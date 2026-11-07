/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and README.md#license for the terms and scope.
 */
.equ SELF_VERIFIER_DEADLINE_SECONDS, 120

/* GitHub CLI supplies Sigstore verification and its own trusted-root handling.
 * Asm supplies fixed identity constraints and checks the verified repository ID.
 * Release-supplied roots, GH credentials, custom hosts, and shell expressions are
 * never accepted. This manual protocol provides no registry freshness or
 * revocation guarantee. It does not implement a TUF release-metadata client.
 */
.section .text

/* Build a fresh verifier HOME/config/cache inside the private stage, then
 * require the fixed executable to report a stable version >=2.93.0.
 * Inputs: held self_stage_fd, parent path, private stage name. Output:
 * self_gh_environment strings (each 8192 bytes), otherwise fatal error.
 * Stack: 32 saved bytes plus 16 alignment bytes. Only proxy routing entries
 * are copied from the calling environment. */
self_prepare_verifier:
    ARM_SAVE x19
    ARM_SAVE x21
    sub sp, sp, #16
    ARM_CALL self_copy_proxy_environment
    ARM_ADDR x16, self_stage_fd
    ldr x10, [x16]
    mov x0, x10
    ARM_ADDR x16, self_verifier_directory
    mov x1, x16
    ARM_IMM w10, 448
    mov w2, w10
    ARM_CALL arm_mkdirat
    tst x9, x9
    b.mi self_io_error
    ARM_ADDR x16, self_home_environment
    mov x0, x16
    ARM_ADDR x16, self_home_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_parent_path
    mov x1, x16
    ARM_CALL copy_string
    ARM_IMM w10, 47
    mov x16, x9
    strb w10, [x16]
    mov x16, x9
    add x16, x16, #1
    mov x0, x16
    ARM_ADDR x16, registry_temp_dir
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x16, self_verifier_suffix
    mov x1, x16
    ARM_CALL copy_string
    ARM_ADDR x16, self_home_environment + 5
    mov x21, x16
    ARM_ADDR x16, self_config_environment
    mov x0, x16
    ARM_ADDR x16, self_config_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x1, x21
    ARM_CALL copy_string
    ARM_ADDR x16, self_cache_environment
    mov x0, x16
    ARM_ADDR x16, self_cache_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x1, x21
    ARM_CALL copy_string
    ARM_ADDR x16, self_xdg_environment
    mov x0, x16
    ARM_ADDR x16, self_xdg_prefix
    mov x1, x16
    ARM_CALL copy_string
    mov x0, x9
    mov x1, x21
    ARM_CALL copy_string
.ifdef ASM_TRUSTED_DISTRIBUTION
    ARM_CALL self_prepare_embedded_verifier
.else
    ARM_ADDR x16, self_gh_path
    mov x0, x16
    ARM_ADDR x16, self_version_argv
    mov x1, x16
    ARM_ADDR x16, self_gh_environment
    mov x2, x16
    ARM_CALL self_capture
    tst w9, w9
    b.ne self_verifier_missing
    ARM_ADDR x16, self_capture_buffer
    mov x0, x16
    ARM_ADDR x16, self_gh_version_prefix
    mov x1, x16
    ARM_CALL self_prefix
    tst x9, x9
    b.eq self_verifier_missing
    mov x1, x9
    ARM_ADDR x16, self_gh_version
    mov x0, x16
    eor w3, w3, w3
    tst w3, w3
.Lself_gh_version_character:
    ARM_IMM w11, 32
    cmp w3, w11
    b.hi self_verifier_missing
    mov x16, x1
    add x16, x16, x3
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    ARM_IMM w11, 32
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_gh_version_end
    and w10, w9, #255
    ARM_IMM w11, 10
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.eq .Lself_gh_version_end
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq self_verifier_missing
    and w10, w9, #255
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_IMM w11, 1
    adds w3, w3, w11
    b .Lself_gh_version_character
.Lself_gh_version_end:
    ARM_IMM w10, 0
    mov x16, x0
    add x16, x16, x3
    strb w10, [x16]
    ARM_CALL registry_valid_version
    tst w9, w9
    b.eq self_verifier_missing
    ARM_ADDR x16, self_gh_version
    mov x0, x16
    ARM_ADDR x16, self_gh_minimum_version
    mov x1, x16
    ARM_CALL registry_version_compare
    ARM_IMM w11, 0
    cmp w9, w11
    b.lt self_verifier_missing
.endif
    add sp, sp, #16
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* Copy only the eight standard proxy variables into bounded child env arrays.
 * Routing is configurable; certificate roots, signatures, identities, GH
 * tokens, hosts, and config remain fixed. Each complete entry is <=4096 bytes;
 * duplicate names fail rather than let two child tools interpret them
 * differently. Values remain borrowed from the initial process environment.
 * Output: <=8 pointers plus NUL in network env, appended after 10 fixed gh
 * entries. Stack: 80 saved bytes. No environment values are logged. */
self_copy_proxy_environment:
    ARM_SAVE x19
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    ARM_ADDR x16, envp
    ldr x10, [x16]
    mov x21, x10
    eor w23, w23, w23
    tst w23, w23
    eor w24, w24, w24
    tst w24, w24
.Lself_proxy_entry:
    mov x16, x21
    ldr x10, [x16]
    mov x22, x10
    tst x22, x22
    b.eq .Lself_proxy_done
    eor w19, w19, w19
    tst w19, w19
.Lself_proxy_name:
    mov x0, x22
    ARM_ADDR x16, self_proxy_prefixes
    mov x9, x16
    mov x16, x9
    add x16, x16, x19, lsl #3
    ldr x10, [x16]
    mov x1, x10
    ARM_CALL self_prefix
    tst x9, x9
    b.ne .Lself_proxy_found
    ARM_IMM w11, 1
    adds w19, w19, w11
    ARM_IMM w11, 8
    cmp w19, w11
    b.lo .Lself_proxy_name
    b .Lself_proxy_next
.Lself_proxy_found:
    ARM_IMM x12, 1
    lslv x12, x12, x19
    and x10, x24, x12
    cmp x10, #1
    b.cs self_proxy_error
    ARM_IMM x12, 1
    lslv x12, x12, x19
    and x10, x24, x12
    cmp x10, #1
    orr x24, x24, x12
    mov x0, x22
    ARM_CALL strlen
    ARM_IMM x11, 4096
    cmp x9, x11
    b.hi self_proxy_error
    ARM_ADDR x16, self_network_environment
    mov x9, x16
    mov x16, x9
    add x16, x16, x23, lsl #3
    str x22, [x16]
    ARM_ADDR x16, self_gh_environment + 10*8
    mov x9, x16
    mov x16, x9
    add x16, x16, x23, lsl #3
    str x22, [x16]
    ARM_IMM x11, 1
    adds x23, x23, x11
.Lself_proxy_next:
    ARM_IMM x11, 8
    adds x21, x21, x11
    b .Lself_proxy_entry
.Lself_proxy_done:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x19
    ret

/* x0=terminated input, x1=terminated prefix. Output x9 points immediately
 * after a matching prefix, else zero. Does not read past the input NUL.
 * Scratch x9/x3/x0/x1; no local stack or mutation. */
self_prefix:
    mov x16, x1
    ldrb w10, [x16]
    bfi x9, x10, #0, #8
    and w10, w9, #255
    and w11, w9, #255
    lsl w10, w10, #24
    lsl w11, w11, #24
    tst w10, w11
    b.eq .Lself_prefix_match
    and w10, w9, #255
    mov x16, x0
    ldrb w11, [x16]
    lsl w10, w10, #24
    lsl w11, w11, #24
    cmp w10, w11
    b.ne .Lself_prefix_no
    ARM_IMM x11, 1
    adds x1, x1, x11
    ARM_IMM x11, 1
    adds x0, x0, x11
    b self_prefix
.Lself_prefix_match:
    mov x9, x0
    ret
.Lself_prefix_no:
    eor w9, w9, w9
    tst w9, w9
    ret

/* Download the <=1 MiB manifest and Sigstore bundle from the exact versioned
 * release. Verify manifest identity first; parse all metadata natively; then
 * verify manifest and payload with the same exact source/signer commit.
 * Each verifier result must contain exactly the pinned numeric repository ID.
 * Returns only after all checks succeed. Never executes the candidate.
 * Stack: 16 saved bytes. Owns bounded manifest buffer and gh argument array. */
self_verify_release:
    ARM_SAVE x19
    ARM_ADDR x16, self_manifest_url
    mov x0, x16
    ARM_ADDR x16, self_manifest_path
    mov x1, x16
    ARM_ADDR x16, registry_index_max
    mov x2, x16
    ARM_CALL registry_download
    tst w9, w9
    b.ne self_download_error
    ARM_ADDR x16, self_bundle_url
    mov x0, x16
    ARM_ADDR x16, self_bundle_path
    mov x1, x16
    ARM_ADDR x16, registry_index_max
    mov x2, x16
    ARM_CALL registry_download
    tst w9, w9
    b.ne self_download_error
    ARM_ADDR x16, self_manifest_path
    mov x0, x16
    ARM_CALL self_bounded_regular_file
    ARM_ADDR x16, self_bundle_path
    mov x0, x16
    ARM_CALL self_bounded_regular_file
    ARM_ADDR x16, self_bundle_path
    mov x9, x16
    ARM_ADDR x16, self_verify_argv + 16*8
    str x9, [x16]
    ARM_ADDR x16, self_manifest_path
    mov x9, x16
    ARM_ADDR x16, self_verify_argv + 3*8
    str x9, [x16]
    ARM_IMM x10, 0
    ARM_ADDR x16, self_verify_argv + 23*8
    str x10, [x16]
    ARM_CALL self_verify_attestation
    ARM_CALL self_load_manifest
    ARM_ADDR x16, self_manifest_data
    mov x0, x16
    ARM_ADDR x16, self_manifest_length
    ldr x10, [x16]
    mov x1, x10
    ARM_ADDR x16, registry_selected
    ldr x10, [x16]
    mov x2, x10
    ARM_CALL self_parse_release
    tst w9, w9
    b.ne self_metadata_error
    ARM_ADDR x16, self_source_digest_option
    mov x9, x16
    ARM_ADDR x16, self_verify_argv + 23*8
    str x9, [x16]
    ARM_ADDR x16, self_source_commit
    mov x9, x16
    ARM_ADDR x16, self_verify_argv + 24*8
    str x9, [x16]
    ARM_ADDR x16, self_verify_argv + 26*8
    str x9, [x16]
    ARM_ADDR x16, self_signer_digest_option
    mov x9, x16
    ARM_ADDR x16, self_verify_argv + 25*8
    str x9, [x16]
    ARM_CALL self_verify_attestation
    ARM_ADDR x16, registry_temp_payload
    mov x9, x16
    ARM_ADDR x16, self_verify_argv + 3*8
    str x9, [x16]
    ARM_CALL self_verify_attestation
    ARM_RESTORE x19
    ret

/* Read only the parsed certificate repository ID from a successful verifier.
 * gh --jq is a fixed argument, never a shell command or untrusted expression.
 * The exact single-line result rejects absent, duplicate, or renamed IDs.
 * Stack: 16 alignment bytes. */
self_verify_attestation:
    sub sp, sp, #16
.ifdef ASM_TRUSTED_DISTRIBUTION
    ARM_CALL self_embedded_provenance
.else
    ARM_ADDR x16, self_gh_path
    mov x0, x16
    ARM_ADDR x16, self_verify_argv
    mov x1, x16
    ARM_ADDR x16, self_gh_environment
    mov x2, x16
    ARM_CALL self_capture
.endif
    tst w9, w9
    b.ne self_attestation_error
    ARM_ADDR x16, self_capture_length
    ldr x10, [x16]
    ARM_IMM x11, 11
    cmp x10, x11
    b.ne self_attestation_error
    ARM_ADDR x16, self_capture_buffer
    mov x0, x16
    ARM_ADDR x16, self_repository_id_line
    mov x1, x16
    ARM_CALL streq
    tst w9, w9
    b.eq self_attestation_error
    add sp, sp, #16
    ret

/* x0=owned staged file path. Require a regular single-link file 1..1MiB.
 * lstat refuses final symlinks; private ancestor is owned and held. Output:
 * x9=byte size, or terminal failure. Scratch stat buffer 128 bytes. */
self_bounded_regular_file:
    ARM_ADDR x16, self_check_stat
    mov x1, x16
    ARM_CALL arm_lstat
    tst x9, x9
    b.mi self_metadata_error
    ARM_ADDR x16, self_check_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne self_metadata_error
    ARM_ADDR x16, self_check_stat + 20
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.ne self_metadata_error
    ARM_ADDR x16, self_check_stat + 48
    ldr x10, [x16]
    mov x9, x10
    tst x9, x9
    b.eq self_metadata_error
    ARM_IMM x11, INDEX_LIMIT
    cmp x9, x11
    b.hi self_metadata_error
    ret

/* Read the attested manifest into INDEX_LIMIT+1 owned bytes. Open without
 * following links; check the final length against fstat; retry EINTR.
 * Output: buffer plus NUL and manifest_length. Stack 48 saved bytes. */
self_load_manifest:
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_ADDR x16, self_manifest_path
    mov x0, x16
    ARM_IMM w10, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi self_metadata_error
    mov x21, x9
    mov x0, x21
    ARM_ADDR x16, self_check_stat
    mov x1, x16
    ARM_CALL arm_fstat
    tst x9, x9
    b.mi .Lself_manifest_close_error
    ARM_ADDR x16, self_check_stat + 16
    ldr w10, [x16]
    mov w9, w10
    ARM_IMM w11, 61440
    and w9, w9, w11
    tst w9, w9
    ARM_IMM w11, 32768
    cmp w9, w11
    b.ne .Lself_manifest_close_error
    ARM_ADDR x16, self_check_stat + 48
    ldr x10, [x16]
    mov x23, x10
    tst x23, x23
    b.eq .Lself_manifest_close_error
    ARM_IMM x11, INDEX_LIMIT
    cmp x23, x11
    b.hi .Lself_manifest_close_error
    eor w22, w22, w22
    tst w22, w22
.Lself_manifest_read:
    mov x0, x21
    ARM_ADDR x16, self_manifest_data
    mov x1, x16
    adds x1, x1, x22
    ARM_IMM w10, INDEX_LIMIT + 1
    mov w2, w10
    subs x2, x2, x22
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lself_manifest_read
    tst x9, x9
    b.mi .Lself_manifest_close_error
    b.eq .Lself_manifest_end
    adds x22, x22, x9
    ARM_IMM x11, INDEX_LIMIT
    cmp x22, x11
    b.hi .Lself_manifest_close_error
    b .Lself_manifest_read
.Lself_manifest_end:
    cmp x22, x23
    b.ne .Lself_manifest_close_error
    mov x0, x21
    ARM_CALL arm_close
    tst x9, x9
    b.mi self_metadata_error
    ARM_ADDR x16, self_manifest_data
    mov x9, x16
    ARM_IMM w10, 0
    mov x16, x9
    add x16, x16, x22
    strb w10, [x16]
    ARM_ADDR x16, self_manifest_length
    str x22, [x16]
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ret
.Lself_manifest_close_error:
    mov x0, x21
    ARM_CALL arm_close
    b self_metadata_error

/* x0=fixed executable, x1=argv, x2=explicit environment. Fork and capture
 * stdout into self_capture_buffer[4098], rejecting >4096 bytes. Child stdin
 * is /dev/null, stderr is inherited, and alarm bounds each child to 120s.
 * Output w9=exit status (128+signal; 127 for child setup/exec/fork failure),
 * capture_length plus NUL. No shell. Stack 96 saved bytes plus 16 alignment
 * bytes for the absolute-path check; FDs close on every parent return path.
 */
self_capture:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_SAVE x23
    ARM_SAVE x24
    mov x21, x0
    mov x22, x1
    mov x23, x2
    sub sp, sp, #16
    ARM_CALL self_check_absolute_installation
    add sp, sp, #16
    ARM_IMM x10, 0
    ARM_ADDR x16, self_capture_length
    str x10, [x16]
    ARM_IMM w10, 0
    ARM_ADDR x16, self_capture_buffer
    strb w10, [x16]
    ARM_ADDR x16, self_capture_pipe
    mov x0, x16
    ARM_IMM w10, O_CLOEXEC
    mov w1, w10
    ARM_CALL arm_pipe2
    tst x9, x9
    b.mi .Lself_capture_fork_error
    ARM_CALL arm_fork
    tst x9, x9
    b.mi .Lself_capture_pipe_error
    b.eq .Lself_capture_child
    mov x19, x9
    ARM_ADDR x16, self_capture_pipe + 4
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arm_close
    eor w24, w24, w24
    tst w24, w24
    eor w20, w20, w20
    tst w20, w20
.Lself_capture_read:
    ARM_ADDR x16, self_capture_pipe
    ldr w10, [x16]
    mov w0, w10
    ARM_ADDR x16, self_capture_buffer
    mov x1, x16
    adds x1, x1, x24
    ARM_IMM w10, 4097
    mov w2, w10
    subs x2, x2, x24
    ARM_CALL arm_read
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lself_capture_read
    tst x9, x9
    b.mi .Lself_capture_kill
    b.eq .Lself_capture_wait
    adds x24, x24, x9
    ARM_IMM x11, 4096
    cmp x24, x11
    b.hi .Lself_capture_kill
    b .Lself_capture_read
.Lself_capture_kill:
    ARM_IMM w10, 1
    mov w20, w10
    mov x0, x19
    ARM_IMM w10, 9
    mov w1, w10
    ARM_CALL arm_kill
.Lself_capture_wait:
    ARM_ADDR x16, self_capture_pipe
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arm_close
.Lself_capture_wait_retry:
    mov x0, x19
    ARM_ADDR x16, self_capture_wait_status
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    eor w6, w6, w6
    tst w6, w6
    ARM_CALL arm_wait4
    ARM_IMM x11, -4
    cmp x9, x11
    b.eq .Lself_capture_wait_retry
    tst x9, x9
    b.mi .Lself_capture_fork_error
    ARM_ADDR x16, self_capture_length
    str x24, [x16]
    ARM_ADDR x16, self_capture_buffer
    mov x9, x16
    ARM_IMM w10, 0
    mov x16, x9
    add x16, x16, x24
    strb w10, [x16]
    tst w20, w20
    b.ne .Lself_capture_failed
    ARM_ADDR x16, self_capture_wait_status
    ldr w10, [x16]
    mov w9, w10
    mov w2, w9
    ARM_IMM w11, 127
    and w2, w2, w11
    tst w2, w2
    b.ne .Lself_capture_signaled
    lsr w9, w9, #8
    tst w9, w9
    ARM_IMM w11, 255
    and w9, w9, w11
    tst w9, w9
    b .Lself_capture_return
.Lself_capture_signaled:
    mov x16, x2
    add x16, x16, #128
    mov w9, w16
    b .Lself_capture_return
.Lself_capture_failed:
    ARM_IMM w10, 1
    mov w9, w10
    b .Lself_capture_return
.Lself_capture_pipe_error:
    ARM_ADDR x16, self_capture_pipe
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arm_close
    ARM_ADDR x16, self_capture_pipe + 4
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arm_close
.Lself_capture_fork_error:
    ARM_IMM w10, 127
    mov w9, w10
.Lself_capture_return:
    ARM_RESTORE x24
    ARM_RESTORE x23
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
.Lself_capture_child:
    ARM_ADDR x16, self_capture_pipe
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arm_close
    ARM_ADDR x16, self_capture_pipe + 4
    ldr w10, [x16]
    mov w0, w10
    ARM_IMM w10, 1
    mov w1, w10
    ARM_CALL arm_dup2
    tst x9, x9
    b.mi .Lself_capture_child_error
    /* dup2(fd,fd) leaves CLOEXEC set, so clear stdout's flag explicitly. */
    ARM_IMM w10, 1
    mov w0, w10
    ARM_IMM w10, 2
    mov w1, w10
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_fcntl
    tst x9, x9
    b.mi .Lself_capture_child_error
    ARM_ADDR x16, self_capture_pipe + 4
    ldr w10, [x16]
    ARM_IMM w11, 1
    cmp w10, w11
    b.eq .Lself_capture_child_stdin
    ARM_ADDR x16, self_capture_pipe + 4
    ldr w10, [x16]
    mov w0, w10
    ARM_CALL arm_close
.Lself_capture_child_stdin:
    ARM_ADDR x16, self_dev_null
    mov x0, x16
    eor w1, w1, w1
    tst w1, w1
    eor w2, w2, w2
    tst w2, w2
    ARM_CALL arm_open
    tst x9, x9
    b.mi .Lself_capture_child_error
    mov x20, x9
    mov x0, x9
    eor w1, w1, w1
    tst w1, w1
    ARM_CALL arm_dup2
    tst x9, x9
    b.mi .Lself_capture_child_error
    tst x20, x20
    b.eq .Lself_capture_child_alarm
    mov x0, x20
    ARM_CALL arm_close
.Lself_capture_child_alarm:
    /* Ignored dispositions and blocked masks survive execve. Reset SIGALRM
     * and explicitly unblock it before enforcing the child deadline. The
     * Linux AArch64 kernel signal set is eight bytes; bit 13 is SIGALRM. */
    ARM_IMM w10, 14
    mov w0, w10
    ARM_ADDR x16, self_default_signal
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    ARM_IMM w10, 8
    mov w6, w10
    ARM_CALL arm_rt_sigaction
    tst x9, x9
    b.mi .Lself_capture_child_error
    ARM_IMM w10, 1 /* SIG_UNBLOCK */
    mov w0, w10
    ARM_ADDR x16, self_alarm_signal_mask
    mov x1, x16
    eor w2, w2, w2
    tst w2, w2
    ARM_IMM w10, 8
    mov w6, w10
    ARM_CALL arm_rt_sigprocmask
    tst x9, x9
    b.mi .Lself_capture_child_error
    ARM_IMM w10, SELF_VERIFIER_DEADLINE_SECONDS
    mov w0, w10
    ARM_CALL arm_alarm
    tst x9, x9
    b.mi .Lself_capture_child_error
    mov x0, x21
    mov x1, x22
    mov x2, x23
    ARM_CALL arm_execve
.Lself_capture_child_error:
    ARM_IMM w10, 127
    mov w0, w10
    b exit_code

self_verifier_missing:
    ARM_ADDR x16, self_error_verifier
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_attestation_error:
    ARM_ADDR x16, self_error_attestation
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_metadata_error:
    ARM_ADDR x16, self_error_metadata
    mov x0, x16
    ARM_IMM w10, 1
    mov w1, w10
    b self_fail
self_proxy_error:
    ARM_ADDR x16, self_error_proxy
    mov x0, x16
    ARM_IMM w10, 2
    mov w1, w10
    b self_fail

.section .rodata
self_gh_path: .asciz "/usr/bin/gh"
self_dev_null: .asciz "/dev/null"
self_verifier_directory: .asciz "verifier"
self_verifier_suffix: .asciz "/verifier"
self_home_prefix: .asciz "HOME="
self_config_prefix: .asciz "GH_CONFIG_DIR="
self_cache_prefix: .asciz "XDG_CACHE_HOME="
self_xdg_prefix: .asciz "XDG_CONFIG_HOME="
self_gh_host_environment: .asciz "GH_HOST=github.com"
self_gh_prompt_environment: .asciz "GH_PROMPT_DISABLED=1"
self_gh_update_environment: .asciz "GH_NO_UPDATE_NOTIFIER=1"
self_gh_extension_environment: .asciz "GH_NO_EXTENSION_UPDATE_NOTIFIER=1"
self_locale_environment: .asciz "LC_ALL=C"
self_lang_environment: .asciz "LANG=C"
self_gh_version_option: .asciz "--version"
self_gh_version_prefix: .asciz "gh version "
self_gh_minimum_version: .asciz "2.93.0"
self_attestation_command: .asciz "attestation"
self_verify_command: .asciz "verify"
self_repository_option: .asciz "--repo"
self_certificate_option: .asciz "--cert-identity"
self_certificate_identity: .asciz "https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main"
self_issuer_option: .asciz "--cert-oidc-issuer"
self_issuer_identity: .asciz "https://token.actions.githubusercontent.com"
self_source_ref_option: .asciz "--source-ref"
self_source_ref: .asciz "refs/heads/main"
self_hosted_option: .asciz "--deny-self-hosted-runners"
self_predicate_option: .asciz "--predicate-type"
self_predicate_type: .asciz "https://slsa.dev/provenance/v1"
self_bundle_option: .asciz "--bundle"
self_format_option: .asciz "--format"
self_json_format: .asciz "json"
self_jq_option: .asciz "--jq"
self_repository_expression: .asciz ".[].verificationResult.signature.certificate.sourceRepositoryIdentifier"
self_repository_id_line: .asciz "1441332955\n"
self_hostname_option: .asciz "--hostname"
self_hostname: .asciz "github.com"
self_source_digest_option: .asciz "--source-digest"
self_signer_digest_option: .asciz "--signer-digest"
self_error_verifier: .asciz "self update requires GitHub CLI 2.93.0 or later at /usr/bin/gh; install it from cli.github.com and try again"
self_error_attestation: .asciz "release attestation verification failed; the previous binary remains; check the official release and verifier connection"
self_error_metadata: .asciz "the attested release metadata does not match the selected Asm artifact; the previous binary remains; check the release"
self_error_proxy: .asciz "proxy environment entries must be unique and at most 4096 bytes; correct the proxy settings and try again"
self_proxy_https_upper: .asciz "HTTPS_PROXY="
self_proxy_https_lower: .asciz "https_proxy="
self_proxy_http_upper: .asciz "HTTP_PROXY="
self_proxy_http_lower: .asciz "http_proxy="
self_proxy_no_upper: .asciz "NO_PROXY="
self_proxy_no_lower: .asciz "no_proxy="
self_proxy_all_upper: .asciz "ALL_PROXY="
self_proxy_all_lower: .asciz "all_proxy="
.balign 8
self_proxy_prefixes:
    .quad self_proxy_https_upper, self_proxy_https_lower, self_proxy_http_upper, self_proxy_http_lower
    .quad self_proxy_no_upper, self_proxy_no_lower, self_proxy_all_upper, self_proxy_all_lower
self_default_signal: .quad 0, 0, 0, 0
self_alarm_signal_mask: .quad 1 << (14 - 1)
self_version_argv: .quad self_gh_path, self_gh_version_option, 0
.section .data
.balign 8
self_gh_environment:
    .quad self_home_environment, self_config_environment, self_cache_environment
    .quad self_xdg_environment, self_gh_host_environment, self_gh_prompt_environment
    .quad self_gh_update_environment, self_gh_extension_environment
    .quad self_locale_environment, self_lang_environment
    .rept 9
    .quad 0
    .endr
.balign 8
self_verify_argv:
    .quad self_gh_path, self_attestation_command, self_verify_command, 0
    .quad self_repository_option, self_package, self_certificate_option, self_certificate_identity
    .quad self_issuer_option, self_issuer_identity, self_source_ref_option, self_source_ref
    .quad self_hosted_option, self_predicate_option, self_predicate_type
    .quad self_bundle_option, 0, self_format_option, self_json_format
    .quad self_jq_option, self_repository_expression, self_hostname_option, self_hostname
    .quad 0, 0, 0, 0, 0
.section .bss
.balign 8
self_manifest_length: .skip 8
self_network_environment: .skip 9 * 8
self_capture_length: .skip 8
self_capture_pipe: .skip 8
self_capture_wait_status: .skip 4
self_gh_version: .skip 33
self_capture_buffer: .skip 4098
self_home_environment: .skip 8192
self_config_environment: .skip 8192
self_cache_environment: .skip 8192
self_xdg_environment: .skip 8192
self_manifest_data: .skip INDEX_LIMIT + 1
