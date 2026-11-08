/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Darwin arm64 adapters for the shared command assembly.
 * Inputs x0-x7 (fourth argument in x6), output x9 or negative Linux-contract
 * errno. Preserve x0-x7 and x19-x29. x8/x10-x17/NZCV scratch. Never use x18.
 * Stack frames are 16-byte aligned; variadic arguments are placed on the stack.
 * File metadata is normalized to the private 128-byte shared layout.
 */
.text
.macro MAC_SAVE
    stp x29, x30, [sp, #-96]!
    stp x0, x1, [sp, #16]
    stp x2, x3, [sp, #32]
    stp x4, x5, [sp, #48]
    stp x6, x7, [sp, #64]
.endm
.macro MAC_RETURN
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldp x29, x30, [sp], #96
    ret
.endm
.macro MAC_SIMPLE name, function
\name:
    MAC_SAVE
    mov x3, x6
    bl _\function
    ARM_CALL mac_result
    MAC_RETURN
.endm
/* Signed int and ssize_t results are distinct: Darwin int returns zero-extend. */
mac_result:
    cmn w0, #1
    b.eq mac_errno
    mov x9, x0
    ret
mac_errno:
    ARM_SAVE x30
    bl ___error
    ldr w9, [x0]
    cmp w9, #35
    b.ne 1f
    mov w9, #11
1:  cmp w9, #66
    b.ne 2f
    mov w9, #39
2:  cmp w9, #62
    b.ne 3f
    mov w9, #40
3:  cmp w9, #78
    b.ne 4f
    mov w9, #38
4:  neg x9, x9
    ARM_RESTORE x30
    ret
MAC_SIMPLE arm_read, read
MAC_SIMPLE arm_write, write

MAC_SIMPLE arm_lseek, lseek
.ifdef ASM_REGISTRY_V2
/* Project batch mapping: x0=0, x1=bounded completed-file size, x2=PROT_READ(1),
 * x6=MAP_PRIVATE(2), x4=owned FD>=3, x5=64-bit offset0. Flags match Darwin.
 * x9=64-bit pointer or negative errno. Preserve x0-x7/x19-x29; scratch as above.
 * Stack96 locally, plus16 call and16 errno-save bytes on the error path. */
arm_mmap:
    MAC_SAVE
    mov x3, x6
    bl _mmap
    cmn x0, #1
    b.eq .Lmac_project_mmap_error
    mov x9, x0
    MAC_RETURN
.Lmac_project_mmap_error:
    ARM_CALL mac_errno
    MAC_RETURN
/* x0=returned mapping, x1=its exact length. x9=0 or negative errno. */
MAC_SIMPLE arm_munmap, munmap
.endif
MAC_SIMPLE arm_mkdir, mkdir
MAC_SIMPLE arm_unlink, unlink
MAC_SIMPLE arm_rmdir, rmdir
MAC_SIMPLE arm_rename, rename
/* link preserves an existing destination and reports Linux-contract errno. */
MAC_SIMPLE arm_link, link
MAC_SIMPLE arm_chmod, chmod
MAC_SIMPLE arm_fchmod, fchmod
MAC_SIMPLE arm_fsync, fsync
MAC_SIMPLE arm_flock, flock
MAC_SIMPLE arm_kill, kill
/* shasum is a system Perl script. Never let PERL5OPT/PERL5LIB or another
 * interpreter startup setting turn a successful process exit into a false hash
 * decision. All calls to the fixed digest executable get an empty environment.
 * Other tools retain the caller's explicitly selected environment contract. */
arm_execve:
    MAC_SAVE
    ARM_ADDR x10, registry_sha256sum
    cmp x0, x10
    b.ne 1f
    ARM_ADDR x2, mac_digest_environment
1:  bl _execve
    ARM_CALL mac_result
    MAC_RETURN
.data
.p2align 3
mac_digest_environment: .quad 0
.text
MAC_SIMPLE arm_wait4, wait4
MAC_SIMPLE arm_getpid, getpid
/* x0=owned buffer, x1=capacity. x9=length including NUL, or negative errno.
 * _getcwd bounds and terminates the result. Preserve x0-x7 and x19-x29.
 * Scratch x8/x10-x17/NZCV; stack 96 bytes plus the errno helper. */
arm_getcwd:
    MAC_SAVE
    bl _getcwd
    cbz x0, .Lmac_getcwd_error
    mov x9, #0
.Lmac_getcwd_length:
    ldrb w10, [x0, x9]
    add x9, x9, #1
    cbnz w10, .Lmac_getcwd_length
    b .Lmac_getcwd_return
.Lmac_getcwd_error:
    ARM_CALL mac_errno
.Lmac_getcwd_return:
    MAC_RETURN
MAC_SIMPLE arm_chdir, chdir
MAC_SIMPLE arm_fchdir, fchdir
MAC_SIMPLE arm_getuid, getuid
MAC_SIMPLE arm_geteuid, geteuid
MAC_SIMPLE arm_getgid, getgid
MAC_SIMPLE arm_getegid, getegid
MAC_SIMPLE arm_umask, umask
MAC_SIMPLE arm_access, access
MAC_SIMPLE arm_fork, fork
MAC_SIMPLE arm_dup2, dup2
MAC_SIMPLE arm_alarm, alarm
MAC_SIMPLE arm_getrlimit, getrlimit
MAC_SIMPLE arm_setrlimit, setrlimit
arm_exit:
    bl _exit
    brk #0

/* Linux-contract open flags -> Darwin. Only internal named flag combinations are passed. */
mac_flags:
    and x9, x1, #3
    tst x1, #64
    b.eq 1f
    orr x9, x9, #512
1:  tst x1, #128
    b.eq 2f
    orr x9, x9, #2048
2:  tst x1, #512
    b.eq 3f
    orr x9, x9, #1024
3:  tst x1, #1024
    b.eq 4f
    orr x9, x9, #8
4:  tst x1, #O_NOFOLLOW
    b.eq 5f
    orr x9, x9, #256
5:  tst x1, #O_DIRECTORY
    b.eq 6f
    orr x9, x9, #0x100000
6:  tst x1, #O_CLOEXEC
    b.eq 7f
    orr x9, x9, #0x1000000
7:  tst x1, #O_NONBLOCK
    b.eq 8f
    orr x9, x9, #4
8:  mov x1, x9
    ret
arm_open:
    MAC_SAVE
    ARM_CALL mac_flags
    sub sp, sp, #16
    str x2, [sp]
    bl _open
    add sp, sp, #16
    ARM_CALL mac_result
    MAC_RETURN
arm_openat:
    MAC_SAVE
    mov x10, x1
    mov x1, x2
    ARM_CALL mac_flags
    mov x2, x1
    mov x1, x10
    cmp w0, #-100
    b.ne 1f
    mov x0, #-2
1:  sub sp, sp, #16
    str x6, [sp]
    bl _openat
    add sp, sp, #16
    ARM_CALL mac_result
    MAC_RETURN
arm_mkdirat:
    MAC_SAVE
    cmp w0, #-100
    b.ne 1f
    mov x0, #-2
1:  bl _mkdirat
    ARM_CALL mac_result
    MAC_RETURN
arm_unlinkat:
    MAC_SAVE
    cmp w0, #-100
    b.ne 1f
    mov x0, #-2
1:  cmp w2, #512
    mov w10, #128
    csel w2, w10, wzr, eq
    bl _unlinkat
    ARM_CALL mac_result
    MAC_RETURN
arm_renameat:
    MAC_SAVE
    mov x3, x6
    cmp w0, #-100
    b.ne 1f
    mov x0, #-2
1:  cmp w2, #-100
    b.ne 2f
    mov x2, #-2
2:  bl _renameat
    ARM_CALL mac_result
    MAC_RETURN
arm_renameat2:
    MAC_SAVE
    mov x3, x6
    cmp w4, #1
    b.ne 3f
    mov w4, #4 /* RENAME_EXCL */
    cmp w0, #-100
    b.ne 1f
    mov x0, #-2
1:  cmp w2, #-100
    b.ne 2f
    mov x2, #-2
2:  bl _renameatx_np
    ARM_CALL mac_result
    b 4f
3:  mov x9, #-22
4:  MAC_RETURN

/* x0=owned probe FD, x1=normalized output (128 bytes). Inspect identity only.
 * The held probe is created exclusively with mode 000. ACL-aware file-opening
 * checks remain mandatory everywhere that authorizes an installed executable.
 * x9=0/negative errno; preserves x0-x7/x19-x29; stack 256 bytes plus helpers. */
arm_probe_fd_stat:
    MAC_SAVE
    sub sp, sp, #160
    mov x1, sp
    bl _fstat
    b mac_stat_result
/* x0=held parent FD, x1=basename, x2=normalized output (128 bytes), x6=256.
 * Raw nofollow identity lookup cannot authorize file ownership or permissions.
 * It compares a mode-000 probe against a descriptor Asm already owns.
 * x9=0/negative errno; preserves x0-x7/x19-x29; stack 256 bytes plus helpers. */
arm_probe_stat:
    MAC_SAVE
    mov w3, #32 /* AT_SYMLINK_NOFOLLOW */
    sub sp, sp, #160
    mov x2, sp
    bl _fstatat
    ARM_CALL mac_result
    tbnz x9, #63, .Lmac_probe_stat_error
    ldr x10, [sp, #192] /* saved normalized output x2 */
    b mac_stat_copy
.Lmac_probe_stat_error:
    add sp, sp, #160
    MAC_RETURN

/* Native stat temporary is 144 bytes, normalized output remains caller-owned. */
arm_fstat:
    MAC_SAVE
    mov x1, #256
    bl _acl_get_fd_np
    ARM_CALL mac_acl_safe
    cbz w9, mac_stat_acl_fail
    ldr x0, [sp, #16]
    sub sp, sp, #160
    mov x1, sp
    bl _fstat
    b mac_stat_result
arm_lstat:
    MAC_SAVE
    mov x1, #256
    bl _acl_get_link_np
    ARM_CALL mac_acl_safe
    cbz w9, mac_stat_acl_fail
    ldr x0, [sp, #16]
    sub sp, sp, #160
    mov x1, sp
    bl _lstat
    b mac_stat_result
mac_stat_result:
    ARM_CALL mac_result
    tbnz x9, #63, 1f
    ldr x10, [sp, #184] /* saved x1 */
    b mac_stat_copy
1:  add sp, sp, #160
    MAC_RETURN
arm_newfstatat:
    MAC_SAVE
    cmp w0, #-100
    b.ne 8f
    mov x0, #-2
8:  ARM_IMM x2, 0x1000104 /* native nofollow, cloexec, nonblock */
    sub sp, sp, #16
    str xzr, [sp]
    bl _openat
    add sp, sp, #16
    ARM_CALL mac_result
    tbnz x9, #63, mac_stat_acl_return
    str x9, [sp, #80]
    mov x0, x9
    mov x1, #256
    bl _acl_get_fd_np
    ARM_CALL mac_acl_safe
    ARM_SAVE x9
    ldr x0, [sp, #96]
    bl _close
    ARM_RESTORE x9
    cbz w9, mac_stat_acl_fail
    ldp x0, x1, [sp, #16]
    ldr x6, [sp, #64]
    cmp w0, #-100
    b.ne 1f
    mov x0, #-2
1:  cmp w6, #256
    mov w3, #32
    csel w3, w3, wzr, eq
    sub sp, sp, #160
    mov x2, sp
    bl _fstatat
    ARM_CALL mac_result
    tbnz x9, #63, 2f
    ldr x10, [sp, #192] /* saved x2 */
    b mac_stat_copy
2:  add sp, sp, #160
    MAC_RETURN
mac_stat_acl_fail:
    mov x9, #-13
mac_stat_acl_return:
    MAC_RETURN
mac_stat_copy:
    /* Only fields consumed by shared assembly are exposed. Zero all padding. */
    .irp offset,0,16,32,48,64,80,96,112
    stp xzr, xzr, [x10, #\offset]
    .endr
    ldr w11, [sp]
    str x11, [x10]
    ldr x11, [sp, #8]
    str x11, [x10, #8]
    ldrh w11, [sp, #4]
    str w11, [x10, #16]
    ldrh w11, [sp, #6]
    str w11, [x10, #20]
    ldp w11, w12, [sp, #16]
    stp w11, w12, [x10, #24]
    ldr x11, [sp, #96]
    str x11, [x10, #48]
    mov x9, #0
    add sp, sp, #160
    MAC_RETURN

arm_fcntl:
    MAC_SAVE
    cmp w1, #1030 /* Linux F_DUPFD_CLOEXEC */
    b.ne 1f
    mov w1, #67
1:  sub sp, sp, #16
    str x2, [sp]
    bl _fcntl
    add sp, sp, #16
    ARM_CALL mac_result
    MAC_RETURN
arm_pipe2:
    MAC_SAVE
    bl _pipe
    ARM_CALL mac_result
    /* All callers request CLOEXEC. Set each descriptor before returning. */
    tbnz x9, #63, 2f
    ldr x10, [sp, #16]
    ldr w0, [x10]
    mov w1, #2
    mov x2, #1
    ARM_CALL arm_fcntl
    tbnz x9, #63, 2f
    ldr x10, [sp, #16]
    ldr w0, [x10, #4]
    mov w1, #2
    mov x2, #1
    ARM_CALL arm_fcntl
2:  MAC_RETURN
arm_getrandom:
    MAC_SAVE
    /* getentropy is bounded at 256 bytes; shared callers request 16. */
    cmp x1, #256
    b.hi 1f
    mov x9, x1
    mov x1, x9
    bl _getentropy
    ARM_CALL mac_result
    tbnz x9, #63, 2f
    ldr x9, [sp, #24]
    b 2f
1:  mov x9, #-22
2:  MAC_RETURN
/* Darwin sigset_t is 32 bits; only the shared SIGALRM bit is accepted. */
arm_rt_sigaction:
    MAC_SAVE
    cmp w0, #14
    b.ne 1f
    mov x1, #0 /* SIG_DFL */
    bl _signal
    ARM_CALL mac_result
    b 2f
1:  mov x9, #-22
2:  MAC_RETURN
arm_rt_sigprocmask:
    MAC_SAVE
    cmp w0, #1 /* shared SIG_UNBLOCK */
    b.ne 1f
    mov w0, #2
    bl _sigprocmask
    ARM_CALL mac_result
    b 2f
1:  mov x9, #-22
2:  MAC_RETURN
arm_readlink:
    MAC_SAVE
    bl _getpid
    ldr x1, [sp, #24]
    ldr w2, [sp, #32]
    bl _proc_pidpath
    cmp w0, #0
    b.eq 1f
    mov x9, x0
    b 2f
1:  mov x9, #-5
2:  MAC_RETURN
/* Check APFS and MNT_LOCAL. Return a private sentinel, never a Linux fs type. */
arm_fstatfs:
    MAC_SAVE
    sub sp, sp, #2176
    mov x1, sp
    bl _fstatfs
    ARM_CALL mac_result
    tbnz x9, #63, 1f
    ldr w10, [sp, #64]
    tst w10, #0x1000
    b.eq 2f
    tbnz w10, #21, 2f /* MNT_IGNORE_OWNERSHIP */
    ldr w10, [sp, #72]
    ARM_IMM w11, 0x73667061 /* apfs */
    cmp w10, w11
    b.ne 2f
    ldrb w10, [sp, #76]
    cbnz w10, 2f
    ldr x10, [sp, #2200]
    ARM_IMM w11, 0x41504653 /* private APFS sentinel */
    str w11, [x10]
    b 1f
2:  mov x9, #-95
1:  add sp, sp, #2176
    MAC_RETURN
/* Each fd owns a readdir stream until arm_close. One bounded entry is returned
 * per call. A duplicate descriptor gives closedir ownership without consuming
 * the caller descriptor. The table bounds descriptors at 1024 and fails closed.
 * This uses public libc directory interfaces, never a private kernel syscall. */
arm_getdents64:
    MAC_SAVE
    ARM_SAVE x19
    cmp x0, #1024
    b.hs 7f
    ARM_ADDR x19, mac_directory_streams
    add x19, x19, x0, lsl #3
    ldr x0, [x19]
    cbnz x0, 2f
    ldr x0, [sp, #32]
    bl _dup
    cmn w0, #1
    b.eq 6f
    ARM_SAVE x0
    bl _fdopendir
    cbnz x0, 1f
    ARM_RESTORE x0
    bl _close
    b 6f
1:  add sp, sp, #16
    str x0, [x19]
2:  bl ___error
    str wzr, [x0]
    ldr x0, [x19]
    bl _readdir
    cbnz x0, 3f
    bl ___error
    ldr w9, [x0]
    cbnz w9, 6f
    b 8f
3:  ldr x10, [sp, #40] /* caller buffer */
    ldr x11, [sp, #48] /* caller capacity */
    ldrh w12, [x0, #18] /* d_namlen */
    add x13, x12, #20
    add x13, x13, #7
    and x13, x13, #-8
    cmp x13, x11
    b.hi 7f
    ldr x14, [x0]
    str x14, [x10]
    str xzr, [x10, #8]
    strh w13, [x10, #16]
    ldrb w14, [x0, #20]
    strb w14, [x10, #18]
    add x0, x0, #21
    add x10, x10, #19
4:  ldrb w14, [x0], #1
    strb w14, [x10], #1
    subs x12, x12, #1
    b.pl 4b
    mov x9, x13
    b 8f
6:  ARM_CALL mac_errno
    b 8f
7:  mov x9, #-24
8:  ARM_RESTORE x19
    MAC_RETURN
arm_close:
    MAC_SAVE
    ARM_SAVE x19
    cmp x0, #1024
    b.hs 1f
    ARM_ADDR x19, mac_directory_streams
    add x19, x19, x0, lsl #3
    ldr x0, [x19]
    cbz x0, 1f
    str xzr, [x19]
    bl _closedir
1:  ldr x0, [sp, #32]
    bl _close
    ARM_CALL mac_result
    ARM_RESTORE x19
    MAC_RETURN
.zerofill __DATA,__bss,mac_directory_streams,8192,3

/* Bind an open descriptor to the vnode backing this executing text region.
 * Path identity alone is insufficient after an executable has been displaced.
 * Input x0=resolved executable path; output fd or negative error.
 * Kernel proc_regionwithpathinfo is 1272 bytes, vnode begins at offset 96.
 * This contract is checked against the SDK by tests/macos/test_abi.py. */
mac_open_running_image:
    MAC_SAVE
    sub sp, sp, #1424
    bl _getpid
    mov w1, #8 /* PROC_PIDREGIONPATHINFO */
    ARM_ADDR x2, _main
    mov x3, sp
    mov w4, #1272
    bl _proc_pidinfo
    cmp w0, #1272
    b.ne 3f
    ldr x0, [sp, #1440]
    ARM_IMM x1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, 4f
    str x9, [sp, #1408]
    mov x0, x9
    add x1, sp, #1280
    ARM_CALL arm_fstat
    tbnz x9, #63, .Lmac_image_stat_fail
    ldr w10, [sp, #96] /* kernel executable device */
    ldr x11, [sp, #1280]
    cmp x10, x11
    b.ne 2f
    ldr x10, [sp, #104] /* kernel executable inode */
    ldr x11, [sp, #1288]
    cmp x10, x11
    b.ne 2f
    ldr x9, [sp, #1408]
    b 4f
.Lmac_image_stat_fail:
    ARM_SAVE x9
    ldr x0, [sp, #1424]
    ARM_CALL arm_close
    ARM_RESTORE x9
    b 4f
2:  ldr x0, [sp, #1408]
    ARM_CALL arm_close
3:  mov x9, #-1
4:  add sp, sp, #1424
    MAC_RETURN

/* A mode check is not an ACL check. Accept empty or deny-only Darwin ACLs;
 * reject every allow entry, including owner-only grants, conservatively.
 * x0 owns an ACL returned by acl_get_*; x9=1 safe, 0 error/allow entry.
 * Always frees a non-null ACL. Preserves x19/x20. At most 170 entry probes.
 * Default macOS HOME's everyone-deny-delete entry remains supported.
 */
mac_acl_safe:
    ARM_SAVE x30
    ARM_SAVE x19
    ARM_SAVE x20
    sub sp, sp, #32
    mov x19, x0
    cbz x19, .Lmac_acl_missing
    bl _acl_valid
    cbnz w0, .Lmac_acl_free_bad
    mov x20, #0
.Lmac_acl_next:
    mov x0, x19
    mov x1, x20
    mov x2, sp
    bl _acl_get_entry
    cbnz w0, .Lmac_acl_end
    cmp x20, #169
    b.hs .Lmac_acl_free_bad
    ldr x0, [sp]
    add x1, sp, #8
    bl _acl_get_tag_type
    cbnz w0, .Lmac_acl_free_bad
    ldr w10, [sp, #8]
    cmp w10, #2 /* ACL_EXTENDED_DENY */
    b.ne .Lmac_acl_free_bad
    add x20, x20, #1
    b .Lmac_acl_next
.Lmac_acl_end:
    bl ___error
    ldr w10, [x0]
    cmp w10, #22 /* valid ACL, no entry at this index */
    b.ne .Lmac_acl_free_bad
    mov x0, x19
    bl _acl_free
    mov x9, #1
    b .Lmac_acl_return
.Lmac_acl_free_bad:
    mov x0, x19
    bl _acl_free
.Lmac_acl_bad:
    mov x9, #0
    b .Lmac_acl_return
.Lmac_acl_missing:
    bl ___error
    ldr w10, [x0]
    cmp w10, #2 /* APFS reports ENOENT when the object has no extended ACL. */
    cset w9, eq
.Lmac_acl_return:
    add sp, sp, #32
    ARM_RESTORE x20
    ARM_RESTORE x19
    ARM_RESTORE x30
    ret
