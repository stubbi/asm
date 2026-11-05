"""Selected build recipes must retain strict dependency metadata validation.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import json
import unittest

from host import OTHER_TARGET, TARGET, exit_source
import test_resolver_cli as resolver_fixture


class ResolutionManifestCliTests(unittest.TestCase):
    setUp = resolver_fixture.ResolverCliTests.setUp
    cli = resolver_fixture.ResolverCliTests.cli
    package = resolver_fixture.ResolverCliTests.package
    resolve = resolver_fixture.ResolverCliTests.resolve
    selections = resolver_fixture.ResolverCliTests.selections
    consumer = resolver_fixture.ResolverCliTests.consumer

    def named(self, *, dependencies=False, source="src/main.s", extra=""):
        text = '[package]\nname = "root"\nversion = "1.0.0"\n'
        text += f'\n[target.{OTHER_TARGET}]\nsource = "src/unused.s"\n'
        text += f'\n[target.{TARGET}]\nsource = "{source}"\ntest = "tests/selected.s"\n'
        text += extra
        if dependencies:
            text += '\n[resolution]\nschema = "1"\n[dependencies]\n"stubbi/alpha" = "^1.0.0"\n'
        (self.project / "asm.toml").write_text(text)
        (self.project / "tests/selected.s").write_text(exit_source(0))
        (self.project / "tests/main.s").write_text(exit_source(21))
        return text

    def test_named_recipe_selects_its_explicit_test(self):
        self.named()
        result = self.cli("test", "--json")
        self.assertEqual(json.loads(result.stdout), {"ok": True, "test": "tests/selected.s"})

    def test_named_graph_root_and_named_dependency_resolve_and_run(self):
        targets = ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
                   "x86_64-macos", "x86_64-windows", "aarch64-windows")
        leaf = '[package]\nname = "alpha"\nversion = "1.0.0"\n'
        leaf += ''.join(f'\n[target.{target}]\nsource = "src/alpha.s"\n' for target in targets)
        self.package("alpha", manifest_text=leaf)
        self.named(dependencies=True)
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0"})
        self.consumer("alpha")
        self.cli("run", "--locked")
        self.cli("test", "--locked")

    def test_inactive_invalid_recipe_preserves_existing_output(self):
        self.cli("build")
        output = self.project / "build/app"
        before = output.read_bytes()
        text = self.named()
        for field in ('source = "../outside.s"', 'test = "@response.s"',
                      'libraries = "pthread"', 'link = "shell"', 'check = "src/@response.c"'):
            with self.subTest(field=field):
                inactive = f'\n[target.{OTHER_TARGET}]\nsource = "src/unused.s"\n'
                replacement = inactive + field + '\n'
                if field.startswith("source"):
                    replacement = f'\n[target.{OTHER_TARGET}]\n{field}\n'
                (self.project / "asm.toml").write_text(text.replace(inactive, replacement))
                self.cli("build", code=1)
                self.assertEqual(output.read_bytes(), before)

    def test_missing_selected_recipe_is_target_error_after_full_validation(self):
        self.cli("build")
        output = self.project / "build/app"
        before = output.read_bytes()
        text = ('[package]\nname = "root"\nversion = "1.0.0"\n'
                f'[target.{OTHER_TARGET}]\nsource = "src/unused.s"\n')
        (self.project / "asm.toml").write_text(text)
        self.cli("build", code=2)
        self.assertEqual(output.read_bytes(), before)
        (self.project / "asm.toml").write_text(text + 'test = "../outside.s"\n')
        self.cli("build", code=1)
        self.assertEqual(output.read_bytes(), before)

    def test_named_manifest_bound_is_8190_bytes(self):
        text = self.named()
        for size in (8190, 8191):
            with self.subTest(size=size):
                content = text + "#" + "x" * (size - len(text.encode()) - 2) + "\n"
                self.assertEqual(len(content.encode()), size)
                (self.project / "asm.toml").write_text(content)
                self.cli("build", code=0 if size == 8190 else 1)

    def test_core_unicode_path_remains_valid_without_resolution_extension(self):
        source = self.project / "src/世界.s"
        source.write_bytes((self.project / "src/main.s").read_bytes())
        text = self.named(source="src/世界.s")
        self.cli("build")
        output = self.project / "build/app"
        before = output.read_bytes()
        # Dependency metadata retains its stricter ASCII schema.
        (self.project / "asm.toml").write_text(text + '\n[resolution]\nschema = "1"\n')
        self.cli("build", code=1)
        self.assertEqual(output.read_bytes(), before)

    def test_legacy_dependency_archive_retains_16384_byte_manifest_limit(self):
        text = resolver_fixture.manifest("alpha").split("[resolution]", 1)[0]
        leaf = text + "#" + "x" * (16384 - len(text.encode()) - 2) + "\n"
        self.assertEqual(len(leaf.encode()), 16384)
        self.package("alpha", manifest_text=leaf)
        resolver_fixture.ResolverCliTests.root_manifest(self, {"stubbi/alpha": "1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0"})
        self.consumer("alpha")
        self.cli("run", "--locked")


if __name__ == "__main__":
    unittest.main()
