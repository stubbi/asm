.include "src/min.s"

.equ EINTR, 4

.text
.p2align 2
.global _main
/* Input: Apple main call frame; arguments are unused.
 * Output: status 0 after the complete message; status 1 on failure.
 * Changed: caller-saved registers and NZCV through libSystem calls.
 * Stack: 32 bytes; saves x19-x20 and the x29-x30 frame record.
 * Memory: the fixed message is read-only. No caller-owned buffers.
 * Calls: Apple arm64 helper, libSystem write, and __error for errno.
 * x18 is reserved by Apple and is not accessed here.
 */
_main:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x0, #12
    mov x1, #37
    bl _asm_u64_min
    cmp x0, #12
    b.ne Lfailure
    adrp x19, message@PAGE
    add x19, x19, message@PAGEOFF
    mov x20, #message_len
Lwrite:
    mov x0, #1
    mov x1, x19
    mov x2, x20
    bl _write
    cmn x0, #1
    b.eq Lwrite_error
    tbnz x0, #63, Lfailure
    cbz x0, Lfailure
    cmp x0, x20
    b.hi Lfailure
    add x19, x19, x0
    sub x20, x20, x0
    cbnz x20, Lwrite
    mov x0, #0
    b Lreturn
Lwrite_error:
    bl ___error
    ldr w9, [x0]
    cmp w9, #EINTR
    b.eq Lwrite
Lfailure:
    mov x0, #1
Lreturn:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.section __TEXT,__const
message: .ascii "min(12, 37) = 12\n"
.equ message_len, .-message
.subsections_via_symbols
