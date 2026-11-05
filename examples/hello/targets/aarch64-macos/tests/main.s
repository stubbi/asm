/* MIT; see ../../../LICENSE. Apple arm64 startup smoke test, macOS 15+.
 * No inputs used or local stack; startup provides 16-byte stack alignment.
 * Calls libSystem exit with zero and does not return.
 */
.global _main
.text
_main:
    mov x0, #0
    bl _exit
