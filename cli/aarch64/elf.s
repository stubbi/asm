/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global validate_host_elf

/* Bounded installation checks for a declared aarch64-linux executable.
 * This checks the ELF container and target, not program behavior or provenance.
 * ABI: returning routines preserve x19/x20/x21-x24. Other registers are scratch.
 */
.section .text

/* Input: x0=owned staged artifact path, x1=verified byte size (1..64 MiB).
 * Output: w9=1 for a supported ELF64 AArch64 executable; zero on any failure.
 * Opens without following a symlink and requires a regular file of exact size.
 * Accepts ET_EXEC/ET_DYN, 1..128 program headers of 56 bytes, readable segment
 * ranges, no writable+executable load segment, no executable stack, and an
 * entry point in a file-backed executable load segment. Does not map or run it.
 * Stack: 80 saved bytes plus nested calls. Owned buffers: 64/128/7168 bytes. */
validate_host_elf:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x19, x1
    ARM_IMM x11, 64
    cmp x19, x11
    b.lo .Lelf_fail_unopened
    ARM_IMM x11, 67108864
    cmp x19, x11
    b.hi .Lelf_fail_unopened
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lelf_fail_unopened
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, elf_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lelf_fail
    ARM_ADDR x16, elf_stat + 48
    ldr x11, [x16]
    cmp x19, x11
    b.ne .Lelf_fail
    ARM_ADDR x16, elf_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Lelf_fail
    mov x0, x21
    ARM_ADDR x16, elf_header
    mov x1, x16
    ARM_IMM w10, 64
    mov w2, w10
    ARM_CALL elf_read_exact
    tst x9, x9
    b.mi .Lelf_fail
    ARM_ADDR x16, elf_header
    mov x22, x16
    mov x16, x22
    ldr w10, [x16]
    ARM_IMM w11, 1179403647
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #4
    ldrb w10, [x16]
    ARM_IMM w11, 2
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #5
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #6
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #7
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lelf_osabi_ok
    and w10, w9, #255
    ARM_IMM w11, 3
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lelf_fail
.Lelf_osabi_ok:
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #16
    ldrh w10, [x16]
    mov w9, w10
    ARM_IMM w11, 2
    cmp w9, w11
    b.eq .Lelf_type_ok
    ARM_IMM w11, 3
    cmp w9, w11
    b.ne .Lelf_fail
.Lelf_type_ok:
    mov x16, x22
    add x16, x16, #18
    ldrh w10, [x16]
    ARM_IMM w11, 183
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #20
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #48
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #52
    ldrh w10, [x16]
    ARM_IMM w11, 64
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #54
    ldrh w10, [x16]
    ARM_IMM w11, 56
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #56
    ldrh w10, [x16]
    mov w23, w10
    tst w23, w23
    b.eq .Lelf_fail
    ARM_IMM w11, 128
    cmp w23, w11
    b.hi .Lelf_fail
    mov x16, x22
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_IMM x11, 64
    cmp x1, x11
    b.lo .Lelf_fail
    mov x9, x23
    ARM_IMM x11, 56
    mul x9, x9, x11
    adds x9, x9, x1
    b.cs .Lelf_fail
    cmp x9, x19
    b.hi .Lelf_fail
    mov x0, x21
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_lseek
    mov x16, x22
    add x16, x16, #32
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lelf_fail
    mov x0, x21
    ARM_ADDR x16, elf_program_headers
    mov x1, x16
    mov x2, x23
    ARM_IMM x11, 56
    mul x2, x2, x11
    ARM_CALL elf_read_exact
    tst x9, x9
    b.mi .Lelf_fail
    ARM_ADDR x16, elf_program_headers
    mov x22, x16
    eor w24, w24, w24
    tst w24, w24
.Lelf_segment:
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #32
    ldr x11, [x16]
    adds x9, x9, x11
    b.cs .Lelf_fail
    cmp x9, x19
    b.hi .Lelf_fail
    mov x16, x22
    ldr w10, [x16]
    ARM_IMM w11, 1685382481
    cmp w10, w11
    b.ne .Lelf_load_check
    mov x16, x22
    add x16, x16, #4
    ldr w10, [x16]
    ARM_IMM w11, 1
    tst w10, w11
    b.ne .Lelf_fail
.Lelf_load_check:
    mov x16, x22
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lelf_next_segment
    mov x16, x22
    add x16, x16, #4
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, -8
    tst w9, w11
    b.ne .Lelf_fail
    ARM_IMM w11, 3
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 3
    cmp w9, w11
    b.eq .Lelf_fail
    mov x16, x22
    add x16, x16, #32
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #40
    ldr x11, [x16]
    cmp x9, x11
    b.hi .Lelf_fail
    mov x16, x22
    add x16, x16, #16
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #40
    ldr x11, [x16]
    adds x9, x9, x11
    b.cs .Lelf_fail
    mov x16, x22
    add x16, x16, #48
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 1
    cmp x9, x11
    b.ls .Lelf_alignment_ok
    mov x16, x9
    sub x16, x16, #1
    mov x2, x16
    tst x9, x2
    b.ne .Lelf_fail
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #16
    ldr x11, [x16]
    eor x9, x9, x11
    tst x9, x9
    tst x9, x2
    b.ne .Lelf_fail
.Lelf_alignment_ok:
    mov x16, x22
    add x16, x16, #4
    ldr w10, [x16]
    ARM_IMM w11, 1
    tst w10, w11
    b.eq .Lelf_next_segment
    ARM_ADDR x16, elf_header + 24
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #16
    ldr x11, [x16]
    cmp x9, x11
    b.lo .Lelf_next_segment
    mov x16, x22
    add x16, x16, #16
    ldr x10, [x16]
    mov x2, x10
    mov x16, x22
    add x16, x16, #32
    ldr x11, [x16]
    adds x2, x2, x11
    b.cs .Lelf_fail
    cmp x9, x2
    b.hs .Lelf_next_segment
    ARM_IMM w10, 1
    mov w24, w10
.Lelf_next_segment:
    ARM_IMM x11, 56
    adds x22, x22, x11
    ARM_IMM w11, 1
    subs w23, w23, w11
    b.ne .Lelf_segment
    tst w24, w24
    b.eq .Lelf_fail
    mov x0, x21
    ARM_CALL arm_close
    tst x9, x9
    b.mi .Lelf_fail_unopened
    ARM_IMM w10, 1
    mov w9, w10
    b .Lelf_return
.Lelf_fail:
    mov x0, x21
    ARM_CALL arm_close
.Lelf_fail_unopened:
    eor w9, w9, w9
    tst w9, w9
.Lelf_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: x0=fd, x1=destination, x2=remaining capacity/required bytes.
 * Output: x9=0 on an exact read, -1 on EOF/error. Retries EINTR and short reads.
 * Scratch: syscall registers, x1/x2. No local stack, allocation or close operation. */
elf_read_exact:
    tst x2, x2
    b.eq .Lelf_read_done
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq elf_read_exact
    tst x9, x9
    b.le .Lelf_read_fail
    adds x1, x1, x9
    subs x2, x2, x9
    b elf_read_exact
.Lelf_read_done:
    eor w9, w9, w9
    tst w9, w9
    ret
.Lelf_read_fail:
    ARM_IMM x10, -1
    mov x9, x10
    ret

.section .bss
.balign 8
elf_header: .skip 64
elf_stat: .skip 128
elf_program_headers: .skip 7168
.section .note.GNU-stack,"",%progbits
