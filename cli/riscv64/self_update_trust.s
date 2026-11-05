/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/self_update_trust.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Internal RISC-V64 ABI: arguments a0-a7, result t0, RV_CALL preserves LR.
 */
.section .text
/* Extract the verifier from this trusted executable, never from a candidate.
 * Inputs: held stage fd and prepared HOME/parent strings (bounded at 4096).
 * Outputs: helper/state paths, each capacity 8192. Failure terminates.
 * Preserves s0-s5; local stack 16 bytes plus RV_CALL frames. */
self_prepare_embedded_verifier:
    RV_SAVE s0
    RV_ADDR a0, self_helper_path
    RV_ADDR a1, self_home_environment + 5
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, self_helper_suffix
    RV_CALL copy_string
    RV_ADDR a0, self_trust_path
    RV_ADDR a1, self_parent_path
    RV_CALL copy_string
    mv a0, t0
    RV_ADDR a1, self_trust_suffix
    RV_CALL copy_string
    RV_ADDR s6, self_stage_fd
    mv s8, s6
    RV_LOAD a0, 8
    RV_ADDR a1, self_helper_relative
    RV_IMM a2, 1 + 64 + 128 + O_NOFOLLOW + O_CLOEXEC, 32
    /* arm_openat's fourth argument uses a6 in the internal adapter ABI. */
    li a6, 448
    RV_ZEXT a6
    RV_CALL rv_openat
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_self_update_trust31
    RV_JUMP self_io_error
.Lrv_tb_skip_self_update_trust31:
    mv s0, t0
    mv a0, t0
    RV_ADDR a1, self_helper_bytes
    RV_ADDR a2, self_helper_end
    mv s10, a1
    sub a2, a2, s10
    RV_CALL write_all
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_self_update_trust38
    RV_JUMP .Lself_helper_write_error
.Lrv_tb_skip_self_update_trust38:
    mv a0, s0
    RV_CALL rv_close
    srli s8, t0, 63
    andi s8, s8, 1
    beqz s8, .Lrv_tb_skip_self_update_trust41
    RV_JUMP self_io_error
.Lrv_tb_skip_self_update_trust41:
    RV_RESTORE s0
    ret
.Lself_helper_write_error:
    mv a0, s0
    RV_CALL rv_close
    RV_JUMP self_io_error
/* No arguments. Each operation preserves s0-s5 and uses only RV_CALL
 * frames. self_capture applies the independent deadline and installation
 * identity checks. All nonzero child statuses fail before installation. */
self_authenticated_index:
    RV_ADDR a0, self_helper_path
    RV_ADDR a1, self_trust_index_argv
    RV_ADDR a2, self_gh_environment
    RV_CALL self_capture
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_self_update_trust57
    RV_JUMP self_metadata_error
.Lrv_cb_skip_self_update_trust57:
    ret
self_authorize_candidate:
    RV_ADDR a0, self_helper_path
    RV_ADDR a1, self_trust_artifact_argv
    RV_ADDR a2, self_gh_environment
    RV_CALL self_capture
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_self_update_trust64
    RV_JUMP self_metadata_error
.Lrv_cb_skip_self_update_trust64:
    ret
/* Use the native parser's artifact slot and source commit. Before parsing the
 * authenticated manifest, '-' requests the fixed publisher policy alone.
 * Output t0 = child status; stdout must still equal the pinned repository ID. */
self_embedded_provenance:
    RV_ADDR s6, self_verify_argv + 3*8
    mv s8, s6
    RV_LOAD t1, 8
    RV_ADDR s6, self_provenance_argv + 2*8
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR t1, self_source_commit
    mv s8, t1
    RV_LOAD t2, 1
    mv s8, t2
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_self_update_trust77
    RV_JUMP .Lself_provenance_commit
.Lrv_cb_skip_self_update_trust77:
    RV_ADDR t1, self_unknown_commit
.Lself_provenance_commit:
    RV_ADDR s6, self_provenance_argv + 4*8
    mv s8, s6
    RV_STORE t1, 8
    RV_ADDR a0, self_helper_path
    RV_ADDR a1, self_provenance_argv
    RV_ADDR a2, self_gh_environment
    RV_CALL self_capture
    ret
.section .rodata
self_helper_suffix: .asciz "/asm-verify"
self_helper_relative: .asciz "verifier/asm-verify"
self_trust_suffix: .asciz "/.asm-trust"
self_trust_metadata: .asciz "metadata"
self_trust_authorize: .asciz "authorize"
self_trust_index: .asciz "index.tsv"
self_provenance_command: .asciz "provenance"
self_unknown_commit: .asciz "-"
.balign 16
self_helper_bytes:
.incbin "build/asm-verify-riscv64-linux"
self_helper_end:
.section .data
.balign 8
self_trust_index_argv:
.quad self_helper_path, self_trust_metadata, self_trust_path, self_trust_index, registry_temp_index, 0
self_trust_artifact_argv:
.quad self_helper_path, self_trust_authorize, self_trust_path, self_asset_filename, registry_temp_payload, 0
self_provenance_argv:
.quad self_helper_path, self_provenance_command, 0, self_bundle_path, 0, 0
.section .bss
self_helper_path: .skip 8192
self_trust_path: .skip 8192
