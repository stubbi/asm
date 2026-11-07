#!/usr/bin/env python3
"""Bounded native rename comparison on owned files; never used by the CLI.

SPDX-License-Identifier: AGPL-3.0-or-later
This diagnostic changes no permissions policy or replacement protocol.
The child is created suspended and is never resumed. Only its owned files
and process are used. A failed experiment remains a failed observation.
"""
import ctypes as c
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

U16, U32, U64, PTR = c.c_uint16, c.c_uint32, c.c_uint64, c.c_void_p
SOURCE_ACCESS = 0x130081
DIRECTORY_ACCESS = 0x120081
IMAGE_ACCESS = 0x1200A1


class UnicodeString(c.Structure):
    _fields_ = [('length', U16), ('capacity', U16), ('buffer', PTR)]


class ObjectAttributes(c.Structure):
    _fields_ = [('length', U32), ('root', PTR), ('name', PTR), ('attributes', U32),
                ('security', PTR), ('quality', PTR)]


class IoStatus(c.Structure):
    _fields_ = [('status', PTR), ('information', U64)]


class FileInformation(c.Structure):
    _fields_ = [('attributes', U32), ('creation', U64), ('access', U64),
                ('write', U64), ('volume', U32), ('size_high', U32),
                ('size_low', U32), ('links', U32), ('index_high', U32), ('index_low', U32)]
    _pack_ = 4


class Startup(c.Structure):
    _fields_ = [('size', U32), ('reserved', PTR), ('desktop', PTR), ('title', PTR),
                ('x', U32), ('y', U32), ('width', U32), ('height', U32),
                ('columns', U32), ('rows', U32), ('fill', U32), ('flags', U32),
                ('show', U16), ('reserved_count', U16), ('reserved_bytes', PTR),
                ('stdin', PTR), ('stdout', PTR), ('stderr', PTR)]


class ProcessInformation(c.Structure):
    _fields_ = [('process', PTR), ('thread', PTR), ('pid', U32), ('tid', U32)]


def rename_buffer(parent, name):
    encoded = name.encode('utf-16-le')
    if len(encoded) > 510 or '/' in name or '\\' in name or not name:
        raise ValueError('one bounded owned filename is required')
    data = c.create_string_buffer(8192)
    U32.from_buffer(data, 0).value = 3
    PTR.from_buffer(data, 8).value = parent
    U32.from_buffer(data, 16).value = len(encoded)
    c.memmove(c.addressof(data) + 20, encoded + b'\0\0', len(encoded) + 2)
    return data, 20 + len(encoded)


def run(binary, set_owner, security, result=None):
    if os.name != 'nt' or c.sizeof(PTR) != 8:
        raise ValueError('native 64-bit Windows is required')
    kernel = c.WinDLL('kernel32', use_last_error=True)
    nt = c.WinDLL('ntdll', use_last_error=True)
    kernel.CreateFileW.argtypes = [c.c_wchar_p, U32, U32, PTR, U32, U32, PTR]
    kernel.CreateFileW.restype = PTR
    kernel.CloseHandle.argtypes = [PTR]
    kernel.GetFileInformationByHandle.argtypes = [PTR, c.POINTER(FileInformation)]
    kernel.GetFinalPathNameByHandleW.argtypes = [PTR, c.c_wchar_p, U32, U32]
    kernel.GetFinalPathNameByHandleW.restype = U32
    kernel.SetFilePointerEx.argtypes = [PTR, c.c_int64, PTR, U32]
    kernel.ReadFile.argtypes = [PTR, PTR, U32, c.POINTER(U32), PTR]
    kernel.CreateProcessW.argtypes = [c.c_wchar_p, c.c_wchar_p, PTR, PTR, c.c_int,
                                    U32, PTR, c.c_wchar_p, c.POINTER(Startup), c.POINTER(ProcessInformation)]
    kernel.TerminateProcess.argtypes = [PTR, U32]
    kernel.CreateJobObjectW.argtypes = [PTR, c.c_wchar_p]
    kernel.CreateJobObjectW.restype = PTR
    kernel.SetInformationJobObject.argtypes = [PTR, U32, PTR, U32]
    kernel.AssignProcessToJobObject.argtypes = [PTR, PTR]
    kernel.WaitForSingleObject.argtypes = [PTR, U32]
    kernel.WaitForSingleObject.restype = U32
    nt.NtCreateFile.argtypes = [c.POINTER(PTR), U32, c.POINTER(ObjectAttributes), c.POINTER(IoStatus),
                               PTR, U32, U32, U32, U32, PTR, U32]
    nt.NtCreateFile.restype = c.c_int32
    nt.NtSetInformationFile.argtypes = [PTR, c.POINTER(IoStatus), PTR, U32, U32]
    nt.NtSetInformationFile.restype = c.c_int32
    nt.NtQueryObject.argtypes = [PTR, U32, PTR, U32, PTR]
    nt.NtQueryObject.restype = c.c_int32
    nt.NtQueryInformationProcess.argtypes = [PTR, U32, PTR, U32, PTR]
    nt.NtQueryInformationProcess.restype = c.c_int32
    invalid = PTR(-1).value
    if result is None:
        result = {}
    result.update(scope='owned ordinary versus suspended-image target, exact rename class65 request',
                  native_qualification=False, cases=[])

    def checked(value):
        if not value:
            raise c.WinError(c.get_last_error())
        return value

    def open_at(parent, name, access):
        buffer = c.create_unicode_buffer(name)
        string = UnicodeString(len(name.encode('utf-16-le')), len(name.encode('utf-16-le')), c.addressof(buffer))
        attributes = ObjectAttributes(c.sizeof(ObjectAttributes), parent, c.addressof(string), 64, None, None)
        status, handle = IoStatus(), PTR()
        code = nt.NtCreateFile(c.byref(handle), access, c.byref(attributes), c.byref(status),
                               None, 128, 7, 1, 0x200020, None, 0) & 0xffffffff
        if code != 0 or not handle.value:
            if handle.value and handle.value != invalid:
                kernel.CloseHandle(handle.value)
            raise OSError(f'NtCreateFile status 0x{code:08x}')
        return handle.value

    def information(handle, require_name=True):
        info = FileInformation()
        checked(kernel.GetFileInformationByHandle(handle, c.byref(info)))
        basic = c.create_string_buffer(56)
        status = nt.NtQueryObject(handle, 0, basic, 56, None) & 0xffffffff
        if status != 0:
            raise OSError(f'NtQueryObject status 0x{status:08x}')
        name = c.create_unicode_buffer(4096)
        count = kernel.GetFinalPathNameByHandleW(handle, name, 4096, 0)
        if not 0 < count < 4096 and require_name:
            raise OSError('bounded final path query failed')
        return {'final_path_error': c.get_last_error() if not count else None, 'attributes': info.attributes, 'volume': info.volume,
                'file_index': (info.index_high << 32) | info.index_low,
                'links': info.links, 'bytes': (info.size_high << 32) | info.size_low,
                'granted_access': U32.from_buffer(basic, 4).value, 'final_path': name.value if 0 < count < 4096 else None}

    def digest(handle):
        checked(kernel.SetFilePointerEx(handle, 0, None, 0))
        block, count, total, h = c.create_string_buffer(65536), U32(), 0, hashlib.sha256()
        while True:
            checked(kernel.ReadFile(handle, block, 65536, c.byref(count), None))
            if not count.value:
                break
            total += count.value
            if total > 67108864:
                raise OSError('owned digest input exceeded bound')
            h.update(block.raw[:count.value])
        checked(kernel.SetFilePointerEx(handle, 0, None, 0))
        return {'bytes': total, 'sha256': h.hexdigest()}

    binary = Path(binary)
    size = binary.stat().st_size
    if not 328 <= size <= 67108845:
        raise ValueError('the owned CLI input must fit the64MiB probe bound')
    original = binary.read_bytes()
    if len(original) != size:
        raise OSError('CLI probe input changed while reading')
    candidate = original + b'owned rename probe\0'
    with tempfile.TemporaryDirectory(prefix='asm-owned-rename-probe-') as temporary:
        for mapped in [False, True]:
            row = {'case': 'suspended-image' if mapped else 'ordinary', 'stage': 'create-owned-files'}
            result['cases'].append(row)
            handles, child, child_job = [], ProcessInformation(), None
            try:
                directory = Path(temporary) / row['case']
                directory.mkdir()
                source, target = directory / 'payload', directory / 'asm.exe'
                source.write_bytes(candidate)
                target.write_bytes(original)
                set_owner([directory, source, target])
                row['security'] = security([directory, source, target])
                parent = kernel.CreateFileW(str(directory), DIRECTORY_ACCESS, 7, None, 3, 0x02200000, None)
                if not parent or parent == invalid:
                    raise c.WinError(c.get_last_error())
                handles.append(parent)
                source_handle = open_at(parent, 'payload', SOURCE_ACCESS)
                handles.append(source_handle)
                target_handle = open_at(parent, 'asm.exe', IMAGE_ACCESS)
                handles.append(target_handle)
                row['parent'] = information(parent)
                row['source_before'], row['target_before'] = information(source_handle), information(target_handle)
                row['source_digest_before'], row['target_digest_before'] = digest(source_handle), digest(target_handle)
                row['stage'] = 'create-suspended-child' if mapped else 'rename'
                if mapped:
                    child_job = checked(kernel.CreateJobObjectW(None, None))
                    limits = c.create_string_buffer(144)
                    U32.from_buffer(limits, 16).value = 0x2000 # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                    checked(kernel.SetInformationJobObject(child_job, 9, limits, 144))
                    startup = Startup()
                    startup.size = c.sizeof(Startup)
                    command = c.create_unicode_buffer('"' + str(target) + '" version --json')
                    checked(kernel.CreateProcessW(str(target), command, None, None, 0, 4, None,
                                                   str(directory), c.byref(startup), c.byref(child)))
                    checked(kernel.AssignProcessToJobObject(child_job, child.process))
                    row['child_pid'] = child.pid
                    image = PTR(target_handle)
                    row['image_binding'] = nt.NtQueryInformationProcess(child.process, 44, c.byref(image), 8, None) & 0xffffffff
                    if row['image_binding'] != 0:
                        raise OSError('child was not bound to the held target image')
                row['stage'] = 'rename'
                data, size = rename_buffer(parent, 'asm.exe')
                completion = IoStatus()
                completion.status = 0x11111111
                row['request'] = {'source_access': SOURCE_ACCESS, 'parent_access': DIRECTORY_ACCESS,
                                  'held_target_access': IMAGE_ACCESS, 'flags': 3, 'class': 65,
                                  'filename': 'asm.exe', 'filename_bytes': 14, 'buffer_bytes': size}
                row['status'] = nt.NtSetInformationFile(source_handle, c.byref(completion), data, size, 65) & 0xffffffff
                row['completion_status'] = (completion.status or 0) & 0xffffffff
                row['source_after'], row['held_target_after'] = information(source_handle, False), information(target_handle, False)
                current = open_at(parent, 'asm.exe', 0x120081)
                handles.append(current)
                row['current_after'], row['current_digest_after'] = information(current), digest(current)
                row['held_target_digest_after'] = digest(target_handle)
                expected = row['source_digest_before'] if row['status'] == 0 else row['target_digest_before']
                if row['current_digest_after'] != expected:
                    raise OSError('rename status and current namespace bytes disagree')
                if row['held_target_digest_after'] != row['target_digest_before']:
                    raise OSError('held original bytes changed')
                row['stage'] = 'complete'
            except Exception as error:
                row['error'] = {'type': type(error).__name__, 'message': str(error)[:2048]}
            finally:
                if child.process:
                    terminated = bool(kernel.TerminateProcess(child.process, 7))
                    waited = kernel.WaitForSingleObject(child.process, 10000)
                    if child_job:
                        kernel.CloseHandle(child_job)
                        child_job = None
                    if waited != 0:
                        waited = kernel.WaitForSingleObject(child.process, 10000)
                    row['child_cleanup'] = {'terminated': terminated, 'wait_status': waited}
                    kernel.CloseHandle(child.thread)
                    kernel.CloseHandle(child.process)
                    if waited != 0:
                        row['cleanup_error'] = 'owned suspended child did not terminate within the bound'
                if child_job:
                    kernel.CloseHandle(child_job)
                for handle in reversed(handles):
                    kernel.CloseHandle(handle)
    return result


def main():
    import argparse
    import importlib.util
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if os.name != 'nt' or c.sizeof(PTR) != 8:
        parser.error('native 64-bit Windows is required')
    if args.evidence.exists():
        parser.error('the evidence destination must not already exist')
    spec = importlib.util.spec_from_file_location('owned_probe_diagnostics', Path(__file__).with_name('native_diagnostics.py'))
    diagnostics = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(diagnostics)
    report = {'native_qualification': False, 'cases': []}

    def collect():
        run(args.binary, diagnostics.set_fixture_user_owner, diagnostics.api_security, report)
        if any(row.get('stage') != 'complete' or row.get('cleanup_error') for row in report['cases']):
            report['collection_failed'] = True

    return diagnostics.collect_evidence(args.evidence, report, collect)


if __name__ == '__main__':
    raise SystemExit(main())
