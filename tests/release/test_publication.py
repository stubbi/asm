"""Validate release handoff bytes without executing downloaded artifacts."""

import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import registry
import release
import test_release as fixtures


def test_receipt():
    return {"status": "pass", "command": ["make", "test"], "suite": "tests",
            "tests_run": 4, "skipped": 0, "exit_code": 0, "output_sha256": "d" * 64}


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.name = "asm-0.6.0-x86_64-linux"
        self.payload = b"Synthetic handoff bytes; never execute.\n"
        asset = {"file": self.name, "bytes": len(self.payload),
                 "sha256": hashlib.sha256(self.payload).hexdigest()}
        self.manifest = {"schema": 1, "project": "asm", "repository": "https://github.com/stubbi/asm",
                         "version": "0.6.0", "tag": "v0.6.0", "source_commit": "a" * 40,
                         "cli_hosts": ["x86_64-linux"], "assets": [asset],
                         "builds": {"asm": {"asset": asset, "tests": test_receipt()}}}
        (self.directory / self.name).write_bytes(self.payload)
        self.write()

    def write(self):
        data = registry.json_bytes(self.manifest)
        (self.directory / "release.json").write_bytes(data)
        self.digest = hashlib.sha256(data).hexdigest()
        checksums = {asset["file"]: asset["sha256"] for asset in self.manifest["assets"]}
        checksums["release.json"] = self.digest
        (self.directory / "SHA256SUMS").write_text("".join(
            f"{digest}  {name}\n" for name, digest in sorted(checksums.items())))

    def validate(self, **kwargs):
        return release.validate_release(self.directory, "a" * 40, "0.6.0", self.digest, **kwargs)

    def test_exact_handoff_is_accepted_without_running_artifacts(self):
        with patch.object(release, "command", side_effect=AssertionError("Never execute artifact bytes")):
            self.assertEqual(self.validate(), self.manifest)

    def test_cli_uses_the_accepted_source_version_and_hosts_without_building(self):
        repository = self.directory / "source"
        (repository / "cli").mkdir(parents=True)
        (repository / "cli/commands.json").write_text(json.dumps({"version": "0.6.0", "hosts": ["x86_64-linux"]}))
        for arguments in (("init", "-q"), ("add", "."), ("commit", "-qm", "Record publication source fixture")):
            subprocess.run(["git", "-C", str(repository), "-c", "user.name=Publication fixture",
                            "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                            "-c", "commit.gpgSign=false", *arguments], check=True, capture_output=True, timeout=10)
        commit = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], timeout=10).decode().strip()
        self.manifest["source_commit"] = commit
        self.write()
        # The accepted source fixture has no assembler, build recipe, or program.
        result = subprocess.run([sys.executable, str(Path(release.__file__)), "--repo", str(repository),
                                 "--commit", commit, "--validate-release", str(self.directory),
                                 "--manifest-sha256", self.digest], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
        self.assertIn("unexpected files", result.stderr)
        # Move source outside the handoff directory to exercise a successful CLI validation.
        with tempfile.TemporaryDirectory() as source_root:
            source = Path(source_root) / "source"
            repository.rename(source)
            result = subprocess.run([sys.executable, str(Path(release.__file__)), "--repo", str(source),
                                     "--commit", commit, "--validate-release", str(self.directory),
                                     "--manifest-sha256", self.digest], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertIn("No artifact was executed", result.stdout)

    def test_changed_manifest_payload_checksums_or_extra_file_are_refused(self):
        mutations = {"manifest": ("release.json", b"{}\n"),
                     "payload": (self.name, self.payload + b"changed"),
                     "checksums": ("SHA256SUMS", b""), "extra": ("unexpected", b"extra")}
        for label, (name, data) in mutations.items():
            path = self.directory / name
            original = path.read_bytes() if path.exists() else None
            path.write_bytes(data)
            with self.subTest(mutation=label), self.assertRaises(registry.RegistryError):
                self.validate()
            if original is None:
                path.unlink()
            else:
                path.write_bytes(original)

    def test_source_version_tag_and_profile_are_bound_to_the_workflow(self):
        original = copy.deepcopy(self.manifest)
        for changes in ({"source_commit": "b" * 40}, {"version": "0.6.1"},
                        {"tag": "v0.6.1"}, {"repository": "https://github.com/other/asm"},
                        {"distribution": {"profile": "asm-tuf-v1"}}):
            self.manifest = {**copy.deepcopy(original), **changes}
            self.write()
            with self.subTest(changes=changes), self.assertRaises(registry.RegistryError):
                self.validate()
        self.manifest = original
        self.write()
        with self.assertRaises(registry.RegistryError):
            self.validate(trusted=True)

    def test_unqualified_skipped_failed_or_different_x86_bytes_are_refused(self):
        original = copy.deepcopy(self.manifest)
        for change in ({"tests": None}, {"tests": {**test_receipt(), "skipped": 1}},
                       {"tests": {**test_receipt(), "tests_run": 0}},
                       {"tests": {**test_receipt(), "exit_code": False}},
                       {"asset": {**original["assets"][0], "sha256": "b" * 64}}):
            self.manifest = copy.deepcopy(original)
            self.manifest["builds"]["asm"].update(change)
            self.write()
            with self.subTest(change=change), self.assertRaises(registry.RegistryError):
                self.validate()

    def test_missing_linked_duplicate_and_traversing_assets_are_refused(self):
        asset_path = self.directory / self.name
        asset_path.unlink()
        with self.assertRaises(registry.RegistryError):
            self.validate()
        outside = self.directory / "outside"
        outside.write_bytes(self.payload)
        asset_path.symlink_to(outside)
        with self.assertRaises(registry.RegistryError):
            self.validate()
        asset_path.unlink()
        outside.unlink()
        asset_path.write_bytes(self.payload)
        original = copy.deepcopy(self.manifest)
        self.manifest["assets"].append(copy.deepcopy(self.manifest["assets"][0]))
        self.write()
        with self.assertRaises(registry.RegistryError):
            self.validate()
        self.manifest = original
        self.manifest["assets"][0]["file"] = "../outside"
        self.write()
        with self.assertRaises(registry.RegistryError):
            self.validate()

    def test_trusted_profile_binds_verifiers_notices_installer_and_source_root(self):
        for name in ("asm-verify-0.6.0-x86_64-linux", "asm-verify-0.6.0-x86_64-linux.LICENSES.txt", "install.sh"):
            payload = b"Synthetic trusted-profile fixture; never execute.\n"
            (self.directory / name).write_bytes(payload)
            self.manifest["assets"].append({"file": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
        helper = self.manifest["assets"][1]
        self.manifest["distribution"] = {"profile": "asm-tuf-v1", "root_sha256": "e" * 64,
            "verifiers": [{"target": "x86_64-linux", "url": "https://github.com/stubbi/asm/releases/download/v0.6.0/" + helper["file"],
                           "bytes": helper["bytes"], "sha256": helper["sha256"]}]}
        self.write()
        self.assertEqual(self.validate(trusted=True, trust_root_sha256="e" * 64), self.manifest)
        for options in ({}, {"trusted": True, "trust_root_sha256": "f" * 64},
                        {"trusted": True, "cli_hosts": ["x86_64-linux", "aarch64-linux"]}):
            with self.subTest(options=options), self.assertRaises(registry.RegistryError):
                self.validate(**options)
        self.manifest["distribution"]["verifiers"][0]["sha256"] = "9" * 64
        self.write()
        with self.assertRaises(registry.RegistryError):
            self.validate(trusted=True)

    def v2_profile(self):
        profile = {"registry_v2": True, "trusted_distribution": False}
        notices = b"Synthetic dependency notices for the embedded adapter.\n"
        name = self.name + ".LICENSES.txt"
        (self.directory / name).write_bytes(notices)
        asset = {"file": name, "bytes": len(notices), "sha256": hashlib.sha256(notices).hexdigest()}
        self.manifest["client_profile"] = profile
        self.manifest["tool_versions"] = {"go": "go version go1.27.3 linux/amd64; synthetic fixture"}
        self.manifest["builds"]["asm"]["client_profile"] = profile.copy()
        self.manifest["builds"]["asm"]["adapter"] = {"bytes": 4096, "sha256": "b" * 64, "notices": asset}
        self.manifest["assets"].append(asset)
        self.write()

    def test_v2_handoff_binds_embedded_adapter_and_notices_without_trusted_bootstrap(self):
        self.v2_profile()
        with patch.object(release, "command", side_effect=AssertionError("Never execute artifact bytes")):
            self.assertEqual(self.validate(registry_v2=True), self.manifest)
        self.assertNotIn("distribution", self.manifest)
        self.assertFalse(any(asset["file"].startswith("asm-verify-") for asset in self.manifest["assets"]))

    def test_v2_handoff_refuses_missing_mixed_or_ambiguous_profile_receipts(self):
        self.v2_profile()
        original = copy.deepcopy(self.manifest)
        for location in (self.manifest, self.manifest["builds"]["asm"]):
            for profile in (None, {"registry_v2": False, "trusted_distribution": False},
                            {"registry_v2": 1, "trusted_distribution": False},
                            {"registry_v2": True, "trusted_distribution": True}):
                saved = location.pop("client_profile")
                if profile is not None:
                    location["client_profile"] = profile
                self.write()
                with self.subTest(profile=profile), self.assertRaises(registry.RegistryError):
                    self.validate(registry_v2=True)
                location["client_profile"] = saved
        self.manifest = original
        for mutation in ({"bytes": 0}, {"bytes": True}, {"sha256": "invalid"}, {"notices": None}):
            self.manifest = copy.deepcopy(original)
            self.manifest["builds"]["asm"]["adapter"].update(mutation)
            self.write()
            with self.subTest(mutation=mutation), self.assertRaises(registry.RegistryError):
                self.validate(registry_v2=True)

    def test_v2_handoff_refuses_notice_identity_changes_and_a_v1_workflow(self):
        self.v2_profile()
        with self.assertRaises(registry.RegistryError):
            self.validate()
        self.manifest["builds"]["asm"]["adapter"]["notices"]["sha256"] = "c" * 64
        self.write()
        with self.assertRaises(registry.RegistryError):
            self.validate(registry_v2=True)


class SourceProfileTests(unittest.TestCase):
    def test_source_archive_retains_hosting_recipes_and_locked_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            expected = {"requirements-storage.in": b"storage dependency input\n",
                        "requirements-storage.txt": b"locked storage dependency fixture\n",
                        "deploy/mirror/nginx.conf": b"synthetic origin recipe\n",
                        "blog/README.md": b"maintained article instructions\n",
                        "verifier/go.mod": b"module synthetic\n"}
            for name, data in expected.items():
                path = repository / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            for arguments in (("init", "-q"), ("add", "."), ("commit", "-qm", "Record hostable source fixture")):
                subprocess.run(["git", "-C", str(repository), "-c", "user.name=Source fixture",
                                "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                                "-c", "commit.gpgSign=false", *arguments], check=True, capture_output=True, timeout=10)
            commit = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], timeout=10).decode().strip()
            selected = registry.git_files(repository, commit, ".", release.SOURCE_INCLUDES)
            archive = registry.read_archive(registry.make_archive(selected))
            self.assertEqual(archive, expected)

    def test_source_contract_selects_v2_and_rejects_ambiguous_values(self):
        self.assertFalse(release.source_registry_v2({}))
        self.assertTrue(release.source_registry_v2({"registry_v2": True}))
        for value in (None, 1, "1", [], {}):
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                release.source_registry_v2({"registry_v2": value})

    def test_ambient_profile_cannot_override_the_recorded_source(self):
        with patch.dict(os.environ, {"REGISTRY_V2": "1", "TRUSTED_DISTRIBUTION": "1"}):
            minimal = release.build_environment()
            full = release.build_environment(registry_v2=True)
        self.assertEqual(minimal["REGISTRY_V2"], "0")
        self.assertEqual(full["REGISTRY_V2"], "1")
        self.assertNotIn("TRUSTED_DISTRIBUTION", full)

    def test_release_environment_keeps_baseline_cpu_features_and_unmodified_cryptography(self):
        ambient = {"GOAMD64": "v4", "GOARM64": "v9.5,lse,crypto",
                   "GOEXPERIMENT": "invalid-ambient-experiment", "GOFIPS140": "latest",
                   "PATH": "/preserved-sdk-path", "GOCACHE": "/preserved-cache"}
        with patch.dict(os.environ, ambient):
            for full in (False, True):
                environment = release.build_environment(registry_v2=full)
                with self.subTest(registry_v2=full):
                    self.assertEqual({name: environment.get(name) for name in ambient},
                                     {**ambient, "GOAMD64": "v1", "GOARM64": "v8.0",
                                      "GOEXPERIMENT": "", "GOFIPS140": "off"})


class ExactNativeTests(unittest.TestCase):
    def test_failures_skips_and_changed_final_bytes_cannot_qualify(self):
        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary)
            expected = b"original qualified bytes"
            env = {"TRUSTED_DISTRIBUTION": "1"}
            for output, changed in ((b"Ran 4 tests in 0.1s\n\nFAILED (failures=1)\n", False),
                                    (b"Ran 4 tests in 0.1s\n\nOK (skipped=1)\n", False),
                                    (b"Ran 4 tests in 0.1s\n\nOK\n", True)):
                with self.subTest(output=output, changed=changed), \
                     patch.object(release, "command", return_value=output) as command, \
                     patch.object(release, "read_binary", return_value=expected + b"changed" if changed else expected), \
                     self.assertRaises(registry.RegistryError):
                    release.qualify_native_tests(snapshot, env, "x86_64-linux", expected)
                self.assertEqual(command.call_args.args[:3], (["make", "test"], snapshot, env))

    def test_trusted_flag_and_unskipped_result_are_retained(self):
        with patch.object(release, "command", return_value=b"Ran 4 tests in 0.1s\n\nOK\n") as command, \
             patch.object(release, "read_binary", return_value=b"exact"):
            env = {"TRUSTED_DISTRIBUTION": "1"}
            result = release.qualify_native_tests(Path("fixture"), env, "x86_64-linux", b"exact")
        self.assertEqual(result["tests_run"], 4)
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(command.call_args.args[2], env)


class FinalBuildQualificationTests(unittest.TestCase):
    setUp = fixtures.ArmReleaseFanInTests.setUp

    def build(self, output, **kwargs):
        with patch.object(release.os, "getuid", return_value=0), \
             patch.object(release.os, "geteuid", return_value=0):
            return fixtures.ArmReleaseFanInTests.build(self, output, qualify_x86=True, **kwargs)

    def test_final_build_records_the_qualified_x86_bytes(self):
        with patch.object(release, "qualify_native_tests", return_value=test_receipt()) as qualify:
            result = self.build(self.directory / "qualified")
        self.assertEqual(qualify.call_args.args[2:], ("x86_64-linux", self.x86))
        self.assertEqual(result["builds"]["asm"]["tests"], test_receipt())
        self.assertEqual(result["builds"]["asm"]["asset"]["sha256"], hashlib.sha256(self.x86).hexdigest())

    def test_native_failure_prevents_any_release_output(self):
        output = self.directory / "failed"
        with patch.object(release, "qualify_native_tests", side_effect=registry.RegistryError("native tests failed")), \
             self.assertRaisesRegex(registry.RegistryError, "native tests failed"):
            self.build(output)
        self.assertFalse(output.exists())

    def test_trusted_profile_reaches_the_same_final_byte_test_gate(self):
        output = self.directory / "trusted"
        self.evidence["client_profile"] = {"registry_v2": False, "trusted_distribution": True}
        (self.native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(self.evidence))
        with patch.object(release, "qualify_native_tests", side_effect=registry.RegistryError("stop at native gate")) as qualify, \
             self.assertRaisesRegex(registry.RegistryError, "stop at native gate"):
            self.build(output, trusted=True)
        self.assertEqual(qualify.call_args.args[1]["TRUSTED_DISTRIBUTION"], "1")
        self.assertEqual(qualify.call_args.args[3], self.x86)
        self.assertFalse(output.exists())

    def test_partial_privilege_cannot_skip_the_full_cross_uid_suite(self):
        for uid, effective in ((1, 1), (0, 1), (1, 0)):
            with self.subTest(uid=uid, effective=effective), \
                 patch.object(release.os, "getuid", return_value=uid), \
                 patch.object(release.os, "geteuid", return_value=effective), \
                 self.assertRaisesRegex(registry.RegistryError, "requires root"):
                fixtures.ArmReleaseFanInTests.build(self, self.directory / "unprivileged", qualify_x86=True)


if __name__ == "__main__":
    unittest.main()
