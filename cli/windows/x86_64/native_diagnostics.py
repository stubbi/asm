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
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
LOCAL = Path(__file__).resolve().parent
LIMIT = 65536


def diagnostic_source(module):
    return instrument_source(module.prepare(ROOT / 'cli/asm.s'))


def instrument_source(source):
    anchor = '    call NtCreateFile\n    test eax, eax\n'
    if source.count(anchor) != 1:
        raise ValueError('NtCreateFile diagnostic anchor changed')
    source = source.replace(anchor, '''    call NtCreateFile
    push rax
    mov edi, eax
    mov rsi, r13
    mov edx, r15d
    call win_diag_nt_log
    pop rax
    test eax, eax
''')
    anchor = '.Lwst_acl_done:\n    mov rcx, r14\n'
    if source.count(anchor) != 1:
        raise ValueError('stat diagnostic anchor changed')
    source = source.replace(anchor, '''.Lwst_acl_done:
    mov rdi, r13
    call win_diag_stat_log
    mov rcx, r14
''')
    begin = source.index('win_process:\n')
    end = source.index('win_command_byte:\n', begin)
    process = source[begin:end]
    stages = ['win_wide','win_wide_command','win_build_environment','win_explicit_environment',
              'CreatePipe','SetHandleInformation','win_inherit_duplicate','CreateFileW',
              'InitializeProcThreadAttributeList','UpdateProcThreadAttribute','CreateProcessW']
    for number, name in enumerate(stages, 1):
        process = process.replace('    call ' + name + '\n',
            '    mov dword ptr [rip + win_diag_process_stage], ' + str(number) + '\n' +
            '    call ' + name + '\n    call win_diag_process_log\n')
    anchor = '    mov ebx, [rbp - 152]\n'
    assert process.count(anchor) == 1
    process = process.replace(anchor, anchor + '    mov eax, ebx\n    mov dword ptr [rip + win_diag_process_stage], 16\n    call win_diag_process_log\n')
    source = source[:begin] + process + source[end:]
    begin = source.index('win_decompress:\n')
    end = source.index('win_download:\n', begin)
    body = source[begin:end]
    anchor = '    call win_process\n'
    assert body.count(anchor) == 1
    body = body.replace(anchor, anchor + '    mov dword ptr [rip + win_diag_process_stage], 12\n    call win_diag_process_log\n    push rax\n    mov eax, [rip + win_capture_length]\n    mov dword ptr [rip + win_diag_process_stage], 13\n    call win_diag_process_log\n    pop rax\n')
    source = source[:begin] + body + source[end:]
    for function, stage in [('arc_validate', 14), ('pub_check_project', 15)]:
        anchor = '    call ' + function + '\n'
        assert source.count(anchor) >= 1
        source = source.replace(anchor, anchor + '    mov dword ptr [rip + win_diag_process_stage], ' + str(stage) + '\n    call win_diag_process_log\n')
    for function, stage in [('NtSetInformationFile', 17), ('SetSecurityInfo', 18), ('FlushFileBuffers', 19)]:
        anchor = '    call ' + function + '\n'
        assert source.count(anchor) == 1
        source = source.replace(anchor, anchor + '    mov dword ptr [rip + win_diag_process_stage], ' + str(stage) + '\n    call win_diag_process_log\n')
    begin = source.index('self_commit_update:\n')
    end = source.index('self_update_cleanup:\n', begin)
    body = source[begin:end].split('    call win_syscall\n')
    assert len(body) == 7, 'self commit syscall contract changed'
    traced = body[0]
    for index, remaining in enumerate(body[1:]):
        traced += ('    call win_syscall\n    mov dword ptr [rip + win_diag_process_stage], ' +
                   str(20+index) + '\n    call win_diag_process_log\n' + remaining)
    source = source[:begin] + traced + source[end:]
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
        report['collection_error'] = {'type': type(error).__name__, 'message': str(error)[:1024]}
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


def update_probe(report, binary):
    """Reuse the exact positive runtime fixture with separately traced CLI bytes.

    The fixture enforces arguments and supplies bytes. It validates no real
    signature and gives no production provenance qualification.
    """
    test_directory = ROOT / 'tests/windows'
    previous = {key: os.environ.get(key) for key in ['ASM_WINDOWS_EXE','ASM_WINDOWS_TARGET']}
    try:
        os.environ['ASM_WINDOWS_EXE'] = str(binary)
        os.environ['ASM_WINDOWS_TARGET'] = 'x86_64-windows'
        sys.path.insert(0, str(test_directory))
        spec = importlib.util.spec_from_file_location('x64_update_diagnostic_runtime', test_directory / 'test_runtime.py')
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
    finally:
        if sys.path and sys.path[0] == str(test_directory):
            sys.path.pop(0)
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    class UpdateDiagnostic(runtime.SelfUpdateRuntimeTests):
        @classmethod
        def build_cli(cls, source, name):
            return super().build_cli(instrument_source(source), 'diagnostic-' + name)

        @classmethod
        def build_command(cls, argv):
            command = list(argv)
            if str(command[0]).lower().endswith('clang.exe') and '--no-default-config' not in command:
                command.insert(1, '--no-default-config')
            return super().build_command(command)

    result = unittest.TestResult()
    suite = unittest.TestSuite([UpdateDiagnostic('test_update_replaces_exact_bytes_after_three_provenance_bindings')])
    try:
        suite.run(result)
    finally:
        report['commands'].extend(runtime.COMMANDS)
        report['update_probe_artifacts'] = runtime.TEST_ARTIFACTS
        report['update_probe'] = {'outcome': 'pass' if result.wasSuccessful() else 'fail',
            'tests_run': result.testsRun, 'native_qualification': False,
            'scope': 'Test-only transport/verifier fixtures and instrumented assembly',
            'failures': [{'test': str(test), 'detail': detail[:LIMIT]} for test,detail in result.failures],
            'errors': [{'test': str(test), 'detail': detail[:LIMIT]} for test,detail in result.errors]}


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
