/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native x86-64 PE32+ executable-container validation. This does not establish
 * code behavior, publisher identity, provenance, or absence of harmful code.
 */
.intel_syntax noprefix
.text
/* RDI=non-reparse staged path, RSI=exact verified bytes (1..64 MiB).
 * EAX=1 for an AMD64 console executable with bounded sections and executable
 * entry; zero for every failure. Requires PE32+, NX_COMPAT, executable image,
 * 1..96 sections, file/section alignment, bounded raw/virtual section ranges,
 * no writable executable section, and an entry in file-backed executable data.
 * Each raw section must fit the artifact, follow SizeOfHeaders, and be
 * disjoint from other raw ranges. Raw range order is unrestricted. Mapped
 * sections follow the aligned header range and previous aligned mapped end.
 * Mapped extents cover max(VirtualSize,SizeOfRawData), including zero padding.
 * All sums use 64 bits before the 32-bit SizeOfImage bound is applied.
 * Header offsets are checked before seeks. The candidate is never mapped or run.
 * Preserves RBX/RBP/R12-R15; scratch standard SysV. Stack:40 bytes.
 * Buffers: DOS64, NT264, sections3840, stat144. Owns and closes one descriptor.
 */
validate_host_elf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi
    cmp rbx, 328
    jb .Lpe_unopened
    cmp rbx, 67108864
    ja .Lpe_unopened
    mov eax, 2
    xor esi, esi
    xor edx, edx
    call win_syscall
    test rax, rax
    js .Lpe_unopened
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + pe_stat]
    mov eax, 5
    call win_syscall
    test rax, rax
    js .Lpe_fail
    mov eax, [rip + pe_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lpe_fail
    cmp rbx, [rip + pe_stat + 48]
    jne .Lpe_fail
    mov rdi, r12
    lea rsi, [rip + pe_dos]
    mov edx, 64
    call elf_read_exact
    test rax, rax
    js .Lpe_fail
    cmp word ptr [rip + pe_dos], 0x5a4d
    jne .Lpe_fail
    mov esi, [rip + pe_dos + 60]
    cmp esi, 64
    jb .Lpe_fail
    lea rax, [rsi + 264]
    cmp rax, rbx
    ja .Lpe_fail
    mov rdi, r12
    xor edx, edx
    mov eax, 8
    call win_syscall
    test rax, rax
    js .Lpe_fail
    mov rdi, r12
    lea rsi, [rip + pe_nt]
    mov edx, 264
    call elf_read_exact
    test rax, rax
    js .Lpe_fail
    lea r13, [rip + pe_nt]
    cmp dword ptr [r13], 0x00004550
    jne .Lpe_fail
    cmp word ptr [r13 + 4], 0x8664
    jne .Lpe_fail
    cmp word ptr [r13 + 20], 240
    jne .Lpe_fail
    movzx eax, word ptr [r13 + 22]
    test eax, 2
    jz .Lpe_fail
    test eax, 0x2000 /* no DLL */
    jnz .Lpe_fail
    cmp word ptr [r13 + 24], 0x20b
    jne .Lpe_fail
    cmp word ptr [r13 + 92], 3 /* console subsystem */
    jne .Lpe_fail
    test word ptr [r13 + 94], 0x100 /* NX_COMPAT */
    jz .Lpe_fail
    cmp dword ptr [r13 + 132], 16 /* data directories */
    ja .Lpe_fail
    mov eax, [r13 + 60] /* FileAlignment */
    cmp eax, 512
    jb .Lpe_fail
    cmp eax, 65536
    ja .Lpe_fail
    lea edx, [eax - 1]
    test eax, edx
    jnz .Lpe_fail
    mov [rip + pe_file_mask], edx
    mov ecx, [r13 + 56] /* SectionAlignment */
    cmp ecx, 4096
    jb .Lpe_fail
    cmp ecx, eax
    jb .Lpe_fail
    lea edx, [ecx - 1]
    test ecx, edx
    jnz .Lpe_fail
    mov [rip + pe_section_mask], edx
    test [r13 + 80], edx /* SizeOfImage */
    jnz .Lpe_fail
    mov eax, [r13 + 84] /* SizeOfHeaders */
    test eax, [rip + pe_file_mask]
    jnz .Lpe_fail
    cmp rax, rbx
    ja .Lpe_fail
    movzx r14d, word ptr [r13 + 6]
    test r14d, r14d
    jz .Lpe_fail
    cmp r14d, 96
    ja .Lpe_fail
    mov eax, [rip + pe_dos + 60]
    add eax, 264
    mov edx, r14d
    imul edx, edx, 40
    add rax, rdx
    cmp rax, rbx
    ja .Lpe_fail
    mov ecx, [r13 + 84]
    cmp rax, rcx
    ja .Lpe_fail
    mov rdi, r12
    lea rsi, [rip + pe_sections]
    call elf_read_exact
    test rax, rax
    js .Lpe_fail
    /* Headers occupy their complete section-aligned mapping. The previous
     * mapped end then advances once per section, requiring ordered disjoint
     * mappings without a quadratic overlap scan. */
    mov eax, [rip + pe_nt + 84]
    test eax, eax
    jz .Lpe_fail
    mov ecx, [rip + pe_section_mask]
    add rax, rcx
    not rcx
    and rax, rcx
    mov edx, [rip + pe_nt + 80]
    cmp rax, rdx
    ja .Lpe_fail
    mov [rip + pe_mapped_end], rax
    lea r13, [rip + pe_sections]
    xor r15d, r15d
.Lpe_section:
    mov eax, [r13 + 12] /* VirtualAddress */
    test eax, [rip + pe_section_mask]
    jnz .Lpe_fail
    cmp rax, [rip + pe_mapped_end]
    jb .Lpe_fail
    mov edx, [r13 + 8] /* VirtualSize */
    mov ecx, [r13 + 16] /* raw bytes also occupy mapped memory */
    cmp edx, ecx
    cmovb edx, ecx
    add rax, rdx
    mov ecx, [rip + pe_section_mask]
    add rax, rcx
    not rcx
    and rax, rcx
    mov edx, [rip + pe_nt + 80]
    cmp rax, rdx
    ja .Lpe_fail
    mov [rip + pe_mapped_end], rax
    mov eax, [r13 + 20] /* PointerToRawData */
    mov edx, [r13 + 16] /* SizeOfRawData */
    test edx, [rip + pe_file_mask]
    jnz .Lpe_fail
    test edx, edx
    jz .Lpe_section_flags
    test eax, [rip + pe_file_mask]
    jnz .Lpe_fail
    cmp eax, [rip + pe_nt + 84]
    jb .Lpe_fail
    add rax, rdx
    cmp rax, rbx
    ja .Lpe_fail
    /* Compare this file range with every preceding nonempty raw range.
     * At most96 sections means at most4560 comparisons. Raw file order may
     * differ from virtual order; only actual intersections are rejected. */
    mov r8, rax /* current exclusive raw end */
    mov r9d, [r13 + 20] /* current raw start */
    lea rcx, [rip + pe_sections]
.Lpe_raw_prior:
    cmp rcx, r13
    jae .Lpe_section_flags
    mov edx, [rcx + 16]
    test edx, edx
    jz .Lpe_raw_next
    mov eax, [rcx + 20]
    add rdx, rax /* prior exclusive raw end, overflow-safe64bits */
    cmp r9, rdx
    jae .Lpe_raw_next
    cmp rax, r8
    jb .Lpe_fail
.Lpe_raw_next:
    add rcx, 40
    jmp .Lpe_raw_prior
.Lpe_section_flags:
    mov eax, [r13 + 36]
    and eax, 0xa0000000
    cmp eax, 0xa0000000
    je .Lpe_fail
    test dword ptr [r13 + 36], 0x20000000
    jz .Lpe_next
    mov eax, [rip + pe_nt + 40] /* AddressOfEntryPoint */
    cmp eax, [r13 + 12]
    jb .Lpe_next
    mov edx, [r13 + 16]
    mov ecx, [r13 + 8]
    cmp edx, ecx
    cmova edx, ecx
    add edx, [r13 + 12]
    jc .Lpe_fail
    cmp eax, edx
    jae .Lpe_next
    mov r15d, 1
.Lpe_next:
    add r13, 40
    dec r14d
    jnz .Lpe_section
    test r15d, r15d
    jz .Lpe_fail
    mov rdi, r12
    mov eax, 3
    call win_syscall
    test rax, rax
    js .Lpe_unopened
    mov eax, 1
    jmp .Lpe_return
.Lpe_fail:
    mov rdi, r12
    mov eax, 3
    call win_syscall
.Lpe_unopened:
    xor eax, eax
.Lpe_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
/* RDI=fd RSI=owned output RDX=exact length. RAX=0/-errno. Short reads retry;
 * EOF before the requested length is EIO. Preserves callee-saved registers.
 */
elf_read_exact:
    test rdx, rdx
    jz .Lper_ok
    xor eax, eax
    call win_syscall
    test rax, rax
    js .Lper_return
    jz .Lper_short
    add rsi, rax
    sub rdx, rax
    jmp elf_read_exact
.Lper_ok:
    xor eax, eax
.Lper_return:
    ret
.Lper_short:
    mov rax, -5
    ret
.section .bss
.p2align 3
pe_dos: .space 64
pe_nt: .space 264
pe_sections: .space 3840
pe_stat: .space 144
pe_file_mask: .space 4
pe_section_mask: .space 4
pe_mapped_end: .space 8
