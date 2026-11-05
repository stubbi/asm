"""Registry contract tests. No network access is required."""

import copy
import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import tarfile
import tomllib
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("asm_registry", ROOT / "tools" / "registry.py")
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)


def project_files(version="0.1.0", target="x86_64-linux"):
    manifest = f'[package]\nname = "hello"\nversion = "{version}"\n\n[build]\nsource = "src/main.s"\ntarget = "{target}"\n'
    return {"asm.toml": (manifest.encode(), 0o644),
            "README.md": (b"Registry test source.\n", 0o644),
            "LICENSE": (b"Test fixture under MIT.\n", 0o644),
            "src/main.s": (b".global _start\n_start: nop\n", 0o644)}


def release(version="0.1.0", target="x86_64-linux"):
    data = registry.make_archive(project_files(version, target))
    record = {"schema": 1, "name": "stubbi/hello", "version": version,
              "summary": "A small assembly source example.", "license": "MIT",
              "source": {"repository": "https://github.com/stubbi/asm", "commit": "a" * 40,
                         "path": "registry/examples/hello"},
              "artifacts": [{"target": target, "kind": "source", "sha256": hashlib.sha256(data).hexdigest(),
                             "bytes": len(data), "url": f"https://github.com/stubbi/asm/releases/download/packages-v{version}/hello-{version}-{target}-source.tar.gz"}],
              "yanked": False}
    return record, data


def raw_tar(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, kind, content in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = 0o644
            info.size = len(content) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = "../../outside"
            archive.addfile(info, io.BytesIO(content) if info.size else None)
    return gzip.compress(buffer.getvalue(), mtime=0)


def minimal_elf(machine=62):
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", header, 16, 2, machine, 1)
    struct.pack_into("<Q", header, 32, 64)
    struct.pack_into("<HHH", header, 52, 64, 56, 1)
    program = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 4096)
    return bytes(header) + program


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def save_record(self, root, record):
        path = root / "packages" / record["name"] / (record["version"] + ".json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(registry.json_bytes(record))
        return path

    def test_names_are_unambiguous(self):
        self.assertEqual(registry.package_name("stubbi/hello-world"), "stubbi/hello-world")
        for name in ("hello", "../hello", "Stubbi/hello", "stubbi/a--b", "stubbi/a-",
                     "stubbi/hello/world", "stubbi/é", "stubbi/" + "a" * 65):
            with self.subTest(name=name), self.assertRaises(registry.RegistryError):
                registry.package_name(name)

    def test_versions_are_exact_and_bounded(self):
        self.assertEqual(registry.version_tuple("1.20.3"), (1, 20, 3))
        for value in ("1.2", "v1.2.3", "01.2.3", "1.2.3-beta", "^1.2.3", "1.2.2147483648", "1.2.3\n"):
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                registry.version_tuple(value)

    def test_release_urls_cannot_escape_github(self):
        good = "https://github.com/stubbi/asm/releases/download/v0.1.0/asm.tar.gz"
        self.assertEqual(registry.artifact_url(good)[2], "asm.tar.gz")
        for value in (good.replace("https:", "http:"), good.replace("github.com", "github.com.evil.test"),
                      good.replace("github.com", "user@github.com"), good + "?token=1", good + "#x",
                      good.replace("v0.1.0", "%2e%2e"), good.replace("v0.1.0", ".."),
                      "file:///tmp/asm", "https://127.0.0.1/a"):
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                registry.artifact_url(value)

    def test_agpl_and_permissive_package_declarations_are_independent(self):
        record, _ = release()
        for license_id in ("MIT", "Apache-2.0", "AGPL-3.0-only", "AGPL-3.0-or-later"):
            with self.subTest(license=license_id):
                record["license"] = license_id
                self.assertEqual(registry.validate_manifest(record)["license"], license_id)
        for license_id in ("AGPL", "AGPL-3.0-or-later OR MIT", "Proprietary"):
            record["license"] = license_id
            with self.subTest(license=license_id), self.assertRaises(registry.RegistryError):
                registry.validate_manifest(record)

    def test_invalid_manifest_types_and_unknown_fields_fail(self):
        record, _ = release()
        mutations = [lambda r: r.update(extra=True), lambda r: r.update(license=[]),
                     lambda r: r.update(schema=True), lambda r: r.update(yanked="false"),
                     lambda r: r["artifacts"][0].update(target=[]),
                     lambda r: r["artifacts"][0].update(bytes=True),
                     lambda r: r["artifacts"][0].update(sha256="A" * 64),
                     lambda r: r.update(summary="two\nlines")]
        for mutate in mutations:
            candidate = copy.deepcopy(record)
            mutate(candidate)
            with self.assertRaises(registry.RegistryError):
                registry.validate_manifest(candidate)

    def test_invalid_or_unpinned_commit_fails(self):
        record, _ = release()
        for commit in ("main", "v0.1.0", "abc123", "0" * 40, "A" * 40, "a" * 39):
            candidate = copy.deepcopy(record)
            candidate["source"]["commit"] = commit
            with self.subTest(commit=commit), self.assertRaises(registry.RegistryError):
                registry.validate_manifest(candidate)

    def test_duplicate_json_keys_and_nonfinite_numbers_fail(self):
        for data in ('{"schema":1,"schema":2}', '{"bytes":NaN}', '{"x":Infinity}'):
            with self.assertRaises(registry.RegistryError):
                registry.strict_json(data)

    def test_archives_are_reproducible(self):
        files = project_files()
        first = registry.make_archive(files)
        second = registry.make_archive(dict(reversed(list(files.items()))))
        self.assertEqual(first, second)
        self.assertEqual(registry.read_archive(first), {path: data for path, (data, _) in files.items()})

    def test_traversal_and_ambiguous_paths_fail(self):
        for path in ("../outside", "/outside", "a/../outside", "a//b", "a\\b", "C:/x", "./x", "-option", "con.txt"):
            data = raw_tar([(path, tarfile.REGTYPE, b"x")])
            with self.subTest(path=path), self.assertRaises(registry.RegistryError):
                registry.read_archive(data)

    def test_links_and_special_files_fail(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE):
            with self.subTest(kind=kind), self.assertRaises(registry.RegistryError):
                registry.read_archive(raw_tar([("link", kind, b"")]))

    def test_duplicate_paths_and_file_directory_conflicts_fail(self):
        for paths in (("file", "file"), ("File", "file"), ("a", "a/b"), ("a/b", "a")):
            with self.subTest(paths=paths), self.assertRaises(registry.RegistryError):
                registry.read_archive(raw_tar([(path, tarfile.REGTYPE, b"x") for path in paths]))

    def test_archive_resource_limits_fail_before_extraction(self):
        data = raw_tar([("large", tarfile.REGTYPE, b"x" * 1024)])
        with patch.object(registry, "MAX_FILE_BYTES", 100), self.assertRaises(registry.RegistryError):
            registry.read_archive(data)
        data = raw_tar([(f"file{i}", tarfile.REGTYPE, b"x") for i in range(3)])
        with patch.object(registry, "MAX_FILES", 2), self.assertRaises(registry.RegistryError):
            registry.read_archive(data)
        with patch.object(registry, "MAX_EXPANDED_BYTES", 100), patch.object(registry, "MAX_FILES", 1):
            with self.assertRaises(registry.RegistryError):
                registry.read_archive(gzip.compress(b"x" * 12000, mtime=0))

    def test_tar_checksum_truncation_and_hidden_suffix_fail(self):
        valid = registry.make_archive(project_files())
        raw = bytearray(gzip.decompress(valid))
        raw[20] ^= 1
        candidates = [gzip.compress(raw, mtime=0), valid[:-8],
                      gzip.compress(gzip.decompress(valid) + b"hidden", mtime=0)]
        for data in candidates:
            with self.assertRaises(registry.RegistryError):
                registry.read_archive(data)

    def test_sensitive_paths_are_not_packaged(self):
        for path in (".env", "keys/private.key", "config/.npmrc"):
            with self.assertRaises(registry.RegistryError):
                registry.read_archive(raw_tar([(path, tarfile.REGTYPE, b"secret")]))

    def test_source_target_name_and_version_must_match(self):
        files = registry.read_archive(registry.make_archive(project_files()))
        registry.validate_project(files, "stubbi/hello", "0.1.0", "x86_64-linux")
        for name, version, target in (("stubbi/wrong", "0.1.0", "x86_64-linux"),
                                     ("stubbi/hello", "0.2.0", "x86_64-linux"),
                                     ("stubbi/hello", "0.1.0", "aarch64-linux")):
            with self.assertRaises(registry.RegistryError):
                registry.validate_project(files, name, version, target)

    def test_source_requires_readme_license_and_declared_source(self):
        for removed in ("README.md", "LICENSE", "src/main.s", "asm.toml"):
            files = {path: data for path, (data, _) in project_files().items() if path != removed}
            with self.assertRaises(registry.RegistryError):
                registry.validate_project(files, "stubbi/hello", "0.1.0", "x86_64-linux")

    def resolution_files(self, metadata):
        files = {path: data for path, (data, _) in project_files().items()}
        files["asm.toml"] += metadata.encode()
        return files

    def check_resolution(self, metadata):
        registry.validate_project(self.resolution_files(metadata), "stubbi/hello", "0.1.0", "x86_64-linux")

    def test_resolution_metadata_accepts_ranges_and_feature_edges(self):
        self.check_resolution('''
[resolution]
schema = "1"
[dependencies]
"stubbi/core" = ">=1.2.0, <2.0.0"
"stubbi/optional" = { version = "^0.2.3", optional = true, default-features = false, features = ["base"] }
[features]
default = ["fast"]
fast = ["dep:stubbi/optional", "stubbi/core/simd"]
empty = []
''')
        for requirement in ("*", "1.2.3", "^1.2.3", "~1.2.3", "=1.2.3", ">1.2.3", "<= 2.0.0",
                            ">=0.0.0, <=2147483647.2147483647.2147483647"):
            with self.subTest(requirement=requirement):
                self.check_resolution('[resolution]\nschema = "1"\n[dependencies]\n"stubbi/core" = '
                                      + json.dumps(requirement) + '\n')

    def test_resolution_requires_its_explicit_supported_schema(self):
        for metadata in ('[dependencies]\n"stubbi/core" = "1.2.3"\n', '[features]\nfast = []\n',
                         '[resolution]\nschema = "2"\n', '[resolution]\nschema = 1\n',
                         '[resolution]\nextra = "1"\n', '[resolution]\nschema = "1"\nextra = true\n'):
            with self.subTest(metadata=metadata), self.assertRaises(registry.RegistryError):
                self.check_resolution(metadata)

    def test_resolution_rejects_unsupported_or_unbounded_ranges(self):
        for requirement in ("", "1.2", "01.2.3", "1.2.3-beta", "1.2.3+build", "1.x", "1.2.3 || 2.0.0",
                            "1.2.2147483648", "^1.2.3, <2.0.0", "1.2.3, 2.0.0", ">=1.0.0,", " >=1.0.0",
                            ",".join([">=1.0.0"] * 9), ">=" + "1" * 126):
            with self.subTest(requirement=requirement), self.assertRaises(registry.RegistryError):
                self.check_resolution('[resolution]\nschema = "1"\n[dependencies]\n"stubbi/core" = '
                                      + json.dumps(requirement) + '\n')

    def test_resolution_rejects_unknown_keys_and_invalid_dependency_shapes(self):
        for entry in ('"stubbi/core" = { optional = true }', '"stubbi/core" = { version = "1.2.3", extra = true }',
                      '"stubbi/core" = { version = "1.2.3", optional = "true" }',
                      '"stubbi/core" = { version = "1.2.3", default-features = 1 }',
                      '"stubbi/core" = { version = "1.2.3", features = "simd" }', '"stubbi/core" = []',
                      '"stubbi/core" = { version = "1.2.3", version = "2.0.0" }',
                      '"stubbi/core" = "1.2.3"\n"stubbi/core" = "2.0.0"',
                      '"Stubbi/core" = "1.2.3"', '"stubbi/a--b" = "1.2.3"'):
            with self.subTest(entry=entry), self.assertRaises(registry.RegistryError):
                self.check_resolution('[resolution]\nschema = "1"\n[dependencies]\n' + entry + '\n')
        for metadata in ('[unknown]\nvalue = "x"\n', '[package.extra]\nvalue = "x"\n',
                         '[build]\nsource = "src/main.s"\ntarget = "x86_64-linux"\nextra = "x"\n'):
            with self.subTest(metadata=metadata), self.assertRaises(registry.RegistryError):
                self.check_resolution('[resolution]\nschema = "1"\n' + metadata)

    def test_resolution_rejects_invalid_or_duplicate_feature_names(self):
        for name in ("Fast", "-fast", "1fast", "a" * 33, "fast.name", "fast/name"):
            with self.subTest(name=name), self.assertRaises(registry.RegistryError):
                self.check_resolution('[resolution]\nschema = "1"\n[features]\n' + json.dumps(name) + ' = []\n')
        for entry in ('[features]\nfast = ["fast", "fast"]\n',
                      '[dependencies]\n"stubbi/core" = { version = "1.2.3", features = ["simd", "simd"] }\n',
                      '[dependencies]\n"stubbi/core" = { version = "1.2.3", features = ["SIMD"] }\n'):
            with self.subTest(entry=entry), self.assertRaises(registry.RegistryError):
                self.check_resolution('[resolution]\nschema = "1"\n' + entry)

    def test_resolution_rejects_missing_feature_references_and_local_cycles(self):
        for entry in ('[features]\nfast = ["missing"]\n', '[features]\nfast = ["fast"]\n',
                      '[features]\nfirst = ["second"]\nsecond = ["first"]\n',
                      '[features]\nfast = ["dep:stubbi/missing"]\n',
                      '[features]\nfast = ["stubbi/missing/simd"]\n',
                      '[features]\nfast = ["dep:stubbi/core"]\n',
                      '[features]\nfast = ["stubbi/core/SIMD"]\n'):
            with self.subTest(entry=entry), self.assertRaises(registry.RegistryError):
                self.check_resolution('[resolution]\nschema = "1"\n[dependencies]\n"stubbi/core" = "1.2.3"\n' + entry)

    def test_resolution_limits_manifest_dependency_and_feature_sizes(self):
        schema = '[resolution]\nschema = "1"\n'
        self.check_resolution(schema + '[features]\n' + ''.join(f'f{i} = []\n' for i in range(64)))
        self.check_resolution(schema + '[dependencies]\n' + ''.join(f'"stubbi/p{i}" = "*"\n' for i in range(64)))
        external_features = lambda count: ','.join('"stubbi/core/f' + str(i) + '"' for i in range(count))
        feature_prefix = schema + '[dependencies]\n"stubbi/core" = "*"\n[features]\nfast = ['
        self.check_resolution(feature_prefix + external_features(64) + ']\n')
        files = self.resolution_files(schema)
        files["asm.toml"] += b"#" + b"x" * (8190 - len(files["asm.toml"]) - 1)
        registry.validate_project(files, "stubbi/hello", "0.1.0", "x86_64-linux")
        files["asm.toml"] += b"x"
        with self.assertRaises(registry.RegistryError):
            registry.validate_project(files, "stubbi/hello", "0.1.0", "x86_64-linux")
        for metadata in (schema + '[features]\n' + ''.join(f'f{i} = []\n' for i in range(65)),
                         schema + '[dependencies]\n' + ''.join(f'"stubbi/p{i}" = "*"\n' for i in range(65)),
                         feature_prefix + external_features(65) + ']\n',
                         schema + '[dependencies]\n"stubbi/core" = { version = "*", features = ['
                         + ','.join('"f' + str(i) + '"' for i in range(65)) + '] }\n',
                         schema + '#' + 'x' * 8190 + '\n'):
            with self.subTest(metadata=metadata[:120]), self.assertRaises(registry.RegistryError):
                self.check_resolution(metadata)

    def test_resolution_uses_the_native_single_line_ascii_toml_subset(self):
        for metadata in ('[resolution]\nschema = \'1\'\n', '[resolution]\nschema = """1"""\n',
                         '[resolution]\nschema = "\\u0031"\n', '[resolution]\nschema = "1"\n[features]\nfast = [\n]\n',
                         '[resolution]\nschema = "1"\n[dependencies]\n"stubbi/core" = {\nversion = "1.2.3"\n}\n',
                         '[resolution]\nschema = "1"\n[dependencies."stubbi/core"]\nversion = "1.2.3"\n',
                         '[resolution]\nschema = "1"\n[dependencies]\n"stubbi/core" = { version = "1.2.3", features = ["s\\u0069md"] }\n',
                         '[resolution]\nschema = "1"\n# non-ASCII: é\n'):
            with self.subTest(metadata=metadata), self.assertRaises(registry.RegistryError):
                self.check_resolution(metadata)

    def test_legacy_source_manifest_keeps_its_previous_validation_contract(self):
        self.check_resolution('#' + 'x' * 8190 + '\n[custom]\nnote = "existing metadata"\n')

    def test_invalid_resolution_preserves_pack_and_publication_destinations(self):
        files = self.resolution_files('[resolution]\nschema = "9"\n')
        source = self.root / "source"
        for relative, data in files.items():
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        output = self.root / "existing"
        output.write_bytes(b"preserve existing bytes")
        artifact = self.root / "hello.tar.gz"
        artifact.write_bytes(registry.make_archive({path: (data, 0o644) for path, data in files.items()}))
        commands = (["pack", str(source), "--output", str(output), "--name", "stubbi/hello", "--version", "0.1.0",
                     "--target", "x86_64-linux"],
                    ["prepare", "--name", "stubbi/hello", "--version", "0.1.0", "--summary", "An example.",
                     "--license", "MIT", "--repository", "https://github.com/stubbi/asm", "--commit", "a" * 40,
                     "--artifact", "x86_64-linux", "source", str(artifact),
                     "https://github.com/stubbi/asm/releases/download/v0.1.0/hello.tar.gz", "--output", str(output)])
        for arguments in commands:
            with self.subTest(command=arguments[0]), contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(registry.main(arguments), 1)
                self.assertEqual(output.read_bytes(), b"preserve existing bytes")

    def test_resolution_publication_retains_source_bytes_and_v1_metadata(self):
        files = self.resolution_files('[resolution]\nschema = "1"\n[dependencies]\n"stubbi/core" = "^1.0.0"\n')
        source = self.root / "source"
        for relative, data in files.items():
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        artifact = self.root / "hello.tar.gz"
        output = self.root / "release.json"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(registry.main(["pack", str(source), "--output", str(artifact), "--name", "stubbi/hello",
                                           "--version", "0.1.0", "--target", "x86_64-linux"]), 0)
            self.assertEqual(registry.main(["prepare", "--name", "stubbi/hello", "--version", "0.1.0",
                "--summary", "An example.", "--license", "MIT", "--repository", "https://github.com/stubbi/asm",
                "--commit", "a" * 40, "--artifact", "x86_64-linux", "source", str(artifact),
                "https://github.com/stubbi/asm/releases/download/v0.1.0/hello.tar.gz", "--output", str(output)]), 0)
        self.assertEqual(registry.read_archive(artifact.read_bytes())["asm.toml"], files["asm.toml"])
        record = json.loads(output.read_bytes())
        self.assertEqual(record["schema"], 1)
        self.assertEqual(set(record), {"schema", "name", "version", "summary", "license", "source", "artifacts", "yanked"})
        self.assertEqual(record["artifacts"][0]["sha256"], hashlib.sha256(artifact.read_bytes()).hexdigest())
        tsv, _ = registry.make_indexes([record])
        self.assertTrue(tsv.startswith("# asm-registry-v1\n"))
        self.assertEqual(len(tsv.splitlines()[1].split("\t")), 8)

    def test_source_collection_rejects_symlinks_and_hardlinks(self):
        (self.root / "outside").write_text("private")
        source = self.root / "project"
        source.mkdir()
        (source / "link").symlink_to(self.root / "outside")
        with self.assertRaises(registry.RegistryError):
            registry.collect_files(source)
        (source / "link").unlink()
        (source / "hardlink").hardlink_to(self.root / "outside")
        with self.assertRaises(registry.RegistryError):
            registry.collect_files(source)

    def test_source_collection_enforces_total_limit_before_reading(self):
        for name in ("a", "b"):
            (self.root / name).write_bytes(b"12345678")
        fdopen = registry.os.fdopen
        payload_reads = []

        def observe_reads(*arguments, **keywords):
            stream = fdopen(*arguments, **keywords)
            read = stream.read

            def observed_read(*arguments, **keywords):
                data = read(*arguments, **keywords)
                payload_reads.append(data)
                return data

            stream.read = observed_read
            return stream

        with patch.object(registry, "MAX_EXPANDED_BYTES", 8), \
             patch.object(registry.os, "fdopen", side_effect=observe_reads):
            with self.assertRaises(registry.RegistryError):
                registry.collect_files(self.root)
        self.assertEqual(payload_reads, [b"12345678"])
        with patch.object(registry, "MAX_EXPANDED_BYTES", 16):
            self.assertEqual(set(registry.collect_files(self.root)), {"a", "b"})
        with patch.object(registry, "MAX_EXPANDED_BYTES", 8):
            self.assertEqual(set(registry.collect_files(self.root, ["a", "a"])), {"a"})

    @unittest.skipUnless(shutil.which("git"), "Git is needed for the committed-source limit test")
    def test_git_collection_enforces_total_limit_before_reading(self):
        for name in ("a", "b"):
            (self.root / name).write_bytes(b"12345678")

        def git(*arguments):
            return subprocess.check_output(["git", "-C", str(self.root), *arguments], stderr=subprocess.DEVNULL)

        git("init", "-q")
        git("add", ".")
        git("-c", "user.name=Registry Test", "-c", "user.email=registry-test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        commit = git("rev-parse", "HEAD").decode().strip()
        git_output = registry.git_output
        payload_reads = []

        def observe_reads(repository, *arguments):
            data = git_output(repository, *arguments)
            if arguments[:2] == ("cat-file", "blob"):
                payload_reads.append(data)
            return data

        with patch.object(registry, "MAX_EXPANDED_BYTES", 8), \
             patch.object(registry, "git_output", side_effect=observe_reads):
            with self.assertRaises(registry.RegistryError):
                registry.git_files(self.root, commit, ".")
        self.assertEqual(payload_reads, [b"12345678"])
        with patch.object(registry, "MAX_EXPANDED_BYTES", 16):
            self.assertEqual(set(registry.git_files(self.root, commit, ".")), {"a", "b"})

    @unittest.skipUnless(shutil.which("git"), "Git is needed for the replacement-object test")
    def test_git_replacement_objects_cannot_change_recorded_source_or_baseline(self):
        for replacement in ("commit", "blob"):
            repository = self.root / replacement
            repository.mkdir()
            source = repository / "main.s"
            source.write_bytes(b"original source\n")
            record, _ = release()
            metadata = self.save_record(repository / "registry", record)

            def git(*arguments):
                return subprocess.check_output(["git", "-C", str(repository), *arguments], stderr=subprocess.DEVNULL).decode().strip()

            def commit():
                git("add", ".")
                git("-c", "user.name=Registry Test", "-c", "user.email=registry-test@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")

            git("init", "-q")
            original = commit()
            source.write_bytes(b"replacement source\n")
            changed_record = copy.deepcopy(record)
            changed_record["summary"] = "Replacement metadata."
            metadata.write_bytes(registry.json_bytes(changed_record))
            changed = commit()
            if replacement == "commit":
                git("replace", original, changed)
            else:
                for relative in ("main.s", metadata.relative_to(repository).as_posix()):
                    git("replace", git("rev-parse", original + ":" + relative),
                        git("rev-parse", changed + ":" + relative))
            with self.subTest(replacement=replacement, operation="source"):
                self.assertEqual(registry.git_files(repository, original, ".", ["main.s"])["main.s"][0],
                                 b"original source\n")
            with self.subTest(replacement=replacement, operation="baseline"):
                self.assertEqual(registry.baseline_from_git(repository, original), [record])

    def test_filesystem_fifos_are_rejected_without_open_blocking(self):
        source = self.root / "source"
        source.mkdir()
        os.mkfifo(source / "pipe")
        result = subprocess.run(
            ["python3", str(ROOT / "tools/registry.py"), "pack", str(source),
             "--name", "stubbi/hello", "--version", "0.1.0", "--target", "x86_64-linux",
             "--output", str(self.root / "output.tar.gz")],
            capture_output=True, timeout=3,
        )
        self.assertNotEqual(result.returncode, 0)
        metadata = self.root / "metadata/packages/stubbi/hello"
        metadata.mkdir(parents=True)
        os.mkfifo(metadata / "0.1.0.json")
        result = subprocess.run(
            ["python3", str(ROOT / "tools/registry.py"), "validate", "--registry", str(self.root / "metadata")],
            capture_output=True, timeout=3,
        )
        self.assertNotEqual(result.returncode, 0)
    def test_elf_target_and_segment_bounds_are_checked(self):
        registry.validate_elf(minimal_elf(), "x86_64-linux")
        with self.assertRaises(registry.RegistryError):
            registry.validate_elf(minimal_elf(), "aarch64-linux")
        with self.assertRaises(registry.RegistryError):
            registry.validate_elf(minimal_elf()[:-1], "x86_64-linux")
        invalid = bytearray(minimal_elf())
        struct.pack_into("<Q", invalid, 64 + 32, 9999)
        with self.assertRaises(registry.RegistryError):
            registry.validate_elf(bytes(invalid), "x86_64-linux")

    def test_elf_metadata_segment_need_not_have_memory_size(self):
        # GNU RISC-V ld emits PT_RISCV_ATTRIBUTES with p_filesz > 0, p_memsz = 0.
        data = bytearray(minimal_elf(machine=243))
        struct.pack_into("<H", data, 56, 2)
        data.extend(struct.pack("<IIQQQQQQ", 0x70000003, 4, 176, 0, 0, 4, 0, 1))
        data.extend(b"test")
        registry.validate_elf(bytes(data), "riscv64-linux")
        struct.pack_into("<Q", data, 64 + 40, 1)
        with self.assertRaises(registry.RegistryError):
            registry.validate_elf(bytes(data), "riscv64-linux")

    def test_hash_and_byte_count_are_both_required(self):
        record, data = release()
        registry.validate_artifact(data, record, record["artifacts"][0])
        for bad in (data + b"x", bytes([data[0] ^ 1]) + data[1:]):
            with self.assertRaises(registry.RegistryError):
                registry.validate_artifact(bad, record, record["artifacts"][0])

    def test_manifest_path_and_duplicate_release_are_checked(self):
        record, _ = release()
        path = self.save_record(self.root, record)
        self.assertEqual(len(registry.read_records(self.root)), 1)
        with self.assertRaises(registry.RegistryError):
            registry.check_records([record, record])
        path.rename(path.with_name("1.0.0.json"))
        with self.assertRaises(registry.RegistryError):
            registry.read_records(self.root)

    def test_registry_metadata_symlinks_fail(self):
        record, _ = release()
        path = self.save_record(self.root, record)
        original = self.root / "original.json"
        path.rename(original)
        path.symlink_to(original)
        with self.assertRaises(registry.RegistryError):
            registry.read_records(self.root)

    def test_empty_registry_root_marker_is_the_only_allowed_marker(self):
        packages = self.root / "packages"
        packages.mkdir()
        marker = packages / ".gitkeep"
        marker.write_bytes(b"")
        self.assertEqual(registry.read_records(self.root), [])
        marker.write_bytes(b"not empty")
        with self.assertRaises(registry.RegistryError):
            registry.read_records(self.root)
        marker.unlink()
        elsewhere = self.root / "empty"
        elsewhere.write_bytes(b"")
        marker.symlink_to(elsewhere)
        with self.assertRaises(registry.RegistryError):
            registry.read_records(self.root)
        marker.unlink()
        nested = packages / "owner"
        nested.mkdir()
        (nested / ".gitkeep").write_bytes(b"")
        with self.assertRaises(registry.RegistryError):
            registry.read_records(self.root)

    def test_immutable_history_allows_only_yank_changes(self):
        old, _ = release()
        yanked = copy.deepcopy(old)
        yanked.update(yanked=True, yank_reason="Broken calling convention.")
        registry.validate_manifest(yanked)
        registry.check_immutable([yanked], [old])
        for mutate in (lambda r: r["source"].update(commit="b" * 40),
                       lambda r: r["artifacts"][0].update(sha256="b" * 64),
                       lambda r: r.update(license="AGPL-3.0-or-later"),
                       lambda r: r.update(summary="A replacement.")):
            changed = copy.deepcopy(old)
            mutate(changed)
            with self.assertRaises(registry.RegistryError):
                registry.check_immutable([changed], [old])
        with self.assertRaises(registry.RegistryError):
            registry.check_immutable([], [old])

    @unittest.skipUnless(shutil.which("git"), "Git is needed for the committed-baseline test")
    def test_git_baseline_marker_preserves_immutable_release_history(self):
        def git(*arguments):
            return subprocess.check_output(["git", "-C", str(self.root), *arguments], stderr=subprocess.DEVNULL)

        def commit():
            git("add", ".")
            git("-c", "user.name=Registry Test", "-c", "user.email=registry-test@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
            return git("rev-parse", "HEAD").decode().strip()

        git("init", "-q")
        catalog = self.root / "registry"
        marker = catalog / "packages" / ".gitkeep"
        marker.parent.mkdir(parents=True)
        marker.write_bytes(b"")
        empty_commit = commit()
        self.assertEqual(registry.baseline_from_git(self.root, empty_commit), [])

        old, _ = release()
        self.save_record(catalog, old)
        self.assertEqual(registry.main(["validate", "--repo", str(self.root),
            "--registry", str(catalog), "--base-ref", empty_commit]), 0)
        published_commit = commit()
        baseline = registry.baseline_from_git(self.root, published_commit)
        self.assertEqual(baseline, [old])

        # Read the marker from the recorded Git object, not the working tree.
        marker.write_bytes(b"uncommitted marker change")
        self.assertEqual(registry.baseline_from_git(self.root, published_commit), [old])

        yanked = copy.deepcopy(old)
        yanked.update(yanked=True, yank_reason="Broken calling convention.")
        registry.check_immutable([yanked], baseline)
        changed = copy.deepcopy(old)
        changed["artifacts"][0]["sha256"] = "b" * 64
        with self.assertRaises(registry.RegistryError):
            registry.check_immutable([changed], baseline)
        with self.assertRaises(registry.RegistryError):
            registry.check_immutable([], baseline)

    @unittest.skipUnless(shutil.which("git"), "Git is needed for the committed-baseline test")
    def test_git_baseline_rejects_other_markers_and_metadata_modes(self):
        for kind in ("nonempty", "symlink", "nested", "other-name", "executable", "executable-json"):
            with self.subTest(kind=kind):
                repository = self.root / kind
                repository.mkdir()

                def git(*arguments):
                    return subprocess.check_output(["git", "-C", str(repository), *arguments],
                                                   stderr=subprocess.DEVNULL)

                git("init", "-q")
                catalog = repository / "registry"
                marker = catalog / "packages" / ".gitkeep"
                marker.parent.mkdir(parents=True)
                if kind == "nonempty":
                    marker.write_bytes(b"not empty")
                elif kind == "symlink":
                    (repository / "empty").write_bytes(b"")
                    marker.symlink_to("../../empty")
                elif kind == "nested":
                    marker.parent.joinpath("owner").mkdir()
                    marker.parent.joinpath("owner", ".gitkeep").write_bytes(b"")
                elif kind == "other-name":
                    marker.with_name(".keep").write_bytes(b"")
                else:
                    marker.write_bytes(b"")
                git("add", ".")
                if kind == "executable":
                    git("update-index", "--chmod=+x", "registry/packages/.gitkeep")
                elif kind == "executable-json":
                    old, _ = release()
                    record_path = self.save_record(catalog, old)
                    relative = record_path.relative_to(repository).as_posix()
                    git("add", relative)
                    git("update-index", "--chmod=+x", relative)
                git("-c", "user.name=Registry Test", "-c", "user.email=registry-test@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
                baseline = git("rev-parse", "HEAD").decode().strip()
                with self.assertRaises(registry.RegistryError):
                    registry.baseline_from_git(repository, baseline)

    def test_indexes_use_numeric_versions_and_keep_yank_history(self):
        first, _ = release("0.2.0")
        newest, _ = release("0.10.0")
        yanked, _ = release("0.11.0")
        yanked.update(yanked=True, yank_reason="A test failure.")
        tsv, index = registry.make_indexes([yanked, newest, first], {("stubbi/hello", "0.10.0")})
        self.assertTrue(tsv.startswith(registry.HEADER) and tsv.endswith("\n"))
        self.assertEqual([line.split("\t")[1] for line in tsv.splitlines()[1:]], ["0.2.0", "0.10.0"])
        package = index["packages"][0]
        self.assertEqual(package["latest"], "0.10.0")
        self.assertEqual(len(package["versions"]), 3)
        self.assertEqual(package["versions"][1]["evidence"]["artifacts"], "validated")
        self.assertEqual(package["versions"][1]["evidence"]["formal"], "not-run")

    def test_generated_artifacts_do_not_alias_immutable_release_records(self):
        record, _ = release()
        original = copy.deepcopy(record)
        _, index = registry.make_indexes([record])
        index["packages"][0]["versions"][0]["artifacts"][0]["dependency_metadata"] = {"schema": 1}
        self.assertEqual(record, original)

    def test_dependency_export_preserves_native_indexes_and_published_records(self):
        record, data = release()
        original = copy.deepcopy(record)
        before, _ = registry.make_indexes([record])
        metadata = {}
        registry.validate_artifact(data, record, record["artifacts"][0], dependency_metadata=metadata)
        after, index = registry.make_indexes([record], {(record["name"], record["version"])}, dependency_metadata=metadata)
        self.assertEqual(after, before)
        self.assertEqual(record, original)
        registry.check_immutable([record], [original])
        exported = index["packages"][0]["versions"][0]["artifacts"][0]
        self.assertEqual(exported["dependency_metadata"]["dependencies"], [])
        exported["dependency_metadata"]["dependencies"].append({"name": "untrusted/change"})
        _, regenerated = registry.make_indexes([record], {(record["name"], record["version"])}, dependency_metadata=metadata)
        self.assertEqual(regenerated["packages"][0]["versions"][0]["artifacts"][0]["dependency_metadata"]["dependencies"], [])

    def shared_target_release(self):
        project = ROOT / "examples/hello"
        version = tomllib.loads((project / "asm.toml").read_text())["package"]["version"]
        data = registry.make_archive(registry.collect_files(project))
        record, _ = release(version)
        record["source"]["path"] = "examples/hello"
        record["artifacts"] = [{"target": target, "kind": "source", "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "url": f"https://github.com/stubbi/asm/releases/download/v{version}/hello-{version}-{target}.tar.gz"}
            for target in ("x86_64-linux", "aarch64-linux", "riscv64-linux")]
        return record, data

    def test_dependency_export_keeps_each_target_for_one_shared_source_archive(self):
        record, data = self.shared_target_release()
        original = copy.deepcopy(record)
        before, _ = registry.make_indexes([record])
        metadata = {}
        for artifact in record["artifacts"]:
            registry.validate_artifact(data, record, artifact, dependency_metadata=metadata)
        after, index = registry.make_indexes([record], {(record["name"], record["version"])},
                                             dependency_metadata=metadata)
        self.assertEqual(after, before)
        self.assertEqual(record, original)
        exported = index["packages"][0]["versions"][0]["artifacts"]
        self.assertEqual([artifact["target"] for artifact in exported],
                         ["aarch64-linux", "riscv64-linux", "x86_64-linux"])
        for artifact in exported:
            self.assertEqual(artifact["dependency_metadata"], {"schema": 1,
                "source_sha256": hashlib.sha256(data).hexdigest(), "dependencies": [], "features": {}})

    def test_site_exports_separate_target_declarations_for_one_shared_archive(self):
        with patch.object(sys, "path", [str(ROOT / "tools"), *sys.path]):
            import build_site
        record, data = self.shared_target_release()
        catalog = self.root / "catalog"
        self.save_record(catalog, record)
        output = self.root / "site"
        result = build_site.build_site(ROOT, catalog, output, verify=True,
                                       artifact_reader=lambda *args, **kwargs: data)
        self.assertEqual(result["artifact_checked_releases"], 1)
        declarations = json.loads((output / "registry/v1/dependencies.json").read_bytes())
        self.assertEqual(declarations, {"schema": 1, "sources": [{
            "name": record["name"], "version": record["version"], "target": target,
            "metadata": {"schema": 1, "source_sha256": hashlib.sha256(data).hexdigest(),
                         "dependencies": [], "features": {}}}
            for target in ("aarch64-linux", "riscv64-linux", "x86_64-linux")]})
        expected_tsv, _ = registry.make_indexes([record])
        self.assertEqual((output / "registry/v1/index.tsv").read_bytes(), expected_tsv.encode("ascii"))
        index = json.loads((output / "registry/v1/index.json").read_bytes())
        self.assertTrue(all("dependency_metadata" not in artifact
            for artifact in index["packages"][0]["versions"][0]["artifacts"]))

    def test_dependency_export_rejects_forged_or_mismatched_source_bindings(self):
        record, data = release()
        artifact = record["artifacts"][0]
        digest = artifact["sha256"]
        metadata = {}
        registry.validate_artifact(data, record, artifact, dependency_metadata=metadata)
        checked = {(record["name"], record["version"])}
        identity = ("hello", record["version"], artifact["target"], artifact["bytes"], digest)
        verified = next(iter(metadata.values()))
        for forged in ({identity: {"schema": 1, "source_sha256": digest, "dependencies": [], "features": {}}},
                       {(*identity[:-1], "0" * 64): verified}, {digest: verified}):
            with self.subTest(metadata=forged), self.assertRaises(registry.RegistryError):
                registry.make_indexes([record], checked, dependency_metadata=forged)
        with self.assertRaises(registry.RegistryError):
            registry.make_indexes([record], dependency_metadata=metadata)
        for field, value in (("target", "aarch64-linux"), ("bytes", artifact["bytes"] + 1),
                             ("kind", "executable"), ("sha256", "b" * 64)):
            candidate = copy.deepcopy(record)
            candidate["artifacts"][0][field] = value
            with self.subTest(field=field), self.assertRaises(registry.RegistryError):
                registry.make_indexes([candidate], checked, dependency_metadata=metadata)
        for field, value in (("name", "stubbi/other"), ("version", "0.2.0")):
            candidate = copy.deepcopy(record)
            candidate[field] = value
            with self.subTest(field=field), self.assertRaises(registry.RegistryError):
                registry.make_indexes([candidate], checked, dependency_metadata=metadata)

    def test_checked_flag_alone_does_not_invent_dependency_declarations(self):
        record, _ = release()
        _, index = registry.make_indexes([record], {(record["name"], record["version"])})
        self.assertNotIn("dependency_metadata", index["packages"][0]["versions"][0]["artifacts"][0])

    def test_indexes_preserve_each_version_license(self):
        legacy, _ = release("0.1.0")
        current, _ = release("0.2.0")
        current["license"] = "AGPL-3.0-or-later"
        _, index = registry.make_indexes([current, legacy])
        package = index["packages"][0]
        self.assertEqual(package["license"], "AGPL-3.0-or-later")
        self.assertEqual([(item["version"], item["license"]) for item in package["versions"]],
                         [("0.1.0", "MIT"), ("0.2.0", "AGPL-3.0-or-later")])
        current.update(yanked=True, yank_reason="A test failure.")
        _, index = registry.make_indexes([current, legacy])
        self.assertEqual(index["packages"][0]["license"], "MIT")
        self.assertEqual(index["packages"][0]["versions"][1]["license"], "AGPL-3.0-or-later")

    def test_download_zero_is_distinct_from_unavailable(self):
        record, _ = release()
        artifact = record["artifacts"][0]
        response = {"assets": [{"browser_download_url": artifact["url"], "size": artifact["bytes"],
                                "digest": "sha256:" + artifact["sha256"], "download_count": 0}]}
        result = registry.download_counts([record], fetch=lambda _: response, observed_at="2026-01-01T00:00:00Z")
        self.assertEqual(result["packages"]["stubbi/hello"]["total"], 0)
        unavailable = registry.download_counts([record], fetch=lambda _: {"assets": []})
        self.assertIsNone(unavailable["packages"]["stubbi/hello"]["total"])
        response["assets"][0]["digest"] = "sha256:" + "b" * 64
        mismatch = registry.download_counts([record], fetch=lambda _: response)
        self.assertIsNone(mismatch["packages"]["stubbi/hello"]["total"])

    def test_download_api_failure_does_not_invent_counts(self):
        record, _ = release()
        def failure(_):
            raise OSError("offline")
        result = registry.download_counts([record], fetch=failure)
        self.assertIsNone(result["packages"]["stubbi/hello"]["total"])

    def test_complete_local_publication_pipeline(self):
        source = self.root / "source"
        for path, (data, _) in project_files().items():
            file = source / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
        artifact = self.root / "artifacts" / "hello-0.1.0-x86_64-linux-source.tar.gz"
        self.assertEqual(registry.main(["pack", str(source), "--output", str(artifact), "--name", "stubbi/hello",
                                        "--version", "0.1.0", "--target", "x86_64-linux"]), 0)
        metadata = self.root / "registry" / "packages" / "stubbi" / "hello" / "0.1.0.json"
        url = "https://github.com/stubbi/asm/releases/download/packages-v0.1.0/" + artifact.name
        self.assertEqual(registry.main(["prepare", "--name", "stubbi/hello", "--version", "0.1.0",
            "--summary", "An assembly example.", "--license", "MIT", "--repository", "https://github.com/stubbi/asm",
            "--commit", "a" * 40, "--artifact", "x86_64-linux", "source", str(artifact), url,
            "--output", str(metadata)]), 0)
        output = self.root / "site" / "registry" / "v1"
        self.assertEqual(registry.main(["build", "--registry", str(self.root / "registry"),
                                       "--artifacts-dir", str(artifact.parent), "--output", str(output)]), 0)
        index = json.loads((output / "index.json").read_text())
        self.assertEqual(index["packages"][0]["name"], "stubbi/hello")
        self.assertEqual(index["packages"][0]["versions"][0]["evidence"]["artifacts"], "validated")

    @unittest.skipUnless(shutil.which("git"), "Git is needed for the committed-source test")
    def test_git_pack_uses_the_commit_not_dirty_files(self):
        for path, (data, _) in project_files().items():
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
        def git(*arguments):
            return subprocess.check_output(["git", "-C", str(self.root), *arguments], stderr=subprocess.DEVNULL)
        git("init", "-q")
        git("add", ".")
        git("-c", "user.name=Registry Test", "-c", "user.email=registry-test@example.invalid", "commit", "-qm", "fixture")
        commit = git("rev-parse", "HEAD").decode().strip()
        (self.root / "src" / "main.s").write_bytes(b"modified after commit")
        files = registry.git_files(self.root, commit, ".")
        self.assertEqual(files["src/main.s"][0], project_files()["src/main.s"][0])
        self.assertNotEqual(files["src/main.s"][0], (self.root / "src" / "main.s").read_bytes())


if __name__ == "__main__":
    unittest.main()
