/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Windows owner and DACL policy. A POSIX-style mode is only an internal
 * summary of observed Windows grants. It never substitutes for a DACL check.
 */
.text
/* Acquire current token user and construct a protected DACL granting full
 * control to that user, SYSTEM, and Administrators. Fail closed on any error.
 * Buffers are private, process-lifetime; max token user=1024, ACL=2048 bytes.
 */
win_security_init:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    mov x0, #-1
    mov w1, #8
    add x2, sp, #16
    bl OpenProcessToken
    cbz w0, .Lwsi_bad
    ldr x0, [sp, #16]
    mov w1, #1
    ARM_ADDR x2, win_token_user
    mov w3, #1024
    add x4, sp, #24
    bl GetTokenInformation
    str w0, [sp, #32]
    ldr x0, [sp, #16]
    bl CloseHandle
    ldr w10, [sp, #32]
    cbz w10, .Lwsi_bad
    ARM_ADDR x0, win_private_acl
    mov w1, #2048
    mov w2, #2
    bl InitializeAcl
    cbz w0, .Lwsi_bad
    ARM_ADDR x16, win_token_user
    ldr x3, [x16]
    ARM_CALL win_acl_add
    cbz w0, .Lwsi_bad
    ARM_ADDR x3, win_sid_system
    ARM_CALL win_acl_add
    cbz w0, .Lwsi_bad
    ARM_ADDR x3, win_sid_admin
    ARM_CALL win_acl_add
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_private_sd
    mov w1, #1
    bl InitializeSecurityDescriptor
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_private_sd
    mov w1, #1
    ARM_ADDR x2, win_private_acl
    mov w3, #0
    bl SetSecurityDescriptorDacl
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_private_sd
    mov w1, #0x1000
    mov w2, #0x1000
    bl SetSecurityDescriptorControl
    cbz w0, .Lwsi_bad
    /* Mode000 identity probes expose metadata and cleanup rights, not data
     * read/write/execute rights, to the current user. Administrative recovery
     * principals retain full control as they do for other private objects. */
    ARM_ADDR x0, win_probe_acl
    mov w1, #2048
    mov w2, #2
    bl InitializeAcl
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_probe_acl
    mov w1, #2
    mov w2, #0
    ARM_IMM w3, 0x170080
    ARM_ADDR x16, win_token_user
    ldr x4, [x16]
    bl AddAccessAllowedAceEx
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_probe_acl
    mov w1, #2
    mov w2, #0
    ARM_IMM w3, 0x1f01ff
    ARM_ADDR x4, win_sid_system
    bl AddAccessAllowedAceEx
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_probe_acl
    mov w1, #2
    mov w2, #0
    ARM_IMM w3, 0x1f01ff
    ARM_ADDR x4, win_sid_admin
    bl AddAccessAllowedAceEx
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_probe_sd
    mov w1, #1
    bl InitializeSecurityDescriptor
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_probe_sd
    mov w1, #1
    ARM_ADDR x2, win_probe_acl
    mov w3, #0
    bl SetSecurityDescriptorDacl
    cbz w0, .Lwsi_bad
    ARM_ADDR x0, win_probe_sd
    mov w1, #0x1000
    mov w2, #0x1000
    bl SetSecurityDescriptorControl
    cbz w0, .Lwsi_bad
    mov x9, #0
    ldp x29, x30, [sp], #48
    ret
.Lwsi_bad:
    mov w0, #1
    bl ExitProcess
    brk #0
win_acl_add:
    mov x4, x3
    ARM_ADDR x0, win_private_acl
    mov w1, #2
    mov w2, #3                   /* inherit to files and directories */
    ARM_IMM w3, 0x1f01ff
    b AddAccessAllowedAceEx
/* x0=SID. x9=1 current user, 0 trusted administrator, 2 other.
 * Pure SID comparison; does not infer identities from display names. */
win_sid_class:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    ARM_ADDR x16, win_token_user
    ldr x1, [x16]
    bl EqualSid
    cbnz w0, 1f
    mov x0, x19
    ARM_ADDR x1, win_sid_system
    bl EqualSid
    cbnz w0, 2f
    mov x0, x19
    ARM_ADDR x1, win_sid_admin
    bl EqualSid
    cbnz w0, 2f
    mov x0, x19
    ARM_ADDR x1, win_sid_installer
    bl EqualSid
    cbnz w0, 2f
    mov x9, #2
    b 3f
1:  mov x9, #1
    b 3f
2:  mov x9, #0
3:  ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

/* x0=HANDLE, x1=128-byte internal stat, already has type/size/identity.
 * x9=0 on a readable security descriptor, -13 otherwise. Stat uid describes
 * owner; stat group/other write bits reflect an untrusted allow ACE. Unknown
 * ACE types fail closed. INHERIT_ONLY ACEs do not grant access to this object.
 * Stack=128, plus SID helper; GetSecurityInfo allocation always LocalFree'd.
 */
win_security_stat:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x1
    mov w1, #1
    mov w2, #5                   /* OWNER_SECURITY_INFORMATION|DACL */
    add x3, sp, #64
    mov x4, #0
    add x5, sp, #72
    mov x6, #0
    add x7, sp, #80
    str xzr, [sp, #80]
    bl GetSecurityInfo
    cbnz w0, .Lwss_fail
    ldr x0, [sp, #64]
    cbz x0, .Lwss_bad
    ARM_CALL win_sid_class
    str w9, [x19, #ARM_STAT_UID]
    str w9, [x19, #ARM_STAT_GID]
    ldr x20, [sp, #72]
    cbz x20, .Lwss_bad
    mov x0, x20
    bl IsValidAcl
    cbz w0, .Lwss_bad
    ldrh w21, [x20, #4]          /* ACL.AceCount */
    cmp w21, #256
    b.hi .Lwss_bad
    mov x22, #0
.Lwss_ace:
    cmp x22, x21
    b.hs .Lwss_good
    mov x0, x20
    mov x1, x22
    add x2, sp, #88
    bl GetAce
    cbz w0, .Lwss_bad
    ldr x10, [sp, #88]
    ldrh w11, [x10, #2]
    cmp w11, #8
    b.lo .Lwss_bad
    ldrb w11, [x10, #1]
    tst w11, #8
    b.ne .Lwss_next
    ldrb w11, [x10]
    cmp w11, #1                  /* ACCESS_DENIED_ACE */
    b.eq .Lwss_next
    cbnz w11, .Lwss_bad          /* Only simple ALLOW/DENY supported. */
    ldr w11, [x10, #4]
    ARM_IMM w12, 0x500d0156      /* mutable content/metadata/ACL/identity */
    ldr w13, [x19, #ARM_STAT_MODE]
    tst w13, #0x4000
    b.eq 4f
    ldr w13, [x19, #ARM_STAT_UID]
    cbnz w13, 4f
    /* On a protected administrative ancestor, add-only rights cannot replace
     * an existing held child. HOME descendants still require current owner. */
    bic w12, w12, #6
4:  tst w11, w12
    b.eq .Lwss_next
    add x0, x10, #8
    ARM_CALL win_sid_class
    cmp x9, #2
    b.ne .Lwss_next
    ldr w10, [x19, #ARM_STAT_MODE]
    mov w11, #18
    orr w10, w10, w11
    str w10, [x19, #ARM_STAT_MODE]
.Lwss_next:
    add x22, x22, #1
    b .Lwss_ace
.Lwss_good:
    mov x21, #0
    b .Lwss_free
.Lwss_bad:
    mov x21, #-13
.Lwss_free:
    ldr x0, [sp, #80]
    bl LocalFree
    mov x9, x21
    b .Lwss_done
.Lwss_fail:
    mov x9, #-13
.Lwss_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #128
    ret
/* x0=owned opened file, x1=requested mode. Only 0600/0644/0700/0755 are
 * accepted. Windows does not have POSIX execute bits: all these modes set a
 * protected DACL for the same trusted principals. x9=0 or -13/-22.
 */
win_set_mode:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp x1, #384
    b.eq 1f
    cmp x1, #420
    b.eq 1f
    cmp x1, #448
    b.eq 1f
    cmp x1, #493
    b.ne 3f
1:  mov w1, #1
    ARM_IMM w2, 0x80000004       /* protected DACL */
    mov x3, #0
    mov x4, #0
    ARM_ADDR x5, win_private_acl
    mov x6, #0
    bl SetSecurityInfo
    cbnz w0, 2f
    mov x9, #0
    b 4f
2:  mov x9, #-13
    b 4f
3:  mov x9, #-22
4:  ldp x29, x30, [sp], #16
    ret
.section .rdata,"dr"
.p2align 2
win_sid_system: .byte 1,1,0,0,0,0,0,5
    .long 18
win_sid_admin: .byte 1,2,0,0,0,0,0,5
    .long 32,544
win_sid_installer: .byte 1,6,0,0,0,0,0,5
    .long 80,956008885,3418522649,1831038044,1853292631,2271478464
.section .bss
.p2align 3
win_token_user: .skip 1024
win_private_sd: .skip 40
win_probe_sd: .skip 40
win_probe_acl: .skip 2048
win_private_acl: .skip 2048
