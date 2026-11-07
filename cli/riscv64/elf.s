/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/elf.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global validate_host_elf
/* Bounded installation checks for a declared aarch64-linux executable.
 * This checks the ELF container and target, not program behavior or provenance.
 * ABI: returning routines preserve s0/s1/s2-s5. Other registers are scratch.
 */
.section .text
/* Input: a0=owned staged artifact path, a1=verified byte size (1..64 MiB).
 * Output: t0=1 for a supported ELF64 RISC-V64 executable; zero on any failure.
 * Opens without following a symlink and requires a regular file of exact size.
 * Accepts ET_EXEC/ET_DYN, 1..128 program headers of 56 bytes, readable segment
 * ranges, no writable+executable load segment, no executable stack, and an
 * entry point in a file-backed executable load segment. Does not map or run it.
 * Stack: 80 saved bytes plus nested calls. Owned buffers: 64/128/7168 bytes. */
validate_host_elf:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s0, a1
    RV_IMM t2, 64, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lelf_fail_unopened
    RV_IMM t2, 67108864, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lelf_fail_unopened
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lelf_fail_unopened
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, elf_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lelf_fail
    RV_ADDR s6, elf_stat + 48
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lelf_fail
    RV_ADDR s6, elf_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 32768, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv a0, s2
    RV_ADDR s6, elf_header
    mv a1, s6
    RV_IMM t1, 64, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL elf_read_exact
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lelf_fail
    RV_ADDR s6, elf_header
    mv s3, s6
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1179403647, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 2, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 5
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 1, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 6
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 1, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lelf_osabi_ok
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 3, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
.Lelf_osabi_ok:
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 2, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lelf_type_ok
    RV_IMM t2, 3, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
.Lelf_type_ok:
    mv s6, s3
    li s10, 18
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 243, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    andi s8, t1, -6
    beqz s8, .Lrv_flags_ok_elf150
    RV_JUMP .Lelf_fail
.Lrv_flags_ok_elf150:
    mv s6, s3
    li s10, 52
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 64, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 54
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 56, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 56
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    mv s4, t1
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, .Lelf_fail
    RV_IMM t2, 128, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lelf_fail
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_IMM t2, 64, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lelf_fail
    mv t0, s4
    RV_IMM t2, 56, 64
    mv s10, t2
    mul t0, t0, s10
    mv s8, t0
    mv s10, a1
    RV_FLAGS add, 64
    mv t0, s11
    RV_BCOND cs, .Lelf_fail
    mv s8, t0
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lelf_fail
    mv a0, s2
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_lseek
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lelf_fail
    mv a0, s2
    RV_ADDR s6, elf_program_headers
    mv a1, s6
    mv a2, s4
    RV_IMM t2, 56, 64
    mv s10, t2
    mul a2, a2, s10
    RV_CALL elf_read_exact
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lelf_fail
    RV_ADDR s6, elf_program_headers
    mv s3, s6
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
.Lelf_segment:
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    RV_BCOND cs, .Lelf_fail
    mv s8, t0
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lelf_fail
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1685382481, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_load_check
    mv s6, s3
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lelf_fail
.Lelf_load_check:
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lelf_next_segment
    mv s6, s3
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, -8, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lelf_fail
    RV_IMM t2, 3, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 3, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lelf_fail
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lelf_fail
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    RV_BCOND cs, .Lelf_fail
    mv s6, s3
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ls, .Lelf_alignment_ok
    mv s6, t0
    li s10, 1
    sub s6, s6, s10
    mv a2, s6
    mv s8, t0
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND ne, .Lelf_fail
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s10, t2
    xor t0, t0, s10
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    mv s8, t0
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND ne, .Lelf_fail
.Lelf_alignment_ok:
    mv s6, s3
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lelf_next_segment
    RV_ADDR s6, elf_header + 24
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lelf_next_segment
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_BCOND cs, .Lelf_fail
    mv s8, t0
    mv s10, a2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lelf_next_segment
    RV_IMM t1, 1, 32
    mv s5, t1
    RV_ZEXT s5
.Lelf_next_segment:
    RV_IMM t2, 56, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    mv s4, s11
    RV_BCOND ne, .Lelf_segment
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    RV_BCOND eq, .Lelf_fail
    mv a0, s2
    RV_CALL rv_close
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lelf_fail_unopened
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    RV_JUMP .Lelf_return
.Lelf_fail:
    mv a0, s2
    RV_CALL rv_close
.Lelf_fail_unopened:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Lelf_return:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: a0=fd, a1=destination, a2=remaining capacity/required bytes.
 * Output: t0=0 on an exact read, -1 on EOF/error. Retries EINTR and short reads.
 * Scratch: syscall registers, a1/a2. No local stack, allocation or close operation. */
elf_read_exact:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lelf_read_done
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, elf_read_exact
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND le, .Lelf_read_fail
    mv s8, a1
    mv s10, t0
    RV_FLAGS add, 64
    mv a1, s11
    mv s8, a2
    mv s10, t0
    RV_FLAGS sub, 64
    mv a2, s11
    RV_JUMP elf_read_exact
.Lelf_read_done:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
.Lelf_read_fail:
    RV_IMM t1, -1, 64
    mv t0, t1
    ret
.section .bss
.balign 8
elf_header: .skip 64
elf_stat: .skip 128
elf_program_headers: .skip 7168
.section .note.GNU-stack,""
