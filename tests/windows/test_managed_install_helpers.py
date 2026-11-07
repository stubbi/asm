"""Exercise real trusted-child failures without claiming Windows qualification.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import managed_helpers as helpers


class ManagedInstallHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asm-installer-evidence-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.work = self.root / 'owned'
        self.work.mkdir()
        self.home = self.work / 'HOME with spaces'
        self.home.mkdir()
        self.environment = dict(os.environ)
        self.commands = []
        self.evidence = self.root / 'evidence'
        self.patch = patch.object(helpers, 'INSTALLER_FAILURES', self.evidence)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def child(self, body):
        return [sys.executable, '-c', body]

    def retained(self, command=None):
        command = command or self.commands[-1]
        output = Path(command['failure_evidence'])
        return output, json.loads((output / 'report.json').read_bytes())

    def test_actual_timeout_keeps_raw_streams_elapsed_and_partial_installation(self):
        source, script = self.work / 'source.exe', self.work / 'install.ps1'
        source.write_bytes(b'inert source bytes\x00\xff')
        script.write_bytes(b'# generated script bytes\r\n')
        argv = self.child('import os,time; from pathlib import Path; '
                          'Path("HOME with spaces/partial.bin").write_bytes(b"partial state"); '
                          'os.write(1,b"before timeout\\x00\\xff"); '
                          'os.write(2,b"stderr before timeout\\r\\n"); time.sleep(10)')
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            helpers.run_installer(self, argv, self.commands, timeout=.3, inputs=(source, script))
        self.assertEqual(len(self.commands), 1)
        command = self.commands[0]
        self.assertTrue(command['timed_out'])
        self.assertNotEqual(command['exit_code'], 0)
        self.assertIsNotNone(command['exit_code'])
        self.assertGreaterEqual(command['seconds'], .3)
        self.assertLess(command['seconds'], 5)
        self.assertEqual(caught.exception.output, b'before timeout\x00\xff')
        self.assertEqual(caught.exception.stderr, b'stderr before timeout\r\n')
        output, report = self.retained()
        self.assertEqual((output / 'stdout.bin').read_bytes(), caught.exception.output)
        self.assertEqual((output / 'stderr.bin').read_bytes(), caught.exception.stderr)
        self.assertEqual(report['command']['exit_code'], command['exit_code'])
        self.assertTrue(report['command']['timed_out'])
        # Evidence survives the same temporary fixture cleanup used by runtime tests.
        source.unlink()
        script.unlink()
        (self.home / 'partial.bin').unlink()
        self.assertEqual((output / 'files/source.exe').read_bytes(), b'inert source bytes\x00\xff')
        self.assertEqual((output / 'files/install.ps1').read_bytes(), b'# generated script bytes\r\n')
        self.assertEqual((output / 'files/HOME with spaces/partial.bin').read_bytes(), b'partial state')
        partial = next(row for row in report['entries'] if row['path'] == 'HOME with spaces/partial.bin')
        self.assertEqual(partial['sha256'], hashlib.sha256(b'partial state').hexdigest())

    def test_nonzero_and_expected_failure_keep_exact_status_and_preserve_prior_bytes(self):
        artifact = self.work / 'source.exe'
        artifact.write_bytes(b'first failed fixture')
        argv = self.child('import os,sys; os.write(1,b"failure one"); sys.exit(23)')
        with self.assertRaises(AssertionError):
            helpers.run_installer(self, argv, self.commands)
        first, first_report = self.retained()
        original_report = (first / 'report.json').read_bytes()
        artifact.write_bytes(b'second failed fixture')
        result = helpers.run_installer(self, argv, self.commands, code=23)
        second, second_report = self.retained()
        self.assertNotEqual(first, second)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(first_report['command']['exit_code'], 23)
        self.assertEqual(second_report['command']['exit_code'], 23)
        self.assertEqual((first / 'report.json').read_bytes(), original_report)
        self.assertEqual((first / 'files/source.exe').read_bytes(), b'first failed fixture')
        self.assertEqual((second / 'files/source.exe').read_bytes(), b'second failed fixture')

    def test_output_flood_is_bounded_and_cannot_become_a_success(self):
        with self.assertRaises(RuntimeError):
            helpers.run_installer(self, self.child('import os; os.write(1,b"x"*200000)'), self.commands)
        output, report = self.retained()
        self.assertTrue(report['command']['output_limit_exceeded'])
        self.assertLessEqual((output / 'stdout.bin').stat().st_size, 65536)
        self.assertLessEqual(len(bytes.fromhex(self.commands[0]['stdout_hex'])), 65536)

    def test_hostile_directory_link_is_recorded_without_copying_external_bytes(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'must-not-copy').write_bytes(b'private outside bytes')
        link = self.work / 'escape'
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            self.skipTest(f'This host cannot create the hostile symlink fixture: {error}')
        (self.work / 'safe').write_bytes(b'retained')
        output = helpers.retain_installer_failure(self.work, {'stdout_hex': '', 'stderr_hex': ''})
        report = json.loads((output / 'report.json').read_bytes())
        row = next(row for row in report['entries'] if row['path'] == 'escape')
        self.assertIn('not traversed', row['skipped'])
        self.assertFalse((output / 'files/escape').exists())
        self.assertFalse(any(path.name == 'must-not-copy' for path in output.rglob('*')))
        self.assertEqual((outside / 'must-not-copy').read_bytes(), b'private outside bytes')

    def test_snapshot_byte_entry_and_depth_limits_are_explicit(self):
        (self.work / 'a').write_bytes(b'123456')
        (self.work / 'b').write_bytes(b'abcdef')
        with patch.object(helpers, 'FAILURE_FILE_BYTES', 8), patch.object(helpers, 'FAILURE_TOTAL_BYTES', 10):
            output = helpers.retain_installer_failure(self.work, {})
        report = json.loads((output / 'report.json').read_bytes())
        self.assertFalse(report['complete'])
        self.assertLessEqual(report['retained_bytes'], 10)
        self.assertTrue(any(row.get('skipped') == 'file or total byte bound' for row in report['entries']))
        with patch.object(helpers, 'FAILURE_ENTRIES', 1):
            output = helpers.retain_installer_failure(self.work, {})
        report = json.loads((output / 'report.json').read_bytes())
        self.assertTrue(report['entry_limit_reached'])
        self.assertEqual(len(report['entries']), 1)
        with patch.object(helpers, 'FAILURE_DEPTH', 0):
            output = helpers.retain_installer_failure(self.work, {})
        report = json.loads((output / 'report.json').read_bytes())
        self.assertTrue(any(row.get('skipped') == 'depth bound' for row in report['entries']))

    def test_source_install_wiring_keeps_fixed_powershell_and_deadline(self):
        # Inspect argument wiring only. No mock qualifies Windows or PowerShell.
        windows = self.root / 'Windows'
        powershell = windows / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        powershell.parent.mkdir(parents=True)
        powershell.write_bytes(b'inert fixed-tool placeholder')
        runtime = SimpleNamespace(TARGET='x86_64-windows', TEST_ARTIFACTS=[], COMMANDS=self.commands)
        generator = SimpleNamespace(render_source_installer=lambda path, target: b'# inert script\n')
        sentinel = object()
        with patch.dict(sys.modules, {'test_runtime': runtime}), patch.dict(os.environ, {'SystemRoot': str(windows)}), \
                patch.object(helpers, 'build_module', return_value=generator), \
                patch.object(helpers, 'run_installer', return_value=sentinel) as invoke:
            result = helpers.source_install(self, b'inert candidate', replace=True, repair=True)
        self.assertIs(result, sentinel)
        invoke.assert_called_once_with(self, [str(powershell), '-NoLogo', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', str(self.work / 'source-install.ps1'),
            '-ReplaceExisting', '-RepairLauncher'], self.commands, code=0, timeout=90,
            inputs=(self.work / 'source.exe', self.work / 'source-install.ps1'))
        self.assertEqual((self.work / 'source.exe').read_bytes(), b'inert candidate')
        self.assertEqual((self.work / 'source-install.ps1').read_bytes(), b'# inert script\n')

    def test_source_and_script_have_priority_over_large_partial_state(self):
        (self.work / 'a-partial').write_bytes(b'12345678')
        source, script = self.work / 'z-source.exe', self.work / 'z-install.ps1'
        source.write_bytes(b'PE?')
        script.write_bytes(b'#PS')
        with patch.object(helpers, 'FAILURE_FILE_BYTES', 8), patch.object(helpers, 'FAILURE_TOTAL_BYTES', 10):
            output = helpers.retain_installer_failure(self.work, {'fixture_inputs': [str(source), str(script)]})
        report = json.loads((output / 'report.json').read_bytes())
        self.assertEqual((output / 'files/z-source.exe').read_bytes(), b'PE?')
        self.assertEqual((output / 'files/z-install.ps1').read_bytes(), b'#PS')
        self.assertFalse((output / 'files/a-partial').exists())
        paths = [row['path'] for row in report['entries']]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertLessEqual(report['retained_bytes'], 10)

    def test_success_stays_quiet_and_invalid_deadlines_cannot_start_a_child(self):
        result = helpers.run_installer(self, self.child('pass'), self.commands)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('failure_evidence', self.commands[0])
        self.assertFalse(self.evidence.exists())
        for timeout in (0, -1, 91):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                helpers.run_installer(self, self.child('raise Exception("not reached")'),
                                      self.commands, timeout=timeout)
        self.assertEqual(len(self.commands), 1)


if __name__ == '__main__':
    unittest.main()
