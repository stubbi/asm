/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native committed-project preparation for the optional registry V2 client.
 * All package, USTAR, selection and canonical-JSON policy remains assembly.
 * Fixed Git plumbing supplies committed objects; fixed gzip supplies compression.
 * Native AArch64 ABI: arguments x0-x7; result x9. Returning functions preserve x19/x20/x21-x24; other integer registers
 * and flags are scratch. ARM_CALL adds16 bytes beyond each stated local frame.
 * x18 is never used. Serial owned buffers: list3MiB, 4096 records32 bytes,
 * header512 bytes. Batch mapping <=64MiB+4096*96; unmapped before validation.
 * Private temporary source data peaks below193MiB; files are removed on exit.
 */
.equ R2P_LIST, 3145728
.equ R2P_FILES, 4096
.equ R2P_RECORD, 32
.equ R2P_BATCH, ARC_LIMIT + R2P_FILES * 96
.equ R2P_REQUIRED, 127004
.equ R2P_ALLOWED, R2P_REQUIRED | 131072 | 262144 | 524288 | 1048576
.section .text

/* x0=option. w9=1 if a repeated project selection was consumed, otherwise0.
 * Consumes one target and, for --executable, one path. Local frame48 bytes. */
r2p_option:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    mov x21, x0
    mov w11, w22
    eor w22, w22, w11
    tst w22, w22
    ARM_ADDR x16, r2p_opt_source_target
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2p_selection_option
    mov x0, x21
    ARM_ADDR x16, r2p_opt_executable
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2p_option_no
    ARM_IMM w22, 1
.Lr2p_selection_option:
    ARM_CALL registry_arg_value
    mov x0, x9
    ARM_CALL r2p_tuple
    lsl x16, x2, #1
    mov w3, w16
    mov w11, w22
    adds w3, w3, w11
    ARM_ADDR x16, r2p_selections
    ldr x10, [x16]
    lsrv x11, x10, x3
    and x11, x11, #1
    cmp x11, #0
    b.ne r2_arguments
    ARM_ADDR x16, r2p_selections
    ldr x10, [x16]
    mov x11, #1
    lslv x11, x11, x3
    orr x10, x10, x11
    ARM_ADDR x16, r2p_selections
    str x10, [x16]
    ARM_ADDR x16, r2_fields
    ldr x10, [x16]
    ARM_IMM x11, 1048576
    orr x10, x10, x11
    tst x10, x10
    ARM_ADDR x16, r2_fields
    str x10, [x16]
    mov w10, w22
    mov w11, w22
    tst w10, w11
    b.eq .Lr2p_option_yes
    mov w19, w2
    ARM_CALL registry_arg_value
    ARM_ADDR x16, r2p_executable_paths
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x9, [x16]
.Lr2p_option_yes:
    ARM_IMM w9, 1
    b .Lr2p_option_done
.Lr2p_option_no:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2p_option_done:
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=target. x9=approved tuple pointer, w2=index0..5; unknown=>exit2. */
r2p_tuple:
    ARM_SAVE x19
    ARM_SAVE x21
    sub sp, sp, #16
    mov x21, x0
    ARM_ADDR x16, r2_tuples
    mov x19, x16
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
.Lr2p_tuple_loop:
    mov x0, x21
    mov x16, x19
    ldr x1, [x16]
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2p_tuple_found
    ARM_IMM w11, 1
    adds w2, w2, w11
    ARM_IMM x11, 40
    adds x19, x19, x11
    mov w10, w2
    ARM_IMM w11, 6
    cmp w10, w11
    b.lo .Lr2p_tuple_loop
    b r2_arguments
.Lr2p_tuple_found:
    mov x9, x19
    add sp, sp, #16
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Validate mode/metadata before opening project files. Local frame16 bytes. */
r2p_arguments:
    ARM_SAVE x19
    ARM_ADDR x16, r2_fields
    ldr x9, [x16]
    ARM_IMM x11, -257
    and x9, x9, x11
    tst x9, x9
    mov x2, x9
    ARM_IMM w11, R2P_REQUIRED
    and w9, w9, w11
    tst w9, w9
    mov w10, w9
    ARM_IMM w11, R2P_REQUIRED
    cmp w10, w11
    b.ne r2_arguments
    ARM_IMM x11, ~R2P_ALLOWED
    and x2, x2, x11
    tst x2, x2
    b.ne r2_arguments
    ARM_ADDR x16, r2p_selections
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq r2_arguments
    ARM_ADDR x16, r2p_name
    ldr x0, [x16]
    ARM_CALL registry_valid_package
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2p_owner
    ldr x0, [x16]
    ARM_IMM w1, 32
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2p_summary
    ldr x0, [x16]
    ARM_CALL strlen
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2_arguments
    mov x10, x9
    ARM_IMM x11, 160
    cmp x10, x11
    b.hi r2_arguments
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2_arguments
    mov x16, x0
    add x16, x16, x9
    ARM_IMM x17, 1
    sub x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2_arguments
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2p_summary_byte:
    mov x16, x0
    add x16, x16, x3
    ldrb w9, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2p_license
    mov w10, w9
    ARM_IMM w11, 32
    cmp w10, w11
    b.lo r2_arguments
    mov w10, w9
    ARM_IMM w11, 126
    cmp w10, w11
    b.hi r2_arguments
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2p_summary_byte
.Lr2p_license:
    ARM_ADDR x16, r2p_license
    ldr x0, [x16]
    ARM_ADDR x16, pub_licenses
    mov x1, x16
    ARM_CALL pub_in_strings
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2p_source_path
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.ne .Lr2p_path_check
    ARM_ADDR x16, pub_dot
    mov x9, x16
    ARM_ADDR x16, r2p_source_path
    str x9, [x16]
.Lr2p_path_check:
    ARM_ADDR x16, r2p_source_path
    ldr x0, [x16]
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x002e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2p_repository_check
    ARM_CALL pub_portable_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2_arguments
.Lr2p_repository_check:
    ARM_ADDR x16, r2p_repository
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr2p_commit_check
    ARM_CALL r2_repository_locator
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
.Lr2p_commit_check:
    ARM_ADDR x16, r2p_commit
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr2p_arguments_done
    ARM_CALL strlen
    mov w10, w9
    ARM_IMM w11, 40
    cmp w10, w11
    b.eq .Lr2p_commit_hex
    mov w10, w9
    ARM_IMM w11, 64
    cmp w10, w11
    b.ne r2_arguments
.Lr2p_commit_hex:
    mov w1, w9
    mov w19, w9
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2_arguments
    ARM_ADDR x16, r2p_commit
    ldr x0, [x16]
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2p_commit_zero:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 48
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2p_arguments_done
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    mov w11, w19
    cmp w10, w11
    b.lo .Lr2p_commit_zero
    b r2_arguments
.Lr2p_arguments_done:
    ARM_RESTORE x19
    ret

r2p_bad:
    ARM_ADDR x16, r2p_error
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
r2p_not_root:
    ARM_ADDR x16, r2p_error_root
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
r2p_lock_error:
    ARM_ADDR x16, r2p_error_lock
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail

/* x0=fixed workspace suffix. x9=owned r2p_path[160] string. Local frame16 bytes. */
r2p_path_for:
    ARM_SAVE x19
    mov x19, x0
    ARM_ADDR x16, r2p_path
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x1, x19
    ARM_CALL copy_string
    ARM_ADDR x16, r2p_path
    mov x9, x16
    ARM_RESTORE x19
    ret

/* x0=owned fixed path. x9=new private file FD>=3; no replacement. */
r2p_create:
    sub sp, sp, #16
    ARM_IMM w9, 2
    ARM_IMM w1, O_CLOEXEC + O_NOFOLLOW + 193
    ARM_IMM w2, 384
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x9
    ARM_CALL arc_promote_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    add sp, sp, #16
    ret

/* x0=owned path. x9=read FD>=3; file never follows a link. */
r2p_open:
    sub sp, sp, #16
    ARM_IMM w9, 2
    ARM_IMM w1, O_CLOEXEC + O_NOFOLLOW + O_NONBLOCK
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x9
    ARM_CALL arc_promote_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    add sp, sp, #16
    ret

/* x0=fixed executable, x1=direct argv, x2=input FD>=3, x3=output FD>=3,
 * x4=max output file bytes. Returns only after successful child exit. Children
 * run in opened repo FD, with closed inherited FDs on exec, fixed Git settings,
 * no secret, stderr /dev/null, a120s alarm and RLIMIT_FSIZE. Frame 112. */
r2p_run:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov x21, x0
    mov x22, x1
    mov x23, x2
    mov x24, x3
    ARM_ADDR x16, r2p_limit
    str x4, [x16]
    ARM_IMM w9, 57
    ARM_CALL arm_fork
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    b.eq .Lr2p_child
    mov x19, x9
.Lr2p_wait:
    ARM_IMM w9, 61
    mov x0, x19
    ARM_ADDR x16, r2p_child_status
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
    b.eq .Lr2p_wait
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2p_kill
    ARM_ADDR x16, r2p_child_status
    ldr w10, [x16]
    ARM_IMM w11, 0
    cmp w10, w11
    b.ne r2p_bad
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.Lr2p_kill:
    ARM_IMM w9, 62
    mov x0, x19
    ARM_IMM w1, 9
    ARM_CALL arm_kill
.Lr2p_failed_reap:
    ARM_IMM w9, 61
    mov x0, x19
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
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
    b.eq .Lr2p_failed_reap
    b r2p_bad
.Lr2p_child:
    ARM_IMM w9, 81
    ARM_ADDR x16, r2p_repo_fd
    ldr x0, [x16]
    ARM_CALL arm_fchdir
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2p_child_bad
    ARM_IMM w9, 33
    mov x0, x23
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_CALL arm_dup2
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2p_child_bad
    ARM_IMM w9, 33
    mov x0, x24
    ARM_IMM w1, 1
    ARM_CALL arm_dup2
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2p_child_bad
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
    b.mi .Lr2p_child_bad
    mov x20, x9
    ARM_IMM w9, 33
    mov x0, x20
    ARM_IMM w1, 2
    ARM_CALL arm_dup2
    mov x10, x20
    ARM_IMM x11, 2
    cmp x10, x11
    b.eq .Lr2p_child_signal
    ARM_IMM w9, 3
    mov x0, x20
    ARM_CALL arm_close
.Lr2p_child_signal:
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
    b.mi .Lr2p_child_bad
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
    b.mi .Lr2p_child_bad
    ARM_IMM w9, 37
    ARM_IMM w0, 120
    ARM_CALL arm_alarm
    ARM_IMM w9, 97
    ARM_IMM w0, 1
    ARM_ADDR x16, r2p_rlimit
    mov x1, x16
    ARM_CALL arm_getrlimit
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2p_child_bad
    ARM_ADDR x16, r2p_limit
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2p_rlimit
    ldr x11, [x16]
    cmp x10, x11
    ARM_ADDR x16, r2p_rlimit
    ldr x11, [x16]
    csel x9, x11, x9, hi
    ARM_ADDR x16, r2p_rlimit
    str x9, [x16]
    ARM_ADDR x16, r2p_limit
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2p_rlimit + 8
    ldr x11, [x16]
    cmp x10, x11
    ARM_ADDR x16, r2p_rlimit + 8
    ldr x11, [x16]
    csel x9, x11, x9, hi
    ARM_ADDR x16, r2p_rlimit + 8
    str x9, [x16]
    ARM_IMM w9, 160
    ARM_IMM w0, 1
    ARM_ADDR x16, r2p_rlimit
    mov x1, x16
    ARM_CALL arm_setrlimit
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi .Lr2p_child_bad
    ARM_IMM w9, 59
    mov x0, x21
    mov x1, x22
    ARM_ADDR x16, r2p_environment
    mov x2, x16
    ARM_CALL arm_execve
.Lr2p_child_bad:
    ARM_IMM w9, 60
    ARM_IMM w0, 127
    ARM_CALL arm_exit
    brk #0

/* x1=Git argv, x0=fixed suffix, x4=file cap. Creates a private output and
 * runs Git with /dev/null input; returns open read FD. Stack 80. */
r2p_git_file:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    mov x21, x1
    mov x22, x4
    ARM_CALL r2p_path_for
    mov x23, x9
    mov x0, x9
    ARM_IMM w9, 87
    ARM_CALL arm_unlink
    mov x0, x23
    ARM_CALL r2p_create
    mov x19, x9
    ARM_IMM w9, 2
    ARM_ADDR x16, self_dev_null
    mov x0, x16
    ARM_IMM w1, O_CLOEXEC
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x9
    ARM_CALL arc_promote_fd
    mov x23, x9
    ARM_ADDR x16, r2p_git
    mov x0, x16
    mov x1, x21
    mov x2, x23
    mov x3, x19
    mov x4, x22
    ARM_CALL r2p_run
    mov x0, x23
    ARM_CALL arc_close
    mov x0, x19
    ARM_CALL arc_close
    ARM_ADDR x16, r2p_path
    mov x0, x16
    ARM_CALL r2p_open
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Create all local inputs before a credential is read. Output: canonical
 * r2_manifest and owned digest objects suitable for the shared upload engine.
 * The selected commit alone supplies source bytes; no working file is read.
 * Stack 112. Terminal failures clean this invocation's private stage. */
r2_project_prepare:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_ADDR x16, r2p_project
    ldr x0, [x16]
    mov x16, x0
    ldrh w10, [x16]
    ARM_IMM w11, 0x002e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne .Lr2p_open_repo
    ARM_ADDR x16, r2_cwd
    mov x0, x16
.Lr2p_open_repo:
    ARM_IMM w1, 1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_CALL arc_promote_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_ADDR x16, r2p_repo_fd
    str x9, [x16]
    ARM_CALL r2p_credential_location
    ARM_ADDR x16, r2p_info_suffix
    mov x0, x16
    ARM_ADDR x16, r2p_prefix_argv
    mov x1, x16
    ARM_IMM w4, 4096
    ARM_CALL r2p_git_file
    mov x0, x9
    ARM_ADDR x16, r2p_info
    mov x1, x16
    ARM_IMM w2, 4096
    ARM_CALL r2_read_fd
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq .Lr2p_resolve_commit
    mov x10, x9
    ARM_IMM x11, 1
    cmp x10, x11
    b.ne r2p_not_root
    ARM_ADDR x16, r2p_info
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_not_root
.Lr2p_resolve_commit:
    ARM_ADDR x16, r2p_commit_spec
    mov x0, x16
    ARM_ADDR x16, r2p_commit
    ldr x1, [x16]
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.ne .Lr2p_commit_spec
    ARM_ADDR x16, r2p_head
    mov x1, x16
.Lr2p_commit_spec:
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, r2p_commit_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2p_info_suffix
    mov x0, x16
    ARM_ADDR x16, r2p_commit_argv
    mov x1, x16
    ARM_IMM w4, 80
    ARM_CALL r2p_git_file
    mov x0, x9
    ARM_ADDR x16, r2p_info
    mov x1, x16
    ARM_IMM w2, 80
    ARM_CALL r2_read_fd
    mov x10, x9
    ARM_IMM x11, 41
    cmp x10, x11
    b.eq .Lr2p_sha1
    mov x10, x9
    ARM_IMM x11, 65
    cmp x10, x11
    b.ne r2p_bad
    ARM_IMM w19, 64
    ARM_ADDR x16, r2_git_sha256
    mov x9, x16
    b .Lr2p_commit_length
.Lr2p_sha1:
    ARM_IMM w19, 40
    ARM_ADDR x16, r2_git_sha1
    mov x9, x16
.Lr2p_commit_length:
    ARM_ADDR x16, r2p_algorithm
    str x9, [x16]
    ARM_ADDR x16, r2p_oid_length
    str x19, [x16]
    ARM_ADDR x16, r2p_info
    mov x0, x16
    mov x16, x0
    add x16, x16, x19
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x19
    strb w10, [x16]
    mov w1, w19
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2p_bad
    ARM_ADDR x16, r2p_commit
    ldr x1, [x16]
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.eq .Lr2p_commit_copy
    ARM_ADDR x16, r2p_info
    mov x0, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2p_bad
.Lr2p_commit_copy:
    ARM_ADDR x16, r2_commit
    mov x0, x16
    ARM_ADDR x16, r2p_info
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_name
    mov x0, x16
    ARM_ADDR x16, r2p_name
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_owner_id
    mov x0, x16
    ARM_ADDR x16, r2p_owner
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_summary
    mov x0, x16
    ARM_ADDR x16, r2p_summary
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_license
    mov x0, x16
    ARM_ADDR x16, r2p_license
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2_source_path
    mov x0, x16
    ARM_ADDR x16, r2p_source_path
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2p_source_path
    ldr x9, [x16]
    ARM_ADDR x16, r2p_tree_argv + 12*8
    str x9, [x16]
    ARM_ADDR x16, r2p_tree_suffix
    mov x0, x16
    ARM_ADDR x16, r2p_tree_argv
    mov x1, x16
    ARM_IMM w4, R2P_LIST
    ARM_CALL r2p_git_file
    mov x0, x9
    ARM_ADDR x16, r2p_tree_data
    mov x1, x16
    ARM_IMM w2, R2P_LIST
    ARM_CALL r2_read_fd
    ARM_ADDR x16, r2p_tree_data
    mov x2, x16
    mov x11, x9
    adds x2, x2, x11
    ARM_ADDR x16, r2p_tree_end
    str x2, [x16]
    ARM_CALL r2p_collect
    ARM_CALL r2p_archive
    /* Validate once to inspect the committed manifest. The existing parser
     * checks inactive target inputs; only the expected version is omitted. */
    ARM_ADDR x16, r2_source_sha
    mov x0, x16
    ARM_CALL r2_object_stage_path
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_CALL validate_source_archive
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2p_bad
    ARM_ADDR x16, pub_manifest_name
    mov x0, x16
    ARM_CALL source_archive_member
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.eq r2p_bad
    mov w10, w3
    mov w11, w3
    tst w10, w11
    b.ne r2p_bad
    mov x10, x2
    ARM_IMM x11, PUB_TARGET_MANIFEST_MAX
    cmp x10, x11
    b.hi r2p_bad
    ARM_ADDR x16, r2_name
    mov x9, x16
    ARM_ADDR x16, pub_name
    str x9, [x16]
    ARM_ADDR x16, r2_source_path
    mov x9, x16
    ARM_ADDR x16, pub_source_path
    str x9, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, pub_project_inspect_version
    strb w10, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2p_first_tuple:
    lsl x16, x19, #1
    mov w3, w16
    ARM_ADDR x16, r2p_selections
    ldr x9, [x16]
    lsrv x9, x9, x3
    mov w10, w9
    ARM_IMM w11, 3
    tst w10, w11
    b.ne .Lr2p_inspect
    ARM_IMM w11, 1
    adds w19, w19, w11
    mov w10, w19
    ARM_IMM w11, 6
    cmp w10, w11
    b.lo .Lr2p_first_tuple
    b r2p_bad
.Lr2p_inspect:
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
    ldr x0, [x16]
    ARM_CALL pub_check_project
    ARM_IMM w10, 0
    ARM_ADDR x16, pub_project_inspect_version
    strb w10, [x16]
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2p_bad
    ARM_ADDR x16, pub_project_version
    mov x0, x16
    ARM_CALL registry_valid_version
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2p_bad
    ARM_ADDR x16, r2_version
    mov x0, x16
    ARM_ADDR x16, pub_project_version
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2_version
    mov x9, x16
    ARM_ADDR x16, pub_version
    str x9, [x16]
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2p_validate_targets:
    mov w10, w19
    ARM_IMM w11, 6
    cmp w10, w11
    b.hs .Lr2p_targets_validated
    lsl x16, x19, #1
    mov w3, w16
    ARM_ADDR x16, r2p_selections
    ldr x9, [x16]
    lsrv x9, x9, x3
    mov w10, w9
    ARM_IMM w11, 3
    tst w10, w11
    b.eq .Lr2p_validate_next
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
    ldr x0, [x16]
    ARM_CALL pub_check_project
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2p_bad
.Lr2p_validate_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2p_validate_targets
.Lr2p_targets_validated:
    ARM_CALL r2p_credential_identity
    ARM_CALL r2p_executables
    ARM_CALL r2p_json
    ARM_ADDR x16, r2p_manifest_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    ARM_ADDR x16, r2p_manifest_path
    mov x0, x16
    ARM_ADDR x16, r2p_path
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2p_manifest_path
    mov x0, x16
    ARM_ADDR x16, pub_json
    mov x1, x16
    ARM_ADDR x16, pub_json_length
    ldr x2, [x16]
    ARM_CALL r2_write_file
    ARM_ADDR x16, r2p_manifest_path
    mov x9, x16
    ARM_ADDR x16, r2_manifest
    str x9, [x16]
    ARM_IMM w10, 1
    ARM_ADDR x16, r2p_owned
    strb w10, [x16]
    ARM_ADDR x16, r2p_repo_fd
    ldr x0, [x16]
    ARM_CALL arc_close
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Compare selected physical directory identity with the credential parent's
 * ancestors before Git reads. Case aliases do not bypass device/inode checks.
 * Missing physical subtrees are allowed: committed Git objects remain usable.
 * Input path components never follow links; only fixed internal '..' ascends.
 * Local frame128 bytes, at most4096 ancestor steps; no credential file bytes are read. */
r2p_credential_location:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #32
    ARM_IMM w9, 72
    ARM_ADDR x16, r2p_repo_fd
    ldr x0, [x16]
    ARM_IMM w1, 1030
    ARM_IMM w2, 3
    ARM_CALL arm_fcntl
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x21, x9
    ARM_ADDR x16, r2p_source_path
    ldr x1, [x16]
    mov x16, x1
    ldrh w10, [x16]
    ARM_IMM w11, 0x002e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2p_selected_directory
    ARM_ADDR x16, r2p_subtree_walk
    mov x0, x16
    ARM_CALL copy_string
    ARM_ADDR x16, r2p_subtree_walk
    mov x19, x16
.Lr2p_subtree_component:
    mov x22, x19
.Lr2p_subtree_component_end:
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_subtree_component_open
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_subtree_component_open
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lr2p_subtree_component_end
.Lr2p_subtree_component_open:
    mov x16, x22
    ldrb w23, [x16]
    ARM_IMM w10, 0
    mov x16, x22
    strb w10, [x16]
    ARM_IMM w9, 257
    mov x0, x21
    mov x1, x19
    ARM_IMM w2, O_CLOEXEC + O_NOFOLLOW + O_DIRECTORY
    mov w11, w6
    eor w6, w6, w11
    tst w6, w6
    ARM_CALL arm_openat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.pl .Lr2p_subtree_component_ready
    mov x10, x9
    ARM_IMM x11, -2
    cmp x10, x11
    b.eq .Lr2p_no_physical_subtree
    mov x10, x9
    ARM_IMM x11, -20
    cmp x10, x11
    b.eq .Lr2p_no_physical_subtree
    mov x10, x9
    ARM_IMM x11, -40
    cmp x10, x11
    b.eq .Lr2p_no_physical_subtree
    b r2p_bad
.Lr2p_subtree_component_ready:
    mov x24, x9
    mov x0, x21
    ARM_CALL arc_close
    mov x21, x24
    mov w10, w23
    mov w11, w23
    tst w10, w11
    b.eq .Lr2p_selected_directory
    mov x16, x22
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x19, x16
    b .Lr2p_subtree_component
.Lr2p_selected_directory:
    ARM_IMM w9, 5
    mov x0, x21
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_ADDR x16, r2_stat
    ldr x22, [x16]
    ARM_ADDR x16, r2_stat + 8
    ldr x23, [x16]
    mov x0, x21
    ARM_CALL arc_close
    ARM_ADDR x16, r2p_credential_parent
    mov x0, x16
    ARM_ADDR x16, r2_credential
    ldr x1, [x16]
    ARM_CALL copy_string
    ARM_ADDR x16, r2p_credential_parent
    mov x0, x16
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2p_credential_last_slash:
    mov x16, x0
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lr2p_credential_parent_path
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2p_credential_slash_next
    mov x16, x0
    add x16, x16, x3
    mov x19, x16
.Lr2p_credential_slash_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2p_credential_last_slash
.Lr2p_credential_parent_path:
    mov x10, x19
    mov x11, x19
    tst x10, x11
    b.ne .Lr2p_credential_parent_cut
    ARM_ADDR x16, r2_cwd
    mov x0, x16
    b .Lr2p_credential_parent_open
.Lr2p_credential_parent_cut:
    mov x10, x19
    mov x11, x0
    cmp x10, x11
    b.ne .Lr2p_credential_parent_terminate
    ARM_IMM w9, 2
    ARM_ADDR x16, self_root
    mov x0, x16
    ARM_IMM w1, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL arm_open
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x24, x9
    b .Lr2p_credential_ancestors
.Lr2p_credential_parent_terminate:
    ARM_IMM w10, 0
    mov x16, x19
    strb w10, [x16]
.Lr2p_credential_parent_open:
    ARM_IMM w1, 1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x24, x9
.Lr2p_credential_ancestors:
    mov w11, w20
    eor w20, w20, w11
    tst w20, w20
.Lr2p_credential_ancestor:
    ARM_IMM w11, 1
    adds w20, w20, w11
    mov w10, w20
    ARM_IMM w11, 4096
    cmp w10, w11
    b.hi r2p_bad
    ARM_IMM w9, 5
    mov x0, x24
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_ADDR x16, r2_stat
    ldr x9, [x16]
    mov x10, x9
    mov x11, x22
    cmp x10, x11
    b.ne .Lr2p_credential_parent_next
    ARM_ADDR x16, r2_stat + 8
    ldr x9, [x16]
    mov x10, x9
    mov x11, x23
    cmp x10, x11
    b.eq .Lr2p_credential_inside
.Lr2p_credential_parent_next:
    ARM_ADDR x16, r2_stat
    ldr x9, [x16]
    mov x16, sp
    str x9, [x16]
    ARM_ADDR x16, r2_stat + 8
    ldr x9, [x16]
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    ARM_IMM w9, 257
    mov x0, x24
    ARM_ADDR x16, r2p_parent
    mov x1, x16
    ARM_IMM w2, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov w11, w6
    eor w6, w6, w11
    tst w6, w6
    ARM_CALL arm_openat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x21, x9
    ARM_IMM w9, 5
    mov x0, x21
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x24
    ARM_CALL arc_close
    mov x24, x21
    ARM_ADDR x16, r2_stat
    ldr x9, [x16]
    mov x10, x9
    mov x16, sp
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lr2p_credential_ancestor
    ARM_ADDR x16, r2_stat + 8
    ldr x9, [x16]
    mov x10, x9
    mov x16, sp
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lr2p_credential_ancestor
    mov x0, x24
    ARM_CALL arc_close
    b .Lr2p_credential_location_ok
.Lr2p_credential_inside:
    ARM_ADDR x16, r2p_error_credential
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
.Lr2p_no_physical_subtree:
    mov x0, x21
    ARM_CALL arc_close
.Lr2p_credential_location_ok:
    add sp, sp, #32
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Read only protected credential metadata. Call after source checks, before
 * executable snapshots. No credential byte enters package state. Stack 16. */
r2p_credential_identity:
    sub sp, sp, #16
    ARM_ADDR x16, r2_credential
    ldr x0, [x16]
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    ARM_IMM w2, 1
    ARM_CALL r2_open_path
    mov x0, x9
    ARM_ADDR x16, r2_stat
    ldr x9, [x16]
    ARM_ADDR x16, r2p_credential_dev
    str x9, [x16]
    ARM_ADDR x16, r2_stat + 8
    ldr x9, [x16]
    ARM_ADDR x16, r2p_credential_ino
    str x9, [x16]
    ARM_CALL arc_close
    add sp, sp, #16
    ret

/* r2_stat describes an opened candidate, before its first byte read. */
r2p_refuse_credential_object:
    ARM_ADDR x16, r2_stat
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2p_credential_dev
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lr2p_not_credential_object
    ARM_ADDR x16, r2_stat + 8
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2p_credential_ino
    ldr x11, [x16]
    cmp x10, x11
    b.ne .Lr2p_not_credential_object
    ARM_ADDR x16, r2p_error_credential_object
    mov x0, x16
    ARM_IMM w1, 1
    b registry_fail
.Lr2p_not_credential_object:
    ret

/* x0=portable candidate path. w9=1 keep/0 excluded; sensitive names fail.
 * Same six directory exclusions as committed registry packing. Stack 80. */
r2p_allowed:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    mov x21, x0
    ARM_CALL r2p_is_excluded
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2p_excluded
    mov x0, x21
    ARM_CALL pub_portable_path
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2p_bad
    mov x22, x21
.Lr2p_component:
    ARM_ADDR x16, pub_component
    mov x0, x16
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2p_component_copy:
    mov x16, x22
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lr2p_component_check
    mov w10, w9
    and w10, w10, #255
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_component_check
    mov x16, x0
    add x16, x16, x19
    strb w9, [x16]
    ARM_IMM w11, 1
    adds w19, w19, w11
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lr2p_component_copy
.Lr2p_component_check:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x19
    strb w10, [x16]
    ARM_ADDR x16, r2p_excluded
    mov x1, x16
    ARM_CALL pub_in_strings
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2p_excluded
    ARM_ADDR x16, pub_component
    mov x0, x16
    ARM_ADDR x16, pub_excluded
    mov x1, x16
    ARM_CALL pub_in_strings
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2p_bad
    ARM_ADDR x16, pub_component
    ldr w10, [x16]
    ARM_IMM w11, 0x766e652e
    cmp w10, w11
    b.ne .Lr2p_component_next
    ARM_ADDR x16, pub_component + 4
    ldrb w10, [x16]
    ARM_IMM w11, 46
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2p_bad
.Lr2p_component_next:
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_extension
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lr2p_component
.Lr2p_extension:
    mov x0, x21
    ARM_CALL strlen
    mov x10, x9
    ARM_IMM x11, 4
    cmp x10, x11
    b.lo .Lr2p_allowed_yes
    mov x16, x21
    add x16, x16, x9
    ARM_IMM x17, 4
    sub x16, x16, x17
    ldr w9, [x16]
    ARM_IMM w11, 0x20202000
    orr w9, w9, w11
    tst w9, w9
    mov w10, w9
    ARM_IMM w11, 0x79656b2e
    cmp w10, w11
    b.eq r2p_bad
    mov w10, w9
    ARM_IMM w11, 0x6d65702e
    cmp w10, w11
    b.eq r2p_bad
.Lr2p_allowed_yes:
    ARM_IMM w9, 1
    b .Lr2p_allowed_done
.Lr2p_excluded:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2p_allowed_done:
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=borrowed NUL path inside the bounded Git list. w9=1 iff any complete
 * component is an excluded cache directory. Run before portability/sensitive
 * checks, matching the existing committed-source collector's precedence.
 * No component above11 bytes needs copying. Stack 80. */
r2p_is_excluded:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    mov x21, x0
.Lr2p_exclusion_component:
    mov x22, x21
.Lr2p_exclusion_end:
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_exclusion_check
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_exclusion_check
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lr2p_exclusion_end
.Lr2p_exclusion_check:
    mov x3, x22
    mov x11, x21
    subs x3, x3, x11
    mov x10, x3
    ARM_IMM x11, 11
    cmp x10, x11
    b.hi .Lr2p_exclusion_next
    ARM_ADDR x16, pub_component
    mov x0, x16
    mov x1, x21
    cbz x3, .Lr2p_arm_copy_1_end
.Lr2p_arm_copy_1:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2p_arm_copy_1
.Lr2p_arm_copy_1_end:
    ARM_IMM w10, 0
    mov x16, x0
    strb w10, [x16]
    ARM_ADDR x16, pub_component
    mov x0, x16
    ARM_ADDR x16, r2p_excluded
    mov x1, x16
    ARM_CALL pub_in_strings
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne .Lr2p_exclusion_found
.Lr2p_exclusion_next:
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_exclusion_absent
    mov x16, x22
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x21, x16
    b .Lr2p_exclusion_component
.Lr2p_exclusion_found:
    ARM_IMM w9, 1
    b .Lr2p_exclusion_done
.Lr2p_exclusion_absent:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
.Lr2p_exclusion_done:
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Parse canonical unsigned decimal in [x0,x1), permitting zero. x9=value,
 * x0=first non-digit. Cap x2 is checked before each multiply. No stack. */
r2p_decimal:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov w11, w4
    eor w4, w4, w11
    tst w4, w4
.Lr2p_decimal_loop:
    mov x10, x0
    mov x11, x1
    cmp x10, x11
    b.hs .Lr2p_decimal_done
    mov x16, x0
    ldrb w3, [x16]
    ARM_IMM w11, 48
    subs w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 9
    cmp w10, w11
    b.hi .Lr2p_decimal_done
    mov x10, x9
    ARM_IMM x11, 10
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    mov x11, x3
    adds x9, x9, x11
    mov x10, x9
    mov x11, x2
    cmp x10, x11
    b.hi r2p_bad
    ARM_IMM w11, 1
    adds w4, w4, w11
    ARM_IMM x11, 1
    adds x0, x0, x11
    mov w10, w4
    ARM_IMM w11, 20
    cmp w10, w11
    b.hi r2p_bad
    b .Lr2p_decimal_loop
.Lr2p_decimal_done:
    mov w10, w4
    mov w11, w4
    tst w10, w11
    b.eq r2p_bad
    ret

/* Read the bounded ls-tree list. Records borrow paths/OIDs in that list.
 * Reject before object reads if headers+padding+end exceed64MiB. Stack 112. */
r2p_collect:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_ADDR x16, r2p_tree_data
    mov x21, x16
    ARM_IMM x10, 1024
    ARM_ADDR x16, r2p_tar_bytes
    str x10, [x16]
    ARM_ADDR x16, r2p_request_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_create
    mov x24, x9
.Lr2p_tree_entry:
    mov x10, x21
    ARM_ADDR x16, r2p_tree_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2p_collected
    mov x22, x21
.Lr2p_tree_tab:
    mov x10, x22
    ARM_ADDR x16, r2p_tree_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs r2p_bad
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 9
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_tree_path
    mov x16, x22
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq r2p_bad
    ARM_IMM x11, 1
    adds x22, x22, x11
    b .Lr2p_tree_tab
.Lr2p_tree_path:
    mov x16, x22
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x20, x16
    mov x23, x20
.Lr2p_tree_end:
    mov x10, x23
    ARM_ADDR x16, r2p_tree_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs r2p_bad
    mov x16, x23
    ldrb w10, [x16]
    ARM_IMM w11, 0
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lr2p_tree_subtree
    ARM_IMM x11, 1
    adds x23, x23, x11
    b .Lr2p_tree_end
.Lr2p_tree_subtree:
    ARM_ADDR x16, r2_source_path
    mov x1, x16
    mov x16, x1
    ldrh w10, [x16]
    ARM_IMM w11, 0x002e
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2p_tree_relative
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2p_subtree_prefix:
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    mov w10, w9
    and w10, w10, #255
    mov w11, w9
    and w11, w11, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lr2p_subtree_slash
    mov w10, w9
    and w10, w10, #255
    mov x16, x20
    add x16, x16, x3
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2p_subtree_prefix
.Lr2p_subtree_slash:
    mov x16, x20
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x20
    add x16, x16, x3
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x20, x16
.Lr2p_tree_relative:
    mov x0, x20
    ARM_CALL r2p_allowed
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq .Lr2p_tree_next
    mov x0, x20
    ARM_ADDR x16, r2p_lock_name
    mov x1, x16
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.ne r2p_lock_error
    ARM_IMM w19, 420
    mov x16, x21
    ldr w10, [x16]
    ARM_IMM w11, 0x36303031
    cmp w10, w11
    b.ne .Lr2p_tree_executable
    mov x16, x21
    ARM_IMM x17, 4
    add x16, x16, x17
    ldrh w10, [x16]
    ARM_IMM w11, 0x3434
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.eq .Lr2p_tree_mode_ok
.Lr2p_tree_executable:
    mov x16, x21
    ldr w10, [x16]
    ARM_IMM w11, 0x37303031
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x21
    ARM_IMM x17, 4
    add x16, x16, x17
    ldrh w10, [x16]
    ARM_IMM w11, 0x3535
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne r2p_bad
    ARM_IMM w19, 493
.Lr2p_tree_mode_ok:
    mov x16, x21
    ARM_IMM x17, 6
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x21
    ARM_IMM x17, 7
    add x16, x16, x17
    ldr w10, [x16]
    ARM_IMM w11, 0x626f6c62
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x21
    ARM_IMM x17, 11
    add x16, x16, x17
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x21
    ARM_IMM x17, 12
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2p_oid_length
    ldr x3, [x16]
    mov x16, x0
    add x16, x16, x3
    mov x9, x16
    mov x10, x9
    mov x11, x22
    cmp x10, x11
    b.hs r2p_bad
    mov x16, x9
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    ARM_IMM w10, 0
    mov x16, x9
    strb w10, [x16]
    mov w1, w3
    ARM_CALL r2_hex
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2p_bad
    mov x16, x21
    ARM_IMM x17, 12
    add x16, x16, x17
    mov x0, x16
    ARM_ADDR x16, r2p_oid_length
    ldr x11, [x16]
    adds x0, x0, x11
    ARM_IMM x11, 1
    adds x0, x0, x11
.Lr2p_tree_spaces:
    mov x10, x0
    mov x11, x22
    cmp x10, x11
    b.hs r2p_bad
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2p_tree_size
    ARM_IMM x11, 1
    adds x0, x0, x11
    b .Lr2p_tree_spaces
.Lr2p_tree_size:
    mov x1, x22
    ARM_IMM w2, ARC_FILE_LIMIT
    ARM_CALL r2p_decimal
    mov x10, x0
    mov x11, x22
    cmp x10, x11
    b.ne r2p_bad
    mov x2, x9
    ARM_IMM x11, 511
    adds x9, x9, x11
    ARM_IMM x11, -512
    and x9, x9, x11
    tst x9, x9
    ARM_IMM x11, 512
    adds x9, x9, x11
    ARM_ADDR x16, r2p_tar_bytes
    ldr x11, [x16]
    adds x9, x9, x11
    mov x10, x9
    ARM_IMM x11, ARC_LIMIT
    cmp x10, x11
    b.hi r2p_bad
    ARM_ADDR x16, r2p_tar_bytes
    str x9, [x16]
    ARM_ADDR x16, r2p_count
    ldr x3, [x16]
    mov x10, x3
    ARM_IMM x11, R2P_FILES
    cmp x10, x11
    b.hs r2p_bad
    lsl x3, x3, #5
    ARM_ADDR x16, r2p_records
    mov x0, x16
    mov x11, x3
    adds x0, x0, x11
    mov x16, x0
    str x20, [x16]
    mov x16, x21
    ARM_IMM x17, 12
    add x16, x16, x17
    mov x9, x16
    mov x16, x0
    ARM_IMM x17, 8
    add x16, x16, x17
    str x9, [x16]
    mov x16, x0
    ARM_IMM x17, 16
    add x16, x16, x17
    str x2, [x16]
    mov x16, x0
    ARM_IMM x17, 24
    add x16, x16, x17
    str x19, [x16]
    ARM_ADDR x16, r2p_count
    ldr x10, [x16]
    ARM_IMM x11, 1
    adds x10, x10, x11
    ARM_ADDR x16, r2p_count
    str x10, [x16]
    mov x0, x24
    mov x16, x21
    ARM_IMM x17, 12
    add x16, x16, x17
    mov x1, x16
    ARM_ADDR x16, r2p_oid_length
    ldr x2, [x16]
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x24
    ARM_ADDR x16, r2p_lf
    mov x1, x16
    ARM_IMM w2, 1
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
.Lr2p_tree_next:
    mov x16, x23
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x21, x16
    b .Lr2p_tree_entry
.Lr2p_collected:
    ARM_ADDR x16, r2p_count
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq r2p_bad
    mov x0, x24
    ARM_CALL arc_close
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=field, w3=width including NUL, x9=unsigned value. Writes fixed-width
 * zero-padded octal. A value outside the field fails. Scratch x9/x3/x2/x4. */
r2p_octal:
    mov x16, x0
    add x16, x16, x3
    ARM_IMM x17, 1
    sub x16, x16, x17
    mov x4, x16
    ARM_IMM w10, 0
    mov x16, x4
    strb w10, [x16]
.Lr2p_octal_digit:
    ARM_IMM x11, 1
    subs x4, x4, x11
    mov w2, w9
    ARM_IMM w11, 7
    and w2, w2, w11
    tst w2, w2
    ARM_IMM w11, 48
    adds w2, w2, w11
    mov x16, x4
    strb w2, [x16]
    lsr x9, x9, #3
    mov x10, x4
    mov x11, x0
    cmp x10, x11
    b.hi .Lr2p_octal_digit
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.ne r2p_bad
    ret

/* x0=borrowed record. Output r2p_header[512]. USTAR path split never truncates:
 * name<=100, prefix<=155. Header ownership/time zero, regular normalized mode.
 * Stack 80. Header and padding contribute to the previously checked TAR budget. */
r2p_tar_header:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    mov x21, x0
    mov x16, x21
    ldr x22, [x16]
    ARM_ADDR x16, r2p_header
    mov x0, x16
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_IMM w3, 512
    cbz x3, .Lr2p_arm_copy_2_end
.Lr2p_arm_copy_2:
    strb w9, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2p_arm_copy_2
.Lr2p_arm_copy_2_end:
    mov x0, x22
    ARM_CALL strlen
    mov x23, x9
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov x10, x23
    ARM_IMM x11, 100
    cmp x10, x11
    b.ls .Lr2p_tar_name
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
.Lr2p_tar_split:
    mov x10, x3
    mov x11, x23
    cmp x10, x11
    b.hs r2p_bad
    mov w10, w3
    ARM_IMM w11, 155
    cmp w10, w11
    b.hi r2p_bad
    mov x16, x22
    add x16, x16, x3
    ldrb w10, [x16]
    ARM_IMM w11, 47
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lr2p_tar_split_next
    mov x9, x23
    mov x11, x3
    subs x9, x9, x11
    ARM_IMM x11, 1
    subs x9, x9, x11
    mov x10, x9
    ARM_IMM x11, 100
    cmp x10, x11
    b.hi .Lr2p_tar_split_next
    mov x19, x3
    ARM_ADDR x16, r2p_header + 345
    mov x0, x16
    mov x1, x22
    cbz x3, .Lr2p_arm_copy_3_end
.Lr2p_arm_copy_3:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2p_arm_copy_3
.Lr2p_arm_copy_3_end:
    ARM_IMM x11, 1
    adds x19, x19, x11
    b .Lr2p_tar_name
.Lr2p_tar_split_next:
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lr2p_tar_split
.Lr2p_tar_name:
    ARM_ADDR x16, r2p_header
    mov x0, x16
    mov x16, x22
    add x16, x16, x19
    mov x1, x16
    mov x3, x23
    mov x11, x19
    subs x3, x3, x11
    cbz x3, .Lr2p_arm_copy_4_end
.Lr2p_arm_copy_4:
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lr2p_arm_copy_4
.Lr2p_arm_copy_4_end:
    ARM_ADDR x16, r2p_header + 100
    mov x0, x16
    ARM_IMM w3, 8
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x9, [x16]
    ARM_CALL r2p_octal
    ARM_ADDR x16, r2p_header + 108
    mov x0, x16
    ARM_IMM w3, 8
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_CALL r2p_octal
    ARM_ADDR x16, r2p_header + 116
    mov x0, x16
    ARM_IMM w3, 8
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_CALL r2p_octal
    ARM_ADDR x16, r2p_header + 124
    mov x0, x16
    ARM_IMM w3, 12
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x9, [x16]
    ARM_CALL r2p_octal
    ARM_ADDR x16, r2p_header + 136
    mov x0, x16
    ARM_IMM w3, 12
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    ARM_CALL r2p_octal
    ARM_IMM x9, 0x2020202020202020
    ARM_ADDR x16, r2p_header + 148
    str x9, [x16]
    ARM_IMM w10, 48
    ARM_ADDR x16, r2p_header + 156
    strb w10, [x16]
    ARM_IMM w10, 0x61747375
    ARM_ADDR x16, r2p_header + 257
    str w10, [x16]
    ARM_IMM w10, 0x0072
    ARM_ADDR x16, r2p_header + 261
    strh w10, [x16]
    ARM_IMM w10, 0x3030
    ARM_ADDR x16, r2p_header + 263
    strh w10, [x16]
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov w11, w3
    eor w3, w3, w11
    tst w3, w3
    ARM_ADDR x16, r2p_header
    mov x0, x16
.Lr2p_tar_checksum:
    mov x16, x0
    add x16, x16, x3
    ldrb w2, [x16]
    mov w11, w2
    adds w9, w9, w11
    ARM_IMM w11, 1
    adds w3, w3, w11
    mov w10, w3
    ARM_IMM w11, 512
    cmp w10, w11
    b.lo .Lr2p_tar_checksum
    ARM_ADDR x16, r2p_header + 148
    mov x0, x16
    ARM_IMM w3, 7
    ARM_CALL r2p_octal
    ARM_IMM w10, 32
    ARM_ADDR x16, r2p_header + 155
    strb w10, [x16]
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* One unbuffered cat-file process reads only selected OIDs from an owned file.
 * Its regular output has a kernel cap. Native code checks every response header
 * and byte count while writing USTAR; no Git archive attributes or filters run.
 * Stack 112; mapping is unmapped before gzip/validation. */
r2p_archive:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_ADDR x16, r2p_request_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_open
    mov x21, x9
    ARM_ADDR x16, r2p_batch_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_create
    mov x22, x9
    ARM_ADDR x16, r2p_git
    mov x0, x16
    ARM_ADDR x16, r2p_batch_argv
    mov x1, x16
    mov x2, x21
    mov x3, x22
    ARM_IMM w4, R2P_BATCH
    ARM_CALL r2p_run
    mov x0, x21
    ARM_CALL arc_close
    mov x0, x22
    ARM_CALL arc_close
    ARM_ADDR x16, r2p_batch_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_open
    mov x21, x9
    ARM_IMM w9, 5
    mov x0, x21
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_ADDR x16, r2_stat + 48
    ldr x1, [x16]
    mov x10, x1
    mov x11, x1
    tst x10, x11
    b.le r2p_bad
    mov x10, x1
    ARM_IMM x11, R2P_BATCH
    cmp x10, x11
    b.hi r2p_bad
    ARM_ADDR x16, r2p_batch_length
    str x1, [x16]
    ARM_IMM w9, 9
    mov w11, w0
    eor w0, w0, w11
    tst w0, w0
    ARM_IMM w2, 1
    ARM_IMM w6, 2
    mov x4, x21
    mov w11, w5
    eor w5, w5, w11
    tst w5, w5
    ARM_CALL arm_mmap
    mov x10, x9
    ARM_IMM x11, -4095
    cmp x10, x11
    b.hs r2p_bad
    ARM_ADDR x16, r2p_batch_base
    str x9, [x16]
    ARM_ADDR x16, r2p_cursor
    str x9, [x16]
    ARM_ADDR x16, r2p_batch_length
    ldr x11, [x16]
    adds x9, x9, x11
    ARM_ADDR x16, r2p_batch_end
    str x9, [x16]
    mov x0, x21
    ARM_CALL arc_close
    ARM_ADDR x16, r2p_tar_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_create
    mov x24, x9
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2p_tar_entry:
    mov x10, x19
    ARM_ADDR x16, r2p_count
    ldr x11, [x16]
    cmp x10, x11
    b.hs .Lr2p_tar_end
    mov x9, x19
    lsl x9, x9, #5
    ARM_ADDR x16, r2p_records
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    ARM_ADDR x16, r2p_cursor
    ldr x22, [x16]
    mov x23, x22
    ARM_ADDR x16, r2p_oid_length
    ldr x11, [x16]
    adds x23, x23, x11
    ARM_IMM x11, 7
    adds x23, x23, x11
    mov x10, x23
    ARM_ADDR x16, r2p_batch_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs r2p_bad
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x1, [x16]
    ARM_ADDR x16, r2p_oid_length
    ldr x3, [x16]
    mov x0, x22
    cbz x3, .Lr2p_arm_compare_5_end
.Lr2p_arm_compare_5:
    ldrb w10, [x0], #1
    ldrb w11, [x1], #1
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w11, w10
    sub x3, x3, #1
    b.ne .Lr2p_arm_compare_5_end
    cbnz x3, .Lr2p_arm_compare_5
.Lr2p_arm_compare_5_end:
    b.ne r2p_bad
    mov x16, x0
    ldr w10, [x16]
    ARM_IMM w11, 0x6f6c6220
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x0
    ARM_IMM x17, 4
    add x16, x16, x17
    ldrh w10, [x16]
    ARM_IMM w11, 0x2062
    lsl w10, w10, #16
    lsl w11, w11, #16
    cmp w10, w11
    b.ne r2p_bad
    ARM_IMM x11, 6
    adds x0, x0, x11
    ARM_ADDR x16, r2p_batch_end
    ldr x1, [x16]
    ARM_IMM w2, ARC_FILE_LIMIT
    ARM_CALL r2p_decimal
    mov x10, x9
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2p_bad
    mov x16, x0
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x0
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x22, x16
    mov x16, x22
    add x16, x16, x9
    mov x23, x16
    mov x10, x23
    ARM_ADDR x16, r2p_batch_end
    ldr x11, [x16]
    cmp x10, x11
    b.hs r2p_bad
    mov x16, x23
    ldrb w10, [x16]
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne r2p_bad
    mov x16, x23
    ARM_IMM x17, 1
    add x16, x16, x17
    mov x9, x16
    ARM_ADDR x16, r2p_cursor
    str x9, [x16]
    mov x0, x21
    ARM_CALL r2p_tar_header
    mov x0, x24
    ARM_ADDR x16, r2p_header
    mov x1, x16
    ARM_IMM w2, 512
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x24
    mov x1, x22
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x2, [x16]
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x2, [x16]
    negs x2, x2
    ARM_IMM w11, 511
    and w2, w2, w11
    tst w2, w2
    mov x0, x24
    ARM_ADDR x16, r2p_zeroes
    mov x1, x16
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2p_tar_entry
.Lr2p_tar_end:
    ARM_ADDR x16, r2p_cursor
    ldr x9, [x16]
    mov x10, x9
    ARM_ADDR x16, r2p_batch_end
    ldr x11, [x16]
    cmp x10, x11
    b.ne r2p_bad
    mov x0, x24
    ARM_ADDR x16, r2p_zeroes
    mov x1, x16
    ARM_IMM w2, 1024
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    mov x0, x24
    ARM_CALL arc_close
    ARM_IMM w9, 11
    ARM_ADDR x16, r2p_batch_base
    ldr x0, [x16]
    ARM_ADDR x16, r2p_batch_length
    ldr x1, [x16]
    ARM_CALL arm_munmap
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_IMM x10, 0
    ARM_ADDR x16, r2p_batch_base
    str x10, [x16]
    ARM_ADDR x16, r2p_batch_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_IMM w9, 87
    ARM_CALL arm_unlink
    ARM_ADDR x16, r2p_request_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_IMM w9, 87
    ARM_CALL arm_unlink
    ARM_ADDR x16, r2p_tar_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_open
    mov x21, x9
    ARM_ADDR x16, r2p_archive_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_create
    mov x22, x9
    ARM_ADDR x16, r2p_gzip
    mov x0, x16
    ARM_ADDR x16, r2p_gzip_argv
    mov x1, x16
    mov x2, x21
    mov x3, x22
    ARM_IMM w4, ARC_LIMIT
    ARM_CALL r2p_run
    mov x0, x21
    ARM_CALL arc_close
    mov x0, x22
    ARM_CALL arc_close
    ARM_ADDR x16, r2p_tar_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_IMM w9, 87
    ARM_CALL arm_unlink
    ARM_ADDR x16, r2p_archive_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_retain_object
    mov x16, x9
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x9, [x16]
    ARM_ADDR x16, r2_source_bytes
    str x9, [x16]
    ARM_ADDR x16, r2_source_sha
    mov x0, x16
    ARM_ADDR x16, pub_hash_buffer
    mov x1, x16
    ARM_CALL copy_string
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* x0=owned private candidate path. x9=shared digest record after no-replace
 * finalization; pub_hash_buffer holds its digest. Existing equal bytes may be
 * reused, never replaced. Stack 80; bounds1..64MiB and task128MiB. */
r2p_retain_object:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    sub sp, sp, #16
    mov x21, x0
    ARM_CALL r2p_open
    mov x22, x9
    ARM_IMM w9, 5
    mov x0, x22
    ARM_ADDR x16, r2_stat
    mov x1, x16
    ARM_CALL arm_fstat
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    ARM_ADDR x16, r2_stat + 16
    ldr w9, [x16]
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    mov w10, w9
    ARM_IMM w11, 32768
    cmp w10, w11
    b.ne r2p_bad
    ARM_ADDR x16, r2_stat + 20
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne r2p_bad
    ARM_ADDR x16, r2_stat + 48
    ldr x23, [x16]
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.le r2p_bad
    mov x10, x23
    ARM_IMM x11, ARC_LIMIT
    cmp x10, x11
    b.hi r2p_bad
    mov x0, x22
    ARM_CALL arc_close
    mov x0, x21
    ARM_CALL r2_hash_path
    ARM_ADDR x16, pub_hash_buffer
    mov x0, x16
    mov x1, x23
    ARM_CALL r2_add_object
    mov x19, x9
    mov x0, x19
    ARM_CALL r2_object_stage_path
    ARM_IMM w9, 316
    ARM_IMM x0, -100
    mov x1, x21
    ARM_IMM x2, -100
    ARM_ADDR x16, r2_object_path
    mov x6, x16
    ARM_IMM w4, 1
    ARM_CALL arm_renameat2
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.pl .Lr2p_retained
    mov x10, x9
    ARM_IMM x11, -17
    cmp x10, x11
    b.ne r2p_bad
    ARM_ADDR x16, r2_object_path
    mov x0, x16
    ARM_CALL r2_hash_path
    ARM_ADDR x16, pub_hash_buffer
    mov x0, x16
    mov x1, x19
    ARM_CALL streq
    mov w10, w9
    mov w11, w9
    tst w10, w11
    b.eq r2p_bad
    ARM_IMM w9, 87
    mov x0, x21
    ARM_CALL arm_unlink
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
.Lr2p_retained:
    mov x9, x19
    add sp, sp, #16
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Snapshot explicit executable inputs without building or executing them.
 * Records use the common SHA/length/task bounds. Stack 112; copy buffer64KiB. */
r2p_executables:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
.Lr2p_executable:
    mov w10, w19
    ARM_IMM w11, 6
    cmp w10, w11
    b.hs .Lr2p_executables_done
    ARM_ADDR x16, r2p_executable_paths
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr2p_executable_next
    mov w11, w1
    eor w1, w1, w11
    tst w1, w1
    mov w11, w2
    eor w2, w2, w11
    tst w2, w2
    ARM_CALL r2_open_path
    mov x21, x9
    ARM_CALL r2p_refuse_credential_object
    ARM_ADDR x16, r2_stat + 48
    ldr x23, [x16]
    mov x10, x23
    mov x11, x23
    tst x10, x11
    b.le r2p_bad
    mov x10, x23
    ARM_IMM x11, ARC_LIMIT
    cmp x10, x11
    b.hi r2p_bad
    ARM_ADDR x16, r2p_candidate_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_create
    mov x22, x9
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lr2p_executable_read:
    mov w11, w9
    eor w9, w9, w11
    tst w9, w9
    mov x0, x21
    ARM_ADDR x16, registry_copy_buffer
    mov x1, x16
    ARM_IMM w2, 65536
    ARM_CALL arm_read
    mov x10, x9
    ARM_IMM x11, -4
    cmp x10, x11
    b.eq .Lr2p_executable_read
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    b.eq .Lr2p_executable_copied
    mov x11, x9
    adds x24, x24, x11
    mov x10, x24
    mov x11, x23
    cmp x10, x11
    b.hi r2p_bad
    mov x2, x9
    mov x0, x22
    ARM_ADDR x16, registry_copy_buffer
    mov x1, x16
    ARM_CALL write_all
    mov x10, x9
    mov x11, x9
    tst x10, x11
    b.mi r2p_bad
    b .Lr2p_executable_read
.Lr2p_executable_copied:
    mov x10, x24
    mov x11, x23
    cmp x10, x11
    b.ne r2p_bad
    mov x0, x21
    ARM_CALL arc_close
    mov x0, x22
    ARM_CALL arc_close
    ARM_ADDR x16, r2p_candidate_suffix
    mov x0, x16
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_CALL r2p_retain_object
    ARM_ADDR x16, r2p_executable_records
    mov x2, x16
    mov x16, x2
    add x16, x16, x19, lsl #3
    str x9, [x16]
.Lr2p_executable_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2p_executable
.Lr2p_executables_done:
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

.macro R2P_APPEND text
    ARM_ADDR x16, \text
    mov x0, x16
    ARM_CALL pub_append
.endm
.macro R2P_QUOTE text
    ARM_ADDR x16, \text
    mov x0, x16
    ARM_CALL pub_quote
.endm
/* x0=unsigned value; append one canonical decimal to the16KiB JSON buffer. */
r2p_number:
    sub sp, sp, #16
    ARM_ADDR x16, pub_number + 31
    mov x1, x16
    ARM_CALL unsigned_decimal
    mov x0, x9
    ARM_CALL pub_append
    add sp, sp, #16
    ret

/* Build the exact sorted-key, two-space canonical publication JSON from owned
 * metadata. Arrays use stable tuple/kind order independent of option order.
 * Max12 selections and all string bounds fit the existing16KiB writer. Stack 112. */
r2p_json:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    sub sp, sp, #16
    ARM_IMM x10, 0
    ARM_ADDR x16, pub_json_length
    str x10, [x16]
    R2P_APPEND r2p_json_start
    mov w11, w19
    eor w19, w19, w11
    tst w19, w19
    mov w11, w24
    eor w24, w24, w11
    tst w24, w24
.Lr2p_json_selection:
    mov w10, w19
    ARM_IMM w11, 12
    cmp w10, w11
    b.hs .Lr2p_json_metadata
    ARM_ADDR x16, r2p_selections
    ldr x10, [x16]
    lsrv x11, x10, x19
    and x11, x11, #1
    cmp x11, #0
    b.eq .Lr2p_json_next
    mov w10, w24
    mov w11, w24
    tst w10, w11
    b.eq .Lr2p_json_first
    R2P_APPEND r2p_json_comma_lf
.Lr2p_json_first:
    ARM_IMM w11, 1
    adds w24, w24, w11
    mov w9, w19
    lsr w9, w9, #1
    mov x10, x9
    ARM_IMM x11, 40
    smulh x12, x10, x11
    mul x9, x10, x11
    asr x13, x9, #63
    cmp x12, x13
    ARM_ADDR x16, r2_tuples
    mov x21, x16
    mov x11, x9
    adds x21, x21, x11
    ARM_ADDR x16, r2_source_sha
    mov x22, x16
    ARM_ADDR x16, r2_source_bytes
    ldr x23, [x16]
    mov w10, w19
    ARM_IMM w11, 1
    tst w10, w11
    b.eq .Lr2p_json_artifact
    mov w9, w19
    lsr w9, w9, #1
    ARM_ADDR x16, r2p_executable_records
    mov x2, x16
    mov x16, x2
    add x16, x16, x9, lsl #3
    ldr x22, [x16]
    mov x16, x22
    ARM_IMM x17, 72
    add x16, x16, x17
    ldr x23, [x16]
.Lr2p_json_artifact:
    R2P_APPEND r2p_json_abi
    mov x16, x21
    ARM_IMM x17, 24
    add x16, x16, x17
    ldr x0, [x16]
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_bytes
    mov x0, x23
    ARM_CALL r2p_number
    R2P_APPEND r2p_json_features
    mov x16, x21
    ARM_IMM x17, 32
    add x16, x16, x17
    ldr x0, [x16]
    mov w10, w19
    ARM_IMM w11, 1
    tst w10, w11
    b.ne .Lr2p_json_format
    ARM_ADDR x16, r2_tar_gzip
    mov x0, x16
.Lr2p_json_format:
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_isa
    mov x16, x21
    ARM_IMM x17, 8
    add x16, x16, x17
    ldr x0, [x16]
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_kind
    ARM_ADDR x16, registry_source_kind
    mov x0, x16
    mov w10, w19
    ARM_IMM w11, 1
    tst w10, w11
    b.eq .Lr2p_json_kind_value
    ARM_ADDR x16, registry_executable_kind
    mov x0, x16
.Lr2p_json_kind_value:
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_os
    mov x16, x21
    ARM_IMM x17, 16
    add x16, x16, x17
    ldr x0, [x16]
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_sha
    mov x0, x22
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_artifact_end
.Lr2p_json_next:
    ARM_IMM w11, 1
    adds w19, w19, w11
    b .Lr2p_json_selection
.Lr2p_json_metadata:
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cbz x9, .Lr2p_json_license
    R2P_APPEND r2p_json_dependencies
    ARM_ADDR x21, g3_project_deps
    mov x19, #0
.Lr2p_json_dependency:
    cbz x19, .Lr2p_json_dependency_first
    R2P_APPEND r2p_json_comma_lf
.Lr2p_json_dependency_first:
    R2P_APPEND r2p_json_dependency_name
    mov x0, x21
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_requirement
    add x0, x21, #105
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_artifact_end
    add x21, x21, #240
    add x19, x19, #1
    ARM_ADDR x16, g3_project_dep_count
    ldr x9, [x16]
    cmp x19, x9
    b.lo .Lr2p_json_dependency
.Lr2p_json_license:
    R2P_APPEND r2p_json_license
    R2P_QUOTE r2_license
    R2P_APPEND r2p_json_name
    R2P_QUOTE r2_name
    R2P_APPEND r2p_json_owner
    R2P_QUOTE r2_owner_id
    R2P_APPEND r2p_json_archive
    ARM_ADDR x16, r2_source_bytes
    ldr x0, [x16]
    ARM_CALL r2p_number
    R2P_APPEND r2p_json_archive_sha
    R2P_QUOTE r2_source_sha
    R2P_APPEND r2p_json_algorithm
    ARM_ADDR x16, r2p_algorithm
    ldr x0, [x16]
    ARM_CALL pub_quote
    R2P_APPEND r2p_json_commit
    R2P_QUOTE r2_commit
    R2P_APPEND r2p_json_path
    R2P_QUOTE r2_source_path
    ARM_ADDR x16, r2p_repository
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr2p_json_summary
    R2P_APPEND r2p_json_repository
    ARM_ADDR x16, r2p_repository
    ldr x0, [x16]
    ARM_CALL pub_quote
.Lr2p_json_summary:
    R2P_APPEND r2p_json_summary
    R2P_QUOTE r2_summary
    R2P_APPEND r2p_json_version
    R2P_QUOTE r2_version
    R2P_APPEND r2p_json_end
    add sp, sp, #16
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Remove only this invocation's fixed private files, including failed candidates.
 * Shared digest objects are cleaned by r2_clean_files. Stack 48. */
r2p_cleanup:
    ARM_SAVE x19
    ARM_SAVE x21
    sub sp, sp, #16
    ARM_ADDR x16, r2p_project
    ldr x10, [x16]
    ARM_IMM x11, 0
    cmp x10, x11
    b.eq .Lr2p_cleanup_done
    ARM_ADDR x16, r2p_batch_base
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr2p_cleanup_files
    ARM_IMM w9, 11
    ARM_ADDR x16, r2p_batch_length
    ldr x1, [x16]
    ARM_CALL arm_munmap
    ARM_IMM x10, 0
    ARM_ADDR x16, r2p_batch_base
    str x10, [x16]
.Lr2p_cleanup_files:
    ARM_ADDR x16, r2p_suffixes
    mov x19, x16
.Lr2p_cleanup_file:
    mov x16, x19
    ldr x0, [x16]
    mov x10, x0
    mov x11, x0
    tst x10, x11
    b.eq .Lr2p_cleanup_done
    ARM_CALL r2p_path_for
    mov x0, x9
    ARM_IMM w9, 87
    ARM_CALL arm_unlink
    ARM_IMM x11, 8
    adds x19, x19, x11
    b .Lr2p_cleanup_file
.Lr2p_cleanup_done:
    add sp, sp, #16
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

.section .rodata
r2p_opt_project: .asciz "--project"
r2p_opt_name: .asciz "--name"
r2p_opt_owner: .asciz "--owner-id"
r2p_opt_summary: .asciz "--summary"
r2p_opt_license: .asciz "--license"
r2p_opt_commit: .asciz "--commit"
r2p_opt_path: .asciz "--source-path"
r2p_opt_repository: .asciz "--repository"
r2p_opt_source_target: .asciz "--source-target"
r2p_opt_executable: .asciz "--executable"
r2p_error: .asciz "project publication preparation failed; check committed source, paths, limits and local Git objects"
r2p_error_root: .asciz "project must select the Git repository root; use --source-path for a committed subtree"
r2p_error_lock: .asciz "published project source cannot contain asm.lock; remove the committed consumer lock"
r2p_error_credential: .asciz "project credential is inside the packaged subtree; move it outside the source directory"
r2p_error_credential_object: .asciz "publication object is the credential file; select a separate prepared artifact"
r2p_git: .asciz "/usr/bin/git"
r2p_gzip: .asciz "/usr/bin/gzip"
r2p_git_no_replace: .asciz "--no-replace-objects"
r2p_git_literal: .asciz "--literal-pathspecs"
r2p_git_config: .asciz "-c"
r2p_git_monitor: .asciz "core.fsmonitor=false"
r2p_git_hooks: .asciz "core.hooksPath=/dev/null"
r2p_rev_parse: .asciz "rev-parse"
r2p_prefix: .asciz "--show-prefix"
r2p_verify: .asciz "--verify"
r2p_end_options: .asciz "--end-of-options"
r2p_head: .asciz "HEAD"
r2p_commit_suffix: .asciz "^{commit}"
r2p_ls_tree: .asciz "ls-tree"
r2p_tree_flags: .asciz "-rlz"
r2p_full_tree: .asciz "--full-tree"
r2p_cat_file: .asciz "cat-file"
r2p_batch_option: .asciz "--batch"
r2p_gzip_flags: .asciz "-n9c"
r2p_info_suffix: .asciz "/project.info"
r2p_tree_suffix: .asciz "/project.tree"
r2p_request_suffix: .asciz "/project.requests"
r2p_batch_suffix: .asciz "/project.batch"
r2p_tar_suffix: .asciz "/project.tar"
r2p_archive_suffix: .asciz "/project.archive"
r2p_manifest_suffix: .asciz "/project.json"
r2p_candidate_suffix: .asciz "/project.candidate"
r2p_lock_name: .asciz "asm.lock"
r2p_blob_word: .asciz "blob"
r2p_empty: .asciz ""
r2p_lf: .asciz "\n"
r2p_parent: .asciz ".."
r2p_json_start: .asciz "{\n  \"artifacts\": [\n"
r2p_json_comma_lf: .asciz ",\n"
r2p_json_abi: .asciz "    {\n      \"abi\": "
r2p_json_bytes: .asciz ",\n      \"bytes\": "
r2p_json_features: .asciz ",\n      \"cpu_features\": [],\n      \"format\": "
r2p_json_isa: .asciz ",\n      \"isa\": "
r2p_json_kind: .asciz ",\n      \"kind\": "
r2p_json_os: .asciz ",\n      \"os\": "
r2p_json_sha: .asciz ",\n      \"sha256\": "
r2p_json_artifact_end: .asciz "\n    }"
r2p_json_license: .asciz "\n  ],\n  \"license\": "
r2p_json_dependencies: .asciz "\n  ],\n  \"dependencies\": [\n"
r2p_json_dependency_name: .asciz "    {\n      \"name\": "
r2p_json_requirement: .asciz ",\n      \"requirement\": "
r2p_json_name: .asciz ",\n  \"name\": "
r2p_json_owner: .asciz ",\n  \"owner_id\": "
r2p_json_archive: .asciz ",\n  \"schema\": 2,\n  \"source\": {\n    \"archive\": {\n      \"bytes\": "
r2p_json_archive_sha: .asciz ",\n      \"sha256\": "
r2p_json_algorithm: .asciz "\n    },\n    \"commit\": {\n      \"algorithm\": "
r2p_json_commit: .asciz ",\n      \"digest\": "
r2p_json_path: .asciz "\n    },\n    \"path\": "
r2p_json_repository: .asciz ",\n    \"repository\": "
r2p_json_summary: .asciz "\n  },\n  \"summary\": "
r2p_json_version: .asciz ",\n  \"version\": "
r2p_json_end: .asciz "\n}\n"
r2p_env_system: .asciz "GIT_CONFIG_NOSYSTEM=1"
r2p_env_global: .asciz "GIT_CONFIG_GLOBAL=/dev/null"
r2p_env_system_file: .asciz "GIT_CONFIG_SYSTEM=/dev/null"
r2p_env_replace: .asciz "GIT_NO_REPLACE_OBJECTS=1"
r2p_env_lazy: .asciz "GIT_NO_LAZY_FETCH=1"
r2p_env_protocol: .asciz "GIT_ALLOW_PROTOCOL="
r2p_env_locks: .asciz "GIT_OPTIONAL_LOCKS=0"
r2p_env_prompt: .asciz "GIT_TERMINAL_PROMPT=0"
r2p_env_locale: .asciz "LC_ALL=C"
.balign 8
r2p_environment: .quad r2p_env_system,r2p_env_global,r2p_env_system_file,r2p_env_replace,r2p_env_lazy,r2p_env_protocol,r2p_env_locks,r2p_env_prompt,r2p_env_locale,0
r2p_prefix_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_rev_parse,r2p_prefix,0
r2p_commit_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_rev_parse,r2p_verify,r2p_end_options,r2p_commit_spec,0
.section .data
r2p_tree_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_ls_tree,r2p_tree_flags,r2p_full_tree,r2_commit,registry_separator,0,0
.section .rodata
r2p_batch_argv: .quad r2p_git,r2p_git_no_replace,r2p_git_literal,r2p_git_config,r2p_git_monitor,r2p_git_config,r2p_git_hooks,r2p_cat_file,r2p_batch_option,0
r2p_gzip_argv: .quad r2p_gzip,r2p_gzip_flags,0
r2p_suffixes: .quad r2p_info_suffix,r2p_tree_suffix,r2p_request_suffix,r2p_batch_suffix,r2p_tar_suffix,r2p_archive_suffix,r2p_manifest_suffix,r2p_candidate_suffix,0
r2p_excluded: .asciz ".git\0.asm\0.venv\0__pycache__\0build\0dist\0"
.section .bss
.balign 8
r2p_project: .skip 8
r2p_name: .skip 8
r2p_owner: .skip 8
r2p_summary: .skip 8
r2p_license: .skip 8
r2p_commit: .skip 8
r2p_source_path: .skip 8
r2p_repository: .skip 8
r2p_selections: .skip 8
r2p_executable_paths: .skip 48
r2p_executable_records: .skip 48
r2p_repo_fd: .skip 8
r2p_limit: .skip 8
r2p_rlimit: .skip 16
r2p_child_status: .skip 8
r2p_path: .skip 160
r2p_manifest_path: .skip 160
r2p_subtree_walk: .skip 241
r2p_credential_parent: .skip 4096
r2p_credential_dev: .skip 8
r2p_credential_ino: .skip 8
r2p_commit_spec: .skip 80
r2p_info: .skip 4097
r2p_oid_length: .skip 8
r2p_algorithm: .skip 8
r2p_tree_data: .skip R2P_LIST + 1
r2p_tree_end: .skip 8
r2p_records: .skip R2P_FILES * R2P_RECORD
r2p_count: .skip 8
r2p_tar_bytes: .skip 8
r2p_batch_base: .skip 8
r2p_batch_length: .skip 8
r2p_batch_end: .skip 8
r2p_cursor: .skip 8
r2p_header: .skip 512
r2p_zeroes: .skip 1024
r2p_owned: .skip 1
