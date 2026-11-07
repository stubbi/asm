#!/usr/bin/env python3
"""Collect bounded Windows adapter diagnostics from a separate test executable.

This builds the real assembly CLI with test-only status logging. It changes no
permission rule. All mutations stay in one owned temporary directory. Self-update
uses the current explicit version, so this fixture makes no network request.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import gzip
import io
import tarfile
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import traceback
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
LOCAL = Path(__file__).resolve().parent
LIMIT = 65536


def diagnostic_source(module):
    return instrument_source(module.prepare(ROOT / 'cli/asm.s'))


def checked_replace(body, anchor, replacement, context, count=1):
    observed = body.count(anchor)
    if observed != count:
        raise ValueError(f'{context}: expected {count} diagnostic anchor(s), found {observed}: {anchor.strip()!r}')
    return body.replace(anchor, replacement)


def scoped_edit(source, begin, end, edit):
    markers = ['\n' + name + ':\n' for name in (begin, end)]
    for name, marker in zip((begin, end), markers):
        if source.count(marker) != 1:
            raise ValueError(f'{begin}: absent or ambiguous diagnostic boundary {name}')
    first, last = (source.index(marker) for marker in markers)
    if last <= first:
        raise ValueError(f'{begin}: diagnostic boundary {end} precedes its routine')
    return source[:first] + edit(source[first:last]) + source[last:]


def trace_result(stage):
    # The logger preserves RAX, LastError and the internal callee-saved
    # registers. Keep its remaining integer/flags scratch state here, too.
    return (f'    mov dword ptr [rip + win_diag_process_stage], {stage}\n'
            '    pushfq\n    push rcx\n    push r11\n'
            '    call win_diag_process_log\n'
            '    pop r11\n    pop rcx\n    popfq\n')


def trace_call(body, function, stage, context, count=1):
    anchor = '    call ' + function + '\n'
    return checked_replace(body, anchor, anchor + trace_result(stage), context, count)


def instrument_source(source):
    # Each call belongs to a known routine. An additional use elsewhere must
    # neither break the collector nor silently acquire instrumentation.
    source = scoped_edit(source, 'win_nt_open', 'win_drive_path', lambda body:
        checked_replace(body, '    call NtCreateFile\n    test eax, eax\n',
            '    call NtCreateFile\n    pushfq\n    push rax\n    push rcx\n'
            '    push r11\n    push rdi\n    push rsi\n    push rdx\n'
            '    mov edi, eax\n    mov rsi, r13\n    mov edx, r15d\n'
            '    call win_diag_nt_log\n    pop rdx\n    pop rsi\n    pop rdi\n'
            '    pop r11\n    pop rcx\n    pop rax\n    popfq\n    test eax, eax\n', 'win_nt_open'))
    source = scoped_edit(source, 'win_stat', 'win_protect', lambda body:
        checked_replace(body, '.Lwst_acl_done:\n    mov rcx, r14\n',
            '.Lwst_acl_done:\n    pushfq\n    push rax\n    push rcx\n'
            '    push r11\n    push rdi\n    mov rdi, r13\n    call win_diag_stat_log\n'
            '    pop rdi\n    pop r11\n    pop rcx\n    pop rax\n    popfq\n'
            '    mov rcx, r14\n', 'win_stat'))

    def process_trace(body):
        stages = ['win_wide', 'win_wide_command', 'win_build_environment', 'win_explicit_environment',
                  'CreatePipe', 'SetHandleInformation', 'win_inherit_duplicate', 'CreateFileW',
                  'InitializeProcThreadAttributeList', 'UpdateProcThreadAttribute', 'CreateProcessW']
        for stage, function in enumerate(stages, 1):
            body = trace_call(body, function, stage, 'win_process', 3 if function == 'win_inherit_duplicate' else 1)
        anchor = '    mov ebx, [rbp - 152]\n'
        return checked_replace(body, anchor, anchor + '    push rax\n    mov eax, ebx\n' +
                               trace_result(16) + '    pop rax\n', 'win_process child exit')
    source = scoped_edit(source, 'win_process', 'win_command_byte', process_trace)
    source = scoped_edit(source, 'win_decompress', 'win_download', lambda body:
        checked_replace(body, '    call win_process\n', '    call win_process\n' + trace_result(12) +
            '    push rax\n    mov eax, [rip + win_capture_length]\n' + trace_result(13) +
            '    pop rax\n', 'win_decompress'))
    for begin, end, function, stage in [
            ('validate_source_archive', 'source_archive_member', 'arc_validate', 14),
            ('arc_operation_start', 'arc_close', 'arc_validate', 14),
            ('validate_source_package', 'cmd_publish', 'pub_check_project', 15),
            ('cmd_publish', 'pub_arg_value', 'pub_check_project', 15),
            ('win_rename', 'win_open_parent', 'NtSetInformationFile', 17),
            ('win_protect', 'win_ntfs', 'SetSecurityInfo', 18),
            ('.Lws_sync', '.Lws_fchmod', 'FlushFileBuffers', 19),
            ('win_managed_rename_fd', 'win_managed_same_fd', 'NtSetInformationFile', 26)]:
        source = scoped_edit(source, begin, end,
                             lambda body: trace_call(body, function, stage, begin))

    # The shared entry now delegates to the managed implementation. Refuse an
    # unrecognized shape instead of silently applying the old six-call trace.
    source = scoped_edit(source, 'self_commit_update', 'self_update_cleanup', lambda body:
        checked_replace(body, '    jmp win_managed_commit_update\n',
                        '    jmp win_managed_commit_update\n', 'self_commit_update'))

    def commit_trace(body):
        for name, function, stage in [('payload_flush', 'win_syscall', 27),
                                      ('record_write', 'win_syscall', 28),
                                      ('record_flush', 'win_syscall', 29),
                                      ('activation_rename', 'win_managed_rename_fd', 30)]:
            label = '\nwin_managed_' + name + ':\n'
            if body.count(label) != 1:
                raise ValueError(f'win_managed_{name}: absent or ambiguous diagnostic boundary')
            first = body.index(label)
            # Test fault variants insert register-preserving observations before
            # this call. Trace its result before the existing status check.
            status = body.find('    test rax, rax\n', first)
            if status < 0 or status - first > 4096:
                raise ValueError(f'win_managed_{name}: diagnostic status check changed')
            body = body[:first] + trace_call(body[first:status], function, stage,
                                           'win_managed_' + name) + body[status:]
        return body
    source = scoped_edit(source, 'win_managed_commit_update', 'win_managed_update_cleanup', commit_trace)
    return source + '\n' + (LOCAL / 'diagnostic.s').read_text()


def api_security(paths):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    pointer = ctypes.c_void_p
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.LocalFree.argtypes = [pointer]
    kernel.LocalFree.restype = pointer
    kernel.GetFileAttributesW.argtypes = [wintypes.LPCWSTR]
    kernel.GetFileAttributesW.restype = wintypes.DWORD
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, pointer, wintypes.DWORD,
                                          ctypes.POINTER(wintypes.DWORD)]
    advapi.ConvertSidToStringSidW.argtypes = [pointer, ctypes.POINTER(pointer)]
    advapi.GetNamedSecurityInfoW.argtypes = [wintypes.LPWSTR, ctypes.c_int, wintypes.DWORD,
        ctypes.POINTER(pointer), pointer, ctypes.POINTER(pointer), pointer, ctypes.POINTER(pointer)]
    advapi.GetNamedSecurityInfoW.restype = wintypes.DWORD
    advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [pointer, wintypes.DWORD,
        wintypes.DWORD, ctypes.POINTER(pointer), ctypes.POINTER(wintypes.DWORD)]

    def sid_text(sid):
        value = pointer()
        if not sid or not advapi.ConvertSidToStringSidW(sid, ctypes.byref(value)):
            return {'error': ctypes.get_last_error()}
        try:
            return ctypes.wstring_at(value, 0) if not value else ctypes.wstring_at(value)[:128]
        finally:
            kernel.LocalFree(value)

    token = wintypes.HANDLE()
    result = {'token': {}, 'paths': []}
    if advapi.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
        try:
            for kind, name in [(1, 'user'), (4, 'default_owner'), (20, 'elevated')]:
                data = ctypes.create_string_buffer(4096)
                needed = wintypes.DWORD()
                if advapi.GetTokenInformation(token, kind, data, 4096, ctypes.byref(needed)):
                    result['token'][name] = (ctypes.c_uint32.from_buffer(data).value if kind == 20 else sid_text(pointer.from_buffer(data).value))
                else:
                    result['token'][name] = {'error': ctypes.get_last_error()}
        finally:
            kernel.CloseHandle(token)
    else:
        result['token']['error'] = ctypes.get_last_error()
    unique = list(dict.fromkeys(map(str, paths)))[:32]
    for name in unique:
        row = {'path': name, 'attributes': kernel.GetFileAttributesW(name)}
        owner, dacl, security = pointer(), pointer(), pointer()
        error = advapi.GetNamedSecurityInfoW(name, 1, 5, ctypes.byref(owner), None,
                                            ctypes.byref(dacl), None, ctypes.byref(security))
        if error:
            row['security_error'] = error
        else:
            try:
                row['owner'] = sid_text(owner)
                value, count = pointer(), wintypes.DWORD()
                if advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW(
                        security, 1, 5, ctypes.byref(value), ctypes.byref(count)):
                    try:
                        length = max(0, count.value - 1)
                        row['sddl'] = ctypes.wstring_at(value, min(length, 16384)).split('\0', 1)[0]
                        row['sddl_truncated'] = length > 16384
                    finally:
                        kernel.LocalFree(value)
                else:
                    row['sddl_error'] = ctypes.get_last_error()
            finally:
                kernel.LocalFree(security)
        result['paths'].append(row)
    return result


def set_fixture_user_owner(paths):
    """Set only intended positive fixture owners; keep inherited DACLs."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    pointer = ctypes.c_void_p
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, pointer, wintypes.DWORD,
                                          ctypes.POINTER(wintypes.DWORD)]
    advapi.SetNamedSecurityInfoW.argtypes = [wintypes.LPWSTR, ctypes.c_int, wintypes.DWORD,
                                           pointer, pointer, pointer, pointer]
    advapi.SetNamedSecurityInfoW.restype = wintypes.DWORD
    token = wintypes.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        data, needed = ctypes.create_string_buffer(4096), wintypes.DWORD()
        if not advapi.GetTokenInformation(token, 1, data, 4096, ctypes.byref(needed)):
            raise ctypes.WinError(ctypes.get_last_error())
        sid = pointer.from_buffer(data).value
        for path in paths:
            error = advapi.SetNamedSecurityInfoW(str(path), 1, 1, sid, None, None, None)
            if error:
                raise ctypes.WinError(error)
    finally:
        kernel.CloseHandle(token)


def captured_text(value):
    if value is None:
        return ''
    if isinstance(value, bytes):
        return value[:LIMIT].decode('utf-8', errors='replace')
    return value[:LIMIT]


def run_recorded(report, argv, *, binary=False, **options):
    """Retain completed and failed process observations with bounded output."""
    started = time.monotonic()
    argv = list(map(str, argv))
    row = {'argv': argv}
    try:
        mode = {} if binary else {'text': True, 'encoding': 'utf-8', 'errors': 'replace'}
        result = subprocess.run(argv, capture_output=True, timeout=30, **mode, **options)
        stdout, stderr = result.stdout, result.stderr
        row['exit_code'] = result.returncode
    except subprocess.TimeoutExpired as error:
        stdout, stderr = error.stdout, error.stderr
        row.update(exit_code=None, timed_out=True)
        report['collection_failed'] = True
        result = subprocess.CompletedProcess(argv, 127, captured_text(stdout), captured_text(stderr))
    except OSError as error:
        stdout, stderr = '', ''
        row.update(exit_code=None, os_error={'type': type(error).__name__,
            'errno': error.errno, 'winerror': getattr(error, 'winerror', None),
            'message': str(error)[:1024]})
        report['collection_failed'] = True
        result = subprocess.CompletedProcess(argv, 127, '', '')
    row.update(stdout=captured_text(stdout), stderr=captured_text(stderr),
        output_truncated=len(stdout or '') > LIMIT or len(stderr or '') > LIMIT,
        seconds=round(time.monotonic()-started, 6))
    if binary:
        data = stdout if isinstance(stdout, bytes) else (stdout or '').encode('utf-8')
        row.update(binary_output=True, stdout='', stdout_bytes=len(data), stdout_sha256=hashlib.sha256(data).hexdigest())
    report['commands'].append(row)
    return result


def collect_evidence(destination, report, operation):
    """Write partial evidence even if collection fails before its final step."""
    try:
        operation()
    except Exception as error:
        report['collection_failed'] = True
        detail = ''.join(traceback.format_exception(type(error), error, error.__traceback__, limit=8))
        report['collection_error'] = {'type': type(error).__name__,
            'message': (str(error) or type(error).__name__)[:1024],
            'traceback': detail[:8192], 'traceback_truncated': len(detail) > 8192}
    finally:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('x', encoding='utf-8') as output:
            json.dump(report, output, indent=2)
            output.write('\n')
    return 1 if report.get('build_failed') or report.get('collection_failed') else 0


def source_fixture(work, project):
    """Create one bounded, owned USTAR/Gzip fixture for the assembly validator."""
    contents = {'asm.toml': (project / 'asm.toml').read_bytes(),
                'src/main.s': (project / 'src/main.s').read_bytes(),
                'README.md': b'Diagnostic source fixture.\n',
                'LICENSE': b'SPDX-License-Identifier: MIT\n'}
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, data in contents.items():
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.mtime = len(data), 0o644, 0
            archive.addfile(entry, io.BytesIO(data))
    payload = gzip.compress(stream.getvalue(), mtime=0)
    artifact, index = work / 'source.tar.gz', work / 'source-index.tsv'
    artifact.write_bytes(payload)
    fields = ['fixture/hello','0.1.0','x86_64-windows','source',
              hashlib.sha256(payload).hexdigest(),'https://fixture.invalid/source.tar.gz',
              str(len(payload)),'Diagnostic source fixture']
    index.write_bytes(('# asm-registry-v1\n' + '\t'.join(fields) + '\n').encode('utf-8'))
    return artifact, index, stream.getvalue()


def update_diagnostic_case(runtime):
    """Keep the current runtime fixture; adapt only its diagnostic build/output."""
    class UpdateDiagnostic(runtime.SelfUpdateRuntimeTests):
        @classmethod
        def build_cli(cls, source, name, extra_objects=()):
            # This candidate deliberately contains only the execution marker.
            # Every complete CLI, including fault variants, must satisfy all
            # instrumentation anchors instead of falling back on an exception.
            traced = source if name == 'marker-next' else instrument_source(source)
            return super().build_cli(traced, 'diagnostic-' + name, extra_objects)

        @classmethod
        def build_command(cls, argv):
            command = list(argv)
            if str(command[0]).lower().endswith('clang.exe') and '--no-default-config' not in command:
                command.insert(1, '--no-default-config')
            return super().build_command(command)

        def cli(self, *args, cwd=None, code=0, env=None, binary=runtime.ASM, timeout=30):
            argv = [str(binary), *map(str, args)]
            started = time.monotonic()
            failure = None
            try:
                raw = subprocess.run(argv, cwd=cwd or self.work, env=env or self.environment,
                                     capture_output=True, timeout=timeout)
            except subprocess.TimeoutExpired as error:
                failure = error
                raw = subprocess.CompletedProcess(argv, None, error.stdout or b'', error.stderr or b'')
            except OSError as error:
                failure = error
                raw = subprocess.CompletedProcess(argv, None, b'', b'')
            row = {'test': self.id(), 'argv': argv, 'cwd': str(cwd or self.work),
                'exit_code': raw.returncode, 'stdout': captured_text(raw.stdout),
                'stderr': captured_text(raw.stderr), 'stdout_hex': raw.stdout[:LIMIT].hex(),
                'stderr_hex': raw.stderr[:LIMIT].hex(),
                'output_truncated': len(raw.stdout) > LIMIT or len(raw.stderr) > LIMIT,
                'seconds': round(time.monotonic() - started, 6)}
            runtime.COMMANDS.append(row)
            if failure is not None:
                row['timed_out'] = isinstance(failure, subprocess.TimeoutExpired)
                row['error'] = {'type': type(failure).__name__, 'message': str(failure)[:1024]}
                raise failure
            self.assertFalse(row['output_truncated'], 'Diagnostic output exceeded the retained byte bound.')
            # Match the normal fixture's strict UTF-8/text handling. Raw bytes
            # stay in the report even when decoding or an assertion fails.
            stdout = raw.stdout.decode('utf-8').replace('\r\n', '\n').replace('\r', '\n')
            stderr = raw.stderr.decode('utf-8').replace('\r\n', '\n').replace('\r', '\n')
            framed = re.compile(r'(?:NT [0-9A-F]{8} component=[^\r\n]{0,900}|'
                r'STAT mode=[0-9A-F]{8} owner=[0-9A-F]{8} links=[0-9A-F]{8}|'
                r'PROC stage=000000(?:0[1-9A-F]|1[0-3A-E]) result=[0-9A-F]{8} error=[0-9A-F]{8})\n')
            remaining = ''.join(line for line in stderr.splitlines(keepends=True) if not framed.fullmatch(line))
            row['asserted_stderr'] = remaining
            result = subprocess.CompletedProcess(argv, raw.returncode, stdout, remaining)
            self.assertEqual(result.returncode, code, (argv, result.stdout, result.stderr))
            if code == 0:
                self.assertEqual(result.stderr, '')
            elif code in (1, 2, 69):
                self.assertNotEqual(result.stderr, '')
            self.assertFalse(((cwd or self.work) / 'PACKAGE_EXECUTED').exists(),
                             'Package management executed package code')
            self.assertEqual(list((cwd or self.work).glob('.asm-registry-*')), [], 'A private stage remains')
            return result
    return UpdateDiagnostic


def update_probe(report, binary):
    """Reuse the exact positive runtime fixture with separately traced CLI bytes.

    The fixture enforces arguments and supplies bytes. It validates no real
    signature and gives no production provenance qualification.
    """
    test_directory = ROOT / 'tests/windows'
    previous = {key: os.environ.get(key) for key in ['ASM_WINDOWS_EXE','ASM_WINDOWS_TARGET']}
    previous_runtime = sys.modules.get('test_runtime')
    previous_path = sys.path[:]
    runtime = None
    result = unittest.TestResult()
    try:
        os.environ['ASM_WINDOWS_EXE'] = str(binary)
        os.environ['ASM_WINDOWS_TARGET'] = 'x86_64-windows'
        sys.path.insert(0, str(test_directory))
        spec = importlib.util.spec_from_file_location('test_runtime', test_directory / 'test_runtime.py')
        runtime = importlib.util.module_from_spec(spec)
        sys.modules['test_runtime'] = runtime
        spec.loader.exec_module(runtime)
        case = update_diagnostic_case(runtime)
        suite = unittest.TestSuite([case('test_update_replaces_exact_bytes_after_three_provenance_bindings')])
        suite.run(result)
    finally:
        if runtime is not None:
            report['commands'].extend(getattr(runtime, 'COMMANDS', []))
            report['update_probe_artifacts'] = getattr(runtime, 'TEST_ARTIFACTS', [])
            report['update_probe'] = {'outcome': 'pass' if result.wasSuccessful() and result.testsRun == 1 and not result.skipped else 'fail',
                'tests_run': result.testsRun, 'native_qualification': False,
                'scope': 'Test-only transport/verifier fixtures and instrumented assembly',
                'failures': [{'test': str(test), 'detail': detail[:LIMIT]} for test, detail in result.failures],
                'errors': [{'test': str(test), 'detail': detail[:LIMIT]} for test, detail in result.errors],
                'skipped': [{'test': str(test), 'reason': reason[:1024]} for test, reason in result.skipped]}
        sys.path[:] = previous_path
        if previous_runtime is None:
            sys.modules.pop('test_runtime', None)
        else:
            sys.modules['test_runtime'] = previous_runtime
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain-bin', type=Path, default=Path('C:/Program Files/LLVM/bin'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This diagnostic fixture requires native Windows')
    if args.evidence.exists():
        parser.error('The evidence destination must not already exist')
    report = {'process_stages': {str(i+1): name for i,name in enumerate(['win_wide','win_wide_command','win_build_environment','win_explicit_environment','CreatePipe','SetHandleInformation','win_inherit_duplicate','CreateFileW','InitializeProcThreadAttributeList','UpdateProcThreadAttribute','CreateProcessW'])}, 'kind': 'windows-x64-adapter-diagnostics', 'native_qualification': False, 'commands': []}

    report['process_stages'].update({'12': 'gzip-capture-status', '13': 'gzip-capture-bytes', '14': 'tar-validation', '15': 'source-project-validation', '16': 'raw-child-exit-code'})
    report['process_stages'].update({'17': 'NtSetInformationFile-status', '18': 'SetSecurityInfo-error', '19': 'FlushFileBuffers-bool', '20': 'commit-open-result', '21': 'commit-protect-result', '22': 'commit-flush-result', '23': 'commit-close-result', '24': 'commit-rename-result', '25': 'commit-failure-close-result'})
    # Stages 20..25 describe retained legacy reports; current managed builds
    # use these explicit boundaries and the same raw native API observations.
    report['process_stages'].update({'26': 'managed-NtSetInformationFile-status',
        '27': 'managed-payload-flush-result', '28': 'managed-record-write-result',
        '29': 'managed-record-flush-result', '30': 'managed-activation-rename-result'})

    def run(argv, **options):
        return run_recorded(report, argv, **options)

    def collect():
        spec = importlib.util.spec_from_file_location('windows_x64', ROOT / 'tools/windows_x64.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='asm-x64-native-diagnostic-') as temporary:
            work = Path(temporary)
            source, obj, binary = (work / 'diagnostic.s', work / 'diagnostic.obj', work / 'diagnostic.exe')
            text = diagnostic_source(module)
            source.write_text(text)
            report['assembly_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
            compile_result = run([args.toolchain_bin / 'clang.exe', '--no-default-config', '--target=x86_64-pc-windows-msvc',
                                  '-c', source, '-o', obj], cwd=ROOT)
            if compile_result.returncode:
                report['build_failed'] = True
            else:
                linked = run([args.toolchain_bin / 'lld-link.exe', '/machine:x64', '/entry:_start',
                    '/subsystem:console', '/nodefaultlib', '/nxcompat', '/dynamicbase', '/Brepro',
                    '/out:' + str(binary), obj, 'kernel32.lib', 'ntdll.lib', 'advapi32.lib',
                    'bcrypt.lib', 'shell32.lib'], cwd=ROOT)
                if linked.returncode:
                    report['build_failed'] = True
                else:
                    report['executable_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
                    home = work / 'home with spaces'
                    home.mkdir()
                    report['ambient_home_security'] = api_security([home])
                    set_fixture_user_owner([home])
                    environment = dict(os.environ, HOME=str(home), USERPROFILE=str(home))
                    new_project = work / 'hello'
                    run([binary, 'new', new_project], cwd=work, env=environment)
                    run([binary, 'run'], cwd=new_project, env=environment)
                    artifact, index, raw = source_fixture(work, new_project)
                    report['source_fixture'] = {'compressed_bytes': artifact.stat().st_size,
                        'raw_bytes': len(raw), 'raw_sha256': hashlib.sha256(raw).hexdigest()}
                    for name, probe_environment in [('empty', {}), ('system-root-only',
                            {key: os.environ[key] for key in ['SystemRoot', 'WINDIR'] if key in os.environ})]:
                        run_recorded(report, ['C:/Program Files/Git/usr/bin/gzip.exe','-d','-c'],
                            binary=True, input=artifact.read_bytes(), env=probe_environment, cwd=work)
                        report['commands'][-1]['gzip_probe_environment'] = name
                    run([binary, 'add', 'fixture/hello@0.1.0', '--index', index,
                         '--artifact', artifact, '--json'], cwd=new_project, env=environment)
                    run([binary, 'installed', '--json'], cwd=work, env=environment)
                    version = json.loads(run([binary, 'version', '--json'], cwd=work, env=environment).stdout)['version']
                    installation = home / '.local/bin/asm.exe'
                    installation.parent.mkdir(parents=True, exist_ok=True)
                    set_fixture_user_owner([home / '.local', installation.parent])
                    shutil.copyfile(binary, installation)
                    run([installation, 'self', 'update', version, '--json'], cwd=work, env=environment)
                    report['security'] = api_security([
                        *reversed(installation.parents), installation, new_project,
                        new_project / 'asm.toml', new_project / 'src/main.s'])
                    report['rename_probe'] = {}
                    spec = importlib.util.spec_from_file_location('owned_rename_probe', LOCAL / 'rename_probe.py')
                    probe = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(probe)
                    probe.run(binary, set_fixture_user_owner, api_security, report['rename_probe'])
                    if any(row.get('stage') != 'complete' or row.get('cleanup_error') for row in report['rename_probe']['cases']):
                        report['collection_failed'] = True
                    update_probe(report, binary)
    result = collect_evidence(args.evidence, report, collect)
    print('Adapter diagnostic evidence:', args.evidence)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
