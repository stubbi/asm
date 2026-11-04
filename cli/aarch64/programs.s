/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Installed programs are distinct from project source dependencies.
 * Native internal ABI: x0-x7 inputs, x9 result; x19-x24 preserved. ARM_CALL
 * adds a 16-byte link frame. Every saved register uses 16 stack bytes.
 * Commands terminate; fatal paths retain the original error through cleanup.
 */
.equ PROGRAM_LIMIT, 128
.equ PROGRAM_STATE_LIMIT, 1048576

/* These small macros access process-owned state without changing flags. */
.macro P_LOAD reg, symbol
    ARM_ADDR x16, \symbol
    ldr \reg, [x16]
.endm
.macro P_STORE reg, symbol
    ARM_ADDR x16, \symbol
    str \reg, [x16]
.endm
.macro P_BYTE reg, symbol
    ARM_ADDR x16, \symbol
    ldrb \reg, [x16]
.endm
.macro P_SET value, symbol
    mov x10, #\value
    P_STORE x10, \symbol
.endm

.section .text
cmd_upgrade:
    P_SET 1, program_upgrade
    mov w10, #5
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command
cmd_installed:
    b program_local_command
cmd_uninstall:
    P_SET 1, program_remove

/* Parse local-only commands before touching the filesystem. Inputs are argv;
 * owns program_query. No registry access occurs. Stack: no local reservation. */
program_local_command:
    ARM_CALL next_arg
    cbz x9, .Lp_local_done
    P_STORE x9, program_arg
    mov x0, x9
    ARM_ADDR x1, registry_opt_json
    ARM_CALL streq
    cbnz w9, .Lp_local_json
    P_LOAD x0, program_arg
    ARM_ADDR x1, registry_opt_no_color
    ARM_CALL streq
    cbnz w9, program_local_command
    P_LOAD x0, program_arg
    ARM_ADDR x1, registry_opt_help
    ARM_CALL streq
    cbnz w9, program_help
    P_LOAD x0, program_arg
    ldrb w10, [x0]
    cmp w10, #45
    b.eq program_bad_args
    P_LOAD x10, program_query
    cbnz x10, program_bad_args
    P_LOAD x10, program_remove
    cbz x10, program_bad_args
    P_LOAD x0, program_arg
    ARM_CALL registry_valid_package
    cbz w9, program_bad_args
    P_LOAD x10, program_arg
    P_STORE x10, program_query
    b program_local_command
.Lp_local_json:
    mov w10, #1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b program_local_command
.Lp_local_done:
    P_LOAD x10, program_remove
    cbz x10, .Lp_local_open
    P_LOAD x10, program_query
    cbz x10, program_bad_args
.Lp_local_open:
    mov w0, #0
    ARM_CALL program_open_state
    ARM_CALL program_read_state
    P_LOAD x10, program_remove
    cbz x10, program_list
    P_LOAD x0, program_query
    ARM_CALL program_find
    cbz x9, program_not_managed
    P_STORE x9, program_found
    ldr x1, [x9, #40]
    ARM_ADDR x0, program_path
    ARM_CALL copy_string
    ARM_CALL program_open_destination
    ARM_CALL program_check_existing
    ARM_CALL program_make_stage
    ARM_CALL program_write_state
    ARM_CALL program_recheck_destination
    P_LOAD x0, program_dest_fd
    P_LOAD x1, program_dest_name
    P_LOAD x2, program_stage_fd
    ARM_ADDR x6, program_previous
    ARM_CALL arm_renameat
    tbnz x9, #63, program_io_error
    P_SET 1, program_mutated
    ARM_CALL program_commit_state
    tbnz x9, #63, .Lp_uninstall_rollback
    P_SET 0, program_mutated
    ARM_CALL registry_cleanup
    P_BYTE w10, json_mode
    cbz w10, exit_ok
    ARM_ADDR x0, program_ok_json
    ARM_CALL out
    b exit_ok
.Lp_uninstall_rollback:
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_previous
    P_LOAD x2, program_dest_fd
    P_LOAD x6, program_dest_name
    mov w4, #1
    ARM_CALL arm_renameat2
    tbnz x9, #63, program_recovery_error
    P_SET 0, program_mutated
    b program_io_error

/* mode=5 preflight, called after arguments are validated but before index IO.
 * Acquires the inventory lock; its descriptor remains held until cleanup.
 * Upgrade reuses its recorded HTTPS origin unless explicitly overridden.
 * Local origins need --index because local index paths are not persisted.
 * Stack: one saved register. Preserves registry-selected pointers. */
program_before_load:
    ARM_SAVE x19
    P_LOAD x10, program_upgrade
    cbz x10, .Lp_preflight_open
    P_LOAD x10, registry_output
    cbnz x10, program_bad_args
.Lp_preflight_open:
    mov w0, #1
    ARM_CALL program_open_state
    ARM_CALL program_read_state
    P_LOAD x0, registry_query
    ARM_CALL program_find
    P_STORE x9, program_found
    P_LOAD x10, program_upgrade
    cbnz x10, .Lp_preflight_upgrade
    cbnz x9, program_already_managed
    P_LOAD x10, program_count
    cmp x10, #PROGRAM_LIMIT
    b.hs program_state_error
    ARM_RESTORE x19
    ret
.Lp_preflight_upgrade:
    cbz x9, program_not_managed
    mov x19, x9
    ldr x10, [x19, #40]
    P_STORE x10, registry_output
    P_BYTE w10, registry_origin_seen
    cbnz w10, .Lp_preflight_origin
    ldr x0, [x19, #48]
    ARM_ADDR x1, program_local
    ARM_CALL streq
    cbnz w9, program_local_index_error
    ldr x10, [x19, #48]
    P_STORE x10, registry_url
.Lp_preflight_origin:
    P_BYTE w10, registry_local_index
    cbz w10, .Lp_preflight_https
    ARM_ADDR x0, program_local
    b .Lp_preflight_compare
.Lp_preflight_https:
    P_LOAD x0, registry_url
.Lp_preflight_compare:
    ldr x1, [x19, #48]
    ARM_CALL streq
    cbz w9, program_origin_error
    ARM_RESTORE x19
    ret

/* Validated selected registry row is borrowed from registry_selected. Before
 * transfer, upgrades check the managed bytes and reject older selections.
 * Equal selections require identical digest/size and leave files unchanged.
 * Stack: two saved registers. Buffer ownership stays with each parser. */
program_prepare_selection:
    ARM_SAVE x19
    ARM_SAVE x20
    P_LOAD x19, registry_selected
    P_LOAD x20, program_found
    P_LOAD x10, program_upgrade
    cbz x10, .Lp_prepare_done
    ldr x1, [x20, #40]
    ARM_ADDR x0, program_path
    ARM_CALL copy_string
    ARM_CALL program_open_destination
    ARM_CALL program_check_existing
    ldr x0, [x19, #8]
    ldr x1, [x20, #8]
    ARM_CALL registry_version_compare
    cmp w9, #0
    b.lt program_downgrade_error
    b.gt .Lp_prepare_done
    ldr x0, [x19, #32]
    ldr x1, [x20, #24]
    ARM_CALL streq
    cbz w9, program_changed_release
    ldr x0, [x19, #48]
    ldr x1, [x20, #32]
    ARM_CALL streq
    cbz w9, program_changed_release
    ARM_CALL registry_cleanup
    P_BYTE w10, json_mode
    cbz w10, exit_ok
    ARM_ADDR x0, program_unchanged_json
    ARM_CALL out
    b exit_ok
.Lp_prepare_done:
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Commit a checked executable. Candidate and rollback bytes are copied into a
 * private directory on the destination filesystem, fsynced, then renamed.
 * Inventory failure restores previous bytes/mode or removes a new install.
 * Power/process interruption between the two renames can leave a stage and
 * mismatched receipt. Directory crash durability and hostile same-UID races
 * are outside this advisory-lock contract. Stack: four saved registers. */
program_commit_install:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    P_LOAD x19, registry_selected
    P_LOAD x10, program_upgrade
    cbnz x10, .Lp_commit_opened
    P_LOAD x1, registry_output
    ARM_CALL program_absolute_path
    ARM_CALL program_check_new_path
    ARM_CALL program_open_destination
    P_LOAD x0, program_dest_fd
    P_LOAD x1, program_dest_name
    ARM_ADDR x2, program_check_stat
    mov x6, #256
    ARM_CALL arm_newfstatat
    cmn x9, #2
    b.ne program_destination_exists
.Lp_commit_opened:
    ARM_CALL program_make_stage
    ARM_ADDR x0, registry_temp_payload
    ARM_IMM x1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, program_io_error
    mov x21, x9
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_candidate
    mov x2, #493
    ARM_CALL program_copy_into_stage
    mov x22, x9
    mov x0, x21
    ARM_CALL arm_close
    cbnz x22, program_io_error
    P_LOAD x10, program_upgrade
    cbz x10, .Lp_commit_new_row
    P_LOAD x0, program_current_fd
    mov x1, #0
    mov x2, #0
    ARM_CALL arm_lseek
    tbnz x9, #63, program_io_error
    P_LOAD x21, program_current_fd
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_previous
    P_LOAD x10, program_current_mode
    and x2, x10, #1023
    ARM_CALL program_copy_into_stage
    cbnz x9, program_io_error
.Lp_commit_new_row:
    ARM_ADDR x20, program_new_row
    ldp x10, x11, [x19]
    stp x10, x11, [x20]
    ldr x10, [x19, #16]
    str x10, [x20, #16]
    ldr x10, [x19, #32]
    str x10, [x20, #24]
    ldr x10, [x19, #48]
    str x10, [x20, #32]
    ARM_ADDR x10, program_path
    str x10, [x20, #40]
    P_BYTE w10, registry_local_index
    cbz w10, .Lp_commit_https
    ARM_ADDR x10, program_local
    b .Lp_commit_origin_set
.Lp_commit_https:
    P_LOAD x10, registry_url
.Lp_commit_origin_set:
    str x10, [x20, #48]
    ARM_CALL program_write_state
    P_LOAD x10, program_upgrade
    cbz x10, .Lp_commit_absent
    ARM_CALL program_recheck_destination
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_candidate
    P_LOAD x2, program_dest_fd
    P_LOAD x6, program_dest_name
    ARM_CALL arm_renameat
    b .Lp_commit_payload_result
.Lp_commit_absent:
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_candidate
    P_LOAD x2, program_dest_fd
    P_LOAD x6, program_dest_name
    mov x4, #1
    ARM_CALL arm_renameat2
.Lp_commit_payload_result:
    tbnz x9, #63, program_destination_exists
    P_SET 1, program_mutated
    ARM_CALL program_commit_state
    tbnz x9, #63, .Lp_commit_rollback
    P_SET 0, program_mutated
    ARM_ADDR x10, program_path
    P_STORE x10, registry_output
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.Lp_commit_rollback:
    P_LOAD x10, program_upgrade
    cbz x10, .Lp_commit_rollback_install
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_previous
    P_LOAD x2, program_dest_fd
    P_LOAD x6, program_dest_name
    ARM_CALL arm_renameat
    b .Lp_commit_rollback_result
.Lp_commit_rollback_install:
    P_LOAD x0, program_dest_fd
    P_LOAD x1, program_dest_name
    mov x2, #0
    ARM_CALL arm_unlinkat
.Lp_commit_rollback_result:
    tbnz x9, #63, program_recovery_error
    P_SET 0, program_mutated
    b program_io_error

/* x1=nonempty relative/absolute output <=4095. Produces absolute program_path
 * without resolving symlinks. The descriptor walk rejects '.'/'..' and empty
 * components. Buffers: cwd/path 4096 each. Stack: two saved registers. */
program_absolute_path:
    ARM_SAVE x19
    ARM_SAVE x20
    mov x19, x1
    mov x0, x1
    ARM_CALL strlen
    mov x20, x9
    ldrb w10, [x19]
    cmp w10, #47
    b.eq .Lp_absolute_copy
    ARM_ADDR x0, program_cwd
    mov x1, #4096
    ARM_CALL arm_getcwd
    tbnz x9, #63, program_path_error
    ARM_ADDR x0, program_cwd
    ARM_CALL strlen
    add x10, x9, x20
    add x10, x10, #1
    cmp x10, #4095
    b.hi program_path_error
    ARM_ADDR x0, program_path
    ARM_ADDR x1, program_cwd
    ARM_CALL copy_string
    mov w10, #47
    strb w10, [x9], #1
    mov x0, x9
    mov x1, x19
    ARM_CALL copy_string
    b .Lp_absolute_done
.Lp_absolute_copy:
    cmp x20, #4095
    b.hi program_path_error
    ARM_ADDR x0, program_path
    mov x1, x19
    ARM_CALL copy_string
.Lp_absolute_done:
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=create state directories (0/1). HOME must be absolute <=3800 bytes.
 * Opens protected directory ancestors and acquires a nonblocking exclusive
 * directory flock. Missing state in read-only mode is an empty inventory.
 * Stack: two saved registers. All held descriptors belong to this process. */
program_open_state:
    ARM_SAVE x19
    ARM_SAVE x20
    mov x20, x0
    ARM_CALL arm_getuid
    P_STORE x9, program_uid
    mov x19, x9
    ARM_CALL arm_geteuid
    cmp x9, x19
    b.ne program_path_error
    P_LOAD x19, envp
.Lp_home_loop:
    ldr x0, [x19], #8
    cbz x0, program_path_error
    ldrb w10, [x0]
    cmp w10, #72
    b.ne .Lp_home_loop
    ldrb w10, [x0, #1]
    cmp w10, #79
    b.ne .Lp_home_loop
    ldrb w10, [x0, #2]
    cmp w10, #77
    b.ne .Lp_home_loop
    ldrb w10, [x0, #3]
    cmp w10, #69
    b.ne .Lp_home_loop
    ldrb w10, [x0, #4]
    cmp w10, #61
    b.ne .Lp_home_loop
    add x19, x0, #5
    ldrb w10, [x19]
    cmp w10, #47
    b.ne program_path_error
    mov x0, x19
    ARM_CALL strlen
    cmp x9, #3800
    b.hi program_path_error
    cmp x9, #1
    b.ls program_path_error
    P_STORE x9, program_home_length
    P_STORE x19, program_home
    ARM_ADDR x0, program_state_path
    mov x1, x19
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, program_state_suffix
    ARM_CALL copy_string
    ARM_ADDR x0, program_state_path
    mov x1, x20
    ARM_CALL program_walk_parent
    cmn x9, #2
    b.eq .Lp_state_missing
    tbnz x9, #63, program_path_error
    P_STORE x9, program_state_fd
    mov x0, x9
    mov x1, #6
    ARM_CALL arm_flock
    tbnz x9, #63, program_busy_error
.Lp_state_missing:
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=absolute mutable path <=4095, x1=allow mkdir below HOME (0/1).
 * x9=owned parent FD or negative errno; program_basename borrows final name.
 * Rejects symlinks, traversal, ASCII controls, invalid UTF-8 and >255-byte names.
 * Ancestors must be root/user owned and deny group/other writes. HOME and
 * descendants must belong to this UID. Exact root-owned sticky /tmp and
 * /private/tmp are exceptions above HOME; their child must be user-owned.
 * Uses descriptor-relative opens and restores temporary NUL separators.
 * Stack: six saved registers and 16 local bytes; stat scratch is 128 bytes. */
program_walk_parent:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    str xzr, [sp]
    mov x19, x0
    mov x20, x1
    mov x0, x19
    ARM_CALL program_valid_absolute_path
    cbz w9, .Lp_walk_bad_initial
    ldrb w10, [x19]
    cmp w10, #47
    b.ne .Lp_walk_bad_initial
    ARM_ADDR x0, program_root
    ARM_IMM x1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, .Lp_walk_return
    mov x21, x9
    mov x0, x21
    ARM_ADDR x1, program_walk_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, .Lp_walk_bad
    ARM_ADDR x16, program_walk_stat
    ldr w10, [x16, #ARM_STAT_MODE]
    mov w14, #18
    tst w10, w14
    b.ne .Lp_walk_bad
    ldr w10, [x16, #ARM_STAT_UID]
    cbz w10, .Lp_walk_root_owned
    P_LOAD x11, program_uid
    cmp w10, w11
    b.ne .Lp_walk_bad
.Lp_walk_root_owned:
    add x22, x19, #1
    /* Only matching HOME descendants inherit the user-only ownership rule. */
    P_LOAD x1, program_home
    mov x2, x19
.Lp_walk_home_prefix:
    ldrb w10, [x1], #1
    cbz w10, .Lp_walk_home_prefix_end
    ldrb w11, [x2], #1
    cmp w10, w11
    b.ne .Lp_walk_outside_home
    b .Lp_walk_home_prefix
.Lp_walk_home_prefix_end:
    ldrb w10, [x2]
    cmp w10, #47
    b.ne .Lp_walk_outside_home
    P_LOAD x24, program_home_length
    b .Lp_walk_component
.Lp_walk_outside_home:
    mov x24, #-1
.Lp_walk_component:
    mov x23, x22
.Lp_walk_scan:
    ldrb w10, [x23]
    cbz w10, .Lp_walk_final
    cmp w10, #47
    b.eq .Lp_walk_separator
    cmp w10, #32
    b.lo .Lp_walk_bad
    cmp w10, #127
    b.eq .Lp_walk_bad
    sub x11, x23, x22
    cmp x11, #254
    b.hi .Lp_walk_bad
    add x23, x23, #1
    b .Lp_walk_scan
.Lp_walk_separator:
    cmp x23, x22
    b.eq .Lp_walk_bad
    strb wzr, [x23]
    ARM_CALL program_component_valid
    cbz w9, .Lp_walk_bad_restore
    mov x0, x21
    mov x1, x22
    ARM_IMM x2, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov x6, #0
    ARM_CALL arm_openat
    cmn x9, #2
    b.ne .Lp_walk_open_result
    cbz x20, .Lp_walk_open_result
    sub x10, x22, x19
    cmp x10, x24
    b.lo .Lp_walk_open_result
    mov x0, x21
    mov x1, x22
    mov x2, #448
    ARM_CALL arm_mkdirat
    cbnz x9, .Lp_walk_open_result
    mov x0, x21
    mov x1, x22
    ARM_IMM x2, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov x6, #0
    ARM_CALL arm_openat
.Lp_walk_open_result:
    mov x10, x9
    mov w11, #47
    strb w11, [x23]
    tbnz x10, #63, .Lp_walk_close_error
    mov x0, x21
    mov x21, x10
    ARM_CALL arm_close
    mov x0, x21
    ARM_ADDR x1, program_walk_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, .Lp_walk_bad
    /* A directory identity, rather than its spelling, reserves state on
     * case-insensitive filesystems too. Refuse its entire descendant tree. */
    P_LOAD x0, program_state_fd
    tbnz x0, #63, .Lp_walk_not_state
    ARM_ADDR x1, program_check_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, .Lp_walk_bad
    ARM_ADDR x0, program_walk_stat
    ARM_ADDR x1, program_check_stat
    ldr x10, [x0, #ARM_STAT_DEVICE]
    ldr x11, [x1, #ARM_STAT_DEVICE]
    cmp x10, x11
    b.ne .Lp_walk_not_state
    ldr x10, [x0, #ARM_STAT_INODE]
    ldr x11, [x1, #ARM_STAT_INODE]
    cmp x10, x11
    b.eq .Lp_walk_bad
.Lp_walk_not_state:
    ARM_ADDR x16, program_walk_stat
    ldr w10, [x16, #ARM_STAT_MODE]
    and w11, w10, #61440
    cmp w11, #16384
    b.ne .Lp_walk_bad
    ldr w11, [x16, #ARM_STAT_UID]
    P_LOAD x12, program_uid
    sub x13, x23, x19
    cmp x13, x24
    b.hs .Lp_walk_user
    ldr x14, [sp]
    cbnz x14, .Lp_walk_user
    cbz w11, .Lp_walk_mode
.Lp_walk_user:
    cmp w11, w12
    b.ne .Lp_walk_bad
.Lp_walk_mode:
    mov w14, #18
    tst w10, w14
    b.eq .Lp_walk_protected
    cbnz w11, .Lp_walk_bad
    tst w10, #512
    b.eq .Lp_walk_bad
    cmp x13, x24
    b.hs .Lp_walk_bad
    cmp x13, #4
    b.eq .Lp_walk_tmp4
    cmp x13, #12
    b.ne .Lp_walk_bad
    ARM_ADDR x1, program_private_tmp
    b .Lp_walk_check_tmp
.Lp_walk_tmp4:
    ARM_ADDR x1, program_tmp
.Lp_walk_check_tmp:
    mov w10, #0
    strb w10, [x23]
    mov x0, x19
    ARM_CALL streq
    mov w10, #47
    strb w10, [x23]
    cbz w9, .Lp_walk_bad
    mov x10, #1
    str x10, [sp]
    b .Lp_walk_next
.Lp_walk_protected:
    str xzr, [sp]
.Lp_walk_next:
    add x22, x23, #1
    b .Lp_walk_component
.Lp_walk_final:
    cmp x23, x22
    b.eq .Lp_walk_bad
    ARM_CALL program_component_valid
    cbz w9, .Lp_walk_bad
    P_STORE x22, program_basename
    mov x9, x21
    b .Lp_walk_return
.Lp_walk_bad_restore:
    mov w10, #47
    strb w10, [x23]
.Lp_walk_bad:
    mov x10, #-13
.Lp_walk_close_error:
    str x10, [sp, #8]
    mov x0, x21
    ARM_CALL arm_close
    ldr x9, [sp, #8]
    b .Lp_walk_return
.Lp_walk_bad_initial:
    mov x9, #-22
.Lp_walk_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x22=NUL component; w9=1 except '.'/'..'; no stack or memory changes. */
program_component_valid:
    ldrb w10, [x22]
    cmp w10, #46
    b.ne .Lp_component_good
    ldrb w10, [x22, #1]
    cbz w10, .Lp_component_bad
    cmp w10, #46
    b.ne .Lp_component_good
    ldrb w10, [x22, #2]
    cbz w10, .Lp_component_bad
.Lp_component_good:
    mov w9, #1
    ret
.Lp_component_bad:
    mov w9, #0
    ret

/* Opens the constructed destination's protected parent, retains its FD and
 * basename, and reserves HOME/.local/bin/asm for the provenance updater.
 * No directory is created. Stack: one saved register. */
program_open_destination:
    ARM_SAVE x19
    ARM_ADDR x0, program_reserved_path
    P_LOAD x1, program_home
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, program_reserved_suffix
    ARM_CALL copy_string
    ARM_ADDR x0, program_path
    ARM_ADDR x1, program_reserved_path
    ARM_CALL streq
    cbnz w9, program_reserved_error
    ARM_ADDR x0, program_state_path
    ARM_CALL strlen
    sub x2, x9, #13 /* installed.tsv */
    ARM_ADDR x0, program_path
    ARM_ADDR x1, program_state_path
.Lp_destination_internal:
    cbz x2, program_internal_error
    ldrb w10, [x0], #1
    ldrb w11, [x1], #1
    cmp w10, w11
    b.ne .Lp_destination_external
    sub x2, x2, #1
    b .Lp_destination_internal
.Lp_destination_external:
    ARM_ADDR x0, program_path
    mov x1, #0
    ARM_CALL program_walk_parent
    tbnz x9, #63, program_path_error
    P_STORE x9, program_dest_fd
    P_LOAD x10, program_basename
    P_STORE x10, program_dest_name
    ARM_CALL program_check_cli_destination
    P_BYTE w10, registry_has_workspace
    cbz w10, .Lp_destination_workspace_safe
    ARM_ADDR x0, registry_temp_dir
    ARM_IMM x1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, program_path_error
    mov x19, x9
    mov x0, x19
    ARM_ADDR x1, program_walk_stat
    ARM_CALL arm_fstat
    P_STORE x9, program_internal_stat_result
    mov x0, x19
    ARM_CALL arm_close
    P_LOAD x9, program_internal_stat_result
    tbnz x9, #63, program_path_error
    P_LOAD x0, program_dest_fd
    ARM_ADDR x1, program_check_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, program_path_error
    ARM_ADDR x0, program_walk_stat
    ARM_ADDR x1, program_check_stat
    ldr x10, [x0, #ARM_STAT_DEVICE]
    ldr x11, [x1, #ARM_STAT_DEVICE]
    cmp x10, x11
    b.ne .Lp_destination_workspace_safe
    ldr x10, [x0, #ARM_STAT_INODE]
    ldr x11, [x1, #ARM_STAT_INODE]
    cmp x10, x11
    b.eq program_internal_error
.Lp_destination_workspace_safe:
    ARM_RESTORE x19
    ret

/* Reserve case aliases of the CLI basename by the actual bin directory
 * identity. Never assume that path spelling identifies a filesystem entry.
 * Input: destination FD/name and constructed reserved_path. Stack: two saves.
 * A missing default bin directory cannot alias an existing destination parent. */
program_check_cli_destination:
    ARM_SAVE x19
    ARM_SAVE x20
    P_LOAD x0, program_dest_name
    ldrb w10, [x0]
    orr w10, w10, #32
    cmp w10, #97
    b.ne .Lp_cli_destination_safe
    ldrb w10, [x0, #1]
    orr w10, w10, #32
    cmp w10, #115
    b.ne .Lp_cli_destination_safe
    ldrb w10, [x0, #2]
    orr w10, w10, #32
    cmp w10, #109
    b.ne .Lp_cli_destination_safe
    ldrb w10, [x0, #3]
    cbnz w10, .Lp_cli_destination_safe
    ARM_ADDR x0, program_reserved_path
    mov x1, #0
    ARM_CALL program_walk_parent
    tbnz x9, #63, .Lp_cli_destination_safe
    mov x19, x9
    mov x0, x19
    ARM_ADDR x1, program_walk_stat
    ARM_CALL arm_fstat
    mov x20, x9
    mov x0, x19
    ARM_CALL arm_close
    tbnz x20, #63, program_path_error
    P_LOAD x0, program_dest_fd
    ARM_ADDR x1, program_check_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, program_path_error
    ARM_ADDR x0, program_walk_stat
    ARM_ADDR x1, program_check_stat
    ldr x10, [x0, #ARM_STAT_DEVICE]
    ldr x11, [x1, #ARM_STAT_DEVICE]
    cmp x10, x11
    b.ne .Lp_cli_destination_safe
    ldr x10, [x0, #ARM_STAT_INODE]
    ldr x11, [x1, #ARM_STAT_INODE]
    cmp x10, x11
    b.eq program_reserved_error
.Lp_cli_destination_safe:
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Read a regular, owned, protected single-link inventory. Empty/missing files
 * are distinct: missing means no programs; an empty file is malformed.
 * All bytes are bounded before parsing; no results print until validation.
 * Stack: two saved registers. program_input has limit+1 byte capacity. */
program_read_state:
    ARM_SAVE x19
    ARM_SAVE x20
    P_SET 0, program_count
    P_LOAD x0, program_state_fd
    tbnz x0, #63, .Lp_read_done
    ARM_ADDR x1, program_state_name
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov x6, #0
    ARM_CALL arm_openat
    cmn x9, #2
    b.eq .Lp_read_done
    tbnz x9, #63, program_state_error
    mov x19, x9
    mov x0, x19
    ARM_ADDR x1, program_check_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, .Lp_read_bad
    ARM_ADDR x0, program_check_stat
    ARM_CALL program_regular_stat
    cbz w9, .Lp_read_bad
    ARM_ADDR x16, program_check_stat
    ldr x10, [x16, #ARM_STAT_SIZE]
    ARM_IMM x11, PROGRAM_STATE_LIMIT
    cmp x10, x11
    b.hi .Lp_read_bad
    mov x20, #0
.Lp_read_loop:
    mov x0, x19
    ARM_ADDR x1, program_input
    add x1, x1, x20
    ARM_IMM x2, PROGRAM_STATE_LIMIT + 1
    sub x2, x2, x20
    ARM_CALL arm_read
    cmn x9, #4
    b.eq .Lp_read_loop
    tbnz x9, #63, .Lp_read_bad
    cbz x9, .Lp_read_eof
    add x20, x20, x9
    ARM_IMM x10, PROGRAM_STATE_LIMIT
    cmp x20, x10
    b.hi .Lp_read_bad
    b .Lp_read_loop
.Lp_read_eof:
    mov x0, x19
    ARM_CALL arm_close
    P_STORE x20, program_input_size
    ARM_CALL program_parse_state
.Lp_read_done:
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.Lp_read_bad:
    mov x0, x19
    ARM_CALL arm_close
    b program_state_error

/* Parses seven TSV fields per record; metadata is printable ASCII, <=128 records. Borrowed
 * pointers have process lifetime in program_input. Every field is validated,
 * including duplicates, before any mutation. Stack: six saved registers. */
program_parse_state:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x19, program_input
    P_LOAD x20, program_input_size
    add x20, x20, x19
    ARM_ADDR x21, program_header
.Lp_parse_header:
    ldrb w10, [x21], #1
    cbz w10, .Lp_parse_row
    cmp x19, x20
    b.hs program_state_error
    ldrb w11, [x19], #1
    cmp w10, w11
    b.ne program_state_error
    b .Lp_parse_header
.Lp_parse_row:
    cmp x19, x20
    b.eq .Lp_parse_done
    P_LOAD x23, program_count
    cmp x23, #PROGRAM_LIMIT
    b.hs program_state_error
    ARM_ADDR x21, program_rows
    add x21, x21, x23, lsl #6
    str x19, [x21]
    mov x22, #0
    mov x24, x19
.Lp_parse_char:
    cmp x19, x20
    b.hs program_state_error
    ldrb w10, [x19]
    cmp w10, #9
    b.eq .Lp_parse_tab
    cmp w10, #10
    b.eq .Lp_parse_newline
    cmp w10, #32
    b.lo program_state_error
    cmp w10, #127
    b.eq program_state_error
    b.lo .Lp_parse_ascii
    cmp x22, #5
    b.ne program_state_error
.Lp_parse_ascii:
    sub x11, x19, x24
    cmp x11, #4094
    b.hi program_state_error
    add x19, x19, #1
    b .Lp_parse_char
.Lp_parse_tab:
    cmp x19, x24
    b.eq program_state_error
    cmp x22, #6
    b.hs program_state_error
    strb wzr, [x19], #1
    add x22, x22, #1
    str x19, [x21, x22, lsl #3]
    mov x24, x19
    b .Lp_parse_char
.Lp_parse_newline:
    cmp x22, #6
    b.ne program_state_error
    cmp x19, x24
    b.eq program_state_error
    strb wzr, [x19], #1
    mov x0, x21
    ARM_CALL program_validate_row
    add x23, x23, #1
    P_STORE x23, program_count
    b .Lp_parse_row
.Lp_parse_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=seven-pointer row; checks canonical identities/size/hash, absolute path,
 * HTTPS/local origin, and uniqueness against earlier rows. Stack: 3 saves. */
program_validate_row:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    ldr x0, [x19]
    ARM_CALL registry_valid_package
    cbz w9, program_state_error
    ldr x0, [x19, #8]
    ARM_CALL registry_valid_version
    cbz w9, program_state_error
    ldr x0, [x19, #16]
    ARM_CALL registry_valid_target
    cbz w9, program_state_error
    ldr x0, [x19, #24]
    ARM_CALL strlen
    cmp x9, #64
    b.ne program_state_error
    ldr x0, [x19, #24]
    mov x2, #0
.Lp_validate_hash:
    ldrb w10, [x0, x2]
    cmp w10, #48
    b.lo program_state_error
    cmp w10, #57
    b.ls .Lp_validate_hash_next
    cmp w10, #97
    b.lo program_state_error
    cmp w10, #102
    b.hi program_state_error
.Lp_validate_hash_next:
    add x2, x2, #1
    cmp x2, #64
    b.lo .Lp_validate_hash
    ldrb w10, [x0, #64]
    cbnz w10, program_state_error
    ldr x0, [x19, #32]
    ARM_CALL registry_size_value
    cbz x9, program_state_error
    ldr x0, [x19, #40]
    ARM_CALL program_valid_absolute_path
    cbz w9, program_state_error
    ldr x0, [x19, #40]
    ldrb w10, [x0]
    cmp w10, #47
    b.ne program_state_error
    ldr x0, [x19, #48]
    ARM_ADDR x1, program_local
    ARM_CALL streq
    cbnz w9, .Lp_validate_unique
    ldr x0, [x19, #48]
    ARM_CALL registry_https_url
    cbz w9, program_state_error
.Lp_validate_unique:
    ARM_ADDR x20, program_rows
.Lp_validate_duplicate:
    cmp x20, x19
    b.eq .Lp_validate_done
    ldr x0, [x19]
    ldr x1, [x20]
    ARM_CALL streq
    cbnz w9, program_state_error
    ldr x0, [x19, #40]
    ldr x1, [x20, #40]
    ARM_CALL streq
    cbnz w9, program_state_error
    add x20, x20, #64
    b .Lp_validate_duplicate
.Lp_validate_done:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=canonical package; x9=borrowed matching row or zero. Stack: 3 saves. */
program_find:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    ARM_ADDR x20, program_rows
    P_LOAD x21, program_count
.Lp_find_loop:
    cbz x21, .Lp_find_absent
    mov x0, x19
    ldr x1, [x20]
    ARM_CALL streq
    cbnz w9, .Lp_find_found
    add x20, x20, #64
    sub x21, x21, #1
    b .Lp_find_loop
.Lp_find_absent:
    mov x9, #0
    b .Lp_find_done
.Lp_find_found:
    mov x9, x20
.Lp_find_done:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=NUL-terminated text <=4095 bytes; w9=1 for canonical UTF-8. Rejects
 * overlong encodings, surrogate code points, and values above U+10FFFF.
 * No writes or stack use. Scratch x0-x3,x10-x12; stops at the first NUL. */
program_valid_utf8:
.Lp_utf8_next:
    ldrb w10, [x0], #1
    cbz w10, .Lp_utf8_good
    cmp w10, #128
    b.lo .Lp_utf8_next
    cmp w10, #194
    b.lo .Lp_utf8_bad
    cmp w10, #224
    b.lo .Lp_utf8_one
    cmp w10, #240
    b.lo .Lp_utf8_three
    cmp w10, #245
    b.hs .Lp_utf8_bad
    ldrb w11, [x0], #1
    cmp w11, #128
    b.lo .Lp_utf8_bad
    cmp w11, #192
    b.hs .Lp_utf8_bad
    cmp w10, #240
    b.ne .Lp_utf8_four_upper
    cmp w11, #144
    b.lo .Lp_utf8_bad
.Lp_utf8_four_upper:
    cmp w10, #244
    b.ne .Lp_utf8_four_tail
    cmp w11, #144
    b.hs .Lp_utf8_bad
.Lp_utf8_four_tail:
    mov w2, #2
    b .Lp_utf8_tail
.Lp_utf8_three:
    ldrb w11, [x0], #1
    cmp w11, #128
    b.lo .Lp_utf8_bad
    cmp w11, #192
    b.hs .Lp_utf8_bad
    cmp w10, #224
    b.ne .Lp_utf8_three_upper
    cmp w11, #160
    b.lo .Lp_utf8_bad
.Lp_utf8_three_upper:
    cmp w10, #237
    b.ne .Lp_utf8_one
    cmp w11, #160
    b.hs .Lp_utf8_bad
.Lp_utf8_one:
    mov w2, #1
.Lp_utf8_tail:
    ldrb w11, [x0], #1
    cmp w11, #128
    b.lo .Lp_utf8_bad
    cmp w11, #192
    b.hs .Lp_utf8_bad
    subs w2, w2, #1
    b.ne .Lp_utf8_tail
    b .Lp_utf8_next
.Lp_utf8_good:
    mov w9, #1
    ret
.Lp_utf8_bad:
    mov w9, #0
    ret

/* x0=NUL path <=4095 bytes; w9=1 for an absolute canonical UTF-8 file path.
 * Reject controls, empty components, '.'/'..', and names above 255 bytes.
 * Pure validation does not open files, so listing detects malformed receipts
 * even when destinations are absent. Stack: one saved register. */
program_valid_absolute_path:
    ARM_SAVE x19
    mov x19, x0
    ARM_CALL program_valid_utf8
    cbz w9, .Lp_path_invalid
    ldrb w10, [x19]
    cmp w10, #47
    b.ne .Lp_path_invalid
    add x1, x19, #1
    mov x2, x1
.Lp_path_scan:
    ldrb w10, [x2]
    cbz w10, .Lp_path_component
    cmp w10, #47
    b.eq .Lp_path_component
    cmp w10, #32
    b.lo .Lp_path_invalid
    cmp w10, #127
    b.eq .Lp_path_invalid
    add x2, x2, #1
    b .Lp_path_scan
.Lp_path_component:
    sub x3, x2, x1
    cbz x3, .Lp_path_invalid
    cmp x3, #255
    b.hi .Lp_path_invalid
    cmp x3, #2
    b.hi .Lp_path_component_valid
    ldrb w11, [x1]
    cmp w11, #46
    b.ne .Lp_path_component_valid
    cmp x3, #1
    b.eq .Lp_path_invalid
    ldrb w11, [x1, #1]
    cmp w11, #46
    b.eq .Lp_path_invalid
.Lp_path_component_valid:
    cbz w10, .Lp_path_valid
    add x1, x2, #1
    mov x2, x1
    b .Lp_path_scan
.Lp_path_invalid:
    mov w9, #0
    ARM_RESTORE x19
    ret
.Lp_path_valid:
    mov w9, #1
    ARM_RESTORE x19
    ret

/* A missing file still belongs to its installation record. Reject a new
 * package at that path instead of generating an ambiguous inventory.
 * Input program_path, parsed rows/count. Stack: two saved registers. */
program_check_new_path:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_ADDR x19, program_rows
    P_LOAD x20, program_count
.Lp_new_path_loop:
    cbz x20, .Lp_new_path_done
    ARM_ADDR x0, program_path
    ldr x1, [x19, #40]
    ARM_CALL streq
    cbnz w9, program_destination_exists
    add x19, x19, #64
    sub x20, x20, #1
    b .Lp_new_path_loop
.Lp_new_path_done:
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=normalized stat; w9=1 for protected single-link user regular files.
 * No stack. File execute permission is checked separately for destinations. */
program_regular_stat:
    ldr w10, [x0, #ARM_STAT_MODE]
    and w11, w10, #61440
    cmp w11, #32768
    b.ne .Lp_regular_bad
    mov w11, #3090
    tst w10, w11
    b.ne .Lp_regular_bad
    ldr w11, [x0, #ARM_STAT_LINKS]
    cmp w11, #1
    b.ne .Lp_regular_bad
    ldr w11, [x0, #ARM_STAT_UID]
    P_LOAD x12, program_uid
    cmp w11, w12
    b.ne .Lp_regular_bad
    mov w9, #1
    ret
.Lp_regular_bad:
    mov w9, #0
    ret

/* Opens current executable by held parent FD. Copies it to the private registry
 * payload for hashing through the mature fixed-argv adapter, then removes the
 * snapshot. Keeps current_fd and original stat for backup/recheck. Requires
 * size/hash match; never executes the program. Stack: four saved registers. */
program_check_existing:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    P_LOAD x19, program_found
    ldr x0, [x19, #16]
    ARM_ADDR x1, registry_host
    ARM_CALL streq
    cbz w9, program_changed_file
    P_LOAD x0, program_dest_fd
    P_LOAD x1, program_dest_name
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov x6, #0
    ARM_CALL arm_openat
    tbnz x9, #63, program_changed_file
    mov x21, x9
    P_STORE x9, program_current_fd
    mov x0, x21
    ARM_ADDR x1, program_current_stat
    ARM_CALL arm_fstat
    tbnz x9, #63, program_changed_file
    ARM_ADDR x0, program_current_stat
    ARM_CALL program_regular_stat
    cbz w9, program_changed_file
    ARM_ADDR x16, program_current_stat
    ldr w10, [x16, #ARM_STAT_MODE]
    tst w10, #64
    b.eq program_changed_file
    P_STORE x10, program_current_mode
    ldr x0, [x19, #32]
    ARM_CALL registry_size_value
    ARM_ADDR x16, program_current_stat
    ldr x10, [x16, #ARM_STAT_SIZE]
    cmp x10, x9
    b.ne program_changed_file
    ARM_CALL registry_workspace
    ARM_ADDR x0, registry_temp_payload
    ARM_IMM x1, O_NOFOLLOW + O_CLOEXEC + 193
    mov x2, #384
    ARM_CALL arm_open
    tbnz x9, #63, program_io_error
    mov x22, x9
    mov x0, x21
    mov x1, x22
    ARM_CALL program_copy_fds
    mov x20, x9
    mov x0, x22
    ARM_CALL arm_close
    cbnz x20, program_io_error
    ARM_CALL pub_hash_payload
    cbnz w9, program_changed_file
    ARM_ADDR x0, pub_hash_buffer
    ldr x1, [x19, #24]
    mov x2, #64
.Lp_existing_digest:
    ldrb w10, [x0], #1
    ldrb w11, [x1], #1
    cmp w10, w11
    b.ne program_changed_file
    subs x2, x2, #1
    b.ne .Lp_existing_digest
    ARM_ADDR x0, registry_temp_payload
    ARM_CALL arm_unlink
    tbnz x9, #63, program_io_error
    ARM_CALL program_recheck_destination
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Require unchanged destination identity/mode/size immediately before mutation.
 * Descriptor-relative nofollow stat. Stack: no local reservation. */
program_recheck_destination:
    P_LOAD x0, program_dest_fd
    P_LOAD x1, program_dest_name
    ARM_ADDR x2, program_check_stat
    mov x6, #256
    ARM_CALL arm_newfstatat
    tbnz x9, #63, program_changed_file
    ARM_ADDR x0, program_check_stat
    ARM_CALL program_regular_stat
    cbz w9, program_changed_file
    ARM_ADDR x0, program_current_stat
    ARM_ADDR x1, program_check_stat
    ldr x10, [x0, #ARM_STAT_DEVICE]
    ldr x11, [x1, #ARM_STAT_DEVICE]
    cmp x10, x11
    b.ne program_changed_file
    ldr x10, [x0, #ARM_STAT_INODE]
    ldr x11, [x1, #ARM_STAT_INODE]
    cmp x10, x11
    b.ne program_changed_file
    ldr x10, [x0, #ARM_STAT_SIZE]
    ldr x11, [x1, #ARM_STAT_SIZE]
    cmp x10, x11
    b.ne program_changed_file
    ldr w10, [x0, #ARM_STAT_MODE]
    ldr w11, [x1, #ARM_STAT_MODE]
    cmp w10, w11
    b.ne program_changed_file
    ret

/* x0=input FD, x1=output FD; x9=0/-1. Copies <=64MiB and retries EINTR and
 * short writes with write_all. Caller owns both FDs. Stack: four saves. */
program_copy_fds:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    mov x19, x0
    mov x20, x1
    mov x21, #0
.Lp_copy_read:
    mov x0, x19
    ARM_ADDR x1, registry_copy_buffer
    mov x2, #65536
    ARM_CALL arm_read
    cmn x9, #4
    b.eq .Lp_copy_read
    tbnz x9, #63, .Lp_copy_bad
    cbz x9, .Lp_copy_ok
    add x21, x21, x9
    ARM_IMM x10, 67108864
    cmp x21, x10
    b.hi .Lp_copy_bad
    mov x2, x9
    mov x0, x20
    ARM_ADDR x1, registry_copy_buffer
    ARM_CALL write_all
    tbnz x9, #63, .Lp_copy_bad
    b .Lp_copy_read
.Lp_copy_bad:
    mov x9, #-1
    b .Lp_copy_done
.Lp_copy_ok:
    mov x9, #0
.Lp_copy_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Exclusive stage lives in the destination's filesystem. Its predictable PID
 * name is safe because mkdirat must create it. Never reuses an existing path.
 * Stack: none beyond nested link frames. */
program_make_stage:
    ARM_ADDR x0, program_stage_name
    ARM_ADDR x1, program_stage_prefix
    ARM_CALL copy_string
    P_STORE x9, program_append
    ARM_CALL arm_getpid
    mov x0, x9
    ARM_ADDR x1, program_number + 31
    ARM_CALL unsigned_decimal
    mov x1, x9
    P_LOAD x0, program_append
    ARM_CALL copy_string
    P_LOAD x0, program_dest_fd
    ARM_ADDR x1, program_stage_name
    mov x2, #448
    ARM_CALL arm_mkdirat
    cbnz x9, program_io_error
    P_SET 1, program_stage_created
    P_LOAD x0, program_dest_fd
    ARM_ADDR x1, program_stage_name
    ARM_IMM x2, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov x6, #0
    ARM_CALL arm_openat
    tbnz x9, #63, program_io_error
    P_STORE x9, program_stage_fd
    ret

/* x0=stage directory FD, x1=fixed file name, x2=mode, x21=source FD.
 * x9=0/-1; copies, chmods and fsyncs an exclusive file. Stack: three saves.
 * Backup mode is retained, but rollback may create a different inode. */
program_copy_into_stage:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x22
    mov x20, x2
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC + 193
    mov x6, #384
    ARM_CALL arm_openat
    tbnz x9, #63, .Lp_stage_copy_bad
    mov x19, x9
    mov x0, x21
    mov x1, x19
    ARM_CALL program_copy_fds
    cbnz x9, .Lp_stage_copy_close_bad
    mov x0, x19
    mov x1, x20
    ARM_CALL arm_fchmod
    tbnz x9, #63, .Lp_stage_copy_close_bad
    mov x0, x19
    ARM_CALL arm_fsync
    tbnz x9, #63, .Lp_stage_copy_close_bad
    mov x0, x19
    ARM_CALL arm_close
    tbnz x9, #63, .Lp_stage_copy_bad
    mov x9, #0
    b .Lp_stage_copy_done
.Lp_stage_copy_close_bad:
    mov x0, x19
    ARM_CALL arm_close
.Lp_stage_copy_bad:
    mov x9, #-1
.Lp_stage_copy_done:
    ARM_RESTORE x22
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Serialize a complete replacement inventory to an exclusive temporary file
 * under the locked state FD. Removal skips found; upgrade replaces found;
 * install appends new_row. File fsync precedes any executable mutation.
 * Stack: four saved registers. Total output remains <=1 MiB. */
program_write_state:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x0, program_state_temp
    ARM_ADDR x1, program_state_prefix
    ARM_CALL copy_string
    P_STORE x9, program_append
    ARM_CALL arm_getpid
    mov x0, x9
    ARM_ADDR x1, program_number + 31
    ARM_CALL unsigned_decimal
    mov x1, x9
    P_LOAD x0, program_append
    ARM_CALL copy_string
    P_LOAD x0, program_state_fd
    ARM_ADDR x1, program_state_temp
    ARM_IMM x2, O_NOFOLLOW + O_CLOEXEC + 193
    mov x6, #384
    ARM_CALL arm_openat
    tbnz x9, #63, program_io_error
    mov x19, x9
    P_STORE x9, program_temp_fd
    P_SET 1, program_state_created
    P_SET 0, program_written
    ARM_ADDR x1, program_header
    ARM_CALL program_write_piece
    ARM_ADDR x20, program_rows
    P_LOAD x21, program_count
.Lp_write_row:
    cbz x21, .Lp_write_append
    P_LOAD x10, program_found
    cmp x20, x10
    b.ne .Lp_write_old
    P_LOAD x10, program_remove
    cbnz x10, .Lp_write_next
    ARM_ADDR x0, program_new_row
    b .Lp_write_emit
.Lp_write_old:
    mov x0, x20
.Lp_write_emit:
    ARM_CALL program_write_row
.Lp_write_next:
    add x20, x20, #64
    sub x21, x21, #1
    b .Lp_write_row
.Lp_write_append:
    P_LOAD x10, program_found
    cbnz x10, .Lp_write_sync
    ARM_ADDR x0, program_new_row
    ARM_CALL program_write_row
.Lp_write_sync:
    mov x0, x19
    ARM_CALL arm_fsync
    tbnz x9, #63, program_io_error
    mov x0, x19
    ARM_CALL arm_close
    P_SET -1, program_temp_fd
    tbnz x9, #63, program_io_error
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
/* x0=seven-pointer row; x19=output FD. Stack: two saves. */
program_write_row:
    ARM_SAVE x20
    ARM_SAVE x21
    mov x20, x0
    mov x21, #0
.Lp_write_field:
    ldr x1, [x20, x21, lsl #3]
    ARM_CALL program_write_piece
    add x21, x21, #1
    cmp x21, #7
    b.eq .Lp_write_row_end
    ARM_ADDR x1, registry_tab
    ARM_CALL program_write_piece
    b .Lp_write_field
.Lp_write_row_end:
    ARM_ADDR x1, registry_newline
    ARM_CALL program_write_piece
    ARM_RESTORE x21
    ARM_RESTORE x20
    ret
/* x1=NUL text, x19=FD. Bounds cumulative bytes; stack: one save. */
program_write_piece:
    ARM_SAVE x20
    mov x20, x1
    mov x0, x1
    ARM_CALL strlen
    P_LOAD x10, program_written
    add x10, x10, x9
    ARM_IMM x11, PROGRAM_STATE_LIMIT
    cmp x10, x11
    b.hi program_state_error
    P_STORE x10, program_written
    mov x0, x19
    mov x1, x20
    ARM_CALL write_cstr
    tbnz x9, #63, program_io_error
    ARM_RESTORE x20
    ret
/* Final inventory replacement. x9=rename result; no fatal branch, so callers
 * can roll back their executable mutation before reporting any error. */
program_commit_state:
    P_LOAD x0, program_state_fd
    ARM_ADDR x1, program_state_temp
    mov x2, x0
    ARM_ADDR x6, program_state_name
    ARM_CALL arm_renameat
    tbnz x9, #63, .Lp_state_commit_done
    P_SET 0, program_state_created
.Lp_state_commit_done:
    ret

/* Stable native inventory output. Parse errors have already failed without
 * stdout. JSON encodes paths through the shared bounded encoder. Stack: 3 saves. */
program_list:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    P_BYTE w10, json_mode
    cbz w10, .Lp_list_text
    ARM_ADDR x0, program_list_prefix
    ARM_CALL out
    ARM_ADDR x19, program_rows
    P_LOAD x20, program_count
    mov x21, #0
.Lp_list_json_row:
    cbz x20, .Lp_list_json_done
    cbz x21, .Lp_list_json_first
    ARM_ADDR x0, registry_comma
    ARM_CALL out
.Lp_list_json_first:
    ARM_ADDR x0, program_json_package
    ARM_CALL out
    ldr x0, [x19]
    ARM_CALL registry_json_string
    ARM_ADDR x0, program_json_version
    ARM_CALL out
    ldr x0, [x19, #8]
    ARM_CALL registry_json_string
    ARM_ADDR x0, program_json_target
    ARM_CALL out
    ldr x0, [x19, #16]
    ARM_CALL registry_json_string
    ARM_ADDR x0, program_json_sha
    ARM_CALL out
    ldr x0, [x19, #24]
    ARM_CALL registry_json_string
    ARM_ADDR x0, program_json_bytes
    ARM_CALL out
    ldr x0, [x19, #32]
    ARM_CALL out
    ARM_ADDR x0, program_json_path
    ARM_CALL out
    ldr x0, [x19, #40]
    ARM_CALL registry_json_string
    ARM_ADDR x0, program_json_registry
    ARM_CALL out
    ldr x0, [x19, #48]
    ARM_CALL registry_json_string
    ARM_ADDR x0, registry_rbrace
    ARM_CALL out
    add x19, x19, #64
    sub x20, x20, #1
    mov x21, #1
    b .Lp_list_json_row
.Lp_list_json_done:
    ARM_ADDR x0, program_list_suffix
    ARM_CALL out
    b .Lp_list_done
.Lp_list_text:
    P_LOAD x20, program_count
    cbnz x20, .Lp_list_text_rows
    ARM_ADDR x0, program_empty_text
    ARM_CALL out
    b .Lp_list_done
.Lp_list_text_rows:
    ARM_ADDR x19, program_rows
.Lp_list_text_row:
    ldr x0, [x19]
    ARM_CALL out
    ARM_ADDR x0, program_at
    ARM_CALL out
    ldr x0, [x19, #8]
    ARM_CALL out
    ARM_ADDR x0, registry_tab
    ARM_CALL out
    ldr x0, [x19, #16]
    ARM_CALL out
    ARM_ADDR x0, registry_tab
    ARM_CALL out
    ldr x0, [x19, #40]
    ARM_CALL out
    ARM_ADDR x0, registry_newline
    ARM_CALL out
    add x19, x19, #64
    subs x20, x20, #1
    b.ne .Lp_list_text_row
.Lp_list_done:
    ARM_CALL registry_cleanup
    b exit_ok

/* Cleanup closes only owned descriptors and removes only invocation-owned
 * stage names. A failed rollback retains its backup directory for recovery.
 * Cleanup failure cannot replace an earlier error. Stack: one saved register. */
program_cleanup:
    ARM_SAVE x19
    P_LOAD x0, program_temp_fd
    tbnz x0, #63, .Lp_cleanup_temp_name
    ARM_CALL arm_close
    P_SET -1, program_temp_fd
.Lp_cleanup_temp_name:
    P_LOAD x10, program_state_created
    cbz x10, .Lp_cleanup_stage
    P_LOAD x0, program_state_fd
    ARM_ADDR x1, program_state_temp
    mov x2, #0
    ARM_CALL arm_unlinkat
    P_SET 0, program_state_created
.Lp_cleanup_stage:
    P_LOAD x10, program_keep_stage
    cbnz x10, .Lp_cleanup_close
    P_LOAD x0, program_stage_fd
    tbnz x0, #63, .Lp_cleanup_stage_dir
    ARM_ADDR x1, program_candidate
    mov x2, #0
    ARM_CALL arm_unlinkat
    P_LOAD x0, program_stage_fd
    ARM_ADDR x1, program_previous
    mov x2, #0
    ARM_CALL arm_unlinkat
.Lp_cleanup_stage_dir:
    P_LOAD x10, program_stage_created
    cbz x10, .Lp_cleanup_close
    P_LOAD x0, program_dest_fd
    ARM_ADDR x1, program_stage_name
    mov x2, #512
    ARM_CALL arm_unlinkat
    P_SET 0, program_stage_created
.Lp_cleanup_close:
    ARM_ADDR x19, program_fds
    mov x10, #4
    P_STORE x10, program_cleanup_count
.Lp_cleanup_fd:
    ldr x0, [x19]
    tbnz x0, #63, .Lp_cleanup_fd_next
    ARM_CALL arm_close
    mov x10, #-1
    str x10, [x19]
.Lp_cleanup_fd_next:
    add x19, x19, #8
    P_LOAD x10, program_cleanup_count
    subs x10, x10, #1
    P_STORE x10, program_cleanup_count
    b.ne .Lp_cleanup_fd
    ARM_RESTORE x19
    ret

program_help:
    ARM_ADDR x0, program_help_text
    ARM_CALL out
    b exit_ok
program_bad_args:
    ARM_ADDR x0, program_error_args
    mov x1, #2
    b registry_fail
program_path_error:
    ARM_ADDR x0, program_error_path
    b program_error
program_state_error:
    ARM_ADDR x0, program_error_state
    b program_error
program_busy_error:
    ARM_ADDR x0, program_error_busy
    b program_error
program_not_managed:
    ARM_ADDR x0, program_error_unmanaged
    b program_error
program_already_managed:
    ARM_ADDR x0, program_error_already
    b program_error
program_local_index_error:
    ARM_ADDR x0, program_error_local
    b program_error
program_origin_error:
    ARM_ADDR x0, program_error_origin
    b program_error
program_downgrade_error:
    ARM_ADDR x0, program_error_downgrade
    b program_error
program_changed_release:
    ARM_ADDR x0, program_error_release
    b program_error
program_changed_file:
    ARM_ADDR x0, program_error_changed
    b program_error
program_destination_exists:
    ARM_ADDR x0, program_error_exists
    b program_error
program_reserved_error:
    ARM_ADDR x0, program_error_reserved
    b program_error
program_internal_error:
    ARM_ADDR x0, program_error_internal
    b program_error
program_recovery_error:
    P_SET 1, program_keep_stage
    ARM_ADDR x0, program_error_recovery
    b program_error
program_io_error:
    ARM_ADDR x0, program_error_io
program_error:
    mov x1, #1
    b registry_fail

.section .rodata
program_header: .asciz "# asm-installed-v1\n"
program_state_suffix: .asciz "/.local/state/asm/installed.tsv"
program_state_name: .asciz "installed.tsv"
program_state_prefix: .asciz ".installed-"
program_stage_prefix: .asciz ".asm-program-"
program_reserved_suffix: .asciz "/.local/bin/asm"
program_candidate: .asciz "candidate"
program_previous: .asciz "previous"
program_local: .asciz "local"
program_root: .asciz "/"
program_tmp: .asciz "/tmp"
program_private_tmp: .asciz "/private/tmp"
program_at: .asciz "@"
program_ok_json: .asciz "{\"ok\":true}\n"
program_unchanged_json: .asciz "{\"ok\":true,\"unchanged\":true}\n"
program_list_prefix: .asciz "{\"installed\":["
program_list_suffix: .asciz "]}\n"
program_json_package: .asciz "{\"package\":"
program_json_version: .asciz ",\"version\":"
program_json_target: .asciz ",\"target\":"
program_json_sha: .asciz ",\"sha256\":"
program_json_bytes: .asciz ",\"bytes\":"
program_json_path: .asciz ",\"path\":"
program_json_registry: .asciz ",\"registry\":"
program_empty_text: .asciz "No installed programs.\n"
program_help_text: .asciz "Usage:\n  asm installed [--json]\n  asm upgrade owner/name[@version] [--index PATH | --registry HTTPS_URL] [--artifact PATH] [--json]\n  asm uninstall owner/name [--json]\nupdate and remove manage project source dependencies.\n"
program_error_args: .asciz "invalid installed-program arguments; use asm installed --help"
program_error_path: .asciz "program management requires protected user-owned paths; check HOME, directory ownership, permissions, and symlinks"
program_error_state: .asciz "installed.tsv is invalid or exceeds its limit; restore the inventory before changing programs"
program_error_busy: .asciz "another command holds the installed-program lock; wait for it to finish and try again"
program_error_unmanaged: .asciz "this package has no installation record; use asm install for a new destination"
program_error_already: .asciz "this package is already managed; use asm upgrade to change its installed version"
program_error_local: .asciz "this installation has a local index origin; supply its --index PATH to upgrade"
program_error_origin: .asciz "the registry differs from the installation record; use the recorded registry origin"
program_error_downgrade: .asciz "upgrade refuses an older version; select the installed version or a newer version"
program_error_release: .asciz "the installed version has different release bytes; restore the original registry record"
program_error_changed: .asciz "the installed file is missing or changed; restore its recorded bytes and protected permissions before continuing"
program_error_exists: .asciz "the destination exists or cannot be replaced; choose a new destination and check its directory permissions"
program_error_internal: .asciz "the destination is inside Asm installation state or its temporary workspace; choose another program destination"
program_error_reserved: .asciz "HOME/.local/bin/asm is reserved for the CLI updater; use asm self update"
program_error_recovery: .asciz "program rollback failed; preserve the .asm-program-PID directory beside the destination and its previous file for recovery"
program_error_io: .asciz "program management could not finish; check free space, directory permissions, and retained .asm-program-PID stages"

.section .data
.balign 8
program_fds:
program_state_fd: .quad -1
program_dest_fd: .quad -1
program_stage_fd: .quad -1
program_current_fd: .quad -1
program_temp_fd: .quad -1
.section .bss
.balign 8
program_upgrade: .skip 8
program_remove: .skip 8
program_arg: .skip 8
program_query: .skip 8
program_found: .skip 8
program_count: .skip 8
program_uid: .skip 8
program_home: .skip 8
program_home_length: .skip 8
program_basename: .skip 8
program_dest_name: .skip 8
program_input_size: .skip 8
program_current_mode: .skip 8
program_append: .skip 8
program_written: .skip 8
program_mutated: .skip 8
program_keep_stage: .skip 8
program_stage_created: .skip 8
program_state_created: .skip 8
program_cleanup_count: .skip 8
program_internal_stat_result: .skip 8
program_number: .skip 32
program_state_temp: .skip 64
program_stage_name: .skip 64
program_new_row: .skip 64
program_walk_stat: .skip ARM_STAT_BYTES
program_check_stat: .skip ARM_STAT_BYTES
program_current_stat: .skip ARM_STAT_BYTES
program_state_path: .skip 4096
program_reserved_path: .skip 4096
program_path: .skip 4096
program_cwd: .skip 4096
program_rows: .skip PROGRAM_LIMIT * 64
program_input: .skip PROGRAM_STATE_LIMIT + 1
.section .note.GNU-stack,"",%progbits
