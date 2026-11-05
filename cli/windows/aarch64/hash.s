/* SPDX-License-Identifier: AGPL-3.0-or-later
 * BCrypt SHA-256 over an opened no-reparse regular file. No external process,
 * ambient digest configuration, filename parser, or package code is involved.
 * x0=UTF8 path, x1=owned65-byte lowercase hex output. x9=0 success/1 failure.
 * Input is at most64MiB; verifies exact stream length against opened identity.
 * Stack=128 plus adapters; hash provider/object/handle always close.
 */
.text
win_hash_file:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x1
    mov x20, #-1
    mov x21, #0
    mov x22, #0
    mov x23, #1
    ARM_IMM x1, O_CLOEXEC + O_NOFOLLOW + O_NONBLOCK
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, .Lwh_close
    mov x20, x9
    mov x0, x20
    ARM_ADDR x1, win_hash_stat
    ARM_CALL arm_fstat
    cbnz x9, .Lwh_close
    ARM_ADDR x16, win_hash_stat
    ldr w10, [x16, #ARM_STAT_MODE]
    and w10, w10, #61440
    cmp w10, #32768
    b.ne .Lwh_close
    ldr x24, [x16, #ARM_STAT_SIZE]
    ARM_IMM x10, 67108864
    cmp x24, x10
    b.hi .Lwh_close
    add x0, sp, #64
    ARM_ADDR x1, win_sha256_w
    mov x2, #0
    mov x3, #0
    bl BCryptOpenAlgorithmProvider
    tbnz w0, #31, .Lwh_close
    ldr x21, [sp, #64]
    mov x0, x21
    add x1, sp, #72
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    mov x6, #0
    bl BCryptCreateHash
    tbnz w0, #31, .Lwh_close
    ldr x22, [sp, #72]
    str xzr, [sp, #80]
.Lwh_read:
    mov x0, x20
    ARM_ADDR x1, win_hash_buffer
    ARM_IMM x2, 65536
    ARM_CALL arm_read
    tbnz x9, #63, .Lwh_close
    cbz x9, .Lwh_finish
    ldr x10, [sp, #80]
    add x10, x10, x9
    cmp x10, x24
    b.hi .Lwh_close
    str x10, [sp, #80]
    mov x0, x22
    ARM_ADDR x1, win_hash_buffer
    mov x2, x9
    mov x3, #0
    bl BCryptHashData
    tbnz w0, #31, .Lwh_close
    b .Lwh_read
.Lwh_finish:
    ldr x10, [sp, #80]
    cmp x10, x24
    b.ne .Lwh_close
    mov x0, x22
    add x1, sp, #88
    mov x2, #32
    mov x3, #0
    bl BCryptFinishHash
    tbnz w0, #31, .Lwh_close
    mov x0, #0
    add x1, sp, #88
    ARM_ADDR x2, win_hex_digits
1:  ldrb w10, [x1, x0]
    lsr w11, w10, #4
    and w10, w10, #15
    ldrb w11, [x2, x11]
    ldrb w10, [x2, x10]
    strb w11, [x19], #1
    strb w10, [x19], #1
    add x0, x0, #1
    cmp x0, #32
    b.lo 1b
    strb wzr, [x19]
    mov x23, #0
.Lwh_close:
    cbz x22, 2f
    mov x0, x22
    bl BCryptDestroyHash
2:  cbz x21, 3f
    mov x0, x21
    mov x1, #0
    bl BCryptCloseAlgorithmProvider
3:  tbnz x20, #63, 4f
    mov x0, x20
    ARM_CALL arm_close
4:  mov x9, x23
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #128
    ret
.section .rdata,"dr"
.p2align 1
win_sha256_w: .hword 83,72,65,50,53,54,0
win_hex_digits: .ascii "0123456789abcdef"
.section .bss
.p2align 3
win_hash_stat: .skip 128
win_hash_buffer: .skip 65536
