.intel_syntax noprefix
.global validate_host_elf

/* Bounded installation checks for a declared x86_64-linux executable.
 * This checks the ELF container and target, not program behavior or provenance.
 * ABI: returning routines preserve RBX/RBP/R12-R15. Other registers are scratch.
 */
.section .text

/* Input: RDI=owned staged artifact path, RSI=verified byte size (1..64 MiB).
 * Output: EAX=1 for a supported ELF64 x86-64 executable; zero on any failure.
 * Opens without following a symlink and requires a regular file of exact size.
 * Accepts ET_EXEC/ET_DYN, 1..128 program headers of 56 bytes, readable segment
 * ranges, no writable+executable load segment, no executable stack, and an
 * entry point in a file-backed executable load segment. Does not map or run it.
 * Stack: 40 saved bytes plus nested calls. Owned buffers: 64/144/7168 bytes. */
validate_host_elf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi
    cmp rbx, 64
    jb .Lelf_fail_unopened
    cmp rbx, 67108864
    ja .Lelf_fail_unopened
    mov eax, 2
    mov esi, 131072 + 524288 + 2048
    xor edx, edx
    syscall
    test rax, rax
    js .Lelf_fail_unopened
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + elf_stat]
    syscall
    test rax, rax
    js .Lelf_fail
    cmp rbx, [rip + elf_stat + 48]
    jne .Lelf_fail
    mov eax, [rip + elf_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lelf_fail
    mov rdi, r12
    lea rsi, [rip + elf_header]
    mov edx, 64
    call elf_read_exact
    test rax, rax
    js .Lelf_fail
    lea r13, [rip + elf_header]
    cmp dword ptr [r13], 0x464c457f
    jne .Lelf_fail
    cmp byte ptr [r13 + 4], 2
    jne .Lelf_fail
    cmp byte ptr [r13 + 5], 1
    jne .Lelf_fail
    cmp byte ptr [r13 + 6], 1
    jne .Lelf_fail
    mov al, [r13 + 7]
    test al, al
    jz .Lelf_osabi_ok
    cmp al, 3
    jne .Lelf_fail
.Lelf_osabi_ok:
    cmp qword ptr [r13 + 8], 0
    jne .Lelf_fail
    movzx eax, word ptr [r13 + 16]
    cmp eax, 2
    je .Lelf_type_ok
    cmp eax, 3
    jne .Lelf_fail
.Lelf_type_ok:
    cmp word ptr [r13 + 18], 62
    jne .Lelf_fail
    cmp dword ptr [r13 + 20], 1
    jne .Lelf_fail
    cmp dword ptr [r13 + 48], 0
    jne .Lelf_fail
    cmp word ptr [r13 + 52], 64
    jne .Lelf_fail
    cmp word ptr [r13 + 54], 56
    jne .Lelf_fail
    movzx r14d, word ptr [r13 + 56]
    test r14d, r14d
    jz .Lelf_fail
    cmp r14d, 128
    ja .Lelf_fail
    mov rsi, [r13 + 32]
    cmp rsi, 64
    jb .Lelf_fail
    mov rax, r14
    imul rax, rax, 56
    add rax, rsi
    jc .Lelf_fail
    cmp rax, rbx
    ja .Lelf_fail
    mov eax, 8
    mov rdi, r12
    xor edx, edx
    syscall
    cmp rax, [r13 + 32]
    jne .Lelf_fail
    mov rdi, r12
    lea rsi, [rip + elf_program_headers]
    mov rdx, r14
    imul rdx, rdx, 56
    call elf_read_exact
    test rax, rax
    js .Lelf_fail
    lea r13, [rip + elf_program_headers]
    xor r15d, r15d
.Lelf_segment:
    mov rax, [r13 + 8]
    add rax, [r13 + 32]
    jc .Lelf_fail
    cmp rax, rbx
    ja .Lelf_fail
    cmp dword ptr [r13], 0x6474e551
    jne .Lelf_load_check
    test dword ptr [r13 + 4], 1
    jnz .Lelf_fail
.Lelf_load_check:
    cmp dword ptr [r13], 1
    jne .Lelf_next_segment
    mov eax, [r13 + 4]
    test eax, -8
    jnz .Lelf_fail
    and eax, 3
    cmp eax, 3
    je .Lelf_fail
    mov rax, [r13 + 32]
    cmp rax, [r13 + 40]
    ja .Lelf_fail
    mov rax, [r13 + 16]
    add rax, [r13 + 40]
    jc .Lelf_fail
    mov rax, [r13 + 48]
    cmp rax, 1
    jbe .Lelf_alignment_ok
    lea rdx, [rax - 1]
    test rax, rdx
    jnz .Lelf_fail
    mov rax, [r13 + 8]
    xor rax, [r13 + 16]
    test rax, rdx
    jnz .Lelf_fail
.Lelf_alignment_ok:
    test dword ptr [r13 + 4], 1
    jz .Lelf_next_segment
    mov rax, [rip + elf_header + 24]
    cmp rax, [r13 + 16]
    jb .Lelf_next_segment
    mov rdx, [r13 + 16]
    add rdx, [r13 + 32]
    jc .Lelf_fail
    cmp rax, rdx
    jae .Lelf_next_segment
    mov r15d, 1
.Lelf_next_segment:
    add r13, 56
    dec r14d
    jnz .Lelf_segment
    test r15d, r15d
    jz .Lelf_fail
    mov eax, 3
    mov rdi, r12
    syscall
    test rax, rax
    js .Lelf_fail_unopened
    mov eax, 1
    jmp .Lelf_return
.Lelf_fail:
    mov eax, 3
    mov rdi, r12
    syscall
.Lelf_fail_unopened:
    xor eax, eax
.Lelf_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Input: RDI=fd, RSI=destination, RDX=remaining capacity/required bytes.
 * Output: RAX=0 on an exact read, -1 on EOF/error. Retries EINTR and short reads.
 * Scratch: syscall registers, RSI/RDX. No stack, allocation or close operation. */
elf_read_exact:
    test rdx, rdx
    jz .Lelf_read_done
    xor eax, eax
    syscall
    cmp rax, -4
    je elf_read_exact
    test rax, rax
    jle .Lelf_read_fail
    add rsi, rax
    sub rdx, rax
    jmp elf_read_exact
.Lelf_read_done:
    xor eax, eax
    ret
.Lelf_read_fail:
    mov rax, -1
    ret

.section .bss
.balign 8
elf_header: .skip 64
elf_stat: .skip 144
elf_program_headers: .skip 7168
.section .note.GNU-stack,"",@progbits
