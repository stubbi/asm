"""Source archive checks for projects with explicit target implementations.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import importlib.util
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("target_registry", ROOT / "tools/registry.py")
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)
sys.path.insert(0, str(ROOT / "tools"))
import release

PACKAGE = '[package]\nname = "hello"\nversion = "0.1.0"\n'
TARGETS = ('[target.x86_64-linux]\nsource = "src/x86.s"\ntest = "tests/x86.s"\n'
           '[target.aarch64-linux]\nsource = "src/arm.s"\n'
           'link = "c"\nlibraries = "pq pthread"\ncheck = "abi-arm.c"\n')


def project_files(manifest=PACKAGE + TARGETS):
    return {"asm.toml": manifest.encode(), "README.md": b"Target test fixture.\n",
            "LICENSE": b"MIT fixture.\n", "src/x86.s": b".text\n",
            "src/arm.s": b".text\n", "tests/x86.s": b".text\n",
            "abi-arm.c": b"_Static_assert(sizeof(void *) == 8, \"LP64\");\n"}


class ProjectTargetTests(unittest.TestCase):
    def validate(self, files, target="x86_64-linux"):
        registry.validate_project(files, "owner/hello", "0.1.0", target)

    def test_one_archive_can_declare_and_select_multiple_targets(self):
        for target in ("x86_64-linux", "aarch64-linux"):
            with self.subTest(target=target):
                try:
                    self.validate(project_files(), target)
                except registry.RegistryError as error:
                    self.fail(f"A declared target must be accepted: {error}")

    def test_all_four_existing_registry_target_ids_are_valid(self):
        manifest = PACKAGE + "".join(f'[target.{target}]\nsource = "src/x86.s"\n'
                                     for target in registry.TARGETS)
        for target in registry.TARGETS:
            with self.subTest(target=target):
                self.validate(project_files(manifest), target)

    def test_one_project_retains_all_seven_existing_platform_implementations(self):
        targets = ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
                   "x86_64-macos", "x86_64-windows", "aarch64-windows")
        manifest = PACKAGE + "".join(f'[target.{target}]\nsource = "src/x86.s"\n'
                                     for target in targets)
        for target in registry.TARGETS:
            with self.subTest(artifact_target=target):
                self.validate(project_files(manifest), target)
        project = tomllib.loads(manifest)
        self.assertEqual(set(registry.project_builds(project)), set(targets))

    def test_selector_returns_requested_recipe_and_retains_legacy(self):
        if not hasattr(registry, "project_build"):
            self.fail("The release compiler needs a shared target selector")
        project = tomllib.loads(PACKAGE + TARGETS)
        self.assertEqual(registry.project_build(project, "aarch64-linux")["source"], "src/arm.s")
        legacy = tomllib.loads(PACKAGE + '[build]\nsource = "src/x86.s"\ntarget = "x86_64-linux"\n')
        self.assertEqual(registry.project_build(legacy, "x86_64-linux"), legacy["build"])

    def test_legacy_build_accepts_an_explicit_test_source(self):
        manifest = PACKAGE + ('[build]\nsource = "src/x86.s"\ntarget = "x86_64-linux"\n'
                              'test = "tests/x86.s"\n')
        self.validate(project_files(manifest))
        files = project_files(manifest)
        del files["tests/x86.s"]
        with self.assertRaises(registry.RegistryError):
            self.validate(files)

    def test_missing_or_unknown_selected_target_is_rejected(self):
        for target in ("riscv64-linux", "x86_64-windows", ""):
            with self.subTest(target=target), self.assertRaises(registry.RegistryError):
                self.validate(project_files(), target)

    def test_every_explicit_source_test_and_checker_must_be_archived(self):
        for removed in ("src/x86.s", "src/arm.s", "tests/x86.s", "abi-arm.c"):
            files = project_files()
            del files[removed]
            with self.subTest(removed=removed), self.assertRaises(registry.RegistryError):
                self.validate(files)

    def test_absent_default_test_is_not_required_in_an_archive(self):
        self.validate(project_files(PACKAGE + '[target.x86_64-linux]\nsource = "src/x86.s"\n'))

    def test_inactive_target_fields_are_validated(self):
        prefixes = PACKAGE + '[target.x86_64-linux]\nsource = "src/x86.s"\n[target.aarch64-linux]\n'
        candidates = [
            'source = "../arm.s"', 'source = "src/arm.c"', 'source = 3',
            'source = "src/arm.s"\ntest = "../test.s"',
            'source = "src/arm.s"\ntest = "tests/arm.c"',
            'source = "src/arm.s"\ntest = ""',
            'source = "src/arm.s"\ntarget = "aarch64-linux"',
            'source = "src/arm.s"\nunknown = "value"',
            'source = "src/arm.s"\nlibraries = "pq"',
            'source = "src/arm.s"\nlink = "c"\nlibraries = "-lpq"',
            'source = "src/arm.s"\nlink = "c"\ncheck = "abi-arm.s"',
            'source = "src/arm.s"\nlink = "c"\ncheck = "../abi-arm.c"',
            'link = "c"',
        ]
        for fields in candidates:
            with self.subTest(fields=fields), self.assertRaises(registry.RegistryError):
                self.validate(project_files(prefixes + fields + "\n"))

    def test_response_file_inputs_are_rejected_in_active_and_inactive_recipes(self):
        for target in ("x86_64-linux", "aarch64-linux"):
            for field in ("source", "test", "check"):
                suffix = ".c" if field == "check" else ".s"
                for prefix in ("@input", "dir/@input"):
                    path = prefix + suffix
                    declarations = {
                        "source": f'source = "{path}"\n',
                        "test": f'source = "src/x86.s"\ntest = "{path}"\n',
                        "check": f'source = "src/x86.s"\nlink = "c"\ncheck = "{path}"\n',
                    }
                    manifest = PACKAGE + f'[target.{target}]\n' + declarations[field]
                    if target != "x86_64-linux":
                        manifest += '[target.x86_64-linux]\nsource = "src/x86.s"\n'
                    files = project_files(manifest)
                    files[path] = b"Untrusted response-file input.\n"
                    with self.subTest(target=target, field=field, path=path), \
                         self.assertRaisesRegex(registry.RegistryError, "path has invalid characters"):
                        self.validate(files)

    def test_response_file_inputs_are_rejected_in_legacy_build_recipes(self):
        for field in ("source", "test", "check"):
            suffix = ".c" if field == "check" else ".s"
            for prefix in ("@input", "dir/@input"):
                path = prefix + suffix
                declarations = {
                    "source": f'source = "{path}"\n',
                    "test": f'source = "src/x86.s"\ntest = "{path}"\n',
                    "check": f'source = "src/x86.s"\nlink = "c"\ncheck = "{path}"\n',
                }
                manifest = PACKAGE + '[build]\ntarget = "x86_64-linux"\n' + declarations[field]
                files = project_files(manifest)
                files[path] = b"Untrusted response-file input.\n"
                with self.subTest(field=field, path=path), \
                     self.assertRaisesRegex(registry.RegistryError, "path has invalid characters"):
                    self.validate(files)

    def test_ambiguous_or_unknown_declarations_are_rejected(self):
        candidates = [
            PACKAGE + TARGETS + '[build]\nsource = "src/x86.s"\ntarget = "x86_64-linux"\n',
            PACKAGE + '[target.x86_64-windows]\nsource = "src/x86.s"\n',
            PACKAGE + '[target]\n',
            PACKAGE + '[target.x86_64-linux]\nsource = "src/x86.s"\n' * 2,
            PACKAGE + '[target.x86_64-linux]\nsource = "src/x86.s"\nsource = "src/x86.s"\n',
        ]
        for manifest in candidates:
            with self.subTest(manifest=manifest), self.assertRaises(registry.RegistryError):
                self.validate(project_files(manifest))

    def test_native_manifest_byte_limit_applies_before_parsing(self):
        manifest = PACKAGE + TARGETS
        maximum = manifest + "#" + "x" * (8190 - len(manifest) - 1)
        self.validate(project_files(maximum))
        with self.assertRaises(registry.RegistryError):
            self.validate(project_files(maximum + "x"))

    def test_release_compiles_two_targets_in_one_project_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary)
            project = snapshot / "examples/hello"
            project.mkdir(parents=True)
            (project / "asm.toml").write_text(PACKAGE + TARGETS)
            calls = []

            def command(arguments, cwd, env, *limits):
                calls.append((arguments, cwd))
                return b"Hello from asm!\n"

            with patch.object(release, "command", side_effect=command), \
                 patch.object(release, "read_binary", return_value=b"executable"), \
                 patch.object(release, "target_runner", return_value=None):
                for target in ("x86_64-linux", "aarch64-linux"):
                    try:
                        release.compile_hello(snapshot, target, {})
                    except (FileNotFoundError, FileExistsError) as error:
                        self.fail(f"Release targets must share one project directory: {error}")
            self.assertEqual(calls[0][0][-1], "src/x86.s")
            self.assertEqual(calls[3][0][-1], "src/arm.s")
            self.assertTrue((project / "build/x86_64-linux").is_dir())
            self.assertTrue((project / "build/aarch64-linux").is_dir())
            self.assertNotEqual(calls[0][0][-2], calls[3][0][-2])


if __name__ == "__main__":
    unittest.main()
