.intel_syntax noprefix
.global _start

.section .text
_start:
    # Exit zero for success; replace this with your assertions.
    mov eax, 60
    xor edi, edi
    syscall
.section .note.GNU-stack,"",@progbits
