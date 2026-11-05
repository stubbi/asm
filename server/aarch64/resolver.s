/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux AArch64 LP64, AAPCS64, glibc >= 2.34. Startup-only DNS.
 * libc owns resolver/TLS machinery; every retained request pointer below has
 * process lifetime. No request thread uses this module after startup.
 * One kernel-owned monotonic SIGKILL timer also covers fully masked stalls.
 */
.arch armv8-a
.macro RES_ADDR reg, symbol
    adrp \reg, \symbol
    add \reg, \reg, :lo12:\symbol
.endm
.equ RES_SIGALRM, 14
.equ RES_SIGPIPE, 13
.equ RES_SIGKILL, 9
.equ RES_SIG_BLOCK, 0
.equ RES_SIG_SETMASK, 2
.equ RES_CLOCK_MONOTONIC, 1
.equ RES_TIMER_ABSTIME, 1
.equ RES_DEADLINE_SECONDS, 2
.equ RES_EXIT_GROUP, 94
.equ RES_WRITE, 64
.equ RES_CONFIG_LIMIT, 4096
.equ RES_NANOSECONDS, 1000000000
.equ RES_ADDRESS_KEY_LENGTH, 10
.equ RES_DIAGNOSTIC_INTERRUPTS, 16

.section .rodata
.Lres_address_key: .ascii "&hostaddr="
.Lres_failure_text:
    .ascii "asm-hub: database hostname resolution failed. Check DNS and the private TLS connection file.\n"
.Lres_failure_end:

.section .bss
.balign 8
.Lres_request: .zero 56
.Lres_hints: .zero 48
.Lres_notification: .zero 64
.Lres_list: .zero 8
.Lres_numeric: .zero 16
.Lres_old_mask: .zero 128
.Lres_alarm_mask: .zero 128
.Lres_pending: .zero 128
.Lres_pipe_mask: .zero 128
.Lres_old_timer: .zero 32
.Lres_hard_event: .zero 64
.Lres_hard_id: .zero 8
.Lres_hard_value: .zero 32
.Lres_deadline: .zero 16
.Lres_now: .zero 16
.Lres_remaining: .zero 16

.section .text
.globl resolve_database_address
.type resolve_database_address,%function
/* x0=validated persistent hostname, 1..253 bytes plus NUL. Returns w0=1
 * after appending one numeric hostaddr to global db_config[4098]. Failure
 * terminates the whole process with78, or SIGKILL on deadline expiration.
 * Preserves x19-x29/SP; clobbers only AAPCS64 caller-saved registers.
 * Frame48 saves x19-x22 and FP/LR. One owned kernel POSIX timer covers the
 * exact monotonic deadline even when glibc masks signals in helper creation.
 * Caller SIGALRM action and interval timer remain unchanged. Scheduler and
 * uninterruptible kernel-I/O delays are not hard real-time guarantees.
 */
resolve_database_address:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0

    RES_ADDR x0, .Lres_alarm_mask
    bl sigemptyset
    cbnz w0, .Lres_direct_exit
    RES_ADDR x0, .Lres_alarm_mask
    mov w1, #RES_SIGALRM
    bl sigaddset
    cbnz w0, .Lres_direct_exit
    mov w0, #RES_SIG_BLOCK
    RES_ADDR x1, .Lres_alarm_mask
    RES_ADDR x2, .Lres_old_mask
    bl sigprocmask
    cbnz w0, .Lres_direct_exit
    mov w0, #0                  /* ITIMER_REAL */
    RES_ADDR x1, .Lres_old_timer
    bl getitimer
    cbnz w0, .Lres_direct_exit
    RES_ADDR x9, .Lres_old_timer
    ldp x10, x11, [x9]
    ldp x12, x13, [x9, #16]
    orr x10, x10, x11
    orr x10, x10, x12
    orr x10, x10, x13
    cbnz x10, .Lres_direct_exit
    bl .Lres_alarm_pending
    cbnz w0, .Lres_direct_exit

    mov w0, #RES_CLOCK_MONOTONIC
    RES_ADDR x1, .Lres_deadline
    bl clock_gettime
    cbnz w0, .Lres_direct_exit
    RES_ADDR x9, .Lres_deadline
    ldr x10, [x9]
    add x10, x10, #RES_DEADLINE_SECONDS
    str x10, [x9]
    RES_ADDR x1, .Lres_hard_event
    mov w10, #RES_SIGKILL
    str w10, [x1, #8]          /* SIGEV_SIGNAL=0, signo=SIGKILL */
    mov w0, #RES_CLOCK_MONOTONIC
    RES_ADDR x2, .Lres_hard_id
    bl timer_create
    cbnz w0, .Lres_direct_exit
    RES_ADDR x9, .Lres_deadline
    ldp x10, x11, [x9]
    RES_ADDR x9, .Lres_hard_value
    stp x10, x11, [x9, #16]    /* no interval, exact absolute deadline */
    RES_ADDR x9, .Lres_hard_id
    ldr x0, [x9]
    mov w1, #RES_TIMER_ABSTIME
    RES_ADDR x2, .Lres_hard_value
    mov x3, #0
    bl timer_settime
    cbnz w0, .Lres_direct_exit
    /* Restore the exact caller mask. SIGKILL cannot be masked by the main
     * thread or any resolver helper. No ALRM handler/timer is installed. */
    mov w0, #RES_SIG_SETMASK
    RES_ADDR x1, .Lres_old_mask
    mov x2, #0
    bl sigprocmask
    cbnz w0, .Lres_direct_exit

    RES_ADDR x9, .Lres_request
    str x19, [x9]
    RES_ADDR x10, .Lres_hints
    str x10, [x9, #16]
    mov w11, #2
    str w11, [x10, #4]          /* AF_INET */
    mov w11, #1
    str w11, [x10, #8]          /* SOCK_STREAM */
    mov w11, #6
    str w11, [x10, #12]         /* IPPROTO_TCP */
    RES_ADDR x10, .Lres_list
    str x9, [x10]
    RES_ADDR x3, .Lres_notification
    mov w11, #1
    str w11, [x3, #12]          /* SIGEV_NONE */
    mov w0, #1                  /* GAI_NOWAIT */
    mov x1, x10
    mov w2, #1
    bl getaddrinfo_a
    cbnz w0, .Lres_failure
.Lres_poll:
    RES_ADDR x0, .Lres_request
    bl gai_error
    cbz w0, .Lres_completed
    cmn w0, #100               /* EAI_INPROGRESS */
    b.ne .Lres_failure
    bl .Lres_compute_remaining
    cbz w0, .Lres_failure
    RES_ADDR x0, .Lres_list
    mov w1, #1
    RES_ADDR x2, .Lres_remaining
    bl gai_suspend
    cbz w0, .Lres_poll
    cmn w0, #104               /* EAI_INTR */
    b.eq .Lres_poll
    cmn w0, #3                 /* EAI_AGAIN */
    b.eq .Lres_poll
    cmn w0, #103               /* EAI_ALLDONE */
    b.eq .Lres_poll
    b .Lres_failure
.Lres_completed:
    RES_ADDR x9, .Lres_request
    ldr x20, [x9, #24]
    cbz x20, .Lres_failure
    ldr w9, [x20, #4]
    cmp w9, #2
    b.ne .Lres_failure
    ldr w9, [x20, #8]
    cmp w9, #1
    b.ne .Lres_failure
    ldr w9, [x20, #12]
    cmp w9, #6
    b.ne .Lres_failure
    ldr w9, [x20, #16]
    cmp w9, #16
    b.ne .Lres_failure
    ldr x1, [x20, #24]
    cbz x1, .Lres_failure
    ldrh w9, [x1]
    cmp w9, #2
    b.ne .Lres_failure
    add x1, x1, #4
    mov w0, #2
    RES_ADDR x2, .Lres_numeric
    mov w3, #16
    bl inet_ntop
    cbz x0, .Lres_failure
    RES_ADDR x0, db_config
    mov x1, #4097
    bl strnlen
    cmp x0, #RES_CONFIG_LIMIT
    b.hi .Lres_failure
    mov x21, x0
    RES_ADDR x0, .Lres_numeric
    mov x1, #16
    bl strnlen
    cbz x0, .Lres_failure
    cmp x0, #15
    b.hi .Lres_failure
    mov x22, x0
    add x9, x21, #RES_ADDRESS_KEY_LENGTH
    add x9, x9, x22
    cmp x9, #RES_CONFIG_LIMIT
    b.hi .Lres_failure
    RES_ADDR x0, db_config
    add x0, x0, x21
    RES_ADDR x1, .Lres_address_key
    mov x2, #RES_ADDRESS_KEY_LENGTH
    bl memcpy
    RES_ADDR x0, db_config
    add x0, x0, x21
    add x0, x0, #RES_ADDRESS_KEY_LENGTH
    RES_ADDR x1, .Lres_numeric
    add x2, x22, #1
    bl memcpy
    mov x0, x20
    bl freeaddrinfo             /* request is completed; no pending free/cancel */

    mov w0, #RES_SIG_BLOCK
    RES_ADDR x1, .Lres_alarm_mask
    mov x2, #0
    bl sigprocmask
    cbnz w0, .Lres_direct_exit
    bl .Lres_compute_remaining
    cbz w0, .Lres_direct_exit
    bl .Lres_alarm_pending
    cbnz w0, .Lres_direct_exit
    mov w0, #RES_SIG_SETMASK
    RES_ADDR x1, .Lres_old_mask
    mov x2, #0
    bl sigprocmask
    cbnz w0, .Lres_direct_exit
    RES_ADDR x9, .Lres_hard_id
    ldr x0, [x9]
    bl timer_delete
    cbnz w0, .Lres_direct_exit
    bl .Lres_compute_remaining
    cbz w0, .Lres_direct_exit
    mov w0, #1
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
.Lres_failure:
    /* Block only SIGPIPE. A closed diagnostic pipe must still return 78;
     * an open full pipe remains covered by the owned monotonic hard timer. */
    RES_ADDR x0, .Lres_pipe_mask
    bl sigemptyset
    cbnz w0, .Lres_direct_exit
    RES_ADDR x0, .Lres_pipe_mask
    mov w1, #RES_SIGPIPE
    bl sigaddset
    cbnz w0, .Lres_direct_exit
    mov w0, #RES_SIG_BLOCK
    RES_ADDR x1, .Lres_pipe_mask
    mov x2, #0
    bl sigprocmask
    cbnz w0, .Lres_direct_exit
    /* This path cannot return. Callee-saved cursor/remainder survive the raw
     * calls; positive short writes advance, and EINTR has one finite budget.
     * The original deadline and all other signal mask bits stay unchanged. */
    RES_ADDR x19, .Lres_failure_text
    mov x20, #(.Lres_failure_end - .Lres_failure_text)
    mov x21, #RES_DIAGNOSTIC_INTERRUPTS
.Lres_diagnostic_write:
    cbz x20, .Lres_direct_exit
    mov x0, #2
    mov x1, x19
    mov x2, x20
    mov x8, #RES_WRITE
    svc #0
    cmn x0, #4                 /* EINTR */
    b.eq .Lres_diagnostic_interrupt
    cmp x0, #0
    b.le .Lres_direct_exit
    add x19, x19, x0
    sub x20, x20, x0
    b .Lres_diagnostic_write
.Lres_diagnostic_interrupt:
    cbz x21, .Lres_direct_exit
    sub x21, x21, #1
    b .Lres_diagnostic_write
.Lres_direct_exit:
    mov x0, #78
    mov x8, #RES_EXIT_GROUP
    svc #0
    b .Lres_direct_exit
.size resolve_database_address,.-resolve_database_address

/* No inputs; w0=0 iff blocked SIGALRM is not pending, else 1.
 * Frame16 saves FP/LR. Uses lifetime storage; caller has blocked ALRM. */
.Lres_alarm_pending:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    RES_ADDR x0, .Lres_pending
    bl sigpending
    cbnz w0, .Lres_pending_bad
    RES_ADDR x0, .Lres_pending
    mov w1, #RES_SIGALRM
    bl sigismember
    cmp w0, #0
    cset w0, ne
    b .Lres_pending_return
.Lres_pending_bad:
    mov w0, #1
.Lres_pending_return:
    ldp x29, x30, [sp], #16
    ret

/* No inputs; w0=1 with positive remaining timespec, or 0 on expired/clock
 * failure. Frame16; caller-saved only. One immutable absolute deadline. */
.Lres_compute_remaining:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w0, #RES_CLOCK_MONOTONIC
    RES_ADDR x1, .Lres_now
    bl clock_gettime
    cbnz w0, .Lres_time_bad
    RES_ADDR x9, .Lres_deadline
    ldp x10, x11, [x9]
    RES_ADDR x9, .Lres_now
    ldp x12, x13, [x9]
    sub x10, x10, x12
    subs x11, x11, x13
    b.ge .Lres_time_normal
    sub x10, x10, #1
    mov x12, #(RES_NANOSECONDS & 0xffff)
    movk x12, #(RES_NANOSECONDS >> 16), lsl #16
    add x11, x11, x12
.Lres_time_normal:
    cmp x10, #0
    b.lt .Lres_time_bad
    orr x12, x10, x11
    cbz x12, .Lres_time_bad
    RES_ADDR x9, .Lres_remaining
    stp x10, x11, [x9]
    mov w0, #1
    b .Lres_time_return
.Lres_time_bad:
    mov w0, #0
.Lres_time_return:
    ldp x29, x30, [sp], #16
    ret

.section .note.GNU-stack,"",%progbits
