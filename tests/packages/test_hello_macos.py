"""Observe native macOS hello output and failure exits; label translation separately."""
import hashlib
from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
from unittest.mock import patch

try:
    from .macos_host import is_apple_silicon
except ImportError:
    from macos_host import is_apple_silicon

ROOT = Path(__file__).resolve().parents[2]
ARM_HARDWARE = is_apple_silicon()


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS and Apple clang")
class MacHelloTests(unittest.TestCase):
    def exercise(self, target, arch):
        with tempfile.TemporaryDirectory() as temporary:
            source = ROOT / "examples/hello/targets" / f"{target}-macos" / "src/main.s"
            output = Path(temporary) / "hello"
            subprocess.run(["/usr/bin/clang", "-arch", arch, "-mmacosx-version-min=15.0",
                            "-Wl,-no_uuid", "-o", str(output), str(source)],
                           capture_output=True, check=True, timeout=30)
            if arch == "arm64" and not ARM_HARDWARE:
                self.skipTest("ARM64 Mach-O built; native Apple Silicon is required")
            if arch == "x86_64" and ARM_HARDWARE:
                probe = subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"],
                                       capture_output=True, timeout=10)
                if probe.returncode:
                    self.skipTest("Intel Mach-O built; Rosetta is unavailable")
            result = subprocess.run([str(output)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"Hello from asm!\n")
            self.assertEqual(result.stderr, b"")
            with open(os.devnull, "rb") as readonly:
                failure = subprocess.run([str(output)], stdout=readonly,
                                         stderr=subprocess.PIPE, timeout=10)
            self.assertEqual(failure.returncode, 1, failure.stderr)
            closed = subprocess.run([str(output)], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=10,
                                    preexec_fn=lambda: os.close(1))
            self.assertEqual(closed.returncode, 1, closed.stderr)
            self.assertEqual(closed.stdout, b"")
            mode = "Rosetta translation" if arch == "x86_64" and ARM_HARDWARE else "native"
            print(f"{target}-macos: {mode}; source_sha256={hashlib.sha256(source.read_bytes()).hexdigest()}; "
                  f"artifact_sha256={hashlib.sha256(output.read_bytes()).hexdigest()}")

    def test_apple_silicon_greeting_and_output_failures(self):
        self.exercise("aarch64", "arm64")

    def test_intel_greeting_and_output_failures(self):
        self.exercise("x86_64", "x86_64")

    def test_execution_modes_ignore_python_process_architecture(self):
        if not ARM_HARDWARE:
            self.skipTest("This regression requires Apple Silicon")
        probe = subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"],
                               capture_output=True, timeout=10)
        if probe.returncode:
            self.skipTest("This regression also requires the optional Rosetta runtime")
        name = f"{__package__}._hello_process_metadata" if __package__ else "_hello_process_metadata"
        output = io.StringIO()
        with patch("platform.machine", return_value="x86_64"):
            # Reload the cached hardware decision under controlled process metadata.
            # The hardware probe and compiled executables remain real.
            spec = importlib.util.spec_from_file_location(name, __file__)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.assertTrue(module.is_apple_silicon())
            self.assertTrue(module.ARM_HARDWARE)
            case = module.MacHelloTests("test_apple_silicon_greeting_and_output_failures")
            try:
                with redirect_stdout(output):
                    case.exercise("aarch64", "arm64")
                    case.exercise("x86_64", "x86_64")
            except unittest.SkipTest as error:
                self.fail(f"Controlled process metadata skipped a runnable target: {error}")
        self.assertIn("aarch64-macos: native;", output.getvalue())
        self.assertIn("x86_64-macos: Rosetta translation;", output.getvalue())


if __name__ == "__main__":
    unittest.main()
