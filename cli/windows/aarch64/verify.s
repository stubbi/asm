registry_verify_payload:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_ADDR x0, registry_temp_payload
    ARM_ADDR x1, registry_stat
    ARM_CALL arm_lstat
    cbnz x9, registry_io_error
    ARM_ADDR x16, registry_stat
    ldr x10, [x16, #ARM_STAT_SIZE]
    ARM_ADDR x16, registry_expected_size
    ldr x11, [x16]
    cmp x10, x11
    b.ne registry_integrity_error
    ARM_ADDR x0, registry_temp_payload
    ARM_ADDR x1, registry_checksum_contents
    ARM_CALL win_hash_file
    cbnz x9, registry_integrity_error
    ARM_ADDR x16, registry_selected
    ldr x16, [x16]
    ldr x19, [x16, #32]
    ARM_ADDR x20, registry_checksum_contents
    mov x2, #64
1:  ldrb w10, [x19], #1
    ldrb w11, [x20], #1
    cmp w10, w11
    b.ne registry_integrity_error
    subs x2, x2, #1
    b.ne 1b
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
