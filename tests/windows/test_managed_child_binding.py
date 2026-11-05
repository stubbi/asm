"""Observe test-injected refusal after the real suspended-child image check.

This test does not claim a real Windows image-mismatch attack.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import threading
import time
import unittest

from managed_helpers import build_module, retain_installer_failure, selection, source_install

ROOT = Path(__file__).resolve().parents[2]
MAGIC = b'ASMCB1\r\n'
RECEIPT_BYTES = 40

if os.name == 'nt' and 'ASM_WINDOWS_EXE' in os.environ and 'ASM_WINDOWS_TARGET' in os.environ:
    import test_runtime as runtime
else:
    runtime = None


def observer_call(arm64):
    """Preserve live state around the C observer, then force only match status.

    The real adapter has returned. ARM64 x19 and x64 win_process_handle own
    the suspended child. Save volatile registers, vector lanes, flags and LR.
    The only intentional change is x9/RAX=-116 before the original branch.
    """
    if arm64:
        lines = ['    sub sp, sp, #672']
        lines += [f'    stp x{i}, x{i + 1}, [sp, #{i * 8}]' for i in range(0, 18, 2)]
        lines += ['    str x30, [sp, #144]', '    mrs x16, nzcv', '    str x16, [sp, #152]']
        lines += [f'    stp q{i}, q{i + 1}, [sp, #{160 + i * 16}]' for i in range(0, 32, 2)]
        lines += ['    mov x0, x19', '    mov x1, x9', '    bl asm_test_child_binding']
        lines += [f'    ldp q{i}, q{i + 1}, [sp, #{160 + i * 16}]' for i in range(0, 32, 2)]
        lines += ['    ldr x16, [sp, #152]', '    msr nzcv, x16', '    ldr x30, [sp, #144]']
        lines += [f'    ldp x{i}, x{i + 1}, [sp, #{i * 8}]' for i in range(0, 18, 2)]
        lines += ['    add sp, sp, #672', '    mov x9, #-116']
    else:
        registers = ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11']
        lines = ['    pushfq'] + ['    push ' + reg for reg in registers]
        lines += ['    sub rsp, 128']
        lines += [f'    movdqu [rsp + {32 + i * 16}], xmm{i}' for i in range(6)]
        lines += ['    mov rcx, [rip + win_process_handle]', '    mov rdx, rax',
                  '    call asm_test_child_binding']
        lines += [f'    movdqu xmm{i}, [rsp + {32 + i * 16}]' for i in range(6)]
        lines += ['    add rsp, 128'] + ['    pop ' + reg for reg in reversed(registers)]
        lines += ['    popfq', '    mov rax, -116']
    return '\n'.join(lines) + '\n'


def instrument_source(source, arm64):
    """Require one actual launcher call and retain the real class-44 operation."""
    begin = '\nwin_managed_launch:\n'
    end = '\nwin_managed_ctrl:\n' if arm64 else '\nwin_managed_control:\n'
    call = '    ARM_CALL win_child_image_matches\n' if arm64 else '    call win_child_image_matches\n'
    branch = '    cbnz x9, .Lwml_reject\n' if arm64 else '    test rax, rax\n    jnz .Lwml_terminate\n'
    if source.count(begin) != 1 or source.count(end) != 1:
        raise ValueError('The dedicated launcher routine is absent or ambiguous.')
    start, stop = source.index(begin), source.index(end)
    if stop <= start:
        raise ValueError('The dedicated launcher routine has invalid boundaries.')
    body = source[start:stop]
    anchor = call + branch
    if body.count(call) != 1 or body.count(anchor) != 1:
        raise ValueError('The suspended-child binding call is absent or ambiguous.')
    changed = body.replace(anchor, call + observer_call(arm64) + branch, 1)
    return source[:start] + changed + source[stop:]


def decode_receipt(raw, controller_pid):
    """Decode one exact fixed-width receipt. It is test evidence, not authority."""
    if len(raw) != RECEIPT_BYTES or raw[:8] != MAGIC:
        raise ValueError('The child-binding observer receipt is malformed.')
    handle, child_pid, owner_pid, actual_match, launcher_pid, reserved = struct.unpack('<QIIqII', raw[8:])
    if (not 0 < handle < 0xffffffffffffffff or not child_pid or not launcher_pid
            or owner_pid != controller_pid or reserved):
        raise ValueError('The child-binding observer receipt has invalid fields.')
    return {'duplicated_handle': handle, 'child_pid': child_pid, 'controller_pid': owner_pid,
            'actual_match': actual_match, 'launcher_pid': launcher_pid}


def observe_child(receipt_path, row):
    """Wait on the transferred handle and always close it; force cleanup on failure."""
    import ctypes
    from ctypes import wintypes
    info = receipt_path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, 'st_file_attributes', 0) & 0x400 or info.st_size != RECEIPT_BYTES):
        raise ValueError('The child-binding receipt has an unsafe identity or length.')
    raw = receipt_path.read_bytes()
    row['receipt_hex'] = raw.hex()
    row.update(decode_receipt(raw, os.getpid()))
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetProcessId.argtypes = [wintypes.HANDLE]
    kernel.GetProcessId.restype = wintypes.DWORD
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetExitCodeProcess.restype = wintypes.BOOL
    kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.TerminateProcess.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = row['duplicated_handle']
    signaled = False
    try:
        actual_pid = kernel.GetProcessId(handle)
        row['handle_child_pid'] = actual_pid
        if actual_pid != row['child_pid']:
            raise RuntimeError('The transferred process handle identifies another child.')
        row['child_wait'] = kernel.WaitForSingleObject(handle, 10000)
        signaled = row['child_wait'] == 0
        if not signaled:
            raise RuntimeError('The rejected suspended child did not exit within ten seconds.')
        status = wintypes.DWORD()
        if not kernel.GetExitCodeProcess(handle, ctypes.byref(status)):
            raise ctypes.WinError(ctypes.get_last_error())
        row['child_exit_code'] = status.value
    finally:
        if not signaled:
            row['forced_child_termination'] = bool(kernel.TerminateProcess(handle, 126))
            row['cleanup_child_wait'] = kernel.WaitForSingleObject(handle, 5000)
        row['child_handle_closed'] = bool(kernel.CloseHandle(handle))


class NativeController:
    """Own one test-only job, suspended root, and explicit standard streams.

    The production launcher has no job policy. This fixture's unnamed,
    noninheritable job permits no breakaway and kills its tree on close.
    """
    def __init__(self):
        import ctypes
        from ctypes import wintypes
        import _winapi
        self.ctypes, self.api = ctypes, _winapi
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        handle, dword, void = wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p
        for name, args, result in (
                ('CreateJobObjectW', [void, wintypes.LPCWSTR], handle),
                ('SetInformationJobObject', [handle, ctypes.c_int, void, dword], wintypes.BOOL),
                ('AssignProcessToJobObject', [handle, handle], wintypes.BOOL),
                ('ResumeThread', [handle], dword)):
            function = getattr(self.kernel, name)
            function.argtypes, function.restype = args, result
        class BasicLimit(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_longlong), ('job_time', ctypes.c_longlong),
                        ('flags', dword), ('minimum_working_set', ctypes.c_size_t),
                        ('maximum_working_set', ctypes.c_size_t), ('active_processes', dword),
                        ('affinity', ctypes.c_size_t), ('priority', dword), ('scheduling', dword)]
        class ExtendedLimit(ctypes.Structure):
            _fields_ = [('basic', BasicLimit), ('io_counters', ctypes.c_ulonglong * 6),
                        ('process_memory', ctypes.c_size_t), ('job_memory', ctypes.c_size_t),
                        ('peak_process_memory', ctypes.c_size_t), ('peak_job_memory', ctypes.c_size_t)]
        if ctypes.sizeof(handle) != 8 or ctypes.sizeof(ExtendedLimit) != 144:
            raise RuntimeError('The child-binding fixture requires the native 64-bit Windows ABI.')
        self.limits = ExtendedLimit()
        self.limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, fixture only.
        self.job = self.process = self.thread = None
        self.descriptors, self.readers, self.errors = [], [], []
        self.buffers = {'stdout': bytearray(), 'stderr': bytearray()}
        self.lock, self.exceeded = threading.Lock(), threading.Event()

    @property
    def overflow(self):
        return self.exceeded.is_set()

    def create_job(self):
        self.job = self.kernel.CreateJobObjectW(None, None)
        if not self.job:
            raise self.ctypes.WinError(self.ctypes.get_last_error())
        if not self.kernel.SetInformationJobObject(self.job, 9, self.ctypes.byref(self.limits),
                                                   self.ctypes.sizeof(self.limits)):
            raise self.ctypes.WinError(self.ctypes.get_last_error())

    def create_suspended(self, argv, cwd, environment):
        import msvcrt
        output_read, output_write = os.pipe()
        self.descriptors.extend((output_read, output_write))
        error_read, error_write = os.pipe()
        self.descriptors.extend((error_read, error_write))
        null_input = os.open(os.devnull, os.O_RDONLY)
        self.descriptors.append(null_input)
        handles = [msvcrt.get_osfhandle(fd) for fd in (null_input, output_write, error_write)]
        startup = subprocess.STARTUPINFO()
        startup.dwFlags = subprocess.STARTF_USESTDHANDLES
        startup.hStdInput, startup.hStdOutput, startup.hStdError = handles
        startup.lpAttributeList = {'handle_list': handles}
        inherited = []
        try:
            for handle in handles:
                os.set_handle_inheritable(handle, True)
                inherited.append(handle)
            self.process, self.thread, self.pid, _ = self.api.CreateProcess(
                str(argv[0]), subprocess.list2cmdline(list(map(str, argv))), None, None, True,
                0x4 | 0x400, dict(environment), str(cwd), startup)
        finally:
            for handle in inherited:
                os.set_handle_inheritable(handle, False)
        for fd in (output_write, error_write, null_input):
            os.close(fd)
            self.descriptors.remove(fd)
        for fd, name in ((output_read, 'stdout'), (error_read, 'stderr')):
            reader = threading.Thread(target=self.drain, args=(fd, name), daemon=True)
            reader.start()
            self.descriptors.remove(fd)  # the reader now owns this descriptor
            self.readers.append(reader)

    def drain(self, fd, name):
        try:
            while data := os.read(fd, 4096):
                with self.lock:
                    remaining = 65536 - len(self.buffers[name])
                    self.buffers[name].extend(data[:remaining])
                if len(data) > remaining:
                    self.exceeded.set()
                    break
        except OSError as error:
            with self.lock:
                self.errors.append(str(error))
        finally:
            os.close(fd)

    def assign(self):
        if not self.kernel.AssignProcessToJobObject(self.job, self.process):
            raise self.ctypes.WinError(self.ctypes.get_last_error())

    def resume(self):
        if self.kernel.ResumeThread(self.thread) == 0xffffffff:
            raise self.ctypes.WinError(self.ctypes.get_last_error())

    def wait_root(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            status = self.api.WaitForSingleObject(self.process, 50)
            if status == 0:
                return True
            if status != 258:
                raise RuntimeError('The root process wait returned an unexpected status: ' + str(status))
            if self.overflow or time.monotonic() >= deadline:
                return False

    def root_status(self):
        return self.api.GetExitCodeProcess(self.process)

    def close_job(self):
        if self.job:
            self.api.CloseHandle(self.job)
            self.job = None

    def terminate_root(self):
        self.api.TerminateProcess(self.process, 126)

    def finish(self, row):
        for fd in self.descriptors:
            try:
                os.close(fd)
            except OSError as error:
                self.errors.append(str(error))
        self.descriptors.clear()
        deadline = time.monotonic() + 2
        for reader in self.readers:
            reader.join(max(0, deadline - time.monotonic()))
        for name in ('thread', 'process'):
            handle = getattr(self, name)
            if handle is not None:
                try:
                    self.api.CloseHandle(handle)
                    setattr(self, name, None)
                except OSError as error:
                    self.errors.append(str(error))
        with self.lock:
            row.update(capture_complete=not any(reader.is_alive() for reader in self.readers),
                       capture_errors=list(self.errors), output_limit_exceeded=self.overflow,
                       root_handles_closed=self.process is None and self.thread is None)
            for name, buffer in self.buffers.items():
                raw = bytes(buffer)
                row[name] = raw.decode('utf-8', errors='replace')
                row[name + '_hex'], row[name + '_bytes'] = raw.hex(), len(raw)


def capture_contained(argv, cwd, environment, receipt_path, row, *, timeout=30,
                      controller_factory=NativeController, observe=observe_child):
    """Run the actual root only after containment; observe before job cleanup.

    Missing/malformed receipts remain unobserved and cannot earn a reaping pass.
    The factory parameter supplies controlled host APIs in this test module only.
    """
    if not 0 < timeout <= 30:
        raise ValueError('The child-binding root deadline must be in (0, 30] seconds.')
    started = time.monotonic()
    row.update(argv=list(map(str, argv)), returncode=None, exit_code=None, timed_out=False,
               child_reaping='unobserved', job_assigned=False, root_resumed=False, cleanup_errors=[])
    controller = controller_factory()
    try:
        controller.create_job()
        controller.create_suspended(argv, cwd, environment)
        row['root_pid'] = getattr(controller, 'pid', None)
        controller.assign()
        row['job_assigned'] = True
        controller.resume()
        row['root_resumed'] = True
        if not controller.wait_root(timeout):
            row['timed_out'] = not controller.overflow
            raise RuntimeError('The contained root exceeded its deadline or output bound.')
        row['returncode'] = row['exit_code'] = controller.root_status()
    except Exception as error:
        row['controller_error'] = {'type': type(error).__name__, 'message': str(error)}
    finally:
        try:
            if receipt_path.exists():
                observe(receipt_path, row)
                if row.get('child_wait') == 0 and 'forced_child_termination' not in row:
                    row['child_reaping'] = 'observed-before-job-close'
            else:
                row['observer_error'] = 'No complete observer receipt; child reaping is unobserved.'
        except Exception as error:
            row['observer_error'] = {'type': type(error).__name__, 'message': str(error)}
        # This close contains even children whose handles were never received.
        # It occurs strictly after any product-reaping observation above.
        try:
            controller.close_job()
            row['job_closed'] = True
        except Exception as error:
            row['cleanup_errors'].append('Job close failed: ' + str(error))
        if controller.process is not None:
            try:
                if not row['job_assigned']:
                    controller.terminate_root()  # still suspended, never allowed to create children
                    row['suspended_root_terminated'] = True
                row['cleanup_root_wait'] = controller.wait_root(5)
                if not row['cleanup_root_wait']:
                    controller.terminate_root()
                    row['cleanup_root_wait'] = controller.wait_root(5)
            except Exception as error:
                row['cleanup_errors'].append('Root cleanup failed: ' + str(error))
        controller.finish(row)
        row['seconds'] = round(time.monotonic() - started, 6)
    return row


@unittest.skipUnless(runtime is not None, 'Run through the native Windows runtime driver.')
class ManagedChildBindingTests(unittest.TestCase):
    def setUp(self):
        runtime.WindowsRuntimeTests.setUp(self)
        self.receipt = {'test': self.id(), 'scope': 'injected refusal after real class-44 success; not a kernel mismatch attack',
                        'candidate_deliberately_executed': False}
        runtime.COMMANDS.append(self.receipt)
        # LIFO: retain all owned fixture sources, objects, raw receipts and logs
        # before the inherited temporary-directory cleanup runs.
        self.addCleanup(self.retain)

    def retain(self):
        (self.work / 'child-binding-result.json').write_text(json.dumps(self.receipt, indent=2) + '\n')
        self.receipt['retained_evidence'] = str(retain_installer_failure(self.work, self.receipt))

    def artifact(self, path, role):
        data = path.read_bytes()
        runtime.TEST_ARTIFACTS.append({'role': 'child-binding-test-only-' + role, 'target': runtime.TARGET,
                                       'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                       'path': str(path)})

    def build_command(self, argv):
        smoke = build_module('windows_bootstrap_smoke')
        row = {'test': self.id(), 'role': 'child-binding-fixture-build'}
        runtime.COMMANDS.append(row)
        row.update(smoke.capture(argv, cwd=runtime.ROOT, timeout=90))
        row['exit_code'] = row['returncode']
        self.assertTrue(smoke.command_succeeded(row), row)

    def build_image(self, source, name, extra=()):
        path = self.work / (name + '.s')
        path.write_text(source, encoding='utf-8')
        self.artifact(path, name + '-source')
        obj, binary = path.with_suffix('.obj'), path.with_suffix('.exe')
        triple = 'aarch64-pc-windows-msvc' if runtime.ARM64 else 'x86_64-pc-windows-msvc'
        self.build_command([runtime.TOOLCHAIN_BIN / 'clang.exe', '--no-default-config', '--target=' + triple,
                            '-c', path, '-o', obj])
        self.artifact(obj, name + '-object')
        self.build_command([runtime.TOOLCHAIN_BIN / 'lld-link.exe',
                            '/machine:' + ('arm64' if runtime.ARM64 else 'x64'), '/entry:_start',
                            '/subsystem:console', '/nodefaultlib', '/nxcompat', '/dynamicbase', '/Brepro',
                            '/out:' + str(binary), obj, *extra, 'kernel32.lib', 'ntdll.lib',
                            'advapi32.lib', 'bcrypt.lib', 'shell32.lib'])
        self.artifact(binary, name + '-image')
        return binary.read_bytes()

    def test_refused_suspended_payload_is_never_resumed_and_is_reaped(self):
        smoke = build_module('windows_bootstrap_smoke')
        module = build_module('windows_arm64' if runtime.ARM64 else 'windows_x64')
        entry = runtime.ROOT / ('cli/aarch64/asm.s' if runtime.ARM64 else 'cli/asm.s')
        original = module.prepare(entry)
        original_path = self.work / 'original-prepared.s'
        original_path.write_text(original, encoding='utf-8')
        self.artifact(original_path, 'original-prepared-source')
        fixture = self.work / 'child_binding_fixture.c'
        fixture.write_bytes((runtime.ROOT / 'tests/windows/child_binding_fixture.c').read_bytes())
        self.artifact(fixture, 'observer-source')
        obj = fixture.with_suffix('.obj')
        triple = 'aarch64-pc-windows-msvc' if runtime.ARM64 else 'x86_64-pc-windows-msvc'
        self.build_command([runtime.TOOLCHAIN_BIN / 'clang.exe', '--no-default-config', '--target=' + triple,
                            '-Oz', '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-builtin',
                            '-fno-stack-protector', '-c', fixture, '-o', obj])
        self.artifact(obj, 'observer-object')
        launcher = self.build_image(instrument_source(original, runtime.ARM64), 'binding-refusal', (obj,))
        marker = self.work / 'SELECTED_PAYLOAD_EXECUTED'
        candidate = self.build_image(smoke.marker_assembly(runtime.TARGET, runtime.VERSION, marker), 'selected-marker')
        # Both operations use the generated PowerShell source installer. Repair
        # replaces only the root launcher and preserves the selected marker PE.
        source_install(self, candidate, name='selected-marker-install')
        self.assertFalse(marker.exists())
        before = selection(self)[2]
        source_install(self, launcher, name='binding-launcher-repair', repair=True)
        self.assertFalse(marker.exists())
        self.assertEqual(selection(self)[2], before)
        self.assertEqual(selection(self)[1].read_bytes(), candidate)
        installed = self.home / '.local/bin/asm.exe'
        self.assertEqual(installed.read_bytes(), launcher)
        receipt_path = self.work / 'child-binding-ready.bin'
        self.assertFalse(receipt_path.exists())
        environment = dict(self.environment, ASM_TEST_CHILD_CONTROLLER_PID=str(os.getpid()),
                           ASM_TEST_CHILD_RECEIPT=str(receipt_path))
        capture = capture_contained([installed, 'version'], self.work, environment, receipt_path, self.receipt)
        self.assertTrue(receipt_path.is_file(), self.receipt)
        self.assertNotIn('controller_error', capture, self.receipt)
        self.assertNotIn('observer_error', capture, self.receipt)
        self.assertEqual(capture['cleanup_errors'], [], self.receipt)
        self.assertTrue(capture['job_assigned'] and capture['root_resumed'] and capture['job_closed'], self.receipt)
        self.assertTrue(capture['cleanup_root_wait'] and capture['root_handles_closed'], self.receipt)
        self.assertEqual(capture['child_reaping'], 'observed-before-job-close', self.receipt)
        self.assertFalse(capture['timed_out'], self.receipt)
        self.assertFalse(capture['output_limit_exceeded'], self.receipt)
        self.assertTrue(capture['capture_complete'], self.receipt)
        self.assertEqual(capture['capture_errors'], [], self.receipt)
        self.assertEqual(capture['returncode'], 1, self.receipt)
        self.assertEqual(capture['stdout_hex'], '', self.receipt)
        self.assertNotEqual(capture['stderr_hex'], '', self.receipt)
        self.assertEqual(self.receipt['actual_match'], 0, self.receipt)
        self.assertEqual(self.receipt['child_wait'], 0, self.receipt)
        self.assertEqual(self.receipt['child_exit_code'], 127, self.receipt)
        self.assertTrue(self.receipt['child_handle_closed'], self.receipt)
        self.assertNotIn('forced_child_termination', self.receipt)
        self.assertFalse(marker.exists(), self.receipt)
        self.assertEqual(installed.read_bytes(), launcher)
        self.assertEqual(selection(self)[2], before)


def host_checks(output):
    """Exercise transform guards and actual C with controlled APIs, never a PE."""
    results = {}
    for arm64 in (False, True):
        target = 'aarch64' if arm64 else 'x86_64'
        try:
            source = (ROOT / 'cli/windows' / target / 'launcher.s').read_text()
            changed = instrument_source(source, arm64)
            assert changed != source
            call = '    ARM_CALL win_child_image_matches\n' if arm64 else '    call win_child_image_matches\n'
            assert changed.count(call) == 1
            assert changed.count('    bl asm_test_child_binding\n' if arm64 else
                                 '    call asm_test_child_binding\n') == 1
            # An unrelated call outside the dedicated routine must stay intact.
            suffix = '\nother_routine:\n' + call
            assert instrument_source(source + suffix, arm64) == changed + suffix
            malformed = [source.replace('\nwin_managed_launch:\n', '\nother_launch:\n'),
                         source + '\nwin_managed_launch:\n',
                         source.replace(call, call + call), source.replace(call, '')]
            for value in malformed:
                try:
                    instrument_source(value, arm64)
                except ValueError:
                    pass
                else:
                    raise AssertionError('An absent or ambiguous binding call was instrumented.')
            results[target] = {'result': 'pass', 'guard_rejections': len(malformed),
                               'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
                               'instrumented_sha256': hashlib.sha256(changed.encode()).hexdigest()}
        except Exception as error:
            results[target] = {'result': 'fail', 'error': repr(error)}
    try:
        results['observer_controlled_apis'] = observer_host_check(output.parent)
    except Exception as error:
        results['observer_controlled_apis'] = {'result': 'fail', 'error': repr(error)}
    try:
        results['contained_controller'] = controller_host_check()
    except Exception as error:
        results['contained_controller'] = {'result': 'fail', 'error': repr(error)}
    report = {'scope': 'host transform guards and actual C observer with controlled APIs; not native Windows execution', 'cases': results,
              'result': 'pass' if all(row['result'] == 'pass' for row in results.values()) else 'fail'}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report['result'] != 'pass'


def controller_host_check():
    """Execute actual Python orchestration with controlled native operations."""
    cases = {}
    for fault in ('none', 'missing_receipt', 'partial_receipt', 'hang', 'create', 'assign', 'resume'):
        events = []
        with tempfile.TemporaryDirectory(prefix='asm-child-control-host-') as tmp:
            receipt_path = Path(tmp) / 'receipt'
            class Controller:
                process = None
                overflow = False
                child_alive = False
                root_alive = False
                assigned = False
                def create_job(self): events.append('job-create')
                def create_suspended(self, argv, cwd, environment):
                    events.append('create-suspended')
                    if fault == 'create': raise OSError('controlled create failure')
                    self.process = 101
                    self.root_alive = True
                def assign(self):
                    events.append('assign')
                    if fault == 'assign': raise OSError('controlled assign failure')
                    self.assigned = True
                def resume(self):
                    assert self.assigned
                    events.append('resume')
                    if fault == 'resume': raise OSError('controlled resume failure')
                    self.child_alive = fault in ('missing_receipt', 'partial_receipt', 'hang')
                    self.root_alive = fault == 'hang'
                    if fault == 'none':
                        receipt_path.write_bytes(MAGIC + struct.pack('<QIIqII', 4, 321, 42, 0, 654, 0))
                    elif fault == 'partial_receipt':
                        receipt_path.write_bytes(MAGIC + b'partial')
                def wait_root(self, seconds):
                    events.append('wait-root')
                    return not self.root_alive
                def root_status(self): return 1
                def close_job(self):
                    events.append('job-close')
                    if self.assigned:
                        self.root_alive = self.child_alive = False
                def terminate_root(self):
                    events.append('root-terminate')
                    self.root_alive = False
                def finish(self, row):
                    assert not self.root_alive and not self.child_alive
                    events.append('handles-close')
                    row.update(capture_complete=True, capture_errors=[], stdout_hex='', stderr_hex='78',
                               stdout='', stderr='x', output_limit_exceeded=False)
            controller = Controller()
            def observe(path, row):
                assert 'job-close' not in events
                decode_receipt(path.read_bytes(), 42)
                events.append('observe-child')
                row.update(child_wait=0, child_exit_code=127, child_handle_closed=True)
            row = {}
            capture_contained(['root.exe', 'version'], tmp, {}, receipt_path, row,
                              controller_factory=lambda: controller, observe=observe)
            assert events.count('job-close') == 1 and events[-1] == 'handles-close', events
            if fault == 'none':
                assert events.index('assign') < events.index('resume') < events.index('observe-child')
                assert row['child_reaping'] == 'observed-before-job-close' and row['returncode'] == 1
            else:
                assert row['child_reaping'] == 'unobserved', row
                assert 'observe-child' not in events
            if fault == 'assign':
                assert 'resume' not in events and 'root-terminate' in events
            if fault == 'hang': assert row['timed_out']
            cases[fault] = {'result': 'pass', 'events': events, 'receipt': row}
    return {'result': 'pass', 'scope': 'controller orchestration with controlled kernel operations, not native jobs',
            'cases': cases}


def observer_host_check(evidence):
    """Run unchanged observer body against strict host-only API implementations.

    These fixtures catch lost high match bits, borrowed-child closure, leaked
    duplicates on observation failures, short writes, and failure termination.
    No ExitProcess definition exists: such an observer call cannot link.
    """
    import shutil
    clang = shutil.which('clang')
    if not clang:
        raise RuntimeError('The isolated observer check requires an existing host clang.')
    original = (ROOT / 'tests/windows/child_binding_fixture.c').read_text()
    # Only the unavailable import annotation changes for host execution.
    source = original.replace('#define API __declspec(dllimport)', '#define API') + r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int fault, bad, controller_closed, marker_closed, remote_closed, deleted;
static unsigned char observed[40];
static DWORD observed_size;
#define H(n) ((HANDLE)(U64)(n))
static void check(int value) { if (!value) bad = 1; }
static int same(const WCHAR *a, const WCHAR *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
DWORD GetEnvironmentVariableW(const WCHAR *name, WCHAR *out, DWORD cap) {
    const WCHAR *value;
    DWORD count = 0;
    if (same(name, (const WCHAR *)L"ASM_TEST_CHILD_CONTROLLER_PID")) {
        check(cap == 16);
        if (fault == 1) return 0;
        value = (const WCHAR *)(fault == 2 ? L"0042" : fault == 14 ? L"4294967296" : L"42");
    } else {
        check(same(name, (const WCHAR *)L"ASM_TEST_CHILD_RECEIPT") && cap == 4096);
        if (fault == 3) return 0;
        if (fault == 15) return 4096;
        value = (const WCHAR *)L"owned-receipt";
    }
    do { out[count] = value[count]; } while (value[count++]);
    return count - 1;
}
HANDLE GetCurrentProcess(void) { return H(5); }
DWORD GetCurrentProcessId(void) { return 654; }
DWORD GetProcessId(HANDLE child) { check(child == H(3)); return fault == 4 ? 0 : 321; }
HANDLE OpenProcess(DWORD rights, int inherit, DWORD pid) {
    check(rights == 0x40 && !inherit && pid == 42);
    return fault == 5 ? 0 : H(1);
}
int DuplicateHandle(HANDLE owner, HANDLE child, HANDLE target, HANDLE *out,
                    DWORD rights, int inherit, DWORD options) {
    if (options == 1) {
        check(owner == H(1) && child == H(4) && !target && !out && !rights && !inherit);
        ++remote_closed;
        return 1;
    }
    check(owner == H(5) && child == H(3) && target == H(1) && out &&
          rights == 0x101001 && !inherit && !options);
    if (fault == 7) return 0;
    *out = H(4);
    return 1;
}
HANDLE CreateFileW(const WCHAR *path, DWORD access, DWORD share, void *security,
                   DWORD disposition, DWORD flags, HANDLE template_file) {
    check(same(path, (const WCHAR *)L"owned-receipt") && access == 0x40000000 &&
          !share && !security && disposition == 1 && flags == 0x200080 && !template_file);
    return fault == 6 ? INVALID_HANDLE : H(2);
}
int WriteFile(HANDLE file, const void *bytes, DWORD count, DWORD *written, void *overlap) {
    check(file == H(2) && !overlap && count == 40 - observed_size);
    if (fault == 8) return 0;
    if (fault == 11) { *written = 0; return 1; }
    if (fault == 12) { *written = count + 1; return 1; }
    if (fault == 10 && count > 7) count = 7;
    memcpy(observed + observed_size, bytes, count);
    observed_size += count;
    *written = count;
    return 1;
}
int FlushFileBuffers(HANDLE file) { check(file == H(2)); return fault != 9; }
int CloseHandle(HANDLE handle) {
    if (handle == H(1)) ++controller_closed;
    else if (handle == H(2)) ++marker_closed;
    else bad = 1; /* borrowed child and transferred remote must not close locally */
    return !(fault == 13 && handle == H(2));
}
int DeleteFileW(const WCHAR *path) {
    check(same(path, (const WCHAR *)L"owned-receipt"));
    ++deleted;
    return 1;
}
int main(int argc, char **argv) {
    int success, reached_open, reached_marker, transferred;
    check(argc == 2);
    if (argc != 2) return 95;
    fault = atoi(argv[1]);
    /* Nonzero high bits establish that receipt serialization is full-width. */
    success = asm_test_child_binding(H(3), (long long)0x1234567887654321ULL);
    check(success == (fault == 0 || fault == 10));
    reached_open = fault == 0 || (fault >= 6 && fault <= 13);
    reached_marker = reached_open && fault != 6;
    transferred = reached_marker && fault != 7;
    check(controller_closed == reached_open && marker_closed == reached_marker);
    check(remote_closed == (transferred && !success));
    check(deleted == (reached_marker && !success));
    if (success) {
        check(observed_size == 40);
        if (fwrite(observed, 1, 40, stdout) != 40) return 96;
    }
    return bad ? 95 : 0;
}
'''
    evidence.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='child-observer-host-', dir=evidence)).resolve()
    path, binary = directory / 'observer-host.c', directory / 'observer-host'
    path.write_text(source)
    argv = [clang, '-fshort-wchar', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1',
            '-fno-builtin', str(path), '-o', str(binary)]
    build = subprocess.run(argv, capture_output=True, timeout=30)
    report = {'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
              'observer_source_sha256': hashlib.sha256(original.encode()).hexdigest(),
              'retained_directory': str(directory), 'build': {'argv': argv, 'exit_code': build.returncode,
              'stdout_hex': build.stdout.hex(), 'stderr_hex': build.stderr.hex()}, 'cases': {}}
    if build.returncode == 0:
        report['executable_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        for case in range(16):
            result = subprocess.run([str(binary), str(case)], capture_output=True, timeout=5)
            row = {'exit_code': result.returncode, 'stdout_hex': result.stdout.hex(),
                   'stderr_hex': result.stderr.hex(), 'result': 'pass' if result.returncode == 0 else 'fail'}
            if result.returncode == 0 and case in (0, 10):
                observed = decode_receipt(result.stdout, 42)
                row['receipt'] = observed
                if observed != {'duplicated_handle': 4, 'child_pid': 321, 'controller_pid': 42,
                                'actual_match': 0x1234567887654321, 'launcher_pid': 654}:
                    row['result'] = 'fail'
            elif result.stdout:
                row['result'] = 'fail'
            report['cases'][str(case)] = row
    report['result'] = ('pass' if len(report['cases']) == 16 and
                        all(row['result'] == 'pass' for row in report['cases'].values()) else 'fail')
    (directory / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--host-check', type=Path, required=True)
    raise SystemExit(host_checks(parser.parse_args().host_check))
