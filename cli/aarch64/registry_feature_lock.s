/* SPDX-License-Identifier: AGPL-3.0-or-later
 * V2 feature selection, complete v4 graph facts, and exact envelope cache.
 * Native AArch64 ABI: x0/x1/x2 inputs; x9 result. Preserve x19-x24 and SP.
 * Serial owned buffers:64 requests of<=32 bytes,256 profiles11296 bytes,
 * control envelope<=65536 bytes, cache paths<=96. No submitted code runs.
 * Local cache checks bind bytes to the lock, not current remote authority.
 */
.section .text
/* x0=option string. w9=1 handled,0 unknown. Only resolve accepts choices.
 * Duplicate options and empty/duplicate feature names fail before network.
 * Request text is copied before later argument or parser activity. Stack 48. */
r4_option:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    ARM_ADDR x16, r4_opt_features
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr4_option_features
    mov x0, x21
    ARM_ADDR x16, r4_opt_no_defaults
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr4_option_return
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 5
    cmp x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r4_option_bits
    ldrb w10, [x16]
    ARM_IMM w11, 2
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.ne r2_arguments
    ARM_ADDR x16, r4_option_bits
    ldrb w10, [x16]
    ARM_IMM w11, 2
    orr w10, w10, w11
    tst w10, w10
    ARM_ADDR x16, r4_option_bits
    strb w10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_defaults
    str x10, [x16]
    b .Lr4_option_yes
.Lr4_option_features:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 5
    cmp x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r4_option_bits
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.ne r2_arguments
    ARM_ADDR x16, r4_option_bits
    ldrb w10, [x16]
    ARM_IMM w11, 1
    orr w10, w10, w11
    tst w10, w10
    ARM_ADDR x16, r4_option_bits
    strb w10, [x16]
    ARM_CALL registry_arg_value
    mov x0, x9
    ARM_CALL r4_parse_requests
.Lr4_option_yes:
    ARM_IMM w9, 1
.Lr4_option_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=comma-separated names<=2111 bytes. Canonicalize into owned NUL list.
 * Reject invalid names, duplicates and list overflow. Stack 96 plus callees.
 * All copies have checked total capacity; sort is bounded insertion sort. */
r4_parse_requests:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
    ARM_ADDR x16, r4_request_input
    mov x2, x16
.Lr4_request_copy:
    mov w10, w3
    ARM_IMM w11, 2112
    cmp w10, w11
    b.hs r2_arguments
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov x16, x2
    add x16, x16, x3
    strb w9, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.ne .Lr4_request_copy
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_request_count
    str x10, [x16]
    ARM_ADDR x16, r4_request_input
    mov x21, x16
    ARM_ADDR x16, r4_request_pointers
    mov x22, x16
    mov x23, x21
.Lr4_request_split:
    ARM_ADDR x16, g4_request_count
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs r2_arguments
    mov x16, x22
    add x16, x16, x9, lsl #3
    str x21, [x16]
    ARM_ADDR x16, g4_request_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g4_request_count
    str x10, [x16]
.Lr4_request_separator:
    mov x16, x23
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr4_request_validate_last
    mov x16, x23
    ldrb w10, [x16]
    ARM_IMM w11, 44
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr4_request_validate
    ARM_IMM x11, 1
    adds x23, x23, x11
    b .Lr4_request_separator
.Lr4_request_validate:
    ARM_IMM w10, 0
    mov x16, x23
    strb w10, [x16]
    mov x0, x21
    ARM_CALL g4_feature_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_IMM x11, 1
    adds x23, x23, x11
    mov x21, x23
    b .Lr4_request_split
.Lr4_request_validate_last:
    mov x0, x21
    ARM_CALL g4_feature_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_IMM w19, 1
.Lr4_request_sort_outer:
    mov x10, x19
    ARM_ADDR x16, g4_request_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr4_request_sorted
    mov x16, x22
    add x16, x16, x19, lsl #3
    ldr x21, [x16]
    mov x20, x19
.Lr4_request_sort_inner:
    mov x10, x20
    mov x11, x20
    tst x10, x11
    b.eq .Lr4_request_store
    mov x16, x22
    add x16, x16, x20, lsl #3
    ARM_IMM x17, 8
    sub x16, x16, x17
    ldr x23, [x16]
    mov x0, x23
    mov x1, x21
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    b.mi .Lr4_request_store
    mov x16, x22
    add x16, x16, x20, lsl #3
    str x23, [x16]
    ARM_IMM x11, 1
    subs x20, x20, x11
    b .Lr4_request_sort_inner
.Lr4_request_store:
    mov x16, x22
    add x16, x16, x20, lsl #3
    str x21, [x16]
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr4_request_sort_outer
.Lr4_request_sorted:
    ARM_ADDR x16, r4_request_text
    mov x24, x16
    ARM_ADDR x16, g4_requests
    str x24, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr4_request_own:
    mov x10, x19
    ARM_ADDR x16, g4_request_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr4_request_done
    mov x0, x24
    mov x16, x22
    add x16, x16, x19, lsl #3
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x24, x16
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr4_request_own
.Lr4_request_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Confirm explicit root requests exist before contacting any registry.
 * An absent implicit default is permitted. Stack 48; owns no input. */
r4_validate_selection:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, g4_requests
    ldr x21, [x16]
.Lr4_validate_request:
    mov x10, x19
    ARM_ADDR x16, g4_request_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr4_validate_done
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    mov x1, x21
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r4_selection_error
    mov x0, x21
    ARM_CALL g4_next
    mov x21, x9
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr4_validate_request
.Lr4_validate_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
r4_selection_error:
    ARM_ADDR x16, r4_err_selection
    mov x0, x16
    b r3_fail

/* x9=profile orNULL,x2=dependency count. Refuse feature semantics in v3.
 * Legacy lock readers cannot ignore dormant declarations or child requests.
 * Preserves callee registers; scratch x9/x3/x2. No stack or effects. */
r4_legacy_profile:
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr4_legacy_done
    mov x16, x9
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r3_lock_error
    mov x16, x9
    ldr x9, [x16]
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr4_legacy_option:
    mov x10, x3
    mov x11, x2
    cmp x10, x11
    b.hs .Lr4_legacy_done
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, 2
    cmp x10, x11
    b.ne r3_lock_error
    mov x16, x9
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r3_lock_error
    ARM_IMM x11, 1
    adds x3, x3, x11
    ARM_IMM x11, 24
    adds x9, x9, x11
    b .Lr4_legacy_option
.Lr4_legacy_done:
    ret

/* Consume exactly one v4 selection row after its checked authority header.
 * Canonical rendering later rejects reordered requests and all extra rows.
 * Lock parsing fields borrow an independent buffer. Stack 16 plus callees. */
r4_read_selection:
    ARM_SAVE x19
    ARM_CALL r3_line
    mov w10, w9
    ARM_IMM w11, 3
    cmp w10, w11
    b.ne r3_lock_error
    ARM_ADDR x16, r3_fields
    ldr x0, [x16]
    ARM_ADDR x16, r4_selection_word
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_ADDR x16, r3_fields + 8
    ldr x9, [x16]
    mov x16, x9
    ldrh w10, [x16]
    ARM_IMM w11, 0x0030
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr4_selection_no_default
    mov x16, x9
    ldrh w10, [x16]
    ARM_IMM w11, 0x0031
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne r3_lock_error
    ARM_IMM x10, 1
    ARM_ADDR x16, g4_defaults
    str x10, [x16]
    b .Lr4_selection_requests
.Lr4_selection_no_default:
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_defaults
    str x10, [x16]
.Lr4_selection_requests:
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_request_count
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_requests
    str x10, [x16]
    ARM_ADDR x16, r3_fields + 16
    ldr x0, [x16]
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x002d
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr4_selection_check
    ARM_CALL r4_parse_requests
.Lr4_selection_check:
    ARM_CALL r4_validate_selection
    ARM_RESTORE x19
    ret

/* Append v4 root selection and enabled local features. Stack 48 plus writer.
 * Request strings are already sorted and bounded; an empty list is '-'. */
r4_render_selection:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, r4_selection_word
    mov x1, x16
    ARM_CALL r3_append
    ARM_CALL r3_tab
    ARM_ADDR x16, r4_zero
    mov x1, x16
    ARM_ADDR x16, g4_defaults
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr4_render_defaults
    ARM_ADDR x16, r4_one
    mov x1, x16
.Lr4_render_defaults:
    ARM_CALL r3_append
    ARM_CALL r3_tab
    ARM_ADDR x16, g4_request_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lr4_render_requests_start
    ARM_ADDR x16, r4_dash
    mov x1, x16
    ARM_CALL r3_append
    b .Lr4_render_requests_end
.Lr4_render_requests_start:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, g4_requests
    ldr x21, [x16]
.Lr4_render_request:
    mov x10, x19
    mov x11, x19
    tst x10, x11
    b.eq .Lr4_render_request_text
    ARM_ADDR x16, r4_comma
    mov x1, x16
    ARM_CALL r3_append
.Lr4_render_request_text:
    mov x1, x21
    ARM_CALL r3_append
    mov x0, x21
    ARM_CALL g4_next
    mov x21, x9
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x10, x19
    ARM_ADDR x16, g4_request_count
    ldr x11, [x16]
    cmp x10, x11
    b.lo .Lr4_render_request
.Lr4_render_requests_end:
    ARM_CALL r3_lf
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    ARM_ADDR x16, g4_root_features
    ldr x1, [x16]
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r4_render_features
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=profile,x1=enabled bitset,x2=package name orNULL for root.
 * Append sorted feature rows. Input profile is validated and owned. Stack 96.
 * Never derive a package selection from a lock's feature rows. */
r4_render_features:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr4_features_done
    mov x21, x0
    mov x22, x1
    mov x23, x2
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x24, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr4_render_feature:
    mov x10, x19
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr4_features_done
    mov x10, x22
    lsrv x11, x10, x19
    and x11, x11, #1
    cmp x11, #0
    b.eq .Lr4_render_feature_next
    ARM_ADDR x16, r4_root_feature_word
    mov x1, x16
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.eq .Lr4_render_feature_word
    ARM_ADDR x16, r4_feature_word
    mov x1, x16
.Lr4_render_feature_word:
    ARM_CALL r3_append
    ARM_CALL r3_tab
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.eq .Lr4_render_feature_name
    mov x1, x23
    ARM_CALL r3_append
    ARM_CALL r3_tab
.Lr4_render_feature_name:
    mov x16, x24
    ldr x1, [x16]
    ARM_CALL r3_append
    ARM_CALL r3_lf
.Lr4_render_feature_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    ARM_IMM x11, 24
    adds x24, x24, x11
    b .Lr4_render_feature
.Lr4_features_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

r4_render_node_features:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr4_render_node_feature:
    mov x10, x19
    ARM_ADDR x16, r3_order_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr4_render_node_features_done
    ARM_ADDR x16, r3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    ldr x21, [x16]
    ARM_ADDR x16, g4_profiles
    mov x9, x16
    mov x16, x9
    add x16, x16, x21, lsl #3
    ldr x0, [x16]
    ARM_ADDR x16, g4_active_features
    mov x9, x16
    mov x16, x9
    add x16, x16, x21, lsl #3
    ldr x1, [x16]
    mov x9, x21
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x2, x16
    mov x11, x9
    adds x2, x2, x11
    ARM_CALL r4_render_features
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr4_render_node_feature
.Lr4_render_node_features_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=candidate index. Set owned metadata pathname using checked hex binding.
 * The fixed relative path is<96 bytes. No filesystem effects; Stack 16. */
r4_metadata_path:
    ARM_SAVE x19
    mov x19, x0
    ARM_ADDR x16, r4_cache_path
    mov x0, x16
    ARM_ADDR x16, r4_metadata_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x9, x19
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records + 204
    mov x1, x16
    mov x11, x9
    adds x1, x1, x11
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r4_json_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x19
    ret

/* x0=candidate index. Retain verified exact envelope during sync only.
 * Stage0600 bytes, fsync, link without replacement, then remove stage.
 * Existing bytes must match; symlinks/nonregular files fail. Parent traversal
 * checks protected directories. Advisory locking coordinates Asm processes;
 * pathname finalization is not a sandbox against another same-user process.
 * Stack 64 plus callees; stage is registered for failure cleanup. */
r4_metadata_save:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x21, x0
    ARM_ADDR x16, r4_metadata_root
    mov x0, x16
    ARM_CALL make_safe_dir
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r4_metadata_root
    mov x0, x16
    ARM_IMM w1, 1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_IMM w9, 3
    ARM_CALL arm_close
    mov x0, x21
    ARM_CALL r4_metadata_path
    ARM_ADDR x16, r4_stage_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r4_metadata_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r4_stage_path
    mov x9, x16
    ARM_ADDR x16, registry_extra_temp
    str x9, [x16]
    mov x0, x9
    ARM_ADDR x16, r2_envelope
    mov x1, x16
    ARM_ADDR x16, r4_envelope_length
    ldr x2, [x16]
    ARM_CALL r2_write_file
    ARM_ADDR x16, r4_stage_path
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 1
    ARM_CALL r2_open_path
    mov x23, x9
    mov x0, x9
    ARM_IMM w9, 74
    ARM_CALL arm_fsync
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x0, x23
    ARM_IMM w9, 3
    ARM_CALL arm_close
    ARM_ADDR x16, r4_stage_path
    mov x0, x16
    ARM_ADDR x16, r4_cache_path
    mov x1, x16
    ARM_IMM w9, 86
    ARM_CALL arm_link
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr4_metadata_unstage
    mov x10, x9
    ARM_IMM x11, -17
    cmp x10, x11
    b.ne r2_io
.Lr4_metadata_unstage:
    ARM_ADDR x16, r4_stage_path
    mov x0, x16
    ARM_IMM w9, 87
    ARM_CALL arm_unlink
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_extra_temp
    str x10, [x16]
    ARM_ADDR x16, r4_cache_path
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 1
    ARM_CALL r2_open_path
    ARM_ADDR x16, r2_stat + 48
    ldr x2, [x16]
    ARM_ADDR x16, r4_envelope_length
    ldr x11, [x16]
    cmp x2, x11
    b.ne r4_metadata_length_error
    mov x0, x9
    ARM_IMM w9, 3
    ARM_CALL arm_close
    ARM_ADDR x16, r4_cache_path
    mov x0, x16
    ARM_CALL r2_hash_path
    mov x9, x21
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records + 204
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

r4_metadata_length_error:
    ARM_ADDR x0, r4_err_metadata_length
    b r3_fail

/* x0=local candidate index with nine validated lock bindings. Load exact
 * digest-named envelope<=64KiB, validate its complete native schema, compare
 * all bindings, then own its full dependency/profile declarations. No network
 * or authority/freshness claim. Metadata must have been retained by sync.
 * Stack 96 plus callees; all text remains process-owned for graph validation. */
r4_metadata_load:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x9, x21
    lsl x9, x9, #9
    ARM_ADDR x16, r3_records
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    ARM_CALL r4_metadata_path
    ARM_ADDR x16, r4_cache_path
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 1
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_envelope
    mov x1, x16
    ARM_IMM w2, R2_CONTROL
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r4_envelope_length
    str x9, [x16]
    ARM_ADDR x16, r4_cache_path
    mov x0, x16
    ARM_CALL r2_hash_path
    mov x16, x19
    ARM_IMM x17, 204
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
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
    ARM_ADDR x16, r2_envelope
    mov x0, x16
    ARM_ADDR x16, r4_envelope_length
    ldr x1, [x16]
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
    b.eq r3_lock_error
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
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 269
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_manifest_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 334
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_commit
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
    mov x16, x19
    ARM_IMM x17, 431
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_source_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r3_lock_error
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
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
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
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x23, [x16]
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
    cbz x3, .Lr4_arm_copy_1_end
.Lr4_arm_copy_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr4_arm_copy_1
.Lr4_arm_copy_1_end:
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
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr4_load_dependency:
    mov x10, x20
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr4_load_done
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
    b .Lr4_load_dependency
.Lr4_load_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

.section .rodata
r4_header: .asciz "# asm-lock-v4\n"
r4_header_line: .asciz "# asm-lock-v4"
r4_selection_word: .asciz "selection"
r4_root_feature_word: .asciz "root-feature"
r4_feature_word: .asciz "feature"
r4_opt_features: .asciz "--features"
r4_opt_no_defaults: .asciz "--no-default-features"
r4_zero: .asciz "0"
r4_one: .asciz "1"
r4_dash: .asciz "-"
r4_comma: .asciz ","
r4_metadata_root: .asciz ".asm/metadata"
r4_metadata_prefix: .asciz ".asm/metadata/"
r4_metadata_suffix: .asciz "/metadata"
r4_json_suffix: .asciz ".json"
r4_err_selection: .asciz "A requested root feature is not declared. Check [features] in asm.toml. Resolve again."
.section .data
.p2align 3
r4_format: .quad 4
.section .bss
.p2align 3
r4_option_bits: .skip 8
r4_steps: .skip 8
r4_envelope_length: .skip 8
r4_root_profile: .skip G4_PROFILE_SIZE
r4_profiles: .skip R3_CANDIDATES * G4_PROFILE_SIZE
r4_request_pointers: .skip 64 * 8
r4_request_input: .skip 2112
r4_request_text: .skip 2112
r4_cache_path: .skip 96
r4_stage_path: .skip 96

.section .rodata
r4_err_metadata_length: .asciz "Cached V2 metadata has the wrong length. Remove the damaged file in .asm/metadata. Run sync again."
