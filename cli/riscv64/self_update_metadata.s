/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/self_update_metadata.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global self_parse_release, self_source_commit
/* Read-only release metadata validation. Authentication belongs to the caller.
 * Limits: 1 MiB input, 32 nested values, 16384 tokens, 256 members per object,
 * 4096 array elements, 16384 raw string bytes, and 256-byte object keys.
 * Keys must be plain ASCII. Unknown strings support JSON escapes, paired
 * UTF-16 surrogate escapes, and valid UTF-8. Identity strings must be plain
 * ASCII. Every object rejects duplicate keys, including ignored metadata.
 * ABI: returning routines preserve s0/s1/s2-s5; others are scratch.
 * Global scratch makes this parser non-reentrant. Input is never changed.
 * Tokens are four qwords: type/flags, borrowed start, raw length, end token.
 */
.equ SMP_INPUT_LIMIT, 1048576
.equ SMP_DEPTH_LIMIT, 32
.equ SMP_TOKEN_LIMIT, 16384
.equ SMP_MEMBER_LIMIT, 256
.equ SMP_ARRAY_LIMIT, 4096
.equ SMP_STRING_LIMIT, 16384
.equ SMP_KEY_LIMIT, 256
.equ SMP_ASSET_LIMIT, 256
.equ SMP_OBJECT, 1
.equ SMP_ARRAY, 2
.equ SMP_STRING, 3
.equ SMP_NUMBER, 4
.equ SMP_TRUE, 5
.equ SMP_FALSE, 6
.equ SMP_NULL, 7
.equ SMP_KEY, 8
.equ SMP_ESCAPED, 256
.equ SMP_NONASCII, 512
.section .text
/* Input: a0=readable bytes, a1=length, a2=validated registry row (eight
 * NUL-terminated field pointers), selecting stubbi/asm/host/executable with a
 * canonical version, byte count, and SHA-256. Output: t0=0/1 success/failure.
 * Success copies the commit to self_source_commit[41]; failure clears it.
 * Stack: 80 saved bytes plus recursion bounded by 32; each recursive object
 * or array adds at most 128 bytes including call frames. Memory is fixed below.
 */
self_parse_release:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
/* Forward string loops do not use a direction flag. */
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE a0, 8
    RV_ADDR s6, smp_row
    mv s8, s6
    RV_STORE a2, 8
    mv t0, a0
    mv s8, t0
    mv s10, a1
    RV_FLAGS add, 64
    mv t0, s11
    RV_BCOND cs, .Lsmp_entry_fail
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, smp_commit_pointer
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, smp_asset_count
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, smp_matching_assets
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, self_source_commit
    mv a0, s6
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t1, 41, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_self_update_metadata79
    RV_JUMP .Lport_self_update_metadata_1_end
.Lrv_cb_skip_self_update_metadata79:
.Lport_self_update_metadata_1:
    mv s8, a0
    RV_STORE t0, 1
    li s10, 1
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_self_update_metadata83
    RV_JUMP .Lport_self_update_metadata_1
.Lrv_cb_skip_self_update_metadata83:
.Lport_self_update_metadata_1_end:
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lsmp_entry_fail
    RV_IMM t2, SMP_INPUT_LIMIT, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_entry_fail
    RV_CALL smp_expected_names
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_entry_fail
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL smp_value
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_entry_fail
    RV_CALL smp_space
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_entry_fail
    RV_ADDR s6, smp_tokens
    mv t0, s6
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_OBJECT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_entry_fail
    mv s6, t0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_entry_fail
    RV_IMM t1, 1, 32
    mv s3, t1
    RV_ZEXT s3
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Lsmp_root_member:
    mv s8, s3
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_root_done
    mv t0, s3
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv s0, s6
    mv s8, s0
    mv s10, t0
    RV_FLAGS add, 64
    mv s0, s11
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv s5, s6
    RV_ADDR s6, smp_key_schema
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_schema
    RV_ADDR s6, smp_key_project
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_project
    RV_ADDR s6, smp_key_repository
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_repository
    RV_ADDR s6, smp_key_version
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_version
    RV_ADDR s6, smp_key_tag
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_tag
    RV_ADDR s6, smp_key_commit
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_commit
    RV_ADDR s6, smp_key_assets
    mv a1, s6
    mv a0, s0
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_root_assets
    RV_JUMP .Lsmp_root_next
.Lsmp_root_schema:
    mv s6, s5
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_NUMBER, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_entry_fail
    mv s6, s5
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_entry_fail
    mv s6, s5
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 49, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_entry_fail
    RV_IMM t2, 1, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_root_next
.Lsmp_root_project:
    RV_ADDR s6, smp_project
    mv a1, s6
    mv a0, s5
    RV_CALL smp_plain_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_entry_fail
    RV_IMM t2, 2, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_root_next
.Lsmp_root_repository:
    RV_ADDR s6, smp_repository
    mv a1, s6
    mv a0, s5
    RV_CALL smp_plain_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_entry_fail
    RV_IMM t2, 4, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_root_next
.Lsmp_root_version:
    RV_ADDR s6, smp_row
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv a0, s5
    RV_CALL smp_plain_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_entry_fail
    RV_IMM t2, 8, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_root_next
.Lsmp_root_tag:
    RV_ADDR s6, smp_expected_tag
    mv a1, s6
    mv a0, s5
    RV_CALL smp_plain_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_entry_fail
    RV_IMM t2, 16, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_root_next
.Lsmp_root_commit:
    mv a0, s5
    RV_IMM t1, 40, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL smp_lower_hex
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_entry_fail
    mv s6, s5
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Lsmp_nonzero_commit:
    mv s6, a2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and a4, a4, s10
    or a4, a4, s11
    li s10, 255
    and t1, a4, s10
    RV_ZEXT t1
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    mv t3, s11
    srliw t3, t3, 24
    RV_ZEXT t3
    li s10, 255
    slli s11, t3, 0
    and s11, s11, s10
    not s10, s10
    and a4, a4, s10
    or a4, a4, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, a4, s10
    RV_ZEXT t2
    mv s10, t2
    or t3, t1, s10
    RV_ZEXT t3
    slliw t1, t3, 24
    RV_ZEXT t1
    mv s8, t1
    mv s10, t1
    RV_FLAGS and, 32
    li s10, 255
    slli s11, t3, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 40, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_nonzero_commit
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_entry_fail
    RV_ADDR s6, smp_commit_pointer
    mv s8, s6
    RV_STORE a2, 8
    RV_IMM t2, 32, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_root_next
.Lsmp_root_assets:
    mv a0, s5
    RV_CALL smp_assets
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_entry_fail
    RV_IMM t2, 64, 32
    mv s10, t2
    or s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Lsmp_root_next:
    mv s6, s5
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    RV_JUMP .Lsmp_root_member
.Lsmp_root_done:
    RV_IMM t2, 127, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_entry_fail
    RV_ADDR s6, smp_matching_assets
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_entry_fail
    RV_ADDR s6, smp_commit_pointer
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, self_source_commit
    mv a0, s6
    RV_IMM t1, 40, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_self_update_metadata336
    RV_JUMP .Lport_self_update_metadata_2_end
.Lrv_cb_skip_self_update_metadata336:
.Lport_self_update_metadata_2:
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
    beqz s8, .Lrv_cb_skip_self_update_metadata341
    RV_JUMP .Lport_self_update_metadata_2
.Lrv_cb_skip_self_update_metadata341:
.Lport_self_update_metadata_2_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_entry_done
.Lsmp_entry_fail:
    RV_ADDR s6, self_source_commit
    mv a0, s6
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t1, 41, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_self_update_metadata356
    RV_JUMP .Lport_self_update_metadata_3_end
.Lrv_cb_skip_self_update_metadata356:
.Lport_self_update_metadata_3:
    mv s8, a0
    RV_STORE t0, 1
    li s10, 1
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_self_update_metadata360
    RV_JUMP .Lport_self_update_metadata_3
.Lrv_cb_skip_self_update_metadata360:
.Lport_self_update_metadata_3_end:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_entry_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: smp_row. Output: zero and bounded expected tag/filename strings,
 * or one for a row outside the fixed package/host/kind contract. The version
 * must already be canonical; its defensive length limit is 32. Stack: 48. */
smp_expected_names:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s6, smp_row
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, smp_package
    mv a1, s6
    RV_CALL smp_cstr_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_names_fail
    mv s6, s0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, smp_host
    mv a1, s6
    RV_CALL smp_cstr_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_names_fail
    mv s6, s0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, smp_executable
    mv a1, s6
    RV_CALL smp_cstr_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_names_fail
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, smp_expected_tag
    mv s2, s6
    RV_IMM t1, 118, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_expected_file
    mv s3, s6
    RV_IMM t1, 762147681, 32
    mv s6, s3
    mv s8, s6
    RV_STORE t1, 4
    RV_IMM t2, 4, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lsmp_names_copy:
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
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_names_suffix
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lsmp_names_fail
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, s3
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lsmp_names_copy
.Lsmp_names_suffix:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_names_fail
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s8, s3
    mv s10, a3
    RV_FLAGS add, 64
    mv s3, s11
    RV_ADDR s6, smp_host_suffix
    mv a1, s6
.Lsmp_names_suffix_byte:
    mv s8, a1
    RV_LOAD t1, 1
    li s10, 1
    add a1, a1, s10
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, s3
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_names_suffix_byte
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_names_done
.Lsmp_names_fail:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_names_done:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: a0=value depth, root=1. Output: zero/one, advanced cursor and token
 * count. Checks depth before dispatch. Stack: nested bounded parser calls. */
smp_value:
    RV_IMM t2, SMP_DEPTH_LIMIT, 32
    mv s8, a0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, smp_bad
    li s10, 16
    sub sp, sp, s10
    RV_CALL smp_space
    li s10, 16
    add sp, sp, s10
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, smp_bad
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 123, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, smp_object
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 91, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, smp_array
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 34, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_value_string
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 45, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, smp_number
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_value_literal
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 57, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, smp_number
.Lsmp_value_literal:
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 116, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_value_true
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 102, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_value_false
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 110, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, smp_bad
    RV_ADDR s6, smp_null
    mv a1, s6
    RV_IMM t1, SMP_NULL, 32
    mv a0, t1
    RV_ZEXT a0
    RV_JUMP smp_literal
.Lsmp_value_true:
    RV_ADDR s6, smp_true
    mv a1, s6
    RV_IMM t1, SMP_TRUE, 32
    mv a0, t1
    RV_ZEXT a0
    RV_JUMP smp_literal
.Lsmp_value_false:
    RV_ADDR s6, smp_false
    mv a1, s6
    RV_IMM t1, SMP_FALSE, 32
    mv a0, t1
    RV_ZEXT a0
    RV_JUMP smp_literal
.Lsmp_value_string:
    mv s10, a0
    xor a0, a0, s10
    RV_ZEXT a0
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 32
    RV_JUMP smp_string
/* Input: cursor at object, a0=depth. Output: zero/one. Stores member keys as
 * tokens, then compares each key with this object's previous keys. Plain
 * ASCII unescaped keys make raw equality semantic equality. Stack: 80 bytes.
 * At most 256 members; recursive children have exclusive end token indexes. */
smp_object:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s2, a0
    RV_ZEXT s2
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    RV_IMM t1, SMP_OBJECT, 32
    mv a0, t1
    RV_ZEXT a0
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL smp_emit
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_object_fail
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_CALL smp_space
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_object_fail
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 125, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_object_close
.Lsmp_object_member:
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    RV_IMM t2, SMP_MEMBER_LIMIT, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_object_fail
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s5, t1
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL smp_string
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_object_fail
    mv s6, s3
    li s10, 1
    add s6, s6, s10
    mv s0, s6
.Lsmp_object_previous:
    mv s8, s0
    mv s10, s5
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_object_colon
    mv t0, s0
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    mv t0, s5
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv a1, s6
    mv s8, a1
    mv s10, t0
    RV_FLAGS add, 64
    mv a1, s11
    RV_CALL smp_token_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_object_fail
    mv t0, s0
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv a2, s6
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    RV_JUMP .Lsmp_object_previous
.Lsmp_object_colon:
    RV_CALL smp_space
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_object_fail
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 58, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_object_fail
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    RV_ZEXT a0
    RV_CALL smp_value
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_object_fail
    RV_CALL smp_space
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_object_fail
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 125, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_object_close
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 44, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_object_fail
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    RV_CALL smp_space
    RV_JUMP .Lsmp_object_member
.Lsmp_object_close:
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    mv t0, s3
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv a2, s6
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_STORE a3, 8
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_object_done
.Lsmp_object_fail:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_object_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: cursor at array, a0=depth. Output: zero/one. Maximum 4096 elements.
 * Each child records its exclusive end token. Stack: 48 saved bytes. */
smp_array:
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    mv s2, a0
    RV_ZEXT s2
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    RV_IMM t1, SMP_ARRAY, 32
    mv a0, t1
    RV_ZEXT a0
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL smp_emit
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_array_fail
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_CALL smp_space
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_array_fail
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 93, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_array_close
.Lsmp_array_element:
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    RV_IMM t2, SMP_ARRAY_LIMIT, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_array_fail
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    RV_ZEXT a0
    RV_CALL smp_value
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_array_fail
    RV_CALL smp_space
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_array_fail
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 93, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_array_close
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 44, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_array_fail
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    RV_JUMP .Lsmp_array_element
.Lsmp_array_close:
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t3, 8
    mv t0, s3
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv a2, s6
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_STORE a3, 8
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_array_done
.Lsmp_array_fail:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_array_done:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    ret
/* Input: cursor at quote, a0=1 for plain ASCII key, else value string.
 * Output: zero/one; token excludes quotes and records escape/non-ASCII flags.
 * Every read is bounded. Limits: 256 key bytes, 16 KiB string bytes. Stack:80
 * bytes, including alignment padding. */
smp_string:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    li s10, 16
    sub sp, sp, s10
    mv s4, a0
    RV_ZEXT s4
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_string_fail
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 34, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_string_fail
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    mv s0, s2
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Lsmp_string_byte:
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_string_fail
    mv t0, s2
    mv s8, t0
    mv s10, s0
    RV_FLAGS sub, 64
    mv t0, s11
    RV_IMM t2, SMP_STRING_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_string_fail
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_string_bound_ready
    RV_IMM t2, SMP_KEY_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_string_fail
.Lsmp_string_bound_ready:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 34, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_close
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 32, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_string_fail
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 92, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 128, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lsmp_string_utf8
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lsmp_string_byte
.Lsmp_string_escape:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_string_fail
    RV_IMM t2, SMP_ESCAPED, 32
    mv s10, t2
    or s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_string_fail
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 117, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_unicode
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 34, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 92, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 47, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 98, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 102, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 110, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 114, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_string_escape_single
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 116, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_string_fail
.Lsmp_string_escape_single:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lsmp_string_byte
.Lsmp_string_unicode:
    mv s6, s2
    li s10, 5
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_string_fail
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    RV_CALL smp_hex4
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND mi, .Lsmp_string_fail
    RV_IMM t2, 55296, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_string_unicode_single
    RV_IMM t2, 56319, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_string_surrogate
    RV_IMM t2, 57343, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_string_fail
.Lsmp_string_unicode_single:
    RV_IMM t2, 5, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lsmp_string_byte
.Lsmp_string_surrogate:
    mv s6, s2
    li s10, 11
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_string_fail
    mv s6, s2
    li s10, 5
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 92, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_string_fail
    mv s6, s2
    li s10, 6
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 117, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_string_fail
    mv s6, s2
    li s10, 7
    add s6, s6, s10
    mv a0, s6
    RV_CALL smp_hex4
    RV_IMM t2, 56320, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_string_fail
    RV_IMM t2, 57343, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_string_fail
    RV_IMM t2, 11, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lsmp_string_byte
.Lsmp_string_utf8:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_string_fail
    RV_IMM t2, SMP_NONASCII, 32
    mv s10, t2
    or s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
    mv a0, s2
    RV_CALL smp_utf8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lsmp_string_fail
    mv s2, t0
    RV_JUMP .Lsmp_string_byte
.Lsmp_string_close:
    mv s6, s2
    li s10, 1
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t0, 8
    mv a2, s2
    mv s8, a2
    mv s10, s0
    RV_FLAGS sub, 64
    mv a2, s11
    mv a1, s0
    RV_IMM t1, SMP_STRING, 32
    mv a0, t1
    RV_ZEXT a0
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_string_type
    RV_IMM t1, SMP_KEY, 32
    mv a0, t1
    RV_ZEXT a0
.Lsmp_string_type:
    mv s10, s3
    or a0, a0, s10
    RV_ZEXT a0
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 32
    RV_CALL smp_emit
    RV_JUMP .Lsmp_string_done
.Lsmp_string_fail:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_string_done:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: a0=four already-bounded bytes. Output: t0=0..65535 or -1.
 * Accepts both JSON hexadecimal letter cases. No local stack or memory writes. */
smp_hex4:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lsmp_hex_digit:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv a2, s11
    RV_IMM t2, 9, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_hex_add
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t2, 32, 32
    mv s10, t2
    or a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_IMM t2, 97, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv a2, s11
    RV_IMM t2, 5, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_hex_fail
    RV_IMM t2, 10, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
.Lsmp_hex_add:
    slliw t0, t0, 4
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    mv s10, a2
    or t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 4, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_hex_digit
    ret
.Lsmp_hex_fail:
    RV_IMM t1, -1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
/* Input: a0=non-ASCII input byte. Output: t0=next pointer or zero.
 * Rejects overlong UTF-8, surrogates, and values above U+10FFFF. Reads at
 * most four bytes after a full length check. No local stack or memory writes. */
smp_utf8:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t1, 2, 32
    mv a3, t1
    RV_ZEXT a3
    RV_IMM t1, 128, 32
    mv a4, t1
    RV_ZEXT a4
    RV_IMM t1, 191, 32
    mv a5, t1
    RV_ZEXT a5
    RV_IMM t2, 194, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_utf8_fail
    RV_IMM t2, 223, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_utf8_count
    RV_IMM t1, 3, 32
    mv a3, t1
    RV_ZEXT a3
    RV_IMM t2, 224, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_utf8_not_e0
    RV_IMM t1, 160, 32
    mv a4, t1
    RV_ZEXT a4
    RV_JUMP .Lsmp_utf8_count
.Lsmp_utf8_not_e0:
    RV_IMM t2, 237, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_utf8_not_ed
    RV_IMM t1, 159, 32
    mv a5, t1
    RV_ZEXT a5
    RV_JUMP .Lsmp_utf8_count
.Lsmp_utf8_not_ed:
    RV_IMM t2, 239, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_utf8_count
    RV_IMM t1, 4, 32
    mv a3, t1
    RV_ZEXT a3
    RV_IMM t2, 240, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_utf8_not_f0
    RV_IMM t1, 144, 32
    mv a4, t1
    RV_ZEXT a4
    RV_JUMP .Lsmp_utf8_count
.Lsmp_utf8_not_f0:
    RV_IMM t2, 244, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_utf8_fail
    RV_BCOND ne, .Lsmp_utf8_count
    RV_IMM t1, 143, 32
    mv a5, t1
    RV_ZEXT a5
.Lsmp_utf8_count:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_utf8_fail
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, a4
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_utf8_fail
    mv s8, a2
    mv s10, a5
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_utf8_fail
    RV_IMM t1, 2, 32
    mv a4, t1
    RV_ZEXT a4
.Lsmp_utf8_continuation:
    mv s8, a4
    mv s10, a3
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lsmp_utf8_done
    mv s6, a0
    mv s10, a4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t2, 128, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv a2, s11
    RV_IMM t2, 63, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_utf8_fail
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 32
    mv a4, s11
    RV_JUMP .Lsmp_utf8_continuation
.Lsmp_utf8_done:
    ret
.Lsmp_utf8_fail:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Input: cursor at '-' or digit. Output: zero/one and raw number token.
 * Implements JSON integer/fraction/exponent grammar without conversion.
 * Limit: 256 bytes. All input reads are bounded. Stack: 48 bytes, including
 * alignment padding. */
smp_number:
    RV_SAVE s0
    RV_SAVE s2
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    mv s2, s0
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 45, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_number_integer
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_fail
.Lsmp_number_integer:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_number_zero
    RV_IMM t2, 49, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 8, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_number_fail
.Lsmp_number_integer_digits:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_finish
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_number_integer_digits
    RV_JUMP .Lsmp_number_fraction
.Lsmp_number_zero:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_finish
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_number_fail
.Lsmp_number_fraction:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 46, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_number_exponent
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_fail
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_number_fail
.Lsmp_number_fraction_digits:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_finish
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_number_fraction_digits
.Lsmp_number_exponent:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 32, 32
    mv s10, t2
    or t3, t1, s10
    RV_ZEXT t3
    slliw t1, t3, 24
    RV_ZEXT t1
    mv s8, t1
    mv s10, t1
    RV_FLAGS and, 32
    li s10, 255
    slli s11, t3, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 101, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_number_finish
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_fail
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 43, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_number_exponent_sign
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 45, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_number_exponent_first
.Lsmp_number_exponent_sign:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_fail
.Lsmp_number_exponent_first:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_number_fail
.Lsmp_number_exponent_digits:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_number_finish
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_number_exponent_digits
.Lsmp_number_finish:
    mv a2, s2
    mv s8, a2
    mv s10, s0
    RV_FLAGS sub, 64
    mv a2, s11
    RV_IMM t2, 256, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_number_fail
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE s2, 8
    mv a1, s0
    RV_IMM t1, SMP_NUMBER, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL smp_emit
    RV_JUMP .Lsmp_number_done
.Lsmp_number_fail:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_number_done:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: a0=type, a1=static literal spelling. Output: zero/one and a token.
 * Every input read is bounded by smp_end. No local stack or borrowed data writes. */
smp_literal:
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv a4, t1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lsmp_literal_byte:
    mv s6, a1
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_literal_done
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv a3, s6
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, smp_bad
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a3
    mv s8, s6
    RV_LOAD t2, 1
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, smp_bad
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    RV_JUMP .Lsmp_literal_byte
.Lsmp_literal_done:
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t0, 8
    mv a1, a4
    RV_JUMP smp_emit
/* Input: cursor/end. Advances over SP/TAB/LF/CR only. t0/a3 scratch. */
smp_space:
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
.Lsmp_space_byte:
    RV_ADDR s6, smp_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_space_done
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    mv a3, t1
    RV_ZEXT a3
    li s10, 255
    and t1, a3, s10
    RV_ZEXT t1
    RV_IMM t2, 32, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_space_next
    li s10, 255
    and t1, a3, s10
    RV_ZEXT t1
    RV_IMM t2, 9, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_space_next
    li s10, 255
    and t1, a3, s10
    RV_ZEXT t1
    RV_IMM t2, 10, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_space_next
    li s10, 255
    and t1, a3, s10
    RV_ZEXT t1
    RV_IMM t2, 13, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_space_done
.Lsmp_space_next:
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    RV_JUMP .Lsmp_space_byte
.Lsmp_space_done:
    RV_ADDR s6, smp_cursor
    mv s8, s6
    RV_STORE t0, 8
    ret
/* Input: a0=type/flags, a1=start, a2=length. Output: zero/one.
 * Appends one 32-byte token inside the fixed table. No local stack. */
smp_emit:
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, SMP_TOKEN_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, smp_bad
    mv a3, t0
    slli a3, a3, 5
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv a4, s6
    mv s8, a4
    mv s10, a3
    RV_FLAGS add, 64
    mv a4, s11
    mv s6, a4
    mv s8, s6
    RV_STORE a0, 8
    mv s6, a4
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_STORE a1, 8
    mv s6, a4
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_STORE a2, 8
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    mv s6, a4
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, smp_token_count
    mv s8, s6
    RV_STORE t0, 8
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
smp_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
/* Input: a0/a1=tokens containing bounded spans. Output: t0=1 for raw byte
 * equality, else zero. Callers check kinds. No local stack or memory writes. */
smp_token_equal:
    mv s6, a0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a1
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_equal_no
    mv s6, a0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, a1
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lsmp_equal_byte:
    mv s8, a2
    mv s10, a3
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_equal_yes
    mv s6, a0
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a1
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 1
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_equal_no
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_JUMP .Lsmp_equal_byte
.Lsmp_equal_yes:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.Lsmp_equal_no:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Input: a0=token, a1=NUL-terminated static/validated text. Output: 1/0.
 * Token span is bounded. Does not read past the expected text's NUL. */
smp_token_text_equal:
    mv s6, a0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lsmp_text_byte:
    mv s8, a2
    mv s10, a3
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_text_end
    mv s6, a1
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_equal_no
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 1
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_equal_no
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_JUMP .Lsmp_text_byte
.Lsmp_text_end:
    mv s6, a1
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 0, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_equal_no
    RV_JUMP .Lsmp_equal_yes
smp_plain_equal:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_STRING, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_equal_no
    RV_JUMP smp_token_text_equal
/* Input: two borrowed NUL-terminated validated/static strings. Output: 1/0.
 * No local stack or writes. Used only for the row's fixed identity fields. */
smp_cstr_equal:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a1
    mv s8, s6
    RV_LOAD t2, 1
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_equal_no
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    and t2, t0, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_equal_yes
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_JUMP smp_cstr_equal
/* Input: a0=token, a1=required hex length. Output: 1/0. Requires a plain
 * ASCII string and lowercase hex digits. No local stack or memory writes. */
smp_lower_hex:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_STRING, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_equal_no
    mv s6, a0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, a1
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_equal_no
    mv s6, a0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lsmp_lower_hex_digit:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_lower_hex_next
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 97, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 5, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_equal_no
.Lsmp_lower_hex_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    mv s8, a3
    mv s10, a1
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lsmp_lower_hex_digit
    RV_JUMP .Lsmp_equal_yes
/* Input: bytes token. Output: 1 for canonical decimal 1..64 MiB, else zero.
 * Rejects signs, fractions, exponents, and leading zeroes. No local stack/writes. */
smp_asset_size:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_NUMBER, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_equal_no
    mv s6, a0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 64
    RV_BCOND eq, .Lsmp_equal_no
    RV_IMM t2, 8, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_equal_no
    mv s6, a0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_equal_no
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lsmp_asset_size_digit:
    mv s6, a0
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 9, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lsmp_equal_no
    RV_IMM t2, 10, 64
    mv s10, t2
    mul a4, a4, s10
    mv s8, a4
    mv s10, t0
    RV_FLAGS add, 64
    mv a4, s11
    RV_IMM t2, 67108864, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_equal_no
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    mv s8, a2
    mv s10, a3
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lsmp_asset_size_digit
    RV_JUMP .Lsmp_equal_yes
/* Input: filename token. Output: 1/0. Accepts 1..160 plain ASCII bytes:
 * letters/digits plus '.', '_' and '-'; first byte is a letter or digit.
 * Names are compared, never used as paths. No local stack or writes. */
smp_asset_filename:
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_STRING, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_equal_no
    mv s6, a0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 64
    RV_BCOND eq, .Lsmp_equal_no
    RV_IMM t2, 160, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lsmp_equal_no
    mv s6, a0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lsmp_filename_byte:
    mv s6, a0
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_filename_punctuation
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 57, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_filename_next
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 32, 32
    mv s10, t2
    or t3, t1, s10
    RV_ZEXT t3
    slliw t1, t3, 24
    RV_ZEXT t1
    mv s8, t1
    mv s10, t1
    RV_FLAGS and, 32
    li s10, 255
    slli s11, t3, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 97, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lsmp_filename_punctuation
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 122, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lsmp_filename_next
.Lsmp_filename_punctuation:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_equal_no
    mv s6, a0
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 46, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_filename_next
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 95, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lsmp_filename_next
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 45, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_equal_no
.Lsmp_filename_next:
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    mv s8, a2
    mv s10, a3
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lsmp_filename_byte
    RV_JUMP .Lsmp_equal_yes
/* Input: assets array token. Output: zero/one. Requires 1..256 objects with
 * exactly bytes/file/sha256. Validates every record and rejects repeated
 * filenames. Binds selected filename/bytes/hash to the validated registry row.
 * Stack: 80 saved bytes plus 32 bytes of local token pointers. */
smp_assets:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 32
    sub sp, sp, s10
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_ARRAY, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_assets_fail
    mv s6, a0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    RV_ADDR s6, smp_tokens
    mv t0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS sub, 64
    mv a0, s11
    srli a0, a0, 5
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s3, s6
.Lsmp_assets_item:
    mv s8, s3
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_assets_done
    RV_ADDR s6, smp_asset_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_ASSET_LIMIT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_assets_fail
    mv t0, s3
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv s0, s6
    mv s8, s0
    mv s10, t0
    RV_FLAGS add, 64
    mv s0, s11
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, SMP_OBJECT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_assets_fail
    mv s6, s0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s4, t1
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    RV_IMM t1, 0, 64
    mv s6, sp
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    mv s6, sp
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 8
.Lsmp_asset_member:
    mv s8, s3
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_asset_checked
    mv t0, s3
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, smp_tokens
    mv s0, s6
    mv s8, s0
    mv s10, t0
    RV_FLAGS add, 64
    mv s0, s11
    mv a0, s0
    RV_ADDR s6, smp_key_bytes
    mv a1, s6
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_asset_bytes
    mv a0, s0
    RV_ADDR s6, smp_key_file
    mv a1, s6
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_asset_file
    mv a0, s0
    RV_ADDR s6, smp_key_sha
    mv a1, s6
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_fail
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv a0, s6
    mv s6, sp
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_STORE a0, 8
    RV_IMM t1, 64, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL smp_lower_hex
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_fail
    RV_IMM t2, 4, 32
    mv s10, t2
    or s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_asset_next_member
.Lsmp_asset_bytes:
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv a0, s6
    mv s6, sp
    mv s8, s6
    RV_STORE a0, 8
    RV_CALL smp_asset_size
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_fail
    RV_IMM t2, 1, 32
    mv s10, t2
    or s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_asset_next_member
.Lsmp_asset_file:
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv a0, s6
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_STORE a0, 8
    RV_CALL smp_asset_filename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_fail
    RV_IMM t2, 2, 32
    mv s10, t2
    or s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
.Lsmp_asset_next_member:
    mv s6, s0
    li s10, 56
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    RV_JUMP .Lsmp_asset_member
.Lsmp_asset_checked:
    RV_IMM t2, 7, 32
    mv s8, s5
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsmp_assets_fail
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Lsmp_asset_previous:
    RV_ADDR s6, smp_asset_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lsmp_asset_remember
    RV_ADDR s6, smp_asset_names
    mv t0, s6
    mv s6, t0
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL smp_token_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lsmp_assets_fail
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lsmp_asset_previous
.Lsmp_asset_remember:
    RV_ADDR s6, smp_asset_names
    mv t0, s6
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, t0
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE a2, 8
    RV_ADDR s6, smp_asset_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_asset_count
    mv s8, s6
    RV_STORE t3, 8
    mv a0, a2
    RV_ADDR s6, smp_expected_file
    mv a1, s6
    RV_CALL smp_plain_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_item
    RV_ADDR s6, smp_row
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL smp_token_text_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_fail
    RV_ADDR s6, smp_row
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, sp
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL smp_plain_equal
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lsmp_assets_fail
    RV_ADDR s6, smp_matching_assets
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, smp_matching_assets
    mv s8, s6
    RV_STORE t3, 8
    RV_JUMP .Lsmp_assets_item
.Lsmp_assets_done:
    RV_ADDR s6, smp_matching_assets
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lsmp_assets_fail
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lsmp_assets_return
.Lsmp_assets_fail:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lsmp_assets_return:
    li s10, 32
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
.section .rodata
smp_key_schema: .asciz "schema"
smp_key_project: .asciz "project"
smp_key_repository: .asciz "repository"
smp_key_version: .asciz "version"
smp_key_tag: .asciz "tag"
smp_key_commit: .asciz "source_commit"
smp_key_assets: .asciz "assets"
smp_key_bytes: .asciz "bytes"
smp_key_file: .asciz "file"
smp_key_sha: .asciz "sha256"
smp_project: .asciz "asm"
smp_package: .asciz "stubbi/asm"
smp_repository: .asciz "https://github.com/stubbi/asm"
smp_host: .asciz "riscv64-linux"
smp_host_suffix: .asciz "-riscv64-linux"
smp_executable: .asciz "executable"
smp_true: .asciz "true"
smp_false: .asciz "false"
smp_null: .asciz "null"
.section .bss
.balign 8
smp_cursor: .skip 8
smp_end: .skip 8
smp_row: .skip 8
smp_token_count: .skip 8
smp_commit_pointer: .skip 8
smp_asset_count: .skip 8
smp_matching_assets: .skip 8
smp_expected_tag: .skip 40
smp_expected_file: .skip 64
self_source_commit: .skip 41
.balign 8
smp_asset_names: .skip SMP_ASSET_LIMIT * 8
smp_tokens: .skip SMP_TOKEN_LIMIT * 32
.section .note.GNU-stack,""
