/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native source and signed dependency-feature declarations.
 * SysV inputs RDI/RSI/RDX; RAX result. Preserve RBX/RBP/R12-R15.
 * Owned serial state:64 dependency records240, profiles11296 each. Source
 * manifests<=8190 ASCII bytes;64 definitions/list entries; text pool8192.
 */
.intel_syntax noprefix
.equ G3_PROJECT_DEP_RECORD, 240
.equ G3_PROJECT_DEP_LIMIT, 64
.section .text

/* RDI=NUL source manifest<=8190 bytes. EAX=0 valid,1 invalid. Writes sorted
 * g3_project_deps/count and g4_project_profile. Other recipe fields stay with
 * the caller's strict project parser. No input bytes change. Stack56. */
g3_project_dependencies:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, rdi
    mov qword ptr [rip + g3_project_dep_count], 0
    lea rdi, [rip + g4_project_profile]
    call g4_profile_init
    mov [rip + g4_parser_profile], rax
    xor ecx, ecx
.Lg4p_bound:
    movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz .Lg4p_bound_done
    cmp ecx, 8190
    jae .Lg4p_bad
    cmp eax, 9
    je .Lg4p_bound_next
    cmp eax, 10
    je .Lg4p_bound_next
    cmp eax, 13
    je .Lg4p_bound_next
    cmp eax, 32
    jb .Lg4p_bad
    cmp eax, 126
    ja .Lg4p_bad
.Lg4p_bound_next:
    inc ecx
    jmp .Lg4p_bound
.Lg4p_bound_done:
    test ecx, ecx
    jz .Lg4p_bad
    xor r13d, r13d
    xor r14d, r14d
.Lg4p_line:
    call g3_project_horizontal
    mov al, [r12]
    test al, al
    jz .Lg4p_finish
    cmp al, 10
    je .Lg4p_next
    cmp al, '#'
    je .Lg4p_skip
    cmp al, '['
    je .Lg4p_section
    cmp r13d, 1
    je .Lg4p_dependency
    cmp r13d, 2
    je .Lg4p_feature
    jmp .Lg4p_skip
.Lg4p_dependency:
    mov rax, [rip + g3_project_dep_count]
    cmp rax, 64
    jae .Lg4p_bad
    imul rax, rax, 240
    lea r15, [rip + g3_project_deps]
    add r15, rax
    mov rdi, r15
    mov esi, 105
    call g3_project_string
    test eax, eax
    jnz .Lg4p_bad
    mov rdi, r15
    call registry_valid_package
    test eax, eax
    jz .Lg4p_bad
    call g3_project_horizontal
    cmp byte ptr [r12], '='
    jne .Lg4p_bad
    inc r12
    call g3_project_horizontal
    mov rax, [rip + g3_project_dep_count]
    imul rax, rax, 24
    lea rbx, [rip + g4_project_profile + G4_OPTIONS]
    add rbx, rax
    mov qword ptr [rbx], 2
    cmp byte ptr [r12], '{'
    je .Lg4p_inline
    lea rdi, [r15 + 105]
    mov esi, 129
    call g3_project_string
    test eax, eax
    jnz .Lg4p_bad
    jmp .Lg4p_dependency_range
.Lg4p_inline:
    inc r12
    xor ebp, ebp
.Lg4p_inline_field:
    call g3_project_horizontal
    lea rdi, [rip + g4_parser_key]
    mov esi, 33
    call g4_project_identifier
    test eax, eax
    jnz .Lg4p_bad
    call g3_project_horizontal
    cmp byte ptr [r12], '='
    jne .Lg4p_bad
    inc r12
    call g3_project_horizontal
    lea rdi, [rip + g4_parser_key]
    lea rsi, [rip + g4_key_version]
    call streq
    test eax, eax
    jnz .Lg4p_inline_version
    lea rdi, [rip + g4_parser_key]
    lea rsi, [rip + g4_key_optional]
    call streq
    test eax, eax
    jnz .Lg4p_inline_optional
    lea rdi, [rip + g4_parser_key]
    lea rsi, [rip + g4_key_source_defaults]
    call streq
    test eax, eax
    jnz .Lg4p_inline_defaults
    lea rdi, [rip + g4_parser_key]
    lea rsi, [rip + g3_project_feature_section]
    call streq
    test eax, eax
    jz .Lg4p_bad
    test ebp, 8
    jnz .Lg4p_bad
    or ebp, 8
    mov rdi, rbx
    call g4_source_array
    test eax, eax
    jnz .Lg4p_bad
    jmp .Lg4p_inline_end
.Lg4p_inline_version:
    test ebp, 1
    jnz .Lg4p_bad
    or ebp, 1
    lea rdi, [r15 + 105]
    mov esi, 129
    call g3_project_string
    test eax, eax
    jnz .Lg4p_bad
    jmp .Lg4p_inline_end
.Lg4p_inline_optional:
    test ebp, 2
    jnz .Lg4p_bad
    or ebp, 2
    call g4_source_bool
    cmp eax, -1
    je .Lg4p_bad
    and qword ptr [rbx], -2
    or [rbx], rax
    jmp .Lg4p_inline_end
.Lg4p_inline_defaults:
    test ebp, 4
    jnz .Lg4p_bad
    or ebp, 4
    call g4_source_bool
    cmp eax, -1
    je .Lg4p_bad
    shl rax, 1
    and qword ptr [rbx], -3
    or [rbx], rax
.Lg4p_inline_end:
    call g3_project_horizontal
    cmp byte ptr [r12], '}'
    je .Lg4p_inline_done
    cmp byte ptr [r12], ','
    jne .Lg4p_bad
    inc r12
    jmp .Lg4p_inline_field
.Lg4p_inline_done:
    test ebp, 1
    jz .Lg4p_bad
    inc r12
.Lg4p_dependency_range:
    lea rdi, [r15 + 105]
    lea rsi, [rip + g3_project_zero]
    call g3_requirement
    cmp eax, -1
    je .Lg4p_bad
    inc qword ptr [rip + g3_project_dep_count]
    jmp .Lg4p_line_end
.Lg4p_feature:
    mov rax, [rip + g4_project_profile + 16]
    cmp rax, 64
    jae .Lg4p_bad
    imul rax, rax, 24
    lea r15, [rip + g4_project_profile + G4_DEFINITIONS]
    add r15, rax
    cmp byte ptr [r12], '"'
    je .Lg4p_feature_quoted
    lea rdi, [rip + g4_parser_text]
    mov esi, 33
    call g4_project_identifier
    test eax, eax
    jnz .Lg4p_bad
    jmp .Lg4p_feature_name
.Lg4p_feature_quoted:
    lea rdi, [rip + g4_parser_text]
    mov esi, 33
    call g3_project_string
    test eax, eax
    jnz .Lg4p_bad
.Lg4p_feature_name:
    lea rsi, [rip + g4_parser_text]
    call g4_parser_pool
    test rax, rax
    jz .Lg4p_bad
    mov [r15], rax
    call g3_project_horizontal
    cmp byte ptr [r12], '='
    jne .Lg4p_bad
    inc r12
    call g3_project_horizontal
    mov rdi, r15
    call g4_source_array
    test eax, eax
    jnz .Lg4p_bad
    inc qword ptr [rip + g4_project_profile + 16]
    jmp .Lg4p_line_end
.Lg4p_section:
    inc r12
    lea rdi, [rip + g3_project_section]
    xor ecx, ecx
.Lg4p_section_byte:
    mov al, [r12]
    cmp al, ']'
    je .Lg4p_section_end
    cmp al, 32
    jb .Lg4p_bad
    cmp ecx, 63
    jae .Lg4p_bad
    mov [rdi + rcx], al
    inc r12
    inc ecx
    jmp .Lg4p_section_byte
.Lg4p_section_end:
    mov byte ptr [rdi + rcx], 0
    inc r12
    xor r13d, r13d
    lea rsi, [rip + g3_project_dependency_section]
    call streq
    test eax, eax
    jnz .Lg4p_dep_section
    lea rdi, [rip + g3_project_section]
    lea rsi, [rip + g3_project_feature_section]
    call streq
    test eax, eax
    jnz .Lg4p_feat_section
    lea rdi, [rip + g3_project_section]
    lea rsi, [rip + g3_project_resolution_section]
    call streq
    test eax, eax
    jnz .Lg4p_bad
    jmp .Lg4p_line_end
.Lg4p_dep_section:
    test r14d, 1
    jnz .Lg4p_bad
    or r14d, 1
    mov r13d, 1
    jmp .Lg4p_line_end
.Lg4p_feat_section:
    test r14d, 2
    jnz .Lg4p_bad
    or r14d, 2
    mov r13d, 2
.Lg4p_line_end:
    call g3_project_horizontal
    mov al, [r12]
    test al, al
    jz .Lg4p_finish
    cmp al, '#'
    je .Lg4p_skip
    cmp al, 10
    jne .Lg4p_bad
.Lg4p_next:
    inc r12
    jmp .Lg4p_line
.Lg4p_skip:
    mov al, [r12]
    test al, al
    jz .Lg4p_finish
    inc r12
    cmp al, 10
    jne .Lg4p_skip
    jmp .Lg4p_line
.Lg4p_finish:
    call g4_source_sort
    test eax, eax
    jnz .Lg4p_bad
    lea rdi, [rip + g4_project_profile]
    lea rsi, [rip + g3_project_deps]
    mov rdx, [rip + g3_project_dep_count]
    call g4_parser_validate
    jmp .Lg4p_return
.Lg4p_bad:
    mov eax, 1
.Lg4p_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* R12=cursor,RDI=destination,ESI=capacity including NUL. EAX=0/1. Bounded
 * plain quoted string; no escapes, control bytes, or input mutation. */
g3_project_string:
    cmp byte ptr [r12], '"'
    jne .Lg4_string_bad
    inc r12
    xor ecx, ecx
.Lg4_string_byte:
    mov al, [r12]
    cmp al, '"'
    je .Lg4_string_end
    cmp al, 32
    jb .Lg4_string_bad
    cmp al, 126
    ja .Lg4_string_bad
    cmp al, '\\'
    je .Lg4_string_bad
    inc ecx
    cmp ecx, esi
    jae .Lg4_string_bad
    mov [rdi + rcx - 1], al
    inc r12
    jmp .Lg4_string_byte
.Lg4_string_end:
    mov byte ptr [rdi + rcx], 0
    inc r12
    xor eax, eax
    ret
.Lg4_string_bad:
    mov eax, 1
    ret

/* R12=cursor,RDI=destination,ESI=capacity. Read an unquoted key. EAX0/1. */
g4_project_identifier:
    xor ecx, ecx
.Lg4_identifier_byte:
    mov al, [r12]
    cmp al, 'a'
    jb .Lg4_identifier_other
    cmp al, 'z'
    jbe .Lg4_identifier_accept
.Lg4_identifier_other:
    test ecx, ecx
    jz .Lg4_identifier_end
    cmp al, '0'
    jb .Lg4_identifier_symbol
    cmp al, '9'
    jbe .Lg4_identifier_accept
.Lg4_identifier_symbol:
    cmp al, '_'
    je .Lg4_identifier_accept
    cmp al, '-'
    jne .Lg4_identifier_end
.Lg4_identifier_accept:
    inc ecx
    cmp ecx, esi
    jae .Lg4_identifier_bad
    mov [rdi + rcx - 1], al
    inc r12
    jmp .Lg4_identifier_byte
.Lg4_identifier_end:
    test ecx, ecx
    jz .Lg4_identifier_bad
    mov byte ptr [rdi + rcx], 0
    xor eax, eax
    ret
.Lg4_identifier_bad:
    mov eax, 1
    ret

/* R12=cursor, EAX=1/0 boolean or-1 invalid; delimiter remains unconsumed. */
g4_source_bool:
    lea rsi, [rip + g4_true]
    mov r8d, 1
    cmp byte ptr [r12], 't'
    je .Lg4_bool_scan_start
    lea rsi, [rip + g4_false]
    xor r8d, r8d
.Lg4_bool_scan_start:
    xor ecx, ecx
.Lg4_bool_scan:
    mov al, [rsi + rcx]
    test al, al
    jz .Lg4_bool_done
    cmp al, [r12 + rcx]
    jne .Lg4_bool_bad
    inc ecx
    jmp .Lg4_bool_scan
.Lg4_bool_done:
    add r12, rcx
    mov eax, r8d
    ret
.Lg4_bool_bad:
    mov rax, -1
    ret

g3_project_horizontal:
    mov al, [r12]
    cmp al, 32
    je .Lg4_horizontal_next
    cmp al, 9
    je .Lg4_horizontal_next
    cmp al, 13
    jne .Lg4_horizontal_done
.Lg4_horizontal_next:
    inc r12
    jmp g3_project_horizontal
.Lg4_horizontal_done:
    ret

/* RSI=plain NUL string<=137bytes. Append to active owned profile text pool.
 * RAX=owned pointer,0 if capacity exhausted. Scratch caller registers; stack24. */
g4_parser_pool:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov rdi, rsi
    call strlen
    inc rax
    mov rbx, [rip + g4_parser_profile]
    mov r13, [rbx + G4_TEXT_USED]
    lea rdx, [r13 + rax]
    cmp rdx, G4_TEXT_BYTES
    ja .Lg4_pool_bad
    mov [rbx + G4_TEXT_USED], rdx
    lea rdi, [rbx + r13 + G4_TEXT]
    mov r13, rdi
    mov rsi, r12
    mov rcx, rax
    rep movsb
    mov rax, r13
    jmp .Lg4_pool_return
.Lg4_pool_bad:
    xor eax, eax
.Lg4_pool_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=option/definition24. Parse its array into the active profile. The first
 * qword is preserved; listptr/count written at8/16. Sort source members and
 * reject duplicates. EAX0/1. String pool remains bounded even on failure. */
g4_source_array:
    push rbx
    push rbp
    push r13
    push r14
    push r15
    mov rbx, rdi
    cmp byte ptr [r12], '['
    jne .Lg4_array_bad
    inc r12
    mov qword ptr [rbx + 8], 0
    mov qword ptr [rbx + 16], 0
    mov qword ptr [rip + g4_array_count], 0
    mov rax, [rip + g4_parser_profile]
    mov rax, [rax + G4_TEXT_USED]
    mov [rip + g4_array_start], rax
    call g3_project_horizontal
    cmp byte ptr [r12], ']'
    je .Lg4_array_done
.Lg4_array_value:
    mov rax, [rip + g4_array_count]
    cmp rax, 64
    jae .Lg4_array_bad
    lea rdi, [rip + g4_parser_text]
    mov esi, 138
    call g3_project_string
    test eax, eax
    jnz .Lg4_array_bad
    lea rsi, [rip + g4_parser_text]
    call g4_parser_pool
    test rax, rax
    jz .Lg4_array_bad
    mov rdx, [rip + g4_array_count]
    lea rcx, [rip + g4_array_pointers]
    mov [rcx + rdx*8], rax
    inc qword ptr [rip + g4_array_count]
    call g3_project_horizontal
    cmp byte ptr [r12], ']'
    je .Lg4_array_done
    cmp byte ptr [r12], ','
    jne .Lg4_array_bad
    inc r12
    call g3_project_horizontal
    cmp byte ptr [r12], ']'
    jne .Lg4_array_value
.Lg4_array_done:
    inc r12
    call g4_array_sort
    test eax, eax
    jnz .Lg4_array_bad
    mov rax, [rip + g4_array_count]
    mov [rbx + 16], rax
    test rax, rax
    jz .Lg4_array_ok
    mov rax, [rip + g4_parser_profile]
    add rax, G4_TEXT
    add rax, [rip + g4_array_start]
    mov [rbx + 8], rax
.Lg4_array_ok:
    xor eax, eax
    jmp .Lg4_array_return
.Lg4_array_bad:
    mov eax, 1
.Lg4_array_return:
    pop r15
    pop r14
    pop r13
    pop rbp
    pop rbx
    ret

/* Sort <=64 borrowed pointers and rewrite their contiguous owned text span.
 * EAX0/1; duplicates rejected. Shared scratch8192+64 pointers. Stack40. */
g4_array_sort:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    lea r12, [rip + g4_array_pointers]
    xor ebx, ebx
.Lg4_sort_array_outer:
    cmp rbx, [rip + g4_array_count]
    jae .Lg4_sort_array_copy
    lea rbp, [rbx + 1]
.Lg4_sort_array_inner:
    cmp rbp, [rip + g4_array_count]
    jae .Lg4_sort_array_next
    mov rdi, [r12 + rbx*8]
    mov rsi, [r12 + rbp*8]
    call r2_lex
    test eax, eax
    jz .Lg4_sort_array_bad
    js .Lg4_sort_array_keep
    mov rax, [r12 + rbx*8]
    mov rdx, [r12 + rbp*8]
    mov [r12 + rbx*8], rdx
    mov [r12 + rbp*8], rax
.Lg4_sort_array_keep:
    inc rbp
    jmp .Lg4_sort_array_inner
.Lg4_sort_array_next:
    inc rbx
    jmp .Lg4_sort_array_outer
.Lg4_sort_array_copy:
    lea r13, [rip + g4_array_buffer]
    mov r14, r13
    xor ebx, ebx
.Lg4_sort_array_string:
    cmp rbx, [rip + g4_array_count]
    jae .Lg4_sort_array_restore
    mov rsi, [r12 + rbx*8]
    mov rdi, r14
    call copy_string
    lea r14, [rax + 1]
    inc rbx
    jmp .Lg4_sort_array_string
.Lg4_sort_array_restore:
    mov rcx, r14
    sub rcx, r13
    mov rdi, [rip + g4_parser_profile]
    add rdi, G4_TEXT
    add rdi, [rip + g4_array_start]
    mov rsi, r13
    rep movsb
    xor eax, eax
    jmp .Lg4_sort_array_return
.Lg4_sort_array_bad:
    mov eax, 1
.Lg4_sort_array_return:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Sort source dependencies with their options, then feature definitions.
 * EAX0/1; strict uniqueness applies regardless of whether a feature is used. */
g4_source_sort:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    xor ebx, ebx
.Lg4_sort_dep_outer:
    cmp rbx, [rip + g3_project_dep_count]
    jae .Lg4_sort_defs_start
    lea rbp, [rbx + 1]
.Lg4_sort_dep_inner:
    cmp rbp, [rip + g3_project_dep_count]
    jae .Lg4_sort_dep_next
    imul rax, rbx, 240
    imul rdx, rbp, 240
    lea r12, [rip + g3_project_deps]
    lea r13, [r12 + rdx]
    add r12, rax
    mov rdi, r12
    mov rsi, r13
    call r2_lex
    test eax, eax
    jz .Lg4_sort_source_bad
    js .Lg4_sort_dep_keep
    xor ecx, ecx
.Lg4_swap_dep:
    mov rax, [r12 + rcx]
    mov rdx, [r13 + rcx]
    mov [r12 + rcx], rdx
    mov [r13 + rcx], rax
    add rcx, 8
    cmp rcx, 240
    jb .Lg4_swap_dep
    imul rax, rbx, 24
    imul rdx, rbp, 24
    lea r12, [rip + g4_project_profile + G4_OPTIONS]
    lea r13, [r12 + rdx]
    add r12, rax
    xor ecx, ecx
.Lg4_swap_option:
    mov rax, [r12 + rcx]
    mov rdx, [r13 + rcx]
    mov [r12 + rcx], rdx
    mov [r13 + rcx], rax
    add rcx, 8
    cmp rcx, 24
    jb .Lg4_swap_option
.Lg4_sort_dep_keep:
    inc rbp
    jmp .Lg4_sort_dep_inner
.Lg4_sort_dep_next:
    inc rbx
    jmp .Lg4_sort_dep_outer
.Lg4_sort_defs_start:
    xor ebx, ebx
.Lg4_sort_def_outer:
    cmp rbx, [rip + g4_project_profile + 16]
    jae .Lg4_sort_source_ok
    lea rbp, [rbx + 1]
.Lg4_sort_def_inner:
    cmp rbp, [rip + g4_project_profile + 16]
    jae .Lg4_sort_def_next
    imul rax, rbx, 24
    imul rdx, rbp, 24
    lea r12, [rip + g4_project_profile + G4_DEFINITIONS]
    lea r13, [r12 + rdx]
    add r12, rax
    mov rdi, [r12]
    mov rsi, [r13]
    call r2_lex
    test eax, eax
    jz .Lg4_sort_source_bad
    js .Lg4_sort_def_keep
    xor ecx, ecx
.Lg4_swap_def:
    mov rax, [r12 + rcx]
    mov rdx, [r13 + rcx]
    mov [r12 + rcx], rdx
    mov [r13 + rcx], rax
    add rcx, 8
    cmp rcx, 24
    jb .Lg4_swap_def
.Lg4_sort_def_keep:
    inc rbp
    jmp .Lg4_sort_def_inner
.Lg4_sort_def_next:
    inc rbx
    jmp .Lg4_sort_def_outer
.Lg4_sort_source_ok:
    xor eax, eax
    jmp .Lg4_sort_source_return
.Lg4_sort_source_bad:
    mov eax, 1
.Lg4_sort_source_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=profile,RSI=records240,RDX=count. EAX0/1; construct the pure model's
 * borrowed dependency-pair view without changing owned declarations. */
g4_parser_validate:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rdx
    lea rdi, [rip + g4_parser_pairs]
    mov rcx, rdx
.Lg4_pair_next:
    test rcx, rcx
    jz .Lg4_pair_done
    mov [rdi], rsi
    lea rax, [rsi + 105]
    mov [rdi + 8], rax
    add rdi, 16
    add rsi, 240
    dec rcx
    jmp .Lg4_pair_next
.Lg4_pair_done:
    mov rdi, r12
    lea rsi, [rip + g4_parser_pairs]
    mov rdx, r13
    call g4_profile_validate
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=validated publication object. Own r2_dependencies/count plus the
 * publication feature profile. Missing extension fields retain old defaults.
 * JSON arrays are strictly sorted; source normalization supplies that order.
 * Stack48 plus bounded JSON/model helpers. Fatal errors preserve caller files. */
g3_manifest_dependencies:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbp, rdi
    lea rdi, [rip + g4_publication_profile]
    call g4_profile_init
    mov [rip + g4_parser_profile], rax
    mov qword ptr [rip + r2_dependency_count], 0
    mov rdi, rbp
    lea rsi, [rip + g3_project_dependency_section]
    call r2_member
    test rax, rax
    jz .Lg4m_features
    cmp qword ptr [rax], SMP_ARRAY
    jne r2_invalid
    mov r14, [rax + 24]
    lea rbx, [rax + 32]
    xor r15d, r15d
.Lg4m_dependency:
    lea rax, [rip + smp_tokens]
    mov rdx, rbx
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lg4m_features
    mov rax, [rip + r2_dependency_count]
    cmp rax, 64
    jae r2_invalid
    imul rdx, rax, 24
    lea r13, [rip + g4_publication_profile + G4_OPTIONS]
    add r13, rdx
    mov qword ptr [r13], 2
    imul rax, rax, 240
    lea r12, [rip + r2_dependencies]
    add r12, rax
    mov rdi, rbx
    lea rsi, [rip + g3_manifest_fields]
    mov edx, 2
    mov ecx, 5
    call r2_keys
    mov rdi, rbx
    lea rsi, [rip + r2_k_name]
    call r2_required
    mov rdi, rax
    mov rsi, r12
    mov edx, 105
    call r2_string
    mov rdi, r12
    call registry_valid_package
    test eax, eax
    jz r2_invalid
    mov rdi, rbx
    lea rsi, [rip + g3_manifest_requirement]
    call r2_required
    mov rdi, rax
    lea rsi, [r12 + 105]
    mov edx, 129
    call r2_string
    lea rdi, [r12 + 105]
    lea rsi, [rip + g3_project_zero]
    call g3_requirement
    cmp eax, -1
    je r2_invalid
    mov rdi, rbx
    lea rsi, [rip + g4_key_optional]
    call r2_member
    test rax, rax
    jz .Lg4m_defaults
    mov rdi, rax
    call g4_json_bool
    or [r13], rax
.Lg4m_defaults:
    mov rdi, rbx
    lea rsi, [rip + g4_key_json_defaults]
    call r2_member
    test rax, rax
    jz .Lg4m_requested
    mov rdi, rax
    call g4_json_bool
    shl rax, 1
    and qword ptr [r13], -3
    or [r13], rax
.Lg4m_requested:
    mov rdi, rbx
    lea rsi, [rip + g3_project_feature_section]
    call r2_member
    test rax, rax
    jz .Lg4m_dependency_order
    mov rdi, rax
    mov rsi, r13
    mov edx, 33
    call g4_json_array
.Lg4m_dependency_order:
    test r15, r15
    jz .Lg4m_dependency_accept
    mov rdi, r15
    mov rsi, r12
    call r2_lex
    test eax, eax
    jns r2_invalid
.Lg4m_dependency_accept:
    mov r15, r12
    inc qword ptr [rip + r2_dependency_count]
    mov rax, [rbx + 24]
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    jmp .Lg4m_dependency
.Lg4m_features:
    mov rdi, rbp
    lea rsi, [rip + g3_project_feature_section]
    call r2_member
    test rax, rax
    jz .Lg4m_validate
    cmp qword ptr [rax], SMP_ARRAY
    jne r2_invalid
    mov r14, [rax + 24]
    lea rbx, [rax + 32]
    xor r15d, r15d
.Lg4m_definition:
    lea rax, [rip + smp_tokens]
    mov rdx, rbx
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lg4m_validate
    mov rax, [rip + g4_publication_profile + 16]
    cmp rax, 64
    jae r2_invalid
    imul rax, rax, 24
    lea r12, [rip + g4_publication_profile + G4_DEFINITIONS]
    add r12, rax
    mov rdi, rbx
    lea rsi, [rip + g4_manifest_feature_fields]
    mov edx, 2
    mov ecx, 2
    call r2_keys
    mov rdi, rbx
    lea rsi, [rip + r2_k_name]
    call r2_required
    mov rdi, rax
    lea rsi, [rip + g4_parser_text]
    mov edx, 33
    call r2_string
    lea rsi, [rip + g4_parser_text]
    call g4_parser_pool
    test rax, rax
    jz r2_invalid
    mov [r12], rax
    mov rdi, rbx
    lea rsi, [rip + g4_key_members]
    call r2_required
    mov rdi, rax
    mov rsi, r12
    mov edx, 138
    call g4_json_array
    test r15, r15
    jz .Lg4m_feature_accept
    mov rdi, r15
    mov rsi, [r12]
    call r2_lex
    test eax, eax
    jns r2_invalid
.Lg4m_feature_accept:
    mov r15, [r12]
    inc qword ptr [rip + g4_publication_profile + 16]
    mov rax, [rbx + 24]
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    jmp .Lg4m_definition
.Lg4m_validate:
    lea rdi, [rip + g4_publication_profile]
    lea rsi, [rip + r2_dependencies]
    mov rdx, [rip + r2_dependency_count]
    call g4_parser_validate
    test eax, eax
    jnz r2_invalid
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=boolean token. RAX=0/1; other types are invalid, never truthy. */
g4_json_bool:
    cmp qword ptr [rdi], SMP_TRUE
    je .Lg4_json_true
    cmp qword ptr [rdi], SMP_FALSE
    jne r2_invalid
    xor eax, eax
    ret
.Lg4_json_true:
    mov eax, 1
    ret

/* RDI=array token,RSI=option/definition24,EDX=string capacity<=138.
 * Writes owned canonical sorted NUL list at8/count16. Empty lists use NULL.
 * Never modifies JSON token or input buffers. Stack48 plus callees. */
g4_json_array:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    cmp qword ptr [rdi], SMP_ARRAY
    jne r2_invalid
    mov r12d, edx
    mov r13, rsi
    mov r14, [rdi + 24]
    lea rbx, [rdi + 32]
    xor r15d, r15d
    mov qword ptr [r13 + 8], 0
    mov qword ptr [r13 + 16], 0
.Lg4_json_array_next:
    lea rax, [rip + smp_tokens]
    mov rdx, rbx
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lg4_json_array_done
    cmp qword ptr [r13 + 16], 64
    jae r2_invalid
    mov rdi, rbx
    lea rsi, [rip + g4_parser_text]
    mov edx, r12d
    call r2_string
    lea rsi, [rip + g4_parser_text]
    call g4_parser_pool
    test rax, rax
    jz r2_invalid
    mov rbp, rax
    test r15, r15
    jz .Lg4_json_array_first
    mov rdi, r15
    mov rsi, rbp
    call r2_lex
    test eax, eax
    jns r2_invalid
    jmp .Lg4_json_array_accept
.Lg4_json_array_first:
    mov [r13 + 8], rbp
.Lg4_json_array_accept:
    mov r15, rbp
    inc qword ptr [r13 + 16]
    mov rax, [rbx + 24]
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    jmp .Lg4_json_array_next
.Lg4_json_array_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=records in project layout, RSI=count0..64. EAX=0 when identical to the
 * latest parsed source declarations,1 otherwise. Compares strings, not padding.
 * Preserves callee registers; stack24 plus streq. Reads no archive or file. */
g3_compare_dependencies:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    cmp r13, [rip + g3_project_dep_count]
    jne .Lg3c_bad
    xor ebx, ebx
.Lg3c_next:
    cmp rbx, r13
    jae .Lg3c_ok
    imul rax, rbx, G3_PROJECT_DEP_RECORD
    lea rdi, [rip + g3_project_deps]
    add rdi, rax
    lea rsi, [r12 + rax]
    call streq
    test eax, eax
    jz .Lg3c_bad
    imul rax, rbx, G3_PROJECT_DEP_RECORD
    lea rdi, [rip + g3_project_deps + 105]
    add rdi, rax
    lea rsi, [r12 + rax + 105]
    call streq
    test eax, eax
    jz .Lg3c_bad
    inc rbx
    jmp .Lg3c_next
.Lg3c_ok:
    xor eax, eax
    jmp .Lg3c_return
.Lg3c_bad:
    mov eax, 1
.Lg3c_return:
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=expected records240,RSI=count,RDX=expected complete profile.
 * EAX0 same/1different versus latest parsed archived source. Stack24. */
g4_compare_project:
    push rbx
    push r12
    push r13
    mov r12, rdx
    mov r13, rsi
    call g3_compare_dependencies
    test eax, eax
    jnz .Lg4_compare_return
    lea rdi, [rip + g4_project_profile]
    mov rsi, r12
    mov rdx, r13
    call g4_profile_equal
.Lg4_compare_return:
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
g3_project_dependency_section: .asciz "dependencies"
g3_project_feature_section: .asciz "features"
g3_project_resolution_section: .asciz "resolution"
g3_project_zero: .asciz "0.0.0"
g3_manifest_requirement: .asciz "requirement"
g4_key_version: .asciz "version"
g4_key_optional: .asciz "optional"
g4_key_source_defaults: .asciz "default-features"
g4_key_json_defaults: .asciz "default_features"
g4_key_members: .asciz "members"
g4_true: .asciz "true"
g4_false: .asciz "false"
g3_manifest_fields: .asciz "name\0requirement\0optional\0default_features\0features\0"
g4_manifest_feature_fields: .asciz "members\0name\0"
.section .bss
.p2align 3
g3_project_dep_count: .skip 8
g3_project_deps: .skip 64 * 240
g4_project_profile: .skip G4_PROFILE_SIZE
g4_publication_profile: .skip G4_PROFILE_SIZE
g4_parser_profile: .skip 8
g4_parser_pairs: .skip 64 * 16
g4_array_pointers: .skip 64 * 8
g4_array_count: .skip 8
g4_array_start: .skip 8
g4_array_buffer: .skip G4_TEXT_BYTES
g3_project_section: .skip 64
g4_parser_key: .skip 33
g4_parser_text: .skip 138
