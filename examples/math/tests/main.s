.intel_syntax noprefix
.include "src/min.s"

.section .text
.global _start
_start:
    lea r12, [rip + cases]
    mov r13d, 8
.Lcase:
    mov rdi, [r12]
    mov rsi, [r12 + 8]
    call asm_u64_min
    cmp rax, [r12 + 16]
    jne .Lfailure
    add r12, 24
    dec r13d
    jnz .Lcase
    mov eax, 60
    xor edi, edi
    syscall
.Lfailure:
    mov eax, 60
    mov edi, 1
    syscall

.section .rodata
.balign 8
cases:
    .quad 0, 0, 0
    .quad 0, 0xffffffffffffffff, 0
    .quad 0xffffffffffffffff, 0, 0
    .quad 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff
    .quad 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff
    .quad 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff
    .quad 12, 37, 12
    .quad 37, 12, 12
.section .note.GNU-stack,"",@progbits
