/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native source and signed dependency-feature declarations.
 * SysV inputs x0/x1/x2; x9 result. Preserve x19/x20/x21-x24.
 * Owned serial state:64 dependency records240, profiles11296 each. Source
 * manifests<=8190 ASCII bytes;64 definitions/list entries; text pool8192.
 */
.equ G3_PROJECT_DEP_RECORD, 240
.equ G3_PROJECT_DEP_LIMIT, 64
.section .text

/* x0=NUL source manifest<=8190 bytes. w9=0 valid,1 invalid. Writes sorted
 * g3_project_deps/count and g4_project_profile. Other recipe fields stay with
 * the caller's strict project parser. No input bytes change. Stack 112. */
g3_project_dependencies:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov x21, x0
    ARM_IMM x10, 0
    ARM_ADDR x16, g3_project_dep_count
    str x10, [x16]
    ARM_ADDR x16, g4_project_profile
    mov x0, x16
    ARM_CALL g4_profile_init
    ARM_ADDR x16, g4_parser_profile
    str x9, [x16]
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4p_bound:
    mov x16, x21
    add x16, x16, x3
    ldrb w9, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4p_bound_done
    mov w10, w3
    ARM_IMM w11, 8190
    cmp w10, w11
    b.hs .Lg4p_bad
    mov w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.eq .Lg4p_bound_next
    mov w10, w9
    ARM_IMM w11, 10
    cmp w10, w11
    b.eq .Lg4p_bound_next
    mov w10, w9
    ARM_IMM w11, 13
    cmp w10, w11
    b.eq .Lg4p_bound_next
    mov w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.lo .Lg4p_bad
    mov w10, w9
    ARM_IMM w11, 126
    cmp w10, w11
    b.hi .Lg4p_bad
.Lg4p_bound_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lg4p_bound
.Lg4p_bound_done:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq .Lg4p_bad
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    mov w11, w23
    eor w23, w23, w11
    tst w23, w23
.Lg4p_line:
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lg4p_finish
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 35
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_skip
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 91
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_section
    mov w10, w22
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq .Lg4p_dependency
    mov w10, w22
    ARM_IMM w11, 2
    cmp w10, w11
    b.eq .Lg4p_feature
    b .Lg4p_skip
.Lg4p_dependency:
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs .Lg4p_bad
    mov x10, x9
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_project_deps
    mov x24, x16
    mov x11, x9
    adds x24, x24, x11
    mov x0, x24
    ARM_IMM w1, 105
    ARM_CALL g3_project_string
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    mov x0, x24
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4p_bad
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4p_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_CALL g3_project_horizontal
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g4_project_profile + G4_OPTIONS
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    ARM_IMM x10, 2
    mov x16, x19
    str x10, [x16]
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 123
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_inline
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 129
    ARM_CALL g3_project_string
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    b .Lg4p_dependency_range
.Lg4p_inline:
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lg4p_inline_field:
    ARM_CALL g3_project_horizontal
    ARM_ADDR x16, g4_parser_key
    mov x0, x16
    ARM_IMM w1, 33
    ARM_CALL g4_project_identifier
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4p_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_CALL g3_project_horizontal
    ARM_ADDR x16, g4_parser_key
    mov x0, x16
    ARM_ADDR x16, g4_key_version
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_inline_version
    ARM_ADDR x16, g4_parser_key
    mov x0, x16
    ARM_ADDR x16, g4_key_optional
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_inline_optional
    ARM_ADDR x16, g4_parser_key
    mov x0, x16
    ARM_ADDR x16, g4_key_source_defaults
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_inline_defaults
    ARM_ADDR x16, g4_parser_key
    mov x0, x16
    ARM_ADDR x16, g3_project_feature_section
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4p_bad
    mov w10, w20
    ARM_IMM w11, 8
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_IMM w11, 8
    orr w20, w20, w11
    tst w20, w20
    mov x0, x19
    ARM_CALL g4_source_array
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    b .Lg4p_inline_end
.Lg4p_inline_version:
    mov w10, w20
    ARM_IMM w11, 1
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_IMM w11, 1
    orr w20, w20, w11
    tst w20, w20
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_IMM w1, 129
    ARM_CALL g3_project_string
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    b .Lg4p_inline_end
.Lg4p_inline_optional:
    mov w10, w20
    ARM_IMM w11, 2
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_IMM w11, 2
    orr w20, w20, w11
    tst w20, w20
    ARM_CALL g4_source_bool
    mov w10, w9
    ARM_IMM w11, -1
    cmp w10, w11
    b.eq .Lg4p_bad
    mov x16, x19
    ldr x10, [x16]
    ARM_IMM x11, -2
    and x10, x10, x11
    tst x10, x10
    mov x16, x19
    str x10, [x16]
    mov x16, x19
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x19
    str x10, [x16]
    b .Lg4p_inline_end
.Lg4p_inline_defaults:
    mov w10, w20
    ARM_IMM w11, 4
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_IMM w11, 4
    orr w20, w20, w11
    tst w20, w20
    ARM_CALL g4_source_bool
    mov w10, w9
    ARM_IMM w11, -1
    cmp w10, w11
    b.eq .Lg4p_bad
    lsl x9, x9, #1
    mov x16, x19
    ldr x10, [x16]
    ARM_IMM x11, -3
    and x10, x10, x11
    tst x10, x10
    mov x16, x19
    str x10, [x16]
    mov x16, x19
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x19
    str x10, [x16]
.Lg4p_inline_end:
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 125
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_inline_done
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 44
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4p_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lg4p_inline_field
.Lg4p_inline_done:
    mov w10, w20
    ARM_IMM w11, 1
    tst w10, w11
    b.eq .Lg4p_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
.Lg4p_dependency_range:
    mov x16, x24
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, g3_project_zero
    mov x1, x16
    ARM_CALL g3_requirement
    mov w10, w9
    ARM_IMM w11, -1
    cmp w10, w11
    b.eq .Lg4p_bad
    ARM_ADDR x16, g3_project_dep_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g3_project_dep_count
    str x10, [x16]
    b .Lg4p_line_end
.Lg4p_feature:
    ARM_ADDR x16, g4_project_profile + 16
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs .Lg4p_bad
    mov x10, x9
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g4_project_profile + G4_DEFINITIONS
    mov x24, x16
    mov x11, x9
    adds x24, x24, x11
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_feature_quoted
    ARM_ADDR x16, g4_parser_text
    mov x0, x16
    ARM_IMM w1, 33
    ARM_CALL g4_project_identifier
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    b .Lg4p_feature_name
.Lg4p_feature_quoted:
    ARM_ADDR x16, g4_parser_text
    mov x0, x16
    ARM_IMM w1, 33
    ARM_CALL g3_project_string
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
.Lg4p_feature_name:
    ARM_ADDR x16, g4_parser_text
    mov x1, x16
    ARM_CALL g4_parser_pool
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4p_bad
    mov x16, x24
    str x9, [x16]
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4p_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_CALL g3_project_horizontal
    mov x0, x24
    ARM_CALL g4_source_array
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_ADDR x16, g4_project_profile + 16
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g4_project_profile + 16
    str x10, [x16]
    b .Lg4p_line_end
.Lg4p_section:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, g3_project_section
    mov x0, x16
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4p_section_byte:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_section_end
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lg4p_bad
    mov w10, w3
    ARM_IMM w11, 63
    cmp w10, w11
    b.hs .Lg4p_bad
    mov x16, x0
    add x16, x16, x3
    strb w9, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lg4p_section_byte
.Lg4p_section_end:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    ARM_ADDR x16, g3_project_dependency_section
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_dep_section
    ARM_ADDR x16, g3_project_section
    mov x0, x16
    ARM_ADDR x16, g3_project_feature_section
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_feat_section
    ARM_ADDR x16, g3_project_section
    mov x0, x16
    ARM_ADDR x16, g3_project_resolution_section
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    b .Lg4p_line_end
.Lg4p_dep_section:
    mov w10, w23
    ARM_IMM w11, 1
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_IMM w11, 1
    orr w23, w23, w11
    tst w23, w23
    ARM_IMM w22, 1
    b .Lg4p_line_end
.Lg4p_feat_section:
    mov w10, w23
    ARM_IMM w11, 2
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_IMM w11, 2
    orr w23, w23, w11
    tst w23, w23
    ARM_IMM w22, 2
.Lg4p_line_end:
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lg4p_finish
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 35
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4p_skip
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4p_bad
.Lg4p_next:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lg4p_line
.Lg4p_skip:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lg4p_finish
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4p_skip
    b .Lg4p_line
.Lg4p_finish:
    ARM_CALL g4_source_sort
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4p_bad
    ARM_ADDR x16, g4_project_profile
    mov x0, x16
    ARM_ADDR x16, g3_project_deps
    mov x1, x16
    ARM_ADDR x16, g3_project_dep_count
    ldr x2, [x16]
    ARM_CALL g4_parser_validate
    b .Lg4p_return
.Lg4p_bad:
    ARM_IMM w9, 1
.Lg4p_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x21=cursor,x0=destination,w1=capacity including NUL. w9=0/1. Bounded
 * plain quoted string; no escapes, control bytes, or input mutation. */
g3_project_string:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_string_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_string_byte:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_string_end
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lg4_string_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lg4_string_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_string_bad
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    mov w11, w1
    cmp w10, w11
    b.hs .Lg4_string_bad
    mov x16, x0
    add x16, x16, x3
    ARM_IMM x17, 1
    sub x16, x16, x17
    strb w9, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lg4_string_byte
.Lg4_string_end:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
.Lg4_string_bad:
    ARM_IMM w9, 1
    ret

/* x21=cursor,x0=destination,w1=capacity. Read an unquoted key. EAX0/1. */
g4_project_identifier:
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_identifier_byte:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lg4_identifier_other
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lg4_identifier_accept
.Lg4_identifier_other:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq .Lg4_identifier_end
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lg4_identifier_symbol
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lg4_identifier_accept
.Lg4_identifier_symbol:
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 95
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_identifier_accept
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_identifier_end
.Lg4_identifier_accept:
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    mov w11, w1
    cmp w10, w11
    b.hs .Lg4_identifier_bad
    mov x16, x0
    add x16, x16, x3
    ARM_IMM x17, 1
    sub x16, x16, x17
    strb w9, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lg4_identifier_byte
.Lg4_identifier_end:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq .Lg4_identifier_bad
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
.Lg4_identifier_bad:
    ARM_IMM w9, 1
    ret

/* x21=cursor, w9=1/0 boolean or-1 invalid; delimiter remains unconsumed. */
g4_source_bool:
    ARM_ADDR x16, g4_true
    mov x1, x16
    ARM_IMM w4, 1
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 116
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_bool_scan_start
    ARM_ADDR x16, g4_false
    mov x1, x16
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
.Lg4_bool_scan_start:
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_bool_scan:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lg4_bool_done
    mov w10, w9
    and w10, w10, #255
    mov x16, x21
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_bool_bad
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lg4_bool_scan
.Lg4_bool_done:
    mov x11, x3
    adds x21, x21, x11
    mov w9, w4
    ret
.Lg4_bool_bad:
    ARM_IMM x9, -1
    ret

g3_project_horizontal:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_horizontal_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_horizontal_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 13
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_horizontal_done
.Lg4_horizontal_next:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b g3_project_horizontal
.Lg4_horizontal_done:
    ret

/* x1=plain NUL string<=137bytes. Append to active owned profile text pool.
 * x9=owned pointer,0 if capacity exhausted. Scratch caller registers; Stack 48. */
g4_parser_pool:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x1
    mov x0, x1
    ARM_CALL strlen
    ARM_IMM x11, 1
    adds x9, x9, x11
    ARM_ADDR x16, g4_parser_profile
    ldr x19, [x16]
    mov x16, x19
    ARM_IMM x17, G4_TEXT_USED
    add x16, x16, x17
    ldr x22, [x16]
    mov x16, x22
    add x16, x16, x9
    mov x2, x16
    mov x10, x2
    ARM_IMM x11, G4_TEXT_BYTES
    cmp x10, x11
    b.hi .Lg4_pool_bad
    mov x16, x19
    ARM_IMM x17, G4_TEXT_USED
    add x16, x16, x17
    str x2, [x16]
    mov x16, x19
    add x16, x16, x22
    ARM_IMM x17, G4_TEXT
    add x16, x16, x17
    mov x0, x16
    mov x22, x0
    mov x1, x21
    mov x3, x9
    cbz x3, .Lg4p_arm_copy_1_end
.Lg4p_arm_copy_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg4p_arm_copy_1
.Lg4p_arm_copy_1_end:
    mov x9, x22
    b .Lg4_pool_return
.Lg4_pool_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lg4_pool_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=option/definition24. Parse its array into the active profile. The first
 * qword is preserved; listptr/count written at8/16. Sort source members and
 * reject duplicates. EAX0/1. String pool remains bounded even on failure. */
g4_source_array:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x19, x0
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 91
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_array_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM x10, 0
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM x10, 0
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, g4_array_count
    str x10, [x16]
    ARM_ADDR x16, g4_parser_profile
    ldr x9, [x16]
    mov x16, x9
    ARM_IMM x17, G4_TEXT_USED
    add x16, x16, x17
    ldr x9, [x16]
    ARM_ADDR x16, g4_array_start
    str x9, [x16]
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_array_done
.Lg4_array_value:
    ARM_ADDR x16, g4_array_count
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs .Lg4_array_bad
    ARM_ADDR x16, g4_parser_text
    mov x0, x16
    ARM_IMM w1, 138
    ARM_CALL g3_project_string
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_array_bad
    ARM_ADDR x16, g4_parser_text
    mov x1, x16
    ARM_CALL g4_parser_pool
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4_array_bad
    ARM_ADDR x16, g4_array_count
    ldr x2, [x16]
    ARM_ADDR x16, g4_array_pointers
    mov x3, x16
    mov x16, x3
    add x16, x16, x2, lsl #3
    str x9, [x16]
    ARM_ADDR x16, g4_array_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g4_array_count
    str x10, [x16]
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lg4_array_done
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 44
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_array_bad
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_CALL g3_project_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lg4_array_value
.Lg4_array_done:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_CALL g4_array_sort
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_array_bad
    ARM_ADDR x16, g4_array_count
    ldr x9, [x16]
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
    str x9, [x16]
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4_array_ok
    ARM_ADDR x16, g4_parser_profile
    ldr x9, [x16]
    ARM_IMM x11, G4_TEXT
    adds x9, x9, x11
    ARM_ADDR x16, g4_array_start
    ldr x11, [x16]
    adds x9, x9, x11
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
.Lg4_array_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_array_return
.Lg4_array_bad:
    ARM_IMM w9, 1
.Lg4_array_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Sort <=64 borrowed pointers and rewrite their contiguous owned text span.
 * EAX0/1; duplicates rejected. Shared scratch8192+64 pointers. Stack 80. */
g4_array_sort:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_ADDR x16, g4_array_pointers
    mov x21, x16
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_sort_array_outer:
    mov x10, x19
    ARM_ADDR x16, g4_array_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_array_copy
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x20, x16
.Lg4_sort_array_inner:
    mov x10, x20
    ARM_ADDR x16, g4_array_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_array_next
    mov x16, x21
    add x16, x16, x19, lsl #3
    ldr x0, [x16]
    mov x16, x21
    add x16, x16, x20, lsl #3
    ldr x1, [x16]
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_sort_array_bad
    b.mi .Lg4_sort_array_keep
    mov x16, x21
    add x16, x16, x19, lsl #3
    ldr x9, [x16]
    mov x16, x21
    add x16, x16, x20, lsl #3
    ldr x2, [x16]
    mov x16, x21
    add x16, x16, x19, lsl #3
    str x2, [x16]
    mov x16, x21
    add x16, x16, x20, lsl #3
    str x9, [x16]
.Lg4_sort_array_keep:
    ARM_IMM x11, 1
    adds x20, x20, x11
    b .Lg4_sort_array_inner
.Lg4_sort_array_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_sort_array_outer
.Lg4_sort_array_copy:
    ARM_ADDR x16, g4_array_buffer
    mov x22, x16
    mov x23, x22
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_sort_array_string:
    mov x10, x19
    ARM_ADDR x16, g4_array_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_array_restore
    mov x16, x21
    add x16, x16, x19, lsl #3
    ldr x1, [x16]
    mov x0, x23
    ARM_CALL copy_string
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x23, x16
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_sort_array_string
.Lg4_sort_array_restore:
    mov x3, x23
    mov x11, x22
    subs x3, x3, x11
    ARM_ADDR x16, g4_parser_profile
    ldr x0, [x16]
    ARM_IMM x11, G4_TEXT
    adds x0, x0, x11
    ARM_ADDR x16, g4_array_start
    ldr x11, [x16]
    adds x0, x0, x11
    mov x1, x22
    cbz x3, .Lg4p_arm_copy_2_end
.Lg4p_arm_copy_2:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lg4p_arm_copy_2
.Lg4p_arm_copy_2_end:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_sort_array_return
.Lg4_sort_array_bad:
    ARM_IMM w9, 1
.Lg4_sort_array_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Sort source dependencies with their options, then feature definitions.
 * EAX0/1; strict uniqueness applies regardless of whether a feature is used. */
g4_source_sort:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_sort_dep_outer:
    mov x10, x19
    ARM_ADDR x16, g3_project_dep_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_defs_start
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x20, x16
.Lg4_sort_dep_inner:
    mov x10, x20
    ARM_ADDR x16, g3_project_dep_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_dep_next
    mov x10, x19
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x10, x20
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x2, x10, x11
    asr x13, x2, #63
    cmp x12, x13
    ARM_ADDR x16, g3_project_deps
    mov x21, x16
    mov x16, x21
    add x16, x16, x2
    mov x22, x16
    mov x11, x9
    adds x21, x21, x11
    mov x0, x21
    mov x1, x22
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_sort_source_bad
    b.mi .Lg4_sort_dep_keep
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_swap_dep:
    mov x16, x21
    add x16, x16, x3
    ldr x9, [x16]
    mov x16, x22
    add x16, x16, x3
    ldr x2, [x16]
    mov x16, x21
    add x16, x16, x3
    str x2, [x16]
    mov x16, x22
    add x16, x16, x3
    str x9, [x16]
    ARM_IMM x11, 8
    adds x3, x3, x11
    mov x10, x3
    ARM_IMM x11, 240
    cmp x10, x11
    b.lo .Lg4_swap_dep
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x10, x20
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x2, x10, x11
    asr x13, x2, #63
    cmp x12, x13
    ARM_ADDR x16, g4_project_profile + G4_OPTIONS
    mov x21, x16
    mov x16, x21
    add x16, x16, x2
    mov x22, x16
    mov x11, x9
    adds x21, x21, x11
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_swap_option:
    mov x16, x21
    add x16, x16, x3
    ldr x9, [x16]
    mov x16, x22
    add x16, x16, x3
    ldr x2, [x16]
    mov x16, x21
    add x16, x16, x3
    str x2, [x16]
    mov x16, x22
    add x16, x16, x3
    str x9, [x16]
    ARM_IMM x11, 8
    adds x3, x3, x11
    mov x10, x3
    ARM_IMM x11, 24
    cmp x10, x11
    b.lo .Lg4_swap_option
.Lg4_sort_dep_keep:
    ARM_IMM x11, 1
    adds x20, x20, x11
    b .Lg4_sort_dep_inner
.Lg4_sort_dep_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_sort_dep_outer
.Lg4_sort_defs_start:
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg4_sort_def_outer:
    mov x10, x19
    ARM_ADDR x16, g4_project_profile + 16
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_source_ok
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x20, x16
.Lg4_sort_def_inner:
    mov x10, x20
    ARM_ADDR x16, g4_project_profile + 16
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lg4_sort_def_next
    mov x10, x19
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x10, x20
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x2, x10, x11
    asr x13, x2, #63
    cmp x12, x13
    ARM_ADDR x16, g4_project_profile + G4_DEFINITIONS
    mov x21, x16
    mov x16, x21
    add x16, x16, x2
    mov x22, x16
    mov x11, x9
    adds x21, x21, x11
    mov x16, x21
    ldr x0, [x16]
    mov x16, x22
    ldr x1, [x16]
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg4_sort_source_bad
    b.mi .Lg4_sort_def_keep
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lg4_swap_def:
    mov x16, x21
    add x16, x16, x3
    ldr x9, [x16]
    mov x16, x22
    add x16, x16, x3
    ldr x2, [x16]
    mov x16, x21
    add x16, x16, x3
    str x2, [x16]
    mov x16, x22
    add x16, x16, x3
    str x9, [x16]
    ARM_IMM x11, 8
    adds x3, x3, x11
    mov x10, x3
    ARM_IMM x11, 24
    cmp x10, x11
    b.lo .Lg4_swap_def
.Lg4_sort_def_keep:
    ARM_IMM x11, 1
    adds x20, x20, x11
    b .Lg4_sort_def_inner
.Lg4_sort_def_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg4_sort_def_outer
.Lg4_sort_source_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg4_sort_source_return
.Lg4_sort_source_bad:
    ARM_IMM w9, 1
.Lg4_sort_source_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=profile,x1=records240,x2=count. EAX0/1; construct the pure model's
 * borrowed dependency-pair view without changing owned declarations. */
g4_parser_validate:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x2
    ARM_ADDR x16, g4_parser_pairs
    mov x0, x16
    mov x3, x2
.Lg4_pair_next:
    mov x10, x3
    mov x11, x3
    tst x10, x11
    b.eq .Lg4_pair_done
    mov x16, x0
    str x1, [x16]
    mov x16, x1
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x9, x16
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM x11, 16
    adds x0, x0, x11
    ARM_IMM x11, 240
    adds x1, x1, x11
    ARM_IMM x11, 1
    subs x3, x3, x11
    b .Lg4_pair_next
.Lg4_pair_done:
    mov x0, x21
    ARM_ADDR x16, g4_parser_pairs
    mov x1, x16
    mov x2, x22
    ARM_CALL g4_profile_validate
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=validated publication object. Own r2_dependencies/count plus the
 * publication feature profile. Missing extension fields retain old defaults.
 * JSON arrays are strictly sorted; source normalization supplies that order.
 * Stack 96 plus bounded JSON/model helpers. Fatal errors preserve caller files. */
g3_manifest_dependencies:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x20, x0
    ARM_ADDR x16, g4_publication_profile
    mov x0, x16
    ARM_CALL g4_profile_init
    ARM_ADDR x16, g4_parser_profile
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_dependency_count
    str x10, [x16]
    mov x0, x20
    ARM_ADDR x16, g3_project_dependency_section
    mov x1, x16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4m_features
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne r2_invalid
    mov x16, x9
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x9
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x19, x16
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lg4m_dependency:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x19
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4m_features
    ARM_ADDR x16, r2_dependency_count
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs r2_invalid
    mov x10, x9
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x2, x10, x11
    asr x13, x2, #63
    cmp x12, x13
    ARM_ADDR x16, g4_publication_profile + G4_OPTIONS
    mov x22, x16
    mov x11, x2
    adds x22, x22, x11
    ARM_IMM x10, 2
    mov x16, x22
    str x10, [x16]
    mov x10, x9
    ARM_IMM x11, 240
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_dependencies
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x0, x19
    ARM_ADDR x16, g3_manifest_fields
    mov x1, x16
    ARM_IMM w2, 2
    ARM_IMM w3, 5
    ARM_CALL r2_keys
    mov x0, x19
    ARM_ADDR x16, r2_k_name
    mov x1, x16
    ARM_CALL r2_required
    mov x0, x9
    mov x1, x21
    ARM_IMM w2, 105
    ARM_CALL r2_string
    mov x0, x21
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    mov x0, x19
    ARM_ADDR x16, g3_manifest_requirement
    mov x1, x16
    ARM_CALL r2_required
    mov x0, x9
    mov x16, x21
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_IMM w2, 129
    ARM_CALL r2_string
    mov x16, x21
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, g3_project_zero
    mov x1, x16
    ARM_CALL g3_requirement
    mov w10, w9
    ARM_IMM w11, -1
    cmp w10, w11
    b.eq r2_invalid
    mov x0, x19
    ARM_ADDR x16, g4_key_optional
    mov x1, x16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4m_defaults
    mov x0, x9
    ARM_CALL g4_json_bool
    mov x16, x22
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x22
    str x10, [x16]
.Lg4m_defaults:
    mov x0, x19
    ARM_ADDR x16, g4_key_json_defaults
    mov x1, x16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4m_requested
    mov x0, x9
    ARM_CALL g4_json_bool
    lsl x9, x9, #1
    mov x16, x22
    ldr x10, [x16]
    ARM_IMM x11, -3
    and x10, x10, x11
    tst x10, x10
    mov x16, x22
    str x10, [x16]
    mov x16, x22
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    mov x16, x22
    str x10, [x16]
.Lg4m_requested:
    mov x0, x19
    ARM_ADDR x16, g3_project_feature_section
    mov x1, x16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4m_dependency_order
    mov x0, x9
    mov x1, x22
    ARM_IMM w2, 33
    ARM_CALL g4_json_array
.Lg4m_dependency_order:
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq .Lg4m_dependency_accept
    mov x0, x24
    mov x1, x21
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.pl r2_invalid
.Lg4m_dependency_accept:
    mov x24, x21
    ARM_ADDR x16, r2_dependency_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r2_dependency_count
    str x10, [x16]
    mov x16, x19
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    b .Lg4m_dependency
.Lg4m_features:
    mov x0, x20
    ARM_ADDR x16, g3_project_feature_section
    mov x1, x16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lg4m_validate
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne r2_invalid
    mov x16, x9
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x9
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x19, x16
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lg4m_definition:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x19
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4m_validate
    ARM_ADDR x16, g4_publication_profile + 16
    ldr x9, [x16]
    mov x10, x9
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs r2_invalid
    mov x10, x9
    ARM_IMM x11, 24
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g4_publication_profile + G4_DEFINITIONS
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x0, x19
    ARM_ADDR x16, g4_manifest_feature_fields
    mov x1, x16
    ARM_IMM w2, 2
    ARM_IMM w3, 2
    ARM_CALL r2_keys
    mov x0, x19
    ARM_ADDR x16, r2_k_name
    mov x1, x16
    ARM_CALL r2_required
    mov x0, x9
    ARM_ADDR x16, g4_parser_text
    mov x1, x16
    ARM_IMM w2, 33
    ARM_CALL r2_string
    ARM_ADDR x16, g4_parser_text
    mov x1, x16
    ARM_CALL g4_parser_pool
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_invalid
    mov x16, x21
    str x9, [x16]
    mov x0, x19
    ARM_ADDR x16, g4_key_members
    mov x1, x16
    ARM_CALL r2_required
    mov x0, x9
    mov x1, x21
    ARM_IMM w2, 138
    ARM_CALL g4_json_array
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq .Lg4m_feature_accept
    mov x0, x24
    mov x16, x21
    ldr x1, [x16]
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.pl r2_invalid
.Lg4m_feature_accept:
    mov x16, x21
    ldr x24, [x16]
    ARM_ADDR x16, g4_publication_profile + 16
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, g4_publication_profile + 16
    str x10, [x16]
    mov x16, x19
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    b .Lg4m_definition
.Lg4m_validate:
    ARM_ADDR x16, g4_publication_profile
    mov x0, x16
    ARM_ADDR x16, r2_dependencies
    mov x1, x16
    ARM_ADDR x16, r2_dependency_count
    ldr x2, [x16]
    ARM_CALL g4_parser_validate
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_invalid
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=boolean token. x9=0/1; other types are invalid, never truthy. */
g4_json_bool:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_TRUE
    cmp x10, x11
    b.eq .Lg4_json_true
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_FALSE
    cmp x10, x11
    b.ne r2_invalid
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret
.Lg4_json_true:
    ARM_IMM w9, 1
    ret

/* x0=array token,x1=option/definition24,w2=string capacity<=138.
 * Writes owned canonical sorted NUL list at8/count16. Empty lists use NULL.
 * Never modifies JSON token or input buffers. Stack 96 plus callees. */
g4_json_array:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne r2_invalid
    mov w21, w2
    mov x22, x1
    mov x16, x0
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x0
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x19, x16
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
    ARM_IMM x10, 0
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM x10, 0
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    str x10, [x16]
.Lg4_json_array_next:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x19
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x11, x23
    cmp x10, x11
    b.hs .Lg4_json_array_done
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs r2_invalid
    mov x0, x19
    ARM_ADDR x16, g4_parser_text
    mov x1, x16
    mov w2, w21
    ARM_CALL r2_string
    ARM_ADDR x16, g4_parser_text
    mov x1, x16
    ARM_CALL g4_parser_pool
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_invalid
    mov x20, x9
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq .Lg4_json_array_first
    mov x0, x24
    mov x1, x20
    ARM_CALL r2_lex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.pl r2_invalid
    b .Lg4_json_array_accept
.Lg4_json_array_first:
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    str x20, [x16]
.Lg4_json_array_accept:
    mov x24, x20
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    str x10, [x16]
    mov x16, x19
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    b .Lg4_json_array_next
.Lg4_json_array_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=records in project layout, x1=count0..64. w9=0 when identical to the
 * latest parsed source declarations,1 otherwise. Compares strings, not padding.
 * Preserves callee registers; Stack 48 plus streq. Reads no archive or file. */
g3_compare_dependencies:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x1
    mov x10, x22
    ARM_ADDR x16, g3_project_dep_count
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lg3c_bad
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lg3c_next:
    mov x10, x19
    mov x11, x22
    cmp x10, x11
    b.hs .Lg3c_ok
    mov x10, x19
    ARM_IMM x11, G3_PROJECT_DEP_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_project_deps
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    mov x16, x21
    add x16, x16, x9
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3c_bad
    mov x10, x19
    ARM_IMM x11, G3_PROJECT_DEP_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, g3_project_deps + 105
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    mov x16, x21
    add x16, x16, x9
    ARM_IMM x17, 105
    add x16, x16, x17
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lg3c_bad
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lg3c_next
.Lg3c_ok:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lg3c_return
.Lg3c_bad:
    ARM_IMM w9, 1
.Lg3c_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=expected records240,x1=count,x2=expected complete profile.
 * EAX0 same/1different versus latest parsed archived source. Stack 48. */
g4_compare_project:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x2
    mov x22, x1
    ARM_CALL g3_compare_dependencies
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lg4_compare_return
    ARM_ADDR x16, g4_project_profile
    mov x0, x16
    mov x1, x21
    mov x2, x22
    ARM_CALL g4_profile_equal
.Lg4_compare_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

.section .rodata
g3_project_dependency_section: .asciz "dependencies"
g3_project_feature_section: .asciz "features"
g3_project_resolution_section: .asciz "resolution"
g3_project_zero: .asciz "0.0.0"
g3_manifest_requirement: .asciz "requirement"
g4_key_version: .asciz "version"
g4_key_optional: .asciz "optional"
g4_key_source_defaults: .asciz "default-features"
g4_key_json_defaults: .asciz "default_features"
g4_key_members: .asciz "members"
g4_true: .asciz "true"
g4_false: .asciz "false"
g3_manifest_fields: .asciz "name\0requirement\0optional\0default_features\0features\0"
g4_manifest_feature_fields: .asciz "members\0name\0"
.section .bss
.p2align 3
g3_project_dep_count: .skip 8
g3_project_deps: .skip 64 * 240
g4_project_profile: .skip G4_PROFILE_SIZE
g4_publication_profile: .skip G4_PROFILE_SIZE
g4_parser_profile: .skip 8
g4_parser_pairs: .skip 64 * 16
g4_array_pointers: .skip 64 * 8
g4_array_count: .skip 8
g4_array_start: .skip 8
g4_array_buffer: .skip G4_TEXT_BYTES
g3_project_section: .skip 64
g4_parser_key: .skip 33
g4_parser_text: .skip 138
