/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Explicit selected-target standalone builds. No shell or emulator is used.
 * Strings are bounded by the manifest parser. Owned path buffers are 96 bytes;
 * canonical target names and fixed suffixes fit within 72 bytes including NUL.
 * Returning routines preserve SysV callee-saved registers. Syscalls use Linux
 * x86-64 ABI; helper calls use the CLI ABI documented in asm.s. */
.section .text
/* RDI=terminated target. RAX=canonical static pointer, or zero. Stack:8.
 * Recognizes seven canonical targets and the native host alias only. */
project_canonical_target:
    push rbx
    mov rbx, rdi
    lea rsi, [rip + host_target_alias]
    call streq
    test eax, eax
    jz .Lpc_canonical
    lea rax, [rip + host_target]
    jmp .Lpc_done
.Lpc_canonical:
    lea rsi, [rip + target_x86]
    call streq
    test eax, eax
    jnz .Lpc_x86
    mov rdi, rbx
    lea rsi, [rip + target_arm]
    call streq
    test eax, eax
    jnz .Lpc_arm
    mov rdi, rbx
    lea rsi, [rip + target_riscv]
    call streq
    test eax, eax
    jnz .Lpc_riscv
    mov rdi, rbx
    lea rsi, [rip + target_macos]
    call streq
    test eax, eax
    jnz .Lpc_macos
    mov rdi, rbx
    lea rsi, [rip + target_macos_x86]
    call streq
    test eax, eax
    jnz .Lpc_macos_x86
    mov rdi, rbx
    lea rsi, [rip + target_windows_x86]
    call streq
    test eax, eax
    jnz .Lpc_windows_x86
    mov rdi, rbx
    lea rsi, [rip + target_windows_arm]
    call streq
    test eax, eax
    jnz .Lpc_windows_arm
    jmp .Lpc_done
.Lpc_macos:
    lea rax, [rip + target_macos]
    jmp .Lpc_done
.Lpc_x86: lea rax, [rip + target_x86]
    jmp .Lpc_done
.Lpc_arm: lea rax, [rip + target_arm]
    jmp .Lpc_done
.Lpc_riscv: lea rax, [rip + target_riscv]
    jmp .Lpc_done
.Lpc_macos_x86: lea rax, [rip + target_macos_x86]
    jmp .Lpc_done
.Lpc_windows_x86: lea rax, [rip + target_windows_x86]
    jmp .Lpc_done
.Lpc_windows_arm: lea rax, [rip + target_windows_arm]
.Lpc_done:
    pop rbx
    ret
/* RDI=argv target. EAX=1/0. Stores a static pointer only on success. */
project_set_target:
    call project_canonical_target
    test rax, rax
    jz .Lps_done
    mov [rip + project_requested_target], rax
    mov eax, 1
.Lps_done: ret
/* RDI=manifest target. EAX=selected match. Canonicalizes package_target on
 * success. Stack:8; borrows argv/static selected pointer, modifies no files. */
project_target_matches:
    call project_canonical_target
    test rax, rax
    jz .Lpm_done
    push rax
    mov rdi, rax
    mov rsi, [rip + project_requested_target]
    test rsi, rsi
    jnz .Lpm_compare
    lea rsi, [rip + host_target]
.Lpm_compare:
    call streq
    pop rsi
    test eax, eax
    jz .Lpm_done
    lea rdi, [rip + package_target]
    call copy_string
    mov eax, 1
.Lpm_done: ret
/* RDI=canonical target. EAX=declared 1/0. Mask uses parser table bits.
 * Legacy form compares the selected canonical package_target. Stack:8. */
project_declares_target:
    mov edx, [rip + project_target_mask]
    test edx, edx
    jz .Lpd_legacy
    push rbx
    mov rbx, rdi
    lea rsi, [rip + target_x86]
    call streq
    test eax, eax
    jnz .Lpd_x86
    mov rdi, rbx
    lea rsi, [rip + target_arm]
    call streq
    test eax, eax
    jnz .Lpd_arm
    mov rdi, rbx
    lea rsi, [rip + target_riscv]
    call streq
    test eax, eax
    jnz .Lpd_riscv
    mov rdi, rbx
    lea rsi, [rip + target_macos]
    call streq
    test eax, eax
    jnz .Lpd_macos
    mov rdi, rbx
    lea rsi, [rip + target_macos_x86]
    call streq
    test eax, eax
    jnz .Lpd_macos_x86
    mov rdi, rbx
    lea rsi, [rip + target_windows_x86]
    call streq
    test eax, eax
    jnz .Lpd_windows_x86
    mov rdi, rbx
    lea rsi, [rip + target_windows_arm]
    call streq
    test eax, eax
    jnz .Lpd_windows_arm
    jmp .Lpd_return
.Lpd_macos: mov eax, 32
    jmp .Lpd_mask
.Lpd_macos_x86: mov eax, 64
    jmp .Lpd_mask
.Lpd_windows_x86: mov eax, 128
    jmp .Lpd_mask
.Lpd_windows_arm: mov eax, 256
    jmp .Lpd_mask

.Lpd_x86: mov eax, 4
    jmp .Lpd_mask
.Lpd_arm: mov eax, 8
    jmp .Lpd_mask
.Lpd_riscv: mov eax, 16
.Lpd_mask:
    test eax, [rip + project_target_mask]
    setnz al
    movzx eax, al
.Lpd_return: pop rbx
    ret
.Lpd_legacy:
    lea rsi, [rip + package_target]
    jmp streq
project_template_check:
    mov rdi, [rip + project_requested_target]
    test rdi, rdi
    jz .Lpt_done
    call validate_target
    test eax, eax
    jz .Lpt_error
.Lpt_done: ret
.Lpt_error:
    lea rdi, [rip + cross_template_error]
    mov esi, 2
    jmp die
/* Refuse execution before dependency/cache/output mutation. */
project_execution_check:
    lea rdi, [rip + package_target]
    call validate_target
    test eax, eax
    jnz .Lpe_done
    cmp byte ptr [rip + run_mode], 0
    jne .Lpe_error
    cmp byte ptr [rip + test_mode], 0
    je .Lpe_done
    cmp byte ptr [rip + no_run], 0
    je .Lpe_error
.Lpe_done: ret
.Lpe_error:
    lea rdi, [rip + cross_execute_error]
    mov esi, 2
    jmp die
/* Build canonical selected directory and four artifact paths. No syscalls.
 * Scratch:caller-saved. Stack:8 for alignment. */
cross_paths:
    sub rsp, 8
    lea rdi, [rip + cross_directory]
    lea rsi, [rip + cross_build_prefix]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + package_target]
    call copy_string
    lea rdi, [rip + cross_object]
    lea rsi, [rip + cross_directory]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + object_suffix]
    cmp byte ptr [rip + test_mode], 0
    je .Lcp_object
    lea rsi, [rip + cross_test_object_suffix]
.Lcp_object: call copy_string
    lea rdi, [rip + cross_binary]
    lea rsi, [rip + cross_directory]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + binary_suffix]
    cmp byte ptr [rip + test_mode], 0
    je .Lcp_binary
    lea rsi, [rip + cross_test_suffix]
.Lcp_binary: call copy_string
    add rsp, 8
    ret
/* Select fixed Linux cross tools; macOS cross target needs an Apple SDK.
 * EAX=0 success; failure exits before filesystem writes. Stack:8. */
cross_tools:
    cmp byte ptr [rip + package_link], 0
    jne .Lct_sysroot
    sub rsp, 8
    lea rdi, [rip + package_target]
    lea rsi, [rip + target_macos_x86]
    call streq
    test eax, eax
    jnz .Lct_unsupported
    lea rsi, [rip + target_windows_x86]
    call streq
    test eax, eax
    jnz .Lct_unsupported
    lea rsi, [rip + target_windows_arm]
    call streq
    test eax, eax
    jnz .Lct_unsupported
    lea rdi, [rip + package_target]
    lea rsi, [rip + target_macos]
    call streq
    test eax, eax
    jnz .Lct_sdk
    lea rax, [rip + cross_x86_as]
    lea rdx, [rip + cross_x86_ld]
    lea rdi, [rip + package_target]
    lea rsi, [rip + target_x86]
    push rax
    push rdx
    call streq
    pop rdx
    pop rcx
    test eax, eax
    jnz .Lct_store
    lea rcx, [rip + cross_arm_as]
    lea rdx, [rip + cross_arm_ld]
    lea rsi, [rip + target_arm]
    push rcx
    push rdx
    call streq
    pop rdx
    pop rcx
    test eax, eax
    jnz .Lct_store
    lea rcx, [rip + cross_riscv_as]
    lea rdx, [rip + cross_riscv_ld]
.Lct_store:
    mov [rip + cross_as], rcx
    mov [rip + cross_ld], rdx
    mov rdi, rcx
    mov esi, 1
    mov eax, SYS_access
    syscall
    test rax, rax
    js .Lct_missing
    mov rdi, [rip + cross_ld]
    mov esi, 1
    mov eax, SYS_access
    syscall
    test rax, rax
    js .Lct_missing
    cmp byte ptr [rip + package_link], 0
    jne .Lct_sysroot
    add rsp, 8
    ret
.Lct_unsupported:
    lea rdi, [rip + cross_unsupported_error]
    mov esi, 2
    jmp die
.Lct_sdk:
    lea rdi, [rip + cross_sdk_error]
    mov esi, 2
    jmp die
.Lct_sysroot:
    lea rdi, [rip + cross_sysroot_error]
    mov esi, 2
    jmp die
.Lct_missing:
    lea rdi, [rip + cross_tools_error]
    mov esi, 127
    jmp die
/* Selected standalone build. Stack:8 plus callees; stage capacity64/96/96.
 * Validates tools before locks/dirs. Atomic binary rename preserves old output
 * on assembler/linker failure. Existing directory safety limits also apply. */
cross_build_project:
    push r12
    call cross_tools
    call verify_project_dependencies
    call cross_paths
    lea rdi, [rip + build_dir]
    call make_safe_dir
    test rax, rax
    js build_directory_error
    lea rdi, [rip + cross_directory]
    call make_safe_dir
    test rax, rax
    js build_directory_error
    lea rdi, [rip + stage_dir]
    lea rsi, [rip + cross_directory]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + cross_stage_suffix]
    call copy_string
    mov r12, rax
    mov eax, SYS_getpid
    syscall
    mov rdi, rax
    lea rsi, [rip + number_buffer + 31]
    call unsigned_decimal
    mov rdi, r12
    mov rsi, rax
    call copy_string
    mov eax, SYS_mkdir
    lea rdi, [rip + stage_dir]
    mov esi, 448
    syscall
    test rax, rax
    js build_directory_error
    lea rdi, [rip + stage_object]
    lea rsi, [rip + stage_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + object_suffix]
    call copy_string
    lea rdi, [rip + stage_binary]
    lea rsi, [rip + stage_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + binary_suffix]
    call copy_string
    mov rax, [rip + cross_as]
    mov [rip + child_argv], rax
    lea rax, [rip + arg_I]
    mov [rip + child_argv + 8], rax
    lea rax, [rip + dependency_packages_root]
    mov [rip + child_argv + 16], rax
    lea rax, [rip + arg_o]
    mov [rip + child_argv + 24], rax
    lea rax, [rip + stage_object]
    mov [rip + child_argv + 32], rax
    lea rax, [rip + package_source]
    cmp byte ptr [rip + test_mode], 0
    je .Lcb_source
    lea rax, [rip + package_test]
.Lcb_source:
    mov [rip + child_argv + 40], rax
    mov qword ptr [rip + child_argv + 48], 0
    lea rdi, [rip + package_target]
    lea rsi, [rip + target_riscv]
    call streq
    test eax, eax
    jz .Lcb_gnu_args
    lea rax, [rip + cross_riscv_arch]
    mov [rip + child_argv + 48], rax
    lea rax, [rip + cross_riscv_abi]
    mov [rip + child_argv + 56], rax
    mov qword ptr [rip + child_argv + 64], 0
.Lcb_gnu_args:
    mov rdi, [rip + cross_as]
    lea rsi, [rip + child_argv]
    call spawn_wait
    test eax, eax
    jnz build_child_error
    mov rax, [rip + cross_ld]
    mov [rip + child_argv], rax
    lea rax, [rip + arg_z]
    mov [rip + child_argv + 8], rax
    lea rax, [rip + noexecstack]
    mov [rip + child_argv + 16], rax
    lea rax, [rip + arg_o]
    mov [rip + child_argv + 24], rax
    lea rax, [rip + stage_binary]
    mov [rip + child_argv + 32], rax
    lea rax, [rip + stage_object]
    mov [rip + child_argv + 40], rax
    mov qword ptr [rip + child_argv + 48], 0
    mov rdi, [rip + cross_ld]
    lea rsi, [rip + child_argv]
    call spawn_wait
    test eax, eax
    jnz build_child_error
    mov eax, SYS_rename
    lea rdi, [rip + stage_object]
    lea rsi, [rip + cross_object]
    syscall
    test rax, rax
    js build_io_error
    mov eax, SYS_rename
    lea rdi, [rip + stage_binary]
    lea rsi, [rip + cross_binary]
    syscall
    test rax, rax
    js build_io_error
    call cleanup_stage
    call release_dependency_lock
    pop r12
    ret
/* Report actual selected path. Test --no-run explicitly records no execution. */
project_build_report:
    lea rdi, [rip + package_target]
    call validate_target
    test eax, eax
    jz .Lbr_cross
    lea rdi, [rip + build_text]
    lea rsi, [rip + build_json]
    jmp report
.Lbr_cross:
    call cross_paths
    lea rdi, [rip + cross_binary]
    jmp .Lbr_path
project_test_build_report:
    lea rdi, [rip + package_target]
    call validate_target
    test eax, eax
    jz .Lbr_test_cross
    lea rdi, [rip + test_output]
    jmp .Lbr_path
.Lbr_test_cross:
    call cross_paths
    lea rdi, [rip + cross_binary]
.Lbr_path:
    push rdi
    cmp byte ptr [rip + json_mode], 0
    jne .Lbr_json
    lea rdi, [rip + cross_built]
    call out
    pop rdi
    call out
    lea rdi, [rip + newline]
    call out
    jmp .Lbr_done
.Lbr_json:
    lea rdi, [rip + cross_json]
    call out
    pop rdi
    call registry_json_string
    lea rdi, [rip + cross_json_end]
    cmp byte ptr [rip + no_run], 0
    je .Lbr_end
    lea rdi, [rip + cross_json_not_run]
.Lbr_end: call out
.Lbr_done:
    cmp byte ptr [rip + no_run], 0
    jne exit_ok
    ret
/* Clean only selected files. Existing parent and selected directory must be
 * real directories; final symlinks are unlinked, never followed. */
cross_clean:
    lea rdi, [rip + build_dir]
    call cross_require_directory
    test eax, eax
    jz .Lcc_done
    call cross_paths
    lea rdi, [rip + cross_directory]
    call cross_require_directory
    test eax, eax
    jz .Lcc_done
    lea rdi, [rip + cross_binary]
    call clean_file
    lea rdi, [rip + cross_object]
    call clean_file
    mov byte ptr [rip + test_mode], 1
    call cross_paths
    lea rdi, [rip + cross_binary]
    call clean_file
    lea rdi, [rip + cross_object]
    call clean_file
    mov eax, SYS_rmdir
    lea rdi, [rip + cross_directory]
    syscall
    test rax, rax
    jz .Lcc_done
    cmp rax, -39
    jne .Lclean_error
.Lcc_done:
    lea rdi, [rip + clean_text]
    lea rsi, [rip + clean_json]
    call report
    jmp exit_ok
/* RDI=path. EAX=1 existing directory,0 ENOENT; other cases fail clean. */
cross_require_directory:
    mov eax, SYS_lstat
    lea rsi, [rip + stat_buffer]
    syscall
    cmp rax, -2
    je .Lcr_absent
    test rax, rax
    js .Lclean_error
    mov eax, [rip + stat_buffer + 24]
    and eax, 61440
    cmp eax, 16384
    jne .Lclean_error
    mov eax, 1
    ret
.Lcr_absent: xor eax, eax
    ret
.section .rodata
cross_riscv_arch: .asciz "-march=rv64i"
cross_riscv_abi: .asciz "-mabi=lp64"
opt_no_run: .asciz "--no-run"
cross_build_prefix: .asciz "build/"
cross_stage_suffix: .asciz "/.asm-stage-"
cross_test_suffix: .asciz "/test"
cross_test_object_suffix: .asciz "/test.o"
cross_x86_as: .asciz "/usr/bin/x86_64-linux-gnu-as"
cross_x86_ld: .asciz "/usr/bin/x86_64-linux-gnu-ld"
cross_arm_as: .asciz "/usr/bin/aarch64-linux-gnu-as"
cross_arm_ld: .asciz "/usr/bin/aarch64-linux-gnu-ld"
cross_riscv_as: .asciz "/usr/bin/riscv64-linux-gnu-as"
cross_riscv_ld: .asciz "/usr/bin/riscv64-linux-gnu-ld"
cross_template_error: .asciz "new and init require the native host target; create target-specific sources in an existing project"
cross_execute_error: .asciz "cannot execute a foreign target; use build or test --no-run and run it on its declared host"
cross_unsupported_error: .asciz "selected target has no build toolchain contract; build it on a qualified native host"
cross_sdk_error: .asciz "aarch64-macos requires an Apple SDK and native macOS host; build it on Apple Silicon macOS"
cross_sysroot_error: .asciz "cross-target link=c requires an explicit sysroot contract; build on the native target host"
cross_tools_error: .asciz "selected cross tools are unavailable; install GNU target binutils in /usr/bin, or Homebrew llvm and lld on macOS"
cross_built: .asciz "Built "
cross_json: .asciz "{\"ok\":true,\"artifact\":"
cross_json_end: .asciz "}\n"
cross_json_not_run: .asciz ",\"executed\":false}\n"
.section .bss
.balign 8
project_requested_target: .skip 8
project_target_mask: .skip 8
allow_no_run: .skip 1
no_run: .skip 1
.balign 8
cross_as: .skip 8
cross_ld: .skip 8
cross_directory: .skip 96
cross_object: .skip 96
cross_binary: .skip 96
