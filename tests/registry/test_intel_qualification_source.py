"""Bind Intel qualification snapshots to original Git objects and modes.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import qualify_macos_x86_64 as qualify
import registry
import release


class IntelQualificationSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='intel-source-binding-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.repo = self.work / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Qualification fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.original = {'source.s': (b'original $Format:%H$\n', 0o644),
                         'retained.s': (b'include this file\n', 0o644),
                         'tool.sh': (b'#!/bin/sh\nexit 0\n', 0o755)}
        for name, (data, mode) in self.original.items():
            path = self.repo / name
            path.write_bytes(data)
            path.chmod(mode)
        self.git('add', '.')
        self.git('commit', '-qm', 'original')
        self.commit = self.git('rev-parse', 'HEAD')
        (self.repo / 'source.s').write_bytes(b'replacement assembly\n')
        (self.repo / 'retained.s').write_bytes(b'replacement file\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'replacement')
        self.changed = self.git('rev-parse', 'HEAD')

    def git(self, *arguments):
        return subprocess.check_output(['git', '-C', str(self.repo), *arguments],
                                       text=True, stderr=subprocess.STDOUT).strip()

    def assert_snapshots(self):
        commit, files = qualify.source_files(self.repo, self.commit)
        self.assertEqual(commit, self.commit)
        self.assertEqual(files, self.original)
        for number in range(2):
            destination = self.work / str(number)
            release.materialize(files, destination)
            actual = {str(path.relative_to(destination)): (path.read_bytes(), path.stat().st_mode & 0o777)
                      for path in destination.rglob('*') if path.is_file()}
            self.assertEqual(actual, self.original)

    def test_commit_replacement_cannot_change_either_snapshot(self):
        self.git('replace', self.commit, self.changed)
        self.assert_snapshots()

    def test_tree_replacement_cannot_change_either_snapshot(self):
        self.git('replace', self.git('rev-parse', self.commit + '^{tree}'),
                 self.git('rev-parse', self.changed + '^{tree}'))
        self.assert_snapshots()

    def test_blob_replacement_cannot_change_either_snapshot(self):
        self.git('replace', self.git('rev-parse', self.commit + ':source.s'),
                 self.git('rev-parse', self.changed + ':source.s'))
        self.assert_snapshots()

    def test_local_export_subst_cannot_expand_committed_source(self):
        (self.repo / '.git/info/attributes').write_text('source.s export-subst\n')
        self.assert_snapshots()

    def test_local_export_ignore_cannot_omit_committed_source(self):
        (self.repo / '.git/info/attributes').write_text('retained.s export-ignore\n')
        self.assert_snapshots()

    def test_committed_executable_and_regular_modes_are_preserved(self):
        self.assert_snapshots()

    def test_missing_commit_fails_before_materialization(self):
        with self.assertRaises(registry.RegistryError):
            qualify.source_files(self.repo, '1' * 40)
        self.assertFalse((self.work / '0').exists())


if __name__ == '__main__':
    unittest.main()
