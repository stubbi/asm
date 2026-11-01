"""Exercise the native archive boundary through a small assembly ABI harness.

Python only creates hostile fixtures and observes results. The code under test
is cli/archive.s, linked directly with GNU as/ld, with no Python CLI backend.
"""

import gzip
import io
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest

from host import IS_ARM64, ASM_FLAGS


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
.intel_syntax noprefix
.global _start
.extern extract_source_archive, verify_source_archive
.section .text
_start:
    cmp qword ptr [rsp], 4
    jne bad
    mov rax, [rsp + 16]
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov rbx, 0x12345678
    mov rbp, 0x23456789
    mov r12, 0x3456789a
    mov r13, 0x456789ab
    mov r14, 0x56789abc
    mov r15, 0x6789abcd
    cmp byte ptr [rax], 'v'
    je verify
    call extract_source_archive
    jmp result
verify:
    call verify_source_archive
result:
    mov r8d, eax
    cmp rbx, 0x12345678
    jne bad
    cmp rbp, 0x23456789
    jne bad
    cmp r12, 0x3456789a
    jne bad
    cmp r13, 0x456789ab
    jne bad
    cmp r14, 0x56789abc
    jne bad
    cmp r15, 0x6789abcd
    jne bad
    mov edi, r8d
    mov eax, 60
    syscall
bad:
    mov edi, 99
    mov eax, 60
    syscall
.section .note.GNU-stack,"",@progbits
'''


def archive(entries=None):
    """Create the same normalized USTAR profile used by the registry."""
    if entries is None:
        entries = [("README.md", tarfile.REGTYPE, b"Native extraction test.\n"),
                   ("src/main.s", tarfile.REGTYPE, b".global _start\n_start: nop\n")]
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for path, kind, data in entries:
            info = tarfile.TarInfo(path)
            info.type = kind
            info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
            info.uid = info.gid = info.mtime = 0
            info.size = len(data) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = "../../outside"
            tar.addfile(info, io.BytesIO(data) if info.size else None)
    return gzip.compress(output.getvalue(), mtime=0)


def replace_header(data, offset, value):
    raw = bytearray(gzip.decompress(data))
    raw[offset:offset + len(value)] = value
    raw[148:156] = b"        "
    raw[148:156] = f"{sum(raw[:512]):06o}\0 ".encode()
    return gzip.compress(raw, mtime=0)


class NativeArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "build").mkdir(exist_ok=True)
        cls.build = tempfile.TemporaryDirectory(prefix="archive-harness-", dir=ROOT / "build")
        directory = Path(cls.build.name)
        (directory / "harness.s").write_text(
            (ROOT / "tests/aarch64/archive_harness.s").read_text() if IS_ARM64 else HARNESS)
        sources = [(directory / "harness.s", directory / "harness.o")]
        if not IS_ARM64:
            sources.append((ROOT / "cli/archive.s", directory / "archive.o"))
        for source, output in sources:
            subprocess.run(["as", *ASM_FLAGS, "--fatal-warnings", "-o", str(output), str(source)],
                           cwd=ROOT, check=True)
        cls.binary = directory / "archive-test"
        subprocess.run(["ld", "-z", "noexecstack", "--build-id=none", "-o", str(cls.binary),
                        *[str(output) for _, output in sources]], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="archive test ", dir=ROOT / "build")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / "input.tar.gz"
        self.output = self.work / "source"

    def run_native(self, mode="extract", code=0, source=None, output=None, env=None):
        result = subprocess.run([str(self.binary), mode, str(source or self.source),
                                 str(output or self.output)], capture_output=True, timeout=10, env=env)
        self.assertEqual(result.returncode, code, (result.args, result.stderr.decode("utf-8", "replace")))
        return result

    def reject(self, data):
        self.source.write_bytes(data)
        self.run_native(code=1)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.work.glob(".asm-stage-*")), [])

    def test_extract_and_verify_real_bytes_and_callee_saved_registers(self):
        self.source.write_bytes(archive())
        self.run_native()
        self.assertEqual((self.output / "src/main.s").read_bytes(), b".global _start\n_start: nop\n")
        self.assertEqual((self.output / "README.md").stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o755)
        self.run_native("verify")
        self.assertEqual(list(self.work.glob(".asm-stage-*")), [])

    def test_explicit_directories_long_ustar_prefix_and_empty_file(self):
        path = "nested/" + "long-name/" * 12 + "module.s"
        self.source.write_bytes(archive([("empty", tarfile.DIRTYPE, b""),
                                         ("nested/", tarfile.DIRTYPE, b""),
                                         (path, tarfile.REGTYPE, b""),
                                         ("root.s", tarfile.REGTYPE, b"ret\n")]))
        self.run_native()
        self.assertEqual((self.output / path).read_bytes(), b"")
        self.assertTrue((self.output / "empty").is_dir())
        self.run_native("verify")

    def test_bad_gzip_and_tar_checksum_fail(self):
        self.reject(b"not a gzip stream")
        broken = bytearray(archive())
        broken[-5] ^= 1
        self.reject(bytes(broken))
        raw = bytearray(gzip.decompress(archive()))
        raw[0] ^= 1
        self.reject(gzip.compress(raw, mtime=0))

    def test_links_special_files_and_extensions_fail(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE,
                     tarfile.CHRTYPE, tarfile.BLKTYPE, tarfile.XHDTYPE, tarfile.GNUTYPE_LONGNAME):
            with self.subTest(kind=kind):
                self.reject(archive([("unsafe", kind, b"")]))

    def test_traversal_and_ambiguous_member_paths_fail(self):
        for path in ("../outside", "/absolute", "a/../outside", "./relative", "a//b",
                     "a/./b", "a\\b", "C:drive", "-option", "a/-option", "trailing.", "a /b"):
            with self.subTest(path=path):
                self.reject(archive([(path, tarfile.REGTYPE, b"x")]))
        self.assertFalse((self.work / "outside").exists())

    def test_duplicate_case_colliding_and_file_directory_conflicts_fail(self):
        candidates = [[("same", tarfile.REGTYPE, b"a"), ("same", tarfile.REGTYPE, b"b")],
                      [("Same", tarfile.REGTYPE, b"a"), ("same", tarfile.REGTYPE, b"b")],
                      [("a", tarfile.REGTYPE, b"a"), ("a/b", tarfile.REGTYPE, b"b")],
                      [("a/b", tarfile.REGTYPE, b"a"), ("a", tarfile.REGTYPE, b"b")]]
        for entries in candidates:
            with self.subTest(entries=entries):
                self.reject(archive(entries))

    def test_mode_ownership_and_noncanonical_text_are_rejected(self):
        data = archive()
        for offset, value in ((100, b"0004755\0"), (108, b"0000001\0"),
                              (116, b"0000001\0"), (40, b"hidden"),
                              (157, b"link"), (257, b"ustar "), (263, b"01")):
            with self.subTest(offset=offset):
                self.reject(replace_header(data, offset, value))

    def test_truncation_padding_and_hidden_trailing_content_fail(self):
        raw = gzip.decompress(archive([("a", tarfile.REGTYPE, b"x")]))
        candidates = [raw[:-1], raw[:512], raw[:1024], raw[:1536], raw + b"hidden"]
        corrupt_padding = bytearray(raw)
        corrupt_padding[513] = 1
        candidates.append(corrupt_padding)
        hidden_tail = bytearray(raw)
        hidden_tail[-1] = 1
        candidates.append(hidden_tail)
        for payload in candidates:
            with self.subTest(length=len(payload)):
                self.reject(gzip.compress(payload, mtime=0))

    def test_prevalidation_writes_nothing_when_a_late_member_is_bad(self):
        self.reject(archive([("first.s", tarfile.REGTYPE, b"allowed"),
                             ("../outside", tarfile.REGTYPE, b"blocked")]))

    def test_file_count_size_and_decompressed_stream_limits(self):
        self.reject(archive([(f"f{i}", tarfile.REGTYPE, b"") for i in range(4097)]))
        self.reject(archive([("large", tarfile.REGTYPE, b"x" * (16 * 1024 * 1024 + 1))]))
        self.reject(gzip.compress(b"\0" * (64 * 1024 * 1024 + 1), mtime=0))

    def test_existing_destinations_are_not_replaced_and_staging_is_removed(self):
        self.source.write_bytes(archive())
        self.output.mkdir()
        sentinel = self.output / "keep"
        sentinel.write_bytes(b"unchanged")
        self.run_native(code=1)
        self.assertEqual(sentinel.read_bytes(), b"unchanged")
        self.assertEqual(list(self.work.glob(".asm-stage-*")), [])
        sentinel.unlink()
        self.output.rmdir()
        self.output.write_bytes(b"existing file")
        self.run_native(code=1)
        self.assertEqual(self.output.read_bytes(), b"existing file")
        self.assertEqual(list(self.work.glob(".asm-stage-*")), [])

    def test_destination_parent_symlink_is_not_followed(self):
        self.source.write_bytes(archive())
        real = self.work / "real"
        real.mkdir()
        link = self.work / "alias"
        link.symlink_to(real, target_is_directory=True)
        self.run_native(code=1, output=link / "package")
        self.assertEqual(list(real.iterdir()), [])

    def test_input_symlink_and_fifo_are_rejected_without_blocking(self):
        real = self.work / "real.tar.gz"
        real.write_bytes(archive())
        self.source.symlink_to(real)
        self.run_native(code=1)
        self.source.unlink()
        os.mkfifo(self.source)
        self.run_native(code=1)

    def test_verify_rejects_changed_missing_extra_and_linked_files(self):
        self.source.write_bytes(archive())
        self.run_native()
        module = self.output / "src/main.s"
        original = module.read_bytes()
        module.write_bytes(b"X" + original[1:])
        self.run_native("verify", code=1)
        module.write_bytes(original)
        module.unlink()
        self.run_native("verify", code=1)
        module.write_bytes(original)
        extra = self.output / "extra.s"
        extra.write_bytes(b"extra")
        self.run_native("verify", code=1)
        extra.unlink()
        module.unlink()
        other = self.work / "other.s"
        other.write_bytes(original)
        module.symlink_to(other)
        self.run_native("verify", code=1)
        module.unlink()
        os.link(other, module)
        self.run_native("verify", code=1)
        module.unlink()
        os.mkfifo(module)
        self.run_native("verify", code=1)

    def test_verify_rejects_extra_directory_and_missing_explicit_directory(self):
        self.source.write_bytes(archive([("empty", tarfile.DIRTYPE, b""),
                                         ("file.s", tarfile.REGTYPE, b"ret\n")]))
        self.run_native()
        (self.output / "unexpected").mkdir()
        self.run_native("verify", code=1)
        (self.output / "unexpected").rmdir()
        (self.output / "empty").rmdir()
        self.run_native("verify", code=1)

    def test_gzip_environment_cannot_add_options(self):
        self.source.write_bytes(archive())
        env = os.environ.copy()
        env["GZIP"] = "--this-option-does-not-exist"
        self.run_native(env=env)
        self.run_native("verify", env=env)


if __name__ == "__main__":
    unittest.main()
