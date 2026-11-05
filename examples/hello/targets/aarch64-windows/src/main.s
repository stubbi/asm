// SPDX-License-Identifier: MIT
.equ STD_OUTPUT_HANDLE, -11
.equ WRITE_FRAME, 48
.equ HANDLE, 16
.equ NEXT_BYTE, 24
.equ REMAINING, 32
.equ WRITTEN, 36

.text
.ifndef HELLO_TEST
.global mainCRTStartup
.seh_proc mainCRTStartup
// Process entry. No arguments are used. ExitProcess receives status 0 or 1.
// Stack: 16 bytes; preserves x29/x30 and keeps SP 16-byte aligned.
mainCRTStartup:
    stp x29, x30, [sp, #-16]!
    .seh_save_fplr_x 16
    mov x29, sp
    .seh_set_fp
    .seh_endprologue
    bl hello_write_stdout
    adrp x16, __imp_ExitProcess
    ldr x16, [x16, :lo12:__imp_ExitProcess]
    blr x16
    brk #0
.seh_endproc
.endif

.global hello_write_stdout
.seh_proc hello_write_stdout
// Input: none. Output: w0 = 0 for all 16 bytes written; w0 = 1 on failure.
// Clobbers x0-x17, flags; preserves x18-x30. Stack: 48 bytes, 16-byte aligned.
// The read-only message owns 16 bytes. Stack locals remain private to this call.
// Uses synchronous GetStdHandle/WriteFile; rejects NULL and INVALID_HANDLE_VALUE.
hello_write_stdout:
    stp x29, x30, [sp, #-WRITE_FRAME]!
    .seh_save_fplr_x WRITE_FRAME
    mov x29, sp
    .seh_set_fp
    .seh_endprologue
    mov w0, #STD_OUTPUT_HANDLE
    adrp x16, __imp_GetStdHandle
    ldr x16, [x16, :lo12:__imp_GetStdHandle]
    blr x16
    cbz x0, write_failed
    cmn x0, #1
    b.eq write_failed
    str x0, [sp, #HANDLE]
    adrp x1, message
    add x1, x1, :lo12:message
    str x1, [sp, #NEXT_BYTE]
    mov w2, #message_len
    str w2, [sp, #REMAINING]
write_more:
    ldr x0, [sp, #HANDLE]
    ldr x1, [sp, #NEXT_BYTE]
    ldr w2, [sp, #REMAINING]
    add x3, sp, #WRITTEN
    str wzr, [x3]
    mov x4, #0
    adrp x16, __imp_WriteFile
    ldr x16, [x16, :lo12:__imp_WriteFile]
    blr x16
    cbz w0, write_failed
    ldr w0, [sp, #WRITTEN]
    cbz w0, write_failed
    ldr w2, [sp, #REMAINING]
    cmp w0, w2
    b.hi write_failed
    sub w2, w2, w0
    str w2, [sp, #REMAINING]
    ldr x1, [sp, #NEXT_BYTE]
    add x1, x1, x0
    str x1, [sp, #NEXT_BYTE]
    cbnz w2, write_more
    mov w0, #0
    b write_return
write_failed:
    mov w0, #1
write_return:
    .seh_startepilogue
    ldp x29, x30, [sp], #WRITE_FRAME
    .seh_save_fplr_x WRITE_FRAME
    .seh_endepilogue
    ret
.seh_endproc

.section .rdata,"dr"
message:
    .ascii "Hello from asm!\n"
.equ message_len, . - message
