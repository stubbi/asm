/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.intel_syntax noprefix
.global cmd_self, self_update_cleanup

/* Manual updates operate only on HOME/.local/bin/asm. An open directory and
 * nonblocking advisory lock coordinate asm invocations. The directory and
 * executable must belong to the calling UID, without group/other write bits.
 * A same-account process can ignore the lock; this is not a local sandbox.
 * All returning routines preserve SysV callee-saved registers. Command and
 * error labels terminate. Borrowed arguments are kernel-terminated strings.
 */
.section .text
cmd_self:
    call self_current_version
.Lself_arguments:
    call next_arg
    test rax, rax
    jz .Lself_arguments_done
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + opt_help]
    call streq
    test eax, eax
    jnz self_help
    mov rdi, r12
    lea rsi, [rip + opt_json]
    call streq
    test eax, eax
    jnz .Lself_json_option
    mov rdi, r12
    lea rsi, [rip + opt_no_color]
    call streq
    test eax, eax
    jnz .Lself_arguments
    cmp byte ptr [rip + self_has_update], 0
    jne .Lself_version_argument
    mov rdi, r12
    lea rsi, [rip + command_update]
    call streq
    test eax, eax
    jz self_bad_arguments
    mov byte ptr [rip + self_has_update], 1
    jmp .Lself_arguments
.Lself_version_argument:
    cmp qword ptr [rip + registry_exact_version], 0
    jne self_bad_arguments
    mov rdi, r12
    call registry_valid_version
    test eax, eax
    jz self_bad_arguments
    mov [rip + registry_exact_version], r12
    jmp .Lself_arguments
.Lself_json_option:
    mov byte ptr [rip + json_mode], 1
    jmp .Lself_arguments
.Lself_arguments_done:
    cmp byte ptr [rip + self_has_update], 0
    je self_help
    mov rdi, [rip + registry_exact_version]
    test rdi, rdi
    jz .Lself_open
    lea rsi, [rip + self_version]
    call registry_version_compare
    cmp eax, 0
    jl self_downgrade
.Lself_open:
    mov byte ptr [rip + self_active], 1
    call self_open_installation
    mov rdi, [rip + registry_exact_version]
    test rdi, rdi
    jz .Lself_begin
    lea rsi, [rip + self_version]
    call streq
    test eax, eax
.ifndef ASM_TRUSTED_DISTRIBUTION
    jnz self_unchanged
.endif
.Lself_begin:
    call registry_workspace
    mov eax, 257
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + registry_temp_dir]
    mov edx, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    xor r10d, r10d
    syscall
    test rax, rax
    js self_io_error
    mov [rip + self_stage_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + self_stage_stat]
    syscall
    test rax, rax
    js self_io_error
    call self_prepare_verifier
    /* Only bounded standard proxy variables reach transport and hashing.
     * No ambient CA, credential, or tool configuration is inherited. */
    lea rax, [rip + self_network_environment]
    mov [rip + envp], rax
    lea rax, [rip + self_package]
    mov [rip + registry_query], rax
    lea rax, [rip + registry_host]
    mov [rip + registry_target], rax
    lea rax, [rip + registry_executable_kind]
    mov [rip + registry_kind], rax
.ifdef ASM_TRUSTED_DISTRIBUTION
    call self_authenticated_index
.else
    lea rdi, [rip + registry_default_url]
    lea rsi, [rip + registry_temp_index]
    lea rdx, [rip + registry_index_max]
    call registry_download
    test eax, eax
    jnz self_download_error
.endif
    lea rax, [rip + registry_temp_index]
    mov [rip + registry_index_path], rax
    call registry_read_index
    call registry_parse_index
    call registry_select
    test rax, rax
    jz self_not_found
    mov rbx, rax
    mov rdi, [rbx + 8]
    lea rsi, [rip + self_version]
    call registry_version_compare
    cmp eax, 0
    jl self_downgrade
    je self_unchanged
    call self_release_paths
    mov rdi, [rbx + 40]
    lea rsi, [rip + self_asset_url]
    call streq
    test eax, eax
    jz self_release_error
    mov rdi, [rbx + 48]
    call registry_size_value
    mov [rip + registry_expected_size], rax
    mov rdi, [rbx + 40]
    lea rsi, [rip + registry_temp_payload]
    mov rdx, [rbx + 48]
    call registry_download
    test eax, eax
    jnz self_download_error
    call registry_verify_payload
    lea rdi, [rip + registry_temp_payload]
    mov rsi, [rip + registry_expected_size]
    call validate_host_elf
    test eax, eax
    jz registry_install_elf_error
    /* This gate verifies the manifest, its source binding, and the exact
     * payload. It returns only after every required provenance check passes. */
    call self_verify_release
.ifdef ASM_TRUSTED_DISTRIBUTION
    call self_authorize_candidate
.endif
    call self_commit_update
    call self_update_cleanup
    cmp byte ptr [rip + json_mode], 0
    jne .Lself_success_json
    lea rdi, [rip + self_updated_text]
    call out
    mov rbx, [rip + registry_selected]
    mov rdi, [rbx + 8]
    call out
    lea rdi, [rip + self_updated_suffix]
    call out
    jmp exit_ok
.Lself_success_json:
    lea rdi, [rip + self_success_json]
    call out
    mov rbx, [rip + registry_selected]
    mov rdi, [rbx + 8]
    call registry_json_string
    lea rdi, [rip + self_success_suffix]
    call out
    jmp exit_ok

self_unchanged:
    call self_update_cleanup
    lea rdi, [rip + self_unchanged_text]
    lea rsi, [rip + self_unchanged_json]
    call report
    jmp exit_ok
self_help:
    lea rdi, [rip + self_help_text]
    call out
    jmp exit_ok
self_bad_arguments:
    lea rdi, [rip + self_error_arguments]
    mov esi, 2
    jmp self_fail
self_downgrade:
    lea rdi, [rip + self_error_downgrade]
    mov esi, 1
    jmp self_fail
self_installation_error:
    lea rdi, [rip + self_error_installation]
    mov esi, 1
    jmp self_fail
self_permissions_error:
    lea rdi, [rip + self_error_permissions]
    mov esi, 1
    jmp self_fail
self_busy:
    lea rdi, [rip + self_error_busy]
    mov esi, 1
    jmp self_fail
self_changed:
    lea rdi, [rip + self_error_changed]
    mov esi, 1
    jmp self_fail
self_filesystem_error:
    lea rdi, [rip + self_error_filesystem]
    mov esi, 1
    jmp self_fail
self_io_error:
    lea rdi, [rip + self_error_io]
    mov esi, 1
    jmp self_fail
self_download_error:
    lea rdi, [rip + self_error_download]
    mov esi, 1
    jmp self_fail
self_release_error:
    lea rdi, [rip + self_error_release]
    mov esi, 1
    jmp self_fail
self_not_found:
    lea rdi, [rip + self_error_not_found]
    mov esi, 1
    jmp self_fail
self_fail:
    push rdi
    push rsi
    call self_update_cleanup
    pop rsi
    pop rdi
    jmp die

/* Read the trusted version_text prefix. Output: self_version (33 bytes).
 * No duplicated release version constant is introduced. Scratch: caller-save
 * registers; stack 8 alignment bytes. A malformed version fails closed. */
self_current_version:
    sub rsp, 8
    lea rsi, [rip + version_text + 4]
    lea rdi, [rip + self_version]
    xor ecx, ecx
.Lself_current_character:
    cmp ecx, 32
    ja self_bad_arguments
    mov al, [rsi + rcx]
    cmp al, ' '
    je .Lself_current_end
    test al, al
    jz self_bad_arguments
    mov [rdi + rcx], al
    inc ecx
    jmp .Lself_current_character
.Lself_current_end:
    mov byte ptr [rdi + rcx], 0
    call registry_valid_version
    test eax, eax
    jz self_bad_arguments
    add rsp, 8
    ret

/* Open a direct per-user installation. The shared parent walk checks every
 * ancestor, refusing links, empty components, '.' and '..'. HOME and its
 * descendants must belong to the real/effective UID without unsafe writes.
 * Output: held parent/current FDs and a directory flock; cwd becomes parent.
 * Owned path buffers are 4096 bytes. Stack: 40 saved bytes. */
self_open_installation:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, 102
    syscall
    mov [rip + self_uid], eax
    mov r12d, eax
    mov eax, 107
    syscall
    cmp eax, r12d
    jne self_permissions_error
    mov eax, 104
    syscall
    mov r12d, eax
    mov eax, 108
    syscall
    cmp eax, r12d
    jne self_permissions_error
    mov r12, [rip + envp]
.Lself_find_home:
    mov rdi, [r12]
    test rdi, rdi
    jz self_installation_error
    cmp byte ptr [rdi], 'H'
    jne .Lself_next_env
    cmp byte ptr [rdi + 1], 'O'
    jne .Lself_next_env
    cmp byte ptr [rdi + 2], 'M'
    jne .Lself_next_env
    cmp byte ptr [rdi + 3], 'E'
    jne .Lself_next_env
    cmp byte ptr [rdi + 4], '='
    je .Lself_home_found
.Lself_next_env:
    add r12, 8
    jmp .Lself_find_home
.Lself_home_found:
    lea rsi, [rdi + 5]
    cmp byte ptr [rsi], '/'
    jne self_installation_error
    mov rdi, rsi
    mov r12, rsi
    call strlen
    cmp rax, 2
    jb self_installation_error
    cmp rax, 3900
    ja self_installation_error
    cmp byte ptr [r12 + rax - 1], '/'
    je self_installation_error
    mov [rip + self_home_length], rax
    lea rdi, [rip + self_install_path]
    mov rsi, r12
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_install_suffix]
    call copy_string
    /* copy_string returns the terminator. Exclude the constructed /asm. */
    lea rdi, [rip + self_parent_path]
    lea rsi, [rip + self_install_path]
    mov rcx, rax
    sub rcx, rsi
    sub rcx, 4
    rep movsb
    mov byte ptr [rdi], 0
    mov eax, 89
    lea rdi, [rip + self_proc_exe]
    lea rsi, [rip + self_exe_path]
    mov edx, 4095
    syscall
    test rax, rax
    js self_installation_error
    cmp rax, 4095
    jae self_installation_error
    lea rdi, [rip + self_exe_path]
    mov byte ptr [rdi + rax], 0
    lea rsi, [rip + self_install_path]
    call streq
    test eax, eax
    jz self_installation_error
    mov eax, 2
    lea rdi, [rip + self_proc_exe]
    mov esi, O_CLOEXEC + O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js self_installation_error
    mov [rip + self_current_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + self_current_stat]
    syscall
    test rax, rax
    js self_installation_error
    lea rdi, [rip + self_current_stat]
    call self_check_file_stat
    test eax, eax
    jz self_permissions_error
    mov eax, [rip + self_current_stat + 24]
    and eax, 511
    mov [rip + self_file_mode], eax
    call self_open_parent
    cmp rax, -2
    je self_permissions_error
    test rax, rax
    js self_installation_error
    mov [rip + self_parent_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + self_parent_stat]
    syscall
    test rax, rax
    js self_installation_error
    mov eax, 73
    mov rdi, [rip + self_parent_fd]
    mov esi, 6
    syscall
    cmp rax, -11
    je self_busy
    test rax, rax
    js self_filesystem_error
    mov eax, 138
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + self_filesystem_stat]
    syscall
    test rax, rax
    js self_filesystem_error
    mov eax, [rip + self_filesystem_stat]
    cmp eax, 0xef53
    je .Lself_local_filesystem
    cmp eax, 0x58465342
    je .Lself_local_filesystem
    cmp eax, 0x9123683e
    je .Lself_local_filesystem
    cmp eax, 0x01021994
    je .Lself_local_filesystem
    cmp eax, 0x794c7630
    je .Lself_local_filesystem
    cmp eax, 0xf2f52010
    jne self_filesystem_error
.Lself_local_filesystem:
    call self_check_destination
    mov eax, 81
    mov rdi, [rip + self_parent_fd]
    syscall
    test rax, rax
    js self_installation_error
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Open the absolute installation parent from /. Input: bounded, constructed
 * self_install_path and self_home_length. Output: RAX=owned parent FD, -1 for
 * an invalid/inaccessible path, or -2 for unsafe ownership or write access.
 * Every directory, including /, must belong to root or this UID. HOME and
 * its descendants must belong to this UID. No group/other writes are allowed
 * except at exact root-owned sticky /tmp above HOME; its immediate child must
 * belong to this UID and deny group/other writes. An arbitrary sticky path
 * is not an exception. Each open uses O_DIRECTORY|O_NOFOLLOW. The walk does
 * not change cwd or held installation descriptors. It restores temporary NUL
 * separators and closes its FD on failure. Scratch: caller-save, stat buffer;
 * stack: 40 saved bytes. The process is single-threaded. */
self_open_parent:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, 2
    lea rdi, [rip + self_root]
    mov esi, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    xor edx, edx
    syscall
    test rax, rax
    js .Lself_walk_open_error
    mov r15, rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + self_check_stat]
    syscall
    test rax, rax
    js .Lself_walk_bad_permissions
    mov eax, [rip + self_check_stat + 28]
    test eax, eax
    jz .Lself_root_mode
    cmp eax, [rip + self_uid]
    jne .Lself_walk_bad_permissions
.Lself_root_mode:
    test dword ptr [rip + self_check_stat + 24], 18
    jnz .Lself_walk_bad_permissions
    lea r12, [rip + self_install_path]
    lea r13, [r12 + 1]
    xor ebx, ebx
.Lself_walk_component:
    mov r14, r13
.Lself_walk_scan:
    mov al, [r14]
    test al, al
    jz .Lself_walk_complete
    cmp al, '/'
    je .Lself_walk_open
    inc r14
    jmp .Lself_walk_scan
.Lself_walk_open:
    cmp r14, r13
    je .Lself_walk_bad_path
    mov byte ptr [r14], 0
    cmp word ptr [r13], 0x002e
    je .Lself_walk_bad_component
    cmp word ptr [r13], 0x2e2e
    jne .Lself_component_open
    cmp byte ptr [r13 + 2], 0
    je .Lself_walk_bad_component
.Lself_component_open:
    mov eax, 257
    mov rdi, r15
    mov rsi, r13
    mov edx, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    xor r10d, r10d
    syscall
    mov byte ptr [r14], '/'
    test rax, rax
    js .Lself_walk_bad_path
    mov rdi, r15
    mov r15, rax
    mov eax, 3
    syscall
    mov eax, 5
    mov rdi, r15
    lea rsi, [rip + self_check_stat]
    syscall
    test rax, rax
    js .Lself_walk_bad_permissions
    mov rdx, r14
    sub rdx, r12
    mov eax, [rip + self_check_stat + 28]
    test ebx, ebx
    jnz .Lself_component_user
    cmp rdx, [rip + self_home_length]
    jae .Lself_component_user
    test eax, eax
    jz .Lself_component_mode
.Lself_component_user:
    cmp eax, [rip + self_uid]
    jne .Lself_walk_bad_permissions
.Lself_component_mode:
    test dword ptr [rip + self_check_stat + 24], 18
    jz .Lself_component_protected
    test ebx, ebx
    jnz .Lself_walk_bad_permissions
    cmp rdx, [rip + self_home_length]
    jae .Lself_walk_bad_permissions
    cmp edx, 4
    jne .Lself_walk_bad_permissions
    cmp dword ptr [r12], 0x706d742f /* exact /tmp */
    jne .Lself_walk_bad_permissions
    cmp dword ptr [rip + self_check_stat + 28], 0
    jne .Lself_walk_bad_permissions
    test dword ptr [rip + self_check_stat + 24], 512
    jz .Lself_walk_bad_permissions
    mov ebx, 1
    jmp .Lself_component_next
.Lself_component_protected:
    xor ebx, ebx
.Lself_component_next:
    lea r13, [r14 + 1]
    jmp .Lself_walk_component
.Lself_walk_complete:
    /* The final component was constructed as asm, never supplied by input. */
    mov rax, r15
    jmp .Lself_walk_return
.Lself_walk_bad_component:
    mov byte ptr [r14], '/'
.Lself_walk_bad_path:
    mov ebx, -1
    jmp .Lself_walk_close
.Lself_walk_bad_permissions:
    mov ebx, -2
.Lself_walk_close:
    mov eax, 3
    mov rdi, r15
    syscall
    movsxd rax, ebx
    jmp .Lself_walk_return
.Lself_walk_open_error:
    mov rax, -1
.Lself_walk_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Rewalk and validate the expected absolute path, then require its parent
 * and executable to match the held installation. Called before every verifier
 * child and immediately before the final rename. This catches displaced
 * directories as well as changed file entries; descriptor-relative writes
 * remain authoritative. A noncooperating same-UID race is outside the lock's
 * boundary. No input; no return on mismatch. Owns one temporary FD, always
 * closed. Stack: 8 saved bytes; scratch caller-save and self_check_stat. */
self_check_absolute_installation:
    push r12
    call self_open_parent
    test rax, rax
    js self_changed
    mov r12, rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + self_check_stat]
    syscall
    test rax, rax
    js .Lself_absolute_changed
    mov rax, [rip + self_check_stat]
    cmp rax, [rip + self_parent_stat]
    jne .Lself_absolute_changed
    mov rax, [rip + self_check_stat + 8]
    cmp rax, [rip + self_parent_stat + 8]
    jne .Lself_absolute_changed
    mov eax, 3
    mov rdi, r12
    syscall
    test rax, rax
    js self_changed
    call self_check_destination
    pop r12
    ret
.Lself_absolute_changed:
    mov eax, 3
    mov rdi, r12
    syscall
    jmp self_changed

/* RDI=Linux x86-64 stat structure (144 bytes). EAX=1 only for a single-link
 * regular executable owned by this UID, with no set-ID or unsafe write bits.
 * Reads only; clobbers RAX/RDX. */
self_check_file_stat:
    cmp qword ptr [rdi + 16], 1
    jne .Lself_bad_stat
    mov eax, [rdi + 28]
    cmp eax, [rip + self_uid]
    jne .Lself_bad_stat
    mov eax, [rdi + 24]
    mov edx, eax
    and edx, 61440
    cmp edx, 32768
    jne .Lself_bad_stat
    test eax, 3072 + 18
    jnz .Lself_bad_stat
    test eax, 64
    jz .Lself_bad_stat
    mov eax, 1
    ret
.Lself_bad_stat:
    xor eax, eax
    ret

/* Require the held directory entry to remain the exact executed inode.
 * Symlinks are inspected, never followed. No return on mismatch.
 * Stack: 8 alignment bytes. */
self_check_destination:
    sub rsp, 8
    mov eax, 262
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + self_binary_name]
    lea rdx, [rip + self_check_stat]
    mov r10d, 256
    syscall
    test rax, rax
    js self_changed
    lea rdi, [rip + self_check_stat]
    call self_check_file_stat
    test eax, eax
    jz self_changed
    mov rax, [rip + self_check_stat]
    cmp rax, [rip + self_current_stat]
    jne self_changed
    mov rax, [rip + self_check_stat + 8]
    cmp rax, [rip + self_current_stat + 8]
    jne self_changed
    mov eax, [rip + self_check_stat + 24]
    cmp eax, [rip + self_current_stat + 24]
    jne self_changed
    add rsp, 8
    ret

/* Input: selected, validated row. Build exact official asset URLs and local
 * stage paths. All version fields are <=32 bytes, buffers >=512/96 bytes.
 * Preserves callee-saved registers; scratch caller-save and stack 8 bytes. */
self_release_paths:
    push rbx
    mov rbx, [rip + registry_selected]
    lea rdi, [rip + self_asset_filename]
    lea rsi, [rip + self_asset_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, [rbx + 8]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_asset_suffix]
    call copy_string
    lea rdi, [rip + self_release_base]
    lea rsi, [rip + self_release_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, [rbx + 8]
    call copy_string
    mov byte ptr [rax], '/'
    mov byte ptr [rax + 1], 0
    lea rdi, [rip + self_asset_url]
    lea rsi, [rip + self_release_base]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_asset_filename]
    call copy_string
    lea rdi, [rip + self_manifest_url]
    lea rsi, [rip + self_release_base]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_manifest_name]
    call copy_string
    lea rdi, [rip + self_bundle_url]
    lea rsi, [rip + self_release_base]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_bundle_name]
    call copy_string
    lea rdi, [rip + self_manifest_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_manifest_suffix]
    call copy_string
    lea rdi, [rip + self_bundle_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_bundle_suffix]
    call copy_string
    pop rbx
    ret

/* Commit only a fully verified private payload. File mode and bytes are
 * synced before the final identity check and atomic rename. Rename is the
 * final fallible mutation: its failure preserves the previous directory entry.
 * Directory crash durability and hostile same-UID races are outside scope.
 * Stack: one saved descriptor. */
self_commit_update:
    push r12
    mov eax, 257
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + self_payload_name]
    mov edx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    xor r10d, r10d
    syscall
    test rax, rax
    js self_io_error
    mov r12, rax
    mov eax, 91
    mov rdi, r12
    mov esi, [rip + self_file_mode]
    syscall
    test rax, rax
    js .Lself_commit_close_fail
    mov eax, 74
    mov rdi, r12
    syscall
    test rax, rax
    js .Lself_commit_close_fail
    mov eax, 3
    mov rdi, r12
    syscall
    test rax, rax
    js self_io_error
    call self_check_absolute_installation
    mov eax, 264
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + self_payload_name]
    mov rdx, [rip + self_parent_fd]
    lea r10, [rip + self_binary_name]
    syscall
    test rax, rax
    js self_io_error
    pop r12
    ret
.Lself_commit_close_fail:
    mov eax, 3
    mov rdi, r12
    syscall
    jmp self_io_error

/* Cleanup only the held private stage and descriptors owned by this command.
 * Native descriptor-relative traversal does not follow links. Never delete a
 * substituted stage directory entry. Cleanup errors do not turn a committed
 * update into a reported failure. Uses archive cleanup buffers exclusively. */
self_update_cleanup:
    cmp byte ptr [rip + self_active], 0
    je .Lself_cleanup_done
    push r12
    cmp qword ptr [rip + self_stage_fd], 0
    jl .Lself_cleanup_without_stage
    mov rdi, [rip + self_stage_fd]
    xor esi, esi
    mov edx, 1
    call arc_walk_tree
    mov eax, 262
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + registry_temp_dir]
    lea rdx, [rip + self_check_stat]
    mov r10d, 256
    syscall
    test rax, rax
    js .Lself_close_stage
    mov rax, [rip + self_check_stat]
    cmp rax, [rip + self_stage_stat]
    jne .Lself_close_stage
    mov rax, [rip + self_check_stat + 8]
    cmp rax, [rip + self_stage_stat + 8]
    jne .Lself_close_stage
    mov eax, 263
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + registry_temp_dir]
    mov edx, 512
    syscall
.Lself_close_stage:
    mov rdi, [rip + self_stage_fd]
    call arc_close
    mov qword ptr [rip + self_stage_fd], -1
    jmp .Lself_cleanup_descriptors
.Lself_cleanup_without_stage:
    cmp byte ptr [rip + registry_has_workspace], 0
    je .Lself_cleanup_descriptors
    mov eax, 263
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + registry_temp_dir]
    mov edx, 512
    syscall
.Lself_cleanup_descriptors:
    mov byte ptr [rip + registry_has_workspace], 0
    mov rdi, [rip + self_current_fd]
    call arc_close
    mov qword ptr [rip + self_current_fd], -1
    mov rdi, [rip + self_parent_fd]
    call arc_close
    mov qword ptr [rip + self_parent_fd], -1
    mov byte ptr [rip + self_active], 0
    pop r12
.Lself_cleanup_done:
    ret

.section .rodata
self_install_suffix: .asciz "/.local/bin/asm"
self_proc_exe: .asciz "/proc/self/exe"
self_root: .asciz "/"
self_binary_name: .asciz "asm"
self_payload_name: .asciz "payload"
self_package: .asciz "stubbi/asm"
self_release_prefix: .asciz "https://github.com/stubbi/asm/releases/download/v"
self_asset_prefix: .asciz "asm-"
self_asset_suffix: .asciz "-x86_64-linux"
self_manifest_name: .asciz "release.json"
self_bundle_name: .asciz "release-attestation.sigstore.json"
self_manifest_suffix: .asciz "/release.json"
self_bundle_suffix: .asciz "/release-attestation.sigstore.json"
self_updated_text: .asciz "Updated asm to "
self_updated_suffix: .asciz ". Start a new command to use it.\n"
self_success_json: .asciz "{\"updated\":true,\"version\":"
self_success_suffix: .asciz ",\"integrity_verified\":true,\"provenance_verified\":true}\n"
self_unchanged_text: .asciz "No newer version was selected. The installed binary was not changed.\n"
self_unchanged_json: .asciz "{\"updated\":false,\"reason\":\"no-newer-version-selected\"}\n"
self_error_arguments: .asciz "invalid self arguments; use asm self --help"
self_error_downgrade: .asciz "self update refuses an older version; keep the current version or select a newer release"
self_error_installation: .asciz "self update requires the direct HOME/.local/bin/asm installation; use the bootstrap installer or your package manager"
self_error_permissions: .asciz "self update requires a single-link user-owned executable and protected path ancestors; check ownership and write permissions from / through HOME/.local/bin"
self_error_busy: .asciz "another update holds the installation lock; wait for it to finish and try again"
self_error_changed: .asciz "the installation path or executable changed during this operation; no replacement was made; start the installed command again"
self_error_filesystem: .asciz "self update requires a supported local filesystem; use your package manager or install the verified release manually"
self_error_io: .asciz "self update could not prepare or replace the executable; the previous binary remains; check free space and directory permissions"
self_error_download: .asciz "self update could not download required release files over HTTPS; the previous binary remains; check the connection and release"
self_error_release: .asciz "self update requires the exact official versioned asm artifact; the previous binary remains; check the published release"
self_error_not_found: .asciz "no matching asm host executable was found; check the requested version with asm versions stubbi/asm"
self_help_text:
    .ascii "Usage: asm self update [X.Y.Z] [--json] [--no-color]\n\n"
    .ascii "Manually update the direct HOME/.local/bin/asm installation.\n"
    .ascii "Uses stubbi/asm from https://asm.build. Older versions are refused.\n"
    .ascii "Requires /usr/bin/curl, sha256sum, and GitHub CLI gh >= 2.93.0.\n"
    .ascii "Checks size, SHA-256, host ELF, and release-workflow attestations.\n"
    .ascii "Does not execute the downloaded program or elevate privileges.\n"
    .ascii "No unattended update, metadata freshness, or revocation guarantee.\n"
    .ascii "Use your package manager for an installation that it owns.\n"
    .byte 0
.section .data
self_parent_fd: .quad -1
self_current_fd: .quad -1
self_stage_fd: .quad -1
.section .bss
.balign 8
self_home_length: .skip 8
self_uid: .skip 4
self_file_mode: .skip 4
self_active: .skip 1
self_has_update: .skip 1
self_version: .skip 33
self_install_path: .skip 4096
self_parent_path: .skip 4096
self_exe_path: .skip 4096
self_current_stat: .skip 144
self_parent_stat: .skip 144
self_check_stat: .skip 144
self_stage_stat: .skip 144
self_filesystem_stat: .skip 128
self_asset_filename: .skip 96
self_release_base: .skip 512
self_asset_url: .skip 512
self_manifest_url: .skip 512
self_bundle_url: .skip 512
self_manifest_path: .skip 96
self_bundle_path: .skip 96
