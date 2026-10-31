/* AArch64 Linux: write to stdout, then exit. No C runtime. */
.global _start
.section .text
_start:
    mov x0, #1
    adr x1, message
    mov x2, #16
    mov x8, #64
    svc #0

    mov x0, #0
    mov x8, #93
    svc #0

.section .rodata
message:
    .ascii "Hello from ASM.\n"

.section .note.GNU-stack,"",@progbits
