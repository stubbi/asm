"""Test probe refusals and evidence limits; these are not Windows qualification.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
try:
    driver = importlib.import_module('tools.windows_bootstrap_smoke')
finally:
    sys.path.pop(0)


class BootstrapSmokeDriverTests(unittest.TestCase):
    def test_requires_native_windows_and_matching_target(self):
        if os.name != 'nt':
            with self.assertRaisesRegex(RuntimeError, 'Native Windows'):
                driver.require_native('x86_64-windows')
        else:
            native = driver.require_native(None)
            wrong = 'aarch64-windows' if native == 0x8664 else 'x86_64-windows'
            with self.assertRaisesRegex(RuntimeError, 'architecture'):
                driver.require_native(wrong)

    def test_missing_fixed_tool_fails_without_path_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, 'clang.exe'):
                driver.fixed_tools('x86_64-windows', llvm=root, sdk=root, windows=root)

    def test_commit_parser_rejects_abbreviated_uppercase_and_zero_ids(self):
        self.assertEqual(driver.commit_id('a' * 40), 'a' * 40)
        for text in ('abc123', 'A' * 40, '0' * 40, 'a' * 40 + '\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                driver.commit_id(text)

    def test_source_binding_rejects_wrong_commit_and_dirty_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
            git('init', '--quiet')
            (root / 'source').write_text('original')
            git('add', 'source')
            git('-c', 'user.name=Probe test', '-c', 'user.email=probe@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Fixture')
            commit = git('rev-parse', 'HEAD')
            self.assertEqual(driver.source_identity(root, commit)['source_commit'], commit)
            with self.assertRaisesRegex(RuntimeError, 'commit'):
                driver.source_identity(root, 'a' * 40)
            (root / 'source').write_text('changed')
            with self.assertRaisesRegex(RuntimeError, 'clean'):
                driver.source_identity(root, commit)

    def test_capture_retains_only_bounded_output_and_reports_failure(self):
        result = driver.capture([sys.executable, '-c',
                                 'import os; os.write(1,b"a"*200000); os.write(2,b"b"*200000)'], timeout=5)
        self.assertTrue(result['output_limit_exceeded'])
        self.assertLessEqual(len(result['stdout']), 65536)
        self.assertLessEqual(len(result['stderr']), 65536)
        self.assertFalse(driver.command_succeeded(result))

    def test_capture_timeout_retains_diagnostics(self):
        result = driver.capture([sys.executable, '-c',
                                 'import sys,time; print("before timeout",flush=True); time.sleep(5)'], timeout=.2)
        self.assertTrue(result['timed_out'])
        self.assertIn('before timeout', result['stdout'])
        self.assertFalse(driver.command_succeeded(result))

    def test_version_comes_from_exact_source_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'cli').mkdir()
            (root / 'cli/asm.s').write_text('version_text: .asciz "asm 1.2.3 (x86_64-linux)\\n"\n')
            self.assertEqual(driver.source_version(root), '1.2.3')
            (root / 'cli/asm.s').write_text('version_text: .asciz "asm 01.2.3 (x86_64-linux)\\n"\n')
            with self.assertRaises(ValueError):
                driver.source_version(root)

    def test_inventory_keeps_partial_bytes_and_rejects_oversized_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'partial').write_bytes(b'partial publication')
            (root / 'oversized').write_bytes(b'x' * (8 * 1024 * 1024 + 1))
            found = driver.inventory(root)
            partial = next(row for row in found if row['path'] == 'partial')
            self.assertEqual(partial['bytes'], 19)
            self.assertEqual(partial['sha256'], 'e0bb4193f59e6180c895a084883ab2e69801b4a77806bdfabe495a5a980fb00e')
            oversized = next(row for row in found if row['path'] == 'oversized')
            self.assertIn('error', oversized)
            self.assertNotIn('sha256', oversized)

    def test_independent_publication_check_rejects_record_payload_and_execution_changes(self):
        spec = importlib.util.spec_from_file_location('smoke_pe_fixture', ROOT / 'tests/release/test_windows_bootstrap.py')
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        data = fixture.executable()
        digest = hashlib.sha256(data).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            owned = Path(temporary)
            home = owned / 'HOME with spaces'
            store = home / '.local/bin/.asm-cli'
            payload = store / 'versions' / digest / 'asm.exe'
            payload.parent.mkdir(parents=True)
            root = home / '.local/bin/asm.exe'
            artifact, marker = owned / 'marker.exe', owned / 'PACKAGE_EXECUTED'
            for path in (artifact, root, payload):
                path.write_bytes(data)
            (store / 'layout').write_bytes(b'# asm-cli-layout-v1\n')
            record = (f'# asm-cli-current-v1\n0.6.1\tx86_64-windows\t1536\t{digest}\t1\t0.6.0\n').encode()
            (store / 'current.tsv').write_bytes(record)
            result = driver.validate_install(home, artifact, 'x86_64-windows', '0.6.1', marker)
            self.assertEqual(result['sha256'], digest)
            self.assertFalse(result['candidate_executed_by_driver'])
            for path, changed in ((payload, data[:-1] + b'x'), (root, data[:-1] + b'x'),
                                  (store / 'current.tsv', record + b'x'),
                                  (store / 'layout', b'wrong layout')):
                old = path.read_bytes()
                path.write_bytes(changed)
                with self.subTest(path=path), self.assertRaises(ValueError):
                    driver.validate_install(home, artifact, 'x86_64-windows', '0.6.1', marker)
                path.write_bytes(old)
            marker.write_bytes(b'candidate ran')
            with self.assertRaisesRegex(RuntimeError, 'execution occurred'):
                driver.validate_install(home, artifact, 'x86_64-windows', '0.6.1', marker)

    def test_non_native_main_writes_atomic_failure_report(self):
        if os.name == 'nt':
            return  # Native behavior is exercised by the separate probe workflow.
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'evidence'
            result = driver.main(['--target', 'x86_64-windows', '--source-commit', 'a' * 40,
                                  '--output', str(output)])
            self.assertNotEqual(result, 0)
            report = json.loads((output / 'report.json').read_text())
            self.assertEqual(report['outcome'], 'fail')
            self.assertFalse(report['qualifies_cli_runtime'])
            self.assertIn('Native Windows', report['exception']['message'])
            self.assertEqual(list(output.glob('*.tmp')), [])


if __name__ == '__main__':
    unittest.main()
