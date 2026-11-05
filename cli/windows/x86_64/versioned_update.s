/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Versioned activation. Shared download and all provenance bindings precede
 * this module. Candidates are inspected as files and are never executed.
 */
.intel_syntax noprefix
.text
/* No inputs. Require an active image-bound payload, retain original bin lock,
 * and enter the held store for shared private staging. WFRAME, owned duplicate
 * FDs become self_current_fd/self_parent_fd for existing cleanup. */
win_managed_open_installation:
    WFRAME
    cmp dword ptr [rip + wm_role], 2
    jne self_installation_error
    mov rax, [rip + wm_ids]
    cmp rax, [rip + wm_ids + 128]
    jne self_changed
    mov rax, [rip + wm_ids + 8]
    cmp rax, [rip + wm_ids + 136]
    jne self_changed
    mov rdi, [rip + wm_exec_fd]
    call win_handle
    mov rdi, rax
    call win_image_matches
    test rax, rax
    js self_changed
    mov eax, 73
    mov rdi, [rip + wm_bin_fd]
    mov esi, 6
    call win_syscall
    cmp rax, -11
    je self_busy
    cmp rax, -13
    je self_permissions_error
    test rax, rax
    js self_filesystem_error
    mov eax, 138
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + self_filesystem_stat]
    call win_syscall
    test rax, rax
    js self_filesystem_error
    cmp dword ptr [rip + self_filesystem_stat], 0x5346544e
    jne self_filesystem_error
    call win_managed_check_absolute_installation
    mov rdi, [rip + wm_store_fd]
    mov esi, 1030
    call win_duplicate
    test rax, rax
    js self_io_error
    mov [rip + self_parent_fd], rax
    mov rdi, [rip + wm_exec_fd]
    mov esi, 1030
    call win_duplicate
    test rax, rax
    js self_io_error
    mov [rip + self_current_fd], rax
    mov eax, 5
    mov rdi, [rip + self_parent_fd]
    lea rsi, [rip + self_parent_stat]
    call win_syscall
    test rax, rax
    js self_io_error
    mov eax, 5
    mov rdi, [rip + self_current_fd]
    lea rsi, [rip + self_current_stat]
    call win_syscall
    test rax, rax
    js self_io_error
    mov dword ptr [rip + self_file_mode], 448
    mov eax, 81
    mov rdi, [rip + self_parent_fd]
    call win_syscall
    test rax, rax
    js self_io_error
    WLEAVE
/* RDI=dirfd,RSI=component,EDX=context slot,R10D=directory boolean.
 * RAX=0/-116. Owns and closes one temporary descriptor on every path.
 * Verify security and volume/file ID against the retained startup snapshot. */
win_managed_recheck_entry:
    WFRAME
    mov r12d, edx
    mov r13d, r10d
    mov edx, 0x08000000
    test r13d, r13d
    jz 1f
    or edx, 65536
1:  xor r10d, r10d
    call win_open
    test rax, rax
    js .Lwmu_entry_bad
    mov r14, rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js .Lwmu_entry_close_bad
    test r13d, r13d
    jnz .Lwmu_entry_dir
    lea rdi, [rip + wm_stat]
    call self_check_file_stat
    test eax, eax
    jz .Lwmu_entry_close_bad
    jmp .Lwmu_entry_id
.Lwmu_entry_dir:
    mov eax, [rip + wm_stat + 28]
    cmp eax, [rip + self_uid]
    jne .Lwmu_entry_close_bad
    mov eax, [rip + wm_stat + 24]
    test eax, 18
    jnz .Lwmu_entry_close_bad
    and eax, 61440
    cmp eax, 16384
    jne .Lwmu_entry_close_bad
.Lwmu_entry_id:
    lea rdi, [rip + wm_ids]
    shl r12, 4
    mov rax, [rip + wm_stat]
    cmp rax, [rdi + r12]
    jne .Lwmu_entry_close_bad
    mov rax, [rip + wm_stat + 8]
    cmp rax, [rdi + r12 + 8]
    jne .Lwmu_entry_close_bad
    xor r15d, r15d
    jmp .Lwmu_entry_close
.Lwmu_entry_close_bad:
    mov r15, -116
.Lwmu_entry_close:
    mov rdi, r14
    mov eax, 3
    call win_syscall
    test rax, rax
    js .Lwmu_entry_bad
    mov rax, r15
    WLEAVE
.Lwmu_entry_bad:
    mov rax, -116
    WLEAVE
/* No inputs. Repeat the protected absolute ancestor walk and all retained
 * managed directory/file identities. The held record denies write sharing;
 * its file identity binds the exact original selection bytes. */
win_managed_check_absolute_installation:
    WFRAME
    call self_open_parent
    test rax, rax
    js self_changed
    mov r12, rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    call win_syscall
    or rax, r13
    js self_changed
    mov rax, [rip + wm_stat]
    cmp rax, [rip + wm_ids + 16]
    jne self_changed
    mov rax, [rip + wm_stat + 8]
    cmp rax, [rip + wm_ids + 24]
    jne self_changed
    mov rdi, [rip + wm_bin_fd]
    lea rsi, [rip + wm_store_name]
    mov edx, 2
    mov r10d, 1
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + wm_versions_name]
    mov edx, 3
    mov r10d, 1
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_bin_fd]
    lea rsi, [rip + self_binary_name]
    mov edx, 4
    xor r10d, r10d
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + wm_layout_name]
    mov edx, 5
    xor r10d, r10d
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    call win_managed_check_destination
    WLEAVE
win_managed_check_destination:
    WFRAME
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + wm_current_name]
    mov edx, 6
    xor r10d, r10d
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_versions_fd]
    mov rsi, [rip + wm_fields + 24]
    mov edx, 7
    mov r10d, 1
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_payload_dir_fd]
    lea rsi, [rip + self_binary_name]
    mov edx, 8
    xor r10d, r10d
    call win_managed_recheck_entry
    test rax, rax
    js self_changed
    WLEAVE
/* RDI=3 uint32 components,RSI=owned text[33]. RAX=end NUL pointer.
 * Inputs have already passed metadata bounds. Scratch decimal buffer[32]. */
win_managed_format_version:
    WFRAME
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
.Lwmu_format_part:
    mov edi, [r12 + r14*4]
    lea rsi, [rip + wm_decimal + 31]
    call unsigned_decimal
    mov rsi, rax
    mov rdi, r13
    call copy_string
    mov r13, rax
    inc r14d
    cmp r14d, 3
    je .Lwmu_format_end
    mov byte ptr [r13], '.'
    inc r13
    jmp .Lwmu_format_part
.Lwmu_format_end:
    mov rax, r13
    WLEAVE
/* Candidate guard: RDI=borrowed fd. RAX=0/-22. Exact selected size/hash,
 * file security, full PE, artifact version and held launcher compatibility.
 * No path reopens, children, or provenance substitutions. */
win_managed_candidate:
    WFRAME
    mov r12, rdi
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js .Lwmu_candidate_bad
    lea rdi, [rip + wm_stat]
    call self_check_file_stat
    test eax, eax
    jz .Lwmu_candidate_bad
    mov rdi, r12
    mov rsi, [rip + registry_expected_size]
    lea rdx, [rip + wm_hash]
    call win_hash_fd
    test eax, eax
    jnz .Lwmu_candidate_bad
    mov r13, [rip + registry_selected]
    lea rdi, [rip + wm_hash]
    mov rsi, [r13 + 32]
    call streq
    test eax, eax
    jz .Lwmu_candidate_bad
    mov rdi, r12
    mov rsi, [rip + registry_expected_size]
    lea rdx, [rip + wm_candidate_meta]
    call win_managed_pe
    test rax, rax
    js .Lwmu_candidate_bad
    lea rdi, [rip + wm_candidate_meta + 24]
    mov rsi, [r13 + 8]
    call win_managed_version_text
    test eax, eax
    jnz .Lwmu_candidate_bad
    lea rdi, [rip + wm_candidate_meta]
    lea rsi, [rip + wm_launcher_meta]
    call win_managed_compatible
    test eax, eax
    jnz .Lwmu_candidate_bad
    xor eax, eax
    WLEAVE
.Lwmu_candidate_bad:
    mov rax, -22
    WLEAVE
/* Final commit retains previous payloads. No-replace directory publication
 * precedes record staging. Only current.tsv rename activates new bytes.
 * Every owned FD is registered for cleanup before a fallible operation.
 * WFRAME and global bounded record[257], metadata64 and decimal32 buffers. */
win_managed_commit_update:
    WFRAME
    call win_managed_check_absolute_installation
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + self_payload_name]
    mov edx, 0x20000002
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_candidate_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js self_io_error
    lea rdi, [rip + wm_stat]
    call self_check_file_stat
    test eax, eax
    jz self_permissions_error
    mov rdi, [rip + wm_candidate_fd]
    mov eax, 91
    mov esi, 448
    call win_syscall
    test rax, rax
    js self_io_error
    mov rdi, [rip + wm_candidate_fd]
    mov eax, 74
win_managed_payload_flush:
    call win_syscall
    test rax, rax
    js self_io_error
    mov rdi, [rip + wm_candidate_fd]
    mov qword ptr [rip + wm_candidate_fd], -1
    mov eax, 3
    call win_syscall
    test rax, rax
    js self_io_error
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + self_payload_name]
    mov edx, 0x1a000000
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_candidate_fd], rax
    mov rdi, rax
    call win_managed_candidate
    test rax, rax
    js win_managed_compatibility_error
    mov eax, 258
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + wm_version_stage]
    mov edx, 448
    call win_syscall
    test rax, rax
    js self_io_error
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + wm_version_stage]
    mov edx, 0x10010000
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_candidate_dir_fd], rax
    mov rdi, [rip + wm_candidate_fd]
    call win_handle
    mov r12, rax
    mov rdi, [rip + wm_candidate_dir_fd]
    call win_handle
    mov rsi, rax
    mov rdi, r12
    lea rdx, [rip + self_binary_name]
    mov ecx, 1
    call win_managed_rename_fd
    test rax, rax
    js self_io_error
    mov rbx, [rip + registry_selected]
    mov rdi, [rip + wm_candidate_dir_fd]
    call win_handle
    mov r12, rax
    mov rdi, [rip + wm_versions_fd]
    call win_handle
    mov rsi, rax
    mov rdi, r12
    mov rdx, [rbx + 32]
    mov ecx, 1
    call win_managed_rename_fd
    test rax, rax
    jns .Lwmu_published
    cmp rax, -17
    jne self_io_error
    /* A prior exact digest publication is reusable only after complete
     * directory security and held artifact checks. Other bytes remain intact. */
    mov rdi, [rip + wm_versions_fd]
    mov rsi, [rbx + 32]
    mov edx, 65536
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_existing_dir_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js self_io_error
    mov eax, [rip + wm_stat + 28]
    cmp eax, [rip + self_uid]
    jne self_permissions_error
    test dword ptr [rip + wm_stat + 24], 18
    jnz self_permissions_error
    mov rdi, [rip + wm_existing_dir_fd]
    lea rsi, [rip + self_binary_name]
    mov edx, 0x1a000000
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_existing_fd], rax
    mov rdi, rax
    call win_managed_candidate
    test rax, rax
    js self_changed
.Lwmu_published:
    lea rdi, [rip + wm_candidate_meta + 36]
    lea rsi, [rip + wm_min_text]
    call win_managed_format_version
    lea rdi, [rip + wm_next_record]
    lea rsi, [rip + wm_record_header]
    mov ecx, 21
    rep movsb
    mov rsi, [rbx + 8]
    call copy_string
    mov byte ptr [rax], 9
    lea rdi, [rax + 1]
    lea rsi, [rip + registry_host]
    call copy_string
    mov byte ptr [rax], 9
    lea rdi, [rax + 1]
    mov rsi, [rbx + 48]
    call copy_string
    mov byte ptr [rax], 9
    lea rdi, [rax + 1]
    mov rsi, [rbx + 32]
    call copy_string
    mov byte ptr [rax], 9
    mov byte ptr [rax + 1], '1'
    mov byte ptr [rax + 2], 9
    lea rdi, [rax + 3]
    lea rsi, [rip + wm_min_text]
    call copy_string
    mov byte ptr [rax], 10
    inc rax
    lea rdx, [rip + wm_next_record]
    sub rax, rdx
    cmp rax, 256
    ja self_io_error
    mov [rip + wm_next_length], rax
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + wm_next_name]
    mov edx, 194
    mov r10d, 384
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_next_fd], rax
    mov r12, [rip + wm_next_length]
    lea r13, [rip + wm_next_record]
.Lwmu_write:
    mov rdi, [rip + wm_next_fd]
    mov rsi, r13
    mov rdx, r12
    mov eax, 1
win_managed_record_write:
    call win_syscall
    test rax, rax
    jle self_io_error
    add r13, rax
    sub r12, rax
    jnz .Lwmu_write
    mov rdi, [rip + wm_next_fd]
    mov eax, 74
win_managed_record_flush:
    call win_syscall
    test rax, rax
    js self_io_error
    mov rdi, [rip + wm_next_fd]
    mov eax, 5
    lea rsi, [rip + wm_new_record_stat]
    call win_syscall
    test rax, rax
    js self_io_error
    mov rdi, [rip + wm_next_fd]
    mov qword ptr [rip + wm_next_fd], -1
    mov eax, 3
    call win_syscall
    test rax, rax
    js self_io_error
    /* Reopen read+DELETE after closing the writer. Deny-write sharing then
     * remains compatible with all concurrent read/delete record snapshots. */
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + wm_next_name]
    mov edx, 0x18000000
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_io_error
    mov [rip + wm_next_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js self_io_error
    mov rax, [rip + wm_stat]
    cmp rax, [rip + wm_new_record_stat]
    jne self_changed
    mov rax, [rip + wm_stat + 8]
    cmp rax, [rip + wm_new_record_stat + 8]
    jne self_changed
    mov rax, [rip + wm_stat + 48]
    cmp rax, [rip + wm_next_length]
    jne self_changed
    lea rdi, [rip + wm_stat]
    call self_check_file_stat
    test eax, eax
    jz self_permissions_error
    mov rdi, [rip + wm_next_fd]
    lea rsi, [rip + wm_record_check]
    mov rdx, [rip + wm_next_length]
    call elf_read_exact
    test rax, rax
    js self_io_error
    lea rdi, [rip + wm_record_check]
    lea rsi, [rip + wm_next_record]
    mov rcx, [rip + wm_next_length]
    repe cmpsb
    jne self_changed
    call win_managed_check_absolute_installation
    /* Recheck digest directory and file location before exposing its record. */
    mov rdi, [rip + wm_versions_fd]
    mov rsi, [rbx + 32]
    mov edx, 65536
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_changed
    mov [rip + wm_final_dir_fd], rax
    mov rdi, rax
    mov rsi, [rip + wm_candidate_dir_fd]
    cmp qword ptr [rip + wm_existing_dir_fd], 0
    jl 1f
    mov rsi, [rip + wm_existing_dir_fd]
1:  call win_managed_same_fd
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_final_dir_fd]
    lea rsi, [rip + self_binary_name]
    mov edx, 0x1a000000
    xor r10d, r10d
    call win_open
    test rax, rax
    js self_changed
    mov [rip + wm_final_fd], rax
    mov rdi, rax
    mov rsi, [rip + wm_candidate_fd]
    cmp qword ptr [rip + wm_existing_fd], 0
    jl 1f
    mov rsi, [rip + wm_existing_fd]
1:  call win_managed_same_fd
    test rax, rax
    js self_changed
    mov rdi, [rip + wm_final_fd]
    call win_managed_candidate
    test rax, rax
    js self_changed
    call win_managed_check_absolute_installation
    mov rdi, [rip + wm_next_fd]
    call win_handle
    mov r12, rax
    mov rdi, [rip + self_parent_fd]
    call win_handle
    mov rsi, rax
    mov rdi, r12
    lea rdx, [rip + wm_current_name]
    xor ecx, ecx
win_managed_activation_rename:
    call win_managed_rename_fd
    test rax, rax
    js self_io_error
    /* The sole commit completed. Cleanup cannot change the success result. */
    WLEAVE
/* Additional update contexts close before shared stage cleanup. */
win_managed_update_cleanup:
    WFRAME
    lea r12, [rip + wm_update_fds]
    mov r13d, 7
.Lwmu_cleanup:
    mov rdi, [r12]
    mov qword ptr [r12], -1
    test rdi, rdi
    js 1f
    mov eax, 3
    call win_syscall
1:  add r12, 8
    dec r13d
    jnz .Lwmu_cleanup
    WLEAVE
.section .rdata,"dr"
wm_version_stage: .asciz "version"
wm_next_name: .asciz "current.next"
.section .data
.p2align 3
wm_update_fds:
wm_candidate_fd: .quad -1
wm_candidate_dir_fd: .quad -1
wm_existing_dir_fd: .quad -1
wm_existing_fd: .quad -1
wm_next_fd: .quad -1
wm_final_dir_fd: .quad -1
wm_final_fd: .quad -1
.section .bss
wm_candidate_meta: .space 64
wm_min_text: .space 33
wm_decimal: .space 32
wm_next_record: .space 257
wm_next_length: .space 8

.text
/* RDI=borrowed flushed source HANDLE with DELETE, RSI=held parent HANDLE,
 * RDX=fixed single-component UTF8 target, RCX=1 no-replace or0 replace.
 * RAX=0/-errno. Neither handle closes or reopens. Exact source authority flows
 * to FileRenameInformationEx. WFRAME, shared rename buffer[8216]. */
win_managed_rename_fd:
    WFRAME
    mov r12, rdi
    mov r13, rsi
    mov r14, rcx
    mov rdi, rdx
    lea rsi, [rip + win_rename_info + 20]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwmu_rename_bad
    dec eax
    shl eax, 1
    mov [rip + win_rename_info + 16], eax
    mov [rip + win_rename_info + 8], r13
    lea rdi, [rip + win_rename_info + 20]
    mov edx, eax
    call win_component_safe
    test eax, eax
    jz .Lwmu_rename_bad
    mov dword ptr [rip + win_rename_info], 2
    test r14, r14
    jnz 1f
    or dword ptr [rip + win_rename_info], 1
1:  mov rcx, r12
    lea rdx, [rbp - 128]
    lea r8, [rip + win_rename_info]
    mov r9d, [rip + win_rename_info + 16]
    add r9d, 20
    mov qword ptr [rsp + 32], 65
    call NtSetInformationFile
    test eax, eax
    js .Lwmu_rename_error
    xor eax, eax
    WLEAVE
.Lwmu_rename_error:
    call win_nt_error
    WLEAVE
.Lwmu_rename_bad:
    mov rax, -22
    WLEAVE
.section .bss
wm_new_record_stat: .space 144
wm_record_check: .space 257

.text
/* RDI/RSI=borrowed FDs. RAX=0/-116. Compare current private user-owned
 * object identities; no handle ownership changes and no path lookup. */
win_managed_same_fd:
    WFRAME
    mov r12, rsi
    mov eax, 5
    lea rsi, [rip + wm_compare_stat]
    call win_syscall
    test rax, rax
    js .Lwmu_same_bad
    mov rdi, r12
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js .Lwmu_same_bad
    mov eax, [rip + wm_compare_stat + 28]
    cmp eax, [rip + self_uid]
    jne .Lwmu_same_bad
    test dword ptr [rip + wm_compare_stat + 24], 18
    jnz .Lwmu_same_bad
    mov rax, [rip + wm_compare_stat]
    cmp rax, [rip + wm_stat]
    jne .Lwmu_same_bad
    mov rax, [rip + wm_compare_stat + 8]
    cmp rax, [rip + wm_stat + 8]
    jne .Lwmu_same_bad
    xor eax, eax
    WLEAVE
.Lwmu_same_bad:
    mov rax, -116
    WLEAVE
.section .bss
wm_compare_stat: .space 144
