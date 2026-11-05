"""Keep explicit native test targets bound to their host OS and ISA.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import os
from pathlib import Path
import platform
import runpy
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


class HostFixtureTests(unittest.TestCase):
    def load(self, system, machine, target):
        with patch.object(platform, "system", return_value=system), \
                patch.object(platform, "machine", return_value=machine), \
                patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ASM_TEST_TARGET", None)
            if target is not None:
                os.environ["ASM_TEST_TARGET"] = target
            return runpy.run_path(str(ROOT / "tests/host.py"))

    def test_matching_native_linux_target_loads_the_real_fixtures(self):
        for machine, target in (("x86_64", "x86_64-linux"), ("amd64", "x86_64-linux"),
                                ("aarch64", "aarch64-linux"), ("arm64", "aarch64-linux")):
            with self.subTest(machine=machine):
                try:
                    fixtures = self.load("Linux", machine, target)
                except RuntimeError as error:
                    self.fail(f"Matching native Linux target was rejected: {error}")
                self.assertEqual(fixtures["TARGET"], target)

    def test_foreign_os_or_isa_cannot_select_native_linux_fixtures(self):
        for system, machine, target in (("Linux", "x86_64", "aarch64-linux"),
                                        ("Linux", "aarch64", "x86_64-linux"),
                                        ("Darwin", "arm64", "aarch64-linux"),
                                        ("Darwin", "x86_64", "x86_64-linux"),
                                        ("Windows", "AMD64", "x86_64-linux"),
                                        ("Linux", "x86_64", "x86_64-macos"),
                                        ("Linux", "riscv64", "x86_64-linux"),
                                        ("Linux", "riscv64", "aarch64-linux"),
                                        ("Darwin", "arm64", "riscv64-linux"),
                                        ("Windows", "AMD64", "riscv64-linux")):
            with self.subTest(system=system, machine=machine, target=target):
                with self.assertRaises(RuntimeError):
                    self.load(system, machine, target)

    def test_riscv_fixture_selection_retains_actual_kernel_syscalls(self):
        for machine, target, expected in (
                ("riscv64", None, (135, 163, 164, 276)),
                ("riscv64", "riscv64-linux", (135, 163, 164, 276)),
                ("x86_64", "riscv64-linux", (14, 97, 160, 316)),
                ("amd64", "riscv64-linux", (14, 97, 160, 316)),
                ("aarch64", "riscv64-linux", (135, 163, 164, 276)),
                ("arm64", "riscv64-linux", (135, 163, 164, 276))):
            with self.subTest(machine=machine, target=target):
                fixtures = self.load("Linux", machine, target)
                self.assertEqual(fixtures["TARGET"], "riscv64-linux")
                self.assertEqual(fixtures["CLI_SOURCE"], "cli/riscv64/asm.s")
                self.assertEqual(fixtures["CLI_ASM_FLAGS"], ["-march=rv64im", "-mabi=lp64"])
                self.assertEqual(fixtures["ASM_FLAGS"], ["-march=rv64i", "-mabi=lp64"])
                self.assertEqual(tuple(fixtures[name] for name in
                    ("SYS_SIGPROCMASK", "SYS_GETRLIMIT", "SYS_SETRLIMIT", "SYS_RENAMEAT")), expected)

    def test_intel_darwin_fixture_retains_its_architecture_and_source(self):
        for machine in ("x86_64", "arm64"):
            with self.subTest(machine=machine):
                fixtures = self.load("Darwin", machine, "x86_64-macos")
                self.assertEqual(fixtures["TARGET"], "x86_64-macos")
                self.assertEqual(fixtures["MAC_ARCH"], "x86_64")
                self.assertEqual(fixtures["MAC_PREPARED"], "build/macos-x86_64/asm.s")
                self.assertEqual(fixtures["CLI_SOURCE"], "cli/macos/x86_64/asm.s")
                self.assertIn(".intel_syntax noprefix", fixtures["exit_source"](0))
