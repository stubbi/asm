/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Typed RV64 Linux syscall adapters. Native ECALL, no syscall interpreter.
 * Inputs:a0,a1,a2,a6,a4,a5. Result:t0=kernel result/negative errno.
 * Preserve a0-a7 and s0-s5/sp/gp/tp. Scratch:t1-t6,s6-s11. Local stack64
 * bytes; alarm uses128. Caller retains pointer/buffer ownership and bounds.
 */
.section .text
.macro RV_SYSCALL_SAVE
    addi sp, sp, -64
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    sd a6, 48(sp)
    sd a7, 56(sp)
.endm
.macro RV_SYSCALL_RETURN
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    ld a6, 48(sp)
    ld a7, 56(sp)
    addi sp, sp, 64
    ret
.endm
.macro RV_SYSCALL name,number
\name:
    RV_SYSCALL_SAVE
    mv a3, a6
    li a7, \number
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
.endm
RV_SYSCALL rv_read, 63
RV_SYSCALL rv_write, 64
RV_SYSCALL rv_close, 57
RV_SYSCALL rv_fstat, 80
RV_SYSCALL rv_probe_fd_stat, 80
RV_SYSCALL rv_probe_stat, 79
RV_SYSCALL rv_lseek, 62
RV_SYSCALL rv_openat, 56
RV_SYSCALL rv_mkdirat, 34
RV_SYSCALL rv_unlinkat, 35
RV_SYSCALL rv_renameat2, 276
RV_SYSCALL rv_fchmod, 52
RV_SYSCALL rv_fsync, 82
RV_SYSCALL rv_fcntl, 25
RV_SYSCALL rv_flock, 32
RV_SYSCALL rv_getdents64, 61
RV_SYSCALL rv_pipe2, 59
RV_SYSCALL rv_kill, 129
RV_SYSCALL rv_execve, 221
RV_SYSCALL rv_wait4, 260
RV_SYSCALL rv_getpid, 172
RV_SYSCALL rv_getcwd, 17
RV_SYSCALL rv_chdir, 49
RV_SYSCALL rv_fchdir, 50
RV_SYSCALL rv_getuid, 174
RV_SYSCALL rv_geteuid, 175
RV_SYSCALL rv_getgid, 176
RV_SYSCALL rv_getegid, 177
RV_SYSCALL rv_getrandom, 278
RV_SYSCALL rv_umask, 166
RV_SYSCALL rv_uname, 160
RV_SYSCALL rv_getrlimit, 163
RV_SYSCALL rv_setrlimit, 164
RV_SYSCALL rv_rt_sigaction, 134
RV_SYSCALL rv_rt_sigprocmask, 135
RV_SYSCALL rv_fstatfs, 44
RV_SYSCALL rv_mmap, 222
RV_SYSCALL rv_mprotect, 226
RV_SYSCALL rv_munmap, 215
RV_SYSCALL rv_readlinkat, 78
RV_SYSCALL rv_prlimit64, 261
RV_SYSCALL rv_newfstatat, 79
rv_exit:
    li a7, 93
    ecall
    ebreak
rv_open:
    RV_SYSCALL_SAVE
    mv a3, a2
    mv a2, a1
    mv a1, a0
    li a0, -100
    li a7, 56
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_lstat:
    RV_SYSCALL_SAVE
    mv a2, a1
    mv a1, a0
    li a0, -100
    li a3, 256
    li a7, 79
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_access:
    RV_SYSCALL_SAVE
    mv a2, a1
    mv a1, a0
    li a0, -100
    li a7, 48
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_mkdir:
    RV_SYSCALL_SAVE
    mv a2, a1
    mv a1, a0
    li a0, -100
    li a7, 34
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_unlink:
    RV_SYSCALL_SAVE
    mv a1, a0
    li a0, -100
    li a2, 0
    li a7, 35
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_rmdir:
    RV_SYSCALL_SAVE
    mv a1, a0
    li a0, -100
    li a2, 512
    li a7, 35
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
/* RISC-V omits legacy renameat. Use renameat2 with explicit zero flags. */
rv_renameat:
    RV_SYSCALL_SAVE
    mv a3, a6
    li a4, 0
    li a7, 276
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_rename:
    RV_SYSCALL_SAVE
    mv a3, a1
    mv a1, a0
    li a0, -100
    li a2, -100
    li a4, 0
    li a7, 276
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_chmod:
    RV_SYSCALL_SAVE
    mv a2, a1
    mv a1, a0
    li a0, -100
    li a7, 53
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_readlink:
    RV_SYSCALL_SAVE
    mv a3, a2
    mv a2, a1
    mv a1, a0
    li a0, -100
    li a7, 78
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_fork:
    RV_SYSCALL_SAVE
    li a0, 17
    li a1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a7, 220
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
rv_dup2:
    RV_SYSCALL_SAVE
    beq a0, a1, .Lrv_dup2_equal
    li a2, 0
    li a7, 24
    ecall
    mv t0, a0
    RV_SYSCALL_RETURN
.Lrv_dup2_equal:
    li a1, 1
    li a7, 25
    ecall
    mv t0, a0
    bltz t0, .Lrv_dup2_done
    ld t0, 0(sp)
.Lrv_dup2_done:
    RV_SYSCALL_RETURN
rv_alarm:
    RV_SYSCALL_SAVE
    addi sp, sp, -64
    sd zero, 0(sp)
    sd zero, 8(sp)
    sd a0, 16(sp)
    sd zero, 24(sp)
    li a0, 0
    mv a1, sp
    addi a2, sp, 32
    li a7, 103
    ecall
    mv t0, a0
    bltz t0, .Lrv_alarm_done
    ld t0, 48(sp)
    ld t1, 56(sp)
    beqz t1, .Lrv_alarm_done
    addi t0, t0, 1
.Lrv_alarm_done:
    addi sp, sp, 64
    RV_SYSCALL_RETURN
.section .note.GNU-stack,""
