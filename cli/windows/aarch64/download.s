/* Curl sends bytes through a bounded parent-drained anonymous pipe. The
 * output file is created exclusively only after the child succeeds. This
 * enforces the size limit without trusting curl's Content-Length handling.
 * x0=URL, x1=private output path, x2=maximum decimal bytes. x9=child status.
 */
registry_download:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_ADDR x16, registry_curl_argv + 21*8
    str x0, [x16]
    ARM_ADDR x16, registry_curl_argv + 19*8
    ARM_ADDR x10, win_dash
    str x10, [x16]
    ARM_ADDR x16, registry_curl_argv + 17*8
    str x2, [x16]
    mov x19, x1
    mov x0, x2
    ARM_CALL registry_size_value
    cbz x9, 1f
    mov x5, x9
    ARM_ADDR x0, registry_curl
    ARM_ADDR x1, registry_curl_argv
    ARM_ADDR x2, arc_empty_env
    mov x3, #0
    ARM_ADDR x4, arc_data
    ARM_CALL win_capture
    cbnz x9, 2f
    mov x0, x19
    ARM_IMM x1, O_NOFOLLOW + O_CLOEXEC + 193
    mov x2, #384
    ARM_CALL arm_open
    tbnz x9, #63, 1f
    mov x20, x9
    mov x0, x20
    ARM_ADDR x1, arc_data
    ARM_ADDR x16, win_capture_size
    ldr x2, [x16]
    ARM_CALL write_all
    mov x21, x9
    mov x0, x20
    ARM_CALL arm_close
    cbnz x21, 1f
    cbnz x9, 1f
    mov x9, #0
    b 2f
1:  mov x9, #127
2:  ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
