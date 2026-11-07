"""Test diagnostic boundaries; these tests do not qualify Windows semantics.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import contextlib
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('windows_layout_rename_probe', ROOT / 'tools/windows_layout_rename_probe.py')
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class LayoutRenameProbeTests(unittest.TestCase):
    def test_rename_buffer_uses_native_64_bit_abi_and_exact_component_bytes(self):
        if ctypes.sizeof(ctypes.c_void_p) != 8:
            self.skipTest('The diagnostic requires 64-bit native structure layout.')
        parent = 0x123456789abcdef0
        raw = probe.rename_bytes(parent, 'published')
        self.assertEqual(probe.RenameHeader.RootDirectory.offset, 8)
        self.assertEqual(probe.RenameHeader.FileNameLength.offset, 16)
        self.assertEqual(probe.RenameHeader.FileName.offset, 20)
        self.assertEqual(ctypes.sizeof(probe.IoStatusBlock), 16)
        self.assertEqual(struct.unpack_from('<I', raw)[0], 2)
        self.assertEqual(struct.unpack_from('<Q', raw, 8)[0], parent)
        self.assertEqual(struct.unpack_from('<I', raw, 16)[0], 18)
        self.assertEqual(raw[20:], b'p\x00u\x00b\x00l\x00i\x00s\x00h\x00e\x00d\x00')
        self.assertEqual(len(raw), 38)

    def test_rename_component_refuses_paths_empty_unicode_and_excess_length(self):
        for value in ('', '.', '..', '../published', 'a/b', 'a\\b', 'C:leaf', '\x00', 'é', 'a' * 65):
            with self.subTest(value=value), self.assertRaises(ValueError):
                probe.rename_bytes(123, value)

    def test_source_identity_refuses_changed_source_and_wrong_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '--quiet')
            (root / 'source').write_bytes(b'fixed fixture\n')
            git('add', 'source')
            git('-c', 'user.name=Probe fixture', '-c', 'user.email=probe@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Fixture')
            source = git('rev-parse', 'HEAD')
            self.assertEqual(probe.shared.source_identity(root, source)['source_commit'], source)
            with self.assertRaisesRegex(RuntimeError, 'commit'):
                probe.shared.source_identity(root, 'f' * 40)
            (root / 'source').write_bytes(b'changed\n')
            with self.assertRaisesRegex(RuntimeError, 'clean'):
                probe.shared.source_identity(root, source)

    def test_commit_identity_refuses_malformed_inputs(self):
        for source in ('f487', 'A' * 40, '0' * 40, 'a' * 40 + '\n', '../source'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                probe.shared.commit_id(source)

    def test_malformed_target_is_refused_before_creating_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'new-output'
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
                probe.main(['--target', 'x86_64-linux', '--source-commit', 'a' * 40, '--output', str(output)])
            self.assertEqual(result.exception.code, 2)
            self.assertFalse(output.exists())

    def test_existing_output_and_prior_failure_bytes_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            retained = output / 'report.json'
            retained.write_bytes(b'previous failure\n')
            with contextlib.redirect_stderr(io.StringIO()):
                result = probe.main(['--target', 'x86_64-windows', '--source-commit', 'a' * 40,
                                     '--output', str(output)])
            self.assertEqual(result, 1)
            self.assertEqual(retained.read_bytes(), b'previous failure\n')
            self.assertEqual(list(output.iterdir()), [retained])

    @unittest.skipIf(os.name == 'nt', 'This refusal test requires a non-Windows controller.')
    def test_non_windows_refusal_retains_atomic_report_without_fixtures(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'new-output'
            with contextlib.redirect_stderr(io.StringIO()):
                result = probe.main(['--target', 'x86_64-windows', '--source-commit', 'a' * 40,
                                     '--output', str(output)])
            report = json.loads((output / 'report.json').read_bytes())
            self.assertEqual(result, 1)
            self.assertEqual(report['outcome'], 'incomplete')
            self.assertIn('Native Windows', report['exception']['message'])
            self.assertFalse(report['qualifies_cli_runtime'])
            self.assertFalse(report['qualifies_release'])
            self.assertFalse(report['qualifies_published_installer'])
            self.assertEqual(report['cases'], [])
            self.assertEqual([item.name for item in output.iterdir()], ['report.json'])

    def test_observational_cases_keep_access_and_share_dimensions_separate(self):
        self.assertEqual(probe.READ_DIRECTORY, 0x120081)
        self.assertEqual(probe.DELETE_DIRECTORY, 0x130081)
        self.assertEqual(probe.HELD_CHILD, 0x1300a1)
        self.assertEqual(probe.RENAME_CLASS, 65)
        self.assertEqual(len(probe.CASES), 4)
        self.assertEqual([(case[1], case[2], case[3]) for case in probe.CASES], [
            (0x120081, 5, False), (0x120081, 7, False),
            (0x130081, 7, False), (0x120081, 7, True)])
        self.assertLessEqual(len(probe.DUMMY), 512)
        self.assertFalse(probe.DUMMY.startswith(b'MZ'))
        self.assertLessEqual(probe.MAX_SECONDS, 60)


if __name__ == '__main__':
    unittest.main()
