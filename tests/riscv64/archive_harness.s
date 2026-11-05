/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Args: argc=4, argv[1]=mode, argv[2]=archive, argv[3]=destination.
 * Exit: archive result (0/1); 99 means a private-ABI preservation failure.
 * The private CLI ABI returns t0 and preserves s0-s5, sp, gp, and tp.
 * Other saved-register names are private scratch, not the public C psABI.
 * The harness allocates no stack; Linux supplies a 16-byte aligned stack.
 */
.include "cli/riscv64/platform.inc"
.option norelax
.global _start
.text
_start:
    ld t1, 0(sp)
    li t2, 4
    bne t1, t2, bad
    la t1, initial_registers
    sd sp, 0(t1)
    sd gp, 8(t1)
    sd tp, 16(t1)
    ld t1, 16(sp)
    ld a0, 24(sp)
    ld a1, 32(sp)
    li s0, 0x12345678
    li s1, 0x23456789
    li s2, 0x3456789a
    li s3, 0x456789ab
    li s4, 0x56789abc
    li s5, 0x6789abcd
    lbu t1, 0(t1)
    li t2, 'v'
    beq t1, t2, verify
    call extract_source_archive
    j result
verify:
    call verify_source_archive
result:
    mv a0, t0
    li t1, 0x12345678
    bne s0, t1, bad
    li t1, 0x23456789
    bne s1, t1, bad
    li t1, 0x3456789a
    bne s2, t1, bad
    li t1, 0x456789ab
    bne s3, t1, bad
    li t1, 0x56789abc
    bne s4, t1, bad
    li t1, 0x6789abcd
    bne s5, t1, bad
    la t1, initial_registers
    ld t2, 0(t1)
    bne sp, t2, bad
    ld t2, 8(t1)
    bne gp, t2, bad
    ld t2, 16(t1)
    bne tp, t2, bad
    li a7, 93
    ecall
bad:
    li a0, 99
    li a7, 93
    ecall
.bss
.balign 8
initial_registers: .skip 24
.include "cli/riscv64/archive.s"
.include "cli/riscv64/platform.s"
.section .note.GNU-stack,""
