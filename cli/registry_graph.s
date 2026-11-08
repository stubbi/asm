/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native V2 dependency metadata, complete graph locks and exact source sync.
 * SysV ABI: RDI/RSI/RDX/RCX inputs, RAX result. Preserve RBX/RBP/R12-R15.
 * Serial process-owned state; no package code or shell is executed.
 * Bounds: 4095 inventory rows, 256 reached versions/names, 64 edges/version,
 * 64 roots, 1 MiB lock. Existing transport/archive limits remain in force.
 * Mirrors are transport inputs. Registry ID and initial root bind authority.
 */
.intel_syntax noprefix
.equ R3_CANDIDATES, 256
.equ R3_NODE, 512
.equ R3_DEPS, 15360
.section .text

/* Parsed command, no selector. Resolve=5, sync=6. Changes cwd to a checked
 * project directory, takes its operation lock, and exits. No return. */
r3_command:
    cmp rdx, 4832
    jne r2_arguments
    cmp qword ptr [rip + r2_mirror_count], 0
    je r2_arguments
    mov rdi, [rip + r2_registry_id]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2_root]
    call program_valid_absolute_path
    test eax, eax
    jz r2_arguments
    mov rdi, [rip + r2_state]
    call program_valid_absolute_path
    test eax, eax
    jz r2_arguments
    cmp qword ptr [rip + r2_ca], 0
    je .Lr3_project
    mov rdi, [rip + r2_ca]
    call program_valid_absolute_path
    test eax, eax
    jz r2_arguments
.Lr3_project:
    mov rdi, [rip + r2p_project]
    mov esi, 1
    xor edx, edx
    call r2_open_path
    mov r12, rax
    mov rdi, rax
    mov eax, 81
    syscall
    test rax, rax
    js r2_io
    mov rdi, r12
    mov eax, 3
    syscall
    mov rax, [rip + r2_target]
    mov [rip + project_requested_target], rax
    call read_manifest
    mov edi, 6
    mov esi, 1
    call dependency_acquire
    mov byte ptr [rip + r3_active], 1
    call r2_workspace
    call r2_prepare_adapter
    mov rdi, [rip + r2_root]
    xor esi, esi
    mov edx, 2
    call r2_open_path
    mov rdi, rax
    mov eax, 3
    syscall
    mov rdi, [rip + r2_root]
    call r2_hash_path
    lea rdi, [rip + r2_root_sha]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    call r3_roots
    call r4_validate_selection
    call r3_read_lock
    test eax, eax
    jz .Lr3_have_lock
    cmp qword ptr [rip + r2_mode], 6
    je r3_lock_error
    jmp .Lr3_catalog
.Lr3_have_lock:
    call r3_lock_header
.Lr3_catalog:
    cmp qword ptr [rip + r2_mode], 5
    jne .Lr3_catalog_ready
    mov qword ptr [rip + r4_format], 4
.Lr3_catalog_ready:
    call r3_catalog
    cmp qword ptr [rip + r2_mode], 6
    je .Lr3_sync
    call r3_discover
    call r3_render
    call r3_preserve_bindings
    call r3_check_policy
    call r3_write_lock
    jmp .Lr3_report
.Lr3_sync:
    call r3_locked_candidates
    call r3_solve
    call r3_render
    call r3_compare_lock
    call r3_materialize
    call r3_check_policy
.Lr3_report:
    call registry_cleanup
    call release_dependency_lock
    cmp byte ptr [rip + json_mode], 0
    je exit_ok
    lea rdi, [rip + r3_result_prefix]
    call out
    mov rdi, [rip + r3_order_count]
    lea rsi, [rip + number_buffer + 31]
    call unsigned_decimal
    mov rdi, rax
    call out
    lea rdi, [rip + r3_resolved]
    cmp qword ptr [rip + r2_mode], 5
    je .Lr3_report_end
    lea rdi, [rip + r3_synchronized]
.Lr3_report_end:
    call out
    jmp exit_ok

r3_lock_error:
    lea rdi, [rip + r3_err_lock]
    jmp r3_fail
r3_metadata_error:
    lea rdi, [rip + r3_err_metadata]
    jmp r3_fail
r3_limit_error:
    lea rdi, [rip + r3_err_limit]
    jmp r3_fail
r3_unsatisfiable:
    lea rdi, [rip + r3_err_unsat]
    jmp r3_fail
r3_changed_binding:
    lea rdi, [rip + r3_err_changed]
r3_fail:
    mov esi, 1
    jmp registry_fail

/* Copy validated root declarations before archive checks overwrite the shared
 * project parser. Bind the exact root manifest, not its working directory.
 * No arguments/results. Own root_data[64*240], roots[64*16], manifest_sha[65]. */
r3_roots:
    push rbx
    push r12
    mov rax, [rip + g3_project_dep_count]
    mov [rip + g3_root_count], rax
    imul rcx, rax, 240
    lea rdi, [rip + r3_root_data]
    lea rsi, [rip + g3_project_deps]
    rep movsb
    xor ebx, ebx
    lea r12, [rip + g3_roots]
.Lr3_root_pair:
    cmp rbx, [rip + g3_root_count]
    jae .Lr3_root_hash
    imul rax, rbx, 240
    lea rdx, [rip + r3_root_data]
    add rdx, rax
    mov [r12], rdx
    add rdx, 105
    mov [r12 + 8], rdx
    add r12, 16
    inc rbx
    jmp .Lr3_root_pair
.Lr3_root_hash:
    lea rdi, [rip + r4_root_profile]
    lea rsi, [rip + g4_project_profile]
    call g4_profile_copy
    mov [rip + g4_root_profile], rax
    lea rdi, [rip + manifest_path]
    call r2_hash_path
    lea rdi, [rip + r3_manifest_sha]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    pop r12
    pop rbx
    ret

/* Existing signed policy validator calls this only after validating a row.
 * Copy its six borrowed fields. No args/result; catalog records are 256B.
 * Sorted policy names make all versions adjacent. Their package ID must stay
 * equal, including yanked/revoked rows. Bounds precede writes; stack8. */
r3_policy_row:
    push rbx
    mov rax, [rip + r3_catalog_count]
    cmp rax, 4095
    jae r3_limit_error
    shl rax, 8
    lea rbx, [rip + r3_inventory]
    add rbx, rax
    cmp qword ptr [rip + r3_catalog_count], 0
    je .Lr3_policy_copy
    lea rdi, [rbx - 256]
    mov rsi, [rip + r2_policy_fields]
    call streq
    test eax, eax
    jz .Lr3_policy_copy
    lea rdi, [rbx - 256 + 138]
    mov rsi, [rip + r2_policy_fields + 16]
    call streq
    test eax, eax
    jz r3_changed_binding
.Lr3_policy_copy:
    mov rdi, rbx
    mov rsi, [rip + r2_policy_fields]
    call copy_string
    lea rdi, [rbx + 105]
    mov rsi, [rip + r2_policy_fields + 8]
    call copy_string
    lea rdi, [rbx + 138]
    mov rsi, [rip + r2_policy_fields + 16]
    call copy_string
    lea rdi, [rbx + 171]
    mov rsi, [rip + r2_policy_fields + 24]
    call copy_string
    mov byte ptr [rbx + 204], 0
    mov rax, [rip + r2_policy_fields + 32]
    cmp byte ptr [rax], '0'
    jne .Lr3_policy_row_end
    mov rax, [rip + r2_policy_fields + 40]
    cmp byte ptr [rax], '0'
    jne .Lr3_policy_row_end
    mov byte ptr [rbx + 204], 1
.Lr3_policy_row_end:
    inc qword ptr [rip + r3_catalog_count]
    pop rbx
    ret

r3_catalog:
    sub rsp, 8
    mov qword ptr [rip + r3_catalog_count], 0
    call r2_load_policy
    add rsp, 8
    ret

/* RDI=name, RSI=version. Return RAX=inventory record or zero. Read only.
 * Callee registers and inputs are preserved across string comparisons. */
r3_find_inventory:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + r3_inventory]
    xor r14d, r14d
.Lr3_find_row:
    cmp r14, [rip + r3_catalog_count]
    jae .Lr3_find_none
    mov rdi, rbx
    mov rsi, r12
    call streq
    test eax, eax
    jz .Lr3_find_next
    lea rdi, [rbx + 105]
    mov rsi, r13
    call streq
    test eax, eax
    jnz .Lr3_find_yes
.Lr3_find_next:
    inc r14
    add rbx, 256
    jmp .Lr3_find_row
.Lr3_find_none:
    xor eax, eax
    jmp .Lr3_find_return
.Lr3_find_yes:
    mov rax, rbx
.Lr3_find_return:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Add one validated name to a bounded unique discovery queue. RDI=name.
 * Names are copied, so later JSON parsing and policy refresh cannot alter it. */
r3_name:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor ebx, ebx
    lea r13, [rip + r3_names]
.Lr3_name_find:
    cmp rbx, [rip + r3_name_count]
    jae .Lr3_name_append
    mov rdi, r13
    mov rsi, r12
    call streq
    test eax, eax
    jnz .Lr3_name_end
    inc rbx
    add r13, 105
    jmp .Lr3_name_find
.Lr3_name_append:
    cmp rbx, R3_CANDIDATES
    jae r3_limit_error
    mov rdi, r13
    mov rsi, r12
    call copy_string
    lea rdx, [rip + g4_known_names]
    mov [rdx + rbx*8], r13
    inc qword ptr [rip + r3_name_count]
    inc qword ptr [rip + g4_known_count]
.Lr3_name_end:
    pop r13
    pop r12
    pop rbx
    ret

/* Demand-driven discovery loads all active versions only when an active
 * solver branch requires that name. Unknown and known-empty names differ.
 * The aggregate 100000-step budget covers every retry, including validation.
 * No source blob is read. Network errors never become unsatisfiability. */
r3_discover:
    push rbx
    push r12
    push r13
    push r14
    mov qword ptr [rip + g4_lazy], 1
    mov qword ptr [rip + r4_steps], 0
.Lr3_discover_solve:
    mov eax, 100000
    sub rax, [rip + r4_steps]
    jbe r3_limit_error
    mov [rip + g3_limit], rax
    call g3_solve
    mov ebx, eax
    mov rax, [rip + g3_steps]
    add [rip + r4_steps], rax
    cmp ebx, 4
    jne .Lr3_discover_result
    mov rdi, [rip + g4_missing_name]
    call r3_name
    mov rax, [rip + r3_name_count]
    dec rax
    imul rax, rax, 105
    lea r12, [rip + r3_names]
    add r12, rax
    lea r13, [rip + r3_inventory]
    xor r14d, r14d
.Lr3_discover_version:
    cmp r14, [rip + r3_catalog_count]
    jae .Lr3_discover_solve
    cmp byte ptr [r13 + 204], 1
    jne .Lr3_discover_next_version
    mov rdi, r12
    mov rsi, r13
    call streq
    test eax, eax
    jz .Lr3_discover_next_version
    mov rdi, r13
    call r3_candidate
.Lr3_discover_next_version:
    inc r14
    add r13, 256
    jmp .Lr3_discover_version
.Lr3_discover_result:
    cmp ebx, 1
    je r3_unsatisfiable
    cmp ebx, 2
    je r3_limit_error
    test ebx, ebx
    jnz r3_metadata_error
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=validated active inventory record. Authenticate its exact envelope and
 * own its fields and dependencies. Append one solver candidate (40B).
 * All repeated-envelope parser state is reset. Stack48 plus callees. */
r3_candidate:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi
    mov r12, [rip + g3_candidate_count]
    cmp r12, R3_CANDIDATES
    jae r3_limit_error
    mov rax, r12
    shl rax, 9
    lea rbx, [rip + r3_records]
    add rbx, rax
    mov rdi, rbx
    mov rsi, r15
    call copy_string
    lea rdi, [rbx + 105]
    lea rsi, [r15 + 105]
    call copy_string
    lea rdi, [rbx + 138]
    lea rsi, [r15 + 138]
    call copy_string
    lea rdi, [rbx + 171]
    lea rsi, [r15 + 171]
    call copy_string
    lea rdi, [rip + r2_requested_name]
    mov rsi, rbx
    call copy_string
    lea rdi, [rip + r2_requested_version]
    lea rsi, [rbx + 105]
    call copy_string
    lea rax, [rip + registry_source_kind]
    mov [rip + r2_kind], rax
    mov qword ptr [rip + r2_object_count], 0
    mov qword ptr [rip + r2_total_bytes], 0
    mov qword ptr [rip + r2_tuple_bits], 0
    mov qword ptr [rip + r2_selected], 0
    mov byte ptr [rip + r2_repository], 0
    call r2_release_target
    lea rdi, [rip + registry_temp_index]
    call r2_get_target
    test eax, eax
    jnz r3_metadata_error
    lea rdi, [rip + registry_temp_index]
    call r2_hash_path
    lea rdi, [rbx + 204]
    lea rsi, [rip + pub_hash_buffer]
    call copy_string
    lea rdi, [rip + registry_temp_index]
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_envelope]
    mov edx, R2_CONTROL
    call r2_read_fd
    mov [rip + r4_envelope_length], rax
    mov rsi, rax
    lea rdi, [rip + r2_envelope]
    call r2_parse_json
    mov rdi, rax
    call r2_validate_envelope
    lea rdi, [rbx + 138]
    lea rsi, [rip + r2_package_id]
    call streq
    test eax, eax
    jz r3_metadata_error
    lea rdi, [rbx + 171]
    lea rsi, [rip + r2_release_id]
    call streq
    test eax, eax
    jz r3_metadata_error
.Lr4_candidate_record:
    lea rdi, [rbx + 269]
    lea rsi, [rip + r2_manifest_sha]
    call copy_string
    lea rdi, [rbx + 334]
    lea rsi, [rip + r2_commit]
    call copy_string
    lea rdi, [rbx + 431]
    lea rsi, [rip + r2_source_sha]
    call copy_string
    mov rdi, [rip + r2_source_bytes]
    lea rsi, [rip + r2_size_decimal + 31]
    call unsigned_decimal
    mov rsi, rax
    lea rdi, [rbx + 399]
    call copy_string
    imul rax, r12, 40
    lea r13, [rip + g3_candidates]
    add r13, rax
    mov [r13], rbx
    lea rax, [rbx + 105]
    mov [r13 + 8], rax
    mov rax, r12
    shl rax, 10
    lea r14, [rip + r3_pairs]
    add r14, rax
    mov [r13 + 16], r14
    mov rax, [rip + r2_dependency_count]
    mov [r13 + 24], rax
    mov rax, [rip + r2_selected]
    mov [r13 + 32], rax
    imul rax, r12, R3_DEPS
    lea r15, [rip + r3_dependency_data]
    add r15, rax
    mov rdi, r15
    lea rsi, [rip + r2_dependencies]
    imul rcx, [rip + r2_dependency_count], 240
    rep movsb
    imul rax, r12, G4_PROFILE_SIZE
    lea rdi, [rip + r4_profiles]
    add rdi, rax
    lea rsi, [rip + g4_publication_profile]
    call g4_profile_copy
    lea rdx, [rip + g4_profiles]
    mov [rdx + r12*8], rax
    cmp qword ptr [rip + r4_format], 3
    jne .Lr4_candidate_complex_ok
    mov rdx, [r13 + 24]
    call r4_legacy_profile
.Lr4_candidate_complex_ok:
    cmp qword ptr [rip + r2_mode], 6
    jne .Lr4_candidate_no_save
    cmp byte ptr [rip + r3_local], 0
    jne .Lr4_candidate_no_save
    mov rdi, r12
    call r4_metadata_save
.Lr4_candidate_no_save:
    xor ebp, ebp
.Lr3_candidate_dep:
    cmp rbp, [r13 + 24]
    jae .Lr3_candidate_end
    mov [r14], r15
    lea rax, [r15 + 105]
    mov [r14 + 8], rax
    add r14, 16
    add r15, 240
    inc rbp
    jmp .Lr3_candidate_dep
.Lr3_candidate_end:
    inc qword ptr [rip + g3_candidate_count]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Solve once after complete metadata discovery. Result flags belong to the
 * solver; resource failure never reports a graph as unsatisfiable. */
r3_solve:
    sub rsp, 8
    mov qword ptr [rip + g4_lazy], 0
    mov qword ptr [rip + g3_limit], 100000
    call g3_solve
    cmp eax, 1
    je r3_unsatisfiable
    cmp eax, 2
    je r3_limit_error
    test eax, eax
    jnz r3_metadata_error
    add rsp, 8
    ret

/* Read an existing regular lock into independent raw and parsing buffers.
 * EAX=0 present,1 absent. Reject NUL/CR/control bytes and missing final LF.
 * Keep raw bytes for exact comparison; line splitting owns only the copy. */
r3_read_lock:
    push rbx
    mov eax, 6
    lea rdi, [rip + dependency_lock_path]
    lea rsi, [rip + dependency_stat]
    syscall
    cmp rax, -2
    je .Lr3_lock_absent
    test rax, rax
    js r3_lock_error
    lea rdi, [rip + dependency_lock_path]
    xor esi, esi
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r3_old_lock]
    mov edx, INDEX_LIMIT
    call r2_read_fd
    test rax, rax
    jz r3_lock_error
    mov [rip + r3_old_length], rax
    lea rdi, [rip + r3_old_lock]
    cmp byte ptr [rdi + rax - 1], 10
    jne r3_lock_error
    xor ebx, ebx
.Lr3_lock_ascii:
    cmp rbx, [rip + r3_old_length]
    jae .Lr3_lock_copy
    movzx eax, byte ptr [rdi + rbx]
    cmp al, 9
    je .Lr3_lock_ascii_next
    cmp al, 10
    je .Lr3_lock_ascii_next
    cmp al, 32
    jb r3_lock_error
    cmp al, 126
    ja r3_lock_error
.Lr3_lock_ascii_next:
    inc rbx
    jmp .Lr3_lock_ascii
.Lr3_lock_copy:
    call r3_parse_reset
    xor eax, eax
    pop rbx
    ret
.Lr3_lock_absent:
    mov qword ptr [rip + r3_old_length], 0
    mov eax, 1
    pop rbx
    ret

r3_parse_reset:
    lea rdi, [rip + r3_parse_buffer]
    lea rsi, [rip + r3_old_lock]
    mov rcx, [rip + r3_old_length]
    rep movsb
    lea rax, [rip + r3_parse_buffer]
    mov [rip + r3_cursor], rax
    add rax, [rip + r3_old_length]
    mov [rip + r3_end], rax
    ret

/* Split one line into <=11 borrowed fields. Return field count, zero at EOF.
 * Input is already ASCII bounded. Empty fields and rows are invalid. */
r3_line:
    mov rdi, [rip + r3_cursor]
    cmp rdi, [rip + r3_end]
    jae .Lr3_line_eof
    lea rdx, [rip + r3_fields]
    mov [rdx], rdi
    mov eax, 1
    mov rsi, rdi
.Lr3_line_byte:
    cmp rdi, [rip + r3_end]
    jae r3_lock_error
    cmp byte ptr [rdi], 10
    je .Lr3_line_end
    cmp byte ptr [rdi], 9
    jne .Lr3_line_next
    cmp rdi, rsi
    je r3_lock_error
    cmp eax, 11
    jae r3_lock_error
    mov byte ptr [rdi], 0
    lea rsi, [rdi + 1]
    mov [rdx + rax*8], rsi
    inc eax
.Lr3_line_next:
    inc rdi
    jmp .Lr3_line_byte
.Lr3_line_end:
    cmp rdi, rsi
    je r3_lock_error
    mov byte ptr [rdi], 0
    inc rdi
    mov [rip + r3_cursor], rdi
    ret
.Lr3_line_eof:
    xor eax, eax
    ret

/* Validate authority/target before resolve can replace an existing graph.
 * Local build loads the recorded authority but never authenticates it here.
 * Sync requires the root manifest digest to remain identical. */
r3_lock_header:
    push rbx
    call r3_line
    cmp eax, 1
    jne r3_lock_error
    mov qword ptr [rip + r4_format], 3
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r3_header_line]
    call streq
    test eax, eax
    jnz .Lr4_header_known
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r4_header_line]
    call streq
    test eax, eax
    jz r3_lock_error
    mov qword ptr [rip + r4_format], 4
.Lr4_header_known:
    call r3_line
    cmp eax, 5
    jne r3_lock_error
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r3_registry_word]
    call streq
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 8]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 16]
    mov esi, 64
    call r2_hex
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 32]
    mov esi, 64
    call r2_hex
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 24]
    mov rsi, [rip + r2_target]
    call streq
    test eax, eax
    jz r3_lock_error
    cmp byte ptr [rip + r3_local], 0
    je .Lr3_header_remote
    lea rdi, [rip + r3_local_id]
    mov rsi, [rip + r3_fields + 8]
    call copy_string
    lea rax, [rip + r3_local_id]
    mov [rip + r2_registry_id], rax
    lea rdi, [rip + r2_root_sha]
    mov rsi, [rip + r3_fields + 16]
    call copy_string
    jmp .Lr3_header_manifest
.Lr3_header_remote:
    mov rdi, [rip + r3_fields + 8]
    mov rsi, [rip + r2_registry_id]
    call streq
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 16]
    lea rsi, [rip + r2_root_sha]
    call streq
    test eax, eax
    jz r3_lock_error
    cmp qword ptr [rip + r2_mode], 5
    je .Lr3_header_done
.Lr3_header_manifest:
    mov rdi, [rip + r3_fields + 32]
    lea rsi, [rip + r3_manifest_sha]
    call streq
    test eax, eax
    jz r3_lock_error
.Lr3_header_done:
    cmp qword ptr [rip + r2_mode], 5
    je .Lr4_header_return
    cmp qword ptr [rip + r4_format], 4
    je .Lr4_header_selection
    mov rax, [rip + g4_root_profile]
    mov rdx, [rip + g3_root_count]
    call r4_legacy_profile
    jmp .Lr4_header_return
.Lr4_header_selection:
    call r4_read_selection
.Lr4_header_return:
    pop rbx
    ret

/* Sync loads ONLY named versions in the retained lock. Regeneration after
 * solving checks every root, node and edge against authenticated metadata. */
r3_locked_candidates:
    push rbx
    push r12
.Lr3_locked_line:
    call r3_line
    test eax, eax
    jz .Lr3_locked_done
    mov ebx, eax
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r3_node_word]
    call streq
    test eax, eax
    jz .Lr3_locked_line
    cmp ebx, 10
    jne r3_lock_error
    mov rdi, [rip + r3_fields + 8]
    call registry_valid_package
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 16]
    call registry_valid_version
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 8]
    mov rsi, [rip + r3_fields + 16]
    call r3_find_inventory
    test rax, rax
    jz r3_metadata_error
    cmp byte ptr [rax + 204], 1
    jne r3_metadata_error
    mov rdi, rax
    call r3_candidate
    jmp .Lr3_locked_line
.Lr3_locked_done:
    pop r12
    pop rbx
    ret

/* Stable selected-node ordering by package bytes, independent of inventory
 * or search order. The solver already enforces one version per package. */
r3_sort:
    push rbx
    push r12
    push r13
    push r14
    mov qword ptr [rip + r3_order_count], 0
    xor ebx, ebx
.Lr3_sort_candidate:
    cmp rbx, [rip + g3_candidate_count]
    jae .Lr3_sort_done
    lea rax, [rip + g3_solution]
    cmp byte ptr [rax + rbx], 1
    jne .Lr3_sort_next
    mov r12, [rip + r3_order_count]
    lea r13, [rip + r3_order]
.Lr3_sort_insert:
    test r12, r12
    jz .Lr3_sort_store
    mov r14, [r13 + r12*8 - 8]
    mov rax, r14
    shl rax, 9
    lea rdi, [rip + r3_records]
    add rdi, rax
    mov rax, rbx
    shl rax, 9
    lea rsi, [rip + r3_records]
    add rsi, rax
    call r2_lex
    test eax, eax
    js .Lr3_sort_store
    jz r3_lock_error
    mov [r13 + r12*8], r14
    dec r12
    jmp .Lr3_sort_insert
.Lr3_sort_store:
    mov [r13 + r12*8], rbx
    inc qword ptr [rip + r3_order_count]
.Lr3_sort_next:
    inc rbx
    jmp .Lr3_sort_candidate
.Lr3_sort_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Append one NUL string to the <=1MiB canonical lock. RSI=input, ownership
 * stays with caller. Preserves callee registers, RDI/RCX/RAX are scratch. */
r3_append:
    push rbx
    push r12
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rbx, [rip + r3_length]
    lea rdx, [rbx + rax]
    cmp rdx, INDEX_LIMIT
    ja r3_limit_error
    mov [rip + r3_length], rdx
    mov rcx, rax
    lea rdi, [rip + r3_buffer]
    add rdi, rbx
    mov rsi, r12
    rep movsb
    pop r12
    pop rbx
    ret

r3_tab:
    lea rsi, [rip + registry_tab]
    jmp r3_append
r3_lf:
    lea rsi, [rip + registry_newline]
    jmp r3_append

/* Serialize complete roots, selected immutable node bindings and every edge.
 * Uses bounded append and byte-sorted declarations. No external effects. */
r3_render:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    call r3_sort
    mov qword ptr [rip + r3_length], 0
    lea rsi, [rip + r3_header]
    cmp qword ptr [rip + r4_format], 3
    je .Lr4_render_header
    lea rsi, [rip + r4_header]
.Lr4_render_header:
    call r3_append
    lea rsi, [rip + r3_registry_word]
    call r3_append
    call r3_tab
    mov rsi, [rip + r2_registry_id]
    call r3_append
    call r3_tab
    lea rsi, [rip + r2_root_sha]
    call r3_append
    call r3_tab
    mov rsi, [rip + r2_target]
    call r3_append
    call r3_tab
    lea rsi, [rip + r3_manifest_sha]
    call r3_append
    call r3_lf
    cmp qword ptr [rip + r4_format], 4
    jne .Lr4_render_roots
    call r4_render_selection
.Lr4_render_roots:
    lea r12, [rip + g3_roots]
    xor ebx, ebx
.Lr3_render_root:
    cmp rbx, [rip + g3_root_count]
    jae .Lr3_render_nodes_start
    bt qword ptr [rip + g4_root_deps], rbx
    jnc .Lr4_render_root_next
    lea rsi, [rip + r3_root_word]
    call r3_append
    call r3_tab
    mov rsi, [r12]
    call r3_append
    call r3_tab
    mov rsi, [r12 + 8]
    call r3_append
    call r3_lf
.Lr4_render_root_next:
    add r12, 16
    inc rbx
    jmp .Lr3_render_root
.Lr3_render_nodes_start:
    xor ebx, ebx
    lea r15, [rip + r3_order]
.Lr3_render_node:
    cmp rbx, [rip + r3_order_count]
    jae .Lr3_render_edges_start
    mov rax, [r15 + rbx*8]
    shl rax, 9
    lea r12, [rip + r3_records]
    add r12, rax
    lea rsi, [rip + r3_node_word]
    call r3_append
    lea r13, [rip + r3_offsets]
    xor ebp, ebp
.Lr3_render_node_field:
    call r3_tab
    mov rsi, [r13 + rbp*8]
    add rsi, r12
    call r3_append
    inc rbp
    cmp ebp, 9
    jb .Lr3_render_node_field
    call r3_lf
    inc rbx
    jmp .Lr3_render_node
.Lr3_render_edges_start:
    cmp qword ptr [rip + r4_format], 4
    jne .Lr4_render_edges
    call r4_render_node_features
.Lr4_render_edges:
    xor ebx, ebx
.Lr3_render_parent:
    cmp rbx, [rip + r3_order_count]
    jae .Lr3_render_done
    mov rax, [r15 + rbx*8]
    mov rdx, rax
    shl rdx, 9
    lea r12, [rip + r3_records]
    add r12, rdx
    imul rax, rax, 40
    lea r13, [rip + g3_candidates]
    add r13, rax
    mov r14, [r13 + 16]
    xor ebp, ebp
.Lr3_render_edge:
    cmp rbp, [r13 + 24]
    jae .Lr3_render_parent_next
    mov rax, [r15 + rbx*8]
    lea rdx, [rip + g4_active_deps]
    mov rax, [rdx + rax*8]
    bt rax, rbp
    jnc .Lr4_render_edge_next
    lea rsi, [rip + r3_edge_word]
    call r3_append
    call r3_tab
    mov rsi, r12
    call r3_append
    call r3_tab
    mov rsi, [r14]
    call r3_append
    call r3_tab
    mov rsi, [r14 + 8]
    call r3_append
    call r3_lf
.Lr4_render_edge_next:
    add r14, 16
    inc rbp
    jmp .Lr3_render_edge
.Lr3_render_parent_next:
    inc rbx
    jmp .Lr3_render_parent
.Lr3_render_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

r3_compare_lock:
    mov rcx, [rip + r3_length]
    cmp rcx, [rip + r3_old_length]
    jne r3_lock_error
    lea rsi, [rip + r3_old_lock]
    lea rdi, [rip + r3_buffer]
    repe cmpsb
    jne r3_lock_error
    ret

/* Compare retained history before explicit resolve can replace asm.lock.
 * No arguments. Old lock<=1MiB; parse-copy fields borrow that owned buffer.
 * A retained name keeps its package ID across versions. The same name/version
 * keeps all nine node values, including signed metadata and source bindings.
 * Removed names are permitted. Reads<=256 old nodes and<=256 new selections;
 * no package, cache or lock bytes change. Preserves callee registers; stack40. */
r3_preserve_bindings:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp qword ptr [rip + r3_old_length], 0
    je .Lr3_preserve_done
    call r3_parse_reset
    call r3_lock_header
    xor ebx, ebx
    lea r15, [rip + r3_offsets]
.Lr3_preserve_line:
    call r3_line
    test eax, eax
    jz .Lr3_preserve_done
    mov r14d, eax
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r3_node_word]
    call streq
    test eax, eax
    jz .Lr3_preserve_line
    cmp r14d, 10
    jne r3_lock_error
    inc ebx
    cmp ebx, R3_CANDIDATES
    ja r3_lock_error
    xor r12d, r12d
.Lr3_preserve_selection:
    cmp r12, [rip + r3_order_count]
    jae .Lr3_preserve_line
    lea rdx, [rip + r3_order]
    mov rax, [rdx + r12*8]
    shl rax, 9
    lea r13, [rip + r3_records]
    add r13, rax
    mov rdi, r13
    mov rsi, [rip + r3_fields + 8]
    call streq
    test eax, eax
    jz .Lr3_preserve_next_selection
    lea rdi, [r13 + 138]
    mov rsi, [rip + r3_fields + 24]
    call streq
    test eax, eax
    jz r3_changed_binding
    lea rdi, [r13 + 105]
    mov rsi, [rip + r3_fields + 16]
    call streq
    test eax, eax
    jz .Lr3_preserve_line
    xor r14d, r14d
.Lr3_preserve_field:
    mov rdi, [r15 + r14*8]
    add rdi, r13
    lea rdx, [rip + r3_fields + 8]
    mov rsi, [rdx + r14*8]
    call streq
    test eax, eax
    jz r3_changed_binding
    inc r14d
    cmp r14d, 9
    jb .Lr3_preserve_field
    jmp .Lr3_preserve_line
.Lr3_preserve_next_selection:
    inc r12
    jmp .Lr3_preserve_selection
.Lr3_preserve_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Finalize a resolved graph through private staging, fsync, and rename. A
 * failed write leaves the previous asm.lock intact; cache is unaffected. */
r3_write_lock:
    push rbx
    lea rdi, [rip + dependency_temp_lock]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + dependency_lock_suffix]
    call copy_string
    lea rax, [rip + dependency_temp_lock]
    mov [rip + registry_extra_temp], rax
    mov rdi, rax
    lea rsi, [rip + r3_buffer]
    mov rdx, [rip + r3_length]
    call r2_write_file
    lea rdi, [rip + dependency_temp_lock]
    mov esi, O_NOFOLLOW + O_CLOEXEC
    xor edx, edx
    mov eax, 2
    syscall
    test rax, rax
    js r2_io
    mov rbx, rax
    mov rdi, rax
    mov eax, 74
    syscall
    test rax, rax
    js r2_io
    mov rdi, rbx
    mov eax, 3
    syscall
    test rax, rax
    js r2_io
    lea rdi, [rip + dependency_temp_lock]
    lea rsi, [rip + dependency_lock_path]
    mov eax, 82
    syscall
    test rax, rax
    js r2_io
    mov qword ptr [rip + registry_extra_temp], 0
    pop rbx
    ret

/* Fresh policy must still admit EVERY selected identity, not just the last
 * parsed global envelope. Refresh never changes candidate/lock selections. */
r3_check_policy:
    push rbx
    push r12
    call r3_catalog
    xor ebx, ebx
.Lr3_check_node:
    cmp rbx, [rip + r3_order_count]
    jae .Lr3_check_done
    lea rdx, [rip + r3_order]
    mov rax, [rdx + rbx*8]
    shl rax, 9
    lea r12, [rip + r3_records]
    add r12, rax
    mov rdi, r12
    lea rsi, [r12 + 105]
    call r3_find_inventory
    test rax, rax
    jz r3_metadata_error
    cmp byte ptr [rax + 204], 1
    jne r3_metadata_error
    lea rdi, [rax + 138]
    lea rsi, [r12 + 138]
    call streq
    test eax, eax
    jz r3_metadata_error
    mov rdi, r12
    lea rsi, [r12 + 105]
    call r3_find_inventory
    lea rdi, [rax + 171]
    lea rsi, [r12 + 171]
    call streq
    test eax, eax
    jz r3_metadata_error
    inc rbx
    jmp .Lr3_check_node
.Lr3_check_done:
    pop r12
    pop rbx
    ret

/* RDI=candidate index. Build the existing eight-pointer source-cache row.
 * Also restore exact global selection fields needed by digest GET tagging.
 * No untrusted URL is accepted: all artifact requests derive from mirrors. */
r3_row:
    push rbx
    mov rax, rdi
    shl rax, 9
    lea rbx, [rip + r3_records]
    add rbx, rax
    lea rdx, [rip + r3_cache_row]
    mov [rdx], rbx
    lea rax, [rbx + 105]
    mov [rdx + 8], rax
    mov rax, [rip + r2_target]
    mov [rdx + 16], rax
    lea rax, [rip + registry_source_kind]
    mov [rdx + 24], rax
    mov [rip + r2_kind], rax
    lea rax, [rbx + 431]
    mov [rdx + 32], rax
    lea rax, [rip + r3_local_url]
    mov [rdx + 40], rax
    lea rax, [rbx + 399]
    mov [rdx + 48], rax
    lea rax, [rip + r3_source_note]
    mov [rdx + 56], rax
    mov [rip + registry_selected], rdx
    mov rdi, [rdx + 48]
    call registry_size_value
    test rax, rax
    jz r3_lock_error
    mov [rip + registry_expected_size], rax
    mov [rip + r2_selected_bytes], rax
    lea rdi, [rip + r2_selected_sha]
    lea rsi, [rbx + 431]
    call copy_string
    lea rdi, [rip + r2_name]
    mov rsi, rbx
    call copy_string
    lea rdi, [rip + r2_version]
    lea rsi, [rbx + 105]
    call copy_string
    lea rdi, [rip + r2_package_id]
    lea rsi, [rbx + 138]
    call copy_string
    lea rdi, [rip + r2_release_id]
    lea rsi, [rbx + 171]
    call copy_string
    pop rbx
    ret

/* Restore checked cached bytes when present. RAX=0 copied,1 absent/corrupt.
 * Symlinks and nonregular cache entries are errors, never replacement targets.
 * Hash and declared length both match before a cache hit is accepted. */
r3_cached:
    sub rsp, 8
    mov eax, 6
    lea rdi, [rip + dependency_archive_path]
    lea rsi, [rip + dependency_stat]
    syscall
    cmp rax, -2
    je .Lr3_cache_miss
    test rax, rax
    js dependency_io_error
    mov eax, [rip + dependency_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne dependency_cache_changed
    mov rax, [rip + dependency_stat + 48]
    cmp rax, [rip + registry_expected_size]
    jne .Lr3_cache_miss
    lea rax, [rip + dependency_archive_path]
    mov [rip + registry_local_artifact], rax
    call registry_copy_local
    lea rdi, [rip + registry_temp_payload]
    call r2_hash_path
    lea rdi, [rip + pub_hash_buffer]
    lea rsi, [rip + r2_selected_sha]
    call streq
    test eax, eax
    jz .Lr3_cache_miss
    xor eax, eax
    add rsp, 8
    ret
.Lr3_cache_miss:
    mov eax, 1
    add rsp, 8
    ret

/* RDI=candidate index. The most recent source validator produced sorted
 * project dependency records. Compare those with the signed/locked edges. */
r3_source_dependencies:
    sub rsp, 8
    lea rdx, [rip + g4_profiles]
    mov rdx, [rdx + rdi*8]
    mov rax, rdi
    imul rax, rax, 40
    lea rcx, [rip + g3_candidates]
    add rcx, rax
    mov rsi, [rcx + 24]
    imul rax, rdi, R3_DEPS
    lea rdi, [rip + r3_dependency_data]
    add rdi, rax
    call g4_compare_project
    test eax, eax
    jnz r3_lock_error
    add rsp, 8
    ret

/* Exact sync, no solving or archive execution. Validate source declarations
 * before extraction. Existing files must match; only missing trees are added.
 * Unreferenced verified cache entries may remain if a later operation fails. */
r3_materialize:
    push rbx
    push r12
    push r13
    call r3_check_policy
    xor ebx, ebx
.Lr3_materialize_node:
    cmp rbx, [rip + r3_order_count]
    jae .Lr3_materialize_done
    lea rdx, [rip + r3_order]
    mov r12, [rdx + rbx*8]
    mov rdi, r12
    call r3_row
    mov edi, 1
    call dependency_paths
    call r3_cached
    test eax, eax
    jz .Lr3_materialize_validate
    call r2_download_blob
    test eax, eax
    jnz r3_metadata_error
.Lr3_materialize_validate:
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + r2_name]
    lea rdx, [rip + r2_version]
    mov rcx, [rip + r2_target]
    call validate_v2_source_package
    test eax, eax
    jnz dependency_archive_error
    mov rdi, r12
    call r3_source_dependencies
    call r3_check_policy
    call dependency_accept_validated_payload
    inc rbx
    jmp .Lr3_materialize_node
.Lr3_materialize_done:
    pop r13
    pop r12
    pop rbx
    ret

/* Local build hook. RAX=1 graph checked,0 legacy/no lock. A declared V2
 * dependency cannot be silently ignored without a complete graph lock.
 * Shared operation lock stays held until the build releases it. This verifies
 * local bytes/closure; only registry sync authenticates current remote policy. */
r3_verify_project:
    push rbx
    push r12
    push r13
    call r3_read_lock
    test eax, eax
    jnz .Lr3_verify_legacy
    lea rdi, [rip + r3_old_lock]
    lea rsi, [rip + r3_header]
    call dependency_prefix
    test rax, rax
    jnz .Lr4_verify_graph
    lea rdi, [rip + r3_old_lock]
    lea rsi, [rip + r4_header]
    call dependency_prefix
    test rax, rax
    jz .Lr3_verify_legacy
.Lr4_verify_graph:
    mov byte ptr [rip + r3_active], 1
    mov byte ptr [rip + r3_local], 1
    lea rax, [rip + package_target]
    mov [rip + r2_target], rax
    call r3_roots
    mov edi, 5
    mov esi, 1
    call dependency_acquire
    call r3_read_lock
    test eax, eax
    jnz r3_lock_error
    call r3_lock_header
    call r3_local_candidates
    mov qword ptr [rip + g4_lazy], 0
    mov qword ptr [rip + g3_limit], 100000
    call g3_solve
    test eax, eax
    jnz r3_lock_error
    call r3_render
    call r3_compare_lock
    xor ebx, ebx
.Lr3_verify_node:
    cmp rbx, [rip + r3_order_count]
    jae .Lr3_verify_done
    lea rdx, [rip + r3_order]
    mov r12, [rdx + rbx*8]
    mov rdi, r12
    call r3_row
    xor edi, edi
    call dependency_paths
    call registry_workspace
    call r3_cached
    test eax, eax
    jnz dependency_cache_missing
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + r2_name]
    lea rdx, [rip + r2_version]
    mov rcx, [rip + r2_target]
    call validate_v2_source_package
    test eax, eax
    jnz dependency_archive_error
    mov rdi, r12
    call r3_source_dependencies
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + dependency_package_path]
    call verify_source_archive
    test eax, eax
    jnz dependency_cache_changed
    call registry_cleanup
    inc rbx
    jmp .Lr3_verify_node
.Lr3_verify_done:
    mov eax, 1
    jmp .Lr3_verify_return
.Lr3_verify_legacy:
    cmp qword ptr [rip + g4_project_profile + 16], 0
    jne r3_lock_error
    cmp qword ptr [rip + g3_project_dep_count], 0
    jne r3_lock_error
    xor eax, eax
.Lr3_verify_return:
    pop r13
    pop r12
    pop rbx
    ret

/* Load node and edge declarations from the local project-controlled lock.
 * Structural checks plus canonical regeneration reject duplicate/orphan nodes,
 * unsorted edges, omitted roots, extra rows and malformed constraints. */
r3_local_candidates:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
.Lr3_local_node_line:
    call r3_line
    test eax, eax
    jz .Lr3_local_edges_start
    mov ebp, eax
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r3_node_word]
    call streq
    test eax, eax
    jz .Lr3_local_node_line
    cmp ebp, 10
    jne r3_lock_error
    mov r12, [rip + g3_candidate_count]
    cmp r12, R3_CANDIDATES
    jae r3_limit_error
    mov rax, r12
    shl rax, 9
    lea rbx, [rip + r3_records]
    add rbx, rax
    lea r13, [rip + r3_offsets]
    lea r14, [rip + r3_capacities]
    xor r15d, r15d
.Lr3_local_node_field:
    lea rdx, [rip + r3_fields + 8]
    mov rdi, [rdx + r15*8]
    call strlen
    cmp rax, [r14 + r15*8]
    jae r3_lock_error
    mov rdi, [r13 + r15*8]
    add rdi, rbx
    lea rdx, [rip + r3_fields + 8]
    mov rsi, [rdx + r15*8]
    call copy_string
    inc r15
    cmp r15, 9
    jb .Lr3_local_node_field
    mov rdi, rbx
    call registry_valid_package
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 105]
    call registry_valid_version
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 138]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 171]
    mov esi, 32
    call r2_hex
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 204]
    mov esi, 64
    call r2_hex
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 269]
    mov esi, 64
    call r2_hex
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 431]
    mov esi, 64
    call r2_hex
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 334]
    call strlen
    cmp eax, 40
    je .Lr3_local_commit
    cmp eax, 64
    jne r3_lock_error
.Lr3_local_commit:
    mov esi, eax
    lea rdi, [rbx + 334]
    call r2_hex
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 399]
    call registry_size_value
    test rax, rax
    jz r3_lock_error
    imul rax, r12, 40
    lea r13, [rip + g3_candidates]
    add r13, rax
    mov [r13], rbx
    lea rax, [rbx + 105]
    mov [r13 + 8], rax
    mov rax, r12
    shl rax, 10
    lea rdx, [rip + r3_pairs]
    add rdx, rax
    mov [r13 + 16], rdx
    mov qword ptr [r13 + 24], 0
    mov qword ptr [r13 + 32], 1
    cmp qword ptr [rip + r4_format], 4
    jne .Lr4_local_node_done
    mov rdi, r12
    call r4_metadata_load
.Lr4_local_node_done:
    inc qword ptr [rip + g3_candidate_count]
    jmp .Lr3_local_node_line
.Lr3_local_edges_start:
    cmp qword ptr [rip + r4_format], 4
    je .Lr3_local_done
    call r3_parse_reset
    call r3_lock_header
.Lr3_local_edge_line:
    call r3_line
    test eax, eax
    jz .Lr3_local_done
    mov ebp, eax
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r3_edge_word]
    call streq
    test eax, eax
    jz .Lr3_local_edge_line
    cmp ebp, 4
    jne r3_lock_error
    xor r12d, r12d
    lea r13, [rip + g3_candidates]
.Lr3_local_parent:
    cmp r12, [rip + g3_candidate_count]
    jae r3_lock_error
    mov rdi, [r13]
    mov rsi, [rip + r3_fields + 8]
    call streq
    test eax, eax
    jnz .Lr3_local_parent_found
    add r13, 40
    inc r12
    jmp .Lr3_local_parent
.Lr3_local_parent_found:
    mov r14, [r13 + 24]
    cmp r14, 64
    jae r3_limit_error
    mov rdi, [rip + r3_fields + 16]
    call registry_valid_package
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r3_fields + 24]
    lea rsi, [rip + r3_zero_version]
    call g3_requirement
    cmp eax, -1
    je r3_lock_error
    imul rax, r12, R3_DEPS
    imul rdx, r14, 240
    add rax, rdx
    lea r15, [rip + r3_dependency_data]
    add r15, rax
    mov rdi, r15
    mov rsi, [rip + r3_fields + 16]
    call copy_string
    lea rdi, [r15 + 105]
    mov rsi, [rip + r3_fields + 24]
    call copy_string
    mov rdx, [r13 + 16]
    shl r14, 4
    add rdx, r14
    mov [rdx], r15
    lea rax, [r15 + 105]
    mov [rdx + 8], rax
    inc qword ptr [r13 + 24]
    jmp .Lr3_local_edge_line
.Lr3_local_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

.section .rodata
r3_header: .asciz "# asm-lock-v3\n"
r3_header_line: .asciz "# asm-lock-v3"
r3_registry_word: .asciz "registry"
r3_root_word: .asciz "root"
r3_node_word: .asciz "node"
r3_edge_word: .asciz "edge"
r3_zero_version: .asciz "0.0.0"
r3_local_url: .asciz "https://locked.invalid/source.tar.gz"
r3_source_note: .asciz "Locked V2 source"
r3_result_prefix: .asciz "{\"ok\":true,\"packages\":"
r3_resolved: .asciz ",\"resolved\":true}\n"
r3_synchronized: .asciz ",\"synchronized\":true}\n"
r3_err_lock: .asciz "V2 dependency lock is missing, stale or inconsistent. Preserve legacy locks. Use the same registry and target, then resolve this project."
r3_err_metadata: .asciz "V2 dependency metadata or artifact is unavailable, invalid or disabled by current policy; check the trusted registry and mirrors"
r3_err_limit: .asciz "V2 dependency search limit or metadata bound exceeded; reduce the dependency graph or report this input"
r3_err_unsat: .asciz "no compatible dependency graph satisfies the declared requirements and target; inspect the root and package constraints"
r3_err_changed: .asciz "A package identity or locked release changed. Keep asm.lock and report the metadata to the registry operator."
.p2align 3
r3_offsets: .quad 0,105,138,171,204,269,334,399,431
r3_capacities: .quad 105,33,33,33,65,65,65,32,65
.section .bss
.p2align 3
r3_active: .skip 1
r3_local: .skip 1
.p2align 3
r3_catalog_count: .skip 8
r3_inventory: .skip 4095 * 256
r3_records: .skip R3_CANDIDATES * R3_NODE
r3_pairs: .skip R3_CANDIDATES * 1024
r3_dependency_data: .skip R3_CANDIDATES * R3_DEPS
r3_names: .skip R3_CANDIDATES * 105
r3_name_count: .skip 8
r3_root_data: .skip 64 * 240
r3_manifest_sha: .skip 65
r3_local_id: .skip 33
.p2align 3
r3_order: .skip R3_CANDIDATES * 8
r3_order_count: .skip 8
r3_cache_row: .skip 64
r3_old_length: .skip 8
r3_old_lock: .skip INDEX_LIMIT + 1
r3_parse_buffer: .skip INDEX_LIMIT + 1
.p2align 3
r3_cursor: .skip 8
r3_end: .skip 8
r3_fields: .skip 11 * 8
r3_length: .skip 8
r3_buffer: .skip INDEX_LIMIT + 1
