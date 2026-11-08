"""Credential-free publication checks use synthetic bytes and never execute them.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import hashlib
import importlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class PublicationCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-publisher-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.task = "1" * 32
        self.revision = "a" * 40
        self.data = self.archive()
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest = {"schema": 2, "owner_id": "2" * 32, "name": "example/hello", "version": "1.0.0",
            "summary": "Synthetic checker fixture.", "license": "MIT",
            "source": {"commit": {"algorithm": "git-sha1", "digest": "b" * 40}, "path": ".",
                "repository": "https://entire.com/et/example/hello",
                "archive": {"sha256": self.digest, "bytes": len(self.data)}},
            "artifacts": [{"kind": "source", "format": "tar.gz", "isa": "x86_64", "os": "linux",
                "abi": "sysv-amd64", "cpu_features": [], "sha256": self.digest, "bytes": len(self.data)}]}
        self.manifest_file = self.root / "manifest.json"
        self.objects = self.root / "uploads"
        self.objects.mkdir(mode=0o700)
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()

    def archive(self, extra="", *, targets=("x86_64-linux",), lock=False):
        project = '[package]\nname = "hello"\nversion = "1.0.0"\n'
        project += "".join(f'\n[target.{target}]\nsource = "src/main.s"\n' for target in targets)
        files = {"asm.toml": ((project + extra).encode(), 0o644),
            "LICENSE": (b"Synthetic fixture under MIT.\n", 0o644),
            "README.md": (b"Synthetic fixture.\n", 0o644),
            "src/main.s": (b".global _start\n_start: nop\n", 0o644)}
        if lock:
            files["asm.lock"] = (b"# consumer lock\n", 0o644)
        return registry.make_archive(files)

    def write(self):
        self.manifest_file.write_bytes(registry.json_bytes(self.manifest))
        self.manifest_file.chmod(0o600)
        self.object_file.write_bytes(self.data)
        self.object_file.chmod(0o600)

    def module(self):
        return importlib.import_module("publication_check")

    def check(self):
        return self.module().check(self.task, self.manifest_file, self.objects, self.revision)

    def test_entire_and_no_locator_bind_the_exact_manifest_and_source_bytes(self):
        for locator in (True, False):
            if not locator:
                del self.manifest["source"]["repository"]
                self.write()
            receipt = self.check()
            self.assertEqual(receipt, {"schema": 1, "task_id": self.task,
                "manifest_sha256": hashlib.sha256(self.manifest_file.read_bytes()).hexdigest(),
                "checker_revision": self.revision, "policy_sha256": self.module().policy_digest(),
                "outcome": "pass", "objects": [{"sha256": self.digest, "bytes": len(self.data), "outcome": "pass"}]})

    def test_structural_archive_failure_is_distinct_from_missing_or_changed_staging(self):
        self.object_file.unlink()
        self.assertEqual(self.check()["outcome"], "error")
        self.write()
        self.object_file.write_bytes(b"!" + self.data[1:])
        self.assertEqual(self.check()["outcome"], "error")
        self.data = b"Not an archive."
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
        self.manifest["artifacts"][0].update(sha256=self.digest, bytes=len(self.data))
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()
        self.assertEqual(self.check()["outcome"], "fail")

    def test_all_six_targets_share_one_checked_source_without_execution(self):
        tuples = self.module().TARGETS
        self.data = self.archive(targets=tuple(value[0] for value in tuples.values()))
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
        self.manifest["artifacts"] = [{"kind": "source", "format": "tar.gz", "isa": isa, "os": operating_system,
            "abi": abi, "cpu_features": [], "sha256": self.digest, "bytes": len(self.data)}
            for isa, operating_system, abi in tuples]
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()
        self.assertEqual(self.check()["outcome"], "pass")
        self.assertEqual(len(self.check()["objects"]), 1)

    def test_target_mismatch_or_undeclared_source_dependencies_fail(self):
        self.manifest["artifacts"][0].update(isa="aarch64", abi="aapcs64")
        self.write()
        self.assertEqual(self.check()["outcome"], "fail")
        self.data = self.archive('\n[dependencies]\n"other/math" = "1.0.0"\n')
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
        self.manifest["artifacts"][0].update(isa="x86_64", abi="sysv-amd64", sha256=self.digest, bytes=len(self.data))
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()
        self.assertEqual(self.check()["outcome"], "fail")

    def test_signed_dependencies_match_source_before_any_dependency_download(self):
        self.data = self.archive('\n[dependencies]\n"other/math" = "^1.2.0"\n')
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
        self.manifest["artifacts"][0].update(sha256=self.digest, bytes=len(self.data))
        self.manifest["dependencies"] = [{"name": "other/math", "requirement": "^1.2.0"}]
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()
        try:
            receipt = self.check()
        except registry.RegistryError as error:
            self.fail(str(error))
        self.assertEqual(receipt["outcome"], "pass")
        self.manifest["dependencies"][0]["requirement"] = "~1.2.0"
        self.write()
        self.assertEqual(self.check()["outcome"], "fail")

    def test_dependency_metadata_rejects_duplicates_features_and_invalid_ranges(self):
        cases = [
            [{"name": "other/math", "requirement": "^1.2"}],
            [{"name": "other/math", "requirement": ">=1.0.0,invalid"}],
            [{"name": "other/math", "requirement": "1.0.0", "optional": True}],
            [{"name": "other/math", "requirement": "1.0.0"}] * 2,
            [{"name": "z/math", "requirement": "1.0.0"}, {"name": "a/math", "requirement": "*"}],
        ]
        for dependencies in cases:
            with self.subTest(dependencies=dependencies):
                self.manifest["dependencies"] = dependencies
                self.write()
                with self.assertRaises(registry.RegistryError):
                    self.check()

    def test_published_source_cannot_contain_a_consumer_lock(self):
        self.data = self.archive(lock=True)
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
        self.manifest["artifacts"][0].update(sha256=self.digest, bytes=len(self.data))
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()
        self.assertEqual(self.check()["outcome"], "fail")

    def test_unknown_targets_features_urls_and_ambiguous_manifests_are_refused(self):
        original = copy.deepcopy(self.manifest)
        for field, value in (("isa", "unknown"), ("cpu_features", ["avx2"]), ("url", "https://example.invalid/object")):
            self.manifest = copy.deepcopy(original)
            self.manifest["artifacts"][0][field] = value
            self.write()
            with self.subTest(field=field), self.assertRaises(registry.RegistryError):
                self.check()
        for raw in (b'{"schema":2,"schema":2}\n', b" " + registry.json_bytes(original), b"[" * 10000 + b"]" * 10000):
            self.manifest_file.write_bytes(raw)
            with self.assertRaises(registry.RegistryError):
                self.check()

    def test_hostile_source_toml_returns_a_bound_failure_receipt(self):
        for extra in ("\n[unknown]\nvalue = " + "[" * 2000 + "0" + "]" * 2000 + "\n",
                      "\n#" + "x" * registry.MAX_PROJECT_BYTES + "\n"):
            self.data = self.archive(extra)
            self.digest = hashlib.sha256(self.data).hexdigest()
            self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
            self.manifest["artifacts"][0].update(sha256=self.digest, bytes=len(self.data))
            self.object_file = self.objects / (self.task + "-" + self.digest)
            self.write()
            with self.subTest(expanded=len(extra)):
                self.assertEqual(self.check()["outcome"], "fail")

    def test_linked_or_public_files_and_existing_bytes_are_preserved(self):
        before = self.object_file.read_bytes()
        self.object_file.chmod(0o644)
        self.assertEqual(self.check()["outcome"], "error")
        self.object_file.unlink()
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(before)
        self.object_file.symlink_to(sentinel)
        self.assertEqual(self.check()["outcome"], "error")
        self.assertEqual(sentinel.read_bytes(), before)
        self.object_file.unlink()
        self.object_file.write_bytes(before)
        self.object_file.chmod(0o600)
        os.link(self.object_file, self.root / "hardlink")
        self.assertEqual(self.check()["outcome"], "error")
        self.assertEqual(self.object_file.read_bytes(), before)

    def test_real_cli_emits_one_canonical_receipt_without_ambient_credentials(self):
        command = [sys.executable, "-I", str(ROOT / "tools/publication_check.py"), "check",
            "--task", self.task, "--manifest", str(self.manifest_file), "--objects", str(self.objects),
            "--checker-revision", self.revision]
        result = subprocess.run(command, capture_output=True, timeout=10,
            env={"PATH": os.defpath, "AWS_SECRET_ACCESS_KEY": "synthetic-not-needed",
                 "PGPASSWORD": "synthetic-not-needed", "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout, registry.json_bytes(self.check()))
        self.assertNotIn(b"synthetic-not-needed", result.stdout)
        self.manifest_file.write_bytes(b"{}\n")
        refused = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(refused.stdout, b"")
        self.assertNotIn(b"Traceback", refused.stderr)


if __name__ == "__main__":
    unittest.main()
