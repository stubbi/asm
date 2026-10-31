.intel_syntax noprefix
.section .text
.global asm_u64_min
.type asm_u64_min, @function

/* Return the smaller unsigned 64-bit input.
 * ABI: Linux x86-64, System V.
 * Input: rdi = a, rsi = b. Every 64-bit value is permitted.
 * Output: rax = min(a, b), with unsigned comparison.
 * Clobbers: rax and flags. Other registers are unchanged.
 * Memory: no data access. RET reads the caller's valid return address.
 * Stack: no local storage. The caller must supply a valid call frame.
 */
asm_u64_min:
    mov rax, rdi
    cmp rdi, rsi
    cmova rax, rsi
    ret
.size asm_u64_min, .-asm_u64_min

.section .note.GNU-stack,"",@progbits
