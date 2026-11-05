"""Test read-only snapshot inputs; these are not native security observations.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('windows_fixture_security_probe',
    ROOT / 'tools/windows_fixture_security_probe.py')
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class FixtureSecurityProbeTests(unittest.TestCase):
    def test_prefixes_include_every_workspace_ancestor_and_leaf(self):
        self.assertEqual(probe.path_chain('D:/a/asm/asm/build/HOME with spaces'), [
            'D:\\', 'D:\\a', 'D:\\a\\asm', 'D:\\a\\asm\\asm',
            'D:\\a\\asm\\asm\\build', 'D:\\a\\asm\\asm\\build\\HOME with spaces'])

    def test_ambiguous_remote_relative_and_unbounded_paths_are_refused(self):
        for path in ('relative', 'C:relative', '/C:/odd', '\\\\host\\share\\file', 'C:\\a\\..\\b',
                     'C:\\a\\.\\b', 'C:\\a\\\\b', 'C:\\a\\', 'C:\\a.', 'C:\\a ',
                     'C:\\file:stream', 'C:\\nul\x00', 'C:\\a?b', 'C:\\' + 'x' * 4096,
                     'C:\\' + '\\'.join(['a'] * 33)):
            with self.subTest(path=path), self.assertRaises(ValueError):
                probe.path_chain(path)

    def test_shared_ancestors_keep_home_source_and_temp_roles(self):
        rows = probe.path_requests('C:\\a\\owned\\home', 'C:\\a\\owned\\marker.exe',
                                   ('C:\\Users\\runner\\AppData\\Local\\Temp', 'C:\\a\\owned\\marker.s'))
        self.assertEqual(len([row for row in rows if row['path'] == 'C:\\']), 1)
        self.assertEqual(len(rows[0]['roles']), 4)
        self.assertEqual([row['path'] for row in rows if row['private_home_leaf']], ['C:\\a\\owned\\home'])
        self.assertTrue(any(row['path'].endswith('\\Temp') for row in rows))
        self.assertTrue(any(row['path'].endswith('\\marker.exe') for row in rows))

    def test_case_variants_share_one_observation_without_losing_roles(self):
        rows = probe.path_requests('C:\\Owned\\HOME', 'c:\\owned\\marker.exe')
        self.assertEqual(len(rows), 4)
        self.assertEqual(len(rows[1]['roles']), 2)

    def test_additional_path_count_and_total_snapshot_are_bounded(self):
        with self.assertRaisesRegex(ValueError, '16'):
            probe.path_requests('C:\\home', 'C:\\source', ('C:\\extra',) * 17)
        deep = lambda prefix: 'C:\\' + '\\'.join(f'{prefix}{index}' for index in range(32))
        with self.assertRaisesRegex(ValueError, '64'):
            probe.path_requests(deep('home'), deep('source'))

    @unittest.skipIf(os.name == 'nt', 'This test checks non-Windows refusal only.')
    def test_non_windows_host_is_refused_without_native_api_mocking(self):
        with self.assertRaisesRegex(RuntimeError, 'Native Windows'):
            probe.snapshot('C:\\fixture\\home', 'C:\\fixture\\marker.exe')


if __name__ == '__main__':
    unittest.main()
