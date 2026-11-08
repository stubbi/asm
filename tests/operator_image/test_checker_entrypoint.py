"""A checker image binds its receipt to immutable source and fixed input paths.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import contextlib
import io
import hashlib
from pathlib import Path
import subprocess
import sys
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


class CheckerEntrypointTests(unittest.TestCase):
    def test_checked_receipt_binds_source_and_corrupt_inputs_preserve_bytes(self):
        import checker_entrypoint
        import registry
        import publication_check
        with tempfile.TemporaryDirectory(prefix="asm-checker-entrypoint-") as directory:
            root = Path(directory).resolve()
            objects = root / "objects"
            objects.mkdir(mode=0o700)
            archive = registry.make_archive({"asm.toml": (b'[package]\nname="hello"\nversion="1.0.0"\n'
                b'[target.x86_64-linux]\nsource="src/main.s"\n', 0o644),
                "src/main.s": (b".global _start\n_start: nop\n", 0o644),
                "LICENSE": (b"Synthetic MIT fixture\n", 0o644), "README.md": (b"Fixture\n", 0o644)})
            digest, task = hashlib.sha256(archive).hexdigest(), "a" * 32
            value = {"schema": 2, "owner_id": "b" * 32, "name": "example/hello", "version": "1.0.0",
                "summary": "Synthetic image entrypoint fixture.", "license": "MIT", "source": {
                "commit": {"algorithm": "git-sha1", "digest": "c" * 40}, "path": ".",
                "archive": {"sha256": digest, "bytes": len(archive)}}, "artifacts": [{"kind": "source",
                "format": "tar.gz", "isa": "x86_64", "os": "linux", "abi": "sysv-amd64", "cpu_features": [],
                "sha256": digest, "bytes": len(archive)}]}
            raw = registry.json_bytes(value)
            (root / "manifest.json").write_bytes(raw)
            (root / "manifest.json").chmod(0o600)
            object_file = objects / (task + "-" + digest)
            object_file.write_bytes(archive)
            object_file.chmod(0o600)
            for corrupt, outcome in ((False, "pass"), (True, "error")):
                if corrupt:
                    object_file.write_bytes(b"!" + archive[1:])
                before = object_file.read_bytes()
                output = io.BytesIO()
                with patch.object(checker_entrypoint, "INPUT", root, create=True), \
                        patch.object(checker_entrypoint, "source_revision", return_value="d" * 40), \
                        patch.object(sys, "stdout", SimpleNamespace(buffer=output)):
                    self.assertEqual(checker_entrypoint.main(["--task", task]), 0)
                receipt = registry.strict_json(output.getvalue())
                self.assertEqual(receipt["checker_revision"], "d" * 40)
                self.assertEqual(receipt["manifest_sha256"], hashlib.sha256(raw).hexdigest())
                self.assertEqual(receipt["policy_sha256"], publication_check.policy_digest())
                self.assertEqual(receipt["outcome"], outcome)
                self.assertEqual(object_file.read_bytes(), before)

    def test_help_is_available_without_inputs_and_overrides_fail(self):
        script = ROOT / "tools/checker_entrypoint.py"
        helped = subprocess.run([sys.executable, "-I", str(script), "--help"], capture_output=True, timeout=5)
        self.assertEqual(helped.returncode, 0, helped.stderr.decode())
        self.assertIn(b"--task", helped.stdout)
        for option in ("--manifest", "--objects", "--checker-revision", "--command"):
            result = subprocess.run([sys.executable, "-I", str(script), "--task", "a" * 32, option, "/untrusted"],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b"")

    def test_an_absent_image_source_marker_refuses_before_reading_input(self):
        import checker_entrypoint
        import image_source
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(image_source, "SOURCE", Path("/absent-image-source-marker")), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(checker_entrypoint.main(["--task", "a" * 32]), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("image source", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
