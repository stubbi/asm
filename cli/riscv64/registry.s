/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/registry.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global cmd_search, cmd_info, cmd_versions, cmd_fetch, cmd_install
.extern next_arg, streq, strlen, copy_string, out, write_cstr, write_all
.extern die, exit_ok, exit_code, spawn_wait, unsigned_decimal
.extern create_exclusive_file, json_mode
/* Registry v1 is a bounded TSV protocol. All parsing and decisions are native
 * assembly. curl supplies HTTPS; sha256sum supplies the digest implementation.
 * Package contents are never extracted or executed by fetch.
 * ABI: returning routines preserve s0, s1 and s2-s5. t0, a3, a2, a1,
 * a0 and a4-a7 are scratch unless a narrower set is stated. Command/error
 * labels do not return. The executable uses Linux RISC-V64 syscalls, not libc.
 * Each borrowed string must end in accessible NUL memory. argv comes from the
 * kernel. Index strings are bounded and terminated by registry_parse_index.
 */
.equ INDEX_LIMIT, 1048576
.equ ROW_LIMIT, 4096
.equ REGISTRY_OUTPUT_LIMIT, 65536
.equ ARTIFACT_LIMIT, 67108864
.equ AT_FDCWD, -100
/* Native RISC-V64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each RV_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */
.section .text
cmd_search:
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
cmd_info:
    RV_IMM t1, 2, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
cmd_versions:
    RV_IMM t1, 3, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
cmd_fetch:
    RV_IMM t1, 4, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP registry_command
cmd_install:
    RV_IMM t1, 5, 32
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_STORE t1, 1
/* Command entry: global argv cursor follows the command name. Parses options
 * before filesystem/network work. Owns the global registry_* buffers for the
 * process lifetime. Commands terminate the process; no caller stack survives. */
registry_command:
    RV_ADDR s6, registry_default_url
    mv t0, s6
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_host
    mv t0, s6
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_source_kind
    mv t0, s6
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 5, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lregistry_kind_default
    RV_ADDR s6, registry_executable_kind
    mv t0, s6
.Lregistry_kind_default:
    RV_ADDR s6, registry_kind
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_empty
    mv t0, s6
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_STORE t0, 8
.Lregistry_args:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lregistry_args_done
    mv s2, t0
    RV_ADDR s6, registry_literal
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
    RV_BCOND ne, .Lregistry_query_arg
    mv a0, s2
    RV_ADDR s6, registry_opt_json
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_json
    mv a0, s2
    RV_ADDR s6, registry_opt_no_color
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_args
    mv a0, s2
    RV_ADDR s6, registry_opt_help
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_help
    mv a0, s2
    RV_ADDR s6, registry_separator
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_separator
    mv a0, s2
    RV_ADDR s6, registry_opt_index
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_index
    mv a0, s2
    RV_ADDR s6, registry_opt_registry
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_registry
    mv a0, s2
    RV_ADDR s6, registry_opt_target
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_target
    mv a0, s2
    RV_ADDR s6, registry_opt_kind
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_kind
    mv a0, s2
    RV_ADDR s6, registry_opt_output
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_output
    mv a0, s2
    RV_ADDR s6, registry_opt_artifact
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lregistry_arg_artifact
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
    RV_BCOND eq, registry_bad_args
.Lregistry_query_arg:
    RV_ADDR s6, registry_has_query
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
    RV_BCOND ne, registry_bad_args
    mv a0, s2
    RV_CALL strlen
    RV_IMM t2, 168, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_bad_args
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_STORE s2, 8
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_has_query
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lregistry_args
.Lregistry_arg_json:
    RV_IMM t1, 1, 32
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lregistry_args
.Lregistry_arg_separator:
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_literal
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lregistry_args
.Lregistry_arg_index:
    RV_ADDR s6, registry_origin_seen
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
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_local_index
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_origin_seen
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lregistry_args
.Lregistry_arg_registry:
    RV_ADDR s6, registry_origin_seen
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
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_CALL registry_https_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_origin_seen
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lregistry_args
.Lregistry_arg_target:
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_CALL registry_valid_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Lregistry_args
.Lregistry_arg_kind:
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_kind
    mv s8, s6
    RV_STORE t0, 8
    mv a0, t0
    RV_CALL registry_valid_kind
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Lregistry_args
.Lregistry_arg_output:
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Lregistry_args
.Lregistry_arg_artifact:
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_CALL registry_arg_value
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_STORE t0, 8
    RV_JUMP .Lregistry_args
.Lregistry_args_done:
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 4, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lregistry_fetch_args
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_ADDR s6, registry_mode
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
    RV_BCOND eq, .Lregistry_load
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Lregistry_load
.Lregistry_fetch_args:
    RV_ADDR s6, registry_selector
    mv a0, s6
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    RV_ADDR s6, registry_selector
    mv a0, s6
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_STORE a0, 8
    mv a1, a0
.Lselector_scan:
    mv s6, a1
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
    RV_BCOND eq, .Lselector_package
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 64, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lselector_version
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_JUMP .Lselector_scan
.Lselector_version:
    RV_IMM t1, 0, 32
    mv s6, a1
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_STORE a1, 8
    mv a0, a1
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
.Lselector_package:
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 6, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Ldependency_args
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 5, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lregistry_load
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_host
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_install_target_error
    RV_ADDR s6, registry_kind
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_executable_kind
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_JUMP .Lregistry_load
.Ldependency_args:
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, registry_bad_args
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_bad_args
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_host
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_install_target_error
    RV_ADDR s6, registry_kind
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_source_kind
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_args
    RV_CALL read_manifest
.Lregistry_load:
    P_BYTE t1, registry_mode
    mv s8, t1
    li s10, 5
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_registry_load_ready
    RV_CALL program_before_load
.Lp_registry_load_ready:
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lregistry_read
    RV_CALL registry_workspace
    RV_ADDR s6, registry_url
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_index
    mv a1, s6
    RV_ADDR s6, registry_index_max
    mv a2, s6
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_download_error
    RV_ADDR s6, registry_temp_index
    mv t0, s6
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_STORE t0, 8
.Lregistry_read:
    RV_CALL registry_read_index
    RV_CALL registry_parse_index
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 4, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, registry_fetch
    RV_JUMP registry_list
/* Input: argv cursor follows a value option. Output: t0=borrowed nonempty
 * string <=4095 bytes. Advances the cursor; exits 2 if absent or out of bounds.
 * Stack: one saved pointer. No filesystem or network effect. */
registry_arg_value:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, registry_bad_args
    mv a0, t0
    RV_SAVE t0
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, registry_bad_args
    RV_IMM t2, 4095, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_bad_args
    RV_RESTORE t0
    ret
registry_help:
    RV_ADDR s6, registry_help_text
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
registry_bad_args:
    RV_ADDR s6, registry_err_args
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_bad_index:
    RV_ADDR s6, registry_err_index
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_download_error:
    RV_ADDR s6, registry_err_download
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_io_error:
    RV_ADDR s6, registry_err_io
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_not_found:
    RV_ADDR s6, registry_err_not_found
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
/* Input: a0=static JSON-safe error, a1=status 1..255. Removes owned temporary
 * files before calling die. No return. Stack: saves the two inputs (32 bytes). */
registry_fail:
    RV_SAVE a0
    RV_SAVE a1
    RV_CALL registry_cleanup
    RV_RESTORE a1
    RV_RESTORE a0
    RV_JUMP die
/* Input: current working directory. Creates mode-0700 .asm-registry-<pid> only
 * if absent. Output: owned workspace and its three fixed paths, or fatal error.
 * Buffer capacities: directory=64, file paths=96; PID is <=20 decimal digits.
 * An existing path is never reused. Stack: one saved append pointer. */
registry_workspace:
    RV_ADDR s6, registry_has_workspace
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
    RV_BCOND ne, .Lworkspace_done
    RV_ADDR s6, registry_temp_dir
    mv a0, s6
    RV_ADDR s6, registry_temp_prefix
    mv a1, s6
    RV_CALL copy_string
    RV_SAVE t0
    RV_CALL rv_getpid
    mv a0, t0
    RV_ADDR s6, registry_number_buffer + 31
    mv a1, s6
    RV_CALL unsigned_decimal
    mv a1, t0
    RV_RESTORE a0
    RV_CALL copy_string
    RV_ADDR s6, registry_temp_dir
    mv a0, s6
    RV_IMM t1, 448, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_mkdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_has_workspace
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, registry_temp_index
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_index_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_payload_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, registry_temp_checksum
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_checksum_suffix
    mv a1, s6
    RV_CALL copy_string
.Lworkspace_done:
    ret
/* Input: ownership flag and fixed workspace paths. Unlinks only index, payload
 * and checksum, then removes the empty directory. Clears the ownership flag.
 * Does not replace an original error with a cleanup error. Stack: none. */
registry_cleanup:
    RV_CALL program_cleanup
    RV_ADDR s6, self_active
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
    RV_BCOND ne, self_update_cleanup
    RV_ADDR s6, registry_has_workspace
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
    RV_BCOND eq, .Lcleanup_done
    RV_ADDR s6, registry_extra_temp
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lcleanup_fixed_files
    RV_CALL rv_unlink
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_extra_temp
    mv s8, s6
    RV_STORE t1, 8
.Lcleanup_fixed_files:
    RV_ADDR s6, registry_temp_index
    mv a0, s6
    RV_CALL rv_unlink
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_CALL rv_unlink
    RV_ADDR s6, registry_temp_checksum
    mv a0, s6
    RV_CALL rv_unlink
    RV_ADDR s6, registry_temp_dir
    mv a0, s6
    RV_CALL rv_rmdir
    RV_IMM t1, 0, 32
    RV_ADDR s6, registry_has_workspace
    mv s8, s6
    RV_STORE t1, 1
.Lcleanup_done:
    ret
/* curl's config is disabled before all other options. Protocol and redirects
 * remain HTTPS-only. The caller supplies a validated URL and a bounded size. */
/* Input: a0=URL (<=4095 chars), a1=owned temporary output path (<=95 chars),
 * a2=decimal maximum bytes (1..67108864). Output: t0=child exit status or
 * 128+signal; size/fork/wait/limit/exec failure is 127. Missing curl is fatal.
 * Only the curl child lowers RLIMIT_FSIZE, independently of curl's handling
 * of Content-Length and streaming responses. Soft and hard values are each
 * capped without raising a stricter inherited limit. No other resource limit
 * changes. The parent, verifier, and hashing processes retain their limits.
 * Retries interrupted waits. Owns fixed 23-pointer argv; stack: 32 saved
 * bytes and 32 local bytes (16-byte Linux rlimit / child status + alignment).
 * Asm RISC-V64 callee-saved registers are preserved. No shell is involved. */
registry_download:
    RV_ADDR s6, registry_curl_argv + 21*8
    mv s8, s6
    RV_STORE a0, 8
    RV_ADDR s6, registry_curl_argv + 19*8
    mv s8, s6
    RV_STORE a1, 8
    RV_ADDR s6, registry_curl_argv + 17*8
    mv s8, s6
    RV_STORE a2, 8
    RV_ADDR s6, registry_curl
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcurl_missing
    RV_SAVE s0
    RV_SAVE s2
    li s10, 32
    sub sp, sp, s10
    RV_ADDR s6, registry_curl_argv + 17*8
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_size_value
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lcurl_failed
    mv s2, t0
    RV_CALL rv_fork
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcurl_failed
    RV_BCOND eq, .Lcurl_child
    mv s0, t0
.Lcurl_wait:
    mv a0, s0
    mv t1, sp
    mv a1, t1
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
    RV_BCOND eq, .Lcurl_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcurl_failed
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 4
    mv t0, t1
    RV_ZEXT t0
    mv a2, t0
    RV_ZEXT a2
    RV_IMM t2, 127, 32
    mv s10, t2
    and a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND ne, .Lcurl_signaled
    srliw t0, t0, 8
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_IMM t2, 255, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_JUMP .Lcurl_return
.Lcurl_signaled:
    mv s6, a2
    li s10, 128
    add s6, s6, s10
    mv t0, s6
    RV_ZEXT t0
    RV_JUMP .Lcurl_return
.Lcurl_child:
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    mv t1, sp
    mv a1, t1
    RV_CALL rv_getrlimit
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcurl_child_failed
    mv t0, s2
    mv s6, sp
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv s6, sp
    mv s8, s6
    RV_LOAD t2, 8
    RV_BCOND hi, .Lrv_csel_true_registry711
    mv t0, t0
    j .Lrv_csel_done_registry711
.Lrv_csel_true_registry711:
    mv t0, t2
.Lrv_csel_done_registry711:
    mv s6, sp
    mv s8, s6
    RV_STORE t0, 8
    mv t0, s2
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    RV_BCOND hi, .Lrv_csel_true_registry722
    mv t0, t0
    j .Lrv_csel_done_registry722
.Lrv_csel_true_registry722:
    mv t0, t2
.Lrv_csel_done_registry722:
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    mv t1, sp
    mv a1, t1
    RV_CALL rv_setrlimit
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcurl_child_failed
    RV_ADDR s6, registry_curl
    mv a0, s6
    RV_ADDR s6, registry_curl_argv
    mv a1, s6
    RV_ADDR s6, envp
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL rv_execve
.Lcurl_child_failed:
    RV_IMM t1, 127, 32
    mv a0, t1
    RV_ZEXT a0
    RV_JUMP exit_code
.Lcurl_failed:
    RV_IMM t1, 127, 32
    mv t0, t1
    RV_ZEXT t0
.Lcurl_return:
    li s10, 32
    add sp, sp, s10
    RV_RESTORE s2
    RV_RESTORE s0
    ret
.Lcurl_missing:
    RV_ADDR s6, registry_err_curl
    mv a0, s6
    RV_IMM t1, 127, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
/* Input: registry_index_path. Reads only a regular non-symlink file, bounded to
 * 1 MiB. Output: index bytes plus NUL, registry_index_end exclusive. Retries
 * EINTR/short reads; growth beyond the bound fails. Stack: 32 saved bytes. */
registry_read_index:
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s6, registry_index_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 32
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
    RV_BCOND mi, registry_io_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lindex_read_error
    RV_ADDR s6, registry_stat + RV_STAT_MODE
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
    RV_BCOND ne, .Lindex_read_error
    RV_ADDR s6, registry_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, INDEX_LIMIT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lindex_read_error
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Lindex_read_loop:
    mv a0, s2
    RV_ADDR s6, registry_index
    mv a1, s6
    mv s8, a1
    mv s10, s3
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t1, INDEX_LIMIT + 1, 32
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, s3
    RV_FLAGS sub, 64
    mv a2, s11
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lindex_read_loop
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lindex_read_error
    RV_BCOND eq, .Lindex_read_done
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    RV_IMM t2, INDEX_LIMIT, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lindex_read_error
    RV_JUMP .Lindex_read_loop
.Lindex_read_done:
    mv a0, s2
    RV_CALL rv_close
    RV_ADDR s6, registry_index
    mv t0, s6
    RV_IMM t1, 0, 32
    mv s6, t0
    mv s10, s3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s8, t0
    mv s10, s3
    RV_FLAGS add, 64
    mv t0, s11
    RV_ADDR s6, registry_index_end
    mv s8, s6
    RV_STORE t0, 8
    RV_RESTORE s3
    RV_RESTORE s2
    ret
.Lindex_read_error:
    mv a0, s2
    RV_CALL rv_close
    RV_JUMP registry_bad_index
/* Input: bounded index/end from registry_read_index. Output: <=4096 records,
 * each eight borrowed pointers into index. Replaces TAB/LF with NUL. Rejects
 * invalid headers, controls, non-ASCII, missing LF, >2048-byte rows, malformed
 * fields and duplicate artifact identities before any result is printed.
 * Capacity: registry_rows=4096*64 bytes. Stack: 64 saved bytes plus calls. */
registry_parse_index:
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s6, registry_index
    mv s2, s6
    RV_ADDR s6, registry_header
    mv a1, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lindex_header:
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
    RV_BCOND eq, .Lindex_header_done
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, s2
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
    RV_BCOND ne, registry_bad_index
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lindex_header
.Lindex_header_done:
    mv s6, s2
    mv s10, a3
    add s6, s6, s10
    mv a0, s6
    RV_ADDR s6, registry_index_end
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_JUMP registry_parse_records
/* Input: a0=start of bounded TSV records, a1=exclusive end. Shared by index
 * and lock parsers after their headers. Output: registry_rows/count. Replaces
 * delimiters with NUL; validates every record before returning. Stack: 64 saved bytes. */
registry_parse_records:
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s2, a0
    RV_ADDR s6, registry_index_end
    mv s8, s6
    RV_STORE a1, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_STORE t1, 8
.Lindex_row:
    RV_ADDR s6, registry_index_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lindex_parsed
    RV_BCOND hi, registry_bad_index
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, ROW_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, registry_bad_index
    slli t0, t0, 6
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_ADDR s6, registry_rows
    mv s3, s6
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    mv s6, s3
    mv s8, s6
    RV_STORE s2, 8
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    mv s5, s2
.Lindex_char:
    RV_ADDR s6, registry_index_end
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, registry_bad_index
    mv t0, s2
    mv s8, t0
    mv s10, s5
    RV_FLAGS sub, 64
    mv t0, s11
    RV_IMM t2, 2048, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, registry_bad_index
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
    RV_IMM t2, 9, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lindex_tab
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 10, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lindex_newline
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
    RV_BCOND lo, registry_bad_index
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 127, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, registry_bad_index
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_JUMP .Lindex_char
.Lindex_tab:
    RV_IMM t2, 7, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, registry_bad_index
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s2, 8
    RV_JUMP .Lindex_char
.Lindex_newline:
    RV_IMM t2, 7, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_bad_index
    RV_IMM t1, 0, 32
    mv s6, s2
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    mv a0, s3
    RV_CALL registry_validate_row
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_STORE t3, 8
    RV_JUMP .Lindex_row
.Lindex_parsed:
    RV_CALL registry_check_unique
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    ret
/* Input: a0 points to eight bounded, NUL-terminated field pointers. Output:
 * returns only for valid fields. The complete parser checks identity uniqueness
 * before returning. Scratch: index is unchanged. Stack: 16 saved bytes plus calls. */
registry_validate_row:
    RV_SAVE s0
    mv s0, a0
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_package
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
    mv s6, s0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
    mv s6, s0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_valid_kind
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
    mv s6, s0
    li s10, 32
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
.Lhash_validate:
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
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_bad_index
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
    RV_BCOND ls, .Lhash_next
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
    RV_BCOND lo, registry_bad_index
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
    RV_BCOND hi, registry_bad_index
.Lhash_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 64, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lhash_validate
    mv s6, a0
    li s10, 64
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
    RV_BCOND ne, registry_bad_index
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_release_url
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
    mv s6, s0
    li s10, 24
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
    RV_BCOND ne, .Lrow_artifact_suffix
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    RV_IMM t2, 7, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, registry_bad_index
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 7
    sub s6, s6, s10
    mv a0, s6
    RV_ADDR s6, registry_tar_suffix
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
.Lrow_artifact_suffix:
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_size_value
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, registry_bad_index
    mv s6, s0
    li s10, 56
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, registry_bad_index
    RV_IMM t2, 160, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_bad_index
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
    RV_BCOND eq, registry_bad_index
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
    RV_BCOND eq, registry_bad_index
    RV_RESTORE s0
    ret
/* Input: a0/a1=validated eight-pointer rows. Output: t0 is negative, zero,
 * or positive for lexical artifact-identity order (package/version/target/kind).
 * Bytes are printable ASCII and each field ends at an accessible NUL. No row
 * or string changes. Scratch: t0/a3/a2/a4/a5. Stack: none. */
registry_identity_compare:
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lidentity_field:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a4, t1
    mv s6, a1
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a5, t1
.Lidentity_byte:
    mv s6, a4
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    mv s6, a5
    mv s8, s6
    RV_LOAD t1, 1
    mv a2, t1
    RV_ZEXT a2
    mv s8, t0
    mv s10, a2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_BCOND ne, .Lidentity_return
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lidentity_next_field
    RV_IMM t2, 1, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    RV_IMM t2, 1, 64
    mv s8, a5
    mv s10, t2
    RV_FLAGS add, 64
    mv a5, s11
    RV_JUMP .Lidentity_byte
.Lidentity_next_field:
    RV_IMM t2, 8, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lidentity_field
.Lidentity_return:
    ret
/* Input: a0=owned row-pointer array, a1=root index, a2=exclusive heap size.
 * Bounds: root < size <= ROW_LIMIT. The child heaps already satisfy max order.
 * Output: restores the max heap rooted at a1. Only pointers within the array
 * change. All row bytes remain unchanged. Scratch: caller-saved registers.
 * Stack: 80 saved bytes plus calls. At most floor(log2(ROW_LIMIT)) iterations. */
registry_identity_sift:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s0, a0
    mv s2, a1
    mv s3, a2
.Lidentity_sift_loop:
    mv s6, s2
    mv s10, s2
    add s6, s6, s10
    li s10, 1
    add s6, s6, s10
    mv s4, s6
    mv s8, s4
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lidentity_sift_done
    mv s6, s4
    li s10, 1
    add s6, s6, s10
    mv s5, s6
    mv s8, s5
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lidentity_sift_child
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    mv s10, s5
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL registry_identity_compare
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ge, .Lidentity_sift_child
    mv s4, s5
.Lidentity_sift_child:
    mv s6, s0
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL registry_identity_compare
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ge, .Lidentity_sift_done
    mv s6, s0
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, s0
    mv s10, s2
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE a3, 8
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv s2, s4
    RV_JUMP .Lidentity_sift_loop
.Lidentity_sift_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Input: registry_rows contains registry_row_count <= ROW_LIMIT validated rows.
 * Output: returns only when every artifact identity is unique; otherwise exits
 * before any result or download. Sorts a separate 32 KiB pointer array with
 * heap sort, then compares adjacent identities. Work is O(n log n), including
 * hostile row order; there is no hash collision path or recursion. Original
 * row order is preserved. Scratch: caller-saved registers and owned pointer
 * array. Stack: 64 saved bytes; at most 176 bytes with nested calls. */
registry_check_unique:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    RV_IMM t2, 2, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lunique_done
    RV_ADDR s6, registry_sorted_rows
    mv s3, s6
    RV_ADDR s6, registry_rows
    mv s0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lunique_copy:
    mv s6, s3
    mv s10, a3
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s0, 8
    RV_IMM t2, 64, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_IMM t2, 1, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 64
    mv a3, s11
    mv s8, a3
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lunique_copy
    mv s4, s2
    srli s4, s4, 1
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
.Lunique_heap:
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    mv s4, s11
    mv a0, s3
    mv a1, s4
    mv a2, s2
    RV_CALL registry_identity_sift
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND ne, .Lunique_heap
    mv s4, s2
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    mv s4, s11
.Lunique_sort:
    mv s6, s3
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, s3
    mv s8, s6
    RV_STORE a3, 8
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t0, 8
    mv a0, s3
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    mv a2, s4
    RV_CALL registry_identity_sift
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    mv s4, s11
    RV_BCOND ne, .Lunique_sort
    RV_IMM t1, 1, 32
    mv s4, t1
    RV_ZEXT s4
.Lunique_adjacent:
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    li s10, 8
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s3
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL registry_identity_compare
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_bad_index
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 64
    mv s4, s11
    mv s8, s4
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lunique_adjacent
.Lunique_done:
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* A namespace component is lowercase, does not end in '-' and has no '--'. */
/* Input: a0=component, a1=max length (39 or 64). Ends at '/' or NUL. Output:
 * t0=length on success, zero on failure. Scratch: t0/a3/a2. Stack: none. */
registry_component:
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
    RV_IMM t2, 97, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
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
    RV_BCOND hi, registry_invalid
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lcomponent_loop:
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
    RV_BCOND eq, .Lcomponent_end
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
    RV_BCOND eq, .Lcomponent_end
    mv s8, a3
    mv s10, a1
    RV_FLAGS sub, 32
    RV_BCOND hs, registry_invalid
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
    RV_BCOND eq, .Lcomponent_dash
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
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
    RV_BCOND lo, registry_invalid
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
    RV_BCOND ls, .Lcomponent_next
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
    RV_BCOND lo, registry_invalid
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
    RV_BCOND hi, registry_invalid
    RV_JUMP .Lcomponent_next
.Lcomponent_dash:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND ne, registry_invalid
    RV_IMM t1, 1, 32
    mv a2, t1
    RV_ZEXT a2
.Lcomponent_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lcomponent_loop
.Lcomponent_end:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_BCOND ne, registry_invalid
    mv t0, a3
    RV_ZEXT t0
    ret
/* Input: a0=package string. Output: t0=1 for owner/name, else zero. Owner is
 * <=39 chars, name <=64 chars; exactly one slash. Stack: one saved pointer. */
registry_valid_package:
    RV_SAVE a0
    RV_IMM t1, 39, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL registry_component
    RV_RESTORE a0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_invalid
    mv s6, a0
    mv s10, t0
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
    RV_BCOND ne, registry_invalid
    mv s6, a0
    mv s10, t0
    add s6, s6, s10
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    RV_SAVE a0
    RV_IMM t1, 64, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL registry_component
    RV_RESTORE a0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_invalid
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
    RV_BCOND ne, registry_invalid
    RV_JUMP registry_valid
/* Input: a0=version. Output: t0=1 for exactly three decimal components, each
 * <=2147483647, no leading zeroes. Maximum accepted length is 32. No overflow:
 * each multiply starts from a value <=2147483647. Stack: none. */
registry_valid_version:
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
.Lreg_version_component:
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
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
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
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
    RV_BCOND hi, registry_invalid
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
    RV_BCOND eq, .Lreg_version_zero
.Lreg_version_digit:
    mv s6, a0
    mv s10, a3
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
    RV_BCOND lo, .Lreg_version_separator
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
    RV_BCOND hi, .Lreg_version_separator
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 10, 64
    mv s10, t2
    mul a2, a2, s10
    mv s8, a2
    mv s10, t0
    RV_FLAGS add, 64
    mv a2, s11
    RV_IMM t2, 2147483647, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lreg_version_digit
.Lreg_version_zero:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
.Lreg_version_separator:
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
    RV_BCOND eq, .Lreg_version_end
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
    RV_BCOND ne, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 32
    mv a4, s11
    RV_IMM t2, 2, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lreg_version_component
.Lreg_version_end:
    RV_IMM t2, 2, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_invalid
    RV_JUMP registry_valid
/* Input: a0=string. Output: t0=1 only for one of the three published targets.
 * This is artifact selection, not a claim that the host can execute it. */
registry_valid_target:
    RV_SAVE a0
    RV_ADDR a1, registry_macos
    RV_CALL streq
    RV_RESTORE a0
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_registry1602
    RV_JUMP registry_valid
.Lrv_cb_skip_registry1602:
    RV_SAVE a0
    RV_ADDR s6, registry_x86_64
    mv a1, s6
    RV_CALL streq
    RV_RESTORE a0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_valid
    RV_SAVE a0
    RV_ADDR s6, registry_aarch64
    mv a1, s6
    RV_CALL streq
    RV_RESTORE a0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_valid
    RV_ADDR s6, registry_riscv64
    mv a1, s6
    RV_JUMP streq
/* Input: a0=string. Output: t0=1 for source/executable, else zero.
 * Stack: one saved pointer. Does not authorize execution. */
registry_valid_kind:
    RV_SAVE a0
    RV_ADDR s6, registry_source_kind
    mv a1, s6
    RV_CALL streq
    RV_RESTORE a0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_valid
    RV_ADDR s6, registry_executable_kind
    mv a1, s6
    RV_JUMP streq
/* Input: a0=decimal string. Output: t0=size 1..64 MiB, or zero on failure.
 * Rejects signs and leading zeroes. Checks each multiply against the bound.
 * Scratch: t0/a3/a2. Stack: none. */
registry_size_value:
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
    mv s6, a0
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
    RV_BCOND lo, registry_invalid
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 57, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, registry_invalid
.Lsize_digit:
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
    RV_BCOND eq, .Lsize_done
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
    RV_IMM t2, 57, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, registry_invalid
    RV_IMM t2, 48, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    mv a2, s11
    RV_IMM t2, 10, 64
    mv s10, t2
    mul t0, t0, s10
    mv s8, t0
    mv s10, a2
    RV_FLAGS add, 64
    mv t0, s11
    RV_IMM t2, ARTIFACT_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lsize_digit
.Lsize_done:
    ret
/* Input: a0=index URL already bounded to 4095 chars. Output: t0=1 for a
 * nonempty HTTPS URL with printable bytes and no userinfo/backslash, else zero.
 * This permits a user-selected registry origin; it is not artifact policy. */
registry_https_url:
    RV_ADDR s6, registry_https_prefix
    mv a1, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lhttps_prefix:
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
    RV_BCOND eq, .Lhttps_body
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
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
    RV_BCOND ne, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lhttps_prefix
.Lhttps_body:
    mv s6, a0
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
    RV_BCOND eq, registry_invalid
.Lhttps_char:
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
    RV_BCOND eq, registry_valid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 33, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 126, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, registry_invalid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 64, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, registry_invalid
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
    RV_BCOND eq, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lhttps_char
/* GitHub release URLs have exactly six path components. Restrict the alphabet
 * and reject dot components, query strings, fragments and percent encoding. */
/* Input: a0=bounded artifact URL. Output: t0=1 or zero. Read-only validation;
 * the release URL does not establish namespace ownership. Stack: none. */
registry_release_url:
    RV_CALL strlen
    RV_IMM t2, 768, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_invalid
    RV_ADDR s6, registry_github_prefix
    mv a1, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lrelease_prefix:
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
    RV_BCOND eq, .Lrelease_path
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
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
    RV_BCOND ne, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lrelease_prefix
.Lrelease_path:
    mv s8, a0
    mv s10, a3
    RV_FLAGS add, 64
    mv a0, s11
    mv s10, a4
    xor a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    mv a5, a0
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lrelease_segment_start:
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
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
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
    RV_BCOND ls, .Lrelease_char
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 65, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 90, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lrelease_char
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
    RV_BCOND lo, registry_invalid
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
    RV_BCOND hi, registry_invalid
.Lrelease_char:
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
    RV_BCOND eq, .Lrelease_segment
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
    RV_BCOND eq, .Lrelease_segment
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
    RV_BCOND eq, .Lrelease_next
    mv s8, a4
    mv s10, a4
    RV_FLAGS and, 32
    RV_BCOND eq, .Lrelease_alphanumeric
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
    RV_BCOND eq, .Lrelease_next
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
    RV_BCOND eq, .Lrelease_next
.Lrelease_alphanumeric:
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
    RV_BCOND lo, registry_invalid
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
    RV_BCOND ls, .Lrelease_next
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 65, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, registry_invalid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_IMM t2, 90, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lrelease_next
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
    RV_BCOND lo, registry_invalid
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
    RV_BCOND hi, registry_invalid
.Lrelease_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lrelease_char
.Lrelease_segment:
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv a6, s6
    mv a7, a6
    mv s8, a7
    mv s10, a5
    RV_FLAGS sub, 64
    mv a7, s11
    mv s8, a7
    mv s10, a7
    RV_FLAGS and, 64
    RV_BCOND eq, registry_invalid
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 32
    mv a4, s11
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrelease_owner
    RV_IMM t2, 2, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrelease_repository
    RV_IMM t2, 3, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrelease_label_releases
    RV_IMM t2, 4, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lrelease_label_download
    RV_IMM t2, 128, 64
    mv s8, a7
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_invalid
    RV_JUMP .Lrelease_delimiter
.Lrelease_owner:
    RV_IMM t2, 39, 64
    mv s8, a7
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_invalid
    RV_JUMP .Lrelease_delimiter
.Lrelease_repository:
    RV_IMM t2, 100, 64
    mv s8, a7
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_invalid
    RV_IMM t2, 4, 64
    mv s8, a7
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lrelease_delimiter
    mv s6, a6
    li s10, 4
    sub s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1953064750, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, registry_invalid
    RV_JUMP .Lrelease_delimiter
.Lrelease_label_releases:
    RV_IMM t2, 8, 64
    mv s8, a7
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_invalid
    RV_IMM t1, 8315179149160113522, 64
    mv a2, t1
    mv s6, a5
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, a2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_invalid
    RV_JUMP .Lrelease_delimiter
.Lrelease_label_download:
    RV_IMM t2, 8, 64
    mv s8, a7
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_invalid
    RV_IMM t1, 7233184988034199396, 64
    mv a2, t1
    mv s6, a5
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, a2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_invalid
.Lrelease_delimiter:
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
    RV_BCOND eq, .Lrelease_end
    RV_IMM t2, 6, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, registry_invalid
    mv s6, a6
    li s10, 1
    add s6, s6, s10
    mv a5, s6
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lrelease_segment_start
.Lrelease_end:
    RV_IMM t2, 6, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, registry_invalid
    RV_JUMP registry_valid
registry_valid:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
registry_invalid:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Terminal command: uses validated registry_rows. search matches package or
 * summary; info matches a package; versions suppresses duplicate versions.
 * Emits plain TSV or one JSON object. Cleans the workspace before exit. */
registry_list:
    RV_IMM t1, 1, 32
    RV_ADDR s6, registry_output_active
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_STORE t1, 8
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
    RV_BCOND eq, .Llist_start
    RV_ADDR s6, registry_results_prefix
    mv a0, s6
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 3, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Llist_prefix
    RV_ADDR s6, registry_versions_prefix
    mv a0, s6
.Llist_prefix:
    RV_CALL registry_emit
.Llist_start:
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Llist_row:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Llist_done
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, registry_mode
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
    RV_BCOND eq, .Llist_search
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Llist_next
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 3, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Llist_match
    RV_CALL registry_version_seen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Llist_next
    RV_JUMP .Llist_match
.Llist_search:
    RV_CALL registry_contains
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Llist_match
    mv s6, s2
    li s10, 56
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL registry_contains
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Llist_next
.Llist_match:
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
    RV_BCOND eq, .Llist_human
    RV_ADDR s6, registry_matches
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Llist_json_row
    RV_ADDR s6, registry_comma
    mv a0, s6
    RV_CALL registry_emit
.Llist_json_row:
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 3, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Llist_json_version
    mv a0, s2
    RV_CALL registry_print_json_row
    RV_JUMP .Llist_count
.Llist_json_version:
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_JUMP .Llist_count
.Llist_human:
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 3, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Llist_human_version
    mv a0, s2
    RV_CALL registry_print_text_row
    RV_JUMP .Llist_count
.Llist_human_version:
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_emit
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL registry_emit
.Llist_count:
    RV_ADDR s6, registry_matches
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, registry_matches
    mv s8, s6
    RV_STORE t3, 8
.Llist_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Llist_row
.Llist_done:
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
    RV_BCOND eq, .Llist_finish
    RV_ADDR s6, registry_results_suffix
    mv a0, s6
    RV_CALL registry_emit
.Llist_finish:
    RV_ADDR s6, registry_matches
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Llist_flush
    RV_ADDR s6, registry_mode
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
    RV_BCOND ne, .Llist_flush
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
    RV_BCOND ne, .Llist_flush
    RV_ADDR s6, registry_no_matches
    mv a0, s6
    RV_CALL registry_emit
.Llist_flush:
    RV_CALL registry_flush
    RV_IMM t1, 0, 32
    RV_ADDR s6, registry_output_active
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL registry_cleanup
    RV_ADDR s6, registry_matches
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, exit_ok
    RV_ADDR s6, registry_mode
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
    RV_BCOND ne, registry_not_found
    RV_JUMP exit_ok
/* Input: a0=accessible NUL-terminated text. Output: writes through out when
 * listing is inactive; otherwise appends to the owned 64 KiB output buffer.
 * Each copy is bounded by remaining capacity and string length. A full buffer
 * is flushed before reuse. Copies advance through memory. Scratch: caller-saved
 * registers and buffer; callee-saved registers survive. Stack: 48 saved bytes
 * plus calls. A returned write error is fatal and cleans the registry workspace. */
registry_emit:
    RV_ADDR s6, registry_output_active
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
    RV_BCOND eq, out
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    mv s0, a0
    RV_CALL strlen
    mv s2, t0
.Lemit_chunk:
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lemit_done
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t1, REGISTRY_OUTPUT_LIMIT, 32
    mv s3, t1
    RV_ZEXT s3
    mv s8, s3
    mv s10, t0
    RV_FLAGS sub, 64
    mv s3, s11
    mv s8, s3
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND ls, .Lemit_copy
    mv s3, s2
.Lemit_copy:
    RV_ADDR s6, registry_output_buffer
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    mv a1, s0
    mv a3, s3
    mv s8, a3
    bnez s8, .Lrv_cb_skip_registry2257
    RV_JUMP .Lport_registry_1_end
.Lrv_cb_skip_registry2257:
.Lport_registry_1:
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
    beqz s8, .Lrv_cb_skip_registry2262
    RV_JUMP .Lport_registry_1
.Lrv_cb_skip_registry2262:
.Lport_registry_1_end:
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, t1
    mv s10, s3
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_STORE t3, 8
    mv s8, s0
    mv s10, s3
    RV_FLAGS add, 64
    mv s0, s11
    mv s8, s2
    mv s10, s3
    RV_FLAGS sub, 64
    mv s2, s11
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, REGISTRY_OUTPUT_LIMIT, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lemit_chunk
    RV_CALL registry_flush
    RV_JUMP .Lemit_chunk
.Lemit_done:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Input: owned output buffer and size <= REGISTRY_OUTPUT_LIMIT. Output: all
 * queued bytes are written once in order, then size becomes zero. write_all
 * retries EINTR and short writes. Any other failure exits nonzero. Scratch:
 * caller-saved registers; no saved stack bytes, one nested call. */
registry_flush:
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lflush_done
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, registry_output_buffer
    mv a1, s6
    RV_CALL write_all
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lflush_error
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_output_size
    mv s8, s6
    RV_STORE t1, 8
.Lflush_done:
    ret
.Lflush_error:
    RV_ADDR s6, registry_err_output_write
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
/* Input: a0=haystack, a1=needle, both bounded strings. Output: t0=1 for a
 * case-sensitive substring (including empty needle), else zero. Read-only.
 * Scratch: t0/a3/a4. Stack: none. */
registry_contains:
    mv s6, a1
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
    RV_BCOND eq, registry_valid
    mv a4, a0
.Lcontains_start:
    mv s6, a4
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
    RV_BCOND eq, registry_invalid
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lcontains_chars:
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
    RV_BCOND eq, registry_valid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a4
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
    RV_BCOND ne, .Lcontains_next
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lcontains_chars
.Lcontains_next:
    RV_IMM t2, 1, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    RV_JUMP .Lcontains_start
/* Current row is s2. Suppress versions already printed for this package. */
/* Input: s2=current row in registry_rows. Output: t0=1 if an earlier row has
 * the same package and version. Read-only; scan ends before s2. Stack: 16 saved bytes. */
registry_version_seen:
    RV_SAVE s0
    RV_ADDR s6, registry_rows
    mv s0, s6
.Lversion_seen_row:
    mv s8, s0
    mv s10, s2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lversion_unseen
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lversion_seen_next
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lversion_seen_return
.Lversion_seen_next:
    RV_IMM t2, 64, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Lversion_seen_row
.Lversion_unseen:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Lversion_seen_return:
    RV_RESTORE s0
    ret
/* Input: a0=validated eight-pointer record. Writes one TSV row to stdout.
 * Record fields contain no tabs or controls. Stack: 32 saved bytes plus calls. */
registry_print_text_row:
    RV_SAVE s0
    RV_SAVE s4
    mv s0, a0
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Ltext_field:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, .Ltext_value
    RV_ADDR s6, registry_tab
    mv a0, s6
    RV_CALL registry_emit
.Ltext_value:
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_emit
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    RV_IMM t2, 8, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Ltext_field
    RV_ADDR s6, registry_newline
    mv a0, s6
    RV_CALL registry_emit
    RV_RESTORE s4
    RV_RESTORE s0
    ret
/* Input: a0=validated eight-pointer record. Writes one JSON object; bytes is
 * numeric and all other values are escaped strings. Stack: 48 saved bytes. */
registry_print_json_row:
    RV_SAVE s0
    RV_SAVE s4
    RV_SAVE s5
    mv s0, a0
    RV_ADDR s6, registry_lbrace
    mv a0, s6
    RV_CALL registry_emit
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_ADDR s6, registry_json_keys
    mv s5, s6
.Ljson_field:
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    RV_BCOND eq, .Ljson_key
    RV_ADDR s6, registry_comma
    mv a0, s6
    RV_CALL registry_emit
.Ljson_key:
    mv s6, s5
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_emit
    mv s6, s0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t2, 6, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Ljson_number
    RV_CALL registry_json_string
    RV_JUMP .Ljson_next
.Ljson_number:
    RV_CALL registry_emit
.Ljson_next:
    RV_IMM t2, 1, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 32
    mv s4, s11
    RV_IMM t2, 8, 32
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Ljson_field
    RV_ADDR s6, registry_rbrace
    mv a0, s6
    RV_CALL registry_emit
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s0
    ret
/* Metadata is printable ASCII. File arguments may contain controls, which are
 * encoded as \u00XX. A 4095-byte path requires at most 24572 output bytes. */
/* Input: a0=string <=4095 bytes. Output: writes a quoted JSON string. Owned
 * scratch buffer is 24576 bytes, including closing quote and NUL. Other bytes
 * are copied unchanged; non-ASCII paths must use UTF-8 for valid JSON. */
registry_json_string:
    mv a1, a0
    RV_ADDR s6, registry_json_buffer
    mv a0, s6
    RV_IMM t1, 34, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
.Lquote_char:
    mv s6, a1
    mv s8, s6
    RV_LOAD t1, 1
    mv t0, t1
    RV_ZEXT t0
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
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
    RV_BCOND eq, .Lquote_end
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
    RV_BCOND lo, .Lquote_control
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
    RV_BCOND eq, .Lquote_escape
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
    RV_BCOND eq, .Lquote_escape
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_JUMP .Lquote_char
.Lquote_escape:
    RV_IMM t1, 92, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 2, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_JUMP .Lquote_char
.Lquote_control:
    RV_IMM t1, 92, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 117, 32
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 48, 32
    mv s6, a0
    li s10, 2
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 48, 32
    mv s6, a0
    li s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv a2, t0
    RV_ZEXT a2
    srliw a2, a2, 4
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_ADDR s6, registry_hex_digits
    mv a3, s6
    mv s6, a3
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
    and t1, a2, s10
    RV_ZEXT t1
    mv s6, a0
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 15, 32
    mv s10, t2
    and t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    mv s6, a3
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
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    li s10, 5
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 6, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    RV_JUMP .Lquote_char
.Lquote_end:
    RV_IMM t1, 34, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 0, 32
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, registry_json_buffer
    mv a0, s6
    RV_JUMP registry_emit
/* Input: validated rows plus query/target/kind/exact-version globals.
 * Output: t0=selected eight-pointer row, or zero. Stores registry_selected.
 * Numeric version order is shared by package fetch and self update.
 * Stack: 32 saved bytes plus 16 local bytes. No filesystem changes. */
registry_select:
    RV_SAVE s2
    RV_SAVE s3
    li s10, 16
    sub sp, sp, s10
    RV_IMM t1, 0, 64
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, registry_rows
    mv s2, s6
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Lfetch_select:
    RV_ADDR s6, registry_row_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lfetch_selected
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_query
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lfetch_next
    mv s6, s2
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_target
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lfetch_next
    mv s6, s2
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_kind
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lfetch_next
    RV_ADDR s6, registry_exact_version
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lfetch_latest
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Lfetch_next
    RV_JUMP .Lfetch_choose
.Lfetch_latest:
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lfetch_choose
    mv s6, s2
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s6, t0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL registry_version_compare
    RV_IMM t2, 0, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND le, .Lfetch_next
.Lfetch_choose:
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_STORE s2, 8
.Lfetch_next:
    RV_IMM t2, 64, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    RV_IMM t2, 1, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS add, 64
    mv s3, s11
    RV_JUMP .Lfetch_select
.Lfetch_selected:
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s3
    RV_RESTORE s2
    ret
/* Terminal command: select exact or highest numeric version for package,
 * target and kind. Copy/download into the owned stage, check exact byte size,
 * run fixed sha256sum argv, then renameat2(RENAME_NOREPLACE). fetch retains
 * non-executable mode; install additionally validates ELF and sets 0755.
 * Existing outputs are retained on all failures.
 * The index authenticates no publisher; the digest check establishes integrity
 * relative to that selected index. Source archives remain opaque bytes. */
registry_fetch:
    RV_CALL registry_select
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 64
    RV_BCOND eq, registry_not_found
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 6, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lfetch_selection_ready
    RV_CALL dependency_prepare_selection
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
.Lfetch_selection_ready:
    P_BYTE t1, registry_mode
    mv s8, t1
    li s10, 5
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_registry_selection_ready
    RV_CALL program_prepare_selection
.Lp_registry_selection_ready:
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_size_value
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL registry_workspace
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lfetch_local
    mv s6, s0
    li s10, 40
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, registry_temp_payload
    mv a1, s6
    mv s6, s0
    li s10, 48
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_download_error
    RV_JUMP .Lfetch_verify
.Lfetch_local:
    RV_CALL registry_copy_local
.Lfetch_verify:
    RV_CALL registry_verify_payload
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 6, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, dependency_finish_add
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 5, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lfetch_default_output
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL validate_host_elf
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, registry_install_elf_error
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lfetch_output_ready
    RV_CALL registry_install_output
    RV_JUMP .Lfetch_output_ready
.Lfetch_default_output:
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 0, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lfetch_output_ready
    RV_ADDR s6, registry_default_output
    mv a0, s6
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
.Loutput_package:
    mv s6, a1
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
    RV_BCOND eq, .Loutput_version
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
    RV_BCOND ne, .Loutput_package_char
    RV_IMM t1, 45, 32
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and t0, t0, s10
    or t0, t0, s11
.Loutput_package_char:
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
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
    RV_JUMP .Loutput_package
.Loutput_version:
    RV_IMM t1, 45, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    RV_IMM t1, 45, 32
    mv s6, t0
    mv s8, s6
    RV_STORE t1, 1
    mv s6, t0
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    mv s6, s0
    li s10, 16
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_tar_suffix
    mv a1, s6
    mv s6, s0
    li s10, 24
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a3
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
    RV_BCOND eq, .Loutput_suffix
    RV_ADDR s6, registry_bin_suffix
    mv a1, s6
.Loutput_suffix:
    RV_CALL copy_string
    RV_ADDR s6, registry_default_output
    mv t0, s6
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_STORE t0, 8
.Lfetch_output_ready:
    P_BYTE t1, registry_mode
    mv s8, t1
    li s10, 5
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_registry_original_output
    RV_CALL program_commit_install
    RV_JUMP .Lp_registry_committed
.Lp_registry_original_output:
    /* Only the explicit install command grants execute permission. */
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_IMM t1, 420, 32
    mv a1, t1
    RV_ZEXT a1
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 5, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lartifact_permissions
    RV_IMM t1, 493, 32
    mv a1, t1
    RV_ZEXT a1
.Lartifact_permissions:
    RV_CALL rv_chmod
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_IMM t1, AT_FDCWD, 64
    mv a0, t1
    RV_ADDR s6, registry_temp_payload
    mv a1, s6
    RV_IMM t1, AT_FDCWD, 64
    mv a2, t1
    RV_ADDR s6, registry_output
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
    RV_BCOND mi, .Lfetch_output_error
.Lp_registry_committed:
    RV_CALL registry_cleanup
    P_BYTE t1, registry_mode
    mv s8, t1
    li s10, 5
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lp_registry_report
    P_BYTE t1, json_mode
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_registry2920
    RV_JUMP exit_ok
.Lrv_cb_skip_registry2920:
.Lp_registry_report:
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
    RV_BCOND ne, .Lfetch_json
    RV_ADDR s6, registry_fetched_text
    mv a0, s6
    RV_ADDR s6, registry_mode
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 5, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lartifact_report
    RV_ADDR s6, registry_installed_text
    mv a0, s6
.Lartifact_report:
    RV_CALL out
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL out
    RV_ADDR s6, registry_verified_text
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
.Lfetch_json:
    RV_ADDR s6, registry_fetch_json_prefix
    mv a0, s6
    RV_CALL out
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, registry_fetch_json_package
    mv a0, s6
    RV_CALL out
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, registry_fetch_json_version
    mv a0, s6
    RV_CALL out
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL registry_json_string
    RV_ADDR s6, registry_fetch_json_suffix
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
.Lfetch_output_error:
    RV_ADDR s6, registry_err_output
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
.Lsha_missing:
    RV_ADDR s6, registry_err_sha
    mv a0, s6
    RV_IMM t1, 127, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_integrity_error:
    RV_ADDR s6, registry_err_integrity
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_install_target_error:
    RV_ADDR s6, registry_err_install_target
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
registry_install_elf_error:
    RV_ADDR s6, registry_err_elf
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
/* Input: selected registry row in s0; no explicit output was supplied.
 * Output: registry_output points to HOME/.local/bin/<unscoped package name>.
 * HOME is read, never changed. Requires an absolute HOME <=4000 bytes. Creates
 * only the two local/bin directories with the existing real-directory check.
 * Buffer capacity=4096. Caller still uses atomic no-overwrite finalization.
 * No PATH modification occurs. This does not make local directory races safe. */
registry_install_output:
    RV_ADDR s6, envp
    mv s8, s6
    RV_LOAD t1, 8
    mv a4, t1
.Linstall_env:
    mv s6, a4
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 64
    RV_BCOND eq, .Linstall_home_error
    mv s6, a0
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 72, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Linstall_env_next
    mv s6, a0
    li s10, 1
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 79, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Linstall_env_next
    mv s6, a0
    li s10, 2
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 77, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Linstall_env_next
    mv s6, a0
    li s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 69, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Linstall_env_next
    mv s6, a0
    li s10, 4
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 1
    RV_IMM t2, 61, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Linstall_home
.Linstall_env_next:
    RV_IMM t2, 8, 64
    mv s8, a4
    mv s10, t2
    RV_FLAGS add, 64
    mv a4, s11
    RV_JUMP .Linstall_env
.Linstall_home:
    RV_IMM t2, 5, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    mv s6, a0
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
    RV_BCOND ne, .Linstall_home_error
    RV_SAVE a0
    RV_CALL strlen
    RV_RESTORE a1
    RV_IMM t2, 4000, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Linstall_home_error
    RV_ADDR s6, registry_default_output
    mv a0, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_local_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, registry_default_output
    mv a0, s6
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_default_output
    mv a0, s6
    RV_CALL strlen
    RV_ADDR s6, registry_default_output
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    RV_ADDR s6, registry_bin_dir_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, registry_default_output
    mv a0, s6
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_default_output
    mv a0, s6
    RV_CALL strlen
    RV_ADDR s6, registry_default_output
    mv a0, s6
    mv s8, a0
    mv s10, t0
    RV_FLAGS add, 64
    mv a0, s11
    RV_IMM t1, 47, 32
    mv s6, a0
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
.Linstall_name:
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
    RV_BCOND eq, .Linstall_name_start
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_JUMP .Linstall_name
.Linstall_name_start:
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_CALL copy_string
    RV_ADDR s6, registry_default_output
    mv t0, s6
    RV_ADDR s6, registry_output
    mv s8, s6
    RV_STORE t0, 8
    ret
.Linstall_home_error:
    RV_ADDR s6, registry_err_home
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP registry_fail
/* Input: registry_selected and expected_size describe the private payload.
 * Check its regular-file type and exact length, then run sha256sum with fixed
 * arguments. Returns only on success; failure cleans the private workspace.
 * Stack: 16 saved bytes. Each workspace has one exclusive checksum file. */
registry_verify_payload:
    RV_SAVE s0
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv s0, t1
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_stat + RV_STAT_MODE
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
    RV_BCOND ne, registry_io_error
    RV_ADDR s6, registry_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_integrity_error
    RV_ADDR s6, registry_checksum_contents
    mv a0, s6
    mv s6, s0
    li s10, 32
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_two_spaces
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_temp_payload
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, registry_newline
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, registry_temp_checksum
    mv a0, s6
    RV_ADDR s6, registry_checksum_contents
    mv a1, s6
    RV_ADDR s6, registry_checksum_created
    mv a2, s6
    RV_CALL create_exclusive_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_sha256sum
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lsha_missing
    RV_ADDR s6, registry_temp_checksum
    mv t0, s6
    RV_ADDR s6, registry_sha_argv + 24
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, registry_sha256sum
    mv a0, s6
    RV_ADDR s6, registry_sha_argv
    mv a1, s6
    RV_CALL spawn_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, registry_integrity_error
    RV_RESTORE s0
    ret
/* Input: local_artifact path and expected_size <=64 MiB. Output: private payload
 * file, or fatal error. Opens a regular non-symlink input and exclusive output.
 * Retries short/interrupted reads and writes; checks both initial and copied
 * lengths. Owned copy buffer=65536 bytes. Stack: 48 saved bytes plus calls. */
registry_copy_local:
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_ADDR s6, registry_local_artifact
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK, 32
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
    RV_BCOND mi, registry_io_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, registry_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_stat + RV_STAT_MODE
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
    RV_BCOND ne, registry_io_error
    RV_ADDR s6, registry_stat + RV_STAT_SIZE
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_integrity_error
    RV_ADDR s6, registry_temp_payload
    mv a0, s6
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + 193, 32
    mv a1, t1
    RV_ZEXT a1
    RV_IMM t1, 384, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    mv s3, t0
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
.Lcopy_artifact_read:
    mv a0, s2
    RV_ADDR s6, registry_copy_buffer
    mv a1, s6
    RV_IMM t1, 65536, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lcopy_artifact_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_BCOND eq, .Lcopy_artifact_done
    mv s8, s4
    mv s10, t0
    RV_FLAGS add, 64
    mv s4, s11
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, registry_integrity_error
    mv a2, t0
    mv a0, s3
    RV_ADDR s6, registry_copy_buffer
    mv a1, s6
    RV_CALL write_all
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_JUMP .Lcopy_artifact_read
.Lcopy_artifact_done:
    mv a0, s2
    RV_CALL rv_close
    mv a0, s3
    RV_CALL rv_close
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, registry_io_error
    RV_ADDR s6, registry_expected_size
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, registry_integrity_error
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    ret
/* Input: a0/a1=already validated numeric versions. Output: t0=-1, 0 or 1
 * for left less/equal/greater. Values are <=2147483647 per component, so the
 * decimal conversion cannot overflow. Read-only. Stack: none. */
registry_version_compare:
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lcompare_component:
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
.Lcompare_left:
    mv s6, a0
    mv s10, a3
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
    RV_BCOND lo, .Lcompare_right
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
    RV_BCOND hi, .Lcompare_right
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 10, 64
    mv s10, t2
    mul a4, a4, s10
    mv s8, a4
    mv s10, t0
    RV_FLAGS add, 64
    mv a4, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lcompare_left
.Lcompare_right:
    mv s6, a1
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
    RV_BCOND lo, .Lcompare_values
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
    RV_BCOND hi, .Lcompare_values
    RV_IMM t2, 48, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    mv t0, s11
    RV_IMM t2, 10, 64
    mv s10, t2
    mul a5, a5, s10
    mv s8, a5
    mv s10, t0
    RV_FLAGS add, 64
    mv a5, s11
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    RV_JUMP .Lcompare_right
.Lcompare_values:
    mv s8, a4
    mv s10, a5
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lcompare_greater
    RV_BCOND lo, .Lcompare_less
    mv s6, a0
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
    RV_BCOND eq, .Lcompare_equal
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    RV_JUMP .Lcompare_component
.Lcompare_greater:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.Lcompare_less:
    RV_IMM t1, -1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.Lcompare_equal:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
.section .rodata
registry_default_url: .asciz "https://asm.build/registry/v1/index.tsv"
registry_header: .asciz "# asm-registry-v1\n"
registry_host: .asciz "riscv64-linux"
registry_x86_64: .asciz "x86_64-linux"
registry_macos: .asciz "aarch64-macos"
registry_aarch64: .asciz "aarch64-linux"
registry_riscv64: .asciz "riscv64-linux"
registry_source_kind: .asciz "source"
registry_executable_kind: .asciz "executable"
registry_empty: .asciz ""
registry_opt_json: .asciz "--json"
registry_opt_no_color: .asciz "--no-color"
registry_opt_help: .asciz "--help"
registry_opt_index: .asciz "--index"
registry_opt_registry: .asciz "--registry"
registry_opt_target: .asciz "--target"
registry_opt_kind: .asciz "--kind"
registry_opt_output: .asciz "--output"
registry_opt_artifact: .asciz "--artifact"
registry_separator: .asciz "--"
registry_https_prefix: .asciz "https://"
registry_github_prefix: .asciz "https://github.com/"
registry_curl: .asciz "/usr/bin/curl"
registry_sha256sum: .asciz "/usr/bin/sha256sum"
registry_curl_disable: .asciz "--disable"
registry_curl_fail: .asciz "--fail"
registry_curl_location: .asciz "--location"
registry_curl_silent: .asciz "--silent"
registry_curl_show_error: .asciz "--show-error"
registry_curl_proto: .asciz "--proto"
registry_curl_https: .asciz "=https"
registry_curl_proto_redir: .asciz "--proto-redir"
registry_curl_connect_timeout: .asciz "--connect-timeout"
registry_curl_fifteen: .asciz "15"
registry_curl_max_time: .asciz "--max-time"
registry_curl_120: .asciz "120"
registry_curl_max_redirs: .asciz "--max-redirs"
registry_curl_five: .asciz "5"
registry_curl_max_filesize: .asciz "--max-filesize"
registry_curl_output: .asciz "--output"
registry_sha_status: .asciz "--status"
registry_sha_check: .asciz "--check"
registry_index_max: .asciz "1048576"
registry_temp_prefix: .asciz ".asm-registry-"
registry_index_suffix: .asciz "/index.tsv"
registry_payload_suffix: .asciz "/payload"
registry_checksum_suffix: .asciz "/checksum.txt"
registry_tar_suffix: .asciz ".tar.gz"
registry_bin_suffix: .asciz ".bin"
registry_local_suffix: .asciz "/.local"
registry_bin_dir_suffix: .asciz "/bin"
registry_tab: .asciz "\t"
registry_newline: .asciz "\n"
registry_two_spaces: .asciz "  "
registry_comma: .asciz ","
registry_lbrace: .asciz "{"
registry_rbrace: .asciz "}"
registry_hex_digits: .asciz "0123456789abcdef"
registry_results_prefix: .asciz "{\"results\":["
registry_versions_prefix: .asciz "{\"versions\":["
registry_results_suffix: .asciz "]}\n"
registry_json_keys:
.quad registry_json_package, registry_json_version, registry_json_target
.quad registry_json_kind, registry_json_sha, registry_json_url
.quad registry_json_bytes, registry_json_summary
registry_json_package: .asciz "\"package\":"
registry_json_version: .asciz "\"version\":"
registry_json_target: .asciz "\"target\":"
registry_json_kind: .asciz "\"kind\":"
registry_json_sha: .asciz "\"sha256\":"
registry_json_url: .asciz "\"url\":"
registry_json_bytes: .asciz "\"bytes\":"
registry_json_summary: .asciz "\"summary\":"
registry_fetch_json_prefix: .asciz "{\"ok\":true,\"artifact\":"
registry_fetch_json_package: .asciz ",\"package\":"
registry_fetch_json_version: .asciz ",\"version\":"
registry_fetch_json_suffix: .asciz ",\"verified\":true}\n"
registry_fetched_text: .asciz "Fetched "
registry_installed_text: .asciz "Installed "
registry_verified_text: .asciz " (size and SHA-256 verified; not executed)\n"
registry_no_matches: .asciz "No matching packages.\n"
registry_err_args: .asciz "invalid registry arguments; use asm search --help"
registry_err_index: .asciz "invalid registry index; expected the bounded asm-registry-v1 format"
registry_err_download: .asciz "HTTPS download failed; no package was installed"
registry_err_io: .asciz "cannot read a regular file or create a private registry workspace"
registry_err_not_found: .asciz "no matching package, version, target and artifact kind"
registry_err_curl: .asciz "registry downloads require /usr/bin/curl"
registry_err_sha: .asciz "artifact verification requires /usr/bin/sha256sum"
registry_err_integrity: .asciz "artifact size or SHA-256 verification failed; output was not created"
registry_err_output: .asciz "cannot create output; the destination must not exist and must be on the same filesystem"
registry_err_output_write: .asciz "cannot write registry output; check the output destination and try again"
registry_err_install_target: .asciz "installation requires aarch64-linux; use fetch to inspect another target"
registry_err_elf: .asciz "artifact is not a supported AArch64 ELF executable; check its target and format"
registry_err_home: .asciz "HOME must be an absolute directory; set an explicit destination with --output"
registry_help_text:
.ascii "Usage:\n"
.ascii "  asm search [query] [--json]\n"
.ascii "  asm info owner/name [--json]\n"
.ascii "  asm versions owner/name [--json]\n"
.ascii "  asm fetch owner/name[@version] [--target target] [--kind source|executable]\n"
.ascii "            [--output path] [--artifact local-file] [--json]\n\n"
.ascii "  asm install owner/name[@version] [--output path] [--artifact local-file]\n\n"
.ascii "  asm add owner/name@version [--artifact local-file] [--json]\n"
.ascii "  asm update owner/name@version [--artifact local-file] [--json]\n"
.ascii "  asm remove owner/name [--json]\n"
.ascii "  asm installed [--json]\n"
.ascii "  asm upgrade owner/name[@version] [--index PATH | --registry HTTPS_URL]\n"
.ascii "  asm uninstall owner/name [--json]\n"
.ascii "  asm lock [--json]\n"
.ascii "  asm sync [--artifact local-file] [--json]\n\n"
.ascii "Use --index path for a local index or --registry https://... for an index URL.\n"
.ascii "The default index is https://asm.build/registry/v1/index.tsv.\n"
.ascii "upgrade manages recorded programs; update and remove manage source dependencies.\n"
.ascii "upgrade reuses the recorded HTTPS origin; local records require --index PATH.\n"
.ascii "upgrade also accepts --artifact PATH and --json; it refuses --output and downgrades.\n"
.ascii "fetch selects the highest numeric version if you omit @version.\n"
.ascii "fetch defaults to source and riscv64-linux. It verifies bytes and SHA-256.\n"
.ascii "fetch does not overwrite, extract, install, or run package contents.\n"
.ascii "install accepts host ELF executables. Its default path is ~/.local/bin/<name>.\n"
.ascii "install does not overwrite a file, run the program, or change PATH.\n"
.ascii "add and update require an exact source version and an existing project.\n"
.ascii "Imports use owner/name/version/target paths under .asm/packages.\n"
.ascii "Build commands check locked archives and source bytes before assembly.\n"
.byte 0
.section .data
.balign 8
registry_curl_argv:
.quad registry_curl, registry_curl_disable, registry_curl_fail
.quad registry_curl_location, registry_curl_silent, registry_curl_show_error
.quad registry_curl_proto, registry_curl_https, registry_curl_proto_redir
.quad registry_curl_https, registry_curl_connect_timeout, registry_curl_fifteen
.quad registry_curl_max_time, registry_curl_120, registry_curl_max_redirs
.quad registry_curl_five, registry_curl_max_filesize, 0
.quad registry_curl_output, 0, registry_separator, 0, 0
registry_sha_argv:
.quad registry_sha256sum, registry_sha_status, registry_sha_check, 0, 0
.section .bss
.balign 8
registry_url: .skip 8
registry_index_path: .skip 8
registry_target: .skip 8
registry_kind: .skip 8
registry_query: .skip 8
registry_exact_version: .skip 8
registry_output: .skip 8
registry_extra_temp: .skip 8
registry_local_artifact: .skip 8
registry_row_count: .skip 8
registry_index_end: .skip 8
registry_selected: .skip 8
registry_matches: .skip 8
registry_expected_size: .skip 8
registry_stat: .skip RV_STAT_BYTES
registry_number_buffer: .skip 32
registry_temp_dir: .skip 64
registry_temp_index: .skip 96
registry_temp_payload: .skip 96
registry_temp_checksum: .skip 96
registry_checksum_contents: .skip 256
registry_selector: .skip 170
registry_default_output: .skip 4096
registry_json_buffer: .skip 24576
registry_output_size: .skip 8
registry_output_buffer: .skip REGISTRY_OUTPUT_LIMIT
registry_copy_buffer: .skip 65536
registry_rows: .skip ROW_LIMIT * 64
registry_sorted_rows: .skip ROW_LIMIT * 8
registry_index: .skip INDEX_LIMIT + 2
registry_mode: .skip 1
registry_has_query: .skip 1
registry_origin_seen: .skip 1
registry_local_index: .skip 1
registry_literal: .skip 1
registry_has_workspace: .skip 1
registry_checksum_created: .skip 1
registry_output_active: .skip 1
.section .note.GNU-stack,""
