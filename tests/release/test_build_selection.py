"""Check verifier target selection without requiring a Go installation.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
UNUSED_GO = "/no-go-required-for-build-selection"


class VerifierBuildSelectionTests(unittest.TestCase):
    def dry_run(self, target, *, operating_system="Darwin", architecture="aarch64",
                directory=ROOT, force=True, registry_v2=None):
        environment = dict(os.environ)
        for name in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            environment.pop(name, None)
        command = ["make", "--no-print-directory", "-n"]
        if force:
            command.append("-B")
        command += [f"HOST_OS={operating_system}", f"ARCH={architecture}",
                    f"GO={UNUSED_GO}", "TRUSTED_DISTRIBUTION=0", target]
        if registry_v2 is not None:
            command.append(f"REGISTRY_V2={registry_v2}")
        return subprocess.run(command, cwd=directory, env=environment,
                              capture_output=True, text=True, timeout=10)

    @staticmethod
    def recipe_environment(line):
        tokens = shlex.split(line)
        if "&&" in tokens:
            tokens = tokens[tokens.index("&&") + 1:]
        result = {}
        for token in tokens:
            if "=" not in token:
                break
            name, value = token.split("=", 1)
            result[name] = value
        return result

    def assert_target_environment(self, result, target, go_os, go_architecture):
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        build_commands = [line for line in result.stdout.splitlines()
                          if f"{UNUSED_GO} build " in line]
        notice_commands = [line for line in result.stdout.splitlines()
                           if "tools/verifier_notices.py" in line]
        self.assertEqual(len(build_commands), 1, result.stdout)
        self.assertEqual(len(notice_commands), 1, result.stdout)
        build, notices = build_commands[0], notice_commands[0]
        expected = {"CGO_ENABLED": "0", "GOOS": go_os, "GOARCH": go_architecture,
                    "GOENV": "off", "GOWORK": "off", "GOTOOLCHAIN": "local", "GOFLAGS": "",
                    "GOAMD64": "v1", "GOARM64": "v8.0", "GOEXPERIMENT": "", "GOFIPS140": "off"}
        for recipe in (build, notices):
            self.assertEqual(self.recipe_environment(recipe), expected, recipe)
        self.assertIn(f"../{target}", shlex.split(build))
        self.assertIn(f"{target}.LICENSES.txt", shlex.split(notices))

    def test_current_targets_select_explicit_build_and_notice_platforms(self):
        for operating_system, architecture, suffix, go_os, go_architecture in (
            ("Linux", "x86_64", "x86_64-linux", "linux", "amd64"),
            ("Linux", "aarch64", "aarch64-linux", "linux", "arm64"),
            ("Darwin", "aarch64", "aarch64-macos", "darwin", "arm64"),
        ):
            with self.subTest(target=suffix):
                target = f"build/asm-verify-{suffix}"
                result = self.dry_run(target, operating_system=operating_system,
                                      architecture=architecture)
                self.assert_target_environment(result, target, go_os, go_architecture)

    def test_explicit_linux_targets_cross_build_from_the_native_mac_configuration(self):
        for architecture, go_architecture in (("x86_64", "amd64"), ("aarch64", "arm64")):
            with self.subTest(architecture=architecture):
                target = f"build/asm-verify-{architecture}-linux"
                self.assert_target_environment(self.dry_run(target), target, "linux", go_architecture)

    def test_ambient_cpu_features_cannot_change_adapter_builds_or_notices(self):
        with patch.dict(os.environ, {"GOAMD64": "v4", "GOARM64": "v9.5,lse,crypto",
                                     "GOEXPERIMENT": "invalid-ambient-experiment", "GOFIPS140": "latest"}):
            for suffix, go_os, go_architecture in (("x86_64-linux", "linux", "amd64"),
                                                  ("aarch64-linux", "linux", "arm64"),
                                                  ("aarch64-macos", "darwin", "arm64")):
                target = "build/asm-verify-" + suffix
                with self.subTest(target=target):
                    self.assert_target_environment(self.dry_run(target), target, go_os, go_architecture)

    def test_unknown_cli_platforms_fail_before_any_build_recipe(self):
        for operating_system, architecture in (
            ("FreeBSD", "aarch64"), ("Windows_NT", "x86_64"),
            ("Linux", "riscv64"), ("Darwin", "x86_64"),
        ):
            with self.subTest(operating_system=operating_system, architecture=architecture):
                result = self.dry_run(f"build/asm-verify-{architecture}-linux",
                                      operating_system=operating_system, architecture=architecture)
                self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
                self.assertNotIn(UNUSED_GO, result.stdout)
                self.assertNotEqual(result.stderr, "")

    def test_unintegrated_verifier_targets_have_no_build_rule(self):
        with tempfile.TemporaryDirectory(prefix="asm-unintegrated-target-") as temporary:
            directory = Path(temporary)
            (directory / "Makefile").write_bytes((ROOT / "Makefile").read_bytes())
            for target in ("riscv64-linux", "x86_64-macos", "x86_64-windows",
                           "aarch64-windows", "x86_64-freebsd"):
                with self.subTest(target=target):
                    result = self.dry_run(f"build/asm-verify-{target}", directory=directory)
                    self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
                    self.assertNotIn(UNUSED_GO, result.stdout)

    def test_ordinary_cli_build_includes_v2_without_activating_self_update_trust(self):
        result = self.dry_run("all")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertIn(UNUSED_GO, result.stdout)
        self.assertIn("verifier_notices.py", result.stdout)
        self.assertIn("ASM_REGISTRY_V2", result.stdout)
        self.assertNotIn("ASM_TRUSTED_DISTRIBUTION", result.stdout)
        self.assertNotIn("check-root", result.stdout)

    def test_explicit_minimal_cli_build_does_not_schedule_go(self):
        result = self.dry_run("all", registry_v2="0")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertNotIn(UNUSED_GO, result.stdout)
        self.assertNotIn("verifier_notices.py", result.stdout)
        self.assertNotIn("ASM_REGISTRY_V2", result.stdout)

    def test_profile_outputs_cannot_reuse_a_different_incremental_build(self):
        for operating_system, architecture in (("Linux", "x86_64"), ("Linux", "aarch64"), ("Darwin", "aarch64")):
            full = self.dry_run("all", operating_system=operating_system, architecture=architecture)
            minimal = self.dry_run("all", operating_system=operating_system, architecture=architecture, registry_v2="0")
            with self.subTest(operating_system=operating_system, architecture=architecture):
                self.assertEqual(full.returncode, 0, full.stderr)
                self.assertEqual(minimal.returncode, 0, minimal.stderr)
                self.assertIn("build/v2/", full.stdout)
                self.assertIn("build/v1/", minimal.stdout)

    def test_invalid_registry_profile_fails_before_building(self):
        for value in ("", "yes", "2", "1 0"):
            result = self.dry_run("all", registry_v2=value)
            with self.subTest(value=value):
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(UNUSED_GO, result.stdout)

    def test_makefile_change_rebuilds_an_existing_verifier(self):
        with tempfile.TemporaryDirectory(prefix="asm-build-selection-") as temporary:
            directory = Path(temporary)
            inputs = {"Makefile": (ROOT / "Makefile").read_bytes(),
                      "verifier/main.go": b"package main\n",
                      "verifier/go.mod": b"module fixture\n",
                      "verifier/go.sum": b"",
                      "verifier/trust/asm-root.json": b"{}\n",
                      "tools/verifier_notices.py": b"# Not executed by this dry run.\n"}
            for name, data in inputs.items():
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                os.utime(path, (1_700_000_000, 1_700_000_000))
            target = "build/asm-verify-x86_64-linux"
            artifact = directory / target
            artifact.parent.mkdir()
            artifact.write_bytes(b"A stale verifier artifact.\n")
            os.utime(artifact, (1_700_000_010, 1_700_000_010))
            os.utime(directory / "Makefile", (1_700_000_020, 1_700_000_020))
            result = self.dry_run(target, operating_system="Linux", architecture="x86_64",
                                  directory=directory, force=False)
            self.assert_target_environment(result, target, "linux", "amd64")


if __name__ == "__main__":
    unittest.main()
