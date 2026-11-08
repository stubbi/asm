/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Typed Linux AArch64 syscall adapters. These routines contain native SVC.
 * Inputs use the CLI's documented argument roles: x0,x1,x2,x6,x4,x5.
 * Output x9 is the kernel result or a negative errno. x0-x7 are preserved.
 * Scratch: x8,x10-x17,NZCV. Stack: 64 bytes; alarm uses 64 more bytes.
 * All pointer ownership, capacities, and operation-specific flags remain the
 * caller's responsibility. No adapter constructs or executes a shell command.
 */
.section .text

.macro ARM_SYSCALL_SAVE
    stp x0, x1, [sp, #-64]!
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
.endm
.macro ARM_SYSCALL_RETURN
    ldp x0, x1, [sp]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    add sp, sp, #64
    ret
.endm
.macro ARM_SYSCALL name, number
\name:
    ARM_SYSCALL_SAVE
    mov x3, x6
    mov x8, #\number
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN
.endm

ARM_SYSCALL arm_read, 63
ARM_SYSCALL arm_write, 64
ARM_SYSCALL arm_close, 57
ARM_SYSCALL arm_fstat, 80
/* Probe-only identity inspection. Never authorizes an untrusted file. */
ARM_SYSCALL arm_probe_fd_stat, 80
ARM_SYSCALL arm_probe_stat, 79
ARM_SYSCALL arm_lseek, 62
ARM_SYSCALL arm_openat, 56
ARM_SYSCALL arm_mkdirat, 34
ARM_SYSCALL arm_unlinkat, 35
ARM_SYSCALL arm_renameat, 38
ARM_SYSCALL arm_renameat2, 276
ARM_SYSCALL arm_fchmod, 52
ARM_SYSCALL arm_fsync, 82
ARM_SYSCALL arm_fcntl, 25
ARM_SYSCALL arm_flock, 32
ARM_SYSCALL arm_getdents64, 61
ARM_SYSCALL arm_pipe2, 59
ARM_SYSCALL arm_kill, 129
ARM_SYSCALL arm_execve, 221
ARM_SYSCALL arm_wait4, 260
ARM_SYSCALL arm_getpid, 172
ARM_SYSCALL arm_getcwd, 17
ARM_SYSCALL arm_chdir, 49
ARM_SYSCALL arm_fchdir, 50
ARM_SYSCALL arm_getuid, 174
ARM_SYSCALL arm_geteuid, 175
ARM_SYSCALL arm_getgid, 176
ARM_SYSCALL arm_getegid, 177
ARM_SYSCALL arm_getrandom, 278
ARM_SYSCALL arm_umask, 166
ARM_SYSCALL arm_uname, 160
ARM_SYSCALL arm_getrlimit, 163
ARM_SYSCALL arm_setrlimit, 164
ARM_SYSCALL arm_rt_sigaction, 134
ARM_SYSCALL arm_rt_sigprocmask, 135
ARM_SYSCALL arm_fstatfs, 44
ARM_SYSCALL arm_mmap, 222
ARM_SYSCALL arm_mprotect, 226
ARM_SYSCALL arm_munmap, 215
ARM_SYSCALL arm_readlinkat, 78
ARM_SYSCALL arm_prlimit64, 261

arm_exit:
    mov x8, #93
    svc #0
    brk #0

/* open(path, flags, mode) -> openat(AT_FDCWD, path, flags, mode). */
arm_open:
    ARM_SYSCALL_SAVE
    mov x3, x2
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x8, #56
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

/* lstat(path, stat) -> newfstatat without following the final symlink. */
arm_lstat:
    ARM_SYSCALL_SAVE
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x3, #256
    mov x8, #79
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN
ARM_SYSCALL arm_newfstatat, 79

arm_access:
    ARM_SYSCALL_SAVE
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x8, #48
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

arm_mkdir:
    ARM_SYSCALL_SAVE
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x8, #34
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

arm_unlink:
    ARM_SYSCALL_SAVE
    mov x1, x0
    mov x0, #-100
    mov x2, #0
    mov x8, #35
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

arm_rmdir:
    ARM_SYSCALL_SAVE
    mov x1, x0
    mov x0, #-100
    mov x2, #512
    mov x8, #35
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

arm_rename:
    ARM_SYSCALL_SAVE
    mov x3, x1
    mov x1, x0
    mov x0, #-100
    mov x2, #-100
    mov x8, #38
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

/* link(old,new) -> linkat(AT_FDCWD,old,AT_FDCWD,new,0). x0/x1 are
 * borrowed bounded paths; x9=0 or negative errno. No replacement occurs.
 * Preserve x0-x7; stack64; scratch x8/x10-x17/NZCV as other adapters. */
arm_link:
    ARM_SYSCALL_SAVE
    mov x3, x1
    mov x1, x0
    mov x0, #-100
    mov x2, #-100
    mov x4, #0
    mov x8, #37
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

arm_chmod:
    ARM_SYSCALL_SAVE
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x8, #53
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

arm_readlink:
    ARM_SYSCALL_SAVE
    mov x3, x2
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x8, #78
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

/* clone with SIGCHLD and no sharing flags has fork's process semantics. */
arm_fork:
    ARM_SYSCALL_SAVE
    mov x0, #17
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x8, #220
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN

/* dup3 rejects equal descriptors. Match dup2's equal-fd validation with fcntl. */
arm_dup2:
    ARM_SYSCALL_SAVE
    cmp x0, x1
    b.eq .Larm_dup2_equal
    mov x2, #0
    mov x8, #24
    svc #0
    mov x9, x0
    ARM_SYSCALL_RETURN
.Larm_dup2_equal:
    mov x1, #1
    mov x8, #25
    svc #0
    mov x9, x0
    tbnz x9, #63, .Larm_dup2_done
    ldr x9, [sp]
.Larm_dup2_done:
    ARM_SYSCALL_RETURN

/* alarm(seconds) via ITIMER_REAL. Return the old remaining seconds, rounded up.
 * Both itimerval structures have four signed 64-bit timeval fields.
 */
arm_alarm:
    ARM_SYSCALL_SAVE
    sub sp, sp, #64
    stp xzr, xzr, [sp]
    stp x0, xzr, [sp, #16]
    mov x0, #0
    mov x1, sp
    add x2, sp, #32
    mov x8, #103
    svc #0
    mov x9, x0
    tbnz x9, #63, .Larm_alarm_done
    ldp x9, x10, [sp, #48]
    cmp x10, #0
    cinc x9, x9, ne
.Larm_alarm_done:
    add sp, sp, #64
    ARM_SYSCALL_RETURN

.section .note.GNU-stack,"",@progbits
