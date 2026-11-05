/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native dependency driver. See docs/specs/dependencies.md.
 * Arguments use x0-x7; x9 holds results. Returning routines preserve x19-x24.
 * x8,x10-x17,NZCV are scratch. ARM_CALL adds a 16-byte link frame.
 * No package code is executed. Transport, hashes and archive checks reuse the
 * existing fixed-tool adapters. Every buffer is owned by this process.
 */
.global cmd_resolve
.equ RES_RM_SIZE, RM_SIZE
.equ RES_NODE_SIZE, 4096
.section .text

/* argv follows resolve. Parse all options before creating dependency state.
 * Index <=1MiB, manifests <=8190 bytes, archive <=64MiB. Lock rename is last.
 * Fatal errors use the normal registry cleanup path. Command does not return. */
cmd_resolve:
    ARM_ADDR x16, registry_default_url
    mov x9, x16
    ARM_ADDR x16, registry_url
    str x9, [x16]
    ARM_IMM x10, 1
    ARM_ADDR x16, res_default
    str x10, [x16]
.Lres_args:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lres_start
    mov x21, x9
    mov x0, x9
    ARM_ADDR x16, registry_opt_index
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_arg_index
    mov x0, x21
    ARM_ADDR x16, registry_opt_registry
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_arg_registry
    mov x0, x21
    ARM_ADDR x16, res_opt_artifacts
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_arg_artifacts
    mov x0, x21
    ARM_ADDR x16, res_opt_features
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_arg_features
    mov x0, x21
    ARM_ADDR x16, res_opt_no_default
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_arg_no_default
    mov x0, x21
    ARM_ADDR x16, opt_help
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne res_help
    mov x9, x21
    ARM_CALL common_option
    tst w9, w9
    b.eq registry_bad_args
    b .Lres_args
.Lres_arg_index:
    ARM_ADDR x16, registry_origin_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_index_path
    str x9, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_local_index
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_origin_seen
    strb w10, [x16]
    b .Lres_args
.Lres_arg_registry:
    ARM_ADDR x16, registry_origin_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_url
    str x9, [x16]
    mov x0, x9
    ARM_CALL registry_https_url
    tst w9, w9
    b.eq registry_bad_args
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_origin_seen
    strb w10, [x16]
    b .Lres_args
.Lres_arg_artifacts:
    ARM_ADDR x16, res_artifacts
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, res_artifacts
    str x9, [x16]
    b .Lres_args
.Lres_arg_features:
    ARM_ADDR x16, res_cli_features
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, res_cli_features
    str x9, [x16]
    b .Lres_args
.Lres_arg_no_default:
    ARM_ADDR x16, res_no_default_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne registry_bad_args
    ARM_IMM w10, 1
    ARM_ADDR x16, res_no_default_seen
    strb w10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, res_default
    str x10, [x16]
    b .Lres_args
.Lres_start:
    ARM_CALL read_manifest
    ARM_ADDR x16, rm_root_metadata
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne res_manifest_error
    ARM_ADDR x16, res_cli_features
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL res_parse_features
    ARM_IMM w10, 6
    mov w0, w10
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL dependency_acquire
    ARM_CALL res_hash_root
    ARM_CALL res_read_previous
    ARM_ADDR x16, registry_url
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, registry_local_index
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lres_origin_ready
    ARM_ADDR x16, dependency_local_origin
    mov x9, x16
.Lres_origin_ready:
    ARM_ADDR x16, dependency_origin
    str x9, [x16]
    ARM_ADDR x16, res_previous_origin
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lres_index
    mov x0, x9
    ARM_ADDR x16, res_previous_origin
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_origin_error
.Lres_index:
    ARM_ADDR x16, registry_index_path
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lres_index_read
    ARM_CALL registry_workspace
    ARM_ADDR x16, registry_url
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_index
    mov x1, x16
    ARM_ADDR x16, registry_index_max
    mov x2, x16
    ARM_CALL registry_download
    tst w9, w9
    b.ne registry_download_error
    ARM_ADDR x16, registry_temp_index
    mov x9, x16
    ARM_ADDR x16, registry_index_path
    str x9, [x16]
.Lres_index_read:
    ARM_CALL registry_read_index
    ARM_CALL registry_parse_index
    ARM_CALL res_copy_rows
    /* The registry input is now in its owned buffer. A later cleanup cannot
     * erase it. No network artifact can replace index strings. */
    ARM_CALL registry_cleanup
    ARM_CALL res_solve
    tst w9, w9
    b.eq res_conflict_error
    ARM_CALL res_check_immutable
    ARM_CALL res_render_lock
    ARM_CALL res_commit_lock
    ARM_CALL registry_cleanup
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, res_done
    mov x0, x16
    b res_report

res_help:
    ARM_ADDR x16, res_help_text
    mov x0, x16
    ARM_CALL out
    b exit_ok

/* x0=optional comma list, <=2111 bytes. Store at most64 unique borrowed names
 * in owned res_feature_buffer[2113]. Sort them for a canonical lock header.
 * Empty input is represented by NULL; explicit empty/duplicate names fail.
 * Stack:80 saved bytes. No filesystem effect. */
res_parse_features:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_IMM x10, 0
    ARM_ADDR x16, res_root_request_count
    str x10, [x16]
    tst x0, x0
    b.eq .Lres_features_done
    mov x21, x0
    ARM_CALL strlen
    tst x9, x9
    b.eq registry_bad_args
    ARM_IMM x11, 2111
    cmp x9, x11
    b.hi registry_bad_args
    ARM_ADDR x16, res_feature_buffer
    mov x0, x16
    mov x1, x21
    ARM_CALL copy_string
    ARM_ADDR x16, res_feature_buffer
    mov x21, x16
.Lres_feature_name:
    mov x22, x21
    eor w12, w23, w23
    tst w12, w12
    mov w23, w12
.Lres_feature_chars:
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lres_feature_end
    uxtb w10, w9
    ARM_IMM w11, 44
    cmp w10, w11
    b.eq .Lres_feature_end
    uxtb w10, w9
    ARM_IMM w11, 97
    cmp w10, w11
    b.lo .Lres_feature_other
    uxtb w10, w9
    ARM_IMM w11, 122
    cmp w10, w11
    b.ls .Lres_feature_char_ok
.Lres_feature_other:
    tst w23, w23
    b.eq registry_bad_args
    uxtb w10, w9
    ARM_IMM w11, 45
    cmp w10, w11
    b.eq .Lres_feature_char_ok
    uxtb w10, w9
    ARM_IMM w11, 95
    cmp w10, w11
    b.eq .Lres_feature_char_ok
    uxtb w10, w9
    ARM_IMM w11, 48
    cmp w10, w11
    b.lo registry_bad_args
    uxtb w10, w9
    ARM_IMM w11, 57
    cmp w10, w11
    b.hi registry_bad_args
.Lres_feature_char_ok:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    ARM_IMM w11, 1
    adds w12, w23, w11
    mov w23, w12
    ARM_IMM w11, 32
    cmp w23, w11
    b.hi registry_bad_args
    b .Lres_feature_chars
.Lres_feature_end:
    tst w23, w23
    b.eq registry_bad_args
    uxtb w10, w9
    bfi x24, x10, #0, #8
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_ADDR x16, res_root_request_count
    ldr x10, [x16]
    mov x19, x10
    ARM_IMM x11, 64
    cmp x19, x11
    b.hs res_limit_error
    ARM_ADDR x16, res_root_requests
    mov x23, x16
    eor w12, w6, w6
    tst w12, w12
    mov w6, w12
.Lres_feature_duplicate:
    cmp x6, x19
    b.hs .Lres_feature_insert
    mov x0, x22
    mov x16, x23
    add x16, x16, x6, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_SAVE x6
    ARM_CALL streq
    ARM_RESTORE x6
    tst w9, w9
    b.ne registry_bad_args
    ARM_IMM x11, 1
    adds x12, x6, x11
    mov x6, x12
    b .Lres_feature_duplicate
.Lres_feature_insert:
    mov x16, x23
    add x16, x16, x19, lsl #3
    str x22, [x16]
    ARM_ADDR x16, res_root_request_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, res_root_request_count
    str x12, [x16]
    uxtb w10, w24
    uxtb w11, w24
    tst w10, w11
    b.eq .Lres_feature_sort
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_feature_name
.Lres_feature_sort:
    ARM_IMM w10, 1
    mov w21, w10
.Lres_feature_sort_outer:
    ARM_ADDR x16, res_root_request_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lres_features_done
    mov x22, x21
.Lres_feature_sort_inner:
    tst x22, x22
    b.eq .Lres_feature_sort_next
    mov x16, x23
    add x16, x16, x22, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    mov x16, x23
    add x16, x16, x22, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL res_strcmp
    tst w9, w9
    b.le .Lres_feature_sort_next
    mov x16, x23
    add x16, x16, x22, lsl #3
    ldr x10, [x16]
    mov x9, x10
    mov x16, x23
    add x16, x16, x22, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    mov x16, x23
    add x16, x16, x22, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    str x9, [x16]
    mov x16, x23
    add x16, x16, x22, lsl #3
    str x2, [x16]
    ARM_IMM x11, 1
    subs x12, x22, x11
    mov x22, x12
    b .Lres_feature_sort_inner
.Lres_feature_sort_next:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_feature_sort_outer
.Lres_features_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* NUL ASCII strings x0/x1. x9 signed comparison; read-only, stack:none. */
res_strcmp:
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lres_strcmp_loop:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    mov w2, w10
    subs w12, w9, w2
    mov w9, w12
    b.ne .Lres_strcmp_done
    tst w2, w2
    b.eq .Lres_strcmp_done
    ARM_IMM x11, 1
    adds x12, x3, x11
    mov x3, x12
    b .Lres_strcmp_loop
.Lres_strcmp_done:
    ret

/* Hash the exact unmodified bytes retained by read_manifest. The parser and
 * lock digest therefore describe one snapshot even if the source file changes.
 * Input rm_root_original[8192]; output res_root_hash[65]. Mature fixed-tool
 * hash adapter receives only the private snapshot through stdin. Stack:none. */
res_hash_root:
    ARM_CALL registry_workspace
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, rm_root_original
    mov x1, x16
    ARM_ADDR x16, res_snapshot_created
    mov x2, x16
    ARM_CALL create_exclusive_file
    tst x9, x9
    b.mi registry_io_error
    ARM_CALL pub_hash_payload
    tst w9, w9
    b.ne registry_integrity_error
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_ADDR x16, res_root_hash
    mov x0, x16
    ARM_IMM w10, 64
    mov w3, w10
    cbz x3, .Lres_arm_repeat_done1
.Lres_arm_repeat1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lres_arm_repeat1
.Lres_arm_repeat_done1:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_CALL registry_cleanup
    ret

/* A non-following bounded probe only selects the parser. Invalid locks still
 * fail in their full readers. x9=1 v2 prefix,0 otherwise. Stack:16 bytes. */
res_is_v2:
    ARM_SAVE x21
    ARM_ADDR x16, dependency_lock_path
    mov x0, x16
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lres_probe_no
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lres_probe_close
    ARM_ADDR x16, registry_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    ands w12, w9, w11
    mov w9, w12
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Lres_probe_close
    mov x0, x21
    ARM_ADDR x16, res_probe
    mov x1, x16
    ARM_IMM w10, 14
    mov w2, w10
    ARM_CALL arm_read
    ARM_IMM x11, 14
    cmp x9, x11
    b.ne .Lres_probe_close
    ARM_IMM w10, 0
    ARM_ADDR x16, res_probe + 14
    strb w10, [x16]
    mov x0, x21
    ARM_CALL arm_close
    ARM_ADDR x16, res_probe
    mov x0, x16
    ARM_ADDR x16, res_header
    mov x1, x16
    ARM_CALL streq
    ARM_RESTORE x21
    ret
.Lres_probe_close:
    mov x0, x21
    ARM_CALL arm_close
.Lres_probe_no:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    ARM_RESTORE x21
    ret

/* Used by legacy add/update/remove. Refuse graph mutation before any changed
 * lock or cache. read_manifest has populated rm_root_metadata. */
res_legacy_guard:
    ARM_ADDR x16, rm_root_metadata
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne res_use_resolve_error
    ARM_CALL res_is_v2
    tst w9, w9
    b.ne res_use_resolve_error
    ret

/* Preserve previous exact rows for immutable-version comparisons. Owned row
 * pointers borrow either v1 dependency_lock_buffer or res_lock_buffer. */
res_read_previous:
    ARM_CALL res_is_v2
    tst w9, w9
    b.eq .Lres_previous_v1
    ARM_CALL res_read_v2
    b .Lres_previous_copy
.Lres_previous_v1:
    ARM_CALL dependency_load_lock
    tst w9, w9
    b.ne .Lres_previous_none
.Lres_previous_copy:
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, res_previous_origin
    str x9, [x16]
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    mov x3, x10
    ARM_ADDR x16, res_previous_count
    str x3, [x16]
    ARM_IMM x11, 3
    lsl x12, x3, x11
    tst x12, x12
    mov x3, x12
    ARM_ADDR x16, res_previous_rows
    mov x0, x16
    ARM_ADDR x16, registry_rows
    mov x1, x16
    cbz x3, .Lres_arm_repeat_done2
.Lres_arm_repeat2:
    ldr x10, [x1], #8
    str x10, [x0], #8
    sub x3, x3, #1
    cbnz x3, .Lres_arm_repeat2
.Lres_arm_repeat_done2:
.Lres_previous_none:
    ret

/* Load v2 as a bounded regular non-symlink file. Keep an unmodified copy for
 * canonical verification. Only flags/origin are trusted as resolution inputs;
 * enabled-feature comments and selected rows are recomputed from archives.
 * Output registry_rows/count, dependency_origin, res_lock_*; stack:64 bytes. */
res_read_v2:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_ADDR x16, dependency_lock_path
    mov x0, x16
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
    ARM_CALL arm_open
    tst x9, x9
    b.mi res_lock_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi res_lock_error
    ARM_ADDR x16, registry_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    ands w12, w9, w11
    mov w9, w12
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne res_lock_error
    ARM_ADDR x16, registry_stat + 48
    ldr x10, [x16]
    ARM_IMM x11, 1048576
    cmp x10, x11
    b.hi res_lock_error
    eor w12, w22, w22
    tst w12, w12
    mov w22, w12
.Lres_lock_read:
    mov x0, x21
    ARM_ADDR x16, res_lock_buffer
    mov x1, x16
    adds x12, x1, x22
    mov x1, x12
    ARM_IMM w10, 1048577
    mov w2, w10
    subs x12, x2, x22
    mov x2, x12
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lres_lock_read
    tst x9, x9
    b.mi res_lock_error
    b.eq .Lres_lock_read_end
    adds x12, x22, x9
    mov x22, x12
    ARM_IMM x11, 1048576
    cmp x22, x11
    b.hi res_lock_error
    b .Lres_lock_read
.Lres_lock_read_end:
    mov x0, x21
    ARM_CALL arm_close
    ARM_ADDR x16, res_lock_buffer
    mov x0, x16
    mov x3, x22
    ARM_ADDR x16, res_lock_length
    str x22, [x16]
    ARM_ADDR x16, res_lock_buffer
    mov x1, x16
    ARM_ADDR x16, res_lock_original
    mov x0, x16
    cbz x3, .Lres_arm_repeat_done3
.Lres_arm_repeat3:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lres_arm_repeat3
.Lres_arm_repeat_done3:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_ADDR x16, res_lock_buffer
    mov x0, x16
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x22
    strb w10, [x16]
    mov x16, x0
    add x16, x16, x22
    mov x23, x16
    ARM_ADDR x16, res_header
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq res_lock_error
    mov x0, x9
    ARM_ADDR x16, dependency_origin_prefix
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq res_lock_error
    mov x0, x9
    ARM_ADDR x16, dependency_origin
    str x0, [x16]
    ARM_CALL res_line
    mov x21, x9
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, dependency_local_origin
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_lock_default
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_https_url
    tst w9, w9
    b.eq res_lock_error
.Lres_lock_default:
    mov x0, x21
    ARM_ADDR x16, res_default_prefix
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq res_lock_error
    mov x16, x9
    ldrb w10, [x16]
    mov w2, w10
    ARM_IMM w11, 48
    subs w12, w2, w11
    mov w2, w12
    ARM_IMM w11, 1
    cmp w2, w11
    b.hi res_lock_error
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 10
    cmp w10, w11
    b.ne res_lock_error
    ARM_ADDR x16, res_lock_default
    str x2, [x16]
    mov x16, x9
    ARM_IMM x17, 2
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, res_features_prefix
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq res_lock_error
    mov x0, x9
    ARM_ADDR x16, res_lock_features
    str x9, [x16]
    ARM_CALL res_line
    mov x0, x9
    ARM_ADDR x16, res_manifest_prefix
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq res_lock_error
    mov x0, x9
    ARM_ADDR x16, res_lock_hash
    str x9, [x16]
    ARM_CALL res_line
    mov x21, x9
    ARM_ADDR x16, res_lock_hash
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    ARM_IMM x11, 64
    cmp x9, x11
    b.ne res_lock_error
.Lres_lock_comments:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 35
    cmp w10, w11
    b.ne .Lres_lock_records
    mov x0, x21
    ARM_ADDR x16, res_enabled_prefix
    mov x1, x16
    ARM_CALL dependency_prefix
    tst x9, x9
    b.eq res_lock_error
    mov x0, x9
    ARM_CALL res_line
    mov x21, x9
    b .Lres_lock_comments
.Lres_lock_records:
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_row_count
    str x10, [x16]
    mov x0, x21
    mov x1, x23
    ARM_CALL registry_parse_records
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    ARM_IMM x11, 128
    cmp x10, x11
    b.hi res_limit_error
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w12, w22, w22
    tst w12, w12
    mov w22, w12
.Lres_lock_validate:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Lres_lock_loaded
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_host
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq res_lock_error
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_source_kind
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq res_lock_error
    ARM_ADDR x16, registry_rows
    mov x19, x16
.Lres_lock_duplicate:
    cmp x19, x21
    b.hs .Lres_lock_next
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    mov x16, x21
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.ne res_lock_error
    ARM_IMM x11, 64
    adds x12, x19, x11
    mov x19, x12
    b .Lres_lock_duplicate
.Lres_lock_next:
    ARM_IMM x11, 64
    adds x12, x21, x11
    mov x21, x12
    ARM_IMM x11, 1
    adds x12, x22, x11
    mov x22, x12
    b .Lres_lock_validate
.Lres_lock_loaded:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0 points into res_lock_buffer, x23 its end. Replace LF with NUL and return
 * following byte. Refuse embedded NUL/control/non-ASCII and lines>4095 bytes. */
res_line:
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lres_line_loop:
    cmp x0, x23
    b.hs res_lock_error
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 10
    cmp w10, w11
    b.eq .Lres_line_end
    uxtb w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.eq .Lres_line_char
    uxtb w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.lo res_lock_error
    uxtb w10, w9
    ARM_IMM w11, 126
    cmp w10, w11
    b.hi res_lock_error
.Lres_line_char:
    ARM_IMM x11, 1
    adds x12, x0, x11
    mov x0, x12
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    ARM_IMM w11, 4095
    cmp w3, w11
    b.hi res_lock_error
    b .Lres_line_loop
.Lres_line_end:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x9, x16
    ret

/* Copy validated registry rows into solver-owned storage. Their strings remain
 * borrowed from registry/lock buffers. Count <=4096; stack:none. */
res_copy_rows:
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    mov x3, x10
    ARM_ADDR x16, res_row_count
    str x3, [x16]
    ARM_IMM x11, 3
    lsl x12, x3, x11
    tst x12, x12
    mov x3, x12
    ARM_ADDR x16, res_rows
    mov x0, x16
    ARM_ADDR x16, registry_rows
    mov x1, x16
    cbz x3, .Lres_arm_repeat_done4
.Lres_arm_repeat4:
    ldr x10, [x1], #8
    str x10, [x0], #8
    sub x3, x3, #1
    cbnz x3, .Lres_arm_repeat4
.Lres_arm_repeat_done4:
    ret

/* Callback x0=validated row, return x9=persistent metadata. Inspect at most
 * 256 candidates. Acquire and validate compressed bytes before parsing their
 * manifest. Cache comparison precedes replacement. In check mode no fetch,
 * extraction or writes to managed caches occur. Stack:80 saved bytes. */
res_load_candidate:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x19, x0
    eor w12, w21, w21
    tst w12, w12
    mov w21, w12
    ARM_ADDR x16, res_loaded_rows
    mov x22, x16
.Lres_loaded_find:
    ARM_ADDR x16, res_loaded_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lres_load_new
    mov x16, x22
    add x16, x16, x21, lsl #3
    ldr x11, [x16]
    cmp x19, x11
    b.eq .Lres_loaded_return
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_loaded_find
.Lres_load_new:
    ARM_IMM x11, 256
    cmp x21, x11
    b.hs res_limit_error
    mov x16, x22
    add x16, x16, x21, lsl #3
    str x19, [x16]
    ARM_ADDR x16, res_loaded_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, res_loaded_count
    str x12, [x16]
    ARM_ADDR x16, registry_selected
    str x19, [x16]
    mov x16, x19
    ARM_IMM x17, 48
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
    ARM_IMM w10, 1
    mov w0, w10
    ARM_ADDR x16, res_check_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lres_candidate_paths
    eor w12, w0, w0
    tst w12, w12
    mov w0, w12
.Lres_candidate_paths:
    ARM_CALL dependency_paths
    ARM_CALL registry_workspace
    /* Existing digest cache is verified rather than silently repaired. */
    ARM_ADDR x16, dependency_archive_path
    mov x0, x16
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.eq .Lres_candidate_cached
    ARM_IMM x11, -2
    cmp x9, x11
    b.ne dependency_cache_changed
    ARM_ADDR x16, res_check_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne dependency_cache_missing
    ARM_ADDR x16, res_artifacts
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lres_candidate_offline
    mov x16, x19
    ARM_IMM x17, 40
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_payload
    mov x1, x16
    mov x16, x19
    ARM_IMM x17, 48
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    ARM_CALL registry_download
    tst w9, w9
    b.ne registry_download_error
    b .Lres_candidate_verify
.Lres_candidate_cached:
    ARM_ADDR x16, dependency_archive_path
    mov x9, x16
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    ARM_CALL registry_copy_local
    b .Lres_candidate_verify
.Lres_candidate_offline:
    ARM_CALL res_offline_path
    ARM_ADDR x16, res_artifact_path
    mov x9, x16
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    ARM_CALL registry_copy_local
.Lres_candidate_verify:
    ARM_CALL registry_verify_payload
    ARM_ADDR x16, res_check_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lres_candidate_check
    ARM_CALL dependency_accept_payload
    b .Lres_candidate_manifest
.Lres_candidate_check:
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    mov x16, x19
    ldr x10, [x16]
    mov x1, x10
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
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
.Lres_candidate_manifest:
    ARM_ADDR x16, pub_manifest_name
    mov x0, x16
    ARM_CALL source_archive_member
    tst x9, x9
    b.eq res_manifest_error
    tst w3, w3
    b.ne res_manifest_error
    tst x2, x2
    b.eq res_manifest_error
    ARM_IMM x11, 16384
    cmp x2, x11
    b.hi res_manifest_error
    mov x1, x9
    mov x3, x2
    mov x9, x21
    ARM_IMM x11, 16385
    mul x12, x9, x11
    mov x9, x12
    ARM_ADDR x16, res_manifests
    mov x23, x16
    adds x12, x23, x9
    mov x23, x12
    mov x0, x23
    cbz x3, .Lres_arm_repeat_done5
.Lres_arm_repeat5:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lres_arm_repeat5
.Lres_arm_repeat_done5:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    mov x0, x23
    mov x9, x21
    ARM_IMM x11, RES_RM_SIZE
    mul x12, x9, x11
    mov x9, x12
    ARM_ADDR x16, res_metadata
    mov x1, x16
    adds x12, x1, x9
    mov x1, x12
    ARM_CALL rm_parse_manifest
    tst w9, w9
    b.ne res_manifest_error
    ARM_CALL registry_cleanup
.Lres_loaded_return:
    mov x9, x21
    ARM_IMM x11, RES_RM_SIZE
    mul x12, x9, x11
    mov x9, x12
    ARM_ADDR x16, res_metadata
    mov x2, x16
    adds x12, x9, x2
    mov x9, x12
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Offline directory is a user-selected path, <=4095 bytes. Inspect every
 * existing component without following symlinks; file open also uses NOFOLLOW.
 * This is a checked path boundary, not a race-free descriptor walk. Same-user
 * processes can race path replacement, as with the existing cache checks. */
res_offline_path:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, res_artifacts
    ldr x10, [x16]
    mov x21, x10
    mov x0, x21
    ARM_CALL strlen
    ARM_IMM x11, 4000
    cmp x9, x11
    b.hi registry_bad_args
    ARM_ADDR x16, res_artifact_path
    mov x0, x16
    mov x1, x21
    ARM_CALL copy_string
    ARM_ADDR x16, res_artifact_path
    mov x21, x16
    mov x22, x21
.Lres_dir_component:
    mov x16, x22
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lres_dir_final
    uxtb w10, w9
    ARM_IMM w11, 47
    cmp w10, w11
    b.ne .Lres_dir_advance
    cmp x22, x21
    b.eq .Lres_dir_advance
    ARM_IMM w10, 0
    mov x16, x22
    strb w10, [x16]
    ARM_CALL res_check_artifact_dir
    ARM_IMM w10, 47
    mov x16, x22
    strb w10, [x16]
.Lres_dir_advance:
    ARM_IMM x11, 1
    adds x12, x22, x11
    mov x22, x12
    b .Lres_dir_component
.Lres_dir_final:
    ARM_CALL res_check_artifact_dir
    mov x0, x22
    ARM_ADDR x16, res_slash
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, res_archive_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret
res_check_artifact_dir:
    ARM_ADDR x16, res_artifact_path
    mov x0, x16
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    ands w12, w9, w11
    mov w9, w12
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne registry_io_error
    ret

/* Compare every reused identity/version to previous immutable artifact fields.
 * Inputs solver nodes, retained previous rows. Stack:80 saved bytes. */
res_check_immutable:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_IMM w10, 1
    mov w21, w10
.Lres_immutable_node:
    ARM_ADDR x16, res_node_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lres_immutable_done
    mov x9, x21
    ARM_IMM x11, 12
    lsl x12, x9, x11
    tst x12, x12
    mov x9, x12
    ARM_ADDR x16, res_nodes
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x22, x10
    eor w12, w23, w23
    tst w12, w12
    mov w23, w12
    ARM_ADDR x16, res_previous_rows
    mov x24, x16
.Lres_immutable_row:
    ARM_ADDR x16, res_previous_count
    ldr x11, [x16]
    cmp x23, x11
    b.hs .Lres_immutable_next
    mov x16, x22
    ldr x10, [x16]
    mov x0, x10
    mov x16, x24
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lres_immutable_row_next
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    mov x16, x24
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lres_immutable_row_next
    ARM_IMM w10, 2
    mov w19, w10
.Lres_immutable_field:
    mov x16, x22
    add x16, x16, x19, lsl #3
    ldr x10, [x16]
    mov x0, x10
    mov x16, x24
    add x16, x16, x19, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq dependency_changed_release
    ARM_IMM w11, 1
    adds w12, w19, w11
    mov w19, w12
    ARM_IMM w11, 7
    cmp w19, w11
    b.lo .Lres_immutable_field
.Lres_immutable_row_next:
    ARM_IMM x11, 64
    adds x12, x24, x11
    mov x24, x12
    ARM_IMM x11, 1
    adds x12, x23, x11
    mov x23, x12
    b .Lres_immutable_row
.Lres_immutable_next:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_immutable_node
.Lres_immutable_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Canonical rendering <=1MiB. Hash binds the exact root manifest; flags bind
 * selected root features; feature comments are regenerated from the verified
 * complete graph. Artifacts use the existing stable eight-column record. */
res_render_lock:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, res_rendered
    mov x9, x16
    ARM_ADDR x16, res_render_cursor
    str x9, [x16]
    ARM_ADDR x16, res_header
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, dependency_origin_prefix
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, dependency_origin
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL res_append
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, res_default_prefix
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, res_false
    mov x0, x16
    ARM_ADDR x16, res_default
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lres_render_default
    ARM_ADDR x16, res_true
    mov x0, x16
.Lres_render_default:
    ARM_CALL res_append
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, res_features_prefix
    mov x0, x16
    ARM_CALL res_append
    eor w12, w21, w21
    tst w12, w12
    mov w21, w12
    ARM_ADDR x16, res_root_request_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lres_render_features
    ARM_ADDR x16, res_dash
    mov x0, x16
    ARM_CALL res_append
.Lres_render_features:
    ARM_ADDR x16, res_root_request_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lres_render_hash
    tst x21, x21
    b.eq .Lres_render_feature_item
    ARM_ADDR x16, res_comma
    mov x0, x16
    ARM_CALL res_append
.Lres_render_feature_item:
    ARM_ADDR x16, res_root_requests
    mov x9, x16
    mov x16, x9
    add x16, x16, x21, lsl #3
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL res_append
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_render_features
.Lres_render_hash:
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, res_manifest_prefix
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, res_root_hash
    mov x0, x16
    ARM_CALL res_append
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL res_append
    /* Sort node pointers, excluding the root, by canonical package identity. */
    ARM_ADDR x16, res_order
    mov x22, x16
    ARM_IMM w10, 1
    mov w21, w10
.Lres_order_fill:
    ARM_ADDR x16, res_node_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lres_order_sort_start
    mov x9, x21
    ARM_IMM x11, 12
    lsl x12, x9, x11
    tst x12, x12
    mov x9, x12
    ARM_ADDR x16, res_nodes
    mov x2, x16
    adds x12, x9, x2
    mov x9, x12
    mov x16, x22
    add x16, x16, x21, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_order_fill
.Lres_order_sort_start:
    ARM_IMM w10, 1
    mov w21, w10
.Lres_order_sort:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 1
    subs x12, x9, x11
    mov x9, x12
    cmp x21, x9
    b.hs .Lres_enabled_start
    mov x23, x21
.Lres_order_inner:
    tst x23, x23
    b.eq .Lres_order_next
    mov x16, x22
    add x16, x16, x23, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x2, x10
    mov x16, x9
    ldr x10, [x16]
    mov x0, x10
    mov x16, x2
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL res_strcmp
    tst w9, w9
    b.le .Lres_order_next
    mov x16, x22
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, x23, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    mov x16, x22
    add x16, x16, x23, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    str x9, [x16]
    mov x16, x22
    add x16, x16, x23, lsl #3
    str x2, [x16]
    ARM_IMM x11, 1
    subs x12, x23, x11
    mov x23, x12
    b .Lres_order_inner
.Lres_order_next:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_order_sort
.Lres_enabled_start:
    eor w12, w21, w21
    tst w12, w12
    mov w21, w12
.Lres_enabled_node:
    ARM_ADDR x16, res_node_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lres_render_rows
    ARM_ADDR x16, res_nodes
    mov x23, x16
    tst x21, x21
    b.eq .Lres_enabled_metadata
    mov x16, x22
    add x16, x16, x21, lsl #3
    ARM_IMM x17, -8
    add x16, x16, x17
    ldr x10, [x16]
    mov x23, x10
.Lres_enabled_metadata:
    mov x16, x23
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    mov x24, x10
    eor w12, w19, w19
    tst w12, w12
    mov w19, w12
.Lres_enabled_feature:
    mov x16, x24
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x19, x11
    b.hs .Lres_enabled_next
    mov x16, x23
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x10, [x16]
    lsr x12, x10, x19
    and x12, x12, #1
    cmp x12, #1
    b.lo .Lres_enabled_feature_next
    ARM_ADDR x16, res_enabled_prefix
    mov x0, x16
    ARM_CALL res_append
    mov x16, x23
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL res_append
    ARM_ADDR x16, registry_tab
    mov x0, x16
    ARM_CALL res_append
    mov x9, x19
    ARM_IMM x11, 576
    mul x12, x9, x11
    mov x9, x12
    mov x16, x24
    add x16, x16, x9
    ARM_IMM x17, 36928
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL res_append
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL res_append
.Lres_enabled_feature_next:
    ARM_IMM x11, 1
    adds x12, x19, x11
    mov x19, x12
    b .Lres_enabled_feature
.Lres_enabled_next:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_enabled_node
.Lres_render_rows:
    eor w12, w21, w21
    tst w12, w12
    mov w21, w12
.Lres_render_row:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 1
    subs x12, x9, x11
    mov x9, x12
    cmp x21, x9
    b.hs .Lres_render_done
    mov x16, x22
    add x16, x16, x21, lsl #3
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x23, x10
    eor w12, w19, w19
    tst w12, w12
    mov w19, w12
.Lres_render_field:
    mov x16, x23
    add x16, x16, x19, lsl #3
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL res_append
    ARM_ADDR x16, registry_tab
    mov x0, x16
    ARM_IMM w11, 7
    cmp w19, w11
    b.ne .Lres_render_separator
    ARM_ADDR x16, registry_newline
    mov x0, x16
.Lres_render_separator:
    ARM_CALL res_append
    ARM_IMM w11, 1
    adds w12, w19, w11
    mov w19, w12
    ARM_IMM w11, 8
    cmp w19, w11
    b.lo .Lres_render_field
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lres_render_row
.Lres_render_done:
    ARM_ADDR x16, res_render_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, res_rendered
    mov x2, x16
    subs x12, x9, x2
    mov x9, x12
    ARM_ADDR x16, res_render_length
    str x9, [x16]
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=bounded NUL text. Append to owned1MiB+NUL buffer or fail. */
res_append:
    mov x1, x0
    ARM_ADDR x16, res_render_cursor
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, res_rendered + 1048576
    mov x2, x16
.Lres_append_byte:
    mov x16, x1
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lres_append_done
    cmp x0, x2
    b.hs dependency_lock_too_large
    uxtb w10, w9
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x12, x0, x11
    mov x0, x12
    ARM_IMM x11, 1
    adds x12, x1, x11
    mov x1, x12
    b .Lres_append_byte
.Lres_append_done:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_ADDR x16, res_render_cursor
    str x0, [x16]
    ret

/* Atomic publication reuses private stage and cleanup ownership. Writes all
 * bytes, fsyncs, closes, then renames once. Existing asm.lock survives failure. */
res_commit_lock:
    ARM_SAVE x21
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
    ARM_ADDR x16, dependency_temp_lock
    mov x0, x16
    ARM_IMM w10, 193 + O_NOFOLLOW + O_CLOEXEC
    mov w1, w10
    ARM_IMM w10, 420
    mov w2, w10
    ARM_CALL arm_open
    tst x9, x9
    b.mi dependency_io_error
    mov x21, x9
    mov x0, x9
    ARM_ADDR x16, res_rendered
    mov x1, x16
    ARM_ADDR x16, res_render_length
    ldr x10, [x16]
    mov x2, x10
    ARM_CALL write_all
    tst x9, x9
    b.mi dependency_io_error
    mov x0, x21
    ARM_CALL arm_fsync
    tst x9, x9
    b.mi dependency_io_error
    mov x0, x21
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
    ARM_RESTORE x21
    ret

/* Called after read_manifest by the normal build path. A resolution manifest
 * always requires a v2 lock, even without --locked. Legacy behavior unchanged. */
verify_project_dependencies:
    ARM_ADDR x16, rm_root_metadata
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne res_verify_project
    ARM_CALL res_is_v2
    tst w9, w9
    b.ne res_lock_error
    b verify_legacy_project_dependencies

res_verify_project:
    ARM_IMM w10, 1
    ARM_ADDR x16, res_check_mode
    strb w10, [x16]
    ARM_IMM w10, 5
    mov w0, w10
    eor w12, w1, w1
    tst w12, w12
    mov w1, w12
    ARM_CALL dependency_acquire
    ARM_CALL res_check_locked_graph
    ret

/* Sync selects its legacy/graph implementation without consuming argv. */
cmd_sync:
    ARM_CALL read_manifest
    ARM_ADDR x16, rm_root_metadata
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq cmd_sync_legacy
.Lres_sync_args:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lres_sync_start
    mov x21, x9
    mov x0, x9
    ARM_ADDR x16, res_opt_artifacts
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lres_sync_artifacts
    mov x9, x21
    ARM_CALL common_option
    tst w9, w9
    b.eq registry_bad_args
    b .Lres_sync_args
.Lres_sync_artifacts:
    ARM_ADDR x16, res_artifacts
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, res_artifacts
    str x9, [x16]
    b .Lres_sync_args
.Lres_sync_start:
    ARM_IMM w10, 6
    mov w0, w10
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL dependency_acquire
    ARM_CALL res_check_locked_graph
    ARM_CALL release_dependency_lock
    ARM_ADDR x16, res_sync_done
    mov x0, x16
    b res_report

/* Reconstruct and compare the entire graph from locked artifacts. No current
 * index is consulted. Verification mode refuses missing cache; sync can fetch
 * exact locked URLs. Re-rendering detects omitted, extra or edited metadata.
 * Root SHA-256 makes any manifest change require deliberate resolution. */
res_check_locked_graph:
    ARM_CALL res_read_v2
    ARM_CALL res_copy_rows
    ARM_ADDR x16, res_row_count
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, res_locked_count
    str x9, [x16]
    ARM_CALL res_hash_root
    ARM_ADDR x16, res_root_hash
    mov x0, x16
    ARM_ADDR x16, res_lock_hash
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq res_lock_error
    ARM_ADDR x16, res_lock_default
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, res_default
    str x9, [x16]
    ARM_ADDR x16, res_lock_features
    ldr x10, [x16]
    mov x0, x10
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 45
    cmp w10, w11
    b.ne .Lres_locked_features
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne res_lock_error
    eor w12, w0, w0
    tst w12, w12
    mov w0, w12
.Lres_locked_features:
    ARM_CALL res_parse_features
    ARM_CALL res_solve
    tst w9, w9
    b.eq res_lock_error
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 1
    subs x12, x9, x11
    mov x9, x12
    ARM_ADDR x16, res_locked_count
    ldr x11, [x16]
    cmp x9, x11
    b.ne res_lock_error
    ARM_CALL res_render_lock
    ARM_ADDR x16, res_render_length
    ldr x10, [x16]
    mov x3, x10
    ARM_ADDR x16, res_lock_length
    ldr x11, [x16]
    cmp x3, x11
    b.ne res_lock_error
    ARM_ADDR x16, res_rendered
    mov x0, x16
    ARM_ADDR x16, res_lock_original
    mov x1, x16
    cbz x3, .Lres_arm_repeat_done6
.Lres_arm_repeat6:
    ldrb w10, [x0], #1
    ldrb w11, [x1], #1
    sub x3, x3, #1
    cmp w10, w11
    b.ne .Lres_arm_repeat_done6
    cbnz x3, .Lres_arm_repeat6
.Lres_arm_repeat_done6:
    b.ne res_lock_error
    ARM_CALL registry_cleanup
    ret

res_report:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lres_report_text
    ARM_ADDR x16, dependency_count_prefix
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM x11, 1
    subs x12, x0, x11
    mov x0, x12
    ARM_ADDR x16, dependency_number + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x0, x9
    ARM_CALL out
    ARM_ADDR x16, dependency_result_suffix
    mov x0, x16
.Lres_report_text:
    ARM_CALL out
    b exit_ok

res_conflict_error:
    /* JSON stays structured through registry_fail; package text has already
     * passed canonical ASCII validation, so no credential-bearing input leaks. */
    ARM_ADDR x16, res_conflict_buffer
    mov x0, x16
    ARM_ADDR x16, res_err_conflict
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, res_conflict_name
    ldr x10, [x16]
    mov x1, x10
    tst x1, x1
    b.ne .Lres_conflict_named
    ARM_ADDR x16, res_root_name
    mov x1, x16
.Lres_conflict_named:
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, res_reason_separator
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, res_conflict_reason
    ldr x1, [x16]
    cbnz x1, .Lres_conflict_reason_ready
    ARM_ADDR x1, res_reason_version
.Lres_conflict_reason_ready:
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, res_conflict_range
    ldr x10, [x16]
    cbz x10, .Lres_conflict_advice
    ARM_ADDR x1, res_requirement_prefix
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, res_conflict_range
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, res_requirement_suffix
    ARM_CALL copy_string
    mov x0, x9
.Lres_conflict_advice:
    ARM_ADDR x1, res_err_conflict_suffix
    ARM_CALL copy_string
    ARM_ADDR x16, res_conflict_buffer
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
res_limit_error:
    ARM_ADDR x16, res_err_limit
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
res_manifest_error:
    ARM_ADDR x16, res_err_manifest
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
res_lock_error:
    ARM_ADDR x16, res_err_lock
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
res_use_resolve_error:
    ARM_ADDR x16, res_err_legacy
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail

.section .rodata
res_header: .asciz "# asm-lock-v2\n"
res_default_prefix: .asciz "# default "
res_features_prefix: .asciz "# features "
res_manifest_prefix: .asciz "# manifest "
res_enabled_prefix: .asciz "# enabled "
res_true: .asciz "1"
res_false: .asciz "0"
res_dash: .asciz "-"
res_comma: .asciz ","
res_slash: .asciz "/"
res_archive_suffix: .asciz ".tar.gz"
res_opt_artifacts: .asciz "--artifacts"
res_opt_features: .asciz "--features"
res_opt_no_default: .asciz "--no-default-features"
res_done: .asciz "Resolved and locked the complete source dependency graph.\n"
res_sync_done: .asciz "Synchronized the exact locked dependency graph.\n"
res_err_limit: .asciz "dependency resolution resource limit exhausted. Reduce the graph or narrow version requirements"
res_err_manifest: .asciz "invalid dependency manifest. Check resolution schema, ranges, and feature declarations"
res_err_lock: .asciz "dependency graph lock is missing, stale, or invalid. Run asm resolve after reviewing asm.toml"
res_err_legacy: .asciz "this project uses dependency resolution. Edit asm.toml, then run asm resolve"
res_err_conflict: .asciz "cannot resolve dependency requirements or features for "
res_reason_separator: .asciz ": "
res_requirement_prefix: .asciz " (requirement "
res_requirement_suffix: .asciz ")"
res_err_conflict_suffix: .asciz ". Check version ranges, target support, features, and dependency cycles; then run asm resolve"
res_help_text:
    .ascii "Usage: asm resolve [--index PATH | --registry HTTPS_URL]\n"
    .ascii "                   [--artifacts DIR] [--features NAME,NAME] [--no-default-features]\n"
    .ascii "Declare dependencies in asm.toml with [resolution] schema = \"1\".\n"
    .ascii "Ranges: exact X.Y.Z, *, ^X.Y.Z, ~X.Y.Z, comma-separated comparisons.\n"
    .ascii "Offline archives use DIR/<sha256>.tar.gz; no network fallback occurs.\n"
    .asciz "Resolution never executes packages. Failed resolution preserves the previous lock.\n"
.section .bss
.balign 8
res_default: .skip 8
res_artifacts: .skip 8
res_cli_features: .skip 8
res_root_requests: .skip 512
res_root_request_count: .skip 8
res_feature_buffer: .skip 2113
.balign 8
res_row_count: .skip 8
res_rows: .skip 262144
res_node_count: .skip 8
res_nodes: .skip 528384
res_previous_count: .skip 8
res_previous_rows: .skip 262144
res_previous_origin: .skip 8
res_loaded_count: .skip 8
res_loaded_rows: .skip 2048
res_metadata: .skip RES_RM_SIZE * 256
res_manifests: .skip 4194560
res_probe: .skip 16
res_artifact_path: .skip 4096
res_root_hash: .skip 65
.balign 8
res_lock_default: .skip 8
res_lock_features: .skip 8
res_lock_hash: .skip 8
res_locked_count: .skip 8
res_lock_length: .skip 8
res_lock_buffer: .skip 1048578
res_lock_original: .skip 1048578
res_rendered: .skip 1048577
.balign 8
res_render_cursor: .skip 8
res_render_length: .skip 8
res_order: .skip 1024
res_conflict_buffer: .skip 1024
res_no_default_seen: .skip 1
res_check_mode: .skip 1
res_snapshot_created: .skip 1
.section .note.GNU-stack,"",@progbits
.include "cli/aarch64/resolver_graph.s"
