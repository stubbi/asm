/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Native RISC-V assembler argument selection.
 */

.section .text
/* Build assembler argv from already validated local project state. Leaf;
 * result t0=0; caller scratch only. Owns child_argv[128]. No process or file
 * operation occurs here. Standalone RV64I/LP64 and linked RV64GC/LP64D are
 * separate explicit tool arguments; native C objects also receive PIC.
 */
rv_prepare_assembly:
    RV_ADDR t1, child_argv
    RV_ADDR t2, as_path
    sd t2, 0(t1)
    addi t1, t1, 8
    RV_ADDR t3, package_link
    lbu t3, 0(t3)
    beqz t3, .Lrv_as_standalone
    RV_ADDR t2, rv_cc_arch
    sd t2, 0(t1)
    RV_ADDR t2, rv_cc_abi
    sd t2, 8(t1)
    RV_ADDR t2, rv_asm_no_relax
    sd t2, 16(t1)
    RV_ADDR t2, rv_asm_pic
    sd t2, 24(t1)
    addi t1, t1, 32
    j .Lrv_as_paths
.Lrv_as_standalone:
    RV_ADDR t2, as_arch
    sd t2, 0(t1)
    RV_ADDR t2, rv_asm_abi
    sd t2, 8(t1)
    RV_ADDR t2, rv_asm_no_relax
    sd t2, 16(t1)
    addi t1, t1, 24
.Lrv_as_paths:
    RV_ADDR t2, arg_I
    sd t2, 0(t1)
    RV_ADDR t2, dependency_packages_root
    sd t2, 8(t1)
    RV_ADDR t2, arg_o
    sd t2, 16(t1)
    RV_ADDR t2, stage_object
    sd t2, 24(t1)
    RV_ADDR t2, test_mode
    lbu t2, 0(t2)
    beqz t2, .Lrv_as_project_source
    RV_ADDR t2, package_test
    j .Lrv_as_source_ready
.Lrv_as_project_source:
    RV_ADDR t2, package_source
.Lrv_as_source_ready:
    sd t2, 32(t1)
    sd zero, 40(t1)
    li t0, 0
    ret
.section .rodata
rv_cc_arch: .asciz "-march=rv64gc"
rv_cc_abi: .asciz "-mabi=lp64d"
rv_asm_abi: .asciz "-mabi=lp64"
rv_asm_no_relax: .asciz "-mno-relax"
rv_asm_pic: .asciz "-fpic"
.section .note.GNU-stack,""
