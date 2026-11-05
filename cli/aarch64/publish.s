/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global cmd_publish, validate_source_package

/* Prepare a local registry submission. No upload, login, network or shell.
 * Snapshot each artifact before hashing/validation. Required arguments are
 * explicit; the JSON record never asserts a remote commit or owner was verified.
 * pub_* names own all module state. Returning helpers preserve Asm AArch64 callee
 * registers. Terminal error labels clean the owned registry workspace.
 * Caller-saved integer registers and flags are scratch. Parser helpers that
 * intentionally advance x21 document that exception. Buffers use fixed limits:
 * six 128-byte artifact records, 16 KiB manifest/JSON, 256-byte path components.
 */
/* Native AArch64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each ARM_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */

.section .text
/* Shared source-package boundary for add/sync and publication. x0=archive
 * path, x1=validated owner/name, x2=validated version, x3=validated target.
 * w9=0/1. Preserves Asm AArch64 callee registers and prior publication name/version.
 * Owns the archive/manifest scratch buffers; performs no filesystem mutation.
 * Stack frame: 80 bytes. The compressed artifact digest is the caller's check. */
validate_source_package:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, pub_name
    ldr x10, [x16]
    mov x21, x10
    ARM_ADDR x16, pub_version
    ldr x10, [x16]
    mov x22, x10
    mov x23, x3
    ARM_ADDR x16, pub_name
    str x1, [x16]
    ARM_ADDR x16, pub_version
    str x2, [x16]
    ARM_CALL validate_source_archive
    tst w9, w9
    b.ne .Lpub_package_checked
    mov x0, x23
    ARM_CALL pub_check_project
.Lpub_package_checked:
    ARM_ADDR x16, pub_name
    str x21, [x16]
    ARM_ADDR x16, pub_version
    str x22, [x16]
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

cmd_publish:
    ARM_ADDR x16, pub_dot
    mov x9, x16
    ARM_ADDR x16, pub_source_path
    str x9, [x16]
.Lpub_argument:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lpub_arguments_done
    mov x21, x9
    mov x0, x9
    ARM_ADDR x16, pub_help_option
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpub_help
    mov x0, x21
    ARM_ADDR x16, pub_json_option
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpub_json_mode
    mov x0, x21
    ARM_ADDR x16, pub_no_color_option
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpub_argument
    mov x0, x21
    ARM_ADDR x16, pub_artifact_option
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpub_artifact_argument
    ARM_ADDR x16, pub_options
    mov x19, x16
.Lpub_option_match:
    mov x16, x19
    ldr x10, [x16]
    mov x1, x10
    tst x1, x1
    b.eq pub_bad_arguments
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpub_option_value
    ARM_IMM x11, 24
    adds x19, x19, x11
    b .Lpub_option_match
.Lpub_option_value:
    mov x16, x19
    add x16, x16, #16
    ldr w10, [x16]
    mov w9, w10
    ARM_ADDR x16, pub_fields
    ldr w10, [x16]
    tst w10, w9
    b.ne pub_bad_arguments
    ARM_ADDR x16, pub_fields
    ldr w10, [x16]
    orr w12, w10, w9
    tst w12, w12
    ARM_ADDR x16, pub_fields
    str w12, [x16]
    ARM_CALL pub_arg_value
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
    mov x16, x2
    str x9, [x16]
    b .Lpub_argument
.Lpub_json_mode:
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b .Lpub_argument
.Lpub_artifact_argument:
    ARM_ADDR x16, pub_artifact_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 6
    cmp x9, x11
    b.hs pub_bad_arguments
    lsl x9, x9, #7
    tst x9, x9
    ARM_ADDR x16, pub_artifacts
    mov x22, x16
    adds x22, x22, x9
    eor w19, w19, w19
    tst w19, w19
.Lpub_four_values:
    ARM_CALL pub_arg_value
    mov x16, x22
    add x16, x16, x19, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w19, w19, w11
    ARM_IMM w11, 4
    cmp w19, w11
    b.lo .Lpub_four_values
    ARM_ADDR x16, pub_artifact_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, pub_artifact_count
    str x12, [x16]
    b .Lpub_argument
.Lpub_arguments_done:
    ARM_ADDR x16, pub_fields
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 127
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 127
    cmp w9, w11
    b.ne pub_bad_arguments
    ARM_ADDR x16, pub_artifact_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq pub_bad_arguments
    ARM_ADDR x16, pub_name
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_package
    tst w9, w9
    b.eq pub_bad_metadata
    ARM_ADDR x16, pub_version
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq pub_bad_metadata
    ARM_ADDR x16, pub_summary
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    tst x9, x9
    b.eq pub_bad_metadata
    ARM_IMM x11, 160
    cmp x9, x11
    b.hi pub_bad_metadata
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq pub_bad_metadata
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq pub_bad_metadata
    eor w3, w3, w3
    tst w3, w3
.Lpub_summary_character:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w2, w10
    tst w2, w2
    b.eq .Lpub_license
    ARM_IMM w11, 32
    cmp w2, w11
    b.lo pub_bad_metadata
    ARM_IMM w11, 126
    cmp w2, w11
    b.hi pub_bad_metadata
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lpub_summary_character
.Lpub_license:
    ARM_ADDR x16, pub_license
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, pub_licenses
    mov x1, x16
    ARM_CALL pub_in_strings
    tst w9, w9
    b.eq pub_bad_metadata
    ARM_ADDR x16, pub_repository
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    ARM_IMM x11, 160
    cmp x9, x11
    b.hi pub_bad_metadata
    ARM_ADDR x16, pub_repository_check
    mov x0, x16
    ARM_ADDR x16, pub_repository
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, pub_release_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, pub_repository_check
    mov x0, x16
    ARM_CALL registry_release_url
    tst w9, w9
    b.eq pub_bad_metadata
    ARM_ADDR x16, pub_commit
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    ARM_IMM x11, 40
    cmp x9, x11
    b.ne pub_bad_metadata
    eor w3, w3, w3
    tst w3, w3
    eor w4, w4, w4
    tst w4, w4
.Lpub_commit_character:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    cmp w9, w11
    b.lo pub_bad_metadata
    ARM_IMM w11, 57
    cmp w9, w11
    b.ls .Lpub_commit_digit
    ARM_IMM w11, 97
    cmp w9, w11
    b.lo pub_bad_metadata
    ARM_IMM w11, 102
    cmp w9, w11
    b.hi pub_bad_metadata
.Lpub_commit_digit:
    ARM_IMM w11, 48
    cmp w9, w11
    b.eq .Lpub_commit_next
    ARM_IMM w10, 1
    mov w4, w10
.Lpub_commit_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 40
    cmp w3, w11
    b.lo .Lpub_commit_character
    tst w4, w4
    b.eq pub_bad_metadata
    ARM_ADDR x16, pub_source_path
    ldr x10, [x16]
    mov x0, x10
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lpub_check_artifacts
    ARM_CALL pub_portable_path
    tst w9, w9
    b.ne pub_bad_metadata
.Lpub_check_artifacts:
    eor w21, w21, w21
    tst w21, w21
.Lpub_artifact_metadata:
    ARM_ADDR x16, pub_artifact_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lpub_check_bytes
    mov x9, x21
    lsl x9, x9, #7
    tst x9, x9
    ARM_ADDR x16, pub_artifacts
    mov x22, x16
    adds x22, x22, x9
    mov x16, x22
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_target
    tst w9, w9
    b.eq pub_bad_metadata
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_kind
    tst w9, w9
    b.eq pub_bad_metadata
    mov x16, x22
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_release_url
    tst w9, w9
    b.eq pub_bad_metadata
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 115
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lpub_artifact_duplicates
    mov x16, x22
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    ARM_IMM x11, 7
    cmp x9, x11
    b.lo pub_bad_metadata
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #7
    mov x0, x16
    ARM_ADDR x16, pub_tar_suffix
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq pub_bad_metadata
.Lpub_artifact_duplicates:
    eor w23, w23, w23
    tst w23, w23
.Lpub_duplicate_loop:
    cmp x23, x21
    b.hs .Lpub_artifact_next
    mov x9, x23
    lsl x9, x9, #7
    tst x9, x9
    ARM_ADDR x16, pub_artifacts
    mov x24, x16
    adds x24, x24, x9
    mov x16, x22
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    mov x16, x24
    add x16, x16, #24
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.ne pub_bad_metadata
    mov x16, x22
    ldr x10, [x16]
    mov x0, x10
    mov x16, x24
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lpub_duplicate_next
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x24
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.ne pub_bad_metadata
.Lpub_duplicate_next:
    ARM_IMM x11, 1
    adds x23, x23, x11
    b .Lpub_duplicate_loop
.Lpub_artifact_next:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lpub_artifact_metadata
.Lpub_check_bytes:
    ARM_CALL registry_workspace
    eor w21, w21, w21
    tst w21, w21
.Lpub_artifact_bytes:
    ARM_ADDR x16, pub_artifact_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lpub_write_record
    mov x9, x21
    lsl x9, x9, #7
    tst x9, x9
    ARM_ADDR x16, pub_artifacts
    mov x22, x16
    adds x22, x22, x9
    mov x16, x22
    add x16, x16, #16
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    mov x16, x22
    add x16, x16, #16
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, pub_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi pub_bad_artifact
    ARM_ADDR x16, pub_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne pub_bad_artifact
    ARM_ADDR x16, pub_stat + ARM_STAT_SIZE
    ldr x10, [x16]
    mov x9, x10
    tst x9, x9
    b.le pub_bad_artifact
    ARM_IMM x11, 67108864
    cmp x9, x11
    b.hi pub_bad_artifact
    mov x16, x22
    add x16, x16, #32
    str x9, [x16]
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
    ARM_CALL registry_copy_local
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 115
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lpub_check_elf
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL validate_source_archive
    tst w9, w9
    b.ne pub_bad_artifact
    mov x16, x22
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_check_project
    tst w9, w9
    b.ne pub_bad_project
    b .Lpub_hash
.Lpub_check_elf:
    mov x16, x22
    ldr x10, [x16]
    mov x0, x10
    mov x16, x22
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL pub_validate_elf
    tst w9, w9
    b.ne pub_bad_artifact
.Lpub_hash:
    ARM_CALL pub_hash_payload
    tst w9, w9
    b.ne pub_bad_artifact
    mov x16, x22
    add x16, x16, #40
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_IMM w10, 64
    mov w3, w10
    cbz x3, .Lport_publish_1_end
.Lport_publish_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_publish_1
.Lport_publish_1_end:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL arm_unlink
    tst x9, x9
    b.mi pub_bad_artifact
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lpub_artifact_bytes
.Lpub_write_record:
    ARM_CALL pub_make_json
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_ADDR x16, pub_json
    mov x1, x16
    ARM_ADDR x16, pub_output_created
    mov x2, x16
    ARM_CALL create_exclusive_file
    tst x9, x9
    b.mi pub_output_error
    ARM_IMM x10, -100
    mov x0, x10
    ARM_ADDR x16, registry_temp_index
    mov x1, x16
    ARM_IMM x10, -100
    mov x2, x10
    ARM_ADDR x16, pub_output
    ldr x10, [x16]
    mov x6, x10
    ARM_IMM w10, 1
    mov w4, w10
    ARM_CALL arm_renameat2
    tst x9, x9
    b.mi pub_output_error
    ARM_CALL registry_cleanup
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lpub_report_json
    ARM_ADDR x16, pub_prepared_text
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, pub_output
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL out
    ARM_ADDR x16, pub_review_text
    mov x0, x16
    ARM_CALL out
    b exit_ok
.Lpub_report_json:
    ARM_ADDR x16, pub_report_prefix
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, pub_output
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, pub_report_suffix
    mov x0, x16
    ARM_CALL out
    b exit_ok
.Lpub_help:
    ARM_ADDR x16, pub_help
    mov x0, x16
    ARM_CALL out
    b exit_ok

pub_arg_value:
    ARM_CALL next_arg
    tst x9, x9
    b.eq pub_bad_arguments
    ARM_SAVE x9
    mov x0, x9
    ARM_CALL strlen
    tst x9, x9
    b.eq pub_bad_arguments
    ARM_IMM x11, 4095
    cmp x9, x11
    b.hi pub_bad_arguments
    ARM_RESTORE x9
    ret
pub_bad_arguments:
    ARM_ADDR x16, pub_error_arguments
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b registry_fail
pub_bad_metadata:
    ARM_ADDR x16, pub_error_metadata
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b registry_fail
pub_bad_artifact:
    ARM_ADDR x16, pub_error_artifact
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
pub_bad_project:
    ARM_ADDR x16, pub_error_project
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
pub_output_error:
    ARM_ADDR x16, pub_error_output
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail

/* x0=input string, x1=set of NUL strings followed by a second NUL.
 * w9=1 for a match, 0 otherwise. Read-only; 32 saved stack bytes. */
pub_in_strings:
    ARM_SAVE x19
    ARM_SAVE x21
    mov x19, x1
    mov x21, x0
.Lpub_set_entry:
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_set_absent
    mov x0, x21
    mov x1, x19
    ARM_CALL streq
    tst w9, w9
    b.ne .Lpub_set_return
.Lpub_set_next:
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    mov x16, x19
    add x16, x16, #1
    mov x19, x16
    b.ne .Lpub_set_next
    b .Lpub_set_entry
.Lpub_set_absent:
    eor w9, w9, w9
    tst w9, w9
.Lpub_set_return:
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=NUL path. w9=0/1. Checks 240-byte path bounds before component copies.
 * Rejects Windows device names. Owns pub_component[256]. Frame: 48 bytes. */
pub_portable_path:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x21, x0
    ARM_CALL strlen
    mov x1, x9
    ARM_CALL arc_path_valid
    tst w9, w9
    b.ne .Lpub_portable_return
    mov x19, x21
.Lpub_path_segment:
    ARM_ADDR x16, pub_component
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
    eor w20, w20, w20
    tst w20, w20
.Lpub_path_stem:
    mov x16, x19
    ldrb w10, [x16]
    mov w9, w10
    tst w9, w9
    b.eq .Lpub_path_check_stem
    ARM_IMM w11, 47
    cmp w9, w11
    b.eq .Lpub_path_check_stem
    ARM_IMM w11, 46
    cmp w9, w11
    b.ne .Lpub_path_stem_character
    ARM_IMM w10, 1
    mov w20, w10
.Lpub_path_stem_character:
    tst w20, w20
    b.ne .Lpub_path_stem_next
    ARM_IMM w11, 65
    cmp w9, w11
    b.lo .Lpub_path_stem_copy
    ARM_IMM w11, 90
    cmp w9, w11
    b.hi .Lpub_path_stem_copy
    ARM_IMM w11, 32
    adds w9, w9, w11
.Lpub_path_stem_copy:
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
.Lpub_path_stem_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lpub_path_stem
.Lpub_path_check_stem:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_ADDR x16, pub_reserved
    mov x1, x16
    ARM_CALL pub_in_strings
    tst w9, w9
    b.ne .Lpub_portable_return
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_portable_return
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lpub_path_segment
.Lpub_portable_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Input: successful archive validation. Output: w9=0/1. Reads bounded member
 * paths; rejects credential/VCS/cache names. Owns pub_component. Frame: 80. */
pub_source_paths:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    eor w21, w21, w21
    tst w21, w21
.Lpub_source_path:
    ARM_ADDR x16, arc_entry_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lpub_source_paths_ok
    mov x9, x21
    lsl x9, x9, #8
    tst x9, x9
    ARM_ADDR x16, arc_paths
    mov x22, x16
    adds x22, x22, x9
    mov x0, x22
    ARM_CALL pub_portable_path
    tst w9, w9
    b.ne .Lpub_source_paths_bad
    mov x19, x22
.Lpub_source_component:
    ARM_ADDR x16, pub_component
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
.Lpub_source_component_copy:
    mov x16, x19
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lpub_source_component_check
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_source_component_check
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lpub_source_component_copy
.Lpub_source_component_check:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    mov x16, x0
    ldr w10, [x16]
    ARM_IMM w11, 1986946350
    cmp w10, w11
    b.ne .Lpub_source_component_set
    mov x16, x0
    add x16, x16, #4
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_source_paths_bad
.Lpub_source_component_set:
    ARM_ADDR x16, pub_excluded
    mov x1, x16
    ARM_CALL pub_in_strings
    tst w9, w9
    b.ne .Lpub_source_paths_bad
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_source_extension
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lpub_source_component
.Lpub_source_extension:
    mov x0, x22
    ARM_CALL strlen
    ARM_IMM x11, 4
    cmp x9, x11
    b.lo .Lpub_source_path_next
    mov x16, x22
    add x16, x16, x9
    sub x16, x16, #4
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 538976256
    orr w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 2036689710
    cmp w9, w11
    b.eq .Lpub_source_paths_bad
    ARM_IMM w11, 1835364398
    cmp w9, w11
    b.eq .Lpub_source_paths_bad
.Lpub_source_path_next:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lpub_source_path
.Lpub_source_paths_ok:
    eor w9, w9, w9
    tst w9, w9
    b .Lpub_source_paths_return
.Lpub_source_paths_bad:
    ARM_IMM w10, 1
    mov w9, w10
.Lpub_source_paths_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Inspect the small project manifest inside the validated TAR. The accepted
 * subset uses the shared bounded build/dependency/native-link parser.
 * No escapes or duplicate fields are accepted. Reads use a copied NUL.
 * Input: x0=validated target, pub_name/version and successful archive table.
 * Output: w9=0/1. Owns a 16385-byte manifest and four 256-byte values. Frame: 112. */
pub_check_project:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_ADDR x16, pub_project_target
    str x0, [x16]
    ARM_CALL pub_source_paths
    tst w9, w9
    b.ne .Lpub_project_bad
    ARM_ADDR x16, pub_readme_names
    mov x19, x16
    ARM_CALL pub_any_member
    tst w9, w9
    b.eq .Lpub_project_bad
    ARM_ADDR x16, pub_license_names
    mov x19, x16
    ARM_CALL pub_any_member
    tst w9, w9
    b.eq .Lpub_project_bad
    ARM_ADDR x16, pub_manifest_name
    mov x0, x16
    ARM_CALL source_archive_member
    tst x9, x9
    b.eq .Lpub_project_bad
    tst w3, w3
    b.ne .Lpub_project_bad
    tst x2, x2
    b.eq .Lpub_project_bad
    ARM_IMM x11, 16384
    cmp x2, x11
    b.hi .Lpub_project_bad
    mov x1, x9
    ARM_ADDR x16, pub_manifest
    mov x0, x16
    mov x3, x2
    eor w4, w4, w4
    tst w4, w4
.Lpub_manifest_copy:
    mov x16, x1
    add x16, x16, x4
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lpub_project_bad
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x4
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x4, x4, x11
    cmp x4, x3
    b.lo .Lpub_manifest_copy
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_ADDR x1, rm_archive_metadata
    ARM_CALL rm_parse_manifest
    cbnz w9, .Lpub_project_bad
    ARM_ADDR x0, pub_project_name
    ARM_ADDR x16, rm_archive_metadata + 24
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x0, pub_project_version
    ARM_ADDR x16, rm_archive_metadata + 32
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x0, pub_project_source
    ARM_ADDR x16, rm_archive_metadata + 40
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x0, pub_project_arch
    ARM_ADDR x16, rm_archive_metadata + 48
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, pub_name
    ldr x10, [x16]
    mov x1, x10
.Lpub_unscoped_name:
    mov x16, x1
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_unscoped_found
    ARM_IMM x11, 1
    adds x1, x1, x11
    b .Lpub_unscoped_name
.Lpub_unscoped_found:
    ARM_IMM x11, 1
    adds x1, x1, x11
    ARM_ADDR x16, pub_project_name
    mov x0, x16
    ARM_CALL streq
    tst w9, w9
    b.eq .Lpub_project_bad
    ARM_ADDR x16, pub_project_version
    mov x0, x16
    ARM_ADDR x16, pub_version
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lpub_project_bad
    ARM_ADDR x16, pub_project_arch
    mov x0, x16
    ARM_ADDR x16, pub_project_target
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lpub_project_bad
    ARM_ADDR x16, pub_project_source
    mov x0, x16
    ARM_CALL pub_portable_path
    tst w9, w9
    b.ne .Lpub_project_bad
    ARM_ADDR x16, pub_project_source
    mov x0, x16
    ARM_CALL strlen
    ARM_IMM x11, 2
    cmp x9, x11
    b.lo .Lpub_project_bad
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #2
    ldrh w10, [x16]
    ARM_IMM w11, 29486
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lpub_project_source_lookup
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #2
    ldrh w10, [x16]
    ARM_IMM w11, 21294
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lpub_project_source_lookup
    ARM_IMM x11, 4
    cmp x9, x11
    b.lo .Lpub_project_bad
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #4
    ldr w10, [x16]
    ARM_IMM w11, 1836278062
    cmp w10, w11
    b.ne .Lpub_project_bad
.Lpub_project_source_lookup:
    ARM_CALL source_archive_member
    tst x9, x9
    b.eq .Lpub_project_bad
    tst w3, w3
    b.ne .Lpub_project_bad
    ARM_ADDR x16, rm_archive_metadata + RM_CHECK
    ldr x0, [x16]
    ldrb w10, [x0]
    cbz w10, .Lpub_project_valid
    ARM_CALL pub_portable_path
    cbnz w9, .Lpub_project_bad
    ARM_ADDR x16, rm_archive_metadata + RM_CHECK
    ldr x0, [x16]
    ARM_CALL source_archive_member
    cbz x9, .Lpub_project_bad
    cbnz w3, .Lpub_project_bad
.Lpub_project_valid:
    eor w9, w9, w9
    tst w9, w9
    b .Lpub_project_return
.Lpub_project_bad:
    ARM_IMM w10, 1
    mov w9, w10
.Lpub_project_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x19 points to a pointer list. Return 1 if any listed regular member exists. */
pub_any_member:
    ARM_SAVE x19
.Lpub_any_member_loop:
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.eq .Lpub_no_member
    ARM_CALL source_archive_member
    tst x9, x9
    b.eq .Lpub_member_next
    tst w3, w3
    b.eq .Lpub_member_present
.Lpub_member_next:
    ARM_IMM x11, 8
    adds x19, x19, x11
    b .Lpub_any_member_loop
.Lpub_member_present:
    ARM_IMM w10, 1
    mov w9, w10
    ARM_RESTORE x19
    ret
.Lpub_no_member:
    eor w9, w9, w9
    tst w9, w9
    ARM_RESTORE x19
    ret

/* Generic ELF64 little-endian container checks for all three registry targets.
 * Metadata segments need no memory image. At least one PT_LOAD is required.
 * This does not execute the binary or prove its instruction requirements.
 * x0=validated target, x1=byte size. w9=0/1. Owns fd and 64/56-byte buffers.
 * Stack frame: 112 bytes. Each program header is read separately, at most1024. */
pub_validate_elf:
    /* A Mach-O target must never be accepted by the Linux ELF validator. */
    ARM_SAVE x0
    ARM_SAVE x1
    ARM_ADDR x1, registry_macos
    ARM_CALL streq
    ARM_RESTORE x1
    ARM_RESTORE x0
    cbz w9, .Lpub_linux_executable
    mov w9, #1
    ret
.Lpub_linux_executable:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov x19, x1
    ARM_IMM x10, -1
    mov x21, x10
    ARM_IMM w10, 62
    mov w20, w10
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 120
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_elf_open
    ARM_IMM w10, 183
    mov w20, w10
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_elf_open
    ARM_IMM w10, 243
    mov w20, w10
.Lpub_elf_open:
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_IMM w10, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lpub_elf_bad
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, pub_elf_header
    mov x1, x16
    ARM_IMM w10, 64
    mov w2, w10
    ARM_CALL elf_read_exact
    tst x9, x9
    b.mi .Lpub_elf_bad
    ARM_ADDR x16, pub_elf_header
    mov x22, x16
    mov x16, x22
    ldr w10, [x16]
    ARM_IMM w11, 1179403647
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #4
    ldrh w10, [x16]
    ARM_IMM w11, 258
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #6
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #16
    ldrh w10, [x16]
    mov w9, w10
    ARM_IMM w11, 2
    cmp w9, w11
    b.eq .Lpub_elf_kind
    ARM_IMM w11, 3
    cmp w9, w11
    b.ne .Lpub_elf_bad
.Lpub_elf_kind:
    mov x16, x22
    add x16, x16, #18
    ldrh w10, [x16]
    and w11, w20, #65535
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #20
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #52
    ldrh w10, [x16]
    ARM_IMM w11, 64
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #54
    ldrh w10, [x16]
    ARM_IMM w11, 56
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #56
    ldrh w10, [x16]
    mov w23, w10
    tst w23, w23
    b.eq .Lpub_elf_bad
    ARM_IMM w11, 1024
    cmp w23, w11
    b.hi .Lpub_elf_bad
    mov x16, x22
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_IMM x11, 64
    cmp x1, x11
    b.lo .Lpub_elf_bad
    mov x9, x23
    ARM_IMM x11, 56
    mul x9, x9, x11
    adds x9, x9, x1
    b.cs .Lpub_elf_bad
    cmp x9, x19
    b.hi .Lpub_elf_bad
    mov x0, x21
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_lseek
    mov x16, x22
    add x16, x16, #32
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lpub_elf_bad
    eor w24, w24, w24
    tst w24, w24
.Lpub_elf_segment:
    mov x0, x21
    ARM_ADDR x16, pub_elf_segment
    mov x1, x16
    ARM_IMM w10, 56
    mov w2, w10
    ARM_CALL elf_read_exact
    tst x9, x9
    b.mi .Lpub_elf_bad
    ARM_ADDR x16, pub_elf_segment
    mov x22, x16
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #32
    ldr x11, [x16]
    adds x9, x9, x11
    b.cs .Lpub_elf_bad
    cmp x9, x19
    b.hi .Lpub_elf_bad
    mov x16, x22
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lpub_elf_next
    ARM_IMM w10, 1
    mov w24, w10
    mov x16, x22
    add x16, x16, #32
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, #40
    ldr x11, [x16]
    cmp x9, x11
    b.hi .Lpub_elf_bad
.Lpub_elf_next:
    ARM_IMM x11, 1
    subs x23, x23, x11
    b.ne .Lpub_elf_segment
    tst w24, w24
    b.eq .Lpub_elf_bad
    mov x0, x21
    ARM_CALL arc_close
    eor w9, w9, w9
    tst w9, w9
    b .Lpub_elf_return
.Lpub_elf_bad:
    mov x0, x21
    ARM_CALL arc_close
    ARM_IMM w10, 1
    mov w9, w10
.Lpub_elf_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* sha256sum reads the private payload through stdin. An empty environment and
 * fixed argv prevent filename escaping and environment-supplied behavior.
 * Exactly 68 output bytes are accepted: 64 lowercase hex, two spaces, '-', LF.
 * Input: owned registry_temp_payload. w9=0/1. Owns pub_hash_buffer[72], pipe
 * descriptors and child process. Stack frame: 112 bytes; every child is reaped. */
pub_hash_payload:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_IMM x10, -1
    mov x21, x10
    ARM_IMM x10, -1
    mov x22, x10
    ARM_IMM x10, -1
    mov x23, x10
    ARM_IMM x10, -1
    mov x24, x10
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_IMM w10, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lpub_hash_bad
    mov x0, x9
    ARM_CALL arc_promote_fd
    tst x9, x9
    b.mi .Lpub_hash_bad
    mov x21, x9
    ARM_ADDR x16, pub_pipe
    mov x0, x16
    ARM_IMM w10, 524288
    mov w1, w10
    ARM_CALL arm_pipe2
    tst x9, x9
    b.mi .Lpub_hash_bad
    ARM_ADDR x16, pub_pipe
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arc_promote_fd
    mov x22, x9
    ARM_ADDR x16, pub_pipe + 4
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arc_promote_fd
    mov x23, x9
    tst x22, x22
    b.mi .Lpub_hash_bad
    tst x23, x23
    b.mi .Lpub_hash_bad
    ARM_CALL arm_fork
    tst x9, x9
    b.mi .Lpub_hash_bad
    b.eq .Lpub_hash_child
    mov x24, x9
    mov x0, x21
    ARM_CALL arc_close
    ARM_IMM x10, -1
    mov x21, x10
    mov x0, x23
    ARM_CALL arc_close
    ARM_IMM x10, -1
    mov x23, x10
    eor w19, w19, w19
    tst w19, w19
.Lpub_hash_read:
    mov x0, x22
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    adds x1, x1, x19
    ARM_IMM w10, 69
    mov w2, w10
    subs x2, x2, x19
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lpub_hash_read
    tst x9, x9
    b.mi .Lpub_hash_kill
    b.eq .Lpub_hash_wait
    adds x19, x19, x9
    ARM_IMM x11, 68
    cmp x19, x11
    b.hi .Lpub_hash_kill
    b .Lpub_hash_read
.Lpub_hash_wait:
    mov x0, x24
    ARM_ADDR x16, pub_child_status
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lpub_hash_wait
    tst x9, x9
    b.mi .Lpub_hash_bad
    ARM_ADDR x16, pub_child_status
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lpub_hash_bad
    ARM_IMM x11, 68
    cmp x19, x11
    b.ne .Lpub_hash_bad
    ARM_ADDR x16, pub_hash_buffer + 64
    ldr w10, [x16]
    ARM_IMM w11, 170729504
    cmp w10, w11
    b.ne .Lpub_hash_bad
    eor w3, w3, w3
    tst w3, w3
    ARM_ADDR x16, pub_hash_buffer
    mov x0, x16
.Lpub_hash_hex:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 48
    cmp w9, w11
    b.lo .Lpub_hash_bad
    ARM_IMM w11, 57
    cmp w9, w11
    b.ls .Lpub_hash_hex_next
    ARM_IMM w11, 97
    cmp w9, w11
    b.lo .Lpub_hash_bad
    ARM_IMM w11, 102
    cmp w9, w11
    b.hi .Lpub_hash_bad
.Lpub_hash_hex_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 64
    cmp w3, w11
    b.lo .Lpub_hash_hex
    eor w20, w20, w20
    tst w20, w20
    b .Lpub_hash_close
.Lpub_hash_kill:
    mov x0, x24
    ARM_IMM w10, 9
    mov w1, w10
    ARM_CALL arm_kill
.Lpub_hash_reap:
    mov x0, x24
    ARM_ADDR x16, pub_child_status
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lpub_hash_reap
.Lpub_hash_bad:
    ARM_IMM w10, 1
    mov w20, w10
.Lpub_hash_close:
    mov x0, x21
    ARM_CALL arc_close
    mov x0, x22
    ARM_CALL arc_close
    mov x0, x23
    ARM_CALL arc_close
    mov w9, w20
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.Lpub_hash_child:
    mov x0, x21
    eor w1, w1, w1
    tst w1, w1
    ARM_CALL arm_dup2
    tst x9, x9
    b.mi .Lpub_hash_child_bad
    mov x0, x23
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_dup2
    tst x9, x9
    b.mi .Lpub_hash_child_bad
    mov x0, x21
    ARM_CALL arc_close
    mov x0, x22
    ARM_CALL arc_close
    mov x0, x23
    ARM_CALL arc_close
    ARM_ADDR x16, registry_sha256sum
    mov x0, x16
    ARM_ADDR x16, pub_sha_argv
    mov x1, x16
    ARM_ADDR x16, arc_empty_env
    mov x2, x16
    ARM_CALL arm_execve
.Lpub_hash_child_bad:
    ARM_IMM w10, 126
    mov w0, w10
    ARM_CALL arm_exit
    brk #0

/* Bounded JSON builder. All string input has already passed ASCII validation.
 * It escapes quote/backslash and never writes outside the 16 KiB buffer.
 * Append/quote take x0=NUL text and update pub_json_length. They return void;
 * overflow exits through cleanup. No saved stack frame. Inputs are immutable. */
pub_append:
    ARM_ADDR x16, pub_json_length
    ldr x10, [x16]
    mov x2, x10
    ARM_ADDR x16, pub_json
    mov x4, x16
.Lpub_append_character:
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lpub_append_done
    ARM_IMM x11, 16383
    cmp x2, x11
    b.hs pub_bad_metadata
    and w10, w9, #255
    mov x16, x4
    add x16, x16, x2
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x2, x2, x11
    ARM_IMM x11, 1
    adds x0, x0, x11
    b .Lpub_append_character
.Lpub_append_done:
    ARM_IMM w10, 0
    mov x16, x4
    add x16, x16, x2
    strb w10, [x16]
    ARM_ADDR x16, pub_json_length
    str x2, [x16]
    ret
pub_quote:
    mov x5, x0
    ARM_ADDR x16, pub_quote_text
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_json_length
    ldr x10, [x16]
    mov x2, x10
    ARM_ADDR x16, pub_json
    mov x4, x16
.Lpub_quote_character:
    mov x16, x5
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lpub_quote_end
    ARM_IMM x11, 16380
    cmp x2, x11
    b.hs pub_bad_metadata
    and w10, w9, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lpub_quote_escape
    and w10, w9, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lpub_quote_copy
.Lpub_quote_escape:
    ARM_IMM w10, 92
    mov x16, x4
    add x16, x16, x2
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x2, x2, x11
.Lpub_quote_copy:
    and w10, w9, #255
    mov x16, x4
    add x16, x16, x2
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x2, x2, x11
    ARM_IMM x11, 1
    adds x5, x5, x11
    b .Lpub_quote_character
.Lpub_quote_end:
    ARM_IMM w10, 34
    mov x16, x4
    add x16, x16, x2
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x2, x2, x11
    ARM_IMM w10, 0
    mov x16, x4
    add x16, x16, x2
    strb w10, [x16]
    ARM_ADDR x16, pub_json_length
    str x2, [x16]
    ret
/* Input: validated pub_* metadata/artifacts. Output: pub_json and its length.
 * Writes no file. Owns the 16 KiB JSON and 32-byte decimal buffers. Frame: 48. */
pub_make_json:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_IMM x10, 0
    ARM_ADDR x16, pub_json_length
    str x10, [x16]
    ARM_ADDR x16, pub_json_prefix
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_name
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_version
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_version
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_summary
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_summary
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_license
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_license
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_source
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_repository
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_commit
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_commit
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_path
    mov x0, x16
    ARM_CALL pub_append
    ARM_ADDR x16, pub_source_path
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_artifacts
    mov x0, x16
    ARM_CALL pub_append
    eor w21, w21, w21
    tst w21, w21
.Lpub_json_artifact:
    ARM_ADDR x16, pub_artifact_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Lpub_json_done
    tst x21, x21
    b.eq .Lpub_json_artifact_body
    ARM_ADDR x16, pub_comma
    mov x0, x16
    ARM_CALL pub_append
.Lpub_json_artifact_body:
    mov x9, x21
    lsl x9, x9, #7
    tst x9, x9
    ARM_ADDR x16, pub_artifacts
    mov x22, x16
    adds x22, x22, x9
    ARM_ADDR x16, pub_json_target
    mov x0, x16
    ARM_CALL pub_append
    mov x16, x22
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_kind
    mov x0, x16
    ARM_CALL pub_append
    mov x16, x22
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_hash
    mov x0, x16
    ARM_CALL pub_append
    mov x16, x22
    add x16, x16, #40
    mov x0, x16
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_url
    mov x0, x16
    ARM_CALL pub_append
    mov x16, x22
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL pub_quote
    ARM_ADDR x16, pub_json_bytes
    mov x0, x16
    ARM_CALL pub_append
    mov x16, x22
    add x16, x16, #32
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, pub_number + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x0, x9
    ARM_CALL pub_append
    ARM_ADDR x16, pub_rbrace
    mov x0, x16
    ARM_CALL pub_append
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lpub_json_artifact
.Lpub_json_done:
    ARM_ADDR x16, pub_json_suffix
    mov x0, x16
    ARM_CALL pub_append
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

.section .rodata
pub_dot: .asciz "."
pub_name_option: .asciz "--name"
pub_version_option: .asciz "--version"
pub_summary_option: .asciz "--summary"
pub_license_option: .asciz "--license"
pub_repository_option: .asciz "--repository"
pub_commit_option: .asciz "--commit"
pub_output_option: .asciz "--output"
pub_source_path_option: .asciz "--source-path"
pub_artifact_option: .asciz "--artifact"
pub_help_option: .asciz "--help"
pub_json_option: .asciz "--json"
pub_no_color_option: .asciz "--no-color"
pub_tar_suffix: .asciz ".tar.gz"
pub_release_suffix: .asciz "/releases/download/v1/file"
pub_licenses:
    .asciz "AGPL-3.0-only", "AGPL-3.0-or-later"
    .asciz "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "BSL-1.0"
    .asciz "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later"
    .asciz "ISC", "LGPL-2.1-only", "LGPL-2.1-or-later", "LGPL-3.0-only", "LGPL-3.0-or-later"
    .asciz "MIT", "MPL-2.0", "Unlicense", "Zlib", ""
pub_reserved:
    .asciz "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9"
    .asciz "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", ""
pub_excluded:
    .asciz ".git", ".asm", ".venv", "__pycache__", "build", "dist", ".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", ""
pub_manifest_name: .asciz "asm.toml"
pub_readme_name: .asciz "README"
pub_readme_md: .asciz "README.md"
pub_readme_txt: .asciz "README.txt"
pub_license_name: .asciz "LICENSE"
pub_license_txt: .asciz "LICENSE.txt"
pub_license_md: .asciz "LICENSE.md"
pub_quote_text: .asciz "\""
pub_comma: .asciz ","
pub_rbrace: .asciz "}"
pub_json_prefix: .asciz "{\"schema\":1,\"name\":"
pub_json_version: .asciz ",\"version\":"
pub_json_summary: .asciz ",\"summary\":"
pub_json_license: .asciz ",\"license\":"
pub_json_source: .asciz ",\"source\":{\"repository\":"
pub_json_commit: .asciz ",\"commit\":"
pub_json_path: .asciz ",\"path\":"
pub_json_artifacts: .asciz "},\"artifacts\":["
pub_json_target: .asciz "{\"target\":"
pub_json_kind: .asciz ",\"kind\":"
pub_json_hash: .asciz ",\"sha256\":"
pub_json_url: .asciz ",\"url\":"
pub_json_bytes: .asciz ",\"bytes\":"
pub_json_suffix: .asciz "],\"yanked\":false}\n"
pub_prepared_text: .asciz "Prepared submission: "
pub_review_text: .asciz "\nOpen a registry pull request with this record. Nothing was uploaded.\n"
pub_report_prefix: .asciz "{\"prepared\":true,\"uploaded\":false,\"output\":"
pub_report_suffix: .asciz "}\n"
pub_error_arguments: .asciz "invalid publish arguments; use asm publish --help"
pub_error_metadata: .asciz "invalid publication metadata"
pub_error_artifact: .asciz "artifact validation or hashing failed"
pub_error_project: .asciz "source package is incomplete or does not match publication metadata"
pub_error_output: .asciz "cannot create submission; parent must exist and output must be new"
pub_help:
    .ascii "Usage: asm publish --name owner/name --version X.Y.Z --summary TEXT\n"
    .ascii "  --license SPDX --repository https://github.com/owner/repo\n"
    .ascii "  --commit FULL_COMMIT_ID [--source-path PATH]\n"
    .ascii "  --artifact TARGET KIND FILE URL [--artifact ...] --output FILE [--json]\n\n"
    .ascii "Prepare a local submission for a reviewed registry pull request.\n"
    .ascii "No artifact or metadata is uploaded. No name is reserved.\n"
    .ascii "Upload the exact artifacts to their public GitHub release URLs, then\n"
    .ascii "open a pull request with the generated record. Source-path defaults to .\n"
    .ascii "Supports up to six target/kind artifacts. Source is normalized USTAR gzip.\n"
    .ascii "The source manifest must match name, version and each declared target.\n"
    .ascii "The repository commit is pinned in metadata; its remote existence and\n"
    .asciz "namespace ownership remain publication-review checks. Output is never replaced.\n"
.balign 8
pub_options:
    .quad pub_name_option, pub_name, 1
    .quad pub_version_option, pub_version, 2
    .quad pub_summary_option, pub_summary, 4
    .quad pub_license_option, pub_license, 8
    .quad pub_repository_option, pub_repository, 16
    .quad pub_commit_option, pub_commit, 32
    .quad pub_output_option, pub_output, 64
    .quad pub_source_path_option, pub_source_path, 128
    .quad 0, 0, 0
pub_readme_names: .quad pub_readme_name, pub_readme_md, pub_readme_txt, 0
pub_license_names: .quad pub_license_name, pub_license_txt, pub_license_md, 0
pub_sha_argv: .quad registry_sha256sum, 0
.section .bss
.balign 16
pub_name: .skip 8
pub_version: .skip 8
pub_summary: .skip 8
pub_license: .skip 8
pub_repository: .skip 8
pub_commit: .skip 8
pub_source_path: .skip 8
pub_output: .skip 8
pub_fields: .skip 4
pub_output_created: .skip 1
.balign 8
pub_artifact_count: .skip 8
pub_artifacts: .skip 768
pub_stat: .skip ARM_STAT_BYTES
pub_repository_check: .skip 512
pub_component: .skip 256
pub_project_target: .skip 8
pub_project_name: .skip 256
pub_project_version: .skip 256
pub_project_source: .skip 256
pub_project_arch: .skip 256
pub_manifest: .skip 16385
.balign 8
rm_archive_metadata: .skip RM_SIZE
pub_elf_header: .skip 64
pub_elf_segment: .skip 56
pub_pipe: .skip 8
pub_child_status: .skip 4
pub_hash_buffer: .skip 72
pub_json_length: .skip 8
pub_json: .skip 16384
pub_number: .skip 32
.section .note.GNU-stack,"",%progbits
