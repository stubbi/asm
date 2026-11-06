"""Exercise bounded backend replay without PostgreSQL or target execution.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import ModuleType, SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
METHOD = "test_simultaneous_searches_keep_request_data_separate"
PG = "/opt/asm/postgres/bin"
NATIVE = "/opt/asm/native-postgres/bin"


def response(index, status=200):
    value = {"schema": 0, "experimental": True, "packages": [{"name": f"fixture/p{index:02d}",
             "latest": "0.2.0", "summary": f"Assembly fixture {index:02d}", "license": "MIT",
             "owner_github_id": 12345, "targets": ["x86_64-linux"]}],
             "next_after": None, "order": "package-name-ascii"} if status == 200 else {"error": "unavailable"}
    raw = json.dumps(value).encode()
    return {"index": index, "query": "private query", "route": "private URL", "status": status,
            "headers": {"content-type": "application/json", "authorization": "private header"},
            "start_monotonic": 1.0, "end_monotonic": 1.1, "elapsed_seconds": 0.1,
            "body_bytes": len(raw), "body_sha256": hashlib.sha256(raw).hexdigest(),
            "body_base64": base64.b64encode(raw).decode(), "body_truncated": False,
            "body_redacted": False, "body_complete": True, "body_state": "complete", "exception": None}


class BackendTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/riscv64_reference_backend.py"
        self.assertTrue(path.is_file(), "The bounded HTTP backend replayer is absent")
        spec = importlib.util.spec_from_file_location("reference_backend", path)
        self.backend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.backend)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        (self.source / "test_server.py").write_text("# trusted synthetic fixture\n")
        (self.source / "local_postgres.py").write_text("# trusted synthetic administration\n")
        (self.source / "search.sql").write_bytes((ROOT / "experiments/assembly-server/search.sql").read_bytes())
        self.events, self.created = [], []
        self.fail_method = self.fail_setup = self.fail_cleanup = self.fail_teardown = False
        self.mutate_environment = self.mutate_files = self.late = False
        self.leave_process = self.bad_body = self.missing_trace = False
        self.mutate_source = False
        self.bad_evidence = False
        owner = self

        class Fixture(unittest.TestCase):
            attribution_config = SimpleNamespace(runner_deadline=time.monotonic() + 100)
            trace_config = object()

            @classmethod
            def setUpClass(cls):
                owner.created.append(cls)
                owner.events.append(("setup", os.environ["ASM_PROTO_PG_BINDIR"]))
                cls.addClassCleanup(cls.cleanup)
                if owner.fail_setup:
                    raise RuntimeError("private setup password")
                cls.cluster_live = cls.server_live = cls.proxy_live = True
                cls.cluster = SimpleNamespace(process=SimpleNamespace(pid=100 + len(owner.created),
                    poll=lambda: None if cls.cluster_live else 0), admin=object(), temp=object())
                cls.server = SimpleNamespace(pid=200 + len(owner.created), poll=lambda: None if cls.server_live else 0)
                cls.proxy = SimpleNamespace(thread=SimpleNamespace(is_alive=lambda: cls.proxy_live), workers=[],
                    listener=SimpleNamespace(fileno=lambda: 4 if cls.proxy_live else -1))
                cls.fixture_admin = SimpleNamespace(conn=object())
                cls.base = owner.source
                cls.fixture_ready = True
                cls.attribution = SimpleNamespace(record={"released": True, "target_ready": True,
                    "cleanup_errors": [], "returncode": 0, "pid": cls.server.pid})
                cls.diagnostic = SimpleNamespace(data={"simultaneous_searches": {"records": []}, "phase_traces": {}},
                                                 publish=lambda: None)
                cls.log = SimpleNamespace(flush=lambda: None, closed=False)
                cls.evidence = {"binary_sha256": "3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9",
                    "libpq_version": 160015, "database_version": "16.15", "schema_sha384": "e9fce69caa758cb9d15a700d92b76aba0fc3ca466a81624733124a742f2211aadae612ab877bd908a6e1d6ab5e803ef2",
                    "fixture": "owned-local-cluster"}
                if owner.bad_evidence:
                    cls.evidence["database_version"] = "18.6"

            @classmethod
            def cleanup(cls):
                owner.events.append(("cleanup", len(owner.created)))
                if owner.fail_cleanup:
                    raise OSError("private cleanup error")
                if getattr(cls, "cluster", None):
                    cls.cluster_live = owner.leave_process
                    cls.proxy_live = False
                    cls.cluster.admin = cls.cluster.temp = cls.fixture_admin.conn = None
                    cls.log.closed = True

            @classmethod
            def stop_server(cls):
                owner.events.append(("stop", len(owner.created)))
                cls.server_live = False

            @classmethod
            def tearDownClass(cls):
                owner.events.append(("teardown", len(owner.created)))
                if owner.fail_teardown:
                    raise RuntimeError("private teardown error")

            @staticmethod
            def _owned_server_stopped(proc, control):
                return True

            @classmethod
            def _collect_phase_trace(cls, label, path, records):
                owner.events.append(("trace", len(owner.created)))
                cls.diagnostic.data["phase_traces"][label] = {"qualification": "UNQUALIFIED",
                    "association": "complete", "records": [{"id": i, "index": i, "kind": 2} for i in range(1, 16 if owner.missing_trace else 17)],
                    "cohort_record_ids": {str(i): i for i in range(1, 17)}}

            def test_simultaneous_searches_keep_request_data_separate(self):
                owner.events.append(("method", len(owner.created)))
                failed = owner.fail_method and len(owner.created) == 2
                self.diagnostic.data["simultaneous_searches"]["records"] = [response(i, 503 if failed and i == 5 else 200) for i in range(1, 17)]
                if owner.bad_body and len(owner.created) == 2:
                    # Valid JSON and self-consistent digest, with the wrong release.
                    row = self.diagnostic.data["simultaneous_searches"]["records"][0]
                    raw = base64.b64decode(row["body_base64"]).replace(b"0.2.0", b"9.9.9")
                    row.update(body_base64=base64.b64encode(raw).decode(), body_sha256=hashlib.sha256(raw).hexdigest())
                if owner.mutate_environment:
                    os.environ["LD_LIBRARY_PATH"] = "/private/changed"
                if owner.mutate_source:
                    (owner.source / "test_server.py").write_text("# changed fixture\n")
                if failed:
                    raise KeyError("private provider text")

        module = ModuleType("backend_fixture")
        module.__file__ = str(self.source / "test_server.py")
        module.ServerTests = Fixture
        Fixture.__module__ = module.__name__
        self.fixture = Fixture
        self.native = ModuleType("riscv64_reference_native")
        self.native.BINDIR = Path(NATIVE)
        self.native.ROOT = Path("/opt/asm/native-postgres/rootfs")
        self.native.POSTGRES = self.native.ROOT / "usr/local/bin/postgres"
        self.native.verify_risc = lambda: {"outcome": "pass", "files": {"client": {"bytes": 1,
            "sha256": ("b" if self.mutate_files and len(self.created) else "a") * 64}},
            "postgres": {"bytes": 2, "sha256": "c" * 64, "elf_machine": 243}}
        self.native.inspect_native = lambda output, deadline: {"outcome": "pass", "postgres": {
            "bytes": 3, "sha256": "d" * 64, "elf_machine": 62}, "bindir": NATIVE}
        self.native.resource_snapshot = lambda: {"available": True, "cpu": {"usage_usec": 10, "user_usec": 6,
            "system_usec": 4, "nr_periods": 1, "nr_throttled": 0, "throttled_usec": 0},
            "memory_current": 100, "memory_peak": 200, "captured_monotonic": time.monotonic(),
            "memory_peak_scope": "whole-cgroup-lifetime-not-reset"}
        self.enterContext(mock.patch.dict(sys.modules, {module.__name__: module, self.native.__name__: self.native}))
        self.enterContext(mock.patch.dict(os.environ, {"ASM_PROTO_PG_BINDIR": PG,
            "ASM_PROTO_LIBPQ": "/opt/asm/postgres/lib/libpq.so.5", "LD_LIBRARY_PATH": "/opt/asm/mhd/lib:/opt/asm/postgres/lib",
            "QEMU_LD_PREFIX": "/", "ASM_PROTO_BUILD_DIR": str(self.source)}, clear=True))
        self.real_postmaster = self.backend._postmaster
        self.enterContext(mock.patch.object(self.backend, "_postmaster", return_value={"pid": 101, "outcome": "pass"}))

    def run_replay(self, deadline=None):
        return self.backend.run_backend_comparison(self.fixture, self.source, deadline or self.fixture.attribution_config.runner_deadline)

    def test_four_fresh_classes_run_one_method_in_abba_order_and_keep_64_records(self):
        report = self.run_replay()
        self.assertEqual(report["outcome"], "pass")
        self.assertEqual([value for event, value in self.events if event == "setup"], [PG, NATIVE, NATIVE, PG])
        self.assertEqual(len(set(self.created)), 4)
        self.assertEqual(sum(event == "method" for event, _ in self.events), 4)
        self.assertEqual(sum(event == "cleanup" for event, _ in self.events), 4)
        self.assertEqual([len(arm["records"]) for arm in report["arms"]], [16] * 4)
        self.assertTrue(all(row["expected_body_matches"] for arm in report["arms"] for row in arm["records"]))
        self.assertTrue(all(row["matching"] for row in report["paired_bodies"]))
        self.assertEqual(report["acceptance_tests_run"], 0)
        self.assertEqual(report["historical_original19"], "FAIL")
        self.assertFalse(report["application_qualified"] or report["native_qualified"] or report["release_qualified"])
        self.assertEqual(os.environ["ASM_PROTO_PG_BINDIR"], PG)
        self.assertFalse(getattr(self.fixture, "_class_cleanups", []))

    def test_failed_method_keeps_all_responses_and_failure_through_cleanup(self):
        self.fail_method = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "pass")
        self.assertEqual(report["http_assertions_outcome"], "fail")
        self.assertEqual([arm["method_outcome"] for arm in report["arms"]], ["pass", "fail", "pass", "pass"])
        self.assertEqual([arm["records"][4]["status"] for arm in report["arms"]], [200, 503, 200, 200])
        self.assertEqual(sum(event == "cleanup" for event, _ in self.events), 4)
        encoded = json.dumps(report)
        for forbidden in ("private provider", "private query", "private URL", "private header", "authorization"):
            self.assertNotIn(forbidden, encoded)

    def test_partial_setup_still_cleans_and_blocks_later_arms(self):
        self.fail_setup = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(sum(event == "cleanup" for event, _ in self.events), 1)
        self.assertEqual([arm["state"] for arm in report["arms"]][1:], ["not_run"] * 3)
        self.assertNotIn("private setup", json.dumps(report))

    def test_class_cleanup_exception_is_retained_and_prohibits_next_arm(self):
        self.fail_cleanup = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse(report["arms"][0]["cleanup_complete"])
        self.assertEqual(len(self.created), 1)
        self.assertTrue(any(row["stage"] == "class-cleanup" for row in report["arms"][0]["failures"]))

    def test_teardown_failure_does_not_skip_class_cleanup(self):
        self.fail_teardown = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(sum(event == "cleanup" for event, _ in self.events), 1)

    def test_expired_deadline_launches_no_arm(self):
        report = self.run_replay(time.monotonic() - 1)
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse(self.created)
        self.assertEqual([arm["state"] for arm in report["arms"]], ["not_run"] * 4)

    def test_changed_clients_or_environment_stop_comparison_and_restore_parent(self):
        for field in ("mutate_files", "mutate_environment"):
            with self.subTest(field=field):
                setattr(self, field, True)
                report = self.run_replay()
                self.assertEqual(report["outcome"], "fail")
                self.assertEqual(len(self.created), 1)
                self.assertEqual(os.environ["LD_LIBRARY_PATH"], "/opt/asm/mhd/lib:/opt/asm/postgres/lib")
                self.created.clear()
                setattr(self, field, False)

    def test_master_is_published_before_native_preflight_and_after_every_arm(self):
        seen = []
        original = self.native.inspect_native
        def inspect(output, deadline):
            path = self.source / "reference-backend/diagnostic.json"
            seen.append(json.loads(path.read_text()))
            return original(output, deadline)
        self.native.inspect_native = inspect
        report = self.run_replay()
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0]["outcome"], "fail")
        self.assertEqual(seen[0]["diagnostic_method_invocations"], 0)
        self.assertEqual(json.loads((self.source / "reference-backend/diagnostic.json").read_text()), report)

    def test_oversized_or_failed_publication_preserves_existing_report(self):
        destination = self.source / "report.json"
        destination.write_bytes(b"old evidence\n")
        with self.assertRaises(ValueError):
            self.backend._publish(destination, {"too_large": "x" * 1048576})
        self.assertEqual(destination.read_bytes(), b"old evidence\n")
        with mock.patch.object(self.backend.combined, "write_report", side_effect=OSError("private error")):
            with self.assertRaises(OSError):
                self.backend._publish(destination, {"outcome": "fail"})
        self.assertEqual(destination.read_bytes(), b"old evidence\n")

    def test_cleanup_returning_with_live_postmaster_is_not_complete(self):
        self.leave_process = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse(report["arms"][0]["cleanup_complete"])
        self.assertEqual(len(self.created), 1)

    def test_changed_fixture_bytes_block_the_next_arm(self):
        self.mutate_source = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(len(self.created), 1)
        self.assertFalse(report["arms"][0]["bindings_unchanged"])

    def test_equal_but_wrong_release_bodies_do_not_pass_independent_oracle(self):
        self.bad_body = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual([arm["records"][0]["expected_body_matches"] for arm in report["arms"]], [True, False, True, True])

    def test_late_final_publication_cannot_leave_passing_master(self):
        observed = [0.0]
        real_publish = self.backend._publish
        def late_publish(path, report):
            real_publish(path, report)
            if report["outcome"] == "pass":
                observed[0] = 101.0
        self.fixture.attribution_config.runner_deadline = 100.0
        with mock.patch.object(self.backend.time, "monotonic", side_effect=lambda: observed[0]), \
                mock.patch.object(self.backend, "_publish", side_effect=late_publish):
            report = self.run_replay(100.0)
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(json.loads((self.source / "reference-backend/diagnostic.json").read_text())["outcome"], "fail")

    def test_failed_late_correction_invalidates_passing_master(self):
        observed, passing = [0.0], [False]
        real_publish = self.backend._publish
        def late_publish(path, report):
            if passing[0]:
                raise OSError("private disk failure")
            real_publish(path, report)
            if report["outcome"] == "pass":
                passing[0], observed[0] = True, 101.0
        self.fixture.attribution_config.runner_deadline = 100.0
        with mock.patch.object(self.backend.time, "monotonic", side_effect=lambda: observed[0]), \
                mock.patch.object(self.backend, "_publish", side_effect=late_publish):
            with self.assertRaises(OSError):
                self.run_replay(100.0)
        self.assertFalse((self.source / "reference-backend/diagnostic.json").exists())

    def test_postmaster_identity_distinguishes_guest_elf_from_actual_qemu(self):
        case = SimpleNamespace(cluster=SimpleNamespace(process=SimpleNamespace(pid=10, poll=lambda: None)))
        target = {"bytes": 123, "sha256": "a" * 64, "elf_machine": 243}
        qemu = {"bytes": 4431192, "sha256": "be89e201dc6112ef101617ab575c95119ad123f80ca2b51b6c36ef218ac9df65", "elf_machine": 62}
        with mock.patch.object(self.backend, "_identity", side_effect=[qemu, target]):
            result = self.real_postmaster(case, "A", {"postgres": target}, {})
        self.assertEqual(result["declared_postgres"]["elf_machine"], 243)
        self.assertEqual(result["actual_executable"]["elf_machine"], 62)
        for actual in (dict(qemu, sha256="0" * 64), dict(qemu, elf_machine=243)):
            with self.subTest(actual=actual), mock.patch.object(self.backend, "_identity", side_effect=[actual, target]):
                with self.assertRaises(ValueError):
                    self.real_postmaster(case, "A", {"postgres": target}, {})

    def test_native_postmaster_requires_exact_actual_binary_and_path(self):
        case = SimpleNamespace(cluster=SimpleNamespace(process=SimpleNamespace(pid=10, poll=lambda: None)))
        target = {"bytes": 123, "sha256": "a" * 64, "elf_machine": 62}
        for matches_path in (True, False):
            proc_path = SimpleNamespace(resolve=lambda: self.native.POSTGRES.resolve() if matches_path else Path("/wrong/postgres"))
            with self.subTest(matches_path=matches_path), \
                    mock.patch.object(self.backend, "_identity", side_effect=[target, target]), \
                    mock.patch.object(self.backend, "Path", return_value=proc_path):
                if matches_path:
                    result = self.real_postmaster(case, "B", {}, {"postgres": target})
                    self.assertEqual(result["execution"], "native-amd64")
                else:
                    with self.assertRaises(ValueError):
                        self.real_postmaster(case, "B", {}, {"postgres": target})

    def test_invalid_response_json_retains_its_status_hash_and_timing(self):
        row = response(1)
        raw = b'{"incomplete":'
        row.update(body_base64=base64.b64encode(raw).decode(), body_bytes=len(raw),
                   body_sha256=hashlib.sha256(raw).hexdigest())
        kept = self.backend._row(row, 1)
        self.assertTrue(kept["recorded"])
        self.assertEqual(kept["status"], 200)
        self.assertEqual(kept["body_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(kept["elapsed_seconds"], 0.1)
        self.assertFalse(kept["expected_body_matches"])

    def test_request_error_metadata_retains_safe_stage_errno_without_error_text(self):
        row = response(1)
        row["exception"] = {"type": "OSError", "errno": 104, "stage": "transport", "message": "private password"}
        row["attribution_exception"] = {"type": "RuntimeError", "errno": None, "stage": "attribution", "text": "private URL"}
        kept = self.backend._row(row, 1)
        self.assertEqual(kept["exception"], {"type": "OSError", "errno": 104, "stage": "transport"})
        self.assertEqual(kept["attribution_exception"], {"type": "RuntimeError", "errno": None, "stage": "attribution"})
        self.assertNotIn("private", json.dumps(kept))

    def test_actual_fixture_version_evidence_is_retained_and_mismatch_stops_before_http(self):
        self.bad_evidence = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse(any(event == "method" for event, _ in self.events))
        self.assertEqual(len(self.created), 1)
        self.assertEqual(report["arms"][0]["fixture_evidence"]["database_version"], "18.6")

    def test_incomplete_resource_snapshot_stops_before_wave_and_preserves_partial_data(self):
        self.native.resource_snapshot = lambda: {"available": False, "cpu": {"usage_usec": 10}, "memory_current": 100}
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse(any(event == "method" for event, _ in self.events))
        self.assertEqual(report["arms"][0]["resources_before_http"]["cpu"]["usage_usec"], 10)

    def test_failed_postwave_resource_capture_still_retains_all_http_outcomes(self):
        original = self.native.resource_snapshot
        calls = [0]
        def snapshot():
            calls[0] += 1
            return original() if calls[0] == 1 else {"available": False, "cpu": {}}
        self.native.resource_snapshot = snapshot
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(len(report["arms"][0]["records"]), 16)
        self.assertEqual(len(self.created), 1)

    def test_complete_error_response_hash_is_verified(self):
        row = response(1, 503)
        row["body_sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            self.backend._row(row, 1)

    def test_incomplete_phase_evidence_prevents_measurement_pass(self):
        self.missing_trace = True
        report = self.run_replay()
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse(report["measurement_complete"])

    def test_late_arm_preserves_records_and_never_launches_next(self):
        observed = [0.0]
        original = self.fixture.test_simultaneous_searches_keep_request_data_separate
        def late(case):
            original(case)
            observed[0] = 101.0
        self.fixture.test_simultaneous_searches_keep_request_data_separate = late
        self.fixture.attribution_config.runner_deadline = 100.0
        with mock.patch.object(self.backend.time, "monotonic", side_effect=lambda: observed[0]):
            report = self.run_replay(100.0)
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(len(report["arms"][0]["records"]), 16)
        self.assertEqual(len(self.created), 1)


if __name__ == "__main__":
    unittest.main()
