/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Windows ARM64 boundary. Internal inputs x0-x7, fourth argument x6; result
 * x9 is a nonnegative value or negative Linux-contract errno. Adapters preserve
 * x0-x7/x19-x29 and never use x18. Windows calls use x0-x7 and aligned stack
 * arguments. Pointers are borrowed unless a routine documents ownership.
 * Windows handles remain native handles; only 0,1,2 name standard streams.
 */
.text
.equ WIN_OPEN_DELETE, 0x10000000
.macro WIN_SAVE
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    stp x2, x3, [sp, #32]
    stp x4, x5, [sp, #48]
    stp x6, x7, [sp, #64]
.endm
.macro WIN_RETURN
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldp x29, x30, [sp], #96
    ret
.endm
/* x0=Win32 error -> negative shared errno, x9. No allocation. */
win_error_code:
    cmp w0, #2
    b.eq 1f
    cmp w0, #3
    b.eq 1f
    cmp w0, #18
    b.eq 1f
    cmp w0, #80
    b.eq 2f
    cmp w0, #183
    b.eq 2f
    cmp w0, #32
    b.eq 3f
    cmp w0, #33
    b.eq 3f
    cmp w0, #145
    b.eq 4f
    cmp w0, #6
    b.eq 5f
    mov x9, #-13
    ret
1:  mov x9, #-2
    ret
2:  mov x9, #-17
    ret
3:  mov x9, #-11
    ret
4:  mov x9, #-39
    ret
5:  mov x9, #-9
    ret
win_error:
    ARM_SAVE x30
    bl GetLastError
    ARM_CALL win_error_code
    ARM_RESTORE x30
    ret
win_nt_error:
    ARM_SAVE x30
    bl RtlNtStatusToDosError
    ARM_CALL win_error_code
    ARM_RESTORE x30
    ret
/* x0=UTF8 NUL, x1=owned UTF16 buffer, x2=capacity in WCHARs.
 * Returns x9=character count including NUL, or -22. Reject invalid UTF8. */
win_utf16:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x5, x2
    mov x4, x1
    mov x2, x0
    mov w3, #-1
    mov w0, #65001
    mov w1, #8
    bl MultiByteToWideChar
    mov x9, x0
    cbnz w0, 1f
    mov x9, #-22
1:  ldp x29, x30, [sp], #32
    ret
/* Resolve 0..2 through GetStdHandle. Other handles remain unchanged. */
win_handle:
    cmp x0, #2
    b.hi 1f
    ARM_SAVE x30
    mov w10, #-10
    sub w0, w10, w0
    bl GetStdHandle
    ARM_RESTORE x30
1:  ret
arm_read:
    WIN_SAVE
    sub sp, sp, #16
    ARM_CALL win_handle
    ldp x1, x2, [x29, #24]
    add x3, sp, #8
    mov x4, #0
    bl ReadFile
    cbnz w0, 1f
    bl GetLastError
    cmp w0, #109                  /* ERROR_BROKEN_PIPE is EOF. */
    b.eq 2f
    ARM_CALL win_error_code
    b 3f
1:  ldr w9, [sp, #8]
    b 3f
2:  mov x9, #0
3:  add sp, sp, #16
    WIN_RETURN
arm_write:
    WIN_SAVE
    sub sp, sp, #16
    ARM_CALL win_handle
    ldp x1, x2, [x29, #24]
    add x3, sp, #8
    mov x4, #0
    bl WriteFile
    cbz w0, 1f
    ldr w9, [sp, #8]
    b 2f
1:  ARM_CALL win_error
2:  add sp, sp, #16
    WIN_RETURN
arm_close:
    WIN_SAVE
    ARM_CALL win_handle
    ARM_CALL win_unlock_close
    cbz w0, 1f
    mov x9, #0
    b 2f
1:  ARM_CALL win_error
2:  WIN_RETURN
arm_fsync:
    WIN_SAVE
    bl FlushFileBuffers
    cbz w0, 1f
    mov x9, #0
    b 2f
1:  ARM_CALL win_error
2:  WIN_RETURN
arm_lseek:
    WIN_SAVE
    sub sp, sp, #16
    mov w3, w2
    mov x2, sp
    bl SetFilePointerEx
    cbz w0, 1f
    ldr x9, [sp]
    b 2f
1:  ARM_CALL win_error
2:  add sp, sp, #16
    WIN_RETURN
arm_exit:
    bl ExitProcess
    brk #0
arm_getpid:
    WIN_SAVE
    bl GetCurrentProcessId
    mov x9, x0
    WIN_RETURN
/* Shared UID values describe checked security principals, never OS UIDs.
 * 1=current token user; 0=SYSTEM/Administrators/TrustedInstaller; 2=other.
 * File modes are derived from DACL grants by win_security_stat. */
arm_getuid:
arm_geteuid:
arm_getgid:
arm_getegid:
    mov x9, #1
    ret
arm_getrandom:
    WIN_SAVE
    mov x3, #2                    /* BCRYPT_USE_SYSTEM_PREFERRED_RNG */
    mov x2, x1
    mov x1, x0
    mov x0, #0
    bl BCryptGenRandom
    tbnz w0, #31, 1f
    ldr x9, [sp, #24]
    b 2f
1:  mov x9, #-5
2:  WIN_RETURN

/* UTF8 paths are limited to 4095 bytes. Split at both separators and reject
 * DOS aliases, ADS, device names, trailing dot/space, and parent traversal.
 * Open each component relative to a retained directory HANDLE. Each open uses
 * FILE_OPEN_REPARSE_POINT; GetFileInformationByHandle rejects every reparse
 * tag, including intermediate junctions. No string-based re-open follows it.
 * x0=RootDirectory or -100, x1=UTF8, x2=shared flags, x6=mode.
 * Returns owned HANDLE or negative errno. Stack 224 plus Win32 conversion.
 * Global UTF16 scratch (8192 bytes) is private to this single-threaded CLI.
 */
win_open:
    stp x29, x30, [sp, #-224]!
    mov x29, sp
    stp x19, x20, [sp, #32]
    stp x21, x22, [sp, #48]
    stp x23, x24, [sp, #64]
    stp x25, x26, [sp, #80]
    mov x19, x0
    mov x20, x2
    mov x25, x6
    mov x0, x1
    ARM_ADDR x1, win_path_w
    mov x2, #4096
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwo_bad
    ARM_ADDR x21, win_path_w
    mov x24, #0                  /* own root handle? */
    cmn x19, #100
    b.ne .Lwo_relative
    mov x0, #4096
    ARM_ADDR x1, win_path_full
    bl GetCurrentDirectoryW
    cbz w0, .Lwo_error
    cmp w0, #4096
    b.hs .Lwo_bad
    ARM_ADDR x23, win_path_full
    ldrh w10, [x21, #2]
    cmp w10, #':'
    b.ne .Lwo_current_root
    ldrh w10, [x21]
    strh w10, [x23]
    ldrh w10, [x21, #4]
    cmp w10, #47
    b.eq 1f
    cmp w10, #92
    b.ne .Lwo_bad
1:  add x21, x21, #4
.Lwo_current_root:
    /* Fixed native drive root, not a DOS device-relative path. */
    ARM_ADDR x22, win_nt_root
    ldrh w10, [x23]
    strh w10, [x22, #8]
    mov w10, #58
    strh w10, [x22, #10]
    mov w10, #92
    strh w10, [x22, #12]
    strh wzr, [x22, #14]
    mov x19, #0
    mov x0, x22
    mov x1, #14
    mov x2, #0
    ARM_CALL win_nt_component
    tbnz x9, #63, .Lwo_done
    mov x19, x9
    mov x24, #1
    ldrh w10, [x21]
    cmp w10, #47
    b.eq .Lwo_skip_root
    cmp w10, #92
    b.eq .Lwo_skip_root
    /* Relative to current directory: acquire it as one absolute NT path.
     * It is split into components by the same path walk below. */
    mov x26, x21
    mov x21, x23
    add x21, x21, #6
    bl .Lwo_walk_cwd
    tbnz x9, #63, .Lwo_close_error
    mov x21, x26
    b .Lwo_relative
.Lwo_skip_root:
    add x21, x21, #2
    b .Lwo_relative
.Lwo_walk_cwd:
    ARM_SAVE x30
    mov x22, x21
2:  ldrh w10, [x21]
    cbz w10, 4f
    cmp w10, #92
    b.eq 3f
    add x21, x21, #2
    b 2b
3:  mov x23, #92
    strh wzr, [x21]
    b 8f
4:  mov x23, #0
8:  sub x1, x21, x22
    cbz x1, 6f
    mov x0, x22
    mov x2, #0
    ARM_CALL win_nt_component
    tbnz x9, #63, 7f
    mov x0, x19
    mov x19, x9
    bl CloseHandle
    cbz x23, 6f
    mov w10, #92
    strh w10, [x21]
    add x21, x21, #2
    mov x22, x21
    ldrh w10, [x21]
    cbnz w10, 2b
6:  mov x9, #0
7:  ARM_RESTORE x30
    ret
.Lwo_relative:
    mov x22, x21
.Lwo_scan:
    ldrh w10, [x21]
    cbz w10, .Lwo_final
    cmp w10, #47
    b.eq .Lwo_next
    cmp w10, #92
    b.eq .Lwo_next
    cmp w10, #32
    b.lo .Lwo_bad_close
    cmp w10, #':'
    b.eq .Lwo_bad_close
    cmp w10, #'"'
    b.eq .Lwo_bad_close
    cmp w10, #'*'
    b.eq .Lwo_bad_close
    cmp w10, #'?'
    b.eq .Lwo_bad_close
    cmp w10, #'|'
    b.eq .Lwo_bad_close
    cmp w10, #'<'
    b.eq .Lwo_bad_close
    cmp w10, #'>'
    b.eq .Lwo_bad_close
    add x21, x21, #2
    b .Lwo_scan
.Lwo_next:
    sub x1, x21, x22
    cbz x1, .Lwo_bad_close
    strh wzr, [x21]
    mov x0, x22
    mov x2, #0
    ARM_CALL win_nt_component
    mov w10, #92
    strh w10, [x21]
    tbnz x9, #63, .Lwo_close_error
    cbz x24, 1f
    mov x0, x19
    str x9, [sp, #112]
    bl CloseHandle
    ldr x9, [sp, #112]
1:  mov x19, x9
    mov x24, #1
    add x21, x21, #2
    mov x22, x21
    b .Lwo_scan
.Lwo_final:
    sub x1, x21, x22
    cbnz x1, 1f
    cbz x24, .Lwo_bad_close
    mov x9, x19
    mov x24, #0
    b .Lwo_done
1:  mov x0, x22
    mov x2, #1
    ARM_CALL win_nt_component
.Lwo_close_error:
    str x9, [sp, #112]
    cbz x24, 2f
    mov x0, x19
    bl CloseHandle
2:  ldr x9, [sp, #112]
    b .Lwo_done
.Lwo_bad_close:
    mov x9, #-22
    b .Lwo_close_error
.Lwo_error:
    ARM_CALL win_error
    b .Lwo_done
.Lwo_bad:
    mov x9, #-22
.Lwo_done:
    ldp x25, x26, [sp, #80]
    ldp x23, x24, [sp, #64]
    ldp x21, x22, [sp, #48]
    ldp x19, x20, [sp, #32]
    ldp x29, x30, [sp], #224
    ret

/* Private component open: x0=UTF16, x1=byte length, x2=final(0/1).
 * Captures root x19, flags x20. Returns owned HANDLE. Preserves x19-x28.
 * NtCreateFile receives an OBJECT_ATTRIBUTES and UNICODE_STRING on stack.
 */
win_nt_component:
    stp x29, x30, [sp, #-224]!
    mov x29, sp
    stp x0, x1, [sp, #40]
    str x2, [sp, #56]
    cbz x1, .Lwn_bad
    cmp x1, #510
    b.hi .Lwn_bad
    sub x10, x1, #2
    ldrh w11, [x0, x10]
    cmp w11, #'.'
    b.eq .Lwn_dot
    cmp w11, #32
    b.eq .Lwn_bad
    b .Lwn_setup
.Lwn_dot:
    /* '.' is needed for local cwd and dependency root; '..' is never accepted. */
    cmp x1, #2
    b.ne .Lwn_bad
.Lwn_setup:
    cbz x19, 9f
    ARM_CALL win_component_name
    cbz w9, .Lwn_bad
9:  strh w1, [sp, #64]
    strh w1, [sp, #66]
    str x0, [sp, #72]
    mov w10, #48
    str w10, [sp, #80]
    str x19, [sp, #88]
    add x10, sp, #64
    str x10, [sp, #96]
    mov w10, #64
    str w10, [sp, #104]
    str xzr, [sp, #112]
    tst x20, #64
    b.eq 1f
    ARM_ADDR x10, win_private_sd
    str x10, [sp, #112]
1:  str xzr, [sp, #120]
    add x0, sp, #128
    ARM_IMM x1, 0x120089          /* read data/attributes/control/synchronize */
    mov x5, #7                   /* share read/write/delete; identity held */
    mov x6, #1                   /* FILE_OPEN */
    ARM_IMM x7, 0x200021         /* reparse open + sync + directory */
    ldr x10, [sp, #56]
    cbz x10, .Lwn_call
    bic x7, x7, #1
    tst x20, #O_DIRECTORY
    b.eq 1f
    orr x7, x7, #1
1:  and x10, x20, #3
    cbz x10, 2f
    ARM_IMM x1, 0x17019f         /* read/write/delete + READ_CONTROL/SYNC */
2:  tst x20, #WIN_OPEN_DELETE
    b.eq 8f
    ARM_IMM x1, 0x130080         /* DELETE/SYNC/READ_CONTROL/attributes */
8:  tst x20, #64
    b.eq 3f
    mov x6, #3                   /* FILE_OPEN_IF */
    tst x20, #128
    b.eq 3f
    mov x6, #2                   /* FILE_CREATE */
3:  tst x20, #512
    b.eq .Lwn_call
    mov x6, #5                   /* FILE_OVERWRITE_IF */
.Lwn_call:
    add x2, sp, #80
    add x3, sp, #136
    mov x4, #0
    /* Preserve all frame addresses above before allocating the outgoing
     * area. Args9..11 belong at the call's SP, outside the saved frame. */
    sub sp, sp, #32
    str x7, [sp]                /* CreateOptions */
    str xzr, [sp, #8]           /* EaBuffer */
    str xzr, [sp, #16]          /* EaLength */
    mov x7, x6
    mov x6, x5
    mov x5, #128
    bl NtCreateFile
    add sp, sp, #32
    tbnz w0, #31, .Lwn_nt_error
    ldr x0, [sp, #128]
    add x1, sp, #152
    bl GetFileInformationByHandle
    cbz w0, .Lwn_created_bad
    ldr w10, [sp, #152]
    tst w10, #0x400
    b.ne .Lwn_created_bad
    ldr x9, [sp, #128]
    b .Lwn_return
.Lwn_created_bad:
    ldr x0, [sp, #128]
    bl CloseHandle
    mov x9, #-40
    b .Lwn_return
.Lwn_nt_error:
    ARM_CALL win_nt_error
    b .Lwn_return
.Lwn_bad:
    mov x9, #-22
.Lwn_return:
    ldp x29, x30, [sp], #224
    ret

arm_open:
    WIN_SAVE
    mov x6, x2
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    ARM_CALL win_open
    WIN_RETURN
arm_openat:
    WIN_SAVE
    ARM_CALL win_open
    WIN_RETURN
/* mkdir uses FILE_CREATE on a directory; creation never accepts EEXIST. */
arm_mkdir:
    WIN_SAVE
    mov x6, x1
    mov x1, x0
    mov x0, #-100
    ARM_IMM x2, O_DIRECTORY + O_NOFOLLOW + 193
    ARM_CALL win_open
    b .Lwm_finish
arm_mkdirat:
    WIN_SAVE
    mov x6, x2
    ARM_IMM x2, O_DIRECTORY + O_NOFOLLOW + 193
    ARM_CALL win_open
.Lwm_finish:
    tbnz x9, #63, 1f
    mov x0, x9
    bl CloseHandle
    mov x9, #0
1:  WIN_RETURN

arm_fstat:
    WIN_SAVE
    sub sp, sp, #64
    str x1, [sp, #56]
    mov x1, sp
    bl GetFileInformationByHandle
    cbz w0, .Lws_error
    ldr w10, [sp]
    tst w10, #0x400
    b.ne .Lws_reparse
    ldr x1, [sp, #56]
    stp xzr, xzr, [x1]
    stp xzr, xzr, [x1, #16]
    stp xzr, xzr, [x1, #32]
    stp xzr, xzr, [x1, #48]
    stp xzr, xzr, [x1, #64]
    stp xzr, xzr, [x1, #80]
    stp xzr, xzr, [x1, #96]
    stp xzr, xzr, [x1, #112]
    ldr w11, [sp, #28]           /* volume serial */
    str x11, [x1, #ARM_STAT_DEVICE]
    ldr w11, [sp, #44]
    ldr w12, [sp, #48]
    orr x11, x12, x11, lsl #32
    str x11, [x1, #ARM_STAT_INODE]
    ldr w11, [sp, #32]
    ldr w12, [sp, #36]
    orr x11, x12, x11, lsl #32
    str x11, [x1, #ARM_STAT_SIZE]
    ldr w11, [sp, #40]
    str w11, [x1, #ARM_STAT_LINKS]
    ARM_IMM w11, 0x81ed         /* normal file 0755, subject to DACL check */
    tst w10, #16
    b.eq 1f
    ARM_IMM w11, 0x41ed
1:  str w11, [x1, #ARM_STAT_MODE]
    ldr x0, [x29, #16]
    ARM_CALL win_security_stat
    b .Lws_return
.Lws_reparse:
    mov x9, #-40
    b .Lws_return
.Lws_error:
    ARM_CALL win_error
.Lws_return:
    add sp, sp, #64
    WIN_RETURN
arm_lstat:
    WIN_SAVE
    sub sp, sp, #16
    str x1, [sp]
    mov x1, x0
    mov x0, #-100
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC
    mov x6, #0
    ARM_CALL win_open
    b .Lwst_opened
arm_newfstatat:
    WIN_SAVE
    sub sp, sp, #16
    str x2, [sp]
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC
    mov x6, #0
    ARM_CALL win_open
.Lwst_opened:
    tbnz x9, #63, 1f
    str x9, [sp, #8]
    mov x0, x9
    ldr x1, [sp]
    ARM_CALL arm_fstat
    str x9, [sp]
    ldr x0, [sp, #8]
    bl CloseHandle
    ldr x9, [sp]
1:  add sp, sp, #16
    WIN_RETURN
arm_access:
    ARM_ADDR x16, registry_sha256sum
    cmp x0, x16
    b.ne 8f
    /* BCrypt is statically imported and its SHA provider was tested by init. */
    mov x9, #0
    ret
8:  WIN_SAVE
    mov x1, x0
    mov x0, #-100
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC
    mov x6, #0
    ARM_CALL win_open
    tbnz x9, #63, 1f
    mov x0, x9
    bl CloseHandle
    mov x9, #0
1:  WIN_RETURN

/* Deletion targets the opened file identity and never reparses its name. */
arm_unlink:
    WIN_SAVE
    mov x1, x0
    mov x0, #-100
    mov x7, #0
    b .Lwu_open
arm_rmdir:
    WIN_SAVE
    mov x1, x0
    mov x0, #-100
    mov x7, #512
    b .Lwu_open
arm_unlinkat:
    WIN_SAVE
    mov x7, x2
.Lwu_open:
    /* Keep the requested kind outside the outgoing API area. */
    str x7, [x29, #80]
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_DELETE
    mov x6, #0
    ARM_CALL win_open
    tbnz x9, #63, .Lwu_done
    sub sp, sp, #80
    str x9, [sp, #8]
    mov x0, x9
    add x1, sp, #16
    bl GetFileInformationByHandle
    cbz w0, .Lwu_info_error
    ldr w10, [sp, #16]
    ldr x11, [x29, #80]
    tst w10, #16
    b.ne .Lwu_directory
    cbnz x11, .Lwu_not_directory
    b .Lwu_delete
.Lwu_directory:
    cmp x11, #512
    b.ne .Lwu_is_directory
.Lwu_delete:
    mov w10, #1
    str w10, [sp]
    ldr x0, [sp, #8]
    mov w1, #4                   /* FileDispositionInfo */
    mov x2, sp
    mov w3, #4
    bl SetFileInformationByHandle
    cbnz w0, 1f
.Lwu_info_error:
    ARM_CALL win_error
    b .Lwu_close
1:  mov x9, #0
    b .Lwu_close
.Lwu_not_directory:
    mov x9, #-20
    b .Lwu_close
.Lwu_is_directory:
    mov x9, #-21
.Lwu_close:
    str x9, [sp]
    ldr x0, [sp, #8]
    bl CloseHandle
    ldr x9, [sp]
    add sp, sp, #80
.Lwu_done:
    WIN_RETURN
/* Rename uses source HANDLE and destination RootDirectory. The destination
 * parent is opened before mutation; no-replace is kernel-enforced. */
arm_rename:
    WIN_SAVE
    mov x6, x1
    mov x1, x0
    mov x0, #-100
    mov x2, #-100
    mov x4, #0
    b .Lwr_start
arm_renameat:
    WIN_SAVE
    mov x4, #0
    b .Lwr_start
arm_renameat2:
    WIN_SAVE
.Lwr_start:
    ARM_CALL win_rename
    WIN_RETURN

/* LockFileEx locks one byte on the directory's private lock file. Directory
 * handles cannot be locked with LockFileEx, so use an exclusive NT open of a
 * reserved lock file relative to that exact directory. Held until close. */
arm_flock:
    WIN_SAVE
    ARM_CALL win_directory_lock
    WIN_RETURN
arm_getcwd:
    WIN_SAVE
    ARM_CALL win_getcwd_utf8
    WIN_RETURN
arm_chdir:
    WIN_SAVE
    ARM_CALL win_chdir
    WIN_RETURN
arm_fchdir:
    WIN_SAVE
    ARM_CALL win_fchdir
    WIN_RETURN
arm_fchmod:
    WIN_SAVE
    ARM_CALL win_set_mode
    WIN_RETURN
arm_chmod:
    WIN_SAVE
    sub sp, sp, #16
    str x1, [sp]
    mov x1, x0
    mov x0, #-100
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC + 2
    mov x6, #0
    ARM_CALL win_open
    tbnz x9, #63, 1f
    str x9, [sp, #8]
    mov x0, x9
    ldr x1, [sp]
    ARM_CALL win_set_mode
    str x9, [sp]
    ldr x0, [sp, #8]
    bl CloseHandle
    ldr x9, [sp]
1:  add sp, sp, #16
    WIN_RETURN
arm_getdents64:
    WIN_SAVE
    ARM_CALL win_getdents
    WIN_RETURN
arm_fcntl:
    WIN_SAVE
    cmp x1, #1030
    b.ne 1f
    sub sp, sp, #16
    mov x2, #-1
    mov x1, x0
    mov x0, #-1
    mov x3, sp
    mov w4, #0
    mov w5, #0
    mov w6, #2
    bl DuplicateHandle
    cbz w0, 2f
    ldr x9, [sp]
    b 3f
2:  ARM_CALL win_error
3:  add sp, sp, #16
    b 4f
1:  mov x9, #-38
4:  WIN_RETURN
/* These Linux-only facilities have no caller after build-time substitution.
 * Retain explicit failures if a new shared caller is accidentally introduced. */
arm_readlink:
arm_readlinkat:
arm_fstatfs:
arm_rt_sigaction:
arm_rt_sigprocmask:
arm_getrlimit:
arm_setrlimit:
arm_prlimit64:
arm_alarm:
arm_kill:
arm_pipe2:
arm_dup2:
arm_uname:
arm_mmap:
arm_mprotect:
arm_munmap:
arm_umask:
    mov x9, #-38
    ret

.section .data
.p2align 3
win_nt_root: .hword 92,63,63,92,67,58,92,0
.section .bss
.p2align 3
win_path_w: .skip 8192
win_path_full: .skip 8192
