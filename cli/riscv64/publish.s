/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/publish.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global cmd_publish, validate_source_package
/* Prepare a local registry submission. No upload, login, network or shell.
 * Snapshot each artifact before hashing/validation. Required arguments are
 * explicit; the JSON record never asserts a remote commit or owner was verified.
 * pub_* names own all module state. Returning helpers preserve Asm RISC-V64 callee
 * registers. Terminal error labels clean the owned registry workspace.
 * Caller-saved integer registers and flags are scratch. Parser helpers that
 * intentionally advance s2 document that exception. Buffers use fixed limits:
 * six 128-byte artifact records, 16 KiB manifest/JSON, 256-byte path components.
 */
/* Native RISC-V64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each RV_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */
.section .text
/* Shared source-package boundary for add/sync and publication. a0=archive
 * path, a1=validated owner/name, a2=validated version, a3=validated target.
 * t0=0/1. Preserves Asm RISC-V64 callee registers and prior publication name/version.
 * Owns the archive/manifest scratch buffers; performs no filesystem mutation.
 * Stack frame: 80 bytes. The compressed artifact digest is the caller's check. */
validate_source_package:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s6, pub_name
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    RV_ADDR s6, pub_version
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    mv s4, a3
    RV_ADDR s6, pub_name
    mv s8, s6
    RV_STORE a1, 8
    RV_ADDR s6, pub_version
    mv s8, s6
    RV_STORE a2, 8
    RV_CALL validate_source_archive
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_package_checked
    mv a0, s4
    RV_CALL pub_check_project
.Lpub_package_checked:
    RV_ADDR s6, pub_name
    mv s8, s6
    RV_STORE s2, 8
    RV_ADDR s6, pub_version
    mv s8, s6
    RV_STORE s3, 8
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
cmd_publish:
    RV_ADDR s6, pub_dot
    mv t0, s6
    RV_ADDR s6, pub_source_path
    mv s8, s6
    RV_STORE t0, 8
.Lpub_argument:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_arguments_done
    mv s2, t0
    mv a0, t0
    RV_ADDR s6, pub_help_option
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_help
    mv a0, s2
    RV_ADDR s6, pub_json_option
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_json_mode
    mv a0, s2
    RV_ADDR s6, pub_no_color_option
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_argument
    mv a0, s2
    RV_ADDR s6, pub_artifact_option
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_artifact_argument
    RV_ADDR s6, pub_options
    mv s0, s6
.Lpub_option_match:
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND eq, pub_bad_arguments
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_option_value
    RV_IMM t2, 24, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lpub_option_match
.Lpub_option_value:
    mv s6, s0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_ADDR s6, pub_fields
    mv s8, s6
    RV_LOAD t1, 4
    mv s8, t1
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_arguments
    RV_ADDR s6, pub_fields
    mv s8, s6
    RV_LOAD t1, 4
    mv s10, t0
    or t3, t1, s10
    RV_ZEXT t3
    mv s8, t3
    mv s10, t3
    RV_FLAGS and, 32
    RV_ADDR s6, pub_fields
    mv s8, s6
    RV_STORE t3, 4
    RV_CALL pub_arg_value
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, a2
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Lpub_argument
.Lpub_json_mode:
    RV_IMM t1, 1, 32
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lpub_argument
.Lpub_artifact_argument:
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 6, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, pub_bad_arguments
    slli t0, t0, 7
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, pub_artifacts
    mv s3, s6
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Lpub_four_values:
    RV_CALL pub_arg_value
    mv s6, s3
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t2, 1, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 32
    mv s0, s11
    RV_IMM t2, 4, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lpub_four_values
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_STORE t3, 8
    RV_JUMP .Lpub_argument
.Lpub_arguments_done:
    RV_ADDR s6, pub_fields
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 127, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 127, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, pub_bad_arguments
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, pub_bad_arguments
    RV_ADDR s6, pub_name
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    RV_ADDR s6, pub_version
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    RV_ADDR s6, pub_summary
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, pub_bad_metadata
    RV_IMM t2, 160, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, pub_bad_metadata
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, pub_bad_metadata
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 1
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 32, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, pub_bad_metadata
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lpub_summary_character:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_license
    RV_IMM t2, 32, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, pub_bad_metadata
    RV_IMM t2, 126, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, pub_bad_metadata
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lpub_summary_character
.Lpub_license:
    RV_ADDR s6, pub_license
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, pub_licenses
    mv a1, s6
    RV_CALL pub_in_strings
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    RV_ADDR s6, pub_repository
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    RV_IMM t2, 160, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, pub_bad_metadata
    RV_ADDR s6, pub_repository_check
    mv a0, s6
    RV_ADDR s6, pub_repository
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, pub_release_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, pub_repository_check
    mv a0, s6
    RV_CALL registry_release_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    RV_ADDR s6, pub_commit
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    RV_IMM t2, 40, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, pub_bad_metadata
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
.Lpub_commit_character:
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
    RV_BCOND lo, pub_bad_metadata
    RV_IMM t2, 57, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lpub_commit_digit
    RV_IMM t2, 97, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, pub_bad_metadata
    RV_IMM t2, 102, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, pub_bad_metadata
.Lpub_commit_digit:
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_commit_next
    RV_IMM t1, 1, 32
    mv a4, t1
    RV_ZEXT a4
.Lpub_commit_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 40, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lpub_commit_character
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    RV_ADDR s6, pub_source_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 46, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_check_artifacts
    RV_CALL pub_portable_path
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_metadata
.Lpub_check_artifacts:
    mv s10, s2
    xor s2, s2, s10
    RV_ZEXT s2
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 32
.Lpub_artifact_metadata:
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lpub_check_bytes
    mv t0, s2
    slli t0, t0, 7
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, pub_artifacts
    mv s3, s6
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_kind
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    mv s6, s3
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_release_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 115, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_artifact_duplicates
    mv s6, s3
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    RV_IMM t2, 7, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, pub_bad_metadata
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 7
    sub s6, s6, s10
    mv a0, s6
    RV_ADDR s6, pub_tar_suffix
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, pub_bad_metadata
.Lpub_artifact_duplicates:
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Lpub_duplicate_loop:
    mv s8, s4
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lpub_artifact_next
    mv t0, s4
    slli t0, t0, 7
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, pub_artifacts
    mv s5, s6
    mv s8, s5
    mv s10, t0
    RV_FLAGS add, 64
    mv s5, s11
    mv s6, s3
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s5
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_metadata
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s5
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_duplicate_next
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s5
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_metadata
.Lpub_duplicate_next:
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 64
    mv s4, s11
    RV_JUMP .Lpub_duplicate_loop
.Lpub_artifact_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lpub_artifact_metadata
.Lpub_check_bytes:
    RV_CALL registry_workspace
    mv s10, s2
    xor s2, s2, s10
    RV_ZEXT s2
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 32
.Lpub_artifact_bytes:
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lpub_write_record
    mv t0, s2
    slli t0, t0, 7
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, pub_artifacts
    mv s3, s6
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_STORE t0, 8
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, pub_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, pub_bad_artifact
    RV_ADDR s6, pub_stat + RV_STAT_MODE
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 61440, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 32768, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, pub_bad_artifact
    RV_ADDR s6, pub_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND le, pub_bad_artifact
    RV_IMM t2, 67108864, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, pub_bad_artifact
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_copy_local
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, t0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 115, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_check_elf
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_CALL validate_source_archive
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_artifact
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_check_project
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_project
    RV_JUMP .Lpub_hash
.Lpub_check_elf:
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL pub_validate_elf
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_artifact
.Lpub_hash:
    RV_CALL pub_hash_payload
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, pub_bad_artifact
    mv s6, s3
    li s10, 40
    add s6, s6, s10
    mv a0, s6
    RV_ADDR s6, pub_hash_buffer
    mv a1, s6
    RV_IMM t1, 64, 32
    mv a3, t1
    RV_ZEXT a3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_publish537
    RV_JUMP .Lport_publish_1_end
.Lrv_cb_skip_publish537:
.Lport_publish_1:
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
    beqz s8, .Lrv_cb_skip_publish542
    RV_JUMP .Lport_publish_1
.Lrv_cb_skip_publish542:
.Lport_publish_1_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_CALL rv_unlink
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, pub_bad_artifact
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lpub_artifact_bytes
.Lpub_write_record:
    RV_CALL pub_make_json
    RV_ADDR s6, registry_temp_index
    mv a0, s6
    RV_ADDR s6, pub_json
    mv a1, s6
    RV_ADDR s6, pub_output_created
    mv a2, s6
    RV_CALL create_exclusive_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, pub_output_error
    RV_IMM t1, -100, 64
    mv a0, t1
    RV_ADDR s6, registry_temp_index
    mv a1, s6
    RV_IMM t1, -100, 64
    mv a2, t1
    RV_ADDR s6, pub_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a6, t1
    RV_IMM t1, 1, 32
    mv a4, t1
    RV_ZEXT a4
    RV_CALL rv_renameat2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, pub_output_error
    RV_CALL registry_cleanup
    RV_ADDR s6, json_mode
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
    RV_BCOND ne, .Lpub_report_json
    RV_ADDR s6, pub_prepared_text
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, pub_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL out
    RV_ADDR s6, pub_review_text
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
.Lpub_report_json:
    RV_ADDR s6, pub_report_prefix
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, pub_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, pub_report_suffix
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
.Lpub_help:
    RV_ADDR s6, pub_help
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
pub_arg_value:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, pub_bad_arguments
    RV_SAVE t0
    mv a0, t0
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, pub_bad_arguments
    RV_IMM t2, 4095, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, pub_bad_arguments
    RV_RESTORE t0
    ret
pub_bad_arguments:
    RV_ADDR s6, pub_error_arguments
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
pub_bad_metadata:
    RV_ADDR s6, pub_error_metadata
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
pub_bad_artifact:
    RV_ADDR s6, pub_error_artifact
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
pub_bad_project:
    RV_ADDR s6, pub_error_project
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
pub_output_error:
    RV_ADDR s6, pub_error_output
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
/* a0=input string, a1=set of NUL strings followed by a second NUL.
 * t0=1 for a match, 0 otherwise. Read-only; 32 saved stack bytes. */
pub_in_strings:
    RV_SAVE s0
    RV_SAVE s2
    mv s0, a1
    mv s2, a0
.Lpub_set_entry:
    mv s6, s0
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
    RV_BCOND eq, .Lpub_set_absent
    mv a0, s2
    mv a1, s0
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_set_return
.Lpub_set_next:
    mv s6, s0
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
    mv s6, s0
    li s10, 1
    add s6, s6, s10
    mv s0, s6
    RV_BCOND ne, .Lpub_set_next
    RV_JUMP .Lpub_set_entry
.Lpub_set_absent:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Lpub_set_return:
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* a0=NUL path. t0=0/1. Checks 240-byte path bounds before component copies.
 * Rejects Windows device names. Owns pub_component[256]. Frame: 48 bytes. */
pub_portable_path:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s2, a0
    RV_CALL strlen
    mv a1, t0
    RV_CALL arc_path_valid
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_portable_return
    mv s0, s2
.Lpub_path_segment:
    RV_ADDR s6, pub_component
    mv a0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    mv s10, s1
    xor s1, s1, s10
    RV_ZEXT s1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
.Lpub_path_stem:
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_path_check_stem
    RV_IMM t2, 47, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_path_check_stem
    RV_IMM t2, 46, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_path_stem_character
    RV_IMM t1, 1, 32
    mv s1, t1
    RV_ZEXT s1
.Lpub_path_stem_character:
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_path_stem_next
    RV_IMM t2, 65, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lpub_path_stem_copy
    RV_IMM t2, 90, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lpub_path_stem_copy
    RV_IMM t2, 32, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 32
    mv t0, s11
.Lpub_path_stem_copy:
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
.Lpub_path_stem_next:
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lpub_path_stem
.Lpub_path_check_stem:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, pub_reserved
    mv a1, s6
    RV_CALL pub_in_strings
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_portable_return
    mv s6, s0
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
    RV_BCOND eq, .Lpub_portable_return
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lpub_path_segment
.Lpub_portable_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Input: successful archive validation. Output: t0=0/1. Reads bounded member
 * paths; rejects credential/VCS/cache names. Owns pub_component. Frame: 80. */
pub_source_paths:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    mv s10, s2
    xor s2, s2, s10
    RV_ZEXT s2
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 32
.Lpub_source_path:
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lpub_source_paths_ok
    mv t0, s2
    slli t0, t0, 8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_paths
    mv s3, s6
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    mv a0, s3
    RV_CALL pub_portable_path
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_source_paths_bad
    mv s0, s3
.Lpub_source_component:
    RV_ADDR s6, pub_component
    mv a0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lpub_source_component_copy:
    mv s6, s0
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
    RV_BCOND eq, .Lpub_source_component_check
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
    RV_BCOND eq, .Lpub_source_component_check
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lpub_source_component_copy
.Lpub_source_component_check:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1986946350, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_source_component_set
    mv s6, a0
    li s10, 4
    add s6, s6, s10
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
    RV_BCOND eq, .Lpub_source_paths_bad
.Lpub_source_component_set:
    RV_ADDR s6, pub_excluded
    mv a1, s6
    RV_CALL pub_in_strings
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_source_paths_bad
    mv s6, s0
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
    RV_BCOND eq, .Lpub_source_extension
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lpub_source_component
.Lpub_source_extension:
    mv a0, s3
    RV_CALL strlen
    RV_IMM t2, 4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lpub_source_path_next
    mv s6, s3
    mv s10, t0
    add s6, s6, s10
    li s10, 4
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 538976256, 32
    mv s10, t2
    or t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 2036689710, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_source_paths_bad
    RV_IMM t2, 1835364398, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_source_paths_bad
.Lpub_source_path_next:
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lpub_source_path
.Lpub_source_paths_ok:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lpub_source_paths_return
.Lpub_source_paths_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lpub_source_paths_return:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Inspect the small project manifest inside the validated TAR. The accepted
 * subset uses the shared bounded build/dependency/native-link parser.
 * No escapes or duplicate fields are accepted. Reads use a copied NUL.
 * Input: a0=validated target, pub_name/version and successful archive table.
 * Output: t0=0/1. Owns a 16385-byte manifest and four 256-byte values. Frame: 112. */
pub_check_project:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s6, pub_project_target
    mv s8, s6
    RV_STORE a0, 8
    RV_CALL pub_source_paths
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_project_bad
    RV_ADDR s6, pub_readme_names
    mv s0, s6
    RV_CALL pub_any_member
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_project_bad
    RV_ADDR s6, pub_license_names
    mv s0, s6
    RV_CALL pub_any_member
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_project_bad
    RV_ADDR s6, pub_manifest_name
    mv a0, s6
    RV_CALL source_archive_member
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_project_bad
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_project_bad
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_project_bad
    RV_IMM t2, 16384, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lpub_project_bad
    mv a1, t0
    RV_ADDR s6, pub_manifest
    mv a0, s6
    mv a3, a2
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
.Lpub_manifest_copy:
    mv s6, a1
    mv s10, a4
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
    RV_BCOND eq, .Lpub_project_bad
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a4
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    mv s8, a4
    mv s10, a3
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lpub_manifest_copy
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR a1, rm_archive_metadata
    RV_CALL rm_parse_manifest
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_publish984
    RV_JUMP .Lpub_project_bad
.Lrv_cb_skip_publish984:
    RV_ADDR a0, pub_project_name
    RV_ADDR s6, rm_archive_metadata + 24
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, pub_project_version
    RV_ADDR s6, rm_archive_metadata + 32
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, pub_project_source
    RV_ADDR s6, rm_archive_metadata + 40
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, pub_project_arch
    RV_ADDR s6, rm_archive_metadata + 48
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR s6, pub_name
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
.Lpub_unscoped_name:
    mv s6, a1
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 47, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_unscoped_found
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_JUMP .Lpub_unscoped_name
.Lpub_unscoped_found:
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_ADDR s6, pub_project_name
    mv a0, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_project_bad
    RV_ADDR s6, pub_project_version
    mv a0, s6
    RV_ADDR s6, pub_version
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_project_bad
    RV_ADDR s6, pub_project_arch
    mv a0, s6
    RV_ADDR s6, pub_project_target
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_project_bad
    RV_ADDR s6, pub_project_source
    mv a0, s6
    RV_CALL pub_portable_path
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_project_bad
    RV_ADDR s6, pub_project_source
    mv a0, s6
    RV_CALL strlen
    RV_IMM t2, 2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lpub_project_bad
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 2
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 29486, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_project_source_lookup
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 2
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 21294, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_project_source_lookup
    RV_IMM t2, 4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lpub_project_bad
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 4
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1836278062, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_project_bad
.Lpub_project_source_lookup:
    RV_CALL source_archive_member
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_project_bad
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND ne, .Lpub_project_bad
    RV_ADDR s6, rm_archive_metadata + RM_CHECK
    mv s8, s6
    RV_LOAD a0, 8
    mv s8, a0
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_publish1087
    RV_JUMP .Lpub_project_valid
.Lrv_cb_skip_publish1087:
    RV_CALL pub_portable_path
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_publish1089
    RV_JUMP .Lpub_project_bad
.Lrv_cb_skip_publish1089:
    RV_ADDR s6, rm_archive_metadata + RM_CHECK
    mv s8, s6
    RV_LOAD a0, 8
    RV_CALL source_archive_member
    mv s8, t0
    bnez s8, .Lrv_cb_skip_publish1093
    RV_JUMP .Lpub_project_bad
.Lrv_cb_skip_publish1093:
    mv s8, a3
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_publish1094
    RV_JUMP .Lpub_project_bad
.Lrv_cb_skip_publish1094:
.Lpub_project_valid:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lpub_project_return
.Lpub_project_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lpub_project_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* s0 points to a pointer list. Return 1 if any listed regular member exists. */
pub_any_member:
    RV_SAVE s0
.Lpub_any_member_loop:
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_no_member
    RV_CALL source_archive_member
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_member_next
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_member_present
.Lpub_member_next:
    RV_IMM t2, 8, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lpub_any_member_loop
.Lpub_member_present:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    RV_RESTORE s0
    ret
.Lpub_no_member:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_RESTORE s0
    ret
/* Generic ELF64 little-endian container checks for all three registry targets.
 * Metadata segments need no memory image. At least one PT_LOAD is required.
 * This does not execute the binary or prove its instruction requirements.
 * a0=validated target, a1=byte size. t0=0/1. Owns fd and 64/56-byte buffers.
 * Stack frame: 112 bytes. Each program header is read separately, at most1024. */
pub_validate_elf:
    /* A Mach-O target must never be accepted by the Linux ELF validator. */
    RV_SAVE a0
    RV_SAVE a1
    RV_ADDR a1, registry_macos
    RV_CALL streq
    RV_RESTORE a1
    RV_RESTORE a0
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_publish1153
    RV_JUMP .Lpub_linux_executable
.Lrv_cb_skip_publish1153:
    li t0, 1
    RV_ZEXT t0
    ret
.Lpub_linux_executable:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    mv s0, a1
    RV_IMM t1, -1, 64
    mv s2, t1
    RV_IMM t1, 62, 32
    mv s1, t1
    RV_ZEXT s1
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 120, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_elf_open
    RV_IMM t1, 183, 32
    mv s1, t1
    RV_ZEXT s1
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 97, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_elf_open
    RV_IMM t1, 243, 32
    mv s1, t1
    RV_ZEXT s1
.Lpub_elf_open:
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_IMM t1, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_elf_bad
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, pub_elf_header
    mv a1, s6
    RV_IMM t1, 64, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL elf_read_exact
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_elf_bad
    RV_ADDR s6, pub_elf_header
    mv s3, s6
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1179403647, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 258, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 6
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 1, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 2, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lpub_elf_kind
    RV_IMM t2, 3, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
.Lpub_elf_kind:
    mv s6, s3
    li s10, 18
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    li s10, 65535
    and t2, s1, s10
    RV_ZEXT t2
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 52
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 64, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 54
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 56, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_bad
    mv s6, s3
    li s10, 56
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    mv s4, t1
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_elf_bad
    RV_IMM t2, 1024, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lpub_elf_bad
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_IMM t2, 64, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lpub_elf_bad
    mv t0, s4
    RV_IMM t2, 56, 64
    mv s10, t2
    mul t0, t0, s10
    mv s8, t0
    mv s10, a1
    RV_FLAGS add, 64
    mv t0, s11
    RV_BCOND cs, .Lpub_elf_bad
    mv s8, t0
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lpub_elf_bad
    mv a0, s2
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_lseek
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lpub_elf_bad
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
.Lpub_elf_segment:
    mv a0, s2
    RV_ADDR s6, pub_elf_segment
    mv a1, s6
    RV_IMM t1, 56, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL elf_read_exact
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_elf_bad
    RV_ADDR s6, pub_elf_segment
    mv s3, s6
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    RV_BCOND cs, .Lpub_elf_bad
    mv s8, t0
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lpub_elf_bad
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_elf_next
    RV_IMM t1, 1, 32
    mv s5, t1
    RV_ZEXT s5
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lpub_elf_bad
.Lpub_elf_next:
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    mv s4, s11
    RV_BCOND ne, .Lpub_elf_segment
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    RV_BCOND eq, .Lpub_elf_bad
    mv a0, s2
    RV_CALL arc_close
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lpub_elf_return
.Lpub_elf_bad:
    mv a0, s2
    RV_CALL arc_close
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Lpub_elf_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* sha256sum reads the private payload through stdin. An empty environment and
 * fixed argv prevent filename escaping and environment-supplied behavior.
 * Exactly 68 output bytes are accepted: 64 lowercase hex, two spaces, '-', LF.
 * Input: owned registry_temp_payload. t0=0/1. Owns pub_hash_buffer[72], pipe
 * descriptors and child process. Stack frame: 112 bytes; every child is reaped. */
pub_hash_payload:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    RV_IMM t1, -1, 64
    mv s2, t1
    RV_IMM t1, -1, 64
    mv s3, t1
    RV_IMM t1, -1, 64
    mv s4, t1
    RV_IMM t1, -1, 64
    mv s5, t1
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_IMM t1, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    mv a0, t0
    RV_CALL arc_promote_fd
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    mv s2, t0
    RV_ADDR s6, pub_pipe
    mv a0, s6
    RV_IMM t1, 524288, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_pipe2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    RV_ADDR s6, pub_pipe
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL arc_promote_fd
    mv s3, t0
    RV_ADDR s6, pub_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL arc_promote_fd
    mv s4, t0
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    RV_CALL rv_fork
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    RV_BCOND eq, .Lpub_hash_child
    mv s5, t0
    mv a0, s2
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    mv s2, t1
    mv a0, s4
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    mv s4, t1
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Lpub_hash_read:
    mv a0, s3
    RV_ADDR s6, pub_hash_buffer
    mv a1, s6
    mv s8, a1
    mv s10, s0
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t1, 69, 32
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, s0
    RV_FLAGS sub, 64
    mv a2, s11
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lpub_hash_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_kill
    RV_BCOND eq, .Lpub_hash_wait
    mv s8, s0
    mv s10, t0
    RV_FLAGS add, 64
    mv s0, s11
    RV_IMM t2, 68, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lpub_hash_kill
    RV_JUMP .Lpub_hash_read
.Lpub_hash_wait:
    mv a0, s5
    RV_ADDR s6, pub_child_status
    mv a1, s6
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_wait4
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lpub_hash_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_bad
    RV_ADDR s6, pub_child_status
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_hash_bad
    RV_IMM t2, 68, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lpub_hash_bad
    RV_ADDR s6, pub_hash_buffer + 64
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 170729504, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lpub_hash_bad
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_ADDR s6, pub_hash_buffer
    mv a0, s6
.Lpub_hash_hex:
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
    RV_BCOND lo, .Lpub_hash_bad
    RV_IMM t2, 57, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lpub_hash_hex_next
    RV_IMM t2, 97, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lpub_hash_bad
    RV_IMM t2, 102, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lpub_hash_bad
.Lpub_hash_hex_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 64, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lpub_hash_hex
    mv s10, s1
    xor s1, s1, s10
    RV_ZEXT s1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    RV_JUMP .Lpub_hash_close
.Lpub_hash_kill:
    mv a0, s5
    RV_IMM t1, 9, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_kill
.Lpub_hash_reap:
    mv a0, s5
    RV_ADDR s6, pub_child_status
    mv a1, s6
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_wait4
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lpub_hash_reap
.Lpub_hash_bad:
    RV_IMM t1, 1, 32
    mv s1, t1
    RV_ZEXT s1
.Lpub_hash_close:
    mv a0, s2
    RV_CALL arc_close
    mv a0, s3
    RV_CALL arc_close
    mv a0, s4
    RV_CALL arc_close
    mv t0, s1
    RV_ZEXT t0
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
.Lpub_hash_child:
    mv a0, s2
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_CALL rv_dup2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_child_bad
    mv a0, s4
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_dup2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lpub_hash_child_bad
    mv a0, s2
    RV_CALL arc_close
    mv a0, s3
    RV_CALL arc_close
    mv a0, s4
    RV_CALL arc_close
    RV_ADDR s6, registry_sha256sum
    mv a0, s6
    RV_ADDR s6, pub_sha_argv
    mv a1, s6
    RV_ADDR s6, arc_empty_env
    mv a2, s6
    RV_CALL rv_execve
.Lpub_hash_child_bad:
    RV_IMM t1, 126, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_exit
    ebreak
/* Bounded JSON builder. All string input has already passed ASCII validation.
 * It escapes quote/backslash and never writes outside the 16 KiB buffer.
 * Append/quote take a0=NUL text and update pub_json_length. They return void;
 * overflow exits through cleanup. No saved stack frame. Inputs are immutable. */
pub_append:
    RV_ADDR s6, pub_json_length
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_ADDR s6, pub_json
    mv a4, s6
.Lpub_append_character:
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
    RV_BCOND eq, .Lpub_append_done
    RV_IMM t2, 16383, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, pub_bad_metadata
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_JUMP .Lpub_append_character
.Lpub_append_done:
    RV_IMM t1, 0, 32
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, pub_json_length
    mv s8, s6
    RV_STORE a2, 8
    ret
pub_quote:
    mv a5, a0
    RV_ADDR s6, pub_quote_text
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_json_length
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_ADDR s6, pub_json
    mv a4, s6
.Lpub_quote_character:
    mv s6, a5
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
    RV_BCOND eq, .Lpub_quote_end
    RV_IMM t2, 16380, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, pub_bad_metadata
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
    RV_BCOND eq, .Lpub_quote_escape
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
    RV_BCOND ne, .Lpub_quote_copy
.Lpub_quote_escape:
    RV_IMM t1, 92, 32
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
.Lpub_quote_copy:
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_IMM t2, 1, 64
    mv s8, a5
    mv s10, t2
    RV_FLAGS add, 64
    mv a5, s11
    RV_JUMP .Lpub_quote_character
.Lpub_quote_end:
    RV_IMM t1, 34, 32
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_IMM t1, 0, 32
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, pub_json_length
    mv s8, s6
    RV_STORE a2, 8
    ret
/* Input: validated pub_* metadata/artifacts. Output: pub_json and its length.
 * Writes no file. Owns the 16 KiB JSON and 32-byte decimal buffers. Frame: 48. */
pub_make_json:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_IMM t1, 0, 64
    RV_ADDR s6, pub_json_length
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, pub_json_prefix
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_name
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_version
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_version
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_summary
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_summary
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_license
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_license
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_source
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_repository
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_commit
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_commit
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_path
    mv a0, s6
    RV_CALL pub_append
    RV_ADDR s6, pub_source_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_artifacts
    mv a0, s6
    RV_CALL pub_append
    mv s10, s2
    xor s2, s2, s10
    RV_ZEXT s2
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 32
.Lpub_json_artifact:
    RV_ADDR s6, pub_artifact_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lpub_json_done
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lpub_json_artifact_body
    RV_ADDR s6, pub_comma
    mv a0, s6
    RV_CALL pub_append
.Lpub_json_artifact_body:
    mv t0, s2
    slli t0, t0, 7
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, pub_artifacts
    mv s3, s6
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    RV_ADDR s6, pub_json_target
    mv a0, s6
    RV_CALL pub_append
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_kind
    mv a0, s6
    RV_CALL pub_append
    mv s6, s3
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_hash
    mv a0, s6
    RV_CALL pub_append
    mv s6, s3
    li s10, 40
    add s6, s6, s10
    mv a0, s6
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_url
    mv a0, s6
    RV_CALL pub_append
    mv s6, s3
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL pub_quote
    RV_ADDR s6, pub_json_bytes
    mv a0, s6
    RV_CALL pub_append
    mv s6, s3
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, pub_number + 31
    mv a1, s6
    RV_CALL unsigned_decimal
    mv a0, t0
    RV_CALL pub_append
    RV_ADDR s6, pub_rbrace
    mv a0, s6
    RV_CALL pub_append
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lpub_json_artifact
.Lpub_json_done:
    RV_ADDR s6, pub_json_suffix
    mv a0, s6
    RV_CALL pub_append
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
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
pub_stat: .skip RV_STAT_BYTES
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
.section .note.GNU-stack,""
