/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and README.md#license for the terms and scope.
 */
.global extract_source_archive, verify_source_archive
.global validate_source_archive, source_archive_member

/* Source archive boundary. Linux AArch64, Asm AArch64 callee-saved registers preserved.
 * extract_source_archive(gzip_path, new_directory) returns 0 or 1.
 * verify_source_archive(gzip_path, existing_directory) returns 0 or 1.
 * Callers verify the compressed artifact digest before either operation.
 * Both paths are NUL-terminated. The destination parent must already exist.
 * Calls are serial: bounded buffers belong to this module, not the stack.
 * Public calls preserve x19/x20/x21-x24. Other integer registers and flags are
 * scratch. All nested calls use the same rule unless a parser cursor is noted.
 * All TAR parsing, path checks, file comparison and extraction are assembly.
 * A fixed /usr/bin/gzip process receives an already opened file on stdin and
 * an empty environment. Its output is capped before any filesystem mutation.
 */
.equ ARC_LIMIT, 67108864
.equ ARC_FILE_LIMIT, 16777216
.equ ARC_COUNT, 4096
.equ ARC_PATH, 240
.equ ARC_RDONLY, O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK        /* O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK */
.equ ARC_DIRECTORY, ARC_RDONLY | O_DIRECTORY     /* above | O_DIRECTORY */
.equ ARC_CREATE, O_CLOEXEC | O_NOFOLLOW | 193        /* O_CLOEXEC | O_NOFOLLOW | O_WRONLY | O_CREAT | O_EXCL */

/* Native AArch64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each ARM_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */

.section .text
/* Read-only validation. A successful call leaves a bounded member table for
 * source_archive_member. No file is created. x0 is the gzip path; w9=0/1. */
validate_source_archive:
    ARM_SAVE x19
    ARM_ADDR x16, arc_input_path
    str x0, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, arc_entry_count
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, arc_file_count
    str x10, [x16]
    // Forward string loops do not use a direction flag.
    ARM_CALL arc_decompress
    tst w9, w9
    b.ne .Larc_validate_only_done
    ARM_CALL arc_validate
.Larc_validate_only_done:
    ARM_RESTORE x19
    ret

/* Lookup after successful validation. x0=name. x9=borrowed content pointer,
 * x2=byte count, w3=0 for a file or 1 for a directory. x9=0 means absent.
 * Pointers remain valid until the next archive operation. */
source_archive_member:
    eor w4, w4, w4
    tst w4, w4
.Larc_member_lookup:
    ARM_ADDR x16, arc_entry_count
    ldr x11, [x16]
    cmp x4, x11
    b.hs .Larc_member_absent
    mov x9, x4
    lsl x9, x9, #8
    tst x9, x9
    ARM_ADDR x16, arc_paths
    mov x1, x16
    adds x1, x1, x9
    eor w3, w3, w3
    tst w3, w3
.Larc_lookup_compare:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x1
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_lookup_next
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Larc_lookup_found
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Larc_lookup_compare
.Larc_lookup_next:
    ARM_IMM x11, 1
    adds x4, x4, x11
    b .Larc_member_lookup
.Larc_lookup_found:
    lsl x4, x4, #5
    tst x4, x4
    ARM_ADDR x16, arc_entries
    mov x1, x16
    adds x1, x1, x4
    ARM_ADDR x16, arc_data
    mov x9, x16
    mov x16, x1
    ldr x11, [x16]
    adds x9, x9, x11
    mov x16, x1
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
    mov x16, x1
    add x16, x16, #20
    ldr w10, [x16]
    mov w3, w10
    ret
.Larc_member_absent:
    eor w9, w9, w9
    tst w9, w9
    ret

extract_source_archive:
    eor w2, w2, w2
    tst w2, w2
    b arc_operation_start
verify_source_archive:
    ARM_IMM w10, 1
    mov w2, w10
/* Shared terminal operation body. w2 selects extraction (0) or comparison
 * (1). Owns the root/parent descriptors and stage flag. Stack frame: 112 bytes. */
arc_operation_start:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_ADDR x16, arc_input_path
    str x0, [x16]
    ARM_ADDR x16, arc_output_path
    str x1, [x16]
    ARM_ADDR x16, arc_operation
    str w2, [x16]
    ARM_IMM x10, -1
    ARM_ADDR x16, arc_parent_fd
    str x10, [x16]
    ARM_IMM x10, -1
    ARM_ADDR x16, arc_root_fd
    str x10, [x16]
    ARM_IMM w10, 0
    ARM_ADDR x16, arc_stage_created
    strb w10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, arc_entry_count
    str x10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, arc_file_count
    str x10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, arc_result
    str w10, [x16]
    // Forward string loops do not use a direction flag.
    ARM_ADDR x16, arc_seen
    mov x0, x16
    ARM_IMM w10, ARC_COUNT
    mov w3, w10
    eor w9, w9, w9
    tst w9, w9
    cbz x3, .Lport_archive_1_end
.Lport_archive_1:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_archive_1
.Lport_archive_1_end:
    ARM_CALL arc_decompress
    tst w9, w9
    b.ne .Larc_finish
    ARM_CALL arc_validate
    tst w9, w9
    b.ne .Larc_finish
    ARM_CALL arc_open_parent
    tst w9, w9
    b.ne .Larc_finish
    ARM_ADDR x16, arc_operation
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_extract
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, arc_destination_leaf
    mov x1, x16
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_finish
    ARM_ADDR x16, arc_root_fd
    str x9, [x16]
    mov x0, x9
    eor w1, w1, w1
    tst w1, w1
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arc_walk_tree
    tst w9, w9
    b.ne .Larc_finish
    eor w3, w3, w3
    tst w3, w3
    ARM_ADDR x16, arc_seen
    mov x2, x16
.Larc_check_seen:
    ARM_ADDR x16, arc_entry_count
    ldr x11, [x16]
    cmp x3, x11
    b.hs .Larc_success
    mov x16, x2
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_finish
    ARM_IMM x11, 1
    adds x3, x3, x11
    b .Larc_check_seen
.Larc_extract:
    ARM_CALL arc_create_stage
    tst w9, w9
    b.ne .Larc_finish
    eor w21, w21, w21
    tst w21, w21
.Larc_extract_entry:
    ARM_ADDR x16, arc_entry_count
    ldr x11, [x16]
    cmp x21, x11
    b.hs .Larc_publish_stage
    mov x9, x21
    lsl x9, x9, #8
    tst x9, x9
    ARM_ADDR x16, arc_paths
    mov x0, x16
    adds x0, x0, x9
    ARM_CALL arc_member_parent
    tst x9, x9
    b.mi .Larc_finish
    mov x22, x9
    mov x23, x2
    mov x9, x21
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, arc_entries
    mov x24, x16
    adds x24, x24, x9
    mov x16, x24
    add x16, x16, #20
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_extract_file
    mov x0, x22
    mov x1, x23
    ARM_IMM w10, 493
    mov w2, w10
    ARM_CALL arm_mkdirat
    tst x9, x9
    b.pl .Larc_extract_directory_check
    ARM_IMM x11, -17
    cmp x9, x11
    b.ne .Larc_extract_parent_error
.Larc_extract_directory_check:
    mov x0, x22
    mov x1, x23
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_extract_parent_error
    mov x0, x9
    ARM_CALL arc_close
    b .Larc_extract_next
.Larc_extract_file:
    mov x0, x22
    mov x1, x23
    ARM_IMM w10, ARC_CREATE
    mov w2, w10
    ARM_IMM w10, 384
    mov w6, w10
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_extract_parent_error
    mov x20, x9
    ARM_ADDR x16, arc_data
    mov x1, x16
    mov x16, x24
    ldr x11, [x16]
    adds x1, x1, x11
    mov x16, x24
    add x16, x16, #8
    ldr x10, [x16]
    mov x2, x10
.Larc_write:
    tst x2, x2
    b.eq .Larc_file_mode
    mov x0, x20
    ARM_CALL arm_write
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_write
    tst x9, x9
    b.le .Larc_extract_file_error
    adds x1, x1, x9
    subs x2, x2, x9
    b .Larc_write
.Larc_file_mode:
    mov x0, x20
    mov x16, x24
    add x16, x16, #16
    ldr w10, [x16]
    mov w1, w10
    ARM_CALL arm_fchmod
    tst x9, x9
    b.mi .Larc_extract_file_error
    mov x0, x20
    ARM_CALL arc_close
.Larc_extract_next:
    mov x0, x22
    ARM_CALL arc_close
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Larc_extract_entry
.Larc_extract_file_error:
    mov x0, x20
    ARM_CALL arc_close
.Larc_extract_parent_error:
    mov x0, x22
    ARM_CALL arc_close
    b .Larc_finish
.Larc_publish_stage:
    ARM_ADDR x16, arc_root_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, 493
    mov w1, w10
    ARM_CALL arm_fchmod
    tst x9, x9
    b.mi .Larc_finish
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, arc_stage_name
    mov x1, x16
    mov x2, x0
    ARM_ADDR x16, arc_destination_leaf
    mov x6, x16
    ARM_IMM w10, 1
    mov w4, w10
    ARM_CALL arm_renameat2
    tst x9, x9
    b.mi .Larc_finish
    ARM_IMM w10, 0
    ARM_ADDR x16, arc_stage_created
    strb w10, [x16]
.Larc_success:
    ARM_IMM w10, 0
    ARM_ADDR x16, arc_result
    str w10, [x16]
.Larc_finish:
    ARM_ADDR x16, arc_stage_created
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_close_root
    ARM_ADDR x16, arc_root_fd
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.mi .Larc_remove_stage
    eor w1, w1, w1
    tst w1, w1
    ARM_IMM w10, 1
    mov w2, w10
    ARM_CALL arc_walk_tree
.Larc_remove_stage:
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, arc_stage_name
    mov x1, x16
    ARM_IMM w10, 512
    mov w2, w10
    ARM_CALL arm_unlinkat
.Larc_close_root:
    ARM_ADDR x16, arc_root_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    ARM_ADDR x16, arc_result
    ldr w10, [x16]
    mov w9, w10
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Close an owned descriptor. Negative descriptors are an empty slot. */
arc_close:
    tst x0, x0
    b.mi .Larc_close_done
    ARM_CALL arm_close
.Larc_close_done:
    ret

/* Ensure our descriptors cannot alias stdin/stdout/stderr in the child. */
arc_promote_fd:
    ARM_IMM x11, 3
    cmp x0, x11
    b.hs .Larc_promote_same
    ARM_SAVE x19
    mov x19, x0
    ARM_IMM w10, 1030 /* F_DUPFD_CLOEXEC */
    mov w1, w10
    ARM_IMM w10, 3
    mov w2, w10
    ARM_CALL arm_fcntl
    ARM_SAVE x9
    mov x0, x19
    ARM_CALL arc_close
    ARM_RESTORE x9
    ARM_RESTORE x19
    ret
.Larc_promote_same:
    mov x9, x0
    ret

/* Input: arc_input_path. Output: w9=0/1, arc_data[0..arc_raw_size) on success.
 * Capacity: 64 MiB + one overflow byte. Owns source/pipe descriptors and child.
 * Retries EINTR, reaps the child, and caps output before validation. Frame: 112. */
arc_decompress:
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
    ARM_IMM x10, 0
    ARM_ADDR x16, arc_raw_size
    str x10, [x16]
    ARM_IMM x10, -100
    mov x0, x10
    ARM_ADDR x16, arc_input_path
    ldr x10, [x16]
    mov x1, x10
    ARM_IMM w10, ARC_RDONLY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_decompress_fail
    mov x0, x9
    ARM_CALL arc_promote_fd
    tst x9, x9
    b.mi .Larc_decompress_fail
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, arc_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Larc_decompress_fail
    ARM_ADDR x16, arc_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Larc_decompress_fail
    ARM_ADDR x16, arc_stat + ARM_STAT_SIZE
    ldr x10, [x16]
    mov x9, x10
    tst x9, x9
    b.le .Larc_decompress_fail
    ARM_IMM x11, ARC_LIMIT
    cmp x9, x11
    b.hi .Larc_decompress_fail
    ARM_ADDR x16, arc_pipe
    mov x0, x16
    ARM_IMM w10, 524288
    mov w1, w10
    ARM_CALL arm_pipe2
    tst x9, x9
    b.mi .Larc_decompress_fail
    ARM_ADDR x16, arc_pipe
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arc_promote_fd
    mov x22, x9
    ARM_ADDR x16, arc_pipe + 4
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arc_promote_fd
    mov x23, x9
    tst x22, x22
    b.mi .Larc_decompress_fail
    tst x23, x23
    b.mi .Larc_decompress_fail
    ARM_CALL arm_fork
    tst x9, x9
    b.mi .Larc_decompress_fail
    b.eq .Larc_gzip_child
    mov x24, x9
    mov x0, x23
    ARM_CALL arc_close
    ARM_IMM x10, -1
    mov x23, x10
    mov x0, x21
    ARM_CALL arc_close
    ARM_IMM x10, -1
    mov x21, x10
    eor w19, w19, w19
    tst w19, w19
.Larc_gzip_read:
    mov x0, x22
    ARM_ADDR x16, arc_data
    mov x1, x16
    adds x1, x1, x19
    ARM_IMM w10, ARC_LIMIT + 1
    mov w2, w10
    subs x2, x2, x19
    ARM_IMM x11, 65536
    cmp x2, x11
    b.ls .Larc_gzip_read_size
    ARM_IMM w10, 65536
    mov w2, w10
.Larc_gzip_read_size:
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_gzip_read
    tst x9, x9
    b.mi .Larc_decompress_kill
    b.eq .Larc_gzip_eof
    adds x19, x19, x9
    ARM_IMM x11, ARC_LIMIT
    cmp x19, x11
    b.hi .Larc_decompress_kill
    b .Larc_gzip_read
.Larc_gzip_eof:
    ARM_ADDR x16, arc_raw_size
    str x19, [x16]
    mov x0, x22
    ARM_CALL arc_close
    ARM_IMM x10, -1
    mov x22, x10
.Larc_gzip_wait:
    mov x0, x24
    ARM_ADDR x16, arc_child_status
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_gzip_wait
    tst x9, x9
    b.mi .Larc_decompress_fail
    ARM_IMM x10, -1
    mov x24, x10
    ARM_ADDR x16, arc_child_status
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Larc_decompress_fail
    eor w20, w20, w20
    tst w20, w20
    b .Larc_decompress_close
.Larc_decompress_kill:
    mov x0, x24
    ARM_IMM w10, 9
    mov w1, w10
    ARM_CALL arm_kill
.Larc_decompress_reap:
    mov x0, x24
    ARM_ADDR x16, arc_child_status
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_decompress_reap
    ARM_IMM x10, -1
    mov x24, x10
.Larc_decompress_fail:
    ARM_IMM w10, 1
    mov w20, w10
.Larc_decompress_close:
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
.Larc_gzip_child:
    mov x0, x21
    eor w1, w1, w1
    tst w1, w1
    ARM_CALL arm_dup2
    tst x9, x9
    b.mi .Larc_gzip_child_fail
    mov x0, x23
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_dup2
    tst x9, x9
    b.mi .Larc_gzip_child_fail
    mov x0, x21
    ARM_CALL arc_close
    mov x0, x22
    ARM_CALL arc_close
    mov x0, x23
    ARM_CALL arc_close
    ARM_ADDR x16, arc_gzip
    mov x0, x16
    ARM_ADDR x16, arc_gzip_argv
    mov x1, x16
    ARM_ADDR x16, arc_empty_env
    mov x2, x16
    ARM_CALL arm_execve
.Larc_gzip_child_fail:
    ARM_IMM w10, 126
    mov w0, w10
    ARM_CALL arm_exit
    brk #0

/* Return 1 for an all-zero region, including the empty region. */
arc_is_zero:
    mov x3, x1
    eor w9, w9, w9
    tst w9, w9
    cbz x3, .Lport_archive_2_end
.Lport_archive_2:
    and w10, w9, #255
    ldrb w11, [x0], #1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    sub x3, x3, #1
    b.ne .Lport_archive_2_end
    cbnz x3, .Lport_archive_2
.Lport_archive_2_end:
    cset w10, eq
    bfi x9, x10, #0, #8
    ret

/* Input: x0=bounded field, w3=field size. Output: x9=unsigned octal value.
 * Carry is clear on success and set on failure. Other NZCV flags are scratch.
 * Leading spaces and NUL/space suffixes are permitted. No saved frame. */
arc_octal:
    eor w9, w9, w9
    tst w9, w9
    eor w4, w4, w4
    tst w4, w4
.Larc_octal_leading:
    tst w3, w3
    b.eq .Larc_octal_bad
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_octal_digits
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM w11, 1
    subs w3, w3, w11
    b .Larc_octal_leading
.Larc_octal_digits:
    tst w3, w3
    b.eq .Larc_octal_end
    mov x16, x0
    ldrb w10, [x16]
    mov w2, w10
    ARM_IMM w11, 48
    cmp w2, w11
    b.lo .Larc_octal_suffix
    ARM_IMM w11, 55
    cmp w2, w11
    b.hi .Larc_octal_bad
    mov x5, x9
    lsr x5, x5, #61
    tst x5, x5
    b.ne .Larc_octal_bad
    lsl x9, x9, #3
    tst x9, x9
    ARM_IMM w11, 48
    subs w2, w2, w11
    orr x9, x9, x2
    tst x9, x9
    ARM_IMM w11, 1
    adds w4, w4, w11
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM w11, 1
    subs w3, w3, w11
    b .Larc_octal_digits
.Larc_octal_suffix:
    tst w2, w2
    b.eq .Larc_octal_suffix_next
    ARM_IMM w11, 32
    cmp w2, w11
    b.ne .Larc_octal_bad
.Larc_octal_suffix_next:
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM w11, 1
    subs w3, w3, w11
    b.eq .Larc_octal_end
    mov x16, x0
    ldrb w10, [x16]
    mov w2, w10
    b .Larc_octal_suffix
.Larc_octal_end:
    tst w4, w4
    b.eq .Larc_octal_bad
    adds xzr, xzr, xzr
    ret
.Larc_octal_bad:
    cmp xzr, xzr
    ret

/* Input: x0=bounded TAR field, w3=field size. Output: w9=text length.
 * Carry is clear on success and set on failure. Other NZCV flags are scratch.
 * The field ends at its first NUL. Remaining bytes must be zero. No frame. */
arc_field_length:
    eor w9, w9, w9
    tst w9, w9
.Larc_field_scan:
    cmp w9, w3
    b.hs .Larc_field_ok
    mov x16, x0
    add x16, x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_field_tail
    ARM_IMM w11, 1
    adds w9, w9, w11
    b .Larc_field_scan
.Larc_field_tail:
    mov w2, w9
.Larc_field_tail_loop:
    cmp w2, w3
    b.hs .Larc_field_ok
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_field_bad
    ARM_IMM w11, 1
    adds w2, w2, w11
    b .Larc_field_tail_loop
.Larc_field_ok:
    adds xzr, xzr, xzr
    ret
.Larc_field_bad:
    cmp xzr, xzr
    ret

/* Portable member paths. Dot segments, empty segments, trailing dots, option
 * prefixes, controls and shell/path punctuation cannot reach openat. */
arc_path_valid:
    tst w1, w1
    b.eq .Larc_path_bad
    ARM_IMM w11, ARC_PATH
    cmp w1, w11
    b.hi .Larc_path_bad
    eor w3, w3, w3
    tst w3, w3
    eor w4, w4, w4
    tst w4, w4
.Larc_path_loop:
    cmp w3, w1
    b.hs .Larc_path_last
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 47
    cmp w9, w11
    b.eq .Larc_path_separator
    tst w4, w4
    b.ne .Larc_path_character
    ARM_IMM w11, 45
    cmp w9, w11
    b.eq .Larc_path_bad
.Larc_path_character:
    ARM_IMM w11, 65
    cmp w9, w11
    b.lo .Larc_path_digit
    ARM_IMM w11, 90
    cmp w9, w11
    b.ls .Larc_path_advance
    ARM_IMM w11, 97
    cmp w9, w11
    b.lo .Larc_path_symbol
    ARM_IMM w11, 122
    cmp w9, w11
    b.ls .Larc_path_advance
    b .Larc_path_bad
.Larc_path_digit:
    ARM_IMM w11, 48
    cmp w9, w11
    b.lo .Larc_path_symbol
    ARM_IMM w11, 57
    cmp w9, w11
    b.ls .Larc_path_advance
.Larc_path_symbol:
    ARM_IMM w11, 95
    cmp w9, w11
    b.eq .Larc_path_advance
    ARM_IMM w11, 46
    cmp w9, w11
    b.eq .Larc_path_advance
    ARM_IMM w11, 45
    cmp w9, w11
    b.ne .Larc_path_bad
.Larc_path_advance:
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 1
    adds w4, w4, w11
    b .Larc_path_loop
.Larc_path_separator:
    tst w4, w4
    b.eq .Larc_path_bad
    mov x16, x0
    add x16, x16, x3
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_path_bad
    eor w4, w4, w4
    tst w4, w4
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Larc_path_loop
.Larc_path_last:
    tst w4, w4
    b.eq .Larc_path_bad
    mov x16, x0
    add x16, x16, x3
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_path_bad
    eor w9, w9, w9
    tst w9, w9
    ret
.Larc_path_bad:
    ARM_IMM w10, 1
    mov w9, w10
    ret

/* Compare a new path to previous paths, folding ASCII case. Reject duplicates
 * and either ordering of a regular file used as an ancestor directory. */
arc_check_conflicts:
    eor w4, w4, w4
    tst w4, w4
.Larc_conflict_entry:
    ARM_ADDR x16, arc_entry_count
    ldr x11, [x16]
    cmp x4, x11
    b.hs .Larc_conflict_ok
    mov x9, x4
    lsl x9, x9, #8
    tst x9, x9
    ARM_ADDR x16, arc_paths
    mov x5, x16
    adds x5, x5, x9
    eor w3, w3, w3
    tst w3, w3
.Larc_conflict_char:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    mov x16, x5
    add x16, x16, x3
    ldrb w10, [x16]
    mov w2, w10
    tst w9, w9
    b.eq .Larc_conflict_new_end
    tst w2, w2
    b.eq .Larc_conflict_old_end
    ARM_IMM w11, 65
    cmp w9, w11
    b.lo .Larc_conflict_fold_old
    ARM_IMM w11, 90
    cmp w9, w11
    b.hi .Larc_conflict_fold_old
    ARM_IMM w11, 32
    adds w9, w9, w11
.Larc_conflict_fold_old:
    ARM_IMM w11, 65
    cmp w2, w11
    b.lo .Larc_conflict_compare
    ARM_IMM w11, 90
    cmp w2, w11
    b.hi .Larc_conflict_compare
    ARM_IMM w11, 32
    adds w2, w2, w11
.Larc_conflict_compare:
    cmp w9, w2
    b.ne .Larc_conflict_next
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Larc_conflict_char
.Larc_conflict_new_end:
    tst w2, w2
    b.eq .Larc_conflict_bad
    ARM_IMM w11, 47
    cmp w2, w11
    b.ne .Larc_conflict_next
    tst w1, w1
    b.eq .Larc_conflict_bad
    b .Larc_conflict_next
.Larc_conflict_old_end:
    ARM_IMM w11, 47
    cmp w9, w11
    b.ne .Larc_conflict_next
    mov x9, x4
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, arc_entries
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    add x16, x16, #20
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_conflict_bad
.Larc_conflict_next:
    ARM_IMM x11, 1
    adds x4, x4, x11
    b .Larc_conflict_entry
.Larc_conflict_ok:
    eor w9, w9, w9
    tst w9, w9
    ret
.Larc_conflict_bad:
    ARM_IMM w10, 1
    mov w9, w10
    ret

/* Input: bounded arc_data/raw_size. Output: w9=0/1, paths and member table.
 * Table bounds: 4096 records, 256 bytes/path, 32 bytes/record. No file writes.
 * Scratch stack: 128 bytes including callee-saved registers. */
arc_validate:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #32
    ARM_ADDR x16, arc_data
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
    ARM_ADDR x16, arc_raw_size
    ldr x10, [x16]
    mov x23, x10
    ARM_IMM x11, 511
    tst x23, x11
    b.ne .Larc_validate_bad
.Larc_header:
    mov x16, x22
    add x16, x16, #512
    mov x9, x16
    cmp x9, x23
    b.hi .Larc_validate_bad
    mov x16, x21
    add x16, x16, x22
    mov x19, x16
    mov x0, x19
    ARM_IMM w10, 512
    mov w1, w10
    ARM_CALL arc_is_zero
    tst w9, w9
    b.ne .Larc_tar_end
    ARM_ADDR x16, arc_entry_count
    ldr x10, [x16]
    ARM_IMM x11, ARC_COUNT
    cmp x10, x11
    b.hs .Larc_validate_bad
    mov x16, x19
    add x16, x16, #257
    ldr w10, [x16]
    ARM_IMM w11, 1635021685
    cmp w10, w11
    b.ne .Larc_validate_bad
    mov x16, x19
    add x16, x16, #261
    ldrh w10, [x16]
    ARM_IMM w11, 114
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Larc_validate_bad
    mov x16, x19
    add x16, x16, #263
    ldrh w10, [x16]
    ARM_IMM w11, 12336
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Larc_validate_bad
    eor w20, w20, w20
    tst w20, w20
    eor w3, w3, w3
    tst w3, w3
.Larc_checksum:
    mov x16, x19
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM w11, 148
    cmp w3, w11
    b.lo .Larc_checksum_add
    ARM_IMM w11, 156
    cmp w3, w11
    b.hs .Larc_checksum_add
    ARM_IMM w10, 32
    mov w9, w10
.Larc_checksum_add:
    adds w20, w20, w9
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 512
    cmp w3, w11
    b.lo .Larc_checksum
    mov x16, x19
    add x16, x16, #148
    mov x0, x16
    ARM_IMM w10, 8
    mov w3, w10
    ARM_CALL arc_octal
    b.cs .Larc_validate_bad
    cmp x9, x20
    b.ne .Larc_validate_bad
    mov x16, x19
    add x16, x16, #156
    ldrb w10, [x16]
    mov w9, w10
    eor w20, w20, w20
    tst w20, w20
    tst w9, w9
    b.eq .Larc_header_type
    ARM_IMM w11, 48
    cmp w9, w11
    b.eq .Larc_header_type
    ARM_IMM w11, 53
    cmp w9, w11
    b.ne .Larc_validate_bad
    ARM_IMM w10, 1
    mov w20, w10
.Larc_header_type:
    mov x16, sp
    str w20, [x16]
    mov x16, x19
    add x16, x16, #157
    mov x0, x16
    ARM_IMM w10, 100
    mov w1, w10
    ARM_CALL arc_is_zero
    tst w9, w9
    b.eq .Larc_validate_bad
    ARM_ADDR x16, arc_entry_count
    ldr x10, [x16]
    mov x9, x10
    lsl x9, x9, #8
    tst x9, x9
    ARM_ADDR x16, arc_paths
    mov x24, x16
    adds x24, x24, x9
    mov x16, x19
    add x16, x16, #345
    mov x0, x16
    ARM_IMM w10, 155
    mov w3, w10
    ARM_CALL arc_field_length
    b.cs .Larc_validate_bad
    mov x20, x9
    mov x16, x19
    add x16, x16, #345
    mov x1, x16
    mov x0, x24
    mov x3, x20
    cbz x3, .Lport_archive_3_end
.Lport_archive_3:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_archive_3
.Lport_archive_3_end:
    tst x20, x20
    b.eq .Larc_path_name
    ARM_IMM w10, 47
    mov x16, x24
    add x16, x16, x20
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x20, x20, x11
.Larc_path_name:
    mov x0, x19
    ARM_IMM w10, 100
    mov w3, w10
    ARM_CALL arc_field_length
    b.cs .Larc_validate_bad
    tst x9, x9
    b.eq .Larc_validate_bad
    mov x16, x20
    add x16, x16, x9
    mov x2, x16
    ARM_IMM x11, ARC_PATH
    cmp x2, x11
    b.hi .Larc_validate_bad
    mov x1, x19
    mov x16, x24
    add x16, x16, x20
    mov x0, x16
    mov x3, x9
    cbz x3, .Lport_archive_4_end
.Lport_archive_4:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_archive_4
.Lport_archive_4_end:
    mov x20, x2
    mov x16, sp
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_path_terminate
.Larc_trim_directory:
    tst x20, x20
    b.eq .Larc_validate_bad
    mov x16, x24
    add x16, x16, x20
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_path_terminate
    ARM_IMM x11, 1
    subs x20, x20, x11
    b .Larc_trim_directory
.Larc_path_terminate:
    ARM_IMM w10, 0
    mov x16, x24
    add x16, x16, x20
    strb w10, [x16]
    mov x0, x24
    mov x1, x20
    ARM_CALL arc_path_valid
    tst w9, w9
    b.ne .Larc_validate_bad
    mov x0, x24
    mov x16, sp
    ldr w10, [x16]
    mov w1, w10
    ARM_CALL arc_check_conflicts
    tst w9, w9
    b.ne .Larc_validate_bad
    mov x16, x19
    add x16, x16, #100
    mov x0, x16
    ARM_IMM w10, 8
    mov w3, w10
    ARM_CALL arc_octal
    b.cs .Larc_validate_bad
    ARM_IMM x11, 420
    cmp x9, x11
    b.eq .Larc_mode_ok
    ARM_IMM x11, 493
    cmp x9, x11
    b.ne .Larc_validate_bad
.Larc_mode_ok:
    mov x16, sp
    add x16, x16, #4
    str w9, [x16]
    mov x16, x19
    add x16, x16, #108
    mov x0, x16
    ARM_IMM w10, 8
    mov w3, w10
    ARM_CALL arc_octal
    b.cs .Larc_validate_bad
    tst x9, x9
    b.ne .Larc_validate_bad
    mov x16, x19
    add x16, x16, #116
    mov x0, x16
    ARM_IMM w10, 8
    mov w3, w10
    ARM_CALL arc_octal
    b.cs .Larc_validate_bad
    tst x9, x9
    b.ne .Larc_validate_bad
    mov x16, x19
    add x16, x16, #124
    mov x0, x16
    ARM_IMM w10, 12
    mov w3, w10
    ARM_CALL arc_octal
    b.cs .Larc_validate_bad
    ARM_IMM x11, ARC_FILE_LIMIT
    cmp x9, x11
    b.hi .Larc_validate_bad
    mov x16, sp
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_size_file
    tst x9, x9
    b.ne .Larc_validate_bad
    b .Larc_size_ok
.Larc_size_file:
    ARM_ADDR x16, arc_file_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, arc_file_count
    str x12, [x16]
.Larc_size_ok:
    mov x16, sp
    add x16, x16, #8
    str x9, [x16]
    mov x16, x9
    add x16, x16, #511
    mov x20, x16
    ARM_IMM x11, -512
    and x20, x20, x11
    tst x20, x20
    mov x16, x22
    add x16, x16, #512
    mov x24, x16
    adds x20, x20, x24
    cmp x20, x23
    b.hi .Larc_validate_bad
    mov x16, x21
    add x16, x16, x24
    mov x0, x16
    adds x0, x0, x9
    mov x1, x20
    subs x1, x1, x24
    subs x1, x1, x9
    ARM_CALL arc_is_zero
    tst w9, w9
    b.eq .Larc_validate_bad
    ARM_ADDR x16, arc_entry_count
    ldr x10, [x16]
    mov x9, x10
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, arc_entries
    mov x2, x16
    adds x2, x2, x9
    mov x16, x2
    str x24, [x16]
    mov x16, sp
    add x16, x16, #8
    ldr x10, [x16]
    mov x9, x10
    mov x16, x2
    add x16, x16, #8
    str x9, [x16]
    mov x16, sp
    add x16, x16, #4
    ldr w10, [x16]
    mov w9, w10
    mov x16, x2
    add x16, x16, #16
    str w9, [x16]
    mov x16, sp
    ldr w10, [x16]
    mov w9, w10
    mov x16, x2
    add x16, x16, #20
    str w9, [x16]
    ARM_ADDR x16, arc_entry_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, arc_entry_count
    str x12, [x16]
    mov x22, x20
    b .Larc_header
.Larc_tar_end:
    mov x1, x23
    subs x1, x1, x22
    ARM_IMM x11, 1024
    cmp x1, x11
    b.lo .Larc_validate_bad
    mov x0, x19
    ARM_CALL arc_is_zero
    tst w9, w9
    b.eq .Larc_validate_bad
    ARM_ADDR x16, arc_file_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Larc_validate_bad
    eor w9, w9, w9
    tst w9, w9
    b .Larc_validate_return
.Larc_validate_bad:
    ARM_IMM w10, 1
    mov w9, w10
.Larc_validate_return:
    add sp, sp, #32
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Walk the user-supplied parent with O_NOFOLLOW on each component. No parent
 * is created. Dot is allowed as a parent; dot-dot is never followed. */
arc_open_parent:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    ARM_ADDR x16, arc_output_path
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, arc_output_copy
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
.Larc_copy_output:
    ARM_IMM w11, 4095
    cmp w3, w11
    b.hs .Larc_parent_bad
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Larc_output_copied
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Larc_copy_output
.Larc_output_copied:
    tst w3, w3
    b.eq .Larc_parent_bad
    mov x16, x0
    add x16, x16, x3
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_parent_bad
    ARM_ADDR x16, arc_output_copy
    mov x19, x16
    ARM_ADDR x16, arc_dot
    mov x1, x16
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_parent_open_start
    ARM_ADDR x16, arc_slash
    mov x1, x16
    ARM_IMM x11, 1
    adds x19, x19, x11
.Larc_parent_open_start:
    ARM_IMM x10, -100
    mov x0, x10
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_parent_bad
    ARM_ADDR x16, arc_parent_fd
    str x9, [x16]
.Larc_parent_component:
    mov x21, x19
    eor w22, w22, w22
    tst w22, w22
.Larc_parent_find_end:
    mov x16, x19
    ldrb w10, [x16]
    mov w9, w10
    tst w9, w9
    b.eq .Larc_parent_leaf
    ARM_IMM w11, 47
    cmp w9, w11
    b.eq .Larc_parent_descend
    ARM_IMM x11, 1
    adds x19, x19, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    ARM_IMM x11, 255
    cmp x22, x11
    b.hi .Larc_parent_bad
    b .Larc_parent_find_end
.Larc_parent_descend:
    tst x22, x22
    b.eq .Larc_parent_bad
    ARM_IMM w10, 0
    mov x16, x19
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x16, x21
    ldrh w10, [x16]
    ARM_IMM w11, 11822
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Larc_parent_not_dotdot
    mov x16, x21
    add x16, x16, #2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_parent_bad
.Larc_parent_not_dotdot:
    mov x16, x21
    ldrh w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Larc_parent_component
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    mov x1, x21
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_parent_bad
    mov x23, x9
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    ARM_ADDR x16, arc_parent_fd
    str x23, [x16]
    b .Larc_parent_component
.Larc_parent_leaf:
    tst x22, x22
    b.eq .Larc_parent_bad
    mov x16, x21
    ldrh w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Larc_parent_bad
    mov x16, x21
    ldrh w10, [x16]
    ARM_IMM w11, 11822
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Larc_parent_save_leaf
    mov x16, x21
    add x16, x16, #2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_parent_bad
.Larc_parent_save_leaf:
    ARM_ADDR x16, arc_destination_leaf
    mov x0, x16
    mov x1, x21
    mov x16, x22
    add x16, x16, #1
    mov x3, x16
    cbz x3, .Lport_archive_5_end
.Lport_archive_5:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_archive_5
.Lport_archive_5_end:
    eor w9, w9, w9
    tst w9, w9
    b .Larc_parent_return
.Larc_parent_bad:
    ARM_IMM w10, 1
    mov w9, w10
.Larc_parent_return:
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Input: owned arc_parent_fd. Output: w9=0/1, root fd and stage ownership flag.
 * Creates mode-0700 random sibling with mkdirat, then opens without following
 * a link. Stage-name capacity is 45 bytes; random input is 16 bytes. Frame: 16. */
arc_create_stage:
    ARM_SAVE x19
    ARM_ADDR x16, arc_random
    mov x0, x16
    ARM_IMM w10, 16
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_getrandom
    ARM_IMM x11, 16
    cmp x9, x11
    b.ne .Larc_stage_bad
    ARM_ADDR x16, arc_random
    mov x1, x16
    ARM_ADDR x16, arc_stage_name + 11
    mov x0, x16
    ARM_ADDR x16, arc_hex
    mov x4, x16
    eor w3, w3, w3
    tst w3, w3
.Larc_stage_hex:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    mov w2, w9
    lsr w9, w9, #4
    tst w9, w9
    ARM_IMM w11, 15
    and w2, w2, w11
    tst w2, w2
    mov x16, x4
    add x16, x16, x9
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov x16, x4
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x2, x10, #0, #8
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3, lsl #1
    strb w10, [x16]
    and w10, w2, #255
    mov x16, x0
    add x16, x16, x3, lsl #1
    add x16, x16, #1
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 16
    cmp w3, w11
    b.lo .Larc_stage_hex
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, #32
    strb w10, [x16]
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, arc_stage_name
    mov x1, x16
    ARM_IMM w10, 448
    mov w2, w10
    ARM_CALL arm_mkdirat
    tst x9, x9
    b.mi .Larc_stage_bad
    ARM_IMM w10, 1
    ARM_ADDR x16, arc_stage_created
    strb w10, [x16]
    ARM_ADDR x16, arc_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, arc_stage_name
    mov x1, x16
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_stage_bad
    ARM_ADDR x16, arc_root_fd
    str x9, [x16]
    eor w9, w9, w9
    tst w9, w9
    ARM_RESTORE x19
    ret
.Larc_stage_bad:
    ARM_IMM w10, 1
    mov w9, w10
    ARM_RESTORE x19
    ret

/* Open/create implied parent directories below the private staging descriptor.
 * Return an owned parent fd in x9 and final component pointer in x2. */
arc_member_parent:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    sub sp, sp, #16
    mov x1, x0
    ARM_ADDR x16, arc_member_copy
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
.Larc_member_copy:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.ne .Larc_member_copy
    ARM_ADDR x16, arc_root_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, 1030
    mov w1, w10
    ARM_IMM w10, 3
    mov w2, w10
    ARM_CALL arm_fcntl
    tst x9, x9
    b.mi .Larc_member_return
    mov x21, x9
    ARM_ADDR x16, arc_member_copy
    mov x19, x16
.Larc_member_component:
    mov x20, x19
.Larc_member_find:
    mov x16, x19
    ldrb w10, [x16]
    mov w9, w10
    tst w9, w9
    b.eq .Larc_member_done
    ARM_IMM w11, 47
    cmp w9, w11
    b.eq .Larc_member_descend
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Larc_member_find
.Larc_member_descend:
    ARM_IMM w10, 0
    mov x16, x19
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x19, x19, x11
    mov x0, x21
    mov x1, x20
    ARM_IMM w10, 493
    mov w2, w10
    ARM_CALL arm_mkdirat
    tst x9, x9
    b.pl .Larc_member_open
    ARM_IMM x11, -17
    cmp x9, x11
    b.ne .Larc_member_fail
.Larc_member_open:
    mov x0, x21
    mov x1, x20
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_member_fail
    mov x22, x9
    mov x0, x21
    ARM_CALL arc_close
    mov x21, x22
    b .Larc_member_component
.Larc_member_done:
    mov x9, x21
    mov x2, x20
    b .Larc_member_return
.Larc_member_fail:
    mov x0, x21
    ARM_CALL arc_close
    ARM_IMM x10, -1
    mov x9, x10
.Larc_member_return:
    add sp, sp, #16
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Match arc_scan_path to a record of requested type (w1). A directory may
 * also be an implicit parent. Return its index, -1 for implicit, -2 for error. */
arc_find_entry:
    eor w4, w4, w4
    tst w4, w4
    eor w5, w5, w5
    tst w5, w5
    ARM_ADDR x16, arc_scan_path
    mov x0, x16
.Larc_find_loop:
    ARM_ADDR x16, arc_entry_count
    ldr x11, [x16]
    cmp x4, x11
    b.hs .Larc_find_end
    mov x9, x4
    lsl x9, x9, #8
    tst x9, x9
    ARM_ADDR x16, arc_paths
    mov x2, x16
    adds x2, x2, x9
    eor w3, w3, w3
    tst w3, w3
.Larc_find_compare:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Larc_find_path_end
    and w10, w9, #255
    mov x16, x2
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_find_next
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Larc_find_compare
.Larc_find_path_end:
    mov x16, x2
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_find_exact
    mov x16, x2
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Larc_find_next
    ARM_IMM w10, 1
    mov w5, w10
.Larc_find_next:
    ARM_IMM x11, 1
    adds x4, x4, x11
    b .Larc_find_loop
.Larc_find_exact:
    mov x9, x4
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, arc_entries
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    add x16, x16, #20
    ldr w10, [x16]
    cmp w10, w1
    b.ne .Larc_find_bad
    mov x9, x4
    ret
.Larc_find_end:
    tst w1, w1
    b.eq .Larc_find_bad
    tst w5, w5
    b.eq .Larc_find_bad
    ARM_IMM x10, -1
    mov x9, x10
    ret
.Larc_find_bad:
    ARM_IMM x10, -2
    mov x9, x10
    ret

/* Verify one actual regular file against an expected record. x0 is its
 * parent, x1 its leaf, x4 its record index. No symlink or FIFO is followed. */
arc_compare_file:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov x21, x4
    ARM_IMM w10, ARC_RDONLY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_compare_bad_no_fd
    mov x22, x9
    mov x0, x22
    ARM_ADDR x16, arc_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Larc_compare_bad
    ARM_ADDR x16, arc_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Larc_compare_bad
    ARM_ADDR x16, arc_stat + ARM_STAT_LINKS
    ldr w10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Larc_compare_bad
    mov x9, x21
    lsl x9, x9, #5
    tst x9, x9
    ARM_ADDR x16, arc_entries
    mov x19, x16
    adds x19, x19, x9
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x23, x10
    ARM_ADDR x16, arc_stat + ARM_STAT_SIZE
    ldr x11, [x16]
    cmp x23, x11
    b.ne .Larc_compare_bad
    ARM_ADDR x16, arc_data
    mov x24, x16
    mov x16, x19
    ldr x11, [x16]
    adds x24, x24, x11
.Larc_compare_read:
    mov x0, x22
    ARM_ADDR x16, arc_compare_buffer
    mov x1, x16
    mov x2, x23
    ARM_IMM x11, 65536
    cmp x2, x11
    b.ls .Larc_compare_read_size
    ARM_IMM w10, 65536
    mov w2, w10
.Larc_compare_read_size:
    tst x2, x2
    b.eq .Larc_compare_eof
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_compare_read
    tst x9, x9
    b.le .Larc_compare_bad
    mov x20, x9
    mov x3, x9
    ARM_ADDR x16, arc_compare_buffer
    mov x1, x16
    mov x0, x24
    cbz x3, .Lport_archive_6_end
.Lport_archive_6:
    ldrb w10, [x1], #1
    ldrb w11, [x0], #1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    sub x3, x3, #1
    b.ne .Lport_archive_6_end
    cbnz x3, .Lport_archive_6
.Lport_archive_6_end:
    b.ne .Larc_compare_bad
    adds x24, x24, x20
    subs x23, x23, x20
    b .Larc_compare_read
.Larc_compare_eof:
    mov x0, x22
    ARM_ADDR x16, arc_compare_buffer
    mov x1, x16
    ARM_IMM w10, 1
    mov w2, w10
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_compare_eof
    tst x9, x9
    b.ne .Larc_compare_bad
    ARM_ADDR x16, arc_seen
    mov x2, x16
    ARM_IMM w10, 1
    mov x16, x2
    add x16, x16, x21
    strb w10, [x16]
    mov x0, x22
    ARM_CALL arc_close
    eor w9, w9, w9
    tst w9, w9
    b .Larc_compare_return
.Larc_compare_bad:
    mov x0, x22
    ARM_CALL arc_close
.Larc_compare_bad_no_fd:
    ARM_IMM w10, 1
    mov w9, w10
.Larc_compare_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Walk one directory without following links. Mode 0 compares the exact tree;
 * mode 1 removes a failed private stage. Each recursion owns its getdents buffer.
 * x0 fd, x1 prefix length in arc_scan_path, w2 mode. Own a fresh directory
 * descriptor per recursion; leave the caller's descriptor and cursor intact.
 * Prefix length remains bounded by ARC_PATH; all return paths close our FD. */
arc_walk_tree:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_IMM x17, 4128
    sub sp, sp, x17
    mov x21, x0
    mov x22, x1
    mov x16, sp
    ARM_IMM x17, 4104
    add x16, x16, x17
    str w2, [x16]
    mov x0, x21
    mov x21, #-1
    ARM_ADDR x1, arc_dot
    ARM_IMM w2, ARC_DIRECTORY
    mov x6, #0
.Larc_walk_open:
    ARM_CALL arm_openat
    cmn x9, #4
    b.eq .Larc_walk_open
    tst x9, x9
    b.mi .Larc_walk_bad
    mov x21, x9
.Larc_walk_read:
    mov x0, x21
    mov x10, sp
    mov x1, x10
    ARM_IMM w10, 4096
    mov w2, w10
    ARM_CALL arm_getdents64
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Larc_walk_read
    tst x9, x9
    b.mi .Larc_walk_bad
    b.eq .Larc_walk_ok
    mov x23, x9
    eor w24, w24, w24
    tst w24, w24
.Larc_walk_entry:
    cmp x24, x23
    b.hs .Larc_walk_read
    mov x16, sp
    add x16, x16, x24
    mov x19, x16
    mov x16, x24
    add x16, x16, #20
    mov x9, x16
    cmp x9, x23
    b.hi .Larc_walk_bad
    mov x16, x19
    add x16, x16, #16
    ldrh w10, [x16]
    mov w9, w10
    ARM_IMM w11, 20
    cmp w9, w11
    b.lo .Larc_walk_bad
    mov x16, x24
    add x16, x16, x9
    mov x2, x16
    cmp x2, x23
    b.hi .Larc_walk_bad
    mov x16, sp
    ARM_IMM x17, 4096
    add x16, x16, x17
    str w9, [x16]
    mov x16, x19
    add x16, x16, #19
    mov x19, x16
    ARM_IMM w11, 19
    subs w9, w9, w11
    eor w3, w3, w3
    tst w3, w3
.Larc_walk_name:
    cmp w3, w9
    b.hs .Larc_walk_bad
    mov x16, x19
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_walk_name_end
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Larc_walk_name
.Larc_walk_name_end:
    tst w3, w3
    b.eq .Larc_walk_bad
    mov x16, x19
    ldrh w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Larc_walk_next
    mov x16, x19
    ldrh w10, [x16]
    ARM_IMM w11, 11822
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Larc_walk_real_entry
    mov x16, x19
    add x16, x16, #2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Larc_walk_next
.Larc_walk_real_entry:
    mov x16, x22
    add x16, x16, x3
    mov x20, x16
    ARM_IMM x11, ARC_PATH
    cmp x20, x11
    b.hi .Larc_walk_bad
    ARM_ADDR x16, arc_scan_path
    mov x0, x16
    adds x0, x0, x22
    mov x1, x19
    ARM_IMM w11, 1
    adds w3, w3, w11
    cbz x3, .Lport_archive_7_end
.Lport_archive_7:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_archive_7
.Lport_archive_7_end:
    mov x0, x21
    mov x1, x19
    ARM_IMM w10, ARC_DIRECTORY
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi .Larc_walk_file
    mov x16, sp
    ARM_IMM x17, 4112
    add x16, x16, x17
    str x9, [x16]
    mov x16, sp
    ARM_IMM x17, 4104
    add x16, x16, x17
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Larc_walk_directory_recurse
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arc_find_entry
    ARM_IMM x11, -2
    cmp x9, x11
    b.eq .Larc_walk_directory_bad
    tst x9, x9
    b.mi .Larc_walk_directory_recurse
    ARM_ADDR x16, arc_seen
    mov x2, x16
    ARM_IMM w10, 1
    mov x16, x2
    add x16, x16, x9
    strb w10, [x16]
.Larc_walk_directory_recurse:
    ARM_ADDR x16, arc_scan_path
    mov x2, x16
    ARM_IMM w10, 47
    mov x16, x2
    add x16, x16, x20
    strb w10, [x16]
    ARM_IMM w10, 0
    mov x16, x2
    add x16, x16, x20
    add x16, x16, #1
    strb w10, [x16]
    mov x16, sp
    ARM_IMM x17, 4112
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    mov x16, x20
    add x16, x16, #1
    mov x1, x16
    mov x16, sp
    ARM_IMM x17, 4104
    add x16, x16, x17
    ldr w10, [x16]
    mov w2, w10
    ARM_CALL arc_walk_tree
    mov w20, w9
    mov x16, sp
    ARM_IMM x17, 4112
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    tst w20, w20
    b.ne .Larc_walk_bad
    mov x16, sp
    ARM_IMM x17, 4104
    add x16, x16, x17
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_walk_next
    mov x0, x21
    mov x1, x19
    ARM_IMM w10, 512
    mov w2, w10
    ARM_CALL arm_unlinkat
    tst x9, x9
    b.mi .Larc_walk_bad
    b .Larc_walk_next
.Larc_walk_directory_bad:
    mov x16, sp
    ARM_IMM x17, 4112
    add x16, x16, x17
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    b .Larc_walk_bad
.Larc_walk_file:
    mov x16, sp
    ARM_IMM x17, 4104
    add x16, x16, x17
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.eq .Larc_walk_compare_file
    mov x0, x21
    mov x1, x19
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_unlinkat
    tst x9, x9
    b.mi .Larc_walk_bad
    b .Larc_walk_next
.Larc_walk_compare_file:
    eor w1, w1, w1
    tst w1, w1
    ARM_CALL arc_find_entry
    tst x9, x9
    b.mi .Larc_walk_bad
    mov x4, x9
    mov x0, x21
    mov x1, x19
    ARM_CALL arc_compare_file
    tst w9, w9
    b.ne .Larc_walk_bad
.Larc_walk_next:
    ARM_ADDR x16, arc_scan_path
    mov x2, x16
    ARM_IMM w10, 0
    mov x16, x2
    add x16, x16, x22
    strb w10, [x16]
    mov x16, sp
    ARM_IMM x17, 4096
    add x16, x16, x17
    ldr w10, [x16]
    mov w9, w10
    adds x24, x24, x9
    b .Larc_walk_entry
.Larc_walk_ok:
    eor w9, w9, w9
    tst w9, w9
    b .Larc_walk_return
.Larc_walk_bad:
    ARM_IMM w10, 1
    mov w9, w10
.Larc_walk_return:
    mov w22, w9
    mov x0, x21
    ARM_CALL arc_close
    mov w9, w22
    ARM_IMM x17, 4128
    add sp, sp, x17
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
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
arc_stat: .skip ARM_STAT_BYTES
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
.section .note.GNU-stack,"",%progbits
