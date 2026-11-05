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
                patch.dict(os.environ, {"ASM_TEST_TARGET": target}):
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
                                        ("Linux", "x86_64", "x86_64-macos")):
            with self.subTest(system=system, machine=machine, target=target):
                with self.assertRaises(RuntimeError):
                    self.load(system, machine, target)
