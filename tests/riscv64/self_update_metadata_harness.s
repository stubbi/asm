/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Args: argv[1]=version, argv[2]=digest, argv[3]=size. JSON arrives on stdin.
 * Exit: 0 + source digest on stdout for acceptance; 1 for rejection; 3 for
 * harness failure. The borrowed JSON ends exactly at a PROT_NONE guard page.
 * Private ABI: a0=input, a1=length, a2=row; result=t0; s0-s5/sp/gp/tp retained.
 * Linux RISC-V syscall numbers and mmap argument order are used directly.
 * Buffers are harness-owned. No stack allocation or network operations.
 */
.include "cli/riscv64/platform.inc"
.option norelax
.ifndef RV_TEST_PAGE_SIZE
.equ RV_TEST_PAGE_SIZE, 4096
.endif
.equ MAP_BYTES, 1048576 + 2 * RV_TEST_PAGE_SIZE
.equ LAST_PAGE, 1048576 + RV_TEST_PAGE_SIZE
.global _start
.text
_start:
    ld t1, 0(sp)
    li t2, 4
    bne t1, t2, harness_error
    la t1, harness_row
    ld t2, 16(sp)
    sd t2, 8(t1)
    ld t2, 24(sp)
    sd t2, 32(t1)
    ld t2, 32(sp)
    sd t2, 48(t1)
    li s2, 0
harness_read:
    li t1, 1048577
    bgeu s2, t1, harness_read_done
    li a0, 0
    la a1, harness_input
    add a1, a1, s2
    sub a2, t1, s2
    li a7, 63
    ecall
    li t1, -4
    beq a0, t1, harness_read
    bltz a0, harness_error
    beqz a0, harness_read_done
    add s2, s2, a0
    j harness_read
harness_read_done:
    la t1, harness_length
    sd s2, 0(t1)
    la s3, harness_input
    li t1, 1048576
    bgtu s2, t1, harness_call
    li a0, 0
    li a1, MAP_BYTES
    li a2, 3
    li a3, 34
    li a4, -1
    li a5, 0
    li a7, 222
    ecall
    li t1, -4095
    bgeu a0, t1, harness_error
    mv s4, a0
    li a1, RV_TEST_PAGE_SIZE
    li a2, 0
    li a7, 226
    ecall
    bltz a0, harness_error
    li t1, LAST_PAGE
    add a0, s4, t1
    li a1, RV_TEST_PAGE_SIZE
    li a2, 0
    li a7, 226
    ecall
    bltz a0, harness_error
    li t1, LAST_PAGE
    add s3, s4, t1
    sub s3, s3, s2
    mv t1, s3
    la t2, harness_input
    mv t3, s2
harness_copy:
    beqz t3, harness_readonly
    lbu t4, 0(t2)
    sb t4, 0(t1)
    addi t1, t1, 1
    addi t2, t2, 1
    addi t3, t3, -1
    j harness_copy
harness_readonly:
    li t1, RV_TEST_PAGE_SIZE
    add a0, s4, t1
    li a1, 1048576
    li a2, 1
    li a7, 226
    ecall
    bltz a0, harness_error
harness_call:
    la t1, harness_start
    sd s3, 0(t1)
    la t1, self_source_commit
    li t2, 41
    li t3, 'X'
harness_poison:
    sb t3, 0(t1)
    addi t1, t1, 1
    addi t2, t2, -1
    bnez t2, harness_poison
    la t1, harness_registers
    sd sp, 0(t1)
    sd gp, 8(t1)
    sd tp, 16(t1)
    la t1, harness_start
    ld a0, 0(t1)
    la t1, harness_length
    ld a1, 0(t1)
    la a2, harness_row
    li s0, 0x1111
    li s1, 0x2222
    li s2, 0x3333
    li s3, 0x4444
    li s4, 0x5555
    li s5, 0x6666
    call self_parse_release
    li t1, 0x1111
    bne s0, t1, harness_error
    li t1, 0x2222
    bne s1, t1, harness_error
    li t1, 0x3333
    bne s2, t1, harness_error
    li t1, 0x4444
    bne s3, t1, harness_error
    li t1, 0x5555
    bne s4, t1, harness_error
    li t1, 0x6666
    bne s5, t1, harness_error
    la t1, harness_registers
    ld t2, 0(t1)
    bne sp, t2, harness_error
    ld t2, 8(t1)
    bne gp, t2, harness_error
    ld t2, 16(t1)
    bne tp, t2, harness_error
    beqz t0, harness_success
    li t1, 1
    bne t0, t1, harness_error
    la t1, self_source_commit
    li t2, 41
harness_cleared:
    lbu t3, 0(t1)
    bnez t3, harness_error
    addi t1, t1, 1
    addi t2, t2, -1
    bnez t2, harness_cleared
    li a0, 1
    j harness_exit
harness_success:
    la a1, self_source_commit
    lbu t1, 40(a1)
    bnez t1, harness_error
    li a0, 1
    li a2, 40
    li a7, 64
    ecall
    li t1, 40
    bne a0, t1, harness_error
    li a0, 0
    j harness_exit
harness_error:
    li a0, 3
harness_exit:
    li a7, 93
    ecall
.section .rodata
harness_package: .asciz "stubbi/asm"
harness_target: .asciz "riscv64-linux"
harness_kind: .asciz "executable"
harness_unused: .asciz ""
.data
harness_row:
    .quad harness_package, 0, harness_target, harness_kind
    .quad 0, harness_unused, 0, harness_unused
.bss
.balign 8
harness_length: .skip 8
harness_start: .skip 8
harness_registers: .skip 24
harness_input: .skip 1048577
.include "cli/riscv64/self_update_metadata.s"
.include "cli/riscv64/platform.s"
.section .note.GNU-stack,""
