"""Check exact-commit packaging, deterministic builds, and publication boundaries."""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import URLError


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry
import release
from test_macos_release import minimal_macho, native_evidence


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE).decode().strip()


def minimal_arm_elf():
    """Container-only fixture. These bytes never qualify a published host."""
    data = bytearray(120)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 2, 183, 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HHH", data, 52, 64, 56, 1)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, 120, 120, 4096)
    return bytes(data)


def arm_native_evidence(commit, version, binary, *, selected_target=False):
    """Synthetic consumer fixture; no native execution or qualification claim."""
    targets = (["x86_64-linux", "aarch64-linux", "riscv64-linux"]
               if selected_target else ["aarch64-linux"])
    return {
        "schema": 2 if selected_target else 1,
        "source_commit": commit, "version": version, "target": "aarch64-linux",
        "asset": {"file": f"asm-{version}-aarch64-linux", "bytes": len(binary),
                  "sha256": hashlib.sha256(binary).hexdigest()},
        "platform": {"system": "Linux", "machine": "aarch64", "kernel": "6.8.0-fixture",
                     "version": "Synthetic Linux fixture", "uid": 0, "effective_uid": 0},
        "command": ["make", "build/asm"], "reproducibility": "Two clean builds produced identical bytes.",
        "version_check": {"status": "pass", "runner": "native", "stdout": f"asm {version} (aarch64-linux)\n", "exit_code": 0},
        "targets_check": {"status": "pass", "runner": "native",
                          "result": {"host": "aarch64-linux", "targets": targets}, "exit_code": 0},
        "tests": {"status": "pass", "command": ["make", "test"], "suite": "tests", "tests_run": 4,
                  "skipped": 0, "exit_code": 0, "output_sha256": hashlib.sha256(b"synthetic test output").hexdigest()},
        "tool_versions": {"make": "GNU Make fixture", "as": "GNU assembler fixture",
                          "ld": "GNU ld fixture", "git": "git fixture", "python": "3.13.0"},
    }


class ArmNativeInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.commit, self.version = "a" * 40, "0.5.0"
        self.binary = minimal_arm_elf()
        self.evidence = arm_native_evidence(self.commit, self.version, self.binary)
        self.filename = self.evidence["asset"]["file"]
        (self.directory / self.filename).write_bytes(self.binary)
        self.write(self.evidence)

    def write(self, evidence):
        (self.directory / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))

    def read(self, **kwargs):
        return release.read_native_release(self.directory, self.commit, self.version, "aarch64-linux", **kwargs)

    def test_exact_arm_bytes_and_complete_native_evidence_are_accepted(self):
        try:
            binary, evidence = self.read()
        except registry.RegistryError as error:
            self.fail(f"exact ARM64 native input was refused: {error}")
        self.assertEqual(binary, self.binary)
        self.assertEqual(evidence, self.evidence)

    def test_selected_target_arm_receipt_accepts_exactly_the_three_linux_targets(self):
        selected = copy.deepcopy(self.evidence)
        selected["schema"] = 2
        selected["targets_check"]["result"]["targets"] = [
            "x86_64-linux", "aarch64-linux", "riscv64-linux"]
        self.write(selected)
        try:
            binary, evidence = self.read()
        except registry.RegistryError as error:
            self.fail(f"canonical selected-target Linux receipt was refused: {error}")
        self.assertEqual(binary, self.binary)
        self.assertEqual(evidence, selected)
        self.assertEqual(self.read(expected_build_targets=[
            "x86_64-linux", "aarch64-linux", "riscv64-linux"])[1], selected)

    def test_selected_target_arm_receipt_rejects_noncanonical_target_lists(self):
        for targets in (["x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-linux"],
                        ["aarch64-linux"], ["aarch64-linux", "x86_64-linux", "riscv64-linux"],
                        ["x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos"]):
            with self.subTest(targets=targets):
                evidence = copy.deepcopy(self.evidence)
                evidence["schema"] = 2
                evidence["targets_check"]["result"]["targets"] = targets
                self.write(evidence)
                with self.assertRaisesRegex(registry.RegistryError, "native target evidence did not pass"):
                    self.read()

    def test_legacy_arm_receipt_keeps_its_native_only_target_contract(self):
        self.assertEqual(self.read(expected_build_targets=["aarch64-linux"])[1], self.evidence)
        evidence = copy.deepcopy(self.evidence)
        evidence["targets_check"]["result"]["targets"] = [
            "x86_64-linux", "aarch64-linux", "riscv64-linux"]
        self.write(evidence)
        with self.assertRaisesRegex(registry.RegistryError, "native target evidence did not pass"):
            self.read()

    def test_arm_receipt_schema_cannot_replace_the_source_build_contract(self):
        for schema, targets, source_targets in (
                (1, ["aarch64-linux"], ["x86_64-linux", "aarch64-linux", "riscv64-linux"]),
                (2, ["x86_64-linux", "aarch64-linux", "riscv64-linux"], ["aarch64-linux"])):
            with self.subTest(schema=schema):
                evidence = copy.deepcopy(self.evidence)
                evidence["schema"] = schema
                evidence["targets_check"]["result"]["targets"] = targets
                self.write(evidence)
                with self.assertRaisesRegex(registry.RegistryError, "different source build contract"):
                    self.read(expected_build_targets=source_targets)

    def test_wrong_identity_incomplete_native_checks_and_missing_kernel_are_rejected(self):
        mutations = [(None, "source_commit", "b" * 40), (None, "version", "0.5.1"),
                     (None, "target", "aarch64-macos"), (None, "schema", True),
                     (None, "reproducibility", "not-run"),
                     ("asset", "file", "../../outside"), ("asset", "bytes", True),
                     ("asset", "sha256", "0" * 64),
                     ("version_check", "runner", "qemu-aarch64"), ("version_check", "status", "error"),
                     ("version_check", "exit_code", False), ("targets_check", "exit_code", 0.0),
                     ("targets_check", "status", "not-run"), ("tests", "status", "fail"),
                     ("tests", "tests_run", 0), ("tests", "tests_run", True), ("tests", "skipped", 1),
                     ("tests", "exit_code", False), ("tests", "suite", "tests/macos"),
                     ("tests", "output_sha256", "missing"), ("platform", "system", "Darwin"),
                     ("platform", "machine", "x86_64"), ("platform", "machine", []), ("platform", "kernel", ""),
                     ("platform", "version", ""), ("platform", "effective_uid", 1001),
                     ("platform", "uid", False), ("tool_versions", "as", ""),
                     ("tool_versions", "ld", ""), ("tool_versions", "python", "")]
        for section, key, value in mutations:
            with self.subTest(section=section, key=key, value=value):
                evidence = copy.deepcopy(self.evidence)
                (evidence if section is None else evidence[section])[key] = value
                self.write(evidence)
                with self.assertRaises(registry.RegistryError):
                    self.read()

    def test_corrupt_wrong_architecture_and_symlink_assets_are_rejected(self):
        for binary in (self.binary[:-1], minimal_macho(), self.binary[:18] + b"\x3e\0" + self.binary[20:]):
            with self.subTest(binary=binary[:20]):
                evidence = copy.deepcopy(self.evidence)
                evidence["asset"].update(bytes=len(binary), sha256=hashlib.sha256(binary).hexdigest())
                self.write(evidence)
                (self.directory / self.filename).write_bytes(binary)
                with self.assertRaises(registry.RegistryError):
                    self.read()
        self.write(self.evidence)
        asset = self.directory / self.filename
        asset.unlink()
        asset.symlink_to(release.NATIVE_EVIDENCE)
        with self.assertRaises(registry.RegistryError):
            self.read()

    def test_missing_duplicate_oversized_and_symlink_evidence_are_rejected(self):
        path = self.directory / release.NATIVE_EVIDENCE
        for data in (b"", b'{"schema":1,"schema":1}', b" " * (release.MAX_NATIVE_EVIDENCE + 1)):
            with self.subTest(size=len(data)):
                path.write_bytes(data)
                with self.assertRaises(registry.RegistryError):
                    self.read()
        path.unlink()
        path.symlink_to("missing")
        with self.assertRaises(registry.RegistryError):
            self.read()

    def test_declared_arm_host_requires_native_input_before_build_or_output(self):
        commands = {"version": self.version, "hosts": ["x86_64-linux", "aarch64-linux"]}
        output = self.directory / "release-output"
        with mock.patch.object(release, "resolve_commit", return_value=self.commit), \
             mock.patch.object(registry, "git_files", return_value={"cli/commands.json": (json.dumps(commands).encode(), 0o644)}), \
             mock.patch.object(release, "core_license", return_value="AGPL-3.0-or-later"), \
             mock.patch.object(release.platform, "system", return_value="Linux"), \
             mock.patch.object(release.platform, "machine", return_value="x86_64"), \
             mock.patch.object(release, "tool_version", return_value="fixture"), \
             mock.patch.object(release, "command", side_effect=AssertionError("build started before native qualification")):
            with self.assertRaisesRegex(registry.RegistryError, "exact-commit native qualification input"):
                release.build_release(self.directory, output)
        self.assertFalse(output.exists())

    def test_linux_qualification_requires_linux_arm64_and_root_for_all_tests(self):
        for system, machine, uid in (("Darwin", "arm64", 0), ("Linux", "x86_64", 0), ("Linux", "aarch64", 1001)):
            with self.subTest(system=system, machine=machine, uid=uid), \
                 mock.patch.object(release.platform, "system", return_value=system), \
                 mock.patch.object(release.platform, "machine", return_value=machine), \
                 mock.patch.object(release.os, "getuid", return_value=uid), \
                 mock.patch.object(release.os, "geteuid", return_value=uid):
                output = self.directory / "wrong-host-output"
                with self.assertRaisesRegex(registry.RegistryError, "native Linux ARM64 qualification requires"):
                    release.build_native_release(self.directory, output, target="aarch64-linux")
                self.assertFalse(output.exists())

    def test_cli_rejects_duplicate_native_inputs_before_build(self):
        arguments = ["--native-input-for", "aarch64-linux", str(self.directory)] * 2
        result = subprocess.run([sys.executable, str(ROOT / "tools/release.py"), *arguments],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate native input", result.stderr)


class ArmNativeProducerTests(unittest.TestCase):
    """Exercise producer orchestration with synthetic tools, not a native-runtime claim."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.binary = minimal_arm_elf()
        self.builds = 0

    def produce(self, *, mismatch=False, skipped=False, changed_by_tests=False):
        def fake_command(arguments, cwd, env, timeout=120, include_stderr=False):
            if arguments == ["make", "build/asm"]:
                self.builds += 1
                (cwd / "build").mkdir()
                data = self.binary + (b"different" if mismatch and self.builds == 2 else b"")
                (cwd / "build/asm").write_bytes(data)
                return b""
            if arguments == ["make", "test"]:
                if changed_by_tests:
                    (cwd / "build/asm").write_bytes(self.binary + b"changed")
                return b"test_fixture ... ok\n\nRan 4 tests in 0.123s\n\n" + (b"OK (skipped=1)\n" if skipped else b"OK\n")
            if arguments[-1] == "version":
                return b"asm 0.5.0 (aarch64-linux)\n"
            if arguments[-2:] == ["targets", "--json"]:
                return b'{"host":"aarch64-linux","targets":["aarch64-linux"]}'
            self.fail(f"unexpected producer command: {arguments}")
        with mock.patch.object(release.platform, "system", return_value="Linux"), \
             mock.patch.object(release.platform, "machine", return_value="aarch64"), \
             mock.patch.object(release.platform, "release", return_value="6.8.0-observed-fixture"), \
             mock.patch.object(release.platform, "version", return_value="Observed fixture kernel build"), \
             mock.patch.object(release.os, "getuid", return_value=0), \
             mock.patch.object(release.os, "geteuid", return_value=0), \
             mock.patch.object(release, "resolve_commit", return_value="a" * 40), \
             mock.patch.object(registry, "git_files", return_value={"cli/commands.json": (b'{"version":"0.5.0","build_mode":"native host"}', 0o644)}), \
             mock.patch.object(release, "command", side_effect=fake_command), \
             mock.patch.object(release, "tool_version", side_effect=lambda name, *unused: name + " fixture"):
            return release.build_native_release(self.directory, self.directory / "qualified", target="aarch64-linux")

    def test_linux_producer_records_actual_kernel_and_unskipped_suite_for_same_bytes(self):
        try:
            result = self.produce()
        except registry.RegistryError as error:
            self.fail(f"Linux native producer refused a qualified fixture: {error}")
        self.assertEqual(result["platform"], {"system": "Linux", "machine": "aarch64", "kernel": "6.8.0-observed-fixture",
                                             "version": "Observed fixture kernel build", "uid": 0, "effective_uid": 0})
        self.assertEqual(result["tests"]["suite"], "tests")
        self.assertEqual(result["tests"]["tests_run"], 4)
        self.assertEqual(result["tests"]["skipped"], 0)
        self.assertNotIn("minimum", result["platform"])
        self.assertNotIn("code_signature", result)
        self.assertEqual((self.directory / "qualified" / result["asset"]["file"]).read_bytes(), self.binary)
        binary, evidence = release.read_native_release(self.directory / "qualified", "a" * 40, "0.5.0", "aarch64-linux")
        self.assertEqual(binary, self.binary)
        self.assertEqual(evidence, result)

    def test_changed_builds_skipped_tests_or_test_mutation_never_publish_output(self):
        for options in ({"mismatch": True}, {"skipped": True}, {"changed_by_tests": True}):
            with self.subTest(options=options), self.assertRaises(registry.RegistryError):
                self.builds = 0
                self.produce(**options)
            self.assertFalse((self.directory / "qualified").exists())


class ArmReleaseFanInTests(unittest.TestCase):
    """Check final-byte consumption with synthetic build and native-job fixtures."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        files = {"LICENSE": "MIT License\nFixture only.\n", "README.md": "# Fixture\n",
                 "asm.toml": '[package]\nname="asm"\nversion="0.5.0"\n[build]\nsource="cli/asm.s"\ntarget="x86_64-linux"\n',
                 "cli/commands.json": '{"version":"0.5.0","license":"MIT","build_mode":"native host","hosts":["x86_64-linux","aarch64-linux"]}',
                 "cli/asm.s": "# Synthetic fixture; never assembled.\n",
                 "examples/hello/LICENSE": "MIT License\nFixture only.\n",
                 "examples/hello/README.md": "# Fixture\n",
                 "examples/hello/asm.toml": '[package]\nname="hello"\nversion="0.5.0"\n[build]\nsource="src/main.s"\ntarget="x86_64-linux"\n',
                 "examples/hello/src/main.s": "# Synthetic fixture; never assembled.\n"}
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        git(self.repo, "init", "-q")
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Release fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-qm", "Create synthetic producer fixture")
        self.commit = git(self.repo, "rev-parse", "HEAD")
        self.arm = minimal_arm_elf()
        self.x86 = self.arm[:18] + b"\x3e\0" + self.arm[20:]
        self.native = self.directory / "native"
        self.native.mkdir()
        self.evidence = arm_native_evidence(self.commit, "0.5.0", self.arm)
        (self.native / self.evidence["asset"]["file"]).write_bytes(self.arm)
        (self.native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(self.evidence))

    def build(self, output, **kwargs):
        def fixture_cli(snapshot, env, target="x86_64-linux"):
            self.assertEqual(target, "x86_64-linux", "ARM release bytes must come from native input")
            return self.x86
        with mock.patch.object(release.platform, "system", return_value="Linux"), \
             mock.patch.object(release.platform, "machine", return_value="x86_64"), \
             mock.patch.object(release, "tool_version", return_value="fixture tool"), \
             mock.patch.object(release, "build_cli", side_effect=fixture_cli), \
             mock.patch.object(release, "compile_hello", return_value=(self.x86, {
                 "runtime": {"status": "pass"}, "source_path": "examples/hello"})), \
             mock.patch.object(release, "command", return_value=b"asm 0.5.0 (x86_64-linux)\n"):
            return release.build_release(self.repo, output, native_inputs={"aarch64-linux": self.native}, **kwargs)

    def test_final_release_consumes_native_arm_bytes_and_evidence(self):
        output = self.directory / "release"
        result = self.build(output)
        self.assertEqual((output / "asm-0.5.0-aarch64-linux").read_bytes(), self.arm)
        self.assertEqual(result["builds"]["asm_targets"]["aarch64-linux"], self.evidence)
        records = registry.read_records(output / "registry")
        cli = next(record for record in records if record["name"] == "stubbi/asm")
        artifact = next(item for item in cli["artifacts"] if item["target"] == "aarch64-linux")
        self.assertEqual(artifact["sha256"], hashlib.sha256(self.arm).hexdigest())
        self.assertEqual(artifact["bytes"], len(self.arm))

    def test_wrong_commit_or_corrupt_native_bytes_leave_no_release_output(self):
        for mutation in ("wrong-commit", "corrupt-bytes"):
            with self.subTest(mutation=mutation):
                evidence = copy.deepcopy(self.evidence)
                if mutation == "wrong-commit":
                    evidence["source_commit"] = "b" * 40
                else:
                    (self.native / evidence["asset"]["file"]).write_bytes(self.arm + b"changed")
                (self.native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
                output = self.directory / mutation
                with self.assertRaises(registry.RegistryError):
                    self.build(output)
                self.assertFalse(output.exists())

    def test_source_build_contract_mismatch_is_rejected_before_build_or_output(self):
        for mode, schema, targets in (
                ("selected target; native libraries require the native host", 1, ["aarch64-linux"]),
                ("native host", 2, ["x86_64-linux", "aarch64-linux", "riscv64-linux"])):
            with self.subTest(mode=mode, schema=schema):
                path = self.repo / "cli/commands.json"
                commands = json.loads(path.read_text())
                commands["build_mode"] = mode
                path.write_text(json.dumps(commands) + "\n")
                git(self.repo, "add", "cli/commands.json")
                git(self.repo, "-c", "user.name=Release fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "Set synthetic source build contract")
                evidence = copy.deepcopy(self.evidence)
                evidence.update(source_commit=git(self.repo, "rev-parse", "HEAD"), schema=schema)
                evidence["targets_check"]["result"]["targets"] = targets
                (self.native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
                output = self.directory / f"wrong-source-contract-schema-{schema}"
                with mock.patch.object(release.platform, "system", return_value="Linux"), \
                     mock.patch.object(release.platform, "machine", return_value="x86_64"), \
                     mock.patch.object(release, "command") as command:
                    with self.assertRaisesRegex(registry.RegistryError, "different source build contract"):
                        release.build_release(self.repo, output, native_inputs={"aarch64-linux": self.native})
                    command.assert_not_called()
                self.assertFalse(output.exists())

    def test_legacy_macos_input_can_coexist_without_widening_hosts(self):
        macos = self.directory / "macos"
        macos.mkdir()
        binary = minimal_macho()
        evidence = native_evidence(self.commit, "0.5.0", binary)
        (macos / evidence["asset"]["file"]).write_bytes(binary)
        (macos / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
        output = self.directory / "linux-only"
        result = self.build(output, native_input=macos)
        self.assertEqual(result["cli_hosts"], ["x86_64-linux", "aarch64-linux"])
        self.assertFalse((output / "asm-0.5.0-aarch64-macos").exists())


class FakeResponse(io.BytesIO):
    def __init__(self, data, url, headers=None, status=200):
        super().__init__(data)
        self.url = url
        self.headers = headers or {}
        self.status = status

    def geturl(self):
        return self.url


class FakeOpener:
    def __init__(self, data, url, headers=None):
        self.data, self.url, self.headers = data, url, headers

    def open(self, request, timeout):
        return FakeResponse(self.data, self.url, self.headers)


class LicenseDeclarationTests(unittest.TestCase):
    def test_legacy_mit_source_keeps_its_license(self):
        files = {"LICENSE": (b"MIT License\nLegacy fixture.\n", 0o644)}
        self.assertEqual(release.core_license(files, {"version": "0.1.0"}), "MIT")
        with self.assertRaises(registry.RegistryError):
            release.core_license(files, {"version": "0.2.0"})

    def test_agpl_declaration_requires_separate_mit_template_notice(self):
        # Test source-layout checks, not the legal completeness of a notice.
        files = {
            "LICENSE": (b"GNU AFFERO GENERAL PUBLIC LICENSE\nVersion 3, 19 November 2007\n", 0o644),
            "LICENSING.md": (b"Fixture scope declaration.\n", 0o644),
            "LICENSES/MIT.txt": (b"MIT License\nTemplate fixture.\n", 0o644),
        }
        commands = {"version": "0.2.0", "license": "AGPL-3.0-or-later", "template_license": "MIT"}
        self.assertEqual(release.core_license(files, commands), "AGPL-3.0-or-later")
        for missing in ("LICENSE", "LICENSING.md", "LICENSES/MIT.txt"):
            candidate = dict(files)
            del candidate[missing]
            with self.subTest(missing=missing), self.assertRaises(registry.RegistryError):
                release.core_license(candidate, commands)
        for changes in ({"license": "AGPL-3.0-only"}, {"license": "MIT"}, {"template_license": "AGPL-3.0-or-later"}):
            with self.subTest(changes=changes), self.assertRaises(registry.RegistryError):
                release.core_license(files, {**commands, **changes})
        with self.assertRaises(registry.RegistryError):
            release.require_mit_example({"LICENSE": files["LICENSE"]}, "hello")
        release.require_mit_example({"LICENSE": files["LICENSES/MIT.txt"]}, "hello")

    def test_agpl_readme_scope_keeps_the_existing_mit_notice(self):
        files = {
            "LICENSE": (b"GNU AFFERO GENERAL PUBLIC LICENSE\nVersion 3, 19 November 2007\n", 0o644),
            "README.md": (b"# Asm\n\n## License\n\nAGPL-3.0-or-later; cli/templates.s and cli/aarch64/templates.s use MIT.\n", 0o644),
            "examples/hello/LICENSE": (b"MIT License\nTemplate fixture.\n", 0o644),
        }
        commands = {"version": "0.5.0", "license": "AGPL-3.0-or-later", "template_license": "MIT"}
        self.assertEqual(release.core_license(files, commands), "AGPL-3.0-or-later")
        for missing in files:
            candidate = dict(files)
            del candidate[missing]
            with self.subTest(missing=missing), self.assertRaises(registry.RegistryError):
                release.core_license(candidate, commands)
        for readme in (b"# Asm\n", b"## License\n\nAGPL-3.0-or-later\n"):
            with self.subTest(readme=readme), self.assertRaises(registry.RegistryError):
                release.core_license({**files, "README.md": (readme, 0o644)}, commands)


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64" and
                     all(shutil.which(tool) for tool in ("git", "make", "as", "ld")),
                     "native release checks require Linux x86_64 and GNU build tools")
class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = ROOT / "build"
        scratch.mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-release-tests-", dir=scratch)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        cls.repo = cls.base / "repo"
        cls.repo.mkdir()
        shutil.copytree(ROOT / "cli", cls.repo / "cli")
        cls.version = json.loads((cls.repo / "cli/commands.json").read_text())["version"]
        # This fixture qualifies the Linux producer. The separate native
        # fixture exercises Darwin; the fan-in test below declares that host.
        command_metadata = json.loads((cls.repo / "cli/commands.json").read_text())
        command_metadata["hosts"] = ["x86_64-linux", "aarch64-linux"]
        (cls.repo / "cli/commands.json").write_text(json.dumps(command_metadata) + "\n")
        shutil.copytree(ROOT / "examples/hello", cls.repo / "examples/hello", ignore=shutil.ignore_patterns("build"))
        if (ROOT / "examples/math").is_dir():
            shutil.copytree(ROOT / "examples/math", cls.repo / "examples/math", ignore=shutil.ignore_patterns("build"))
        shutil.copytree(ROOT / "site", cls.repo / "site")
        shutil.copytree(ROOT / "skills/asm-build", cls.repo / "skills/asm-build")
        (cls.repo / "tools").mkdir()
        shutil.copy2(ROOT / "tools/install.sh", cls.repo / "tools/install.sh")
        shutil.copyfile(ROOT / "README.md", cls.repo / "README.md")
        shutil.copyfile(ROOT / "LICENSE", cls.repo / "LICENSE")
        (cls.repo / "asm.toml").write_text(f'[package]\nname = "asm"\nversion = "{cls.version}"\n\n[build]\nsource = "cli/asm.s"\ntarget = "x86_64-linux"\n')
        shutil.copyfile(ROOT / "Makefile", cls.repo / "Makefile")
        git(cls.repo, "init", "-q")
        git(cls.repo, "config", "user.name", "Release test fixture")
        git(cls.repo, "config", "user.email", "fixture@example.invalid")
        git(cls.repo, "add", ".")
        git(cls.repo, "commit", "-qm", "Create isolated release fixture")
        cls.commit = git(cls.repo, "rev-parse", "HEAD")
        # The fan-in consumer fixture is synthetic. Hosted native jobs supply
        # actual runtime qualification; the local fixture tests exact bytes.
        cls.arm_input = cls.base / "native-arm-input"
        cls.arm_input.mkdir()
        cls.arm_binary = minimal_arm_elf()
        cls.arm_evidence = arm_native_evidence(cls.commit, cls.version, cls.arm_binary, selected_target=True)
        (cls.arm_input / cls.arm_evidence["asset"]["file"]).write_bytes(cls.arm_binary)
        (cls.arm_input / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(cls.arm_evidence))
        cls.first = cls.base / "first-release"
        cls.metadata = release.build_release(cls.repo, cls.first, native_inputs={"aarch64-linux": cls.arm_input})
        cls.records = registry.read_records(cls.first / "registry")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.case_dir = Path(tempfile.mkdtemp(prefix="case-", dir=self.base))

    def artifact_reader(self, url, limit, hosts, *, expected_size=None):
        filename = registry.artifact_url(url)[2]
        if filename == "release-attestation.sigstore.json":
            # The site checks bundle availability and shape, not signatures.
            return b'{"dsseEnvelope": {"payload": "unsigned test fixture"}}'
        return (self.first / filename).read_bytes()

    def test_two_releases_match_and_ignore_uncommitted_source(self):
        source = self.repo / "cli/asm.s"
        original = source.read_bytes()
        try:
            source.write_text("This uncommitted change cannot compile.\n")
            second = self.case_dir / "second"
            release.build_release(self.repo, second, self.commit, native_inputs={"aarch64-linux": self.arm_input})
        finally:
            source.write_bytes(original)
        first_files = {path.relative_to(self.first): path.read_bytes() for path in self.first.rglob("*") if path.is_file()}
        second_files = {path.relative_to(second): path.read_bytes() for path in second.rglob("*") if path.is_file()}
        self.assertEqual(first_files, second_files)
        archive = registry.read_archive((second / f"asm-{self.version}-source.tar.gz").read_bytes())
        self.assertEqual(archive["cli/asm.s"], original)
        self.assertFalse(any(name.startswith((".git/", "build/")) for name in archive))

    def test_release_checksums_and_recorded_build_results_match(self):
        for line in (self.first / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256((self.first / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(self.metadata["source_commit"], self.commit)
        self.assertEqual(self.metadata["builds"]["hello"]["x86_64-linux"]["runtime"]["status"], "pass")
        self.assertEqual(self.metadata["builds"]["asm"]["version_check"]["status"], "pass")
        self.assertEqual(self.metadata["builds"]["asm_targets"]["aarch64-linux"]["version_check"]["status"], "pass")
        self.assertEqual(self.metadata["cli_hosts"], ["x86_64-linux", "aarch64-linux"])
        hello = next(record for record in self.records if record["name"] == "stubbi/hello")
        self.assertEqual(hello["source"]["path"], "examples/hello")
        cli = next(record for record in self.records if record["name"] == "stubbi/asm")
        self.assertEqual({item["target"] for item in cli["artifacts"] if item["kind"] == "executable"},
                         {"x86_64-linux", "aarch64-linux"})
        self.assertEqual(registry.validate_local_artifacts(self.records, self.first),
                         {(item["name"], item["version"]) for item in self.records})

    def test_release_preserves_core_and_example_license_scopes(self):
        licenses = {record["name"]: record["license"] for record in self.records}
        self.assertEqual(licenses, {"stubbi/asm": "AGPL-3.0-or-later", "stubbi/hello": "MIT", "stubbi/math": "MIT"})
        self.assertEqual(self.metadata["license"], "AGPL-3.0-or-later")
        self.assertEqual(self.metadata["template_license"], "MIT")
        self.assertEqual(self.metadata["package_licenses"], licenses)
        source = registry.read_archive((self.first / f"asm-{self.version}-source.tar.gz").read_bytes())
        self.assertEqual(source["LICENSE"], (ROOT / "LICENSE").read_bytes())
        self.assertEqual(source["examples/hello/LICENSE"], (ROOT / "examples/hello/LICENSE").read_bytes())
        self.assertEqual(source["README.md"], (ROOT / "README.md").read_bytes())
        self.assertEqual(source["tools/install.sh"], (ROOT / "tools/install.sh").read_bytes())
        self.assertNotIn("LICENSING.md", source)
        self.assertFalse(any(name.startswith("LICENSES/") for name in source))
        self.assertEqual(source["cli/templates.s"], (ROOT / "cli/templates.s").read_bytes())
        self.assertEqual(source["cli/aarch64/templates.s"], (ROOT / "cli/aarch64/templates.s").read_bytes())
        project = self.case_dir / "source"
        release.materialize({name: (data, 0o644) for name, data in source.items()}, project)
        (project / "build").mkdir()
        binary = self.first / f"asm-{self.version}-x86_64-linux"
        shutil.copy2(binary, project / "build/asm")
        prefix = self.case_dir / "installed"
        result = subprocess.run(["make", "--no-print-directory", "-o", "build/asm", "install",
                                 f"DESTDIR={prefix}", "PREFIX=/usr"], cwd=project,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual((prefix / "usr/bin/asm").read_bytes(), binary.read_bytes())

    def test_mac_fan_in_preserves_exact_native_bytes_and_requires_declaration(self):
        repo = self.case_dir / "native-fan-in-repo"
        git(self.repo, "clone", "--quiet", "--no-hardlinks", str(self.repo), str(repo))
        metadata_path = repo / "cli/commands.json"
        commands = json.loads(metadata_path.read_text())
        commands["hosts"].append("aarch64-macos")
        metadata_path.write_text(json.dumps(commands) + "\n")
        git(repo, "add", "cli/commands.json")
        git(repo, "-c", "user.name=Release fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-qm", "Declare synthetic native input for fan-in test")
        commit = git(repo, "rev-parse", "HEAD")
        native = self.case_dir / "native-input"
        native.mkdir()
        binary = minimal_macho()
        evidence = native_evidence(commit, self.version, binary, selected_target=True)
        filename = evidence["asset"]["file"]
        (native / filename).write_bytes(binary)
        (native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
        arm = self.case_dir / "arm-input"
        arm.mkdir()
        (arm / self.arm_evidence["asset"]["file"]).write_bytes(self.arm_binary)
        (arm / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes({**self.arm_evidence, "source_commit": commit}))
        output = self.case_dir / "with-native-host"
        result = release.build_release(repo, output, native_input=native, native_inputs={"aarch64-linux": arm})
        self.assertEqual((output / filename).read_bytes(), binary)
        self.assertIn("aarch64-macos", result["cli_hosts"])
        self.assertEqual(result["builds"]["asm_targets"]["aarch64-macos"], evidence)
        self.assertIn(filename, {item["file"] for item in result["assets"]})
        # The same evidence must not authorize another source commit.
        with self.assertRaises(registry.RegistryError):
            release.build_release(self.repo, self.case_dir / "wrong-commit", native_input=native)
        # A valid optional qualification input does not add an undeclared host.
        evidence["source_commit"] = self.commit
        (native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
        undeclared = self.case_dir / "linux-only"
        result = release.build_release(self.repo, undeclared, native_input=native, native_inputs={"aarch64-linux": self.arm_input})
        self.assertNotIn("aarch64-macos", result["cli_hosts"])
        self.assertFalse((undeclared / filename).exists())

    def test_version_mismatch_leaves_no_output(self):
        output = self.case_dir / "wrong-version"
        with self.assertRaises(registry.RegistryError):
            release.build_release(self.repo, output, version="99.0.0")
        self.assertFalse(output.exists())

    def test_existing_output_is_preserved(self):
        output = self.case_dir / "existing"
        output.mkdir()
        marker = output / "keep.txt"
        marker.write_text("Existing data")
        with self.assertRaises(registry.RegistryError):
            release.build_release(self.repo, output)
        self.assertEqual(marker.read_text(), "Existing data")

    def test_destination_created_after_initial_check_is_not_replaced(self):
        stage = self.case_dir / "stage"
        stage.mkdir()
        (stage / "asset").write_text("Complete artifact")
        output = release.output_path(self.case_dir / "race-output")
        output.mkdir()  # Deterministic interleaving after the early existence check.
        before = output.stat().st_ino
        with self.assertRaises(FileExistsError):
            release.publish_directory(stage, output)
        self.assertEqual(output.stat().st_ino, before)
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual((stage / "asset").read_text(), "Complete artifact")

    @unittest.skipUnless(all(shutil.which(tool) for tool in (
        "aarch64-linux-gnu-as", "aarch64-linux-gnu-ld", "riscv64-linux-gnu-as", "riscv64-linux-gnu-ld")) and
        all(release.target_runner(name, dict(os.environ)) for name in ("qemu-aarch64", "qemu-riscv64")),
        "cross-target release check requires GNU cross tools and QEMU")
    def test_requested_cross_targets_are_built_and_run(self):
        output = self.case_dir / "cross-release"
        result = release.build_release(self.repo, output, hello_targets=list(release.HELLO_TARGETS),
                                       native_inputs={"aarch64-linux": self.arm_input})
        self.assertEqual(result["cli_hosts"], ["x86_64-linux", "aarch64-linux"])
        for target in release.HELLO_TARGETS:
            self.assertEqual(result["builds"]["hello"][target]["runtime"]["status"], "pass")
        records = registry.read_records(output / "registry")
        hello = next(record for record in records if record["name"] == "stubbi/hello")
        self.assertEqual(len(hello["artifacts"]), 6)
        registry.validate_local_artifacts(records, output)

    def test_site_without_network_keeps_evidence_and_counts_unknown(self):
        def forbidden(*args, **kwargs):
            raise AssertionError("Offline site build made a network request")
        output = self.case_dir / "offline-site"
        result = build_site.build_site(self.repo, self.first / "registry", output,
                                      artifact_reader=forbidden, metrics_fetcher=forbidden)
        self.assertEqual(result["artifact_checked_releases"], 0)
        self.assertIsNone(result["bootstrap_version"])
        self.assertFalse((output / "install.sh").exists())
        index = json.loads((output / "registry/v1/index.json").read_text())
        for package in index["packages"]:
            self.assertTrue(all(version["evidence"]["artifacts"] == "not-run" for version in package["versions"]))
        counts = json.loads((output / "registry/v1/downloads.json").read_text())
        self.assertIsNone(counts["observed_at"])
        self.assertTrue(all(value["total"] is None for value in counts["packages"].values()))
        self.assertEqual((output / "reference/asm.s").read_bytes(), (self.repo / "cli/asm.s").read_bytes())

    def test_artifact_evidence_requires_all_exact_bytes(self):
        output = self.case_dir / "checked-site"
        result = build_site.build_site(self.repo, self.first / "registry", output,
                                      verify=True, artifact_reader=self.artifact_reader)
        self.assertEqual(result["artifact_checked_releases"], len(self.records))
        self.assertEqual(result["bootstrap_version"], self.version)
        self.assertTrue((output / "install.sh").is_file())
        index = json.loads((output / "registry/v1/index.json").read_text())
        self.assertTrue(all(v["evidence"]["artifacts"] == "validated" for p in index["packages"] for v in p["versions"]))
        failed = self.case_dir / "failed-site"
        with self.assertRaises(registry.RegistryError):
            build_site.build_site(self.repo, self.first / "registry", failed, verify=True,
                                  artifact_reader=lambda *args, **kwargs: b"tampered")
        self.assertFalse(failed.exists())

    def test_missing_release_bundle_preserves_the_unpublished_site(self):
        requests = []
        def missing_bundle(url, limit, hosts, *, expected_size=None):
            requests.append(url)
            if url.endswith("/release-attestation.sigstore.json"):
                raise URLError("release bundle does not exist")
            return self.artifact_reader(url, limit, hosts, expected_size=expected_size)
        output = self.case_dir / "missing-bundle-site"
        with self.assertRaises(URLError):
            build_site.build_site(self.repo, self.first / "registry", output,
                                  verify=True, artifact_reader=missing_bundle)
        self.assertFalse(output.exists())
        self.assertTrue(requests[-1].endswith("/release-attestation.sigstore.json"))

    def test_metrics_failure_does_not_become_success_or_zero(self):
        def unavailable(url):
            raise URLError("network unavailable")
        output = self.case_dir / "missing-metrics"
        result = build_site.build_site(self.repo, self.first / "registry", output,
                                      downloads=True, metrics_fetcher=unavailable)
        self.assertEqual(result["artifact_checked_releases"], 0)
        counts = json.loads((output / "registry/v1/downloads.json").read_text())
        self.assertTrue(all(value["total"] is None for value in counts["packages"].values()))


class DownloadPolicyTests(unittest.TestCase):
    URL = "https://github.com/stubbi/asm/releases/download/v0.1.0/asm-0.1.0-x86_64-linux"

    def test_redirects_reject_unapproved_origins_and_url_tricks(self):
        for url in ("http://github.com/stubbi/asm/releases/download/v0.1.0/a", "https://github.com.evil.example/a",
                    "https://user@github.com/a", "https://github.com:443/a", "https://127.0.0.1/a",
                    "https://github.com/stubbi/asm/releases/download/v0.1.0/a%2fb",
                    "https://release-assets.githubusercontent.com/a#fragment", " https://github.com/a"):
            with self.subTest(url=url), self.assertRaises(registry.RegistryError):
                build_site.check_https_url(url, build_site.ASSET_HOSTS)
        build_site.check_https_url("https://release-assets.githubusercontent.com/path?signature=value", build_site.ASSET_HOSTS)

    def test_declared_size_is_enforced_without_content_length(self):
        opener = FakeOpener(b"abcd", self.URL)
        with self.assertRaises(registry.RegistryError):
            build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS, expected_size=3, opener=opener)
        opener = FakeOpener(b"abc", self.URL)
        self.assertEqual(build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS, expected_size=3, opener=opener), b"abc")

    def test_oversize_header_and_unexpected_encoding_are_rejected(self):
        for headers in ({"Content-Length": "65"}, {"Content-Length": "-1"}, {"Content-Encoding": "gzip"}):
            with self.subTest(headers=headers), self.assertRaises(registry.RegistryError):
                build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS, opener=FakeOpener(b"abc", self.URL, headers))

    def test_final_response_origin_is_checked_again(self):
        with self.assertRaises(registry.RegistryError):
            build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS,
                                  opener=FakeOpener(b"abc", "https://example.invalid/payload"))


if __name__ == "__main__":
    unittest.main()
