/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux RV64GC/LP64D. a0-a7 arguments,a0 result; s0-s11/gp/tp preserved.
 * All call frames are16-byte aligned; no floating-point register is changed.
 * Fixed shared data/layout is in metrics-data.inc. All application logic here
 * remains assembly; libc supplies formatting, time, and pthread primitives.
 */
.option pic
.option norelax
.attribute arch, "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"
#include "../metrics-data.inc"
.section .text
.globl asm_metrics_init
.type asm_metrics_init,@function
/* No input; a0=1 success,0 mutex failure. Frame16; called before workers. */
asm_metrics_init:
    addi sp, sp, -16
    sd ra, 8(sp)
    la a0, m_table
    li a1, 0
    li a2, METRICS_BYTES
    call memset
    la t0, m_health
    sw zero, 0(t0)
    la a0, m_mutex
    li a1, 0
    call pthread_mutex_init
    bnez a0, .Lm_init_no
    la t0, m_health
    li a0, 1
    sw a0, 0(t0)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret
.Lm_init_no:
    li a0, 0
    ld ra, 8(sp)
    addi sp, sp, 16
    ret

.globl asm_metrics_destroy
.type asm_metrics_destroy,@function
/* No input/output; caller joined every request thread. Frame16. */
asm_metrics_destroy:
    addi sp, sp, -16
    sd ra, 8(sp)
    la a0, m_mutex
    call pthread_mutex_destroy
    bnez a0, m_fatal
    la t0, m_health
    sw zero, 0(t0)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret

.globl asm_metrics_route
.type asm_metrics_route,@function
/* a0=borrowed bounded NUL path; a0=route0..5. Frame32 saves s0/s1/ra. */
asm_metrics_route:
    addi sp, sp, -32
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd ra, 24(sp)
    mv s0, a0
    la s1, m_paths
.Lm_route_next:
    ld a1, 0(s1)
    beqz a1, .Lm_route_other
    mv a0, s0
    call strcmp
    beqz a0, .Lm_route_found
    addi s1, s1, 16
    j .Lm_route_next
.Lm_route_other:
    li a0, 5
    j .Lm_route_done
.Lm_route_found:
    lwu a0, 8(s1)
.Lm_route_done:
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld ra, 24(sp)
    addi sp, sp, 32
    ret

.globl asm_metrics_begin
.type asm_metrics_begin,@function
/* a0=owned16-byte stack request; initializes timer and default route. Frame16. */
asm_metrics_begin:
    addi sp, sp, -16
    sd s0, 0(sp)
    sd ra, 8(sp)
    mv s0, a0
    call m_clock
    sd a0, 0(s0)
    li t0, 5
    sw t0, 8(s0)
    sw a1, 12(s0)
    bnez a1, .Lm_begin_done
    call m_disable
.Lm_begin_done:
    ld s0, 0(sp)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret

.globl asm_metrics_finish
.type asm_metrics_finish,@function
/* a0=request,a1=status:u32,a2=MHD result0/1; a0=original result. Frame48.
 * Checks every affected field before committing one mutex-protected update. */
asm_metrics_finish:
    addi sp, sp, -48
    sd s0, 0(sp)
    sd s1, 8(sp)
    sd s2, 16(sp)
    sd s3, 24(sp)
    sd s4, 32(sp)
    sd ra, 40(sp)
    mv s0, a0
    slli s1, a1, 32
    srli s1, s1, 32
    sext.w s2, a2
    beqz s2, .Lm_finish_lock
    li t0, 1
    bne s2, t0, .Lm_finish_bad
    lwu t1, 12(s0)
    bne t1, t0, .Lm_finish_bad
    call m_clock
    beqz a1, .Lm_finish_bad
    ld t0, 0(s0)
    bltu a0, t0, .Lm_finish_bad
    sub s3, a0, t0
    lwu t0, 8(s0)
    li t1, 5
    bgtu t0, t1, .Lm_finish_bad
    li t0, 100
    divu s1, s1, t0
    li t0, 2
    beq s1, t0, .Lm_class_two
    addi s1, s1, -3
    li t0, 1
    bltu s1, t0, .Lm_finish_bad
    li t0, 2
    bgtu s1, t0, .Lm_finish_bad
    j .Lm_finish_lock
.Lm_class_two:
    li s1, 0
.Lm_finish_lock:
    call m_lock
    la t0, m_health
    lw t0, 0(t0)
    li t1, 1
    bne t0, t1, .Lm_finish_unlock
    beqz s2, .Lm_failure_count
    lwu t0, 8(s0)
    li t1, METRICS_ROW
    mul t0, t0, t1
    la s4, m_table
    add s4, s4, t0
    slli t0, s1, 3
    add t0, t0, s4
    ld t1, 0(t0)
    li t2, -1
    beq t1, t2, .Lm_finish_overflow
    ld t1, METRICS_COUNT(s4)
    beq t1, t2, .Lm_finish_overflow
    ld t1, METRICS_SUM(s4)
    add t2, t1, s3
    bltu t2, t1, .Lm_finish_overflow
    li t0, 0
    la t1, m_bucket_ns
    addi t4, s4, 24
.Lm_bucket_check:
    slli t2, t0, 3
    add t3, t1, t2
    ld t3, 0(t3)
    bgtu s3, t3, .Lm_bucket_check_next
    add t3, t4, t2
    ld t3, 0(t3)
    li t5, -1
    beq t3, t5, .Lm_finish_overflow
.Lm_bucket_check_next:
    addi t0, t0, 1
    li t5, 8
    bltu t0, t5, .Lm_bucket_check
    slli t0, s1, 3
    add t0, t0, s4
    ld t1, 0(t0)
    addi t1, t1, 1
    sd t1, 0(t0)
    ld t1, METRICS_COUNT(s4)
    addi t1, t1, 1
    sd t1, METRICS_COUNT(s4)
    ld t1, METRICS_SUM(s4)
    add t1, t1, s3
    sd t1, METRICS_SUM(s4)
    li t0, 0
    la t1, m_bucket_ns
.Lm_bucket_update:
    slli t2, t0, 3
    add t3, t1, t2
    ld t3, 0(t3)
    bgtu s3, t3, .Lm_bucket_update_next
    add t3, t4, t2
    ld t5, 0(t3)
    addi t5, t5, 1
    sd t5, 0(t3)
.Lm_bucket_update_next:
    addi t0, t0, 1
    li t5, 8
    bltu t0, t5, .Lm_bucket_update
    j .Lm_finish_unlock
.Lm_failure_count:
    la t0, m_table
    ld t1, METRICS_FAILURES(t0)
    li t2, -1
    beq t1, t2, .Lm_finish_overflow
    addi t1, t1, 1
    sd t1, METRICS_FAILURES(t0)
    j .Lm_finish_unlock
.Lm_finish_overflow:
    la t0, m_health
    sw zero, 0(t0)
.Lm_finish_unlock:
    call m_unlock
    j .Lm_finish_done
.Lm_finish_bad:
    call m_disable
.Lm_finish_done:
    mv a0, s2
    ld s0, 0(sp)
    ld s1, 8(sp)
    ld s2, 16(sp)
    ld s3, 24(sp)
    ld s4, 32(sp)
    ld ra, 40(sp)
    addi sp, sp, 48
    ret

.globl asm_metrics_render
.type asm_metrics_render,@function
/* a0=buffer,a1=capacity; a0=positive length or-1. Frame720 includes632-byte
 * snapshot/builder; output capped16KiB. All formatter arguments are integers. */
asm_metrics_render:
    addi sp, sp, -720
    sd s0, 672(sp)
    sd s1, 680(sp)
    sd s2, 688(sp)
    sd s3, 696(sp)
    sd s4, 704(sp)
    sd ra, 712(sp)
    mv s0, sp
    addi s1, sp, 32
    beqz a0, .Lm_render_bad
    beqz a1, .Lm_render_bad
    li t0, METRICS_REPLY
    bleu a1, t0, .Lm_render_capacity
    mv a1, t0
.Lm_render_capacity:
    sd a0, 0(s0)
    sd a1, 8(s0)
    sd zero, 16(s0)
    call m_lock
    la t0, m_health
    lw t0, 0(t0)
    li t1, 1
    bne t0, t1, .Lm_render_unavailable
    mv a0, s1
    la a1, m_table
    li a2, METRICS_BYTES
    call memcpy
    call m_unlock
    mv a0, s0
    la a1, m_requests_header
    call m_literal
    beqz a0, .Lm_render_bad
    li s2, 0
.Lm_render_requests_route:
    li t0, METRICS_ROW
    mul s4, s2, t0
    add s4, s4, s1
    li s3, 0
.Lm_render_request_class:
    mv a0, s0
    la a1, m_requests_format
    la t0, m_routes
    slli t1, s2, 3
    add t0, t0, t1
    ld a2, 0(t0)
    la t0, m_classes
    slli t1, s3, 3
    add t0, t0, t1
    ld a3, 0(t0)
    add t0, s4, t1
    ld a4, 0(t0)
    call m_append
    beqz a0, .Lm_render_bad
    addi s3, s3, 1
    li t0, 3
    bltu s3, t0, .Lm_render_request_class
    addi s2, s2, 1
    li t0, 6
    bltu s2, t0, .Lm_render_requests_route
    mv a0, s0
    la a1, m_duration_header
    call m_literal
    beqz a0, .Lm_render_bad
    li s2, 0
.Lm_render_duration_route:
    li t0, METRICS_ROW
    mul s4, s2, t0
    add s4, s4, s1
    li s3, 0
.Lm_render_bucket:
    mv a0, s0
    la a1, m_bucket_format
    la t0, m_routes
    slli t1, s2, 3
    add t0, t0, t1
    ld a2, 0(t0)
    la t0, m_boundaries
    slli t1, s3, 3
    add t0, t0, t1
    ld a3, 0(t0)
    add t0, s4, t1
    ld a4, 24(t0)
    call m_append
    beqz a0, .Lm_render_bad
    addi s3, s3, 1
    li t0, 8
    bltu s3, t0, .Lm_render_bucket
    ld t0, METRICS_SUM(s4)
    li t1, 1000000000
    divu a3, t0, t1
    remu a4, t0, t1
    la t0, m_routes
    slli t1, s2, 3
    add t0, t0, t1
    ld a2, 0(t0)
    mv a0, s0
    la a1, m_sum_format
    call m_append
    beqz a0, .Lm_render_bad
    mv a0, s0
    la a1, m_count_format
    la t0, m_routes
    slli t1, s2, 3
    add t0, t0, t1
    ld a2, 0(t0)
    ld a3, METRICS_COUNT(s4)
    li a4, 0
    call m_append
    beqz a0, .Lm_render_bad
    addi s2, s2, 1
    li t0, 6
    bltu s2, t0, .Lm_render_duration_route
    mv a0, s0
    la a1, m_failures_header
    call m_literal
    beqz a0, .Lm_render_bad
    mv a0, s0
    la a1, m_failures_format
    ld a2, METRICS_FAILURES(s1)
    li a3, 0
    li a4, 0
    call m_append
    beqz a0, .Lm_render_bad
    ld a0, 16(s0)
    j .Lm_render_done
.Lm_render_unavailable:
    call m_unlock
    li a0, -1
    j .Lm_render_done
.Lm_render_bad:
    call m_disable
    li a0, -1
.Lm_render_done:
    ld s0, 672(sp)
    ld s1, 680(sp)
    ld s2, 688(sp)
    ld s3, 696(sp)
    ld s4, 704(sp)
    ld ra, 712(sp)
    addi sp, sp, 720
    ret

/* Private clock: a0=ns,a1=valid. Frame32 owns one timespec. */
m_clock:
    addi sp, sp, -32
    sd ra, 24(sp)
    li a0, 1
    mv a1, sp
    call clock_gettime
    bnez a0, .Lm_clock_no
    ld a0, 0(sp)
    bltz a0, .Lm_clock_no
    ld t0, 8(sp)
    li t1, 1000000000
    bgeu t0, t1, .Lm_clock_no
    mulhu t2, a0, t1
    bnez t2, .Lm_clock_no
    mul a0, a0, t1
    add t2, a0, t0
    bltu t2, a0, .Lm_clock_no
    mv a0, t2
    li a1, 1
    ld ra, 24(sp)
    addi sp, sp, 32
    ret
.Lm_clock_no:
    li a0, 0
    li a1, 0
    ld ra, 24(sp)
    addi sp, sp, 32
    ret

/* a0=builder,a1=fixed format,a2/a3/a4=arguments; a0=complete. Frame16. */
m_append:
    addi sp, sp, -16
    sd s0, 0(sp)
    sd ra, 8(sp)
    mv s0, a0
    mv a5, a4
    mv a4, a3
    mv a3, a2
    mv a2, a1
    ld a1, 8(s0)
    ld a0, 0(s0)
    call snprintf
    sext.w a0, a0
    blez a0, .Lm_append_no
    ld t0, 8(s0)
    bgeu a0, t0, .Lm_append_no
    sub t0, t0, a0
    sd t0, 8(s0)
    ld t0, 0(s0)
    add t0, t0, a0
    sd t0, 0(s0)
    ld t0, 16(s0)
    add t0, t0, a0
    sd t0, 16(s0)
    li a0, 1
    j .Lm_append_done
.Lm_append_no:
    li a0, 0
.Lm_append_done:
    ld s0, 0(sp)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret
m_literal:
    mv a2, a1
    la a1, m_literal_format
    li a3, 0
    li a4, 0
    tail m_append

/* Private mutex operations; no arguments/results. Frame16; never nested. */
m_lock:
    addi sp, sp, -16
    sd ra, 8(sp)
    la a0, m_mutex
    call pthread_mutex_lock
    ld ra, 8(sp)
    addi sp, sp, 16
    bnez a0, m_fatal
    ret
m_unlock:
    addi sp, sp, -16
    sd ra, 8(sp)
    la a0, m_mutex
    call pthread_mutex_unlock
    ld ra, 8(sp)
    addi sp, sp, 16
    bnez a0, m_fatal
    ret
m_disable:
    addi sp, sp, -16
    sd ra, 8(sp)
    call m_lock
    la t0, m_health
    sw zero, 0(t0)
    call m_unlock
    ld ra, 8(sp)
    addi sp, sp, 16
    ret

/* No return. Fixed stderr only; Linux short writes/EINTR handled without locks. */
m_fatal:
    la s0, m_sync_error
    la s1, m_sync_error_end
    sub s1, s1, s0
    addi s1, s1, -1
.Lm_fatal_write:
    beqz s1, .Lm_fatal_exit
    li a0, 2
    mv a1, s0
    mv a2, s1
    li a7, 64
    ecall
    li t0, -4
    beq a0, t0, .Lm_fatal_write
    blez a0, .Lm_fatal_exit
    add s0, s0, a0
    sub s1, s1, a0
    j .Lm_fatal_write
.Lm_fatal_exit:
    li a0, 71
    li a7, 94
    ecall
    unimp

#ifdef ASM_METRICS_TEST
/* Trusted632-byte fixture hooks only. Frame16 saves s0/ra. */
.globl asm_metrics_test_seed
asm_metrics_test_seed:
    addi sp, sp, -16
    sd s0, 0(sp)
    sd ra, 8(sp)
    mv s0, a0
    call m_lock
    la a0, m_table
    mv a1, s0
    li a2, METRICS_BYTES
    call memcpy
    la t0, m_health
    li t1, 1
    sw t1, 0(t0)
    call m_unlock
    ld s0, 0(sp)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret
.globl asm_metrics_test_snapshot
asm_metrics_test_snapshot:
    addi sp, sp, -16
    sd s0, 0(sp)
    sd ra, 8(sp)
    mv s0, a0
    call m_lock
    mv a0, s0
    la a1, m_table
    li a2, METRICS_BYTES
    call memcpy
    call m_unlock
    ld s0, 0(sp)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret
#endif
.section .note.GNU-stack,"",@progbits
