# SPDX-License-Identifier: GPL-2.0-or-later
"""Bounded native tests for malformed saves and special file destinations."""
import pathlib
import platform
import resource
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (3, 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024 * 1024, 8 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                     'Native Apple arm64 test')
class HostileSaveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='asm-doom-save-test-')
        cls.exe = pathlib.Path(cls.tmp.name) / 'save-test'
        subprocess.run([
            'clang', '-arch', 'arm64', '-mmacosx-version-min=15.0',
            '-I', str(ROOT / 'src'),
            '-Wall', '-Wextra', '-Werror', str(ROOT / 'tests/world_save_hostile.c'),
            str(ROOT / 'src/world.s'), '-o', str(cls.exe),
        ], check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def exercise(self, case):
        with tempfile.TemporaryDirectory(prefix='asm-doom-save-case-') as directory:
            result = subprocess.run([str(self.exe), case, directory], capture_output=True,
                                    text=True, timeout=5, preexec_fn=limits)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, 'Hostile save rejected; state and existing files preserved.\n')
        self.assertEqual(result.stderr, '')

    def test_fifo_rejected_without_writer(self): self.exercise('fifo')
    def test_symlink_does_not_replace_target(self): self.exercise('symlink')
    def test_hardlink_cannot_be_replaced(self): self.exercise('hardlink')
    def test_unrelated_existing_file_preserved(self): self.exercise('unrelated')
    def test_negative_mover_speed(self): self.exercise('negative-speed')
    def test_zero_mover_speed(self): self.exercise('zero-speed')
    def test_large_mover_speed(self): self.exercise('large-speed')
    def test_large_mover_target(self): self.exercise('large-target')
    def test_large_mover_top(self): self.exercise('large-top')
    def test_nan_crusher_return_speed(self): self.exercise('crusher-nan')
    def test_infinite_crusher_return_speed(self): self.exercise('crusher-inf')
    def test_negative_crusher_return_speed(self): self.exercise('crusher-negative')
    def test_large_crusher_return_speed(self): self.exercise('crusher-large')
    def test_large_door_wait(self): self.exercise('door-wait')
    def test_nonboolean_floor_crush_flag(self): self.exercise('floor-crush')


if __name__ == '__main__':
    unittest.main()
