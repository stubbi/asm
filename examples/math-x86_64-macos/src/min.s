.intel_syntax noprefix
.text
.p2align 4
.global _asm_u64_min

/* Return the smaller unsigned 64-bit input.
 * ABI: Apple x86-64, ordinary C calls under the System V AMD64 rules.
 * Input: rdi = a, rsi = b. Every 64-bit value is permitted.
 * Output: rax = min(a, b), using unsigned comparison. No failure value.
 * Changed: rax and arithmetic flags. All other registers are unchanged.
 * Memory: no data buffer access. RET reads the caller's return address.
 * Stack: no local storage. The caller aligns RSP to 16 bytes before CALL.
 * Entry RSP is therefore 8 modulo 16, with a valid return address at [RSP].
 * Symbols: C name asm_u64_min has the Mach-O name _asm_u64_min.
 */
_asm_u64_min:
    mov rax, rdi
    cmp rdi, rsi
    cmova rax, rsi
    ret

.subsections_via_symbols
