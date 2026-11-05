"""Check verifier target selection without requiring a Go installation.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
UNUSED_GO = "/no-go-required-for-build-selection"


class VerifierBuildSelectionTests(unittest.TestCase):
    def dry_run(self, target, *, operating_system="Darwin", architecture="aarch64",
                directory=ROOT, force=True):
        environment = dict(os.environ)
        for name in ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            environment.pop(name, None)
        command = ["make", "--no-print-directory", "-n"]
        if force:
            command.append("-B")
        command += [f"HOST_OS={operating_system}", f"ARCH={architecture}",
                    f"GO={UNUSED_GO}", "TRUSTED_DISTRIBUTION=0", target]
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
        expected = {"CGO_ENABLED": "0", "GOOS": go_os, "GOARCH": go_architecture}
        for recipe in (build, notices):
            self.assertEqual(self.recipe_environment(recipe), expected, recipe)
        self.assertIn(f"../{target}", shlex.split(build))
        self.assertIn(f"{target}.LICENSES.txt", shlex.split(notices))

    def test_source_targets_select_explicit_build_and_notice_platforms(self):
        for operating_system, architecture, suffix, go_os, go_architecture in (
            ("Linux", "x86_64", "x86_64-linux", "linux", "amd64"),
            ("Linux", "aarch64", "aarch64-linux", "linux", "arm64"),
            ("Linux", "riscv64", "riscv64-linux", "linux", "riscv64"),
            ("Darwin", "aarch64", "aarch64-macos", "darwin", "arm64"),
        ):
            with self.subTest(target=suffix):
                target = f"build/asm-verify-{suffix}"
                result = self.dry_run(target, operating_system=operating_system,
                                      architecture=architecture)
                self.assert_target_environment(result, target, go_os, go_architecture)

    def test_explicit_linux_targets_cross_build_from_the_native_mac_configuration(self):
        for architecture, go_architecture in (("x86_64", "amd64"), ("aarch64", "arm64"), ("riscv64", "riscv64")):
            with self.subTest(architecture=architecture):
                target = f"build/asm-verify-{architecture}-linux"
                self.assert_target_environment(self.dry_run(target), target, "linux", go_architecture)

    def test_unknown_cli_platforms_fail_before_any_build_recipe(self):
        for operating_system, architecture in (
            ("FreeBSD", "aarch64"), ("Windows_NT", "x86_64"),
            ("Linux", "mips64"), ("Darwin", "x86_64"),
        ):
            with self.subTest(operating_system=operating_system, architecture=architecture):
                result = self.dry_run(f"build/asm-verify-{architecture}-linux",
                                      operating_system=operating_system, architecture=architecture)
                self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
                self.assertNotIn(UNUSED_GO, result.stdout)
                self.assertNotEqual(result.stderr, "")

    def test_unintegrated_verifier_targets_have_no_build_rule(self):
        for target in ("x86_64-macos", "x86_64-windows",
                       "aarch64-windows", "x86_64-freebsd"):
            with self.subTest(target=target):
                result = self.dry_run(f"build/asm-verify-{target}")
                self.assertNotEqual(result.returncode, 0, (result.stdout, result.stderr))
                self.assertNotIn(UNUSED_GO, result.stdout)

    def test_ordinary_cli_build_does_not_schedule_go(self):
        result = self.dry_run("all")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertNotIn(UNUSED_GO, result.stdout)
        self.assertNotIn("verifier_notices.py", result.stdout)

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

    def test_internal_source_change_rebuilds_an_existing_verifier(self):
        with tempfile.TemporaryDirectory(prefix="asm-verifier-input-") as temporary:
            directory = Path(temporary)
            inputs = {
                "Makefile": (ROOT / "Makefile").read_bytes(),
                "verifier/main.go": b"package main\n",
                "verifier/internal/securefs/files_windows.go": b"original adapter bytes\n",
                "verifier/go.mod": b"module fixture\n",
                "verifier/go.sum": b"",
                "verifier/trust/asm-root.json": b"{}\n",
                # Keep the real make recipes and filesystem effects. This
                # controlled compiler avoids a Go dependency in this gate.
                "compiler.py": b"from pathlib import Path\nimport sys\n"
                    b"assert sys.argv[1] == 'build'\n"
                    b"Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(\n"
                    b"    Path('internal/securefs/files_windows.go').read_bytes())\n",
                "tools/verifier_notices.py": b"from pathlib import Path\nimport sys\n"
                    b"Path(sys.argv[-1]).write_text('fixture notices\\n')\n",
            }
            for name, data in inputs.items():
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                os.utime(path, (1_700_000_000, 1_700_000_000))
            target = "build/asm-verify-x86_64-linux"
            arguments = ["make", "--no-print-directory", "HOST_OS=Linux", "ARCH=x86_64",
                         f"GO={sys.executable} {directory / 'compiler.py'}",
                         f"PYTHON={sys.executable}", "TRUSTED_DISTRIBUTION=0", target]
            environment = dict(os.environ)
            for name in ("MAKEFLAGS", "GNUMAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
                environment.pop(name, None)
            def build():
                result = subprocess.run(arguments, cwd=directory, env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
            build()
            artifact = directory / target
            self.assertEqual(artifact.read_bytes(), b"original adapter bytes\n")
            os.utime(artifact, (1_700_000_010, 1_700_000_010))
            source = directory / "verifier/internal/securefs/files_windows.go"
            source.write_bytes(b"changed adapter bytes\n")
            os.utime(source, (1_700_000_020, 1_700_000_020))
            build()
            self.assertEqual(artifact.read_bytes(), b"changed adapter bytes\n")


if __name__ == "__main__":
    unittest.main()
