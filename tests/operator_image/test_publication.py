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
CHECK = ROOT / "tools/operator_publication.py"
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
        "not_applicable": [{"id": MAC_CASE, "reason": "macOS extended ACL interface"}], "seconds": 0.125,
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
    def gate(self, report, image, *, extra_document=False, raw_report=None, raw_image=None):
        with tempfile.TemporaryDirectory(prefix="asm-publication-gate-") as name:
            base = Path(name)
            image_body = raw_image if raw_image is not None else json.dumps(image).encode()
            (base / "image.json").write_bytes(image_body)
            body = raw_report if raw_report is not None else (json.dumps(report) + ("\n" + json.dumps(report) if extra_document else "")).encode()
            (base / "qualification.json").write_bytes(body)
            result = subprocess.run([sys.executable, "-I", str(CHECK), "--revision", REVISION,
                "--qualification", str(base / "qualification.json"), "--image", str(base / "image.json")],
                capture_output=True, timeout=10)
            self.assertEqual((base / "qualification.json").read_bytes(), body)
            self.assertEqual((base / "image.json").read_bytes(), image_body)
            return result

    def test_loaded_metadata_is_checked_even_when_fabricated_evidence_has_its_image_id(self):
        report, approved = evidence()
        actual = copy.deepcopy(approved)
        actual["Config"].update(User="0:0", Entrypoint=["/bin/sh"])
        self.assertEqual(self.gate(report, approved).returncode, 0)
        self.assertEqual(actual["Id"], report["runtime_image_id"])
        self.assertNotEqual(self.gate(report, actual).returncode, 0)
        publisher = WORKFLOW.read_text().split("  publish:", 1)[1]
        loaded = publisher.index("docker load --input runtime.tar")
        self.assertIn("--image loaded-image.json", publisher[loaded:])
        inspected = publisher.index(
            "docker image inspect asm-operator:runtime-amd64 --format '{{json .}}' > loaded-image.json", loaded)
        checked = publisher.index("--image loaded-image.json", inspected)
        self.assertLess(checked, publisher.index("docker tag "))
        self.assertLess(checked, publisher.index("docker login "))
        self.assertNotIn("docker run ", publisher)

    def test_conflicting_duplicate_fields_in_both_raw_inputs_are_refused(self):
        report, image = evidence()
        body = json.dumps(report).encode()
        for original, replacement in ((b'"status": "pass"', b'"status": "fail", "status": "pass"'),
                (b'"schema": 1', b'"schema": 999, "schema": 1'),
                (b'"read_only_root": true', b'"read_only_root": false, "read_only_root": true')):
            with self.subTest(field=original):
                self.assertNotEqual(self.gate(report, image, raw_report=body.replace(original, replacement, 1)).returncode, 0)
        image_body = json.dumps(image).encode().replace(b'"User": "65532:65532"', b'"User": "0:0", "User": "65532:65532"')
        self.assertNotEqual(self.gate(report, image, raw_image=image_body).returncode, 0)

    def test_nonfinite_lossy_and_noninteger_representations_are_refused(self):
        report, image = evidence()
        body = json.dumps(report).encode()
        for token in (b'NaN', b'Infinity', b'-Infinity', b'1e999'):
            with self.subTest(token=token):
                raw = body.replace(b'"seconds": 0.125', b'"seconds": ' + token)
                self.assertNotEqual(self.gate(report, image, raw_report=raw).returncode, 0)
                raw_image = json.dumps(image).encode()[:-1] + b', "Size": ' + token + b'}'
                self.assertNotEqual(self.gate(report, image, raw_image=raw_image).returncode, 0)
        for original, replacement in ((b'"tests_run": 100', b'"tests_run": 100.0'),
                (b'"uid": 65532', b'"uid": 65532e0'),
                (b'"schema": 1', b'"schema": 1.0')):
            with self.subTest(field=original):
                self.assertNotEqual(self.gate(report, image, raw_report=body.replace(original, replacement, 1)).returncode, 0)
        raw_image = json.dumps(image).encode()[:-1] + b', "Size": 9007199254740993}'
        self.assertNotEqual(self.gate(report, image, raw_image=raw_image).returncode, 0)

    def test_bounded_single_utf8_documents_preserve_the_raw_evidence(self):
        report, image = evidence()
        body = json.dumps(report).encode()
        invalid = (body[:-1] + b', "unused": "' + b'x' * 1048576 + b'"}',
                   body.decode().encode("utf-16"), b'\xef\xbb\xbf' + body,
                   body[:-1] + b', "unused": "\\ud800"}',
                   body[:-1] + b', "unused": ' + b'[' * 65 + b'0' + b']' * 65 + b'}')
        for raw in invalid:
            with self.subTest(size=len(raw), prefix=raw[:3]):
                self.assertNotEqual(self.gate(report, image, raw_report=raw).returncode, 0)
        for raw in (json.dumps(image).encode() + b'\n{}', json.dumps(image).encode("utf-16")):
            self.assertNotEqual(self.gate(report, image, raw_image=raw).returncode, 0)

    def test_valid_evidence_and_workflow_use_one_gate_before_loading(self):
        report, image = evidence()
        result = self.gate(report, image)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        text = WORKFLOW.read_text()
        self.assertEqual(text.count("python3 -I tools/operator_publication.py --revision"), 3)
        self.assertLess(text.index("--image image.json"), text.index("docker load --input runtime.tar"))
        self.assertEqual(result.stdout, b"")

    def test_distribution_modules_must_match_the_immutable_source_and_runtime(self):
        for name in ("tools/registry_mirror.py", "tools/registry_storage.py"):
            for location in (("source", "files", name), ("runtime_files", "/app/" + name)):
                with self.subTest(location=location):
                    report, image = evidence()
                    put(report, location, "0" * 64)
                    self.assertNotEqual(self.gate(report, image).returncode, 0)

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
