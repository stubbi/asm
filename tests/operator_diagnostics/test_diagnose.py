"""Exercise temporary preflight diagnostics without images or credentials.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/diagnose_operator_image.py'


class DiagnosticTests(unittest.TestCase):
    def module(self):
        self.assertTrue(SCRIPT.is_file(), 'The bounded diagnostic probe does not exist.')
        spec = importlib.util.spec_from_file_location('diagnose_operator_image', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_capture_preserves_failed_exit_and_both_streams(self):
        probe = self.module()
        result = probe.capture([sys.executable, '-I', '-c', "import sys;print('out');print('err',file=sys.stderr);sys.exit(7)"])
        self.assertEqual(result['exit_code'], 7)
        self.assertEqual(result['stdout'], b'out\n')
        self.assertEqual(result['stderr'], b'err\n')
        self.assertFalse(result['output_limit'] or result['timed_out'])

    def test_capture_caps_output_and_reaps_its_child(self):
        probe = self.module()
        result = probe.capture([sys.executable, '-I', '-c', "import sys;sys.stderr.write('x'*65536)"], maximum=1024)
        self.assertEqual(len(result['stderr']), 1024)
        self.assertTrue(result['output_limit'])
        with self.assertRaises(ProcessLookupError):
            os.kill(result['pid'], 0)

    def test_capture_timeout_kills_and_reaps_its_child(self):
        probe = self.module()
        result = probe.capture([sys.executable, '-I', '-c', 'import time;time.sleep(10)'], timeout=0.05)
        self.assertTrue(result['timed_out'])
        with self.assertRaises(ProcessLookupError):
            os.kill(result['pid'], 0)

    def test_metadata_never_exposes_file_or_symlink_contents(self):
        probe = self.module()
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            path = root / 'file'
            path.write_bytes(b'synthetic contents must not enter metadata')
            path.chmod(0o440)
            pointer = root / 'pointer'
            pointer.symlink_to('synthetic-target-must-not-enter-metadata')
            record = probe.metadata('fixed_file', path)
            self.assertEqual((record['uid'], record['gid'], record['mode']), (os.geteuid(), path.stat().st_gid, '0440'))
            self.assertFalse(record['symlink'])
            linked = probe.metadata('fixed_pointer', pointer)
            self.assertTrue(linked['symlink'])
            self.assertNotIn('synthetic', repr([record, linked]))
            self.assertNotIn(str(root), repr([record, linked]))

    def test_openssl_classification_exports_only_allowlisted_reason_and_hash(self):
        probe = self.module()
        result = {'exit_code': 1, 'stderr': b"Can't open /usr/lib/ssl/openssl.cnf: No such file or directory", 'stdout': b'', 'timed_out': False, 'output_limit': False}
        record = probe.openssl_result(result)
        self.assertEqual(record['reason'], 'config_missing')
        self.assertEqual(len(record['stderr_prefix_sha256']), 64)
        self.assertNotIn('openssl.cnf', repr(record))
        result['stderr'] = b"Can't open openssl.cnf: Permission denied"
        self.assertEqual(probe.openssl_result(result)['reason'], 'config_permission_denied')
        result['stderr'] = b'arbitrary library text must stay private'
        self.assertEqual(probe.openssl_result(result)['reason'], 'setup_failed')

    def test_prepare_refusal_uses_fixed_stage_reason_and_exception_identifiers(self):
        probe = self.module()
        with tempfile.TemporaryDirectory() as name:
            base = Path(name).resolve()
            (base / 'valid/config').mkdir(parents=True)
            record = probe.projection_attempt(base)
            self.assertEqual(record, {'status': 'refused', 'stage': 'projected_directory_policy', 'exception': 'AdminError', 'reason': 'owner_group_mismatch'})
            self.assertNotIn(str(base), repr(record))


if __name__ == '__main__':
    unittest.main()
