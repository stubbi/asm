/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Held SHA-256: x0=borrowed fd, x1=exact size1..64MiB, x2=owned hex65.
 * x9=0/1. Seeks from zero; checks metadata and complete stream length.
 * Never closes the borrowed fd. Owns/closes BCrypt handles on every exit.
 * Preserves x19-x24; stack128. win_hash_file remains the path convenience
 * adapter for package workflows and owns its independently opened fd.
 */
.text
win_hash_file:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    mov x19,x1
    ARM_IMM x1,O_CLOEXEC + O_NOFOLLOW + O_NONBLOCK
    mov x2,#0
    ARM_CALL arm_open
    tbnz x9,#63,.Lwhf_fail
    mov x20,x9
    mov x0,x20
    ARM_ADDR x1,win_hash_stat
    ARM_CALL arm_fstat
    cbnz x9,.Lwhf_close_fail
    ARM_ADDR x16,win_hash_stat
    ldr x1,[x16,#ARM_STAT_SIZE]
    mov x0,x20
    mov x2,x19
    ARM_CALL win_hash_fd
    str x9,[sp,#32]
    mov x0,x20
    ARM_CALL arm_close
    ldr x9,[sp,#32]
    b .Lwhf_done
.Lwhf_close_fail:
    mov x0,x20
    ARM_CALL arm_close
.Lwhf_fail:
    mov x9,#1
.Lwhf_done:
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret
win_hash_fd:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x2
    mov x20, x0
    mov x24, x1
    mov x21, #0
    mov x22, #0
    mov x23, #1
    cbz x24, .Lwh_close
    ARM_IMM x10, 67108864
    cmp x24, x10
    b.hi .Lwh_close
    ARM_ADDR x1, win_hash_stat
    ARM_CALL arm_fstat
    cbnz x9, .Lwh_close
    ARM_ADDR x16, win_hash_stat
    ldr w10, [x16, #ARM_STAT_MODE]
    and w10, w10, #61440
    cmp w10, #32768
    b.ne .Lwh_close
    ldr x10, [x16, #ARM_STAT_SIZE]
    cmp x10, x24
    b.ne .Lwh_close
    mov x0, x20
    mov x1, #0
    mov x2, #0
    ARM_CALL arm_lseek
    cbnz x9, .Lwh_close
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
3:  mov x9, x23
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
