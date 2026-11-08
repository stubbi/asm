"""Final checker qualification rejects missing cases and forged bound receipts.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import contextlib
import hashlib
import importlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import operator_source
import publication_check
import registry

SCRIPT = ROOT / "tools/qualify_checker_image.py"
CASES = ("absent-object", "corrupt-object", "feature-mismatch", "linked-object", "malformed-archive",
         "malformed-manifest", "target-mismatch", "valid-features", "valid-source")
REVISION = "a" * 40
POLICY = "b" * 64


class CheckerImageQualificationTests(unittest.TestCase):
    def module(self):
        self.assertTrue(SCRIPT.exists(), "The final checker image has no qualification command.")
        return importlib.import_module("qualify_checker_image")

    def receipt(self, case):
        return {"schema": 1, "task_id": case["task_id"], "manifest_sha256": case["manifest_sha256"],
            "checker_revision": REVISION, "policy_sha256": POLICY, "outcome": case["expected_outcome"],
            "objects": [{**item, "outcome": case["expected_outcome"]} for item in case["objects"]]}

    def test_every_fixed_fixture_has_the_expected_observable_checker_result(self):
        image = self.module()
        outcomes = {"valid-source": "pass", "valid-features": "pass", "corrupt-object": "error",
            "malformed-archive": "fail", "absent-object": "error", "linked-object": "error",
            "target-mismatch": "fail", "feature-mismatch": "fail"}
        self.assertEqual(image.REQUIRED_CASES, CASES)
        with tempfile.TemporaryDirectory(prefix="asm-checker-cases-") as directory:
            for identity in CASES:
                with self.subTest(case=identity):
                    root = Path(directory).resolve() / identity
                    case = image.make_fixture(root, identity)
                    before = image.snapshot(root)
                    if identity == "malformed-manifest":
                        with self.assertRaises(registry.RegistryError):
                            publication_check.check(case["task_id"], root / "manifest.json", root / "objects", REVISION)
                        self.assertEqual(case["exit_status"], 1)
                    else:
                        result = publication_check.check(case["task_id"], root / "manifest.json", root / "objects", REVISION)
                        self.assertEqual(result["outcome"], outcomes[identity])
                        self.assertEqual(case["expected_outcome"], outcomes[identity])
                        self.assertEqual(case["exit_status"], 0)
                    self.assertEqual(image.snapshot(root), before)

    def test_forged_receipt_cannot_replace_any_task_manifest_policy_source_or_object_binding(self):
        image = self.module()
        with tempfile.TemporaryDirectory(prefix="asm-checker-receipt-") as directory:
            case = image.make_fixture(Path(directory).resolve() / "task", "valid-source")
            receipt = self.receipt(case)
            raw = registry.json_bytes(receipt)
            self.assertEqual(image.receipt_contract(raw, case, REVISION, POLICY), receipt)
            for field, replacement in (("schema", True), ("task_id", "c" * 32),
                    ("manifest_sha256", "c" * 64), ("checker_revision", "c" * 40),
                    ("policy_sha256", "c" * 64), ("outcome", "error"), ("objects", [])):
                forged = deepcopy(receipt)
                forged[field] = replacement
                with self.subTest(field=field), self.assertRaises(ValueError):
                    image.receipt_contract(registry.json_bytes(forged), case, REVISION, POLICY)
            for field, replacement in (("sha256", "c" * 64), ("bytes", 1),
                    ("bytes", float(case["objects"][0]["bytes"])), ("outcome", "fail")):
                forged = deepcopy(receipt)
                forged["objects"][0][field] = replacement
                with self.subTest(object_field=field), self.assertRaises(ValueError):
                    image.receipt_contract(registry.json_bytes(forged), case, REVISION, POLICY)
            for forged in (b" " + raw, raw + raw, raw.replace(b'"schema": 1', b'"schema": 1,"schema": 1'),
                           json.dumps(receipt).encode(), b"x" * 32769):
                with self.subTest(raw_bytes=len(forged)), self.assertRaises(ValueError):
                    image.receipt_contract(forged, case, REVISION, POLICY)

    def test_source_marker_and_runtime_bytes_must_match_accepted_committed_source(self):
        image = self.module()
        accepted = {name: hashlib.sha256(name.encode()).hexdigest() for name in operator_source.FILES}
        source = {"schema": 1, "repository": "https://github.com/stubbi/asm", "source_revision": REVISION,
            "bundle_sha256": "d" * 64, "bundle_bytes": 128, "files": accepted.copy()}
        runtime = {"/app/" + name: accepted[name] for name in image.CHECKER_FILES}
        runtime["/app/SOURCE.json"] = hashlib.sha256(registry.json_bytes(source)).hexdigest()
        report = {"source": source, "runtime_files": runtime}
        image.source_contract(report, REVISION, accepted)
        for location in ("marker", "runtime", "marker-digest"):
            changed = deepcopy(report)
            if location == "marker":
                changed["source"]["files"]["tools/publication_check.py"] = "f" * 64
                changed["runtime_files"]["/app/tools/publication_check.py"] = "f" * 64
            elif location == "runtime":
                changed["runtime_files"]["/app/tools/registry_storage.py"] = "f" * 64
            else:
                changed["runtime_files"]["/app/SOURCE.json"] = "f" * 64
            with self.subTest(location=location), self.assertRaises(ValueError):
                image.source_contract(changed, REVISION, accepted)

    @contextlib.contextmanager
    def orchestration(self, directory, *, malformed_error=None, forged_source=False):
        image = self.module()
        args = SimpleNamespace(context="default", image="synthetic-final", revision=REVISION,
                               output=str(Path(directory) / "report.json"))
        accepted = {name: hashlib.sha256((ROOT / name).read_bytes() if name in image.CHECKER_FILES
                                       else name.encode()).hexdigest() for name in operator_source.FILES}
        source = {"schema": 1, "repository": operator_source.REPOSITORY, "source_revision": REVISION,
            "bundle_sha256": "d" * 64, "bundle_bytes": 128, "files": accepted}
        runtime = {"/app/" + name: accepted[name] for name in image.CHECKER_FILES}
        runtime["/app/SOURCE.json"] = hashlib.sha256(registry.json_bytes(source)).hexdigest()
        def smoke(selected):
            Path(selected.output).write_bytes(registry.json_bytes({"schema": 1, "status": "pass",
                "scope": "v2-runtime-smoke", "role": "checker", "source_revision": REVISION,
                "runtime_image_id": "sha256:" + "e" * 64, "source": source, "runtime_files": runtime,
                "help_exit_status": 0, "daemon": "linux/x86_64"}))
        def docker(arguments, **_):
            if "--task" not in arguments:
                return subprocess.CompletedProcess(arguments, 0,
                    b'{"read_only_root":true,"cluster_token":false}\n', b"")
            mount = arguments[arguments.index("--mount") + 1]
            root = Path(mount.split(",src=", 1)[1].split(",dst=", 1)[0])
            if root.name == "malformed-manifest" and malformed_error is not None:
                return subprocess.CompletedProcess(arguments, 1, b"", malformed_error)
            try:
                receipt = publication_check.check(arguments[-1], root / "manifest.json", root / "objects", REVISION)
                if forged_source:
                    receipt["checker_revision"] = "f" * 40
                return subprocess.CompletedProcess(arguments, 0, registry.json_bytes(receipt), b"")
            except registry.RegistryError:
                return subprocess.CompletedProcess(arguments, 1, b"",
                    b"Asm checker: input is unavailable or invalid. Inspect the retained task and staged files.\n")
        with patch.object(image, "native_contract"), patch.object(image, "accepted_source", return_value=accepted), \
                patch.object(image, "runtime_smoke", side_effect=smoke), patch.object(image.os, "chown"), \
                patch.object(image, "run_case", side_effect=docker):
            yield args

    def test_qualifier_writes_complete_bound_report_and_preserves_existing_reports(self):
        image = self.module()
        with tempfile.TemporaryDirectory(prefix="asm-checker-orchestration-") as directory:
            with self.orchestration(directory) as args:
                image.qualify(args)
                report = json.loads(Path(args.output).read_bytes())
                self.assertEqual(report["test_ids"], list(CASES))
                self.assertEqual((report["tests_run"], report["tests_skipped"]), (9, 0))
                self.assertEqual([case["id"] for case in report["cases"]], list(CASES))
                self.assertEqual(report["checker_policy_sha256"], publication_check.policy_digest())
                self.assertTrue(report["inputs_unchanged"])
                before = Path(args.output).read_bytes()
                with self.assertRaises(FileExistsError):
                    image.qualify(args)
                self.assertEqual(Path(args.output).read_bytes(), before)
            Path(args.output).unlink()
            with self.orchestration(directory, forged_source=True) as args, self.assertRaises(ValueError):
                image.qualify(args)
            self.assertFalse(Path(args.output).exists())

    def test_daemon_and_source_identity_errors_cannot_count_as_malformed_input_refusal(self):
        image = self.module()
        for error in (b"Cannot connect to the Docker daemon at unix:///var/run/docker.sock.\n",
                      b"Asm checker: image source identity is invalid. Use a qualified image.\n"):
            with self.subTest(error=error), tempfile.TemporaryDirectory(prefix="asm-checker-false-refusal-") as directory:
                with self.orchestration(directory, malformed_error=error) as args, self.assertRaises(ValueError):
                    image.qualify(args)
                self.assertFalse(Path(args.output).exists())

    def test_skips_missing_cases_duplicates_and_emulation_cannot_produce_passing_coverage(self):
        image = self.module()
        report = {"test_ids": list(CASES), "tests_run": 9, "tests_skipped": 0,
                  "execution": "native", "os": "linux", "architecture": "amd64"}
        image.coverage_contract(report)
        for field, value in (("test_ids", list(CASES[:-1])), ("test_ids", list(CASES[:-1]) + [CASES[0]]),
                ("tests_run", 8), ("tests_run", True), ("tests_skipped", 1), ("tests_skipped", False),
                ("execution", "emulated"), ("architecture", "arm64"), ("os", "Darwin")):
            changed = deepcopy(report)
            changed[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                image.coverage_contract(changed)

    def test_non_native_host_or_daemon_and_nonroot_fixture_preparation_fail_before_tasks(self):
        image = self.module()
        for system, architecture, uid, daemon in (("Darwin", "arm64", 0, "linux/amd64"),
                ("Linux", "aarch64", 0, "linux/amd64"), ("Linux", "x86_64", 502, "linux/amd64"),
                ("Linux", "x86_64", 0, "linux/aarch64")):
            with self.subTest(system=system, architecture=architecture, uid=uid, daemon=daemon), \
                    patch.object(image.platform, "system", return_value=system), \
                    patch.object(image.platform, "machine", return_value=architecture), \
                    patch.object(image.os, "geteuid", return_value=uid), \
                    patch.object(image, "command", return_value=(daemon + "\n").encode()), \
                    self.assertRaises(ValueError):
                image.native_contract(["docker", "--context", "default"])

    def test_actual_case_arguments_preserve_final_entrypoint_and_mount_one_private_input_only(self):
        image = self.module()
        with tempfile.TemporaryDirectory(prefix="asm-checker-command-") as directory:
            root = Path(directory).resolve() / "task"
            case = image.make_fixture(root, "valid-source")
            argv = image.case_arguments(["docker", "--context", "default"], "sha256:" + "d" * 64,
                                        "asm-checker-test", root, case["task_id"])
            self.assertEqual(argv[-3:], ["sha256:" + "d" * 64, "--task", case["task_id"]])
            self.assertNotIn("--entrypoint", argv)
            self.assertEqual(argv.count("--mount"), 1)
            self.assertEqual(argv[argv.index("--mount") + 1], "type=bind,src=" + str(root) + ",dst=/input,readonly")
            for option, value in (("--user", "65532:65532"), ("--network", "none"), ("--cap-drop", "ALL"),
                    ("--security-opt", "no-new-privileges"), ("--pids-limit", "16"),
                    ("--memory", "512m"), ("--cpus", "1")):
                self.assertEqual(argv[argv.index(option) + 1], value)
            self.assertIn("--read-only", argv)
            self.assertNotIn("--env", argv)

    def test_changed_bytes_link_targets_and_permissions_are_detected_without_following_links(self):
        image = self.module()
        with tempfile.TemporaryDirectory(prefix="asm-checker-snapshot-") as directory:
            root = Path(directory).resolve() / "task"
            case = image.make_fixture(root, "linked-object")
            before = image.snapshot(root)
            link = root / "objects" / (case["task_id"] + "-" + case["objects"][0]["sha256"])
            link.unlink()
            link.symlink_to("../other")
            self.assertNotEqual(image.snapshot(root), before)
            manifest = root / "manifest.json"
            before = image.snapshot(root)
            manifest.chmod(0o644)
            self.assertNotEqual(image.snapshot(root), before)
            before = image.snapshot(root)
            manifest.write_bytes(b"{}\n")
            self.assertNotEqual(image.snapshot(root), before)

    def test_case_child_output_and_time_are_bounded(self):
        image = self.module()
        result = image.run_case([sys.executable, "-I", "-c", "import sys;sys.stdout.write('receipt');sys.exit(1)"], timeout=2)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b"receipt", b""))
        for program, timeout in (("import sys;sys.stdout.write('x'*32769)", 2),
                                 ("import sys;sys.stderr.write('x'*65537)", 2),
                                 ("import time;time.sleep(2)", 0.05)):
            with self.subTest(program=program), self.assertRaises(ValueError):
                image.run_case([sys.executable, "-I", "-c", program], timeout=timeout)

    def test_failed_qualification_names_its_stage_without_exposing_child_diagnostics(self):
        image = self.module()
        def stopped(args, state=None):
            if state is not None:
                state["stage"] = "receipt-corrupt-object"
            raise ValueError("synthetic private child diagnostic")
        errors = io.StringIO()
        with patch.object(image, "qualify", side_effect=stopped), contextlib.redirect_stderr(errors):
            status = image.main(["--context", "default", "--revision", REVISION, "--image", "synthetic",
                                 "--output", "/absent/report.json"])
        self.assertEqual(status, 1)
        self.assertIn("stage=receipt-corrupt-object", errors.getvalue())
        self.assertNotIn("synthetic private child diagnostic", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
