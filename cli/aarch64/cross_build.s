/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Explicit selected-target standalone builds. No shell or emulator is used.
 * Strings are bounded by the manifest parser. Owned path buffers are 96 bytes;
 * canonical target names and fixed suffixes fit within 72 bytes including NUL.
 * Returning routines preserve x19-x24. Typed adapters use the native platform
 * ABI; helper calls use the CLI ABI documented in platform.inc. */
.equ CROSS_MACOS, 0
.section .text
/* x0=terminated target. x9=canonical static pointer, or zero. Stack:16.
 * Recognizes seven canonical targets and the native host alias only. */
project_canonical_target:
    ARM_SAVE x19
    mov x19, x0
    ARM_ADDR x1, host_target_alias
    ARM_CALL streq
    tst w9, w9
    b.eq .Lpc_canonical
    ARM_ADDR x9, host_target
    b .Lpc_done
.Lpc_canonical:
    ARM_ADDR x1, target_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_x86
    mov x0, x19
    ARM_ADDR x1, target_arm
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_arm
    mov x0, x19
    ARM_ADDR x1, target_riscv
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_riscv
    mov x0, x19
    ARM_ADDR x1, target_macos
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_macos
    mov x0, x19
    ARM_ADDR x1, target_macos_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_macos_x86
    mov x0, x19
    ARM_ADDR x1, target_windows_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_windows_x86
    mov x0, x19
    ARM_ADDR x1, target_windows_arm
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpc_windows_arm
    b .Lpc_done
.Lpc_macos:
    ARM_ADDR x9, target_macos
    b .Lpc_done
.Lpc_x86:
    ARM_ADDR x9, target_x86
    b .Lpc_done
.Lpc_arm:
    ARM_ADDR x9, target_arm
    b .Lpc_done
.Lpc_riscv:
    ARM_ADDR x9, target_riscv
    b .Lpc_done
.Lpc_macos_x86:
    ARM_ADDR x9, target_macos_x86
    b .Lpc_done
.Lpc_windows_x86:
    ARM_ADDR x9, target_windows_x86
    b .Lpc_done
.Lpc_windows_arm:
    ARM_ADDR x9, target_windows_arm
.Lpc_done:
    ARM_RESTORE x19
    ret
/* x0=argv target. w9=1/0. Stores a static pointer only on success. */
project_set_target:
    ARM_CALL project_canonical_target
    tst x9, x9
    b.eq .Lps_done
    ARM_ADDR x16, project_requested_target
    str x9, [x16]
    ARM_IMM w9, 1
.Lps_done: ret
/* x0=manifest target. w9=selected match. Canonicalizes package_target on
 * success. Stack:16; borrows argv/static selected pointer, modifies no files. */
project_target_matches:
    ARM_CALL project_canonical_target
    tst x9, x9
    b.eq .Lpm_done
    ARM_SAVE x9
    mov x0, x9
    ARM_ADDR x16, project_requested_target
    ldr x1, [x16]
    tst x1, x1
    b.ne .Lpm_compare
    ARM_ADDR x1, host_target
.Lpm_compare:
    ARM_CALL streq
    ARM_RESTORE x1
    tst w9, w9
    b.eq .Lpm_done
    ARM_ADDR x0, package_target
    ARM_CALL copy_string
    ARM_IMM w9, 1
.Lpm_done: ret
/* x0=canonical target. w9=declared 1/0. Mask uses parser table bits (4 through 256).
 * Legacy form compares the selected canonical package_target. Stack:16. */
project_declares_target:
    ARM_ADDR x16, project_target_mask
    ldr w2, [x16]
    tst w2, w2
    b.eq .Lpd_legacy
    ARM_SAVE x19
    mov x19, x0
    ARM_ADDR x1, target_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_x86
    mov x0, x19
    ARM_ADDR x1, target_arm
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_arm
    mov x0, x19
    ARM_ADDR x1, target_riscv
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_riscv
    mov x0, x19
    ARM_ADDR x1, target_macos
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_macos
    mov x0, x19
    ARM_ADDR x1, target_macos_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_macos_x86
    mov x0, x19
    ARM_ADDR x1, target_windows_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_windows_x86
    mov x0, x19
    ARM_ADDR x1, target_windows_arm
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpd_windows_arm
    b .Lpd_return
.Lpd_macos:
    ARM_IMM w9, 32
    b .Lpd_mask
.Lpd_macos_x86:
    ARM_IMM w9, 64
    b .Lpd_mask
.Lpd_windows_x86:
    ARM_IMM w9, 128
    b .Lpd_mask
.Lpd_windows_arm:
    ARM_IMM w9, 256
    b .Lpd_mask

.Lpd_x86:
    ARM_IMM w9, 4
    b .Lpd_mask
.Lpd_arm:
    ARM_IMM w9, 8
    b .Lpd_mask
.Lpd_riscv:
    ARM_IMM w9, 16
.Lpd_mask:
    ARM_ADDR x16, project_target_mask
    ldr w11, [x16]
    tst w9, w11
    cset w9, ne
    and w9, w9, #255
.Lpd_return:
    ARM_RESTORE x19
    ret
.Lpd_legacy:
    ARM_ADDR x1, package_target
    b streq
project_template_check:
    ARM_ADDR x16, project_requested_target
    ldr x0, [x16]
    tst x0, x0
    b.eq .Lpt_done
    ARM_CALL validate_target
    tst w9, w9
    b.eq .Lpt_error
.Lpt_done: ret
.Lpt_error:
    ARM_ADDR x0, cross_template_error
    ARM_IMM w1, 2
    b die
/* Refuse execution before dependency/cache/output mutation. */
project_execution_check:
    ARM_ADDR x0, package_target
    ARM_CALL validate_target
    tst w9, w9
    b.ne .Lpe_done
    ARM_ADDR x16, run_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lpe_error
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lpe_done
    ARM_ADDR x16, no_run
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lpe_error
.Lpe_done: ret
.Lpe_error:
    ARM_ADDR x0, cross_execute_error
    ARM_IMM w1, 2
    b die
/* Build canonical selected directory and four artifact paths. No syscalls.
 * Scratch:caller-saved. Stack:16 for alignment. */
cross_paths:
    sub sp, sp, #16
    ARM_ADDR x0, cross_directory
    ARM_ADDR x1, cross_build_prefix
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, package_target
    ARM_CALL copy_string
    ARM_ADDR x0, cross_object
    ARM_ADDR x1, cross_directory
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, object_suffix
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lcp_object
    ARM_ADDR x1, cross_test_object_suffix
.Lcp_object:
    ARM_CALL copy_string
    ARM_ADDR x0, cross_binary
    ARM_ADDR x1, cross_directory
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, binary_suffix
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lcp_binary
    ARM_ADDR x1, cross_test_suffix
.Lcp_binary:
    ARM_CALL copy_string
    add sp, sp, #16
    ret
/* Select fixed Linux cross tools; macOS cross target needs an Apple SDK.
 * w9=0 success; failure exits before filesystem writes. Stack:16. */
cross_tools:
    ARM_ADDR x16, package_link
    ldrb w10, [x16]
    cbnz w10, .Lct_sysroot
.if CROSS_MACOS
    b cross_macos_tools
.endif
    sub sp, sp, #16
    ARM_ADDR x0, package_target
    ARM_ADDR x1, target_macos_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lct_unsupported
    ARM_ADDR x1, target_windows_x86
    ARM_CALL streq
    tst w9, w9
    b.ne .Lct_unsupported
    ARM_ADDR x1, target_windows_arm
    ARM_CALL streq
    tst w9, w9
    b.ne .Lct_unsupported
    ARM_ADDR x0, package_target
    ARM_ADDR x1, target_macos
    ARM_CALL streq
    tst w9, w9
    b.ne .Lct_sdk
    ARM_ADDR x9, cross_x86_as
    ARM_ADDR x2, cross_x86_ld
    ARM_ADDR x0, package_target
    ARM_ADDR x1, target_x86
    ARM_SAVE x9
    ARM_SAVE x2
    ARM_CALL streq
    ARM_RESTORE x2
    ARM_RESTORE x3
    tst w9, w9
    b.ne .Lct_store
    ARM_ADDR x3, cross_arm_as
    ARM_ADDR x2, cross_arm_ld
    ARM_ADDR x1, target_arm
    ARM_SAVE x3
    ARM_SAVE x2
    ARM_CALL streq
    ARM_RESTORE x2
    ARM_RESTORE x3
    tst w9, w9
    b.ne .Lct_store
    ARM_ADDR x3, cross_riscv_as
    ARM_ADDR x2, cross_riscv_ld
.Lct_store:
    ARM_ADDR x16, cross_as
    str x3, [x16]
    ARM_ADDR x16, cross_ld
    str x2, [x16]
    mov x0, x3
    ARM_IMM w1, 1
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Lct_missing
    ARM_ADDR x16, cross_ld
    ldr x0, [x16]
    ARM_IMM w1, 1
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Lct_missing
    ARM_ADDR x16, package_link
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lct_sysroot
    add sp, sp, #16
    ret
.Lct_unsupported:
    ARM_ADDR x0, cross_unsupported_error
    ARM_IMM w1, 2
    b die
.Lct_sdk:
    ARM_ADDR x0, cross_sdk_error
    ARM_IMM w1, 2
    b die
.Lct_sysroot:
    ARM_ADDR x0, cross_sysroot_error
    ARM_IMM w1, 2
    b die
.Lct_missing:
    ARM_ADDR x0, cross_tools_error
    ARM_IMM w1, 127
    b die
/* Selected standalone build. Stack:16 plus callees; stage capacity64/96/96.
 * Validates tools before locks/dirs. Atomic binary rename preserves old output
 * on assembler/linker failure. Existing directory safety limits also apply. */
cross_build_project:
    ARM_SAVE x21
    ARM_CALL cross_tools
    ARM_CALL verify_project_dependencies
    ARM_CALL cross_paths
    ARM_ADDR x0, build_dir
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi build_directory_error
    ARM_ADDR x0, cross_directory
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi build_directory_error
    ARM_ADDR x0, stage_dir
    ARM_ADDR x1, cross_directory
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, cross_stage_suffix
    ARM_CALL copy_string
    mov x21, x9
    ARM_CALL arm_getpid
    mov x0, x9
    ARM_ADDR x1, number_buffer + 31
    ARM_CALL unsigned_decimal
    mov x0, x21
    mov x1, x9
    ARM_CALL copy_string
    ARM_ADDR x0, stage_dir
    ARM_IMM w1, 448
    ARM_CALL arm_mkdir
    tst x9, x9
    b.mi build_directory_error
    ARM_ADDR x0, stage_object
    ARM_ADDR x1, stage_dir
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, object_suffix
    ARM_CALL copy_string
    ARM_ADDR x0, stage_binary
    ARM_ADDR x1, stage_dir
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, binary_suffix
    ARM_CALL copy_string
.if CROSS_MACOS
    ARM_CALL cross_macos_assemble
    cbnz w9, build_child_error
    ARM_CALL cross_macos_link
    cbnz w9, build_child_error
.else
    ARM_ADDR x16, cross_as
    ldr x9, [x16]
    ARM_ADDR x16, child_argv
    str x9, [x16]
    ARM_ADDR x9, arg_I
    ARM_ADDR x16, child_argv + 8
    str x9, [x16]
    ARM_ADDR x9, dependency_packages_root
    ARM_ADDR x16, child_argv + 16
    str x9, [x16]
    ARM_ADDR x9, arg_o
    ARM_ADDR x16, child_argv + 24
    str x9, [x16]
    ARM_ADDR x9, stage_object
    ARM_ADDR x16, child_argv + 32
    str x9, [x16]
    ARM_ADDR x9, package_source
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lcb_source
    ARM_ADDR x9, package_test
.Lcb_source:
    ARM_ADDR x16, child_argv + 40
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, child_argv + 48
    str x10, [x16]
    ARM_ADDR x0, package_target
    ARM_ADDR x1, target_riscv
    ARM_CALL streq
    cbz w9, .Lcb_gnu_args
    ARM_ADDR x10, cross_riscv_arch
    ARM_ADDR x16, child_argv + 48
    str x10, [x16]
    ARM_ADDR x10, cross_riscv_abi
    ARM_ADDR x16, child_argv + 56
    str x10, [x16]
    ARM_ADDR x16, child_argv + 64
    str xzr, [x16]
.Lcb_gnu_args:
    ARM_ADDR x16, cross_as
    ldr x0, [x16]
    ARM_ADDR x1, child_argv
    ARM_CALL spawn_wait
    tst w9, w9
    b.ne build_child_error
    ARM_ADDR x16, cross_ld
    ldr x9, [x16]
    ARM_ADDR x16, child_argv
    str x9, [x16]
    ARM_ADDR x9, arg_z
    ARM_ADDR x16, child_argv + 8
    str x9, [x16]
    ARM_ADDR x9, noexecstack
    ARM_ADDR x16, child_argv + 16
    str x9, [x16]
    ARM_ADDR x9, arg_o
    ARM_ADDR x16, child_argv + 24
    str x9, [x16]
    ARM_ADDR x9, stage_binary
    ARM_ADDR x16, child_argv + 32
    str x9, [x16]
    ARM_ADDR x9, stage_object
    ARM_ADDR x16, child_argv + 40
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, child_argv + 48
    str x10, [x16]
    ARM_ADDR x16, cross_ld
    ldr x0, [x16]
    ARM_ADDR x1, child_argv
    ARM_CALL spawn_wait
    tst w9, w9
    b.ne build_child_error
.endif
    ARM_ADDR x0, stage_object
    ARM_ADDR x1, cross_object
    ARM_CALL arm_rename
    tst x9, x9
    b.mi build_io_error
    ARM_ADDR x0, stage_binary
    ARM_ADDR x1, cross_binary
    ARM_CALL arm_rename
    tst x9, x9
    b.mi build_io_error
    ARM_CALL cleanup_stage
    ARM_CALL release_dependency_lock
    ARM_RESTORE x21
    ret
/* Report actual selected path. Test --no-run explicitly records no execution. */
project_build_report:
    ARM_ADDR x0, package_target
    ARM_CALL validate_target
    tst w9, w9
    b.eq .Lbr_cross
    ARM_ADDR x0, build_text
    ARM_ADDR x1, build_json
    b report
.Lbr_cross:
    ARM_CALL cross_paths
    ARM_ADDR x0, cross_binary
    b .Lbr_path
project_test_build_report:
    ARM_ADDR x0, package_target
    ARM_CALL validate_target
    tst w9, w9
    b.eq .Lbr_test_cross
    ARM_ADDR x0, test_output
    b .Lbr_path
.Lbr_test_cross:
    ARM_CALL cross_paths
    ARM_ADDR x0, cross_binary
.Lbr_path:
    ARM_SAVE x0
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lbr_json
    ARM_ADDR x0, cross_built
    ARM_CALL out
    ARM_RESTORE x0
    ARM_CALL out
    ARM_ADDR x0, newline
    ARM_CALL out
    b .Lbr_done
.Lbr_json:
    ARM_ADDR x0, cross_json
    ARM_CALL out
    ARM_RESTORE x0
    ARM_CALL registry_json_string
    ARM_ADDR x0, cross_json_end
    ARM_ADDR x16, no_run
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lbr_end
    ARM_ADDR x0, cross_json_not_run
.Lbr_end:
    ARM_CALL out
.Lbr_done:
    ARM_ADDR x16, no_run
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne exit_ok
    ret
/* Clean only selected files. Existing parent and selected directory must be
 * real directories; final symlinks are unlinked, never followed. */
cross_clean:
    ARM_ADDR x0, build_dir
    ARM_CALL cross_require_directory
    tst w9, w9
    b.eq .Lcc_done
    ARM_CALL cross_paths
    ARM_ADDR x0, cross_directory
    ARM_CALL cross_require_directory
    tst w9, w9
    b.eq .Lcc_done
    ARM_ADDR x0, cross_binary
    ARM_CALL clean_file
    ARM_ADDR x0, cross_object
    ARM_CALL clean_file
    ARM_IMM w10, 1
    ARM_ADDR x16, test_mode
    strb w10, [x16]
    ARM_CALL cross_paths
    ARM_ADDR x0, cross_binary
    ARM_CALL clean_file
    ARM_ADDR x0, cross_object
    ARM_CALL clean_file
    ARM_ADDR x0, cross_directory
    ARM_CALL arm_rmdir
    tst x9, x9
    b.eq .Lcc_done
    ARM_IMM x11, -39
    cmp x9, x11
    b.ne .Lclean_error
.Lcc_done:
    ARM_ADDR x0, clean_text
    ARM_ADDR x1, clean_json
    ARM_CALL report
    b exit_ok
/* x0=path. w9=1 existing directory,0 ENOENT; other cases fail clean. */
cross_require_directory:
    ARM_ADDR x1, stat_buffer
    ARM_CALL arm_lstat
    ARM_IMM x11, -2
    cmp x9, x11
    b.eq .Lcr_absent
    tst x9, x9
    b.mi .Lclean_error
    ARM_ADDR x16, stat_buffer + 16
    ldr w9, [x16]
    ARM_IMM w11, 61440
    and w9, w9, w11
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne .Lclean_error
    ARM_IMM w9, 1
    ret
.Lcr_absent:
    mov w9, #0
    ret
/* macOS uses one fixed LLVM installation for Linux ELF outputs. The compiler
 * receives no ambient config and uses an explicit triple. No Apple SDK is
 * needed for standalone Linux assembly. All routines preserve x19-x24.
 * x0-x17/NZCV scratch; stack consists only of ARM_CALL frames. */
cross_macos_tools:
    ARM_ADDR x0, package_target
    ARM_ADDR x1, target_x86
    ARM_CALL streq
    cbnz w9, .Lcm_x86
    ARM_ADDR x1, target_arm
    ARM_CALL streq
    cbnz w9, .Lcm_arm
    ARM_ADDR x1, target_riscv
    ARM_CALL streq
    cbz w9, .Lct_unsupported
    ARM_ADDR x0, cross_llvm_riscv
    ARM_ADDR x1, cross_emulation_riscv
    b .Lcm_set
.Lcm_x86:
    ARM_ADDR x0, cross_llvm_x86
    ARM_ADDR x1, cross_emulation_x86
    b .Lcm_set
.Lcm_arm:
    ARM_ADDR x0, cross_llvm_arm
    ARM_ADDR x1, cross_emulation_arm
.Lcm_set:
    ARM_ADDR x16, cross_triple
    str x0, [x16]
    ARM_ADDR x16, cross_emulation
    str x1, [x16]
    ARM_ADDR x0, cross_llvm_clang
    ARM_ADDR x16, cross_as
    str x0, [x16]
    mov w1, #1
    ARM_CALL arm_access
    tbnz x9, #63, .Lct_missing
    ARM_ADDR x0, cross_llvm_ld
    ARM_ADDR x16, cross_ld
    str x0, [x16]
    mov w1, #1
    ARM_CALL arm_access
    tbnz x9, #63, .Lct_missing
    ARM_ADDR x16, package_link
    ldrb w10, [x16]
    cbnz w10, .Lct_sysroot
    ret
cross_macos_assemble:
    ARM_ADDR x0, child_argv
    ARM_ADDR x10, cross_llvm_clang
    str x10, [x0]
    ARM_ADDR x10, cross_no_config
    str x10, [x0, #8]
    ARM_ADDR x10, cross_target_option
    str x10, [x0, #16]
    ARM_ADDR x16, cross_triple
    ldr x10, [x16]
    str x10, [x0, #24]
    ARM_ADDR x10, cross_compile_only
    str x10, [x0, #32]
    ARM_ADDR x10, arg_I
    str x10, [x0, #40]
    ARM_ADDR x10, dependency_packages_root
    str x10, [x0, #48]
    ARM_ADDR x10, arg_o
    str x10, [x0, #56]
    ARM_ADDR x10, stage_object
    str x10, [x0, #64]
    ARM_ADDR x10, package_source
    ARM_ADDR x16, test_mode
    ldrb w11, [x16]
    cbz w11, .Lcma_source
    ARM_ADDR x10, package_test
.Lcma_source:
    str x10, [x0, #72]
    str xzr, [x0, #80]
    ARM_SAVE x0
    ARM_ADDR x0, package_target
    ARM_ADDR x1, target_riscv
    ARM_CALL streq
    ARM_RESTORE x0
    cbz w9, .Lcma_args
    ARM_ADDR x10, cross_riscv_arch
    str x10, [x0, #80]
    ARM_ADDR x10, cross_riscv_abi
    str x10, [x0, #88]
    str xzr, [x0, #96]
.Lcma_args:
    mov x1, x0
    ARM_ADDR x0, cross_llvm_clang
    b spawn_wait
cross_macos_link:
    ARM_ADDR x0, child_argv
    ARM_ADDR x10, cross_llvm_ld
    str x10, [x0]
    ARM_ADDR x10, cross_emulation_option
    str x10, [x0, #8]
    ARM_ADDR x16, cross_emulation
    ldr x10, [x16]
    str x10, [x0, #16]
    ARM_ADDR x10, cross_elf_z
    str x10, [x0, #24]
    ARM_ADDR x10, cross_elf_noexecstack
    str x10, [x0, #32]
    ARM_ADDR x10, arg_o
    str x10, [x0, #40]
    ARM_ADDR x10, stage_binary
    str x10, [x0, #48]
    ARM_ADDR x10, stage_object
    str x10, [x0, #56]
    str xzr, [x0, #64]
    mov x1, x0
    ARM_ADDR x0, cross_llvm_ld
    b spawn_wait

.section .rodata
cross_llvm_clang: .asciz "/opt/homebrew/opt/llvm/bin/clang"
cross_llvm_ld: .asciz "/opt/homebrew/opt/lld/bin/ld.lld"
cross_llvm_x86: .asciz "x86_64-linux-gnu"
cross_llvm_arm: .ascii "aarch64-"
    .asciz "linux-gnu"
cross_llvm_riscv: .asciz "riscv64-linux-gnu"
cross_emulation_x86: .asciz "elf_x86_64"
cross_emulation_arm: .asciz "aarch64linux"
cross_emulation_riscv: .asciz "elf64lriscv"
cross_no_config: .asciz "--no-default-config"
cross_target_option: .asciz "-target"
cross_compile_only: .asciz "-c"
cross_emulation_option: .asciz "-m"
cross_elf_z: .asciz "-z"
cross_elf_noexecstack: .asciz "noexecstack"
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
cross_triple: .skip 8
cross_emulation: .skip 8
cross_as: .skip 8
cross_ld: .skip 8
cross_directory: .skip 96
cross_object: .skip 96
cross_binary: .skip 96
