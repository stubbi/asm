.text
.p2align 2
.global _asm_u64_min

/* Return the smaller unsigned 64-bit input.
 * ABI: Apple arm64 (AAPCS64 with Apple platform rules).
 * Input: x0 = a, x1 = b. Every 64-bit value is permitted.
 * Output: x0 = min(a, b), using unsigned comparison. No failure value.
 * Changed: x0 and NZCV flags. All other registers are unchanged.
 * Stack: no allocation or access; SP is unchanged and must be 16-byte aligned.
 * Memory: no data access; no buffer or ownership requirements.
 * Calls: leaf function. x30 must contain the valid return address.
 * Symbols: C name asm_u64_min has the Mach-O name _asm_u64_min.
 * Apple reserves x18; this function does not access it.
 */
_asm_u64_min:
    cmp x0, x1
    csel x0, x0, x1, ls
    ret

.subsections_via_symbols
