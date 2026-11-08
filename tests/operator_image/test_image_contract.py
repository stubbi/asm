"""Qualification must bind actual image bytes, dependencies, and applicable tests.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import test_operator_image as image


class ImageContractTests(unittest.TestCase):
    def smoke_fixture(self, directory, *, failed_stage, status=127, stdout=b"", stderr=b"synthetic-private-diagnostic"):
        inspected = self.fixture()
        inspected["Config"]["Entrypoint"] = ["/usr/local/bin/asm-publisher"]
        inspected["Config"]["Labels"].update({"org.opencontainers.image.source": "https://github.com/stubbi/asm",
            "org.opencontainers.image.licenses": "AGPL-3.0-or-later"})
        source = json.dumps({"source_revision": "3" * 40, "repository": "https://github.com/stubbi/asm", "files": {}}).encode()
        process = b"Uid:\t65532 65532 65532 65532\nGid:\t65532 65532 65532 65532\nCapEff:\t0\nNoNewPrivs:\t1\n"

        def boundary(arguments, **kwargs):
            if "inspect" in arguments:
                return subprocess.CompletedProcess(arguments, 0, json.dumps([inspected]).encode(), b"")
            if arguments[-1] == "/app/SOURCE.json":
                return subprocess.CompletedProcess(arguments, 0, source, b"")
            if arguments[-1] == "/proc/self/status":
                return subprocess.CompletedProcess(arguments, 0, process, b"")
            stage = "invalid-input" if arguments[-1] == "--not-an-option" else "publisher-libraries" if "/usr/bin/ldd" in arguments else "help"
            if stage == failed_stage:
                return subprocess.CompletedProcess(arguments, status, stdout, stderr)
            return subprocess.CompletedProcess(arguments, 64, b"", b"Usage: asm-publisher serve\n")

        args = SimpleNamespace(context="owned-context", image="synthetic-local-image", revision="3" * 40,
                               smoke_kind="publisher", output=str(Path(directory) / "report.json"))
        return args, boundary

    def test_smoke_failure_identifies_the_command_stage_without_private_tool_output(self):
        with tempfile.TemporaryDirectory(prefix="asm-smoke-failure-") as directory:
            args, boundary = self.smoke_fixture(directory, failed_stage="publisher-libraries")
            with patch.object(image.subprocess, "run", side_effect=boundary), \
                    self.assertRaisesRegex(ValueError, r"stage=publisher-libraries.*command-status.*expected=0 actual=127") as stopped:
                image.runtime_smoke(args)
            self.assertNotIn("synthetic-private-diagnostic", str(stopped.exception))
            self.assertFalse(Path(args.output).exists())

    def test_publisher_invalid_input_still_refuses_nonempty_machine_output(self):
        with tempfile.TemporaryDirectory(prefix="asm-smoke-output-") as directory:
            args, boundary = self.smoke_fixture(directory, failed_stage="invalid-input", status=64,
                                                stdout=b"synthetic-private-diagnostic", stderr=b"")
            with patch.object(image.subprocess, "run", side_effect=boundary), \
                    self.assertRaisesRegex(ValueError, "Invalid input emitted machine output") as stopped:
                image.runtime_smoke(args)
            self.assertNotIn("synthetic-private-diagnostic", str(stopped.exception))
            self.assertFalse(Path(args.output).exists())

    def test_v2_inspection_refuses_wrong_entrypoint_identity_or_writable_image_volume(self):
        for role, entrypoint in (("publisher", ["/usr/local/bin/asm-publisher"]),
                ("checker", ["/usr/bin/python3", "-B", "-I", "/app/tools/checker_entrypoint.py"])):
            value = self.fixture()
            value["Config"]["Entrypoint"] = entrypoint
            value["Config"]["Labels"].update({"org.opencontainers.image.source": "https://github.com/stubbi/asm",
                "org.opencontainers.image.licenses": "AGPL-3.0-or-later"})
            self.assertEqual(image.v2_image_contract(value, "3" * 40, role), "sha256:" + "1" * 64)
            for field, changed in (("Entrypoint", ["/bin/sh"]), ("User", "0:0"), ("Volumes", {"/input": {}})):
                refused = copy.deepcopy(value)
                refused["Config"][field] = changed
                with self.subTest(role=role, field=field), self.assertRaises(ValueError):
                    image.v2_image_contract(refused, "3" * 40, role)
            with self.assertRaises(ValueError):
                image.v2_image_contract(value, "4" * 40, role)

    def fixture(self):
        return {"Architecture": "amd64", "Os": "linux", "Id": "sha256:" + "1" * 64,
                "RootFS": {"Layers": ["sha256:" + "2" * 64]}, "Config": {"User": "65532:65532",
                "Entrypoint": ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"], "Cmd": ["--help"],
                "Labels": {"org.opencontainers.image.revision": "3" * 40}}}

    def test_image_target_user_entrypoint_source_and_layers_are_mandatory(self):
        value = self.fixture()
        self.assertEqual(image.image_contract(value, "3" * 40), value["Id"])
        for key, replacement in (("Architecture", "arm64"), ("Os", "windows"), ("Id", "mutable-tag")):
            changed = copy.deepcopy(value)
            changed[key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                image.image_contract(changed, "3" * 40)
        value["Config"]["User"] = "0:0"
        with self.assertRaises(ValueError):
            image.image_contract(value, "3" * 40)

    def test_derived_qualification_cannot_change_a_runtime_dependency(self):
        runtime = self.fixture()
        qualifier = copy.deepcopy(runtime)
        qualifier["RootFS"]["Layers"].append("sha256:" + "4" * 64)
        files = {"/app/tools/registry_admin.py": "a" * 64, "/lib/libssl.so.3": "b" * 64}
        image.derived_contract(runtime, qualifier, files, files)
        changed = dict(files, **{"/lib/libssl.so.3": "c" * 64})
        with self.assertRaises(ValueError):
            image.derived_contract(runtime, qualifier, files, changed)
        qualifier["RootFS"]["Layers"][0] = "different"
        with self.assertRaises(ValueError):
            image.derived_contract(runtime, qualifier, files, files)

    def test_only_the_named_macos_case_is_inapplicable_on_linux(self):
        def result(skips):
            return SimpleNamespace(testsRun=35, skipped=skips, wasSuccessful=lambda: True)
        named = SimpleNamespace(id=lambda: "test_database.CatalogDatabaseTests.test_extended_acl_on_private_key_cannot_reach_mutation")
        self.assertEqual(len(image.test_contract(result([(named, "macOS extended ACL interface")]), 35)), 1)
        applicable = SimpleNamespace(id=lambda: "test_prepare.RootProjectedImageTests.test_real_root_gid65532_projection_and_policy_failures")
        with self.assertRaises(ValueError):
            image.test_contract(result([(applicable, "fixture missing")]), 35)
        with self.assertRaises(ValueError):
            image.test_contract(result([]), 36)


if __name__ == "__main__":
    unittest.main()
