/* MIT; see ../../../LICENSE. Apple AMD64 startup smoke test, macOS 15+.
 * Input: main's call frame; arguments are unused. Output: status zero.
 * Scratch: RAX/flags. No calls, buffers, or local stack; RET consumes the frame.
 */
.intel_syntax noprefix
.global _main
.text
_main:
    xor eax, eax
    ret
