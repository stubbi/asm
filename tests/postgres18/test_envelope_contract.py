"""A fixed envelope cannot pass with missing resource or cancellation evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import http.client
import importlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import postgres18_fixture as fixture
import test_postgres18_image as harness
try:
    import deployment_envelope as envelope
except ImportError:
    envelope = None


def cgroup_files():
    return {"memory.max": "268435456\n", "memory.current": "48000000\n", "memory.peak": "64000000\n",
            "memory.swap.max": "0\n", "memory.swap.current": "0\n", "cpu.max": "100000 100000\n",
            "memory.events": "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n",
            "memory.events.local": "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n",
            "cpu.stat": "usage_usec 100\nuser_usec 60\nsystem_usec 40\nnr_periods 4\nnr_throttled 1\nthrottled_usec 1000\n"}


class EnvelopeTests(unittest.TestCase):
    def require_envelope(self):
        self.assertIsNotNone(envelope, "The fixed envelope evidence helper is required.")

    def snapshots(self):
        return [{"phase": phase, "monotonic_ns": number + 1, "files": cgroup_files()}
                for number, phase in enumerate(("before-suite", "before:test_case", "after:test_case", "after-suite"))]

    def test_live_cgroup_reader_bounds_and_records_kernel_files(self):
        self.require_envelope()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, value in cgroup_files().items():
                (root / name).write_text(value)
            value = envelope.snapshot(root, "before-suite")
            self.assertEqual(value["files"], cgroup_files())
            (root / "memory.peak").unlink()
            with self.assertRaises((ValueError, OSError)):
                envelope.snapshot(root, "before-suite")
            (root / "memory.peak").write_bytes(b"1" * 8193)
            with self.assertRaises(ValueError):
                envelope.snapshot(root, "before-suite")

    def test_cgroup_closure_accepts_throttling_but_refuses_wrong_limits_oom_and_missing_boundaries(self):
        self.require_envelope()
        envelope.validate_snapshots(self.snapshots(), ["test_case"])
        for name, value in (("memory.max", "536870912\n"), ("memory.swap.max", "268435456\n"),
                            ("memory.current", "268435457\n"), ("memory.peak", "max\n"),
                            ("cpu.max", "200000 100000\n"), ("memory.events", "oom 1\noom_kill 1\n"),
                            ("cpu.stat", "usage_usec 1\nusage_usec 2\n")):
            changed = self.snapshots()
            changed[-1]["files"][name] = value
            with self.subTest(name=name), self.assertRaises(ValueError):
                envelope.validate_snapshots(changed, ["test_case"])
        for changed in (self.snapshots()[:-1], self.snapshots()[1:], self.snapshots() + self.snapshots()):
            with self.assertRaises(ValueError):
                envelope.validate_snapshots(changed, ["test_case"])

    def test_result_samples_include_failed_case_closure_and_raw_output(self):
        self.require_envelope()
        class Failure(unittest.TestCase):
            def test_failure(self):
                self.fail("retained controlled failure")
        samples, output = [], io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, value in cgroup_files().items():
                (root / name).write_text(value)
            with patch.object(envelope, "CGROUP", root), patch("sys.stdout", output):
                result = envelope.run_suite(unittest.defaultTestLoader.loadTestsFromTestCase(Failure), samples, io.StringIO())
        self.assertFalse(result.wasSuccessful())
        envelope.validate_snapshots(samples, [Failure("test_failure").id()])
        self.assertEqual(len(output.getvalue().splitlines()), 4)

    def test_profile_selection_keeps_original_suite_and_wires_the_owned_capacity_provider(self):
        self.require_envelope()
        sys.path.insert(0, str(ROOT / "server"))
        factory = type("OwnedProvider", (), {})
        import test_capacity
        previous_factory, previous_request = test_capacity.CapacityTests.__dict__["postgres_factory"], test_capacity.CapacityTests.__dict__["raw_request"]
        self.addCleanup(setattr, test_capacity.CapacityTests, "postgres_factory", previous_factory)
        self.addCleanup(setattr, test_capacity.CapacityTests, "raw_request", previous_request)
        with patch.dict(os.environ, {}, clear=True):
            suite = harness.load_profile_suite("capacity", factory)
            import test_capacity
            self.assertIs(test_capacity.CapacityTests.postgres_factory, factory)
            self.assertEqual(suite.countTestCases(), 12)
            self.assertEqual(os.environ["ASM_SERVER_CONNECT_NULL_FIXTURE"], "/qualification/fixtures/connect-null.so")
            selected = harness.load_profile_suite("envelope", factory)
            self.assertEqual(selected.countTestCases(), 3)
            self.assertEqual(unittest.defaultTestLoader.loadTestsFromModule(test_capacity).countTestCases(), 12)
            with self.assertRaises(ValueError):
                harness.load_profile_suite("operator", factory)

    def test_fixed_profile_does_not_change_default_limits_or_accept_other_resource_profiles(self):
        self.require_envelope()
        ordinary = harness.base_security("65532:65532", "none")
        selected = harness.base_security("65532:65532", "none", profile="deployment-envelope")
        database = harness.base_security("26:26", "none", database=True, profile="deployment-envelope")
        self.assertEqual(ordinary[ordinary.index("--memory") + 1], "512m")
        self.assertEqual(ordinary[ordinary.index("--cpus") + 1], "2")
        self.assertEqual(selected[selected.index("--memory") + 1], "256m")
        self.assertEqual(selected[selected.index("--memory-swap") + 1], "256m")
        self.assertEqual(selected[selected.index("--cpus") + 1], "1")
        self.assertEqual(database[database.index("--memory") + 1], "2g")
        self.assertEqual(database[database.index("--cpus") + 1], "2")
        with self.assertRaises(ValueError):
            harness.base_security("65532:65532", "none", profile="custom")

    def test_log_provider_requires_exact_owned_identity_before_the_fixed_bounded_read(self):
        self.assertTrue(hasattr(fixture, "postgres_log_bytes"), "The bounded owned log bridge is required.")
        declaration = {"nonce": "b" * 64}
        row = ["180006", "/run/asm-postgres18/data", "b" * 64, "7452238960987612345",
               "asm_fixture_admin", "asm_fixture_admin", "t", "TLSv1.3"]
        identity = fixture.server_contract([row], declaration)
        operations = []
        class Admin:
            def execute(self, query):
                operations.append(query)
                if "pg_control_system" in query:
                    return [row]
                if "/run/asm-postgres18/postgres.log" not in query or "1048577" not in query:
                    raise AssertionError("The log read is not fixed and bounded.")
                return [[b"canceling statement due to statement timeout\n".hex()]]
        body = fixture.postgres_log_bytes(Admin(), declaration, identity)
        self.assertEqual(body, b"canceling statement due to statement timeout\n")
        self.assertEqual(len(operations), 2)
        operations.clear()
        row[2] = "c" * 64
        with self.assertRaises(ValueError):
            fixture.postgres_log_bytes(Admin(), declaration, identity)
        self.assertEqual(len(operations), 1)

    def test_log_provider_refuses_missing_oversized_and_malformed_log_bytes(self):
        self.assertTrue(hasattr(fixture, "postgres_log_bytes"), "The bounded owned log bridge is required.")
        row = ["180006", "/run/asm-postgres18/data", "b" * 64, "7452238960987612345",
               "asm_fixture_admin", "asm_fixture_admin", "t", "TLSv1.3"]
        declaration = {"nonce": "b" * 64}
        identity = fixture.server_contract([row], declaration)
        for value in ([], [[None]], [["not-hex"]], [["ff"]], [["61" * 1048577]]):
            class Admin:
                def execute(self, query):
                    return [row] if "pg_control_system" in query else value
            with self.subTest(value=str(value)[:40]), self.assertRaises(ValueError):
                fixture.postgres_log_bytes(Admin(), declaration, identity)

    def test_real_control_flow_keeps_profile_scope_and_owns_cleanup(self):
        self.require_envelope()
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("scenario.py")), "envelope-pass"],
                                    cwd=temporary, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            report = json.loads((Path(temporary) / "evidence/qualification.json").read_text())
            self.assertEqual(report["scope"], "selected-cnpg18-deployment-envelope")
            self.assertEqual([part["suite"] for part in report["suites"]], ["baseline", "capacity", "envelope"])
            self.assertTrue(all(value["status"] == "removed" for value in report["cleanup"]))
            self.assertEqual(len(list((Path(temporary) / "evidence").glob("*.database.file.log"))), 3)

    def test_profile_failures_preserve_raw_evidence_and_fail_after_owned_cleanup(self):
        self.require_envelope()
        for mode in ("envelope-log-fail", "envelope-oom", "envelope-missing-sample", "envelope-fixture-change",
                     "envelope-fixture-type", "envelope-availability-type", "envelope-cleanup-fail"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                result = subprocess.run([sys.executable, str(Path(__file__).with_name("scenario.py")), mode],
                                        cwd=temporary, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1, result.stderr.decode())
                output = Path(temporary) / "evidence"
                report = json.loads((output / "qualification.json").read_text())
                self.assertEqual(report["status"], "fail")
                self.assertTrue((output / "baseline.stdout.log").exists())
                self.assertTrue((output / "baseline.container.json").exists())
                self.assertTrue(list(output.glob("*.database.log")))
                self.assertFalse((Path(temporary) / ".postgres18-fixture").exists())
                if mode != "envelope-cleanup-fail":
                    self.assertTrue(all(value["status"] == "removed" for value in report["cleanup"]))

    def test_original_admission_module_remains_twelve_cases_after_profile_selection(self):
        sys.path.insert(0, str(ROOT / "server"))
        import test_capacity
        self.assertEqual(unittest.defaultTestLoader.loadTestsFromModule(test_capacity).countTestCases(), 12)

    def test_invalid_profile_cli_fails_before_execution_and_preserves_existing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "existing"
            output.mkdir()
            retained = output / "retained"
            retained.write_bytes(b"unchanged")
            result = subprocess.run([sys.executable, str(ROOT / "tools/test_postgres18_image.py"),
                "--profile", "custom", "--revision", "a" * 40, "--output", str(output)], capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(retained.read_bytes(), b"unchanged")

    def test_transport_failures_are_counted_and_emitted_before_any_success_report(self):
        self.require_envelope()
        records, output = [], io.StringIO()
        for error, outcome in ((TimeoutError("controlled"), "timeout"), (ConnectionResetError("controlled"), "reset"),
                               (http.client.IncompleteRead(b"part", 10), "truncated")):
            def fail():
                raise error
            with patch("sys.stdout", output), self.assertRaises(type(error)):
                envelope.observe(records, "/registry/v1/index.json", fail)
            self.assertEqual(records[-1]["outcome"], outcome)
        self.assertEqual(envelope.request_contract(records), {"valid_requests": 3, "availability_failures": 3})
        self.assertEqual(len(output.getvalue().splitlines()), 3, "A failed producer must retain raw transport outcomes.")

    def test_request_report_cannot_relabel_refusal_or_transport_loss_as_available(self):
        self.require_envelope()
        accepted = {"path": "/health/ready", "valid_request": True, "status": 503,
                    "body_bytes": 132, "outcome": "refused", "elapsed_ns": 1000}
        self.assertEqual(envelope.request_contract([accepted])["availability_failures"], 1)
        for change in ({"outcome": "complete"}, {"status": None, "outcome": "complete"}, {"outcome": "closed"},
                       {"elapsed_ns": True}, {"body_bytes": -1}, {"unexpected": "value"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                envelope.request_contract([dict(accepted, **change)])

    def test_timeout_still_retains_owned_application_state_and_cleanup_evidence(self):
        self.require_envelope()
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("scenario.py")), "envelope-timeout"],
                                    cwd=temporary, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr.decode())
            output = Path(temporary) / "evidence"
            self.assertTrue((output / "baseline.container.json").exists())
            report = json.loads((output / "qualification.json").read_text())
            self.assertEqual(report["failure"]["error"], "TimeoutExpired")
            self.assertTrue(all(value["status"] == "removed" for value in report["cleanup"]))

    def test_slow_reader_keeps_actual_refusal_status_and_checks_response_length(self):
        self.require_envelope()
        sys.path.insert(0, str(ROOT / "server"))
        module = importlib.import_module("test_envelope")
        class Connection:
            def __init__(self, chunks):
                self.chunks = iter(chunks)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def setsockopt(self, *args):
                pass
            def settimeout(self, *args):
                pass
            def connect(self, *args):
                pass
            def sendall(self, *args):
                pass
            def recv(self, *args):
                return next(self.chunks, b"")
        for header, wanted_status in ((b"HTTP/1.1 503 Unavailable\r\nContent-Length: 4\r\n\r\nxxxx", 503),
                                      (b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nxxxx", 200)):
            selected = module.EnvelopeTests("test_eight_slow_maximum_exports_preserve_bytes_and_recover")
            selected.port, selected.request_records = 12345, []
            with patch.object(module.socket, "socket", return_value=Connection([header])), patch("sys.stdout", io.StringIO()), \
                    self.assertRaises(AssertionError):
                selected.slow_export("/registry/v1/index.json", 4)
            self.assertEqual(selected.request_records[0]["status"], wanted_status)
            self.assertEqual(selected.request_records[0]["outcome"], "refused" if wanted_status == 503 else "truncated")


if __name__ == "__main__":
    unittest.main()
