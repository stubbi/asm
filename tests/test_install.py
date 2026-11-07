"""Check collision handling for the development install target."""

from pathlib import Path
import os
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-install-failure-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / "source"
        self.source.write_bytes(b"Asm source-install fixture.\n")
        self.source.chmod(0o755)
        self.destination = self.work / "asm"

    def test_source_install_runs_first_project(self):
        with tempfile.TemporaryDirectory(prefix="install-project-", dir=ROOT / "build") as temporary:
            work = Path(temporary)
            destination = work / "bin/asm"
            result = subprocess.run(
                ["sh", "cli/install.sh", "install", "build/asm", str(destination), "0"],
                cwd=ROOT, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            project = work / "hello"
            result = subprocess.run([str(destination), "new", str(project)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(destination), "run"], cwd=project, capture_output=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Hello from asm!\n", b""))
            result = subprocess.run([str(destination), "test"], cwd=project, capture_output=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Passed tests/main.s\n", b""))

    def test_install_and_uninstall_preserve_other_commands(self):
        with tempfile.TemporaryDirectory(prefix="install test ", dir=ROOT / "build") as temporary:
            destination = Path(temporary) / "bin/asm"
            destination.parent.mkdir()
            destination.write_text("another asm command")
            args = ["sh", "cli/install.sh", "install", "build/asm", str(destination), "0"]
            result = subprocess.run(args, cwd=ROOT, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(destination.read_text(), "another asm command")
            args[2] = "uninstall"
            result = subprocess.run(args, cwd=ROOT, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(destination.read_text(), "another asm command")
            destination.unlink()
            args[2] = "install"
            for _ in range(2):
                subprocess.run(args, cwd=ROOT, check=True, capture_output=True, timeout=10)
            self.assertEqual(destination.read_bytes(), (ROOT / "build/asm").read_bytes())
            args[2] = "uninstall"
            subprocess.run(args, cwd=ROOT, check=True, capture_output=True, timeout=10)
            self.assertFalse(destination.exists())

    def test_install_rejects_symlink_and_explicit_replace_is_required(self):
        with tempfile.TemporaryDirectory(prefix="install-", dir=ROOT / "build") as temporary:
            protected = Path(temporary) / "protected"
            protected.write_text("keep this")
            destination = Path(temporary) / "asm"
            destination.symlink_to(protected)
            args = ["sh", "cli/install.sh", "install", "build/asm", str(destination), "0"]
            result = subprocess.run(args, cwd=ROOT, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(protected.read_text(), "keep this")
            args[-1] = "1"
            subprocess.run(args, cwd=ROOT, check=True, capture_output=True, timeout=10)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(protected.read_text(), "keep this")
            self.assertEqual(destination.read_bytes(), (ROOT / "build/asm").read_bytes())

    def installer(self, action, replace=0):
        arguments = ["sh", str(ROOT / "cli/install.sh"), action,
                     str(self.source), str(self.destination), str(replace)]
        with subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)
                self.fail(f"The source installer did not finish {action} within three seconds.")
            return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)

    def test_identical_nonexecutable_destination_requires_explicit_replacement(self):
        self.destination.write_bytes(self.source.read_bytes())
        self.destination.chmod(0o644)
        original = self.destination.stat()
        result = self.installer("install")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"REPLACE=1", result.stderr)
        self.assertEqual(self.destination.read_bytes(), b"Asm source-install fixture.\n")
        self.assertEqual(self.destination.stat().st_ino, original.st_ino)
        self.assertEqual(self.destination.stat().st_mode & 0o7777, 0o644)
        self.assertEqual(list(self.work.glob(".asm-install.*")), [])

        result = self.installer("install", replace=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), b"Asm source-install fixture.\n")
        self.assertEqual(self.destination.stat().st_mode & 0o7777, 0o755)
        self.assertNotEqual(self.destination.stat().st_ino, original.st_ino)
        self.assertEqual(list(self.work.glob(".asm-install.*")), [])

    def test_uninstall_rejects_nonregular_or_foreign_destinations_promptly(self):
        protected = self.work / "protected"
        protected.write_bytes(self.source.read_bytes())
        for kind in ("fifo", "directory", "symlink", "foreign"):
            with self.subTest(kind=kind):
                self.destination = self.work / kind
                if kind == "fifo":
                    os.mkfifo(self.destination)
                elif kind == "directory":
                    self.destination.mkdir()
                    (self.destination / "keep").write_bytes(b"Preserve this file.\n")
                elif kind == "symlink":
                    self.destination.symlink_to(protected)
                else:
                    self.destination.write_bytes(b"Another asm command.\n")
                original = self.destination.lstat()
                result = self.installer("uninstall")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"Refuse to remove", result.stderr)
                self.assertEqual(self.destination.lstat().st_ino, original.st_ino)
                self.assertEqual(self.destination.lstat().st_mode, original.st_mode)
                self.assertEqual(protected.read_bytes(), b"Asm source-install fixture.\n")
                if kind == "directory":
                    self.assertEqual((self.destination / "keep").read_bytes(), b"Preserve this file.\n")
                elif kind == "symlink":
                    self.assertEqual(self.destination.readlink(), protected)
                elif kind == "foreign":
                    self.assertEqual(self.destination.read_bytes(), b"Another asm command.\n")
