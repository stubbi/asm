/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Bounded, newest-first native dependency graph resolution. No I/O is here.
 */
.intel_syntax noprefix
.global res_solve, res_conflict_name, res_conflict_range, res_conflict_reason
.global res_nodes, res_node_count
.section .text
/* Inputs: res_rows/count are validated v1 artifact records; rm_root_metadata
 * is parsed root metadata; res_root_requests/count names and res_default bool.
 * Callback res_load_candidate(RDI=row) returns persistent parsed metadata.
 * Outputs:RAX=1 solved/0 conflict; res_nodes/count include root at index0.
 * Node4096-byte layout: name0,row8,metadata16,features24,active dependencies32,
 * defaults40,request count48,request pointers56[64],processed features576,
 * private cycle state608,range count640,range pointers648[256]. At most128
 * packages,64 requested features/node,256 distinct incoming ranges/node,4096
 * candidate decisions. Exhaustion jumps to res_limit_error. Preserves all
 * System V callee registers. Recursive search depth<=129 and local frames<=
 * 72 bytes/depth; cycle traversal adds at most129 frames of40 bytes. No input
 * strings change. Caller owns index, manifest bytes, metadata and cache I/O.
 */
res_solve:
    mov qword ptr [rip + res_assign_count], 0
    mov qword ptr [rip + res_decisions], 0
    mov qword ptr [rip + res_conflict_depth], 0
    mov qword ptr [rip + res_conflict_name], 0
    mov qword ptr [rip + res_conflict_range], 0
    mov qword ptr [rip + res_conflict_reason], 0
    jmp res_search
res_search:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    call res_rebuild
    test eax, eax
    jz .Lrg_search_fail
    xor r12d, r12d
    lea rbx, [rip + res_nodes + 4096]
    mov ebp, 1
.Lrg_unresolved:
    cmp rbp, [rip + res_node_count]
    jae .Lrg_unresolved_done
    cmp qword ptr [rbx + 16], 0
    jne .Lrg_unresolved_next
    test r12, r12
    jz .Lrg_unresolved_choose
    mov rdi, [rbx]
    mov rsi, r12
    call res_text_compare
    test eax, eax
    jge .Lrg_unresolved_next
.Lrg_unresolved_choose:
    mov r12, [rbx]
.Lrg_unresolved_next:
    inc ebp
    add rbx, 4096
    jmp .Lrg_unresolved
.Lrg_unresolved_done:
    test r12, r12
    jnz .Lrg_choose_start
    call res_check_cycles
    jmp .Lrg_search_return
.Lrg_choose_start:
    xor r13d, r13d /* last attempted version */
    mov r15, [rip + res_assign_count]
.Lrg_candidate_round:
    /* Child branches overwrite derived nodes; rebuild before every retry. */
    call res_rebuild
    test eax, eax
    jz .Lrg_search_fail
    mov rdi, r12
    call res_find_node
    mov rbp, rax
    xor r14d, r14d /* highest remaining eligible row */
    lea rbx, [rip + res_rows]
    mov qword ptr [rsp], 0
.Lrg_candidate_scan:
    mov rax, [rsp]
    cmp rax, [rip + res_row_count]
    jae .Lrg_candidate_selected
    mov rdi, [rbx]
    mov rsi, r12
    call streq
    test eax, eax
    jz .Lrg_candidate_next
    mov rdi, [rbx + 16]
    lea rsi, [rip + registry_host]
    call streq
    test eax, eax
    jz .Lrg_candidate_next
    mov rdi, [rbx + 24]
    lea rsi, [rip + registry_source_kind]
    call streq
    test eax, eax
    jz .Lrg_candidate_next
    test r13, r13
    jz .Lrg_candidate_upper_ok
    mov rdi, [rbx + 8]
    mov rsi, r13
    call registry_version_compare
    test eax, eax
    jge .Lrg_candidate_next
.Lrg_candidate_upper_ok:
    test r14, r14
    jz .Lrg_candidate_ranges
    mov rdi, [rbx + 8]
    mov rsi, [r14 + 8]
    call registry_version_compare
    test eax, eax
    jle .Lrg_candidate_next
.Lrg_candidate_ranges:
    mov rdi, rbp
    mov rsi, rbx
    call res_row_matches
    test eax, eax
    jz .Lrg_candidate_next
    mov r14, rbx
.Lrg_candidate_next:
    inc qword ptr [rsp]
    add rbx, 64
    jmp .Lrg_candidate_scan
.Lrg_candidate_selected:
    test r14, r14
    jz .Lrg_no_candidate
    inc qword ptr [rip + res_decisions]
    cmp qword ptr [rip + res_decisions], 4096
    ja res_limit_error
    mov rdi, r14
    call res_load_candidate
    mov rdx, rax
    mov rax, r15
    imul rax, 24
    lea rdi, [rip + res_assignments]
    add rdi, rax
    mov [rdi], r12
    mov [rdi + 8], r14
    mov [rdi + 16], rdx
    lea rax, [r15 + 1]
    cmp rax, 128
    ja res_limit_error
    mov [rip + res_assign_count], rax
    call res_search
    test eax, eax
    jnz .Lrg_search_return
    mov [rip + res_assign_count], r15
    mov r13, [r14 + 8]
    jmp .Lrg_candidate_round
.Lrg_no_candidate:
    mov rdi, r12
    xor esi, esi
    cmp qword ptr [rbp + 640], 0
    je .Lrg_no_candidate_report
    mov rsi, [rbp + 648]
.Lrg_no_candidate_report:
    lea rdx, [rip + res_reason_version]
    call res_set_conflict
.Lrg_search_fail:
    xor eax, eax
.Lrg_search_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Derive all requirements from root and the current assignment prefix. Nodes
 * are cleared between branches, so abandoned defaults/features never leak.
 * RAX=1 stable compatible graph/0 conflict. Uses56 local stack bytes. */
res_rebuild:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    lea rdi, [rip + res_nodes]
    xor eax, eax
    mov ecx, 129*4096/8
    rep stosq
    mov qword ptr [rip + res_node_count], 1
    lea rbx, [rip + res_nodes]
    lea rax, [rip + res_root_name]
    mov [rbx], rax
    lea rax, [rip + rm_root_metadata]
    mov [rbx + 16], rax
    mov rax, [rip + res_default]
    mov [rbx + 40], rax
    xor ebp, ebp
.Lrg_root_request:
    cmp rbp, [rip + res_root_request_count]
    jae .Lrg_propagate_start
    lea rax, [rip + res_root_requests]
    mov rsi, [rax + rbp*8]
    mov rdi, rbx
    call res_add_request
    inc ebp
    jmp .Lrg_root_request
.Lrg_propagate_start:
    mov qword ptr [rip + res_changed], 0
    xor ebp, ebp
    lea rbx, [rip + res_nodes]
.Lrg_propagate_node:
    cmp rbp, [rip + res_node_count]
    jae .Lrg_propagate_done
    mov r12, [rbx + 16]
    test r12, r12
    jz .Lrg_propagate_next
    cmp qword ptr [rbx + 40], 0
    je .Lrg_requests
    mov rdi, r12
    lea rsi, [rip + res_default_feature]
    call res_meta_feature
    test rax, rax
    jz .Lrg_requests
    /* Default activation does not consume an explicit request slot. */
    bts [rbx + 24], rdx
    jc .Lrg_requests
    mov qword ptr [rip + res_changed], 1
.Lrg_requests:
    xor r13d, r13d
.Lrg_request:
    cmp r13, [rbx + 48]
    jae .Lrg_feature_expand_start
    mov rdi, r12
    mov rsi, [rbx + r13*8 + 56]
    call res_meta_feature
    test rax, rax
    jz .Lrg_unknown_feature
    sub rax, r12
    sub rax, RM_FEATURES
    xor edx, edx
    mov ecx, RM_STRIDE
    div rcx
    bts [rbx + 24], rax
    jnc .Lrg_feature_new
    jmp .Lrg_request_next
.Lrg_feature_new:
    mov qword ptr [rip + res_changed], 1
.Lrg_request_next:
    inc r13d
    jmp .Lrg_request
.Lrg_feature_expand_start:
    xor r13d, r13d
.Lrg_feature_expand:
    cmp r13, [r12 + 16]
    jae .Lrg_nonoptional_start
    bt [rbx + 24], r13
    jnc .Lrg_feature_next
    bt [rbx + 576], r13
    jc .Lrg_feature_next
    bts [rbx + 576], r13
    imul r14, r13, RM_STRIDE
    lea r14, [r12 + r14 + RM_FEATURES]
    xor r15d, r15d
.Lrg_feature_member:
    cmp r15, [r14 + 8]
    jae .Lrg_feature_next
    mov rsi, [r14 + r15*8 + 16]
    mov rdi, rbx
    call res_expand_member
    test eax, eax
    jz .Lrg_rebuild_bad
    inc r15d
    jmp .Lrg_feature_member
.Lrg_feature_next:
    inc r13d
    jmp .Lrg_feature_expand
.Lrg_nonoptional_start:
    xor r13d, r13d
.Lrg_nonoptional:
    cmp r13, [r12 + 8]
    jae .Lrg_edges_start
    imul rax, r13, RM_STRIDE
    cmp qword ptr [r12 + rax + RM_DEPS + 16], 0
    jne .Lrg_nonoptional_next
    bts [rbx + 32], r13
.Lrg_nonoptional_next:
    inc r13d
    jmp .Lrg_nonoptional
.Lrg_edges_start:
    xor r13d, r13d
.Lrg_edge:
    cmp r13, [r12 + 8]
    jae .Lrg_propagate_next
    bt [rbx + 32], r13
    jnc .Lrg_edge_next
    imul r14, r13, RM_STRIDE
    lea r14, [r12 + r14 + RM_DEPS]
    mov rdi, [r14]
    call res_get_node
    mov r15, rax
    mov rdi, r15
    mov rsi, [r14 + 8]
    call res_add_range
    cmp qword ptr [r14 + 24], 0
    je .Lrg_edge_requests
    cmp qword ptr [r15 + 40], 0
    jne .Lrg_edge_requests
    mov qword ptr [r15 + 40], 1
    mov qword ptr [rip + res_changed], 1
.Lrg_edge_requests:
    mov qword ptr [rsp], 0
.Lrg_edge_request:
    mov rax, [rsp]
    cmp rax, [r14 + 32]
    jae .Lrg_edge_next
    mov rdi, r15
    mov rsi, [r14 + rax*8 + 40]
    call res_add_request
    inc qword ptr [rsp]
    jmp .Lrg_edge_request
.Lrg_edge_next:
    inc r13d
    jmp .Lrg_edge
.Lrg_propagate_next:
    inc ebp
    add rbx, 4096
    jmp .Lrg_propagate_node
.Lrg_propagate_done:
    cmp qword ptr [rip + res_changed], 0
    jne .Lrg_propagate_start
    lea rbx, [rip + res_nodes + 4096]
    mov ebp, 1
.Lrg_validate_assigned:
    cmp rbp, [rip + res_node_count]
    jae .Lrg_rebuild_good
    mov rsi, [rbx + 8]
    test rsi, rsi
    jz .Lrg_validate_next
    mov rdi, rbx
    call res_row_matches
    test eax, eax
    jz .Lrg_rebuild_bad
.Lrg_validate_next:
    inc ebp
    add rbx, 4096
    jmp .Lrg_validate_assigned
.Lrg_unknown_feature:
    mov rdi, [rbx]
    mov rsi, [rbx + r13*8 + 56]
    lea rdx, [rip + res_reason_feature]
    call res_set_conflict
.Lrg_rebuild_bad:
    xor eax, eax
    jmp .Lrg_rebuild_return
.Lrg_rebuild_good:
    mov eax, 1
.Lrg_rebuild_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=node,RSI=row. RAX=1 iff version meets every accumulated range. */
res_row_matches:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    mov rbp, rsi
    xor r12d, r12d
.Lrg_match_range:
    cmp r12, [rbx + 640]
    jae .Lrg_match_good
    mov rdi, [rbp + 8]
    mov rsi, [rbx + r12*8 + 648]
    call rm_range_matches
    cmp rax, 1
    jne .Lrg_match_bad
    inc r12d
    jmp .Lrg_match_range
.Lrg_match_bad:
    /* Rejected unassigned candidates are not failed graph requirements. */
    cmp qword ptr [rbx + 8], 0
    je .Lrg_match_no_report
    mov rdi, [rbx]
    mov rsi, [rbx + r12*8 + 648]
    lea rdx, [rip + res_reason_version]
    call res_set_conflict
.Lrg_match_no_report:
    xor eax, eax
    jmp .Lrg_match_return
.Lrg_match_good:
    mov eax, 1
.Lrg_match_return:
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=node,RSI=feature member. RAX=1; parser already checked references.
 * May create a child and add a feature request. Owns256-byte text scratch. */
res_expand_member:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    mov [rip + res_expand_original], rsi
    lea rdi, [rip + res_member]
    call copy_string
    lea rbp, [rip + res_member]
    cmp dword ptr [rbp], 0x3a706564
    je .Lrg_expand_optional
    mov rdi, rbp
    xor r12d, r12d
.Lrg_expand_slash:
    mov al, [rdi]
    test al, al
    jz .Lrg_expand_classify
    cmp al, '/'
    jne .Lrg_expand_char
    mov r12, rdi
.Lrg_expand_char:
    inc rdi
    jmp .Lrg_expand_slash
.Lrg_expand_classify:
    test r12, r12
    jnz .Lrg_expand_external
    mov rdi, rbx
    mov rsi, rbp
    /* Own names must borrow persistent metadata, not shared scratch. */
    mov rdi, [rbx + 16]
    call res_meta_feature
    test rax, rax
    jz .Lrg_expand_bad
    mov rsi, [rax]
    mov rdi, rbx
    call res_add_request
    jmp .Lrg_expand_good
.Lrg_expand_external:
    mov byte ptr [r12], 0
    inc r12
    mov rdi, [rbx + 16]
    mov rsi, rbp
    call res_meta_dep
    test rax, rax
    jz .Lrg_expand_bad
    mov rbp, rax
    mov rcx, rdx
    bts [rbx + 32], rcx
    mov rdi, [rbp]
    call res_get_node
    mov rbx, rax
    /* The original member ends with the same feature string. Copying it to
     * shared scratch is unsafe: retain a pointer into immutable metadata. */
    mov rdi, r12
    call strlen
    mov rbp, rax
    /* Caller passed a persistent member pointer; recover it saved globally
     * before copy via res_expand_original. */
    mov rsi, [rip + res_expand_original]
    mov rdi, rsi
    call strlen
    mov rsi, [rip + res_expand_original]
    add rsi, rax
    sub rsi, rbp
    mov rdi, rbx
    call res_add_request
    jmp .Lrg_expand_good
.Lrg_expand_optional:
    mov rdi, [rbx + 16]
    lea rsi, [rbp + 4]
    call res_meta_dep
    test rax, rax
    jz .Lrg_expand_bad
    bts [rbx + 32], rdx
.Lrg_expand_good:
    mov eax, 1
    jmp .Lrg_expand_return
.Lrg_expand_bad:
    xor eax, eax
.Lrg_expand_return:
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=metadata,RSI=name;RAX=record/0;RDX=record index on success. */
res_meta_feature:
    mov rdx, [rdi + 16]
    add rdi, RM_FEATURES
    jmp res_meta_find
res_meta_dep:
    mov rdx, [rdi + 8]
    add rdi, RM_DEPS
res_meta_find:
    push rbx
    push rbp
    push r12
    push r13
    sub rsp, 8
    mov rbx, rdi
    mov rbp, rsi
    mov r12, rdx
    xor r13d, r13d
.Lrg_meta_loop:
    cmp r13, r12
    jae .Lrg_meta_absent
    mov rdi, [rbx]
    mov rsi, rbp
    call streq
    test eax, eax
    jnz .Lrg_meta_found
    inc r13d
    add rbx, RM_STRIDE
    jmp .Lrg_meta_loop
.Lrg_meta_absent:
    xor eax, eax
    jmp .Lrg_meta_return
.Lrg_meta_found:
    mov rax, rbx
    mov rdx, r13
.Lrg_meta_return:
    add rsp, 8
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=name;RAX=node/0. Read-only lookup; retains no argument pointers. */
res_find_node:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    lea rbp, [rip + res_nodes + 4096]
    mov r12d, 1
.Lrg_find_node:
    cmp r12, [rip + res_node_count]
    jae .Lrg_find_none
    mov rdi, rbx
    mov rsi, [rbp]
    call streq
    test eax, eax
    jnz .Lrg_find_yes
    inc r12d
    add rbp, 4096
    jmp .Lrg_find_node
.Lrg_find_none:
    xor eax, eax
    jmp .Lrg_find_return
.Lrg_find_yes:
    mov rax, rbp
.Lrg_find_return:
    pop r12
    pop rbp
    pop rbx
    ret
/* RDI=persistent package name;RAX=existing/new zeroed node with assignment
 * attached when selected. New nodes mark propagation changed. */
res_get_node:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    call res_find_node
    test rax, rax
    jnz .Lrg_get_return
    mov rax, [rip + res_node_count]
    cmp rax, 129
    jae res_limit_error
    shl rax, 12
    lea rbp, [rip + res_nodes]
    add rbp, rax
    mov [rbp], rbx
    inc qword ptr [rip + res_node_count]
    mov qword ptr [rip + res_changed], 1
    lea r12, [rip + res_assignments]
    xor ebx, ebx
.Lrg_attach:
    cmp rbx, [rip + res_assign_count]
    jae .Lrg_get_new
    mov rdi, [rbp]
    mov rsi, [r12]
    call streq
    test eax, eax
    jnz .Lrg_attach_found
    inc ebx
    add r12, 24
    jmp .Lrg_attach
.Lrg_attach_found:
    mov rax, [r12 + 8]
    mov [rbp + 8], rax
    mov rax, [r12 + 16]
    mov [rbp + 16], rax
.Lrg_get_new:
    mov rax, rbp
.Lrg_get_return:
    pop r12
    pop rbp
    pop rbx
    ret
/* RDI=node,RSI=persistent request/range string. Deduplicate exact strings.
 * No return value. Bounded counts; new facts mark propagation changed. */
res_add_request:
    lea rdx, [rdi + 48]
    lea rcx, [rdi + 56]
    mov r8d, 64
    jmp res_add_fact
res_add_range:
    lea rdx, [rdi + 640]
    lea rcx, [rdi + 648]
    mov r8d, 256
res_add_fact:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov rbx, rsi
    mov rbp, rdx
    mov r12, rcx
    mov r13, r8
    xor r14d, r14d
.Lrg_fact_loop:
    cmp r14, [rbp]
    jae .Lrg_fact_add
    mov rdi, rbx
    mov rsi, [r12 + r14*8]
    call streq
    test eax, eax
    jnz .Lrg_fact_return
    inc r14d
    jmp .Lrg_fact_loop
.Lrg_fact_add:
    cmp r14, r13
    jae res_limit_error
    mov [r12 + r14*8], rbx
    inc qword ptr [rbp]
    mov qword ptr [rip + res_changed], 1
.Lrg_fact_return:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RAX=1 acyclic/0 cycle. Active graph only; optional unused edges excluded. */
res_check_cycles:
    push rbx
    push rbp
    sub rsp, 8
    lea rbx, [rip + res_nodes]
    xor ebp, ebp
.Lrg_cycle_root:
    cmp rbp, [rip + res_node_count]
    jae .Lrg_cycle_all_good
    mov rdi, rbx
    call res_cycle_visit
    test eax, eax
    jz .Lrg_cycle_all_return
    add rbx, 4096
    inc ebp
    jmp .Lrg_cycle_root
.Lrg_cycle_all_good:
    mov eax, 1
.Lrg_cycle_all_return:
    add rsp, 8
    pop rbp
    pop rbx
    ret
res_cycle_visit:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    cmp qword ptr [rbx + 608], 2
    je .Lrg_cycle_good
    cmp qword ptr [rbx + 608], 1
    je .Lrg_cycle_bad
    mov qword ptr [rbx + 608], 1
    mov r12, [rbx + 16]
    xor ebp, ebp
.Lrg_cycle_edge:
    cmp rbp, [r12 + 8]
    jae .Lrg_cycle_complete
    bt [rbx + 32], rbp
    jnc .Lrg_cycle_next
    imul rax, rbp, RM_STRIDE
    mov rdi, [r12 + rax + RM_DEPS]
    call res_find_node
    test rax, rax
    jz .Lrg_cycle_bad
    mov rdi, rax
    call res_cycle_visit
    test eax, eax
    jz .Lrg_cycle_return
.Lrg_cycle_next:
    inc ebp
    jmp .Lrg_cycle_edge
.Lrg_cycle_complete:
    mov qword ptr [rbx + 608], 2
.Lrg_cycle_good:
    mov eax, 1
    jmp .Lrg_cycle_return
.Lrg_cycle_bad:
    mov rdi, [rbx]
    xor esi, esi
    lea rdx, [rip + res_reason_cycle]
    call res_set_conflict
    xor eax, eax
.Lrg_cycle_return:
    pop r12
    pop rbp
    pop rbx
    ret
/* RDI=name,RSI=range/feature or0,RDX=reason. Preserve the deepest observed
 * failed requirement across backtracking. Equal-depth failures remain current.
 * Scratch:RAX. No stack use; strings remain owned by registry/manifest buffers. */
res_set_conflict:
    mov rax, [rip + res_assign_count]
    cmp rax, [rip + res_conflict_depth]
    jb .Lrg_conflict_keep
    mov [rip + res_conflict_depth], rax
    mov [rip + res_conflict_name], rdi
    mov [rip + res_conflict_range], rsi
    mov [rip + res_conflict_reason], rdx
.Lrg_conflict_keep:
    ret
/* RDI/RSI=NUL ASCII text; EAX lexical difference. No mutation/stack use. */
res_text_compare:
    xor ecx, ecx
.Lrg_text:
    movzx eax, byte ptr [rdi + rcx]
    movzx edx, byte ptr [rsi + rcx]
    sub eax, edx
    jne .Lrg_text_done
    test edx, edx
    jz .Lrg_text_done
    inc ecx
    jmp .Lrg_text
.Lrg_text_done:
    ret
.section .rodata
res_root_name: .asciz "."
res_default_feature: .asciz "default"
res_reason_version: .asciz "no version satisfies the active dependency constraints"
res_reason_feature: .asciz "the selected version does not define a requested feature"
res_reason_cycle: .asciz "the active dependency graph contains a cycle"
.section .bss
.balign 8
res_assign_count: .skip 8
res_decisions: .skip 8
res_changed: .skip 8
res_conflict_depth: .skip 8
res_conflict_name: .skip 8
res_conflict_range: .skip 8
res_conflict_reason: .skip 8
res_expand_original: .skip 8
res_assignments: .skip 128*24
res_member: .skip 256
.section .note.GNU-stack,"",@progbits
