/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/self_update.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global cmd_self, self_update_cleanup
/* Manual updates operate only on HOME/.local/bin/asm. An open directory and
 * nonblocking advisory lock coordinate asm invocations. The directory and
 * executable must belong to the calling UID, without group/other write bits.
 * A same-account process can ignore the lock; this is not a local sandbox.
 * All returning routines preserve SysV callee-saved registers. Command and
 * error labels terminate. Borrowed arguments are kernel-terminated strings.
 */
.section .text
cmd_self:
    RV_CALL self_current_version
.Lself_arguments:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lself_arguments_done
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, opt_help
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_help
    mv a0, s2
    RV_ADDR s6, opt_json
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_json_option
    mv a0, s2
    RV_ADDR s6, opt_no_color
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_arguments
    RV_ADDR s6, self_has_update
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_version_argument
    mv a0, s2
    RV_ADDR s6, command_update
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_bad_arguments
    RV_IMM t1, 1, 32
    RV_ADDR s6, self_has_update
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lself_arguments
.Lself_version_argument:
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, self_bad_arguments
    mv a0, s2
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_bad_arguments
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_STORE s2, 8
    RV_JUMP .Lself_arguments
.Lself_json_option:
    RV_IMM t1, 1, 32
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lself_arguments
.Lself_arguments_done:
    RV_ADDR s6, self_has_update
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, self_help
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lself_open
    RV_ADDR s6, self_version
    mv a1, s6
    RV_CALL registry_version_compare
    RV_IMM t2, 0, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lt, self_downgrade
.Lself_open:
    RV_IMM t1, 1, 32
    RV_ADDR s6, self_active
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL self_open_installation
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lself_begin
    RV_ADDR s6, self_version
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.ifndef ASM_TRUSTED_DISTRIBUTION
    RV_BCOND ne, self_unchanged
.endif
.Lself_begin:
    RV_CALL registry_workspace
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_IMM t1, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_io_error
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_ADDR s6, self_stage_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_io_error
    RV_CALL self_prepare_verifier
    /* Only bounded standard proxy variables reach transport and hashing.
     * No ambient CA, credential, or tool configuration is inherited. */
    RV_ADDR s6, self_network_environment
    mv t0, s6
    RV_ADDR s6, envp
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, self_package
    mv t0, s6
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_host
    mv t0, s6
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_executable_kind
    mv t0, s6
    RV_ADDR s6, registry_kind
    mv s8, s6
    RV_STORE t0, 8
.ifdef ASM_TRUSTED_DISTRIBUTION
    RV_CALL self_authenticated_index
.else
    RV_ADDR s6, registry_default_url
    mv a0, s6
    RV_ADDR s6, registry_temp_index
    mv a1, s6
    RV_ADDR s6, registry_index_max
    mv a2, s6
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_download_error
.endif
    RV_ADDR s6, registry_temp_index
    mv t0, s6
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_read_index
    RV_CALL registry_parse_index
    RV_CALL registry_select
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, self_not_found
    mv s0, t0
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_version
    mv a1, s6
    RV_CALL registry_version_compare
    RV_IMM t2, 0, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lt, self_downgrade
    RV_BCOND eq, self_unchanged
    RV_CALL self_release_paths
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_asset_url
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_release_error
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_size_value
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_STORE t0, 8
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_payload
    mv a1, s6
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_download_error
    RV_CALL registry_verify_payload
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL validate_host_elf
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_install_elf_error
    /* This gate verifies the manifest, its source binding, and the exact
     * payload. It returns only after every required provenance check passes. */
    RV_CALL self_verify_release
.ifdef ASM_TRUSTED_DISTRIBUTION
    RV_CALL self_authorize_candidate
.endif
    RV_CALL self_commit_update
    RV_CALL self_update_cleanup
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_success_json
    RV_ADDR s6, self_updated_text
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL out
    RV_ADDR s6, self_updated_suffix
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
.Lself_success_json:
    RV_ADDR s6, self_success_json
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, self_success_suffix
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
self_unchanged:
    RV_CALL self_update_cleanup
    RV_ADDR s6, self_unchanged_text
    mv a0, s6
    RV_ADDR s6, self_unchanged_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
self_help:
    RV_ADDR s6, self_help_text
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
self_bad_arguments:
    RV_ADDR s6, self_error_arguments
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_downgrade:
    RV_ADDR s6, self_error_downgrade
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_installation_error:
    RV_ADDR s6, self_error_installation
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_permissions_error:
    RV_ADDR s6, self_error_permissions
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_busy:
    RV_ADDR s6, self_error_busy
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_changed:
    RV_ADDR s6, self_error_changed
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_filesystem_error:
    RV_ADDR s6, self_error_filesystem
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_io_error:
    RV_ADDR s6, self_error_io
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_download_error:
    RV_ADDR s6, self_error_download
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_release_error:
    RV_ADDR s6, self_error_release
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_not_found:
    RV_ADDR s6, self_error_not_found
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP self_fail
self_fail:
    RV_SAVE a0
    RV_SAVE a1
    RV_CALL self_update_cleanup
    RV_RESTORE a1
    RV_RESTORE a0
    RV_JUMP die
/* Read the trusted version_text prefix. Output: self_version (33 bytes).
 * No duplicated release version constant is introduced. Scratch: caller-save
 * registers; stack 16 alignment bytes. A malformed version fails closed. */
self_current_version:
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s6, version_text + 4
    mv a1, s6
    RV_ADDR s6, self_version
    mv a0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lself_current_character:
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, self_bad_arguments
    mv s6, a1
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 32, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_current_end
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, self_bad_arguments
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lself_current_character
.Lself_current_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_bad_arguments
    li s10, 16
    add sp, sp, s10
    ret
/* Open a direct per-user installation. The shared parent walk checks every
 * ancestor, refusing links, empty components, '.' and '..'. HOME and its
 * descendants must belong to the real/effective UID without unsafe writes.
 * Output: held parent/current FDs and a directory flock; cwd becomes parent.
 * Owned path buffers are 4096 bytes. Stack: 80 saved bytes. */
self_open_installation:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_CALL rv_getuid
    RV_ADDR s6, self_uid
    mv s8, s6
    RV_STORE t0, 4
    mv s2, t0
    RV_ZEXT s2
    RV_CALL rv_geteuid
    mv s8, t0
    mv s10, s2
    RV_FLAGS sub, 32
    RV_BCOND ne, self_permissions_error
    RV_CALL rv_getgid
    mv s2, t0
    RV_ZEXT s2
    RV_CALL rv_getegid
    mv s8, t0
    mv s10, s2
    RV_FLAGS sub, 32
    RV_BCOND ne, self_permissions_error
    RV_ADDR s6, envp
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
.Lself_find_home:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, self_installation_error
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 72, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_next_env
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 79, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_next_env
    mv s6, a0
    li s10, 2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 77, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_next_env
    mv s6, a0
    li s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 69, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_next_env
    mv s6, a0
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 61, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_home_found
.Lself_next_env:
    RV_IMM t2, 8, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lself_find_home
.Lself_home_found:
    mv s6, a0
    li s10, 5
    add s6, s6, s10
    mv a1, s6
    mv s6, a1
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 47, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, self_installation_error
    mv a0, a1
    mv s2, a1
    RV_CALL strlen
    RV_IMM t2, 2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, self_installation_error
    RV_IMM t2, 3900, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, self_installation_error
    mv s6, s2
    mv s10, t0
    add s6, s6, s10
    li s10, 1
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 47, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, self_installation_error
    RV_ADDR s6, self_home_length
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, self_install_path
    mv a0, s6
    mv a1, s2
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_install_suffix
    mv a1, s6
    RV_CALL copy_string
    /* copy_string returns the terminator. Exclude the constructed /asm. */
    RV_ADDR s6, self_parent_path
    mv a0, s6
    RV_ADDR s6, self_install_path
    mv a1, s6
    mv a3, t0
    mv s8, a3
    mv s10, a1
    RV_FLAGS sub, 64
    mv a3, s11
    RV_IMM t2, 4, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    mv a3, s11
    mv s8, a3
    bnez s8, .Lrv_cb_skip_self_update531
    RV_JUMP .Lport_self_update_1_end
.Lrv_cb_skip_self_update531:
.Lport_self_update_1:
    mv s8, a1
    RV_LOAD t1, 1
    li s10, 1
    add a1, a1, s10
    mv s8, a0
    RV_STORE t1, 1
    li s10, 1
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_self_update536
    RV_JUMP .Lport_self_update_1
.Lrv_cb_skip_self_update536:
.Lport_self_update_1_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, self_proc_exe
    mv a0, s6
    RV_ADDR s6, self_exe_path
    mv a1, s6
    RV_IMM t1, 4095, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_readlink
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_installation_error
    RV_IMM t2, 4095, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, self_installation_error
    RV_ADDR s6, self_exe_path
    mv a0, s6
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, self_install_path
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_installation_error
    RV_ADDR s6, self_proc_exe
    mv a0, s6
    RV_IMM t1, O_CLOEXEC + O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_installation_error
    RV_ADDR s6, self_current_fd
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_ADDR s6, self_current_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_installation_error
    RV_ADDR s6, self_current_stat
    mv a0, s6
    RV_CALL self_check_file_stat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_permissions_error
    RV_ADDR s6, self_current_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 511, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_ADDR s6, self_file_mode
    mv s8, s6
    RV_STORE t0, 4
    RV_CALL self_open_parent
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, self_permissions_error
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_installation_error
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_ADDR s6, self_parent_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_installation_error
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, 6, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_flock
    RV_IMM t2, -11, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, self_busy
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_filesystem_error
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_filesystem_stat
    mv a1, s6
    RV_CALL rv_fstatfs
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_filesystem_error
    RV_ADDR s6, self_filesystem_stat
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61267, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_local_filesystem
    RV_IMM t2, 1481003842, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_local_filesystem
    RV_IMM t2, 2435016766, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_local_filesystem
    RV_IMM t2, 16914836, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_local_filesystem
    RV_IMM t2, 2035054128, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_local_filesystem
    RV_IMM t2, 4076150800, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, self_filesystem_error
.Lself_local_filesystem:
    RV_CALL self_check_destination
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL rv_fchdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_installation_error
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Open the absolute installation parent from /. Input: bounded, constructed
 * self_install_path and self_home_length. Output: t0=owned parent FD, -1 for
 * an invalid/inaccessible path, or -2 for unsafe ownership or write access.
 * Every directory, including /, must belong to root or this UID. HOME and
 * its descendants must belong to this UID. No group/other writes are allowed
 * except at exact root-owned sticky /tmp above HOME; its immediate child must
 * belong to this UID and deny group/other writes. An arbitrary sticky path
 * is not an exception. Each open uses O_DIRECTORY|O_NOFOLLOW. The walk does
 * not change cwd or held installation descriptors. It restores temporary NUL
 * separators and closes its FD on failure. Scratch: caller-save, stat buffer;
 * stack: 80 saved bytes. The process is single-threaded. */
self_open_parent:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s6, self_root
    mv a0, s6
    RV_IMM t1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_walk_open_error
    mv s5, t0
    mv a0, t0
    RV_ADDR s6, self_check_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_walk_bad_permissions
    RV_ADDR s6, self_check_stat + 24
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lself_root_mode
    RV_ADDR s6, self_uid
    mv s8, s6
    RV_LOAD t2, 4
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
.Lself_root_mode:
    RV_ADDR s6, self_check_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 18, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
    RV_ADDR s6, self_install_path
    mv s2, s6
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv s3, s6
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Lself_walk_component:
    mv s4, s3
.Lself_walk_scan:
    mv s6, s4
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lself_walk_complete
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 47, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_walk_open
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 64
    mv s4, s11
    RV_JUMP .Lself_walk_scan
.Lself_walk_open:
    mv s8, s4
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lself_walk_bad_path
    RV_IMM t1, 0, 32
    mv s6, s4
    mv s8, s6
    RV_STORE t1, 1
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 46, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_walk_bad_component
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 11822, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_component_open
    mv s6, s3
    li s10, 2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_walk_bad_component
.Lself_component_open:
    mv a0, s5
    mv a1, s3
    RV_IMM t1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    RV_IMM t1, 47, 32
    mv s6, s4
    mv s8, s6
    RV_STORE t1, 1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_walk_bad_path
    mv a0, s5
    mv s5, t0
    RV_CALL rv_close
    mv a0, s5
    RV_ADDR s6, self_check_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_walk_bad_permissions
    mv a2, s4
    mv s8, a2
    mv s10, s2
    RV_FLAGS sub, 64
    mv a2, s11
    RV_ADDR s6, self_check_stat + 24
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_component_user
    RV_ADDR s6, self_home_length
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lself_component_user
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lself_component_mode
.Lself_component_user:
    RV_ADDR s6, self_uid
    mv s8, s6
    RV_LOAD t2, 4
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
.Lself_component_mode:
    RV_ADDR s6, self_check_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 18, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lself_component_protected
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
    RV_ADDR s6, self_home_length
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lself_walk_bad_permissions
    RV_IMM t2, 4, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1886221359, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
    RV_ADDR s6, self_check_stat + 24
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_walk_bad_permissions
    RV_ADDR s6, self_check_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 512, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lself_walk_bad_permissions
    RV_IMM t1, 1, 32
    mv s0, t1
    RV_ZEXT s0
    RV_JUMP .Lself_component_next
.Lself_component_protected:
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Lself_component_next:
    mv s6, s4
    li s10, 1
    add s6, s6, s10
    mv s3, s6
    RV_JUMP .Lself_walk_component
.Lself_walk_complete:
    /* The final component was constructed as asm, never supplied by input. */
    mv t0, s5
    RV_JUMP .Lself_walk_return
.Lself_walk_bad_component:
    RV_IMM t1, 47, 32
    mv s6, s4
    mv s8, s6
    RV_STORE t1, 1
.Lself_walk_bad_path:
    RV_IMM t1, -1, 32
    mv s0, t1
    RV_ZEXT s0
    RV_JUMP .Lself_walk_close
.Lself_walk_bad_permissions:
    RV_IMM t1, -2, 32
    mv s0, t1
    RV_ZEXT s0
.Lself_walk_close:
    mv a0, s5
    RV_CALL rv_close
    sext.w t0, s0
    RV_JUMP .Lself_walk_return
.Lself_walk_open_error:
    RV_IMM t1, -1, 64
    mv t0, t1
.Lself_walk_return:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Rewalk and validate the expected absolute path, then require its parent
 * and executable to match the held installation. Called before every verifier
 * child and immediately before the final rename. This catches displaced
 * directories as well as changed file entries; descriptor-relative writes
 * remain authoritative. A noncooperating same-UID race is outside the lock's
 * boundary. No input; no return on mismatch. Owns one temporary FD, always
 * closed. Stack: 16 saved bytes; scratch caller-save and self_check_stat. */
self_check_absolute_installation:
    RV_SAVE s2
    RV_CALL self_open_parent
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_changed
    mv s2, t0
    mv a0, t0
    RV_ADDR s6, self_check_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_absolute_changed
    RV_ADDR s6, self_check_stat
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, self_parent_stat
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lself_absolute_changed
    RV_ADDR s6, self_check_stat + 8
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, self_parent_stat + 8
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lself_absolute_changed
    mv a0, s2
    RV_CALL rv_close
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_changed
    RV_CALL self_check_destination
    RV_RESTORE s2
    ret
.Lself_absolute_changed:
    mv a0, s2
    RV_CALL rv_close
    RV_JUMP self_changed
/* a0=Linux RISC-V64 stat structure (128 bytes). t0=1 only for a single-link
 * regular executable owned by this UID, with no set-ID or unsafe write bits.
 * Reads only; clobbers t0/a2. */
self_check_file_stat:
    mv s6, a0
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_bad_stat
    mv s6, a0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_ADDR s6, self_uid
    mv s8, s6
    RV_LOAD t2, 4
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_bad_stat
    mv s6, a0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv a2, t0
    RV_ZEXT a2
    RV_IMM t2, 61440, 32
    mv s10, t2
    and a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_IMM t2, 32768, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_bad_stat
    RV_IMM t2, 3090, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_bad_stat
    RV_IMM t2, 64, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lself_bad_stat
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.Lself_bad_stat:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Require the held directory entry to remain the exact executed inode.
 * Symlinks are inspected, never followed. No return on mismatch.
 * Stack: 16 alignment bytes. */
self_check_destination:
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_binary_name
    mv a1, s6
    RV_ADDR s6, self_check_stat
    mv a2, s6
    RV_IMM t1, 256, 32
    mv a6, t1
    RV_ZEXT a6
    RV_CALL rv_newfstatat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_changed
    RV_ADDR s6, self_check_stat
    mv a0, s6
    RV_CALL self_check_file_stat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_changed
    RV_ADDR s6, self_check_stat
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, self_current_stat
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, self_changed
    RV_ADDR s6, self_check_stat + 8
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, self_current_stat + 8
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, self_changed
    RV_ADDR s6, self_check_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_ADDR s6, self_current_stat + 16
    mv s8, s6
    RV_LOAD t2, 4
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, self_changed
    li s10, 16
    add sp, sp, s10
    ret
/* Input: selected, validated row. Build exact official asset URLs and local
 * stage paths. All version fields are <=32 bytes, buffers >=512/96 bytes.
 * Preserves callee-saved registers; scratch caller-save and stack 16 bytes. */
self_release_paths:
    RV_SAVE s0
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    RV_ADDR s6, self_asset_filename
    mv a0, s6
    RV_ADDR s6, self_asset_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_asset_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, self_release_base
    mv a0, s6
    RV_ADDR s6, self_release_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    RV_IMM t1, 47, 32
    mv s6, t0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 0, 32
    mv s6, t0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, self_asset_url
    mv a0, s6
    RV_ADDR s6, self_release_base
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_asset_filename
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, self_manifest_url
    mv a0, s6
    RV_ADDR s6, self_release_base
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_manifest_name
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, self_bundle_url
    mv a0, s6
    RV_ADDR s6, self_release_base
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_bundle_name
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, self_manifest_path
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_manifest_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, self_bundle_path
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_bundle_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_RESTORE s0
    ret
/* Commit only a fully verified private payload. File mode and bytes are
 * synced before the final identity check and atomic rename. Rename is the
 * final fallible mutation: its failure preserves the previous directory entry.
 * Directory crash durability and hostile same-UID races are outside scope.
 * Stack: one saved descriptor. */
self_commit_update:
    RV_SAVE s2
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_payload_name
    mv a1, s6
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_io_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, self_file_mode
    mv s8, s6
    RV_LOAD t1, 4
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_fchmod
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_commit_close_fail
    mv a0, s2
    RV_CALL rv_fsync
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_commit_close_fail
    mv a0, s2
    RV_CALL rv_close
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_io_error
    RV_CALL self_check_absolute_installation
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_payload_name
    mv a1, s6
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_ADDR s6, self_binary_name
    mv a6, s6
    RV_CALL rv_renameat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_io_error
    RV_RESTORE s2
    ret
.Lself_commit_close_fail:
    mv a0, s2
    RV_CALL rv_close
    RV_JUMP self_io_error
/* Cleanup only the held private stage and descriptors owned by this command.
 * Native descriptor-relative traversal does not follow links. Never delete a
 * substituted stage directory entry. Cleanup errors do not turn a committed
 * update into a reported failure. Uses archive cleanup buffers exclusively. */
self_update_cleanup:
    RV_ADDR s6, self_active
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_cleanup_done
    RV_SAVE s2
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lt, .Lself_cleanup_without_stage
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL arc_walk_tree
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_ADDR s6, self_check_stat
    mv a2, s6
    RV_IMM t1, 256, 32
    mv a6, t1
    RV_ZEXT a6
    RV_CALL rv_newfstatat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_close_stage
    RV_ADDR s6, self_check_stat
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, self_stage_stat
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lself_close_stage
    RV_ADDR s6, self_check_stat + 8
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, self_stage_stat + 8
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lself_close_stage
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_IMM t1, 512, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_unlinkat
.Lself_close_stage:
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_STORE t1, 8
    RV_JUMP .Lself_cleanup_descriptors
.Lself_cleanup_without_stage:
    RV_ADDR s6, registry_has_workspace
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_cleanup_descriptors
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_IMM t1, 512, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_unlinkat
.Lself_cleanup_descriptors:
    RV_IMM t1, 0, 32
    RV_ADDR s6, registry_has_workspace
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, self_current_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    RV_ADDR s6, self_current_fd
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    RV_ADDR s6, self_parent_fd
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 32
    RV_ADDR s6, self_active
    mv s8, s6
    RV_STORE t1, 1
    RV_RESTORE s2
.Lself_cleanup_done:
    ret
.section .rodata
self_install_suffix: .asciz "/.local/bin/asm"
self_proc_exe: .asciz "/proc/self/exe"
self_root: .asciz "/"
self_binary_name: .asciz "asm"
self_payload_name: .asciz "payload"
self_package: .asciz "stubbi/asm"
self_release_prefix: .asciz "https://github.com/stubbi/asm/releases/download/v"
self_asset_prefix: .asciz "asm-"
self_asset_suffix: .asciz "-riscv64-linux"
self_manifest_name: .asciz "release.json"
self_bundle_name: .asciz "release-attestation.sigstore.json"
self_manifest_suffix: .asciz "/release.json"
self_bundle_suffix: .asciz "/release-attestation.sigstore.json"
self_updated_text: .asciz "Updated Asm to "
self_updated_suffix: .asciz ". Start a new command to use it.\n"
self_success_json: .asciz "{\"updated\":true,\"version\":"
self_success_suffix: .asciz ",\"integrity_verified\":true,\"provenance_verified\":true}\n"
self_unchanged_text: .asciz "No newer version was selected. The installed binary was not changed.\n"
self_unchanged_json: .asciz "{\"updated\":false,\"reason\":\"no-newer-version-selected\"}\n"
self_error_arguments: .asciz "invalid self arguments; use asm self --help"
self_error_downgrade: .asciz "self update refuses an older version; keep the current version or select a newer release"
self_error_installation: .asciz "self update requires the direct HOME/.local/bin/asm installation; use the bootstrap installer or your package manager"
self_error_permissions: .asciz "self update requires a single-link user-owned executable and protected path ancestors; check ownership and write permissions from / through HOME/.local/bin"
self_error_busy: .asciz "another update holds the installation lock; wait for it to finish and try again"
self_error_changed: .asciz "the installation path or executable changed during this operation; no replacement was made; start the installed command again"
self_error_filesystem: .asciz "self update requires a supported local filesystem; use your package manager or install the verified release manually"
self_error_io: .asciz "self update could not prepare or replace the executable; the previous binary remains; check free space and directory permissions"
self_error_download: .asciz "self update could not download required release files over HTTPS; the previous binary remains; check the connection and release"
self_error_release: .asciz "self update requires the exact official versioned Asm artifact; the previous binary remains; check the published release"
self_error_not_found: .asciz "no matching Asm host executable was found; check the requested version with asm versions stubbi/asm"
self_help_text:
.ascii "Usage: asm self update [X.Y.Z] [--json] [--no-color]\n\n"
.ascii "Manually update the direct HOME/.local/bin/asm installation.\n"
.ascii "Uses stubbi/asm from https://asm.build. Older versions are refused.\n"
.ascii "Requires /usr/bin/curl, sha256sum, and GitHub CLI gh >= 2.93.0.\n"
.ascii "Checks size, SHA-256, host ELF, and release-workflow attestations.\n"
.ascii "Does not execute the downloaded program or elevate privileges.\n"
.ascii "No unattended update, metadata freshness, or revocation guarantee.\n"
.ascii "Use your package manager for an installation that it owns.\n"
.byte 0
.section .data
self_parent_fd: .quad -1
self_current_fd: .quad -1
self_stage_fd: .quad -1
.section .bss
.balign 8
self_home_length: .skip 8
self_uid: .skip 4
self_file_mode: .skip 4
self_active: .skip 1
self_has_update: .skip 1
self_version: .skip 33
self_install_path: .skip 4096
self_parent_path: .skip 4096
self_exe_path: .skip 4096
self_current_stat: .skip 128
self_parent_stat: .skip 128
self_check_stat: .skip 128
self_stage_stat: .skip 128
self_filesystem_stat: .skip 128
self_asset_filename: .skip 96
self_release_base: .skip 512
self_asset_url: .skip 512
self_manifest_url: .skip 512
self_bundle_url: .skip 512
self_manifest_path: .skip 96
self_bundle_path: .skip 96
