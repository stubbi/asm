#!/usr/bin/env python3
"""Run the real ARM64 startup error writer and shared complete-write routine.

Controlled output calls cover short writes, interruption, and output failure.
The host check does not qualify Windows argument parsing or console handles.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile

import abi_test

HERE = Path(__file__).resolve().parent
MESSAGE = b'asm: cannot initialize Windows arguments, paths, or user permissions. Check the command line and HOME.\n'


def source_prefix():
    spec = importlib.util.spec_from_file_location('startup_error_arm_generator', abi_test.ROOT / 'tools/windows_arm64.py')
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    source = (HERE / 'process.s').read_text()
    body = source[source.index('.Lwsu_bad:\n'):source.index('/* x0=executable UTF8')]
    data = ''
    if 'win_startup_error:\n' in source:
        start = source.index('win_startup_error:\n')
        end = source.index('\n.p2align', start)
        data = '\n.data\n' + source[start:end] + '\n'
    common = (abi_test.ROOT / 'cli/aarch64/asm.s').read_text()
    writer = common[common.index('write_cstr:\n'):common.index('/* Input: x0=valid output string.')]
    return generator.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc') + '\n.text\n' + body + writer + data


def program(prefix, mode):
    return prefix + f'''
.text
.global _main
_main:
    b .Lwsu_bad
/* Same preservation contract as the real Windows adapter. */
arm_write:
    cmp x0,#2
    b.ne failed
    ARM_ADDR x10,write_calls
    ldr x11,[x10]
    add x11,x11,#1
    str x11,[x10]
    mov x9,#{mode}
    cmp x9,#3
    b.eq io_error
    cmp x9,#2
    b.ne 1f
    cmp x11,#1
    b.ne 1f
    mov x9,#-4
    ret
1:  mov x12,x2
    cmp x9,#1
    b.ne 2f
    cmp x12,#3
    b.ls 2f
    mov x12,#3
2:  ARM_ADDR x10,written_length
    ldr x13,[x10]
    add x11,x13,x12
    cmp x11,#512
    b.hi failed
    str x11,[x10]
    ARM_ADDR x11,stderr_bytes
    add x11,x11,x13
    mov x10,x1
    mov x14,#0
3:  cmp x14,x12
    b.hs 4f
    ldrb w15,[x10,x14]
    strb w15,[x11,x14]
    add x14,x14,#1
    b 3b
4:  mov x9,x12
    ret
io_error:
    mov x9,#-13
    ret
ExitProcess:
    cmp w0,#2
    b.ne failed
    ARM_ADDR x10,write_calls
    ldr x10,[x10]
    cbz x10,failed
    ARM_ADDR x10,written_length
    ldr x10,[x10]
    mov x11,#{mode}
    cmp x11,#3
    b.eq 3f
    cmp x10,#{len(MESSAGE)}
    b.ne failed
    ARM_ADDR x10,stderr_bytes
    ARM_ADDR x11,expected_bytes
    mov x12,#0
1:  cmp x12,#{len(MESSAGE)}
    b.hs 2f
    ldrb w13,[x10,x12]
    ldrb w14,[x11,x12]
    cmp w13,w14
    b.ne failed
    add x12,x12,#1
    b 1b
2:  mov w0,#0
    b _exit
3:  cbnz x10,failed
    b 2b
failed:
    mov w0,#95
    b _exit
.data
.p2align 3
write_calls: .quad 0
written_length: .quad 0
stderr_bytes: .space 512
expected_bytes: .byte {','.join(map(str,MESSAGE))}
'''


def host_source(text):
    return (text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
            .replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prefix = source_prefix()
    with tempfile.TemporaryDirectory(prefix='asm-arm-startup-error-') as temporary:
        cases = {name: abi_test.run_case(Path(temporary), name, host_source(program(prefix, mode)))
                 for name, mode in (('complete',0), ('short',1), ('interrupted',2), ('failed-output',3))}
    report = {'scope': __doc__, 'result': 'pass' if all(row.get('exit_code') == 0 for row in cases.values()) else 'fail',
              'cases': cases}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': report['result'], 'cases': len(cases)}))
    return report['result'] != 'pass'


if __name__ == '__main__':
    raise SystemExit(main())
