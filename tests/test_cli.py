"""Black-box native CLI tests. Python is a development dependency, not a CLI backend."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from host import IS_MACOS, TARGET, OTHER_TARGET, TRIPLE, VERSION, CLI_SOURCE
from host import exit_source, argc_source, illegal_source, undefined_symbol_source


ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build" / "asm"


class NativeCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-test-", dir=ROOT / "build")
        self.work = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *args, cwd=None, code=0, env=None):
        result = subprocess.run(
            [str(ASM), *map(str, args)], cwd=cwd or self.work,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=10, env=env,
        )
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        return result

    def project(self, name="hello"):
        path = self.work / name
        self.cli("new", path)
        return path

    def replace_manifest(self, project, before, after):
        path = project / "asm.toml"
        path.write_text(path.read_text().replace(before, after))

    def exit_program(self, code):
        return exit_source(code)

    def test_version_help_doctor_and_status_json(self):
        self.assertIn(f"asm {VERSION}", self.cli("--version").stdout)
        self.assertIn("Usage:", self.cli().stdout)
        self.assertEqual(json.loads(self.cli("version", "--json").stdout)["version"], VERSION)
        self.assertTrue(json.loads(self.cli("doctor", "--json").stdout)["ok"])
        self.assertIn("new", json.loads(self.cli("help", "--json").stdout)["commands"])
        self.assertEqual(json.loads(self.cli("targets", "--json").stdout), {"host": TARGET, "targets": [TARGET]})
        status = json.loads(self.cli("status").stdout)
        self.assertIn("build", status["implemented"])
        self.assertIn("yank", status["unimplemented"])

    def test_license_and_starter_grants_have_distinct_scopes(self):
        report = json.loads(self.cli("license", "--json").stdout)
        self.assertEqual(report["license"], "AGPL-3.0-or-later")
        self.assertEqual(report["template_license"], "MIT")
        self.assertFalse(report["warranty"])
        self.assertEqual(self.cli("--license").stdout, self.cli("license").stdout)
        self.assertIn("AGPL-3.0-or-later", self.cli("help").stdout)
        self.cli("license", "unexpected", code=2)
        project = self.project()
        notice = (ROOT / "LICENSES/MIT.txt").read_text()
        for relative in ("src/main.s", "tests/main.s"):
            source = (project / relative).read_text()
            self.assertIn("SPDX-License-Identifier: MIT", source)
            uncommented = "\n".join(line[2:] if line.startswith("# ") else ""
                                     for line in source.splitlines())
            self.assertIn(notice.strip(), uncommented)
        self.assertEqual(self.cli("run", cwd=project).stdout, "Hello from asm!\n")
        self.cli("test", cwd=project)

    def test_new_run_test_clean_vertical_slice(self):
        project = self.project()
        self.assertIn('name = "hello"', (project / "asm.toml").read_text())
        self.assertEqual(self.cli("run", cwd=project).stdout, "Hello from asm!\n")
        self.assertTrue((project / "build/app").is_file())
        self.assertTrue(json.loads(self.cli("test", "--json", cwd=project).stdout)["ok"])
        self.cli("clean", cwd=project)
        self.assertFalse((project / "build").exists())
        self.assertTrue((project / "src/main.s").exists())
        self.cli("clean", cwd=project)

    def test_paths_with_spaces_and_shell_metacharacters_are_literal(self):
        project = self.project("hello world; touch NEVER-CREATED")
        self.assertEqual(self.cli("run", cwd=project).stdout, "Hello from asm!\n")
        self.assertFalse((self.work / "NEVER-CREATED").exists())
        moved = project / "src" / "source with spaces.s"
        (project / "src/main.s").rename(moved)
        self.replace_manifest(project, "src/main.s", "src/source with spaces.s")
        self.assertEqual(self.cli("run", cwd=project).stdout, "Hello from asm!\n")

    def test_argument_forwarding_and_exit_status(self):
        project = self.project()
        (project / "src/main.s").write_text(argc_source())
        self.cli("run", "--", "first argument", "$(touch never)", cwd=project, code=3)
        self.assertFalse((project / "never").exists())

    def test_child_failure_is_propagated(self):
        project = self.project()
        (project / "src/main.s").write_text(self.exit_program(37))
        self.cli("run", cwd=project, code=37)
        (project / "tests/main.s").write_text(self.exit_program(9))
        self.assertIn("test program failed", self.cli("test", cwd=project, code=9).stderr)

    def test_child_signal_is_propagated(self):
        project = self.project()
        (project / "src/main.s").write_text(illegal_source())
        self.cli("run", cwd=project, code=132)

    def test_failed_build_preserves_previous_binary_and_cleans_staging(self):
        project = self.project()
        self.cli("build", cwd=project)
        previous = (project / "build/app").read_bytes()
        (project / "src/main.s").write_text("this is not assembly\n")
        self.cli("build", cwd=project, code=1)
        self.assertEqual(previous, (project / "build/app").read_bytes())
        self.assertEqual(list((project / "build").glob(".asm-*")), [])
        self.cli("run", cwd=project, code=1)

    def test_link_failure_is_propagated(self):
        project = self.project()
        (project / "src/main.s").write_text(undefined_symbol_source())
        self.cli("build", cwd=project, code=1)
        self.assertFalse((project / "build/app").exists())

    def test_output_obstruction_preserves_previous_binary(self):
        project = self.project()
        self.cli("build", cwd=project)
        previous = (project / "build/app").read_bytes()
        (project / "src/main.s").write_text(self.exit_program(7))
        (project / "build/main.o").unlink()
        (project / "build/main.o").mkdir()
        self.cli("build", cwd=project, code=1)
        self.assertEqual((project / "build/app").read_bytes(), previous)
        self.assertEqual(list((project / "build").glob(".asm-*")), [])

    def test_new_never_overwrites_directory(self):
        project = self.project()
        manifest = (project / "asm.toml").read_bytes()
        self.cli("new", project, code=1)
        self.assertEqual((project / "asm.toml").read_bytes(), manifest)
        self.cli("init", project, code=1)
        self.assertEqual((project / "asm.toml").read_bytes(), manifest)

    def test_init_current_directory_and_partial_conflict(self):
        self.cli("init")
        self.assertTrue((self.work / "asm.toml").is_file())
        other = self.work / "existing"
        (other / "src").mkdir(parents=True)
        source = other / "src/main.s"
        source.write_text("precious source\n")
        self.cli("init", other, code=1)
        self.assertEqual(source.read_text(), "precious source\n")
        self.assertFalse((other / "asm.toml").exists())

    def test_init_rejects_symlink_directories_without_writing_through_them(self):
        outside = self.work / "outside"
        outside.mkdir()
        project = self.work / "project"
        project.mkdir()
        (project / "src").symlink_to(outside, target_is_directory=True)
        self.cli("init", project, code=1)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((project / "asm.toml").exists())

    def test_build_and_clean_refuse_symlink_build_directory(self):
        project = self.project()
        outside = self.work / "outside"
        outside.mkdir()
        (outside / "app").write_text("do not touch")
        (project / "build").symlink_to(outside, target_is_directory=True)
        self.cli("build", cwd=project, code=1)
        self.cli("clean", cwd=project, code=1)
        self.assertEqual((outside / "app").read_text(), "do not touch")

    def test_clean_preserves_unrelated_files(self):
        project = self.project()
        self.cli("build", cwd=project)
        keep = project / "build/keep.txt"
        keep.write_text("user data")
        self.cli("clean", cwd=project)
        self.assertEqual(keep.read_text(), "user data")
        self.assertFalse((project / "build/app").exists())

    def test_manifest_is_parsed_and_validated(self):
        project = self.project()
        manifest = project / "asm.toml"
        original = manifest.read_text()
        mutations = [
            original.replace('name = "hello"', 'name = "Bad Name"'),
            original.replace('version = "0.1.0"', 'version = "01.1.0"'),
            original.replace('version = "0.1.0"', 'version = "1.0"'),
            original.replace('source = "src/main.s"', 'source = "../outside.s"'),
            original.replace('source = "src/main.s"', 'source = "/etc/passwd"'),
            original.replace('source = "src/main.s"', 'source = "-option.s"'),
            original.replace('source = "src/main.s"', 'source = "src//main.s"'),
            original.replace('source = "src/main.s"', 'source = "src/./main.s"'),
            original + 'source = "src/another.s"\n',
            original + 'unknown = "value"\n',
            original + '[build]\n',
            original + '\x00hidden content',
            original.replace('name = "hello"', 'name = "hello" trailing'),
            "[package]\nname = \"hello\"\n",
            "x" * 8192,
        ]
        for content in mutations:
            with self.subTest(content=content[:120]):
                manifest.write_text(content)
                self.cli("build", cwd=project, code=1)
        manifest.write_text(original)
        self.cli("build", cwd=project)

    def test_missing_manifest_fails_and_symlink_manifest_fails(self):
        self.cli("build", code=1)
        self.cli("clean", code=1)
        project = self.project()
        manifest = project / "asm.toml"
        actual = project / "actual.toml"
        manifest.rename(actual)
        manifest.symlink_to(actual)
        self.cli("build", cwd=project, code=1)

    def test_fifo_manifest_is_rejected_without_blocking(self):
        os.mkfifo(self.work / "asm.toml")
        self.cli("build", code=1)

    def test_options_and_unsupported_targets(self):
        project = self.project()
        self.cli("build", "--target", TARGET, "--no-color", cwd=project)
        self.cli("build", "--target", TRIPLE, cwd=project)
        self.cli("build", "--target", OTHER_TARGET, cwd=project, code=2)
        self.cli("build", "--target", cwd=project, code=2)
        self.cli("build", "--mystery", cwd=project, code=2)
        self.cli("new", code=2)
        self.cli("new", "", code=2)
        self.cli("new", "one", "two", code=2)
        self.cli("run", "not-forwarded-without-separator", cwd=project, code=2)
        self.cli("nosuchcommand", code=2)
        self.replace_manifest(project, TARGET, OTHER_TARGET)
        self.cli("build", cwd=project, code=2)

    def test_leading_dash_path_with_separator(self):
        self.cli("new", "--", "-literal")
        self.assertTrue((self.work / "-literal/asm.toml").is_file())

    def test_registry_length_package_name_builds_locally(self):
        project = self.project("a" * 64)
        self.assertIn('name = "' + "a" * 64 + '"', (project / "asm.toml").read_text())
        self.cli("build", cwd=project)

    def test_registry_commands_fail_honestly(self):
        for command in ["login", "yank"]:
            with self.subTest(command=command):
                result = self.cli(command, "example", "--json", code=69)
                self.assertFalse(json.loads(result.stderr)["ok"])

    def test_no_shell_or_runtime_dependency(self):
        # An empty PATH must not affect fixed-path tool execution or native CLI.
        project = self.project()
        env = dict(os.environ, PATH="")
        self.assertEqual(self.cli("run", cwd=project, env=env).stdout, "Hello from asm!\n")
        if IS_MACOS:
            header = subprocess.run(["otool", "-L", ASM], capture_output=True, text=True, check=True)
            self.assertIn("/usr/lib/libSystem.B.dylib", header.stdout)
            self.assertNotIn("libpython", header.stdout)
            return
        header = subprocess.run(["readelf", "-l", ASM], capture_output=True, text=True, check=True)
        self.assertNotIn("INTERP", header.stdout)
        self.assertNotIn("RWE", header.stdout)

    def test_cli_builds_its_own_assembly_sources(self):
        shutil.copytree(ROOT / "cli", self.work / "cli")
        if IS_MACOS:
            shutil.copyfile(ROOT / "build/macos/asm.s", self.work / CLI_SOURCE)
        (self.work / "asm.toml").write_text(
            '[package]\nname = "asm"\nversion = "0.1.0"\n\n'
            f'[build]\nsource = "{CLI_SOURCE}"\ntarget = "{TARGET}"\n'
        )
        self.cli("build")
        result = subprocess.run(
            [str(self.work / "build/app"), "status"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        self.assertIn("fetch", json.loads(result.stdout)["implemented"])


if __name__ == "__main__":
    unittest.main()
