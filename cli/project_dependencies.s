/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Mandatory same-registry source declarations for the optional V2 client.
 * SysV ABI; returning routines preserve RBX/RBP/R12-R15. Serial owned state.
 */
.intel_syntax noprefix
.equ G3_PROJECT_DEP_RECORD, 240
.equ G3_PROJECT_DEP_LIMIT, 64
.section .text

/* RDI=NUL manifest, at most8190 ASCII bytes. EAX=0 valid,1 invalid.
 * Writes g3_project_dep_count and64 owned records: name[105],requirement[129],
 * six padding bytes. Sorts names; rejects duplicate declarations and sections.
 * Other project fields remain the responsibility of the calling parser.
 * Scratch: caller-saved registers,56 stack bytes plus called routines.
 */
g3_project_dependencies:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov qword ptr [rip + g3_project_dep_count], 0
    mov r12, rdi
    xor ecx, ecx
.Lg3p_bound:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lg3p_bound_done
    cmp ecx, 8190
    jae .Lg3p_bad
    cmp eax, 9
    je .Lg3p_bound_next
    cmp eax, 10
    je .Lg3p_bound_next
    cmp eax, 13
    je .Lg3p_bound_next
    cmp eax, 32
    jb .Lg3p_bad
    cmp eax, 126
    ja .Lg3p_bad
.Lg3p_bound_next:
    inc ecx
    jmp .Lg3p_bound
.Lg3p_bound_done:
    test ecx, ecx
    jz .Lg3p_bad
    xor r13d, r13d
    xor r14d, r14d
.Lg3p_line:
    call g3_project_horizontal
    mov al, [r12]
    test al, al
    jz .Lg3p_sort
    cmp al, 10
    je .Lg3p_next
    cmp al, '#'
    je .Lg3p_skip
    cmp al, '['
    je .Lg3p_section
    test r13d, r13d
    jz .Lg3p_skip
    mov rax, [rip + g3_project_dep_count]
    cmp rax, G3_PROJECT_DEP_LIMIT
    jae .Lg3p_bad
    imul rax, rax, G3_PROJECT_DEP_RECORD
    lea r15, [rip + g3_project_deps]
    add r15, rax
    mov rdi, r15
    mov esi, 105
    call g3_project_string
    test eax, eax
    jnz .Lg3p_bad
    call g3_project_horizontal
    cmp byte ptr [r12], '='
    jne .Lg3p_bad
    inc r12
    call g3_project_horizontal
    lea rdi, [r15 + 105]
    mov esi, 129
    call g3_project_string
    test eax, eax
    jnz .Lg3p_bad
    mov rdi, r15
    call registry_valid_package
    test eax, eax
    jz .Lg3p_bad
    lea rdi, [r15 + 105]
    lea rsi, [rip + g3_project_zero]
    call g3_requirement
    cmp eax, -1
    je .Lg3p_bad
    lea rbx, [rip + g3_project_deps]
    xor ebp, ebp
.Lg3p_duplicate:
    cmp rbp, [rip + g3_project_dep_count]
    jae .Lg3p_accept
    mov rdi, rbx
    mov rsi, r15
    call streq
    test eax, eax
    jnz .Lg3p_bad
    add rbx, G3_PROJECT_DEP_RECORD
    inc rbp
    jmp .Lg3p_duplicate
.Lg3p_accept:
    inc qword ptr [rip + g3_project_dep_count]
    jmp .Lg3p_line_end
.Lg3p_section:
    inc r12
    lea rdi, [rip + g3_project_section]
    xor ecx, ecx
.Lg3p_section_byte:
    mov al, [r12]
    cmp al, ']'
    je .Lg3p_section_end
    cmp al, 32
    jb .Lg3p_bad
    cmp ecx, 63
    jae .Lg3p_bad
    mov [rdi + rcx], al
    inc r12
    inc ecx
    jmp .Lg3p_section_byte
.Lg3p_section_end:
    mov byte ptr [rdi + rcx], 0
    inc r12
    lea rsi, [rip + g3_project_dependency_section]
    call streq
    mov r13d, eax
    test eax, eax
    jz .Lg3p_non_dependency
    test r14d, r14d
    jnz .Lg3p_bad
    mov r14d, 1
    jmp .Lg3p_line_end
.Lg3p_non_dependency:
    lea rdi, [rip + g3_project_section]
    lea rsi, [rip + g3_project_feature_section]
    call streq
    test eax, eax
    jnz .Lg3p_bad
    lea rdi, [rip + g3_project_section]
    lea rsi, [rip + g3_project_resolution_section]
    call streq
    test eax, eax
    jnz .Lg3p_bad
.Lg3p_line_end:
    call g3_project_horizontal
    mov al, [r12]
    test al, al
    jz .Lg3p_sort
    cmp al, '#'
    je .Lg3p_skip
    cmp al, 10
    jne .Lg3p_bad
.Lg3p_next:
    inc r12
    jmp .Lg3p_line
.Lg3p_skip:
    mov al, [r12]
    test al, al
    jz .Lg3p_sort
    inc r12
    cmp al, 10
    jne .Lg3p_skip
    jmp .Lg3p_line
.Lg3p_sort:
    xor ebp, ebp
.Lg3p_sort_outer:
    cmp rbp, [rip + g3_project_dep_count]
    jae .Lg3p_ok
    imul rax, rbp, G3_PROJECT_DEP_RECORD
    lea rbx, [rip + g3_project_deps]
    add rbx, rax
    lea r14, [rbp + 1]
    lea r15, [rbx + G3_PROJECT_DEP_RECORD]
.Lg3p_sort_inner:
    cmp r14, [rip + g3_project_dep_count]
    jae .Lg3p_sort_next
    mov rdi, rbx
    mov rsi, r15
    call r2_lex
    test eax, eax
    jle .Lg3p_sort_keep
    xor ecx, ecx
.Lg3p_swap:
    mov rax, [rbx + rcx]
    mov rdx, [r15 + rcx]
    mov [rbx + rcx], rdx
    mov [r15 + rcx], rax
    add ecx, 8
    cmp ecx, G3_PROJECT_DEP_RECORD
    jb .Lg3p_swap
.Lg3p_sort_keep:
    inc r14
    add r15, G3_PROJECT_DEP_RECORD
    jmp .Lg3p_sort_inner
.Lg3p_sort_next:
    inc rbp
    jmp .Lg3p_sort_outer
.Lg3p_ok:
    xor eax, eax
    jmp .Lg3p_return
.Lg3p_bad:
    mov qword ptr [rip + g3_project_dep_count], 0
    mov eax, 1
.Lg3p_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* R12=cursor, RDI=owned destination, ESI=capacity including NUL.
 * EAX=0 success,1 invalid; advances R12 only within the bounded manifest.
 * No escapes, multiline strings, or control bytes. Scratch RAX/RCX/RDX. */
g3_project_string:
    cmp byte ptr [r12], '"'
    jne .Lg3p_string_bad
    inc r12
    xor ecx, ecx
    dec esi
.Lg3p_string_byte:
    movzx eax, byte ptr [r12]
    cmp al, '"'
    je .Lg3p_string_end
    cmp eax, 32
    jb .Lg3p_string_bad
    cmp al, '\\'
    je .Lg3p_string_bad
    cmp ecx, esi
    jae .Lg3p_string_bad
    mov [rdi + rcx], al
    inc ecx
    inc r12
    jmp .Lg3p_string_byte
.Lg3p_string_end:
    mov byte ptr [rdi + rcx], 0
    inc r12
    xor eax, eax
    ret
.Lg3p_string_bad:
    mov eax, 1
    ret

/* R12=cursor; skip horizontal whitespace and CR. Scratch RAX. */
g3_project_horizontal:
    mov al, [r12]
    cmp al, 32
    je .Lg3p_horizontal_next
    cmp al, 9
    je .Lg3p_horizontal_next
    cmp al, 13
    jne .Lg3p_horizontal_done
.Lg3p_horizontal_next:
    inc r12
    jmp g3_project_horizontal
.Lg3p_horizontal_done:
    ret

/* RDI=validated publication object token. Writes r2_dependencies/count.
 * Optional dependency array is sorted and unique; records use the project ABI.
 * Fatal invalid input uses the existing V2 cleanup path. Stack40 plus callees.
 */
g3_manifest_dependencies:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov qword ptr [rip + r2_dependency_count], 0
    lea rsi, [rip + g3_project_dependency_section]
    call r2_member
    test rax, rax
    jz .Lg3m_done
    cmp qword ptr [rax], SMP_ARRAY
    jne r2_invalid
    mov r14, [rax + 24]
    lea rbx, [rax + 32]
    xor r15d, r15d
.Lg3m_next:
    lea rax, [rip + smp_tokens]
    mov rdx, rbx
    sub rdx, rax
    shr rdx, 5
    cmp rdx, r14
    jae .Lg3m_done
    mov rax, [rip + r2_dependency_count]
    cmp rax, G3_PROJECT_DEP_LIMIT
    jae r2_invalid
    imul rax, rax, G3_PROJECT_DEP_RECORD
    lea r12, [rip + r2_dependencies]
    add r12, rax
    mov rdi, rbx
    lea rsi, [rip + g3_manifest_fields]
    mov edx, 2
    mov ecx, 2
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
    test r15, r15
    jz .Lg3m_accept
    mov rdi, r15
    mov rsi, r12
    call r2_lex
    test eax, eax
    jns r2_invalid
.Lg3m_accept:
    mov r15, r12
    inc qword ptr [rip + r2_dependency_count]
    mov rax, [rbx + 24]
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    jmp .Lg3m_next
.Lg3m_done:
    pop r15
    pop r14
    pop r13
    pop r12
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

.section .rodata
g3_project_dependency_section: .asciz "dependencies"
g3_project_feature_section: .asciz "features"
g3_project_resolution_section: .asciz "resolution"
g3_project_zero: .asciz "0.0.0"
g3_manifest_fields: .asciz "name\0requirement\0"
g3_manifest_requirement: .asciz "requirement"
.section .bss
.balign 8
g3_project_dep_count: .skip 8
g3_project_deps: .skip G3_PROJECT_DEP_LIMIT * G3_PROJECT_DEP_RECORD
g3_project_section: .skip 64
