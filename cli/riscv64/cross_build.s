/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/cross_build.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Explicit selected-target standalone builds. No shell or emulator is used.
 * Strings are bounded by the manifest parser. Owned path buffers are 96 bytes;
 * canonical target names and fixed suffixes fit within 72 bytes including NUL.
 * Returning routines preserve s0-s5. Typed adapters use the native platform
 * ABI; helper calls use the CLI ABI documented in platform.inc. */
.equ CROSS_MACOS, 0
.section .text
/* a0=terminated target. t0=canonical static pointer, or zero. Stack:16.
 * Recognizes seven canonical targets and the native host alias only. */
project_canonical_target:
    RV_SAVE s0
    mv s0, a0
    RV_ADDR a1, host_target_alias
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpc_canonical
    RV_ADDR t0, host_target
    RV_JUMP .Lpc_done
.Lpc_canonical:
    RV_ADDR a1, target_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_x86
    mv a0, s0
    RV_ADDR a1, target_arm
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_arm
    mv a0, s0
    RV_ADDR a1, target_riscv
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_riscv
    mv a0, s0
    RV_ADDR a1, target_macos
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_macos
    mv a0, s0
    RV_ADDR a1, target_macos_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_macos_x86
    mv a0, s0
    RV_ADDR a1, target_windows_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_windows_x86
    mv a0, s0
    RV_ADDR a1, target_windows_arm
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpc_windows_arm
    RV_JUMP .Lpc_done
.Lpc_macos:
    RV_ADDR t0, target_macos
    RV_JUMP .Lpc_done
.Lpc_x86:
    RV_ADDR t0, target_x86
    RV_JUMP .Lpc_done
.Lpc_arm:
    RV_ADDR t0, target_arm
    RV_JUMP .Lpc_done
.Lpc_riscv:
    RV_ADDR t0, target_riscv
    RV_JUMP .Lpc_done
.Lpc_macos_x86:
    RV_ADDR t0, target_macos_x86
    RV_JUMP .Lpc_done
.Lpc_windows_x86:
    RV_ADDR t0, target_windows_x86
    RV_JUMP .Lpc_done
.Lpc_windows_arm:
    RV_ADDR t0, target_windows_arm
.Lpc_done:
    RV_RESTORE s0
    ret
/* a0=argv target. t0=1/0. Stores a static pointer only on success. */
project_set_target:
    RV_CALL project_canonical_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lps_done
    RV_ADDR s6, project_requested_target
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t0, 1, 32
.Lps_done: ret
/* a0=manifest target. t0=selected match. Canonicalizes package_target on
 * success. Stack:16; borrows argv/static selected pointer, modifies no files. */
project_target_matches:
    RV_CALL project_canonical_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpm_done
    RV_SAVE t0
    mv a0, t0
    RV_ADDR s6, project_requested_target
    mv s8, s6
    RV_LOAD a1, 8
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND ne, .Lpm_compare
    RV_ADDR a1, host_target
.Lpm_compare:
    RV_CALL streq
    RV_RESTORE a1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpm_done
    RV_ADDR a0, package_target
    RV_CALL copy_string
    RV_IMM t0, 1, 32
.Lpm_done: ret
/* a0=canonical target. t0=declared 1/0. Mask uses parser table bits (4 through 256).
 * Legacy form compares the selected canonical package_target. Stack:16. */
project_declares_target:
    RV_ADDR s6, project_target_mask
    mv s8, s6
    RV_LOAD a2, 4
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpd_legacy
    RV_SAVE s0
    mv s0, a0
    RV_ADDR a1, target_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_x86
    mv a0, s0
    RV_ADDR a1, target_arm
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_arm
    mv a0, s0
    RV_ADDR a1, target_riscv
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_riscv
    mv a0, s0
    RV_ADDR a1, target_macos
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_macos
    mv a0, s0
    RV_ADDR a1, target_macos_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_macos_x86
    mv a0, s0
    RV_ADDR a1, target_windows_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_windows_x86
    mv a0, s0
    RV_ADDR a1, target_windows_arm
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpd_windows_arm
    RV_JUMP .Lpd_return
.Lpd_macos:
    RV_IMM t0, 32, 32
    RV_JUMP .Lpd_mask
.Lpd_macos_x86:
    RV_IMM t0, 64, 32
    RV_JUMP .Lpd_mask
.Lpd_windows_x86:
    RV_IMM t0, 128, 32
    RV_JUMP .Lpd_mask
.Lpd_windows_arm:
    RV_IMM t0, 256, 32
    RV_JUMP .Lpd_mask
.Lpd_x86:
    RV_IMM t0, 4, 32
    RV_JUMP .Lpd_mask
.Lpd_arm:
    RV_IMM t0, 8, 32
    RV_JUMP .Lpd_mask
.Lpd_riscv:
    RV_IMM t0, 16, 32
.Lpd_mask:
    RV_ADDR s6, project_target_mask
    mv s8, s6
    RV_LOAD t2, 4
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrv_cset_true_cross_build179
    li t0, 0
    j .Lrv_cset_done_cross_build179
.Lrv_cset_true_cross_build179:
    li t0, 1
.Lrv_cset_done_cross_build179:
    li s10, 255
    and t0, t0, s10
    RV_ZEXT t0
.Lpd_return:
    RV_RESTORE s0
    ret
.Lpd_legacy:
    RV_ADDR a1, package_target
    RV_JUMP streq
project_template_check:
    RV_ADDR s6, project_requested_target
    mv s8, s6
    RV_LOAD a0, 8
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpt_done
    RV_CALL validate_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpt_error
.Lpt_done: ret
.Lpt_error:
    RV_ADDR a0, cross_template_error
    RV_IMM a1, 2, 32
    RV_JUMP die
/* Refuse execution before dependency/cache/output mutation. */
project_execution_check:
    RV_ADDR a0, package_target
    RV_CALL validate_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpe_done
    RV_ADDR s6, run_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpe_error
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpe_done
    RV_ADDR s6, no_run
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpe_error
.Lpe_done: ret
.Lpe_error:
    RV_ADDR a0, cross_execute_error
    RV_IMM a1, 2, 32
    RV_JUMP die
/* Build canonical selected directory and four artifact paths. No syscalls.
 * Scratch:caller-saved. Stack:16 for alignment. */
cross_paths:
    li s10, 16
    sub sp, sp, s10
    RV_ADDR a0, cross_directory
    RV_ADDR a1, cross_build_prefix
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, package_target
    RV_CALL copy_string
    RV_ADDR a0, cross_object
    RV_ADDR a1, cross_directory
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, object_suffix
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lcp_object
    RV_ADDR a1, cross_test_object_suffix
.Lcp_object:
    RV_CALL copy_string
    RV_ADDR a0, cross_binary
    RV_ADDR a1, cross_directory
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, binary_suffix
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lcp_binary
    RV_ADDR a1, cross_test_suffix
.Lcp_binary:
    RV_CALL copy_string
    li s10, 16
    add sp, sp, s10
    ret
/* Select fixed Linux cross tools; macOS cross target needs an Apple SDK.
 * t0=0 success; failure exits before filesystem writes. Stack:16. */
cross_tools:
    RV_ADDR s6, package_link
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_cross_build269
    RV_JUMP .Lct_sysroot
.Lrv_cb_skip_cross_build269:
.if CROSS_MACOS
    RV_JUMP cross_macos_tools
.endif
    li s10, 16
    sub sp, sp, s10
    RV_ADDR a0, package_target
    RV_ADDR a1, target_macos_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lct_unsupported
    RV_ADDR a1, target_windows_x86
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lct_unsupported
    RV_ADDR a1, target_windows_arm
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lct_unsupported
    RV_ADDR a0, package_target
    RV_ADDR a1, target_macos
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lct_sdk
    RV_ADDR t0, cross_x86_as
    RV_ADDR a2, cross_x86_ld
    RV_ADDR a0, package_target
    RV_ADDR a1, target_x86
    RV_SAVE t0
    RV_SAVE a2
    RV_CALL streq
    RV_RESTORE a2
    RV_RESTORE a3
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lct_store
    RV_ADDR a3, cross_arm_as
    RV_ADDR a2, cross_arm_ld
    RV_ADDR a1, target_arm
    RV_SAVE a3
    RV_SAVE a2
    RV_CALL streq
    RV_RESTORE a2
    RV_RESTORE a3
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lct_store
    RV_ADDR a3, cross_riscv_as
    RV_ADDR a2, cross_riscv_ld
.Lct_store:
    RV_ADDR s6, cross_as
    mv s8, s6
    RV_STORE a3, 8
    RV_ADDR s6, cross_ld
    mv s8, s6
    RV_STORE a2, 8
    mv a0, a3
    RV_IMM a1, 1, 32
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lct_missing
    RV_ADDR s6, cross_ld
    mv s8, s6
    RV_LOAD a0, 8
    RV_IMM a1, 1, 32
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lct_missing
    RV_ADDR s6, package_link
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lct_sysroot
    li s10, 16
    add sp, sp, s10
    ret
.Lct_unsupported:
    RV_ADDR a0, cross_unsupported_error
    RV_IMM a1, 2, 32
    RV_JUMP die
.Lct_sdk:
    RV_ADDR a0, cross_sdk_error
    RV_IMM a1, 2, 32
    RV_JUMP die
.Lct_sysroot:
    RV_ADDR a0, cross_sysroot_error
    RV_IMM a1, 2, 32
    RV_JUMP die
.Lct_missing:
    RV_ADDR a0, cross_tools_error
    RV_IMM a1, 127, 32
    RV_JUMP die
/* Selected standalone build. Stack:16 plus callees; stage capacity64/96/96.
 * Validates tools before locks/dirs. Atomic binary rename preserves old output
 * on assembler/linker failure. Existing directory safety limits also apply. */
cross_build_project:
    RV_SAVE s2
    RV_CALL cross_tools
    RV_CALL verify_project_dependencies
    RV_CALL cross_paths
    RV_ADDR a0, build_dir
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_directory_error
    RV_ADDR a0, cross_directory
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_directory_error
    RV_ADDR a0, stage_dir
    RV_ADDR a1, cross_directory
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, cross_stage_suffix
    RV_CALL copy_string
    mv s2, t0
    RV_CALL rv_getpid
    mv a0, t0
    RV_ADDR a1, number_buffer + 31
    RV_CALL unsigned_decimal
    mv a0, s2
    mv a1, t0
    RV_CALL copy_string
    RV_ADDR a0, stage_dir
    RV_IMM a1, 448, 32
    RV_CALL rv_mkdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_directory_error
    RV_ADDR a0, stage_object
    RV_ADDR a1, stage_dir
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, object_suffix
    RV_CALL copy_string
    RV_ADDR a0, stage_binary
    RV_ADDR a1, stage_dir
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, binary_suffix
    RV_CALL copy_string
.if CROSS_MACOS
    RV_CALL cross_macos_assemble
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_cross_build403
    RV_JUMP build_child_error
.Lrv_cb_skip_cross_build403:
    RV_CALL cross_macos_link
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_cross_build405
    RV_JUMP build_child_error
.Lrv_cb_skip_cross_build405:
.else
    RV_ADDR s6, cross_as
    mv s8, s6
    RV_LOAD t0, 8
    RV_ADDR s6, child_argv
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, arg_I
    RV_ADDR s6, child_argv + 8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, dependency_packages_root
    RV_ADDR s6, child_argv + 16
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, arg_o
    RV_ADDR s6, child_argv + 24
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, stage_object
    RV_ADDR s6, child_argv + 32
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, package_source
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lcb_source
    RV_ADDR t0, package_test
.Lcb_source:
    RV_ADDR s6, child_argv + 40
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, child_argv + 48
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR a0, package_target
    RV_ADDR a1, target_riscv
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_cross_build439
    RV_JUMP .Lcb_gnu_args
.Lrv_cb_skip_cross_build439:
    RV_ADDR t1, cross_riscv_arch
    RV_ADDR s6, child_argv + 48
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR t1, cross_riscv_abi
    RV_ADDR s6, child_argv + 56
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, child_argv + 64
    mv s8, s6
    RV_STORE zero, 8
.Lcb_gnu_args:
    RV_ADDR s6, cross_as
    mv s8, s6
    RV_LOAD a0, 8
    RV_ADDR a1, child_argv
    RV_CALL spawn_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, build_child_error
    RV_ADDR s6, cross_ld
    mv s8, s6
    RV_LOAD t0, 8
    RV_ADDR s6, child_argv
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, arg_z
    RV_ADDR s6, child_argv + 8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, noexecstack
    RV_ADDR s6, child_argv + 16
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, arg_o
    RV_ADDR s6, child_argv + 24
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, stage_binary
    RV_ADDR s6, child_argv + 32
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR t0, stage_object
    RV_ADDR s6, child_argv + 40
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, child_argv + 48
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, cross_ld
    mv s8, s6
    RV_LOAD a0, 8
    RV_ADDR a1, child_argv
    RV_CALL spawn_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, build_child_error
.endif
    RV_ADDR a0, stage_object
    RV_ADDR a1, cross_object
    RV_CALL rv_rename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_io_error
    RV_ADDR a0, stage_binary
    RV_ADDR a1, cross_binary
    RV_CALL rv_rename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_io_error
    RV_CALL cleanup_stage
    RV_CALL release_dependency_lock
    RV_RESTORE s2
    ret
/* Report actual selected path. Test --no-run explicitly records no execution. */
project_build_report:
    RV_ADDR a0, package_target
    RV_CALL validate_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lbr_cross
    RV_ADDR a0, build_text
    RV_ADDR a1, build_json
    RV_JUMP report
.Lbr_cross:
    RV_CALL cross_paths
    RV_ADDR a0, cross_binary
    RV_JUMP .Lbr_path
project_test_build_report:
    RV_ADDR a0, package_target
    RV_CALL validate_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lbr_test_cross
    RV_ADDR a0, test_output
    RV_JUMP .Lbr_path
.Lbr_test_cross:
    RV_CALL cross_paths
    RV_ADDR a0, cross_binary
.Lbr_path:
    RV_SAVE a0
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lbr_json
    RV_ADDR a0, cross_built
    RV_CALL out
    RV_RESTORE a0
    RV_CALL out
    RV_ADDR a0, newline
    RV_CALL out
    RV_JUMP .Lbr_done
.Lbr_json:
    RV_ADDR a0, cross_json
    RV_CALL out
    RV_RESTORE a0
    RV_CALL registry_json_string
    RV_ADDR a0, cross_json_end
    RV_ADDR s6, no_run
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lbr_end
    RV_ADDR a0, cross_json_not_run
.Lbr_end:
    RV_CALL out
.Lbr_done:
    RV_ADDR s6, no_run
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, exit_ok
    ret
/* Clean only selected files. Existing parent and selected directory must be
 * real directories; final symlinks are unlinked, never followed. */
cross_clean:
    RV_ADDR a0, build_dir
    RV_CALL cross_require_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lcc_done
    RV_CALL cross_paths
    RV_ADDR a0, cross_directory
    RV_CALL cross_require_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lcc_done
    RV_ADDR a0, cross_binary
    RV_CALL clean_file
    RV_ADDR a0, cross_object
    RV_CALL clean_file
    RV_IMM t1, 1, 32
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL cross_paths
    RV_ADDR a0, cross_binary
    RV_CALL clean_file
    RV_ADDR a0, cross_object
    RV_CALL clean_file
    RV_ADDR a0, cross_directory
    RV_CALL rv_rmdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lcc_done
    RV_IMM t2, -39, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lclean_error
.Lcc_done:
    RV_ADDR a0, clean_text
    RV_ADDR a1, clean_json
    RV_CALL report
    RV_JUMP exit_ok
/* a0=path. t0=1 existing directory,0 ENOENT; other cases fail clean. */
cross_require_directory:
    RV_ADDR a1, stat_buffer
    RV_CALL rv_lstat
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lcr_absent
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lclean_error
    RV_ADDR s6, stat_buffer + 16
    mv s8, s6
    RV_LOAD t0, 4
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lclean_error
    RV_IMM t0, 1, 32
    ret
.Lcr_absent:
    li t0, 0
    RV_ZEXT t0
    ret
/* macOS uses one fixed LLVM installation for Linux ELF outputs. The compiler
 * receives no ambient config and uses an explicit triple. No Apple SDK is
 * needed for standalone Linux assembly. All routines preserve s0-s5.
 * a0-s7/s9 conditions scratch; stack consists only of RV_CALL frames. */
cross_macos_tools:
    RV_ADDR a0, package_target
    RV_ADDR a1, target_x86
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_cross_build621
    RV_JUMP .Lcm_x86
.Lrv_cb_skip_cross_build621:
    RV_ADDR a1, target_arm
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_cross_build624
    RV_JUMP .Lcm_arm
.Lrv_cb_skip_cross_build624:
    RV_ADDR a1, target_riscv
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_cross_build627
    RV_JUMP .Lct_unsupported
.Lrv_cb_skip_cross_build627:
    RV_ADDR a0, cross_llvm_riscv
    RV_ADDR a1, cross_emulation_riscv
    RV_JUMP .Lcm_set
.Lcm_x86:
    RV_ADDR a0, cross_llvm_x86
    RV_ADDR a1, cross_emulation_x86
    RV_JUMP .Lcm_set
.Lcm_arm:
    RV_ADDR a0, cross_llvm_arm
    RV_ADDR a1, cross_emulation_arm
.Lcm_set:
    RV_ADDR s6, cross_triple
    mv s8, s6
    RV_STORE a0, 8
    RV_ADDR s6, cross_emulation
    mv s8, s6
    RV_STORE a1, 8
    RV_ADDR a0, cross_llvm_clang
    RV_ADDR s6, cross_as
    mv s8, s6
    RV_STORE a0, 8
    li a1, 1
    RV_ZEXT a1
    RV_CALL rv_access
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_cross_build648
    RV_JUMP .Lct_missing
.Lrv_tb_skip_cross_build648:
    RV_ADDR a0, cross_llvm_ld
    RV_ADDR s6, cross_ld
    mv s8, s6
    RV_STORE a0, 8
    li a1, 1
    RV_ZEXT a1
    RV_CALL rv_access
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_cross_build654
    RV_JUMP .Lct_missing
.Lrv_tb_skip_cross_build654:
    RV_ADDR s6, package_link
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_cross_build657
    RV_JUMP .Lct_sysroot
.Lrv_cb_skip_cross_build657:
    ret
cross_macos_assemble:
    RV_ADDR a0, child_argv
    RV_ADDR t1, cross_llvm_clang
    mv s8, a0
    RV_STORE t1, 8
    RV_ADDR t1, cross_no_config
    li s10, 8
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, cross_target_option
    li s10, 16
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR s6, cross_triple
    mv s8, s6
    RV_LOAD t1, 8
    li s10, 24
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, cross_compile_only
    li s10, 32
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, arg_I
    li s10, 40
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, dependency_packages_root
    li s10, 48
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, arg_o
    li s10, 56
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, stage_object
    li s10, 64
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, package_source
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_LOAD t2, 1
    mv s8, t2
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_cross_build683
    RV_JUMP .Lcma_source
.Lrv_cb_skip_cross_build683:
    RV_ADDR t1, package_test
.Lcma_source:
    li s10, 72
    add s8, a0, s10
    RV_STORE t1, 8
    li s10, 80
    add s8, a0, s10
    RV_STORE zero, 8
    RV_SAVE a0
    RV_ADDR a0, package_target
    RV_ADDR a1, target_riscv
    RV_CALL streq
    RV_RESTORE a0
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_cross_build693
    RV_JUMP .Lcma_args
.Lrv_cb_skip_cross_build693:
    RV_ADDR t1, cross_riscv_arch
    li s10, 80
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, cross_riscv_abi
    li s10, 88
    add s8, a0, s10
    RV_STORE t1, 8
    li s10, 96
    add s8, a0, s10
    RV_STORE zero, 8
.Lcma_args:
    mv a1, a0
    RV_ADDR a0, cross_llvm_clang
    RV_JUMP spawn_wait
cross_macos_link:
    RV_ADDR a0, child_argv
    RV_ADDR t1, cross_llvm_ld
    mv s8, a0
    RV_STORE t1, 8
    RV_ADDR t1, cross_emulation_option
    li s10, 8
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR s6, cross_emulation
    mv s8, s6
    RV_LOAD t1, 8
    li s10, 16
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, cross_elf_z
    li s10, 24
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, cross_elf_noexecstack
    li s10, 32
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, arg_o
    li s10, 40
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, stage_binary
    li s10, 48
    add s8, a0, s10
    RV_STORE t1, 8
    RV_ADDR t1, stage_object
    li s10, 56
    add s8, a0, s10
    RV_STORE t1, 8
    li s10, 64
    add s8, a0, s10
    RV_STORE zero, 8
    mv a1, a0
    RV_ADDR a0, cross_llvm_ld
    RV_JUMP spawn_wait
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
