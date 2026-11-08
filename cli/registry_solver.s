/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Bounded, target-specific dependency solving. No I/O or package execution.
 * SysV arguments RDI/RSI/RDX/RCX; result RAX. All returning routines preserve
 * RBX/RBP/R12-R15. Other integer registers, flags and parser scratch change.
 * Process-owned serial state; pointers remain owned by the caller throughout.
 * One selected version per name. Chronological backtracking, not PubGrub.
 */
.intel_syntax noprefix
.equ G3_CANDIDATES, 256
.equ G3_ROOTS, 64
.equ G3_DEPS, 64
.equ G3_RECORD, 40
.equ G4_FACT_BYTES, 4376
.global g3_requirement, g3_solve
.global g3_candidates, g3_candidate_count, g3_roots, g3_root_count
.global g3_solution, g3_steps, g3_limit
.global g4_profiles, g4_root_profile, g4_requests, g4_request_count, g4_defaults
.global g4_active_features, g4_active_deps, g4_root_features, g4_root_deps
.global g4_lazy, g4_known_names, g4_known_count, g4_missing_name
.section .text

/* RDI=NUL version, RSI=owned 24-byte numeric tuple. RAX=end pointer or zero.
 * Three canonical decimal components, each <=2147483647. Stack: none.
 * At most ten digits per component are read before overflow rejection. */
g3_parse_version:
    test rdi, rdi
    jz .Lg3_version_bad
    xor ecx, ecx
.Lg3_component:
    xor r8d, r8d
    xor r9d, r9d
    cmp byte ptr [rdi], '0'
    jne .Lg3_digit
    movzx eax, byte ptr [rdi + 1]
    sub eax, '0'
    cmp eax, 9
    jbe .Lg3_version_bad
.Lg3_digit:
    movzx eax, byte ptr [rdi]
    sub eax, '0'
    cmp eax, 9
    ja .Lg3_component_end
    imul r8, r8, 10
    add r8, rax
    cmp r8, 2147483647
    ja .Lg3_version_bad
    inc r9d
    inc rdi
    jmp .Lg3_digit
.Lg3_component_end:
    test r9d, r9d
    jz .Lg3_version_bad
    mov [rsi + rcx*8], r8
    cmp ecx, 2
    je .Lg3_version_end
    cmp byte ptr [rdi], '.'
    jne .Lg3_version_bad
    inc rdi
    inc ecx
    jmp .Lg3_component
.Lg3_version_end:
    mov rax, rdi
    ret
.Lg3_version_bad:
    xor eax, eax
    ret

/* RDI/RSI=three-qword tuples. EAX=-1/0/1 numeric order. Stack:none. */
g3_compare_numbers:
    xor ecx, ecx
.Lg3_numbers_loop:
    mov rax, [rdi + rcx*8]
    cmp rax, [rsi + rcx*8]
    jb .Lg3_numbers_less
    ja .Lg3_numbers_greater
    inc ecx
    cmp ecx, 3
    jb .Lg3_numbers_loop
    xor eax, eax
    ret
.Lg3_numbers_less:
    mov eax, -1
    ret
.Lg3_numbers_greater:
    mov eax, 1
    ret

/* RDI=requirement<=128ASCII, RSI=canonical version. RAX=1 match,0 mismatch,
 * -1 invalid. Exact/=/>/>=/</<=/^/~ terms, <=8 comma intersections; '*' alone.
 * No whitespace, prerelease or build suffix. Every term is validated even
 * after an earlier mismatch. Static tuples24 each; stack40 plus callees. */
g3_requirement:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    test r12, r12
    jz .Lg3_requirement_bad
    xor ecx, ecx
.Lg3_requirement_length:
    cmp byte ptr [r12 + rcx], 0
    je .Lg3_requirement_version
    inc ecx
    cmp ecx, 128
    jbe .Lg3_requirement_length
    jmp .Lg3_requirement_bad
.Lg3_requirement_version:
    test ecx, ecx
    jz .Lg3_requirement_bad
    mov rdi, rsi
    lea rsi, [rip + g3_version_numbers]
    call g3_parse_version
    test rax, rax
    jz .Lg3_requirement_bad
    cmp byte ptr [rax], 0
    jne .Lg3_requirement_bad
    cmp byte ptr [r12], '*'
    jne .Lg3_requirement_terms
    cmp byte ptr [r12 + 1], 0
    jne .Lg3_requirement_bad
    mov eax, 1
    jmp .Lg3_requirement_return
.Lg3_requirement_terms:
    xor ebx, ebx
    mov r15d, 1
.Lg3_requirement_term:
    inc ebx
    cmp ebx, 8
    ja .Lg3_requirement_bad
    xor r13d, r13d
    movzx eax, byte ptr [r12]
    cmp al, '='
    je .Lg3_operator_one
    cmp al, '>'
    je .Lg3_operator_greater
    cmp al, '<'
    je .Lg3_operator_less
    mov r13d, 5
    cmp al, '^'
    je .Lg3_operator_one
    mov r13d, 6
    cmp al, '~'
    je .Lg3_operator_one
    xor r13d, r13d
    jmp .Lg3_requirement_parse
.Lg3_operator_greater:
    mov r13d, 1
    jmp .Lg3_operator_compare
.Lg3_operator_less:
    mov r13d, 3
.Lg3_operator_compare:
    inc r12
    cmp byte ptr [r12], '='
    jne .Lg3_requirement_parse
    inc r13d
.Lg3_operator_one:
    inc r12
.Lg3_requirement_parse:
    mov rdi, r12
    lea rsi, [rip + g3_base_numbers]
    call g3_parse_version
    test rax, rax
    jz .Lg3_requirement_bad
    mov r12, rax
    cmp byte ptr [r12], 0
    je .Lg3_requirement_compare
    cmp byte ptr [r12], ','
    jne .Lg3_requirement_bad
.Lg3_requirement_compare:
    lea rdi, [rip + g3_version_numbers]
    lea rsi, [rip + g3_base_numbers]
    call g3_compare_numbers
    test r13d, r13d
    jz .Lg3_match_exact
    cmp r13d, 1
    je .Lg3_match_greater
    cmp r13d, 2
    je .Lg3_match_ge
    cmp r13d, 3
    je .Lg3_match_less
    cmp r13d, 4
    je .Lg3_match_le
    test eax, eax
    js .Lg3_match_false
    mov rax, [rip + g3_version_numbers]
    cmp rax, [rip + g3_base_numbers]
    jne .Lg3_match_false
    cmp r13d, 6
    je .Lg3_match_minor
    cmp qword ptr [rip + g3_base_numbers], 0
    jne .Lg3_match_true
.Lg3_match_minor:
    mov rax, [rip + g3_version_numbers + 8]
    cmp rax, [rip + g3_base_numbers + 8]
    jne .Lg3_match_false
    cmp r13d, 6
    je .Lg3_match_true
    cmp qword ptr [rip + g3_base_numbers + 8], 0
    jne .Lg3_match_true
    mov rax, [rip + g3_version_numbers + 16]
    cmp rax, [rip + g3_base_numbers + 16]
    jne .Lg3_match_false
    jmp .Lg3_match_true
.Lg3_match_exact:
    test eax, eax
    sete al
    jmp .Lg3_match_boolean
.Lg3_match_greater:
    test eax, eax
    setg al
    jmp .Lg3_match_boolean
.Lg3_match_ge:
    test eax, eax
    setge al
    jmp .Lg3_match_boolean
.Lg3_match_less:
    test eax, eax
    setl al
    jmp .Lg3_match_boolean
.Lg3_match_le:
    test eax, eax
    setle al
.Lg3_match_boolean:
    movzx eax, al
    and r15d, eax
    jmp .Lg3_requirement_next
.Lg3_match_false:
    xor r15d, r15d
    jmp .Lg3_requirement_next
.Lg3_match_true:
.Lg3_requirement_next:
    cmp byte ptr [r12], 0
    je .Lg3_requirement_result
    inc r12
    jmp .Lg3_requirement_term
.Lg3_requirement_result:
    mov eax, r15d
    jmp .Lg3_requirement_return
.Lg3_requirement_bad:
    mov rax, -1
.Lg3_requirement_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=name. EAX=1 bounded nonempty printable ASCII,0 invalid. The registry
 * parser additionally validates package grammar. <=104 bytes; stack:none. */
g3_name:
    test rdi, rdi
    jz .Lg3_name_bad
    xor ecx, ecx
.Lg3_name_loop:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lg3_name_end
    cmp eax, 33
    jb .Lg3_name_bad
    cmp eax, 126
    ja .Lg3_name_bad
    inc ecx
    cmp ecx, 104
    jbe .Lg3_name_loop
.Lg3_name_bad:
    xor eax, eax
    ret
.Lg3_name_end:
    xor eax, eax
    test ecx, ecx
    setne al
    ret

/* RDI/RSI=validated bounded strings. EAX=-1/0/1 lexical order. Stack:none. */
g3_string_compare:
    movzx eax, byte ptr [rdi]
    movzx edx, byte ptr [rsi]
    cmp eax, edx
    jb .Lg3_numbers_less
    ja .Lg3_numbers_greater
    test eax, eax
    jz .Lg3_string_equal
    inc rdi
    inc rsi
    jmp g3_string_compare
.Lg3_string_equal:
    ret

/* Count one propagation, constraint, or search operation. EAX=0 or2 limit.
 * Each operation scans at most256 candidates. Does not wrap. Stack:none. */
g3_tick:
    mov rax, [rip + g3_steps]
    cmp rax, [rip + g3_limit]
    jae .Lg3_tick_limit
    inc qword ptr [rip + g3_steps]
    xor eax, eax
    ret
.Lg3_tick_limit:
    mov eax, 2
    ret

/* RDI/RSI=candidate indexes<256. EAX=sort order: name ascending, numeric
 * version descending. Equal identities are invalid. Static tuples; stack24. */
g3_candidate_compare:
    push rbx
    push r12
    push r13
    imul rdi, rdi, G3_RECORD
    imul rsi, rsi, G3_RECORD
    lea r12, [rip + g3_candidates]
    lea r13, [r12 + rsi]
    add r12, rdi
    mov rdi, [r12]
    mov rsi, [r13]
    call g3_string_compare
    test eax, eax
    jnz .Lg3_candidate_compare_return
    mov rdi, [r12 + 8]
    lea rsi, [rip + g3_version_numbers]
    call g3_parse_version
    mov rdi, [r13 + 8]
    lea rsi, [rip + g3_base_numbers]
    call g3_parse_version
    lea rdi, [rip + g3_base_numbers]
    lea rsi, [rip + g3_version_numbers]
    call g3_compare_numbers
.Lg3_candidate_compare_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=name. RAX=selected candidate index, or -1. Reads solution<=256bytes.
 * Only one selected candidate per name is permitted. Stack24. */
g3_selected_for_name:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor ebx, ebx
.Lg3_selected_loop:
    cmp rbx, [rip + g3_candidate_count]
    jae .Lg3_selected_none
    lea rax, [rip + g3_solution]
    cmp byte ptr [rax + rbx], 0
    je .Lg3_selected_next
    imul rax, rbx, G3_RECORD
    lea r13, [rip + g3_candidates]
    mov rdi, [r13 + rax]
    mov rsi, r12
    call g3_string_compare
    test eax, eax
    jz .Lg3_selected_found
.Lg3_selected_next:
    inc rbx
    jmp .Lg3_selected_loop
.Lg3_selected_none:
    mov rax, -1
    jmp .Lg3_selected_return
.Lg3_selected_found:
    mov rax, rbx
.Lg3_selected_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=candidate index<256. Queue a selected reached candidate once until
 * processed. Dirty bits permit repeated feature growth without queue overflow.
 * Registers RAX/RDX change; stack0; static dirty256/count8. */
g4_schedule:
    lea rdx, [rip + g4_dirty]
    cmp byte ptr [rdx + rdi], 0
    jne .Lg4_schedule_done
    mov byte ptr [rdx + rdi], 1
    inc qword ptr [rip + g4_dirty_count]
.Lg4_schedule_done:
    ret

/* RDI=name. EAX1found0known-absent2budget4needs-discovery. Mark all versions
 * required; schedule newly reached selected versions. Missing-name pointer is
 * borrowed, never copied. Lazy mode asks the IO owner to restart the solver.
 * Stack24; scans<=256 candidates and<=256 declared known names. */
g3_mark:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call g3_tick
    test eax, eax
    jnz .Lg3_mark_return
    xor ebx, ebx
    xor r13d, r13d
.Lg3_mark_loop:
    cmp rbx, [rip + g3_candidate_count]
    jae .Lg3_mark_done
    imul rax, rbx, G3_RECORD
    lea rdx, [rip + g3_candidates]
    mov rdi, [rdx + rax]
    mov rsi, r12
    call g3_string_compare
    test eax, eax
    jnz .Lg3_mark_next
    mov r13d, 1
    lea rdx, [rip + g3_required]
    cmp byte ptr [rdx + rbx], 0
    jne .Lg3_mark_next
    mov byte ptr [rdx + rbx], 1
    lea rdx, [rip + g3_solution]
    cmp byte ptr [rdx + rbx], 0
    je .Lg3_mark_next
    mov rdi, rbx
    call g4_schedule
.Lg3_mark_next:
    inc rbx
    jmp .Lg3_mark_loop
.Lg3_mark_done:
    mov eax, r13d
    test eax, eax
    jnz .Lg3_mark_return
    cmp qword ptr [rip + g4_lazy], 0
    je .Lg3_mark_return
    xor ebx, ebx
.Lg3_mark_known:
    cmp rbx, [rip + g4_known_count]
    jae .Lg3_mark_discover
    lea rax, [rip + g4_known_names]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call g3_string_compare
    test eax, eax
    jz .Lg3_mark_return
    inc rbx
    jmp .Lg3_mark_known
.Lg3_mark_discover:
    mov [rip + g4_missing_name], r12
    mov eax, 4
.Lg3_mark_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=name,RSI=requirement. EAX=0 matched or unresolved,1 conflict,2 budget,
 * 3 invalid. Only active requirements call this routine. Stack24. */
g3_check:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    call g3_tick
    test eax, eax
    jnz .Lg3_check_return
    mov rdi, r12
    call g3_selected_for_name
    test rax, rax
    js .Lg3_check_ok
    imul rax, rax, G3_RECORD
    lea rdx, [rip + g3_candidates]
    mov rsi, [rdx + rax + 8]
    mov rdi, r13
    call g3_requirement
    test rax, rax
    js .Lg3_check_invalid
    jz .Lg3_check_conflict
.Lg3_check_ok:
    xor eax, eax
    jmp .Lg3_check_return
.Lg3_check_invalid:
    mov eax, 3
    jmp .Lg3_check_return
.Lg3_check_conflict:
    mov eax, 1
.Lg3_check_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=validated profile orNULL,RDX=depcount. EAX0charged2exhausted.
 * Charge each declared option, feature, and list member before search.
 * Counts were validated<=64. Stack24; callee registers preserved; no I/O. */
g4_budget_profile:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rdx
    test r12, r12
    jz .Lg4_budget_good
    mov rbx, [r12 + 16]
    add rbx, r13
    inc rbx
    xor ecx, ecx
.Lg4_budget_options:
    cmp rcx, r13
    jae .Lg4_budget_definitions_begin
    imul rax, rcx, 24
    mov rdx, [r12]
    add rbx, [rdx + rax + 16]
    inc rcx
    jmp .Lg4_budget_options
.Lg4_budget_definitions_begin:
    xor ecx, ecx
.Lg4_budget_definitions:
    cmp rcx, [r12 + 16]
    jae .Lg4_budget_tick
    imul rax, rcx, 24
    mov rdx, [r12 + 8]
    add rbx, [rdx + rax + 16]
    inc rcx
    jmp .Lg4_budget_definitions
.Lg4_budget_tick:
    call g3_tick
    test eax, eax
    jnz .Lg4_budget_return
    dec rbx
    jnz .Lg4_budget_tick
.Lg4_budget_good:
    xor eax, eax
.Lg4_budget_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=profile,RSI=feature,RDX=mask address. EAX0activated1unknown.
 * New candidate features schedule their selected owner for propagation.
 * Uses unsigned64 masks, including bit63. Stack24; borrowed profile/strings. */
g4_activate:
    push rbx
    push r12
    push r13
    mov r12, rdx
    call g4_feature_index
    test rax, rax
    js .Lg4_activate_missing
    mov rcx, rax
    mov eax, 1
    shl rax, cl
    test [r12], rax
    jnz .Lg4_activate_ok
    or [r12], rax
    lea rdx, [rip + g4_active_features]
    mov rdi, r12
    sub rdi, rdx
    cmp rdi, G3_CANDIDATES * 8
    jae .Lg4_activate_ok
    shr rdi, 3
    call g4_schedule
.Lg4_activate_ok:
    xor eax, eax
    jmp .Lg4_activate_return
.Lg4_activate_missing:
    mov eax, 1
.Lg4_activate_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=dependency pair16,RSI=options24 orNULL(defaults only). EAX0okay,
 * 1conflict2budget3invalid4discovery. Only activated edges call this routine.
 * A missing requested child feature is a candidate conflict, never malformed.
 * Stack56; schedule facts unite monotonically within one search branch. */
g4_apply_edge:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rdi
    mov r13, rsi
    mov rdi, [r12]
    call g3_mark
    cmp eax, 1
    jne .Lg4_edge_mark_result
    mov rdi, [r12]
    mov rsi, [r12 + 8]
    call g3_check
    test eax, eax
    jnz .Lg4_edge_return
    mov rdi, [r12]
    call g3_selected_for_name
    test rax, rax
    js .Lg4_edge_ok
    mov r14, rax
    lea rdx, [rip + g4_active_features]
    lea rbx, [rdx + r14*8]
    lea rdx, [rip + g4_profiles]
    mov r15, [rdx + r14*8]
    test r13, r13
    jz .Lg4_edge_defaults
    test qword ptr [r13], 2
    jz .Lg4_edge_requests
.Lg4_edge_defaults:
    mov rdi, r15
    lea rsi, [rip + g4_default_name]
    call g4_feature_index
    test rax, rax
    js .Lg4_edge_requests
    mov rdi, r15
    lea rsi, [rip + g4_default_name]
    mov rdx, rbx
    call g4_activate
.Lg4_edge_requests:
    test r13, r13
    jz .Lg4_edge_ok
    mov rax, [r13 + 8]
    mov [rsp], rax
    mov rax, [r13 + 16]
    mov [rsp + 8], rax
.Lg4_edge_request:
    cmp qword ptr [rsp + 8], 0
    je .Lg4_edge_ok
    call g3_tick
    test eax, eax
    jnz .Lg4_edge_return
    mov rdi, r15
    mov rsi, [rsp]
    mov rdx, rbx
    call g4_activate
    test eax, eax
    jnz .Lg4_edge_return
    mov rdi, [rsp]
    call g4_next
    mov [rsp], rax
    dec qword ptr [rsp + 8]
    jmp .Lg4_edge_request
.Lg4_edge_mark_result:
    test eax, eax
    jnz .Lg4_edge_return
    mov eax, 1
    jmp .Lg4_edge_return
.Lg4_edge_ok:
    xor eax, eax
.Lg4_edge_return:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=profile orNULL,RSI=deps16,RDX=count,RCX=feature-mask*,R8=dep-mask*.
 * EAX0okay1conflict2budget3invalid4discovery. Derive local-feature closure,
 * then apply exactly active edges. Forwarded child features activate their
 * edge even when optional. Input declarations stay immutable. Stack88. */
g4_process_node:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    xor ecx, ecx
.Lg4_node_mandatory:
    cmp rcx, r13
    jae .Lg4_node_features_begin
    test rbx, rbx
    jz .Lg4_node_enable
    imul rax, rcx, 24
    mov rdx, [rbx]
    test qword ptr [rdx + rax], 1
    jnz .Lg4_node_mandatory_next
.Lg4_node_enable:
    mov eax, 1
    shl rax, cl
    or [r15], rax
.Lg4_node_mandatory_next:
    inc rcx
    jmp .Lg4_node_mandatory
.Lg4_node_features_begin:
    test rbx, rbx
    jz .Lg4_node_edges_begin
.Lg4_node_feature_pass:
    mov qword ptr [rsp + 24], 0
    mov qword ptr [rsp], 0
.Lg4_node_feature:
    mov rcx, [rsp]
    cmp rcx, [rbx + 16]
    jae .Lg4_node_feature_pass_done
    mov eax, 1
    shl rax, cl
    test [r14], rax
    jz .Lg4_node_feature_next
    call g3_tick
    test eax, eax
    jnz .Lg4_node_return
    imul rax, rcx, 24
    mov rdx, [rbx + 8]
    mov rcx, [rdx + rax + 8]
    mov [rsp + 8], rcx
    mov rcx, [rdx + rax + 16]
    mov [rsp + 16], rcx
.Lg4_node_member:
    cmp qword ptr [rsp + 16], 0
    je .Lg4_node_feature_next
    call g3_tick
    test eax, eax
    jnz .Lg4_node_return
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, [rsp + 8]
    call g4_member
    test eax, eax
    js .Lg4_node_invalid
    jz .Lg4_node_local
    mov [rsp + 32], rax
    mov [rsp + 40], rcx
    mov rcx, rdx
    mov eax, 1
    shl rax, cl
    or [r15], rax
    cmp qword ptr [rsp + 32], 2
    jne .Lg4_node_member_next
    mov rax, [rsp + 40]
    mov [rip + g4_forward_option + 8], rax
    imul rdi, rdx, 16
    add rdi, r12
    lea rsi, [rip + g4_forward_option]
    call g4_apply_edge
    test eax, eax
    jnz .Lg4_node_return
    jmp .Lg4_node_member_next
.Lg4_node_local:
    mov rcx, rdx
    mov eax, 1
    shl rax, cl
    test [r14], rax
    jnz .Lg4_node_member_next
    or [r14], rax
    mov qword ptr [rsp + 24], 1
.Lg4_node_member_next:
    mov rdi, [rsp + 8]
    call g4_next
    mov [rsp + 8], rax
    dec qword ptr [rsp + 16]
    jmp .Lg4_node_member
.Lg4_node_feature_next:
    inc qword ptr [rsp]
    jmp .Lg4_node_feature
.Lg4_node_feature_pass_done:
    cmp qword ptr [rsp + 24], 0
    jne .Lg4_node_feature_pass
.Lg4_node_edges_begin:
    mov qword ptr [rsp + 32], 0
.Lg4_node_edge:
    mov rcx, [rsp + 32]
    cmp rcx, r13
    jae .Lg4_node_ok
    mov eax, 1
    shl rax, cl
    test [r15], rax
    jz .Lg4_node_edge_next
    xor esi, esi
    test rbx, rbx
    jz .Lg4_node_edge_apply
    imul rax, rcx, 24
    mov rsi, [rbx]
    add rsi, rax
.Lg4_node_edge_apply:
    imul rdi, rcx, 16
    add rdi, r12
    call g4_apply_edge
    test eax, eax
    jnz .Lg4_node_return
.Lg4_node_edge_next:
    inc qword ptr [rsp + 32]
    jmp .Lg4_node_edge
.Lg4_node_invalid:
    mov eax, 3
    jmp .Lg4_node_return
.Lg4_node_ok:
    xor eax, eax
.Lg4_node_return:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Recompute every branch from roots, including all feature facts. Dirty
 * selected nodes are revisited when incoming features grow. Graph cycles
 * remain valid; local feature cycles were rejected before search. Stack40
 * per search depth<=256; RAX0solution1unsat2budget3invalid4discovery. */
g3_search:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call g3_tick
    test eax, eax
    jnz .Lg3_search_return
    call g4_clear_facts
    mov r12, [rip + g4_requests]
    mov r13, [rip + g4_request_count]
.Lg4_search_root_requests:
    test r13, r13
    jz .Lg4_search_root_default
    call g3_tick
    test eax, eax
    jnz .Lg3_search_return
    mov rdi, [rip + g4_root_profile]
    mov rsi, r12
    lea rdx, [rip + g4_root_features]
    call g4_activate
    test eax, eax
    jnz .Lg3_search_return
    mov rdi, r12
    call g4_next
    mov r12, rax
    dec r13
    jmp .Lg4_search_root_requests
.Lg4_search_root_default:
    cmp qword ptr [rip + g4_defaults], 0
    je .Lg4_search_root
    mov rdi, [rip + g4_root_profile]
    lea rsi, [rip + g4_default_name]
    call g4_feature_index
    test rax, rax
    js .Lg4_search_root
    mov rdi, [rip + g4_root_profile]
    lea rsi, [rip + g4_default_name]
    lea rdx, [rip + g4_root_features]
    call g4_activate
.Lg4_search_root:
    mov rdi, [rip + g4_root_profile]
    lea rsi, [rip + g3_roots]
    mov rdx, [rip + g3_root_count]
    lea rcx, [rip + g4_root_features]
    lea r8, [rip + g4_root_deps]
    call g4_process_node
    test eax, eax
    jnz .Lg3_search_return
.Lg4_search_dirty:
    cmp qword ptr [rip + g4_dirty_count], 0
    je .Lg3_find_unresolved
    xor ebx, ebx
    lea rdx, [rip + g4_dirty]
.Lg4_search_dirty_find:
    cmp byte ptr [rdx + rbx], 0
    jne .Lg4_search_dirty_found
    inc rbx
    jmp .Lg4_search_dirty_find
.Lg4_search_dirty_found:
    mov byte ptr [rdx + rbx], 0
    dec qword ptr [rip + g4_dirty_count]
    lea rax, [rip + g4_profiles]
    mov rdi, [rax + rbx*8]
    imul rax, rbx, G3_RECORD
    lea r12, [rip + g3_candidates]
    add r12, rax
    mov rsi, [r12 + 16]
    mov rdx, [r12 + 24]
    lea rax, [rip + g4_active_features]
    lea rcx, [rax + rbx*8]
    lea rax, [rip + g4_active_deps]
    lea r8, [rax + rbx*8]
    call g4_process_node
    test eax, eax
    jnz .Lg3_search_return
    jmp .Lg4_search_dirty
.Lg3_find_unresolved:
    xor r13d, r13d
.Lg3_unresolved_loop:
    cmp r13, [rip + g3_candidate_count]
    jae .Lg3_search_success
    lea rax, [rip + g3_order]
    mov rbx, [rax + r13*8]
    lea rax, [rip + g3_required]
    cmp byte ptr [rax + rbx], 0
    je .Lg3_unresolved_next
    imul rax, rbx, G3_RECORD
    lea rdx, [rip + g3_candidates]
    mov r14, [rdx + rax]
    mov rdi, r14
    call g3_selected_for_name
    test rax, rax
    js .Lg3_choose_begin
.Lg3_unresolved_next:
    inc r13
    jmp .Lg3_unresolved_loop
.Lg3_choose_begin:
    xor r15d, r15d
.Lg3_choose:
    cmp r15, [rip + g3_candidate_count]
    jae .Lg3_search_unsat
    lea rax, [rip + g3_order]
    mov rbx, [rax + r15*8]
    imul rax, rbx, G3_RECORD
    lea r12, [rip + g3_candidates]
    add r12, rax
    cmp qword ptr [r12 + 32], 0
    je .Lg3_choose_next
    mov rdi, [r12]
    mov rsi, r14
    call g3_string_compare
    test eax, eax
    jnz .Lg3_choose_next
    lea rax, [rip + g3_solution]
    mov byte ptr [rax + rbx], 1
    call g3_search
    test eax, eax
    jz .Lg3_search_return
    lea rdx, [rip + g3_solution]
    mov byte ptr [rdx + rbx], 0
    cmp eax, 1
    jne .Lg3_search_return
.Lg3_choose_next:
    inc r15
    jmp .Lg3_choose
.Lg3_search_success:
    xor eax, eax
    jmp .Lg3_search_return
.Lg3_search_unsat:
    mov eax, 1
.Lg3_search_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Inputs: candidates<=256 records40 {name*,version*,deps*,dep_count,usable};
 * roots<=64 records16 {name*,requirement*}; deps<=64 records16 per candidate.
 * Optional g4 profiles carry feature definitions and per-edge options. Root
 * requests<=64 are NUL-separated; defaults is boolean. NULL profiles retain
 * mandatory/default behavior. Lazy mode yields4 for an unknown required name.
 * All strings/arrays must remain readable during the call. Limit<=100000.
 * Outputs: RAX=0 solved,1 unsatisfiable,2 resource bound,3 malformed graph,
 * 4 needs discovery with a borrowed missing-name pointer.
 * solution[i]=1 for exactly the reachable graph on success, all zero on error.
 * Validates every supplied candidate, even inactive ones; rejects duplicates.
 * Sort scratch2048, reachability256, feature facts4376, dirty nodes256.
 * Recursion<=256*40 saved bytes plus bounded propagation routine frames. */
g3_solve:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [rip + g3_solution]
    mov ecx, G3_CANDIDATES
    xor eax, eax
    rep stosb
    mov qword ptr [rip + g3_steps], 0
    mov qword ptr [rip + g4_missing_name], 0
    call g4_clear_facts
    cmp qword ptr [rip + g3_candidate_count], G3_CANDIDATES
    ja .Lg3_solve_limit
    cmp qword ptr [rip + g3_root_count], G3_ROOTS
    ja .Lg3_solve_limit
    cmp qword ptr [rip + g3_limit], 100000
    ja .Lg3_solve_limit
    xor r13d, r13d
    lea r12, [rip + g3_candidates]
.Lg3_validate_candidate:
    cmp r13, [rip + g3_candidate_count]
    jae .Lg3_validate_roots_begin
    mov rdi, [r12]
    call g3_name
    test eax, eax
    jz .Lg3_solve_invalid
    lea rdi, [rip + g3_any]
    mov rsi, [r12 + 8]
    call g3_requirement
    test rax, rax
    js .Lg3_solve_invalid
    cmp qword ptr [r12 + 32], 1
    ja .Lg3_solve_invalid
    cmp qword ptr [r12 + 24], G3_DEPS
    ja .Lg3_solve_limit
    mov r14, [r12 + 16]
    mov r15, [r12 + 24]
    test r15, r15
    jz .Lg3_validate_candidate_next
    test r14, r14
    jz .Lg3_solve_invalid
.Lg3_validate_dep:
    mov rdi, [r14]
    call g3_name
    test eax, eax
    jz .Lg3_solve_invalid
    mov rdi, [r14 + 8]
    lea rsi, [rip + g3_zero]
    call g3_requirement
    test rax, rax
    js .Lg3_solve_invalid
    add r14, 16
    dec r15
    jnz .Lg3_validate_dep
.Lg3_validate_candidate_next:
    lea rax, [rip + g4_profiles]
    mov rdi, [rax + r13*8]
    mov rsi, [r12 + 16]
    mov rdx, [r12 + 24]
    call g4_profile_validate
    test eax, eax
    jnz .Lg3_solve_invalid
    lea rax, [rip + g4_profiles]
    mov rdi, [rax + r13*8]
    mov rdx, [r12 + 24]
    call g4_budget_profile
    test eax, eax
    jnz .Lg3_solve_return
    lea rax, [rip + g3_order]
    mov [rax + r13*8], r13
    inc r13
    add r12, G3_RECORD
    jmp .Lg3_validate_candidate
.Lg3_validate_roots_begin:
    xor r13d, r13d
    lea r12, [rip + g3_roots]
.Lg3_validate_root:
    cmp r13, [rip + g3_root_count]
    jae .Lg4_validate_root_profile
    mov rdi, [r12]
    call g3_name
    test eax, eax
    jz .Lg3_solve_invalid
    mov rdi, [r12 + 8]
    lea rsi, [rip + g3_zero]
    call g3_requirement
    test rax, rax
    js .Lg3_solve_invalid
    inc r13
    add r12, 16
    jmp .Lg3_validate_root
.Lg4_validate_root_profile:
    mov rdi, [rip + g4_root_profile]
    lea rsi, [rip + g3_roots]
    mov rdx, [rip + g3_root_count]
    call g4_profile_validate
    test eax, eax
    jnz .Lg3_solve_invalid
    mov rdi, [rip + g4_root_profile]
    mov rdx, [rip + g3_root_count]
    call g4_budget_profile
    test eax, eax
    jnz .Lg3_solve_return
    cmp qword ptr [rip + g4_request_count], 64
    ja .Lg3_solve_limit
    cmp qword ptr [rip + g4_defaults], 1
    ja .Lg3_solve_invalid
    cmp qword ptr [rip + g4_lazy], 1
    ja .Lg3_solve_invalid
    cmp qword ptr [rip + g4_known_count], 256
    ja .Lg3_solve_limit
    mov rdi, [rip + g4_requests]
    mov rsi, [rip + g4_request_count]
    call g4_names_validate
    test eax, eax
    jnz .Lg3_solve_invalid
    mov r12, [rip + g4_requests]
    mov r13, [rip + g4_request_count]
.Lg4_validate_request:
    test r13, r13
    jz .Lg4_validate_known_begin
    mov rdi, [rip + g4_root_profile]
    mov rsi, r12
    call g4_feature_index
    test rax, rax
    js .Lg3_solve_invalid
    mov rdi, r12
    call g4_next
    mov r12, rax
    dec r13
    jmp .Lg4_validate_request
.Lg4_validate_known_begin:
    xor r13d, r13d
.Lg4_validate_known:
    cmp r13, [rip + g4_known_count]
    jae .Lg3_sort_begin
    lea rax, [rip + g4_known_names]
    mov rdi, [rax + r13*8]
    call g3_name
    test eax, eax
    jz .Lg3_solve_invalid
    inc r13
    jmp .Lg4_validate_known
.Lg3_sort_begin:
    mov r13d, 1
.Lg3_sort_outer:
    cmp r13, [rip + g3_candidate_count]
    jae .Lg3_solve_search
    lea rax, [rip + g3_order]
    mov r14, [rax + r13*8]
    mov r15, r13
.Lg3_sort_inner:
    test r15, r15
    jz .Lg3_sort_insert
    lea rax, [rip + g3_order]
    mov rdi, [rax + r15*8 - 8]
    mov rsi, r14
    call g3_candidate_compare
    test eax, eax
    jz .Lg3_solve_invalid
    js .Lg3_sort_insert
    lea rax, [rip + g3_order]
    mov rdx, [rax + r15*8 - 8]
    mov [rax + r15*8], rdx
    dec r15
    jmp .Lg3_sort_inner
.Lg3_sort_insert:
    lea rax, [rip + g3_order]
    mov [rax + r15*8], r14
    inc r13
    jmp .Lg3_sort_outer
.Lg3_solve_search:
    call g3_search
    jmp .Lg3_solve_return
.Lg3_solve_invalid:
    mov eax, 3
    jmp .Lg3_solve_return
.Lg3_solve_limit:
    mov eax, 2
.Lg3_solve_return:
    test eax, eax
    jz .Lg4_solve_done
    mov r12, rax
    lea rdi, [rip + g3_solution]
    mov ecx, G3_CANDIDATES
    xor eax, eax
    rep stosb
    call g4_clear_facts
    mov rax, r12
    cmp eax, 4
    je .Lg4_solve_done
    mov qword ptr [rip + g4_missing_name], 0
.Lg4_solve_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Zero branch-derived facts without changing selections or input metadata.
 * All registers except RDI/RCX/RAX preserved; stack0. Contiguous private
 * storage is one owned G4_FACT_BYTES block with fixed field offsets. */
g4_clear_facts:
    lea rdi, [rip + g4_facts]
    mov ecx, G4_FACT_BYTES
    xor eax, eax
    rep stosb
    lea rdi, [rip + g3_required]
    mov ecx, G3_CANDIDATES
    rep stosb
    ret

.section .rodata
g4_default_name: .asciz "default"
g3_any: .asciz "*"
g3_zero: .asciz "0.0.0"
.section .data
.balign 8
g3_limit: .quad 100000
g4_defaults: .quad 1
g4_forward_option: .quad 0,0,1
.section .bss
.balign 8
g3_candidate_count: .skip 8
g3_root_count: .skip 8
g3_steps: .skip 8
g3_candidates: .skip G3_CANDIDATES * G3_RECORD
g3_roots: .skip G3_ROOTS * 16
g3_solution: .skip G3_CANDIDATES
g3_required: .skip G3_CANDIDATES
g3_order: .skip G3_CANDIDATES * 8
g3_version_numbers: .skip 24
g3_base_numbers: .skip 24

.balign 8
g4_profiles: .skip G3_CANDIDATES * 8
g4_root_profile: .skip 8
g4_requests: .skip 8
g4_request_count: .skip 8
g4_lazy: .skip 8
g4_known_names: .skip G3_CANDIDATES * 8
g4_known_count: .skip 8
g4_missing_name: .skip 8
g4_facts: .skip G4_FACT_BYTES
.set g4_active_features, g4_facts
.set g4_active_deps, g4_facts + 2048
.set g4_root_features, g4_facts + 4096
.set g4_root_deps, g4_facts + 4104
.set g4_dirty, g4_facts + 4112
.set g4_dirty_count, g4_facts + 4368
.if 4368 + 8 != G4_FACT_BYTES
.error "feature fact capacity differs"
.endif
