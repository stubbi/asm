.include "targets/x86_64-macos/src/min.s"

.text
.p2align 4
.global _main
/* Assembly-only value and ABI checks.
 * Input: Apple main call frame; arguments are unused.
 * Output: status 0 on pass, 1 on a value or preservation failure.
 * Saves: rbp, rbx, r12-r15. Adds 40 bytes of private stack storage.
 * Checks: rbx, r12-r15 sentinels, rbp, rsp, and a stack canary.
 * Buffers: fixed case/sentinel tables; private frame-address word.
 * Calls: _asm_u64_min with RSP aligned to 16 bytes before CALL.
 */
_main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov QWORD PTR [rip + frame_address], rsp
    mov rbx, QWORD PTR [rip + sentinels]
    mov r12, QWORD PTR [rip + sentinels + 8]
    mov r13, QWORD PTR [rip + sentinels + 16]
    mov r14, QWORD PTR [rip + sentinels + 24]
    mov r15, QWORD PTR [rip + sentinels + 32]
    lea r10, [rip + cases]
    mov QWORD PTR [rsp], r10
    mov QWORD PTR [rsp + 8], 16
    mov QWORD PTR [rsp + 24], 0x5a5a
Lcase:
    mov r10, QWORD PTR [rsp]
    mov rdi, QWORD PTR [r10]
    mov rsi, QWORD PTR [r10 + 8]
    mov r11, QWORD PTR [r10 + 16]
    mov QWORD PTR [rsp + 16], r11
    call _asm_u64_min
    cmp rsp, QWORD PTR [rip + frame_address]
    jne Lfailure
    lea r10, [rsp + 80]
    cmp rbp, r10
    jne Lfailure
    cmp rax, QWORD PTR [rsp + 16]
    jne Lfailure
    cmp QWORD PTR [rsp + 24], 0x5a5a
    jne Lfailure
    cmp rbx, QWORD PTR [rip + sentinels]
    jne Lfailure
    cmp r12, QWORD PTR [rip + sentinels + 8]
    jne Lfailure
    cmp r13, QWORD PTR [rip + sentinels + 16]
    jne Lfailure
    cmp r14, QWORD PTR [rip + sentinels + 24]
    jne Lfailure
    cmp r15, QWORD PTR [rip + sentinels + 32]
    jne Lfailure
    add QWORD PTR [rsp], 24
    dec QWORD PTR [rsp + 8]
    jnz Lcase
    xor eax, eax
    jmp Lrestore
Lfailure:
    mov rsp, QWORD PTR [rip + frame_address]
    mov eax, 1
Lrestore:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.section __TEXT,__const
.p2align 3
cases:
    .quad 0, 0, 0
    .quad 0, 0xffffffffffffffff, 0
    .quad 0xffffffffffffffff, 0, 0
    .quad 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff
    .quad 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff
    .quad 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff
    .quad 12, 37, 12
    .quad 37, 12, 12
    .quad 42, 42, 42
    .quad 1, 0xffffffffffffffff, 1
    .quad 0xffffffffffffffff, 1, 1
    .quad 1, 2, 1
    .quad 2, 1, 1
    .quad 0x8000000000000000, 1, 1
    .quad 0x100000000, 0x10000000000, 0x100000000
    .quad 0x10000000000, 0x100000000, 0x100000000
sentinels:
    .quad 0x0303030303030303
    .quad 0x1212121212121212
    .quad 0x1313131313131313
    .quad 0x1414141414141414
    .quad 0x1515151515151515

.data
.p2align 3
frame_address: .quad 0
.subsections_via_symbols
