"""Exercise the exact trusted publication gate with synthetic evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import operator_source

REVISION = "1" * 40
POLICY = ROOT / "containers/operator-publication.jq"
WORKFLOW = ROOT / ".github/workflows/operator-images.yml"
MAC_CASE = "test_database.CatalogDatabaseTests.test_extended_acl_on_private_key_cannot_reach_mutation"


def evidence():
    files = {name: "a" * 64 for name in operator_source.FILES}
    runtime = {"/app/" + name: digest for name, digest in files.items()}
    runtime.update({path: "b" * 64 for path in ("/app/SOURCE.json", "/opt/asm/postgres/bin/psql", "/usr/bin/python3", "/usr/bin/git")})
    routes = ("/registry/v1/index.tsv", "/registry/v1/index-macos.tsv", "/registry/v1/index-all.tsv", "/registry/v1/index.json")
    report = {"schema": 1, "status": "pass", "scope": "explicit-registry-operator", "os": "linux",
        "architecture": "amd64", "execution": "native", "source_revision": REVISION,
        "runtime_image_id": "sha256:" + "2" * 64, "qualification_image_id": "sha256:" + "3" * 64,
        "tests_run": 100, "applicable_tests_run": 99, "applicable_tests_skipped": 0,
        "not_applicable": [{"id": MAC_CASE, "reason": "macOS extended ACL interface"}],
        "database_fixture_version": "16.15", "loaded_libraries": {"libpq": "16.15", "OpenSSL": "Synthetic OpenSSL fixture"},
        "security": {"uid": 65532, "gid": 65532, "projected_reader_gid": 65532, "read_only_root": True,
                     "effective_capabilities": 0, "no_new_privileges": True, "cluster_token": False},
        "source": {"schema": 1, "repository": "https://github.com/stubbi/asm", "source_revision": REVISION,
                   "bundle_sha256": "c" * 64, "bundle_bytes": 1024, "files": files},
        "runtime_files": runtime, "final_compiler_and_postgresql_server_absent": True,
        "postgresql_source": {"version": "16.15", "url": "https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2",
            "sha256": "c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed"},
        "plan": {"schema": 1, "acceptance_repository": "https://github.com/stubbi/asm", "acceptance_commit": REVISION,
                 "expected_revision": 0, "record_count": 1, "records_sha256": "d" * 64, "validator_sha256": "a" * 64,
                 "plan_sha256": "e" * 64, "artifact_bytes_checked": False,
                 "exports": {route: {"bytes": 100, "sha256": "f" * 64} for route in routes}},
        "resolved_packages": [{"package": name, "version": "1", "source_package": name, "source_version": "1",
                               "source_index": "https://snapshot.debian.org/package/" + name + "/1/"}
                              for name in ("git", "python3", "libssl3t64", "libc6")]}
    image = {"Id": report["runtime_image_id"], "Architecture": "amd64", "Os": "linux",
             "RootFS": {"Layers": ["sha256:" + "4" * 64]}, "Config": {"User": "65532:65532", "Cmd": ["--help"],
             "Entrypoint": ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"],
             "Labels": {"org.opencontainers.image.revision": REVISION, "org.opencontainers.image.source": "https://github.com/stubbi/asm",
                        "org.opencontainers.image.licenses": "AGPL-3.0-or-later"}}}
    return report, image


def put(value, path, replacement):
    for key in path[:-1]:
        value = value[key]
    if replacement is MISSING:
        del value[path[-1]]
    else:
        value[path[-1]] = replacement


MISSING = object()


class PublicationGateTests(unittest.TestCase):
    def gate(self, report, image, *, extra_document=False):
        with tempfile.TemporaryDirectory(prefix="asm-publication-gate-") as name:
            base = Path(name)
            (base / "image.json").write_text(json.dumps(image))
            body = json.dumps(report) + ("\n" + json.dumps(report) if extra_document else "")
            (base / "qualification.json").write_text(body)
            return subprocess.run(["jq", "--slurp", "--exit-status", "--arg", "revision", REVISION,
                "--slurpfile", "image", str(base / "image.json"), "--from-file", str(POLICY),
                str(base / "qualification.json")], capture_output=True, timeout=5)

    def test_valid_evidence_and_workflow_use_one_gate_before_loading(self):
        report, image = evidence()
        result = self.gate(report, image)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        text = WORKFLOW.read_text()
        self.assertIn("--slurpfile image image.json", text)
        self.assertLess(text.index("--from-file containers/operator-publication.jq"), text.index("docker load --input runtime.tar"))

    def test_malformed_schema_counts_exclusions_and_isolation_are_refused(self):
        report, image = evidence()
        cases = [(("schema",), 999), (("os",), "windows"), (("architecture",), "arm64"), (("execution",), "emulated"),
            (("tests_run",), "zero"), (("tests_run",), 100.5), (("tests_run",), True), (("tests_run",), -1),
            (("applicable_tests_run",), "zero"), (("applicable_tests_run",), 98), (("applicable_tests_skipped",), "0"),
            (("applicable_tests_skipped",), 1), (("not_applicable",), []),
            (("not_applicable",), [{"id": "test_prepare.required_projection", "reason": "missing fixture"}]),
            (("security", "read_only_root"), "false"), (("security", "read_only_root"), False),
            (("security", "gid"), MISSING), (("security", "uid"), "65532"),
            (("security", "effective_capabilities"), MISSING), (("security", "effective_capabilities"), 1),
            (("security", "no_new_privileges"), MISSING), (("security", "no_new_privileges"), "true"),
            (("security", "cluster_token"), True), (("final_compiler_and_postgresql_server_absent",), "true")]
        for path, replacement in cases:
            changed = copy.deepcopy(report)
            put(changed, path, replacement)
            with self.subTest(path=path, replacement=repr(replacement)):
                self.assertNotEqual(self.gate(changed, image).returncode, 0)

    def test_source_plan_image_and_platform_bindings_are_refused_when_mismatched(self):
        report, image = evidence()
        cases = [(("source_revision",), "5" * 40), (("runtime_image_id",), "sha256:" + "5" * 64),
            (("source", "source_revision"), "5" * 40), (("source", "repository"), "https://example.invalid/other"),
            (("source", "files", "tools/registry.py"), "0" * 64), (("source", "bundle_sha256"), "invalid"),
            (("source", "bundle_bytes"), 67108865), (("plan", "acceptance_commit"), "5" * 40),
            (("plan", "validator_sha256"), "0" * 64), (("plan", "exports", "/registry/v1/index.tsv", "bytes"), "100"),
            (("plan", "exports", "/registry/v1/index.json", "bytes"), 4194305), (("resolved_packages",), []),
            (("loaded_libraries", "libpq"), "18.6")]
        for path, replacement in cases:
            changed = copy.deepcopy(report)
            put(changed, path, replacement)
            with self.subTest(path=path):
                self.assertNotEqual(self.gate(changed, image).returncode, 0)
        for path, replacement in [(("Architecture",), "arm64"), (("Os",), "windows"),
                (("Config", "User"), "0:0"), (("Config", "Labels", "org.opencontainers.image.revision"), "5" * 40)]:
            changed = copy.deepcopy(image)
            put(changed, path, replacement)
            with self.subTest(image_path=path):
                self.assertNotEqual(self.gate(report, changed).returncode, 0)
        self.assertNotEqual(self.gate(report, image, extra_document=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
