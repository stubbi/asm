/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Bounded thin Mach-O arm64 executable validation.
 * x0: staged path; x1: expected bytes, 32..64 MiB. x9: boolean result.
 * Preserves x19-x24. Owns a 65568-byte header buffer and 128-byte stat buffer.
 * Reads with no-follow/nonblock, checks exact size, commands, target, deployment
 * floor, segment bounds/protections, and file-backed entry. Then verifies the
 * Mach-O signature with the fixed system codesign tool. Never runs the payload.
 * These checks establish format, not publisher identity or harmless behavior.
 */
.text
validate_host_elf:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x20, x0
    mov x21, x1
    cmp x21, #32
    b.lo .Lmac_macho_unopened
    ARM_IMM x11, 67108864
    cmp x21, x11
    b.hi .Lmac_macho_unopened
    ARM_IMM x1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, .Lmac_macho_unopened
    mov x19, x9
    mov x0, x19
    ARM_ADDR x1, mac_macho_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, .Lmac_macho_fail
    ARM_ADDR x16, mac_macho_stat
    ldr x10, [x16, #48]
    cmp x10, x21
    b.ne .Lmac_macho_fail
    ldr w10, [x16, #16]
    and w10, w10, #0xf000
    cmp w10, #0x8000
    b.ne .Lmac_macho_fail
    mov x0, x19
    ARM_ADDR x1, mac_macho_buffer
    mov x2, #32
    ARM_CALL elf_read_exact
    tbnz x9, #63, .Lmac_macho_fail
    ARM_ADDR x22, mac_macho_buffer
    ldr w10, [x22]
    ARM_IMM w11, 0xfeedfacf
    cmp w10, w11
    b.ne .Lmac_macho_fail
    ldr w10, [x22, #4]
    ARM_IMM w11, 0x100000c
    cmp w10, w11
    b.ne .Lmac_macho_fail
    ldr w10, [x22, #8]
    cbnz w10, .Lmac_macho_fail
    ldr w10, [x22, #12]
    cmp w10, #2
    b.ne .Lmac_macho_fail
    ldr w10, [x22, #28]
    cbnz w10, .Lmac_macho_fail
    ldr w10, [x22, #24]
    tbz w10, #21, .Lmac_macho_fail
    tbnz w10, #17, .Lmac_macho_fail
    ldr w24, [x22, #16]
    cbz w24, .Lmac_macho_fail
    cmp w24, #128
    b.hi .Lmac_macho_fail
    ldr w2, [x22, #20]
    cbz w2, .Lmac_macho_fail
    cmp x2, #65536
    b.hi .Lmac_macho_fail
    add x10, x2, #32
    cmp x10, x21
    b.hi .Lmac_macho_fail
    add x22, x22, #32
    add x23, x22, x2
    mov x0, x19
    mov x1, x22
    ARM_CALL elf_read_exact
    tbnz x9, #63, .Lmac_macho_fail
    ARM_ADDR x16, mac_macho_entry
    mov x10, #-1
    str x10, [x16]
    ARM_ADDR x16, mac_macho_platform
    str wzr, [x16]
.Lmac_macho_command:
    add x10, x22, #8
    cmp x10, x23
    b.hi .Lmac_macho_fail
    ldp w3, w4, [x22]
    cmp w4, #8
    b.lo .Lmac_macho_fail
    tst w4, #7
    b.ne .Lmac_macho_fail
    add x5, x22, x4
    cmp x5, x23
    b.hi .Lmac_macho_fail
    cmp w3, #0x19
    b.eq .Lmac_macho_segment
    ARM_IMM w10, 0x80000028
    cmp w3, w10
    b.eq .Lmac_macho_main
    cmp w3, #0x32
    b.eq .Lmac_macho_version
    b .Lmac_macho_next
.Lmac_macho_main:
    cmp w4, #24
    b.ne .Lmac_macho_fail
    ARM_ADDR x16, mac_macho_entry
    ldr x10, [x16]
    cmn x10, #1
    b.ne .Lmac_macho_fail
    ldr x10, [x22, #8]
    str x10, [x16]
    b .Lmac_macho_next
.Lmac_macho_version:
    cmp w4, #24
    b.lo .Lmac_macho_fail
    ARM_ADDR x16, mac_macho_platform
    ldr w10, [x16]
    cbnz w10, .Lmac_macho_fail
    ldr w10, [x22, #8]
    cmp w10, #1
    b.ne .Lmac_macho_fail
    ldr w10, [x22, #12]
    ARM_IMM w11, 0xf0000
    cmp w10, w11
    b.hi .Lmac_macho_fail
    ldr w10, [x22, #20]
    lsl x10, x10, #3
    add x10, x10, #24
    cmp x10, x4
    b.ne .Lmac_macho_fail
    mov w10, #1
    str w10, [x16]
    b .Lmac_macho_next
.Lmac_macho_segment:
    cmp w4, #72
    b.lo .Lmac_macho_fail
    ldr w10, [x22, #64]
    mov x11, #80
    mul x10, x10, x11
    add x10, x10, #72
    cmp x10, x4
    b.ne .Lmac_macho_fail
    ldr x10, [x22, #48]
    ldr x11, [x22, #32]
    cmp x10, x11
    b.hi .Lmac_macho_fail
    ldr x11, [x22, #40]
    adds x11, x11, x10
    b.cs .Lmac_macho_fail
    cmp x11, x21
    b.hi .Lmac_macho_fail
    ldp w10, w11, [x22, #56]
    orr w12, w10, w11
    tst w12, #0xfffffff8
    b.ne .Lmac_macho_fail
    and w12, w10, w11
    cmp w12, w11
    b.ne .Lmac_macho_fail
    and w11, w11, #6
    cmp w11, #6
    b.eq .Lmac_macho_fail
.Lmac_macho_next:
    mov x22, x5
    subs w24, w24, #1
    b.ne .Lmac_macho_command
    cmp x22, x23
    b.ne .Lmac_macho_fail
    ARM_ADDR x16, mac_macho_platform
    ldr w10, [x16]
    cbz w10, .Lmac_macho_fail
    ARM_ADDR x16, mac_macho_entry
    ldr x6, [x16]
    ARM_ADDR x22, mac_macho_buffer
    sub x10, x23, x22
    cmp x6, x10
    b.lo .Lmac_macho_fail
    ldr w24, [x22, #16]
    add x22, x22, #32
.Lmac_macho_entry_check:
    ldp w3, w4, [x22]
    cmp w3, #0x19
    b.ne .Lmac_macho_entry_next
    ldr w10, [x22, #60]
    tbz w10, #2, .Lmac_macho_entry_next
    ldr x10, [x22, #40]
    cmp x6, x10
    b.lo .Lmac_macho_entry_next
    ldr x11, [x22, #48]
    add x11, x11, x10
    cmp x6, x11
    b.lo .Lmac_macho_valid
.Lmac_macho_entry_next:
    add x22, x22, x4
    subs w24, w24, #1
    b.ne .Lmac_macho_entry_check
    b .Lmac_macho_fail
.Lmac_macho_valid:
    mov x0, x19
    ARM_CALL arm_close
    tbnz x9, #63, .Lmac_macho_unopened
    ARM_ADDR x16, mac_codesign_argv
    str x20, [x16, #24]
    ARM_ADDR x0, mac_codesign_path
    mov x1, x16
    ARM_CALL mac_codesign_wait
    cmp x9, #0
    cset w9, eq
    b .Lmac_macho_return
.Lmac_macho_fail:
    mov x0, x19
    ARM_CALL arm_close
.Lmac_macho_unopened:
    mov x9, #0
.Lmac_macho_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.data
mac_codesign_path: .asciz "/usr/bin/codesign"
mac_codesign_verify: .asciz "--verify"
mac_codesign_strict: .asciz "--strict"
.p2align 3
mac_codesign_argv: .quad mac_codesign_path, mac_codesign_verify, mac_codesign_strict, 0, 0
.zerofill __DATA,__bss,mac_macho_buffer,65568,3
.zerofill __DATA,__bss,mac_macho_stat,128,3
.zerofill __DATA,__bss,mac_macho_entry,8,3
.zerofill __DATA,__bss,mac_macho_platform,4,3
.text
elf_read_exact:
    tst x2, x2
    b.eq .Lelf_read_done
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq elf_read_exact
    tst x9, x9
    b.le .Lelf_read_fail
    adds x1, x1, x9
    subs x2, x2, x9
    b elf_read_exact
.Lelf_read_done:
    eor w9, w9, w9
    tst w9, w9
    ret
.Lelf_read_fail:
    ARM_IMM x10, -1
    mov x9, x10
    ret

/* Run the fixed signature verifier quietly with a clean environment and a
 * 15-second child alarm. Output x9=0 only for a successful child exit.
 * Preserves x19; other scratch follows the shared internal ABI.
 */
.text
mac_codesign_wait:
    ARM_SAVE x19
    ARM_CALL arm_fork
    tbnz x9, #63, .Lmac_sign_bad
    cbz x9, .Lmac_sign_child
    mov x19, x9
.Lmac_sign_wait:
    mov x0, x19
    ARM_ADDR x1, mac_codesign_status
    mov x2, #0
    mov x6, #0
    ARM_CALL arm_wait4
    cmn x9, #4
    b.eq .Lmac_sign_wait
    tbnz x9, #63, .Lmac_sign_bad
    ARM_ADDR x16, mac_codesign_status
    ldr w10, [x16]
    cmp w10, #0
    cset w9, ne
    b .Lmac_sign_return
.Lmac_sign_child:
    ARM_ADDR x0, mac_codesign_null
    mov x1, #1
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, .Lmac_sign_child_bad
    mov x19, x9
    mov x0, x19
    mov x1, #1
    ARM_CALL arm_dup2
    tbnz x9, #63, .Lmac_sign_child_bad
    mov x0, x19
    mov x1, #2
    ARM_CALL arm_dup2
    tbnz x9, #63, .Lmac_sign_child_bad
    cmp x19, #2
    b.ls .Lmac_sign_alarm
    mov x0, x19
    ARM_CALL arm_close
.Lmac_sign_alarm:
    mov x0, #14
    mov x1, #0
    ARM_CALL arm_rt_sigaction
    tbnz x9, #63, .Lmac_sign_child_bad
    mov x0, #1
    ARM_ADDR x1, mac_codesign_alarm_mask
    mov x2, #0
    ARM_CALL arm_rt_sigprocmask
    tbnz x9, #63, .Lmac_sign_child_bad
    mov x0, #15
    ARM_CALL arm_alarm
    tbnz x9, #63, .Lmac_sign_child_bad
    ARM_ADDR x0, mac_codesign_path
    ARM_ADDR x1, mac_codesign_argv
    ARM_ADDR x2, mac_digest_environment
    ARM_CALL arm_execve
.Lmac_sign_child_bad:
    mov x0, #127
    b arm_exit
.Lmac_sign_bad:
    mov x9, #1
.Lmac_sign_return:
    ARM_RESTORE x19
    ret
.data
mac_codesign_null: .asciz "/dev/null"
.p2align 3
mac_codesign_alarm_mask: .quad 1 << 13
.zerofill __DATA,__bss,mac_codesign_status,8,3
