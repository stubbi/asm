/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Internal AArch64 ABI: arguments x0-x7, result x9, ARM_CALL preserves LR.
 */
.section .text
/* Extract the verifier from this trusted executable, never from a candidate.
 * Inputs: held stage fd and prepared HOME/parent strings (bounded at 4096).
 * Outputs: helper/state paths, each capacity 8192. Failure terminates.
 * Preserves x19-x24; local stack 16 bytes plus ARM_CALL frames. */
self_prepare_embedded_verifier:
    ARM_SAVE x19
    ARM_ADDR x0, self_helper_path
    ARM_ADDR x1, self_home_environment + 5
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, self_helper_suffix
    ARM_CALL copy_string
    ARM_ADDR x0, self_trust_path
    ARM_ADDR x1, self_parent_path
    ARM_CALL copy_string
    mov x0, x9
    ARM_ADDR x1, self_trust_suffix
    ARM_CALL copy_string
    ARM_ADDR x16, self_stage_fd
    ldr x0, [x16]
    ARM_ADDR x1, self_helper_relative
    ARM_IMM w2, 1 + 64 + 128 + O_NOFOLLOW + O_CLOEXEC
    /* arm_openat's fourth argument uses x6 in the internal adapter ABI. */
    mov w6, #448
    ARM_CALL arm_openat
    tbnz x9, #63, self_io_error
    mov x19, x9
    mov x0, x9
    ARM_ADDR x1, self_helper_bytes
    ARM_ADDR x2, self_helper_end
    sub x2, x2, x1
    ARM_CALL write_all
    tbnz x9, #63, .Lself_helper_write_error
    mov x0, x19
    ARM_CALL arm_close
    tbnz x9, #63, self_io_error
    ARM_RESTORE x19
    ret
.Lself_helper_write_error:
    mov x0, x19
    ARM_CALL arm_close
    b self_io_error

/* No arguments. Each operation preserves x19-x24 and uses only ARM_CALL
 * frames. self_capture applies the independent deadline and installation
 * identity checks. All nonzero child statuses fail before installation. */
self_authenticated_index:
    ARM_ADDR x0, self_helper_path
    ARM_ADDR x1, self_trust_index_argv
    ARM_ADDR x2, self_gh_environment
    ARM_CALL self_capture
    cbnz w9, self_metadata_error
    ret
self_authorize_candidate:
    ARM_ADDR x0, self_helper_path
    ARM_ADDR x1, self_trust_artifact_argv
    ARM_ADDR x2, self_gh_environment
    ARM_CALL self_capture
    cbnz w9, self_metadata_error
    ret

/* Use the native parser's artifact slot and source commit. Before parsing the
 * authenticated manifest, '-' requests the fixed publisher policy alone.
 * Output x9 = child status; stdout must still equal the pinned repository ID. */
self_embedded_provenance:
    ARM_ADDR x16, self_verify_argv + 3*8
    ldr x10, [x16]
    ARM_ADDR x16, self_provenance_argv + 2*8
    str x10, [x16]
    ARM_ADDR x10, self_source_commit
    ldrb w11, [x10]
    cbnz w11, .Lself_provenance_commit
    ARM_ADDR x10, self_unknown_commit
.Lself_provenance_commit:
    ARM_ADDR x16, self_provenance_argv + 4*8
    str x10, [x16]
    ARM_ADDR x0, self_helper_path
    ARM_ADDR x1, self_provenance_argv
    ARM_ADDR x2, self_gh_environment
    ARM_CALL self_capture
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
.incbin "build/asm-verify-aarch64-linux"
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
