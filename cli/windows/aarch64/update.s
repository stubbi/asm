/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Windows updater platform checks. Shared assembly retains provenance policy,
 * source/signer binding, rollback limits, and exact signed metadata parser.
 */
.text
/* readlink-compatible result: actual image UTF8 path without NUL counted.
 * x1=owned4096 output, x2=max4095 bytes. UTF16 source capacity4096 WCHARs.
 */
win_read_running_image:
    WIN_SAVE
    sub sp, sp, #16
    str x1, [sp]
    str x2, [sp, #8]
    mov x0, #0
    ARM_ADDR x1, win_running_w
    mov x2, #4096
    bl GetModuleFileNameW
    cbz w0, 1f
    cmp w0, #4096
    b.hs 1f
    mov w0, #65001
    mov w1, #0x80
    ARM_ADDR x2, win_running_w
    mov w3, #-1
    ldr x4, [sp]
    ldr x5, [sp, #8]
    add x5, x5, #1
    mov x6, #0
    mov x7, #0
    bl WideCharToMultiByte
    cbz w0, 1f
    sub x9, x0, #1
    ldr x1, [sp]
    mov x2, #0
2:  cmp x2, x9
    b.hs 4f
    ldrb w10, [x1, x2]
    cmp w10, #92
    b.ne 3f
    mov w10, #47
    strb w10, [x1, x2]
3:  add x2, x2, #1
    b 2b
1:  mov x9, #-22
4:  add sp, sp, #16
    WIN_RETURN
/* x0=held parent directory. x9=0 only for a local NTFS volume, otherwise-1.
 * GetVolumeInformationByHandleW establishes filesystem type. GetDriveTypeW
 * on the final volume root rejects network/remote drives. Stack=64.
 */
win_require_ntfs:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    ARM_ADDR x6, win_fs_name
    mov x7, #32
    bl GetVolumeInformationByHandleW
    cbz w0, 1f
    ARM_ADDR x16, win_fs_name
    ldr x10, [x16]
    ARM_IMM x11, 0x005300460054004e
    cmp x10, x11
    b.ne 1f
    ldrh w10, [x16, #8]
    cbnz w10, 1f
    mov x0, x19
    ARM_ADDR x1, win_volume_path
    mov x2, #4096
    mov x3, #0
    bl GetFinalPathNameByHandleW
    cbz w0, 1f
    cmp w0, #4096
    b.hs 1f
    ARM_ADDR x0, win_volume_path
    /* GetFinalPathName yields \\?\C:\...; truncate after drive root. */
    ldrh w10, [x0, #10]
    cmp w10, #58
    b.ne 1f
    strh wzr, [x0, #14]
    bl GetDriveTypeW
    cmp w0, #3                  /* DRIVE_FIXED */
    b.ne 1f
    mov x9, #0
    b 2f
1:  mov x9, #-1
2:  ldr x19, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
.section .bss
.p2align 3
win_running_w: .skip 8192
win_fs_name: .skip 64
win_volume_path: .skip 8192

.text
/* Convert the private verifier environment to bounded native drive paths.
 * Inputs: four owned self_*_environment[8192] strings built by shared code.
 * x9=0/-22. Preserves x19-x22; stack48. New profile variables point only to
 * the same newly created verifier directory; no ambient profile is copied. */
win_prepare_verifier_environment:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    ARM_ADDR x19, win_verifier_path_values
    mov x20, #4
.Lwvpe_value:
    ldr x21, [x19], #8
    mov x0, x21
    ARM_CALL win_is_absolute
    cbz w9, .Lwvpe_bad
    mov x22, #0
.Lwvpe_bound:
    ARM_IMM x10, 8170
    cmp x22, x10
    b.hs .Lwvpe_bad
    ldrb w10, [x21, x22]
    cbz w10, .Lwvpe_next
    add x22, x22, #1
    b .Lwvpe_bound
.Lwvpe_next:
    mov x0, x21
    ARM_CALL win_slashes
    subs x20, x20, #1
    b.ne .Lwvpe_value
    ARM_ADDR x0, win_profile_environment
    ARM_ADDR x1, win_profile_prefix
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, self_home_environment + 5
    ARM_CALL copy_string
    ARM_ADDR x0, win_localappdata_environment
    ARM_ADDR x1, win_localappdata_prefix
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, self_home_environment + 5
    ARM_CALL copy_string
    mov x9, #0
    b .Lwvpe_done
.Lwvpe_bad:
    mov x9, #-22
.Lwvpe_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
.section .rdata,"dr"
.p2align 3
win_verifier_path_values:
    .quad self_home_environment + 5, self_config_environment + 14
    .quad self_cache_environment + 15, self_xdg_environment + 16
win_profile_prefix: .asciz "USERPROFILE="
win_localappdata_prefix: .asciz "LOCALAPPDATA="
.section .bss
.p2align 3
win_profile_environment: .skip 8192
win_localappdata_environment: .skip 8192

.text
/* x0=retained self_current_fd with FILE_EXECUTE|SYNCHRONIZE and read rights.
 * x9=0 exact creation image, -116 observed mismatch, -95 unsupported/error.
 * Preserve x0-x7/x19-x29; stack128. Runtime-resolve only loaded ntdll's fixed
 * NtQueryInformationProcess. Class44 consumes an INPUT pointer to our handle,
 * exactly8bytes. Accept only STATUS_SUCCESS0; never use a pathname fallback.
 * The native Windows11 fixture observed class44 match and mismatch results.
 * This adapter still needs native qualification; class44 is no Win32 promise.
 */
win_image_matches:
    WIN_SAVE
    sub sp, sp, #32
    str x0, [sp]
    ARM_ADDR x0, win_ntdll_name
    bl GetModuleHandleW
    cbz x0, .Lwim_unsupported
    ARM_ADDR x1, win_image_query_name
    bl GetProcAddress
    cbz x0, .Lwim_unsupported
    mov x16, x0
    mov x0, #-1
    mov w1, #44
    mov x2, sp
    mov w3, #8
    mov x4, #0
    blr x16
    cbz w0, .Lwim_match
    ARM_IMM w10, 0xc0000001
    cmp w0, w10
    b.ne .Lwim_unsupported
    mov x9, #-116
    b .Lwim_done
.Lwim_match:
    mov x9, #0
    b .Lwim_done
.Lwim_unsupported:
    mov x9, #-95
.Lwim_done:
    add sp, sp, #32
    WIN_RETURN
.section .rdata,"dr"
.p2align 1
win_ntdll_name: .hword 110,116,100,108,108,46,100,108,108,0
win_image_query_name: .asciz "NtQueryInformationProcess"
