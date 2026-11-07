/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and README.md#license for the terms and scope.
 */
.intel_syntax noprefix
.global extract_source_archive, verify_source_archive
.global validate_source_archive, source_archive_member

/* Source archive boundary. Linux x86-64, SysV callee-saved registers preserved.
 * extract_source_archive(gzip_path, new_directory) returns 0 or 1.
 * verify_source_archive(gzip_path, existing_directory) returns 0 or 1.
 * Callers verify the compressed artifact digest before either operation.
 * Both paths are NUL-terminated. The destination parent must already exist.
 * Calls are serial: bounded buffers belong to this module, not the stack.
 * Public calls preserve RBX/RBP/R12-R15. Other integer registers and flags are
 * scratch. All nested calls use the same rule unless a parser cursor is noted.
 * All TAR parsing, path checks, file comparison and extraction are assembly.
 * A fixed /usr/bin/gzip process receives an already opened file on stdin and
 * an empty environment. Its output is capped before any filesystem mutation.
 */
.equ ARC_LIMIT, 67108864
.equ ARC_FILE_LIMIT, 16777216
.equ ARC_COUNT, 4096
.equ ARC_PATH, 240
.equ ARC_RDONLY, 657408        /* O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK */
.equ ARC_DIRECTORY, 722944     /* above | O_DIRECTORY */
.equ ARC_CREATE, 655553        /* O_CLOEXEC | O_NOFOLLOW | O_WRONLY | O_CREAT | O_EXCL */

.section .text
/* Read-only validation. A successful call leaves a bounded member table for
 * source_archive_member. No file is created. RDI is the gzip path; EAX=0/1. */
validate_source_archive:
    push rbx
    mov [rip + arc_input_path], rdi
    mov qword ptr [rip + arc_entry_count], 0
    mov qword ptr [rip + arc_file_count], 0
    cld
    call arc_decompress
    test eax, eax
    jnz .Larc_validate_only_done
    call arc_validate
.Larc_validate_only_done:
    pop rbx
    ret

/* Lookup after successful validation. RDI=name. RAX=borrowed content pointer,
 * RDX=byte count, ECX=0 for a file or 1 for a directory. RAX=0 means absent.
 * Pointers remain valid until the next archive operation. */
source_archive_member:
    xor r8d, r8d
.Larc_member_lookup:
    cmp r8, [rip + arc_entry_count]
    jae .Larc_member_absent
    mov rax, r8
    shl rax, 8
    lea rsi, [rip + arc_paths]
    add rsi, rax
    xor ecx, ecx
.Larc_lookup_compare:
    mov al, [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .Larc_lookup_next
    test al, al
    jz .Larc_lookup_found
    inc ecx
    jmp .Larc_lookup_compare
.Larc_lookup_next:
    inc r8
    jmp .Larc_member_lookup
.Larc_lookup_found:
    shl r8, 5
    lea rsi, [rip + arc_entries]
    add rsi, r8
    lea rax, [rip + arc_data]
    add rax, [rsi]
    mov rdx, [rsi + 8]
    mov ecx, [rsi + 20]
    ret
.Larc_member_absent:
    xor eax, eax
    ret

extract_source_archive:
    xor edx, edx
    jmp arc_operation_start
verify_source_archive:
    mov edx, 1
/* Shared terminal operation body. EDX selects extraction (0) or comparison
 * (1). Owns the root/parent descriptors and stage flag. Stack frame: 56 bytes. */
arc_operation_start:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov [rip + arc_input_path], rdi
    mov [rip + arc_output_path], rsi
    mov [rip + arc_operation], edx
    mov qword ptr [rip + arc_parent_fd], -1
    mov qword ptr [rip + arc_root_fd], -1
    mov byte ptr [rip + arc_stage_created], 0
    mov qword ptr [rip + arc_entry_count], 0
    mov qword ptr [rip + arc_file_count], 0
    mov dword ptr [rip + arc_result], 1
    cld
    lea rdi, [rip + arc_seen]
    mov ecx, ARC_COUNT
    xor eax, eax
    rep stosb
    call arc_decompress
    test eax, eax
    jnz .Larc_finish
    call arc_validate
    test eax, eax
    jnz .Larc_finish
    call arc_open_parent
    test eax, eax
    jnz .Larc_finish
    cmp dword ptr [rip + arc_operation], 0
    je .Larc_extract
    mov eax, 257
    mov rdi, [rip + arc_parent_fd]
    lea rsi, [rip + arc_destination_leaf]
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_finish
    mov [rip + arc_root_fd], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call arc_walk_tree
    test eax, eax
    jnz .Larc_finish
    xor ecx, ecx
    lea rdx, [rip + arc_seen]
.Larc_check_seen:
    cmp rcx, [rip + arc_entry_count]
    jae .Larc_success
    cmp byte ptr [rdx + rcx], 1
    jne .Larc_finish
    inc rcx
    jmp .Larc_check_seen
.Larc_extract:
    call arc_create_stage
    test eax, eax
    jnz .Larc_finish
    xor r12d, r12d
.Larc_extract_entry:
    cmp r12, [rip + arc_entry_count]
    jae .Larc_publish_stage
    mov rax, r12
    shl rax, 8
    lea rdi, [rip + arc_paths]
    add rdi, rax
    call arc_member_parent
    test rax, rax
    js .Larc_finish
    mov r13, rax
    mov r14, rdx
    mov rax, r12
    shl rax, 5
    lea r15, [rip + arc_entries]
    add r15, rax
    cmp dword ptr [r15 + 20], 0
    je .Larc_extract_file
    mov eax, 258
    mov rdi, r13
    mov rsi, r14
    mov edx, 493
    syscall
    test rax, rax
    jns .Larc_extract_directory_check
    cmp rax, -17
    jne .Larc_extract_parent_error
.Larc_extract_directory_check:
    mov eax, 257
    mov rdi, r13
    mov rsi, r14
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_extract_parent_error
    mov rdi, rax
    call arc_close
    jmp .Larc_extract_next
.Larc_extract_file:
    mov eax, 257
    mov rdi, r13
    mov rsi, r14
    mov edx, ARC_CREATE
    mov r10d, 384
    syscall
    test rax, rax
    js .Larc_extract_parent_error
    mov rbp, rax
    lea rsi, [rip + arc_data]
    add rsi, [r15]
    mov rdx, [r15 + 8]
.Larc_write:
    test rdx, rdx
    jz .Larc_file_mode
    mov eax, 1
    mov rdi, rbp
    syscall
    cmp rax, -4
    je .Larc_write
    test rax, rax
    jle .Larc_extract_file_error
    add rsi, rax
    sub rdx, rax
    jmp .Larc_write
.Larc_file_mode:
    mov eax, 91
    mov rdi, rbp
    mov esi, [r15 + 16]
    syscall
    test rax, rax
    js .Larc_extract_file_error
    mov rdi, rbp
    call arc_close
.Larc_extract_next:
    mov rdi, r13
    call arc_close
    inc r12
    jmp .Larc_extract_entry
.Larc_extract_file_error:
    mov rdi, rbp
    call arc_close
.Larc_extract_parent_error:
    mov rdi, r13
    call arc_close
    jmp .Larc_finish
.Larc_publish_stage:
    mov eax, 91
    mov rdi, [rip + arc_root_fd]
    mov esi, 493
    syscall
    test rax, rax
    js .Larc_finish
    mov eax, 316                 /* renameat2, RENAME_NOREPLACE */
    mov rdi, [rip + arc_parent_fd]
    lea rsi, [rip + arc_stage_name]
    mov rdx, rdi
    lea r10, [rip + arc_destination_leaf]
    mov r8d, 1
    syscall
    test rax, rax
    js .Larc_finish
    mov byte ptr [rip + arc_stage_created], 0
.Larc_success:
    mov dword ptr [rip + arc_result], 0
.Larc_finish:
    cmp byte ptr [rip + arc_stage_created], 0
    je .Larc_close_root
    mov rdi, [rip + arc_root_fd]
    test rdi, rdi
    js .Larc_remove_stage
    xor esi, esi
    mov edx, 1
    call arc_walk_tree
.Larc_remove_stage:
    mov eax, 263
    mov rdi, [rip + arc_parent_fd]
    lea rsi, [rip + arc_stage_name]
    mov edx, 512
    syscall
.Larc_close_root:
    mov rdi, [rip + arc_root_fd]
    call arc_close
    mov rdi, [rip + arc_parent_fd]
    call arc_close
    mov eax, [rip + arc_result]
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Close an owned descriptor. Negative descriptors are an empty slot. */
arc_close:
    test rdi, rdi
    js .Larc_close_done
    mov eax, 3
    syscall
.Larc_close_done:
    ret

/* Ensure our descriptors cannot alias stdin/stdout/stderr in the child. */
arc_promote_fd:
    cmp rdi, 3
    jae .Larc_promote_same
    push rbx
    mov rbx, rdi
    mov eax, 72
    mov esi, 1030               /* F_DUPFD_CLOEXEC */
    mov edx, 3
    syscall
    push rax
    mov rdi, rbx
    call arc_close
    pop rax
    pop rbx
    ret
.Larc_promote_same:
    mov rax, rdi
    ret

/* Input: arc_input_path. Output: EAX=0/1, arc_data[0..arc_raw_size) on success.
 * Capacity: 64 MiB + one overflow byte. Owns source/pipe descriptors and child.
 * Retries EINTR, reaps the child, and caps output before validation. Frame:56. */
arc_decompress:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, -1
    mov r13, -1
    mov r14, -1
    mov r15, -1
    mov qword ptr [rip + arc_raw_size], 0
    mov eax, 257
    mov rdi, -100
    mov rsi, [rip + arc_input_path]
    mov edx, ARC_RDONLY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_decompress_fail
    mov rdi, rax
    call arc_promote_fd
    test rax, rax
    js .Larc_decompress_fail
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + arc_stat]
    syscall
    test rax, rax
    js .Larc_decompress_fail
    mov eax, [rip + arc_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Larc_decompress_fail
    mov rax, [rip + arc_stat + 48]
    test rax, rax
    jle .Larc_decompress_fail
    cmp rax, ARC_LIMIT
    ja .Larc_decompress_fail
    mov eax, 293
    lea rdi, [rip + arc_pipe]
    mov esi, 524288
    syscall
    test rax, rax
    js .Larc_decompress_fail
    mov edi, [rip + arc_pipe]
    call arc_promote_fd
    mov r13, rax
    mov edi, [rip + arc_pipe + 4]
    call arc_promote_fd
    mov r14, rax
    test r13, r13
    js .Larc_decompress_fail
    test r14, r14
    js .Larc_decompress_fail
    mov eax, 57
    syscall
    test rax, rax
    js .Larc_decompress_fail
    jz .Larc_gzip_child
    mov r15, rax
    mov rdi, r14
    call arc_close
    mov r14, -1
    mov rdi, r12
    call arc_close
    mov r12, -1
    xor ebx, ebx
.Larc_gzip_read:
    mov eax, 0
    mov rdi, r13
    lea rsi, [rip + arc_data]
    add rsi, rbx
    mov edx, ARC_LIMIT + 1
    sub rdx, rbx
    cmp rdx, 65536
    jbe .Larc_gzip_read_size
    mov edx, 65536
.Larc_gzip_read_size:
    syscall
    cmp rax, -4
    je .Larc_gzip_read
    test rax, rax
    js .Larc_decompress_kill
    jz .Larc_gzip_eof
    add rbx, rax
    cmp rbx, ARC_LIMIT
    ja .Larc_decompress_kill
    jmp .Larc_gzip_read
.Larc_gzip_eof:
    mov [rip + arc_raw_size], rbx
    mov rdi, r13
    call arc_close
    mov r13, -1
.Larc_gzip_wait:
    mov eax, 61
    mov rdi, r15
    lea rsi, [rip + arc_child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Larc_gzip_wait
    test rax, rax
    js .Larc_decompress_fail
    mov r15, -1
    cmp dword ptr [rip + arc_child_status], 0
    jne .Larc_decompress_fail
    xor ebp, ebp
    jmp .Larc_decompress_close
.Larc_decompress_kill:
    mov eax, 62
    mov rdi, r15
    mov esi, 9
    syscall
.Larc_decompress_reap:
    mov eax, 61
    mov rdi, r15
    lea rsi, [rip + arc_child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Larc_decompress_reap
    mov r15, -1
.Larc_decompress_fail:
    mov ebp, 1
.Larc_decompress_close:
    mov rdi, r12
    call arc_close
    mov rdi, r13
    call arc_close
    mov rdi, r14
    call arc_close
    mov eax, ebp
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Larc_gzip_child:
    mov eax, 33
    mov rdi, r12
    xor esi, esi
    syscall
    test rax, rax
    js .Larc_gzip_child_fail
    mov eax, 33
    mov rdi, r14
    mov esi, 1
    syscall
    test rax, rax
    js .Larc_gzip_child_fail
    mov rdi, r12
    call arc_close
    mov rdi, r13
    call arc_close
    mov rdi, r14
    call arc_close
    mov eax, 59
    lea rdi, [rip + arc_gzip]
    lea rsi, [rip + arc_gzip_argv]
    lea rdx, [rip + arc_empty_env]
    syscall
.Larc_gzip_child_fail:
    mov eax, 60
    mov edi, 126
    syscall
    ud2

/* Return 1 for an all-zero region, including the empty region. */
arc_is_zero:
    mov rcx, rsi
    xor eax, eax
    repe scasb
    sete al
    ret

/* Parse canonical unsigned octal with leading spaces and NUL/space suffix. */
arc_octal:
    xor eax, eax
    xor r8d, r8d
.Larc_octal_leading:
    test ecx, ecx
    jz .Larc_octal_bad
    cmp byte ptr [rdi], 32
    jne .Larc_octal_digits
    inc rdi
    dec ecx
    jmp .Larc_octal_leading
.Larc_octal_digits:
    test ecx, ecx
    jz .Larc_octal_end
    movzx edx, byte ptr [rdi]
    cmp edx, '0'
    jb .Larc_octal_suffix
    cmp edx, '7'
    ja .Larc_octal_bad
    mov r9, rax
    shr r9, 61
    jnz .Larc_octal_bad
    shl rax, 3
    sub edx, '0'
    or rax, rdx
    inc r8d
    inc rdi
    dec ecx
    jmp .Larc_octal_digits
.Larc_octal_suffix:
    test edx, edx
    jz .Larc_octal_suffix_next
    cmp edx, 32
    jne .Larc_octal_bad
.Larc_octal_suffix_next:
    inc rdi
    dec ecx
    jz .Larc_octal_end
    movzx edx, byte ptr [rdi]
    jmp .Larc_octal_suffix
.Larc_octal_end:
    test r8d, r8d
    jz .Larc_octal_bad
    clc
    ret
.Larc_octal_bad:
    stc
    ret

/* A TAR text field ends at its first NUL. Remaining bytes must be zero. */
arc_field_length:
    xor eax, eax
.Larc_field_scan:
    cmp eax, ecx
    jae .Larc_field_ok
    cmp byte ptr [rdi + rax], 0
    je .Larc_field_tail
    inc eax
    jmp .Larc_field_scan
.Larc_field_tail:
    mov edx, eax
.Larc_field_tail_loop:
    cmp edx, ecx
    jae .Larc_field_ok
    cmp byte ptr [rdi + rdx], 0
    jne .Larc_field_bad
    inc edx
    jmp .Larc_field_tail_loop
.Larc_field_ok:
    clc
    ret
.Larc_field_bad:
    stc
    ret

/* Portable member paths. Dot segments, empty segments, trailing dots, option
 * prefixes, controls and shell/path punctuation cannot reach openat. */
arc_path_valid:
    test esi, esi
    jz .Larc_path_bad
    cmp esi, ARC_PATH
    ja .Larc_path_bad
    xor ecx, ecx
    xor r8d, r8d
.Larc_path_loop:
    cmp ecx, esi
    jae .Larc_path_last
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, '/'
    je .Larc_path_separator
    test r8d, r8d
    jnz .Larc_path_character
    cmp eax, '-'
    je .Larc_path_bad
.Larc_path_character:
    cmp eax, 'A'
    jb .Larc_path_digit
    cmp eax, 'Z'
    jbe .Larc_path_advance
    cmp eax, 'a'
    jb .Larc_path_symbol
    cmp eax, 'z'
    jbe .Larc_path_advance
    jmp .Larc_path_bad
.Larc_path_digit:
    cmp eax, '0'
    jb .Larc_path_symbol
    cmp eax, '9'
    jbe .Larc_path_advance
.Larc_path_symbol:
    cmp eax, '_'
    je .Larc_path_advance
    cmp eax, '.'
    je .Larc_path_advance
    cmp eax, '-'
    jne .Larc_path_bad
.Larc_path_advance:
    inc ecx
    inc r8d
    jmp .Larc_path_loop
.Larc_path_separator:
    test r8d, r8d
    jz .Larc_path_bad
    cmp byte ptr [rdi + rcx - 1], '.'
    je .Larc_path_bad
    xor r8d, r8d
    inc ecx
    jmp .Larc_path_loop
.Larc_path_last:
    test r8d, r8d
    jz .Larc_path_bad
    cmp byte ptr [rdi + rcx - 1], '.'
    je .Larc_path_bad
    xor eax, eax
    ret
.Larc_path_bad:
    mov eax, 1
    ret

/* Compare a new path to previous paths, folding ASCII case. Reject duplicates
 * and either ordering of a regular file used as an ancestor directory. */
arc_check_conflicts:
    xor r8d, r8d
.Larc_conflict_entry:
    cmp r8, [rip + arc_entry_count]
    jae .Larc_conflict_ok
    mov rax, r8
    shl rax, 8
    lea r9, [rip + arc_paths]
    add r9, rax
    xor ecx, ecx
.Larc_conflict_char:
    movzx eax, byte ptr [rdi + rcx]
    movzx edx, byte ptr [r9 + rcx]
    test eax, eax
    jz .Larc_conflict_new_end
    test edx, edx
    jz .Larc_conflict_old_end
    cmp eax, 'A'
    jb .Larc_conflict_fold_old
    cmp eax, 'Z'
    ja .Larc_conflict_fold_old
    add eax, 32
.Larc_conflict_fold_old:
    cmp edx, 'A'
    jb .Larc_conflict_compare
    cmp edx, 'Z'
    ja .Larc_conflict_compare
    add edx, 32
.Larc_conflict_compare:
    cmp eax, edx
    jne .Larc_conflict_next
    inc ecx
    jmp .Larc_conflict_char
.Larc_conflict_new_end:
    test edx, edx
    jz .Larc_conflict_bad
    cmp edx, '/'
    jne .Larc_conflict_next
    test esi, esi
    jz .Larc_conflict_bad
    jmp .Larc_conflict_next
.Larc_conflict_old_end:
    cmp eax, '/'
    jne .Larc_conflict_next
    mov rax, r8
    shl rax, 5
    lea rdx, [rip + arc_entries]
    cmp dword ptr [rdx + rax + 20], 0
    je .Larc_conflict_bad
.Larc_conflict_next:
    inc r8
    jmp .Larc_conflict_entry
.Larc_conflict_ok:
    xor eax, eax
    ret
.Larc_conflict_bad:
    mov eax, 1
    ret

/* Input: bounded arc_data/raw_size. Output: EAX=0/1, paths and member table.
 * Table bounds: 4096 records, 256 bytes/path, 32 bytes/record. No file writes.
 * Scratch stack: 72 bytes including callee-saved registers. */
arc_validate:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    lea r12, [rip + arc_data]
    xor r13d, r13d
    mov r14, [rip + arc_raw_size]
    test r14, 511
    jnz .Larc_validate_bad
.Larc_header:
    lea rax, [r13 + 512]
    cmp rax, r14
    ja .Larc_validate_bad
    lea rbx, [r12 + r13]
    mov rdi, rbx
    mov esi, 512
    call arc_is_zero
    test eax, eax
    jnz .Larc_tar_end
    cmp qword ptr [rip + arc_entry_count], ARC_COUNT
    jae .Larc_validate_bad
    cmp dword ptr [rbx + 257], 0x61747375
    jne .Larc_validate_bad
    cmp word ptr [rbx + 261], 0x0072
    jne .Larc_validate_bad
    cmp word ptr [rbx + 263], 0x3030
    jne .Larc_validate_bad
    xor ebp, ebp
    xor ecx, ecx
.Larc_checksum:
    movzx eax, byte ptr [rbx + rcx]
    cmp ecx, 148
    jb .Larc_checksum_add
    cmp ecx, 156
    jae .Larc_checksum_add
    mov eax, 32
.Larc_checksum_add:
    add ebp, eax
    inc ecx
    cmp ecx, 512
    jb .Larc_checksum
    lea rdi, [rbx + 148]
    mov ecx, 8
    call arc_octal
    jc .Larc_validate_bad
    cmp rax, rbp
    jne .Larc_validate_bad
    movzx eax, byte ptr [rbx + 156]
    xor ebp, ebp
    test eax, eax
    jz .Larc_header_type
    cmp eax, '0'
    je .Larc_header_type
    cmp eax, '5'
    jne .Larc_validate_bad
    mov ebp, 1
.Larc_header_type:
    mov [rsp], ebp
    lea rdi, [rbx + 157]
    mov esi, 100
    call arc_is_zero
    test eax, eax
    jz .Larc_validate_bad
    mov rax, [rip + arc_entry_count]
    shl rax, 8
    lea r15, [rip + arc_paths]
    add r15, rax
    lea rdi, [rbx + 345]
    mov ecx, 155
    call arc_field_length
    jc .Larc_validate_bad
    mov rbp, rax
    lea rsi, [rbx + 345]
    mov rdi, r15
    mov rcx, rbp
    rep movsb
    test rbp, rbp
    jz .Larc_path_name
    mov byte ptr [r15 + rbp], '/'
    inc rbp
.Larc_path_name:
    mov rdi, rbx
    mov ecx, 100
    call arc_field_length
    jc .Larc_validate_bad
    test rax, rax
    jz .Larc_validate_bad
    lea rdx, [rbp + rax]
    cmp rdx, ARC_PATH
    ja .Larc_validate_bad
    mov rsi, rbx
    lea rdi, [r15 + rbp]
    mov rcx, rax
    rep movsb
    mov rbp, rdx
    cmp dword ptr [rsp], 0
    je .Larc_path_terminate
.Larc_trim_directory:
    test rbp, rbp
    jz .Larc_validate_bad
    cmp byte ptr [r15 + rbp - 1], '/'
    jne .Larc_path_terminate
    dec rbp
    jmp .Larc_trim_directory
.Larc_path_terminate:
    mov byte ptr [r15 + rbp], 0
    mov rdi, r15
    mov rsi, rbp
    call arc_path_valid
    test eax, eax
    jnz .Larc_validate_bad
    mov rdi, r15
    mov esi, [rsp]
    call arc_check_conflicts
    test eax, eax
    jnz .Larc_validate_bad
    lea rdi, [rbx + 100]
    mov ecx, 8
    call arc_octal
    jc .Larc_validate_bad
    cmp rax, 420
    je .Larc_mode_ok
    cmp rax, 493
    jne .Larc_validate_bad
.Larc_mode_ok:
    mov [rsp + 4], eax
    lea rdi, [rbx + 108]
    mov ecx, 8
    call arc_octal
    jc .Larc_validate_bad
    test rax, rax
    jnz .Larc_validate_bad
    lea rdi, [rbx + 116]
    mov ecx, 8
    call arc_octal
    jc .Larc_validate_bad
    test rax, rax
    jnz .Larc_validate_bad
    lea rdi, [rbx + 124]
    mov ecx, 12
    call arc_octal
    jc .Larc_validate_bad
    cmp rax, ARC_FILE_LIMIT
    ja .Larc_validate_bad
    cmp dword ptr [rsp], 0
    je .Larc_size_file
    test rax, rax
    jnz .Larc_validate_bad
    jmp .Larc_size_ok
.Larc_size_file:
    inc qword ptr [rip + arc_file_count]
.Larc_size_ok:
    mov [rsp + 8], rax
    lea rbp, [rax + 511]
    and rbp, -512
    lea r15, [r13 + 512]
    add rbp, r15
    cmp rbp, r14
    ja .Larc_validate_bad
    lea rdi, [r12 + r15]
    add rdi, rax
    mov rsi, rbp
    sub rsi, r15
    sub rsi, rax
    call arc_is_zero
    test eax, eax
    jz .Larc_validate_bad
    mov rax, [rip + arc_entry_count]
    shl rax, 5
    lea rdx, [rip + arc_entries]
    add rdx, rax
    mov [rdx], r15
    mov rax, [rsp + 8]
    mov [rdx + 8], rax
    mov eax, [rsp + 4]
    mov [rdx + 16], eax
    mov eax, [rsp]
    mov [rdx + 20], eax
    inc qword ptr [rip + arc_entry_count]
    mov r13, rbp
    jmp .Larc_header
.Larc_tar_end:
    mov rsi, r14
    sub rsi, r13
    cmp rsi, 1024
    jb .Larc_validate_bad
    mov rdi, rbx
    call arc_is_zero
    test eax, eax
    jz .Larc_validate_bad
    cmp qword ptr [rip + arc_file_count], 0
    je .Larc_validate_bad
    xor eax, eax
    jmp .Larc_validate_return
.Larc_validate_bad:
    mov eax, 1
.Larc_validate_return:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Walk the user-supplied parent with O_NOFOLLOW on each component. No parent
 * is created. Dot is allowed as a parent; dot-dot is never followed. */
arc_open_parent:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, 16
    mov rsi, [rip + arc_output_path]
    lea rdi, [rip + arc_output_copy]
    xor ecx, ecx
.Larc_copy_output:
    cmp ecx, 4095
    jae .Larc_parent_bad
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .Larc_output_copied
    inc ecx
    jmp .Larc_copy_output
.Larc_output_copied:
    test ecx, ecx
    jz .Larc_parent_bad
    cmp byte ptr [rdi + rcx - 1], '/'
    je .Larc_parent_bad
    lea rbx, [rip + arc_output_copy]
    lea rsi, [rip + arc_dot]
    cmp byte ptr [rbx], '/'
    jne .Larc_parent_open_start
    lea rsi, [rip + arc_slash]
    inc rbx
.Larc_parent_open_start:
    mov eax, 257
    mov rdi, -100
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_parent_bad
    mov [rip + arc_parent_fd], rax
.Larc_parent_component:
    mov r12, rbx
    xor r13d, r13d
.Larc_parent_find_end:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .Larc_parent_leaf
    cmp eax, '/'
    je .Larc_parent_descend
    inc rbx
    inc r13
    cmp r13, 255
    ja .Larc_parent_bad
    jmp .Larc_parent_find_end
.Larc_parent_descend:
    test r13, r13
    jz .Larc_parent_bad
    mov byte ptr [rbx], 0
    inc rbx
    cmp word ptr [r12], 0x2e2e
    jne .Larc_parent_not_dotdot
    cmp byte ptr [r12 + 2], 0
    je .Larc_parent_bad
.Larc_parent_not_dotdot:
    cmp word ptr [r12], 0x002e
    je .Larc_parent_component
    mov eax, 257
    mov rdi, [rip + arc_parent_fd]
    mov rsi, r12
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_parent_bad
    mov r14, rax
    mov rdi, [rip + arc_parent_fd]
    call arc_close
    mov [rip + arc_parent_fd], r14
    jmp .Larc_parent_component
.Larc_parent_leaf:
    test r13, r13
    jz .Larc_parent_bad
    cmp word ptr [r12], 0x002e
    je .Larc_parent_bad
    cmp word ptr [r12], 0x2e2e
    jne .Larc_parent_save_leaf
    cmp byte ptr [r12 + 2], 0
    je .Larc_parent_bad
.Larc_parent_save_leaf:
    lea rdi, [rip + arc_destination_leaf]
    mov rsi, r12
    lea rcx, [r13 + 1]
    rep movsb
    xor eax, eax
    jmp .Larc_parent_return
.Larc_parent_bad:
    mov eax, 1
.Larc_parent_return:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Input: owned arc_parent_fd. Output: EAX=0/1, root fd and stage ownership flag.
 * Creates mode-0700 random sibling with mkdirat, then opens without following
 * a link. Stage-name capacity is 45 bytes; random input is 16 bytes. Frame:8. */
arc_create_stage:
    push rbx
    mov eax, 318
    lea rdi, [rip + arc_random]
    mov esi, 16
    xor edx, edx
    syscall
    cmp rax, 16
    jne .Larc_stage_bad
    lea rsi, [rip + arc_random]
    lea rdi, [rip + arc_stage_name + 11]
    lea r8, [rip + arc_hex]
    xor ecx, ecx
.Larc_stage_hex:
    movzx eax, byte ptr [rsi + rcx]
    mov edx, eax
    shr eax, 4
    and edx, 15
    mov al, [r8 + rax]
    mov dl, [r8 + rdx]
    mov [rdi + rcx * 2], al
    mov [rdi + rcx * 2 + 1], dl
    inc ecx
    cmp ecx, 16
    jb .Larc_stage_hex
    mov byte ptr [rdi + 32], 0
    mov eax, 258
    mov rdi, [rip + arc_parent_fd]
    lea rsi, [rip + arc_stage_name]
    mov edx, 448
    syscall
    test rax, rax
    js .Larc_stage_bad
    mov byte ptr [rip + arc_stage_created], 1
    mov eax, 257
    mov rdi, [rip + arc_parent_fd]
    lea rsi, [rip + arc_stage_name]
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_stage_bad
    mov [rip + arc_root_fd], rax
    xor eax, eax
    pop rbx
    ret
.Larc_stage_bad:
    mov eax, 1
    pop rbx
    ret

/* Open/create implied parent directories below the private staging descriptor.
 * Return an owned parent fd in RAX and final component pointer in RDX. */
arc_member_parent:
    push rbx
    push rbp
    push r12
    push r13
    sub rsp, 8
    mov rsi, rdi
    lea rdi, [rip + arc_member_copy]
    xor ecx, ecx
.Larc_member_copy:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    inc ecx
    test al, al
    jnz .Larc_member_copy
    mov eax, 72
    mov rdi, [rip + arc_root_fd]
    mov esi, 1030
    mov edx, 3
    syscall
    test rax, rax
    js .Larc_member_return
    mov r12, rax
    lea rbx, [rip + arc_member_copy]
.Larc_member_component:
    mov rbp, rbx
.Larc_member_find:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .Larc_member_done
    cmp eax, '/'
    je .Larc_member_descend
    inc rbx
    jmp .Larc_member_find
.Larc_member_descend:
    mov byte ptr [rbx], 0
    inc rbx
    mov eax, 258
    mov rdi, r12
    mov rsi, rbp
    mov edx, 493
    syscall
    test rax, rax
    jns .Larc_member_open
    cmp rax, -17
    jne .Larc_member_fail
.Larc_member_open:
    mov eax, 257
    mov rdi, r12
    mov rsi, rbp
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_member_fail
    mov r13, rax
    mov rdi, r12
    call arc_close
    mov r12, r13
    jmp .Larc_member_component
.Larc_member_done:
    mov rax, r12
    mov rdx, rbp
    jmp .Larc_member_return
.Larc_member_fail:
    mov rdi, r12
    call arc_close
    mov rax, -1
.Larc_member_return:
    add rsp, 8
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Match arc_scan_path to a record of requested type (ESI). A directory may
 * also be an implicit parent. Return its index, -1 for implicit, -2 for error. */
arc_find_entry:
    xor r8d, r8d
    xor r9d, r9d
    lea rdi, [rip + arc_scan_path]
.Larc_find_loop:
    cmp r8, [rip + arc_entry_count]
    jae .Larc_find_end
    mov rax, r8
    shl rax, 8
    lea rdx, [rip + arc_paths]
    add rdx, rax
    xor ecx, ecx
.Larc_find_compare:
    mov al, [rdi + rcx]
    test al, al
    jz .Larc_find_path_end
    cmp al, [rdx + rcx]
    jne .Larc_find_next
    inc ecx
    jmp .Larc_find_compare
.Larc_find_path_end:
    cmp byte ptr [rdx + rcx], 0
    je .Larc_find_exact
    cmp byte ptr [rdx + rcx], '/'
    jne .Larc_find_next
    mov r9d, 1
.Larc_find_next:
    inc r8
    jmp .Larc_find_loop
.Larc_find_exact:
    mov rax, r8
    shl rax, 5
    lea rdx, [rip + arc_entries]
    cmp [rdx + rax + 20], esi
    jne .Larc_find_bad
    mov rax, r8
    ret
.Larc_find_end:
    test esi, esi
    jz .Larc_find_bad
    test r9d, r9d
    jz .Larc_find_bad
    mov rax, -1
    ret
.Larc_find_bad:
    mov rax, -2
    ret

/* Verify one actual regular file against an expected record. RDI is its
 * parent, RSI its leaf, R8 its record index. No symlink or FIFO is followed. */
arc_compare_file:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, r8
    mov eax, 257
    mov edx, ARC_RDONLY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_compare_bad_no_fd
    mov r13, rax
    mov eax, 5
    mov rdi, r13
    lea rsi, [rip + arc_stat]
    syscall
    test rax, rax
    js .Larc_compare_bad
    mov eax, [rip + arc_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Larc_compare_bad
    cmp qword ptr [rip + arc_stat + 16], 1
    jne .Larc_compare_bad
    mov rax, r12
    shl rax, 5
    lea rbx, [rip + arc_entries]
    add rbx, rax
    mov r14, [rbx + 8]
    cmp r14, [rip + arc_stat + 48]
    jne .Larc_compare_bad
    lea r15, [rip + arc_data]
    add r15, [rbx]
.Larc_compare_read:
    mov eax, 0
    mov rdi, r13
    lea rsi, [rip + arc_compare_buffer]
    mov rdx, r14
    cmp rdx, 65536
    jbe .Larc_compare_read_size
    mov edx, 65536
.Larc_compare_read_size:
    test rdx, rdx
    jz .Larc_compare_eof
    syscall
    cmp rax, -4
    je .Larc_compare_read
    test rax, rax
    jle .Larc_compare_bad
    mov rbp, rax
    mov rcx, rax
    lea rsi, [rip + arc_compare_buffer]
    mov rdi, r15
    repe cmpsb
    jne .Larc_compare_bad
    add r15, rbp
    sub r14, rbp
    jmp .Larc_compare_read
.Larc_compare_eof:
    mov eax, 0
    mov rdi, r13
    lea rsi, [rip + arc_compare_buffer]
    mov edx, 1
    syscall
    cmp rax, -4
    je .Larc_compare_eof
    test rax, rax
    jne .Larc_compare_bad
    lea rdx, [rip + arc_seen]
    mov byte ptr [rdx + r12], 1
    mov rdi, r13
    call arc_close
    xor eax, eax
    jmp .Larc_compare_return
.Larc_compare_bad:
    mov rdi, r13
    call arc_close
.Larc_compare_bad_no_fd:
    mov eax, 1
.Larc_compare_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Walk one directory without following links. Mode 0 compares the exact tree;
 * mode 1 removes a failed private stage. Each recursion owns its getdents buffer.
 * RDI fd, RSI prefix length in arc_scan_path, EDX mode. */
arc_walk_tree:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 4120
    mov r12, rdi
    mov r13, rsi
    mov [rsp + 4104], edx
.Larc_walk_read:
    mov eax, 217
    mov rdi, r12
    mov rsi, rsp
    mov edx, 4096
    syscall
    cmp rax, -4
    je .Larc_walk_read
    test rax, rax
    js .Larc_walk_bad
    jz .Larc_walk_ok
    mov r14, rax
    xor r15d, r15d
.Larc_walk_entry:
    cmp r15, r14
    jae .Larc_walk_read
    lea rbx, [rsp + r15]
    lea rax, [r15 + 20]
    cmp rax, r14
    ja .Larc_walk_bad
    movzx eax, word ptr [rbx + 16]
    cmp eax, 20
    jb .Larc_walk_bad
    lea rdx, [r15 + rax]
    cmp rdx, r14
    ja .Larc_walk_bad
    mov [rsp + 4096], eax
    lea rbx, [rbx + 19]
    sub eax, 19
    xor ecx, ecx
.Larc_walk_name:
    cmp ecx, eax
    jae .Larc_walk_bad
    cmp byte ptr [rbx + rcx], 0
    je .Larc_walk_name_end
    inc ecx
    jmp .Larc_walk_name
.Larc_walk_name_end:
    test ecx, ecx
    jz .Larc_walk_bad
    cmp word ptr [rbx], 0x002e
    je .Larc_walk_next
    cmp word ptr [rbx], 0x2e2e
    jne .Larc_walk_real_entry
    cmp byte ptr [rbx + 2], 0
    je .Larc_walk_next
.Larc_walk_real_entry:
    lea rbp, [r13 + rcx]
    cmp rbp, ARC_PATH
    ja .Larc_walk_bad
    lea rdi, [rip + arc_scan_path]
    add rdi, r13
    mov rsi, rbx
    inc ecx
    rep movsb
    mov eax, 257
    mov rdi, r12
    mov rsi, rbx
    mov edx, ARC_DIRECTORY
    xor r10d, r10d
    syscall
    test rax, rax
    js .Larc_walk_file
    mov [rsp + 4112], rax
    cmp dword ptr [rsp + 4104], 0
    jne .Larc_walk_directory_recurse
    mov esi, 1
    call arc_find_entry
    cmp rax, -2
    je .Larc_walk_directory_bad
    test rax, rax
    js .Larc_walk_directory_recurse
    lea rdx, [rip + arc_seen]
    mov byte ptr [rdx + rax], 1
.Larc_walk_directory_recurse:
    lea rdx, [rip + arc_scan_path]
    mov byte ptr [rdx + rbp], '/'
    mov byte ptr [rdx + rbp + 1], 0
    mov rdi, [rsp + 4112]
    lea rsi, [rbp + 1]
    mov edx, [rsp + 4104]
    call arc_walk_tree
    mov ebp, eax
    mov rdi, [rsp + 4112]
    call arc_close
    test ebp, ebp
    jnz .Larc_walk_bad
    cmp dword ptr [rsp + 4104], 0
    je .Larc_walk_next
    mov eax, 263
    mov rdi, r12
    mov rsi, rbx
    mov edx, 512
    syscall
    test rax, rax
    js .Larc_walk_bad
    jmp .Larc_walk_next
.Larc_walk_directory_bad:
    mov rdi, [rsp + 4112]
    call arc_close
    jmp .Larc_walk_bad
.Larc_walk_file:
    cmp dword ptr [rsp + 4104], 0
    je .Larc_walk_compare_file
    mov eax, 263
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx
    syscall
    test rax, rax
    js .Larc_walk_bad
    jmp .Larc_walk_next
.Larc_walk_compare_file:
    xor esi, esi
    call arc_find_entry
    test rax, rax
    js .Larc_walk_bad
    mov r8, rax
    mov rdi, r12
    mov rsi, rbx
    call arc_compare_file
    test eax, eax
    jnz .Larc_walk_bad
.Larc_walk_next:
    lea rdx, [rip + arc_scan_path]
    mov byte ptr [rdx + r13], 0
    mov eax, [rsp + 4096]
    add r15, rax
    jmp .Larc_walk_entry
.Larc_walk_ok:
    xor eax, eax
    jmp .Larc_walk_return
.Larc_walk_bad:
    mov eax, 1
.Larc_walk_return:
    add rsp, 4120
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

.section .rodata
arc_gzip: .asciz "/usr/bin/gzip"
arc_gzip_d: .asciz "-d"
arc_gzip_c: .asciz "-c"
arc_dot: .asciz "."
arc_slash: .asciz "/"
arc_hex: .ascii "0123456789abcdef"
.balign 8
arc_gzip_argv: .quad arc_gzip, arc_gzip_d, arc_gzip_c, 0
arc_empty_env: .quad 0
.section .data
arc_stage_name: .ascii ".asm-stage-"
    .zero 34
.section .bss
.balign 16
arc_input_path: .skip 8
arc_output_path: .skip 8
arc_parent_fd: .skip 8
arc_root_fd: .skip 8
arc_raw_size: .skip 8
arc_entry_count: .skip 8
arc_file_count: .skip 8
arc_operation: .skip 4
arc_result: .skip 4
arc_child_status: .skip 4
arc_pipe: .skip 8
arc_stage_created: .skip 1
arc_random: .skip 16
arc_stat: .skip 144
arc_output_copy: .skip 4096
arc_destination_leaf: .skip 256
arc_member_copy: .skip 256
arc_scan_path: .skip 256
arc_seen: .skip ARC_COUNT
.balign 16
arc_entries: .skip ARC_COUNT * 32
arc_paths: .skip ARC_COUNT * 256
arc_compare_buffer: .skip 65536
arc_data: .skip ARC_LIMIT + 1
.section .note.GNU-stack,"",@progbits
