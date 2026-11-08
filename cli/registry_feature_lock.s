/* SPDX-License-Identifier: AGPL-3.0-or-later
 * V2 feature selection, complete v4 graph facts, and exact envelope cache.
 * SysV ABI: RDI/RSI/RDX inputs; RAX result. Preserve RBX/RBP/R12-R15.
 * Serial owned buffers:64 requests of<=32 bytes,256 profiles11296 bytes,
 * control envelope<=65536 bytes, cache paths<=96. No submitted code runs.
 * Local cache checks bind bytes to the lock, not current remote authority.
 */
.intel_syntax noprefix
.section .text
/* RDI=option string. EAX1 handled,0 unknown. Only resolve accepts choices.
 * Duplicate options and empty/duplicate feature names fail before network.
 * Request text is copied before later argument or parser activity. Stack24. */
r4_option:
    push rbx
    push r12
    push r13
    mov r12, rdi
    lea rsi, [rip + r4_opt_features]
    call streq
    test eax, eax
    jnz .Lr4_option_features
    mov rdi, r12
    lea rsi, [rip + r4_opt_no_defaults]
    call streq
    test eax, eax
    jz .Lr4_option_return
    cmp qword ptr [rip + r2_mode], 5
    jne r2_arguments
    test byte ptr [rip + r4_option_bits], 2
    jnz r2_arguments
    or byte ptr [rip + r4_option_bits], 2
    mov qword ptr [rip + g4_defaults], 0
    jmp .Lr4_option_yes
.Lr4_option_features:
    cmp qword ptr [rip + r2_mode], 5
    jne r2_arguments
    test byte ptr [rip + r4_option_bits], 1
    jnz r2_arguments
    or byte ptr [rip + r4_option_bits], 1
    call registry_arg_value
    mov rdi, rax
    call r4_parse_requests
.Lr4_option_yes:
    mov eax, 1
.Lr4_option_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=comma-separated names<=2111 bytes. Canonicalize into owned NUL list.
 * Reject invalid names, duplicates and list overflow. Stack48 plus callees.
 * All copies have checked total capacity; sort is bounded insertion sort. */
r4_parse_requests:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    xor ecx, ecx
    lea rdx, [rip + r4_request_input]
.Lr4_request_copy:
    cmp ecx, 2112
    jae r2_arguments
    mov al, [rdi + rcx]
    mov [rdx + rcx], al
    inc ecx
    test al, al
    jnz .Lr4_request_copy
    mov qword ptr [rip + g4_request_count], 0
    lea r12, [rip + r4_request_input]
    lea r13, [rip + r4_request_pointers]
    mov r14, r12
.Lr4_request_split:
    mov rax, [rip + g4_request_count]
    cmp rax, 64
    jae r2_arguments
    mov [r13 + rax*8], r12
    inc qword ptr [rip + g4_request_count]
.Lr4_request_separator:
    cmp byte ptr [r14], 0
    je .Lr4_request_validate_last
    cmp byte ptr [r14], ','
    je .Lr4_request_validate
    inc r14
    jmp .Lr4_request_separator
.Lr4_request_validate:
    mov byte ptr [r14], 0
    mov rdi, r12
    call g4_feature_name
    test eax, eax
    jz r2_arguments
    inc r14
    mov r12, r14
    jmp .Lr4_request_split
.Lr4_request_validate_last:
    mov rdi, r12
    call g4_feature_name
    test eax, eax
    jz r2_arguments
    mov ebx, 1
.Lr4_request_sort_outer:
    cmp rbx, [rip + g4_request_count]
    jae .Lr4_request_sorted
    mov r12, [r13 + rbx*8]
    mov rbp, rbx
.Lr4_request_sort_inner:
    test rbp, rbp
    jz .Lr4_request_store
    mov r14, [r13 + rbp*8 - 8]
    mov rdi, r14
    mov rsi, r12
    call r2_lex
    test eax, eax
    jz r2_arguments
    js .Lr4_request_store
    mov [r13 + rbp*8], r14
    dec rbp
    jmp .Lr4_request_sort_inner
.Lr4_request_store:
    mov [r13 + rbp*8], r12
    inc rbx
    jmp .Lr4_request_sort_outer
.Lr4_request_sorted:
    lea r15, [rip + r4_request_text]
    mov [rip + g4_requests], r15
    xor ebx, ebx
.Lr4_request_own:
    cmp rbx, [rip + g4_request_count]
    jae .Lr4_request_done
    mov rdi, r15
    mov rsi, [r13 + rbx*8]
    call copy_string
    lea r15, [rax + 1]
    inc rbx
    jmp .Lr4_request_own
.Lr4_request_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Confirm explicit root requests exist before contacting any registry.
 * An absent implicit default is permitted. Stack24; owns no input. */
r4_validate_selection:
    push rbx
    push r12
    push r13
    xor ebx, ebx
    mov r12, [rip + g4_requests]
.Lr4_validate_request:
    cmp rbx, [rip + g4_request_count]
    jae .Lr4_validate_done
    mov rdi, [rip + g4_root_profile]
    mov rsi, r12
    call g4_feature_index
    test rax, rax
    js r4_selection_error
    mov rdi, r12
    call g4_next
    mov r12, rax
    inc rbx
    jmp .Lr4_validate_request
.Lr4_validate_done:
    pop r13
    pop r12
    pop rbx
    ret
r4_metadata_length_error:
    lea rdi, [rip + r4_err_metadata_length]
    jmp r3_fail

r4_selection_error:
    lea rdi, [rip + r4_err_selection]
    jmp r3_fail

/* RAX=profile orNULL,RDX=dependency count. Refuse feature semantics in v3.
 * Legacy lock readers cannot ignore dormant declarations or child requests.
 * Preserves callee registers; scratch RAX/RCX/RDX. No stack or effects. */
r4_legacy_profile:
    test rax, rax
    jz .Lr4_legacy_done
    cmp qword ptr [rax + 16], 0
    jne r3_lock_error
    mov rax, [rax]
    xor ecx, ecx
.Lr4_legacy_option:
    cmp rcx, rdx
    jae .Lr4_legacy_done
    cmp qword ptr [rax], 2
    jne r3_lock_error
    cmp qword ptr [rax + 16], 0
    jne r3_lock_error
    inc rcx
    add rax, 24
    jmp .Lr4_legacy_option
.Lr4_legacy_done:
    ret

/* Consume exactly one v4 selection row after its checked authority header.
 * Canonical rendering later rejects reordered requests and all extra rows.
 * Lock parsing fields borrow an independent buffer. Stack8 plus callees. */
r4_read_selection:
    push rbx
    call r3_line
    cmp eax, 3
    jne r3_lock_error
    mov rdi, [rip + r3_fields]
    lea rsi, [rip + r4_selection_word]
    call streq
    test eax, eax
    jz r3_lock_error
    mov rax, [rip + r3_fields + 8]
    cmp word ptr [rax], 0x0030
    je .Lr4_selection_no_default
    cmp word ptr [rax], 0x0031
    jne r3_lock_error
    mov qword ptr [rip + g4_defaults], 1
    jmp .Lr4_selection_requests
.Lr4_selection_no_default:
    mov qword ptr [rip + g4_defaults], 0
.Lr4_selection_requests:
    mov qword ptr [rip + g4_request_count], 0
    mov qword ptr [rip + g4_requests], 0
    mov rdi, [rip + r3_fields + 16]
    cmp word ptr [rdi], 0x002d
    je .Lr4_selection_check
    call r4_parse_requests
.Lr4_selection_check:
    call r4_validate_selection
    pop rbx
    ret

/* Append v4 root selection and enabled local features. Stack24 plus writer.
 * Request strings are already sorted and bounded; an empty list is '-'. */
r4_render_selection:
    push rbx
    push r12
    push r13
    lea rsi, [rip + r4_selection_word]
    call r3_append
    call r3_tab
    lea rsi, [rip + r4_zero]
    cmp qword ptr [rip + g4_defaults], 0
    je .Lr4_render_defaults
    lea rsi, [rip + r4_one]
.Lr4_render_defaults:
    call r3_append
    call r3_tab
    cmp qword ptr [rip + g4_request_count], 0
    jne .Lr4_render_requests_start
    lea rsi, [rip + r4_dash]
    call r3_append
    jmp .Lr4_render_requests_end
.Lr4_render_requests_start:
    xor ebx, ebx
    mov r12, [rip + g4_requests]
.Lr4_render_request:
    test rbx, rbx
    jz .Lr4_render_request_text
    lea rsi, [rip + r4_comma]
    call r3_append
.Lr4_render_request_text:
    mov rsi, r12
    call r3_append
    mov rdi, r12
    call g4_next
    mov r12, rax
    inc rbx
    cmp rbx, [rip + g4_request_count]
    jb .Lr4_render_request
.Lr4_render_requests_end:
    call r3_lf
    mov rdi, [rip + g4_root_profile]
    mov rsi, [rip + g4_root_features]
    xor edx, edx
    call r4_render_features
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=profile,RSI=enabled bitset,RDX=package name orNULL for root.
 * Append sorted feature rows. Input profile is validated and owned. Stack48.
 * Never derive a package selection from a lock's feature rows. */
r4_render_features:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    test rdi, rdi
    jz .Lr4_features_done
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, [rdi + 8]
    xor ebx, ebx
.Lr4_render_feature:
    cmp rbx, [r12 + 16]
    jae .Lr4_features_done
    bt r13, rbx
    jnc .Lr4_render_feature_next
    lea rsi, [rip + r4_root_feature_word]
    test r14, r14
    jz .Lr4_render_feature_word
    lea rsi, [rip + r4_feature_word]
.Lr4_render_feature_word:
    call r3_append
    call r3_tab
    test r14, r14
    jz .Lr4_render_feature_name
    mov rsi, r14
    call r3_append
    call r3_tab
.Lr4_render_feature_name:
    mov rsi, [r15]
    call r3_append
    call r3_lf
.Lr4_render_feature_next:
    inc rbx
    add r15, 24
    jmp .Lr4_render_feature
.Lr4_features_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

r4_render_node_features:
    push rbx
    push r12
    push r13
    xor ebx, ebx
.Lr4_render_node_feature:
    cmp rbx, [rip + r3_order_count]
    jae .Lr4_render_node_features_done
    lea rax, [rip + r3_order]
    mov r12, [rax + rbx*8]
    lea rax, [rip + g4_profiles]
    mov rdi, [rax + r12*8]
    lea rax, [rip + g4_active_features]
    mov rsi, [rax + r12*8]
    mov rax, r12
    shl rax, 9
    lea rdx, [rip + r3_records]
    add rdx, rax
    call r4_render_features
    inc rbx
    jmp .Lr4_render_node_feature
.Lr4_render_node_features_done:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=candidate index. Set owned metadata pathname using checked hex binding.
 * The fixed relative path is<96 bytes. No filesystem effects; stack8. */
r4_metadata_path:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + r4_cache_path]
    lea rsi, [rip + r4_metadata_prefix]
    call copy_string
    mov rdi, rax
    mov rax, rbx
    shl rax, 9
    lea rsi, [rip + r3_records + 204]
    add rsi, rax
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r4_json_suffix]
    call copy_string
    pop rbx
    ret

/* RDI=candidate index. Retain verified exact envelope during sync only.
 * Stage0600 bytes, fsync, link without replacement, then remove stage.
 * Existing bytes must match; symlinks/nonregular files fail. Parent traversal
 * checks protected directories. Advisory locking coordinates Asm processes;
 * pathname finalization is not a sandbox against another same-user process.
 * Stack32 plus callees; stage is registered for failure cleanup. */
r4_metadata_save:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    lea rdi, [rip + r4_metadata_root]
    call make_safe_dir
    test rax, rax
    js r2_io
    lea rdi, [rip + r4_metadata_root]
    mov esi, 1
    xor edx, edx
    call r2_open_path
    mov rdi, rax
    mov eax, 3
    syscall
    mov rdi, r12
    call r4_metadata_path
    lea rdi, [rip + r4_stage_path]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + r4_metadata_suffix]
    call copy_string
    lea rax, [rip + r4_stage_path]
    mov [rip + registry_extra_temp], rax
    mov rdi, rax
    lea rsi, [rip + r2_envelope]
    mov rdx, [rip + r4_envelope_length]
    call r2_write_file
    lea rdi, [rip + r4_stage_path]
    xor esi, esi
    mov edx, 1
    call r2_open_path
    mov r14, rax
    mov rdi, rax
    mov eax, 74
    syscall
    test rax, rax
    js r2_io
    mov rdi, r14
    mov eax, 3
    syscall
    lea rdi, [rip + r4_stage_path]
    lea rsi, [rip + r4_cache_path]
    mov eax, 86
    syscall
    test rax, rax
    jz .Lr4_metadata_unstage
    cmp rax, -17
    jne r2_io
.Lr4_metadata_unstage:
    lea rdi, [rip + r4_stage_path]
    mov eax, 87
    syscall
    test rax, rax
    js r2_io
    mov qword ptr [rip + registry_extra_temp], 0
    lea rdi, [rip + r4_cache_path]
    xor esi, esi
    mov edx, 1
    call r2_open_path
    mov rdx, [rip + r2_stat + 48]
    cmp rdx, [rip + r4_envelope_length]
    jne r4_metadata_length_error
    mov rdi, rax
    mov eax, 3
    syscall
    lea rdi, [rip + r4_cache_path]
    call r2_hash_path
    mov rax, r12
    shl rax, 9
    lea rdi, [rip + r3_records + 204]
    add rdi, rax
    lea rsi, [rip + pub_hash_buffer]
    call streq
    test eax, eax
    jz r3_lock_error
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=local candidate index with nine validated lock bindings. Load exact
 * digest-named envelope<=64KiB, validate its complete native schema, compare
 * all bindings, then own its full dependency/profile declarations. No network
 * or authority/freshness claim. Metadata must have been retained by sync.
 * Stack48 plus callees; all text remains process-owned for graph validation. */
r4_metadata_load:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rax, r12
    shl rax, 9
    lea rbx, [rip + r3_records]
    add rbx, rax
    call r4_metadata_path
    lea rdi, [rip + r4_cache_path]
    xor esi, esi
    mov edx, 1
    call r2_open_path
    mov rdi, rax
    lea rsi, [rip + r2_envelope]
    mov edx, R2_CONTROL
    call r2_read_fd
    mov [rip + r4_envelope_length], rax
    lea rdi, [rip + r4_cache_path]
    call r2_hash_path
    lea rdi, [rbx + 204]
    lea rsi, [rip + pub_hash_buffer]
    call streq
    test eax, eax
    jz r3_lock_error
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
    lea rdi, [rip + r2_envelope]
    mov rsi, [rip + r4_envelope_length]
    call r2_parse_json
    mov rdi, rax
    call r2_validate_envelope
    lea rdi, [rbx + 138]
    lea rsi, [rip + r2_package_id]
    call streq
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 171]
    lea rsi, [rip + r2_release_id]
    call streq
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 269]
    lea rsi, [rip + r2_manifest_sha]
    call streq
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 334]
    lea rsi, [rip + r2_commit]
    call streq
    test eax, eax
    jz r3_lock_error
    lea rdi, [rbx + 431]
    lea rsi, [rip + r2_source_sha]
    call streq
    test eax, eax
    jz r3_lock_error
    mov rdi, [rip + r2_source_bytes]
    lea rsi, [rip + r2_size_decimal + 31]
    call unsigned_decimal
    mov rsi, rax
    lea rdi, [rbx + 399]
    call streq
    test eax, eax
    jz r3_lock_error
    imul rax, r12, 40
    lea r13, [rip + g3_candidates]
    add r13, rax
    mov rax, [rip + r2_dependency_count]
    mov [r13 + 24], rax
    mov rax, [rip + r2_selected]
    mov [r13 + 32], rax
    mov r14, [r13 + 16]
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
    xor ebp, ebp
.Lr4_load_dependency:
    cmp rbp, [r13 + 24]
    jae .Lr4_load_done
    mov [r14], r15
    lea rax, [r15 + 105]
    mov [r14 + 8], rax
    add r14, 16
    add r15, 240
    inc rbp
    jmp .Lr4_load_dependency
.Lr4_load_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

.section .rodata
r4_header: .asciz "# asm-lock-v4\n"
r4_header_line: .asciz "# asm-lock-v4"
r4_selection_word: .asciz "selection"
r4_root_feature_word: .asciz "root-feature"
r4_feature_word: .asciz "feature"
r4_opt_features: .asciz "--features"
r4_opt_no_defaults: .asciz "--no-default-features"
r4_zero: .asciz "0"
r4_one: .asciz "1"
r4_dash: .asciz "-"
r4_comma: .asciz ","
r4_metadata_root: .asciz ".asm/metadata"
r4_metadata_prefix: .asciz ".asm/metadata/"
r4_metadata_suffix: .asciz "/metadata"
r4_json_suffix: .asciz ".json"
r4_err_metadata_length: .asciz "Cached V2 metadata has the wrong length. Remove the damaged file in .asm/metadata. Run sync again."
r4_err_selection: .asciz "A requested root feature is not declared. Check [features] in asm.toml. Resolve again."
.section .data
.p2align 3
r4_format: .quad 4
.section .bss
.p2align 3
r4_option_bits: .skip 8
r4_steps: .skip 8
r4_envelope_length: .skip 8
r4_root_profile: .skip G4_PROFILE_SIZE
r4_profiles: .skip R3_CANDIDATES * G4_PROFILE_SIZE
r4_request_pointers: .skip 64 * 8
r4_request_input: .skip 2112
r4_request_text: .skip 2112
r4_cache_path: .skip 96
r4_stage_path: .skip 96
