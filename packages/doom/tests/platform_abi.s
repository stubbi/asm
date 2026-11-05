// Test driver only. Exercise native Apple AArch64 callee-save conventions.
.text
.p2align 2
.globl _platform_abi_call
// x0=function,x1..x3=its first three integer arguments.
// Returns {i32 result,u32 broken}; bits0..9 x19..28,10 x29,11..18 d8..15.
_platform_abi_call:
    stp x29, x30, [sp, #-176]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mov x29, sp
    mov x16, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x19, #0x1919
    mov x20, #0x2020
    mov x21, #0x2121
    mov x22, #0x2222
    mov x23, #0x2323
    mov x24, #0x2424
    mov x25, #0x2525
    mov x26, #0x2626
    mov x27, #0x2727
    mov x28, #0x2828
.macro set_d reg, value
    mov x9, #\value
    fmov \reg, x9
.endm
    set_d d8, 0x8808
    set_d d9, 0x9909
    set_d d10, 0xaa0a
    set_d d11, 0xbb0b
    set_d d12, 0xcc0c
    set_d d13, 0xdd0d
    set_d d14, 0xee0e
    set_d d15, 0xff0f
    blr x16
    str w0, [sp, #160]
    mov w9, #0
.macro check_x reg, value, bit
    mov x10, #\value
    cmp \reg, x10
    cset w10, ne
    orr w9, w9, w10, lsl #\bit
.endm
    check_x x19, 0x1919, 0
    check_x x20, 0x2020, 1
    check_x x21, 0x2121, 2
    check_x x22, 0x2222, 3
    check_x x23, 0x2323, 4
    check_x x24, 0x2424, 5
    check_x x25, 0x2525, 6
    check_x x26, 0x2626, 7
    check_x x27, 0x2727, 8
    check_x x28, 0x2828, 9
    mov x10, sp
    cmp x29, x10
    cset w10, ne
    orr w9, w9, w10, lsl #10
.macro check_d reg, value, bit
    fmov x11, \reg
    check_x x11, \value, \bit
.endm
    check_d d8, 0x8808, 11
    check_d d9, 0x9909, 12
    check_d d10, 0xaa0a, 13
    check_d d11, 0xbb0b, 14
    check_d d12, 0xcc0c, 15
    check_d d13, 0xdd0d, 16
    check_d d14, 0xee0e, 17
    check_d d15, 0xff0f, 18
    ldr w0, [sp, #160]
    orr x0, x0, x9, lsl #32
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #176
    ret
