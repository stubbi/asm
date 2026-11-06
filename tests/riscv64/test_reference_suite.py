"""Check registration binding and the reference-suite lifecycle.

SPDX-License-Identifier: AGPL-3.0-or-later
No package, PostgreSQL, Docker, or target executable runs in these tests.
"""
import hashlib
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
METHODS = (
    "test_a_stalled_database_does_not_stall_liveness",
    "test_configuration_rejects_nonregular_public_and_malformed_files",
    "test_connection_cap_bounds_http_threads_and_recovers",
    "test_fixture_retains_reference_records_and_query_limits",
    "test_health_and_declared_dependency_boundary",
    "test_query_rejects_duplicates_unknown_fields_controls_and_oversize",
    "test_readiness_loses_permissions_and_recovers",
    "test_real_pagination_does_not_drop_or_repeat_packages",
    "test_search_uses_parameters_and_literal_matching",
    "test_shutdown_is_bounded_with_a_stalled_database",
    "test_simultaneous_searches_keep_request_data_separate",
    "test_startup_rejects_migrator_and_missing_grants",
    "test_unknown_route_method_and_body_fail_without_database_writes",
    "test_uri_and_header_limits",
)


def elf(machine=243, flags=5):
    data = bytearray(176)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, 3, machine, 1, 0, 64, 0, flags, 64, 56, 2, 0, 0, 0)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 4, 0, 0, 0, len(data), len(data), 4096)
    struct.pack_into("<IIQQQQQQ", data, 120, 0x6474E551, 6, 0, 0, 0, 0, 0, 16)
    return bytes(data)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/riscv64_reference_suite.py"
        self.assertTrue(path.is_file(), "The reference suite registration adapter is absent")
        spec = importlib.util.spec_from_file_location("reference_suite", path)
        self.suite = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.suite)
        self.inputs = {"revision": "1" * 40, "fixture_revision": "2" * 40}
        self.record = {"schema": 1, "scope": "asm-riscv64-binfmt-registration",
            "source_revision": self.inputs["revision"], "fixture_revision": self.inputs["fixture_revision"],
            "run_id": "42063015630", "captured_at": "2026-11-05T12:00:00+00:00",
            "registration_path": "/proc/sys/fs/binfmt_misc/qemu-riscv64",
            "registration_text": self.suite.REGISTRATION_TEXT,
            "emulator_sha256": self.suite.EMULATOR_SHA256, "emulator_bytes": 4431192,
            "server_sha256": self.suite.SERVER_SHA256, "fixture_sha256": "3" * 64}

    def test_exact_registration_record_is_accepted(self):
        self.suite.registration_contract(self.record, self.inputs, "3" * 64)

    def test_unknown_missing_wrong_types_and_pins_are_rejected(self):
        cases = [dict(self.record, extra=1), {key: value for key, value in self.record.items() if key != "schema"}]
        cases += [dict(self.record, **{key: value}) for key, value in (
            ("schema", True), ("schema", 1.0), ("scope", "other"), ("run_id", 42), ("run_id", "x"),
            ("source_revision", "4" * 40), ("fixture_revision", "4" * 40),
            ("registration_path", "/tmp/untrusted"), ("emulator_bytes", True), ("emulator_bytes", 4431193),
            ("emulator_sha256", "0" * 64), ("server_sha256", "0" * 64), ("fixture_sha256", "0" * 64),
            ("registration_text", self.record["registration_text"].replace("POF", "F")),
            ("registration_text", self.record["registration_text"] + "\n"),
            ("registration_text", "x" * 1025), ("registration_text", {"command": "untrusted"}))]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.suite.registration_contract(value, self.inputs, "3" * 64)

    def test_utc_timestamp_is_validated(self):
        self.suite.registration_contract(dict(self.record, captured_at="2026-11-05T12:00:00Z"), self.inputs, "3" * 64)
        for value in (None, 3, "", "2026-11-05T12:00:00", "2026-11-05T12:00:00+01:00", "2026-13-05T12:00:00Z"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.suite.registration_contract(dict(self.record, captured_at=value), self.inputs, "3" * 64)

    def test_json_reader_rejects_nonstandard_numeric_constants(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "record.json"
            path.write_text('{"unused":NaN}')
            with self.assertRaises(ValueError):
                self.suite.read_object(path)

    def test_capture_checks_actual_files_and_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            context = base / "context"
            (context / "source").mkdir(parents=True)
            fixture = context / "source/test_server.py"
            fixture.write_bytes(b"exact fixture\n")
            (context / "input-manifest.json").write_text(json.dumps(self.inputs))
            registration = base / "registration"
            registration.write_text(self.suite.REGISTRATION_TEXT)
            emulator = base / "emulator"
            emulator.write_bytes(elf(62, 0))
            alias = base / "alias"
            alias.symlink_to(emulator)
            with mock.patch.object(self.suite, "REGISTRATION_FILE", registration), \
                 mock.patch.object(self.suite, "EMULATOR_FILE", emulator), \
                 mock.patch.object(self.suite, "REGISTERED_ALIAS", alias), \
                 mock.patch.object(self.suite, "EMULATOR_BYTES", emulator.stat().st_size), \
                 mock.patch.object(self.suite, "EMULATOR_SHA256", hashlib.sha256(emulator.read_bytes()).hexdigest()), \
                 mock.patch.object(self.suite.platform, "system", return_value="Linux"), \
                 mock.patch.object(self.suite.platform, "machine", return_value="x86_64"):
                result = self.suite.capture_registration(context, run_id="123")
                output = context / "binfmt-registration.json"
                self.assertEqual(json.loads(output.read_text()), result)
                self.assertEqual(result["fixture_sha256"], hashlib.sha256(fixture.read_bytes()).hexdigest())
                self.assertEqual(output.stat().st_mode & 0o777, 0o444)
                original = output.read_bytes()
                with self.assertRaises(ValueError):
                    self.suite.capture_registration(context, run_id="124")
                self.assertEqual(output.read_bytes(), original)
                output.unlink()
                emulator.write_bytes(elf(62, 0)[:-1] + b"x")
                with self.assertRaises(ValueError):
                    self.suite.capture_registration(context, run_id="125")
                self.assertFalse(output.exists())


class SuiteLifecycleTests(unittest.TestCase):
    setUp = RegistrationTests.setUp
    def fixture(self, base, deadline, *, fail=False, comparison_error=False, teardown_error=False,
                cleanup_error=False, setup_error=False, subtest_error=False, expected_failure=False, skip=False):
        import riscv64_reference_build as producer
        context = base / "context"
        source, trace = context / "source", context / "trace"
        source.mkdir(parents=True)
        trace.mkdir()
        events = base / "events"
        fixture = f'''from dataclasses import dataclass
from pathlib import Path
import unittest
EVENTS=Path({str(events)!r})
def mark(value):
    with EVENTS.open("a") as output: output.write(value+"\\n")
def cleanup():
    mark("class_cleanup")
    {"raise RuntimeError('private cleanup URL')" if cleanup_error else "pass"}
mark("import")
@dataclass
class BinfmtFifoConfig:
    registration: dict
    runner_deadline: float
@dataclass
class PhaseTraceConfig:
    library_path: object
    sha256: str
    read_records: object
class ServerTests(unittest.TestCase):
    attribution_config=None
    trace_config=None
    @classmethod
    def setUpClass(cls):
        mark("setup")
        cls.addClassCleanup(cleanup)
        {"raise RuntimeError('private setup password')" if setup_error else "pass"}
        assert cls.attribution_config.runner_deadline=={deadline!r}
        assert callable(cls.trace_config.read_records)
    @classmethod
    def run_controlled_search_comparison(cls):
        mark("comparison")
        {"raise RuntimeError('private comparison URL')" if comparison_error else "pass"}
    @classmethod
    def tearDownClass(cls):
        mark("teardown")
        {"raise RuntimeError('private teardown password')" if teardown_error else "pass"}
'''
        for index, name in enumerate(METHODS):
            statement = "self.skipTest('private reason')" if skip and index == 0 else f"self.assertTrue({not (fail and index == 0)}, 'private assertion password')"
            if subtest_error and index == 0:
                statement = "with self.subTest(query='private query'):\n            self.fail('private password')"
            if expected_failure and index == 0:
                fixture += "    @unittest.expectedFailure\n"
                statement = "self.fail('private expected failure')"
            fixture += f"    def {name}(self):\n        mark({name!r})\n        {statement}\n"
        path = source / "test_server.py"
        path.write_text(fixture)
        (context / "input-manifest.json").write_text(json.dumps(dict(self.inputs, test_methods=list(METHODS))))
        value = dict(self.record, fixture_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        registration = context / "binfmt-registration.json"
        registration.write_text(json.dumps(value))
        library = trace / "reference_libpq_trace.so"
        library.write_bytes(elf())
        output = producer.elf_contract(library, shared=True)
        manifest = {"schema": 1, "scope": producer.BUILD_SCOPE, "qualification": "UNQUALIFIED",
                    "outcome": "pass", "target": "riscv64-linux", "isa": "RV64GC", "abi": "LP64D",
                    "outputs": {name: output for name in ("reference_libpq_trace.so", "libreference_provider.so", "reference_trace_check")}}
        (trace / "manifest.json").write_text(json.dumps(manifest))
        return source, registration, trace, events

    def test_actual_producer_scope_and_output_metadata_are_accepted(self):
        import riscv64_reference_build as producer
        with tempfile.TemporaryDirectory() as temporary:
            source, registration, trace, _events = self.fixture(Path(temporary), time.monotonic() + 30)
            manifest = json.loads((trace / "manifest.json").read_text())
            self.assertEqual(manifest["scope"], producer.BUILD_SCOPE)
            expected = producer.elf_contract(trace / "reference_libpq_trace.so", shared=True)
            self.assertEqual(manifest["outputs"]["reference_libpq_trace.so"], expected)
            library, digest = self.suite.trace_library(trace)
            self.assertEqual(library, (trace / "reference_libpq_trace.so").resolve())
            self.assertEqual(digest, expected["sha256"])

    def child(self, source, registration, trace, deadline):
        return subprocess.run([sys.executable, str(ROOT / "tools/riscv64_reference_suite.py"),
            "--source", str(source), "--registration", str(registration), "--trace-directory", str(trace),
            "--deadline", str(deadline)], capture_output=True, text=True, timeout=10)

    def test_real_child_runs_fourteen_then_comparison_teardown_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            deadline = time.monotonic() + 30
            args = self.fixture(Path(temporary), deadline)
            result = self.child(*args[:3], deadline)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(args[3].read_text().splitlines(), ["import", "setup", *METHODS, "comparison", "teardown", "class_cleanup"])
            self.assertIn("Ran 14 tests", result.stderr)

    def test_failures_skips_and_comparison_errors_never_become_success(self):
        for changes in ({"fail": True}, {"skip": True}, {"expected_failure": True}, {"subtest_error": True}, {"comparison_error": True}, {"cleanup_error": True},
                        {"teardown_error": True}, {"fail": True, "comparison_error": True, "teardown_error": True}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as temporary:
                deadline = time.monotonic() + 30
                args = self.fixture(Path(temporary), deadline, **changes)
                result = self.child(*args[:3], deadline)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("private", result.stdout + result.stderr)
                values = args[3].read_text().splitlines()
                self.assertEqual(values[-3:], ["comparison", "teardown", "class_cleanup"])
                self.assertEqual(sum(value.startswith("test_") for value in values), 14)
                if changes.get("comparison_error") and changes.get("teardown_error"):
                    self.assertIn("comparison: RuntimeError", result.stderr)
                    self.assertIn("teardown: RuntimeError", result.stderr)

    def test_setup_failure_runs_class_cleanup_once_without_comparison_or_teardown(self):
        with tempfile.TemporaryDirectory() as temporary:
            deadline = time.monotonic() + 30
            args = self.fixture(Path(temporary), deadline, setup_error=True)
            result = self.child(*args[:3], deadline)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("private", result.stdout + result.stderr)
            self.assertEqual(args[3].read_text().splitlines(), ["import", "setup", "class_cleanup"])

    def test_backend_control_is_separate_from_the_acceptance_suite(self):
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                deadline = time.monotonic() + 30
                source, registration, trace, events = self.fixture(Path(temporary), deadline)
                def compare(cls, actual_source, actual_deadline):
                    self.assertEqual(actual_source, source)
                    self.assertEqual(actual_deadline, deadline)
                    with events.open("a") as output: output.write("backend-control\n")
                    if failure: raise RuntimeError("private provider password")
                    return {"outcome": "pass", "diagnostic_method_invocations": 4, "http_assertions_outcome": "fail"}
                output = io.StringIO()
                with mock.patch.dict(sys.modules, {"riscv64_reference_backend": SimpleNamespace(run_backend_comparison=compare)}), \
                        contextlib.redirect_stdout(output):
                    result = self.suite.run_suite(source, registration, trace, deadline, native_backend=True)
                self.assertEqual(result, int(failure))
                self.assertEqual(events.read_text().splitlines(), ["import", "backend-control"])
                self.assertNotIn("private", output.getvalue())
                record = json.loads(output.getvalue().removeprefix("ASM_REFERENCE_BACKEND="))
                self.assertEqual(record["tests_run"], 0)
                self.assertEqual(record["acceptance_suite"], "not-run")
                self.assertEqual(record["diagnostic_method_replays"], 0 if failure else 4)
                self.assertEqual(record["http_assertions_outcome"], "not-run" if failure else "fail")

    def test_cost_probe_preserves_comparison_failure_and_always_finishes_cleanup(self):
        # Catch losing the original failure, exposing provider text, or skipping
        # owned-cluster cleanup after a measurement/publication failure.
        for comparison_error, probe_failure, measurement_outcome in (
                (False, False, "pass"), (False, True, "pass"), (False, False, "fail"),
                (True, False, "pass"), (True, True, "pass"), (True, False, "fail")):
            with self.subTest(comparison_error=comparison_error, probe_failure=probe_failure,
                              measurement_outcome=measurement_outcome), tempfile.TemporaryDirectory() as temporary:
                deadline = time.monotonic() + 30
                source, registration, trace, events = self.fixture(Path(temporary), deadline, comparison_error=comparison_error)
                def probe(case, actual_source, actual_deadline):
                    self.assertEqual(actual_source, source)
                    self.assertEqual(actual_deadline, deadline)
                    with events.open("a") as stream:
                        stream.write("measurement\n")
                    class Diagnostic:
                        def optional_update(self, key, report):
                            with events.open("a") as stream:
                                stream.write(key + ":" + report["outcome"] + "\n")
                    case.diagnostic = Diagnostic()
                    if probe_failure:
                        raise RuntimeError("private provider URL and password")
                    return {"outcome": measurement_outcome}
                output = io.StringIO()
                module = SimpleNamespace(run_diagnostic=probe)
                with mock.patch.dict(sys.modules, {"riscv64_reference_performance": module}), contextlib.redirect_stderr(output):
                    result = self.suite.run_suite(source, registration, trace, deadline, query_cost_probe=True)
                self.assertEqual(result, int(comparison_error or probe_failure or measurement_outcome == "fail"))
                values = events.read_text().splitlines()
                suffix = ["comparison", "measurement"]
                if not probe_failure:
                    suffix += ["query_cost_probe:" + measurement_outcome]
                self.assertEqual(values[-(len(suffix) + 2):], suffix + ["teardown", "class_cleanup"])
                self.assertNotIn("private", output.getvalue())
                if comparison_error:
                    self.assertIn("comparison: RuntimeError", output.getvalue())
                if probe_failure:
                    self.assertIn("query-cost: RuntimeError", output.getvalue())
                elif measurement_outcome == "fail":
                    self.assertIn("query-cost: ValueError", output.getvalue())

    def test_invalid_duplicate_oversized_or_changed_metadata_fails_before_import(self):
        for change in ("registration", "duplicate", "oversize", "scope", "library", "elf", "method", "deadline"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                deadline = time.monotonic() + 30
                source, registration, trace, events = self.fixture(Path(temporary), deadline)
                if change == "registration":
                    value = json.loads(registration.read_text()); value["fixture_revision"] = "0" * 40
                    registration.write_text(json.dumps(value))
                elif change == "duplicate":
                    registration.write_text(registration.read_text().replace('"schema": 1', '"schema": 1,"schema": 1'))
                elif change == "oversize":
                    registration.write_bytes(b" " * 4097)
                elif change == "scope":
                    value = json.loads((trace / "manifest.json").read_text())
                    value["scope"] += "-untrusted"
                    (trace / "manifest.json").write_text(json.dumps(value))
                elif change == "library":
                    (trace / "reference_libpq_trace.so").write_bytes(b"corrupt")
                elif change == "elf":
                    data = elf(62, 0); (trace / "reference_libpq_trace.so").write_bytes(data)
                    value = json.loads((trace / "manifest.json").read_text())
                    value["outputs"]["reference_libpq_trace.so"].update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                    (trace / "manifest.json").write_text(json.dumps(value))
                elif change == "method":
                    path = source / "test_server.py"
                    path.write_text(path.read_text().replace(METHODS[-1], "test_replaced_contract"))
                    value = json.loads(registration.read_text()); value["fixture_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                    registration.write_text(json.dumps(value))
                elif change == "deadline":
                    deadline = 0
                result = self.child(source, registration, trace, deadline)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(events.exists(), "The fixture was imported before metadata validation.")


if __name__ == "__main__":
    unittest.main()
