/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and README.md#license for the terms and scope.
 */
.global cmd_add, cmd_update, cmd_remove, cmd_lock, cmd_sync
.global verify_project_dependencies, release_dependency_lock

/* Direct source dependencies use exact versions. asm.lock stores the same
 * eight fields as registry v1, after a versioned header and registry origin.
 * No ranges, transitive resolution, hooks or implicit source imports exist.
 * Returning routines preserve x19/x20/x21-x24; other registers are scratch.
 */
/* Native AArch64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each ARM_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */

.section .text
cmd_add:
    ARM_IMM w10, 6
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command
cmd_update:
    ARM_IMM w10, 7
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command

/* Input: registry_selected is validated and points into the registry buffer.
 * Save its eight pointers before loading the independent lock buffer. Require
 * a project and a single registry origin. Take a nonblocking exclusive project
 * lock. Existing lock records are retained until verified extraction succeeds.
 * Output: registry_selected points to dependency_new_record; locked rows are
 * in registry_rows. Stack: 48 saved bytes. Fatal failures preserve asm.lock. */
dependency_prepare_selection:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, registry_target
    ldr x9, [x16]
    ARM_ADDR x16, project_requested_target
    str x9, [x16]
    ARM_CALL read_manifest
    ARM_ADDR x16, dependency_new_record
    mov x0, x16
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x1, x10
    ARM_IMM w10, 8
    mov w3, w10
    cbz x3, .Lport_dependencies_1_end
.Lport_dependencies_1:
    ldr x10, [x1], #8
    str x10, [x0], #8
    sub x3, x3, #1
    cbnz x3, .Lport_dependencies_1
.Lport_dependencies_1_end:
    ARM_ADDR x16, dependency_new_record
    mov x9, x16
    ARM_ADDR x16, registry_selected
    str x9, [x16]
    ARM_ADDR x16, registry_url
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, registry_local_index
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Ldep_new_origin
    ARM_ADDR x16, dependency_local_origin
    mov x9, x16
.Ldep_new_origin:
    ARM_ADDR x16, dependency_new_origin
    str x9, [x16]
    ARM_IMM w10, 6
    mov w0, w10
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL dependency_acquire
    ARM_CALL dependency_load_lock
    tst w9, w9
    b.eq .Ldep_check_origin
    ARM_ADDR x16, dependency_new_origin
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, dependency_origin
    str x9, [x16]
    b .Ldep_find_previous
.Ldep_check_origin:
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, dependency_new_origin
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_origin_error
.Ldep_find_previous:
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
    ARM_ADDR x16, dependency_new_record
    mov x19, x16
.Ldep_previous_loop:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Ldep_previous_done
    mov x16, x21
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Ldep_previous_next
    ldr x0, [x21, #16]
    ldr x1, [x19, #16]
    ARM_CALL streq
    cbz w9, .Ldep_previous_next
    ARM_ADDR x16, dependency_replace_row
    str x21, [x16]
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 7
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Ldep_previous_done
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_already_locked
    mov x16, x21
    add x16, x16, #32
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
    mov x16, x21
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #40
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
    mov x16, x21
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #48
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
    b .Ldep_previous_done
.Ldep_previous_next:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_previous_loop
.Ldep_previous_done:
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 7
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Ldep_prepare_done
    ARM_ADDR x16, dependency_replace_row
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq dependency_missing_selection
    /* Updating a version may not change the bytes of the same version. */
    ARM_ADDR x16, dependency_replace_row
    ldr x10, [x16]
    mov x21, x10
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Ldep_prepare_done
    mov x16, x21
    add x16, x16, #32
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
    mov x16, x21
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #40
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
    mov x16, x21
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, #48
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
.Ldep_prepare_done:
    ARM_ADDR x16, dependency_new_record
    mov x9, x16
    ARM_ADDR x16, registry_selected
    str x9, [x16]
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: verified private payload and dependency_new_record. Extract or compare
 * the exact source tree before changing asm.lock. Cache archives are derived
 * data named by their digest; a verified replacement can repair those bytes.
 * The lock rename is the final operation. Unreferenced cache data can remain
 * after a filesystem failure; the previous lock remains usable. No return. */
dependency_finish_add:
    ARM_ADDR x16, dependency_new_record
    mov x19, x16
    ARM_ADDR x16, registry_selected
    str x19, [x16]
    ARM_IMM w10, 1
    mov w0, w10
    ARM_CALL dependency_paths
    ARM_CALL dependency_accept_payload
    ARM_ADDR x16, dependency_replace_row
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.ne .Ldep_replace_record
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 4096
    cmp x9, x11
    b.hs dependency_lock_error
    lsl x9, x9, #6
    tst x9, x9
    ARM_ADDR x16, registry_rows
    mov x0, x16
    adds x0, x0, x9
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, registry_row_count
    str x12, [x16]
.Ldep_replace_record:
    ARM_ADDR x16, dependency_new_record
    mov x1, x16
    ARM_IMM w10, 8
    mov w3, w10
    cbz x3, .Lport_dependencies_2_end
.Lport_dependencies_2:
    ldr x10, [x1], #8
    str x10, [x0], #8
    sub x3, x3, #1
    cbnz x3, .Lport_dependencies_2
.Lport_dependencies_2_end:
    ARM_CALL dependency_write_lock
    ARM_CALL registry_cleanup
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Ldep_add_json
    ARM_ADDR x16, dependency_added_text
    mov x0, x16
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 7
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Ldep_add_text
    ARM_ADDR x16, dependency_updated_text
    mov x0, x16
.Ldep_add_text:
    ARM_CALL out
    b exit_ok
.Ldep_add_json:
    ARM_ADDR x16, dependency_result_prefix
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, dependency_new_record
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, registry_fetch_json_version
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, dependency_new_record + 8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, dependency_result_cache
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, dependency_package_path
    mov x0, x16
    ARM_CALL registry_json_string
    ARM_ADDR x16, dependency_result_suffix
    mov x0, x16
    ARM_CALL out
    b exit_ok

/* Input: w0=flock operation 5(shared/nonblocking) or 6(exclusive/nonblocking),
 * w1=allow creating .asm. Output: held descriptor in dependency_lock_fd.
 * The empty coordination file is regular, non-symlink, and has one hard link.
 * Cooperation prevents lost updates between asm processes in this project.
 * It is not a sandbox against a process that ignores flock. Stack: 16 saved bytes. */
dependency_acquire:
    ARM_SAVE x21
    mov w21, w0
    tst w1, w1
    b.eq .Ldep_existing_root
    ARM_ADDR x16, dependency_root
    mov x0, x16
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi dependency_io_error
    b .Ldep_open_lock
.Ldep_existing_root:
    ARM_ADDR x16, dependency_root
    mov x0, x16
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi dependency_cache_missing
    ARM_ADDR x16, dependency_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne dependency_io_error
.Ldep_open_lock:
    ARM_ADDR x16, dependency_operation_lock
    mov x0, x16
    ARM_IMM w10, 64 | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    mov w1, w10
    ARM_IMM w10, 384
    mov w2, w10
    ARM_CALL arm_open
    tst x9, x9
    b.mi dependency_io_error
    ARM_ADDR x16, dependency_lock_fd
    str x9, [x16]
    mov x0, x9
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi dependency_io_error
    ARM_ADDR x16, dependency_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne dependency_io_error
    ARM_ADDR x16, dependency_stat + ARM_STAT_LINKS
    ldr w10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne dependency_io_error
    ARM_ADDR x16, dependency_lock_fd
    ldr x10, [x16]
    mov x0, x10
    mov w1, w21
    ARM_CALL arm_flock
    tst x9, x9
    b.mi dependency_busy
    ARM_RESTORE x21
    ret

/* Closes only a descriptor acquired above, releasing its advisory lock.
 * Output: dependency_lock_fd=-1. Safe if no lock was acquired. Stack: none. */
release_dependency_lock:
    ARM_ADDR x16, dependency_lock_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM x11, 0
    cmp x0, x11
    b.lt .Ldep_release_done
    ARM_CALL arm_close
    ARM_IMM x10, -1
    ARM_ADDR x16, dependency_lock_fd
    str x10, [x16]
.Ldep_release_done:
    ret

/* Input: cwd. Reads a regular asm.lock into its own <=1MiB buffer. Output:
 * w9=0 loaded, w9=1 absent; registry_rows/count and dependency_origin updated.
 * The selected remote record must be saved before this routine is called.
 * v1 retains host-only rows. v2 keys each row by package and declared target.
 * All metadata, kinds, targets and duplicate identities are checked before use. Stack: 64 saved bytes. Missing does not create a file. */
dependency_load_lock:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_row_count
    str x10, [x16]
    ARM_ADDR x16, dependency_selected_count
    str x10, [x16]
    mov w10, #1
    ARM_ADDR x16, dependency_lock_version
    strb w10, [x16]
    ARM_ADDR x16, dependency_lock_path
    mov x0, x16
    ARM_IMM w10, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    ARM_IMM x11, -2
    cmp x9, x11
    b.eq .Ldep_no_lock
    tst x9, x9
    b.mi dependency_lock_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Ldep_read_bad
    ARM_ADDR x16, dependency_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Ldep_read_bad
    ARM_ADDR x16, dependency_stat + ARM_STAT_SIZE
    ldr x10, [x16]
    ARM_IMM x11, 1048576
    cmp x10, x11
    b.hi .Ldep_read_bad
    eor w22, w22, w22
    tst w22, w22
.Ldep_read_loop:
    mov x0, x21
    ARM_ADDR x16, dependency_lock_buffer
    mov x1, x16
    adds x1, x1, x22
    ARM_IMM w10, 1048577
    mov w2, w10
    subs x2, x2, x22
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Ldep_read_loop
    tst x9, x9
    b.mi .Ldep_read_bad
    b.eq .Ldep_read_done
    adds x22, x22, x9
    ARM_IMM x11, 1048576
    cmp x22, x11
    b.hi .Ldep_read_bad
    b .Ldep_read_loop
.Ldep_read_done:
    mov x0, x21
    ARM_CALL arm_close
    ARM_ADDR x16, dependency_lock_buffer
    mov x0, x16
    mov x16, x0
    add x16, x16, x22
    mov x23, x16
    ARM_IMM w10, 0
    mov x16, x23
    strb w10, [x16]
    ARM_ADDR x16, dependency_header
    mov x1, x16
    ARM_CALL dependency_prefix
    cbnz x9, .Ldep_header_found
    ARM_ADDR x0, dependency_lock_buffer
    ARM_ADDR x1, dependency_header_v2
    ARM_CALL dependency_prefix
    cbz x9, dependency_lock_error
    mov w10, #2
    ARM_ADDR x16, dependency_lock_version
    strb w10, [x16]
.Ldep_header_found:
    mov x0, x9
    ARM_ADDR x16, dependency_origin_prefix
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq dependency_lock_error
    ARM_ADDR x16, dependency_origin
    str x9, [x16]
    mov x21, x9
    eor w3, w3, w3
    tst w3, w3
.Ldep_origin_scan:
    cmp x21, x23
    b.hs dependency_lock_error
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Ldep_origin_end
    and w10, w9, #255
    ARM_IMM w11, 33
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo dependency_lock_error
    and w10, w9, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi dependency_lock_error
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 4095
    cmp w3, w11
    b.hi dependency_lock_error
    b .Ldep_origin_scan
.Ldep_origin_end:
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, dependency_local_origin
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Ldep_parse_rows
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_https_url
    tst w9, w9
    b.eq dependency_lock_error
.Ldep_parse_rows:
    mov x0, x21
    mov x1, x23
    ARM_CALL registry_parse_records
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Ldep_validate_record:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Ldep_loaded
    ARM_ADDR x16, dependency_lock_version
    ldrb w10, [x16]
    cmp w10, #1
    b.ne .Ldep_declared_target
    ldr x0, [x21, #16]
    ARM_ADDR x1, registry_host
    ARM_CALL streq
    cbz w9, dependency_lock_error
.Ldep_declared_target:
    ldr x0, [x21, #16]
    ARM_CALL project_declares_target
    cbz w9, dependency_lock_error
    mov x16, x21
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_source_kind
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_lock_error
    ARM_ADDR x16, registry_rows
    mov x19, x16
.Ldep_duplicate_package:
    cmp x19, x21
    b.hs .Ldep_record_next
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    mov x16, x21
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Ldep_duplicate_next
    ldr x0, [x19, #16]
    ldr x1, [x21, #16]
    ARM_CALL streq
    cbnz w9, dependency_lock_error
.Ldep_duplicate_next:
    ARM_IMM x11, 64
    adds x19, x19, x11
    b .Ldep_duplicate_package
.Ldep_record_next:
    ldr x0, [x21, #16]
    ARM_ADDR x1, package_target
    ARM_CALL streq
    cbz w9, .Ldep_record_unselected
    ARM_ADDR x16, dependency_selected_count
    ldr x10, [x16]
    add x10, x10, #1
    str x10, [x16]
.Ldep_record_unselected:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_validate_record
.Ldep_loaded:
    eor w9, w9, w9
    tst w9, w9
    b .Ldep_load_return
.Ldep_no_lock:
    ARM_IMM w10, 1
    mov w9, w10
.Ldep_load_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
.Ldep_read_bad:
    mov x0, x21
    ARM_CALL arm_close
    b dependency_lock_error

/* Input: x0=input, x1=constant prefix. Output: x9=first byte after prefix,
 * or zero on mismatch. Read-only; inputs point into bounded NUL buffers. */
dependency_prefix:
    eor w3, w3, w3
    tst w3, w3
.Ldep_prefix_loop:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Ldep_prefix_done
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Ldep_prefix_bad
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Ldep_prefix_loop
.Ldep_prefix_done:
    mov x16, x0
    add x16, x16, x3
    mov x9, x16
    ret
.Ldep_prefix_bad:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Input: registry_selected=validated source record, w0=create parent dirs.
 * Output: package path .asm/packages/owner/name/version/target (<=180 bytes),
 * and archive .asm/cache/<sha256>.tar.gz (<=90 bytes). Does not create the final
 * extraction directory. Existing directory components must not be symlinks.
 * Stack: 64 saved bytes. Buffer capacities 256 and 128. */
dependency_paths:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov w23, w0
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
    ARM_ADDR x16, dependency_packages_root
    mov x0, x16
    mov w1, w23
    ARM_CALL dependency_directory
    tst x9, x9
    b.mi dependency_io_error
    ARM_ADDR x16, dependency_cache_root
    mov x0, x16
    mov w1, w23
    ARM_CALL dependency_directory
    tst x9, x9
    b.mi dependency_io_error
.Ldep_path_copy:
    ARM_ADDR x16, dependency_package_path
    mov x0, x16
    ARM_ADDR x16, dependency_packages_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x21, x9
    mov x16, x19
    ldr x10, [x16]
    mov x22, x10
.Ldep_owner_copy:
    mov x16, x22
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Ldep_owner_done
    and w10, w9, #255
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_owner_copy
.Ldep_owner_done:
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_ADDR x16, dependency_package_path
    mov x0, x16
    mov w1, w23
    ARM_CALL dependency_directory
    tst x9, x9
    b.mi dependency_io_error
.Ldep_name_copy:
    mov x0, x21
    mov x1, x22
    ARM_CALL copy_string
    mov x21, x9
    ARM_ADDR x16, dependency_package_path
    mov x0, x16
    mov w1, w23
    ARM_CALL dependency_directory
    tst x9, x9
    b.mi dependency_io_error
.Ldep_version_copy:
    ARM_IMM w10, 47
    mov x16, x21
    strb w10, [x16]
    mov x16, x21
    add x16, x16, #1
    mov x0, x16
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x21, x9
    ARM_ADDR x16, dependency_package_path
    mov x0, x16
    mov w1, w23
    ARM_CALL dependency_directory
    tst x9, x9
    b.mi dependency_io_error
.Ldep_target_copy:
    ARM_IMM w10, 47
    mov x16, x21
    strb w10, [x16]
    mov x16, x21
    add x16, x16, #1
    mov x0, x16
    mov x16, x19
    add x16, x16, #16
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    ARM_ADDR x16, dependency_archive_path
    mov x0, x16
    ARM_ADDR x16, dependency_cache_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x16, x19
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_tar_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: x0=one cache directory component, w1=allow creation. Output: zero
 * or one for a real directory, negative on failure. Read-only mode still
 * rejects symbolic links at every checked component. Stack: none. */
dependency_directory:
    tst w1, w1
    b.ne make_safe_dir
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi .Ldep_directory_return
    ARM_ADDR x16, dependency_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne .Ldep_directory_bad
    eor w9, w9, w9
    tst w9, w9
    ret
.Ldep_directory_bad:
    ARM_IMM x10, -1
    mov x9, x10
.Ldep_directory_return:
    ret

/* Input: private payload has passed size+SHA256; dependency paths are set.
 * Compare an existing cache tree or extract a new one with the native archive
 * module. Then atomically store the verified archive in the managed digest
 * cache. Does not modify asm.lock. No package code runs. */
dependency_accept_payload:
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ldr x10, [x16]
    mov x1, x10
    mov x16, x9
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
    mov x16, x9
    add x16, x16, #16
    ldr x10, [x16]
    mov x3, x10
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL validate_source_package
    tst w9, w9
    b.ne dependency_archive_error
    ARM_ADDR x16, dependency_package_path
    mov x0, x16
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    ARM_IMM x11, -2
    cmp x9, x11
    b.eq .Ldep_extract_new
    tst x9, x9
    b.mi dependency_io_error
    ARM_ADDR x16, dependency_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne dependency_cache_changed
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, dependency_package_path
    mov x1, x16
    ARM_CALL verify_source_archive
    tst w9, w9
    b.ne dependency_cache_changed
    b .Ldep_store_archive
.Ldep_extract_new:
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, dependency_package_path
    mov x1, x16
    ARM_CALL extract_source_archive
    tst w9, w9
    b.ne dependency_archive_error
.Ldep_store_archive:
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_IMM w10, 420
    mov w1, w10
    ARM_CALL arm_chmod
    tst x9, x9
    b.mi dependency_io_error
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, dependency_archive_path
    mov x1, x16
    ARM_CALL arm_rename
    tst x9, x9
    b.mi dependency_io_error
    ret

/* Input: registry_rows/count and one validated dependency_origin. Writes a
 * canonical lock to an exclusive private temporary file, fsyncs it, then
 * renames it onto asm.lock. The held project lock serializes writers. Each
 * field is already bounded printable text. Stack: 80 saved bytes plus calls. */
dependency_write_lock:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    /* Bound the serialized file, not just its record count. Otherwise an
     * append could write a lock that the bounded reader cannot reopen. */
    ARM_ADDR x0, dependency_header
    ARM_ADDR x16, dependency_lock_version
    ldrb w10, [x16]
    cmp w10, #2
    b.eq .Ldep_write_v2
    ARM_ADDR x16, project_target_mask
    ldr x10, [x16]
    cbnz x10, .Ldep_write_v2
    /* The legacy v1 reader accepts native rows only. Foreign selections
     * require v2 even when the manifest uses one legacy build table. */
    ARM_ADDR x0, package_target
    ARM_ADDR x1, registry_host
    ARM_CALL streq
    cbz w9, .Ldep_write_v2
    ARM_ADDR x0, dependency_header
    b .Ldep_write_header_ready
.Ldep_write_v2:
    ARM_ADDR x0, dependency_header_v2
.Ldep_write_header_ready:
    ARM_ADDR x16, dependency_write_header
    str x0, [x16]
    ARM_CALL strlen
    mov x24, x9
    ARM_ADDR x16, dependency_origin_prefix
    mov x0, x16
    ARM_CALL strlen
    adds x24, x24, x9
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    mov x16, x24
    add x16, x16, x9
    add x16, x16, #1
    mov x24, x16
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Ldep_measure_record:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Ldep_measure_done
    eor w23, w23, w23
    tst w23, w23
.Ldep_measure_field:
    mov x16, x21
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    mov x16, x24
    add x16, x16, x9
    add x16, x16, #1
    mov x24, x16
    ARM_IMM x11, 1048576
    cmp x24, x11
    b.hi dependency_lock_too_large
    ARM_IMM w11, 1
    adds w23, w23, w11
    ARM_IMM w11, 8
    cmp w23, w11
    b.lo .Ldep_measure_field
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_measure_record
.Ldep_measure_done:
    ARM_IMM x11, 1048576
    cmp x24, x11
    b.hi dependency_lock_too_large
    ARM_CALL registry_workspace
    ARM_ADDR x16, dependency_temp_lock
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, dependency_lock_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, dependency_temp_lock
    mov x9, x16
    ARM_ADDR x16, registry_extra_temp
    str x9, [x16]
    ARM_ADDR x16, registry_extra_temp
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, 193 | O_NOFOLLOW | O_CLOEXEC
    mov w1, w10
    ARM_IMM w10, 420
    mov w2, w10
    ARM_CALL arm_open
    tst x9, x9
    b.mi dependency_io_error
    mov x19, x9
    ARM_ADDR x16, dependency_write_header
    ldr x1, [x16]
    ARM_CALL dependency_write_string
    ARM_ADDR x16, dependency_origin_prefix
    mov x1, x16
    ARM_CALL dependency_write_string
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL dependency_write_string
    ARM_ADDR x16, registry_newline
    mov x1, x16
    ARM_CALL dependency_write_string
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Ldep_write_record:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Ldep_write_end
    eor w23, w23, w23
    tst w23, w23
.Ldep_write_field:
    mov x16, x21
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL dependency_write_string
    ARM_ADDR x16, registry_tab
    mov x1, x16
    ARM_IMM w11, 7
    cmp w23, w11
    b.ne .Ldep_write_separator
    ARM_ADDR x16, registry_newline
    mov x1, x16
.Ldep_write_separator:
    ARM_CALL dependency_write_string
    ARM_IMM w11, 1
    adds w23, w23, w11
    ARM_IMM w11, 8
    cmp w23, w11
    b.lo .Ldep_write_field
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_write_record
.Ldep_write_end:
    mov x0, x19
    ARM_CALL arm_fsync
    tst x9, x9
    b.mi dependency_io_error
    mov x0, x19
    ARM_CALL arm_close
    tst x9, x9
    b.mi dependency_io_error
    ARM_ADDR x16, dependency_temp_lock
    mov x0, x16
    ARM_ADDR x16, dependency_lock_path
    mov x1, x16
    ARM_CALL arm_rename
    tst x9, x9
    b.mi dependency_io_error
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_extra_temp
    str x10, [x16]
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: x19=owned lock file descriptor, x1=validated string. Returns only
 * after complete write; fatal error preserves the previous asm.lock. */
dependency_write_string:
    mov x0, x19
    ARM_CALL write_cstr
    tst x9, x9
    b.mi dependency_io_error
    ret

/* Core build entry. Input: require_lock selects strict missing-lock behavior.
 * Builds verify selected-target dependencies when asm.lock exists. Each archive
 * is copied into a private stage, checked against its locked size/digest, and
 * compared byte-for-byte to its extracted cache, including unexpected members.
 * Output: returns with a shared project lock held until build completion.
 * Does not fetch, resolve new versions, execute code or modify source caches. */
verify_project_dependencies:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, dependency_lock_path
    mov x0, x16
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    ARM_IMM x11, -2
    cmp x9, x11
    b.ne .Ldep_verify_present
    ARM_ADDR x16, require_lock
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne dependency_lock_missing
    b .Ldep_verify_done
.Ldep_verify_present:
    tst x9, x9
    b.mi dependency_lock_error
    ARM_IMM w10, 5
    mov w0, w10
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL dependency_acquire
    ARM_CALL dependency_load_lock
    tst w9, w9
    b.ne dependency_lock_missing
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Ldep_verify_row:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Ldep_verify_done
    ldr x0, [x21, #16]
    ARM_ADDR x1, package_target
    ARM_CALL streq
    cbz w9, .Ldep_verify_next
    ARM_ADDR x16, registry_selected
    str x21, [x16]
    mov x16, x21
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
    eor w0, w0, w0
    tst w0, w0
    ARM_CALL dependency_paths
    ARM_ADDR x16, dependency_archive_path
    mov x0, x16
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi dependency_cache_missing
    ARM_CALL registry_workspace
    ARM_ADDR x16, dependency_archive_path
    mov x9, x16
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    ARM_CALL registry_copy_local
    ARM_CALL registry_verify_payload
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    mov x16, x21
    ldr x10, [x16]
    mov x1, x10
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
    mov x16, x21
    add x16, x16, #16
    ldr x10, [x16]
    mov x3, x10
    ARM_CALL validate_source_package
    tst w9, w9
    b.ne dependency_archive_error
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, dependency_package_path
    mov x1, x16
    ARM_CALL verify_source_archive
    tst w9, w9
    b.ne dependency_cache_changed
    ARM_CALL registry_cleanup
.Ldep_verify_next:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_verify_row
.Ldep_verify_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

cmd_lock:
    ARM_CALL parse_options_only
    ARM_CALL read_manifest
    ARM_IMM w10, 1
    ARM_ADDR x16, require_lock
    strb w10, [x16]
    ARM_CALL verify_project_dependencies
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, dependency_locked_text
    mov x0, x16
    b dependency_count_report

cmd_remove:
    ARM_CALL dependency_parse_name
    ARM_CALL read_manifest
    ARM_IMM w10, 6
    mov w0, w10
    eor w1, w1, w1
    tst w1, w1
    ARM_CALL dependency_acquire
    ARM_CALL dependency_load_lock
    tst w9, w9
    b.ne dependency_lock_missing
    ARM_ADDR x16, registry_rows
    mov x21, x16
    mov x22, x21
    eor w23, w23, w23
    tst w23, w23
    eor w24, w24, w24
    tst w24, w24
.Ldep_remove_row:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x23, x11
    b.hs .Ldep_remove_done
    mov x16, x21
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, dependency_remove_name
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Ldep_remove_keep
    ldr x0, [x21, #16]
    ARM_ADDR x1, package_target
    ARM_CALL streq
    cbnz w9, .Ldep_remove_match
.Ldep_remove_keep:
    mov x0, x22
    mov x1, x21
    ARM_IMM w10, 8
    mov w3, w10
    cbz x3, .Lport_dependencies_3_end
.Lport_dependencies_3:
    ldr x10, [x1], #8
    str x10, [x0], #8
    sub x3, x3, #1
    cbnz x3, .Lport_dependencies_3
.Lport_dependencies_3_end:
    ARM_IMM x11, 64
    adds x22, x22, x11
    b .Ldep_remove_next
.Ldep_remove_match:
    ARM_IMM w11, 1
    adds w24, w24, w11
.Ldep_remove_next:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x23, x23, x11
    b .Ldep_remove_row
.Ldep_remove_done:
    tst w24, w24
    b.eq dependency_missing_selection
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    subs x12, x10, x24
    ARM_ADDR x16, registry_row_count
    str x12, [x16]
    ARM_ADDR x16, dependency_selected_count
    ldr x10, [x16]
    sub x10, x10, x24
    str x10, [x16]
    ARM_CALL dependency_write_lock
    ARM_CALL registry_cleanup
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, dependency_removed_text
    mov x0, x16
    b dependency_count_report

/* Parse remove's one owner/name operand and common output options. Input:
 * argv cursor follows command. Output: borrowed dependency_remove_name.
 * Unknown arguments or selectors with versions exit 2 before file changes. */
dependency_parse_name:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Ldep_remove_args_done
    mov x21, x9
    ARM_CALL common_option
    tst w9, w9
    b.ne dependency_parse_name
    ARM_ADDR x16, dependency_remove_name
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    mov x0, x21
    ARM_CALL registry_valid_package
    tst w9, w9
    b.eq registry_bad_args
    ARM_ADDR x16, dependency_remove_name
    str x21, [x16]
    b dependency_parse_name
.Ldep_remove_args_done:
    ARM_ADDR x16, dependency_remove_name
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq registry_bad_args
    ret

/* Sync downloads locked exact URLs. It never reads a newer registry index.
 * --artifact FILE requires exactly one selected-target dependency.
 * Existing extracted source must match; sync does not discard local edits. */
cmd_sync:
.Ldep_sync_args:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Ldep_sync_start
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, registry_opt_artifact
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq .Ldep_sync_common
    ARM_ADDR x16, dependency_sync_artifact
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, dependency_sync_artifact
    str x9, [x16]
    b .Ldep_sync_args
.Ldep_sync_common:
    mov x9, x21
    ARM_CALL common_option
    tst w9, w9
    b.eq registry_bad_args
    b .Ldep_sync_args
.Ldep_sync_start:
    ARM_CALL read_manifest
    ARM_IMM w10, 6
    mov w0, w10
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL dependency_acquire
    ARM_CALL dependency_load_lock
    tst w9, w9
    b.ne dependency_lock_missing
    ARM_ADDR x16, dependency_sync_artifact
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Ldep_sync_begin
    ARM_ADDR x16, dependency_selected_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne registry_bad_args
.Ldep_sync_begin:
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Ldep_sync_row:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Ldep_sync_done
    ldr x0, [x21, #16]
    ARM_ADDR x1, package_target
    ARM_CALL streq
    cbz w9, .Ldep_sync_next
    ARM_ADDR x16, registry_selected
    str x21, [x16]
    mov x16, x21
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
    ARM_IMM w10, 1
    mov w0, w10
    ARM_CALL dependency_paths
    ARM_CALL registry_workspace
    ARM_ADDR x16, dependency_sync_artifact
    ldr x10, [x16]
    mov x9, x10
    tst x9, x9
    b.eq .Ldep_sync_remote
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    ARM_CALL registry_copy_local
    b .Ldep_sync_verified
.Ldep_sync_remote:
    mov x16, x21
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_payload
    mov x1, x16
    mov x16, x21
    add x16, x16, #48
    ldr x10, [x16]
    mov x2, x10
    ARM_CALL registry_download
    tst w9, w9
    b.ne registry_download_error
.Ldep_sync_verified:
    ARM_CALL registry_verify_payload
    ARM_CALL dependency_accept_payload
    ARM_CALL registry_cleanup
.Ldep_sync_next:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Ldep_sync_row
.Ldep_sync_done:
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, dependency_synced_text
    mov x0, x16
    b dependency_count_report

/* Terminal report. Input: x0=plain success text; selected_count is the locked
 * count. JSON writes a numeric count, not a package-safety claim. */
dependency_count_report:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Ldep_report_text
    ARM_ADDR x16, dependency_count_prefix
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, dependency_selected_count
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, dependency_number + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x0, x9
    ARM_CALL out
    ARM_ADDR x16, dependency_result_suffix
    mov x0, x16
.Ldep_report_text:
    ARM_CALL out
    b exit_ok

dependency_io_error:
    ARM_ADDR x16, dependency_err_io
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_lock_error:
    ARM_ADDR x16, dependency_err_lock
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_lock_missing:
    ARM_ADDR x16, dependency_err_lock_missing
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_cache_missing:
    ARM_ADDR x16, dependency_err_cache_missing
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_cache_changed:
    ARM_ADDR x16, dependency_err_cache_changed
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_archive_error:
    ARM_ADDR x16, dependency_err_archive
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_origin_error:
    ARM_ADDR x16, dependency_err_origin
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_already_locked:
    ARM_ADDR x16, dependency_err_already
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_changed_release:
    ARM_ADDR x16, dependency_err_changed
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_missing_selection:
    ARM_ADDR x16, dependency_err_selection
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_busy:
    ARM_ADDR x16, dependency_err_busy
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
dependency_lock_too_large:
    ARM_ADDR x16, dependency_err_large
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail

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
dependency_stat: .skip ARM_STAT_BYTES
dependency_package_path: .skip 256
dependency_archive_path: .skip 128
dependency_temp_lock: .skip 96
dependency_number: .skip 32
dependency_lock_buffer: .skip 1048578
.section .note.GNU-stack,"",%progbits
