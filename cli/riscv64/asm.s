/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/asm.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.include "cli/riscv64/platform.inc"
.include "cli/riscv64/resolution_manifest.s"
.global _start
.global next_arg, streq, strlen, copy_string, out, write_cstr, write_all
.global die, exit_ok, exit_code, spawn_wait, unsigned_decimal
.global create_exclusive_file, json_mode
.extern cmd_search, cmd_info, cmd_versions, cmd_fetch, cmd_install
/* Native RISC-V64 implementation. No C runtime or shell backend is used.
 * The internal ABI is defined in platform.inc. Arguments use a0-a7; t0 is
 * the result. Returning routines preserve s0-s5. Calls use BL/RET and
 * 16-byte aligned SP. Typed adapters invoke the native Linux syscall ABI.
 * String inputs require accessible NUL termination. File strings use bounded
 * parsers. Command and fatal-error labels do not return.
 */
.section .text
_start:
/* Forward string loops do not use a direction flag. */
    mv s6, sp
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, argc
    mv s8, s6
    RV_STORE t0, 8
    mv s6, sp
    li s10, 8
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, argv
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, argc
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, t0
    mv s10, a3
    slli s10, s10, 3
    add s6, s6, s10
    li s10, 8
    add s6, s6, s10
    mv t0, s6
    RV_ADDR s6, envp
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 1, 64
    RV_ADDR s6, argi
    mv s8, s6
    RV_STORE t1, 8
.Lglobals:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, cmd_help
    mv s2, t0
    RV_ADDR s6, opt_json
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lglobal_json
    RV_ADDR s6, opt_no_color
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lglobals
    RV_ADDR s6, opt_help
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_help
    RV_ADDR s6, opt_h
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_help
    RV_ADDR s6, opt_version
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_version
    RV_ADDR s6, opt_V
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_version
    RV_ADDR s6, opt_license
    mv a1, s6
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_license
    RV_ADDR s6, commands
    mv s0, s6
.Ldispatch:
    mv s6, s0
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 64
    RV_BCOND eq, unknown_command
    mv a0, s2
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Ldispatch_match
    RV_IMM t2, 16, 64
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 64
    mv s0, s11
    RV_JUMP .Ldispatch
.Ldispatch_match:
    mv s6, s0
    li s10, 8
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t2, 8
    jr t2
.Lglobal_json:
    RV_IMM t1, 1, 32
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lglobals
/* Input: global argc/argv/argi from the initial Linux stack. Output: t0 is the
 * next borrowed argv pointer, or zero. Advances argi only for an existing arg.
 * Stack: none. Bounds: argi is checked against argc before the pointer load. */
next_arg:
    RV_ADDR s6, argi
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, argc
    mv s8, s6
    RV_LOAD t2, 8
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lnext_none
    RV_ADDR s6, argv
    mv s8, s6
    RV_LOAD t1, 8
    mv a3, t1
    mv s6, a3
    mv s10, t0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, argi
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 1, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 64
    mv t3, s11
    RV_ADDR s6, argi
    mv s8, s6
    RV_STORE t3, 8
    ret
.Lnext_none:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Input: a0, a1 are valid strings. Output: t0=1 if equal, otherwise zero.
 * Scratch: t0, a3. Stack: none. Does not modify either input. */
streq:
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Leq_loop:
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
    RV_BCOND ne, .Leq_no
    RV_IMM t2, 1, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 64
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
    RV_BCOND ne, .Leq_loop
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.Leq_no:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Input: a0 is a valid string. Output: t0 excludes its NUL terminator.
 * Scratch: t0. Stack: none. Callers must establish accessible termination. */
strlen:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Llen_loop:
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
    RV_BCOND eq, .Llen_done
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    RV_JUMP .Llen_loop
.Llen_done:
    ret
/* Input: a0=destination, a1=source. Caller owns both buffers and proves
 * destination capacity >= strlen(source)+1; overlapping buffers are unsupported.
 * Output: t0 points to the copied NUL. Scratch: t0, a3, a1. Stack: none. */
copy_string:
    mv t0, a0
.Lcopy_loop:
    mv s6, a1
    mv s8, s6
    RV_LOAD t1, 1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and a3, a3, s10
    or a3, a3, s11
    li s10, 255
    and t1, a3, s10
    RV_ZEXT t1
    mv s6, t0
    mv s8, s6
    RV_STORE t1, 1
    li s10, 255
    and t1, a3, s10
    RV_ZEXT t1
    li s10, 255
    and t2, a3, s10
    RV_ZEXT t2
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS and, 32
    RV_BCOND eq, .Lcopy_done
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS add, 64
    mv t0, s11
    RV_JUMP .Lcopy_loop
.Lcopy_done:
    ret
/* Input: a0=file descriptor; a1=valid string. Output: zero or negative errno.
 * write_all instead takes an explicit byte count in a2. Both retry EINTR and
 * short writes. Scratch: syscall registers and a1/a2. Stack: none. */
write_cstr:
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
.Lwrite_len:
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
    RV_BCOND eq, write_all
    RV_IMM t2, 1, 64
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 64
    mv a2, s11
    RV_JUMP .Lwrite_len
write_all:
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 64
    RV_BCOND eq, .Lwrite_ok
    RV_CALL rv_write
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, write_all
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lwrite_done
    RV_BCOND eq, .Lwrite_zero
    mv s8, a1
    mv s10, t0
    RV_FLAGS add, 64
    mv a1, s11
    mv s8, a2
    mv s10, t0
    RV_FLAGS sub, 64
    mv a2, s11
    RV_JUMP write_all
.Lwrite_ok:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
.Lwrite_done:
    ret
.Lwrite_zero:
    RV_IMM t1, -5, 64
    mv t0, t1
    ret
/* Input: a0=valid output string. Output: t0=0 after the complete stdout write;
 * returned write failures report a static stderr error and exit 1. Uses standard
 * caller scratch, preserves callee-saved registers, and uses a 16-byte RV_CALL
 * frame. File and stderr writers keep their returned-error contract. */
out:
    mv a1, a0
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL write_cstr
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lout_error
    ret
.Lout_error:
    RV_ADDR a0, err_output
    li a1, 1
    RV_ZEXT a1
    RV_JUMP die
/* Input: a0=text, a1=JSON, both static strings with a trailing LF. Selects the
 * global output mode and uses out's complete-write or fatal-error contract.
 * Stack: none beyond out's frame. */
report:
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
    RV_BCOND eq, out
    mv a0, a1
    RV_JUMP out
/* Input: a0=static JSON-safe error string without LF; a1=exit status 1..255.
 * Writes stderr and exits. Does not return. JSON escaping is not performed;
 * callers must not supply untrusted text, quotes, backslashes or controls. */
die:
    mv s2, a1
    RV_ZEXT s2
    mv s3, a0
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
    RV_BCOND eq, .Ldie_plain
    RV_IMM t1, 2, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, error_json_prefix
    mv a1, s6
    RV_CALL write_cstr
    RV_IMM t1, 2, 32
    mv a0, t1
    RV_ZEXT a0
    mv a1, s3
    RV_CALL write_cstr
    RV_IMM t1, 2, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, error_json_suffix
    mv a1, s6
    RV_CALL write_cstr
    RV_JUMP .Ldie_exit
.Ldie_plain:
    RV_IMM t1, 2, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, error_prefix
    mv a1, s6
    RV_CALL write_cstr
    RV_IMM t1, 2, 32
    mv a0, t1
    RV_ZEXT a0
    mv a1, s3
    RV_CALL write_cstr
    RV_IMM t1, 2, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, newline
    mv a1, s6
    RV_CALL write_cstr
.Ldie_exit:
    mv a0, s2
    RV_ZEXT a0
    RV_JUMP exit_code
exit_ok:
    mv s10, a0
    xor a0, a0, s10
    RV_ZEXT a0
    mv s8, a0
    mv s10, a0
    RV_FLAGS and, 32
exit_code:
    RV_CALL rv_exit
unknown_command:
    RV_ADDR s6, err_unknown_command
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
bad_args:
    RV_ADDR s6, err_arguments
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
unsupported_target:
    RV_ADDR s6, err_target
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Input: t0=current argv string. Output: t0=1 if consumed, otherwise zero.
 * --target consumes one more argument and accepts the host or its alias.
 * Malformed options exit. Stack: 16 saved bytes plus nested calls. */
common_option:
    RV_SAVE s0
    mv s0, t0
    mv a0, s0
    RV_ADDR s6, opt_json
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lopt_json
    mv a0, s0
    RV_ADDR s6, opt_no_color
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lopt_yes
    mv a0, s0
    RV_ADDR s6, opt_target
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lopt_target
    mv a0, s0
    RV_ADDR s6, opt_locked
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lopt_locked
    mv t0, s0
    RV_CALL native_link_option
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_asm403
    RV_JUMP .Lopt_yes
.Lrv_cb_skip_asm403:
    mv a0, s0
    RV_ADDR s6, opt_help
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_help
    mv a0, s0
    RV_ADDR s6, opt_h
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, cmd_help
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_RESTORE s0
    ret
.Lopt_json:
    RV_IMM t1, 1, 32
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
.Lopt_yes:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    RV_RESTORE s0
    ret
.Lopt_target:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, bad_args
    mv a0, t0
    RV_CALL validate_target
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, unsupported_target
    RV_JUMP .Lopt_yes
.Lopt_locked:
    RV_ADDR s6, allow_locked
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
    RV_BCOND eq, bad_args
    RV_IMM t1, 1, 32
    RV_ADDR s6, require_lock
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Lopt_yes
/* Input: a0=target string. Output: t0=1 for the host or alias, else zero.
 * Stack: 16 saved bytes. Strings are borrowed; no memory is changed. */
validate_target:
    RV_SAVE a0
    RV_ADDR s6, host_target
    mv a1, s6
    RV_CALL streq
    RV_RESTORE a0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Ltarget_done
    RV_ADDR s6, host_target_alias
    mv a1, s6
    RV_CALL streq
.Ltarget_done:
    ret
/* Input: global argv cursor. Accepts common options until EOF. Returns with the
 * cursor at argc; any operand or unknown option exits with status 2. */
parse_options_only:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lopts_done
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, bad_args
    RV_JUMP parse_options_only
.Lopts_done:
    ret
cmd_help:
    RV_CALL parse_options_only
    RV_ADDR s6, help_text
    mv a0, s6
    RV_ADDR s6, help_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
cmd_version:
    RV_CALL parse_options_only
    RV_ADDR s6, version_text
    mv a0, s6
    RV_ADDR s6, version_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
cmd_license:
    RV_CALL parse_options_only
    RV_ADDR s6, license_text
    mv a0, s6
    RV_ADDR s6, license_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
cmd_targets:
    RV_CALL parse_options_only
    RV_ADDR s6, targets_text
    mv a0, s6
    RV_ADDR s6, targets_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
cmd_status:
    RV_CALL parse_options_only
    RV_ADDR s6, status_json
    mv a0, s6
    RV_CALL out
    RV_JUMP exit_ok
cmd_doctor:
    RV_CALL parse_options_only
    RV_CALL check_tools
    RV_ADDR s6, registry_curl
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldoctor_registry_missing
    RV_ADDR s6, registry_sha256sum
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldoctor_registry_missing
    RV_ADDR s6, doctor_gzip_path
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldoctor_registry_missing
    RV_ADDR s6, doctor_text
    mv a0, s6
    RV_ADDR s6, doctor_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
.Ldoctor_registry_missing:
    RV_ADDR s6, err_registry_tools
    mv a0, s6
    RV_IMM t1, 127, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Check execute access to fixed GNU tool paths. No files are changed. Returns
 * on success; exits 127 with a recovery message if a tool is unavailable. */
check_tools:
    RV_ADDR s6, as_path
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Ltools_missing
    RV_ADDR s6, ld_path
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_access
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Ltools_missing
    ret
.Ltools_missing:
    RV_ADDR s6, err_tools
    mv a0, s6
    RV_IMM t1, 127, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
cmd_unimplemented:
    RV_CALL parse_unimplemented_options
    RV_ADDR s6, err_unimplemented
    mv a0, s6
    RV_IMM t1, 69, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
parse_unimplemented_options:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lunimplemented_done
    mv a0, t0
    RV_ADDR s6, opt_json
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, parse_unimplemented_options
    RV_IMM t1, 1, 32
    RV_ADDR s6, json_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP parse_unimplemented_options
.Lunimplemented_done:
    ret
/* Project creation: preflight all files, use O_EXCL|O_NOFOLLOW, roll back only
 * files/directories created by this invocation if any operation fails. */
cmd_new:
    RV_IMM t1, 1, 32
    RV_ADDR s6, new_mode
    mv s8, s6
    RV_STORE t1, 1
cmd_init:
    RV_ADDR s6, dot
    mv t0, s6
    RV_ADDR s6, project_path
    mv s8, s6
    RV_STORE t0, 8
.Linit_parse:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Linit_parsed
    mv s2, t0
    RV_ADDR s6, literal_path
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
    RV_BCOND ne, .Linit_path
    mv a0, s2
    RV_ADDR s6, opt_separator
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Linit_options
    RV_IMM t1, 1, 32
    RV_ADDR s6, literal_path
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Linit_parse
.Linit_options:
    mv t0, s2
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Linit_parse
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
    RV_BCOND eq, bad_args
.Linit_path:
    RV_ADDR s6, path_seen
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
    RV_BCOND ne, bad_args
    mv a0, s2
    RV_CALL strlen
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, bad_args
    RV_IMM t2, 4095, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, bad_args
    RV_ADDR s6, project_path
    mv s8, s6
    RV_STORE s2, 8
    RV_IMM t1, 1, 32
    RV_ADDR s6, path_seen
    mv s8, s6
    RV_STORE t1, 1
    RV_JUMP .Linit_parse
.Linit_parsed:
    RV_ADDR s6, new_mode
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
    RV_BCOND eq, .Linit_save_cwd
    RV_ADDR s6, path_seen
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
    RV_BCOND eq, bad_args
.Linit_save_cwd:
    RV_ADDR s6, dot
    mv a0, s6
    RV_IMM t1, O_DIRECTORY + O_CLOEXEC, 32
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
    RV_BCOND mi, .Linit_path_error
    RV_ADDR s6, initial_cwd_fd
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, new_mode
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
    RV_BCOND eq, .Linit_chdir
    RV_ADDR s6, project_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_IMM t1, 493, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_mkdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Linit_path_error
    RV_IMM t1, 1, 32
    RV_ADDR s6, made_project
    mv s8, s6
    RV_STORE t1, 1
.Linit_chdir:
    RV_ADDR s6, project_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL rv_chdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, init_rollback
    RV_ADDR s6, manifest_path
    mv a0, s6
    RV_CALL require_absent
    RV_ADDR s6, source_default
    mv a0, s6
    RV_CALL require_absent
    RV_ADDR s6, test_source
    mv a0, s6
    RV_CALL require_absent
    RV_ADDR s6, src_dir
    mv a0, s6
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, init_rollback
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_ADDR s6, made_src
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, tests_dir
    mv a0, s6
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, init_rollback
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    RV_ADDR s6, made_tests
    mv s8, s6
    RV_STORE t1, 1
    /* A name derived from the last path component, if valid; otherwise app. */
    RV_ADDR s6, package_name
    mv a0, s6
    RV_ADDR s6, default_name
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, project_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s2, a1
.Lbasename_scan:
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
    RV_BCOND eq, .Lbasename_ready
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
    RV_BCOND ne, .Lbasename_next
    mv s6, a1
    li s10, 1
    add s6, s6, s10
    mv s2, s6
.Lbasename_next:
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_JUMP .Lbasename_scan
.Lbasename_ready:
    mv a0, s2
    RV_CALL valid_name
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, .Linit_manifest
    RV_ADDR s6, package_name
    mv a0, s6
    mv a1, s2
    RV_CALL copy_string
.Linit_manifest:
    RV_ADDR s6, manifest_buffer
    mv a0, s6
    RV_ADDR s6, manifest_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, package_name
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, manifest_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, manifest_path
    mv a0, s6
    RV_ADDR s6, manifest_buffer
    mv a1, s6
    RV_ADDR s6, made_manifest
    mv a2, s6
    RV_CALL create_exclusive_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, init_rollback
    RV_ADDR s6, source_default
    mv a0, s6
    RV_ADDR s6, main_template
    mv a1, s6
    RV_ADDR s6, made_main
    mv a2, s6
    RV_CALL create_exclusive_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, init_rollback
    RV_ADDR s6, test_source
    mv a0, s6
    RV_ADDR s6, test_template
    mv a1, s6
    RV_ADDR s6, made_test
    mv a2, s6
    RV_CALL create_exclusive_file
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, init_rollback
    RV_ADDR s6, init_text
    mv a0, s6
    RV_ADDR s6, init_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
.Linit_path_error:
    RV_ADDR s6, err_init_path
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Input: a0=initialization output path. Returns only for ENOENT from lstat.
 * Every other result triggers initialization rollback. Scratch: stat_buffer
 * (128 bytes), syscall registers. No symlink is followed for the final path. */
require_absent:
    RV_ADDR s6, stat_buffer
    mv a1, s6
    RV_CALL rv_lstat
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, init_rollback
    ret
/* Input: a0=directory path. Output: t0=1 created, 0 existing real directory,
 * or -1 on failure. Uses lstat after EEXIST; this is not a race-free sandbox.
 * Scratch: stat_buffer (128 bytes), caller-saved registers. Stack: 16 bytes. */
make_safe_dir:
    RV_SAVE s0
    mv s0, a0
    RV_IMM t1, 493, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_mkdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Ldir_created
    RV_IMM t2, -17, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Ldir_fail
    mv a0, s0
    RV_ADDR s6, stat_buffer
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Ldir_fail
    RV_ADDR s6, stat_buffer + 16
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
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Ldir_fail
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_RESTORE s0
    ret
.Ldir_created:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    RV_RESTORE s0
    ret
.Ldir_fail:
    RV_IMM t1, -1, 64
    mv t0, t1
    RV_RESTORE s0
    ret
/* Input: a0=path, a1=content string, a2=owned one-byte creation flag.
 * Creates mode 0644 with O_EXCL|O_NOFOLLOW and sets the flag only after open.
 * Output: zero or negative errno from open/write/close. Caller rolls back a
 * partially written file. Stack: 48 saved bytes plus nested calls. */
create_exclusive_file:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    mv s2, a1
    mv s3, a2
    RV_IMM t1, O_NOFOLLOW + O_CLOEXEC + 193, 32
    mv a1, t1
    RV_ZEXT a1
    RV_IMM t1, 420, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_open
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcreate_end
    RV_IMM t1, 1, 32
    mv s6, s3
    mv s8, s6
    RV_STORE t1, 1
    mv s0, t0
    mv a0, s0
    mv a1, s2
    RV_CALL write_cstr
    mv s2, t0
    mv a0, s0
    RV_CALL rv_close
    mv s8, s2
    mv s10, s2
    RV_FLAGS and, 64
    RV_BCOND mi, .Lcreate_write_error
    RV_JUMP .Lcreate_end
.Lcreate_write_error:
    mv t0, s2
.Lcreate_end:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* No return. Uses creation flags to remove only this invocation's outputs.
 * A new project directory is removed only after restoring the original cwd.
 * Existing files and directories have zero creation flags and are retained. */
init_rollback:
    RV_ADDR s6, made_test
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
    RV_BCOND eq, .Lrollback_main
    RV_ADDR s6, test_source
    mv a0, s6
    RV_CALL rv_unlink
.Lrollback_main:
    RV_ADDR s6, made_main
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
    RV_BCOND eq, .Lrollback_manifest
    RV_ADDR s6, source_default
    mv a0, s6
    RV_CALL rv_unlink
.Lrollback_manifest:
    RV_ADDR s6, made_manifest
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
    RV_BCOND eq, .Lrollback_tests
    RV_ADDR s6, manifest_path
    mv a0, s6
    RV_CALL rv_unlink
.Lrollback_tests:
    RV_ADDR s6, made_tests
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
    RV_BCOND eq, .Lrollback_src
    RV_ADDR s6, tests_dir
    mv a0, s6
    RV_CALL rv_rmdir
.Lrollback_src:
    RV_ADDR s6, made_src
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
    RV_BCOND eq, .Lrollback_project
    RV_ADDR s6, src_dir
    mv a0, s6
    RV_CALL rv_rmdir
.Lrollback_project:
    RV_ADDR s6, made_project
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
    RV_BCOND eq, .Lrollback_error
    RV_ADDR s6, initial_cwd_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL rv_fchdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lrollback_error
    RV_ADDR s6, project_path
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_CALL rv_rmdir
.Lrollback_error:
    RV_ADDR s6, err_init_conflict
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Strict, documented TOML subset. Sections and string fields are parsed, not
 * ignored. Unknown keys, duplicate fields, escapes and unsupported targets fail. */
/* Input: cwd is the project. Output: package_* buffers contain validated fields.
 * Reads a regular, non-symlink asm.toml with at most 8190 bytes. Field capacities
 * include NUL: name=65, version/target=64, source/native fields=256.
 * Failure exits without build
 * changes. Stack: 64 saved bytes plus nested calls; all callee-saved restored. */
read_manifest:
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s6, manifest_path
    mv a0, s6
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
    RV_BCOND mi, manifest_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, stat_buffer
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lmanifest_close_error
    RV_ADDR s6, stat_buffer + 16
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
    RV_BCOND ne, .Lmanifest_close_error
    RV_ADDR s6, stat_buffer + 48
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lmanifest_close_error
    RV_IMM t2, 8191, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lmanifest_close_error
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Lmanifest_read:
    mv a0, s2
    RV_ADDR s6, manifest_buffer
    mv a1, s6
    mv s8, a1
    mv s10, s3
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t1, 8191, 32
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
    RV_BCOND eq, .Lmanifest_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lmanifest_close_error
    RV_BCOND eq, .Lmanifest_read_done
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    RV_IMM t2, 8191, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lmanifest_close_error
    RV_JUMP .Lmanifest_read
.Lmanifest_read_done:
    RV_ADDR s6, manifest_buffer
    mv t0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lmanifest_no_nul:
    mv s8, a3
    mv s10, s3
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lmanifest_terminate
    mv s6, t0
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
    RV_BCOND eq, .Lmanifest_close_error
    RV_IMM t2, 1, 64
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 64
    mv a3, s11
    RV_JUMP .Lmanifest_no_nul
.Lmanifest_terminate:
    RV_IMM t1, 0, 32
    mv s6, t0
    mv s10, s3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv a0, s2
    RV_CALL rv_close
    RV_ADDR a0, rm_root_original
    RV_ADDR a1, manifest_buffer
    RV_CALL copy_string
    RV_ADDR a0, manifest_buffer
    RV_ADDR a1, rm_root_metadata
    RV_CALL rm_parse_manifest
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_asm1119
    RV_JUMP manifest_error
.Lrv_cb_skip_asm1119:
    RV_ADDR a0, package_name
    RV_ADDR s6, rm_root_metadata + 24
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, package_version
    RV_ADDR s6, rm_root_metadata + 32
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, package_source
    RV_ADDR s6, rm_root_metadata + 40
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, package_target
    RV_ADDR s6, rm_root_metadata + 48
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, package_link
    RV_ADDR s6, rm_root_metadata + RM_LINK
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, package_libraries
    RV_ADDR s6, rm_root_metadata + RM_LIBRARIES
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_ADDR a0, package_check
    RV_ADDR s6, rm_root_metadata + RM_CHECK
    mv s8, s6
    RV_LOAD a1, 8
    RV_CALL copy_string
    RV_CALL native_link_check_options
    RV_ADDR a0, package_target
    RV_CALL validate_target
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_asm1151
    RV_JUMP unsupported_target
.Lrv_cb_skip_asm1151:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    ret
.Lmanifest_close_error:
    mv a0, s2
    RV_CALL rv_close
manifest_error:
    RV_ADDR s6, err_manifest
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Input: a0=project name. Output: t0=1 for [a-z][a-z0-9-]{0,63}, else zero.
 * Scratch: t0/a3. Registry namespace validation is a separate stricter rule. */
valid_name:
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
    RV_BCOND lo, .Linvalid
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
    RV_BCOND hi, .Linvalid
    RV_IMM t1, 1, 32
    mv a3, t1
    RV_ZEXT a3
.Lname_loop:
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
    RV_BCOND eq, .Lvalid
    RV_IMM t2, 64, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Linvalid
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
    RV_BCOND eq, .Lname_next
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
    RV_BCOND lo, .Linvalid
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
    RV_BCOND ls, .Lname_next
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
    RV_BCOND lo, .Linvalid
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
    RV_BCOND hi, .Linvalid
.Lname_next:
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lname_loop
/* Input: a0=bounded manifest version (at most 63 chars). Output: t0=1 for
 * numeric major.minor.patch without leading zeroes, else zero. No integer
 * conversion occurs here. Registry versions impose a separate numeric limit. */
valid_version:
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
.Lversion_component:
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
    RV_BCOND lo, .Linvalid
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
    RV_BCOND hi, .Linvalid
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    li s10, 255
    slli s11, t1, 0
    and s11, s11, s10
    not s10, s10
    and a4, a4, s10
    or a4, a4, s11
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
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
    RV_BCOND eq, .Lversion_sep
.Lversion_digits:
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
    RV_BCOND lo, .Lversion_sep
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
    RV_BCOND hi, .Lversion_sep
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_IMM t2, 63, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hs, .Linvalid
    RV_JUMP .Lversion_digits
.Lversion_sep:
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
    RV_BCOND eq, .Lversion_final
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
    RV_BCOND ne, .Linvalid
    RV_IMM t2, 1, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS add, 32
    mv a2, s11
    RV_IMM t2, 2, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, .Linvalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lversion_component
.Lversion_final:
    RV_IMM t2, 2, 32
    mv s8, a2
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lvalid
    RV_JUMP .Linvalid
/* Input: a0=source path already bounded to 255 chars. Output: t0=1 for a
 * relative path with no empty/. /.. or option-like segments, else zero. This
 * validates syntax; assembly and included files remain trusted local input. */
valid_source:
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
    RV_BCOND eq, .Linvalid
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
.Lsource_segment:
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
    RV_IMM t2, 45, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Linvalid
    mv a2, a3
    RV_ZEXT a2
.Lsource_loop:
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
    RV_BCOND eq, .Lsource_end_segment
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
    RV_BCOND eq, .Lsource_end_segment
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
    RV_BCOND lo, .Linvalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lsource_loop
.Lsource_end_segment:
    mv a4, a3
    RV_ZEXT a4
    mv s8, a4
    mv s10, a2
    RV_FLAGS sub, 32
    mv a4, s11
    RV_BCOND eq, .Linvalid
    mv s6, a0
    mv s10, a2
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
    RV_BCOND ne, .Lsource_continue
    RV_IMM t2, 1, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Linvalid
    RV_IMM t2, 2, 32
    mv s8, a4
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lsource_continue
    mv s6, a0
    mv s10, a2
    add s6, s6, s10
    li s10, 1
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
    RV_BCOND eq, .Linvalid
.Lsource_continue:
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
    RV_BCOND eq, .Lvalid
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    RV_JUMP .Lsource_segment
.Lvalid:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    ret
.Linvalid:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Build outputs in a fresh process-specific staging directory, then rename
 * completed artifacts into place. Never pass project paths through a shell. */
cmd_build:
    RV_ADDR s6, native_allow
    li t1, 1
    RV_ZEXT t1
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 1, 32
    RV_ADDR s6, allow_locked
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL parse_options_only
    RV_CALL read_manifest
    RV_CALL build_project
    RV_ADDR s6, build_text
    mv a0, s6
    RV_ADDR s6, build_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
cmd_run:
    RV_ADDR s6, native_allow
    li t1, 1
    RV_ZEXT t1
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 1, 32
    RV_ADDR s6, allow_locked
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 1, 32
    RV_ADDR s6, run_mode
    mv s8, s6
    RV_STORE t1, 1
.Lrun_options:
    RV_CALL next_arg
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lrun_args_done
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, opt_separator
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Lrun_args_done
    mv t0, s2
    RV_CALL common_option
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, bad_args
    RV_JUMP .Lrun_options
.Lrun_args_done:
    RV_ADDR s6, argi
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_ADDR s6, run_argi
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL read_manifest
    RV_CALL build_project
    /* Reuse argv's contiguous tail, replacing the preceding slot with argv0. */
    RV_ADDR s6, run_argi
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    RV_IMM t2, 1, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    mv t0, s11
    RV_ADDR s6, argv
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    mv s6, a1
    mv s10, t0
    slli s10, s10, 3
    add s6, s6, s10
    mv a1, s6
    RV_ADDR s6, app_output
    mv a0, s6
    mv s6, a1
    mv s8, s6
    RV_STORE a0, 8
    RV_CALL spawn_wait
    mv a0, t0
    RV_ZEXT a0
    RV_JUMP exit_code
cmd_test:
    RV_ADDR s6, native_allow
    li t1, 1
    RV_ZEXT t1
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t1, 1, 32
    RV_ADDR s6, allow_locked
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL parse_options_only
    RV_CALL read_manifest
    RV_IMM t1, 1, 32
    RV_ADDR s6, test_mode
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL build_project
    RV_ADDR s6, test_output
    mv a0, s6
    RV_ADDR s6, child_argv
    mv s8, s6
    RV_STORE a0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, child_argv + 8
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, child_argv
    mv a1, s6
    RV_CALL spawn_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, .Ltest_failed
    RV_ADDR s6, test_text
    mv a0, s6
    RV_ADDR s6, test_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
.Ltest_failed:
    mv a1, t0
    RV_ZEXT a1
    RV_ADDR s6, err_test
    mv a0, s6
    RV_JUMP die
/* Input: cwd is a trusted local project; package_source was parsed and bounded.
 * test_mode selects tests/main.s. Output: build/app or build/test, plus object.
 * Object rename occurs first; binary rename is the final publication step.
 * Returns on success. On failure, removes this process's stage and exits with
 * the child status or 1. Stage paths have capacities 64/96/96. Stack: 16 bytes. */
build_project:
    RV_SAVE s2
    RV_CALL check_tools
    RV_CALL verify_project_dependencies
    RV_ADDR s6, build_dir
    mv a0, s6
    RV_CALL make_safe_dir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_directory_error
    RV_ADDR s6, stage_dir
    mv a0, s6
    RV_ADDR s6, stage_prefix
    mv a1, s6
    RV_CALL copy_string
    mv s2, t0
    RV_CALL rv_getpid
    mv a0, t0
    RV_ADDR s6, number_buffer + 31
    mv a1, s6
    RV_CALL unsigned_decimal
    mv a0, s2
    mv a1, t0
    RV_CALL copy_string
    RV_ADDR s6, stage_dir
    mv a0, s6
    RV_IMM t1, 448, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_mkdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_directory_error
    RV_ADDR s6, stage_object
    mv a0, s6
    RV_ADDR s6, stage_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, object_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, stage_binary
    mv a0, s6
    RV_ADDR s6, stage_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, binary_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_CALL native_link_compile_check
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_asm1585
    RV_JUMP build_child_error
.Lrv_cb_skip_asm1585:
    RV_CALL rv_prepare_assembly
    RV_ADDR s6, as_path
    mv a0, s6
    RV_ADDR s6, child_argv
    mv a1, s6
    RV_CALL spawn_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, build_child_error
    RV_ADDR s6, package_link
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_asm1596
    RV_JUMP .Lbuild_standalone_link
.Lrv_cb_skip_asm1596:
    RV_CALL native_link_build
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_asm1598
    RV_JUMP build_child_error
.Lrv_cb_skip_asm1598:
    RV_JUMP .Lbuild_linked
.Lbuild_standalone_link:
    RV_ADDR s6, ld_path
    mv t0, s6
    RV_ADDR s6, child_argv
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, arg_z
    mv t0, s6
    RV_ADDR s6, child_argv + 8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, noexecstack
    mv t0, s6
    RV_ADDR s6, child_argv + 16
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, arg_o
    mv t0, s6
    RV_ADDR s6, child_argv + 24
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, stage_binary
    mv t0, s6
    RV_ADDR s6, child_argv + 32
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, stage_object
    mv t0, s6
    RV_ADDR s6, child_argv + 40
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, child_argv + 48
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR s6, ld_path
    mv a0, s6
    RV_ADDR s6, child_argv
    mv a1, s6
    RV_CALL spawn_wait
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, build_child_error
.Lbuild_linked:
    RV_ADDR s6, stage_object
    mv a0, s6
    RV_ADDR s6, object_output
    mv a1, s6
    RV_ADDR s6, test_mode
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
    RV_BCOND eq, .Lrename_object
    RV_ADDR s6, test_object_output
    mv a1, s6
.Lrename_object:
    RV_CALL rv_rename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_io_error
    RV_ADDR s6, stage_binary
    mv a0, s6
    RV_ADDR s6, app_output
    mv a1, s6
    RV_ADDR s6, test_mode
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
    RV_BCOND eq, .Lrename_binary
    RV_ADDR s6, test_output
    mv a1, s6
.Lrename_binary:
    RV_CALL rv_rename
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, build_io_error
    RV_CALL cleanup_stage
    RV_CALL release_dependency_lock
    RV_RESTORE s2
    ret
build_child_error:
    mv s5, t0
    RV_ZEXT s5
    RV_CALL cleanup_stage
    RV_ADDR s6, err_build
    mv a0, s6
    mv a1, s5
    RV_ZEXT a1
    RV_JUMP die
build_io_error:
    RV_CALL cleanup_stage
build_directory_error:
    RV_ADDR s6, err_build_io
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Input: stage paths refer to the directory this process created. Removes only
 * its two known files and then its empty directory. Scratch: syscall registers.
 * Cleanup errors do not replace the original failure status. Stack: none. */
cleanup_stage:
    RV_ADDR s6, stage_object
    mv a0, s6
    RV_CALL rv_unlink
    RV_ADDR s6, stage_binary
    mv a0, s6
    RV_CALL rv_unlink
    RV_ADDR s6, stage_dir
    mv a0, s6
    RV_CALL rv_rmdir
    ret
/* Input: a0=unsigned 64-bit value; a1=last byte of a writable >=21-byte buffer.
 * Output: t0 points to the decimal string within that buffer. Writes backward
 * from a1, including its NUL terminator. Scratch: t0/a2/a1/a4. Stack: none. */
unsigned_decimal:
    RV_IMM t1, 0, 32
    mv s6, a1
    mv s8, s6
    RV_STORE t1, 1
    mv t0, a0
    RV_IMM t1, 10, 32
    mv a4, t1
    RV_ZEXT a4
.Ldecimal_loop:
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
/* Caller establishes a2 = 0 and a nonzero divisor. */
    mv t1, t0
    beqz a4, .Lrv_div_zero_asm1719
    divu t0, t1, a4
    j .Lrv_div_done_asm1719
.Lrv_div_zero_asm1719:
    li t0, 0
.Lrv_div_done_asm1719:
    mul s8, t0, a4
    sub a2, t1, s8
    li s10, 255
    and t1, a2, s10
    RV_ZEXT t1
    RV_IMM t2, 48, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS add, 32
    mv t3, s11
    srliw t3, t3, 24
    RV_ZEXT t3
    li s10, 255
    slli s11, t3, 0
    and s11, s11, s10
    not s10, s10
    and a2, a2, s10
    or a2, a2, s11
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS sub, 64
    mv a1, s11
    li s10, 255
    and t1, a2, s10
    RV_ZEXT t1
    mv s6, a1
    mv s8, s6
    RV_STORE t1, 1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Ldecimal_loop
    mv t0, a1
    ret
/* Spawn a fixed executable with explicit argv and inherited file streams.
 * Compiler drivers use a fixed environment; application children inherit env.
 * Return child's exit code, or 128+signal; never turn a failed exec into success. */
/* Input: a0=executable path, a1=NUL-terminated argv pointer array. All pointers
 * remain owned by the parent. Output: t0=0..255; fork/wait/exec failure is 127.
 * Retries interrupted waits. Stack: 48 saved bytes. No shell is involved. */
spawn_wait:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    mv s2, a0
    mv s3, a1
    RV_CALL rv_fork
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lspawn_failed
    RV_BCOND eq, .Lspawn_child
    mv s0, t0
.Lwait_again:
    mv a0, s0
    RV_ADDR s6, child_status
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
    RV_BCOND eq, .Lwait_again
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lspawn_failed
    RV_ADDR s6, child_status
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
    RV_BCOND ne, .Lspawn_signal
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
    RV_JUMP .Lspawn_return
.Lspawn_signal:
    mv s6, a2
    li s10, 128
    add s6, s6, s10
    mv t0, s6
    RV_ZEXT t0
    RV_JUMP .Lspawn_return
.Lspawn_child:
    mv a0, s2
    RV_CALL native_link_child_environment
    mv a2, t0
    mv a0, s2
    mv a1, s3
    RV_CALL rv_execve
    RV_IMM t1, 127, 32
    mv a0, t1
    RV_ZEXT a0
    RV_JUMP exit_code
.Lspawn_failed:
    RV_IMM t1, 127, 32
    mv t0, t1
    RV_ZEXT t0
.Lspawn_return:
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
cmd_clean:
    RV_CALL parse_options_only
    RV_CALL read_manifest
    RV_ADDR s6, build_dir
    mv a0, s6
    RV_ADDR s6, stat_buffer
    mv a1, s6
    RV_CALL rv_lstat
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lclean_done
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lclean_error
    RV_ADDR s6, stat_buffer + 16
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
    RV_IMM t2, 16384, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lclean_error
    RV_ADDR s6, app_output
    mv a0, s6
    RV_CALL clean_file
    RV_ADDR s6, object_output
    mv a0, s6
    RV_CALL clean_file
    RV_ADDR s6, test_output
    mv a0, s6
    RV_CALL clean_file
    RV_ADDR s6, test_object_output
    mv a0, s6
    RV_CALL clean_file
    RV_ADDR s6, build_dir
    mv a0, s6
    RV_CALL rv_rmdir
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lclean_done
    RV_IMM t2, -39, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lclean_done
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lclean_error
.Lclean_done:
    RV_ADDR s6, clean_text
    mv a0, s6
    RV_ADDR s6, clean_json
    mv a1, s6
    RV_CALL report
    RV_JUMP exit_ok
.Lclean_error:
    RV_ADDR s6, err_clean
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_JUMP die
/* Input: a0=one fixed Asm artifact path. Unlinks the final entry, not its
 * symlink target. Returns for success or ENOENT; other errors exit. */
clean_file:
    RV_CALL rv_unlink
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, .Lclean_file_done
    RV_IMM t2, -2, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lclean_error
.Lclean_file_done:
    ret
.section .rodata
commands:
.quad command_help, cmd_help, command_version, cmd_version
.quad command_license, cmd_license
.quad command_self, cmd_self
.quad command_doctor, cmd_doctor, command_init, cmd_init
.quad command_new, cmd_new, command_build, cmd_build
.quad command_run, cmd_run, command_test, cmd_test
.quad command_clean, cmd_clean, command_target, cmd_targets
.quad command_targets, cmd_targets, command_status, cmd_status
.quad command_add, cmd_add, command_remove, cmd_remove
.quad command_resolve, cmd_resolve
.quad command_search, cmd_search, command_publish, cmd_publish
.quad command_info, cmd_info, command_versions, cmd_versions
.quad command_fetch, cmd_fetch
.quad command_install, cmd_install, command_update, cmd_update
.quad command_installed, cmd_installed, command_upgrade, cmd_upgrade
.quad command_uninstall, cmd_uninstall
.quad command_lock, cmd_lock, command_login, cmd_unimplemented
.quad command_sync, cmd_sync
.quad command_yank, cmd_unimplemented, 0, 0
command_help: .asciz "help"
command_version: .asciz "version"
command_license: .asciz "license"
command_self: .asciz "self"
command_doctor: .asciz "doctor"
command_init: .asciz "init"
command_new: .asciz "new"
command_build: .asciz "build"
command_run: .asciz "run"
command_test: .asciz "test"
command_clean: .asciz "clean"
command_target: .asciz "target"
command_targets: .asciz "targets"
command_status: .asciz "status"
command_add: .asciz "add"
command_resolve: .asciz "resolve"
command_remove: .asciz "remove"
command_search: .asciz "search"
command_info: .asciz "info"
command_versions: .asciz "versions"
command_fetch: .asciz "fetch"
command_publish: .asciz "publish"
command_install: .asciz "install"
command_installed: .asciz "installed"
command_upgrade: .asciz "upgrade"
command_uninstall: .asciz "uninstall"
command_update: .asciz "update"
command_lock: .asciz "lock"
command_sync: .asciz "sync"
command_login: .asciz "login"
command_yank: .asciz "yank"
opt_json: .asciz "--json"
opt_no_color: .asciz "--no-color"
opt_help: .asciz "--help"
opt_h: .asciz "-h"
opt_version: .asciz "--version"
opt_V: .asciz "-V"
opt_license: .asciz "--license"
opt_target: .asciz "--target"
opt_locked: .asciz "--locked"
opt_separator: .asciz "--"
host_target: .asciz "riscv64-linux"
host_target_alias: .asciz "riscv64-unknown-linux-gnu"
as_path: .asciz "/usr/bin/as"
ld_path: .asciz "/usr/bin/ld"
as_arch: .asciz "-march=rv64i"
arg_o: .asciz "-o"
arg_I: .asciz "-I"
arg_z: .asciz "-z"
noexecstack: .asciz "noexecstack"
dot: .asciz "."
manifest_path: .asciz "asm.toml"
source_default: .asciz "src/main.s"
test_source: .asciz "tests/main.s"
src_dir: .asciz "src"
tests_dir: .asciz "tests"
build_dir: .asciz "build"
app_output: .asciz "build/app"
object_output: .asciz "build/main.o"
test_output: .asciz "build/test"
test_object_output: .asciz "build/test.o"
stage_prefix: .asciz "build/.asm-"
object_suffix: .asciz "/main.o"
binary_suffix: .asciz "/app"
default_name: .asciz "app"
newline: .asciz "\n"
error_prefix: .asciz "asm: "
error_json_prefix: .asciz "{\"ok\":false,\"error\":\""
error_json_suffix: .asciz "\"}\n"
err_unknown_command: .asciz "unknown command; use asm help"
err_arguments: .asciz "invalid arguments; use asm help"
err_output: .asciz "cannot write command output; check the output destination and try again"
err_target: .asciz "unsupported target; this release supports riscv64-linux only"
err_tools: .asciz "GNU as and ld must be executable at /usr/bin/as and /usr/bin/ld"
err_registry_tools: .asciz "registry and source commands require curl, sha256sum and gzip in /usr/bin. Install the missing tools"
err_unimplemented: .asciz "this command is not implemented; run asm status to see command support"
err_init_path: .asciz "cannot create project directory; new requires a path that does not exist"
err_init_conflict: .asciz "cannot initialize project; existing files and symlink directories are never overwritten"
err_manifest: .asciz "invalid or missing asm.toml; expected package name/version and build source/target"
err_build: .asciz "build failed; see tool diagnostics above"
err_build_io: .asciz "cannot write build artifacts; build must be a real directory"
err_test: .asciz "test program failed"
err_clean: .asciz "cannot clean artifacts; build must be a real directory"
version_text: .asciz "asm 0.5.0 (riscv64-linux)\n"
version_json: .asciz "{\"name\":\"asm\",\"version\":\"0.5.0\",\"host\":\"riscv64-linux\"}\n"
license_text: .asciz "asm 0.5.0\nCopyright (c) 2026 ASM contributors\nLicense: AGPL-3.0-or-later\nYou may copy, modify, and redistribute Asm under this license.\nAsm is provided without warranty.\nTerms: https://www.gnu.org/licenses/agpl-3.0.html\nSource: https://github.com/stubbi/asm/tree/v0.5.0\nStarter code and examples: MIT. Packages retain their own licenses.\n"
license_json: .asciz "{\"license\":\"AGPL-3.0-or-later\",\"template_license\":\"MIT\",\"copyright\":\"Copyright (c) 2026 ASM contributors\",\"warranty\":false,\"terms\":\"https://www.gnu.org/licenses/agpl-3.0.html\",\"source\":\"https://github.com/stubbi/asm/tree/v0.5.0\"}\n"
targets_text: .asciz "riscv64-linux (host; GNU as + ld)\n"
targets_json: .asciz "{\"host\":\"riscv64-linux\",\"targets\":[\"riscv64-linux\"]}\n"
doctor_gzip_path: .asciz "/usr/bin/gzip"
doctor_text: .asciz "Host: riscv64-linux\nBuild: /usr/bin/as and /usr/bin/ld\nRegistry: /usr/bin/curl and /usr/bin/sha256sum\nSource archives: /usr/bin/gzip\nRequired tools are available.\n"
doctor_json: .asciz "{\"ok\":true,\"host\":\"riscv64-linux\",\"assembler\":\"/usr/bin/as\",\"linker\":\"/usr/bin/ld\",\"curl\":\"/usr/bin/curl\",\"sha256sum\":\"/usr/bin/sha256sum\",\"gzip\":\"/usr/bin/gzip\"}\n"
init_text: .asciz "Created asm.toml, src/main.s and tests/main.s.\nNext: asm run\n"
init_json: .asciz "{\"ok\":true,\"created\":[\"asm.toml\",\"src/main.s\",\"tests/main.s\"]}\n"
build_text: .asciz "Built build/app\n"
build_json: .asciz "{\"ok\":true,\"artifact\":\"build/app\"}\n"
test_text: .asciz "Passed tests/main.s\n"
test_json: .asciz "{\"ok\":true,\"test\":\"tests/main.s\"}\n"
clean_text: .asciz "Removed Asm build artifacts.\n"
clean_json: .asciz "{\"ok\":true,\"cleaned\":true}\n"
help_text:
.ascii "asm 0.5.0 - build assembly projects\n\n"
.ascii "Usage: asm [--json] [--no-color] <command> [options]\n\n"
.ascii "  new <path>       Create a project in a new directory\n"
.ascii "  init [path]      Initialize an existing directory (default: .)\n"
.ascii "  build            Assemble and link to build/app\n"
.ascii "  run [-- args]    Build, then run with forwarded arguments\n"
.ascii "  test             Assemble and execute tests/main.s\n"
.ascii "  clean            Remove only Asm's named build artifacts\n"
.ascii "  search [query]   Search the package registry\n"
.ascii "  info <package>   Show registry package metadata\n"
.ascii "  versions <pkg>   List published package versions\n"
.ascii "  fetch <pkg[@v]>  Fetch and verify an artifact; do not run it\n"
.ascii "  install <pkg>    Install a host executable without running it\n"
.ascii "  installed        List recorded installed programs\n"
.ascii "  upgrade <pkg[@v]> Upgrade a recorded program\n"
.ascii "  uninstall <pkg>  Uninstall an unchanged recorded program\n"
.ascii "  resolve          Resolve declared dependency ranges and features\n"
.ascii "  add <pkg@v>      Add an exact source dependency and lock its digest\n"
.ascii "  update <pkg@v>   Update a direct dependency to an exact version\n"
.ascii "  remove <pkg>     Remove a lock selection; retain cache files\n"
.ascii "  lock             Check every locked archive and source file\n"
.ascii "  sync             Fetch and extract exact locked source artifacts\n"
.ascii "  publish          Prepare a release record for review; do not upload\n"
.ascii "  doctor           Check required tools\n"
.ascii "  targets          List supported targets\n"
.ascii "  status           Print machine-readable command availability\n"
.ascii "  version          Print the CLI version\n"
.ascii "  license          Show the license, warranty, and source\n"
.ascii "  self update      Update this user installation from the hub\n"
.ascii "  help             Show this help\n\n"
.ascii "Options: --target riscv64-linux, --json, --no-color, --help\n"
.ascii "Build/run/test verify existing locks. --locked also requires asm.lock.\n"
.ascii "Native builds: --include-dir PATH and --library-dir PATH (repeat up to eight).\n"
.ascii "For a path starting with -, use: asm new -- <path>\n"
.ascii "JSON describes Asm's own output; child output is passed through.\n"
.ascii "For registry options, use asm search --help.\n"
.ascii "Unimplemented commands fail with exit status 69; use asm status.\n"
.ascii "License: AGPL-3.0-or-later. No warranty. Use asm license for terms.\n"
.byte 0
help_json:
.asciz "{\"name\":\"asm\",\"version\":\"0.5.0\",\"usage\":\"asm [--json] <command> [options]\",\"commands\":[\"new\",\"init\",\"build\",\"run\",\"test\",\"clean\",\"search\",\"info\",\"versions\",\"fetch\",\"install\",\"installed\",\"upgrade\",\"uninstall\",\"add\",\"update\",\"remove\",\"resolve\",\"lock\",\"sync\",\"doctor\",\"targets\",\"status\",\"version\",\"help\",\"publish\",\"license\",\"self\"],\"license\":\"AGPL-3.0-or-later\",\"template_license\":\"MIT\"}\n"
status_json:
.asciz "{\"version\":\"0.5.0\",\"implementation\":\"riscv64 assembly\",\"targets\":[\"riscv64-linux\"],\"implemented\":[\"help\",\"version\",\"doctor\",\"init\",\"new\",\"build\",\"run\",\"test\",\"clean\",\"targets\",\"status\",\"search\",\"info\",\"versions\",\"fetch\",\"install\",\"installed\",\"upgrade\",\"uninstall\",\"add\",\"update\",\"remove\",\"resolve\",\"lock\",\"sync\",\"publish\",\"license\",\"self\"],\"unimplemented\":[\"login\",\"yank\"],\"license\":\"AGPL-3.0-or-later\",\"template_license\":\"MIT\"}\n"
.include "cli/riscv64/templates.s"
.section .bss
.balign 8
argc: .skip 8
argv: .skip 8
envp: .skip 8
argi: .skip 8
run_argi: .skip 8
project_path: .skip 8
initial_cwd_fd: .skip 8
child_argv: .skip 128
child_status: .skip 8
stat_buffer: .skip 128
number_buffer: .skip 32
stage_dir: .skip 64
stage_object: .skip 96
stage_binary: .skip 96
package_name: .skip 65
package_version: .skip 64
package_source: .skip 256
package_target: .skip 64
manifest_buffer: .skip 8192
rm_root_original: .skip 8192
.balign 8
rm_root_metadata: .skip RM_SIZE
json_mode: .skip 1
allow_locked: .skip 1
require_lock: .skip 1
new_mode: .skip 1
run_mode: .skip 1
test_mode: .skip 1
literal_path: .skip 1
path_seen: .skip 1
made_project: .skip 1
made_src: .skip 1
made_tests: .skip 1
made_manifest: .skip 1
made_main: .skip 1
made_test: .skip 1
.section .note.GNU-stack,""
/* Keep one assembler translation unit so the CLI can build itself with the
 * standard single-source asm.toml. GNU as resolves .include from project cwd. */
.include "cli/riscv64/native_link.s"
.include "cli/riscv64/programs.s"
.include "cli/riscv64/registry.s"
.include "cli/riscv64/elf.s"
.include "cli/riscv64/archive.s"
.include "cli/riscv64/dependencies.s"
.include "cli/riscv64/resolver.s"
.include "cli/riscv64/publish.s"
.include "cli/riscv64/self_update.s"
.include "cli/riscv64/self_update_verify.s"
.include "cli/riscv64/self_update_metadata.s"
.include "cli/riscv64/platform.s"
.ifdef ASM_TRUSTED_DISTRIBUTION
.include "cli/riscv64/self_update_trust.s"
.endif
.include "cli/riscv64/build.s"
