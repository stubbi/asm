/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/resolver_graph.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Bounded, newest-first native dependency graph resolution. No I/O is here.
 */
.global res_solve, res_conflict_name, res_conflict_range, res_conflict_reason
.section .text
/* Inputs: res_rows/count contain validated v1 artifact records. The root
 * metadata is rm_root_metadata; root feature requests/count and res_default
 * supply the root policy. res_load_candidate(a0=row) returns metadata in t0.
 * Outputs: t0=1 solved/0 conflict. res_nodes/count include root at index 0.
 * Node4096-byte layout: name0,row8,metadata16,features24,active dependencies32,
 * defaults40,request count48,request pointers56[64],processed features576,
 * private cycle state608,range count640,range pointers648[256]. At most128
 * packages,64 requested features/node,256 distinct incoming ranges/node,4096
 * decisions. Exhaustion branches to res_limit_error. Strings remain borrowed
 * and unchanged. The caller owns their storage and all cache/file operations.
 * Native internal ABI: arguments a0-a7, result t0, preserved s0-s5 and SP.
 * x8,t1-s7,s9 conditions are scratch. Local search/rebuild frames use112 bytes;
 * search depth is at most129. Cycle traversal uses48 bytes/node. RV_CALL
 * adds a temporary16-byte link frame. No system calls or external ABI calls.
 */
res_solve:
    RV_ADDR s6, res_assign_count
    mv s8, s6
    RV_STORE zero, 8
    RV_ADDR s6, res_decisions
    mv s8, s6
    RV_STORE zero, 8
    RV_ADDR s6, res_conflict_depth
    mv s8, s6
    RV_STORE zero, 8
    RV_ADDR s6, res_conflict_name
    mv s8, s6
    RV_STORE zero, 8
    RV_ADDR s6, res_conflict_range
    mv s8, s6
    RV_STORE zero, 8
    RV_ADDR s6, res_conflict_reason
    mv s8, s6
    RV_STORE zero, 8
    RV_JUMP res_search
res_search:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    RV_CALL res_rebuild
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph45
    RV_JUMP .Lrg_search_fail
.Lrv_cb_skip_resolver_graph45:
    li s2, 0
    RV_ADDR s0, res_nodes + 4096
    li s1, 1
.Lrg_unresolved:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_unresolved_done
    li s10, 16
    add s8, s0, s10
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_resolver_graph55
    RV_JUMP .Lrg_unresolved_next
.Lrv_cb_skip_resolver_graph55:
    mv s8, s2
    bnez s8, .Lrv_cb_skip_resolver_graph56
    RV_JUMP .Lrg_unresolved_choose
.Lrv_cb_skip_resolver_graph56:
    mv s8, s0
    RV_LOAD a0, 8
    mv a1, s2
    RV_CALL res_text_compare
    mv s8, t0
    li s10, 0
    RV_FLAGS sub, 32
    RV_BCOND ge, .Lrg_unresolved_next
.Lrg_unresolved_choose:
    mv s8, s0
    RV_LOAD s2, 8
.Lrg_unresolved_next:
    li s10, 1
    add s1, s1, s10
    li s10, 4096
    add s0, s0, s10
    RV_JUMP .Lrg_unresolved
.Lrg_unresolved_done:
    mv s8, s2
    beqz s8, .Lrv_cb_skip_resolver_graph69
    RV_JUMP .Lrg_choose_start
.Lrv_cb_skip_resolver_graph69:
    RV_CALL res_check_cycles
    RV_JUMP .Lrg_search_return
.Lrg_choose_start:
    li s3, 0
    RV_ADDR s6, res_assign_count
    mv s8, s6
    RV_LOAD s5, 8
.Lrg_candidate_round:
    /* Child branches overwrite derived nodes. Rebuild before every retry. */
    RV_CALL res_rebuild
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph79
    RV_JUMP .Lrg_search_fail
.Lrv_cb_skip_resolver_graph79:
    mv a0, s2
    RV_CALL res_find_node
    mv s1, t0
    li s4, 0
    RV_ADDR s0, res_rows
    mv s8, sp
    RV_STORE zero, 8
.Lrg_candidate_scan:
    mv s8, sp
    RV_LOAD t0, 8
    RV_ADDR s6, res_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t0
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_candidate_selected
    mv s8, s0
    RV_LOAD a0, 8
    mv a1, s2
    RV_CALL streq
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph95
    RV_JUMP .Lrg_candidate_next
.Lrv_cb_skip_resolver_graph95:
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_ADDR a1, registry_host
    RV_CALL streq
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph99
    RV_JUMP .Lrg_candidate_next
.Lrv_cb_skip_resolver_graph99:
    li s10, 24
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_ADDR a1, registry_source_kind
    RV_CALL streq
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph103
    RV_JUMP .Lrg_candidate_next
.Lrv_cb_skip_resolver_graph103:
    mv s8, s3
    bnez s8, .Lrv_cb_skip_resolver_graph104
    RV_JUMP .Lrg_candidate_upper_ok
.Lrv_cb_skip_resolver_graph104:
    li s10, 8
    add s8, s0, s10
    RV_LOAD a0, 8
    mv a1, s3
    RV_CALL registry_version_compare
    mv s8, t0
    li s10, 0
    RV_FLAGS sub, 32
    RV_BCOND ge, .Lrg_candidate_next
.Lrg_candidate_upper_ok:
    mv s8, s4
    bnez s8, .Lrv_cb_skip_resolver_graph111
    RV_JUMP .Lrg_candidate_ranges
.Lrv_cb_skip_resolver_graph111:
    li s10, 8
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 8
    add s8, s4, s10
    RV_LOAD a1, 8
    RV_CALL registry_version_compare
    mv s8, t0
    li s10, 0
    RV_FLAGS sub, 32
    RV_BCOND le, .Lrg_candidate_next
.Lrg_candidate_ranges:
    mv a0, s1
    mv a1, s0
    RV_CALL res_row_matches
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph121
    RV_JUMP .Lrg_candidate_next
.Lrv_cb_skip_resolver_graph121:
    mv s4, s0
.Lrg_candidate_next:
    mv s8, sp
    RV_LOAD t1, 8
    li s10, 1
    add t1, t1, s10
    mv s8, sp
    RV_STORE t1, 8
    li s10, 64
    add s0, s0, s10
    RV_JUMP .Lrg_candidate_scan
.Lrg_candidate_selected:
    mv s8, s4
    bnez s8, .Lrv_cb_skip_resolver_graph130
    RV_JUMP .Lrg_no_candidate
.Lrv_cb_skip_resolver_graph130:
    RV_ADDR s6, res_decisions
    mv s8, s6
    RV_LOAD t1, 8
    li s10, 1
    add t1, t1, s10
    mv s8, s6
    RV_STORE t1, 8
    mv s8, t1
    li s10, 4096
    RV_FLAGS sub, 64
    RV_BCOND hi, res_limit_error
    mv a0, s4
    RV_CALL res_load_candidate
    mv a2, t0
    mv s10, s5
    slli s10, s10, 1
    add t1, s5, s10
    slli t1, t1, 3
    RV_ADDR a0, res_assignments
    mv s10, t1
    add a0, a0, s10
    mv s8, a0
    RV_STORE s2, 8
    li s10, 8
    add s8, a0, s10
    RV_STORE s4, 8
    li s10, 16
    add s8, a0, s10
    RV_STORE a2, 8
    li s10, 1
    add t0, s5, s10
    mv s8, t0
    li s10, 128
    RV_FLAGS sub, 64
    RV_BCOND hi, res_limit_error
    RV_ADDR s6, res_assign_count
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL res_search
    mv s8, t0
    beqz s8, .Lrv_cb_skip_resolver_graph153
    RV_JUMP .Lrg_search_return
.Lrv_cb_skip_resolver_graph153:
    RV_ADDR s6, res_assign_count
    mv s8, s6
    RV_STORE s5, 8
    li s10, 8
    add s8, s4, s10
    RV_LOAD s3, 8
    RV_JUMP .Lrg_candidate_round
.Lrg_no_candidate:
    mv a0, s2
    li a1, 0
    li s10, 640
    add s8, s1, s10
    RV_LOAD t1, 8
    mv s8, t1
    bnez s8, .Lrv_cb_skip_resolver_graph162
    RV_JUMP .Lrg_no_candidate_report
.Lrv_cb_skip_resolver_graph162:
    li s10, 648
    add s8, s1, s10
    RV_LOAD a1, 8
.Lrg_no_candidate_report:
    RV_ADDR a2, res_reason_version
    RV_CALL res_set_conflict
.Lrg_search_fail:
    li t0, 0
.Lrg_search_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Derive requirements from the root and current assignment prefix. Clear all
 * nodes between branches so abandoned defaults/features cannot leak.
 * t0=1 stable compatible graph/0 conflict. Local frame112 bytes. */
res_rebuild:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    RV_ADDR a0, res_nodes
    RV_IMM a3, 129*4096/8, 64
.Lrg_clear_node:
    mv s8, a0
    RV_STORE zero, 8
    li s10, 8
    add a0, a0, s10
    mv s8, a3
    li s10, 1
    RV_FLAGS sub, 64
    mv a3, s11
    RV_BCOND ne, .Lrg_clear_node
    RV_ADDR s6, res_node_count
    li t1, 1
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s0, res_nodes
    RV_ADDR t0, res_root_name
    mv s8, s0
    RV_STORE t0, 8
    RV_ADDR t0, rm_root_metadata
    li s10, 16
    add s8, s0, s10
    RV_STORE t0, 8
    RV_ADDR s6, res_default
    mv s8, s6
    RV_LOAD t0, 8
    li s10, 40
    add s8, s0, s10
    RV_STORE t0, 8
    li s1, 0
.Lrg_root_request:
    RV_ADDR s6, res_root_request_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_propagate_start
    RV_ADDR t0, res_root_requests
    mv s10, s1
    slli s10, s10, 3
    add s8, t0, s10
    RV_LOAD a1, 8
    mv a0, s0
    RV_CALL res_add_request
    li s10, 1
    add s1, s1, s10
    RV_JUMP .Lrg_root_request
.Lrg_propagate_start:
    RV_ADDR s6, res_changed
    mv s8, s6
    RV_STORE zero, 8
    li s1, 0
    RV_ADDR s0, res_nodes
.Lrg_propagate_node:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_propagate_done
    li s10, 16
    add s8, s0, s10
    RV_LOAD s2, 8
    mv s8, s2
    bnez s8, .Lrv_cb_skip_resolver_graph230
    RV_JUMP .Lrg_propagate_next
.Lrv_cb_skip_resolver_graph230:
    li s10, 40
    add s8, s0, s10
    RV_LOAD t1, 8
    mv s8, t1
    bnez s8, .Lrv_cb_skip_resolver_graph232
    RV_JUMP .Lrg_requests
.Lrv_cb_skip_resolver_graph232:
    mv a0, s2
    RV_ADDR a1, res_default_feature
    RV_CALL res_meta_feature
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph236
    RV_JUMP .Lrg_requests
.Lrv_cb_skip_resolver_graph236:
    li t1, 1
    sll t1, t1, a2
    li s10, 24
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s8, t2
    mv s10, t1
    RV_FLAGS and, 64
    mv s10, t1
    or t2, t2, s10
    li s10, 24
    add s8, s0, s10
    RV_STORE t2, 8
    RV_BCOND ne, .Lrg_requests
    RV_ADDR s6, res_changed
    li t1, 1
    mv s8, s6
    RV_STORE t1, 8
.Lrg_requests:
    li s3, 0
.Lrg_request:
    li s10, 48
    add s8, s0, s10
    RV_LOAD t1, 8
    mv s8, s3
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_feature_expand_start
    mv a0, s2
    li s10, 56
    add t1, s0, s10
    mv s10, s3
    slli s10, s10, 3
    add s8, t1, s10
    RV_LOAD a1, 8
    RV_CALL res_meta_feature
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph257
    RV_JUMP .Lrg_unknown_feature
.Lrv_cb_skip_resolver_graph257:
    mv s10, s2
    sub t0, t0, s10
    RV_IMM t1, RM_FEATURES, 64
    mv s10, t1
    sub t0, t0, s10
    RV_IMM t1, RM_STRIDE, 64
    beqz t1, .Lrv_div_zero_resolver_graph262
    divu t0, t0, t1
    j .Lrv_div_done_resolver_graph262
.Lrv_div_zero_resolver_graph262:
    li t0, 0
.Lrv_div_done_resolver_graph262:
    li t1, 1
    sll t1, t1, t0
    li s10, 24
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s8, t2
    mv s10, t1
    RV_FLAGS and, 64
    mv s10, t1
    or t2, t2, s10
    li s10, 24
    add s8, s0, s10
    RV_STORE t2, 8
    RV_BCOND ne, .Lrg_request_next
    RV_ADDR s6, res_changed
    li t1, 1
    mv s8, s6
    RV_STORE t1, 8
.Lrg_request_next:
    li s10, 1
    add s3, s3, s10
    RV_JUMP .Lrg_request
.Lrg_feature_expand_start:
    li s3, 0
.Lrg_feature_expand:
    li s10, 16
    add s8, s2, s10
    RV_LOAD t1, 8
    mv s8, s3
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_nonoptional_start
    li t1, 1
    sll t1, t1, s3
    li s10, 24
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s8, t2
    mv s10, t1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrg_feature_next
    li s10, 576
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s8, t2
    mv s10, t1
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrg_feature_next
    mv s10, t1
    or t2, t2, s10
    li s10, 576
    add s8, s0, s10
    RV_STORE t2, 8
    RV_IMM t1, RM_STRIDE, 64
    mv s10, t1
    mul s4, s3, s10
    mv s10, s4
    add s4, s2, s10
    RV_IMM t1, RM_FEATURES, 64
    mv s10, t1
    add s4, s4, s10
    li s5, 0
.Lrg_feature_member:
    li s10, 8
    add s8, s4, s10
    RV_LOAD t1, 8
    mv s8, s5
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_feature_next
    li s10, 16
    add t1, s4, s10
    mv s10, s5
    slli s10, s10, 3
    add s8, t1, s10
    RV_LOAD a1, 8
    mv a0, s0
    RV_CALL res_expand_member
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph306
    RV_JUMP .Lrg_rebuild_bad
.Lrv_cb_skip_resolver_graph306:
    li s10, 1
    add s5, s5, s10
    RV_JUMP .Lrg_feature_member
.Lrg_feature_next:
    li s10, 1
    add s3, s3, s10
    RV_JUMP .Lrg_feature_expand
.Lrg_nonoptional_start:
    li s3, 0
.Lrg_nonoptional:
    li s10, 8
    add s8, s2, s10
    RV_LOAD t1, 8
    mv s8, s3
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_edges_start
    RV_IMM t1, RM_STRIDE, 64
    mv s10, t1
    mul t0, s3, s10
    mv s10, t0
    add t1, s2, s10
    li s10, RM_DEPS + 16
    add s8, t1, s10
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_resolver_graph322
    RV_JUMP .Lrg_nonoptional_next
.Lrv_cb_skip_resolver_graph322:
    li t1, 1
    sll t1, t1, s3
    li s10, 32
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s10, t1
    or t2, t2, s10
    li s10, 32
    add s8, s0, s10
    RV_STORE t2, 8
.Lrg_nonoptional_next:
    li s10, 1
    add s3, s3, s10
    RV_JUMP .Lrg_nonoptional
.Lrg_edges_start:
    li s3, 0
.Lrg_edge:
    li s10, 8
    add s8, s2, s10
    RV_LOAD t1, 8
    mv s8, s3
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_propagate_next
    li t1, 1
    sll t1, t1, s3
    li s10, 32
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s8, t2
    mv s10, t1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrg_edge_next
    RV_IMM t1, RM_STRIDE, 64
    mv s10, t1
    mul s4, s3, s10
    mv s10, s4
    add s4, s2, s10
    li s10, RM_DEPS
    add s4, s4, s10
    mv s8, s4
    RV_LOAD a0, 8
    RV_CALL res_get_node
    mv s5, t0
    mv a0, s5
    li s10, 8
    add s8, s4, s10
    RV_LOAD a1, 8
    RV_CALL res_add_range
    li s10, 24
    add s8, s4, s10
    RV_LOAD t1, 8
    mv s8, t1
    bnez s8, .Lrv_cb_skip_resolver_graph353
    RV_JUMP .Lrg_edge_requests
.Lrv_cb_skip_resolver_graph353:
    li s10, 40
    add s8, s5, s10
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_resolver_graph355
    RV_JUMP .Lrg_edge_requests
.Lrv_cb_skip_resolver_graph355:
    li t1, 1
    li s10, 40
    add s8, s5, s10
    RV_STORE t1, 8
    RV_ADDR s6, res_changed
    mv s8, s6
    RV_STORE t1, 8
.Lrg_edge_requests:
    mv s8, sp
    RV_STORE zero, 8
.Lrg_edge_request:
    mv s8, sp
    RV_LOAD t0, 8
    li s10, 32
    add s8, s4, s10
    RV_LOAD t1, 8
    mv s8, t0
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_edge_next
    mv a0, s5
    li s10, 40
    add t1, s4, s10
    mv s10, t0
    slli s10, s10, 3
    add s8, t1, s10
    RV_LOAD a1, 8
    RV_CALL res_add_request
    mv s8, sp
    RV_LOAD t1, 8
    li s10, 1
    add t1, t1, s10
    mv s8, sp
    RV_STORE t1, 8
    RV_JUMP .Lrg_edge_request
.Lrg_edge_next:
    li s10, 1
    add s3, s3, s10
    RV_JUMP .Lrg_edge
.Lrg_propagate_next:
    li s10, 1
    add s1, s1, s10
    li s10, 4096
    add s0, s0, s10
    RV_JUMP .Lrg_propagate_node
.Lrg_propagate_done:
    RV_ADDR s6, res_changed
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    beqz s8, .Lrv_cb_skip_resolver_graph385
    RV_JUMP .Lrg_propagate_start
.Lrv_cb_skip_resolver_graph385:
    RV_ADDR s0, res_nodes + 4096
    li s1, 1
.Lrg_validate_assigned:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_rebuild_good
    li s10, 8
    add s8, s0, s10
    RV_LOAD a1, 8
    mv s8, a1
    bnez s8, .Lrv_cb_skip_resolver_graph394
    RV_JUMP .Lrg_validate_next
.Lrv_cb_skip_resolver_graph394:
    mv a0, s0
    RV_CALL res_row_matches
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph397
    RV_JUMP .Lrg_rebuild_bad
.Lrv_cb_skip_resolver_graph397:
.Lrg_validate_next:
    li s10, 1
    add s1, s1, s10
    li s10, 4096
    add s0, s0, s10
    RV_JUMP .Lrg_validate_assigned
.Lrg_unknown_feature:
    mv s8, s0
    RV_LOAD a0, 8
    li s10, 56
    add t1, s0, s10
    mv s10, s3
    slli s10, s10, 3
    add s8, t1, s10
    RV_LOAD a1, 8
    RV_ADDR a2, res_reason_feature
    RV_CALL res_set_conflict
.Lrg_rebuild_bad:
    li t0, 0
    RV_JUMP .Lrg_rebuild_return
.Lrg_rebuild_good:
    li t0, 1
.Lrg_rebuild_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=node,a1=row. t0=1 if the version meets every accumulated range.
 * Preserves s0-s5; local frame48 bytes. No input mutation. */
res_row_matches:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    mv s1, a1
    li s2, 0
.Lrg_match_range:
    li s10, 640
    add s8, s0, s10
    RV_LOAD t1, 8
    mv s8, s2
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_match_good
    li s10, 8
    add s8, s1, s10
    RV_LOAD a0, 8
    li s10, 648
    add t1, s0, s10
    mv s10, s2
    slli s10, s10, 3
    add s8, t1, s10
    RV_LOAD a1, 8
    RV_CALL rm_range_matches
    mv s8, t0
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lrg_match_bad
    li s10, 1
    add s2, s2, s10
    RV_JUMP .Lrg_match_range
.Lrg_match_bad:
    /* Rejecting an unassigned index candidate is not a failed requirement. */
    li s10, 8
    add s8, s0, s10
    RV_LOAD t1, 8
    mv s8, t1
    bnez s8, .Lrv_cb_skip_resolver_graph447
    RV_JUMP .Lrg_match_no_report
.Lrv_cb_skip_resolver_graph447:
    mv s8, s0
    RV_LOAD a0, 8
    li s10, 648
    add t1, s0, s10
    mv s10, s2
    slli s10, s10, 3
    add s8, t1, s10
    RV_LOAD a1, 8
    RV_ADDR a2, res_reason_version
    RV_CALL res_set_conflict
.Lrg_match_no_report:
    li t0, 0
    RV_JUMP .Lrg_match_return
.Lrg_match_good:
    li t0, 1
.Lrg_match_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=node,a1=feature member. t0=1/0. Parser checked local references.
 * May create a child and add a request. Owns256-byte text scratch. The member
 * and metadata strings remain borrowed. Preserves s0-s5; local frame48. */
res_expand_member:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    RV_ADDR s6, res_expand_original
    mv s8, s6
    RV_STORE a1, 8
    RV_ADDR a0, res_member
    RV_CALL copy_string
    RV_ADDR s1, res_member
    mv s8, s1
    RV_LOAD t1, 4
    RV_IMM t2, 0x3a706564, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrg_expand_optional
    mv a0, s1
    li s2, 0
.Lrg_expand_slash:
    mv s8, a0
    RV_LOAD t0, 1
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolver_graph485
    RV_JUMP .Lrg_expand_classify
.Lrv_cb_skip_resolver_graph485:
    mv s8, t0
    li s10, '/'
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrg_expand_char
    mv s2, a0
.Lrg_expand_char:
    li s10, 1
    add a0, a0, s10
    RV_JUMP .Lrg_expand_slash
.Lrg_expand_classify:
    mv s8, s2
    beqz s8, .Lrv_cb_skip_resolver_graph493
    RV_JUMP .Lrg_expand_external
.Lrv_cb_skip_resolver_graph493:
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    mv a1, s1
    RV_CALL res_meta_feature
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph497
    RV_JUMP .Lrg_expand_bad
.Lrv_cb_skip_resolver_graph497:
    mv s8, t0
    RV_LOAD a1, 8
    mv a0, s0
    RV_CALL res_add_request
    RV_JUMP .Lrg_expand_good
.Lrg_expand_external:
    mv s8, s2
    RV_STORE zero, 1
    li s10, 1
    add s2, s2, s10
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    mv a1, s1
    RV_CALL res_meta_dep
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph508
    RV_JUMP .Lrg_expand_bad
.Lrv_cb_skip_resolver_graph508:
    mv s1, t0
    li t1, 1
    sll t1, t1, a2
    li s10, 32
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s10, t1
    or t2, t2, s10
    li s10, 32
    add s8, s0, s10
    RV_STORE t2, 8
    mv s8, s1
    RV_LOAD a0, 8
    RV_CALL res_get_node
    mv s0, t0
    /* Requests must point into immutable metadata, never shared scratch. */
    mv a0, s2
    RV_CALL strlen
    mv s1, t0
    RV_ADDR s6, res_expand_original
    mv s8, s6
    RV_LOAD a1, 8
    mv a0, a1
    RV_CALL strlen
    RV_ADDR s6, res_expand_original
    mv s8, s6
    RV_LOAD a1, 8
    mv s10, t0
    add a1, a1, s10
    mv s10, s1
    sub a1, a1, s10
    mv a0, s0
    RV_CALL res_add_request
    RV_JUMP .Lrg_expand_good
.Lrg_expand_optional:
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 4
    add a1, s1, s10
    RV_CALL res_meta_dep
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph537
    RV_JUMP .Lrg_expand_bad
.Lrv_cb_skip_resolver_graph537:
    li t1, 1
    sll t1, t1, a2
    li s10, 32
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s10, t1
    or t2, t2, s10
    li s10, 32
    add s8, s0, s10
    RV_STORE t2, 8
.Lrg_expand_good:
    li t0, 1
    RV_JUMP .Lrg_expand_return
.Lrg_expand_bad:
    li t0, 0
.Lrg_expand_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=metadata,a1=name. t0=record/0,a2=index on success.
 * Lookup borrows strings; preserves s0-s5; local frame80 bytes. */
res_meta_feature:
    li s10, 16
    add s8, a0, s10
    RV_LOAD a2, 8
    RV_IMM t1, RM_FEATURES, 64
    mv s10, t1
    add a0, a0, s10
    RV_JUMP res_meta_find
res_meta_dep:
    li s10, 8
    add s8, a0, s10
    RV_LOAD a2, 8
    li s10, RM_DEPS
    add a0, a0, s10
res_meta_find:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    li s10, 16
    sub sp, sp, s10
    mv s0, a0
    mv s1, a1
    mv s2, a2
    li s3, 0
.Lrg_meta_loop:
    mv s8, s3
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_meta_absent
    mv s8, s0
    RV_LOAD a0, 8
    mv a1, s1
    RV_CALL streq
    mv s8, t0
    beqz s8, .Lrv_cb_skip_resolver_graph580
    RV_JUMP .Lrg_meta_found
.Lrv_cb_skip_resolver_graph580:
    li s10, 1
    add s3, s3, s10
    li s10, RM_STRIDE
    add s0, s0, s10
    RV_JUMP .Lrg_meta_loop
.Lrg_meta_absent:
    li t0, 0
    RV_JUMP .Lrg_meta_return
.Lrg_meta_found:
    mv t0, s0
    mv a2, s3
.Lrg_meta_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=name. t0=node/0. Read-only lookup; retains no argument pointers.
 * Preserves s0-s5; local frame48 bytes. */
res_find_node:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    RV_ADDR s1, res_nodes + 4096
    li s2, 1
.Lrg_find_node:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s2
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_find_none
    mv a0, s0
    mv s8, s1
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    beqz s8, .Lrv_cb_skip_resolver_graph615
    RV_JUMP .Lrg_find_yes
.Lrv_cb_skip_resolver_graph615:
    li s10, 1
    add s2, s2, s10
    li s10, 4096
    add s1, s1, s10
    RV_JUMP .Lrg_find_node
.Lrg_find_none:
    li t0, 0
    RV_JUMP .Lrg_find_return
.Lrg_find_yes:
    mv t0, s1
.Lrg_find_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=persistent package name. t0=existing/new zeroed node with its selected
 * assignment attached. New nodes mark propagation changed. Local frame48. */
res_get_node:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    RV_CALL res_find_node
    mv s8, t0
    beqz s8, .Lrv_cb_skip_resolver_graph638
    RV_JUMP .Lrg_get_return
.Lrv_cb_skip_resolver_graph638:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t0, 8
    mv s8, t0
    li s10, 129
    RV_FLAGS sub, 64
    RV_BCOND hs, res_limit_error
    slli t0, t0, 12
    RV_ADDR s1, res_nodes
    mv s10, t0
    add s1, s1, s10
    mv s8, s1
    RV_STORE s0, 8
    mv s8, s6
    RV_LOAD t1, 8
    li s10, 1
    add t1, t1, s10
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, res_changed
    li t1, 1
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s2, res_assignments
    li s0, 0
.Lrg_attach:
    RV_ADDR s6, res_assign_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s0
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_get_new
    mv s8, s1
    RV_LOAD a0, 8
    mv s8, s2
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    beqz s8, .Lrv_cb_skip_resolver_graph663
    RV_JUMP .Lrg_attach_found
.Lrv_cb_skip_resolver_graph663:
    li s10, 1
    add s0, s0, s10
    li s10, 24
    add s2, s2, s10
    RV_JUMP .Lrg_attach
.Lrg_attach_found:
    li s10, 8
    add s8, s2, s10
    RV_LOAD t0, 8
    li s10, 8
    add s8, s1, s10
    RV_STORE t0, 8
    li s10, 16
    add s8, s2, s10
    RV_LOAD t0, 8
    li s10, 16
    add s8, s1, s10
    RV_STORE t0, 8
.Lrg_get_new:
    mv t0, s1
.Lrg_get_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=node,a1=persistent request/range string. No return value. Deduplicate
 * exact text; bounded additions mark propagation changed. Local frame80. */
res_add_request:
    li s10, 48
    add a2, a0, s10
    li s10, 56
    add a3, a0, s10
    li a4, 64
    RV_JUMP res_add_fact
res_add_range:
    li s10, 640
    add a2, a0, s10
    li s10, 648
    add a3, a0, s10
    li a4, 256
res_add_fact:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    mv s0, a1
    mv s1, a2
    mv s2, a3
    mv s3, a4
    li s4, 0
.Lrg_fact_loop:
    mv s8, s1
    RV_LOAD t1, 8
    mv s8, s4
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_fact_add
    mv a0, s0
    mv s10, s4
    slli s10, s10, 3
    add s8, s2, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    beqz s8, .Lrv_cb_skip_resolver_graph709
    RV_JUMP .Lrg_fact_return
.Lrv_cb_skip_resolver_graph709:
    li s10, 1
    add s4, s4, s10
    RV_JUMP .Lrg_fact_loop
.Lrg_fact_add:
    mv s8, s4
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND hs, res_limit_error
    mv s10, s4
    slli s10, s10, 3
    add s8, s2, s10
    RV_STORE s0, 8
    mv s8, s1
    RV_LOAD t1, 8
    li s10, 1
    add t1, t1, s10
    mv s8, s1
    RV_STORE t1, 8
    RV_ADDR s6, res_changed
    li t1, 1
    mv s8, s6
    RV_STORE t1, 8
.Lrg_fact_return:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* t0=1 acyclic/0 cycle. Traverse only active edges; unused optional edges do
 * not create cycles. Local frame48 bytes plus recursive visit frames. */
res_check_cycles:
    RV_SAVE s0
    RV_SAVE s1
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s0, res_nodes
    li s1, 0
.Lrg_cycle_root:
    RV_ADDR s6, res_node_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_cycle_all_good
    mv a0, s0
    RV_CALL res_cycle_visit
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph745
    RV_JUMP .Lrg_cycle_all_return
.Lrv_cb_skip_resolver_graph745:
    li s10, 4096
    add s0, s0, s10
    li s10, 1
    add s1, s1, s10
    RV_JUMP .Lrg_cycle_root
.Lrg_cycle_all_good:
    li t0, 1
.Lrg_cycle_all_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=node,t0=1 acyclic/0 cycle. Cycle marks belong to res_nodes. Preserves
 * s0-s5; local frame48 bytes; at most129 recursive calls. */
res_cycle_visit:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    li s10, 608
    add s8, s0, s10
    RV_LOAD t1, 8
    mv s8, t1
    li s10, 2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrg_cycle_good
    mv s8, t1
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrg_cycle_bad
    li t1, 1
    li s10, 608
    add s8, s0, s10
    RV_STORE t1, 8
    li s10, 16
    add s8, s0, s10
    RV_LOAD s2, 8
    li s1, 0
.Lrg_cycle_edge:
    li s10, 8
    add s8, s2, s10
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrg_cycle_complete
    li t1, 1
    sll t1, t1, s1
    li s10, 32
    add s8, s0, s10
    RV_LOAD t2, 8
    mv s8, t2
    mv s10, t1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrg_cycle_next
    RV_IMM t1, RM_STRIDE, 64
    mv s10, t1
    mul t0, s1, s10
    mv s10, t0
    add t1, s2, s10
    li s10, RM_DEPS
    add s8, t1, s10
    RV_LOAD a0, 8
    RV_CALL res_find_node
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph786
    RV_JUMP .Lrg_cycle_bad
.Lrv_cb_skip_resolver_graph786:
    mv a0, t0
    RV_CALL res_cycle_visit
    mv s8, t0
    bnez s8, .Lrv_cb_skip_resolver_graph789
    RV_JUMP .Lrg_cycle_return
.Lrv_cb_skip_resolver_graph789:
.Lrg_cycle_next:
    li s10, 1
    add s1, s1, s10
    RV_JUMP .Lrg_cycle_edge
.Lrg_cycle_complete:
    li t1, 2
    li s10, 608
    add s8, s0, s10
    RV_STORE t1, 8
.Lrg_cycle_good:
    li t0, 1
    RV_JUMP .Lrg_cycle_return
.Lrg_cycle_bad:
    mv s8, s0
    RV_LOAD a0, 8
    li a1, 0
    RV_ADDR a2, res_reason_cycle
    RV_CALL res_set_conflict
    li t0, 0
.Lrg_cycle_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=name,a1=range/feature or0,a2=reason. Preserve the deepest observed failed
 * requirement across backtracking. Equal-depth failures replace old context.
 * t0,t1,s6,s9 conditions change. No stack use; strings remain caller-owned. */
res_set_conflict:
    RV_ADDR s6, res_assign_count
    mv s8, s6
    RV_LOAD t0, 8
    RV_ADDR s6, res_conflict_depth
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t0
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lrg_conflict_keep
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, res_conflict_name
    mv s8, s6
    RV_STORE a0, 8
    RV_ADDR s6, res_conflict_range
    mv s8, s6
    RV_STORE a1, 8
    RV_ADDR s6, res_conflict_reason
    mv s8, s6
    RV_STORE a2, 8
.Lrg_conflict_keep:
    ret
/* a0/a1=NUL ASCII strings. t0=signed lexical difference. No mutation, stack
 * use, or retained pointers. a2,a3 and ordinary scratch registers change. */
res_text_compare:
    li a3, 0
.Lrg_text:
    mv s10, a3
    add s8, a0, s10
    RV_LOAD t0, 1
    mv s10, a3
    add s8, a1, s10
    RV_LOAD a2, 1
    mv s8, t0
    mv s10, a2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_BCOND ne, .Lrg_text_done
    mv s8, a2
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolver_graph840
    RV_JUMP .Lrg_text_done
.Lrv_cb_skip_resolver_graph840:
    li s10, 1
    add a3, a3, s10
    RV_JUMP .Lrg_text
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
.section .note.GNU-stack,""
