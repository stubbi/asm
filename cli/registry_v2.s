/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Explicit, optional native registry V2 client. No V1 fallback.
 * SysV internal ABI: arguments RDI/RSI/RDX/RCX; result RAX. Returning routines
 * preserve RBX/RBP/R12-R15. Other integer registers/flags are scratch.
 * All state is process-owned and serial. Bounds: control JSON 65536 bytes,
 * 15 unique objects, 64MiB/object, 128MiB/task, three mirrors, 4095-byte paths.
 * Mature fixed executables provide HTTPS, SHA256, gzip and TUF verification.
 * Assembly alone parses manifests, selects targets and changes local files.
 */
.intel_syntax noprefix
.equ R2_CONTROL, 65536
.equ R2_OBJECTS, 15
.equ R2_RECORD, 96
.equ R2_OBJECT_RECEIVED, 80
.equ R2_TASK_BYTES, 134217728
.section .text
cmd_registry_v2:
    mov byte ptr [rip + r2_active], 1
    call next_arg
    test rax, rax
    jz r2_arguments
    mov r12, rax
    lea rbx, [rip + r2_commands]
.Lr2_command:
    mov rsi, [rbx]
    test rsi, rsi
    jz r2_arguments
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lr2_command_found
    add rbx, 16
    jmp .Lr2_command
.Lr2_command_found:
    mov rax, [rbx + 8]
    test rax, rax
    jz r2_help
    mov [rip + r2_mode], rax
    cmp eax, 2
    jb .Lr2_options
    cmp eax, 5
    jae .Lr2_options
    call next_arg
    test rax, rax
    jz r2_arguments
    mov [rip + r2_selector], rax
.Lr2_options:
    call next_arg
    test rax, rax
    jz .Lr2_options_done
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + registry_opt_json]
    call streq
    test eax, eax
    jnz .Lr2_json_option
    mov rdi, r12
    lea rsi, [rip + registry_opt_help]
    call streq
    test eax, eax
    jnz r2_help
    mov rdi, r12
    lea rsi, [rip + r2_opt_mirror]
    call streq
    test eax, eax
    jnz .Lr2_mirror_option
    mov rdi, r12
    call r4_option
    test eax, eax
    jnz .Lr2_options
    mov rdi, r12
    call r2p_option
    test eax, eax
    jnz .Lr2_options
    lea rbx, [rip + r2_options]
.Lr2_option:
    mov rsi, [rbx]
    test rsi, rsi
    jz r2_arguments
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lr2_option_found
    add rbx, 24
    jmp .Lr2_option
.Lr2_option_found:
    mov rax, [rbx + 16]
    test [rip + r2_fields], rax
    jnz r2_arguments
    or [rip + r2_fields], rax
    call registry_arg_value
    mov rdx, [rbx + 8]
    mov [rdx], rax
    jmp .Lr2_options
.Lr2_json_option:
    mov byte ptr [rip + json_mode], 1
    jmp .Lr2_options
.Lr2_mirror_option:
    cmp qword ptr [rip + r2_mirror_count], 3
    jae r2_arguments
    call registry_arg_value
    mov r12, rax
    mov rdi, rax
    call r2_origin
    test eax, eax
    jz r2_arguments
    mov rcx, [rip + r2_mirror_count]
    lea rdx, [rip + r2_mirrors]
    mov [rdx + rcx*8], r12
    inc qword ptr [rip + r2_mirror_count]
    jmp .Lr2_options
.Lr2_options_done:
    mov rax, [rip + r2_mode]
    mov rdx, [rip + r2_fields]
    and rdx, -257
    cmp eax, 5
    jae r3_command
    cmp eax, 2
    ja r2_receive
    cmp eax, 1
    je .Lr2_publish_fields
    cmp rdx, 12
    jne r2_arguments
    mov rdi, [rip + r2_selector]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_arguments
    lea rdi, [rip + r2_task_id]
    mov rsi, [rip + r2_selector]
    call copy_string
    jmp .Lr2_auth_start
.Lr2_publish_fields:
    cmp qword ptr [rip + r2p_project], 0
    je .Lr2_prepared_fields
    call r2p_arguments
    jmp .Lr2_publish_key
.Lr2_prepared_fields:
    cmp rdx, 31
    jne r2_arguments
.Lr2_publish_key:
    mov rdi, [rip + r2_key]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_arguments
.Lr2_auth_start:
    cmp qword ptr [rip + r2_mirror_count], 0
    jne r2_arguments
    cmp qword ptr [rip + r2_ca], 0
    je .Lr2_auth_origin
    mov rdi, [rip + r2_ca]
    xor esi, esi
    mov edx, 2
    call r2_open_path
    mov rdi, rax
    mov eax, 3
    syscall
.Lr2_auth_origin:
    mov rdi, [rip + r2_api]
    call r2_origin
    test eax, eax
    jz r2_arguments
    call r2_workspace
    cmp qword ptr [rip + r2p_project], 0
    jne .Lr2_prepare_project
    call r2p_credential_identity
    jmp .Lr2_read_credential
.Lr2_prepare_project:
    call r2_project_prepare
.Lr2_read_credential:
    call r2_credential_header
    cmp qword ptr [rip + r2_mode], 1
    je r2_publish
    call r2_task_url
    lea rdi, [rip + r2_method_get]
    xor esi, esi
    call r2_http
    cmp eax, 200
    jne r2_http_error
    call r2_parse_task
    jmp r2_report

r2_help:
    lea rdi, [rip + r2_help_text]
    call out
    call registry_cleanup
    jmp exit_ok
r2_arguments:
    lea rdi, [rip + r2_err_arguments]
    mov esi, 2
    jmp registry_fail
r2_invalid:
    cmp byte ptr [rip + r3_active], 0
    jne r3_metadata_error
    cmp byte ptr [rip + r2_post_attempted], 0
    jne .Lr2_invalid_after_post
    cmp qword ptr [rip + r2p_project], 0
    jne r2p_bad
    lea rdi, [rip + r2_err_manifest]
    mov esi, 1
    jmp registry_fail
.Lr2_invalid_after_post:
    lea rdi, [rip + r2_err_http]
    mov esi, 1
    jmp registry_fail
r2_io:
    cmp byte ptr [rip + r2_post_attempted], 0
    jne .Lr2_invalid_after_post
    lea rdi, [rip + r2_err_io]
    mov esi, 1
    jmp registry_fail
r2_trust_error:
    cmp byte ptr [rip + r3_active], 0
    jne r3_metadata_error
    lea rdi, [rip + r2_err_trust]
    mov esi, 1
    jmp registry_fail
r2_http_error:
    cmp eax, 401
    je .Lr2_credential_refused
    cmp eax, 403
    je .Lr2_scope_refused
    cmp eax, 410
    je .Lr2_upload_expired
    lea rdi, [rip + r2_err_http]
    jmp .Lr2_http_die
.Lr2_credential_refused:
    lea rdi, [rip + r2_err_credential]
    jmp .Lr2_http_die
.Lr2_scope_refused:
    lea rdi, [rip + r2_err_scope]
    jmp .Lr2_http_die
.Lr2_upload_expired:
    lea rdi, [rip + r2_err_expired]
.Lr2_http_die:
    mov esi, 1
    jmp registry_fail
r2_legacy_upgrade:
    lea rdi, [rip + r2_err_upgrade]
    mov esi, 1
    jmp registry_fail

/* RDI=NUL string, ESI=exact lowercase hex length. EAX=1/0. No stack. */
r2_hex:
    xor ecx, ecx
.Lr2_hex_byte:
    cmp ecx, esi
    jae .Lr2_hex_end
    movzx eax, byte ptr [rdi + rcx]
    cmp al, '0'
    jb .Lr2_no
    cmp al, '9'
    jbe .Lr2_hex_next
    cmp al, 'a'
    jb .Lr2_no
    cmp al, 'f'
    ja .Lr2_no
.Lr2_hex_next:
    inc ecx
    jmp .Lr2_hex_byte
.Lr2_hex_end:
    cmp byte ptr [rdi + rcx], 0
    jne .Lr2_no
    mov eax, 1
    ret
.Lr2_no:
    xor eax, eax
    ret

/* Strict explicit HTTPS base, <=2048 bytes. No query, fragment, escaping,
 * credentials, backslash, trailing slash, empty or dot path components.
 * Input/output RDI unchanged; EAX=1/0; stack16. */
r2_origin:
    push rbx
    push r12
    mov r12, rdi
    call strlen
    cmp rax, 9
    jb .Lr2_origin_bad
    cmp rax, 2048
    ja .Lr2_origin_bad
    cmp byte ptr [r12 + rax - 1], '/'
    je .Lr2_origin_bad
    mov rdi, r12
    call registry_https_url
    test eax, eax
    jz .Lr2_origin_bad
    lea rbx, [r12 + 8]
    mov rdx, rbx
.Lr2_origin_byte:
    mov al, [rbx]
    test al, al
    jz .Lr2_origin_segment
    cmp al, '?'
    je .Lr2_origin_bad
    cmp al, '#'
    je .Lr2_origin_bad
    cmp al, '%'
    je .Lr2_origin_bad
    cmp al, '/'
    jne .Lr2_origin_next
    call .Lr2_origin_segment_check
    test eax, eax
    jz .Lr2_origin_bad
    lea rdx, [rbx + 1]
.Lr2_origin_next:
    inc rbx
    jmp .Lr2_origin_byte
.Lr2_origin_segment:
    call .Lr2_origin_segment_check
    jmp .Lr2_origin_return
.Lr2_origin_segment_check:
    cmp rdx, rbx
    je .Lr2_no
    cmp byte ptr [rdx], '.'
    jne .Lr2_origin_segment_ok
    lea rax, [rdx + 1]
    cmp rax, rbx
    je .Lr2_no
    cmp byte ptr [rdx + 1], '.'
    jne .Lr2_origin_segment_ok
    inc rax
    cmp rax, rbx
    je .Lr2_no
.Lr2_origin_segment_ok:
    mov eax, 1
    ret
.Lr2_origin_bad:
    xor eax, eax
.Lr2_origin_return:
    mov rdi, r12
    pop r12
    pop rbx
    ret

/* Open a caller path with descriptor-relative no-follow traversal. RDI=path
 * <=4095; ESI=0 regular,1 directory; EDX=1 additionally requires a private
 * credential file. Every directory is root/user-owned and not group/world
 * writable, except root-owned sticky directories. Darwin fstat refuses ACL
 * grants through the existing adapter. Result FD or fatal controlled error.
 * Preserves callee registers; path buffer4096, stat144; local stack48. */
r2_open_path:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi
    mov r13d, edx
    call strlen
    test rax, rax
    jz r2_io
    cmp rax, 4095
    ja r2_io
    mov rsi, rdi
    lea rdi, [rip + r2_path]
    call copy_string
    lea r14, [rip + r2_path]
    lea rdi, [rip + pub_dot]
    cmp byte ptr [r14], '/'
    jne .Lr2_open_start
    lea rdi, [rip + self_root]
    inc r14
.Lr2_open_start:
    mov eax, 2
    mov esi, O_NOFOLLOW + O_CLOEXEC + O_DIRECTORY
    xor edx, edx
    syscall
    test rax, rax
    js r2_io
    mov r15, rax
    call r2_directory_stat
.Lr2_walk_segment:
    mov rbx, r14
.Lr2_walk_scan:
    cmp byte ptr [rbx], 0
    je .Lr2_walk_last
    cmp byte ptr [rbx], '/'
    je .Lr2_walk_directory
    inc rbx
    jmp .Lr2_walk_scan
.Lr2_walk_directory:
    cmp rbx, r14
    je r2_io
    mov byte ptr [rbx], 0
    mov rdi, r14
    call r2_component
    test eax, eax
    jz r2_io
    mov eax, 257
    mov rdi, r15
    mov rsi, r14
    mov edx, O_NOFOLLOW + O_CLOEXEC + O_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js r2_io
    mov rbp, rax
    mov eax, 3
    mov rdi, r15
    syscall
    mov r15, rbp
    call r2_directory_stat
    lea r14, [rbx + 1]
    jmp .Lr2_walk_segment
.Lr2_walk_last:
    cmp rbx, r14
    je r2_io
    mov rdi, r14
    call r2_component
    test eax, eax
    jz r2_io
    mov eax, 257
    mov rdi, r15
    mov rsi, r14
    mov edx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    test r12d, r12d
    jz .Lr2_walk_flags
    or edx, O_DIRECTORY
.Lr2_walk_flags:
    xor r10d, r10d
    syscall
    test rax, rax
    js r2_io
    mov rbp, rax
    mov eax, 3
    mov rdi, r15
    syscall
    mov eax, 5
    mov rdi, rbp
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2_io
    mov eax, [rip + r2_stat + 24]
    and eax, 61440
    mov edx, 32768
    test r12d, r12d
    jz .Lr2_walk_kind
    mov edx, 16384
.Lr2_walk_kind:
    cmp eax, edx
    jne r2_io
    test r12d, r12d
    jz .Lr2_walk_private
    mov r15, rbp
    call r2_directory_stat
.Lr2_walk_private:
    test r13d, r13d
    jz .Lr2_walk_ok
    cmp qword ptr [rip + r2_stat + 16], 1
    jne r2_io
    mov eax, 102
    syscall
    cmp eax, [rip + r2_stat + 28]
    je .Lr2_private_owner
    cmp r13d, 2
    jne r2_io
    cmp dword ptr [rip + r2_stat + 28], 0
    jne r2_io
.Lr2_private_owner:
    cmp r13d, 2
    jne .Lr2_private_mode
    test dword ptr [rip + r2_stat + 24], 18
    jnz r2_io
    jmp .Lr2_walk_ok
.Lr2_private_mode:
    test dword ptr [rip + r2_stat + 24], 127
    jnz r2_io
.Lr2_walk_ok:
    mov rax, rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
r2_component:
    cmp word ptr [rdi], 0x002e
    je .Lr2_no
    cmp word ptr [rdi], 0x2e2e
    jne .Lr2_component_ok
    cmp byte ptr [rdi + 2], 0
    je .Lr2_no
.Lr2_component_ok:
    mov eax, 1
    ret
/* R15=directory FD; r2_path contains the traversal. Only directory ownership
 * checks. Root-owned sticky temporary directories are allowed; a private
 * descendant is still required for all outputs. Stack8. */
r2_directory_stat:
    sub rsp, 8
    mov eax, 5
    mov rdi, r15
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2_io
    mov eax, 102
    syscall
    mov edx, [rip + r2_stat + 28]
    cmp eax, edx
    je .Lr2_dir_mode
    test edx, edx
    jnz r2_io
.Lr2_dir_mode:
    test dword ptr [rip + r2_stat + 24], 18
    jz .Lr2_dir_ok
    test edx, edx
    jnz r2_io
    test dword ptr [rip + r2_stat + 24], 512
    jz r2_io
.Lr2_dir_ok:
    add rsp, 8
    ret

/* Input FD RDI, output RSI[capacity+1], RDX=capacity. EAX=length. Retains no
 * input FD; reads one extra byte to reject growth, handles EINTR/short reads.
 * Buffer belongs to caller; saved stack32. */
r2_read_fd:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
.Lr2_read:
    xor eax, eax
    mov rdi, r12
    lea rsi, [r13 + rbx]
    lea rdx, [r14 + 1]
    sub rdx, rbx
    syscall
    cmp rax, -4
    je .Lr2_read
    test rax, rax
    js r2_io
    jz .Lr2_read_done
    add rbx, rax
    cmp rbx, r14
    ja r2_invalid
    jmp .Lr2_read
.Lr2_read_done:
    mov eax, 3
    mov rdi, r12
    syscall
    test rax, rax
    js r2_io
    mov byte ptr [r13 + rbx], 0
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Require a protected current directory before creating the existing private
 * stage. Directory is traversed from its canonical absolute pathname. */
r2_workspace:
    sub rsp, 8
    mov eax, 79
    lea rdi, [rip + r2_cwd]
    mov esi, 4096
    syscall
    test rax, rax
    js r2_io
    lea rdi, [rip + r2_cwd]
    call strlen
    cmp rax, 3900             /* Absolute stage outputs must fit4096 bytes. */
    ja r2_io
    lea rdi, [rip + r2_cwd]
    mov esi, 1
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    mov eax, 3
    syscall
    call registry_workspace
    lea rdi, [rip + r2_header_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_header_suffix]
    call copy_string
    lea rdi, [rip + r2_helper_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_helper_suffix]
    call copy_string
    add rsp, 8
    ret

/* Read one exact token (optional final LF) from a private file. Write a private
 * fixed header file; the secret never appears in argv or child environment. */
r2_credential_header:
    sub rsp, 8
    mov rdi, [rip + r2_credential]
    xor esi, esi
    mov edx, 1
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_token]
    mov edx, 76
    call r2_read_fd
    cmp eax, 76
    jne .Lr2_token_size
    cmp byte ptr [rip + r2_token + 75], 10
    jne r2_io
    mov byte ptr [rip + r2_token + 75], 0
    dec eax
.Lr2_token_size:
    cmp eax, 75
    jne r2_io
    lea rdi, [rip + r2_token]
    lea rsi, [rip + r2_token_prefix]
    call self_prefix
    test rax, rax
    jz r2_io
    mov rdi, rax
    mov esi, 64
    call r2_hex
    test eax, eax
    jz r2_io
    lea rdi, [rip + r2_header]
    lea rsi, [rip + r2_authorization]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_token]
    call copy_string
    mov byte ptr [rax], 10
    inc rax
    cmp qword ptr [rip + r2_mode], 1
    jne .Lr2_header_end
    mov rdi, rax
    lea rsi, [rip + r2_idempotency]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + r2_key]
    call copy_string
    mov byte ptr [rax], 10
    inc rax
.Lr2_header_end:
    lea rsi, [rip + r2_header]
    sub rax, rsi
    mov rdx, rax
    lea rdi, [rip + r2_header_path]
    call r2_write_file
    lea rdi, [rip + r2_token]
    xor eax, eax
    mov ecx, 78
    rep stosb
    lea rdi, [rip + r2_header]
    mov ecx, 256
    rep stosb
    add rsp, 8
    ret

/* Exclusive0600 regular file. RDI=owned path, RSI=bytes, RDX=length<=64MiB.
 * EAX=0 success; controlled fatal on failure. Stack32; write_all retries. */
r2_write_file:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    mov eax, 2
    mov esi, O_NOFOLLOW + O_CLOEXEC + 193
    mov edx, 384
    syscall
    test rax, rax
    js r2_io
    mov r14, rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call write_all
    test rax, rax
    js r2_io
    mov eax, 3
    mov rdi, r14
    syscall
    test rax, rax
    js r2_io
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Fixed child invocation. RDI=executable, RSI=argv. Child stdout is a private
 * pipe, stderr /dev/null, stdin /dev/null, environment empty. Capture <=4bytes
 * (curl status only; verifier must emit nothing). Child alarm120s, reset mask
 * and disposition. Parent bounds capture and reaps every child. Stack56. */
r2_child:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov eax, 293
    lea rdi, [rip + r2_pipe]
    mov esi, O_CLOEXEC
    syscall
    test rax, rax
    js r2_io
    mov edi, [rip + r2_pipe]
    call arc_promote_fd
    test rax, rax
    js r2_io
    mov [rip + r2_pipe], eax
    mov edi, [rip + r2_pipe + 4]
    call arc_promote_fd
    test rax, rax
    js r2_io
    mov [rip + r2_pipe + 4], eax
    mov eax, 57
    syscall
    test rax, rax
    js r2_io
    jz .Lr2_child_process
    mov r14, rax
    mov eax, 3
    mov edi, [rip + r2_pipe + 4]
    syscall
    xor r15d, r15d
    xor ebp, ebp
.Lr2_child_read:
    xor eax, eax
    mov edi, [rip + r2_pipe]
    lea rsi, [rip + r2_status]
    add rsi, r15
    mov edx, 5
    sub rdx, r15
    syscall
    cmp rax, -4
    je .Lr2_child_read
    test rax, rax
    js .Lr2_child_kill
    jz .Lr2_child_reap
    add r15, rax
    cmp r15, 4
    ja .Lr2_child_kill
    jmp .Lr2_child_read
.Lr2_child_kill:
    mov ebp, 1
    mov eax, 62
    mov rdi, r14
    mov esi, 9
    syscall
.Lr2_child_reap:
    mov eax, 3
    mov edi, [rip + r2_pipe]
    syscall
.Lr2_child_wait:
    mov eax, 61
    mov rdi, r14
    lea rsi, [rip + r2_child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lr2_child_wait
    test rax, rax
    js r2_io
    mov [rip + r2_status_length], r15
    mov eax, [rip + r2_child_status]
    test ebp, ebp
    jz .Lr2_child_return
    mov eax, 1
.Lr2_child_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lr2_child_process:
    mov eax, 2
    lea rdi, [rip + self_dev_null]
    mov esi, 2
    xor edx, edx
    syscall
    test rax, rax
    js .Lr2_child_abort
    mov rbx, rax
    mov eax, 33
    mov rdi, rbx
    xor esi, esi
    syscall
    mov eax, 33
    mov rdi, rbx
    mov esi, 2
    syscall
    mov eax, 33
    mov edi, [rip + r2_pipe + 4]
    mov esi, 1
    syscall
    test rax, rax
    js .Lr2_child_abort
    mov eax, 13
    mov edi, 14
    lea rsi, [rip + self_default_signal]
    xor edx, edx
    mov r10d, 8
    syscall
    test rax, rax
    js .Lr2_child_abort
    mov eax, 14
    mov edi, 1
    lea rsi, [rip + self_alarm_signal_mask]
    xor edx, edx
    mov r10d, 8
    syscall
    test rax, rax
    js .Lr2_child_abort
    mov eax, 37
    mov edi, 120
    syscall
    /* Bound every child output file independently of declared HTTP length. */
    mov eax, 97
    mov edi, 1
    lea rsi, [rip + r2_rlimit]
    syscall
    test rax, rax
    js .Lr2_child_abort
    mov rax, [rip + r2_child_file_limit]
    cmp rax, [rip + r2_rlimit]
    cmova rax, [rip + r2_rlimit]
    mov [rip + r2_rlimit], rax
    mov rax, [rip + r2_child_file_limit]
    cmp rax, [rip + r2_rlimit + 8]
    cmova rax, [rip + r2_rlimit + 8]
    mov [rip + r2_rlimit + 8], rax
    mov eax, 160
    mov edi, 1
    lea rsi, [rip + r2_rlimit]
    syscall
    test rax, rax
    js .Lr2_child_abort
    mov eax, 59
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + arc_empty_env]
    syscall
.Lr2_child_abort:
    mov edi, 127
    mov eax, 60
    syscall
    ud2

/* RDI=GET/POST/PUT, RSI=owned bodypath or0. r2_url is validated/derived.
 * EAX=HTTP status or0. No redirects, config, netrc, cookies or ambient trust.
 * Body output <=65536, length/regularity checked before JSON parsing. */
r2_http:
    push rbx
    push r12
    mov r12, rsi
    mov [rip + r2_http_method], rdi
    mov eax, 87
    lea rdi, [rip + registry_temp_index]
    syscall
    lea rbx, [rip + r2_http_argv]
    lea rax, [rip + registry_curl]
    mov [rbx], rax
    lea rax, [rip + registry_curl_disable]
    mov [rbx + 8], rax
    lea rax, [rip + registry_curl_silent]
    mov [rbx + 16], rax
    lea rax, [rip + registry_curl_proto]
    mov [rbx + 24], rax
    lea rax, [rip + registry_curl_https]
    mov [rbx + 32], rax
    lea rax, [rip + registry_curl_connect_timeout]
    mov [rbx + 40], rax
    lea rax, [rip + registry_curl_fifteen]
    mov [rbx + 48], rax
    lea rax, [rip + registry_curl_max_time]
    mov [rbx + 56], rax
    lea rax, [rip + r2_seconds]
    mov [rbx + 64], rax
    lea rax, [rip + registry_curl_max_filesize]
    mov [rbx + 72], rax
    lea rax, [rip + r2_control_decimal]
    mov [rbx + 80], rax
    lea rax, [rip + registry_curl_output]
    mov [rbx + 88], rax
    lea rax, [rip + registry_temp_index]
    mov [rbx + 96], rax
    lea rax, [rip + r2_write_out]
    mov [rbx + 104], rax
    lea rax, [rip + r2_status_format]
    mov [rbx + 112], rax
    lea rax, [rip + r2_request]
    mov [rbx + 120], rax
    mov rax, [rip + r2_http_method]
    mov [rbx + 128], rax
    lea rax, [rip + r2_header_option]
    mov [rbx + 136], rax
    lea rdi, [rip + r2_header_argument]
    mov byte ptr [rdi], '@'
    inc rdi
    lea rsi, [rip + r2_header_path]
    call copy_string
    lea rax, [rip + r2_header_argument]
    mov [rbx + 144], rax
    mov ebx, 19
    test r12, r12
    jz .Lr2_http_ca
    lea rdi, [rip + r2_body_argument]
    mov byte ptr [rdi], '@'
    inc rdi
    mov rsi, r12
    call copy_string
    mov rax, [rip + r2_http_method]
    cmp byte ptr [rax], 'P'
    jne r2_http_error
    lea rax, [rip + r2_content_json]
    mov rdx, [rip + r2_http_method]
    cmp byte ptr [rdx + 1], 'U'
    jne .Lr2_http_post
    lea rax, [rip + r2_content_blob]
.Lr2_http_post:
    lea rdx, [rip + r2_http_argv]
    lea rcx, [rip + r2_header_option]
    mov [rdx + 19*8], rcx
    mov [rdx + 20*8], rax
    lea rax, [rip + r2_data_binary]
    mov [rdx + 21*8], rax
    lea rax, [rip + r2_body_argument]
    mov rcx, [rip + r2_http_method]
    cmp byte ptr [rcx + 1], 'U'
    jne .Lr2_http_body_ready
    lea rax, [rip + r2_upload_file]
    mov [rdx + 21*8], rax
    mov rax, r12
.Lr2_http_body_ready:
    mov [rdx + 22*8], rax
    mov ebx, 23
.Lr2_http_ca:
    mov rax, [rip + r2_ca]
    test rax, rax
    jz .Lr2_http_end
    lea rdx, [rip + r2_http_argv]
    lea rcx, [rip + r2_ca_option]
    mov [rdx + rbx*8], rcx
    inc ebx
    mov [rdx + rbx*8], rax
    inc ebx
.Lr2_http_end:
    lea rdx, [rip + r2_http_argv]
    lea rax, [rip + registry_separator]
    mov [rdx + rbx*8], rax
    inc ebx
    lea rax, [rip + r2_url]
    mov [rdx + rbx*8], rax
    inc ebx
    mov qword ptr [rdx + rbx*8], 0
    mov qword ptr [rip + r2_child_file_limit], R2_CONTROL
    lea rdi, [rip + registry_curl]
    lea rsi, [rip + r2_http_argv]
    call r2_child
    test eax, eax
    jnz .Lr2_http_fail
    cmp qword ptr [rip + r2_status_length], 3
    jne .Lr2_http_fail
    xor ebx, ebx
    xor ecx, ecx
.Lr2_status_digit:
    lea rdx, [rip + r2_status]
    movzx eax, byte ptr [rdx + rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lr2_http_fail
    imul ebx, ebx, 10
    add ebx, eax
    inc ecx
    cmp ecx, 3
    jb .Lr2_status_digit
    lea rdi, [rip + registry_temp_index]
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_response]
    mov edx, R2_CONTROL
    call r2_read_fd
    mov [rip + r2_response_length], rax
    mov eax, ebx
    jmp .Lr2_http_return
.Lr2_http_fail:
    xor eax, eax
.Lr2_http_return:
    pop r12
    pop rbx
    ret

/* Appends are bounded by derived paths: HTTPS2048 + fixed routes<256. */
r2_task_url:
    sub rsp, 8
    lea rdi, [rip + r2_url]
    mov rsi, [rip + r2_api]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_publications_path]
    call copy_string
    cmp byte ptr [rip + r2_task_id], 0
    je .Lr2_task_url_done
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_task_id]
    call copy_string
.Lr2_task_url_done:
    add rsp, 8
    ret

/* Shared strict tokenizer. Bytes remain read-only. RDI=data, RSI<=65536.
 * Unknown/duplicate/escaped keys are rejected by smp_value. Returns token0.
 * V2 schema routines enforce field sets and plain identity values. */
r2_parse_json:
    sub rsp, 8
    test rsi, rsi
    jz r2_invalid
    cmp rsi, INDEX_LIMIT
    ja r2_invalid
    mov [rip + smp_cursor], rdi
    add rsi, rdi
    mov [rip + smp_end], rsi
    mov qword ptr [rip + smp_token_count], 0
    mov edi, 1
    call smp_value
    test eax, eax
    jnz r2_invalid
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jne r2_invalid
    lea rax, [rip + smp_tokens]
    cmp qword ptr [rax], SMP_OBJECT
    jne r2_invalid
    add rsp, 8
    ret

/* RDI=object token; RSI=key. RAX=value token or0; stack32. */
r2_member:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    cmp qword ptr [r12], SMP_OBJECT
    jne .Lr2_member_none
    mov r14, [r12 + 24]
    lea rbx, [r12 + 32]
.Lr2_member_next:
    lea rax, [rip + smp_tokens]
    mov rdx, rbx
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lr2_member_none
    mov rdi, rbx
    mov rsi, r13
    call smp_token_text_equal
    test eax, eax
    jnz .Lr2_member_found
    mov rax, [rbx + 32 + 24]
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    jmp .Lr2_member_next
.Lr2_member_found:
    lea rax, [rbx + 32]
    jmp .Lr2_member_return
.Lr2_member_none:
    xor eax, eax
.Lr2_member_return:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
r2_required:
    sub rsp, 8
    call r2_member
    test rax, rax
    jz r2_invalid
    add rsp, 8
    ret

.macro R2_GET object, key
    mov rdi, \object
    lea rsi, [rip + r2_k_\key]
    call r2_required
.endm

/* RDI=number token, RSI=upper bound. RAX=positive canonical decimal value.
 * Reject exponent/fraction/negative/leading zero. No stack. */
r2_number:
    cmp qword ptr [rdi], SMP_NUMBER
    jne r2_invalid
    mov rcx, [rdi + 16]
    test rcx, rcx
    jz r2_invalid
    cmp rcx, 10
    ja r2_invalid
    mov rdi, [rdi + 8]
    cmp byte ptr [rdi], '0'
    je r2_invalid
    xor eax, eax
    xor r8d, r8d
.Lr2_number_digit:
    cmp r8, rcx
    jae .Lr2_number_end
    movzx edx, byte ptr [rdi + r8]
    sub edx, '0'
    cmp edx, 9
    ja r2_invalid
    imul rax, rax, 10
    add rax, rdx
    cmp rax, rsi
    ja r2_invalid
    inc r8
    jmp .Lr2_number_digit
.Lr2_number_end:
    ret
r2_schema:
    mov esi, 2
    call r2_number
    cmp eax, 2
    jne r2_invalid
    ret

/* Plain token hex -> owned buffer. RDI token, RSI buffer, EDX hex length.
 * Uses r2_string and r2_hex; stack24. */
r2_hex_token:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13d, edx
    inc edx
    call r2_string
    mov rdi, r12
    mov esi, r13d
    call r2_hex
    test eax, eax
    jz r2_invalid
    pop r13
    pop r12
    pop rbx
    ret

/* Decode canonical printable ASCII text. Only quote/backslash escapes are
 * permitted. RDI=string token; RSI=dest; EDX=capacity. RAX=decoded length.
 * Caller checks semantic bounds; stack0, destination owns decoded text. */
r2_text:
    mov rax, [rdi]
    and eax, -257
    cmp eax, SMP_STRING
    jne r2_invalid
    mov rcx, [rdi + 16]
    mov rdi, [rdi + 8]
    xor r8d, r8d
    xor r9d, r9d
.Lr2_text_byte:
    cmp r8, rcx
    jae .Lr2_text_end
    mov al, [rdi + r8]
    inc r8
    cmp al, '\\'
    jne .Lr2_text_plain
    cmp r8, rcx
    jae r2_invalid
    mov al, [rdi + r8]
    inc r8
    cmp al, '\\'
    je .Lr2_text_plain
    cmp al, '"'
    jne r2_invalid
.Lr2_text_plain:
    cmp al, 32
    jb r2_invalid
    cmp al, 126
    ja r2_invalid
    inc r9
    cmp r9, rdx
    jae r2_invalid
    mov [rsi + r9 - 1], al
    jmp .Lr2_text_byte
.Lr2_text_end:
    mov byte ptr [rsi + r9], 0
    mov rax, r9
    ret

/* Full closed V2 publication schema. RDI=root object. Owns name/version,
 * source declaration, artifact selection and deduplicated object table.
 * Every tuple is explicit; no CPU extension or unknown field is accepted.
 * Maximum14 selections/15 unique objects. Stack48 plus bounded JSON lexer. */
r2_validate_manifest:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    lea rsi, [rip + r2_fields_manifest]
    mov edx, 8
    mov ecx, 10
    call r2_keys
    mov rdi, r12
    call g3_manifest_dependencies
    R2_GET r12, schema
    mov rdi, rax
    call r2_schema
    R2_GET r12, name
    mov rdi, rax
    lea rsi, [rip + r2_name]
    mov edx, 105
    call r2_string
    lea rdi, [rip + r2_name]
    call registry_valid_package
    test eax, eax
    jz r2_invalid
    R2_GET r12, version
    mov rdi, rax
    lea rsi, [rip + r2_version]
    mov edx, 33
    call r2_string
    lea rdi, [rip + r2_version]
    call registry_valid_version
    test eax, eax
    jz r2_invalid
    R2_GET r12, owner_id
    mov rdi, rax
    lea rsi, [rip + r2_owner_id]
    mov edx, 32
    call r2_hex_token
    R2_GET r12, summary
    mov rdi, rax
    lea rsi, [rip + r2_summary]
    mov edx, 161
    call r2_text
    test rax, rax
    jz r2_invalid
    cmp byte ptr [rip + r2_summary], 32
    je r2_invalid
    lea rdx, [rip + r2_summary]
    cmp byte ptr [rdx + rax - 1], 32
    je r2_invalid
    R2_GET r12, license
    mov rdi, rax
    lea rsi, [rip + r2_license]
    mov edx, 64
    call r2_string
    lea rdi, [rip + r2_license]
    lea rsi, [rip + pub_licenses]
    call pub_in_strings
    test eax, eax
    jz r2_invalid
    R2_GET r12, source
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + r2_fields_source]
    mov edx, 3
    mov ecx, 4
    call r2_keys
    R2_GET r13, path
    mov rdi, rax
    lea rsi, [rip + r2_source_path]
    mov edx, 241
    call r2_string
    lea rdi, [rip + r2_source_path]
    cmp word ptr [rdi], 0x002e
    je .Lr2_source_path_ok
    call pub_portable_path
    test eax, eax
    jnz r2_invalid
.Lr2_source_path_ok:
    lea rax, [rip + r2_source_path]
    mov [rip + pub_source_path], rax
    mov rdi, r13
    lea rsi, [rip + r2_k_repository]
    call r2_member
    test rax, rax
    jz .Lr2_source_commit
    mov rdi, rax
    lea rsi, [rip + r2_repository]
    mov edx, 1025
    call r2_string
    lea rdi, [rip + r2_repository]
    call r2_repository_locator
    test eax, eax
    jz r2_invalid
.Lr2_source_commit:
    R2_GET r13, commit
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + r2_fields_commit]
    mov edx, 2
    mov ecx, 2
    call r2_keys
    R2_GET r14, algorithm
    mov rdi, rax
    lea rsi, [rip + r2_git_sha1]
    call smp_plain_equal
    mov ebp, 40
    test eax, eax
    jnz .Lr2_commit_digest
    R2_GET r14, algorithm
    mov rdi, rax
    lea rsi, [rip + r2_git_sha256]
    call smp_plain_equal
    test eax, eax
    jz r2_invalid
    mov ebp, 64
.Lr2_commit_digest:
    R2_GET r14, digest
    mov rdi, rax
    lea rsi, [rip + r2_commit]
    mov edx, ebp
    call r2_hex_token
    lea rdi, [rip + r2_commit]
    xor ecx, ecx
.Lr2_commit_nonzero:
    cmp byte ptr [rdi + rcx], '0'
    jne .Lr2_commit_ok
    inc ecx
    cmp ecx, ebp
    jb .Lr2_commit_nonzero
    jmp r2_invalid
.Lr2_commit_ok:
    R2_GET r13, archive
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + r2_fields_archive]
    mov edx, 2
    mov ecx, 2
    call r2_keys
    R2_GET r14, sha256
    mov rdi, rax
    lea rsi, [rip + r2_source_sha]
    mov edx, 64
    call r2_hex_token
    R2_GET r14, bytes
    mov rdi, rax
    mov esi, ARTIFACT_LIMIT
    call r2_number
    mov [rip + r2_source_bytes], rax
    mov rsi, rax
    lea rdi, [rip + r2_source_sha]
    call r2_add_object
    R2_GET r12, artifacts
    cmp qword ptr [rax], SMP_ARRAY
    jne r2_invalid
    mov r14, [rax + 24]
    lea r13, [rax + 32]
    xor r15d, r15d
.Lr2_artifact:
    lea rax, [rip + smp_tokens]
    mov rdx, r13
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lr2_artifacts_end
    inc r15
    cmp r15, 14
    ja r2_invalid
    mov rdi, r13
    call r2_validate_artifact
    mov rax, [r13 + 24]
    shl rax, 5
    lea r13, [rip + smp_tokens]
    add r13, rax
    jmp .Lr2_artifact
.Lr2_artifacts_end:
    test r15, r15
    jz r2_invalid
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=artifact token. Validate every tuple and source binding, including
 * unselected artifacts. Fixed scratch strings and object records. Stack48. */
r2_validate_artifact:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    lea rsi, [rip + r2_fields_artifact]
    mov edx, 8
    mov ecx, 8
    call r2_keys
    R2_GET r12, cpu_features
    cmp qword ptr [rax], SMP_ARRAY
    jne r2_invalid
    mov rdx, rax
    lea rcx, [rip + smp_tokens]
    sub rdx, rcx
    shr rdx, 5
    inc rdx
    cmp rdx, [rax + 24]
    jne r2_invalid
    R2_GET r12, kind
    mov rdi, rax
    lea rsi, [rip + registry_source_kind]
    call smp_plain_equal
    lea r13, [rip + registry_source_kind]
    xor ebp, ebp
    test eax, eax
    jnz .Lr2_artifact_kind
    R2_GET r12, kind
    mov rdi, rax
    lea rsi, [rip + registry_executable_kind]
    call smp_plain_equal
    test eax, eax
    jz r2_invalid
    lea r13, [rip + registry_executable_kind]
    mov ebp, 1
.Lr2_artifact_kind:
    lea rbx, [rip + r2_tuples]
    xor r14d, r14d
.Lr2_tuple:
    cmp r14, 6
    jae r2_invalid
    R2_GET r12, isa
    mov rdi, rax
    mov rsi, [rbx + 8]
    call smp_plain_equal
    test eax, eax
    jz .Lr2_tuple_next
    R2_GET r12, os
    mov rdi, rax
    mov rsi, [rbx + 16]
    call smp_plain_equal
    test eax, eax
    jz .Lr2_tuple_next
    R2_GET r12, abi
    mov rdi, rax
    mov rsi, [rbx + 24]
    call smp_plain_equal
    test eax, eax
    jz .Lr2_tuple_next
    R2_GET r12, format
    mov rdi, rax
    mov rsi, [rbx + 32]
    test ebp, ebp
    jnz .Lr2_tuple_format
    lea rsi, [rip + r2_tar_gzip]
.Lr2_tuple_format:
    call smp_plain_equal
    test eax, eax
    jnz .Lr2_tuple_found
.Lr2_tuple_next:
    add rbx, 40
    inc r14
    jmp .Lr2_tuple
.Lr2_tuple_found:
    lea ecx, [r14d*2]
    add ecx, ebp
    bt [rip + r2_tuple_bits], rcx
    jc r2_invalid
    bts [rip + r2_tuple_bits], rcx
    R2_GET r12, sha256
    mov rdi, rax
    lea rsi, [rip + r2_digest]
    mov edx, 64
    call r2_hex_token
    R2_GET r12, bytes
    mov rdi, rax
    mov esi, ARTIFACT_LIMIT
    call r2_number
    mov r15, rax
    test ebp, ebp
    jnz .Lr2_artifact_object
    cmp r15, [rip + r2_source_bytes]
    jne r2_invalid
    lea rdi, [rip + r2_digest]
    lea rsi, [rip + r2_source_sha]
    call streq
    test eax, eax
    jz r2_invalid
.Lr2_artifact_object:
    lea rdi, [rip + r2_digest]
    mov rsi, r15
    call r2_add_object
    cmp qword ptr [rip + r2_target], 0
    je .Lr2_artifact_done
    mov rdi, [rbx]
    mov rsi, [rip + r2_target]
    call streq
    test eax, eax
    jz .Lr2_artifact_done
    mov rdi, r13
    mov rsi, [rip + r2_kind]
    call streq
    test eax, eax
    jz .Lr2_artifact_done
    inc qword ptr [rip + r2_selected]
    lea rdi, [rip + r2_selected_sha]
    lea rsi, [rip + r2_digest]
    call copy_string
    mov [rip + r2_selected_bytes], r15
.Lr2_artifact_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Add one unique digest. RDI=validated hex64, RSI=1..64MiB. RAX=owned record.
 * Conflicting lengths, >15 unique objects or >128MiB fail. Stack32. */
r2_add_object:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
    lea rbx, [rip + r2_objects]
.Lr2_object_find:
    cmp r14, [rip + r2_object_count]
    jae .Lr2_object_new
    mov rdi, rbx
    mov rsi, r12
    call streq
    test eax, eax
    jnz .Lr2_object_existing
    inc r14
    add rbx, R2_RECORD
    jmp .Lr2_object_find
.Lr2_object_existing:
    cmp r13, [rbx + 72]
    jne r2_invalid
    jmp .Lr2_object_added
.Lr2_object_new:
    cmp r14, R2_OBJECTS
    jae r2_invalid
    mov rax, [rip + r2_total_bytes]
    add rax, r13
    cmp rax, R2_TASK_BYTES
    ja r2_invalid
    mov [rip + r2_total_bytes], rax
    mov rdi, rbx
    mov rsi, r12
    call copy_string
    mov [rbx + 72], r13
    inc qword ptr [rip + r2_object_count]
.Lr2_object_added:
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Source-bound publication. Snapshot every digest before the first HTTP
 * mutation. Files use the exact manifest digest names; no manifest URL is
 * fetched and no package code is executed. Stack40. */
r2_publish:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rdi, [rip + r2_manifest]
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_manifest_data]
    mov edx, R2_CONTROL
    call r2_read_fd
    mov [rip + r2_manifest_length], rax
    mov rsi, rax
    lea rdi, [rip + r2_manifest_data]
    call r2_parse_json
    mov rdi, rax
    call r2_validate_manifest
    lea rdi, [rip + registry_temp_checksum]
    lea rsi, [rip + r2_manifest_data]
    mov rdx, [rip + r2_manifest_length]
    call r2_write_file
    cmp byte ptr [rip + r2p_owned], 0
    je .Lr2_open_object_inputs
    mov r15, -1
    jmp .Lr2_publish_source
.Lr2_open_object_inputs:
    mov rdi, [rip + r2_objects_dir]
    mov esi, 1
    xor edx, edx
    call r2_open_path
    mov r15, rax
    xor ebx, ebx
.Lr2_publish_snapshot:
    cmp rbx, [rip + r2_object_count]
    jae .Lr2_publish_source
    imul rax, rbx, R2_RECORD
    lea r12, [rip + r2_objects]
    add r12, rax
    mov eax, 257
    mov rdi, r15
    mov rsi, r12
    mov edx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    xor r10d, r10d
    syscall
    test rax, rax
    js r2_io
    mov r13, rax
    mov eax, 5
    mov rdi, r13
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2_io
    mov eax, [rip + r2_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne r2_io
    mov rax, [rip + r2_stat + 48]
    cmp rax, [r12 + 72]
    jne r2_invalid
    call r2p_refuse_credential_object
    mov rdi, r12
    call r2_object_stage_path
    mov eax, 2
    lea rdi, [rip + r2_object_path]
    mov esi, O_NOFOLLOW + O_CLOEXEC + 193
    mov edx, 384
    syscall
    test rax, rax
    js r2_io
    mov r14, rax
    xor ebp, ebp
.Lr2_snapshot_read:
    xor eax, eax
    mov rdi, r13
    lea rsi, [rip + registry_copy_buffer]
    mov edx, 65536
    syscall
    cmp rax, -4
    je .Lr2_snapshot_read
    test rax, rax
    js r2_io
    jz .Lr2_snapshot_done
    add rbp, rax
    cmp rbp, [r12 + 72]
    ja r2_invalid
    mov rdx, rax
    mov rdi, r14
    lea rsi, [rip + registry_copy_buffer]
    call write_all
    test rax, rax
    js r2_io
    jmp .Lr2_snapshot_read
.Lr2_snapshot_done:
    cmp rbp, [r12 + 72]
    jne r2_invalid
    mov eax, 3
    mov rdi, r13
    syscall
    mov eax, 3
    mov rdi, r14
    syscall
    test rax, rax
    js r2_io
    /* Hash an owned snapshot with the existing descriptor-fed digest child. */
    lea rdi, [rip + r2_object_path]
    call r2_hash_path
    lea rdi, [rip + pub_hash_buffer]
    mov rsi, r12
    call streq
    test eax, eax
    jz r2_invalid
    inc ebx
    jmp .Lr2_publish_snapshot
.Lr2_publish_source:
    mov eax, 3
    mov rdi, r15
    syscall
    lea rdi, [rip + r2_source_sha]
    call r2_object_stage_path
    xor ebx, ebx
.Lr2_publish_project:
    cmp ebx, 6
    jae .Lr2_publish_post
    lea ecx, [ebx*2]
    mov rax, [rip + r2_tuple_bits]
    shr rax, cl
    test eax, 3
    jz .Lr2_publish_project_next
    imul rax, rbx, 40
    lea rdx, [rip + r2_tuples]
    mov rcx, [rdx + rax]
    lea rdi, [rip + r2_object_path]
    lea rsi, [rip + r2_name]
    lea rdx, [rip + r2_version]
    call validate_v2_source_package
    test eax, eax
    jnz r2_invalid
    lea rdi, [rip + r2_dependencies]
    mov rsi, [rip + r2_dependency_count]
    lea rdx, [rip + g4_publication_profile]
    call g4_compare_project
    test eax, eax
    jnz r2_invalid
.Lr2_publish_project_next:
    inc ebx
    jmp .Lr2_publish_project
.Lr2_publish_post:
    lea rdi, [rip + registry_temp_checksum]
    call r2_hash_path
    lea rdi, [rip + r2_manifest_sha]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    call r2_task_url
    lea rdi, [rip + r2_method_post]
    lea rsi, [rip + registry_temp_checksum]
    mov byte ptr [rip + r2_post_attempted], 1
    call r2_http
    cmp eax, 200
    je .Lr2_publish_accepted
    cmp eax, 202
    jne r2_http_error
.Lr2_publish_accepted:
    call r2_parse_task
    xor ebx, ebx
.Lr2_publish_upload:
    cmp rbx, [rip + r2_object_count]
    jae .Lr2_publish_status
    imul rax, rbx, R2_RECORD
    lea r12, [rip + r2_objects]
    add r12, rax
    cmp qword ptr [r12 + R2_OBJECT_RECEIVED], 1
    je .Lr2_upload_next
    call r2_task_url
    mov rdi, rax
    lea rsi, [rip + r2_artifacts_path]
    call copy_string
    mov rdi, rax
    mov rsi, r12
    call copy_string
    mov rdi, r12
    call r2_object_stage_path
    lea rdi, [rip + r2_method_put]
    lea rsi, [rip + r2_object_path]
    call r2_http
    cmp eax, 201
    je .Lr2_upload_task
    cmp eax, 204
    jne r2_http_error
    cmp qword ptr [rip + r2_response_length], 0
    jne r2_invalid
    jmp .Lr2_upload_next
.Lr2_upload_task:
    call r2_parse_task
.Lr2_upload_next:
    inc ebx
    jmp .Lr2_publish_upload
.Lr2_publish_status:
    call r2_task_url
    lea rdi, [rip + r2_method_get]
    xor esi, esi
    call r2_http
    cmp eax, 200
    jne r2_http_error
    call r2_parse_task
    jmp r2_report

/* Descriptor hash adapter reuses the mature digest child without a shell.
 * RDI=owned path. Output pub_hash_buffer is hex64+NUL. Stack8. */
r2_hash_path:
    sub rsp, 8
    call pub_hash_file
    test eax, eax
    jnz r2_io
    mov byte ptr [rip + pub_hash_buffer + 64], 0
    add rsp, 8
    ret

/* Descriptive source locator, never a transport instruction. Unlike an API
 * base, it may contain escaped path bytes or a trailing slash. RDI=bounded
 * ASCII<=1024; EAX=1/0. No credentials/query/fragment/backslash. Stack8. */
r2_repository_locator:
    push rbx
    mov rbx, rdi
    call registry_https_url
    test eax, eax
    jz .Lr2_locator_return
    cmp byte ptr [rbx + 8], '/'
    je .Lr2_locator_bad
.Lr2_locator_byte:
    mov al, [rbx]
    test al, al
    jz .Lr2_locator_ok
    cmp al, '?'
    je .Lr2_locator_bad
    cmp al, '#'
    je .Lr2_locator_bad
    inc rbx
    jmp .Lr2_locator_byte
.Lr2_locator_ok:
    mov eax, 1
    jmp .Lr2_locator_return
.Lr2_locator_bad:
    xor eax, eax
.Lr2_locator_return:
    pop rbx
    ret

/* Exact authenticated fetch/install command. All trust inputs are explicit;
 * adapter state binds registry ID and the initial root across rotations. */
r2_receive:
    cmp rdx, 3808
    jne r2_arguments
    cmp qword ptr [rip + r2_mirror_count], 0
    je r2_arguments
    mov rdi, [rip + r2_registry_id]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2_selector]
    call strlen
    cmp rax, 168
    ja r2_arguments
    lea rdi, [rip + r2_requested_name]
    mov rsi, [rip + r2_selector]
    call copy_string
    lea rbx, [rip + r2_requested_name]
.Lr2_selector_at:
    cmp byte ptr [rbx], 0
    je r2_arguments
    cmp byte ptr [rbx], '@'
    je .Lr2_selector_split
    inc rbx
    jmp .Lr2_selector_at
.Lr2_selector_split:
    mov byte ptr [rbx], 0
    lea rdi, [rbx + 1]
    call registry_valid_version
    test eax, eax
    jz r2_arguments
    lea rdi, [rip + r2_requested_version]
    lea rsi, [rbx + 1]
    call copy_string
    lea rdi, [rip + r2_requested_name]
    call registry_valid_package
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2_kind]
    call registry_valid_kind
    test eax, eax
    jz r2_arguments
    lea rbx, [rip + r2_tuples]
    xor ebp, ebp
.Lr2_requested_tuple:
    mov rdi, [rip + r2_target]
    mov rsi, [rbx]
    call streq
    test eax, eax
    jnz .Lr2_requested_tuple_found
    add rbx, 40
    inc ebp
    cmp ebp, 6
    jb .Lr2_requested_tuple
    jmp r2_arguments
.Lr2_requested_tuple_found:
    cmp qword ptr [rip + r2_mode], 4
    jne .Lr2_trust_files
    mov rdi, [rip + r2_kind]
    lea rsi, [rip + registry_executable_kind]
    call streq
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2_target]
    lea rsi, [rip + registry_host]
    call streq
    test eax, eax
    jz r2_arguments
.Lr2_trust_files:
    mov rdi, [rip + r2_root]
    call program_valid_absolute_path
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2_state]
    call program_valid_absolute_path
    test eax, eax
    jz r2_arguments
    cmp qword ptr [rip + r2_ca], 0
    je .Lr2_trust_paths_done
    mov rdi, [rip + r2_ca]
    call program_valid_absolute_path
    test eax, eax
    jz r2_arguments
.Lr2_trust_paths_done:
    mov rdi, [rip + r2_root]
    xor esi, esi
    mov edx, 2
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_root_data]
    mov edx, INDEX_LIMIT
    call r2_read_fd
    cmp qword ptr [rip + r2_ca], 0
    je .Lr2_trust_workspace
    mov rdi, [rip + r2_ca]
    xor esi, esi
    mov edx, 2
    call r2_open_path
    mov rdi, rax
    mov eax, 3
    syscall
.Lr2_trust_workspace:
    call r2_workspace
    call r2_prepare_adapter
    mov rdi, [rip + r2_root]
    call r2_hash_path
    lea rdi, [rip + r2_root_sha]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    call r2_release_target
    lea rdi, [rip + registry_temp_index]
    call r2_get_target
    test eax, eax
    jnz r2_trust_error
    lea rdi, [rip + registry_temp_index]
    call r2_hash_path
    lea rdi, [rip + r2_envelope_sha]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    lea rdi, [rip + registry_temp_index]
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_envelope]
    mov edx, INDEX_LIMIT
    call r2_read_fd
    mov rsi, rax
    lea rdi, [rip + r2_envelope]
    call r2_parse_json
    mov rdi, rax
    call r2_validate_envelope
    cmp qword ptr [rip + r2_selected], 1
    jne r2_trust_error
    call r2_load_policy
    cmp qword ptr [rip + r2_mode], 4
    jne .Lr2_receive_blob
    call r2_install_prepare
.Lr2_receive_blob:
    call r2_download_blob
    test eax, eax
    jnz r2_trust_error
    mov rdi, [rip + r2_kind]
    lea rsi, [rip + registry_source_kind]
    call streq
    test eax, eax
    jz .Lr2_receive_executable
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + r2_name]
    lea rdx, [rip + r2_version]
    mov rcx, [rip + r2_target]
    call validate_v2_source_package
    test eax, eax
    jnz r2_invalid
    lea rdi, [rip + r2_dependencies]
    mov rsi, [rip + r2_dependency_count]
    lea rdx, [rip + g4_publication_profile]
    call g4_compare_project
    test eax, eax
    jnz r2_invalid
    jmp .Lr2_receive_finalize
.Lr2_receive_executable:
    cmp qword ptr [rip + r2_mode], 4
    jne .Lr2_receive_finalize
    lea rdi, [rip + registry_temp_payload]
    mov rsi, [rip + r2_selected_bytes]
    call validate_host_elf
    test eax, eax
    jz r2_invalid
.Lr2_receive_finalize:
    /* Long or retried blob transfers cannot extend policy freshness. */
    call r2_load_policy
    cmp qword ptr [rip + r2_mode], 4
    jne .Lr2_fetch_commit
    call program_commit_install
    jmp .Lr2_receive_report
.Lr2_fetch_commit:
    mov rax, [rip + r2_output]
    mov [rip + arc_output_path], rax
    call arc_open_parent
    test eax, eax
    jnz r2_io
    mov eax, 90
    lea rdi, [rip + registry_temp_payload]
    mov esi, 420
    syscall
    test rax, rax
    js r2_io
    mov eax, 316
    mov rdi, -100
    lea rsi, [rip + registry_temp_payload]
    mov rdx, [rip + arc_parent_fd]
    lea r10, [rip + arc_destination_leaf]
    mov r8d, 1
    syscall
    test rax, rax
    js r2_io
    mov eax, 3
    mov rdi, [rip + arc_parent_fd]
    syscall
.Lr2_receive_report:
    call registry_cleanup
    cmp byte ptr [rip + json_mode], 0
    je exit_ok
    lea rdi, [rip + r2_fetched_json]
    call out
    jmp exit_ok

/* Write only the reviewed embedded adapter. Its target roots are explicit
 * inputs; no test key or downloaded verifier can replace these bytes. */
r2_prepare_adapter:
    sub rsp, 8
    lea rdi, [rip + r2_helper_path]
    lea rsi, [rip + r2_helper_bytes]
    mov edx, OFFSET r2_helper_length
    call r2_write_file
    mov eax, 90
    lea rdi, [rip + r2_helper_path]
    mov esi, 448
    syscall
    test rax, rax
    js r2_io
    add rsp, 8
    ret
r2_target_prefix:
    sub rsp, 8
    lea rdi, [rip + r2_target_path]
    lea rsi, [rip + r2_registries_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + r2_registry_id]
    call copy_string
    add rsp, 8
    ret
r2_release_target:
    sub rsp, 8
    call r2_target_prefix
    mov rdi, rax
    lea rsi, [rip + r2_releases_path]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_requested_name]
    call copy_string
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_requested_version]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_json_suffix]
    call copy_string
    add rsp, 8
    ret
r2_policy_target:
    sub rsp, 8
    call r2_target_prefix
    mov rdi, rax
    lea rsi, [rip + r2_policy_suffix]
    call copy_string
    add rsp, 8
    ret

/* Refresh and evaluate lifecycle policy under the same protected trust state.
 * Called before transfer and immediately before exposure. No blob transfer.
 * Preserves callee registers, stack8, policy buffer<=1MiB. */
r2_load_policy:
    sub rsp, 8
    call r2_policy_target
    lea rdi, [rip + registry_temp_checksum]
    call r2_get_target
    test eax, eax
    jnz r2_trust_error
    lea rdi, [rip + registry_temp_checksum]
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_policy]
    mov edx, INDEX_LIMIT
    call r2_read_fd
    lea rdx, [rip + r2_policy]
    add rdx, rax
    mov [rip + r2_policy_end], rdx
    lea rax, [rip + r2_policy]
    mov [rip + r2_policy_cursor], rax
    call r2_validate_policy
    add rsp, 8
    ret

/* RDI=owned output path. Try <=3 explicitly selected byte origins; never
 * change authority/root/state. EAX=0 success,1 all alternatives failed. */
r2_get_target:
    push rbx
    push r12
    mov r12, rdi
    lea rdi, [rip + r2_adapter_output]
    lea rsi, [rip + r2_cwd]
    call copy_string
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, r12
    call copy_string
    xor ebx, ebx
.Lr2_target_try:
    mov eax, 87
    mov rdi, r12
    syscall
    lea rdx, [rip + r2_adapter_argv]
    lea rax, [rip + r2_helper_path]
    mov [rdx], rax
    lea rax, [rip + r2_adapter_command]
    mov [rdx + 8], rax
    mov rax, [rip + r2_root]
    mov [rdx + 16], rax
    mov rax, [rip + r2_state]
    mov [rdx + 24], rax
    mov rax, [rip + r2_registry_id]
    mov [rdx + 32], rax
    lea rcx, [rip + r2_mirrors]
    mov rax, [rcx + rbx*8]
    mov [rdx + 40], rax
    lea rax, [rip + r2_target_path]
    mov [rdx + 48], rax
    lea rax, [rip + r2_adapter_output]
    mov [rdx + 56], rax
    mov rax, [rip + r2_ca]
    mov [rdx + 64], rax
    mov qword ptr [rdx + 72], 0
    mov qword ptr [rip + r2_child_file_limit], INDEX_LIMIT
    lea rdi, [rip + r2_helper_path]
    lea rsi, [rip + r2_adapter_argv]
    call r2_child
    test eax, eax
    jnz .Lr2_target_next
    cmp qword ptr [rip + r2_status_length], 0
    jne .Lr2_target_next
    xor eax, eax
    jmp .Lr2_target_return
.Lr2_target_next:
    inc ebx
    cmp rbx, [rip + r2_mirror_count]
    jb .Lr2_target_try
    mov eax, 1
.Lr2_target_return:
    pop r12
    pop rbx
    ret

/* Full signed envelope, whose digest is retained in the managed receipt. */
r2_validate_envelope:
    push rbx
    push r12
    mov r12, rdi
    lea rsi, [rip + r2_fields_envelope]
    mov edx, 6
    mov ecx, 6
    call r2_keys
    R2_GET r12, schema
    mov rdi, rax
    call r2_schema
    R2_GET r12, registry_id
    mov rdi, rax
    mov rsi, [rip + r2_registry_id]
    call smp_plain_equal
    test eax, eax
    jz r2_trust_error
    R2_GET r12, package_id
    mov rdi, rax
    lea rsi, [rip + r2_package_id]
    mov edx, 32
    call r2_hex_token
    R2_GET r12, release_id
    mov rdi, rax
    lea rsi, [rip + r2_release_id]
    mov edx, 32
    call r2_hex_token
    R2_GET r12, manifest_sha256
    mov rdi, rax
    lea rsi, [rip + r2_manifest_sha]
    mov edx, 64
    call r2_hex_token
    R2_GET r12, publication
    mov rdi, rax
    call r2_validate_manifest
    lea rdi, [rip + r2_name]
    lea rsi, [rip + r2_requested_name]
    call streq
    test eax, eax
    jz r2_trust_error
    lea rdi, [rip + r2_version]
    lea rsi, [rip + r2_requested_version]
    call streq
    test eax, eax
    jz r2_trust_error
    pop r12
    pop rbx
    ret

/* Bounded TSV line split in owned policy buffer. RAX=field count, RDI/RSI
 * scratch; fields borrow NUL-terminated spans. Require LF and <=6fields. */
r2_policy_line:
    mov rdi, [rip + r2_policy_cursor]
    xor ecx, ecx
    lea rdx, [rip + r2_policy_fields]
    mov [rdx], rdi
.Lr2_policy_byte:
    cmp rdi, [rip + r2_policy_end]
    jae r2_trust_error
    mov al, [rdi]
    test al, al
    jz r2_trust_error
    cmp al, 10
    je .Lr2_policy_lf
    cmp al, 9
    jne .Lr2_policy_plain
    mov byte ptr [rdi], 0
    inc ecx
    cmp ecx, 6
    jae r2_trust_error
    lea rax, [rdi + 1]
    mov [rdx + rcx*8], rax
    jmp .Lr2_policy_scan_next
.Lr2_policy_plain:
    cmp al, 32
    jb r2_trust_error
    cmp al, 126
    ja r2_trust_error
.Lr2_policy_scan_next:
    inc rdi
    jmp .Lr2_policy_byte
.Lr2_policy_lf:
    mov byte ptr [rdi], 0
    inc rdi
    mov [rip + r2_policy_cursor], rdi
    lea eax, [ecx + 1]
    ret

/* Canonical nonnegative signed63-bit decimal field, including0. */
r2_policy_revision:
    xor eax, eax
    xor ecx, ecx
    cmp byte ptr [rdi], '0'
    jne .Lr2_revision_digit
    cmp byte ptr [rdi + 1], 0
    jne r2_trust_error
    ret
.Lr2_revision_digit:
    movzx edx, byte ptr [rdi + rcx]
    test edx, edx
    jz .Lr2_revision_end
    sub edx, '0'
    cmp edx, 9
    ja r2_trust_error
    imul rax, rax, 10
    jo r2_trust_error
    add rax, rdx
    jo r2_trust_error
    inc ecx
    cmp ecx, 19
    ja r2_trust_error
    jmp .Lr2_revision_digit
.Lr2_revision_end:
    test ecx, ecx
    jz r2_trust_error
    ret

/* C lexical comparison of validated ASCII. EAX=-1/0/1. */
r2_lex:
    movzx eax, byte ptr [rdi]
    movzx edx, byte ptr [rsi]
    cmp eax, edx
    jb .Lr2_lex_less
    ja .Lr2_lex_greater
    test eax, eax
    jz .Lr2_lex_equal
    inc rdi
    inc rsi
    jmp r2_lex
.Lr2_lex_less:
    mov eax, -1
    ret
.Lr2_lex_greater:
    mov eax, 1
    ret
.Lr2_lex_equal:
    xor eax, eax
    ret

/* Validate the whole authenticated lifecycle table before selecting bytes.
 * Every retained row is bounded, sorted, unique and closed. Selected IDs must
 * match the signed envelope and be neither yanked nor revoked. Stack24. */
r2_validate_policy:
    push rbx
    push r12
    push r13
    call r2_policy_line
    cmp eax, 4
    jne r2_trust_error
    mov rdi, [rip + r2_policy_fields]
    lea rsi, [rip + r2_policy_header]
    call streq
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 8]
    mov rsi, [rip + r2_registry_id]
    call streq
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 16]
    call r2_policy_revision
    mov rdi, [rip + r2_policy_fields + 24]
    call r2_policy_revision
    xor ebx, ebx
    xor r12d, r12d
.Lr2_policy_row:
    mov rax, [rip + r2_policy_cursor]
    cmp rax, [rip + r2_policy_end]
    je .Lr2_policy_done
    inc ebx
    cmp ebx, 4096
    ja r2_trust_error
    call r2_policy_line
    cmp eax, 6
    jne r2_trust_error
    mov rdi, [rip + r2_policy_fields]
    call registry_valid_package
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 8]
    call registry_valid_version
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 16]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 24]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 32]
    call r2_policy_flag
    mov rdi, [rip + r2_policy_fields + 40]
    call r2_policy_flag
    cmp ebx, 1
    je .Lr2_policy_save
    lea rdi, [rip + r2_previous_name]
    mov rsi, [rip + r2_policy_fields]
    call r2_lex
    cmp eax, 0
    jg r2_trust_error
    jl .Lr2_policy_save
    lea rdi, [rip + r2_previous_version]
    mov rsi, [rip + r2_policy_fields + 8]
    call r2_lex
    cmp eax, 0
    jge r2_trust_error
.Lr2_policy_save:
    cmp byte ptr [rip + r3_active], 0
    je .Lr3_policy_legacy
    call r3_policy_row
.Lr3_policy_legacy:
    lea rdi, [rip + r2_previous_name]
    mov rsi, [rip + r2_policy_fields]
    call copy_string
    lea rdi, [rip + r2_previous_version]
    mov rsi, [rip + r2_policy_fields + 8]
    call copy_string
    cmp byte ptr [rip + r3_active], 0
    jne .Lr2_policy_row
    lea rdi, [rip + r2_name]
    mov rsi, [rip + r2_policy_fields]
    call streq
    test eax, eax
    jz .Lr2_policy_row
    lea rdi, [rip + r2_version]
    mov rsi, [rip + r2_policy_fields + 8]
    call streq
    test eax, eax
    jz .Lr2_policy_row
    lea rdi, [rip + r2_package_id]
    mov rsi, [rip + r2_policy_fields + 16]
    call streq
    test eax, eax
    jz r2_trust_error
    lea rdi, [rip + r2_release_id]
    mov rsi, [rip + r2_policy_fields + 24]
    call streq
    test eax, eax
    jz r2_trust_error
    mov rdi, [rip + r2_policy_fields + 32]
    cmp byte ptr [rdi], '0'
    jne r2_trust_error
    mov rdi, [rip + r2_policy_fields + 40]
    cmp byte ptr [rdi], '0'
    jne r2_trust_error
    inc r12
    jmp .Lr2_policy_row
.Lr2_policy_done:
    cmp byte ptr [rip + r3_active], 0
    jne .Lr3_policy_return
    cmp r12, 1
    jne r2_trust_error
.Lr3_policy_return:
    pop r13
    pop r12
    pop rbx
    ret
r2_policy_flag:
    cmp word ptr [rdi], 0x0030
    je .Lr2_policy_flag_ok
    cmp word ptr [rdi], 0x0031
    jne r2_trust_error
.Lr2_policy_flag_ok:
    ret

/* Download digest-addressed blob through <=3 byte mirrors. Corrupt or failed
 * alternatives are removed; only exact bytes become visible. Stack32. */
r2_download_blob:
    push rbx
    push rbp
    push r12
    push r13
    mov rdi, [rip + r2_selected_bytes]
    lea rsi, [rip + r2_size_decimal + 31]
    call unsigned_decimal
    mov [rip + r2_size_pointer], rax
    xor ebx, ebx
.Lr2_blob_try:
    mov eax, 87
    lea rdi, [rip + registry_temp_payload]
    syscall
    lea rdi, [rip + r2_url]
    lea rdx, [rip + r2_mirrors]
    mov rsi, [rdx + rbx*8]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_blobs_path]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_selected_sha]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2_selection_query]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + r2_registry_id]
    call copy_string
    mov byte ptr [rax], '.'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_package_id]
    call copy_string
    mov byte ptr [rax], '.'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_release_id]
    call copy_string
    mov byte ptr [rax], '.'
    lea rdi, [rax + 1]
    mov rsi, [rip + r2_target]
    call copy_string
    mov byte ptr [rax], '.'
    lea rdi, [rax + 1]
    mov rsi, [rip + r2_kind]
    call copy_string
    lea rdx, [rip + r2_blob_argv]
    lea rax, [rip + registry_curl]
    mov [rdx], rax
    lea rax, [rip + registry_curl_disable]
    mov [rdx + 8], rax
    lea rax, [rip + registry_curl_silent]
    mov [rdx + 16], rax
    lea rax, [rip + registry_curl_fail]
    mov [rdx + 24], rax
    lea rax, [rip + registry_curl_proto]
    mov [rdx + 32], rax
    lea rax, [rip + registry_curl_https]
    mov [rdx + 40], rax
    lea rax, [rip + registry_curl_connect_timeout]
    mov [rdx + 48], rax
    lea rax, [rip + registry_curl_fifteen]
    mov [rdx + 56], rax
    lea rax, [rip + registry_curl_max_time]
    mov [rdx + 64], rax
    lea rax, [rip + r2_seconds]
    mov [rdx + 72], rax
    lea rax, [rip + registry_curl_max_filesize]
    mov [rdx + 80], rax
    mov rax, [rip + r2_size_pointer]
    mov [rdx + 88], rax
    lea rax, [rip + registry_curl_output]
    mov [rdx + 96], rax
    lea rax, [rip + registry_temp_payload]
    mov [rdx + 104], rax
    mov ecx, 14
    mov rax, [rip + r2_ca]
    test rax, rax
    jz .Lr2_blob_argv_end
    lea rsi, [rip + r2_ca_option]
    mov [rdx + rcx*8], rsi
    inc ecx
    mov [rdx + rcx*8], rax
    inc ecx
.Lr2_blob_argv_end:
    lea rax, [rip + registry_separator]
    mov [rdx + rcx*8], rax
    inc ecx
    lea rax, [rip + r2_url]
    mov [rdx + rcx*8], rax
    inc ecx
    mov qword ptr [rdx + rcx*8], 0
    mov rax, [rip + r2_selected_bytes]
    mov [rip + r2_child_file_limit], rax
    lea rdi, [rip + registry_curl]
    lea rsi, [rip + r2_blob_argv]
    call r2_child
    test eax, eax
    jnz .Lr2_blob_next
    cmp qword ptr [rip + r2_status_length], 0
    jne .Lr2_blob_next
    mov eax, 6
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js .Lr2_blob_next
    mov rax, [rip + r2_stat + 48]
    cmp rax, [rip + r2_selected_bytes]
    jne .Lr2_blob_next
    lea rdi, [rip + registry_temp_payload]
    call r2_hash_path
    lea rdi, [rip + pub_hash_buffer]
    lea rsi, [rip + r2_selected_sha]
    call streq
    test eax, eax
    jz .Lr2_blob_next
    xor eax, eax
    jmp .Lr2_blob_return
.Lr2_blob_next:
    inc ebx
    cmp rbx, [rip + r2_mirror_count]
    jb .Lr2_blob_try
    mov eax, 1
.Lr2_blob_return:
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Reuse the existing program inventory with an explicit authority binding.
 * Full origin: v2:registry:initial-root-sha:package:release:envelope-sha.
 * No adoption or upgrade. Exact repeated installation verifies existing bytes
 * only after fresh TUF/lifecycle checks, then returns unchanged. */
r2_install_prepare:
    push rbx
    push r12
    lea rdi, [rip + r2_origin_receipt]
    lea rsi, [rip + r2_origin_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + r2_registry_id]
    call copy_string
    mov byte ptr [rax], ':'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_root_sha]
    call copy_string
    mov byte ptr [rax], ':'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_package_id]
    call copy_string
    mov byte ptr [rax], ':'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_release_id]
    call copy_string
    mov byte ptr [rax], ':'
    lea rdi, [rax + 1]
    lea rsi, [rip + r2_envelope_sha]
    call copy_string
    lea rax, [rip + r2_origin_receipt]
    mov [rip + registry_url], rax
    mov rax, [rip + r2_output]
    mov [rip + registry_output], rax
    lea rax, [rip + r2_name]
    mov [rip + r2_synthetic_row], rax
    lea rax, [rip + r2_version]
    mov [rip + r2_synthetic_row + 8], rax
    mov rax, [rip + r2_target]
    mov [rip + r2_synthetic_row + 16], rax
    mov rax, [rip + r2_kind]
    mov [rip + r2_synthetic_row + 24], rax
    lea rax, [rip + r2_selected_sha]
    mov [rip + r2_synthetic_row + 32], rax
    lea rax, [rip + r2_origin_receipt]
    mov [rip + r2_synthetic_row + 40], rax
    mov rdi, [rip + r2_selected_bytes]
    lea rsi, [rip + r2_size_decimal + 31]
    call unsigned_decimal
    mov [rip + r2_synthetic_row + 48], rax
    lea rax, [rip + r2_summary]
    mov [rip + r2_synthetic_row + 56], rax
    lea rax, [rip + r2_synthetic_row]
    mov [rip + registry_selected], rax
    mov edi, 1
    call program_open_state
    call program_read_state
    lea rdi, [rip + r2_name]
    call program_find
    mov [rip + program_found], rax
    test rax, rax
    jz .Lr2_install_new
    mov r12, rax
    mov rdi, [r12 + 48]
    lea rsi, [rip + r2_origin_receipt]
    call streq
    test eax, eax
    jz r2_io
    mov rdi, [r12 + 8]
    lea rsi, [rip + r2_version]
    call streq
    test eax, eax
    jz r2_io
    mov rdi, [r12 + 16]
    mov rsi, [rip + r2_target]
    call streq
    test eax, eax
    jz r2_io
    mov rdi, [r12 + 24]
    lea rsi, [rip + r2_selected_sha]
    call streq
    test eax, eax
    jz r2_io
    mov rdi, [r12 + 32]
    mov rsi, [rip + r2_synthetic_row + 48]
    call streq
    test eax, eax
    jz r2_io
    mov rsi, [rip + r2_output]
    call program_absolute_path
    lea rdi, [rip + program_path]
    mov rsi, [r12 + 40]
    call streq
    test eax, eax
    jz r2_io
    call program_open_destination
    call program_check_existing
    call registry_cleanup
    cmp byte ptr [rip + json_mode], 0
    je exit_ok
    lea rdi, [rip + r2_unchanged_json]
    call out
    jmp exit_ok
.Lr2_install_new:
    cmp qword ptr [rip + program_count], PROGRAM_LIMIT
    jae r2_io
    pop r12
    pop rbx
    ret

/* RDI=inventory origin. EAX=1 only for the complete closed V2 receipt shape.
 * No mutation; all fixed ID/digest lengths and separators checked. Stack8. */
r2_inventory_origin:
    push rbx
    mov rbx, rdi
    call strlen
    cmp eax, 231
    jne .Lr2_inventory_bad
    cmp word ptr [rbx], 0x3276
    jne .Lr2_inventory_bad
    cmp byte ptr [rbx + 2], ':'
    jne .Lr2_inventory_bad
    mov ecx, 3
.Lr2_inventory_byte:
    cmp ecx, 231
    jae .Lr2_inventory_ok
    mov al, [rbx + rcx]
    cmp ecx, 35
    je .Lr2_inventory_colon
    cmp ecx, 100
    je .Lr2_inventory_colon
    cmp ecx, 133
    je .Lr2_inventory_colon
    cmp ecx, 166
    je .Lr2_inventory_colon
    cmp al, '0'
    jb .Lr2_inventory_bad
    cmp al, '9'
    jbe .Lr2_inventory_next
    cmp al, 'a'
    jb .Lr2_inventory_bad
    cmp al, 'f'
    ja .Lr2_inventory_bad
    jmp .Lr2_inventory_next
.Lr2_inventory_colon:
    cmp al, ':'
    jne .Lr2_inventory_bad
.Lr2_inventory_next:
    inc ecx
    jmp .Lr2_inventory_byte
.Lr2_inventory_ok:
    mov eax, 1
    jmp .Lr2_inventory_return
.Lr2_inventory_bad:
    xor eax, eax
.Lr2_inventory_return:
    pop rbx
    ret

/* Token string -> owned NUL buffer. RDI=token, RSI=buffer, EDX=capacity incl
 * NUL. Plain printable ASCII only; EAX=length. Stack0. */
r2_string:
    cmp qword ptr [rdi], SMP_STRING
    jne r2_invalid
    mov rcx, [rdi + 16]
    cmp rcx, rdx
    jae r2_invalid
    mov rdi, [rdi + 8]
    xor edx, edx
.Lr2_string_byte:
    cmp rdx, rcx
    jae .Lr2_string_end
    mov al, [rdi + rdx]
    cmp al, 32
    jb r2_invalid
    cmp al, 126
    ja r2_invalid
    mov [rsi + rdx], al
    inc rdx
    jmp .Lr2_string_byte
.Lr2_string_end:
    mov byte ptr [rsi + rdx], 0
    mov rax, rcx
    ret

/* Closed object fields. RDI=token, RSI=allowed NUL string set, EDX=min count,
 * ECX=max count. Required fields are checked separately. Stack40. */
r2_keys:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp qword ptr [rdi], SMP_OBJECT
    jne r2_invalid
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov r15d, ecx
    lea rbx, [rdi + 32]
    xor r8d, r8d
.Lr2_keys_next:
    lea rax, [rip + smp_tokens]
    mov rdx, rbx
    sub rdx, rax
    shr rdx, 5
    cmp rdx, [r12 + 24]
    jae .Lr2_keys_end
    push r8
    mov rdi, rbx
    lea rsi, [rip + r2_key_buffer]
    mov edx, 256
    /* Keys have the KEY token kind; copy through the bounded raw span. */
    mov rcx, [rdi + 16]
    cmp rcx, 255
    ja r2_invalid
    mov rdx, [rdi + 8]
    mov rdi, rsi
    mov rsi, rdx
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + r2_key_buffer]
    mov rsi, r13
    call pub_in_strings
    pop r8
    test eax, eax
    jz r2_invalid
    inc r8
    cmp r8, r15
    ja r2_invalid
    mov rax, [rbx + 56]
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    jmp .Lr2_keys_next
.Lr2_keys_end:
    cmp r8, r14
    jb r2_invalid
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Parsed task IDs must bind the requested task; raw private problem bodies
 * are never emitted. Further task schema checks are performed below. */
r2_parse_task:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [rip + r2_response]
    mov rsi, [rip + r2_response_length]
    call r2_parse_json
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + r2_fields_task]
    mov edx, 9
    mov ecx, 9
    call r2_keys
    R2_GET r12, schema
    mov rdi, rax
    call r2_schema
    R2_GET r12, package_id
    mov rdi, rax
    lea rsi, [rip + r2_task_package]
    mov edx, 32
    call r2_hex_token
    R2_GET r12, manifest_sha256
    mov rdi, rax
    lea rsi, [rip + r2_task_manifest]
    mov edx, 64
    call r2_hex_token
    cmp qword ptr [rip + r2_mode], 1
    jne .Lr2_task_state
    lea rdi, [rip + r2_task_manifest]
    lea rsi, [rip + r2_manifest_sha]
    call streq
    test eax, eax
    jz r2_invalid
.Lr2_task_state:
    R2_GET r12, state
    mov rdi, rax
    lea rsi, [rip + r2_task_state]
    mov edx, 16
    call r2_string
    lea rdi, [rip + r2_task_state]
    lea rsi, [rip + r2_task_states]
    call pub_in_strings
    test eax, eax
    jz r2_invalid
    R2_GET r12, upload_expires_at
    mov rdi, rax
    lea rsi, [rip + r2_timestamp]
    mov edx, 21
    call r2_string
    cmp eax, 20
    jne r2_invalid
    lea rdi, [rip + r2_timestamp]
    xor ecx, ecx
.Lr2_timestamp_byte:
    cmp ecx, 20
    jae .Lr2_task_objects
    lea rdx, [rip + r2_timestamp_shape]
    mov al, [rdx + rcx]
    cmp al, '0'
    je .Lr2_timestamp_digit
    cmp al, [rdi + rcx]
    jne r2_invalid
    jmp .Lr2_timestamp_next
.Lr2_timestamp_digit:
    mov al, [rdi + rcx]
    sub al, '0'
    cmp al, 9
    ja r2_invalid
.Lr2_timestamp_next:
    inc ecx
    jmp .Lr2_timestamp_byte
.Lr2_task_objects:
    R2_GET r12, objects
    cmp qword ptr [rax], SMP_ARRAY
    jne r2_invalid
    mov r14, [rax + 24]
    lea r13, [rax + 32]
    xor r15d, r15d
    mov qword ptr [rip + r2_task_total], 0
    mov byte ptr [rip + r2_previous_digest], 0
.Lr2_task_object:
    lea rax, [rip + smp_tokens]
    mov rdx, r13
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lr2_task_objects_done
    inc r15
    cmp r15, R2_OBJECTS
    ja r2_invalid
    mov rdi, r13
    lea rsi, [rip + r2_fields_task_object]
    mov edx, 3
    mov ecx, 3
    call r2_keys
    R2_GET r13, sha256
    mov rdi, rax
    lea rsi, [rip + r2_task_digest]
    mov edx, 64
    call r2_hex_token
    lea rdi, [rip + r2_previous_digest]
    lea rsi, [rip + r2_task_digest]
    call r2_lex
    cmp eax, 0
    jge r2_invalid
    lea rdi, [rip + r2_previous_digest]
    lea rsi, [rip + r2_task_digest]
    call copy_string
    R2_GET r13, bytes
    mov rdi, rax
    mov esi, ARTIFACT_LIMIT
    call r2_number
    add [rip + r2_task_total], rax
    cmp qword ptr [rip + r2_task_total], R2_TASK_BYTES
    ja r2_invalid
    mov [rip + r2_task_object_bytes], rax
    R2_GET r13, received
    mov qword ptr [rip + r2_task_received], 1
    cmp qword ptr [rax], SMP_TRUE
    je .Lr2_task_object_binding
    cmp qword ptr [rax], SMP_FALSE
    jne r2_invalid
    mov qword ptr [rip + r2_task_received], 0
.Lr2_task_object_binding:
    cmp qword ptr [rip + r2_mode], 1
    jne .Lr2_task_object_next
    xor ebx, ebx
.Lr2_task_object_find:
    cmp rbx, [rip + r2_object_count]
    jae r2_invalid
    imul rax, rbx, R2_RECORD
    lea rdi, [rip + r2_objects]
    add rdi, rax
    lea rsi, [rip + r2_task_digest]
    call streq
    test eax, eax
    jnz .Lr2_task_object_found
    inc ebx
    jmp .Lr2_task_object_find
.Lr2_task_object_found:
    imul rax, rbx, R2_RECORD
    lea rdx, [rip + r2_objects]
    mov r8, [rdx + rax + 72]
    cmp r8, [rip + r2_task_object_bytes]
    jne r2_invalid
    mov rcx, [rip + r2_task_received]
    mov [rdx + rax + R2_OBJECT_RECEIVED], rcx
.Lr2_task_object_next:
    mov rax, [r13 + 24]
    shl rax, 5
    lea r13, [rip + smp_tokens]
    add r13, rax
    jmp .Lr2_task_object
.Lr2_task_objects_done:
    test r15, r15
    jz r2_invalid
    cmp qword ptr [rip + r2_mode], 1
    jne .Lr2_task_failure
    cmp r15, [rip + r2_object_count]
    jne r2_invalid
.Lr2_task_failure:
    R2_GET r12, failure
    cmp qword ptr [rax], SMP_NULL
    je .Lr2_task_release
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + r2_fields_failure]
    mov edx, 3
    mov ecx, 3
    call r2_keys
    R2_GET r13, code
    mov rdi, rax
    lea rsi, [rip + r2_task_detail]
    mov edx, 128
    call r2_string
    R2_GET r13, detail
    mov rdi, rax
    lea rsi, [rip + r2_task_detail]
    mov edx, 1024
    call r2_text
    R2_GET r13, retryable
    cmp qword ptr [rax], SMP_TRUE
    je .Lr2_task_release
    cmp qword ptr [rax], SMP_FALSE
    jne r2_invalid
.Lr2_task_release:
    R2_GET r12, release
    cmp qword ptr [rax], SMP_NULL
    je .Lr2_task_identity
    mov r13, rax
    lea rdi, [rip + r2_task_state]
    lea rsi, [rip + r2_published_state]
    call streq
    test eax, eax
    jz r2_invalid
    mov rax, r13
    mov rdi, rax
    lea rsi, [rip + r2_fields_task_release]
    mov edx, 2
    mov ecx, 2
    call r2_keys
    R2_GET r13, manifest_url
    mov rdi, rax
    lea rsi, [rip + r2_task_detail]
    mov edx, 1024
    call r2_string
    lea rdi, [rip + r2_task_detail]
    call r2_origin
    test eax, eax
    jz r2_invalid
    R2_GET r13, metadata_url
    mov rdi, rax
    lea rsi, [rip + r2_task_detail]
    mov edx, 1024
    call r2_string
    lea rdi, [rip + r2_task_detail]
    call r2_origin
    test eax, eax
    jz r2_invalid
.Lr2_task_identity:
    mov rax, r12
    mov rdi, rax
    lea rsi, [rip + r2_key_id]
    call r2_required
    mov rdi, rax
    lea rsi, [rip + r2_returned_task]
    mov edx, 33
    call r2_string
    lea rdi, [rip + r2_returned_task]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_invalid
    cmp byte ptr [rip + r2_task_id], 0
    je .Lr2_task_copy
    lea rdi, [rip + r2_task_id]
    lea rsi, [rip + r2_returned_task]
    call streq
    test eax, eax
    jz r2_invalid
.Lr2_task_copy:
    lea rdi, [rip + r2_task_id]
    lea rsi, [rip + r2_returned_task]
    call copy_string
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
r2_report:
    cmp byte ptr [rip + json_mode], 0
    je .Lr2_report_text
    mov edi, 1
    lea rsi, [rip + r2_response]
    mov rdx, [rip + r2_response_length]
    call write_all
    jmp .Lr2_report_end
.Lr2_report_text:
    lea rdi, [rip + r2_task_text]
    call out
    lea rdi, [rip + r2_task_id]
    call out
    lea rdi, [rip + r2_task_separator]
    call out
    lea rdi, [rip + r2_task_state]
    call out
    lea rdi, [rip + r2_task_note]
    call out
.Lr2_report_end:
    call registry_cleanup
    jmp exit_ok

/* Called by registry_cleanup for any exit, including reused legacy routines.
 * Remove only fixed files/validated digest names in our owned private stage. */
r2_clean_files:
    cmp byte ptr [rip + r2_active], 0
    je .Lr2_clean_return
    push rbx
    push r12
    cmp byte ptr [rip + registry_has_workspace], 0
    je .Lr2_clean_done
    call r2p_cleanup
    mov eax, 87
    lea rdi, [rip + r2_header_path]
    syscall
    mov eax, 87
    lea rdi, [rip + r2_helper_path]
    syscall
    xor ebx, ebx
.Lr2_clean_object:
    cmp rbx, [rip + r2_object_count]
    jae .Lr2_clean_done
    mov rax, rbx
    imul rax, R2_RECORD
    lea r12, [rip + r2_objects]
    add r12, rax
    mov rdi, r12
    call r2_object_stage_path
    mov eax, 87
    lea rdi, [rip + r2_object_path]
    syscall
    inc ebx
    jmp .Lr2_clean_object
.Lr2_clean_done:
    pop r12
    pop rbx
.Lr2_clean_return:
    ret
r2_object_stage_path:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + r2_object_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, rbx
    call copy_string
    pop rbx
    ret

.section .rodata
r2_commands:
    .quad r2_cmd_publish,1,r2_cmd_task,2,r2_cmd_fetch,3,r2_cmd_install,4
    .quad r3_cmd_resolve,5,r3_cmd_sync,6
    .quad registry_opt_help,0,0,0
r3_cmd_resolve: .asciz "resolve"
r3_cmd_sync: .asciz "sync"
r2_cmd_publish: .asciz "publish"
r2_cmd_task: .asciz "task"
r2_cmd_fetch: .asciz "fetch"
r2_cmd_install: .asciz "install"
r2_opt_manifest: .asciz "--manifest"
r2_opt_objects: .asciz "--objects-dir"
r2_opt_credential: .asciz "--credential-file"
r2_opt_api: .asciz "--api"
r2_opt_key: .asciz "--idempotency-key"
r2_opt_id: .asciz "--registry-id"
r2_opt_root: .asciz "--root"
r2_opt_state: .asciz "--state"
r2_opt_mirror: .asciz "--mirror"
r2_opt_ca: .asciz "--ca"
r2_options:
    .quad r2_opt_manifest,r2_manifest,1,r2_opt_objects,r2_objects_dir,2
    .quad r2_opt_credential,r2_credential,4,r2_opt_api,r2_api,8
    .quad r2_opt_key,r2_key,16,r2_opt_id,r2_registry_id,32
    .quad r2_opt_root,r2_root,64,r2_opt_state,r2_state,128
    .quad r2_opt_ca,r2_ca,256,registry_opt_target,r2_target,512
    .quad registry_opt_kind,r2_kind,1024,registry_opt_output,r2_output,2048
    .quad r2p_opt_project,r2p_project,4096,r2p_opt_name,r2p_name,8192
    .quad r2p_opt_owner,r2p_owner,16384,r2p_opt_summary,r2p_summary,32768
    .quad r2p_opt_license,r2p_license,65536,r2p_opt_commit,r2p_commit,131072
    .quad r2p_opt_path,r2p_source_path,262144,r2p_opt_repository,r2p_repository,524288
    .quad 0,0,0
r2_method_get: .asciz "GET"
r2_method_post: .asciz "POST"
r2_method_put: .asciz "PUT"
r2_request: .asciz "--request"
r2_write_out: .asciz "--write-out"
r2_status_format: .asciz "%{http_code}"
r2_header_option: .asciz "--header"
r2_data_binary: .asciz "--data-binary"
r2_upload_file: .asciz "--upload-file"
r2_content_json: .asciz "Content-Type: application/json"
r2_content_blob: .asciz "Content-Type: application/octet-stream"
r2_ca_option: .asciz "--cacert"
r2_control_decimal: .asciz "65536"
r2_seconds: .asciz "110"
r2_token_prefix: .asciz "asm_pub_v1_"
r2_authorization: .asciz "Authorization: Bearer "
r2_idempotency: .asciz "Idempotency-Key: "
r2_publications_path: .asciz "/api/v2/publications"
r2_header_suffix: .asciz "/authorization"
r2_helper_suffix: .asciz "/asm-verify"
r2_key_id: .asciz "id"
r2_k_registry_id: .asciz "registry_id"
r2_k_package_id: .asciz "package_id"
r2_k_release_id: .asciz "release_id"
r2_k_manifest_sha256: .asciz "manifest_sha256"
r2_k_publication: .asciz "publication"
r2_fields_envelope: .asciz "schema\0registry_id\0package_id\0release_id\0manifest_sha256\0publication\0"
r2_fields_task: .asciz "schema\0id\0package_id\0manifest_sha256\0state\0upload_expires_at\0objects\0failure\0release\0"
r2_fields_task_object: .asciz "sha256\0bytes\0received\0"
r2_fields_failure: .asciz "code\0detail\0retryable\0"
r2_fields_task_release: .asciz "manifest_url\0metadata_url\0"
r2_k_state: .asciz "state"
r2_k_upload_expires_at: .asciz "upload_expires_at"
r2_k_objects: .asciz "objects"
r2_k_received: .asciz "received"
r2_k_failure: .asciz "failure"
r2_k_release: .asciz "release"
r2_k_code: .asciz "code"
r2_k_detail: .asciz "detail"
r2_k_retryable: .asciz "retryable"
r2_k_manifest_url: .asciz "manifest_url"
r2_k_metadata_url: .asciz "metadata_url"
r2_task_states: .asciz "accepted\0uploading\0checking\0committed\0distributing\0published\0"
r2_published_state: .asciz "published"
r2_timestamp_shape: .asciz "0000-00-00T00:00:00Z"
r2_registries_prefix: .asciz "registries/"
r2_releases_path: .asciz "/releases/"
r2_policy_suffix: .asciz "/policy.tsv"
r2_json_suffix: .asciz ".json"
r2_blobs_path: .asciz "/blobs/sha256/"
r2_selection_query: .asciz "?x-asm="
r2_adapter_command: .asciz "registry-target"
r2_policy_header: .asciz "# asm-registry-policy-v2"
r2_origin_prefix: .asciz "v2:"
r2_fetched_json: .asciz "{\"ok\":true,\"authenticated\":true,\"executed\":false}\n"
r2_unchanged_json: .asciz "{\"ok\":true,\"authenticated\":true,\"unchanged\":true,\"executed\":false}\n"
r2_artifacts_path: .asciz "/artifacts/"
r2_k_schema: .asciz "schema"
r2_k_name: .asciz "name"
r2_k_version: .asciz "version"
r2_k_owner_id: .asciz "owner_id"
r2_k_summary: .asciz "summary"
r2_k_license: .asciz "license"
r2_k_source: .asciz "source"
r2_k_path: .asciz "path"
r2_k_repository: .asciz "repository"
r2_k_commit: .asciz "commit"
r2_k_algorithm: .asciz "algorithm"
r2_k_digest: .asciz "digest"
r2_k_archive: .asciz "archive"
r2_k_sha256: .asciz "sha256"
r2_k_bytes: .asciz "bytes"
r2_k_artifacts: .asciz "artifacts"
r2_k_cpu_features: .asciz "cpu_features"
r2_k_kind: .asciz "kind"
r2_k_isa: .asciz "isa"
r2_k_os: .asciz "os"
r2_k_abi: .asciz "abi"
r2_k_format: .asciz "format"
r2_fields_manifest: .asciz "artifacts\0license\0name\0owner_id\0schema\0source\0summary\0version\0dependencies\0features\0"
r2_fields_source: .asciz "archive\0commit\0path\0repository\0"
r2_fields_commit: .asciz "algorithm\0digest\0"
r2_fields_archive: .asciz "bytes\0sha256\0"
r2_fields_artifact: .asciz "abi\0bytes\0cpu_features\0format\0isa\0kind\0os\0sha256\0"
r2_git_sha1: .asciz "git-sha1"
r2_git_sha256: .asciz "git-sha256"
r2_tar_gzip: .asciz "tar.gz"
r2_isa_x86: .asciz "x86_64"
r2_isa_arm: .asciz "aarch64"
r2_isa_riscv: .asciz "riscv64"
r2_os_linux: .asciz "linux"
r2_os_macos: .asciz "macos"
r2_os_windows: .asciz "windows"
r2_abi_x86: .asciz "sysv-amd64"
r2_abi_arm: .asciz "aapcs64"
r2_abi_riscv: .asciz "lp64d"
r2_abi_macos: .asciz "apple-arm64"
r2_abi_win_x86: .asciz "windows-x64"
r2_abi_win_arm: .asciz "windows-arm64"
r2_format_elf: .asciz "elf"
r2_format_macho: .asciz "macho"
r2_format_pe: .asciz "pe"
r2_target_x86: .asciz "x86_64-linux"
r2_target_arm: .asciz "aarch64-linux"
r2_target_riscv: .asciz "riscv64-linux"
r2_target_macos: .asciz "aarch64-macos"
r2_target_win_x86: .asciz "x86_64-windows"
r2_target_win_arm: .asciz "aarch64-windows"
.balign 8
r2_tuples:
    .quad r2_target_x86,r2_isa_x86,r2_os_linux,r2_abi_x86,r2_format_elf
    .quad r2_target_arm,r2_isa_arm,r2_os_linux,r2_abi_arm,r2_format_elf
    .quad r2_target_riscv,r2_isa_riscv,r2_os_linux,r2_abi_riscv,r2_format_elf
    .quad r2_target_macos,r2_isa_arm,r2_os_macos,r2_abi_macos,r2_format_macho
    .quad r2_target_win_x86,r2_isa_x86,r2_os_windows,r2_abi_win_x86,r2_format_pe
    .quad r2_target_win_arm,r2_isa_arm,r2_os_windows,r2_abi_win_arm,r2_format_pe
r2_task_text: .asciz "Publication task "
r2_task_separator: .asciz ": "
r2_task_note: .asciz ".\n"
r2_err_arguments: .asciz "invalid registry V2 arguments; use asm registry --help"
r2_err_manifest: .asciz "invalid registry V2 metadata or declared bytes; correct the manifest and retry the same task only with identical bytes"
r2_err_io: .asciz "registry V2 requires protected regular files and directories; check ownership, links, permissions and free space"
r2_err_http: .asciz "registry V2 request failed; inspect the task with a current credential before retrying the same key"
r2_err_credential: .asciz "publication credential was refused; obtain a current credential before retrying the same task"
r2_err_scope: .asciz "publication scope was refused; request access to the exact owner, package and operation"
r2_err_expired: .asciz "publication upload reservation expired; create a new task with a fresh key and current credential"
r2_err_trust: .asciz "registry V2 authentication or policy failed; check the registry identity, trusted root, clock and mirrors"
r2_err_upgrade: .asciz "this installation uses registry V2; V1 upgrade cannot change its authority; use the exact asm registry install command"
r2_help_text:
    .ascii "Usage: asm registry resolve|sync --project DIR --registry-id ID --root FILE\n"
    .ascii "  --state DIR --mirror HTTPS_BASE --target TARGET [--ca FILE] [--json]\n"
    .ascii "Resolve accepts [--features NAME,NAME] [--no-default-features].\n"
    .ascii "Resolve writes a complete graph lock. Sync restores exact source packages.\n"
    .ascii "Build checks local locked bytes; sync checks current registry policy.\n\n"
    .ascii "Usage: asm registry publish --project REPO_ROOT --name OWNER/NAME --owner-id 32HEX\n"
    .ascii "         --summary TEXT --license SPDX [--commit FULL_COMMIT] [--source-path PATH]\n"
    .ascii "         [--repository HTTPS_URL] [--source-target TARGET ...]\n"
    .ascii "         [--executable TARGET FILE ...] --credential-file FILE --api HTTPS_BASE\n"
    .ascii "         --idempotency-key 32HEX [--ca FILE] [--json]\n"
    .ascii "Usage: asm registry publish --manifest FILE --objects-dir DIR\n"
    .ascii "         --credential-file FILE --api HTTPS_BASE --idempotency-key 32HEX [--json]\n"
    .ascii "       asm registry task ID --credential-file FILE --api HTTPS_BASE [--json]\n"
    .ascii "       asm registry fetch|install OWNER/NAME@VERSION --registry-id 32HEX\n"
    .ascii "         --root ROOTFILE --state STATE --mirror HTTPS_BASE (up to three)\n"
    .ascii "         [--ca FILE] --target TARGET --kind source|executable --output PATH\n"
    .ascii "       asm registry install uses the same options and requires a host executable.\n"
    .ascii "Fetch and install require clean absolute ROOT, STATE and CA paths.\n"
    .ascii "Objects use their SHA-256 digest as the filename. Credentials stay outside argv.\n"
    .ascii "Project mode reads only the selected local commit (default HEAD), never dirty files.\n"
    .ascii "Select at least one artifact; up to six source targets and six executable files.\n"
    .ascii "It requires Git and gzip. It does not build, execute, or resolve dependencies.\n"
    .ascii "Exact V2 commands never fall back to V1. Installation never executes a package.\n"
    .byte 0
.balign 16
r2_helper_bytes:
.incbin "build/asm-verify-x86_64-linux"
r2_helper_end:
.equ r2_helper_length, r2_helper_end-r2_helper_bytes
.section .bss
.balign 8
r2_mode: .skip 8
r2_fields: .skip 8
r2_selector: .skip 8
r2_manifest: .skip 8
r2_objects_dir: .skip 8
r2_credential: .skip 8
r2_api: .skip 8
r2_key: .skip 8
r2_registry_id: .skip 8
r2_root: .skip 8
r2_state: .skip 8
r2_ca: .skip 8
r2_target: .skip 8
r2_kind: .skip 8
r2_output: .skip 8
r2_mirrors: .skip 24
r2_mirror_count: .skip 8
r2_object_count: .skip 8
r2_objects: .skip R2_OBJECTS * R2_RECORD
r2_stat: .skip 144
r2_path: .skip 4096
r2_cwd: .skip 4096
r2_header_path: .skip 96
r2_helper_path: .skip 96
r2_object_path: .skip 160
r2_header: .skip 256
r2_token: .skip 78
r2_key_buffer: .skip 256
r2_task_id: .skip 33
r2_returned_task: .skip 33
r2_header_argument: .skip 100
r2_body_argument: .skip 4100
r2_url: .skip 4096
r2_response: .skip R2_CONTROL + 1
r2_response_length: .skip 8
r2_http_argv: .skip 256
r2_http_method: .skip 8
r2_pipe: .skip 8
r2_status: .skip 8
r2_status_length: .skip 8
r2_child_status: .skip 8
r2_child_file_limit: .skip 8
r2_rlimit: .skip 16
r2_manifest_data: .skip R2_CONTROL + 1
r2_manifest_length: .skip 8
r2_dependency_count: .skip 8
r2_dependencies: .skip 64 * 240
r2_name: .skip 105
r2_version: .skip 33
r2_owner_id: .skip 33
r2_summary: .skip 161
r2_license: .skip 64
r2_source_path: .skip 241
r2_repository: .skip 1025
r2_commit: .skip 65
r2_source_sha: .skip 65
r2_source_bytes: .skip 8
r2_digest: .skip 65
r2_total_bytes: .skip 8
r2_tuple_bits: .skip 8
r2_selected: .skip 8
r2_selected_sha: .skip 65
r2_selected_bytes: .skip 8
r2_requested_name: .skip 170
r2_requested_version: .skip 33
r2_root_data: .skip INDEX_LIMIT + 1
r2_root_sha: .skip 65
r2_envelope: .skip INDEX_LIMIT + 1
r2_envelope_sha: .skip 65
r2_package_id: .skip 33
r2_release_id: .skip 33
r2_manifest_sha: .skip 65
r2_target_path: .skip 512
r2_adapter_argv: .skip 80
r2_adapter_output: .skip 4096
r2_policy: .skip INDEX_LIMIT + 1
r2_policy_cursor: .skip 8
r2_policy_end: .skip 8
r2_policy_fields: .skip 48
r2_previous_name: .skip 105
r2_previous_version: .skip 33
r2_blob_argv: .skip 160
r2_size_decimal: .skip 32
r2_size_pointer: .skip 8
r2_synthetic_row: .skip 64
r2_origin_receipt: .skip 256
r2_task_package: .skip 33
r2_task_manifest: .skip 65
r2_task_state: .skip 16
r2_timestamp: .skip 21
r2_task_digest: .skip 65
r2_previous_digest: .skip 65
r2_task_total: .skip 8
r2_task_object_bytes: .skip 8
r2_task_received: .skip 8
r2_task_detail: .skip 1024
r2_active: .skip 1
r2_post_attempted: .skip 1
.include "cli/registry_project.s"
