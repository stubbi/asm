/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and README.md#license for the terms and scope.
 */
.global cmd_search, cmd_info, cmd_versions, cmd_fetch, cmd_install
.extern next_arg, streq, strlen, copy_string, out, write_cstr, write_all
.extern die, exit_ok, exit_code, spawn_wait, unsigned_decimal
.extern create_exclusive_file, json_mode

/* Registry v1 is a bounded TSV protocol. All parsing and decisions are native
 * assembly. curl supplies HTTPS; sha256sum supplies the digest implementation.
 * Package contents are never extracted or executed by fetch.
 * ABI: returning routines preserve x19, x20 and x21-x24. x9, x3, x2, x1,
 * x0 and x4-x7 are scratch unless a narrower set is stated. Command/error
 * labels do not return. The executable uses Linux AArch64 syscalls, not libc.
 * Each borrowed string must end in accessible NUL memory. argv comes from the
 * kernel. Index strings are bounded and terminated by registry_parse_index.
 */
.equ INDEX_LIMIT, 1048576
.equ ROW_LIMIT, 4096
.equ REGISTRY_OUTPUT_LIMIT, 65536
.equ ARTIFACT_LIMIT, 67108864
.equ AT_FDCWD, -100

/* Native AArch64 port. See platform.inc for the internal register contract.
 * Each saved register occupies 16 bytes. Each ARM_CALL adds a 16-byte link
 * frame for its duration. Numeric frame sizes exclude that caller link frame.
 * The corresponding x86-64 module retains the same behavioral contract.
 */

.section .text
cmd_search:
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command
cmd_info:
    ARM_IMM w10, 2
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command
cmd_versions:
    ARM_IMM w10, 3
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command
cmd_fetch:
    ARM_IMM w10, 4
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
    b registry_command
cmd_install:
    ARM_IMM w10, 5
    ARM_ADDR x16, registry_mode
    strb w10, [x16]
/* Command entry: global argv cursor follows the command name. Parses options
 * before filesystem/network work. Owns the global registry_* buffers for the
 * process lifetime. Commands terminate the process; no caller stack survives. */
registry_command:
    ARM_ADDR x16, registry_default_url
    mov x9, x16
    ARM_ADDR x16, registry_url
    str x9, [x16]
    ARM_ADDR x16, registry_host
    mov x9, x16
    ARM_ADDR x16, registry_target
    str x9, [x16]
    ARM_ADDR x16, registry_source_kind
    mov x9, x16
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 5
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lregistry_kind_default
    ARM_ADDR x16, registry_executable_kind
    mov x9, x16
.Lregistry_kind_default:
    ARM_ADDR x16, registry_kind
    str x9, [x16]
    ARM_ADDR x16, registry_empty
    mov x9, x16
    ARM_ADDR x16, registry_query
    str x9, [x16]
.Lregistry_args:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lregistry_args_done
    mov x21, x9
    ARM_ADDR x16, registry_literal
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lregistry_query_arg
    mov x0, x21
    ARM_ADDR x16, registry_opt_json
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_json
    mov x0, x21
    ARM_ADDR x16, registry_opt_no_color
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_args
    mov x0, x21
    ARM_ADDR x16, registry_opt_help
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne registry_help
    mov x0, x21
    ARM_ADDR x16, registry_separator
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_separator
    mov x0, x21
    ARM_ADDR x16, registry_opt_index
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_index
    mov x0, x21
    ARM_ADDR x16, registry_opt_registry
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_registry
    mov x0, x21
    ARM_ADDR x16, registry_opt_target
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_target
    mov x0, x21
    ARM_ADDR x16, registry_opt_kind
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_kind
    mov x0, x21
    ARM_ADDR x16, registry_opt_output
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_output
    mov x0, x21
    ARM_ADDR x16, registry_opt_artifact
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lregistry_arg_artifact
    mov x16, x21
    ldrb w10, [x16]
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_bad_args
.Lregistry_query_arg:
    ARM_ADDR x16, registry_has_query
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_bad_args
    mov x0, x21
    ARM_CALL strlen
    ARM_IMM x11, 168
    cmp x9, x11
    b.hi registry_bad_args
    ARM_ADDR x16, registry_query
    str x21, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_has_query
    strb w10, [x16]
    b .Lregistry_args
.Lregistry_arg_json:
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b .Lregistry_args
.Lregistry_arg_separator:
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_literal
    strb w10, [x16]
    b .Lregistry_args
.Lregistry_arg_index:
    ARM_ADDR x16, registry_origin_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_index_path
    str x9, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_local_index
    strb w10, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_origin_seen
    strb w10, [x16]
    b .Lregistry_args
.Lregistry_arg_registry:
    ARM_ADDR x16, registry_origin_seen
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_url
    str x9, [x16]
    mov x0, x9
    ARM_CALL registry_https_url
    tst w9, w9
    b.eq registry_bad_args
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_origin_seen
    strb w10, [x16]
    b .Lregistry_args
.Lregistry_arg_target:
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_target
    str x9, [x16]
    mov x0, x9
    ARM_CALL registry_valid_target
    tst w9, w9
    b.eq registry_bad_args
    b .Lregistry_args
.Lregistry_arg_kind:
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_kind
    str x9, [x16]
    mov x0, x9
    ARM_CALL registry_valid_kind
    tst w9, w9
    b.eq registry_bad_args
    b .Lregistry_args
.Lregistry_arg_output:
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_output
    str x9, [x16]
    b .Lregistry_args
.Lregistry_arg_artifact:
    ARM_ADDR x16, registry_local_artifact
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_CALL registry_arg_value
    ARM_ADDR x16, registry_local_artifact
    str x9, [x16]
    b .Lregistry_args
.Lregistry_args_done:
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 4
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hs .Lregistry_fetch_args
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_ADDR x16, registry_local_artifact
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lregistry_load
    ARM_ADDR x16, registry_query
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_package
    tst w9, w9
    b.eq registry_bad_args
    b .Lregistry_load
.Lregistry_fetch_args:
    ARM_ADDR x16, registry_selector
    mov x0, x16
    ARM_ADDR x16, registry_query
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    ARM_ADDR x16, registry_selector
    mov x0, x16
    ARM_ADDR x16, registry_query
    str x0, [x16]
    mov x1, x0
.Lselector_scan:
    mov x16, x1
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lselector_package
    and w10, w9, #255
    ARM_IMM w11, 64
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lselector_version
    ARM_IMM x11, 1
    adds x1, x1, x11
    b .Lselector_scan
.Lselector_version:
    ARM_IMM w10, 0
    mov x16, x1
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x1, x1, x11
    ARM_ADDR x16, registry_exact_version
    str x1, [x16]
    mov x0, x1
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq registry_bad_args
.Lselector_package:
    ARM_ADDR x16, registry_query
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_package
    tst w9, w9
    b.eq registry_bad_args
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 6
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hs .Ldependency_args
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 5
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lregistry_load
    ARM_ADDR x16, registry_target
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_host
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq registry_install_target_error
    ARM_ADDR x16, registry_kind
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_executable_kind
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq registry_bad_args
    b .Lregistry_load
.Ldependency_args:
    ARM_ADDR x16, registry_exact_version
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq registry_bad_args
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne registry_bad_args
    ARM_ADDR x16, registry_kind
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_source_kind
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq registry_bad_args
    ARM_ADDR x16, registry_target
    ldr x9, [x16]
    ARM_ADDR x16, project_requested_target
    str x9, [x16]
    ARM_CALL read_manifest
.Lregistry_load:
    P_BYTE w10, registry_mode
    cmp w10, #5
    b.ne .Lp_registry_load_ready
    ARM_CALL program_before_load
.Lp_registry_load_ready:
    ARM_ADDR x16, registry_index_path
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lregistry_read
    ARM_CALL registry_workspace
    ARM_ADDR x16, registry_url
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_index
    mov x1, x16
    ARM_ADDR x16, registry_index_max
    mov x2, x16
    ARM_CALL registry_download
    tst w9, w9
    b.ne registry_download_error
    ARM_ADDR x16, registry_temp_index
    mov x9, x16
    ARM_ADDR x16, registry_index_path
    str x9, [x16]
.Lregistry_read:
    ARM_CALL registry_read_index
    ARM_CALL registry_parse_index
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 4
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hs registry_fetch
    b registry_list

/* Input: argv cursor follows a value option. Output: x9=borrowed nonempty
 * string <=4095 bytes. Advances the cursor; exits 2 if absent or out of bounds.
 * Stack: one saved pointer. No filesystem or network effect. */
registry_arg_value:
    ARM_CALL next_arg
    tst x9, x9
    b.eq registry_bad_args
    mov x0, x9
    ARM_SAVE x9
    ARM_CALL strlen
    tst x9, x9
    b.eq registry_bad_args
    ARM_IMM x11, 4095
    cmp x9, x11
    b.hi registry_bad_args
    ARM_RESTORE x9
    ret
registry_help:
    ARM_ADDR x16, registry_help_text
    mov x0, x16
    ARM_CALL out
    b exit_ok
registry_bad_args:
    ARM_ADDR x16, registry_err_args
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b registry_fail
registry_bad_index:
    ARM_ADDR x16, registry_err_index
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
registry_download_error:
    ARM_ADDR x16, registry_err_download
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
registry_io_error:
    ARM_ADDR x16, registry_err_io
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
registry_not_found:
    ARM_ADDR x16, registry_err_not_found
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
/* Input: x0=static JSON-safe error, w1=status 1..255. Removes owned temporary
 * files before calling die. No return. Stack: saves the two inputs (32 bytes). */
registry_fail:
    ARM_SAVE x0
    ARM_SAVE x1
    ARM_CALL registry_cleanup
    ARM_RESTORE x1
    ARM_RESTORE x0
    b die

/* Input: current working directory. Creates mode-0700 .asm-registry-<pid> only
 * if absent. Output: owned workspace and its three fixed paths, or fatal error.
 * Buffer capacities: directory=64, file paths=96; PID is <=20 decimal digits.
 * An existing path is never reused. Stack: one saved append pointer. */
registry_workspace:
    ARM_ADDR x16, registry_has_workspace
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lworkspace_done
    ARM_ADDR x16, registry_temp_dir
    mov x0, x16
    ARM_ADDR x16, registry_temp_prefix
    mov x1, x16
    ARM_CALL copy_string
    ARM_SAVE x9
    ARM_CALL arm_getpid
    mov x0, x9
    ARM_ADDR x16, registry_number_buffer + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x1, x9
    ARM_RESTORE x0
    ARM_CALL copy_string
    ARM_ADDR x16, registry_temp_dir
    mov x0, x16
    ARM_IMM w10, 448
    mov w1, w10
    ARM_CALL arm_mkdir
    tst x9, x9
    b.mi registry_io_error
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_has_workspace
    strb w10, [x16]
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_index_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_payload_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_checksum_suffix
    mov x1, x16
    ARM_CALL copy_string
.Lworkspace_done:
    ret

/* Input: ownership flag and fixed workspace paths. Unlinks only index, payload
 * and checksum, then removes the empty directory. Clears the ownership flag.
 * Does not replace an original error with a cleanup error. Stack: none. */
registry_cleanup:
.ifdef ASM_REGISTRY_V2
    ARM_CALL r2_clean_files
.endif
    ARM_CALL program_cleanup
    ARM_ADDR x16, self_active
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne self_update_cleanup
    ARM_ADDR x16, registry_has_workspace
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lcleanup_done
    ARM_ADDR x16, registry_extra_temp
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.eq .Lcleanup_fixed_files
    ARM_CALL arm_unlink
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_extra_temp
    str x10, [x16]
.Lcleanup_fixed_files:
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, registry_temp_dir
    mov x0, x16
    ARM_CALL arm_rmdir
    ARM_IMM w10, 0
    ARM_ADDR x16, registry_has_workspace
    strb w10, [x16]
.Lcleanup_done:
    ret

/* curl's config is disabled before all other options. Protocol and redirects
 * remain HTTPS-only. The caller supplies a validated URL and a bounded size. */
/* Input: x0=URL (<=4095 chars), x1=owned temporary output path (<=95 chars),
 * x2=decimal maximum bytes (1..67108864). Output: w9=child exit status or
 * 128+signal; size/fork/wait/limit/exec failure is 127. Missing curl is fatal.
 * Only the curl child lowers RLIMIT_FSIZE, independently of curl's handling
 * of Content-Length and streaming responses. Soft and hard values are each
 * capped without raising a stricter inherited limit. No other resource limit
 * changes. The parent, verifier, and hashing processes retain their limits.
 * Retries interrupted waits. Owns fixed 23-pointer argv; stack: 32 saved
 * bytes and 32 local bytes (16-byte Linux rlimit / child status + alignment).
 * Asm AArch64 callee-saved registers are preserved. No shell is involved. */
registry_download:
    ARM_ADDR x16, registry_curl_argv + 21*8
    str x0, [x16]
    ARM_ADDR x16, registry_curl_argv + 19*8
    str x1, [x16]
    ARM_ADDR x16, registry_curl_argv + 17*8
    str x2, [x16]
    ARM_ADDR x16, registry_curl
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Lcurl_missing
    ARM_SAVE x19
    ARM_SAVE x21
    sub sp, sp, #32
    ARM_ADDR x16, registry_curl_argv + 17*8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    tst x9, x9
    b.eq .Lcurl_failed
    mov x21, x9
    ARM_CALL arm_fork
    tst x9, x9
    b.mi .Lcurl_failed
    b.eq .Lcurl_child
    mov x19, x9
.Lcurl_wait:
    mov x0, x19
    mov x10, sp
    mov x1, x10
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lcurl_wait
    tst x9, x9
    b.mi .Lcurl_failed
    mov x16, sp
    ldr w10, [x16]
    mov w9, w10
    mov w2, w9
    ARM_IMM w11, 127
    and w2, w2, w11
    tst w2, w2
    b.ne .Lcurl_signaled
    lsr w9, w9, #8
    tst w9, w9
    ARM_IMM w11, 255
    and w9, w9, w11
    tst w9, w9
    b .Lcurl_return
.Lcurl_signaled:
    mov x16, x2
    add x16, x16, #128
    mov w9, w16
    b .Lcurl_return
.Lcurl_child:
    ARM_IMM w10, 1 /* RLIMIT_FSIZE */
    mov w0, w10
    mov x10, sp
    mov x1, x10
    ARM_CALL arm_getrlimit
    tst x9, x9
    b.mi .Lcurl_child_failed
    mov x9, x21
    mov x16, sp
    ldr x11, [x16]
    cmp x9, x11
    mov x16, sp
    ldr x11, [x16]
    csel x9, x11, x9, hi
    mov x16, sp
    str x9, [x16]
    mov x9, x21
    mov x16, sp
    add x16, x16, #8
    ldr x11, [x16]
    cmp x9, x11
    mov x16, sp
    add x16, x16, #8
    ldr x11, [x16]
    csel x9, x11, x9, hi
    mov x16, sp
    add x16, x16, #8
    str x9, [x16]
    ARM_IMM w10, 1 /* RLIMIT_FSIZE */
    mov w0, w10
    mov x10, sp
    mov x1, x10
    ARM_CALL arm_setrlimit
    tst x9, x9
    b.mi .Lcurl_child_failed
    ARM_ADDR x16, registry_curl
    mov x0, x16
    ARM_ADDR x16, registry_curl_argv
    mov x1, x16
    ARM_ADDR x16, envp
    ldr x10, [x16]
    mov x2, x10
    ARM_CALL arm_execve
.Lcurl_child_failed:
    ARM_IMM w10, 127
    mov w0, w10
    b exit_code
.Lcurl_failed:
    ARM_IMM w10, 127
    mov w9, w10
.Lcurl_return:
    add sp, sp, #32
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
.Lcurl_missing:
    ARM_ADDR x16, registry_err_curl
    mov x0, x16
    ARM_IMM w10, 127
    mov w1, w10
    b registry_fail

/* Input: registry_index_path. Reads only a regular non-symlink file, bounded to
 * 1 MiB. Output: index bytes plus NUL, registry_index_end exclusive. Retries
 * EINTR/short reads; growth beyond the bound fails. Stack: 32 saved bytes. */
registry_read_index:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, registry_index_path
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi registry_io_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lindex_read_error
    ARM_ADDR x16, registry_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Lindex_read_error
    ARM_ADDR x16, registry_stat + ARM_STAT_SIZE
    ldr x10, [x16]
    ARM_IMM x11, INDEX_LIMIT
    cmp x10, x11
    b.hi .Lindex_read_error
    eor w22, w22, w22
    tst w22, w22
.Lindex_read_loop:
    mov x0, x21
    ARM_ADDR x16, registry_index
    mov x1, x16
    adds x1, x1, x22
    ARM_IMM w10, INDEX_LIMIT + 1
    mov w2, w10
    subs x2, x2, x22
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lindex_read_loop
    tst x9, x9
    b.mi .Lindex_read_error
    b.eq .Lindex_read_done
    adds x22, x22, x9
    ARM_IMM x11, INDEX_LIMIT
    cmp x22, x11
    b.hi .Lindex_read_error
    b .Lindex_read_loop
.Lindex_read_done:
    mov x0, x21
    ARM_CALL arm_close
    ARM_ADDR x16, registry_index
    mov x9, x16
    ARM_IMM w10, 0
    mov x16, x9
    add x16, x16, x22
    strb w10, [x16]
    adds x9, x9, x22
    ARM_ADDR x16, registry_index_end
    str x9, [x16]
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret
.Lindex_read_error:
    mov x0, x21
    ARM_CALL arm_close
    b registry_bad_index

/* Input: bounded index/end from registry_read_index. Output: <=4096 records,
 * each eight borrowed pointers into index. Replaces TAB/LF with NUL. Rejects
 * invalid headers, controls, non-ASCII, missing LF, >2048-byte rows, malformed
 * fields and duplicate artifact identities before any result is printed.
 * Capacity: registry_rows=4096*64 bytes. Stack: 64 saved bytes plus calls. */
registry_parse_index:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, registry_index
    mov x21, x16
    ARM_ADDR x16, registry_header
    mov x1, x16
    eor w3, w3, w3
    tst w3, w3
.Lindex_header:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lindex_header_done
    and w10, w9, #255
    mov x16, x21
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_bad_index
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lindex_header
.Lindex_header_done:
    mov x16, x21
    add x16, x16, x3
    mov x0, x16
    ARM_ADDR x16, registry_index_end
    ldr x10, [x16]
    mov x1, x10
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    b registry_parse_records

/* Input: x0=start of bounded TSV records, x1=exclusive end. Shared by index
 * and lock parsers after their headers. Output: registry_rows/count. Replaces
 * delimiters with NUL; validates every record before returning. Stack: 64 saved bytes. */
registry_parse_records:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    ARM_ADDR x16, registry_index_end
    str x1, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_row_count
    str x10, [x16]
.Lindex_row:
    ARM_ADDR x16, registry_index_end
    ldr x11, [x16]
    cmp x21, x11
    b.eq .Lindex_parsed
    b.hi registry_bad_index
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM x11, ROW_LIMIT
    cmp x9, x11
    b.hs registry_bad_index
    lsl x9, x9, #6
    tst x9, x9
    ARM_ADDR x16, registry_rows
    mov x22, x16
    adds x22, x22, x9
    mov x16, x22
    str x21, [x16]
    eor w23, w23, w23
    tst w23, w23
    mov x24, x21
.Lindex_char:
    ARM_ADDR x16, registry_index_end
    ldr x11, [x16]
    cmp x21, x11
    b.hs registry_bad_index
    mov x9, x21
    subs x9, x9, x24
    ARM_IMM x11, 2048
    cmp x9, x11
    b.hs registry_bad_index
    mov x16, x21
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lindex_tab
    and w10, w9, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lindex_newline
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_bad_index
    and w10, w9, #255
    ARM_IMM w11, 127
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hs registry_bad_index
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lindex_char
.Lindex_tab:
    ARM_IMM w11, 7
    cmp w23, w11
    b.hs registry_bad_index
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    ARM_IMM w11, 1
    adds w23, w23, w11
    mov x16, x22
    add x16, x16, x23, lsl #3
    str x21, [x16]
    b .Lindex_char
.Lindex_newline:
    ARM_IMM w11, 7
    cmp w23, w11
    b.ne registry_bad_index
    ARM_IMM w10, 0
    mov x16, x21
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x21, x21, x11
    mov x0, x22
    ARM_CALL registry_validate_row
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, registry_row_count
    str x12, [x16]
    b .Lindex_row
.Lindex_parsed:
    ARM_CALL registry_check_unique
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret

/* Input: x0 points to eight bounded, NUL-terminated field pointers. Output:
 * returns only for valid fields. The complete parser checks identity uniqueness
 * before returning. Scratch: index is unchanged. Stack: 16 saved bytes plus calls. */
registry_validate_row:
    ARM_SAVE x19
    mov x19, x0
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_package
    tst w9, w9
    b.eq registry_bad_index
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq registry_bad_index
    mov x16, x19
    add x16, x16, #16
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_target
    tst w9, w9
    b.eq registry_bad_index
    mov x16, x19
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_valid_kind
    tst w9, w9
    b.eq registry_bad_index
    mov x16, x19
    add x16, x16, #32
    ldr x10, [x16]
    mov x0, x10
    eor w3, w3, w3
    tst w3, w3
.Lhash_validate:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_bad_index
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lhash_next
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_bad_index
    and w10, w9, #255
    ARM_IMM w11, 102
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_bad_index
.Lhash_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 64
    cmp w3, w11
    b.lo .Lhash_validate
    mov x16, x0
    add x16, x16, #64
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_bad_index
    mov x16, x19
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_release_url
    tst w9, w9
    b.eq registry_bad_index
    mov x16, x19
    add x16, x16, #24
    ldr x10, [x16]
    mov x9, x10
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 115
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lrow_artifact_suffix
    mov x16, x19
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    ARM_IMM x11, 7
    cmp x9, x11
    b.lo registry_bad_index
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #7
    mov x0, x16
    ARM_ADDR x16, registry_tar_suffix
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq registry_bad_index
.Lrow_artifact_suffix:
    mov x16, x19
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    tst x9, x9
    b.eq registry_bad_index
    mov x16, x19
    add x16, x16, #56
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL strlen
    tst x9, x9
    b.eq registry_bad_index
    ARM_IMM x11, 160
    cmp x9, x11
    b.hi registry_bad_index
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_bad_index
    mov x16, x0
    add x16, x16, x9
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_bad_index
    ARM_RESTORE x19
    ret

/* Input: x0/x1=validated eight-pointer rows. Output: w9 is negative, zero,
 * or positive for lexical artifact-identity order (package/version/target/kind).
 * Bytes are printable ASCII and each field ends at an accessible NUL. No row
 * or string changes. Scratch: x9/x3/x2/x4/x5. Stack: none. */
registry_identity_compare:
    eor w3, w3, w3
    tst w3, w3
.Lidentity_field:
    mov x16, x0
    add x16, x16, x3
    ldr x10, [x16]
    mov x4, x10
    mov x16, x1
    add x16, x16, x3
    ldr x10, [x16]
    mov x5, x10
.Lidentity_byte:
    mov x16, x4
    ldrb w10, [x16]
    mov w9, w10
    mov x16, x5
    ldrb w10, [x16]
    mov w2, w10
    subs w9, w9, w2
    b.ne .Lidentity_return
    tst w2, w2
    b.eq .Lidentity_next_field
    ARM_IMM x11, 1
    adds x4, x4, x11
    ARM_IMM x11, 1
    adds x5, x5, x11
    b .Lidentity_byte
.Lidentity_next_field:
    ARM_IMM w11, 8
    adds w3, w3, w11
    ARM_IMM w11, 32
    cmp w3, w11
    b.lo .Lidentity_field
.Lidentity_return:
    ret

/* Input: x0=owned row-pointer array, x1=root index, x2=exclusive heap size.
 * Bounds: root < size <= ROW_LIMIT. The child heaps already satisfy max order.
 * Output: restores the max heap rooted at x1. Only pointers within the array
 * change. All row bytes remain unchanged. Scratch: caller-saved registers.
 * Stack: 80 saved bytes plus calls. At most floor(log2(ROW_LIMIT)) iterations. */
registry_identity_sift:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x19, x0
    mov x21, x1
    mov x22, x2
.Lidentity_sift_loop:
    mov x16, x21
    add x16, x16, x21
    add x16, x16, #1
    mov x23, x16
    cmp x23, x22
    b.hs .Lidentity_sift_done
    mov x16, x23
    add x16, x16, #1
    mov x24, x16
    cmp x24, x22
    b.hs .Lidentity_sift_child
    mov x16, x19
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, x24, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL registry_identity_compare
    tst w9, w9
    b.ge .Lidentity_sift_child
    mov x23, x24
.Lidentity_sift_child:
    mov x16, x19
    add x16, x16, x21, lsl #3
    ldr x10, [x16]
    mov x0, x10
    mov x16, x19
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL registry_identity_compare
    tst w9, w9
    b.ge .Lidentity_sift_done
    mov x16, x19
    add x16, x16, x21, lsl #3
    ldr x10, [x16]
    mov x9, x10
    mov x16, x19
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x3, x10
    mov x16, x19
    add x16, x16, x21, lsl #3
    str x3, [x16]
    mov x16, x19
    add x16, x16, x23, lsl #3
    str x9, [x16]
    mov x21, x23
    b .Lidentity_sift_loop
.Lidentity_sift_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Input: registry_rows contains registry_row_count <= ROW_LIMIT validated rows.
 * Output: returns only when every artifact identity is unique; otherwise exits
 * before any result or download. Sorts a separate 32 KiB pointer array with
 * heap sort, then compares adjacent identities. Work is O(n log n), including
 * hostile row order; there is no hash collision path or recursion. Original
 * row order is preserved. Scratch: caller-saved registers and owned pointer
 * array. Stack: 64 saved bytes; at most 176 bytes with nested calls. */
registry_check_unique:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_ADDR x16, registry_row_count
    ldr x10, [x16]
    mov x21, x10
    ARM_IMM x11, 2
    cmp x21, x11
    b.lo .Lunique_done
    ARM_ADDR x16, registry_sorted_rows
    mov x22, x16
    ARM_ADDR x16, registry_rows
    mov x19, x16
    eor w3, w3, w3
    tst w3, w3
.Lunique_copy:
    mov x16, x22
    add x16, x16, x3, lsl #3
    str x19, [x16]
    ARM_IMM x11, 64
    adds x19, x19, x11
    ARM_IMM x11, 1
    adds x3, x3, x11
    cmp x3, x21
    b.lo .Lunique_copy
    mov x23, x21
    lsr x23, x23, #1
    tst x23, x23
.Lunique_heap:
    ARM_IMM x11, 1
    subs x23, x23, x11
    mov x0, x22
    mov x1, x23
    mov x2, x21
    ARM_CALL registry_identity_sift
    tst x23, x23
    b.ne .Lunique_heap
    mov x23, x21
    ARM_IMM x11, 1
    subs x23, x23, x11
.Lunique_sort:
    mov x16, x22
    ldr x10, [x16]
    mov x9, x10
    mov x16, x22
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x3, x10
    mov x16, x22
    str x3, [x16]
    mov x16, x22
    add x16, x16, x23, lsl #3
    str x9, [x16]
    mov x0, x22
    eor w1, w1, w1
    tst w1, w1
    mov x2, x23
    ARM_CALL registry_identity_sift
    ARM_IMM x11, 1
    subs x23, x23, x11
    b.ne .Lunique_sort
    ARM_IMM w10, 1
    mov w23, w10
.Lunique_adjacent:
    mov x16, x22
    add x16, x16, x23, lsl #3
    sub x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x22
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL registry_identity_compare
    tst w9, w9
    b.eq registry_bad_index
    ARM_IMM x11, 1
    adds x23, x23, x11
    cmp x23, x21
    b.lo .Lunique_adjacent
.Lunique_done:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* A namespace component is lowercase, does not end in '-' and has no '--'. */
/* Input: x0=component, w1=max length (39 or 64). Ends at '/' or NUL. Output:
 * w9=length on success, zero on failure. Scratch: x9/x3/x2. Stack: none. */
registry_component:
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
    eor w3, w3, w3
    tst w3, w3
    eor w2, w2, w2
    tst w2, w2
.Lcomponent_loop:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lcomponent_end
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lcomponent_end
    cmp w3, w1
    b.hs registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lcomponent_dash
    eor w2, w2, w2
    tst w2, w2
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lcomponent_next
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
    b .Lcomponent_next
.Lcomponent_dash:
    tst w2, w2
    b.ne registry_invalid
    ARM_IMM w10, 1
    mov w2, w10
.Lcomponent_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lcomponent_loop
.Lcomponent_end:
    tst w2, w2
    b.ne registry_invalid
    mov w9, w3
    ret
/* Input: x0=package string. Output: w9=1 for owner/name, else zero. Owner is
 * <=39 chars, name <=64 chars; exactly one slash. Stack: one saved pointer. */
registry_valid_package:
    ARM_SAVE x0
    ARM_IMM w10, 39
    mov w1, w10
    ARM_CALL registry_component
    ARM_RESTORE x0
    tst w9, w9
    b.eq registry_invalid
    mov x16, x0
    add x16, x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_invalid
    mov x16, x0
    add x16, x16, x9
    add x16, x16, #1
    mov x0, x16
    ARM_SAVE x0
    ARM_IMM w10, 64
    mov w1, w10
    ARM_CALL registry_component
    ARM_RESTORE x0
    tst w9, w9
    b.eq registry_invalid
    mov x16, x0
    add x16, x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_invalid
    b registry_valid

/* Input: x0=version. Output: w9=1 for exactly three decimal components, each
 * <=2147483647, no leading zeroes. Maximum accepted length is 32. No overflow:
 * each multiply starts from a value <=2147483647. Stack: none. */
registry_valid_version:
    eor w3, w3, w3
    tst w3, w3
    eor w4, w4, w4
    tst w4, w4
.Lreg_version_component:
    eor w2, w2, w2
    tst w2, w2
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lreg_version_zero
.Lreg_version_digit:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lreg_version_separator
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lreg_version_separator
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM x11, 10
    mul x2, x2, x11
    adds x2, x2, x9
    ARM_IMM x11, 2147483647
    cmp x2, x11
    b.hi registry_invalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lreg_version_digit
.Lreg_version_zero:
    ARM_IMM w11, 1
    adds w3, w3, w11
.Lreg_version_separator:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lreg_version_end
    and w10, w9, #255
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_invalid
    ARM_IMM w11, 1
    adds w4, w4, w11
    ARM_IMM w11, 2
    cmp w4, w11
    b.hi registry_invalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lreg_version_component
.Lreg_version_end:
    ARM_IMM w11, 2
    cmp w4, w11
    b.ne registry_invalid
    b registry_valid

/* Input: x0=string. Output: w9=1 only for one of the three published targets.
 * This is artifact selection, not a claim that the host can execute it. */
registry_valid_target:
    ARM_SAVE x0
    ARM_ADDR x1, registry_macos
    ARM_CALL streq
    ARM_RESTORE x0
    cbnz w9, registry_valid
    ARM_SAVE x0
    ARM_ADDR x16, registry_x86_64
    mov x1, x16
    ARM_CALL streq
    ARM_RESTORE x0
    tst w9, w9
    b.ne registry_valid
    ARM_SAVE x0
    ARM_ADDR x16, registry_aarch64
    mov x1, x16
    ARM_CALL streq
    ARM_RESTORE x0
    tst w9, w9
    b.ne registry_valid
    ARM_ADDR x16, registry_riscv64
    mov x1, x16
    b streq
/* Input: x0=string. Output: w9=1 for source/executable, else zero.
 * Stack: one saved pointer. Does not authorize execution. */
registry_valid_kind:
    ARM_SAVE x0
    ARM_ADDR x16, registry_source_kind
    mov x1, x16
    ARM_CALL streq
    ARM_RESTORE x0
    tst w9, w9
    b.ne registry_valid
    ARM_ADDR x16, registry_executable_kind
    mov x1, x16
    b streq

/* Input: x0=decimal string. Output: x9=size 1..64 MiB, or zero on failure.
 * Rejects signs and leading zeroes. Checks each multiply against the bound.
 * Scratch: x9/x3/x2. Stack: none. */
registry_size_value:
    eor w9, w9, w9
    tst w9, w9
    eor w3, w3, w3
    tst w3, w3
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 49
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
.Lsize_digit:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w2, w10
    tst w2, w2
    b.eq .Lsize_done
    ARM_IMM w11, 48
    cmp w2, w11
    b.lo registry_invalid
    ARM_IMM w11, 57
    cmp w2, w11
    b.hi registry_invalid
    ARM_IMM w11, 48
    subs w2, w2, w11
    ARM_IMM x11, 10
    mul x9, x9, x11
    adds x9, x9, x2
    ARM_IMM x11, ARTIFACT_LIMIT
    cmp x9, x11
    b.hi registry_invalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lsize_digit
.Lsize_done:
    ret

/* Input: x0=index URL already bounded to 4095 chars. Output: w9=1 for a
 * nonempty HTTPS URL with printable bytes and no userinfo/backslash, else zero.
 * This permits a user-selected registry origin; it is not artifact policy. */
registry_https_url:
    ARM_ADDR x16, registry_https_prefix
    mov x1, x16
    eor w3, w3, w3
    tst w3, w3
.Lhttps_prefix:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lhttps_body
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_invalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lhttps_prefix
.Lhttps_body:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_invalid
.Lhttps_char:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq registry_valid
    and w10, w9, #255
    ARM_IMM w11, 33
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 64
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_invalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lhttps_char

/* GitHub release URLs have exactly six path components. Restrict the alphabet
 * and reject dot components, query strings, fragments and percent encoding. */
/* Input: x0=bounded artifact URL. Output: w9=1 or zero. Read-only validation;
 * the release URL does not establish namespace ownership. Stack: none. */
registry_release_url:
    ARM_CALL strlen
    ARM_IMM x11, 768
    cmp x9, x11
    b.hi registry_invalid
    ARM_ADDR x16, registry_github_prefix
    mov x1, x16
    eor w3, w3, w3
    tst w3, w3
.Lrelease_prefix:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lrelease_path
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_invalid
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lrelease_prefix
.Lrelease_path:
    adds x0, x0, x3
    eor w4, w4, w4
    tst w4, w4
    mov x5, x0
    eor w3, w3, w3
    tst w3, w3
.Lrelease_segment_start:
    mov x16, x5
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lrelease_char
    and w10, w9, #255
    ARM_IMM w11, 65
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 90
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lrelease_char
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
.Lrelease_char:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lrelease_segment
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrelease_segment
    and w10, w9, #255
    ARM_IMM w11, 45
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrelease_next
    tst w4, w4
    b.eq .Lrelease_alphanumeric
    and w10, w9, #255
    ARM_IMM w11, 95
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrelease_next
    and w10, w9, #255
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lrelease_next
.Lrelease_alphanumeric:
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lrelease_next
    and w10, w9, #255
    ARM_IMM w11, 65
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 90
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lrelease_next
    and w10, w9, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo registry_invalid
    and w10, w9, #255
    ARM_IMM w11, 122
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi registry_invalid
.Lrelease_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lrelease_char
.Lrelease_segment:
    mov x16, x0
    add x16, x16, x3
    mov x6, x16
    mov x7, x6
    subs x7, x7, x5
    tst x7, x7
    b.eq registry_invalid
    ARM_IMM w11, 1
    adds w4, w4, w11
    ARM_IMM w11, 1
    cmp w4, w11
    b.eq .Lrelease_owner
    ARM_IMM w11, 2
    cmp w4, w11
    b.eq .Lrelease_repository
    ARM_IMM w11, 3
    cmp w4, w11
    b.eq .Lrelease_label_releases
    ARM_IMM w11, 4
    cmp w4, w11
    b.eq .Lrelease_label_download
    ARM_IMM x11, 128
    cmp x7, x11
    b.hi registry_invalid
    b .Lrelease_delimiter
.Lrelease_owner:
    ARM_IMM x11, 39
    cmp x7, x11
    b.hi registry_invalid
    b .Lrelease_delimiter
.Lrelease_repository:
    ARM_IMM x11, 100
    cmp x7, x11
    b.hi registry_invalid
    ARM_IMM x11, 4
    cmp x7, x11
    b.lo .Lrelease_delimiter
    mov x16, x6
    sub x16, x16, #4
    ldr w10, [x16]
    ARM_IMM w11, 1953064750
    cmp w10, w11
    b.eq registry_invalid
    b .Lrelease_delimiter
.Lrelease_label_releases:
    ARM_IMM x11, 8
    cmp x7, x11
    b.ne registry_invalid
    ARM_IMM x10, 8315179149160113522
    mov x2, x10
    mov x16, x5
    ldr x10, [x16]
    cmp x10, x2
    b.ne registry_invalid
    b .Lrelease_delimiter
.Lrelease_label_download:
    ARM_IMM x11, 8
    cmp x7, x11
    b.ne registry_invalid
    ARM_IMM x10, 7233184988034199396
    mov x2, x10
    mov x16, x5
    ldr x10, [x16]
    cmp x10, x2
    b.ne registry_invalid
.Lrelease_delimiter:
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lrelease_end
    ARM_IMM w11, 6
    cmp w4, w11
    b.hs registry_invalid
    mov x16, x6
    add x16, x16, #1
    mov x5, x16
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lrelease_segment_start
.Lrelease_end:
    ARM_IMM w11, 6
    cmp w4, w11
    b.ne registry_invalid
    b registry_valid
registry_valid:
    ARM_IMM w10, 1
    mov w9, w10
    ret
registry_invalid:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Terminal command: uses validated registry_rows. search matches package or
 * summary; info matches a package; versions suppresses duplicate versions.
 * Emits plain TSV or one JSON object. Cleans the workspace before exit. */
registry_list:
    ARM_IMM w10, 1
    ARM_ADDR x16, registry_output_active
    strb w10, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_output_size
    str x10, [x16]
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llist_start
    ARM_ADDR x16, registry_results_prefix
    mov x0, x16
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 3
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Llist_prefix
    ARM_ADDR x16, registry_versions_prefix
    mov x0, x16
.Llist_prefix:
    ARM_CALL registry_emit
.Llist_start:
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Llist_row:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Llist_done
    mov x16, x21
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_query
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llist_search
    ARM_CALL streq
    tst w9, w9
    b.eq .Llist_next
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 3
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Llist_match
    ARM_CALL registry_version_seen
    tst w9, w9
    b.ne .Llist_next
    b .Llist_match
.Llist_search:
    ARM_CALL registry_contains
    tst w9, w9
    b.ne .Llist_match
    mov x16, x21
    add x16, x16, #56
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_query
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL registry_contains
    tst w9, w9
    b.eq .Llist_next
.Llist_match:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llist_human
    ARM_ADDR x16, registry_matches
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Llist_json_row
    ARM_ADDR x16, registry_comma
    mov x0, x16
    ARM_CALL registry_emit
.Llist_json_row:
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 3
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llist_json_version
    mov x0, x21
    ARM_CALL registry_print_json_row
    b .Llist_count
.Llist_json_version:
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    b .Llist_count
.Llist_human:
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 3
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llist_human_version
    mov x0, x21
    ARM_CALL registry_print_text_row
    b .Llist_count
.Llist_human_version:
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_emit
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL registry_emit
.Llist_count:
    ARM_ADDR x16, registry_matches
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x12, x10, x11
    ARM_ADDR x16, registry_matches
    str x12, [x16]
.Llist_next:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Llist_row
.Llist_done:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Llist_finish
    ARM_ADDR x16, registry_results_suffix
    mov x0, x16
    ARM_CALL registry_emit
.Llist_finish:
    ARM_ADDR x16, registry_matches
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Llist_flush
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Llist_flush
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Llist_flush
    ARM_ADDR x16, registry_no_matches
    mov x0, x16
    ARM_CALL registry_emit
.Llist_flush:
    ARM_CALL registry_flush
    ARM_IMM w10, 0
    ARM_ADDR x16, registry_output_active
    strb w10, [x16]
    ARM_CALL registry_cleanup
    ARM_ADDR x16, registry_matches
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne exit_ok
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne registry_not_found
    b exit_ok

/* Input: x0=accessible NUL-terminated text. Output: writes through out when
 * listing is inactive; otherwise appends to the owned 64 KiB output buffer.
 * Each copy is bounded by remaining capacity and string length. A full buffer
 * is flushed before reuse. Copies advance through memory. Scratch: caller-saved
 * registers and buffer; callee-saved registers survive. Stack: 48 saved bytes
 * plus calls. A returned write error is fatal and cleans the registry workspace. */
registry_emit:
    ARM_ADDR x16, registry_output_active
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq out
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x19, x0
    ARM_CALL strlen
    mov x21, x9
.Lemit_chunk:
    tst x21, x21
    b.eq .Lemit_done
    ARM_ADDR x16, registry_output_size
    ldr x10, [x16]
    mov x9, x10
    ARM_IMM w10, REGISTRY_OUTPUT_LIMIT
    mov w22, w10
    subs x22, x22, x9
    cmp x22, x21
    b.ls .Lemit_copy
    mov x22, x21
.Lemit_copy:
    ARM_ADDR x16, registry_output_buffer
    mov x0, x16
    adds x0, x0, x9
    mov x1, x19
    mov x3, x22
    cbz x3, .Lport_registry_1_end
.Lport_registry_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_registry_1
.Lport_registry_1_end:
    ARM_ADDR x16, registry_output_size
    ldr x10, [x16]
    adds x12, x10, x22
    ARM_ADDR x16, registry_output_size
    str x12, [x16]
    adds x19, x19, x22
    subs x21, x21, x22
    ARM_ADDR x16, registry_output_size
    ldr x10, [x16]
    ARM_IMM x11, REGISTRY_OUTPUT_LIMIT
    cmp x10, x11
    b.ne .Lemit_chunk
    ARM_CALL registry_flush
    b .Lemit_chunk
.Lemit_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    eor w9, w9, w9
    tst w9, w9
    ret

/* Input: owned output buffer and size <= REGISTRY_OUTPUT_LIMIT. Output: all
 * queued bytes are written once in order, then size becomes zero. write_all
 * retries EINTR and short writes. Any other failure exits nonzero. Scratch:
 * caller-saved registers; no saved stack bytes, one nested call. */
registry_flush:
    ARM_ADDR x16, registry_output_size
    ldr x10, [x16]
    mov x2, x10
    tst x2, x2
    b.eq .Lflush_done
    ARM_IMM w10, 1
    mov w0, w10
    ARM_ADDR x16, registry_output_buffer
    mov x1, x16
    ARM_CALL write_all
    tst x9, x9
    b.mi .Lflush_error
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_output_size
    str x10, [x16]
.Lflush_done:
    ret
.Lflush_error:
    ARM_ADDR x16, registry_err_output_write
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail

/* Input: x0=haystack, x1=needle, both bounded strings. Output: w9=1 for a
 * case-sensitive substring (including empty needle), else zero. Read-only.
 * Scratch: x9/x3/x4. Stack: none. */
registry_contains:
    mov x16, x1
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_valid
    mov x4, x0
.Lcontains_start:
    mov x16, x4
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq registry_invalid
    eor w3, w3, w3
    tst w3, w3
.Lcontains_chars:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq registry_valid
    and w10, w9, #255
    mov x16, x4
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lcontains_next
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lcontains_chars
.Lcontains_next:
    ARM_IMM x11, 1
    adds x4, x4, x11
    b .Lcontains_start

/* Current row is x21. Suppress versions already printed for this package. */
/* Input: x21=current row in registry_rows. Output: w9=1 if an earlier row has
 * the same package and version. Read-only; scan ends before x21. Stack: 16 saved bytes. */
registry_version_seen:
    ARM_SAVE x19
    ARM_ADDR x16, registry_rows
    mov x19, x16
.Lversion_seen_row:
    cmp x19, x21
    b.hs .Lversion_unseen
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    mov x16, x21
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lversion_seen_next
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.ne .Lversion_seen_return
.Lversion_seen_next:
    ARM_IMM x11, 64
    adds x19, x19, x11
    b .Lversion_seen_row
.Lversion_unseen:
    eor w9, w9, w9
    tst w9, w9
.Lversion_seen_return:
    ARM_RESTORE x19
    ret

/* Input: x0=validated eight-pointer record. Writes one TSV row to stdout.
 * Record fields contain no tabs or controls. Stack: 32 saved bytes plus calls. */
registry_print_text_row:
    ARM_SAVE x19
    ARM_SAVE x23
    mov x19, x0
    eor w23, w23, w23
    tst w23, w23
.Ltext_field:
    tst w23, w23
    b.eq .Ltext_value
    ARM_ADDR x16, registry_tab
    mov x0, x16
    ARM_CALL registry_emit
.Ltext_value:
    mov x16, x19
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_emit
    ARM_IMM w11, 1
    adds w23, w23, w11
    ARM_IMM w11, 8
    cmp w23, w11
    b.lo .Ltext_field
    ARM_ADDR x16, registry_newline
    mov x0, x16
    ARM_CALL registry_emit
    ARM_RESTORE x23
    ARM_RESTORE x19
    ret

/* Input: x0=validated eight-pointer record. Writes one JSON object; bytes is
 * numeric and all other values are escaped strings. Stack: 48 saved bytes. */
registry_print_json_row:
    ARM_SAVE x19
    ARM_SAVE x23
    ARM_SAVE x24
    mov x19, x0
    ARM_ADDR x16, registry_lbrace
    mov x0, x16
    ARM_CALL registry_emit
    eor w23, w23, w23
    tst w23, w23
    ARM_ADDR x16, registry_json_keys
    mov x24, x16
.Ljson_field:
    tst w23, w23
    b.eq .Ljson_key
    ARM_ADDR x16, registry_comma
    mov x0, x16
    ARM_CALL registry_emit
.Ljson_key:
    mov x16, x24
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_emit
    mov x16, x19
    add x16, x16, x23, lsl #3
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w11, 6
    cmp w23, w11
    b.eq .Ljson_number
    ARM_CALL registry_json_string
    b .Ljson_next
.Ljson_number:
    ARM_CALL registry_emit
.Ljson_next:
    ARM_IMM w11, 1
    adds w23, w23, w11
    ARM_IMM w11, 8
    cmp w23, w11
    b.lo .Ljson_field
    ARM_ADDR x16, registry_rbrace
    mov x0, x16
    ARM_CALL registry_emit
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x19
    ret

/* Metadata is printable ASCII. File arguments may contain controls, which are
 * encoded as \u00XX. A 4095-byte path requires at most 24572 output bytes. */
/* Input: x0=string <=4095 bytes. Output: writes a quoted JSON string. Owned
 * scratch buffer is 24576 bytes, including closing quote and NUL. Other bytes
 * are copied unchanged; non-ASCII paths must use UTF-8 for valid JSON. */
registry_json_string:
    mov x1, x0
    ARM_ADDR x16, registry_json_buffer
    mov x0, x16
    ARM_IMM w10, 34
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
.Lquote_char:
    mov x16, x1
    ldrb w10, [x16]
    mov w9, w10
    ARM_IMM x11, 1
    adds x1, x1, x11
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lquote_end
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lquote_control
    and w10, w9, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lquote_escape
    and w10, w9, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lquote_escape
    and w10, w9, #255
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    b .Lquote_char
.Lquote_escape:
    ARM_IMM w10, 92
    mov x16, x0
    strb w10, [x16]
    and w10, w9, #255
    mov x16, x0
    add x16, x16, #1
    strb w10, [x16]
    ARM_IMM x11, 2
    adds x0, x0, x11
    b .Lquote_char
.Lquote_control:
    ARM_IMM w10, 92
    mov x16, x0
    strb w10, [x16]
    ARM_IMM w10, 117
    mov x16, x0
    add x16, x16, #1
    strb w10, [x16]
    ARM_IMM w10, 48
    mov x16, x0
    add x16, x16, #2
    strb w10, [x16]
    ARM_IMM w10, 48
    mov x16, x0
    add x16, x16, #3
    strb w10, [x16]
    mov w2, w9
    lsr w2, w2, #4
    tst w2, w2
    ARM_ADDR x16, registry_hex_digits
    mov x3, x16
    mov x16, x3
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x2, x10, #0, #8
    and w10, w2, #255
    mov x16, x0
    add x16, x16, #4
    strb w10, [x16]
    ARM_IMM w11, 15
    and w9, w9, w11
    tst w9, w9
    mov x16, x3
    add x16, x16, x9
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    mov x16, x0
    add x16, x16, #5
    strb w10, [x16]
    ARM_IMM x11, 6
    adds x0, x0, x11
    b .Lquote_char
.Lquote_end:
    ARM_IMM w10, 34
    mov x16, x0
    strb w10, [x16]
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, #1
    strb w10, [x16]
    ARM_ADDR x16, registry_json_buffer
    mov x0, x16
    b registry_emit

/* Input: validated rows plus query/target/kind/exact-version globals.
 * Output: x9=selected eight-pointer row, or zero. Stores registry_selected.
 * Numeric version order is shared by package fetch and self update.
 * Stack: 32 saved bytes plus 16 local bytes. No filesystem changes. */
registry_select:
    ARM_SAVE x21
    ARM_SAVE x22
    sub sp, sp, #16
    ARM_IMM x10, 0
    ARM_ADDR x16, registry_selected
    str x10, [x16]
    ARM_ADDR x16, registry_rows
    mov x21, x16
    eor w22, w22, w22
    tst w22, w22
.Lfetch_select:
    ARM_ADDR x16, registry_row_count
    ldr x11, [x16]
    cmp x22, x11
    b.hs .Lfetch_selected
    mov x16, x21
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_query
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lfetch_next
    mov x16, x21
    add x16, x16, #16
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_target
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lfetch_next
    mov x16, x21
    add x16, x16, #24
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_kind
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lfetch_next
    ARM_ADDR x16, registry_exact_version
    ldr x10, [x16]
    mov x1, x10
    tst x1, x1
    b.eq .Lfetch_latest
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL streq
    tst w9, w9
    b.eq .Lfetch_next
    b .Lfetch_choose
.Lfetch_latest:
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x9, x10
    tst x9, x9
    b.eq .Lfetch_choose
    mov x16, x21
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    mov x16, x9
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL registry_version_compare
    ARM_IMM w11, 0
    cmp w9, w11
    b.le .Lfetch_next
.Lfetch_choose:
    ARM_ADDR x16, registry_selected
    str x21, [x16]
.Lfetch_next:
    ARM_IMM x11, 64
    adds x21, x21, x11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lfetch_select
.Lfetch_selected:
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x9, x10
    add sp, sp, #16
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret

/* Terminal command: select exact or highest numeric version for package,
 * target and kind. Copy/download into the owned stage, check exact byte size,
 * run fixed sha256sum argv, then renameat2(RENAME_NOREPLACE). fetch retains
 * non-executable mode; install additionally validates ELF and sets 0755.
 * Existing outputs are retained on all failures.
 * The index authenticates no publisher; the digest check establishes integrity
 * relative to that selected index. Source archives remain opaque bytes. */
registry_fetch:
    ARM_CALL registry_select
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
    tst x19, x19
    b.eq registry_not_found
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 6
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lfetch_selection_ready
    ARM_CALL dependency_prepare_selection
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
.Lfetch_selection_ready:
    P_BYTE w10, registry_mode
    cmp w10, #5
    b.ne .Lp_registry_selection_ready
    ARM_CALL program_prepare_selection
.Lp_registry_selection_ready:
    mov x16, x19
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
    ARM_CALL registry_workspace
    ARM_ADDR x16, registry_local_artifact
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lfetch_local
    mov x16, x19
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_payload
    mov x1, x16
    mov x16, x19
    add x16, x16, #48
    ldr x10, [x16]
    mov x2, x10
    ARM_CALL registry_download
    tst w9, w9
    b.ne registry_download_error
    b .Lfetch_verify
.Lfetch_local:
    ARM_CALL registry_copy_local
.Lfetch_verify:
    ARM_CALL registry_verify_payload
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 6
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hs dependency_finish_add
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 5
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lfetch_default_output
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, registry_expected_size
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL validate_host_elf
    tst w9, w9
    b.eq registry_install_elf_error
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lfetch_output_ready
    ARM_CALL registry_install_output
    b .Lfetch_output_ready
.Lfetch_default_output:
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lfetch_output_ready
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    mov x16, x19
    ldr x10, [x16]
    mov x1, x10
.Loutput_package:
    mov x16, x1
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Loutput_version
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Loutput_package_char
    ARM_IMM w10, 45
    bfi x9, x10, #0, #8
.Loutput_package_char:
    and w10, w9, #255
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM x11, 1
    adds x1, x1, x11
    b .Loutput_package
.Loutput_version:
    ARM_IMM w10, 45
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    ARM_IMM w10, 45
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    add x16, x16, #1
    mov x0, x16
    mov x16, x19
    add x16, x16, #16
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_tar_suffix
    mov x1, x16
    mov x16, x19
    add x16, x16, #24
    ldr x10, [x16]
    mov x3, x10
    mov x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 115
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Loutput_suffix
    ARM_ADDR x16, registry_bin_suffix
    mov x1, x16
.Loutput_suffix:
    ARM_CALL copy_string
    ARM_ADDR x16, registry_default_output
    mov x9, x16
    ARM_ADDR x16, registry_output
    str x9, [x16]
.Lfetch_output_ready:
    P_BYTE w10, registry_mode
    cmp w10, #5
    b.ne .Lp_registry_original_output
    ARM_CALL program_commit_install
    b .Lp_registry_committed
.Lp_registry_original_output:
    /* Only the explicit install command grants execute permission. */
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_IMM w10, 420
    mov w1, w10
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 5
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lartifact_permissions
    ARM_IMM w10, 493
    mov w1, w10
.Lartifact_permissions:
    ARM_CALL arm_chmod
    tst x9, x9
    b.mi registry_io_error
    ARM_IMM x10, AT_FDCWD
    mov x0, x10
    ARM_ADDR x16, registry_temp_payload
    mov x1, x16
    ARM_IMM x10, AT_FDCWD
    mov x2, x10
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    mov x6, x10
    ARM_IMM w10, 1
    mov w4, w10
    ARM_CALL arm_renameat2
    tst x9, x9
    b.mi .Lfetch_output_error
.Lp_registry_committed:
    ARM_CALL registry_cleanup
    P_BYTE w10, registry_mode
    cmp w10, #5
    b.ne .Lp_registry_report
    P_BYTE w10, json_mode
    cbz w10, exit_ok
.Lp_registry_report:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lfetch_json
    ARM_ADDR x16, registry_fetched_text
    mov x0, x16
    ARM_ADDR x16, registry_mode
    ldrb w10, [x16]
    ARM_IMM w11, 5
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lartifact_report
    ARM_ADDR x16, registry_installed_text
    mov x0, x16
.Lartifact_report:
    ARM_CALL out
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL out
    ARM_ADDR x16, registry_verified_text
    mov x0, x16
    ARM_CALL out
    b exit_ok
.Lfetch_json:
    ARM_ADDR x16, registry_fetch_json_prefix
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, registry_output
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, registry_fetch_json_package
    mov x0, x16
    ARM_CALL out
    mov x16, x19
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, registry_fetch_json_version
    mov x0, x16
    ARM_CALL out
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, registry_fetch_json_suffix
    mov x0, x16
    ARM_CALL out
    b exit_ok
.Lfetch_output_error:
    ARM_ADDR x16, registry_err_output
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail
.Lsha_missing:
    ARM_ADDR x16, registry_err_sha
    mov x0, x16
    ARM_IMM w10, 127
    mov w1, w10
    b registry_fail
registry_integrity_error:
    ARM_ADDR x16, registry_err_integrity
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail

registry_install_target_error:
    ARM_ADDR x16, registry_err_install_target
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b registry_fail
registry_install_elf_error:
    ARM_ADDR x16, registry_err_elf
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b registry_fail

/* Input: selected registry row in x19; no explicit output was supplied.
 * Output: registry_output points to HOME/.local/bin/<unscoped package name>.
 * HOME is read, never changed. Requires an absolute HOME <=4000 bytes. Creates
 * only the two local/bin directories with the existing real-directory check.
 * Buffer capacity=4096. Caller still uses atomic no-overwrite finalization.
 * No PATH modification occurs. This does not make local directory races safe. */
registry_install_output:
    ARM_ADDR x16, envp
    ldr x10, [x16]
    mov x4, x10
.Linstall_env:
    mov x16, x4
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.eq .Linstall_home_error
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 72
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linstall_env_next
    mov x16, x0
    add x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 79
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linstall_env_next
    mov x16, x0
    add x16, x16, #2
    ldrb w10, [x16]
    ARM_IMM w11, 77
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linstall_env_next
    mov x16, x0
    add x16, x16, #3
    ldrb w10, [x16]
    ARM_IMM w11, 69
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linstall_env_next
    mov x16, x0
    add x16, x16, #4
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linstall_home
.Linstall_env_next:
    ARM_IMM x11, 8
    adds x4, x4, x11
    b .Linstall_env
.Linstall_home:
    ARM_IMM x11, 5
    adds x0, x0, x11
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Linstall_home_error
    ARM_SAVE x0
    ARM_CALL strlen
    ARM_RESTORE x1
    ARM_IMM x11, 4000
    cmp x9, x11
    b.hi .Linstall_home_error
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_local_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    ARM_CALL strlen
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    adds x0, x0, x9
    ARM_ADDR x16, registry_bin_dir_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    ARM_CALL make_safe_dir
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    ARM_CALL strlen
    ARM_ADDR x16, registry_default_output
    mov x0, x16
    adds x0, x0, x9
    ARM_IMM w10, 47
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    mov x16, x19
    ldr x10, [x16]
    mov x1, x10
.Linstall_name:
    mov x16, x1
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Linstall_name_start
    ARM_IMM x11, 1
    adds x1, x1, x11
    b .Linstall_name
.Linstall_name_start:
    ARM_IMM x11, 1
    adds x1, x1, x11
    ARM_CALL copy_string
    ARM_ADDR x16, registry_default_output
    mov x9, x16
    ARM_ADDR x16, registry_output
    str x9, [x16]
    ret
.Linstall_home_error:
    ARM_ADDR x16, registry_err_home
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b registry_fail

/* Input: registry_selected and expected_size describe the private payload.
 * Check its regular-file type and exact length, then run sha256sum with fixed
 * arguments. Returns only on success; failure cleans the private workspace.
 * Stack: 16 saved bytes. Each workspace has one exclusive checksum file. */
registry_verify_payload:
    ARM_SAVE x19
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne registry_io_error
    ARM_ADDR x16, registry_stat + ARM_STAT_SIZE
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, registry_expected_size
    ldr x11, [x16]
    cmp x9, x11
    b.ne registry_integrity_error
    ARM_ADDR x16, registry_checksum_contents
    mov x0, x16
    mov x16, x19
    add x16, x16, #32
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_two_spaces
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_temp_payload
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, registry_newline
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    ARM_ADDR x16, registry_checksum_contents
    mov x1, x16
    ARM_ADDR x16, registry_checksum_created
    mov x2, x16
    ARM_CALL create_exclusive_file
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_sha256sum
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_access
    tst x9, x9
    b.mi .Lsha_missing
    ARM_ADDR x16, registry_temp_checksum
    mov x9, x16
    ARM_ADDR x16, registry_sha_argv + 24
    str x9, [x16]
    ARM_ADDR x16, registry_sha256sum
    mov x0, x16
    ARM_ADDR x16, registry_sha_argv
    mov x1, x16
    ARM_CALL spawn_wait
    tst w9, w9
    b.ne registry_integrity_error
    ARM_RESTORE x19
    ret

/* Input: local_artifact path and expected_size <=64 MiB. Output: private payload
 * file, or fatal error. Opens a regular non-symlink input and exclusive output.
 * Retries short/interrupted reads and writes; checks both initial and copied
 * lengths. Owned copy buffer=65536 bytes. Stack: 48 saved bytes plus calls. */
registry_copy_local:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_ADDR x16, registry_local_artifact
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi registry_io_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, registry_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_stat + ARM_STAT_MODE
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne registry_io_error
    ARM_ADDR x16, registry_stat + ARM_STAT_SIZE
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, registry_expected_size
    ldr x11, [x16]
    cmp x9, x11
    b.ne registry_integrity_error
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + 193
    mov w1, w10
    ARM_IMM w10, 384
    mov w2, w10
    ARM_CALL arm_open
    tst x9, x9
    b.mi registry_io_error
    mov x22, x9
    eor w23, w23, w23
    tst w23, w23
.Lcopy_artifact_read:
    mov x0, x21
    ARM_ADDR x16, registry_copy_buffer
    mov x1, x16
    ARM_IMM w10, 65536
    mov w2, w10
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lcopy_artifact_read
    tst x9, x9
    b.mi registry_io_error
    b.eq .Lcopy_artifact_done
    adds x23, x23, x9
    ARM_ADDR x16, registry_expected_size
    ldr x11, [x16]
    cmp x23, x11
    b.hi registry_integrity_error
    mov x2, x9
    mov x0, x22
    ARM_ADDR x16, registry_copy_buffer
    mov x1, x16
    ARM_CALL write_all
    tst x9, x9
    b.mi registry_io_error
    b .Lcopy_artifact_read
.Lcopy_artifact_done:
    mov x0, x21
    ARM_CALL arm_close
    mov x0, x22
    ARM_CALL arm_close
    tst x9, x9
    b.mi registry_io_error
    ARM_ADDR x16, registry_expected_size
    ldr x11, [x16]
    cmp x23, x11
    b.ne registry_integrity_error
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret

/* Input: x0/x1=already validated numeric versions. Output: w9=-1, 0 or 1
 * for left less/equal/greater. Values are <=2147483647 per component, so the
 * decimal conversion cannot overflow. Read-only. Stack: none. */
registry_version_compare:
    eor w3, w3, w3
    tst w3, w3
    eor w2, w2, w2
    tst w2, w2
.Lcompare_component:
    eor w4, w4, w4
    tst w4, w4
    eor w5, w5, w5
    tst w5, w5
.Lcompare_left:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lcompare_right
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lcompare_right
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM x11, 10
    mul x4, x4, x11
    adds x4, x4, x9
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lcompare_left
.Lcompare_right:
    mov x16, x1
    add x16, x16, x2
    ldrb w10, [x16]
    mov w9, w10
    and w10, w9, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lcompare_values
    and w10, w9, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lcompare_values
    ARM_IMM w11, 48
    subs w9, w9, w11
    ARM_IMM x11, 10
    mul x5, x5, x11
    adds x5, x5, x9
    ARM_IMM w11, 1
    adds w2, w2, w11
    b .Lcompare_right
.Lcompare_values:
    cmp x4, x5
    b.hi .Lcompare_greater
    b.lo .Lcompare_less
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lcompare_equal
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM w11, 1
    adds w2, w2, w11
    b .Lcompare_component
.Lcompare_greater:
    ARM_IMM w10, 1
    mov w9, w10
    ret
.Lcompare_less:
    ARM_IMM w10, -1
    mov w9, w10
    ret
.Lcompare_equal:
    eor w9, w9, w9
    tst w9, w9
    ret

.section .rodata
registry_default_url: .asciz "https://asm.build/registry/v1/index.tsv"
registry_header: .asciz "# asm-registry-v1\n"
registry_host: .asciz "aarch64-linux"
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
    .ascii "fetch defaults to source and aarch64-linux. It verifies bytes and SHA-256.\n"
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
registry_stat: .skip ARM_STAT_BYTES
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
.section .note.GNU-stack,"",%progbits
