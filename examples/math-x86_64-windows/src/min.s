# SPDX-License-Identifier: MIT
.intel_syntax noprefix
.text
.global asm_u64_min
# Input: rcx, rdx = any unsigned 64-bit values. Output: rax = their minimum.
# Changes rax and arithmetic flags only. Preserves all other registers and SP.
# No stack allocation or data-buffer access. RET reads the caller return address.
# The caller supplies a valid Win64 call frame.
asm_u64_min:
    mov rax, rcx
    cmp rcx, rdx
    cmova rax, rdx
    ret
