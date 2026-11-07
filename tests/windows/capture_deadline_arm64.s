/* Test-only native capture-routine harness with deterministic API shims.
 * CAPTURE_BODY is copied verbatim from the Windows adapter at build time.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
/* CAPTURE_MACROS */
.text
.global _start
_start:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x0, #0x8000
    bl win_pump_capture
    mov x19, #1
    cmp x9, #1
    b.ne harness_output
    ARM_ADDR x10, harness_clocks
    ldr x10, [x10]
    cmp x10, #1
    b.ls harness_output
    ARM_ADDR x10, harness_reads
    ldr x10, [x10]
    cbz x10, harness_output
    cmp x10, #256
    b.hs harness_output
    mov x19, #0
harness_output:
    mov w0, #-11
    bl GetStdHandle
    ARM_ADDR x1, harness_clocks
    mov x2, #16
    ARM_ADDR x3, harness_written
    mov x4, #0
    bl WriteFile
    cbnz w0, 1f
    mov x19, #1
1:  mov x0, x19
    bl ExitProcess
/* CAPTURE_BODY */
GetTickCount64:
    ARM_ADDR x10, harness_clocks
    ldr x11, [x10]
    add x11, x11, #1
    str x11, [x10]
    lsl x0, x11, #10
    ret
PeekNamedPipe:
    mov w10, #1
    str w10, [x4]
    mov w0, #1
    ret
ReadFile:
    strb wzr, [x1]
    mov w10, #1
    str w10, [x3]
    ARM_ADDR x10, harness_reads
    ldr x11, [x10]
    add x11, x11, #1
    str x11, [x10]
    mov w0, #1
    ret
WaitForSingleObject:
    mov w0, #258
    ret
CloseHandle:
    mov w0, #1
    ret
GetLastError:
    mov w0, #109
    ret
Sleep:
    ret
.data
harness_clocks: .quad 0
harness_reads: .quad 0
win_capture_read: .quad 0x8004
win_capture_write: .quad 0x8008
win_capture_buffer: .quad harness_buffer
win_capture_limit: .quad 4096
win_capture_size: .quad 0
.bss
harness_written: .space 4
harness_buffer: .space 4098
