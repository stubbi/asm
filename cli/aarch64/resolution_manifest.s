/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Strict dependency metadata and numeric version ranges. All runtime logic is
 * native assembly. See LICENSING.md for the platform license scope.
 */
.equ RM_LINK, 73792
.equ RM_LIBRARIES, 73800
.equ RM_CHECK, 73808
.equ RM_SIZE, 73816
.equ RM_DEPS, 64
.equ RM_FEATURES, 36928
.equ RM_STRIDE, 576
.equ RM_VERSION_LIMIT, 63
.global rm_parse_manifest, rm_range_matches, rm_valid_range
.section .text
/* x0=mutable NUL manifest <=16384 bytes; x1=owned RM_SIZE-byte result.
 * x9=0 success,1 invalid. Strings borrow the input; caller retains its bytes.
 * Extension manifests are <=8190 bytes. Header: extension,deps,features at
 * 0,8,16; name/version/source/target pointers at24,32,40,48. Dependency records
 * at64: name,range,optional,defaults,count,pointers[64]. Feature records at36928:
 * name,count,pointers[64]; +528/+536 are private traversal state. Stride576.
 * Optional native-link pointers follow at RM_LINK/RM_LIBRARIES/RM_CHECK.
 * Absent optional values borrow rm_empty. Field capacities include NUL:256.
 * Preserves x19-x24. Uses 96 local stack bytes, plus ARM_CALL frames.
 * Feature traversal adds at most 64 frames of 48 bytes. No file or process effects.
 */
rm_parse_manifest:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x22, x1
    ARM_ADDR x16, rm_input
    str x0, [x16]
    ARM_ADDR x16, rm_output
    str x1, [x16]
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
    ARM_IMM w10, 1
    mov w2, w10
.Lrm_preflight:
    mov x16, x21
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_preflight_done
    ARM_IMM w11, 16384
    cmp w3, w11
    b.hs .Lrm_bad
    uxtb w10, w9
    ARM_IMM w11, 127
    cmp w10, w11
    b.hs .Lrm_not_ascii
    uxtb w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.hs .Lrm_preflight_next
    uxtb w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.eq .Lrm_preflight_next
    uxtb w10, w9
    ARM_IMM w11, 10
    cmp w10, w11
    b.eq .Lrm_preflight_next
    uxtb w10, w9
    ARM_IMM w11, 13
    cmp w10, w11
    b.ne .Lrm_not_ascii
    mov x16, x21
    add x16, x16, x3
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 10
    cmp w10, w11
    b.eq .Lrm_preflight_next
.Lrm_not_ascii:
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
.Lrm_preflight_next:
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    b .Lrm_preflight
.Lrm_preflight_done:
    ARM_ADDR x16, rm_ascii
    str x2, [x16]
    ARM_ADDR x16, rm_input_length
    str x3, [x16]
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    mov x0, x1
    ARM_IMM w10, RM_SIZE/8
    mov w3, w10
    cbz x3, .Lrm_arm_zero_done1
.Lrm_arm_zero1:
    str x9, [x0], #8
    sub x3, x3, #1
    cbnz x3, .Lrm_arm_zero1
.Lrm_arm_zero_done1:
    ARM_ADDR x10, rm_empty
    ARM_IMM x17, RM_LINK
    add x16, x22, x17
    str x10, [x16]
    str x10, [x16, #8]
    str x10, [x16, #16]
    eor w12, w23, w23
    tst w12, w12
    mov w23, w12 /* section */
    eor w12, w24, w24
    tst w12, w12
    mov w24, w12 /* section mask */
    eor w12, w19, w19
    tst w12, w12
    mov w19, w12 /* scalar mask */
.Lrm_line:
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_finish
    uxtb w10, w9
    ARM_IMM w11, 10
    cmp w10, w11
    b.eq .Lrm_next
    uxtb w10, w9
    ARM_IMM w11, 35
    cmp w10, w11
    b.eq .Lrm_comment
    uxtb w10, w9
    ARM_IMM w11, 91
    cmp w10, w11
    b.eq .Lrm_section
    ARM_IMM w11, 4
    cmp w23, w11
    b.eq .Lrm_dependency
    ARM_IMM w11, 5
    cmp w23, w11
    b.eq .Lrm_feature
    ARM_CALL rm_key_identifier
    tst w9, w9
    b.eq .Lrm_bad
    ARM_IMM w10, 61
    mov w0, w10
    ARM_CALL rm_expect
    tst w9, w9
    b.eq .Lrm_bad
    ARM_CALL rm_string
    tst x9, x9
    b.eq .Lrm_bad
    mov x20, x9
    ARM_IMM w11, 3
    cmp w23, w11
    b.eq .Lrm_schema
    ARM_IMM w11, 1
    cmp w23, w11
    b.eq .Lrm_package
    ARM_IMM w11, 2
    cmp w23, w11
    b.ne .Lrm_bad
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_source
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_source
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_target
    mov x1, x16
    ARM_CALL streq
    cbnz w9, .Lrm_target
    ARM_ADDR x0, rm_key
    ARM_ADDR x1, rm_link
    ARM_CALL streq
    cbnz w9, .Lrm_link
    ARM_ADDR x0, rm_key
    ARM_ADDR x1, rm_libraries
    ARM_CALL streq
    cbnz w9, .Lrm_libraries
    ARM_ADDR x0, rm_key
    ARM_ADDR x1, rm_check
    ARM_CALL streq
    cbnz w9, .Lrm_check
    b .Lrm_bad
.Lrm_link:
    ldrb w10, [x20]
    cbz w10, .Lrm_bad
    mov w2, #32
    ARM_IMM x3, RM_LINK
    b .Lrm_scalar
.Lrm_libraries:
    ldrb w10, [x20]
    cbz w10, .Lrm_bad
    mov w2, #64
    ARM_IMM x3, RM_LIBRARIES
    b .Lrm_scalar
.Lrm_check:
    ldrb w10, [x20]
    cbz w10, .Lrm_bad
    mov w2, #128
    ARM_IMM x3, RM_CHECK
    b .Lrm_scalar
.Lrm_target:
    ARM_IMM w10, 8
    mov w2, w10
    ARM_IMM w10, 48
    mov w3, w10
    b .Lrm_scalar
.Lrm_source:
    ARM_IMM w10, 4
    mov w2, w10
    ARM_IMM w10, 40
    mov w3, w10
    b .Lrm_scalar
.Lrm_package:
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_name
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_name
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_version
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq .Lrm_bad
    ARM_IMM w10, 2
    mov w2, w10
    ARM_IMM w10, 32
    mov w3, w10
    b .Lrm_scalar
.Lrm_name:
    ARM_IMM w10, 1
    mov w2, w10
    ARM_IMM w10, 24
    mov w3, w10
.Lrm_scalar:
    tst w19, w2
    b.ne .Lrm_bad
    orr w12, w19, w2
    tst w12, w12
    mov w19, w12
    mov x16, x22
    add x16, x16, x3
    str x20, [x16]
    b .Lrm_line_end
.Lrm_schema:
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_schema
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq .Lrm_bad
    mov x16, x20
    ldrh w10, [x16]
    ARM_IMM w11, 0x31
    cmp w10, w11
    b.ne .Lrm_bad
    ARM_IMM w11, 16
    tst w19, w11
    b.ne .Lrm_bad
    ARM_IMM w11, 16
    orr w12, w19, w11
    tst w12, w12
    mov w19, w12
    ARM_IMM x10, 1
    mov x16, x22
    str x10, [x16]
    b .Lrm_line_end
.Lrm_section:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 97
    cmp w10, w11
    b.lo .Lrm_bad
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 122
    cmp w10, w11
    b.hi .Lrm_bad
    ARM_CALL rm_key_identifier
    tst w9, w9
    b.eq .Lrm_bad
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 93
    cmp w10, w11
    b.ne .Lrm_bad
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    ARM_ADDR x16, rm_sections
    mov x20, x16
    ARM_IMM w10, 1
    mov w23, w10
.Lrm_section_find:
    mov x16, x20
    ldr x10, [x16]
    mov x1, x10
    tst x1, x1
    b.eq .Lrm_bad
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_section_found
    ARM_IMM w11, 1
    adds w12, w23, w11
    mov w23, w12
    ARM_IMM x11, 8
    adds x12, x20, x11
    mov x20, x12
    b .Lrm_section_find
.Lrm_section_found:
    mov w3, w23
    ARM_IMM w11, 1
    subs w12, w3, w11
    mov w3, w12
    ARM_IMM w10, 1
    mov w9, w10
    uxtb w11, w3
    lsl w12, w9, w11
    tst w12, w12
    mov w9, w12
    tst w24, w9
    b.ne .Lrm_bad
    orr w12, w24, w9
    tst w12, w12
    mov w24, w12
    b .Lrm_line_end
.Lrm_dependency:
    ARM_CALL rm_string
    tst x9, x9
    b.eq .Lrm_bad
    mov x20, x9
    mov x0, x9
    ARM_CALL registry_valid_package
    tst w9, w9
    b.eq .Lrm_bad
    mov x0, x20
    ARM_CALL rm_find_dep
    tst x9, x9
    b.ne .Lrm_bad
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 64
    cmp x9, x11
    b.hs .Lrm_bad
    ARM_IMM x11, RM_STRIDE
    mul x12, x9, x11
    mov x9, x12
    mov x16, x22
    add x16, x16, x9
    ARM_IMM x17, RM_DEPS
    add x16, x16, x17
    mov x20, x16
    mov x16, x20
    str x0, [x16]
    ARM_IMM x10, 1
    mov x16, x20
    ARM_IMM x17, 24
    add x16, x16, x17
    str x10, [x16]
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    mov x16, x22
    ARM_IMM x17, 8
    add x16, x16, x17
    str x12, [x16]
    ARM_IMM w10, 61
    mov w0, w10
    ARM_CALL rm_expect
    tst w9, w9
    b.eq .Lrm_bad
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 123
    cmp w10, w11
    b.eq .Lrm_inline
    ARM_CALL rm_string
    tst x9, x9
    b.eq .Lrm_bad
    mov x16, x20
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x0, x9
    ARM_CALL rm_valid_range
    tst w9, w9
    b.eq .Lrm_bad
    b .Lrm_line_end
.Lrm_inline:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    ARM_IMM x10, 0
    ARM_ADDR x16, rm_table_fields
    str x10, [x16]
.Lrm_inline_field:
    ARM_CALL rm_key_identifier
    tst w9, w9
    b.eq .Lrm_bad
    ARM_IMM w10, 61
    mov w0, w10
    ARM_CALL rm_expect
    tst w9, w9
    b.eq .Lrm_bad
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_version
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_inline_version
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_optional
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_inline_optional
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_defaults
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_inline_defaults
    ARM_ADDR x16, rm_key
    mov x0, x16
    ARM_ADDR x16, rm_features
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq .Lrm_bad
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    ARM_IMM x11, 8
    tst x10, x11
    b.ne .Lrm_bad
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    ARM_IMM x11, 8
    orr x12, x10, x11
    tst x12, x12
    ARM_ADDR x16, rm_table_fields
    str x12, [x16]
    mov x16, x20
    ARM_IMM x17, 40
    add x16, x16, x17
    mov x0, x16
    ARM_CALL rm_array
    ARM_IMM x11, -1
    cmp x9, x11
    b.eq .Lrm_bad
    mov x16, x20
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
.Lrm_dep_feature_name:
    mov x16, x20
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x11, [x16]
    cmp x2, x11
    b.hs .Lrm_inline_end
    mov x16, x20
    add x16, x16, x2, lsl #3
    ARM_IMM x17, 40
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_SAVE x2
    ARM_CALL rm_valid_feature
    ARM_RESTORE x2
    tst w9, w9
    b.eq .Lrm_bad
    ARM_IMM w11, 1
    adds w12, w2, w11
    mov w2, w12
    b .Lrm_dep_feature_name
.Lrm_inline_version:
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    ARM_IMM x11, 1
    tst x10, x11
    b.ne .Lrm_bad
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    ARM_IMM x11, 1
    orr x12, x10, x11
    tst x12, x12
    ARM_ADDR x16, rm_table_fields
    str x12, [x16]
    ARM_CALL rm_string
    tst x9, x9
    b.eq .Lrm_bad
    mov x16, x20
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x0, x9
    ARM_CALL rm_valid_range
    tst w9, w9
    b.eq .Lrm_bad
    b .Lrm_inline_end
.Lrm_inline_optional:
    ARM_IMM w10, 2
    mov w2, w10
    ARM_IMM w10, 16
    mov w3, w10
    b .Lrm_inline_bool
.Lrm_inline_defaults:
    ARM_IMM w10, 4
    mov w2, w10
    ARM_IMM w10, 24
    mov w3, w10
.Lrm_inline_bool:
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    tst x10, x2
    b.ne .Lrm_bad
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    orr x12, x10, x2
    tst x12, x12
    ARM_ADDR x16, rm_table_fields
    str x12, [x16]
    ARM_SAVE x3
    ARM_CALL rm_bool
    ARM_RESTORE x3
    ARM_IMM x11, -1
    cmp x9, x11
    b.eq .Lrm_bad
    mov x16, x20
    add x16, x16, x3
    str x9, [x16]
.Lrm_inline_end:
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    uxtb w10, w9
    ARM_IMM w11, 125
    cmp w10, w11
    b.eq .Lrm_inline_done
    uxtb w10, w9
    ARM_IMM w11, 44
    cmp w10, w11
    b.ne .Lrm_bad
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 125
    cmp w10, w11
    b.eq .Lrm_bad
    b .Lrm_inline_field
.Lrm_inline_done:
    ARM_ADDR x16, rm_table_fields
    ldr x10, [x16]
    ARM_IMM x11, 1
    tst x10, x11
    b.eq .Lrm_bad
    b .Lrm_line_end
.Lrm_feature:
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 64
    cmp x10, x11
    b.hs .Lrm_bad
    ARM_CALL rm_horizontal
    ARM_IMM x10, 0
    ARM_ADDR x16, rm_feature_equal
    str x10, [x16]
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 34
    cmp w10, w11
    b.eq .Lrm_feature_quoted
    mov x20, x21
    ARM_CALL rm_key_identifier
    tst w9, w9
    b.eq .Lrm_bad
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.eq .Lrm_feature_bare_end
    uxtb w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.eq .Lrm_feature_bare_end
    uxtb w10, w9
    ARM_IMM w11, 61
    cmp w10, w11
    b.ne .Lrm_bad
    ARM_IMM x10, 1
    ARM_ADDR x16, rm_feature_equal
    str x10, [x16]
.Lrm_feature_bare_end:
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    mov x9, x20
    b .Lrm_feature_key
.Lrm_feature_quoted:
    ARM_CALL rm_string
    tst x9, x9
    b.eq .Lrm_bad
.Lrm_feature_key:
    mov x20, x9
    mov x0, x9
    ARM_CALL rm_valid_feature
    tst w9, w9
    b.eq .Lrm_bad
    mov x0, x20
    ARM_CALL rm_find_feature
    tst x9, x9
    b.ne .Lrm_bad
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, RM_STRIDE
    mul x12, x9, x11
    mov x9, x12
    mov x16, x22
    add x16, x16, x9
    ARM_IMM x17, RM_FEATURES
    add x16, x16, x17
    mov x9, x16
    mov x16, x9
    str x20, [x16]
    mov x20, x9
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    str x12, [x16]
    ARM_ADDR x16, rm_feature_equal
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.eq .Lrm_feature_array
    ARM_IMM w10, 61
    mov w0, w10
    ARM_CALL rm_expect
    tst w9, w9
    b.eq .Lrm_bad
.Lrm_feature_array:
    mov x16, x20
    ARM_IMM x17, 16
    add x16, x16, x17
    mov x0, x16
    ARM_CALL rm_array
    ARM_IMM x11, -1
    cmp x9, x11
    b.eq .Lrm_bad
    mov x16, x20
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
.Lrm_line_end:
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_finish
    uxtb w10, w9
    ARM_IMM w11, 35
    cmp w10, w11
    b.eq .Lrm_comment
    uxtb w10, w9
    ARM_IMM w11, 10
    cmp w10, w11
    b.ne .Lrm_bad
.Lrm_next:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrm_line
.Lrm_comment:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_finish
    uxtb w10, w9
    ARM_IMM w11, 10
    cmp w10, w11
    b.eq .Lrm_next
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrm_comment
.Lrm_finish:
    mov w9, w19
    ARM_IMM w11, 15
    ands w12, w9, w11
    mov w9, w12
    ARM_IMM w11, 15
    cmp w9, w11
    b.ne .Lrm_bad
    mov x9, x21
    ARM_ADDR x16, rm_input
    ldr x11, [x16]
    subs x12, x9, x11
    mov x9, x12
    ARM_IMM x11, 16384
    cmp x9, x11
    b.hi .Lrm_bad
    ARM_IMM w11, 28
    tst w24, w11
    b.eq .Lrm_scalars_valid
    ARM_IMM w11, 16
    tst w19, w11
    b.eq .Lrm_bad
    ARM_IMM x11, 8190
    cmp x9, x11
    b.hi .Lrm_bad
    ARM_ADDR x16, rm_ascii
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lrm_bad
.Lrm_scalars_valid:
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL valid_name
    tst w9, w9
    b.eq .Lrm_bad
    mov x16, x22
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    cmp x9, #RM_VERSION_LIMIT
    b.hi .Lrm_bad
    ldr x0, [x22, #32]
    mov x16, x22
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lrm_strict_version
    ARM_CALL valid_version
    b .Lrm_version_checked
.Lrm_strict_version:
    ARM_CALL registry_valid_version
.Lrm_version_checked:
    tst w9, w9
    b.eq .Lrm_bad
    mov x16, x22
    ARM_IMM x17, 40
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL valid_source
    tst w9, w9
    b.eq .Lrm_bad
    mov x16, x22
    ARM_IMM x17, 48
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_target
    tst w9, w9
    b.eq .Lrm_bad
    ARM_IMM x17, RM_LINK
    add x16, x22, x17
    ldr x0, [x16]
    ldr x1, [x16, #8]
    ldr x2, [x16, #16]
    ARM_CALL native_link_validate
    cbz w9, .Lrm_bad
    eor w12, w20, w20
    tst w12, w12
    mov w20, w12
.Lrm_feature_check:
    mov x16, x22
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x20, x11
    b.hs .Lrm_good
    ARM_IMM x11, RM_STRIDE
    mul x12, x20, x11
    mov x9, x12
    mov x16, x22
    add x16, x16, x9
    ARM_IMM x17, RM_FEATURES
    add x16, x16, x17
    mov x0, x16
    ARM_CALL rm_feature_visit
    tst w9, w9
    b.eq .Lrm_bad
    ARM_IMM w11, 1
    adds w12, w20, w11
    mov w20, w12
    b .Lrm_feature_check
.Lrm_good:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    b .Lrm_return
.Lrm_bad:
    ARM_IMM w10, 1
    mov w9, w10
.Lrm_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Parser helpers deliberately advance x21. Other callee registers preserved.
 * Input is a bounded copied NUL buffer. No helper crosses a string terminator. */
rm_horizontal:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.eq .Lrm_hnext
    uxtb w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.eq .Lrm_hnext
    uxtb w10, w9
    ARM_IMM w11, 13
    cmp w10, w11
    b.ne .Lrm_hdone
.Lrm_hnext:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b rm_horizontal
.Lrm_hdone:
    ret
rm_expect:
    mov w2, w0
    ARM_CALL rm_horizontal
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    mov x16, x21
    ldrb w10, [x16]
    uxtb w11, w2
    cmp w10, w11
    b.ne .Lrm_expect_done
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    ARM_IMM w10, 1
    mov w9, w10
.Lrm_expect_done:
    ret
rm_key_identifier:
    ARM_CALL rm_horizontal
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
    ARM_ADDR x16, rm_key
    mov x0, x16
.Lrm_key_char:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 97
    cmp w10, w11
    b.lo .Lrm_key_extra
    uxtb w10, w9
    ARM_IMM w11, 122
    cmp w10, w11
    b.ls .Lrm_key_copy
.Lrm_key_extra:
    tst w3, w3
    b.eq .Lrm_key_end
    uxtb w10, w9
    ARM_IMM w11, 48
    cmp w10, w11
    b.lo .Lrm_key_punct
    uxtb w10, w9
    ARM_IMM w11, 57
    cmp w10, w11
    b.ls .Lrm_key_copy
.Lrm_key_punct:
    uxtb w10, w9
    ARM_IMM w11, 45
    cmp w10, w11
    b.eq .Lrm_key_copy
    uxtb w10, w9
    ARM_IMM w11, 95
    cmp w10, w11
    b.ne .Lrm_key_end
.Lrm_key_copy:
    ARM_IMM w11, 32
    cmp w3, w11
    b.hs .Lrm_key_bad
    uxtb w10, w9
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrm_key_char
.Lrm_key_end:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    tst w3, w3
    cset w10, ne
    bfi x9, x10, #0, #8
    ret
.Lrm_key_bad:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    ret
rm_string:
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 34
    cmp w10, w11
    b.ne .Lrm_string_bad
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    mov x0, x21
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrm_string_char:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 34
    cmp w10, w11
    b.eq .Lrm_string_end
    uxtb w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.lo .Lrm_string_bad
    uxtb w10, w9
    ARM_IMM w11, 126
    cmp w10, w11
    b.hi .Lrm_string_bad
    uxtb w10, w9
    ARM_IMM w11, 92
    cmp w10, w11
    b.eq .Lrm_string_bad
    ARM_IMM w11, 255
    cmp w3, w11
    b.hs .Lrm_string_bad
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrm_string_char
.Lrm_string_end:
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    mov x9, x0
    ret
.Lrm_string_bad:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    ret
rm_bool:
    ARM_CALL rm_horizontal
    ARM_ADDR x16, rm_true
    mov x1, x16
    ARM_IMM w10, 1
    mov w2, w10
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 116
    cmp w10, w11
    b.eq .Lrm_bool_scan
    ARM_ADDR x16, rm_false
    mov x1, x16
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
.Lrm_bool_scan:
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrm_bool_char:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_bool_end
    uxtb w10, w9
    mov x16, x21
    add x16, x16, x3
    ldrb w11, [x16]
    cmp w10, w11
    b.ne .Lrm_bool_bad
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    b .Lrm_bool_char
.Lrm_bool_end:
    adds x12, x21, x3
    mov x21, x12
    mov w9, w2
    ret
.Lrm_bool_bad:
    ARM_IMM x10, -1
    mov x9, x10
    ret
/* x0=array[64] result. x9=count or-1. Reject duplicate strings. */
rm_array:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x22
    ARM_SAVE x23
    mov x19, x0
    eor w12, w20, w20
    tst w12, w12
    mov w20, w12
    ARM_IMM w10, 91
    mov w0, w10
    ARM_CALL rm_expect
    tst w9, w9
    b.eq .Lrm_array_bad
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 93
    cmp w10, w11
    b.eq .Lrm_array_empty
.Lrm_array_item:
    ARM_IMM w11, 64
    cmp w20, w11
    b.hs .Lrm_array_bad
    ARM_CALL rm_string
    tst x9, x9
    b.eq .Lrm_array_bad
    mov x22, x9
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lrm_array_bad
    eor w12, w23, w23
    tst w12, w12
    mov w23, w12
.Lrm_array_duplicate:
    cmp w23, w20
    b.hs .Lrm_array_store
    mov x0, x22
    mov x16, x19
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_array_bad
    ARM_IMM w11, 1
    adds w12, w23, w11
    mov w23, w12
    b .Lrm_array_duplicate
.Lrm_array_store:
    mov x16, x19
    add x16, x16, x20, lsl #3
    str x22, [x16]
    ARM_IMM w11, 1
    adds w12, w20, w11
    mov w20, w12
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    uxtb w10, w9
    ARM_IMM w11, 93
    cmp w10, w11
    b.eq .Lrm_array_done
    uxtb w10, w9
    ARM_IMM w11, 44
    cmp w10, w11
    b.ne .Lrm_array_bad
    ARM_CALL rm_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 93
    cmp w10, w11
    b.eq .Lrm_array_empty /* TOML permits one trailing array comma. */
    b .Lrm_array_item
.Lrm_array_empty:
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
.Lrm_array_done:
    mov w9, w20
    b .Lrm_array_return
.Lrm_array_bad:
    ARM_IMM x10, -1
    mov x9, x10
.Lrm_array_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x0=feature identifier. x9=1/0. Max32 ASCII bytes. */
rm_valid_feature:
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrm_feature_char:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_feature_end
    ARM_IMM w11, 32
    cmp w3, w11
    b.hs .Lrm_feature_invalid
    uxtb w10, w9
    ARM_IMM w11, 97
    cmp w10, w11
    b.lo .Lrm_feature_extra
    uxtb w10, w9
    ARM_IMM w11, 122
    cmp w10, w11
    b.ls .Lrm_feature_next
.Lrm_feature_extra:
    tst w3, w3
    b.eq .Lrm_feature_invalid
    uxtb w10, w9
    ARM_IMM w11, 48
    cmp w10, w11
    b.lo .Lrm_feature_punct
    uxtb w10, w9
    ARM_IMM w11, 57
    cmp w10, w11
    b.ls .Lrm_feature_next
.Lrm_feature_punct:
    uxtb w10, w9
    ARM_IMM w11, 95
    cmp w10, w11
    b.eq .Lrm_feature_next
    uxtb w10, w9
    ARM_IMM w11, 45
    cmp w10, w11
    b.ne .Lrm_feature_invalid
.Lrm_feature_next:
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    b .Lrm_feature_char
.Lrm_feature_end:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    tst w3, w3
    cset w10, ne
    bfi x9, x10, #0, #8
    ret
.Lrm_feature_invalid:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    ret
/* x0=name; global rm_output is current owned result. x9=record or0.
 * x0 remains the input on return. Other argument registers are scratch. */
rm_find_dep:
    ARM_ADDR x16, rm_output
    ldr x10, [x16]
    mov x1, x10
    mov x16, x1
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    ARM_IMM x11, RM_DEPS
    adds x12, x1, x11
    mov x1, x12
    b rm_find_record
rm_find_feature:
    ARM_ADDR x16, rm_output
    ldr x10, [x16]
    mov x1, x10
    mov x16, x1
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    ARM_IMM x11, RM_FEATURES
    adds x12, x1, x11
    mov x1, x12
rm_find_record:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x22
    mov x19, x0
    mov x20, x1
    mov x22, x2
.Lrm_find_loop:
    tst x22, x22
    b.eq .Lrm_find_absent
    mov x0, x19
    mov x16, x20
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrm_find_found
    ARM_IMM x11, RM_STRIDE
    adds x12, x20, x11
    mov x20, x12
    ARM_IMM x11, 1
    subs x12, x22, x11
    mov x22, x12
    b .Lrm_find_loop
.Lrm_find_absent:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    b .Lrm_find_return
.Lrm_find_found:
    mov x9, x20
.Lrm_find_return:
    mov x0, x19
    ARM_RESTORE x22
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x0=feature record. x9=1 valid,0 invalid/reference cycle. DFS depth<=64.
 * Local reference scratch is not retained across recursive calls. */
rm_feature_visit:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x22
    mov x19, x0
    mov x16, x19
    ARM_IMM x17, 536
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 2
    cmp x10, x11
    b.eq .Lrm_visit_good
    mov x16, x19
    ARM_IMM x17, 536
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.eq .Lrm_visit_bad
    ARM_IMM x10, 1
    mov x16, x19
    ARM_IMM x17, 536
    add x16, x16, x17
    str x10, [x16]
    eor w12, w20, w20
    tst w12, w12
    mov w20, w12
.Lrm_visit_item:
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x11, [x16]
    cmp x20, x11
    b.hs .Lrm_visit_complete
    mov x16, x19
    add x16, x16, x20, lsl #3
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    mov x22, x10
    ARM_ADDR x16, rm_reference
    mov x0, x16
    mov x1, x22
    ARM_CALL copy_string
    ARM_ADDR x16, rm_reference
    mov x22, x16
    mov x16, x22
    ldr w10, [x16]
    ARM_IMM w11, 0x3a706564
    cmp w10, w11 /* dep: */
    b.eq .Lrm_visit_optional
    mov x0, x22
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
.Lrm_visit_slash:
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrm_visit_classify
    uxtb w10, w9
    ARM_IMM w11, 47
    cmp w10, w11
    b.ne .Lrm_visit_slash_next
    mov x2, x0
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
.Lrm_visit_slash_next:
    ARM_IMM x11, 1
    adds x12, x0, x11
    mov x0, x12
    b .Lrm_visit_slash
.Lrm_visit_classify:
    tst w3, w3
    b.eq .Lrm_visit_own
    ARM_IMM w11, 2
    cmp w3, w11
    b.ne .Lrm_visit_bad
    ARM_IMM w10, 0
    mov x16, x2
    strb w10, [x16]
    mov x16, x2
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_CALL rm_valid_feature
    tst w9, w9
    b.eq .Lrm_visit_bad
    mov x0, x22
    ARM_CALL rm_find_dep
    tst x9, x9
    b.eq .Lrm_visit_bad
    b .Lrm_visit_next
.Lrm_visit_optional:
    mov x16, x22
    ARM_IMM x17, 4
    add x16, x16, x17
    mov x0, x16
    ARM_CALL rm_find_dep
    tst x9, x9
    b.eq .Lrm_visit_bad
    mov x16, x9
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lrm_visit_bad
    b .Lrm_visit_next
.Lrm_visit_own:
    mov x0, x22
    ARM_CALL rm_valid_feature
    tst w9, w9
    b.eq .Lrm_visit_bad
    mov x0, x22
    ARM_CALL rm_find_feature
    tst x9, x9
    b.eq .Lrm_visit_bad
    mov x0, x9
    ARM_CALL rm_feature_visit
    tst w9, w9
    b.eq .Lrm_visit_bad
.Lrm_visit_next:
    ARM_IMM w11, 1
    adds w12, w20, w11
    mov w20, w12
    b .Lrm_visit_item
.Lrm_visit_complete:
    ARM_IMM x10, 2
    mov x16, x19
    ARM_IMM x17, 536
    add x16, x16, x17
    str x10, [x16]
.Lrm_visit_good:
    ARM_IMM w10, 1
    mov w9, w10
    b .Lrm_visit_return
.Lrm_visit_bad:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
.Lrm_visit_return:
    ARM_RESTORE x22
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

.section .rodata
rm_sections: .quad rm_package,rm_build,rm_resolution,rm_dependencies,rm_features,0
rm_package: .asciz "package"
rm_build: .asciz "build"
rm_resolution: .asciz "resolution"
rm_dependencies: .asciz "dependencies"
rm_features: .asciz "features"
rm_link: .asciz "link"
rm_libraries: .asciz "libraries"
rm_check: .asciz "check"
rm_empty: .asciz ""
rm_name: .asciz "name"
rm_version: .asciz "version"
rm_source: .asciz "source"
rm_target: .asciz "target"
rm_schema: .asciz "schema"
rm_optional: .asciz "optional"
rm_defaults: .asciz "default-features"
rm_true: .asciz "true"
rm_false: .asciz "false"
.section .bss
.balign 8
rm_input: .skip 8
rm_input_length: .skip 8
rm_ascii: .skip 8
rm_output: .skip 8
rm_table_fields: .skip 8
rm_feature_equal: .skip 8
rm_key: .skip 40
rm_reference: .skip 256
.section .note.GNU-stack,"",@progbits

.section .text
/* x0=range, x9=1 valid/0 invalid. No mutation of range bytes. */
rm_valid_range:
    mov x1, x0
    eor w12, w0, w0
    tst w12, w12
    mov w0, w12
    ARM_CALL rm_range_matches
    ARM_IMM x11, -1
    cmp x9, x11
    cset w10, ne
    bfi x9, x10, #0, #8
    uxtb w10, w9
    mov w9, w10
    ret
/* x0=validated numeric version or0 for syntax only; x1=range. x9=1 match,
 * 0 mismatch,-1 invalid. Supports exact,*,^,~, and <=8 explicit comparisons.
 * Max128 printable bytes, no outer whitespace or implicit partial versions.
 * Callee registers preserved; 96 local stack bytes, plus ARM_CALL frames. Owns128-byte token and
 * three numeric triplets; no file operations, recursive calls or input writes.
 */
rm_range_matches:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x23, x0
    mov x21, x1
    ARM_IMM w10, 1
    mov w22, w10
    eor w12, w24, w24
    tst w12, w12
    mov w24, w12
    mov x0, x21
    ARM_CALL strlen
    tst x9, x9
    b.eq .Lrq_bad
    ARM_IMM x11, 128
    cmp x9, x11
    b.hi .Lrq_bad
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 32
    cmp w10, w11
    b.eq .Lrq_bad
    mov x16, x21
    add x16, x16, x9
    ARM_IMM x17, -1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 32
    cmp w10, w11
    b.eq .Lrq_bad
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrq_ascii:
    cmp x3, x9
    b.hs .Lrq_start
    mov x16, x21
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 32
    cmp w10, w11
    b.lo .Lrq_bad
    mov x16, x21
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 126
    cmp w10, w11
    b.hi .Lrq_bad
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    b .Lrq_ascii
.Lrq_start:
    tst x23, x23
    b.eq .Lrq_term
    mov x0, x23
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq .Lrq_bad
    mov x0, x23
    ARM_ADDR x16, rm_range_actual
    mov x1, x16
    ARM_CALL rm_range_numbers
.Lrq_term:
    ARM_IMM w11, 1
    adds w12, w24, w11
    mov w24, w12
    ARM_IMM w11, 8
    cmp w24, w11
    b.hi .Lrq_bad
    eor w12, w20, w20
    tst w12, w12
    mov w20, w12 /*0 exact,1>=,2>,3<=,4<,5^,6~,7= */
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 42
    cmp w10, w11
    b.eq .Lrq_wildcard
    uxtb w10, w9
    ARM_IMM w11, 94
    cmp w10, w11
    b.eq .Lrq_caret
    uxtb w10, w9
    ARM_IMM w11, 126
    cmp w10, w11
    b.eq .Lrq_tilde
    uxtb w10, w9
    ARM_IMM w11, 62
    cmp w10, w11
    b.eq .Lrq_gt
    uxtb w10, w9
    ARM_IMM w11, 60
    cmp w10, w11
    b.eq .Lrq_lt
    uxtb w10, w9
    ARM_IMM w11, 61
    cmp w10, w11
    b.eq .Lrq_eq
    b .Lrq_version
.Lrq_caret:
    ARM_IMM w10, 5
    mov w20, w10
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_version
.Lrq_tilde:
    ARM_IMM w10, 6
    mov w20, w10
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_version
.Lrq_gt:
    ARM_IMM w10, 2
    mov w20, w10
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    cmp w10, w11
    b.ne .Lrq_spaces
    ARM_IMM w11, 1
    subs w12, w20, w11
    mov w20, w12
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_spaces
.Lrq_lt:
    ARM_IMM w10, 4
    mov w20, w10
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    cmp w10, w11
    b.ne .Lrq_spaces
    ARM_IMM w11, 1
    subs w12, w20, w11
    mov w20, w12
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_spaces
.Lrq_eq:
    ARM_IMM w10, 7
    mov w20, w10
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
.Lrq_spaces:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 32
    cmp w10, w11
    b.ne .Lrq_version
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_spaces
.Lrq_version:
    ARM_ADDR x16, rm_range_token
    mov x19, x16
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrq_version_char:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    uxtb w11, w9
    tst w10, w11
    b.eq .Lrq_version_end
    uxtb w10, w9
    ARM_IMM w11, 44
    cmp w10, w11
    b.eq .Lrq_version_end
    uxtb w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.eq .Lrq_version_end
    ARM_IMM w11, 32
    cmp w3, w11
    b.hs .Lrq_bad
    uxtb w10, w9
    mov x16, x19
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_version_char
.Lrq_version_end:
    ARM_IMM w10, 0
    mov x16, x19
    add x16, x16, x3
    strb w10, [x16]
    mov x0, x19
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq .Lrq_bad
    tst x23, x23
    b.eq .Lrq_next
    mov x0, x19
    ARM_ADDR x16, rm_range_term
    mov x1, x16
    ARM_CALL rm_range_numbers
    ARM_ADDR x16, rm_range_actual
    mov x0, x16
    ARM_ADDR x16, rm_range_term
    mov x1, x16
    ARM_CALL rm_range_compare
    ARM_IMM w11, 0
    cmp w20, w11
    b.eq .Lrq_exact
    ARM_IMM w11, 7
    cmp w20, w11
    b.eq .Lrq_exact
    ARM_IMM w11, 1
    cmp w20, w11
    b.eq .Lrq_ge
    ARM_IMM w11, 2
    cmp w20, w11
    b.eq .Lrq_greater
    ARM_IMM w11, 3
    cmp w20, w11
    b.eq .Lrq_le
    ARM_IMM w11, 4
    cmp w20, w11
    b.eq .Lrq_less
    ARM_IMM w11, 0
    cmp w9, w11
    b.lt .Lrq_mismatch
    ARM_ADDR x16, rm_range_term
    mov x1, x16
    mov x16, x1
    ldr x10, [x16]
    mov x9, x10
    mov x16, x1
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x10, [x16]
    mov x3, x10
    mov x16, x1
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x10, [x16]
    mov x2, x10
    ARM_IMM w11, 6
    cmp w20, w11
    b.eq .Lrq_upper_minor
    tst x9, x9
    b.eq .Lrq_upper_zero
    ARM_IMM x11, 1
    adds x12, x9, x11
    mov x9, x12
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
    b .Lrq_upper
.Lrq_upper_zero:
    tst x3, x3
    b.ne .Lrq_upper_minor
    ARM_IMM x11, 1
    adds x12, x2, x11
    mov x2, x12
    b .Lrq_upper
.Lrq_upper_minor:
    ARM_IMM x11, 1
    adds x12, x3, x11
    mov x3, x12
    eor w12, w2, w2
    tst w12, w12
    mov w2, w12
.Lrq_upper:
    ARM_ADDR x16, rm_range_upper
    mov x1, x16
    mov x16, x1
    str x9, [x16]
    mov x16, x1
    ARM_IMM x17, 8
    add x16, x16, x17
    str x3, [x16]
    mov x16, x1
    ARM_IMM x17, 16
    add x16, x16, x17
    str x2, [x16]
    ARM_ADDR x16, rm_range_actual
    mov x0, x16
    ARM_CALL rm_range_compare
    tst w9, w9
    b.ge .Lrq_mismatch
    b .Lrq_next
.Lrq_exact:
    tst w9, w9
    b.ne .Lrq_mismatch
    b .Lrq_next
.Lrq_ge:
    tst w9, w9
    b.lt .Lrq_mismatch
    b .Lrq_next
.Lrq_greater:
    tst w9, w9
    b.le .Lrq_mismatch
    b .Lrq_next
.Lrq_le:
    tst w9, w9
    b.gt .Lrq_mismatch
    b .Lrq_next
.Lrq_less:
    tst w9, w9
    b.ge .Lrq_mismatch
    b .Lrq_next
.Lrq_mismatch:
    eor w12, w22, w22
    tst w12, w12
    mov w22, w12
.Lrq_next:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 32
    cmp w10, w11
    b.ne .Lrq_separator
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_next
.Lrq_separator:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Lrq_done
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 44
    cmp w10, w11
    b.ne .Lrq_bad
    ARM_IMM w11, 0
    cmp w20, w11
    b.eq .Lrq_bad
    ARM_IMM w11, 5
    cmp w20, w11
    b.eq .Lrq_bad
    ARM_IMM w11, 6
    cmp w20, w11
    b.eq .Lrq_bad
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
.Lrq_after_comma:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 32
    cmp w10, w11
    b.ne .Lrq_require_comparator
    ARM_IMM x11, 1
    adds x12, x21, x11
    mov x21, x12
    b .Lrq_after_comma
.Lrq_require_comparator:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    uxtb w10, w9
    ARM_IMM w11, 61
    cmp w10, w11
    b.eq .Lrq_term
    uxtb w10, w9
    ARM_IMM w11, 60
    cmp w10, w11
    b.eq .Lrq_term
    uxtb w10, w9
    ARM_IMM w11, 62
    cmp w10, w11
    b.eq .Lrq_term
    b .Lrq_bad
.Lrq_wildcard:
    ARM_IMM w11, 1
    cmp w24, w11
    b.ne .Lrq_bad
    mov x16, x21
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lrq_bad
.Lrq_done:
    mov w9, w22
    b .Lrq_return
.Lrq_bad:
    ARM_IMM x10, -1
    mov x9, x10
.Lrq_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x0=validated version,x1=three owned qwords. Scratch:x9,x3,x2,x4. */
rm_range_numbers:
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrq_number_component:
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
.Lrq_number_digit:
    mov x16, x0
    ldrb w10, [x16]
    mov w2, w10
    uxtb w10, w2
    ARM_IMM w11, 48
    cmp w10, w11
    b.lo .Lrq_number_store
    uxtb w10, w2
    ARM_IMM w11, 57
    cmp w10, w11
    b.hi .Lrq_number_store
    ARM_IMM w11, 48
    subs w12, w2, w11
    mov w2, w12
    ARM_IMM x11, 10
    mul x12, x9, x11
    mov x9, x12
    adds x12, x9, x2
    mov x9, x12
    ARM_IMM x11, 1
    adds x12, x0, x11
    mov x0, x12
    b .Lrq_number_digit
.Lrq_number_store:
    mov x16, x1
    add x16, x16, x3, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    ARM_IMM w11, 3
    cmp w3, w11
    b.eq .Lrq_number_done
    ARM_IMM x11, 1
    adds x12, x0, x11
    mov x0, x12
    b .Lrq_number_component
.Lrq_number_done:
    ret
/* x0/x1=three unsigned qwords. x9=-1,0,1 lexical numeric order. */
rm_range_compare:
    eor w12, w3, w3
    tst w12, w12
    mov w3, w12
.Lrq_compare:
    mov x16, x0
    add x16, x16, x3, lsl #3
    ldr x10, [x16]
    mov x9, x10
    mov x16, x1
    add x16, x16, x3, lsl #3
    ldr x11, [x16]
    cmp x9, x11
    b.lo .Lrq_cmp_less
    b.hi .Lrq_cmp_greater
    ARM_IMM w11, 1
    adds w12, w3, w11
    mov w3, w12
    ARM_IMM w11, 3
    cmp w3, w11
    b.lo .Lrq_compare
    eor w12, w9, w9
    tst w12, w12
    mov w9, w12
    ret
.Lrq_cmp_less:
    ARM_IMM x10, -1
    mov x9, x10
    ret
.Lrq_cmp_greater:
    ARM_IMM w10, 1
    mov w9, w10
    ret
.section .bss
.balign 8
rm_range_token: .skip 40
rm_range_actual: .skip 24
rm_range_term: .skip 24
rm_range_upper: .skip 24
.section .note.GNU-stack,"",@progbits
