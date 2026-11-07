/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/dependencies.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global cmd_add, cmd_update, cmd_remove, cmd_lock, cmd_sync
.global verify_project_dependencies, release_dependency_lock
/* Direct source dependencies use exact versions. asm.lock stores the same
 * eight fields as registry v1, after a versioned header and registry origin.
 * No ranges, transitive resolution, hooks or implicit source imports exist.
 * Returning routines preserve s0/s1/s2-s5; other registers are scratch.
 */
/* Native RISC-V64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each RV_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */
.section .text
cmd_add:
    RV_IMM t1, 6, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
cmd_update:
    RV_IMM t1, 7, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
/* Input: registry_selected is validated and points into the registry buffer.
 * Save its eight pointers before loading the independent lock buffer. Require
 * a project and a single registry origin. Take a nonblocking exclusive project
 * lock. Existing lock records are retained until verified extraction succeeds.
 * Output: registry_selected points to dependency_new_record; locked rows are
 * in registry_rows. Stack: 48 saved bytes. Fatal failures preserve asm.lock. */
dependency_prepare_selection:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_LOAD t0, 8
    RV_ADDR s6, project_requested_target
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL read_manifest
    RV_CALL res_legacy_guard
    RV_ADDR s6, dependency_new_record
    mv a0, s6
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_dependencies54
    RV_JUMP .Lport_dependencies_1_end
.Lrv_cb_skip_dependencies54:
.Lport_dependencies_1:
    mv s8, a1
    RV_LOAD t1, 8
    li s10, 8
    add a1, a1, s10
    mv s8, a0
    RV_STORE t1, 8
    li s10, 8
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_dependencies59
    RV_JUMP .Lport_dependencies_1
.Lrv_cb_skip_dependencies59:
.Lport_dependencies_1_end:
    RV_ADDR s6, dependency_new_record
    mv t0, s6
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, registry_local_index
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
    RV_BCOND eq, .Ldep_new_origin
    RV_ADDR s6, dependency_local_origin
    mv t0, s6
.Ldep_new_origin:
    RV_ADDR s6, dependency_new_origin
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 6, 32
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL dependency_acquire
    RV_CALL dependency_load_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_check_origin
    RV_ADDR s6, dependency_new_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Ldep_find_previous
.Ldep_check_origin:
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, dependency_new_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_origin_error
.Ldep_find_previous:
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
    RV_ADDR s6, dependency_new_record
    mv s0, s6
.Ldep_previous_loop:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_previous_done
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_previous_next
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    li s10, 16
    add s8, s0, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies128
    RV_JUMP .Ldep_previous_next
.Lrv_cb_skip_dependencies128:
    RV_ADDR s6, dependency_replace_row
    mv s8, s6
    RV_STORE s2, 8
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 7, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Ldep_previous_done
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_already_locked
    mv s6, s2
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
    mv s6, s2
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
    mv s6, s2
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
    RV_JUMP .Ldep_previous_done
.Ldep_previous_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_previous_loop
.Ldep_previous_done:
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 7, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_prepare_done
    RV_ADDR s6, dependency_replace_row
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, dependency_missing_selection
    /* Updating a version may not change the bytes of the same version. */
    RV_ADDR s6, dependency_replace_row
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_prepare_done
    mv s6, s2
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
    mv s6, s2
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
    mv s6, s2
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
.Ldep_prepare_done:
    RV_ADDR s6, dependency_new_record
    mv t0, s6
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE t0, 8
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: verified private payload and dependency_new_record. Extract or compare
 * the exact source tree before changing asm.lock. Cache archives are derived
 * data named by their digest; a verified replacement can repair those bytes.
 * The lock rename is the final operation. Unreferenced cache data can remain
 * after a filesystem failure; the previous lock remains usable. No return. */
dependency_finish_add:
    RV_ADDR s6, dependency_new_record
    mv s0, s6
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE s0, 8
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL dependency_paths
    RV_CALL dependency_accept_payload
    RV_ADDR s6, rm_archive_metadata
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_dependencies276
    RV_JUMP res_use_resolve_error
.Lrv_cb_skip_dependencies276:
    RV_ADDR s6, dependency_replace_row
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND ne, .Ldep_replace_record
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 4096, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, dependency_lock_error
    slli t0, t0, 6
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, registry_rows
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_STORE t3, 8
.Ldep_replace_record:
    RV_ADDR s6, dependency_new_record
    mv a1, s6
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_dependencies304
    RV_JUMP .Lport_dependencies_2_end
.Lrv_cb_skip_dependencies304:
.Lport_dependencies_2:
    mv s8, a1
    RV_LOAD t1, 8
    li s10, 8
    add a1, a1, s10
    mv s8, a0
    RV_STORE t1, 8
    li s10, 8
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_dependencies309
    RV_JUMP .Lport_dependencies_2
.Lrv_cb_skip_dependencies309:
.Lport_dependencies_2_end:
    RV_CALL dependency_write_lock
    RV_CALL registry_cleanup
    RV_CALL release_dependency_lock
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
    RV_BCOND ne, .Ldep_add_json
    RV_ADDR s6, dependency_added_text
    mv a0, s6
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 7, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_add_text
    RV_ADDR s6, dependency_updated_text
    mv a0, s6
.Ldep_add_text:
    RV_CALL out
    RV_JUMP exit_ok
.Ldep_add_json:
    RV_ADDR s6, dependency_result_prefix
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, dependency_new_record
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, registry_fetch_json_version
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, dependency_new_record + 8
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, dependency_result_cache
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, dependency_package_path
    mv a0, s6
    RV_CALL registry_json_string
    RV_ADDR s6, dependency_result_suffix
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
/* Input: a0=flock operation 5(shared/nonblocking) or 6(exclusive/nonblocking),
 * a1=allow creating .asm. Output: held descriptor in dependency_lock_fd.
 * The empty coordination file is regular, non-symlink, and has one hard link.
 * Cooperation prevents lost updates between asm processes in this project.
 * It is not a sandbox against a process that ignores flock. Stack: 16 saved bytes. */
dependency_acquire:
    RV_SAVE s2
    mv s2, a0
    RV_ZEXT s2
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_existing_root
    RV_ADDR s6, dependency_root
    mv a0, s6
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_JUMP .Ldep_open_lock
.Ldep_existing_root:
    RV_ADDR s6, dependency_root
    mv a0, s6
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_cache_missing
    RV_ADDR s6, dependency_stat + RV_STAT_MODE
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, dependency_io_error
.Ldep_open_lock:
    RV_ADDR s6, dependency_operation_lock
    mv a0, s6
    RV_IMM t1, 64 | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    RV_IMM t1, 384, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_ADDR s6, dependency_lock_fd
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_ADDR s6, dependency_stat + RV_STAT_MODE
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 32768, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, dependency_io_error
    RV_ADDR s6, dependency_stat + RV_STAT_LINKS
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, dependency_io_error
    RV_ADDR s6, dependency_lock_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv a1, s2
    RV_ZEXT a1
    RV_CALL rv_flock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_busy
    RV_RESTORE s2
    ret
/* Closes only a descriptor acquired above, releasing its advisory lock.
 * Output: dependency_lock_fd=-1. Safe if no lock was acquired. Stack: none. */
release_dependency_lock:
    RV_ADDR s6, dependency_lock_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t2, 0, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lt, .Ldep_release_done
    RV_CALL rv_close
    RV_IMM t1, -1, 64
    RV_ADDR s6, dependency_lock_fd
    mv s8, s6
    RV_STORE t1, 8
.Ldep_release_done:
    ret
/* Input: cwd. Reads a regular asm.lock into its own <=1MiB buffer. Output:
 * t0=0 loaded, t0=1 absent; registry_rows/count and dependency_origin updated.
 * The selected remote record must be saved before this routine is called.
 * v1 retains host-only rows. v2 keys each row by package and declared target.
 * All metadata, kinds, targets and duplicate identities are checked before use. Stack: 64 saved bytes. Missing does not create a file. */
dependency_load_lock:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, dependency_selected_count
    mv s8, s6
    RV_STORE t1, 8
    li t1, 1
    RV_ZEXT t1
    RV_ADDR s6, dependency_lock_version
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, dependency_lock_path
    mv a0, s6
    RV_IMM t1, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_open
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Ldep_no_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_lock_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldep_read_bad
    RV_ADDR s6, dependency_stat + RV_STAT_MODE
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 32768, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_read_bad
    RV_ADDR s6, dependency_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1048576, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Ldep_read_bad
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Ldep_read_loop:
    mv a0, s2
    RV_ADDR s6, dependency_lock_buffer
    mv a1, s6
    mv s8, a1
    mv s10, s3
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t1, 1048577, 32
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, s3
    RV_FLAGS sub, 64
    mv a2, s11
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Ldep_read_loop
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldep_read_bad
    RV_BCOND eq, .Ldep_read_done
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    RV_IMM t2, 1048576, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Ldep_read_bad
    RV_JUMP .Ldep_read_loop
.Ldep_read_done:
    mv a0, s2
    RV_CALL rv_close
    RV_ADDR s6, dependency_lock_buffer
    mv a0, s6
    mv s6, a0
    mv s10, s3
    add s6, s6, s10
    mv s4, s6
    RV_IMM t1, 0, 32
    mv s6, s4
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, dependency_header
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    beqz s8, .Lrv_cb_skip_dependencies539
    RV_JUMP .Ldep_header_found
.Lrv_cb_skip_dependencies539:
    RV_ADDR a0, dependency_lock_buffer
    RV_ADDR a1, dependency_header_v2
    RV_CALL dependency_prefix
    mv s8, t0
    bnez s8, .Lrv_cb_skip_dependencies543
    RV_JUMP dependency_lock_error
.Lrv_cb_skip_dependencies543:
    li t1, 2
    RV_ZEXT t1
    RV_ADDR s6, dependency_lock_version
    mv s8, s6
    RV_STORE t1, 1
.Ldep_header_found:
    mv a0, t0
    RV_ADDR s6, dependency_origin_prefix
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, dependency_lock_error
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_STORE t0, 8
    mv s2, t0
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Ldep_origin_scan:
    mv s8, s2
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hs, dependency_lock_error
    mv s6, s2
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
    RV_IMM t2, 10, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Ldep_origin_end
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 33, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, dependency_lock_error
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 126, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, dependency_lock_error
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 4095, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, dependency_lock_error
    RV_JUMP .Ldep_origin_scan
.Ldep_origin_end:
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, dependency_local_origin
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Ldep_parse_rows
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_https_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_lock_error
.Ldep_parse_rows:
    mv a0, s2
    mv a1, s4
    RV_CALL registry_parse_records
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Ldep_validate_record:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_loaded
    RV_ADDR s6, dependency_lock_version
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 1
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_declared_target
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    RV_ADDR a1, registry_host
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies631
    RV_JUMP dependency_lock_error
.Lrv_cb_skip_dependencies631:
.Ldep_declared_target:
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    RV_CALL project_declares_target
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies635
    RV_JUMP dependency_lock_error
.Lrv_cb_skip_dependencies635:
    mv s6, s2
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_source_kind
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_lock_error
    RV_ADDR s6, registry_rows
    mv s0, s6
.Ldep_duplicate_package:
    mv s8, s0
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_record_next
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_duplicate_next
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 16
    add s8, s2, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_dependencies662
    RV_JUMP dependency_lock_error
.Lrv_cb_skip_dependencies662:
.Ldep_duplicate_next:
    RV_IMM t2, 64, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Ldep_duplicate_package
.Ldep_record_next:
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    RV_ADDR a1, package_target
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies671
    RV_JUMP .Ldep_record_unselected
.Lrv_cb_skip_dependencies671:
    RV_ADDR s6, dependency_selected_count
    mv s8, s6
    RV_LOAD t1, 8
    li s10, 1
    add t1, t1, s10
    mv s8, s6
    RV_STORE t1, 8
.Ldep_record_unselected:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_validate_record
.Ldep_loaded:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Ldep_load_return
.Ldep_no_lock:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Ldep_load_return:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
.Ldep_read_bad:
    mv a0, s2
    RV_CALL rv_close
    RV_JUMP dependency_lock_error
/* Input: a0=input, a1=constant prefix. Output: t0=first byte after prefix,
 * or zero on mismatch. Read-only; inputs point into bounded NUL buffers. */
dependency_prefix:
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Ldep_prefix_loop:
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
    RV_BCOND eq, .Ldep_prefix_done
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 1
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_prefix_bad
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Ldep_prefix_loop
.Ldep_prefix_done:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv t0, s6
    ret
.Ldep_prefix_bad:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Input: registry_selected=validated source record, a0=create parent dirs.
 * Output: package path .asm/packages/owner/name/version/target (<=180 bytes),
 * and archive .asm/cache/<sha256>.tar.gz (<=90 bytes). Does not create the final
 * extraction directory. Existing directory components must not be symlinks.
 * Stack: 64 saved bytes. Buffer capacities 256 and 128. */
dependency_paths:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    mv s4, a0
    RV_ZEXT s4
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    RV_ADDR s6, dependency_packages_root
    mv a0, s6
    mv a1, s4
    RV_ZEXT a1
    RV_CALL dependency_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_ADDR s6, dependency_cache_root
    mv a0, s6
    mv a1, s4
    RV_ZEXT a1
    RV_CALL dependency_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
.Ldep_path_copy:
    RV_ADDR s6, dependency_package_path
    mv a0, s6
    RV_ADDR s6, dependency_packages_prefix
    mv a1, s6
    RV_CALL copy_string
    mv s2, t0
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
.Ldep_owner_copy:
    mv s6, s3
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
    RV_IMM t2, 47, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Ldep_owner_done
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_owner_copy
.Ldep_owner_done:
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, dependency_package_path
    mv a0, s6
    mv a1, s4
    RV_ZEXT a1
    RV_CALL dependency_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
.Ldep_name_copy:
    mv a0, s2
    mv a1, s3
    RV_CALL copy_string
    mv s2, t0
    RV_ADDR s6, dependency_package_path
    mv a0, s6
    mv a1, s4
    RV_ZEXT a1
    RV_CALL dependency_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
.Ldep_version_copy:
    RV_IMM t1, 47, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv s2, t0
    RV_ADDR s6, dependency_package_path
    mv a0, s6
    mv a1, s4
    RV_ZEXT a1
    RV_CALL dependency_directory
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
.Ldep_target_copy:
    RV_IMM t1, 47, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    mv s6, s0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    RV_ADDR s6, dependency_archive_path
    mv a0, s6
    RV_ADDR s6, dependency_cache_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_tar_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: a0=one cache directory component, a1=allow creation. Output: zero
 * or one for a real directory, negative on failure. Read-only mode still
 * rejects symbolic links at every checked component. Stack: none. */
dependency_directory:
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_BCOND ne, make_safe_dir
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldep_directory_return
    RV_ADDR s6, dependency_stat + RV_STAT_MODE
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_directory_bad
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
.Ldep_directory_bad:
    RV_IMM t1, -1, 64
    mv t0, t1
.Ldep_directory_return:
    ret
/* Input: private payload has passed size+SHA256; dependency paths are set.
 * Compare an existing cache tree or extract a new one with the native archive
 * module. Then atomically store the verified archive in the managed digest
 * cache. Does not modify asm.lock. No package code runs. */
dependency_accept_payload:
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, t0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, t0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_CALL validate_source_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_archive_error
    RV_ADDR s6, dependency_package_path
    mv a0, s6
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_lstat
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Ldep_extract_new
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_ADDR s6, dependency_stat + RV_STAT_MODE
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, dependency_cache_changed
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, dependency_package_path
    mv a1, s6
    RV_CALL verify_source_archive
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_cache_changed
    RV_JUMP .Ldep_store_archive
.Ldep_extract_new:
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, dependency_package_path
    mv a1, s6
    RV_CALL extract_source_archive
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_archive_error
.Ldep_store_archive:
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_IMM t1, 420, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_chmod
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, dependency_archive_path
    mv a1, s6
    RV_CALL rv_rename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    ret
/* Input: registry_rows/count and one validated dependency_origin. Writes a
 * canonical lock to an exclusive private temporary file, fsyncs it, then
 * renames it onto asm.lock. The held project lock serializes writers. Each
 * field is already bounded printable text. Stack: 80 saved bytes plus calls. */
dependency_write_lock:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    /* Bound the serialized file, not just its record count. Otherwise an
     * append could write a lock that the bounded reader cannot reopen. */
    RV_ADDR a0, dependency_header
    RV_ADDR s6, dependency_lock_version
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Ldep_write_v2
    RV_ADDR s6, project_target_mask
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_dependencies988
    RV_JUMP .Ldep_write_v2
.Lrv_cb_skip_dependencies988:
    /* The legacy v1 reader accepts native rows only. Foreign selections
     * require v2 even when the manifest uses one legacy build table. */
    RV_ADDR a0, package_target
    RV_ADDR a1, registry_host
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies994
    RV_JUMP .Ldep_write_v2
.Lrv_cb_skip_dependencies994:
    RV_ADDR a0, dependency_header
    RV_JUMP .Ldep_write_header_ready
.Ldep_write_v2:
    RV_ADDR a0, dependency_header_v2
.Ldep_write_header_ready:
    RV_ADDR s6, dependency_write_header
    mv s8, s6
    RV_STORE a0, 8
    RV_CALL strlen
    mv s5, t0
    RV_ADDR s6, dependency_origin_prefix
    mv a0, s6
    RV_CALL strlen
    mv s8, s5
    mv s10, t0
    RV_FLAGS add, 64
    mv s5, s11
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    mv s6, s5
    mv s10, t0
    add s6, s6, s10
    li s10, 1
    add s6, s6, s10
    mv s5, s6
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Ldep_measure_record:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_measure_done
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Ldep_measure_field:
    mv s6, s2
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    mv s6, s5
    mv s10, t0
    add s6, s6, s10
    li s10, 1
    add s6, s6, s10
    mv s5, s6
    RV_IMM t2, 1048576, 64
    mv s8, s5
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, dependency_lock_too_large
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    RV_IMM t2, 8, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Ldep_measure_field
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_measure_record
.Ldep_measure_done:
    RV_IMM t2, 1048576, 64
    mv s8, s5
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, dependency_lock_too_large
    RV_CALL registry_workspace
    RV_ADDR s6, dependency_temp_lock
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, dependency_lock_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, dependency_temp_lock
    mv t0, s6
    RV_ADDR s6, registry_extra_temp
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_extra_temp
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, 193 | O_NOFOLLOW | O_CLOEXEC, 32
    mv a1, t1
    RV_ZEXT a1
    RV_IMM t1, 420, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    mv s0, t0
    RV_ADDR s6, dependency_write_header
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL dependency_write_string
    RV_ADDR s6, dependency_origin_prefix
    mv a1, s6
    RV_CALL dependency_write_string
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL dependency_write_string
    RV_ADDR s6, registry_newline
    mv a1, s6
    RV_CALL dependency_write_string
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Ldep_write_record:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_write_end
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Ldep_write_field:
    mv s6, s2
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL dependency_write_string
    RV_ADDR s6, registry_tab
    mv a1, s6
    RV_IMM t2, 7, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldep_write_separator
    RV_ADDR s6, registry_newline
    mv a1, s6
.Ldep_write_separator:
    RV_CALL dependency_write_string
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    RV_IMM t2, 8, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Ldep_write_field
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_write_record
.Ldep_write_end:
    mv a0, s0
    RV_CALL rv_fsync
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    mv a0, s0
    RV_CALL rv_close
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_ADDR s6, dependency_temp_lock
    mv a0, s6
    RV_ADDR s6, dependency_lock_path
    mv a1, s6
    RV_CALL rv_rename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_extra_temp
    mv s8, s6
    RV_STORE t1, 8
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: s0=owned lock file descriptor, a1=validated string. Returns only
 * after complete write; fatal error preserves the previous asm.lock. */
dependency_write_string:
    mv a0, s0
    RV_CALL write_cstr
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    ret
/* Core build entry. Input: require_lock selects strict missing-lock behavior.
 * Builds verify selected-target dependencies when asm.lock exists. Each archive
 * is copied into a private stage, checked against its locked size/digest, and
 * compared byte-for-byte to its extracted cache, including unexpected members.
 * Output: returns with a shared project lock held until build completion.
 * Does not fetch, resolve new versions, execute code or modify source caches. */
verify_legacy_project_dependencies:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s6, dependency_lock_path
    mv a0, s6
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_lstat
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Ldep_verify_present
    RV_ADDR s6, require_lock
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
    RV_BCOND ne, dependency_lock_missing
    RV_JUMP .Ldep_verify_done
.Ldep_verify_present:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_lock_error
    RV_IMM t1, 5, 32
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL dependency_acquire
    RV_CALL dependency_load_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_lock_missing
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Ldep_verify_row:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_verify_done
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    RV_ADDR a1, package_target
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies1212
    RV_JUMP .Ldep_verify_next
.Lrv_cb_skip_dependencies1212:
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE s2, 8
    mv s6, s2
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_size_value
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_STORE t0, 8
    mv s10, a0
    xor a0, a0, s10
    RV_ZEXT a0
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 32
    RV_CALL dependency_paths
    RV_ADDR s6, dependency_archive_path
    mv a0, s6
    RV_ADDR s6, dependency_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_cache_missing
    RV_CALL registry_workspace
    RV_ADDR s6, dependency_archive_path
    mv t0, s6
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_copy_local
    RV_CALL registry_verify_payload
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, s2
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    RV_CALL validate_source_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_archive_error
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, dependency_package_path
    mv a1, s6
    RV_CALL verify_source_archive
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_cache_changed
    RV_CALL registry_cleanup
.Ldep_verify_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_verify_row
.Ldep_verify_done:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
cmd_lock:
    RV_CALL parse_options_only
    RV_CALL read_manifest
    RV_IMM t1, 1, 32
    RV_ADDR s6, require_lock
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL verify_project_dependencies
    RV_CALL release_dependency_lock
    RV_ADDR s6, dependency_locked_text
    mv a0, s6
    RV_JUMP dependency_count_report
cmd_remove:
    RV_CALL dependency_parse_name
    RV_CALL read_manifest
    RV_CALL res_legacy_guard
    RV_IMM t1, 6, 32
    mv a0, t1
    RV_ZEXT a0
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_CALL dependency_acquire
    RV_CALL dependency_load_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_lock_missing
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s3, s2
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
.Ldep_remove_row:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_remove_done
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, dependency_remove_name
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_remove_keep
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    RV_ADDR a1, package_target
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_dependencies1323
    RV_JUMP .Ldep_remove_match
.Lrv_cb_skip_dependencies1323:
.Ldep_remove_keep:
    mv a0, s3
    mv a1, s2
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_dependencies1329
    RV_JUMP .Lport_dependencies_3_end
.Lrv_cb_skip_dependencies1329:
.Lport_dependencies_3:
    mv s8, a1
    RV_LOAD t1, 8
    li s10, 8
    add a1, a1, s10
    mv s8, a0
    RV_STORE t1, 8
    li s10, 8
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_dependencies1334
    RV_JUMP .Lport_dependencies_3
.Lrv_cb_skip_dependencies1334:
.Lport_dependencies_3_end:
    RV_IMM t2, 64, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_remove_next
.Ldep_remove_match:
    RV_IMM t2, 1, 32
    mv s8, s5
    mv s10, t2
    RV_FLAGS add, 32
    mv s5, s11
.Ldep_remove_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 64
    mv s4, s11
    RV_JUMP .Ldep_remove_row
.Ldep_remove_done:
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_missing_selection
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, s5
    RV_FLAGS sub, 64
    mv t3, s11
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_STORE t3, 8
    RV_ADDR s6, dependency_selected_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s10, s5
    sub t1, t1, s10
    mv s8, s6
    RV_STORE t1, 8
    RV_CALL dependency_write_lock
    RV_CALL registry_cleanup
    RV_CALL release_dependency_lock
    RV_ADDR s6, dependency_removed_text
    mv a0, s6
    RV_JUMP dependency_count_report
/* Parse remove's one owner/name operand and common output options. Input:
 * argv cursor follows command. Output: borrowed dependency_remove_name.
 * Unknown arguments or selectors with versions exit 2 before file changes. */
dependency_parse_name:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Ldep_remove_args_done
    mv s2, t0
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_parse_name
    RV_ADDR s6, dependency_remove_name
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    mv a0, s2
    RV_CALL registry_valid_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_ADDR s6, dependency_remove_name
    mv s8, s6
    RV_STORE s2, 8
    RV_JUMP dependency_parse_name
.Ldep_remove_args_done:
    RV_ADDR s6, dependency_remove_name
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, registry_bad_args
    ret
/* Sync downloads locked exact URLs. It never reads a newer registry index.
 * --artifact FILE requires exactly one selected-target dependency.
 * Existing extracted source must match; sync does not discard local edits. */
cmd_sync_legacy:
.Ldep_sync_args:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Ldep_sync_start
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, registry_opt_artifact
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Ldep_sync_common
    RV_ADDR s6, dependency_sync_artifact
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, dependency_sync_artifact
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Ldep_sync_args
.Ldep_sync_common:
    mv t0, s2
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Ldep_sync_args
.Ldep_sync_start:
    RV_CALL read_manifest
    RV_ADDR s6, rm_root_metadata
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_dependencies1432
    RV_JUMP res_lock_error
.Lrv_cb_skip_dependencies1432:
    RV_IMM t1, 6, 32
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL dependency_acquire
    RV_CALL dependency_load_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, dependency_lock_missing
    RV_ADDR s6, dependency_sync_artifact
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Ldep_sync_begin
    RV_ADDR s6, dependency_selected_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
.Ldep_sync_begin:
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Ldep_sync_row:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Ldep_sync_done
    li s10, 16
    add s8, s2, s10
    RV_LOAD a0, 8
    RV_ADDR a1, package_target
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_dependencies1464
    RV_JUMP .Ldep_sync_next
.Lrv_cb_skip_dependencies1464:
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE s2, 8
    mv s6, s2
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_size_value
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL dependency_paths
    RV_CALL registry_workspace
    RV_ADDR s6, dependency_sync_artifact
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Ldep_sync_remote
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_copy_local
    RV_JUMP .Ldep_sync_verified
.Ldep_sync_remote:
    mv s6, s2
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_payload
    mv a1, s6
    mv s6, s2
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_download_error
.Ldep_sync_verified:
    RV_CALL registry_verify_payload
    RV_CALL dependency_accept_payload
    RV_CALL registry_cleanup
.Ldep_sync_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Ldep_sync_row
.Ldep_sync_done:
    RV_CALL release_dependency_lock
    RV_ADDR s6, dependency_synced_text
    mv a0, s6
    RV_JUMP dependency_count_report
/* Terminal report. Input: a0=plain success text; selected_count is the locked
 * count. JSON writes a numeric count, not a package-safety claim. */
dependency_count_report:
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
    RV_BCOND eq, .Ldep_report_text
    RV_ADDR s6, dependency_count_prefix
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, dependency_selected_count
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, dependency_number + 31
    mv a1, s6
    RV_CALL unsigned_decimal
    mv a0, t0
    RV_CALL out
    RV_ADDR s6, dependency_result_suffix
    mv a0, s6
.Ldep_report_text:
    RV_CALL out
    RV_JUMP exit_ok
dependency_io_error:
    RV_ADDR s6, dependency_err_io
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_lock_error:
    RV_ADDR s6, dependency_err_lock
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_lock_missing:
    RV_ADDR s6, dependency_err_lock_missing
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_cache_missing:
    RV_ADDR s6, dependency_err_cache_missing
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_cache_changed:
    RV_ADDR s6, dependency_err_cache_changed
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_archive_error:
    RV_ADDR s6, dependency_err_archive
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_origin_error:
    RV_ADDR s6, dependency_err_origin
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_already_locked:
    RV_ADDR s6, dependency_err_already
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_changed_release:
    RV_ADDR s6, dependency_err_changed
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_missing_selection:
    RV_ADDR s6, dependency_err_selection
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_busy:
    RV_ADDR s6, dependency_err_busy
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
dependency_lock_too_large:
    RV_ADDR s6, dependency_err_large
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
.section .rodata
dependency_header: .asciz "# asm-lock-v1\n"
dependency_header_v2: .asciz "# asm-lock-v2\n"
dependency_origin_prefix: .asciz "# registry "
dependency_local_origin: .asciz "local"
dependency_root: .asciz ".asm"
dependency_operation_lock: .asciz ".asm/operation.lock"
dependency_packages_root: .asciz ".asm/packages"
dependency_packages_prefix: .asciz ".asm/packages/"
dependency_cache_root: .asciz ".asm/cache"
dependency_cache_prefix: .asciz ".asm/cache/"
dependency_lock_path: .asciz "asm.lock"
dependency_lock_suffix: .asciz "/asm.lock"
dependency_added_text: .asciz "Added the exact source dependency. Run asm lock to check the cache.\n"
dependency_updated_text: .asciz "Updated the exact source dependency. The previous lock was retained until verification succeeded.\n"
dependency_removed_text: .asciz "Removed the dependency from asm.lock. Cache files were retained.\n"
dependency_locked_text: .asciz "Verified the selected target's locked archives and source files.\n"
dependency_synced_text: .asciz "Synchronized the exact locked source dependencies.\n"
dependency_result_prefix: .asciz "{\"ok\":true,\"package\":"
dependency_result_cache: .asciz ",\"cache\":"
dependency_result_suffix: .asciz "}\n"
dependency_count_prefix: .asciz "{\"ok\":true,\"dependencies\":"
dependency_err_io: .asciz "cannot write dependency state. Check project permissions and .asm directory types"
dependency_err_lock: .asciz "asm.lock is invalid. Restore a valid lock file before using dependencies"
dependency_err_lock_missing: .asciz "asm.lock is missing. Use asm add with an exact package version"
dependency_err_cache_missing: .asciz "a locked package is missing. Run asm sync before building"
dependency_err_cache_changed: .asciz "source cache verification failed. Remove the changed package cache directory, then run asm sync"
dependency_err_archive: .asciz "the source archive is invalid. The lock file was not changed"
dependency_err_origin: .asciz "the registry differs from asm.lock. Use the locked registry origin"
dependency_err_already: .asciz "the dependency has another locked version. Use asm update with an exact version"
dependency_err_changed: .asciz "a locked version has different release metadata. The lock file was not changed"
dependency_err_selection: .asciz "the package is not in asm.lock. Use asm add to create its first selection"
dependency_err_busy: .asciz "another asm command uses this project. Try again after it finishes"
dependency_err_large: .asciz "the dependency lock would exceed 1 MiB. Remove an unused dependency first"
.section .data
.balign 8
dependency_lock_fd: .quad -1
.section .bss
.balign 8
dependency_lock_version: .skip 8
dependency_write_header: .skip 8
dependency_selected_count: .skip 8
dependency_new_record: .skip 64
dependency_replace_row: .skip 8
dependency_origin: .skip 8
dependency_new_origin: .skip 8
dependency_remove_name: .skip 8
dependency_sync_artifact: .skip 8
dependency_stat: .skip RV_STAT_BYTES
dependency_package_path: .skip 256
dependency_archive_path: .skip 128
dependency_temp_lock: .skip 96
dependency_number: .skip 32
dependency_lock_buffer: .skip 1048578
.section .note.GNU-stack,""
