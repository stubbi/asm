/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/programs.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Installed programs are distinct from project source dependencies.
 * Native internal ABI: a0-a7 inputs, t0 result; s0-s5 preserved. RV_CALL
 * adds a 16-byte link frame. Every saved register uses 16 stack bytes.
 * Commands terminate; fatal paths retain the original error through cleanup.
 */
.equ PROGRAM_LIMIT, 128
.equ PROGRAM_STATE_LIMIT, 1048576
/* These small macros access process-owned state without changing flags. */
.macro P_LOAD reg, symbol
    RV_ADDR s6, \symbol
    mv s8, s6
    RV_LOAD \reg, 8
.endm
.macro P_STORE reg, symbol
    RV_ADDR s6, \symbol
    mv s8, s6
    RV_STORE \reg, 8
.endm
.macro P_BYTE reg, symbol
    RV_ADDR s6, \symbol
    mv s8, s6
    RV_LOAD \reg, 1
.endm
.macro P_SET value, symbol
    li t1, \value
    P_STORE t1, \symbol
.endm
.section .text
cmd_upgrade:
    P_SET 1, program_upgrade
    li t1, 5
    RV_ZEXT t1
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
cmd_installed:
    RV_JUMP program_local_command
cmd_uninstall:
    P_SET 1, program_remove
/* Parse local-only commands before touching the filesystem. Inputs are argv;
 * owns program_query. No registry access occurs. Stack: no local reservation. */
program_local_command:
    RV_CALL next_arg
    mv s8, t0
    bnez s8, .Lrv_cb_skip_programs45
    RV_JUMP .Lp_local_done
.Lrv_cb_skip_programs45:
    P_STORE t0, program_arg
    mv a0, t0
    RV_ADDR a1, registry_opt_json
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs50
    RV_JUMP .Lp_local_json
.Lrv_cb_skip_programs50:
    P_LOAD a0, program_arg
    RV_ADDR a1, registry_opt_no_color
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs54
    RV_JUMP program_local_command
.Lrv_cb_skip_programs54:
    P_LOAD a0, program_arg
    RV_ADDR a1, registry_opt_help
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs58
    RV_JUMP program_help
.Lrv_cb_skip_programs58:
    P_LOAD a0, program_arg
    mv s8, a0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 45
    RV_FLAGS sub, 32
    RV_BCOND eq, program_bad_args
    P_LOAD t1, program_query
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs64
    RV_JUMP program_bad_args
.Lrv_cb_skip_programs64:
    P_LOAD t1, program_remove
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs66
    RV_JUMP program_bad_args
.Lrv_cb_skip_programs66:
    P_LOAD a0, program_arg
    RV_CALL registry_valid_package
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs69
    RV_JUMP program_bad_args
.Lrv_cb_skip_programs69:
    P_LOAD t1, program_arg
    P_STORE t1, program_query
    RV_JUMP program_local_command
.Lp_local_json:
    li t1, 1
    RV_ZEXT t1
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP program_local_command
.Lp_local_done:
    P_LOAD t1, program_remove
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs80
    RV_JUMP .Lp_local_open
.Lrv_cb_skip_programs80:
    P_LOAD t1, program_query
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs82
    RV_JUMP program_bad_args
.Lrv_cb_skip_programs82:
.Lp_local_open:
    li a0, 0
    RV_ZEXT a0
    RV_CALL program_open_state
    RV_CALL program_read_state
    P_LOAD t1, program_remove
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs88
    RV_JUMP program_list
.Lrv_cb_skip_programs88:
    P_LOAD a0, program_query
    RV_CALL program_find
    mv s8, t0
    bnez s8, .Lrv_cb_skip_programs91
    RV_JUMP program_not_managed
.Lrv_cb_skip_programs91:
    P_STORE t0, program_found
    li s10, 40
    add s8, t0, s10
    RV_LOAD a1, 8
    RV_ADDR a0, program_path
    RV_CALL copy_string
    RV_CALL program_open_destination
    RV_CALL program_check_existing
    RV_CALL program_make_stage
    RV_CALL program_write_state
    RV_CALL program_recheck_destination
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    P_LOAD a2, program_stage_fd
    RV_ADDR a6, program_previous
    RV_CALL rv_renameat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs106
    RV_JUMP program_io_error
.Lrv_tb_skip_programs106:
    P_SET 1, program_mutated
    RV_CALL program_commit_state
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs109
    RV_JUMP .Lp_uninstall_rollback
.Lrv_tb_skip_programs109:
    P_SET 0, program_mutated
    RV_CALL registry_cleanup
    P_BYTE t1, json_mode
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs113
    RV_JUMP exit_ok
.Lrv_cb_skip_programs113:
    RV_ADDR a0, program_ok_json
    RV_CALL out
    RV_JUMP exit_ok
.Lp_uninstall_rollback:
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_previous
    P_LOAD a2, program_dest_fd
    P_LOAD a6, program_dest_name
    li a4, 1
    RV_ZEXT a4
    RV_CALL rv_renameat2
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs124
    RV_JUMP program_recovery_error
.Lrv_tb_skip_programs124:
    P_SET 0, program_mutated
    RV_JUMP program_io_error
/* mode=5 preflight, called after arguments are validated but before index IO.
 * Acquires the inventory lock; its descriptor remains held until cleanup.
 * Upgrade reuses its recorded HTTPS origin unless explicitly overridden.
 * Local origins need --index because local index paths are not persisted.
 * Stack: one saved register. Preserves registry-selected pointers. */
program_before_load:
    RV_SAVE s0
    P_LOAD t1, program_upgrade
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs136
    RV_JUMP .Lp_preflight_open
.Lrv_cb_skip_programs136:
    P_LOAD t1, registry_output
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs138
    RV_JUMP program_bad_args
.Lrv_cb_skip_programs138:
.Lp_preflight_open:
    li a0, 1
    RV_ZEXT a0
    RV_CALL program_open_state
    RV_CALL program_read_state
    P_LOAD a0, registry_query
    RV_CALL program_find
    P_STORE t0, program_found
    P_LOAD t1, program_upgrade
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs147
    RV_JUMP .Lp_preflight_upgrade
.Lrv_cb_skip_programs147:
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs148
    RV_JUMP program_already_managed
.Lrv_cb_skip_programs148:
    P_LOAD t1, program_count
    mv s8, t1
    li s10, PROGRAM_LIMIT
    RV_FLAGS sub, 64
    RV_BCOND hs, program_state_error
    RV_RESTORE s0
    ret
.Lp_preflight_upgrade:
    mv s8, t0
    bnez s8, .Lrv_cb_skip_programs155
    RV_JUMP program_not_managed
.Lrv_cb_skip_programs155:
    mv s0, t0
    li s10, 40
    add s8, s0, s10
    RV_LOAD t1, 8
    P_STORE t1, registry_output
    P_BYTE t1, registry_origin_seen
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs160
    RV_JUMP .Lp_preflight_origin
.Lrv_cb_skip_programs160:
    li s10, 48
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_ADDR a1, program_local
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs164
    RV_JUMP program_local_index_error
.Lrv_cb_skip_programs164:
    li s10, 48
    add s8, s0, s10
    RV_LOAD t1, 8
    P_STORE t1, registry_url
.Lp_preflight_origin:
    P_BYTE t1, registry_local_index
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs169
    RV_JUMP .Lp_preflight_https
.Lrv_cb_skip_programs169:
    RV_ADDR a0, program_local
    RV_JUMP .Lp_preflight_compare
.Lp_preflight_https:
    P_LOAD a0, registry_url
.Lp_preflight_compare:
    li s10, 48
    add s8, s0, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs177
    RV_JUMP program_origin_error
.Lrv_cb_skip_programs177:
    RV_RESTORE s0
    ret
/* Validated selected registry row is borrowed from registry_selected. Before
 * transfer, upgrades check the managed bytes and reject older selections.
 * Equal selections require identical digest/size and leave files unchanged.
 * Stack: two saved registers. Buffer ownership stays with each parser. */
program_prepare_selection:
    RV_SAVE s0
    RV_SAVE s1
    P_LOAD s0, registry_selected
    P_LOAD s1, program_found
    P_LOAD t1, program_upgrade
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs191
    RV_JUMP .Lp_prepare_done
.Lrv_cb_skip_programs191:
    li s10, 40
    add s8, s1, s10
    RV_LOAD a1, 8
    RV_ADDR a0, program_path
    RV_CALL copy_string
    RV_CALL program_open_destination
    RV_CALL program_check_existing
    li s10, 8
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 8
    add s8, s1, s10
    RV_LOAD a1, 8
    RV_CALL registry_version_compare
    mv s8, t0
    li s10, 0
    RV_FLAGS sub, 32
    RV_BCOND lt, program_downgrade_error
    RV_BCOND gt, .Lp_prepare_done
    li s10, 32
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 24
    add s8, s1, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs206
    RV_JUMP program_changed_release
.Lrv_cb_skip_programs206:
    li s10, 48
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 32
    add s8, s1, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs210
    RV_JUMP program_changed_release
.Lrv_cb_skip_programs210:
    RV_CALL registry_cleanup
    P_BYTE t1, json_mode
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs213
    RV_JUMP exit_ok
.Lrv_cb_skip_programs213:
    RV_ADDR a0, program_unchanged_json
    RV_CALL out
    RV_JUMP exit_ok
.Lp_prepare_done:
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Commit a checked executable. Candidate and rollback bytes are copied into a
 * private directory on the destination filesystem, fsynced, then renamed.
 * Inventory failure restores previous bytes/mode or removes a new install.
 * Power/process interruption between the two renames can leave a stage and
 * mismatched receipt. Directory crash durability and hostile same-UID races
 * are outside this advisory-lock contract. Stack: four saved registers. */
program_commit_install:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    P_LOAD s0, registry_selected
    P_LOAD t1, program_upgrade
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs235
    RV_JUMP .Lp_commit_opened
.Lrv_cb_skip_programs235:
    P_LOAD a1, registry_output
    RV_CALL program_absolute_path
    RV_CALL program_open_destination
    RV_CALL program_check_new_path
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    RV_ADDR a2, program_check_stat
    li a6, 256
    RV_CALL rv_newfstatat
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND ne, program_destination_exists
.Lp_commit_opened:
    RV_CALL program_make_stage
    RV_ADDR a0, registry_temp_payload
    RV_IMM a1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 64
    li a2, 0
    RV_CALL rv_open
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs253
    RV_JUMP program_io_error
.Lrv_tb_skip_programs253:
    mv s2, t0
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_candidate
    li a2, 493
    RV_CALL program_copy_into_stage
    mv s3, t0
    mv a0, s2
    RV_CALL rv_close
    mv s8, s3
    beqz s8, .Lrv_cb_skip_programs262
    RV_JUMP program_io_error
.Lrv_cb_skip_programs262:
    P_LOAD t1, program_upgrade
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs264
    RV_JUMP .Lp_commit_new_row
.Lrv_cb_skip_programs264:
    P_LOAD a0, program_current_fd
    li a1, 0
    li a2, 0
    RV_CALL rv_lseek
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs269
    RV_JUMP program_io_error
.Lrv_tb_skip_programs269:
    P_LOAD s2, program_current_fd
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_previous
    P_LOAD t1, program_current_mode
    li s10, 1023
    and a2, t1, s10
    RV_CALL program_copy_into_stage
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs276
    RV_JUMP program_io_error
.Lrv_cb_skip_programs276:
.Lp_commit_new_row:
    RV_ADDR s1, program_new_row
    mv s8, s0
    RV_LOAD t1, 8
    addi s8, s8, 8
    RV_LOAD t2, 8
    mv s8, s1
    RV_STORE t1, 8
    addi s8, s8, 8
    RV_STORE t2, 8
    li s10, 16
    add s8, s0, s10
    RV_LOAD t1, 8
    li s10, 16
    add s8, s1, s10
    RV_STORE t1, 8
    li s10, 32
    add s8, s0, s10
    RV_LOAD t1, 8
    li s10, 24
    add s8, s1, s10
    RV_STORE t1, 8
    li s10, 48
    add s8, s0, s10
    RV_LOAD t1, 8
    li s10, 32
    add s8, s1, s10
    RV_STORE t1, 8
    RV_ADDR t1, program_path
    li s10, 40
    add s8, s1, s10
    RV_STORE t1, 8
    P_BYTE t1, registry_local_index
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs290
    RV_JUMP .Lp_commit_https
.Lrv_cb_skip_programs290:
    RV_ADDR t1, program_local
    RV_JUMP .Lp_commit_origin_set
.Lp_commit_https:
    P_LOAD t1, registry_url
.Lp_commit_origin_set:
    li s10, 48
    add s8, s1, s10
    RV_STORE t1, 8
    RV_CALL program_write_state
    P_LOAD t1, program_upgrade
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs299
    RV_JUMP .Lp_commit_absent
.Lrv_cb_skip_programs299:
    RV_CALL program_recheck_destination
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_candidate
    P_LOAD a2, program_dest_fd
    P_LOAD a6, program_dest_name
    RV_CALL rv_renameat
    RV_JUMP .Lp_commit_payload_result
.Lp_commit_absent:
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_candidate
    P_LOAD a2, program_dest_fd
    P_LOAD a6, program_dest_name
    li a4, 1
    RV_CALL rv_renameat2
.Lp_commit_payload_result:
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs315
    RV_JUMP program_destination_exists
.Lrv_tb_skip_programs315:
    P_SET 1, program_mutated
    RV_CALL program_commit_state
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs318
    RV_JUMP .Lp_commit_rollback
.Lrv_tb_skip_programs318:
    P_SET 0, program_mutated
    RV_ADDR t1, program_path
    P_STORE t1, registry_output
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
.Lp_commit_rollback:
    P_LOAD t1, program_upgrade
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs329
    RV_JUMP .Lp_commit_rollback_install
.Lrv_cb_skip_programs329:
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_previous
    P_LOAD a2, program_dest_fd
    P_LOAD a6, program_dest_name
    RV_CALL rv_renameat
    RV_JUMP .Lp_commit_rollback_result
.Lp_commit_rollback_install:
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    li a2, 0
    RV_CALL rv_unlinkat
.Lp_commit_rollback_result:
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs342
    RV_JUMP program_recovery_error
.Lrv_tb_skip_programs342:
    P_SET 0, program_mutated
    RV_JUMP program_io_error
/* a1=nonempty relative/absolute output <=4095. Produces absolute program_path
 * without resolving symlinks. The descriptor walk rejects '.'/'..' and empty
 * components. Buffers: cwd/path 4096 each. Stack: two saved registers. */
program_absolute_path:
    RV_SAVE s0
    RV_SAVE s1
    mv s0, a1
    mv a0, a1
    RV_CALL strlen
    mv s1, t0
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_absolute_copy
    RV_ADDR a0, program_cwd
    li a1, 4096
    RV_CALL rv_getcwd
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs362
    RV_JUMP program_path_error
.Lrv_tb_skip_programs362:
    RV_ADDR a0, program_cwd
    RV_CALL strlen
    mv s10, s1
    add t1, t0, s10
    li s10, 1
    add t1, t1, s10
    mv s8, t1
    li s10, 4095
    RV_FLAGS sub, 64
    RV_BCOND hi, program_path_error
    RV_ADDR a0, program_path
    RV_ADDR a1, program_cwd
    RV_CALL copy_string
    li t1, 47
    RV_ZEXT t1
    mv s8, t0
    RV_STORE t1, 1
    li s10, 1
    add t0, t0, s10
    mv a0, t0
    mv a1, s0
    RV_CALL copy_string
    RV_JUMP .Lp_absolute_done
.Lp_absolute_copy:
    mv s8, s1
    li s10, 4095
    RV_FLAGS sub, 64
    RV_BCOND hi, program_path_error
    RV_ADDR a0, program_path
    mv a1, s0
    RV_CALL copy_string
.Lp_absolute_done:
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=create state directories (0/1). HOME must be absolute <=3800 bytes.
 * Opens protected directory ancestors and acquires a nonblocking exclusive
 * directory flock. Missing state in read-only mode is an empty inventory.
 * Stack: two saved registers. All held descriptors belong to this process. */
program_open_state:
    RV_SAVE s0
    RV_SAVE s1
    mv s1, a0
    RV_CALL rv_getuid
    P_STORE t0, program_uid
    mv s0, t0
    RV_CALL rv_geteuid
    mv s8, t0
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND ne, program_path_error
    P_LOAD s0, envp
.Lp_home_loop:
    mv s8, s0
    RV_LOAD a0, 8
    li s10, 8
    add s0, s0, s10
    mv s8, a0
    bnez s8, .Lrv_cb_skip_programs406
    RV_JUMP program_path_error
.Lrv_cb_skip_programs406:
    mv s8, a0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 72
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_home_loop
    li s10, 1
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 79
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_home_loop
    li s10, 2
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 77
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_home_loop
    li s10, 3
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 69
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_home_loop
    li s10, 4
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 61
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_home_loop
    li s10, 5
    add s0, a0, s10
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND ne, program_path_error
    mv a0, s0
    RV_CALL strlen
    mv s8, t0
    li s10, 3800
    RV_FLAGS sub, 64
    RV_BCOND hi, program_path_error
    mv s8, t0
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND ls, program_path_error
    P_STORE t0, program_home_length
    P_STORE s0, program_home
    RV_ADDR a0, program_state_path
    mv a1, s0
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, program_state_suffix
    RV_CALL copy_string
    RV_ADDR a0, program_state_path
    mv a1, s1
    RV_CALL program_walk_parent
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_state_missing
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs445
    RV_JUMP program_path_error
.Lrv_tb_skip_programs445:
    P_STORE t0, program_state_fd
    mv a0, t0
    li a1, 6
    RV_CALL rv_flock
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs450
    RV_JUMP program_busy_error
.Lrv_tb_skip_programs450:
.Lp_state_missing:
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=absolute mutable path <=4095, a1=allow mkdir below HOME (0/1).
 * t0=owned parent FD or negative errno; program_basename borrows final name.
 * Rejects symlinks, traversal, ASCII controls, invalid UTF-8 and >255-byte names.
 * Ancestors must be root/user owned and deny group/other writes. HOME and
 * descendants must belong to this UID. Exact root-owned sticky /tmp and
 * /private/tmp are exceptions above HOME; their child must be user-owned.
 * Uses descriptor-relative opens and restores temporary NUL separators.
 * Stack: six saved registers and 16 local bytes; stat scratch is 128 bytes. */
program_walk_parent:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    li s10, 16
    sub sp, sp, s10
    mv s8, sp
    RV_STORE zero, 8
    mv s0, a0
    mv s1, a1
    mv a0, s0
    RV_CALL program_valid_absolute_path
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs477
    RV_JUMP .Lp_walk_bad_initial
.Lrv_cb_skip_programs477:
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_walk_bad_initial
    RV_ADDR a0, program_root
    RV_IMM a1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW, 64
    li a2, 0
    RV_CALL rv_open
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs485
    RV_JUMP .Lp_walk_return
.Lrv_tb_skip_programs485:
    mv s2, t0
    mv a0, s2
    RV_ADDR a1, program_walk_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs490
    RV_JUMP .Lp_walk_bad
.Lrv_tb_skip_programs490:
    RV_ADDR s6, program_walk_stat
    li s10, RV_STAT_MODE
    add s8, s6, s10
    RV_LOAD t1, 4
    li t5, 18
    RV_ZEXT t5
    mv s8, t1
    mv s10, t5
    RV_FLAGS and, 32
    RV_BCOND ne, .Lp_walk_bad
    li s10, RV_STAT_UID
    add s8, s6, s10
    RV_LOAD t1, 4
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs497
    RV_JUMP .Lp_walk_root_owned
.Lrv_cb_skip_programs497:
    P_LOAD t2, program_uid
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_walk_bad
.Lp_walk_root_owned:
    li s10, 1
    add s3, s0, s10
    /* Only matching HOME descendants inherit the user-only ownership rule. */
    P_LOAD a1, program_home
    mv a2, s0
.Lp_walk_home_prefix:
    mv s8, a1
    RV_LOAD t1, 1
    li s10, 1
    add a1, a1, s10
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs508
    RV_JUMP .Lp_walk_home_prefix_end
.Lrv_cb_skip_programs508:
    mv s8, a2
    RV_LOAD t2, 1
    li s10, 1
    add a2, a2, s10
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_walk_outside_home
    RV_JUMP .Lp_walk_home_prefix
.Lp_walk_home_prefix_end:
    mv s8, a2
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_walk_outside_home
    P_LOAD s5, program_home_length
    RV_JUMP .Lp_walk_component
.Lp_walk_outside_home:
    li s5, -1
.Lp_walk_component:
    mv s4, s3
.Lp_walk_scan:
    mv s8, s4
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs525
    RV_JUMP .Lp_walk_final
.Lrv_cb_skip_programs525:
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_walk_separator
    mv s8, t1
    li s10, 32
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_walk_bad
    mv s8, t1
    li s10, 127
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_walk_bad
    mv s10, s3
    sub t2, s4, s10
    mv s8, t2
    li s10, 254
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lp_walk_bad
    li s10, 1
    add s4, s4, s10
    RV_JUMP .Lp_walk_scan
.Lp_walk_separator:
    mv s8, s4
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_walk_bad
    mv s8, s4
    RV_STORE zero, 1
    RV_CALL program_component_valid
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs542
    RV_JUMP .Lp_walk_bad_restore
.Lrv_cb_skip_programs542:
    mv a0, s2
    mv a1, s3
    RV_IMM a2, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW, 64
    li a6, 0
    RV_CALL rv_openat
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND ne, .Lp_walk_open_result
    mv s8, s1
    bnez s8, .Lrv_cb_skip_programs550
    RV_JUMP .Lp_walk_open_result
.Lrv_cb_skip_programs550:
    mv s10, s0
    sub t1, s3, s10
    mv s8, t1
    mv s10, s5
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lp_walk_open_result
    mv a0, s2
    mv a1, s3
    li a2, 448
    RV_CALL rv_mkdirat
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs558
    RV_JUMP .Lp_walk_open_result
.Lrv_cb_skip_programs558:
    mv a0, s2
    mv a1, s3
    RV_IMM a2, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW, 64
    li a6, 0
    RV_CALL rv_openat
.Lp_walk_open_result:
    mv t1, t0
    li t2, 47
    RV_ZEXT t2
    mv s8, s4
    RV_STORE t2, 1
    srli s8, t1, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs568
    RV_JUMP .Lp_walk_close_error
.Lrv_tb_skip_programs568:
    mv a0, s2
    mv s2, t1
    RV_CALL rv_close
    mv a0, s2
    RV_ADDR a1, program_walk_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs575
    RV_JUMP .Lp_walk_bad
.Lrv_tb_skip_programs575:
    /* A directory identity, rather than its spelling, reserves state on
     * case-insensitive filesystems too. Refuse its entire descendant tree. */
    P_LOAD a0, program_state_fd
    srli s8, a0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs579
    RV_JUMP .Lp_walk_not_state
.Lrv_tb_skip_programs579:
    RV_ADDR a1, program_check_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs582
    RV_JUMP .Lp_walk_bad
.Lrv_tb_skip_programs582:
    RV_ADDR a0, program_walk_stat
    RV_ADDR a1, program_check_stat
    li s10, RV_STAT_DEVICE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_DEVICE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_walk_not_state
    li s10, RV_STAT_INODE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_INODE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_walk_bad
.Lp_walk_not_state:
    RV_ADDR s6, program_walk_stat
    li s10, RV_STAT_MODE
    add s8, s6, s10
    RV_LOAD t1, 4
    li s10, 61440
    and t2, t1, s10
    RV_ZEXT t2
    mv s8, t2
    li s10, 16384
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_walk_bad
    li s10, RV_STAT_UID
    add s8, s6, s10
    RV_LOAD t2, 4
    P_LOAD t3, program_uid
    mv s10, s0
    sub t4, s4, s10
    mv s8, t4
    mv s10, s5
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lp_walk_user
    mv s8, sp
    RV_LOAD t5, 8
    mv s8, t5
    beqz s8, .Lrv_cb_skip_programs605
    RV_JUMP .Lp_walk_user
.Lrv_cb_skip_programs605:
    mv s8, t2
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs606
    RV_JUMP .Lp_walk_mode
.Lrv_cb_skip_programs606:
.Lp_walk_user:
    mv s8, t2
    mv s10, t3
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_walk_bad
.Lp_walk_mode:
    li t5, 18
    RV_ZEXT t5
    mv s8, t1
    mv s10, t5
    RV_FLAGS and, 32
    RV_BCOND eq, .Lp_walk_protected
    mv s8, t2
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs614
    RV_JUMP .Lp_walk_bad
.Lrv_cb_skip_programs614:
    mv s8, t1
    li s10, 512
    RV_FLAGS and, 32
    RV_BCOND eq, .Lp_walk_bad
    mv s8, t4
    mv s10, s5
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lp_walk_bad
    mv s8, t4
    li s10, 4
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_walk_tmp4
    mv s8, t4
    li s10, 12
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_walk_bad
    RV_ADDR a1, program_private_tmp
    RV_JUMP .Lp_walk_check_tmp
.Lp_walk_tmp4:
    RV_ADDR a1, program_tmp
.Lp_walk_check_tmp:
    li t1, 0
    RV_ZEXT t1
    mv s8, s4
    RV_STORE t1, 1
    mv a0, s0
    RV_CALL streq
    li t1, 47
    RV_ZEXT t1
    mv s8, s4
    RV_STORE t1, 1
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs634
    RV_JUMP .Lp_walk_bad
.Lrv_cb_skip_programs634:
    li t1, 1
    mv s8, sp
    RV_STORE t1, 8
    RV_JUMP .Lp_walk_next
.Lp_walk_protected:
    mv s8, sp
    RV_STORE zero, 8
.Lp_walk_next:
    li s10, 1
    add s3, s4, s10
    RV_JUMP .Lp_walk_component
.Lp_walk_final:
    mv s8, s4
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_walk_bad
    RV_CALL program_component_valid
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs647
    RV_JUMP .Lp_walk_bad
.Lrv_cb_skip_programs647:
    P_STORE s3, program_basename
    mv t0, s2
    RV_JUMP .Lp_walk_return
.Lp_walk_bad_restore:
    li t1, 47
    RV_ZEXT t1
    mv s8, s4
    RV_STORE t1, 1
.Lp_walk_bad:
    li t1, -13
.Lp_walk_close_error:
    li s10, 8
    add s8, sp, s10
    RV_STORE t1, 8
    mv a0, s2
    RV_CALL rv_close
    li s10, 8
    add s8, sp, s10
    RV_LOAD t0, 8
    RV_JUMP .Lp_walk_return
.Lp_walk_bad_initial:
    li t0, -22
.Lp_walk_return:
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* s3=NUL component; t0=1 except '.'/'..'; no stack or memory changes. */
program_component_valid:
    mv s8, s3
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 46
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_component_good
    li s10, 1
    add s8, s3, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs679
    RV_JUMP .Lp_component_bad
.Lrv_cb_skip_programs679:
    mv s8, t1
    li s10, 46
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_component_good
    li s10, 2
    add s8, s3, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs683
    RV_JUMP .Lp_component_bad
.Lrv_cb_skip_programs683:
.Lp_component_good:
    li t0, 1
    RV_ZEXT t0
    ret
.Lp_component_bad:
    li t0, 0
    RV_ZEXT t0
    ret
/* Opens the constructed destination's protected parent, retains its FD and
 * basename, and reserves HOME/.local/bin/asm for the provenance updater.
 * No directory is created. Stack: one saved register. */
program_open_destination:
    RV_SAVE s0
    RV_ADDR a0, program_reserved_path
    P_LOAD a1, program_home
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, program_reserved_suffix
    RV_CALL copy_string
    RV_ADDR a0, program_path
    RV_ADDR a1, program_reserved_path
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs705
    RV_JUMP program_reserved_error
.Lrv_cb_skip_programs705:
    RV_ADDR a0, program_state_path
    RV_CALL strlen
    li s10, 13
    sub a2, t0, s10
    RV_ADDR a0, program_path
    RV_ADDR a1, program_state_path
.Lp_destination_internal:
    mv s8, a2
    bnez s8, .Lrv_cb_skip_programs712
    RV_JUMP program_internal_error
.Lrv_cb_skip_programs712:
    mv s8, a0
    RV_LOAD t1, 1
    li s10, 1
    add a0, a0, s10
    mv s8, a1
    RV_LOAD t2, 1
    li s10, 1
    add a1, a1, s10
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_destination_external
    li s10, 1
    sub a2, a2, s10
    RV_JUMP .Lp_destination_internal
.Lp_destination_external:
    RV_ADDR a0, program_path
    li a1, 0
    RV_CALL program_walk_parent
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs723
    RV_JUMP program_path_error
.Lrv_tb_skip_programs723:
    P_STORE t0, program_dest_fd
    P_LOAD t1, program_basename
    P_STORE t1, program_dest_name
    RV_CALL program_check_cli_destination
    P_BYTE t1, registry_has_workspace
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs729
    RV_JUMP .Lp_destination_workspace_safe
.Lrv_cb_skip_programs729:
    RV_ADDR a0, registry_temp_dir
    RV_IMM a1, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW, 64
    li a2, 0
    RV_CALL rv_open
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs734
    RV_JUMP program_path_error
.Lrv_tb_skip_programs734:
    mv s0, t0
    mv a0, s0
    RV_ADDR a1, program_walk_stat
    RV_CALL rv_fstat
    P_STORE t0, program_internal_stat_result
    mv a0, s0
    RV_CALL rv_close
    P_LOAD t0, program_internal_stat_result
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs743
    RV_JUMP program_path_error
.Lrv_tb_skip_programs743:
    P_LOAD a0, program_dest_fd
    RV_ADDR a1, program_check_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs747
    RV_JUMP program_path_error
.Lrv_tb_skip_programs747:
    RV_ADDR a0, program_walk_stat
    RV_ADDR a1, program_check_stat
    li s10, RV_STAT_DEVICE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_DEVICE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_destination_workspace_safe
    li s10, RV_STAT_INODE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_INODE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, program_internal_error
.Lp_destination_workspace_safe:
    RV_RESTORE s0
    ret
/* Reserve case aliases of the CLI basename by the actual bin directory
 * identity. Never assume that path spelling identifies a filesystem entry.
 * Input: destination FD/name and constructed reserved_path. Stack: two saves.
 * A missing default bin directory cannot alias an existing destination parent. */
program_check_cli_destination:
    RV_SAVE s0
    RV_SAVE s1
    P_LOAD a0, program_dest_name
    mv s8, a0
    RV_LOAD t1, 1
    li s10, 32
    or t1, t1, s10
    RV_ZEXT t1
    mv s8, t1
    li s10, 97
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_cli_destination_safe
    li s10, 1
    add s8, a0, s10
    RV_LOAD t1, 1
    li s10, 32
    or t1, t1, s10
    RV_ZEXT t1
    mv s8, t1
    li s10, 115
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_cli_destination_safe
    li s10, 2
    add s8, a0, s10
    RV_LOAD t1, 1
    li s10, 32
    or t1, t1, s10
    RV_ZEXT t1
    mv s8, t1
    li s10, 109
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_cli_destination_safe
    li s10, 3
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs783
    RV_JUMP .Lp_cli_destination_safe
.Lrv_cb_skip_programs783:
    RV_ADDR a0, program_reserved_path
    li a1, 0
    RV_CALL program_walk_parent
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs787
    RV_JUMP .Lp_cli_destination_safe
.Lrv_tb_skip_programs787:
    mv s0, t0
    mv a0, s0
    RV_ADDR a1, program_walk_stat
    RV_CALL rv_fstat
    mv s1, t0
    mv a0, s0
    RV_CALL rv_close
    srli s8, s1, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs795
    RV_JUMP program_path_error
.Lrv_tb_skip_programs795:
    P_LOAD a0, program_dest_fd
    RV_ADDR a1, program_check_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs799
    RV_JUMP program_path_error
.Lrv_tb_skip_programs799:
    RV_ADDR a0, program_walk_stat
    RV_ADDR a1, program_check_stat
    li s10, RV_STAT_DEVICE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_DEVICE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_cli_destination_safe
    li s10, RV_STAT_INODE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_INODE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, program_reserved_error
.Lp_cli_destination_safe:
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Read a regular, owned, protected single-link inventory. Empty/missing files
 * are distinct: missing means no programs; an empty file is malformed.
 * All bytes are bounded before parsing; no results print until validation.
 * Stack: two saved registers. program_input has limit+1 byte capacity. */
program_read_state:
    RV_SAVE s0
    RV_SAVE s1
    P_SET 0, program_count
    P_LOAD a0, program_state_fd
    srli s8, a0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs824
    RV_JUMP .Lp_read_done
.Lrv_tb_skip_programs824:
    RV_ADDR a1, program_state_name
    RV_IMM a2, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 64
    li a6, 0
    RV_CALL rv_openat
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_read_done
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs831
    RV_JUMP program_state_error
.Lrv_tb_skip_programs831:
    mv s0, t0
    mv a0, s0
    RV_ADDR a1, program_check_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs836
    RV_JUMP .Lp_read_bad
.Lrv_tb_skip_programs836:
    RV_ADDR a0, program_check_stat
    RV_CALL program_regular_stat
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs839
    RV_JUMP .Lp_read_bad
.Lrv_cb_skip_programs839:
    RV_ADDR s6, program_check_stat
    li s10, RV_STAT_SIZE
    add s8, s6, s10
    RV_LOAD t1, 8
    RV_IMM t2, PROGRAM_STATE_LIMIT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lp_read_bad
    li s1, 0
.Lp_read_loop:
    mv a0, s0
    RV_ADDR a1, program_input
    mv s10, s1
    add a1, a1, s10
    RV_IMM a2, PROGRAM_STATE_LIMIT + 1, 64
    mv s10, s1
    sub a2, a2, s10
    RV_CALL rv_read
    mv s8, t0
    li s10, 4
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_read_loop
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs855
    RV_JUMP .Lp_read_bad
.Lrv_tb_skip_programs855:
    mv s8, t0
    bnez s8, .Lrv_cb_skip_programs856
    RV_JUMP .Lp_read_eof
.Lrv_cb_skip_programs856:
    mv s10, t0
    add s1, s1, s10
    RV_IMM t1, PROGRAM_STATE_LIMIT, 64
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lp_read_bad
    RV_JUMP .Lp_read_loop
.Lp_read_eof:
    mv a0, s0
    RV_CALL rv_close
    P_STORE s1, program_input_size
    RV_CALL program_parse_state
.Lp_read_done:
    RV_RESTORE s1
    RV_RESTORE s0
    ret
.Lp_read_bad:
    mv a0, s0
    RV_CALL rv_close
    RV_JUMP program_state_error
/* Parses seven TSV fields per record; metadata is printable ASCII, <=128 records. Borrowed
 * pointers have process lifetime in program_input. Every field is validated,
 * including duplicates, before any mutation. Stack: six saved registers. */
program_parse_state:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s0, program_input
    P_LOAD s1, program_input_size
    mv s10, s0
    add s1, s1, s10
    RV_ADDR s2, program_header
.Lp_parse_header:
    mv s8, s2
    RV_LOAD t1, 1
    li s10, 1
    add s2, s2, s10
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs892
    RV_JUMP .Lp_parse_row
.Lrv_cb_skip_programs892:
    mv s8, s0
    mv s10, s1
    RV_FLAGS sub, 64
    RV_BCOND hs, program_state_error
    mv s8, s0
    RV_LOAD t2, 1
    li s10, 1
    add s0, s0, s10
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, program_state_error
    RV_JUMP .Lp_parse_header
.Lp_parse_row:
    mv s8, s0
    mv s10, s1
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_parse_done
    P_LOAD s4, program_count
    mv s8, s4
    li s10, PROGRAM_LIMIT
    RV_FLAGS sub, 64
    RV_BCOND hs, program_state_error
    RV_ADDR s2, program_rows
    mv s10, s4
    slli s10, s10, 6
    add s2, s2, s10
    mv s8, s2
    RV_STORE s0, 8
    li s3, 0
    mv s5, s0
.Lp_parse_char:
    mv s8, s0
    mv s10, s1
    RV_FLAGS sub, 64
    RV_BCOND hs, program_state_error
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 9
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_parse_tab
    mv s8, t1
    li s10, 10
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_parse_newline
    mv s8, t1
    li s10, 32
    RV_FLAGS sub, 32
    RV_BCOND lo, program_state_error
    mv s8, t1
    li s10, 127
    RV_FLAGS sub, 32
    RV_BCOND eq, program_state_error
    RV_BCOND lo, .Lp_parse_ascii
    mv s8, s3
    li s10, 5
    RV_FLAGS sub, 64
    RV_BCOND ne, program_state_error
.Lp_parse_ascii:
    mv s10, s5
    sub t2, s0, s10
    mv s8, t2
    li s10, 4094
    RV_FLAGS sub, 64
    RV_BCOND hi, program_state_error
    li s10, 1
    add s0, s0, s10
    RV_JUMP .Lp_parse_char
.Lp_parse_tab:
    mv s8, s0
    mv s10, s5
    RV_FLAGS sub, 64
    RV_BCOND eq, program_state_error
    mv s8, s3
    li s10, 6
    RV_FLAGS sub, 64
    RV_BCOND hs, program_state_error
    mv s8, s0
    RV_STORE zero, 1
    li s10, 1
    add s0, s0, s10
    li s10, 1
    add s3, s3, s10
    mv s10, s3
    slli s10, s10, 3
    add s8, s2, s10
    RV_STORE s0, 8
    mv s5, s0
    RV_JUMP .Lp_parse_char
.Lp_parse_newline:
    mv s8, s3
    li s10, 6
    RV_FLAGS sub, 64
    RV_BCOND ne, program_state_error
    mv s8, s0
    mv s10, s5
    RV_FLAGS sub, 64
    RV_BCOND eq, program_state_error
    mv s8, s0
    RV_STORE zero, 1
    li s10, 1
    add s0, s0, s10
    mv a0, s2
    RV_CALL program_validate_row
    li s10, 1
    add s4, s4, s10
    P_STORE s4, program_count
    RV_JUMP .Lp_parse_row
.Lp_parse_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=seven-pointer row; checks canonical identities/size/hash, absolute path,
 * HTTPS/local origin, and uniqueness against earlier rows. Stack: 3 saves. */
program_validate_row:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    mv s8, s0
    RV_LOAD a0, 8
    RV_CALL registry_valid_package
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs970
    RV_JUMP program_state_error
.Lrv_cb_skip_programs970:
    li s10, 8
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_valid_version
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs973
    RV_JUMP program_state_error
.Lrv_cb_skip_programs973:
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_valid_target
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs976
    RV_JUMP program_state_error
.Lrv_cb_skip_programs976:
    li s10, 24
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL strlen
    mv s8, t0
    li s10, 64
    RV_FLAGS sub, 64
    RV_BCOND ne, program_state_error
    li s10, 24
    add s8, s0, s10
    RV_LOAD a0, 8
    li a2, 0
.Lp_validate_hash:
    mv s10, a2
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 48
    RV_FLAGS sub, 32
    RV_BCOND lo, program_state_error
    mv s8, t1
    li s10, 57
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lp_validate_hash_next
    mv s8, t1
    li s10, 97
    RV_FLAGS sub, 32
    RV_BCOND lo, program_state_error
    mv s8, t1
    li s10, 102
    RV_FLAGS sub, 32
    RV_BCOND hi, program_state_error
.Lp_validate_hash_next:
    li s10, 1
    add a2, a2, s10
    mv s8, a2
    li s10, 64
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lp_validate_hash
    li s10, 64
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs998
    RV_JUMP program_state_error
.Lrv_cb_skip_programs998:
    li s10, 32
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_size_value
    mv s8, t0
    bnez s8, .Lrv_cb_skip_programs1001
    RV_JUMP program_state_error
.Lrv_cb_skip_programs1001:
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL program_valid_absolute_path
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1004
    RV_JUMP program_state_error
.Lrv_cb_skip_programs1004:
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    mv s8, a0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND ne, program_state_error
    li s10, 48
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_ADDR a1, program_local
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1012
    RV_JUMP .Lp_validate_unique
.Lrv_cb_skip_programs1012:
    li s10, 48
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_https_url
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1015
    RV_JUMP program_state_error
.Lrv_cb_skip_programs1015:
.Lp_validate_unique:
    RV_ADDR s1, program_rows
.Lp_validate_duplicate:
    mv s8, s1
    mv s10, s0
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_validate_done
    mv s8, s0
    RV_LOAD a0, 8
    mv s8, s1
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1024
    RV_JUMP program_state_error
.Lrv_cb_skip_programs1024:
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    li s10, 40
    add s8, s1, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1028
    RV_JUMP program_state_error
.Lrv_cb_skip_programs1028:
    li s10, 64
    add s1, s1, s10
    RV_JUMP .Lp_validate_duplicate
.Lp_validate_done:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=canonical package; t0=borrowed matching row or zero. Stack: 3 saves. */
program_find:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a0
    RV_ADDR s1, program_rows
    P_LOAD s2, program_count
.Lp_find_loop:
    mv s8, s2
    bnez s8, .Lrv_cb_skip_programs1046
    RV_JUMP .Lp_find_absent
.Lrv_cb_skip_programs1046:
    mv a0, s0
    mv s8, s1
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1050
    RV_JUMP .Lp_find_found
.Lrv_cb_skip_programs1050:
    li s10, 64
    add s1, s1, s10
    li s10, 1
    sub s2, s2, s10
    RV_JUMP .Lp_find_loop
.Lp_find_absent:
    li t0, 0
    RV_JUMP .Lp_find_done
.Lp_find_found:
    mv t0, s1
.Lp_find_done:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=NUL-terminated text <=4095 bytes; t0=1 for canonical UTF-8. Rejects
 * overlong encodings, surrogate code points, and values above U+10FFFF.
 * No writes or stack use. Scratch a0-a3,t1-t3; stops at the first NUL. */
program_valid_utf8:
.Lp_utf8_next:
    mv s8, a0
    RV_LOAD t1, 1
    li s10, 1
    add a0, a0, s10
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1071
    RV_JUMP .Lp_utf8_good
.Lrv_cb_skip_programs1071:
    mv s8, t1
    li s10, 128
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_next
    mv s8, t1
    li s10, 194
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_bad
    mv s8, t1
    li s10, 224
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_one
    mv s8, t1
    li s10, 240
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_three
    mv s8, t1
    li s10, 245
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lp_utf8_bad
    mv s8, a0
    RV_LOAD t2, 1
    li s10, 1
    add a0, a0, s10
    mv s8, t2
    li s10, 128
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_bad
    mv s8, t2
    li s10, 192
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lp_utf8_bad
    mv s8, t1
    li s10, 240
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_utf8_four_upper
    mv s8, t2
    li s10, 144
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_bad
.Lp_utf8_four_upper:
    mv s8, t1
    li s10, 244
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_utf8_four_tail
    mv s8, t2
    li s10, 144
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lp_utf8_bad
.Lp_utf8_four_tail:
    li a2, 2
    RV_ZEXT a2
    RV_JUMP .Lp_utf8_tail
.Lp_utf8_three:
    mv s8, a0
    RV_LOAD t2, 1
    li s10, 1
    add a0, a0, s10
    mv s8, t2
    li s10, 128
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_bad
    mv s8, t2
    li s10, 192
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lp_utf8_bad
    mv s8, t1
    li s10, 224
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_utf8_three_upper
    mv s8, t2
    li s10, 160
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_bad
.Lp_utf8_three_upper:
    mv s8, t1
    li s10, 237
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_utf8_one
    mv s8, t2
    li s10, 160
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lp_utf8_bad
.Lp_utf8_one:
    li a2, 1
    RV_ZEXT a2
.Lp_utf8_tail:
    mv s8, a0
    RV_LOAD t2, 1
    li s10, 1
    add a0, a0, s10
    mv s8, t2
    li s10, 128
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_utf8_bad
    mv s8, t2
    li s10, 192
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lp_utf8_bad
    mv s8, a2
    li s10, 1
    RV_FLAGS sub, 32
    mv a2, s11
    RV_BCOND ne, .Lp_utf8_tail
    RV_JUMP .Lp_utf8_next
.Lp_utf8_good:
    li t0, 1
    RV_ZEXT t0
    ret
.Lp_utf8_bad:
    li t0, 0
    RV_ZEXT t0
    ret
/* a0=NUL path <=4095 bytes; t0=1 for an absolute canonical UTF-8 file path.
 * Reject controls, empty components, '.'/'..', and names above 255 bytes.
 * Pure validation does not open files, so listing detects malformed receipts
 * even when destinations are absent. Stack: one saved register. */
program_valid_absolute_path:
    RV_SAVE s0
    mv s0, a0
    RV_CALL program_valid_utf8
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1140
    RV_JUMP .Lp_path_invalid
.Lrv_cb_skip_programs1140:
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_path_invalid
    li s10, 1
    add a1, s0, s10
    mv a2, a1
.Lp_path_scan:
    mv s8, a2
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1148
    RV_JUMP .Lp_path_component
.Lrv_cb_skip_programs1148:
    mv s8, t1
    li s10, 47
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_path_component
    mv s8, t1
    li s10, 32
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lp_path_invalid
    mv s8, t1
    li s10, 127
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_path_invalid
    li s10, 1
    add a2, a2, s10
    RV_JUMP .Lp_path_scan
.Lp_path_component:
    mv s10, a1
    sub a3, a2, s10
    mv s8, a3
    bnez s8, .Lrv_cb_skip_programs1159
    RV_JUMP .Lp_path_invalid
.Lrv_cb_skip_programs1159:
    mv s8, a3
    li s10, 255
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lp_path_invalid
    mv s8, a3
    li s10, 2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lp_path_component_valid
    mv s8, a1
    RV_LOAD t2, 1
    mv s8, t2
    li s10, 46
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_path_component_valid
    mv s8, a3
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_path_invalid
    li s10, 1
    add s8, a1, s10
    RV_LOAD t2, 1
    mv s8, t2
    li s10, 46
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lp_path_invalid
.Lp_path_component_valid:
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1173
    RV_JUMP .Lp_path_valid
.Lrv_cb_skip_programs1173:
    li s10, 1
    add a1, a2, s10
    mv a2, a1
    RV_JUMP .Lp_path_scan
.Lp_path_invalid:
    li t0, 0
    RV_ZEXT t0
    RV_RESTORE s0
    ret
.Lp_path_valid:
    li t0, 1
    RV_ZEXT t0
    RV_RESTORE s0
    ret
/* A missing file still belongs to its installation record. Compare actual
 * parent directory identities, then let that directory resolve the names.
 * Only a parent collision needs a probe. One O_EXCL mode-000 empty file at
 * the new destination exposes the filesystem's exact case/Unicode rules.
 * No data is written and no execution is possible. Remove the owned probe
 * before staging the executable. An interruption can leave an empty inert
 * new destination; previous files and inventory bytes remain unchanged.
 * Inputs: held destination FD/name, canonical program_path, <=128 rows.
 * Names are borrowed from parsed rows; names[129] includes reserved asm.
 * Stack: six saved registers. No shell, child, or Unicode approximation.
 */
program_check_new_path:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    P_LOAD a0, program_dest_fd
    RV_ADDR a1, program_alias_parent_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1207
    RV_JUMP program_path_error
.Lrv_tb_skip_programs1207:
    RV_ADDR s0, program_rows
    P_LOAD s1, program_count
    li s3, 0
.Lp_new_path_loop:
    mv s8, s1
    bnez s8, .Lrv_cb_skip_programs1212
    RV_JUMP .Lp_new_path_cli
.Lrv_cb_skip_programs1212:
    RV_ADDR a0, program_path
    li s10, 40
    add s8, s0, s10
    RV_LOAD a1, 8
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1216
    RV_JUMP program_destination_exists
.Lrv_cb_skip_programs1216:
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    li a1, 0
    RV_CALL program_walk_parent
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_new_path_next
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1222
    RV_JUMP program_path_error
.Lrv_tb_skip_programs1222:
    mv s2, t0
    mv a0, s2
    RV_ADDR a1, program_alias_record_stat
    RV_CALL rv_fstat
    mv s4, t0
    mv a0, s2
    RV_CALL rv_close
    srli s8, s4, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1230
    RV_JUMP program_path_error
.Lrv_tb_skip_programs1230:
    RV_ADDR a0, program_alias_parent_stat
    RV_ADDR a1, program_alias_record_stat
    RV_CALL program_same_identity
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1234
    RV_JUMP .Lp_new_path_next
.Lrv_cb_skip_programs1234:
    P_LOAD t1, program_basename
    RV_ADDR s6, program_alias_names
    mv s10, s3
    slli s10, s10, 3
    add s8, s6, s10
    RV_STORE t1, 8
    li s10, 1
    add s3, s3, s10
.Lp_new_path_next:
    li s10, 64
    add s0, s0, s10
    li s10, 1
    sub s1, s1, s10
    RV_JUMP .Lp_new_path_loop
.Lp_new_path_cli:
    /* Reserve filesystem aliases of asm, including Unicode case aliases. */
    RV_ADDR a0, program_reserved_path
    li a1, 0
    RV_CALL program_walk_parent
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1248
    RV_JUMP .Lp_new_path_probe
.Lrv_tb_skip_programs1248:
    mv s2, t0
    mv a0, s2
    RV_ADDR a1, program_alias_record_stat
    RV_CALL rv_fstat
    mv s4, t0
    mv a0, s2
    RV_CALL rv_close
    srli s8, s4, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1256
    RV_JUMP program_path_error
.Lrv_tb_skip_programs1256:
    RV_ADDR a0, program_alias_parent_stat
    RV_ADDR a1, program_alias_record_stat
    RV_CALL program_same_identity
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1260
    RV_JUMP .Lp_new_path_probe
.Lrv_cb_skip_programs1260:
    RV_ADDR t1, program_cli_name
    RV_ADDR s6, program_alias_names
    mv s10, s3
    slli s10, s10, 3
    add s8, s6, s10
    RV_STORE t1, 8
    li s10, 1
    add s3, s3, s10
.Lp_new_path_probe:
    mv s8, s3
    bnez s8, .Lrv_cb_skip_programs1266
    RV_JUMP .Lp_new_path_done
.Lrv_cb_skip_programs1266:
    P_STORE s3, program_alias_count
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    RV_IMM a2, O_NOFOLLOW + O_CLOEXEC + 193, 64
    li a6, 0
    RV_CALL rv_openat
    mv s8, t0
    li s10, 17
    RV_FLAGS add, 64
    RV_BCOND eq, program_destination_exists
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1275
    RV_JUMP program_probe_error
.Lrv_tb_skip_programs1275:
    P_STORE t0, program_probe_fd
    P_SET 1, program_probe_active
    mv a0, t0
    RV_ADDR a1, program_probe_stat
    RV_CALL rv_probe_fd_stat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1281
    RV_JUMP program_probe_error
.Lrv_tb_skip_programs1281:
    li s5, 0
.Lp_new_path_lookup:
    RV_ADDR s6, program_alias_names
    mv s10, s5
    slli s10, s10, 3
    add s8, s6, s10
    RV_LOAD a1, 8
    P_LOAD a0, program_dest_fd
    RV_ADDR a2, program_probe_entry_stat
    li a6, 256
    RV_CALL rv_probe_stat
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_new_path_lookup_next
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1292
    RV_JUMP program_probe_error
.Lrv_tb_skip_programs1292:
    RV_ADDR a0, program_probe_stat
    RV_ADDR a1, program_probe_entry_stat
    RV_CALL program_same_identity
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1296
    RV_JUMP .Lp_new_path_collision
.Lrv_cb_skip_programs1296:
.Lp_new_path_lookup_next:
    li s10, 1
    add s5, s5, s10
    mv s8, s5
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lp_new_path_lookup
    RV_CALL program_remove_probe
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs1302
    RV_JUMP program_probe_error
.Lrv_cb_skip_programs1302:
.Lp_new_path_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
.Lp_new_path_collision:
    RV_CALL program_remove_probe
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs1313
    RV_JUMP program_probe_error
.Lrv_cb_skip_programs1313:
    RV_ADDR s6, program_alias_names
    mv s10, s5
    slli s10, s10, 3
    add s8, s6, s10
    RV_LOAD t1, 8
    RV_ADDR t2, program_cli_name
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, program_reserved_error
    RV_JUMP program_destination_exists
/* a0/a1=normalized stat structures. t0=1 only for equal device and inode.
 * Identity comparison grants no ownership, permission, or digest result.
 * No stack or writes; scratch t1/t2. */
program_same_identity:
    li s10, RV_STAT_DEVICE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_DEVICE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_identity_different
    li s10, RV_STAT_INODE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_INODE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_identity_different
    li t0, 1
    RV_ZEXT t0
    ret
.Lp_identity_different:
    li t0, 0
    RV_ZEXT t0
    ret
/* Remove only a destination that still identifies the held exclusive probe.
 * A replacement entry is retained. ENOENT means absence already holds.
 * t0=0 on restored absence, -1 if inspection/removal/close fails. Never exits.
 * The probe FD is closed on every path. Same-UID races remain outside the
 * advisory-lock contract; identity is rechecked before each unlink attempt.
 * Stack: two saved registers. No writes to file contents or inventory.
 */
program_remove_probe:
    RV_SAVE s0
    RV_SAVE s1
    li s1, 0
    P_LOAD t1, program_probe_active
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs1351
    RV_JUMP .Lp_probe_remove_done
.Lrv_cb_skip_programs1351:
    P_LOAD s0, program_probe_fd
    srli s8, s0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1353
    RV_JUMP .Lp_probe_remove_bad
.Lrv_tb_skip_programs1353:
    mv a0, s0
    RV_ADDR a1, program_probe_stat
    RV_CALL rv_probe_fd_stat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1357
    RV_JUMP .Lp_probe_remove_bad
.Lrv_tb_skip_programs1357:
.Lp_probe_remove_check:
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    RV_ADDR a2, program_probe_entry_stat
    li a6, 256
    RV_CALL rv_probe_stat
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_probe_remove_close
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1366
    RV_JUMP .Lp_probe_remove_bad
.Lrv_tb_skip_programs1366:
    RV_ADDR a0, program_probe_stat
    RV_ADDR a1, program_probe_entry_stat
    RV_CALL program_same_identity
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1370
    RV_JUMP .Lp_probe_remove_bad
.Lrv_cb_skip_programs1370:
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    li a2, 0
    RV_CALL rv_unlinkat
    mv s8, t0
    li s10, 4
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_probe_remove_check
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1377
    RV_JUMP .Lp_probe_remove_bad
.Lrv_tb_skip_programs1377:
    RV_JUMP .Lp_probe_remove_close
.Lp_probe_remove_bad:
    li s1, -1
.Lp_probe_remove_close:
    P_LOAD a0, program_probe_fd
    srli s8, a0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1383
    RV_JUMP .Lp_probe_remove_clear
.Lrv_tb_skip_programs1383:
    RV_CALL rv_close
    srli s8, t0, 63
    andi s8, s8, 1
    bnez s8, .Lrv_tb_skip_programs1385
    RV_JUMP .Lp_probe_remove_clear
.Lrv_tb_skip_programs1385:
    li s1, -1
.Lp_probe_remove_clear:
    P_SET -1, program_probe_fd
    P_SET 0, program_probe_active
.Lp_probe_remove_done:
    mv t0, s1
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=normalized stat; t0=1 for protected single-link user regular files.
 * No stack. File execute permission is checked separately for destinations. */
program_regular_stat:
    li s10, RV_STAT_MODE
    add s8, a0, s10
    RV_LOAD t1, 4
    li s10, 61440
    and t2, t1, s10
    RV_ZEXT t2
    mv s8, t2
    li s10, 32768
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_regular_bad
    li t2, 3090
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lp_regular_bad
    li s10, RV_STAT_LINKS
    add s8, a0, s10
    RV_LOAD t2, 4
    mv s8, t2
    li s10, 1
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_regular_bad
    li s10, RV_STAT_UID
    add s8, a0, s10
    RV_LOAD t2, 4
    P_LOAD t3, program_uid
    mv s8, t2
    mv s10, t3
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_regular_bad
    li t0, 1
    RV_ZEXT t0
    ret
.Lp_regular_bad:
    li t0, 0
    RV_ZEXT t0
    ret
/* Opens current executable by held parent FD. Copies it to the private registry
 * payload for hashing through the mature fixed-argv adapter, then removes the
 * snapshot. Keeps current_fd and original stat for backup/recheck. Requires
 * size/hash match; never executes the program. Stack: four saved registers. */
program_check_existing:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    P_LOAD s0, program_found
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_ADDR a1, registry_host
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1432
    RV_JUMP program_changed_file
.Lrv_cb_skip_programs1432:
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    RV_IMM a2, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 64
    li a6, 0
    RV_CALL rv_openat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1438
    RV_JUMP program_changed_file
.Lrv_tb_skip_programs1438:
    mv s2, t0
    P_STORE t0, program_current_fd
    mv a0, s2
    RV_ADDR a1, program_current_stat
    RV_CALL rv_fstat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1444
    RV_JUMP program_changed_file
.Lrv_tb_skip_programs1444:
    RV_ADDR a0, program_current_stat
    RV_CALL program_regular_stat
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1447
    RV_JUMP program_changed_file
.Lrv_cb_skip_programs1447:
    RV_ADDR s6, program_current_stat
    li s10, RV_STAT_MODE
    add s8, s6, s10
    RV_LOAD t1, 4
    mv s8, t1
    li s10, 64
    RV_FLAGS and, 32
    RV_BCOND eq, program_changed_file
    P_STORE t1, program_current_mode
    li s10, 32
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_size_value
    RV_ADDR s6, program_current_stat
    li s10, RV_STAT_SIZE
    add s8, s6, s10
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, t0
    RV_FLAGS sub, 64
    RV_BCOND ne, program_changed_file
    RV_CALL registry_workspace
    RV_ADDR a0, registry_temp_payload
    RV_IMM a1, O_NOFOLLOW + O_CLOEXEC + 193, 64
    li a2, 384
    RV_CALL rv_open
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1464
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1464:
    mv s3, t0
    mv a0, s2
    mv a1, s3
    RV_CALL program_copy_fds
    mv s1, t0
    mv a0, s3
    RV_CALL rv_close
    mv s8, s1
    beqz s8, .Lrv_cb_skip_programs1472
    RV_JUMP program_io_error
.Lrv_cb_skip_programs1472:
    RV_CALL pub_hash_payload
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1474
    RV_JUMP program_changed_file
.Lrv_cb_skip_programs1474:
    RV_ADDR a0, pub_hash_buffer
    li s10, 24
    add s8, s0, s10
    RV_LOAD a1, 8
    li a2, 64
.Lp_existing_digest:
    mv s8, a0
    RV_LOAD t1, 1
    li s10, 1
    add a0, a0, s10
    mv s8, a1
    RV_LOAD t2, 1
    li s10, 1
    add a1, a1, s10
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, program_changed_file
    mv s8, a2
    li s10, 1
    RV_FLAGS sub, 64
    mv a2, s11
    RV_BCOND ne, .Lp_existing_digest
    RV_ADDR a0, registry_temp_payload
    RV_CALL rv_unlink
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1487
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1487:
    RV_CALL program_check_existing_claims
    RV_CALL program_recheck_destination
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Refuse mutation when another valid inventory row names the held file.
 * Input: trusted program_current_stat and program_found; <=128 parsed rows.
 * Walk each other parent and perform raw nofollow identity lookup. No file is
 * created or changed. Missing paths cannot claim this existing inode; other
 * lookup failures fail closed. A matching device/inode is ambiguous state.
 * Owns each temporary parent FD until its immediate close. Scratch stat is
 * program_alias_record_stat. Stack: four saved registers. Listing never calls
 * this routine and continues to report recorded metadata without filesystem IO.
 */
program_check_existing_claims:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s0, program_rows
    P_LOAD s1, program_count
.Lp_existing_claim_loop:
    mv s8, s1
    bnez s8, .Lrv_cb_skip_programs1513
    RV_JUMP .Lp_existing_claim_done
.Lrv_cb_skip_programs1513:
    P_LOAD t1, program_found
    mv s8, s0
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_existing_claim_next
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    li a1, 0
    RV_CALL program_walk_parent
    mv s8, t0
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_existing_claim_next
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1522
    RV_JUMP program_path_error
.Lrv_tb_skip_programs1522:
    mv s2, t0
    mv a0, s2
    P_LOAD a1, program_basename
    RV_ADDR a2, program_alias_record_stat
    li a6, 256
    RV_CALL rv_probe_stat
    mv s3, t0
    mv a0, s2
    RV_CALL rv_close
    mv s8, s3
    li s10, 2
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_existing_claim_next
    srli s8, s3, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1534
    RV_JUMP program_state_error
.Lrv_tb_skip_programs1534:
    RV_ADDR a0, program_current_stat
    RV_ADDR a1, program_alias_record_stat
    RV_CALL program_same_identity
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_programs1538
    RV_JUMP program_state_error
.Lrv_cb_skip_programs1538:
.Lp_existing_claim_next:
    li s10, 64
    add s0, s0, s10
    li s10, 1
    sub s1, s1, s10
    RV_JUMP .Lp_existing_claim_loop
.Lp_existing_claim_done:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Require unchanged destination identity/mode/size immediately before mutation.
 * Descriptor-relative nofollow stat. Stack: no local reservation. */
program_recheck_destination:
    P_LOAD a0, program_dest_fd
    P_LOAD a1, program_dest_name
    RV_ADDR a2, program_check_stat
    li a6, 256
    RV_CALL rv_newfstatat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1558
    RV_JUMP program_changed_file
.Lrv_tb_skip_programs1558:
    RV_ADDR a0, program_check_stat
    RV_CALL program_regular_stat
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1561
    RV_JUMP program_changed_file
.Lrv_cb_skip_programs1561:
    RV_ADDR a0, program_current_stat
    RV_ADDR a1, program_check_stat
    li s10, RV_STAT_DEVICE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_DEVICE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, program_changed_file
    li s10, RV_STAT_INODE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_INODE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, program_changed_file
    li s10, RV_STAT_SIZE
    add s8, a0, s10
    RV_LOAD t1, 8
    li s10, RV_STAT_SIZE
    add s8, a1, s10
    RV_LOAD t2, 8
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, program_changed_file
    li s10, RV_STAT_MODE
    add s8, a0, s10
    RV_LOAD t1, 4
    li s10, RV_STAT_MODE
    add s8, a1, s10
    RV_LOAD t2, 4
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, program_changed_file
    ret
/* a0=input FD, a1=output FD; t0=0/-1. Copies <=64MiB and retries EINTR and
 * short writes with write_all. Caller owns both FDs. Stack: four saves. */
program_copy_fds:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    mv s0, a0
    mv s1, a1
    li s2, 0
.Lp_copy_read:
    mv a0, s0
    RV_ADDR a1, registry_copy_buffer
    li a2, 65536
    RV_CALL rv_read
    mv s8, t0
    li s10, 4
    RV_FLAGS add, 64
    RV_BCOND eq, .Lp_copy_read
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1599
    RV_JUMP .Lp_copy_bad
.Lrv_tb_skip_programs1599:
    mv s8, t0
    bnez s8, .Lrv_cb_skip_programs1600
    RV_JUMP .Lp_copy_ok
.Lrv_cb_skip_programs1600:
    mv s10, t0
    add s2, s2, s10
    RV_IMM t1, 67108864, 64
    mv s8, s2
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lp_copy_bad
    mv a2, t0
    mv a0, s1
    RV_ADDR a1, registry_copy_buffer
    RV_CALL write_all
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1609
    RV_JUMP .Lp_copy_bad
.Lrv_tb_skip_programs1609:
    RV_JUMP .Lp_copy_read
.Lp_copy_bad:
    li t0, -1
    RV_JUMP .Lp_copy_done
.Lp_copy_ok:
    li t0, 0
.Lp_copy_done:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Exclusive stage lives in the destination's filesystem. Its predictable PID
 * name is safe because mkdirat must create it. Never reuses an existing path.
 * Stack: none beyond nested link frames. */
program_make_stage:
    RV_ADDR a0, program_stage_name
    RV_ADDR a1, program_stage_prefix
    RV_CALL copy_string
    P_STORE t0, program_append
    RV_CALL rv_getpid
    mv a0, t0
    RV_ADDR a1, program_number + 31
    RV_CALL unsigned_decimal
    mv a1, t0
    P_LOAD a0, program_append
    RV_CALL copy_string
    P_LOAD a0, program_dest_fd
    RV_ADDR a1, program_stage_name
    li a2, 448
    RV_CALL rv_mkdirat
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs1642
    RV_JUMP program_io_error
.Lrv_cb_skip_programs1642:
    P_SET 1, program_stage_created
    P_LOAD a0, program_dest_fd
    RV_ADDR a1, program_stage_name
    RV_IMM a2, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC, 64
    li a6, 0
    RV_CALL rv_openat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1649
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1649:
    P_STORE t0, program_stage_fd
    ret
/* a0=stage directory FD, a1=fixed file name, a2=mode, s2=source FD.
 * t0=0/-1; copies, chmods and fsyncs an exclusive file. Stack: three saves.
 * Backup mode is retained, but rollback may create a different inode. */
program_copy_into_stage:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s3
    mv s1, a2
    RV_IMM a2, O_NOFOLLOW + O_CLOEXEC + 193, 64
    li a6, 384
    RV_CALL rv_openat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1664
    RV_JUMP .Lp_stage_copy_bad
.Lrv_tb_skip_programs1664:
    mv s0, t0
    mv a0, s2
    mv a1, s0
    RV_CALL program_copy_fds
    mv s8, t0
    beqz s8, .Lrv_cb_skip_programs1669
    RV_JUMP .Lp_stage_copy_close_bad
.Lrv_cb_skip_programs1669:
    mv a0, s0
    mv a1, s1
    RV_CALL rv_fchmod
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1673
    RV_JUMP .Lp_stage_copy_close_bad
.Lrv_tb_skip_programs1673:
    mv a0, s0
    RV_CALL rv_fsync
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1676
    RV_JUMP .Lp_stage_copy_close_bad
.Lrv_tb_skip_programs1676:
    mv a0, s0
    RV_CALL rv_close
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1679
    RV_JUMP .Lp_stage_copy_bad
.Lrv_tb_skip_programs1679:
    li t0, 0
    RV_JUMP .Lp_stage_copy_done
.Lp_stage_copy_close_bad:
    mv a0, s0
    RV_CALL rv_close
.Lp_stage_copy_bad:
    li t0, -1
.Lp_stage_copy_done:
    RV_RESTORE s3
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Serialize a complete replacement inventory to an exclusive temporary file
 * under the locked state FD. Removal skips found; upgrade replaces found;
 * install appends new_row. File fsync precedes any executable mutation.
 * Stack: four saved registers. Total output remains <=1 MiB. */
program_write_state:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR a0, program_state_temp
    RV_ADDR a1, program_state_prefix
    RV_CALL copy_string
    P_STORE t0, program_append
    RV_CALL rv_getpid
    mv a0, t0
    RV_ADDR a1, program_number + 31
    RV_CALL unsigned_decimal
    mv a1, t0
    P_LOAD a0, program_append
    RV_CALL copy_string
    P_LOAD a0, program_state_fd
    RV_ADDR a1, program_state_temp
    RV_IMM a2, O_NOFOLLOW + O_CLOEXEC + 193, 64
    li a6, 384
    RV_CALL rv_openat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1718
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1718:
    mv s0, t0
    P_STORE t0, program_temp_fd
    P_SET 1, program_state_created
    P_SET 0, program_written
    RV_ADDR a1, program_header
    RV_CALL program_write_piece
    RV_ADDR s1, program_rows
    P_LOAD s2, program_count
.Lp_write_row:
    mv s8, s2
    bnez s8, .Lrv_cb_skip_programs1728
    RV_JUMP .Lp_write_append
.Lrv_cb_skip_programs1728:
    P_LOAD t1, program_found
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lp_write_old
    P_LOAD t1, program_remove
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs1733
    RV_JUMP .Lp_write_next
.Lrv_cb_skip_programs1733:
    RV_ADDR a0, program_new_row
    RV_JUMP .Lp_write_emit
.Lp_write_old:
    mv a0, s1
.Lp_write_emit:
    RV_CALL program_write_row
.Lp_write_next:
    li s10, 64
    add s1, s1, s10
    li s10, 1
    sub s2, s2, s10
    RV_JUMP .Lp_write_row
.Lp_write_append:
    P_LOAD t1, program_found
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs1746
    RV_JUMP .Lp_write_sync
.Lrv_cb_skip_programs1746:
    RV_ADDR a0, program_new_row
    RV_CALL program_write_row
.Lp_write_sync:
    mv a0, s0
    RV_CALL rv_fsync
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1752
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1752:
    mv a0, s0
    RV_CALL rv_close
    P_SET -1, program_temp_fd
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1756
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1756:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* a0=seven-pointer row; s0=output FD. Stack: two saves. */
program_write_row:
    RV_SAVE s1
    RV_SAVE s2
    mv s1, a0
    li s2, 0
.Lp_write_field:
    mv s10, s2
    slli s10, s10, 3
    add s8, s1, s10
    RV_LOAD a1, 8
    RV_CALL program_write_piece
    li s10, 1
    add s2, s2, s10
    mv s8, s2
    li s10, 7
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lp_write_row_end
    RV_ADDR a1, registry_tab
    RV_CALL program_write_piece
    RV_JUMP .Lp_write_field
.Lp_write_row_end:
    RV_ADDR a1, registry_newline
    RV_CALL program_write_piece
    RV_RESTORE s2
    RV_RESTORE s1
    ret
/* a1=NUL text, s0=FD. Bounds cumulative bytes; stack: one save. */
program_write_piece:
    RV_SAVE s1
    mv s1, a1
    mv a0, a1
    RV_CALL strlen
    P_LOAD t1, program_written
    mv s10, t0
    add t1, t1, s10
    RV_IMM t2, PROGRAM_STATE_LIMIT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, program_state_error
    P_STORE t1, program_written
    mv a0, s0
    mv a1, s1
    RV_CALL write_cstr
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1798
    RV_JUMP program_io_error
.Lrv_tb_skip_programs1798:
    RV_RESTORE s1
    ret
/* Final inventory replacement. t0=rename result; no fatal branch, so callers
 * can roll back their executable mutation before reporting any error. */
program_commit_state:
    P_LOAD a0, program_state_fd
    RV_ADDR a1, program_state_temp
    mv a2, a0
    RV_ADDR a6, program_state_name
    RV_CALL rv_renameat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1809
    RV_JUMP .Lp_state_commit_done
.Lrv_tb_skip_programs1809:
    P_SET 0, program_state_created
.Lp_state_commit_done:
    ret
/* Stable native inventory output. Parse errors have already failed without
 * stdout. JSON encodes paths through the shared bounded encoder. Stack: 3 saves. */
program_list:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    P_BYTE t1, json_mode
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_programs1821
    RV_JUMP .Lp_list_text
.Lrv_cb_skip_programs1821:
    RV_ADDR a0, program_list_prefix
    RV_CALL out
    RV_ADDR s0, program_rows
    P_LOAD s1, program_count
    li s2, 0
.Lp_list_json_row:
    mv s8, s1
    bnez s8, .Lrv_cb_skip_programs1828
    RV_JUMP .Lp_list_json_done
.Lrv_cb_skip_programs1828:
    mv s8, s2
    bnez s8, .Lrv_cb_skip_programs1829
    RV_JUMP .Lp_list_json_first
.Lrv_cb_skip_programs1829:
    RV_ADDR a0, registry_comma
    RV_CALL out
.Lp_list_json_first:
    RV_ADDR a0, program_json_package
    RV_CALL out
    mv s8, s0
    RV_LOAD a0, 8
    RV_CALL registry_json_string
    RV_ADDR a0, program_json_version
    RV_CALL out
    li s10, 8
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_json_string
    RV_ADDR a0, program_json_target
    RV_CALL out
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_json_string
    RV_ADDR a0, program_json_sha
    RV_CALL out
    li s10, 24
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_json_string
    RV_ADDR a0, program_json_bytes
    RV_CALL out
    li s10, 32
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL out
    RV_ADDR a0, program_json_path
    RV_CALL out
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_json_string
    RV_ADDR a0, program_json_registry
    RV_CALL out
    li s10, 48
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL registry_json_string
    RV_ADDR a0, registry_rbrace
    RV_CALL out
    li s10, 64
    add s0, s0, s10
    li s10, 1
    sub s1, s1, s10
    li s2, 1
    RV_JUMP .Lp_list_json_row
.Lp_list_json_done:
    RV_ADDR a0, program_list_suffix
    RV_CALL out
    RV_JUMP .Lp_list_done
.Lp_list_text:
    P_LOAD s1, program_count
    mv s8, s1
    beqz s8, .Lrv_cb_skip_programs1873
    RV_JUMP .Lp_list_text_rows
.Lrv_cb_skip_programs1873:
    RV_ADDR a0, program_empty_text
    RV_CALL out
    RV_JUMP .Lp_list_done
.Lp_list_text_rows:
    RV_ADDR s0, program_rows
.Lp_list_text_row:
    mv s8, s0
    RV_LOAD a0, 8
    RV_CALL out
    RV_ADDR a0, program_at
    RV_CALL out
    li s10, 8
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL out
    RV_ADDR a0, registry_tab
    RV_CALL out
    li s10, 16
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL out
    RV_ADDR a0, registry_tab
    RV_CALL out
    li s10, 40
    add s8, s0, s10
    RV_LOAD a0, 8
    RV_CALL out
    RV_ADDR a0, registry_newline
    RV_CALL out
    li s10, 64
    add s0, s0, s10
    mv s8, s1
    li s10, 1
    RV_FLAGS sub, 64
    mv s1, s11
    RV_BCOND ne, .Lp_list_text_row
.Lp_list_done:
    RV_CALL registry_cleanup
    RV_JUMP exit_ok
/* Cleanup closes only owned descriptors and removes only invocation-owned
 * stage names. A failed rollback retains its backup directory for recovery.
 * Cleanup failure cannot replace an earlier error. Stack: one saved register. */
program_cleanup:
    RV_SAVE s0
    RV_CALL program_remove_probe
    P_LOAD a0, program_temp_fd
    srli s8, a0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1910
    RV_JUMP .Lp_cleanup_temp_name
.Lrv_tb_skip_programs1910:
    RV_CALL rv_close
    P_SET -1, program_temp_fd
.Lp_cleanup_temp_name:
    P_LOAD t1, program_state_created
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs1915
    RV_JUMP .Lp_cleanup_stage
.Lrv_cb_skip_programs1915:
    P_LOAD a0, program_state_fd
    RV_ADDR a1, program_state_temp
    li a2, 0
    RV_CALL rv_unlinkat
    P_SET 0, program_state_created
.Lp_cleanup_stage:
    P_LOAD t1, program_keep_stage
    mv s8, t1
    beqz s8, .Lrv_cb_skip_programs1923
    RV_JUMP .Lp_cleanup_close
.Lrv_cb_skip_programs1923:
    P_LOAD a0, program_stage_fd
    srli s8, a0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1925
    RV_JUMP .Lp_cleanup_stage_dir
.Lrv_tb_skip_programs1925:
    RV_ADDR a1, program_candidate
    li a2, 0
    RV_CALL rv_unlinkat
    P_LOAD a0, program_stage_fd
    RV_ADDR a1, program_previous
    li a2, 0
    RV_CALL rv_unlinkat
.Lp_cleanup_stage_dir:
    P_LOAD t1, program_stage_created
    mv s8, t1
    bnez s8, .Lrv_cb_skip_programs1935
    RV_JUMP .Lp_cleanup_close
.Lrv_cb_skip_programs1935:
    P_LOAD a0, program_dest_fd
    RV_ADDR a1, program_stage_name
    li a2, 512
    RV_CALL rv_unlinkat
    P_SET 0, program_stage_created
.Lp_cleanup_close:
    RV_ADDR s0, program_fds
    li t1, 4
    P_STORE t1, program_cleanup_count
.Lp_cleanup_fd:
    mv s8, s0
    RV_LOAD a0, 8
    srli s8, a0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_programs1947
    RV_JUMP .Lp_cleanup_fd_next
.Lrv_tb_skip_programs1947:
    RV_CALL rv_close
    li t1, -1
    mv s8, s0
    RV_STORE t1, 8
.Lp_cleanup_fd_next:
    li s10, 8
    add s0, s0, s10
    P_LOAD t1, program_cleanup_count
    mv s8, t1
    li s10, 1
    RV_FLAGS sub, 64
    mv t1, s11
    P_STORE t1, program_cleanup_count
    RV_BCOND ne, .Lp_cleanup_fd
    RV_RESTORE s0
    ret
program_help:
    RV_ADDR a0, program_help_text
    RV_CALL out
    RV_JUMP exit_ok
program_bad_args:
    RV_ADDR a0, program_error_args
    li a1, 2
    RV_JUMP registry_fail
program_path_error:
    RV_ADDR a0, program_error_path
    RV_JUMP program_error
program_state_error:
    RV_ADDR a0, program_error_state
    RV_JUMP program_error
program_busy_error:
    RV_ADDR a0, program_error_busy
    RV_JUMP program_error
program_not_managed:
    RV_ADDR a0, program_error_unmanaged
    RV_JUMP program_error
program_already_managed:
    RV_ADDR a0, program_error_already
    RV_JUMP program_error
program_local_index_error:
    RV_ADDR a0, program_error_local
    RV_JUMP program_error
program_origin_error:
    RV_ADDR a0, program_error_origin
    RV_JUMP program_error
program_downgrade_error:
    RV_ADDR a0, program_error_downgrade
    RV_JUMP program_error
program_changed_release:
    RV_ADDR a0, program_error_release
    RV_JUMP program_error
program_changed_file:
    RV_ADDR a0, program_error_changed
    RV_JUMP program_error
program_destination_exists:
    RV_ADDR a0, program_error_exists
    RV_JUMP program_error
program_reserved_error:
    RV_ADDR a0, program_error_reserved
    RV_JUMP program_error
program_internal_error:
    RV_ADDR a0, program_error_internal
    RV_JUMP program_error
program_recovery_error:
    P_SET 1, program_keep_stage
    RV_ADDR a0, program_error_recovery
    RV_JUMP program_error
program_probe_error:
    RV_ADDR a0, program_error_probe
    RV_JUMP program_error
program_io_error:
    RV_ADDR a0, program_error_io
program_error:
    li a1, 1
    RV_JUMP registry_fail
.section .rodata
program_header: .asciz "# asm-installed-v1\n"
program_state_suffix: .asciz "/.local/state/asm/installed.tsv"
program_state_name: .asciz "installed.tsv"
program_state_prefix: .asciz ".installed-"
program_stage_prefix: .asciz ".asm-program-"
program_reserved_suffix: .asciz "/.local/bin/asm"
program_candidate: .asciz "candidate"
program_cli_name: .asciz "asm"
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
program_error_probe: .asciz "the program name check failed; inspect the new destination for an empty nonexecutable file before retrying"
program_error_io: .asciz "program management could not finish; check free space, directory permissions, and retained .asm-program-PID stages"
.section .data
.balign 8
program_fds:
program_state_fd: .quad -1
program_dest_fd: .quad -1
program_stage_fd: .quad -1
program_current_fd: .quad -1
program_temp_fd: .quad -1
program_probe_fd: .quad -1
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
program_probe_active: .skip 8
program_alias_count: .skip 8
program_number: .skip 32
program_state_temp: .skip 64
program_stage_name: .skip 64
program_new_row: .skip 64
program_walk_stat: .skip RV_STAT_BYTES
program_check_stat: .skip RV_STAT_BYTES
program_current_stat: .skip RV_STAT_BYTES
program_probe_stat: .skip RV_STAT_BYTES
program_probe_entry_stat: .skip RV_STAT_BYTES
program_alias_parent_stat: .skip RV_STAT_BYTES
program_alias_record_stat: .skip RV_STAT_BYTES
program_alias_names: .skip (PROGRAM_LIMIT + 1) * 8
program_state_path: .skip 4096
program_reserved_path: .skip 4096
program_path: .skip 4096
program_cwd: .skip 4096
program_rows: .skip PROGRAM_LIMIT * 64
program_input: .skip PROGRAM_STATE_LIMIT + 1
.section .note.GNU-stack,""
