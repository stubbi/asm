/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native RV64IM/LP64 Linux internal ABI; this is not the C calling convention.
 * Arguments:a0-a7. Result:t0. Preserved:s0-s5,sp,gp,tp. The remaining registers
 * are scratch. s8/s10/s11 are reserved instruction-expansion temporaries; s9
 * holds transient NZCV conditions (N=8,Z=4,C=2,V=1). No instruction interpreter
 * or runtime backend exists. These macros expand into native RV64 instructions.
 * Stack reservations are16-byte aligned. Calls save ra in one16-byte frame.
 * RV word operations explicitly zero-extend; RV psABI C word arguments instead
 * use their own sign-extension rules. Unaligned file data uses byte accesses.
 */
.attribute arch, "rv64im"
.option arch, rv64im
.option norelax
.macro RV_CALL target
    addi sp, sp, -16
    sd ra, 0(sp)
    call \target
    ld ra, 0(sp)
    addi sp, sp, 16
.endm
.macro RV_CALL_REG target
    addi sp, sp, -16
    sd ra, 0(sp)
    jalr ra, \target, 0
    ld ra, 0(sp)
    addi sp, sp, 16
.endm
.macro RV_SAVE reg
    addi sp, sp, -16
    sd \reg, 0(sp)
.endm
.macro RV_RESTORE reg
    ld \reg, 0(sp)
    addi sp, sp, 16
.endm
.macro RV_ZEXT reg
    slli \reg, \reg, 32
    srli \reg, \reg, 32
.endm
.macro RV_IMM reg,value,width=64
    li \reg, \value
    .if \width == 32
        RV_ZEXT \reg
    .endif
.endm
.macro RV_ADDR reg,symbol
    lla \reg, \symbol
.endm
/* s8/s10 contain operands. Result s11. Only reserved scratch changes. */
.macro RV_FLAGS operation,width=64
    .if \width == 32
        RV_ZEXT s8
        RV_ZEXT s10
    .endif
    .ifc \operation,add
        add s11, s8, s10
    .else
        .ifc \operation,sub
            sub s11, s8, s10
        .else
            and s11, s8, s10
        .endif
    .endif
    .if \width == 32
        RV_ZEXT s11
    .endif
    .ifc \operation,add
        sltu s9, s11, s8
        slli s9, s9, 1
        xor s10, s8, s10
        not s10, s10
        xor s8, s8, s11
        and s8, s8, s10
        srli s8, s8, (\width - 1)
        andi s8, s8, 1
        or s9, s9, s8
    .else
        .ifc \operation,sub
            sltu s9, s8, s10
            xori s9, s9, 1
            slli s9, s9, 1
            xor s10, s8, s10
            xor s8, s8, s11
            and s8, s8, s10
            srli s8, s8, (\width - 1)
            andi s8, s8, 1
            or s9, s9, s8
        .else
            li s9, 0
        .endif
    .endif
    srli s8, s11, (\width - 1)
    andi s8, s8, 1
    slli s8, s8, 3
    or s9, s9, s8
    seqz s8, s11
    slli s8, s8, 2
    or s9, s9, s8
.endm
/* The condition is checked locally; tail supplies a full PC-relative reach. */
.macro RV_BCOND condition,target
    .ifc \condition,eq
        andi s8, s9, 4
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,ne
        andi s8, s9, 4
        bnez s8, .Lrv_skip\@
    .else
    .ifc \condition,cs
        andi s8, s9, 2
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,hs
        andi s8, s9, 2
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,lo
        andi s8, s9, 2
        bnez s8, .Lrv_skip\@
    .else
    .ifc \condition,cc
        andi s8, s9, 2
        bnez s8, .Lrv_skip\@
    .else
    .ifc \condition,mi
        andi s8, s9, 8
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,pl
        andi s8, s9, 8
        bnez s8, .Lrv_skip\@
    .else
    .ifc \condition,hi
        andi s8, s9, 6
        li s10, 2
        bne s8, s10, .Lrv_skip\@
    .else
    .ifc \condition,ls
        andi s8, s9, 6
        li s10, 2
        beq s8, s10, .Lrv_skip\@
    .else
    .ifc \condition,ge
        srli s8, s9, 3
        xor s8, s8, s9
        andi s8, s8, 1
        bnez s8, .Lrv_skip\@
    .else
    .ifc \condition,lt
        srli s8, s9, 3
        xor s8, s8, s9
        andi s8, s8, 1
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,gt
        andi s8, s9, 4
        bnez s8, .Lrv_skip\@
        srli s8, s9, 3
        xor s8, s8, s9
        andi s8, s8, 1
        bnez s8, .Lrv_skip\@
    .else
    .ifc \condition,le
        andi s8, s9, 4
        bnez s8, .Lrv_take\@
        srli s8, s9, 3
        xor s8, s8, s9
        andi s8, s8, 1
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,vs
        andi s8, s9, 1
        beqz s8, .Lrv_skip\@
    .else
    .ifc \condition,vc
        andi s8, s9, 1
        bnez s8, .Lrv_skip\@
    .else
        .error "unsupported RV condition"
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
    .endif
.Lrv_take\@:
    tail \target
.Lrv_skip\@:
.endm
/* Address s8 is stable before these macros. Preserve arithmetic conditions.
 * All reads/writes use bytes, so unaligned untrusted records remain portable.
 */
.macro RV_LOAD reg,size
    li \reg, 0
    .irp offset,0,1,2,3,4,5,6,7
        .if \offset < \size
            lbu s11, \offset(s8)
            .if \offset != 0
                slli s11, s11, (8*\offset)
            .endif
            or \reg, \reg, s11
        .endif
    .endr
.endm
.macro RV_STORE reg,size
    mv s11, \reg
    .irp offset,0,1,2,3,4,5,6,7
        .if \offset < \size
            sb s11, \offset(s8)
            .if \offset != (\size-1)
                srli s11, s11, 8
            .endif
        .endif
    .endr
.endm
/* RV64 Linux UAPI, checked against Linuxv6.8 asm-generic interfaces. */
.equ O_NOFOLLOW, 131072
.equ O_DIRECTORY, 65536
.equ O_CLOEXEC, 524288
.equ O_NONBLOCK, 2048
.equ RV_STAT_BYTES, 128
.equ RV_STAT_DEVICE, 0
.equ RV_STAT_INODE, 8
.equ RV_STAT_MODE, 16
.equ RV_STAT_LINKS, 20
.equ RV_STAT_UID, 24
.equ RV_STAT_GID, 28
.equ RV_STAT_SIZE, 48
