"""Registry contract tests. No network access is required."""

import copy
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
import tempfile
import tarfile
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
