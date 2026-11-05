"""Reject mismatched native evidence before release fan-in exposes any bytes."""

import copy
import hashlib
import json
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import release


def minimal_macho():
    data = bytearray(160)
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x100000C, 0, 2, 3, 120, 0x200000, 0)
    struct.pack_into("<II16sQQQQIIII", data, 32, 0x19, 72, b"__TEXT", 0, 160, 0, 160, 5, 5, 0, 0)
    struct.pack_into("<IIQQ", data, 104, 0x80000028, 24, 152, 0)
    struct.pack_into("<6I", data, 128, 0x32, 24, 1, 0xF0000, 0xF0000, 0)
    return bytes(data)


def native_evidence(commit, version, binary, *, selected_target=False):
    """Synthetic evidence for consumer validation tests, never publication."""
    targets = (["x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos"]
               if selected_target else ["aarch64-macos"])
    return {
        "schema": 2 if selected_target else 1, "source_commit": commit, "version": version, "target": "aarch64-macos",
        "asset": {"file": f"asm-{version}-aarch64-macos", "bytes": len(binary), "sha256": hashlib.sha256(binary).hexdigest()},
        "platform": {"system": "Darwin", "machine": "arm64", "version": "15.7.1", "minimum": "15.0"},
        "command": ["make", "build/asm"], "reproducibility": "Two clean builds produced identical bytes.",
        "version_check": {"status": "pass", "runner": "native", "stdout": f"asm {version} (aarch64-macos)\n", "exit_code": 0},
        "targets_check": {"status": "pass", "runner": "native", "result": {"host": "aarch64-macos", "targets": targets}, "exit_code": 0},
        "tests": release.native_test_result(b"test_fixture ... ok\n\nRan 4 tests in 0.123s\n\nOK\n"),
        "code_signature": "ad-hoc; verified with codesign --verify --strict",
        "developer_id": "not-run", "notarization": "not-run",
        "tool_versions": {"clang": "Apple clang fixture", "sdk": "15.0", "python": "3.13.0"},
    }


class NativeFanInTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.commit, self.version = "a" * 40, "0.4.0"
        self.binary = minimal_macho()
        self.name = f"asm-{self.version}-aarch64-macos"
        (self.directory / self.name).write_bytes(self.binary)
        self.evidence = native_evidence(self.commit, self.version, self.binary)
        self.write_evidence(self.evidence)

    def write_evidence(self, data):
        (self.directory / release.NATIVE_EVIDENCE).write_text(json.dumps(data))

    def read(self):
        return release.read_native_release(self.directory, self.commit, self.version)

    def test_exact_commit_digest_and_native_runtime_are_accepted(self):
        binary, evidence = self.read()
        self.assertEqual(binary, self.binary)
        self.assertEqual(evidence, self.evidence)

    def test_selected_target_evidence_has_a_distinct_exact_schema(self):
        selected = copy.deepcopy(self.evidence)
        selected["schema"] = 2
        selected["targets_check"]["result"]["targets"] = [
            "x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos"]
        self.write_evidence(selected)
        self.assertEqual(self.read()[1], selected)
        self.assertEqual(release.read_native_release(
            self.directory, self.commit, self.version,
            expected_build_targets=selected["targets_check"]["result"]["targets"])[1], selected)
        with self.assertRaises(registry.RegistryError):
            release.read_native_release(self.directory, self.commit, self.version,
                                        expected_build_targets=["aarch64-macos"])
        for schema, targets in ((1, selected["targets_check"]["result"]["targets"]),
                                (2, ["aarch64-macos"]), (3, ["aarch64-macos"])):
            with self.subTest(schema=schema, targets=targets):
                invalid = copy.deepcopy(selected)
                invalid["schema"] = schema
                invalid["targets_check"]["result"]["targets"] = targets
                self.write_evidence(invalid)
                with self.assertRaises(registry.RegistryError):
                    self.read()

    def test_other_commit_version_target_and_asset_are_rejected(self):
        changes = [("source_commit", "b" * 40), ("version", "0.4.1"), ("target", "x86_64-macos"), ("schema", True),
                   ("asset", {**self.evidence["asset"], "file": "../../outside"}),
                   ("asset", {**self.evidence["asset"], "sha256": "0" * 64}),
                   ("asset", {**self.evidence["asset"], "bytes": 1})]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                self.write_evidence({**self.evidence, key: value})
                with self.assertRaises(registry.RegistryError):
                    self.read()

    def test_failed_skipped_emulated_and_wrong_os_evidence_are_rejected(self):
        mutations = [("version_check", "status", "fail"), ("version_check", "runner", "qemu-aarch64"),
                     ("version_check", "exit_code", False), ("targets_check", "exit_code", 0.0),
                     ("targets_check", "status", "not-run"), ("tests", "status", "error"),
                     ("tests", "tests_run", 0), ("tests", "tests_run", True), ("tests", "skipped", 1),
                     ("tests", "exit_code", False),
                     ("tests", "suite", "tests"), ("tests", "output_sha256", "no digest"),
                     ("platform", "system", "Linux"), ("platform", "machine", "x86_64"),
                     ("platform", "version", "14.7.0"), ("platform", "minimum", "14.0")]
        for section, key, value in mutations:
            with self.subTest(section=section, key=key, value=value):
                evidence = copy.deepcopy(self.evidence)
                evidence[section][key] = value
                self.write_evidence(evidence)
                with self.assertRaises(registry.RegistryError):
                    self.read()

    def test_corrupt_wrong_os_and_wrong_cpu_bytes_are_rejected(self):
        for binary in (b"\x7fELF" + self.binary[4:], self.binary[:-1], self.binary[:4] + b"\x07\x00\x00\x01" + self.binary[8:]):
            with self.subTest(binary=binary[:8]):
                evidence = copy.deepcopy(self.evidence)
                evidence["asset"].update(bytes=len(binary), sha256=hashlib.sha256(binary).hexdigest())
                self.write_evidence(evidence)
                (self.directory / self.name).write_bytes(binary)
                with self.assertRaises(registry.RegistryError):
                    self.read()

    def test_missing_oversized_duplicate_and_symlink_inputs_are_rejected(self):
        path = self.directory / release.NATIVE_EVIDENCE
        for data in (b"", b" " * (release.MAX_NATIVE_EVIDENCE + 1), b'{"schema":1,"schema":1}'):
            with self.subTest(size=len(data)):
                path.write_bytes(data)
                with self.assertRaises(registry.RegistryError):
                    self.read()
        self.write_evidence(self.evidence)
        asset = self.directory / self.name
        asset.unlink()
        asset.symlink_to(release.NATIVE_EVIDENCE)
        with self.assertRaises(registry.RegistryError):
            self.read()
        path.unlink()
        path.symlink_to("missing")
        with self.assertRaises(registry.RegistryError):
            self.read()

    def test_empty_failed_or_skipped_native_suite_cannot_qualify(self):
        for output in (b"Ran 0 tests in 0.000s\n\nOK\n", b"Ran 4 tests in 0.100s\n\nFAILED (failures=1)\n",
                       b"Ran 4 tests in 0.100s\n\nOK (skipped=1)\n", b"OK\n"):
            with self.subTest(output=output), self.assertRaises(registry.RegistryError):
                release.native_test_result(output)

    def test_declared_mac_host_requires_native_input_before_build_or_output(self):
        commands = {"version": self.version, "hosts": ["x86_64-linux", "aarch64-macos"]}
        output = self.directory / "release-output"
        with mock.patch.object(release, "resolve_commit", return_value=self.commit), \
             mock.patch.object(registry, "git_files", return_value={"cli/commands.json": (json.dumps(commands).encode(), 0o644)}), \
             mock.patch.object(release, "core_license", return_value="AGPL-3.0-or-later"), \
             mock.patch.object(release.platform, "system", return_value="Linux"), \
             mock.patch.object(release.platform, "machine", return_value="x86_64"), \
             mock.patch.object(release, "command") as command:
            with self.assertRaisesRegex(registry.RegistryError, "exact-commit native qualification input"):
                release.build_release(self.directory, output)
        command.assert_not_called()
        self.assertFalse(output.exists())


@unittest.skipUnless(platform.system() in {"Darwin", "Linux"}, "requires a supported atomic directory publication primitive")
class NativePublicationTests(unittest.TestCase):
    def test_existing_destination_is_preserved_at_the_commit_point(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, destination = root / "stage", root / "destination"
            stage.mkdir()
            (stage / "asset").write_bytes(b"new bytes")
            output = release.output_path(destination)
            destination.mkdir()
            (destination / "keep").write_bytes(b"original")
            with self.assertRaises(FileExistsError):
                release.publish_directory(stage, output)
            self.assertEqual((destination / "keep").read_bytes(), b"original")
            self.assertEqual((stage / "asset").read_bytes(), b"new bytes")

    def test_complete_stage_appears_under_new_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, output = root / "stage", root / "output"
            stage.mkdir()
            (stage / "asset").write_bytes(b"qualified")
            release.publish_directory(stage, output)
            self.assertFalse(stage.exists())
            self.assertEqual((output / "asset").read_bytes(), b"qualified")


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "exact native build checks require Apple Silicon macOS")
class NativeBuilderTests(unittest.TestCase):
    def test_final_bytes_come_from_exact_commit_and_pass_native_tests(self):
        # This isolated Git fixture includes the actual assembly and native
        # tests. It creates no commit in the working repository.
        (ROOT / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="native-release-fixture-", dir=ROOT / "build") as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            for name in release.SOURCE_INCLUDES:
                source = ROOT / name
                if source.is_dir():
                    shutil.copytree(source, repo / name,
                                    ignore=shutil.ignore_patterns("build", "__pycache__", ".asm", ".DS_Store"))
                elif source.is_file():
                    (repo / name).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, repo / name)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE).decode().strip()
            git("init", "-q")
            git("-c", "user.name=Native release fixture", "-c", "user.email=fixture@example.invalid",
                "add", ".")
            git("-c", "user.name=Native release fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-qm", "Create isolated native release fixture")
            commit = git("rev-parse", "HEAD")
            # Workspace changes must not enter either clean release build.
            (repo / "cli/macos/platform.s").write_text("uncommitted invalid assembly\n")
            output = root / "qualified"
            result = release.build_native_release(repo, output, commit)
            self.assertEqual(result["source_commit"], commit)
            self.assertGreater(result["tests"]["tests_run"], 0)
            self.assertEqual(result["tests"]["skipped"], 0)
            binary, evidence = release.read_native_release(output, commit, result["version"])
            self.assertEqual(evidence, result)
            self.assertEqual(hashlib.sha256(binary).hexdigest(), result["asset"]["sha256"])
            installed = output / result["asset"]["file"]
            actual = subprocess.check_output([str(installed), "version"], timeout=15)
            self.assertEqual(actual.decode(), result["version_check"]["stdout"])
