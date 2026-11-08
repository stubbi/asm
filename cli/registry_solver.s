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
.global g3_requirement, g3_solve
.global g3_candidates, g3_candidate_count, g3_roots, g3_root_count
.global g3_solution, g3_steps, g3_limit
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

/* RDI=name. Mark all candidates of this required name. EAX=1 found,0 absent,
 * 2 budget. Newly reached selections enter a <=256-byte work queue once.
 * Updates required256/queue256 and queue_write; stack24. */
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
    mov rax, [rip + g3_queue_write]
    cmp rax, G3_CANDIDATES
    jae .Lg3_mark_limit
    lea rdx, [rip + g3_queue]
    mov byte ptr [rdx + rax], bl
    inc qword ptr [rip + g3_queue_write]
.Lg3_mark_next:
    inc rbx
    jmp .Lg3_mark_loop
.Lg3_mark_done:
    mov eax, r13d
    jmp .Lg3_mark_return
.Lg3_mark_limit:
    mov eax, 2
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

/* Recompute root-reachable closure, check active constraints, then select
 * the lexical first unresolved name and try numeric-newest usable versions.
 * Recursive depth<=256 names. Every failed branch clears its selections.
 * RAX=0 solution,1 unsatisfiable,2 budget,3 invalid. Stack40 per depth plus
 * calls. No graph edge creates unbounded recursion; cycles use required[].
 * A visited work queue processes each reached selection once per branch. */
g3_search:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call g3_tick
    test eax, eax
    jnz .Lg3_search_return
    lea rdi, [rip + g3_required]
    mov ecx, G3_CANDIDATES
    xor eax, eax
    rep stosb
    mov qword ptr [rip + g3_queue_read], 0
    mov qword ptr [rip + g3_queue_write], 0
    lea r12, [rip + g3_roots]
    xor r13d, r13d
.Lg3_search_roots:
    cmp r13, [rip + g3_root_count]
    jae .Lg3_closure_candidate
    mov rdi, [r12]
    call g3_mark
    cmp eax, 2
    je .Lg3_search_return
    test eax, eax
    jz .Lg3_search_unsat
    add r12, 16
    inc r13
    jmp .Lg3_search_roots
.Lg3_closure_candidate:
    mov rax, [rip + g3_queue_read]
    cmp rax, [rip + g3_queue_write]
    jae .Lg3_closure_pass_end
    lea rdx, [rip + g3_queue]
    movzx eax, byte ptr [rdx + rax]
    inc qword ptr [rip + g3_queue_read]
    imul rax, rax, G3_RECORD
    lea r12, [rip + g3_candidates]
    add r12, rax
    mov r14, [r12 + 16]
    mov r15, [r12 + 24]
.Lg3_closure_dep:
    test r15, r15
    jz .Lg3_closure_next
    mov rdi, [r14]
    call g3_mark
    cmp eax, 2
    je .Lg3_search_return
    test eax, eax
    jz .Lg3_search_unsat
    add r14, 16
    dec r15
    jmp .Lg3_closure_dep
.Lg3_closure_next:
    jmp .Lg3_closure_candidate
.Lg3_closure_pass_end:
    lea r12, [rip + g3_roots]
    xor r13d, r13d
.Lg3_check_roots:
    cmp r13, [rip + g3_root_count]
    jae .Lg3_check_candidates_begin
    mov rdi, [r12]
    mov rsi, [r12 + 8]
    call g3_check
    test eax, eax
    jnz .Lg3_search_return
    add r12, 16
    inc r13
    jmp .Lg3_check_roots
.Lg3_check_candidates_begin:
    xor r13d, r13d
.Lg3_check_candidate:
    cmp r13, [rip + g3_candidate_count]
    jae .Lg3_find_unresolved
    lea rax, [rip + g3_solution]
    cmp byte ptr [rax + r13], 0
    je .Lg3_check_candidate_next
    lea rax, [rip + g3_required]
    cmp byte ptr [rax + r13], 0
    je .Lg3_check_candidate_next
    imul rax, r13, G3_RECORD
    lea r12, [rip + g3_candidates]
    add r12, rax
    mov r14, [r12 + 16]
    mov r15, [r12 + 24]
.Lg3_check_dep:
    test r15, r15
    jz .Lg3_check_candidate_next
    mov rdi, [r14]
    mov rsi, [r14 + 8]
    call g3_check
    test eax, eax
    jnz .Lg3_search_return
    add r14, 16
    dec r15
    jmp .Lg3_check_dep
.Lg3_check_candidate_next:
    inc r13
    jmp .Lg3_check_candidate
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
 * All strings/arrays must remain readable during the call. Limit<=100000.
 * Outputs: RAX=0 solved,1 unsatisfiable,2 resource bound,3 malformed graph.
 * solution[i]=1 for exactly the reachable graph on success, all zero on error.
 * Validates every supplied candidate, even inactive ones; rejects duplicates.
 * Sort scratch2048, reachability256, recursion<=256*40 saved bytes. */
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
    jae .Lg3_sort_begin
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
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
g3_any: .asciz "*"
g3_zero: .asciz "0.0.0"
.section .data
.balign 8
g3_limit: .quad 100000
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
g3_queue_read: .skip 8
g3_queue_write: .skip 8
g3_queue: .skip G3_CANDIDATES
