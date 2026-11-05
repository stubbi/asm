/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only bounded adapter trace. This file is never included in release
 * preparation. native_diagnostics.py injects calls into a separate executable.
 * No file contents, credentials or environment entries are logged.
 */
.text
/* RDI=raw NTSTATUS, RSI=UTF16 component, EDX=explicit byte length <=510.
 * Emits at most 1024 stderr bytes. Preserves internal callee-saved registers.
 * Stack: WFRAME; status preservation belongs to the injected caller. */
win_diag_nt_log:
    WFRAME
    mov r12d, edi
    lea rdi, [rip + win_diag_nt_line + 3]
    mov esi, r12d
    call win_diag_hex32
    mov ecx, 65001
    mov edx, 128
    mov r8, [rbp - 56]
    mov r9, [rbp - 64]
    shr r9, 1
    cmp r9, 255
    ja .Ldiag_nt_no_name
    lea rax, [rip + win_diag_nt_line + 22]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 900
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jnz .Ldiag_nt_name
.Ldiag_nt_no_name:
    xor eax, eax
.Ldiag_nt_name:
    lea rsi, [rip + win_diag_nt_line]
    mov byte ptr [rsi + rax + 22], 10
    lea edx, [eax + 23]
    mov edi, 2
    call write_all
    WLEAVE

/* RDI=normalized stat[144] after owner and DACL checks. Emits 49 bytes.
 * This reports the adapter's actual encoding, not a replacement decision. */
win_diag_stat_log:
    WFRAME
    mov r12, rdi
    mov esi, [r12 + 24]
    lea rdi, [rip + win_diag_stat_line + 10]
    call win_diag_hex32
    mov esi, [r12 + 28]
    lea rdi, [rip + win_diag_stat_line + 25]
    call win_diag_hex32
    mov esi, [r12 + 16]
    lea rdi, [rip + win_diag_stat_line + 40]
    call win_diag_hex32
    mov edi, 2
    lea rsi, [rip + win_diag_stat_line]
    mov edx, 49
    call write_all
    WLEAVE

/* RDI=owned output[8], ESI=value. Writes eight uppercase hex digits.
 * Scratch: RAX/RCX/RDX/R8/flags; no external calls or stack use. */
win_diag_hex32:
    mov r8d, 8
    lea rdx, [rip + win_diag_hex_digits]
.Ldiag_hex:
    mov eax, esi
    shr eax, 28
    mov al, [rdx + rax]
    mov [rdi], al
    inc rdi
    shl esi, 4
    dec r8d
    jnz .Ldiag_hex
    ret
.section .rdata,"dr"
win_diag_hex_digits: .ascii "0123456789ABCDEF"
.data
win_diag_nt_line: .ascii "NT 00000000 component="
    .space 1002
win_diag_stat_line: .ascii "STAT mode=00000000 owner=00000000 links=00000000\n"

.text
/* RAX=setup result. Log a bounded process stage/result; an error code is
 * meaningful only when the documented API result denotes failure. Preserve
 * RAX and internal registers. This does not enter the release executable. */
win_diag_process_log:
    WFRAME
    mov r12, rax
    call GetLastError
    mov r13d, eax
    lea rdi, [rip + win_diag_process_line + 11]
    mov esi, [rip + win_diag_process_stage]
    call win_diag_hex32
    lea rdi, [rip + win_diag_process_line + 27]
    mov esi, r12d
    call win_diag_hex32
    lea rdi, [rip + win_diag_process_line + 42]
    mov esi, r13d
    call win_diag_hex32
    mov edi, 2
    lea rsi, [rip + win_diag_process_line]
    mov edx, 51
    call write_all
    mov rax, r12
    WLEAVE
.data
win_diag_process_stage: .long 0
win_diag_process_line: .ascii "PROC stage=00000000 result=00000000 error=00000000\n"
