/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/self_update_verify.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
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
    RV_SAVE s0
    RV_SAVE s2
    li s10, 16
    sub sp, sp, s10
    RV_CALL self_copy_proxy_environment
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD t1, 8
    mv a0, t1
    RV_ADDR s6, self_verifier_directory
    mv a1, s6
    RV_IMM t1, 448, 32
    mv a2, t1
    RV_ZEXT a2
    RV_CALL rv_mkdirat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_io_error
    RV_ADDR s6, self_home_environment
    mv a0, s6
    RV_ADDR s6, self_home_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_parent_path
    mv a1, s6
    RV_CALL copy_string
    RV_IMM t1, 47, 32
    mv s6, t0
    mv s8, s6
    RV_STORE t1, 1
    mv s6, t0
    li s10, 1
    add s6, s6, s10
    mv a0, s6
    RV_ADDR s6, registry_temp_dir
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR s6, self_verifier_suffix
    mv a1, s6
    RV_CALL copy_string
    RV_ADDR s6, self_home_environment + 5
    mv s2, s6
    RV_ADDR s6, self_config_environment
    mv a0, s6
    RV_ADDR s6, self_config_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    mv a1, s2
    RV_CALL copy_string
    RV_ADDR s6, self_cache_environment
    mv a0, s6
    RV_ADDR s6, self_cache_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    mv a1, s2
    RV_CALL copy_string
    RV_ADDR s6, self_xdg_environment
    mv a0, s6
    RV_ADDR s6, self_xdg_prefix
    mv a1, s6
    RV_CALL copy_string
    mv a0, t0
    mv a1, s2
    RV_CALL copy_string
.ifdef ASM_TRUSTED_DISTRIBUTION
    RV_CALL self_prepare_embedded_verifier
.else
    RV_ADDR s6, self_gh_path
    mv a0, s6
    RV_ADDR s6, self_version_argv
    mv a1, s6
    RV_ADDR s6, self_gh_environment
    mv a2, s6
    RV_CALL self_capture
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_verifier_missing
    RV_ADDR s6, self_capture_buffer
    mv a0, s6
    RV_ADDR s6, self_gh_version_prefix
    mv a1, s6
    RV_CALL self_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, self_verifier_missing
    mv a1, t0
    RV_ADDR s6, self_gh_version
    mv a0, s6
    mv s10, a3
    xor a3, a3, s10
    RV_ZEXT a3
    mv s8, a3
    mv s10, a3
    RV_FLAGS and, 32
.Lself_gh_version_character:
    RV_IMM t2, 32, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND hi, self_verifier_missing
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
    RV_IMM t2, 32, 32
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_gh_version_end
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
    RV_BCOND eq, .Lself_gh_version_end
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
    RV_BCOND eq, self_verifier_missing
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_IMM t2, 1, 32
    mv s8, a3
    mv s10, t2
    RV_FLAGS add, 32
    mv a3, s11
    tail .Lself_gh_version_character
.Lself_gh_version_end:
    RV_IMM t1, 0, 32
    mv s6, a0
    mv s10, a3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_CALL registry_valid_version
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_verifier_missing
    RV_ADDR s6, self_gh_version
    mv a0, s6
    RV_ADDR s6, self_gh_minimum_version
    mv a1, s6
    RV_CALL registry_version_compare
    RV_IMM t2, 0, 32
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lt, self_verifier_missing
.endif
    li s10, 16
    add sp, sp, s10
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* Copy only the eight standard proxy variables into bounded child env arrays.
 * Routing is configurable; certificate roots, signatures, identities, GH
 * tokens, hosts, and config remain fixed. Each complete entry is <=4096 bytes;
 * duplicate names fail rather than let two child tools interpret them
 * differently. Values remain borrowed from the initial process environment.
 * Output: <=8 pointers plus NUL in network env, appended after 10 fixed gh
 * entries. Stack: 80 saved bytes. No environment values are logged. */
self_copy_proxy_environment:
    RV_SAVE s0
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    RV_ADDR s6, envp
    mv s8, s6
    RV_LOAD t1, 8
    mv s2, t1
    mv s10, s4
    xor s4, s4, s10
    RV_ZEXT s4
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 32
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
.Lself_proxy_entry:
    mv s6, s2
    mv s8, s6
    RV_LOAD t1, 8
    mv s3, t1
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 64
    RV_BCOND eq, .Lself_proxy_done
    mv s10, s0
    xor s0, s0, s10
    RV_ZEXT s0
    mv s8, s0
    mv s10, s0
    RV_FLAGS and, 32
.Lself_proxy_name:
    mv a0, s3
    RV_ADDR s6, self_proxy_prefixes
    mv t0, s6
    mv s6, t0
    mv s10, s0
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_CALL self_prefix
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND ne, .Lself_proxy_found
    RV_IMM t2, 1, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS add, 32
    mv s0, s11
    RV_IMM t2, 8, 32
    mv s8, s0
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lself_proxy_name
    tail .Lself_proxy_next
.Lself_proxy_found:
    RV_IMM t3, 1, 64
    sll t3, t3, s0
    mv s10, t3
    and t1, s5, s10
    mv s8, t1
    li s10, 1
    RV_FLAGS sub, 64
    RV_BCOND cs, self_proxy_error
    RV_IMM t3, 1, 64
    sll t3, t3, s0
    mv s10, t3
    and t1, s5, s10
    mv s8, t1
    li s10, 1
    RV_FLAGS sub, 64
    mv s10, t3
    or s5, s5, s10
    mv a0, s3
    RV_CALL strlen
    RV_IMM t2, 4096, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, self_proxy_error
    RV_ADDR s6, self_network_environment
    mv t0, s6
    mv s6, t0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s3, 8
    RV_ADDR s6, self_gh_environment + 10*8
    mv t0, s6
    mv s6, t0
    mv s10, s4
    slli s10, s10, 3
    add s6, s6, s10
    mv s8, s6
    RV_STORE s3, 8
    RV_IMM t2, 1, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS add, 64
    mv s4, s11
.Lself_proxy_next:
    RV_IMM t2, 8, 64
    mv s8, s2
    mv s10, t2
    RV_FLAGS add, 64
    mv s2, s11
    tail .Lself_proxy_entry
.Lself_proxy_done:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s0
    ret
/* a0=terminated input, a1=terminated prefix. Output t0 points immediately
 * after a matching prefix, else zero. Does not read past the input NUL.
 * Scratch t0/a3/a0/a1; no local stack or mutation. */
self_prefix:
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
    RV_BCOND eq, .Lself_prefix_match
    li s10, 255
    and t1, t0, s10
    RV_ZEXT t1
    mv s6, a0
    mv s8, s6
    RV_LOAD t2, 1
    slliw t1, t1, 24
    RV_ZEXT t1
    slliw t2, t2, 24
    RV_ZEXT t2
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lself_prefix_no
    RV_IMM t2, 1, 64
    mv s8, a1
    mv s10, t2
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t2, 1, 64
    mv s8, a0
    mv s10, t2
    RV_FLAGS add, 64
    mv a0, s11
    tail self_prefix
.Lself_prefix_match:
    mv t0, a0
    ret
.Lself_prefix_no:
    mv s10, t0
    xor t0, t0, s10
    RV_ZEXT t0
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    ret
/* Download the <=1 MiB manifest and Sigstore bundle from the exact versioned
 * release. Verify manifest identity first; parse all metadata natively; then
 * verify manifest and payload with the same exact source/signer commit.
 * Each verifier result must contain exactly the pinned numeric repository ID.
 * Returns only after all checks succeed. Never executes the candidate.
 * Stack: 16 saved bytes. Owns bounded manifest buffer and gh argument array. */
self_verify_release:
    RV_SAVE s0
    RV_ADDR s6, self_manifest_url
    mv a0, s6
    RV_ADDR s6, self_manifest_path
    mv a1, s6
    RV_ADDR s6, registry_index_max
    mv a2, s6
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_download_error
    RV_ADDR s6, self_bundle_url
    mv a0, s6
    RV_ADDR s6, self_bundle_path
    mv a1, s6
    RV_ADDR s6, registry_index_max
    mv a2, s6
    RV_CALL registry_download
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_download_error
    RV_ADDR s6, self_manifest_path
    mv a0, s6
    RV_CALL self_bounded_regular_file
    RV_ADDR s6, self_bundle_path
    mv a0, s6
    RV_CALL self_bounded_regular_file
    RV_ADDR s6, self_bundle_path
    mv t0, s6
    RV_ADDR s6, self_verify_argv + 16*8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, self_manifest_path
    mv t0, s6
    RV_ADDR s6, self_verify_argv + 3*8
    mv s8, s6
    RV_STORE t0, 8
    RV_IMM t1, 0, 64
    RV_ADDR s6, self_verify_argv + 23*8
    mv s8, s6
    RV_STORE t1, 8
    RV_CALL self_verify_attestation
    RV_CALL self_load_manifest
    RV_ADDR s6, self_manifest_data
    mv a0, s6
    RV_ADDR s6, self_manifest_length
    mv s8, s6
    RV_LOAD t1, 8
    mv a1, t1
    RV_ADDR s6, registry_selected
    mv s8, s6
    RV_LOAD t1, 8
    mv a2, t1
    RV_CALL self_parse_release
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_metadata_error
    RV_ADDR s6, self_source_digest_option
    mv t0, s6
    RV_ADDR s6, self_verify_argv + 23*8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, self_source_commit
    mv t0, s6
    RV_ADDR s6, self_verify_argv + 24*8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, self_verify_argv + 26*8
    mv s8, s6
    RV_STORE t0, 8
    RV_ADDR s6, self_signer_digest_option
    mv t0, s6
    RV_ADDR s6, self_verify_argv + 25*8
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL self_verify_attestation
    RV_ADDR s6, registry_temp_payload
    mv t0, s6
    RV_ADDR s6, self_verify_argv + 3*8
    mv s8, s6
    RV_STORE t0, 8
    RV_CALL self_verify_attestation
    RV_RESTORE s0
    ret
/* Read only the parsed certificate repository ID from a successful verifier.
 * gh --jq is a fixed argument, never a shell command or untrusted expression.
 * The exact single-line result rejects absent, duplicate, or renamed IDs.
 * Stack: 16 alignment bytes. */
self_verify_attestation:
    li s10, 16
    sub sp, sp, s10
.ifdef ASM_TRUSTED_DISTRIBUTION
    RV_CALL self_embedded_provenance
.else
    RV_ADDR s6, self_gh_path
    mv a0, s6
    RV_ADDR s6, self_verify_argv
    mv a1, s6
    RV_ADDR s6, self_gh_environment
    mv a2, s6
    RV_CALL self_capture
.endif
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND ne, self_attestation_error
    RV_ADDR s6, self_capture_length
    mv s8, s6
    RV_LOAD t1, 8
    RV_IMM t2, 11, 64
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND ne, self_attestation_error
    RV_ADDR s6, self_capture_buffer
    mv a0, s6
    RV_ADDR s6, self_repository_id_line
    mv a1, s6
    RV_CALL streq
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 32
    RV_BCOND eq, self_attestation_error
    li s10, 16
    add sp, sp, s10
    ret
/* a0=owned staged file path. Require a regular single-link file 1..1MiB.
 * lstat refuses final symlinks; private ancestor is owned and held. Output:
 * t0=byte size, or terminal failure. Scratch stat buffer 128 bytes. */
self_bounded_regular_file:
    RV_ADDR s6, self_check_stat
    mv a1, s6
    RV_CALL rv_lstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_metadata_error
    RV_ADDR s6, self_check_stat + 16
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
    RV_BCOND ne, self_metadata_error
    RV_ADDR s6, self_check_stat + 20
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND ne, self_metadata_error
    RV_ADDR s6, self_check_stat + 48
    mv s8, s6
    RV_LOAD t1, 8
    mv t0, t1
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND eq, self_metadata_error
    RV_IMM t2, INDEX_LIMIT, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, self_metadata_error
    ret
/* Read the attested manifest into INDEX_LIMIT+1 owned bytes. Open without
 * following links; check the final length against fstat; retry EINTR.
 * Output: buffer plus NUL and manifest_length. Stack 48 saved bytes. */
self_load_manifest:
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_ADDR s6, self_manifest_path
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
    RV_BCOND mi, self_metadata_error
    mv s2, t0
    mv a0, s2
    RV_ADDR s6, self_check_stat
    mv a1, s6
    RV_CALL rv_fstat
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_manifest_close_error
    RV_ADDR s6, self_check_stat + 16
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
    RV_BCOND ne, .Lself_manifest_close_error
    RV_ADDR s6, self_check_stat + 48
    mv s8, s6
    RV_LOAD t1, 8
    mv s4, t1
    mv s8, s4
    mv s10, s4
    RV_FLAGS and, 64
    RV_BCOND eq, .Lself_manifest_close_error
    RV_IMM t2, INDEX_LIMIT, 64
    mv s8, s4
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lself_manifest_close_error
    mv s10, s3
    xor s3, s3, s10
    RV_ZEXT s3
    mv s8, s3
    mv s10, s3
    RV_FLAGS and, 32
.Lself_manifest_read:
    mv a0, s2
    RV_ADDR s6, self_manifest_data
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
    RV_BCOND eq, .Lself_manifest_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_manifest_close_error
    RV_BCOND eq, .Lself_manifest_end
    mv s8, s3
    mv s10, t0
    RV_FLAGS add, 64
    mv s3, s11
    RV_IMM t2, INDEX_LIMIT, 64
    mv s8, s3
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lself_manifest_close_error
    tail .Lself_manifest_read
.Lself_manifest_end:
    mv s8, s3
    mv s10, s4
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lself_manifest_close_error
    mv a0, s2
    RV_CALL rv_close
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, self_metadata_error
    RV_ADDR s6, self_manifest_data
    mv t0, s6
    RV_IMM t1, 0, 32
    mv s6, t0
    mv s10, s3
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, self_manifest_length
    mv s8, s6
    RV_STORE s3, 8
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    ret
.Lself_manifest_close_error:
    mv a0, s2
    RV_CALL rv_close
    tail self_metadata_error
/* a0=fixed executable, a1=argv, a2=explicit environment. Fork and capture
 * stdout into self_capture_buffer[4098], rejecting >4096 bytes. Child stdin
 * is /dev/null, stderr is inherited, and alarm bounds each child to 120s.
 * Output t0=exit status (128+signal; 127 for child setup/exec/fork failure),
 * capture_length plus NUL. No shell. Stack 96 saved bytes plus 16 alignment
 * bytes for the absolute-path check; FDs close on every parent return path.
 */
self_capture:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_SAVE s4
    RV_SAVE s5
    mv s2, a0
    mv s3, a1
    mv s4, a2
    li s10, 16
    sub sp, sp, s10
    RV_CALL self_check_absolute_installation
    li s10, 16
    add sp, sp, s10
    RV_IMM t1, 0, 64
    RV_ADDR s6, self_capture_length
    mv s8, s6
    RV_STORE t1, 8
    RV_IMM t1, 0, 32
    RV_ADDR s6, self_capture_buffer
    mv s8, s6
    RV_STORE t1, 1
    RV_ADDR s6, self_capture_pipe
    mv a0, s6
    RV_IMM t1, O_CLOEXEC, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_pipe2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_fork_error
    RV_CALL rv_fork
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_pipe_error
    RV_BCOND eq, .Lself_capture_child
    mv s0, t0
    RV_ADDR s6, self_capture_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_close
    mv s10, s5
    xor s5, s5, s10
    RV_ZEXT s5
    mv s8, s5
    mv s10, s5
    RV_FLAGS and, 32
    mv s10, s1
    xor s1, s1, s10
    RV_ZEXT s1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
.Lself_capture_read:
    RV_ADDR s6, self_capture_pipe
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, self_capture_buffer
    mv a1, s6
    mv s8, a1
    mv s10, s5
    RV_FLAGS add, 64
    mv a1, s11
    RV_IMM t1, 4097, 32
    mv a2, t1
    RV_ZEXT a2
    mv s8, a2
    mv s10, s5
    RV_FLAGS sub, 64
    mv a2, s11
    RV_CALL rv_read
    RV_IMM t2, -4, 64
    mv s8, t0
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lself_capture_read
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_kill
    RV_BCOND eq, .Lself_capture_wait
    mv s8, s5
    mv s10, t0
    RV_FLAGS add, 64
    mv s5, s11
    RV_IMM t2, 4096, 64
    mv s8, s5
    mv s10, t2
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lself_capture_kill
    tail .Lself_capture_read
.Lself_capture_kill:
    RV_IMM t1, 1, 32
    mv s1, t1
    RV_ZEXT s1
    mv a0, s0
    RV_IMM t1, 9, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_kill
.Lself_capture_wait:
    RV_ADDR s6, self_capture_pipe
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_close
.Lself_capture_wait_retry:
    mv a0, s0
    RV_ADDR s6, self_capture_wait_status
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
    RV_BCOND eq, .Lself_capture_wait_retry
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_fork_error
    RV_ADDR s6, self_capture_length
    mv s8, s6
    RV_STORE s5, 8
    RV_ADDR s6, self_capture_buffer
    mv t0, s6
    RV_IMM t1, 0, 32
    mv s6, t0
    mv s10, s5
    add s6, s6, s10
    mv s8, s6
    RV_STORE t1, 1
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 32
    RV_BCOND ne, .Lself_capture_failed
    RV_ADDR s6, self_capture_wait_status
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
    RV_BCOND ne, .Lself_capture_signaled
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
    tail .Lself_capture_return
.Lself_capture_signaled:
    mv s6, a2
    li s10, 128
    add s6, s6, s10
    mv t0, s6
    RV_ZEXT t0
    tail .Lself_capture_return
.Lself_capture_failed:
    RV_IMM t1, 1, 32
    mv t0, t1
    RV_ZEXT t0
    tail .Lself_capture_return
.Lself_capture_pipe_error:
    RV_ADDR s6, self_capture_pipe
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_close
    RV_ADDR s6, self_capture_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_close
.Lself_capture_fork_error:
    RV_IMM t1, 127, 32
    mv t0, t1
    RV_ZEXT t0
.Lself_capture_return:
    RV_RESTORE s5
    RV_RESTORE s4
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
.Lself_capture_child:
    RV_ADDR s6, self_capture_pipe
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_close
    RV_ADDR s6, self_capture_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    RV_CALL rv_dup2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_child_error
    /* dup2(fd,fd) leaves CLOEXEC set, so clear stdout's flag explicitly. */
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_CALL rv_fcntl
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_child_error
    RV_ADDR s6, self_capture_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    RV_IMM t2, 1, 32
    mv s8, t1
    mv s10, t2
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lself_capture_child_stdin
    RV_ADDR s6, self_capture_pipe + 4
    mv s8, s6
    RV_LOAD t1, 4
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_close
.Lself_capture_child_stdin:
    RV_ADDR s6, self_dev_null
    mv a0, s6
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
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
    RV_BCOND mi, .Lself_capture_child_error
    mv s1, t0
    mv a0, t0
    mv s10, a1
    xor a1, a1, s10
    RV_ZEXT a1
    mv s8, a1
    mv s10, a1
    RV_FLAGS and, 32
    RV_CALL rv_dup2
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_child_error
    mv s8, s1
    mv s10, s1
    RV_FLAGS and, 64
    RV_BCOND eq, .Lself_capture_child_alarm
    mv a0, s1
    RV_CALL rv_close
.Lself_capture_child_alarm:
    /* Ignored dispositions and blocked masks survive execve. Reset SIGALRM
     * and explicitly unblock it before enforcing the child deadline. The
     * Linux RISC-V64 kernel signal set is eight bytes; bit 13 is SIGALRM. */
    RV_IMM t1, 14, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, self_default_signal
    mv a1, s6
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_IMM t1, 8, 32
    mv a6, t1
    RV_ZEXT a6
    RV_CALL rv_rt_sigaction
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_child_error
    RV_IMM t1, 1, 32
    mv a0, t1
    RV_ZEXT a0
    RV_ADDR s6, self_alarm_signal_mask
    mv a1, s6
    mv s10, a2
    xor a2, a2, s10
    RV_ZEXT a2
    mv s8, a2
    mv s10, a2
    RV_FLAGS and, 32
    RV_IMM t1, 8, 32
    mv a6, t1
    RV_ZEXT a6
    RV_CALL rv_rt_sigprocmask
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_child_error
    RV_IMM t1, SELF_VERIFIER_DEADLINE_SECONDS, 32
    mv a0, t1
    RV_ZEXT a0
    RV_CALL rv_alarm
    mv s8, t0
    mv s10, t0
    RV_FLAGS and, 64
    RV_BCOND mi, .Lself_capture_child_error
    mv a0, s2
    mv a1, s3
    mv a2, s4
    RV_CALL rv_execve
.Lself_capture_child_error:
    RV_IMM t1, 127, 32
    mv a0, t1
    RV_ZEXT a0
    tail exit_code
self_verifier_missing:
    RV_ADDR s6, self_error_verifier
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    tail self_fail
self_attestation_error:
    RV_ADDR s6, self_error_attestation
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    tail self_fail
self_metadata_error:
    RV_ADDR s6, self_error_metadata
    mv a0, s6
    RV_IMM t1, 1, 32
    mv a1, t1
    RV_ZEXT a1
    tail self_fail
self_proxy_error:
    RV_ADDR s6, self_error_proxy
    mv a0, s6
    RV_IMM t1, 2, 32
    mv a1, t1
    RV_ZEXT a1
    tail self_fail
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
