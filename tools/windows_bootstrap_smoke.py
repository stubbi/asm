#!/usr/bin/env python3
"""Probe the exact-source bootstrap with a never-executed assembly marker PE.

This build/test tool does not qualify CLI behavior or publisher authentication.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback

# bootstrap.py still uses an absolute registry import. Support both module and
# standalone invocation without changing that shared generator in this probe.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    if __package__:
        from . import windows_bootstrap, windows_layout, windows_fixture_security_probe
    else:
        import windows_bootstrap
        import windows_layout
        import windows_fixture_security_probe
finally:
    sys.path.pop(0)

ROOT = Path(__file__).resolve().parents[1]
MACHINES = {'x86_64-windows': 0x8664, 'aarch64-windows': 0xaa64}
MAX_FILE = 8 * 1024 * 1024
MAX_OUTPUT = 65536


def commit_id(text):
    if not re.fullmatch('[0-9a-f]{40}', text) or text == '0' * 40:
        raise ValueError('Require one full, nonzero lowercase source commit.')
    return text


def require_native(target):
    if os.name != 'nt':
        raise RuntimeError('Native Windows is required; no bootstrap was executed.')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.IsWow64Process2.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort),
                                      ctypes.POINTER(ctypes.c_ushort)]
    kernel.IsWow64Process2.restype = ctypes.c_int
    process, native = ctypes.c_ushort(), ctypes.c_ushort()
    if not kernel.IsWow64Process2(ctypes.c_void_p(-1), ctypes.byref(process), ctypes.byref(native)):
        raise ctypes.WinError(ctypes.get_last_error())
    if native.value not in MACHINES.values() or (target and native.value != MACHINES[target]):
        raise RuntimeError('The native Windows architecture does not match the probe target.')
    return native.value


def capture(argv, *, cwd=None, env=None, timeout=90):
    """Drain two bounded pipes; kill the tool on overflow or its deadline.

    Readers retain at most 64 KiB per stream. A descendant holding a pipe cannot
    extend the deadline: an incomplete drain fails and daemon readers retain no
    further bytes. This is a trusted fixed-tool test boundary, not containment
    of arbitrary code. The candidate never appears in an executable argument.
    """
    if not 0 < timeout <= 90:
        raise ValueError('Tool deadlines must be in (0, 90] seconds.')
    started = time.monotonic()
    process = subprocess.Popen(list(map(str, argv)), cwd=cwd, env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    buffers = [bytearray(), bytearray()]
    overflow, lock = threading.Event(), threading.Lock()
    errors = []
    def drain(stream, index):
        try:
            while True:
                chunk = os.read(stream.fileno(), 8192)
                if not chunk:
                    break
                with lock:
                    remaining = MAX_OUTPUT - len(buffers[index])
                    buffers[index].extend(chunk[:remaining])
                if len(chunk) > remaining:
                    overflow.set()
                    break
        except OSError as error:
            with lock:
                errors.append(str(error))
        finally:
            stream.close()
    readers = [threading.Thread(target=drain, args=(stream, index), daemon=True)
               for index, stream in enumerate((process.stdout, process.stderr))]
    for reader in readers:
        reader.start()
    deadline = started + timeout
    timed_out = False
    while process.poll() is None or any(reader.is_alive() for reader in readers):
        if overflow.is_set() or time.monotonic() >= deadline:
            timed_out = not overflow.is_set()
            if process.poll() is None:
                process.kill()
            break
        time.sleep(.01)
    try:
        process.wait(timeout=min(2, timeout))
    except subprocess.TimeoutExpired:
        errors.append('The killed tool did not exit within the reap bound.')
    # Join against one shared grace deadline, not one deadline per pipe.
    grace = time.monotonic() + min(1, timeout)
    for reader in readers:
        reader.join(max(0, grace - time.monotonic()))
    with lock:
        return {'argv': list(map(str, argv)), 'returncode': process.returncode,
                'stdout': bytes(buffers[0]).decode('utf-8', errors='replace'),
                'stderr': bytes(buffers[1]).decode('utf-8', errors='replace'),
                'stdout_bytes': len(buffers[0]), 'stderr_bytes': len(buffers[1]),
                'stdout_hex': bytes(buffers[0]).hex(), 'stderr_hex': bytes(buffers[1]).hex(),
                'output_limit_exceeded': overflow.is_set(), 'timed_out': timed_out,
                'capture_complete': not any(reader.is_alive() for reader in readers),
                'capture_errors': list(errors), 'seconds': round(time.monotonic() - started, 6)}


def command_succeeded(result):
    return (result['returncode'] == 0 and not result['timed_out']
            and not result['output_limit_exceeded'] and result['capture_complete']
            and not result['capture_errors'])


def checked(argv, commands, **kwargs):
    result = capture(argv, **kwargs)
    commands.append(result)
    if not command_succeeded(result):
        raise RuntimeError(f'The fixed tool failed: {argv[0]}; inspect recorded output.')
    return result['stdout'].strip()


def source_identity(root, expected, git='git', commands=None):
    commit_id(expected)
    commands = commands if commands is not None else []
    commit = checked([git, '-C', root, 'rev-parse', 'HEAD'], commands, timeout=15)
    if commit != expected:
        raise RuntimeError('The checkout commit differs from --source-commit.')
    dirty = checked([git, '-C', root, 'status', '--porcelain', '--untracked-files=normal'], commands, timeout=15)
    if dirty:
        raise RuntimeError('The bootstrap probe requires a clean exact-source checkout.')
    return {'source_commit': commit, 'source_dirty': False}


def source_version(root):
    text = (root / 'cli/asm.s').read_text(encoding='utf-8')
    versions = re.findall(r'^version_text: \.asciz "asm ([^ ]+) ', text, re.MULTILINE)
    if len(versions) != 1:
        raise ValueError('Require exactly one source command version.')
    windows_layout.metadata_bytes(versions[0])
    return versions[0]


def powershell_observation(output):
    """Read static version and process environment data, not effective policy."""
    lines = output.splitlines()
    if not 1 <= len(lines) <= 2 or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', lines[0]):
        raise ValueError('The PowerShell version observation is malformed.')
    if tuple(map(int, lines[0].split('.'))) < (5, 1):
        raise ValueError('The bootstrap requires Windows PowerShell 5.1 or later.')
    return {'version': lines[0], 'process_environment_preference': lines[1] if len(lines) == 2 else None}


def fixed_tools(target, *, llvm=Path('C:/Program Files/LLVM/bin'),
                sdk=Path('C:/Program Files (x86)/Windows Kits/10/Lib'), windows=None):
    if windows is None:
        buffer = ctypes.create_unicode_buffer(32768)
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        if not 0 < kernel.GetWindowsDirectoryW(buffer, len(buffer)) < len(buffer):
            raise ctypes.WinError(ctypes.get_last_error())
        windows = Path(buffer.value)
    tools = {'clang': llvm / 'clang.exe', 'link': llvm / 'lld-link.exe',
             'powershell': windows / 'System32/WindowsPowerShell/v1.0/powershell.exe',
             'git': Path('C:/Program Files/Git/cmd/git.exe')}
    for path in tools.values():
        if not path.is_file():
            raise RuntimeError(f'Required fixed tool is absent: {path}')
    arch = 'x64' if target == 'x86_64-windows' else 'arm64'
    versions = sorted((p for p in sdk.iterdir() if p.is_dir()
                       and re.fullmatch(r'[0-9]+(?:\.[0-9]+){3}', p.name)
                       and (p / 'um' / arch / 'kernel32.lib').is_file()),
                      key=lambda p: tuple(map(int, p.name.split('.'))), reverse=True)
    if not versions:
        raise RuntimeError(f'The fixed Windows SDK kernel32.lib is absent for {arch}.')
    tools['kernel32'] = versions[0] / 'um' / arch / 'kernel32.lib'
    return tools


def bounded_bytes(path):
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or getattr(before, 'st_file_attributes', 0) & 0x400 or before.st_size > MAX_FILE):
        raise ValueError('The fixture is not a bounded single-link regular file.')
    with path.open('rb') as stream:
        held = os.fstat(stream.fileno())
        data = stream.read(MAX_FILE + 1)
        after = os.fstat(stream.fileno())
    current = path.lstat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_nlink)
    if len(data) > MAX_FILE or len(data) != before.st_size or not all(
            identity(s) == identity(before) for s in (held, after, current)):
        raise ValueError('The fixture identity or bytes changed during inspection.')
    return data


def inventory(root):
    """Inspect only the owned tree. Never descend through a reparse point.

    Raw files stay below output; no failure cleanup discards their bytes.
    File identity checks do not establish general same-user race freedom.
    """
    rows, total = [], 0
    def visit(path, depth):
        nonlocal total
        if len(rows) >= 512 or depth > 12:
            raise ValueError('The owned fixture inventory exceeded its entry/depth bound.')
        row = {'path': path.relative_to(root).as_posix() or '.'}
        rows.append(row)
        try:
            info = path.lstat()
            row.update(bytes=info.st_size, device=info.st_dev, file_id=info.st_ino,
                       links=info.st_nlink, mode=info.st_mode,
                       attributes=getattr(info, 'st_file_attributes', None))
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise ValueError('Reparse point or symlink retained without traversal.')
            if stat.S_ISDIR(info.st_mode):
                with os.scandir(path) as entries:
                    for entry in entries:
                        visit(Path(entry.path), depth + 1)
            else:
                if total + info.st_size > 64 * 1024 * 1024:
                    raise ValueError('The fixture inventory exceeded its total byte bound.')
                data = bounded_bytes(path)
                total += len(data)
                row['sha256'] = hashlib.sha256(data).hexdigest()
        except (OSError, ValueError) as error:
            row['error'] = str(error)
    if root.exists():
        visit(root, 0)
    return rows


def retain_fixture(root, output):
    """Retain bounded raw bytes from a private TEMP fixture for artifact upload."""
    rows = inventory(root)
    destination = output / 'retained-fixture'
    destination.mkdir()
    for row in rows:
        if 'error' in row:
            continue
        relative = Path(row['path'])
        source, target = root / relative, destination / relative
        if stat.S_ISDIR(row['mode']):
            target.mkdir(exist_ok=True)
        else:
            data = bounded_bytes(source)
            if hashlib.sha256(data).hexdigest() != row['sha256']:
                raise ValueError('Fixture bytes changed before evidence retention.')
            with target.open('xb') as stream:
                stream.write(data)
            row['retained_path'] = target.relative_to(output).as_posix()
    return rows


def marker_assembly(target, version, marker):
    # Input: no arguments. Output: marker creation and ExitProcess(73).
    # x64 reserves 32-byte shadow space and aligned 64-byte argument storage.
    # ARM64 reserves an aligned frame. Neither path returns to the loader.
    path = marker.as_posix().encode('utf-16le') + b'\0\0'
    data = '.section .rdata,"dr"\nmarker_path:\n.byte ' + ','.join(map(str, path)) + '\n'
    if target == 'x86_64-windows':
        code = '''.intel_syntax noprefix
.text
.globl _start
_start:
    sub rsp, 72
    lea rcx, [rip + marker_path]
    mov edx, 0x40000000
    mov r8d, 7
    xor r9d, r9d
    mov qword ptr [rsp + 32], 2
    mov qword ptr [rsp + 40], 0x80
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    mov ecx, 73
    call ExitProcess
    int3
'''
    else:
        code = '''.text
.globl _start
_start:
    sub sp, sp, #16
    adrp x0, marker_path
    add x0, x0, :lo12:marker_path
    mov w1, #0x40000000
    mov w2, #7
    mov x3, #0
    mov w4, #2
    mov w5, #0x80
    mov x6, #0
    bl CreateFileW
    mov w0, #73
    bl ExitProcess
    brk #0
'''
    return code + data + windows_layout.metadata_assembly(version, target.removesuffix('-windows'))


def validate_install(home, artifact, target, version, marker):
    if marker.exists():
        raise RuntimeError('The PACKAGE_EXECUTED marker exists; candidate execution occurred.')
    source = bounded_bytes(artifact)
    digest = hashlib.sha256(source).hexdigest()
    bin_path = home / '.local/bin'
    store = bin_path / '.asm-cli'
    payload = store / 'versions' / digest / 'asm.exe'
    root = bin_path / 'asm.exe'
    # Check every owned ancestor before opening bytes. This is an independent
    # fixture observation, not a claim of descriptor-based race freedom.
    for item in (home, home / '.local', bin_path, store, store / 'versions', payload.parent):
        info = item.lstat()
        if not stat.S_ISDIR(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise ValueError('A published fixture directory is a reparse point or invalid.')
    if bounded_bytes(store / 'layout') != b'# asm-cli-layout-v1\n':
        raise ValueError('The layout marker differs from its canonical bytes.')
    record = bounded_bytes(store / 'current.tsv')
    selection = windows_layout.decode_record(record, target)
    metadata = windows_layout.read_pe_metadata(source, target, expected_version=version)
    expected = (f'# asm-cli-current-v1\n{version}\t{target}\t{len(source)}\t{digest}'
                f'\t1\t{metadata["minimum_launcher"]}\n').encode('ascii')
    if record != expected:
        raise ValueError('The published selection differs from the exact candidate.')
    for path in (root, payload):
        data = bounded_bytes(path)
        if data != source:
            raise ValueError('A published executable differs from the exact candidate bytes.')
        windows_layout.read_pe_metadata(data, target, expected_version=version)
    if (root.stat().st_dev, root.stat().st_ino) == (payload.stat().st_dev, payload.stat().st_ino):
        raise ValueError('Launcher and payload must be separate single-link copies.')
    return {'selection': selection, 'metadata': metadata, 'sha256': digest, 'bytes': len(source),
            'package_executed_marker_absent': True, 'candidate_executed_by_driver': False}


def atomic_report(output, report):
    descriptor, name = tempfile.mkstemp(prefix='.report-', suffix='.tmp', dir=output)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(report, stream, indent=2, ensure_ascii=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, output / 'report.json')
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=tuple(MACHINES), required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    output = args.output.absolute()
    report = {'schema': 'asm-windows-bootstrap-smoke-v1', 'target': args.target,
              'requested_source_commit': args.source_commit, 'outcome': 'fail',
              'qualifies_cli_runtime': False, 'qualifies_published_installer': False,
              'scope': 'exact-source bootstrap publication using an unexecuted assembly marker PE',
              'started_utc': datetime.now(timezone.utc).isoformat(), 'commands': [],
              'host': {'platform': platform.platform(), 'python': sys.version,
                       'machine': platform.machine(), 'image_os': os.environ.get('ImageOS'),
                       'image_version': os.environ.get('ImageVersion')},
              'powershell_policy': {'scope': 'Process', 'requested': 'Bypass',
                                    'persistent_policy_changed': False,
                                    'effective_policy': None, 'persistent_scopes': None,
                                    'group_policy_scopes': None, 'full_policy_query_measured': False},
              'limits': {'child_seconds': 90, 'stream_bytes': MAX_OUTPUT,
                         'fixture_file_bytes': MAX_FILE}, 'inputs': {}}
    owned = None
    checkpoint_written = False
    try:
        commit_id(args.source_commit)
        report['host']['native_machine'] = require_native(args.target)
        report['host']['windows_version'] = list(sys.getwindowsversion())
        tools = fixed_tools(args.target)
        report.update(source_identity(ROOT, args.source_commit, tools['git'], report['commands']))
        if output.exists():
            raise ValueError('Use a new output directory; existing evidence must be preserved.')
        output.mkdir(parents=True)
        # Native fourth-run descriptors show the workspace drive/ancestors
        # violate the unchanged guard policy. Ordinary runtime fixtures use
        # the current user's TEMP chain, whose descriptors were also retained.
        owned = Path(tempfile.mkdtemp(prefix='owned bootstrap '))
        home = owned / 'HOME with spaces'
        home.mkdir()
        fixture_spec = importlib.util.spec_from_file_location('asm_smoke_fixture_security', ROOT / 'tests/windows/fixture_security.py')
        fixture = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture)
        fixture.own_directory(owned, owned.parent)
        fixture.own_directory(home, owned)
        environment = {key: os.environ[key] for key in ('SystemRoot', 'WINDIR', 'ComSpec') if key in os.environ}
        environment.update(HOME=str(home), USERPROFILE=str(home), TEMP=str(home), TMP=str(home),
                           PATH=str(tools['powershell'].parents[1]),
                           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='NUL', GIT_CONFIG_SYSTEM='NUL')
        report['tools'] = {}
        for name, path in tools.items():
            # LLVM and SDK libraries may exceed the fixture bound; hash in chunks.
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            report['tools'][name] = {'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest}
            if name in ('clang', 'link'):
                report['tools'][name]['version'] = checked([path, '--version'], report['commands'], env=environment, timeout=15)
        ps = [tools['powershell'], '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass']
        report['powershell_policy']['observed'] = powershell_observation(checked(ps + ['-Command',
            '$PSVersionTable.PSVersion.ToString(); [Environment]::GetEnvironmentVariable("PSExecutionPolicyPreference")'],
            report['commands'], env=environment, cwd=owned, timeout=15))
        version = source_version(ROOT)
        report['source_version'] = version
        marker = owned / 'PACKAGE_EXECUTED'
        source, obj, artifact = (owned / name for name in ('marker.s', 'marker.obj', 'marker.exe'))
        source.write_text(marker_assembly(args.target, version, marker), encoding='ascii')
        arch = args.target.removesuffix('-windows')
        checked([tools['clang'], '--no-default-config', f'--target={arch}-pc-windows-msvc',
                 '-c', source, '-o', obj], report['commands'], cwd=owned, env=environment)
        checked([tools['link'], '/machine:' + ('x64' if arch == 'x86_64' else 'arm64'),
                 '/entry:_start', '/subsystem:console', '/nodefaultlib', '/nxcompat', '/dynamicbase',
                 '/Brepro', '/out:' + str(artifact), obj, tools['kernel32']],
                report['commands'], cwd=owned, env=environment)
        windows_layout.read_pe_metadata(bounded_bytes(artifact), args.target, expected_version=version)
        script = owned / 'bootstrap.ps1'
        script.write_bytes(windows_bootstrap.render_source_installer(artifact, args.target))
        report['fixture_security'] = windows_fixture_security_probe.snapshot(
            home, artifact, extra_paths=(owned, source, obj, script,
                                        Path(tempfile.gettempdir()), Path(os.environ['USERPROFILE'])))
        # Preserve the exact guard inputs even if the installer child fails.
        atomic_report(output, report)
        checkpoint_written = True
        checked(ps + ['-File', script], report['commands'], cwd=owned, env=environment)
        report['verification'] = validate_install(home, artifact, args.target, version, marker)
        # A source change during the probe invalidates its exact-source claim.
        source_identity(ROOT, args.source_commit, tools['git'], report['commands'])
        report['outcome'] = 'pass'
    except Exception as error:
        report['exception'] = {'type': type(error).__name__, 'message': str(error),
                               'traceback': traceback.format_exc()}
        print(f'Windows bootstrap probe failed: {error}', file=sys.stderr)
    finally:
        for relative in ('tools/windows_bootstrap_smoke.py', 'tools/windows_bootstrap.py',
                         'tools/windows-install.ps1.in', 'tools/windows_layout.py', 'tools/bootstrap.py',
                         'tools/registry.py', 'cli/asm.s', 'tests/windows/fixture_security.py',
                         'tools/windows_fixture_security_probe.py'):
            try:
                data = bounded_bytes(ROOT / relative)
                report['inputs'][relative] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            except (OSError, ValueError) as error:
                report['inputs'][relative] = {'error': str(error)}
        if owned:
            report['original_owned_root'] = str(owned)
            report['owned_root'] = 'retained-fixture'
            report['files'] = inventory(owned)
            try:
                report['files'] = retain_fixture(owned, output)
            except (OSError, ValueError) as error:
                report['retention_error'] = str(error)
                report['outcome'] = 'fail'
            report['package_executed_marker_present'] = (owned / 'PACKAGE_EXECUTED').exists()
            if report['package_executed_marker_present'] or any('error' in row for row in report['files']):
                report['outcome'] = 'fail'
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        # Never overwrite a report from a previous attempt, even on refusal.
        output.mkdir(parents=True, exist_ok=True)
        if (output / 'report.json').exists() and not checkpoint_written:
            print('Existing report preserved; choose a new output directory.', file=sys.stderr)
            report['outcome'] = 'fail'
        else:
            atomic_report(output, report)
    return 0 if report['outcome'] == 'pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
