/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Managed Windows CLI state. Native runtime only; build codecs are not used.
 */
.intel_syntax noprefix
.text
/* BEGIN RECORD PARSER */
/* RDI=borrowed record bytes, RSI=exact length. RAX=0/-22.
 * Input is not modified. At most256 bytes are copied to owned scratch[257].
 * Success sets wm_fields[6] and wm_record_size. Fields borrow scratch until
 * the next parse. Preserves callee-saved registers; WFRAME stack<=528 bytes.
 * No filesystem operations and no execution occur. */
win_managed_parse_record:
    WFRAME
    cmp rsi, 256
    ja .Lwm_parse_bad
    cmp rsi, 21
    jbe .Lwm_parse_bad
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + wm_record_scratch]
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + wm_record_scratch]
    lea rsi, [rip + wm_record_header]
    mov ecx, 21
    repe cmpsb
    jne .Lwm_parse_bad
    lea rbx, [rip + wm_fields]
    mov [rbx], rdi
    xor r14d, r14d
    lea r15, [rip + wm_record_scratch]
    add r15, r13
    dec r15
    cmp byte ptr [r15], 10
    jne .Lwm_parse_bad
    mov byte ptr [r15], 0
.Lwm_parse_byte:
    cmp rdi, r15
    je .Lwm_parse_fields
    movzx eax, byte ptr [rdi]
    cmp eax, 9
    je .Lwm_parse_tab
    cmp eax, 33
    jb .Lwm_parse_bad
    cmp eax, 126
    ja .Lwm_parse_bad
    inc rdi
    jmp .Lwm_parse_byte
.Lwm_parse_tab:
    cmp r14d, 5
    jae .Lwm_parse_bad
    mov byte ptr [rdi], 0
    inc r14d
    inc rdi
    mov [rbx + r14*8], rdi
    jmp .Lwm_parse_byte
.Lwm_parse_fields:
    cmp r14d, 5
    jne .Lwm_parse_bad
    mov rdi, [rbx]
    call strlen
    cmp rax, 32
    ja .Lwm_parse_bad
    mov rdi, [rbx]
    call registry_valid_version
    test eax, eax
    jz .Lwm_parse_bad
    mov rdi, [rbx + 8]
    lea rsi, [rip + registry_host]
    call streq
    test eax, eax
    jz .Lwm_parse_bad
    mov rdi, [rbx + 16]
    call registry_size_value
    test rax, rax
    jz .Lwm_parse_bad
    mov [rip + wm_record_size], rax
    mov rdi, [rbx + 24]
    call win_managed_digest
    test eax, eax
    jnz .Lwm_parse_bad
    mov rdi, [rbx + 32]
    cmp word ptr [rdi], 49
    jne .Lwm_parse_bad
    mov rdi, [rbx + 40]
    call strlen
    cmp rax, 32
    ja .Lwm_parse_bad
    mov rdi, [rbx + 40]
    call registry_valid_version
    test eax, eax
    jz .Lwm_parse_bad
    xor eax, eax
    WLEAVE
.Lwm_parse_bad:
    mov rax, -22
    WLEAVE
/* RDI=terminated digest. EAX=0/-22; bounded65-byte read. */
win_managed_digest:
    xor ecx, ecx
.Lwm_digest_byte:
    mov al, [rdi + rcx]
    cmp al, '0'
    jb .Lwm_digest_bad
    cmp al, '9'
    jbe .Lwm_digest_next
    cmp al, 'a'
    jb .Lwm_digest_bad
    cmp al, 'f'
    ja .Lwm_digest_bad
.Lwm_digest_next:
    inc ecx
    cmp ecx, 64
    jb .Lwm_digest_byte
    cmp byte ptr [rdi + 64], 0
    jne .Lwm_digest_bad
    xor eax, eax
    ret
.Lwm_digest_bad:
    mov eax, -22
    ret
.section .rdata,"dr"
wm_record_header: .ascii "# asm-cli-current-v1\n"
.section .bss
.p2align 3
wm_fields: .space 48
wm_record_size: .space 8
wm_record_scratch: .space 257
/* END RECORD PARSER */
.text
/* RDI/RSI=terminated UTF8 paths<=4095. EAX=1 iff ordinal case-insensitive
 * Windows comparison agrees. Owned UTF16 buffers[4096] each. No path opens. */
win_managed_equal:
    WFRAME
    mov r12, rsi
    lea rsi, [rip + wm_equal_a]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwm_equal_bad
    mov rdi, r12
    lea rsi, [rip + wm_equal_b]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwm_equal_bad
    lea rcx, [rip + wm_equal_a]
    mov edx, -1
    lea r8, [rip + wm_equal_b]
    mov r9d, -1
    mov dword ptr [rsp + 32], 1
    call CompareStringOrdinal
    cmp eax, 2
    sete al
    movzx eax, al
    WLEAVE
.Lwm_equal_bad:
    xor eax, eax
    WLEAVE
/* RDI=borrowed fd, RSI=owned path[4096]. RAX=0/-22. Canonical handle path
 * expands short names. Accept only local DOS drive paths; no UNC/devices. */
win_managed_fd_path:
    WFRAME
    mov r12, rsi
    call win_handle
    mov rcx, rax
    lea rdx, [rip + wm_final_wide]
    mov r8d, 4096
    xor r9d, r9d
    call GetFinalPathNameByHandleW
    test eax, eax
    jz .Lwm_fd_path_bad
    cmp eax, 4096
    jae .Lwm_fd_path_bad
    lea rdi, [rip + wm_final_wide]
    /* Local normalized output must start \\?\. */
    cmp word ptr [rdi], '\\'
    jne .Lwm_fd_path_bad
    cmp word ptr [rdi + 2], '\\'
    jne .Lwm_fd_path_bad
    cmp word ptr [rdi + 4], '?'
    jne .Lwm_fd_path_bad
    cmp word ptr [rdi + 6], '\\'
    jne .Lwm_fd_path_bad
    add rdi, 8
    mov rsi, r12
    mov edx, 4095
    call win_utf8
    test rax, rax
    js .Lwm_fd_path_bad
    mov rdi, r12
    call win_normalize_path
    test rax, rax
    js .Lwm_fd_path_bad
    xor eax, eax
    WLEAVE
.Lwm_fd_path_bad:
    mov rax, -22
    WLEAVE
/* RDI=owned mutable normalized path. EAX=0 standalone,1 launcher,2 payload.
 * RDX=root bin prefix length for managed roles. ASCII reserved components
 * compare without case; actual path identity uses held handles. A malformed
 * digest-shaped payload path still has role2 and fails subsequent validation.
 * Preserves callee-saved registers. WFRAME; path read bounded4095. */
win_managed_path_role:
    WFRAME
    mov r12, rdi
    call strlen
    mov r13, rax
    cmp r13, 19
    jb .Lwm_role_none
    lea rdi, [r12 + r13 - 19]
    lea rsi, [rip + wm_root_suffix]
    call win_managed_ascii_equal
    test eax, eax
    jnz .Lwm_role_root
    cmp r13, 102
    jb .Lwm_role_none
    lea rdi, [r12 + r13 - 8]
    lea rsi, [rip + wm_exe_suffix]
    call win_managed_ascii_equal
    test eax, eax
    jz .Lwm_role_none
    lea r14, [r12 + r13 - 91]
    mov al, [r14 + 19]
    mov [rbp - 128], al
    mov byte ptr [r14 + 19], 0
    mov rdi, r14
    lea rsi, [rip + wm_versions_suffix]
    call win_managed_ascii_equal
    mov dl, [rbp - 128]
    mov [r14 + 19], dl
    test eax, eax
    jz .Lwm_role_none
    mov al, [r14]
    mov [rbp - 128], al
    mov byte ptr [r14], 0
    lea rdi, [r14 - 11]
    lea rsi, [rip + wm_bin_suffix]
    call win_managed_ascii_equal
    mov dl, [rbp - 128]
    mov [r14], dl
    test eax, eax
    jz .Lwm_role_none
    mov eax, 2
    lea rdx, [r13 - 91]
    mov [rbp - 64], rdx /* WLEAVE returns this explicit secondary output */
    WLEAVE
.Lwm_role_root:
    mov eax, 1
    lea rdx, [r13 - 8]
    mov [rbp - 64], rdx
    WLEAVE
.Lwm_role_none:
    xor eax, eax
    WLEAVE
/* RDI/RSI=terminated ASCII reserved suffixes. EAX=1/0; RAX/RCX/RDX scratch. */
win_managed_ascii_equal:
    xor ecx, ecx
.Lwm_ascii_next:
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx]
    test al, al
    jz .Lwm_ascii_end
    or al, 32
    or dl, 32
    cmp al, dl
    jne .Lwm_ascii_bad
    inc ecx
    jmp .Lwm_ascii_next
.Lwm_ascii_end:
    test dl, dl
    setz al
    movzx eax, al
    ret
.Lwm_ascii_bad:
    xor eax, eax
    ret
/* RDI=owned fd, RSI=context slot0..8, EDX=directory boolean. RAX=0/-13.
 * Takes ownership immediately, before checking. Saves volume/file identity.
 * Every managed object is private and user-owned; regular files single-link.
 * Failure cleanup owns the slot. wm_stat[144] is reusable scratch. */
win_managed_hold:
    WFRAME
    mov r12, rsi
    mov r13d, edx
    lea rax, [rip + wm_fds]
    mov [rax + r12*8], rdi
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js .Lwm_hold_bad
    lea rdi, [rip + wm_stat]
    test r13d, r13d
    jnz .Lwm_hold_dir
    call self_check_file_stat
    test eax, eax
    jz .Lwm_hold_bad
    jmp .Lwm_hold_identity
.Lwm_hold_dir:
    mov eax, [rip + wm_stat + 28]
    cmp eax, [rip + self_uid]
    jne .Lwm_hold_bad
    mov eax, [rip + wm_stat + 24]
    test eax, 18
    jnz .Lwm_hold_bad
    and eax, 61440
    cmp eax, 16384
    jne .Lwm_hold_bad
.Lwm_hold_identity:
    shl r12, 4
    lea rdi, [rip + wm_ids]
    mov rax, [rip + wm_stat]
    mov [rdi + r12], rax
    mov rax, [rip + wm_stat + 8]
    mov [rdi + r12 + 8], rax
    xor eax, eax
    WLEAVE
.Lwm_hold_bad:
    mov rax, -13
    WLEAVE
/* RDI=dirfd,RSI=component,EDX=slot,R10D=directory boolean.
 * RAX=0/-errno; owns the opened descriptor even on stat failure. */
win_managed_open_slot:
    WFRAME
    mov r12d, edx
    mov r13d, r10d
    mov edx, 0x08000000
    test r13d, r13d
    jz 1f
    or edx, 65536
1:  cmp r12d, 4
    je 2f
    cmp r12d, 8
    jne 3f
2:  or edx, 0x02000000
3:  xor r10d, r10d
    call win_open
    test rax, rax
    js .Lwm_slot_done
    mov rdi, rax
    mov esi, r12d
    mov edx, r13d
    call win_managed_hold
.Lwm_slot_done:
    WLEAVE
/* Startup follows win_initialize. Managed errors honor a validated --json
 * argv token before normal option dispatch. Standalone retains its own bytes.
 * Every managed launch reads one held immutable record snapshot. */
win_managed_startup:
    WFRAME
    mov eax, 102
    call win_syscall
    mov [rip + self_uid], eax
    mov r12, [rip + argv]
    xor r13d, r13d
.Lwm_start_json:
    cmp r13, [rip + argc]
    jae .Lwm_start_path
    mov rdi, [r12 + r13*8]
    lea rsi, [rip + opt_json]
    call streq
    test eax, eax
    jz 1f
    mov byte ptr [rip + json_mode], 1
1:  inc r13
    jmp .Lwm_start_json
.Lwm_start_path:
    xor ecx, ecx
    lea rdx, [rip + wm_final_wide]
    mov r8d, 4096
    call GetModuleFileNameW
    test eax, eax
    jz win_managed_error
    cmp eax, 4096
    jae win_managed_error
    lea rdi, [rip + wm_final_wide]
    lea rsi, [rip + wm_exec_path]
    mov edx, 4095
    call win_utf8
    test rax, rax
    js win_managed_error
    lea rdi, [rip + wm_exec_path]
    call win_normalize_path
    test rax, rax
    js win_managed_error
    lea rdi, [rip + wm_exec_path]
    call win_managed_path_role
    mov [rip + wm_role], eax
    mov rdi, -100
    lea rsi, [rip + wm_exec_path]
    mov edx, 0x0a000000
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lwm_start_open_failed
    mov [rip + wm_exec_fd], rax
    mov rdi, rax
    lea rsi, [rip + wm_exec_path]
    call win_managed_fd_path
    test rax, rax
    js win_managed_error
    lea rdi, [rip + wm_exec_path]
    call win_managed_path_role
    mov [rip + wm_role], eax
    test eax, eax
    jnz .Lwm_start_managed
    lea rdi, [rip + wm_exec_path]
    call win_managed_reserved_spelling
    test eax, eax
    jnz win_managed_error
    jmp .Lwm_start_standalone
.Lwm_start_managed:
    cmp rdx, 3900
    ja win_managed_error
    mov r13, rdx
    lea rsi, [rip + wm_exec_path]
    lea rdi, [rip + wm_bin_path]
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + self_install_path]
    lea rsi, [rip + wm_bin_path]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + wm_exe_suffix]
    call copy_string
    lea rdi, [rip + wm_bin_path]
    sub r13, 11
    mov byte ptr [rdi + r13], 0
    lea rsi, [rip + win_home + 5]
    call win_managed_equal
    lea rdi, [rip + wm_bin_path]
    mov byte ptr [rdi + r13], '/'
    test eax, eax
    jz win_managed_home_error
    mov [rip + self_home_length], r13
    mov rdi, [rip + wm_exec_fd]
    xor esi, esi
    xor edx, edx
    call win_managed_hold
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_exec_fd]
    call win_handle
    mov rdi, rax
    call win_image_matches
    test rax, rax
    js win_managed_error
    call self_open_parent
    test rax, rax
    js win_managed_error
    mov rdi, rax
    mov esi, 1
    mov edx, 1
    call win_managed_hold
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_bin_fd]
    lea rsi, [rip + wm_store_name]
    mov edx, 2
    mov r10d, 1
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + wm_versions_name]
    mov edx, 3
    mov r10d, 1
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_bin_fd]
    lea rsi, [rip + self_binary_name]
    mov edx, 4
    xor r10d, r10d
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_launcher_fd]
    mov rsi, [rip + wm_stat + 48]
    lea rdx, [rip + wm_launcher_meta]
    call win_managed_pe
    test rax, rax
    js win_managed_error
    cmp dword ptr [rip + wm_role], 1
    jne .Lwm_start_marker
    mov rdi, [rip + wm_launcher_fd]
    call win_handle
    mov rdi, rax
    call win_image_matches
    test rax, rax
    js win_managed_error
.Lwm_start_marker:
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + wm_layout_name]
    mov edx, 5
    xor r10d, r10d
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    cmp qword ptr [rip + wm_stat + 48], 20
    jne win_managed_error
    mov rdi, [rip + wm_layout_fd]
    lea rsi, [rip + wm_record_bytes]
    mov edx, 20
    call elf_read_exact
    test rax, rax
    js win_managed_error
    lea rdi, [rip + wm_record_bytes]
    lea rsi, [rip + wm_layout_bytes]
    mov ecx, 20
    repe cmpsb
    jne win_managed_error
    mov rdi, [rip + wm_store_fd]
    lea rsi, [rip + wm_current_name]
    mov edx, 6
    xor r10d, r10d
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    mov rdx, [rip + wm_stat + 48]
    cmp rdx, 256
    ja win_managed_error
    test rdx, rdx
    jz win_managed_error
    mov [rip + wm_record_length], rdx
    mov rdi, [rip + wm_record_fd]
    lea rsi, [rip + wm_record_bytes]
    call elf_read_exact
    test rax, rax
    js win_managed_error
    lea rdi, [rip + wm_record_bytes]
    mov rsi, [rip + wm_record_length]
    call win_managed_parse_record
    test rax, rax
    js win_managed_error
    cmp dword ptr [rip + wm_role], 1
    jne .Lwm_snapshot_complete
    /* Native qualification can pause this launcher-only snapshot point.
     * The production label has no behavior. Volatile registers are dead. */
win_managed_snapshot_ready:
.Lwm_snapshot_complete:
    mov rdi, [rip + wm_versions_fd]
    mov rsi, [rip + wm_fields + 24]
    mov edx, 7
    mov r10d, 1
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_payload_dir_fd]
    lea rsi, [rip + self_binary_name]
    mov edx, 8
    xor r10d, r10d
    call win_managed_open_slot
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_payload_fd]
    mov rsi, [rip + wm_record_size]
    lea rdx, [rip + wm_hash]
    call win_hash_fd
    test eax, eax
    jnz win_managed_error
    lea rdi, [rip + wm_hash]
    mov rsi, [rip + wm_fields + 24]
    call streq
    test eax, eax
    jz win_managed_error
    mov rdi, [rip + wm_payload_fd]
    mov rsi, [rip + wm_record_size]
    lea rdx, [rip + wm_payload_meta]
    call win_managed_pe
    test rax, rax
    js win_managed_error
    lea rdi, [rip + wm_payload_meta]
    mov rsi, [rip + wm_fields]
    mov rdx, [rip + wm_fields + 40]
    call win_managed_metadata_record
    test rax, rax
    jnz win_managed_error
    lea rdi, [rip + wm_payload_meta]
    lea rsi, [rip + wm_launcher_meta]
    call win_managed_compatible
    test rax, rax
    jnz win_managed_compatibility_error
    cmp dword ptr [rip + wm_role], 1
    je .Lwm_start_launch
    /* Retained payloads remain usable after selection changes. Their own
     * digest-derived location and metadata must still validate independently. */
    mov rdi, -100
    lea rsi, [rip + wm_exec_path]
    call win_open_parent
    test rax, rax
    js win_managed_error
    mov r12, rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    call win_syscall
    or rax, r13
    js win_managed_error
    mov eax, [rip + wm_stat + 28]
    cmp eax, [rip + self_uid]
    jne win_managed_error
    test dword ptr [rip + wm_stat + 24], 18
    jnz win_managed_error
    lea rdi, [rip + wm_exec_path]
    call strlen
    lea r12, [rip + wm_exec_path]
    lea r13, [r12 + rax - 72]
    mov byte ptr [r13 + 64], 0
    mov rdi, r13
    call win_managed_digest
    mov byte ptr [r13 + 64], '/'
    test eax, eax
    jnz win_managed_error
    mov rdi, [rip + wm_exec_fd]
    mov rsi, -1
    lea rdx, [rip + wm_hash]
    call win_hash_fd
    test eax, eax
    jnz win_managed_error
    lea rdi, [rip + wm_hash]
    mov rsi, r13
    mov ecx, 64
    repe cmpsb
    jne win_managed_error
    mov rdi, [rip + wm_exec_fd]
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js win_managed_error
    mov rdi, [rip + wm_exec_fd]
    mov rsi, [rip + wm_stat + 48]
    lea rdx, [rip + wm_exec_meta]
    call win_managed_pe
    test rax, rax
    js win_managed_error
    xor eax, eax
    WLEAVE
.Lwm_start_launch:
    mov rdi, [rip + wm_payload_fd]
    lea rsi, [rip + wm_launch_path]
    call win_managed_fd_path
    test rax, rax
    js win_managed_error
    call win_managed_launch
    /* Launcher never falls through to its embedded CLI. */
    mov ecx, eax
    call ExitProcess
    ud2
.Lwm_start_open_failed:
    /* An inaccessible executing pathname cannot establish a standalone role.
     * In particular, a displaced short-name launcher must never fall back. */
    jmp win_managed_error
.Lwm_start_standalone:
    call win_managed_cleanup
    xor eax, eax
    WLEAVE
/* RDI=metadata64, RSI=canonical artifact version, RDX=minimum version.
 * RAX=0/-22. Compare all three integers without trusting record history. */
win_managed_metadata_record:
    WFRAME
    mov r12, rdi
    mov r13, rdx
    lea rdi, [r12 + 24]
    call win_managed_version_text
    test eax, eax
    jnz .Lwm_meta_record_bad
    lea rdi, [r12 + 36]
    mov rsi, r13
    call win_managed_version_text
    WLEAVE
.Lwm_meta_record_bad:
    mov rax, -22
    WLEAVE
/* RDI=three LE uint32, RSI=validated canonical version. RAX=0/-22.
 * Scratch caller-save. No allocations. */
win_managed_version_text:
    xor r8d, r8d
    xor ecx, ecx
.Lwm_version_component:
    xor edx, edx
.Lwm_version_digit:
    movzx eax, byte ptr [rsi + rcx]
    cmp al, '0'
    jb .Lwm_version_end_component
    cmp al, '9'
    ja .Lwm_version_end_component
    imul rdx, rdx, 10
    sub eax, '0'
    add rdx, rax
    inc ecx
    jmp .Lwm_version_digit
.Lwm_version_end_component:
    cmp edx, [rdi + r8*4]
    jne .Lwm_version_bad
    inc r8d
    inc ecx
    cmp r8d, 3
    jb .Lwm_version_component
    xor eax, eax
    ret
.Lwm_version_bad:
    mov rax, -22
    ret
/* RDI=payload metadata, RSI=actual held launcher metadata. RAX=0/-22.
 * Validated schema/protocol1 inputs; compare lexicographic minimum version. */
win_managed_compatible:
    xor ecx, ecx
.Lwm_compat_component:
    mov eax, [rsi + rcx + 24]
    cmp eax, [rdi + rcx + 36]
    ja .Lwm_compat_ok
    jb .Lwm_version_bad
    add ecx, 4
    cmp ecx, 12
    jb .Lwm_compat_component
.Lwm_compat_ok:
    xor eax, eax
    ret
/* Close all owned managed contexts. No return status can undo activation.
 * Descriptor slots are cleared before close. Preserves adapter inputs. */
win_managed_cleanup:
    WFRAME
    lea r12, [rip + wm_fds]
    mov r13d, 9
.Lwm_cleanup_next:
    mov rdi, [r12]
    mov qword ptr [r12], -1
    test rdi, rdi
    js 1f
    mov eax, 3
    call win_syscall
1:  add r12, 8
    dec r13d
    jnz .Lwm_cleanup_next
    WLEAVE
win_managed_home_error:
    lea rdi, [rip + wm_home_error]
    jmp .Lwm_error
win_managed_compatibility_error:
    lea rdi, [rip + wm_compat_error]
    jmp .Lwm_error
win_managed_error:
    lea rdi, [rip + wm_state_error]
.Lwm_error:
    push rdi
    call win_managed_cleanup
    pop rdi
    mov esi, 1
    jmp self_fail
.section .rdata,"dr"
wm_root_suffix: .asciz "/.local/bin/asm.exe"
wm_bin_suffix: .asciz "/.local/bin"
wm_exe_suffix: .asciz "/asm.exe"
wm_versions_suffix: .asciz "/.asm-cli/versions/"
wm_store_name: .asciz ".asm-cli"
wm_versions_name: .asciz "versions"
wm_layout_name: .asciz "layout"
wm_current_name: .asciz "current.tsv"
wm_layout_bytes: .ascii "# asm-cli-layout-v1\n"
wm_state_error: .asciz "the managed Asm installation is missing, changed, or invalid; repair it with the Windows installer"
wm_home_error: .asciz "HOME differs from this managed Asm installation; restore HOME or run the Windows installer for that home"
wm_compat_error: .asciz "the installed launcher cannot start this payload; close Asm processes and repair the launcher with the Windows installer"
.section .data
.p2align 3
wm_fds:
wm_exec_fd: .quad -1
wm_bin_fd: .quad -1
wm_store_fd: .quad -1
wm_versions_fd: .quad -1
wm_launcher_fd: .quad -1
wm_layout_fd: .quad -1
wm_record_fd: .quad -1
wm_payload_dir_fd: .quad -1
wm_payload_fd: .quad -1
.section .bss
.p2align 3
wm_ids: .space 144
wm_stat: .space 144
wm_role: .space 8
wm_record_length: .space 8
wm_record_bytes: .space 257
wm_exec_path: .space 4096
wm_bin_path: .space 4096
wm_launch_path: .space 4096
.p2align 1
wm_final_wide: .space 8192
wm_equal_a: .space 8192
wm_equal_b: .space 8192
wm_hash: .space 65
wm_launcher_meta: .space 64
wm_payload_meta: .space 64
wm_exec_meta: .space 64
.text
/* RDI=absolute destination/inventory path. EAX=0 allowed,1 reserved/error.
 * Traverse existing directory prefixes with no reparse traversal. Compare
 * held directory IDs with this process's managed store, and inspect each
 * canonical long name. This catches short-name aliases before missing leaves.
 * No files are created; every temporary descriptor closes. Scratch paths[4096].
 * Errors other than absent/non-directory components fail closed. */
win_managed_reserved_path:
    WFRAME
    call strlen
    cmp rax, 4093
    ja .Lwmg_reserved
    mov rsi, rdi
    lea rdi, [rip + wm_guard_path]
    call copy_string
    lea rdi, [rip + wm_guard_path]
    call win_normalize_path
    test rax, rax
    js .Lwmg_reserved
    lea rdi, [rip + wm_guard_path]
    call win_managed_reserved_spelling
    test eax, eax
    jnz .Lwmg_reserved
    lea r12, [rip + wm_guard_path]
    mov r13d, 4
.Lwmg_prefix_scan:
    mov al, [r12 + r13]
    test al, al
    jz .Lwmg_allowed
    cmp al, '/'
    je .Lwmg_prefix
    inc r13
    jmp .Lwmg_prefix_scan
.Lwmg_prefix:
    mov byte ptr [r12 + r13], 0
    mov rdi, -100
    mov rsi, r12
    mov edx, 65536
    xor r10d, r10d
    call win_open
    mov byte ptr [r12 + r13], '/'
    cmp rax, -2
    je .Lwmg_allowed
    cmp rax, -20
    je .Lwmg_allowed
    test rax, rax
    js .Lwmg_reserved
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + wm_guard_canonical]
    call win_managed_fd_path
    test rax, rax
    js .Lwmg_close_reserved
    lea rdi, [rip + wm_guard_canonical]
    call win_managed_reserved_spelling
    test eax, eax
    jnz .Lwmg_close_reserved
    cmp qword ptr [rip + wm_store_fd], 0
    jl .Lwmg_close_next
    mov rdi, r14
    mov eax, 5
    lea rsi, [rip + wm_stat]
    call win_syscall
    test rax, rax
    js .Lwmg_close_reserved
    mov rax, [rip + wm_stat]
    cmp rax, [rip + wm_ids + 32]
    jne .Lwmg_close_next
    mov rax, [rip + wm_stat + 8]
    cmp rax, [rip + wm_ids + 40]
    je .Lwmg_close_reserved
.Lwmg_close_next:
    mov rdi, r14
    mov eax, 3
    call win_syscall
    test rax, rax
    js .Lwmg_reserved
    inc r13
    jmp .Lwmg_prefix_scan
.Lwmg_close_reserved:
    mov rdi, r14
    mov eax, 3
    call win_syscall
.Lwmg_reserved:
    mov eax, 1
    WLEAVE
.Lwmg_allowed:
    xor eax, eax
    WLEAVE
/* RDI=normalized path<=4095. EAX=1 for reserved store or root command.
 * Only fixed ASCII component names fold case. No locale or prefix ambiguity. */
win_managed_reserved_spelling:
    WFRAME
    mov r12, rdi
    call strlen
    mov r13, rax
    cmp r13, 19
    jb .Lwmg_spelling_no
    lea rdi, [r12 + r13 - 19]
    lea rsi, [rip + wm_root_suffix]
    call win_managed_ascii_equal
    test eax, eax
    jnz .Lwmg_spelling_yes
    xor r14d, r14d
.Lwmg_spelling_start:
    lea rax, [r14 + 20]
    cmp rax, r13
    ja .Lwmg_spelling_no
    xor ecx, ecx
    lea rsi, [rip + wm_reserved_suffix]
.Lwmg_spelling_byte:
    lea rdx, [r12 + r14]
    mov al, [rdx + rcx]
    or al, 32
    cmp al, [rsi + rcx]
    jne .Lwmg_spelling_next
    inc ecx
    cmp ecx, 20
    jb .Lwmg_spelling_byte
    cmp byte ptr [rdx + 20], 0
    je .Lwmg_spelling_yes
    cmp byte ptr [rdx + 20], '/'
    je .Lwmg_spelling_yes
.Lwmg_spelling_next:
    inc r14
    jmp .Lwmg_spelling_start
.Lwmg_spelling_yes:
    mov eax, 1
    WLEAVE
.Lwmg_spelling_no:
    xor eax, eax
    WLEAVE
.section .rdata,"dr"
wm_reserved_suffix: .ascii "/.local/bin/.asm-cli"
.section .bss
wm_guard_path: .space 4096
wm_guard_canonical: .space 4096
.text
/* Reject package cache/download staging below the reserved CLI store.
 * No inputs. Returns0 or terminates before filesystem mutation.
 * WFRAME preserves dependency lock flags and other adapter arguments.
 * A synthetic leaf permits canonical/identity checks of the entire cwd. */
win_managed_check_workspace:
    WFRAME
    mov eax, 79
    lea rdi, [rip + wm_work_path]
    mov esi, 4070
    call win_syscall
    test rax, rax
    js program_path_error
    lea rdi, [rip + wm_work_path]
    call strlen
    cmp rax, 4068
    ja program_path_error
    lea rdi, [rip + wm_work_path]
    add rdi, rax
    lea rsi, [rip + wm_work_leaf]
    call copy_string
    lea rdi, [rip + wm_work_path]
    call win_managed_reserved_path
    test eax, eax
    jnz program_reserved_error
    xor eax, eax
    WLEAVE
.section .rdata,"dr"
wm_work_leaf: .asciz "/.asm-workspace-check"
.section .bss
wm_work_path: .space 4096
