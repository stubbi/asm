#!/usr/bin/env python3
"""Execute actual held hashing and ownership paths with hostile API results.
BCrypt is shimmed; this does not measure real Windows SHA-256 or I/O.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse, importlib.util, json, tempfile
from pathlib import Path
import abi_test
HERE=Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    spec=importlib.util.spec_from_file_location('arm',abi_test.ROOT/'tools/windows_arm64.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    body=(HERE/'hash.s').read_text();body=body[body.index('win_hash_fd:'):]
    clobber=abi_test.region(HERE/'abi_shim.s','.macro API_CLOBBER','.endm')+'.endm\n'
    prefix=m.prepare(abi_test.ROOT/'cli/aarch64/platform.inc')+'\n'+abi_test.region(HERE/'platform.s','.macro WIN_SAVE','/* x0=Win32 error')+'\n'+clobber+'\n.text\n'+body
    shim='''
.text
arm_fstat:
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#1
    b.eq adapter_error
    mov w11,#32768
    str w11,[x1,#ARM_STAT_MODE]
    mov x11,#5
    cmp x10,#2
    b.ne 1f
    mov x11,#6
1:  str x11,[x1,#ARM_STAT_SIZE]
    mov x9,#0
    ret
arm_lseek:
    cmp x0,#77
    b.ne failed
    cbnz x1,failed
    cbnz x2,failed
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#3
    b.eq adapter_error
    mov x9,#0
    ret
arm_read:
    cmp x0,#77
    b.ne failed
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#7
    b.eq adapter_error
    ARM_ADDR x11,reads
    ldr x12,[x11]
    add x13,x12,#1
    str x13,[x11]
    cbnz x12,1f
    mov x9,#3
    cmp x10,#8
    b.ne 3f
    mov x9,#6
    b 3f
1:  cmp x12,#1
    b.ne 2f
    cmp x10,#9
    b.eq 2f
    mov x9,#2
    b 3f
2:  mov x9,#0
3:  ret
adapter_error:
    mov x9,#-5
    ret
arm_close:
    b failed
BCryptOpenAlgorithmProvider:
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#4
    b.eq api_error
    mov x10,#0xb1
    str x10,[x0]
    API_CLOBBER
    mov w0,#0
    ret
BCryptCreateHash:
    cmp x0,#0xb1
    b.ne failed
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#5
    b.eq api_error
    mov x10,#0xc2
    str x10,[x1]
    API_CLOBBER
    mov w0,#0
    ret
BCryptHashData:
    cmp x0,#0xc2
    b.ne failed
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#6
    b.eq api_error
    API_CLOBBER
    mov w0,#0
    ret
BCryptFinishHash:
    cmp x0,#0xc2
    b.ne failed
    cmp x2,#32
    b.ne failed
    ARM_ADDR x10,case_id
    ldr x10,[x10]
    cmp x10,#10
    b.eq api_error
    stp xzr,xzr,[x1]
    stp xzr,xzr,[x1,#16]
    API_CLOBBER
    mov w0,#0
    ret
BCryptDestroyHash:
    cmp x0,#0xc2
    b.ne failed
    ARM_ADDR x10,destroys
    ldr x11,[x10]
    add x11,x11,#1
    str x11,[x10]
    API_CLOBBER
    mov w0,#0
    ret
BCryptCloseAlgorithmProvider:
    cmp x0,#0xb1
    b.ne failed
    ARM_ADDR x10,provider_closes
    ldr x11,[x10]
    add x11,x11,#1
    str x11,[x10]
    API_CLOBBER
    mov w0,#0
    ret
api_error:
    API_CLOBBER
    mov w0,#-1
    ret
failed:
    mov w0,#95
    b _exit
.data
.p2align 3
reads: .quad 0
destroys: .quad 0
provider_closes: .quad 0
output_hex: .space 65
'''
    results={}
    names=['valid_short_reads','stat_error','size_changed','seek_error','provider_error','hash_create_error','hash_data_error','read_error','stream_too_long','stream_too_short','finish_error']
    with tempfile.TemporaryDirectory(prefix='asm-arm-hash-') as tmp:
        for case,name in enumerate(names):
            want=case!=0;closes=int(case==0 or case>=5);destroys=int(case==0 or case>=6)
            source=prefix+shim+f'''\n.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    mov x0,#77
    mov x1,#5
    ARM_ADDR x2,output_hex
    ARM_CALL win_hash_fd
    cmp x9,#{int(want)}
    b.ne failed
    ARM_ADDR x10,provider_closes
    ldr x10,[x10]
    cmp x10,#{closes}
    b.ne failed
    ARM_ADDR x10,destroys
    ldr x10,[x10]
    cmp x10,#{destroys}
    b.ne failed
    mov w0,#0
    ldp x29,x30,[sp],#16
    ret
.data
.p2align 3
case_id: .quad {case}
'''
            source=source.replace('.section .rdata,"dr"','.data').replace('.section .bss','.data').replace('adrp \\reg, \\symbol','adrp \\reg, (\\symbol)@PAGE').replace('add \\reg, \\reg, :lo12:\\symbol','add \\reg, \\reg, (\\symbol)@PAGEOFF')
            results[name]=abi_test.run_case(Path(tmp),name,source)
    out={'scope':'actual held ARM64 hash routine with controlled BCrypt/file APIs; borrowed fd never closed; not Windows crypto qualification','result':'pass' if all(v.get('exit_code')==0 for v in results.values()) else 'fail','cases':results};a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2));return out['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
