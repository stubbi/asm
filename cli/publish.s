/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.intel_syntax noprefix
.global cmd_publish, validate_source_package

/* Prepare a local registry submission. No upload, login, network or shell.
 * Snapshot each artifact before hashing/validation. Required arguments are
 * explicit; the JSON record never asserts a remote commit or owner was verified.
 * pub_* names own all module state. Returning helpers preserve SysV callee
 * registers. Terminal error labels clean the owned registry workspace.
 * Caller-saved integer registers and flags are scratch. Parser helpers that
 * intentionally advance R12 document that exception. Buffers use fixed limits:
 * six 128-byte artifact records, 16 KiB manifest/JSON, 256-byte path components.
 */
.section .text
/* Shared source-package boundary for add/sync and publication. RDI=archive
 * path, RSI=validated owner/name, RDX=validated version, RCX=validated target.
 * EAX=0/1. Preserves SysV callee registers and prior publication name/version.
 * Owns the archive/manifest scratch buffers; performs no filesystem mutation.
 * Stack frame:40 bytes. The compressed artifact digest is the caller's check. */
validate_source_package:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, [rip + pub_name]
    mov r13, [rip + pub_version]
    mov r14, rcx
    mov [rip + pub_name], rsi
    mov [rip + pub_version], rdx
    call validate_source_archive
    test eax, eax
    jnz .Lpub_package_checked
    mov rdi, r14
    call pub_check_project
.Lpub_package_checked:
    mov [rip + pub_name], r12
    mov [rip + pub_version], r13
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

cmd_publish:
    lea rax, [rip + pub_dot]
    mov [rip + pub_source_path], rax
.Lpub_argument:
    call next_arg
    test rax, rax
    jz .Lpub_arguments_done
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + pub_help_option]
    call streq
    test eax, eax
    jnz .Lpub_help
    mov rdi, r12
    lea rsi, [rip + pub_json_option]
    call streq
    test eax, eax
    jnz .Lpub_json_mode
    mov rdi, r12
    lea rsi, [rip + pub_no_color_option]
    call streq
    test eax, eax
    jnz .Lpub_argument
    mov rdi, r12
    lea rsi, [rip + pub_artifact_option]
    call streq
    test eax, eax
    jnz .Lpub_artifact_argument
    lea rbx, [rip + pub_options]
.Lpub_option_match:
    mov rsi, [rbx]
    test rsi, rsi
    jz pub_bad_arguments
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lpub_option_value
    add rbx, 24
    jmp .Lpub_option_match
.Lpub_option_value:
    mov eax, [rbx + 16]
    test [rip + pub_fields], eax
    jnz pub_bad_arguments
    or [rip + pub_fields], eax
    call pub_arg_value
    mov rdx, [rbx + 8]
    mov [rdx], rax
    jmp .Lpub_argument
.Lpub_json_mode:
    mov byte ptr [rip + json_mode], 1
    jmp .Lpub_argument
.Lpub_artifact_argument:
    mov rax, [rip + pub_artifact_count]
    cmp rax, 6
    jae pub_bad_arguments
    shl rax, 7
    lea r13, [rip + pub_artifacts]
    add r13, rax
    xor ebx, ebx
.Lpub_four_values:
    call pub_arg_value
    mov [r13 + rbx * 8], rax
    inc ebx
    cmp ebx, 4
    jb .Lpub_four_values
    inc qword ptr [rip + pub_artifact_count]
    jmp .Lpub_argument
.Lpub_arguments_done:
    mov eax, [rip + pub_fields]
    and eax, 127
    cmp eax, 127
    jne pub_bad_arguments
    cmp qword ptr [rip + pub_artifact_count], 0
    je pub_bad_arguments
    mov rdi, [rip + pub_name]
    call registry_valid_package
    test eax, eax
    jz pub_bad_metadata
    mov rdi, [rip + pub_version]
    call registry_valid_version
    test eax, eax
    jz pub_bad_metadata
    mov rdi, [rip + pub_summary]
    call strlen
    test rax, rax
    jz pub_bad_metadata
    cmp rax, 160
    ja pub_bad_metadata
    cmp byte ptr [rdi], 32
    je pub_bad_metadata
    cmp byte ptr [rdi + rax - 1], 32
    je pub_bad_metadata
    xor ecx, ecx
.Lpub_summary_character:
    movzx edx, byte ptr [rdi + rcx]
    test edx, edx
    jz .Lpub_license
    cmp edx, 32
    jb pub_bad_metadata
    cmp edx, 126
    ja pub_bad_metadata
    inc ecx
    jmp .Lpub_summary_character
.Lpub_license:
    mov rdi, [rip + pub_license]
    lea rsi, [rip + pub_licenses]
    call pub_in_strings
    test eax, eax
    jz pub_bad_metadata
    mov rdi, [rip + pub_repository]
    call strlen
    cmp rax, 160
    ja pub_bad_metadata
    lea rdi, [rip + pub_repository_check]
    mov rsi, [rip + pub_repository]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + pub_release_suffix]
    call copy_string
    lea rdi, [rip + pub_repository_check]
    call registry_release_url
    test eax, eax
    jz pub_bad_metadata
    mov rdi, [rip + pub_commit]
    call strlen
    cmp rax, 40
    jne pub_bad_metadata
    xor ecx, ecx
    xor r8d, r8d
.Lpub_commit_character:
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, '0'
    jb pub_bad_metadata
    cmp eax, '9'
    jbe .Lpub_commit_digit
    cmp eax, 'a'
    jb pub_bad_metadata
    cmp eax, 'f'
    ja pub_bad_metadata
.Lpub_commit_digit:
    cmp eax, '0'
    je .Lpub_commit_next
    mov r8d, 1
.Lpub_commit_next:
    inc ecx
    cmp ecx, 40
    jb .Lpub_commit_character
    test r8d, r8d
    jz pub_bad_metadata
    mov rdi, [rip + pub_source_path]
    cmp word ptr [rdi], 0x002e
    je .Lpub_check_artifacts
    call pub_portable_path
    test eax, eax
    jnz pub_bad_metadata
.Lpub_check_artifacts:
    xor r12d, r12d
.Lpub_artifact_metadata:
    cmp r12, [rip + pub_artifact_count]
    jae .Lpub_check_bytes
    mov rax, r12
    shl rax, 7
    lea r13, [rip + pub_artifacts]
    add r13, rax
    mov rdi, [r13]
    call registry_valid_target
    test eax, eax
    jz pub_bad_metadata
    mov rdi, [r13 + 8]
    call registry_valid_kind
    test eax, eax
    jz pub_bad_metadata
    mov rdi, [r13 + 24]
    call registry_release_url
    test eax, eax
    jz pub_bad_metadata
    mov rax, [r13 + 8]
    cmp byte ptr [rax], 's'
    jne .Lpub_artifact_duplicates
    mov rdi, [r13 + 24]
    call strlen
    cmp rax, 7
    jb pub_bad_metadata
    lea rdi, [rdi + rax - 7]
    lea rsi, [rip + pub_tar_suffix]
    call streq
    test eax, eax
    jz pub_bad_metadata
.Lpub_artifact_duplicates:
    xor r14d, r14d
.Lpub_duplicate_loop:
    cmp r14, r12
    jae .Lpub_artifact_next
    mov rax, r14
    shl rax, 7
    lea r15, [rip + pub_artifacts]
    add r15, rax
    mov rdi, [r13 + 24]
    mov rsi, [r15 + 24]
    call streq
    test eax, eax
    jnz pub_bad_metadata
    mov rdi, [r13]
    mov rsi, [r15]
    call streq
    test eax, eax
    jz .Lpub_duplicate_next
    mov rdi, [r13 + 8]
    mov rsi, [r15 + 8]
    call streq
    test eax, eax
    jnz pub_bad_metadata
.Lpub_duplicate_next:
    inc r14
    jmp .Lpub_duplicate_loop
.Lpub_artifact_next:
    inc r12
    jmp .Lpub_artifact_metadata
.Lpub_check_bytes:
    call registry_workspace
    xor r12d, r12d
.Lpub_artifact_bytes:
    cmp r12, [rip + pub_artifact_count]
    jae .Lpub_write_record
    mov rax, r12
    shl rax, 7
    lea r13, [rip + pub_artifacts]
    add r13, rax
    mov rax, [r13 + 16]
    mov [rip + registry_local_artifact], rax
    mov eax, 6
    mov rdi, [r13 + 16]
    lea rsi, [rip + pub_stat]
    syscall
    test rax, rax
    js pub_bad_artifact
    mov eax, [rip + pub_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne pub_bad_artifact
    mov rax, [rip + pub_stat + 48]
    test rax, rax
    jle pub_bad_artifact
    cmp rax, 67108864
    ja pub_bad_artifact
    mov [r13 + 32], rax
    mov [rip + registry_expected_size], rax
    call registry_copy_local
    mov rax, [r13 + 8]
    cmp byte ptr [rax], 's'
    jne .Lpub_check_elf
    lea rdi, [rip + registry_temp_payload]
    call validate_source_archive
    test eax, eax
    jnz pub_bad_artifact
    mov rdi, [r13]
    call pub_check_project
    test eax, eax
    jnz pub_bad_project
    jmp .Lpub_hash
.Lpub_check_elf:
    mov rdi, [r13]
    mov rsi, [r13 + 32]
    call pub_validate_elf
    test eax, eax
    jnz pub_bad_artifact
.Lpub_hash:
    call pub_hash_payload
    test eax, eax
    jnz pub_bad_artifact
    lea rdi, [r13 + 40]
    lea rsi, [rip + pub_hash_buffer]
    mov ecx, 64
    rep movsb
    mov byte ptr [rdi], 0
    mov eax, 87
    lea rdi, [rip + registry_temp_payload]
    syscall
    test rax, rax
    js pub_bad_artifact
    inc r12
    jmp .Lpub_artifact_bytes
.Lpub_write_record:
    call pub_make_json
    lea rdi, [rip + registry_temp_index]
    lea rsi, [rip + pub_json]
    lea rdx, [rip + pub_output_created]
    call create_exclusive_file
    test rax, rax
    js pub_output_error
    mov eax, 316
    mov rdi, -100
    lea rsi, [rip + registry_temp_index]
    mov rdx, -100
    mov r10, [rip + pub_output]
    mov r8d, 1
    syscall
    test rax, rax
    js pub_output_error
    call registry_cleanup
    cmp byte ptr [rip + json_mode], 0
    jne .Lpub_report_json
    lea rdi, [rip + pub_prepared_text]
    call out
    mov rdi, [rip + pub_output]
    call out
    lea rdi, [rip + pub_review_text]
    call out
    jmp exit_ok
.Lpub_report_json:
    lea rdi, [rip + pub_report_prefix]
    call out
    mov rdi, [rip + pub_output]
    call registry_json_string
    lea rdi, [rip + pub_report_suffix]
    call out
    jmp exit_ok
.Lpub_help:
    lea rdi, [rip + pub_help]
    call out
    jmp exit_ok

pub_arg_value:
    call next_arg
    test rax, rax
    jz pub_bad_arguments
    push rax
    mov rdi, rax
    call strlen
    test rax, rax
    jz pub_bad_arguments
    cmp rax, 4095
    ja pub_bad_arguments
    pop rax
    ret
pub_bad_arguments:
    lea rdi, [rip + pub_error_arguments]
    mov esi, 2
    jmp registry_fail
pub_bad_metadata:
    lea rdi, [rip + pub_error_metadata]
    mov esi, 2
    jmp registry_fail
pub_bad_artifact:
    lea rdi, [rip + pub_error_artifact]
    mov esi, 1
    jmp registry_fail
pub_bad_project:
    lea rdi, [rip + pub_error_project]
    mov esi, 1
    jmp registry_fail
pub_output_error:
    lea rdi, [rip + pub_error_output]
    mov esi, 1
    jmp registry_fail

/* RDI=input string, RSI=set of NUL strings followed by a second NUL.
 * EAX=1 for a match, 0 otherwise. Read-only; 16 saved stack bytes. */
pub_in_strings:
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdi
.Lpub_set_entry:
    cmp byte ptr [rbx], 0
    je .Lpub_set_absent
    mov rdi, r12
    mov rsi, rbx
    call streq
    test eax, eax
    jnz .Lpub_set_return
.Lpub_set_next:
    cmp byte ptr [rbx], 0
    lea rbx, [rbx + 1]
    jne .Lpub_set_next
    jmp .Lpub_set_entry
.Lpub_set_absent:
    xor eax, eax
.Lpub_set_return:
    pop r12
    pop rbx
    ret

/* RDI=NUL path. EAX=0/1. Checks 240-byte path bounds before component copies.
 * Rejects Windows device names. Owns pub_component[256]. Frame:24 bytes. */
pub_portable_path:
    push rbx
    push rbp
    push r12
    mov r12, rdi
    call strlen
    mov rsi, rax
    call arc_path_valid
    test eax, eax
    jnz .Lpub_portable_return
    mov rbx, r12
.Lpub_path_segment:
    lea rdi, [rip + pub_component]
    xor ecx, ecx
    xor ebp, ebp
.Lpub_path_stem:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .Lpub_path_check_stem
    cmp eax, '/'
    je .Lpub_path_check_stem
    cmp eax, '.'
    jne .Lpub_path_stem_character
    mov ebp, 1
.Lpub_path_stem_character:
    test ebp, ebp
    jnz .Lpub_path_stem_next
    cmp eax, 'A'
    jb .Lpub_path_stem_copy
    cmp eax, 'Z'
    ja .Lpub_path_stem_copy
    add eax, 32
.Lpub_path_stem_copy:
    mov [rdi + rcx], al
    inc ecx
.Lpub_path_stem_next:
    inc rbx
    jmp .Lpub_path_stem
.Lpub_path_check_stem:
    mov byte ptr [rdi + rcx], 0
    lea rsi, [rip + pub_reserved]
    call pub_in_strings
    test eax, eax
    jnz .Lpub_portable_return
    cmp byte ptr [rbx], 0
    je .Lpub_portable_return
    inc rbx
    jmp .Lpub_path_segment
.Lpub_portable_return:
    pop r12
    pop rbp
    pop rbx
    ret

/* Input: successful archive validation. Output: EAX=0/1. Reads bounded member
 * paths; rejects credential/VCS/cache names. Owns pub_component. Frame:40. */
pub_source_paths:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    xor r12d, r12d
.Lpub_source_path:
    cmp r12, [rip + arc_entry_count]
    jae .Lpub_source_paths_ok
    mov rax, r12
    shl rax, 8
    lea r13, [rip + arc_paths]
    add r13, rax
    mov rdi, r13
    call pub_portable_path
    test eax, eax
    jnz .Lpub_source_paths_bad
    mov rbx, r13
.Lpub_source_component:
    lea rdi, [rip + pub_component]
    xor ecx, ecx
.Lpub_source_component_copy:
    mov al, [rbx]
    test al, al
    jz .Lpub_source_component_check
    cmp al, '/'
    je .Lpub_source_component_check
    mov [rdi + rcx], al
    inc ecx
    inc rbx
    jmp .Lpub_source_component_copy
.Lpub_source_component_check:
    mov byte ptr [rdi + rcx], 0
    cmp dword ptr [rdi], 0x766e652e
    jne .Lpub_source_component_set
    cmp byte ptr [rdi + 4], '.'
    je .Lpub_source_paths_bad
.Lpub_source_component_set:
    lea rsi, [rip + pub_excluded]
    call pub_in_strings
    test eax, eax
    jnz .Lpub_source_paths_bad
    cmp byte ptr [rbx], 0
    je .Lpub_source_extension
    inc rbx
    jmp .Lpub_source_component
.Lpub_source_extension:
    mov rdi, r13
    call strlen
    cmp rax, 4
    jb .Lpub_source_path_next
    mov eax, [r13 + rax - 4]
    or eax, 0x20202000
    cmp eax, 0x79656b2e
    je .Lpub_source_paths_bad
    cmp eax, 0x6d65702e
    je .Lpub_source_paths_bad
.Lpub_source_path_next:
    inc r12
    jmp .Lpub_source_path
.Lpub_source_paths_ok:
    xor eax, eax
    jmp .Lpub_source_paths_return
.Lpub_source_paths_bad:
    mov eax, 1
.Lpub_source_paths_return:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Inspect the small project manifest inside the validated TAR. The accepted
 * subset uses the shared bounded build/dependency/native-link parser.
 * No escapes or duplicate fields are accepted. Reads use a copied NUL.
 * Input: RDI=validated target, pub_name/version and successful archive table.
 * Output: EAX=0/1. Owns a 16385-byte manifest and four 256-byte values. Frame:56. */
pub_check_project:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov [rip + pub_project_target], rdi
    call pub_source_paths
    test eax, eax
    jnz .Lpub_project_bad
    lea rbx, [rip + pub_readme_names]
    call pub_any_member
    test eax, eax
    jz .Lpub_project_bad
    lea rbx, [rip + pub_license_names]
    call pub_any_member
    test eax, eax
    jz .Lpub_project_bad
    lea rdi, [rip + pub_manifest_name]
    call source_archive_member
    test rax, rax
    jz .Lpub_project_bad
    test ecx, ecx
    jnz .Lpub_project_bad
    test rdx, rdx
    jz .Lpub_project_bad
    cmp rdx, 16384
    ja .Lpub_project_bad
    mov rsi, rax
    lea rdi, [rip + pub_manifest]
    mov rcx, rdx
    xor r8d, r8d
.Lpub_manifest_copy:
    mov al, [rsi + r8]
    test al, al
    jz .Lpub_project_bad
    mov [rdi + r8], al
    inc r8
    cmp r8, rcx
    jb .Lpub_manifest_copy
    mov byte ptr [rdi + rcx], 0
    lea rsi, [rip + rm_archive_metadata]
    call rm_parse_manifest
    test eax, eax
    jnz .Lpub_project_bad
    lea rdi, [rip + pub_project_name]
    mov rsi, [rip + rm_archive_metadata + 24]
    call copy_string
    lea rdi, [rip + pub_project_version]
    mov rsi, [rip + rm_archive_metadata + 32]
    call copy_string
    lea rdi, [rip + pub_project_source]
    mov rsi, [rip + rm_archive_metadata + 40]
    call copy_string
    lea rdi, [rip + pub_project_arch]
    mov rsi, [rip + rm_archive_metadata + 48]
    call copy_string
    mov rsi, [rip + pub_name]
.Lpub_unscoped_name:
    cmp byte ptr [rsi], '/'
    je .Lpub_unscoped_found
    inc rsi
    jmp .Lpub_unscoped_name
.Lpub_unscoped_found:
    inc rsi
    lea rdi, [rip + pub_project_name]
    call streq
    test eax, eax
    jz .Lpub_project_bad
    lea rdi, [rip + pub_project_version]
    mov rsi, [rip + pub_version]
    call streq
    test eax, eax
    jz .Lpub_project_bad
    lea rdi, [rip + pub_project_arch]
    mov rsi, [rip + pub_project_target]
    call streq
    test eax, eax
    jz .Lpub_project_bad
    lea rdi, [rip + pub_project_source]
    call pub_portable_path
    test eax, eax
    jnz .Lpub_project_bad
    lea rdi, [rip + pub_project_source]
    call strlen
    cmp rax, 2
    jb .Lpub_project_bad
    cmp word ptr [rdi + rax - 2], 0x732e
    je .Lpub_project_source_lookup
    cmp word ptr [rdi + rax - 2], 0x532e
    je .Lpub_project_source_lookup
    cmp rax, 4
    jb .Lpub_project_bad
    cmp dword ptr [rdi + rax - 4], 0x6d73612e
    jne .Lpub_project_bad
.Lpub_project_source_lookup:
    call source_archive_member
    test rax, rax
    jz .Lpub_project_bad
    test ecx, ecx
    jnz .Lpub_project_bad
    mov rdi, [rip + rm_archive_metadata + RM_CHECK]
    cmp byte ptr [rdi], 0
    je .Lpub_project_valid
    call pub_portable_path
    test eax, eax
    jnz .Lpub_project_bad
    mov rdi, [rip + rm_archive_metadata + RM_CHECK]
    call source_archive_member
    test rax, rax
    jz .Lpub_project_bad
    test ecx, ecx
    jnz .Lpub_project_bad
.Lpub_project_valid:
    xor eax, eax
    jmp .Lpub_project_return
.Lpub_project_bad:
    mov eax, 1
.Lpub_project_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
/* RBX points to a pointer list. Return 1 if any listed regular member exists. */
pub_any_member:
    push rbx
.Lpub_any_member_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Lpub_no_member
    call source_archive_member
    test rax, rax
    jz .Lpub_member_next
    test ecx, ecx
    jz .Lpub_member_present
.Lpub_member_next:
    add rbx, 8
    jmp .Lpub_any_member_loop
.Lpub_member_present:
    mov eax, 1
    pop rbx
    ret
.Lpub_no_member:
    xor eax, eax
    pop rbx
    ret

/* Generic ELF64 little-endian container checks for all three registry targets.
 * Metadata segments need no memory image. At least one PT_LOAD is required.
 * This does not execute the binary or prove its instruction requirements.
 * RDI=validated target, RSI=byte size. EAX=0/1. Owns fd and 64/56-byte buffers.
 * Stack frame:56 bytes. Each program header is read separately, at most1024. */
pub_validate_elf:
    # macOS executables require native Mach-O qualification on that host.
    push rdi
    push rsi
    lea rsi, [rip + registry_macos]
    call streq
    pop rsi
    pop rdi
    test eax, eax
    jz .Lpub_linux_executable
    mov eax, 1
    ret
.Lpub_linux_executable:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov rbx, rsi
    mov r12, -1
    mov ebp, 62
    cmp byte ptr [rdi], 'x'
    je .Lpub_elf_open
    mov ebp, 183
    cmp byte ptr [rdi], 'a'
    je .Lpub_elf_open
    mov ebp, 243
.Lpub_elf_open:
    mov eax, 2
    lea rdi, [rip + registry_temp_payload]
    mov esi, 657408
    xor edx, edx
    syscall
    test rax, rax
    js .Lpub_elf_bad
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + pub_elf_header]
    mov edx, 64
    call elf_read_exact
    test rax, rax
    js .Lpub_elf_bad
    lea r13, [rip + pub_elf_header]
    cmp dword ptr [r13], 0x464c457f
    jne .Lpub_elf_bad
    cmp word ptr [r13 + 4], 0x0102
    jne .Lpub_elf_bad
    cmp byte ptr [r13 + 6], 1
    jne .Lpub_elf_bad
    movzx eax, word ptr [r13 + 16]
    cmp eax, 2
    je .Lpub_elf_kind
    cmp eax, 3
    jne .Lpub_elf_bad
.Lpub_elf_kind:
    cmp word ptr [r13 + 18], bp
    jne .Lpub_elf_bad
    cmp dword ptr [r13 + 20], 1
    jne .Lpub_elf_bad
    cmp word ptr [r13 + 52], 64
    jne .Lpub_elf_bad
    cmp word ptr [r13 + 54], 56
    jne .Lpub_elf_bad
    movzx r14d, word ptr [r13 + 56]
    test r14d, r14d
    jz .Lpub_elf_bad
    cmp r14d, 1024
    ja .Lpub_elf_bad
    mov rsi, [r13 + 32]
    cmp rsi, 64
    jb .Lpub_elf_bad
    mov rax, r14
    imul rax, rax, 56
    add rax, rsi
    jc .Lpub_elf_bad
    cmp rax, rbx
    ja .Lpub_elf_bad
    mov eax, 8
    mov rdi, r12
    xor edx, edx
    syscall
    cmp rax, [r13 + 32]
    jne .Lpub_elf_bad
    xor r15d, r15d
.Lpub_elf_segment:
    mov rdi, r12
    lea rsi, [rip + pub_elf_segment]
    mov edx, 56
    call elf_read_exact
    test rax, rax
    js .Lpub_elf_bad
    lea r13, [rip + pub_elf_segment]
    mov rax, [r13 + 8]
    add rax, [r13 + 32]
    jc .Lpub_elf_bad
    cmp rax, rbx
    ja .Lpub_elf_bad
    cmp dword ptr [r13], 1
    jne .Lpub_elf_next
    mov r15d, 1
    mov rax, [r13 + 32]
    cmp rax, [r13 + 40]
    ja .Lpub_elf_bad
.Lpub_elf_next:
    dec r14
    jnz .Lpub_elf_segment
    test r15d, r15d
    jz .Lpub_elf_bad
    mov rdi, r12
    call arc_close
    xor eax, eax
    jmp .Lpub_elf_return
.Lpub_elf_bad:
    mov rdi, r12
    call arc_close
    mov eax, 1
.Lpub_elf_return:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* sha256sum reads the private payload through stdin. An empty environment and
 * fixed argv prevent filename escaping and environment-supplied behavior.
 * Exactly 68 output bytes are accepted: 64 lowercase hex, two spaces, '-', LF.
 * Input: owned registry_temp_payload. EAX=0/1. Owns pub_hash_buffer[72], pipe
 * descriptors and child process. Stack frame:56 bytes; every child is reaped. */
pub_hash_payload:
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
    mov eax, 2
    lea rdi, [rip + registry_temp_payload]
    mov esi, 657408
    xor edx, edx
    syscall
    test rax, rax
    js .Lpub_hash_bad
    mov rdi, rax
    call arc_promote_fd
    test rax, rax
    js .Lpub_hash_bad
    mov r12, rax
    mov eax, 293
    lea rdi, [rip + pub_pipe]
    mov esi, 524288
    syscall
    test rax, rax
    js .Lpub_hash_bad
    mov edi, [rip + pub_pipe]
    call arc_promote_fd
    mov r13, rax
    mov edi, [rip + pub_pipe + 4]
    call arc_promote_fd
    mov r14, rax
    test r13, r13
    js .Lpub_hash_bad
    test r14, r14
    js .Lpub_hash_bad
    mov eax, 57
    syscall
    test rax, rax
    js .Lpub_hash_bad
    jz .Lpub_hash_child
    mov r15, rax
    mov rdi, r12
    call arc_close
    mov r12, -1
    mov rdi, r14
    call arc_close
    mov r14, -1
    xor ebx, ebx
.Lpub_hash_read:
    mov eax, 0
    mov rdi, r13
    lea rsi, [rip + pub_hash_buffer]
    add rsi, rbx
    mov edx, 69
    sub rdx, rbx
    syscall
    cmp rax, -4
    je .Lpub_hash_read
    test rax, rax
    js .Lpub_hash_kill
    jz .Lpub_hash_wait
    add rbx, rax
    cmp rbx, 68
    ja .Lpub_hash_kill
    jmp .Lpub_hash_read
.Lpub_hash_wait:
    mov eax, 61
    mov rdi, r15
    lea rsi, [rip + pub_child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lpub_hash_wait
    test rax, rax
    js .Lpub_hash_bad
    cmp dword ptr [rip + pub_child_status], 0
    jne .Lpub_hash_bad
    cmp rbx, 68
    jne .Lpub_hash_bad
    cmp dword ptr [rip + pub_hash_buffer + 64], 0x0a2d2020
    jne .Lpub_hash_bad
    xor ecx, ecx
    lea rdi, [rip + pub_hash_buffer]
.Lpub_hash_hex:
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, '0'
    jb .Lpub_hash_bad
    cmp eax, '9'
    jbe .Lpub_hash_hex_next
    cmp eax, 'a'
    jb .Lpub_hash_bad
    cmp eax, 'f'
    ja .Lpub_hash_bad
.Lpub_hash_hex_next:
    inc ecx
    cmp ecx, 64
    jb .Lpub_hash_hex
    xor ebp, ebp
    jmp .Lpub_hash_close
.Lpub_hash_kill:
    mov eax, 62
    mov rdi, r15
    mov esi, 9
    syscall
.Lpub_hash_reap:
    mov eax, 61
    mov rdi, r15
    lea rsi, [rip + pub_child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lpub_hash_reap
.Lpub_hash_bad:
    mov ebp, 1
.Lpub_hash_close:
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
.Lpub_hash_child:
    mov eax, 33
    mov rdi, r12
    xor esi, esi
    syscall
    test rax, rax
    js .Lpub_hash_child_bad
    mov eax, 33
    mov rdi, r14
    mov esi, 1
    syscall
    test rax, rax
    js .Lpub_hash_child_bad
    mov rdi, r12
    call arc_close
    mov rdi, r13
    call arc_close
    mov rdi, r14
    call arc_close
    mov eax, 59
    lea rdi, [rip + registry_sha256sum]
    lea rsi, [rip + pub_sha_argv]
    lea rdx, [rip + arc_empty_env]
    syscall
.Lpub_hash_child_bad:
    mov eax, 60
    mov edi, 126
    syscall
    ud2

/* Bounded JSON builder. All string input has already passed ASCII validation.
 * It escapes quote/backslash and never writes outside the 16 KiB buffer.
 * Append/quote take RDI=NUL text and update pub_json_length. They return void;
 * overflow exits through cleanup. No saved stack frame. Inputs are immutable. */
pub_append:
    mov rdx, [rip + pub_json_length]
    lea r8, [rip + pub_json]
.Lpub_append_character:
    mov al, [rdi]
    test al, al
    jz .Lpub_append_done
    cmp rdx, 16383
    jae pub_bad_metadata
    mov [r8 + rdx], al
    inc rdx
    inc rdi
    jmp .Lpub_append_character
.Lpub_append_done:
    mov byte ptr [r8 + rdx], 0
    mov [rip + pub_json_length], rdx
    ret
pub_quote:
    mov r9, rdi
    lea rdi, [rip + pub_quote_text]
    call pub_append
    mov rdx, [rip + pub_json_length]
    lea r8, [rip + pub_json]
.Lpub_quote_character:
    mov al, [r9]
    test al, al
    jz .Lpub_quote_end
    cmp rdx, 16380
    jae pub_bad_metadata
    cmp al, '"'
    je .Lpub_quote_escape
    cmp al, '\\'
    jne .Lpub_quote_copy
.Lpub_quote_escape:
    mov byte ptr [r8 + rdx], '\\'
    inc rdx
.Lpub_quote_copy:
    mov [r8 + rdx], al
    inc rdx
    inc r9
    jmp .Lpub_quote_character
.Lpub_quote_end:
    mov byte ptr [r8 + rdx], '"'
    inc rdx
    mov byte ptr [r8 + rdx], 0
    mov [rip + pub_json_length], rdx
    ret
/* Input: validated pub_* metadata/artifacts. Output: pub_json and its length.
 * Writes no file. Owns the 16 KiB JSON and 32-byte decimal buffers. Frame:24. */
pub_make_json:
    push rbx
    push r12
    push r13
    mov qword ptr [rip + pub_json_length], 0
    lea rdi, [rip + pub_json_prefix]
    call pub_append
    mov rdi, [rip + pub_name]
    call pub_quote
    lea rdi, [rip + pub_json_version]
    call pub_append
    mov rdi, [rip + pub_version]
    call pub_quote
    lea rdi, [rip + pub_json_summary]
    call pub_append
    mov rdi, [rip + pub_summary]
    call pub_quote
    lea rdi, [rip + pub_json_license]
    call pub_append
    mov rdi, [rip + pub_license]
    call pub_quote
    lea rdi, [rip + pub_json_source]
    call pub_append
    mov rdi, [rip + pub_repository]
    call pub_quote
    lea rdi, [rip + pub_json_commit]
    call pub_append
    mov rdi, [rip + pub_commit]
    call pub_quote
    lea rdi, [rip + pub_json_path]
    call pub_append
    mov rdi, [rip + pub_source_path]
    call pub_quote
    lea rdi, [rip + pub_json_artifacts]
    call pub_append
    xor r12d, r12d
.Lpub_json_artifact:
    cmp r12, [rip + pub_artifact_count]
    jae .Lpub_json_done
    test r12, r12
    jz .Lpub_json_artifact_body
    lea rdi, [rip + pub_comma]
    call pub_append
.Lpub_json_artifact_body:
    mov rax, r12
    shl rax, 7
    lea r13, [rip + pub_artifacts]
    add r13, rax
    lea rdi, [rip + pub_json_target]
    call pub_append
    mov rdi, [r13]
    call pub_quote
    lea rdi, [rip + pub_json_kind]
    call pub_append
    mov rdi, [r13 + 8]
    call pub_quote
    lea rdi, [rip + pub_json_hash]
    call pub_append
    lea rdi, [r13 + 40]
    call pub_quote
    lea rdi, [rip + pub_json_url]
    call pub_append
    mov rdi, [r13 + 24]
    call pub_quote
    lea rdi, [rip + pub_json_bytes]
    call pub_append
    mov rdi, [r13 + 32]
    lea rsi, [rip + pub_number + 31]
    call unsigned_decimal
    mov rdi, rax
    call pub_append
    lea rdi, [rip + pub_rbrace]
    call pub_append
    inc r12
    jmp .Lpub_json_artifact
.Lpub_json_done:
    lea rdi, [rip + pub_json_suffix]
    call pub_append
    pop r13
    pop r12
    pop rbx
    ret

.section .rodata
pub_dot: .asciz "."
pub_name_option: .asciz "--name"
pub_version_option: .asciz "--version"
pub_summary_option: .asciz "--summary"
pub_license_option: .asciz "--license"
pub_repository_option: .asciz "--repository"
pub_commit_option: .asciz "--commit"
pub_output_option: .asciz "--output"
pub_source_path_option: .asciz "--source-path"
pub_artifact_option: .asciz "--artifact"
pub_help_option: .asciz "--help"
pub_json_option: .asciz "--json"
pub_no_color_option: .asciz "--no-color"
pub_tar_suffix: .asciz ".tar.gz"
pub_release_suffix: .asciz "/releases/download/v1/file"
pub_licenses:
    .asciz "AGPL-3.0-only", "AGPL-3.0-or-later"
    .asciz "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "BSL-1.0"
    .asciz "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later"
    .asciz "ISC", "LGPL-2.1-only", "LGPL-2.1-or-later", "LGPL-3.0-only", "LGPL-3.0-or-later"
    .asciz "MIT", "MPL-2.0", "Unlicense", "Zlib", ""
pub_reserved:
    .asciz "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9"
    .asciz "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", ""
pub_excluded:
    .asciz ".git", ".asm", ".venv", "__pycache__", "build", "dist", ".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", ""
pub_manifest_name: .asciz "asm.toml"
pub_readme_name: .asciz "README"
pub_readme_md: .asciz "README.md"
pub_readme_txt: .asciz "README.txt"
pub_license_name: .asciz "LICENSE"
pub_license_txt: .asciz "LICENSE.txt"
pub_license_md: .asciz "LICENSE.md"
pub_quote_text: .asciz "\""
pub_comma: .asciz ","
pub_rbrace: .asciz "}"
pub_json_prefix: .asciz "{\"schema\":1,\"name\":"
pub_json_version: .asciz ",\"version\":"
pub_json_summary: .asciz ",\"summary\":"
pub_json_license: .asciz ",\"license\":"
pub_json_source: .asciz ",\"source\":{\"repository\":"
pub_json_commit: .asciz ",\"commit\":"
pub_json_path: .asciz ",\"path\":"
pub_json_artifacts: .asciz "},\"artifacts\":["
pub_json_target: .asciz "{\"target\":"
pub_json_kind: .asciz ",\"kind\":"
pub_json_hash: .asciz ",\"sha256\":"
pub_json_url: .asciz ",\"url\":"
pub_json_bytes: .asciz ",\"bytes\":"
pub_json_suffix: .asciz "],\"yanked\":false}\n"
pub_prepared_text: .asciz "Prepared submission: "
pub_review_text: .asciz "\nOpen a registry pull request with this record. Nothing was uploaded.\n"
pub_report_prefix: .asciz "{\"prepared\":true,\"uploaded\":false,\"output\":"
pub_report_suffix: .asciz "}\n"
pub_error_arguments: .asciz "invalid publish arguments; use asm publish --help"
pub_error_metadata: .asciz "invalid publication metadata"
pub_error_artifact: .asciz "artifact validation or hashing failed"
pub_error_project: .asciz "source package is incomplete or does not match publication metadata"
pub_error_output: .asciz "cannot create submission; parent must exist and output must be new"
pub_help:
    .ascii "Usage: asm publish --name owner/name --version X.Y.Z --summary TEXT\n"
    .ascii "  --license SPDX --repository https://github.com/owner/repo\n"
    .ascii "  --commit FULL_COMMIT_ID [--source-path PATH]\n"
    .ascii "  --artifact TARGET KIND FILE URL [--artifact ...] --output FILE [--json]\n\n"
    .ascii "Prepare a local submission for a reviewed registry pull request.\n"
    .ascii "No artifact or metadata is uploaded. No name is reserved.\n"
    .ascii "Upload the exact artifacts to their public GitHub release URLs, then\n"
    .ascii "open a pull request with the generated record. Source-path defaults to .\n"
    .ascii "Supports up to six target/kind artifacts. Source is normalized USTAR gzip.\n"
    .ascii "The source manifest must match name, version and each declared target.\n"
    .ascii "The repository commit is pinned in metadata; its remote existence and\n"
    .asciz "namespace ownership remain publication-review checks. Output is never replaced.\n"
.balign 8
pub_options:
    .quad pub_name_option, pub_name, 1
    .quad pub_version_option, pub_version, 2
    .quad pub_summary_option, pub_summary, 4
    .quad pub_license_option, pub_license, 8
    .quad pub_repository_option, pub_repository, 16
    .quad pub_commit_option, pub_commit, 32
    .quad pub_output_option, pub_output, 64
    .quad pub_source_path_option, pub_source_path, 128
    .quad 0, 0, 0
pub_readme_names: .quad pub_readme_name, pub_readme_md, pub_readme_txt, 0
pub_license_names: .quad pub_license_name, pub_license_txt, pub_license_md, 0
pub_sha_argv: .quad registry_sha256sum, 0
.section .bss
.balign 16
pub_name: .skip 8
pub_version: .skip 8
pub_summary: .skip 8
pub_license: .skip 8
pub_repository: .skip 8
pub_commit: .skip 8
pub_source_path: .skip 8
pub_output: .skip 8
pub_fields: .skip 4
pub_output_created: .skip 1
.balign 8
pub_artifact_count: .skip 8
pub_artifacts: .skip 768
pub_stat: .skip 144
pub_repository_check: .skip 512
pub_component: .skip 256
pub_project_target: .skip 8
pub_project_name: .skip 256
pub_project_version: .skip 256
pub_project_source: .skip 256
pub_project_arch: .skip 256
pub_manifest: .skip 16385
pub_elf_header: .skip 64
pub_elf_segment: .skip 56
pub_pipe: .skip 8
pub_child_status: .skip 4
pub_hash_buffer: .skip 72
pub_json_length: .skip 8
pub_json: .skip 16384
pub_number: .skip 32
.section .note.GNU-stack,"",@progbits

.section .bss
.balign 8
.global rm_archive_metadata
rm_archive_metadata: .skip RM_SIZE
.section .note.GNU-stack,"",@progbits
