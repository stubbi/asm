/* SPDX-License-Identifier: MIT
 * Input: C main arguments are ignored. Output: w0=0 after all bytes, else 1.
 * ABI: Apple ARM64, libSystem write/__error. Stack: 32 bytes, aligned to 16.
 * Preserves x19-x29 and SP; x18 is reserved and never used.
 * Changes caller-saved registers and flags through libSystem calls.
 * Owns no buffers. Lmessage is immutable; x19/x20 track its remaining span.
 * Short writes advance the span; EINTR retries; zero/error writes fail.
 */
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _main
_main:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    adrp x19, Lmessage@PAGE
    add x19, x19, Lmessage@PAGEOFF
    mov x20, #16
Lwrite:
    mov x0, #1
    mov x1, x19
    mov x2, x20
    bl _write
    cmp x0, #0
    b.gt Lprogress
    b.eq Lfailure
    cmn x0, #1
    b.ne Lfailure
    bl ___error
    ldr w0, [x0]
    cmp w0, #4
    b.eq Lwrite
    b Lfailure
Lprogress:
    cmp x0, x20
    b.hi Lfailure
    add x19, x19, x0
    subs x20, x20, x0
    b.ne Lwrite
    mov w0, #0
    b Lreturn
Lfailure:
    mov w0, #1
Lreturn:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
.section __TEXT,__cstring,cstring_literals
Lmessage: .asciz "Hello from asm!\n"
.subsections_via_symbols
