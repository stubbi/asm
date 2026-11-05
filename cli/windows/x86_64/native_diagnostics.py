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
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
LOCAL = Path(__file__).resolve().parent
LIMIT = 65536


def diagnostic_source(module):
    source = module.prepare(ROOT / 'cli/asm.s')
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
            for kind, name in [(1, 'user'), (4, 'default_owner')]:
                data = ctypes.create_string_buffer(4096)
                needed = wintypes.DWORD()
                if advapi.GetTokenInformation(token, kind, data, 4096, ctypes.byref(needed)):
                    result['token'][name] = sid_text(pointer.from_buffer(data).value)
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
                        row['sddl'] = ctypes.wstring_at(value, min(length, 16384))
                        row['sddl_truncated'] = length > 16384
                    finally:
                        kernel.LocalFree(value)
                else:
                    row['sddl_error'] = ctypes.get_last_error()
            finally:
                kernel.LocalFree(security)
        result['paths'].append(row)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain-bin', type=Path, default=Path('C:/Program Files/LLVM/bin'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This diagnostic fixture requires native Windows')
    if args.evidence.exists():
        parser.error('The evidence destination must not already exist')
    spec = importlib.util.spec_from_file_location('windows_x64', ROOT / 'tools/windows_x64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    report = {'kind': 'windows-x64-adapter-diagnostics', 'native_qualification': False, 'commands': []}

    def run(argv, **options):
        started = time.monotonic()
        result = subprocess.run(list(map(str, argv)), capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=30, **options)
        report['commands'].append({'argv': list(map(str, argv)), 'exit_code': result.returncode,
            'stdout': result.stdout[:LIMIT], 'stderr': result.stderr[:LIMIT],
            'output_truncated': len(result.stdout) > LIMIT or len(result.stderr) > LIMIT,
            'seconds': round(time.monotonic() - started, 6)})
        return result

    with tempfile.TemporaryDirectory(prefix='asm-x64-native-diagnostic-') as temporary:
        work = Path(temporary)
        source, obj, binary = (work / 'diagnostic.s', work / 'diagnostic.obj', work / 'diagnostic.exe')
        text = diagnostic_source(module)
        source.write_text(text)
        report['assembly_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        compile_result = run([args.toolchain_bin / 'clang.exe', '--target=x86_64-pc-windows-msvc',
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
                environment = dict(os.environ, HOME=str(home), USERPROFILE=str(home))
                new_project = work / 'hello'
                run([binary, 'new', new_project], cwd=work, env=environment)
                run([binary, 'installed', '--json'], cwd=work, env=environment)
                version = json.loads(run([binary, 'version', '--json'], cwd=work, env=environment).stdout)['version']
                installation = home / '.local/bin/asm.exe'
                installation.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(binary, installation)
                run([installation, 'self', 'update', version, '--json'], cwd=work, env=environment)
                report['security'] = api_security([
                    *reversed(installation.parents), installation, new_project,
                    new_project / 'asm.toml', new_project / 'src/main.s'])
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    with args.evidence.open('x', encoding='utf-8') as output:
        json.dump(report, output, indent=2)
        output.write('\n')
    print('Adapter diagnostic evidence:', args.evidence)
    return 1 if report.get('build_failed') else 0


if __name__ == '__main__':
    raise SystemExit(main())
