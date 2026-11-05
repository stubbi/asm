/* Test-only native capture-loop harness with deterministic API shims.
 * CAPTURE_BODY is copied verbatim from the Windows adapter at build time.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
.intel_syntax noprefix
.text
.global _start
_start:
    push rbp
    mov rbp, rsp
    sub rsp, 512
    lea r14, [rip + harness_buffer]
    mov r15d, 4096
    call GetTickCount64
    mov r12, rax
    jmp .Lwp_poll
/* CAPTURE_BODY */
.Lwp_complete:
    mov r13d, 1
    jmp harness_output
.Lwp_terminate:
    mov r13d, 1
    cmp qword ptr [rip + harness_clocks], 1
    jbe harness_output
    mov rax, [rip + harness_reads]
    test rax, rax
    jz harness_output
    cmp rax, 256
    jae harness_output
    xor r13d, r13d
harness_output:
    mov ecx, -11
    call GetStdHandle
    mov rcx, rax
    lea rdx, [rip + harness_clocks]
    mov r8d, 16
    lea r9, [rip + harness_written]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    test eax, eax
    jnz 1f
    mov r13d, 1
1:  mov ecx, r13d
    call ExitProcess
GetTickCount64:
    inc qword ptr [rip + harness_clocks]
    mov rax, [rip + harness_clocks]
    shl rax, 10
    ret
PeekNamedPipe:
    mov rax, [rsp + 40]
    mov dword ptr [rax], 1
    mov eax, 1
    ret
ReadFile:
    mov byte ptr [rdx], 0
    mov dword ptr [r9], 1
    inc qword ptr [rip + harness_reads]
    mov eax, 1
    ret
WaitForSingleObject:
    mov eax, 258
    ret
GetLastError:
    mov eax, 109
    ret
.data
harness_clocks: .quad 0
harness_reads: .quad 0
win_capture_length: .quad 0
win_pipe_read: .quad 0x8004
win_process_handle: .quad 0x8000
.bss
harness_written: .space 4
harness_buffer: .space 4098
