"""Observable operator command tests; no database or credential is needed here.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/registry_admin.py"
sys.path.insert(0, str(ROOT / "tools"))
import registry


class OperatorPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-catalog-plan-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        record = json.loads((ROOT / "registry/packages/stubbi/asm/0.5.0.json").read_bytes())
        self.record = record
        target = self.repo / "registry/packages" / record["name"] / (record["version"] + ".json")
        target.parent.mkdir(parents=True)
        target.write_bytes(registry.json_bytes(record))
        self.record_path = target
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "Record canonical catalog fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false", "-c", "user.name=Catalog fixture",
            "-c", "user.email=fixture@example.invalid", *args], capture_output=True,
            check=True, timeout=10).stdout

    def run_plan(self, *args, env=None):
        return subprocess.run([sys.executable, str(SCRIPT), "plan", "--repository", str(self.repo),
            "--commit", self.commit, "--expected-revision", "0", *args],
            capture_output=True, timeout=15, env=env)

    def test_plan_preserves_macos_and_binds_exact_canonical_export_bytes(self):
        result = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b"")
        plan = json.loads(result.stdout)
        self.assertEqual(plan["record_count"], 1)
        self.assertEqual(plan["acceptance_commit"], self.commit)
        self.assertEqual(plan["expected_revision"], 0)
        self.assertFalse(plan["artifact_bytes_checked"])
        tsv, index = registry.make_indexes([self.record])
        expected = {
            "/registry/v1/index.tsv": registry.legacy_tsv(tsv).encode(),
            "/registry/v1/index-macos.tsv": registry.macos_compat_tsv(tsv).encode(),
            "/registry/v1/index-all.tsv": tsv.encode(),
            "/registry/v1/index.json": registry.json_bytes(index),
        }
        self.assertIn(b"aarch64-macos", expected["/registry/v1/index-macos.tsv"])
        self.assertNotIn(b"aarch64-macos", expected["/registry/v1/index.tsv"])
        self.assertEqual(set(plan["exports"]), set(expected))
        for route, body in expected.items():
            self.assertEqual(plan["exports"][route]["sha256"], hashlib.sha256(body).hexdigest())
            self.assertEqual(plan["exports"][route]["bytes"], len(body))
        digest = plan.pop("plan_sha256")
        self.assertEqual(digest, hashlib.sha256(registry.json_bytes(plan)).hexdigest())

    def test_new_windows_records_preserve_both_compatibility_feed_bytes(self):
        before = json.loads(self.run_plan().stdout)
        windows = json.loads(registry.json_bytes(self.record))
        windows["version"] = "0.6.0"
        windows["artifacts"] = [
            {"target": target, "kind": "executable", "bytes": 1024, "sha256": "a" * 64,
             "url": f"https://github.com/stubbi/asm/releases/download/v0.6.0/asm-{target}.exe"}
            for target in ("x86_64-windows", "aarch64-windows")]
        path = self.record_path.with_name("0.6.0.json")
        path.write_bytes(registry.json_bytes(windows))
        self.git("add", ".")
        self.git("commit", "-qm", "Add unqualified Windows catalog fixtures")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        result = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        plan = json.loads(result.stdout)
        for route in ("/registry/v1/index.tsv", "/registry/v1/index-macos.tsv"):
            self.assertEqual(plan["exports"][route], before["exports"][route])
        full, index = registry.make_indexes([self.record, windows])
        for route, body in (("/registry/v1/index-all.tsv", full.encode()),
                            ("/registry/v1/index.json", registry.json_bytes(index))):
            self.assertIn(b"x86_64-windows", body)
            self.assertIn(b"aarch64-windows", body)
            self.assertEqual(plan["exports"][route],
                             {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})

    def test_dirty_metadata_and_git_object_replacements_cannot_change_the_plan(self):
        before = self.run_plan()
        self.assertEqual(before.returncode, 0, before.stderr.decode())
        changed = dict(self.record, summary="Uncommitted replacement")
        self.record_path.write_bytes(registry.json_bytes(changed))
        after = self.run_plan()
        self.assertEqual(after.returncode, 0, after.stderr.decode())
        self.assertEqual(before.stdout, after.stdout)
        self.git("add", ".")
        self.git("commit", "-qm", "Create a conflicting fixture commit")
        replacement = self.git("rev-parse", "HEAD").decode().strip()
        self.git("replace", self.commit, replacement)
        self.assertEqual(self.run_plan().stdout, before.stdout)

    def test_invalid_manifest_and_path_fail_without_partial_machine_output(self):
        self.record["license"] = "unknown-license"
        self.record_path.write_bytes(registry.json_bytes(self.record))
        self.git("add", ".")
        self.git("commit", "-qm", "Record invalid fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        result = self.run_plan()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"invalid", result.stderr.lower())

    def test_rewritten_loose_blob_tree_or_commit_cannot_preserve_source_identity(self):
        blob = self.git("rev-parse", self.commit + ":registry/packages/stubbi/asm/0.5.0.json").decode().strip()
        tree = self.git("rev-parse", self.commit + "^{tree}").decode().strip()
        for kind, oid in (("blob", blob), ("tree", tree), ("commit", self.commit)):
            path = self.repo / ".git/objects" / oid[:2] / oid[2:]
            saved = path.read_bytes()
            raw = self.git("cat-file", kind, oid)
            if kind == "blob":
                record = json.loads(raw)
                record["summary"] = "An altered object under the original object identity"
                altered = registry.json_bytes(record)
            elif kind == "commit":
                altered = raw.replace(b"Record canonical", b"Change canonical")
            else:
                altered = raw.replace(b"registry\0", b"registrx\0")
            self.assertNotEqual(altered, raw)
            path.chmod(0o600)
            path.write_bytes(zlib.compress(kind.encode() + b" " + str(len(altered)).encode() + b"\0" + altered))
            try:
                with self.subTest(kind=kind):
                    failed = self.run_plan()
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertEqual(failed.stdout, b"")
            finally:
                path.write_bytes(saved)

    def test_missing_promisor_blob_cannot_launch_a_network_helper(self):
        marker = self.repo / "network-helper-ran"
        helper = self.repo / "controlled-ssh"
        helper.write_text("#!" + sys.executable + "\nfrom pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\nraise SystemExit(1)\n")
        helper.chmod(0o700)
        blob = self.git("rev-parse", self.commit + ":registry/packages/stubbi/asm/0.5.0.json").decode().strip()
        for key, value in (("extensions.partialClone", "origin"), ("remote.origin.promisor", "true"),
                           ("remote.origin.url", "ssh://example.invalid/repo"), ("core.sshCommand", str(helper))):
            self.git("config", key, value)
        (self.repo / ".git/objects" / blob[:2] / blob[2:]).unlink()
        failed = self.run_plan()
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(failed.stdout, b"")
        self.assertFalse(marker.exists(), "The controlled fake network helper must never run.")


if __name__ == "__main__":
    unittest.main()
