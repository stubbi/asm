"""Exercise standalone package preparation and destination preservation.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


HERE = Path(__file__).resolve().parent


class PackageTests(unittest.TestCase):
    def test_missing_test_input_preserves_source_and_does_not_create_output(self):
        with tempfile.TemporaryDirectory(prefix="asm-package-missing-") as temporary:
            source = Path(temporary) / "source"
            shutil.copytree(HERE, source, ignore=shutil.ignore_patterns("build", "__pycache__"))
            original = (source / "asm.toml").read_bytes()
            (source / "test_package.py").unlink()
            marker = source / "keep.txt"
            marker.write_bytes(b"existing source data\n")
            output = Path(temporary) / "package"
            target = tomllib.loads(original.decode("utf-8"))["build"]["target"]
            result = subprocess.run(
                [sys.executable, str(source / "package.py"), "--target", target, "--output", str(output)],
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("test_package.py", result.stderr)
            self.assertFalse(output.exists())
            self.assertEqual((source / "asm.toml").read_bytes(), original)
            self.assertEqual(marker.read_bytes(), b"existing source data\n")

    def test_prepare_keeps_source_manifest_and_refuses_existing_destination(self):
        original = (HERE / "asm.toml").read_bytes()
        target = tomllib.loads(original.decode("utf-8"))["build"]["target"]
        with tempfile.TemporaryDirectory(prefix="asm-package-test-") as temporary:
            output = Path(temporary) / "package"
            command = [sys.executable, str(HERE / "package.py"), "--target", target,
                       "--output", str(output)]
            first = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual((output / "asm.toml").read_bytes(), original)
            self.assertEqual((output / "server.s").read_bytes(), (HERE / "server.s").read_bytes())
            marker = output / "keep"
            marker.write_text("existing data\n")
            second = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(marker.read_text(), "existing data\n")
            self.assertEqual((HERE / "asm.toml").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
