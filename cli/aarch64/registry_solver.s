/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Bounded, target-specific dependency solving. No I/O or package execution.
 * Native AArch64 arguments x0/x1/x2/x3; result x9. Returning routines preserve
 * x19-x24. ARM_CALL preserves LR; every stack slot has 16-byte alignment.
 * x0-x7, x8/x10-x17, flags and parser scratch change.
 * Process-owned serial state; pointers remain owned by the caller throughout.
 * One selected version per name. Chronological backtracking, not PubGrub.
 */
.equ G3_CANDIDATES, 256
.equ G3_ROOTS, 64
.equ G3_DEPS, 64
.equ G3_RECORD, 40
.equ G4_FACT_BYTES, 4376
.global g3_requirement, g3_solve
.global g3_candidates, g3_candidate_count, g3_roots, g3_root_count
.global g3_solution, g3_steps, g3_limit
.global g4_profiles, g4_root_profile, g4_requests, g4_request_count, g4_defaults
.global g4_active_features, g4_active_deps, g4_root_features, g4_root_deps
.global g4_lazy, g4_known_names, g4_known_count, g4_missing_name
.section .text

/* x0=NUL version, x1=owned 24-byte numeric tuple. x9=end pointer or zero.
 * Three canonical decimal components, each <=2147483647. Stack: none.
 * At most ten digits per component are read before overflow rejection. */
g3_parse_version:
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lg3_version_bad
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg3_component:
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
    mov w11, w5
    eor w5, w5, w11
    tst w5, w5
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_digit
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w9, [x16]
    ARM_IMM w11, 48
    subs w9, w9, w11
    mov w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.ls .Lg3_version_bad
.Lg3_digit:
    mov x16, x0
    ldrb w9, [x16]
    ARM_IMM w11, 48
    subs w9, w9, w11
    mov w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.hi .Lg3_component_end
    mov x10, x4
    ARM_IMM x11, 10
    smulh x12, x10, x11
    mul x4, x10, x11
    asr x13, x4, #63
    cmp x12, x13
    mov x11, x9
    adds x4, x4, x11
    mov x10, x4
    ARM_IMM x11, 2147483647
    cmp x10, x11
    b.hi .Lg3_version_bad
    ARM_IMM w11, 1
    adds w5, w5, w11
    ARM_IMM x11, 1
    adds x0, x0, x11
    b .Lg3_digit
.Lg3_component_end:
    mov w10, w5
    mov w11, w5
    tst w10, w11
    b.eq .Lg3_version_bad
    mov x16, x1
    add x16, x16, x3, lsl #3
    str x4, [x16]
    mov w10, w3
    ARM_IMM w11, 2
    cmp w10, w11
    b.eq .Lg3_version_end
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_version_bad
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lg3_component
.Lg3_version_end:
    mov x9, x0
    ret
.Lg3_version_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret

/* x0/x1=three-qword tuples. w9=-1/0/1 numeric order. Stack:none. */
g3_compare_numbers:
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg3_numbers_loop:
    mov x16, x0
    add x16, x16, x3, lsl #3
    ldr x9, [x16]
    mov x10, x9
    mov x16, x1
    add x16, x16, x3, lsl #3
    ldr x11, [x16]
    cmp x10, x11
    b.lo .Lg3_numbers_less
    b.hi .Lg3_numbers_greater
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 3
    cmp w10, w11
    b.lo .Lg3_numbers_loop
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
.Lg3_numbers_less:
    ARM_IMM w9, -1
    ret
.Lg3_numbers_greater:
    ARM_IMM w9, 1
    ret

/* x0=requirement<=128ASCII, x1=canonical version. x9=1 match,0 mismatch,
 * -1 invalid. Exact/=/>/>=/</<=/^/~ terms, <=8 comma intersections; '*' alone.
 * No whitespace, prerelease or build suffix. Every term is validated even
 * after an earlier mismatch. Static tuples24 each; Stack 80 plus callees. */
g3_requirement:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lg3_requirement_bad
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg3_requirement_length:
    mov x16, x21
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_requirement_version
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 128
    cmp w10, w11
    b.ls .Lg3_requirement_length
    b .Lg3_requirement_bad
.Lg3_requirement_version:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq .Lg3_requirement_bad
    mov x0, x1
    ARM_ADDR x16, g3_version_numbers
    mov x1, x16
    ARM_CALL g3_parse_version
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg3_requirement_bad
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_requirement_bad
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 42
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_requirement_terms
    mov x16, x21
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_requirement_bad
    ARM_IMM w9, 1
    b .Lg3_requirement_return
.Lg3_requirement_terms:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_IMM w24, 1
.Lg3_requirement_term:
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov w10, w19
    ARM_IMM w11, 8
    cmp w10, w11
    b.hi .Lg3_requirement_bad
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    mov x16, x21
    ldrb w9, [x16]
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_operator_one
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 62
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_operator_greater
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 60
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_operator_less
    ARM_IMM w22, 5
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 94
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_operator_one
    ARM_IMM w22, 6
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_operator_one
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    b .Lg3_requirement_parse
.Lg3_operator_greater:
    ARM_IMM w22, 1
    b .Lg3_operator_compare
.Lg3_operator_less:
    ARM_IMM w22, 3
.Lg3_operator_compare:
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_requirement_parse
    ARM_IMM w11, 1
    adds w22, w22, w11
.Lg3_operator_one:
    ARM_IMM x11, 1
    adds x21, x21, x11
.Lg3_requirement_parse:
    mov x0, x21
    ARM_ADDR x16, g3_base_numbers
    mov x1, x16
    ARM_CALL g3_parse_version
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg3_requirement_bad
    mov x21, x9
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_requirement_compare
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 44
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_requirement_bad
.Lg3_requirement_compare:
    ARM_ADDR x16, g3_version_numbers
    mov x0, x16
    ARM_ADDR x16, g3_base_numbers
    mov x1, x16
    ARM_CALL g3_compare_numbers
    mov w10, w22
    mov w11, w22
    tst w10, w11
    b.eq .Lg3_match_exact
    mov w10, w22
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq .Lg3_match_greater
    mov w10, w22
    ARM_IMM w11, 2
    cmp w10, w11
    b.eq .Lg3_match_ge
    mov w10, w22
    ARM_IMM w11, 3
    cmp w10, w11
    b.eq .Lg3_match_less
    mov w10, w22
    ARM_IMM w11, 4
    cmp w10, w11
    b.eq .Lg3_match_le
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.mi .Lg3_match_false
    ARM_ADDR x16, g3_version_numbers
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, g3_base_numbers
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg3_match_false
    mov w10, w22
    ARM_IMM w11, 6
    cmp w10, w11
    b.eq .Lg3_match_minor
    ARM_ADDR x16, g3_base_numbers
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lg3_match_true
.Lg3_match_minor:
    ARM_ADDR x16, g3_version_numbers + 8
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, g3_base_numbers + 8
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg3_match_false
    mov w10, w22
    ARM_IMM w11, 6
    cmp w10, w11
    b.eq .Lg3_match_true
    ARM_ADDR x16, g3_base_numbers + 8
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lg3_match_true
    ARM_ADDR x16, g3_version_numbers + 16
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, g3_base_numbers + 16
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg3_match_false
    b .Lg3_match_true
.Lg3_match_exact:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    cset w9, eq
    b .Lg3_match_boolean
.Lg3_match_greater:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    cset w9, gt
    b .Lg3_match_boolean
.Lg3_match_ge:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    cset w9, ge
    b .Lg3_match_boolean
.Lg3_match_less:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    cset w9, lt
    b .Lg3_match_boolean
.Lg3_match_le:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    cset w9, le
.Lg3_match_boolean:
    mov w9, w9
    mov w11, w9
    and w24, w24, w11
    tst w24, w24
    b .Lg3_requirement_next
.Lg3_match_false:
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
    b .Lg3_requirement_next
.Lg3_match_true:
.Lg3_requirement_next:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_requirement_result
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lg3_requirement_term
.Lg3_requirement_result:
    mov w9, w24
    b .Lg3_requirement_return
.Lg3_requirement_bad:
    ARM_IMM x9, -1
.Lg3_requirement_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=name. w9=1 bounded nonempty printable ASCII,0 invalid. The registry
 * parser additionally validates package grammar. <=104 bytes; stack:none. */
g3_name:
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lg3_name_bad
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg3_name_loop:
    mov x16, x0
    add x16, x16, x3
    ldrb w9, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_name_end
    mov w10, w9
    ARM_IMM w11, 33
    cmp w10, w11
    b.lo .Lg3_name_bad
    mov w10, w9
    ARM_IMM w11, 126
    cmp w10, w11
    b.hi .Lg3_name_bad
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 104
    cmp w10, w11
    b.ls .Lg3_name_loop
.Lg3_name_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
.Lg3_name_end:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov w10, w3
    mov w11, w3
    tst w10, w11
    cset w9, ne
    ret

/* x0/x1=validated bounded strings. w9=-1/0/1 lexical order. Stack:none. */
g3_string_compare:
    mov x16, x0
    ldrb w9, [x16]
    mov x16, x1
    ldrb w2, [x16]
    mov w10, w9
    mov w11, w2
    cmp w10, w11
    b.lo .Lg3_numbers_less
    b.hi .Lg3_numbers_greater
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_string_equal
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM x11, 1
    adds x1, x1, x11
    b g3_string_compare
.Lg3_string_equal:
    ret

/* Count one propagation, constraint, or search operation. w9=0 or2 limit.
 * Each operation scans at most256 candidates. Does not wrap. Stack:none. */
g3_tick:
    ARM_ADDR x16, g3_steps
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, g3_limit
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_tick_limit
    ARM_ADDR x16, g3_steps
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g3_steps
    str x10, [x16]
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
.Lg3_tick_limit:
    ARM_IMM w9, 2
    ret

/* x0/x1=candidate indexes<256. w9=sort order: name ascending, numeric
 * version descending. Equal identities are invalid. Static tuples; Stack 48. */
g3_candidate_compare:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x10, x0
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x0, x10, x11
    asr x13, x0, #63
    cmp x12, x13
    mov x10, x1
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x1, x10, x11
    asr x13, x1, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x21, x16
    mov x16, x21
    add x16, x16, x1
    mov x22, x16
    mov x11, x0
    adds x21, x21, x11
    mov x16, x21
    ldr x0, [x16]
    mov x16, x22
    ldr x1, [x16]
    ARM_CALL g3_string_compare
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_candidate_compare_return
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, g3_version_numbers
    mov x1, x16
    ARM_CALL g3_parse_version
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, g3_base_numbers
    mov x1, x16
    ARM_CALL g3_parse_version
    ARM_ADDR x16, g3_base_numbers
    mov x0, x16
    ARM_ADDR x16, g3_version_numbers
    mov x1, x16
    ARM_CALL g3_compare_numbers
.Lg3_candidate_compare_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=name. x9=selected candidate index, or -1. Reads solution<=256bytes.
 * Only one selected candidate per name is permitted. Stack 48. */
g3_selected_for_name:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg3_selected_loop:
    mov x10, x19
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_selected_none
    ARM_ADDR x16, g3_solution
    mov x9, x16
    mov x16, x9
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_selected_next
    mov x10, x19
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x22, x16
    mov x16, x22
    add x16, x16, x9
    ldr x0, [x16]
    mov x1, x21
    ARM_CALL g3_string_compare
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_selected_found
.Lg3_selected_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg3_selected_loop
.Lg3_selected_none:
    ARM_IMM x9, -1
    b .Lg3_selected_return
.Lg3_selected_found:
    mov x9, x19
.Lg3_selected_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=candidate index<256. Queue a selected reached candidate once until
 * processed. Dirty bits permit repeated feature growth without queue overflow.
 * Registers x9/x2 change; Stack 0; static dirty256/count8. */
g4_schedule:
    ARM_ADDR x16, g4_dirty
    mov x2, x16
    mov x16, x2
    add x16, x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_schedule_done
    ARM_IMM w10, 1
    mov x16, x2
    add x16, x16, x0
    strb w10, [x16]
    ARM_ADDR x16, g4_dirty_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g4_dirty_count
    str x10, [x16]
.Lg4_schedule_done:
    ret

/* x0=name. w9=1found0known-absent2budget4needs-discovery. Mark all versions
 * required; schedule newly reached selected versions. Missing-name pointer is
 * borrowed, never copied. Lazy mode asks the IO owner to restart the solver.
 * Stack 48; scans<=256 candidates and<=256 declared known names. */
g3_mark:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_mark_return
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
.Lg3_mark_loop:
    mov x10, x19
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_mark_done
    mov x10, x19
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ldr x0, [x16]
    mov x1, x21
    ARM_CALL g3_string_compare
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_mark_next
    ARM_IMM w22, 1
    ARM_ADDR x16, g3_required
    mov x2, x16
    mov x16, x2
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg3_mark_next
    ARM_IMM w10, 1
    mov x16, x2
    add x16, x16, x19
    strb w10, [x16]
    ARM_ADDR x16, g3_solution
    mov x2, x16
    mov x16, x2
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_mark_next
    mov x0, x19
    ARM_CALL g4_schedule
.Lg3_mark_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg3_mark_loop
.Lg3_mark_done:
    mov w9, w22
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_mark_return
    ARM_ADDR x16, g4_lazy
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg3_mark_return
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg3_mark_known:
    mov x10, x19
    ARM_ADDR x16, g4_known_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_mark_discover
    ARM_ADDR x16, g4_known_names
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    ldr x0, [x16]
    mov x1, x21
    ARM_CALL g3_string_compare
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_mark_return
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg3_mark_known
.Lg3_mark_discover:
    ARM_ADDR x16, g4_missing_name
    str x21, [x16]
    ARM_IMM w9, 4
.Lg3_mark_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=name,x1=requirement. w9=0 matched or unresolved,1 conflict,2 budget,
 * 3 invalid. Only active requirements call this routine. Stack 48. */
g3_check:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x1
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_check_return
    mov x0, x21
    ARM_CALL g3_selected_for_name
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_check_ok
    mov x10, x9
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    mov x0, x22
    ARM_CALL g3_requirement
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_check_invalid
    b.eq .Lg3_check_conflict
.Lg3_check_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg3_check_return
.Lg3_check_invalid:
    ARM_IMM w9, 3
    b .Lg3_check_return
.Lg3_check_conflict:
    ARM_IMM w9, 1
.Lg3_check_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=validated profile orNULL,x2=depcount. w9=0charged2exhausted.
 * Charge each declared option, feature, and list member before search.
 * Counts were validated<=64. Stack 48; callee registers preserved; no I/O. */
g4_budget_profile:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x2
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lg4_budget_good
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x19, [x16]
    mov x11, x22
    adds x19, x19, x11
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_budget_options:
    mov x10, x3
    mov x11, x22
    cmp x10, x11
    b.hs .Lg4_budget_definitions_begin
    mov x10, x3
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ldr x2, [x16]
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    adds x19, x19, x11
    ARM_IMM x11, 1
    adds x3, x3, x11
    b .Lg4_budget_options
.Lg4_budget_definitions_begin:
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_budget_definitions:
    mov x10, x3
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_budget_tick
    mov x10, x3
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x2, [x16]
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    adds x19, x19, x11
    ARM_IMM x11, 1
    adds x3, x3, x11
    b .Lg4_budget_definitions
.Lg4_budget_tick:
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_budget_return
    ARM_IMM x11, 1
    subs x19, x19, x11
    b.ne .Lg4_budget_tick
.Lg4_budget_good:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lg4_budget_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=profile,x1=feature,x2=mask address. w9=0activated1unknown.
 * New candidate features schedule their selected owner for propagation.
 * Uses unsigned64 masks, including bit63. Stack 48; borrowed profile/strings. */
g4_activate:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x2
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg4_activate_missing
    mov x3, x9
    ARM_IMM w9, 1
    lslv x9, x9, x3
    mov x16, x21
    ldr x10, [x16]
    mov x11, x9
    tst x10, x11
    b.ne .Lg4_activate_ok
    mov x16, x21
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x21
    str x10, [x16]
    ARM_ADDR x16, g4_active_features
    mov x2, x16
    mov x0, x21
    mov x11, x2
    subs x0, x0, x11
    mov x10, x0
    ARM_IMM x11, G3_CANDIDATES * 8
    cmp x10, x11
    b.hs .Lg4_activate_ok
    lsr x0, x0, #3
    ARM_CALL g4_schedule
.Lg4_activate_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_activate_return
.Lg4_activate_missing:
    ARM_IMM w9, 1
.Lg4_activate_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=dependency pair16,x1=options24 orNULL(defaults only). w9=0okay,
 * 1conflict2budget3invalid4discovery. Only activated edges call this routine.
 * A missing requested child feature is a candidate conflict, never malformed.
 * Stack 96; schedule facts unite monotonically within one search branch. */
g4_apply_edge:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov x21, x0
    mov x22, x1
    mov x16, x21
    ldr x0, [x16]
    ARM_CALL g3_mark
    mov w10, w9
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lg4_edge_mark_result
    mov x16, x21
    ldr x0, [x16]
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL g3_check
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_edge_return
    mov x16, x21
    ldr x0, [x16]
    ARM_CALL g3_selected_for_name
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg4_edge_ok
    mov x23, x9
    ARM_ADDR x16, g4_active_features
    mov x2, x16
    mov x16, x2
    add x16, x16, x23, lsl #3
    mov x19, x16
    ARM_ADDR x16, g4_profiles
    mov x2, x16
    mov x16, x2
    add x16, x16, x23, lsl #3
    ldr x24, [x16]
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_edge_defaults
    mov x16, x22
    ldr x10, [x16]
    ARM_IMM x11, 2
    tst x10, x11
    b.eq .Lg4_edge_requests
.Lg4_edge_defaults:
    mov x0, x24
    ARM_ADDR x16, g4_default_name
    mov x1, x16
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg4_edge_requests
    mov x0, x24
    ARM_ADDR x16, g4_default_name
    mov x1, x16
    mov x2, x19
    ARM_CALL g4_activate
.Lg4_edge_requests:
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_edge_ok
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x9, [x16]
    mov x16, sp
    str x9, [x16]
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x9, [x16]
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
.Lg4_edge_request:
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_edge_ok
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_edge_return
    mov x0, x24
    mov x16, sp
    ldr x1, [x16]
    mov x2, x19
    ARM_CALL g4_activate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_edge_return
    mov x16, sp
    ldr x0, [x16]
    ARM_CALL g4_next
    mov x16, sp
    str x9, [x16]
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    subs x10, x10, x11
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    str x10, [x16]
    b .Lg4_edge_request
.Lg4_edge_mark_result:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_edge_return
    ARM_IMM w9, 1
    b .Lg4_edge_return
.Lg4_edge_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lg4_edge_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=profile orNULL,x1=deps16,x2=count,x3=feature-mask*,x4=dep-mask*.
 * w9=0okay1conflict2budget3invalid4discovery. Derive local-feature closure,
 * then apply exactly active edges. Forwarded child features activate their
 * edge even when optional. Input declarations stay immutable. Stack 128. */
g4_process_node:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #48
    mov x19, x0
    mov x21, x1
    mov x22, x2
    mov x23, x3
    mov x24, x4
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_node_mandatory:
    mov x10, x3
    mov x11, x22
    cmp x10, x11
    b.hs .Lg4_node_features_begin
    mov x10, x19
    mov x11, x19
    tst x10, x11
    b.eq .Lg4_node_enable
    mov x10, x3
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x19
    ldr x2, [x16]
    mov x16, x2
    add x16, x16, x9
    ldr x10, [x16]
    ARM_IMM x11, 1
    tst x10, x11
    b.ne .Lg4_node_mandatory_next
.Lg4_node_enable:
    ARM_IMM w9, 1
    lslv x9, x9, x3
    mov x16, x24
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x24
    str x10, [x16]
.Lg4_node_mandatory_next:
    ARM_IMM x11, 1
    adds x3, x3, x11
    b .Lg4_node_mandatory
.Lg4_node_features_begin:
    mov x10, x19
    mov x11, x19
    tst x10, x11
    b.eq .Lg4_node_edges_begin
.Lg4_node_feature_pass:
    ARM_IMM x10, 0
    mov x16, sp
    ARM_IMM x17, 24
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM x10, 0
    mov x16, sp
    str x10, [x16]
.Lg4_node_feature:
    mov x16, sp
    ldr x3, [x16]
    mov x10, x3
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_node_feature_pass_done
    ARM_IMM w9, 1
    lslv x9, x9, x3
    mov x16, x23
    ldr x10, [x16]
    mov x11, x9
    tst x10, x11
    b.eq .Lg4_node_feature_next
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_node_return
    mov x10, x3
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x2, [x16]
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x3, [x16]
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    str x3, [x16]
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x3, [x16]
    mov x16, sp
    ARM_IMM x17, 16
    add x16, x16, x17
    str x3, [x16]
.Lg4_node_member:
    mov x16, sp
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_node_feature_next
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_node_return
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x3, [x16]
    ARM_CALL g4_member
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.mi .Lg4_node_invalid
    b.eq .Lg4_node_local
    mov x16, sp
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    mov x16, sp
    ARM_IMM x17, 40
    add x16, x16, x17
    str x3, [x16]
    mov x3, x2
    ARM_IMM w9, 1
    lslv x9, x9, x3
    mov x16, x24
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x24
    str x10, [x16]
    mov x16, sp
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 2
    cmp x10, x11
    b.ne .Lg4_node_member_next
    mov x16, sp
    ARM_IMM x17, 40
    add x16, x16, x17
    ldr x9, [x16]
    ARM_ADDR x16, g4_forward_option + 8
    str x9, [x16]
    mov x10, x2
    ARM_IMM x11, 16
    smulh x12, x10, x11
    mul x0, x10, x11
    asr x13, x0, #63
    cmp x12, x13
    mov x11, x21
    adds x0, x0, x11
    ARM_ADDR x16, g4_forward_option
    mov x1, x16
    ARM_CALL g4_apply_edge
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_node_return
    b .Lg4_node_member_next
.Lg4_node_local:
    mov x3, x2
    ARM_IMM w9, 1
    lslv x9, x9, x3
    mov x16, x23
    ldr x10, [x16]
    mov x11, x9
    tst x10, x11
    b.ne .Lg4_node_member_next
    mov x16, x23
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x23
    str x10, [x16]
    ARM_IMM x10, 1
    mov x16, sp
    ARM_IMM x17, 24
    add x16, x16, x17
    str x10, [x16]
.Lg4_node_member_next:
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_CALL g4_next
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x16, sp
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    subs x10, x10, x11
    mov x16, sp
    ARM_IMM x17, 16
    add x16, x16, x17
    str x10, [x16]
    b .Lg4_node_member
.Lg4_node_feature_next:
    mov x16, sp
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    mov x16, sp
    str x10, [x16]
    b .Lg4_node_feature
.Lg4_node_feature_pass_done:
    mov x16, sp
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lg4_node_feature_pass
.Lg4_node_edges_begin:
    ARM_IMM x10, 0
    mov x16, sp
    ARM_IMM x17, 32
    add x16, x16, x17
    str x10, [x16]
.Lg4_node_edge:
    mov x16, sp
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x3, [x16]
    mov x10, x3
    mov x11, x22
    cmp x10, x11
    b.hs .Lg4_node_ok
    ARM_IMM w9, 1
    lslv x9, x9, x3
    mov x16, x24
    ldr x10, [x16]
    mov x11, x9
    tst x10, x11
    b.eq .Lg4_node_edge_next
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov x10, x19
    mov x11, x19
    tst x10, x11
    b.eq .Lg4_node_edge_apply
    mov x10, x3
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x19
    ldr x1, [x16]
    mov x11, x9
    adds x1, x1, x11
.Lg4_node_edge_apply:
    mov x10, x3
    ARM_IMM x11, 16
    smulh x12, x10, x11
    mul x0, x10, x11
    asr x13, x0, #63
    cmp x12, x13
    mov x11, x21
    adds x0, x0, x11
    ARM_CALL g4_apply_edge
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_node_return
.Lg4_node_edge_next:
    mov x16, sp
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    mov x16, sp
    ARM_IMM x17, 32
    add x16, x16, x17
    str x10, [x16]
    b .Lg4_node_edge
.Lg4_node_invalid:
    ARM_IMM w9, 3
    b .Lg4_node_return
.Lg4_node_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lg4_node_return:
    add sp, sp, #48
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Recompute every branch from roots, including all feature facts. Dirty
 * selected nodes are revisited when incoming features grow. Graph cycles
 * remain valid; local feature cycles were rejected before search. Stack 80
 * per search depth<=256; RAX0solution1unsat2budget3invalid4discovery. */
g3_search:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_search_return
    ARM_CALL g4_clear_facts
    ARM_ADDR x16, g4_requests
    ldr x21, [x16]
    ARM_ADDR x16, g4_request_count
    ldr x22, [x16]
.Lg4_search_root_requests:
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_search_root_default
    ARM_CALL g3_tick
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_search_return
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    mov x1, x21
    ARM_ADDR x16, g4_root_features
    mov x2, x16
    ARM_CALL g4_activate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_search_return
    mov x0, x21
    ARM_CALL g4_next
    mov x21, x9
    ARM_IMM x11, 1
    subs x22, x22, x11
    b .Lg4_search_root_requests
.Lg4_search_root_default:
    ARM_ADDR x16, g4_defaults
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_search_root
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    ARM_ADDR x16, g4_default_name
    mov x1, x16
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg4_search_root
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    ARM_ADDR x16, g4_default_name
    mov x1, x16
    ARM_ADDR x16, g4_root_features
    mov x2, x16
    ARM_CALL g4_activate
.Lg4_search_root:
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    ARM_ADDR x16, g3_roots
    mov x1, x16
    ARM_ADDR x16, g3_root_count
    ldr x2, [x16]
    ARM_ADDR x16, g4_root_features
    mov x3, x16
    ARM_ADDR x16, g4_root_deps
    mov x4, x16
    ARM_CALL g4_process_node
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_search_return
.Lg4_search_dirty:
    ARM_ADDR x16, g4_dirty_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg3_find_unresolved
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, g4_dirty
    mov x2, x16
.Lg4_search_dirty_find:
    mov x16, x2
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_search_dirty_found
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_search_dirty_find
.Lg4_search_dirty_found:
    ARM_IMM w10, 0
    mov x16, x2
    add x16, x16, x19
    strb w10, [x16]
    ARM_ADDR x16, g4_dirty_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    subs x10, x10, x11
    ARM_ADDR x16, g4_dirty_count
    str x10, [x16]
    ARM_ADDR x16, g4_profiles
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    ldr x0, [x16]
    mov x10, x19
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x1, [x16]
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x2, [x16]
    ARM_ADDR x16, g4_active_features
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    mov x3, x16
    ARM_ADDR x16, g4_active_deps
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    mov x4, x16
    ARM_CALL g4_process_node
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_search_return
    b .Lg4_search_dirty
.Lg3_find_unresolved:
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
.Lg3_unresolved_loop:
    mov x10, x22
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_search_success
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x22, lsl #3
    ldr x19, [x16]
    ARM_ADDR x16, g3_required
    mov x9, x16
    mov x16, x9
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg3_unresolved_next
    mov x10, x19
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ldr x23, [x16]
    mov x0, x23
    ARM_CALL g3_selected_for_name
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_choose_begin
.Lg3_unresolved_next:
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lg3_unresolved_loop
.Lg3_choose_begin:
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lg3_choose:
    mov x10, x24
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_search_unsat
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x24, lsl #3
    ldr x19, [x16]
    mov x10, x19
    ARM_IMM x11, G3_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_candidates
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x16, x21
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg3_choose_next
    mov x16, x21
    ldr x0, [x16]
    mov x1, x23
    ARM_CALL g3_string_compare
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_choose_next
    ARM_ADDR x16, g3_solution
    mov x9, x16
    ARM_IMM w10, 1
    mov x16, x9
    add x16, x16, x19
    strb w10, [x16]
    ARM_CALL g3_search
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_search_return
    ARM_ADDR x16, g3_solution
    mov x2, x16
    ARM_IMM w10, 0
    mov x16, x2
    add x16, x16, x19
    strb w10, [x16]
    mov w10, w9
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lg3_search_return
.Lg3_choose_next:
    ARM_IMM x11, 1
    adds x24, x24, x11
    b .Lg3_choose
.Lg3_search_success:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg3_search_return
.Lg3_search_unsat:
    ARM_IMM w9, 1
.Lg3_search_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Inputs: candidates<=256 records40 {name*,version*,deps*,dep_count,usable};
 * roots<=64 records16 {name*,requirement*}; deps<=64 records16 per candidate.
 * Optional g4 profiles carry feature definitions and per-edge options. Root
 * requests<=64 are NUL-separated; defaults is boolean. NULL profiles retain
 * mandatory/default behavior. Lazy mode yields4 for an unknown required name.
 * All strings/arrays must remain readable during the call. Limit<=100000.
 * Outputs: x9=0 solved,1 unsatisfiable,2 resource bound,3 malformed graph,
 * 4 needs discovery with a borrowed missing-name pointer.
 * solution[i]=1 for exactly the reachable graph on success, all zero on error.
 * Validates every supplied candidate, even inactive ones; rejects duplicates.
 * Sort scratch2048, reachability256, feature facts4376, dirty nodes256.
 * Recursion<=256*80 saved bytes plus bounded propagation routine frames. */
g3_solve:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, g3_solution
    mov x0, x16
    ARM_IMM w3, G3_CANDIDATES
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    cbz x3, .Lg3_arm_copy_1_end
.Lg3_arm_copy_1:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg3_arm_copy_1
.Lg3_arm_copy_1_end:
    ARM_IMM x10, 0
    ARM_ADDR x16, g3_steps
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_missing_name
    str x10, [x16]
    ARM_CALL g4_clear_facts
    ARM_ADDR x16, g3_candidate_count
    ldr x10, [x16]
    ARM_IMM x11, G3_CANDIDATES
    cmp x10, x11
    b.hi .Lg3_solve_limit
    ARM_ADDR x16, g3_root_count
    ldr x10, [x16]
    ARM_IMM x11, G3_ROOTS
    cmp x10, x11
    b.hi .Lg3_solve_limit
    ARM_ADDR x16, g3_limit
    ldr x10, [x16]
    ARM_IMM x11, 100000
    cmp x10, x11
    b.hi .Lg3_solve_limit
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    ARM_ADDR x16, g3_candidates
    mov x21, x16
.Lg3_validate_candidate:
    mov x10, x22
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_validate_roots_begin
    mov x16, x21
    ldr x0, [x16]
    ARM_CALL g3_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_solve_invalid
    ARM_ADDR x16, g3_any
    mov x0, x16
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL g3_requirement
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_solve_invalid
    mov x16, x21
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.hi .Lg3_solve_invalid
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, G3_DEPS
    cmp x10, x11
    b.hi .Lg3_solve_limit
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x24, [x16]
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq .Lg3_validate_candidate_next
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.eq .Lg3_solve_invalid
.Lg3_validate_dep:
    mov x16, x23
    ldr x0, [x16]
    ARM_CALL g3_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_solve_invalid
    mov x16, x23
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, g3_zero
    mov x1, x16
    ARM_CALL g3_requirement
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_solve_invalid
    ARM_IMM x11, 16
    adds x23, x23, x11
    ARM_IMM x11, 1
    subs x24, x24, x11
    b.ne .Lg3_validate_dep
.Lg3_validate_candidate_next:
    ARM_ADDR x16, g4_profiles
    mov x9, x16
    mov x16, x9
    add x16, x16, x22, lsl #3
    ldr x0, [x16]
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x1, [x16]
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x2, [x16]
    ARM_CALL g4_profile_validate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_solve_invalid
    ARM_ADDR x16, g4_profiles
    mov x9, x16
    mov x16, x9
    add x16, x16, x22, lsl #3
    ldr x0, [x16]
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x2, [x16]
    ARM_CALL g4_budget_profile
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_solve_return
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x22, lsl #3
    str x22, [x16]
    ARM_IMM x11, 1
    adds x22, x22, x11
    ARM_IMM x11, G3_RECORD
    adds x21, x21, x11
    b .Lg3_validate_candidate
.Lg3_validate_roots_begin:
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    ARM_ADDR x16, g3_roots
    mov x21, x16
.Lg3_validate_root:
    mov x10, x22
    ARM_ADDR x16, g3_root_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_validate_root_profile
    mov x16, x21
    ldr x0, [x16]
    ARM_CALL g3_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_solve_invalid
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, g3_zero
    mov x1, x16
    ARM_CALL g3_requirement
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_solve_invalid
    ARM_IMM x11, 1
    adds x22, x22, x11
    ARM_IMM x11, 16
    adds x21, x21, x11
    b .Lg3_validate_root
.Lg4_validate_root_profile:
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    ARM_ADDR x16, g3_roots
    mov x1, x16
    ARM_ADDR x16, g3_root_count
    ldr x2, [x16]
    ARM_CALL g4_profile_validate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_solve_invalid
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    ARM_ADDR x16, g3_root_count
    ldr x2, [x16]
    ARM_CALL g4_budget_profile
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_solve_return
    ARM_ADDR x16, g4_request_count
    ldr x10, [x16]
    ARM_IMM x11, 64
    cmp x10, x11
    b.hi .Lg3_solve_limit
    ARM_ADDR x16, g4_defaults
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.hi .Lg3_solve_invalid
    ARM_ADDR x16, g4_lazy
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.hi .Lg3_solve_invalid
    ARM_ADDR x16, g4_known_count
    ldr x10, [x16]
    ARM_IMM x11, 256
    cmp x10, x11
    b.hi .Lg3_solve_limit
    ARM_ADDR x16, g4_requests
    ldr x0, [x16]
    ARM_ADDR x16, g4_request_count
    ldr x1, [x16]
    ARM_CALL g4_names_validate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg3_solve_invalid
    ARM_ADDR x16, g4_requests
    ldr x21, [x16]
    ARM_ADDR x16, g4_request_count
    ldr x22, [x16]
.Lg4_validate_request:
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_validate_known_begin
    ARM_ADDR x16, g4_root_profile
    ldr x0, [x16]
    mov x1, x21
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg3_solve_invalid
    mov x0, x21
    ARM_CALL g4_next
    mov x21, x9
    ARM_IMM x11, 1
    subs x22, x22, x11
    b .Lg4_validate_request
.Lg4_validate_known_begin:
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
.Lg4_validate_known:
    mov x10, x22
    ARM_ADDR x16, g4_known_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_sort_begin
    ARM_ADDR x16, g4_known_names
    mov x9, x16
    mov x16, x9
    add x16, x16, x22, lsl #3
    ldr x0, [x16]
    ARM_CALL g3_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_solve_invalid
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lg4_validate_known
.Lg3_sort_begin:
    ARM_IMM w22, 1
.Lg3_sort_outer:
    mov x10, x22
    ARM_ADDR x16, g3_candidate_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg3_solve_search
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x22, lsl #3
    ldr x23, [x16]
    mov x24, x22
.Lg3_sort_inner:
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq .Lg3_sort_insert
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x24, lsl #3
    ARM_IMM x17, 8
    sub x16, x16, x17
    ldr x0, [x16]
    mov x1, x23
    ARM_CALL g3_candidate_compare
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3_solve_invalid
    b.mi .Lg3_sort_insert
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x24, lsl #3
    ARM_IMM x17, 8
    sub x16, x16, x17
    ldr x2, [x16]
    mov x16, x9
    add x16, x16, x24, lsl #3
    str x2, [x16]
    ARM_IMM x11, 1
    subs x24, x24, x11
    b .Lg3_sort_inner
.Lg3_sort_insert:
    ARM_ADDR x16, g3_order
    mov x9, x16
    mov x16, x9
    add x16, x16, x24, lsl #3
    str x23, [x16]
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lg3_sort_outer
.Lg3_solve_search:
    ARM_CALL g3_search
    b .Lg3_solve_return
.Lg3_solve_invalid:
    ARM_IMM w9, 3
    b .Lg3_solve_return
.Lg3_solve_limit:
    ARM_IMM w9, 2
.Lg3_solve_return:
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_solve_done
    mov x21, x9
    ARM_ADDR x16, g3_solution
    mov x0, x16
    ARM_IMM w3, G3_CANDIDATES
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    cbz x3, .Lg3_arm_copy_2_end
.Lg3_arm_copy_2:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg3_arm_copy_2
.Lg3_arm_copy_2_end:
    ARM_CALL g4_clear_facts
    mov x9, x21
    mov w10, w9
    ARM_IMM w11, 4
    cmp w10, w11
    b.eq .Lg4_solve_done
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_missing_name
    str x10, [x16]
.Lg4_solve_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Zero branch-derived facts without changing selections or input metadata.
 * All registers except x0/x3/x9 preserved; Stack 0. Contiguous private
 * storage is one owned G4_FACT_BYTES block with fixed field offsets. */
g4_clear_facts:
    ARM_ADDR x16, g4_facts
    mov x0, x16
    ARM_IMM w3, G4_FACT_BYTES
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    cbz x3, .Lg3_arm_copy_3_end
.Lg3_arm_copy_3:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg3_arm_copy_3
.Lg3_arm_copy_3_end:
    ARM_ADDR x16, g3_required
    mov x0, x16
    ARM_IMM w3, G3_CANDIDATES
    cbz x3, .Lg3_arm_copy_4_end
.Lg3_arm_copy_4:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg3_arm_copy_4
.Lg3_arm_copy_4_end:
    ret

.section .rodata
g4_default_name: .asciz "default"
g3_any: .asciz "*"
g3_zero: .asciz "0.0.0"
.section .data
.balign 8
g3_limit: .quad 100000
g4_defaults: .quad 1
g4_forward_option: .quad 0,0,1
.section .bss
.balign 8
g3_candidate_count: .skip 8
g3_root_count: .skip 8
g3_steps: .skip 8
g3_candidates: .skip G3_CANDIDATES * G3_RECORD
g3_roots: .skip G3_ROOTS * 16
g3_solution: .skip G3_CANDIDATES
g3_required: .skip G3_CANDIDATES
g3_order: .skip G3_CANDIDATES * 8
g3_version_numbers: .skip 24
g3_base_numbers: .skip 24

.balign 8
g4_profiles: .skip G3_CANDIDATES * 8
g4_root_profile: .skip 8
g4_requests: .skip 8
g4_request_count: .skip 8
g4_lazy: .skip 8
g4_known_names: .skip G3_CANDIDATES * 8
g4_known_count: .skip 8
g4_missing_name: .skip 8
g4_facts: .skip G4_FACT_BYTES
.set g4_active_features, g4_facts
.set g4_active_deps, g4_facts + 2048
.set g4_root_features, g4_facts + 4096
.set g4_root_deps, g4_facts + 4104
.set g4_dirty, g4_facts + 4112
.set g4_dirty_count, g4_facts + 4368
.if 4368 + 8 != G4_FACT_BYTES
.error "feature fact capacity differs"
.endif
