"""Exact publisher qualification rejects missing and mismatched evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import contextlib
import importlib
import io
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


class PublisherQualificationTests(unittest.TestCase):
    def test_suite_requires_every_assertion_to_pass(self):
        qualification = self.module()
        class ExpectedFailureCase(unittest.TestCase):
            @unittest.expectedFailure
            def test_contract(self):
                self.fail("This failed assertion cannot qualify the publisher.")
        class UnexpectedSuccessCase(unittest.TestCase):
            @unittest.expectedFailure
            def test_contract(self):
                pass
        for case in (ExpectedFailureCase, UnexpectedSuccessCase):
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(case)
            expected = [case("test_contract").id()]
            with self.subTest(case=case.__name__), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(ValueError):
                qualification.run_suite(suite, expected)

    def test_suite_receipts_go_to_the_log_without_contaminating_the_marker_channel(self):
        qualification = self.module()
        class NoisyCase(unittest.TestCase):
            def test_receipt(self):
                print('{"synthetic":"full-flow receipt"}')
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(NoisyCase)
        expected = [NoisyCase("test_receipt").id()]
        machine, log = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(machine), contextlib.redirect_stderr(log):
            result, ids = qualification.run_suite(suite, expected)
        self.assertEqual(machine.getvalue(), "")
        self.assertIn('{"synthetic":"full-flow receipt"}', log.getvalue())
        self.assertEqual((result.testsRun, ids), (1, expected))

    def test_cli_preserves_safe_smoke_stage_and_redacts_other_exception_details(self):
        qualification = self.module()
        for error, expected in ((qualification.images.SmokeFailure("stage=publisher-libraries failure=contract"),
                                 "stage=publisher-libraries failure=contract"),
                                (OSError("synthetic-private-tool-diagnostic"), "Retain the bounded child log")):
            output, errors = io.StringIO(), io.StringIO()
            with patch.object(qualification, "main", side_effect=error), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(qualification.run_cli(), 1)
            self.assertEqual(output.getvalue(), "")
            self.assertIn(expected, errors.getvalue())
            self.assertNotIn("synthetic-private-tool-diagnostic", errors.getvalue())

    def module(self):
        self.assertTrue((ROOT / "tools/qualify_publisher_image.py").is_file(), "The exact-image publisher qualifier is missing.")
        return importlib.import_module("qualify_publisher_image")

    def receipt(self, qualification):
        return {"schema": 1, "source_revision": "1" * 40, "tests_run": 55, "tests_skipped": 0,
            "test_ids": qualification.required_test_ids(), "security": {"uid": 65532, "gid": 65532,
                "read_only_root": True, "effective_capabilities": 0, "no_new_privileges": True, "cluster_token": False},
            "os": "linux", "architecture": "amd64", "execution": "native", "database_fixture_version": "18.6",
            "loaded_libraries": {"libpq": "16.15", "OpenSSL": "3.5.9"},
            "publisher_sha256": "a" * 64, "source_marker_sha256": "b" * 64,
            "qualification_artifacts": {name: "c" * 64 for name in (
                "/opt/asm/postgres18/bin/initdb", "/opt/asm/postgres18/bin/postgres",
                "/opt/asm/postgres/bin/psql", "/opt/asm/postgres/lib/libpq.so.5",
                "/qualification/source/build/asm-registry-v2", "/qualification/source/build/asm-trust",
                "/usr/sbin/nginx", "/usr/bin/python3", "/usr/bin/node", "/usr/bin/as", "/usr/bin/ld", "/usr/bin/openssl")}}

    def test_exact_test_set_is_present_without_importing_database_fixtures(self):
        qualification = self.module()
        before = set(sys.modules)
        ids = qualification.required_test_ids()
        self.assertEqual(len(ids), 55)
        self.assertEqual(len(set(ids)), 55)
        self.assertEqual(ids, sorted(ids))
        self.assertFalse({"test_authority", "test_distribution_authority", "test_full_flow", "pg18_fixture", "run_pg18"} &
                         (set(sys.modules) - before))

    def test_receipt_refuses_source_skip_missing_case_and_wrong_native_target(self):
        qualification = self.module()
        receipt = self.receipt(qualification)
        files = {"/usr/local/bin/asm-publisher": "a" * 64, "/app/SOURCE.json": "b" * 64}
        qualification.receipt_contract(receipt, "1" * 40, files)
        for key, value in (("source_revision", "2" * 40), ("tests_skipped", 1), ("tests_run", 54),
                           ("test_ids", receipt["test_ids"][:-1]), ("architecture", "arm64"), ("execution", "emulated"),
                           ("publisher_sha256", "e" * 64), ("source_marker_sha256", "e" * 64),
                           ("loaded_libraries", {"libpq": "16.15", "OpenSSL": "3.5.7"}),
                           ("qualification_artifacts", {}),
                           ("security", dict(receipt["security"], effective_capabilities=False))):
            changed = copy.deepcopy(receipt)
            changed[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                qualification.receipt_contract(changed, "1" * 40, files)

    def test_only_one_complete_canonical_bounded_child_marker_is_accepted(self):
        qualification = self.module()
        receipt = self.receipt(qualification)
        body = qualification.registry.json_bytes(receipt)
        files = {"/usr/local/bin/asm-publisher": "a" * 64, "/app/SOURCE.json": "b" * 64}
        self.assertEqual(qualification.parse_child(qualification.PREFIX + body, "1" * 40, files), receipt)
        for raw in (b"", body, qualification.PREFIX + body + qualification.PREFIX + body,
                    qualification.PREFIX + b" " + body, b"private tool output\n" + qualification.PREFIX + body,
                    qualification.PREFIX + b"x" * 65537):
            with self.subTest(length=len(raw)), self.assertRaises(ValueError):
                qualification.parse_child(raw, "1" * 40, files)

    def test_qualifier_must_derive_from_final_and_preserve_every_runtime_hash(self):
        qualification = self.module()
        final = {"RootFS": {"Layers": ["sha256:" + "1" * 64]}}
        derived = {"RootFS": {"Layers": ["sha256:" + "1" * 64, "sha256:" + "2" * 64]}}
        files = {"/usr/local/bin/asm-publisher": "a" * 64, "/opt/asm/openssl/lib/libssl.so.3": "b" * 64,
                 "/app/SOURCE.json": "c" * 64}
        qualification.derived_contract(final, derived, files, files)
        for path in files:
            changed = dict(files)
            changed[path] = "d" * 64
            with self.subTest(path=path), self.assertRaises(ValueError):
                qualification.derived_contract(final, derived, files, changed)
        with self.assertRaises(ValueError):
            qualification.derived_contract(final, {"RootFS": {"Layers": ["sha256:" + "3" * 64]}}, files, files)

    def test_child_logs_are_private_bounded_and_retained_after_failure(self):
        qualification = self.module()
        with tempfile.TemporaryDirectory(prefix="asm-publisher-child-") as directory:
            log = Path(directory) / "child.log"
            output = qualification.run_child([sys.executable, "-c", "import os;os.write(1,b'marker');os.write(2,b'synthetic log')"], log)
            self.assertEqual(output, b"marker")
            self.assertIn(b"synthetic log", log.read_bytes())
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            failed = Path(directory) / "failed.log"
            with self.assertRaises(ValueError):
                qualification.run_child([sys.executable, "-c", "import os;os.write(2,b'x'*2048)"], failed, maximum=1024)
            self.assertTrue(failed.is_file())
            self.assertLessEqual(failed.stat().st_size, 1024)
            delayed = Path(directory) / "delayed.log"
            with self.assertRaises(ValueError):
                qualification.run_child([sys.executable, "-c", "import time;time.sleep(10)"], delayed, timeout=0.05)
            self.assertTrue(delayed.is_file())

    def test_existing_report_is_preserved_before_any_image_command(self):
        qualification = self.module()
        with tempfile.TemporaryDirectory(prefix="asm-publisher-existing-") as directory:
            report = Path(directory) / "report.json"
            report.write_bytes(b"preserve the previous evidence")
            args = SimpleNamespace(output=report, context="owned-context", image="final", qualification_image="derived", revision="1" * 40)
            with patch.object(qualification.platform, "system", return_value="Linux"), \
                    patch.object(qualification.platform, "machine", return_value="x86_64"), \
                    patch.object(qualification.images, "command", side_effect=AssertionError("An image command ran before output refusal.")), \
                    self.assertRaisesRegex(ValueError, "new report"):
                qualification.qualify(args)
            self.assertEqual(report.read_bytes(), b"preserve the previous evidence")
            self.assertEqual(list(Path(directory).iterdir()), [report])

    def test_short_log_writes_retain_every_child_byte(self):
        qualification = self.module()
        original = qualification.os.fdopen
        class ShortWriter:
            def __init__(self, descriptor, *args, **kwargs):
                self.stream = original(descriptor, *args, **kwargs)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return self.stream.__exit__(*args)
            def fileno(self):
                return self.stream.fileno()
            def write(self, body):
                return self.stream.write(body[:max(1, len(body) // 2)])
        with tempfile.TemporaryDirectory(prefix="asm-publisher-short-log-") as directory:
            log = Path(directory) / "child.log"
            with patch.object(qualification.os, "fdopen", side_effect=ShortWriter):
                output = qualification.run_child([sys.executable, "-c", "import os;os.write(1,b'marker');os.write(2,b'synthetic log')"], log)
            self.assertEqual(output, b"marker")
            self.assertEqual(log.stat().st_size, len(b"markersynthetic log"))
            self.assertIn(b"marker", log.read_bytes())
            self.assertIn(b"synthetic log", log.read_bytes())


if __name__ == "__main__":
    unittest.main()
