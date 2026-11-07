/*
MIT License

Copyright (c) 2026 ASM contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

.intel_syntax noprefix
.include "stubbi/math/0.4.0/x86_64-linux/src/min.s"

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
