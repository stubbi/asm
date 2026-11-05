#!/usr/bin/env python3
"""Execute the generated offline walk and actual Windows drive-path parser.

The Apple Silicon host supplies controlled filesystem calls. These checks do
not qualify Windows NTFS, directory permissions, or native package resolution.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import tempfile

import abi_test

HERE = Path(__file__).resolve().parent
ROOT = abi_test.ROOT
DIGEST = 'a' * 64


def module():
    spec = importlib.util.spec_from_file_location('resolver_windows_arm64', ROOT / 'tools/windows_arm64.py')
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def region(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def literal(label, value):
    data = value.encode('utf-8') + b'\0'
    return label + ': .byte ' + ','.join(map(str, data)) + '\n'


def fixture(path, prefixes, expected=None, *, error=0, bad_mode=0, stat_error=0):
    generator = module()
    prepared = generator.prepare(ROOT / 'cli/aarch64/resolver.s')
    canonical = (ROOT / 'cli/aarch64/asm.s').read_text()
    windows = (HERE / 'platform.s').read_text()
    files = (HERE / 'files.s').read_text()
    source = generator.prepare(ROOT / 'cli/aarch64/platform.inc')
    source += '\n.text\n' + region(prepared, 'res_offline_path:', '/* Compare every reused identity')
    source += region(canonical, 'streq:', '/* Input: x0=file descriptor;')
    source += region(windows, 'win_open:', '/* Private component open:')
    source += region(files, 'win_drive_view:', '/* x0=owned UTF8 buffer')
    source += region(files, 'win_is_absolute:', '/* Normalize separators')
    source += region(files, 'win_slashes:', '/* x0=bounded UTF16')
    source += f'''
.text
.global _main
_main:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x21, x22, [sp, #16]
    /* The real platform parser must keep rejecting direct drive-relative input. */
    mov x0, #-100
    ARM_ADDR x1, bare_drive
    mov x2, #0
    mov x6, #0
    ARM_CALL win_open
    cmn x9, #22
    b.ne failed
    mov x0, #-100
    ARM_ADDR x1, drive_relative
    mov x2, #0
    mov x6, #0
    ARM_CALL win_open
    cmn x9, #22
    b.ne failed
    mov x21, #0x2121
    mov x22, #0x2222
    ARM_CALL res_offline_path
    mov x10, #0x2121
    cmp x21, x10
    b.ne failed
    mov x10, #0x2222
    cmp x22, x10
    b.ne failed
    ARM_ADDR x10, expected_error
    ldr x10, [x10]
    cbnz x10, failed
    ARM_ADDR x10, prefix_index
    ldr x10, [x10]
    cmp x10, #{len(prefixes)}
    b.ne failed
    ARM_ADDR x0, res_artifact_path
    ARM_ADDR x1, expected_path
    ARM_CALL streq
    cbz w9, failed
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #32
    mov w0, #0
    ret
failed:
    mov w0, #95
    b _exit
registry_bad_args:
    ARM_ADDR x10, expected_error
    ldr x10, [x10]
    cmp x10, #2
    b.ne failed
    mov w0, #0
    b _exit
registry_io_error:
    ARM_ADDR x10, expected_error
    ldr x10, [x10]
    cmp x10, #1
    b.ne failed
    mov w0, #0
    b _exit
/* Keep the actual win_open path walk. Replace only external native operations.
 * Each successful lstat also verifies its literal prefix after parsing. */
arm_lstat:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x0, #-100
    mov x1, x19
    mov x2, #0
    mov x6, #0
    ARM_CALL win_open
    tbnz x9, #63, stat_return
    ARM_ADDR x10, prefix_index
    ldr x21, [x10]
    ARM_ADDR x11, prefix_table
    ldr x1, [x11, x21, lsl #3]
    cbz x1, stat_refused
    mov x0, x19
    ARM_CALL streq
    cbz w9, stat_refused
    ARM_ADDR x10, prefix_index
    add x21, x21, #1
    str x21, [x10]
    ARM_ADDR x10, injected_stat_error
    ldr x9, [x10]
    cbnz x9, stat_return
    ARM_ADDR x10, injected_mode
    ldr w10, [x10]
    str w10, [x20, #16]
    mov x9, #0
    b stat_return
stat_refused:
    mov x9, #-22
stat_return:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
win_nt_component:
    mov x9, #0x4400
    ret
CloseHandle:
    mov w0, #1
    ret
win_error:
    mov x9, #-5
    ret
GetCurrentDirectoryW:
    ARM_ADDR x2, current_directory
    mov x3, #0
1:  ldrh w10, [x2, x3, lsl #1]
    strh w10, [x1, x3, lsl #1]
    add x3, x3, #1
    cbnz w10, 1b
    mov w0, #6
    ret
/* ASCII-only direct parser controls; resolver UTF8 prefixes remain byte-exact. */
win_utf16:
    mov x9, #0
1:  ldrb w10, [x0, x9]
    strh w10, [x1, x9, lsl #1]
    add x9, x9, #1
    cbnz w10, 1b
    ret
.data
.p2align 3
res_artifacts: .quad input_path
registry_selected: .quad selected_row
selected_row: .space 32
    .quad digest
prefix_index: .quad 0
expected_error: .quad {error}
injected_mode: .quad {bad_mode or 16384}
injected_stat_error: .quad {stat_error}
prefix_table:
'''
    source += ''.join(f'    .quad prefix_{index}\n' for index in range(len(prefixes))) + '    .quad 0\n'
    source += literal('input_path', path) + literal('expected_path', expected or '')
    source += literal('bare_drive', 'C:') + literal('drive_relative', 'C:fixtures')
    source += ''.join(literal('prefix_' + str(index), value) for index, value in enumerate(prefixes))
    source += literal('digest', DIGEST) + literal('res_slash', '/') + literal('res_archive_suffix', '.tar.gz')
    source += '''
.p2align 1
current_directory: .hword 67,58,47,99,119,100,0
win_nt_root: .hword 92,63,63,92,67,58,92,0
registry_stat: .space 144
res_artifact_path: .space 4096
win_path_w: .space 8192
win_path_full: .space 8192
'''
    return source.replace('.section .rdata,"dr"', '.data').replace('.section .bss', '.data').replace('.section .data', '.data').replace(
        'adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE').replace(
        'add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')


def append_source(*, host=False, offset=1048575, text='A', error=0):
    """Exercise the actual one-MiB rendering bound, also in the COFF object."""
    generator = module()
    prepared = generator.prepare(ROOT / 'cli/aarch64/resolver.s')
    source = generator.prepare(ROOT / 'cli/aarch64/platform.inc')
    source += '\n.text\n' + region(prepared, 'res_append:', 'res_commit_lock:')
    if host:
        cursor = offset if error else offset + len(text)
        source += f'''
.global _main
_main:
    ARM_ADDR x19, res_rendered
    ARM_IMM x10, {offset}
    add x19, x19, x10
    ARM_ADDR x10, res_render_cursor
    str x19, [x10]
    ARM_ADDR x10, res_rendered
    add x10, x10, #256, lsl #12
    mov w11, #90
    strb w11, [x10]
    mov w20, #0
    ARM_ADDR x0, input_text
    ARM_CALL res_append
    b append_finished
dependency_lock_too_large:
    mov w20, #1
append_finished:
    cmp w20, #{error}
    b.ne append_failed
    ARM_ADDR x10, res_render_cursor
    ldr x10, [x10]
    ARM_ADDR x11, res_rendered
    ARM_IMM x12, {cursor}
    add x11, x11, x12
    cmp x10, x11
    b.ne append_failed
    ARM_ADDR x10, res_rendered
    add x10, x10, #256, lsl #12
    ldrb w11, [x10]
    cmp w11, #{90 if error else 0}
    b.ne append_failed
{('    ldrb w11, [x19]\n    cmp w11, #65\n    b.ne append_failed' if text and not (offset == 1048576 and error) else '')}
    mov w0, #0
    b _exit
append_failed:
    mov w0, #95
    b _exit
.data
'''
    else:
        source += '\ndependency_lock_too_large:\n    ret\n.data\n'
    source += literal('input_text', text)
    source += '.p2align 3\nres_render_cursor: .quad 0\nres_rendered: .space 1048577\n'
    if host:
        source = source.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE').replace(
            'add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        parser.error('This actual ARM64 routine fixture requires Apple Silicon.')
    suffix = DIGEST + '.tar.gz'
    cases = {
        'absolute_drive': ('C:/fixtures', ['C:/fixtures'], 'C:/fixtures/' + suffix),
        'absolute_nested': ('C:/fixtures/sub', ['C:/fixtures', 'C:/fixtures/sub'], 'C:/fixtures/sub/' + suffix),
        'backslash_absolute': ('C:\\fixtures\\sub', ['C:/fixtures', 'C:/fixtures/sub'], 'C:/fixtures/sub/' + suffix),
        'drive_root': ('C:/', ['C:/'], 'C:/' + suffix),
        'absolute_trailing_separator': ('C:/fixtures/', ['C:/fixtures', 'C:/fixtures/'], 'C:/fixtures/' + suffix),
        'relative_nested': ('fixtures/sub', ['fixtures', 'fixtures/sub'], 'fixtures/sub/' + suffix),
        'relative_trailing_separator': ('fixtures/', ['fixtures', 'fixtures/'], 'fixtures/' + suffix),
        'relative_directory': ('fixtures', ['fixtures'], 'fixtures/' + suffix),
    }
    failures = {
        'bare_drive_refused': ('C:', []),
        'drive_relative_refused': ('C:fixtures', []),
        'drive_relative_nested_refused': ('C:fixtures/sub', []),
        'double_root_separator_refused': ('C://fixtures', ['C:/']),
        'double_component_separator_refused': ('C:/fixtures//sub', ['C:/fixtures', 'C:/fixtures/']),
        'extra_colon_refused': ('C::/fixtures', []),
        'network_path_refused': ('//server/share', ['/']),
    }
    results = {}
    guards = {}
    with tempfile.TemporaryDirectory(prefix='asm-arm64-resolver-path-') as temporary:
        directory = Path(temporary)
        for name, arguments in cases.items():
            results[name] = abi_test.run_case(directory, name, fixture(*arguments))
        for name, (path, prefixes) in failures.items():
            results[name] = abi_test.run_case(directory, name, fixture(path, prefixes, error=1))
        results['non_directory_refused'] = abi_test.run_case(directory, 'non_directory_refused',
            fixture('C:/fixtures', ['C:/fixtures'], error=1, bad_mode=32768))
        results['symlink_mode_refused'] = abi_test.run_case(directory, 'symlink_mode_refused',
            fixture('C:/fixtures', ['C:/fixtures'], error=1, bad_mode=40960))
        results['stat_failure_refused'] = abi_test.run_case(directory, 'stat_failure_refused',
            fixture('C:/fixtures', ['C:/fixtures'], error=1, stat_error=-5))
        results['overlong_input_refused'] = abi_test.run_case(directory, 'overlong_input_refused',
            fixture('x' * 4001, [], error=2))
        for name, parameters in {
                'render_last_byte': {},
                'render_empty_at_limit': {'offset': 1048576, 'text': ''},
                'render_overflow_refused': {'offset': 1048576, 'text': 'A', 'error': 1},
                'render_partial_overflow_refused': {'text': 'AB', 'error': 1}}.items():
            results[name] = abi_test.run_case(directory, name, append_source(host=True, **parameters))
        # Changed upstream structure must fail generation rather than silently
        # omit either target adaptation. These guards do not claim execution.
        canonical = (ROOT / 'cli/aarch64/resolver.s').read_text()
        anchors = {
            'render_bound': '    ARM_ADDR x16, res_rendered + 1048576',
            'drive_walk': '    ARM_ADDR x16, res_artifact_path\n    mov x21, x16\n    mov x22, x21\n.Lres_dir_component:',
            'archive_suffix': '.Lres_dir_final:\n    ARM_CALL res_check_artifact_dir\n    mov x0, x22',
        }
        alternate = directory / 'resolver.s'
        for name, anchor in anchors.items():
            for mutation, text in [('missing', canonical.replace(anchor, '', 1)),
                                   ('duplicate', canonical + '\n' + anchor)]:
                alternate.write_text(text)
                try:
                    module().prepare(alternate)
                except ValueError as exception:
                    guards[name + '_' + mutation] = {'result': 'pass', 'refusal': str(exception)}
                else:
                    guards[name + '_' + mutation] = {'result': 'fail', 'refusal': None}
    coff_source = args.output.with_suffix('.append.s')
    coff_object = args.output.with_suffix('.append.obj')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    coff_source.write_text(append_source())
    command = ['/usr/bin/clang', '--no-default-config', '--target=aarch64-pc-windows-msvc',
               '-c', str(coff_source), '-o', str(coff_object)]
    assembled = subprocess.run(command, capture_output=True, text=True, timeout=30)
    coff = {'argv': command, 'exit_code': assembled.returncode,
            'stdout': assembled.stdout, 'stderr': assembled.stderr,
            'source_sha256': hashlib.sha256(coff_source.read_bytes()).hexdigest()}
    if assembled.returncode == 0:
        coff['object_sha256'] = hashlib.sha256(coff_object.read_bytes()).hexdigest()
    passed = all(row.get('build_exit_code') == 0 and row.get('exit_code') == 0 for row in results.values())
    passed = passed and assembled.returncode == 0
    passed = passed and all(row['result'] == 'pass' for row in guards.values())
    report = {'utc': datetime.now(timezone.utc).isoformat(), 'scope': 'actual generated offline walker and win_open drive parser; controlled ASCII conversion, current directory and native component calls; not native Windows qualification',
              'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                                (ROOT / 'tools/windows_arm64.py', ROOT / 'cli/aarch64/resolver.s',
                                 HERE / 'platform.s', HERE / 'files.s', Path(__file__))},
              'result': 'pass' if passed else 'fail', 'cases': results, 'generation_guards': guards,
              'coff_render_bound': coff}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': report['result'], 'cases': {key: value.get('exit_code', value.get('build_exit_code')) for key, value in results.items()}}, indent=2))
    return not passed


if __name__ == '__main__':
    raise SystemExit(main())
