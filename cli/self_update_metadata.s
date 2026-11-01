/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.intel_syntax noprefix
.global self_parse_release, self_source_commit

/* Read-only release metadata validation. Authentication belongs to the caller.
 * Limits: 1 MiB input, 32 nested values, 16384 tokens, 256 members per object,
 * 4096 array elements, 16384 raw string bytes, and 256-byte object keys.
 * Keys must be plain ASCII. Unknown strings support JSON escapes, paired
 * UTF-16 surrogate escapes, and valid UTF-8. Identity strings must be plain
 * ASCII. Every object rejects duplicate keys, including ignored metadata.
 * ABI: returning routines preserve RBX/RBP/R12-R15; others are scratch.
 * Global scratch makes this parser non-reentrant. Input is never changed.
 * Tokens are four qwords: type/flags, borrowed start, raw length, end token.
 */
.equ SMP_INPUT_LIMIT, 1048576
.equ SMP_DEPTH_LIMIT, 32
.equ SMP_TOKEN_LIMIT, 16384
.equ SMP_MEMBER_LIMIT, 256
.equ SMP_ARRAY_LIMIT, 4096
.equ SMP_STRING_LIMIT, 16384
.equ SMP_KEY_LIMIT, 256
.equ SMP_ASSET_LIMIT, 256
.equ SMP_OBJECT, 1
.equ SMP_ARRAY, 2
.equ SMP_STRING, 3
.equ SMP_NUMBER, 4
.equ SMP_TRUE, 5
.equ SMP_FALSE, 6
.equ SMP_NULL, 7
.equ SMP_KEY, 8
.equ SMP_ESCAPED, 256
.equ SMP_NONASCII, 512

.section .text

/* Input: RDI=readable bytes, RSI=length, RDX=validated registry row (eight
 * NUL-terminated field pointers), selecting stubbi/asm/host/executable with a
 * canonical version, byte count, and SHA-256. Output: EAX=0/1 success/failure.
 * Success copies the commit to self_source_commit[41]; failure clears it.
 * Stack: 40 saved bytes plus recursion bounded by 32; each recursive object
 * or array adds at most 64 bytes including call frames. Memory is fixed below.
 */
self_parse_release:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cld
    mov [rip + smp_cursor], rdi
    mov [rip + smp_row], rdx
    mov rax, rdi
    add rax, rsi
    jc .Lsmp_entry_fail
    mov [rip + smp_end], rax
    mov qword ptr [rip + smp_token_count], 0
    mov qword ptr [rip + smp_commit_pointer], 0
    mov qword ptr [rip + smp_asset_count], 0
    mov qword ptr [rip + smp_matching_assets], 0
    lea rdi, [rip + self_source_commit]
    xor eax, eax
    mov ecx, 41
    rep stosb
    test rsi, rsi
    jz .Lsmp_entry_fail
    cmp rsi, SMP_INPUT_LIMIT
    ja .Lsmp_entry_fail
    call smp_expected_names
    test eax, eax
    jnz .Lsmp_entry_fail
    mov edi, 1
    call smp_value
    test eax, eax
    jnz .Lsmp_entry_fail
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jne .Lsmp_entry_fail
    lea rax, [rip + smp_tokens]
    cmp qword ptr [rax], SMP_OBJECT
    jne .Lsmp_entry_fail
    mov r12, [rax + 24]
    cmp r12, [rip + smp_token_count]
    jne .Lsmp_entry_fail
    mov r13d, 1
    xor r14d, r14d
.Lsmp_root_member:
    cmp r13, r12
    jae .Lsmp_root_done
    mov rax, r13
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    lea r15, [rbx + 32]
    lea rsi, [rip + smp_key_schema]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_schema
    lea rsi, [rip + smp_key_project]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_project
    lea rsi, [rip + smp_key_repository]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_repository
    lea rsi, [rip + smp_key_version]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_version
    lea rsi, [rip + smp_key_tag]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_tag
    lea rsi, [rip + smp_key_commit]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_commit
    lea rsi, [rip + smp_key_assets]
    mov rdi, rbx
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_root_assets
    jmp .Lsmp_root_next
.Lsmp_root_schema:
    cmp qword ptr [r15], SMP_NUMBER
    jne .Lsmp_entry_fail
    cmp qword ptr [r15 + 16], 1
    jne .Lsmp_entry_fail
    mov rax, [r15 + 8]
    cmp byte ptr [rax], '1'
    jne .Lsmp_entry_fail
    or r14d, 1
    jmp .Lsmp_root_next
.Lsmp_root_project:
    lea rsi, [rip + smp_project]
    mov rdi, r15
    call smp_plain_equal
    test eax, eax
    jz .Lsmp_entry_fail
    or r14d, 2
    jmp .Lsmp_root_next
.Lsmp_root_repository:
    lea rsi, [rip + smp_repository]
    mov rdi, r15
    call smp_plain_equal
    test eax, eax
    jz .Lsmp_entry_fail
    or r14d, 4
    jmp .Lsmp_root_next
.Lsmp_root_version:
    mov rax, [rip + smp_row]
    mov rsi, [rax + 8]
    mov rdi, r15
    call smp_plain_equal
    test eax, eax
    jz .Lsmp_entry_fail
    or r14d, 8
    jmp .Lsmp_root_next
.Lsmp_root_tag:
    lea rsi, [rip + smp_expected_tag]
    mov rdi, r15
    call smp_plain_equal
    test eax, eax
    jz .Lsmp_entry_fail
    or r14d, 16
    jmp .Lsmp_root_next
.Lsmp_root_commit:
    mov rdi, r15
    mov esi, 40
    call smp_lower_hex
    test eax, eax
    jz .Lsmp_entry_fail
    mov rdx, [r15 + 8]
    xor ecx, ecx
    xor eax, eax
.Lsmp_nonzero_commit:
    mov r8b, [rdx + rcx]
    sub r8b, '0'
    or al, r8b
    inc ecx
    cmp ecx, 40
    jb .Lsmp_nonzero_commit
    test al, al
    jz .Lsmp_entry_fail
    mov [rip + smp_commit_pointer], rdx
    or r14d, 32
    jmp .Lsmp_root_next
.Lsmp_root_assets:
    mov rdi, r15
    call smp_assets
    test eax, eax
    jnz .Lsmp_entry_fail
    or r14d, 64
.Lsmp_root_next:
    mov r13, [r15 + 24]
    jmp .Lsmp_root_member
.Lsmp_root_done:
    cmp r14d, 127
    jne .Lsmp_entry_fail
    cmp qword ptr [rip + smp_matching_assets], 1
    jne .Lsmp_entry_fail
    mov rsi, [rip + smp_commit_pointer]
    lea rdi, [rip + self_source_commit]
    mov ecx, 40
    rep movsb
    mov byte ptr [rdi], 0
    xor eax, eax
    jmp .Lsmp_entry_done
.Lsmp_entry_fail:
    lea rdi, [rip + self_source_commit]
    xor eax, eax
    mov ecx, 41
    rep stosb
    mov eax, 1
.Lsmp_entry_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Input: smp_row. Output: zero and bounded expected tag/filename strings,
 * or one for a row outside the fixed package/host/kind contract. The version
 * must already be canonical; its defensive length limit is 32. Stack: 24. */
smp_expected_names:
    push rbx
    push r12
    push r13
    mov rbx, [rip + smp_row]
    mov rdi, [rbx]
    lea rsi, [rip + smp_package]
    call smp_cstr_equal
    test eax, eax
    jz .Lsmp_names_fail
    mov rdi, [rbx + 16]
    lea rsi, [rip + smp_host]
    call smp_cstr_equal
    test eax, eax
    jz .Lsmp_names_fail
    mov rdi, [rbx + 24]
    lea rsi, [rip + smp_executable]
    call smp_cstr_equal
    test eax, eax
    jz .Lsmp_names_fail
    mov rsi, [rbx + 8]
    lea r12, [rip + smp_expected_tag]
    mov byte ptr [r12], 'v'
    inc r12
    lea r13, [rip + smp_expected_file]
    mov dword ptr [r13], 0x2d6d7361
    add r13, 4
    xor ecx, ecx
.Lsmp_names_copy:
    mov al, [rsi + rcx]
    test al, al
    jz .Lsmp_names_suffix
    cmp ecx, 32
    jae .Lsmp_names_fail
    mov [r12 + rcx], al
    mov [r13 + rcx], al
    inc ecx
    jmp .Lsmp_names_copy
.Lsmp_names_suffix:
    test ecx, ecx
    jz .Lsmp_names_fail
    mov byte ptr [r12 + rcx], 0
    add r13, rcx
    lea rsi, [rip + smp_host_suffix]
.Lsmp_names_suffix_byte:
    lodsb
    mov [r13], al
    inc r13
    test al, al
    jnz .Lsmp_names_suffix_byte
    xor eax, eax
    jmp .Lsmp_names_done
.Lsmp_names_fail:
    mov eax, 1
.Lsmp_names_done:
    pop r13
    pop r12
    pop rbx
    ret

/* Input: EDI=value depth, root=1. Output: zero/one, advanced cursor and token
 * count. Checks depth before dispatch. Stack: nested bounded parser calls. */
smp_value:
    cmp edi, SMP_DEPTH_LIMIT
    ja smp_bad
    sub rsp, 8
    call smp_space
    add rsp, 8
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jae smp_bad
    movzx eax, byte ptr [rax]
    cmp al, '{'
    je smp_object
    cmp al, '['
    je smp_array
    cmp al, '"'
    je .Lsmp_value_string
    cmp al, '-'
    je smp_number
    cmp al, '0'
    jb .Lsmp_value_literal
    cmp al, '9'
    jbe smp_number
.Lsmp_value_literal:
    cmp al, 't'
    je .Lsmp_value_true
    cmp al, 'f'
    je .Lsmp_value_false
    cmp al, 'n'
    jne smp_bad
    lea rsi, [rip + smp_null]
    mov edi, SMP_NULL
    jmp smp_literal
.Lsmp_value_true:
    lea rsi, [rip + smp_true]
    mov edi, SMP_TRUE
    jmp smp_literal
.Lsmp_value_false:
    lea rsi, [rip + smp_false]
    mov edi, SMP_FALSE
    jmp smp_literal
.Lsmp_value_string:
    xor edi, edi
    jmp smp_string

/* Input: cursor at object, EDI=depth. Output: zero/one. Stores member keys as
 * tokens, then compares each key with this object's previous keys. Plain
 * ASCII unescaped keys make raw equality semantic equality. Stack: 40 bytes.
 * At most 256 members; recursive children have exclusive end token indexes. */
smp_object:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, [rip + smp_token_count]
    mov rsi, [rip + smp_cursor]
    inc qword ptr [rip + smp_cursor]
    mov edi, SMP_OBJECT
    xor edx, edx
    call smp_emit
    test eax, eax
    jnz .Lsmp_object_fail
    xor r14d, r14d
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jae .Lsmp_object_fail
    cmp byte ptr [rax], '}'
    je .Lsmp_object_close
.Lsmp_object_member:
    inc r14d
    cmp r14d, SMP_MEMBER_LIMIT
    ja .Lsmp_object_fail
    mov r15, [rip + smp_token_count]
    mov edi, 1
    call smp_string
    test eax, eax
    jnz .Lsmp_object_fail
    lea rbx, [r13 + 1]
.Lsmp_object_previous:
    cmp rbx, r15
    jae .Lsmp_object_colon
    mov rax, rbx
    shl rax, 5
    lea rdi, [rip + smp_tokens]
    add rdi, rax
    mov rax, r15
    shl rax, 5
    lea rsi, [rip + smp_tokens]
    add rsi, rax
    call smp_token_equal
    test eax, eax
    jnz .Lsmp_object_fail
    mov rax, rbx
    inc rax
    shl rax, 5
    lea rdx, [rip + smp_tokens]
    mov rbx, [rdx + rax + 24]
    jmp .Lsmp_object_previous
.Lsmp_object_colon:
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jae .Lsmp_object_fail
    cmp byte ptr [rax], ':'
    jne .Lsmp_object_fail
    inc qword ptr [rip + smp_cursor]
    lea edi, [r12d + 1]
    call smp_value
    test eax, eax
    jnz .Lsmp_object_fail
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jae .Lsmp_object_fail
    cmp byte ptr [rax], '}'
    je .Lsmp_object_close
    cmp byte ptr [rax], ','
    jne .Lsmp_object_fail
    inc qword ptr [rip + smp_cursor]
    call smp_space
    jmp .Lsmp_object_member
.Lsmp_object_close:
    inc qword ptr [rip + smp_cursor]
    mov rax, r13
    shl rax, 5
    lea rdx, [rip + smp_tokens]
    mov rcx, [rip + smp_token_count]
    mov [rdx + rax + 24], rcx
    xor eax, eax
    jmp .Lsmp_object_done
.Lsmp_object_fail:
    mov eax, 1
.Lsmp_object_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Input: cursor at array, EDI=depth. Output: zero/one. Maximum 4096 elements.
 * Each child records its exclusive end token. Stack: 24 saved bytes. */
smp_array:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13, [rip + smp_token_count]
    mov rsi, [rip + smp_cursor]
    inc qword ptr [rip + smp_cursor]
    mov edi, SMP_ARRAY
    xor edx, edx
    call smp_emit
    test eax, eax
    jnz .Lsmp_array_fail
    xor r14d, r14d
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jae .Lsmp_array_fail
    cmp byte ptr [rax], ']'
    je .Lsmp_array_close
.Lsmp_array_element:
    inc r14d
    cmp r14d, SMP_ARRAY_LIMIT
    ja .Lsmp_array_fail
    lea edi, [r12d + 1]
    call smp_value
    test eax, eax
    jnz .Lsmp_array_fail
    call smp_space
    mov rax, [rip + smp_cursor]
    cmp rax, [rip + smp_end]
    jae .Lsmp_array_fail
    cmp byte ptr [rax], ']'
    je .Lsmp_array_close
    cmp byte ptr [rax], ','
    jne .Lsmp_array_fail
    inc qword ptr [rip + smp_cursor]
    jmp .Lsmp_array_element
.Lsmp_array_close:
    inc qword ptr [rip + smp_cursor]
    mov rax, r13
    shl rax, 5
    lea rdx, [rip + smp_tokens]
    mov rcx, [rip + smp_token_count]
    mov [rdx + rax + 24], rcx
    xor eax, eax
    jmp .Lsmp_array_done
.Lsmp_array_fail:
    mov eax, 1
.Lsmp_array_done:
    pop r14
    pop r13
    pop r12
    ret


/* Input: cursor at quote, EDI=1 for plain ASCII key, else value string.
 * Output: zero/one; token excludes quotes and records escape/non-ASCII flags.
 * Every read is bounded. Limits: 256 key bytes, 16 KiB string bytes. Stack:40
 * bytes, including alignment padding. */
smp_string:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r14d, edi
    mov r12, [rip + smp_cursor]
    cmp r12, [rip + smp_end]
    jae .Lsmp_string_fail
    cmp byte ptr [r12], '"'
    jne .Lsmp_string_fail
    inc r12
    mov rbx, r12
    xor r13d, r13d
.Lsmp_string_byte:
    cmp r12, [rip + smp_end]
    jae .Lsmp_string_fail
    mov rax, r12
    sub rax, rbx
    cmp rax, SMP_STRING_LIMIT
    ja .Lsmp_string_fail
    test r14d, r14d
    jz .Lsmp_string_bound_ready
    cmp rax, SMP_KEY_LIMIT
    ja .Lsmp_string_fail
.Lsmp_string_bound_ready:
    movzx eax, byte ptr [r12]
    cmp al, '"'
    je .Lsmp_string_close
    cmp al, 32
    jb .Lsmp_string_fail
    cmp al, '\\'
    je .Lsmp_string_escape
    cmp al, 128
    jae .Lsmp_string_utf8
    inc r12
    jmp .Lsmp_string_byte
.Lsmp_string_escape:
    test r14d, r14d
    jnz .Lsmp_string_fail
    or r13d, SMP_ESCAPED
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_string_fail
    movzx eax, byte ptr [r12]
    cmp al, 'u'
    je .Lsmp_string_unicode
    cmp al, '"'
    je .Lsmp_string_escape_single
    cmp al, '\\'
    je .Lsmp_string_escape_single
    cmp al, '/'
    je .Lsmp_string_escape_single
    cmp al, 'b'
    je .Lsmp_string_escape_single
    cmp al, 'f'
    je .Lsmp_string_escape_single
    cmp al, 'n'
    je .Lsmp_string_escape_single
    cmp al, 'r'
    je .Lsmp_string_escape_single
    cmp al, 't'
    jne .Lsmp_string_fail
.Lsmp_string_escape_single:
    inc r12
    jmp .Lsmp_string_byte
.Lsmp_string_unicode:
    lea rax, [r12 + 5]
    cmp rax, [rip + smp_end]
    ja .Lsmp_string_fail
    lea rdi, [r12 + 1]
    call smp_hex4
    test eax, eax
    js .Lsmp_string_fail
    cmp eax, 0xd800
    jb .Lsmp_string_unicode_single
    cmp eax, 0xdbff
    jbe .Lsmp_string_surrogate
    cmp eax, 0xdfff
    jbe .Lsmp_string_fail
.Lsmp_string_unicode_single:
    add r12, 5
    jmp .Lsmp_string_byte
.Lsmp_string_surrogate:
    lea rax, [r12 + 11]
    cmp rax, [rip + smp_end]
    ja .Lsmp_string_fail
    cmp byte ptr [r12 + 5], '\\'
    jne .Lsmp_string_fail
    cmp byte ptr [r12 + 6], 'u'
    jne .Lsmp_string_fail
    lea rdi, [r12 + 7]
    call smp_hex4
    cmp eax, 0xdc00
    jb .Lsmp_string_fail
    cmp eax, 0xdfff
    ja .Lsmp_string_fail
    add r12, 11
    jmp .Lsmp_string_byte
.Lsmp_string_utf8:
    test r14d, r14d
    jnz .Lsmp_string_fail
    or r13d, SMP_NONASCII
    mov rdi, r12
    call smp_utf8
    test rax, rax
    jz .Lsmp_string_fail
    mov r12, rax
    jmp .Lsmp_string_byte
.Lsmp_string_close:
    lea rax, [r12 + 1]
    mov [rip + smp_cursor], rax
    mov rdx, r12
    sub rdx, rbx
    mov rsi, rbx
    mov edi, SMP_STRING
    test r14d, r14d
    jz .Lsmp_string_type
    mov edi, SMP_KEY
.Lsmp_string_type:
    or edi, r13d
    call smp_emit
    jmp .Lsmp_string_done
.Lsmp_string_fail:
    mov eax, 1
.Lsmp_string_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Input: RDI=four already-bounded bytes. Output: EAX=0..65535 or -1.
 * Accepts both JSON hexadecimal letter cases. No stack or memory writes. */
smp_hex4:
    xor eax, eax
    xor ecx, ecx
.Lsmp_hex_digit:
    movzx edx, byte ptr [rdi + rcx]
    sub edx, '0'
    cmp edx, 9
    jbe .Lsmp_hex_add
    movzx edx, byte ptr [rdi + rcx]
    or edx, 32
    sub edx, 'a'
    cmp edx, 5
    ja .Lsmp_hex_fail
    add edx, 10
.Lsmp_hex_add:
    shl eax, 4
    or eax, edx
    inc ecx
    cmp ecx, 4
    jb .Lsmp_hex_digit
    ret
.Lsmp_hex_fail:
    mov eax, -1
    ret

/* Input: RDI=non-ASCII input byte. Output: RAX=next pointer or zero.
 * Rejects overlong UTF-8, surrogates, and values above U+10FFFF. Reads at
 * most four bytes after a full length check. No stack or memory writes. */
smp_utf8:
    movzx eax, byte ptr [rdi]
    mov ecx, 2
    mov r8d, 0x80
    mov r9d, 0xbf
    cmp eax, 0xc2
    jb .Lsmp_utf8_fail
    cmp eax, 0xdf
    jbe .Lsmp_utf8_count
    mov ecx, 3
    cmp eax, 0xe0
    jne .Lsmp_utf8_not_e0
    mov r8d, 0xa0
    jmp .Lsmp_utf8_count
.Lsmp_utf8_not_e0:
    cmp eax, 0xed
    jne .Lsmp_utf8_not_ed
    mov r9d, 0x9f
    jmp .Lsmp_utf8_count
.Lsmp_utf8_not_ed:
    cmp eax, 0xef
    jbe .Lsmp_utf8_count
    mov ecx, 4
    cmp eax, 0xf0
    jne .Lsmp_utf8_not_f0
    mov r8d, 0x90
    jmp .Lsmp_utf8_count
.Lsmp_utf8_not_f0:
    cmp eax, 0xf4
    ja .Lsmp_utf8_fail
    jne .Lsmp_utf8_count
    mov r9d, 0x8f
.Lsmp_utf8_count:
    lea rax, [rdi + rcx]
    cmp rax, [rip + smp_end]
    ja .Lsmp_utf8_fail
    movzx edx, byte ptr [rdi + 1]
    cmp edx, r8d
    jb .Lsmp_utf8_fail
    cmp edx, r9d
    ja .Lsmp_utf8_fail
    mov r8d, 2
.Lsmp_utf8_continuation:
    cmp r8d, ecx
    jae .Lsmp_utf8_done
    movzx edx, byte ptr [rdi + r8]
    sub edx, 0x80
    cmp edx, 0x3f
    ja .Lsmp_utf8_fail
    inc r8d
    jmp .Lsmp_utf8_continuation
.Lsmp_utf8_done:
    ret
.Lsmp_utf8_fail:
    xor eax, eax
    ret

/* Input: cursor at '-' or digit. Output: zero/one and raw number token.
 * Implements JSON integer/fraction/exponent grammar without conversion.
 * Limit: 256 bytes. All input reads are bounded. Stack: 24 bytes, including
 * alignment padding. */
smp_number:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, [rip + smp_cursor]
    mov r12, rbx
    cmp byte ptr [r12], '-'
    jne .Lsmp_number_integer
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_fail
.Lsmp_number_integer:
    movzx eax, byte ptr [r12]
    cmp al, '0'
    je .Lsmp_number_zero
    sub eax, '1'
    cmp eax, 8
    ja .Lsmp_number_fail
.Lsmp_number_integer_digits:
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_finish
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 9
    jbe .Lsmp_number_integer_digits
    jmp .Lsmp_number_fraction
.Lsmp_number_zero:
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_finish
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 9
    jbe .Lsmp_number_fail
.Lsmp_number_fraction:
    cmp byte ptr [r12], '.'
    jne .Lsmp_number_exponent
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_fail
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 9
    ja .Lsmp_number_fail
.Lsmp_number_fraction_digits:
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_finish
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 9
    jbe .Lsmp_number_fraction_digits
.Lsmp_number_exponent:
    mov al, [r12]
    or al, 32
    cmp al, 'e'
    jne .Lsmp_number_finish
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_fail
    mov al, [r12]
    cmp al, '+'
    je .Lsmp_number_exponent_sign
    cmp al, '-'
    jne .Lsmp_number_exponent_first
.Lsmp_number_exponent_sign:
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_fail
.Lsmp_number_exponent_first:
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 9
    ja .Lsmp_number_fail
.Lsmp_number_exponent_digits:
    inc r12
    cmp r12, [rip + smp_end]
    jae .Lsmp_number_finish
    movzx eax, byte ptr [r12]
    sub eax, '0'
    cmp eax, 9
    jbe .Lsmp_number_exponent_digits
.Lsmp_number_finish:
    mov rdx, r12
    sub rdx, rbx
    cmp rdx, 256
    ja .Lsmp_number_fail
    mov [rip + smp_cursor], r12
    mov rsi, rbx
    mov edi, SMP_NUMBER
    call smp_emit
    jmp .Lsmp_number_done
.Lsmp_number_fail:
    mov eax, 1
.Lsmp_number_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

/* Input: EDI=type, RSI=static literal spelling. Output: zero/one and a token.
 * Every input read is bounded by smp_end. No stack or borrowed data writes. */
smp_literal:
    mov r8, [rip + smp_cursor]
    xor edx, edx
.Lsmp_literal_byte:
    mov al, [rsi + rdx]
    test al, al
    jz .Lsmp_literal_done
    lea rcx, [r8 + rdx]
    cmp rcx, [rip + smp_end]
    jae smp_bad
    cmp al, [rcx]
    jne smp_bad
    inc edx
    jmp .Lsmp_literal_byte
.Lsmp_literal_done:
    lea rax, [r8 + rdx]
    mov [rip + smp_cursor], rax
    mov rsi, r8
    jmp smp_emit

/* Input: cursor/end. Advances over SP/TAB/LF/CR only. RAX/RCX scratch. */
smp_space:
    mov rax, [rip + smp_cursor]
.Lsmp_space_byte:
    cmp rax, [rip + smp_end]
    jae .Lsmp_space_done
    movzx ecx, byte ptr [rax]
    cmp cl, ' '
    je .Lsmp_space_next
    cmp cl, 9
    je .Lsmp_space_next
    cmp cl, 10
    je .Lsmp_space_next
    cmp cl, 13
    jne .Lsmp_space_done
.Lsmp_space_next:
    inc rax
    jmp .Lsmp_space_byte
.Lsmp_space_done:
    mov [rip + smp_cursor], rax
    ret

/* Input: EDI=type/flags, RSI=start, RDX=length. Output: zero/one.
 * Appends one 32-byte token inside the fixed table. No stack. */
smp_emit:
    mov rax, [rip + smp_token_count]
    cmp rax, SMP_TOKEN_LIMIT
    jae smp_bad
    mov rcx, rax
    shl rcx, 5
    lea r8, [rip + smp_tokens]
    add r8, rcx
    mov [r8], rdi
    mov [r8 + 8], rsi
    mov [r8 + 16], rdx
    inc rax
    mov [r8 + 24], rax
    mov [rip + smp_token_count], rax
    xor eax, eax
    ret
smp_bad:
    mov eax, 1
    ret


/* Input: RDI/RSI=tokens containing bounded spans. Output: EAX=1 for raw byte
 * equality, else zero. Callers check kinds. No stack or memory writes. */
smp_token_equal:
    mov rcx, [rdi + 16]
    cmp rcx, [rsi + 16]
    jne .Lsmp_equal_no
    mov rdi, [rdi + 8]
    mov rsi, [rsi + 8]
    xor edx, edx
.Lsmp_equal_byte:
    cmp rdx, rcx
    jae .Lsmp_equal_yes
    mov al, [rdi + rdx]
    cmp al, [rsi + rdx]
    jne .Lsmp_equal_no
    inc rdx
    jmp .Lsmp_equal_byte
.Lsmp_equal_yes:
    mov eax, 1
    ret
.Lsmp_equal_no:
    xor eax, eax
    ret

/* Input: RDI=token, RSI=NUL-terminated static/validated text. Output: 1/0.
 * Token span is bounded. Does not read past the expected text's NUL. */
smp_token_text_equal:
    mov rcx, [rdi + 16]
    mov rdi, [rdi + 8]
    xor edx, edx
.Lsmp_text_byte:
    cmp rdx, rcx
    jae .Lsmp_text_end
    mov al, [rsi + rdx]
    test al, al
    jz .Lsmp_equal_no
    cmp al, [rdi + rdx]
    jne .Lsmp_equal_no
    inc rdx
    jmp .Lsmp_text_byte
.Lsmp_text_end:
    cmp byte ptr [rsi + rdx], 0
    jne .Lsmp_equal_no
    jmp .Lsmp_equal_yes
smp_plain_equal:
    cmp qword ptr [rdi], SMP_STRING
    jne .Lsmp_equal_no
    jmp smp_token_text_equal

/* Input: two borrowed NUL-terminated validated/static strings. Output: 1/0.
 * No stack or writes. Used only for the row's fixed identity fields. */
smp_cstr_equal:
    mov al, [rdi]
    cmp al, [rsi]
    jne .Lsmp_equal_no
    test al, al
    jz .Lsmp_equal_yes
    inc rdi
    inc rsi
    jmp smp_cstr_equal

/* Input: RDI=token, ESI=required hex length. Output: 1/0. Requires a plain
 * ASCII string and lowercase hex digits. No stack or memory writes. */
smp_lower_hex:
    cmp qword ptr [rdi], SMP_STRING
    jne .Lsmp_equal_no
    cmp [rdi + 16], rsi
    jne .Lsmp_equal_no
    mov rdi, [rdi + 8]
    xor ecx, ecx
.Lsmp_lower_hex_digit:
    movzx eax, byte ptr [rdi + rcx]
    sub eax, '0'
    cmp eax, 9
    jbe .Lsmp_lower_hex_next
    movzx eax, byte ptr [rdi + rcx]
    sub eax, 'a'
    cmp eax, 5
    ja .Lsmp_equal_no
.Lsmp_lower_hex_next:
    inc ecx
    cmp rcx, rsi
    jb .Lsmp_lower_hex_digit
    jmp .Lsmp_equal_yes

/* Input: bytes token. Output: 1 for canonical decimal 1..64 MiB, else zero.
 * Rejects signs, fractions, exponents, and leading zeroes. No stack/writes. */
smp_asset_size:
    cmp qword ptr [rdi], SMP_NUMBER
    jne .Lsmp_equal_no
    mov rcx, [rdi + 16]
    test rcx, rcx
    jz .Lsmp_equal_no
    cmp rcx, 8
    ja .Lsmp_equal_no
    mov rdi, [rdi + 8]
    cmp byte ptr [rdi], '0'
    je .Lsmp_equal_no
    xor r8d, r8d
    xor edx, edx
.Lsmp_asset_size_digit:
    movzx eax, byte ptr [rdi + rdx]
    sub eax, '0'
    cmp eax, 9
    ja .Lsmp_equal_no
    imul r8, r8, 10
    add r8, rax
    cmp r8, 67108864
    ja .Lsmp_equal_no
    inc edx
    cmp rdx, rcx
    jb .Lsmp_asset_size_digit
    jmp .Lsmp_equal_yes

/* Input: filename token. Output: 1/0. Accepts 1..160 plain ASCII bytes:
 * letters/digits plus '.', '_' and '-'; first byte is a letter or digit.
 * Names are compared, never used as paths. No stack or writes. */
smp_asset_filename:
    cmp qword ptr [rdi], SMP_STRING
    jne .Lsmp_equal_no
    mov rcx, [rdi + 16]
    test rcx, rcx
    jz .Lsmp_equal_no
    cmp rcx, 160
    ja .Lsmp_equal_no
    mov rdi, [rdi + 8]
    xor edx, edx
.Lsmp_filename_byte:
    movzx eax, byte ptr [rdi + rdx]
    cmp al, '0'
    jb .Lsmp_filename_punctuation
    cmp al, '9'
    jbe .Lsmp_filename_next
    or al, 32
    cmp al, 'a'
    jb .Lsmp_filename_punctuation
    cmp al, 'z'
    jbe .Lsmp_filename_next
.Lsmp_filename_punctuation:
    test edx, edx
    jz .Lsmp_equal_no
    mov al, [rdi + rdx]
    cmp al, '.'
    je .Lsmp_filename_next
    cmp al, '_'
    je .Lsmp_filename_next
    cmp al, '-'
    jne .Lsmp_equal_no
.Lsmp_filename_next:
    inc edx
    cmp rdx, rcx
    jb .Lsmp_filename_byte
    jmp .Lsmp_equal_yes

/* Input: assets array token. Output: zero/one. Requires 1..256 objects with
 * exactly bytes/file/sha256. Validates every record and rejects repeated
 * filenames. Binds selected filename/bytes/hash to the validated registry row.
 * Stack: 40 saved bytes plus 32 bytes of local token pointers. */
smp_assets:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    cmp qword ptr [rdi], SMP_ARRAY
    jne .Lsmp_assets_fail
    mov r12, [rdi + 24]
    lea rax, [rip + smp_tokens]
    sub rdi, rax
    shr rdi, 5
    lea r13, [rdi + 1]
.Lsmp_assets_item:
    cmp r13, r12
    jae .Lsmp_assets_done
    cmp qword ptr [rip + smp_asset_count], SMP_ASSET_LIMIT
    jae .Lsmp_assets_fail
    mov rax, r13
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    cmp qword ptr [rbx], SMP_OBJECT
    jne .Lsmp_assets_fail
    mov r14, [rbx + 24]
    inc r13
    xor r15d, r15d
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
.Lsmp_asset_member:
    cmp r13, r14
    jae .Lsmp_asset_checked
    mov rax, r13
    shl rax, 5
    lea rbx, [rip + smp_tokens]
    add rbx, rax
    mov rdi, rbx
    lea rsi, [rip + smp_key_bytes]
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_asset_bytes
    mov rdi, rbx
    lea rsi, [rip + smp_key_file]
    call smp_token_text_equal
    test eax, eax
    jnz .Lsmp_asset_file
    mov rdi, rbx
    lea rsi, [rip + smp_key_sha]
    call smp_token_text_equal
    test eax, eax
    jz .Lsmp_assets_fail
    lea rdi, [rbx + 32]
    mov [rsp + 16], rdi
    mov esi, 64
    call smp_lower_hex
    test eax, eax
    jz .Lsmp_assets_fail
    or r15d, 4
    jmp .Lsmp_asset_next_member
.Lsmp_asset_bytes:
    lea rdi, [rbx + 32]
    mov [rsp], rdi
    call smp_asset_size
    test eax, eax
    jz .Lsmp_assets_fail
    or r15d, 1
    jmp .Lsmp_asset_next_member
.Lsmp_asset_file:
    lea rdi, [rbx + 32]
    mov [rsp + 8], rdi
    call smp_asset_filename
    test eax, eax
    jz .Lsmp_assets_fail
    or r15d, 2
.Lsmp_asset_next_member:
    mov r13, [rbx + 32 + 24]
    jmp .Lsmp_asset_member
.Lsmp_asset_checked:
    cmp r15d, 7
    jne .Lsmp_assets_fail
    xor ebx, ebx
.Lsmp_asset_previous:
    cmp rbx, [rip + smp_asset_count]
    jae .Lsmp_asset_remember
    lea rax, [rip + smp_asset_names]
    mov rdi, [rax + rbx*8]
    mov rsi, [rsp + 8]
    call smp_token_equal
    test eax, eax
    jnz .Lsmp_assets_fail
    inc rbx
    jmp .Lsmp_asset_previous
.Lsmp_asset_remember:
    lea rax, [rip + smp_asset_names]
    mov rdx, [rsp + 8]
    mov [rax + rbx*8], rdx
    inc qword ptr [rip + smp_asset_count]
    mov rdi, rdx
    lea rsi, [rip + smp_expected_file]
    call smp_plain_equal
    test eax, eax
    jz .Lsmp_assets_item
    mov rax, [rip + smp_row]
    mov rsi, [rax + 48]
    mov rdi, [rsp]
    call smp_token_text_equal
    test eax, eax
    jz .Lsmp_assets_fail
    mov rax, [rip + smp_row]
    mov rsi, [rax + 32]
    mov rdi, [rsp + 16]
    call smp_plain_equal
    test eax, eax
    jz .Lsmp_assets_fail
    inc qword ptr [rip + smp_matching_assets]
    jmp .Lsmp_assets_item
.Lsmp_assets_done:
    cmp qword ptr [rip + smp_matching_assets], 1
    jne .Lsmp_assets_fail
    xor eax, eax
    jmp .Lsmp_assets_return
.Lsmp_assets_fail:
    mov eax, 1
.Lsmp_assets_return:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
smp_key_schema: .asciz "schema"
smp_key_project: .asciz "project"
smp_key_repository: .asciz "repository"
smp_key_version: .asciz "version"
smp_key_tag: .asciz "tag"
smp_key_commit: .asciz "source_commit"
smp_key_assets: .asciz "assets"
smp_key_bytes: .asciz "bytes"
smp_key_file: .asciz "file"
smp_key_sha: .asciz "sha256"
smp_project: .asciz "asm"
smp_package: .asciz "stubbi/asm"
smp_repository: .asciz "https://github.com/stubbi/asm"
smp_host: .asciz "x86_64-linux"
smp_host_suffix: .asciz "-x86_64-linux"
smp_executable: .asciz "executable"
smp_true: .asciz "true"
smp_false: .asciz "false"
smp_null: .asciz "null"

.section .bss
.balign 8
smp_cursor: .skip 8
smp_end: .skip 8
smp_row: .skip 8
smp_token_count: .skip 8
smp_commit_pointer: .skip 8
smp_asset_count: .skip 8
smp_matching_assets: .skip 8
smp_expected_tag: .skip 40
smp_expected_file: .skip 64
self_source_commit: .skip 41
.balign 8
smp_asset_names: .skip SMP_ASSET_LIMIT * 8
smp_tokens: .skip SMP_TOKEN_LIMIT * 32

.section .note.GNU-stack,"",@progbits
