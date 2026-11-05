# SPDX-License-Identifier: MIT
.include "targets/x86_64-windows/src/min.s"
.equ TEST_FRAME, 232
.equ CASE_POINTER, 192
.equ CASES_LEFT, 200

.macro check_gp register, value
    mov r11, \value
    cmp \register, r11
    jne test_failed
.endm
.macro check_xmm register
    movdqu xmm0, xmmword ptr [rip + vector_sentinel]
    pcmpeqb xmm0, \register
    pmovmskb eax, xmm0
    cmp eax, 65535
    jne test_failed
.endm

.text
.global _start
.global mainCRTStartup
.seh_proc mainCRTStartup
# Input: none. Output: ExitProcess(0) when value and ABI checks pass; otherwise 1.
# Saves all changed nonvolatile GP/XMM registers with Windows unwind metadata.
# Stack: 64 bytes of GP saves plus 232 bytes including shadow space and locals.
_start:
mainCRTStartup:
    push rbx
    .seh_pushreg rbx
    push rbp
    .seh_pushreg rbp
    push rdi
    .seh_pushreg rdi
    push rsi
    .seh_pushreg rsi
    push r12
    .seh_pushreg r12
    push r13
    .seh_pushreg r13
    push r14
    .seh_pushreg r14
    push r15
    .seh_pushreg r15
    sub rsp, TEST_FRAME
    .seh_stackalloc TEST_FRAME
    movdqu xmmword ptr [rsp + 32], xmm6
    .seh_savexmm xmm6, 32
    movdqu xmmword ptr [rsp + 48], xmm7
    .seh_savexmm xmm7, 48
    movdqu xmmword ptr [rsp + 64], xmm8
    .seh_savexmm xmm8, 64
    movdqu xmmword ptr [rsp + 80], xmm9
    .seh_savexmm xmm9, 80
    movdqu xmmword ptr [rsp + 96], xmm10
    .seh_savexmm xmm10, 96
    movdqu xmmword ptr [rsp + 112], xmm11
    .seh_savexmm xmm11, 112
    movdqu xmmword ptr [rsp + 128], xmm12
    .seh_savexmm xmm12, 128
    movdqu xmmword ptr [rsp + 144], xmm13
    .seh_savexmm xmm13, 144
    movdqu xmmword ptr [rsp + 160], xmm14
    .seh_savexmm xmm14, 160
    movdqu xmmword ptr [rsp + 176], xmm15
    .seh_savexmm xmm15, 176
    .seh_endprologue
    mov qword ptr [rip + expected_sp], rsp
    lea rax, [rip + cases]
    mov qword ptr [rsp + CASE_POINTER], rax
    mov dword ptr [rsp + CASES_LEFT], 8
    mov rbx, 0x1122334455667713
    mov rbp, 0x1122334455667715
    mov rdi, 0x1122334455667717
    mov rsi, 0x1122334455667719
    mov r12, 0x1122334455667721
    mov r13, 0x1122334455667722
    mov r14, 0x1122334455667723
    mov r15, 0x1122334455667724
    movdqu xmm6, xmmword ptr [rip + vector_sentinel]
    movdqa xmm7, xmm6
    movdqa xmm8, xmm6
    movdqa xmm9, xmm6
    movdqa xmm10, xmm6
    movdqa xmm11, xmm6
    movdqa xmm12, xmm6
    movdqa xmm13, xmm6
    movdqa xmm14, xmm6
    movdqa xmm15, xmm6
test_next:
    mov r10, qword ptr [rsp + CASE_POINTER]
    mov rcx, qword ptr [r10]
    mov rdx, qword ptr [r10 + 8]
    call asm_u64_min
    cmp rsp, qword ptr [rip + expected_sp]
    jne test_failed
    mov r10, qword ptr [rsp + CASE_POINTER]
    cmp rax, qword ptr [r10 + 16]
    jne test_failed
    check_gp rbx, 0x1122334455667713
    check_gp rbp, 0x1122334455667715
    check_gp rdi, 0x1122334455667717
    check_gp rsi, 0x1122334455667719
    check_gp r12, 0x1122334455667721
    check_gp r13, 0x1122334455667722
    check_gp r14, 0x1122334455667723
    check_gp r15, 0x1122334455667724
    check_xmm xmm6
    check_xmm xmm7
    check_xmm xmm8
    check_xmm xmm9
    check_xmm xmm10
    check_xmm xmm11
    check_xmm xmm12
    check_xmm xmm13
    check_xmm xmm14
    check_xmm xmm15
    add qword ptr [rsp + CASE_POINTER], 24
    dec dword ptr [rsp + CASES_LEFT]
    jnz test_next
    xor ecx, ecx
    jmp test_exit
test_failed:
    mov ecx, 1
test_exit:
    call qword ptr [rip + __imp_ExitProcess]
    int3
.seh_endproc

.section .rdata,"dr"
.p2align 4
vector_sentinel: .quad 0x0123456789abcdef, 0xfedcba9876543210
cases:
    .quad 0, 0, 0
    .quad 0, 0xffffffffffffffff, 0
    .quad 0xffffffffffffffff, 0, 0
    .quad 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff
    .quad 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff
    .quad 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff
    .quad 12, 37, 12
    .quad 37, 12, 12
.data
.p2align 3
expected_sp: .quad 0
