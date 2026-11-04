/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.include "cli/aarch64/platform.inc"
.global _start
.global next_arg, streq, strlen, copy_string, out, write_cstr, write_all
.global die, exit_ok, exit_code, spawn_wait, unsigned_decimal
.global create_exclusive_file, json_mode
.extern cmd_search, cmd_info, cmd_versions, cmd_fetch, cmd_install

/* Native AArch64 implementation. No C runtime or shell backend is used.
 * The internal ABI is defined in platform.inc. Arguments use x0-x7; x9 is
 * the result. Returning routines preserve x19-x24. Calls use BL/RET and
 * 16-byte aligned SP. Typed adapters invoke the native Linux syscall ABI.
 * String inputs require accessible NUL termination. File strings use bounded
 * parsers. Command and fatal-error labels do not return.
 */

.section .text
_start:
    // Forward string loops do not use a direction flag.
    mov x16, sp
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, argc
    str x9, [x16]
    mov x16, sp
    add x16, x16, #8
    mov x9, x16
    ARM_ADDR x16, argv
    str x9, [x16]
    ARM_ADDR x16, argc
    ldr x10, [x16]
    mov x3, x10
    mov x16, x9
    add x16, x16, x3, lsl #3
    add x16, x16, #8
    mov x9, x16
    ARM_ADDR x16, envp
    str x9, [x16]
    ARM_IMM x10, 1
    ARM_ADDR x16, argi
    str x10, [x16]
.Lglobals:
    ARM_CALL next_arg
    tst x9, x9
    b.eq cmd_help
    mov x21, x9
    ARM_ADDR x16, opt_json
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne .Lglobal_json
    ARM_ADDR x16, opt_no_color
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne .Lglobals
    ARM_ADDR x16, opt_help
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_help
    ARM_ADDR x16, opt_h
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_help
    ARM_ADDR x16, opt_version
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_version
    ARM_ADDR x16, opt_V
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_version
    ARM_ADDR x16, opt_license
    mov x1, x16
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_license
    ARM_ADDR x16, commands
    mov x19, x16
.Ldispatch:
    mov x16, x19
    ldr x10, [x16]
    mov x1, x10
    tst x1, x1
    b.eq unknown_command
    mov x0, x21
    ARM_CALL streq
    tst w9, w9
    b.ne .Ldispatch_match
    ARM_IMM x11, 16
    adds x19, x19, x11
    b .Ldispatch
.Ldispatch_match:
    mov x16, x19
    add x16, x16, #8
    ldr x11, [x16]
    br x11
.Lglobal_json:
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b .Lglobals

/* Input: global argc/argv/argi from the initial Linux stack. Output: x9 is the
 * next borrowed argv pointer, or zero. Advances argi only for an existing arg.
 * Stack: none. Bounds: argi is checked against argc before the pointer load. */
next_arg:
    ARM_ADDR x16, argi
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, argc
    ldr x11, [x16]
    cmp x9, x11
    b.hs .Lnext_none
    ARM_ADDR x16, argv
    ldr x10, [x16]
    mov x3, x10
    mov x16, x3
    add x16, x16, x9, lsl #3
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, argi
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, argi
    str x12, [x16]
    ret
.Lnext_none:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Input: x0, x1 are valid strings. Output: w9=1 if equal, otherwise zero.
 * Scratch: x9, x3. Stack: none. Does not modify either input. */
streq:
    eor w3, w3, w3
    tst w3, w3
.Leq_loop:
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
    b.ne .Leq_no
    ARM_IMM x11, 1
    adds x3, x3, x11
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.ne .Leq_loop
    ARM_IMM w10, 1
    mov w9, w10
    ret
.Leq_no:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Input: x0 is a valid string. Output: x9 excludes its NUL terminator.
 * Scratch: x9. Stack: none. Callers must establish accessible termination. */
strlen:
    eor w9, w9, w9
    tst w9, w9
.Llen_loop:
    mov x16, x0
    add x16, x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llen_done
    ARM_IMM x11, 1
    adds x9, x9, x11
    b .Llen_loop
.Llen_done:
    ret

/* Input: x0=destination, x1=source. Caller owns both buffers and proves
 * destination capacity >= strlen(source)+1; overlapping buffers are unsupported.
 * Output: x9 points to the copied NUL. Scratch: x9, x3, x1. Stack: none. */
copy_string:
    mov x9, x0
.Lcopy_loop:
    mov x16, x1
    ldrb w10, [x16]
    bfi x3, x10, #0, #8
    and w10, w3, #255
    mov x16, x9
    strb w10, [x16]
    and w10, w3, #255
    and w11, w3, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lcopy_done
    ARM_IMM x11, 1
    adds x1, x1, x11
    ARM_IMM x11, 1
    adds x9, x9, x11
    b .Lcopy_loop
.Lcopy_done:
    ret

/* Input: x0=file descriptor; x1=valid string. Output: zero or negative errno.
 * write_all instead takes an explicit byte count in x2. Both retry EINTR and
 * short writes. Scratch: syscall registers and x1/x2. Stack: none. */
write_cstr:
    eor w2, w2, w2
    tst w2, w2
.Lwrite_len:
    mov x16, x1
    add x16, x16, x2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq write_all
    ARM_IMM x11, 1
    adds x2, x2, x11
    b .Lwrite_len
write_all:
    tst x2, x2
    b.eq .Lwrite_ok
    ARM_CALL arm_write
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq write_all
    tst x9, x9
    b.mi .Lwrite_done
    b.eq .Lwrite_zero
    adds x1, x1, x9
    subs x2, x2, x9
    b write_all
.Lwrite_ok:
    eor w9, w9, w9
    tst w9, w9
.Lwrite_done:
    ret
.Lwrite_zero:
    ARM_IMM x10, -5
    mov x9, x10
    ret
/* Input: x0=valid output string. Output: x9=0 after the complete stdout write;
 * returned write failures report a static stderr error and exit 1. Uses standard
 * caller scratch, preserves callee-saved registers, and uses a 16-byte ARM_CALL
 * frame. File and stderr writers keep their returned-error contract. */
out:
    mov x1, x0
    ARM_IMM w10, 1
    mov w0, w10
    ARM_CALL write_cstr
    tst x9, x9
    b.mi .Lout_error
    ret
.Lout_error:
    ARM_ADDR x0, err_output
    mov w1, #1
    b die

/* Input: x0=text, x1=JSON, both static strings with a trailing LF. Selects the
 * global output mode and uses out's complete-write or fatal-error contract.
 * Stack: none beyond out's frame. */
report:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq out
    mov x0, x1
    b out

/* Input: x0=static JSON-safe error string without LF; w1=exit status 1..255.
 * Writes stderr and exits. Does not return. JSON escaping is not performed;
 * callers must not supply untrusted text, quotes, backslashes or controls. */
die:
    mov w21, w1
    mov x22, x0
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Ldie_plain
    ARM_IMM w10, 2
    mov w0, w10
    ARM_ADDR x16, error_json_prefix
    mov x1, x16
    ARM_CALL write_cstr
    ARM_IMM w10, 2
    mov w0, w10
    mov x1, x22
    ARM_CALL write_cstr
    ARM_IMM w10, 2
    mov w0, w10
    ARM_ADDR x16, error_json_suffix
    mov x1, x16
    ARM_CALL write_cstr
    b .Ldie_exit
.Ldie_plain:
    ARM_IMM w10, 2
    mov w0, w10
    ARM_ADDR x16, error_prefix
    mov x1, x16
    ARM_CALL write_cstr
    ARM_IMM w10, 2
    mov w0, w10
    mov x1, x22
    ARM_CALL write_cstr
    ARM_IMM w10, 2
    mov w0, w10
    ARM_ADDR x16, newline
    mov x1, x16
    ARM_CALL write_cstr
.Ldie_exit:
    mov w0, w21
    b exit_code
exit_ok:
    eor w0, w0, w0
    tst w0, w0
exit_code:
    ARM_CALL arm_exit

unknown_command:
    ARM_ADDR x16, err_unknown_command
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b die
bad_args:
    ARM_ADDR x16, err_arguments
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b die
unsupported_target:
    ARM_ADDR x16, err_target
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b die

/* Input: x9=current argv string. Output: w9=1 if consumed, otherwise zero.
 * --target consumes one more argument and accepts the host or its alias.
 * Malformed options exit. Stack: 16 saved bytes plus nested calls. */
common_option:
    ARM_SAVE x19
    mov x19, x9
    mov x0, x19
    ARM_ADDR x16, opt_json
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lopt_json
    mov x0, x19
    ARM_ADDR x16, opt_no_color
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lopt_yes
    mov x0, x19
    ARM_ADDR x16, opt_target
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lopt_target
    mov x0, x19
    ARM_ADDR x16, opt_locked
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lopt_locked
    mov x9, x19
    ARM_CALL native_link_option
    cbnz w9, .Lopt_yes
    mov x0, x19
    ARM_ADDR x16, opt_help
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_help
    mov x0, x19
    ARM_ADDR x16, opt_h
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne cmd_help
    eor w9, w9, w9
    tst w9, w9
    ARM_RESTORE x19
    ret
.Lopt_json:
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
.Lopt_yes:
    ARM_IMM w10, 1
    mov w9, w10
    ARM_RESTORE x19
    ret
.Lopt_target:
    ARM_CALL next_arg
    tst x9, x9
    b.eq bad_args
    mov x0, x9
    ARM_CALL validate_target
    tst w9, w9
    b.eq unsupported_target
    b .Lopt_yes
.Lopt_locked:
    ARM_ADDR x16, allow_locked
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq bad_args
    ARM_IMM w10, 1
    ARM_ADDR x16, require_lock
    strb w10, [x16]
    b .Lopt_yes

/* Input: x0=target string. Output: w9=1 for the host or alias, else zero.
 * Stack: 16 saved bytes. Strings are borrowed; no memory is changed. */
validate_target:
    ARM_SAVE x0
    ARM_ADDR x16, host_target
    mov x1, x16
    ARM_CALL streq
    ARM_RESTORE x0
    tst w9, w9
    b.ne .Ltarget_done
    ARM_ADDR x16, host_target_alias
    mov x1, x16
    ARM_CALL streq
.Ltarget_done:
    ret

/* Input: global argv cursor. Accepts common options until EOF. Returns with the
 * cursor at argc; any operand or unknown option exits with status 2. */
parse_options_only:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lopts_done
    ARM_CALL common_option
    tst w9, w9
    b.eq bad_args
    b parse_options_only
.Lopts_done:
    ret

cmd_help:
    ARM_CALL parse_options_only
    ARM_ADDR x16, help_text
    mov x0, x16
    ARM_ADDR x16, help_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
cmd_version:
    ARM_CALL parse_options_only
    ARM_ADDR x16, version_text
    mov x0, x16
    ARM_ADDR x16, version_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
cmd_license:
    ARM_CALL parse_options_only
    ARM_ADDR x16, license_text
    mov x0, x16
    ARM_ADDR x16, license_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
cmd_targets:
    ARM_CALL parse_options_only
    ARM_ADDR x16, targets_text
    mov x0, x16
    ARM_ADDR x16, targets_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
cmd_status:
    ARM_CALL parse_options_only
    ARM_ADDR x16, status_json
    mov x0, x16
    ARM_CALL out
    b exit_ok
cmd_doctor:
    ARM_CALL parse_options_only
    ARM_CALL check_tools
    ARM_ADDR x16, registry_curl
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Ldoctor_registry_missing
    ARM_ADDR x16, registry_sha256sum
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Ldoctor_registry_missing
    ARM_ADDR x16, doctor_gzip_path
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Ldoctor_registry_missing
    ARM_ADDR x16, doctor_text
    mov x0, x16
    ARM_ADDR x16, doctor_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
.Ldoctor_registry_missing:
    ARM_ADDR x16, err_registry_tools
    mov x0, x16
    ARM_IMM w10, 127
    mov w1, w10
    b die

/* Check execute access to fixed GNU tool paths. No files are changed. Returns
 * on success; exits 127 with a recovery message if a tool is unavailable. */
check_tools:
    ARM_ADDR x16, as_path
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.ne .Ltools_missing
    ARM_ADDR x16, ld_path
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.ne .Ltools_missing
    ret
.Ltools_missing:
    ARM_ADDR x16, err_tools
    mov x0, x16
    ARM_IMM w10, 127
    mov w1, w10
    b die

cmd_unimplemented:
    ARM_CALL parse_unimplemented_options
    ARM_ADDR x16, err_unimplemented
    mov x0, x16
    ARM_IMM w10, 69
    mov w1, w10
    b die
parse_unimplemented_options:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lunimplemented_done
    mov x0, x9
    ARM_ADDR x16, opt_json
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq parse_unimplemented_options
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b parse_unimplemented_options
.Lunimplemented_done:
    ret

/* Project creation: preflight all files, use O_EXCL|O_NOFOLLOW, roll back only
 * files/directories created by this invocation if any operation fails. */
cmd_new:
    ARM_IMM w10, 1
    ARM_ADDR x16, new_mode
    strb w10, [x16]
cmd_init:
    ARM_ADDR x16, dot
    mov x9, x16
    ARM_ADDR x16, project_path
    str x9, [x16]
.Linit_parse:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Linit_parsed
    mov x21, x9
    ARM_ADDR x16, literal_path
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linit_path
    mov x0, x21
    ARM_ADDR x16, opt_separator
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq .Linit_options
    ARM_IMM w10, 1
    ARM_ADDR x16, literal_path
    strb w10, [x16]
    b .Linit_parse
.Linit_options:
    mov x9, x21
    ARM_CALL common_option
    tst w9, w9
    b.ne .Linit_parse
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq bad_args
.Linit_path:
    ARM_ADDR x16, path_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne bad_args
    mov x0, x21
    ARM_CALL strlen
    tst x9, x9
    b.eq bad_args
    ARM_IMM x11, 4095
    cmp x9, x11
    b.hi bad_args
    ARM_ADDR x16, project_path
    str x21, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, path_seen
    strb w10, [x16]
    b .Linit_parse
.Linit_parsed:
    ARM_ADDR x16, new_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linit_save_cwd
    ARM_ADDR x16, path_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq bad_args
.Linit_save_cwd:
    ARM_ADDR x16, dot
    mov x0, x16
    ARM_IMM w10, O_DIRECTORY + O_CLOEXEC
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Linit_path_error
    ARM_ADDR x16, initial_cwd_fd
    str x9, [x16]
    ARM_ADDR x16, new_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linit_chdir
    ARM_ADDR x16, project_path
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, 493
    mov w1, w10
    ARM_CALL arm_mkdir
    tst x9, x9
    b.mi .Linit_path_error
    ARM_IMM w10, 1
    ARM_ADDR x16, made_project
    strb w10, [x16]
.Linit_chdir:
    ARM_ADDR x16, project_path
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arm_chdir
    tst x9, x9
    b.mi init_rollback
    ARM_ADDR x16, manifest_path
    mov x0, x16
    ARM_CALL require_absent
    ARM_ADDR x16, source_default
    mov x0, x16
    ARM_CALL require_absent
    ARM_ADDR x16, test_source
    mov x0, x16
    ARM_CALL require_absent
    ARM_ADDR x16, src_dir
    mov x0, x16
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi init_rollback
    and w10, w9, #255
    ARM_ADDR x16, made_src
    strb w10, [x16]
    ARM_ADDR x16, tests_dir
    mov x0, x16
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi init_rollback
    and w10, w9, #255
    ARM_ADDR x16, made_tests
    strb w10, [x16]
    /* A name derived from the last path component, if valid; otherwise app. */
    ARM_ADDR x16, package_name
    mov x0, x16
    ARM_ADDR x16, default_name
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, project_path
    ldr x10, [x16]
    mov x1, x10
    mov x21, x1
.Lbasename_scan:
    mov x16, x1
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lbasename_ready
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lbasename_next
    mov x16, x1
    add x16, x16, #1
    mov x21, x16
.Lbasename_next:
    ARM_IMM x11, 1
    adds x1, x1, x11
    b .Lbasename_scan
.Lbasename_ready:
    mov x0, x21
    ARM_CALL valid_name
    tst w9, w9
    b.eq .Linit_manifest
    ARM_ADDR x16, package_name
    mov x0, x16
    mov x1, x21
    ARM_CALL copy_string
.Linit_manifest:
    ARM_ADDR x16, manifest_buffer
    mov x0, x16
    ARM_ADDR x16, manifest_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, package_name
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, manifest_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, manifest_path
    mov x0, x16
    ARM_ADDR x16, manifest_buffer
    mov x1, x16
    ARM_ADDR x16, made_manifest
    mov x2, x16
    ARM_CALL create_exclusive_file
    tst x9, x9
    b.mi init_rollback
    ARM_ADDR x16, source_default
    mov x0, x16
    ARM_ADDR x16, main_template
    mov x1, x16
    ARM_ADDR x16, made_main
    mov x2, x16
    ARM_CALL create_exclusive_file
    tst x9, x9
    b.mi init_rollback
    ARM_ADDR x16, test_source
    mov x0, x16
    ARM_ADDR x16, test_template
    mov x1, x16
    ARM_ADDR x16, made_test
    mov x2, x16
    ARM_CALL create_exclusive_file
    tst x9, x9
    b.mi init_rollback
    ARM_ADDR x16, init_text
    mov x0, x16
    ARM_ADDR x16, init_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
.Linit_path_error:
    ARM_ADDR x16, err_init_path
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b die

/* Input: x0=initialization output path. Returns only for ENOENT from lstat.
 * Every other result triggers initialization rollback. Scratch: stat_buffer
 * (128 bytes), syscall registers. No symlink is followed for the final path. */
require_absent:
    ARM_ADDR x16, stat_buffer
    mov x1, x16
    ARM_CALL arm_lstat
    ARM_IMM x11, -2
    cmp x9, x11
    b.ne init_rollback
    ret

/* Input: x0=directory path. Output: x9=1 created, 0 existing real directory,
 * or -1 on failure. Uses lstat after EEXIST; this is not a race-free sandbox.
 * Scratch: stat_buffer (128 bytes), caller-saved registers. Stack: 16 bytes. */
make_safe_dir:
    ARM_SAVE x19
    mov x19, x0
    ARM_IMM w10, 493
    mov w1, w10
    ARM_CALL arm_mkdir
    tst x9, x9
    b.eq .Ldir_created
    ARM_IMM x11, -17
    cmp x9, x11
    b.ne .Ldir_fail
    mov x0, x19
    ARM_ADDR x16, stat_buffer
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi .Ldir_fail
    ARM_ADDR x16, stat_buffer + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne .Ldir_fail
    eor w9, w9, w9
    tst w9, w9
    ARM_RESTORE x19
    ret
.Ldir_created:
    ARM_IMM w10, 1
    mov w9, w10
    ARM_RESTORE x19
    ret
.Ldir_fail:
    ARM_IMM x10, -1
    mov x9, x10
    ARM_RESTORE x19
    ret

/* Input: x0=path, x1=content string, x2=owned one-byte creation flag.
 * Creates mode 0644 with O_EXCL|O_NOFOLLOW and sets the flag only after open.
 * Output: zero or negative errno from open/write/close. Caller rolls back a
 * partially written file. Stack: 48 saved bytes plus nested calls. */
create_exclusive_file:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x1
    mov x22, x2
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + 193
    mov w1, w10
    ARM_IMM w10, 420
    mov w2, w10
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lcreate_end
    ARM_IMM w10, 1
    mov x16, x22
    strb w10, [x16]
    mov x19, x9
    mov x0, x19
    mov x1, x21
    ARM_CALL write_cstr
    mov x21, x9
    mov x0, x19
    ARM_CALL arm_close
    tst x21, x21
    b.mi .Lcreate_write_error
    b .Lcreate_end
.Lcreate_write_error:
    mov x9, x21
.Lcreate_end:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* No return. Uses creation flags to remove only this invocation's outputs.
 * A new project directory is removed only after restoring the original cwd.
 * Existing files and directories have zero creation flags and are retained. */
init_rollback:
    ARM_ADDR x16, made_test
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrollback_main
    ARM_ADDR x16, test_source
    mov x0, x16
    ARM_CALL arm_unlink
.Lrollback_main:
    ARM_ADDR x16, made_main
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrollback_manifest
    ARM_ADDR x16, source_default
    mov x0, x16
    ARM_CALL arm_unlink
.Lrollback_manifest:
    ARM_ADDR x16, made_manifest
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrollback_tests
    ARM_ADDR x16, manifest_path
    mov x0, x16
    ARM_CALL arm_unlink
.Lrollback_tests:
    ARM_ADDR x16, made_tests
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrollback_src
    ARM_ADDR x16, tests_dir
    mov x0, x16
    ARM_CALL arm_rmdir
.Lrollback_src:
    ARM_ADDR x16, made_src
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrollback_project
    ARM_ADDR x16, src_dir
    mov x0, x16
    ARM_CALL arm_rmdir
.Lrollback_project:
    ARM_ADDR x16, made_project
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrollback_error
    ARM_ADDR x16, initial_cwd_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arm_fchdir
    tst x9, x9
    b.mi .Lrollback_error
    ARM_ADDR x16, project_path
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arm_rmdir
.Lrollback_error:
    ARM_ADDR x16, err_init_conflict
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b die

/* Strict, documented TOML subset. Sections and string fields are parsed, not
 * ignored. Unknown keys, duplicate fields, escapes and unsupported targets fail. */
/* Input: cwd is the project. Output: package_* buffers contain validated fields.
 * Reads a regular, non-symlink asm.toml with at most 8190 bytes. Field capacities
 * include NUL: name=65, version/target=64, source/native fields=256. Failure exits without build
 * changes. Stack: 64 saved bytes plus nested calls; all callee-saved restored. */
read_manifest:
    ARM_ADDR x16, package_link
    strb wzr, [x16]
    ARM_ADDR x16, package_libraries
    strb wzr, [x16]
    ARM_ADDR x16, package_check
    strb wzr, [x16]
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, manifest_path
    mov x0, x16
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi manifest_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, stat_buffer
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lmanifest_close_error
    ARM_ADDR x16, stat_buffer + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Lmanifest_close_error
    ARM_ADDR x16, stat_buffer + 48
    ldr x10, [x16]
    mov x9, x10
    tst x9, x9
    b.eq .Lmanifest_close_error
    ARM_IMM x11, 8191
    cmp x9, x11
    b.hi .Lmanifest_close_error
    eor w22, w22, w22
    tst w22, w22
.Lmanifest_read:
    mov x0, x21
    ARM_ADDR x16, manifest_buffer
    mov x1, x16
    adds x1, x1, x22
    ARM_IMM w10, 8191
    mov w2, w10
    subs x2, x2, x22
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lmanifest_read
    tst x9, x9
    b.mi .Lmanifest_close_error
    b.eq .Lmanifest_read_done
    adds x22, x22, x9
    ARM_IMM x11, 8191
    cmp x22, x11
    b.hs .Lmanifest_close_error
    b .Lmanifest_read
.Lmanifest_read_done:
    ARM_ADDR x16, manifest_buffer
    mov x9, x16
    eor w3, w3, w3
    tst w3, w3
.Lmanifest_no_nul:
    cmp x3, x22
    b.hs .Lmanifest_terminate
    mov x16, x9
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_close_error
    ARM_IMM x11, 1
    adds x3, x3, x11
    b .Lmanifest_no_nul
.Lmanifest_terminate:
    ARM_IMM w10, 0
    mov x16, x9
    add x16, x16, x22
    strb w10, [x16]
    mov x0, x21
    ARM_CALL arm_close
    ARM_ADDR x16, manifest_buffer
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
    eor w23, w23, w23
    tst w23, w23
    eor w24, w24, w24
    tst w24, w24
.Lmanifest_line:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lmanifest_finish
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_skip
    and w10, w9, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_skip
    and w10, w9, #255
    ARM_IMM w11, 13
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_skip
    and w10, w9, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_skip
    and w10, w9, #255
    ARM_IMM w11, 35
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_comment
    and w10, w9, #255
    ARM_IMM w11, 91
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_section
    mov x0, x21
    eor w3, w3, w3
    tst w3, w3
.Lmanifest_key:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lmanifest_key_end
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lmanifest_key_end
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM w11, 32
    cmp w3, w11
    b.hi manifest_error
    b .Lmanifest_key
.Lmanifest_key_end:
    tst w3, w3
    b.eq manifest_error
    ARM_ADDR x16, key_buffer
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
.Lmanifest_key_copy:
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x1
    add x16, x16, x2
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w2, w2, w11
    cmp w2, w3
    b.lo .Lmanifest_key_copy
    ARM_IMM w10, 0
    mov x16, x1
    add x16, x16, x2
    strb w10, [x16]
    ARM_CALL skip_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne manifest_error
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_CALL skip_horizontal
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne manifest_error
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, key_buffer
    mov x0, x16
    ARM_ADDR x16, key_name
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lfield_name
    ARM_ADDR x16, key_buffer
    mov x0, x16
    ARM_ADDR x16, key_version
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lfield_version
    ARM_ADDR x16, key_buffer
    mov x0, x16
    ARM_ADDR x16, key_source
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lfield_source
    ARM_ADDR x16, key_buffer
    mov x0, x16
    ARM_ADDR x16, key_target
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lfield_target
    ARM_ADDR x0, key_buffer
    ARM_ADDR x1, key_link
    ARM_CALL streq
    cbnz w9, .Lfield_link
    ARM_ADDR x0, key_buffer
    ARM_ADDR x1, key_libraries
    ARM_CALL streq
    cbnz w9, .Lfield_libraries
    ARM_ADDR x0, key_buffer
    ARM_ADDR x1, key_check
    ARM_CALL streq
    cbnz w9, .Lfield_check
    b manifest_error
.Lfield_name:
    ARM_IMM w11, 1
    cmp w22, w11
    b.ne manifest_error
    ARM_ADDR x16, package_name
    mov x0, x16
    ARM_IMM w10, 64
    mov w1, w10
    ARM_IMM w10, 1
    mov w2, w10
    b .Lfield_read
.Lfield_version:
    ARM_IMM w11, 1
    cmp w22, w11
    b.ne manifest_error
    ARM_ADDR x16, package_version
    mov x0, x16
    ARM_IMM w10, 63
    mov w1, w10
    ARM_IMM w10, 2
    mov w2, w10
    b .Lfield_read
.Lfield_source:
    ARM_IMM w11, 2
    cmp w22, w11
    b.ne manifest_error
    ARM_ADDR x16, package_source
    mov x0, x16
    ARM_IMM w10, 255
    mov w1, w10
    ARM_IMM w10, 4
    mov w2, w10
    b .Lfield_read
.Lfield_target:
    ARM_IMM w11, 2
    cmp w22, w11
    b.ne manifest_error
    ARM_ADDR x16, package_target
    mov x0, x16
    ARM_IMM w10, 63
    mov w1, w10
    ARM_IMM w10, 8
    mov w2, w10
    b .Lfield_read
.Lfield_link:
    cmp w22, #2
    b.ne manifest_error
    ARM_ADDR x0, package_link
    mov w1, #255
    mov w2, #16
    b .Lfield_read
.Lfield_libraries:
    cmp w22, #2
    b.ne manifest_error
    ARM_ADDR x0, package_libraries
    mov w1, #255
    mov w2, #32
    b .Lfield_read
.Lfield_check:
    cmp w22, #2
    b.ne manifest_error
    ARM_ADDR x0, package_check
    mov w1, #255
    mov w2, #64
.Lfield_read:
    tst w23, w2
    b.ne manifest_error
    orr w23, w23, w2
    tst w23, w23
    eor w3, w3, w3
    tst w3, w3
.Lfield_chars:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lfield_end
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo manifest_error
    and w10, w9, #255
    ARM_IMM w11, 127
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq manifest_error
    and w10, w9, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq manifest_error
    cmp w3, w1
    b.hs manifest_error
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lfield_chars
.Lfield_end:
    tst w3, w3
    b.eq manifest_error
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lline_end
.Lmanifest_section:
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, key_buffer
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
.Lsection_chars:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 93
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsection_end
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo manifest_error
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi manifest_error
    ARM_IMM w11, 31
    cmp w3, w11
    b.hs manifest_error
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lsection_chars
.Lsection_end:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_ADDR x16, section_package
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lsection_package
    ARM_ADDR x16, key_buffer
    mov x0, x16
    ARM_ADDR x16, section_build
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq manifest_error
    ARM_IMM w11, 2
    tst w24, w11
    b.ne manifest_error
    ARM_IMM w11, 2
    orr w24, w24, w11
    tst w24, w24
    ARM_IMM w10, 2
    mov w22, w10
    b .Lline_end
.Lsection_package:
    ARM_IMM w11, 1
    tst w24, w11
    b.ne manifest_error
    ARM_IMM w11, 1
    orr w24, w24, w11
    tst w24, w24
    ARM_IMM w10, 1
    mov w22, w10
.Lline_end:
    ARM_CALL skip_horizontal
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 35
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_comment
    and w10, w9, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lmanifest_skip
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lmanifest_finish
    b manifest_error
.Lmanifest_skip:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lmanifest_line
.Lmanifest_comment:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lmanifest_finish
    ARM_IMM x11, 1
    adds x21, x21, x11
    and w10, w9, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lmanifest_comment
    b .Lmanifest_line
.Lmanifest_finish:
    and w10, w23, #15
    ARM_IMM w11, 15
    cmp w10, w11
    b.ne manifest_error
    ARM_ADDR x16, package_name
    mov x0, x16
    ARM_CALL valid_name
    tst w9, w9
    b.eq manifest_error
    ARM_ADDR x16, package_version
    mov x0, x16
    ARM_CALL valid_version
    tst w9, w9
    b.eq manifest_error
    ARM_ADDR x16, package_source
    mov x0, x16
    ARM_CALL valid_source
    tst w9, w9
    b.eq manifest_error
    ARM_ADDR x16, package_target
    mov x0, x16
    ARM_CALL validate_target
    tst w9, w9
    b.eq unsupported_target
    ARM_ADDR x0, package_link
    ARM_ADDR x1, package_libraries
    ARM_ADDR x2, package_check
    ARM_CALL native_link_validate
    cbz w9, manifest_error
    ARM_CALL native_link_check_options
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret
.Lmanifest_close_error:
    mov x0, x21
    ARM_CALL arm_close
manifest_error:
    ARM_ADDR x16, err_manifest
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b die

/* Input/output: x21 is the bounded manifest parser cursor. Advances over SP,
 * TAB and CR. Scratch: x9. This parser helper intentionally updates x21. */
skip_horizontal:
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lhorizontal_next
    and w10, w9, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lhorizontal_next
    and w10, w9, #255
    ARM_IMM w11, 13
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lhorizontal_end
.Lhorizontal_next:
    ARM_IMM x11, 1
    adds x21, x21, x11
    b skip_horizontal
.Lhorizontal_end:
    ret

/* Input: x0=project name. Output: w9=1 for [a-z][a-z0-9-]{0,63}, else zero.
 * Scratch: x9/x3. Registry namespace validation is a separate stricter rule. */
valid_name:
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Linvalid
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Linvalid
    ARM_IMM w10, 1
    mov w3, w10
.Lname_loop:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lvalid
    ARM_IMM w11, 64
    cmp w3, w11
    b.hs .Linvalid
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lname_next
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Linvalid
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lname_next
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Linvalid
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Linvalid
.Lname_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lname_loop
/* Input: x0=bounded manifest version (at most 63 chars). Output: w9=1 for
 * numeric major.minor.patch without leading zeroes, else zero. No integer
 * conversion occurs here. Registry versions impose a separate numeric limit. */
valid_version:
    eor w3, w3, w3
    tst w3, w3
    eor w2, w2, w2
    tst w2, w2
.Lversion_component:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Linvalid
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Linvalid
    and w10, w9, #255
    bfi x4, x10, #0, #8
    ARM_IMM w11, 1
    adds w3, w3, w11
    and w10, w4, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lversion_sep
.Lversion_digits:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lversion_sep
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lversion_sep
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 63
    cmp w3, w11
    b.hs .Linvalid
    b .Lversion_digits
.Lversion_sep:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lversion_final
    and w10, w9, #255
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linvalid
    ARM_IMM w11, 1
    adds w2, w2, w11
    ARM_IMM w11, 2
    cmp w2, w11
    b.hi .Linvalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lversion_component
.Lversion_final:
    ARM_IMM w11, 2
    cmp w2, w11
    b.eq .Lvalid
    b .Linvalid

/* Input: x0=source path already bounded to 255 chars. Output: w9=1 for a
 * relative path with no empty/. /.. or option-like segments, else zero. This
 * validates syntax; assembly and included files remain trusted local input. */
valid_source:
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linvalid
    eor w3, w3, w3
    tst w3, w3
    eor w2, w2, w2
    tst w2, w2
.Lsource_segment:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linvalid
    mov w2, w3
.Lsource_loop:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lsource_end_segment
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lsource_end_segment
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Linvalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lsource_loop
.Lsource_end_segment:
    mov w4, w3
    subs w4, w4, w2
    b.eq .Linvalid
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lsource_continue
    ARM_IMM w11, 1
    cmp w4, w11
    b.eq .Linvalid
    ARM_IMM w11, 2
    cmp w4, w11
    b.ne .Lsource_continue
    mov x16, x0
    add x16, x16, x2
    add x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linvalid
.Lsource_continue:
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lvalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lsource_segment
.Lvalid:
    ARM_IMM w10, 1
    mov w9, w10
    ret
.Linvalid:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Build outputs in a fresh process-specific staging directory, then rename
 * completed artifacts into place. Never pass project paths through a shell. */
cmd_build:
    ARM_ADDR x16, native_allow
    mov w10, #1
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, allow_locked
    strb w10, [x16]
    ARM_CALL parse_options_only
    ARM_CALL read_manifest
    ARM_CALL build_project
    ARM_ADDR x16, build_text
    mov x0, x16
    ARM_ADDR x16, build_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
cmd_run:
    ARM_ADDR x16, native_allow
    mov w10, #1
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, allow_locked
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, run_mode
    strb w10, [x16]
.Lrun_options:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lrun_args_done
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, opt_separator
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lrun_args_done
    mov x9, x21
    ARM_CALL common_option
    tst w9, w9
    b.eq bad_args
    b .Lrun_options
.Lrun_args_done:
    ARM_ADDR x16, argi
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, run_argi
    str x9, [x16]
    ARM_CALL read_manifest
    ARM_CALL build_project
    /* Reuse argv's contiguous tail, replacing the preceding slot with argv0. */
    ARM_ADDR x16, run_argi
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, 1
    subs x9, x9, x11
    ARM_ADDR x16, argv
    ldr x10, [x16]
    mov x1, x10
    mov x16, x1
    add x16, x16, x9, lsl #3
    mov x1, x16
    ARM_ADDR x16, app_output
    mov x0, x16
    mov x16, x1
    str x0, [x16]
    ARM_CALL spawn_wait
    mov w0, w9
    b exit_code
cmd_test:
    ARM_ADDR x16, native_allow
    mov w10, #1
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, allow_locked
    strb w10, [x16]
    ARM_CALL parse_options_only
    ARM_CALL read_manifest
    ARM_IMM w10, 1
    ARM_ADDR x16, test_mode
    strb w10, [x16]
    ARM_CALL build_project
    ARM_ADDR x16, test_output
    mov x0, x16
    ARM_ADDR x16, child_argv
    str x0, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, child_argv + 8
    str x10, [x16]
    ARM_ADDR x16, child_argv
    mov x1, x16
    ARM_CALL spawn_wait
    tst w9, w9
    b.ne .Ltest_failed
    ARM_ADDR x16, test_text
    mov x0, x16
    ARM_ADDR x16, test_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
.Ltest_failed:
    mov w1, w9
    ARM_ADDR x16, err_test
    mov x0, x16
    b die

/* Input: cwd is a trusted local project; package_source was parsed and bounded.
 * test_mode selects tests/main.s. Output: build/app or build/test, plus object.
 * Object rename occurs first; binary rename is the final publication step.
 * Returns on success. On failure, removes this process's stage and exits with
 * the child status or 1. Stage paths have capacities 64/96/96. Stack: 16 bytes. */
build_project:
    ARM_SAVE x21
    ARM_CALL check_tools
    ARM_CALL verify_project_dependencies
    ARM_ADDR x16, build_dir
    mov x0, x16
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi build_directory_error
    ARM_ADDR x16, stage_dir
    mov x0, x16
    ARM_ADDR x16, stage_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x21, x9
    ARM_CALL arm_getpid
    mov x0, x9
    ARM_ADDR x16, number_buffer + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x0, x21
    mov x1, x9
    ARM_CALL copy_string
    ARM_ADDR x16, stage_dir
    mov x0, x16
    ARM_IMM w10, 448
    mov w1, w10
    ARM_CALL arm_mkdir
    tst x9, x9
    b.mi build_directory_error
    ARM_ADDR x16, stage_object
    mov x0, x16
    ARM_ADDR x16, stage_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, object_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, stage_binary
    mov x0, x16
    ARM_ADDR x16, stage_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, binary_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_CALL native_link_compile_check
    cbnz w9, build_child_error
    ARM_ADDR x16, as_path
    mov x9, x16
    ARM_ADDR x16, child_argv
    str x9, [x16]
    ARM_ADDR x16, as_arch
    mov x9, x16
    ARM_ADDR x16, child_argv + 8
    str x9, [x16]
    ARM_ADDR x16, arg_I
    mov x9, x16
    ARM_ADDR x16, child_argv + 16
    str x9, [x16]
    ARM_ADDR x16, dependency_packages_root
    mov x9, x16
    ARM_ADDR x16, child_argv + 24
    str x9, [x16]
    ARM_ADDR x16, arg_o
    mov x9, x16
    ARM_ADDR x16, child_argv + 32
    str x9, [x16]
    ARM_ADDR x16, stage_object
    mov x9, x16
    ARM_ADDR x16, child_argv + 40
    str x9, [x16]
    ARM_ADDR x16, package_source
    mov x9, x16
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lbuild_source_set
    ARM_ADDR x16, test_source
    mov x9, x16
.Lbuild_source_set:
    ARM_ADDR x16, child_argv + 48
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, child_argv + 56
    str x10, [x16]
    ARM_ADDR x16, as_path
    mov x0, x16
    ARM_ADDR x16, child_argv
    mov x1, x16
    ARM_CALL spawn_wait
    tst w9, w9
    b.ne build_child_error
    ARM_ADDR x16, package_link
    ldrb w10, [x16]
    cbz w10, .Lbuild_standalone_link
    ARM_CALL native_link_build
    cbnz w9, build_child_error
    b .Lbuild_linked
.Lbuild_standalone_link:
    ARM_ADDR x16, ld_path
    mov x9, x16
    ARM_ADDR x16, child_argv
    str x9, [x16]
    ARM_ADDR x16, arg_z
    mov x9, x16
    ARM_ADDR x16, child_argv + 8
    str x9, [x16]
    ARM_ADDR x16, noexecstack
    mov x9, x16
    ARM_ADDR x16, child_argv + 16
    str x9, [x16]
    ARM_ADDR x16, arg_o
    mov x9, x16
    ARM_ADDR x16, child_argv + 24
    str x9, [x16]
    ARM_ADDR x16, stage_binary
    mov x9, x16
    ARM_ADDR x16, child_argv + 32
    str x9, [x16]
    ARM_ADDR x16, stage_object
    mov x9, x16
    ARM_ADDR x16, child_argv + 40
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, child_argv + 48
    str x10, [x16]
    ARM_ADDR x16, ld_path
    mov x0, x16
    ARM_ADDR x16, child_argv
    mov x1, x16
    ARM_CALL spawn_wait
    tst w9, w9
    b.ne build_child_error
.Lbuild_linked:
    ARM_ADDR x16, stage_object
    mov x0, x16
    ARM_ADDR x16, object_output
    mov x1, x16
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrename_object
    ARM_ADDR x16, test_object_output
    mov x1, x16
.Lrename_object:
    ARM_CALL arm_rename
    tst x9, x9
    b.mi build_io_error
    ARM_ADDR x16, stage_binary
    mov x0, x16
    ARM_ADDR x16, app_output
    mov x1, x16
    ARM_ADDR x16, test_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrename_binary
    ARM_ADDR x16, test_output
    mov x1, x16
.Lrename_binary:
    ARM_CALL arm_rename
    tst x9, x9
    b.mi build_io_error
    ARM_CALL cleanup_stage
    ARM_CALL release_dependency_lock
    ARM_RESTORE x21
    ret
build_child_error:
    mov w24, w9
    ARM_CALL cleanup_stage
    ARM_ADDR x16, err_build
    mov x0, x16
    mov w1, w24
    b die
build_io_error:
    ARM_CALL cleanup_stage
build_directory_error:
    ARM_ADDR x16, err_build_io
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b die
/* Input: stage paths refer to the directory this process created. Removes only
 * its two known files and then its empty directory. Scratch: syscall registers.
 * Cleanup errors do not replace the original failure status. Stack: none. */
cleanup_stage:
    ARM_ADDR x16, stage_object
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, stage_binary
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, stage_dir
    mov x0, x16
    ARM_CALL arm_rmdir
    ret

/* Input: x0=unsigned 64-bit value; x1=last byte of a writable >=21-byte buffer.
 * Output: x9 points to the decimal string within that buffer. Writes backward
 * from x1, including its NUL terminator. Scratch: x9/x2/x1/x4. Stack: none. */
unsigned_decimal:
    ARM_IMM w10, 0
    mov x16, x1
    strb w10, [x16]
    mov x9, x0
    ARM_IMM w10, 10
    mov w4, w10
.Ldecimal_loop:
    eor w2, w2, w2
    tst w2, w2
    // Caller establishes x2 = 0 and a nonzero divisor.
    mov x10, x9
    udiv x9, x10, x4
    msub x2, x9, x4, x10
    and w10, w2, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    adds w12, w10, w11
    lsr w12, w12, #24
    bfi x2, x12, #0, #8
    ARM_IMM x11, 1
    subs x1, x1, x11
    and w10, w2, #255
    mov x16, x1
    strb w10, [x16]
    tst x9, x9
    b.ne .Ldecimal_loop
    mov x9, x1
    ret

/* Spawn a fixed executable with explicit argv and inherited file streams.
 * Compiler drivers use a fixed environment; application children inherit env.
 * Return child's exit code, or 128+signal; never turn a failed exec into success. */
/* Input: x0=executable path, x1=NUL-terminated argv pointer array. All pointers
 * remain owned by the parent. Output: w9=0..255; fork/wait/exec failure is 127.
 * Retries interrupted waits. Stack: 48 saved bytes. No shell is involved. */
spawn_wait:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov x22, x1
    ARM_CALL arm_fork
    tst x9, x9
    b.mi .Lspawn_failed
    b.eq .Lspawn_child
    mov x19, x9
.Lwait_again:
    mov x0, x19
    ARM_ADDR x16, child_status
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lwait_again
    tst x9, x9
    b.mi .Lspawn_failed
    ARM_ADDR x16, child_status
    ldr w10, [x16]
    mov w9, w10
    mov w2, w9
    ARM_IMM w11, 127
    and w2, w2, w11
    tst w2, w2
    b.ne .Lspawn_signal
    lsr w9, w9, #8
    tst w9, w9
    ARM_IMM w11, 255
    and w9, w9, w11
    tst w9, w9
    b .Lspawn_return
.Lspawn_signal:
    mov x16, x2
    add x16, x16, #128
    mov w9, w16
    b .Lspawn_return
.Lspawn_child:
    mov x0, x21
    ARM_CALL native_link_child_environment
    mov x2, x9
    mov x0, x21
    mov x1, x22
    ARM_CALL arm_execve
    ARM_IMM w10, 127
    mov w0, w10
    b exit_code
.Lspawn_failed:
    ARM_IMM w10, 127
    mov w9, w10
.Lspawn_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

cmd_clean:
    ARM_CALL parse_options_only
    ARM_CALL read_manifest
    ARM_ADDR x16, build_dir
    mov x0, x16
    ARM_ADDR x16, stat_buffer
    mov x1, x16
    ARM_CALL arm_lstat
    ARM_IMM x11, -2
    cmp x9, x11
    b.eq .Lclean_done
    tst x9, x9
    b.mi .Lclean_error
    ARM_ADDR x16, stat_buffer + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 16384
    cmp w9, w11
    b.ne .Lclean_error
    ARM_ADDR x16, app_output
    mov x0, x16
    ARM_CALL clean_file
    ARM_ADDR x16, object_output
    mov x0, x16
    ARM_CALL clean_file
    ARM_ADDR x16, test_output
    mov x0, x16
    ARM_CALL clean_file
    ARM_ADDR x16, test_object_output
    mov x0, x16
    ARM_CALL clean_file
    ARM_ADDR x16, build_dir
    mov x0, x16
    ARM_CALL arm_rmdir
    tst x9, x9
    b.eq .Lclean_done
    ARM_IMM x11, -39
    cmp x9, x11
    b.eq .Lclean_done
    ARM_IMM x11, -2
    cmp x9, x11
    b.ne .Lclean_error
.Lclean_done:
    ARM_ADDR x16, clean_text
    mov x0, x16
    ARM_ADDR x16, clean_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
.Lclean_error:
    ARM_ADDR x16, err_clean
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b die
/* Input: x0=one fixed Asm artifact path. Unlinks the final entry, not its
 * symlink target. Returns for success or ENOENT; other errors exit. */
clean_file:
    ARM_CALL arm_unlink
    tst x9, x9
    b.eq .Lclean_file_done
    ARM_IMM x11, -2
    cmp x9, x11
    b.ne .Lclean_error
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
host_target: .asciz "aarch64-linux"
host_target_alias: .asciz "aarch64-unknown-linux-gnu"
as_path: .asciz "/usr/bin/as"
ld_path: .asciz "/usr/bin/ld"
as_arch: .asciz "-march=armv8-a"
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
key_name: .asciz "name"
key_version: .asciz "version"
key_source: .asciz "source"
key_target: .asciz "target"
key_link: .asciz "link"
key_libraries: .asciz "libraries"
key_check: .asciz "check"
section_package: .asciz "package"
section_build: .asciz "build"
newline: .asciz "\n"
error_prefix: .asciz "asm: "
error_json_prefix: .asciz "{\"ok\":false,\"error\":\""
error_json_suffix: .asciz "\"}\n"
err_unknown_command: .asciz "unknown command; use asm help"
err_arguments: .asciz "invalid arguments; use asm help"
err_output: .asciz "cannot write command output; check the output destination and try again"
err_target: .asciz "unsupported target; this release supports aarch64-linux only"
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

version_text: .asciz "asm 0.4.0 (aarch64-linux)\n"
version_json: .asciz "{\"name\":\"asm\",\"version\":\"0.4.0\",\"host\":\"aarch64-linux\"}\n"
license_text: .asciz "asm 0.4.0\nCopyright (c) 2026 ASM contributors\nLicense: AGPL-3.0-or-later\nYou may copy, modify, and redistribute Asm under this license.\nAsm is provided without warranty.\nTerms: https://www.gnu.org/licenses/agpl-3.0.html\nSource: https://github.com/stubbi/asm/tree/v0.4.0\nStarter code and examples: MIT. Packages retain their own licenses.\n"
license_json: .asciz "{\"license\":\"AGPL-3.0-or-later\",\"template_license\":\"MIT\",\"copyright\":\"Copyright (c) 2026 ASM contributors\",\"warranty\":false,\"terms\":\"https://www.gnu.org/licenses/agpl-3.0.html\",\"source\":\"https://github.com/stubbi/asm/tree/v0.4.0\"}\n"
targets_text: .asciz "aarch64-linux (host; GNU as + ld)\n"
targets_json: .asciz "{\"host\":\"aarch64-linux\",\"targets\":[\"aarch64-linux\"]}\n"
doctor_gzip_path: .asciz "/usr/bin/gzip"
doctor_text: .asciz "Host: aarch64-linux\nBuild: /usr/bin/as and /usr/bin/ld\nRegistry: /usr/bin/curl and /usr/bin/sha256sum\nSource archives: /usr/bin/gzip\nRequired tools are available.\n"
doctor_json: .asciz "{\"ok\":true,\"host\":\"aarch64-linux\",\"assembler\":\"/usr/bin/as\",\"linker\":\"/usr/bin/ld\",\"curl\":\"/usr/bin/curl\",\"sha256sum\":\"/usr/bin/sha256sum\",\"gzip\":\"/usr/bin/gzip\"}\n"
init_text: .asciz "Created asm.toml, src/main.s and tests/main.s.\nNext: asm run\n"
init_json: .asciz "{\"ok\":true,\"created\":[\"asm.toml\",\"src/main.s\",\"tests/main.s\"]}\n"
build_text: .asciz "Built build/app\n"
build_json: .asciz "{\"ok\":true,\"artifact\":\"build/app\"}\n"
test_text: .asciz "Passed tests/main.s\n"
test_json: .asciz "{\"ok\":true,\"test\":\"tests/main.s\"}\n"
clean_text: .asciz "Removed Asm build artifacts.\n"
clean_json: .asciz "{\"ok\":true,\"cleaned\":true}\n"
help_text:
    .ascii "asm 0.4.0 - build assembly projects\n\n"
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
    .ascii "Options: --target aarch64-linux, --json, --no-color, --help\n"
    .ascii "Build/run/test verify existing locks. --locked also requires asm.lock.\n"
    .ascii "Native builds: --include-dir PATH and --library-dir PATH (repeat up to eight).\n"
    .ascii "For a path starting with -, use: asm new -- <path>\n"
    .ascii "JSON describes Asm's own output; child output is passed through.\n"
    .ascii "For registry options, use asm search --help.\n"
    .ascii "Unimplemented commands fail with exit status 69; use asm status.\n"
    .ascii "License: AGPL-3.0-or-later. No warranty. Use asm license for terms.\n"
    .byte 0
help_json:
    .asciz "{\"name\":\"asm\",\"version\":\"0.4.0\",\"usage\":\"asm [--json] <command> [options]\",\"commands\":[\"new\",\"init\",\"build\",\"run\",\"test\",\"clean\",\"search\",\"info\",\"versions\",\"fetch\",\"install\",\"installed\",\"upgrade\",\"uninstall\",\"add\",\"update\",\"remove\",\"lock\",\"sync\",\"doctor\",\"targets\",\"status\",\"version\",\"help\",\"publish\",\"license\",\"self\"],\"license\":\"AGPL-3.0-or-later\",\"template_license\":\"MIT\"}\n"
status_json:
    .asciz "{\"version\":\"0.4.0\",\"implementation\":\"aarch64 assembly\",\"targets\":[\"aarch64-linux\"],\"implemented\":[\"help\",\"version\",\"doctor\",\"init\",\"new\",\"build\",\"run\",\"test\",\"clean\",\"targets\",\"status\",\"search\",\"info\",\"versions\",\"fetch\",\"install\",\"installed\",\"upgrade\",\"uninstall\",\"add\",\"update\",\"remove\",\"lock\",\"sync\",\"publish\",\"license\",\"self\"],\"unimplemented\":[\"login\",\"yank\"],\"license\":\"AGPL-3.0-or-later\",\"template_license\":\"MIT\"}\n"
.include "cli/aarch64/templates.s"

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
key_buffer: .skip 64
package_name: .skip 65
package_version: .skip 64
package_source: .skip 256
package_target: .skip 64
manifest_buffer: .skip 8192
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
.section .note.GNU-stack,"",%progbits

/* Keep one assembler translation unit so the CLI can build itself with the
 * standard single-source asm.toml. GNU as resolves .include from project cwd. */
.include "cli/aarch64/native_link.s"
.include "cli/aarch64/programs.s"
.include "cli/aarch64/registry.s"
.include "cli/aarch64/elf.s"
.include "cli/aarch64/archive.s"
.include "cli/aarch64/dependencies.s"
.include "cli/aarch64/publish.s"
.include "cli/aarch64/self_update.s"
.include "cli/aarch64/self_update_verify.s"
.include "cli/aarch64/self_update_metadata.s"

.include "cli/aarch64/platform.s"

.ifdef ASM_TRUSTED_DISTRIBUTION
.include "cli/aarch64/self_update_trust.s"
.endif
