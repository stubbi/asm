#!/usr/bin/env python3
"""Execute the actual ARM64 PE parser over supplied bytes with host file shims.
No Windows file authorization or process execution is tested.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import abi_test

HERE = Path(__file__).resolve().parent


def source_text(path, size, expected=1):
    spec = importlib.util.spec_from_file_location('windows_arm64', abi_test.ROOT / 'tools/windows_arm64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pe = (HERE / 'pe.s').read_text()
    parser = pe[:pe.index('win_pub_validate_pe:')] + pe[pe.index('.section .bss'):]
    path_bytes = ','.join(str(x) for x in str(path.resolve()).encode() + bytes(1))
    source = module.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc') + '\n' + abi_test.region(HERE / 'platform.s', '.macro WIN_SAVE', '/* x0=Win32 error') + '\n' + parser
    source += f'''\n.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    ARM_ADDR x0, pe_path
    ARM_IMM x1, {size}
    ARM_CALL validate_host_elf
    cmp w9,#{expected}
    cset w0,ne
    ldp x29,x30,[sp],#16
    ret
arm_open:
    WIN_SAVE
    mov x1,#0
    bl _open
    mov x9,x0
    WIN_RETURN
arm_fstat:
    WIN_SAVE
    ARM_IMM x10, {size}
    str x10,[x1,#ARM_STAT_SIZE]
    mov w10,#32768
    str w10,[x1,#ARM_STAT_MODE]
    mov x9,#0
    WIN_RETURN
arm_read:
    WIN_SAVE
    bl _read
    mov x9,x0
    WIN_RETURN
arm_lseek:
    WIN_SAVE
    bl _lseek
    mov x9,x0
    WIN_RETURN
arm_close:
    WIN_SAVE
    bl _close
    mov x9,x0
    WIN_RETURN
.data
pe_path: .byte {path_bytes}
'''
    source = source.replace('.section .bss', '.data')
    source = source.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    source = source.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    return source


def main():
    import hashlib
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    data = args.artifact.read_bytes()
    import struct
    bad_dos = bytearray(data)
    bad_dos[0] ^= 1
    bad_machine = bytearray(data)
    pe = struct.unpack_from('<I', data, 60)[0]
    struct.pack_into('<H', bad_machine, pe + 4, 0x8664)
    fixtures = {'native': (data, 1), 'bad_dos': (bad_dos, 0),
                'wrong_machine': (bad_machine, 0), 'truncated': (data[:-1], 0)}
    with tempfile.TemporaryDirectory(prefix='asm-arm64-pe-') as temporary:
        results = {}
        for name, (content, expected) in fixtures.items():
            path = Path(temporary) / (name + '.exe')
            path.write_bytes(content)
            results[name] = abi_test.run_case(Path(temporary), name, source_text(path, len(content), expected))
    evidence = {'scope': 'actual PE parser with host file adapters; no Windows authorization',
                'artifact':str(args.artifact),'artifact_sha256':hashlib.sha256(data).hexdigest(),
                'result':'pass' if all(r.get('exit_code') == 0 for r in results.values()) else 'fail',
                'cases':results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
    return evidence['result'] != 'pass'


if __name__ == '__main__':
    raise SystemExit(main())
