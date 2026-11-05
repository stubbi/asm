/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/archive.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global extract_source_archive, verify_source_archive
.global validate_source_archive, source_archive_member
/* Source archive boundary. Linux RISC-V64, Asm RISC-V64 callee-saved registers preserved.
 * extract_source_archive(gzip_path, new_directory) returns 0 or 1.
 * verify_source_archive(gzip_path, existing_directory) returns 0 or 1.
 * Callers verify the compressed artifact digest before either operation.
 * Both paths are NUL-terminated. The destination parent must already exist.
 * Calls are serial: bounded buffers belong to this module, not the stack.
 * Public calls preserve s0/s1/s2-s5. Other integer registers and flags are
 * scratch. All nested calls use the same rule unless a parser cursor is noted.
 * All TAR parsing, path checks, file comparison and extraction are assembly.
 * A fixed /usr/bin/gzip process receives an already opened file on stdin and
 * an empty environment. Its output is capped before any filesystem mutation.
 */
.equ ARC_LIMIT, 67108864
.equ ARC_FILE_LIMIT, 16777216
.equ ARC_COUNT, 4096
.equ ARC_PATH, 240
.equ ARC_RDONLY, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
.equ ARC_DIRECTORY, ARC_RDONLY | O_DIRECTORY
.equ ARC_CREATE, O_CLOEXEC | O_NOFOLLOW | 193
/* Native RISC-V64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each RV_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */
.section .text
/* Read-only validation. A successful call leaves a bounded member table for
 * source_archive_member. No file is created. a0 is the gzip path; t0=0/1. */
validate_source_archive:
    RV_SAVE s0
    RV_ADDR s6, arc_input_path
    mv s8, s6
    RV_STORE a0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, arc_file_count
    mv s8, s6
    RV_STORE t1, 8
/* Forward string loops do not use a direction flag. */
    RV_CALL arc_decompress
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_validate_only_done
    RV_CALL arc_validate
.Larc_validate_only_done:
    RV_RESTORE s0
    ret
/* Lookup after successful validation. a0=name. t0=borrowed content pointer,
 * a2=byte count, a3=0 for a file or 1 for a directory. t0=0 means absent.
 * Pointers remain valid until the next archive operation. */
source_archive_member:
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
.Larc_member_lookup:
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_member_absent
    mv t0, a4
    slli t0, t0, 8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_paths
    mv a1, s6
    mv s8, a1
    mv s10, t0
    RV_FLAGS add, 64
    mv a1, s11
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_lookup_compare:
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
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a1
    mv s10, a3
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
    RV_BCOND ne, .Larc_lookup_next
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
    RV_BCOND eq, .Larc_lookup_found
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Larc_lookup_compare
.Larc_lookup_next:
    RV_IMM t2, 1, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    RV_JUMP .Larc_member_lookup
.Larc_lookup_found:
    slli a4, a4, 5
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 64
    RV_ADDR s6, arc_entries
    mv a1, s6
    mv s8, a1
    mv s10, a4
    RV_FLAGS add, 64
    mv a1, s11
    RV_ADDR s6, arc_data
    mv t0, s6
    mv s6, a1
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    mv s6, a1
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s6, a1
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv a3, t1
    RV_ZEXT a3
    ret
.Larc_member_absent:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
extract_source_archive:
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_JUMP arc_operation_start
verify_source_archive:
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
/* Shared terminal operation body. a2 selects extraction (0) or comparison
 * (1). Owns the root/parent descriptors and stage flag. Stack frame: 112 bytes. */
arc_operation_start:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s6, arc_input_path
    mv s8, s6
    RV_STORE a0, 8
    RV_ADDR s6, arc_output_path
    mv s8, s6
    RV_STORE a1, 8
    RV_ADDR s6, arc_operation
    mv s8, s6
    RV_STORE a2, 4
    RV_IMM t1, -1, 64
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, -1, 64
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 32
    RV_ADDR s6, arc_stage_created
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 0, 64
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, arc_file_count
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 1, 32
    RV_ADDR s6, arc_result
    mv s8, s6
    RV_STORE t1, 4
/* Forward string loops do not use a direction flag. */
    RV_ADDR s6, arc_seen
    mv a0, s6
    RV_IMM t1, ARC_COUNT, 32
    mv a3, t1
    RV_ZEXT a3
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive174
    RV_JUMP .Lport_archive_1_end
.Lrv_cb_skip_archive174:
.Lport_archive_1:
    mv s8, a0
    RV_STORE t0, 1
    li s10, 1
    add a0, a0, s10
    li s10, 1
    sub a3, a3, s10
    mv s8, a3
    beqz s8, .Lrv_cb_skip_archive178
    RV_JUMP .Lport_archive_1
.Lrv_cb_skip_archive178:
.Lport_archive_1_end:
    RV_CALL arc_decompress
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_finish
    RV_CALL arc_validate
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_finish
    RV_CALL arc_open_parent
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_finish
    RV_ADDR s6, arc_operation
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_extract
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, arc_destination_leaf
    mv a1, s6
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_finish
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL arc_walk_tree
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_finish
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_ADDR s6, arc_seen
    mv a2, s6
.Larc_check_seen:
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_success
    mv s6, a2
    mv s10, a3
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
    RV_BCOND ne, .Larc_finish
    RV_IMM t2, 1, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 64
    mv a3, s11
    RV_JUMP .Larc_check_seen
.Larc_extract:
    RV_CALL arc_create_stage
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_finish
    mv s10, s2
    xor s2, s2, s10
    RV_ZEXT s2
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 32
.Larc_extract_entry:
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_publish_stage
    mv t0, s2
    slli t0, t0, 8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_paths
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    RV_CALL arc_member_parent
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_finish
    mv s3, t0
    mv s4, a2
    mv t0, s2
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_entries
    mv s5, s6
    mv s8, s5
    mv s10, t0
    RV_FLAGS add, 64
    mv s5, s11
    mv s6, s5
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_extract_file
    mv a0, s3
    mv a1, s4
    RV_IMM t1, 493, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_mkdirat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND pl, .Larc_extract_directory_check
    RV_IMM t2, -17, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_extract_parent_error
.Larc_extract_directory_check:
    mv a0, s3
    mv a1, s4
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_extract_parent_error
    mv a0, t0
    RV_CALL arc_close
    RV_JUMP .Larc_extract_next
.Larc_extract_file:
    mv a0, s3
    mv a1, s4
    RV_IMM t1, ARC_CREATE, 32
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t1, 384, 32
    mv a6, t1
    RV_ZEXT a6
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_extract_parent_error
    mv s1, t0
    RV_ADDR s6, arc_data
    mv a1, s6
    mv s6, s5
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    mv s6, s5
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
.Larc_write:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_file_mode
    mv a0, s1
    RV_CALL rv_write
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_write
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND le, .Larc_extract_file_error
    mv s8, a1
    mv s10, t0
    RV_FLAGS add, 64
    mv a1, s11
    mv s8, a2
    mv s10, t0
    RV_FLAGS sub, 64
    mv a2, s11
    RV_JUMP .Larc_write
.Larc_file_mode:
    mv a0, s1
    mv s6, s5
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_fchmod
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_extract_file_error
    mv a0, s1
    RV_CALL arc_close
.Larc_extract_next:
    mv a0, s3
    RV_CALL arc_close
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Larc_extract_entry
.Larc_extract_file_error:
    mv a0, s1
    RV_CALL arc_close
.Larc_extract_parent_error:
    mv a0, s3
    RV_CALL arc_close
    RV_JUMP .Larc_finish
.Larc_publish_stage:
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, 493, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_fchmod
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_finish
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, arc_stage_name
    mv a1, s6
    mv a2, a0
    RV_ADDR s6, arc_destination_leaf
    mv a6, s6
    RV_IMM t1, 1, 32
    mv a4, t1
    RV_ZEXT a4
    RV_CALL rv_renameat2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_finish
    RV_IMM t1, 0, 32
    RV_ADDR s6, arc_stage_created
    mv s8, s6
    RV_STORE t1, 1
.Larc_success:
    RV_IMM t1, 0, 32
    RV_ADDR s6, arc_result
    mv s8, s6
    RV_STORE t1, 4
.Larc_finish:
    RV_ADDR s6, arc_stage_created
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
    RV_BCOND eq, .Larc_close_root
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_remove_stage
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL arc_walk_tree
.Larc_remove_stage:
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, arc_stage_name
    mv a1, s6
    RV_IMM t1, 512, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_unlinkat
.Larc_close_root:
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_ADDR s6, arc_result
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
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
/* Close an owned descriptor. Negative descriptors are an empty slot. */
arc_close:
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_close_done
    RV_CALL rv_close
.Larc_close_done:
    ret
/* Ensure our descriptors cannot alias stdin/stdout/stderr in the child. */
arc_promote_fd:
    RV_IMM t2, 3, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_promote_same
    RV_SAVE s0
    mv s0, a0
    RV_IMM t1, 1030, 32
    mv a1, t1
    RV_ZEXT a1
    RV_IMM t1, 3, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_fcntl
    RV_SAVE t0
    mv a0, s0
    RV_CALL arc_close
    RV_RESTORE t0
    RV_RESTORE s0
    ret
.Larc_promote_same:
    mv t0, a0
    ret
/* Input: arc_input_path. Output: t0=0/1, arc_data[0..arc_raw_size) on success.
 * Capacity: 64 MiB + one overflow byte. Owns source/pipe descriptors and child.
 * Retries EINTR, reaps the child, and caps output before validation. Frame: 112. */
arc_decompress:
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
    RV_IMM t1, 0, 64
    RV_ADDR s6, arc_raw_size
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, -100, 64
    mv a0, t1
    RV_ADDR s6, arc_input_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_IMM t1, ARC_RDONLY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    mv a0, t0
    RV_CALL arc_promote_fd
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, arc_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    RV_ADDR s6, arc_stat + RV_STAT_MODE
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
    RV_BCOND ne, .Larc_decompress_fail
    RV_ADDR s6, arc_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND le, .Larc_decompress_fail
    RV_IMM t2, ARC_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_decompress_fail
    RV_ADDR s6, arc_pipe
    mv a0, s6
    RV_IMM t1, 524288, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_pipe2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    RV_ADDR s6, arc_pipe
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL arc_promote_fd
    mv s3, t0
    RV_ADDR s6, arc_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL arc_promote_fd
    mv s4, t0
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    RV_CALL rv_fork
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    RV_BCOND eq, .Larc_gzip_child
    mv s5, t0
    mv a0, s4
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    mv s4, t1
    mv a0, s2
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    mv s2, t1
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Larc_gzip_read:
    mv a0, s3
    RV_ADDR s6, arc_data
    mv a1, s6
    mv s8, a1
    mv s10, s0
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t1, ARC_LIMIT + 1, 32
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, s0
    RV_FLAGS sub, 64
    mv a2, s11
    RV_IMM t2, 65536, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ls, .Larc_gzip_read_size
    RV_IMM t1, 65536, 32
    mv a2, t1
    RV_ZEXT a2
.Larc_gzip_read_size:
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_gzip_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_kill
    RV_BCOND eq, .Larc_gzip_eof
    mv s8, s0
    mv s10, t0
    RV_FLAGS add, 64
    mv s0, s11
    RV_IMM t2, ARC_LIMIT, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_decompress_kill
    RV_JUMP .Larc_gzip_read
.Larc_gzip_eof:
    RV_ADDR s6, arc_raw_size
    mv s8, s6
    RV_STORE s0, 8
    mv a0, s3
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    mv s3, t1
.Larc_gzip_wait:
    mv a0, s5
    RV_ADDR s6, arc_child_status
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
    RV_BCOND eq, .Larc_gzip_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_decompress_fail
    RV_IMM t1, -1, 64
    mv s5, t1
    RV_ADDR s6, arc_child_status
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_decompress_fail
    mv s10, s1
    xor s1, s1, s10
    RV_ZEXT s1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    RV_JUMP .Larc_decompress_close
.Larc_decompress_kill:
    mv a0, s5
    RV_IMM t1, 9, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_kill
.Larc_decompress_reap:
    mv a0, s5
    RV_ADDR s6, arc_child_status
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
    RV_BCOND eq, .Larc_decompress_reap
    RV_IMM t1, -1, 64
    mv s5, t1
.Larc_decompress_fail:
    RV_IMM t1, 1, 32
    mv s1, t1
    RV_ZEXT s1
.Larc_decompress_close:
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
.Larc_gzip_child:
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
    RV_BCOND mi, .Larc_gzip_child_fail
    mv a0, s4
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_dup2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_gzip_child_fail
    mv a0, s2
    RV_CALL arc_close
    mv a0, s3
    RV_CALL arc_close
    mv a0, s4
    RV_CALL arc_close
    RV_ADDR s6, arc_gzip
    mv a0, s6
    RV_ADDR s6, arc_gzip_argv
    mv a1, s6
    RV_ADDR s6, arc_empty_env
    mv a2, s6
    RV_CALL rv_execve
.Larc_gzip_child_fail:
    RV_IMM t1, 126, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_exit
    ebreak
/* Return 1 for an all-zero region, including the empty region. */
arc_is_zero:
    mv a3, a1
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive687
    RV_JUMP .Lport_archive_2_end
.Lrv_cb_skip_archive687:
.Lport_archive_2:
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s8, a0
    RV_LOAD t2, 1
    li s10, 1
    add a0, a0, s10
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    li s10, 1
    sub a3, a3, s10
    RV_BCOND ne, .Lport_archive_2_end
    mv s8, a3
    beqz s8, .Lrv_cb_skip_archive696
    RV_JUMP .Lport_archive_2
.Lrv_cb_skip_archive696:
.Lport_archive_2_end:
    RV_BCOND eq, .Lrv_cset_true_archive698
    li t1, 0
    j .Lrv_cset_done_archive698
.Lrv_cset_true_archive698:
    li t1, 1
.Lrv_cset_done_archive698:
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    ret
/* Input: a0=bounded field, a3=field size. Output: t0=unsigned octal value.
 * Carry is clear on success and set on failure. Other s9 conditions flags are scratch.
 * Leading spaces and NUL/space suffixes are permitted. No saved frame. */
arc_octal:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
.Larc_octal_leading:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_octal_bad
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
    RV_BCOND ne, .Larc_octal_digits
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    mv a3, s11
    RV_JUMP .Larc_octal_leading
.Larc_octal_digits:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_octal_end
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_octal_suffix
    RV_IMM t2, 55, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Larc_octal_bad
    mv a5, t0
    srli a5, a5, 61
    mv s8, a5
    mv s10, a5
    RV_FLAGS and, 64
    RV_BCOND ne, .Larc_octal_bad
    slli t0, t0, 3
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv a2, s11
    mv s10, a2
    or t0, t0, s10
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 32
    mv a4, s11
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    mv a3, s11
    RV_JUMP .Larc_octal_digits
.Larc_octal_suffix:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_octal_suffix_next
    RV_IMM t2, 32, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_octal_bad
.Larc_octal_suffix_next:
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    mv a3, s11
    RV_BCOND eq, .Larc_octal_end
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    RV_JUMP .Larc_octal_suffix
.Larc_octal_end:
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_octal_bad
    mv s8, zero
    mv s10, zero
    RV_FLAGS add, 64
    mv zero, s11
    ret
.Larc_octal_bad:
    mv s8, zero
    mv s10, zero
    RV_FLAGS sub, 64
    ret
/* Input: a0=bounded TAR field, a3=field size. Output: t0=text length.
 * Carry is clear on success and set on failure. Other s9 conditions flags are scratch.
 * The field ends at its first NUL. Remaining bytes must be zero. No frame. */
arc_field_length:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Larc_field_scan:
    mv s8, t0
    mv s10, a3
    RV_FLAGS sub, 32
    RV_BCOND hs, .Larc_field_ok
    mv s6, a0
    mv s10, t0
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
    RV_BCOND eq, .Larc_field_tail
    RV_IMM t2, 1, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 32
    mv t0, s11
    RV_JUMP .Larc_field_scan
.Larc_field_tail:
    mv a2, t0
    RV_ZEXT a2
.Larc_field_tail_loop:
    mv s8, a2
    mv s10, a3
    RV_FLAGS sub, 32
    RV_BCOND hs, .Larc_field_ok
    mv s6, a0
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
    RV_BCOND ne, .Larc_field_bad
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    RV_JUMP .Larc_field_tail_loop
.Larc_field_ok:
    mv s8, zero
    mv s10, zero
    RV_FLAGS add, 64
    mv zero, s11
    ret
.Larc_field_bad:
    mv s8, zero
    mv s10, zero
    RV_FLAGS sub, 64
    ret
/* Portable member paths. Dot segments, empty segments, trailing dots, option
 * prefixes, controls and shell/path punctuation cannot reach openat. */
arc_path_valid:
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_path_bad
    RV_IMM t2, ARC_PATH, 32
    mv s8, a1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Larc_path_bad
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
.Larc_path_loop:
    mv s8, a3
    mv s10, a1
    RV_FLAGS sub, 32
    RV_BCOND hs, .Larc_path_last
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 47, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_path_separator
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_path_character
    RV_IMM t2, 45, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_path_bad
.Larc_path_character:
    RV_IMM t2, 65, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_path_digit
    RV_IMM t2, 90, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Larc_path_advance
    RV_IMM t2, 97, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_path_symbol
    RV_IMM t2, 122, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Larc_path_advance
    RV_JUMP .Larc_path_bad
.Larc_path_digit:
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_path_symbol
    RV_IMM t2, 57, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Larc_path_advance
.Larc_path_symbol:
    RV_IMM t2, 95, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_path_advance
    RV_IMM t2, 46, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_path_advance
    RV_IMM t2, 45, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_path_bad
.Larc_path_advance:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 32
    mv a4, s11
    RV_JUMP .Larc_path_loop
.Larc_path_separator:
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_path_bad
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    li s10, 1
    sub s6, s6, s10
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
    RV_BCOND eq, .Larc_path_bad
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Larc_path_loop
.Larc_path_last:
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_path_bad
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    li s10, 1
    sub s6, s6, s10
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
    RV_BCOND eq, .Larc_path_bad
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
.Larc_path_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
/* Compare a new path to previous paths, folding ASCII case. Reject duplicates
 * and either ordering of a regular file used as an ancestor directory. */
arc_check_conflicts:
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
.Larc_conflict_entry:
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_conflict_ok
    mv t0, a4
    slli t0, t0, 8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_paths
    mv a5, s6
    mv s8, a5
    mv s10, t0
    RV_FLAGS add, 64
    mv a5, s11
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_conflict_char:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s6, a5
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_conflict_new_end
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_conflict_old_end
    RV_IMM t2, 65, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_conflict_fold_old
    RV_IMM t2, 90, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Larc_conflict_fold_old
    RV_IMM t2, 32, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 32
    mv t0, s11
.Larc_conflict_fold_old:
    RV_IMM t2, 65, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_conflict_compare
    RV_IMM t2, 90, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Larc_conflict_compare
    RV_IMM t2, 32, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
.Larc_conflict_compare:
    mv s8, t0
    mv s10, a2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_conflict_next
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Larc_conflict_char
.Larc_conflict_new_end:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_conflict_bad
    RV_IMM t2, 47, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_conflict_next
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_conflict_bad
    RV_JUMP .Larc_conflict_next
.Larc_conflict_old_end:
    RV_IMM t2, 47, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_conflict_next
    mv t0, a4
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_entries
    mv a2, s6
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_conflict_bad
.Larc_conflict_next:
    RV_IMM t2, 1, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    RV_JUMP .Larc_conflict_entry
.Larc_conflict_ok:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
.Larc_conflict_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
/* Input: bounded arc_data/raw_size. Output: t0=0/1, paths and member table.
 * Table bounds: 4096 records, 256 bytes/path, 32 bytes/record. No file writes.
 * Scratch stack: 128 bytes including callee-saved registers. */
arc_validate:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 32
    sub sp, sp, s10
    RV_ADDR s6, arc_data
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
    RV_ADDR s6, arc_raw_size
    mv s8, s6
    RV_LOAD t1, 8
    mv s4, t1
    RV_IMM t2, 511, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS and, 64
    RV_BCOND ne, .Larc_validate_bad
.Larc_header:
    mv s6, s3
    li s10, 512
    add s6, s6, s10
    mv t0, s6
    mv s8, t0
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_validate_bad
    mv s6, s2
    mv s10, s3
    add s6, s6, s10
    mv s0, s6
    mv a0, s0
    RV_IMM t1, 512, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL arc_is_zero
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_tar_end
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, ARC_COUNT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_validate_bad
    mv s6, s0
    li s10, 257
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1635021685, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_validate_bad
    mv s6, s0
    li s10, 261
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 114, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_validate_bad
    mv s6, s0
    li s10, 263
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 12336, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_validate_bad
    mv s10, s1
    xor s1, s1, s10
    RV_ZEXT s1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_checksum:
    mv s6, s0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 148, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_checksum_add
    RV_IMM t2, 156, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Larc_checksum_add
    RV_IMM t1, 32, 32
    mv t0, t1
    RV_ZEXT t0
.Larc_checksum_add:
    mv s8, s1
    mv s10, t0
    RV_FLAGS add, 32
    mv s1, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 512, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_checksum
    mv s6, s0
    li s10, 148
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_octal
    RV_BCOND cs, .Larc_validate_bad
    mv s8, t0
    mv s10, s1
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_validate_bad
    mv s6, s0
    li s10, 156
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s10, s1
    xor s1, s1, s10
    RV_ZEXT s1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_header_type
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_header_type
    RV_IMM t2, 53, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_validate_bad
    RV_IMM t1, 1, 32
    mv s1, t1
    RV_ZEXT s1
.Larc_header_type:
    mv s6, sp
    mv s8, s6
    RV_STORE s1, 4
    mv s6, s0
    li s10, 157
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 100, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL arc_is_zero
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_validate_bad
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    slli t0, t0, 8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_paths
    mv s5, s6
    mv s8, s5
    mv s10, t0
    RV_FLAGS add, 64
    mv s5, s11
    mv s6, s0
    li s10, 345
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 155, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_field_length
    RV_BCOND cs, .Larc_validate_bad
    mv s1, t0
    mv s6, s0
    li s10, 345
    add s6, s6, s10
    mv a1, s6
    mv a0, s5
    mv a3, s1
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive1159
    RV_JUMP .Lport_archive_3_end
.Lrv_cb_skip_archive1159:
.Lport_archive_3:
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
    beqz s8, .Lrv_cb_skip_archive1164
    RV_JUMP .Lport_archive_3
.Lrv_cb_skip_archive1164:
.Lport_archive_3_end:
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_path_name
    RV_IMM t1, 47, 32
    mv s6, s5
    mv s10, s1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s1
    mv s10, t2
    RV_FLAGS add, 64
    mv s1, s11
.Larc_path_name:
    mv a0, s0
    RV_IMM t1, 100, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_field_length
    RV_BCOND cs, .Larc_validate_bad
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_validate_bad
    mv s6, s1
    mv s10, t0
    add s6, s6, s10
    mv a2, s6
    RV_IMM t2, ARC_PATH, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_validate_bad
    mv a1, s0
    mv s6, s5
    mv s10, s1
    add s6, s6, s10
    mv a0, s6
    mv a3, t0
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive1193
    RV_JUMP .Lport_archive_4_end
.Lrv_cb_skip_archive1193:
.Lport_archive_4:
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
    beqz s8, .Lrv_cb_skip_archive1198
    RV_JUMP .Lport_archive_4
.Lrv_cb_skip_archive1198:
.Lport_archive_4_end:
    mv s1, a2
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_path_terminate
.Larc_trim_directory:
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_validate_bad
    mv s6, s5
    mv s10, s1
    add s6, s6, s10
    li s10, 1
    sub s6, s6, s10
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
    RV_BCOND ne, .Larc_path_terminate
    RV_IMM t2, 1, 64
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 64
    mv s1, s11
    RV_JUMP .Larc_trim_directory
.Larc_path_terminate:
    RV_IMM t1, 0, 32
    mv s6, s5
    mv s10, s1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv a0, s5
    mv a1, s1
    RV_CALL arc_path_valid
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_validate_bad
    mv a0, s5
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 4
    mv a1, t1
    RV_ZEXT a1
    RV_CALL arc_check_conflicts
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_validate_bad
    mv s6, s0
    li s10, 100
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_octal
    RV_BCOND cs, .Larc_validate_bad
    RV_IMM t2, 420, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_mode_ok
    RV_IMM t2, 493, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_validate_bad
.Larc_mode_ok:
    mv s6, sp
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 4
    mv s6, s0
    li s10, 108
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_octal
    RV_BCOND cs, .Larc_validate_bad
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Larc_validate_bad
    mv s6, s0
    li s10, 116
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 8, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_octal
    RV_BCOND cs, .Larc_validate_bad
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Larc_validate_bad
    mv s6, s0
    li s10, 124
    add s6, s6, s10
    mv a0, s6
    RV_IMM t1, 12, 32
    mv a3, t1
    RV_ZEXT a3
    RV_CALL arc_octal
    RV_BCOND cs, .Larc_validate_bad
    RV_IMM t2, ARC_FILE_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_validate_bad
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_size_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Larc_validate_bad
    RV_JUMP .Larc_size_ok
.Larc_size_file:
    RV_ADDR s6, arc_file_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, arc_file_count
    mv s8, s6
    RV_STORE t3, 8
.Larc_size_ok:
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s6, t0
    li s10, 511
    add s6, s6, s10
    mv s1, s6
    RV_IMM t2, -512, 64
    mv s10, t2
    and s1, s1, s10
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 64
    mv s6, s3
    li s10, 512
    add s6, s6, s10
    mv s5, s6
    mv s8, s1
    mv s10, s5
    RV_FLAGS add, 64
    mv s1, s11
    mv s8, s1
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_validate_bad
    mv s6, s2
    mv s10, s5
    add s6, s6, s10
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    mv a1, s1
    mv s8, a1
    mv s10, s5
    RV_FLAGS sub, 64
    mv a1, s11
    mv s8, a1
    mv s10, t0
    RV_FLAGS sub, 64
    mv a1, s11
    RV_CALL arc_is_zero
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_validate_bad
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_entries
    mv a2, s6
    mv s8, a2
    mv s10, t0
    RV_FLAGS add, 64
    mv a2, s11
    mv s6, a2
    mv s8, s6
    RV_STORE s5, 8
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, a2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s6, sp
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv s6, a2
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 4
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv s6, a2
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 4
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_STORE t3, 8
    mv s3, s1
    RV_JUMP .Larc_header
.Larc_tar_end:
    mv a1, s4
    mv s8, a1
    mv s10, s3
    RV_FLAGS sub, 64
    mv a1, s11
    RV_IMM t2, 1024, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Larc_validate_bad
    mv a0, s0
    RV_CALL arc_is_zero
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_validate_bad
    RV_ADDR s6, arc_file_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_validate_bad
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Larc_validate_return
.Larc_validate_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Larc_validate_return:
    li s10, 32
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Walk the user-supplied parent with O_NOFOLLOW on each component. No parent
 * is created. Dot is allowed as a parent; dot-dot is never followed. */
arc_open_parent:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    li s10, 16
    sub sp, sp, s10
    RV_ADDR s6, arc_output_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, arc_output_copy
    mv a0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_copy_output:
    RV_IMM t2, 4095, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Larc_parent_bad
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
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
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
    RV_BCOND eq, .Larc_output_copied
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Larc_copy_output
.Larc_output_copied:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_parent_bad
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    li s10, 1
    sub s6, s6, s10
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
    RV_BCOND eq, .Larc_parent_bad
    RV_ADDR s6, arc_output_copy
    mv s0, s6
    RV_ADDR s6, arc_dot
    mv a1, s6
    mv s6, s0
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
    RV_BCOND ne, .Larc_parent_open_start
    RV_ADDR s6, arc_slash
    mv a1, s6
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
.Larc_parent_open_start:
    RV_IMM t1, -100, 64
    mv a0, t1
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_parent_bad
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_STORE t0, 8
.Larc_parent_component:
    mv s2, s0
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Larc_parent_find_end:
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_parent_leaf
    RV_IMM t2, 47, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_parent_descend
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_IMM t2, 255, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_parent_bad
    RV_JUMP .Larc_parent_find_end
.Larc_parent_descend:
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_parent_bad
    RV_IMM t1, 0, 32
    mv s6, s0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 11822, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_parent_not_dotdot
    mv s6, s2
    li s10, 2
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
    RV_BCOND eq, .Larc_parent_bad
.Larc_parent_not_dotdot:
    mv s6, s2
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
    RV_BCOND eq, .Larc_parent_component
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv a1, s2
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_parent_bad
    mv s4, t0
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_STORE s4, 8
    RV_JUMP .Larc_parent_component
.Larc_parent_leaf:
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_parent_bad
    mv s6, s2
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
    RV_BCOND eq, .Larc_parent_bad
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 11822, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_parent_save_leaf
    mv s6, s2
    li s10, 2
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
    RV_BCOND eq, .Larc_parent_bad
.Larc_parent_save_leaf:
    RV_ADDR s6, arc_destination_leaf
    mv a0, s6
    mv a1, s2
    mv s6, s3
    li s10, 1
    add s6, s6, s10
    mv a3, s6
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive1572
    RV_JUMP .Lport_archive_5_end
.Lrv_cb_skip_archive1572:
.Lport_archive_5:
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
    beqz s8, .Lrv_cb_skip_archive1577
    RV_JUMP .Lport_archive_5
.Lrv_cb_skip_archive1577:
.Lport_archive_5_end:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Larc_parent_return
.Larc_parent_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Larc_parent_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Input: owned arc_parent_fd. Output: t0=0/1, root fd and stage ownership flag.
 * Creates mode-0700 random sibling with mkdirat, then opens without following
 * a link. Stage-name capacity is 45 bytes; random input is 16 bytes. Frame: 16. */
arc_create_stage:
    RV_SAVE s0
    RV_ADDR s6, arc_random
    mv a0, s6
    RV_IMM t1, 16, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_getrandom
    RV_IMM t2, 16, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_stage_bad
    RV_ADDR s6, arc_random
    mv a1, s6
    RV_ADDR s6, arc_stage_name + 11
    mv a0, s6
    RV_ADDR s6, arc_hex
    mv a4, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_stage_hex:
    mv s6, a1
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv a2, t0
    RV_ZEXT a2
    srliw t0, t0, 4
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 15, 32
    mv s10, t2
    and a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    mv s6, a4
    mv s10, t0
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
    mv s6, a4
    mv s10, a2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and a2, a2, s10
    or a2, a2, s11
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    slli s10, s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    li s10, 255
    and t1, a2, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    slli s10, s10, 1
    add s6, s6, s10
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 16, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_stage_hex
    RV_IMM t1, 0, 32
    mv s6, a0
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, arc_stage_name
    mv a1, s6
    RV_IMM t1, 448, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_mkdirat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_stage_bad
    RV_IMM t1, 1, 32
    RV_ADDR s6, arc_stage_created
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, arc_parent_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, arc_stage_name
    mv a1, s6
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_stage_bad
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_STORE t0, 8
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_RESTORE s0
    ret
.Larc_stage_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    RV_RESTORE s0
    ret
/* Open/create implied parent directories below the private staging descriptor.
 * Return an owned parent fd in t0 and final component pointer in a2. */
arc_member_parent:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    li s10, 16
    sub sp, sp, s10
    mv a1, a0
    RV_ADDR s6, arc_member_copy
    mv a0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_member_copy:
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
    RV_BCOND ne, .Larc_member_copy
    RV_ADDR s6, arc_root_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, 1030, 32
    mv a1, t1
    RV_ZEXT a1
    RV_IMM t1, 3, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_fcntl
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_member_return
    mv s2, t0
    RV_ADDR s6, arc_member_copy
    mv s0, s6
.Larc_member_component:
    mv s1, s0
.Larc_member_find:
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_member_done
    RV_IMM t2, 47, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_member_descend
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Larc_member_find
.Larc_member_descend:
    RV_IMM t1, 0, 32
    mv s6, s0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    mv a0, s2
    mv a1, s1
    RV_IMM t1, 493, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_mkdirat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND pl, .Larc_member_open
    RV_IMM t2, -17, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_member_fail
.Larc_member_open:
    mv a0, s2
    mv a1, s1
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_member_fail
    mv s3, t0
    mv a0, s2
    RV_CALL arc_close
    mv s2, s3
    RV_JUMP .Larc_member_component
.Larc_member_done:
    mv t0, s2
    mv a2, s1
    RV_JUMP .Larc_member_return
.Larc_member_fail:
    mv a0, s2
    RV_CALL arc_close
    RV_IMM t1, -1, 64
    mv t0, t1
.Larc_member_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Match arc_scan_path to a record of requested type (a1). A directory may
 * also be an implicit parent. Return its index, -1 for implicit, -2 for error. */
arc_find_entry:
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    mv s10, a5
    xor a5, a5, s10
    RV_ZEXT a5
    mv s8, a5
    mv s10, a5
    RV_FLAGS and, 32
    RV_ADDR s6, arc_scan_path
    mv a0, s6
.Larc_find_loop:
    RV_ADDR s6, arc_entry_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_find_end
    mv t0, a4
    slli t0, t0, 8
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_paths
    mv a2, s6
    mv s8, a2
    mv s10, t0
    RV_FLAGS add, 64
    mv a2, s11
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_find_compare:
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
    RV_BCOND eq, .Larc_find_path_end
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a2
    mv s10, a3
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
    RV_BCOND ne, .Larc_find_next
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Larc_find_compare
.Larc_find_path_end:
    mv s6, a2
    mv s10, a3
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
    RV_BCOND eq, .Larc_find_exact
    mv s6, a2
    mv s10, a3
    add s6, s6, s10
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
    RV_BCOND ne, .Larc_find_next
    RV_IMM t1, 1, 32
    mv a5, t1
    RV_ZEXT a5
.Larc_find_next:
    RV_IMM t2, 1, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    RV_JUMP .Larc_find_loop
.Larc_find_exact:
    mv t0, a4
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_entries
    mv a2, s6
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    li s10, 20
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv s8, t1
    mv s10, a1
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_find_bad
    mv t0, a4
    ret
.Larc_find_end:
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_find_bad
    mv s8, a5
    mv s10, a5
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_find_bad
    RV_IMM t1, -1, 64
    mv t0, t1
    ret
.Larc_find_bad:
    RV_IMM t1, -2, 64
    mv t0, t1
    ret
/* Verify one actual regular file against an expected record. a0 is its
 * parent, a1 its leaf, a4 its record index. No symlink or FIFO is followed. */
arc_compare_file:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    mv s2, a4
    RV_IMM t1, ARC_RDONLY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_compare_bad_no_fd
    mv s3, t0
    mv a0, s3
    RV_ADDR s6, arc_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_compare_bad
    RV_ADDR s6, arc_stat + RV_STAT_MODE
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
    RV_BCOND ne, .Larc_compare_bad
    RV_ADDR s6, arc_stat + RV_STAT_LINKS
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_compare_bad
    mv t0, s2
    slli t0, t0, 5
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, arc_entries
    mv s0, s6
    mv s8, s0
    mv s10, t0
    RV_FLAGS add, 64
    mv s0, s11
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv s4, t1
    RV_ADDR s6, arc_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Larc_compare_bad
    RV_ADDR s6, arc_data
    mv s5, s6
    mv s6, s0
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s5
    mv s10, t2
    RV_FLAGS add, 64
    mv s5, s11
.Larc_compare_read:
    mv a0, s3
    RV_ADDR s6, arc_compare_buffer
    mv a1, s6
    mv a2, s4
    RV_IMM t2, 65536, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ls, .Larc_compare_read_size
    RV_IMM t1, 65536, 32
    mv a2, t1
    RV_ZEXT a2
.Larc_compare_read_size:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, .Larc_compare_eof
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_compare_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND le, .Larc_compare_bad
    mv s1, t0
    mv a3, t0
    RV_ADDR s6, arc_compare_buffer
    mv a1, s6
    mv a0, s5
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive1972
    RV_JUMP .Lport_archive_6_end
.Lrv_cb_skip_archive1972:
.Lport_archive_6:
    mv s8, a1
    RV_LOAD t1, 1
    li s10, 1
    add a1, a1, s10
    mv s8, a0
    RV_LOAD t2, 1
    li s10, 1
    add a0, a0, s10
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    li s10, 1
    sub a3, a3, s10
    RV_BCOND ne, .Lport_archive_6_end
    mv s8, a3
    beqz s8, .Lrv_cb_skip_archive1981
    RV_JUMP .Lport_archive_6
.Lrv_cb_skip_archive1981:
.Lport_archive_6_end:
    RV_BCOND ne, .Larc_compare_bad
    mv s8, s5
    mv s10, s1
    RV_FLAGS add, 64
    mv s5, s11
    mv s8, s4
    mv s10, s1
    RV_FLAGS sub, 64
    mv s4, s11
    RV_JUMP .Larc_compare_read
.Larc_compare_eof:
    mv a0, s3
    RV_ADDR s6, arc_compare_buffer
    mv a1, s6
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_compare_eof
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Larc_compare_bad
    RV_ADDR s6, arc_seen
    mv a2, s6
    RV_IMM t1, 1, 32
    mv s6, a2
    mv s10, s2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv a0, s3
    RV_CALL arc_close
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Larc_compare_return
.Larc_compare_bad:
    mv a0, s3
    RV_CALL arc_close
.Larc_compare_bad_no_fd:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Larc_compare_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Walk one directory without following links. Mode 0 compares the exact tree;
 * mode 1 removes a failed private stage. Each recursion owns its getdents buffer.
 * a0 fd, a1 prefix length in arc_scan_path, a2 mode. */
arc_walk_tree:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_IMM s7, 4128, 64
    mv s10, s7
    sub sp, sp, s10
    mv s2, a0
    mv s3, a1
    mv s6, sp
    RV_IMM s7, 4104, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE a2, 4
.Larc_walk_read:
    mv a0, s2
    mv t1, sp
    mv a1, t1
    RV_IMM t1, 4096, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_getdents64
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_walk_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_walk_bad
    RV_BCOND eq, .Larc_walk_ok
    mv s4, t0
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
.Larc_walk_entry:
    mv s8, s5
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hs, .Larc_walk_read
    mv s6, sp
    mv s10, s5
    add s6, s6, s10
    mv s0, s6
    mv s6, s5
    li s10, 20
    add s6, s6, s10
    mv t0, s6
    mv s8, t0
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_walk_bad
    mv s6, s0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 2
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 20, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Larc_walk_bad
    mv s6, s5
    mv s10, t0
    add s6, s6, s10
    mv a2, s6
    mv s8, a2
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_walk_bad
    mv s6, sp
    RV_IMM s7, 4096, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 4
    mv s6, s0
    li s10, 19
    add s6, s6, s10
    mv s0, s6
    RV_IMM t2, 19, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Larc_walk_name:
    mv s8, a3
    mv s10, t0
    RV_FLAGS sub, 32
    RV_BCOND hs, .Larc_walk_bad
    mv s6, s0
    mv s10, a3
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
    RV_BCOND eq, .Larc_walk_name_end
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Larc_walk_name
.Larc_walk_name_end:
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    RV_BCOND eq, .Larc_walk_bad
    mv s6, s0
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
    RV_BCOND eq, .Larc_walk_next
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 2
    RV_IMM t2, 11822, 32
    slliw t1, t1, 16
    RV_ZEXT t1
    slliw t2, t2, 16
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_walk_real_entry
    mv s6, s0
    li s10, 2
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
    RV_BCOND eq, .Larc_walk_next
.Larc_walk_real_entry:
    mv s6, s3
    mv s10, a3
    add s6, s6, s10
    mv s1, s6
    RV_IMM t2, ARC_PATH, 64
    mv s8, s1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Larc_walk_bad
    RV_ADDR s6, arc_scan_path
    mv a0, s6
    mv s8, a0
    mv s10, s3
    RV_FLAGS add, 64
    mv a0, s11
    mv a1, s0
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    mv s8, a3
    bnez s8, .Lrv_cb_skip_archive2146
    RV_JUMP .Lport_archive_7_end
.Lrv_cb_skip_archive2146:
.Lport_archive_7:
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
    beqz s8, .Lrv_cb_skip_archive2151
    RV_JUMP .Lport_archive_7
.Lrv_cb_skip_archive2151:
.Lport_archive_7_end:
    mv a0, s2
    mv a1, s0
    RV_IMM t1, ARC_DIRECTORY, 32
    mv a2, t1
    RV_ZEXT a2
    mv s10, a6
    xor a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    mv s10, a6
    RV_FLAGS and, 32
    RV_CALL rv_openat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_walk_file
    mv s6, sp
    RV_IMM s7, 4112, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s6, sp
    RV_IMM s7, 4104, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Larc_walk_directory_recurse
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL arc_find_entry
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Larc_walk_directory_bad
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_walk_directory_recurse
    RV_ADDR s6, arc_seen
    mv a2, s6
    RV_IMM t1, 1, 32
    mv s6, a2
    mv s10, t0
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
.Larc_walk_directory_recurse:
    RV_ADDR s6, arc_scan_path
    mv a2, s6
    RV_IMM t1, 47, 32
    mv s6, a2
    mv s10, s1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 0, 32
    mv s6, a2
    mv s10, s1
    add s6, s6, s10
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s6, sp
    RV_IMM s7, 4112, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s1
    li s10, 1
    add s6, s6, s10
    mv a1, s6
    mv s6, sp
    RV_IMM s7, 4104, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv a2, t1
    RV_ZEXT a2
    RV_CALL arc_walk_tree
    mv s1, t0
    RV_ZEXT s1
    mv s6, sp
    RV_IMM s7, 4112, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_walk_bad
    mv s6, sp
    RV_IMM s7, 4104, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_walk_next
    mv a0, s2
    mv a1, s0
    RV_IMM t1, 512, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_unlinkat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_walk_bad
    RV_JUMP .Larc_walk_next
.Larc_walk_directory_bad:
    mv s6, sp
    RV_IMM s7, 4112, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL arc_close
    RV_JUMP .Larc_walk_bad
.Larc_walk_file:
    mv s6, sp
    RV_IMM s7, 4104, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 0, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Larc_walk_compare_file
    mv a0, s2
    mv a1, s0
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_unlinkat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_walk_bad
    RV_JUMP .Larc_walk_next
.Larc_walk_compare_file:
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_CALL arc_find_entry
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Larc_walk_bad
    mv a4, t0
    mv a0, s2
    mv a1, s0
    RV_CALL arc_compare_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Larc_walk_bad
.Larc_walk_next:
    RV_ADDR s6, arc_scan_path
    mv a2, s6
    RV_IMM t1, 0, 32
    mv s6, a2
    mv s10, s3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s6, sp
    RV_IMM s7, 4096, 64
    mv s10, s7
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv s8, s5
    mv s10, t0
    RV_FLAGS add, 64
    mv s5, s11
    RV_JUMP .Larc_walk_entry
.Larc_walk_ok:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Larc_walk_return
.Larc_walk_bad:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
.Larc_walk_return:
    RV_IMM s7, 4128, 64
    mv s10, s7
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
.section .rodata
arc_gzip: .asciz "/usr/bin/gzip"
arc_gzip_d: .asciz "-d"
arc_gzip_c: .asciz "-c"
arc_dot: .asciz "."
arc_slash: .asciz "/"
arc_hex: .ascii "0123456789abcdef"
.balign 8
arc_gzip_argv: .quad arc_gzip, arc_gzip_d, arc_gzip_c, 0
arc_empty_env: .quad 0
.section .data
arc_stage_name: .ascii ".asm-stage-"
.zero 34
.section .bss
.balign 16
arc_input_path: .skip 8
arc_output_path: .skip 8
arc_parent_fd: .skip 8
arc_root_fd: .skip 8
arc_raw_size: .skip 8
arc_entry_count: .skip 8
arc_file_count: .skip 8
arc_operation: .skip 4
arc_result: .skip 4
arc_child_status: .skip 4
arc_pipe: .skip 8
arc_stage_created: .skip 1
arc_random: .skip 16
arc_stat: .skip RV_STAT_BYTES
arc_output_copy: .skip 4096
arc_destination_leaf: .skip 256
arc_member_copy: .skip 256
arc_scan_path: .skip 256
arc_seen: .skip ARC_COUNT
.balign 16
arc_entries: .skip ARC_COUNT * 32
arc_paths: .skip ARC_COUNT * 256
arc_compare_buffer: .skip 65536
arc_data: .skip ARC_LIMIT + 1
.section .note.GNU-stack,""
