/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Bounded, newest-first native dependency graph resolution. No I/O is here.
 */
.global res_solve, res_conflict_name, res_conflict_range, res_conflict_reason
.section .text
/* Inputs: res_rows/count contain validated v1 artifact records. The root
 * metadata is rm_root_metadata; root feature requests/count and res_default
 * supply the root policy. res_load_candidate(x0=row) returns metadata in x9.
 * Outputs: x9=1 solved/0 conflict. res_nodes/count include root at index 0.
 * Node4096-byte layout: name0,row8,metadata16,features24,active dependencies32,
 * defaults40,request count48,request pointers56[64],processed features576,
 * private cycle state608,range count640,range pointers648[256]. At most128
 * packages,64 requested features/node,256 distinct incoming ranges/node,4096
 * decisions. Exhaustion branches to res_limit_error. Strings remain borrowed
 * and unchanged. The caller owns their storage and all cache/file operations.
 * Native internal ABI: arguments x0-x7, result x9, preserved x19-x24 and SP.
 * x8,x10-x17,NZCV are scratch. Local search/rebuild frames use112 bytes;
 * search depth is at most129. Cycle traversal uses48 bytes/node. ARM_CALL
 * adds a temporary16-byte link frame. No system calls or external ABI calls.
 */
res_solve:
    ARM_ADDR x16, res_assign_count
    str xzr, [x16]
    ARM_ADDR x16, res_decisions
    str xzr, [x16]
    ARM_ADDR x16, res_conflict_depth
    str xzr, [x16]
    ARM_ADDR x16, res_conflict_name
    str xzr, [x16]
    ARM_ADDR x16, res_conflict_range
    str xzr, [x16]
    ARM_ADDR x16, res_conflict_reason
    str xzr, [x16]
    b res_search
res_search:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_CALL res_rebuild
    cbz x9, .Lrg_search_fail
    mov x21, #0
    ARM_ADDR x19, res_nodes + 4096
    mov x20, #1
.Lrg_unresolved:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lrg_unresolved_done
    ldr x10, [x19, #16]
    cbnz x10, .Lrg_unresolved_next
    cbz x21, .Lrg_unresolved_choose
    ldr x0, [x19]
    mov x1, x21
    ARM_CALL res_text_compare
    cmp w9, #0
    b.ge .Lrg_unresolved_next
.Lrg_unresolved_choose:
    ldr x21, [x19]
.Lrg_unresolved_next:
    add x20, x20, #1
    add x19, x19, #4096
    b .Lrg_unresolved
.Lrg_unresolved_done:
    cbnz x21, .Lrg_choose_start
    ARM_CALL res_check_cycles
    b .Lrg_search_return
.Lrg_choose_start:
    mov x22, #0 /* Last attempted version. */
    ARM_ADDR x16, res_assign_count
    ldr x24, [x16]
.Lrg_candidate_round:
    /* Child branches overwrite derived nodes. Rebuild before every retry. */
    ARM_CALL res_rebuild
    cbz x9, .Lrg_search_fail
    mov x0, x21
    ARM_CALL res_find_node
    mov x20, x9
    mov x23, #0 /* Highest remaining eligible artifact row. */
    ARM_ADDR x19, res_rows
    str xzr, [sp]
.Lrg_candidate_scan:
    ldr x9, [sp]
    ARM_ADDR x16, res_row_count
    ldr x10, [x16]
    cmp x9, x10
    b.hs .Lrg_candidate_selected
    ldr x0, [x19]
    mov x1, x21
    ARM_CALL streq
    cbz x9, .Lrg_candidate_next
    ldr x0, [x19, #16]
    ARM_ADDR x1, registry_host
    ARM_CALL streq
    cbz x9, .Lrg_candidate_next
    ldr x0, [x19, #24]
    ARM_ADDR x1, registry_source_kind
    ARM_CALL streq
    cbz x9, .Lrg_candidate_next
    cbz x22, .Lrg_candidate_upper_ok
    ldr x0, [x19, #8]
    mov x1, x22
    ARM_CALL registry_version_compare
    cmp w9, #0
    b.ge .Lrg_candidate_next
.Lrg_candidate_upper_ok:
    cbz x23, .Lrg_candidate_ranges
    ldr x0, [x19, #8]
    ldr x1, [x23, #8]
    ARM_CALL registry_version_compare
    cmp w9, #0
    b.le .Lrg_candidate_next
.Lrg_candidate_ranges:
    mov x0, x20
    mov x1, x19
    ARM_CALL res_row_matches
    cbz x9, .Lrg_candidate_next
    mov x23, x19
.Lrg_candidate_next:
    ldr x10, [sp]
    add x10, x10, #1
    str x10, [sp]
    add x19, x19, #64
    b .Lrg_candidate_scan
.Lrg_candidate_selected:
    cbz x23, .Lrg_no_candidate
    ARM_ADDR x16, res_decisions
    ldr x10, [x16]
    add x10, x10, #1
    str x10, [x16]
    cmp x10, #4096
    b.hi res_limit_error
    mov x0, x23
    ARM_CALL res_load_candidate
    mov x2, x9
    add x10, x24, x24, lsl #1
    lsl x10, x10, #3
    ARM_ADDR x0, res_assignments
    add x0, x0, x10
    str x21, [x0]
    str x23, [x0, #8]
    str x2, [x0, #16]
    add x9, x24, #1
    cmp x9, #128
    b.hi res_limit_error
    ARM_ADDR x16, res_assign_count
    str x9, [x16]
    ARM_CALL res_search
    cbnz x9, .Lrg_search_return
    ARM_ADDR x16, res_assign_count
    str x24, [x16]
    ldr x22, [x23, #8]
    b .Lrg_candidate_round
.Lrg_no_candidate:
    mov x0, x21
    mov x1, #0
    ldr x10, [x20, #640]
    cbz x10, .Lrg_no_candidate_report
    ldr x1, [x20, #648]
.Lrg_no_candidate_report:
    ARM_ADDR x2, res_reason_version
    ARM_CALL res_set_conflict
.Lrg_search_fail:
    mov x9, #0
.Lrg_search_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Derive requirements from the root and current assignment prefix. Clear all
 * nodes between branches so abandoned defaults/features cannot leak.
 * x9=1 stable compatible graph/0 conflict. Local frame112 bytes. */
res_rebuild:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_ADDR x0, res_nodes
    ARM_IMM x3, 129*4096/8
.Lrg_clear_node:
    str xzr, [x0], #8
    subs x3, x3, #1
    b.ne .Lrg_clear_node
    ARM_ADDR x16, res_node_count
    mov x10, #1
    str x10, [x16]
    ARM_ADDR x19, res_nodes
    ARM_ADDR x9, res_root_name
    str x9, [x19]
    ARM_ADDR x9, rm_root_metadata
    str x9, [x19, #16]
    ARM_ADDR x16, res_default
    ldr x9, [x16]
    str x9, [x19, #40]
    mov x20, #0
.Lrg_root_request:
    ARM_ADDR x16, res_root_request_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lrg_propagate_start
    ARM_ADDR x9, res_root_requests
    ldr x1, [x9, x20, lsl #3]
    mov x0, x19
    ARM_CALL res_add_request
    add x20, x20, #1
    b .Lrg_root_request
.Lrg_propagate_start:
    ARM_ADDR x16, res_changed
    str xzr, [x16]
    mov x20, #0
    ARM_ADDR x19, res_nodes
.Lrg_propagate_node:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lrg_propagate_done
    ldr x21, [x19, #16]
    cbz x21, .Lrg_propagate_next
    ldr x10, [x19, #40]
    cbz x10, .Lrg_requests
    mov x0, x21
    ARM_ADDR x1, res_default_feature
    ARM_CALL res_meta_feature
    cbz x9, .Lrg_requests
    mov x10, #1
    lsl x10, x10, x2
    ldr x11, [x19, #24]
    tst x11, x10
    orr x11, x11, x10
    str x11, [x19, #24]
    b.ne .Lrg_requests
    ARM_ADDR x16, res_changed
    mov x10, #1
    str x10, [x16]
.Lrg_requests:
    mov x22, #0
.Lrg_request:
    ldr x10, [x19, #48]
    cmp x22, x10
    b.hs .Lrg_feature_expand_start
    mov x0, x21
    add x10, x19, #56
    ldr x1, [x10, x22, lsl #3]
    ARM_CALL res_meta_feature
    cbz x9, .Lrg_unknown_feature
    sub x9, x9, x21
    ARM_IMM x10, RM_FEATURES
    sub x9, x9, x10
    ARM_IMM x10, RM_STRIDE
    udiv x9, x9, x10
    mov x10, #1
    lsl x10, x10, x9
    ldr x11, [x19, #24]
    tst x11, x10
    orr x11, x11, x10
    str x11, [x19, #24]
    b.ne .Lrg_request_next
    ARM_ADDR x16, res_changed
    mov x10, #1
    str x10, [x16]
.Lrg_request_next:
    add x22, x22, #1
    b .Lrg_request
.Lrg_feature_expand_start:
    mov x22, #0
.Lrg_feature_expand:
    ldr x10, [x21, #16]
    cmp x22, x10
    b.hs .Lrg_nonoptional_start
    mov x10, #1
    lsl x10, x10, x22
    ldr x11, [x19, #24]
    tst x11, x10
    b.eq .Lrg_feature_next
    ldr x11, [x19, #576]
    tst x11, x10
    b.ne .Lrg_feature_next
    orr x11, x11, x10
    str x11, [x19, #576]
    ARM_IMM x10, RM_STRIDE
    mul x23, x22, x10
    add x23, x21, x23
    ARM_IMM x10, RM_FEATURES
    add x23, x23, x10
    mov x24, #0
.Lrg_feature_member:
    ldr x10, [x23, #8]
    cmp x24, x10
    b.hs .Lrg_feature_next
    add x10, x23, #16
    ldr x1, [x10, x24, lsl #3]
    mov x0, x19
    ARM_CALL res_expand_member
    cbz x9, .Lrg_rebuild_bad
    add x24, x24, #1
    b .Lrg_feature_member
.Lrg_feature_next:
    add x22, x22, #1
    b .Lrg_feature_expand
.Lrg_nonoptional_start:
    mov x22, #0
.Lrg_nonoptional:
    ldr x10, [x21, #8]
    cmp x22, x10
    b.hs .Lrg_edges_start
    ARM_IMM x10, RM_STRIDE
    mul x9, x22, x10
    add x10, x21, x9
    ldr x10, [x10, #RM_DEPS + 16]
    cbnz x10, .Lrg_nonoptional_next
    mov x10, #1
    lsl x10, x10, x22
    ldr x11, [x19, #32]
    orr x11, x11, x10
    str x11, [x19, #32]
.Lrg_nonoptional_next:
    add x22, x22, #1
    b .Lrg_nonoptional
.Lrg_edges_start:
    mov x22, #0
.Lrg_edge:
    ldr x10, [x21, #8]
    cmp x22, x10
    b.hs .Lrg_propagate_next
    mov x10, #1
    lsl x10, x10, x22
    ldr x11, [x19, #32]
    tst x11, x10
    b.eq .Lrg_edge_next
    ARM_IMM x10, RM_STRIDE
    mul x23, x22, x10
    add x23, x21, x23
    add x23, x23, #RM_DEPS
    ldr x0, [x23]
    ARM_CALL res_get_node
    mov x24, x9
    mov x0, x24
    ldr x1, [x23, #8]
    ARM_CALL res_add_range
    ldr x10, [x23, #24]
    cbz x10, .Lrg_edge_requests
    ldr x10, [x24, #40]
    cbnz x10, .Lrg_edge_requests
    mov x10, #1
    str x10, [x24, #40]
    ARM_ADDR x16, res_changed
    str x10, [x16]
.Lrg_edge_requests:
    str xzr, [sp]
.Lrg_edge_request:
    ldr x9, [sp]
    ldr x10, [x23, #32]
    cmp x9, x10
    b.hs .Lrg_edge_next
    mov x0, x24
    add x10, x23, #40
    ldr x1, [x10, x9, lsl #3]
    ARM_CALL res_add_request
    ldr x10, [sp]
    add x10, x10, #1
    str x10, [sp]
    b .Lrg_edge_request
.Lrg_edge_next:
    add x22, x22, #1
    b .Lrg_edge
.Lrg_propagate_next:
    add x20, x20, #1
    add x19, x19, #4096
    b .Lrg_propagate_node
.Lrg_propagate_done:
    ARM_ADDR x16, res_changed
    ldr x10, [x16]
    cbnz x10, .Lrg_propagate_start
    ARM_ADDR x19, res_nodes + 4096
    mov x20, #1
.Lrg_validate_assigned:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lrg_rebuild_good
    ldr x1, [x19, #8]
    cbz x1, .Lrg_validate_next
    mov x0, x19
    ARM_CALL res_row_matches
    cbz x9, .Lrg_rebuild_bad
.Lrg_validate_next:
    add x20, x20, #1
    add x19, x19, #4096
    b .Lrg_validate_assigned
.Lrg_unknown_feature:
    ldr x0, [x19]
    add x10, x19, #56
    ldr x1, [x10, x22, lsl #3]
    ARM_ADDR x2, res_reason_feature
    ARM_CALL res_set_conflict
.Lrg_rebuild_bad:
    mov x9, #0
    b .Lrg_rebuild_return
.Lrg_rebuild_good:
    mov x9, #1
.Lrg_rebuild_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=node,x1=row. x9=1 if the version meets every accumulated range.
 * Preserves x19-x24; local frame48 bytes. No input mutation. */
res_row_matches:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    mov x20, x1
    mov x21, #0
.Lrg_match_range:
    ldr x10, [x19, #640]
    cmp x21, x10
    b.hs .Lrg_match_good
    ldr x0, [x20, #8]
    add x10, x19, #648
    ldr x1, [x10, x21, lsl #3]
    ARM_CALL rm_range_matches
    cmp x9, #1
    b.ne .Lrg_match_bad
    add x21, x21, #1
    b .Lrg_match_range
.Lrg_match_bad:
    /* Rejecting an unassigned index candidate is not a failed requirement. */
    ldr x10, [x19, #8]
    cbz x10, .Lrg_match_no_report
    ldr x0, [x19]
    add x10, x19, #648
    ldr x1, [x10, x21, lsl #3]
    ARM_ADDR x2, res_reason_version
    ARM_CALL res_set_conflict
.Lrg_match_no_report:
    mov x9, #0
    b .Lrg_match_return
.Lrg_match_good:
    mov x9, #1
.Lrg_match_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=node,x1=feature member. x9=1/0. Parser checked local references.
 * May create a child and add a request. Owns256-byte text scratch. The member
 * and metadata strings remain borrowed. Preserves x19-x24; local frame48. */
res_expand_member:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    ARM_ADDR x16, res_expand_original
    str x1, [x16]
    ARM_ADDR x0, res_member
    ARM_CALL copy_string
    ARM_ADDR x20, res_member
    ldr w10, [x20]
    ARM_IMM w11, 0x3a706564
    cmp w10, w11
    b.eq .Lrg_expand_optional
    mov x0, x20
    mov x21, #0
.Lrg_expand_slash:
    ldrb w9, [x0]
    cbz w9, .Lrg_expand_classify
    cmp w9, #'/'
    b.ne .Lrg_expand_char
    mov x21, x0
.Lrg_expand_char:
    add x0, x0, #1
    b .Lrg_expand_slash
.Lrg_expand_classify:
    cbnz x21, .Lrg_expand_external
    ldr x0, [x19, #16]
    mov x1, x20
    ARM_CALL res_meta_feature
    cbz x9, .Lrg_expand_bad
    ldr x1, [x9]
    mov x0, x19
    ARM_CALL res_add_request
    b .Lrg_expand_good
.Lrg_expand_external:
    strb wzr, [x21]
    add x21, x21, #1
    ldr x0, [x19, #16]
    mov x1, x20
    ARM_CALL res_meta_dep
    cbz x9, .Lrg_expand_bad
    mov x20, x9
    mov x10, #1
    lsl x10, x10, x2
    ldr x11, [x19, #32]
    orr x11, x11, x10
    str x11, [x19, #32]
    ldr x0, [x20]
    ARM_CALL res_get_node
    mov x19, x9
    /* Requests must point into immutable metadata, never shared scratch. */
    mov x0, x21
    ARM_CALL strlen
    mov x20, x9
    ARM_ADDR x16, res_expand_original
    ldr x1, [x16]
    mov x0, x1
    ARM_CALL strlen
    ARM_ADDR x16, res_expand_original
    ldr x1, [x16]
    add x1, x1, x9
    sub x1, x1, x20
    mov x0, x19
    ARM_CALL res_add_request
    b .Lrg_expand_good
.Lrg_expand_optional:
    ldr x0, [x19, #16]
    add x1, x20, #4
    ARM_CALL res_meta_dep
    cbz x9, .Lrg_expand_bad
    mov x10, #1
    lsl x10, x10, x2
    ldr x11, [x19, #32]
    orr x11, x11, x10
    str x11, [x19, #32]
.Lrg_expand_good:
    mov x9, #1
    b .Lrg_expand_return
.Lrg_expand_bad:
    mov x9, #0
.Lrg_expand_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=metadata,x1=name. x9=record/0,x2=index on success.
 * Lookup borrows strings; preserves x19-x24; local frame80 bytes. */
res_meta_feature:
    ldr x2, [x0, #16]
    ARM_IMM x10, RM_FEATURES
    add x0, x0, x10
    b res_meta_find
res_meta_dep:
    ldr x2, [x0, #8]
    add x0, x0, #RM_DEPS
res_meta_find:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    sub sp, sp, #16
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, #0
.Lrg_meta_loop:
    cmp x22, x21
    b.hs .Lrg_meta_absent
    ldr x0, [x19]
    mov x1, x20
    ARM_CALL streq
    cbnz x9, .Lrg_meta_found
    add x22, x22, #1
    add x19, x19, #RM_STRIDE
    b .Lrg_meta_loop
.Lrg_meta_absent:
    mov x9, #0
    b .Lrg_meta_return
.Lrg_meta_found:
    mov x9, x19
    mov x2, x22
.Lrg_meta_return:
    add sp, sp, #16
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=name. x9=node/0. Read-only lookup; retains no argument pointers.
 * Preserves x19-x24; local frame48 bytes. */
res_find_node:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    ARM_ADDR x20, res_nodes + 4096
    mov x21, #1
.Lrg_find_node:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    cmp x21, x10
    b.hs .Lrg_find_none
    mov x0, x19
    ldr x1, [x20]
    ARM_CALL streq
    cbnz x9, .Lrg_find_yes
    add x21, x21, #1
    add x20, x20, #4096
    b .Lrg_find_node
.Lrg_find_none:
    mov x9, #0
    b .Lrg_find_return
.Lrg_find_yes:
    mov x9, x20
.Lrg_find_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=persistent package name. x9=existing/new zeroed node with its selected
 * assignment attached. New nodes mark propagation changed. Local frame48. */
res_get_node:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    ARM_CALL res_find_node
    cbnz x9, .Lrg_get_return
    ARM_ADDR x16, res_node_count
    ldr x9, [x16]
    cmp x9, #129
    b.hs res_limit_error
    lsl x9, x9, #12
    ARM_ADDR x20, res_nodes
    add x20, x20, x9
    str x19, [x20]
    ldr x10, [x16]
    add x10, x10, #1
    str x10, [x16]
    ARM_ADDR x16, res_changed
    mov x10, #1
    str x10, [x16]
    ARM_ADDR x21, res_assignments
    mov x19, #0
.Lrg_attach:
    ARM_ADDR x16, res_assign_count
    ldr x10, [x16]
    cmp x19, x10
    b.hs .Lrg_get_new
    ldr x0, [x20]
    ldr x1, [x21]
    ARM_CALL streq
    cbnz x9, .Lrg_attach_found
    add x19, x19, #1
    add x21, x21, #24
    b .Lrg_attach
.Lrg_attach_found:
    ldr x9, [x21, #8]
    str x9, [x20, #8]
    ldr x9, [x21, #16]
    str x9, [x20, #16]
.Lrg_get_new:
    mov x9, x20
.Lrg_get_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=node,x1=persistent request/range string. No return value. Deduplicate
 * exact text; bounded additions mark propagation changed. Local frame80. */
res_add_request:
    add x2, x0, #48
    add x3, x0, #56
    mov x4, #64
    b res_add_fact
res_add_range:
    add x2, x0, #640
    add x3, x0, #648
    mov x4, #256
res_add_fact:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x19, x1
    mov x20, x2
    mov x21, x3
    mov x22, x4
    mov x23, #0
.Lrg_fact_loop:
    ldr x10, [x20]
    cmp x23, x10
    b.hs .Lrg_fact_add
    mov x0, x19
    ldr x1, [x21, x23, lsl #3]
    ARM_CALL streq
    cbnz x9, .Lrg_fact_return
    add x23, x23, #1
    b .Lrg_fact_loop
.Lrg_fact_add:
    cmp x23, x22
    b.hs res_limit_error
    str x19, [x21, x23, lsl #3]
    ldr x10, [x20]
    add x10, x10, #1
    str x10, [x20]
    ARM_ADDR x16, res_changed
    mov x10, #1
    str x10, [x16]
.Lrg_fact_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x9=1 acyclic/0 cycle. Traverse only active edges; unused optional edges do
 * not create cycles. Local frame48 bytes plus recursive visit frames. */
res_check_cycles:
    ARM_SAVE x19
    ARM_SAVE x20
    sub sp, sp, #16
    ARM_ADDR x19, res_nodes
    mov x20, #0
.Lrg_cycle_root:
    ARM_ADDR x16, res_node_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lrg_cycle_all_good
    mov x0, x19
    ARM_CALL res_cycle_visit
    cbz x9, .Lrg_cycle_all_return
    add x19, x19, #4096
    add x20, x20, #1
    b .Lrg_cycle_root
.Lrg_cycle_all_good:
    mov x9, #1
.Lrg_cycle_all_return:
    add sp, sp, #16
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x0=node,x9=1 acyclic/0 cycle. Cycle marks belong to res_nodes. Preserves
 * x19-x24; local frame48 bytes; at most129 recursive calls. */
res_cycle_visit:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    ldr x10, [x19, #608]
    cmp x10, #2
    b.eq .Lrg_cycle_good
    cmp x10, #1
    b.eq .Lrg_cycle_bad
    mov x10, #1
    str x10, [x19, #608]
    ldr x21, [x19, #16]
    mov x20, #0
.Lrg_cycle_edge:
    ldr x10, [x21, #8]
    cmp x20, x10
    b.hs .Lrg_cycle_complete
    mov x10, #1
    lsl x10, x10, x20
    ldr x11, [x19, #32]
    tst x11, x10
    b.eq .Lrg_cycle_next
    ARM_IMM x10, RM_STRIDE
    mul x9, x20, x10
    add x10, x21, x9
    ldr x0, [x10, #RM_DEPS]
    ARM_CALL res_find_node
    cbz x9, .Lrg_cycle_bad
    mov x0, x9
    ARM_CALL res_cycle_visit
    cbz x9, .Lrg_cycle_return
.Lrg_cycle_next:
    add x20, x20, #1
    b .Lrg_cycle_edge
.Lrg_cycle_complete:
    mov x10, #2
    str x10, [x19, #608]
.Lrg_cycle_good:
    mov x9, #1
    b .Lrg_cycle_return
.Lrg_cycle_bad:
    ldr x0, [x19]
    mov x1, #0
    ARM_ADDR x2, res_reason_cycle
    ARM_CALL res_set_conflict
    mov x9, #0
.Lrg_cycle_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=name,x1=range/feature or0,x2=reason. Preserve the deepest observed failed
 * requirement across backtracking. Equal-depth failures replace old context.
 * x9,x10,x16,NZCV change. No stack use; strings remain caller-owned. */
res_set_conflict:
    ARM_ADDR x16, res_assign_count
    ldr x9, [x16]
    ARM_ADDR x16, res_conflict_depth
    ldr x10, [x16]
    cmp x9, x10
    b.lo .Lrg_conflict_keep
    str x9, [x16]
    ARM_ADDR x16, res_conflict_name
    str x0, [x16]
    ARM_ADDR x16, res_conflict_range
    str x1, [x16]
    ARM_ADDR x16, res_conflict_reason
    str x2, [x16]
.Lrg_conflict_keep:
    ret

/* x0/x1=NUL ASCII strings. w9=signed lexical difference. No mutation, stack
 * use, or retained pointers. x2,x3 and ordinary scratch registers change. */
res_text_compare:
    mov x3, #0
.Lrg_text:
    ldrb w9, [x0, x3]
    ldrb w2, [x1, x3]
    subs w9, w9, w2
    b.ne .Lrg_text_done
    cbz w2, .Lrg_text_done
    add x3, x3, #1
    b .Lrg_text
.Lrg_text_done:
    ret

.section .rodata
res_root_name: .asciz "."
res_default_feature: .asciz "default"
res_reason_version: .asciz "no version satisfies the active dependency constraints"
res_reason_feature: .asciz "the selected version does not define a requested feature"
res_reason_cycle: .asciz "the active dependency graph contains a cycle"
.section .bss
.balign 8
res_assign_count: .skip 8
res_decisions: .skip 8
res_changed: .skip 8
res_conflict_depth: .skip 8
res_conflict_name: .skip 8
res_conflict_range: .skip 8
res_conflict_reason: .skip 8
res_expand_original: .skip 8
res_assignments: .skip 128*24
res_member: .skip 256
.section .note.GNU-stack,"",@progbits
