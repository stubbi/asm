#!/usr/bin/env python3
"""Actual role, reserved-ancestor, and owned-descriptor routines on ARM64.
Windows ordinal/file-name APIs remain controlled shims, not qualification.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse, importlib.util, json, tempfile
from pathlib import Path
import abi_test
HERE=Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    spec=importlib.util.spec_from_file_location('arm',abi_test.ROOT/'tools/windows_arm64.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    src=(HERE/'managed.s').read_text()
    body=src[src.index('win_managed_role:'):src.index('/* Startup returns')]+src[src.index('win_managed_reserved_path:'):src.index('.section .bss',src.index('win_managed_reserved_path:'))]+src[src.index('win_managed_cleanup:'):src.index('win_managed_fail:')]
    prefix=m.prepare(abi_test.ROOT/'cli/aarch64/platform.inc')+'\n.text\n'+body+'''
strlen:
    mov x9,#0
1:  ldrb w10,[x0,x9]
    cbz w10,2f
    add x9,x9,#1
    b 1b
2:  ret
win_managed_path_equal:
    mov x2,x0
    mov x3,x1
1:  ldrb w10,[x2],#1
    ldrb w11,[x3],#1
    cmp w10,#65
    b.lo 2f
    cmp w10,#90
    b.hi 2f
    add w10,w10,#32
2:  cmp w11,#65
    b.lo 3f
    cmp w11,#90
    b.hi 3f
    add w11,w11,#32
3:  cmp w10,w11
    b.ne 4f
    cbnz w10,1b
    mov x9,#1
    ret
4:  mov x9,#0
    ret
arm_close:
    ARM_ADDR x10,close_count
    ldr x11,[x10]
    add x11,x11,#1
    str x11,[x10]
    mov x9,#0
    ret
.data
wm_root_suffix: .asciz "/.local/bin/asm.exe"
wm_version_suffix: .asciz "/.local/bin/.asm-cli/versions/"
wm_exe_suffix: .asciz "/asm.exe"
wm_store_suffix: .asciz "/.local/bin/.asm-cli"
wm_role_prefix: .space 64
wm_guard_segment: .space 21
.p2align 3
close_count: .quad 0
owned_a: .quad 101
owned_b: .quad -1
owned_c: .quad 103
wm_cleanup_slots: .quad owned_a,owned_b,owned_c,0
'''
    cases=[('root','C:/Users/one/.local/bin/asm.exe','win_managed_role',1),('changed_home_root','D:/Other HOME/.local/bin/ASM.EXE','win_managed_role',1),('payload','C:/Users/one/.local/bin/.asm-cli/versions/'+'a'*64+'/asm.exe','win_managed_role',2),('standalone','C:/src/build/asm.exe','win_managed_role',0),('lookalike','C:/Users/one/.local/bin/asm.exe.old','win_managed_role',0),('reserved','C:/Users/one/.local/bin/.asm-cli','win_managed_reserved_path',-13),('reserved_descendant','C:/Users/one/.LOCAL/BIN/.ASM-CLI/versions/abc','win_managed_reserved_path',-13),('similar_store','C:/Users/one/.local/bin/.asm-cli-extra','win_managed_reserved_path',0)]
    results={}
    with tempfile.TemporaryDirectory(prefix='asm-arm-roles-') as tmp:
        for name,path,routine,want in cases:
            source=prefix+f'''\n.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    ARM_ADDR x0,path
    ARM_CALL {routine}
    mov x10,#{want}
    cmp x9,x10
    b.ne failed
    ARM_CALL win_managed_cleanup
    ARM_CALL win_managed_cleanup
    ARM_ADDR x10,close_count
    ldr x10,[x10]
    cmp x10,#2
    b.ne failed
    ARM_ADDR x10,owned_a
    ldr x10,[x10]
    cmn x10,#1
    b.ne failed
    mov w0,#0
    ldp x29,x30,[sp],#16
    ret
failed:
    mov w0,#95
    b _exit
.data
path: .byte {','.join(map(str,path.encode()+bytes(1)))}
'''
            source=source.replace('adrp \\reg, \\symbol','adrp \\reg, (\\symbol)@PAGE').replace('add \\reg, \\reg, :lo12:\\symbol','add \\reg, \\reg, (\\symbol)@PAGEOFF')
            results[name]=abi_test.run_case(Path(tmp),name,source)
    out={'scope':'actual ARM64 role/reserved-path/cleanup bodies, controlled ordinal helper; not Windows alias or startup qualification','result':'pass' if all(v.get('exit_code')==0 for v in results.values()) else 'fail','cases':results};a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2));return out['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
