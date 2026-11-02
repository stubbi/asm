/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Included only in the provisioned trusted-distribution build.
 */
.section .text
/* Extract the verifier bytes carried by this already-trusted executable.
 * Input: held private stage, prepared HOME, protected installation parent.
 * Output: fixed helper/state paths (8192 bytes each); failure terminates.
 * Uses 8 saved stack bytes; preserves callee-saved registers. The candidate
 * never supplies verifier bytes. openat is exclusive and refuses links.
 */
self_prepare_embedded_verifier:
    push r12
    lea rdi, [rip + self_helper_path]
    lea rsi, [rip + self_home_environment + 5]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_helper_suffix]
    call copy_string
    lea rdi, [rip + self_trust_path]
    lea rsi, [rip + self_parent_path]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_trust_suffix]
    call copy_string
    mov eax, 257
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + self_helper_relative]
    mov edx, 1 + 64 + 128 + O_NOFOLLOW + O_CLOEXEC
    mov r10d, 448
    syscall
    test rax, rax
    js self_io_error
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + self_helper_bytes]
    mov edx, self_helper_end - self_helper_bytes
    call write_all
    test rax, rax
    js .Lself_helper_write_error
    mov eax, 3
    mov rdi, r12
    syscall
    test rax, rax
    js self_io_error
    pop r12
    ret
.Lself_helper_write_error:
    mov eax, 3
    mov rdi, r12
    syscall
    jmp self_io_error

/* No arguments. Download the authenticated index to the existing private
 * workspace; native registry parsing and selection follow. Stack 8 bytes. */
self_authenticated_index:
    sub rsp, 8
    lea rdi, [rip + self_helper_path]
    lea rsi, [rip + self_trust_index_argv]
    lea rdx, [rip + self_gh_environment]
    call self_capture
    test eax, eax
    jnz self_metadata_error
    add rsp, 8
    ret

/* No arguments. Bind the selected candidate to current TUF targets. The
 * assembly caller has checked its format, index digest, and provenance.
 * Missing/revoked targets fail before rename. Stack 8 bytes. */
self_authorize_candidate:
    sub rsp, 8
    lea rdi, [rip + self_helper_path]
    lea rsi, [rip + self_trust_artifact_argv]
    lea rdx, [rip + self_gh_environment]
    call self_capture
    test eax, eax
    jnz self_metadata_error
    add rsp, 8
    ret

/* Build the narrow provenance argv from the native verifier's existing
 * artifact slot and parsed commit. Output EAX is the captured child status.
 * Stack 8 bytes; output remains the exact numeric repository ID line. */
self_embedded_provenance:
    sub rsp, 8
    mov rax, [rip + self_verify_argv + 3*8]
    mov [rip + self_provenance_argv + 2*8], rax
    lea rax, [rip + self_unknown_commit]
    cmp byte ptr [rip + self_source_commit], 0
    je .Lself_provenance_commit
    lea rax, [rip + self_source_commit]
.Lself_provenance_commit:
    mov [rip + self_provenance_argv + 4*8], rax
    lea rdi, [rip + self_helper_path]
    lea rsi, [rip + self_provenance_argv]
    lea rdx, [rip + self_gh_environment]
    call self_capture
    add rsp, 8
    ret

.section .rodata
self_helper_suffix: .asciz "/asm-verify"
self_helper_relative: .asciz "verifier/asm-verify"
self_trust_suffix: .asciz "/.asm-trust"
self_trust_metadata: .asciz "metadata"
self_trust_authorize: .asciz "authorize"
self_trust_index: .asciz "index.tsv"
self_provenance_command: .asciz "provenance"
self_unknown_commit: .asciz "-"
.balign 16
self_helper_bytes:
.incbin "build/asm-verify-x86_64-linux"
self_helper_end:
.section .data
.balign 8
self_trust_index_argv:
    .quad self_helper_path, self_trust_metadata, self_trust_path, self_trust_index, registry_temp_index, 0
self_trust_artifact_argv:
    .quad self_helper_path, self_trust_authorize, self_trust_path, self_asset_filename, registry_temp_payload, 0
self_provenance_argv:
    .quad self_helper_path, self_provenance_command, 0, self_bundle_path, 0, 0
.section .bss
self_helper_path: .skip 8192
self_trust_path: .skip 8192
