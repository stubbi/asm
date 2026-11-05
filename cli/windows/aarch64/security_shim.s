/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Controlled policy API fixtures. Never included in shipped assembly. */
.text
.global _main
_main:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    ARM_ADDR x10, policy_user
    ARM_ADDR x11, win_token_user
    str x10, [x11]
    ARM_ADDR x19, policy_cases
    mov x20, #11
1:  ARM_ADDR x10, policy_active
    str x19, [x10]
    ldr w11, [x19, #16]
    ARM_ADDR x10, win_token_elevation
    str w11, [x10]
    ARM_ADDR x21, policy_stat
    ldr w11, [x19, #20]
    str w11, [x21, #ARM_STAT_MODE]
    mov x0, #123
    mov x1, x21
    ARM_CALL win_security_stat
    cbnz x9, policy_fail
    ldr w10, [x21, #ARM_STAT_UID]
    ldr w11, [x19, #24]
    cmp w10, w11
    b.ne policy_fail
    ldr w10, [x21, #ARM_STAT_MODE]
    mov w11, #18
    and w10, w10, w11
    ldr w11, [x19, #28]
    cmp w10, w11
    b.ne policy_fail
    add x19, x19, #32
    subs x20, x20, #1
    b.ne 1b
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    mov w0, #0
    ret
policy_fail:
    mov w0, #95
    b _exit
GetSecurityInfo:
    ARM_ADDR x10, policy_active
    ldr x10, [x10]
    ldr x11, [x10]
    str x11, [x3]
    ARM_ADDR x11, policy_acl
    str x11, [x5]
    str x11, [x7]
    mov w0, #0
    ret
IsValidAcl:
IsValidSid:
    mov w0, #1
    ret
GetAce:
    cbnz x1, policy_fail
    ARM_ADDR x10, policy_active
    ldr x10, [x10]
    ldr x11, [x10, #8]
    str x11, [x2]
    mov w0, #1
    ret
LocalFree:
    mov x0, #0
    ret
EqualSid:
    ldrb w10, [x0, #1]
    lsl x10, x10, #2
    add x10, x10, #8
    mov x11, #0
1:  ldrb w12, [x0, x11]
    ldrb w13, [x1, x11]
    cmp w12, w13
    b.ne 2f
    add x11, x11, #1
    cmp x11, x10
    b.lo 1b
    mov w0, #1
    ret
2:  mov w0, #0
    ret
.data
.p2align 3
policy_user: .byte 1,1,0,0,0,0,0,5
    .long 1000
policy_foreign: .byte 1,1,0,0,0,0,0,5
    .long 1001
policy_ow_ace: .byte 0,0
    .hword 20
    .long 0x1f01ff
    .byte 1,1,0,0,0,0,0,3
    .long 4
policy_add_ace: .byte 0,0
    .hword 20
    .long 4
    .byte 1,1,0,0,0,0,0,5
    .long 1001
policy_write_ace: .byte 0,0
    .hword 20
    .long 2
    .byte 1,1,0,0,0,0,0,5
    .long 1001
policy_inherit_ace: .byte 0,8
    .hword 20
    .long 0x1f01ff
    .byte 1,1,0,0,0,0,0,5
    .long 1001
policy_acl: .byte 2,0
    .hword 28,1,0
.p2align 3
policy_cases:
    .quad win_sid_admin,policy_ow_ace
    .long 1,0x41c0,0,0
    .quad policy_user,policy_ow_ace
    .long 0,0x81c0,1,0
    .quad win_sid_admin,policy_ow_ace
    .long 1,0x81c0,1,0
    .quad win_sid_admin,policy_ow_ace
    .long 0,0x41c0,0,0
    .quad win_sid_installer,policy_ow_ace
    .long 0,0x41c0,0,0
    .quad win_sid_system,policy_ow_ace
    .long 0,0x41c0,0,0
    .quad policy_foreign,policy_ow_ace
    .long 0,0x81c0,2,18
    .quad win_sid_system,policy_add_ace
    .long 0,0x41c0,0,0
    .quad win_sid_system,policy_write_ace
    .long 0,0x41c0,0,18
    .quad policy_user,policy_write_ace
    .long 0,0x81c0,1,18
    .quad policy_user,policy_inherit_ace
    .long 0,0x81c0,1,0
policy_active: .quad 0
policy_stat: .space 128
