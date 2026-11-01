/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native metadata guard-page and internal-ABI harness. No network operations.
 * The Python test can set ARM_TEST_PAGE_SIZE to its native page size.
 */
.include "cli/aarch64/platform.inc"
.ifndef ARM_TEST_PAGE_SIZE
.equ ARM_TEST_PAGE_SIZE, 4096
.endif
.equ ARM_HARNESS_MAP_BYTES, 1048576 + 2 * ARM_TEST_PAGE_SIZE
.equ ARM_HARNESS_LAST_PAGE, 1048576 + ARM_TEST_PAGE_SIZE

.global _start
.extern self_parse_release, self_source_commit
.text
_start:
    // Forward string loops do not use a direction flag.
    mov x16, sp
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne harness_error
    mov x16, sp
    add x16, x16, #16
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, harness_row + 8
    str x9, [x16]
    mov x16, sp
    add x16, x16, #24
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, harness_row + 32
    str x9, [x16]
    mov x16, sp
    add x16, x16, #32
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, harness_row + 48
    str x9, [x16]
    eor w21, w21, w21
    tst w21, w21
harness_read:
    ARM_IMM x11, 1048577
    cmp x21, x11
    b.hs harness_read_done
    eor w0, w0, w0
    tst w0, w0
    ARM_ADDR x16, harness_input
    mov x1, x16
    adds x1, x1, x21
    ARM_IMM w10, 1048577
    mov w2, w10
    subs x2, x2, x21
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq harness_read
    tst x9, x9
    b.mi harness_error
    b.eq harness_read_done
    adds x21, x21, x9
    b harness_read
harness_read_done:
    ARM_ADDR x16, harness_length
    str x21, [x16]
    ARM_ADDR x16, harness_input
    mov x0, x16
    ARM_IMM x11, 1048576
    cmp x21, x11
    b.hi harness_call
    eor w0, w0, w0
    tst w0, w0
    ARM_IMM w10, ARM_HARNESS_MAP_BYTES
    mov w1, w10
    ARM_IMM w10, 3
    mov w2, w10
    ARM_IMM w10, 34
    mov w6, w10
    ARM_IMM x10, -1
    mov x4, x10
    eor w5, w5, w5
    tst w5, w5
    ARM_CALL arm_mmap
    ARM_IMM x11, -4095
    cmp x9, x11
    b.hs harness_error
    mov x23, x9
    mov x0, x23
    ARM_IMM w10, ARM_TEST_PAGE_SIZE
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_mprotect
    tst x9, x9
    b.mi harness_error
    mov x16, x23
    ARM_IMM x17, +ARM_HARNESS_LAST_PAGE
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w10, ARM_TEST_PAGE_SIZE
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_mprotect
    tst x9, x9
    b.mi harness_error
    mov x16, x23
    ARM_IMM x17, +ARM_HARNESS_LAST_PAGE
    add x16, x16, x17
    mov x0, x16
    subs x0, x0, x21
    ARM_ADDR x16, harness_start
    str x0, [x16]
    ARM_ADDR x16, harness_input
    mov x1, x16
    mov x3, x21
    cbz x3, .Lport_self_update_metadata_harness_1_end
.Lport_self_update_metadata_harness_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_self_update_metadata_harness_1
.Lport_self_update_metadata_harness_1_end:
    mov x16, x23
    ARM_IMM x17, +ARM_TEST_PAGE_SIZE
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w10, 1048576
    mov w1, w10
    ARM_IMM w10, 1
    mov w2, w10
    ARM_CALL arm_mprotect
    tst x9, x9
    b.mi harness_error
    ARM_ADDR x16, harness_start
    ldr x10, [x16]
    mov x0, x10
harness_call:
    ARM_ADDR x16, harness_start
    str x0, [x16]
    ARM_ADDR x16, self_source_commit
    mov x0, x16
    ARM_IMM w10, 88
    mov w9, w10
    ARM_IMM w10, 41
    mov w3, w10
    cbz x3, .Lport_self_update_metadata_harness_2_end
.Lport_self_update_metadata_harness_2:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_self_update_metadata_harness_2
.Lport_self_update_metadata_harness_2_end:
    ARM_ADDR x16, harness_start
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, harness_length
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, harness_row
    mov x2, x16
    ARM_IMM w10, 4369
    mov w19, w10
    ARM_IMM w10, 8738
    mov w20, w10
    ARM_IMM w10, 13107
    mov w21, w10
    ARM_IMM w10, 17476
    mov w22, w10
    ARM_IMM w10, 21845
    mov w23, w10
    ARM_IMM w10, 26214
    mov w24, w10
    mov x10, sp
    ARM_ADDR x16, harness_stack
    str x10, [x16]
    ARM_CALL self_parse_release
    mov x10, sp
    ARM_ADDR x16, harness_stack
    ldr x11, [x16]
    cmp x10, x11
    b.ne harness_error
    ARM_IMM x11, 4369
    cmp x19, x11
    b.ne harness_error
    ARM_IMM x11, 8738
    cmp x20, x11
    b.ne harness_error
    ARM_IMM x11, 13107
    cmp x21, x11
    b.ne harness_error
    ARM_IMM x11, 17476
    cmp x22, x11
    b.ne harness_error
    ARM_IMM x11, 21845
    cmp x23, x11
    b.ne harness_error
    ARM_IMM x11, 26214
    cmp x24, x11
    b.ne harness_error
    tst w9, w9
    b.eq harness_success
    ARM_IMM w11, 1
    cmp w9, w11
    b.ne harness_error
    ARM_ADDR x16, self_source_commit
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
harness_cleared:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne harness_error
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 41
    cmp w3, w11
    b.lo harness_cleared
    ARM_IMM w10, 1
    mov w0, w10
    b harness_exit
harness_success:
    ARM_ADDR x16, self_source_commit + 40
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne harness_error
    ARM_IMM w10, 1
    mov w0, w10
    ARM_ADDR x16, self_source_commit
    mov x1, x16
    ARM_IMM w10, 40
    mov w2, w10
    ARM_CALL arm_write
    ARM_IMM x11, 40
    cmp x9, x11
    b.ne harness_error
    eor w0, w0, w0
    tst w0, w0
    b harness_exit
harness_error:
    ARM_IMM w10, 3
    mov w0, w10
harness_exit:
    ARM_CALL arm_exit
.section .rodata
harness_package: .asciz "stubbi/asm"
harness_target: .asciz "aarch64-linux"
harness_kind: .asciz "executable"
harness_unused: .asciz ""
.data
harness_row:
    .quad harness_package, 0, harness_target, harness_kind
    .quad 0, harness_unused, 0, harness_unused
.bss
.balign 8
harness_length: .skip 8
harness_start: .skip 8
harness_stack: .skip 8
harness_input: .skip 1048577
.section .note.GNU-stack,"",%progbits

.include "cli/aarch64/self_update_metadata.s"
.include "cli/aarch64/platform.s"
