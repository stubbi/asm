/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Explicit, optional native registry V2 client. No V1 fallback.
 * Native AArch64 internal ABI: arguments x0-x7; result x9. Returning routines
 * preserve x19-x24. ARM_CALL preserves LR. Stack slots use 16-byte alignment.
 * x0-x7 are caller scratch; x8/x10-x17 and NZCV are scratch.
 * Routine stack counts exclude ARM_CALL frames and callees. No instruction interpreter is used.
 * All state is process-owned and serial. Bounds: control JSON 65536 bytes,
 * 15 unique objects, 64MiB/object, 128MiB/task, three mirrors, 4095-byte paths.
 * Mature fixed executables provide HTTPS, SHA256, gzip and TUF verification.
 * Assembly alone parses manifests, selects targets and changes local files.
 */
.equ R2_CONTROL, 65536
.equ R2_OBJECTS, 15
.equ R2_RECORD, 96
.equ R2_OBJECT_RECEIVED, 80
.equ R2_TASK_BYTES, 134217728
.section .text
cmd_registry_v2:
    ARM_IMM w10, 1
    ARM_ADDR x16, r2_active
    strb w10, [x16]
    ARM_CALL next_arg
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_arguments
    mov x21, x9
    ARM_ADDR x16, r2_commands
    mov x19, x16
.Lr2_command:
    mov x16, x19
    ldr x1, [x16]
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.eq r2_arguments
    mov x0, x21
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_command_found
    ARM_IMM x11, 16
    adds x19, x19, x11
    b .Lr2_command
.Lr2_command_found:
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x9, [x16]
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_help
    ARM_ADDR x16, r2_mode
    str x9, [x16]
    mov w10, w9
    ARM_IMM w11, 2
    cmp w10, w11
    b.lo .Lr2_options
    cmp w9, #5
    b.hs .Lr2_options
    ARM_CALL next_arg
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_arguments
    ARM_ADDR x16, r2_selector
    str x9, [x16]
.Lr2_options:
    ARM_CALL next_arg
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr2_options_done
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, registry_opt_json
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_json_option
    mov x0, x21
    ARM_ADDR x16, registry_opt_help
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_help
    mov x0, x21
    ARM_ADDR x16, r2_opt_mirror
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_mirror_option
    mov x0, x21
    ARM_CALL r2p_option
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_options
    ARM_ADDR x16, r2_options
    mov x19, x16
.Lr2_option:
    mov x16, x19
    ldr x1, [x16]
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.eq r2_arguments
    mov x0, x21
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_option_found
    ARM_IMM x11, 24
    adds x19, x19, x11
    b .Lr2_option
.Lr2_option_found:
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x9, [x16]
    ARM_ADDR x16, r2_fields
    ldr x10, [x16]
    mov x11, x9
    tst x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r2_fields
    ldr x10, [x16]
    mov x11, x9
    orr x10, x10, x11
    tst x10, x10
    ARM_ADDR x16, r2_fields
    str x10, [x16]
    ARM_CALL registry_arg_value
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x2, [x16]
    mov x16, x2
    str x9, [x16]
    b .Lr2_options
.Lr2_json_option:
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b .Lr2_options
.Lr2_mirror_option:
    ARM_ADDR x16, r2_mirror_count
    ldr x10, [x16]
    ARM_IMM x11, 3
    cmp x10, x11
    b.hs r2_arguments
    ARM_CALL registry_arg_value
    mov x21, x9
    mov x0, x9
    ARM_CALL r2_origin
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_mirror_count
    ldr x3, [x16]
    ARM_ADDR x16, r2_mirrors
    mov x2, x16
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x21, [x16]
    ARM_ADDR x16, r2_mirror_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r2_mirror_count
    str x10, [x16]
    b .Lr2_options
.Lr2_options_done:
    ARM_ADDR x16, r2_mode
    ldr x9, [x16]
    ARM_ADDR x16, r2_fields
    ldr x2, [x16]
    ARM_IMM x11, -257
    and x2, x2, x11
    tst x2, x2
    mov w10, w9
    ARM_IMM w11, 2
    cmp w9, #5
    b.hs r3_command
    cmp w10, w11
    b.hi r2_receive
    mov w10, w9
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq .Lr2_publish_fields
    mov x10, x2
    ARM_IMM x11, 12
    cmp x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r2_selector
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_task_id
    mov x0, x16
    ARM_ADDR x16, r2_selector
    ldr x1, [x16]
    ARM_CALL copy_string
    b .Lr2_auth_start
.Lr2_publish_fields:
    ARM_ADDR x16, r2p_project
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr2_prepared_fields
    ARM_CALL r2p_arguments
    b .Lr2_publish_key
.Lr2_prepared_fields:
    mov x10, x2
    ARM_IMM x11, 31
    cmp x10, x11
    b.ne r2_arguments
.Lr2_publish_key:
    ARM_ADDR x16, r2_key
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
.Lr2_auth_start:
    ARM_ADDR x16, r2_mirror_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r2_ca
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr2_auth_origin
    ARM_ADDR x16, r2_ca
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_IMM w9, 3
    ARM_CALL arm_close
.Lr2_auth_origin:
    ARM_ADDR x16, r2_api
    ldr x0, [x16]
    ARM_CALL r2_origin
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_CALL r2_workspace
    ARM_ADDR x16, r2p_project
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lr2_prepare_project
    ARM_CALL r2p_credential_identity
    b .Lr2_read_credential
.Lr2_prepare_project:
    ARM_CALL r2_project_prepare
.Lr2_read_credential:
    ARM_CALL r2_credential_header
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.eq r2_publish
    ARM_CALL r2_task_url
    ARM_ADDR x16, r2_method_get
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_CALL r2_http
    mov w10, w9
    ARM_IMM w11, 200
    cmp w10, w11
    b.ne r2_http_error
    ARM_CALL r2_parse_task
    b r2_report

r2_help:
    ARM_ADDR x16, r2_help_text
    mov x0, x16
    ARM_CALL out
    ARM_CALL registry_cleanup
    b exit_ok
r2_arguments:
    ARM_ADDR x16, r2_err_arguments
    mov x0, x16
    ARM_IMM w1, 2
    b registry_fail
r2_invalid:
    ARM_ADDR x16, r3_active
    ldrb w10, [x16]
    cbnz w10, r3_metadata_error
    ARM_ADDR x16, r2_post_attempted
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_invalid_after_post
    ARM_ADDR x16, r2p_project
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r2p_bad
    ARM_ADDR x16, r2_err_manifest
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
.Lr2_invalid_after_post:
    ARM_ADDR x16, r2_err_http
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
r2_io:
    ARM_ADDR x16, r2_post_attempted
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_invalid_after_post
    ARM_ADDR x16, r2_err_io
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
r2_trust_error:
    ARM_ADDR x16, r3_active
    ldrb w10, [x16]
    cbnz w10, r3_metadata_error
    ARM_ADDR x16, r2_err_trust
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
r2_http_error:
    mov w10, w9
    ARM_IMM w11, 401
    cmp w10, w11
    b.eq .Lr2_credential_refused
    mov w10, w9
    ARM_IMM w11, 403
    cmp w10, w11
    b.eq .Lr2_scope_refused
    mov w10, w9
    ARM_IMM w11, 410
    cmp w10, w11
    b.eq .Lr2_upload_expired
    ARM_ADDR x16, r2_err_http
    mov x0, x16
    b .Lr2_http_die
.Lr2_credential_refused:
    ARM_ADDR x16, r2_err_credential
    mov x0, x16
    b .Lr2_http_die
.Lr2_scope_refused:
    ARM_ADDR x16, r2_err_scope
    mov x0, x16
    b .Lr2_http_die
.Lr2_upload_expired:
    ARM_ADDR x16, r2_err_expired
    mov x0, x16
.Lr2_http_die:
    ARM_IMM w1, 1
    b registry_fail
r2_legacy_upgrade:
    ARM_ADDR x16, r2_err_upgrade
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail

/* x0=NUL string, w1=exact lowercase hex length. w9=1/0. No stack. */
r2_hex:
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2_hex_byte:
    mov w10, w3
    mov w11, w1
    cmp w10, w11
    b.hs .Lr2_hex_end
    mov x16, x0
    add x16, x16, x3
    ldrb w9, [x16]
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lr2_no
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lr2_hex_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lr2_no
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 102
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lr2_no
.Lr2_hex_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2_hex_byte
.Lr2_hex_end:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_no
    ARM_IMM w9, 1
    ret
.Lr2_no:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret

/* Strict explicit HTTPS base, <=2048 bytes. No query, fragment, escaping,
 * credentials, backslash, trailing slash, empty or dot path components.
 * Input/output x0 unchanged; w9=1/0; Stack 32. */
r2_origin:
    ARM_SAVE x19
    ARM_SAVE x21
    mov x21, x0
    ARM_CALL strlen
    mov x10, x9
    ARM_IMM x11, 9
    cmp x10, x11
    b.lo .Lr2_origin_bad
    mov x10, x9
    ARM_IMM x11, 2048
    cmp x10, x11
    b.hi .Lr2_origin_bad
    mov x16, x21
    add x16, x16, x9
    ARM_IMM x17, 1
    sub x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_origin_bad
    mov x0, x21
    ARM_CALL registry_https_url
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_origin_bad
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    mov x19, x16
    mov x2, x19
.Lr2_origin_byte:
    mov x16, x19
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lr2_origin_segment
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 63
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_origin_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 35
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_origin_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 37
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_origin_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_origin_next
    ARM_CALL .Lr2_origin_segment_check
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_origin_bad
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x2, x16
.Lr2_origin_next:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr2_origin_byte
.Lr2_origin_segment:
    ARM_CALL .Lr2_origin_segment_check
    b .Lr2_origin_return
.Lr2_origin_segment_check:
    mov x10, x2
    mov x11, x19
    cmp x10, x11
    b.eq .Lr2_no
    mov x16, x2
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_origin_segment_ok
    mov x16, x2
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x9, x16
    mov x10, x9
    mov x11, x19
    cmp x10, x11
    b.eq .Lr2_no
    mov x16, x2
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_origin_segment_ok
    ARM_IMM x11, 1
    adds x9, x9, x11
    mov x10, x9
    mov x11, x19
    cmp x10, x11
    b.eq .Lr2_no
.Lr2_origin_segment_ok:
    ARM_IMM w9, 1
    ret
.Lr2_origin_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2_origin_return:
    mov x0, x21
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Open a caller path with descriptor-relative no-follow traversal. x0=path
 * <=4095; w1=0 regular,1 directory; w2=1 additionally requires a private
 * credential file. Every directory is root/user-owned and not group/world
 * writable, except root-owned sticky directories. Darwin fstat refuses ACL
 * grants through the existing adapter. Result FD or fatal controlled error.
 * Preserves callee registers; path buffer4096, stat144; local Stack 96. */
r2_open_path:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov w21, w1
    mov w22, w2
    ARM_CALL strlen
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_io
    mov x10, x9
    ARM_IMM x11, 4095
    cmp x10, x11
    b.hi r2_io
    mov x1, x0
    ARM_ADDR x16, r2_path
    mov x0, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_path
    mov x23, x16
    ARM_ADDR x16, pub_dot
    mov x0, x16
    mov x16, x23
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_open_start
    ARM_ADDR x16, self_root
    mov x0, x16
    ARM_IMM x11, 1
    adds x23, x23, x11
.Lr2_open_start:
    ARM_IMM w9, 2
    ARM_IMM w1, O_NOFOLLOW + O_CLOEXEC + O_DIRECTORY
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x24, x9
    ARM_CALL r2_directory_stat
.Lr2_walk_segment:
    mov x19, x23
.Lr2_walk_scan:
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_walk_last
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_walk_directory
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr2_walk_scan
.Lr2_walk_directory:
    mov x10, x19
    mov x11, x23
    cmp x10, x11
    b.eq r2_io
    ARM_IMM w10, 0
    mov x16, x19
    strb w10, [x16]
    mov x0, x23
    ARM_CALL r2_component
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    ARM_IMM w9, 257
    mov x0, x24
    mov x1, x23
    ARM_IMM w2, O_NOFOLLOW + O_CLOEXEC + O_DIRECTORY
    mov w11, w6
    eor w6, w6, w11
    tst w6, w6
    ARM_CALL arm_openat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x20, x9
    ARM_IMM w9, 3
    mov x0, x24
    ARM_CALL arm_close
    mov x24, x20
    ARM_CALL r2_directory_stat
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x23, x16
    b .Lr2_walk_segment
.Lr2_walk_last:
    mov x10, x19
    mov x11, x23
    cmp x10, x11
    b.eq r2_io
    mov x0, x23
    ARM_CALL r2_component
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    ARM_IMM w9, 257
    mov x0, x24
    mov x1, x23
    ARM_IMM w2, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w10, w21
    mov w11, w21
    tst w10, w11
    b.eq .Lr2_walk_flags
    ARM_IMM w11, O_DIRECTORY
    orr w2, w2, w11
    tst w2, w2
.Lr2_walk_flags:
    mov w11, w6
    eor w6, w6, w11
    tst w6, w6
    ARM_CALL arm_openat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x20, x9
    ARM_IMM w9, 3
    mov x0, x24
    ARM_CALL arm_close
    ARM_IMM w9, 5
    mov x0, x20
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_stat + 16
    ldr w9, [x16]
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w2, 32768
    mov w10, w21
    mov w11, w21
    tst w10, w11
    b.eq .Lr2_walk_kind
    ARM_IMM w2, 16384
.Lr2_walk_kind:
    mov w10, w9
    mov w11, w2
    cmp w10, w11
    b.ne r2_io
    mov w10, w21
    mov w11, w21
    tst w10, w11
    b.eq .Lr2_walk_private
    mov x24, x20
    ARM_CALL r2_directory_stat
.Lr2_walk_private:
    mov w10, w22
    mov w11, w22
    tst w10, w11
    b.eq .Lr2_walk_ok
    ARM_ADDR x16, r2_stat + 20
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne r2_io
    ARM_IMM w9, 102
    ARM_CALL arm_getuid
    mov w10, w9
    ARM_ADDR x16, r2_stat + 24
    ldr w11, [x16]
    cmp w10, w11
    b.eq .Lr2_private_owner
    mov w10, w22
    ARM_IMM w11, 2
    cmp w10, w11
    b.ne r2_io
    ARM_ADDR x16, r2_stat + 24
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne r2_io
.Lr2_private_owner:
    mov w10, w22
    ARM_IMM w11, 2
    cmp w10, w11
    b.ne .Lr2_private_mode
    ARM_ADDR x16, r2_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 18
    tst w10, w11
    b.ne r2_io
    b .Lr2_walk_ok
.Lr2_private_mode:
    ARM_ADDR x16, r2_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 127
    tst w10, w11
    b.ne r2_io
.Lr2_walk_ok:
    mov x9, x20
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
r2_component:
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x002e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2_no
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x2e2e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lr2_component_ok
    mov x16, x0
    ARM_IMM x17, 2
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_no
.Lr2_component_ok:
    ARM_IMM w9, 1
    ret
/* x24=directory FD; r2_path contains the traversal. Only directory ownership
 * checks. Root-owned sticky temporary directories are allowed; a private
 * descendant is still required for all outputs. Stack 16. */
r2_directory_stat:
    sub sp, sp, #16
    ARM_IMM w9, 5
    mov x0, x24
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM w9, 102
    ARM_CALL arm_getuid
    ARM_ADDR x16, r2_stat + 24
    ldr w2, [x16]
    mov w10, w9
    mov w11, w2
    cmp w10, w11
    b.eq .Lr2_dir_mode
    mov w10, w2
    mov w11, w2
    tst w10, w11
    b.ne r2_io
.Lr2_dir_mode:
    ARM_ADDR x16, r2_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 18
    tst w10, w11
    b.eq .Lr2_dir_ok
    mov w10, w2
    mov w11, w2
    tst w10, w11
    b.ne r2_io
    ARM_ADDR x16, r2_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 512
    tst w10, w11
    b.eq r2_io
.Lr2_dir_ok:
    add sp, sp, #16
    ret

/* Input FD x0, output x1[capacity+1], x2=capacity. w9=length. Retains no
 * input FD; reads one extra byte to reject growth, handles EINTR/short reads.
 * Buffer belongs to caller; saved Stack 64. */
r2_read_fd:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x21, x0
    mov x22, x1
    mov x23, x2
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_read:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov x0, x21
    mov x16, x22
    add x16, x16, x19
    mov x1, x16
    mov x16, x23
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x2, x16
    mov x11, x19
    subs x2, x2, x11
    ARM_CALL arm_read
    mov x10, x9
    ARM_IMM x11, -4
    cmp x10, x11
    b.eq .Lr2_read
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    b.eq .Lr2_read_done
    mov x11, x9
    adds x19, x19, x11
    mov x10, x19
    mov x11, x23
    cmp x10, x11
    b.hi r2_invalid
    b .Lr2_read
.Lr2_read_done:
    ARM_IMM w9, 3
    mov x0, x21
    ARM_CALL arm_close
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM w10, 0
    mov x16, x22
    add x16, x16, x19
    strb w10, [x16]
    mov x9, x19
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Require a protected current directory before creating the existing private
 * stage. Directory is traversed from its canonical absolute pathname. */
r2_workspace:
    sub sp, sp, #16
    ARM_IMM w9, 79
    ARM_ADDR x16, r2_cwd
    mov x0, x16
    ARM_IMM w1, 4096
    ARM_CALL arm_getcwd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_cwd
    mov x0, x16
    ARM_CALL strlen
    mov x10, x9
    ARM_IMM x11, 3900
    cmp x10, x11
    b.hi r2_io
    ARM_ADDR x16, r2_cwd
    mov x0, x16
    ARM_IMM w1, 1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_IMM w9, 3
    ARM_CALL arm_close
    ARM_CALL registry_workspace
    ARM_ADDR x16, r2_header_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_header_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_helper_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_helper_suffix
    mov x1, x16
    ARM_CALL copy_string
    add sp, sp, #16
    ret

/* Read one exact token (optional final LF) from a private file. Write a private
 * fixed header file; the secret never appears in argv or child environment. */
r2_credential_header:
    sub sp, sp, #16
    ARM_ADDR x16, r2_credential
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 1
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_token
    mov x1, x16
    ARM_IMM w2, 76
    ARM_CALL r2_read_fd
    mov w10, w9
    ARM_IMM w11, 76
    cmp w10, w11
    b.ne .Lr2_token_size
    ARM_ADDR x16, r2_token + 75
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_io
    ARM_IMM w10, 0
    ARM_ADDR x16, r2_token + 75
    strb w10, [x16]
    ARM_IMM w11, 1
    subs w9, w9, w11
.Lr2_token_size:
    mov w10, w9
    ARM_IMM w11, 75
    cmp w10, w11
    b.ne r2_io
    ARM_ADDR x16, r2_token
    mov x0, x16
    ARM_ADDR x16, r2_token_prefix
    mov x1, x16
    ARM_CALL self_prefix
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_io
    mov x0, x9
    ARM_IMM w1, 64
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    ARM_ADDR x16, r2_header
    mov x0, x16
    ARM_ADDR x16, r2_authorization
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_token
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 10
    mov x16, x9
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x9, x9, x11
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lr2_header_end
    mov x0, x9
    ARM_ADDR x16, r2_idempotency
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_key
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_IMM w10, 10
    mov x16, x9
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x9, x9, x11
.Lr2_header_end:
    ARM_ADDR x16, r2_header
    mov x1, x16
    mov x11, x1
    subs x9, x9, x11
    mov x2, x9
    ARM_ADDR x16, r2_header_path
    mov x0, x16
    ARM_CALL r2_write_file
    ARM_ADDR x16, r2_token
    mov x0, x16
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_IMM w3, 78
    cbz x3, .Lr2_arm_copy_1_end
.Lr2_arm_copy_1:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2_arm_copy_1
.Lr2_arm_copy_1_end:
    ARM_ADDR x16, r2_header
    mov x0, x16
    ARM_IMM w3, 256
    cbz x3, .Lr2_arm_copy_2_end
.Lr2_arm_copy_2:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2_arm_copy_2
.Lr2_arm_copy_2_end:
    add sp, sp, #16
    ret

/* Exclusive0600 regular file. x0=owned path, x1=bytes, x2=length<=64MiB.
 * w9=0 success; controlled fatal on failure. Stack 64; write_all retries. */
r2_write_file:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x21, x1
    mov x22, x2
    ARM_IMM w9, 2
    ARM_IMM w1, O_NOFOLLOW + O_CLOEXEC + 193
    ARM_IMM w2, 384
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x23, x9
    mov x0, x9
    mov x1, x21
    mov x2, x22
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM w9, 3
    mov x0, x23
    ARM_CALL arm_close
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Fixed child invocation. x0=executable, x1=argv. Child stdout is a private
 * pipe, stderr /dev/null, stdin /dev/null, environment empty. Capture <=4bytes
 * (curl status only; verifier must emit nothing). Child alarm120s, reset mask
 * and disposition. Parent bounds capture and reaps every child. Stack 112. */
r2_child:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov x21, x0
    mov x22, x1
    ARM_IMM w9, 293
    ARM_ADDR x16, r2_pipe
    mov x0, x16
    ARM_IMM w1, O_CLOEXEC
    ARM_CALL arm_pipe2
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_pipe
    ldr w0, [x16]
    ARM_CALL arc_promote_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_pipe
    str w9, [x16]
    ARM_ADDR x16, r2_pipe + 4
    ldr w0, [x16]
    ARM_CALL arc_promote_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_pipe + 4
    str w9, [x16]
    ARM_IMM w9, 57
    ARM_CALL arm_fork
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    b.eq .Lr2_child_process
    mov x23, x9
    ARM_IMM w9, 3
    ARM_ADDR x16, r2_pipe + 4
    ldr w0, [x16]
    ARM_CALL arm_close
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr2_child_read:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_ADDR x16, r2_pipe
    ldr w0, [x16]
    ARM_ADDR x16, r2_status
    mov x1, x16
    mov x11, x24
    adds x1, x1, x11
    ARM_IMM w2, 5
    mov x11, x24
    subs x2, x2, x11
    ARM_CALL arm_read
    mov x10, x9
    ARM_IMM x11, -4
    cmp x10, x11
    b.eq .Lr2_child_read
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_kill
    b.eq .Lr2_child_reap
    mov x11, x9
    adds x24, x24, x11
    mov x10, x24
    ARM_IMM x11, 4
    cmp x10, x11
    b.hi .Lr2_child_kill
    b .Lr2_child_read
.Lr2_child_kill:
    ARM_IMM w20, 1
    ARM_IMM w9, 62
    mov x0, x23
    ARM_IMM w1, 9
    ARM_CALL arm_kill
.Lr2_child_reap:
    ARM_IMM w9, 3
    ARM_ADDR x16, r2_pipe
    ldr w0, [x16]
    ARM_CALL arm_close
.Lr2_child_wait:
    ARM_IMM w9, 61
    mov x0, x23
    ARM_ADDR x16, r2_child_status
    mov x1, x16
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    mov w11, w6
    eor w6, w6, w11
    tst w6, w6
    ARM_CALL arm_wait4
    mov x10, x9
    ARM_IMM x11, -4
    cmp x10, x11
    b.eq .Lr2_child_wait
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_status_length
    str x24, [x16]
    ARM_ADDR x16, r2_child_status
    ldr w9, [x16]
    mov w10, w20
    mov w11, w20
    tst w10, w11
    b.eq .Lr2_child_return
    ARM_IMM w9, 1
.Lr2_child_return:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.Lr2_child_process:
    ARM_IMM w9, 2
    ARM_ADDR x16, self_dev_null
    mov x0, x16
    ARM_IMM w1, 2
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_abort
    mov x19, x9
    ARM_IMM w9, 33
    mov x0, x19
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_CALL arm_dup2
    ARM_IMM w9, 33
    mov x0, x19
    ARM_IMM w1, 2
    ARM_CALL arm_dup2
    ARM_IMM w9, 33
    ARM_ADDR x16, r2_pipe + 4
    ldr w0, [x16]
    ARM_IMM w1, 1
    ARM_CALL arm_dup2
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_abort
    ARM_IMM w9, 13
    ARM_IMM w0, 14
    ARM_ADDR x16, self_default_signal
    mov x1, x16
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_IMM w6, 8
    ARM_CALL arm_rt_sigaction
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_abort
    ARM_IMM w9, 14
    ARM_IMM w0, 1
    ARM_ADDR x16, self_alarm_signal_mask
    mov x1, x16
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_IMM w6, 8
    ARM_CALL arm_rt_sigprocmask
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_abort
    ARM_IMM w9, 37
    ARM_IMM w0, 120
    ARM_CALL arm_alarm
    /* Bound every child output file independently of declared HTTP length. */
    ARM_IMM w9, 97
    ARM_IMM w0, 1
    ARM_ADDR x16, r2_rlimit
    mov x1, x16
    ARM_CALL arm_getrlimit
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_abort
    ARM_ADDR x16, r2_child_file_limit
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2_rlimit
    ldr x11, [x16]
    cmp x10, x11
    ARM_ADDR x16, r2_rlimit
    ldr x11, [x16]
    csel x9, x11, x9, hi
    ARM_ADDR x16, r2_rlimit
    str x9, [x16]
    ARM_ADDR x16, r2_child_file_limit
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2_rlimit + 8
    ldr x11, [x16]
    cmp x10, x11
    ARM_ADDR x16, r2_rlimit + 8
    ldr x11, [x16]
    csel x9, x11, x9, hi
    ARM_ADDR x16, r2_rlimit + 8
    str x9, [x16]
    ARM_IMM w9, 160
    ARM_IMM w0, 1
    ARM_ADDR x16, r2_rlimit
    mov x1, x16
    ARM_CALL arm_setrlimit
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_child_abort
    ARM_IMM w9, 59
    mov x0, x21
    mov x1, x22
    ARM_ADDR x16, arc_empty_env
    mov x2, x16
    ARM_CALL arm_execve
.Lr2_child_abort:
    ARM_IMM w0, 127
    ARM_IMM w9, 60
    ARM_CALL arm_exit
    brk #0

/* x0=GET/POST/PUT, x1=owned bodypath or0. r2_url is validated/derived.
 * w9=HTTP status or0. No redirects, config, netrc, cookies or ambient trust.
 * Body output <=65536, length/regularity checked before JSON parsing. */
r2_http:
    ARM_SAVE x19
    ARM_SAVE x21
    mov x21, x1
    ARM_ADDR x16, r2_http_method
    str x0, [x16]
    ARM_IMM w9, 87
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, r2_http_argv
    mov x19, x16
    ARM_ADDR x16, registry_curl
    mov x9, x16
    mov x16, x19
    str x9, [x16]
    ARM_ADDR x16, registry_curl_disable
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_silent
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_proto
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 24
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_https
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_connect_timeout
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 40
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_fifteen
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 48
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_max_time
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 56
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_seconds
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 64
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_max_filesize
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 72
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_control_decimal
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 80
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_output
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 88
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_temp_index
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 96
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_write_out
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 104
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_status_format
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 112
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_request
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 120
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_http_method
    ldr x9, [x16]
    mov x16, x19
    ARM_IMM x17, 128
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_header_option
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 136
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_header_argument
    mov x0, x16
    ARM_IMM w10, 64
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_ADDR x16, r2_header_path
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_header_argument
    mov x9, x16
    mov x16, x19
    ARM_IMM x17, 144
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM w19, 19
    mov x10, x21
    mov x11, x21
    tst x10, x11
    b.eq .Lr2_http_ca
    ARM_ADDR x16, r2_body_argument
    mov x0, x16
    ARM_IMM w10, 64
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    mov x1, x21
    ARM_CALL copy_string
    ARM_ADDR x16, r2_http_method
    ldr x9, [x16]
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 80
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_http_error
    ARM_ADDR x16, r2_content_json
    mov x9, x16
    ARM_ADDR x16, r2_http_method
    ldr x2, [x16]
    mov x16, x2
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 85
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_http_post
    ARM_ADDR x16, r2_content_blob
    mov x9, x16
.Lr2_http_post:
    ARM_ADDR x16, r2_http_argv
    mov x2, x16
    ARM_ADDR x16, r2_header_option
    mov x3, x16
    mov x16, x2
    ARM_IMM x17, 19*8
    add x16, x16, x17
    str x3, [x16]
    mov x16, x2
    ARM_IMM x17, 20*8
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_data_binary
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 21*8
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_body_argument
    mov x9, x16
    ARM_ADDR x16, r2_http_method
    ldr x3, [x16]
    mov x16, x3
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 85
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_http_body_ready
    ARM_ADDR x16, r2_upload_file
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 21*8
    add x16, x16, x17
    str x9, [x16]
    mov x9, x21
.Lr2_http_body_ready:
    mov x16, x2
    ARM_IMM x17, 22*8
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM w19, 23
.Lr2_http_ca:
    ARM_ADDR x16, r2_ca
    ldr x9, [x16]
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr2_http_end
    ARM_ADDR x16, r2_http_argv
    mov x2, x16
    ARM_ADDR x16, r2_ca_option
    mov x3, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x3, [x16]
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w19, w19, w11
.Lr2_http_end:
    ARM_ADDR x16, r2_http_argv
    mov x2, x16
    ARM_ADDR x16, registry_separator
    mov x9, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w19, w19, w11
    ARM_ADDR x16, r2_url
    mov x9, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w19, w19, w11
    ARM_IMM x10, 0
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x10, [x16]
    ARM_IMM x10, R2_CONTROL
    ARM_ADDR x16, r2_child_file_limit
    str x10, [x16]
    ARM_ADDR x16, registry_curl
    mov x0, x16
    ARM_ADDR x16, r2_http_argv
    mov x1, x16
    ARM_CALL r2_child
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_http_fail
    ARM_ADDR x16, r2_status_length
    ldr x10, [x16]
    ARM_IMM x11, 3
    cmp x10, x11
    b.ne .Lr2_http_fail
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2_status_digit:
    ARM_ADDR x16, r2_status
    mov x2, x16
    mov x16, x2
    add x16, x16, x3
    ldrb w9, [x16]
    ARM_IMM w11, 48
    subs w9, w9, w11
    mov w10, w9
    ARM_IMM w11, 9
    cmp w10, w11
    b.hi .Lr2_http_fail
    mov w10, w19
    ARM_IMM w11, 10
    mul w19, w10, w11
    mov w11, w9
    adds w19, w19, w11
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 3
    cmp w10, w11
    b.lo .Lr2_status_digit
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_response
    mov x1, x16
    ARM_IMM w2, R2_CONTROL
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r2_response_length
    str x9, [x16]
    mov w9, w19
    b .Lr2_http_return
.Lr2_http_fail:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2_http_return:
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Appends are bounded by derived paths: HTTPS2048 + fixed routes<256. */
r2_task_url:
    sub sp, sp, #16
    ARM_ADDR x16, r2_url
    mov x0, x16
    ARM_ADDR x16, r2_api
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_publications_path
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_task_id
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_task_url_done
    ARM_IMM w10, 47
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_task_id
    mov x1, x16
    ARM_CALL copy_string
.Lr2_task_url_done:
    add sp, sp, #16
    ret

/* Shared strict tokenizer. Bytes remain read-only. x0=data, x1<=65536.
 * Unknown/duplicate/escaped keys are rejected by smp_value. Returns token0.
 * V2 schema routines enforce field sets and plain identity values. */
r2_parse_json:
    sub sp, sp, #16
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.eq r2_invalid
    mov x10, x1
    ARM_IMM x11, INDEX_LIMIT
    cmp x10, x11
    b.hi r2_invalid
    ARM_ADDR x16, smp_cursor
    str x0, [x16]
    mov x11, x0
    adds x1, x1, x11
    ARM_ADDR x16, smp_end
    str x1, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, smp_token_count
    str x10, [x16]
    ARM_IMM w0, 1
    ARM_CALL smp_value
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_invalid
    ARM_CALL smp_space
    ARM_ADDR x16, smp_cursor
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, smp_end
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_OBJECT
    cmp x10, x11
    b.ne r2_invalid
    add sp, sp, #16
    ret

/* x0=object token; x1=key. x9=value token or0; Stack 64. */
r2_member:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x21, x0
    mov x22, x1
    mov x16, x21
    ldr x10, [x16]
    ARM_IMM x11, SMP_OBJECT
    cmp x10, x11
    b.ne .Lr2_member_none
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x21
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x19, x16
.Lr2_member_next:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x19
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x11, x23
    cmp x10, x11
    b.hs .Lr2_member_none
    mov x0, x19
    mov x1, x22
    ARM_CALL smp_token_text_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_member_found
    mov x16, x19
    ARM_IMM x17, 32
    add x16, x16, x17
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    b .Lr2_member_next
.Lr2_member_found:
    mov x16, x19
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x9, x16
    b .Lr2_member_return
.Lr2_member_none:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2_member_return:
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
r2_required:
    sub sp, sp, #16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_invalid
    add sp, sp, #16
    ret

.macro R2_GET object, key
    mov x0, \object
    ARM_ADDR x16, r2_k_\key
    mov x1, x16
    ARM_CALL r2_required
.endm

/* x0=number token, x1=upper bound. x9=positive canonical decimal value.
 * Reject exponent/fraction/negative/leading zero. No stack. */
r2_number:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_NUMBER
    cmp x10, x11
    b.ne r2_invalid
    mov x16, x0
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x3, [x16]
    mov x10, x3
    mov x11, x3
    tst x10, x11
    b.eq r2_invalid
    mov x10, x3
    ARM_IMM x11, 10
    cmp x10, x11
    b.hi r2_invalid
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2_invalid
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
.Lr2_number_digit:
    mov x10, x4
    mov x11, x3
    cmp x10, x11
    b.hs .Lr2_number_end
    mov x16, x0
    add x16, x16, x4
    ldrb w2, [x16]
    ARM_IMM w11, 48
    subs w2, w2, w11
    mov w10, w2
    ARM_IMM w11, 9
    cmp w10, w11
    b.hi r2_invalid
    mov x10, x9
    ARM_IMM x11, 10
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x11, x2
    adds x9, x9, x11
    mov x10, x9
    mov x11, x1
    cmp x10, x11
    b.hi r2_invalid
    ARM_IMM x11, 1
    adds x4, x4, x11
    b .Lr2_number_digit
.Lr2_number_end:
    ret
r2_schema:
    ARM_IMM w1, 2
    ARM_CALL r2_number
    mov w10, w9
    ARM_IMM w11, 2
    cmp w10, w11
    b.ne r2_invalid
    ret

/* Plain token hex -> owned buffer. x0 token, x1 buffer, w2 hex length.
 * Uses r2_string and r2_hex; Stack 48. */
r2_hex_token:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x1
    mov w22, w2
    ARM_IMM w11, 1
    adds w2, w2, w11
    ARM_CALL r2_string
    mov x0, x21
    mov w1, w22
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Decode canonical printable ASCII text. Only quote/backslash escapes are
 * permitted. x0=string token; x1=dest; w2=capacity. x9=decoded length.
 * Caller checks semantic bounds; Stack 0, destination owns decoded text. */
r2_text:
    mov x16, x0
    ldr x9, [x16]
    ARM_IMM w11, -257
    and w9, w9, w11
    tst w9, w9
    mov w10, w9
    ARM_IMM w11, SMP_STRING
    cmp w10, w11
    b.ne r2_invalid
    mov x16, x0
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x3, [x16]
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
    mov w11, w5
    eor w5, w5, w11
    tst w5, w5
.Lr2_text_byte:
    mov x10, x4
    mov x11, x3
    cmp x10, x11
    b.hs .Lr2_text_end
    mov x16, x0
    add x16, x16, x4
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    ARM_IMM x11, 1
    adds x4, x4, x11
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_text_plain
    mov x10, x4
    mov x11, x3
    cmp x10, x11
    b.hs r2_invalid
    mov x16, x0
    add x16, x16, x4
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    ARM_IMM x11, 1
    adds x4, x4, x11
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 92
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_text_plain
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 34
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_invalid
.Lr2_text_plain:
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo r2_invalid
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi r2_invalid
    ARM_IMM x11, 1
    adds x5, x5, x11
    mov x10, x5
    mov x11, x2
    cmp x10, x11
    b.hs r2_invalid
    mov x16, x1
    add x16, x16, x5
    ARM_IMM x17, 1
    sub x16, x16, x17
    strb w9, [x16]
    b .Lr2_text_byte
.Lr2_text_end:
    ARM_IMM w10, 0
    mov x16, x1
    add x16, x16, x5
    strb w10, [x16]
    mov x9, x5
    ret

/* Full closed V2 publication schema. x0=root object. Owns name/version,
 * source declaration, artifact selection and deduplicated object table.
 * Every tuple is explicit; no CPU extension or unknown field is accepted.
 * Maximum14 selections/15 unique objects. Stack 96 plus bounded JSON lexer. */
r2_validate_manifest:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    ARM_ADDR x16, r2_fields_manifest
    mov x1, x16
    ARM_IMM w2, 8
    ARM_IMM w3, 9
    ARM_CALL r2_keys
    mov x0, x21
    ARM_CALL g3_manifest_dependencies
    R2_GET x21, schema
    mov x0, x9
    ARM_CALL r2_schema
    R2_GET x21, name
    mov x0, x9
    ARM_ADDR x16, r2_name
    mov x1, x16
    ARM_IMM w2, 105
    ARM_CALL r2_string
    ARM_ADDR x16, r2_name
    mov x0, x16
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    R2_GET x21, version
    mov x0, x9
    ARM_ADDR x16, r2_version
    mov x1, x16
    ARM_IMM w2, 33
    ARM_CALL r2_string
    ARM_ADDR x16, r2_version
    mov x0, x16
    ARM_CALL registry_valid_version
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    R2_GET x21, owner_id
    mov x0, x9
    ARM_ADDR x16, r2_owner_id
    mov x1, x16
    ARM_IMM w2, 32
    ARM_CALL r2_hex_token
    R2_GET x21, summary
    mov x0, x9
    ARM_ADDR x16, r2_summary
    mov x1, x16
    ARM_IMM w2, 161
    ARM_CALL r2_text
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_invalid
    ARM_ADDR x16, r2_summary
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2_invalid
    ARM_ADDR x16, r2_summary
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 1
    sub x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2_invalid
    R2_GET x21, license
    mov x0, x9
    ARM_ADDR x16, r2_license
    mov x1, x16
    ARM_IMM w2, 64
    ARM_CALL r2_string
    ARM_ADDR x16, r2_license
    mov x0, x16
    ARM_ADDR x16, pub_licenses
    mov x1, x16
    ARM_CALL pub_in_strings
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    R2_GET x21, source
    mov x22, x9
    mov x0, x9
    ARM_ADDR x16, r2_fields_source
    mov x1, x16
    ARM_IMM w2, 3
    ARM_IMM w3, 4
    ARM_CALL r2_keys
    R2_GET x22, path
    mov x0, x9
    ARM_ADDR x16, r2_source_path
    mov x1, x16
    ARM_IMM w2, 241
    ARM_CALL r2_string
    ARM_ADDR x16, r2_source_path
    mov x0, x16
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x002e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2_source_path_ok
    ARM_CALL pub_portable_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_invalid
.Lr2_source_path_ok:
    ARM_ADDR x16, r2_source_path
    mov x9, x16
    ARM_ADDR x16, pub_source_path
    str x9, [x16]
    mov x0, x22
    ARM_ADDR x16, r2_k_repository
    mov x1, x16
    ARM_CALL r2_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr2_source_commit
    mov x0, x9
    ARM_ADDR x16, r2_repository
    mov x1, x16
    ARM_IMM w2, 1025
    ARM_CALL r2_string
    ARM_ADDR x16, r2_repository
    mov x0, x16
    ARM_CALL r2_repository_locator
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
.Lr2_source_commit:
    R2_GET x22, commit
    mov x23, x9
    mov x0, x9
    ARM_ADDR x16, r2_fields_commit
    mov x1, x16
    ARM_IMM w2, 2
    ARM_IMM w3, 2
    ARM_CALL r2_keys
    R2_GET x23, algorithm
    mov x0, x9
    ARM_ADDR x16, r2_git_sha1
    mov x1, x16
    ARM_CALL smp_plain_equal
    ARM_IMM w20, 40
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_commit_digest
    R2_GET x23, algorithm
    mov x0, x9
    ARM_ADDR x16, r2_git_sha256
    mov x1, x16
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    ARM_IMM w20, 64
.Lr2_commit_digest:
    R2_GET x23, digest
    mov x0, x9
    ARM_ADDR x16, r2_commit
    mov x1, x16
    mov w2, w20
    ARM_CALL r2_hex_token
    ARM_ADDR x16, r2_commit
    mov x0, x16
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2_commit_nonzero:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_commit_ok
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    mov w11, w20
    cmp w10, w11
    b.lo .Lr2_commit_nonzero
    b r2_invalid
.Lr2_commit_ok:
    R2_GET x22, archive
    mov x23, x9
    mov x0, x9
    ARM_ADDR x16, r2_fields_archive
    mov x1, x16
    ARM_IMM w2, 2
    ARM_IMM w3, 2
    ARM_CALL r2_keys
    R2_GET x23, sha256
    mov x0, x9
    ARM_ADDR x16, r2_source_sha
    mov x1, x16
    ARM_IMM w2, 64
    ARM_CALL r2_hex_token
    R2_GET x23, bytes
    mov x0, x9
    ARM_IMM w1, ARTIFACT_LIMIT
    ARM_CALL r2_number
    ARM_ADDR x16, r2_source_bytes
    str x9, [x16]
    mov x1, x9
    ARM_ADDR x16, r2_source_sha
    mov x0, x16
    ARM_CALL r2_add_object
    R2_GET x21, artifacts
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne r2_invalid
    mov x16, x9
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x9
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x22, x16
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lr2_artifact:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x22
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x11, x23
    cmp x10, x11
    b.hs .Lr2_artifacts_end
    ARM_IMM x11, 1
    adds x24, x24, x11
    mov x10, x24
    ARM_IMM x11, 14
    cmp x10, x11
    b.hi r2_invalid
    mov x0, x22
    ARM_CALL r2_validate_artifact
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x22, x16
    mov x11, x9
    adds x22, x22, x11
    b .Lr2_artifact
.Lr2_artifacts_end:
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq r2_invalid
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=artifact token. Validate every tuple and source binding, including
 * unselected artifacts. Fixed scratch strings and object records. Stack 96. */
r2_validate_artifact:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    ARM_ADDR x16, r2_fields_artifact
    mov x1, x16
    ARM_IMM w2, 8
    ARM_IMM w3, 8
    ARM_CALL r2_keys
    R2_GET x21, cpu_features
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne r2_invalid
    mov x2, x9
    ARM_ADDR x16, smp_tokens
    mov x3, x16
    mov x11, x3
    subs x2, x2, x11
    lsr x2, x2, #5
    ARM_IMM x11, 1
    adds x2, x2, x11
    mov x10, x2
    mov x16, x9
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    R2_GET x21, kind
    mov x0, x9
    ARM_ADDR x16, registry_source_kind
    mov x1, x16
    ARM_CALL smp_plain_equal
    ARM_ADDR x16, registry_source_kind
    mov x22, x16
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_artifact_kind
    R2_GET x21, kind
    mov x0, x9
    ARM_ADDR x16, registry_executable_kind
    mov x1, x16
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    ARM_ADDR x16, registry_executable_kind
    mov x22, x16
    ARM_IMM w20, 1
.Lr2_artifact_kind:
    ARM_ADDR x16, r2_tuples
    mov x19, x16
    mov w11, w23
    eor w23, w23, w11
    tst w23, w23
.Lr2_tuple:
    mov x10, x23
    ARM_IMM x11, 6
    cmp x10, x11
    b.hs r2_invalid
    R2_GET x21, isa
    mov x0, x9
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_tuple_next
    R2_GET x21, os
    mov x0, x9
    mov x16, x19
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_tuple_next
    R2_GET x21, abi
    mov x0, x9
    mov x16, x19
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_tuple_next
    R2_GET x21, format
    mov x0, x9
    mov x16, x19
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x1, [x16]
    mov w10, w20
    mov w11, w20
    tst w10, w11
    b.ne .Lr2_tuple_format
    ARM_ADDR x16, r2_tar_gzip
    mov x1, x16
.Lr2_tuple_format:
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_tuple_found
.Lr2_tuple_next:
    ARM_IMM x11, 40
    adds x19, x19, x11
    ARM_IMM x11, 1
    adds x23, x23, x11
    b .Lr2_tuple
.Lr2_tuple_found:
    lsl x16, x23, #1
    mov w3, w16
    mov w11, w20
    adds w3, w3, w11
    ARM_ADDR x16, r2_tuple_bits
    ldr x10, [x16]
    lsrv x11, x10, x3
    and x11, x11, #1
    cmp x11, #0
    b.ne r2_invalid
    ARM_ADDR x16, r2_tuple_bits
    ldr x10, [x16]
    mov x11, #1
    lslv x11, x11, x3
    orr x10, x10, x11
    ARM_ADDR x16, r2_tuple_bits
    str x10, [x16]
    R2_GET x21, sha256
    mov x0, x9
    ARM_ADDR x16, r2_digest
    mov x1, x16
    ARM_IMM w2, 64
    ARM_CALL r2_hex_token
    R2_GET x21, bytes
    mov x0, x9
    ARM_IMM w1, ARTIFACT_LIMIT
    ARM_CALL r2_number
    mov x24, x9
    mov w10, w20
    mov w11, w20
    tst w10, w11
    b.ne .Lr2_artifact_object
    mov x10, x24
    ARM_ADDR x16, r2_source_bytes
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    ARM_ADDR x16, r2_digest
    mov x0, x16
    ARM_ADDR x16, r2_source_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
.Lr2_artifact_object:
    ARM_ADDR x16, r2_digest
    mov x0, x16
    mov x1, x24
    ARM_CALL r2_add_object
    ARM_ADDR x16, r2_target
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr2_artifact_done
    mov x16, x19
    ldr x0, [x16]
    ARM_ADDR x16, r2_target
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_artifact_done
    mov x0, x22
    ARM_ADDR x16, r2_kind
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_artifact_done
    ARM_ADDR x16, r2_selected
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r2_selected
    str x10, [x16]
    ARM_ADDR x16, r2_selected_sha
    mov x0, x16
    ARM_ADDR x16, r2_digest
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_selected_bytes
    str x24, [x16]
.Lr2_artifact_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Add one unique digest. x0=validated hex64, x1=1..64MiB. x9=owned record.
 * Conflicting lengths, >15 unique objects or >128MiB fail. Stack 64. */
r2_add_object:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    mov x21, x0
    mov x22, x1
    mov w11, w23
    eor w23, w23, w11
    tst w23, w23
    ARM_ADDR x16, r2_objects
    mov x19, x16
.Lr2_object_find:
    mov x10, x23
    ARM_ADDR x16, r2_object_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2_object_new
    mov x0, x19
    mov x1, x21
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_object_existing
    ARM_IMM x11, 1
    adds x23, x23, x11
    ARM_IMM x11, R2_RECORD
    adds x19, x19, x11
    b .Lr2_object_find
.Lr2_object_existing:
    mov x10, x22
    mov x16, x19
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    b .Lr2_object_added
.Lr2_object_new:
    mov x10, x23
    ARM_IMM x11, R2_OBJECTS
    cmp x10, x11
    b.hs r2_invalid
    ARM_ADDR x16, r2_total_bytes
    ldr x9, [x16]
    mov x11, x22
    adds x9, x9, x11
    mov x10, x9
    ARM_IMM x11, R2_TASK_BYTES
    cmp x10, x11
    b.hi r2_invalid
    ARM_ADDR x16, r2_total_bytes
    str x9, [x16]
    mov x0, x19
    mov x1, x21
    ARM_CALL copy_string
    mov x16, x19
    ARM_IMM x17, 72
    add x16, x16, x17
    str x22, [x16]
    ARM_ADDR x16, r2_object_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r2_object_count
    str x10, [x16]
.Lr2_object_added:
    mov x9, x19
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Source-bound publication. Snapshot every digest before the first HTTP
 * mutation. Files use the exact manifest digest names; no manifest URL is
 * fetched and no package code is executed. Stack 80. */
r2_publish:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, r2_manifest
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_manifest_data
    mov x1, x16
    ARM_IMM w2, R2_CONTROL
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r2_manifest_length
    str x9, [x16]
    mov x1, x9
    ARM_ADDR x16, r2_manifest_data
    mov x0, x16
    ARM_CALL r2_parse_json
    mov x0, x9
    ARM_CALL r2_validate_manifest
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    ARM_ADDR x16, r2_manifest_data
    mov x1, x16
    ARM_ADDR x16, r2_manifest_length
    ldr x2, [x16]
    ARM_CALL r2_write_file
    ARM_ADDR x16, r2p_owned
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_open_object_inputs
    ARM_IMM x24, -1
    b .Lr2_publish_source
.Lr2_open_object_inputs:
    ARM_ADDR x16, r2_objects_dir
    ldr x0, [x16]
    ARM_IMM w1, 1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x24, x9
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_publish_snapshot:
    mov x10, x19
    ARM_ADDR x16, r2_object_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2_publish_source
    mov x10, x19
    ARM_IMM x11, R2_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_objects
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    ARM_IMM w9, 257
    mov x0, x24
    mov x1, x21
    ARM_IMM w2, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w11, w6
    eor w6, w6, w11
    tst w6, w6
    ARM_CALL arm_openat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x22, x9
    ARM_IMM w9, 5
    mov x0, x22
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_ADDR x16, r2_stat + 16
    ldr w9, [x16]
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    mov w10, w9
    ARM_IMM w11, 32768
    cmp w10, w11
    b.ne r2_io
    ARM_ADDR x16, r2_stat + 48
    ldr x9, [x16]
    mov x10, x9
    mov x16, x21
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    ARM_CALL r2p_refuse_credential_object
    mov x0, x21
    ARM_CALL r2_object_stage_path
    ARM_IMM w9, 2
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_IMM w1, O_NOFOLLOW + O_CLOEXEC + 193
    ARM_IMM w2, 384
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    mov x23, x9
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr2_snapshot_read:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov x0, x22
    ARM_ADDR x16, registry_copy_buffer
    mov x1, x16
    ARM_IMM w2, 65536
    ARM_CALL arm_read
    mov x10, x9
    ARM_IMM x11, -4
    cmp x10, x11
    b.eq .Lr2_snapshot_read
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    b.eq .Lr2_snapshot_done
    mov x11, x9
    adds x20, x20, x11
    mov x10, x20
    mov x16, x21
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hi r2_invalid
    mov x2, x9
    mov x0, x23
    ARM_ADDR x16, registry_copy_buffer
    mov x1, x16
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    b .Lr2_snapshot_read
.Lr2_snapshot_done:
    mov x10, x20
    mov x16, x21
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    ARM_IMM w9, 3
    mov x0, x22
    ARM_CALL arm_close
    ARM_IMM w9, 3
    mov x0, x23
    ARM_CALL arm_close
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    /* Hash an owned snapshot with the existing descriptor-fed digest child. */
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, pub_hash_buffer
    mov x0, x16
    mov x1, x21
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2_publish_snapshot
.Lr2_publish_source:
    ARM_IMM w9, 3
    mov x0, x24
    ARM_CALL arm_close
    ARM_ADDR x16, r2_source_sha
    mov x0, x16
    ARM_CALL r2_object_stage_path
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_publish_project:
    mov w10, w19
    ARM_IMM w11, 6
    cmp w10, w11
    b.hs .Lr2_publish_post
    lsl x16, x19, #1
    mov w3, w16
    ARM_ADDR x16, r2_tuple_bits
    ldr x9, [x16]
    lsrv x9, x9, x3
    mov w10, w9
    ARM_IMM w11, 3
    tst w10, w11
    b.eq .Lr2_publish_project_next
    mov x10, x19
    ARM_IMM x11, 40
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_tuples
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ldr x3, [x16]
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_ADDR x16, r2_name
    mov x1, x16
    ARM_ADDR x16, r2_version
    mov x2, x16
    ARM_CALL validate_source_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_invalid
    ARM_ADDR x0, r2_dependencies
    ARM_ADDR x16, r2_dependency_count
    ldr x1, [x16]
    ARM_CALL g3_compare_dependencies
    cbnz w9, r2_invalid
.Lr2_publish_project_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2_publish_project
.Lr2_publish_post:
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, r2_manifest_sha
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    ARM_CALL r2_task_url
    ARM_ADDR x16, r2_method_post
    mov x0, x16
    ARM_ADDR x16, registry_temp_checksum
    mov x1, x16
    ARM_IMM w10, 1
    ARM_ADDR x16, r2_post_attempted
    strb w10, [x16]
    ARM_CALL r2_http
    mov w10, w9
    ARM_IMM w11, 200
    cmp w10, w11
    b.eq .Lr2_publish_accepted
    mov w10, w9
    ARM_IMM w11, 202
    cmp w10, w11
    b.ne r2_http_error
.Lr2_publish_accepted:
    ARM_CALL r2_parse_task
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_publish_upload:
    mov x10, x19
    ARM_ADDR x16, r2_object_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2_publish_status
    mov x10, x19
    ARM_IMM x11, R2_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_objects
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x16, x21
    ARM_IMM x17, R2_OBJECT_RECEIVED
    add x16, x16, x17
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.eq .Lr2_upload_next
    ARM_CALL r2_task_url
    mov x0, x9
    ARM_ADDR x16, r2_artifacts_path
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x1, x21
    ARM_CALL copy_string
    mov x0, x21
    ARM_CALL r2_object_stage_path
    ARM_ADDR x16, r2_method_put
    mov x0, x16
    ARM_ADDR x16, r2_object_path
    mov x1, x16
    ARM_CALL r2_http
    mov w10, w9
    ARM_IMM w11, 201
    cmp w10, w11
    b.eq .Lr2_upload_task
    mov w10, w9
    ARM_IMM w11, 204
    cmp w10, w11
    b.ne r2_http_error
    ARM_ADDR x16, r2_response_length
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne r2_invalid
    b .Lr2_upload_next
.Lr2_upload_task:
    ARM_CALL r2_parse_task
.Lr2_upload_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2_publish_upload
.Lr2_publish_status:
    ARM_CALL r2_task_url
    ARM_ADDR x16, r2_method_get
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_CALL r2_http
    mov w10, w9
    ARM_IMM w11, 200
    cmp w10, w11
    b.ne r2_http_error
    ARM_CALL r2_parse_task
    b r2_report

/* Descriptor hash adapter reuses the mature digest child without a shell.
 * x0=owned path. Output pub_hash_buffer is hex64+NUL. Stack 16. */
r2_hash_path:
    sub sp, sp, #16
    ARM_CALL pub_hash_file
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_io
    ARM_IMM w10, 0
    ARM_ADDR x16, pub_hash_buffer + 64
    strb w10, [x16]
    add sp, sp, #16
    ret

/* Descriptive source locator, never a transport instruction. Unlike an API
 * base, it may contain escaped path bytes or a trailing slash. x0=bounded
 * ASCII<=1024; w9=1/0. No credentials/query/fragment/backslash. Stack 16. */
r2_repository_locator:
    ARM_SAVE x19
    mov x19, x0
    ARM_CALL registry_https_url
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_locator_return
    mov x16, x19
    ARM_IMM x17, 8
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_locator_bad
.Lr2_locator_byte:
    mov x16, x19
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lr2_locator_ok
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 63
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_locator_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 35
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_locator_bad
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr2_locator_byte
.Lr2_locator_ok:
    ARM_IMM w9, 1
    b .Lr2_locator_return
.Lr2_locator_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2_locator_return:
    ARM_RESTORE x19
    ret

/* Exact authenticated fetch/install command. All trust inputs are explicit;
 * adapter state binds registry ID and the initial root across rotations. */
r2_receive:
    mov x10, x2
    ARM_IMM x11, 3808
    cmp x10, x11
    b.ne r2_arguments
    ARM_ADDR x16, r2_mirror_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq r2_arguments
    ARM_ADDR x16, r2_registry_id
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_selector
    ldr x0, [x16]
    ARM_CALL strlen
    mov x10, x9
    ARM_IMM x11, 168
    cmp x10, x11
    b.hi r2_arguments
    ARM_ADDR x16, r2_requested_name
    mov x0, x16
    ARM_ADDR x16, r2_selector
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_requested_name
    mov x19, x16
.Lr2_selector_at:
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2_arguments
    mov x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 64
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_selector_split
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr2_selector_at
.Lr2_selector_split:
    ARM_IMM w10, 0
    mov x16, x19
    strb w10, [x16]
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_CALL registry_valid_version
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_requested_version
    mov x0, x16
    mov x16, x19
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_requested_name
    mov x0, x16
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_kind
    ldr x0, [x16]
    ARM_CALL registry_valid_kind
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_tuples
    mov x19, x16
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr2_requested_tuple:
    ARM_ADDR x16, r2_target
    ldr x0, [x16]
    mov x16, x19
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_requested_tuple_found
    ARM_IMM x11, 40
    adds x19, x19, x11
    ARM_IMM w11, 1
    adds w20, w20, w11
    mov w10, w20
    ARM_IMM w11, 6
    cmp w10, w11
    b.lo .Lr2_requested_tuple
    b r2_arguments
.Lr2_requested_tuple_found:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr2_trust_files
    ARM_ADDR x16, r2_kind
    ldr x0, [x16]
    ARM_ADDR x16, registry_executable_kind
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_target
    ldr x0, [x16]
    ARM_ADDR x16, registry_host
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
.Lr2_trust_files:
    ARM_ADDR x16, r2_root
    ldr x0, [x16]
    ARM_CALL program_valid_absolute_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_state
    ldr x0, [x16]
    ARM_CALL program_valid_absolute_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2_ca
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr2_trust_paths_done
    ARM_ADDR x16, r2_ca
    ldr x0, [x16]
    ARM_CALL program_valid_absolute_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
.Lr2_trust_paths_done:
    ARM_ADDR x16, r2_root
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_root_data
    mov x1, x16
    ARM_IMM w2, INDEX_LIMIT
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r2_ca
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr2_trust_workspace
    ARM_ADDR x16, r2_ca
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_IMM w9, 3
    ARM_CALL arm_close
.Lr2_trust_workspace:
    ARM_CALL r2_workspace
    ARM_CALL r2_prepare_adapter
    ARM_ADDR x16, r2_root
    ldr x0, [x16]
    ARM_CALL r2_hash_path
    ARM_ADDR x16, r2_root_sha
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    ARM_CALL r2_release_target
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_CALL r2_get_target
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_trust_error
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, r2_envelope_sha
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, registry_temp_index
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_envelope
    mov x1, x16
    ARM_IMM w2, INDEX_LIMIT
    ARM_CALL r2_read_fd
    mov x1, x9
    ARM_ADDR x16, r2_envelope
    mov x0, x16
    ARM_CALL r2_parse_json
    mov x0, x9
    ARM_CALL r2_validate_envelope
    ARM_ADDR x16, r2_selected
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne r2_trust_error
    ARM_CALL r2_load_policy
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr2_receive_blob
    ARM_CALL r2_install_prepare
.Lr2_receive_blob:
    ARM_CALL r2_download_blob
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_trust_error
    ARM_ADDR x16, r2_kind
    ldr x0, [x16]
    ARM_ADDR x16, registry_source_kind
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_receive_executable
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, r2_name
    mov x1, x16
    ARM_ADDR x16, r2_version
    mov x2, x16
    ARM_ADDR x16, r2_target
    ldr x3, [x16]
    ARM_CALL validate_source_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_invalid
    ARM_ADDR x0, r2_dependencies
    ARM_ADDR x16, r2_dependency_count
    ldr x1, [x16]
    ARM_CALL g3_compare_dependencies
    cbnz w9, r2_invalid
    b .Lr2_receive_finalize
.Lr2_receive_executable:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr2_receive_finalize
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, r2_selected_bytes
    ldr x1, [x16]
    ARM_CALL validate_host_elf
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
.Lr2_receive_finalize:
    /* Long or retried blob transfers cannot extend policy freshness. */
    ARM_CALL r2_load_policy
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 4
    cmp x10, x11
    b.ne .Lr2_fetch_commit
    ARM_CALL program_commit_install
    b .Lr2_receive_report
.Lr2_fetch_commit:
    ARM_ADDR x16, r2_output
    ldr x9, [x16]
    ARM_ADDR x16, arc_output_path
    str x9, [x16]
    ARM_CALL arc_open_parent
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_io
    ARM_IMM w9, 90
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_IMM w1, 420
    ARM_CALL arm_chmod
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM w9, 316
    ARM_IMM x0, -100
    ARM_ADDR x16, registry_temp_payload
    mov x1, x16
    ARM_ADDR x16, arc_parent_fd
    ldr x2, [x16]
    ARM_ADDR x16, arc_destination_leaf
    mov x6, x16
    ARM_IMM w4, 1
    ARM_CALL arm_renameat2
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    ARM_IMM w9, 3
    ARM_ADDR x16, arc_parent_fd
    ldr x0, [x16]
    ARM_CALL arm_close
.Lr2_receive_report:
    ARM_CALL registry_cleanup
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq exit_ok
    ARM_ADDR x16, r2_fetched_json
    mov x0, x16
    ARM_CALL out
    b exit_ok

/* Write only the reviewed embedded adapter. Its target roots are explicit
 * inputs; no test key or downloaded verifier can replace these bytes. */
r2_prepare_adapter:
    sub sp, sp, #16
    ARM_ADDR x16, r2_helper_path
    mov x0, x16
    ARM_ADDR x16, r2_helper_bytes
    mov x1, x16
    ARM_ADDR x2, r2_helper_end
    ARM_ADDR x10, r2_helper_bytes
    sub x2, x2, x10
    ARM_CALL r2_write_file
    ARM_IMM w9, 90
    ARM_ADDR x16, r2_helper_path
    mov x0, x16
    ARM_IMM w1, 448
    ARM_CALL arm_chmod
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2_io
    add sp, sp, #16
    ret
r2_target_prefix:
    sub sp, sp, #16
    ARM_ADDR x16, r2_target_path
    mov x0, x16
    ARM_ADDR x16, r2_registries_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL copy_string
    add sp, sp, #16
    ret
r2_release_target:
    sub sp, sp, #16
    ARM_CALL r2_target_prefix
    mov x0, x9
    ARM_ADDR x16, r2_releases_path
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_requested_name
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 47
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_requested_version
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_json_suffix
    mov x1, x16
    ARM_CALL copy_string
    add sp, sp, #16
    ret
r2_policy_target:
    sub sp, sp, #16
    ARM_CALL r2_target_prefix
    mov x0, x9
    ARM_ADDR x16, r2_policy_suffix
    mov x1, x16
    ARM_CALL copy_string
    add sp, sp, #16
    ret

/* Refresh and evaluate lifecycle policy under the same protected trust state.
 * Called before transfer and immediately before exposure. No blob transfer.
 * Preserves callee registers, Stack 16, policy buffer<=1MiB. */
r2_load_policy:
    sub sp, sp, #16
    ARM_CALL r2_policy_target
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    ARM_CALL r2_get_target
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_trust_error
    ARM_ADDR x16, registry_temp_checksum
    mov x0, x16
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_policy
    mov x1, x16
    ARM_IMM w2, INDEX_LIMIT
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r2_policy
    mov x2, x16
    mov x11, x9
    adds x2, x2, x11
    ARM_ADDR x16, r2_policy_end
    str x2, [x16]
    ARM_ADDR x16, r2_policy
    mov x9, x16
    ARM_ADDR x16, r2_policy_cursor
    str x9, [x16]
    ARM_CALL r2_validate_policy
    add sp, sp, #16
    ret

/* x0=owned output path. Try <=3 explicitly selected byte origins; never
 * change authority/root/state. w9=0 success,1 all alternatives failed. */
r2_get_target:
    ARM_SAVE x19
    ARM_SAVE x21
    mov x21, x0
    ARM_ADDR x16, r2_adapter_output
    mov x0, x16
    ARM_ADDR x16, r2_cwd
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 47
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    mov x1, x21
    ARM_CALL copy_string
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_target_try:
    ARM_IMM w9, 87
    mov x0, x21
    ARM_CALL arm_unlink
    ARM_ADDR x16, r2_adapter_argv
    mov x2, x16
    ARM_ADDR x16, r2_helper_path
    mov x9, x16
    mov x16, x2
    str x9, [x16]
    ARM_ADDR x16, r2_adapter_command
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_root
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 16
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_state
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 24
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_registry_id
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_mirrors
    mov x3, x16
    mov x16, x3
    add x16, x16, x19, lsl #3
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 40
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_target_path
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 48
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_adapter_output
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 56
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_ca
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 64
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM x10, 0
    mov x16, x2
    ARM_IMM x17, 72
    add x16, x16, x17
    str x10, [x16]
    ARM_IMM x10, INDEX_LIMIT
    ARM_ADDR x16, r2_child_file_limit
    str x10, [x16]
    ARM_ADDR x16, r2_helper_path
    mov x0, x16
    ARM_ADDR x16, r2_adapter_argv
    mov x1, x16
    ARM_CALL r2_child
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_target_next
    ARM_ADDR x16, r2_status_length
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lr2_target_next
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lr2_target_return
.Lr2_target_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov x10, x19
    ARM_ADDR x16, r2_mirror_count
    ldr x11, [x16]
    cmp x10, x11
    b.lo .Lr2_target_try
    ARM_IMM w9, 1
.Lr2_target_return:
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Full signed envelope, whose digest is retained in the managed receipt. */
r2_validate_envelope:
    ARM_SAVE x19
    ARM_SAVE x21
    mov x21, x0
    ARM_ADDR x16, r2_fields_envelope
    mov x1, x16
    ARM_IMM w2, 6
    ARM_IMM w3, 6
    ARM_CALL r2_keys
    R2_GET x21, schema
    mov x0, x9
    ARM_CALL r2_schema
    R2_GET x21, registry_id
    mov x0, x9
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL smp_plain_equal
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    R2_GET x21, package_id
    mov x0, x9
    ARM_ADDR x16, r2_package_id
    mov x1, x16
    ARM_IMM w2, 32
    ARM_CALL r2_hex_token
    R2_GET x21, release_id
    mov x0, x9
    ARM_ADDR x16, r2_release_id
    mov x1, x16
    ARM_IMM w2, 32
    ARM_CALL r2_hex_token
    R2_GET x21, manifest_sha256
    mov x0, x9
    ARM_ADDR x16, r2_manifest_sha
    mov x1, x16
    ARM_IMM w2, 64
    ARM_CALL r2_hex_token
    R2_GET x21, publication
    mov x0, x9
    ARM_CALL r2_validate_manifest
    ARM_ADDR x16, r2_name
    mov x0, x16
    ARM_ADDR x16, r2_requested_name
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_version
    mov x0, x16
    ARM_ADDR x16, r2_requested_version
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Bounded TSV line split in owned policy buffer. x9=field count, x0/x1
 * scratch; fields borrow NUL-terminated spans. Require LF and <=6fields. */
r2_policy_line:
    ARM_ADDR x16, r2_policy_cursor
    ldr x0, [x16]
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
    ARM_ADDR x16, r2_policy_fields
    mov x2, x16
    mov x16, x2
    str x0, [x16]
.Lr2_policy_byte:
    mov x10, x0
    ARM_ADDR x16, r2_policy_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs r2_trust_error
    mov x16, x0
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq r2_trust_error
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_policy_lf
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_policy_plain
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 6
    cmp w10, w11
    b.hs r2_trust_error
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x9, x16
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x9, [x16]
    b .Lr2_policy_scan_next
.Lr2_policy_plain:
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo r2_trust_error
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi r2_trust_error
.Lr2_policy_scan_next:
    ARM_IMM x11, 1
    adds x0, x0, x11
    b .Lr2_policy_byte
.Lr2_policy_lf:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_ADDR x16, r2_policy_cursor
    str x0, [x16]
    mov x16, x3
    ARM_IMM x17, 1
    add x16, x16, x17
    mov w9, w16
    ret

/* Canonical nonnegative signed63-bit decimal field, including0. */
r2_policy_revision:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_revision_digit
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_trust_error
    ret
.Lr2_revision_digit:
    mov x16, x0
    add x16, x16, x3
    ldrb w2, [x16]
    mov w10, w2
    mov w11, w2
    tst w10, w11
    b.eq .Lr2_revision_end
    ARM_IMM w11, 48
    subs w2, w2, w11
    mov w10, w2
    ARM_IMM w11, 9
    cmp w10, w11
    b.hi r2_trust_error
    mov x10, x9
    ARM_IMM x11, 10
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    b.ne r2_trust_error
    mov x11, x2
    adds x9, x9, x11
    b.vs r2_trust_error
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 19
    cmp w10, w11
    b.hi r2_trust_error
    b .Lr2_revision_digit
.Lr2_revision_end:
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.eq r2_trust_error
    ret

/* C lexical comparison of validated ASCII. w9=-1/0/1. */
r2_lex:
    mov x16, x0
    ldrb w9, [x16]
    mov x16, x1
    ldrb w2, [x16]
    mov w10, w9
    mov w11, w2
    cmp w10, w11
    b.lo .Lr2_lex_less
    b.hi .Lr2_lex_greater
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_lex_equal
    ARM_IMM x11, 1
    adds x0, x0, x11
    ARM_IMM x11, 1
    adds x1, x1, x11
    b r2_lex
.Lr2_lex_less:
    ARM_IMM w9, -1
    ret
.Lr2_lex_greater:
    ARM_IMM w9, 1
    ret
.Lr2_lex_equal:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ret

/* Validate the whole authenticated lifecycle table before selecting bytes.
 * Every retained row is bounded, sorted, unique and closed. Selected IDs must
 * match the signed envelope and be neither yanked nor revoked. Stack 48. */
r2_validate_policy:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_CALL r2_policy_line
    mov w10, w9
    ARM_IMM w11, 4
    cmp w10, w11
    b.ne r2_trust_error
    ARM_ADDR x16, r2_policy_fields
    ldr x0, [x16]
    ARM_ADDR x16, r2_policy_header
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 8
    ldr x0, [x16]
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 16
    ldr x0, [x16]
    ARM_CALL r2_policy_revision
    ARM_ADDR x16, r2_policy_fields + 24
    ldr x0, [x16]
    ARM_CALL r2_policy_revision
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov w11, w21
    eor w21, w21, w11
    tst w21, w21
.Lr2_policy_row:
    ARM_ADDR x16, r2_policy_cursor
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2_policy_end
    ldr x11, [x16]
    cmp x10, x11
    b.eq .Lr2_policy_done
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov w10, w19
    ARM_IMM w11, 4096
    cmp w10, w11
    b.hi r2_trust_error
    ARM_CALL r2_policy_line
    mov w10, w9
    ARM_IMM w11, 6
    cmp w10, w11
    b.ne r2_trust_error
    ARM_ADDR x16, r2_policy_fields
    ldr x0, [x16]
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 8
    ldr x0, [x16]
    ARM_CALL registry_valid_version
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 16
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 24
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 32
    ldr x0, [x16]
    ARM_CALL r2_policy_flag
    ARM_ADDR x16, r2_policy_fields + 40
    ldr x0, [x16]
    ARM_CALL r2_policy_flag
    mov w10, w19
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq .Lr2_policy_save
    ARM_ADDR x16, r2_previous_name
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields
    ldr x1, [x16]
    ARM_CALL r2_lex
    mov w10, w9
    ARM_IMM w11, 0
    cmp w10, w11
    b.gt r2_trust_error
    b.lt .Lr2_policy_save
    ARM_ADDR x16, r2_previous_version
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 8
    ldr x1, [x16]
    ARM_CALL r2_lex
    mov w10, w9
    ARM_IMM w11, 0
    cmp w10, w11
    b.ge r2_trust_error
.Lr2_policy_save:
    ARM_ADDR x16, r3_active
    ldrb w10, [x16]
    cbz w10, .Lr3_policy_legacy
    ARM_CALL r3_policy_row
.Lr3_policy_legacy:
    ARM_ADDR x16, r2_previous_name
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_previous_version
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 8
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r3_active
    ldrb w10, [x16]
    cbnz w10, .Lr2_policy_row
    ARM_ADDR x16, r2_name
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_policy_row
    ARM_ADDR x16, r2_version
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 8
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_policy_row
    ARM_ADDR x16, r2_package_id
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 16
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_release_id
    mov x0, x16
    ARM_ADDR x16, r2_policy_fields + 24
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 32
    ldr x0, [x16]
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_trust_error
    ARM_ADDR x16, r2_policy_fields + 40
    ldr x0, [x16]
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_trust_error
    ARM_IMM x11, 1
    adds x21, x21, x11
    b .Lr2_policy_row
.Lr2_policy_done:
    ARM_ADDR x16, r3_active
    ldrb w10, [x16]
    cbnz w10, .Lr3_policy_return
    mov x10, x21
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne r2_trust_error
.Lr3_policy_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
r2_policy_flag:
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x0030
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2_policy_flag_ok
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x0031
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne r2_trust_error
.Lr2_policy_flag_ok:
    ret

/* Download digest-addressed blob through <=3 byte mirrors. Corrupt or failed
 * alternatives are removed; only exact bytes become visible. Stack 64. */
r2_download_blob:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x16, r2_selected_bytes
    ldr x0, [x16]
    ARM_ADDR x16, r2_size_decimal + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    ARM_ADDR x16, r2_size_pointer
    str x9, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_blob_try:
    ARM_IMM w9, 87
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_ADDR x16, r2_url
    mov x0, x16
    ARM_ADDR x16, r2_mirrors
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    ldr x1, [x16]
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_blobs_path
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_selected_sha
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_selection_query
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_IMM w10, 46
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_package_id
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 46
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_release_id
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 46
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_target
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_IMM w10, 46
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_kind
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_blob_argv
    mov x2, x16
    ARM_ADDR x16, registry_curl
    mov x9, x16
    mov x16, x2
    str x9, [x16]
    ARM_ADDR x16, registry_curl_disable
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_silent
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 16
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_fail
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 24
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_proto
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 32
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_https
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 40
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_connect_timeout
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 48
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_fifteen
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 56
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_max_time
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 64
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_seconds
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 72
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_max_filesize
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 80
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, r2_size_pointer
    ldr x9, [x16]
    mov x16, x2
    ARM_IMM x17, 88
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_curl_output
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 96
    add x16, x16, x17
    str x9, [x16]
    ARM_ADDR x16, registry_temp_payload
    mov x9, x16
    mov x16, x2
    ARM_IMM x17, 104
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM w3, 14
    ARM_ADDR x16, r2_ca
    ldr x9, [x16]
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr2_blob_argv_end
    ARM_ADDR x16, r2_ca_option
    mov x1, x16
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x1, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
.Lr2_blob_argv_end:
    ARM_ADDR x16, registry_separator
    mov x9, x16
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_ADDR x16, r2_url
    mov x9, x16
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x9, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    ARM_IMM x10, 0
    mov x16, x2
    add x16, x16, x3, lsl #3
    str x10, [x16]
    ARM_ADDR x16, r2_selected_bytes
    ldr x9, [x16]
    ARM_ADDR x16, r2_child_file_limit
    str x9, [x16]
    ARM_ADDR x16, registry_curl
    mov x0, x16
    ARM_ADDR x16, r2_blob_argv
    mov x1, x16
    ARM_CALL r2_child
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_blob_next
    ARM_ADDR x16, r2_status_length
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lr2_blob_next
    ARM_IMM w9, 6
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_lstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2_blob_next
    ARM_ADDR x16, r2_stat + 48
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2_selected_bytes
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lr2_blob_next
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, pub_hash_buffer
    mov x0, x16
    ARM_ADDR x16, r2_selected_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2_blob_next
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    b .Lr2_blob_return
.Lr2_blob_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov x10, x19
    ARM_ADDR x16, r2_mirror_count
    ldr x11, [x16]
    cmp x10, x11
    b.lo .Lr2_blob_try
    ARM_IMM w9, 1
.Lr2_blob_return:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Reuse the existing program inventory with an explicit authority binding.
 * Full origin: v2:registry:initial-root-sha:package:release:envelope-sha.
 * No adoption or upgrade. Exact repeated installation verifies existing bytes
 * only after fresh TUF/lifecycle checks, then returns unchanged. */
r2_install_prepare:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_ADDR x16, r2_origin_receipt
    mov x0, x16
    ARM_ADDR x16, r2_origin_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2_registry_id
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_IMM w10, 58
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_root_sha
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 58
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_package_id
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 58
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_release_id
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 58
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2_envelope_sha
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_origin_receipt
    mov x9, x16
    ARM_ADDR x16, registry_url
    str x9, [x16]
    ARM_ADDR x16, r2_output
    ldr x9, [x16]
    ARM_ADDR x16, registry_output
    str x9, [x16]
    ARM_ADDR x16, r2_name
    mov x9, x16
    ARM_ADDR x16, r2_synthetic_row
    str x9, [x16]
    ARM_ADDR x16, r2_version
    mov x9, x16
    ARM_ADDR x16, r2_synthetic_row + 8
    str x9, [x16]
    ARM_ADDR x16, r2_target
    ldr x9, [x16]
    ARM_ADDR x16, r2_synthetic_row + 16
    str x9, [x16]
    ARM_ADDR x16, r2_kind
    ldr x9, [x16]
    ARM_ADDR x16, r2_synthetic_row + 24
    str x9, [x16]
    ARM_ADDR x16, r2_selected_sha
    mov x9, x16
    ARM_ADDR x16, r2_synthetic_row + 32
    str x9, [x16]
    ARM_ADDR x16, r2_origin_receipt
    mov x9, x16
    ARM_ADDR x16, r2_synthetic_row + 40
    str x9, [x16]
    ARM_ADDR x16, r2_selected_bytes
    ldr x0, [x16]
    ARM_ADDR x16, r2_size_decimal + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    ARM_ADDR x16, r2_synthetic_row + 48
    str x9, [x16]
    ARM_ADDR x16, r2_summary
    mov x9, x16
    ARM_ADDR x16, r2_synthetic_row + 56
    str x9, [x16]
    ARM_ADDR x16, r2_synthetic_row
    mov x9, x16
    ARM_ADDR x16, registry_selected
    str x9, [x16]
    ARM_IMM w0, 1
    ARM_CALL program_open_state
    ARM_CALL program_read_state
    ARM_ADDR x16, r2_name
    mov x0, x16
    ARM_CALL program_find
    ARM_ADDR x16, program_found
    str x9, [x16]
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr2_install_new
    mov x21, x9
    mov x16, x21
    ARM_IMM x17, 48
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, r2_origin_receipt
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, r2_version
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, r2_target
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, r2_selected_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    mov x16, x21
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x0, [x16]
    ARM_ADDR x16, r2_synthetic_row + 48
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    ARM_ADDR x16, r2_output
    ldr x1, [x16]
    ARM_CALL program_absolute_path
    ARM_ADDR x16, program_path
    mov x0, x16
    mov x16, x21
    ARM_IMM x17, 40
    add x16, x16, x17
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_io
    ARM_CALL program_open_destination
    ARM_CALL program_check_existing
    ARM_CALL registry_cleanup
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq exit_ok
    ARM_ADDR x16, r2_unchanged_json
    mov x0, x16
    ARM_CALL out
    b exit_ok
.Lr2_install_new:
    ARM_ADDR x16, program_count
    ldr x10, [x16]
    ARM_IMM x11, PROGRAM_LIMIT
    cmp x10, x11
    b.hs r2_io
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=inventory origin. w9=1 only for the complete closed V2 receipt shape.
 * No mutation; all fixed ID/digest lengths and separators checked. Stack 16. */
r2_inventory_origin:
    ARM_SAVE x19
    mov x19, x0
    ARM_CALL strlen
    mov w10, w9
    ARM_IMM w11, 231
    cmp w10, w11
    b.ne .Lr2_inventory_bad
    mov x16, x19
    ldrh w10, [x16]
    ARM_IMM w11, 0x3276
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lr2_inventory_bad
    mov x16, x19
    ARM_IMM x17, 2
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 58
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_inventory_bad
    ARM_IMM w3, 3
.Lr2_inventory_byte:
    mov w10, w3
    ARM_IMM w11, 231
    cmp w10, w11
    b.hs .Lr2_inventory_ok
    mov x16, x19
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w3
    ARM_IMM w11, 35
    cmp w10, w11
    b.eq .Lr2_inventory_colon
    mov w10, w3
    ARM_IMM w11, 100
    cmp w10, w11
    b.eq .Lr2_inventory_colon
    mov w10, w3
    ARM_IMM w11, 133
    cmp w10, w11
    b.eq .Lr2_inventory_colon
    mov w10, w3
    ARM_IMM w11, 166
    cmp w10, w11
    b.eq .Lr2_inventory_colon
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lr2_inventory_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 57
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ls .Lr2_inventory_next
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 97
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo .Lr2_inventory_bad
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 102
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi .Lr2_inventory_bad
    b .Lr2_inventory_next
.Lr2_inventory_colon:
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 58
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2_inventory_bad
.Lr2_inventory_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2_inventory_byte
.Lr2_inventory_ok:
    ARM_IMM w9, 1
    b .Lr2_inventory_return
.Lr2_inventory_bad:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2_inventory_return:
    ARM_RESTORE x19
    ret

/* Token string -> owned NUL buffer. x0=token, x1=buffer, w2=capacity incl
 * NUL. Plain printable ASCII only; w9=length. Stack 0. */
r2_string:
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_STRING
    cmp x10, x11
    b.ne r2_invalid
    mov x16, x0
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x3, [x16]
    mov x10, x3
    mov x11, x2
    cmp x10, x11
    b.hs r2_invalid
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
.Lr2_string_byte:
    mov x10, x2
    mov x11, x3
    cmp x10, x11
    b.hs .Lr2_string_end
    mov x16, x0
    add x16, x16, x2
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.lo r2_invalid
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 126
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi r2_invalid
    mov x16, x1
    add x16, x16, x2
    strb w9, [x16]
    ARM_IMM x11, 1
    adds x2, x2, x11
    b .Lr2_string_byte
.Lr2_string_end:
    ARM_IMM w10, 0
    mov x16, x1
    add x16, x16, x2
    strb w10, [x16]
    mov x9, x3
    ret

/* Closed object fields. x0=token, x1=allowed NUL string set, w2=min count,
 * w3=max count. Required fields are checked separately. Stack 80. */
r2_keys:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x16, x0
    ldr x10, [x16]
    ARM_IMM x11, SMP_OBJECT
    cmp x10, x11
    b.ne r2_invalid
    mov x21, x0
    mov x22, x1
    mov w23, w2
    mov w24, w3
    mov x16, x0
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x19, x16
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
.Lr2_keys_next:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x19
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2_keys_end
    ARM_SAVE x4
    mov x0, x19
    ARM_ADDR x16, r2_key_buffer
    mov x1, x16
    ARM_IMM w2, 256
    /* Keys have the KEY token kind; copy through the bounded raw span. */
    mov x16, x0
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x3, [x16]
    mov x10, x3
    ARM_IMM x11, 255
    cmp x10, x11
    b.hi r2_invalid
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x2, [x16]
    mov x0, x1
    mov x1, x2
    cbz x3, .Lr2_arm_copy_3_end
.Lr2_arm_copy_3:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2_arm_copy_3
.Lr2_arm_copy_3_end:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_ADDR x16, r2_key_buffer
    mov x0, x16
    mov x1, x22
    ARM_CALL pub_in_strings
    ARM_RESTORE x4
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    ARM_IMM x11, 1
    adds x4, x4, x11
    mov x10, x4
    mov x11, x24
    cmp x10, x11
    b.hi r2_invalid
    mov x16, x19
    ARM_IMM x17, 56
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x19, x16
    mov x11, x9
    adds x19, x19, x11
    b .Lr2_keys_next
.Lr2_keys_end:
    mov x10, x4
    mov x11, x23
    cmp x10, x11
    b.lo r2_invalid
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Parsed task IDs must bind the requested task; raw private problem bodies
 * are never emitted. Further task schema checks are performed below. */
r2_parse_task:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, r2_response
    mov x0, x16
    ARM_ADDR x16, r2_response_length
    ldr x1, [x16]
    ARM_CALL r2_parse_json
    mov x21, x9
    mov x0, x9
    ARM_ADDR x16, r2_fields_task
    mov x1, x16
    ARM_IMM w2, 9
    ARM_IMM w3, 9
    ARM_CALL r2_keys
    R2_GET x21, schema
    mov x0, x9
    ARM_CALL r2_schema
    R2_GET x21, package_id
    mov x0, x9
    ARM_ADDR x16, r2_task_package
    mov x1, x16
    ARM_IMM w2, 32
    ARM_CALL r2_hex_token
    R2_GET x21, manifest_sha256
    mov x0, x9
    ARM_ADDR x16, r2_task_manifest
    mov x1, x16
    ARM_IMM w2, 64
    ARM_CALL r2_hex_token
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lr2_task_state
    ARM_ADDR x16, r2_task_manifest
    mov x0, x16
    ARM_ADDR x16, r2_manifest_sha
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
.Lr2_task_state:
    R2_GET x21, state
    mov x0, x9
    ARM_ADDR x16, r2_task_state
    mov x1, x16
    ARM_IMM w2, 16
    ARM_CALL r2_string
    ARM_ADDR x16, r2_task_state
    mov x0, x16
    ARM_ADDR x16, r2_task_states
    mov x1, x16
    ARM_CALL pub_in_strings
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    R2_GET x21, upload_expires_at
    mov x0, x9
    ARM_ADDR x16, r2_timestamp
    mov x1, x16
    ARM_IMM w2, 21
    ARM_CALL r2_string
    mov w10, w9
    ARM_IMM w11, 20
    cmp w10, w11
    b.ne r2_invalid
    ARM_ADDR x16, r2_timestamp
    mov x0, x16
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2_timestamp_byte:
    mov w10, w3
    ARM_IMM w11, 20
    cmp w10, w11
    b.hs .Lr2_task_objects
    ARM_ADDR x16, r2_timestamp_shape
    mov x2, x16
    mov x16, x2
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_timestamp_digit
    mov w10, w9
    and w10, w10, #255
    mov x16, x0
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2_invalid
    b .Lr2_timestamp_next
.Lr2_timestamp_digit:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    ARM_IMM w11, 48
    subs w9, w9, w11
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.hi r2_invalid
.Lr2_timestamp_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2_timestamp_byte
.Lr2_task_objects:
    R2_GET x21, objects
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_ARRAY
    cmp x10, x11
    b.ne r2_invalid
    mov x16, x9
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x23, [x16]
    mov x16, x9
    ARM_IMM x17, 32
    add x16, x16, x17
    mov x22, x16
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_task_total
    str x10, [x16]
    ARM_IMM w10, 0
    ARM_ADDR x16, r2_previous_digest
    strb w10, [x16]
.Lr2_task_object:
    ARM_ADDR x16, smp_tokens
    mov x9, x16
    mov x2, x22
    mov x11, x9
    subs x2, x2, x11
    lsr x2, x2, #5
    mov x10, x2
    mov x11, x23
    cmp x10, x11
    b.hs .Lr2_task_objects_done
    ARM_IMM x11, 1
    adds x24, x24, x11
    mov x10, x24
    ARM_IMM x11, R2_OBJECTS
    cmp x10, x11
    b.hi r2_invalid
    mov x0, x22
    ARM_ADDR x16, r2_fields_task_object
    mov x1, x16
    ARM_IMM w2, 3
    ARM_IMM w3, 3
    ARM_CALL r2_keys
    R2_GET x22, sha256
    mov x0, x9
    ARM_ADDR x16, r2_task_digest
    mov x1, x16
    ARM_IMM w2, 64
    ARM_CALL r2_hex_token
    ARM_ADDR x16, r2_previous_digest
    mov x0, x16
    ARM_ADDR x16, r2_task_digest
    mov x1, x16
    ARM_CALL r2_lex
    mov w10, w9
    ARM_IMM w11, 0
    cmp w10, w11
    b.ge r2_invalid
    ARM_ADDR x16, r2_previous_digest
    mov x0, x16
    ARM_ADDR x16, r2_task_digest
    mov x1, x16
    ARM_CALL copy_string
    R2_GET x22, bytes
    mov x0, x9
    ARM_IMM w1, ARTIFACT_LIMIT
    ARM_CALL r2_number
    ARM_ADDR x16, r2_task_total
    ldr x10, [x16]
    mov x11, x9
    adds x10, x10, x11
    ARM_ADDR x16, r2_task_total
    str x10, [x16]
    ARM_ADDR x16, r2_task_total
    ldr x10, [x16]
    ARM_IMM x11, R2_TASK_BYTES
    cmp x10, x11
    b.hi r2_invalid
    ARM_ADDR x16, r2_task_object_bytes
    str x9, [x16]
    R2_GET x22, received
    ARM_IMM x10, 1
    ARM_ADDR x16, r2_task_received
    str x10, [x16]
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_TRUE
    cmp x10, x11
    b.eq .Lr2_task_object_binding
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_FALSE
    cmp x10, x11
    b.ne r2_invalid
    ARM_IMM x10, 0
    ARM_ADDR x16, r2_task_received
    str x10, [x16]
.Lr2_task_object_binding:
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lr2_task_object_next
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_task_object_find:
    mov x10, x19
    ARM_ADDR x16, r2_object_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs r2_invalid
    mov x10, x19
    ARM_IMM x11, R2_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_objects
    mov x0, x16
    mov x11, x9
    adds x0, x0, x11
    ARM_ADDR x16, r2_task_digest
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2_task_object_found
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2_task_object_find
.Lr2_task_object_found:
    mov x10, x19
    ARM_IMM x11, R2_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_objects
    mov x2, x16
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x4, [x16]
    mov x10, x4
    ARM_ADDR x16, r2_task_object_bytes
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
    ARM_ADDR x16, r2_task_received
    ldr x3, [x16]
    mov x16, x2
    add x16, x16, x9
    ARM_IMM x17, R2_OBJECT_RECEIVED
    add x16, x16, x17
    str x3, [x16]
.Lr2_task_object_next:
    mov x16, x22
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    lsl x9, x9, #5
    ARM_ADDR x16, smp_tokens
    mov x22, x16
    mov x11, x9
    adds x22, x22, x11
    b .Lr2_task_object
.Lr2_task_objects_done:
    mov x10, x24
    mov x11, x24
    tst x10, x11
    b.eq r2_invalid
    ARM_ADDR x16, r2_mode
    ldr x10, [x16]
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne .Lr2_task_failure
    mov x10, x24
    ARM_ADDR x16, r2_object_count
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2_invalid
.Lr2_task_failure:
    R2_GET x21, failure
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_NULL
    cmp x10, x11
    b.eq .Lr2_task_release
    mov x22, x9
    mov x0, x9
    ARM_ADDR x16, r2_fields_failure
    mov x1, x16
    ARM_IMM w2, 3
    ARM_IMM w3, 3
    ARM_CALL r2_keys
    R2_GET x22, code
    mov x0, x9
    ARM_ADDR x16, r2_task_detail
    mov x1, x16
    ARM_IMM w2, 128
    ARM_CALL r2_string
    R2_GET x22, detail
    mov x0, x9
    ARM_ADDR x16, r2_task_detail
    mov x1, x16
    ARM_IMM w2, 1024
    ARM_CALL r2_text
    R2_GET x22, retryable
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_TRUE
    cmp x10, x11
    b.eq .Lr2_task_release
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_FALSE
    cmp x10, x11
    b.ne r2_invalid
.Lr2_task_release:
    R2_GET x21, release
    mov x16, x9
    ldr x10, [x16]
    ARM_IMM x11, SMP_NULL
    cmp x10, x11
    b.eq .Lr2_task_identity
    mov x22, x9
    ARM_ADDR x16, r2_task_state
    mov x0, x16
    ARM_ADDR x16, r2_published_state
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    mov x9, x22
    mov x0, x9
    ARM_ADDR x16, r2_fields_task_release
    mov x1, x16
    ARM_IMM w2, 2
    ARM_IMM w3, 2
    ARM_CALL r2_keys
    R2_GET x22, manifest_url
    mov x0, x9
    ARM_ADDR x16, r2_task_detail
    mov x1, x16
    ARM_IMM w2, 1024
    ARM_CALL r2_string
    ARM_ADDR x16, r2_task_detail
    mov x0, x16
    ARM_CALL r2_origin
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    R2_GET x22, metadata_url
    mov x0, x9
    ARM_ADDR x16, r2_task_detail
    mov x1, x16
    ARM_IMM w2, 1024
    ARM_CALL r2_string
    ARM_ADDR x16, r2_task_detail
    mov x0, x16
    ARM_CALL r2_origin
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
.Lr2_task_identity:
    mov x9, x21
    mov x0, x9
    ARM_ADDR x16, r2_key_id
    mov x1, x16
    ARM_CALL r2_required
    mov x0, x9
    ARM_ADDR x16, r2_returned_task
    mov x1, x16
    ARM_IMM w2, 33
    ARM_CALL r2_string
    ARM_ADDR x16, r2_returned_task
    mov x0, x16
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
    ARM_ADDR x16, r2_task_id
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_task_copy
    ARM_ADDR x16, r2_task_id
    mov x0, x16
    ARM_ADDR x16, r2_returned_task
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_invalid
.Lr2_task_copy:
    ARM_ADDR x16, r2_task_id
    mov x0, x16
    ARM_ADDR x16, r2_returned_task
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret
r2_report:
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_report_text
    ARM_IMM w0, 1
    ARM_ADDR x16, r2_response
    mov x1, x16
    ARM_ADDR x16, r2_response_length
    ldr x2, [x16]
    ARM_CALL write_all
    b .Lr2_report_end
.Lr2_report_text:
    ARM_ADDR x16, r2_task_text
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, r2_task_id
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, r2_task_separator
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, r2_task_state
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, r2_task_note
    mov x0, x16
    ARM_CALL out
.Lr2_report_end:
    ARM_CALL registry_cleanup
    b exit_ok

/* Called by registry_cleanup for any exit, including reused legacy routines.
 * Remove only fixed files/validated digest names in our owned private stage. */
r2_clean_files:
    ARM_ADDR x16, r2_active
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_clean_return
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_ADDR x16, registry_has_workspace
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2_clean_done
    ARM_CALL r2p_cleanup
    ARM_IMM w9, 87
    ARM_ADDR x16, r2_header_path
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_IMM w9, 87
    ARM_ADDR x16, r2_helper_path
    mov x0, x16
    ARM_CALL arm_unlink
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2_clean_object:
    mov x10, x19
    ARM_ADDR x16, r2_object_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2_clean_done
    mov x9, x19
    mov x10, x9
    ARM_IMM x11, R2_RECORD
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_objects
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    mov x0, x21
    ARM_CALL r2_object_stage_path
    ARM_IMM w9, 87
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_CALL arm_unlink
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2_clean_object
.Lr2_clean_done:
    ARM_RESTORE x21
    ARM_RESTORE x19
.Lr2_clean_return:
    ret
r2_object_stage_path:
    ARM_SAVE x19
    mov x19, x0
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 47
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x0, x16
    mov x1, x19
    ARM_CALL copy_string
    ARM_RESTORE x19
    ret

.section .rodata
r2_commands:
    .quad r2_cmd_publish,1,r2_cmd_task,2,r2_cmd_fetch,3,r2_cmd_install,4
    .quad r3_cmd_resolve,5,r3_cmd_sync,6
    .quad registry_opt_help,0,0,0
r3_cmd_resolve: .asciz "resolve"
r3_cmd_sync: .asciz "sync"
r2_cmd_publish: .asciz "publish"
r2_cmd_task: .asciz "task"
r2_cmd_fetch: .asciz "fetch"
r2_cmd_install: .asciz "install"
r2_opt_manifest: .asciz "--manifest"
r2_opt_objects: .asciz "--objects-dir"
r2_opt_credential: .asciz "--credential-file"
r2_opt_api: .asciz "--api"
r2_opt_key: .asciz "--idempotency-key"
r2_opt_id: .asciz "--registry-id"
r2_opt_root: .asciz "--root"
r2_opt_state: .asciz "--state"
r2_opt_mirror: .asciz "--mirror"
r2_opt_ca: .asciz "--ca"
r2_options:
    .quad r2_opt_manifest,r2_manifest,1,r2_opt_objects,r2_objects_dir,2
    .quad r2_opt_credential,r2_credential,4,r2_opt_api,r2_api,8
    .quad r2_opt_key,r2_key,16,r2_opt_id,r2_registry_id,32
    .quad r2_opt_root,r2_root,64,r2_opt_state,r2_state,128
    .quad r2_opt_ca,r2_ca,256,registry_opt_target,r2_target,512
    .quad registry_opt_kind,r2_kind,1024,registry_opt_output,r2_output,2048
    .quad r2p_opt_project,r2p_project,4096,r2p_opt_name,r2p_name,8192
    .quad r2p_opt_owner,r2p_owner,16384,r2p_opt_summary,r2p_summary,32768
    .quad r2p_opt_license,r2p_license,65536,r2p_opt_commit,r2p_commit,131072
    .quad r2p_opt_path,r2p_source_path,262144,r2p_opt_repository,r2p_repository,524288
    .quad 0,0,0
r2_method_get: .asciz "GET"
r2_method_post: .asciz "POST"
r2_method_put: .asciz "PUT"
r2_request: .asciz "--request"
r2_write_out: .asciz "--write-out"
r2_status_format: .asciz "%{http_code}"
r2_header_option: .asciz "--header"
r2_data_binary: .asciz "--data-binary"
r2_upload_file: .asciz "--upload-file"
r2_content_json: .asciz "Content-Type: application/json"
r2_content_blob: .asciz "Content-Type: application/octet-stream"
r2_ca_option: .asciz "--cacert"
r2_control_decimal: .asciz "65536"
r2_seconds: .asciz "110"
r2_token_prefix: .asciz "asm_pub_v1_"
r2_authorization: .asciz "Authorization: Bearer "
r2_idempotency: .asciz "Idempotency-Key: "
r2_publications_path: .asciz "/api/v2/publications"
r2_header_suffix: .asciz "/authorization"
r2_helper_suffix: .asciz "/asm-verify"
r2_key_id: .asciz "id"
r2_k_registry_id: .asciz "registry_id"
r2_k_package_id: .asciz "package_id"
r2_k_release_id: .asciz "release_id"
r2_k_manifest_sha256: .asciz "manifest_sha256"
r2_k_publication: .asciz "publication"
r2_fields_envelope: .asciz "schema\0registry_id\0package_id\0release_id\0manifest_sha256\0publication\0"
r2_fields_task: .asciz "schema\0id\0package_id\0manifest_sha256\0state\0upload_expires_at\0objects\0failure\0release\0"
r2_fields_task_object: .asciz "sha256\0bytes\0received\0"
r2_fields_failure: .asciz "code\0detail\0retryable\0"
r2_fields_task_release: .asciz "manifest_url\0metadata_url\0"
r2_k_state: .asciz "state"
r2_k_upload_expires_at: .asciz "upload_expires_at"
r2_k_objects: .asciz "objects"
r2_k_received: .asciz "received"
r2_k_failure: .asciz "failure"
r2_k_release: .asciz "release"
r2_k_code: .asciz "code"
r2_k_detail: .asciz "detail"
r2_k_retryable: .asciz "retryable"
r2_k_manifest_url: .asciz "manifest_url"
r2_k_metadata_url: .asciz "metadata_url"
r2_task_states: .asciz "accepted\0uploading\0checking\0committed\0distributing\0published\0"
r2_published_state: .asciz "published"
r2_timestamp_shape: .asciz "0000-00-00T00:00:00Z"
r2_registries_prefix: .asciz "registries/"
r2_releases_path: .asciz "/releases/"
r2_policy_suffix: .asciz "/policy.tsv"
r2_json_suffix: .asciz ".json"
r2_blobs_path: .asciz "/blobs/sha256/"
r2_selection_query: .asciz "?x-asm="
r2_adapter_command: .asciz "registry-target"
r2_policy_header: .asciz "# asm-registry-policy-v2"
r2_origin_prefix: .asciz "v2:"
r2_fetched_json: .asciz "{\"ok\":true,\"authenticated\":true,\"executed\":false}\n"
r2_unchanged_json: .asciz "{\"ok\":true,\"authenticated\":true,\"unchanged\":true,\"executed\":false}\n"
r2_artifacts_path: .asciz "/artifacts/"
r2_k_schema: .asciz "schema"
r2_k_name: .asciz "name"
r2_k_version: .asciz "version"
r2_k_owner_id: .asciz "owner_id"
r2_k_summary: .asciz "summary"
r2_k_license: .asciz "license"
r2_k_source: .asciz "source"
r2_k_path: .asciz "path"
r2_k_repository: .asciz "repository"
r2_k_commit: .asciz "commit"
r2_k_algorithm: .asciz "algorithm"
r2_k_digest: .asciz "digest"
r2_k_archive: .asciz "archive"
r2_k_sha256: .asciz "sha256"
r2_k_bytes: .asciz "bytes"
r2_k_artifacts: .asciz "artifacts"
r2_k_cpu_features: .asciz "cpu_features"
r2_k_kind: .asciz "kind"
r2_k_isa: .asciz "isa"
r2_k_os: .asciz "os"
r2_k_abi: .asciz "abi"
r2_k_format: .asciz "format"
r2_fields_manifest: .asciz "artifacts\0license\0name\0owner_id\0schema\0source\0summary\0version\0dependencies\0"
r2_fields_source: .asciz "archive\0commit\0path\0repository\0"
r2_fields_commit: .asciz "algorithm\0digest\0"
r2_fields_archive: .asciz "bytes\0sha256\0"
r2_fields_artifact: .asciz "abi\0bytes\0cpu_features\0format\0isa\0kind\0os\0sha256\0"
r2_git_sha1: .asciz "git-sha1"
r2_git_sha256: .asciz "git-sha256"
r2_tar_gzip: .asciz "tar.gz"
r2_isa_x86: .asciz "x86_64"
r2_isa_arm: .asciz "aarch64"
r2_isa_riscv: .asciz "riscv64"
r2_os_linux: .asciz "linux"
r2_os_macos: .asciz "macos"
r2_os_windows: .asciz "windows"
r2_abi_x86: .asciz "sysv-amd64"
r2_abi_arm: .asciz "aapcs64"
r2_abi_riscv: .asciz "lp64d"
r2_abi_macos: .asciz "apple-arm64"
r2_abi_win_x86: .asciz "windows-x64"
r2_abi_win_arm: .asciz "windows-arm64"
r2_format_elf: .asciz "elf"
r2_format_macho: .asciz "macho"
r2_format_pe: .asciz "pe"
r2_target_x86: .asciz "x86_64-linux"
r2_target_arm: .asciz "aarch64-linux"
r2_target_riscv: .asciz "riscv64-linux"
r2_target_macos: .asciz "aarch64-macos"
r2_target_win_x86: .asciz "x86_64-windows"
r2_target_win_arm: .asciz "aarch64-windows"
.balign 8
r2_tuples:
    .quad r2_target_x86,r2_isa_x86,r2_os_linux,r2_abi_x86,r2_format_elf
    .quad r2_target_arm,r2_isa_arm,r2_os_linux,r2_abi_arm,r2_format_elf
    .quad r2_target_riscv,r2_isa_riscv,r2_os_linux,r2_abi_riscv,r2_format_elf
    .quad r2_target_macos,r2_isa_arm,r2_os_macos,r2_abi_macos,r2_format_macho
    .quad r2_target_win_x86,r2_isa_x86,r2_os_windows,r2_abi_win_x86,r2_format_pe
    .quad r2_target_win_arm,r2_isa_arm,r2_os_windows,r2_abi_win_arm,r2_format_pe
r2_task_text: .asciz "Publication task "
r2_task_separator: .asciz ": "
r2_task_note: .asciz ".\n"
r2_err_arguments: .asciz "invalid registry V2 arguments; use asm registry --help"
r2_err_manifest: .asciz "invalid registry V2 metadata or declared bytes; correct the manifest and retry the same task only with identical bytes"
r2_err_io: .asciz "registry V2 requires protected regular files and directories; check ownership, links, permissions and free space"
r2_err_http: .asciz "registry V2 request failed; inspect the task with a current credential before retrying the same key"
r2_err_credential: .asciz "publication credential was refused; obtain a current credential before retrying the same task"
r2_err_scope: .asciz "publication scope was refused; request access to the exact owner, package and operation"
r2_err_expired: .asciz "publication upload reservation expired; create a new task with a fresh key and current credential"
r2_err_trust: .asciz "registry V2 authentication or policy failed; check the registry identity, trusted root, clock and mirrors"
r2_err_upgrade: .asciz "this installation uses registry V2; V1 upgrade cannot change its authority; use the exact asm registry install command"
r2_help_text:
    .ascii "Usage: asm registry resolve|sync --project DIR --registry-id ID --root FILE\n"
    .ascii "  --state DIR --mirror HTTPS_BASE --target TARGET [--ca FILE] [--json]\n"
    .ascii "Resolve writes a complete graph lock. Sync restores exact source packages.\n"
    .ascii "Build checks local locked bytes; sync checks current registry policy.\n\n"
    .ascii "Usage: asm registry publish --project REPO_ROOT --name OWNER/NAME --owner-id 32HEX\n"
    .ascii "         --summary TEXT --license SPDX [--commit FULL_COMMIT] [--source-path PATH]\n"
    .ascii "         [--repository HTTPS_URL] [--source-target TARGET ...]\n"
    .ascii "         [--executable TARGET FILE ...] --credential-file FILE --api HTTPS_BASE\n"
    .ascii "         --idempotency-key 32HEX [--ca FILE] [--json]\n"
    .ascii "Usage: asm registry publish --manifest FILE --objects-dir DIR\n"
    .ascii "         --credential-file FILE --api HTTPS_BASE --idempotency-key 32HEX [--json]\n"
    .ascii "       asm registry task ID --credential-file FILE --api HTTPS_BASE [--json]\n"
    .ascii "       asm registry fetch|install OWNER/NAME@VERSION --registry-id 32HEX\n"
    .ascii "         --root ROOTFILE --state STATE --mirror HTTPS_BASE (up to three)\n"
    .ascii "         [--ca FILE] --target TARGET --kind source|executable --output PATH\n"
    .ascii "       asm registry install uses the same options and requires a host executable.\n"
    .ascii "Fetch and install require clean absolute ROOT, STATE and CA paths.\n"
    .ascii "Objects use their SHA-256 digest as the filename. Credentials stay outside argv.\n"
    .ascii "Project mode reads only the selected local commit (default HEAD), never dirty files.\n"
    .ascii "Select at least one artifact; up to six source targets and six executable files.\n"
    .ascii "It requires Git and gzip. It does not build, execute, or resolve dependencies.\n"
    .ascii "Exact V2 commands never fall back to V1. Installation never executes a package.\n"
    .byte 0
.balign 16
r2_helper_bytes:
.incbin "build/asm-verify-aarch64-linux"
r2_helper_end:
.equ r2_helper_length, r2_helper_end-r2_helper_bytes
.section .bss
.balign 8
r2_mode: .skip 8
r2_fields: .skip 8
r2_selector: .skip 8
r2_manifest: .skip 8
r2_objects_dir: .skip 8
r2_credential: .skip 8
r2_api: .skip 8
r2_key: .skip 8
r2_registry_id: .skip 8
r2_root: .skip 8
r2_state: .skip 8
r2_ca: .skip 8
r2_target: .skip 8
r2_kind: .skip 8
r2_output: .skip 8
r2_mirrors: .skip 24
r2_mirror_count: .skip 8
r2_object_count: .skip 8
r2_objects: .skip R2_OBJECTS * R2_RECORD
r2_stat: .skip 144
r2_path: .skip 4096
r2_cwd: .skip 4096
r2_header_path: .skip 96
r2_helper_path: .skip 96
r2_object_path: .skip 160
r2_header: .skip 256
r2_token: .skip 78
r2_key_buffer: .skip 256
r2_task_id: .skip 33
r2_returned_task: .skip 33
r2_header_argument: .skip 100
r2_body_argument: .skip 4100
r2_url: .skip 4096
r2_response: .skip R2_CONTROL + 1
r2_response_length: .skip 8
r2_http_argv: .skip 256
r2_http_method: .skip 8
r2_pipe: .skip 8
r2_status: .skip 8
r2_status_length: .skip 8
r2_child_status: .skip 8
r2_child_file_limit: .skip 8
r2_rlimit: .skip 16
r2_manifest_data: .skip R2_CONTROL + 1
r2_manifest_length: .skip 8
r2_dependency_count: .skip 8
r2_dependencies: .skip 64 * 240
r2_name: .skip 105
r2_version: .skip 33
r2_owner_id: .skip 33
r2_summary: .skip 161
r2_license: .skip 64
r2_source_path: .skip 241
r2_repository: .skip 1025
r2_commit: .skip 65
r2_source_sha: .skip 65
r2_source_bytes: .skip 8
r2_digest: .skip 65
r2_total_bytes: .skip 8
r2_tuple_bits: .skip 8
r2_selected: .skip 8
r2_selected_sha: .skip 65
r2_selected_bytes: .skip 8
r2_requested_name: .skip 170
r2_requested_version: .skip 33
r2_root_data: .skip INDEX_LIMIT + 1
r2_root_sha: .skip 65
r2_envelope: .skip INDEX_LIMIT + 1
r2_envelope_sha: .skip 65
r2_package_id: .skip 33
r2_release_id: .skip 33
r2_manifest_sha: .skip 65
r2_target_path: .skip 512
r2_adapter_argv: .skip 80
r2_adapter_output: .skip 4096
r2_policy: .skip INDEX_LIMIT + 1
r2_policy_cursor: .skip 8
r2_policy_end: .skip 8
r2_policy_fields: .skip 48
r2_previous_name: .skip 105
r2_previous_version: .skip 33
r2_blob_argv: .skip 160
r2_size_decimal: .skip 32
r2_size_pointer: .skip 8
r2_synthetic_row: .skip 64
r2_origin_receipt: .skip 256
r2_task_package: .skip 33
r2_task_manifest: .skip 65
r2_task_state: .skip 16
r2_timestamp: .skip 21
r2_task_digest: .skip 65
r2_previous_digest: .skip 65
r2_task_total: .skip 8
r2_task_object_bytes: .skip 8
r2_task_received: .skip 8
r2_task_detail: .skip 1024
r2_active: .skip 1
r2_post_attempted: .skip 1
.include "cli/aarch64/registry_project.s"
