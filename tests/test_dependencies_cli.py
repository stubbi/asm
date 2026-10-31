"""Test exact source dependencies through the native public CLI."""

import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"


class DependencyCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dependencies-", dir=ROOT / "build")
        self.work = Path(self.temp.name)
        self.project = self.work / "project with spaces"
        subprocess.run([str(ASM), "new", str(self.project)], cwd=self.work, check=True, capture_output=True)
        self.index = self.work / "index.tsv"
        self.archive = self.make_archive("0.1.0")
        self.row = self.metadata(self.archive, "0.1.0")
        self.write_index(self.row)

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *args, cwd=None, code=0):
        result = subprocess.run(
            [str(ASM), *map(str, args)], cwd=cwd or self.project,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        self.assertEqual(list((cwd or self.project).glob(".asm-registry-*")), [])
        return result

    def make_archive(self, version, name="math", *, target="x86_64-linux", omit=()):
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for relative in ("LICENSE", "README.md", "asm.toml", "src/main.s", "src/min.s", "tests/main.s"):
                if relative in omit:
                    continue
                path = ROOT / "examples/math" / relative
                data = path.read_bytes()
                if relative == "asm.toml":
                    data = data.replace(b'"0.1.0"', f'"{version}"'.encode())
                    data = data.replace(b'"math"', f'"{name}"'.encode())
                    data = data.replace(b'"x86_64-linux"', f'"{target}"'.encode())
                member = tarfile.TarInfo(relative)
                member.mode = 0o644
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        path = self.work / f"{name}-{version}.tar.gz"
        path.write_bytes(gzip.compress(payload.getvalue(), mtime=0))
        return path

    def metadata(self, archive, version, name="math", digest=None):
        return "\t".join([
            f"stubbi/{name}", version, "x86_64-linux", "source",
            digest or hashlib.sha256(archive.read_bytes()).hexdigest(),
            f"https://github.com/stubbi/asm/releases/download/v0.1.0/{name}-{version}.tar.gz",
            str(archive.stat().st_size), "Unsigned minimum function",
        ]) + "\n"

    def write_index(self, *rows):
        self.index.write_text("# asm-registry-v1\n" + "".join(rows))

    def add(self):
        return self.cli("add", "stubbi/math@0.1.0", "--index", self.index, "--artifact", self.archive, "--json")

    def consumer(self, project=None, version="0.1.0", name="math"):
        project = project or self.project
        (project / "src/main.s").write_text(
            '.intel_syntax noprefix\n'
            f'.include "stubbi/{name}/{version}/x86_64-linux/src/min.s"\n'
            '.section .text\n.global _start\n_start:\n'
            'mov edi, 12\nmov esi, 37\ncall asm_u64_min\ncmp rax, 12\n'
            'jne failure\nxor edi, edi\nmov eax, 60\nsyscall\n'
            'failure:\nmov edi, 99\nmov eax, 60\nsyscall\n'
        )

    def package_cache(self, version="0.1.0", name="math", project=None):
        return (project or self.project) / f".asm/packages/stubbi/{name}/{version}/x86_64-linux"

    def test_add_lock_and_real_assembly_import(self):
        result = json.loads(self.add().stdout)
        self.assertEqual(result["package"], "stubbi/math")
        self.assertTrue((self.project / result["cache"] / "src/min.s").is_file())
        lock = (self.project / "asm.lock").read_text()
        self.assertEqual(lock, "# asm-lock-v1\n# registry local\n" + self.row)
        self.consumer()
        self.cli("run", "--locked")
        self.assertEqual(json.loads(self.cli("lock", "--json").stdout)["dependencies"], 1)
        before = (self.project / "asm.lock").read_bytes()
        self.add()
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)

    def test_default_build_rejects_changed_missing_and_extra_source_cache(self):
        self.add()
        self.consumer()
        self.cli("build")
        previous = (self.project / "build/app").read_bytes()
        source = self.package_cache() / "src/min.s"
        original = source.read_bytes()
        source.write_bytes(original + b"\n# a local edit\n")
        self.cli("build", code=1)
        self.assertEqual((self.project / "build/app").read_bytes(), previous)
        source.write_bytes(original)
        extra = self.package_cache() / "extra.s"
        extra.write_text("unexpected member")
        self.cli("lock", code=1)
        extra.unlink()
        source.unlink()
        self.cli("run", code=1)
        source.write_bytes(original)
        self.cli("run")

    def test_corrupt_archive_cache_fails_before_build(self):
        self.add()
        self.consumer()
        cache = next((self.project / ".asm/cache").glob("*.tar.gz"))
        data = bytearray(cache.read_bytes())
        data[-1] ^= 1
        cache.write_bytes(data)
        self.cli("build", code=1)
        self.assertFalse((self.project / "build/app").exists())

    def test_update_is_atomic_and_requires_explicit_exact_version(self):
        self.add()
        before = (self.project / "asm.lock").read_bytes()
        second = self.make_archive("0.2.0")
        self.write_index(self.row, self.metadata(second, "0.2.0", digest="0" * 64))
        self.cli("update", "stubbi/math@0.2.0", "--index", self.index, "--artifact", second, code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)
        self.assertFalse(self.package_cache("0.2.0").exists())
        self.write_index(self.row, self.metadata(second, "0.2.0"))
        self.cli("add", "stubbi/math@0.2.0", "--index", self.index, "--artifact", second, code=1)
        self.cli("update", "stubbi/math@0.2.0", "--index", self.index, "--artifact", second)
        self.assertIn("\t0.2.0\t", (self.project / "asm.lock").read_text())
        self.assertTrue(self.package_cache("0.1.0").exists())
        self.consumer(version="0.2.0")
        self.cli("run", "--locked")
        self.cli("add", "stubbi/math", "--index", self.index, code=2)
        self.cli("update", "stubbi/math", "--index", self.index, code=2)

    def test_same_version_cannot_change_its_digest(self):
        self.add()
        before = (self.project / "asm.lock").read_bytes()
        self.write_index(self.metadata(self.archive, "0.1.0", digest="0" * 64))
        for command in ("add", "update"):
            self.cli(command, "stubbi/math@0.1.0", "--index", self.index, "--artifact", self.archive, code=1)
            self.assertEqual((self.project / "asm.lock").read_bytes(), before)

    def test_remove_preserves_other_locks_and_all_cache_files(self):
        self.add()
        second = self.make_archive("0.1.0", "math-two")
        self.write_index(self.row, self.metadata(second, "0.1.0", "math-two"))
        self.cli("add", "stubbi/math-two@0.1.0", "--index", self.index, "--artifact", second)
        self.assertEqual(json.loads(self.cli("lock", "--json").stdout)["dependencies"], 2)
        self.cli("remove", "stubbi/math")
        self.assertTrue(self.package_cache().exists())
        lock = (self.project / "asm.lock").read_text()
        self.assertNotIn("stubbi/math\t", lock)
        self.assertIn("stubbi/math-two\t", lock)
        self.consumer(name="math-two")
        self.cli("run", "--locked")
        self.cli("remove", "stubbi/math-two")
        self.assertEqual(json.loads(self.cli("lock", "--json").stdout)["dependencies"], 0)
        self.cli("remove", "stubbi/math-two", code=1)

    def test_sync_recreates_missing_cache_from_exact_lock_without_new_resolution(self):
        self.add()
        clone = self.work / "fresh-clone"
        self.cli("new", clone)
        shutil.copyfile(self.project / "asm.lock", clone / "asm.lock")
        self.consumer(project=clone)
        self.cli("build", cwd=clone, code=1)
        self.cli("sync", "--artifact", self.archive, cwd=clone)
        self.cli("run", "--locked", cwd=clone)
        self.assertEqual((clone / "asm.lock").read_bytes(), (self.project / "asm.lock").read_bytes())

    def test_existing_cache_edits_are_preserved_on_sync_failure(self):
        self.add()
        source = self.package_cache() / "src/min.s"
        source.write_text("a user edit\n")
        before = (self.project / "asm.lock").read_bytes()
        self.cli("sync", "--artifact", self.archive, code=1)
        self.assertEqual(source.read_text(), "a user edit\n")
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)

    def test_locked_requires_lock_and_malformed_lock_is_rejected(self):
        self.cli("build", "--locked", code=1)
        self.cli("build")
        self.add()
        lock = self.project / "asm.lock"
        valid = lock.read_bytes()
        malformed = [
            b"", b"# asm-lock-v2\n# registry local\n",
            valid + self.row.encode(),
            valid.replace(b"source\t", b"executable\t"),
            valid.replace(b"x86_64-linux\t", b"aarch64-linux\t"),
            valid.replace(b"# registry local", b"# registry http://invalid"),
            valid + self.metadata(self.archive, "0.2.0").encode(),
        ]
        for data in malformed:
            with self.subTest(data=data[:100]):
                lock.write_bytes(data)
                self.cli("build", code=1)
        lock.unlink()
        os.mkfifo(lock)
        self.cli("build", code=1)

    def test_bad_archive_and_project_symlink_do_not_change_lock(self):
        self.archive.write_bytes(gzip.compress(b"not a tar archive", mtime=0))
        self.write_index(self.metadata(self.archive, "0.1.0"))
        self.cli("add", "stubbi/math@0.1.0", "--index", self.index, "--artifact", self.archive, code=1)
        self.assertFalse((self.project / "asm.lock").exists())
        self.assertFalse(self.package_cache().exists())
        self.archive = self.make_archive("0.1.0")
        self.write_index(self.metadata(self.archive, "0.1.0"))
        owner = self.project / ".asm/packages/stubbi"
        shutil.rmtree(owner)
        outside = self.work / "outside"
        outside.mkdir()
        owner.symlink_to(outside, target_is_directory=True)
        self.cli("add", "stubbi/math@0.1.0", "--index", self.index, "--artifact", self.archive, code=1)
        self.assertEqual(list(outside.iterdir()), [])

    def test_project_lock_prevents_concurrent_modification(self):
        self.add()
        before = (self.project / "asm.lock").read_bytes()
        with (self.project / ".asm/operation.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.cli("remove", "stubbi/math", code=1)
            self.cli("build", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)
        self.cli("lock")

    def test_custom_index_cannot_misdeclare_source_package_identity(self):
        cases = [
            {"version": "0.1.0", "target": "aarch64-linux"},
            {"version": "0.1.0", "name": "another-name"},
            {"version": "0.2.0"},
            {"version": "0.1.0", "omit": ("README.md",)},
            {"version": "0.1.0", "omit": ("LICENSE",)},
            {"version": "0.1.0", "omit": ("src/main.s",)},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                archive = self.make_archive(**changes)
                self.write_index(self.metadata(archive, "0.1.0"))
                self.cli("add", "stubbi/math@0.1.0", "--index", self.index, "--artifact", archive, code=1)
                self.assertFalse((self.project / "asm.lock").exists())
                self.assertFalse(self.package_cache().exists())

    def test_locked_build_rejects_a_misdeclared_source_manifest(self):
        self.add()
        archive = self.make_archive("0.1.0", target="aarch64-linux")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.project / ".asm/cache" / f"{digest}.tar.gz").write_bytes(archive.read_bytes())
        (self.project / "asm.lock").write_text(
            "# asm-lock-v1\n# registry local\n" + self.metadata(archive, "0.1.0")
        )
        self.cli("build", code=1)
        self.assertFalse((self.project / "build/app").exists())

    def test_add_cannot_write_a_lock_larger_than_the_reader_limit(self):
        prefix = "# asm-lock-v1\n# registry local\n"
        limit = 1048576
        for summary_length in range(160, 0, -1):
            fields = self.row.rstrip("\n").split("\t")
            fields[0] = "stubbi/pkg0000"
            fields[7] = "s" * summary_length
            template = "\t".join(fields) + "\n"
            count = (limit - len(prefix)) // len(template)
            remaining = limit - len(prefix) - count * len(template)
            if count < 4096 and remaining < len(self.row):
                break
        else:
            self.fail("Could not construct a bounded near-limit fixture")
        lock = prefix + "".join(template.replace("pkg0000", f"pkg{number:04d}", 1) for number in range(count))
        self.assertLessEqual(len(lock), limit)
        self.assertGreater(len(lock) + len(self.row), limit)
        (self.project / "asm.lock").write_text(lock)
        result = self.cli("add", "stubbi/math@0.1.0", "--index", self.index, "--artifact", self.archive, code=1)
        self.assertIn("exceed 1 MiB", result.stderr)
        self.assertEqual((self.project / "asm.lock").read_text(), lock)


if __name__ == "__main__":
    unittest.main()
