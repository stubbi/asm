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

from host import IS_MACOS, TARGET, OTHER_TARGET, IS_ARM64, IS_RISCV64, exit_source, program

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

    def make_archive(self, version, name="math", *, target=TARGET, omit=()):
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for relative in ("LICENSE", "README.md", "asm.toml", "src/main.s", "src/min.s", "tests/main.s"):
                if relative in omit:
                    continue
                fixture_root = ROOT / "examples/math"
                if relative.startswith(("src/", "tests/")):
                    fixture_root = fixture_root / "targets/x86_64-linux"
                path = fixture_root / relative
                data = path.read_bytes()
                if relative == "asm.toml":
                    # Fixture versions must not depend on the current example release.
                    data = (f'[package]\nname = "{name}"\nversion = "{version}"\n\n'
                            f'[build]\nsource = "src/main.s"\ntarget = "{target}"\n').encode()
                elif IS_RISCV64 and relative == "src/min.s":
                    data = b".global asm_u64_min\n.text\nasm_u64_min:\n    bgeu a1, a0, 1f\n    mv a0, a1\n1:  ret\n"
                elif IS_RISCV64 and relative in {"src/main.s", "tests/main.s"}:
                    data = exit_source(0).encode()
                elif IS_ARM64 and relative == "src/min.s":
                    data = b".global asm_u64_min\n.text\nasm_u64_min:\n    cmp x0, x1\n    csel x0, x0, x1, ls\n    ret\n"
                elif IS_ARM64 and relative in {"src/main.s", "tests/main.s"}:
                    data = exit_source(0).encode()
                member = tarfile.TarInfo(relative)
                member.mode = 0o644
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        suffix = "" if target == TARGET else f"-{target}"
        path = self.work / f"{name}-{version}{suffix}.tar.gz"
        path.write_bytes(gzip.compress(payload.getvalue(), mtime=0))
        return path

    def metadata(self, archive, version, name="math", digest=None, *, target=TARGET):
        return "\t".join([
            f"stubbi/{name}", version, target, "source",
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
        body = ('mov x0, #12\nmov x1, #37\nbl asm_u64_min\ncmp x0, #12\n'
                'b.ne failure\nmov x0, #0\nmov x8, #93\nsvc #0\n'
                'failure:\nmov x0, #99\nmov x8, #93\nsvc #0\n') if IS_ARM64 else (
                'mov edi, 12\nmov esi, 37\ncall asm_u64_min\ncmp rax, 12\n'
                'jne failure\nxor edi, edi\nmov eax, 60\nsyscall\n'
                'failure:\nmov edi, 99\nmov eax, 60\nsyscall\n')
        if IS_RISCV64:
            body = ("li a0, 12\nli a1, 37\ncall asm_u64_min\nli t0, 12\n"
                    "bne a0, t0, failure\nli a0, 0\nli a7, 93\necall\n"
                    "failure:\nli a0, 99\nli a7, 93\necall\n")
        if IS_MACOS:
            body = body.replace("mov x8, #93\nsvc #0", "bl _exit")
        (project / "src/main.s").write_text(
            f'.include "stubbi/{name}/{version}/{TARGET}/src/min.s"\n' + program(body))

    def package_cache(self, version="0.1.0", name="math", project=None):
        return (project or self.project) / f".asm/packages/stubbi/{name}/{version}/{TARGET}"

    def named_targets(self, project=None):
        project = project or self.project
        (project / "asm.toml").write_text(
            '[package]\nname = "app"\nversion = "0.1.0"\n'
            f'[target.{OTHER_TARGET}]\nsource = "src/foreign.s"\n'
            f'[target.{TARGET}]\nsource = "src/main.s"\n')

    def add_foreign(self, version="0.2.0"):
        archive = self.make_archive(version, target=OTHER_TARGET)
        row = self.metadata(archive, version, target=OTHER_TARGET)
        self.write_index(self.row, row)
        self.cli("add", f"stubbi/math@{version}", "--target", OTHER_TARGET,
                 "--index", self.index, "--artifact", archive)
        return archive, row

    def test_multi_target_lock_preserves_versions_update_and_remove_selection(self):
        self.named_targets()
        self.add()
        archive, foreign_row = self.add_foreign()
        lock = self.project / "asm.lock"
        self.assertEqual(lock.read_text(), "# asm-lock-v2\n# registry local\n" + self.row + foreign_row)
        self.assertEqual(json.loads(self.cli("lock", "--json").stdout)["dependencies"], 1)
        self.assertEqual(json.loads(self.cli("lock", "--target", OTHER_TARGET, "--json").stdout)["dependencies"], 1)
        second = self.make_archive("0.3.0", target=OTHER_TARGET)
        second_row = self.metadata(second, "0.3.0", target=OTHER_TARGET)
        self.write_index(self.row, second_row)
        self.cli("update", "stubbi/math@0.3.0", "--target", OTHER_TARGET,
                 "--index", self.index, "--artifact", second)
        self.assertEqual(lock.read_text(), "# asm-lock-v2\n# registry local\n" + self.row + second_row)
        self.cli("remove", "stubbi/math", "--target", OTHER_TARGET)
        self.assertEqual(lock.read_text(), "# asm-lock-v2\n# registry local\n" + self.row)
        self.assertTrue((self.project / f".asm/packages/stubbi/math/0.2.0/{OTHER_TARGET}").is_dir())
        self.cli("remove", "stubbi/math", "--target", OTHER_TARGET, code=1)
        self.assertEqual(json.loads(self.cli("lock", "--target", OTHER_TARGET, "--json").stdout)["dependencies"], 0)

    def test_multi_target_build_ignores_missing_inactive_cache_but_checks_all_metadata(self):
        self.named_targets()
        self.add()
        archive, foreign_row = self.add_foreign()
        self.consumer()
        self.cli("build", "--locked")
        previous = (self.project / "build/app").read_bytes()
        shutil.rmtree(self.project / f".asm/packages/stubbi/math/0.2.0/{OTHER_TARGET}")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.project / f".asm/cache/{digest}.tar.gz").unlink()
        self.cli("build", "--locked")
        lock = self.project / "asm.lock"
        valid = lock.read_bytes()
        fields = foreign_row.rstrip("\n").split("\t")
        undeclared = next(target for target in ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos")
                          if target not in {TARGET, OTHER_TARGET})
        malformed = [valid + foreign_row.encode()]
        for index, value in ((2, undeclared), (2, "unknown-target"), (3, "executable"), (4, "bad-digest")):
            changed = fields.copy()
            changed[index] = value
            malformed.append(("# asm-lock-v2\n# registry local\n" + self.row + "\t".join(changed) + "\n").encode())
        for data in malformed:
            with self.subTest(data=data[-150:]):
                lock.write_bytes(data)
                self.cli("build", "--locked", code=1)
                self.assertEqual((self.project / "build/app").read_bytes(), previous)
                self.assertEqual(lock.read_bytes(), data)
        lock.write_bytes(valid)
        source = self.package_cache() / "src/min.s"
        source.write_bytes(source.read_bytes() + b"\n# changed selected dependency\n")
        self.cli("build", "--locked", code=1)
        self.assertEqual((self.project / "build/app").read_bytes(), previous)

    def test_multi_target_sync_restores_only_selected_row_without_lock_changes(self):
        self.named_targets()
        self.add()
        archive, foreign_row = self.add_foreign()
        clone = self.work / "multi clone"
        self.cli("new", clone)
        self.named_targets(clone)
        shutil.copyfile(self.project / "asm.lock", clone / "asm.lock")
        before = (clone / "asm.lock").read_bytes()
        self.cli("sync", "--artifact", self.archive, cwd=clone)
        self.assertFalse((clone / f".asm/packages/stubbi/math/0.2.0/{OTHER_TARGET}").exists())
        self.assertEqual(json.loads(self.cli("sync", "--target", OTHER_TARGET, "--artifact", archive,
                                           "--json", cwd=clone).stdout)["dependencies"], 1)
        self.assertEqual((clone / "asm.lock").read_bytes(), before)
        self.cli("lock", "--target", OTHER_TARGET, cwd=clone)

    def test_v1_lock_upgrades_after_success_and_failed_foreign_update_preserves_bytes(self):
        self.add()
        lock = self.project / "asm.lock"
        legacy = lock.read_bytes()
        self.assertTrue(legacy.startswith(b"# asm-lock-v1\n"))
        self.named_targets()
        self.cli("lock")
        self.assertEqual(lock.read_bytes(), legacy)
        archive, foreign_row = self.add_foreign()
        before = lock.read_bytes()
        self.assertTrue(before.startswith(b"# asm-lock-v2\n"))
        self.write_index(self.row, self.metadata(archive, "0.2.0", digest="0" * 64, target=OTHER_TARGET))
        self.cli("update", "stubbi/math@0.2.0", "--target", OTHER_TARGET,
                 "--index", self.index, "--artifact", archive, code=1)
        self.assertEqual(lock.read_bytes(), before)
        newer = self.make_archive("0.4.0", target=OTHER_TARGET)
        self.write_index(self.row, self.metadata(newer, "0.4.0", digest="0" * 64, target=OTHER_TARGET))
        self.cli("update", "stubbi/math@0.4.0", "--target", OTHER_TARGET,
                 "--index", self.index, "--artifact", newer, code=1)
        self.assertEqual(lock.read_bytes(), before)

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

    def test_named_target_project_uses_and_checks_native_dependency_lock(self):
        (self.project / "asm.toml").write_text(
            '[package]\nname = "app"\nversion = "0.1.0"\n'
            f'[target.{OTHER_TARGET}]\nsource = "src/foreign.s"\n'
            f'[target.{TARGET}]\nsource = "src/main.s"\n')
        self.add()
        self.consumer()
        self.cli("run", "--locked")
        self.assertEqual(json.loads(self.cli("lock", "--json").stdout)["dependencies"], 1)
        previous = (self.project / "build/app").read_bytes()
        source = self.package_cache() / "src/min.s"
        source.write_bytes(source.read_bytes() + b"\n# changed dependency\n")
        self.cli("build", "--locked", code=1)
        self.assertEqual((self.project / "build/app").read_bytes(), previous)
        self.cli("remove", "stubbi/math")
        self.assertEqual(json.loads(self.cli("lock", "--json").stdout)["dependencies"], 0)

    def test_legacy_cross_target_first_add_writes_a_reusable_v2_lock(self):
        (self.project / "asm.toml").write_text(
            '[package]\nname = "app"\nversion = "0.1.0"\n'
            f'[build]\nsource = "src/main.s"\ntarget = "{OTHER_TARGET}"\n')
        archive = self.make_archive("0.1.0", target=OTHER_TARGET)
        row = self.metadata(archive, "0.1.0").replace(
            f"\t{TARGET}\tsource\t", f"\t{OTHER_TARGET}\tsource\t")
        self.write_index(row)
        self.cli("add", "stubbi/math@0.1.0", "--target", OTHER_TARGET,
                 "--index", self.index, "--artifact", archive)
        self.assertTrue((self.project / "asm.lock").read_bytes().startswith(b"# asm-lock-v2\n"))
        self.assertEqual(json.loads(self.cli("lock", "--target", OTHER_TARGET, "--json").stdout)["dependencies"], 1)
        self.cli("sync", "--target", OTHER_TARGET, "--artifact", archive)
        self.cli("remove", "stubbi/math", "--target", OTHER_TARGET)
        self.assertEqual(json.loads(self.cli("lock", "--target", OTHER_TARGET, "--json").stdout)["dependencies"], 0)

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
            b"", b"# asm-lock-v3\n# registry local\n",
            valid + self.row.encode(),
            valid.replace(b"source\t", b"executable\t"),
            valid.replace((TARGET + "\t").encode(), (OTHER_TARGET + "\t").encode()),
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
            {"version": "0.1.0", "target": OTHER_TARGET},
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
        archive = self.make_archive("0.1.0", target=OTHER_TARGET)
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
