.arch armv8-a
.section .text
.p2align 2
.global asm_u64_min
.type asm_u64_min, %function

/* Return the smaller unsigned 64-bit input.
 * ABI: Linux AArch64, AAPCS64, LP64.
 * Input: x0 = a, x1 = b. Every 64-bit value is permitted.
 * Output: x0 = min(a, b), using unsigned comparison. No failure value.
 * Changed: x0 and NZCV flags. All other registers are unchanged.
 * Stack: no allocation or access; SP is unchanged and must be 16-byte aligned.
 * Memory: no data access; no buffer or ownership requirements.
 * Calls: leaf function. x30 must contain the valid return address.
 */
asm_u64_min:
    cmp x0, x1
    csel x0, x0, x1, ls
    ret
.size asm_u64_min, .-asm_u64_min

.section .note.GNU-stack,"",%progbits
