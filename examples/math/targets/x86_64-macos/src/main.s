.include "targets/x86_64-macos/src/min.s"

.equ EINTR, 4

.text
.p2align 4
.global _main
/* Input: Apple main call frame; arguments are unused.
 * Output: status 0 after the complete message; status 1 on failure.
 * Changed: caller-saved registers and flags through libSystem calls.
 * Stack: saves rbp, r12, and r13; aligns RSP to 16 bytes before calls.
 * Memory: the fixed message is read-only. No caller-owned buffers.
 * Calls: Apple x86-64 helper, libSystem write, and __error for errno.
 */
_main:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    mov edi, 12
    mov esi, 37
    call _asm_u64_min
    cmp rax, 12
    jne Lfailure
    lea r12, [rip + message]
    mov r13d, OFFSET message_len
Lwrite:
    mov edi, 1
    mov rsi, r12
    mov rdx, r13
    call _write
    cmp rax, -1
    je Lwrite_error
    test rax, rax
    jle Lfailure
    cmp rax, r13
    ja Lfailure
    add r12, rax
    sub r13, rax
    jnz Lwrite
    xor eax, eax
    jmp Lreturn
Lwrite_error:
    call ___error
    cmp DWORD PTR [rax], EINTR
    je Lwrite
Lfailure:
    mov eax, 1
Lreturn:
    pop r13
    pop r12
    pop rbp
    ret

.section __TEXT,__const
message: .ascii "min(12, 37) = 12\n"
.equ message_len, .-message
.subsections_via_symbols
