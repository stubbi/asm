/* SPDX-License-Identifier: MIT
 * Return the smaller unsigned 64-bit input.
 * ABI: Linux RISC-V64, little-endian RV64I, LP64 integer calling convention.
 * Input: a0 = a, a1 = b. Every 64-bit value is permitted.
 * Output: a0 = min(a, b), with unsigned comparison. No failure value.
 * Changed registers: a0 only. All other registers remain unchanged.
 * Memory: no data access, buffers, or ownership transfer.
 * Stack: unchanged; no local storage. The caller aligns sp to 16 bytes.
 * Call: ra contains the return address. No runtime or system call is used.
 */
.section .text
.balign 4
.global asm_u64_min
.type asm_u64_min, @function
asm_u64_min:
    bgeu a1, a0, .Lmin_return
    mv a0, a1
.Lmin_return:
    ret
.size asm_u64_min, .-asm_u64_min

.section .note.GNU-stack,"",@progbits
