"""Observe native installed Windows launch and recovery through asm.exe.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import test_runtime as runtime
from fixture_security import own_home_directories, own_path, own_directory
from managed_helpers import source_install, selection, assert_no_stage, build_module, with_minimum_launcher


class ManagedRuntimeTests(unittest.TestCase):
    setUp = runtime.WindowsRuntimeTests.setUp
    metadata = runtime.WindowsRuntimeTests.metadata
    junction = runtime.WindowsRuntimeTests.junction
    project = runtime.WindowsRuntimeTests.project

    def cli(self, *args, **kwargs):
        kwargs.setdefault('binary', getattr(self, 'installed', runtime.ASM))
        return runtime.WindowsRuntimeTests.cli(self, *args, **kwargs)

    @classmethod
    def setUpClass(cls):
        import tempfile
        import managed_console
        cls.fixtures = tempfile.TemporaryDirectory(prefix='asm-managed-native-fixtures-')
        cls.addClassCleanup(cls.fixtures.cleanup)
        cls.console_fixture = managed_console.build_fixture(
            runtime.ROOT, Path(cls.fixtures.name), runtime.TARGET, runtime.VERSION,
            runtime.TOOLCHAIN_BIN, cls.build_command)
        data = cls.console_fixture.read_bytes()
        runtime.TEST_ARTIFACTS.append({'role': 'managed-console-native-test-fixture', 'target': runtime.TARGET,
                                       'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                       'source_sha256': hashlib.sha256(
                                           (runtime.ROOT / 'tests/windows/managed_console.c').read_bytes()).hexdigest()})
        smoke = build_module('windows_bootstrap_smoke')
        marker = Path(cls.fixtures.name) / 'never-execute.s'
        cls.never_execute_marker = Path(cls.fixtures.name) / 'SOURCE_CANDIDATE_EXECUTED'
        marker.write_text(smoke.marker_assembly(runtime.TARGET, runtime.VERSION,
                                                cls.never_execute_marker), encoding='utf-8')
        obj = marker.with_suffix('.obj')
        cls.never_execute = marker.with_suffix('.exe')
        triple = 'aarch64-pc-windows-msvc' if runtime.ARM64 else 'x86_64-pc-windows-msvc'
        cls.build_command([runtime.TOOLCHAIN_BIN / 'clang.exe', '--no-default-config',
                           '--target=' + triple, '-c', marker, '-o', obj])
        cls.build_command([runtime.TOOLCHAIN_BIN / 'lld-link.exe',
                           '/machine:' + ('arm64' if runtime.ARM64 else 'x64'), '/entry:_start',
                           '/subsystem:console', '/nodefaultlib', '/nxcompat', '/dynamicbase', '/Brepro',
                           '/out:' + str(cls.never_execute), obj, 'kernel32.lib'])

    @classmethod
    def build_command(cls, argv):
        result = subprocess.run(list(map(str, argv)), cwd=runtime.ROOT, capture_output=True, timeout=120)
        runtime.COMMANDS.append({'test': 'ManagedRuntimeTests.setUpClass', 'argv': list(map(str, argv)),
                                 'exit_code': result.returncode,
                                 'stdout': result.stdout.decode('utf-8', errors='replace')[:65536],
                                 'stderr': result.stderr.decode('utf-8', errors='replace')[:65536]})
        if result.returncode:
            raise RuntimeError((argv, result.stdout, result.stderr))

    def install(self):
        source_install(self, runtime.ASM.read_bytes())
        self.installed = self.home / '.local/bin/asm.exe'
        self.launcher = self.installed.read_bytes()
        self.row, self.payload, self.record = selection(self)
        self.assertEqual(self.launcher, runtime.ASM.read_bytes())
        self.assertEqual(self.payload.read_bytes(), self.launcher)
        return self.installed

    def select_fixture(self, data):
        """Deliberately select a bounded native fixture; this grants no provenance."""
        layout = build_module('windows_layout')
        metadata = layout.read_pe_metadata(data, runtime.TARGET)
        digest = hashlib.sha256(data).hexdigest()
        store = self.home / '.local/bin/.asm-cli'
        directory = store / 'versions' / digest
        directory.mkdir()
        own_directory(directory, self.work)
        payload = directory / 'asm.exe'
        payload.write_bytes(data)
        own_path(payload, self.work)
        record = layout.encode_record(metadata['version'], runtime.TARGET, len(data), digest,
                                      metadata['minimum_launcher'])
        (store / 'current.tsv').write_bytes(record)
        return payload, record

    def test_installed_first_project_doctor_run_and_test(self):
        self.install()
        self.assertIn(runtime.VERSION, self.cli('version', binary=self.installed).stdout)
        self.cli('doctor', binary=self.installed)
        project = self.work / 'first installed project'
        self.cli('new', project, binary=self.installed)
        self.assertEqual(self.cli('run', cwd=project, binary=self.installed).stdout, 'Hello from asm!\n')
        self.cli('test', cwd=project, binary=self.installed)
        self.assertEqual(self.installed.read_bytes(), self.launcher)
        self.assertEqual(selection(self)[2], self.record)
        assert_no_stage(self)

    def test_missing_managed_state_never_falls_back_to_embedded_cli(self):
        installed = self.home / '.local/bin/asm.exe'
        installed.parent.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        installed.write_bytes(runtime.ASM.read_bytes())
        own_path(installed, self.work)
        self.cli('version', binary=installed, code=1)
        self.assertEqual(installed.read_bytes(), runtime.ASM.read_bytes())
        self.assertFalse((installed.parent / '.asm-cli').exists())

    def test_corrupt_records_and_missing_marker_preserve_installation(self):
        self.install()
        current = self.home / '.local/bin/.asm-cli/current.tsv'
        marker = current.with_name('layout')
        malformed = [b'', self.record[:-1], self.record + b'\n', b'\xef\xbb\xbf' + self.record,
                     self.record.replace(b'\n', b'\r\n'), self.record + self.record,
                     self.record.replace(self.row['sha256'].encode(), b'0' * 64),
                     self.record.replace(b'\t1\t0.6.0\n', b'\t1\t0.7.0\n'),
                     self.record.replace(b'\t1\t', b'\t2\t'), b'x' * 257]
        for raw in malformed:
            with self.subTest(bytes=len(raw)):
                current.write_bytes(raw)
                self.cli('version', '--json', binary=self.installed, code=1)
                self.assertEqual(current.read_bytes(), raw)
                self.assertEqual(self.installed.read_bytes(), self.launcher)
                self.assertEqual(self.payload.read_bytes(), self.launcher)
        current.write_bytes(self.record)
        marker.unlink()
        self.cli('version', binary=self.installed, code=1)
        self.assertFalse(marker.exists())
        self.assertEqual(current.read_bytes(), self.record)

    def test_home_disagreement_never_runs_embedded_launcher(self):
        self.install()
        other = self.work / 'other home'
        other.mkdir()
        env = dict(self.environment, HOME=str(other), USERPROFILE=str(other))
        self.cli('version', '--json', binary=self.installed, env=env, code=1)
        self.assertEqual(selection(self)[2], self.record)
        self.assertEqual(list(other.iterdir()), [])

    def test_changed_or_hardlinked_payload_is_rejected_before_execution(self):
        self.install()
        original = self.payload.read_bytes()
        changed = original[:-1] + bytes([original[-1] ^ 1])
        self.payload.write_bytes(changed)
        self.cli('version', binary=self.installed, code=1)
        self.assertEqual(self.payload.read_bytes(), changed)
        self.assertEqual((self.home / '.local/bin/.asm-cli/current.tsv').read_bytes(), self.record)
        self.payload.write_bytes(original)
        alias = self.work / 'payload-hardlink.exe'
        os.link(self.payload, alias)
        self.cli('version', binary=self.installed, code=1)
        self.assertEqual(alias.read_bytes(), original)
        self.assertEqual(self.installed.read_bytes(), self.launcher)

    def test_explicit_launcher_repair_preserves_active_payload_selection(self):
        self.install()
        self.installed.unlink()
        source_install(self, self.launcher, name='repair', repair=True)
        self.assertEqual(selection(self)[2], self.record)
        self.assertEqual(self.payload.read_bytes(), self.launcher)
        self.assertEqual(self.installed.read_bytes(), self.launcher)
        self.cli('version', binary=self.installed)
        assert_no_stage(self)

    def test_selected_digest_directory_junction_is_rejected_and_preserved(self):
        self.install()
        directory = self.payload.parent
        outside = self.work / 'displaced-digest-directory'
        directory.rename(outside)
        self.junction(directory, outside)
        try:
            self.cli('version', '--json', code=1)
            self.assertEqual((outside / 'asm.exe').read_bytes(), self.launcher)
            self.assertEqual((self.home / '.local/bin/.asm-cli/current.tsv').read_bytes(), self.record)
            self.assertEqual(self.installed.read_bytes(), self.launcher)
        finally:
            os.rmdir(directory)
            outside.rename(directory)
        self.cli('version')
        self.assertEqual(selection(self)[2], self.record)

    def test_mutable_managed_state_is_rejected_before_execution(self):
        self.install()
        store = self.home / '.local/bin/.asm-cli'
        tool = Path(os.environ['SystemRoot']) / 'System32/icacls.exe'
        for path in (store, store / 'current.tsv', self.payload):
            with self.subTest(path=path.name):
                def acl(*arguments):
                    argv = [str(tool), str(path), *arguments]
                    result = subprocess.run(argv, capture_output=True, timeout=10)
                    runtime.COMMANDS.append({'test': self.id(), 'argv': argv, 'exit_code': result.returncode,
                                             'stdout': result.stdout.decode(errors='replace')[:65536],
                                             'stderr': result.stderr.decode(errors='replace')[:65536]})
                    self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
                try:
                    acl('/grant', '*S-1-1-0:(M)')
                    self.cli('version', '--json', code=1)
                    self.assertEqual(self.installed.read_bytes(), self.launcher)
                    self.assertEqual(self.payload.read_bytes(), self.launcher)
                    self.assertEqual((store / 'current.tsv').read_bytes(), self.record)
                finally:
                    acl('/remove:g', '*S-1-1-0')
                self.cli('version')
                self.assertEqual(selection(self)[2], self.record)

    def test_unfamiliar_store_is_preserved_and_not_adopted(self):
        store = self.home / '.local/bin/.asm-cli'
        store.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        own_directory(store, self.work)
        existing = store / 'user-data.txt'
        existing.write_bytes(b'Unrelated files must remain.\n')
        source_install(self, runtime.ASM.read_bytes(), code=1)
        self.assertEqual(existing.read_bytes(), b'Unrelated files must remain.\n')
        self.assertEqual(list(store.iterdir()), [existing])
        self.assertFalse((store.parent / 'asm.exe').exists())

    def test_unicode_and_shell_punctuation_paths_remain_literal(self):
        self.home = self.work / "源 home & literal ' path"
        self.home.mkdir()
        own_directory(self.home, self.work)
        self.environment.update(HOME=str(self.home), USERPROFILE=str(self.home))
        source_install(self, runtime.ASM.read_bytes(), name="源 artifact & ' literal")
        self.installed = self.home / '.local/bin/asm.exe'
        project = self.work / "源 project & ' literal"
        self.cli('new', project, binary=self.installed)
        self.assertEqual(self.cli('run', cwd=project, binary=self.installed).stdout, 'Hello from asm!\n')
        self.assertEqual(selection(self)[1].read_bytes(), runtime.ASM.read_bytes())

    def test_unrelated_existing_command_requires_explicit_replacement(self):
        installed = self.home / '.local/bin/asm.exe'
        installed.parent.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        unrelated = b'An unrelated existing command must remain byte-for-byte.\n'
        installed.write_bytes(unrelated)
        own_path(installed, self.work)
        source_install(self, runtime.ASM.read_bytes(), code=1)
        self.assertEqual(installed.read_bytes(), unrelated)
        self.assertFalse((installed.parent / '.asm-cli').exists())
        source_install(self, runtime.ASM.read_bytes(), name='replace', replace=True)
        self.assertEqual(selection(self)[1].read_bytes(), runtime.ASM.read_bytes())
        self.cli('version', binary=installed)

    def test_launcher_preserves_full_windows_payload_exit_status(self):
        self.install()
        self.select_fixture(self.console_fixture.read_bytes())
        for status in (37, 259, 0x80000001, 0xffffffff):
            with self.subTest(status=status):
                result = self.cli('--exit', str(status), binary=self.installed, code=status)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, '')
        self.assertEqual(self.installed.read_bytes(), self.launcher)

    def test_launcher_preserves_literal_arguments_through_startup_capacity(self):
        self.install()
        self.select_fixture(self.console_fixture.read_bytes())
        tokens = ['space token', 'double"quote', '', 'back\\slash\\', 'Grüße 世界🙂']
        for count in (257, 1023):
            with self.subTest(total_arguments=count):
                arguments = [tokens[index % len(tokens)] for index in range(count - 3)]
                result = self.cli('--check-args', str(count), *arguments)
                self.assertEqual(result.stdout, '')
        arguments = [tokens[index % len(tokens)] for index in range(1024 - 3)]
        self.cli('--check-args', '1024', *arguments, code=2 if runtime.ARM64 else 1)
        self.assertEqual(self.installed.read_bytes(), self.launcher)

    def test_incompatible_payload_fails_before_child_execution(self):
        self.install()
        self.assertFalse(self.never_execute_marker.exists())
        data = with_minimum_launcher(self.never_execute.read_bytes(), runtime.TARGET, '9.0.0')
        _, record = self.select_fixture(data)
        self.cli('--exit', '0', binary=self.installed, code=1)
        self.assertFalse(self.never_execute_marker.exists())
        self.assertEqual((self.home / '.local/bin/.asm-cli/current.tsv').read_bytes(), record)
        self.assertEqual(self.installed.read_bytes(), self.launcher)

    def test_launcher_preserves_binary_input_and_both_output_streams(self):
        self.install()
        self.select_fixture(self.console_fixture.read_bytes())
        data = b'first line\r\nNUL\x00last\xff ' + '世界🙂'.encode('utf-8')
        argv = [str(self.installed), '--stdio']
        result = subprocess.run(argv, input=data, cwd=self.work, env=self.environment,
                                capture_output=True, timeout=10)
        runtime.COMMANDS.append({'test': self.id(), 'argv': argv, 'exit_code': result.returncode,
                                 'input_hex': data.hex(), 'stdout_hex': result.stdout.hex(),
                                 'stderr_hex': result.stderr.hex()})
        self.assertEqual(result.returncode, 37)
        self.assertEqual(result.stdout, data)
        self.assertEqual(result.stderr, data)
        self.assertEqual(self.installed.read_bytes(), self.launcher)

    def console_event(self, event, status):
        import managed_console
        self.install()
        self.select_fixture(self.console_fixture.read_bytes())
        ready = self.work / ('console-ready-' + str(event))
        report = managed_console.observe_console(
            self.console_fixture, self.installed, self.work, self.environment,
            ready, event, status)
        runtime.COMMANDS.append({'test': self.id(), 'native_console_fixture': report})
        self.assertEqual(report['exit_code'], 0, report)
        self.assertEqual(report['controller']['status'], 'complete', report)
        self.assertEqual(report['controller']['exit_code'], status, report)
        self.assertEqual(report['controller']['payload_exit_code'], status, report)
        self.assertEqual(report['controller']['requested_exit_code'], status, report)
        self.assertTrue(report['controller']['ready'], report)
        self.assertTrue(report['controller']['event_sent'], report)
        self.assertTrue(report['controller']['launcher_reaped'], report)
        self.assertTrue(report['controller']['payload_reaped'], report)
        self.assertLessEqual(report['controller']['elapsed_ms'], 20000, report)
        self.assertEqual(self.installed.read_bytes(), self.launcher)

    def test_owned_console_ctrl_c_reaches_payload_and_preserves_exit(self):
        self.console_event(0, 0x80000031)

    def test_owned_console_ctrl_break_reaches_payload_and_preserves_exit(self):
        self.console_event(1, 0x80000032)

    def test_installed_application_can_run_beyond_two_minutes(self):
        self.install()
        runtime.WindowsRuntimeTests.test_deliberate_application_runs_beyond_two_minutes(self)

    def test_source_bootstrap_does_not_execute_even_a_valid_candidate(self):
        candidate = self.never_execute.read_bytes()
        self.assertFalse(self.never_execute_marker.exists())
        source_install(self, candidate, name='never-execute')
        self.assertFalse(self.never_execute_marker.exists())
        self.assertEqual(selection(self)[1].read_bytes(), candidate)

    def test_package_output_cannot_modify_cli_store_or_alias(self):
        self.install()
        data = runtime.ASM.read_bytes()
        self.artifact.write_bytes(data)
        self.index.write_bytes((runtime.HEADER + self.metadata(data, kind='executable')).encode())
        store = self.home / '.local/bin/.asm-cli'
        destinations = [store / 'new-package.exe', self.payload.parent / 'new-package.exe',
                        self.home / '.local/bin/.AsM-ClI/versions' / self.row['sha256'] / 'new-package.exe']
        alias = self.work / 'cli-store-junction'
        self.junction(alias, store)
        destinations.append(alias / 'new-package.exe')
        for output in destinations:
            with self.subTest(output=str(output)):
                self.cli('install', runtime.PACKAGE, '--index', self.index, '--artifact', self.artifact,
                         '--output', output, binary=self.installed, code=1)
                self.assertFalse(output.exists())
                self.assertEqual(selection(self)[2], self.record)
                self.assertEqual(self.installed.read_bytes(), self.launcher)
                self.cli('fetch', runtime.PACKAGE, '--kind', 'executable', '--index', self.index,
                         '--artifact', self.artifact, '--output', output, binary=runtime.ASM, code=1)
                self.assertFalse(output.exists())
                self.assertEqual(selection(self)[2], self.record)
        outside = self.work / 'outside-fetch.exe'
        self.cli('fetch', runtime.PACKAGE, '--kind', 'executable', '--index', self.index,
                 '--artifact', self.artifact, '--output', outside,
                 cwd=self.payload.parent, binary=runtime.ASM, code=1)
        self.assertFalse(outside.exists())
        env = dict(self.environment, HOME=str(store), USERPROFILE=str(store))
        self.cli('installed', '--json', binary=runtime.ASM, env=env, code=1)
        self.assertFalse((store / '.local').exists())
        self.assertEqual(selection(self)[2], self.record)
        # A normal destination still works through the same installed command.
        output = self.work / 'ordinary-package.exe'
        self.cli('install', runtime.PACKAGE, '--index', self.index, '--artifact', self.artifact,
                 '--output', output, binary=self.installed)
        self.assertEqual(output.read_bytes(), data)
        self.cli('uninstall', runtime.PACKAGE, binary=self.installed)
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
