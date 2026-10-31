"""Black-box native CLI tests. Python is a development dependency, not a CLI backend."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


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
        return (
            ".intel_syntax noprefix\n.global _start\n.text\n_start:\n"
            f"    mov eax, 60\n    mov edi, {code}\n    syscall\n"
            '.section .note.GNU-stack,"",@progbits\n'
        )

    def test_version_help_doctor_and_status_json(self):
        self.assertIn("asm 0.1.0", self.cli("--version").stdout)
        self.assertIn("Usage:", self.cli().stdout)
        self.assertEqual(json.loads(self.cli("version", "--json").stdout)["version"], "0.1.0")
        self.assertTrue(json.loads(self.cli("doctor", "--json").stdout)["ok"])
        self.assertIn("new", json.loads(self.cli("help", "--json").stdout)["commands"])
        self.assertEqual(json.loads(self.cli("targets", "--json").stdout)["targets"], ["x86_64-linux"])
        status = json.loads(self.cli("status").stdout)
        self.assertIn("build", status["implemented"])
        self.assertIn("publish", status["unimplemented"])

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
        (project / "src/main.s").write_text(
            ".intel_syntax noprefix\n.global _start\n.text\n_start:\n"
            "mov rdi, [rsp]\nmov eax, 60\nsyscall\n"
        )
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
        (project / "src/main.s").write_text(
            ".intel_syntax noprefix\n.global _start\n.text\n_start:\nud2\n"
        )
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
        (project / "src/main.s").write_text(
            ".intel_syntax noprefix\n.global _start\n.text\n_start:\ncall missing_symbol\n"
        )
        self.cli("build", cwd=project, code=1)
        self.assertFalse((project / "build/app").exists())

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

    def test_options_and_unsupported_targets(self):
        project = self.project()
        self.cli("build", "--target", "x86_64-linux", "--no-color", cwd=project)
        self.cli("build", "--target", "x86_64-unknown-linux-gnu", cwd=project)
        self.cli("build", "--target", "aarch64-linux", cwd=project, code=2)
        self.cli("build", "--target", cwd=project, code=2)
        self.cli("build", "--mystery", cwd=project, code=2)
        self.cli("new", code=2)
        self.cli("new", "", code=2)
        self.cli("new", "one", "two", code=2)
        self.cli("run", "not-forwarded-without-separator", cwd=project, code=2)
        self.cli("nosuchcommand", code=2)
        self.replace_manifest(project, "x86_64-linux", "aarch64-linux")
        self.cli("build", cwd=project, code=2)

    def test_leading_dash_path_with_separator(self):
        self.cli("new", "--", "-literal")
        self.assertTrue((self.work / "-literal/asm.toml").is_file())

    def test_registry_commands_fail_honestly(self):
        for command in ["search", "add", "remove", "install", "update", "lock", "publish", "login", "yank"]:
            with self.subTest(command=command):
                result = self.cli(command, "example", "--json", code=69)
                self.assertFalse(json.loads(result.stderr)["ok"])

    def test_no_shell_or_runtime_dependency(self):
        # An empty PATH must not affect fixed-path tool execution or native CLI.
        project = self.project()
        env = dict(os.environ, PATH="")
        self.assertEqual(self.cli("run", cwd=project, env=env).stdout, "Hello from asm!\n")
        header = subprocess.run(["readelf", "-l", ASM], capture_output=True, text=True, check=True)
        self.assertNotIn("INTERP", header.stdout)
        self.assertNotIn("RWE", header.stdout)


if __name__ == "__main__":
    unittest.main()
