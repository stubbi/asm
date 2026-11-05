"""Qualification cannot remove an unowned container or hide cleanup failures.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import test_postgres18_image as harness


class HarnessTests(unittest.TestCase):
    def container(self):
        return {"Id": "1" * 64, "Name": "/asm-postgres18-test", "Image": "sha256:" + "2" * 64,
                "Config": {"User": "26:26", "Labels": {"asm.qualification.nonce": "3" * 64}},
                "HostConfig": {"ReadonlyRootfs": True, "NetworkMode": "none", "PortBindings": {},
                               "CapDrop": ["ALL"], "CapAdd": None, "SecurityOpt": ["no-new-privileges"], "Privileged": False,
                               "PidsLimit": 128, "Memory": 2147483648, "NanoCpus": 2000000000},
                "Mounts": [], "State": {"Running": True}}

    def test_only_the_recorded_image_identity_and_isolation_can_own_a_container(self):
        accepted = self.container()
        arguments = ("asm-postgres18-test", "sha256:" + "2" * 64, "3" * 64, "26:26", "none")
        self.assertEqual(harness.container_contract(accepted, *arguments), "1" * 64)
        for path, value in ((["Id"], "mutable-name"), (["Name"], "/other"),
                            (["Image"], "sha256:" + "4" * 64), (["Config", "User"], "0:0"),
                            (["Config", "Labels", "asm.qualification.nonce"], "4" * 64),
                            (["HostConfig", "ReadonlyRootfs"], False), (["HostConfig", "NetworkMode"], "host"),
                            (["HostConfig", "PortBindings"], {"5432/tcp": [{}]}),
                            (["HostConfig", "Memory"], 0), (["HostConfig", "NanoCpus"], 0), (["HostConfig", "PidsLimit"], 0),
                            (["HostConfig", "CapAdd"], ["SYS_ADMIN"]),
                            (["HostConfig", "Privileged"], True), (["Mounts"], [{"Type": "bind"}])):
            changed = copy.deepcopy(accepted)
            node = changed
            for part in path[:-1]:
                node = node[part]
            node[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(ValueError):
                harness.container_contract(changed, *arguments)

    def test_derived_image_cannot_replace_a_base_layer_or_loaded_dependency(self):
        base = {"RootFS": {"Layers": ["sha256:" + "1" * 64]}}
        derived = {"RootFS": {"Layers": ["sha256:" + "1" * 64, "sha256:" + "2" * 64]}}
        harness.derived_contract(base, derived, {"postgres": "a" * 64}, {"postgres": "a" * 64})
        with self.assertRaises(ValueError):
            harness.derived_contract(base, derived, {"postgres": "a" * 64}, {"postgres": "b" * 64})
        derived["RootFS"]["Layers"][0] = "sha256:" + "3" * 64
        with self.assertRaises(ValueError):
            harness.derived_contract(base, derived, {}, {})

    def test_failed_cleanup_is_a_failed_gate_and_other_owned_cleanup_continues(self):
        removed = []
        def remove(identity):
            removed.append(identity)
            if identity == "first":
                raise OSError("controlled removal failure")
        result = harness.cleanup_owned(["first", "second"], remove)
        self.assertEqual(removed, ["second", "first"])
        self.assertEqual(result, [{"identity": "second", "status": "removed"},
                                  {"identity": "first", "status": "error", "error": "OSError"}])
        with self.assertRaises(ValueError):
            harness.cleanup_contract(result)

    def test_report_cannot_claim_pass_with_wrong_version_nonce_counts_or_migration(self):
        report = {"schema": 1, "status": "pass", "scope": "selected-cnpg18-compatibility", "suite": "http",
                  "source_revision": "a" * 40, "tests_run": 16, "not_applicable": [], "applicable_tests_skipped": 0,
                  "client_libpq_version": 160015, "migration_sha384": "c" * 96,
                  "database": {"server_version_num": 180006, "data_directory": "/run/asm-postgres18/data", "nonce": "b" * 64,
                               "system_identifier": "7452238960987612345", "session_user": "asm_fixture_admin", "tls_protocol": "TLSv1.3"}}
        harness.report_contract(report, "http", "a" * 40, "b" * 64, "c" * 96)
        for key, value in (("schema", True), ("tests_run", True), ("tests_run", 11), ("client_libpq_version", 180006),
                           ("migration_sha384", "d" * 96), ("not_applicable", [{"id": "skip"}]), ("applicable_tests_skipped", 1)):
            changed = dict(report, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                harness.report_contract(changed, "http", "a" * 40, "b" * 64, "c" * 96)
        changed = copy.deepcopy(report)
        changed["database"]["nonce"] = "d" * 64
        with self.assertRaises(ValueError):
            harness.report_contract(changed, "http", "a" * 40, "b" * 64, "c" * 96)

    def test_cli_accepts_no_database_target_or_production_credential_argument(self):
        result = subprocess.run([sys.executable, str(ROOT / "tools/test_postgres18_image.py"), "--revision", "a" * 40,
                                 "--database-url", "postgresql://production.invalid/asm"], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")

    def test_unsupported_host_fails_before_any_docker_command_or_output_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence"
            with patch.object(harness.platform, "system", return_value="Darwin"), \
                    patch.object(harness, "command", side_effect=AssertionError("Docker must not run")):
                with self.assertRaises(ValueError):
                    harness.qualify(type("Arguments", (), {"revision": "a" * 40, "output": str(output)})())
            self.assertFalse(output.exists())

    def test_nonzero_command_retains_its_bounded_first_failure_output(self):
        with self.assertRaises(harness.CommandFailure) as failure:
            harness.command([sys.executable, "-c", "import sys;print('first stdout');print('first stderr',file=sys.stderr);sys.exit(4)"])
        self.assertEqual(failure.exception.stdout, b"first stdout\n")
        self.assertEqual(failure.exception.stderr, b"first stderr\n")

    def test_uncertain_creation_requires_successful_absence_check_before_cleanup_passes(self):
        record = {"id": None, "name": "asm-postgres18-test", "image": "sha256:" + "2" * 64,
                  "user": "26:26", "network": "none"}
        for listing_status in (0, 1):
            operations = []
            def docker(arguments, **options):
                operations.append(arguments[2])
                return SimpleNamespace(returncode=1 if arguments[2] == "inspect" else listing_status,
                                       stdout=b"", stderr=b"controlled daemon failure")
            with self.subTest(listing_status=listing_status), patch.object(harness.subprocess, "run", side_effect=docker):
                if listing_status:
                    with self.assertRaises(harness.CommandFailure):
                        harness.remove_container(record, "3" * 64)
                else:
                    harness.remove_container(record, "3" * 64)
            self.assertEqual(operations, ["inspect", "ls"])

    def test_start_failure_retains_failure_evidence_and_removes_only_the_created_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            previous = Path.cwd()
            os.chdir(temporary)
            self.addCleanup(os.chdir, previous)
            declaration = harness.fixture.prepare(harness.fixture.PREPARATION, "a" * 40)
            sidecar = {"Id": "sha256:" + "4" * 64, "Architecture": "amd64", "Os": "linux",
                       "Config": {"User": "26:26"}, "RootFS": {"Layers": ["base", "fixture"]}}
            base = {"Id": harness.fixture.CONFIG, "Architecture": "amd64", "Os": "linux", "Config": {"User": "26"},
                    "RootFS": {"Layers": ["base"]}, "RepoDigests": [harness.fixture.DATABASE_IMAGE]}
            runtime = {"Id": "sha256:" + "5" * 64, "Architecture": "amd64", "Os": "linux", "RootFS": {"Layers": ["application"]},
                       "Config": {"User": "65532:65532", "Entrypoint": harness.operator.ENTRYPOINT, "Cmd": ["--help"],
                                  "Labels": {"org.opencontainers.image.revision": "a" * 40}}}
            original, qualifier = copy.deepcopy(runtime), copy.deepcopy(runtime)
            original["RootFS"]["Layers"].append("original-tests")
            qualifier["RootFS"]["Layers"] += ["original-tests", "pg18-tests"]
            images = {harness.fixture.DATABASE_IMAGE: base, harness.DATABASE: sidecar,
                      harness.IMAGES["operator"][0]: runtime, harness.IMAGES["operator"][1]: original,
                      harness.IMAGES["operator"][2]: qualifier}
            containers, removed = {}, []
            def docker(arguments, **options):
                self.assertEqual(arguments[0], "docker")
                operation = arguments[1]
                if operation == "info":
                    body = b"linux/amd64\n"
                elif operation == "image":
                    body = json.dumps([images[arguments[-1]]]).encode()
                elif operation == "run":
                    self.fail("An anonymous probe bypassed owned container cleanup.")
                elif operation == "create":
                    name = arguments[arguments.index("--name") + 1]
                    value = self.container()
                    value["Name"] = "/" + name
                    value["Image"] = sidecar["Id"]
                    value["Config"]["Labels"]["asm.qualification.nonce"] = declaration["nonce"]
                    identity = f"{len(containers) + 1:064x}"
                    value["Id"] = identity
                    value["probe_path"] = arguments[-1] if "--entrypoint" in arguments else None
                    containers[identity] = value
                    body = identity.encode()
                elif operation == "container":
                    body = json.dumps([containers[arguments[-1]]]).encode()
                elif operation == "start":
                    value = containers[arguments[-1]]
                    if value["probe_path"]:
                        body = (Path(".postgres18-fixture/server") / Path(value["probe_path"]).name).read_bytes()
                    else:
                        raise ValueError("Controlled database start failure.")
                elif operation == "logs":
                    return SimpleNamespace(returncode=0, stdout=b"", stderr=b"retained database failure\n")
                elif operation == "rm":
                    removed.append(arguments[-1])
                    body = b""
                else:
                    self.fail("Unexpected Docker boundary: " + operation)
                return SimpleNamespace(returncode=0, stdout=body, stderr=b"")
            with patch.object(harness.platform, "system", return_value="Linux"), \
                    patch.object(harness.platform, "machine", return_value="x86_64"), \
                    patch.object(harness, "command", side_effect=docker), \
                    patch.object(harness, "database_files", return_value={"postgres": "a" * 64}), \
                    patch.object(harness.operator, "runtime_files", return_value={"psql": "b" * 64}):
                with self.assertRaises(ValueError):
                    harness.qualify(SimpleNamespace(revision="a" * 40, output="evidence"))
            report = json.loads(Path("evidence/qualification.json").read_text())
            self.assertEqual(report["status"], "fail")
            self.assertEqual(report["failure"]["message"], "Controlled database start failure.")
            self.assertEqual(removed, [f"{number:064x}" for number in range(4, 0, -1)])
            self.assertTrue(all(value["status"] == "removed" for value in report["cleanup"]))
            self.assertFalse(Path(".postgres18-fixture").exists())
            self.assertEqual(next(Path("evidence").glob("*.database.log")).read_bytes(), b"retained database failure\n")


if __name__ == "__main__":
    unittest.main()
