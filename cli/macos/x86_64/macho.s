/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Bounded thin x86-64 Mach-O validation. RDI=staged path, RSI=exact bytes.
 * EAX=1 valid container + ad-hoc/stronger code signature, zero on failure.
 * Preserve RBX/RBP/R12-R15. Owned static header <=65568 and stat=144 bytes.
 * Never map or execute the candidate. Publisher identity is checked separately.
 */
.intel_syntax noprefix
.text
validate_host_elf:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbp, rdi
    mov rbx, rsi
    cmp rbx, 32
    jb .Lmx_unopened
    cmp rbx, 67108864
    ja .Lmx_unopened
    mov esi, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    xor edx, edx
    mov eax, 2
    call mac_syscall
    test rax, rax
    js .Lmx_unopened
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + mac_macho_stat]
    mov eax, 5
    call mac_syscall
    test rax, rax
    js .Lmx_fail
    cmp rbx, [rip + mac_macho_stat + 48]
    jne .Lmx_fail
    mov eax, [rip + mac_macho_stat + 24]
    and eax, 0xf000
    cmp eax, 0x8000
    jne .Lmx_fail
    mov rdi, r12
    lea rsi, [rip + mac_macho_buffer]
    mov edx, 32
    call elf_read_exact
    test rax, rax
    js .Lmx_fail
    lea r13, [rip + mac_macho_buffer]
    cmp dword ptr [r13], 0xfeedfacf
    jne .Lmx_fail
    cmp dword ptr [r13 + 4], 0x1000007
    jne .Lmx_fail
    cmp dword ptr [r13 + 8], 3 /* CPU_SUBTYPE_X86_64_ALL, no x86_64h */
    jne .Lmx_fail
    cmp dword ptr [r13 + 12], 2
    jne .Lmx_fail
    cmp dword ptr [r13 + 28], 0
    jne .Lmx_fail
    test dword ptr [r13 + 24], 0x200000 /* MH_PIE */
    jz .Lmx_fail
    test dword ptr [r13 + 24], 0x20000 /* MH_ALLOW_STACK_EXECUTION */
    jnz .Lmx_fail
    mov r15d, [r13 + 16]
    test r15d, r15d
    jz .Lmx_fail
    cmp r15d, 128
    ja .Lmx_fail
    mov edx, [r13 + 20]
    test edx, edx
    jz .Lmx_fail
    cmp edx, 65536
    ja .Lmx_fail
    lea rax, [rdx + 32]
    cmp rax, rbx
    ja .Lmx_fail
    add r13, 32
    lea r14, [r13 + rdx]
    mov rdi, r12
    mov rsi, r13
    call elf_read_exact
    test rax, rax
    js .Lmx_fail
    mov qword ptr [rip + mac_macho_entry], -1
    mov dword ptr [rip + mac_macho_platform], 0
.Lmx_command:
    lea rax, [r13 + 8]
    cmp rax, r14
    ja .Lmx_fail
    mov eax, [r13]
    mov ecx, [r13 + 4]
    cmp ecx, 8
    jb .Lmx_fail
    test ecx, 7
    jnz .Lmx_fail
    lea rdx, [r13 + rcx]
    cmp rdx, r14
    ja .Lmx_fail
    cmp eax, 0x19
    je .Lmx_segment
    cmp eax, 0x80000028
    je .Lmx_main
    cmp eax, 0x32
    je .Lmx_version
    jmp .Lmx_next
.Lmx_main:
    cmp ecx, 24
    jne .Lmx_fail
    cmp qword ptr [rip + mac_macho_entry], -1
    jne .Lmx_fail
    mov rax, [r13 + 8]
    mov [rip + mac_macho_entry], rax
    jmp .Lmx_next
.Lmx_version:
    cmp ecx, 24
    jb .Lmx_fail
    cmp dword ptr [rip + mac_macho_platform], 0
    jne .Lmx_fail
    cmp dword ptr [r13 + 8], 1
    jne .Lmx_fail
    cmp dword ptr [r13 + 12], 0xf0000
    ja .Lmx_fail
    mov eax, [r13 + 20]
    lea rax, [rax*8 + 24]
    cmp rax, rcx
    jne .Lmx_fail
    mov dword ptr [rip + mac_macho_platform], 1
    jmp .Lmx_next
.Lmx_segment:
    cmp ecx, 72
    jb .Lmx_fail
    mov eax, [r13 + 64]
    imul rax, rax, 80
    add rax, 72
    cmp rax, rcx
    jne .Lmx_fail
    mov rax, [r13 + 48]
    cmp rax, [r13 + 32]
    ja .Lmx_fail
    add rax, [r13 + 40]
    jc .Lmx_fail
    cmp rax, rbx
    ja .Lmx_fail
    mov eax, [r13 + 56]
    mov esi, [r13 + 60]
    mov edi, eax
    or edi, esi
    test edi, -8
    jnz .Lmx_fail
    and eax, esi
    cmp eax, esi
    jne .Lmx_fail
    and esi, 6
    cmp esi, 6
    je .Lmx_fail
.Lmx_next:
    mov r13, rdx
    dec r15d
    jnz .Lmx_command
    cmp r13, r14
    jne .Lmx_fail
    cmp dword ptr [rip + mac_macho_platform], 1
    jne .Lmx_fail
    mov rdx, [rip + mac_macho_entry]
    lea r13, [rip + mac_macho_buffer]
    mov rax, r14
    sub rax, r13
    cmp rdx, rax
    jb .Lmx_fail
    mov r15d, [r13 + 16]
    add r13, 32
.Lmx_entry_check:
    cmp dword ptr [r13], 0x19
    jne .Lmx_entry_next
    test dword ptr [r13 + 60], 4
    jz .Lmx_entry_next
    mov rax, [r13 + 40]
    cmp rdx, rax
    jb .Lmx_entry_next
    add rax, [r13 + 48]
    cmp rdx, rax
    jb .Lmx_valid
.Lmx_entry_next:
    mov eax, [r13 + 4]
    add r13, rax
    dec r15d
    jnz .Lmx_entry_check
    jmp .Lmx_fail
.Lmx_valid:
    mov rdi, r12
    mov eax, 3
    call mac_syscall
    test rax, rax
    js .Lmx_unopened
    mov [rip + mac_codesign_argv + 24], rbp
    call mac_codesign_wait
    test eax, eax
    sete al
    movzx eax, al
    jmp .Lmx_return
.Lmx_fail:
    mov rdi, r12
    mov eax, 3
    call mac_syscall
.Lmx_unopened:
    xor eax, eax
.Lmx_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
elf_read_exact:
    test rdx, rdx
    jz .Lmx_read_done
    xor eax, eax
    call mac_syscall
    cmp rax, -4
    je elf_read_exact
    test rax, rax
    jle .Lmx_read_fail
    add rsi, rax
    sub rdx, rax
    jmp elf_read_exact
.Lmx_read_done:
    xor eax, eax
    ret
.Lmx_read_fail:
    mov rax, -1
    ret
/* Fixed codesign, no ambient environment, no output, 15-second alarm.
 * EAX=0 only for an ordinary successful child exit. */
mac_codesign_wait:
    push rbx
    mov eax, 57
    call mac_syscall
    test rax, rax
    js .Lmx_sign_bad
    jz .Lmx_sign_child
    mov rbx, rax
.Lmx_sign_wait:
    mov rdi, rbx
    lea rsi, [rip + mac_codesign_status]
    xor edx, edx
    xor r10d, r10d
    mov eax, 61
    call mac_syscall
    cmp rax, -4
    je .Lmx_sign_wait
    test rax, rax
    js .Lmx_sign_bad
    xor eax, eax
    cmp dword ptr [rip + mac_codesign_status], 0
    setne al
    pop rbx
    ret
.Lmx_sign_child:
    lea rdi, [rip + mac_codesign_null]
    mov esi, 1
    xor edx, edx
    mov eax, 2
    call mac_syscall
    test rax, rax
    js .Lmx_sign_exit
    mov rbx, rax
    mov rdi, rbx
    mov esi, 1
    mov eax, 33
    call mac_syscall
    test rax, rax
    js .Lmx_sign_exit
    mov rdi, rbx
    mov esi, 2
    mov eax, 33
    call mac_syscall
    test rax, rax
    js .Lmx_sign_exit
    cmp rbx, 2
    jbe 1f
    mov rdi, rbx
    mov eax, 3
    call mac_syscall
1:  mov edi, 14
    xor esi, esi
    mov eax, 13
    call mac_syscall
    test rax, rax
    js .Lmx_sign_exit
    mov edi, 1
    lea rsi, [rip + mac_codesign_mask]
    xor edx, edx
    mov eax, 14
    call mac_syscall
    test rax, rax
    js .Lmx_sign_exit
    mov edi, 15
    mov eax, 37
    call mac_syscall
    lea rdi, [rip + mac_codesign_path]
    lea rsi, [rip + mac_codesign_argv]
    lea rdx, [rip + mac_empty_environment]
    mov eax, 59
    call mac_syscall
.Lmx_sign_exit:
    mov edi, 127
    mov eax, 60
    call mac_syscall
.Lmx_sign_bad:
    mov eax, 1
    pop rbx
    ret
.data
mac_codesign_path: .asciz "/usr/bin/codesign"
mac_codesign_verify: .asciz "--verify"
mac_codesign_strict: .asciz "--strict"
mac_codesign_null: .asciz "/dev/null"
.p2align 3
mac_codesign_argv: .quad mac_codesign_path, mac_codesign_verify, mac_codesign_strict, 0, 0
mac_codesign_mask: .quad 1 << 13
.zerofill __DATA,__bss,mac_codesign_status,8,3
.zerofill __DATA,__bss,mac_macho_buffer,65568,3
.zerofill __DATA,__bss,mac_macho_stat,144,3
.zerofill __DATA,__bss,mac_macho_entry,8,3
.zerofill __DATA,__bss,mac_macho_platform,4,3
