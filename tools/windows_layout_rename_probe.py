#!/usr/bin/env python3
"""Observe native Windows directory rename semantics with inert dummy bytes.

No CLI or candidate is built or executed. Exit zero means complete observations
and intact fixtures, including observed rename failures. It does not qualify a
CLI, installer, release, or an unemulated controller.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import windows_bootstrap_smoke as shared
finally:
    sys.path.pop(0)

ROOT = Path(__file__).resolve().parents[1]
MAX_DUMMY = 512
MAX_SECONDS = 60
DUMMY = b'Asm native rename diagnostic: inert bytes, never executable.\n'
READ_DIRECTORY = 0x00120081
DELETE_DIRECTORY = READ_DIRECTORY | 0x10000
HELD_CHILD = DELETE_DIRECTORY | 0x20
SHARE_ALL = 7
SHARE_READ_DELETE = 5
RENAME_CLASS = 65
RENAME_FLAGS = 2  # FILE_RENAME_POSIX_SEMANTICS; no replacement.
CASES = (
    ('snapshot_parent_held_child', READ_DIRECTORY, SHARE_READ_DELETE, False),
    ('shared_parent_held_child', READ_DIRECTORY, SHARE_ALL, False),
    ('delete_parent_held_child', DELETE_DIRECTORY, SHARE_ALL, False),
    ('shared_parent_closed_child', READ_DIRECTORY, SHARE_ALL, True),
)


class RenameHeader(ctypes.Structure):
    _fields_ = [('Flags', ctypes.c_uint32), ('RootDirectory', ctypes.c_void_p),
                ('FileNameLength', ctypes.c_uint32), ('FileName', ctypes.c_uint16 * 1)]


class IoStatusBlock(ctypes.Structure):
    _fields_ = [('Status', ctypes.c_void_p), ('Information', ctypes.c_size_t)]


def rename_bytes(parent, leaf):
    """Encode only a bounded fixed ASCII component in the native 64-bit ABI."""
    if (ctypes.sizeof(ctypes.c_void_p) != 8 or not leaf.isascii()
            or not 1 <= len(leaf) <= 64 or not all(c.isalnum() or c in '._-' for c in leaf)
            or leaf in ('.', '..')):
        raise ValueError('Require a bounded ASCII leaf and a 64-bit controller.')
    name = leaf.encode('utf-16le')
    return struct.pack('<I4xQI', RENAME_FLAGS, parent, len(name)) + name


def status_hex(value):
    return f'0x{value & 0xffffffff:08x}'


def native_controller(target):
    native = shared.require_native(target)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.IsWow64Process2.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort),
                                      ctypes.POINTER(ctypes.c_ushort)]
    kernel.IsWow64Process2.restype = ctypes.c_int
    process, host = ctypes.c_ushort(), ctypes.c_ushort()
    if not kernel.IsWow64Process2(ctypes.c_void_p(-1), ctypes.byref(process), ctypes.byref(host)):
        raise ctypes.WinError(ctypes.get_last_error())
    if ctypes.sizeof(ctypes.c_void_p) != 8:
        raise RuntimeError('A 64-bit Windows controller is required.')
    return {'native_machine': native, 'process_machine': process.value,
            'controller_emulated': bool(process.value), 'qualifies_unemulated_controller': False, 'pointer_bytes': ctypes.sizeof(ctypes.c_void_p)}


class Native:
    """Fixed OS entry points. File handles refer only to the owned fixture tree."""
    def __init__(self):
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        pointer, u32 = ctypes.c_void_p, ctypes.c_uint32
        declarations = {
            'CreateFileW': ([ctypes.c_wchar_p, u32, u32, pointer, u32, u32, pointer], pointer),
            'CloseHandle': ([pointer], ctypes.c_int),
            'GetModuleHandleW': ([ctypes.c_wchar_p], pointer),
            'GetProcAddress': ([pointer, ctypes.c_char_p], pointer),
            'GetModuleFileNameW': ([pointer, ctypes.c_wchar_p, u32], u32),
            'GetFileInformationByHandleEx': ([pointer, ctypes.c_int, pointer, u32], ctypes.c_int),
            'GetFinalPathNameByHandleW': ([pointer, ctypes.c_wchar_p, u32, u32], u32),
            'SetFilePointerEx': ([pointer, ctypes.c_int64, pointer, u32], ctypes.c_int),
            'ReadFile': ([pointer, pointer, u32, ctypes.POINTER(u32), pointer], ctypes.c_int),
            'GetVolumeInformationByHandleW': ([pointer, ctypes.c_wchar_p, u32,
                ctypes.POINTER(u32), ctypes.POINTER(u32), ctypes.POINTER(u32), ctypes.c_wchar_p, u32], ctypes.c_int),
        }
        for name, (arguments, result) in declarations.items():
            function = getattr(self.k, name)
            function.argtypes, function.restype = arguments, result
        self.module = self.k.GetModuleHandleW('ntdll.dll')
        if not self.module:
            raise ctypes.WinError(ctypes.get_last_error())
        def resolve(name, arguments):
            address = self.k.GetProcAddress(self.module, name.encode('ascii'))
            if not address:
                raise ctypes.WinError(ctypes.get_last_error())
            return ctypes.WINFUNCTYPE(ctypes.c_int32, *arguments)(address)
        self.set_information = resolve('NtSetInformationFile', [pointer, pointer, pointer, u32, u32])
        self.query_object = resolve('NtQueryObject', [pointer, u32, pointer, u32, pointer])
        self.handles = {}
        self.queries = []

    def open(self, path, access, share, directory, row):
        flags = 0x00200000 | (0x02000000 if directory else 0)  # reparse-point + backup semantics
        row.update(path=str(path), requested_access=access, requested_access_hex=f'0x{access:08x}',
                   share=share, share_hex=f'0x{share:08x}', create_disposition=3, flags=flags)
        handle = self.k.CreateFileW(str(path), access, share, None, 3, flags, None)
        if handle == ctypes.c_void_p(-1).value:
            row['open_error'] = ctypes.get_last_error()
            raise ctypes.WinError(row['open_error'])
        self.handles[handle] = row
        row['handle_closed'] = False
        info = self.describe(handle)
        row.update(info)
        if info['granted_access'] != access:
            raise RuntimeError('The granted access differs from the requested specific access mask.')
        return handle

    def describe(self, handle):
        # PUBLIC_OBJECT_BASIC_INFORMATION: attributes + GrantedAccess + 11 ULONGs.
        basic = ctypes.create_string_buffer(56)
        returned = ctypes.c_uint32()
        status = self.query_object(handle, 0, basic, len(basic), ctypes.byref(returned))
        query = {'operation': 'NtQueryObject', 'handle': handle, 'ntstatus': status_hex(status),
                 'returned_length': returned.value, 'raw_hex': basic.raw.hex()}
        self.queries.append(query)
        if status < 0 or not 8 <= returned.value <= len(basic):
            raise RuntimeError(f'NtQueryObject failed: {status_hex(status)}; length={returned.value}.')
        file_id = ctypes.create_string_buffer(24)  # FILE_ID_INFO: volume serial + FILE_ID_128.
        if not self.k.GetFileInformationByHandleEx(handle, 18, file_id, len(file_id)):
            raise ctypes.WinError(ctypes.get_last_error())
        path = ctypes.create_unicode_buffer(1024)
        size = self.k.GetFinalPathNameByHandleW(handle, path, len(path), 0)
        if not 0 < size < len(path):
            raise RuntimeError('Cannot bound the final namespace path.')
        return {'granted_access': struct.unpack_from('<I', basic.raw, 4)[0],
                'object_basic_status': status_hex(status), 'object_basic_length': returned.value,
                'object_basic_raw_hex': basic.raw.hex(), 'file_id_raw_hex': file_id.raw.hex(),
                'volume_serial': struct.unpack_from('<Q', file_id.raw)[0],
                'file_id': file_id.raw[8:].hex(), 'final_path': path.value}

    def read_dummy(self, handle):
        if not self.k.SetFilePointerEx(handle, 0, None, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        chunks, total = [], 0
        while total <= MAX_DUMMY:
            buffer, read = ctypes.create_string_buffer(MAX_DUMMY + 1 - total), ctypes.c_uint32()
            if not self.k.ReadFile(handle, buffer, len(buffer), ctypes.byref(read), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if not read.value:
                break
            chunks.append(buffer.raw[:read.value])
            total += read.value
        data = b''.join(chunks)
        if len(data) > MAX_DUMMY or data != DUMMY:
            raise RuntimeError('The bounded dummy bytes changed.')
        return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'raw_hex': data.hex()}

    def rename(self, source, parent, leaf, row):
        raw = rename_bytes(parent, leaf)
        info = ctypes.create_string_buffer(raw, len(raw))
        io = IoStatusBlock()
        ctypes.memset(ctypes.byref(io), 0xcc, ctypes.sizeof(io))
        row.update(information_class=RENAME_CLASS, flags=RENAME_FLAGS,
                   buffer_hex=raw.hex(), buffer_bytes=len(raw), leaf=leaf)
        status = self.set_information(source, ctypes.byref(io), info, len(raw), RENAME_CLASS)
        row.update(ntstatus_signed=status, ntstatus=status_hex(status),
                   io_status=status_hex(io.Status or 0), io_information=io.Information,
                   io_raw_hex=bytes(io).hex(), succeeded=status >= 0)
        if status == 0x103:  # A synchronous handle must not leave an incomplete operation.
            raise RuntimeError('The native operation returned STATUS_PENDING.')
        if status >= 0 and (io.Status or 0) & 0x80000000:
            raise RuntimeError('Successful call returned a failing IO completion status.')
        return status >= 0

    def close(self, handle):
        row = self.handles[handle]
        if not self.k.CloseHandle(handle):
            row['close_error'] = ctypes.get_last_error()
            raise ctypes.WinError(row['close_error'])
        row['handle_closed'] = True
        del self.handles[handle]

    def close_all(self):
        errors = []
        for handle in list(self.handles):
            try:
                self.close(handle)
            except Exception as error:
                errors.append(str(error))
        return errors

    def metadata(self, directory):
        path = ctypes.create_unicode_buffer(1024)
        size = self.k.GetModuleFileNameW(self.module, path, len(path))
        if not 0 < size < len(path):
            raise RuntimeError('Cannot bound the loaded ntdll path.')
        dll = Path(path.value)
        if dll.stat().st_size > 64 * 1024 * 1024:
            raise RuntimeError('The loaded ntdll exceeded its metadata byte bound.')
        with dll.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        fs, label = ctypes.create_unicode_buffer(256), ctypes.create_unicode_buffer(256)
        serial, component, flags = ctypes.c_uint32(), ctypes.c_uint32(), ctypes.c_uint32()
        if not self.k.GetVolumeInformationByHandleW(directory, label, len(label), ctypes.byref(serial),
                ctypes.byref(component), ctypes.byref(flags), fs, len(fs)):
            raise ctypes.WinError(ctypes.get_last_error())
        return {'ntdll': {'path': str(dll), 'bytes': dll.stat().st_size, 'sha256': digest,
                         'resolution': 'GetModuleHandleW + GetProcAddress; already loaded ntdll.dll'},
                'filesystem': {'name': fs.value, 'serial': serial.value, 'flags': flags.value,
                               'maximum_component': component.value}}


def namespace(root):
    rows = []
    def visit(path, depth=0):
        if depth > 4 or len(rows) >= 16:
            raise RuntimeError('The namespace observation exceeded its bound.')
        info = path.lstat()
        if path.is_symlink() or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise RuntimeError('A fixture became a reparse point.')
        row = {'path': path.relative_to(root).as_posix(), 'file_id': info.st_ino,
               'device': info.st_dev, 'bytes': info.st_size, 'directory': path.is_dir()}
        rows.append(row)
        if row['directory']:
            for entry in sorted(path.iterdir()):
                visit(entry, depth + 1)
    visit(root)
    return rows


def run_case(api, owned, definition, report, save, *, precursor=False):
    name, access, share, close_child = definition
    row = {'name': name, 'kind': 'held_file_move' if precursor else 'directory_publication',
           'expected_native_status': 'unknown', 'observations_complete': False,
           'close_descendant_before_directory_rename': close_child, 'handles': {}, 'operations': []}
    report['cases'].append(row)
    case = owned / name
    case.mkdir()
    stage, versions = case / 'stage', case / 'versions'
    stage.mkdir()
    versions.mkdir()
    source = stage / 'version-stage'
    source.mkdir()
    original = stage / 'candidate.bin' if precursor else source / 'dummy.bin'
    original.write_bytes(DUMMY)
    try:
        save()
        child = api.open(original, HELD_CHILD, SHARE_READ_DELETE, False,
                         row['handles'].setdefault('child', {}))
        save()
        directory = api.open(source, DELETE_DIRECTORY, SHARE_ALL, True,
                             row['handles'].setdefault('source_directory', {}))
        save()
        held = {'child': child, 'source_directory': directory}
        if not precursor:
            parent = api.open(versions, access, share, True,
                              row['handles'].setdefault('target_directory', {}))
            held['target_directory'] = parent
        save()
        row['filesystem_and_tools'] = api.metadata(directory)
        row['namespace_before'] = namespace(case)
        row['dummy_before'] = api.read_dummy(child)
        row['held_before'] = {name: api.describe(handle) for name, handle in held.items()}
        save()
        if precursor:
            operation = {'operation': 'move_held_dummy_into_version_stage', 'attempted': True}
            row['operations'].append(operation)
            save()
            api.rename(child, directory, 'dummy.bin', operation)
        else:
            # Independent setup prevents a failed precursor from suppressing
            # directory observations. No file is executed in either setup.
            if close_child:
                api.close(child)
            operation = {'operation': 'publish_directory_after_closing_descendant' if close_child else
                         'publish_directory_with_held_descendant', 'attempted': True}
            row['operations'].append(operation)
            save()
            api.rename(directory, parent, 'published', operation)
        save()
        row['held_after'] = {}
        for name, handle in held.items():
            if name == 'child' and close_child:
                continue
            current = api.describe(handle)
            row['held_after'][name] = current
            if current['file_id_raw_hex'] != row['held_before'][name]['file_id_raw_hex']:
                raise RuntimeError(f'The held {name} identity changed.')
        if not close_child:
            row['dummy_after'] = api.read_dummy(child)
        row['namespace_after_rename'] = namespace(case)
    except Exception as error:
        row['error'] = {'type': type(error).__name__, 'message': str(error), 'traceback': traceback.format_exc()}
    finally:
        row['close_errors'] = api.close_all()
        try:
            row['namespace_final'] = namespace(case)
            files = [item for item in row['namespace_final'] if not item['directory']]
            if len(files) != 1:
                raise RuntimeError('The fixture lost or duplicated its single dummy file.')
            payload = case / files[0]['path']
            info = payload.lstat()
            if info.st_size > MAX_DUMMY or info.st_nlink != 1:
                raise RuntimeError('The retained dummy is not bounded and single-link.')
            with payload.open('rb') as stream:
                data = stream.read(MAX_DUMMY + 1)
            if data != DUMMY:
                raise RuntimeError('The retained dummy bytes changed.')
            row['dummy_final'] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), 'raw_hex': data.hex()}
            succeeded = bool(row['operations'] and row['operations'][0].get('succeeded'))
            expected = ('stage/version-stage/dummy.bin' if succeeded else 'stage/candidate.bin') if precursor else (
                'versions/published/dummy.bin' if succeeded else 'stage/version-stage/dummy.bin')
            if files[0]['path'] != expected:
                raise RuntimeError('The namespace differs from the recorded native rename result.')
            initial = row.get('held_before', {}).get('child')
            if initial:
                retained = api.open(payload, HELD_CHILD, SHARE_READ_DELETE, False,
                                    row['handles'].setdefault('retained_child', {}))
                if api.describe(retained)['file_id_raw_hex'] != initial['file_id_raw_hex']:
                    raise RuntimeError('The retained namespace file identity differs from the held dummy.')
                api.read_dummy(retained)
        except Exception as error:
            row['integrity_error'] = str(error)
        row['close_errors'].extend(api.close_all())
        row['observations_complete'] = (not any(key in row for key in ('error', 'integrity_error'))
                                        and not row['close_errors'] and not api.handles)
        save()


def watchdog(output):
    """Retain the last atomic observation, then let process termination close handles."""
    try:
        report = json.loads((output / 'report.json').read_text(encoding='utf-8'))
        report.update(outcome='incomplete', timed_out=True,
                      handle_cleanup='process termination; explicit closure not observed')
        shared.atomic_report(output, report)
    finally:
        os._exit(1)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=tuple(shared.MACHINES), required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    output = args.output.absolute()
    if output.exists():
        print('Use a new output directory; existing evidence is preserved.', file=sys.stderr)
        return 1
    output.mkdir(parents=True)
    report = {'schema': 'asm-windows-layout-rename-probe-v1', 'target': args.target,
              'requested_source_commit': args.source_commit, 'outcome': 'incomplete',
              'qualifies_cli_runtime': False, 'qualifies_release': False,
              'qualifies_published_installer': False, 'expected_native_statuses': 'unknown',
              'scope': 'native FileRenameInformationEx65 with inert owned fixtures; no CLI execution',
              'started_utc': datetime.now(timezone.utc).isoformat(), 'commands': [], 'cases': [],
              'limits': {'total_seconds': MAX_SECONDS, 'dummy_bytes': MAX_DUMMY,
                         'case_count': len(CASES) + 1, 'namespace_entries_per_case': 16},
              'host': {'platform': platform.platform(), 'machine': platform.machine(),
                       'python': sys.version, 'image_os': os.environ.get('ImageOS'),
                       'image_version': os.environ.get('ImageVersion')},
              'documentation': {'retrieved': '2026-11-05', 'source':
                  'https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information',
                  'limit': 'General open-file remarks do not alone establish information-class-65 behavior.'}}
    save = lambda: shared.atomic_report(output, report)
    save()
    timer = threading.Timer(MAX_SECONDS, watchdog, args=(output,))
    timer.daemon = True
    timer.start()
    started = time.monotonic()
    try:
        shared.commit_id(args.source_commit)
        report['host'].update(native_controller(args.target))
        report['host']['windows_version'] = list(sys.getwindowsversion())
        git = Path('C:/Program Files/Git/cmd/git.exe')
        if not git.is_file():
            raise RuntimeError('The fixed Git executable is absent.')
        report.update(shared.source_identity(ROOT, args.source_commit, git, report['commands']))
        report['inputs'] = {}
        for relative in ('tools/windows_layout_rename_probe.py', 'tools/windows_bootstrap_smoke.py',
                         'cli/windows/x86_64/versioned_update.s', 'cli/windows/x86_64/platform.s'):
            data = shared.bounded_bytes(ROOT / relative)
            report['inputs'][relative] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        owned = Path(tempfile.mkdtemp(prefix='owned-rename-', dir=output))
        report['owned_root'] = owned.relative_to(output).as_posix()
        api = Native()
        report['native_queries'] = api.queries
        run_case(api, owned, ('held_file_move_precursor', DELETE_DIRECTORY, SHARE_ALL, False),
                 report, save, precursor=True)
        for definition in CASES:
            run_case(api, owned, definition, report, save)
        shared.source_identity(ROOT, args.source_commit, git, report['commands'])
        if all(row['observations_complete'] for row in report['cases']) and len(report['cases']) == len(CASES) + 1:
            report['outcome'] = 'observed'
    except Exception as error:
        report['exception'] = {'type': type(error).__name__, 'message': str(error), 'traceback': traceback.format_exc()}
        print(f'Windows layout rename probe incomplete: {error}', file=sys.stderr)
    finally:
        report['seconds'] = round(time.monotonic() - started, 6)
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        save()
        timer.cancel()
    return 0 if report['outcome'] == 'observed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
