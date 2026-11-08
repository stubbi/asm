/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Pure, bounded V2 feature profiles. No I/O or input mutation. Arguments
 * x0-x3; result x9. x19-x24 and SP are preserved. ARM_CALL preserves LR.
 * Stack counts exclude ARM_CALL frames and callees; x0-x7/x8/x10-x17 and
 * flags change. Serial validation scratch is process-owned.
 * Generic profiles borrow readable strings/arrays for the complete call.
 */
.equ G4_PROFILE_SIZE, 11296
.equ G4_OPTIONS, 24
.equ G4_DEFINITIONS, 1560
.equ G4_TEXT, 3096
.equ G4_TEXT_BYTES, 8192
.equ G4_TEXT_USED, 11288
.global g4_profile_init, g4_profile_copy, g4_profile_validate, g4_profile_equal
.section .text
/* x0=owned writable11296-byte block. x9=block. Initialize64 options with
 * defaults enabled. Other fields/text are zero. Stack 16; no external calls. */
g4_profile_init:
    ARM_SAVE x19
    mov x19, x0
    ARM_IMM w3, G4_PROFILE_SIZE
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    cbz x3, .Lg4_arm_copy_1_end
.Lg4_arm_copy_1:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg4_arm_copy_1
.Lg4_arm_copy_1_end:
    mov x16, x19
    ARM_IMM x17, G4_OPTIONS
    add x16, x16, x17
    mov x9, x16
    mov x16, x19
    str x9, [x16]
    mov x16, x19
    ARM_IMM x17, G4_DEFINITIONS
    add x16, x16, x17
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_init_option:
    mov x10, x3
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_IMM x10, 2
    mov x16, x19
    add x16, x16, x9
    ARM_IMM x17, G4_OPTIONS
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 64
    cmp w10, w11
    b.lo .Lg4_init_option
    mov x9, x19
    ARM_RESTORE x19
    ret
/* x0=owned destination,x1=owned source11296 orNULL. x9=destination.
 * Rebase nonzero internal pointers. Caller guarantees initialized owned
 * source; generic borrowed profiles cannot be copied. Stack 48. */
g4_profile_copy:
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.eq g4_profile_init
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x19, x0
    mov x21, x0
    mov x11, x1
    subs x21, x21, x11
    ARM_IMM w3, G4_PROFILE_SIZE
    cbz x3, .Lg4_arm_copy_2_end
.Lg4_arm_copy_2:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg4_arm_copy_2
.Lg4_arm_copy_2_end:
    mov x16, x19
    ldr x10, [x16]
    mov x11, x21
    adds x10, x10, x11
    mov x16, x19
    str x10, [x16]
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x11, x21
    adds x10, x10, x11
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    str x10, [x16]
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
.Lg4_copy_pointer:
    mov x10, x22
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x19
    add x16, x16, x9
    ARM_IMM x17, G4_OPTIONS
    add x16, x16, x17
    ARM_IMM x17, 8
    add x16, x16, x17
    mov x2, x16
    mov x16, x2
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_copy_definition
    mov x16, x2
    ldr x10, [x16]
    mov x11, x21
    adds x10, x10, x11
    mov x16, x2
    str x10, [x16]
.Lg4_copy_definition:
    mov x16, x19
    add x16, x16, x9
    ARM_IMM x17, G4_DEFINITIONS
    add x16, x16, x17
    mov x2, x16
    mov x16, x2
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_copy_members
    mov x16, x2
    ldr x10, [x16]
    mov x11, x21
    adds x10, x10, x11
    mov x16, x2
    str x10, [x16]
.Lg4_copy_members:
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_copy_next
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x11, x21
    adds x10, x10, x11
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    str x10, [x16]
.Lg4_copy_next:
    ARM_IMM x11, 1
    adds x22, x22, x11
    mov x10, x22
    ARM_IMM x11, 64
    cmp x10, x11
    b.lo .Lg4_copy_pointer
    mov x9, x19
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0=readable NUL feature identifier. w9=1 valid0invalid. ASCII grammar
 * [a-z][a-z0-9_-]{0,31}. Reads at most33bytes; pointer unchanged; Stack 0. */
g4_feature_name:
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lg4_name_bad
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_name_character:
    mov x16, x0
    add x16, x16, x3
    ldrb w9, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_name_end
    mov w10, w3
    ARM_IMM w11, 32
    cmp w10, w11
    b.hs .Lg4_name_bad
    mov w10, w9
    ARM_IMM w11, 97
    cmp w10, w11
    b.lo .Lg4_name_extra
    mov w10, w9
    ARM_IMM w11, 122
    cmp w10, w11
    b.ls .Lg4_name_next
.Lg4_name_extra:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq .Lg4_name_bad
    mov w10, w9
    ARM_IMM w11, 48
    cmp w10, w11
    b.lo .Lg4_name_punct
    mov w10, w9
    ARM_IMM w11, 57
    cmp w10, w11
    b.ls .Lg4_name_next
.Lg4_name_punct:
    mov w10, w9
    ARM_IMM w11, 95
    cmp w10, w11
    b.eq .Lg4_name_next
    mov w10, w9
    ARM_IMM w11, 45
    cmp w10, w11
    b.ne .Lg4_name_bad
.Lg4_name_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lg4_name_character
.Lg4_name_end:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov w10, w3
    mov w11, w3
    tst w10, w11
    cset w9, ne
    ret
.Lg4_name_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
/* x0/x1 bounded validated strings. w9=0equal1different; Stack 0. */
g4_text_equal:
    mov x16, x0
    ldrb w9, [x16]
    mov w10, w9
    and w10, w10, #255
    mov x16, x1
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_text_different
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_text_return
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM x11, 1
    adds x1, x1, x11
    b g4_text_equal
.Lg4_text_different:
    ARM_IMM w9, 1
.Lg4_text_return:
    ret
/* x0=validated NUL string. x9=following list item; Stack 0. */
g4_next:
    mov x9, x0
.Lg4_next_byte:
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x9, x16
    b.ne .Lg4_next_byte
    ret
/* x0=NUL-separated list,x1=count<=64. w9=0valid1invalid. Validate all
 * identifiers and reject duplicate entries. List pointer may beNULL ifempty.
 * Caller owns readable bytes; bounded names prevent unbounded scans. Stack 80. */
g4_names_validate:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x22, x1
    mov x10, x22
    ARM_IMM x11, 64
    cmp x10, x11
    b.hi .Lg4_names_bad
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_names_good
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lg4_names_bad
    mov x23, x21
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_names_item:
    mov x0, x23
    ARM_CALL g4_feature_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_names_bad
    mov x24, x21
.Lg4_names_duplicate:
    mov x10, x24
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4_names_next
    mov x0, x24
    mov x1, x23
    ARM_CALL g4_text_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_names_bad
    mov x0, x24
    ARM_CALL g4_next
    mov x24, x9
    b .Lg4_names_duplicate
.Lg4_names_next:
    mov x0, x23
    ARM_CALL g4_next
    mov x23, x9
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x10, x19
    mov x11, x22
    cmp x10, x11
    b.lo .Lg4_names_item
.Lg4_names_good:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_names_return
.Lg4_names_bad:
    ARM_IMM w9, 1
.Lg4_names_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0=profile orNULL,x1=feature name. x9=index0..63 or-1. Stack 48. */
g4_feature_index:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x1
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lg4_feature_absent
.Lg4_feature_find:
    mov x10, x19
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_feature_absent
    mov x10, x19
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
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lg4_feature_absent
    mov x1, x22
    ARM_CALL g4_text_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_feature_found
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_feature_find
.Lg4_feature_found:
    mov x9, x19
    b .Lg4_feature_return
.Lg4_feature_absent:
    ARM_IMM x9, -1
.Lg4_feature_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0=validated profile,x1=deps16,x2=count<=64,x3=member. x9=0local,
 * 1optional activation,2child feature,-1invalid; x2=index; x3=borrowed child
 * feature for type2. Member<=137 bytes. Scratch138; Stack 96. No input writes.
 * Child feature existence belongs to candidate selection, not validation. */
g4_member:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x22, x1
    mov x23, x2
    mov x24, x3
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq .Lg4_member_bad
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    ARM_ADDR x16, g4_member_text
    mov x2, x16
.Lg4_member_copy:
    mov x16, x24
    add x16, x16, x19
    ldrb w9, [x16]
    mov x16, x2
    add x16, x16, x19
    strb w9, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_member_classify
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x10, x19
    ARM_IMM x11, 137
    cmp x10, x11
    b.ls .Lg4_member_copy
    b .Lg4_member_bad
.Lg4_member_classify:
    mov x16, x2
    ldr w10, [x16]
    ARM_IMM w11, 0x3a706564
    cmp w10, w11
    b.eq .Lg4_member_optional
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
.Lg4_member_slash:
    mov x16, x2
    add x16, x16, x19
    ldrb w9, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_member_slashes
    mov w10, w9
    ARM_IMM w11, 47
    cmp w10, w11
    b.ne .Lg4_member_scan_next
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov x4, x19
.Lg4_member_scan_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_member_slash
.Lg4_member_slashes:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq .Lg4_member_local
    mov w10, w3
    ARM_IMM w11, 2
    cmp w10, w11
    b.ne .Lg4_member_bad
    ARM_IMM w10, 0
    mov x16, x2
    add x16, x16, x4
    strb w10, [x16]
    mov x16, x24
    add x16, x16, x4
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x19, x16
    mov x0, x19
    ARM_CALL g4_feature_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_member_bad
    ARM_IMM w24, 2
    ARM_ADDR x16, g4_member_text
    mov x21, x16
    b .Lg4_member_dependency
.Lg4_member_optional:
    ARM_IMM w24, 1
    mov x16, x2
    ARM_IMM x17, 4
    add x16, x16, x17
    mov x21, x16
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_member_dependency:
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
.Lg4_member_dep_find:
    mov x10, x4
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4_member_bad
    mov x0, x21
    mov x16, x22
    ldr x1, [x16]
    sub sp, sp, #16
    mov x16, sp
    str x4, [x16]
    ARM_CALL g4_text_equal
    mov x16, sp
    ldr x4, [x16]
    add sp, sp, #16
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_member_dep_found
    ARM_IMM x11, 1
    adds x4, x4, x11
    ARM_IMM x11, 16
    adds x22, x22, x11
    b .Lg4_member_dep_find
.Lg4_member_dep_found:
.Lg4_member_dep_result:
    mov w9, w24
    mov x2, x4
    mov x3, x19
    b .Lg4_member_return
.Lg4_member_local:
    mov x0, x24
    ARM_CALL g4_feature_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_member_bad
    mov x0, x21
    mov x1, x24
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg4_member_bad
    mov x2, x9
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_member_return
.Lg4_member_bad:
    ARM_IMM x9, -1
.Lg4_member_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0=profile orNULL,x1=deps16,x2=count<=64. w9=0valid1invalid.
 * Validates inactive declarations, flags, all lists, local references and
 * local cycles. NULL means mandatory dependencies/defaults/no local features.
 * DFS depth<=64; visited64/private member138; Stack 96 plus DFS frames80. */
g4_profile_validate:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x22, x1
    mov x23, x2
    mov x10, x23
    ARM_IMM x11, 64
    cmp x10, x11
    b.hi .Lg4_profile_bad
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lg4_profile_good
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 64
    cmp x10, x11
    b.hi .Lg4_profile_bad
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.eq .Lg4_profile_definitions
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_profile_bad
    mov x16, x21
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_profile_bad
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_profile_option:
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ldr x24, [x16]
    mov x11, x9
    adds x24, x24, x11
    mov x16, x24
    ldr x10, [x16]
    ARM_IMM x11, 3
    cmp x10, x11
    b.hi .Lg4_profile_bad
    mov x16, x24
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    mov x16, x24
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL g4_names_validate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_profile_bad
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x10, x19
    mov x11, x23
    cmp x10, x11
    b.lo .Lg4_profile_option
.Lg4_profile_definitions:
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_profile_good
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lg4_profile_bad
    ARM_ADDR x16, g4_validation_profile
    str x21, [x16]
    ARM_ADDR x16, g4_validation_deps
    str x22, [x16]
    ARM_ADDR x16, g4_validation_count
    str x23, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_profile_definition:
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x24, [x16]
    mov x11, x9
    adds x24, x24, x11
    mov x16, x24
    ldr x0, [x16]
    ARM_CALL g4_feature_name
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_profile_bad
    mov x0, x21
    mov x16, x24
    ldr x1, [x16]
    ARM_CALL g4_feature_index
    mov x10, x9
    mov x11, x19
    cmp x10, x11
    b.ne .Lg4_profile_bad
    mov x16, x24
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 64
    cmp x10, x11
    b.hi .Lg4_profile_bad
    mov x16, x24
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x22, [x16]
    mov x16, x24
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x23, [x16]
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.eq .Lg4_profile_definition_next
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.eq .Lg4_profile_bad
.Lg4_profile_member:
    mov x0, x21
    ARM_ADDR x16, g4_validation_deps
    ldr x1, [x16]
    ARM_ADDR x16, g4_validation_count
    ldr x2, [x16]
    mov x3, x22
    ARM_CALL g4_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lg4_profile_bad
    mov w10, w9
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lg4_profile_member_unique
    mov x10, x2
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x2, x10, x11
    asr x13, x2, #63
    cmp x12, x13
    mov x16, x21
    ldr x9, [x16]
    mov x16, x9
    add x16, x16, x2
    ldr x10, [x16]
    ARM_IMM x11, 1
    tst x10, x11
    b.eq .Lg4_profile_bad
.Lg4_profile_member_unique:
    mov x16, x24
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
.Lg4_profile_member_duplicate:
    mov x10, x0
    mov x11, x22
    cmp x10, x11
    b.hs .Lg4_profile_member_next
    sub sp, sp, #16
    mov x16, sp
    str x0, [x16]
    mov x1, x22
    ARM_CALL g4_text_equal
    mov x16, sp
    ldr x0, [x16]
    add sp, sp, #16
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_profile_bad
    ARM_CALL g4_next
    mov x0, x9
    b .Lg4_profile_member_duplicate
.Lg4_profile_member_next:
    mov x0, x22
    ARM_CALL g4_next
    mov x22, x9
    ARM_IMM x11, 1
    subs x23, x23, x11
    b.ne .Lg4_profile_member
.Lg4_profile_definition_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x10, x19
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.lo .Lg4_profile_definition
    ARM_ADDR x16, g4_validation_seen
    mov x0, x16
    ARM_IMM w3, 64
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    cbz x3, .Lg4_arm_copy_3_end
.Lg4_arm_copy_3:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg4_arm_copy_3
.Lg4_arm_copy_3_end:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_profile_cycle:
    mov x0, x19
    ARM_CALL g4_feature_visit
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_profile_bad
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x10, x19
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.lo .Lg4_profile_cycle
.Lg4_profile_good:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_profile_return
.Lg4_profile_bad:
    ARM_IMM w9, 1
.Lg4_profile_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0=local feature index<64, validated declarations in serial scratch.
 * w9=0acyclic1cycle. DFS colors prevent unbounded recursion. Stack 80/depth. */
g4_feature_visit:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x19, x0
    ARM_ADDR x16, g4_validation_seen
    mov x2, x16
    mov x16, x2
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 2
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_visit_good
    mov x16, x2
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_visit_bad
    ARM_IMM w10, 1
    mov x16, x2
    add x16, x16, x19
    strb w10, [x16]
    ARM_ADDR x16, g4_validation_profile
    ldr x21, [x16]
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x2, [x16]
    mov x11, x9
    adds x2, x2, x11
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x22, [x16]
    mov x16, x2
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x23, [x16]
.Lg4_visit_member:
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.eq .Lg4_visit_done
    mov x0, x21
    ARM_ADDR x16, g4_validation_deps
    ldr x1, [x16]
    ARM_ADDR x16, g4_validation_count
    ldr x2, [x16]
    mov x3, x22
    ARM_CALL g4_member
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_visit_next
    mov x0, x2
    ARM_CALL g4_feature_visit
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_visit_bad
.Lg4_visit_next:
    mov x0, x22
    ARM_CALL g4_next
    mov x22, x9
    ARM_IMM x11, 1
    subs x23, x23, x11
    b .Lg4_visit_member
.Lg4_visit_done:
    ARM_ADDR x16, g4_validation_seen
    mov x2, x16
    ARM_IMM w10, 2
    mov x16, x2
    add x16, x16, x19
    strb w10, [x16]
.Lg4_visit_good:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_visit_return
.Lg4_visit_bad:
    ARM_IMM w9, 1
.Lg4_visit_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0/x1=validated profiles orNULL,x2=depcount. w9=0same1different.
 * Compare semantic fields and canonical list order, never pointer values or
 * unused bytes. NULL equals explicit mandatory/default/no-feature profile.
 * Stack 112; caller retains readable arrays. */
g4_profile_equal:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x22, x1
    mov x23, x2
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.ne .Lg4_equal_right
    ARM_ADDR x16, g4_legacy_profile
    mov x21, x16
.Lg4_equal_right:
    mov x10, x22
    mov x11, x22
    tst x10, x11
    b.ne .Lg4_equal_options
    ARM_ADDR x16, g4_legacy_profile
    mov x22, x16
.Lg4_equal_options:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_equal_option:
    mov x10, x19
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4_equal_features
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ldr x0, [x16]
    mov x16, x22
    ldr x1, [x16]
    mov x11, x9
    adds x0, x0, x11
    mov x11, x9
    adds x1, x1, x11
    mov x16, x0
    ldr x9, [x16]
    mov x10, x9
    mov x16, x1
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg4_equal_bad
    ARM_CALL g4_record_list_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_equal_bad
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_equal_option
.Lg4_equal_features:
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x9, [x16]
    mov x10, x9
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg4_equal_bad
    mov x23, x9
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_equal_definition:
    mov x10, x19
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4_equal_good
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    mov x11, x9
    adds x0, x0, x11
    mov x11, x9
    adds x1, x1, x11
    ARM_SAVE x0
    ARM_SAVE x1
    mov x16, x0
    ldr x0, [x16]
    mov x16, x1
    ldr x1, [x16]
    ARM_CALL g4_text_equal
    ARM_RESTORE x1
    ARM_RESTORE x0
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_equal_bad
    ARM_CALL g4_record_list_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_equal_bad
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_equal_definition
.Lg4_equal_good:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_equal_return
.Lg4_equal_bad:
    ARM_IMM w9, 1
.Lg4_equal_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
/* x0/x1=records24 with list ptr@8,count@16. w9=0same1different. Stack 48. */
g4_record_list_equal:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x16, x0
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x19, [x16]
    mov x10, x19
    mov x16, x1
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg4_list_equal_bad
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x21, [x16]
    mov x16, x1
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x22, [x16]
.Lg4_list_equal_item:
    mov x10, x19
    mov x11, x19
    tst x10, x11
    b.eq .Lg4_list_equal_good
    mov x0, x21
    mov x1, x22
    ARM_CALL g4_text_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_list_equal_bad
    mov x0, x21
    ARM_CALL g4_next
    mov x21, x9
    mov x0, x22
    ARM_CALL g4_next
    mov x22, x9
    ARM_IMM x11, 1
    subs x19, x19, x11
    b .Lg4_list_equal_item
.Lg4_list_equal_good:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_list_equal_return
.Lg4_list_equal_bad:
    ARM_IMM w9, 1
.Lg4_list_equal_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
.section .data
.balign 8
g4_legacy_profile: .quad g4_legacy_options,0,0
g4_legacy_options:
.rept 64
    .quad 2,0,0
.endr
.section .bss
.balign 8
g4_validation_profile: .skip 8
g4_validation_deps: .skip 8
g4_validation_count: .skip 8
g4_validation_seen: .skip 64
g4_member_text: .skip 138
