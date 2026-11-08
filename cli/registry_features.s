/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Pure, bounded V2 feature profiles. No I/O or input mutation. SysV arguments
 * RDI/RSI/RDX/RCX; RAX result. RBX/RBP/R12-R15 preserved. Other integer
 * registers and flags change. Serial validation scratch is process-owned.
 * Generic profiles borrow readable strings/arrays for the complete call.
 */
.intel_syntax noprefix
.equ G4_PROFILE_SIZE, 11296
.equ G4_OPTIONS, 24
.equ G4_DEFINITIONS, 1560
.equ G4_TEXT, 3096
.equ G4_TEXT_BYTES, 8192
.equ G4_TEXT_USED, 11288
.global g4_profile_init, g4_profile_copy, g4_profile_validate, g4_profile_equal
.section .text
/* RDI=owned writable11296-byte block. RAX=block. Initialize64 options with
 * defaults enabled. Other fields/text are zero. Stack8; no external calls. */
g4_profile_init:
    push rbx
    mov rbx, rdi
    mov ecx, G4_PROFILE_SIZE
    xor eax, eax
    rep stosb
    lea rax, [rbx + G4_OPTIONS]
    mov [rbx], rax
    lea rax, [rbx + G4_DEFINITIONS]
    mov [rbx + 8], rax
    xor ecx, ecx
.Lg4_init_option:
    imul rax, rcx, 24
    mov qword ptr [rbx + rax + G4_OPTIONS], 2
    inc ecx
    cmp ecx, 64
    jb .Lg4_init_option
    mov rax, rbx
    pop rbx
    ret
/* RDI=owned destination,RSI=owned source11296 orNULL. RAX=destination.
 * Rebase nonzero internal pointers. Caller guarantees initialized owned
 * source; generic borrowed profiles cannot be copied. Stack24. */
g4_profile_copy:
    test rsi, rsi
    jz g4_profile_init
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rdi
    sub r12, rsi
    mov ecx, G4_PROFILE_SIZE
    rep movsb
    add [rbx], r12
    add [rbx + 8], r12
    xor r13d, r13d
.Lg4_copy_pointer:
    imul rax, r13, 24
    lea rdx, [rbx + rax + G4_OPTIONS + 8]
    cmp qword ptr [rdx], 0
    je .Lg4_copy_definition
    add [rdx], r12
.Lg4_copy_definition:
    lea rdx, [rbx + rax + G4_DEFINITIONS]
    cmp qword ptr [rdx], 0
    je .Lg4_copy_members
    add [rdx], r12
.Lg4_copy_members:
    cmp qword ptr [rdx + 8], 0
    je .Lg4_copy_next
    add [rdx + 8], r12
.Lg4_copy_next:
    inc r13
    cmp r13, 64
    jb .Lg4_copy_pointer
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret
/* RDI=readable NUL feature identifier. EAX1 valid0invalid. ASCII grammar
 * [a-z][a-z0-9_-]{0,31}. Reads at most33bytes; pointer unchanged; stack0. */
g4_feature_name:
    test rdi, rdi
    jz .Lg4_name_bad
    xor ecx, ecx
.Lg4_name_character:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lg4_name_end
    cmp ecx, 32
    jae .Lg4_name_bad
    cmp eax, 'a'
    jb .Lg4_name_extra
    cmp eax, 'z'
    jbe .Lg4_name_next
.Lg4_name_extra:
    test ecx, ecx
    jz .Lg4_name_bad
    cmp eax, '0'
    jb .Lg4_name_punct
    cmp eax, '9'
    jbe .Lg4_name_next
.Lg4_name_punct:
    cmp eax, '_'
    je .Lg4_name_next
    cmp eax, '-'
    jne .Lg4_name_bad
.Lg4_name_next:
    inc ecx
    jmp .Lg4_name_character
.Lg4_name_end:
    xor eax, eax
    test ecx, ecx
    setne al
    ret
.Lg4_name_bad:
    xor eax, eax
    ret
/* RDI/RSI bounded validated strings. EAX0equal1different; stack0. */
g4_text_equal:
    movzx eax, byte ptr [rdi]
    cmp al, [rsi]
    jne .Lg4_text_different
    test eax, eax
    jz .Lg4_text_return
    inc rdi
    inc rsi
    jmp g4_text_equal
.Lg4_text_different:
    mov eax, 1
.Lg4_text_return:
    ret
/* RDI=validated NUL string. RAX=following list item; stack0. */
g4_next:
    mov rax, rdi
.Lg4_next_byte:
    cmp byte ptr [rax], 0
    lea rax, [rax + 1]
    jne .Lg4_next_byte
    ret
/* RDI=NUL-separated list,RSI=count<=64. EAX0valid1invalid. Validate all
 * identifiers and reject duplicate entries. List pointer may beNULL ifempty.
 * Caller owns readable bytes; bounded names prevent unbounded scans. Stack40. */
g4_names_validate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    cmp r13, 64
    ja .Lg4_names_bad
    test r13, r13
    jz .Lg4_names_good
    test r12, r12
    jz .Lg4_names_bad
    mov r14, r12
    xor ebx, ebx
.Lg4_names_item:
    mov rdi, r14
    call g4_feature_name
    test eax, eax
    jz .Lg4_names_bad
    mov r15, r12
.Lg4_names_duplicate:
    cmp r15, r14
    jae .Lg4_names_next
    mov rdi, r15
    mov rsi, r14
    call g4_text_equal
    test eax, eax
    jz .Lg4_names_bad
    mov rdi, r15
    call g4_next
    mov r15, rax
    jmp .Lg4_names_duplicate
.Lg4_names_next:
    mov rdi, r14
    call g4_next
    mov r14, rax
    inc rbx
    cmp rbx, r13
    jb .Lg4_names_item
.Lg4_names_good:
    xor eax, eax
    jmp .Lg4_names_return
.Lg4_names_bad:
    mov eax, 1
.Lg4_names_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
/* RDI=profile orNULL,RSI=feature name. RAX=index0..63 or-1. Stack24. */
g4_feature_index:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
    test r12, r12
    jz .Lg4_feature_absent
.Lg4_feature_find:
    cmp rbx, [r12 + 16]
    jae .Lg4_feature_absent
    imul rax, rbx, 24
    mov rdx, [r12 + 8]
    mov rdi, [rdx + rax]
    test rdi, rdi
    jz .Lg4_feature_absent
    mov rsi, r13
    call g4_text_equal
    test eax, eax
    jz .Lg4_feature_found
    inc rbx
    jmp .Lg4_feature_find
.Lg4_feature_found:
    mov rax, rbx
    jmp .Lg4_feature_return
.Lg4_feature_absent:
    mov rax, -1
.Lg4_feature_return:
    pop r13
    pop r12
    pop rbx
    ret
/* RDI=validated profile,RSI=deps16,RDX=count<=64,RCX=member. RAX=0local,
 * 1optional activation,2child feature,-1invalid; RDX=index; RCX=borrowed child
 * feature for type2. Member<=137 bytes. Scratch138; stack56. No input writes.
 * Child feature existence belongs to candidate selection, not validation. */
g4_member:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r15, r15
    jz .Lg4_member_bad
    xor ebx, ebx
    lea rdx, [rip + g4_member_text]
.Lg4_member_copy:
    movzx eax, byte ptr [r15 + rbx]
    mov [rdx + rbx], al
    test eax, eax
    jz .Lg4_member_classify
    inc rbx
    cmp rbx, 137
    jbe .Lg4_member_copy
    jmp .Lg4_member_bad
.Lg4_member_classify:
    cmp dword ptr [rdx], 0x3a706564
    je .Lg4_member_optional
    xor ecx, ecx
    xor ebx, ebx
    xor r8d, r8d
.Lg4_member_slash:
    movzx eax, byte ptr [rdx + rbx]
    test eax, eax
    jz .Lg4_member_slashes
    cmp eax, '/'
    jne .Lg4_member_scan_next
    inc ecx
    mov r8, rbx
.Lg4_member_scan_next:
    inc rbx
    jmp .Lg4_member_slash
.Lg4_member_slashes:
    test ecx, ecx
    jz .Lg4_member_local
    cmp ecx, 2
    jne .Lg4_member_bad
    mov byte ptr [rdx + r8], 0
    lea rbx, [r15 + r8 + 1]
    mov rdi, rbx
    call g4_feature_name
    test eax, eax
    jz .Lg4_member_bad
    mov r15d, 2
    lea r12, [rip + g4_member_text]
    jmp .Lg4_member_dependency
.Lg4_member_optional:
    mov r15d, 1
    lea r12, [rdx + 4]
    xor ebx, ebx
.Lg4_member_dependency:
    xor r8d, r8d
.Lg4_member_dep_find:
    cmp r8, r14
    jae .Lg4_member_bad
    mov rdi, r12
    mov rsi, [r13]
    sub rsp, 16
    mov [rsp], r8
    call g4_text_equal
    mov r8, [rsp]
    add rsp, 16
    test eax, eax
    jz .Lg4_member_dep_found
    inc r8
    add r13, 16
    jmp .Lg4_member_dep_find
.Lg4_member_dep_found:
.Lg4_member_dep_result:
    mov eax, r15d
    mov rdx, r8
    mov rcx, rbx
    jmp .Lg4_member_return
.Lg4_member_local:
    mov rdi, r15
    call g4_feature_name
    test eax, eax
    jz .Lg4_member_bad
    mov rdi, r12
    mov rsi, r15
    call g4_feature_index
    test rax, rax
    js .Lg4_member_bad
    mov rdx, rax
    xor eax, eax
    jmp .Lg4_member_return
.Lg4_member_bad:
    mov rax, -1
.Lg4_member_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
/* RDI=profile orNULL,RSI=deps16,RDX=count<=64. EAX0valid1invalid.
 * Validates inactive declarations, flags, all lists, local references and
 * local cycles. NULL means mandatory dependencies/defaults/no local features.
 * DFS depth<=64; visited64/private member138; stack56 plus DFS frames40. */
g4_profile_validate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp r14, 64
    ja .Lg4_profile_bad
    test r12, r12
    jz .Lg4_profile_good
    cmp qword ptr [r12 + 16], 64
    ja .Lg4_profile_bad
    test r14, r14
    jz .Lg4_profile_definitions
    test r13, r13
    jz .Lg4_profile_bad
    cmp qword ptr [r12], 0
    je .Lg4_profile_bad
    xor ebx, ebx
.Lg4_profile_option:
    imul rax, rbx, 24
    mov r15, [r12]
    add r15, rax
    cmp qword ptr [r15], 3
    ja .Lg4_profile_bad
    mov rdi, [r15 + 8]
    mov rsi, [r15 + 16]
    call g4_names_validate
    test eax, eax
    jnz .Lg4_profile_bad
    inc rbx
    cmp rbx, r14
    jb .Lg4_profile_option
.Lg4_profile_definitions:
    cmp qword ptr [r12 + 16], 0
    je .Lg4_profile_good
    cmp qword ptr [r12 + 8], 0
    je .Lg4_profile_bad
    mov [rip + g4_validation_profile], r12
    mov [rip + g4_validation_deps], r13
    mov [rip + g4_validation_count], r14
    xor ebx, ebx
.Lg4_profile_definition:
    imul rax, rbx, 24
    mov r15, [r12 + 8]
    add r15, rax
    mov rdi, [r15]
    call g4_feature_name
    test eax, eax
    jz .Lg4_profile_bad
    mov rdi, r12
    mov rsi, [r15]
    call g4_feature_index
    cmp rax, rbx
    jne .Lg4_profile_bad
    cmp qword ptr [r15 + 16], 64
    ja .Lg4_profile_bad
    mov r13, [r15 + 8]
    mov r14, [r15 + 16]
    test r14, r14
    jz .Lg4_profile_definition_next
    test r13, r13
    jz .Lg4_profile_bad
.Lg4_profile_member:
    mov rdi, r12
    mov rsi, [rip + g4_validation_deps]
    mov rdx, [rip + g4_validation_count]
    mov rcx, r13
    call g4_member
    test rax, rax
    js .Lg4_profile_bad
    cmp eax, 1
    jne .Lg4_profile_member_unique
    imul rdx, rdx, 24
    mov rax, [r12]
    test qword ptr [rax + rdx], 1
    jz .Lg4_profile_bad
.Lg4_profile_member_unique:
    mov rdi, [r15 + 8]
.Lg4_profile_member_duplicate:
    cmp rdi, r13
    jae .Lg4_profile_member_next
    sub rsp, 16
    mov [rsp], rdi
    mov rsi, r13
    call g4_text_equal
    mov rdi, [rsp]
    add rsp, 16
    test eax, eax
    jz .Lg4_profile_bad
    call g4_next
    mov rdi, rax
    jmp .Lg4_profile_member_duplicate
.Lg4_profile_member_next:
    mov rdi, r13
    call g4_next
    mov r13, rax
    dec r14
    jnz .Lg4_profile_member
.Lg4_profile_definition_next:
    inc rbx
    cmp rbx, [r12 + 16]
    jb .Lg4_profile_definition
    lea rdi, [rip + g4_validation_seen]
    mov ecx, 64
    xor eax, eax
    rep stosb
    xor ebx, ebx
.Lg4_profile_cycle:
    mov rdi, rbx
    call g4_feature_visit
    test eax, eax
    jnz .Lg4_profile_bad
    inc rbx
    cmp rbx, [r12 + 16]
    jb .Lg4_profile_cycle
.Lg4_profile_good:
    xor eax, eax
    jmp .Lg4_profile_return
.Lg4_profile_bad:
    mov eax, 1
.Lg4_profile_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
/* RDI=local feature index<64, validated declarations in serial scratch.
 * EAX0acyclic1cycle. DFS colors prevent unbounded recursion. Stack40/depth. */
g4_feature_visit:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    lea rdx, [rip + g4_validation_seen]
    cmp byte ptr [rdx + rbx], 2
    je .Lg4_visit_good
    cmp byte ptr [rdx + rbx], 1
    je .Lg4_visit_bad
    mov byte ptr [rdx + rbx], 1
    mov r12, [rip + g4_validation_profile]
    imul rax, rbx, 24
    mov rdx, [r12 + 8]
    add rdx, rax
    mov r13, [rdx + 8]
    mov r14, [rdx + 16]
.Lg4_visit_member:
    test r14, r14
    jz .Lg4_visit_done
    mov rdi, r12
    mov rsi, [rip + g4_validation_deps]
    mov rdx, [rip + g4_validation_count]
    mov rcx, r13
    call g4_member
    test eax, eax
    jnz .Lg4_visit_next
    mov rdi, rdx
    call g4_feature_visit
    test eax, eax
    jnz .Lg4_visit_bad
.Lg4_visit_next:
    mov rdi, r13
    call g4_next
    mov r13, rax
    dec r14
    jmp .Lg4_visit_member
.Lg4_visit_done:
    lea rdx, [rip + g4_validation_seen]
    mov byte ptr [rdx + rbx], 2
.Lg4_visit_good:
    xor eax, eax
    jmp .Lg4_visit_return
.Lg4_visit_bad:
    mov eax, 1
.Lg4_visit_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
/* RDI/RSI=validated profiles orNULL,RDX=depcount. EAX0same1different.
 * Compare semantic fields and canonical list order, never pointer values or
 * unused bytes. NULL equals explicit mandatory/default/no-feature profile.
 * Stack56; caller retains readable arrays. */
g4_profile_equal:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r12, r12
    jnz .Lg4_equal_right
    lea r12, [rip + g4_legacy_profile]
.Lg4_equal_right:
    test r13, r13
    jnz .Lg4_equal_options
    lea r13, [rip + g4_legacy_profile]
.Lg4_equal_options:
    xor ebx, ebx
.Lg4_equal_option:
    cmp rbx, r14
    jae .Lg4_equal_features
    imul rax, rbx, 24
    mov rdi, [r12]
    mov rsi, [r13]
    add rdi, rax
    add rsi, rax
    mov rax, [rdi]
    cmp rax, [rsi]
    jne .Lg4_equal_bad
    call g4_record_list_equal
    test eax, eax
    jnz .Lg4_equal_bad
    inc rbx
    jmp .Lg4_equal_option
.Lg4_equal_features:
    mov rax, [r12 + 16]
    cmp rax, [r13 + 16]
    jne .Lg4_equal_bad
    mov r14, rax
    xor ebx, ebx
.Lg4_equal_definition:
    cmp rbx, r14
    jae .Lg4_equal_good
    imul rax, rbx, 24
    mov rdi, [r12 + 8]
    mov rsi, [r13 + 8]
    add rdi, rax
    add rsi, rax
    push rdi
    push rsi
    mov rdi, [rdi]
    mov rsi, [rsi]
    call g4_text_equal
    pop rsi
    pop rdi
    test eax, eax
    jnz .Lg4_equal_bad
    call g4_record_list_equal
    test eax, eax
    jnz .Lg4_equal_bad
    inc rbx
    jmp .Lg4_equal_definition
.Lg4_equal_good:
    xor eax, eax
    jmp .Lg4_equal_return
.Lg4_equal_bad:
    mov eax, 1
.Lg4_equal_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
/* RDI/RSI=records24 with list ptr@8,count@16. EAX0same1different. Stack24. */
g4_record_list_equal:
    push rbx
    push r12
    push r13
    mov rbx, [rdi + 16]
    cmp rbx, [rsi + 16]
    jne .Lg4_list_equal_bad
    mov r12, [rdi + 8]
    mov r13, [rsi + 8]
.Lg4_list_equal_item:
    test rbx, rbx
    jz .Lg4_list_equal_good
    mov rdi, r12
    mov rsi, r13
    call g4_text_equal
    test eax, eax
    jnz .Lg4_list_equal_bad
    mov rdi, r12
    call g4_next
    mov r12, rax
    mov rdi, r13
    call g4_next
    mov r13, rax
    dec rbx
    jmp .Lg4_list_equal_item
.Lg4_list_equal_good:
    xor eax, eax
    jmp .Lg4_list_equal_return
.Lg4_list_equal_bad:
    mov eax, 1
.Lg4_list_equal_return:
    pop r13
    pop r12
    pop rbx
    ret
.section .data
.balign 8
g4_legacy_profile: .quad g4_legacy_options,0,0
g4_legacy_options:
.rept 64
    .quad 2,0,0
.endr
.section .bss
.balign 8
g4_validation_profile: .skip 8
g4_validation_deps: .skip 8
g4_validation_count: .skip 8
g4_validation_seen: .skip 64
g4_member_text: .skip 138
