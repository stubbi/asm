"""Build and exercise the ARM64 math examples; package logic stays in assembly.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import os
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest

if __package__:
    from .macos_host import is_apple_silicon
else:
    from macos_host import is_apple_silicon


ROOT = Path(__file__).resolve().parents[2]
ARM_HOST = platform.machine().lower() in ("aarch64", "arm64")


class MathAarch64Tests(unittest.TestCase):
    def command(self, argv, cwd, **kwargs):
        result = subprocess.run(
            argv, cwd=cwd, capture_output=True, timeout=30, **kwargs
        )
        self.assertEqual(result.returncode, 0, (argv, result.stdout, result.stderr))
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def build(self, package, source, output, macos):
        self.assertTrue((package / source).is_file(), f"Missing {package / source}")
        if macos:
            compiler = shutil.which("clang")
            if not compiler:
                self.skipTest("Apple clang is required")
            self.command(
                [compiler, "-arch", "arm64", "-mmacosx-version-min=15.0",
                 "-Wl,-no_uuid", source, "-o", str(output)], package
            )
            return
        assembler = shutil.which("aarch64-linux-gnu-as")
        linker = os.environ.get("ASM_AARCH64_LINUX_LD")
        linker = linker or shutil.which("aarch64-linux-gnu-ld") or shutil.which("ld.lld")
        if not linker and platform.system() == "Linux" and ARM_HOST:
            linker = shutil.which("ld")
        if not linker:
            self.skipTest("Set ASM_AARCH64_LINUX_LD to an AArch64 ELF linker")
        object_path = output.with_suffix(".o")
        if assembler:
            self.command([assembler, "-march=armv8-a", "-o", str(object_path), source], package)
        else:
            compiler = shutil.which("clang")
            if not compiler:
                self.skipTest("AArch64 GNU assembler or clang is required")
            self.command(
                [compiler, "--target=aarch64-linux-gnu", "-march=armv8-a", "-c",
                 source, "-o", str(object_path)], package
            )
        self.command(
            [linker, "-z", "noexecstack", "--build-id=none", "-o", str(output), str(object_path)],
            package,
        )

    def exercise(self, macos):
        package = ROOT / "examples/math"
        target = "aarch64-macos" if macos else "aarch64-linux"
        prefix = f"targets/{target}/"
        with tempfile.TemporaryDirectory(prefix="asm-math-aarch64-") as directory:
            demo, tests = Path(directory) / "demo", Path(directory) / "tests"
            self.build(package, prefix + "src/main.s", demo, macos)
            self.build(package, prefix + "tests/main.s", tests, macos)
            runner = []
            if not macos and not (platform.system() == "Linux" and ARM_HOST):
                configured = os.environ.get("ASM_AARCH64_LINUX_RUNNER")
                emulator = shutil.which("qemu-aarch64")
                if configured:
                    runner = shlex.split(configured)
                elif emulator:
                    runner = [emulator]
                else:
                    self.skipTest("Linux executables built; native ARM Linux or qemu-aarch64 is required to run")
            result = subprocess.run(
                runner + [str(demo)], capture_output=True, timeout=10
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"min(12, 37) = 12\n")
            self.assertEqual(result.stderr, b"")
            result = subprocess.run(
                runner + [str(tests)], capture_output=True, timeout=10
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            # A read-only descriptor makes write fail with EBADF.
            with (package / prefix / "src/min.s").open("rb") as read_only:
                result = subprocess.run(
                    runner + [str(demo)], stdout=read_only,
                    stderr=subprocess.PIPE, timeout=10,
                )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b"")

    @unittest.skipUnless(is_apple_silicon(), "Apple Silicon macOS is required")
    def test_macos_demo_and_unsigned_abi_cases(self):
        self.exercise(macos=True)

    def test_linux_demo_and_unsigned_abi_cases(self):
        self.exercise(macos=False)


if __name__ == "__main__":
    unittest.main()
