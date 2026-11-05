"""Host checks for diagnostic generation; these do not qualify native Windows.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def module_at(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DiagnosticHelpers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.diagnostic = module_at('diagnostic_helpers', ROOT / 'cli/windows/x86_64/native_diagnostics.py')
        cls.generator = module_at('diagnostic_generator', ROOT / 'tools/windows_x64.py')
        cls.source = cls.generator.prepare(ROOT / 'cli/asm.s')
        cls.helpers = module_at('diagnostic_runtime_helpers', ROOT / 'tests/windows/runtime_helpers.py')

    def test_actual_managed_source_and_fault_variants_assemble(self):
        clang = shutil.which('clang')
        self.assertIsNotNone(clang, 'A local clang is required for this host assembly check.')
        variants = {'current': self.source,
                    'activation': self.helpers.final_replacement_failure(self.source, False),
                    'snapshot': self.helpers.snapshot_source(self.source, False)}
        for stage in ('payload_flush', 'record_write', 'record_flush'):
            variants[stage] = self.helpers.preparation_failure(self.source, False, stage)
        with tempfile.TemporaryDirectory() as directory:
            for name, source in variants.items():
                with self.subTest(name=name):
                    generated = self.diagnostic.instrument_source(source)
                    assembly = Path(directory) / (name + '.s')
                    obj = assembly.with_suffix('.obj')
                    assembly.write_text(generated)
                    result = subprocess.run([clang, '--no-default-config', '--target=x86_64-pc-windows-msvc',
                        '-c', str(assembly), '-o', str(obj)], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(obj.read_bytes()[:2], b'\x64\x86')

    def test_unrelated_api_call_does_not_change_scoped_instrumentation(self):
        extra = '\n.text\nunrelated_diagnostic_fixture:\n    call NtSetInformationFile\n    ret\n'
        generated = self.diagnostic.instrument_source(self.source + extra)
        self.assertIn(extra, generated)

    def test_missing_or_duplicate_scoped_calls_fail_with_location(self):
        start = self.source.index('\nwin_managed_rename_fd:\n')
        end = self.source.index('\nwin_managed_same_fd:\n', start)
        body = self.source[start:end]
        for replacement in ('', '    call NtSetInformationFile\n' * 2):
            with self.subTest(replacement=replacement):
                source = self.source[:start] + body.replace('    call NtSetInformationFile\n', replacement) + self.source[end:]
                with self.assertRaisesRegex(ValueError, 'win_managed_rename_fd.*NtSetInformationFile'):
                    self.diagnostic.instrument_source(source)

    def test_missing_managed_commit_hook_cannot_fall_back_to_legacy(self):
        source = self.source.replace('win_managed_record_write:\n', 'changed_record_write:\n')
        with self.assertRaisesRegex(ValueError, 'win_managed_record_write'):
            self.diagnostic.instrument_source(source)

    def test_runtime_build_keeps_marker_bytes_and_extra_objects(self):
        with mock.patch.dict(os.environ, {'ASM_WINDOWS_EXE': 'diagnostic.exe',
                                         'ASM_WINDOWS_TARGET': 'x86_64-windows'}):
            sys.path.insert(0, str(ROOT / 'tests/windows'))
            try:
                runtime = module_at('diagnostic_build_runtime', ROOT / 'tests/windows/test_runtime.py')
            finally:
                sys.path.pop(0)
        case = self.diagnostic.update_diagnostic_case(runtime)
        with tempfile.TemporaryDirectory() as directory:
            case.fixture = Path(directory)
            case.clang, case.linker = Path('clang.exe'), Path('lld-link.exe')
            case.triple = 'x86_64-pc-windows-msvc'
            barrier = case.fixture / 'barrier.obj'
            barrier.write_bytes(b'owned test object')
            smoke = runtime.build_module('windows_bootstrap_smoke')
            marker = smoke.marker_assembly('x86_64-windows', '99.1.0', case.fixture / 'MARKER')

            def compile_fixture(argv, **options):
                # Only the external compiler/linker is replaced. The real
                # runtime build method writes source and constructs both calls.
                for argument in argv:
                    if argument.startswith('/out:'):
                        Path(argument[5:]).write_bytes(b'host test PE placeholder')
                return subprocess.CompletedProcess(argv, 0, '', '')

            with mock.patch.object(runtime.subprocess, 'run', side_effect=compile_fixture):
                for source, name in [(marker, 'marker-next'), (self.source, 'current')]:
                    case.build_cli(source, name, [barrier])
                    output = case.fixture / ('diagnostic-' + name + '.s')
                    if name == 'marker-next':
                        self.assertEqual(output.read_text(), marker)
                    else:
                        self.assertIn('win_diag_process_log:', output.read_text())
                    self.assertIn(str(barrier), runtime.COMMANDS[-1]['argv'])
                    self.assertEqual(runtime.COMMANDS[-2]['argv'].count('--no-default-config'), 1)
            self.assertEqual(len(runtime.TEST_ARTIFACTS), 2)

    def test_collection_error_keeps_location_partial_rows_and_qualification(self):
        for message in ('', 'anchor failure ' + 'x' * 20000):
            with self.subTest(message_length=len(message)), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / 'evidence.json'
                report = {'native_qualification': False, 'commands': [{'exit_code': 7}]}
                def failing_anchor():
                    raise AssertionError(message)
                self.assertEqual(self.diagnostic.collect_evidence(destination, report, failing_anchor), 1)
                saved = json.loads(destination.read_text())
                self.assertFalse(saved['native_qualification'])
                self.assertEqual(saved['commands'], [{'exit_code': 7}])
                error = saved['collection_error']
                self.assertTrue(error['message'])
                self.assertIn('failing_anchor', error['traceback'])
                self.assertLessEqual(len(error['traceback']), 8192)
                self.assertLessEqual(len(error['message']), 1024)

    def test_positive_probe_does_not_report_skips_or_failures_as_pass(self):
        for skip in (False, True):
            with self.subTest(skip=skip):
                class Probe(unittest.TestCase):
                    def test_update_replaces_exact_bytes_after_three_provenance_bindings(self):
                        if skip:
                            self.skipTest('native fixture unavailable')
                        self.fail('positive update did not complete')
                report = {'commands': [], 'native_qualification': False}
                with mock.patch.object(self.diagnostic, 'update_diagnostic_case', return_value=Probe):
                    self.diagnostic.update_probe(report, Path('diagnostic.exe'))
                self.assertEqual(report['update_probe']['outcome'], 'fail')
                self.assertEqual(report['update_probe']['tests_run'], 1)
                self.assertFalse(report['update_probe']['native_qualification'])

    def test_probe_binds_canonical_runtime_until_fixture_finishes_and_restores_state(self):
        previous = types.ModuleType('prior_runtime')
        environment = {'ASM_WINDOWS_EXE': 'prior.exe', 'ASM_WINDOWS_TARGET': 'aarch64-windows'}
        def fixture_case(runtime):
            class Probe(unittest.TestCase):
                def test_update_replaces_exact_bytes_after_three_provenance_bindings(self):
                    import test_runtime
                    self.assertIs(test_runtime, runtime)
                    self.assertEqual(os.environ['ASM_WINDOWS_EXE'], 'diagnostic.exe')
                    self.assertEqual(os.environ['ASM_WINDOWS_TARGET'], 'x86_64-windows')
                    test_runtime.COMMANDS.append({'canonical_runtime': True})
            return Probe
        with mock.patch.dict(sys.modules, {'test_runtime': previous}), mock.patch.dict(os.environ, environment):
            report = {'commands': [], 'native_qualification': False}
            with mock.patch.object(self.diagnostic, 'update_diagnostic_case', side_effect=fixture_case):
                self.diagnostic.update_probe(report, Path('diagnostic.exe'))
            self.assertIs(sys.modules['test_runtime'], previous)
            self.assertEqual(os.environ['ASM_WINDOWS_EXE'], 'prior.exe')
            self.assertEqual(os.environ['ASM_WINDOWS_TARGET'], 'aarch64-windows')
        self.assertEqual(report['update_probe']['outcome'], 'pass', report)
        self.assertEqual(report['commands'], [{'canonical_runtime': True}])

    def test_diagnostic_cli_retains_raw_bytes_and_rejects_unframed_stderr(self):
        with mock.patch.dict(os.environ, {'ASM_WINDOWS_EXE': 'diagnostic.exe',
                                         'ASM_WINDOWS_TARGET': 'x86_64-windows'}):
            sys.path.insert(0, str(ROOT / 'tests/windows'))
            try:
                runtime = module_at('diagnostic_cli_runtime', ROOT / 'tests/windows/test_runtime.py')
            finally:
                sys.path.pop(0)
        case_type = self.diagnostic.update_diagnostic_case(runtime)
        trace = (b'NT 00000000 component=asm.exe\n'
                 b'STAT mode=000081C0 owner=00000001 links=00000001\n'
                 b'PROC stage=0000001A result=C0000022 error=00000005\n')
        with tempfile.TemporaryDirectory() as directory:
            case = case_type('test_update_replaces_exact_bytes_after_three_provenance_bindings')
            case.work, case.environment = Path(directory), {}
            for extra, code in [(b'', 0), (b'unframed warning\n', 0),
                                (b'PROC stage=FFFFFFFF result=00000000 error=00000000\n', 0),
                                (b'{"ok":false}\n', 1)]:
                with self.subTest(extra=extra, code=code):
                    raw = trace + extra
                    result = subprocess.CompletedProcess(['diagnostic.exe'], code, b'{}\n', raw)
                    with mock.patch.object(runtime.subprocess, 'run', return_value=result):
                        if code == 0 and extra:
                            with self.assertRaises(AssertionError):
                                case.cli('version')
                        else:
                            observed = case.cli('version', code=code)
                            self.assertEqual(observed.stderr, extra.decode())
                    self.assertEqual(bytes.fromhex(runtime.COMMANDS[-1]['stderr_hex']), raw)
                    self.assertEqual(runtime.COMMANDS[-1]['stderr'], raw.decode())
            timeout = subprocess.TimeoutExpired(['diagnostic.exe'], 30,
                output=b'partial stdout', stderr=trace)
            with mock.patch.object(runtime.subprocess, 'run', side_effect=timeout):
                with self.assertRaises(subprocess.TimeoutExpired):
                    case.cli('version')
            self.assertTrue(runtime.COMMANDS[-1]['timed_out'])
            self.assertEqual(bytes.fromhex(runtime.COMMANDS[-1]['stderr_hex']), trace)


if __name__ == '__main__':
    unittest.main()
