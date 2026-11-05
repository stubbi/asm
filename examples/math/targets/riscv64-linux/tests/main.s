/* SPDX-License-Identifier: MIT
 * Native RV64I Linux caller test. No C runtime is used.
 * Tests unsigned results, s0-s11, gp, tp, stack alignment, and stack contents.
 * _start writes no output. It exits with status 0 on success, or 1 on failure.
 * The test owns a 32-byte stack frame and the saved_state data below.
 */
.option norelax
.include "targets/riscv64-linux/src/min.s"

.equ SYS_EXIT, 93
.equ CASE_BYTES, 24
.equ STACK_BYTES, 32
.equ STACK_MARKER, 0x7766554433221100

.macro check_saved reg, expected
    li t0, \expected
    bne \reg, t0, .Lfailure
.endm

.section .text
.global _start
.type _start, @function
_start:
    andi t0, sp, 15
    bnez t0, .Lfailure
    addi sp, sp, -STACK_BYTES
    la t0, saved_state
    sd sp, 0(t0)
    sd gp, 8(t0)
    sd tp, 16(t0)

    la t0, cases
    sd t0, 0(sp)
    la t0, cases_end
    sd t0, 8(sp)
    li t0, STACK_MARKER
    sd t0, 16(sp)
    sd t0, 24(sp)

    li s0, 0x1122334455667700
    li s1, 0x1122334455667701
    li s2, 0x1122334455667702
    li s3, 0x1122334455667703
    li s4, 0x1122334455667704
    li s5, 0x1122334455667705
    li s6, 0x1122334455667706
    li s7, 0x1122334455667707
    li s8, 0x1122334455667708
    li s9, 0x1122334455667709
    li s10, 0x112233445566770a
    li s11, 0x112233445566770b

.Lcase:
    ld t0, 0(sp)
    ld a0, 0(t0)
    ld a1, 8(t0)
    call asm_u64_min

    la t0, saved_state
    ld t1, 0(t0)
    bne sp, t1, .Lfailure
    andi t1, sp, 15
    bnez t1, .Lfailure
    ld t1, 8(t0)
    bne gp, t1, .Lfailure
    ld t1, 16(t0)
    bne tp, t1, .Lfailure

    ld t0, 0(sp)
    ld t1, 16(t0)
    bne a0, t1, .Lfailure
    ld t1, 8(t0)
    bne a1, t1, .Lfailure
    li t0, STACK_MARKER
    ld t1, 16(sp)
    bne t0, t1, .Lfailure
    ld t1, 24(sp)
    bne t0, t1, .Lfailure

    check_saved s0, 0x1122334455667700
    check_saved s1, 0x1122334455667701
    check_saved s2, 0x1122334455667702
    check_saved s3, 0x1122334455667703
    check_saved s4, 0x1122334455667704
    check_saved s5, 0x1122334455667705
    check_saved s6, 0x1122334455667706
    check_saved s7, 0x1122334455667707
    check_saved s8, 0x1122334455667708
    check_saved s9, 0x1122334455667709
    check_saved s10, 0x112233445566770a
    check_saved s11, 0x112233445566770b

    ld t0, 0(sp)
    addi t0, t0, CASE_BYTES
    sd t0, 0(sp)
    ld t1, 8(sp)
    bne t0, t1, .Lcase

    addi sp, sp, STACK_BYTES
    li a0, 0
    li a7, SYS_EXIT
    ecall
.Lfailure:
    li a0, 1
    li a7, SYS_EXIT
    ecall
.size _start, .-_start

.section .rodata
.balign 8
cases:
    .quad 0, 0, 0
    .quad 0, 0xffffffffffffffff, 0
    .quad 0xffffffffffffffff, 0, 0
    .quad 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff
    .quad 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff
    .quad 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff
    .quad 12, 37, 12
    .quad 37, 12, 12
    .quad 37, 37, 37
    /* For each bit, check zero, the maximum, itself, and an adjacent value. */
    .set bit_index, 0
    .rept 64
        .quad (1 << bit_index), 0, 0
        .quad 0, (1 << bit_index), 0
        .quad (1 << bit_index), 0xffffffffffffffff, (1 << bit_index)
        .quad 0xffffffffffffffff, (1 << bit_index), (1 << bit_index)
        .quad (1 << bit_index), (1 << bit_index), (1 << bit_index)
        .quad (1 << bit_index), (1 << bit_index) - 1, (1 << bit_index) - 1
        .quad (1 << bit_index) - 1, (1 << bit_index), (1 << bit_index) - 1
        .set bit_index, bit_index + 1
    .endr
cases_end:

.section .bss
.balign 8
saved_state:
    .skip 24

.section .note.GNU-stack,"",@progbits
