"""Reject incomplete RISC-V combined qualification evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CombinedQualificationTests(unittest.TestCase):
    def setUp(self):
        source = ROOT / "tools/riscv64_combined.py"
        self.assertTrue(source.is_file(), "The combined qualification runner is absent")
        spec = importlib.util.spec_from_file_location("combined_qualification", source)
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)

    def test_guest_tool_requires_a_riscv_elf_executable(self):
        data = bytearray(64)
        data[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HH", data, 16, 3, 243)
        self.assertEqual(self.runner.elf_machine(data), 243)
        for bad in (b"#!/bin/sh\n", data[:63]):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    self.runner.elf_machine(bad)
        for machine, kind in ((62, 3), (243, 1)):
            struct.pack_into("<HH", data, 16, kind, machine)
            with self.subTest(machine=machine, kind=kind):
                with self.assertRaises(ValueError):
                    self.runner.elf_machine(data)

    def test_all_nineteen_tests_must_pass_without_skips(self):
        good = "Ran 19 tests in 8.2s\n\nOK\n"
        self.assertEqual(self.runner.suite_contract(good, 19), 19)
        for bad in ("", good.replace("19", "18"), good.replace("19", "20"),
                    good.replace("OK", "FAILED (failures=1)"),
                    good.replace("OK", "OK (skipped=1)"),
                    "test_x (test_fixture.Tests.test_x) ... skipped 'host'\n" + good):
            with self.subTest(output=bad):
                with self.assertRaises(ValueError):
                    self.runner.suite_contract(bad, 19)

    def test_compiler_must_declare_the_guest_target(self):
        self.runner.compiler_contract("riscv64-linux-gnu")
        for target in ("x86_64-linux-gnu", "aarch64-linux-gnu", "riscv32-linux-gnu", ""):
            with self.subTest(target=target):
                with self.assertRaises(ValueError):
                    self.runner.compiler_contract(target)

    def test_collected_report_requires_nineteen_server_tests(self):
        self.assertTrue(hasattr(self.runner, "result_contract"), "Collected reports have no acceptance contract")
        report = {"outcome": "pass", "target": "riscv64-linux", "execution": "qemu-user",
                  "native_qualified": False, "release_qualified": False,
                  "checks": {"server_package": {"outcome": "pass", "tests_run": 19, "tests_skipped": 0}}}
        self.runner.result_contract(report)
        for changes in ({"tests_run": 18}, {"tests_skipped": 1}, {"outcome": "fail"}):
            with self.subTest(changes=changes):
                bad = json.loads(json.dumps(report))
                bad["checks"]["server_package"].update(changes)
                with self.assertRaises(ValueError):
                    self.runner.result_contract(bad)

    def test_failed_guest_setup_retains_failure_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "qualification.json"
            result = subprocess.run([sys.executable, str(ROOT / "tools/riscv64_combined.py"),
                                     "--inside", "--output", str(output)], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads(output.read_text())
            self.assertEqual(report["outcome"], "fail")
            self.assertFalse(report["native_qualified"])
            self.assertFalse(report["release_qualified"])
            self.assertIn("error", report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
