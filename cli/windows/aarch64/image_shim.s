/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only class44 boundary; never part of release source preparation. */
.text
.global _main
_main:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    ARM_ADDR x19,image_cases
    mov x20,#6
1:  ldr x10,[x19]
    ARM_ADDR x11,image_status
    str x10,[x11]
    ldr x10,[x19,#8]
    ARM_ADDR x11,image_missing
    str x10,[x11]
    mov x0,#0x4404
    ARM_CALL win_image_matches
    ARM_IMM x11,0x4404
    cmp x0,x11
    b.ne image_failed
    ldr x10,[x19,#16]
    cmp x9,x10
    b.ne image_failed
    add x19,x19,#24
    subs x20,x20,#1
    b.ne 1b
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    mov w0,#0
    ret
image_failed:
    mov w0,#95
    b _exit
GetModuleHandleW:
    ARM_ADDR x10,win_ntdll_name
    cmp x0,x10
    b.ne image_failed
    ARM_ADDR x10,image_missing
    ldr x10,[x10]
    cmp x10,#1
    b.eq 1f
    API_CLOBBER
    mov x0,#0x8888
    ret
1:  API_CLOBBER
    mov x0,#0
    ret
GetProcAddress:
    ARM_IMM x11,0x8888
    cmp x0,x11
    b.ne image_failed
    ARM_ADDR x10,win_image_query_name
    cmp x1,x10
    b.ne image_failed
    ARM_ADDR x10,image_missing
    ldr x10,[x10]
    cmp x10,#2
    b.eq 1f
    API_CLOBBER
    ARM_ADDR x0,image_query
    ret
1:  API_CLOBBER
    mov x0,#0
    ret
image_query:
    cmn x0,#1
    b.ne image_failed
    cmp x1,#44
    b.ne image_failed
    cmp x3,#8
    b.ne image_failed
    cbnz x4,image_failed
    ldr x10,[x2]
    ARM_IMM x11,0x4404
    cmp x10,x11
    b.ne image_failed
    API_CLOBBER
    ARM_ADDR x10,image_status
    ldr w0,[x10]
    ret
.data
.p2align 3
image_cases:
    .quad 0,0,0
    .quad 0xc0000001,0,-116
    .quad 0xc0000003,0,-95
    .quad 0x103,0,-95
    .quad 0,1,-95
    .quad 0,2,-95
image_status: .quad 0
image_missing: .quad 0
