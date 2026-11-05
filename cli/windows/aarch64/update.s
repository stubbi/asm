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
