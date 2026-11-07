/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only controlled source/format fixtures; never included in CLI. */
.text
.global _main
_main:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    ARM_ADDR x19, source_cases
1:  ldp x0, x20, [x19], #16
    cbz x0, 2f
    ARM_CALL win_valid_source
    cmp x9, x20
    b.ne contracts_fail
    b 1b
2:  ARM_ADDR x19, target_cases
3:  ldp x0, x20, [x19], #16
    cbz x0, 4f
    mov x1, #1234
    ARM_CALL win_pub_validate_pe
    cmp x9, x20
    b.ne contracts_fail
    b 3b
4:  mov w0, #0
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
contracts_fail:
    mov w0, #95
    b _exit
win_utf16:
    mov x9, #0
1:  ldrb w10, [x0, x9]
    strh w10, [x1, x9, lsl #1]
    add x9, x9, #1
    cbnz w10, 1b
    ret
pub_validate_elf:
    cmp x1, #1234
    b.ne contracts_fail
    mov w9, #10
    ret
validate_host_elf:
    ARM_ADDR x10, registry_temp_payload
    cmp x0, x10
    b.ne contracts_fail
    cmp x1, #1234
    b.ne contracts_fail
    mov w9, #1
    ret
.data
registry_host: .asciz "aarch64-windows"
registry_x86_64: .asciz "x86_64-linux"
registry_aarch64: .asciz "aarch64-linux"
registry_riscv64: .asciz "riscv64-linux"
foreign_windows: .asciz "x86_64-windows"
foreign_mac: .asciz "aarch64-macos"
foreign_x86_mac: .asciz "x86_64-macos"
unknown_target: .asciz "unknown"
registry_temp_payload: .asciz "fixture.exe"
source_good: .asciz "src/main.s"
source_spaces: .asciz "source files/main.s"
source_drive: .asciz "C:/outside.s"
source_relative_drive: .asciz "C:outside.s"
source_stream: .asciz "src/main.s:stream"
source_reserved: .asciz "src/NUL.s"
source_device: .asciz "src/COM1.txt/main.s"
source_dot: .asciz "src./main.s"
source_space: .asciz "src /main.s"
source_response: .asciz "src/@options.s"
source_parent: .asciz "../outside.s"
source_backslash: .asciz "src\\other.s"
.p2align 3
source_cases:
    .quad source_good,1, source_spaces,1, source_drive,0, source_relative_drive,0
    .quad source_stream,0, source_reserved,0, source_device,0, source_dot,0
    .quad source_space,0, source_response,0, source_parent,0, source_backslash,0, 0,0
target_cases:
    .quad registry_host,0, registry_x86_64,10, registry_aarch64,10, registry_riscv64,10
    .quad foreign_windows,1, foreign_mac,1, foreign_x86_mac,1, unknown_target,1, 0,0
win_path_w: .space 8192
