#!/usr/bin/env python3
"""Actual managed launcher with controlled process/console APIs on ARM64.
No child is created; Windows console behavior requires the native suite.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse, importlib.util, json, tempfile
from pathlib import Path
import abi_test
HERE=Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    spec=importlib.util.spec_from_file_location('arm',abi_test.ROOT/'tools/windows_arm64.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    prefix=m.prepare(abi_test.ROOT/'cli/aarch64/platform.inc')+'\n'+abi_test.region(HERE/'abi_shim.s','.macro API_CLOBBER','.endm')+'.endm\n'+(HERE/'launcher.s').read_text()
    shim='''
.text
win_utf16:
    mov x9,#0
1:  cmp x9,x2
    b.hs failed
    ldrb w10,[x0,x9]
    strh w10,[x1,x9,lsl #1]
    add x9,x9,#1
    cbnz w10,1b
    ret
win_environment_block:
    cbnz x0,failed
    mov x9,#0
    ret
win_handle:
    cmp x0,#2
    b.hi failed
    add x9,x0,#10
    mov x0,x9
    ret
win_inherit_duplicate:
    cmp x0,#10
    b.lo failed
    cmp x0,#12
    b.hi failed
    sub x10,x0,#10
    ARM_ADDR x11,duplicates
    ldr x12,[x11]
    cmp x10,x12
    b.ne failed
    add x12,x12,#1
    str x12,[x11]
    add x9,x10,#101
    ret
InitializeProcThreadAttributeList:
    cmp x1,#1
    b.ne failed
    cbnz x2,failed
    ldr x10,[x3]
    cmp x10,#1024
    b.ne failed
    API_CLOBBER
    mov w0,#1
    ret
UpdateProcThreadAttribute:
    ARM_IMM x10,0x20002
    cmp x2,x10
    b.ne failed
    cmp x4,#24
    b.ne failed
    ldp x10,x11,[x3]
    cmp x10,#101
    b.ne failed
    cmp x11,#102
    b.ne failed
    ldr x10,[x3,#16]
    cmp x10,#103
    b.ne failed
    API_CLOBBER
    mov w0,#1
    ret
DeleteProcThreadAttributeList:
    API_CLOBBER
    ret
CreateProcessW:
    ARM_ADDR x10,handler
    ldr x10,[x10]
    cmp x10,#1
    b.ne failed
    cbnz x2,failed
    cbnz x3,failed
    cmp x4,#1
    b.ne failed
    ARM_IMM x10,0x80404
    cmp x5,x10
    b.ne failed
    cbnz x6,failed
    cbnz x7,failed
    ldr x10,[sp]
    ARM_ADDR x11,win_startup_info
    cmp x10,x11
    b.ne failed
    ldr w11,[x10,#60]
    cmp w11,#256
    b.ne failed
    ldr x11,[x10,#80]
    cmp x11,#101
    b.ne failed
    ldr x11,[x10,#88]
    cmp x11,#102
    b.ne failed
    ldr x11,[x10,#96]
    cmp x11,#103
    b.ne failed
    ARM_ADDR x10,expected_command
1:  ldrh w11,[x1],#2
    ldrh w12,[x10],#2
    cmp w11,w12
    b.ne failed
    cbnz w11,1b
    ldr x10,[sp,#8]
    mov x11,#201
    str x11,[x10]
    mov x11,#202
    str x11,[x10,#8]
    API_CLOBBER
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#5
    cset w0,ne
    ret
win_child_image_matches:
    cmp x0,#201
    b.ne failed
    cmp x1,#900
    b.ne failed
    ARM_ADDR x10,bound
    mov x11,#1
    str x11,[x10]
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#1
    b.ne 1f
    mov x9,#-116
    ret
1:  mov x9,#0
    ret
SetConsoleCtrlHandler:
    ARM_ADDR x10,win_managed_ctrl
    cmp x0,x10
    b.ne failed
    cmp w1,#1
    b.hi failed
    cbz w1,2f
    ARM_ADDR x10,handler
    mov x11,#1
    str x11,[x10]
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#3
    b.eq 3f
2:  API_CLOBBER
    mov w0,#1
    ret
3:  API_CLOBBER
    mov w0,#0
    ret
ResumeThread:
    cmp x0,#202
    b.ne failed
    ARM_ADDR x10,bound
    ldr x10,[x10]
    cmp x10,#1
    b.ne failed
    ARM_ADDR x10,handler
    ldr x10,[x10]
    cmp x10,#1
    b.ne failed
    ARM_ADDR x10,resumed
    mov x11,#1
    str x11,[x10]
    API_CLOBBER
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#2
    b.eq 1f
    mov w0,#1
    ret
1:  mov w0,#-1
    ret
WaitForSingleObject:
    cmp x0,#201
    b.ne failed
    cmn w1,#1
    b.ne failed
    API_CLOBBER
    ARM_ADDR x10,terminated
    ldr x10,[x10]
    cbnz x10,1f
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#4
    b.ne 1f
    mov w0,#-1
    ret
1:  mov w0,#0
    ret
GetExitCodeProcess:
    cmp x0,#201
    b.ne failed
    ARM_IMM w10,0xc000013a
    str w10,[x1]
    API_CLOBBER
    mov w0,#1
    ret
TerminateProcess:
    cmp x0,#201
    b.ne failed
    cmp x1,#127
    b.ne failed
    ARM_ADDR x10,terminated
    ldr x11,[x10]
    cbnz x11,failed
    mov x11,#1
    str x11,[x10]
    API_CLOBBER
    mov w0,#1
    ret
CloseHandle:
    ARM_ADDR x10,closed
    cmp x0,#101
    b.lo failed
    cmp x0,#103
    b.hi 1f
    sub x11,x0,#101
    b 2f
1:  cmp x0,#201
    b.lo failed
    cmp x0,#202
    b.hi failed
    sub x11,x0,#198
2:  ldr x12,[x10,x11,lsl #3]
    cbnz x12,failed
    mov x12,#1
    str x12,[x10,x11,lsl #3]
    API_CLOBBER
    mov w0,#1
    ret
failed:
    mov w0,#95
    b _exit
.data
.p2align 3
duplicates: .quad 0
bound: .quad 0
handler: .quad 0
resumed: .quad 0
terminated: .quad 0
closed: .space 40
argv0: .asciz "root.exe"
argv1: .asciz "argument with spaces"
argv2: .asciz ""
.p2align 3
args: .quad argv0,argv1,argv2,0
win_exe_w: .space 8192
win_arg_w: .space 32768
win_command_w: .space 65536
win_startup_info: .space 112
win_inherited_handles: .space 24
win_attribute_list: .space 1024
win_process_info: .space 24
'''
    command='"root.exe" "argument with spaces" "" '+chr(0)
    shim+='expected_command: .hword '+','.join(str(ord(c)) for c in command)+'\n'
    results={}
    with tempfile.TemporaryDirectory(prefix='asm-arm-launcher-') as tmp:
        for case,name in enumerate(['full_dword','image_mismatch','resume_error','handler_error','wait_error','create_error']):
            expected=0xc000013a if case==0 else -1
            source=prefix+shim+f'''\n.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    ARM_ADDR x0,argv0
    ARM_ADDR x1,args
    mov x2,#900
    mov x3,#999
    mov x4,#999
    ARM_CALL win_managed_launch
    ARM_IMM x10,{expected}
    cmp x9,x10
    b.ne failed
    ARM_ADDR x10,closed
    mov x11,#{3 if case in (3,5) else 5}
1:  ldr x12,[x10],#8
    cmp x12,#1
    b.ne failed
    subs x11,x11,#1
    b.ne 1b
    ARM_ADDR x10,resumed
    ldr x10,[x10]
    cmp x10,#{int(case in (0,2,4))}
    b.ne failed
    ARM_ADDR x10,terminated
    ldr x10,[x10]
    cmp x10,#{int(case in (1,2,4))}
    b.ne failed
    mov w0,#0
    ARM_CALL win_managed_ctrl
    cmp w0,#1
    b.ne failed
    mov w0,#1
    ARM_CALL win_managed_ctrl
    cmp w0,#1
    b.ne failed
    mov w0,#2
    ARM_CALL win_managed_ctrl
    cbnz w0,failed
    ldp x29,x30,[sp],#16
    ret
.data
.p2align 3
case_id: .quad {case}
'''
            source=source.replace('adrp \\reg, \\symbol','adrp \\reg, (\\symbol)@PAGE').replace('add \\reg, \\reg, :lo12:\\symbol','add \\reg, \\reg, (\\symbol)@PAGEOFF')
            results[name]=abi_test.run_case(Path(tmp),name,source)
    out={'scope':'actual ARM64 managed launcher with controlled APIs; child binding order, streams, infinite wait, full DWORD, termination/reaping and ownership; not Windows console qualification','result':'pass' if all(v.get('exit_code')==0 for v in results.values()) else 'fail','cases':results};a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2));return out['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
