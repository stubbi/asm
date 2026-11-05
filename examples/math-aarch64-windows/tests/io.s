// SPDX-License-Identifier: MIT
// Test the actual write routine with deterministic Windows API boundary results.
// Cases: complete, short, NULL, invalid, failed, zero-progress, oversized write.
.set MATH_IO_TEST, 1
.include "src/main.s"

.text
.global mainCRTStartup
.seh_proc mainCRTStartup
// Input: none. Output: ExitProcess(0) on pass, ExitProcess(1) on failure.
// Clobbers volatile registers and flags. Stack: 16 bytes, 16-byte aligned.
mainCRTStartup:
    stp x29, x30, [sp, #-16]!
    .seh_save_fplr_x 16
    mov x29, sp
    .seh_set_fp
    .seh_endprologue
test_next:
    adrp x9, completed
    str wzr, [x9, :lo12:completed]
    adrp x9, calls
    str wzr, [x9, :lo12:calls]
    bl math_write_stdout
    adrp x9, scenario
    ldr w9, [x9, :lo12:scenario]
    cmp w9, #2
    cset w10, hs
    cmp w0, w10
    b.ne test_failed
    adrp x10, expected_calls
    add x10, x10, :lo12:expected_calls
    ldr w10, [x10, w9, uxtw #2]
    adrp x11, calls
    ldr w11, [x11, :lo12:calls]
    cmp w10, w11
    b.ne test_failed
    adrp x10, boundary_failed
    ldr w10, [x10, :lo12:boundary_failed]
    cbnz w10, test_failed
    add w9, w9, #1
    adrp x10, scenario
    str w9, [x10, :lo12:scenario]
    cmp w9, #7
    b.lo test_next
    mov w0, #0
    b test_exit
test_failed:
    mov w0, #1
test_exit:
    adrp x16, __imp_ExitProcess
    ldr x16, [x16, :lo12:__imp_ExitProcess]
    blr x16
    brk #0
.seh_endproc

// Windows ARM64 API fixture. Preserves x18-x30 and uses no stack.
// Returns the configured handle; rejects an incorrect selector or alignment.
fixture_get_handle:
    mov x9, sp
    tst x9, #15
    b.ne boundary_bad
    mov w9, #-11
    cmp w0, w9
    b.ne boundary_bad
    adrp x9, scenario
    ldr w9, [x9, :lo12:scenario]
    cmp w9, #2
    b.eq null_handle
    cmp w9, #3
    b.eq invalid_handle
    mov w0, #0x1234
    ret
null_handle:
    mov w0, #0
    ret
invalid_handle:
    mov x0, #-1
    ret

// Inputs use WriteFile's ABI. Checks the actual buffer, remaining length,
// handle, alignment, and NULL OVERLAPPED. Writes only to the supplied DWORD.
// Clobbers x0-x17 and flags; preserves x18-x30 and uses no stack.
fixture_write_file:
    mov x9, sp
    tst x9, #15
    b.ne boundary_bad
    mov w9, #0x1234
    cmp x0, x9
    b.ne boundary_bad
    cbnz x4, boundary_bad
    adrp x9, calls
    ldr w10, [x9, :lo12:calls]
    add w10, w10, #1
    str w10, [x9, :lo12:calls]
    adrp x9, completed
    ldr w10, [x9, :lo12:completed]
    adrp x11, message
    add x11, x11, :lo12:message
    add x11, x11, x10
    cmp x1, x11
    b.ne boundary_bad
    mov w11, #17
    sub w11, w11, w10
    cmp w2, w11
    b.ne boundary_bad
    adrp x11, expected_message
    add x11, x11, :lo12:expected_message
    add x11, x11, x10
    mov w12, #0
check_bytes:
    ldrb w13, [x1, x12]
    ldrb w14, [x11, x12]
    cmp w13, w14
    b.ne boundary_bad
    add w12, w12, #1
    cmp w12, w2
    b.lo check_bytes
    adrp x11, scenario
    ldr w11, [x11, :lo12:scenario]
    cmp w11, #4
    b.eq fixture_failure
    cmp w11, #5
    b.eq fixture_zero
    cmp w11, #6
    b.eq fixture_oversized
    cmp w11, #1
    b.ne fixture_complete
    cbnz w10, fixture_complete
    mov w2, #5
fixture_complete:
    str w2, [x3]
    add w10, w10, w2
    str w10, [x9, :lo12:completed]
    mov w0, #1
    ret
fixture_zero:
    str wzr, [x3]
    mov w0, #1
    ret
fixture_oversized:
    mov w0, #18
    str w0, [x3]
    mov w0, #1
    ret
fixture_failure:
    str wzr, [x3]
    mov w0, #0
    ret
boundary_bad:
    adrp x9, boundary_failed
    mov w10, #1
    str w10, [x9, :lo12:boundary_failed]
    mov w0, #0
    ret

.section .rdata,"dr"
expected_message: .ascii "min(12, 37) = 12\n"
.p2align 2
expected_calls: .long 1, 2, 0, 0, 1, 1, 1
.data
.p2align 3
__imp_GetStdHandle: .quad fixture_get_handle
__imp_WriteFile: .quad fixture_write_file
scenario: .long 0
completed: .long 0
calls: .long 0
boundary_failed: .long 0
