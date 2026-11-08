/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native V2 dependency metadata, complete graph locks and exact source sync.
 * Native AArch64 ABI: x0/x1/x2/x3 inputs, x9 result. Preserve x19-x24 and SP.
 * Serial process-owned state; no package code or shell is executed.
 * Bounds: 4095 inventory rows, 256 reached versions/names, 64 edges/version,
 * 64 roots, 1 MiB lock. Existing transport/archive limits remain in force.
 * Mirrors are transport inputs. Registry ID and initial root bind authority.
 */
.equ R3_CANDIDATES, 256
.equ R3_NODE, 512
.equ R3_DEPS, 15360
.section .text

/* Parsed command, no selector. Resolve=5, sync=6. Changes cwd to a checked
 * project directory, takes its operation lock, and exits. No return. */
r3_command:
    mov x10, x2
    ARM_IMM x11, 4832
    cmp x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r2_mirror_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq r2_arguments
    ARM_ADDR x16, r2_registry_id
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_root
    ldr x0, [x16]
    ARM_CALL program_valid_absolute_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_state
    ldr x0, [x16]
    ARM_CALL program_valid_absolute_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_ca
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr3_project
    ARM_ADDR x16, r2_ca
    ldr x0, [x16]
    ARM_CALL program_valid_absolute_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
.Lr3_project:
    ARM_ADDR x16, r2p_project
    ldr x0, [x16]
    ARM_IMM w1, 1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x21, x9
    mov x0, x9
    ARM_IMM w9, 81
    ARM_CALL arm_fchdir
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x0, x21
    ARM_IMM w9, 3
    ARM_CALL arm_close
    ARM_ADDR x16, r2_target
    ldr x9, [x16]
    ARM_ADDR x16, project_requested_target
    str x9, [x16]
    ARM_CALL read_manifest
    ARM_IMM w0, 6
    ARM_IMM w1, 1
    ARM_CALL dependency_acquire
    ARM_IMM w10, 1
    ARM_ADDR x16, r3_active
    strb w10, [x16]
    ARM_CALL r2_workspace
    ARM_CALL r2_prepare_adapter
    ARM_ADDR x16, r2_root
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_IMM w9, 3
    ARM_CALL arm_close
    ARM_ADDR x16, r2_root
    ldr x0, [x16]
    ARM_CALL r2_hash_path
    ARM_ADDR x16, r2_root_sha
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    ARM_CALL r3_roots
    ARM_CALL r4_validate_selection
    ARM_CALL r3_read_lock
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_have_lock
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 6
    cmp x10, x11
    b.eq r3_lock_error
    b .Lr3_catalog
.Lr3_have_lock:
    ARM_CALL r3_lock_header
.Lr3_catalog:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 5
    cmp x10, x11
    b.ne .Lr3_catalog_ready
    ARM_IMM x10, 4
    ARM_ADDR x16, r4_format
    str x10, [x16]
.Lr3_catalog_ready:
    ARM_CALL r3_catalog
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 6
    cmp x10, x11
    b.eq .Lr3_sync
    ARM_CALL r3_discover
    ARM_CALL r3_render
    ARM_CALL r3_preserve_bindings
    ARM_CALL r3_check_policy
    ARM_CALL r3_write_lock
    b .Lr3_report
.Lr3_sync:
    ARM_CALL r3_locked_candidates
    ARM_CALL r3_solve
    ARM_CALL r3_render
    ARM_CALL r3_compare_lock
    ARM_CALL r3_materialize
    ARM_CALL r3_check_policy
.Lr3_report:
    ARM_CALL registry_cleanup
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq exit_ok
    ARM_ADDR x16, r3_result_prefix
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, r3_order_count
    ldr x0, [x16]
    ARM_ADDR x16, number_buffer + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x0, x9
    ARM_CALL out
    ARM_ADDR x16, r3_resolved
    mov x0, x16
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 5
    cmp x10, x11
    b.eq .Lr3_report_end
    ARM_ADDR x16, r3_synchronized
    mov x0, x16
.Lr3_report_end:
    ARM_CALL out
    b exit_ok

r3_lock_error:
    ARM_ADDR x16, r3_err_lock
    mov x0, x16
    b r3_fail
r3_metadata_error:
    ARM_ADDR x16, r3_err_metadata
    mov x0, x16
    b r3_fail
r3_limit_error:
    ARM_ADDR x16, r3_err_limit
    mov x0, x16
    b r3_fail
r3_unsatisfiable:
    ARM_ADDR x16, r3_err_unsat
    mov x0, x16
    b r3_fail
r3_changed_binding:
    ARM_ADDR x16, r3_err_changed
    mov x0, x16
r3_fail:
    ARM_IMM w1, 1
    b registry_fail

/* Copy validated root declarations before archive checks overwrite the shared
 * project parser. Bind the exact root manifest, not its working directory.
 * No arguments/results. Own root_data[64*240], roots[64*16], manifest_sha[65]. */
r3_roots:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    ARM_ADDR x16, g3_root_count
    str x9, [x16]
    mov x10, x9
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x3, x10, x11
    asr x13, x3, #63
    cmp x12, x13
    ARM_ADDR x16, r3_root_data
    mov x0, x16
    ARM_ADDR x16, g3_project_deps
    mov x1, x16
    cbz x3, .Lr3_arm_copy_1_end
.Lr3_arm_copy_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr3_arm_copy_1
.Lr3_arm_copy_1_end:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, g3_roots
    mov x21, x16
.Lr3_root_pair:
    mov x10, x19
    ARM_ADDR x16, g3_root_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_root_hash
    mov x10, x19
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r3_root_data
    mov x2, x16
    mov x11, x9
    adds x2, x2, x11
    mov x16, x21
    str x2, [x16]
    ARM_IMM x11, 105
    adds x2, x2, x11
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    str x2, [x16]
    ARM_IMM x11, 16
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_root_pair
.Lr3_root_hash:
    ARM_ADDR x16, r4_root_profile
    mov x0, x16
    ARM_ADDR x16, g4_project_profile
    mov x1, x16
    ARM_CALL g4_profile_copy
    ARM_ADDR x16, g4_root_profile
    str x9, [x16]
    ARM_ADDR x16, manifest_path
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, r3_manifest_sha
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Existing signed policy validator calls this only after validating a row.
 * Copy its six borrowed fields. No args/result; catalog records are 256B.
 * Sorted policy names make all versions adjacent. Their package ID must stay
 * equal, including yanked/revoked rows. Bounds precede writes; Stack 16. */
r3_policy_row:
    ARM_SAVE x19
    ARM_ADDR x16, r3_catalog_count
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 4095
    cmp x10, x11
    b.hs r3_limit_error
    lsl x9, x9, #8
    ARM_ADDR x16, r3_inventory
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    ARM_ADDR x16, r3_catalog_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr3_policy_copy
    mov x16, x19
    ARM_IMM x17, 256
    sub x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_policy_copy
    mov x16, x19
    ARM_IMM x17, 256
    sub x16, x16, x17
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 16
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_changed_binding
.Lr3_policy_copy:
    mov x0, x19
    ARM_ADDR x16, r2_policy_fields
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 8
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 16
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 24
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_IMM w10, 0
    mov x16, x19
    ARM_IMM x17, 204
    add x16, x16, x17
    strb w10, [x16]
    ARM_ADDR x16, r2_policy_fields + 32
    ldr x9, [x16]
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr3_policy_row_end
    ARM_ADDR x16, r2_policy_fields + 40
    ldr x9, [x16]
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr3_policy_row_end
    ARM_IMM w10, 1
    mov x16, x19
    ARM_IMM x17, 204
    add x16, x16, x17
    strb w10, [x16]
.Lr3_policy_row_end:
    ARM_ADDR x16, r3_catalog_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r3_catalog_count
    str x10, [x16]
    ARM_RESTORE x19
    ret

r3_catalog:
    sub sp, sp, #16
    ARM_IMM x10, 0
    ARM_ADDR x16, r3_catalog_count
    str x10, [x16]
    ARM_CALL r2_load_policy
    add sp, sp, #16
    ret

/* x0=name, x1=version. Return x9=inventory record or zero. Read only.
 * Callee registers and inputs are preserved across string comparisons. */
r3_find_inventory:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x21, x0
    mov x22, x1
    ARM_ADDR x16, r3_inventory
    mov x19, x16
    mov w11, w23
    eor w23, w23, w11
    tst w23, w23
.Lr3_find_row:
    mov x10, x23
    ARM_ADDR x16, r3_catalog_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_find_none
    mov x0, x19
    mov x1, x21
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_find_next
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    mov x1, x22
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr3_find_yes
.Lr3_find_next:
    ARM_IMM x11, 1
    adds x23, x23, x11
    ARM_IMM x11, 256
    adds x19, x19, x11
    b .Lr3_find_row
.Lr3_find_none:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lr3_find_return
.Lr3_find_yes:
    mov x9, x19
.Lr3_find_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Add one validated name to a bounded unique discovery queue. x0=name.
 * Names are copied, so later JSON parsing and policy refresh cannot alter it. */
r3_name:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, r3_names
    mov x22, x16
.Lr3_name_find:
    mov x10, x19
    ARM_ADDR x16, r3_name_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_name_append
    mov x0, x22
    mov x1, x21
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr3_name_end
    ARM_IMM x11, 1
    adds x19, x19, x11
    ARM_IMM x11, 105
    adds x22, x22, x11
    b .Lr3_name_find
.Lr3_name_append:
    mov x10, x19
    ARM_IMM x11, R3_CANDIDATES
    cmp x10, x11
    b.hs r3_limit_error
    mov x0, x22
    mov x1, x21
    ARM_CALL copy_string
    ARM_ADDR x16, g4_known_names
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x22, [x16]
    ARM_ADDR x16, r3_name_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r3_name_count
    str x10, [x16]
    ARM_ADDR x16, g4_known_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g4_known_count
    str x10, [x16]
.Lr3_name_end:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Demand-driven discovery loads all active versions only when an active
 * solver branch requires that name. Unknown and known-empty names differ.
 * The aggregate 100000-step budget covers every retry, including validation.
 * No source blob is read. Network errors never become unsatisfiability. */
r3_discover:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_IMM x10, 1
    ARM_ADDR x16, g4_lazy
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, r4_steps
    str x10, [x16]
.Lr3_discover_solve:
    ARM_IMM w9, 100000
    ARM_ADDR x16, r4_steps
    ldr x11, [x16]
    subs x9, x9, x11
    b.ls r3_limit_error
    ARM_ADDR x16, g3_limit
    str x9, [x16]
    ARM_CALL g3_solve
    mov w19, w9
    ARM_ADDR x16, g3_steps
    ldr x9, [x16]
    ARM_ADDR x16, r4_steps
    ldr x10, [x16]
    mov x11, x9
    adds x10, x10, x11
    ARM_ADDR x16, r4_steps
    str x10, [x16]
    mov w10, w19
    ARM_IMM w11, 4
    cmp w10, w11
    b.ne .Lr3_discover_result
    ARM_ADDR x16, g4_missing_name
    ldr x0, [x16]
    ARM_CALL r3_name
    ARM_ADDR x16, r3_name_count
    ldr x9, [x16]
    ARM_IMM x11, 1
    subs x9, x9, x11
    mov x10, x9
    ARM_IMM x11, 105
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r3_names
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    ARM_ADDR x16, r3_inventory
    mov x22, x16
    mov w11, w23
    eor w23, w23, w11
    tst w23, w23
.Lr3_discover_version:
    mov x10, x23
    ARM_ADDR x16, r3_catalog_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_discover_solve
    mov x16, x22
    ARM_IMM x17, 204
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr3_discover_next_version
    mov x0, x21
    mov x1, x22
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_discover_next_version
    mov x0, x22
    ARM_CALL r3_candidate
.Lr3_discover_next_version:
    ARM_IMM x11, 1
    adds x23, x23, x11
    ARM_IMM x11, 256
    adds x22, x22, x11
    b .Lr3_discover_version
.Lr3_discover_result:
    mov w10, w19
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq r3_unsatisfiable
    mov w10, w19
    ARM_IMM w11, 2
    cmp w10, w11
    b.eq r3_limit_error
    mov w10, w19
    mov w11, w19
    tst w10, w11
    b.ne r3_metadata_error
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=validated active inventory record. Authenticate its exact envelope and
 * own its fields and dependencies. Append one solver candidate (40B).
 * All repeated-envelope parser state is reset. Stack 96 plus callees. */
r3_candidate:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x24, x0
    ARM_ADDR x16, g3_candidate_count
    ldr x21, [x16]
    mov x10, x21
    ARM_IMM x11, R3_CANDIDATES
    cmp x10, x11
    b.hs r3_limit_error
    mov x9, x21
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    mov x0, x19
    mov x1, x24
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    mov x16, x24
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x0, x16
    mov x16, x24
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_requested_name
    mov x0, x16
    mov x1, x19
    ARM_CALL copy_string
    ARM_ADDR x16, r2_requested_version
    mov x0, x16
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_source_kind
    mov x9, x16
    ARM_ADDR x16, r2_kind
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_object_count
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_total_bytes
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_tuple_bits
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_selected
    str x10, [x16]
    ARM_IMM w10, 0
    ARM_ADDR x16, r2_repository
    strb w10, [x16]
    ARM_CALL r2_release_target
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_CALL r2_get_target
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r3_metadata_error
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_CALL r2_hash_path
    mov x16, x19
    ARM_IMM x17, 204
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_envelope
    mov x1, x16
    ARM_IMM w2, R2_CONTROL
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r4_envelope_length
    str x9, [x16]
    mov x1, x9
    ARM_ADDR x16, r2_envelope
    mov x0, x16
    ARM_CALL r2_parse_json
    mov x0, x9
    ARM_CALL r2_validate_envelope
    mov x16, x19
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_package_id
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_metadata_error
    mov x16, x19
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_release_id
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_metadata_error
.Lr4_candidate_record:
    mov x16, x19
    ARM_IMM x17, 269
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_manifest_sha
    mov x1, x16
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 334
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_commit
    mov x1, x16
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 431
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_source_sha
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_source_bytes
    ldr x0, [x16]
    ARM_ADDR x16, r2_size_decimal + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x1, x9
    mov x16, x19
    ARM_IMM x17, 399
    add x16, x16, x17
    mov x0, x16
    ARM_CALL copy_string
    mov x10, x21
    ARM_IMM x11, 40
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x22, x16
    mov x11, x9
    adds x22, x22, x11
    mov x16, x22
    str x19, [x16]
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x9, x16
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x9, x21
    lsl x9, x9, #10
    ARM_ADDR x16, r3_pairs
    mov x23, x16
    mov x11, x9
    adds x23, x23, x11
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    str x23, [x16]
    ARM_ADDR x16, r2_dependency_count
    ldr x9, [x16]
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_selected
    ldr x9, [x16]
    mov x16, x22
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    mov x10, x21
    ARM_IMM x11, R3_DEPS
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r3_dependency_data
    mov x24, x16
    mov x11, x9
    adds x24, x24, x11
    mov x0, x24
    ARM_ADDR x16, r2_dependencies
    mov x1, x16
    ARM_ADDR x16, r2_dependency_count
    ldr x10, [x16]
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x3, x10, x11
    asr x13, x3, #63
    cmp x12, x13
    cbz x3, .Lr3_arm_copy_2_end
.Lr3_arm_copy_2:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr3_arm_copy_2
.Lr3_arm_copy_2_end:
    mov x10, x21
    ARM_IMM x11, G4_PROFILE_SIZE
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r4_profiles
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    ARM_ADDR x16, g4_publication_profile
    mov x1, x16
    ARM_CALL g4_profile_copy
    ARM_ADDR x16, g4_profiles
    mov x2, x16
    mov x16, x2
    add x16, x16, x21, lsl #3
    str x9, [x16]
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 3
    cmp x10, x11
    b.ne .Lr4_candidate_complex_ok
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x2, [x16]
    ARM_CALL r4_legacy_profile
.Lr4_candidate_complex_ok:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 6
    cmp x10, x11
    b.ne .Lr4_candidate_no_save
    ARM_ADDR x16, r3_local
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr4_candidate_no_save
    mov x0, x21
    ARM_CALL r4_metadata_save
.Lr4_candidate_no_save:
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr3_candidate_dep:
    mov x10, x20
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_candidate_end
    mov x16, x23
    str x24, [x16]
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x9, x16
    mov x16, x23
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM x11, 16
    adds x23, x23, x11
    ARM_IMM x11, 240
    adds x24, x24, x11
    ARM_IMM x11, 1
    adds x20, x20, x11
    b .Lr3_candidate_dep
.Lr3_candidate_end:
    ARM_ADDR x16, g3_candidate_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g3_candidate_count
    str x10, [x16]
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Solve once after complete metadata discovery. Result flags belong to the
 * solver; resource failure never reports a graph as unsatisfiable. */
r3_solve:
    sub sp, sp, #16
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_lazy
    str x10, [x16]
    ARM_IMM x10, 100000
    ARM_ADDR x16, g3_limit
    str x10, [x16]
    ARM_CALL g3_solve
    mov w10, w9
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq r3_unsatisfiable
    mov w10, w9
    ARM_IMM w11, 2
    cmp w10, w11
    b.eq r3_limit_error
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r3_metadata_error
    add sp, sp, #16
    ret

/* Read an existing regular lock into independent raw and parsing buffers.
 * w9=0 present,1 absent. Reject NUL/CR/control bytes and missing final LF.
 * Keep raw bytes for exact comparison; line splitting owns only the copy. */
r3_read_lock:
    ARM_SAVE x19
    ARM_IMM w9, 6
    ARM_ADDR x16, dependency_lock_path
    mov x0, x16
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    mov x10, x9
    ARM_IMM x11, -2
    cmp x10, x11
    b.eq .Lr3_lock_absent
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r3_lock_error
    ARM_ADDR x16, dependency_lock_path
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r3_old_lock
    mov x1, x16
    ARM_IMM w2, INDEX_LIMIT
    ARM_CALL r2_read_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_old_length
    str x9, [x16]
    ARM_ADDR x16, r3_old_lock
    mov x0, x16
    mov x16, x0
    add x16, x16, x9
    ARM_IMM x17, 1
    sub x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r3_lock_error
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_lock_ascii:
    mov x10, x19
    ARM_ADDR x16, r3_old_length
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_lock_copy
    mov x16, x0
    add x16, x16, x19
    ldrb w9, [x16]
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr3_lock_ascii_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr3_lock_ascii_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo r3_lock_error
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi r3_lock_error
.Lr3_lock_ascii_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_lock_ascii
.Lr3_lock_copy:
    ARM_CALL r3_parse_reset
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_RESTORE x19
    ret
.Lr3_lock_absent:
    ARM_IMM x10, 0
    ARM_ADDR x16, r3_old_length
    str x10, [x16]
    ARM_IMM w9, 1
    ARM_RESTORE x19
    ret

r3_parse_reset:
    ARM_ADDR x16, r3_parse_buffer
    mov x0, x16
    ARM_ADDR x16, r3_old_lock
    mov x1, x16
    ARM_ADDR x16, r3_old_length
    ldr x3, [x16]
    cbz x3, .Lr3_arm_copy_3_end
.Lr3_arm_copy_3:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr3_arm_copy_3
.Lr3_arm_copy_3_end:
    ARM_ADDR x16, r3_parse_buffer
    mov x9, x16
    ARM_ADDR x16, r3_cursor
    str x9, [x16]
    ARM_ADDR x16, r3_old_length
    ldr x11, [x16]
    adds x9, x9, x11
    ARM_ADDR x16, r3_end
    str x9, [x16]
    ret

/* Split one line into <=11 borrowed fields. Return field count, zero at EOF.
 * Input is already ASCII bounded. Empty fields and rows are invalid. */
r3_line:
    ARM_ADDR x16, r3_cursor
    ldr x0, [x16]
    mov x10, x0
    ARM_ADDR x16, r3_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_line_eof
    ARM_ADDR x16, r3_fields
    mov x2, x16
    mov x16, x2
    str x0, [x16]
    ARM_IMM w9, 1
    mov x1, x0
.Lr3_line_byte:
    mov x10, x0
    ARM_ADDR x16, r3_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs r3_lock_error
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr3_line_end
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr3_line_next
    mov x10, x0
    mov x11, x1
    cmp x10, x11
    b.eq r3_lock_error
    mov w10, w9
    ARM_IMM w11, 11
    cmp w10, w11
    b.hs r3_lock_error
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x1, x16
    mov x16, x2
    add x16, x16, x9, lsl #3
    str x1, [x16]
    ARM_IMM w11, 1
    adds w9, w9, w11
.Lr3_line_next:
    ARM_IMM x11, 1
    adds x0, x0, x11
    b .Lr3_line_byte
.Lr3_line_end:
    mov x10, x0
    mov x11, x1
    cmp x10, x11
    b.eq r3_lock_error
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_ADDR x16, r3_cursor
    str x0, [x16]
    ret
.Lr3_line_eof:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret

/* Validate authority/target before resolve can replace an existing graph.
 * Local build loads the recorded authority but never authenticates it here.
 * Sync requires the root manifest digest to remain identical. */
r3_lock_header:
    ARM_SAVE x19
    ARM_CALL r3_line
    mov w10, w9
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne r3_lock_error
    ARM_IMM x10, 3
    ARM_ADDR x16, r4_format
    str x10, [x16]
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r3_header_line
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr4_header_known
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r4_header_line
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_IMM x10, 4
    ARM_ADDR x16, r4_format
    str x10, [x16]
.Lr4_header_known:
    ARM_CALL r3_line
    mov w10, w9
    ARM_IMM w11, 5
    cmp w10, w11
    b.ne r3_lock_error
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r3_registry_word
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 8
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 16
    ldr x0, [x16]
    ARM_IMM w1, 64
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 32
    ldr x0, [x16]
    ARM_IMM w1, 64
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 24
    ldr x0, [x16]
    ARM_ADDR x16, r2_target
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_local
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr3_header_remote
    ARM_ADDR x16, r3_local_id
    mov x0, x16
    ARM_ADDR x16, r3_fields + 8
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r3_local_id
    mov x9, x16
    ARM_ADDR x16, r2_registry_id
    str x9, [x16]
    ARM_ADDR x16, r2_root_sha
    mov x0, x16
    ARM_ADDR x16, r3_fields + 16
    ldr x1, [x16]
    ARM_CALL copy_string
    b .Lr3_header_manifest
.Lr3_header_remote:
    ARM_ADDR x16, r3_fields + 8
    ldr x0, [x16]
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 16
    ldr x0, [x16]
    ARM_ADDR x16, r2_root_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 5
    cmp x10, x11
    b.eq .Lr3_header_done
.Lr3_header_manifest:
    ARM_ADDR x16, r3_fields + 32
    ldr x0, [x16]
    ARM_ADDR x16, r3_manifest_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
.Lr3_header_done:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 5
    cmp x10, x11
    b.eq .Lr4_header_return
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.eq .Lr4_header_selection
    ARM_ADDR x16, g4_root_profile
    ldr x9, [x16]
    ARM_ADDR x16, g3_root_count
    ldr x2, [x16]
    ARM_CALL r4_legacy_profile
    b .Lr4_header_return
.Lr4_header_selection:
    ARM_CALL r4_read_selection
.Lr4_header_return:
    ARM_RESTORE x19
    ret

/* Sync loads ONLY named versions in the retained lock. Regeneration after
 * solving checks every root, node and edge against authenticated metadata. */
r3_locked_candidates:
    ARM_SAVE x19
    ARM_SAVE x21
.Lr3_locked_line:
    ARM_CALL r3_line
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_locked_done
    mov w19, w9
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r3_node_word
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_locked_line
    mov w10, w19
    ARM_IMM w11, 10
    cmp w10, w11
    b.ne r3_lock_error
    ARM_ADDR x16, r3_fields + 8
    ldr x0, [x16]
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 16
    ldr x0, [x16]
    ARM_CALL registry_valid_version
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 8
    ldr x0, [x16]
    ARM_ADDR x16, r3_fields + 16
    ldr x1, [x16]
    ARM_CALL r3_find_inventory
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r3_metadata_error
    mov x16, x9
    ARM_IMM x17, 204
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r3_metadata_error
    mov x0, x9
    ARM_CALL r3_candidate
    b .Lr3_locked_line
.Lr3_locked_done:
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Stable selected-node ordering by package bytes, independent of inventory
 * or search order. The solver already enforces one version per package. */
r3_sort:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_IMM x10, 0
    ARM_ADDR x16, r3_order_count
    str x10, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_sort_candidate:
    mov x10, x19
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_sort_done
    ARM_ADDR x16, g3_solution
    mov x9, x16
    mov x16, x9
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr3_sort_next
    ARM_ADDR x16, r3_order_count
    ldr x21, [x16]
    ARM_ADDR x16, r3_order
    mov x22, x16
.Lr3_sort_insert:
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lr3_sort_store
    mov x16, x22
    add x16, x16, x21, lsl #3
    ARM_IMM x17, 8
    sub x16, x16, x17
    ldr x23, [x16]
    mov x9, x23
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    mov x9, x19
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x1, x16
    mov x11, x9
    adds x1, x1, x11
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.mi .Lr3_sort_store
    b.eq r3_lock_error
    mov x16, x22
    add x16, x16, x21, lsl #3
    str x23, [x16]
    ARM_IMM x11, 1
    subs x21, x21, x11
    b .Lr3_sort_insert
.Lr3_sort_store:
    mov x16, x22
    add x16, x16, x21, lsl #3
    str x19, [x16]
    ARM_ADDR x16, r3_order_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r3_order_count
    str x10, [x16]
.Lr3_sort_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_sort_candidate
.Lr3_sort_done:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Append one NUL string to the <=1MiB canonical lock. x1=input, ownership
 * stays with caller. Preserves callee registers, x0/x3/x9 are scratch. */
r3_append:
    ARM_SAVE x19
    ARM_SAVE x21
    mov x21, x1
    mov x0, x1
    ARM_CALL strlen
    ARM_ADDR x16, r3_length
    ldr x19, [x16]
    mov x16, x19
    add x16, x16, x9
    mov x2, x16
    mov x10, x2
    ARM_IMM x11, INDEX_LIMIT
    cmp x10, x11
    b.hi r3_limit_error
    ARM_ADDR x16, r3_length
    str x2, [x16]
    mov x3, x9
    ARM_ADDR x16, r3_buffer
    mov x0, x16
    mov x11, x19
    adds x0, x0, x11
    mov x1, x21
    cbz x3, .Lr3_arm_copy_4_end
.Lr3_arm_copy_4:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr3_arm_copy_4
.Lr3_arm_copy_4_end:
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

r3_tab:
    ARM_ADDR x16, registry_tab
    mov x1, x16
    b r3_append
r3_lf:
    ARM_ADDR x16, registry_newline
    mov x1, x16
    b r3_append

/* Serialize complete roots, selected immutable node bindings and every edge.
 * Uses bounded append and byte-sorted declarations. No external effects. */
r3_render:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_CALL r3_sort
    ARM_IMM x10, 0
    ARM_ADDR x16, r3_length
    str x10, [x16]
    ARM_ADDR x16, r3_header
    mov x1, x16
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 3
    cmp x10, x11
    b.eq .Lr4_render_header
    ARM_ADDR x16, r4_header
    mov x1, x16
.Lr4_render_header:
    ARM_CALL r3_append
    ARM_ADDR x16, r3_registry_word
    mov x1, x16
    ARM_CALL r3_append
    ARM_CALL r3_tab
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_tab
    ARM_ADDR x16, r2_root_sha
    mov x1, x16
    ARM_CALL r3_append
    ARM_CALL r3_tab
    ARM_ADDR x16, r2_target
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_tab
    ARM_ADDR x16, r3_manifest_sha
    mov x1, x16
    ARM_CALL r3_append
    ARM_CALL r3_lf
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr4_render_roots
    ARM_CALL r4_render_selection
.Lr4_render_roots:
    ARM_ADDR x16, g3_roots
    mov x21, x16
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_render_root:
    mov x10, x19
    ARM_ADDR x16, g3_root_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_render_nodes_start
    ARM_ADDR x16, g4_root_deps
    ldr x10, [x16]
    lsrv x11, x10, x19
    and x11, x11, #1
    cmp x11, #0
    b.eq .Lr4_render_root_next
    ARM_ADDR x16, r3_root_word
    mov x1, x16
    ARM_CALL r3_append
    ARM_CALL r3_tab
    mov x16, x21
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_tab
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_lf
.Lr4_render_root_next:
    ARM_IMM x11, 16
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_render_root
.Lr3_render_nodes_start:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, r3_order
    mov x24, x16
.Lr3_render_node:
    mov x10, x19
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_render_edges_start
    mov x16, x24
    add x16, x16, x19, lsl #3
    ldr x9, [x16]
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    ARM_ADDR x16, r3_node_word
    mov x1, x16
    ARM_CALL r3_append
    ARM_ADDR x16, r3_offsets
    mov x22, x16
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr3_render_node_field:
    ARM_CALL r3_tab
    mov x16, x22
    add x16, x16, x20, lsl #3
    ldr x1, [x16]
    mov x11, x21
    adds x1, x1, x11
    ARM_CALL r3_append
    ARM_IMM x11, 1
    adds x20, x20, x11
    mov w10, w20
    ARM_IMM w11, 9
    cmp w10, w11
    b.lo .Lr3_render_node_field
    ARM_CALL r3_lf
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_render_node
.Lr3_render_edges_start:
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr4_render_edges
    ARM_CALL r4_render_node_features
.Lr4_render_edges:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_render_parent:
    mov x10, x19
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_render_done
    mov x16, x24
    add x16, x16, x19, lsl #3
    ldr x9, [x16]
    mov x2, x9
    lsl x2, x2, #9
    ARM_ADDR x16, r3_records
    mov x21, x16
    mov x11, x2
    adds x21, x21, x11
    mov x10, x9
    ARM_IMM x11, 40
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x22, x16
    mov x11, x9
    adds x22, x22, x11
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x23, [x16]
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr3_render_edge:
    mov x10, x20
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_render_parent_next
    mov x16, x24
    add x16, x16, x19, lsl #3
    ldr x9, [x16]
    ARM_ADDR x16, g4_active_deps
    mov x2, x16
    mov x16, x2
    add x16, x16, x9, lsl #3
    ldr x9, [x16]
    mov x10, x9
    lsrv x11, x10, x20
    and x11, x11, #1
    cmp x11, #0
    b.eq .Lr4_render_edge_next
    ARM_ADDR x16, r3_edge_word
    mov x1, x16
    ARM_CALL r3_append
    ARM_CALL r3_tab
    mov x1, x21
    ARM_CALL r3_append
    ARM_CALL r3_tab
    mov x16, x23
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_tab
    mov x16, x23
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_lf
.Lr4_render_edge_next:
    ARM_IMM x11, 16
    adds x23, x23, x11
    ARM_IMM x11, 1
    adds x20, x20, x11
    b .Lr3_render_edge
.Lr3_render_parent_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_render_parent
.Lr3_render_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

r3_compare_lock:
    ARM_ADDR x16, r3_length
    ldr x3, [x16]
    mov x10, x3
    ARM_ADDR x16, r3_old_length
    ldr x11, [x16]
    cmp x10, x11
    b.ne r3_lock_error
    ARM_ADDR x16, r3_old_lock
    mov x1, x16
    ARM_ADDR x16, r3_buffer
    mov x0, x16
    cbz x3, .Lr3_arm_compare_5_end
.Lr3_arm_compare_5:
    ldrb w10, [x0], #1
    ldrb w11, [x1], #1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w11, w10
    sub x3, x3, #1
    b.ne .Lr3_arm_compare_5_end
    cbnz x3, .Lr3_arm_compare_5
.Lr3_arm_compare_5_end:
    b.ne r3_lock_error
    ret

/* Compare retained history before explicit resolve can replace asm.lock.
 * No arguments. Old lock<=1MiB; parse-copy fields borrow that owned buffer.
 * A retained name keeps its package ID across versions. The same name/version
 * keeps all nine node values, including signed metadata and source bindings.
 * Removed names are permitted. Reads<=256 old nodes and<=256 new selections;
 * no package, cache or lock bytes change. Preserves callee registers; Stack 80. */
r3_preserve_bindings:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, r3_old_length
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr3_preserve_done
    ARM_CALL r3_parse_reset
    ARM_CALL r3_lock_header
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, r3_offsets
    mov x24, x16
.Lr3_preserve_line:
    ARM_CALL r3_line
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_preserve_done
    mov w23, w9
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r3_node_word
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_preserve_line
    mov w10, w23
    ARM_IMM w11, 10
    cmp w10, w11
    b.ne r3_lock_error
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov w10, w19
    ARM_IMM w11, R3_CANDIDATES
    cmp w10, w11
    b.hi r3_lock_error
    mov w11, w21
    eor w21, w21, w11
    tst w21, w21
.Lr3_preserve_selection:
    mov x10, x21
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_preserve_line
    ARM_ADDR x16, r3_order
    mov x2, x16
    mov x16, x2
    add x16, x16, x21, lsl #3
    ldr x9, [x16]
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x22, x16
    mov x11, x9
    adds x22, x22, x11
    mov x0, x22
    ARM_ADDR x16, r3_fields + 8
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_preserve_next_selection
    mov x16, x22
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r3_fields + 24
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_changed_binding
    mov x16, x22
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r3_fields + 16
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_preserve_line
    mov w11, w23
    eor w23, w23, w11
    tst w23, w23
.Lr3_preserve_field:
    mov x16, x24
    add x16, x16, x23, lsl #3
    ldr x0, [x16]
    mov x11, x22
    adds x0, x0, x11
    ARM_ADDR x16, r3_fields + 8
    mov x2, x16
    mov x16, x2
    add x16, x16, x23, lsl #3
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_changed_binding
    ARM_IMM w11, 1
    adds w23, w23, w11
    mov w10, w23
    ARM_IMM w11, 9
    cmp w10, w11
    b.lo .Lr3_preserve_field
    b .Lr3_preserve_line
.Lr3_preserve_next_selection:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lr3_preserve_selection
.Lr3_preserve_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Finalize a resolved graph through private staging, fsync, and rename. A
 * failed write leaves the previous asm.lock intact; cache is unaffected. */
r3_write_lock:
    ARM_SAVE x19
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
    mov x0, x9
    ARM_ADDR x16, r3_buffer
    mov x1, x16
    ARM_ADDR x16, r3_length
    ldr x2, [x16]
    ARM_CALL r2_write_file
    ARM_ADDR x16, dependency_temp_lock
    mov x0, x16
    ARM_IMM w1, O_NOFOLLOW + O_CLOEXEC
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_IMM w9, 2
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x19, x9
    mov x0, x9
    ARM_IMM w9, 74
    ARM_CALL arm_fsync
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x0, x19
    ARM_IMM w9, 3
    ARM_CALL arm_close
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, dependency_temp_lock
    mov x0, x16
    ARM_ADDR x16, dependency_lock_path
    mov x1, x16
    ARM_IMM w9, 82
    ARM_CALL arm_rename
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_extra_temp
    str x10, [x16]
    ARM_RESTORE x19
    ret

/* Fresh policy must still admit EVERY selected identity, not just the last
 * parsed global envelope. Refresh never changes candidate/lock selections. */
r3_check_policy:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_CALL r3_catalog
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_check_node:
    mov x10, x19
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_check_done
    ARM_ADDR x16, r3_order
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    ldr x9, [x16]
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x0, x21
    mov x16, x21
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_CALL r3_find_inventory
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r3_metadata_error
    mov x16, x9
    ARM_IMM x17, 204
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r3_metadata_error
    mov x16, x9
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    mov x16, x21
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_metadata_error
    mov x0, x21
    mov x16, x21
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_CALL r3_find_inventory
    mov x16, x9
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x0, x16
    mov x16, x21
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_metadata_error
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_check_node
.Lr3_check_done:
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=candidate index. Build the existing eight-pointer source-cache row.
 * Also restore exact global selection fields needed by digest GET tagging.
 * No untrusted URL is accepted: all artifact requests derive from mirrors. */
r3_row:
    ARM_SAVE x19
    mov x9, x0
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    ARM_ADDR x16, r3_cache_row
    mov x2, x16
    mov x16, x2
    str x19, [x16]
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_target
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 16
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_source_kind
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 24
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_kind
    str x9, [x16]
    mov x16, x19
    ARM_IMM x17, 431
    add x16, x16, x17
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r3_local_url
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 40
    add x16, x16, x17
    str x9, [x16]
    mov x16, x19
    ARM_IMM x17, 399
    add x16, x16, x17
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 48
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r3_source_note
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 56
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_selected
    str x2, [x16]
    mov x16, x2
    ARM_IMM x17, 48
    add x16, x16, x17
    ldr x0, [x16]
    ARM_CALL registry_size_value
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r3_lock_error
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
    ARM_ADDR x16, r2_selected_bytes
    str x9, [x16]
    ARM_ADDR x16, r2_selected_sha
    mov x0, x16
    mov x16, x19
    ARM_IMM x17, 431
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_name
    mov x0, x16
    mov x1, x19
    ARM_CALL copy_string
    ARM_ADDR x16, r2_version
    mov x0, x16
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_package_id
    mov x0, x16
    mov x16, x19
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_release_id
    mov x0, x16
    mov x16, x19
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x19
    ret

/* Restore checked cached bytes when present. x9=0 copied,1 absent/corrupt.
 * Symlinks and nonregular cache entries are errors, never replacement targets.
 * Hash and declared length both match before a cache hit is accepted. */
r3_cached:
    sub sp, sp, #16
    ARM_IMM w9, 6
    ARM_ADDR x16, dependency_archive_path
    mov x0, x16
    ARM_ADDR x16, dependency_stat
    mov x1, x16
    ARM_CALL arm_lstat
    mov x10, x9
    ARM_IMM x11, -2
    cmp x10, x11
    b.eq .Lr3_cache_miss
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi dependency_io_error
    ARM_ADDR x16, dependency_stat + 16
    ldr w9, [x16]
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    mov w10, w9
    ARM_IMM w11, 32768
    cmp w10, w11
    b.ne dependency_cache_changed
    ARM_ADDR x16, dependency_stat + 48
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, registry_expected_size
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lr3_cache_miss
    ARM_ADDR x16, dependency_archive_path
    mov x9, x16
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    ARM_CALL registry_copy_local
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, pub_hash_buffer
    mov x0, x16
    ARM_ADDR x16, r2_selected_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_cache_miss
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    add sp, sp, #16
    ret
.Lr3_cache_miss:
    ARM_IMM w9, 1
    add sp, sp, #16
    ret

/* x0=candidate index. The most recent source validator produced sorted
 * project dependency records. Compare those with the signed/locked edges. */
r3_source_dependencies:
    sub sp, sp, #16
    ARM_ADDR x16, g4_profiles
    mov x2, x16
    mov x16, x2
    add x16, x16, x0, lsl #3
    ldr x2, [x16]
    mov x9, x0
    mov x10, x9
    ARM_IMM x11, 40
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x3, x16
    mov x11, x9
    adds x3, x3, x11
    mov x16, x3
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x1, [x16]
    mov x10, x0
    ARM_IMM x11, R3_DEPS
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r3_dependency_data
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    ARM_CALL g4_compare_project
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r3_lock_error
    add sp, sp, #16
    ret

/* Exact sync, no solving or archive execution. Validate source declarations
 * before extraction. Existing files must match; only missing trees are added.
 * Unreferenced verified cache entries may remain if a later operation fails. */
r3_materialize:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_CALL r3_check_policy
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_materialize_node:
    mov x10, x19
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_materialize_done
    ARM_ADDR x16, r3_order
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    ldr x21, [x16]
    mov x0, x21
    ARM_CALL r3_row
    ARM_IMM w0, 1
    ARM_CALL dependency_paths
    ARM_CALL r3_cached
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_materialize_validate
    ARM_CALL r2_download_blob
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r3_metadata_error
.Lr3_materialize_validate:
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, r2_name
    mov x1, x16
    ARM_ADDR x16, r2_version
    mov x2, x16
    ARM_ADDR x16, r2_target
    ldr x3, [x16]
    ARM_CALL validate_v2_source_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne dependency_archive_error
    mov x0, x21
    ARM_CALL r3_source_dependencies
    ARM_CALL r3_check_policy
    ARM_CALL dependency_accept_validated_payload
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_materialize_node
.Lr3_materialize_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Local build hook. x9=1 graph checked,0 legacy/no lock. A declared V2
 * dependency cannot be silently ignored without a complete graph lock.
 * Shared operation lock stays held until the build releases it. This verifies
 * local bytes/closure; only registry sync authenticates current remote policy. */
r3_verify_project:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_CALL r3_read_lock
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr3_verify_legacy
    ARM_ADDR x16, r3_old_lock
    mov x0, x16
    ARM_ADDR x16, r3_header
    mov x1, x16
    ARM_CALL dependency_prefix
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.ne .Lr4_verify_graph
    ARM_ADDR x16, r3_old_lock
    mov x0, x16
    ARM_ADDR x16, r4_header
    mov x1, x16
    ARM_CALL dependency_prefix
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr3_verify_legacy
.Lr4_verify_graph:
    ARM_IMM w10, 1
    ARM_ADDR x16, r3_active
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, r3_local
    strb w10, [x16]
    ARM_ADDR x16, package_target
    mov x9, x16
    ARM_ADDR x16, r2_target
    str x9, [x16]
    ARM_CALL r3_roots
    ARM_IMM w0, 5
    ARM_IMM w1, 1
    ARM_CALL dependency_acquire
    ARM_CALL r3_read_lock
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r3_lock_error
    ARM_CALL r3_lock_header
    ARM_CALL r3_local_candidates
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_lazy
    str x10, [x16]
    ARM_IMM x10, 100000
    ARM_ADDR x16, g3_limit
    str x10, [x16]
    ARM_CALL g3_solve
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r3_lock_error
    ARM_CALL r3_render
    ARM_CALL r3_compare_lock
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr3_verify_node:
    mov x10, x19
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr3_verify_done
    ARM_ADDR x16, r3_order
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    ldr x21, [x16]
    mov x0, x21
    ARM_CALL r3_row
    mov w11, w0
    eor w0, w0, w11
    tst w0, w0
    ARM_CALL dependency_paths
    ARM_CALL registry_workspace
    ARM_CALL r3_cached
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne dependency_cache_missing
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, r2_name
    mov x1, x16
    ARM_ADDR x16, r2_version
    mov x2, x16
    ARM_ADDR x16, r2_target
    ldr x3, [x16]
    ARM_CALL validate_v2_source_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne dependency_archive_error
    mov x0, x21
    ARM_CALL r3_source_dependencies
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, dependency_package_path
    mov x1, x16
    ARM_CALL verify_source_archive
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne dependency_cache_changed
    ARM_CALL registry_cleanup
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr3_verify_node
.Lr3_verify_done:
    ARM_IMM w9, 1
    b .Lr3_verify_return
.Lr3_verify_legacy:
    ARM_ADDR x16, g4_project_profile + 16
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r3_lock_error
    ARM_ADDR x16, g3_project_dep_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r3_lock_error
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr3_verify_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Load node and edge declarations from the local project-controlled lock.
 * Structural checks plus canonical regeneration reject duplicate/orphan nodes,
 * unsorted edges, omitted roots, extra rows and malformed constraints. */
r3_local_candidates:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
.Lr3_local_node_line:
    ARM_CALL r3_line
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_local_edges_start
    mov w20, w9
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r3_node_word
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_local_node_line
    mov w10, w20
    ARM_IMM w11, 10
    cmp w10, w11
    b.ne r3_lock_error
    ARM_ADDR x16, g3_candidate_count
    ldr x21, [x16]
    mov x10, x21
    ARM_IMM x11, R3_CANDIDATES
    cmp x10, x11
    b.hs r3_limit_error
    mov x9, x21
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    ARM_ADDR x16, r3_offsets
    mov x22, x16
    ARM_ADDR x16, r3_capacities
    mov x23, x16
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lr3_local_node_field:
    ARM_ADDR x16, r3_fields + 8
    mov x2, x16
    mov x16, x2
    add x16, x16, x24, lsl #3
    ldr x0, [x16]
    ARM_CALL strlen
    mov x10, x9
    mov x16, x23
    add x16, x16, x24, lsl #3
    ldr x11, [x16]
    cmp x10, x11
    b.hs r3_lock_error
    mov x16, x22
    add x16, x16, x24, lsl #3
    ldr x0, [x16]
    mov x11, x19
    adds x0, x0, x11
    ARM_ADDR x16, r3_fields + 8
    mov x2, x16
    mov x16, x2
    add x16, x16, x24, lsl #3
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_IMM x11, 1
    adds x24, x24, x11
    mov x10, x24
    ARM_IMM x11, 9
    cmp x10, x11
    b.lo .Lr3_local_node_field
    mov x0, x19
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_CALL registry_valid_version
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 138
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 171
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 204
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 64
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 269
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 64
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 431
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 64
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 334
    add x16, x16, x17
    mov x0, x16
    ARM_CALL strlen
    mov w10, w9
    ARM_IMM w11, 40
    cmp w10, w11
    b.eq .Lr3_local_commit
    mov w10, w9
    ARM_IMM w11, 64
    cmp w10, w11
    b.ne r3_lock_error
.Lr3_local_commit:
    mov w1, w9
    mov x16, x19
    ARM_IMM x17, 334
    add x16, x16, x17
    mov x0, x16
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 399
    add x16, x16, x17
    mov x0, x16
    ARM_CALL registry_size_value
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r3_lock_error
    mov x10, x21
    ARM_IMM x11, 40
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x22, x16
    mov x11, x9
    adds x22, x22, x11
    mov x16, x22
    str x19, [x16]
    mov x16, x19
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x9, x16
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x9, x21
    lsl x9, x9, #10
    ARM_ADDR x16, r3_pairs
    mov x2, x16
    mov x11, x9
    adds x2, x2, x11
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    str x2, [x16]
    ARM_IMM x10, 0
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM x10, 1
    mov x16, x22
    ARM_IMM x17, 32
    add x16, x16, x17
    str x10, [x16]
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr4_local_node_done
    mov x0, x21
    ARM_CALL r4_metadata_load
.Lr4_local_node_done:
    ARM_ADDR x16, g3_candidate_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g3_candidate_count
    str x10, [x16]
    b .Lr3_local_node_line
.Lr3_local_edges_start:
    ARM_ADDR x16, r4_format
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.eq .Lr3_local_done
    ARM_CALL r3_parse_reset
    ARM_CALL r3_lock_header
.Lr3_local_edge_line:
    ARM_CALL r3_line
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_local_done
    mov w20, w9
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r3_edge_word
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr3_local_edge_line
    mov w10, w20
    ARM_IMM w11, 4
    cmp w10, w11
    b.ne r3_lock_error
    mov w11, w21
    eor w21, w21, w11
    tst w21, w21
    ARM_ADDR x16, g3_candidates
    mov x22, x16
.Lr3_local_parent:
    mov x10, x21
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs r3_lock_error
    mov x16, x22
    ldr x0, [x16]
    ARM_ADDR x16, r3_fields + 8
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr3_local_parent_found
    ARM_IMM x11, 40
    adds x22, x22, x11
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lr3_local_parent
.Lr3_local_parent_found:
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x10, x23
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs r3_limit_error
    ARM_ADDR x16, r3_fields + 16
    ldr x0, [x16]
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 24
    ldr x0, [x16]
    ARM_ADDR x16, r3_zero_version
    mov x1, x16
    ARM_CALL g3_requirement
    mov w10, w9
    ARM_IMM w11, -1
    cmp w10, w11
    b.eq r3_lock_error
    mov x10, x21
    ARM_IMM x11, R3_DEPS
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x10, x23
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x2, x10, x11
    asr x13, x2, #63
    cmp x12, x13
    mov x11, x2
    adds x9, x9, x11
    ARM_ADDR x16, r3_dependency_data
    mov x24, x16
    mov x11, x9
    adds x24, x24, x11
    mov x0, x24
    ARM_ADDR x16, r3_fields + 16
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r3_fields + 24
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x2, [x16]
    lsl x23, x23, #4
    mov x11, x23
    adds x2, x2, x11
    mov x16, x2
    str x24, [x16]
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    str x10, [x16]
    b .Lr3_local_edge_line
.Lr3_local_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

.section .rodata
r3_header: .asciz "# asm-lock-v3\n"
r3_header_line: .asciz "# asm-lock-v3"
r3_registry_word: .asciz "registry"
r3_root_word: .asciz "root"
r3_node_word: .asciz "node"
r3_edge_word: .asciz "edge"
r3_zero_version: .asciz "0.0.0"
r3_local_url: .asciz "https://locked.invalid/source.tar.gz"
r3_source_note: .asciz "Locked V2 source"
r3_result_prefix: .asciz "{\"ok\":true,\"packages\":"
r3_resolved: .asciz ",\"resolved\":true}\n"
r3_synchronized: .asciz ",\"synchronized\":true}\n"
r3_err_lock: .asciz "V2 dependency lock is missing, stale or inconsistent. Preserve legacy locks. Use the same registry and target, then resolve this project."
r3_err_metadata: .asciz "V2 dependency metadata or artifact is unavailable, invalid or disabled by current policy; check the trusted registry and mirrors"
r3_err_limit: .asciz "V2 dependency search limit or metadata bound exceeded; reduce the dependency graph or report this input"
r3_err_unsat: .asciz "no compatible dependency graph satisfies the declared requirements and target; inspect the root and package constraints"
r3_err_changed: .asciz "A package identity or locked release changed. Keep asm.lock and report the metadata to the registry operator."
.p2align 3
r3_offsets: .quad 0,105,138,171,204,269,334,399,431
r3_capacities: .quad 105,33,33,33,65,65,65,32,65
.section .bss
.p2align 3
r3_active: .skip 1
r3_local: .skip 1
.p2align 3
r3_catalog_count: .skip 8
r3_inventory: .skip 4095 * 256
r3_records: .skip R3_CANDIDATES * R3_NODE
r3_pairs: .skip R3_CANDIDATES * 1024
r3_dependency_data: .skip R3_CANDIDATES * R3_DEPS
r3_names: .skip R3_CANDIDATES * 105
r3_name_count: .skip 8
r3_root_data: .skip 64 * 240
r3_manifest_sha: .skip 65
r3_local_id: .skip 33
.p2align 3
r3_order: .skip R3_CANDIDATES * 8
r3_order_count: .skip 8
r3_cache_row: .skip 64
r3_old_length: .skip 8
r3_old_lock: .skip INDEX_LIMIT + 1
r3_parse_buffer: .skip INDEX_LIMIT + 1
.p2align 3
r3_cursor: .skip 8
r3_end: .skip 8
r3_fields: .skip 11 * 8
r3_length: .skip 8
r3_buffer: .skip INDEX_LIMIT + 1
