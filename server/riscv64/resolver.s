/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux RV64GC/LP64D startup resolver. glibc owns DNS and its worker threads.
 * One lookup pins an IPv4 address while retaining the TLS certificate host.
 * The signal watchdog applies while the submitting thread can receive ALRM;
 * glibc's masked helper-creation interval is an explicit specification limit.
 */
.option pic
.option norelax
.attribute arch, "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"
.equ RR_AF_INET, 2
.equ RR_SOCK_STREAM, 1
.equ RR_IPPROTO_TCP, 6
.equ RR_SIGALRM, 14
.equ RR_SIGPIPE, 13
.equ RR_SIG_BLOCK, 0
.equ RR_SIG_UNBLOCK, 1
.equ RR_SIG_SETMASK, 2
.equ RR_CLOCK_MONOTONIC, 1
.equ RR_EAI_INPROGRESS, -100
.equ RR_EAI_ALLDONE, -103
.equ RR_EAI_INTR, -104
.equ RR_EAI_AGAIN, -3
.equ RR_LIMIT, 4096
.equ RR_SYS_WRITE, 64
.equ RR_SYS_EXIT_GROUP, 94

.section .rodata
.Lrr_suffix: .ascii "&hostaddr="
.Lrr_error: .ascii "asm-hub: database hostname resolution failed. Check DNS and the TLS connection file.\n"
.Lrr_error_end:

.section .bss
.balign 8
/* These objects outlive every asynchronous request, including fatal paths. */
.Lrr_request: .zero 56
.Lrr_list: .zero 8
.Lrr_hints: .zero 48
.Lrr_notification: .zero 64
.Lrr_address: .zero 16
.Lrr_old_action: .zero 160
.Lrr_action: .zero 160
.Lrr_old_mask: .zero 128
.Lrr_alarm_set: .zero 128
.Lrr_pipe_set: .zero 128
.Lrr_pending: .zero 128
.Lrr_old_timer: .zero 32
.Lrr_timer: .zero 32
.Lrr_zero_timer: .zero 32
.Lrr_deadline: .zero 16
.Lrr_now: .zero 16
.Lrr_remaining: .zero 16

.section .text
.globl resolve_database_address
.type resolve_database_address,@function
/* a0=persistent validated hostname[<=254], borrowed until process termination.
 * Returns a0=1 after appending to owned db_config[4098], or exits process78.
 * Changes caller-saved registers; preserves s0-s11/gp/tp. Frame64, SP16.
 * Uses asserted LP64 libc resolver/signal/time layouts; never cancels a worker.
 * This startup-only routine is called once before database and HTTP threads. */
resolve_database_address:
    addi sp, sp, -64
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    mv s0, a0
    li s4, 0                  /* A fatal diagnostic needs an eligible watchdog. */

    li a0, RR_SIG_SETMASK
    li a1, 0
    la a2, .Lrr_old_mask
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIGALRM
    li a1, 0
    la a2, .Lrr_old_action
    call sigaction
    bnez a0, .Lrr_direct_fail
    li a0, 0                  /* ITIMER_REAL */
    la a1, .Lrr_old_timer
    call getitimer
    bnez a0, .Lrr_direct_fail
    la t0, .Lrr_old_timer
    ld t1, 0(t0)
    ld t2, 8(t0)
    or t1, t1, t2
    ld t2, 16(t0)
    or t1, t1, t2
    ld t2, 24(t0)
    or t1, t1, t2
    bnez t1, .Lrr_direct_fail

    la a0, .Lrr_alarm_set
    call sigemptyset
    bnez a0, .Lrr_direct_fail
    la a0, .Lrr_alarm_set
    li a1, RR_SIGALRM
    call sigaddset
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIG_BLOCK
    la a1, .Lrr_alarm_set
    li a2, 0
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    la a0, .Lrr_pending
    call sigpending
    bnez a0, .Lrr_direct_fail
    la a0, .Lrr_pending
    li a1, RR_SIGALRM
    call sigismember
    bnez a0, .Lrr_direct_fail

    li a0, RR_CLOCK_MONOTONIC
    la a1, .Lrr_deadline
    call clock_gettime
    bnez a0, .Lrr_direct_fail
    la t0, .Lrr_deadline
    ld t1, 0(t0)
    addi t2, t1, 2
    blt t2, t1, .Lrr_direct_fail
    sd t2, 0(t0)
    la a0, .Lrr_action
    addi a0, a0, 8            /* libc sa_mask, not the kernel ABI */
    call sigemptyset
    bnez a0, .Lrr_direct_fail
    la t0, .Lrr_action
    la t1, .Lrr_alarm
    sd t1, 0(t0)
    li a0, RR_SIGALRM
    mv a1, t0
    li a2, 0
    call sigaction
    bnez a0, .Lrr_direct_fail
    la t0, .Lrr_timer
    li t1, 2
    sd t1, 16(t0)
    li a0, 0
    mv a1, t0
    li a2, 0
    call setitimer
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIG_UNBLOCK
    la a1, .Lrr_alarm_set
    li a2, 0
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    li s4, 1

    la t0, .Lrr_request
    sd s0, 0(t0)
    la t1, .Lrr_hints
    sd t1, 16(t0)
    li t2, RR_AF_INET
    sw t2, 4(t1)
    li t2, RR_SOCK_STREAM
    sw t2, 8(t1)
    li t2, RR_IPPROTO_TCP
    sw t2, 12(t1)
    la t1, .Lrr_list
    sd t0, 0(t1)
    la t0, .Lrr_notification
    li t1, 1                  /* SIGEV_NONE */
    sw t1, 12(t0)
    li a0, 1                  /* GAI_NOWAIT */
    la a1, .Lrr_list
    li a2, 1
    mv a3, t0
    call getaddrinfo_a
    bnez a0, .Lrr_fail
.Lrr_poll:
    la a0, .Lrr_request
    call gai_error
    sext.w a0, a0
    beqz a0, .Lrr_completed
    li t0, RR_EAI_INPROGRESS
    bne a0, t0, .Lrr_fail
    call .Lrr_time_left
    beqz a0, .Lrr_fail
    la a0, .Lrr_list
    li a1, 1
    la a2, .Lrr_remaining
    call gai_suspend
    sext.w a0, a0
    beqz a0, .Lrr_poll
    li t0, RR_EAI_INTR
    beq a0, t0, .Lrr_poll
    li t0, RR_EAI_AGAIN
    beq a0, t0, .Lrr_poll
    li t0, RR_EAI_ALLDONE
    beq a0, t0, .Lrr_poll
    j .Lrr_fail
.Lrr_completed:
    la t0, .Lrr_request
    ld s1, 24(t0)
    beqz s1, .Lrr_fail
    lw t0, 4(s1)
    li t1, RR_AF_INET
    bne t0, t1, .Lrr_fail
    lw t0, 8(s1)
    li t1, RR_SOCK_STREAM
    bne t0, t1, .Lrr_fail
    lw t0, 12(s1)
    li t1, RR_IPPROTO_TCP
    bne t0, t1, .Lrr_fail
    lwu t0, 16(s1)
    li t1, 16
    bne t0, t1, .Lrr_fail
    ld t0, 24(s1)
    beqz t0, .Lrr_fail
    lhu t1, 0(t0)
    li t2, RR_AF_INET
    bne t1, t2, .Lrr_fail
    li a0, RR_AF_INET
    addi a1, t0, 4
    la a2, .Lrr_address
    li a3, 16
    call inet_ntop
    beqz a0, .Lrr_fail
    la a0, .Lrr_address
    li a1, 16
    call strnlen
    mv s2, a0
    beqz s2, .Lrr_fail
    li t0, 15
    bgtu s2, t0, .Lrr_fail
    la a0, db_config
    li a1, RR_LIMIT + 1
    call strnlen
    mv s3, a0
    add t0, s3, s2
    addi t0, t0, 10
    li t1, RR_LIMIT
    bgtu t0, t1, .Lrr_fail
    la a0, db_config
    add a0, a0, s3
    la a1, .Lrr_suffix
    li a2, 10
    call memcpy
    la a0, db_config
    add a0, a0, s3
    addi a0, a0, 10
    la a1, .Lrr_address
    addi a2, s2, 1
    call memcpy
    mv a0, s1
    call freeaddrinfo

    li a0, RR_SIG_BLOCK
    la a1, .Lrr_alarm_set
    li a2, 0
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    li s4, 0
    li a0, 0
    la a1, .Lrr_zero_timer
    li a2, 0
    call setitimer
    bnez a0, .Lrr_direct_fail
    call .Lrr_time_left
    beqz a0, .Lrr_direct_fail
    la a0, .Lrr_pending
    call sigpending
    bnez a0, .Lrr_direct_fail
    la a0, .Lrr_pending
    li a1, RR_SIGALRM
    call sigismember
    bnez a0, .Lrr_direct_fail
    li a0, 0
    la a1, .Lrr_old_timer
    li a2, 0
    call setitimer
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIGALRM
    la a1, .Lrr_old_action
    li a2, 0
    call sigaction
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIG_SETMASK
    la a1, .Lrr_old_mask
    li a2, 0
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    li a0, 1
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    addi sp, sp, 64
    ret
.Lrr_fail:
    beqz s4, .Lrr_direct_fail
    /* A closed stderr must not replace status78 with SIGPIPE termination.
     * ALRM remains unblocked so a full pipe is covered by the live watchdog. */
    la a0, .Lrr_pipe_set
    call sigemptyset
    bnez a0, .Lrr_direct_fail
    la a0, .Lrr_pipe_set
    li a1, RR_SIGPIPE
    call sigaddset
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIG_BLOCK
    la a1, .Lrr_pipe_set
    li a2, 0
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    li a0, RR_SIG_UNBLOCK
    la a1, .Lrr_alarm_set
    li a2, 0
    call sigprocmask
    bnez a0, .Lrr_direct_fail
    la s0, .Lrr_error
    li s1, .Lrr_error_end - .Lrr_error
    li s2, 16
.Lrr_error_write:
    li a0, 2
    mv a1, s0
    mv a2, s1
    li a7, RR_SYS_WRITE
    ecall
    li t0, -4
    bne a0, t0, .Lrr_error_progress
    beqz s2, .Lrr_direct_fail
    addi s2, s2, -1
    j .Lrr_error_write
.Lrr_error_progress:
    blez a0, .Lrr_direct_fail
    add s0, s0, a0
    sub s1, s1, a0
    bnez s1, .Lrr_error_write
.Lrr_direct_fail:
    li a0, 78
    li a7, RR_SYS_EXIT_GROUP
    ecall
    unimp
.size resolve_database_address,.-resolve_database_address

.type .Lrr_time_left,@function
/* No input. a0=1 if deadline remains, 0 on timeout/clock failure; writes owned
 * remaining timespec[16]. Caller-saved only, frame16 for ra, SP16 preserved. */
.Lrr_time_left:
    addi sp, sp, -16
    sd ra, 0(sp)
    li a0, RR_CLOCK_MONOTONIC
    la a1, .Lrr_now
    call clock_gettime
    bnez a0, .Lrr_no_time
    la t0, .Lrr_deadline
    la t1, .Lrr_now
    ld t2, 0(t0)
    ld t3, 0(t1)
    blt t2, t3, .Lrr_no_time
    sub t2, t2, t3
    ld t3, 8(t0)
    ld t4, 8(t1)
    sub t3, t3, t4
    bgez t3, .Lrr_time_normal
    addi t2, t2, -1
    li t4, 1000000000
    add t3, t3, t4
.Lrr_time_normal:
    bltz t2, .Lrr_no_time
    or t4, t2, t3
    beqz t4, .Lrr_no_time
    la t0, .Lrr_remaining
    sd t2, 0(t0)
    sd t3, 8(t0)
    li a0, 1
    j .Lrr_time_return
.Lrr_no_time:
    li a0, 0
.Lrr_time_return:
    ld ra, 0(sp)
    addi sp, sp, 16
    ret
.size .Lrr_time_left,.-.Lrr_time_left

.type .Lrr_alarm,@function
/* Signal input ignored. No calls, logging, stack, allocation, or cleanup.
 * Raw exit_group terminates resolver workers as well as the receiving thread. */
.Lrr_alarm:
    li a0, 78
    li a7, RR_SYS_EXIT_GROUP
    ecall
    unimp
.size .Lrr_alarm,.-.Lrr_alarm
.section .note.GNU-stack,"",@progbits
