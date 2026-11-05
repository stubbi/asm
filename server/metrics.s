/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux x86-64 System V LP64. All public calls preserve RBX,RBP,R12-R15.
 * Pointer arguments borrow caller-owned storage during the call only.
 * No allocation, SQL, network operation, or formatting occurs under the mutex.
 */
.intel_syntax noprefix
#include "metrics-data.inc"
.section .text

/* No input. EAX=1 after initialization,0 if mutex initialization fails.
 * Called once before worker creation; resets fixed state. Stack8 saved bytes. */
.globl asm_metrics_init
.type asm_metrics_init,@function
asm_metrics_init:
    sub rsp, 8
    lea rdi, [rip + m_table]
    xor esi, esi
    mov edx, METRICS_BYTES
    call memset@PLT
    mov dword ptr [rip + m_health], 0
    lea rdi, [rip + m_mutex]
    xor esi, esi
    call pthread_mutex_init@PLT
    test eax, eax
    jnz .Lm_init_no
    mov dword ptr [rip + m_health], 1
    mov eax, 1
    add rsp, 8
    ret
.Lm_init_no:
    xor eax, eax
    add rsp, 8
    ret

/* No input/output. Caller has joined every request thread. Stack8 bytes. */
.globl asm_metrics_destroy
.type asm_metrics_destroy,@function
asm_metrics_destroy:
    sub rsp, 8
    lea rdi, [rip + m_mutex]
    call pthread_mutex_destroy@PLT
    test eax, eax
    jnz m_fatal
    mov dword ptr [rip + m_health], 0
    add rsp, 8
    ret

/* RDI=borrowed NUL path already bounded by HTTP policy; EAX=fixed route0..5.
 * Never called on the overlong URI marker. Stack24 saved bytes. */
.globl asm_metrics_route
.type asm_metrics_route,@function
asm_metrics_route:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    lea r12, [rip + m_paths]
.Lm_route_next:
    mov rsi, [r12]
    test rsi, rsi
    jz .Lm_route_other
    mov rdi, rbx
    call strcmp@PLT
    test eax, eax
    jz .Lm_route_found
    add r12, 16
    jmp .Lm_route_next
.Lm_route_other:
    mov eax, 5
    jmp .Lm_route_done
.Lm_route_found:
    mov eax, [r12 + 8]
.Lm_route_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

/* RDI=owned16-byte stack request. Writes start,route=other,and valid flag.
 * Failure disables exposition, never substitutes a zero duration. Stack8. */
.globl asm_metrics_begin
.type asm_metrics_begin,@function
asm_metrics_begin:
    push rbx
    mov rbx, rdi
    call m_clock
    mov [rbx], rax
    mov dword ptr [rbx + 8], 5
    mov [rbx + 12], edx
    test edx, edx
    jnz .Lm_begin_done
    call m_disable
.Lm_begin_done:
    pop rbx
    ret

/* RDI=request,ESI=HTTP status,EDX=MHD result0/1; EAX=original MHD result.
 * Queued responses update one checked transaction; failures update scalar only.
 * Stack40 saved bytes. It never takes ownership of an HTTP/PG object. */
.globl asm_metrics_finish
.type asm_metrics_finish,@function
asm_metrics_finish:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    test edx, edx
    jz .Lm_finish_lock
    cmp edx, 1
    jne .Lm_finish_bad
    cmp dword ptr [rbx + 12], 1
    jne .Lm_finish_bad
    call m_clock
    test edx, edx
    jz .Lm_finish_bad
    sub rax, [rbx]
    jc .Lm_finish_bad
    mov r14, rax
    cmp dword ptr [rbx + 8], 5
    ja .Lm_finish_bad
    mov eax, r12d
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp eax, 2
    je .Lm_class_two
    sub eax, 3
    cmp eax, 1
    jb .Lm_finish_bad
    cmp eax, 2
    ja .Lm_finish_bad
    mov r12d, eax
    jmp .Lm_finish_lock
.Lm_class_two:
    xor r12d, r12d
.Lm_finish_lock:
    call m_lock
    cmp dword ptr [rip + m_health], 1
    jne .Lm_finish_unlock
    test r13d, r13d
    jz .Lm_failure_count
    mov eax, [rbx + 8]
    imul rax, METRICS_ROW
    lea r15, [rip + m_table]
    add r15, rax
    cmp qword ptr [r15 + r12*8], -1
    je .Lm_finish_overflow
    cmp qword ptr [r15 + METRICS_COUNT], -1
    je .Lm_finish_overflow
    mov rax, [r15 + METRICS_SUM]
    add rax, r14
    jc .Lm_finish_overflow
    xor ecx, ecx
    lea rdx, [rip + m_bucket_ns]
.Lm_bucket_check:
    cmp r14, [rdx + rcx*8]
    ja .Lm_bucket_check_next
    cmp qword ptr [r15 + rcx*8 + 24], -1
    je .Lm_finish_overflow
.Lm_bucket_check_next:
    inc ecx
    cmp ecx, 8
    jb .Lm_bucket_check
    inc qword ptr [r15 + r12*8]
    inc qword ptr [r15 + METRICS_COUNT]
    add [r15 + METRICS_SUM], r14
    xor ecx, ecx
.Lm_bucket_update:
    cmp r14, [rdx + rcx*8]
    ja .Lm_bucket_update_next
    inc qword ptr [r15 + rcx*8 + 24]
.Lm_bucket_update_next:
    inc ecx
    cmp ecx, 8
    jb .Lm_bucket_update
    jmp .Lm_finish_unlock
.Lm_failure_count:
    cmp qword ptr [rip + m_table + METRICS_FAILURES], -1
    je .Lm_finish_overflow
    inc qword ptr [rip + m_table + METRICS_FAILURES]
    jmp .Lm_finish_unlock
.Lm_finish_overflow:
    mov dword ptr [rip + m_health], 0
.Lm_finish_unlock:
    call m_unlock
    jmp .Lm_finish_done
.Lm_finish_bad:
    call m_disable
.Lm_finish_done:
    mov eax, r13d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=output buffer,RSI=capacity. RAX=positive bytes or-1 (never partial HTTP).
 * Uses at most16KiB of caller storage and a632-byte consistent local snapshot.
 * Stack672 local+40 saved bytes. Fixed integer-only snprintf formats. */
.globl asm_metrics_render
.type asm_metrics_render,@function
asm_metrics_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 672
    mov rbx, rsp
    lea r12, [rsp + 32]
    test rdi, rdi
    jz .Lm_render_bad
    test rsi, rsi
    jz .Lm_render_bad
    cmp rsi, METRICS_REPLY
    jbe .Lm_render_capacity
    mov esi, METRICS_REPLY
.Lm_render_capacity:
    mov [rbx], rdi
    mov [rbx + 8], rsi
    mov qword ptr [rbx + 16], 0
    call m_lock
    cmp dword ptr [rip + m_health], 1
    jne .Lm_render_unavailable
    mov rdi, r12
    lea rsi, [rip + m_table]
    mov edx, METRICS_BYTES
    call memcpy@PLT
    call m_unlock
    mov rdi, rbx
    lea rsi, [rip + m_requests_header]
    call m_literal
    test eax, eax
    jz .Lm_render_bad
    xor r13d, r13d
.Lm_render_requests_route:
    imul r15, r13, METRICS_ROW
    add r15, r12
    xor r14d, r14d
.Lm_render_request_class:
    mov rdi, rbx
    lea rsi, [rip + m_requests_format]
    lea rax, [rip + m_routes]
    mov rdx, [rax + r13*8]
    lea rax, [rip + m_classes]
    mov rcx, [rax + r14*8]
    mov r8, [r15 + r14*8]
    call m_append
    test eax, eax
    jz .Lm_render_bad
    inc r14d
    cmp r14d, 3
    jb .Lm_render_request_class
    inc r13d
    cmp r13d, 6
    jb .Lm_render_requests_route
    mov rdi, rbx
    lea rsi, [rip + m_duration_header]
    call m_literal
    test eax, eax
    jz .Lm_render_bad
    xor r13d, r13d
.Lm_render_duration_route:
    imul r15, r13, METRICS_ROW
    add r15, r12
    xor r14d, r14d
.Lm_render_bucket:
    mov rdi, rbx
    lea rsi, [rip + m_bucket_format]
    lea rax, [rip + m_routes]
    mov rdx, [rax + r13*8]
    lea rax, [rip + m_boundaries]
    mov rcx, [rax + r14*8]
    mov r8, [r15 + r14*8 + 24]
    call m_append
    test eax, eax
    jz .Lm_render_bad
    inc r14d
    cmp r14d, 8
    jb .Lm_render_bucket
    mov rax, [r15 + METRICS_SUM]
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov r8, rdx
    mov rcx, rax
    lea rax, [rip + m_routes]
    mov rdx, [rax + r13*8]
    mov rdi, rbx
    lea rsi, [rip + m_sum_format]
    call m_append
    test eax, eax
    jz .Lm_render_bad
    mov rdi, rbx
    lea rsi, [rip + m_count_format]
    lea rax, [rip + m_routes]
    mov rdx, [rax + r13*8]
    mov rcx, [r15 + METRICS_COUNT]
    xor r8d, r8d
    call m_append
    test eax, eax
    jz .Lm_render_bad
    inc r13d
    cmp r13d, 6
    jb .Lm_render_duration_route
    mov rdi, rbx
    lea rsi, [rip + m_failures_header]
    call m_literal
    test eax, eax
    jz .Lm_render_bad
    mov rdi, rbx
    lea rsi, [rip + m_failures_format]
    mov rdx, [r12 + METRICS_FAILURES]
    xor ecx, ecx
    xor r8d, r8d
    call m_append
    test eax, eax
    jz .Lm_render_bad
    mov rax, [rbx + 16]
    jmp .Lm_render_done
.Lm_render_unavailable:
    call m_unlock
    mov rax, -1
    jmp .Lm_render_done
.Lm_render_bad:
    call m_disable
    mov rax, -1
.Lm_render_done:
    add rsp, 672
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Private clock: RAX=ns,RDX=valid. One24-byte aligned timespec workspace. */
m_clock:
    sub rsp, 24
    mov edi, 1
    mov rsi, rsp
    call clock_gettime@PLT
    test eax, eax
    jnz .Lm_clock_no
    mov rax, [rsp]
    test rax, rax
    js .Lm_clock_no
    mov rcx, [rsp + 8]
    cmp rcx, 1000000000
    jae .Lm_clock_no
    mov esi, 1000000000
    mul rsi
    test rdx, rdx
    jnz .Lm_clock_no
    add rax, rcx
    jc .Lm_clock_no
    mov edx, 1
    add rsp, 24
    ret
.Lm_clock_no:
    xor eax, eax
    xor edx, edx
    add rsp, 24
    ret

/* RDI=builder{current,remaining,total},RSI=fixed format,RDX/RCX/R8=arguments.
 * EAX=1 iff complete; remaining includes a NUL byte. Stack8 saved bytes. */
m_append:
    push rbx
    mov rbx, rdi
    mov r9, r8
    mov r8, rcx
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, [rbx + 8]
    mov rdi, [rbx]
    xor eax, eax
    call snprintf@PLT
    test eax, eax
    jle .Lm_append_no
    mov eax, eax
    cmp rax, [rbx + 8]
    jae .Lm_append_no
    add [rbx], rax
    sub [rbx + 8], rax
    add [rbx + 16], rax
    mov eax, 1
    pop rbx
    ret
.Lm_append_no:
    xor eax, eax
    pop rbx
    ret

/* RDI=builder,RSI=fixed NUL literal. Uses the same checked formatter. */
m_literal:
    mov rdx, rsi
    lea rsi, [rip + m_literal_format]
    xor ecx, ecx
    xor r8d, r8d
    jmp m_append

/* Private mutex helpers: no args/results; no caller holds the mutex. Stack8. */
m_lock:
    sub rsp, 8
    lea rdi, [rip + m_mutex]
    call pthread_mutex_lock@PLT
    add rsp, 8
    test eax, eax
    jnz m_fatal
    ret
m_unlock:
    sub rsp, 8
    lea rdi, [rip + m_mutex]
    call pthread_mutex_unlock@PLT
    add rsp, 8
    test eax, eax
    jnz m_fatal
    ret
m_disable:
    sub rsp, 8
    call m_lock
    mov dword ptr [rip + m_health], 0
    call m_unlock
    add rsp, 8
    ret

/* Fatal synchronization error. Fixed stderr only; short writes/EINTR handled.
 * No return. Direct Linux write avoids another libc lock during failure. */
m_fatal:
    lea r12, [rip + m_sync_error]
    mov r13d, M_SYNC_ERROR_LENGTH
.Lm_fatal_write:
    test r13, r13
    jz .Lm_fatal_exit
    mov eax, 1
    mov edi, 2
    mov rsi, r12
    mov rdx, r13
    syscall
    cmp rax, -4
    je .Lm_fatal_write
    test rax, rax
    jle .Lm_fatal_exit
    add r12, rax
    sub r13, rax
    jmp .Lm_fatal_write
.Lm_fatal_exit:
    mov eax, 231
    mov edi, 71
    syscall
    ud2

#ifdef ASM_METRICS_TEST
/* Test-only trusted632-byte fixture source/destination. Never in runtime.
 * Seed resets health; snapshot permits reading the last valid disabled table. */
.globl asm_metrics_test_seed
asm_metrics_test_seed:
    push rbx
    mov rbx, rdi
    call m_lock
    lea rdi, [rip + m_table]
    mov rsi, rbx
    mov edx, METRICS_BYTES
    call memcpy@PLT
    mov dword ptr [rip + m_health], 1
    call m_unlock
    pop rbx
    ret
.globl asm_metrics_test_snapshot
asm_metrics_test_snapshot:
    push rbx
    mov rbx, rdi
    call m_lock
    mov rdi, rbx
    lea rsi, [rip + m_table]
    mov edx, METRICS_BYTES
    call memcpy@PLT
    call m_unlock
    pop rbx
    ret
#endif
.section .note.GNU-stack,"",@progbits
