/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux x86-64 SysV. Fixed-key, non-serving configuration preparation.
 * All filesystem authority uses pinned directory descriptors. Trusted path
 * ancestors and same-UID writers remain outside this coordination boundary.
 * Raw Linux syscalls return signed long errors; close is never retried.
 */
.intel_syntax noprefix
.equ PREP_PATH_LIMIT, 1024
.equ PREP_FILE_LIMIT, 4096
.equ PREP_READ_CAPACITY, 4097
.equ PREP_RETRY_LIMIT, 16
.equ PREP_DIRECTORY_FLAGS, 0xb0000
.equ PREP_SOURCE_FLAGS, 0x80800
.equ PREP_EXISTING_FLAGS, 0xa0800
.equ PREP_TEMP_FLAGS, 0xa00c1
.equ PREP_RESOLVE_FLAGS, 11
.equ PREP_SOURCE_BUFFER, 0
.equ PREP_COMPARE_BUFFER, 4104
.equ PREP_STAT_BUFFER, 8208
.equ PREP_STATFS_BUFFER, 8368
.equ PREP_TEMP_NAME, 8488
.equ PREP_RANDOM_BYTES, 8536
.equ PREP_OPEN_HOW, 8552
.equ PREP_SOURCE_FD, 8576
.equ PREP_TEMP_FD, 8584
.equ PREP_TEMP_OWNED, 8592
.equ PREP_LENGTH, 8600
.equ PREP_DEST_PATH, 8608
.equ PREP_RETURN, 8616
.equ PREP_NAME_TRIES, 8624
.equ PREP_CREATED, 8632
.equ PREP_AFTER_RENAME, 8640
.equ PREP_FRAME, 8648

.section .rodata
prep_key: .asciz "database.url"
prep_private: .asciz "private"
prep_prefix: .ascii ".asm-config-"
prep_hex: .ascii "0123456789abcdef"

.section .text
.globl prepare_config
.type prepare_config,@function
/* RDI/RSI: borrowed absolute source/destination directory strings, <=1024.
 * EAX: 0 success, 78 refusal. No environment, DNS, database, or HTTP access.
 * Preserves all SysV callee-saved registers. Stack: 8648 owned bytes plus
 * six register saves (8696 bytes total); 16-byte alignment at every call.
 * Two separate 4097-byte buffers hold source and comparison bytes. Local
 * stat[160], statfs[120], open_how[24], random[16], and name[48] are bounded.
 * R12D/R13D retain real UID/GID for the private metadata helpers. R14/R15/RBX
 * retain pinned source root, destination root, and private child descriptors.
 */
prepare_config:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, PREP_FRAME
    mov [rsp + PREP_DEST_PATH], rsi
    mov r14, -1
    mov r15, -1
    mov rbx, -1
    mov qword ptr [rsp + PREP_SOURCE_FD], -1
    mov qword ptr [rsp + PREP_TEMP_FD], -1
    mov qword ptr [rsp + PREP_TEMP_OWNED], 0
    mov qword ptr [rsp + PREP_RETURN], 78
    mov qword ptr [rsp + PREP_AFTER_RENAME], 0
    /* Validate both borrowed strings before changing the filesystem. */
    call prep_directory_argument
    test eax, eax
    jz .Lprep_cleanup
    mov rsi, rdi
    mov eax, 257                 /* openat(AT_FDCWD, source, flags) */
    mov edi, -100
    mov edx, PREP_DIRECTORY_FLAGS
    xor r10d, r10d
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov r14, rax
    mov rdi, [rsp + PREP_DEST_PATH]
    call prep_directory_argument
    test eax, eax
    jz .Lprep_cleanup
    /* Read real/effective identities directly; no privileged mode exists. */
    mov eax, 102                 /* getuid */
    syscall
    test eax, eax
    jz .Lprep_cleanup
    mov r12d, eax
    mov eax, 107                 /* geteuid */
    syscall
    cmp eax, r12d
    jne .Lprep_cleanup
    mov eax, 104                 /* getgid */
    syscall
    test eax, eax
    jz .Lprep_cleanup
    mov r13d, eax
    mov eax, 108                 /* getegid */
    syscall
    cmp eax, r13d
    jne .Lprep_cleanup
    mov eax, 257
    mov edi, -100
    mov rsi, [rsp + PREP_DEST_PATH]
    mov edx, PREP_DIRECTORY_FLAGS
    xor r10d, r10d
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov r15, rax
    mov rdi, r14
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_root_metadata
    test eax, eax
    jz .Lprep_cleanup
    test dword ptr [rsp + PREP_STAT_BUFFER + 24], 0x10 /* group write */
    jz .Lprep_source_mount_ok
    mov eax, 138                 /* fstatfs */
    mov rdi, r14
    lea rsi, [rsp + PREP_STATFS_BUFFER]
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    test qword ptr [rsp + PREP_STATFS_BUFFER + 80], 1 /* ST_RDONLY */
    jz .Lprep_cleanup
.Lprep_source_mount_ok:
    mov rdi, r15
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_root_metadata
    test eax, eax
    jz .Lprep_cleanup
    /* Follow ordinary projection links, confined to the pinned root/mount. */
    mov qword ptr [rsp + PREP_OPEN_HOW], PREP_SOURCE_FLAGS
    mov qword ptr [rsp + PREP_OPEN_HOW + 8], 0
    mov qword ptr [rsp + PREP_OPEN_HOW + 16], PREP_RESOLVE_FLAGS
    mov eax, 437                 /* openat2; no fallback */
    mov rdi, r14
    lea rsi, [rip + prep_key]
    lea rdx, [rsp + PREP_OPEN_HOW]
    mov r10d, 24
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov [rsp + PREP_SOURCE_FD], rax
    mov rdi, rax
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_source_metadata
    test eax, eax
    jz .Lprep_cleanup
    mov rax, [rsp + PREP_STAT_BUFFER + 48]
    test rax, rax
    jle .Lprep_cleanup
    cmp rax, PREP_FILE_LIMIT
    ja .Lprep_cleanup
    mov rdi, [rsp + PREP_SOURCE_FD]
    lea rsi, [rsp + PREP_SOURCE_BUFFER]
    mov edx, PREP_READ_CAPACITY
    call prep_read_file
    test rax, rax
    jle .Lprep_cleanup
    mov [rsp + PREP_LENGTH], rax
    mov rcx, rax
    cmp byte ptr [rsp + PREP_SOURCE_BUFFER + rcx - 1], 10
    jne .Lprep_validate_start
    dec rcx
    jz .Lprep_cleanup
.Lprep_validate_start:
    xor edx, edx
.Lprep_validate_byte:
    cmp rdx, rcx
    jae .Lprep_content_valid
    movzx eax, byte ptr [rsp + PREP_SOURCE_BUFFER + rdx]
    cmp eax, 32
    jb .Lprep_cleanup
    cmp eax, 126
    ja .Lprep_cleanup
    inc rdx
    jmp .Lprep_validate_byte
.Lprep_content_valid:
    mov eax, 3                   /* close: Linux releases even on EINTR */
    mov rdi, [rsp + PREP_SOURCE_FD]
    syscall
    mov qword ptr [rsp + PREP_SOURCE_FD], -1
    cmp rax, -4
    je .Lprep_source_closed
    test rax, rax
    js .Lprep_cleanup
.Lprep_source_closed:
    mov qword ptr [rsp + PREP_CREATED], 0
    mov eax, 258                 /* mkdirat */
    mov rdi, r15
    lea rsi, [rip + prep_private]
    mov edx, 0x1c0               /* 0700, before umask */
    call prep_syscall
    test rax, rax
    jz .Lprep_private_created
    cmp rax, -17                 /* EEXIST never grants permission */
    jne .Lprep_cleanup
    jmp .Lprep_private_open
.Lprep_private_created:
    mov qword ptr [rsp + PREP_CREATED], 1
.Lprep_private_open:
    mov eax, 257
    mov rdi, r15
    lea rsi, [rip + prep_private]
    mov edx, PREP_DIRECTORY_FLAGS
    xor r10d, r10d
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov rbx, rax
    mov eax, 5
    mov rdi, rbx
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    cmp dword ptr [rsp + PREP_STAT_BUFFER + 28], r12d
    jne .Lprep_cleanup
    mov eax, [rsp + PREP_STAT_BUFFER + 24]
    and eax, 0xf000
    cmp eax, 0x4000
    jne .Lprep_cleanup
    cmp qword ptr [rsp + PREP_CREATED], 0
    je .Lprep_private_verify
    /* A new child can inherit SGID or a restrictive umask. Own it first. */
    mov eax, 91                  /* fchmod */
    mov rdi, rbx
    mov esi, 0x1c0
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov eax, 5
    mov rdi, rbx
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
.Lprep_private_verify:
    cmp dword ptr [rsp + PREP_STAT_BUFFER + 28], r12d
    jne .Lprep_cleanup
    mov eax, [rsp + PREP_STAT_BUFFER + 24]
    and eax, 0xffff
    cmp eax, 0x41c0              /* directory, exact 0700, no special bits */
    jne .Lprep_cleanup
.Lprep_open_existing:
    mov eax, 257
    mov rdi, rbx
    lea rsi, [rip + prep_key]
    mov edx, PREP_EXISTING_FLAGS
    xor r10d, r10d
    call prep_syscall
    test rax, rax
    jns .Lprep_compare_existing
    cmp rax, -2                  /* ENOENT */
    jne .Lprep_cleanup
    cmp qword ptr [rsp + PREP_AFTER_RENAME], 0
    jne .Lprep_cleanup
    jmp .Lprep_create_temporary
.Lprep_compare_existing:
    mov [rsp + PREP_SOURCE_FD], rax
    mov rdi, rax
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_target_metadata
    test eax, eax
    jz .Lprep_cleanup
    mov rax, [rsp + PREP_LENGTH]
    cmp [rsp + PREP_STAT_BUFFER + 48], rax
    jne .Lprep_cleanup
    mov rdi, [rsp + PREP_SOURCE_FD]
    lea rsi, [rsp + PREP_COMPARE_BUFFER]
    mov edx, PREP_READ_CAPACITY
    call prep_read_file
    cmp rax, [rsp + PREP_LENGTH]
    jne .Lprep_cleanup
    mov rcx, rax
    lea rsi, [rsp + PREP_SOURCE_BUFFER]
    lea rdi, [rsp + PREP_COMPARE_BUFFER]
    repe cmpsb
    jne .Lprep_cleanup
    jmp .Lprep_success
.Lprep_create_temporary:
    mov qword ptr [rsp + PREP_NAME_TRIES], PREP_RETRY_LIMIT
.Lprep_temporary_attempt:
    /* 128 fresh random bits become a fixed 44-byte relative name. */
    xor r8d, r8d
.Lprep_random_more:
    mov eax, 318                 /* getrandom, blocking secure source */
    lea rdi, [rsp + PREP_RANDOM_BYTES + r8]
    mov esi, 16
    sub rsi, r8
    xor edx, edx
    call prep_syscall
    test rax, rax
    jle .Lprep_cleanup
    add r8, rax
    cmp r8, 16
    jb .Lprep_random_more
    jne .Lprep_cleanup
    lea rsi, [rip + prep_prefix]
    lea rdi, [rsp + PREP_TEMP_NAME]
    mov ecx, 12
    rep movsb
    lea rsi, [rip + prep_hex]
    xor ecx, ecx
.Lprep_hex_byte:
    movzx eax, byte ptr [rsp + PREP_RANDOM_BYTES + rcx]
    mov edx, eax
    shr eax, 4
    and edx, 15
    mov al, [rsi + rax]
    mov dl, [rsi + rdx]
    mov [rsp + PREP_TEMP_NAME + rcx * 2 + 12], al
    mov [rsp + PREP_TEMP_NAME + rcx * 2 + 13], dl
    inc ecx
    cmp ecx, 16
    jb .Lprep_hex_byte
    mov byte ptr [rsp + PREP_TEMP_NAME + 44], 0
    mov eax, 257
    mov rdi, rbx
    lea rsi, [rsp + PREP_TEMP_NAME]
    mov edx, PREP_TEMP_FLAGS
    mov r10d, 0x180              /* 0600 */
    call prep_syscall
    test rax, rax
    jns .Lprep_temporary_owned
    cmp rax, -17
    jne .Lprep_cleanup
    dec qword ptr [rsp + PREP_NAME_TRIES]
    jnz .Lprep_temporary_attempt
    jmp .Lprep_cleanup
.Lprep_temporary_owned:
    mov [rsp + PREP_TEMP_FD], rax
    mov qword ptr [rsp + PREP_TEMP_OWNED], 1
    mov rdi, rax
    mov eax, 91
    mov esi, 0x180
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov rdi, [rsp + PREP_TEMP_FD]
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_target_metadata
    test eax, eax
    jz .Lprep_cleanup
    cmp qword ptr [rsp + PREP_STAT_BUFFER + 48], 0
    jne .Lprep_cleanup
    xor r8d, r8d
.Lprep_write_more:
    cmp r8, [rsp + PREP_LENGTH]
    jae .Lprep_sync
    mov eax, 1
    mov rdi, [rsp + PREP_TEMP_FD]
    lea rsi, [rsp + PREP_SOURCE_BUFFER + r8]
    mov rdx, [rsp + PREP_LENGTH]
    sub rdx, r8
    call prep_syscall
    test rax, rax
    jle .Lprep_cleanup
    add r8, rax
    jmp .Lprep_write_more
.Lprep_sync:
    mov eax, 74                  /* fsync before visibility */
    mov rdi, [rsp + PREP_TEMP_FD]
    call prep_syscall
    test rax, rax
    js .Lprep_cleanup
    mov rdi, [rsp + PREP_TEMP_FD]
    lea rsi, [rsp + PREP_STAT_BUFFER]
    call prep_target_metadata
    test eax, eax
    jz .Lprep_cleanup
    mov rax, [rsp + PREP_LENGTH]
    cmp [rsp + PREP_STAT_BUFFER + 48], rax
    jne .Lprep_cleanup
    mov eax, 3
    mov rdi, [rsp + PREP_TEMP_FD]
    syscall
    mov qword ptr [rsp + PREP_TEMP_FD], -1
    cmp rax, -4
    je .Lprep_publish
    test rax, rax
    js .Lprep_cleanup
.Lprep_publish:
    mov eax, 316                 /* renameat2(RENAME_NOREPLACE) */
    mov rdi, rbx
    lea rsi, [rsp + PREP_TEMP_NAME]
    mov rdx, rbx
    lea r10, [rip + prep_key]
    mov r8d, 1
    call prep_syscall
    test rax, rax
    jz .Lprep_published
    cmp rax, -17
    jne .Lprep_cleanup
    mov qword ptr [rsp + PREP_AFTER_RENAME], 1
    jmp .Lprep_open_existing      /* concurrent identical publication is a no-op */
.Lprep_published:
    mov qword ptr [rsp + PREP_TEMP_OWNED], 0
.Lprep_success:
    mov qword ptr [rsp + PREP_RETURN], 0
.Lprep_cleanup:
    mov rdi, [rsp + PREP_TEMP_FD]
    test rdi, rdi
    js .Lprep_cleanup_source
    mov eax, 3
    syscall
.Lprep_cleanup_source:
    mov rdi, [rsp + PREP_SOURCE_FD]
    test rdi, rdi
    js .Lprep_cleanup_name
    mov eax, 3
    syscall
.Lprep_cleanup_name:
    cmp qword ptr [rsp + PREP_TEMP_OWNED], 0
    je .Lprep_cleanup_private
    mov eax, 263                 /* unlinkat only this invocation's name */
    mov rdi, rbx
    lea rsi, [rsp + PREP_TEMP_NAME]
    xor edx, edx
    call prep_syscall
    test rax, rax
    jns .Lprep_cleanup_private
    cmp rax, -2
    je .Lprep_cleanup_private
    mov qword ptr [rsp + PREP_RETURN], 78
.Lprep_cleanup_private:
    mov rdi, rbx
    test rdi, rdi
    js .Lprep_cleanup_destination
    mov eax, 3
    syscall
.Lprep_cleanup_destination:
    mov rdi, r15
    test rdi, rdi
    js .Lprep_cleanup_root
    mov eax, 3
    syscall
.Lprep_cleanup_root:
    mov rdi, r14
    test rdi, rdi
    js .Lprep_return
    mov eax, 3
    syscall
.Lprep_return:
    mov eax, [rsp + PREP_RETURN]
    add rsp, PREP_FRAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.size prepare_config,.-prepare_config

.type prep_directory_argument,@function
/* RDI borrowed string. EAX=1/0. Caller-saved changes, no stack. Reads at
 * most 1025 bytes. Keeps RDI unchanged; rejects disguised final symlinks. */
prep_directory_argument:
    test rdi, rdi
    jz .Lprep_argument_bad
    cmp byte ptr [rdi], '/'
    jne .Lprep_argument_bad
    xor ecx, ecx
.Lprep_argument_scan:
    cmp ecx, PREP_PATH_LIMIT
    ja .Lprep_argument_bad
    cmp byte ptr [rdi + rcx], 0
    je .Lprep_argument_end
    inc ecx
    jmp .Lprep_argument_scan
.Lprep_argument_end:
    cmp ecx, 1
    je .Lprep_argument_ok
    cmp byte ptr [rdi + rcx - 1], '/'
    je .Lprep_argument_bad
    cmp byte ptr [rdi + rcx - 1], '.'
    jne .Lprep_argument_ok
    cmp byte ptr [rdi + rcx - 2], '/'
    je .Lprep_argument_bad
    cmp byte ptr [rdi + rcx - 2], '.'
    jne .Lprep_argument_ok
    cmp ecx, 3
    jb .Lprep_argument_ok
    cmp byte ptr [rdi + rcx - 3], '/'
    je .Lprep_argument_bad
.Lprep_argument_ok:
    mov eax, 1
    ret
.Lprep_argument_bad:
    xor eax, eax
    ret
.size prep_directory_argument,.-prep_directory_argument

.type prep_syscall,@function
/* RAX raw syscall number; Linux args RDI/RSI/RDX/R10/R8/R9. Returns raw
 * signed RAX; retries EINTR at most 16 total attempts. Preserves arguments
 * and all callee-saved registers; changes RAX/RCX/R11, stack 32 bytes.
 * Do not call for close: Linux may release its descriptor before EINTR. */
prep_syscall:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    mov [rsp], rax
    mov ebx, PREP_RETRY_LIMIT
.Lprep_syscall_again:
    mov rax, [rsp]
    syscall
    cmp rax, -4
    jne .Lprep_syscall_return
    dec ebx
    jnz .Lprep_syscall_again
.Lprep_syscall_return:
    add rsp, 8
    pop rbx
    pop rbp
    ret
.size prep_syscall,.-prep_syscall

.type prep_root_metadata,@function
/* RDI descriptor, RSI owned stat[160], R12D UID/R13D GID. EAX=1/0.
 * Verifies directory, root/current owner, selected group, no other-write.
 * Preserves callee-saved; changes raw syscall caller-saved, stack 8. */
prep_root_metadata:
    sub rsp, 8
    mov eax, 5
    call prep_syscall
    add rsp, 8
    test rax, rax
    js .Lprep_metadata_bad
    mov eax, [rsi + 24]
    mov edx, eax
    and eax, 0xf000
    cmp eax, 0x4000
    jne .Lprep_metadata_bad
    test edx, 2
    jnz .Lprep_metadata_bad
    cmp dword ptr [rsi + 32], r13d
    jne .Lprep_metadata_bad
    mov eax, [rsi + 28]
    test eax, eax
    jz .Lprep_metadata_ok
    cmp eax, r12d
    jne .Lprep_metadata_bad
    jmp .Lprep_metadata_ok
.size prep_root_metadata,.-prep_root_metadata

.type prep_source_metadata,@function
/* RDI descriptor, RSI stat[160], private UID/GID context. EAX=1/0.
 * Requires regular, nlink1, root/current UID, selected GID, permissions
 * restricted to 0640, with at least one read bit. Stack 8; saves preserved. */
prep_source_metadata:
    sub rsp, 8
    mov eax, 5
    call prep_syscall
    add rsp, 8
    test rax, rax
    js .Lprep_metadata_bad
    mov eax, [rsi + 24]
    mov edx, eax
    and eax, 0xf000
    cmp eax, 0x8000
    jne .Lprep_metadata_bad
    and edx, 0xfff
    test edx, 0xe5f              /* every permission outside 0640 */
    jnz .Lprep_metadata_bad
    test edx, 0x120              /* at least owner/group read */
    jz .Lprep_metadata_bad
    cmp qword ptr [rsi + 16], 1
    jne .Lprep_metadata_bad
    cmp dword ptr [rsi + 32], r13d
    jne .Lprep_metadata_bad
    mov eax, [rsi + 28]
    test eax, eax
    jz .Lprep_metadata_ok
    cmp eax, r12d
    jne .Lprep_metadata_bad
    jmp .Lprep_metadata_ok
.size prep_source_metadata,.-prep_source_metadata

.type prep_target_metadata,@function
/* RDI descriptor, RSI stat[160], private UID/GID context. EAX=1/0.
 * Requires current UID, selected GID, single-link regular, exact0600.
 * Does not interpret size; caller compares it. Stack 8; saves preserved. */
prep_target_metadata:
    sub rsp, 8
    mov eax, 5
    call prep_syscall
    add rsp, 8
    test rax, rax
    js .Lprep_metadata_bad
    mov eax, [rsi + 24]
    and eax, 0xffff
    cmp eax, 0x8180
    jne .Lprep_metadata_bad
    cmp qword ptr [rsi + 16], 1
    jne .Lprep_metadata_bad
    cmp dword ptr [rsi + 28], r12d
    jne .Lprep_metadata_bad
    cmp dword ptr [rsi + 32], r13d
    jne .Lprep_metadata_bad
.Lprep_metadata_ok:
    mov eax, 1
    ret
.Lprep_metadata_bad:
    xor eax, eax
    ret
.size prep_target_metadata,.-prep_target_metadata

.type prep_read_file,@function
/* RDI fd, RSI owned buffer, RDX capacity4097. RAX byte count0..4096 or-1.
 * Reads through EOF; exactly-full capacity is rejected. Short reads and
 * bounded EINTR are handled. Preserves callee-saved; changes caller-saved.
 * Stack 24 bytes; descriptor and buffer stay caller-owned. */
prep_read_file:
    push rbx
    push r14
    push r15
    mov rbx, rdi
    mov r14, rsi
    mov r15, rdx
    xor r8d, r8d
.Lprep_read_more:
    xor eax, eax
    mov rdi, rbx
    lea rsi, [r14 + r8]
    mov rdx, r15
    sub rdx, r8
    call prep_syscall
    test rax, rax
    js .Lprep_read_bad
    jz .Lprep_read_done
    add r8, rax
    cmp r8, r15
    jae .Lprep_read_bad
    jmp .Lprep_read_more
.Lprep_read_done:
    mov rax, r8
    jmp .Lprep_read_return
.Lprep_read_bad:
    mov rax, -1
.Lprep_read_return:
    pop r15
    pop r14
    pop rbx
    ret
.size prep_read_file,.-prep_read_file

.section .note.GNU-stack,"",@progbits
