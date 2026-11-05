"""Native publication preparation tests. No network requests or uploads."""

import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest

from host import IS_MACOS, TARGET


ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"
SPEC = importlib.util.spec_from_file_location("publication_registry", ROOT / "tools/registry.py")
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)
CLI_ARTIFACT_TARGETS = ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos")


def source_files(name="math", version="0.1.0", target="x86_64-linux"):
    manifest = (f'[package]\nname = "{name}"\nversion = "{version}"\n'
                f'[build]\nsource = "src/math.s"\ntarget = "{target}"\n')
    return {"asm.toml": (manifest.encode(), 0o644), "README.md": (b"A test assembly library.\n", 0o644),
            "LICENSE": (b"MIT test fixture.\n", 0o644), "src/math.s": (b"add rax, rdi\nret\n", 0o644)}


def elf(machine=62):
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", header, 16, 2, machine, 1)
    struct.pack_into("<Q", header, 32, 64)
    struct.pack_into("<HHH", header, 52, 64, 56, 1)
    return bytes(header) + struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 4096)


class NativePublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="publish-test-", dir=ROOT / "build")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.artifact = self.work / "math-0.1.0.tar.gz"
        self.artifact.write_bytes(registry.make_archive(source_files()))
        self.output = self.work / "submission.json"
        self.url = "https://github.com/owner/math/releases/download/v0.1.0/math-0.1.0.tar.gz"

    def arguments(self, overrides=None, artifacts=None):
        fields = {"name": "owner/math", "version": "0.1.0", "summary": "A small assembly library.",
                  "license": "MIT", "repository": "https://github.com/owner/math",
                  "commit": "a" * 40, "source-path": ".", "output": str(self.output)}
        fields.update(overrides or {})
        result = ["publish"]
        for key, value in fields.items():
            result.extend(["--" + key, str(value)])
        for artifact in artifacts or [("x86_64-linux", "source", self.artifact, self.url)]:
            result.extend(["--artifact", *map(str, artifact)])
        return result

    def cli(self, args=None, code=0, env=None):
        result = subprocess.run([str(ASM), *(args or self.arguments())], cwd=self.work,
                                capture_output=True, text=True, timeout=10, env=env)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        self.assertEqual(list(self.work.glob(".asm-registry-*")), [], "temporary workspace was not removed")
        return result

    def test_macos_executable_publication_requires_the_declared_format(self):
        candidate = self.work / "candidate"
        url = "https://github.com/owner/math/releases/download/v0.1.0/native"
        candidate.write_bytes(elf(183))
        arguments = self.arguments(artifacts=[(TARGET if IS_MACOS else "aarch64-macos", "executable", candidate, url)])
        self.cli(arguments, code=1)
        self.assertFalse(self.output.exists())
        if IS_MACOS:
            candidate.write_bytes(ASM.read_bytes())
            self.cli(arguments)
            record = json.loads(self.output.read_bytes())
            self.assertEqual(record["artifacts"][0]["target"], TARGET)
            self.assertEqual(record["artifacts"][0]["sha256"], hashlib.sha256(candidate.read_bytes()).hexdigest())
            if TARGET in registry.TARGETS:
                record = registry.validate_manifest(record)
                registry.validate_artifact(candidate.read_bytes(), record, record["artifacts"][0])

    def test_prepares_real_record_with_actual_digest_and_no_upload_claim(self):
        result = self.cli(self.arguments() + ["--json"])
        report = json.loads(result.stdout)
        self.assertEqual(report, {"prepared": True, "uploaded": False, "output": str(self.output)})
        record = registry.validate_manifest(json.loads(self.output.read_bytes()))
        self.assertEqual(record["name"], "owner/math")
        self.assertEqual(record["source"]["commit"], "a" * 40)
        artifact = record["artifacts"][0]
        self.assertEqual(artifact["sha256"], hashlib.sha256(self.artifact.read_bytes()).hexdigest())
        self.assertEqual(artifact["bytes"], self.artifact.stat().st_size)
        registry.validate_artifact(self.artifact.read_bytes(), record, artifact)

    def test_summary_escapes_quotes_and_backslashes_exactly(self):
        summary = 'Use "add" with C:\\source.'
        self.cli(self.arguments({"summary": summary}))
        self.assertEqual(json.loads(self.output.read_bytes())["summary"], summary)

    def test_accepts_each_agpl_identifier_without_relabeling_it(self):
        for license_id in ("AGPL-3.0-only", "AGPL-3.0-or-later"):
            with self.subTest(license=license_id):
                self.cli(self.arguments({"license": license_id}))
                record = registry.validate_manifest(json.loads(self.output.read_bytes()))
                self.assertEqual(record["license"], license_id)
                self.output.unlink()

    def test_six_target_kind_artifacts_have_distinct_validated_records(self):
        artifacts = []
        for target, machine in registry.TARGETS.items():
            if not target.endswith("-linux"):
                continue
            for kind in ("source", "executable"):
                filename = target + (".tar.gz" if kind == "source" else ".bin")
                path = self.work / filename
                path.write_bytes(registry.make_archive(source_files(target=target)) if kind == "source" else elf(machine))
                url = "https://github.com/owner/math/releases/download/v0.1.0/" + filename
                artifacts.append((target, kind, path, url))
        self.cli(self.arguments(artifacts=artifacts))
        record = registry.validate_manifest(json.loads(self.output.read_bytes()))
        self.assertEqual(len(record["artifacts"]), 6)
        for expected, actual in zip(artifacts, record["artifacts"]):
            registry.validate_artifact(expected[2].read_bytes(), record, actual)

    def target_files(self, targets=None):
        files = source_files()
        manifest = '[package]\nname = "math"\nversion = "0.1.0"\n'
        for target in (targets or registry.TARGETS):
            manifest += (f'[target.{target}]\nsource = "src/{target}.s"\n'
                         f'test = "tests/{target}.s"\n')
            files[f"src/{target}.s"] = (b".text\n", 0o644)
            files[f"tests/{target}.s"] = (b".text\n", 0o644)
        files["asm.toml"] = (manifest.encode(), 0o644)
        return files

    def test_seven_project_targets_validate_all_inputs_without_expanding_artifact_targets(self):
        targets = ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
                   "x86_64-macos", "x86_64-windows", "aarch64-windows")
        files = self.target_files(targets)
        self.artifact.write_bytes(registry.make_archive(files))
        for target in CLI_ARTIFACT_TARGETS:
            with self.subTest(artifact_target=target):
                self.cli(self.arguments(artifacts=[(target, "source", self.artifact, self.url)]))
                record = json.loads(self.output.read_bytes())
                self.assertEqual(record["artifacts"][0]["target"], target)
                registry.validate_artifact(self.artifact.read_bytes(), record, record["artifacts"][0])
                self.output.unlink()
        for target in ("x86_64-macos", "x86_64-windows", "aarch64-windows"):
            with self.subTest(inactive_target=target):
                incomplete = {path: value for path, value in files.items() if path != f"src/{target}.s"}
                self.artifact.write_bytes(registry.make_archive(incomplete))
                self.cli(code=1)
                self.assertFalse(self.output.exists())
                duplicate = {**files, "asm.toml": (files["asm.toml"][0] +
                             f'[target.{target}]\nsource = "src/{target}.s"\n'.encode(), 0o644)}
                self.artifact.write_bytes(registry.make_archive(duplicate))
                self.cli(code=1)
                self.assertFalse(self.output.exists())
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(self.arguments(artifacts=[(target, "source", self.artifact, self.url)]), code=2)
                self.assertFalse(self.output.exists())

    def test_multi_target_archive_matches_each_declared_artifact_target(self):
        self.artifact.write_bytes(registry.make_archive(self.target_files()))
        for target in CLI_ARTIFACT_TARGETS:
            with self.subTest(target=target):
                self.cli(self.arguments(artifacts=[(target, "source", self.artifact, self.url)]))
                record = json.loads(self.output.read_bytes())
                self.assertEqual(record["artifacts"][0]["target"], target)
                self.output.unlink()
        # Catalog format recognition does not expand native publication.
        for target in sorted(set(registry.TARGETS) - set(CLI_ARTIFACT_TARGETS)):
            with self.subTest(catalog_only_target=target):
                self.cli(self.arguments(artifacts=[(target, "source", self.artifact, self.url)]), code=2)
                self.assertFalse(self.output.exists())

    def test_multi_target_archive_preserves_target_specific_native_library_fields(self):
        files = self.target_files()
        manifest = files["asm.toml"][0].replace(
            b'source = "src/aarch64-linux.s"\n',
            b'source = "src/aarch64-linux.s"\nlink = "c"\nlibraries = "pq pthread"\ncheck = "abi-arm.c"\n')
        files["asm.toml"] = (manifest, 0o644)
        files["abi-arm.c"] = (b'_Static_assert(sizeof(void *) == 8, "LP64");\n', 0o644)
        self.artifact.write_bytes(registry.make_archive(files))
        self.cli()
        record = json.loads(self.output.read_bytes())
        registry.validate_artifact(self.artifact.read_bytes(), record, record["artifacts"][0])

    def test_legacy_source_manifest_accepts_an_explicit_test_file(self):
        files = source_files()
        files["asm.toml"] = (files["asm.toml"][0] + b'test = "tests/math.s"\n', 0o644)
        files["tests/math.s"] = (b".text\n", 0o644)
        self.artifact.write_bytes(registry.make_archive(files))
        self.cli()
        self.output.unlink()
        del files["tests/math.s"]
        self.artifact.write_bytes(registry.make_archive(files))
        self.cli(code=1)
        self.assertFalse(self.output.exists())

    def test_multi_target_archive_checks_inactive_inputs_and_rejects_ambiguous_tables(self):
        base = self.target_files()
        manifest = base["asm.toml"][0]
        changes = [
            manifest.replace(b'src/aarch64-linux.s', b'../outside.s'),
            manifest.replace(b'tests/aarch64-linux.s', b'missing.s'),
            manifest.replace(b'tests/aarch64-linux.s', b'tests/wrong.c'),
            manifest.replace(b'[target.aarch64-linux]', b'[target.unknown-linux]'),
            manifest + b'[target.x86_64-linux]\nsource = "src/math.s"\n',
            manifest + b'[build]\nsource = "src/math.s"\ntarget = "x86_64-linux"\n',
            manifest + b'target = "aarch64-macos"\n',
            manifest + b'source = "src/math.s"\n',
            manifest + b'link = "c"\ncheck = "missing.c"\n',
            manifest + b'libraries = "pq"\n',
        ]
        for candidate in changes:
            with self.subTest(manifest=candidate):
                files = {**base, "asm.toml": (candidate, 0o644)}
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=1)
                self.assertFalse(self.output.exists())
        for missing in ("src/aarch64-linux.s", "tests/aarch64-linux.s"):
            with self.subTest(missing=missing):
                files = {path: value for path, value in base.items() if path != missing}
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=1)
                self.assertFalse(self.output.exists())

    def test_multi_target_archive_can_publish_without_a_host_entry(self):
        files = source_files()
        files["asm.toml"] = (b'[package]\nname = "math"\nversion = "0.1.0"\n'
                             b'[target.riscv64-linux]\nsource = "src/math.s"\n', 0o644)
        self.artifact.write_bytes(registry.make_archive(files))
        self.cli(self.arguments(artifacts=[("riscv64-linux", "source", self.artifact, self.url)]))
        self.output.unlink()
        self.cli(code=1)
        self.assertFalse(self.output.exists())

    def test_legacy_source_manifest_preserves_the_archive_byte_bound(self):
        files = source_files()
        manifest = files["asm.toml"][0]
        for size in (16384, 16385):
            with self.subTest(size=size):
                files["asm.toml"] = (manifest + b"#" + b"x" * (size - len(manifest) - 1), 0o644)
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=0 if size == 16384 else 1)
                if size == 16384:
                    self.assertTrue(self.output.is_file())
                    self.output.unlink()
                else:
                    self.assertFalse(self.output.exists())

    def test_named_target_source_manifest_uses_the_native_build_byte_bound(self):
        files = self.target_files()
        manifest = files["asm.toml"][0]
        for size in (8190, 8191):
            with self.subTest(size=size):
                files["asm.toml"] = (manifest + b"#" + b"x" * (size - len(manifest) - 1), 0o644)
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=0 if size == 8190 else 1)
                if size == 8190:
                    self.assertTrue(self.output.is_file())
                    self.output.unlink()
                else:
                    self.assertFalse(self.output.exists())

    def test_name_version_and_target_must_match_source_manifest(self):
        for kwargs in ({"name": "wrong"}, {"version": "0.2.0"}, {"target": "aarch64-linux"}):
            with self.subTest(kwargs=kwargs):
                self.artifact.write_bytes(registry.make_archive(source_files(**kwargs)))
                self.cli(code=1)
                self.assertFalse(self.output.exists())

    def test_source_requires_manifest_license_readme_and_declared_file(self):
        for removed in ("asm.toml", "README.md", "LICENSE", "src/math.s"):
            with self.subTest(removed=removed):
                files = source_files()
                del files[removed]
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=1)
                self.assertFalse(self.output.exists())

    def test_native_library_manifest_and_repeated_artifacts_clear_optional_fields(self):
        files = source_files()
        fields = b'link = "c"\nlibraries = "microhttpd pq pthread"\ncheck = "abi-check.c"\n'
        files["asm.toml"] = (files["asm.toml"][0] + fields, 0o644)
        files["abi-check.c"] = (b'_Static_assert(sizeof(void *) == 8, "LP64");\n', 0o644)
        self.artifact.write_bytes(registry.make_archive(files))
        standalone = self.work / "standalone.tar.gz"
        standalone.write_bytes(registry.make_archive(source_files(target="aarch64-linux")))
        artifacts = [("x86_64-linux", "source", self.artifact, self.url),
                     ("aarch64-linux", "source", standalone, self.url.replace("math-0.1.0", "standalone"))]
        for ordered in (artifacts, list(reversed(artifacts))):
            with self.subTest(targets=[item[0] for item in ordered]):
                self.cli(self.arguments(artifacts=ordered))
                record = registry.validate_manifest(json.loads(self.output.read_bytes()))
                for original, artifact in zip(ordered, record["artifacts"]):
                    registry.validate_artifact(original[2].read_bytes(), record, artifact)
                self.output.unlink()

    def test_native_library_fields_reject_invalid_values_and_missing_checker(self):
        invalid = ['link = ""', 'link = "static"', 'libraries = "pq"', 'check = "abi-check.c"',
                   'link = "c"\nlibraries = ""', 'link = "c"\ncheck = ""',
                   'link = "c"\nlibraries = "pq  pthread"', 'link = "c"\nlibraries = "-lpq"',
                   'link = "c"\nlibraries = "PQ"', 'link = "c"\nlibraries = "pq/pthread"',
                   'link = "c"\nlibraries = " pq"', 'link = "c"\nlibraries = "pq "',
                   'link = "c"\nlibraries = "a b c d e f g h i"',
                   'link = "c"\nlibraries = "' + "a" * 32 + '"',
                   'link = "c"\nlibraries = "' + "a" * 256 + '"',
                   'link = "c"\ncheck = "../abi-check.c"', 'link = "c"\ncheck = "abi-check.s"',
                   'link = "c"\nlink = "c"', 'link = "c"\nlibraries = "pq"\nlibraries = "pq"',
                   'link = "c"\ncheck = "abi-check.c"\ncheck = "abi-check.c"',
                   'link = "c"\nunknown = "pq"',
                   'link = "c"\ncheck = "abi-check.c"']
        for fields in invalid:
            with self.subTest(fields=fields):
                files = source_files()
                files["asm.toml"] = (files["asm.toml"][0] + (fields + "\n").encode(), 0o644)
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=1)
                self.assertFalse(self.output.exists())

    def test_duplicate_or_ambiguous_manifest_fields_fail(self):
        candidates = [b'[package]\nname="math"\nname="math"\nversion="0.1.0"\n[build]\nsource="src/math.s"\ntarget="x86_64-linux"\n',
                      b'[package]\nname="math"\nversion="0.1.0"\n[build]\nsource="../outside.s"\ntarget="x86_64-linux"\n',
                      b'[package]\nname="math"\nversion="0.1.0"\n[build]\nsource="src/math.s"\ntarget="x86_64-linux"\0hidden']
        for manifest in candidates:
            with self.subTest(manifest=manifest):
                files = source_files()
                files["asm.toml"] = (manifest, 0o644)
                self.artifact.write_bytes(registry.make_archive(files))
                self.cli(code=1)

    def test_credential_and_excluded_source_members_fail(self):
        # Build these directly because registry packaging correctly rejects them.
        for path in (".env", "config/.env.prod", "id_rsa", "key.pem", "key.KEY", ".git/config", "CON/file.s"):
            with self.subTest(path=path):
                output = io.BytesIO()
                with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                    for name, (data, mode) in {**source_files(), path: (b"blocked", 0o644)}.items():
                        info = tarfile.TarInfo(name)
                        info.mode = mode
                        info.size = len(data)
                        tar.addfile(info, io.BytesIO(data))
                self.artifact.write_bytes(gzip.compress(output.getvalue(), mtime=0))
                self.cli(code=1)

    def test_metadata_grammar_and_repository_constraints(self):
        invalid = [{"name": "math"}, {"name": "owner/a--b"}, {"version": "01.2.3"},
                   {"version": "1.2.2147483648"}, {"commit": "a" * 39}, {"commit": "0" * 40},
                   {"commit": "A" * 40}, {"repository": "http://github.com/owner/math"},
                   {"repository": "https://github.com/owner/math.git"},
                   {"repository": "https://github.com/owner/math/extra"},
                   {"summary": " leading"}, {"summary": "trailing "}, {"summary": "bad\nline"},
                   {"summary": "x" * 161}, {"license": "Proprietary"},
                   {"source-path": "../outside"}, {"source-path": "CON/source"}]
        for values in invalid:
            with self.subTest(values=values):
                self.cli(self.arguments(values), code=2)
                self.assertFalse(self.output.exists())

    def test_invalid_artifact_urls_and_source_extensions_fail(self):
        for url in ("http://github.com/owner/math/releases/download/v1/a.tar.gz",
                    "https://github.com/owner/math/releases/download/v1/a.tar.gz?secret=1",
                    "https://github.com/owner/math/releases/download/v1/a.tar.gz#frag",
                    "https://github.com/owner/math/releases/download/v1/a%2F.tar.gz",
                    "https://github.com/owner/math/releases/download/v1/a.bin",
                    "https://github.com/owner/math/releases/download/v1/a+.tar.gz"):
            with self.subTest(url=url):
                self.cli(self.arguments(artifacts=[("x86_64-linux", "source", self.artifact, url)]), code=2)

    def test_duplicate_artifacts_and_urls_fail(self):
        item = ("x86_64-linux", "source", self.artifact, self.url)
        self.cli(self.arguments(artifacts=[item, item]), code=2)
        self.cli(self.arguments(artifacts=[item, ("aarch64-linux", "source", self.artifact, self.url)]), code=2)
        self.cli(self.arguments(artifacts=[item] * 7), code=2)

    def test_invalid_elf_and_wrong_target_fail(self):
        path = self.work / "program.bin"
        url = "https://github.com/owner/math/releases/download/v1/program.bin"
        for data in (b"not executable", elf(machine=183), elf()[:-1]):
            with self.subTest(size=len(data)):
                path.write_bytes(data)
                self.cli(self.arguments(artifacts=[("x86_64-linux", "executable", path, url)]), code=1)
                self.assertFalse(self.output.exists())

    def test_empty_symlink_fifo_and_missing_artifact_fail_without_blocking(self):
        self.artifact.write_bytes(b"")
        self.cli(code=1)
        self.artifact.unlink()
        self.cli(code=1)
        self.artifact.symlink_to(ASM)
        self.cli(code=1)
        self.artifact.unlink()
        os.mkfifo(self.artifact)
        self.cli(code=1)

    def test_output_is_atomic_and_never_replaces_existing_file(self):
        self.output.write_bytes(b"keep original")
        self.cli(code=1)
        self.assertEqual(self.output.read_bytes(), b"keep original")
        self.output.unlink()
        self.output.symlink_to(self.artifact)
        previous = self.artifact.read_bytes()
        self.cli(code=1)
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(self.artifact.read_bytes(), previous)

    def test_paths_with_spaces_shell_text_and_hostile_gzip_environment_are_literal(self):
        moved = self.work / "input; touch NEVER-CREATED.tar.gz"
        self.artifact.rename(moved)
        self.artifact = moved
        env = os.environ.copy()
        env["GZIP"] = "--invalid-option"
        result = self.cli(env=env)
        self.assertIn("Nothing was uploaded", result.stdout)
        self.assertFalse((self.work / "NEVER-CREATED.tar.gz").exists())

    def test_help_and_missing_argument_errors_are_explicit(self):
        result = self.cli(["publish", "--help"])
        self.assertIn("pull request", result.stdout)
        self.assertIn("No artifact or metadata is uploaded", result.stdout)
        self.cli(["publish"], code=2)
        self.cli(self.arguments() + ["--name", "owner/duplicate"], code=2)
        self.cli(self.arguments() + ["--unknown"], code=2)


if __name__ == "__main__":
    unittest.main()
