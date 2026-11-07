/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Bounded output capture. No worker thread, signal emulation, or shell.
 * Inputs x0=exe, x1=argv, x2=environment, x3=input HANDLE or0 (NUL),
 * x4=owned buffer with capacity x5+1, x5=max bytes. Output x9=child status,
 * win_capture_size=produced bytes (<=limit on success, <=limit+1 on failure).
 * Overflow/setup/deadline return127.
 * Buffers remain borrowed. Owns both anonymous pipe handles and optional NUL.
 */
.text
win_capture:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x24, #0
    ARM_ADDR x16, win_capture_buffer
    str x4, [x16]
    ARM_ADDR x16, win_capture_limit
    str x5, [x16]
    ARM_ADDR x16, win_capture_size
    str xzr, [x16]
    add x0, sp, #64
    add x1, sp, #72
    mov x2, #0
    mov x3, #65536
    bl CreatePipe
    cbz w0, .Lwc_fail
    ARM_ADDR x16, win_capture_read
    ldr x10, [sp, #64]
    str x10, [x16]
    ARM_ADDR x16, win_capture_write
    ldr x10, [sp, #72]
    str x10, [x16]
    cbnz x22, 1f
    ARM_ADDR x0, win_null_w
    mov w1, #0x80000000
    mov w2, #3
    mov x3, #0
    mov w4, #3
    mov w5, #128
    mov x6, #0
    bl CreateFileW
    cmn x0, #1
    b.eq .Lwc_pipe_fail
    mov x22, x0
    mov x24, #1
1:  mov x0, x19
    mov x1, x20
    mov x2, x21
    mov x3, x22
    ldr x4, [sp, #72]
    mov x5, #0
    ARM_CALL win_spawn_core
    mov x23, x9
    cbz x24, 2f
    mov x0, x22
    bl CloseHandle
2:  ARM_ADDR x16, win_capture_write
    ldr x0, [x16]
    cbz x0, 3f
    str xzr, [x16]
    bl CloseHandle
3:  ldr x0, [sp, #64]
    bl CloseHandle
    ARM_ADDR x16, win_capture_read
    str xzr, [x16]
    mov x9, x23
    b .Lwc_done
.Lwc_pipe_fail:
    ldr x0, [sp, #72]
    bl CloseHandle
    ldr x0, [sp, #64]
    bl CloseHandle
    ARM_ADDR x16, win_capture_read
    str xzr, [x16]
    ARM_ADDR x16, win_capture_write
    str xzr, [x16]
.Lwc_fail:
    mov x9, #127
.Lwc_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

/* x0=process HANDLE. Return0 once exited with its pipe drained; 1 on overflow,
 * API failure, or deadline. Uses PeekNamedPipe before each synchronous read;
 * waiting cannot block on an empty pipe. Captures at most declared limit+1.
 * Stack96; preserves x19-x24. Deadline starts after process creation.
 */
win_pump_capture:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    ARM_ADDR x16, win_capture_write
    ldr x0, [x16]
    str xzr, [x16]
    bl CloseHandle
    bl GetTickCount64
    mov x20, x0
    ARM_ADDR x16, win_capture_read
    ldr x21, [x16]
    ARM_ADDR x16, win_capture_buffer
    ldr x22, [x16]
    ARM_ADDR x16, win_capture_limit
    ldr x23, [x16]
    mov x24, #0
    str xzr, [sp, #72]          /* completion has not yet been observed */
.Lwpc_loop:
    /* A continuously readable producer must not bypass the deadline. */
    bl GetTickCount64
    sub x0, x0, x20
    ARM_IMM x10, 120000
    cmp x0, x10
    b.hs .Lwpc_bad
    mov x0, x21
    mov x1, #0
    mov x2, #0
    mov x3, #0
    add x4, sp, #64
    mov x5, #0
    bl PeekNamedPipe
    cbnz w0, .Lwpc_available
    bl GetLastError
    cmp w0, #109
    b.eq .Lwpc_empty
    b .Lwpc_bad
.Lwpc_available:
    ldr w10, [sp, #64]
    cbz w10, .Lwpc_empty
    add x2, x23, #1
    sub x2, x2, x24
    cmp x2, x10
    csel x2, x10, x2, hi
    mov x0, x21
    add x1, x22, x24
    add x3, sp, #68
    mov x4, #0
    bl ReadFile
    cbz w0, .Lwpc_bad
    ldr w10, [sp, #68]
    add x24, x24, x10
    cmp x24, x23
    b.hi .Lwpc_bad
    b .Lwpc_loop
.Lwpc_empty:
    /* An empty peek can race a final write followed by process completion.
     * Only an empty/broken observation after completion ends the drain. */
    ldr x10, [sp, #72]
    cbnz x10, .Lwpc_good
.Lwpc_wait:
    mov x0, x19
    mov x1, #0
    bl WaitForSingleObject
    cbz w0, .Lwpc_exited
    cmp w0, #258
    b.ne .Lwpc_bad
    mov w0, #1
    bl Sleep
    b .Lwpc_loop
.Lwpc_exited:
    mov x10, #1
    str x10, [sp, #72]
    b .Lwpc_loop
.Lwpc_good:
    mov x9, #0
    b .Lwpc_done
.Lwpc_bad:
    mov x9, #1
.Lwpc_done:
    ARM_ADDR x16, win_capture_size
    str x24, [x16]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret
.section .rdata,"dr"
.p2align 1
win_null_w: .hword 78,85,76,0
win_dash: .asciz "-"
.section .bss
.p2align 3
win_capture_read: .skip 8
win_capture_write: .skip 8
win_capture_buffer: .skip 8
win_capture_limit: .skip 8
win_capture_size: .skip 8
