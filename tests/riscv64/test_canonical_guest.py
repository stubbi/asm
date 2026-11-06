"""Mock-only guest boundary and original-method collector checks.

SPDX-License-Identifier: AGPL-3.0-or-later
No assembly executable, PostgreSQL server, container, or target code runs here.
"""
from contextlib import ExitStack, nullcontext
import copy
import io
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import canonical_riscv_phases as core


def complete_report():
    """Controlled full transport fixture; no product execution or provider data."""
    import canonical_riscv_guest as guest
    spec = importlib.util.spec_from_file_location("guest_trace_fixture", ROOT / "tests/riscv64/test_canonical_trace.py")
    fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
    records = [fixture.trace_record(index) for index in range(1, 9)]
    for value in records:
        for name in ("start_ns", "created_ns", "connect_ns", "finish_ns", "end_ns"): value[name] += 410
        for phase in value["phases"]:
            for name in ("send_ns", "result_ns", "drain_ns"): phase[name] += 410
    raw = b"".join(fixture.trace_line(value) for value in records)
    metadata = {"bytes": 1, "sha256": "1" * 64}
    http = [{"schema": 1, "ordinal": index + 1, "route": index % 4 + 1, "status": 200,
             "bytes": 3, "sha256": hashlib.sha256(b"ok\n").hexdigest(), "elapsed_ns": 1,
             "transport": "complete", "bytes_equal": True, "media_ok": True, "cache_ok": True,
             "nosniff_ok": True, "lf_ok": True, "size_ok": True, "declared_bytes": 3} for index in range(8)]
    files = {"cpu.max": "200000 100000\n", "cpu.stat": "usage_usec 1\nuser_usec 1\nsystem_usec 0\nnr_periods 1\nnr_throttled 0\nthrottled_usec 0\n",
             "memory.events": "oom 0\noom_kill 0\n", "memory.current": "1000\n", "memory.peak": "2000\n", "memory.max": "536870912\n"}
    arms = []
    for label, low in (("control", 100), ("traced", 400)):
        arm = {"label": label, "collector_complete": True, "application_passed": True,
               "original_method": "RuntimeTests." + core.METHOD, "ordinal_semantics": guest.ORDINAL,
               "preload": label == "traced", "source_revision": core.CANONICAL,
               "http": copy.deepcopy(http), "http_summary": core.http_contract(http),
               "cohort_start_ns": low + 10, "cohort_end_ns": low + 100,
               "before": {"phase": "before", "monotonic_ns": low, "files": dict(files)},
               "after": {"phase": "after", "monotonic_ns": low + 200, "files": dict(files)},
               "original_result": dict.fromkeys(guest.RESULTS, 0), "original_method_completed": True,
               "cleanup": {"complete": True, "exit_status": -15, "forced": False}, "elapsed_ns": 200}
        arm["original_result"]["tests_run"] = 1
        arm["resources"] = core.resource_assessment(arm["before"], arm["after"])
        arms.append(arm)
    value = {"schema": 1, "scope": core.SCOPE, "qualification": "UNQUALIFIED", "collector_complete": True,
             "application_qualified": False, "native_qualified": False, "release_qualified": False,
             "canonical_revision": core.CANONICAL, "diagnostic_revision": "2" * 40, "arms": arms, "cleanup_complete": True,
             "limits": list(guest.LIMITS), "elapsed_ns": 700, "started_ns": 1, "guest_deadline_ns": 180000000001, "cleanup_reserve_seconds": 15,
             "inputs": {"canonical_revision": core.CANONICAL, "diagnostic_revision": "2" * 40, "sdk_revision": core.SDK_REVISION,
                        "trees": dict.fromkeys(("source", "runner", "sdk"), "3" * 64), "observer": dict(metadata), "observer_test": dict(metadata),
                        "started_ns": 1, "deadline_ns": 600000000001},
             "build": {"identity": dict(metadata), "outputs": {name: dict(metadata, elf_machine=243, elf_flags=5, mode="0555") for name in guest.OUTPUTS},
                       "failed_canonical_equality": "unestablished", "source_rebuilt": True},
             "runtime_inventory": {"current": {"/usr/bin/python3.11": dict(metadata, resolved_path="/usr/bin/python3.11", comparison_to_failed_run="unestablished")},
                                   "failed_canonical_equality": "unestablished", "ldd_output": {key: dict(metadata) for key in ("server", "postgres", "python")},
                                   "libraries": {key: dict(metadata, failed_canonical_equality="unestablished") for key in guest.LIBRARIES}},
             "preflight": {key: {"process": {"outcome": "pass", "exit_code": 0, "failure": None, "bytes": 1, "seconds": 0.01}, "output": dict(metadata)}
                           for key in ("abi-check", "canonical_trace_check")},
             "trace": {"valid": True, "complete": True, "records": records, "cohort_ids": list(range(1, 9)), "route_association": "unknown", "failure_reason": None,
                       "identity": {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}}}
    smoke = fixture.trace_record(1)
    smoke_bytes = fixture.trace_line(smoke)
    value["preflight"]["abi-check"]["process"]["bytes"] = 0
    value["preflight"]["abi-check"]["output"] = {"bytes": 0, "sha256": hashlib.sha256(b"").hexdigest()}
    value["preflight"]["canonical_trace_check"]["process"]["bytes"] = len(smoke_bytes)
    value["preflight"]["canonical_trace_check"]["output"] = {"bytes": len(smoke_bytes), "sha256": hashlib.sha256(smoke_bytes).hexdigest()}
    value["preflight"]["canonical_trace_check"]["records"] = [smoke]
    return value, raw


class Socket:
    def __init__(self, payload, timeout=False):
        self.payload, self.timeout = payload, timeout
        self.closed, self.sent = False, bytearray()
    def __enter__(self): return self
    def __exit__(self, *_): self.closed = True
    def settimeout(self, _): pass
    def sendall(self, data): self.sent.extend(data)
    def setsockopt(self, *_): pass
    def close(self): self.closed = True
    def recv_into(self, target):
        if callable(self.payload): self.payload = self.payload(bytes(self.sent))
        if not self.payload and self.timeout: raise TimeoutError("private provider text")
        count = min(len(target), len(self.payload))
        target[:count], self.payload = self.payload[:count], self.payload[count:]
        return count


class CanonicalGuestTests(unittest.TestCase):
    def guest(self):
        path = ROOT / "tools/canonical_riscv_guest.py"
        self.assertTrue(path.is_file(), "The canonical guest collector is not implemented.")
        spec = importlib.util.spec_from_file_location("canonical_guest_tests", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def fixture(self):
        sys.path.insert(0, str(ROOT / "server"))
        import test_runtime
        class Cohort(unittest.TestCase):
            exports = dict.fromkeys(core.ROUTES, b"ok\n")
            port = 12345
            @classmethod
            def raw_request(cls, *_): raise AssertionError("Original transport must be replaced only for the cohort.")
        setattr(Cohort, core.METHOD, test_runtime.RuntimeTests.__dict__[core.METHOD])
        return Cohort

    def test_original_concurrent_method_retains_all_eight_refusals_without_tracebacks(self):
        guest, cls = self.guest(), self.fixture()
        payload = (b"HTTP/1.1 503 Unavailable\r\nContent-Length: 3\r\nContent-Type: application/json\r\n"
                   b"Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\nok\n")
        sockets = []
        def connect(*_, **__):
            value = Socket(payload); sockets.append(value); return value
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        original = cls.__dict__["raw_request"]
        with patch.object(guest.socket, "create_connection", side_effect=connect):
            report = guest._run_cohort(cls, time.monotonic() + 10, budget)
        self.assertEqual(len(report["http"]), 8)
        self.assertEqual(report["original_result"]["tests_run"], 1)
        self.assertEqual(report["original_result"]["failures"], 8)
        self.assertEqual(report["http_summary"]["availability_failures"], 8)
        self.assertIs(cls.__dict__["raw_request"], original)
        self.assertTrue(all(value.closed for value in sockets))
        self.assertNotIn("Traceback", json.dumps(report))
        self.assertTrue(all(value["sha256"] == hashlib.sha256(b"ok\n").hexdigest() for value in report["http"]))

    def test_partial_body_timeouts_keep_actual_attempt_bytes_and_original_error(self):
        guest, cls = self.guest(), self.fixture()
        payload = b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nfirst"
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        with patch.object(guest.socket, "create_connection", side_effect=lambda *_, **__: Socket(payload, True)):
            report = guest._run_cohort(cls, time.monotonic() + 10, budget)
        self.assertGreaterEqual(len(report["http"]), 1)
        self.assertLessEqual(len(report["http"]), 8)
        self.assertTrue(all(value["transport"] == "timeout" and value["bytes"] == 5 and
                            value["sha256"] == hashlib.sha256(b"first").hexdigest() for value in report["http"]))
        self.assertEqual(report["original_result"]["errors"], 1)
        self.assertNotIn("private", json.dumps(report))

    def test_deadline_interrupt_escapes_original_case_result(self):
        guest = self.guest()
        class Case(unittest.TestCase):
            def test_timeout(self): raise guest.GuestDeadline()
        result = guest.NumericResult()
        with self.assertRaises(guest.GuestDeadline): Case("test_timeout").run(result)

    def test_guest_environment_rejects_wrong_platform_and_ambient_credentials_before_processes(self):
        guest = self.guest()
        with patch.object(guest.platform, "system", return_value="Darwin"), self.assertRaises(ValueError):
            guest._guest_contract(Path("/inputs"))
        with ExitStack() as stack:
            stack.enter_context(patch.object(guest.platform, "system", return_value="Linux"))
            stack.enter_context(patch.object(guest.platform, "machine", return_value="riscv64"))
            stack.enter_context(patch.object(guest.os, "geteuid", return_value=65532))
            stack.enter_context(patch.object(guest.os, "getegid", return_value=65532))
            stack.enter_context(patch.dict(guest.os.environ, {"LD_PRELOAD": "private-unapproved"}, clear=True))
            with self.assertRaisesRegex(ValueError, "^The bounded canonical guest is incomplete\\.$"):
                guest._guest_contract(Path("/inputs"))

    def test_trace_export_is_numeric_only_and_missing_summaries_remain_inconclusive(self):
        guest = self.guest()
        fixture_spec = importlib.util.spec_from_file_location("trace_fixture_guest", ROOT / "tests/riscv64/test_canonical_trace.py")
        fixture = importlib.util.module_from_spec(fixture_spec); fixture_spec.loader.exec_module(fixture)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for count in (8, 7):
                source, output = base / (str(count) + ".log"), base / (str(count) + ".safe")
                data = b"".join(fixture.trace_line(fixture.trace_record(i)) for i in range(1, count + 1))
                source.write_bytes(b"private provider line\n" + data)
                report = guest._trace(source, output, 1, 42)
                self.assertEqual(report["complete"], count == 8)
                self.assertEqual(output.read_bytes(), data)
                self.assertNotIn("private", json.dumps(report))
                self.assertEqual(len(report["cohort_ids"]), count)
            source, output = base / "invalid.log", base / "invalid.safe"
            source.write_bytes(b"private invalid provider text\n")
            report = guest._trace(source, output, 1, 42)
            self.assertFalse(report["complete"])
            self.assertEqual(output.read_bytes(), b"")
            self.assertEqual(report["raw_identity"]["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertNotIn("private", json.dumps(report))

    def test_existing_work_directory_is_preserved_without_a_new_report(self):
        guest = self.guest()
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / "existing"; work.mkdir()
            marker = work / "keep"; marker.write_bytes(b"retained")
            with patch.object(guest, "WORK", work), patch.object(guest, "_guest_contract"), patch.object(guest.sys, "stdout", SimpleNamespace(buffer=io.BytesIO())):
                self.assertEqual(guest.run_inside(Path("/inputs"), work / "qualification.json"), 1)
            self.assertFalse((work / "qualification.json").exists())
            self.assertEqual(marker.read_bytes(), b"retained")

    def test_expired_cleanup_budget_still_kills_the_owned_application(self):
        guest = self.guest()
        process = SimpleNamespace(returncode=None, terminated=False, killed=False)
        process.poll = lambda: process.returncode
        process.wait = lambda **_: process.returncode
        process.terminate = lambda: setattr(process, "terminated", True)
        def kill(): process.killed = True; process.returncode = -9
        process.kill = kill
        budget = SimpleNamespace(remaining=lambda *_, **__: (_ for _ in ()).throw(ValueError("expired")))
        try:
            value = guest._stop(process, budget, time.monotonic() - 1)
        except Exception:
            self.fail("Expired cleanup skipped the owned application's kill attempt.")
        self.assertTrue(process.terminated and process.killed and value["forced"])

    def test_failed_preflight_retains_only_output_identity(self):
        guest = self.guest()
        private = b"private provider text\n"
        def run(arguments, log, **kwargs):
            self.assertNotIn("LD_PRELOAD=", " ".join(map(str, arguments)))
            log.write_bytes(private)
            return {"outcome": "fail", "bytes": len(private), "seconds": 0.01, "exit_code": 1, "failure": None}
        modules = SimpleNamespace(combined=SimpleNamespace(bounded_process=run))
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        retained = {}
        with tempfile.TemporaryDirectory() as directory:
            try:
                guest._preflight(Path("/inputs"), modules, {}, budget, time.monotonic() + 10, Path(directory), retained)
            except ValueError:
                pass
            except Exception:
                self.fail("Failed preflight did not retain its bounded output identity.")
            self.assertEqual(retained["abi-check"]["output"], {"bytes": len(private), "sha256": hashlib.sha256(private).hexdigest()})
            self.assertNotIn("private", json.dumps(retained))
            self.assertFalse(list(Path(directory).iterdir()))

    def test_original_httpconnection_request_wire_is_preserved(self):
        guest, cls = self.guest(), self.fixture()
        sockets = []
        def connect(*_, **__):
            value = Socket(b"HTTP/1.1 503 Unavailable\r\nContent-Length: 3\r\n\r\nok\n")
            sockets.append(value); return value
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        with patch.object(guest.socket, "create_connection", side_effect=connect):
            guest._run_cohort(cls, time.monotonic() + 10, budget)
        for value in sockets:
            path = bytes(value.sent).split(b" ", 2)[1]
            self.assertEqual(bytes(value.sent), b"GET " + path + b" HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nAccept-Encoding: identity\r\n\r\n")

    def test_expected_failure_cannot_be_reported_as_application_success(self):
        guest, cls = self.guest(), self.fixture()
        original = cls.__dict__[core.METHOD]
        @unittest.expectedFailure
        def selected(self):
            original(self)
            self.fail("private assertion text")
        setattr(cls, core.METHOD, selected)
        def payload(request):
            media = b"application/json" if b"/registry/v1/index.json " in request else b"text/tab-separated-values; charset=utf-8"
            return b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Type: " + media + b"\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\nok\n"
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        with patch.object(guest.socket, "create_connection", side_effect=lambda *_, **__: Socket(payload)):
            report = guest._run_cohort(cls, time.monotonic() + 10, budget)
        self.assertTrue(report["http_summary"]["application_passed"])
        self.assertEqual(report["original_result"]["expected_failures"], 1)
        self.assertFalse(report["application_passed"])

    def test_transport_exception_keeps_original_error_and_only_actual_attempts(self):
        guest, cls = self.guest(), self.fixture()
        count, lock = 0, __import__("threading").Lock()
        def connect(*_, **__):
            nonlocal count
            with lock:
                count += 1
                timeout = count == 1
            return Socket(b"" if timeout else b"HTTP/1.1 503 Unavailable\r\nContent-Length: 3\r\n\r\nok\n", timeout)
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        with patch.object(guest.socket, "create_connection", side_effect=connect):
            report = guest._run_cohort(cls, time.monotonic() + 10, budget)
        self.assertEqual(len(report["http"]), count)
        self.assertGreaterEqual(count, 1)
        self.assertLessEqual(count, 8)
        self.assertEqual(sum(value["transport"] == "timeout" for value in report["http"]), 1)
        self.assertEqual(report["original_result"]["errors"], 1)
        self.assertFalse(report["application_passed"])
        self.assertNotIn("private", json.dumps(report))

    def minimal_report(self, guest):
        return {"schema": 1, "scope": core.SCOPE, "qualification": "UNQUALIFIED", "collector_complete": False,
                "application_qualified": False, "native_qualified": False, "release_qualified": False,
                "canonical_revision": core.CANONICAL, "arms": [], "cleanup_complete": False,
                "failure_reason": "guest-contract", "limits": list(guest.LIMITS), "elapsed_ns": 1}

    def test_closed_report_schema_rejects_private_nested_fields_and_keeps_partial_outcomes(self):
        guest, cls = self.guest(), self.fixture()
        self.assertTrue(callable(getattr(guest, "validate_guest_report", None)), "The closed publication schema is missing.")
        value = self.minimal_report(guest)
        self.assertEqual(guest.validate_guest_report(value), value)
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        with patch.object(guest.socket, "create_connection", side_effect=lambda *_, **__: Socket(b"", True)):
            cohort = guest._run_cohort(cls, time.monotonic() + 10, budget)
        arm = dict(cohort, label="control", collector_complete=False, application_passed=False,
                   original_method="RuntimeTests." + core.METHOD,
                   ordinal_semantics="HTTP call-entry ordinal; not submission or completion order", preload=False, elapsed_ns=10)
        arm["http"] = arm["http"][:3]; arm.pop("http_summary", None)
        value["arms"] = [arm]
        self.assertEqual(guest.validate_guest_report(value), value)
        for mutate in (lambda v: v.update(provider_text="private"),
                       lambda v: v["arms"][0]["http"][0].update(body="private"),
                       lambda v: v["arms"][0]["original_result"].update(traceback="private"),
                       lambda v: v["arms"][0].update(failure_reason="private provider text"),
                       lambda v: v["limits"].append("private")):
            invalid = copy.deepcopy(value); mutate(invalid)
            with self.assertRaisesRegex(ValueError, "^The bounded canonical guest is incomplete\\.$"):
                guest.validate_guest_report(invalid)

    def test_emission_exports_only_closed_report_and_revalidated_numeric_trace(self):
        guest = self.guest()
        self.assertTrue(hasattr(guest, "LIMITS"), "The exact publication limits are missing.")
        report = self.minimal_report(guest)
        sink = io.BytesIO()
        with patch.object(guest.sys, "stdout", SimpleNamespace(buffer=sink)):
            guest._emit(report)
        line = sink.getvalue()
        self.assertEqual(line.count(guest.GUEST_PREFIX), 1)
        self.assertEqual(json.loads(line[len(guest.GUEST_PREFIX):]), report)
        invalid = copy.deepcopy(report); invalid["provider"] = "private"
        with patch.object(guest.sys, "stdout", SimpleNamespace(buffer=io.BytesIO())), self.assertRaises(ValueError):
            guest._emit(invalid)

    def test_complete_report_rejects_private_fields_in_every_bound_nested_channel(self):
        guest = self.guest()
        report, _ = complete_report()
        self.assertEqual(guest.validate_guest_report(report), report)
        mutators = (
            lambda v: v["inputs"]["observer"].update(path="private"),
            lambda v: v["build"]["outputs"]["asm-hub"].update(command="private"),
            lambda v: v["runtime_inventory"]["ldd_output"].update(raw="private"),
            lambda v: v["runtime_inventory"]["current"]["/usr/bin/python3.11"].update(provider="private"),
            lambda v: v["preflight"]["abi-check"]["process"].update(stderr="private"),
            lambda v: v["trace"]["records"][0]["phases"][0].update(sql="private"),
            lambda v: v["arms"][0]["resources"].update(stderr="private"),
            lambda v: v["arms"][0]["before"]["files"].update(extra="private"),
        )
        for mutate in mutators:
            invalid = copy.deepcopy(report); mutate(invalid)
            with self.assertRaises(ValueError): guest.validate_guest_report(invalid)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "safe.log"
            _, raw = complete_report(); source.write_bytes(raw)
            sink = io.BytesIO()
            with patch.object(guest.sys, "stdout", SimpleNamespace(buffer=sink)):
                guest._emit(report, source)
            first, retained = sink.getvalue().split(b"\n", 1)
            self.assertEqual(json.loads(first[len(guest.GUEST_PREFIX):]), report)
            self.assertEqual(retained, raw)

    def test_after_snapshot_precedes_stop_and_snapshot_failure_still_stops_owned_app(self):
        guest = self.guest()
        fixture, _ = complete_report()
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        for fail_snapshot in (False, True):
            events = []
            with tempfile.TemporaryDirectory() as directory:
                cls = SimpleNamespace(base=Path(directory), server=object(), log=io.BytesIO())
                cls.setUpClass = lambda: events.append("setup")
                def snapshot(_, phase):
                    events.append(phase)
                    if phase == "after" and fail_snapshot: raise ValueError("private")
                    value = copy.deepcopy(fixture["arms"][0][phase]); value["monotonic_ns"] = time.monotonic_ns()
                    return value
                def cohort(*_):
                    events.append("cohort")
                    value = copy.deepcopy(fixture["arms"][0]); value["cohort_start_ns"] = time.monotonic_ns(); value["cohort_end_ns"] = time.monotonic_ns()
                    return {key: value[key] for key in ("cohort_start_ns", "cohort_end_ns", "http", "http_summary", "original_result", "original_method_completed", "application_passed")}
                def stop(*_): events.append("stop"); return {"complete": True, "exit_status": 0, "forced": False}
                with patch.object(guest, "_probe"), patch.object(guest.core, "snapshot", side_effect=snapshot), patch.object(guest, "_run_cohort", side_effect=cohort), patch.object(guest, "_stop", side_effect=stop):
                    if fail_snapshot:
                        with self.assertRaises(ValueError): guest._run_arm(cls, None, "control", budget, time.monotonic() + 10, {}, initialize=True)
                    else:
                        result = {}; guest._run_arm(cls, None, "control", budget, time.monotonic() + 10, result, initialize=True)
                        self.assertTrue(result["collector_complete"])
                self.assertEqual(events, ["setup", "before", "cohort", "after", "stop"])

    def test_guest_cleanup_still_reaps_owned_database_after_application_stop_error(self):
        guest = self.guest()
        fixture, _ = complete_report()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); context = base / "inputs"; build_dir = context / "canonical-build"; build_dir.mkdir(parents=True)
            for name in guest.OUTPUTS:
                path = build_dir / name; path.write_bytes(b"x"); path.chmod(0o555)
            (build_dir / "manifest.json").write_bytes(b"{}")
            work = base / "evidence"
            now = time.monotonic_ns()
            receipt = copy.deepcopy(fixture["inputs"]); receipt.update(started_ns=now, deadline_ns=now + 600000000000)
            class RuntimeBase:
                @classmethod
                def environment(cls, **changes): return changes
            runtime = SimpleNamespace(RuntimeTests=RuntimeBase)
            events = []
            def arm(cls, runtime, name, budget, deadline, report, **kwargs):
                report.update(copy.deepcopy(fixture["arms"][0])); report["collector_complete"] = False
                cls.server, cls.base, cls.log = object(), base, io.BytesIO()
                raise ValueError("private failure")
            def stopped(*_): events.append("app-stop"); raise OSError("private stop error")
            def cleaned(*_): events.append("database-cleanup"); return True
            def preflight(*args): args[-1].update(copy.deepcopy(fixture["preflight"]))
            sink = io.BytesIO()
            with ExitStack() as stack:
                for target, name, replacement in ((guest, "WORK", work), (guest, "_guest_contract", lambda *_: None),
                    (core, "context_contract", lambda *_, **__: (receipt, object())), (core, "build_contract", lambda *_: fixture["build"]),
                    (guest, "_watchdog", lambda *_: nullcontext()), (guest, "_inventory", lambda *_: fixture["runtime_inventory"]),
                    (guest, "_preflight", preflight), (guest, "_runtime", lambda *_: runtime), (guest, "_run_arm", arm),
                    (guest, "_stop", stopped), (guest, "_cleanup_fixture", cleaned), (guest.sys, "stdout", SimpleNamespace(buffer=sink))):
                    stack.enter_context(patch.object(target, name, replacement))
                stack.enter_context(patch.dict(guest.os.environ, {}, clear=True))
                self.assertEqual(guest.run_inside(context, work / "qualification.json"), 1)
            self.assertEqual(events, ["app-stop", "database-cleanup"])
            report = json.loads(sink.getvalue()[len(guest.GUEST_PREFIX):])
            self.assertFalse(report["cleanup_complete"])
            self.assertNotIn("private", json.dumps(report))

    def test_cohort_retains_three_second_inactivity_with_shared_outer_deadline(self):
        guest, cls = self.guest(), self.fixture()
        calls = []
        original = core.read_http
        deadline = time.monotonic() + 10
        def observed(*args, **kwargs):
            calls.append((kwargs["deadline"], kwargs.get("inactivity")))
            return original(*args, **kwargs)
        now = time.monotonic_ns(); budget = core.Budget(now, now + 600000000000)
        with patch.object(guest.socket, "create_connection", side_effect=lambda *_, **__: Socket(b"HTTP/1.1 503 Unavailable\r\nContent-Length: 3\r\n\r\nok\n")), patch.object(core, "read_http", side_effect=observed):
            report = guest._run_cohort(cls, deadline, budget)
        self.assertEqual(calls, [(deadline, 3)] * 8)
        self.assertEqual(len(report["http"]), 8)

    def test_complete_join_rejects_missing_smoke_record_and_wrong_builder_mode_type(self):
        guest = self.guest()
        complete, _ = complete_report()
        self.assertEqual(guest.validate_guest_report(complete), complete)
        for mutate in (lambda v: v["build"]["outputs"]["asm-hub"].update(mode=0o555),
                       lambda v: v["preflight"]["canonical_trace_check"].pop("records"),
                       lambda v: v["preflight"]["abi-check"]["process"].update(exit_code=1)):
            invalid = copy.deepcopy(complete); mutate(invalid)
            with self.assertRaises(ValueError): guest.validate_guest_report(invalid)


if __name__ == "__main__":
    unittest.main()
