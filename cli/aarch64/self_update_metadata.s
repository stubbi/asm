/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and README.md#license for the terms and scope.
 */
.global self_parse_release, self_source_commit

/* Read-only release metadata validation. Authentication belongs to the caller.
 * Limits: 1 MiB input, 32 nested values, 16384 tokens, 256 members per object,
 * 4096 array elements, 16384 raw string bytes, and 256-byte object keys.
 * Keys must be plain ASCII. Unknown strings support JSON escapes, paired
 * UTF-16 surrogate escapes, and valid UTF-8. Identity strings must be plain
 * ASCII. Every object rejects duplicate keys, including ignored metadata.
 * ABI: returning routines preserve x19/x20/x21-x24; others are scratch.
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

/* Input: x0=readable bytes, x1=length, x2=validated registry row (eight
 * NUL-terminated field pointers), selecting stubbi/asm/host/executable with a
 * canonical version, byte count, and SHA-256. Output: w9=0/1 success/failure.
 * Success copies the commit to self_source_commit[41]; failure clears it.
 * Stack: 80 saved bytes plus recursion bounded by 32; each recursive object
 * or array adds at most 128 bytes including call frames. Memory is fixed below.
 */
self_parse_release:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    // Forward string loops do not use a direction flag.
    ARM_ADDR x16, smp_cursor
    str x0, [x16]
    ARM_ADDR x16, smp_row
    str x2, [x16]
    mov x9, x0
    adds x9, x9, x1
    b.cs .Lsmp_entry_fail
    ARM_ADDR x16, smp_end
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, smp_token_count
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, smp_commit_pointer
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, smp_asset_count
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, smp_matching_assets
    str x10, [x16]
    ARM_ADDR x16, self_source_commit
    mov x0, x16
    eor w9, w9, w9
    tst w9, w9
    ARM_IMM w10, 41
    mov w3, w10
    cbz x3, .Lport_self_update_metadata_1_end
.Lport_self_update_metadata_1:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_self_update_metadata_1
.Lport_self_update_metadata_1_end:
    tst x1, x1
    b.eq .Lsmp_entry_fail
    ARM_IMM x11, SMP_INPUT_LIMIT
    cmp x1, x11
    b.hi .Lsmp_entry_fail
    ARM_CALL smp_expected_names
    tst w9, w9
    b.ne .Lsmp_entry_fail
    ARM_IMM w10, 1
    mov w0, w10
    ARM_CALL smp_value
    tst w9, w9
    b.ne .Lsmp_entry_fail
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lsmp_entry_fail
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_OBJECT
    cmp x10, x11
    b.ne .Lsmp_entry_fail
    mov x16, x9
    add x16, x16, #24
    ldr x10, [x16]
    mov x21, x10
    ARM_ADDR x16, smp_token_count
    ldr x11, [x16]
    cmp x21, x11
    b.ne .Lsmp_entry_fail
    ARM_IMM w10, 1
    mov w22, w10
    eor w23, w23, w23
    tst w23, w23
.Lsmp_root_member:
    cmp x22, x21
    b.hs .Lsmp_root_done
    mov x9, x22
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    adds x19, x19, x9
    mov x16, x19
    add x16, x16, #32
    mov x24, x16
    ARM_ADDR x16, smp_key_schema
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_schema
    ARM_ADDR x16, smp_key_project
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_project
    ARM_ADDR x16, smp_key_repository
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_repository
    ARM_ADDR x16, smp_key_version
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_version
    ARM_ADDR x16, smp_key_tag
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_tag
    ARM_ADDR x16, smp_key_commit
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_commit
    ARM_ADDR x16, smp_key_assets
    mov x1, x16
    mov x0, x19
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_root_assets
    b .Lsmp_root_next
.Lsmp_root_schema:
    mov x16, x24
    ldr x10, [x16]
    ARM_IMM x11, SMP_NUMBER
    cmp x10, x11
    b.ne .Lsmp_entry_fail
    mov x16, x24
    add x16, x16, #16
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lsmp_entry_fail
    mov x16, x24
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 49
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_entry_fail
    ARM_IMM w11, 1
    orr w23, w23, w11
    tst w23, w23
    b .Lsmp_root_next
.Lsmp_root_project:
    ARM_ADDR x16, smp_project
    mov x1, x16
    mov x0, x24
    ARM_CALL smp_plain_equal
    tst w9, w9
    b.eq .Lsmp_entry_fail
    ARM_IMM w11, 2
    orr w23, w23, w11
    tst w23, w23
    b .Lsmp_root_next
.Lsmp_root_repository:
    ARM_ADDR x16, smp_repository
    mov x1, x16
    mov x0, x24
    ARM_CALL smp_plain_equal
    tst w9, w9
    b.eq .Lsmp_entry_fail
    ARM_IMM w11, 4
    orr w23, w23, w11
    tst w23, w23
    b .Lsmp_root_next
.Lsmp_root_version:
    ARM_ADDR x16, smp_row
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    mov x0, x24
    ARM_CALL smp_plain_equal
    tst w9, w9
    b.eq .Lsmp_entry_fail
    ARM_IMM w11, 8
    orr w23, w23, w11
    tst w23, w23
    b .Lsmp_root_next
.Lsmp_root_tag:
    ARM_ADDR x16, smp_expected_tag
    mov x1, x16
    mov x0, x24
    ARM_CALL smp_plain_equal
    tst w9, w9
    b.eq .Lsmp_entry_fail
    ARM_IMM w11, 16
    orr w23, w23, w11
    tst w23, w23
    b .Lsmp_root_next
.Lsmp_root_commit:
    mov x0, x24
    ARM_IMM w10, 40
    mov w1, w10
    ARM_CALL smp_lower_hex
    tst w9, w9
    b.eq .Lsmp_entry_fail
    mov x16, x24
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
    eor w3, w3, w3
    tst w3, w3
    eor w9, w9, w9
    tst w9, w9
.Lsmp_nonzero_commit:
    mov x16, x2
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x4, x10, #0, #8
    and w10, w4, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    subs w12, w10, w11
    lsr w12, w12, #24
    bfi x4, x12, #0, #8
    and w10, w9, #255
    and w11, w4, #255
    orr w12, w10, w11
    lsl w10, w12, #24
    tst w10, w10
    bfi x9, x12, #0, #8
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 40
    cmp w3, w11
    b.lo .Lsmp_nonzero_commit
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lsmp_entry_fail
    ARM_ADDR x16, smp_commit_pointer
    str x2, [x16]
    ARM_IMM w11, 32
    orr w23, w23, w11
    tst w23, w23
    b .Lsmp_root_next
.Lsmp_root_assets:
    mov x0, x24
    ARM_CALL smp_assets
    tst w9, w9
    b.ne .Lsmp_entry_fail
    ARM_IMM w11, 64
    orr w23, w23, w11
    tst w23, w23
.Lsmp_root_next:
    mov x16, x24
    add x16, x16, #24
    ldr x10, [x16]
    mov x22, x10
    b .Lsmp_root_member
.Lsmp_root_done:
    ARM_IMM w11, 127
    cmp w23, w11
    b.ne .Lsmp_entry_fail
    ARM_ADDR x16, smp_matching_assets
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lsmp_entry_fail
    ARM_ADDR x16, smp_commit_pointer
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, self_source_commit
    mov x0, x16
    ARM_IMM w10, 40
    mov w3, w10
    cbz x3, .Lport_self_update_metadata_2_end
.Lport_self_update_metadata_2:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_self_update_metadata_2
.Lport_self_update_metadata_2_end:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    eor w9, w9, w9
    tst w9, w9
    b .Lsmp_entry_done
.Lsmp_entry_fail:
    ARM_ADDR x16, self_source_commit
    mov x0, x16
    eor w9, w9, w9
    tst w9, w9
    ARM_IMM w10, 41
    mov w3, w10
    cbz x3, .Lport_self_update_metadata_3_end
.Lport_self_update_metadata_3:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_self_update_metadata_3
.Lport_self_update_metadata_3_end:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_entry_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: smp_row. Output: zero and bounded expected tag/filename strings,
 * or one for a row outside the fixed package/host/kind contract. The version
 * must already be canonical; its defensive length limit is 32. Stack: 48. */
smp_expected_names:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, smp_row
    ldr x10, [x16]
    mov x19, x10
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, smp_package
    mov x1, x16
    ARM_CALL smp_cstr_equal
    tst w9, w9
    b.eq .Lsmp_names_fail
    mov x16, x19
    add x16, x16, #16
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, smp_host
    mov x1, x16
    ARM_CALL smp_cstr_equal
    tst w9, w9
    b.eq .Lsmp_names_fail
    mov x16, x19
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, smp_executable
    mov x1, x16
    ARM_CALL smp_cstr_equal
    tst w9, w9
    b.eq .Lsmp_names_fail
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, smp_expected_tag
    mov x21, x16
    ARM_IMM w10, 118
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_expected_file
    mov x22, x16
    ARM_IMM w10, 762147681
    mov x16, x22
    str w10, [x16]
    ARM_IMM x11, 4
    adds x22, x22, x11
    eor w3, w3, w3
    tst w3, w3
.Lsmp_names_copy:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lsmp_names_suffix
    ARM_IMM w11, 32
    cmp w3, w11
    b.hs .Lsmp_names_fail
    and w10, w9, #255
    mov x16, x21
    add x16, x16, x3
    strb w10, [x16]
    and w10, w9, #255
    mov x16, x22
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lsmp_names_copy
.Lsmp_names_suffix:
    tst w3, w3
    b.eq .Lsmp_names_fail
    ARM_IMM w10, 0
    mov x16, x21
    add x16, x16, x3
    strb w10, [x16]
    adds x22, x22, x3
    ARM_ADDR x16, smp_host_suffix
    mov x1, x16
.Lsmp_names_suffix_byte:
    ldrb w10, [x1], #1
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x22
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x22, x22, x11
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.ne .Lsmp_names_suffix_byte
    eor w9, w9, w9
    tst w9, w9
    b .Lsmp_names_done
.Lsmp_names_fail:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_names_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: w0=value depth, root=1. Output: zero/one, advanced cursor and token
 * count. Checks depth before dispatch. Stack: nested bounded parser calls. */
smp_value:
    ARM_IMM w11, SMP_DEPTH_LIMIT
    cmp w0, w11
    b.hi smp_bad
    sub sp, sp, #16
    ARM_CALL smp_space
    add sp, sp, #16
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs smp_bad
    mov x16, x9
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 123
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq smp_object
    and w10, w9, #255
    ARM_IMM w11, 91
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq smp_array
    and w10, w9, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_value_string
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq smp_number
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lsmp_value_literal
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls smp_number
.Lsmp_value_literal:
    and w10, w9, #255
    ARM_IMM w11, 116
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_value_true
    and w10, w9, #255
    ARM_IMM w11, 102
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_value_false
    and w10, w9, #255
    ARM_IMM w11, 110
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne smp_bad
    ARM_ADDR x16, smp_null
    mov x1, x16
    ARM_IMM w10, SMP_NULL
    mov w0, w10
    b smp_literal
.Lsmp_value_true:
    ARM_ADDR x16, smp_true
    mov x1, x16
    ARM_IMM w10, SMP_TRUE
    mov w0, w10
    b smp_literal
.Lsmp_value_false:
    ARM_ADDR x16, smp_false
    mov x1, x16
    ARM_IMM w10, SMP_FALSE
    mov w0, w10
    b smp_literal
.Lsmp_value_string:
    eor w0, w0, w0
    tst w0, w0
    b smp_string

/* Input: cursor at object, w0=depth. Output: zero/one. Stores member keys as
 * tokens, then compares each key with this object's previous keys. Plain
 * ASCII unescaped keys make raw equality semantic equality. Stack: 80 bytes.
 * At most 256 members; recursive children have exclusive end token indexes. */
smp_object:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov w21, w0
    ARM_ADDR x16, smp_token_count
    ldr x10, [x16]
    mov x22, x10
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    ARM_IMM w10, SMP_OBJECT
    mov w0, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL smp_emit
    tst w9, w9
    b.ne .Lsmp_object_fail
    eor w23, w23, w23
    tst w23, w23
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lsmp_object_fail
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 125
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_object_close
.Lsmp_object_member:
    ARM_IMM w11, 1
    adds w23, w23, w11
    ARM_IMM w11, SMP_MEMBER_LIMIT
    cmp w23, w11
    b.hi .Lsmp_object_fail
    ARM_ADDR x16, smp_token_count
    ldr x10, [x16]
    mov x24, x10
    ARM_IMM w10, 1
    mov w0, w10
    ARM_CALL smp_string
    tst w9, w9
    b.ne .Lsmp_object_fail
    mov x16, x22
    add x16, x16, #1
    mov x19, x16
.Lsmp_object_previous:
    cmp x19, x24
    b.hs .Lsmp_object_colon
    mov x9, x19
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x0, x16
    adds x0, x0, x9
    mov x9, x24
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x1, x16
    adds x1, x1, x9
    ARM_CALL smp_token_equal
    tst w9, w9
    b.ne .Lsmp_object_fail
    mov x9, x19
    ARM_IMM x11, 1
    adds x9, x9, x11
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    add x16, x16, #24
    ldr x10, [x16]
    mov x19, x10
    b .Lsmp_object_previous
.Lsmp_object_colon:
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lsmp_object_fail
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 58
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_object_fail
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    mov x16, x21
    add x16, x16, #1
    mov w0, w16
    ARM_CALL smp_value
    tst w9, w9
    b.ne .Lsmp_object_fail
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lsmp_object_fail
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 125
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_object_close
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 44
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_object_fail
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    ARM_CALL smp_space
    b .Lsmp_object_member
.Lsmp_object_close:
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    mov x9, x22
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x2, x16
    ARM_ADDR x16, smp_token_count
    ldr x10, [x16]
    mov x3, x10
    mov x16, x2
    add x16, x16, x9
    add x16, x16, #24
    str x3, [x16]
    eor w9, w9, w9
    tst w9, w9
    b .Lsmp_object_done
.Lsmp_object_fail:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_object_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: cursor at array, w0=depth. Output: zero/one. Maximum 4096 elements.
 * Each child records its exclusive end token. Stack: 48 saved bytes. */
smp_array:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov w21, w0
    ARM_ADDR x16, smp_token_count
    ldr x10, [x16]
    mov x22, x10
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    ARM_IMM w10, SMP_ARRAY
    mov w0, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL smp_emit
    tst w9, w9
    b.ne .Lsmp_array_fail
    eor w23, w23, w23
    tst w23, w23
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lsmp_array_fail
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_array_close
.Lsmp_array_element:
    ARM_IMM w11, 1
    adds w23, w23, w11
    ARM_IMM w11, SMP_ARRAY_LIMIT
    cmp w23, w11
    b.hi .Lsmp_array_fail
    mov x16, x21
    add x16, x16, #1
    mov w0, w16
    ARM_CALL smp_value
    tst w9, w9
    b.ne .Lsmp_array_fail
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lsmp_array_fail
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_array_close
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 44
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_array_fail
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    b .Lsmp_array_element
.Lsmp_array_close:
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_cursor
    str x12, [x16]
    mov x9, x22
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x2, x16
    ARM_ADDR x16, smp_token_count
    ldr x10, [x16]
    mov x3, x10
    mov x16, x2
    add x16, x16, x9
    add x16, x16, #24
    str x3, [x16]
    eor w9, w9, w9
    tst w9, w9
    b .Lsmp_array_done
.Lsmp_array_fail:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_array_done:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret


/* Input: cursor at quote, w0=1 for plain ASCII key, else value string.
 * Output: zero/one; token excludes quotes and records escape/non-ASCII flags.
 * Every read is bounded. Limits: 256 key bytes, 16 KiB string bytes. Stack:80
 * bytes, including alignment padding. */
smp_string:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    mov w23, w0
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x21, x10
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_string_fail
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_string_fail
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov x19, x21
    eor w22, w22, w22
    tst w22, w22
.Lsmp_string_byte:
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_string_fail
    mov x9, x21
    subs x9, x9, x19
    ARM_IMM x11, SMP_STRING_LIMIT
    cmp x9, x11
    b.hi .Lsmp_string_fail
    tst w23, w23
    b.eq .Lsmp_string_bound_ready
    ARM_IMM x11, SMP_KEY_LIMIT
    cmp x9, x11
    b.hi .Lsmp_string_fail
.Lsmp_string_bound_ready:
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_close
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lsmp_string_fail
    and w10, w9, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape
    and w10, w9, #255
    ARM_IMM w11, 128
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hs .Lsmp_string_utf8
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lsmp_string_byte
.Lsmp_string_escape:
    tst w23, w23
    b.ne .Lsmp_string_fail
    ARM_IMM w11, SMP_ESCAPED
    orr w22, w22, w11
    tst w22, w22
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_string_fail
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 117
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_unicode
    and w10, w9, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 98
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 102
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 110
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 114
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_string_escape_single
    and w10, w9, #255
    ARM_IMM w11, 116
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_string_fail
.Lsmp_string_escape_single:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lsmp_string_byte
.Lsmp_string_unicode:
    mov x16, x21
    add x16, x16, #5
    mov x9, x16
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hi .Lsmp_string_fail
    mov x16, x21
    add x16, x16, #1
    mov x0, x16
    ARM_CALL smp_hex4
    tst w9, w9
    b.mi .Lsmp_string_fail
    ARM_IMM w11, 55296
    cmp w9, w11
    b.lo .Lsmp_string_unicode_single
    ARM_IMM w11, 56319
    cmp w9, w11
    b.ls .Lsmp_string_surrogate
    ARM_IMM w11, 57343
    cmp w9, w11
    b.ls .Lsmp_string_fail
.Lsmp_string_unicode_single:
    ARM_IMM x11, 5
    adds x21, x21, x11
    b .Lsmp_string_byte
.Lsmp_string_surrogate:
    mov x16, x21
    add x16, x16, #11
    mov x9, x16
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hi .Lsmp_string_fail
    mov x16, x21
    add x16, x16, #5
    ldrb w10, [x16]
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_string_fail
    mov x16, x21
    add x16, x16, #6
    ldrb w10, [x16]
    ARM_IMM w11, 117
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_string_fail
    mov x16, x21
    add x16, x16, #7
    mov x0, x16
    ARM_CALL smp_hex4
    ARM_IMM w11, 56320
    cmp w9, w11
    b.lo .Lsmp_string_fail
    ARM_IMM w11, 57343
    cmp w9, w11
    b.hi .Lsmp_string_fail
    ARM_IMM x11, 11
    adds x21, x21, x11
    b .Lsmp_string_byte
.Lsmp_string_utf8:
    tst w23, w23
    b.ne .Lsmp_string_fail
    ARM_IMM w11, SMP_NONASCII
    orr w22, w22, w11
    tst w22, w22
    mov x0, x21
    ARM_CALL smp_utf8
    tst x9, x9
    b.eq .Lsmp_string_fail
    mov x21, x9
    b .Lsmp_string_byte
.Lsmp_string_close:
    mov x16, x21
    add x16, x16, #1
    mov x9, x16
    ARM_ADDR x16, smp_cursor
    str x9, [x16]
    mov x2, x21
    subs x2, x2, x19
    mov x1, x19
    ARM_IMM w10, SMP_STRING
    mov w0, w10
    tst w23, w23
    b.eq .Lsmp_string_type
    ARM_IMM w10, SMP_KEY
    mov w0, w10
.Lsmp_string_type:
    orr w0, w0, w22
    tst w0, w0
    ARM_CALL smp_emit
    b .Lsmp_string_done
.Lsmp_string_fail:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_string_done:
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: x0=four already-bounded bytes. Output: w9=0..65535 or -1.
 * Accepts both JSON hexadecimal letter cases. No local stack or memory writes. */
smp_hex4:
    eor w9, w9, w9
    tst w9, w9
    eor w3, w3, w3
    tst w3, w3
.Lsmp_hex_digit:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w2, w10
    ARM_IMM w11, 48
    subs w2, w2, w11
    ARM_IMM w11, 9
    cmp w2, w11
    b.ls .Lsmp_hex_add
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w2, w10
    ARM_IMM w11, 32
    orr w2, w2, w11
    tst w2, w2
    ARM_IMM w11, 97
    subs w2, w2, w11
    ARM_IMM w11, 5
    cmp w2, w11
    b.hi .Lsmp_hex_fail
    ARM_IMM w11, 10
    adds w2, w2, w11
.Lsmp_hex_add:
    lsl w9, w9, #4
    tst w9, w9
    orr w9, w9, w2
    tst w9, w9
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 4
    cmp w3, w11
    b.lo .Lsmp_hex_digit
    ret
.Lsmp_hex_fail:
    ARM_IMM w10, -1
    mov w9, w10
    ret

/* Input: x0=non-ASCII input byte. Output: x9=next pointer or zero.
 * Rejects overlong UTF-8, surrogates, and values above U+10FFFF. Reads at
 * most four bytes after a full length check. No local stack or memory writes. */
smp_utf8:
    mov x16, x0
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w10, 2
    mov w3, w10
    ARM_IMM w10, 128
    mov w4, w10
    ARM_IMM w10, 191
    mov w5, w10
    ARM_IMM w11, 194
    cmp w9, w11
    b.lo .Lsmp_utf8_fail
    ARM_IMM w11, 223
    cmp w9, w11
    b.ls .Lsmp_utf8_count
    ARM_IMM w10, 3
    mov w3, w10
    ARM_IMM w11, 224
    cmp w9, w11
    b.ne .Lsmp_utf8_not_e0
    ARM_IMM w10, 160
    mov w4, w10
    b .Lsmp_utf8_count
.Lsmp_utf8_not_e0:
    ARM_IMM w11, 237
    cmp w9, w11
    b.ne .Lsmp_utf8_not_ed
    ARM_IMM w10, 159
    mov w5, w10
    b .Lsmp_utf8_count
.Lsmp_utf8_not_ed:
    ARM_IMM w11, 239
    cmp w9, w11
    b.ls .Lsmp_utf8_count
    ARM_IMM w10, 4
    mov w3, w10
    ARM_IMM w11, 240
    cmp w9, w11
    b.ne .Lsmp_utf8_not_f0
    ARM_IMM w10, 144
    mov w4, w10
    b .Lsmp_utf8_count
.Lsmp_utf8_not_f0:
    ARM_IMM w11, 244
    cmp w9, w11
    b.hi .Lsmp_utf8_fail
    b.ne .Lsmp_utf8_count
    ARM_IMM w10, 143
    mov w5, w10
.Lsmp_utf8_count:
    mov x16, x0
    add x16, x16, x3
    mov x9, x16
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hi .Lsmp_utf8_fail
    mov x16, x0
    add x16, x16, #1
    ldrb w10, [x16]
    mov w2, w10
    cmp w2, w4
    b.lo .Lsmp_utf8_fail
    cmp w2, w5
    b.hi .Lsmp_utf8_fail
    ARM_IMM w10, 2
    mov w4, w10
.Lsmp_utf8_continuation:
    cmp w4, w3
    b.hs .Lsmp_utf8_done
    mov x16, x0
    add x16, x16, x4
    ldrb w10, [x16]
    mov w2, w10
    ARM_IMM w11, 128
    subs w2, w2, w11
    ARM_IMM w11, 63
    cmp w2, w11
    b.hi .Lsmp_utf8_fail
    ARM_IMM w11, 1
    adds w4, w4, w11
    b .Lsmp_utf8_continuation
.Lsmp_utf8_done:
    ret
.Lsmp_utf8_fail:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Input: cursor at '-' or digit. Output: zero/one and raw number token.
 * Implements JSON integer/fraction/exponent grammar without conversion.
 * Limit: 256 bytes. All input reads are bounded. Stack: 48 bytes, including
 * alignment padding. */
smp_number:
    ARM_SAVE x19
    ARM_SAVE x21
    sub sp, sp, #16
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x19, x10
    mov x21, x19
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_number_integer
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_fail
.Lsmp_number_integer:
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_number_zero
    ARM_IMM w11, 49
    subs w9, w9, w11
    ARM_IMM w11, 8
    cmp w9, w11
    b.hi .Lsmp_number_fail
.Lsmp_number_integer_digits:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_finish
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.ls .Lsmp_number_integer_digits
    b .Lsmp_number_fraction
.Lsmp_number_zero:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_finish
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.ls .Lsmp_number_fail
.Lsmp_number_fraction:
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_number_exponent
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_fail
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.hi .Lsmp_number_fail
.Lsmp_number_fraction_digits:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_finish
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.ls .Lsmp_number_fraction_digits
.Lsmp_number_exponent:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 32
    orr w12, w10, w11
    lsl w10, w12, #24
    tst w10, w10
    bfi x9, x12, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 101
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_number_finish
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_fail
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 43
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_number_exponent_sign
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_number_exponent_first
.Lsmp_number_exponent_sign:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_fail
.Lsmp_number_exponent_first:
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.hi .Lsmp_number_fail
.Lsmp_number_exponent_digits:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lsmp_number_finish
    mov x16, x21
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.ls .Lsmp_number_exponent_digits
.Lsmp_number_finish:
    mov x2, x21
    subs x2, x2, x19
    ARM_IMM x11, 256
    cmp x2, x11
    b.hi .Lsmp_number_fail
    ARM_ADDR x16, smp_cursor
    str x21, [x16]
    mov x1, x19
    ARM_IMM w10, SMP_NUMBER
    mov w0, w10
    ARM_CALL smp_emit
    b .Lsmp_number_done
.Lsmp_number_fail:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_number_done:
    add sp, sp, #16
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: w0=type, x1=static literal spelling. Output: zero/one and a token.
 * Every input read is bounded by smp_end. No local stack or borrowed data writes. */
smp_literal:
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x4, x10
    eor w2, w2, w2
    tst w2, w2
.Lsmp_literal_byte:
    mov x16, x1
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lsmp_literal_done
    mov x16, x4
    add x16, x16, x2
    mov x3, x16
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x3, x11
    b.hs smp_bad
    and w10, w9, #255
    mov x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne smp_bad
    ARM_IMM w11, 1
    adds w2, w2, w11
    b .Lsmp_literal_byte
.Lsmp_literal_done:
    mov x16, x4
    add x16, x16, x2
    mov x9, x16
    ARM_ADDR x16, smp_cursor
    str x9, [x16]
    mov x1, x4
    b smp_emit

/* Input: cursor/end. Advances over SP/TAB/LF/CR only. x9/x3 scratch. */
smp_space:
    ARM_ADDR x16, smp_cursor
    ldr x10, [x16]
    mov x9, x10
.Lsmp_space_byte:
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lsmp_space_done
    mov x16, x9
    ldrb w10, [x16]
    mov w3, w10
    and w10, w3, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_space_next
    and w10, w3, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_space_next
    and w10, w3, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_space_next
    and w10, w3, #255
    ARM_IMM w11, 13
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_space_done
.Lsmp_space_next:
    ARM_IMM x11, 1
    adds x9, x9, x11
    b .Lsmp_space_byte
.Lsmp_space_done:
    ARM_ADDR x16, smp_cursor
    str x9, [x16]
    ret

/* Input: w0=type/flags, x1=start, x2=length. Output: zero/one.
 * Appends one 32-byte token inside the fixed table. No local stack. */
smp_emit:
    ARM_ADDR x16, smp_token_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, SMP_TOKEN_LIMIT
    cmp x9, x11
    b.hs smp_bad
    mov x3, x9
    lsl x3, x3, #5
    tst x3, x3
    ARM_ADDR x16, smp_tokens
    mov x4, x16
    adds x4, x4, x3
    mov x16, x4
    str x0, [x16]
    mov x16, x4
    add x16, x16, #8
    str x1, [x16]
    mov x16, x4
    add x16, x16, #16
    str x2, [x16]
    ARM_IMM x11, 1
    adds x9, x9, x11
    mov x16, x4
    add x16, x16, #24
    str x9, [x16]
    ARM_ADDR x16, smp_token_count
    str x9, [x16]
    eor w9, w9, w9
    tst w9, w9
    ret
smp_bad:
    ARM_IMM w10, 1
    mov w9, w10
    ret


/* Input: x0/x1=tokens containing bounded spans. Output: w9=1 for raw byte
 * equality, else zero. Callers check kinds. No local stack or memory writes. */
smp_token_equal:
    mov x16, x0
    add x16, x16, #16
    ldr x10, [x16]
    mov x3, x10
    mov x16, x1
    add x16, x16, #16
    ldr x11, [x16]
    cmp x3, x11
    b.ne .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x1
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    eor w2, w2, w2
    tst w2, w2
.Lsmp_equal_byte:
    cmp x2, x3
    b.hs .Lsmp_equal_yes
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x1
    add x16, x16, x2
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_equal_no
    ARM_IMM x11, 1
    adds x2, x2, x11
    b .Lsmp_equal_byte
.Lsmp_equal_yes:
    ARM_IMM w10, 1
    mov w9, w10
    ret
.Lsmp_equal_no:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Input: x0=token, x1=NUL-terminated static/validated text. Output: 1/0.
 * Token span is bounded. Does not read past the expected text's NUL. */
smp_token_text_equal:
    mov x16, x0
    add x16, x16, #16
    ldr x10, [x16]
    mov x3, x10
    mov x16, x0
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    eor w2, w2, w2
    tst w2, w2
.Lsmp_text_byte:
    cmp x2, x3
    b.hs .Lsmp_text_end
    mov x16, x1
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lsmp_equal_no
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x2
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_equal_no
    ARM_IMM x11, 1
    adds x2, x2, x11
    b .Lsmp_text_byte
.Lsmp_text_end:
    mov x16, x1
    add x16, x16, x2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_equal_no
    b .Lsmp_equal_yes
smp_plain_equal:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_STRING
    cmp x10, x11
    b.ne .Lsmp_equal_no
    b smp_token_text_equal

/* Input: two borrowed NUL-terminated validated/static strings. Output: 1/0.
 * No local stack or writes. Used only for the row's fixed identity fields. */
smp_cstr_equal:
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x1
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_equal_no
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lsmp_equal_yes
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM x11, 1
    adds x1, x1, x11
    b smp_cstr_equal

/* Input: x0=token, w1=required hex length. Output: 1/0. Requires a plain
 * ASCII string and lowercase hex digits. No local stack or memory writes. */
smp_lower_hex:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_STRING
    cmp x10, x11
    b.ne .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #16
    ldr x10, [x16]
    cmp x10, x1
    b.ne .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    eor w3, w3, w3
    tst w3, w3
.Lsmp_lower_hex_digit:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.ls .Lsmp_lower_hex_next
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 97
    subs w9, w9, w11
    ARM_IMM w11, 5
    cmp w9, w11
    b.hi .Lsmp_equal_no
.Lsmp_lower_hex_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    cmp x3, x1
    b.lo .Lsmp_lower_hex_digit
    b .Lsmp_equal_yes

/* Input: bytes token. Output: 1 for canonical decimal 1..64 MiB, else zero.
 * Rejects signs, fractions, exponents, and leading zeroes. No local stack/writes. */
smp_asset_size:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_NUMBER
    cmp x10, x11
    b.ne .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #16
    ldr x10, [x16]
    mov x3, x10
    tst x3, x3
    b.eq .Lsmp_equal_no
    ARM_IMM x11, 8
    cmp x3, x11
    b.hi .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_equal_no
    eor w4, w4, w4
    tst w4, w4
    eor w2, w2, w2
    tst w2, w2
.Lsmp_asset_size_digit:
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM w11, 9
    cmp w9, w11
    b.hi .Lsmp_equal_no
    ARM_IMM x11, 10
    mul x4, x4, x11
    adds x4, x4, x9
    ARM_IMM x11, 67108864
    cmp x4, x11
    b.hi .Lsmp_equal_no
    ARM_IMM w11, 1
    adds w2, w2, w11
    cmp x2, x3
    b.lo .Lsmp_asset_size_digit
    b .Lsmp_equal_yes

/* Input: filename token. Output: 1/0. Accepts 1..160 plain ASCII bytes:
 * letters/digits plus '.', '_' and '-'; first byte is a letter or digit.
 * Names are compared, never used as paths. No local stack or writes. */
smp_asset_filename:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_STRING
    cmp x10, x11
    b.ne .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #16
    ldr x10, [x16]
    mov x3, x10
    tst x3, x3
    b.eq .Lsmp_equal_no
    ARM_IMM x11, 160
    cmp x3, x11
    b.hi .Lsmp_equal_no
    mov x16, x0
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    eor w2, w2, w2
    tst w2, w2
.Lsmp_filename_byte:
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lsmp_filename_punctuation
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lsmp_filename_next
    and w10, w9, #255
    ARM_IMM w11, 32
    orr w12, w10, w11
    lsl w10, w12, #24
    tst w10, w10
    bfi x9, x12, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lsmp_filename_punctuation
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lsmp_filename_next
.Lsmp_filename_punctuation:
    tst w2, w2
    b.eq .Lsmp_equal_no
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_filename_next
    and w10, w9, #255
    ARM_IMM w11, 95
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsmp_filename_next
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsmp_equal_no
.Lsmp_filename_next:
    ARM_IMM w11, 1
    adds w2, w2, w11
    cmp x2, x3
    b.lo .Lsmp_filename_byte
    b .Lsmp_equal_yes

/* Input: assets array token. Output: zero/one. Requires 1..256 objects with
 * exactly bytes/file/sha256. Validates every record and rejects repeated
 * filenames. Binds selected filename/bytes/hash to the validated registry row.
 * Stack: 80 saved bytes plus 32 bytes of local token pointers. */
smp_assets:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #32
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne .Lsmp_assets_fail
    mov x16, x0
    add x16, x16, #24
    ldr x10, [x16]
    mov x21, x10
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    subs x0, x0, x9
    lsr x0, x0, #5
    tst x0, x0
    mov x16, x0
    add x16, x16, #1
    mov x22, x16
.Lsmp_assets_item:
    cmp x22, x21
    b.hs .Lsmp_assets_done
    ARM_ADDR x16, smp_asset_count
    ldr x10, [x16]
    ARM_IMM x11, SMP_ASSET_LIMIT
    cmp x10, x11
    b.hs .Lsmp_assets_fail
    mov x9, x22
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    adds x19, x19, x9
    mov x16, x19
    ldr x10, [x16]
    ARM_IMM x11, SMP_OBJECT
    cmp x10, x11
    b.ne .Lsmp_assets_fail
    mov x16, x19
    add x16, x16, #24
    ldr x10, [x16]
    mov x23, x10
    ARM_IMM x11, 1
    adds x22, x22, x11
    eor w24, w24, w24
    tst w24, w24
    ARM_IMM x10, 0
    mov x16, sp
    str x10, [x16]
    ARM_IMM x10, 0
    mov x16, sp
    add x16, x16, #8
    str x10, [x16]
    ARM_IMM x10, 0
    mov x16, sp
    add x16, x16, #16
    str x10, [x16]
.Lsmp_asset_member:
    cmp x22, x23
    b.hs .Lsmp_asset_checked
    mov x9, x22
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    adds x19, x19, x9
    mov x0, x19
    ARM_ADDR x16, smp_key_bytes
    mov x1, x16
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_asset_bytes
    mov x0, x19
    ARM_ADDR x16, smp_key_file
    mov x1, x16
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.ne .Lsmp_asset_file
    mov x0, x19
    ARM_ADDR x16, smp_key_sha
    mov x1, x16
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.eq .Lsmp_assets_fail
    mov x16, x19
    add x16, x16, #32
    mov x0, x16
    mov x16, sp
    add x16, x16, #16
    str x0, [x16]
    ARM_IMM w10, 64
    mov w1, w10
    ARM_CALL smp_lower_hex
    tst w9, w9
    b.eq .Lsmp_assets_fail
    ARM_IMM w11, 4
    orr w24, w24, w11
    tst w24, w24
    b .Lsmp_asset_next_member
.Lsmp_asset_bytes:
    mov x16, x19
    add x16, x16, #32
    mov x0, x16
    mov x16, sp
    str x0, [x16]
    ARM_CALL smp_asset_size
    tst w9, w9
    b.eq .Lsmp_assets_fail
    ARM_IMM w11, 1
    orr w24, w24, w11
    tst w24, w24
    b .Lsmp_asset_next_member
.Lsmp_asset_file:
    mov x16, x19
    add x16, x16, #32
    mov x0, x16
    mov x16, sp
    add x16, x16, #8
    str x0, [x16]
    ARM_CALL smp_asset_filename
    tst w9, w9
    b.eq .Lsmp_assets_fail
    ARM_IMM w11, 2
    orr w24, w24, w11
    tst w24, w24
.Lsmp_asset_next_member:
    mov x16, x19
    add x16, x16, #56
    ldr x10, [x16]
    mov x22, x10
    b .Lsmp_asset_member
.Lsmp_asset_checked:
    ARM_IMM w11, 7
    cmp w24, w11
    b.ne .Lsmp_assets_fail
    eor w19, w19, w19
    tst w19, w19
.Lsmp_asset_previous:
    ARM_ADDR x16, smp_asset_count
    ldr x11, [x16]
    cmp x19, x11
    b.hs .Lsmp_asset_remember
    ARM_ADDR x16, smp_asset_names
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    ldr x10, [x16]
    mov x0, x10
    mov x16, sp
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL smp_token_equal
    tst w9, w9
    b.ne .Lsmp_assets_fail
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lsmp_asset_previous
.Lsmp_asset_remember:
    ARM_ADDR x16, smp_asset_names
    mov x9, x16
    mov x16, sp
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
    mov x16, x9
    add x16, x16, x19, lsl #3
    str x2, [x16]
    ARM_ADDR x16, smp_asset_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_asset_count
    str x12, [x16]
    mov x0, x2
    ARM_ADDR x16, smp_expected_file
    mov x1, x16
    ARM_CALL smp_plain_equal
    tst w9, w9
    b.eq .Lsmp_assets_item
    ARM_ADDR x16, smp_row
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    add x16, x16, #48
    ldr x10, [x16]
    mov x1, x10
    mov x16, sp
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL smp_token_text_equal
    tst w9, w9
    b.eq .Lsmp_assets_fail
    ARM_ADDR x16, smp_row
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    mov x16, sp
    add x16, x16, #16
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL smp_plain_equal
    tst w9, w9
    b.eq .Lsmp_assets_fail
    ARM_ADDR x16, smp_matching_assets
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, smp_matching_assets
    str x12, [x16]
    b .Lsmp_assets_item
.Lsmp_assets_done:
    ARM_ADDR x16, smp_matching_assets
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lsmp_assets_fail
    eor w9, w9, w9
    tst w9, w9
    b .Lsmp_assets_return
.Lsmp_assets_fail:
    ARM_IMM w10, 1
    mov w9, w10
.Lsmp_assets_return:
    add sp, sp, #32
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
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
smp_host: .asciz "aarch64-linux"
smp_host_suffix: .asciz "-aarch64-linux"
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

.section .note.GNU-stack,"",%progbits
