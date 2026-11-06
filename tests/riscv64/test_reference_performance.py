"""Synthetic boundary tests; no database, target process, or network is used.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import struct
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
SECRET = "private-password-and-url"


def plan():
    return [{"Plan": {"Node Type": "Aggregate", "Startup Cost": 2.0, "Total Cost": 3.5,
        "Plan Rows": 1, "Plan Width": 32, "Actual Startup Time": 0.02, "Actual Total Time": 0.04,
        "Actual Rows": 1, "Actual Loops": 1, "Shared Hit Blocks": 8,
        "Output": [SECRET], "Filter": SECRET, "Plans": [{"Node Type": "Index Scan",
            "Relation Name": "packages", "Index Name": "packages_full_name_key", "Startup Cost":0, "Total Cost":1, "Plan Rows":23, "Plan Width":32, "Actual Rows": 23,
            "Actual Loops": 1, "Index Cond": SECRET}]}, "Planning Time": 2.2,
        "Execution Time": 3.3, "Query Text": SECRET}]


class Function:
    def __init__(self, call): self.call = call
    def __call__(self, *args): return self.call(*args)


class FakeDatabase:
    calls, instances, failure = [], [], None
    def __init__(self, url, *, deadline):
        self.started = time.monotonic()
        self.deadline, self.url, self.closed = deadline, url, False
        self.instances.append(self)
        if self.failure == "connect": raise RuntimeError(SECRET)
        self.conn, self.result, self.buffer, self.sent = 1, False, None, False
        self.state_buffer = ctypes.create_string_buffer(b"57014")
        def send(conn, sql, count, types, values, lengths, formats, result_format):
            text = sql.decode()
            params = [values[i].decode() for i in range(count)]
            self.calls.append((text, params, deadline, url))
            if text.startswith("EXPLAIN "): payload = json.dumps(plan()).encode()
            elif text.startswith("SELECT json_build_object"):
                payload = json.dumps({"jit":"off", "jit_available":False, "statement_timeout":"1s",
                    "lock_timeout":"200ms", "transaction_read_only":"on", "stats":[{"table_id":i,
                    "reltuples":-1, "relpages":0, "n_live_tup":23, "n_dead_tup":0, "analyze_count":0,
                    "autoanalyze_count":0, "last_analyze_set":False, "last_autoanalyze_set":False} for i in range(1,7)]}).encode()
            elif text.startswith("ANALYZE "): payload = b""
            else: payload = json.dumps({"schema": 0, "experimental": True,
                "packages": [{"name": "fixture/p" + params[0][-2:]}], "next_after": None,
                "order": "package-name-ascii"}).encode()
            self.buffer = ctypes.create_string_buffer(payload)
            self.sent = True
            return 1
        def get_result(conn):
            if self.result: return 0
            self.result = True
            return 1
        self.lib = SimpleNamespace(**{name: Function(fn) for name, fn in {
            "PQsendQueryParams": send, "PQflush": lambda conn: 0, "PQconsumeInput": lambda conn: 1,
            "PQisBusy": lambda conn: 0, "PQgetResult": get_result,
            "PQresultStatus": lambda result: 7 if self.failure == "query" else (1 if self.calls[-1][0].startswith("ANALYZE ") else 2),
            "PQntuples": lambda result: 1, "PQnfields": lambda result: 1,
            "PQgetisnull": lambda *args: 0,
            "PQgetlength": lambda *args: len(self.buffer.value),
            "PQgetvalue": lambda *args: ctypes.addressof(self.buffer),
            "PQresultErrorField": lambda *args: ctypes.addressof(self.state_buffer), "PQclear": lambda result: None,
        }.items()})
    def wait(self, writing, deadline):
        if time.monotonic() >= deadline: raise TimeoutError(SECRET)
    def close(self): self.closed = True


class PerformanceTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/riscv64_reference_performance.py"
        self.assertTrue(path.is_file(), "The bounded performance attachment is absent")
        spec = importlib.util.spec_from_file_location("performance", path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        FakeDatabase.calls, FakeDatabase.instances, FakeDatabase.failure = [], [], None

    def test_plan_retains_numeric_evidence_and_fixed_enums_without_private_text(self):
        result = self.module.sanitize_plan(json.dumps(plan()).encode())
        self.assertEqual(result["Planning Time"], 2.2)
        self.assertEqual(result["Plan"]["Plans"][0]["Actual Rows"], 23)
        self.assertEqual(result["Plan"]["Plans"][0]["Index Name"], "packages_full_name_key")
        self.assertNotIn(SECRET, json.dumps(result))
        self.assertNotIn("Output", json.dumps(result))

    def test_hostile_plan_numbers_duplicates_shapes_and_bounds_are_rejected(self):
        cases = [b'[{"Plan":{},"Plan":{}}]', b'[{"Plan":{"Node Type":"Index Scan","Actual Rows":true},"Planning Time":1,"Execution Time":2}]',
            b'[{"Plan":{"Node Type":"Seq Scan","Actual Rows":NaN},"Planning Time":1,"Execution Time":2}]',
            b'[{"Plan":{"Node Type":"Seq Scan"},"Planning Time":-1,"Execution Time":2}]',
            json.dumps([{**plan()[0], "Plan": {"Node Type": SECRET}}]).encode(),
            json.dumps([{**plan()[0], "Plan": {"Node Type": "Seq Scan", "Relation Name": SECRET}}]).encode(),
            b'[]', b'[{"Plan":{"Node Type":"Result"},"Planning Time":1,"Execution Time":2}]', b'[{"Plan":{"Node Type":[]},"Planning Time":1,"Execution Time":2}]', b'[{"Plan":{"Node Type":"Result"},"Execution Time":2}]', b'x' * (65536 + 1)]
        for raw in cases:
            with self.subTest(raw=raw[:40]), self.assertRaises(ValueError): self.module.sanitize_plan(raw)
        bad_number = plan()
        bad_number[0]["Plan"]["Actual Rows"] = True
        with self.assertRaises(ValueError): self.module.sanitize_plan(json.dumps(bad_number).encode())
        duplicate = json.dumps(plan()).replace('"Planning Time": 2.2', '"Planning Time": 2.2, "Planning Time": 2.3')
        with self.assertRaises(ValueError): self.module.sanitize_plan(duplicate.encode())
        oversized = plan()
        oversized[0]["Query Text"] = "x" * 65536
        with self.assertRaises(ValueError): self.module.sanitize_plan(json.dumps(oversized).encode())
        core = {"Node Type":"Result", "Startup Cost":0, "Total Cost":1, "Plan Rows":1,
            "Plan Width":32, "Actual Rows":1, "Actual Loops":1}
        node = dict(core)
        for _ in range(40): node = {**core, "Plans":[node]}
        with self.assertRaises(ValueError): self.module.sanitize_plan(json.dumps([{**plan()[0], "Plan": node}]).encode())
        node = {**core, "Node Type":"Append", "Plans":[core]*300}
        with self.assertRaises(ValueError): self.module.sanitize_plan(json.dumps([{**plan()[0], "Plan": node}]).encode())

    def fixture(self, base):
        source = base / "source"
        source.mkdir()
        (source / "search.sql").write_bytes((ROOT / "experiments/assembly-server/search.sql").read_bytes())
        (source / "local_postgres.py").write_text("# exact fixture module stands in for synthetic boundary\n")
        url = base / "reader.url"
        url.write_text("postgresql://reader:" + SECRET + "@127.0.0.1:15432/owned?hostaddr=127.0.0.1&sslmode=disable&gssencmode=disable&options=-c%20statement_timeout%3D5000")
        case = SimpleNamespace(fixture_ready=True, base=base, reader="reader", dbname="owned",
            cluster=SimpleNamespace(port=15432, url=lambda **kwargs: url.read_text().replace("reader:", "asm_fixture_admin:")),
            url_files={"reader": url}, server=SimpleNamespace(poll=lambda: 0), attribution=None,
            _owned_server_stopped=lambda proc, control: proc.poll() is not None,
            diagnostic=SimpleNamespace(data={"phase_traces": {k: {"association": "complete"} for k in ("main", "direct", "proxy")},
                "controlled_search_comparison": {"order": ["direct", "proxy"], "arms": [
                    {"label": k, "state": "failed", "attribution": {"returncode": 0, "cleanup_errors": [], "released":True, "target_ready":True}} for k in ("direct", "proxy")]}}))
        module = SimpleNamespace(Database=FakeDatabase, __file__=str(source / "local_postgres.py"))
        return case, source, module

    def run_fixture(self, case, source, fixture):
        with mock.patch.dict(sys.modules, {"local_postgres": fixture}), \
                mock.patch.object(self.module, "_pg_config", return_value={"outcome": "pass", "with_llvm": False}), \
                mock.patch.object(self.module, "_connect", side_effect=lambda fixture, url, deadline: FakeDatabase(url, deadline=deadline)):
            return self.module.run_diagnostic(case, source, time.monotonic() + 10)

    def test_candidate_input_exists_before_the_owned_comparison(self):
        self.assertTrue((ROOT / "tools/diagnostics/reference_search_candidate.sql").is_file(),
                        "The fixed candidate SQL input is absent.")

    def candidate_fixture(self, base):
        case, source, fixture = self.fixture(base)
        case.attribution = SimpleNamespace(failure=None, record={"returncode": 0,
            "cleanup_errors": [], "released": True, "target_ready": True})
        case.diagnostic.data = {}  # SQL-only mode does not run HTTP comparison arms.
        return case, source, fixture

    def candidate_semantics(self, case, baseline, candidate, deadline):
        digest = "a" * 64
        return {"schema": 1, "scope": "reference-search-sql-equivalence", "qualification": "UNQUALIFIED",
            "outcome": "pass", "expected_cases": 16,
            "cases": [{"index": index, "outcome": "pass", "checks": 1,
                "baseline_sha256": digest, "candidate_sha256": digest, "expected_sha256": digest}
                for index in range(1, 17)],
            "original_queries": [{"index": index, "outcome": "pass", "baseline_sha256": digest,
                "candidate_sha256": digest, "expected_sha256": digest} for index in range(1, 24)],
            "original_queries_passed": 23,
            "cleanup": {"transaction_rolled_back": True, "case_database_dropped": True,
                "original_catalog_unchanged": True},
            "baseline_sha256": hashlib.sha256(baseline.encode()).hexdigest(),
            "candidate_sha256": hashlib.sha256(candidate.encode()).hexdigest(), "elapsed_seconds": 0.1}

    def run_candidate_fixture(self, case, source, fixture, *, verify=None, deadline=None):
        helper = SimpleNamespace(__file__=str(ROOT / "tools/diagnostics/reference_search_cases.py"),
                                 verify=verify or self.candidate_semantics)
        with mock.patch.dict(sys.modules, {"local_postgres": fixture,
                "diagnostics.reference_search_cases": helper}), \
                mock.patch.object(self.module, "_connect", side_effect=lambda fixture, url, deadline: FakeDatabase(url, deadline=deadline)):
            return self.module.run_candidate(case, source, time.monotonic() + 30 if deadline is None else deadline)

    def test_candidate_orders_four_plain_waves_after_semantics_without_statistics_mutation(self):
        self.assertTrue(callable(getattr(self.module, "run_candidate", None)), "The candidate measurement entry point is absent.")
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.candidate_fixture(Path(temporary))
            baseline = (source / "search.sql").read_text()
            candidate = (ROOT / "tools/diagnostics/reference_search_candidate.sql").read_text()
            def verify(*args):
                self.assertFalse(any(call[0] in (baseline, candidate) for call in FakeDatabase.calls))
                return self.candidate_semantics(*args)
            report = self.run_candidate_fixture(case, source, fixture, verify=verify)
            self.assertEqual(report["outcome"], "pass")
            self.assertEqual([wave["label"] for wave in report["waves"]], ["A1", "B1", "B2", "A2"])
            self.assertEqual([len(wave["records"]) for wave in report["waves"]], [16] * 4)
            plain = [call for call in FakeDatabase.calls if call[0] in (baseline, candidate)]
            self.assertEqual([call[0] for call in plain], [baseline] * 16 + [candidate] * 32 + [baseline] * 16)
            self.assertTrue(all(wave["successful"] == 16 for wave in report["waves"]))
            self.assertTrue(report["paired_results"]["all_matched"])
            self.assertEqual(report["paired_results"]["paired_indexes"], 16)
            self.assertTrue(report["statistics_unchanged"])
            self.assertTrue(all(not call[0].startswith("ANALYZE") for call in FakeDatabase.calls))
            self.assertEqual(report["candidate_sha256"], hashlib.sha256(candidate.encode()).hexdigest())
            self.assertEqual(report["original_19_test_gate"], "fail")
            self.assertEqual(report["http_tests"], "not-run")
            self.assertTrue(all(report[key] is False for key in ("application_qualified", "native_qualified", "release_qualified")))
            self.assertNotIn(SECRET, json.dumps(report))
            self.assertTrue(all(instance.closed for instance in FakeDatabase.instances))
            self.assertTrue(all(urlsplit(instance.url).username == "reader" for instance in FakeDatabase.instances))
            self.assertTrue(all(instance.deadline - instance.started <= 2 for instance in FakeDatabase.instances))

    def test_candidate_retains_only_the_fixed_semantic_failure_enum(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.candidate_fixture(Path(temporary))
            def verify(*args):
                report = self.candidate_semantics(*args)
                report.update(outcome="fail", failure="equivalence", provider_error=SECRET)
                return report
            report = self.run_candidate_fixture(case, source, fixture, verify=verify)
            self.assertEqual(report["semantics"].get("failure"), "equivalence")
            self.assertNotIn(SECRET, json.dumps(report))
            self.assertEqual(report["waves"], [])

    def test_candidate_changed_oversized_non_ascii_or_linked_input_prevents_database_work(self):
        for failure in ("changed", "oversized", "non-ascii", "symlink"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                case, source, fixture = self.candidate_fixture(base)
                candidate = base / "candidate.sql"
                if failure == "changed": candidate.write_text("SELECT private")
                if failure == "oversized": candidate.write_bytes(b"x" * 16385)
                if failure == "non-ascii": candidate.write_bytes(b"\xff")
                if failure == "symlink": candidate.symlink_to(ROOT / "tools/diagnostics/reference_search_candidate.sql")
                with mock.patch.object(self.module, "CANDIDATE_PATH", candidate):
                    report = self.run_candidate_fixture(case, source, fixture,
                        verify=lambda *args: self.fail("Changed candidate reached the semantic gate"))
                self.assertEqual(report["outcome"], "fail")
                self.assertFalse(FakeDatabase.calls)
                self.assertNotIn(SECRET, json.dumps(report))

    def test_candidate_stops_before_abba_when_equivalence_or_case_cleanup_fails(self):
        for failure in ("case", "case-count", "original", "cleanup", "binding", "provider"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                case, source, fixture = self.candidate_fixture(Path(temporary))
                def verify(*args):
                    report = self.candidate_semantics(*args)
                    if failure == "case": report["cases"][0]["outcome"] = "fail"
                    if failure == "case-count": report["cases"].pop()
                    if failure == "original": report["original_queries"][0]["candidate_sha256"] = "b" * 64
                    if failure == "cleanup": report["cleanup"]["case_database_dropped"] = False
                    if failure == "binding": report["candidate_sha256"] = "b" * 64
                    if failure == "provider": raise RuntimeError(SECRET)
                    return report
                report = self.run_candidate_fixture(case, source, fixture, verify=verify)
                self.assertEqual(report["outcome"], "fail")
                self.assertEqual(report["waves"], [])
                self.assertNotIn(SECRET, json.dumps(report))
                FakeDatabase.calls, FakeDatabase.instances = [], []

    def test_candidate_rejects_unsafe_preconditions_before_semantics_or_connections(self):
        for failure in ("active", "not-ready", "attribution", "cleanup", "baseline", "pg-env", "preload", "deadline"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                case, source, fixture = self.candidate_fixture(Path(temporary))
                if failure == "active": case.server.poll = lambda: None
                if failure == "not-ready": case.fixture_ready = False
                if failure == "attribution": case.attribution.failure = RuntimeError(SECRET)
                if failure == "cleanup": case.attribution.record["cleanup_errors"] = [SECRET]
                if failure == "baseline": (source / "search.sql").write_text("SELECT private")
                environment = {"PGSERVICE": SECRET} if failure == "pg-env" else {"LD_PRELOAD": SECRET} if failure == "preload" else {}
                end = time.monotonic() - 1 if failure == "deadline" else time.monotonic() + 30
                with mock.patch.dict(self.module.os.environ, environment):
                    report = self.run_candidate_fixture(case, source, fixture,
                        verify=lambda *args: self.fail("Unsafe preconditions reached the semantic gate"), deadline=end)
                self.assertEqual(report["outcome"], "fail")
                self.assertFalse(FakeDatabase.calls)
                self.assertNotIn(SECRET, json.dumps(report))

    def test_candidate_exact_body_mismatch_fails_after_retaining_all_64_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.candidate_fixture(Path(temporary))
            candidate = (ROOT / "tools/diagnostics/reference_search_candidate.sql").read_text()
            original = self.module._query
            def changed_body(db, sql, params, deadline, **kwargs):
                raw = original(db, sql, params, deadline, **kwargs)
                if sql == candidate:
                    value = json.loads(raw)
                    value["packages"][0]["summary"] = "Different result bytes"
                    return json.dumps(value).encode()
                return raw
            with mock.patch.object(self.module, "_query", changed_body):
                report = self.run_candidate_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(sum(len(wave["records"]) for wave in report["waves"]), 64)
            self.assertFalse(report["paired_results"]["all_matched"])
            self.assertEqual(report["paired_results"]["mismatched_indexes"], list(range(1, 17)))

    def test_candidate_partial_query_failures_remain_visible_without_becoming_query_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.candidate_fixture(Path(temporary))
            original = self.module._row
            def failing_row(fixture, url, query, index, explain, deadline):
                if index != 1: return original(fixture, url, query, index, explain, deadline)
                return {"index": index, "outcome": "fail", "attempted": True,
                    "stage": "query", "failure": "provider-status", "status": 7, "sqlstate": "57014"}
            with mock.patch.object(self.module, "_row", failing_row):
                report = self.run_candidate_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "pass")
            self.assertEqual([wave["successful"] for wave in report["waves"]], [15] * 4)
            self.assertEqual(sum(row["outcome"] == "fail" for wave in report["waves"] for row in wave["records"]), 4)
            self.assertEqual(report["paired_results"]["paired_indexes"], 15)

    def test_candidate_control_statistics_change_invalidates_the_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.candidate_fixture(Path(temporary))
            original, calls = self.module._control, []
            def changed_control(*args):
                result = original(*args)
                if calls: result["stats"][0]["reltuples"] = 1
                calls.append(True)
                return result
            with mock.patch.object(self.module, "_control", changed_control):
                report = self.run_candidate_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "fail")
            self.assertFalse(report["statistics_unchanged"])

    def test_candidate_optional_plans_run_only_after_abba_with_enough_shared_budget(self):
        for remaining in (30, 5):
            with self.subTest(remaining=remaining), tempfile.TemporaryDirectory() as temporary:
                case, source, fixture = self.candidate_fixture(Path(temporary))
                report = self.run_candidate_fixture(case, source, fixture, deadline=time.monotonic() + remaining)
                explains = [index for index, call in enumerate(FakeDatabase.calls) if call[0].startswith("EXPLAIN ")]
                plain = [index for index, call in enumerate(FakeDatabase.calls)
                         if not call[0].startswith(("SELECT json_build_object", "EXPLAIN "))]
                if remaining == 30:
                    self.assertEqual(len(explains), 2)
                    self.assertGreater(min(explains), max(plain))
                    self.assertEqual(report["structural_samples"]["outcome"], "complete")
                else:
                    self.assertFalse(explains)
                    self.assertEqual(report["structural_samples"]["outcome"], "not-run")
                FakeDatabase.calls, FakeDatabase.instances = [], []

    def test_candidate_final_serialization_cannot_hide_a_late_deadline(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.candidate_fixture(Path(temporary))
            original_clock, original_dumps, offset = time.monotonic, json.dumps, [0]
            def late_dumps(value, *args, **kwargs):
                encoded = original_dumps(value, *args, **kwargs)
                if type(value) is dict and value.get("scope") == "reference-query-candidate-abba": offset[0] = 31
                return encoded
            with mock.patch.object(self.module.json, "dumps", late_dumps), \
                    mock.patch.object(self.module.time, "monotonic", lambda: original_clock() + offset[0]):
                report = self.run_candidate_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(sum(len(wave["records"]) for wave in report["waves"]), 64)
            self.assertGreaterEqual(report["seconds"], 31)

    def test_four_ordered_waves_keep_fixed_parameters_private_and_connection_deadlines_shared(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.fixture(Path(temporary))
            report = self.run_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "pass")
            self.assertEqual(report["order"], ["controls_before", "search_before", "explain_before", "analyze", "search_after", "explain_after", "controls_after", "pg_config"])
            self.assertEqual([len(wave["records"]) for wave in report["waves"]], [16, 16, 16, 16])
            self.assertTrue(all(row["outcome"] == "pass" for wave in report["waves"] for row in wave["records"]))
            self.assertNotIn(SECRET, json.dumps(report))
            self.assertNotIn("fixture 01", json.dumps(report))
            self.assertEqual(report["analyze"]["outcome"], "pass")
            self.assertTrue(report["comparison_valid"])
            self.assertTrue(all("TIMING FALSE" in call[0] for call in FakeDatabase.calls if call[0].startswith("EXPLAIN ")))
            self.assertTrue(all(instance.closed for instance in FakeDatabase.instances))
            searches = [call for call in FakeDatabase.calls if not call[0].startswith(("EXPLAIN ", "SELECT json_build_object", "ANALYZE "))]
            explains = [call for call in FakeDatabase.calls if call[0].startswith("EXPLAIN ")]
            self.assertEqual(len(searches), 32)
            self.assertEqual(len(explains), 32)
            self.assertEqual(sorted(v[1] for v in searches), sorted([[f"fixture {i:02d}", ""] for i in range(1, 17)] * 2))
            self.assertEqual(sorted(v[1] for v in explains), sorted(v[1] for v in searches))
            for instance in FakeDatabase.instances:
                self.assertLessEqual(instance.deadline - instance.started, 2)
                fields = parse_qs(urlsplit(instance.url).query)
                expected_readonly = "off" if urlsplit(instance.url).username == "asm_fixture_admin" else "on"
                self.assertEqual(fields["options"], [f"-c default_transaction_read_only={expected_readonly} -c statement_timeout=1000 -c lock_timeout=200 -c search_path=pg_catalog,public"])
                self.assertEqual(fields["application_name"], ["asm-assembly-prototype"])

    def test_query_failures_remain_all_64_records_but_no_plans_is_incomplete(self):
        FakeDatabase.failure = "query"
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.fixture(Path(temporary))
            report = self.run_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(sum(len(wave["records"]) for wave in report["waves"]), 64)
            self.assertTrue(all(row["query_ms"] is not None for wave in report["waves"] for row in wave["records"]))
            self.assertTrue(all(row["sqlstate"] == "57014" for wave in report["waves"] for row in wave["records"]))
            self.assertNotIn(SECRET, json.dumps(report))
            self.assertTrue(all(instance.closed for instance in FakeDatabase.instances))

    def test_incomplete_cleanup_or_changed_source_prevents_all_db_work(self):
        for bad in ("active", "not-ready", "cleanup", "source", "deadline"):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as temporary:
                case, source, fixture = self.fixture(Path(temporary))
                if bad == "active": case.server.poll = lambda: None
                if bad == "not-ready": case.fixture_ready = False
                if bad == "cleanup": case.diagnostic.data["controlled_search_comparison"]["arms"][1]["cleanup_failure"] = SECRET
                if bad == "source": (source / "search.sql").write_text("SELECT private")
                deadline = time.monotonic() - 1 if bad == "deadline" else time.monotonic() + 10
                with mock.patch.dict(sys.modules, {"local_postgres": fixture}):
                    report = self.module.run_diagnostic(case, source, deadline)
                self.assertEqual(report["outcome"], "fail")
                self.assertFalse(FakeDatabase.calls)
                self.assertNotIn(SECRET, json.dumps(report))

    def test_bounded_cell_reader_rejects_large_null_and_extra_results_before_copy(self):
        db = FakeDatabase("unused", deadline=time.monotonic() + 2)
        for field, replacement in (("PQgetlength", lambda *args: 65537),
                ("PQgetisnull", lambda *args: 1), ("PQntuples", lambda *args: 2),
                ("PQnfields", lambda *args: 2)):
            db.result = False
            original = getattr(db.lib, field)
            setattr(db.lib, field, Function(replacement))
            with self.subTest(field=field), mock.patch.object(self.module.ctypes, "string_at", side_effect=AssertionError("must not copy")):
                with self.assertRaises(ValueError):
                    self.module._query(db, "SELECT fixed", ["fixture 01", ""], time.monotonic() + 2)
            setattr(db.lib, field, original)

    def test_connector_installs_private_notice_sink_before_poll_and_uses_fixed_parameters(self):
        events, captured = [], {}
        def connect(keys, values, expand):
            events.append("connect")
            for i in range(6): captured[keys[i].decode()] = values[i].decode()
            self.assertEqual(expand, 1)
            return 1
        lib = SimpleNamespace()
        for name in ("PQconnectStartParams", "PQconnectPoll", "PQsocket", "PQflush", "PQconsumeInput", "PQisBusy",
                "PQsetnonblocking", "PQsendQueryParams", "PQgetResult", "PQresultStatus", "PQgetvalue",
                "PQntuples", "PQnfields", "PQclear", "PQfinish", "PQsetNoticeProcessor"):
            setattr(lib, name, Function(lambda *args: 0))
        lib.PQconnectStartParams = Function(connect)
        lib.PQconnectPoll = Function(lambda conn: events.append("poll") or 3)
        lib.PQsetNoticeProcessor = Function(lambda conn, callback, arg: events.append("notice") or callback(None, 1))
        with mock.patch.object(self.module.ctypes, "CDLL", return_value=lib), \
                mock.patch.dict(self.module.os.environ, {"ASM_PROTO_LIBPQ":"fixed.so"}):
            db = self.module._connect(SimpleNamespace(Database=FakeDatabase), "fixed-owned-url", time.monotonic()+2)
        self.assertEqual(events, ["connect", "notice", "poll"])
        self.assertEqual(captured["hostaddr"], "127.0.0.1")
        self.assertEqual(captured["host"], "127.0.0.1")
        self.assertEqual(captured["application_name"], "asm-assembly-prototype")
        self.assertEqual(captured["options"], "-c default_transaction_read_only=on -c statement_timeout=1000 -c lock_timeout=200 -c search_path=pg_catalog,public")
        self.assertTrue(hasattr(db, "_notice"))

    def test_cgroup_stat_whitelists_numbers_and_missing_support_is_nonfatal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "cpu.stat"
            path.write_text("usage_usec 12\nuser_usec 9\nsystem_usec 3\nnr_periods 4\nnr_throttled 2\nthrottled_usec 7\nunknown " + SECRET + "\n")
            with mock.patch.object(self.module, "CPU_STAT", path):
                result = self.module._cpu_stat()
                self.assertEqual(result["values"]["usage_usec"], 12)
                self.assertNotIn(SECRET, json.dumps(result))
                path.write_text("usage_usec true\n")
                self.assertEqual(self.module._cpu_stat()["outcome"], "unavailable")
                path.unlink()
                self.assertEqual(self.module._cpu_stat()["outcome"], "unavailable")

    def test_late_close_cannot_report_success_and_shared_budget_does_not_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.fixture(Path(temporary))
            original_clock = time.monotonic
            offset = [0]
            original_close = FakeDatabase.close
            def late_close(db):
                original_close(db)
                offset[0] = 31
            with mock.patch.object(FakeDatabase, "close", late_close), \
                    mock.patch.object(self.module.time, "monotonic", lambda: original_clock() + offset[0]):
                report = self.run_fixture(case, source, fixture)
            self.assertEqual(report["outcome"], "fail")
            self.assertFalse(any(row["outcome"] == "pass" for wave in report["waves"] for row in wave["records"]))
            self.assertLessEqual(len(FakeDatabase.calls), 1)

    def test_a_successful_result_with_late_connection_close_is_a_failed_attempt(self):
        original_clock, offset = time.monotonic, [0]
        def late_close(db):
            db.closed = True
            offset[0] = 3
        with mock.patch.object(self.module, "_connect", side_effect=lambda fixture, url, deadline: FakeDatabase(url, deadline=deadline)), \
                mock.patch.object(FakeDatabase, "close", late_close), \
                mock.patch.object(self.module.time, "monotonic", lambda: original_clock()+offset[0]):
            row = self.module._row(None, "unused", "SELECT fixed", 1, False, original_clock()+10)
        self.assertEqual(row["outcome"], "fail")
        self.assertEqual(row["failure"], "deadline")

    def test_pg_config_records_only_bounded_build_identity_and_llvm_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            executable = base / "pg_config"
            data = bytearray(64)
            data[:7] = b"\x7fELF\x02\x01\x01"
            struct.pack_into("<HH",data,16,3,243)
            executable.write_bytes(data)
            calls = []
            def process(args, log, **kwargs):
                calls.append((args, kwargs))
                log.write_bytes(b"PostgreSQL 16.15\n" if args[-1] == "--version" else ("'--with-llvm' '--prefix="+SECRET+"'").encode())
                return {"outcome":"pass", "exit_code":0}
            with mock.patch.object(self.module, "PG_CONFIG", executable), mock.patch.object(self.module, "bounded_process", process):
                report = self.module._pg_config(base, time.monotonic()+5)
            self.assertEqual(report["outcome"], "pass")
            self.assertTrue(report["with_llvm"])
            self.assertNotIn(SECRET,json.dumps(report))
            self.assertEqual(list(base.iterdir()),[executable])
            self.assertEqual(len(calls),2)
            self.assertTrue(all(args[:2] == ["/usr/bin/env","-i"] and 0 < kwargs["timeout"] <= 2 for args,kwargs in calls))

    def test_controls_and_analyze_reject_a_late_close(self):
        for kind in ("control", "analyze"):
            original_clock, offset = time.monotonic, [0]
            def late_close(db):
                db.closed = True
                offset[0] = 3
            with self.subTest(kind=kind), mock.patch.object(self.module, "_connect", side_effect=lambda fixture, url, deadline: FakeDatabase(url, deadline=deadline)), \
                    mock.patch.object(FakeDatabase, "close", late_close), \
                    mock.patch.object(self.module.time, "monotonic", lambda: original_clock()+offset[0]):
                function = self.module._control if kind == "control" else self.module._analyze
                result = function(None,"unused",original_clock()+10)
            self.assertEqual(result["outcome"], "fail")

    def test_plan_tree_retention_cap_preserves_all_64_measurements(self):
        large = plan()
        child = {"Node Type":"Result","Startup Cost":0,"Total Cost":1,"Plan Rows":1,
            "Plan Width":32,"Actual Rows":1,"Actual Loops":1}
        large[0]["Plan"]["Plans"] = [child] * 180
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.fixture(Path(temporary))
            with mock.patch(__name__+".plan", return_value=large):
                report = self.run_fixture(case,source,fixture)
            self.assertEqual(sum(len(w["records"]) for w in report["waves"]),64)
            self.assertLessEqual(len(json.dumps(report,indent=2).encode()),512*1024)
            for wave in report["waves"]:
                if wave["label"].startswith("explain"):
                    self.assertLessEqual(sum(row["full_tree_retained"] for row in wave["records"]),2)
                    self.assertTrue(all("Planning Time" in row["plan"] for row in wave["records"]))

    def test_pg_config_rejects_host_binary_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            executable = base / "pg_config"
            executable.write_bytes(b"not a RISC-V ELF")
            with mock.patch.object(self.module, "PG_CONFIG", executable), \
                    mock.patch.object(self.module, "bounded_process", side_effect=AssertionError("must not execute")):
                with self.assertRaises(ValueError): self.module._pg_config(base, time.monotonic()+2)

    def test_failed_attempts_do_not_consume_successful_plan_tree_slots(self):
        numeric = self.module.sanitize_plan(json.dumps(plan()).encode())
        rows = [{"outcome":state,"plan":json.loads(json.dumps(numeric))} for state in ("fail","pass","pass")]
        self.assertEqual(self.module._retain_plans(rows),2)
        self.assertEqual([row["full_tree_retained"] for row in rows],[False,True,True])
        self.assertNotIn("Plans",rows[0]["plan"]["Plan"])

    def test_ambient_postgres_configuration_prevents_any_connection(self):
        with tempfile.TemporaryDirectory() as temporary:
            case,source,fixture = self.fixture(Path(temporary))
            with mock.patch.dict(self.module.os.environ,{"PGSERVICE":SECRET}):
                report = self.run_fixture(case,source,fixture)
            self.assertEqual(report["outcome"],"fail")
            self.assertFalse(FakeDatabase.calls)
            self.assertNotIn(SECRET,json.dumps(report))

    def test_final_evidence_serialization_uses_the_existing_deadline(self):
        with tempfile.TemporaryDirectory() as temporary:
            case,source,fixture = self.fixture(Path(temporary))
            original_clock, original_dumps, offset = time.monotonic,json.dumps,[0]
            def late_dumps(value,*args,**kwargs):
                result = original_dumps(value,*args,**kwargs)
                if type(value) is dict and value.get("scope") == "reference-query-cost-probe": offset[0] = 31
                return result
            with mock.patch.object(self.module.json,"dumps",late_dumps), \
                    mock.patch.object(self.module.time,"monotonic",lambda:original_clock()+offset[0]):
                report = self.run_fixture(case,source,fixture)
            self.assertEqual(report["outcome"],"fail")
            self.assertEqual(sum(len(wave["records"]) for wave in report["waves"]),64)

    def test_connection_exception_is_sanitized_and_every_attempt_is_retained(self):
        FakeDatabase.failure = "connect"
        with tempfile.TemporaryDirectory() as temporary:
            case, source, fixture = self.fixture(Path(temporary))
            report = self.run_fixture(case, source, fixture)
            self.assertEqual(sum(len(wave["records"]) for wave in report["waves"]), 64)
            self.assertNotIn(SECRET, json.dumps(report))
            self.assertEqual(report["outcome"], "fail")


if __name__ == "__main__": unittest.main(verbosity=2)
