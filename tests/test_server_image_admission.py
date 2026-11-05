"""Reject incomplete or mismatched actual-image admission evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
The reports are controlled metadata. These tests execute no container.
"""
import copy
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("admission_image", ROOT / "tools/test_server_image.py")
image = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = image
SPEC.loader.exec_module(image)


def part(name, count):
    return {"schema": 1, "status": "pass", "scope": "assembly-image-runtime-part", "suite": name,
            "architecture": "amd64", "os": "linux", "execution": "native", "source_revision": "c" * 40,
            "runtime_image_id": "sha256:" + "d" * 64, "qualification_image_id": "sha256:" + "e" * 64,
            "binary": {"machine": 62, "elf_flags": 0, "sha256": "a" * 64, "bytes": 40656,
                       "declared_target": {"isa": "x86_64", "os": "linux", "abi": "System V AMD64 LP64",
                                           "cpu_profile": "x86-64 baseline"},
                       "declaration_limit": "Declared application profile; ELF flags do not audit every instruction or qualify hardware and library CPU requirements."},
            "binary_permissions": {"mode": "0555", "uid": 0, "gid": 0},
            "executable_files": {"/usr/local/bin/asm-hub": "a" * 64,
                                 "/opt/asm/mhd/lib/libmicrohttpd.so.12": "b" * 64,
                                 "/opt/asm/postgres/lib/libpq.so.5": "f" * 64},
            "libraries": {"libmicrohttpd": "1.0.3", "libpq": "16.15"},
            "fixture": {"path": "/qualification/fixtures/connect-null.so", "sha256": "1" * 64,
                        "bytes": 16408, "mode": "0444", "uid": 0, "gid": 0},
            "security": {"uid": 65532, "gid": 65532, "read_only_root": True,
                         "effective_capabilities": 0, "no_new_privileges": True},
            "container_limits": {"cpus": 2, "memory_bytes": 536870912, "pids": 128,
                                 "tmpfs_bytes": 268435456, "tmpfs_noexec": True, "watchdog_seconds": 180},
            "tests_run": count, "tests_skipped": 0, "seconds": 2.0 if name == "baseline" else 3.0}


def parts():
    return {"baseline": part("baseline", 16), "capacity": part("capacity", 12)}


class AdmissionImageContractTests(unittest.TestCase):
    def aggregate(self, values=None):
        return image.aggregate_reports(parts() if values is None else values, "amd64", "c" * 40)

    def test_legacy_sixteen_case_receipt_cannot_qualify_admission(self):
        legacy = {"schema": 1, "status": "pass", "scope": "assembly-canonical-exports", "architecture": "amd64",
                  "os": "linux", "execution": "native", "source_revision": "c" * 40,
                  "tests_run": 16, "tests_skipped": 0}
        with self.assertRaises(ValueError):
            image.runtime_evidence_contract(legacy, "amd64", "c" * 40)

    def test_two_complete_parts_produce_twenty_eight_case_evidence(self):
        report = self.aggregate()
        self.assertEqual(report["scope"], "assembly-canonical-exports-admission")
        self.assertEqual(report["tests_run"], 28)
        self.assertEqual(report["tests_skipped"], 0)
        self.assertEqual(report["seconds"], 5.0)
        self.assertEqual(report["test_watchdog_seconds"], 360)
        self.assertEqual(set(report["parts"]), {"baseline", "capacity"})
        image.runtime_evidence_contract(report, "amd64", "c" * 40)

    def test_all_declared_targets_accept_complete_bound_parts(self):
        targets = (("amd64", 62, 0, "x86_64", "System V AMD64 LP64", "x86-64 baseline"),
                   ("arm64", 183, 0, "aarch64", "AAPCS64 LP64", "ARMv8-A"),
                   ("riscv64", 243, 5, "riscv64", "RISC-V LP64D", "RV64GC"))
        for arch, machine, flags, isa, abi, cpu in targets:
            with self.subTest(arch=arch):
                candidate = parts()
                for value in candidate.values():
                    value["architecture"] = arch
                    value["execution"] = "emulated" if arch == "riscv64" else "native"
                    value["binary"].update(machine=machine, elf_flags=flags,
                                           declared_target={"isa": isa, "os": "linux", "abi": abi, "cpu_profile": cpu})
                report = image.aggregate_reports(candidate, arch, "c" * 40)
                image.runtime_evidence_contract(report, arch, "c" * 40)
                self.assertEqual(report["tests_run"], 28)

    def test_twenty_seven_or_wrong_part_inventory_cannot_pass(self):
        invalid = [{"baseline": part("baseline", 16)}, {"capacity": part("capacity", 12)},
                   {"baseline": part("baseline", 16), "capacity": part("capacity", 11)},
                   {"baseline": part("baseline", 15), "capacity": part("capacity", 13)},
                   dict(parts(), extra=part("extra", 28)), list(parts().values())]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.aggregate(value)

    def test_each_part_must_bind_the_same_source_image_binary_libraries_and_fixture(self):
        changes = [("source_revision", "f" * 40), ("runtime_image_id", "sha256:" + "f" * 64),
                   ("qualification_image_id", "sha256:" + "f" * 64),
                   ("execution", "emulated"), ("suite", "baseline"),
                   ("binary", dict(part("capacity", 12)["binary"], sha256="f" * 64)),
                   ("fixture", dict(part("capacity", 12)["fixture"], sha256="f" * 64)),
                   ("libraries", {"libmicrohttpd": "1.0.3", "libpq": "18.6"}),
                   ("executable_files", dict(part("capacity", 12)["executable_files"],
                                             **{"/opt/asm/postgres/lib/libpq.so.5": "2" * 64})),
                   ("security", dict(part("capacity", 12)["security"], uid=0)),
                   ("container_limits", dict(part("capacity", 12)["container_limits"], watchdog_seconds=181))]
        for key, value in changes:
            with self.subTest(key=key):
                candidate = parts()
                candidate["capacity"][key] = value
                with self.assertRaises(ValueError):
                    self.aggregate(candidate)

    def test_matching_parts_cannot_hide_weaker_fixture_or_isolation(self):
        for key, field, value in (("fixture", "mode", "0644"), ("fixture", "uid", 65532),
                                  ("fixture", "path", "/tmp/connect-null.so"), ("fixture", "bytes", True),
                                  ("fixture", "sha256", "unknown"), ("security", "read_only_root", False),
                                  ("security", "effective_capabilities", True), ("container_limits", "cpus", 4),
                                  ("container_limits", "tmpfs_noexec", False),
                                  ("binary_permissions", "mode", "0777")):
            with self.subTest(key=key, field=field):
                candidate = parts()
                for report in candidate.values():
                    report[key][field] = value
                with self.assertRaises(ValueError):
                    self.aggregate(candidate)

    def test_skips_exclusions_and_malformed_counts_do_not_become_success(self):
        for key, value in (("tests_run", True), ("tests_run", 16.0), ("tests_run", "16"),
                           ("tests_skipped", 1), ("tests_skipped", False), ("schema", True),
                           ("seconds", float("nan")), ("seconds", -1), ("seconds", True),
                           ("seconds", 10 ** 400),
                           ("not_applicable", ["one case"]), ("excluded_tests", ["one case"]),
                           ("scope", "assembly-canonical-exports"), ("status", "fail")):
            with self.subTest(key=key, value=value):
                candidate = parts()
                candidate["baseline"][key] = value
                with self.assertRaises(ValueError):
                    self.aggregate(candidate)

    def test_publisher_revalidates_parts_and_total_instead_of_accepting_outer_labels(self):
        complete = self.aggregate()
        mutations = [("tests_run", 27), ("tests_run", 29), ("tests_skipped", False),
                     ("parts", {"baseline": part("baseline", 28)}),
                     ("scope", "assembly-canonical-exports"), ("test_watchdog_seconds", 361)]
        for key, value in mutations:
            with self.subTest(key=key):
                report = copy.deepcopy(complete)
                report[key] = value
                with self.assertRaises(ValueError):
                    image.runtime_evidence_contract(report, "amd64", "c" * 40)
        report = copy.deepcopy(complete)
        report["parts"]["capacity"]["fixture"]["sha256"] = "2" * 64
        with self.assertRaises(ValueError):
            image.runtime_evidence_contract(report, "amd64", "c" * 40)

    def test_publisher_cli_rejects_duplicate_fields_and_requires_complete_evidence(self):
        complete = self.aggregate()
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / "qualification.json"
            command = [sys.executable, str(ROOT / "tools/test_server_image.py"), "--check-evidence", str(evidence),
                       "--arch", "amd64", "--revision", "c" * 40]
            evidence.write_text(json.dumps(complete))
            accepted = subprocess.run(command, capture_output=True, timeout=5)
            self.assertEqual(accepted.returncode, 0, accepted.stderr.decode())
            self.assertEqual(accepted.stdout, b"")
            for raw in (json.dumps(complete).replace('"baseline": {', '"baseline": {}, "baseline": {', 1),
                        json.dumps(dict(complete, tests_run=27)),
                        json.dumps(dict(complete, scope="assembly-canonical-exports", tests_run=16))):
                with self.subTest(raw=raw[:80]):
                    evidence.write_text(raw)
                    rejected = subprocess.run(command, capture_output=True, timeout=5)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertEqual(rejected.stdout, b"")
            evidence.write_bytes(json.dumps(complete).encode("utf-16"))
            encoded = subprocess.run(command, capture_output=True, timeout=5)
            self.assertNotEqual(encoded.returncode, 0, "Evidence must retain its existing UTF-8 encoding boundary")

    def test_both_parts_keep_the_original_watchdog_and_container_bounds(self):
        args = argparse.Namespace(arch="amd64", revision="c" * 40, execution="native")
        common = {key: value for key, value in part("baseline", 16).items()
                  if key not in {"schema", "status", "scope", "suite", "tests_run", "tests_skipped", "seconds"}}
        runs = []
        def engine(command, **options):
            if command[:2] == ["docker", "run"]:
                name = command[command.index("--suite") + 1]
                runs.append((command, options["timeout"]))
                output = image.REPORT_PREFIX + json.dumps(part(name, 16 if name == "baseline" else 12)) + "\n"
                return subprocess.CompletedProcess(command, 0, output.encode(), b"raw case log\n")
            return subprocess.CompletedProcess(command, 0, b"", b"")
        with tempfile.TemporaryDirectory() as temporary, patch.object(image.subprocess, "run", side_effect=engine):
            directory = Path(temporary)
            reports = {name: image.run_image_part(args, common, name, directory) for name in ("baseline", "capacity")}
            self.assertEqual(self.aggregate(reports)["tests_run"], 28)
            self.assertEqual((directory / "baseline.stderr.log").read_bytes(), b"raw case log\n")
            self.assertEqual((directory / "capacity.stderr.log").read_bytes(), b"raw case log\n")
        self.assertEqual([timeout for _, timeout in runs], [180, 180])
        self.assertNotEqual(runs[0][0][runs[0][0].index("--name") + 1], runs[1][0][runs[1][0].index("--name") + 1])
        for command, _ in runs:
            for flag, value in (("--memory", "512m"), ("--cpus", "2"), ("--pids-limit", "128"),
                                ("--user", "65532:65532"), ("--network", "none"), ("--cap-drop", "ALL")):
                self.assertEqual(command[command.index(flag) + 1], value)
            self.assertIn("--read-only", command)
            self.assertIn("/tmp:rw,nosuid,nodev,noexec,size=256m,uid=65532,gid=65532,mode=0700", command)

    def test_timeout_retains_partial_output_without_a_success_report(self):
        args = argparse.Namespace(arch="amd64", revision="c" * 40, execution="native")
        common = part("baseline", 16)
        def engine(command, **options):
            if command[:2] == ["docker", "run"]:
                raise subprocess.TimeoutExpired(command, 180, output=b"partial stdout\n", stderr=b"first failure\n")
            return subprocess.CompletedProcess(command, 0, b"", b"")
        with tempfile.TemporaryDirectory() as temporary, patch.object(image.subprocess, "run", side_effect=engine):
            directory = Path(temporary)
            with self.assertRaisesRegex(ValueError, "180"):
                image.run_image_part(args, common, "baseline", directory)
            self.assertEqual((directory / "baseline.stdout.log").read_bytes(), b"partial stdout\n")
            self.assertEqual((directory / "baseline.stderr.log").read_bytes(), b"first failure\n")
            outcome = json.loads((directory / "baseline.outcome.json").read_text())
            self.assertEqual(outcome["status"], "fail")
            self.assertIs(outcome["timed_out"], True)
            self.assertFalse((directory / "baseline.qualification.json").exists())

    def test_failed_test_exit_retains_its_first_raw_failure(self):
        args = argparse.Namespace(arch="amd64", revision="c" * 40, execution="native")
        common = part("baseline", 16)
        def engine(command, **options):
            if command[:2] == ["docker", "run"]:
                return subprocess.CompletedProcess(command, 1, b"fixture stdout\n", b"first assertion failed\n")
            return subprocess.CompletedProcess(command, 0, b"", b"")
        with tempfile.TemporaryDirectory() as temporary, patch.object(image.subprocess, "run", side_effect=engine):
            directory = Path(temporary)
            with self.assertRaisesRegex(ValueError, "retained raw logs"):
                image.run_image_part(args, common, "baseline", directory)
            self.assertEqual((directory / "baseline.stderr.log").read_bytes(), b"first assertion failed\n")
            self.assertEqual((directory / "baseline.stdout.log").read_bytes(), b"fixture stdout\n")
            outcome = json.loads((directory / "baseline.outcome.json").read_text())
            self.assertEqual(outcome["exit_code"], 1)
            self.assertIs(outcome["timed_out"], False)
            self.assertEqual(outcome["status"], "fail")

    def test_preflight_failure_replaces_a_previous_success_with_failed_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "qualification.json"
            output.write_text('{"status":"pass"}\n')
            args = argparse.Namespace(arch="amd64", revision="c" * 40, execution="native", output=str(output))
            with patch.object(image.platform, "machine", return_value="wrong-target"), self.assertRaises(ValueError):
                image.qualify(args)
            self.assertEqual(json.loads(output.read_text())["status"], "fail")


if __name__ == "__main__":
    unittest.main()
