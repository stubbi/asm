/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native committed-project preparation for the optional registry V2 client.
 * All package, USTAR, selection and canonical-JSON policy remains assembly.
 * Fixed Git plumbing supplies committed objects; fixed gzip supplies compression.
 * SysV ABI: returning functions preserve RBX/RBP/R12-R15; other integer registers
 * and flags are scratch. Serial owned buffers: list3MiB, 4096 records32 bytes,
 * header512 bytes. Batch mapping <=64MiB+4096*96; unmapped before validation.
 * Private temporary source data peaks below193MiB; files are removed on exit.
 */
.intel_syntax noprefix
.equ R2P_LIST, 3145728
.equ R2P_FILES, 4096
.equ R2P_RECORD, 32
.equ R2P_BATCH, ARC_LIMIT + R2P_FILES * 96
.equ R2P_REQUIRED, 127004
.equ R2P_ALLOWED, R2P_REQUIRED | 131072 | 262144 | 524288 | 1048576
.section .text

/* RDI=option. EAX=1 if a repeated project selection was consumed, otherwise0.
 * Consumes one target and, for --executable, one path. Stack32. */
r2p_option:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor r13d, r13d
    lea rsi, [rip + r2p_opt_source_target]
    call streq
    test eax, eax
    jnz .Lr2p_selection_option
    mov rdi, r12
    lea rsi, [rip + r2p_opt_executable]
    call streq
    test eax, eax
    jz .Lr2p_option_no
    mov r13d, 1
.Lr2p_selection_option:
    call registry_arg_value
    mov rdi, rax
    call r2p_tuple
    lea ecx, [edx*2]
    add ecx, r13d
    bt [rip + r2p_selections], rcx
    jc r2_arguments
    bts [rip + r2p_selections], rcx
    or qword ptr [rip + r2_fields], 1048576
    test r13d, r13d
    jz .Lr2p_option_yes
    mov ebx, edx
    call registry_arg_value
    lea rdx, [rip + r2p_executable_paths]
    mov [rdx + rbx*8], rax
.Lr2p_option_yes:
    mov eax, 1
    jmp .Lr2p_option_done
.Lr2p_option_no:
    xor eax, eax
.Lr2p_option_done:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=target. RAX=approved tuple pointer, EDX=index0..5; unknown=>exit2. */
r2p_tuple:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    lea rbx, [rip + r2_tuples]
    xor edx, edx
.Lr2p_tuple_loop:
    mov rdi, r12
    mov rsi, [rbx]
    call streq
    test eax, eax
    jnz .Lr2p_tuple_found
    inc edx
    add rbx, 40
    cmp edx, 6
    jb .Lr2p_tuple_loop
    jmp r2_arguments
.Lr2p_tuple_found:
    mov rax, rbx
    add rsp, 8
    pop r12
    pop rbx
    ret

/* Validate mode/metadata before opening project files. Stack16. */
r2p_arguments:
    push rbx
    mov rax, [rip + r2_fields]
    and rax, -257
    mov rdx, rax
    and eax, R2P_REQUIRED
    cmp eax, R2P_REQUIRED
    jne r2_arguments
    and rdx, ~R2P_ALLOWED
    jnz r2_arguments
    cmp qword ptr [rip + r2p_selections], 0
    je r2_arguments
    mov rdi, [rip + r2p_name]
    call registry_valid_package
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2p_owner]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2p_summary]
    call strlen
    test rax, rax
    jz r2_arguments
    cmp rax, 160
    ja r2_arguments
    cmp byte ptr [rdi], 32
    je r2_arguments
    cmp byte ptr [rdi + rax - 1], 32
    je r2_arguments
    xor ecx, ecx
.Lr2p_summary_byte:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lr2p_license
    cmp eax, 32
    jb r2_arguments
    cmp eax, 126
    ja r2_arguments
    inc ecx
    jmp .Lr2p_summary_byte
.Lr2p_license:
    mov rdi, [rip + r2p_license]
    lea rsi, [rip + pub_licenses]
    call pub_in_strings
    test eax, eax
    jz r2_arguments
    cmp qword ptr [rip + r2p_source_path], 0
    jne .Lr2p_path_check
    lea rax, [rip + pub_dot]
    mov [rip + r2p_source_path], rax
.Lr2p_path_check:
    mov rdi, [rip + r2p_source_path]
    cmp word ptr [rdi], 0x002e
    je .Lr2p_repository_check
    call pub_portable_path
    test eax, eax
    jnz r2_arguments
.Lr2p_repository_check:
    mov rdi, [rip + r2p_repository]
    test rdi, rdi
    jz .Lr2p_commit_check
    call r2_repository_locator
    test eax, eax
    jz r2_arguments
.Lr2p_commit_check:
    mov rdi, [rip + r2p_commit]
    test rdi, rdi
    jz .Lr2p_arguments_done
    call strlen
    cmp eax, 40
    je .Lr2p_commit_hex
    cmp eax, 64
    jne r2_arguments
.Lr2p_commit_hex:
    mov esi, eax
    mov ebx, eax
    call r2_hex
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2p_commit]
    xor ecx, ecx
.Lr2p_commit_zero:
    cmp byte ptr [rdi + rcx], '0'
    jne .Lr2p_arguments_done
    inc ecx
    cmp ecx, ebx
    jb .Lr2p_commit_zero
    jmp r2_arguments
.Lr2p_arguments_done:
    pop rbx
    ret

r2p_bad:
    lea rdi, [rip + r2p_error]
    mov esi, 1
    jmp registry_fail
r2p_not_root:
    lea rdi, [rip + r2p_error_root]
    mov esi, 1
    jmp registry_fail
r2p_lock_error:
    lea rdi, [rip + r2p_error_lock]
    mov esi, 1
    jmp registry_fail

/* RDI=fixed workspace suffix. RAX=owned r2p_path[160] string. Stack16. */
r2p_path_for:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + r2p_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    mov rsi, rbx
    call copy_string
    lea rax, [rip + r2p_path]
    pop rbx
    ret

/* RDI=owned fixed path. RAX=new private file FD>=3; no replacement. */
r2p_create:
    sub rsp, 8
    mov eax, 2
    mov esi, O_CLOEXEC + O_NOFOLLOW + 193
    mov edx, 384
    syscall
    test rax, rax
    js r2p_bad
    mov rdi, rax
    call arc_promote_fd
    test rax, rax
    js r2p_bad
    add rsp, 8
    ret

/* RDI=owned path. RAX=read FD>=3; file never follows a link. */
r2p_open:
    sub rsp, 8
    mov eax, 2
    mov esi, O_CLOEXEC + O_NOFOLLOW + O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js r2p_bad
    mov rdi, rax
    call arc_promote_fd
    test rax, rax
    js r2p_bad
    add rsp, 8
    ret

/* RDI=fixed executable, RSI=direct argv, RDX=input FD>=3, RCX=output FD>=3,
 * R8=max output file bytes. Returns only after successful child exit. Children
 * run in opened repo FD, with closed inherited FDs on exec, fixed Git settings,
 * no secret, stderr /dev/null, a120s alarm and RLIMIT_FSIZE. Frame56. */
r2p_run:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [rip + r2p_limit], r8
    mov eax, 57
    syscall
    test rax, rax
    js r2p_bad
    jz .Lr2p_child
    mov rbx, rax
.Lr2p_wait:
    mov eax, 61
    mov rdi, rbx
    lea rsi, [rip + r2p_child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lr2p_wait
    test rax, rax
    js .Lr2p_kill
    cmp dword ptr [rip + r2p_child_status], 0
    jne r2p_bad
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lr2p_kill:
    mov eax, 62
    mov rdi, rbx
    mov esi, 9
    syscall
.Lr2p_failed_reap:
    mov eax, 61
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lr2p_failed_reap
    jmp r2p_bad
.Lr2p_child:
    mov eax, 81
    mov rdi, [rip + r2p_repo_fd]
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov eax, 33
    mov rdi, r14
    xor esi, esi
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov eax, 33
    mov rdi, r15
    mov esi, 1
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov eax, 2
    lea rdi, [rip + self_dev_null]
    mov esi, 2
    xor edx, edx
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov rbp, rax
    mov eax, 33
    mov rdi, rbp
    mov esi, 2
    syscall
    cmp rbp, 2
    je .Lr2p_child_signal
    mov eax, 3
    mov rdi, rbp
    syscall
.Lr2p_child_signal:
    mov eax, 13
    mov edi, 14
    lea rsi, [rip + self_default_signal]
    xor edx, edx
    mov r10d, 8
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov eax, 14
    mov edi, 1
    lea rsi, [rip + self_alarm_signal_mask]
    xor edx, edx
    mov r10d, 8
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov eax, 37
    mov edi, 120
    syscall
    mov eax, 97
    mov edi, 1
    lea rsi, [rip + r2p_rlimit]
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov rax, [rip + r2p_limit]
    cmp rax, [rip + r2p_rlimit]
    cmova rax, [rip + r2p_rlimit]
    mov [rip + r2p_rlimit], rax
    mov rax, [rip + r2p_limit]
    cmp rax, [rip + r2p_rlimit + 8]
    cmova rax, [rip + r2p_rlimit + 8]
    mov [rip + r2p_rlimit + 8], rax
    mov eax, 160
    mov edi, 1
    lea rsi, [rip + r2p_rlimit]
    syscall
    test rax, rax
    js .Lr2p_child_bad
    mov eax, 59
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + r2p_environment]
    syscall
.Lr2p_child_bad:
    mov eax, 60
    mov edi, 127
    syscall
    ud2

/* RSI=Git argv, RDI=fixed suffix, R8=file cap. Creates a private output and
 * runs Git with /dev/null input; returns open read FD. Stack40. */
r2p_git_file:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rsi
    mov r13, r8
    call r2p_path_for
    mov r14, rax
    mov rdi, rax
    mov eax, 87
    syscall
    mov rdi, r14
    call r2p_create
    mov rbx, rax
    mov eax, 2
    lea rdi, [rip + self_dev_null]
    mov esi, O_CLOEXEC
    xor edx, edx
    syscall
    test rax, rax
    js r2p_bad
    mov rdi, rax
    call arc_promote_fd
    mov r14, rax
    lea rdi, [rip + r2p_git]
    mov rsi, r12
    mov rdx, r14
    mov rcx, rbx
    mov r8, r13
    call r2p_run
    mov rdi, r14
    call arc_close
    mov rdi, rbx
    call arc_close
    lea rdi, [rip + r2p_path]
    call r2p_open
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Create all local inputs before a credential is read. Output: canonical
 * r2_manifest and owned digest objects suitable for the shared upload engine.
 * The selected commit alone supplies source bytes; no working file is read.
 * Stack56. Terminal failures clean this invocation's private stage. */
r2_project_prepare:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov rdi, [rip + r2p_project]
    cmp word ptr [rdi], 0x002e
    jne .Lr2p_open_repo
    lea rdi, [rip + r2_cwd]
.Lr2p_open_repo:
    mov esi, 1
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    call arc_promote_fd
    test rax, rax
    js r2p_bad
    mov [rip + r2p_repo_fd], rax
    call r2p_credential_location
    lea rdi, [rip + r2p_info_suffix]
    lea rsi, [rip + r2p_prefix_argv]
    mov r8d, 4096
    call r2p_git_file
    mov rdi, rax
    lea rsi, [rip + r2p_info]
    mov edx, 4096
    call r2_read_fd
    test rax, rax
    jz .Lr2p_resolve_commit
    cmp rax, 1
    jne r2p_not_root
    cmp byte ptr [rip + r2p_info], 10
    jne r2p_not_root
.Lr2p_resolve_commit:
    lea rdi, [rip + r2p_commit_spec]
    mov rsi, [rip + r2p_commit]
    test rsi, rsi
    jnz .Lr2p_commit_spec
    lea rsi, [rip + r2p_head]
.Lr2p_commit_spec:
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r2p_commit_suffix]
    call copy_string
    lea rdi, [rip + r2p_info_suffix]
    lea rsi, [rip + r2p_commit_argv]
    mov r8d, 80
    call r2p_git_file
    mov rdi, rax
    lea rsi, [rip + r2p_info]
    mov edx, 80
    call r2_read_fd
    cmp rax, 41
    je .Lr2p_sha1
    cmp rax, 65
    jne r2p_bad
    mov ebx, 64
    lea rax, [rip + r2_git_sha256]
    jmp .Lr2p_commit_length
.Lr2p_sha1:
    mov ebx, 40
    lea rax, [rip + r2_git_sha1]
.Lr2p_commit_length:
    mov [rip + r2p_algorithm], rax
    mov [rip + r2p_oid_length], rbx
    lea rdi, [rip + r2p_info]
    cmp byte ptr [rdi + rbx], 10
    jne r2p_bad
    mov byte ptr [rdi + rbx], 0
    mov esi, ebx
    call r2_hex
    test eax, eax
    jz r2p_bad
    mov rsi, [rip + r2p_commit]
    test rsi, rsi
    jz .Lr2p_commit_copy
    lea rdi, [rip + r2p_info]
    call streq
    test eax, eax
    jz r2p_bad
.Lr2p_commit_copy:
    lea rdi, [rip + r2_commit]
    lea rsi, [rip + r2p_info]
    call copy_string
    lea rdi, [rip + r2_name]
    mov rsi, [rip + r2p_name]
    call copy_string
    lea rdi, [rip + r2_owner_id]
    mov rsi, [rip + r2p_owner]
    call copy_string
    lea rdi, [rip + r2_summary]
    mov rsi, [rip + r2p_summary]
    call copy_string
    lea rdi, [rip + r2_license]
    mov rsi, [rip + r2p_license]
    call copy_string
    lea rdi, [rip + r2_source_path]
    mov rsi, [rip + r2p_source_path]
    call copy_string
    mov rax, [rip + r2p_source_path]
    mov [rip + r2p_tree_argv + 12*8], rax
    lea rdi, [rip + r2p_tree_suffix]
    lea rsi, [rip + r2p_tree_argv]
    mov r8d, R2P_LIST
    call r2p_git_file
    mov rdi, rax
    lea rsi, [rip + r2p_tree_data]
    mov edx, R2P_LIST
    call r2_read_fd
    lea rdx, [rip + r2p_tree_data]
    add rdx, rax
    mov [rip + r2p_tree_end], rdx
    call r2p_collect
    call r2p_archive
    /* Validate once to inspect the committed manifest. The existing parser
     * checks inactive target inputs; only the expected version is omitted. */
    lea rdi, [rip + r2_source_sha]
    call r2_object_stage_path
    lea rdi, [rip + r2_object_path]
    call validate_source_archive
    test eax, eax
    jnz r2p_bad
    lea rdi, [rip + pub_manifest_name]
    call source_archive_member
    test rax, rax
    jz r2p_bad
    test ecx, ecx
    jnz r2p_bad
    cmp rdx, PUB_TARGET_MANIFEST_MAX
    ja r2p_bad
    lea rax, [rip + r2_name]
    mov [rip + pub_name], rax
    lea rax, [rip + r2_source_path]
    mov [rip + pub_source_path], rax
    mov byte ptr [rip + pub_project_inspect_version], 1
    xor ebx, ebx
.Lr2p_first_tuple:
    lea ecx, [ebx*2]
    mov rax, [rip + r2p_selections]
    shr rax, cl
    test eax, 3
    jnz .Lr2p_inspect
    inc ebx
    cmp ebx, 6
    jb .Lr2p_first_tuple
    jmp r2p_bad
.Lr2p_inspect:
    imul rax, rbx, 40
    lea rdx, [rip + r2_tuples]
    mov rdi, [rdx + rax]
    call pub_check_project_v2
    mov byte ptr [rip + pub_project_inspect_version], 0
    test eax, eax
    jnz r2p_bad
    lea rdi, [rip + pub_project_version]
    call registry_valid_version
    test eax, eax
    jz r2p_bad
    lea rdi, [rip + r2_version]
    lea rsi, [rip + pub_project_version]
    call copy_string
    lea rax, [rip + r2_version]
    mov [rip + pub_version], rax
    xor ebx, ebx
.Lr2p_validate_targets:
    cmp ebx, 6
    jae .Lr2p_targets_validated
    lea ecx, [ebx*2]
    mov rax, [rip + r2p_selections]
    shr rax, cl
    test eax, 3
    jz .Lr2p_validate_next
    imul rax, rbx, 40
    lea rdx, [rip + r2_tuples]
    mov rdi, [rdx + rax]
    call pub_check_project_v2
    test eax, eax
    jnz r2p_bad
.Lr2p_validate_next:
    inc ebx
    jmp .Lr2p_validate_targets
.Lr2p_targets_validated:
    call r2p_credential_identity
    call r2p_executables
    call r2p_json
    lea rdi, [rip + r2p_manifest_suffix]
    call r2p_path_for
    lea rdi, [rip + r2p_manifest_path]
    lea rsi, [rip + r2p_path]
    call copy_string
    lea rdi, [rip + r2p_manifest_path]
    lea rsi, [rip + pub_json]
    mov rdx, [rip + pub_json_length]
    call r2_write_file
    lea rax, [rip + r2p_manifest_path]
    mov [rip + r2_manifest], rax
    mov byte ptr [rip + r2p_owned], 1
    mov rdi, [rip + r2p_repo_fd]
    call arc_close
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Compare selected physical directory identity with the credential parent's
 * ancestors before Git reads. Case aliases do not bypass device/inode checks.
 * Missing physical subtrees are allowed: committed Git objects remain usable.
 * Input path components never follow links; only fixed internal '..' ascends.
 * Stack72, at most4096 ancestor steps; no credential file bytes are read. */
r2p_credential_location:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov eax, 72
    mov rdi, [rip + r2p_repo_fd]
    mov esi, 1030
    mov edx, 3
    syscall
    test rax, rax
    js r2p_bad
    mov r12, rax
    mov rsi, [rip + r2p_source_path]
    cmp word ptr [rsi], 0x002e
    je .Lr2p_selected_directory
    lea rdi, [rip + r2p_subtree_walk]
    call copy_string
    lea rbx, [rip + r2p_subtree_walk]
.Lr2p_subtree_component:
    mov r13, rbx
.Lr2p_subtree_component_end:
    cmp byte ptr [r13], 0
    je .Lr2p_subtree_component_open
    cmp byte ptr [r13], '/'
    je .Lr2p_subtree_component_open
    inc r13
    jmp .Lr2p_subtree_component_end
.Lr2p_subtree_component_open:
    movzx r14d, byte ptr [r13]
    mov byte ptr [r13], 0
    mov eax, 257
    mov rdi, r12
    mov rsi, rbx
    mov edx, O_CLOEXEC + O_NOFOLLOW + O_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    jns .Lr2p_subtree_component_ready
    cmp rax, -2
    je .Lr2p_no_physical_subtree
    cmp rax, -20
    je .Lr2p_no_physical_subtree
    cmp rax, -40
    je .Lr2p_no_physical_subtree
    jmp r2p_bad
.Lr2p_subtree_component_ready:
    mov r15, rax
    mov rdi, r12
    call arc_close
    mov r12, r15
    test r14d, r14d
    jz .Lr2p_selected_directory
    lea rbx, [r13 + 1]
    jmp .Lr2p_subtree_component
.Lr2p_selected_directory:
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2p_bad
    mov r13, [rip + r2_stat]
    mov r14, [rip + r2_stat + 8]
    mov rdi, r12
    call arc_close
    lea rdi, [rip + r2p_credential_parent]
    mov rsi, [rip + r2_credential]
    call copy_string
    lea rdi, [rip + r2p_credential_parent]
    xor ebx, ebx
    xor ecx, ecx
.Lr2p_credential_last_slash:
    mov al, [rdi + rcx]
    test al, al
    jz .Lr2p_credential_parent_path
    cmp al, '/'
    jne .Lr2p_credential_slash_next
    lea rbx, [rdi + rcx]
.Lr2p_credential_slash_next:
    inc ecx
    jmp .Lr2p_credential_last_slash
.Lr2p_credential_parent_path:
    test rbx, rbx
    jnz .Lr2p_credential_parent_cut
    lea rdi, [rip + r2_cwd]
    jmp .Lr2p_credential_parent_open
.Lr2p_credential_parent_cut:
    cmp rbx, rdi
    jne .Lr2p_credential_parent_terminate
    mov eax, 2
    lea rdi, [rip + self_root]
    mov esi, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    xor edx, edx
    syscall
    test rax, rax
    js r2p_bad
    mov r15, rax
    jmp .Lr2p_credential_ancestors
.Lr2p_credential_parent_terminate:
    mov byte ptr [rbx], 0
.Lr2p_credential_parent_open:
    mov esi, 1
    xor edx, edx
    call r2_open_path
    mov r15, rax
.Lr2p_credential_ancestors:
    xor ebp, ebp
.Lr2p_credential_ancestor:
    inc ebp
    cmp ebp, 4096
    ja r2p_bad
    mov eax, 5
    mov rdi, r15
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2p_bad
    mov rax, [rip + r2_stat]
    cmp rax, r13
    jne .Lr2p_credential_parent_next
    mov rax, [rip + r2_stat + 8]
    cmp rax, r14
    je .Lr2p_credential_inside
.Lr2p_credential_parent_next:
    mov rax, [rip + r2_stat]
    mov [rsp], rax
    mov rax, [rip + r2_stat + 8]
    mov [rsp + 8], rax
    mov eax, 257
    mov rdi, r15
    lea rsi, [rip + r2p_parent]
    mov edx, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    xor r10d, r10d
    syscall
    test rax, rax
    js r2p_bad
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2p_bad
    mov rdi, r15
    call arc_close
    mov r15, r12
    mov rax, [rip + r2_stat]
    cmp rax, [rsp]
    jne .Lr2p_credential_ancestor
    mov rax, [rip + r2_stat + 8]
    cmp rax, [rsp + 8]
    jne .Lr2p_credential_ancestor
    mov rdi, r15
    call arc_close
    jmp .Lr2p_credential_location_ok
.Lr2p_credential_inside:
    lea rdi, [rip + r2p_error_credential]
    mov esi, 1
    jmp registry_fail
.Lr2p_no_physical_subtree:
    mov rdi, r12
    call arc_close
.Lr2p_credential_location_ok:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Read only protected credential metadata. Call after source checks, before
 * executable snapshots. No credential byte enters package state. Stack8. */
r2p_credential_identity:
    sub rsp, 8
    mov rdi, [rip + r2_credential]
    xor esi, esi
    mov edx, 1
    call r2_open_path
    mov rdi, rax
    mov rax, [rip + r2_stat]
    mov [rip + r2p_credential_dev], rax
    mov rax, [rip + r2_stat + 8]
    mov [rip + r2p_credential_ino], rax
    call arc_close
    add rsp, 8
    ret

/* r2_stat describes an opened candidate, before its first byte read. */
r2p_refuse_credential_object:
    mov rax, [rip + r2_stat]
    cmp rax, [rip + r2p_credential_dev]
    jne .Lr2p_not_credential_object
    mov rax, [rip + r2_stat + 8]
    cmp rax, [rip + r2p_credential_ino]
    jne .Lr2p_not_credential_object
    lea rdi, [rip + r2p_error_credential_object]
    mov esi, 1
    jmp registry_fail
.Lr2p_not_credential_object:
    ret

/* RDI=portable candidate path. EAX=1 keep/0 excluded; sensitive names fail.
 * Same six directory exclusions as committed registry packing. Stack40. */
r2p_allowed:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    call r2p_is_excluded
    test eax, eax
    jnz .Lr2p_excluded
    mov rdi, r12
    call pub_portable_path
    test eax, eax
    jnz r2p_bad
    mov r13, r12
.Lr2p_component:
    lea rdi, [rip + pub_component]
    xor ebx, ebx
.Lr2p_component_copy:
    mov al, [r13]
    test al, al
    jz .Lr2p_component_check
    cmp al, '/'
    je .Lr2p_component_check
    mov [rdi + rbx], al
    inc ebx
    inc r13
    jmp .Lr2p_component_copy
.Lr2p_component_check:
    mov byte ptr [rdi + rbx], 0
    lea rsi, [rip + r2p_excluded]
    call pub_in_strings
    test eax, eax
    jnz .Lr2p_excluded
    lea rdi, [rip + pub_component]
    lea rsi, [rip + pub_excluded]
    call pub_in_strings
    test eax, eax
    jnz r2p_bad
    cmp dword ptr [rip + pub_component], 0x766e652e
    jne .Lr2p_component_next
    cmp byte ptr [rip + pub_component + 4], '.'
    je r2p_bad
.Lr2p_component_next:
    cmp byte ptr [r13], 0
    je .Lr2p_extension
    inc r13
    jmp .Lr2p_component
.Lr2p_extension:
    mov rdi, r12
    call strlen
    cmp rax, 4
    jb .Lr2p_allowed_yes
    mov eax, [r12 + rax - 4]
    or eax, 0x20202000
    cmp eax, 0x79656b2e
    je r2p_bad
    cmp eax, 0x6d65702e
    je r2p_bad
.Lr2p_allowed_yes:
    mov eax, 1
    jmp .Lr2p_allowed_done
.Lr2p_excluded:
    xor eax, eax
.Lr2p_allowed_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=borrowed NUL path inside the bounded Git list. EAX=1 iff any complete
 * component is an excluded cache directory. Run before portability/sensitive
 * checks, matching the existing committed-source collector's precedence.
 * No component above11 bytes needs copying. Stack40. */
r2p_is_excluded:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
.Lr2p_exclusion_component:
    mov r13, r12
.Lr2p_exclusion_end:
    cmp byte ptr [r13], 0
    je .Lr2p_exclusion_check
    cmp byte ptr [r13], '/'
    je .Lr2p_exclusion_check
    inc r13
    jmp .Lr2p_exclusion_end
.Lr2p_exclusion_check:
    mov rcx, r13
    sub rcx, r12
    cmp rcx, 11
    ja .Lr2p_exclusion_next
    lea rdi, [rip + pub_component]
    mov rsi, r12
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + pub_component]
    lea rsi, [rip + r2p_excluded]
    call pub_in_strings
    test eax, eax
    jnz .Lr2p_exclusion_found
.Lr2p_exclusion_next:
    cmp byte ptr [r13], 0
    je .Lr2p_exclusion_absent
    lea r12, [r13 + 1]
    jmp .Lr2p_exclusion_component
.Lr2p_exclusion_found:
    mov eax, 1
    jmp .Lr2p_exclusion_done
.Lr2p_exclusion_absent:
    xor eax, eax
.Lr2p_exclusion_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Parse canonical unsigned decimal in [RDI,RSI), permitting zero. RAX=value,
 * RDI=first non-digit. Cap RDX is checked before each multiply. No stack. */
r2p_decimal:
    xor eax, eax
    xor r8d, r8d
.Lr2p_decimal_loop:
    cmp rdi, rsi
    jae .Lr2p_decimal_done
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lr2p_decimal_done
    imul rax, rax, 10
    add rax, rcx
    cmp rax, rdx
    ja r2p_bad
    inc r8d
    inc rdi
    cmp r8d, 20
    ja r2p_bad
    jmp .Lr2p_decimal_loop
.Lr2p_decimal_done:
    test r8d, r8d
    jz r2p_bad
    ret

/* Read the bounded ls-tree list. Records borrow paths/OIDs in that list.
 * Reject before object reads if headers+padding+end exceed64MiB. Stack56. */
r2p_collect:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    lea r12, [rip + r2p_tree_data]
    mov qword ptr [rip + r2p_tar_bytes], 1024
    lea rdi, [rip + r2p_request_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_create
    mov r15, rax
.Lr2p_tree_entry:
    cmp r12, [rip + r2p_tree_end]
    jae .Lr2p_collected
    mov r13, r12
.Lr2p_tree_tab:
    cmp r13, [rip + r2p_tree_end]
    jae r2p_bad
    cmp byte ptr [r13], 9
    je .Lr2p_tree_path
    cmp byte ptr [r13], 0
    je r2p_bad
    inc r13
    jmp .Lr2p_tree_tab
.Lr2p_tree_path:
    lea rbp, [r13 + 1]
    mov r14, rbp
.Lr2p_tree_end:
    cmp r14, [rip + r2p_tree_end]
    jae r2p_bad
    cmp byte ptr [r14], 0
    je .Lr2p_tree_subtree
    inc r14
    jmp .Lr2p_tree_end
.Lr2p_tree_subtree:
    lea rsi, [rip + r2_source_path]
    cmp word ptr [rsi], 0x002e
    je .Lr2p_tree_relative
    xor ecx, ecx
.Lr2p_subtree_prefix:
    mov al, [rsi + rcx]
    test al, al
    jz .Lr2p_subtree_slash
    cmp al, [rbp + rcx]
    jne r2p_bad
    inc ecx
    jmp .Lr2p_subtree_prefix
.Lr2p_subtree_slash:
    cmp byte ptr [rbp + rcx], '/'
    jne r2p_bad
    lea rbp, [rbp + rcx + 1]
.Lr2p_tree_relative:
    mov rdi, rbp
    call r2p_allowed
    test eax, eax
    jz .Lr2p_tree_next
    mov rdi, rbp
    lea rsi, [rip + r2p_lock_name]
    call streq
    test eax, eax
    jnz r2p_lock_error
    mov ebx, 420
    cmp dword ptr [r12], 0x36303031 /*1006*/
    jne .Lr2p_tree_executable
    cmp word ptr [r12 + 4], 0x3434
    je .Lr2p_tree_mode_ok
.Lr2p_tree_executable:
    cmp dword ptr [r12], 0x37303031 /*1007*/
    jne r2p_bad
    cmp word ptr [r12 + 4], 0x3535
    jne r2p_bad
    mov ebx, 493
.Lr2p_tree_mode_ok:
    cmp byte ptr [r12 + 6], ' '
    jne r2p_bad
    cmp dword ptr [r12 + 7], 0x626f6c62
    jne r2p_bad
    cmp byte ptr [r12 + 11], ' '
    jne r2p_bad
    lea rdi, [r12 + 12]
    mov rcx, [rip + r2p_oid_length]
    lea rax, [rdi + rcx]
    cmp rax, r13
    jae r2p_bad
    cmp byte ptr [rax], ' '
    jne r2p_bad
    mov byte ptr [rax], 0
    mov esi, ecx
    call r2_hex
    test eax, eax
    jz r2p_bad
    lea rdi, [r12 + 12]
    add rdi, [rip + r2p_oid_length]
    inc rdi
.Lr2p_tree_spaces:
    cmp rdi, r13
    jae r2p_bad
    cmp byte ptr [rdi], ' '
    jne .Lr2p_tree_size
    inc rdi
    jmp .Lr2p_tree_spaces
.Lr2p_tree_size:
    mov rsi, r13
    mov edx, ARC_FILE_LIMIT
    call r2p_decimal
    cmp rdi, r13
    jne r2p_bad
    mov rdx, rax
    add rax, 511
    and rax, -512
    add rax, 512
    add rax, [rip + r2p_tar_bytes]
    cmp rax, ARC_LIMIT
    ja r2p_bad
    mov [rip + r2p_tar_bytes], rax
    mov rcx, [rip + r2p_count]
    cmp rcx, R2P_FILES
    jae r2p_bad
    shl rcx, 5
    lea rdi, [rip + r2p_records]
    add rdi, rcx
    mov [rdi], rbp
    lea rax, [r12 + 12]
    mov [rdi + 8], rax
    mov [rdi + 16], rdx
    mov [rdi + 24], rbx
    inc qword ptr [rip + r2p_count]
    mov rdi, r15
    lea rsi, [r12 + 12]
    mov rdx, [rip + r2p_oid_length]
    call write_all
    test rax, rax
    js r2p_bad
    mov rdi, r15
    lea rsi, [rip + r2p_lf]
    mov edx, 1
    call write_all
    test rax, rax
    js r2p_bad
.Lr2p_tree_next:
    lea r12, [r14 + 1]
    jmp .Lr2p_tree_entry
.Lr2p_collected:
    cmp qword ptr [rip + r2p_count], 0
    je r2p_bad
    mov rdi, r15
    call arc_close
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=field, ECX=width including NUL, RAX=unsigned value. Writes fixed-width
 * zero-padded octal. A value outside the field fails. Scratch RAX/RCX/RDX/R8. */
r2p_octal:
    lea r8, [rdi + rcx - 1]
    mov byte ptr [r8], 0
.Lr2p_octal_digit:
    dec r8
    mov edx, eax
    and edx, 7
    add dl, '0'
    mov [r8], dl
    shr rax, 3
    cmp r8, rdi
    ja .Lr2p_octal_digit
    test rax, rax
    jnz r2p_bad
    ret

/* RDI=borrowed record. Output r2p_header[512]. USTAR path split never truncates:
 * name<=100, prefix<=155. Header ownership/time zero, regular normalized mode.
 * Stack40. Header and padding contribute to the previously checked TAR budget. */
r2p_tar_header:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    mov r13, [r12]
    lea rdi, [rip + r2p_header]
    xor eax, eax
    mov ecx, 512
    rep stosb
    mov rdi, r13
    call strlen
    mov r14, rax
    xor ebx, ebx
    cmp r14, 100
    jbe .Lr2p_tar_name
    xor ecx, ecx
.Lr2p_tar_split:
    cmp rcx, r14
    jae r2p_bad
    cmp ecx, 155
    ja r2p_bad
    cmp byte ptr [r13 + rcx], '/'
    jne .Lr2p_tar_split_next
    mov rax, r14
    sub rax, rcx
    dec rax
    cmp rax, 100
    ja .Lr2p_tar_split_next
    mov rbx, rcx
    lea rdi, [rip + r2p_header + 345]
    mov rsi, r13
    rep movsb
    inc rbx
    jmp .Lr2p_tar_name
.Lr2p_tar_split_next:
    inc ecx
    jmp .Lr2p_tar_split
.Lr2p_tar_name:
    lea rdi, [rip + r2p_header]
    lea rsi, [r13 + rbx]
    mov rcx, r14
    sub rcx, rbx
    rep movsb
    lea rdi, [rip + r2p_header + 100]
    mov ecx, 8
    mov rax, [r12 + 24]
    call r2p_octal
    lea rdi, [rip + r2p_header + 108]
    mov ecx, 8
    xor eax, eax
    call r2p_octal
    lea rdi, [rip + r2p_header + 116]
    mov ecx, 8
    xor eax, eax
    call r2p_octal
    lea rdi, [rip + r2p_header + 124]
    mov ecx, 12
    mov rax, [r12 + 16]
    call r2p_octal
    lea rdi, [rip + r2p_header + 136]
    mov ecx, 12
    xor eax, eax
    call r2p_octal
    mov rax, 0x2020202020202020
    mov qword ptr [rip + r2p_header + 148], rax
    mov byte ptr [rip + r2p_header + 156], '0'
    mov dword ptr [rip + r2p_header + 257], 0x61747375
    mov word ptr [rip + r2p_header + 261], 0x0072
    mov word ptr [rip + r2p_header + 263], 0x3030
    xor eax, eax
    xor ecx, ecx
    lea rdi, [rip + r2p_header]
.Lr2p_tar_checksum:
    movzx edx, byte ptr [rdi + rcx]
    add eax, edx
    inc ecx
    cmp ecx, 512
    jb .Lr2p_tar_checksum
    lea rdi, [rip + r2p_header + 148]
    mov ecx, 7
    call r2p_octal
    mov byte ptr [rip + r2p_header + 155], 32
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* One unbuffered cat-file process reads only selected OIDs from an owned file.
 * Its regular output has a kernel cap. Native code checks every response header
 * and byte count while writing USTAR; no Git archive attributes or filters run.
 * Stack56; mapping is unmapped before gzip/validation. */
r2p_archive:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    lea rdi, [rip + r2p_request_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_open
    mov r12, rax
    lea rdi, [rip + r2p_batch_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_create
    mov r13, rax
    lea rdi, [rip + r2p_git]
    lea rsi, [rip + r2p_batch_argv]
    mov rdx, r12
    mov rcx, r13
    mov r8d, R2P_BATCH
    call r2p_run
    mov rdi, r12
    call arc_close
    mov rdi, r13
    call arc_close
    lea rdi, [rip + r2p_batch_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_open
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2p_bad
    mov rsi, [rip + r2_stat + 48]
    test rsi, rsi
    jle r2p_bad
    cmp rsi, R2P_BATCH
    ja r2p_bad
    mov [rip + r2p_batch_length], rsi
    mov eax, 9
    xor edi, edi
    mov edx, 1
    mov r10d, 2
    mov r8, r12
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae r2p_bad
    mov [rip + r2p_batch_base], rax
    mov [rip + r2p_cursor], rax
    add rax, [rip + r2p_batch_length]
    mov [rip + r2p_batch_end], rax
    mov rdi, r12
    call arc_close
    lea rdi, [rip + r2p_tar_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_create
    mov r15, rax
    xor ebx, ebx
.Lr2p_tar_entry:
    cmp rbx, [rip + r2p_count]
    jae .Lr2p_tar_end
    mov rax, rbx
    shl rax, 5
    lea r12, [rip + r2p_records]
    add r12, rax
    mov r13, [rip + r2p_cursor]
    mov r14, r13
    add r14, [rip + r2p_oid_length]
    add r14, 7
    cmp r14, [rip + r2p_batch_end]
    jae r2p_bad
    mov rsi, [r12 + 8]
    mov rcx, [rip + r2p_oid_length]
    mov rdi, r13
    repe cmpsb
    jne r2p_bad
    cmp dword ptr [rdi], 0x6f6c6220 /* space blo */
    jne r2p_bad
    cmp word ptr [rdi + 4], 0x2062 /* b space */
    jne r2p_bad
    add rdi, 6
    mov rsi, [rip + r2p_batch_end]
    mov edx, ARC_FILE_LIMIT
    call r2p_decimal
    cmp rax, [r12 + 16]
    jne r2p_bad
    cmp byte ptr [rdi], 10
    jne r2p_bad
    lea r13, [rdi + 1]
    lea r14, [r13 + rax]
    cmp r14, [rip + r2p_batch_end]
    jae r2p_bad
    cmp byte ptr [r14], 10
    jne r2p_bad
    lea rax, [r14 + 1]
    mov [rip + r2p_cursor], rax
    mov rdi, r12
    call r2p_tar_header
    mov rdi, r15
    lea rsi, [rip + r2p_header]
    mov edx, 512
    call write_all
    test rax, rax
    js r2p_bad
    mov rdi, r15
    mov rsi, r13
    mov rdx, [r12 + 16]
    call write_all
    test rax, rax
    js r2p_bad
    mov rdx, [r12 + 16]
    neg rdx
    and edx, 511
    mov rdi, r15
    lea rsi, [rip + r2p_zeroes]
    call write_all
    test rax, rax
    js r2p_bad
    inc ebx
    jmp .Lr2p_tar_entry
.Lr2p_tar_end:
    mov rax, [rip + r2p_cursor]
    cmp rax, [rip + r2p_batch_end]
    jne r2p_bad
    mov rdi, r15
    lea rsi, [rip + r2p_zeroes]
    mov edx, 1024
    call write_all
    test rax, rax
    js r2p_bad
    mov rdi, r15
    call arc_close
    mov eax, 11
    mov rdi, [rip + r2p_batch_base]
    mov rsi, [rip + r2p_batch_length]
    syscall
    test rax, rax
    js r2p_bad
    mov qword ptr [rip + r2p_batch_base], 0
    lea rdi, [rip + r2p_batch_suffix]
    call r2p_path_for
    mov rdi, rax
    mov eax, 87
    syscall
    lea rdi, [rip + r2p_request_suffix]
    call r2p_path_for
    mov rdi, rax
    mov eax, 87
    syscall
    lea rdi, [rip + r2p_tar_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_open
    mov r12, rax
    lea rdi, [rip + r2p_archive_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_create
    mov r13, rax
    lea rdi, [rip + r2p_gzip]
    lea rsi, [rip + r2p_gzip_argv]
    mov rdx, r12
    mov rcx, r13
    mov r8d, ARC_LIMIT
    call r2p_run
    mov rdi, r12
    call arc_close
    mov rdi, r13
    call arc_close
    lea rdi, [rip + r2p_tar_suffix]
    call r2p_path_for
    mov rdi, rax
    mov eax, 87
    syscall
    lea rdi, [rip + r2p_archive_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_retain_object
    mov rax, [rax + 72]
    mov [rip + r2_source_bytes], rax
    lea rdi, [rip + r2_source_sha]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=owned private candidate path. RAX=shared digest record after no-replace
 * finalization; pub_hash_buffer holds its digest. Existing equal bytes may be
 * reused, never replaced. Stack40; bounds1..64MiB and task128MiB. */
r2p_retain_object:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    call r2p_open
    mov r13, rax
    mov eax, 5
    mov rdi, r13
    lea rsi, [rip + r2_stat]
    syscall
    test rax, rax
    js r2p_bad
    mov eax, [rip + r2_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne r2p_bad
    cmp qword ptr [rip + r2_stat + 16], 1
    jne r2p_bad
    mov r14, [rip + r2_stat + 48]
    test r14, r14
    jle r2p_bad
    cmp r14, ARC_LIMIT
    ja r2p_bad
    mov rdi, r13
    call arc_close
    mov rdi, r12
    call r2_hash_path
    lea rdi, [rip + pub_hash_buffer]
    mov rsi, r14
    call r2_add_object
    mov rbx, rax
    mov rdi, rbx
    call r2_object_stage_path
    mov eax, 316
    mov rdi, -100
    mov rsi, r12
    mov rdx, -100
    lea r10, [rip + r2_object_path]
    mov r8d, 1
    syscall
    test rax, rax
    jns .Lr2p_retained
    cmp rax, -17
    jne r2p_bad
    lea rdi, [rip + r2_object_path]
    call r2_hash_path
    lea rdi, [rip + pub_hash_buffer]
    mov rsi, rbx
    call streq
    test eax, eax
    jz r2p_bad
    mov eax, 87
    mov rdi, r12
    syscall
    test rax, rax
    js r2p_bad
.Lr2p_retained:
    mov rax, rbx
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Snapshot explicit executable inputs without building or executing them.
 * Records use the common SHA/length/task bounds. Stack56; copy buffer64KiB. */
r2p_executables:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    xor ebx, ebx
.Lr2p_executable:
    cmp ebx, 6
    jae .Lr2p_executables_done
    lea rax, [rip + r2p_executable_paths]
    mov rdi, [rax + rbx*8]
    test rdi, rdi
    jz .Lr2p_executable_next
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov r12, rax
    call r2p_refuse_credential_object
    mov r14, [rip + r2_stat + 48]
    test r14, r14
    jle r2p_bad
    cmp r14, ARC_LIMIT
    ja r2p_bad
    lea rdi, [rip + r2p_candidate_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_create
    mov r13, rax
    xor r15d, r15d
.Lr2p_executable_read:
    xor eax, eax
    mov rdi, r12
    lea rsi, [rip + registry_copy_buffer]
    mov edx, 65536
    syscall
    cmp rax, -4
    je .Lr2p_executable_read
    test rax, rax
    js r2p_bad
    jz .Lr2p_executable_copied
    add r15, rax
    cmp r15, r14
    ja r2p_bad
    mov rdx, rax
    mov rdi, r13
    lea rsi, [rip + registry_copy_buffer]
    call write_all
    test rax, rax
    js r2p_bad
    jmp .Lr2p_executable_read
.Lr2p_executable_copied:
    cmp r15, r14
    jne r2p_bad
    mov rdi, r12
    call arc_close
    mov rdi, r13
    call arc_close
    lea rdi, [rip + r2p_candidate_suffix]
    call r2p_path_for
    mov rdi, rax
    call r2p_retain_object
    lea rdx, [rip + r2p_executable_records]
    mov [rdx + rbx*8], rax
.Lr2p_executable_next:
    inc ebx
    jmp .Lr2p_executable
.Lr2p_executables_done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

.macro R2P_APPEND text
    lea rdi, [rip + \text]
    call pub_append
.endm
.macro R2P_QUOTE text
    lea rdi, [rip + \text]
    call pub_quote
.endm
/* RDI=unsigned value; append one canonical decimal to the16KiB JSON buffer. */
r2p_number:
    sub rsp, 8
    lea rsi, [rip + pub_number + 31]
    call unsigned_decimal
    mov rdi, rax
    call pub_append
    add rsp, 8
    ret

/* EAX=1 for metadata requiring expanded dependency objects. Preserve simple
 * source request bytes for replay across CLI upgrades. Stack:none. */
g4_project_complex:
    cmp qword ptr [rip + g4_project_profile + 16], 0
    jne .Lg4_complex_yes
    xor ecx, ecx
    lea rdx, [rip + g4_project_profile + G4_OPTIONS]
.Lg4_complex_option:
    cmp rcx, [rip + g3_project_dep_count]
    jae .Lg4_complex_no
    cmp qword ptr [rdx], 2
    jne .Lg4_complex_yes
    cmp qword ptr [rdx + 16], 0
    jne .Lg4_complex_yes
    add rdx, 24
    inc rcx
    jmp .Lg4_complex_option
.Lg4_complex_yes:
    mov eax, 1
    ret
.Lg4_complex_no:
    xor eax, eax
    ret

/* RDI=boolean0/1. Append a JSON literal to the bounded native writer. */
g4_emit_bool:
    lea rax, [rip + g4_false]
    test rdi, rdi
    jz .Lg4_emit_bool_append
    lea rax, [rip + g4_true]
.Lg4_emit_bool_append:
    mov rdi, rax
    jmp pub_append

/* RDI=NUL-separated list,RSI=count0..64. Append a canonical array used in
 * six-space-indented object fields. Nonempty members use eight spaces.
 * Owns no input; strings were bounded and sorted before credential access.
 * Callee registers preserved. Stack24 plus bounded writer calls. */
g4_emit_array:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz .Lg4_emit_array_empty
    R2P_APPEND g4_json_array_open
    xor ebx, ebx
.Lg4_emit_array_item:
    test ebx, ebx
    jz .Lg4_emit_array_first
    R2P_APPEND g4_json_array_comma
.Lg4_emit_array_first:
    R2P_APPEND g4_json_array_indent
    mov rdi, r12
    call pub_quote
    mov rdi, r12
    call strlen
    lea r12, [r12 + rax + 1]
    inc rbx
    cmp rbx, r13
    jb .Lg4_emit_array_item
    R2P_APPEND g4_json_array_close
    jmp .Lg4_emit_array_return
.Lg4_emit_array_empty:
    R2P_APPEND g4_json_array_empty
.Lg4_emit_array_return:
    pop r13
    pop r12
    pop rbx
    ret

/* Build the exact sorted-key, two-space canonical publication JSON from owned
 * metadata. Arrays use stable tuple/kind order independent of option order.
 * Max12 selections and source metadata use the bounded64KiB V2 writer. Stack56. */
r2p_json:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov qword ptr [rip + pub_json_length], 0
    R2P_APPEND r2p_json_start
    xor ebx, ebx
    xor r15d, r15d
.Lr2p_json_selection:
    cmp ebx, 12
    jae .Lr2p_json_metadata
    bt [rip + r2p_selections], rbx
    jnc .Lr2p_json_next
    test r15d, r15d
    jz .Lr2p_json_first
    R2P_APPEND r2p_json_comma_lf
.Lr2p_json_first:
    inc r15d
    mov eax, ebx
    shr eax, 1
    imul rax, rax, 40
    lea r12, [rip + r2_tuples]
    add r12, rax
    lea r13, [rip + r2_source_sha]
    mov r14, [rip + r2_source_bytes]
    test ebx, 1
    jz .Lr2p_json_artifact
    mov eax, ebx
    shr eax, 1
    lea rdx, [rip + r2p_executable_records]
    mov r13, [rdx + rax*8]
    mov r14, [r13 + 72]
.Lr2p_json_artifact:
    R2P_APPEND r2p_json_abi
    mov rdi, [r12 + 24]
    call pub_quote
    R2P_APPEND r2p_json_bytes
    mov rdi, r14
    call r2p_number
    R2P_APPEND r2p_json_features
    mov rdi, [r12 + 32]
    test ebx, 1
    jnz .Lr2p_json_format
    lea rdi, [rip + r2_tar_gzip]
.Lr2p_json_format:
    call pub_quote
    R2P_APPEND r2p_json_isa
    mov rdi, [r12 + 8]
    call pub_quote
    R2P_APPEND r2p_json_kind
    lea rdi, [rip + registry_source_kind]
    test ebx, 1
    jz .Lr2p_json_kind_value
    lea rdi, [rip + registry_executable_kind]
.Lr2p_json_kind_value:
    call pub_quote
    R2P_APPEND r2p_json_os
    mov rdi, [r12 + 16]
    call pub_quote
    R2P_APPEND r2p_json_sha
    mov rdi, r13
    call pub_quote
    R2P_APPEND r2p_json_artifact_end
.Lr2p_json_next:
    inc ebx
    jmp .Lr2p_json_selection
.Lr2p_json_metadata:
    call g4_project_complex
    mov r14d, eax
    cmp qword ptr [rip + g3_project_dep_count], 0
    je .Lr2p_json_definitions
    R2P_APPEND r2p_json_dependencies
    lea r12, [rip + g3_project_deps]
    lea r13, [rip + g4_project_profile + G4_OPTIONS]
    xor ebx, ebx
.Lr2p_json_dependency:
    test ebx, ebx
    jz .Lr2p_json_dependency_first
    R2P_APPEND r2p_json_comma_lf
.Lr2p_json_dependency_first:
    test r14d, r14d
    jz .Lr2p_json_simple_dependency
    R2P_APPEND g4_json_dep_begin
    mov rdi, [r13]
    shr rdi, 1
    and edi, 1
    call g4_emit_bool
    R2P_APPEND g4_json_dep_features
    mov rdi, [r13 + 8]
    mov rsi, [r13 + 16]
    call g4_emit_array
    R2P_APPEND g4_json_dep_name
    mov rdi, r12
    call pub_quote
    R2P_APPEND g4_json_dep_optional
    mov rdi, [r13]
    and edi, 1
    call g4_emit_bool
    jmp .Lr2p_json_dependency_range
.Lr2p_json_simple_dependency:
    R2P_APPEND r2p_json_dependency_name
    mov rdi, r12
    call pub_quote
.Lr2p_json_dependency_range:
    R2P_APPEND r2p_json_requirement
    lea rdi, [r12 + 105]
    call pub_quote
    R2P_APPEND r2p_json_artifact_end
    add r12, 240
    add r13, 24
    inc ebx
    cmp rbx, [rip + g3_project_dep_count]
    jb .Lr2p_json_dependency
.Lr2p_json_definitions:
    cmp qword ptr [rip + g4_project_profile + 16], 0
    je .Lr2p_json_license
    R2P_APPEND g4_json_definitions
    lea r12, [rip + g4_project_profile + G4_DEFINITIONS]
    xor ebx, ebx
.Lr2p_json_definition:
    test ebx, ebx
    jz .Lr2p_json_definition_first
    R2P_APPEND r2p_json_comma_lf
.Lr2p_json_definition_first:
    R2P_APPEND g4_json_def_members
    mov rdi, [r12 + 8]
    mov rsi, [r12 + 16]
    call g4_emit_array
    R2P_APPEND g4_json_def_name
    mov rdi, [r12]
    call pub_quote
    R2P_APPEND r2p_json_artifact_end
    add r12, 24
    inc ebx
    cmp rbx, [rip + g4_project_profile + 16]
    jb .Lr2p_json_definition
.Lr2p_json_license:
    R2P_APPEND r2p_json_license
    R2P_QUOTE r2_license
    R2P_APPEND r2p_json_name
    R2P_QUOTE r2_name
    R2P_APPEND r2p_json_owner
    R2P_QUOTE r2_owner_id
    R2P_APPEND r2p_json_archive
    mov rdi, [rip + r2_source_bytes]
    call r2p_number
    R2P_APPEND r2p_json_archive_sha
    R2P_QUOTE r2_source_sha
    R2P_APPEND r2p_json_algorithm
    mov rdi, [rip + r2p_algorithm]
    call pub_quote
    R2P_APPEND r2p_json_commit
    R2P_QUOTE r2_commit
    R2P_APPEND r2p_json_path
    R2P_QUOTE r2_source_path
    mov rdi, [rip + r2p_repository]
    test rdi, rdi
    jz .Lr2p_json_summary
    R2P_APPEND r2p_json_repository
    mov rdi, [rip + r2p_repository]
    call pub_quote
.Lr2p_json_summary:
    R2P_APPEND r2p_json_summary
    R2P_QUOTE r2_summary
    R2P_APPEND r2p_json_version
    R2P_QUOTE r2_version
    R2P_APPEND r2p_json_end
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Remove only this invocation's fixed private files, including failed candidates.
 * Shared digest objects are cleaned by r2_clean_files. Stack24. */
r2p_cleanup:
    push rbx
    push r12
    sub rsp, 8
    cmp qword ptr [rip + r2p_project], 0
    je .Lr2p_cleanup_done
    mov rdi, [rip + r2p_batch_base]
    test rdi, rdi
    jz .Lr2p_cleanup_files
    mov eax, 11
    mov rsi, [rip + r2p_batch_length]
    syscall
    mov qword ptr [rip + r2p_batch_base], 0
.Lr2p_cleanup_files:
    lea rbx, [rip + r2p_suffixes]
.Lr2p_cleanup_file:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Lr2p_cleanup_done
    call r2p_path_for
    mov rdi, rax
    mov eax, 87
    syscall
    add rbx, 8
    jmp .Lr2p_cleanup_file
.Lr2p_cleanup_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

.section .rodata
r2p_opt_project: .asciz "--project"
r2p_opt_name: .asciz "--name"
r2p_opt_owner: .asciz "--owner-id"
r2p_opt_summary: .asciz "--summary"
r2p_opt_license: .asciz "--license"
r2p_opt_commit: .asciz "--commit"
r2p_opt_path: .asciz "--source-path"
r2p_opt_repository: .asciz "--repository"
r2p_opt_source_target: .asciz "--source-target"
r2p_opt_executable: .asciz "--executable"
r2p_error: .asciz "project publication preparation failed; check committed source, paths, limits and local Git objects"
r2p_error_root: .asciz "project must select the Git repository root; use --source-path for a committed subtree"
r2p_error_lock: .asciz "published project source cannot contain asm.lock; remove the committed consumer lock"
r2p_error_credential: .asciz "project credential is inside the packaged subtree; move it outside the source directory"
r2p_error_credential_object: .asciz "publication object is the credential file; select a separate prepared artifact"
r2p_git: .asciz "/usr/bin/git"
r2p_gzip: .asciz "/usr/bin/gzip"
r2p_git_no_replace: .asciz "--no-replace-objects"
r2p_git_literal: .asciz "--literal-pathspecs"
r2p_git_config: .asciz "-c"
r2p_git_monitor: .asciz "core.fsmonitor=false"
r2p_git_hooks: .asciz "core.hooksPath=/dev/null"
r2p_rev_parse: .asciz "rev-parse"
r2p_prefix: .asciz "--show-prefix"
r2p_verify: .asciz "--verify"
r2p_end_options: .asciz "--end-of-options"
r2p_head: .asciz "HEAD"
r2p_commit_suffix: .asciz "^{commit}"
r2p_ls_tree: .asciz "ls-tree"
r2p_tree_flags: .asciz "-rlz"
r2p_full_tree: .asciz "--full-tree"
r2p_cat_file: .asciz "cat-file"
r2p_batch_option: .asciz "--batch"
r2p_gzip_flags: .asciz "-n9c"
r2p_info_suffix: .asciz "/project.info"
r2p_tree_suffix: .asciz "/project.tree"
r2p_request_suffix: .asciz "/project.requests"
r2p_batch_suffix: .asciz "/project.batch"
r2p_tar_suffix: .asciz "/project.tar"
r2p_archive_suffix: .asciz "/project.archive"
r2p_manifest_suffix: .asciz "/project.json"
r2p_candidate_suffix: .asciz "/project.candidate"
r2p_lock_name: .asciz "asm.lock"
r2p_blob_word: .asciz "blob"
r2p_empty: .asciz ""
r2p_lf: .asciz "\n"
r2p_parent: .asciz ".."
r2p_json_start: .asciz "{\n  \"artifacts\": [\n"
r2p_json_comma_lf: .asciz ",\n"
r2p_json_abi: .asciz "    {\n      \"abi\": "
r2p_json_bytes: .asciz ",\n      \"bytes\": "
r2p_json_features: .asciz ",\n      \"cpu_features\": [],\n      \"format\": "
r2p_json_isa: .asciz ",\n      \"isa\": "
r2p_json_kind: .asciz ",\n      \"kind\": "
r2p_json_os: .asciz ",\n      \"os\": "
r2p_json_sha: .asciz ",\n      \"sha256\": "
r2p_json_artifact_end: .asciz "\n    }"
r2p_json_license: .asciz "\n  ],\n  \"license\": "
r2p_json_dependencies: .asciz "\n  ],\n  \"dependencies\": [\n"
g4_json_dep_begin: .asciz "    {\n      \"default_features\": "
g4_json_dep_features: .asciz ",\n      \"features\": "
g4_json_dep_name: .asciz ",\n      \"name\": "
g4_json_dep_optional: .asciz ",\n      \"optional\": "
g4_json_definitions: .asciz "\n  ],\n  \"features\": [\n"
g4_json_def_members: .asciz "    {\n      \"members\": "
g4_json_def_name: .asciz ",\n      \"name\": "
g4_json_array_open: .asciz "[\n"
g4_json_array_empty: .asciz "[]"
g4_json_array_indent: .asciz "        "
g4_json_array_comma: .asciz ",\n"
g4_json_array_close: .asciz "\n      ]"
r2p_json_dependency_name: .asciz "    {\n      \"name\": "
r2p_json_requirement: .asciz ",\n      \"requirement\": "
r2p_json_name: .asciz ",\n  \"name\": "
r2p_json_owner: .asciz ",\n  \"owner_id\": "
r2p_json_archive: .asciz ",\n  \"schema\": 2,\n  \"source\": {\n    \"archive\": {\n      \"bytes\": "
r2p_json_archive_sha: .asciz ",\n      \"sha256\": "
r2p_json_algorithm: .asciz "\n    },\n    \"commit\": {\n      \"algorithm\": "
r2p_json_commit: .asciz ",\n      \"digest\": "
r2p_json_path: .asciz "\n    },\n    \"path\": "
r2p_json_repository: .asciz ",\n    \"repository\": "
r2p_json_summary: .asciz "\n  },\n  \"summary\": "
r2p_json_version: .asciz ",\n  \"version\": "
r2p_json_end: .asciz "\n}\n"
r2p_env_system: .asciz "GIT_CONFIG_NOSYSTEM=1"
r2p_env_global: .asciz "GIT_CONFIG_GLOBAL=/dev/null"
r2p_env_system_file: .asciz "GIT_CONFIG_SYSTEM=/dev/null"
r2p_env_replace: .asciz "GIT_NO_REPLACE_OBJECTS=1"
r2p_env_lazy: .asciz "GIT_NO_LAZY_FETCH=1"
r2p_env_protocol: .asciz "GIT_ALLOW_PROTOCOL="
r2p_env_locks: .asciz "GIT_OPTIONAL_LOCKS=0"
r2p_env_prompt: .asciz "GIT_TERMINAL_PROMPT=0"
r2p_env_locale: .asciz "LC_ALL=C"
.balign 8
r2p_environment: .quad r2p_env_system,r2p_env_global,r2p_env_system_file,r2p_env_replace,r2p_env_lazy,r2p_env_protocol,r2p_env_locks,r2p_env_prompt,r2p_env_locale,0
r2p_prefix_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_rev_parse,r2p_prefix,0
r2p_commit_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_rev_parse,r2p_verify,r2p_end_options,r2p_commit_spec,0
.section .data
r2p_tree_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_ls_tree,r2p_tree_flags,r2p_full_tree,r2_commit,registry_separator,0,0
.section .rodata
r2p_batch_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_cat_file,r2p_batch_option,0
r2p_gzip_argv: .quad r2p_gzip,r2p_gzip_flags,0
r2p_suffixes: .quad r2p_info_suffix,r2p_tree_suffix,r2p_request_suffix,r2p_batch_suffix,r2p_tar_suffix,r2p_archive_suffix,r2p_manifest_suffix,r2p_candidate_suffix,0
r2p_excluded: .asciz ".git\0.asm\0.venv\0__pycache__\0build\0dist\0"
.section .bss
.balign 8
r2p_project: .skip 8
r2p_name: .skip 8
r2p_owner: .skip 8
r2p_summary: .skip 8
r2p_license: .skip 8
r2p_commit: .skip 8
r2p_source_path: .skip 8
r2p_repository: .skip 8
r2p_selections: .skip 8
r2p_executable_paths: .skip 48
r2p_executable_records: .skip 48
r2p_repo_fd: .skip 8
r2p_limit: .skip 8
r2p_rlimit: .skip 16
r2p_child_status: .skip 8
r2p_path: .skip 160
r2p_manifest_path: .skip 160
r2p_subtree_walk: .skip 241
r2p_credential_parent: .skip 4096
r2p_credential_dev: .skip 8
r2p_credential_ino: .skip 8
r2p_commit_spec: .skip 80
r2p_info: .skip 4097
r2p_oid_length: .skip 8
r2p_algorithm: .skip 8
r2p_tree_data: .skip R2P_LIST + 1
r2p_tree_end: .skip 8
r2p_records: .skip R2P_FILES * R2P_RECORD
r2p_count: .skip 8
r2p_tar_bytes: .skip 8
r2p_batch_base: .skip 8
r2p_batch_length: .skip 8
r2p_batch_end: .skip 8
r2p_cursor: .skip 8
r2p_header: .skip 512
r2p_zeroes: .skip 1024
r2p_owned: .skip 1
