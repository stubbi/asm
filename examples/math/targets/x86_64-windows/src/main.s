# SPDX-License-Identifier: MIT
.intel_syntax noprefix
.equ STD_OUTPUT_HANDLE, -11
.equ WRITE_FRAME, 88
.equ WRITTEN, 40
.equ HANDLE, 48
.equ NEXT_BYTE, 56
.equ REMAINING, 64

.include "targets/x86_64-windows/src/min.s"

.text
.ifndef MATH_IO_TEST
.global _start
.global mainCRTStartup
.seh_proc mainCRTStartup
# Process entry. No arguments are used. ExitProcess receives status 0 or 1.
# Clobbers volatile Win64 registers; allocates 40 bytes including shadow space.
_start:
mainCRTStartup:
    sub rsp, 40
    .seh_stackalloc 40
    .seh_endprologue
    mov ecx, 12
    mov edx, 37
    call asm_u64_min
    cmp rax, 12
    jne example_failed
    call math_write_stdout
    jmp example_exit
example_failed:
    mov eax, 1
example_exit:
    mov ecx, eax
    call qword ptr [rip + __imp_ExitProcess]
    int3
.seh_endproc
.endif

.global math_write_stdout
.seh_proc math_write_stdout
# Input: none. Output: eax = 0 for all 17 bytes written; eax = 1 on failure.
# Clobbers volatile Win64 registers and flags; preserves nonvolatile registers.
# Stack: 88 bytes, including 32-byte shadow space and WriteFile argument five.
# The read-only message owns 17 bytes. Stack locals remain private to this call.
# Uses synchronous GetStdHandle/WriteFile; rejects NULL and INVALID_HANDLE_VALUE.
math_write_stdout:
    sub rsp, WRITE_FRAME
    .seh_stackalloc WRITE_FRAME
    .seh_endprologue
    mov ecx, STD_OUTPUT_HANDLE
    call qword ptr [rip + __imp_GetStdHandle]
    test rax, rax
    jz write_failed
    cmp rax, -1
    je write_failed
    mov qword ptr [rsp + HANDLE], rax
    lea rax, [rip + message]
    mov qword ptr [rsp + NEXT_BYTE], rax
    mov dword ptr [rsp + REMAINING], OFFSET message_len
write_more:
    mov rcx, qword ptr [rsp + HANDLE]
    mov rdx, qword ptr [rsp + NEXT_BYTE]
    mov r8d, dword ptr [rsp + REMAINING]
    lea r9, [rsp + WRITTEN]
    mov dword ptr [r9], 0
    mov qword ptr [rsp + 32], 0
    call qword ptr [rip + __imp_WriteFile]
    test eax, eax
    jz write_failed
    mov eax, dword ptr [rsp + WRITTEN]
    test eax, eax
    jz write_failed
    cmp eax, dword ptr [rsp + REMAINING]
    ja write_failed
    add qword ptr [rsp + NEXT_BYTE], rax
    sub dword ptr [rsp + REMAINING], eax
    jnz write_more
    xor eax, eax
    jmp write_return
write_failed:
    mov eax, 1
write_return:
    add rsp, WRITE_FRAME
    ret
.seh_endproc

.section .rdata,"dr"
message:
    .ascii "min(12, 37) = 12\n"
.equ message_len, . - message
