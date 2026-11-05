#!/usr/bin/env python3
"""Exercise real managed failure paths before shared stage deletion.

The controlled deletion boundary requires all owned stage files to be closed.
This is an Apple Silicon routine check, not Windows filesystem qualification.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile

import abi_test

HERE = Path(__file__).resolve().parent


def source_prefix():
    spec = importlib.util.spec_from_file_location('cleanup_arm_generator', abi_test.ROOT / 'tools/windows_arm64.py')
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    managed = (HERE / 'managed.s').read_text()
    update = (HERE / 'versioned_update.s').read_text()
    helper = ''
    if 'win_managed_release_stage_files:\n' in managed:
        helper = managed[managed.index('win_managed_release_stage_files:\n'):
                         managed.index('/* Close only owned contexts.')]
    failure = managed[managed.index('win_managed_fail:\n'):
                      managed.index('.section .rdata', managed.index('win_managed_fail:\n'))]
    incompatible = update[update.index('win_managed_incompatible:\n'):
                          update.index('.section .rdata', update.index('win_managed_incompatible:\n'))]
    macros = generator.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc')
    # These macros do not belong to the platform header.
    owned = managed[managed.index('.macro WM_LOAD'):managed.index('/* Read canonical native path')]
    return macros + '\n.text\n' + owned + helper + failure + incompatible


def program(prefix, function, candidate, record):
    expected = (candidate >= 0) + (record >= 0)
    message = 'wm_error' if function == 'win_managed_fail' else 'wm_compat_error'
    return prefix + f'''
.text
.global _main
_main:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    mov x19,#0x5a5
    ARM_CALL {function}
    ARM_CALL {function}
    cmp x19,#0x5a5
    b.ne failed
    ARM_ADDR x10,close_count
    ldr x10,[x10]
    cmp x10,#{expected}
    b.ne failed
    ARM_ADDR x10,borrowed_root
    ldr x10,[x10]
    cmp x10,#201
    b.ne failed
    ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    mov w0,#0
    ret
/* Shared cleanup can remove its stage only after these file handles close.
 * Both calls also prove that the failure instruction and status survive. */
self_fail:
    ARM_ADDR x10,{message}
    cmp x0,x10
    b.ne failed
    cmp w1,#1
    b.ne failed
    ARM_ADDR x10,wm_candidate_fd
    ldr x10,[x10]
    cmn x10,#1
    b.ne failed
    ARM_ADDR x10,wm_newrecord_fd
    ldr x10,[x10]
    cmn x10,#1
    b.ne failed
    ret
arm_close:
    cmp x0,#101
    b.eq 1f
    cmp x0,#102
    b.ne failed
    ARM_ADDR x10,wm_newrecord_fd
    b 2f
1:  ARM_ADDR x10,wm_candidate_fd
2:  ldr x10,[x10]
    cmn x10,#1
    b.ne failed
    ARM_ADDR x10,close_count
    ldr x11,[x10]
    add x11,x11,#1
    str x11,[x10]
    mov x9,#-5
    mov x10,#10
    mov x11,#11
    mov x12,#12
    mov x13,#13
    mov x14,#14
    mov x15,#15
    ret
failed:
    mov w0,#95
    b _exit
.data
.p2align 3
wm_candidate_fd: .quad {candidate}
wm_newrecord_fd: .quad {record}
borrowed_root: .quad 201
close_count: .quad 0
wm_error: .asciz "managed state failure"
wm_compat_error: .asciz "launcher compatibility failure"
'''


def host_source(text):
    return (text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
            .replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prefix = source_prefix()
    cases = {}
    controls = {}
    with tempfile.TemporaryDirectory(prefix='asm-arm-managed-cleanup-') as temporary:
        root = Path(temporary)
        for function in ('win_managed_fail', 'win_managed_incompatible'):
            for candidate, record in ((-1, -1), (101, -1), (-1, 102), (101, 102)):
                name = f'{function}-candidate{candidate}-record{record}'
                cases[name] = abi_test.run_case(root, name, host_source(program(prefix, function, candidate, record)))
        call = '    ARM_CALL win_managed_release_stage_files\n'
        if prefix.count(call) == 2:
            for function in ('win_managed_fail', 'win_managed_incompatible'):
                anchor = function + ':\n' + call
                assert prefix.count(anchor) == 1
                changed = prefix.replace(anchor, function + ':\n')
                name = 'regression-' + function
                controls[name] = abi_test.run_case(root, name, host_source(program(changed, function, 101, 102)))
    ok = (all(row.get('exit_code') == 0 for row in cases.values()) and len(controls) == 2 and
          all(row.get('build_exit_code') == 0 and row.get('exit_code') == 95 for row in controls.values()))
    report = {'scope': __doc__, 'result': 'pass' if ok else 'fail',
              'cases': cases, 'regression_controls': controls}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': report['result'], 'cases': len(cases), 'regression_controls': len(controls)}))
    return not ok


if __name__ == '__main__':
    raise SystemExit(main())
