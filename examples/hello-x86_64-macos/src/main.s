/* SPDX-License-Identifier: MIT
 * Input: C main arguments are ignored. Output: eax=0 after all bytes, else 1.
 * ABI: macOS x86-64 System V, libSystem write/__error.
 * Stack: 24 bytes plus return address; RSP is 16-byte aligned at each CALL.
 * Preserves RBX, RBP, R12-R15 and RSP. Changes caller-saved registers/flags.
 * Owns no buffers. Lmessage is immutable; R12/R13 track its remaining span.
 * Short writes advance the span; EINTR retries; zero/error writes fail.
 */
.intel_syntax noprefix
.section __TEXT,__text,regular,pure_instructions
.p2align 4
.globl _main
_main:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    lea r12, [rip + Lmessage]
    mov r13d, 16
Lwrite:
    mov edi, 1
    mov rsi, r12
    mov rdx, r13
    call _write
    test rax, rax
    jg Lprogress
    je Lfailure
    cmp rax, -1
    jne Lfailure
    call ___error
    cmp dword ptr [rax], 4
    je Lwrite
    jmp Lfailure
Lprogress:
    cmp rax, r13
    ja Lfailure
    add r12, rax
    sub r13, rax
    jne Lwrite
    xor eax, eax
    jmp Lreturn
Lfailure:
    mov eax, 1
Lreturn:
    pop r13
    pop r12
    pop rbp
    ret
.section __TEXT,__cstring,cstring_literals
Lmessage: .asciz "Hello from asm!\n"
.subsections_via_symbols
