"""Qualification failures must retain a machine-readable evidence record.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import importlib.util
import json
import struct
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def runner_module():
    specification = importlib.util.spec_from_file_location("riscv64_test", ROOT / "tools/riscv64_test.py")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def elf_fixture():
    data = bytearray(120)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQQIHHHHHH", data, 16,
                     2, 243, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    struct.pack_into("<IIQQQQQQ", data, 64, 0x6474E551, 6, 0, 0, 0, 0, 0, 16)
    return data


class QualificationRunnerTests(unittest.TestCase):
    def test_container_gate_rejects_wrong_abi_interpreter_stack_and_bounds(self):
        module = runner_module()
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "candidate"
            mutations = ((18, "H", 183), (48, "I", 4), (64, "I", 3),
                         (68, "I", 7), (32, "Q", 121), (96, "Q", 121))
            for offset, format_code, value in mutations:
                with self.subTest(offset=offset, value=value):
                    data = elf_fixture()
                    struct.pack_into("<" + format_code, data, offset, value)
                    artifact.write_bytes(data)
                    with self.assertRaises(ValueError):
                        module.elf_contract(artifact)

    def test_nonload_attributes_need_no_memory_allocation(self):
        module = runner_module()
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "candidate"
            data = elf_fixture() + bytes(56)
            struct.pack_into("<H", data, 56, 2)
            struct.pack_into("<IIQQQQQQ", data, 120,
                             0x70000003, 4, 175, 0, 0, 1, 0, 1)
            artifact.write_bytes(data)
            self.assertEqual(module.elf_contract(artifact)["elf_machine"], 243)

    def test_system_provenance_is_bounded_and_bound_to_guest_source(self):
        module = runner_module()
        commit = "a" * 40
        record = {"schema": 1, "execution_mode": "emulated", "emulation_kind": "system",
                  "emulator": {"path": "/usr/bin/qemu-system-riscv64", "sha256": "b" * 64,
                               "version": "QEMU emulator", "arguments": ["-machine", "virt"]},
                  "images": {name: {"url": "https://example.invalid/" + name,
                                    "sha256": "c" * 64, "bytes": 100}
                             for name in ("rootfs", "kernel", "initrd")},
                  "source": {"commit": commit, "bundle_sha256": "d" * 64}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "provenance.json"
            path.write_text(json.dumps(record))
            result = module.system_emulator_provenance(path, commit)
            self.assertEqual(result["record"], record)
            self.assertTrue(result["host_provided"])
            with self.assertRaises(ValueError):
                module.system_emulator_provenance(path, "e" * 40)
            for field, value in (("execution_mode", "native"), ("emulation_kind", "user")):
                changed = {**record, field: value}
                path.write_text(json.dumps(changed))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    module.system_emulator_provenance(path, commit)
            path.write_text('{"schema":1,"schema":1}')
            with self.assertRaises(ValueError):
                module.system_emulator_provenance(path, commit)
            path.write_bytes(b" " * 65537)
            with self.assertRaises(ValueError):
                module.system_emulator_provenance(path, commit)

    def test_expected_failure_cannot_qualify_a_required_suite(self):
        module = runner_module()
        fixture = ("import unittest\nclass Case(unittest.TestCase):\n"
                   " @unittest.expectedFailure\n def test_incomplete(self): self.fail('not proven')\n"
                   "unittest.main()\n")
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "expected-failure.log"
            result = module.run([sys.executable, "-c", fixture], log)
            self.assertEqual(result["exit_code"], 0)
            self.assertEqual(result["outcome"], "fail")
            self.assertTrue(result["incomplete_checks"])
            self.assertIn("expected failures=1", log.read_text())

    def test_absent_artifact_is_a_failure_with_unrun_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "evidence.json"
            result = subprocess.run([sys.executable, str(ROOT / "tools/riscv64_test.py"),
                                     "--asm", str(Path(directory) / "absent"),
                                     "--execution-mode", "emulated", "--evidence", str(evidence)],
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(evidence.is_file(), result.stderr)
            report = json.loads(evidence.read_text())
            self.assertEqual(report["schema"], 2)
            self.assertEqual(report["qualification_scope"], "native-cli-behavior")
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(report["execution_mode"], "emulated")
            self.assertFalse(report["native_qualified"])
            self.assertEqual(report["checks"]["artifact"]["outcome"], "fail")
            self.assertEqual(report["checks"]["make_test"]["outcome"], "not-run")


if __name__ == "__main__":
    unittest.main()
