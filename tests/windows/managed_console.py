"""Build and observe the real Windows owned-console fixture.

The C binary is test infrastructure, never an installed CLI backend.
Cross-build and parser results do not qualify native Windows behavior.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


_TARGETS = {'x86_64-windows': ('x86_64', 'x64'),
            'aarch64-windows': ('aarch64', 'arm64')}


def build_fixture(root, directory, target, version, toolchain_bin, record_command):
    """Return a PE with valid version metadata; callback executes each build argv.

    record_command(argv) must record the command and raise on an unsuccessful
    build. Use the native runtime driver's existing build_command callback.
    """
    root, directory, toolchain_bin = map(Path, (root, directory, toolchain_bin))
    arch, machine = _TARGETS[target]
    directory.mkdir(parents=True, exist_ok=True)
    suffix = '.exe' if os.name == 'nt' else ''
    clang = toolchain_bin / ('clang' + suffix)
    linker = toolchain_bin / ('lld-link' + suffix)
    for tool in (clang, linker):
        if not tool.is_file():
            raise RuntimeError('The console fixture requires fixed clang and lld-link executables: ' + str(tool))
    if str(root / 'tools') not in sys.path:
        sys.path.insert(0, str(root / 'tools'))
    spec = importlib.util.spec_from_file_location('managed_console_layout', root / 'tools/windows_layout.py')
    layout = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(layout)
    source = root / 'tests/windows/managed_console.c'
    obj = directory / 'managed-console.obj'
    metadata = directory / 'managed-console-meta.s'
    meta_obj = metadata.with_suffix('.obj')
    binary = directory / 'managed-console.exe'
    metadata.write_text(layout.metadata_assembly(version, arch), encoding='ascii')
    triple = '--target=' + arch + '-pc-windows-msvc'
    commands = [
        [clang, '--no-default-config', triple, '-Oz', '-Wall', '-Wextra', '-Werror',
         '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-c', source, '-o', obj],
        [clang, '--no-default-config', triple, '-c', metadata, '-o', meta_obj],
        [linker, '/machine:' + machine, '/entry:fixture_entry', '/subsystem:console',
         '/nodefaultlib', '/nxcompat', '/dynamicbase', '/Brepro', '/out:' + str(binary),
         obj, meta_obj, 'kernel32.lib', 'shell32.lib'],
    ]
    for command in commands:
        record_command(list(map(str, command)))
    layout.read_pe_metadata(binary.read_bytes(), target, expected_version=version)
    return binary


def parse_receipt(stdout):
    """Validate the bounded controller receipt without converting its DWORD."""
    if len(stdout) > 4096:
        raise ValueError('The console controller receipt exceeds 4096 bytes.')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('The console controller receipt has a duplicate field.')
            result[key] = value
        return result
    row = json.loads(stdout.decode('ascii'), object_pairs_hook=unique)
    expected = {'status', 'event', 'requested_exit_code', 'exit_code', 'payload_exit_code', 'ready', 'event_sent',
                'launcher_reaped', 'payload_reaped', 'error', 'elapsed_ms'}
    if not isinstance(row, dict) or set(row) != expected:
        raise ValueError('The console controller receipt has an unexpected schema.')
    statuses = {'invalid-arguments', 'handler-failed', 'command-too-long', 'create-failed',
                'readiness-timeout', 'launcher-exited-before-ready', 'signal-failed',
                'launcher-timeout', 'exit-query-failed', 'payload-timeout', 'payload-exit-query-failed',
                'job-failed', 'job-assignment-failed', 'resume-failed', 'complete'}
    if type(row['status']) is not str or row['status'] not in statuses:
        raise ValueError('The console controller receipt has an unknown status.')
    for key in ('event', 'requested_exit_code', 'error', 'elapsed_ms'):
        if type(row[key]) is not int or not 0 <= row[key] <= 0xffffffff:
            raise ValueError('The console controller receipt has an invalid integer: ' + key)
    if row['event'] not in (0, 1) or row['elapsed_ms'] > 20000:
        raise ValueError('The console controller exceeded its event or time bounds.')
    for key in ('exit_code', 'payload_exit_code'):
        if row[key] is not None and (type(row[key]) is not int or not 0 <= row[key] <= 0xffffffff):
            raise ValueError('The console controller receipt has an invalid DWORD exit code: ' + key)
    for key in ('ready', 'event_sent', 'launcher_reaped', 'payload_reaped'):
        if type(row[key]) is not bool:
            raise ValueError('The console controller receipt has an invalid flag: ' + key)
    if row['status'] == 'complete' and (
            not all(row[key] for key in ('ready', 'event_sent', 'launcher_reaped', 'payload_reaped')) or
            row['exit_code'] is None or row['payload_exit_code'] is None):
        raise ValueError('The completed console receipt lacks completion evidence.')
    return row


def observe_console(binary, launcher, cwd, environment, ready_path, event, exit_code):
    """Run only on native Windows; return all output, failures, and parsed data.

    The controller owns its new console. The wrapper never signals its console.
    Native callers must assert controller.status, reaped flags, and exact DWORD.
    """
    if os.name != 'nt':
        raise RuntimeError('Owned-console observations require native Windows execution.')
    if type(event) is not int or event not in (0, 1):
        raise ValueError('The control event must be 0 (Ctrl+C) or 1 (Ctrl+Break).')
    if type(exit_code) is not int or not 0 <= exit_code <= 0xffffffff:
        raise ValueError('The requested exit code must be a DWORD.')
    ready_path = Path(ready_path)
    if ready_path.exists():
        raise FileExistsError('The private readiness path must not exist: ' + str(ready_path))
    argv = [str(binary), '--controller', str(launcher), str(ready_path), str(event), str(exit_code)]
    started = time.monotonic()
    row = {'argv': argv, 'cwd': str(cwd), 'exit_code': None, 'timed_out': False,
           'stdout': '', 'stderr': '', 'controller': None, 'parse_error': None}
    try:
        completed = subprocess.run(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                   capture_output=True, timeout=30,
                                   creationflags=subprocess.CREATE_NEW_CONSOLE)
        stdout, stderr = completed.stdout, completed.stderr
        row['exit_code'] = completed.returncode
    except subprocess.TimeoutExpired as failure:
        stdout, stderr = failure.stdout or b'', failure.stderr or b''
        row['timed_out'] = True
    except OSError as failure:
        stdout, stderr = b'', b''
        row['parse_error'] = 'Cannot start console controller: ' + str(failure)
    row['seconds'] = round(time.monotonic() - started, 6)
    row['stdout'] = stdout.decode('utf-8', errors='replace')[:65536]
    row['stderr'] = stderr.decode('utf-8', errors='replace')[:65536]
    if row['parse_error'] is None:
        try:
            row['controller'] = parse_receipt(stdout)
        except (ValueError, UnicodeError) as failure:
            row['parse_error'] = str(failure)
    return row
