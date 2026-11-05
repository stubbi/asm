/* SPDX-License-Identifier: AGPL-3.0-or-later
 * ARMv8-A Linux LP64/AAPCS64. x0-x7 arguments,x0 result; x19-x29 preserved.
 * SP is16-byte aligned at every call; no SIMD state is used. Shared fixed
 * request/table contracts are in metrics-data.inc. No per-request allocation.
 */
.arch armv8-a
.macro M_ADDR reg, symbol
    adrp \reg, \symbol
    add \reg, \reg, :lo12:\symbol
.endm
#include "../metrics-data.inc"
.section .text
.globl asm_metrics_init
.type asm_metrics_init,%function
/* No input; w0=1 success,0 initialization failure. Frame16; no workers yet. */
asm_metrics_init:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    M_ADDR x0, m_table
    mov w1, #0
    mov x2, #METRICS_BYTES
    bl memset
    M_ADDR x9, m_health
    str wzr, [x9]
    M_ADDR x0, m_mutex
    mov x1, #0
    bl pthread_mutex_init
    cbnz w0, .Lm_init_no
    M_ADDR x9, m_health
    mov w0, #1
    str w0, [x9]
    ldp x29, x30, [sp], #16
    ret
.Lm_init_no:
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret

.globl asm_metrics_destroy
.type asm_metrics_destroy,%function
/* No input/output; caller joined all requests. Frame16. */
asm_metrics_destroy:
    stp x29, x30, [sp, #-16]!
    M_ADDR x0, m_mutex
    bl pthread_mutex_destroy
    cbnz w0, m_fatal
    M_ADDR x9, m_health
    str wzr, [x9]
    ldp x29, x30, [sp], #16
    ret

.globl asm_metrics_route
.type asm_metrics_route,%function
/* x0=borrowed bounded NUL path; w0=fixed route0..5. Frame32 saves x19/x20. */
asm_metrics_route:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x19, x0
    M_ADDR x20, m_paths
.Lm_route_next:
    ldr x1, [x20]
    cbz x1, .Lm_route_other
    mov x0, x19
    bl strcmp
    cbz w0, .Lm_route_found
    add x20, x20, #16
    b .Lm_route_next
.Lm_route_other:
    mov w0, #5
    b .Lm_route_done
.Lm_route_found:
    ldr w0, [x20, #8]
.Lm_route_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl asm_metrics_begin
.type asm_metrics_begin,%function
/* x0=owned16-byte stack request; initializes timer/default route. Frame32. */
asm_metrics_begin:
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x19, x0
    bl m_clock
    str x0, [x19]
    mov w9, #5
    str w9, [x19, #8]
    str w1, [x19, #12]
    cbnz w1, .Lm_begin_done
    bl m_disable
.Lm_begin_done:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl asm_metrics_finish
.type asm_metrics_finish,%function
/* x0=request,w1=status,w2=queue0/1; w0=original queue result. Frame64.
 * Owns no HTTP/PG resource. Validates all updates before changing the table. */
asm_metrics_finish:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov w20, w1
    mov w21, w2
    cbz w2, .Lm_finish_lock
    cmp w2, #1
    b.ne .Lm_finish_bad
    ldr w9, [x19, #12]
    cmp w9, #1
    b.ne .Lm_finish_bad
    bl m_clock
    cbz w1, .Lm_finish_bad
    ldr x9, [x19]
    subs x22, x0, x9
    b.lo .Lm_finish_bad
    ldr w9, [x19, #8]
    cmp w9, #5
    b.hi .Lm_finish_bad
    mov w9, #100
    udiv w20, w20, w9
    cmp w20, #2
    b.eq .Lm_class_two
    sub w20, w20, #3
    cmp w20, #1
    b.lo .Lm_finish_bad
    cmp w20, #2
    b.hi .Lm_finish_bad
    b .Lm_finish_lock
.Lm_class_two:
    mov w20, #0
.Lm_finish_lock:
    bl m_lock
    M_ADDR x9, m_health
    ldr w9, [x9]
    cmp w9, #1
    b.ne .Lm_finish_unlock
    cbz w21, .Lm_failure_count
    ldr w9, [x19, #8]
    mov x10, #METRICS_ROW
    M_ADDR x23, m_table
    madd x23, x9, x10, x23
    ldr x9, [x23, x20, lsl #3]
    cmn x9, #1
    b.eq .Lm_finish_overflow
    ldr x9, [x23, #METRICS_COUNT]
    cmn x9, #1
    b.eq .Lm_finish_overflow
    ldr x9, [x23, #METRICS_SUM]
    adds x9, x9, x22
    b.cs .Lm_finish_overflow
    mov x9, #0
    M_ADDR x10, m_bucket_ns
    add x13, x23, #24
.Lm_bucket_check:
    ldr x12, [x10, x9, lsl #3]
    cmp x22, x12
    b.hi .Lm_bucket_check_next
    ldr x12, [x13, x9, lsl #3]
    cmn x12, #1
    b.eq .Lm_finish_overflow
.Lm_bucket_check_next:
    add x9, x9, #1
    cmp x9, #8
    b.lo .Lm_bucket_check
    ldr x9, [x23, x20, lsl #3]
    add x9, x9, #1
    str x9, [x23, x20, lsl #3]
    ldr x9, [x23, #METRICS_COUNT]
    add x9, x9, #1
    str x9, [x23, #METRICS_COUNT]
    ldr x9, [x23, #METRICS_SUM]
    add x9, x9, x22
    str x9, [x23, #METRICS_SUM]
    mov x9, #0
.Lm_bucket_update:
    ldr x12, [x10, x9, lsl #3]
    cmp x22, x12
    b.hi .Lm_bucket_update_next
    ldr x12, [x13, x9, lsl #3]
    add x12, x12, #1
    str x12, [x13, x9, lsl #3]
.Lm_bucket_update_next:
    add x9, x9, #1
    cmp x9, #8
    b.lo .Lm_bucket_update
    b .Lm_finish_unlock
.Lm_failure_count:
    M_ADDR x10, m_table
    ldr x9, [x10, #METRICS_FAILURES]
    cmn x9, #1
    b.eq .Lm_finish_overflow
    add x9, x9, #1
    str x9, [x10, #METRICS_FAILURES]
    b .Lm_finish_unlock
.Lm_finish_overflow:
    M_ADDR x9, m_health
    str wzr, [x9]
.Lm_finish_unlock:
    bl m_unlock
    b .Lm_finish_done
.Lm_finish_bad:
    bl m_disable
.Lm_finish_done:
    mov w0, w21
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

.globl asm_metrics_render
.type asm_metrics_render,%function
/* x0=buffer,x1=capacity; x0=positive bytes or-1. Frame736 includes a632-byte
 * snapshot and builder; output uses at most16KiB. Formats contain integers only. */
asm_metrics_render:
    sub sp, sp, #736
    stp x29, x30, [sp]
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    add x19, sp, #64
    add x20, sp, #96
    cbz x0, .Lm_render_bad
    cbz x1, .Lm_render_bad
    mov x9, #METRICS_REPLY
    cmp x1, x9
    csel x1, x1, x9, ls
    stp x0, x1, [x19]
    str xzr, [x19, #16]
    bl m_lock
    M_ADDR x9, m_health
    ldr w9, [x9]
    cmp w9, #1
    b.ne .Lm_render_unavailable
    mov x0, x20
    M_ADDR x1, m_table
    mov x2, #METRICS_BYTES
    bl memcpy
    bl m_unlock
    mov x0, x19
    M_ADDR x1, m_requests_header
    bl m_literal
    cbz w0, .Lm_render_bad
    mov x21, #0
.Lm_render_requests_route:
    mov x9, #METRICS_ROW
    madd x23, x21, x9, x20
    mov x22, #0
.Lm_render_request_class:
    mov x0, x19
    M_ADDR x1, m_requests_format
    M_ADDR x9, m_routes
    ldr x2, [x9, x21, lsl #3]
    M_ADDR x9, m_classes
    ldr x3, [x9, x22, lsl #3]
    ldr x4, [x23, x22, lsl #3]
    bl m_append
    cbz w0, .Lm_render_bad
    add x22, x22, #1
    cmp x22, #3
    b.lo .Lm_render_request_class
    add x21, x21, #1
    cmp x21, #6
    b.lo .Lm_render_requests_route
    mov x0, x19
    M_ADDR x1, m_duration_header
    bl m_literal
    cbz w0, .Lm_render_bad
    mov x21, #0
.Lm_render_duration_route:
    mov x9, #METRICS_ROW
    madd x23, x21, x9, x20
    mov x22, #0
.Lm_render_bucket:
    mov x0, x19
    M_ADDR x1, m_bucket_format
    M_ADDR x9, m_routes
    ldr x2, [x9, x21, lsl #3]
    M_ADDR x9, m_boundaries
    ldr x3, [x9, x22, lsl #3]
    add x9, x23, #24
    ldr x4, [x9, x22, lsl #3]
    bl m_append
    cbz w0, .Lm_render_bad
    add x22, x22, #1
    cmp x22, #8
    b.lo .Lm_render_bucket
    ldr x9, [x23, #METRICS_SUM]
    movz x10, #0xca00
    movk x10, #0x3b9a, lsl #16
    udiv x3, x9, x10
    msub x4, x3, x10, x9
    M_ADDR x9, m_routes
    ldr x2, [x9, x21, lsl #3]
    mov x0, x19
    M_ADDR x1, m_sum_format
    bl m_append
    cbz w0, .Lm_render_bad
    mov x0, x19
    M_ADDR x1, m_count_format
    M_ADDR x9, m_routes
    ldr x2, [x9, x21, lsl #3]
    ldr x3, [x23, #METRICS_COUNT]
    mov x4, #0
    bl m_append
    cbz w0, .Lm_render_bad
    add x21, x21, #1
    cmp x21, #6
    b.lo .Lm_render_duration_route
    mov x0, x19
    M_ADDR x1, m_failures_header
    bl m_literal
    cbz w0, .Lm_render_bad
    mov x0, x19
    M_ADDR x1, m_failures_format
    ldr x2, [x20, #METRICS_FAILURES]
    mov x3, #0
    mov x4, #0
    bl m_append
    cbz w0, .Lm_render_bad
    ldr x0, [x19, #16]
    b .Lm_render_done
.Lm_render_unavailable:
    bl m_unlock
    mov x0, #-1
    b .Lm_render_done
.Lm_render_bad:
    bl m_disable
    mov x0, #-1
.Lm_render_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp]
    add sp, sp, #736
    ret

/* Private clock: x0=ns,w1=valid. Frame32 owns one timespec. */
m_clock:
    stp x29, x30, [sp, #-32]!
    mov w0, #1
    add x1, sp, #16
    bl clock_gettime
    cbnz w0, .Lm_clock_no
    ldp x0, x9, [sp, #16]
    tbnz x0, #63, .Lm_clock_no
    movz x10, #0xca00
    movk x10, #0x3b9a, lsl #16
    cmp x9, x10
    b.hs .Lm_clock_no
    umulh x11, x0, x10
    cbnz x11, .Lm_clock_no
    mul x0, x0, x10
    adds x0, x0, x9
    b.cs .Lm_clock_no
    mov w1, #1
    ldp x29, x30, [sp], #32
    ret
.Lm_clock_no:
    mov x0, #0
    mov w1, #0
    ldp x29, x30, [sp], #32
    ret

/* x0=builder,x1=fixed format,x2/x3/x4=arguments; w0=complete. Frame32. */
m_append:
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x19, x0
    mov x5, x4
    mov x4, x3
    mov x3, x2
    mov x2, x1
    ldp x0, x1, [x19]
    bl snprintf
    cmp w0, #0
    b.le .Lm_append_no
    uxtw x0, w0
    ldp x9, x10, [x19]
    cmp x0, x10
    b.hs .Lm_append_no
    add x9, x9, x0
    sub x10, x10, x0
    stp x9, x10, [x19]
    ldr x9, [x19, #16]
    add x9, x9, x0
    str x9, [x19, #16]
    mov w0, #1
    b .Lm_append_done
.Lm_append_no:
    mov w0, #0
.Lm_append_done:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
m_literal:
    mov x2, x1
    M_ADDR x1, m_literal_format
    mov x3, #0
    mov x4, #0
    b m_append

/* No arguments/results; mutex initialized, matching ownership. Frame16. */
m_lock:
    stp x29, x30, [sp, #-16]!
    M_ADDR x0, m_mutex
    bl pthread_mutex_lock
    ldp x29, x30, [sp], #16
    cbnz w0, m_fatal
    ret
m_unlock:
    stp x29, x30, [sp, #-16]!
    M_ADDR x0, m_mutex
    bl pthread_mutex_unlock
    ldp x29, x30, [sp], #16
    cbnz w0, m_fatal
    ret
m_disable:
    stp x29, x30, [sp, #-16]!
    bl m_lock
    M_ADDR x9, m_health
    str wzr, [x9]
    bl m_unlock
    ldp x29, x30, [sp], #16
    ret

/* No return. Fixed Linux stderr write handles short writes/EINTR without locks. */
m_fatal:
    M_ADDR x19, m_sync_error
    mov x20, #M_SYNC_ERROR_LENGTH
.Lm_fatal_write:
    cbz x20, .Lm_fatal_exit
    mov x0, #2
    mov x1, x19
    mov x2, x20
    mov x8, #64
    svc #0
    cmn x0, #4
    b.eq .Lm_fatal_write
    cmp x0, #0
    b.le .Lm_fatal_exit
    add x19, x19, x0
    sub x20, x20, x0
    b .Lm_fatal_write
.Lm_fatal_exit:
    mov x0, #71
    mov x8, #94
    svc #0
    brk #0

#ifdef ASM_METRICS_TEST
/* Trusted632-byte test fixtures only; seed also restores health. Frame32. */
.globl asm_metrics_test_seed
asm_metrics_test_seed:
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x19, x0
    bl m_lock
    M_ADDR x0, m_table
    mov x1, x19
    mov x2, #METRICS_BYTES
    bl memcpy
    M_ADDR x9, m_health
    mov w10, #1
    str w10, [x9]
    bl m_unlock
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
.globl asm_metrics_test_snapshot
asm_metrics_test_snapshot:
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x19, x0
    bl m_lock
    mov x0, x19
    M_ADDR x1, m_table
    mov x2, #METRICS_BYTES
    bl memcpy
    bl m_unlock
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
#endif
.section .note.GNU-stack,"",%progbits
