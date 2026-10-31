/* RV64 Linux: write to stdout, then exit. No C runtime. */
.option norelax
.global _start
.section .text
_start:
    li a0, 1
    la a1, message
    li a2, 16
    li a7, 64
    ecall

    li a0, 0
    li a7, 93
    ecall

.section .rodata
message:
    .ascii "Hello from ASM.\n"

.section .note.GNU-stack,"",@progbits
