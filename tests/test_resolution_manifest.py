"""Exercise dependency manifest validation through the native build command."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from host import OTHER_TARGET

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"


class ResolutionManifestTests(unittest.TestCase):
    def test_overlong_legacy_version_preserves_existing_build(self):
        with tempfile.TemporaryDirectory(prefix="resolution-version-", dir=ROOT / "build") as folder:
            project = Path(folder) / "project"
            result = subprocess.run([str(ASM), "new", str(project)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
            manifest = project / "asm.toml"
            original = manifest.read_bytes()
            result = subprocess.run([str(ASM), "build"], cwd=project, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
            previous = (project / "build/app").read_bytes()
            for digits in (60, 62):
                candidate = original.replace(b'"0.1.0"', b'"' + b"1" * digits + b'.0.0"')
                manifest.write_bytes(candidate)
                with self.subTest(version_bytes=digits + 4):
                    result = subprocess.run([str(ASM), "build"], cwd=project, capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                    self.assertEqual(result.stdout, "")
                    self.assertIn("asm.toml", result.stderr)
                    self.assertEqual(manifest.read_bytes(), candidate)
                    self.assertEqual((project / "build/app").read_bytes(), previous)

    def check_manifest(self, extension, valid):
        with tempfile.TemporaryDirectory(prefix="resolution-manifest-", dir=ROOT / "build") as folder:
            project = Path(folder)
            (project / "asm.toml").write_text(
                '[package]\nname = "manifest"\nversion = "1.0.0"\n'
                f'[build]\nsource = "src/main.s"\ntarget = "{OTHER_TARGET}"\n' + extension,
                encoding="utf-8",
            )
            result = subprocess.run([str(ASM), "build"], cwd=project, capture_output=True, text=True, timeout=15)
            # A valid manifest reaches the existing explicit host-target check.
            self.assertEqual(result.returncode, 2 if valid else 1, (extension, result.stdout, result.stderr))
            self.assertIn("unsupported" if valid else "asm.toml", result.stderr)
            self.assertFalse((project / "build").exists())
            self.assertFalse((project / "asm.lock").exists())

    def test_supported_ranges_parse_before_target_selection(self):
        for value in ["*", "1.2.3", "^1.2.3", "^0.2.3", "^0.0.3", "~1.2.3",
                      ">=1.2.3, <2.0.0", "> 0.0.0,<=2147483647.0.0", "=1.2.3"]:
            with self.subTest(value=value):
                self.check_manifest('[resolution]\nschema = "1"\n[dependencies]\n"stubbi/math" = "' + value + '"\n', True)

    def test_malformed_ranges_fail_before_target_selection(self):
        for value in ["", "1.2", "01.2.3", "^ 1.2.3", "~1.2.3,<2.0.0", "1.2.3,=1.2.3",
                      " >=1.0.0", ">=1.0.0 ", ">=1.0.0 || <2.0.0", ">=2147483648.0.0",
                      ">=1.0.0,", ">=1.0.0,1.2.3", ">=" + "1" * 129]:
            with self.subTest(value=value):
                self.check_manifest('[resolution]\nschema = "1"\n[dependencies]\n"stubbi/math" = "' + value + '"\n', False)

    def test_inline_dependencies_and_feature_references(self):
        self.check_manifest(
            '[resolution]\nschema = "1"\n[dependencies]\n'
            '"stubbi/math" = { version = "^1.2.3", optional = true, default-features = false, features = ["wide",] }\n'
            '[features]\ndefault = ["fast"]\nfast = ["dep:stubbi/math", "stubbi/math/wide"]\n', True)

    def test_duplicate_unknown_and_cyclic_features_fail(self):
        for declaration in ['fast = ["missing"]', 'fast = ["fast"]',
                            'fast = ["slow"]\nslow = ["fast"]',
                            'fast = ["same", "same"]',
                            'fast = ["dep:stubbi/missing"]',
                            'fast = ["stubbi/missing/wide"]',
                            'fast = []\nfast = []', 'fast\n= []',
                            'fast = ["escape\\n"]']:
            with self.subTest(declaration=declaration):
                self.check_manifest('[resolution]\nschema = "1"\n[features]\n' + declaration + '\n', False)

    def test_extension_requires_schema_and_ascii(self):
        for extension in ['[dependencies]\n"stubbi/math" = "1.0.0"\n',
                          '[resolution]\nschema = "2"\n',
                          '[resolution]\nschema = "1"\n# café\n',
                          '[resolution]\nschema = "1"\n[ resolution]\n',
                          '[resolution]\nschema = "1"\n[features ]\n',
                          '[resolution]\nschema\r = "1"\n',
                          '[resolution]\nschema = "1"\n# comment\rtext\n',
                          '[resolution]\nschema = "1"\n[features]\ndefault = [\r"a"]\na=[]\n']:
            with self.subTest(extension=extension):
                self.check_manifest(extension, False)


if __name__ == "__main__":
    unittest.main()
