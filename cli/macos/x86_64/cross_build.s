/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Intel Darwin adapters for the shared selected-target staging and lock logic.
 * Fixed Homebrew LLVM/LLD build standalone Linux objects and ELF executables.
 * No shell, SDK, emulator, or ambient compiler configuration is used.
 * All routines preserve callee-saved registers. Scratch: caller-saved/flags.
 */
.text
/* No inputs. Select one explicit Linux triple/emulation or fail before writes.
 * Stores borrowed static pointers in cross_as/ld and two owned 8-byte slots.
 * Stack:8 plus callees. Missing tools exit127; unsupported/sysroot exit2. */
mac_cross_tools:
    cmp byte ptr [rip + package_link], 0
    jne .Lct_sysroot
    sub rsp, 8
    lea rdi, [rip + package_target]
    lea rsi, [rip + target_x86]
    call streq
    test eax, eax
    jnz .Lmac_cross_x86
    lea rsi, [rip + target_arm]
    call streq
    test eax, eax
    jnz .Lmac_cross_arm
    lea rsi, [rip + target_riscv]
    call streq
    test eax, eax
    jz .Lct_unsupported
    lea rax, [rip + mac_cross_riscv]
    lea rdx, [rip + mac_cross_emulation_riscv]
    jmp .Lmac_cross_store
.Lmac_cross_x86:
    lea rax, [rip + mac_cross_x86]
    lea rdx, [rip + mac_cross_emulation_x86]
    jmp .Lmac_cross_store
.Lmac_cross_arm:
    lea rax, [rip + mac_cross_arm]
    lea rdx, [rip + mac_cross_emulation_arm]
.Lmac_cross_store:
    mov [rip + mac_cross_triple], rax
    mov [rip + mac_cross_emulation], rdx
    lea rdi, [rip + mac_cross_clang]
    mov [rip + cross_as], rdi
    mov esi, 1
    mov eax, SYS_access
    syscall
    test rax, rax
    js .Lct_missing
    lea rdi, [rip + mac_cross_ld]
    mov [rip + cross_ld], rdi
    mov esi, 1
    mov eax, SYS_access
    syscall
    test rax, rax
    js .Lct_missing
    add rsp, 8
    ret
/* Rebuild argv in the existing 128-byte child_argv buffer. Select main/test
 * after the manifest validates every recipe. EAX=child status. Stack:8. */
mac_cross_assemble_wait:
    sub rsp, 8
    lea rax, [rip + mac_cross_clang]
    mov [rip + child_argv], rax
    lea rax, [rip + mac_cross_no_config]
    mov [rip + child_argv + 8], rax
    lea rax, [rip + mac_cross_target_option]
    mov [rip + child_argv + 16], rax
    mov rax, [rip + mac_cross_triple]
    mov [rip + child_argv + 24], rax
    lea rax, [rip + as_64]
    mov [rip + child_argv + 32], rax
    lea rax, [rip + arg_I]
    mov [rip + child_argv + 40], rax
    lea rax, [rip + dependency_packages_root]
    mov [rip + child_argv + 48], rax
    lea rax, [rip + arg_o]
    mov [rip + child_argv + 56], rax
    lea rax, [rip + stage_object]
    mov [rip + child_argv + 64], rax
    lea rax, [rip + package_source]
    cmp byte ptr [rip + test_mode], 0
    je .Lmac_cross_source
    lea rax, [rip + package_test]
.Lmac_cross_source:
    mov [rip + child_argv + 72], rax
    mov qword ptr [rip + child_argv + 80], 0
    lea rdi, [rip + package_target]
    lea rsi, [rip + target_riscv]
    call streq
    test eax, eax
    jz .Lmac_cross_arguments
    lea rax, [rip + cross_riscv_arch]
    mov [rip + child_argv + 80], rax
    lea rax, [rip + cross_riscv_abi]
    mov [rip + child_argv + 88], rax
    mov qword ptr [rip + child_argv + 96], 0
.Lmac_cross_arguments:
    lea rdi, [rip + mac_cross_clang]
    lea rsi, [rip + child_argv]
    call spawn_wait
    add rsp, 8
    ret
/* RDI/RSI ignored. Rebuild <=9 argv slots with explicit ELF emulation and
 * non-executable stack. EAX=child status. Tail-call keeps caller stack. */
mac_cross_link_wait:
    lea rax, [rip + mac_cross_ld]
    mov [rip + child_argv], rax
    lea rax, [rip + mac_cross_emulation_option]
    mov [rip + child_argv + 8], rax
    mov rax, [rip + mac_cross_emulation]
    mov [rip + child_argv + 16], rax
    lea rax, [rip + mac_cross_elf_z]
    mov [rip + child_argv + 24], rax
    lea rax, [rip + mac_cross_noexecstack]
    mov [rip + child_argv + 32], rax
    lea rax, [rip + arg_o]
    mov [rip + child_argv + 40], rax
    lea rax, [rip + stage_binary]
    mov [rip + child_argv + 48], rax
    lea rax, [rip + stage_object]
    mov [rip + child_argv + 56], rax
    mov qword ptr [rip + child_argv + 64], 0
    lea rdi, [rip + mac_cross_ld]
    lea rsi, [rip + child_argv]
    jmp spawn_wait
.data
mac_cross_clang: .asciz "/usr/local/opt/llvm/bin/clang"
mac_cross_ld: .asciz "/usr/local/opt/lld/bin/ld.lld"
mac_cross_x86: .asciz "x86_64-linux-gnu"
mac_cross_arm: .asciz "aarch64-linux-gnu"
mac_cross_riscv: .asciz "riscv64-linux-gnu"
mac_cross_emulation_x86: .asciz "elf_x86_64"
mac_cross_emulation_arm: .asciz "aarch64linux"
mac_cross_emulation_riscv: .asciz "elf64lriscv"
mac_cross_no_config: .asciz "--no-default-config"
mac_cross_target_option: .asciz "-target"
mac_cross_emulation_option: .asciz "-m"
mac_cross_elf_z: .asciz "-z"
mac_cross_noexecstack: .asciz "noexecstack"
.zerofill __DATA,__bss,mac_cross_triple,8,3
.zerofill __DATA,__bss,mac_cross_emulation,8,3
