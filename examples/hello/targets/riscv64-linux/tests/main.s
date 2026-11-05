/* MIT; see ../../../LICENSE. Linux RV64I/LP64 startup smoke test.
 * No inputs used, memory accesses, local stack, or optional CPU features.
 * Changes a0/a7; exits with status zero through Linux syscall 93.
 */
.option norelax
.global _start
.text
_start:
    li a0, 0
    li a7, 93
    ecall
.section .note.GNU-stack,"",@progbits
