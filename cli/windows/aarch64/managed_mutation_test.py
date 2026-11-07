#!/usr/bin/env python3
"""Exercise actual component/rename refusal before native mutation APIs.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse,json,tempfile
from pathlib import Path
import abi_test

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    s=abi_test.source_text();start=s.index('_main:');end=s.index('abi_failed:',start)
    s=s[:start]+'''_main:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    str x25,[sp,#32]
    mov x19,#0x4400
    ARM_IMM x20,O_NOFOLLOW + O_CLOEXEC + 64 + 128 + 2
    mov x25,#384
    ARM_ADDR x0,abi_component
    mov x1,#10
    mov x2,#1
    ARM_CALL win_nt_component
    cmn x9,#13
    b.ne abi_failed
    ARM_ADDR x10,abi_close_calls
    ldr x10,[x10]
    cbnz x10,abi_failed
    mov x0,#0x4400
    ARM_ADDR x1,mutation_leaf
    mov x2,#0x5500
    ARM_ADDR x6,mutation_leaf
    mov x4,#1
    ARM_CALL win_rename
    cmn x9,#13
    b.ne abi_failed
    ARM_ADDR x10,abi_close_calls
    ldr x10,[x10]
    cmp x10,#1
    b.ne abi_failed
    ARM_ADDR x10,guard_calls
    ldr x10,[x10]
    cmp x10,#2
    b.ne abi_failed
    ldr x25,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    mov w0,#0
    ret
'''+s[end:]
    s=s.replace('NtCreateFile:\n','NtCreateFile:\n    b abi_failed\n',1).replace('NtSetInformationFile:\n','NtSetInformationFile:\n    b abi_failed\n',1)
    s=s.replace('win_managed_write_allowed:\n    mov x9,#0\n    ret','''win_managed_write_allowed:
    ARM_ADDR x10,guard_calls
    ldr x11,[x10]
    add x11,x11,#1
    str x11,[x10]
    mov x9,#-13
    ret''')
    s+='\n.data\n.p2align 3\nguard_calls: .quad 0\nmutation_leaf: .asciz "asm.exe"\n'
    open_anchor='    ARM_CALL win_managed_write_allowed\n    cbnz x9, .Lwn_denied\n'
    rename_anchor='    ARM_CALL win_managed_write_allowed\n    cbnz x9, .Lwr_finish\n'
    assert s.count(open_anchor)==1 and s.count(rename_anchor)==1
    cases={'current':s,'regression_open_guard_removed':s.replace(open_anchor,''),'regression_rename_guard_removed':s.replace(rename_anchor,'')}
    with tempfile.TemporaryDirectory(prefix='asm-arm-mutations-') as tmp:
        results={name:abi_test.run_case(Path(tmp),name,src) for name,src in cases.items()}
    ok=results['current'].get('exit_code')==0 and all(v.get('build_exit_code')==0 and v.get('exit_code',0)!=0 for k,v in results.items() if k!='current')
    out={'scope':'actual ARM64 terminal create/write and rename adapter refusal with controlled reserved-parent result; borrowed parent ownership and no mutation API call; not Windows alias qualification','result':'pass' if ok else 'fail','cases':results};a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2));return not ok
if __name__=='__main__':raise SystemExit(main())
