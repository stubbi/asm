"""Exercise the Intel macOS math package natively or under Rosetta.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

if __package__:
    from .macos_host import is_apple_silicon
else:
    from macos_host import is_apple_silicon


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == "Darwin", "Apple clang and macOS are required")
class MathX8664MacosTests(unittest.TestCase):
    def test_unsigned_values_preserved_registers_and_output_failure(self):
        package = ROOT / "examples/math"
        prefix = "targets/x86_64-macos/"
        compiler = shutil.which("clang")
        if not compiler:
            self.skipTest("Apple clang is required")
        with tempfile.TemporaryDirectory(prefix="asm-math-intel-macos-") as directory:
            outputs = []
            for source, name in (("src/main.s", "demo"), ("tests/main.s", "tests")):
                self.assertTrue((package / prefix / source).is_file(), f"Missing {package / prefix / source}")
                output = Path(directory) / name
                result = subprocess.run(
                    [compiler, "-arch", "x86_64", "-mmacosx-version-min=15.0",
                     "-Wl,-no_uuid", prefix + source, "-o", str(output)],
                    cwd=package, capture_output=True, timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")
                outputs.append(output)
            runner = []
            if is_apple_silicon():
                runner = ["/usr/bin/arch", "-x86_64"]
                probe = subprocess.run(
                    runner + ["/usr/bin/true"], capture_output=True, timeout=10
                )
                if probe.returncode:
                    self.skipTest("Intel executables built; Rosetta is unavailable")
            for output, expected in zip(outputs, (b"min(12, 37) = 12\n", b"")):
                result = subprocess.run(
                    runner + [str(output)], capture_output=True, timeout=10
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, b"")
            with (package / prefix / "src/min.s").open("rb") as read_only:
                result = subprocess.run(
                    runner + [str(outputs[0])], stdout=read_only,
                    stderr=subprocess.PIPE, timeout=10,
                )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
