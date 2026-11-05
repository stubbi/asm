/* MIT; see ../../../LICENSE. Linux AArch64 startup smoke test, AAPCS64.
 * No inputs used, memory accesses, local stack, or optional CPU features.
 * Changes x0/x8; exits with status zero through Linux syscall 93.
 */
.global _start
.text
_start:
    mov x0, #0
    mov x8, #93
    svc #0
.section .note.GNU-stack,"",@progbits
