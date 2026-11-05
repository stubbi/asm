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
