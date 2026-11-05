/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native retained-handle mutations and bounded directory operations.
 */
.text
/* x0=source root, x1=source name, x2=destination root, x6=dest name,
 * x4=1 no-replace or 0 replace. x9=0 or negative errno. Source/destination
 * paths remain borrowed. Rename info capacity=8248, path WCHAR capacity4096.
 * FileRenameInfoEx with POSIX semantics preserves held destination identities.
 * A failed rename leaves the destination bytes intact. Stack=112 plus helpers.
 */
win_rename:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x2
    mov x20, x6
    mov x21, x4
    ARM_IMM x2, O_CLOEXEC + O_NOFOLLOW + WIN_OPEN_DELETE
    mov x6, #0
    ARM_CALL win_open
    tbnz x9, #63, .Lwr_done
    mov x22, x9
    mov x0, x20
    ARM_ADDR x1, win_rename_w
    mov x2, #4096
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwr_fail
    sub x23, x9, #1
    ARM_ADDR x24, win_rename_w
    cmn x19, #100
    b.ne .Lwr_relative
    /* Open destination parent with the same no-reparse component walk. */
    mov x0, x20
    ARM_ADDR x1, win_rename_utf8
    ARM_CALL win_parent_path
    tbnz x9, #63, .Lwr_fail
    str x9, [sp, #72]
    ARM_ADDR x0, win_rename_utf8
    ARM_IMM x1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, .Lwr_fail
    mov x19, x9
    mov x0, x20
    ldr x10, [sp, #72]
    add x0, x0, x10
    ARM_ADDR x1, win_rename_w
    mov x2, #4096
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwr_close_parent
    sub x23, x9, #1
    mov x20, #1
    b .Lwr_build
.Lwr_relative:
    mov x20, #0
    /* A relative rename leaf cannot use a separator, ADS, or DOS alias. */
    mov x0, #0
1:  cmp x0, x23
    b.hs .Lwr_build
    ldrh w10, [x24, x0, lsl #1]
    cmp w10, #47
    b.eq .Lwr_fail
    cmp w10, #92
    b.eq .Lwr_fail
    cmp w10, #58
    b.eq .Lwr_fail
    add x0, x0, #1
    b 1b
.Lwr_build:
    cbz x23, .Lwr_close_parent
    sub x10, x23, #1
    ldrh w11, [x24, x10, lsl #1]
    cmp w11, #46
    b.eq .Lwr_close_parent
    cmp w11, #32
    b.eq .Lwr_close_parent
    ARM_ADDR x2, win_rename_info
    mov w10, #2                  /* FILE_RENAME_FLAG_POSIX_SEMANTICS */
    cbnz x21, 2f
    orr w10, w10, #1
2:  str w10, [x2]
    str x19, [x2, #8]
    lsl x23, x23, #1
    str w23, [x2, #16]
    add x0, x2, #20
    mov x1, #0
3:  cmp x1, x23
    b.hs 4f
    ldrh w10, [x24, x1]
    strh w10, [x0, x1]
    add x1, x1, #2
    b 3b
4:  mov x0, x22
    mov w1, #22                 /* FileRenameInfoEx */
    add x3, x23, #20
    bl SetFileInformationByHandle
    cbnz w0, .Lwr_ok
    ARM_CALL win_error
    b .Lwr_finish
.Lwr_ok:
    mov x9, #0
    b .Lwr_finish
.Lwr_close_parent:
    mov x9, #-22
    b .Lwr_finish
.Lwr_fail:
    mov x20, #0
    mov x9, #-22
.Lwr_finish:
    str x9, [sp, #64]
    cbz x20, 5f
    mov x0, x19
    bl CloseHandle
5:  mov x0, x22
    bl CloseHandle
    ldr x9, [sp, #64]
.Lwr_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #112
    ret
/* x0=UTF8 path<=4095, x1=owned4096 buffer. Output x9=byte offset of basename.
 * Parent '.' when no separator. Does not normalize or resolve path aliases. */
win_parent_path:
    mov x9, #0
    mov x2, #0
1:  ldrb w10, [x0, x2]
    cbz w10, 3f
    cmp x2, #4095
    b.hs 5f
    strb w10, [x1, x2]
    cmp w10, #47
    b.eq 2f
    cmp w10, #92
    b.ne 4f
2:  add x9, x2, #1
4:  add x2, x2, #1
    b 1b
3:  cbnz x9, 6f
    mov w10, #46
    strb w10, [x1]
    strb wzr, [x1, #1]
    ret
6:  sub x10, x9, #1
    cmp x10, #2                  /* retain C:/ root separator */
    b.ne 7f
    mov x10, #3
7:  strb wzr, [x1, x10]
    ret
5:  mov x9, #-22
    ret

/* x0=bounded, NUL-terminated UTF16 path returned by a Windows path API.
 * x9=borrowed drive-absolute view, or -22. Ordinary C:\ and extended \\?\C:\
 * forms are accepted. Network/device namespaces are rejected. This does not
 * resolve or open a filesystem object. x0 preserved; x9-x11/NZCV scratch.
 */
win_drive_view:
    mov x9, x0
    ldr x10, [x9]
    ARM_IMM x11, 0x005c003f005c005c
    cmp x10, x11
    b.ne 1f
    add x9, x9, #8
1:  ldrh w10, [x9]
    orr w10, w10, #32
    cmp w10, #97
    b.lo 3f
    cmp w10, #122
    b.hi 3f
    ldrh w10, [x9, #2]
    cmp w10, #58
    b.ne 3f
    ldrh w10, [x9, #4]
    cmp w10, #92
    b.eq 2f
    cmp w10, #47
    b.ne 3f
2:  ret
3:  mov x9, #-22
    ret

/* x0=owned UTF8 buffer, x1=capacity; x9=length including NUL or -22.
 * Windows current directory returned as C:/path, with strict UTF8 conversion.
 */
win_getcwd_utf8:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    mov x0, #4096
    ARM_ADDR x1, win_cwd_w
    bl GetCurrentDirectoryW
    cbz w0, .Lwgc_bad
    cmp w0, #4096
    b.hs .Lwgc_bad
    ARM_ADDR x0, win_cwd_w
    ARM_CALL win_drive_view
    tbnz x9, #63, .Lwgc_bad
    mov x2, x9
    mov w0, #65001
    mov w1, #0x80
    mov w3, #-1
    mov x4, x19
    mov x5, x20
    mov x6, #0
    mov x7, #0
    bl WideCharToMultiByte
    cbz w0, .Lwgc_bad
    mov x9, x0
    mov x10, #0
1:  ldrb w11, [x19, x10]
    cbz w11, 3f
    cmp w11, #92
    b.ne 2f
    mov w11, #47
    strb w11, [x19, x10]
2:  add x10, x10, #1
    b 1b
.Lwgc_bad:
    mov x9, #-22
3:  ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
win_chdir:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    ARM_IMM x1, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, 1f
    mov x19, x9
    mov x0, x9
    ARM_CALL win_fchdir
    str x9, [sp, #24]
    mov x0, x19
    bl CloseHandle
    ldr x9, [sp, #24]
1:  ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
win_fchdir:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ARM_ADDR x1, win_cwd_w
    mov x2, #4096
    mov x3, #0
    bl GetFinalPathNameByHandleW
    cbz w0, 1f
    cmp w0, #4096
    b.hs 1f
    ARM_ADDR x0, win_cwd_w
    ARM_CALL win_drive_view
    tbnz x9, #63, 2f
    mov x0, x9
    bl SetCurrentDirectoryW
    cbz w0, 1f
    mov x9, #0
    b 2f
1:  ARM_CALL win_error
2:  ldp x29, x30, [sp], #16
    ret

/* One kernel directory entry becomes one bounded Linux-layout dirent64.
 * x0=directory HANDLE, x1=owned buffer, x2=capacity>=1024. x9=bytes/0/-errno.
 * No symlink is followed. Directory cursor belongs to the native handle.
 */
win_getdents:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #32]
    mov x19, x1
    cmp x2, #1024
    b.lo .Lwgd_fail
    mov x1, #0
    mov x2, #0
    mov x3, #0
    add x4, sp, #48
    ARM_ADDR x5, win_dir_entry
    mov x6, #2048
    mov x7, #1                   /* FileDirectoryInformation */
    sub sp, sp, #32             /* outgoing args9..11, not the saved frame */
    mov x10, #1
    str x10, [sp]
    str xzr, [sp, #8]
    str xzr, [sp, #16]
    bl NtQueryDirectoryFile
    add sp, sp, #32
    ARM_IMM w10, 0x80000006
    cmp w0, w10
    b.eq .Lwgd_end
    tbnz w0, #31, .Lwgd_nt
    ARM_ADDR x20, win_dir_entry
    ldr w3, [x20, #60]
    cmp w3, #510
    b.hi .Lwgd_fail
    lsr w3, w3, #1
    add x2, x20, #64
    add x4, x19, #19
    mov w0, #65001
    mov w1, #0x80
    mov w5, #1000
    mov x6, #0
    mov x7, #0
    bl WideCharToMultiByte
    cbz w0, .Lwgd_fail
    add x10, x19, #19
    strb wzr, [x10, x0]
    add x9, x0, #27
    and x9, x9, #-8
    str xzr, [x19]
    str xzr, [x19, #8]
    strh w9, [x19, #16]
    ldr w10, [x20, #56]
    mov w11, #8
    tst w10, #16
    b.eq 1f
    mov w11, #4
1:  tst w10, #0x400
    b.eq 2f
    mov w11, #10
2:  strb w11, [x19, #18]
    b .Lwgd_done
.Lwgd_nt:
    ARM_CALL win_nt_error
    b .Lwgd_done
.Lwgd_end:
    mov x9, #0
    b .Lwgd_done
.Lwgd_fail:
    mov x9, #-22
.Lwgd_done:
    ldp x19, x20, [sp, #32]
    ldp x29, x30, [sp], #80
    ret

/* x0=HANDLE, x1=flock flags. For regular files, LockFileEx implements shared
 * or exclusive advisory byte locking. A directory uses a private delete-on-
 * close child with share mode zero. Up to16 directory locks per CLI process.
 */
win_directory_lock:
    stp x29, x30, [sp, #-176]!
    mov x29, sp
    stp x19, x20, [sp, #32]
    stp x21, x22, [sp, #48]
    mov x19, x0
    mov x20, x1
    add x1, sp, #64
    bl GetFileInformationByHandle
    cbz w0, .Lwlock_error
    ldr w10, [sp, #64]
    tst w10, #16
    b.ne .Lwlock_directory
    stp xzr, xzr, [sp, #120]
    stp xzr, xzr, [sp, #136]
    mov x0, x19
    mov w1, #0
    tst x20, #2
    b.eq 1f
    orr w1, w1, #2
1:  tst x20, #4
    b.eq 2f
    orr w1, w1, #1
2:  mov w2, #0
    mov w3, #1
    mov w4, #0
    add x5, sp, #120
    bl LockFileEx
    cbz w0, .Lwlock_error
    mov x9, #0
    b .Lwlock_done
.Lwlock_directory:
    ARM_ADDR x21, win_dir_locks
    mov x22, #0
3:  cmp x22, #16
    b.hs .Lwlock_bad
    ldr x10, [x21]
    cbz x10, 4f
    add x21, x21, #16
    add x22, x22, #1
    b 3b
4:  /* UNICODE_STRING at64, OBJECT_ATTRIBUTES at80, IO_STATUS at128. */
    mov w10, #18
    strh w10, [sp, #64]
    strh w10, [sp, #66]
    ARM_ADDR x10, win_lock_name
    str x10, [sp, #72]
    mov w10, #48
    str w10, [sp, #80]
    str x19, [sp, #88]
    add x10, sp, #64
    str x10, [sp, #96]
    mov w10, #64
    str w10, [sp, #104]
    ARM_ADDR x10, win_private_sd
    str x10, [sp, #112]
    str xzr, [sp, #120]
    add x0, sp, #144
    ARM_IMM x1, 0x13019f
    add x2, sp, #80
    add x3, sp, #128
    mov x4, #0
    mov x5, #128
    mov x6, #0
    mov x7, #3
    sub sp, sp, #32             /* outgoing args9..11, not the saved frame */
    ARM_IMM x10, 0x201060        /* non-dir, sync, reparse, delete-on-close */
    str x10, [sp]
    str xzr, [sp, #8]
    str xzr, [sp, #16]
    bl NtCreateFile
    add sp, sp, #32
    tbnz w0, #31, .Lwlock_nt
    str x19, [x21]
    ldr x10, [sp, #144]
    str x10, [x21, #8]
    mov x9, #0
    b .Lwlock_done
.Lwlock_nt:
    ARM_CALL win_nt_error
    b .Lwlock_done
.Lwlock_error:
    ARM_CALL win_error
    b .Lwlock_done
.Lwlock_bad:
    mov x9, #-24
.Lwlock_done:
    ldp x21, x22, [sp, #48]
    ldp x19, x20, [sp, #32]
    ldp x29, x30, [sp], #176
    ret
/* x0=closing directory. Close its private lock handle first. */
win_unlock_close:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    ARM_ADDR x10, win_dir_locks
    mov x11, #16
1:  ldr x12, [x10]
    cmp x12, x19
    b.eq 2f
    add x10, x10, #16
    subs x11, x11, #1
    b.ne 1b
    b 3f
2:  ldr x0, [x10, #8]
    stp xzr, xzr, [x10]
    bl CloseHandle
3:  mov x0, x19
    bl CloseHandle
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
.section .rdata,"dr"
.p2align 1
win_lock_name: .hword 46,97,115,109,45,108,111,99,107,0
.section .bss
.p2align 3
win_cwd_w: .skip 8192
win_rename_w: .skip 8192
win_rename_utf8: .skip 4096
win_rename_info: .skip 8248
win_dir_entry: .skip 2048
win_dir_locks: .skip 256
.text
/* x0=UTF8 path. w9=1 for a drive-absolute C:/ form, else0. No changes.
 * Internal canonical paths use forward slashes; UNC/device namespaces and
 * drive-relative spellings are excluded from inventory and updater paths.
 */
win_is_absolute:
    ldrb w10, [x0]
    orr w10, w10, #32
    cmp w10, #97
    b.lo 1f
    cmp w10, #122
    b.hi 1f
    ldrb w10, [x0, #1]
    cmp w10, #58
    b.ne 1f
    ldrb w10, [x0, #2]
    cmp w10, #47
    b.eq 2f
    cmp w10, #92
    b.ne 1f
2:  mov w9, #1
    ret
1:  mov w9, #0
    ret
/* x0=validated C:/ path. x9=process-owned mutable root spelling (4 bytes).
 * Callers must use the returned pointer before another root construction.
 */
win_drive_root:
    ARM_ADDR x9, win_drive_path
    ldrb w10, [x0]
    strb w10, [x9]
    mov w10, #58
    strb w10, [x9, #1]
    mov w10, #47
    strb w10, [x9, #2]
    strb wzr, [x9, #3]
    ret
.section .data
win_drive_path: .asciz "C:/"
.text
/* Normalize separators in an owned NUL-terminated path. Arguments other than
 * paths do not pass through this routine. x0 preserved; x9/x10 scratch. */
win_slashes:
    mov x9, #0
1:  ldrb w10, [x0, x9]
    cbz w10, 3f
    cmp w10, #92
    b.ne 2f
    mov w10, #47
    strb w10, [x0, x9]
2:  add x9, x9, #1
    b 1b
3:  ret
/* x0=bounded UTF16 component, x1=byte length. Return w9=0 for a reserved DOS
 * device basename, otherwise1. A suffix after '.' does not make it valid.
 * Rejects CON, PRN, AUX, NUL, COM1..9, LPT1..9, and superscript digits1..3.
 */
win_component_name:
    mov x12, #0
    mov w13, #0
1:  cmp x12, x1
    b.hs 2f
    ldrh w10, [x0, x12]
    cmp w10, #46
    b.eq 2f
    add w13, w13, #1
    add x12, x12, #2
    b 1b
2:  cmp w13, #3
    b.lo 8f
    cmp w13, #4
    b.hi 8f
    ldrh w10, [x0]
    ldrh w11, [x0, #2]
    ldrh w12, [x0, #4]
    orr w10, w10, #32
    orr w11, w11, #32
    orr w12, w12, #32
    orr w10, w10, w11, lsl #8
    orr w10, w10, w12, lsl #16
    cmp w13, #4
    b.eq 4f
    ARM_IMM w11, 0x6e6f63       /* con */
    cmp w10, w11
    b.eq 9f
    ARM_IMM w11, 0x6e7270       /* prn */
    cmp w10, w11
    b.eq 9f
    ARM_IMM w11, 0x787561       /* aux */
    cmp w10, w11
    b.eq 9f
    ARM_IMM w11, 0x6c756e       /* nul */
    cmp w10, w11
    b.eq 9f
    b 8f
4:  ARM_IMM w11, 0x6d6f63       /* com */
    cmp w10, w11
    b.eq 5f
    ARM_IMM w11, 0x74706c       /* lpt */
    cmp w10, w11
    b.ne 8f
5:  ldrh w10, [x0, #6]
    cmp w10, #49
    b.lo 6f
    cmp w10, #57
    b.ls 9f
6:  cmp w10, #0xb9
    b.eq 9f
    cmp w10, #0xb2
    b.eq 9f
    cmp w10, #0xb3
    b.eq 9f
8:  mov w9, #1
    ret
9:  mov w9, #0
    ret
/* Extra Windows archive name gate, after the shared bounded ASCII path gate.
 * x0=validatedrelativepath, w9=0 valid/1 invalid. No input is changed.
 */
win_archive_names:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x0
1:  ldrb w10, [x20]
    cbz w10, 2f
    cmp w10, #47
    b.eq 2f
    add x20, x20, #1
    b 1b
2:  sub x1, x20, x19
    ARM_ADDR x0, win_archive_component
    mov x2, #0
3:  cmp x2, x1
    b.hs 4f
    ldrb w10, [x19, x2]
    strh w10, [x0, x2, lsl #1]
    add x2, x2, #1
    b 3b
4:  lsl x1, x1, #1
    ARM_CALL win_component_name
    cbz w9, 6f
    ldrb w10, [x20]
    cbz w10, 5f
    add x20, x20, #1
    mov x19, x20
    b 1b
5:  mov w9, #0
    b 7f
6:  mov w9, #1
7:  ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
.section .bss
.p2align 3
win_archive_component: .skip 512

.text
/* x0=borrowed source/test/check path, parser-bounded to255 UTF8 bytes.
 * w9=1 valid/0 invalid. Preserve x19-x21; stack48. Shared syntax rejects
 * traversal, option and response-file components. Then reject Windows drive,
 * device, stream and trailing aliases before any compiler/output mutation.
 * Strict UTF8 conversion borrows single-threaded win_path_w[4096 WCHARs]. */
win_valid_source:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    ARM_CALL win_shared_valid_source
    cbz w9, .Lwvs_bad
    mov x0, x19
    ARM_ADDR x1, win_path_w
    mov x2, #4096
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwvs_bad
    ARM_ADDR x19, win_path_w
    mov x20, x19
.Lwvs_scan:
    ldrh w10, [x20]
    cbz w10, .Lwvs_component
    cmp w10, #47
    b.eq .Lwvs_component
    cmp w10, #32
    b.lo .Lwvs_bad
    cmp w10, #92
    b.eq .Lwvs_bad
    cmp w10, #58
    b.eq .Lwvs_bad
    cmp w10, #34
    b.eq .Lwvs_bad
    cmp w10, #42
    b.eq .Lwvs_bad
    cmp w10, #63
    b.eq .Lwvs_bad
    cmp w10, #60
    b.eq .Lwvs_bad
    cmp w10, #62
    b.eq .Lwvs_bad
    cmp w10, #124
    b.eq .Lwvs_bad
    add x20, x20, #2
    b .Lwvs_scan
.Lwvs_component:
    sub x1, x20, x19
    cbz x1, .Lwvs_bad
    ldrh w10, [x20, #-2]
    cmp w10, #46
    b.eq .Lwvs_bad
    cmp w10, #32
    b.eq .Lwvs_bad
    mov x0, x19
    ARM_CALL win_component_name
    cbz w9, .Lwvs_bad
    ldrh w10, [x20]
    cbz w10, .Lwvs_good
    add x19, x20, #2
    mov x20, x19
    b .Lwvs_scan
.Lwvs_good:
    mov w9, #1
    b .Lwvs_done
.Lwvs_bad:
    mov w9, #0
.Lwvs_done:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
