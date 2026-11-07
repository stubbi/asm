#!/usr/bin/env python3
"""Execute actual prepared inventory parsing over native serialized receipts.
No host file authorization or installed executable is simulated as qualified.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import abi_test


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('windows_arm64', abi_test.ROOT / 'tools/windows_arm64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    prepared = module.prepare(abi_test.ROOT / 'cli/aarch64/asm.s')
    paths = [('native', 'C:/work/literal path & name.exe', True),
             ('virtual_prefix', '/C:/work/app.exe', False),
             ('relative_drive', 'C:work/app.exe', False),
             ('traversal', 'C:/work/../app.exe', False),
             ('regression_unix_root', 'C:/work/literal path & name.exe', True)]
    results = {}
    with tempfile.TemporaryDirectory(prefix='asm-arm64-inventory-') as temporary:
        for name, path, valid in paths:
            data = ('# asm-installed-v1\nfixture/hello\t0.1.0\taarch64-windows\t' + 'a'*64 + '\t1234\t' + path + '\tlocal\n').encode()
            body = prepared
            if name == 'regression_unix_root':
                anchor = '    ldr x0, [x19, #40]\n    ARM_CALL win_is_absolute\n    cbz w9, program_state_error'
                if body.count(anchor) != 1:
                    raise ValueError('inventory regression source anchor changed')
                body = body.replace(anchor, '    ldr x0, [x19, #40]\n    ldrb w10, [x0]\n    cmp w10, #47\n    b.ne program_state_error')
            error = 'program_state_error:\n    ARM_ADDR x0, program_error_state\n    b program_error'
            if body.count(error) != 1:
                raise ValueError('inventory failure interception anchor changed')
            body = body.replace(error, f'program_state_error:\n    mov w0,#{1 if valid else 0}\n    b _exit')
            source = body + f'''
.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    ARM_ADDR x0,program_input
    ARM_ADDR x1,fixture_receipt
    ARM_IMM x2,{len(data)}
1:  ldrb w10,[x1],#1
    strb w10,[x0],#1
    subs x2,x2,#1
    b.ne 1b
    ARM_ADDR x16,program_input_size
    ARM_IMM x10,{len(data)}
    str x10,[x16]
    ARM_CALL program_parse_state
    ARM_ADDR x16,program_count
    ldr x10,[x16]
    cmp x10,#1
    b.ne inventory_unexpected
    mov w0,#{0 if valid else 1}
    ldp x29,x30,[sp],#16
    ret
inventory_unexpected:
    mov w0,#95
    b _exit
.data
fixture_receipt: .byte {','.join(map(str,data))}
'''
            called = set(re.findall(r'^\s*(?:ARM_CALL|bl|b)\s+([A-Za-z_]\w*)\s*$', source, flags=re.M))
            defined = set(re.findall(r'^([A-Za-z_]\w*):', source, flags=re.M))
            source += '\n.text\n' + ''.join(label+':\n' for label in sorted(called-defined-{'_exit'})) + '    mov x0,#-1\n    mov x9,#-1\n    ret\n'
            source = source.replace('.section .asmmeta,"dr"','.data').replace('.section .rdata,"dr"','.data').replace('.section .bss','.data').replace('.section .text','.text').replace('.section .data','.data')
            source = source.replace('adrp \\reg, \\symbol','adrp \\reg, (\\symbol)@PAGE').replace('add \\reg, \\reg, :lo12:\\symbol','add \\reg, \\reg, (\\symbol)@PAGEOFF')
            results[name] = abi_test.run_case(Path(temporary), name, source, linker_flags=('-Wl,-no_fixup_chains',))
            # Keep recorded hashes/results instead of large completed Mach-O
            # files. The full prepared-source shim materializes zero regions.
            (Path(temporary) / name).unlink(missing_ok=True)
            (Path(temporary) / (name + '.s')).unlink(missing_ok=True)
    evidence = {'scope':'actual inventory parser with serialized drive paths and real metadata validators; no Windows filesystem qualification',
                'result':'pass' if all(r.get('exit_code') == (1 if name == 'regression_unix_root' else 0) for name,r in results.items()) else 'fail','cases':results}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(evidence,indent=2))
    return evidence['result']!='pass'


if __name__=='__main__':
    raise SystemExit(main())
