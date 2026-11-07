# SPDX-License-Identifier: GPL-2.0-or-later
"""Exercise the real Asm installer on exact native game bytes."""
import hashlib
import json
import os
import pathlib
import stat
import struct
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
GAME = ROOT / 'build/asm-doom'


class InstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.asm = pathlib.Path(os.environ.get('ASM_BIN', REPO / 'build/asm'))
        if not cls.asm.is_file():
            if 'ASM_BIN' in os.environ:
                raise AssertionError('The required Asm executable is missing')
            raise unittest.SkipTest('Build Asm or set ASM_BIN to run the installation gate')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / 'build')
        self.addCleanup(self.tmp.cleanup)
        self.work = pathlib.Path(self.tmp.name).resolve()
        self.original = GAME.read_bytes()
        self.payload = self.work / 'candidate'
        self.index = self.work / 'index.tsv'
        self.destination = self.work / 'doom'
        home = self.work / 'home'
        home.mkdir(mode=0o700)
        self.environment = dict(os.environ, HOME=str(home))
        self.catalog(self.original)

    def catalog(self, data, target='aarch64-macos', digest=None):
        self.payload.write_bytes(data)
        self.index.write_text('# asm-registry-v1\nstubbi/doom\t0.1.0\t' + target + '\texecutable\t'
                              + (digest or hashlib.sha256(data).hexdigest())
                              + '\thttps://github.com/stubbi/asm/releases/download/doom-v0.1.0/doom-0.1.0-aarch64-macos\t'
                              + str(len(data)) + '\tNative assembly game with Freedoom data\n')

    def install(self):
        return subprocess.run([str(self.asm), 'install', 'stubbi/doom@0.1.0', '--index', str(self.index),
                               '--artifact', str(self.payload), '--output', str(self.destination)],
                              capture_output=True, timeout=30, cwd=self.work, env=self.environment)

    def test_install_matches_bytes_and_runs_bundled_data(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), self.original)
        self.assertTrue(stat.S_IMODE(self.destination.stat().st_mode) & stat.S_IXUSR)
        result = subprocess.run([str(self.destination), '--headless', '--ticks', '1'],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['map'], 'E1M1')

    def test_existing_regular_file_and_symlink_are_preserved(self):
        self.destination.write_bytes(b'unrelated file')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(self.destination.read_bytes(), b'unrelated file')
        self.destination.unlink()
        target = self.work / 'other'
        target.write_bytes(b'unchanged')
        self.destination.symlink_to(target)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(target.read_bytes(), b'unchanged')

    def test_bad_digest_wrong_target_and_changed_signature_are_rejected(self):
        self.catalog(self.original, digest='0' * 64)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse(self.destination.exists())
        self.catalog(self.original, target='aarch64-linux')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse(self.destination.exists())
        changed = bytearray(self.original)
        offset = 32
        for _ in range(struct.unpack_from('<I', changed, 16)[0]):
            command, length = struct.unpack_from('<II', changed, offset)
            if command == 0x80000028:
                entry = struct.unpack_from('<Q', changed, offset + 8)[0]
                changed[entry] ^= 1
                break
            offset += length
        self.catalog(changed)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_native_system_only_runtime_dependencies_and_signature(self):
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(GAME)], check=True, capture_output=True)
        dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(GAME)], text=True).splitlines()[1:]
        self.assertTrue(dependencies)
        for line in dependencies:
            self.assertTrue(line.strip().startswith(('/System/Library/', '/usr/lib/')), line)
