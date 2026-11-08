"""Exercise the native cleanup walker with retained directory descriptors.

SPDX-License-Identifier: AGPL-3.0-or-later
The test links the actual walker and platform adapters. Archive comparison
branches trap because cleanup must not inspect the archive member table.
"""
import ctypes
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARM = platform.machine() in ("aarch64", "arm64")
DARWIN = platform.system() == "Darwin"


@unittest.skipIf(DARWIN and not ARM, "The released Darwin host is Apple Silicon")
class ArchiveCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="asm-native-cleanup-")
        cls.addClassCleanup(cls.directory.cleanup)
        directory = ROOT / ("cli/aarch64" if ARM else "cli")
        archive = (directory / "archive.s").read_text()
        walker = archive[archive.index("arc_walk_tree:"):archive.index(".section .rodata", archive.index("arc_walk_tree:"))]
        close = archive[archive.index("arc_close:"):archive.index("/* Ensure our descriptors", archive.index("arc_close:"))]
        constants = "\n".join(line for line in archive.splitlines() if line.startswith(".equ ARC_")) + "\n"
        prefix = "_" if DARWIN else ""
        if ARM:
            text = (directory / "platform.inc").read_text() + constants
            text += ".section .text\n" + walker + close
            text += (f".global {prefix}asm_cleanup\n{prefix}asm_cleanup:\n"
                     "    mov x1, #0\n    mov x2, #1\n    ARM_CALL arc_walk_tree\n    mov x0, x9\n    ret\n"
                     "arc_find_entry:\narc_compare_file:\n    brk #0\n")
            if DARWIN:
                sys.path.insert(0, str(ROOT / "tools"))
                import macos
                text += macos.prepare(directory / "platform.s")
                text += "\n.text\n_main:\n    brk #0\n"
            else:
                text += (directory / "platform.s").read_text()
        else:
            text = ".intel_syntax noprefix\n" + constants + ".section .text\n" + walker + close
            text += (".global asm_cleanup\nasm_cleanup:\n    xor esi, esi\n    mov edx, 1\n    jmp arc_walk_tree\n"
                     "arc_find_entry:\narc_compare_file:\n    ud2\n")
        text += ('.section .rodata\narc_dot: .asciz "."\nregistry_sha256sum: .asciz "/usr/bin/shasum"\n'
                 '.section .bss\n.balign 8\narc_scan_path: .skip ARC_PATH + 2\narc_seen: .skip ARC_COUNT\n')
        source = Path(cls.directory.name) / "cleanup.s"
        source.write_text(text)
        library = source.with_suffix(".dylib" if DARWIN else ".so")
        if DARWIN:
            source.write_text(macos.prepare(source))
            commands = [["clang", "-arch", "arm64", "-dynamiclib", "-o", str(library), str(source)]]
        else:
            obj = source.with_suffix(".o")
            commands = [["as", *([] if ARM else ["--64"]), "-o", str(obj), str(source)],
                        ["ld", "-shared", "-Bsymbolic", "-z", "noexecstack", "-o", str(library), str(obj)]]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise AssertionError(result.stderr)
        cls.library = ctypes.CDLL(str(library))
        cls.cleanup = cls.library.asm_cleanup
        cls.cleanup.argtypes, cls.cleanup.restype = [ctypes.c_int], ctypes.c_int

    def assert_fresh_cleanup(self, *, enumerate_before_creation):
        import os
        with tempfile.TemporaryDirectory(prefix="asm-cleanup-tree-") as temporary:
            root = Path(temporary)
            stage = root / "private stage"
            stage.mkdir(mode=0o700)
            outside = root / "unrelated"
            outside.mkdir()
            sentinel = outside / "keep"
            sentinel.write_bytes(b"preserve unrelated bytes")
            fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY)
            try:
                offset = os.lseek(fd, 0, os.SEEK_CUR)
                descriptor_directory = "/dev/fd" if DARWIN else "/proc/self/fd"
                descriptors = len(os.listdir(descriptor_directory))
                if enumerate_before_creation:
                    self.assertEqual(self.cleanup(fd), 0)
                    self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), offset)
                    self.assertEqual(len(os.listdir(descriptor_directory)), descriptors)
                nested = stage / "verifier" / "cache"
                nested.mkdir(parents=True)
                (nested / "entry").write_bytes(b"private cache bytes")
                (stage / "metadata").write_bytes(b"private metadata")
                (stage / "outside link").symlink_to(outside, target_is_directory=True)
                self.assertEqual(self.cleanup(fd), 0)
                self.assertEqual(os.lseek(fd, 0, os.SEEK_CUR), offset)
                self.assertEqual(len(os.listdir(descriptor_directory)), descriptors)
                self.assertEqual(list(stage.iterdir()), [])
                self.assertEqual(list(outside.iterdir()), [sentinel])
                self.assertEqual(sentinel.read_bytes(), b"preserve unrelated bytes")
                self.assertEqual(os.fstat(fd).st_ino, stage.stat().st_ino)
            finally:
                os.close(fd)

    def test_cleanup_observes_entries_created_after_the_directory_was_opened(self):
        self.assert_fresh_cleanup(enumerate_before_creation=False)

    def test_repeated_cleanup_refreshes_entries_without_reusing_a_directory_stream(self):
        self.assert_fresh_cleanup(enumerate_before_creation=True)

    def test_invalid_directory_does_not_close_or_change_the_caller_descriptor(self):
        import os
        with tempfile.TemporaryFile() as source:
            source.write(b"preserve input bytes")
            source.seek(0)
            self.assertEqual(self.cleanup(source.fileno()), 1)
            self.assertEqual(source.read(), b"preserve input bytes")
        self.assertEqual(self.cleanup(-1), 1)
