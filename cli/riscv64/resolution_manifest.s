/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/resolution_manifest.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
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
/* a0=mutable NUL manifest <=16384 bytes; a1=owned RM_SIZE-byte result.
 * t0=0 success,1 invalid. Strings borrow the input; caller retains its bytes.
 * Extension manifests are <=8190 bytes. Header: extension,deps,features at
 * 0,8,16; name/version/source/target pointers at24,32,40,48. Dependency records
 * at64: name,range,optional,defaults,count,pointers[64]. Feature records at36928:
 * name,count,pointers[64]; +528/+536 are private traversal state. Stride576.
 * Optional native-link pointers follow at RM_LINK/RM_LIBRARIES/RM_CHECK.
 * Absent optional values borrow rm_empty. Field capacities include NUL:256.
 * Preserves s0-s5. Uses 96 local stack bytes, plus RV_CALL frames.
 * Feature traversal adds at most 64 frames of 48 bytes. No file or process effects.
 */
rm_parse_manifest:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s2, a0
    mv s3, a1
    RV_ADDR s6, rm_input
    mv s8, s6
    RV_STORE a0, 8
    RV_ADDR s6, rm_output
    mv s8, s6
    RV_STORE a1, 8
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
.Lrm_preflight:
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    andi t1, t0, 255
    andi t2, t0, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_preflight_done
    RV_IMM t2, 16384, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_bad
    andi t1, t0, 255
    RV_IMM t2, 127, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_not_ascii
    andi t1, t0, 255
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_preflight_next
    andi t1, t0, 255
    RV_IMM t2, 9, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_preflight_next
    andi t1, t0, 255
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_preflight_next
    andi t1, t0, 255
    RV_IMM t2, 13, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_not_ascii
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    RV_IMM s7, 1, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_preflight_next
.Lrm_not_ascii:
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
.Lrm_preflight_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    tail .Lrm_preflight
.Lrm_preflight_done:
    RV_ADDR s6, rm_ascii
    mv s8, s6
    RV_STORE a2, 8
    RV_ADDR s6, rm_input_length
    mv s8, s6
    RV_STORE a3, 8
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    mv a0, a1
    RV_IMM t1, RM_SIZE/8, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_resolution_manifest105
    tail .Lrm_arm_zero_done1
.Lrv_cb_skip_resolution_manifest105:
.Lrm_arm_zero1:
    mv s8, a0
    RV_STORE t0, 8
    li s10, 8
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_resolution_manifest109
    tail .Lrm_arm_zero1
.Lrv_cb_skip_resolution_manifest109:
.Lrm_arm_zero_done1:
    RV_ADDR t1, rm_empty
    RV_IMM s7, RM_LINK, 64
    mv s10, s7
    add s6, s3, s10
    mv s8, s6
    RV_STORE t1, 8
    li s10, 8
    add s8, s6, s10
    RV_STORE t1, 8
    li s10, 16
    add s8, s6, s10
    RV_STORE t1, 8
    mv s10, s4
    xor t3, s4, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s4, t3
    RV_ZEXT s4
    mv s10, s5
    xor t3, s5, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s5, t3
    RV_ZEXT s5
    mv s10, s0
    xor t3, s0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s0, t3
    RV_ZEXT s0
.Lrm_line:
    RV_CALL rm_horizontal
    mv s6, s2
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
    RV_BCOND eq, .Lrm_finish
    andi t1, t0, 255
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_next
    andi t1, t0, 255
    RV_IMM t2, 35, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_comment
    andi t1, t0, 255
    RV_IMM t2, 91, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_section
    RV_IMM t2, 4, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_dependency
    RV_IMM t2, 5, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_feature
    RV_CALL rm_key_identifier
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM t1, 61, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rm_expect
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_CALL rm_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
    mv s1, t0
    RV_IMM t2, 3, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_schema
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_package
    RV_IMM t2, 2, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_source
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_source
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_target
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_resolution_manifest186
    tail .Lrm_target
.Lrv_cb_skip_resolution_manifest186:
    RV_ADDR a0, rm_key
    RV_ADDR a1, rm_link
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_resolution_manifest190
    tail .Lrm_link
.Lrv_cb_skip_resolution_manifest190:
    RV_ADDR a0, rm_key
    RV_ADDR a1, rm_libraries
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_resolution_manifest194
    tail .Lrm_libraries
.Lrv_cb_skip_resolution_manifest194:
    RV_ADDR a0, rm_key
    RV_ADDR a1, rm_check
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_resolution_manifest198
    tail .Lrm_check
.Lrv_cb_skip_resolution_manifest198:
    tail .Lrm_bad
.Lrm_link:
    mv s8, s1
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolution_manifest202
    tail .Lrm_bad
.Lrv_cb_skip_resolution_manifest202:
    li a2, 32
    RV_ZEXT a2
    RV_IMM a3, RM_LINK, 64
    tail .Lrm_scalar
.Lrm_libraries:
    mv s8, s1
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolution_manifest208
    tail .Lrm_bad
.Lrv_cb_skip_resolution_manifest208:
    li a2, 64
    RV_ZEXT a2
    RV_IMM a3, RM_LIBRARIES, 64
    tail .Lrm_scalar
.Lrm_check:
    mv s8, s1
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolution_manifest214
    tail .Lrm_bad
.Lrv_cb_skip_resolution_manifest214:
    li a2, 128
    RV_ZEXT a2
    RV_IMM a3, RM_CHECK, 64
    tail .Lrm_scalar
.Lrm_target:
    RV_IMM t1, 8, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 48, 32
    mv a3, t1
    RV_ZEXT a3
    tail .Lrm_scalar
.Lrm_source:
    RV_IMM t1, 4, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 40, 32
    mv a3, t1
    RV_ZEXT a3
    tail .Lrm_scalar
.Lrm_package:
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_name
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_name
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_version
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM t1, 2, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 32, 32
    mv a3, t1
    RV_ZEXT a3
    tail .Lrm_scalar
.Lrm_name:
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 24, 32
    mv a3, t1
    RV_ZEXT a3
.Lrm_scalar:
    mv s8, s0
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_bad
    mv s10, a2
    or t3, s0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s0, t3
    RV_ZEXT s0
    mv s6, s3
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s1, 8
    tail .Lrm_line_end
.Lrm_schema:
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_schema
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv s6, s1
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 0x31, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
    RV_IMM t2, 16, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_bad
    RV_IMM t2, 16, 32
    mv s10, t2
    or t3, s0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s0, t3
    RV_ZEXT s0
    RV_IMM t1, 1, 64
    mv s6, s3
    mv s8, s6
    RV_STORE t1, 8
    tail .Lrm_line_end
.Lrm_section:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 97, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrm_bad
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 122, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lrm_bad
    RV_CALL rm_key_identifier
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 93, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_ADDR s6, rm_sections
    mv s1, s6
    RV_IMM t1, 1, 32
    mv s4, t1
    RV_ZEXT s4
.Lrm_section_find:
    mv s6, s1
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_section_found
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s4, t3
    RV_ZEXT s4
    RV_IMM t2, 8, 64
    mv s8, s1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s1, t3
    tail .Lrm_section_find
.Lrm_section_found:
    mv a3, s4
    RV_ZEXT a3
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    andi t2, a3, 255
    sllw t3, t0, t2
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    mv s8, s5
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_bad
    mv s10, t0
    or t3, s5, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s5, t3
    RV_ZEXT s5
    tail .Lrm_line_end
.Lrm_dependency:
    RV_CALL rm_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
    mv s1, t0
    mv a0, t0
    RV_CALL registry_valid_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv a0, s1
    RV_CALL rm_find_dep
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrm_bad
    mv s6, s3
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 64, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrm_bad
    RV_IMM t2, RM_STRIDE, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    mv s6, s3
    mv s10, t0
    add s6, s6, s10
    RV_IMM s7, RM_DEPS, 64
    mv s10, s7
    add s6, s6, s10
    mv s1, s6
    mv s6, s1
    mv s8, s6
    RV_STORE a0, 8
    RV_IMM t1, 1, 64
    mv s6, s1
    RV_IMM s7, 24, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 8
    mv s6, s3
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s6, s3
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t3, 8
    RV_IMM t1, 61, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rm_expect
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 123, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_inline
    RV_CALL rm_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
    mv s6, s1
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_CALL rm_valid_range
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    tail .Lrm_line_end
.Lrm_inline:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_IMM t1, 0, 64
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_STORE t1, 8
.Lrm_inline_field:
    RV_CALL rm_key_identifier
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM t1, 61, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rm_expect
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_version
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_inline_version
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_optional
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_inline_optional
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_defaults
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_inline_defaults
    RV_ADDR s6, rm_key
    mv a0, s6
    RV_ADDR s6, rm_features
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 8, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrm_bad
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 8, 64
    mv s10, t2
    or t3, t1, s10
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_STORE t3, 8
    mv s6, s1
    RV_IMM s7, 40, 64
    mv s10, s7
    add s6, s6, s10
    mv a0, s6
    RV_CALL rm_array
    RV_IMM t2, -1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrm_bad
    mv s6, s1
    RV_IMM s7, 32, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
.Lrm_dep_feature_name:
    mv s6, s1
    RV_IMM s7, 32, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrm_inline_end
    mv s6, s1
    mv s10, a2
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, 40, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_SAVE a2
    RV_CALL rm_valid_feature
    RV_RESTORE a2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a2, t3
    RV_ZEXT a2
    tail .Lrm_dep_feature_name
.Lrm_inline_version:
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrm_bad
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s10, t2
    or t3, t1, s10
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_STORE t3, 8
    RV_CALL rm_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
    mv s6, s1
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_CALL rm_valid_range
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    tail .Lrm_inline_end
.Lrm_inline_optional:
    RV_IMM t1, 2, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 16, 32
    mv a3, t1
    RV_ZEXT a3
    tail .Lrm_inline_bool
.Lrm_inline_defaults:
    RV_IMM t1, 4, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 24, 32
    mv a3, t1
    RV_ZEXT a3
.Lrm_inline_bool:
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrm_bad
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    mv s10, a2
    or t3, t1, s10
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 64
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_STORE t3, 8
    RV_SAVE a3
    RV_CALL rm_bool
    RV_RESTORE a3
    RV_IMM t2, -1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrm_bad
    mv s6, s1
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
.Lrm_inline_end:
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    andi t1, t0, 255
    RV_IMM t2, 125, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_inline_done
    andi t1, t0, 255
    RV_IMM t2, 44, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 125, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_bad
    tail .Lrm_inline_field
.Lrm_inline_done:
    RV_ADDR s6, rm_table_fields
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
    tail .Lrm_line_end
.Lrm_feature:
    mv s6, s3
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 64, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrm_bad
    RV_CALL rm_horizontal
    RV_IMM t1, 0, 64
    RV_ADDR s6, rm_feature_equal
    mv s8, s6
    RV_STORE t1, 8
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 34, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_feature_quoted
    mv s1, s2
    RV_CALL rm_key_identifier
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_feature_bare_end
    andi t1, t0, 255
    RV_IMM t2, 9, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_feature_bare_end
    andi t1, t0, 255
    RV_IMM t2, 61, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
    RV_IMM t1, 1, 64
    RV_ADDR s6, rm_feature_equal
    mv s8, s6
    RV_STORE t1, 8
.Lrm_feature_bare_end:
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv t0, s1
    tail .Lrm_feature_key
.Lrm_feature_quoted:
    RV_CALL rm_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_bad
.Lrm_feature_key:
    mv s1, t0
    mv a0, t0
    RV_CALL rm_valid_feature
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv a0, s1
    RV_CALL rm_find_feature
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrm_bad
    mv s6, s3
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, RM_STRIDE, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    mv s6, s3
    mv s10, t0
    add s6, s6, s10
    RV_IMM s7, RM_FEATURES, 64
    mv s10, s7
    add s6, s6, s10
    mv t0, s6
    mv s6, t0
    mv s8, s6
    RV_STORE s1, 8
    mv s1, t0
    mv s6, s3
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s6, s3
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t3, 8
    RV_ADDR s6, rm_feature_equal
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrm_feature_array
    RV_IMM t1, 61, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rm_expect
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
.Lrm_feature_array:
    mv s6, s1
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv a0, s6
    RV_CALL rm_array
    RV_IMM t2, -1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrm_bad
    mv s6, s1
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
.Lrm_line_end:
    RV_CALL rm_horizontal
    mv s6, s2
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
    RV_BCOND eq, .Lrm_finish
    andi t1, t0, 255
    RV_IMM t2, 35, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_comment
    andi t1, t0, 255
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
.Lrm_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrm_line
.Lrm_comment:
    mv s6, s2
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
    RV_BCOND eq, .Lrm_finish
    andi t1, t0, 255
    RV_IMM t2, 10, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_next
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrm_comment
.Lrm_finish:
    mv t0, s0
    RV_ZEXT t0
    RV_IMM t2, 15, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS and, 32
    mv t3, s11
    mv t0, t3
    RV_ZEXT t0
    RV_IMM t2, 15, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bad
    mv t0, s2
    RV_ADDR s6, rm_input
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv t0, t3
    RV_IMM t2, 16384, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lrm_bad
    RV_IMM t2, 28, 32
    mv s8, s5
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_scalars_valid
    RV_IMM t2, 16, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM t2, 8190, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lrm_bad
    RV_ADDR s6, rm_ascii
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lrm_bad
.Lrm_scalars_valid:
    mv s6, s3
    RV_IMM s7, 24, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL valid_name
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv s6, s3
    RV_IMM s7, 32, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    mv s8, t0
    li s10, RM_VERSION_LIMIT
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lrm_bad
    li s10, 32
    add s8, s3, s10
    RV_LOAD a0, 8
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lrm_strict_version
    RV_CALL valid_version
    tail .Lrm_version_checked
.Lrm_strict_version:
    RV_CALL registry_valid_version
.Lrm_version_checked:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv s6, s3
    RV_IMM s7, 40, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL valid_source
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    mv s6, s3
    RV_IMM s7, 48, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM s7, RM_LINK, 64
    mv s10, s7
    add s6, s3, s10
    mv s8, s6
    RV_LOAD a0, 8
    li s10, 8
    add s8, s6, s10
    RV_LOAD a1, 8
    li s10, 16
    add s8, s6, s10
    RV_LOAD a2, 8
    RV_CALL native_link_validate
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_resolution_manifest832
    tail .Lrm_bad
.Lrv_cb_skip_resolution_manifest832:
    mv s10, s1
    xor t3, s1, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s1, t3
    RV_ZEXT s1
.Lrm_feature_check:
    mv s6, s3
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrm_good
    RV_IMM t2, RM_STRIDE, 64
    mv s10, t2
    mul t3, s1, s10
    mv t0, t3
    mv s6, s3
    mv s10, t0
    add s6, s6, s10
    RV_IMM s7, RM_FEATURES, 64
    mv s10, s7
    add s6, s6, s10
    mv a0, s6
    RV_CALL rm_feature_visit
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_bad
    RV_IMM t2, 1, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s1, t3
    RV_ZEXT s1
    tail .Lrm_feature_check
.Lrm_good:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    tail .Lrm_return
.Lrm_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lrm_return:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Parser helpers deliberately advance s2. Other callee registers preserved.
 * Input is a bounded copied NUL buffer. No helper crosses a string terminator. */
rm_horizontal:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_hnext
    andi t1, t0, 255
    RV_IMM t2, 9, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_hnext
    andi t1, t0, 255
    RV_IMM t2, 13, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_hdone
.Lrm_hnext:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail rm_horizontal
.Lrm_hdone:
    ret
rm_expect:
    mv a2, a0
    RV_ZEXT a2
    RV_CALL rm_horizontal
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    andi t2, a2, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_expect_done
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lrm_expect_done:
    ret
rm_key_identifier:
    RV_CALL rm_horizontal
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
    RV_ADDR s6, rm_key
    mv a0, s6
.Lrm_key_char:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 97, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrm_key_extra
    andi t1, t0, 255
    RV_IMM t2, 122, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lrm_key_copy
.Lrm_key_extra:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_key_end
    andi t1, t0, 255
    RV_IMM t2, 48, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrm_key_punct
    andi t1, t0, 255
    RV_IMM t2, 57, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lrm_key_copy
.Lrm_key_punct:
    andi t1, t0, 255
    RV_IMM t2, 45, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_key_copy
    andi t1, t0, 255
    RV_IMM t2, 95, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_key_end
.Lrm_key_copy:
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_key_bad
    andi t1, t0, 255
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrm_key_char
.Lrm_key_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrv_cset_true_resolution_manifest981
    li t1, 0
    j .Lrv_cset_done_resolution_manifest981
.Lrv_cset_true_resolution_manifest981:
    li t1, 1
.Lrv_cset_done_resolution_manifest981:
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    ret
.Lrm_key_bad:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    ret
rm_string:
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 34, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_string_bad
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv a0, s2
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrm_string_char:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 34, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_string_end
    andi t1, t0, 255
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrm_string_bad
    andi t1, t0, 255
    RV_IMM t2, 126, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lrm_string_bad
    andi t1, t0, 255
    RV_IMM t2, 92, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_string_bad
    RV_IMM t2, 255, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_string_bad
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrm_string_char
.Lrm_string_end:
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv t0, a0
    ret
.Lrm_string_bad:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    ret
rm_bool:
    RV_CALL rm_horizontal
    RV_ADDR s6, rm_true
    mv a1, s6
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 116, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_bool_scan
    RV_ADDR s6, rm_false
    mv a1, s6
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
.Lrm_bool_scan:
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrm_bool_char:
    mv s6, a1
    mv s10, a3
    add s6, s6, s10
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
    RV_BCOND eq, .Lrm_bool_end
    andi t1, t0, 255
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 1
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_bool_bad
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    tail .Lrm_bool_char
.Lrm_bool_end:
    mv s8, s2
    mv s10, a3
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv t0, a2
    RV_ZEXT t0
    ret
.Lrm_bool_bad:
    RV_IMM t1, -1, 64
    mv t0, t1
    ret
/* a0=array[64] result. t0=count or-1. Reject duplicate strings. */
rm_array:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s3
    RV_SAVE s4
    mv s0, a0
    mv s10, s1
    xor t3, s1, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s1, t3
    RV_ZEXT s1
    RV_IMM t1, 91, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rm_expect
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_array_bad
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 93, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_array_empty
.Lrm_array_item:
    RV_IMM t2, 64, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_array_bad
    RV_CALL rm_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_array_bad
    mv s3, t0
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_array_bad
    mv s10, s4
    xor t3, s4, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s4, t3
    RV_ZEXT s4
.Lrm_array_duplicate:
    mv s8, s4
    mv s10, s1
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_array_store
    mv a0, s3
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_array_bad
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s4, t3
    RV_ZEXT s4
    tail .Lrm_array_duplicate
.Lrm_array_store:
    mv s6, s0
    mv s10, s1
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s3, 8
    RV_IMM t2, 1, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s1, t3
    RV_ZEXT s1
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    andi t1, t0, 255
    RV_IMM t2, 93, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_array_done
    andi t1, t0, 255
    RV_IMM t2, 44, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_array_bad
    RV_CALL rm_horizontal
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 93, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_array_empty
    tail .Lrm_array_item
.Lrm_array_empty:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
.Lrm_array_done:
    mv t0, s1
    RV_ZEXT t0
    tail .Lrm_array_return
.Lrm_array_bad:
    RV_IMM t1, -1, 64
    mv t0, t1
.Lrm_array_return:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=feature identifier. t0=1/0. Max32 ASCII bytes. */
rm_valid_feature:
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrm_feature_char:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
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
    RV_BCOND eq, .Lrm_feature_end
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrm_feature_invalid
    andi t1, t0, 255
    RV_IMM t2, 97, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrm_feature_extra
    andi t1, t0, 255
    RV_IMM t2, 122, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lrm_feature_next
.Lrm_feature_extra:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_feature_invalid
    andi t1, t0, 255
    RV_IMM t2, 48, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrm_feature_punct
    andi t1, t0, 255
    RV_IMM t2, 57, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lrm_feature_next
.Lrm_feature_punct:
    andi t1, t0, 255
    RV_IMM t2, 95, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_feature_next
    andi t1, t0, 255
    RV_IMM t2, 45, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_feature_invalid
.Lrm_feature_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    tail .Lrm_feature_char
.Lrm_feature_end:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrv_cset_true_resolution_manifest1247
    li t1, 0
    j .Lrv_cset_done_resolution_manifest1247
.Lrv_cset_true_resolution_manifest1247:
    li t1, 1
.Lrv_cset_done_resolution_manifest1247:
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    ret
.Lrm_feature_invalid:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    ret
/* a0=name; global rm_output is current owned result. t0=record or0.
 * a0 remains the input on return. Other argument registers are scratch. */
rm_find_dep:
    RV_ADDR s6, rm_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, a1
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_IMM t2, RM_DEPS, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a1, t3
    tail rm_find_record
rm_find_feature:
    RV_ADDR s6, rm_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, a1
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_IMM t2, RM_FEATURES, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a1, t3
rm_find_record:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s3
    mv s0, a0
    mv s1, a1
    mv s3, a2
.Lrm_find_loop:
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_find_absent
    mv a0, s0
    mv s6, s1
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrm_find_found
    RV_IMM t2, RM_STRIDE, 64
    mv s8, s1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s1, t3
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    mv t3, s11
    mv s3, t3
    tail .Lrm_find_loop
.Lrm_find_absent:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    tail .Lrm_find_return
.Lrm_find_found:
    mv t0, s1
.Lrm_find_return:
    mv a0, s0
    RV_RESTORE s3
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=feature record. t0=1 valid,0 invalid/reference cycle. DFS depth<=64.
 * Local reference scratch is not retained across recursive calls. */
rm_feature_visit:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s3
    mv s0, a0
    mv s6, s0
    RV_IMM s7, 536, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 2, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrm_visit_good
    mv s6, s0
    RV_IMM s7, 536, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lrm_visit_bad
    RV_IMM t1, 1, 64
    mv s6, s0
    RV_IMM s7, 536, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 8
    mv s10, s1
    xor t3, s1, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s1, t3
    RV_ZEXT s1
.Lrm_visit_item:
    mv s6, s0
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrm_visit_complete
    mv s6, s0
    mv s10, s1
    slli s10, s10, 3
    add s6, s6, s10
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    RV_ADDR s6, rm_reference
    mv a0, s6
    mv a1, s3
    RV_CALL copy_string
    RV_ADDR s6, rm_reference
    mv s3, s6
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0x3a706564, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrm_visit_optional
    mv a0, s3
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
.Lrm_visit_slash:
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
    andi t2, t0, 255
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_visit_classify
    andi t1, t0, 255
    RV_IMM t2, 47, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_visit_slash_next
    mv a2, a0
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
.Lrm_visit_slash_next:
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a0, t3
    tail .Lrm_visit_slash
.Lrm_visit_classify:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_visit_own
    RV_IMM t2, 2, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrm_visit_bad
    RV_IMM t1, 0, 32
    mv s6, a2
    mv s8, s6
    RV_STORE t1, 1
    mv s6, a2
    RV_IMM s7, 1, 64
    mv s10, s7
    add s6, s6, s10
    mv a0, s6
    RV_CALL rm_valid_feature
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_visit_bad
    mv a0, s3
    RV_CALL rm_find_dep
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_visit_bad
    tail .Lrm_visit_next
.Lrm_visit_optional:
    mv s6, s3
    RV_IMM s7, 4, 64
    mv s10, s7
    add s6, s6, s10
    mv a0, s6
    RV_CALL rm_find_dep
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_visit_bad
    mv s6, t0
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lrm_visit_bad
    tail .Lrm_visit_next
.Lrm_visit_own:
    mv a0, s3
    RV_CALL rm_valid_feature
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_visit_bad
    mv a0, s3
    RV_CALL rm_find_feature
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrm_visit_bad
    mv a0, t0
    RV_CALL rm_feature_visit
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrm_visit_bad
.Lrm_visit_next:
    RV_IMM t2, 1, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s1, t3
    RV_ZEXT s1
    tail .Lrm_visit_item
.Lrm_visit_complete:
    RV_IMM t1, 2, 64
    mv s6, s0
    RV_IMM s7, 536, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 8
.Lrm_visit_good:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    tail .Lrm_visit_return
.Lrm_visit_bad:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
.Lrm_visit_return:
    RV_RESTORE s3
    RV_RESTORE s1
    RV_RESTORE s0
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
.section .note.GNU-stack,""
.section .text
/* a0=range, t0=1 valid/0 invalid. No mutation of range bytes. */
rm_valid_range:
    mv a1, a0
    mv s10, a0
    xor t3, a0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a0, t3
    RV_ZEXT a0
    RV_CALL rm_range_matches
    RV_IMM t2, -1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lrv_cset_true_resolution_manifest1517
    li t1, 0
    j .Lrv_cset_done_resolution_manifest1517
.Lrv_cset_true_resolution_manifest1517:
    li t1, 1
.Lrv_cset_done_resolution_manifest1517:
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    mv t0, t1
    RV_ZEXT t0
    ret
/* a0=validated numeric version or0 for syntax only; a1=range. t0=1 match,
 * 0 mismatch,-1 invalid. Supports exact,*,^,~, and <=8 explicit comparisons.
 * Max128 printable bytes, no outer whitespace or implicit partial versions.
 * Callee registers preserved; 96 local stack bytes, plus RV_CALL frames. Owns128-byte token and
 * three numeric triplets; no file operations, recursive calls or input writes.
 */
rm_range_matches:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s4, a0
    mv s2, a1
    RV_IMM t1, 1, 32
    mv s3, t1
    RV_ZEXT s3
    mv s10, s5
    xor t3, s5, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s5, t3
    RV_ZEXT s5
    mv a0, s2
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrq_bad
    RV_IMM t2, 128, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lrq_bad
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_bad
    mv s6, s2
    mv s10, t0
    add s6, s6, s10
    RV_IMM s7, -1, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_bad
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrq_ascii:
    mv s8, a3
    mv s10, t0
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lrq_start
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrq_bad
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 126, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lrq_bad
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    tail .Lrq_ascii
.Lrq_start:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrq_term
    mv a0, s4
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrq_bad
    mv a0, s4
    RV_ADDR s6, rm_range_actual
    mv a1, s6
    RV_CALL rm_range_numbers
.Lrq_term:
    RV_IMM t2, 1, 32
    mv s8, s5
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv s5, t3
    RV_ZEXT s5
    RV_IMM t2, 8, 32
    mv s8, s5
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lrq_bad
    mv s10, s1
    xor t3, s1, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s1, t3
    RV_ZEXT s1
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 42, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_wildcard
    andi t1, t0, 255
    RV_IMM t2, 94, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_caret
    andi t1, t0, 255
    RV_IMM t2, 126, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_tilde
    andi t1, t0, 255
    RV_IMM t2, 62, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_gt
    andi t1, t0, 255
    RV_IMM t2, 60, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_lt
    andi t1, t0, 255
    RV_IMM t2, 61, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_eq
    tail .Lrq_version
.Lrq_caret:
    RV_IMM t1, 5, 32
    mv s1, t1
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_version
.Lrq_tilde:
    RV_IMM t1, 6, 32
    mv s1, t1
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_version
.Lrq_gt:
    RV_IMM t1, 2, 32
    mv s1, t1
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 61, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_spaces
    RV_IMM t2, 1, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    mv t3, s11
    mv s1, t3
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_spaces
.Lrq_lt:
    RV_IMM t1, 4, 32
    mv s1, t1
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 61, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_spaces
    RV_IMM t2, 1, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    mv t3, s11
    mv s1, t3
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_spaces
.Lrq_eq:
    RV_IMM t1, 7, 32
    mv s1, t1
    RV_ZEXT s1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
.Lrq_spaces:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_version
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_spaces
.Lrq_version:
    RV_ADDR s6, rm_range_token
    mv s0, s6
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrq_version_char:
    mv s6, s2
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
    RV_BCOND eq, .Lrq_version_end
    andi t1, t0, 255
    RV_IMM t2, 44, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_version_end
    andi t1, t0, 255
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_version_end
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lrq_bad
    andi t1, t0, 255
    mv s6, s0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_version_char
.Lrq_version_end:
    RV_IMM t1, 0, 32
    mv s6, s0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv a0, s0
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrq_bad
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrq_next
    mv a0, s0
    RV_ADDR s6, rm_range_term
    mv a1, s6
    RV_CALL rm_range_numbers
    RV_ADDR s6, rm_range_actual
    mv a0, s6
    RV_ADDR s6, rm_range_term
    mv a1, s6
    RV_CALL rm_range_compare
    RV_IMM t2, 0, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_exact
    RV_IMM t2, 7, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_exact
    RV_IMM t2, 1, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_ge
    RV_IMM t2, 2, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_greater
    RV_IMM t2, 3, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_le
    RV_IMM t2, 4, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_less
    RV_IMM t2, 0, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lt, .Lrq_mismatch
    RV_ADDR s6, rm_range_term
    mv a1, s6
    mv s6, a1
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, a1
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a1
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_IMM t2, 6, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_upper_minor
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrq_upper_zero
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv t0, t3
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
    tail .Lrq_upper
.Lrq_upper_zero:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 64
    RV_BCOND ne, .Lrq_upper_minor
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a2, t3
    tail .Lrq_upper
.Lrq_upper_minor:
    RV_IMM t2, 1, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a3, t3
    mv s10, a2
    xor t3, a2, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a2, t3
    RV_ZEXT a2
.Lrq_upper:
    RV_ADDR s6, rm_range_upper
    mv a1, s6
    mv s6, a1
    mv s8, s6
    RV_STORE t0, 8
    mv s6, a1
    RV_IMM s7, 8, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE a3, 8
    mv s6, a1
    RV_IMM s7, 16, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE a2, 8
    RV_ADDR s6, rm_range_actual
    mv a0, s6
    RV_CALL rm_range_compare
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ge, .Lrq_mismatch
    tail .Lrq_next
.Lrq_exact:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrq_mismatch
    tail .Lrq_next
.Lrq_ge:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND lt, .Lrq_mismatch
    tail .Lrq_next
.Lrq_greater:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND le, .Lrq_mismatch
    tail .Lrq_next
.Lrq_le:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND gt, .Lrq_mismatch
    tail .Lrq_next
.Lrq_less:
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ge, .Lrq_mismatch
    tail .Lrq_next
.Lrq_mismatch:
    mv s10, s3
    xor t3, s3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv s3, t3
    RV_ZEXT s3
.Lrq_next:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_separator
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_next
.Lrq_separator:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_done
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 44, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_bad
    RV_IMM t2, 0, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_bad
    RV_IMM t2, 5, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_bad
    RV_IMM t2, 6, 32
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_bad
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
.Lrq_after_comma:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_require_comparator
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv s2, t3
    tail .Lrq_after_comma
.Lrq_require_comparator:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    andi t1, t0, 255
    RV_IMM t2, 61, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_term
    andi t1, t0, 255
    RV_IMM t2, 60, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_term
    andi t1, t0, 255
    RV_IMM t2, 62, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_term
    tail .Lrq_bad
.Lrq_wildcard:
    RV_IMM t2, 1, 32
    mv s8, s5
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_bad
    mv s6, s2
    RV_IMM s7, 1, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lrq_bad
.Lrq_done:
    mv t0, s3
    RV_ZEXT t0
    tail .Lrq_return
.Lrq_bad:
    RV_IMM t1, -1, 64
    mv t0, t1
.Lrq_return:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=validated version,a1=three owned qwords. Scratch:t0,a3,a2,a4. */
rm_range_numbers:
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrq_number_component:
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
.Lrq_number_digit:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    andi t1, a2, 255
    RV_IMM t2, 48, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrq_number_store
    andi t1, a2, 255
    RV_IMM t2, 57, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lrq_number_store
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv t3, s11
    mv a2, t3
    RV_ZEXT a2
    RV_IMM t2, 10, 64
    mv s10, t2
    mul t3, t0, s10
    mv t0, t3
    mv s8, t0
    mv s10, a2
    RV_FLAGS add, 64
    mv t3, s11
    mv t0, t3
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a0, t3
    tail .Lrq_number_digit
.Lrq_number_store:
    mv s6, a1
    mv s10, a3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t2, 3, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrq_number_done
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    mv a0, t3
    tail .Lrq_number_component
.Lrq_number_done:
    ret
/* a0/a1=three unsigned qwords. t0=-1,0,1 lexical numeric order. */
rm_range_compare:
    mv s10, a3
    xor t3, a3, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv a3, t3
    RV_ZEXT a3
.Lrq_compare:
    mv s6, a0
    mv s10, a3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, a1
    mv s10, a3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lrq_cmp_less
    RV_BCOND hi, .Lrq_cmp_greater
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    mv a3, t3
    RV_ZEXT a3
    RV_IMM t2, 3, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lrq_compare
    mv s10, t0
    xor t3, t0, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    mv t0, t3
    RV_ZEXT t0
    ret
.Lrq_cmp_less:
    RV_IMM t1, -1, 64
    mv t0, t1
    ret
.Lrq_cmp_greater:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.section .bss
.balign 8
rm_range_token: .skip 40
rm_range_actual: .skip 24
rm_range_term: .skip 24
rm_range_upper: .skip 24
.section .note.GNU-stack,""
