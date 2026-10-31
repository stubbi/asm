"""Check collision handling for the development install target."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def test_install_and_uninstall_preserve_other_commands(self):
        with tempfile.TemporaryDirectory(prefix="install test ", dir=ROOT / "build") as temporary:
            destination = Path(temporary) / "bin/asm"
            destination.parent.mkdir()
            destination.write_text("another asm command")
            args = ["sh", "cli/install.sh", "install", "build/asm", str(destination), "0"]
            result = subprocess.run(args, cwd=ROOT, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(destination.read_text(), "another asm command")
            args[2] = "uninstall"
            result = subprocess.run(args, cwd=ROOT, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(destination.read_text(), "another asm command")
            destination.unlink()
            args[2] = "install"
            for _ in range(2):
                subprocess.run(args, cwd=ROOT, check=True, capture_output=True)
            self.assertEqual(destination.read_bytes(), (ROOT / "build/asm").read_bytes())
            args[2] = "uninstall"
            subprocess.run(args, cwd=ROOT, check=True, capture_output=True)
            self.assertFalse(destination.exists())

    def test_install_rejects_symlink_and_explicit_replace_is_required(self):
        with tempfile.TemporaryDirectory(prefix="install-", dir=ROOT / "build") as temporary:
            protected = Path(temporary) / "protected"
            protected.write_text("keep this")
            destination = Path(temporary) / "asm"
            destination.symlink_to(protected)
            args = ["sh", "cli/install.sh", "install", "build/asm", str(destination), "0"]
            result = subprocess.run(args, cwd=ROOT, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(protected.read_text(), "keep this")
            args[-1] = "1"
            subprocess.run(args, cwd=ROOT, check=True, capture_output=True)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(protected.read_text(), "keep this")
            self.assertEqual(destination.read_bytes(), (ROOT / "build/asm").read_bytes())
