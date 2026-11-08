/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Mandatory same-registry declarations for the optional V2 client.
 * Native internal ABI: x0-x7 inputs,x9 result; preserve x19-x24 and aligned SP.
 */
.equ G3_PROJECT_DEP_RECORD, 240
.equ G3_PROJECT_DEP_LIMIT, 64
.section .text

/* x0=NUL manifest, at most8190 ASCII bytes. w9=0 valid,1 invalid.
 * Writes64 owned records: name[105],requirement[129],six padding bytes;
 * g3_project_dep_count is the valid count. Sorts names; rejects duplicate names
 * and sections. The caller validates other project fields. Stack96 plus calls.
 */
g3_project_dependencies:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, g3_project_dep_count
    str xzr, [x16]
    mov x21, x0
    mov x3, #0
.Lg3p_bound:
    ldrb w9, [x0, x3]
    cbz w9, .Lg3p_bound_done
    ARM_IMM x10, 8190
    cmp x3, x10
    b.hs .Lg3p_bad
    cmp w9, #9
    b.eq .Lg3p_bound_next
    cmp w9, #10
    b.eq .Lg3p_bound_next
    cmp w9, #13
    b.eq .Lg3p_bound_next
    cmp w9, #32
    b.lo .Lg3p_bad
    cmp w9, #126
    b.hi .Lg3p_bad
.Lg3p_bound_next:
    add x3, x3, #1
    b .Lg3p_bound
.Lg3p_bound_done:
    cbz x3, .Lg3p_bad
    mov w22, #0
    mov w23, #0
.Lg3p_line:
    ARM_CALL g3_project_horizontal
    ldrb w9, [x21]
    cbz w9, .Lg3p_sort
    cmp w9, #10
    b.eq .Lg3p_next
    cmp w9, #'#'
    b.eq .Lg3p_skip
    cmp w9, #'['
    b.eq .Lg3p_section
    cbz w22, .Lg3p_skip
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cmp x9, #G3_PROJECT_DEP_LIMIT
    b.hs .Lg3p_bad
    mov x10, #G3_PROJECT_DEP_RECORD
    mul x9, x9, x10
    ARM_ADDR x24, g3_project_deps
    add x24, x24, x9
    mov x0, x24
    mov w1, #105
    ARM_CALL g3_project_string
    cbnz w9, .Lg3p_bad
    ARM_CALL g3_project_horizontal
    ldrb w9, [x21]
    cmp w9, #'='
    b.ne .Lg3p_bad
    add x21, x21, #1
    ARM_CALL g3_project_horizontal
    add x0, x24, #105
    mov w1, #129
    ARM_CALL g3_project_string
    cbnz w9, .Lg3p_bad
    mov x0, x24
    ARM_CALL registry_valid_package
    cbz w9, .Lg3p_bad
    add x0, x24, #105
    ARM_ADDR x1, g3_project_zero
    ARM_CALL g3_requirement
    cmn w9, #1
    b.eq .Lg3p_bad
    ARM_ADDR x19, g3_project_deps
    mov x20, #0
.Lg3p_duplicate:
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cmp x20, x9
    b.hs .Lg3p_accept
    mov x0, x19
    mov x1, x24
    ARM_CALL streq
    cbnz w9, .Lg3p_bad
    add x19, x19, #G3_PROJECT_DEP_RECORD
    add x20, x20, #1
    b .Lg3p_duplicate
.Lg3p_accept:
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    add x9, x9, #1
    str x9, [x16]
    b .Lg3p_line_end
.Lg3p_section:
    add x21, x21, #1
    ARM_ADDR x0, g3_project_section
    mov x3, #0
.Lg3p_section_byte:
    ldrb w9, [x21]
    cmp w9, #']'
    b.eq .Lg3p_section_end
    cmp w9, #32
    b.lo .Lg3p_bad
    cmp x3, #63
    b.hs .Lg3p_bad
    strb w9, [x0, x3]
    add x21, x21, #1
    add x3, x3, #1
    b .Lg3p_section_byte
.Lg3p_section_end:
    strb wzr, [x0, x3]
    add x21, x21, #1
    ARM_ADDR x1, g3_project_dependency_section
    ARM_CALL streq
    mov w22, w9
    cbz w9, .Lg3p_non_dependency
    cbnz w23, .Lg3p_bad
    mov w23, #1
    b .Lg3p_line_end
.Lg3p_non_dependency:
    ARM_ADDR x0, g3_project_section
    ARM_ADDR x1, g3_project_feature_section
    ARM_CALL streq
    cbnz w9, .Lg3p_bad
    ARM_ADDR x0, g3_project_section
    ARM_ADDR x1, g3_project_resolution_section
    ARM_CALL streq
    cbnz w9, .Lg3p_bad
.Lg3p_line_end:
    ARM_CALL g3_project_horizontal
    ldrb w9, [x21]
    cbz w9, .Lg3p_sort
    cmp w9, #'#'
    b.eq .Lg3p_skip
    cmp w9, #10
    b.ne .Lg3p_bad
.Lg3p_next:
    add x21, x21, #1
    b .Lg3p_line
.Lg3p_skip:
    ldrb w9, [x21]
    cbz w9, .Lg3p_sort
    add x21, x21, #1
    cmp w9, #10
    b.ne .Lg3p_skip
    b .Lg3p_line
.Lg3p_sort:
    mov x20, #0
.Lg3p_sort_outer:
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cmp x20, x9
    b.hs .Lg3p_ok
    mov x10, #G3_PROJECT_DEP_RECORD
    mul x9, x20, x10
    ARM_ADDR x19, g3_project_deps
    add x19, x19, x9
    add x23, x20, #1
    add x24, x19, #G3_PROJECT_DEP_RECORD
.Lg3p_sort_inner:
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cmp x23, x9
    b.hs .Lg3p_sort_next
    mov x0, x19
    mov x1, x24
    ARM_CALL r2_lex
    cmp w9, #0
    b.le .Lg3p_sort_keep
    mov x3, #0
.Lg3p_swap:
    ldr x9, [x19, x3]
    ldr x2, [x24, x3]
    str x2, [x19, x3]
    str x9, [x24, x3]
    add x3, x3, #8
    cmp x3, #G3_PROJECT_DEP_RECORD
    b.lo .Lg3p_swap
.Lg3p_sort_keep:
    add x23, x23, #1
    add x24, x24, #G3_PROJECT_DEP_RECORD
    b .Lg3p_sort_inner
.Lg3p_sort_next:
    add x20, x20, #1
    b .Lg3p_sort_outer
.Lg3p_ok:
    mov w9, #0
    b .Lg3p_return
.Lg3p_bad:
    ARM_ADDR x16, g3_project_dep_count
    str xzr, [x16]
    mov w9, #1
.Lg3p_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x21=cursor,x0=owned destination,w1=capacity including NUL.
 * w9=0 success,1 invalid; advances x21 within the bounded manifest.
 * No escapes or multiline/control bytes. Scratch x2,x3,x9,x10. */
g3_project_string:
    ldrb w9, [x21]
    cmp w9, #'"'
    b.ne .Lg3p_string_bad
    add x21, x21, #1
    mov x3, #0
    sub w1, w1, #1
.Lg3p_string_byte:
    ldrb w9, [x21]
    cmp w9, #'"'
    b.eq .Lg3p_string_end
    cmp w9, #32
    b.lo .Lg3p_string_bad
    cmp w9, #'\\'
    b.eq .Lg3p_string_bad
    cmp w3, w1
    b.hs .Lg3p_string_bad
    strb w9, [x0, x3]
    add x3, x3, #1
    add x21, x21, #1
    b .Lg3p_string_byte
.Lg3p_string_end:
    strb wzr, [x0, x3]
    add x21, x21, #1
    mov w9, #0
    ret
.Lg3p_string_bad:
    mov w9, #1
    ret

/* x21=cursor; skip horizontal whitespace and CR. Scratch w9. */
g3_project_horizontal:
    ldrb w9, [x21]
    cmp w9, #32
    b.eq .Lg3p_horizontal_next
    cmp w9, #9
    b.eq .Lg3p_horizontal_next
    cmp w9, #13
    b.ne .Lg3p_horizontal_done
.Lg3p_horizontal_next:
    add x21, x21, #1
    b g3_project_horizontal
.Lg3p_horizontal_done:
    ret

/* x0=validated publication object. Writes r2_dependencies/count in project
 * record layout. Optional array must be sorted and unique. Invalid input uses
 * the existing V2 cleanup path. Preserves x19-x24; stack80 plus callees. */
g3_manifest_dependencies:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, r2_dependency_count
    str xzr, [x16]
    ARM_ADDR x1, g3_project_dependency_section
    ARM_CALL r2_member
    cbz x9, .Lg3m_done
    ldr x10, [x9]
    cmp x10, #SMP_ARRAY
    b.ne r2_invalid
    ldr x23, [x9, #24]
    add x19, x9, #32
    mov x24, #0
.Lg3m_next:
    ARM_ADDR x9, smp_tokens
    sub x2, x19, x9
    lsr x2, x2, #5
    cmp x2, x23
    b.hs .Lg3m_done
    ARM_ADDR x16, r2_dependency_count
    ldr x9, [x16]
    cmp x9, #G3_PROJECT_DEP_LIMIT
    b.hs r2_invalid
    mov x10, #G3_PROJECT_DEP_RECORD
    mul x9, x9, x10
    ARM_ADDR x21, r2_dependencies
    add x21, x21, x9
    mov x0, x19
    ARM_ADDR x1, g3_manifest_fields
    mov w2, #2
    mov w3, #2
    ARM_CALL r2_keys
    mov x0, x19
    ARM_ADDR x1, r2_k_name
    ARM_CALL r2_required
    mov x0, x9
    mov x1, x21
    mov w2, #105
    ARM_CALL r2_string
    mov x0, x21
    ARM_CALL registry_valid_package
    cbz w9, r2_invalid
    mov x0, x19
    ARM_ADDR x1, g3_manifest_requirement
    ARM_CALL r2_required
    mov x0, x9
    add x1, x21, #105
    mov w2, #129
    ARM_CALL r2_string
    add x0, x21, #105
    ARM_ADDR x1, g3_project_zero
    ARM_CALL g3_requirement
    cmn w9, #1
    b.eq r2_invalid
    cbz x24, .Lg3m_accept
    mov x0, x24
    mov x1, x21
    ARM_CALL r2_lex
    cmp w9, #0
    b.ge r2_invalid
.Lg3m_accept:
    mov x24, x21
    ARM_ADDR x16, r2_dependency_count
    ldr x9, [x16]
    add x9, x9, #1
    str x9, [x16]
    ldr x9, [x19, #24]
    lsl x9, x9, #5
    ARM_ADDR x19, smp_tokens
    add x19, x19, x9
    b .Lg3m_next
.Lg3m_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=records in project layout,x1=count0..64. w9=0 identical to latest parsed
 * source declarations,1 different. Compares strings rather than padding.
 * Preserves x19-x24; stack48 plus streq. No archive or file reads. */
g3_compare_dependencies:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x1
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cmp x22, x9
    b.ne .Lg3c_bad
    mov x19, #0
.Lg3c_next:
    cmp x19, x22
    b.hs .Lg3c_ok
    mov x10, #G3_PROJECT_DEP_RECORD
    mul x9, x19, x10
    ARM_ADDR x0, g3_project_deps
    add x0, x0, x9
    add x1, x21, x9
    ARM_CALL streq
    cbz w9, .Lg3c_bad
    mov x10, #G3_PROJECT_DEP_RECORD
    mul x9, x19, x10
    ARM_ADDR x0, g3_project_deps
    add x0, x0, x9
    add x0, x0, #105
    add x1, x21, x9
    add x1, x1, #105
    ARM_CALL streq
    cbz w9, .Lg3c_bad
    add x19, x19, #1
    b .Lg3c_next
.Lg3c_ok:
    mov w9, #0
    b .Lg3c_return
.Lg3c_bad:
    mov w9, #1
.Lg3c_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

.section .rodata
g3_project_dependency_section: .asciz "dependencies"
g3_project_feature_section: .asciz "features"
g3_project_resolution_section: .asciz "resolution"
g3_project_zero: .asciz "0.0.0"
g3_manifest_fields: .asciz "name\0requirement\0"
g3_manifest_requirement: .asciz "requirement"
.section .bss
.balign 8
g3_project_dep_count: .skip 8
g3_project_deps: .skip G3_PROJECT_DEP_LIMIT * G3_PROJECT_DEP_RECORD
g3_project_section: .skip 64
