#!/usr/bin/env python3
"""Execute selected Windows ARM64 boundaries against hostile local API shims.

The native assembly routine bodies are taken directly from the port sources.
Only object-format spelling changes for the Apple Silicon host. This checks
argument placement and preservation, not Windows API or filesystem semantics.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def region(path, start, end):
    source = path.read_text()
    return source[source.index(start):source.index(end, source.index(start))]


def source_text():
    spec = importlib.util.spec_from_file_location('windows_arm64', ROOT / 'tools/windows_arm64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    parts = [module.prepare(ROOT / 'cli/aarch64/platform.inc'),
             region(HERE / 'platform.s', '.equ WIN_OPEN_DELETE', '/* x0=Win32 error'),
             region(HERE / 'platform.s', 'win_handle:', 'arm_close:'),
             region(HERE / 'platform.s', 'win_nt_component:', '\narm_open:'),
             region(HERE / 'platform.s', 'arm_unlink:', '/* Rename uses source HANDLE'),
             region(HERE / 'files.s', 'win_getdents:', '\n/* x0=HANDLE, x1=flock'),
             region(HERE / 'files.s', 'win_directory_lock:', '\n/* x0=closing directory'),
             region(HERE / 'files.s', 'win_component_name:', '\n/* Extra Windows archive'),
             region(HERE / 'process.s', '.macro WIN_QUOTE', '/* Populate argc'),
             region(HERE / 'process.s', 'win_spawn_core:', '\n/* x0=explicit UTF8'),
             region(HERE / 'pipe.s', 'win_pump_capture:', '\n.section .rdata'),
             (HERE / 'abi_shim.s').read_text()]
    text = '\n.text\n'.join(parts)
    text = text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    text = text.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    return re.sub(r'^\.arch.*$', '', text, flags=re.M)


def run_case(directory, label, source):
    assembly = directory / (label + '.s')
    executable = directory / label
    assembly.write_text(source)
    build = subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-Wl,-no_uuid',
                            str(assembly), '-o', str(executable)],
                           capture_output=True, text=True, timeout=30)
    result = {'source_sha256': hashlib.sha256(assembly.read_bytes()).hexdigest(),
              'build_exit_code': build.returncode, 'build_stderr': build.stderr}
    if build.returncode == 0:
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
        result.update(exit_code=run.returncode, stdout=run.stdout, stderr=run.stderr,
                      executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        parser.error('This ABI shim requires an Apple Silicon macOS host.')
    source = source_text()
    # Reintroduce each reviewed defect separately in temporary test input.
    # Every mutation must remain buildable and fail during actual execution.
    def mutate(label, end, old, new):
        begin = source.index(label)
        finish = source.index(end, begin)
        body = source[begin:finish]
        if body.count(old) != 1:
            raise ValueError(f'ABI regression anchor changed: {label!r}')
        return source[:begin] + body.replace(old, new) + source[finish:]

    cases = {'current': source}
    for routine, end in [('arm_read:', 'arm_write:'), ('arm_write:', 'win_nt_component:')]:
        cases['regression_' + routine[:-1]] = mutate(routine, end, '    ldp x1, x2, [x29, #24]\n', '')
    for routine, end, allocation, api in [
        ('win_nt_component:', 'arm_unlink:', '    sub sp, sp, #32\n', 'NtCreateFile'),
        ('win_getdents:', 'win_directory_lock:', '    sub sp, sp, #32             /* outgoing args9..11, not the saved frame */\n', 'NtQueryDirectoryFile'),
        ('win_directory_lock:', 'win_component_name:', '    sub sp, sp, #32             /* outgoing args9..11, not the saved frame */\n', 'NtCreateFile'),
        ('win_spawn_core:', 'win_inherit_duplicate:', '    sub sp, sp, #16             /* outgoing args9..10, not the saved frame */\n', 'CreateProcessW')]:
        mutated = mutate(routine, end, allocation, '')
        amount = '16' if api == 'CreateProcessW' else '32'
        old = f'    bl {api}\n    add sp, sp, #{amount}'
        begin = mutated.index(routine)
        finish = mutated.index(end, begin)
        body = mutated[begin:finish]
        if body.count(old) != 1:
            raise ValueError(f'ABI regression return anchor changed: {routine!r}')
        cases['regression_' + routine[:-1]] = mutated[:begin] + body.replace(old, f'    bl {api}', 1) + mutated[finish:]
    deadline = '    /* A continuously readable producer must not bypass the deadline. */\n    bl GetTickCount64\n    sub x0, x0, x20\n    ARM_IMM x10, 120000\n    cmp x0, x10\n    b.hs .Lwpc_bad\n'
    cases['regression_capture_deadline'] = mutate('win_pump_capture:', 'GetStdHandle:', deadline, '')
    cases['regression_capture_exit_drain'] = mutate(
        'win_pump_capture:', 'GetStdHandle:',
        '.Lwpc_exited:\n    mov x10, #1\n    str x10, [sp, #72]\n    b .Lwpc_loop',
        '.Lwpc_exited:\n    b .Lwpc_good')
    with tempfile.TemporaryDirectory(prefix='asm-arm64-abi-') as temporary:
        directory = Path(temporary)
        results = {name: run_case(directory, name, code) for name, code in cases.items()}
    passed = (results['current'].get('exit_code') == 0 and
              all(result.get('build_exit_code') == 0 and result.get('exit_code', 0) != 0
                  for name, result in results.items() if name != 'current'))
    toolchain = subprocess.run(['/usr/bin/clang', '--version'], capture_output=True, text=True, timeout=10)
    evidence = {'observed_at': datetime.now(timezone.utc).isoformat(),
                'toolchain': toolchain.stdout.splitlines()[0],
                'scope': 'host-executed ARM64 call-boundary shims; not Windows runtime qualification',
                'host': {'os': platform.platform(), 'machine': platform.machine()},
                'result': 'pass' if passed else 'fail', 'cases': results}
    data = json.dumps(evidence, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(data)
    print(data, end='')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
