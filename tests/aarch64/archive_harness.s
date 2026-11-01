/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Exercise archive extraction and cache comparison through the native ABI.
 * This file is assembled as one translation unit from the repository root.
 */
.include "cli/aarch64/platform.inc"
.global _start
.section .text
_start:
    ldr x10, [sp]
    cmp x10, #4
    b.ne bad
    ldr x9, [sp, #16]
    ldr x0, [sp, #24]
    ldr x1, [sp, #32]
    ARM_IMM x19, 0x12345678
    ARM_IMM x20, 0x23456789
    ARM_IMM x21, 0x3456789a
    ARM_IMM x22, 0x456789ab
    ARM_IMM x23, 0x56789abc
    ARM_IMM x24, 0x6789abcd
    ARM_ADDR x10, initial_sp
    mov x11, sp
    str x11, [x10]
    ldrb w10, [x9]
    cmp w10, #'v'
    b.eq verify
    ARM_CALL extract_source_archive
    b result
verify:
    ARM_CALL verify_source_archive
result:
    mov w4, w9
    ARM_IMM x10, 0x12345678
    cmp x19, x10
    b.ne bad
    ARM_IMM x10, 0x23456789
    cmp x20, x10
    b.ne bad
    ARM_IMM x10, 0x3456789a
    cmp x21, x10
    b.ne bad
    ARM_IMM x10, 0x456789ab
    cmp x22, x10
    b.ne bad
    ARM_IMM x10, 0x56789abc
    cmp x23, x10
    b.ne bad
    ARM_IMM x10, 0x6789abcd
    cmp x24, x10
    b.ne bad
    ARM_ADDR x10, initial_sp
    ldr x10, [x10]
    mov x11, sp
    cmp x10, x11
    b.ne bad
    mov w0, w4
    b arm_exit
bad:
    mov w0, #99
    b arm_exit
.section .bss
.balign 8
initial_sp: .skip 8
.include "cli/aarch64/archive.s"
.include "cli/aarch64/platform.s"
.section .note.GNU-stack,"",%progbits
