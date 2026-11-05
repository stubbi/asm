"""Run the generated Windows bootstrap and inspect managed test installations.

Only native tests use these helpers. They are not an installed CLI backend.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time
import struct
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools'
INSTALLER_FAILURES = ROOT / 'build/windows-evidence/installer-failures'
FAILURE_FILE_BYTES = 8 * 1024 * 1024
FAILURE_TOTAL_BYTES = 32 * 1024 * 1024
FAILURE_ENTRIES = 256
FAILURE_DEPTH = 12


def build_module(name):
    # The generators use the same direct-script imports as their public CLI.
    if str(TOOLS) not in sys.path:
        sys.path.insert(0, str(TOOLS))
    spec = importlib.util.spec_from_file_location(name, TOOLS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def with_minimum_launcher(data, target, version):
    """Change only a valid fixture's minimum launcher metadata, never execute it."""
    layout = build_module('windows_layout')
    layout.read_pe_metadata(data, target)
    changed = bytearray(data)
    pe = struct.unpack_from('<I', changed, 60)[0]
    count = struct.unpack_from('<H', changed, pe + 6)[0]
    optional = struct.unpack_from('<H', changed, pe + 20)[0]
    table = pe + 24 + optional
    section = next(table + index * 40 for index in range(count)
                   if changed[table + index * 40:table + index * 40 + 8] == b'.asmmeta')
    raw = struct.unpack_from('<I', changed, section + 20)[0]
    # The codec validates canonical version components before encoding them.
    changed[raw + 36:raw + 48] = layout.metadata_bytes('0.0.0', version)[36:48]
    layout.read_pe_metadata(bytes(changed), target)
    return bytes(changed)


def retain_installer_failure(work, command):
    """Copy bounded owned fixture evidence without following links.

    The snapshot retains errors and skipped entries. It does not claim general
    freedom from same-user path races. Each attempt uses a new directory.
    """
    work = Path(work).absolute()
    destination = Path(INSTALLER_FAILURES).absolute()
    if destination.is_relative_to(work):
        raise ValueError('Installer evidence must remain outside its owned source tree.')
    destination.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='installer-', dir=destination))
    files = output / 'files'
    files.mkdir()
    report = {'schema': 'asm-managed-installer-failure-v1', 'command': command.copy(),
              'source_root': str(work), 'complete': True, 'entries': [],
              'limits': {'file_bytes': FAILURE_FILE_BYTES, 'total_bytes': FAILURE_TOTAL_BYTES,
                         'entries': FAILURE_ENTRIES, 'depth': FAILURE_DEPTH},
              'scope': 'bounded test-fixture snapshot; no candidate execution or race-free claim'}
    for stream in ('stdout', 'stderr'):
        raw = bytes.fromhex(command.get(stream + '_hex', ''))
        (output / (stream + '.bin')).write_bytes(raw)
    total, visited = 0, set()
    def visit(path, relative, depth):
        nonlocal total
        if relative in visited:
            return
        if len(report['entries']) >= FAILURE_ENTRIES:
            report.update(complete=False, entry_limit_reached=True)
            return
        visited.add(relative)
        row = {'path': relative.as_posix()}
        report['entries'].append(row)
        try:
            info = path.lstat()
            row.update(bytes=info.st_size, device=info.st_dev, file_id=info.st_ino, mode=info.st_mode,
                       links=info.st_nlink, attributes=getattr(info, 'st_file_attributes', 0))
            if stat.S_ISLNK(info.st_mode) or row['attributes'] & 0x400:
                row['skipped'] = 'symlink or reparse point; not traversed'
            elif depth > FAILURE_DEPTH:
                row['skipped'] = 'depth bound'
            elif stat.S_ISDIR(info.st_mode):
                target = files / relative
                if relative != Path('.'):
                    target.mkdir()
                with os.scandir(path) as entries:
                    for entry in entries:
                        if len(report['entries']) >= FAILURE_ENTRIES:
                            report.update(complete=False, entry_limit_reached=True)
                            break
                        visit(Path(entry.path), relative / entry.name, depth + 1)
            elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                row['skipped'] = 'not a single-link regular file'
            elif info.st_size > FAILURE_FILE_BYTES or total + info.st_size > FAILURE_TOTAL_BYTES:
                row['skipped'] = 'file or total byte bound'
            else:
                flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
                descriptor = os.open(path, flags)
                with os.fdopen(descriptor, 'rb') as stream:
                    held = os.fstat(stream.fileno())
                    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_nlink)
                    if identity(held) != identity(info):
                        raise ValueError('The fixture identity changed before the bounded read.')
                    data = stream.read(FAILURE_FILE_BYTES + 1)
                    after = os.fstat(stream.fileno())
                if (len(data) != info.st_size or len(data) > FAILURE_FILE_BYTES
                        or identity(after) != identity(info) or identity(path.lstat()) != identity(info)):
                    raise ValueError('The fixture identity or bytes changed during the bounded read.')
                with (files / relative).open('xb') as saved:
                    saved.write(data)
                total += len(data)
                row.update(retained_bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            if 'skipped' in row:
                report['complete'] = False
        except (OSError, ValueError) as error:
            row['error'] = str(error)
            report['complete'] = False
    try:
        # Retain the exact source and script before a large partial installation
        # can consume the shared byte bound. Both are direct owned fixture files.
        for value in command.get('fixture_inputs', ()):
            path = Path(value).absolute()
            if path.parent != work:
                report.setdefault('input_errors', []).append('A priority input is not directly inside the owned root.')
                report['complete'] = False
                continue
            visit(path, path.relative_to(work), 1)
        visit(work, Path('.'), 0)
    finally:
        report['retained_bytes'] = total
        temporary = output / '.report.tmp'
        with temporary.open('x', encoding='utf-8') as stream:
            json.dump(report, stream, indent=2, ensure_ascii=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output / 'report.json')
    return output


def run_installer(case, argv, commands, *, code=0, timeout=90, inputs=()):
    """Record a bounded trusted-tool outcome and retain failures before raising."""
    if not 0 < timeout <= 90:
        raise ValueError('The installer deadline must be in (0, 90] seconds.')
    if len(inputs) > 2:
        raise ValueError('The installer has at most two priority fixture inputs.')
    started = time.monotonic()
    row = {'test': case.id(), 'argv': list(map(str, argv)), 'cwd': str(case.work),
           'exit_code': None, 'stdout': '', 'stderr': '', 'stdout_hex': '', 'stderr_hex': '',
           'fixture_inputs': list(map(str, inputs))}
    commands.append(row)
    try:
        capture = build_module('windows_bootstrap_smoke')
        observed = capture.capture(argv, cwd=case.work, env=case.environment, timeout=timeout)
        row.update(observed, exit_code=observed['returncode'])
        stdout, stderr = bytes.fromhex(row['stdout_hex']), bytes.fromhex(row['stderr_hex'])
        result = subprocess.CompletedProcess(argv, row['exit_code'], stdout, stderr)
        if row['timed_out']:
            raise subprocess.TimeoutExpired(argv, timeout, output=stdout, stderr=stderr)
        if (row['output_limit_exceeded'] or not row['capture_complete'] or row['capture_errors']):
            raise RuntimeError('The installer output exceeded a bound or could not be captured completely.')
        case.assertEqual(result.returncode, code, (stdout, stderr))
        case.assertFalse((case.work / 'PACKAGE_EXECUTED').exists(), 'The installer executed the candidate.')
        return result
    except Exception as error:
        row['exception'] = {'type': type(error).__name__, 'message': str(error),
                            'errno': getattr(error, 'errno', None), 'winerror': getattr(error, 'winerror', None)}
        raise
    finally:
        row['seconds'] = round(time.monotonic() - started, 6)
        if row['exit_code'] != 0 or 'exception' in row:
            try:
                row['failure_evidence'] = str(retain_installer_failure(case.work, row))
            except Exception as error:
                row['failure_evidence_error'] = {'type': type(error).__name__, 'message': str(error)}


def source_install(case, data, *, name='source', replace=False, repair=False, code=0):
    """Generate then run the exact source bootstrap without executing its PE.

    Record source/script digests and PowerShell output in the native receipt.
    The case owns the private work directory and its HOME environment.
    """
    import test_runtime as runtime
    artifact = case.work / (name + '.exe')
    artifact.write_bytes(data)
    installer = build_module('windows_bootstrap')
    script = installer.render_source_installer(artifact, runtime.TARGET)
    path = case.work / (name + '-install.ps1')
    path.write_bytes(script)
    runtime.TEST_ARTIFACTS.append({'role': 'managed-source-bootstrap-' + name,
                                   'target': runtime.TARGET, 'bytes': len(script),
                                   'sha256': hashlib.sha256(script).hexdigest(),
                                   'source_sha256': hashlib.sha256(data).hexdigest(),
                                   'source_bytes': len(data)})
    powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if not powershell.is_file():
        raise RuntimeError('The managed installation contract requires Windows PowerShell 5.1 or later.')
    argv = [str(powershell), '-NoLogo', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', str(path)]
    if replace:
        argv.append('-ReplaceExisting')
    if repair:
        argv.append('-RepairLauncher')
    return run_installer(case, argv, runtime.COMMANDS, code=code, timeout=90, inputs=(artifact, path))


def selection(case):
    """Check the active record against independently hashed installed bytes."""
    import test_runtime as runtime
    layout = build_module('windows_layout')
    store = case.home / '.local/bin/.asm-cli'
    case.assertEqual((store / 'layout').read_bytes(), b'# asm-cli-layout-v1\n')
    raw = (store / 'current.tsv').read_bytes()
    row = layout.decode_record(raw, runtime.TARGET)
    payload = store / 'versions' / row['sha256'] / 'asm.exe'
    data = payload.read_bytes()
    case.assertEqual(len(data), row['size'])
    case.assertEqual(hashlib.sha256(data).hexdigest(), row['sha256'])
    metadata = layout.read_pe_metadata(data, runtime.TARGET, expected_version=row['version'])
    case.assertEqual(metadata['minimum_launcher'], row['minimum_launcher'])
    return row, payload, raw


def assert_no_stage(case):
    store = case.home / '.local/bin/.asm-cli'
    case.assertEqual(sorted(p.name for p in store.iterdir()), ['current.tsv', 'layout', 'versions'])
    case.assertEqual(list((case.home / '.local/bin').glob('.asm-*')), [store])


@contextmanager
def hold_install_lock(case):
    """Hold the real kernel byte-range lock used by the native updater."""
    import ctypes
    from ctypes import wintypes
    from fixture_security import own_path
    if os.name != 'nt':
        raise RuntimeError('The installation lock fixture requires native Windows.')
    path = case.home / '.local/bin/.asm.lock'
    path.touch(exist_ok=True)
    own_path(path, case.work)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                   ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.LockFileEx.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD,
                                  wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    kernel.LockFileEx.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.CreateFileW(str(path), 0xc0000000, 7, None, 3, 0x200000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    class Overlapped(ctypes.Structure):
        _fields_ = [('internal', ctypes.c_size_t), ('internal_high', ctypes.c_size_t),
                    ('offset', wintypes.DWORD), ('offset_high', wintypes.DWORD),
                    ('event', wintypes.HANDLE)]
    overlap = Overlapped()
    try:
        if not kernel.LockFileEx(handle, 3, 0, 1, 0, ctypes.byref(overlap)):
            raise ctypes.WinError(ctypes.get_last_error())
        yield
    finally:
        if not kernel.CloseHandle(handle):
            raise ctypes.WinError(ctypes.get_last_error())


@contextmanager
def snapshot_events():
    """Own two uniquely named native events for one bounded snapshot test."""
    import ctypes
    from ctypes import wintypes
    import uuid
    if os.name != 'nt':
        raise RuntimeError('Snapshot synchronization requires native Windows.')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.CreateEventW.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.SetEvent.argtypes = [wintypes.HANDLE]
    kernel.SetEvent.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    names = ['Local\\AsmSnapshot-' + uuid.uuid4().hex for _ in range(2)]
    handles = []
    try:
        for name in names:
            handle = kernel.CreateEventW(None, True, False, name)
            if not handle:
                raise ctypes.WinError(ctypes.get_last_error())
            handles.append(handle)
            if ctypes.get_last_error() == 183:
                raise RuntimeError('The snapshot event already exists.')
        def ready():
            if kernel.WaitForSingleObject(handles[0], 10000) != 0:
                raise RuntimeError('The launcher did not hold its selection snapshot within ten seconds.')
        def release():
            if not kernel.SetEvent(handles[1]):
                raise ctypes.WinError(ctypes.get_last_error())
        yield {'environment': dict(zip(('ASM_TEST_SNAPSHOT_READY', 'ASM_TEST_SNAPSHOT_RELEASE'), names)),
               'ready': ready, 'release': release}
    finally:
        if len(handles) == 2:
            kernel.SetEvent(handles[1])
        for handle in handles:
            kernel.CloseHandle(handle)
