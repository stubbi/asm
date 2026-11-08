"""A local distribution gate runs before the catalog operator reads credentials.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import weakref

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import registry_admin
import registry_mirror
from registry_storage import LocalBlobStore


class DistributionGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-distribution-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / "repository"
        self.repo.mkdir()
        self.artifacts = self.base / "artifacts"
        self.artifacts.mkdir()
        self.record, self.data = self.release("0.1.0")
        self.write_record(self.record)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "Record a synthetic distribution fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.store = LocalBlobStore(self.base / "distribution")
        self.snapshot = registry_mirror.publish(self.store, self.repo, self.commit, self.artifacts, initialize=True)

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false", "-c", "user.name=Distribution fixture",
            "-c", "user.email=fixture@example.invalid", *arguments],
            check=True, capture_output=True, timeout=10).stdout

    def release(self, version):
        data = registry.make_archive({
            "asm.toml": (f'[package]\nname = "hello"\nversion = "{version}"\n'
                         '[build]\nsource = "src/main.s"\ntarget = "x86_64-linux"\n'.encode(), 0o644),
            "LICENSE": (b"Synthetic fixture under MIT.\n", 0o644),
            "README.md": (b"Synthetic distribution fixture.\n", 0o644),
            "src/main.s": (b".global _start\n_start: nop\n", 0o644),
        })
        asset = f"hello-{version}.tar.gz"
        (self.artifacts / asset).write_bytes(data)
        record = {"schema": 1, "name": "fixture/hello", "version": version,
            "summary": "Synthetic distribution fixture.", "license": "MIT", "yanked": False,
            "source": {"repository": "https://github.com/fixture/hello", "commit": "a" * 40, "path": "."},
            "artifacts": [{"target": "x86_64-linux", "kind": "source", "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "url": f"https://github.com/fixture/hello/releases/download/v{version}/{asset}"}]}
        return record, data

    def write_record(self, record):
        path = self.repo / "registry/packages" / record["name"] / (record["version"] + ".json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(registry.json_bytes(record))

    def prepared(self):
        return registry_admin.prepare_import(self.repo, self.commit, 0)

    def verify(self):
        return registry_admin.verify_distribution(self.store.root, self.commit, self.prepared()[1])

    def cli(self, root, *, plan_digest=None):
        # Observe actual filesystem opens in the real parser/entrypoint process.
        # A valid distribution must reach this boundary; invalid input must not.
        credential = self.base / "operator.url"
        driver = """import os,sys
sys.path.insert(0,sys.argv.pop(1))
import registry_admin
credential=sys.argv.pop(1)
def observe(event,args):
    if event=='import' and args[0].split('.')[0] in {'boto3','botocore'}:
        raise RuntimeError('unexpected-s3-sdk-import')
    if event=='open' and args[0]==credential:
        raise RuntimeError('credential-access-observed')
sys.addaudithook(observe)
raise SystemExit(registry_admin.main(sys.argv[1:]))
"""
        return subprocess.run([sys.executable, "-c", driver, str(ROOT / "tools"), str(credential),
            "--connection-file", str(credential), "--psql", "/not-a-psql-program",
            "import", "--repository", str(self.repo), "--commit", self.commit,
            "--expected-revision", "0", "--plan-sha256", plan_digest or self.prepared()[0]["plan_sha256"],
            "--distribution-root", str(root)], capture_output=True, timeout=15,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))

    def test_cli_rejects_missing_store_before_credentials(self):
        missing = self.base / "absent-distribution"
        result = self.cli(missing)
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertIn(b"distribution", result.stderr.lower())
        self.assertNotIn(b"credential-access-observed", result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertFalse(missing.exists(), "A read prerequisite must not initialize storage.")

    def test_valid_store_reaches_the_observed_credential_boundary(self):
        result = self.cli(self.store.root)
        self.assertIn(b"credential-access-observed", result.stderr)
        self.assertEqual(result.stdout, b"")

    def test_verification_returns_the_exact_snapshot_without_changing_files(self):
        before = {p.relative_to(self.store.root): p.read_bytes()
                  for p in self.store.root.rglob("*") if p.is_file()}
        receipt = self.verify()
        self.assertEqual(receipt, {"snapshot_sha256": self.snapshot, "source_commit": self.commit,
                                   "sequence": 1, "artifact_count": 1})
        self.assertEqual(before, {p.relative_to(self.store.root): p.read_bytes()
                                 for p in self.store.root.rglob("*") if p.is_file()})

    def test_same_records_at_another_commit_do_not_satisfy_the_gate(self):
        self.git("commit", "--allow-empty", "-qm", "Accept a different source revision")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        result = self.cli(self.store.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"source commit", result.stderr)
        self.assertNotIn(b"credential-access-observed", result.stderr)

    def test_missing_or_corrupt_artifact_cannot_reach_credentials(self):
        path = self.store.root / "blobs/sha256" / self.record["artifacts"][0]["sha256"]
        original = path.read_bytes()
        for value in (None, b"!" + original[1:]):
            with self.subTest(missing=value is None):
                if value is None:
                    path.unlink()
                else:
                    path.write_bytes(value)
                    path.chmod(0o600)
                result = self.cli(self.store.root)
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"distribution", result.stderr.lower())
                self.assertNotIn(b"credential-access-observed", result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_snapshot_records_must_match_the_accepted_tree(self):
        current = registry_mirror.load_current(self.store)
        snapshot = copy.deepcopy(current[1])
        snapshot["records"][0]["summary"] = "Different bytes under the selected commit."
        snapshot["sequence"] += 1
        snapshot["previous"] = self.snapshot
        registry_mirror._install(self.store, snapshot, (self.snapshot, current[1], current[2]))
        result = self.cli(self.store.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"records", result.stderr)
        self.assertNotIn(b"credential-access-observed", result.stderr)

    def test_matching_digest_does_not_replace_archive_validation(self):
        bad = b"Not a source archive."
        record = copy.deepcopy(self.record)
        record["artifacts"][0].update(bytes=len(bad), sha256=hashlib.sha256(bad).hexdigest())
        self.write_record(record)
        self.git("add", ".")
        self.git("commit", "-qm", "Accept a structurally invalid artifact fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        path = self.base / "bad-artifact"
        path.write_bytes(bad)
        other = LocalBlobStore(self.base / "unqualified")
        other.put_blob(path, record["artifacts"][0]["sha256"], len(bad))
        snapshot = {"schema": 1, "source_commit": self.commit, "sequence": 1, "previous": None,
                    "records": [record], "objects": registry_mirror._objects([record])}
        registry_mirror._install(other, snapshot, None)
        result = self.cli(other.root)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"distribution", result.stderr.lower())
        self.assertNotIn(b"credential-access-observed", result.stderr)

    def test_a_changed_head_interrupts_verification(self):
        current = registry_mirror.load_current(self.store)
        with patch.object(registry_mirror, "load_current", side_effect=[current, None]):
            with self.assertRaisesRegex(registry_admin.AdminError, "changed"):
                self.verify()

    def test_reviewed_plan_is_checked_before_distribution_or_credentials(self):
        result = self.cli(self.base / "absent", plan_digest="0" * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"reviewed import plan", result.stderr)
        self.assertNotIn(b"credential-access-observed", result.stderr)

    def test_validation_releases_each_artifact_before_the_next_read(self):
        second, _ = self.release("0.2.0")
        self.write_record(second)
        self.git("add", ".")
        self.git("commit", "-qm", "Accept a second distribution artifact")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        registry_mirror.publish(self.store, self.repo, self.commit, self.artifacts)
        original = LocalBlobStore.get_blob
        retained = []

        class ObservedBytes(bytearray):
            pass

        def observe(store, digest, size):
            self.assertTrue(all(value() is None for value in retained), "An earlier artifact remains in memory.")
            value = ObservedBytes(original(store, digest, size))
            retained.append(weakref.ref(value))
            return value

        with patch.object(LocalBlobStore, "get_blob", observe):
            self.assertEqual(self.verify()["artifact_count"], 2)
        self.assertTrue(all(value() is None for value in retained))


if __name__ == "__main__":
    unittest.main()
