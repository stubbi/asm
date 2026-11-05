// SPDX-License-Identifier: MIT
.text
.global asm_u64_min
// Input: x0, x1 = any unsigned 64-bit values. Output: x0 = their minimum.
// Changes x0 and arithmetic flags only. Preserves all other registers and SP.
// No stack allocation or data-memory access. Caller supplies a valid ARM64 frame.
asm_u64_min:
    cmp x0, x1
    csel x0, x0, x1, ls
    ret
