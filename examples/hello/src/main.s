.intel_syntax noprefix
.global _start

.section .text
_start:
    mov eax, 1
    mov edi, 1
    lea rsi, [rip + message]
    mov edx, OFFSET message_len
    syscall
    mov eax, 60
    xor edi, edi
    syscall

.section .rodata
message: .ascii "Hello from asm!\n"
.equ message_len, . - message
.section .note.GNU-stack,"",@progbits
