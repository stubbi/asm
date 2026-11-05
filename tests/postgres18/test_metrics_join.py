"""A source join must retain metrics coverage and the fixed fixture bindings.

SPDX-License-Identifier: AGPL-3.0-or-later
These checks exercise validators and orchestration with controlled metadata.
"""
import copy
import io
import importlib
import os
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests"), str(ROOT / "server")]
import test_postgres18_image as harness
from server_metrics_fixture import CASES, metrics
import test_server_image_admission as admission
from test_envelope_contract import cgroup_files


def report(suite="http"):
    return {"schema": 1, "status": "pass", "scope": "selected-cnpg18-compatibility", "suite": suite,
            "source_revision": "a" * 40, "tests_run": 22, "not_applicable": [], "applicable_tests_skipped": 0,
            "client_libpq_version": 160015, "migration_sha384": "b" * 96,
            "database": {"server_version_num": 180006, "data_directory": harness.fixture.DATA,
                         "nonce": "c" * 64, "system_identifier": "7452238960987612345",
                         "session_user": "asm_fixture_admin", "tls_protocol": "TLSv1.3"},
            "metrics": metrics(), "metrics_test_tools": metrics()["test_tools"], "cases": list(CASES["baseline"])}


class MetricsJoinTests(unittest.TestCase):
    def validate(self, value):
        return harness.report_contract(value, "http", "a" * 40, "c" * 64, "b" * 96,
                                       expected_metrics_tools=metrics()["test_tools"])

    def test_sixteen_case_pg18_receipt_cannot_qualify_the_joined_http_source(self):
        legacy = report()
        legacy["tests_run"] = 16
        del legacy["metrics"], legacy["metrics_test_tools"]
        with self.assertRaises(ValueError):
            harness.report_contract(legacy, "http", "a" * 40, "c" * 64, "b" * 96)

    def test_pg18_http_requires_all_six_http_and_nineteen_unit_identities(self):
        self.assertIn("expected_metrics_tools", __import__("inspect").signature(harness.report_contract).parameters,
                      "The PostgreSQL 18 report must bind the actual metrics tools.")
        self.validate(report())
        for kind in ("http_tests", "checks"):
            complete = report()
            values = complete["metrics"]["unit"] if kind == "checks" else complete["metrics"]
            for index in range(len(values[kind])):
                changed = copy.deepcopy(complete)
                selected = changed["metrics"]["unit"] if kind == "checks" else changed["metrics"]
                selected[kind].pop(index)
                with self.subTest(kind=kind, index=index), self.assertRaises(ValueError):
                    self.validate(changed)
        for count in (16, 21):
            changed = report()
            changed["tests_run"] = count
            with self.subTest(count=count), self.assertRaises(ValueError):
                self.validate(changed)

    def test_profile_selection_supplies_both_fixtures_without_applying_metrics_to_capacity(self):
        for name, wanted in (("baseline", 22), ("capacity", 12), ("envelope", 3)):
            module, cls_name, _ = harness.envelope.SUITES[name]
            cls = getattr(importlib.import_module(module), cls_name)
            previous_factory, previous_request = cls.__dict__["postgres_factory"], cls.__dict__["raw_request"]
            self.addCleanup(setattr, cls, "postgres_factory", previous_factory)
            self.addCleanup(setattr, cls, "raw_request", previous_request)
            if "metrics_request" in cls.__dict__:
                self.addCleanup(setattr, cls, "metrics_request", cls.__dict__["metrics_request"])
            with patch.dict(os.environ, {}, clear=True):
                selected = harness.load_profile_suite(name, object)
                self.assertEqual(selected.countTestCases(), wanted)
                self.assertEqual(os.environ.get("ASM_METRICS_TEST_DIRECTORY"), "/qualification/server")
                self.assertEqual(os.environ["ASM_SERVER_CONNECT_NULL_FIXTURE"], "/qualification/fixtures/connect-null.so")
                if name == "baseline":
                    self.assertEqual(harness.server.metrics_suite_names(selected), metrics()["http_tests"])

    def test_fixed_profile_observes_valid_metrics_requests_in_owned_fault_children(self):
        cls = importlib.import_module("test_runtime").RuntimeTests
        self.addCleanup(setattr, cls, "postgres_factory", cls.__dict__["postgres_factory"])
        self.addCleanup(setattr, cls, "raw_request", cls.__dict__["raw_request"])
        def response(selected, port, path, **arguments):
            return 503, {}, b"controlled metrics refusal"
        with patch.object(cls, "metrics_request", response), patch("sys.stdout", io.StringIO()), patch.dict(os.environ, {}, clear=True):
            harness.load_profile_suite("baseline", object)
            selected = cls("test_health_and_exact_source_identity")
            self.assertEqual(selected.metrics_request(12345, "/metrics")[0], 503)
            self.assertEqual(harness.envelope.request_contract(cls.request_records),
                             {"valid_requests": 1, "availability_failures": 1})

    def test_all_baseline_and_capacity_case_identities_are_required(self):
        values = admission.parts()
        for name, part in values.items():
            part["cases"] = list(CASES[name])
        try:
            admission.image.aggregate_reports(values, "amd64", "c" * 40)
        except ValueError as error:
            self.fail("The complete joined case identities must qualify: " + str(error))
        for name in ("baseline", "capacity"):
            for index in range(len(CASES[name])):
                changed = copy.deepcopy(values)
                changed[name]["cases"].pop(index)
                with self.subTest(suite=name, index=index), self.assertRaises(ValueError):
                    admission.image.aggregate_reports(changed, "amd64", "c" * 40)

    def test_fixed_profile_requires_each_case_and_baseline_metrics_with_exact_tools(self):
        null_fixture = {"path": "/qualification/fixtures/connect-null.so", "sha256": "1" * 64,
                        "bytes": 16384, "mode": "0444", "uid": 0, "gid": 0}
        for suite in ("baseline", "capacity", "envelope"):
            value = report(suite)
            if suite != "baseline":
                del value["metrics"]
            cases = [{"baseline": "test_runtime", "capacity": "test_capacity", "envelope": "test_envelope"}[suite]
                     + "." + name for name in CASES[suite]]
            phases = ["before-suite"] + [phase + case for case in cases for phase in ("before:", "after:")] + ["after-suite"]
            value.update(scope=harness.envelope.SCOPE, profile="deployment-envelope",
                         measurement_scope=harness.envelope.MEASUREMENT_SCOPE, tests_run=len(cases), cases=cases,
                         fixture=null_fixture,
                         cgroup=[{"phase": phase, "monotonic_ns": index + 1, "files": cgroup_files()}
                                 for index, phase in enumerate(phases)],
                         requests=[{"path": "/metrics", "valid_request": True, "status": 200,
                                    "body_bytes": 5600, "outcome": "complete", "elapsed_ns": 1000}],
                         availability={"valid_requests": 1, "availability_failures": 0})
            arguments = (suite, "a" * 40, "c" * 64, "b" * 96, "deployment-envelope", null_fixture, metrics()["test_tools"])
            harness.report_contract(value, *arguments)
            for index in range(len(cases)):
                changed = copy.deepcopy(value)
                changed["cases"].pop(index)
                with self.subTest(suite=suite, index=index), self.assertRaises(ValueError):
                    harness.report_contract(changed, *arguments)
            changed = copy.deepcopy(value)
            changed["metrics_test_tools"]["metrics-faults.so"]["sha256"] = "4" * 64
            with self.subTest(suite=suite), self.assertRaises(ValueError):
                harness.report_contract(changed, *arguments)

    def test_changed_pg18_derived_metrics_artifact_fails_before_suite_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("scenario.py")),
                                     "envelope-metrics-tool-change"], cwd=temporary, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr.decode())
            value = json.loads((Path(temporary) / "evidence/qualification.json").read_text())
            self.assertEqual(value["status"], "fail")
            self.assertEqual(value["suites"], [])
            self.assertIn("changed a metrics qualification tool", value["failure"]["message"])
            self.assertTrue(all(item["status"] == "removed" for item in value["cleanup"]))

    def test_strict_image_aggregate_requires_baseline_metrics_and_shared_tools(self):
        old = admission.parts()
        old["baseline"]["tests_run"] = 16
        old["baseline"].pop("metrics", None)
        with self.assertRaises(ValueError):
            admission.image.aggregate_reports(old, "amd64", "c" * 40)
        values = admission.parts()
        for part in values.values():
            part["metrics_test_tools"] = metrics()["test_tools"]
        values["baseline"].update(tests_run=22, metrics=metrics())
        self.assertTrue(hasattr(admission.image, "metrics_evidence_contract"), "The strict child validator lost metrics coverage.")
        joined = admission.image.aggregate_reports(values, "amd64", "c" * 40)
        self.assertEqual(joined["tests_run"], 34)
        self.assertEqual(joined["metrics"], metrics())
        admission.image.runtime_evidence_contract(joined, "amd64", "c" * 40)
        changed = copy.deepcopy(joined)
        changed["metrics"]["unit"]["checks"].pop()
        with self.assertRaises(ValueError):
            admission.image.runtime_evidence_contract(changed, "amd64", "c" * 40)
        changed = copy.deepcopy(values)
        changed["capacity"]["metrics_test_tools"]["metrics-faults.so"]["sha256"] = "4" * 64
        with self.assertRaises(ValueError):
            admission.image.aggregate_reports(changed, "amd64", "c" * 40)


if __name__ == "__main__":
    unittest.main()
