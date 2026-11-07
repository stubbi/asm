/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/resolver.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native dependency driver. See docs/specs/dependencies.md.
 * Arguments use a0-a7; t0 holds results. Returning routines preserve s0-s5.
 * x8,t1-s7,s9 conditions are scratch. RV_CALL adds a 16-byte link frame.
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
    RV_ADDR s6, registry_default_url
    mv t0, s6
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 1, 64
    RV_ADDR s6, res_default
    mv s8, s6
    RV_STORE t1, 8
.Lres_args:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_start
    mv s2, t0
    mv a0, t0
    RV_ADDR s6, registry_opt_index
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_arg_index
    mv a0, s2
    RV_ADDR s6, registry_opt_registry
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_arg_registry
    mv a0, s2
    RV_ADDR s6, res_opt_artifacts
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_arg_artifacts
    mv a0, s2
    RV_ADDR s6, res_opt_features
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_arg_features
    mv a0, s2
    RV_ADDR s6, res_opt_no_default
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_arg_no_default
    mv a0, s2
    RV_ADDR s6, opt_help
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, res_help
    mv t0, s2
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Lres_args
.Lres_arg_index:
    RV_ADDR s6, registry_origin_seen
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_local_index
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_origin_seen
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lres_args
.Lres_arg_registry:
    RV_ADDR s6, registry_origin_seen
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_CALL registry_https_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_origin_seen
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lres_args
.Lres_arg_artifacts:
    RV_ADDR s6, res_artifacts
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, res_artifacts
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Lres_args
.Lres_arg_features:
    RV_ADDR s6, res_cli_features
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, res_cli_features
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Lres_args
.Lres_arg_no_default:
    RV_ADDR s6, res_no_default_seen
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_bad_args
    RV_IMM t1, 1, 32
    RV_ADDR s6, res_no_default_seen
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 0, 64
    RV_ADDR s6, res_default
    mv s8, s6
    RV_STORE t1, 8
    RV_JUMP .Lres_args
.Lres_start:
    RV_CALL read_manifest
    RV_CALL res_require_native_target
    RV_ADDR s6, rm_root_metadata
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, res_manifest_error
    RV_ADDR s6, res_cli_features
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL res_parse_features
    RV_IMM t1, 6, 32
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL dependency_acquire
    RV_CALL res_hash_root
    RV_CALL res_read_previous
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, registry_local_index
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_origin_ready
    RV_ADDR s6, dependency_local_origin
    mv t0, s6
.Lres_origin_ready:
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, res_previous_origin
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lres_index
    mv a0, t0
    RV_ADDR s6, res_previous_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_origin_error
.Lres_index:
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lres_index_read
    RV_CALL registry_workspace
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_index
    mv a1, s6
    RV_ADDR s6, registry_index_max
    mv a2, s6
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_download_error
    RV_ADDR s6, registry_temp_index
    mv t0, s6
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_STORE t0, 8
.Lres_index_read:
    RV_CALL registry_read_index
    RV_CALL registry_parse_index
    RV_CALL res_copy_rows
    /* The registry input is now in its owned buffer. A later cleanup cannot
     * erase it. No network artifact can replace index strings. */
    RV_CALL registry_cleanup
    RV_CALL res_solve
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, res_conflict_error
    RV_CALL res_check_immutable
    RV_CALL res_render_lock
    RV_CALL res_commit_lock
    RV_CALL registry_cleanup
    RV_CALL release_dependency_lock
    RV_ADDR s6, res_done
    mv a0, s6
    RV_JUMP res_report
/* Graph resolution is native-only; exact v2 locks retain foreign targets.
 * No file effects. Caller scratch only; RV_CALL supplies an aligned frame. */
res_require_native_target:
    RV_ADDR a0, package_target
    RV_ADDR a1, registry_host
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolver227
    RV_JUMP res_native_target_error
.Lrv_cb_skip_resolver227:
    ret
res_native_target_error:
    RV_ADDR a0, res_native_target_message
    li a1, 2
    RV_ZEXT a1
    RV_JUMP die
res_help:
    RV_ADDR s6, res_help_text
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
/* a0=optional comma list, <=2111 bytes. Store at most64 unique borrowed names
 * in owned res_feature_buffer[2113]. Sort them for a canonical lock header.
 * Empty input is represented by NULL; explicit empty/duplicate names fail.
 * Stack:80 saved bytes. No filesystem effect. */
res_parse_features:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_IMM t1, 0, 64
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_STORE t1, 8
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_features_done
    mv s2, a0
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, registry_bad_args
    RV_IMM t2, 2111, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_bad_args
    RV_ADDR s6, res_feature_buffer
    mv a0, s6
    mv a1, s2
    RV_CALL copy_string
    RV_ADDR s6, res_feature_buffer
    mv s2, s6
.Lres_feature_name:
    mv s3, s2
    mv s10, s4
    xor t3, s4, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s4, t3
    RV_ZEXT s4
.Lres_feature_chars:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    andi t1, t0, 255
    andi t2, t0, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_feature_end
    andi t1, t0, 255
    RV_IMM t2, 44, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_feature_end
    andi t1, t0, 255
    RV_IMM t2, 97, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lres_feature_other
    andi t1, t0, 255
    RV_IMM t2, 122, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lres_feature_char_ok
.Lres_feature_other:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    andi t1, t0, 255
    RV_IMM t2, 45, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_feature_char_ok
    andi t1, t0, 255
    RV_IMM t2, 95, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_feature_char_ok
    andi t1, t0, 255
    RV_IMM t2, 48, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_bad_args
    andi t1, t0, 255
    RV_IMM t2, 57, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, registry_bad_args
.Lres_feature_char_ok:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s4, t3
    RV_ZEXT s4
    RV_IMM t2, 32, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, registry_bad_args
    RV_JUMP .Lres_feature_chars
.Lres_feature_end:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    andi t1, t0, 255
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and s5, s5, s10
    or s5, s5, s11
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    RV_IMM t2, 64, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, res_limit_error
    RV_ADDR s6, res_root_requests
    mv s4, s6
    mv s10, a6
    xor t3, a6, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a6, t3
    RV_ZEXT a6
.Lres_feature_duplicate:
    mv s8, a6
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_feature_insert
    mv a0, s3
    mv s6, s4
    mv s10, a6
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_SAVE a6
    RV_CALL streq
    RV_RESTORE a6
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_bad_args
    RV_IMM t2, 1, 64
    mv s8, a6
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a6, t3
    RV_JUMP .Lres_feature_duplicate
.Lres_feature_insert:
    mv s6, s4
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s3, 8
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_STORE t3, 8
    andi t1, s5, 255
    andi t2, s5, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_feature_sort
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_feature_name
.Lres_feature_sort:
    RV_IMM t1, 1, 32
    mv s2, t1
    RV_ZEXT s2
.Lres_feature_sort_outer:
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_features_done
    mv s3, s2
.Lres_feature_sort_inner:
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_feature_sort_next
    mv s6, s4
    mv s10, s3
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s4
    mv s10, s3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL res_strcmp
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND le, .Lres_feature_sort_next
    mv s6, s4
    mv s10, s3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s4
    mv s10, s3
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, s4
    mv s10, s3
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s6, s4
    mv s10, s3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE a2, 8
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv s3, t3
    RV_JUMP .Lres_feature_sort_inner
.Lres_feature_sort_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_feature_sort_outer
.Lres_features_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* NUL ASCII strings a0/a1. t0 signed comparison; read-only, stack:none. */
res_strcmp:
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lres_strcmp_loop:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s6, a1
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    mv s8, t0
    mv s10, a2
    RV_FLAGS sub, 32
    mv t3, s11
    mv t0, t3
    RV_ZEXT t0
    RV_BCOND ne, .Lres_strcmp_done
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_strcmp_done
    RV_IMM t2, 1, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a3, t3
    RV_JUMP .Lres_strcmp_loop
.Lres_strcmp_done:
    ret
/* Hash the exact unmodified bytes retained by read_manifest. The parser and
 * lock digest therefore describe one snapshot even if the source file changes.
 * Input rm_root_original[8192]; output res_root_hash[65]. Mature fixed-tool
 * hash adapter receives only the private snapshot through stdin. Stack:none. */
res_hash_root:
    RV_CALL registry_workspace
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, rm_root_original
    mv a1, s6
    RV_ADDR s6, res_snapshot_created
    mv a2, s6
    RV_CALL create_exclusive_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_CALL pub_hash_payload
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_integrity_error
    RV_ADDR s6, pub_hash_buffer
    mv a1, s6
    RV_ADDR s6, res_root_hash
    mv a0, s6
    RV_IMM t1, 64, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolver487
    RV_JUMP .Lres_arm_repeat_done1
.Lrv_cb_skip_resolver487:
.Lres_arm_repeat1:
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
    beqz s8, .Lrv_cb_skip_resolver492
    RV_JUMP .Lres_arm_repeat1
.Lrv_cb_skip_resolver492:
.Lres_arm_repeat_done1:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL registry_cleanup
    ret
/* A non-following bounded probe only selects the parser. Invalid locks still
 * fail in their full readers. t0=1 graph-v3 prefix,0 otherwise. Stack:16 bytes. */
res_is_graph_lock:
    RV_SAVE s2
    RV_ADDR s6, dependency_lock_path
    mv a0, s6
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lres_probe_no
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lres_probe_close
    RV_ADDR s6, registry_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    mv t3, s11
    mv t0, t3
    RV_ZEXT t0
    RV_IMM t2, 32768, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_probe_close
    mv a0, s2
    RV_ADDR s6, res_probe
    mv a1, s6
    RV_IMM t1, 14, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_read
    RV_IMM t2, 14, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lres_probe_close
    RV_IMM t1, 0, 32
    RV_ADDR s6, res_probe + 14
    mv s8, s6
    RV_STORE t1, 1
    mv a0, s2
    RV_CALL rv_close
    RV_ADDR s6, res_probe
    mv a0, s6
    RV_ADDR s6, res_header
    mv a1, s6
    RV_CALL streq
    RV_RESTORE s2
    ret
.Lres_probe_close:
    mv a0, s2
    RV_CALL rv_close
.Lres_probe_no:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    RV_RESTORE s2
    ret
/* Used by legacy add/update/remove. Refuse graph mutation before any changed
 * lock or cache. read_manifest has populated rm_root_metadata. */
res_legacy_guard:
    RV_ADDR s6, rm_root_metadata
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, res_use_resolve_error
    RV_CALL res_is_graph_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, res_use_resolve_error
    ret
/* Preserve previous exact rows for immutable-version comparisons. Owned row
 * pointers borrow either v1 dependency_lock_buffer or res_lock_buffer. */
res_read_previous:
    RV_CALL res_is_graph_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_previous_v1
    RV_CALL res_read_graph_lock
    RV_JUMP .Lres_previous_copy
.Lres_previous_v1:
    RV_CALL dependency_load_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_previous_none
    RV_ADDR s6, dependency_lock_version
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 2
    RV_FLAGS sub, 32
    RV_BCOND eq, res_lock_error
.Lres_previous_copy:
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, res_previous_origin
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    RV_ADDR s6, res_previous_count
    mv s8, s6
    RV_STORE a3, 8
    RV_IMM t2, 3, 64
    sll t3, a3, t2
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    mv a3, t3
    RV_ADDR s6, res_previous_rows
    mv a0, s6
    RV_ADDR s6, registry_rows
    mv a1, s6
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolver609
    RV_JUMP .Lres_arm_repeat_done2
.Lrv_cb_skip_resolver609:
.Lres_arm_repeat2:
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
    beqz s8, .Lrv_cb_skip_resolver614
    RV_JUMP .Lres_arm_repeat2
.Lrv_cb_skip_resolver614:
.Lres_arm_repeat_done2:
.Lres_previous_none:
    ret
/* Load graph v3 as a bounded regular non-symlink file. Keep an unmodified copy for
 * canonical verification. Only flags/origin are trusted as resolution inputs;
 * enabled-feature comments and selected rows are recomputed from archives.
 * Output registry_rows/count, dependency_origin, res_lock_*; stack:64 bytes. */
res_read_graph_lock:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_ADDR s6, dependency_lock_path
    mv a0, s6
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, res_lock_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, res_lock_error
    RV_ADDR s6, registry_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    mv t3, s11
    mv t0, t3
    RV_ZEXT t0
    RV_IMM t2, 32768, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, res_lock_error
    RV_ADDR s6, registry_stat + 48
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1048576, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, res_lock_error
    mv s10, s3
    xor t3, s3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s3, t3
    RV_ZEXT s3
.Lres_lock_read:
    mv a0, s2
    RV_ADDR s6, res_lock_buffer
    mv a1, s6
    mv s8, a1
    mv s10, s3
    RV_FLAGS add, 64
    mv t3, s11
    mv a1, t3
    RV_IMM t1, 1048577, 32
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, s3
    RV_FLAGS sub, 64
    mv t3, s11
    mv a2, t3
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lres_lock_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, res_lock_error
    RV_BCOND eq, .Lres_lock_read_end
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv t3, s11
    mv s3, t3
    RV_IMM t2, 1048576, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, res_lock_error
    RV_JUMP .Lres_lock_read
.Lres_lock_read_end:
    mv a0, s2
    RV_CALL rv_close
    RV_ADDR s6, res_lock_buffer
    mv a0, s6
    mv a3, s3
    RV_ADDR s6, res_lock_length
    mv s8, s6
    RV_STORE s3, 8
    RV_ADDR s6, res_lock_buffer
    mv a1, s6
    RV_ADDR s6, res_lock_original
    mv a0, s6
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolver697
    RV_JUMP .Lres_arm_repeat_done3
.Lrv_cb_skip_resolver697:
.Lres_arm_repeat3:
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
    beqz s8, .Lrv_cb_skip_resolver702
    RV_JUMP .Lres_arm_repeat3
.Lrv_cb_skip_resolver702:
.Lres_arm_repeat_done3:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, res_lock_buffer
    mv a0, s6
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, s3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s6, a0
    mv s10, s3
    add s6, s6, s10
    mv s4, s6
    RV_ADDR s6, res_header
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_lock_error
    mv a0, t0
    RV_ADDR s6, dependency_origin_prefix
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_lock_error
    mv a0, t0
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_STORE a0, 8
    RV_CALL res_line
    mv s2, t0
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
    RV_BCOND ne, .Lres_lock_default
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_https_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, res_lock_error
.Lres_lock_default:
    mv a0, s2
    RV_ADDR s6, res_default_prefix
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_lock_error
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv t3, s11
    mv a2, t3
    RV_ZEXT a2
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, res_lock_error
    mv s6, t0
    RV_IMM s7, 1, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, res_lock_error
    RV_ADDR s6, res_lock_default
    mv s8, s6
    RV_STORE a2, 8
    mv s6, t0
    RV_IMM s7, 2, 64
    mv s10, s7
    add s6, s6, s10
    mv a0, s6
    RV_ADDR s6, res_features_prefix
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_lock_error
    mv a0, t0
    RV_ADDR s6, res_lock_features
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL res_line
    mv a0, t0
    RV_ADDR s6, res_manifest_prefix
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_lock_error
    mv a0, t0
    RV_ADDR s6, res_lock_hash
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL res_line
    mv s2, t0
    RV_ADDR s6, res_lock_hash
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    RV_IMM t2, 64, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, res_lock_error
.Lres_lock_comments:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 35, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_lock_records
    mv a0, s2
    RV_ADDR s6, res_enabled_prefix
    mv a1, s6
    RV_CALL dependency_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_lock_error
    mv a0, t0
    RV_CALL res_line
    mv s2, t0
    RV_JUMP .Lres_lock_comments
.Lres_lock_records:
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_STORE t1, 8
    mv a0, s2
    mv a1, s4
    RV_CALL registry_parse_records
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 128, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, res_limit_error
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor t3, s3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s3, t3
    RV_ZEXT s3
.Lres_lock_validate:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_lock_loaded
    mv s6, s2
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_host
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, res_lock_error
    mv s6, s2
    RV_IMM s7, 24, 64
    mv s10, s7
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
    RV_BCOND eq, res_lock_error
    RV_ADDR s6, registry_rows
    mv s0, s6
.Lres_lock_duplicate:
    mv s8, s0
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_lock_next
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
    RV_BCOND ne, res_lock_error
    RV_IMM t2, 64, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s0, t3
    RV_JUMP .Lres_lock_duplicate
.Lres_lock_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s3, t3
    RV_JUMP .Lres_lock_validate
.Lres_lock_loaded:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* a0 points into res_lock_buffer, s4 its end. Replace LF with NUL and return
 * following byte. Refuse embedded NUL/control/non-ASCII and lines>4095 bytes. */
res_line:
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lres_line_loop:
    mv s8, a0
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hs, res_lock_error
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_line_end
    andi t1, t0, 255
    RV_IMM t2, 9, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_line_char
    andi t1, t0, 255
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, res_lock_error
    andi t1, t0, 255
    RV_IMM t2, 126, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, res_lock_error
.Lres_line_char:
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a0, t3
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t2, 4095, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, res_lock_error
    RV_JUMP .Lres_line_loop
.Lres_line_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    mv s6, a0
    RV_IMM s7, 1, 64
    mv s10, s7
    add s6, s6, s10
    mv t0, s6
    ret
/* Copy validated registry rows into solver-owned storage. Their strings remain
 * borrowed from registry/lock buffers. Count <=4096; stack:none. */
res_copy_rows:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    RV_ADDR s6, res_row_count
    mv s8, s6
    RV_STORE a3, 8
    RV_IMM t2, 3, 64
    sll t3, a3, t2
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    mv a3, t3
    RV_ADDR s6, res_rows
    mv a0, s6
    RV_ADDR s6, registry_rows
    mv a1, s6
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolver958
    RV_JUMP .Lres_arm_repeat_done4
.Lrv_cb_skip_resolver958:
.Lres_arm_repeat4:
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
    beqz s8, .Lrv_cb_skip_resolver963
    RV_JUMP .Lres_arm_repeat4
.Lrv_cb_skip_resolver963:
.Lres_arm_repeat_done4:
    ret
/* Callback a0=validated row, return t0=persistent metadata. Inspect at most
 * 256 candidates. Acquire and validate compressed bytes before parsing their
 * manifest. Cache comparison precedes replacement. In check mode no fetch,
 * extraction or writes to managed caches occur. Stack:80 saved bytes. */
res_load_candidate:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s0, a0
    mv s10, s2
    xor t3, s2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s2, t3
    RV_ZEXT s2
    RV_ADDR s6, res_loaded_rows
    mv s3, s6
.Lres_loaded_find:
    RV_ADDR s6, res_loaded_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_load_new
    mv s6, s3
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lres_loaded_return
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_loaded_find
.Lres_load_new:
    RV_IMM t2, 256, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, res_limit_error
    mv s6, s3
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s0, 8
    RV_ADDR s6, res_loaded_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, res_loaded_count
    mv s8, s6
    RV_STORE t3, 8
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE s0, 8
    mv s6, s0
    RV_IMM s7, 48, 64
    mv s10, s7
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
    RV_ADDR s6, res_check_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_candidate_paths
    mv s10, a0
    xor t3, a0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a0, t3
    RV_ZEXT a0
.Lres_candidate_paths:
    RV_CALL dependency_paths
    RV_CALL registry_workspace
    /* Existing digest cache is verified rather than silently repaired. */
    RV_ADDR s6, dependency_archive_path
    mv a0, s6
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_candidate_cached
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, dependency_cache_changed
    RV_ADDR s6, res_check_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, dependency_cache_missing
    RV_ADDR s6, res_artifacts
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lres_candidate_offline
    mv s6, s0
    RV_IMM s7, 40, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_payload
    mv a1, s6
    mv s6, s0
    RV_IMM s7, 48, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_download_error
    RV_JUMP .Lres_candidate_verify
.Lres_candidate_cached:
    RV_ADDR s6, dependency_archive_path
    mv t0, s6
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_copy_local
    RV_JUMP .Lres_candidate_verify
.Lres_candidate_offline:
    RV_CALL res_offline_path
    RV_ADDR s6, res_artifact_path
    mv t0, s6
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_copy_local
.Lres_candidate_verify:
    RV_CALL registry_verify_payload
    RV_ADDR s6, res_check_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_candidate_check
    RV_CALL dependency_accept_payload
    RV_JUMP .Lres_candidate_manifest
.Lres_candidate_check:
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, s0
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, s0
    RV_IMM s7, 16, 64
    mv s10, s7
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
.Lres_candidate_manifest:
    RV_ADDR s6, pub_manifest_name
    mv a0, s6
    RV_CALL source_archive_member
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, res_manifest_error
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND ne, res_manifest_error
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, res_manifest_error
    RV_IMM t2, 16384, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, res_manifest_error
    mv a1, t0
    mv a3, a2
    mv t0, s2
    RV_IMM t2, 16385, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    RV_ADDR s6, res_manifests
    mv s4, s6
    mv s8, s4
    mv s10, t0
    RV_FLAGS add, 64
    mv t3, s11
    mv s4, t3
    mv a0, s4
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolver1143
    RV_JUMP .Lres_arm_repeat_done5
.Lrv_cb_skip_resolver1143:
.Lres_arm_repeat5:
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
    beqz s8, .Lrv_cb_skip_resolver1148
    RV_JUMP .Lres_arm_repeat5
.Lrv_cb_skip_resolver1148:
.Lres_arm_repeat_done5:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    mv a0, s4
    mv t0, s2
    RV_IMM t2, RES_RM_SIZE, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    RV_ADDR s6, res_metadata
    mv a1, s6
    mv s8, a1
    mv s10, t0
    RV_FLAGS add, 64
    mv t3, s11
    mv a1, t3
    li s10, 16
    add s8, s0, s10
    RV_LOAD a2, 8
    RV_CALL rm_parse_manifest
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, res_manifest_error
    RV_CALL registry_cleanup
.Lres_loaded_return:
    mv t0, s2
    RV_IMM t2, RES_RM_SIZE, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    RV_ADDR s6, res_metadata
    mv a2, s6
    mv s8, t0
    mv s10, a2
    RV_FLAGS add, 64
    mv t3, s11
    mv t0, t3
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Offline directory is a user-selected path, <=4095 bytes. Inspect every
 * existing component without following symlinks; file open also uses NOFOLLOW.
 * This is a checked path boundary, not a race-free descriptor walk. Same-user
 * processes can race path replacement, as with the existing cache checks. */
res_offline_path:
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s6, res_artifacts
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    mv a0, s2
    RV_CALL strlen
    RV_IMM t2, 4000, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_bad_args
    RV_ADDR s6, res_artifact_path
    mv a0, s6
    mv a1, s2
    RV_CALL copy_string
    RV_ADDR s6, res_artifact_path
    mv s2, s6
    mv s3, s2
.Lres_dir_component:
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    andi t2, t0, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_dir_final
    andi t1, t0, 255
    RV_IMM t2, 47, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_dir_advance
    mv s8, s3
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lres_dir_advance
    RV_IMM t1, 0, 32
    mv s6, s3
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL res_check_artifact_dir
    RV_IMM t1, 47, 32
    mv s6, s3
    mv s8, s6
    RV_STORE t1, 1
.Lres_dir_advance:
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s3, t3
    RV_JUMP .Lres_dir_component
.Lres_dir_final:
    RV_CALL res_check_artifact_dir
    mv a0, s3
    RV_ADDR s6, res_slash
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    RV_IMM s7, 32, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, res_archive_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_RESTORE s3
    RV_RESTORE s2
    ret
res_check_artifact_dir:
    RV_ADDR s6, res_artifact_path
    mv a0, s6
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_stat + 16
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    mv t3, s11
    mv t0, t3
    RV_ZEXT t0
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_io_error
    ret
/* Compare every reused identity/version to previous immutable artifact fields.
 * Inputs solver nodes, retained previous rows. Stack:80 saved bytes. */
res_check_immutable:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_IMM t1, 1, 32
    mv s2, t1
    RV_ZEXT s2
.Lres_immutable_node:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_immutable_done
    mv t0, s2
    RV_IMM t2, 12, 64
    sll t3, t0, t2
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    mv t0, t3
    RV_ADDR s6, res_nodes
    mv a2, s6
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    mv s10, s4
    xor t3, s4, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s4, t3
    RV_ZEXT s4
    RV_ADDR s6, res_previous_rows
    mv s5, s6
.Lres_immutable_row:
    RV_ADDR s6, res_previous_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_immutable_next
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s5
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_immutable_row_next
    mv s6, s3
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s5
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_immutable_row_next
    RV_IMM t1, 2, 32
    mv s0, t1
    RV_ZEXT s0
.Lres_immutable_field:
    mv s6, s3
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s5
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, dependency_changed_release
    RV_IMM t2, 1, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s0, t3
    RV_ZEXT s0
    RV_IMM t2, 7, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lres_immutable_field
.Lres_immutable_row_next:
    RV_IMM t2, 64, 64
    mv s8, s5
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s5, t3
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s4, t3
    RV_JUMP .Lres_immutable_row
.Lres_immutable_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_immutable_node
.Lres_immutable_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Canonical rendering <=1MiB. Hash binds the exact root manifest; flags bind
 * selected root features; feature comments are regenerated from the verified
 * complete graph. Artifacts use the existing stable eight-column record. */
res_render_lock:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s6, res_rendered
    mv t0, s6
    RV_ADDR s6, res_render_cursor
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, res_header
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, dependency_origin_prefix
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, dependency_origin
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL res_append
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, res_default_prefix
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, res_false
    mv a0, s6
    RV_ADDR s6, res_default
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lres_render_default
    RV_ADDR s6, res_true
    mv a0, s6
.Lres_render_default:
    RV_CALL res_append
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, res_features_prefix
    mv a0, s6
    RV_CALL res_append
    mv s10, s2
    xor t3, s2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s2, t3
    RV_ZEXT s2
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lres_render_features
    RV_ADDR s6, res_dash
    mv a0, s6
    RV_CALL res_append
.Lres_render_features:
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_render_hash
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_render_feature_item
    RV_ADDR s6, res_comma
    mv a0, s6
    RV_CALL res_append
.Lres_render_feature_item:
    RV_ADDR s6, res_root_requests
    mv t0, s6
    mv s6, t0
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL res_append
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_render_features
.Lres_render_hash:
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, res_manifest_prefix
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, res_root_hash
    mv a0, s6
    RV_CALL res_append
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL res_append
    /* Sort node pointers, excluding the root, by canonical package identity. */
    RV_ADDR s6, res_order
    mv s3, s6
    RV_IMM t1, 1, 32
    mv s2, t1
    RV_ZEXT s2
.Lres_order_fill:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_order_sort_start
    mv t0, s2
    RV_IMM t2, 12, 64
    sll t3, t0, t2
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    mv t0, t3
    RV_ADDR s6, res_nodes
    mv a2, s6
    mv s8, t0
    mv s10, a2
    RV_FLAGS add, 64
    mv t3, s11
    mv t0, t3
    mv s6, s3
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_order_fill
.Lres_order_sort_start:
    RV_IMM t1, 1, 32
    mv s2, t1
    RV_ZEXT s2
.Lres_order_sort:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv t0, t3
    mv s8, s2
    mv s10, t0
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_enabled_start
    mv s4, s2
.Lres_order_inner:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_order_next
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, a2
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL res_strcmp
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND le, .Lres_order_next
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE a2, 8
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv s4, t3
    RV_JUMP .Lres_order_inner
.Lres_order_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_order_sort
.Lres_enabled_start:
    mv s10, s2
    xor t3, s2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s2, t3
    RV_ZEXT s2
.Lres_enabled_node:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_render_rows
    RV_ADDR s6, res_nodes
    mv s4, s6
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_enabled_metadata
    mv s6, s3
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, -8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s4, t1
.Lres_enabled_metadata:
    mv s6, s4
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s5, t1
    mv s10, s0
    xor t3, s0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s0, t3
    RV_ZEXT s0
.Lres_enabled_feature:
    mv s6, s5
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_enabled_next
    mv s6, s4
    RV_IMM s7, 24, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    srl t3, t1, s0
    li s10, 1
    and t3, t3, s10
    mv s8, t3
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lres_enabled_feature_next
    RV_ADDR s6, res_enabled_prefix
    mv a0, s6
    RV_CALL res_append
    mv s6, s4
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL res_append
    RV_ADDR s6, registry_tab
    mv a0, s6
    RV_CALL res_append
    mv t0, s0
    RV_IMM t2, 576, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    mv s6, s5
    mv s10, t0
    add s6, s6, s10
    RV_IMM s7, 36928, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL res_append
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL res_append
.Lres_enabled_feature_next:
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s0, t3
    RV_JUMP .Lres_enabled_feature
.Lres_enabled_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_enabled_node
.Lres_render_rows:
    mv s10, s2
    xor t3, s2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s2, t3
    RV_ZEXT s2
.Lres_render_row:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv t0, t3
    mv s8, s2
    mv s10, t0
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lres_render_done
    mv s6, s3
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s4, t1
    mv s10, s0
    xor t3, s0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s0, t3
    RV_ZEXT s0
.Lres_render_field:
    mv s6, s4
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL res_append
    RV_ADDR s6, registry_tab
    mv a0, s6
    RV_IMM t2, 7, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_render_separator
    RV_ADDR s6, registry_newline
    mv a0, s6
.Lres_render_separator:
    RV_CALL res_append
    RV_IMM t2, 1, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s0, t3
    RV_ZEXT s0
    RV_IMM t2, 8, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lres_render_field
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_JUMP .Lres_render_row
.Lres_render_done:
    RV_ADDR s6, res_render_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, res_rendered
    mv a2, s6
    mv s8, t0
    mv s10, a2
    RV_FLAGS sub, 64
    mv t3, s11
    mv t0, t3
    RV_ADDR s6, res_render_length
    mv s8, s6
    RV_STORE t0, 8
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* a0=bounded NUL text. Append to owned1MiB+NUL buffer or fail. */
res_append:
    mv a1, a0
    RV_ADDR s6, res_render_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, res_rendered + 1048576
    mv a2, s6
.Lres_append_byte:
    mv s6, a1
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    andi t2, t0, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lres_append_done
    mv s8, a0
    mv s10, a2
    RV_FLAGS sub, 64
    RV_BCOND hs, dependency_lock_too_large
    andi t1, t0, 255
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a0, t3
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a1, t3
    RV_JUMP .Lres_append_byte
.Lres_append_done:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, res_render_cursor
    mv s8, s6
    RV_STORE a0, 8
    ret
/* Atomic publication reuses private stage and cleanup ownership. Writes all
 * bytes, fsyncs, closes, then renames once. Existing asm.lock survives failure. */
res_commit_lock:
    RV_SAVE s2
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
    RV_ADDR s6, dependency_temp_lock
    mv a0, s6
    RV_IMM t1, 193 + O_NOFOLLOW + O_CLOEXEC, 32
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
    mv s2, t0
    mv a0, t0
    RV_ADDR s6, res_rendered
    mv a1, s6
    RV_ADDR s6, res_render_length
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL write_all
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    mv a0, s2
    RV_CALL rv_fsync
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, dependency_io_error
    mv a0, s2
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
    RV_RESTORE s2
    ret
/* Called after read_manifest by the normal build path. A resolution manifest
 * always requires a graph v3 lock, even without --locked. Legacy behavior unchanged. */
verify_project_dependencies:
    RV_ADDR s6, rm_root_metadata
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, res_verify_project
    RV_CALL res_is_graph_lock
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, res_lock_error
    RV_JUMP verify_legacy_project_dependencies
res_verify_project:
    RV_CALL res_require_native_target
    RV_IMM t1, 1, 32
    RV_ADDR s6, res_check_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 5, 32
    mv a0, t1
    RV_ZEXT a0
    mv s10, a1
    xor t3, a1, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a1, t3
    RV_ZEXT a1
    RV_CALL dependency_acquire
    RV_CALL res_check_locked_graph
    ret
/* Sync selects its legacy/graph implementation without consuming argv. */
cmd_sync:
    RV_CALL res_is_graph_lock
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolver1824
    RV_JUMP cmd_sync_legacy
.Lrv_cb_skip_resolver1824:
.Lres_sync_args:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lres_sync_start
    mv s2, t0
    mv a0, t0
    RV_ADDR s6, res_opt_artifacts
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lres_sync_artifacts
    mv t0, s2
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Lres_sync_args
.Lres_sync_artifacts:
    RV_ADDR s6, res_artifacts
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, res_artifacts
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Lres_sync_args
.Lres_sync_start:
    RV_CALL read_manifest
    RV_CALL res_require_native_target
    RV_ADDR s6, rm_root_metadata
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND ne, res_lock_error
    RV_IMM t1, 6, 32
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL dependency_acquire
    RV_CALL res_check_locked_graph
    RV_CALL release_dependency_lock
    RV_ADDR s6, res_sync_done
    mv a0, s6
    RV_JUMP res_report
/* Reconstruct and compare the entire graph from locked artifacts. No current
 * index is consulted. Verification mode refuses missing cache; sync can fetch
 * exact locked URLs. Re-rendering detects omitted, extra or edited metadata.
 * Root SHA-256 makes any manifest change require deliberate resolution. */
res_check_locked_graph:
    RV_CALL res_read_graph_lock
    RV_CALL res_copy_rows
    RV_ADDR s6, res_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, res_locked_count
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL res_hash_root
    RV_ADDR s6, res_root_hash
    mv a0, s6
    RV_ADDR s6, res_lock_hash
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, res_lock_error
    RV_ADDR s6, res_lock_default
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, res_default
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, res_lock_features
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 45, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_locked_features
    mv s6, a0
    RV_IMM s7, 1, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, res_lock_error
    mv s10, a0
    xor t3, a0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a0, t3
    RV_ZEXT a0
.Lres_locked_features:
    RV_CALL res_parse_features
    RV_CALL res_solve
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, res_lock_error
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv t0, t3
    RV_ADDR s6, res_locked_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, res_lock_error
    RV_CALL res_render_lock
    RV_ADDR s6, res_render_length
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    RV_ADDR s6, res_lock_length
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, res_lock_error
    RV_ADDR s6, res_rendered
    mv a0, s6
    RV_ADDR s6, res_lock_original
    mv a1, s6
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolver1940
    RV_JUMP .Lres_arm_repeat_done6
.Lrv_cb_skip_resolver1940:
.Lres_arm_repeat6:
    mv s8, a0
    RV_LOAD t1, 1
    li s10, 1
    add a0, a0, s10
    mv s8, a1
    RV_LOAD t2, 1
    li s10, 1
    add a1, a1, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lres_arm_repeat_done6
    mv s8, a3
    beqz s8, .Lrv_cb_skip_resolver1947
    RV_JUMP .Lres_arm_repeat6
.Lrv_cb_skip_resolver1947:
.Lres_arm_repeat_done6:
    RV_BCOND ne, res_lock_error
    RV_CALL registry_cleanup
    ret
res_report:
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lres_report_text
    RV_ADDR s6, dependency_count_prefix
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv a0, t3
    RV_ADDR s6, dependency_number + 31
    mv a1, s6
    RV_CALL unsigned_decimal
    mv a0, t0
    RV_CALL out
    RV_ADDR s6, dependency_result_suffix
    mv a0, s6
.Lres_report_text:
    RV_CALL out
    RV_JUMP exit_ok
res_conflict_error:
    /* JSON stays structured through registry_fail; package text has already
     * passed canonical ASCII validation, so no credential-bearing input leaks. */
    RV_ADDR s6, res_conflict_buffer
    mv a0, s6
    RV_ADDR s6, res_err_conflict
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, res_conflict_name
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND ne, .Lres_conflict_named
    RV_ADDR s6, res_root_name
    mv a1, s6
.Lres_conflict_named:
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, res_reason_separator
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, res_conflict_reason
    mv s8, s6
    RV_LOAD a1, 8
    mv s8, a1
    beqz s8, .Lrv_cb_skip_resolver2003
    RV_JUMP .Lres_conflict_reason_ready
.Lrv_cb_skip_resolver2003:
    RV_ADDR a1, res_reason_version
.Lres_conflict_reason_ready:
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, res_conflict_range
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    bnez s8, .Lrv_cb_skip_resolver2010
    RV_JUMP .Lres_conflict_advice
.Lrv_cb_skip_resolver2010:
    RV_ADDR a1, res_requirement_prefix
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, res_conflict_range
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, res_requirement_suffix
    RV_CALL copy_string
    mv a0, t0
.Lres_conflict_advice:
    RV_ADDR a1, res_err_conflict_suffix
    RV_CALL copy_string
    RV_ADDR s6, res_conflict_buffer
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
res_limit_error:
    RV_ADDR s6, res_err_limit
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
res_manifest_error:
    RV_ADDR s6, res_err_manifest
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
res_lock_error:
    RV_ADDR s6, res_err_lock
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
res_use_resolve_error:
    RV_ADDR s6, res_err_legacy
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
.section .rodata
res_native_target_message: .asciz "dependency resolution requires the native host target; use exact dependency commands for another target"
res_header: .asciz "# asm-lock-v3\n"
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
.section .note.GNU-stack,""
.include "cli/riscv64/resolver_graph.s"
