#!/usr/bin/env python3
"""Measure one-step replacement after unmapping a suspended owned CLI image.

This isolated Windows experiment never resumes a child. It changes only copied
fixtures in its own temporary directory. A measured denial is a result, not CLI
qualification. It does not change production updater behavior or its tests.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import ctypes as C
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 8 * 1024 * 1024
D, P, Z = C.c_uint32, C.c_void_p, C.c_size_t


class FileInfo(C.Structure):
    _fields_ = [('attributes', D), ('times', D * 6), ('volume', D),
                ('size_high', D), ('size_low', D), ('links', D),
                ('index_high', D), ('index_low', D)]


class BasicInfo(C.Structure):
    _fields_ = [('reserved1', P), ('peb', P), ('reserved2', P * 2),
                ('pid', Z), ('reserved3', P)]


class MemoryInfo(C.Structure):
    _fields_ = [('base', P), ('allocation_base', P), ('allocation_protect', D),
                ('partition', C.c_uint16), ('region_size', Z), ('state', D),
                ('protect', D), ('kind', D)]


class RenameInfo(C.Structure):
    _fields_ = [('flags', D), ('root', P), ('length', D), ('name', C.c_uint16 * 1)]


class IoResult(C.Union):
    _fields_ = [('status', C.c_int32), ('pointer', P)]


class IoStatus(C.Structure):
    _anonymous_ = ('result',)
    _fields_ = [('result', IoResult), ('information', Z)]


class JobLimits(C.Structure):
    _fields_ = [('process_time', C.c_int64), ('job_time', C.c_int64), ('flags', D),
                ('minimum_working_set', Z), ('maximum_working_set', Z),
                ('active_process_limit', D), ('affinity', Z), ('priority', D), ('scheduling', D)]


class ExtendedJobLimits(C.Structure):
    _fields_ = [('basic', JobLimits), ('io', C.c_uint64 * 6),
                ('process_memory', Z), ('job_memory', Z), ('peak_process_memory', Z), ('peak_job_memory', Z)]


def layouts():
    actual = {'pointer': C.sizeof(P), 'file_info': C.sizeof(FileInfo),
              'basic_info': C.sizeof(BasicInfo), 'basic_peb_offset': BasicInfo.peb.offset,
              'memory_info': C.sizeof(MemoryInfo), 'memory_region_offset': MemoryInfo.region_size.offset,
              'rename_info': C.sizeof(RenameInfo), 'rename_name_offset': RenameInfo.name.offset,
              'io_status': C.sizeof(IoStatus), 'extended_job_limits': C.sizeof(ExtendedJobLimits)}
    expected = dict(pointer=8, file_info=52, basic_info=48, basic_peb_offset=8,
                    memory_info=48, memory_region_offset=24, rename_info=24,
                    rename_name_offset=20, io_status=16, extended_job_limits=144)
    if actual != expected:
        raise RuntimeError(f'The native 64-bit fixture layout is unsupported: {actual}')
    return actual


def module_at(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Windows:
    def __init__(self):
        from ctypes import wintypes as W
        self.kernel = C.WinDLL('kernel32', use_last_error=True)
        self.advapi = C.WinDLL('advapi32', use_last_error=True)
        def api(dll, name, result, *arguments):
            function = getattr(dll, name)
            function.restype, function.argtypes = result, list(arguments)
            return function
        k, a = self.kernel, self.advapi
        self.open = api(k, 'CreateFileW', P, W.LPCWSTR, D, D, P, D, D, P)
        self.close = api(k, 'CloseHandle', W.BOOL, P)
        self.info = api(k, 'GetFileInformationByHandle', W.BOOL, P, C.POINTER(FileInfo))
        self.read = api(k, 'ReadFile', W.BOOL, P, P, D, C.POINTER(D), P)
        self.seek = api(k, 'SetFilePointerEx', W.BOOL, P, C.c_int64, P, D)
        self.read_process = api(k, 'ReadProcessMemory', W.BOOL, P, P, P, Z, C.POINTER(Z))
        self.memory = api(k, 'VirtualQueryEx', Z, P, P, C.POINTER(MemoryInfo), Z)
        self.wait = api(k, 'WaitForSingleObject', D, P, D)
        self.exit_code = api(k, 'GetExitCodeProcess', W.BOOL, P, C.POINTER(D))
        self.terminate = api(k, 'TerminateProcess', W.BOOL, P, D)
        self.job = api(k, 'CreateJobObjectW', P, P, W.LPCWSTR)
        self.job_limits = api(k, 'SetInformationJobObject', W.BOOL, P, C.c_int, P, D)
        self.assign = api(k, 'AssignProcessToJobObject', W.BOOL, P, P)
        self.volume = api(k, 'GetVolumeInformationByHandleW', W.BOOL, P, W.LPWSTR, D, P, P, P, W.LPWSTR, D)
        self.drive = api(k, 'GetDriveTypeW', D, W.LPCWSTR)
        self.security = api(a, 'GetSecurityInfo', D, P, C.c_int, D, P, P, P, P, C.POINTER(P))
        self.sddl = api(a, 'ConvertSecurityDescriptorToStringSecurityDescriptorW', W.BOOL, P, D, D, C.POINTER(P), C.POINTER(D))
        self.free = api(k, 'LocalFree', P, P)
        module = api(k, 'GetModuleHandleW', P, W.LPCWSTR)('ntdll.dll')
        address = api(k, 'GetProcAddress', P, P, C.c_char_p)
        require(module, 'The loaded ntdll module is unavailable.')
        def native(name, *arguments):
            pointer = address(module, name.encode('ascii'))
            require(pointer, f'{name} is unavailable; no fallback is permitted.')
            return C.WINFUNCTYPE(C.c_int32, *arguments)(pointer)
        self.query = native('NtQueryInformationProcess', P, C.c_int, P, D, P)
        self.unmap = native('NtUnmapViewOfSection', P, P)
        self.rename = native('NtSetInformationFile', P, C.POINTER(IoStatus), P, D, C.c_int)

    def check(self, value):
        if not value:
            raise C.WinError(C.get_last_error())
        return value

    def handle(self, path, access, directory=False):
        value = self.open(str(path), access, 7, None, 3, 0x200000 | (0x2000000 if directory else 0), None)
        if value == P(-1).value:
            raise C.WinError(C.get_last_error())
        return value

    def identity(self, handle):
        info = FileInfo()
        self.check(self.info(handle, C.byref(info)))
        require(not info.attributes & 0x400, 'The fixture must not be a reparse point.')
        return {'volume_serial': info.volume, 'file_index': info.index_high << 32 | info.index_low,
                'links': info.links, 'bytes': info.size_high << 32 | info.size_low, 'attributes': info.attributes}

    def descriptor(self, handle):
        security, value, count = P(), P(), D()
        status = self.security(handle, 1, 5, None, None, None, None, C.byref(security))
        require(status == 0, f'GetSecurityInfo failed with {status}.')
        try:
            self.check(self.sddl(security, 1, 5, C.byref(value), C.byref(count)))
            require(0 < count.value <= 16384, 'The fixture descriptor exceeds its bound.')
            return C.wstring_at(value, count.value - 1)
        finally:
            if value.value:
                self.free(value)
            self.free(security)

    def snapshot(self, path):
        handle = self.handle(path, 0x120089)
        try:
            identity = self.identity(handle)
            require(not identity['attributes'] & 0x10 and identity['bytes'] <= LIMIT,
                    'The fixture is not a bounded regular file.')
            self.check(self.seek(handle, 0, None, 0))
            digest, remaining = hashlib.sha256(), identity['bytes']
            buffer = C.create_string_buffer(65536)
            while remaining:
                count = D()
                request = min(remaining, len(buffer))
                self.check(self.read(handle, buffer, request, C.byref(count), None))
                require(0 < count.value <= request, 'The fixture read ended early or exceeded its bound.')
                digest.update(buffer.raw[:count.value])
                remaining -= count.value
            count = D()
            self.check(self.read(handle, buffer, 1, C.byref(count), None))
            require(count.value == 0, 'The fixture grew during its read.')
            require(self.identity(handle) == identity, 'The fixture identity changed during its read.')
            return dict(identity=identity, sha256=digest.hexdigest(), owner_dacl_sddl=self.descriptor(handle))
        finally:
            self.close(handle)

    def memory_info(self, process, base):
        info = MemoryInfo()
        require(self.memory(process, base, C.byref(info), C.sizeof(info)) == C.sizeof(info),
                'VirtualQueryEx did not return the complete native layout.')
        return {'base': info.base, 'allocation_base': info.allocation_base, 'region_bytes': info.region_size,
                'state': info.state, 'protection': info.protect, 'type': info.kind}

    def remote_bytes(self, process, address, length):
        require(0 < length <= 4096, 'The remote fixture read exceeds its bound.')
        data, count = C.create_string_buffer(length), Z()
        self.check(self.read_process(process, address, data, length, C.byref(count)))
        require(count.value == length, 'The remote fixture read was short.')
        return data.raw


def same_file(left, right):
    return (left['volume_serial'], left['file_index']) == (right['volume_serial'], right['file_index'])


def experiment(api, work, image, target, mode, owner, report, checkpoint):
    import _winapi
    case = {'mode': mode, 'fixture': 'error', 'never_resumed': True, 'stage': 'create-fixtures'}
    report['cases'].append(case)
    directory = work / mode
    directory.mkdir()
    owner.own_directory(directory, work)
    original, candidate = directory / 'original.exe', directory / 'candidate.exe'
    original.write_bytes(image)
    candidate.write_bytes(image)
    owner.own_path(original, work)
    owner.own_path(candidate, work)
    case['original_before'], case['candidate_before'] = api.snapshot(original), api.snapshot(candidate)
    before, new = case['original_before'], case['candidate_before']
    require(not same_file(before['identity'], new['identity']), 'The two fixtures have the same file identity.')
    require(before['identity']['links'] == new['identity']['links'] == 1, 'A fixture has extra hard links.')
    require(before['identity']['attributes'] == new['identity']['attributes'] and
            before['owner_dacl_sddl'] == new['owner_dacl_sddl'], 'The candidate and original metadata differ.')
    handles, process, thread, job = [], None, None, None
    try:
        parent_access = 0x120089 if target == 'aarch64-windows' else 0x120081
        parent = api.handle(directory, parent_access, directory=True)
        handles.append(parent)
        case['parent_identity'], case['parent_sddl'] = api.identity(parent), api.descriptor(parent)
        filesystem, flags = C.create_unicode_buffer(32), D()
        api.check(api.volume(parent, None, 0, None, None, C.byref(flags), filesystem, len(filesystem)))
        case['filesystem'] = {'name': filesystem.value, 'flags': flags.value, 'drive_type': api.drive(directory.anchor)}
        require(filesystem.value == 'NTFS' and flags.value & 8 and case['filesystem']['drive_type'] == 3,
                'The probe requires fixed local NTFS with persistent access lists.')
        source_access = 0x130080 if target == 'aarch64-windows' else 0x130081
        candidate_handle = api.handle(candidate, source_access)
        handles.append(candidate_handle)
        original_handle = api.handle(original, 0x1200A9 if target == 'aarch64-windows' else 0x1200A1)
        handles.append(original_handle)
        require(same_file(api.identity(candidate_handle), new['identity']) and same_file(api.identity(original_handle), before['identity']),
                'The opened handles do not identify the created fixtures.')
        case['open_contract'] = {'source_access': source_access, 'parent_access': parent_access,
                                 'share_access': 7, 'open_reparse_point': True, 'synchronous': True}
        case['stage'] = 'create-owned-suspended-child'
        startup = subprocess.STARTUPINFO()
        arguments = [str(original), 'version', '--json']
        process, thread, pid, _ = _winapi.CreateProcess(str(original), subprocess.list2cmdline(arguments),
            None, None, False, 0x4 | 0x08000000 | 0x400,
            {'SystemRoot': os.environ['SystemRoot']}, str(directory), startup)
        case['child_pid'] = pid
        case['stage'] = 'protect-owned-child-job'
        checkpoint()
        # Closing this unnamed job kills only this child, including on controller termination.
        job = api.check(api.job(None, None))
        limits = ExtendedJobLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        api.check(api.job_limits(job, 9, C.byref(limits), C.sizeof(limits)))
        api.check(api.assign(job, process))
        case['kill_on_job_close'] = True
        require(api.wait(process, 0) == 258, 'The suspended child is not alive.')
        held = P(original_handle)
        case['creation_image_match'] = api.query(process, 44, C.byref(held), 8, None) & 0xffffffff
        require(case['creation_image_match'] == 0, 'The original is not the actual child creation image.')
        basic, returned = BasicInfo(), D()
        case['basic_query_status'] = api.query(process, 0, C.byref(basic), C.sizeof(basic), C.byref(returned)) & 0xffffffff
        require(case['basic_query_status'] == 0 and returned.value == C.sizeof(basic) and basic.pid == pid and basic.peb,
                'The child basic-information result is incomplete or inconsistent.')
        # Explicit Windows64 PEB layout assumption; validate the result against MEM_IMAGE and PE headers.
        base = struct.unpack('<Q', api.remote_bytes(process, basic.peb + 16, 8))[0]
        case['peb'], case['image_base'], case['peb_image_base_offset'] = basic.peb, base, 16
        case['memory_before'] = api.memory_info(process, base)
        require(case['memory_before']['allocation_base'] == base and case['memory_before']['type'] == 0x1000000,
                'The PEB address does not identify an image allocation base.')
        pe_offset = struct.unpack_from('<I', image, 60)[0]
        require(api.remote_bytes(process, base, 64) == image[:64] and
                api.remote_bytes(process, base + pe_offset, 264) == image[pe_offset:pe_offset + 264],
                'The primary image headers do not match the copied CLI bytes.')
        case['stage'] = 'prepare-control-state'
        checkpoint()
        if mode == 'primary_unmapped':
            case['stage'] = 'unmap-owned-child-primary-image'
            checkpoint()
            case['unmap_status'] = api.unmap(process, base) & 0xffffffff
            case['unmap_status_hex'] = f"0x{case['unmap_status']:08X}"
            checkpoint()
            case['memory_after_unmap'] = api.memory_info(process, base)
            case['process_alive_after_unmap'] = api.wait(process, 0) == 258
            require(case['process_alive_after_unmap'], 'The child exited during unmap.')
            if case['unmap_status'] == 0:
                # Allocation/protection/type fields are undefined for MEM_FREE.
                require(case['memory_after_unmap']['state'] == 0x10000,
                        'A successful unmap did not release the image view.')
            case['creation_image_match_after_unmap'] = api.query(process, 44, C.byref(held), 8, None) & 0xffffffff
        elif mode == 'terminated':
            api.check(api.terminate(process, 123))
            require(api.wait(process, 5000) == 0, 'The terminated control did not exit within five seconds.')
        case['process_alive_before_rename'] = api.wait(process, 0) == 258
        require(case['process_alive_before_rename'] == (mode != 'terminated'), 'The control process state is wrong.')
        case['stage'] = 'one-step-atomic-rename'
        name = original.name.encode('utf-16-le')
        buffer = C.create_string_buffer(RenameInfo.name.offset + len(name))
        rename = RenameInfo.from_buffer(buffer)
        rename.flags, rename.root, rename.length = 3, parent, len(name)
        C.memmove(C.byref(buffer, RenameInfo.name.offset), name, len(name))
        completion = IoStatus()
        completion.status = 0x103
        case['rename_contract'] = {'class': 65, 'flags': 3, 'root_identity': case['parent_identity'],
                                   'leaf': original.name, 'name_bytes': len(name), 'buffer_bytes': len(buffer)}
        checkpoint()
        case['rename_status'] = api.rename(candidate_handle, C.byref(completion), buffer, len(buffer), 65) & 0xffffffff
        case['rename_io_status'], case['rename_io_information'] = completion.status & 0xffffffff, completion.information
        case['rename_status_hex'] = f"0x{case['rename_status']:08X}"
        case['rename_io_status_hex'] = f"0x{case['rename_io_status']:08X}"
        checkpoint()
        success = case['rename_status'] == 0
        require(not success or case['rename_io_status'] == 0, 'The successful rename has a nonzero completion status.')
        case['original_after'] = api.snapshot(original)
        case['candidate_name_present'] = candidate.exists()
        case['held_original_after'], case['held_candidate_after'] = api.identity(original_handle), api.identity(candidate_handle)
        if success:
            require(same_file(case['original_after']['identity'], new['identity']) and not case['candidate_name_present'],
                    'Successful replacement did not install the candidate identity and remove its stage name.')
            require(case['original_after'] == new, 'The installed candidate bytes or security metadata changed.')
            case['observation'] = 'replacement-succeeded'
        else:
            case['candidate_after'] = api.snapshot(candidate)
            require(case['original_after'] == before and case['candidate_after'] == new,
                    'A failed replacement changed fixture identity, bytes, or security metadata.')
            case['observation'] = 'replacement-denied-files-preserved'
        require(same_file(case['held_original_after'], before['identity']) and
                same_file(case['held_candidate_after'], new['identity']) and
                same_file(api.identity(parent), case['parent_identity']), 'A held identity changed during replacement.')
        case['fixture'], case['stage'] = 'complete', 'complete'
    except Exception as error:
        case['error'] = {'type': type(error).__name__, 'message': str(error)[:2048]}
    finally:
        try:
            if process is not None:
                if api.wait(process, 0) != 0:
                    api.check(api.terminate(process, 124))
                require(api.wait(process, 5000) == 0, 'The owned child could not be reaped within five seconds.')
                code = D()
                api.check(api.exit_code(process, C.byref(code)))
                case['child_exit_code'] = code.value
                case['reaped'] = True
        except Exception as error:
            case['fixture'], case['cleanup_error'] = 'error', str(error)[:2048]
        for handle in [thread, process, *reversed(handles), job]:
            if handle is not None:
                if not api.close(handle):
                    case['fixture'], case['cleanup_error'] = 'error', f'CloseHandle failed: {C.get_last_error()}'
        checkpoint()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--asm', dest='binary', type=Path, required=True)
    parser.add_argument('--target', choices=['aarch64-windows', 'x86_64-windows'], required=True)
    parser.add_argument('--source-commit')
    parser.add_argument('--toolchain-bin', type=Path, default=Path('C:/Program Files/LLVM/bin'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args(argv)
    if os.name != 'nt':
        parser.error('This experiment requires native Windows; no child was created or unmapped.')
    progress = args.evidence.with_name(args.evidence.stem + '.progress.json')
    progress_temp = progress.with_suffix('.tmp')
    if any(path.exists() for path in [args.evidence, progress, progress_temp]):
        parser.error('The evidence and progress destinations must not already exist.')
    report = {'schema': 1, 'kind': 'owned-suspended-primary-image-unmap-probe', 'target': args.target,
              'native_cli_qualification': False, 'production_updater_changed': False,
              'scope': 'native section/file operations on never-resumed copies; no CLI command qualification',
              'started_utc': datetime.now(timezone.utc).isoformat(), 'fixture': 'error', 'cases': [],
              'progress_evidence': str(progress)}
    def checkpoint():
        report['checkpoint_utc'] = datetime.now(timezone.utc).isoformat()
        data = (json.dumps(report, indent=2) + '\n').encode('utf-8')
        require(len(data) <= 1048576, 'The bounded progress record exceeds one MiB.')
        progress.parent.mkdir(parents=True, exist_ok=True)
        with progress_temp.open('xb') as output:
            output.write(data)
            output.flush()
        os.replace(progress_temp, progress)
    try:
        report['layouts'] = layouts()
        driver = module_at('unmap_evidence_driver', ROOT / 'tools/windows_test.py')
        report.update(driver.source_identity(args.source_commit))
        report['probe_source_sha256'] = driver.digest(Path(__file__))
        report['fixture_security_source_sha256'] = driver.digest(ROOT / 'tests/windows/fixture_security.py')
        native = driver.native_machine()
        require(native == driver.MACHINES[args.target], 'The requested PE target does not match the native host ISA.')
        require(driver.pe_machine(args.binary) == native, 'The input PE has the wrong machine identifier.')
        require(64 <= args.binary.stat().st_size <= LIMIT, 'The input PE exceeds the bounded byte contract.')
        image = args.binary.read_bytes()
        report['artifact'] = {'path': str(args.binary.resolve()), 'bytes': len(image), 'sha256': hashlib.sha256(image).hexdigest()}
        report['host'] = {'os': platform.platform(), 'windows_version': list(sys.getwindowsversion()),
                          'platform_machine': platform.machine(), 'native_pe_machine': native, 'python': sys.version}
        report['tools'] = {}
        for tool in ['clang.exe', 'lld-link.exe']:
            flags = ['--no-default-config', '--version'] if tool == 'clang.exe' else ['--version']
            result = subprocess.run([str(args.toolchain_bin / tool), *flags], capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=10)
            require(result.returncode == 0, f'{tool} version collection failed.')
            report['tools'][tool] = {'stdout': result.stdout[:16384], 'stderr': result.stderr[:16384], 'exit_code': result.returncode}
        api = Windows()
        owner = module_at('unmap_fixture_security', ROOT / 'tests/windows/fixture_security.py')
        with tempfile.TemporaryDirectory(prefix='asm-owned-unmap-probe-') as temporary:
            work = Path(temporary).resolve()
            owner.own_directory(work, work)
            report['temporary_root'] = str(work)
            for mode in ['still_mapped', 'primary_unmapped', 'terminated']:
                experiment(api, work, image, args.target, mode, owner, report, checkpoint)
        require(all(c['fixture'] == 'complete' and c.get('reaped') for c in report['cases']), 'One or more fixture cases failed.')
        controls = {c['mode']: c for c in report['cases']}
        require(controls['terminated']['rename_status'] == 0, 'The terminated replacement control did not succeed.')
        report['fixture'] = 'complete'
        mapped, unmapped = controls['still_mapped'], controls['primary_unmapped']
        if unmapped['unmap_status'] != 0:
            report['conclusion'] = 'Unmap returned a measured denial or unsupported status; the unmapped condition was not established.'
        elif mapped['rename_status'] != 0 and unmapped['rename_status'] == 0:
            report['conclusion'] = 'Unmapping permits one-step replacement in this owned suspended-child fixture; no finalizer is qualified.'
        elif mapped['rename_status'] != 0 and unmapped['rename_status'] != 0:
            report['conclusion'] = 'Unmapping does not remove the measured replacement denial in this fixture.'
        else:
            report['conclusion'] = 'The mapped control differs from the failing updater; no production conclusion follows.'
    except Exception as error:
        report['fixture_error'] = {'type': type(error).__name__, 'message': str(error)[:2048]}
    report['finished_utc'] = datetime.now(timezone.utc).isoformat()
    checkpoint()
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    with args.evidence.open('x', encoding='utf-8') as output:
        json.dump(report, output, indent=2)
        output.write('\n')
    print(json.dumps({'fixture': report['fixture'], 'evidence': str(args.evidence), 'native_cli_qualification': False,
                      'conclusion': report.get('conclusion'), 'error': report.get('fixture_error')}, indent=2))
    return 0 if report['fixture'] == 'complete' else 1


if __name__ == '__main__':
    raise SystemExit(main())
