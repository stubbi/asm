/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Strict dependency metadata and numeric version ranges. All runtime logic is
 * native assembly. See LICENSING.md for the platform license scope.
 */
.intel_syntax noprefix
.equ RM_LINK, 73792
.equ RM_LIBRARIES, 73800
.equ RM_CHECK, 73808
.equ RM_SIZE, 73816
.equ RM_DEPS, 64
.equ RM_FEATURES, 36928
.equ RM_STRIDE, 576
.equ RM_VERSION_LIMIT, 63
.global rm_parse_manifest, rm_range_matches, rm_valid_range
.section .text
/* RDI=mutable NUL manifest <=16384 bytes; RSI=owned RM_SIZE-byte result.
 * RAX=0 success,1 invalid. Strings borrow the input; caller retains its bytes.
 * Extension manifests are <=8190 bytes. Header: extension,deps,features at
 * 0,8,16; name/version/source/target pointers at24,32,40,48. Dependency records
 * at64: name,range,optional,defaults,count,pointers[64]. Feature records at36928:
 * name,count,pointers[64]; +528/+536 are private traversal state. Stride576.
 * Optional native-link pointers follow at RM_LINK/RM_LIBRARIES/RM_CHECK.
 * Absent optional values borrow rm_empty. Field capacities include NUL:256.
 * Preserves RBX/RBP/R12-R15. Main frame saves56 bytes; array helpers save40.
 * Feature DFS saves24 bytes per level, at most64 levels. Calls add return
 * addresses and nested helper frames. No file or process effects.
 */
rm_parse_manifest:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov [rip + rm_input], rdi
    mov [rip + rm_output], rsi
    xor ecx, ecx
    mov edx, 1
.Lrm_preflight:
    movzx eax, byte ptr [r12 + rcx]
    test al, al
    jz .Lrm_preflight_done
    cmp ecx, 16384
    jae .Lrm_bad
    cmp al, 127
    jae .Lrm_not_ascii
    cmp al, 32
    jae .Lrm_preflight_next
    cmp al, 9
    je .Lrm_preflight_next
    cmp al, 10
    je .Lrm_preflight_next
    cmp al, 13
    jne .Lrm_not_ascii
    cmp byte ptr [r12 + rcx + 1], 10
    je .Lrm_preflight_next
.Lrm_not_ascii:
    xor edx, edx
.Lrm_preflight_next:
    inc ecx
    jmp .Lrm_preflight
.Lrm_preflight_done:
    mov [rip + rm_ascii], rdx
    mov [rip + rm_input_length], rcx
    xor eax, eax
    mov rdi, rsi
    mov ecx, RM_SIZE/8
    rep stosq
    lea rax, [rip + rm_empty]
    mov [r13 + RM_LINK], rax
    mov [r13 + RM_LIBRARIES], rax
    mov [r13 + RM_CHECK], rax
    xor r14d, r14d /* section */
    xor r15d, r15d /* section mask */
    xor ebx, ebx /* scalar mask */
.Lrm_line:
    call rm_horizontal
    mov al, [r12]
    test al, al
    jz .Lrm_finish
    cmp al, 10
    je .Lrm_next
    cmp al, '#'
    je .Lrm_comment
    cmp al, '['
    je .Lrm_section
    cmp r14d, 4
    je .Lrm_dependency
    cmp r14d, 5
    je .Lrm_feature
    call rm_key_identifier
    test eax, eax
    jz .Lrm_bad
    mov edi, '='
    call rm_expect
    test eax, eax
    jz .Lrm_bad
    call rm_string
    test rax, rax
    jz .Lrm_bad
    mov rbp, rax
    cmp r14d, 3
    je .Lrm_schema
    cmp r14d, 1
    je .Lrm_package
    cmp r14d, 2
    jne .Lrm_bad
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_source]
    call streq
    test eax, eax
    jnz .Lrm_source
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_target]
    call streq
    test eax, eax
    jnz .Lrm_target
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_link]
    call streq
    test eax, eax
    jnz .Lrm_link
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_libraries]
    call streq
    test eax, eax
    jnz .Lrm_libraries
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_check]
    call streq
    test eax, eax
    jnz .Lrm_check
    jmp .Lrm_bad
.Lrm_link:
    cmp byte ptr [rbp], 0
    je .Lrm_bad
    mov edx, 32
    mov ecx, RM_LINK
    jmp .Lrm_scalar
.Lrm_libraries:
    cmp byte ptr [rbp], 0
    je .Lrm_bad
    mov edx, 64
    mov ecx, RM_LIBRARIES
    jmp .Lrm_scalar
.Lrm_check:
    cmp byte ptr [rbp], 0
    je .Lrm_bad
    mov edx, 128
    mov ecx, RM_CHECK
    jmp .Lrm_scalar
.Lrm_target:
    mov edx, 8
    mov ecx, 48
    jmp .Lrm_scalar
.Lrm_source:
    mov edx, 4
    mov ecx, 40
    jmp .Lrm_scalar
.Lrm_package:
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_name]
    call streq
    test eax, eax
    jnz .Lrm_name
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_version]
    call streq
    test eax, eax
    jz .Lrm_bad
    mov edx, 2
    mov ecx, 32
    jmp .Lrm_scalar
.Lrm_name:
    mov edx, 1
    mov ecx, 24
.Lrm_scalar:
    test ebx, edx
    jnz .Lrm_bad
    or ebx, edx
    mov [r13 + rcx], rbp
    jmp .Lrm_line_end
.Lrm_schema:
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_schema]
    call streq
    test eax, eax
    jz .Lrm_bad
    cmp word ptr [rbp], 0x31
    jne .Lrm_bad
    test ebx, 16
    jnz .Lrm_bad
    or ebx, 16
    mov qword ptr [r13], 1
    jmp .Lrm_line_end
.Lrm_section:
    inc r12
    cmp byte ptr [r12], 'a'
    jb .Lrm_bad
    cmp byte ptr [r12], 'z'
    ja .Lrm_bad
    call rm_key_identifier
    test eax, eax
    jz .Lrm_bad
    cmp byte ptr [r12], ']'
    jne .Lrm_bad
    inc r12
    lea rbp, [rip + rm_sections]
    mov r14d, 1
.Lrm_section_find:
    mov rsi, [rbp]
    test rsi, rsi
    jz .Lrm_bad
    lea rdi, [rip + rm_key]
    call streq
    test eax, eax
    jnz .Lrm_section_found
    inc r14d
    add rbp, 8
    jmp .Lrm_section_find
.Lrm_section_found:
    mov ecx, r14d
    dec ecx
    mov eax, 1
    shl eax, cl
    test r15d, eax
    jnz .Lrm_bad
    or r15d, eax
    jmp .Lrm_line_end
.Lrm_dependency:
    call rm_string
    test rax, rax
    jz .Lrm_bad
    mov rbp, rax
    mov rdi, rax
    call registry_valid_package
    test eax, eax
    jz .Lrm_bad
    mov rdi, rbp
    call rm_find_dep
    test rax, rax
    jnz .Lrm_bad
    mov rax, [r13 + 8]
    cmp rax, 64
    jae .Lrm_bad
    imul rax, RM_STRIDE
    lea rbp, [r13 + rax + RM_DEPS]
    mov [rbp], rdi
    mov qword ptr [rbp + 24], 1
    inc qword ptr [r13 + 8]
    mov edi, '='
    call rm_expect
    test eax, eax
    jz .Lrm_bad
    call rm_horizontal
    cmp byte ptr [r12], '{'
    je .Lrm_inline
    call rm_string
    test rax, rax
    jz .Lrm_bad
    mov [rbp + 8], rax
    mov rdi, rax
    call rm_valid_range
    test eax, eax
    jz .Lrm_bad
    jmp .Lrm_line_end
.Lrm_inline:
    inc r12
    mov qword ptr [rip + rm_table_fields], 0
.Lrm_inline_field:
    call rm_key_identifier
    test eax, eax
    jz .Lrm_bad
    mov edi, '='
    call rm_expect
    test eax, eax
    jz .Lrm_bad
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_version]
    call streq
    test eax, eax
    jnz .Lrm_inline_version
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_optional]
    call streq
    test eax, eax
    jnz .Lrm_inline_optional
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_defaults]
    call streq
    test eax, eax
    jnz .Lrm_inline_defaults
    lea rdi, [rip + rm_key]
    lea rsi, [rip + rm_features]
    call streq
    test eax, eax
    jz .Lrm_bad
    test qword ptr [rip + rm_table_fields], 8
    jnz .Lrm_bad
    or qword ptr [rip + rm_table_fields], 8
    lea rdi, [rbp + 40]
    call rm_array
    cmp rax, -1
    je .Lrm_bad
    mov [rbp + 32], rax
    xor edx, edx
.Lrm_dep_feature_name:
    cmp rdx, [rbp + 32]
    jae .Lrm_inline_end
    mov rdi, [rbp + rdx*8 + 40]
    push rdx
    call rm_valid_feature
    pop rdx
    test eax, eax
    jz .Lrm_bad
    inc edx
    jmp .Lrm_dep_feature_name
.Lrm_inline_version:
    test qword ptr [rip + rm_table_fields], 1
    jnz .Lrm_bad
    or qword ptr [rip + rm_table_fields], 1
    call rm_string
    test rax, rax
    jz .Lrm_bad
    mov [rbp + 8], rax
    mov rdi, rax
    call rm_valid_range
    test eax, eax
    jz .Lrm_bad
    jmp .Lrm_inline_end
.Lrm_inline_optional:
    mov edx, 2
    mov ecx, 16
    jmp .Lrm_inline_bool
.Lrm_inline_defaults:
    mov edx, 4
    mov ecx, 24
.Lrm_inline_bool:
    test [rip + rm_table_fields], rdx
    jnz .Lrm_bad
    or [rip + rm_table_fields], rdx
    push rcx
    call rm_bool
    pop rcx
    cmp rax, -1
    je .Lrm_bad
    mov [rbp + rcx], rax
.Lrm_inline_end:
    call rm_horizontal
    mov al, [r12]
    inc r12
    cmp al, '}'
    je .Lrm_inline_done
    cmp al, ','
    jne .Lrm_bad
    call rm_horizontal
    cmp byte ptr [r12], '}'
    je .Lrm_bad
    jmp .Lrm_inline_field
.Lrm_inline_done:
    test qword ptr [rip + rm_table_fields], 1
    jz .Lrm_bad
    jmp .Lrm_line_end
.Lrm_feature:
    cmp qword ptr [r13 + 16], 64
    jae .Lrm_bad
    call rm_horizontal
    mov qword ptr [rip + rm_feature_equal], 0
    cmp byte ptr [r12], '"'
    je .Lrm_feature_quoted
    mov rbp, r12
    call rm_key_identifier
    test eax, eax
    jz .Lrm_bad
    mov al, [r12]
    cmp al, ' '
    je .Lrm_feature_bare_end
    cmp al, 9
    je .Lrm_feature_bare_end
    cmp al, '='
    jne .Lrm_bad
    mov qword ptr [rip + rm_feature_equal], 1
.Lrm_feature_bare_end:
    mov byte ptr [r12], 0
    inc r12
    mov rax, rbp
    jmp .Lrm_feature_key
.Lrm_feature_quoted:
    call rm_string
    test rax, rax
    jz .Lrm_bad
.Lrm_feature_key:
    mov rbp, rax
    mov rdi, rax
    call rm_valid_feature
    test eax, eax
    jz .Lrm_bad
    mov rdi, rbp
    call rm_find_feature
    test rax, rax
    jnz .Lrm_bad
    mov rax, [r13 + 16]
    imul rax, RM_STRIDE
    lea rax, [r13 + rax + RM_FEATURES]
    mov [rax], rbp
    mov rbp, rax
    inc qword ptr [r13 + 16]
    cmp qword ptr [rip + rm_feature_equal], 1
    je .Lrm_feature_array
    mov edi, '='
    call rm_expect
    test eax, eax
    jz .Lrm_bad
.Lrm_feature_array:
    lea rdi, [rbp + 16]
    call rm_array
    cmp rax, -1
    je .Lrm_bad
    mov [rbp + 8], rax
.Lrm_line_end:
    call rm_horizontal
    mov al, [r12]
    test al, al
    jz .Lrm_finish
    cmp al, '#'
    je .Lrm_comment
    cmp al, 10
    jne .Lrm_bad
.Lrm_next:
    inc r12
    jmp .Lrm_line
.Lrm_comment:
    mov al, [r12]
    test al, al
    jz .Lrm_finish
    cmp al, 10
    je .Lrm_next
    inc r12
    jmp .Lrm_comment
.Lrm_finish:
    mov eax, ebx
    and eax, 15
    cmp eax, 15
    jne .Lrm_bad
    mov rax, [rip + rm_input_length]
    cmp rax, 16384
    ja .Lrm_bad
    test r15d, 28
    jz .Lrm_scalars_valid
    test ebx, 16
    jz .Lrm_bad
    cmp rax, 8190
    ja .Lrm_bad
    cmp qword ptr [rip + rm_ascii], 1
    jne .Lrm_bad
.Lrm_scalars_valid:
    mov rdi, [r13 + 24]
    call valid_name
    test eax, eax
    jz .Lrm_bad
    mov rdi, [r13 + 32]
    call strlen
    cmp rax, RM_VERSION_LIMIT
    ja .Lrm_bad
    mov rdi, [r13 + 32]
    cmp qword ptr [r13], 0
    jne .Lrm_strict_version
    call valid_version
    jmp .Lrm_version_checked
.Lrm_strict_version:
    call registry_valid_version
.Lrm_version_checked:
    test eax, eax
    jz .Lrm_bad
    mov rdi, [r13 + 40]
    call valid_source
    test eax, eax
    jz .Lrm_bad
    mov rdi, [r13 + 48]
    call registry_valid_target
    test eax, eax
    jz .Lrm_bad
    mov rdi, [r13 + RM_LINK]
    mov rsi, [r13 + RM_LIBRARIES]
    mov rdx, [r13 + RM_CHECK]
    call native_link_validate
    test eax, eax
    jz .Lrm_bad
    xor ebp, ebp
.Lrm_feature_check:
    cmp rbp, [r13 + 16]
    jae .Lrm_good
    imul rax, rbp, RM_STRIDE
    lea rdi, [r13 + rax + RM_FEATURES]
    call rm_feature_visit
    test eax, eax
    jz .Lrm_bad
    inc ebp
    jmp .Lrm_feature_check
.Lrm_good:
    xor eax, eax
    jmp .Lrm_return
.Lrm_bad:
    mov eax, 1
.Lrm_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Parser helpers deliberately advance R12. Other callee registers preserved.
 * Input is a bounded copied NUL buffer. No helper crosses a string terminator. */
rm_horizontal:
    mov al, [r12]
    cmp al, ' '
    je .Lrm_hnext
    cmp al, 9
    je .Lrm_hnext
    cmp al, 13
    jne .Lrm_hdone
.Lrm_hnext:
    inc r12
    jmp rm_horizontal
.Lrm_hdone:
    ret
rm_expect:
    mov edx, edi
    call rm_horizontal
    xor eax, eax
    cmp [r12], dl
    jne .Lrm_expect_done
    inc r12
    mov eax, 1
.Lrm_expect_done:
    ret
rm_key_identifier:
    call rm_horizontal
    xor ecx, ecx
    lea rdi, [rip + rm_key]
.Lrm_key_char:
    mov al, [r12]
    cmp al, 'a'
    jb .Lrm_key_extra
    cmp al, 'z'
    jbe .Lrm_key_copy
.Lrm_key_extra:
    test ecx, ecx
    jz .Lrm_key_end
    cmp al, '0'
    jb .Lrm_key_punct
    cmp al, '9'
    jbe .Lrm_key_copy
.Lrm_key_punct:
    cmp al, '-'
    je .Lrm_key_copy
    cmp al, '_'
    jne .Lrm_key_end
.Lrm_key_copy:
    cmp ecx, 32
    jae .Lrm_key_bad
    mov [rdi + rcx], al
    inc ecx
    inc r12
    jmp .Lrm_key_char
.Lrm_key_end:
    mov byte ptr [rdi + rcx], 0
    xor eax, eax
    test ecx, ecx
    setnz al
    ret
.Lrm_key_bad:
    xor eax, eax
    ret
rm_string:
    call rm_horizontal
    cmp byte ptr [r12], '"'
    jne .Lrm_string_bad
    inc r12
    mov rdi, r12
    xor ecx, ecx
.Lrm_string_char:
    mov al, [r12]
    cmp al, '"'
    je .Lrm_string_end
    cmp al, 32
    jb .Lrm_string_bad
    cmp al, 126
    ja .Lrm_string_bad
    cmp al, '\\'
    je .Lrm_string_bad
    cmp ecx, 255
    jae .Lrm_string_bad
    inc ecx
    inc r12
    jmp .Lrm_string_char
.Lrm_string_end:
    mov byte ptr [r12], 0
    inc r12
    mov rax, rdi
    ret
.Lrm_string_bad:
    xor eax, eax
    ret
rm_bool:
    call rm_horizontal
    lea rsi, [rip + rm_true]
    mov edx, 1
    cmp byte ptr [r12], 't'
    je .Lrm_bool_scan
    lea rsi, [rip + rm_false]
    xor edx, edx
.Lrm_bool_scan:
    xor ecx, ecx
.Lrm_bool_char:
    mov al, [rsi + rcx]
    test al, al
    jz .Lrm_bool_end
    cmp al, [r12 + rcx]
    jne .Lrm_bool_bad
    inc ecx
    jmp .Lrm_bool_char
.Lrm_bool_end:
    add r12, rcx
    mov eax, edx
    ret
.Lrm_bool_bad:
    mov rax, -1
    ret
/* RDI=array[64] result. RAX=count or-1. Reject duplicate strings. */
rm_array:
    push rbx
    push rbp
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    xor ebp, ebp
    mov edi, '['
    call rm_expect
    test eax, eax
    jz .Lrm_array_bad
    call rm_horizontal
    cmp byte ptr [r12], ']'
    je .Lrm_array_empty
.Lrm_array_item:
    cmp ebp, 64
    jae .Lrm_array_bad
    call rm_string
    test rax, rax
    jz .Lrm_array_bad
    mov r13, rax
    cmp byte ptr [r13], 0
    je .Lrm_array_bad
    xor r14d, r14d
.Lrm_array_duplicate:
    cmp r14d, ebp
    jae .Lrm_array_store
    mov rdi, r13
    mov rsi, [rbx + r14*8]
    call streq
    test eax, eax
    jnz .Lrm_array_bad
    inc r14d
    jmp .Lrm_array_duplicate
.Lrm_array_store:
    mov [rbx + rbp*8], r13
    inc ebp
    call rm_horizontal
    mov al, [r12]
    inc r12
    cmp al, ']'
    je .Lrm_array_done
    cmp al, ','
    jne .Lrm_array_bad
    call rm_horizontal
    cmp byte ptr [r12], ']'
    je .Lrm_array_empty /* TOML permits one trailing array comma. */
    jmp .Lrm_array_item
.Lrm_array_empty:
    inc r12
.Lrm_array_done:
    mov eax, ebp
    jmp .Lrm_array_return
.Lrm_array_bad:
    mov rax, -1
.Lrm_array_return:
    add rsp, 8
    pop r14
    pop r13
    pop rbp
    pop rbx
    ret
/* RDI=feature identifier. RAX=1/0. Max32 ASCII bytes. */
rm_valid_feature:
    xor ecx, ecx
.Lrm_feature_char:
    mov al, [rdi + rcx]
    test al, al
    jz .Lrm_feature_end
    cmp ecx, 32
    jae .Lrm_feature_invalid
    cmp al, 'a'
    jb .Lrm_feature_extra
    cmp al, 'z'
    jbe .Lrm_feature_next
.Lrm_feature_extra:
    test ecx, ecx
    jz .Lrm_feature_invalid
    cmp al, '0'
    jb .Lrm_feature_punct
    cmp al, '9'
    jbe .Lrm_feature_next
.Lrm_feature_punct:
    cmp al, '_'
    je .Lrm_feature_next
    cmp al, '-'
    jne .Lrm_feature_invalid
.Lrm_feature_next:
    inc ecx
    jmp .Lrm_feature_char
.Lrm_feature_end:
    xor eax, eax
    test ecx, ecx
    setnz al
    ret
.Lrm_feature_invalid:
    xor eax, eax
    ret
/* RDI=name; global rm_output is current owned result. RAX=record or0.
 * RDI remains the input on return. Other argument registers are scratch. */
rm_find_dep:
    mov rsi, [rip + rm_output]
    mov rdx, [rsi + 8]
    add rsi, RM_DEPS
    jmp rm_find_record
rm_find_feature:
    mov rsi, [rip + rm_output]
    mov rdx, [rsi + 16]
    add rsi, RM_FEATURES
rm_find_record:
    push rbx
    push rbp
    push r13
    mov rbx, rdi
    mov rbp, rsi
    mov r13, rdx
.Lrm_find_loop:
    test r13, r13
    jz .Lrm_find_absent
    mov rdi, rbx
    mov rsi, [rbp]
    call streq
    test eax, eax
    jnz .Lrm_find_found
    add rbp, RM_STRIDE
    dec r13
    jmp .Lrm_find_loop
.Lrm_find_absent:
    xor eax, eax
    jmp .Lrm_find_return
.Lrm_find_found:
    mov rax, rbp
.Lrm_find_return:
    mov rdi, rbx
    pop r13
    pop rbp
    pop rbx
    ret
/* RDI=feature record. RAX=1 valid,0 invalid/reference cycle. DFS depth<=64.
 * Local reference scratch is not retained across recursive calls. */
rm_feature_visit:
    push rbx
    push rbp
    push r13
    mov rbx, rdi
    cmp qword ptr [rbx + 536], 2
    je .Lrm_visit_good
    cmp qword ptr [rbx + 536], 1
    je .Lrm_visit_bad
    mov qword ptr [rbx + 536], 1
    xor ebp, ebp
.Lrm_visit_item:
    cmp rbp, [rbx + 8]
    jae .Lrm_visit_complete
    mov r13, [rbx + rbp*8 + 16]
    lea rdi, [rip + rm_reference]
    mov rsi, r13
    call copy_string
    lea r13, [rip + rm_reference]
    cmp dword ptr [r13], 0x3a706564 /* dep: */
    je .Lrm_visit_optional
    mov rdi, r13
    xor ecx, ecx
    xor edx, edx
.Lrm_visit_slash:
    mov al, [rdi]
    test al, al
    jz .Lrm_visit_classify
    cmp al, '/'
    jne .Lrm_visit_slash_next
    mov rdx, rdi
    inc ecx
.Lrm_visit_slash_next:
    inc rdi
    jmp .Lrm_visit_slash
.Lrm_visit_classify:
    test ecx, ecx
    jz .Lrm_visit_own
    cmp ecx, 2
    jne .Lrm_visit_bad
    mov byte ptr [rdx], 0
    lea rdi, [rdx + 1]
    call rm_valid_feature
    test eax, eax
    jz .Lrm_visit_bad
    mov rdi, r13
    call rm_find_dep
    test rax, rax
    jz .Lrm_visit_bad
    jmp .Lrm_visit_next
.Lrm_visit_optional:
    lea rdi, [r13 + 4]
    call rm_find_dep
    test rax, rax
    jz .Lrm_visit_bad
    cmp qword ptr [rax + 16], 1
    jne .Lrm_visit_bad
    jmp .Lrm_visit_next
.Lrm_visit_own:
    mov rdi, r13
    call rm_valid_feature
    test eax, eax
    jz .Lrm_visit_bad
    mov rdi, r13
    call rm_find_feature
    test rax, rax
    jz .Lrm_visit_bad
    mov rdi, rax
    call rm_feature_visit
    test eax, eax
    jz .Lrm_visit_bad
.Lrm_visit_next:
    inc ebp
    jmp .Lrm_visit_item
.Lrm_visit_complete:
    mov qword ptr [rbx + 536], 2
.Lrm_visit_good:
    mov eax, 1
    jmp .Lrm_visit_return
.Lrm_visit_bad:
    xor eax, eax
.Lrm_visit_return:
    pop r13
    pop rbp
    pop rbx
    ret

.section .rodata
rm_sections: .quad rm_package,rm_build,rm_resolution,rm_dependencies,rm_features,0
rm_package: .asciz "package"
rm_build: .asciz "build"
rm_resolution: .asciz "resolution"
rm_dependencies: .asciz "dependencies"
rm_features: .asciz "features"
rm_link: .asciz "link"
rm_libraries: .asciz "libraries"
rm_check: .asciz "check"
rm_empty: .asciz ""
rm_name: .asciz "name"
rm_version: .asciz "version"
rm_source: .asciz "source"
rm_target: .asciz "target"
rm_schema: .asciz "schema"
rm_optional: .asciz "optional"
rm_defaults: .asciz "default-features"
rm_true: .asciz "true"
rm_false: .asciz "false"
.section .bss
.balign 8
rm_input: .skip 8
rm_input_length: .skip 8
rm_ascii: .skip 8
rm_output: .skip 8
rm_table_fields: .skip 8
rm_feature_equal: .skip 8
rm_key: .skip 40
rm_reference: .skip 256
.section .note.GNU-stack,"",@progbits

.section .text
/* RDI=range, RAX=1 valid/0 invalid. No mutation of range bytes. */
rm_valid_range:
    mov rsi, rdi
    xor edi, edi
    call rm_range_matches
    cmp rax, -1
    setne al
    movzx eax, al
    ret
/* RDI=validated numeric version or0 for syntax only; RSI=range. RAX=1 match,
 * 0 mismatch,-1 invalid. Supports exact,*,^,~, and <=8 explicit comparisons.
 * Max128 printable bytes, no outer whitespace or implicit partial versions.
 * Callee registers preserved; 56 local stack bytes. Owns128-byte token and
 * three numeric triplets; no file operations, recursive calls or input writes.
 */
rm_range_matches:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r14, rdi
    mov r12, rsi
    mov r13d, 1
    xor r15d, r15d
    mov rdi, r12
    call strlen
    test rax, rax
    jz .Lrq_bad
    cmp rax, 128
    ja .Lrq_bad
    cmp byte ptr [r12], ' '
    je .Lrq_bad
    cmp byte ptr [r12 + rax - 1], ' '
    je .Lrq_bad
    xor ecx, ecx
.Lrq_ascii:
    cmp rcx, rax
    jae .Lrq_start
    cmp byte ptr [r12 + rcx], 32
    jb .Lrq_bad
    cmp byte ptr [r12 + rcx], 126
    ja .Lrq_bad
    inc ecx
    jmp .Lrq_ascii
.Lrq_start:
    test r14, r14
    jz .Lrq_term
    mov rdi, r14
    call registry_valid_version
    test eax, eax
    jz .Lrq_bad
    mov rdi, r14
    lea rsi, [rip + rm_range_actual]
    call rm_range_numbers
.Lrq_term:
    inc r15d
    cmp r15d, 8
    ja .Lrq_bad
    xor ebp, ebp /*0 exact,1>=,2>,3<=,4<,5^,6~,7= */
    mov al, [r12]
    cmp al, '*'
    je .Lrq_wildcard
    cmp al, '^'
    je .Lrq_caret
    cmp al, '~'
    je .Lrq_tilde
    cmp al, '>'
    je .Lrq_gt
    cmp al, '<'
    je .Lrq_lt
    cmp al, '='
    je .Lrq_eq
    jmp .Lrq_version
.Lrq_caret:
    mov ebp, 5
    inc r12
    jmp .Lrq_version
.Lrq_tilde:
    mov ebp, 6
    inc r12
    jmp .Lrq_version
.Lrq_gt:
    mov ebp, 2
    inc r12
    cmp byte ptr [r12], '='
    jne .Lrq_spaces
    dec ebp
    inc r12
    jmp .Lrq_spaces
.Lrq_lt:
    mov ebp, 4
    inc r12
    cmp byte ptr [r12], '='
    jne .Lrq_spaces
    dec ebp
    inc r12
    jmp .Lrq_spaces
.Lrq_eq:
    mov ebp, 7
    inc r12
.Lrq_spaces:
    cmp byte ptr [r12], ' '
    jne .Lrq_version
    inc r12
    jmp .Lrq_spaces
.Lrq_version:
    lea rbx, [rip + rm_range_token]
    xor ecx, ecx
.Lrq_version_char:
    mov al, [r12]
    test al, al
    jz .Lrq_version_end
    cmp al, ','
    je .Lrq_version_end
    cmp al, ' '
    je .Lrq_version_end
    cmp ecx, 32
    jae .Lrq_bad
    mov [rbx + rcx], al
    inc ecx
    inc r12
    jmp .Lrq_version_char
.Lrq_version_end:
    mov byte ptr [rbx + rcx], 0
    mov rdi, rbx
    call registry_valid_version
    test eax, eax
    jz .Lrq_bad
    test r14, r14
    jz .Lrq_next
    mov rdi, rbx
    lea rsi, [rip + rm_range_term]
    call rm_range_numbers
    lea rdi, [rip + rm_range_actual]
    lea rsi, [rip + rm_range_term]
    call rm_range_compare
    cmp ebp, 0
    je .Lrq_exact
    cmp ebp, 7
    je .Lrq_exact
    cmp ebp, 1
    je .Lrq_ge
    cmp ebp, 2
    je .Lrq_greater
    cmp ebp, 3
    je .Lrq_le
    cmp ebp, 4
    je .Lrq_less
    cmp eax, 0
    jl .Lrq_mismatch
    lea rsi, [rip + rm_range_term]
    mov rax, [rsi]
    mov rcx, [rsi + 8]
    mov rdx, [rsi + 16]
    cmp ebp, 6
    je .Lrq_upper_minor
    test rax, rax
    jz .Lrq_upper_zero
    inc rax
    xor ecx, ecx
    xor edx, edx
    jmp .Lrq_upper
.Lrq_upper_zero:
    test rcx, rcx
    jnz .Lrq_upper_minor
    inc rdx
    jmp .Lrq_upper
.Lrq_upper_minor:
    inc rcx
    xor edx, edx
.Lrq_upper:
    lea rsi, [rip + rm_range_upper]
    mov [rsi], rax
    mov [rsi + 8], rcx
    mov [rsi + 16], rdx
    lea rdi, [rip + rm_range_actual]
    call rm_range_compare
    test eax, eax
    jge .Lrq_mismatch
    jmp .Lrq_next
.Lrq_exact:
    test eax, eax
    jnz .Lrq_mismatch
    jmp .Lrq_next
.Lrq_ge:
    test eax, eax
    jl .Lrq_mismatch
    jmp .Lrq_next
.Lrq_greater:
    test eax, eax
    jle .Lrq_mismatch
    jmp .Lrq_next
.Lrq_le:
    test eax, eax
    jg .Lrq_mismatch
    jmp .Lrq_next
.Lrq_less:
    test eax, eax
    jge .Lrq_mismatch
    jmp .Lrq_next
.Lrq_mismatch:
    xor r13d, r13d
.Lrq_next:
    cmp byte ptr [r12], ' '
    jne .Lrq_separator
    inc r12
    jmp .Lrq_next
.Lrq_separator:
    cmp byte ptr [r12], 0
    je .Lrq_done
    cmp byte ptr [r12], ','
    jne .Lrq_bad
    cmp ebp, 0
    je .Lrq_bad
    cmp ebp, 5
    je .Lrq_bad
    cmp ebp, 6
    je .Lrq_bad
    inc r12
.Lrq_after_comma:
    cmp byte ptr [r12], ' '
    jne .Lrq_require_comparator
    inc r12
    jmp .Lrq_after_comma
.Lrq_require_comparator:
    mov al, [r12]
    cmp al, '='
    je .Lrq_term
    cmp al, '<'
    je .Lrq_term
    cmp al, '>'
    je .Lrq_term
    jmp .Lrq_bad
.Lrq_wildcard:
    cmp r15d, 1
    jne .Lrq_bad
    cmp byte ptr [r12 + 1], 0
    jne .Lrq_bad
.Lrq_done:
    mov eax, r13d
    jmp .Lrq_return
.Lrq_bad:
    mov rax, -1
.Lrq_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
/* RDI=validated version,RSI=three owned qwords. Scratch:RAX,RCX,RDX,R8. */
rm_range_numbers:
    xor ecx, ecx
.Lrq_number_component:
    xor eax, eax
.Lrq_number_digit:
    movzx edx, byte ptr [rdi]
    cmp dl, '0'
    jb .Lrq_number_store
    cmp dl, '9'
    ja .Lrq_number_store
    sub edx, '0'
    imul rax, rax, 10
    add rax, rdx
    inc rdi
    jmp .Lrq_number_digit
.Lrq_number_store:
    mov [rsi + rcx*8], rax
    inc ecx
    cmp ecx, 3
    je .Lrq_number_done
    inc rdi
    jmp .Lrq_number_component
.Lrq_number_done:
    ret
/* RDI/RSI=three unsigned qwords. RAX=-1,0,1 lexical numeric order. */
rm_range_compare:
    xor ecx, ecx
.Lrq_compare:
    mov rax, [rdi + rcx*8]
    cmp rax, [rsi + rcx*8]
    jb .Lrq_cmp_less
    ja .Lrq_cmp_greater
    inc ecx
    cmp ecx, 3
    jb .Lrq_compare
    xor eax, eax
    ret
.Lrq_cmp_less:
    mov rax, -1
    ret
.Lrq_cmp_greater:
    mov eax, 1
    ret
.section .bss
.balign 8
rm_range_token: .skip 40
rm_range_actual: .skip 24
rm_range_term: .skip 24
rm_range_upper: .skip 24
.section .note.GNU-stack,"",@progbits
