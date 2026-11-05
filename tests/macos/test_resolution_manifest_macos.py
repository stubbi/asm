"""Check source-bound resolution metadata through the native Mac CLI."""
from pathlib import Path
import ctypes
import importlib.util
import hashlib
import platform
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ASM = ROOT / "build/asm"


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64", "requires native Apple Silicon")
class NativeResolutionManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / "build")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        result = subprocess.run([str(ASM), "new", "project"], cwd=self.work, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.project = self.work / "project"
        self.manifest = self.project / "asm.toml"
        self.original = self.manifest.read_bytes()

    def command(self, *arguments):
        return subprocess.run([str(ASM), *arguments], cwd=self.project, capture_output=True, text=True, timeout=15)

    def test_versioned_feature_manifest_builds_and_runs(self):
        self.manifest.write_bytes(self.original + b'[resolution]\nschema = "1"\n[features]\ndefault = ["fast"]\nfast = []\n')
        index = self.project / "index.tsv"
        index.write_text("# asm-registry-v1\n")
        result = self.command("resolve", "--index", str(index))
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        result = self.command("run")
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(result.stdout, "Hello from asm!\n")

    def test_legacy_local_version_keeps_its_existing_numeric_contract(self):
        for version in (b"2147483648.1.0", b"1" * 59 + b".0.0"):
            self.manifest.write_bytes(self.original.replace(b'"0.1.0"', b'"' + version + b'"'))
            with self.subTest(version=version):
                result = self.command("build")
                self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))

    def test_overlong_legacy_version_preserves_the_existing_output(self):
        self.assertEqual(self.command("build").returncode, 0)
        previous = (self.project / "build/app").read_bytes()
        for digits in (60, 62):
            candidate = self.original.replace(b'"0.1.0"', b'"' + b"1" * digits + b'.0.0"')
            self.manifest.write_bytes(candidate)
            with self.subTest(version_bytes=digits + 4):
                result = self.command("build")
                self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                self.assertEqual(result.stdout, "")
                self.assertIn("asm.toml", result.stderr)
                self.assertEqual(self.manifest.read_bytes(), candidate)
                self.assertEqual((self.project / "build/app").read_bytes(), previous)

    def test_invalid_metadata_preserves_existing_build_and_manifest(self):
        self.assertEqual(self.command("build").returncode, 0)
        previous = (self.project / "build/app").read_bytes()
        for metadata in (b'[resolution]\nschema = "2"\n', b'[features]\nfast = []\n',
                         b'[resolution]\nschema = "1"\n[features]\nfast = ["missing"]\n',
                         b'[resolution]\nschema = "1"\n[features]\nfast = ["fast"]\n',
                         b'[resolution]\nschema = "1"\n[features]\nfast\n= []\n'):
            candidate = self.original + metadata
            self.manifest.write_bytes(candidate)
            with self.subTest(metadata=metadata):
                result = self.command("build")
                self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                self.assertEqual(result.stdout, "")
                self.assertIn("asm.toml", result.stderr)
                self.assertEqual(self.manifest.read_bytes(), candidate)
                self.assertEqual((self.project / "build/app").read_bytes(), previous)


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64", "requires native Apple Silicon")
class NativeResolutionRangeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(dir=ROOT / "build")
        cls.addClassCleanup(cls.temporary.cleanup)
        work = Path(cls.temporary.name)
        spec = importlib.util.spec_from_file_location("resolution_macos", ROOT / "tools/macos.py")
        macos = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(macos)
        source = macos.prepare(ROOT / "cli/aarch64/asm.s") + '''
.text
.global _asm_test_range
_asm_test_range:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl rm_range_matches
    mov x0, x9
    ldp x29, x30, [sp], #16
    ret
.global _asm_test_manifest
_asm_test_manifest:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl rm_parse_manifest
    mov x0, x9
    ldp x29, x30, [sp], #16
    ret
.global _asm_test_root_snapshot
_asm_test_root_snapshot:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl read_manifest
    blr x19
    bl res_hash_root
    ARM_ADDR x0, res_root_hash
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
'''
        assembly = work / "range.s"
        assembly.write_text(source)
        library = work / "range.dylib"
        subprocess.run(["/usr/bin/clang", "-arch", "arm64", "-dynamiclib", "-o", str(library), str(assembly)],
                       capture_output=True, text=True, timeout=30, check=True)
        cls.library = ctypes.CDLL(str(library))
        cls.library_path = library
        cls.range_matches = cls.library.asm_test_range
        cls.range_matches.argtypes = (ctypes.c_char_p, ctypes.c_char_p)
        cls.range_matches.restype = ctypes.c_long
        cls.parse_manifest = cls.library.asm_test_manifest
        cls.parse_manifest.argtypes = (ctypes.c_void_p, ctypes.c_void_p)
        cls.parse_manifest.restype = ctypes.c_long

    def test_root_hash_binds_the_parsed_bytes_after_a_manifest_replacement(self):
        original = ('[package]\nname = "hello"\nversion = "0.1.0"\n'
                    '[build]\nsource = "src/main.s"\ntarget = "aarch64-macos"\n').encode()
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as directory:
            manifest = Path(directory) / "asm.toml"
            manifest.write_bytes(original)
            script = '''
import ctypes
from pathlib import Path
import sys
library = ctypes.CDLL(sys.argv[1])
callback_type = ctypes.CFUNCTYPE(None)
def replace_manifest():
    path = Path("asm.toml")
    path.write_bytes(path.read_bytes().replace(b'"0.1.0"', b'"0.2.0"'))
callback = callback_type(replace_manifest)
library.asm_test_root_snapshot.argtypes = (callback_type,)
library.asm_test_root_snapshot.restype = ctypes.c_char_p
print(library.asm_test_root_snapshot(callback).decode())
'''
            result = subprocess.run([sys.executable, "-c", script, str(self.library_path)], cwd=directory,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
            self.assertEqual(result.stdout.strip(), hashlib.sha256(original).hexdigest())
            self.assertIn(b'"0.2.0"', manifest.read_bytes())

    def parse(self, metadata):
        manifest = ('[package]\nname = "hello"\nversion = "0.1.0"\n'
                    '[build]\nsource = "src/main.s"\ntarget = "aarch64-macos"\n' + metadata).encode()
        source = ctypes.create_string_buffer(manifest)
        result = ctypes.create_string_buffer(73816)
        return self.parse_manifest(source, result)

    def test_native_parser_accepts_inline_dependencies_and_valid_feature_edges(self):
        self.assertEqual(self.parse('''[resolution]
schema = "1"
[dependencies]
"stubbi/core" = ">=1.0.0, <2.0.0"
"stubbi/extra" = { version = "~0.1.0", optional = true, default-features = false, features = ["simd"] }
[features]
default = ["fast",]
fast = ["dep:stubbi/extra", "stubbi/core/fast"]
'''), 0)
        self.assertEqual(self.parse('[resolution]\nschema = "1"\n[dependencies]\n'
                                    + ''.join(f'"stubbi/p{i}" = "*"\n' for i in range(64))), 0)

    def test_native_parser_rejects_invalid_bounds_and_references(self):
        schema = '[resolution]\nschema = "1"\n'
        candidates = ('[dependencies]\n"stubbi/core" = "1.0.0"\n',
                      schema + '[dependencies]\n"stubbi/core" = { version = "1.0.0", extra = true }\n',
                      schema + '[dependencies]\n"stubbi/core" = { version = "1.0.0", optional = "true" }\n',
                      schema + '[dependencies]\n"stubbi/core" = { version = "1.0.0", features = ["simd", "simd"] }\n',
                      schema + '[features]\nfast = ["dep:stubbi/missing"]\n',
                      schema + '[dependencies]\n"stubbi/core" = "1.0.0"\n[features]\nfast = ["dep:stubbi/core"]\n',
                      schema + '[features]\nfirst = ["second"]\nsecond = ["first"]\n',
                      schema + '[features]\nfast = ["stubbi/missing/simd"]\n',
                      schema + '[features]\nfast = [\n]\n', schema + '# invalid comment: é\n',
                      schema + '[dependencies]\n' + ''.join(f'"stubbi/p{i}" = "*"\n' for i in range(65)),
                      schema + '[features]\n' + ''.join(f'f{i} = []\n' for i in range(65)))
        for metadata in candidates:
            with self.subTest(metadata=metadata[:100]):
                self.assertEqual(self.parse(metadata), 1)

    def test_range_boundaries_and_zero_major_caret_rules(self):
        cases = (("1.2.3", "1.2.3", 1), ("1.2.4", "1.2.3", 0), ("2147483647.0.0", "*", 1),
                 ("1.2.2", "^1.2.3", 0), ("1.2.3", "^1.2.3", 1), ("1.9.9", "^1.2.3", 1),
                 ("2.0.0", "^1.2.3", 0), ("0.2.4", "^0.2.3", 1), ("0.3.0", "^0.2.3", 0),
                 ("0.0.3", "^0.0.3", 1), ("0.0.4", "^0.0.3", 0), ("1.2.9", "~1.2.3", 1),
                 ("1.3.0", "~1.2.3", 0), ("1.2.3", ">=1.2.3, <2.0.0", 1),
                 ("2.0.0", ">=1.2.3, <2.0.0", 0), ("1.2.3", ">1.2.3", 0),
                 ("1.2.3", "<= 1.2.3", 1), ("1.2.3", "=1.2.3", 1),
                 ("2147483647.0.1", "^2147483647.0.0", 1),
                 ("1.2147483647.1", "~1.2147483647.0", 1),
                 ("1.2.3", ">=2.0.0, <1.0.0", 0))
        for version, requirement, expected in cases:
            with self.subTest(version=version, requirement=requirement):
                self.assertEqual(self.range_matches(version.encode(), requirement.encode()), expected)

    def test_malformed_ranges_are_distinct_from_nonmatches(self):
        for requirement in ("", "1.2", "01.2.3", "1.2.2147483648", "^ 1.2.3", "1.2.3 || 2.0.0",
                            "^1.2.3, <2.0.0", "1.2.3, =1.2.3", ">=1.2.3,", " >=1.2.3", ">=1.2.3 ",
                            ",".join([">=1.0.0"] * 9), ">" + "1" * 128):
            with self.subTest(requirement=requirement):
                self.assertEqual(self.range_matches(b"1.2.3", requirement.encode()), -1)
