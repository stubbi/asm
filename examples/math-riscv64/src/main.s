/* SPDX-License-Identifier: MIT
 * RV64I Linux demonstration. No C runtime or global-pointer setup is needed.
 * _start consumes no arguments. It exits with status 0 or 1 and never returns.
 * It calls asm_u64_min with the process stack's required 16-byte alignment.
 */
.option norelax
.include "src/min.s"

.equ SYS_WRITE, 64
.equ SYS_EXIT, 93
.equ STDOUT, 1
.equ STDERR, 2
.equ EINTR, 4
.equ MESSAGE_LENGTH, 17
.equ WRITE_ERROR_LENGTH, 69

/* LI uses absolute constants. These checks bind each length to its bytes. */
.section .rodata
message:
    .ascii "min(12, 37) = 12\n"
message_end:
.if message_end - message != MESSAGE_LENGTH
    .error "MESSAGE_LENGTH does not match the message bytes"
.endif
write_error:
    .ascii "math: write failed.\nCheck standard output and run the example again.\n"
write_error_end:
.if write_error_end - write_error != WRITE_ERROR_LENGTH
    .error "WRITE_ERROR_LENGTH does not match the diagnostic bytes"
.endif

.section .text
.global _start
.type _start, @function
_start:
    li a0, 12
    li a1, 37
    call asm_u64_min
    li t0, 12
    bne a0, t0, .Lfailure

    li a0, STDOUT
    la a1, message
    li a2, MESSAGE_LENGTH
    call .Lwrite_all
    bnez a0, .Lwrite_failure
    li a0, 0
    li a7, SYS_EXIT
    ecall

.Lwrite_failure:
    li a0, STDERR
    la a1, write_error
    li a2, WRITE_ERROR_LENGTH
    call .Lwrite_all
.Lfailure:
    li a0, 1
    li a7, SYS_EXIT
    ecall
.size _start, .-_start

/* Write a caller-owned byte range without modifying it.
 * Input: a0 = descriptor; a1 = readable buffer; a2 = byte length, including 0.
 * Output: a0 = 0 on complete write, or -1 on error or no progress.
 * Changed registers: a0-a2, a7, t0-t3. Other registers remain unchanged.
 * Stack: unchanged; no local storage. ra supplies the return address.
 * Memory: reads at most a2 bytes from a1 through Linux write (system call 64).
 * Linux preserves the loop registers across ecall and returns -errno in a0.
 * EINTR retries the pending range. Short writes advance within that range.
 * An error can follow partial output. No caller-owned memory is modified.
 */
.type .Lwrite_all, @function
.Lwrite_all:
    mv t0, a0
    mv t1, a1
    mv t2, a2
    beqz t2, .Lwrite_done
.Lwrite_next:
    mv a0, t0
    mv a1, t1
    mv a2, t2
    li a7, SYS_WRITE
    ecall
    li t3, -EINTR
    beq a0, t3, .Lwrite_next
    blez a0, .Lwrite_error
    bgtu a0, t2, .Lwrite_error
    add t1, t1, a0
    sub t2, t2, a0
    bnez t2, .Lwrite_next
.Lwrite_done:
    li a0, 0
    ret
.Lwrite_error:
    li a0, -1
    ret
.size .Lwrite_all, .-.Lwrite_all

.section .note.GNU-stack,"",@progbits
