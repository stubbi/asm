/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux x86-64 System V, glibc >= 2.34. Startup only, before HTTP threads.
 * libc owns NSS resolution. All asynchronous request storage lives to exit.
 * A kernel-owned SIGKILL timer covers masked helper creation as well.
 */
.intel_syntax noprefix
.equ DNS_SECONDS, 2
.equ DNS_CONFIG_LIMIT, 4096
.equ DNS_HOSTADDR_BYTES, 10
.equ DNS_SIGALRM, 14
.equ DNS_SIGPIPE, 13
.equ DNS_EXIT_GROUP, 231

.section .rodata
dns_suffix: .ascii "&hostaddr="
dns_error: .ascii "asm-hub: database address resolution failed. Check the hostname and resolver service.\n"
.equ DNS_ERROR_BYTES, .-dns_error

.section .bss
.balign 8
dns_request: .zero 56
dns_requests: .zero 8
dns_hints: .zero 48
dns_notification: .zero 64
dns_alarm_set: .zero 128
dns_pipe_set: .zero 128
dns_old_mask: .zero 128
dns_pending: .zero 128
dns_old_timer: .zero 32
dns_hard_event: .zero 64
dns_hard_id: .zero 8
dns_hard_value: .zero 32
dns_deadline: .zero 16
dns_remaining_time: .zero 16
dns_now: .zero 16
dns_numeric: .zero 16

.section .text
.globl resolve_database_address
.type resolve_database_address,@function
/* RDI=persistent validated hostname[1..253] plus NUL; db_config[4098] owned.
 * EAX=1 on success; refusals terminate every process thread with 78.
 * A DNS deadline can instead terminate through the owned SIGKILL timer.
 * Preserves callee-saved registers, uses 24 saved stack bytes, caller-saved
 * scratch. One gaicb, one IPv4 stream/TCP result; no requests after startup.
 * libc signal layouts are checked by abi-check.c, never used as raw layouts.
 */
resolve_database_address:
    push rbx
    push r12
    push r13
    mov [rip + dns_request], rdi
    lea rax, [rip + dns_hints]
    mov [rip + dns_request + 16], rax
    mov dword ptr [rip + dns_hints + 4], 2
    mov dword ptr [rip + dns_hints + 8], 1
    mov dword ptr [rip + dns_hints + 12], 6
    lea rax, [rip + dns_request]
    mov [rip + dns_requests], rax
    mov dword ptr [rip + dns_notification + 12], 1
    lea rdi, [rip + dns_alarm_set]
    call sigemptyset@PLT
    test eax, eax
    jnz dns_exit
    lea rdi, [rip + dns_alarm_set]
    mov esi, DNS_SIGALRM
    call sigaddset@PLT
    test eax, eax
    jnz dns_exit
    xor edi, edi
    lea rsi, [rip + dns_alarm_set]
    lea rdx, [rip + dns_old_mask]
    call sigprocmask@PLT
    test eax, eax
    jnz dns_exit
    xor edi, edi
    lea rsi, [rip + dns_old_timer]
    call getitimer@PLT
    test eax, eax
    jnz dns_exit
    mov rax, [rip + dns_old_timer]
    or rax, [rip + dns_old_timer + 8]
    or rax, [rip + dns_old_timer + 16]
    or rax, [rip + dns_old_timer + 24]
    jnz dns_exit
    call dns_check_pending
    test eax, eax
    jz dns_exit
    mov edi, 1
    lea rsi, [rip + dns_deadline]
    call clock_gettime@PLT
    test eax, eax
    jnz dns_exit
    add qword ptr [rip + dns_deadline], DNS_SECONDS
    mov dword ptr [rip + dns_hard_event + 8], 9
    mov edi, 1
    lea rsi, [rip + dns_hard_event]
    lea rdx, [rip + dns_hard_id]
    call timer_create@PLT
    test eax, eax
    jnz dns_exit
    mov rax, [rip + dns_deadline]
    mov [rip + dns_hard_value + 16], rax
    mov rax, [rip + dns_deadline + 8]
    mov [rip + dns_hard_value + 24], rax
    mov rdi, [rip + dns_hard_id]
    mov esi, 1
    lea rdx, [rip + dns_hard_value]
    xor ecx, ecx
    call timer_settime@PLT
    test eax, eax
    jnz dns_exit
    /* Restore the caller mask before submission; SIGKILL cannot be masked. */
    mov edi, 2
    lea rsi, [rip + dns_old_mask]
    xor edx, edx
    call sigprocmask@PLT
    test eax, eax
    jnz dns_exit
    mov edi, 1
    lea rsi, [rip + dns_requests]
    mov edx, 1
    lea rcx, [rip + dns_notification]
    call getaddrinfo_a@PLT
    test eax, eax
    jnz dns_refuse
.Ldns_poll:
    lea rdi, [rip + dns_request]
    call gai_error@PLT
    test eax, eax
    jz .Ldns_result
    cmp eax, -100
    jne dns_refuse
    call dns_remaining
    test eax, eax
    jz dns_refuse
    lea rdi, [rip + dns_requests]
    mov esi, 1
    lea rdx, [rip + dns_remaining_time]
    call gai_suspend@PLT
    test eax, eax
    jz .Ldns_poll
    cmp eax, -104
    je .Ldns_poll
    cmp eax, -103
    je .Ldns_poll
    cmp eax, -3
    je .Ldns_poll
    jmp dns_refuse
.Ldns_result:
    mov rbx, [rip + dns_request + 24]
    test rbx, rbx
    jz dns_refuse
    cmp dword ptr [rbx + 4], 2
    jne dns_refuse
    cmp dword ptr [rbx + 8], 1
    jne dns_refuse
    cmp dword ptr [rbx + 12], 6
    jne dns_refuse
    cmp dword ptr [rbx + 16], 16
    jne dns_refuse
    mov rsi, [rbx + 24]
    test rsi, rsi
    jz dns_refuse
    cmp word ptr [rsi], 2
    jne dns_refuse
    add rsi, 4
    mov edi, 2
    lea rdx, [rip + dns_numeric]
    mov ecx, 16
    call inet_ntop@PLT
    test rax, rax
    jz dns_refuse
    lea rdi, [rip + db_config]
    mov esi, DNS_CONFIG_LIMIT + 1
    call strnlen@PLT
    cmp rax, DNS_CONFIG_LIMIT
    ja dns_refuse
    mov r12, rax
    lea rdi, [rip + dns_numeric]
    mov esi, 16
    call strnlen@PLT
    cmp rax, 15
    ja dns_refuse
    test eax, eax
    jz dns_refuse
    mov r13, rax
    lea rax, [r12 + r13 + DNS_HOSTADDR_BYTES]
    cmp rax, DNS_CONFIG_LIMIT
    ja dns_refuse
    lea rdi, [rip + db_config]
    add rdi, r12
    lea rsi, [rip + dns_suffix]
    mov edx, DNS_HOSTADDR_BYTES
    call memcpy@PLT
    lea rdi, [rip + db_config]
    add rdi, r12
    add rdi, DNS_HOSTADDR_BYTES
    lea rsi, [rip + dns_numeric]
    lea rdx, [r13 + 1]
    call memcpy@PLT
    mov rdi, rbx
    call freeaddrinfo@PLT
    /* Pending inherited ALRM must not become a successful startup. */
    xor edi, edi
    lea rsi, [rip + dns_alarm_set]
    xor edx, edx
    call sigprocmask@PLT
    test eax, eax
    jnz dns_exit
    call dns_remaining
    test eax, eax
    jz dns_exit
    call dns_check_pending
    test eax, eax
    jz dns_exit
    mov edi, 2
    lea rsi, [rip + dns_old_mask]
    xor edx, edx
    call sigprocmask@PLT
    test eax, eax
    jnz dns_exit
    mov rdi, [rip + dns_hard_id]
    call timer_delete@PLT
    test eax, eax
    jnz dns_exit
    call dns_remaining
    test eax, eax
    jz dns_exit
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.size resolve_database_address,.-resolve_database_address

/* No inputs. EAX=1 iff the monotonic deadline is still future; remaining
 * timespec[16] is normalized. Caller-saved only, 8 stack bytes for alignment. */
dns_remaining:
    sub rsp, 8
    mov edi, 1
    lea rsi, [rip + dns_now]
    call clock_gettime@PLT
    test eax, eax
    jnz .Ldns_no_time
    mov rax, [rip + dns_deadline]
    sub rax, [rip + dns_now]
    mov rdx, [rip + dns_deadline + 8]
    sub rdx, [rip + dns_now + 8]
    jns .Ldns_normal_time
    dec rax
    add rdx, 1000000000
.Ldns_normal_time:
    test rax, rax
    js .Ldns_no_time
    jnz .Ldns_have_time
    test rdx, rdx
    jz .Ldns_no_time
.Ldns_have_time:
    mov [rip + dns_remaining_time], rax
    mov [rip + dns_remaining_time + 8], rdx
    mov eax, 1
    add rsp, 8
    ret
.Ldns_no_time:
    xor eax, eax
    add rsp, 8
    ret

/* No inputs. EAX=1 iff no blocked SIGALRM is pending. Caller-saved, stack8. */
dns_check_pending:
    sub rsp, 8
    lea rdi, [rip + dns_pending]
    call sigpending@PLT
    test eax, eax
    jnz .Ldns_pending_bad
    lea rdi, [rip + dns_pending]
    mov esi, DNS_SIGALRM
    call sigismember@PLT
    test eax, eax
    setz al
    movzx eax, al
    add rsp, 8
    ret
.Ldns_pending_bad:
    xor eax, eax
    add rsp, 8
    ret

/* Fatal path reached with main's three saves still on stack. Block SIGPIPE
 * so a closed diagnostic pipe still exits78; SIGKILL remains unmaskable.
 * A full pipe remains covered by the hard timer; no cleanup/cancel is used. */
dns_refuse:
    lea rdi, [rip + dns_pipe_set]
    call sigemptyset@PLT
    test eax, eax
    jnz dns_exit
    lea rdi, [rip + dns_pipe_set]
    mov esi, DNS_SIGPIPE
    call sigaddset@PLT
    test eax, eax
    jnz dns_exit
    xor edi, edi
    lea rsi, [rip + dns_pipe_set]
    xor edx, edx
    call sigprocmask@PLT
    test eax, eax
    jnz dns_exit
    lea r12, [rip + dns_error]
    mov r13d, DNS_ERROR_BYTES
    mov ebx, 16
.Ldns_write_error:
    mov eax, 1
    mov edi, 2
    mov rsi, r12
    mov rdx, r13
    syscall
    cmp rax, -4
    jne .Ldns_error_progress
    dec ebx
    jnz .Ldns_write_error
    jmp dns_exit
.Ldns_error_progress:
    test rax, rax
    jle dns_exit
    add r12, rax
    sub r13, rax
    jnz .Ldns_write_error
dns_exit:
    mov eax, DNS_EXIT_GROUP
    mov edi, 78
    syscall
    ud2

.section .note.GNU-stack,"",@progbits
