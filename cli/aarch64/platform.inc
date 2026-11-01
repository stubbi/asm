/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native Linux AArch64 internal ABI. No instruction interpreter is used.
 * Arguments: x0-x7. Result: x9. Preserved: x19-x24 and SP.
 * x8 and x10-x17 are scratch; x29 is unused; x30 is the native link register.
 * Each stack reservation is a multiple of 16. ARM_CALL preserves the caller's
 * x30 around BL, so leaf and nested routines both return with native RET.
 * NZCV is scratch unless a routine explicitly documents its carry result.
 * Per-routine scratch lists add to x8/x10-x17/NZCV. Stack counts describe
 * local reservations; ARM_CALL frames and called routines are additional.
 */
.arch armv8-a

.macro ARM_CALL target
    str x30, [sp, #-16]!
    bl \target
    ldr x30, [sp], #16
.endm

.macro ARM_CALL_REG target
    str x30, [sp, #-16]!
    blr \target
    ldr x30, [sp], #16
.endm

.macro ARM_SAVE reg
    str \reg, [sp, #-16]!
.endm

.macro ARM_RESTORE reg
    ldr \reg, [sp], #16
.endm

/* Materialize an assembly-time integer without a literal pool or flag change.
 * The expression must be defined before use. Both W and X registers are valid.
 */
.macro ARM_IMM reg, value
    .set .Larm_imm_word\@, 0
    .irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
        .ifc \reg,w\n
            .set .Larm_imm_word\@, 1
        .endif
    .endr
    .if (\value) >= 0 && (\value) <= 65535
        movz \reg, #((\value) & 65535)
    .elseif (\value) < 0 && (\value) >= -65536
        movn \reg, #((~(\value)) & 65535)
    .else
        movz \reg, #((\value) & 65535)
        .if (((\value) >> 16) & 65535) != 0
            movk \reg, #(((\value) >> 16) & 65535), lsl #16
        .endif
        .if .Larm_imm_word\@ == 0
            .if (((\value) >> 32) & 65535) != 0
                movk \reg, #(((\value) >> 32) & 65535), lsl #32
            .endif
            .if (((\value) >> 48) & 65535) != 0
                movk \reg, #(((\value) >> 48) & 65535), lsl #48
            .endif
        .endif
    .endif
.endm

.macro ARM_ADDR reg, symbol
    adrp \reg, \symbol
    add \reg, \reg, :lo12:\symbol
.endm

/* Values verified against linux-libc-dev-arm64-cross UAPI headers. */
.equ O_NOFOLLOW, 32768
.equ O_DIRECTORY, 16384
.equ O_CLOEXEC, 524288
.equ O_NONBLOCK, 2048
.equ ARM_STAT_BYTES, 128
.equ ARM_STAT_DEVICE, 0
.equ ARM_STAT_INODE, 8
.equ ARM_STAT_MODE, 16
.equ ARM_STAT_LINKS, 20
.equ ARM_STAT_UID, 24
.equ ARM_STAT_GID, 28
.equ ARM_STAT_SIZE, 48
