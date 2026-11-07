"""Observe interrupted native installation and deliberate launcher recovery.

Only generated test scripts contain the interruption hooks. No candidate runs.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import base64
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from managed_helpers import build_module, retain_installer_failure, source_install, selection, with_minimum_launcher

if os.name == 'nt' and 'ASM_WINDOWS_EXE' in os.environ and 'ASM_WINDOWS_TARGET' in os.environ:
    import test_runtime as runtime
else:
    runtime = None

ANCHORS = {
    'before-store': '                held.CloseDescendants(newStore); newStore.Rename(bin,".asm-cli",false);',
    'after-store': '                Compatible(candidateMetadata,state.Metadata);\n            }\n            held.Recheck();',
    'repair-before-launcher': '            publish.Rename(bin,"asm.exe",root != null); committed=true; publish.Dispose();',
}
STREAM_BYTES = 65536


def readiness_bytes(boundary):
    if boundary not in ANCHORS:
        raise ValueError('Unknown installer interruption boundary.')
    return ('asm-installer-interruption-v1:' + boundary + '\n').encode('ascii')


def instrument_script(script, boundary, marker):
    """Insert one guarded test-only pause. A resumed hook throws before commit."""
    expected = readiness_bytes(boundary)
    text = script.decode('utf-8')
    anchor = ANCHORS[boundary]
    if text.count(anchor) != 1:
        raise ValueError('The installer interruption anchor is absent or ambiguous.')
    encoded_path = base64.b64encode(str(marker).encode('utf-8')).decode('ascii')
    encoded_marker = base64.b64encode(expected).decode('ascii')
    condition = 'repair && state != null' if boundary == 'repair-before-launcher' else (
        '!repair && state == null' if boundary == 'before-store' else '!repair && state != null')
    hook = '''
                Require(CONDITION,"The test interruption reached the wrong installer state.");
                ((Action)(() => {
                    string readyPath=Encoding.UTF8.GetString(Convert.FromBase64String("PATH"));
                    byte[] readyBytes=Convert.FromBase64String("MARKER");
                    using (FileStream ready=new FileStream(readyPath,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {
                        ready.Write(readyBytes,0,readyBytes.Length); ready.Flush(true);
                    }
                    System.Threading.Thread.Sleep(60000);
                    throw new InvalidOperationException("The bounded test interruption resumed without parent termination.");
                }))();
'''.replace('CONDITION', condition).replace('PATH', encoded_path).replace('MARKER', encoded_marker)
    if boundary == 'after-store':
        prefix = '                Compatible(candidateMetadata,state.Metadata);'
        replacement = prefix + hook + '\n            }\n            held.Recheck();'
    else:
        replacement = hook + anchor
    return text.replace(anchor, replacement, 1).encode('utf-8')


def marker_ready(path, expected):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, 'st_file_attributes', 0) & 0x400 or info.st_size > len(expected)):
        raise ValueError('The owned readiness marker has an unsafe identity or length.')
    with path.open('rb') as stream:
        raw = stream.read(len(expected) + 1)
    return raw == expected


def observe_interruption(argv, cwd, environment, marker, expected, receipt, *, timeout=90):
    """Terminate only this owned process after readiness; drain bounded raw pipes."""
    if not 6 <= timeout <= 90:
        raise ValueError('The interruption child deadline must be in [6, 90] seconds.')
    started = time.monotonic()
    receipt.update(argv=list(map(str, argv)), cwd=str(cwd), exit_code=None, ready_observed=False,
                   termination_requested=False, process_reaped=False, timed_out=False,
                   stdout_hex='', stderr_hex='', stdout='', stderr='', capture_errors=[])
    process = None
    readers, buffers = [], [bytearray(), bytearray()]
    overflow, lock = threading.Event(), threading.Lock()
    def drain(stream, index):
        try:
            while True:
                raw = os.read(stream.fileno(), 8192)
                if not raw:
                    break
                with lock:
                    remaining = STREAM_BYTES - len(buffers[index])
                    buffers[index].extend(raw[:remaining])
                if len(raw) > remaining:
                    overflow.set()
                    break
        except OSError as error:
            with lock:
                receipt['capture_errors'].append(str(error))
        finally:
            stream.close()
    try:
        process = subprocess.Popen(list(map(str, argv)), cwd=cwd, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        receipt['owned_pid'] = process.pid
        for index, stream in enumerate((process.stdout, process.stderr)):
            reader = threading.Thread(target=drain, args=(stream, index), daemon=True)
            readers.append(reader)
            reader.start()
        deadline = started + timeout - 5
        while process.poll() is None:
            if marker_ready(marker, expected):
                receipt['ready_observed'] = True
                receipt['marker_hex'] = expected.hex()
                if process.poll() is None:
                    process.terminate()
                    receipt['termination_requested'] = True
                break
            if overflow.is_set() or time.monotonic() >= deadline:
                receipt['timed_out'] = not overflow.is_set()
                break
            time.sleep(.01)
    except Exception as error:
        receipt['exception'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        if process is not None:
            try:
                if process.poll() is None and not receipt['termination_requested']:
                    process.kill()
                    receipt['forced_cleanup_termination'] = True
                try:
                    process.wait(timeout=3)
                    receipt['process_reaped'] = True
                except subprocess.TimeoutExpired:
                    process.kill()
                    receipt['forced_cleanup_termination'] = True
                    try:
                        process.wait(timeout=1)
                        receipt['process_reaped'] = True
                    except subprocess.TimeoutExpired:
                        receipt['capture_errors'].append('The owned installer did not exit within its reap bound.')
            except Exception as error:
                receipt['capture_errors'].append('Owned process cleanup failed: ' + str(error))
            receipt['exit_code'] = process.returncode
        grace = time.monotonic() + 1
        for reader in readers:
            reader.join(max(0, grace - time.monotonic()))
        with lock:
            for index, stream in enumerate(('stdout', 'stderr')):
                raw = bytes(buffers[index])
                receipt[stream + '_hex'] = raw.hex()
                receipt[stream] = raw.decode('utf-8', errors='replace')
                receipt[stream + '_bytes'] = len(raw)
        receipt.update(output_limit_exceeded=overflow.is_set(), capture_complete=not any(
            reader.is_alive() for reader in readers), seconds=round(time.monotonic() - started, 6))
    return receipt


@unittest.skipUnless(runtime is not None, 'Run through the native Windows runtime driver.')
class ManagedRecoveryTests(unittest.TestCase):
    # Alias only the fixture methods. Importing a TestCase class would duplicate
    # its entire suite when unittest loads this module.
    setUp = runtime.WindowsRuntimeTests.setUp if runtime else unittest.TestCase.setUp
    cli = runtime.WindowsRuntimeTests.cli if runtime else None

    def interrupt(self, data, boundary, *, repair=False):
        self.assertEqual(os.name, 'nt')
        source = self.work / (boundary + '-source.exe')
        script = self.work / (boundary + '-install.ps1')
        marker = self.work / (boundary + '-ready')
        self.assertFalse(marker.exists())
        source.write_bytes(data)
        generated = build_module('windows_bootstrap').render_source_installer(source, runtime.TARGET)
        instrumented = instrument_script(generated, boundary, marker)
        script.write_bytes(instrumented)
        runtime.TEST_ARTIFACTS.append({'role': 'interrupted-source-installer', 'boundary': boundary,
            'target': runtime.TARGET, 'bytes': len(instrumented),
            'sha256': hashlib.sha256(instrumented).hexdigest(),
            'generated_script_sha256': hashlib.sha256(generated).hexdigest(),
            'source_bytes': len(data), 'source_sha256': hashlib.sha256(data).hexdigest()})
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        self.assertTrue(powershell.is_file(), 'Windows PowerShell 5.1 or later is required.')
        argv = [powershell, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script]
        if repair:
            argv.append('-RepairLauncher')
        receipt = {'test': self.id(), 'boundary': boundary, 'fixture_inputs': [str(source), str(script)],
                   'candidate_executed_by_test': False}
        runtime.COMMANDS.append(receipt)
        try:
            observe_interruption(argv, self.work, self.environment, marker, readiness_bytes(boundary), receipt)
        finally:
            try:
                receipt['failure_evidence'] = str(retain_installer_failure(self.work, receipt))
            except Exception as error:
                receipt['failure_evidence_error'] = {'type': type(error).__name__, 'message': str(error)}
        self.assertNotIn('failure_evidence_error', receipt, receipt)
        self.assertTrue(receipt['ready_observed'], receipt)
        self.assertTrue(receipt['termination_requested'], receipt)
        self.assertTrue(receipt['process_reaped'], receipt)
        self.assertTrue(receipt['capture_complete'], receipt)
        self.assertFalse(receipt['timed_out'], receipt)
        self.assertFalse(receipt['output_limit_exceeded'], receipt)
        self.assertEqual(receipt['capture_errors'], [], receipt)
        self.assertNotEqual(receipt['exit_code'], 0, receipt)
        self.assertFalse((self.work / 'PACKAGE_EXECUTED').exists())
        return receipt

    def signature(self, path):
        rows = build_module('windows_bootstrap_smoke').inventory(path)
        self.assertTrue(rows)
        self.assertFalse(any('error' in row for row in rows), rows)
        return sorted(rows, key=lambda row: row['path'])

    def stages(self):
        return sorted((self.home / '.local/bin').glob('.asm-bootstrap-*'))

    def verify_selection(self, data):
        row, payload, raw = selection(self)
        self.assertEqual(payload.read_bytes(), data)
        self.assertEqual(row['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(row['size'], len(data))
        return payload, raw

    def test_interruption_before_store_publication_retains_stage_and_allows_new_install(self):
        data = runtime.ASM.read_bytes()
        self.interrupt(data, 'before-store')
        bin_path = self.home / '.local/bin'
        self.assertFalse((bin_path / 'asm.exe').exists())
        self.assertFalse((bin_path / '.asm-cli').exists())
        self.assertEqual(len(self.stages()), 1)
        stage = self.stages()[0]
        before = self.signature(stage)
        self.assertTrue((stage / 'store/current.tsv').is_file())
        digest = hashlib.sha256(data).hexdigest()
        self.assertEqual((stage / 'store/versions' / digest / 'asm.exe').read_bytes(), data)
        source_install(self, data, name='retry-initial')
        self.verify_selection(data)
        self.assertEqual((bin_path / 'asm.exe').read_bytes(), data)
        self.assertEqual(self.signature(stage), before)

    def test_interruption_after_store_publication_requires_explicit_launcher_repair(self):
        data = runtime.ASM.read_bytes()
        self.interrupt(data, 'after-store')
        bin_path = self.home / '.local/bin'
        store = bin_path / '.asm-cli'
        self.assertFalse((bin_path / 'asm.exe').exists())
        payload, raw = self.verify_selection(data)
        before = self.signature(store)
        source_install(self, data, name='refuse-implicit-repair', code=1)
        self.assertFalse((bin_path / 'asm.exe').exists())
        self.assertEqual(self.signature(store), before)
        source_install(self, data, name='explicit-repair', repair=True)
        self.assertEqual((bin_path / 'asm.exe').read_bytes(), data)
        self.assertEqual(selection(self)[2], raw)
        self.assertEqual(payload.read_bytes(), data)
        self.assertEqual(self.signature(store), before)

    def test_interrupted_launcher_repair_preserves_old_launcher_and_exact_selection(self):
        original = runtime.ASM.read_bytes()
        source_install(self, original)
        root = self.home / '.local/bin/asm.exe'
        store = root.parent / '.asm-cli'
        payload, raw = self.verify_selection(original)
        before, root_id = self.signature(store), (root.stat().st_dev, root.stat().st_ino)
        compatible = with_minimum_launcher(original, runtime.TARGET, '0.5.0')
        self.assertNotEqual(compatible, original)
        self.interrupt(compatible, 'repair-before-launcher', repair=True)
        self.assertEqual(root.read_bytes(), original)
        self.assertEqual((root.stat().st_dev, root.stat().st_ino), root_id)
        self.assertEqual(selection(self)[2], raw)
        self.assertEqual(payload.read_bytes(), original)
        self.assertEqual(self.signature(store), before)
        source_install(self, compatible, name='retry-repair', repair=True)
        self.assertEqual(root.read_bytes(), compatible)
        self.assertEqual(selection(self)[2], raw)
        self.assertEqual(payload.read_bytes(), original)
        self.assertEqual(self.signature(store), before)
        self.assertFalse((self.work / 'PACKAGE_EXECUTED').exists())


class RecoveryHookTests(unittest.TestCase):
    def test_readiness_requires_exact_bounded_single_link_file_bytes(self):
        expected = readiness_bytes('before-store')
        with tempfile.TemporaryDirectory(prefix='asm-recovery-marker-') as temporary:
            marker = Path(temporary) / 'ready'
            self.assertFalse(marker_ready(marker, expected))
            marker.write_bytes(expected[:-1])
            self.assertFalse(marker_ready(marker, expected))
            marker.write_bytes(expected + b'extra')
            with self.assertRaises(ValueError):
                marker_ready(marker, expected)
            marker.write_bytes(expected)
            self.assertTrue(marker_ready(marker, expected))
            os.link(marker, Path(temporary) / 'alias')
            with self.assertRaises(ValueError):
                marker_ready(marker, expected)

    def test_each_actual_anchor_is_unique_and_changed_scripts_are_rejected(self):
        template = (Path(__file__).resolve().parents[2] / 'tools/windows-install.ps1.in').read_bytes()
        marker = Path('C:/owned/ready')
        for boundary, anchor in ANCHORS.items():
            with self.subTest(boundary=boundary):
                result = instrument_script(template, boundary, marker)
                self.assertEqual(result.count(b'System.Threading.Thread.Sleep(60000);'), 1)
                self.assertIn(b'FileMode.CreateNew', result)
                self.assertIn(b'bounded test interruption resumed', result)
                for changed in (template.replace(anchor.encode(), b'', 1), template + anchor.encode()):
                    with self.assertRaises(ValueError):
                        instrument_script(changed, boundary, marker)
        with self.assertRaises(ValueError):
            instrument_script(template, 'unknown', marker)

    def test_actual_owned_child_is_interrupted_only_after_exact_marker(self):
        with tempfile.TemporaryDirectory(prefix='asm-recovery-host-') as temporary:
            marker = Path(temporary) / 'ready'
            expected = readiness_bytes('before-store')
            body = ('import os,time; from pathlib import Path; '
                    'os.write(1,b"ready stdout"); os.write(2,b"ready stderr"); '
                    f'Path({str(marker)!r}).write_bytes({expected!r}); time.sleep(30)')
            receipt = {}
            observe_interruption([sys.executable, '-c', body], temporary, dict(os.environ),
                                 marker, expected, receipt, timeout=10)
            self.assertTrue(receipt['ready_observed'], receipt)
            self.assertTrue(receipt['termination_requested'], receipt)
            self.assertTrue(receipt['process_reaped'], receipt)
            self.assertTrue(receipt['capture_complete'], receipt)
            self.assertEqual(receipt['capture_errors'], [], receipt)
            self.assertEqual(bytes.fromhex(receipt['stdout_hex']), b'ready stdout')
            self.assertEqual(bytes.fromhex(receipt['stderr_hex']), b'ready stderr')
            self.assertNotEqual(receipt['exit_code'], 0)


if __name__ == '__main__':
    unittest.main()
