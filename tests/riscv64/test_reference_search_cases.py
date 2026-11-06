"""Check bounded SQL case orchestration without a database or target process.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
from pathlib import Path
import sys
import time
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
BASELINE = ROOT / "experiments/assembly-server/search.sql"
CANDIDATE = ROOT / "tools/diagnostics/reference_search_candidate.sql"
SECRET = "private password and connection URL"


class CandidateInputTests(unittest.TestCase):
    def test_selected_candidate_is_available_as_bounded_ascii_sql(self):
        data = CANDIDATE.read_bytes()
        self.assertTrue(0 < len(data) <= 16384)
        self.assertEqual(data.decode("ascii").encode("ascii"), data)


class SearchCaseTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/diagnostics/reference_search_cases.py"
        self.assertTrue(path.is_file(), "The bounded SQL equivalence helper is absent")
        spec = importlib.util.spec_from_file_location("reference_search_cases", path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.case = SimpleNamespace(names="asm_proto_0123456789ab", dbname="asm_proto_0123456789ab",
            reader="asm_proto_0123456789ab_r", fixture_ready=True, cluster=SimpleNamespace())

    def verify(self, baseline=None, candidate=None, deadline=None):
        return self.module.verify(self.case, BASELINE.read_text() if baseline is None else baseline,
            CANDIDATE.read_text() if candidate is None else candidate,
            time.monotonic() + 10 if deadline is None else deadline)

    def test_changed_baseline_or_unsafe_case_identity_prevents_any_connection(self):
        for failure in ("baseline", "identity", "deadline", "oversized", "nonascii"):
            with self.subTest(failure=failure), mock.patch.object(self.module.perf, "_connect") as connect:
                baseline, candidate, deadline = None, None, None
                if failure == "baseline": baseline = "SELECT private"
                if failure == "identity": self.case.names = "unsafe; DROP DATABASE postgres"
                if failure == "deadline": deadline = time.monotonic() - 1
                if failure == "oversized": candidate = "x" * 16385
                if failure == "nonascii": candidate = "SELECT '\u00e4'"
                result = self.verify(baseline, candidate, deadline)
                self.assertEqual(result["outcome"], "fail")
                self.assertFalse(connect.called)
                self.assertNotIn("private", json.dumps(result))
                self.case.names = "asm_proto_0123456789ab"

    def test_connection_failure_is_private_and_keeps_all_cases_not_run(self):
        fixture = SimpleNamespace(__file__=str(ROOT / "experiments/assembly-server/local_postgres.py"))
        with mock.patch.object(self.module.importlib, "import_module", return_value=fixture), \
                mock.patch.object(self.module.perf, "_url", return_value=SECRET), \
                mock.patch.object(self.module.perf, "_connect", side_effect=RuntimeError(SECRET)) as connection:
            result = self.verify()
        self.assertTrue(connection.called)
        self.assertEqual(result["outcome"], "fail")
        self.assertEqual(len(result["cases"]), 16)
        self.assertEqual(len(result["original_queries"]), 23)
        self.assertTrue(all(row["outcome"] == "not-run" for row in result["cases"]))
        self.assertFalse(result["cleanup"]["case_database_dropped"])
        self.assertNotIn(SECRET, json.dumps(result))

    def test_equal_wrong_results_fail_the_independent_expected_answer(self):
        expected = {"schema": 0, "experimental": True, "packages": [{"name": "fixture/p01",
            "latest": "0.2.0", "summary": "Assembly fixture 01", "license": "MIT",
            "owner_github_id": 12345, "targets": ["x86_64-linux"]}],
            "next_after": None, "order": "package-name-ascii"}
        wrong = b'{"schema":0,"experimental":true,"packages":[],"next_after":null,"order":"package-name-ascii"}'
        row = {"outcome": "not-run"}
        with mock.patch.object(self.module.perf, "_query", side_effect=[wrong, wrong]):
            with self.assertRaises(self.module.EquivalenceError):
                self.module._compare(None, "fixed A", "fixed B", ["fixed", ""], expected,
                    time.monotonic() + 2, row)
        self.assertEqual(row["outcome"], "fail")
        self.assertEqual(row["baseline_sha256"], row["candidate_sha256"])
        self.assertNotEqual(row["expected_sha256"], row["baseline_sha256"])

    def test_case_setup_failure_drops_only_its_new_database_and_closes_connections(self):
        fixture = SimpleNamespace(__file__=str(ROOT / "experiments/assembly-server/local_postgres.py"))
        existing = {self.case.dbname}
        connections = []
        operations = []
        def connect(fixture, url, deadline):
            database = SimpleNamespace(name=url, closed=False)
            database.close = lambda: setattr(database, "closed", True)
            connections.append(database)
            return database
        def command(db, sql, params, deadline):
            operations.append((db.name, sql))
            if sql.startswith('CREATE DATABASE "'):
                existing.add(sql.split('"')[1])
            elif sql.startswith('DROP DATABASE "'):
                existing.remove(sql.split('"')[1])
        def script(db, sql, deadline):
            self.assertEqual(db.name, self.case.names + "_sqlcases")
            raise RuntimeError(SECRET)
        with mock.patch.object(self.module.importlib, "import_module", return_value=fixture), \
                mock.patch.object(self.module.perf, "_url", side_effect=lambda case, **kw: case.dbname), \
                mock.patch.object(self.module.perf, "_connect", side_effect=connect), \
                mock.patch.object(self.module, "_snapshot", return_value="a" * 64), \
                mock.patch.object(self.module, "_command", side_effect=command), \
                mock.patch.object(self.module, "_script", side_effect=script):
            result = self.verify()
        self.assertEqual(existing, {self.case.dbname})
        self.assertTrue(all(db.closed for db in connections))
        self.assertEqual(len(connections), 2)
        self.assertEqual([sql.split()[0] for _, sql in operations], ["CREATE", "DROP"])
        self.assertTrue(all(name == self.case.dbname for name, _ in operations))
        self.assertTrue(result["cleanup"]["case_database_dropped"])
        self.assertTrue(result["cleanup"]["original_catalog_unchanged"])
        self.assertEqual(result["outcome"], "fail")
        self.assertNotIn(SECRET, json.dumps(result))

    def test_release_commands_convert_only_fixed_scalar_parameters_to_text(self):
        calls = []
        def query(db, sql, params, deadline, **kwargs):
            self.assertTrue(all(type(value) is str for value in params))
            calls.append((sql, params))
            return b""
        with mock.patch.object(self.module.perf, "_query", side_effect=query):
            self.module._release(None, time.monotonic() + 2, 2, (9, 9, 10), "patchwinner")
        self.assertEqual(len(calls), 3)

    def simulated_verify(self, *, mismatch=None, rollback_failure=False, collision=False):
        """Simulate only the unavailable database/connection boundary."""
        fixture = SimpleNamespace(__file__=str(ROOT / "experiments/assembly-server/local_postgres.py"))
        name = self.case.names + "_sqlcases"
        existing = {self.case.dbname, *([name] if collision else [])}
        connections, operations = [], []
        def connect(fixture, url, deadline):
            db = SimpleNamespace(name=url, closed=False)
            db.close = lambda: setattr(db, "closed", True)
            connections.append(db)
            return db
        def command(db, sql, params, deadline):
            operations.append((db.name, sql))
            if sql.startswith('CREATE DATABASE "'):
                if name in existing: raise RuntimeError(SECRET)
                existing.add(name)
            elif sql.startswith('DROP DATABASE "'):
                existing.remove(name)
            elif sql == "ROLLBACK" and rollback_failure:
                raise RuntimeError(SECRET)
        def compare(db, baseline, candidate, params, expected, deadline, row):
            row.update(outcome="fail", baseline_sha256="a" * 64, candidate_sha256="a" * 64,
                       expected_sha256="b" * 64)
            if mismatch is not None and mismatch(params, expected):
                raise self.module.EquivalenceError(SECRET)
            row["outcome"] = "pass"
        with mock.patch.object(self.module.importlib, "import_module", return_value=fixture), \
                mock.patch.object(self.module.perf, "_url", side_effect=lambda case, **kw: case.dbname), \
                mock.patch.object(self.module.perf, "_connect", side_effect=connect), \
                mock.patch.object(self.module, "_snapshot", return_value="a" * 64), \
                mock.patch.object(self.module, "_script"), \
                mock.patch.object(self.module, "_command", side_effect=command), \
                mock.patch.object(self.module, "_compare", side_effect=compare):
            result = self.verify()
        return result, existing, connections, operations

    def test_nonempty_query_pagination_defect_cannot_pass_the_case_gate(self):
        result, existing, connections, operations = self.simulated_verify(
            mismatch=lambda params, expected: params == ["fixture", ""])
        self.assertEqual(result["outcome"], "fail")
        self.assertEqual(result["cases"][1]["outcome"], "fail")
        self.assertTrue(result["cleanup"]["case_database_dropped"])
        self.assertTrue(all(db.closed for db in connections))
        self.assertEqual(existing, {self.case.dbname})

    def test_stale_license_and_cross_release_targets_cannot_pass_the_case_gate(self):
        for failure in ("license", "targets"):
            def mismatch(params, expected):
                packages = expected["packages"]
                if not packages or packages[0]["name"] != "fixture/semantic": return False
                package = packages[0]
                if failure == "license":
                    return package["latest"] == "10.0.0" and package["license"] == "Apache-2.0"
                return package["latest"] == "9.9.10" and package["targets"] == ["riscv64-linux"]
            with self.subTest(failure=failure):
                result, existing, connections, operations = self.simulated_verify(mismatch=mismatch)
                self.assertEqual(result["outcome"], "fail")
                self.assertTrue(result["cleanup"]["transaction_rolled_back"])
                self.assertTrue(result["cleanup"]["case_database_dropped"])
                self.assertEqual(existing, {self.case.dbname})

    def test_failed_rollback_stays_failed_and_does_not_claim_rollback_success(self):
        result, existing, connections, operations = self.simulated_verify(
            mismatch=lambda params, expected: params == ["fixture/semantic", ""], rollback_failure=True)
        self.assertEqual(result["outcome"], "fail")
        self.assertEqual(result["failure"], "cleanup")
        self.assertFalse(result["cleanup"]["transaction_rolled_back"])
        self.assertTrue(result["cleanup"]["case_database_dropped"])
        self.assertIn("ROLLBACK", [sql for _, sql in operations])
        self.assertTrue(all(db.closed for db in connections))
        self.assertEqual(existing, {self.case.dbname})
        self.assertNotIn(SECRET, json.dumps(result))

    def test_existing_case_database_is_preserved_after_create_failure(self):
        result, existing, connections, operations = self.simulated_verify(collision=True)
        self.assertEqual(result["outcome"], "fail")
        self.assertFalse(result["cleanup"]["case_database_dropped"])
        self.assertEqual(existing, {self.case.dbname, self.case.names + "_sqlcases"})
        self.assertFalse(any(sql.startswith("DROP") for _, sql in operations))
        self.assertTrue(all(db.closed for db in connections))


if __name__ == "__main__":
    unittest.main(verbosity=2)
