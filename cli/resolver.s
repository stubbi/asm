/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native dependency driver. See docs/specs/dependencies.md.
 * All returning routines preserve RBX/RBP/R12-R15. Other registers are scratch.
 * No package code is executed. Transport, hashes and archive checks reuse the
 * existing fixed-tool adapters. Every buffer is owned by this process.
 */
.intel_syntax noprefix
.global cmd_resolve
.equ RES_RM_SIZE, RM_SIZE
.equ RES_NODE_SIZE, 4096
.section .text

/* argv follows resolve. Parse all options before creating dependency state.
 * Index <=1MiB, manifests <=8190 bytes, archive <=64MiB. Lock rename is last.
 * Fatal errors use the normal registry cleanup path. Command does not return. */
cmd_resolve:
    lea rax, [rip + registry_default_url]
    mov [rip + registry_url], rax
    mov qword ptr [rip + res_default], 1
.Lres_args:
    call next_arg
    test rax, rax
    jz .Lres_start
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + registry_opt_index]
    call streq
    test eax, eax
    jnz .Lres_arg_index
    mov rdi, r12
    lea rsi, [rip + registry_opt_registry]
    call streq
    test eax, eax
    jnz .Lres_arg_registry
    mov rdi, r12
    lea rsi, [rip + res_opt_artifacts]
    call streq
    test eax, eax
    jnz .Lres_arg_artifacts
    mov rdi, r12
    lea rsi, [rip + res_opt_features]
    call streq
    test eax, eax
    jnz .Lres_arg_features
    mov rdi, r12
    lea rsi, [rip + res_opt_no_default]
    call streq
    test eax, eax
    jnz .Lres_arg_no_default
    mov rdi, r12
    lea rsi, [rip + opt_help]
    call streq
    test eax, eax
    jnz res_help
    mov rax, r12
    call common_option
    test eax, eax
    jz registry_bad_args
    jmp .Lres_args
.Lres_arg_index:
    cmp byte ptr [rip + registry_origin_seen], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + registry_index_path], rax
    mov byte ptr [rip + registry_local_index], 1
    mov byte ptr [rip + registry_origin_seen], 1
    jmp .Lres_args
.Lres_arg_registry:
    cmp byte ptr [rip + registry_origin_seen], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + registry_url], rax
    mov rdi, rax
    call registry_https_url
    test eax, eax
    jz registry_bad_args
    mov byte ptr [rip + registry_origin_seen], 1
    jmp .Lres_args
.Lres_arg_artifacts:
    cmp qword ptr [rip + res_artifacts], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + res_artifacts], rax
    jmp .Lres_args
.Lres_arg_features:
    cmp qword ptr [rip + res_cli_features], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + res_cli_features], rax
    jmp .Lres_args
.Lres_arg_no_default:
    cmp byte ptr [rip + res_no_default_seen], 0
    jne registry_bad_args
    mov byte ptr [rip + res_no_default_seen], 1
    mov qword ptr [rip + res_default], 0
    jmp .Lres_args
.Lres_start:
    call read_manifest
    cmp qword ptr [rip + rm_root_metadata], 1
    jne res_manifest_error
    mov rdi, [rip + res_cli_features]
    call res_parse_features
    mov edi, 6
    mov esi, 1
    call dependency_acquire
    call res_hash_root
    call res_read_previous
    mov rax, [rip + registry_url]
    cmp byte ptr [rip + registry_local_index], 0
    je .Lres_origin_ready
    lea rax, [rip + dependency_local_origin]
.Lres_origin_ready:
    mov [rip + dependency_origin], rax
    cmp qword ptr [rip + res_previous_origin], 0
    je .Lres_index
    mov rdi, rax
    mov rsi, [rip + res_previous_origin]
    call streq
    test eax, eax
    jz dependency_origin_error
.Lres_index:
    cmp qword ptr [rip + registry_index_path], 0
    jne .Lres_index_read
    call registry_workspace
    mov rdi, [rip + registry_url]
    lea rsi, [rip + registry_temp_index]
    lea rdx, [rip + registry_index_max]
    call registry_download
    test eax, eax
    jnz registry_download_error
    lea rax, [rip + registry_temp_index]
    mov [rip + registry_index_path], rax
.Lres_index_read:
    call registry_read_index
    call registry_parse_index
    call res_copy_rows
    /* The registry input is now in its owned buffer. A later cleanup cannot
     * erase it. No network artifact can replace index strings. */
    call registry_cleanup
    call res_solve
    test eax, eax
    jz res_conflict_error
    call res_check_immutable
    call res_render_lock
    call res_commit_lock
    call registry_cleanup
    call release_dependency_lock
    lea rdi, [rip + res_done]
    jmp res_report

res_help:
    lea rdi, [rip + res_help_text]
    call out
    jmp exit_ok

/* RDI=optional comma list, <=2111 bytes. Store at most64 unique borrowed names
 * in owned res_feature_buffer[2113]. Sort them for a canonical lock header.
 * Empty input is represented by NULL; explicit empty/duplicate names fail.
 * Stack:40 saved bytes. No filesystem effect. */
res_parse_features:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov qword ptr [rip + res_root_request_count], 0
    test rdi, rdi
    jz .Lres_features_done
    mov r12, rdi
    call strlen
    test rax, rax
    jz registry_bad_args
    cmp rax, 2111
    ja registry_bad_args
    lea rdi, [rip + res_feature_buffer]
    mov rsi, r12
    call copy_string
    lea r12, [rip + res_feature_buffer]
.Lres_feature_name:
    mov r13, r12
    xor r14d, r14d
.Lres_feature_chars:
    movzx eax, byte ptr [r12]
    test al, al
    jz .Lres_feature_end
    cmp al, ','
    je .Lres_feature_end
    cmp al, 'a'
    jb .Lres_feature_other
    cmp al, 'z'
    jbe .Lres_feature_char_ok
.Lres_feature_other:
    test r14d, r14d
    jz registry_bad_args
    cmp al, '-'
    je .Lres_feature_char_ok
    cmp al, '_'
    je .Lres_feature_char_ok
    cmp al, '0'
    jb registry_bad_args
    cmp al, '9'
    ja registry_bad_args
.Lres_feature_char_ok:
    inc r12
    inc r14d
    cmp r14d, 32
    ja registry_bad_args
    jmp .Lres_feature_chars
.Lres_feature_end:
    test r14d, r14d
    jz registry_bad_args
    mov r15b, al
    mov byte ptr [r12], 0
    mov rbx, [rip + res_root_request_count]
    cmp rbx, 64
    jae res_limit_error
    lea r14, [rip + res_root_requests]
    xor r10d, r10d
.Lres_feature_duplicate:
    cmp r10, rbx
    jae .Lres_feature_insert
    mov rdi, r13
    mov rsi, [r14 + r10*8]
    push r10
    call streq
    pop r10
    test eax, eax
    jnz registry_bad_args
    inc r10
    jmp .Lres_feature_duplicate
.Lres_feature_insert:
    mov [r14 + rbx*8], r13
    inc qword ptr [rip + res_root_request_count]
    test r15b, r15b
    jz .Lres_feature_sort
    inc r12
    jmp .Lres_feature_name
.Lres_feature_sort:
    mov r12d, 1
.Lres_feature_sort_outer:
    cmp r12, [rip + res_root_request_count]
    jae .Lres_features_done
    mov r13, r12
.Lres_feature_sort_inner:
    test r13, r13
    jz .Lres_feature_sort_next
    mov rdi, [r14 + r13*8 - 8]
    mov rsi, [r14 + r13*8]
    call res_strcmp
    test eax, eax
    jle .Lres_feature_sort_next
    mov rax, [r14 + r13*8]
    mov rdx, [r14 + r13*8 - 8]
    mov [r14 + r13*8 - 8], rax
    mov [r14 + r13*8], rdx
    dec r13
    jmp .Lres_feature_sort_inner
.Lres_feature_sort_next:
    inc r12
    jmp .Lres_feature_sort_outer
.Lres_features_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* NUL ASCII strings RDI/RSI. RAX signed comparison; read-only, stack:none. */
res_strcmp:
    xor ecx, ecx
.Lres_strcmp_loop:
    movzx eax, byte ptr [rdi + rcx]
    movzx edx, byte ptr [rsi + rcx]
    sub eax, edx
    jnz .Lres_strcmp_done
    test edx, edx
    jz .Lres_strcmp_done
    inc rcx
    jmp .Lres_strcmp_loop
.Lres_strcmp_done:
    ret

/* Hash the exact unmodified bytes retained by read_manifest. The parser and
 * lock digest therefore describe one snapshot even if the source file changes.
 * Input rm_root_original[8192]; output res_root_hash[65]. Mature fixed-tool
 * hash adapter receives only the private snapshot through stdin. Stack:none. */
res_hash_root:
    call registry_workspace
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + rm_root_original]
    lea rdx, [rip + res_snapshot_created]
    call create_exclusive_file
    test rax, rax
    js registry_io_error
    call pub_hash_payload
    test eax, eax
    jnz registry_integrity_error
    lea rsi, [rip + pub_hash_buffer]
    lea rdi, [rip + res_root_hash]
    mov ecx, 64
    rep movsb
    mov byte ptr [rdi], 0
    call registry_cleanup
    ret

/* A non-following bounded probe only selects the parser. Invalid locks still
 * fail in their full readers. RAX=1 v2 prefix,0 otherwise. Stack:8 bytes. */
res_is_v2:
    push r12
    mov eax, SYS_open
    lea rdi, [rip + dependency_lock_path]
    mov esi, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js .Lres_probe_no
    mov r12, rax
    mov eax, SYS_fstat
    mov rdi, r12
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    js .Lres_probe_close
    mov eax, [rip + registry_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lres_probe_close
    xor eax, eax
    mov rdi, r12
    lea rsi, [rip + res_probe]
    mov edx, 14
    syscall
    cmp rax, 14
    jne .Lres_probe_close
    mov byte ptr [rip + res_probe + 14], 0
    mov eax, SYS_close
    mov rdi, r12
    syscall
    lea rdi, [rip + res_probe]
    lea rsi, [rip + res_header]
    call streq
    pop r12
    ret
.Lres_probe_close:
    mov eax, SYS_close
    mov rdi, r12
    syscall
.Lres_probe_no:
    xor eax, eax
    pop r12
    ret

/* Used by legacy add/update/remove. Refuse graph mutation before any changed
 * lock or cache. read_manifest has populated rm_root_metadata. */
res_legacy_guard:
    cmp qword ptr [rip + rm_root_metadata], 0
    jne res_use_resolve_error
    call res_is_v2
    test eax, eax
    jnz res_use_resolve_error
    ret

/* Preserve previous exact rows for immutable-version comparisons. Owned row
 * pointers borrow either v1 dependency_lock_buffer or res_lock_buffer. */
res_read_previous:
    call res_is_v2
    test eax, eax
    jz .Lres_previous_v1
    call res_read_v2
    jmp .Lres_previous_copy
.Lres_previous_v1:
    call dependency_load_lock
    test eax, eax
    jnz .Lres_previous_none
.Lres_previous_copy:
    mov rax, [rip + dependency_origin]
    mov [rip + res_previous_origin], rax
    mov rcx, [rip + registry_row_count]
    mov [rip + res_previous_count], rcx
    shl rcx, 3
    lea rdi, [rip + res_previous_rows]
    lea rsi, [rip + registry_rows]
    rep movsq
.Lres_previous_none:
    ret

/* Load v2 as a bounded regular non-symlink file. Keep an unmodified copy for
 * canonical verification. Only flags/origin are trusted as resolution inputs;
 * enabled-feature comments and selected rows are recomputed from archives.
 * Output registry_rows/count, dependency_origin, res_lock_*; stack:32 bytes. */
res_read_v2:
    push rbx
    push r12
    push r13
    push r14
    mov eax, SYS_open
    lea rdi, [rip + dependency_lock_path]
    mov esi, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js res_lock_error
    mov r12, rax
    mov eax, SYS_fstat
    mov rdi, r12
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    js res_lock_error
    mov eax, [rip + registry_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne res_lock_error
    cmp qword ptr [rip + registry_stat + 48], 1048576
    ja res_lock_error
    xor r13d, r13d
.Lres_lock_read:
    mov eax, SYS_read
    mov rdi, r12
    lea rsi, [rip + res_lock_buffer]
    add rsi, r13
    mov edx, 1048577
    sub rdx, r13
    syscall
    cmp rax, -4
    je .Lres_lock_read
    test rax, rax
    js res_lock_error
    jz .Lres_lock_read_end
    add r13, rax
    cmp r13, 1048576
    ja res_lock_error
    jmp .Lres_lock_read
.Lres_lock_read_end:
    mov eax, SYS_close
    mov rdi, r12
    syscall
    lea rdi, [rip + res_lock_buffer]
    mov rcx, r13
    mov [rip + res_lock_length], r13
    lea rsi, [rip + res_lock_buffer]
    lea rdi, [rip + res_lock_original]
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + res_lock_buffer]
    mov byte ptr [rdi + r13], 0
    lea r14, [rdi + r13]
    lea rsi, [rip + res_header]
    call dependency_prefix
    test rax, rax
    jz res_lock_error
    mov rdi, rax
    lea rsi, [rip + dependency_origin_prefix]
    call dependency_prefix
    test rax, rax
    jz res_lock_error
    mov rdi, rax
    mov [rip + dependency_origin], rdi
    call res_line
    mov r12, rax
    mov rdi, [rip + dependency_origin]
    lea rsi, [rip + dependency_local_origin]
    call streq
    test eax, eax
    jnz .Lres_lock_default
    mov rdi, [rip + dependency_origin]
    call registry_https_url
    test eax, eax
    jz res_lock_error
.Lres_lock_default:
    mov rdi, r12
    lea rsi, [rip + res_default_prefix]
    call dependency_prefix
    test rax, rax
    jz res_lock_error
    movzx edx, byte ptr [rax]
    sub edx, '0'
    cmp edx, 1
    ja res_lock_error
    cmp byte ptr [rax + 1], 10
    jne res_lock_error
    mov [rip + res_lock_default], rdx
    lea rdi, [rax + 2]
    lea rsi, [rip + res_features_prefix]
    call dependency_prefix
    test rax, rax
    jz res_lock_error
    mov rdi, rax
    mov [rip + res_lock_features], rax
    call res_line
    mov rdi, rax
    lea rsi, [rip + res_manifest_prefix]
    call dependency_prefix
    test rax, rax
    jz res_lock_error
    mov rdi, rax
    mov [rip + res_lock_hash], rax
    call res_line
    mov r12, rax
    mov rdi, [rip + res_lock_hash]
    call strlen
    cmp rax, 64
    jne res_lock_error
.Lres_lock_comments:
    cmp byte ptr [r12], '#'
    jne .Lres_lock_records
    mov rdi, r12
    lea rsi, [rip + res_enabled_prefix]
    call dependency_prefix
    test rax, rax
    jz res_lock_error
    mov rdi, rax
    call res_line
    mov r12, rax
    jmp .Lres_lock_comments
.Lres_lock_records:
    mov qword ptr [rip + registry_row_count], 0
    mov rdi, r12
    mov rsi, r14
    call registry_parse_records
    cmp qword ptr [rip + registry_row_count], 128
    ja res_limit_error
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Lres_lock_validate:
    cmp r13, [rip + registry_row_count]
    jae .Lres_lock_loaded
    mov rdi, [r12 + 16]
    lea rsi, [rip + registry_host]
    call streq
    test eax, eax
    jz res_lock_error
    mov rdi, [r12 + 24]
    lea rsi, [rip + registry_source_kind]
    call streq
    test eax, eax
    jz res_lock_error
    lea rbx, [rip + registry_rows]
.Lres_lock_duplicate:
    cmp rbx, r12
    jae .Lres_lock_next
    mov rdi, [rbx]
    mov rsi, [r12]
    call streq
    test eax, eax
    jnz res_lock_error
    add rbx, 64
    jmp .Lres_lock_duplicate
.Lres_lock_next:
    add r12, 64
    inc r13
    jmp .Lres_lock_validate
.Lres_lock_loaded:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI points into res_lock_buffer, R14 its end. Replace LF with NUL and return
 * following byte. Refuse embedded NUL/control/non-ASCII and lines>4095 bytes. */
res_line:
    xor ecx, ecx
.Lres_line_loop:
    cmp rdi, r14
    jae res_lock_error
    mov al, [rdi]
    cmp al, 10
    je .Lres_line_end
    cmp al, 9
    je .Lres_line_char
    cmp al, 32
    jb res_lock_error
    cmp al, 126
    ja res_lock_error
.Lres_line_char:
    inc rdi
    inc ecx
    cmp ecx, 4095
    ja res_lock_error
    jmp .Lres_line_loop
.Lres_line_end:
    mov byte ptr [rdi], 0
    lea rax, [rdi + 1]
    ret

/* Copy validated registry rows into solver-owned storage. Their strings remain
 * borrowed from registry/lock buffers. Count <=4096; stack:none. */
res_copy_rows:
    mov rcx, [rip + registry_row_count]
    mov [rip + res_row_count], rcx
    shl rcx, 3
    lea rdi, [rip + res_rows]
    lea rsi, [rip + registry_rows]
    rep movsq
    ret

/* Callback RDI=validated row, return RAX=persistent metadata. Inspect at most
 * 256 candidates. Acquire and validate compressed bytes before parsing their
 * manifest. Cache comparison precedes replacement. In check mode no fetch,
 * extraction or writes to managed caches occur. Stack:40 saved bytes. */
res_load_candidate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    xor r12d, r12d
    lea r13, [rip + res_loaded_rows]
.Lres_loaded_find:
    cmp r12, [rip + res_loaded_count]
    jae .Lres_load_new
    cmp rbx, [r13 + r12*8]
    je .Lres_loaded_return
    inc r12
    jmp .Lres_loaded_find
.Lres_load_new:
    cmp r12, 256
    jae res_limit_error
    mov [r13 + r12*8], rbx
    inc qword ptr [rip + res_loaded_count]
    mov [rip + registry_selected], rbx
    mov rdi, [rbx + 48]
    call registry_size_value
    mov [rip + registry_expected_size], rax
    mov edi, 1
    cmp byte ptr [rip + res_check_mode], 0
    je .Lres_candidate_paths
    xor edi, edi
.Lres_candidate_paths:
    call dependency_paths
    call registry_workspace
    /* Existing digest cache is verified rather than silently repaired. */
    mov eax, 6
    lea rdi, [rip + dependency_archive_path]
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    jz .Lres_candidate_cached
    cmp rax, -2
    jne dependency_cache_changed
    cmp byte ptr [rip + res_check_mode], 0
    jne dependency_cache_missing
    cmp qword ptr [rip + res_artifacts], 0
    jne .Lres_candidate_offline
    mov rdi, [rbx + 40]
    lea rsi, [rip + registry_temp_payload]
    mov rdx, [rbx + 48]
    call registry_download
    test eax, eax
    jnz registry_download_error
    jmp .Lres_candidate_verify
.Lres_candidate_cached:
    lea rax, [rip + dependency_archive_path]
    mov [rip + registry_local_artifact], rax
    call registry_copy_local
    jmp .Lres_candidate_verify
.Lres_candidate_offline:
    call res_offline_path
    lea rax, [rip + res_artifact_path]
    mov [rip + registry_local_artifact], rax
    call registry_copy_local
.Lres_candidate_verify:
    call registry_verify_payload
    cmp byte ptr [rip + res_check_mode], 0
    jne .Lres_candidate_check
    call dependency_accept_payload
    jmp .Lres_candidate_manifest
.Lres_candidate_check:
    lea rdi, [rip + registry_temp_payload]
    mov rsi, [rbx]
    mov rdx, [rbx + 8]
    mov rcx, [rbx + 16]
    call validate_source_package
    test eax, eax
    jnz dependency_archive_error
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + dependency_package_path]
    call verify_source_archive
    test eax, eax
    jnz dependency_cache_changed
.Lres_candidate_manifest:
    lea rdi, [rip + pub_manifest_name]
    call source_archive_member
    test rax, rax
    jz res_manifest_error
    test ecx, ecx
    jnz res_manifest_error
    test rdx, rdx
    jz res_manifest_error
    cmp rdx, 16384
    ja res_manifest_error
    mov rsi, rax
    mov rcx, rdx
    mov rax, r12
    imul rax, rax, 16385
    lea r14, [rip + res_manifests]
    add r14, rax
    mov rdi, r14
    rep movsb
    mov byte ptr [rdi], 0
    mov rdi, r14
    mov rax, r12
    imul rax, rax, RES_RM_SIZE
    lea rsi, [rip + res_metadata]
    add rsi, rax
    call rm_parse_manifest
    test eax, eax
    jnz res_manifest_error
    call registry_cleanup
.Lres_loaded_return:
    mov rax, r12
    imul rax, rax, RES_RM_SIZE
    lea rdx, [rip + res_metadata]
    add rax, rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Offline directory is a user-selected path, <=4095 bytes. Inspect every
 * existing component without following symlinks; file open also uses NOFOLLOW.
 * This is a checked path boundary, not a race-free descriptor walk. Same-user
 * processes can race path replacement, as with the existing cache checks. */
res_offline_path:
    push r12
    push r13
    mov r12, [rip + res_artifacts]
    mov rdi, r12
    call strlen
    cmp rax, 4000
    ja registry_bad_args
    lea rdi, [rip + res_artifact_path]
    mov rsi, r12
    call copy_string
    lea r12, [rip + res_artifact_path]
    mov r13, r12
.Lres_dir_component:
    mov al, [r13]
    test al, al
    jz .Lres_dir_final
    cmp al, '/'
    jne .Lres_dir_advance
    cmp r13, r12
    je .Lres_dir_advance
    mov byte ptr [r13], 0
    call res_check_artifact_dir
    mov byte ptr [r13], '/'
.Lres_dir_advance:
    inc r13
    jmp .Lres_dir_component
.Lres_dir_final:
    call res_check_artifact_dir
    mov rdi, r13
    lea rsi, [rip + res_slash]
    call copy_string
    mov rdi, rax
    mov rax, [rip + registry_selected]
    mov rsi, [rax + 32]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + res_archive_suffix]
    call copy_string
    pop r13
    pop r12
    ret
res_check_artifact_dir:
    mov eax, 6
    lea rdi, [rip + res_artifact_path]
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    js registry_io_error
    mov eax, [rip + registry_stat + 24]
    and eax, 61440
    cmp eax, 16384
    jne registry_io_error
    ret

/* Compare every reused identity/version to previous immutable artifact fields.
 * Inputs solver nodes, retained previous rows. Stack:40 saved bytes. */
res_check_immutable:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, 1
.Lres_immutable_node:
    cmp r12, [rip + res_node_count]
    jae .Lres_immutable_done
    mov rax, r12
    shl rax, 12
    lea rdx, [rip + res_nodes]
    mov r13, [rdx + rax + 8]
    xor r14d, r14d
    lea r15, [rip + res_previous_rows]
.Lres_immutable_row:
    cmp r14, [rip + res_previous_count]
    jae .Lres_immutable_next
    mov rdi, [r13]
    mov rsi, [r15]
    call streq
    test eax, eax
    jz .Lres_immutable_row_next
    mov rdi, [r13 + 8]
    mov rsi, [r15 + 8]
    call streq
    test eax, eax
    jz .Lres_immutable_row_next
    mov ebx, 2
.Lres_immutable_field:
    mov rdi, [r13 + rbx*8]
    mov rsi, [r15 + rbx*8]
    call streq
    test eax, eax
    jz dependency_changed_release
    inc ebx
    cmp ebx, 7
    jb .Lres_immutable_field
.Lres_immutable_row_next:
    add r15, 64
    inc r14
    jmp .Lres_immutable_row
.Lres_immutable_next:
    inc r12
    jmp .Lres_immutable_node
.Lres_immutable_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Canonical rendering <=1MiB. Hash binds the exact root manifest; flags bind
 * selected root features; feature comments are regenerated from the verified
 * complete graph. Artifacts use the existing stable eight-column record. */
res_render_lock:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rax, [rip + res_rendered]
    mov [rip + res_render_cursor], rax
    lea rdi, [rip + res_header]
    call res_append
    lea rdi, [rip + dependency_origin_prefix]
    call res_append
    mov rdi, [rip + dependency_origin]
    call res_append
    lea rdi, [rip + registry_newline]
    call res_append
    lea rdi, [rip + res_default_prefix]
    call res_append
    lea rdi, [rip + res_false]
    cmp qword ptr [rip + res_default], 0
    je .Lres_render_default
    lea rdi, [rip + res_true]
.Lres_render_default:
    call res_append
    lea rdi, [rip + registry_newline]
    call res_append
    lea rdi, [rip + res_features_prefix]
    call res_append
    xor r12d, r12d
    cmp qword ptr [rip + res_root_request_count], 0
    jne .Lres_render_features
    lea rdi, [rip + res_dash]
    call res_append
.Lres_render_features:
    cmp r12, [rip + res_root_request_count]
    jae .Lres_render_hash
    test r12, r12
    jz .Lres_render_feature_item
    lea rdi, [rip + res_comma]
    call res_append
.Lres_render_feature_item:
    lea rax, [rip + res_root_requests]
    mov rdi, [rax + r12*8]
    call res_append
    inc r12
    jmp .Lres_render_features
.Lres_render_hash:
    lea rdi, [rip + registry_newline]
    call res_append
    lea rdi, [rip + res_manifest_prefix]
    call res_append
    lea rdi, [rip + res_root_hash]
    call res_append
    lea rdi, [rip + registry_newline]
    call res_append
    /* Sort node pointers, excluding the root, by canonical package identity. */
    lea r13, [rip + res_order]
    mov r12d, 1
.Lres_order_fill:
    cmp r12, [rip + res_node_count]
    jae .Lres_order_sort_start
    mov rax, r12
    shl rax, 12
    lea rdx, [rip + res_nodes]
    add rax, rdx
    mov [r13 + r12*8 - 8], rax
    inc r12
    jmp .Lres_order_fill
.Lres_order_sort_start:
    mov r12d, 1
.Lres_order_sort:
    mov rax, [rip + res_node_count]
    dec rax
    cmp r12, rax
    jae .Lres_enabled_start
    mov r14, r12
.Lres_order_inner:
    test r14, r14
    jz .Lres_order_next
    mov rax, [r13 + r14*8 - 8]
    mov rdx, [r13 + r14*8]
    mov rdi, [rax]
    mov rsi, [rdx]
    call res_strcmp
    test eax, eax
    jle .Lres_order_next
    mov rax, [r13 + r14*8]
    mov rdx, [r13 + r14*8 - 8]
    mov [r13 + r14*8 - 8], rax
    mov [r13 + r14*8], rdx
    dec r14
    jmp .Lres_order_inner
.Lres_order_next:
    inc r12
    jmp .Lres_order_sort
.Lres_enabled_start:
    xor r12d, r12d
.Lres_enabled_node:
    cmp r12, [rip + res_node_count]
    jae .Lres_render_rows
    lea r14, [rip + res_nodes]
    test r12, r12
    jz .Lres_enabled_metadata
    mov r14, [r13 + r12*8 - 8]
.Lres_enabled_metadata:
    mov r15, [r14 + 16]
    xor ebx, ebx
.Lres_enabled_feature:
    cmp rbx, [r15 + 16]
    jae .Lres_enabled_next
    bt [r14 + 24], rbx
    jnc .Lres_enabled_feature_next
    lea rdi, [rip + res_enabled_prefix]
    call res_append
    mov rdi, [r14]
    call res_append
    lea rdi, [rip + registry_tab]
    call res_append
    mov rax, rbx
    imul rax, rax, 576
    mov rdi, [r15 + rax + 36928]
    call res_append
    lea rdi, [rip + registry_newline]
    call res_append
.Lres_enabled_feature_next:
    inc rbx
    jmp .Lres_enabled_feature
.Lres_enabled_next:
    inc r12
    jmp .Lres_enabled_node
.Lres_render_rows:
    xor r12d, r12d
.Lres_render_row:
    mov rax, [rip + res_node_count]
    dec rax
    cmp r12, rax
    jae .Lres_render_done
    mov rax, [r13 + r12*8]
    mov r14, [rax + 8]
    xor ebx, ebx
.Lres_render_field:
    mov rdi, [r14 + rbx*8]
    call res_append
    lea rdi, [rip + registry_tab]
    cmp ebx, 7
    jne .Lres_render_separator
    lea rdi, [rip + registry_newline]
.Lres_render_separator:
    call res_append
    inc ebx
    cmp ebx, 8
    jb .Lres_render_field
    inc r12
    jmp .Lres_render_row
.Lres_render_done:
    mov rax, [rip + res_render_cursor]
    lea rdx, [rip + res_rendered]
    sub rax, rdx
    mov [rip + res_render_length], rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=bounded NUL text. Append to owned1MiB+NUL buffer or fail. */
res_append:
    mov rsi, rdi
    mov rdi, [rip + res_render_cursor]
    lea rdx, [rip + res_rendered + 1048576]
.Lres_append_byte:
    mov al, [rsi]
    test al, al
    jz .Lres_append_done
    cmp rdi, rdx
    jae dependency_lock_too_large
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .Lres_append_byte
.Lres_append_done:
    mov byte ptr [rdi], 0
    mov [rip + res_render_cursor], rdi
    ret

/* Atomic publication reuses private stage and cleanup ownership. Writes all
 * bytes, fsyncs, closes, then renames once. Existing asm.lock survives failure. */
res_commit_lock:
    push r12
    call registry_workspace
    lea rdi, [rip + dependency_temp_lock]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + dependency_lock_suffix]
    call copy_string
    lea rax, [rip + dependency_temp_lock]
    mov [rip + registry_extra_temp], rax
    mov eax, SYS_open
    lea rdi, [rip + dependency_temp_lock]
    mov esi, 193 + O_NOFOLLOW + O_CLOEXEC
    mov edx, 420
    syscall
    test rax, rax
    js dependency_io_error
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + res_rendered]
    mov rdx, [rip + res_render_length]
    call write_all
    test rax, rax
    js dependency_io_error
    mov eax, 74
    mov rdi, r12
    syscall
    test rax, rax
    js dependency_io_error
    mov eax, SYS_close
    mov rdi, r12
    syscall
    test rax, rax
    js dependency_io_error
    mov eax, 82
    lea rdi, [rip + dependency_temp_lock]
    lea rsi, [rip + dependency_lock_path]
    syscall
    test rax, rax
    js dependency_io_error
    mov qword ptr [rip + registry_extra_temp], 0
    pop r12
    ret

/* Called after read_manifest by the normal build path. A resolution manifest
 * always requires a v2 lock, even without --locked. Legacy behavior unchanged. */
verify_project_dependencies:
    cmp qword ptr [rip + rm_root_metadata], 0
    jne res_verify_project
    call res_is_v2
    test eax, eax
    jnz res_lock_error
    jmp verify_legacy_project_dependencies

res_verify_project:
    mov byte ptr [rip + res_check_mode], 1
    mov edi, 5
    xor esi, esi
    call dependency_acquire
    call res_check_locked_graph
    ret

/* Sync selects its legacy/graph implementation without consuming argv. */
cmd_sync:
    call read_manifest
    cmp qword ptr [rip + rm_root_metadata], 0
    je cmd_sync_legacy
.Lres_sync_args:
    call next_arg
    test rax, rax
    jz .Lres_sync_start
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + res_opt_artifacts]
    call streq
    test eax, eax
    jnz .Lres_sync_artifacts
    mov rax, r12
    call common_option
    test eax, eax
    jz registry_bad_args
    jmp .Lres_sync_args
.Lres_sync_artifacts:
    cmp qword ptr [rip + res_artifacts], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + res_artifacts], rax
    jmp .Lres_sync_args
.Lres_sync_start:
    mov edi, 6
    mov esi, 1
    call dependency_acquire
    call res_check_locked_graph
    call release_dependency_lock
    lea rdi, [rip + res_sync_done]
    jmp res_report

/* Reconstruct and compare the entire graph from locked artifacts. No current
 * index is consulted. Verification mode refuses missing cache; sync can fetch
 * exact locked URLs. Re-rendering detects omitted, extra or edited metadata.
 * Root SHA-256 makes any manifest change require deliberate resolution. */
res_check_locked_graph:
    call res_read_v2
    call res_copy_rows
    mov rax, [rip + res_row_count]
    mov [rip + res_locked_count], rax
    call res_hash_root
    lea rdi, [rip + res_root_hash]
    mov rsi, [rip + res_lock_hash]
    call streq
    test eax, eax
    jz res_lock_error
    mov rax, [rip + res_lock_default]
    mov [rip + res_default], rax
    mov rdi, [rip + res_lock_features]
    cmp byte ptr [rdi], '-'
    jne .Lres_locked_features
    cmp byte ptr [rdi + 1], 0
    jne res_lock_error
    xor edi, edi
.Lres_locked_features:
    call res_parse_features
    call res_solve
    test eax, eax
    jz res_lock_error
    mov rax, [rip + res_node_count]
    dec rax
    cmp rax, [rip + res_locked_count]
    jne res_lock_error
    call res_render_lock
    mov rcx, [rip + res_render_length]
    cmp rcx, [rip + res_lock_length]
    jne res_lock_error
    lea rdi, [rip + res_rendered]
    lea rsi, [rip + res_lock_original]
    repe cmpsb
    jne res_lock_error
    call registry_cleanup
    ret

res_report:
    cmp byte ptr [rip + json_mode], 0
    je .Lres_report_text
    lea rdi, [rip + dependency_count_prefix]
    call out
    mov rdi, [rip + res_node_count]
    dec rdi
    lea rsi, [rip + dependency_number + 31]
    call unsigned_decimal
    mov rdi, rax
    call out
    lea rdi, [rip + dependency_result_suffix]
.Lres_report_text:
    call out
    jmp exit_ok

res_conflict_error:
    /* JSON stays structured through registry_fail; package text has already
     * passed canonical ASCII validation, so no credential-bearing input leaks. */
    lea rdi, [rip + res_conflict_buffer]
    lea rsi, [rip + res_err_conflict]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + res_conflict_name]
    test rsi, rsi
    jnz .Lres_conflict_named
    lea rsi, [rip + res_root_name]
.Lres_conflict_named:
    call copy_string
    mov rdi, rax
    lea rsi, [rip + res_reason_separator]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + res_conflict_reason]
    test rsi, rsi
    jnz .Lres_conflict_reason_ready
    lea rsi, [rip + res_reason_version]
.Lres_conflict_reason_ready:
    call copy_string
    mov rdi, rax
    cmp qword ptr [rip + res_conflict_range], 0
    je .Lres_conflict_advice
    lea rsi, [rip + res_requirement_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, [rip + res_conflict_range]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + res_requirement_suffix]
    call copy_string
    mov rdi, rax
.Lres_conflict_advice:
    lea rsi, [rip + res_err_conflict_suffix]
    call copy_string
    lea rdi, [rip + res_conflict_buffer]
    mov esi, 1
    jmp registry_fail
res_limit_error:
    lea rdi, [rip + res_err_limit]
    mov esi, 1
    jmp registry_fail
res_manifest_error:
    lea rdi, [rip + res_err_manifest]
    mov esi, 1
    jmp registry_fail
res_lock_error:
    lea rdi, [rip + res_err_lock]
    mov esi, 1
    jmp registry_fail
res_use_resolve_error:
    lea rdi, [rip + res_err_legacy]
    mov esi, 1
    jmp registry_fail

.section .rodata
res_header: .asciz "# asm-lock-v2\n"
res_default_prefix: .asciz "# default "
res_features_prefix: .asciz "# features "
res_manifest_prefix: .asciz "# manifest "
res_enabled_prefix: .asciz "# enabled "
res_true: .asciz "1"
res_false: .asciz "0"
res_dash: .asciz "-"
res_comma: .asciz ","
res_slash: .asciz "/"
res_archive_suffix: .asciz ".tar.gz"
res_opt_artifacts: .asciz "--artifacts"
res_opt_features: .asciz "--features"
res_opt_no_default: .asciz "--no-default-features"
res_done: .asciz "Resolved and locked the complete source dependency graph.\n"
res_sync_done: .asciz "Synchronized the exact locked dependency graph.\n"
res_err_limit: .asciz "dependency resolution resource limit exhausted. Reduce the graph or narrow version requirements"
res_err_manifest: .asciz "invalid dependency manifest. Check resolution schema, ranges, and feature declarations"
res_err_lock: .asciz "dependency graph lock is missing, stale, or invalid. Run asm resolve after reviewing asm.toml"
res_err_legacy: .asciz "this project uses dependency resolution. Edit asm.toml, then run asm resolve"
res_err_conflict: .asciz "cannot resolve dependency requirements or features for "
res_reason_separator: .asciz ": "
res_requirement_prefix: .asciz " (requirement "
res_requirement_suffix: .asciz ")"
res_err_conflict_suffix: .asciz ". Check version ranges, target support, features, and dependency cycles; then run asm resolve"
res_help_text:
    .ascii "Usage: asm resolve [--index PATH | --registry HTTPS_URL]\n"
    .ascii "                   [--artifacts DIR] [--features NAME,NAME] [--no-default-features]\n"
    .ascii "Declare dependencies in asm.toml with [resolution] schema = \"1\".\n"
    .ascii "Ranges: exact X.Y.Z, *, ^X.Y.Z, ~X.Y.Z, comma-separated comparisons.\n"
    .ascii "Offline archives use DIR/<sha256>.tar.gz; no network fallback occurs.\n"
    .asciz "Resolution never executes packages. Failed resolution preserves the previous lock.\n"
.section .bss
.balign 8
res_default: .skip 8
res_artifacts: .skip 8
res_cli_features: .skip 8
res_root_requests: .skip 512
res_root_request_count: .skip 8
res_feature_buffer: .skip 2113
.balign 8
res_row_count: .skip 8
res_rows: .skip 262144
res_node_count: .skip 8
res_nodes: .skip 528384
res_previous_count: .skip 8
res_previous_rows: .skip 262144
res_previous_origin: .skip 8
res_loaded_count: .skip 8
res_loaded_rows: .skip 2048
res_metadata: .skip RES_RM_SIZE * 256
res_manifests: .skip 4194560
res_probe: .skip 16
res_artifact_path: .skip 4096
res_root_hash: .skip 65
.balign 8
res_lock_default: .skip 8
res_lock_features: .skip 8
res_lock_hash: .skip 8
res_locked_count: .skip 8
res_lock_length: .skip 8
res_lock_buffer: .skip 1048578
res_lock_original: .skip 1048578
res_rendered: .skip 1048577
.balign 8
res_render_cursor: .skip 8
res_render_length: .skip 8
res_order: .skip 1024
res_conflict_buffer: .skip 1024
res_no_default_seen: .skip 1
res_check_mode: .skip 1
res_snapshot_created: .skip 1
.section .note.GNU-stack,"",@progbits
.include "cli/resolver_graph.s"
