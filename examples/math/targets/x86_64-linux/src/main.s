.intel_syntax noprefix
.include "targets/x86_64-linux/src/min.s"

.section .text
.global _start
_start:
    mov edi, 12
    mov esi, 37
    call asm_u64_min
    cmp rax, 12
    jne .Lfailure
    mov eax, 1
    mov edi, 1
    lea rsi, [rip + message]
    mov edx, message_end - message
    syscall
    mov eax, 60
    xor edi, edi
    syscall
.Lfailure:
    mov eax, 60
    mov edi, 1
    syscall

.section .rodata
message: .ascii "min(12, 37) = 12\n"
message_end:
.section .note.GNU-stack,"",@progbits
