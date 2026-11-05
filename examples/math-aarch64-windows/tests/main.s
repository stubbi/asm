// SPDX-License-Identifier: MIT
.include "src/min.s"
.equ TEST_FRAME, 192
.equ CASE_POINTER, 160
.equ CASES_LEFT, 168

.macro check_gp register, value
    mov x11, #\value
    movk x11, #0xabcd, lsl #48
    cmp \register, x11
    b.ne test_failed
.endm
.macro check_fp register
    fmov x10, \register
    mov x11, #0x55
    movk x11, #0xa5a5, lsl #48
    cmp x10, x11
    b.ne test_failed
.endm

.text
.global mainCRTStartup
.seh_proc mainCRTStartup
// Input: none. Output: ExitProcess(0) when value and ABI checks pass; otherwise 1.
// Saves changed nonvolatile GP and low 64-bit vector lanes with unwind metadata.
// Stack: 192 bytes, 16-byte aligned. No buffers or external resources are owned.
mainCRTStartup:
    stp x29, x30, [sp, #-TEST_FRAME]!
    .seh_save_fplr_x TEST_FRAME
    stp x19, x20, [sp, #16]
    .seh_save_regp x19, 16
    stp x21, x22, [sp, #32]
    .seh_save_regp x21, 32
    stp x23, x24, [sp, #48]
    .seh_save_regp x23, 48
    stp x25, x26, [sp, #64]
    .seh_save_regp x25, 64
    stp x27, x28, [sp, #80]
    .seh_save_regp x27, 80
    stp d8, d9, [sp, #96]
    .seh_save_fregp d8, 96
    stp d10, d11, [sp, #112]
    .seh_save_fregp d10, 112
    stp d12, d13, [sp, #128]
    .seh_save_fregp d12, 128
    stp d14, d15, [sp, #144]
    .seh_save_fregp d14, 144
    mov x29, sp
    .seh_set_fp
    .seh_endprologue
    mov x9, sp
    adrp x10, expected_sp
    str x9, [x10, :lo12:expected_sp]
    adrp x9, cases
    add x9, x9, :lo12:cases
    str x9, [sp, #CASE_POINTER]
    str x18, [sp, #176]
    mov w9, #8
    str w9, [sp, #CASES_LEFT]
    mov x19, #0x19
    movk x19, #0xabcd, lsl #48
    mov x20, #0x20
    movk x20, #0xabcd, lsl #48
    mov x21, #0x21
    movk x21, #0xabcd, lsl #48
    mov x22, #0x22
    movk x22, #0xabcd, lsl #48
    mov x23, #0x23
    movk x23, #0xabcd, lsl #48
    mov x24, #0x24
    movk x24, #0xabcd, lsl #48
    mov x25, #0x25
    movk x25, #0xabcd, lsl #48
    mov x26, #0x26
    movk x26, #0xabcd, lsl #48
    mov x27, #0x27
    movk x27, #0xabcd, lsl #48
    mov x28, #0x28
    movk x28, #0xabcd, lsl #48
    mov x9, #0x55
    movk x9, #0xa5a5, lsl #48
    fmov d8, x9
    fmov d9, x9
    fmov d10, x9
    fmov d11, x9
    fmov d12, x9
    fmov d13, x9
    fmov d14, x9
    fmov d15, x9
test_next:
    ldr x9, [sp, #CASE_POINTER]
    ldp x0, x1, [x9]
    bl asm_u64_min
    mov x10, sp
    adrp x9, expected_sp
    ldr x9, [x9, :lo12:expected_sp]
    cmp x10, x9
    b.ne test_failed
    cmp x29, x10
    b.ne test_failed
    ldr x9, [sp, #176]
    cmp x18, x9
    b.ne test_failed
    ldr x9, [sp, #CASE_POINTER]
    ldr x10, [x9, #16]
    cmp x0, x10
    b.ne test_failed
    check_gp x19, 0x19
    check_gp x20, 0x20
    check_gp x21, 0x21
    check_gp x22, 0x22
    check_gp x23, 0x23
    check_gp x24, 0x24
    check_gp x25, 0x25
    check_gp x26, 0x26
    check_gp x27, 0x27
    check_gp x28, 0x28
    check_fp d8
    check_fp d9
    check_fp d10
    check_fp d11
    check_fp d12
    check_fp d13
    check_fp d14
    check_fp d15
    add x9, x9, #24
    str x9, [sp, #CASE_POINTER]
    ldr w9, [sp, #CASES_LEFT]
    subs w9, w9, #1
    str w9, [sp, #CASES_LEFT]
    b.ne test_next
    mov w0, #0
    b test_exit
test_failed:
    mov w0, #1
test_exit:
    adrp x16, __imp_ExitProcess
    ldr x16, [x16, :lo12:__imp_ExitProcess]
    blr x16
    brk #0
.seh_endproc

.section .rdata,"dr"
.p2align 3
cases:
    .quad 0, 0, 0
    .quad 0, 0xffffffffffffffff, 0
    .quad 0xffffffffffffffff, 0, 0
    .quad 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff
    .quad 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff
    .quad 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff
    .quad 12, 37, 12
    .quad 37, 12, 12
.data
.p2align 3
expected_sp: .quad 0
