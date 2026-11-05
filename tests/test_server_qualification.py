"""Reject missing runtime evidence and mismatched server ELF policies.

SPDX-License-Identifier: AGPL-3.0-or-later
Synthetic ELF fixtures are inspected only; they are never executed.
"""
import importlib.util
import io
import json
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("server_port_evidence", ROOT / "tools/record_server_ports.py")
record = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(record)
FAILURE_SPEC = importlib.util.spec_from_file_location("server_build_failures", ROOT / "tools/test_server_build_failures.py")
failures = importlib.util.module_from_spec(FAILURE_SPEC)
FAILURE_SPEC.loader.exec_module(failures)


def elf(machine=62, flags=0):
    data = bytearray(320)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 3, machine, 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<I", data, 48, flags)
    struct.pack_into("<HHH", data, 52, 64, 56, 4)
    headers = [(1, 5, 0, 0, 0, 320, 320, 4096),
               (2, 6, 288, 288, 288, 32, 32, 8),
               (0x6474E552, 4, 288, 288, 288, 32, 32, 1),
               (0x6474E551, 6, 0, 0, 0, 0, 0, 16)]
    for number, header in enumerate(headers):
        struct.pack_into("<IIQQQQQQ", data, 64 + number * 56, *header)
    struct.pack_into("<qQqQ", data, 288, 30, 8, 0, 0)
    return data


class ServerQualificationTests(unittest.TestCase):
    def recorder_inputs(self, work):
        binary = work / "server"
        binary.write_bytes(elf())
        for name, count in (("native-link", 8), ("reference", 19), ("hosted", 11)):
            (work / (name + "-tests.log")).write_text(f"Ran {count} tests in 1.0s\n\nOK\n")
        (work / "build-failure-tests.log").write_text('{"status":"pass","tests":4}\n')
        output = work / "qualification.json"
        arguments = ["record_server_ports.py", "--target", "x86_64-linux", "--execution", "native",
                     "--revision", "a" * 40, "--job-status", "success", "--asm", str(binary),
                     "--reference", str(binary), "--hosted", str(binary),
                     "--archive", str(work / "source.tar.gz"), "--output", str(output)]
        return arguments, output

    def run_recorder(self, arguments):
        def tool_result(command, **_):
            text = "a" * 40 + "\n" if "rev-parse" in command else ("" if "status" in command else "fixture tool\n")
            return SimpleNamespace(returncode=0, stdout=text, stderr="")
        linux = platform.uname_result("Linux", "fixture", "fixture", "fixture", "x86_64")
        with patch.object(sys, "argv", arguments), patch.object(record.platform, "uname", return_value=linux), \
                patch.object(record.subprocess, "run", side_effect=tool_result):
            return record.main()

    def test_reference_suite_requires_all_nineteen_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            arguments, output = self.recorder_inputs(work)
            manifest = (b'[package]\nname = "asm-server"\nversion = "0.1.0"\n'
                        b'[build]\nsource = "server.s"\ntarget = "x86_64-linux"\n')
            files = {"asm.toml": manifest, "server.s": b".text\n",
                     "README.md": b"Assembly server fixture.\n", "LICENSE": b"AGPL-3.0-or-later\n"}
            with tarfile.open(work / "source.tar.gz", "w:gz") as archive:
                for name, data in files.items():
                    member = tarfile.TarInfo(name)
                    member.mode = 0o644
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
            for count, expected, status in ((19, 0, "pass"), (18, 1, "fail")):
                with self.subTest(count=count):
                    (work / "reference-tests.log").write_text(f"Ran {count} tests in 1.0s\n\nOK\n")
                    self.assertEqual(self.run_recorder(arguments), expected)
                    report = json.loads(output.read_text())
                    self.assertEqual(report["status"], status)
                    self.assertEqual(report["tests"]["reference"]["status"], status)

    def test_missing_source_archive_cannot_receive_a_pass_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            arguments, output = self.recorder_inputs(Path(temporary))
            self.assertEqual(self.run_recorder(arguments), 1)
            report = json.loads(output.read_text())
            self.assertEqual(report["artifacts"]["source_archive"]["status"], "unrun")

    def test_archive_and_log_read_errors_still_produce_failed_json(self):
        for archive in (True, False):
            with self.subTest(archive=archive), tempfile.TemporaryDirectory() as temporary:
                work = Path(temporary)
                arguments, output = self.recorder_inputs(work)
                unreadable = work / ("source.tar.gz" if archive else "native-link-tests.log")
                unreadable.write_bytes(b"exists")
                method = "read_bytes"
                original = getattr(Path, method)
                def read(path, *args, **kwargs):
                    if path == unreadable:
                        raise PermissionError("fixture read denied")
                    return original(path, *args, **kwargs)
                with patch.object(Path, method, autospec=True, side_effect=read):
                    try:
                        result = self.run_recorder(arguments)
                    except OSError as error:
                        self.fail(f"Read failure escaped instead of retaining JSON: {error}")
                self.assertEqual(result, 1)
                report = json.loads(output.read_text())
                check = report["artifacts"]["source_archive"] if archive else report["tests"]["native-link"]
                self.assertEqual(check["status"], "fail")
                self.assertIn("fixture read denied", check["reason"])

    def test_nonobject_build_failure_report_still_produces_failed_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            arguments, output = self.recorder_inputs(work)
            (work / "build-failure-tests.log").write_text("[]\n")
            try:
                result = self.run_recorder(arguments)
            except (AttributeError, TypeError) as error:
                self.fail(f"Malformed evidence escaped instead of retaining JSON: {error}")
            self.assertEqual(result, 1)
            self.assertEqual(json.loads(output.read_text())["tests"]["failure_preservation"]["status"], "fail")

    def test_unrelated_build_failure_does_not_qualify_an_abi_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            binary = work / "app"
            binary.write_bytes(b"previous executable\n")
            with self.assertRaisesRegex(AssertionError, "intentional"):
                failures.reject_build([sys.executable, "-c", "raise SystemExit(1)"], work, binary)

    def test_target_elf_and_hardening_are_checked_independently(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "server"
            for target, machine, flags in (("x86_64-linux", 62, 0), ("aarch64-linux", 183, 0),
                                           ("riscv64-linux", 243, 5)):
                with self.subTest(target=target):
                    path.write_bytes(elf(machine, flags))
                    self.assertEqual(record.artifact(path, target, server=True)["status"], "pass")
            changes = [(16, "<H", 2), (236, "<I", 7), (216, "<Q", 0), (296, "<Q", 0)]
            for offset, encoding, value in changes:
                with self.subTest(offset=offset):
                    data = elf()
                    struct.pack_into(encoding, data, offset, value)
                    path.write_bytes(data)
                    with self.assertRaises(ValueError):
                        record.artifact(path, "x86_64-linux", server=True)

    def test_riscv_integer_and_unknown_abis_do_not_qualify_as_lp64d(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "server"
            for flags in (0, 1, 2, 3, 6, 7, 8, 13):
                with self.subTest(flags=flags):
                    path.write_bytes(elf(243, flags))
                    with self.assertRaises(ValueError):
                        record.artifact(path, "riscv64-linux", server=True)

    def test_absent_empty_failed_and_skipped_test_logs_are_not_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "tests.log"
            self.assertEqual(record.tests(path, 6)["status"], "unrun")
            for text in ("", "Ran 0 tests in 0.001s\n\nOK\n", "Ran 8 tests in 1.0s\n\nFAILED (errors=1)\n",
                         "Ran 8 tests in 1.0s\n\nOK (skipped=1)\n",
                         "Ran 8 tests in 1.0s\n\nOK\nRan 8 tests in 1.0s\n"):
                with self.subTest(text=text):
                    path.write_text(text)
                    self.assertEqual(record.tests(path, 6)["status"], "fail")
            path.write_text("Ran 8 tests in 1.0s\n\nOK\n")
            self.assertEqual(record.tests(path, 6)["status"], "pass")


if __name__ == "__main__":
    unittest.main()
