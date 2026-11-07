/* Verifier output is bounded independently of the child. Native Windows
 * deadline and pipe pumping replace fork, dup2, signals, alarm, and wait4.
 */
self_capture:
    ARM_SAVE x19
    ARM_SAVE x20
    mov x3, #0
    ARM_ADDR x4, self_capture_buffer
    mov x5, #4096
    ARM_CALL win_capture
    mov x19, x9
    ARM_ADDR x16, win_capture_size
    ldr x10, [x16]
    ARM_ADDR x16, self_capture_length
    str x10, [x16]
    ARM_ADDR x16, self_capture_buffer
    strb wzr, [x16, x10]
    mov x9, x19
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
