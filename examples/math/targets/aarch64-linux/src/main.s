.include "targets/aarch64-linux/src/min.s"

.equ SYS_WRITE, 64
.equ SYS_EXIT, 93
.equ EINTR, 4

.section .text
.p2align 2
.global _start
/* Input: Linux process entry with a 16-byte aligned stack.
 * Output: status 0 after the complete message; status 1 on failure.
 * Changed: x0-x2, x8, x19-x20, x30, and NZCV. No local stack storage.
 * Memory: the fixed message is read-only. No caller-owned buffers.
 * Calls: AAPCS64 helper; Linux AArch64 write and exit system calls.
 */
_start:
    mov x0, #12
    mov x1, #37
    bl asm_u64_min
    cmp x0, #12
    b.ne .Lfailure
    adrp x19, message
    add x19, x19, :lo12:message
    mov x20, #message_len
.Lwrite:
    mov x0, #1
    mov x1, x19
    mov x2, x20
    mov x8, #SYS_WRITE
    svc #0
    cmn x0, #EINTR
    b.eq .Lwrite
    tbnz x0, #63, .Lfailure
    cbz x0, .Lfailure
    cmp x0, x20
    b.hi .Lfailure
    add x19, x19, x0
    sub x20, x20, x0
    cbnz x20, .Lwrite
    mov x0, #0
    b .Lexit
.Lfailure:
    mov x0, #1
.Lexit:
    mov x8, #SYS_EXIT
    svc #0

.section .rodata
message: .ascii "min(12, 37) = 12\n"
.equ message_len, .-message
.section .note.GNU-stack,"",%progbits
