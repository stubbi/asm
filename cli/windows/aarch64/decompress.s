/* The fixed Git gzip executable only reads a no-reparse opened source on
 * stdin. Parent drains stdout through a bounded anonymous pipe and terminates
 * an overflowing or timed-out child. Its environment is empty.
 */
arc_decompress:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_ADDR x16, arc_raw_size
    str xzr, [x16]
    ARM_ADDR x16, arc_input_path
    ldr x0, [x16]
    ARM_IMM x1, ARC_RDONLY
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, 2f
    mov x19, x9
    mov x0, x19
    ARM_ADDR x1, arc_stat
    ARM_CALL arm_fstat
    cbnz x9, 1f
    ARM_ADDR x16, arc_stat
    ldr w10, [x16, #ARM_STAT_MODE]
    and w10, w10, #61440
    cmp w10, #32768
    b.ne 1f
    ldr x10, [x16, #ARM_STAT_SIZE]
    cbz x10, 1f
    ARM_IMM x11, ARC_LIMIT
    cmp x10, x11
    b.hi 1f
    ARM_ADDR x0, arc_gzip
    ARM_ADDR x1, arc_gzip_argv
    ARM_ADDR x2, arc_empty_env
    mov x3, x19
    ARM_ADDR x4, arc_data
    ARM_IMM x5, ARC_LIMIT
    ARM_CALL win_capture
    mov x20, x9
    ARM_ADDR x16, win_capture_size
    ldr x10, [x16]
    ARM_ADDR x16, arc_raw_size
    str x10, [x16]
    b 3f
1:  mov x20, #1
3:  mov x0, x19
    ARM_CALL arm_close
    mov x9, x20
    b 4f
2:  mov x9, #1
4:  ARM_RESTORE x20
    ARM_RESTORE x19
    ret
