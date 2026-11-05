"""Keep the retained-server diagnostic bounded and explicitly unqualified.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import importlib.util
import io
from contextlib import redirect_stdout
import json
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


class ObservationTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/riscv64_server_observations.py"
        self.assertTrue(path.is_file(), "The bounded retained-server diagnostic is absent")
        spec = importlib.util.spec_from_file_location("observations", path)
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)

    def test_zip_member_requires_original_archive_digest_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "input.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr("selected", b"original")
            output = base / "selected"
            with self.assertRaises(ValueError):
                self.runner.extract_zip_member(archive, output, "selected", 8,
                    hashlib.sha256(b"original").hexdigest(), archive.stat().st_size, "0" * 64)
            self.assertFalse(output.exists())

    def test_zip_member_rejects_duplicate_link_traversal_and_wrong_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            for case in ("duplicate", "link", "traversal", "size"):
                archive = base / (case + ".zip")
                with zipfile.ZipFile(archive, "w") as stream:
                    entry = zipfile.ZipInfo("selected")
                    if case == "link":
                        entry.create_system = 3
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    stream.writestr(entry, b"x")
                    if case == "duplicate":
                        # Different names must also be unambiguous after normalization.
                        stream.writestr("./selected", b"x")
                    if case == "traversal":
                        stream.writestr("../outside", b"x")
                output = base / (case + ".out")
                with self.subTest(case=case), self.assertRaises(ValueError):
                    self.runner.extract_zip_member(archive, output, "selected", 2 if case == "size" else 1,
                        hashlib.sha256(b"x").hexdigest(), archive.stat().st_size,
                        hashlib.sha256(archive.read_bytes()).hexdigest())
                self.assertFalse(output.exists())

    def test_zip_member_selects_only_the_requested_original_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "input.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr("selected", b"original")
                stream.writestr("unneeded", b"do not extract")
            output = base / "output"
            self.runner.extract_zip_member(archive, output, "selected", 8,
                hashlib.sha256(b"original").hexdigest(), archive.stat().st_size,
                hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(output.read_bytes(), b"original")
            self.assertFalse((base / "unneeded").exists())

    def test_image_archive_binds_config_platform_and_rejects_preload(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "image.tar"
            for changes in ({}, {"architecture": "amd64"}, {"config": None}, {"config": {"Env": ["LD_PRELOAD=/trace.so"]}},
                            {"config": {"Env": ["GITHUB_TOKEN=private"]}}):
                config = {"architecture": "riscv64", "os": "linux", "config": {"Env": ["HOME=/nonexistent"]},
                          "rootfs": {"type": "layers", "diff_ids": []}, **changes}
                raw = json.dumps(config).encode()
                digest = hashlib.sha256(raw).hexdigest()
                with tarfile.open(archive, "w") as stream:
                    for name, data in (("manifest.json", json.dumps([{"Config": "blobs/sha256/" + digest, "Layers": []}]).encode()),
                                       ("blobs/sha256/" + digest, raw)):
                        entry = tarfile.TarInfo(name)
                        entry.size = len(data)
                        stream.addfile(entry, io.BytesIO(data))
                if not changes:
                    self.assertEqual(self.runner.image_archive_contract(archive, "sha256:" + digest)["architecture"], "riscv64")
                else:
                    with self.subTest(changes=changes), self.assertRaises(ValueError):
                        self.runner.image_archive_contract(archive, "sha256:" + digest)
                with self.assertRaises(ValueError):
                    self.runner.image_archive_contract(archive, "sha256:" + "0" * 64)

    def test_json_records_reject_duplicate_fields_and_nonobjects(self):
        for data in (b'{"schema":1,"schema":1}', b'[]', b'null'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.runner.load_object(data)

    def test_library_mismatch_is_rejected_before_loading(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "library.so"
            library.write_bytes(b"different library")
            with self.assertRaises(ValueError):
                self.runner.library_contract(library, "0" * 64)

    def test_every_report_remains_unqualified_and_retains_original_failure(self):
        report = self.runner.initial_report()
        self.assertEqual(report["qualification"], "UNQUALIFIED")
        self.assertEqual(report["target"], "riscv64-linux")
        self.assertFalse(report["application_qualified"])
        self.assertFalse(report["native_qualified"])
        self.assertFalse(report["release_qualified"])
        self.assertEqual(report["original_19_test_gate"], "fail")
        self.assertEqual(sum(item["tests"] for item in report["not_run"]), 5)
        self.assertEqual(report["limits"]["cleanup_reserve_seconds"], 90)
        self.assertEqual(report["limits"]["attached_runtime_seconds_cap"], 600)

    def test_phase_report_labels_added_arms_without_clearing_the_original_gate(self):
        report = self.runner.initial_report(phase_probe=True)
        self.assertEqual(report["scope"], "retained-riscv64-reference-server-phase-probe")
        self.assertEqual(report["comparison_order"], ["direct", "proxy"])
        self.assertEqual(report["original_19_test_gate"], "fail")
        self.assertEqual(report["limits"]["suite_seconds"], 180)
        self.assertFalse(report["application_qualified"])

    def test_phase_log_summary_cannot_publish_body_or_arbitrary_error_text(self):
        private = "postgresql://private-password@private-host/database"
        guest = {"outcome": "fail", "error": private,
                 "server_tests": {"tests_run": 14, "exit_code": 1}}
        record = {"index": 5, "status": 503, "elapsed_seconds": 1.9,
                  "body_base64": private, "exception": private}
        trace = {"id": 1, "index": 5, "kind": -1, "start_ns": 100, "end_ns": 200,
                 "first_api": 1, "first_return": 0, "first_errno": 0, "sqlstate": private}
        observation = {"simultaneous_searches": {"records": [record]},
                       "phase_traces": {"main": {"association": private, "records": [trace]}}}
        summary = self.runner.sanitized_phase_summary(guest, observation)
        self.assertNotIn(private, json.dumps(summary))
        self.assertEqual(summary["qualification"], "UNQUALIFIED")
        self.assertEqual(summary["original_19_test_gate"], "fail")
        self.assertEqual(summary["cohorts"][0]["http"],
                         [{"index": 5, "status": 503, "elapsed_us": 1900000}])
        self.assertEqual(summary["cohorts"][0]["association"], "inconclusive")

    def test_phase_log_summary_keeps_invalid_nested_shapes_inconclusive(self):
        summary = self.runner.sanitized_phase_summary({"server_tests": None},
            {"simultaneous_searches": None, "controlled_search_comparison": {"arms": None},
             "phase_traces": {"main": None}})
        self.assertIsNone(summary["tests_run"])
        self.assertEqual([wave["association"] for wave in summary["cohorts"]], ["inconclusive"] * 3)

    def test_host_helper_retention_is_bounded_and_preserves_existing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, output = base / "source", base / "retained"
            source.write_bytes(b"reviewed helper bytes")
            self.runner.retain_host_file(source, output, limit=64)
            self.assertEqual(output.read_bytes(), source.read_bytes())
            source.write_bytes(b"other bytes")
            with self.assertRaises(ValueError):
                self.runner.retain_host_file(source, output, limit=64)
            self.assertEqual(output.read_bytes(), b"reviewed helper bytes")
            source.write_bytes(b"x" * 65)
            with self.assertRaises(ValueError):
                self.runner.retain_host_file(source, base / "oversized", limit=64)
            self.assertFalse((base / "oversized").exists())
            link = base / "link"
            link.symlink_to(source)
            with self.assertRaises(ValueError):
                self.runner.retain_host_file(link, base / "linked", limit=128)
            self.assertFalse((base / "linked").exists())

    def test_forwarding_check_does_not_run_an_unverified_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            trace = base / "trace"
            trace.mkdir()
            previous = base / "trace-forwarding.log"
            previous.write_bytes(b"earlier evidence")
            with mock.patch.object(self.runner.combined, "bounded_process") as child:
                result = self.runner.trace_smoke(trace, base)
            child.assert_not_called()
            self.assertEqual(result["outcome"], "fail")
            self.assertEqual(result["qualification"], "UNQUALIFIED")
            self.assertEqual(previous.read_bytes(), b"earlier evidence")

    def test_incomplete_phase_collection_still_emits_a_private_failure_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            private = "postgresql://private-password@private-host/database"
            (base / "qualification.json").write_text(json.dumps({"error": private, "server_tests": None}))
            report = {"failure_stage": "runtime", "collection": {
                "collected": ["qualification.json"], "errors": {"server_package.log": private}}}
            output = io.StringIO()
            with redirect_stdout(output):
                self.runner.publish_phase_summary(report, base)
            self.assertNotIn(private, output.getvalue())
            summary = json.loads((base / "phase-summary.json").read_text())
            self.assertEqual(summary["host"]["failure_stage"], "runtime")
            self.assertFalse(summary["host"]["collection_complete"])
            self.assertEqual(summary["original_19_test_gate"], "fail")

    def test_late_final_report_io_cannot_leave_a_passing_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            clock = [599.0]
            report = self.runner.initial_report()
            report["outcome"] = "pass"
            writer = self.runner.combined.write_report
            def slow_write(path, value):
                writer(path, value)
                clock[0] += 2
            with mock.patch.object(self.runner.time, "monotonic", side_effect=lambda: clock[0]), \
                 mock.patch.object(self.runner.combined, "write_report", side_effect=slow_write):
                self.runner.finish_host_report(report, output, started=0, deadline=600, phase_probe=False)
            retained = json.loads((output / "UNQUALIFIED-host-report.json").read_text())
            self.assertEqual(retained["outcome"], "fail")
            self.assertTrue(retained["host_deadline_exceeded"])
            self.assertFalse(retained["application_qualified"])

    def _host_failure_scenario(self, base, *, extraction_seconds=0, create_timeout=False):
        """Replace only unavailable Docker; retain real host files and failure reports."""
        context = base / "context"
        context.mkdir()
        server_zip = base / "server.zip"
        with zipfile.ZipFile(server_zip, "w") as packed:
            packed.writestr("qualification.json", json.dumps({"retained_artifacts": {
                "asm-server-riscv64-linux": {"sha256": self.runner.SERVER_SHA}}}))
        clock, calls = [0.0], []
        image_config = {"rootfs": {"diff_ids": []}, "config": {"Env": []}}
        image = {"Id": self.runner.IMAGE_ID, "Architecture": "riscv64", "Os": "linux",
                 "RootFS": {"Layers": []}, "Config": {"Env": []}}
        container = {"Image": self.runner.IMAGE_ID, "Config": {"User": "65532:65532", "Env": []},
                     "HostConfig": {"NetworkMode": "none", "Memory": 2147483648, "NanoCpus": 2000000000,
                                    "PidsLimit": 256, "CapDrop": ["ALL"], "SecurityOpt": ["no-new-privileges"]},
                     "Mounts": [{"Destination": "/inputs", "Source": str(context.resolve()), "RW": False, "Type": "bind"}]}
        def extraction(archive, output, *arguments):
            output.write_bytes(b"retained bytes")
            if output.name == "image.tar":
                clock[0] += extraction_seconds
        def command(arguments, *, timeout=30, **kwargs):
            calls.append((arguments[1], timeout))
            if arguments[1] == "load":
                clock[0] += timeout
            elif arguments[1] == "image":
                clock[0] += timeout
                return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps([image]).encode())
            elif arguments[1] == "inspect":
                clock[0] += timeout
                return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps([container]).encode())
            elif arguments[1] == "create":
                clock[0] += timeout
                if create_timeout:
                    raise subprocess.TimeoutExpired(arguments[0], timeout)
            else:
                clock[0] += timeout
            return subprocess.CompletedProcess(arguments, 0, stdout=b"")
        def runtime(arguments, log, *, timeout, **kwargs):
            calls.append(("runtime", timeout))
            clock[0] += timeout
            log.write_text("retained runtime failure\n")
            return {"outcome": "fail", "failure": "deadline", "exit_code": -9}
        def collect(arguments, filename, destination, budget, *, timeout, **kwargs):
            calls.append(("collect", timeout))
            clock[0] += timeout
            raise ValueError("The failed container has no requested record.")
        output = base / "evidence"
        with mock.patch.object(self.runner, "extract_zip_member", side_effect=extraction), \
             mock.patch.object(self.runner, "image_archive_contract", return_value=image_config), \
             mock.patch.object(self.runner.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(self.runner.combined, "command", side_effect=command), \
             mock.patch.object(self.runner.combined, "bounded_process", side_effect=runtime), \
             mock.patch.object(self.runner.combined, "collect_file", side_effect=collect):
            result = self.runner.run_image(base / "image.zip", server_zip, context, output)
        return result, json.loads((output / "UNQUALIFIED-host-report.json").read_text()), calls

    def test_shared_host_deadline_reserves_collection_after_runtime_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, calls = self._host_failure_scenario(Path(temporary))
            self.assertEqual(result, 1)
            self.assertEqual(dict(calls)["runtime"], 300)
            self.assertEqual([kind for kind, _ in calls][-5:], ["stop", "collect", "collect", "collect", "rm"])
            self.assertEqual(report["host_elapsed_seconds"], 600)
            self.assertEqual(report["outcome"], "fail")
            self.assertTrue(all(timeout > 0 for _, timeout in calls))

    def test_source_io_cannot_start_docker_after_the_operation_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, calls = self._host_failure_scenario(Path(temporary), extraction_seconds=510)
            self.assertEqual(result, 1)
            self.assertEqual(calls, [])
            self.assertIn("operation deadline", report["error"])
            self.assertEqual(report["host_elapsed_seconds"], 510)

    def test_ambiguous_create_timeout_still_attempts_collection_and_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, calls = self._host_failure_scenario(Path(temporary), create_timeout=True)
            self.assertEqual(result, 1)
            self.assertNotIn("runtime", [kind for kind, _ in calls])
            self.assertEqual([kind for kind, _ in calls][-5:], ["stop", "collect", "collect", "collect", "rm"])
            self.assertEqual(report["outcome"], "fail")
            self.assertLessEqual(report["host_elapsed_seconds"], 600)

    def test_container_contract_rejects_a_weaker_boundary_before_start(self):
        original = {"Image": self.runner.IMAGE_ID, "Config": {"User": "65532:65532", "Env": ["LC_ALL=C"]},
                    "HostConfig": {"NetworkMode": "none", "Memory": 2147483648, "NanoCpus": 2000000000,
                                   "PidsLimit": 256, "CapDrop": ["ALL"], "SecurityOpt": ["no-new-privileges"]},
                    "Mounts": [{"Destination": "/inputs", "RW": False, "Type": "bind"}]}
        self.runner.container_contract(original)
        for section, key, value in ((None, "Image", "sha256:other"), ("Config", "User", "0:0"),
                                    ("HostConfig", "NetworkMode", "bridge"), ("HostConfig", "Memory", 0),
                                    ("HostConfig", "NanoCpus", 0), ("HostConfig", "PidsLimit", 512),
                                    ("HostConfig", "CapDrop", []), ("HostConfig", "SecurityOpt", []),
                                    ("Config", "Env", ["GITHUB_TOKEN=secret"])):
            changed = json.loads(json.dumps(original))
            (changed[section] if section else changed)[key] = value
            with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                self.runner.container_contract(changed)
        changed = json.loads(json.dumps(original))
        changed["Mounts"][0]["RW"] = True
        with self.assertRaises(ValueError):
            self.runner.container_contract(changed)

    def test_observation_retains_exact_bytes_and_requires_failed_server_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            build = base / "build"
            directory = build / "reference-causal-one"
            directory.mkdir(parents=True)
            record = {"schema": 1, "scope": "reference-server-causal-diagnostic", "qualification": "UNQUALIFIED",
                      "base_commit": self.runner.BASE_REVISION,
                      "runtime": {"sha256": self.runner.SERVER_SHA, "bytes": self.runner.SERVER_BYTES}}
            data = json.dumps(record).encode() + b"\n"
            (directory / "diagnostic.json").write_bytes(data)
            output = base / "saved/qualification.json"
            receipt = self.runner.retain_observation(build, output)
            self.assertEqual(output.read_bytes(), data)
            self.assertEqual(receipt["sha256"], hashlib.sha256(data).hexdigest())
            record["runtime"]["sha256"] = "0" * 64
            (directory / "diagnostic.json").write_text(json.dumps(record))
            with self.assertRaises(ValueError):
                self.runner.retain_observation(build, output)
            self.assertEqual(output.read_bytes(), data)

    def test_missing_fourteenth_test_or_skip_cannot_pass(self):
        for text in ("Ran 13 tests in 1.0s\n\nOK\n", "Ran 14 tests in 1.0s\n\nOK (skipped=1)\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.runner.combined.suite_contract(text, 14)

    def test_failed_inside_setup_retains_a_nonzero_scoped_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "qualification.json"
            result = subprocess.run([sys.executable, str(ROOT / "tools/riscv64_server_observations.py"),
                                     "--inside", "--output", str(output)], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads(output.read_text())
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(report["qualification"], "UNQUALIFIED")
            self.assertIn("error", report)

    def test_real_suite_failure_stays_nonzero_with_all_fourteen_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            source.mkdir()
            body = "import unittest\nclass ServerTests(unittest.TestCase):\n"
            for i in range(14):
                body += f"    def test_{i:02d}(self): self.assertTrue({i != 0})\n"
            (source / "test_server.py").write_text(body)
            result = self.runner.run_server_suite(source, base / "server_package.log")
            self.assertEqual(result["outcome"], "fail")
            self.assertNotEqual(result["exit_code"], 0)
            self.assertIn("Ran 14 tests", (base / "server_package.log").read_text())

    def test_oversized_or_multiple_observations_preserve_prior_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            build = base / "build"
            build.mkdir()
            directory = build / "reference-causal-first"
            directory.mkdir()
            original = directory / "diagnostic.json"
            original.write_bytes(b" " * (1024 * 1024 + 1))
            output = base / "qualification.json"
            output.write_bytes(b"prior evidence")
            with self.assertRaises(ValueError):
                self.runner.retain_observation(build, output)
            self.assertEqual(output.read_bytes(), b"prior evidence")
            original.write_text("{}")
            second = build / "reference-causal-second"
            second.mkdir()
            (second / "diagnostic.json").write_text("{}")
            with self.assertRaises(ValueError):
                self.runner.retain_observation(build, output)
            self.assertEqual(output.read_bytes(), b"prior evidence")


if __name__ == "__main__":
    unittest.main()
