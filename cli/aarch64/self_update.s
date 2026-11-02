/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.global cmd_self, self_update_cleanup

/* Manual updates operate only on HOME/.local/bin/asm. An open directory and
 * nonblocking advisory lock coordinate ASM invocations. The directory and
 * executable must belong to the calling UID, without group/other write bits.
 * A same-account process can ignore the lock; this is not a local sandbox.
 * All returning routines preserve SysV callee-saved registers. Command and
 * error labels terminate. Borrowed arguments are kernel-terminated strings.
 */
.section .text
cmd_self:
    ARM_CALL self_current_version
.Lself_arguments:
    ARM_CALL next_arg
    tst x9, x9
    b.eq .Lself_arguments_done
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, opt_help
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne self_help
    mov x0, x21
    ARM_ADDR x16, opt_json
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lself_json_option
    mov x0, x21
    ARM_ADDR x16, opt_no_color
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.ne .Lself_arguments
    ARM_ADDR x16, self_has_update
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_version_argument
    mov x0, x21
    ARM_ADDR x16, command_update
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq self_bad_arguments
    ARM_IMM w10, 1
    ARM_ADDR x16, self_has_update
    strb w10, [x16]
    b .Lself_arguments
.Lself_version_argument:
    ARM_ADDR x16, registry_exact_version
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne self_bad_arguments
    mov x0, x21
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq self_bad_arguments
    ARM_ADDR x16, registry_exact_version
    str x21, [x16]
    b .Lself_arguments
.Lself_json_option:
    ARM_IMM w10, 1
    ARM_ADDR x16, json_mode
    strb w10, [x16]
    b .Lself_arguments
.Lself_arguments_done:
    ARM_ADDR x16, self_has_update
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq self_help
    ARM_ADDR x16, registry_exact_version
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.eq .Lself_open
    ARM_ADDR x16, self_version
    mov x1, x16
    ARM_CALL registry_version_compare
    ARM_IMM w11, 0
    cmp w9, w11
    b.lt self_downgrade
.Lself_open:
    ARM_IMM w10, 1
    ARM_ADDR x16, self_active
    strb w10, [x16]
    ARM_CALL self_open_installation
    ARM_ADDR x16, registry_exact_version
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.eq .Lself_begin
    ARM_ADDR x16, self_version
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
.ifndef ASM_TRUSTED_DISTRIBUTION
    b.ne self_unchanged
.endif
.Lself_begin:
    ARM_CALL registry_workspace
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_IMM w10, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi self_io_error
    ARM_ADDR x16, self_stage_fd
    str x9, [x16]
    mov x0, x9
    ARM_ADDR x16, self_stage_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi self_io_error
    ARM_CALL self_prepare_verifier
    /* Only bounded standard proxy variables reach transport and hashing.
     * No ambient CA, credential, or tool configuration is inherited. */
    ARM_ADDR x16, self_network_environment
    mov x9, x16
    ARM_ADDR x16, envp
    str x9, [x16]
    ARM_ADDR x16, self_package
    mov x9, x16
    ARM_ADDR x16, registry_query
    str x9, [x16]
    ARM_ADDR x16, registry_host
    mov x9, x16
    ARM_ADDR x16, registry_target
    str x9, [x16]
    ARM_ADDR x16, registry_executable_kind
    mov x9, x16
    ARM_ADDR x16, registry_kind
    str x9, [x16]
.ifdef ASM_TRUSTED_DISTRIBUTION
    ARM_CALL self_authenticated_index
.else
    ARM_ADDR x16, registry_default_url
    mov x0, x16
    ARM_ADDR x16, registry_temp_index
    mov x1, x16
    ARM_ADDR x16, registry_index_max
    mov x2, x16
    ARM_CALL registry_download
    tst w9, w9
    b.ne self_download_error
.endif
    ARM_ADDR x16, registry_temp_index
    mov x9, x16
    ARM_ADDR x16, registry_index_path
    str x9, [x16]
    ARM_CALL registry_read_index
    ARM_CALL registry_parse_index
    ARM_CALL registry_select
    tst x9, x9
    b.eq self_not_found
    mov x19, x9
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_version
    mov x1, x16
    ARM_CALL registry_version_compare
    ARM_IMM w11, 0
    cmp w9, w11
    b.lt self_downgrade
    b.eq self_unchanged
    ARM_CALL self_release_paths
    mov x16, x19
    add x16, x16, #40
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_asset_url
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq self_release_error
    mov x16, x19
    add x16, x16, #48
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_size_value
    ARM_ADDR x16, registry_expected_size
    str x9, [x16]
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
    b.ne self_download_error
    ARM_CALL registry_verify_payload
    ARM_ADDR x16, registry_temp_payload
    mov x0, x16
    ARM_ADDR x16, registry_expected_size
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL validate_host_elf
    tst w9, w9
    b.eq registry_install_elf_error
    /* This gate verifies the manifest, its source binding, and the exact
     * payload. It returns only after every required provenance check passes. */
    ARM_CALL self_verify_release
.ifdef ASM_TRUSTED_DISTRIBUTION
    ARM_CALL self_authorize_candidate
.endif
    ARM_CALL self_commit_update
    ARM_CALL self_update_cleanup
    ARM_ADDR x16, json_mode
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_success_json
    ARM_ADDR x16, self_updated_text
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL out
    ARM_ADDR x16, self_updated_suffix
    mov x0, x16
    ARM_CALL out
    b exit_ok
.Lself_success_json:
    ARM_ADDR x16, self_success_json
    mov x0, x16
    ARM_CALL out
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL registry_json_string
    ARM_ADDR x16, self_success_suffix
    mov x0, x16
    ARM_CALL out
    b exit_ok

self_unchanged:
    ARM_CALL self_update_cleanup
    ARM_ADDR x16, self_unchanged_text
    mov x0, x16
    ARM_ADDR x16, self_unchanged_json
    mov x1, x16
    ARM_CALL report
    b exit_ok
self_help:
    ARM_ADDR x16, self_help_text
    mov x0, x16
    ARM_CALL out
    b exit_ok
self_bad_arguments:
    ARM_ADDR x16, self_error_arguments
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b self_fail
self_downgrade:
    ARM_ADDR x16, self_error_downgrade
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_installation_error:
    ARM_ADDR x16, self_error_installation
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_permissions_error:
    ARM_ADDR x16, self_error_permissions
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_busy:
    ARM_ADDR x16, self_error_busy
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_changed:
    ARM_ADDR x16, self_error_changed
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_filesystem_error:
    ARM_ADDR x16, self_error_filesystem
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_io_error:
    ARM_ADDR x16, self_error_io
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_download_error:
    ARM_ADDR x16, self_error_download
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_release_error:
    ARM_ADDR x16, self_error_release
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_not_found:
    ARM_ADDR x16, self_error_not_found
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_fail:
    ARM_SAVE x0
    ARM_SAVE x1
    ARM_CALL self_update_cleanup
    ARM_RESTORE x1
    ARM_RESTORE x0
    b die

/* Read the trusted version_text prefix. Output: self_version (33 bytes).
 * No duplicated release version constant is introduced. Scratch: caller-save
 * registers; stack 16 alignment bytes. A malformed version fails closed. */
self_current_version:
    sub sp, sp, #16
    ARM_ADDR x16, version_text + 4
    mov x1, x16
    ARM_ADDR x16, self_version
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
.Lself_current_character:
    ARM_IMM w11, 32
    cmp w3, w11
    b.hi self_bad_arguments
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_current_end
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq self_bad_arguments
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lself_current_character
.Lself_current_end:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq self_bad_arguments
    add sp, sp, #16
    ret

/* Open a direct per-user installation. The shared parent walk checks every
 * ancestor, refusing links, empty components, '.' and '..'. HOME and its
 * descendants must belong to the real/effective UID without unsafe writes.
 * Output: held parent/current FDs and a directory flock; cwd becomes parent.
 * Owned path buffers are 4096 bytes. Stack: 80 saved bytes. */
self_open_installation:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_CALL arm_getuid
    ARM_ADDR x16, self_uid
    str w9, [x16]
    mov w21, w9
    ARM_CALL arm_geteuid
    cmp w9, w21
    b.ne self_permissions_error
    ARM_CALL arm_getgid
    mov w21, w9
    ARM_CALL arm_getegid
    cmp w9, w21
    b.ne self_permissions_error
    ARM_ADDR x16, envp
    ldr x10, [x16]
    mov x21, x10
.Lself_find_home:
    mov x16, x21
    ldr x10, [x16]
    mov x0, x10
    tst x0, x0
    b.eq self_installation_error
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 72
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_next_env
    mov x16, x0
    add x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 79
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_next_env
    mov x16, x0
    add x16, x16, #2
    ldrb w10, [x16]
    ARM_IMM w11, 77
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_next_env
    mov x16, x0
    add x16, x16, #3
    ldrb w10, [x16]
    ARM_IMM w11, 69
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_next_env
    mov x16, x0
    add x16, x16, #4
    ldrb w10, [x16]
    ARM_IMM w11, 61
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_home_found
.Lself_next_env:
    ARM_IMM x11, 8
    adds x21, x21, x11
    b .Lself_find_home
.Lself_home_found:
    mov x16, x0
    add x16, x16, #5
    mov x1, x16
    mov x16, x1
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne self_installation_error
    mov x0, x1
    mov x21, x1
    ARM_CALL strlen
    ARM_IMM x11, 2
    cmp x9, x11
    b.lo self_installation_error
    ARM_IMM x11, 3900
    cmp x9, x11
    b.hi self_installation_error
    mov x16, x21
    add x16, x16, x9
    sub x16, x16, #1
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq self_installation_error
    ARM_ADDR x16, self_home_length
    str x9, [x16]
    ARM_ADDR x16, self_install_path
    mov x0, x16
    mov x1, x21
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_install_suffix
    mov x1, x16
    ARM_CALL copy_string
    /* copy_string returns the terminator. Exclude the constructed /asm. */
    ARM_ADDR x16, self_parent_path
    mov x0, x16
    ARM_ADDR x16, self_install_path
    mov x1, x16
    mov x3, x9
    subs x3, x3, x1
    ARM_IMM x11, 4
    subs x3, x3, x11
    cbz x3, .Lport_self_update_1_end
.Lport_self_update_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lport_self_update_1
.Lport_self_update_1_end:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_ADDR x16, self_proc_exe
    mov x0, x16
    ARM_ADDR x16, self_exe_path
    mov x1, x16
    ARM_IMM w10, 4095
    mov w2, w10
    ARM_CALL arm_readlink
    tst x9, x9
    b.mi self_installation_error
    ARM_IMM x11, 4095
    cmp x9, x11
    b.hs self_installation_error
    ARM_ADDR x16, self_exe_path
    mov x0, x16
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x9
    strb w10, [x16]
    ARM_ADDR x16, self_install_path
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq self_installation_error
    ARM_ADDR x16, self_proc_exe
    mov x0, x16
    ARM_IMM w10, O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi self_installation_error
    ARM_ADDR x16, self_current_fd
    str x9, [x16]
    mov x0, x9
    ARM_ADDR x16, self_current_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi self_installation_error
    ARM_ADDR x16, self_current_stat
    mov x0, x16
    ARM_CALL self_check_file_stat
    tst w9, w9
    b.eq self_permissions_error
    ARM_ADDR x16, self_current_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 511
    and w9, w9, w11
    tst w9, w9
    ARM_ADDR x16, self_file_mode
    str w9, [x16]
    ARM_CALL self_open_parent
    ARM_IMM x11, -2
    cmp x9, x11
    b.eq self_permissions_error
    tst x9, x9
    b.mi self_installation_error
    ARM_ADDR x16, self_parent_fd
    str x9, [x16]
    mov x0, x9
    ARM_ADDR x16, self_parent_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi self_installation_error
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_IMM w10, 6
    mov w1, w10
    ARM_CALL arm_flock
    ARM_IMM x11, -11
    cmp x9, x11
    b.eq self_busy
    tst x9, x9
    b.mi self_filesystem_error
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_filesystem_stat
    mov x1, x16
    ARM_CALL arm_fstatfs
    tst x9, x9
    b.mi self_filesystem_error
    ARM_ADDR x16, self_filesystem_stat
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61267
    cmp w9, w11
    b.eq .Lself_local_filesystem
    ARM_IMM w11, 1481003842
    cmp w9, w11
    b.eq .Lself_local_filesystem
    ARM_IMM w11, 2435016766
    cmp w9, w11
    b.eq .Lself_local_filesystem
    ARM_IMM w11, 16914836
    cmp w9, w11
    b.eq .Lself_local_filesystem
    ARM_IMM w11, 2035054128
    cmp w9, w11
    b.eq .Lself_local_filesystem
    ARM_IMM w11, 4076150800
    cmp w9, w11
    b.ne self_filesystem_error
.Lself_local_filesystem:
    ARM_CALL self_check_destination
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arm_fchdir
    tst x9, x9
    b.mi self_installation_error
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Open the absolute installation parent from /. Input: bounded, constructed
 * self_install_path and self_home_length. Output: x9=owned parent FD, -1 for
 * an invalid/inaccessible path, or -2 for unsafe ownership or write access.
 * Every directory, including /, must belong to root or this UID. HOME and
 * its descendants must belong to this UID. No group/other writes are allowed
 * except at exact root-owned sticky /tmp above HOME; its immediate child must
 * belong to this UID and deny group/other writes. An arbitrary sticky path
 * is not an exception. Each open uses O_DIRECTORY|O_NOFOLLOW. The walk does
 * not change cwd or held installation descriptors. It restores temporary NUL
 * separators and closes its FD on failure. Scratch: caller-save, stat buffer;
 * stack: 80 saved bytes. The process is single-threaded. */
self_open_parent:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, self_root
    mov x0, x16
    ARM_IMM w10, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lself_walk_open_error
    mov x24, x9
    mov x0, x9
    ARM_ADDR x16, self_check_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lself_walk_bad_permissions
    ARM_ADDR x16, self_check_stat + 24
    ldr w10, [x16]
    mov w9, w10
    tst w9, w9
    b.eq .Lself_root_mode
    ARM_ADDR x16, self_uid
    ldr w11, [x16]
    cmp w9, w11
    b.ne .Lself_walk_bad_permissions
.Lself_root_mode:
    ARM_ADDR x16, self_check_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 18
    tst w10, w11
    b.ne .Lself_walk_bad_permissions
    ARM_ADDR x16, self_install_path
    mov x21, x16
    mov x16, x21
    add x16, x16, #1
    mov x22, x16
    eor w19, w19, w19
    tst w19, w19
.Lself_walk_component:
    mov x23, x22
.Lself_walk_scan:
    mov x16, x23
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lself_walk_complete
    and w10, w9, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_walk_open
    ARM_IMM x11, 1
    adds x23, x23, x11
    b .Lself_walk_scan
.Lself_walk_open:
    cmp x23, x22
    b.eq .Lself_walk_bad_path
    ARM_IMM w10, 0
    mov x16, x23
    strb w10, [x16]
    mov x16, x22
    ldrh w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lself_walk_bad_component
    mov x16, x22
    ldrh w10, [x16]
    ARM_IMM w11, 11822
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lself_component_open
    mov x16, x22
    add x16, x16, #2
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_walk_bad_component
.Lself_component_open:
    mov x0, x24
    mov x1, x22
    ARM_IMM w10, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    ARM_IMM w10, 47
    mov x16, x23
    strb w10, [x16]
    tst x9, x9
    b.mi .Lself_walk_bad_path
    mov x0, x24
    mov x24, x9
    ARM_CALL arm_close
    mov x0, x24
    ARM_ADDR x16, self_check_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lself_walk_bad_permissions
    mov x2, x23
    subs x2, x2, x21
    ARM_ADDR x16, self_check_stat + 24
    ldr w10, [x16]
    mov w9, w10
    tst w19, w19
    b.ne .Lself_component_user
    ARM_ADDR x16, self_home_length
    ldr x11, [x16]
    cmp x2, x11
    b.hs .Lself_component_user
    tst w9, w9
    b.eq .Lself_component_mode
.Lself_component_user:
    ARM_ADDR x16, self_uid
    ldr w11, [x16]
    cmp w9, w11
    b.ne .Lself_walk_bad_permissions
.Lself_component_mode:
    ARM_ADDR x16, self_check_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 18
    tst w10, w11
    b.eq .Lself_component_protected
    tst w19, w19
    b.ne .Lself_walk_bad_permissions
    ARM_ADDR x16, self_home_length
    ldr x11, [x16]
    cmp x2, x11
    b.hs .Lself_walk_bad_permissions
    ARM_IMM w11, 4
    cmp w2, w11
    b.ne .Lself_walk_bad_permissions
    mov x16, x21 /* exact /tmp */
    ldr w10, [x16]
    ARM_IMM w11, 1886221359
    cmp w10, w11
    b.ne .Lself_walk_bad_permissions
    ARM_ADDR x16, self_check_stat + 24
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne .Lself_walk_bad_permissions
    ARM_ADDR x16, self_check_stat + 16
    ldr w10, [x16]
    ARM_IMM w11, 512
    tst w10, w11
    b.eq .Lself_walk_bad_permissions
    ARM_IMM w10, 1
    mov w19, w10
    b .Lself_component_next
.Lself_component_protected:
    eor w19, w19, w19
    tst w19, w19
.Lself_component_next:
    mov x16, x23
    add x16, x16, #1
    mov x22, x16
    b .Lself_walk_component
.Lself_walk_complete:
    /* The final component was constructed as asm, never supplied by input. */
    mov x9, x24
    b .Lself_walk_return
.Lself_walk_bad_component:
    ARM_IMM w10, 47
    mov x16, x23
    strb w10, [x16]
.Lself_walk_bad_path:
    ARM_IMM w10, -1
    mov w19, w10
    b .Lself_walk_close
.Lself_walk_bad_permissions:
    ARM_IMM w10, -2
    mov w19, w10
.Lself_walk_close:
    mov x0, x24
    ARM_CALL arm_close
    sxtw x9, w19
    b .Lself_walk_return
.Lself_walk_open_error:
    ARM_IMM x10, -1
    mov x9, x10
.Lself_walk_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Rewalk and validate the expected absolute path, then require its parent
 * and executable to match the held installation. Called before every verifier
 * child and immediately before the final rename. This catches displaced
 * directories as well as changed file entries; descriptor-relative writes
 * remain authoritative. A noncooperating same-UID race is outside the lock's
 * boundary. No input; no return on mismatch. Owns one temporary FD, always
 * closed. Stack: 16 saved bytes; scratch caller-save and self_check_stat. */
self_check_absolute_installation:
    ARM_SAVE x21
    ARM_CALL self_open_parent
    tst x9, x9
    b.mi self_changed
    mov x21, x9
    mov x0, x9
    ARM_ADDR x16, self_check_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lself_absolute_changed
    ARM_ADDR x16, self_check_stat
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, self_parent_stat
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lself_absolute_changed
    ARM_ADDR x16, self_check_stat + 8
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, self_parent_stat + 8
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lself_absolute_changed
    mov x0, x21
    ARM_CALL arm_close
    tst x9, x9
    b.mi self_changed
    ARM_CALL self_check_destination
    ARM_RESTORE x21
    ret
.Lself_absolute_changed:
    mov x0, x21
    ARM_CALL arm_close
    b self_changed

/* x0=Linux AArch64 stat structure (128 bytes). w9=1 only for a single-link
 * regular executable owned by this UID, with no set-ID or unsafe write bits.
 * Reads only; clobbers x9/x2. */
self_check_file_stat:
    mov x16, x0
    add x16, x16, #20
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne .Lself_bad_stat
    mov x16, x0
    add x16, x16, #24
    ldr w10, [x16]
    mov w9, w10
    ARM_ADDR x16, self_uid
    ldr w11, [x16]
    cmp w9, w11
    b.ne .Lself_bad_stat
    mov x16, x0
    add x16, x16, #16
    ldr w10, [x16]
    mov w9, w10
    mov w2, w9
    ARM_IMM w11, 61440
    and w2, w2, w11
    tst w2, w2
    ARM_IMM w11, 32768
    cmp w2, w11
    b.ne .Lself_bad_stat
    ARM_IMM w11, 3090
    tst w9, w11
    b.ne .Lself_bad_stat
    ARM_IMM w11, 64
    tst w9, w11
    b.eq .Lself_bad_stat
    ARM_IMM w10, 1
    mov w9, w10
    ret
.Lself_bad_stat:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Require the held directory entry to remain the exact executed inode.
 * Symlinks are inspected, never followed. No return on mismatch.
 * Stack: 16 alignment bytes. */
self_check_destination:
    sub sp, sp, #16
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_binary_name
    mov x1, x16
    ARM_ADDR x16, self_check_stat
    mov x2, x16
    ARM_IMM w10, 256
    mov w6, w10
    ARM_CALL arm_newfstatat
    tst x9, x9
    b.mi self_changed
    ARM_ADDR x16, self_check_stat
    mov x0, x16
    ARM_CALL self_check_file_stat
    tst w9, w9
    b.eq self_changed
    ARM_ADDR x16, self_check_stat
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, self_current_stat
    ldr x11, [x16]
    cmp x9, x11
    b.ne self_changed
    ARM_ADDR x16, self_check_stat + 8
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, self_current_stat + 8
    ldr x11, [x16]
    cmp x9, x11
    b.ne self_changed
    ARM_ADDR x16, self_check_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_ADDR x16, self_current_stat + 16
    ldr w11, [x16]
    cmp w9, w11
    b.ne self_changed
    add sp, sp, #16
    ret

/* Input: selected, validated row. Build exact official asset URLs and local
 * stage paths. All version fields are <=32 bytes, buffers >=512/96 bytes.
 * Preserves callee-saved registers; scratch caller-save and stack 16 bytes. */
self_release_paths:
    ARM_SAVE x19
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x19, x10
    ARM_ADDR x16, self_asset_filename
    mov x0, x16
    ARM_ADDR x16, self_asset_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_asset_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, self_release_base
    mov x0, x16
    ARM_ADDR x16, self_release_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x16, x19
    add x16, x16, #8
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL copy_string
    ARM_IMM w10, 47
    mov x16, x9
    strb w10, [x16]
    ARM_IMM w10, 0
    mov x16, x9
    add x16, x16, #1
    strb w10, [x16]
    ARM_ADDR x16, self_asset_url
    mov x0, x16
    ARM_ADDR x16, self_release_base
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_asset_filename
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, self_manifest_url
    mov x0, x16
    ARM_ADDR x16, self_release_base
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_manifest_name
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, self_bundle_url
    mov x0, x16
    ARM_ADDR x16, self_release_base
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_bundle_name
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, self_manifest_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_manifest_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, self_bundle_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_bundle_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_RESTORE x19
    ret

/* Commit only a fully verified private payload. File mode and bytes are
 * synced before the final identity check and atomic rename. Rename is the
 * final fallible mutation: its failure preserves the previous directory entry.
 * Directory crash durability and hostile same-UID races are outside scope.
 * Stack: one saved descriptor. */
self_commit_update:
    ARM_SAVE x21
    ARM_ADDR x16, self_stage_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_payload_name
    mov x1, x16
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w2, w10
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_openat
    tst x9, x9
    b.mi self_io_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, self_file_mode
    ldr w10, [x16]
    mov w1, w10
    ARM_CALL arm_fchmod
    tst x9, x9
    b.mi .Lself_commit_close_fail
    mov x0, x21
    ARM_CALL arm_fsync
    tst x9, x9
    b.mi .Lself_commit_close_fail
    mov x0, x21
    ARM_CALL arm_close
    tst x9, x9
    b.mi self_io_error
    ARM_CALL self_check_absolute_installation
    ARM_ADDR x16, self_stage_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_payload_name
    mov x1, x16
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x2, x10
    ARM_ADDR x16, self_binary_name
    mov x6, x16
    ARM_CALL arm_renameat
    tst x9, x9
    b.mi self_io_error
    ARM_RESTORE x21
    ret
.Lself_commit_close_fail:
    mov x0, x21
    ARM_CALL arm_close
    b self_io_error

/* Cleanup only the held private stage and descriptors owned by this command.
 * Native descriptor-relative traversal does not follow links. Never delete a
 * substituted stage directory entry. Cleanup errors do not turn a committed
 * update into a reported failure. Uses archive cleanup buffers exclusively. */
self_update_cleanup:
    ARM_ADDR x16, self_active
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_cleanup_done
    ARM_SAVE x21
    ARM_ADDR x16, self_stage_fd
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.lt .Lself_cleanup_without_stage
    ARM_ADDR x16, self_stage_fd
    ldr x10, [x16]
    mov x0, x10
    eor w1, w1, w1
    tst w1, w1
    ARM_IMM w10, 1
    mov w2, w10
    ARM_CALL arc_walk_tree
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_ADDR x16, self_check_stat
    mov x2, x16
    ARM_IMM w10, 256
    mov w6, w10
    ARM_CALL arm_newfstatat
    tst x9, x9
    b.mi .Lself_close_stage
    ARM_ADDR x16, self_check_stat
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, self_stage_stat
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lself_close_stage
    ARM_ADDR x16, self_check_stat + 8
    ldr x10, [x16]
    mov x9, x10
    ARM_ADDR x16, self_stage_stat + 8
    ldr x11, [x16]
    cmp x9, x11
    b.ne .Lself_close_stage
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_IMM w10, 512
    mov w2, w10
    ARM_CALL arm_unlinkat
.Lself_close_stage:
    ARM_ADDR x16, self_stage_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    ARM_IMM x10, -1
    ARM_ADDR x16, self_stage_fd
    str x10, [x16]
    b .Lself_cleanup_descriptors
.Lself_cleanup_without_stage:
    ARM_ADDR x16, registry_has_workspace
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_cleanup_descriptors
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_IMM w10, 512
    mov w2, w10
    ARM_CALL arm_unlinkat
.Lself_cleanup_descriptors:
    ARM_IMM w10, 0
    ARM_ADDR x16, registry_has_workspace
    strb w10, [x16]
    ARM_ADDR x16, self_current_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    ARM_IMM x10, -1
    ARM_ADDR x16, self_current_fd
    str x10, [x16]
    ARM_ADDR x16, self_parent_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_CALL arc_close
    ARM_IMM x10, -1
    ARM_ADDR x16, self_parent_fd
    str x10, [x16]
    ARM_IMM w10, 0
    ARM_ADDR x16, self_active
    strb w10, [x16]
    ARM_RESTORE x21
.Lself_cleanup_done:
    ret

.section .rodata
self_install_suffix: .asciz "/.local/bin/asm"
self_proc_exe: .asciz "/proc/self/exe"
self_root: .asciz "/"
self_binary_name: .asciz "asm"
self_payload_name: .asciz "payload"
self_package: .asciz "stubbi/asm"
self_release_prefix: .asciz "https://github.com/stubbi/asm/releases/download/v"
self_asset_prefix: .asciz "asm-"
self_asset_suffix: .asciz "-aarch64-linux"
self_manifest_name: .asciz "release.json"
self_bundle_name: .asciz "release-attestation.sigstore.json"
self_manifest_suffix: .asciz "/release.json"
self_bundle_suffix: .asciz "/release-attestation.sigstore.json"
self_updated_text: .asciz "Updated ASM to "
self_updated_suffix: .asciz ". Start a new command to use it.\n"
self_success_json: .asciz "{\"updated\":true,\"version\":"
self_success_suffix: .asciz ",\"integrity_verified\":true,\"provenance_verified\":true}\n"
self_unchanged_text: .asciz "No newer version was selected. The installed binary was not changed.\n"
self_unchanged_json: .asciz "{\"updated\":false,\"reason\":\"no-newer-version-selected\"}\n"
self_error_arguments: .asciz "invalid self arguments; use asm self --help"
self_error_downgrade: .asciz "self update refuses an older version; keep the current version or select a newer release"
self_error_installation: .asciz "self update requires the direct HOME/.local/bin/asm installation; use the bootstrap installer or your package manager"
self_error_permissions: .asciz "self update requires a single-link user-owned executable and protected path ancestors; check ownership and write permissions from / through HOME/.local/bin"
self_error_busy: .asciz "another update holds the installation lock; wait for it to finish and try again"
self_error_changed: .asciz "the installation path or executable changed during this operation; no replacement was made; start the installed command again"
self_error_filesystem: .asciz "self update requires a supported local filesystem; use your package manager or install the verified release manually"
self_error_io: .asciz "self update could not prepare or replace the executable; the previous binary remains; check free space and directory permissions"
self_error_download: .asciz "self update could not download required release files over HTTPS; the previous binary remains; check the connection and release"
self_error_release: .asciz "self update requires the exact official versioned ASM artifact; the previous binary remains; check the published release"
self_error_not_found: .asciz "no matching ASM host executable was found; check the requested version with asm versions stubbi/asm"
self_help_text:
    .ascii "Usage: asm self update [X.Y.Z] [--json] [--no-color]\n\n"
    .ascii "Manually update the direct HOME/.local/bin/asm installation.\n"
    .ascii "Uses stubbi/asm from https://asm.build. Older versions are refused.\n"
    .ascii "Requires /usr/bin/curl, sha256sum, and GitHub CLI gh >= 2.93.0.\n"
    .ascii "Checks size, SHA-256, host ELF, and release-workflow attestations.\n"
    .ascii "Does not execute the downloaded program or elevate privileges.\n"
    .ascii "No unattended update, metadata freshness, or revocation guarantee.\n"
    .ascii "Use your package manager for an installation that it owns.\n"
    .byte 0
.section .data
self_parent_fd: .quad -1
self_current_fd: .quad -1
self_stage_fd: .quad -1
.section .bss
.balign 8
self_home_length: .skip 8
self_uid: .skip 4
self_file_mode: .skip 4
self_active: .skip 1
self_has_update: .skip 1
self_version: .skip 33
self_install_path: .skip 4096
self_parent_path: .skip 4096
self_exe_path: .skip 4096
self_current_stat: .skip 128
self_parent_stat: .skip 128
self_check_stat: .skip 128
self_stage_stat: .skip 128
self_filesystem_stat: .skip 128
self_asset_filename: .skip 96
self_release_base: .skip 512
self_asset_url: .skip 512
self_manifest_url: .skip 512
self_bundle_url: .skip 512
self_manifest_path: .skip 96
self_bundle_path: .skip 96
