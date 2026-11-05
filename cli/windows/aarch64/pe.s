/* SPDX-License-Identifier: AGPL-3.0-or-later
 * PE32+ ARM64 executable validation. No mapping or execution occurs.
 * Input x0=path, x1=exact expected size (64..67108864).
 * Output w9=0 valid, 1 invalid. Preserves x19-x24; stack=112 plus adapters.
 * Checks DOS/PE signatures, Machine/optional header, section table arithmetic,
 * raw/virtual section ranges, no writable executable section, and an entry
 * inside a file-backed executable section. Requires ASLR and non-exec data.
 * This format check does not authenticate the publisher or establish safety.
 */
.text
validate_host_elf:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x1
    cmp x19, #64
    b.lo .Lpe_unopened
    ARM_IMM x10, 67108864
    cmp x19, x10
    b.hi .Lpe_unopened
    ARM_IMM x1, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov x2, #0
    ARM_CALL arm_open
    tbnz x9, #63, .Lpe_unopened
    mov x20, x9
    mov x0, x20
    ARM_ADDR x1, elf_stat
    ARM_CALL arm_fstat
    cbnz x9, .Lpe_bad
    ARM_ADDR x16, elf_stat
    ldr x10, [x16, #ARM_STAT_SIZE]
    cmp x10, x19
    b.ne .Lpe_bad
    ldr w10, [x16, #ARM_STAT_MODE]
    and w10, w10, #61440
    cmp w10, #32768
    b.ne .Lpe_bad
    mov x0, x20
    ARM_ADDR x1, win_pe_header
    mov x2, #64
    ARM_CALL elf_read_exact
    cbnz x9, .Lpe_bad
    ARM_ADDR x21, win_pe_header
    ldrh w10, [x21]
    ARM_IMM w11, 0x5a4d
    cmp w10, w11
    b.ne .Lpe_bad
    ldr w22, [x21, #60]
    cmp x22, #64
    b.lo .Lpe_bad
    add x10, x22, #264
    cmp x10, x19
    b.hi .Lpe_bad
    mov x0, x20
    mov x1, x22
    mov x2, #0
    ARM_CALL arm_lseek
    cmp x9, x22
    b.ne .Lpe_bad
    mov x0, x20
    mov x1, x21
    mov x2, #264
    ARM_CALL elf_read_exact
    cbnz x9, .Lpe_bad
    ldr w10, [x21]
    ARM_IMM w11, 0x4550
    cmp w10, w11
    b.ne .Lpe_bad
    ldrh w10, [x21, #4]
    ARM_IMM w11, 0xaa64
    cmp w10, w11
    b.ne .Lpe_bad
    ldrh w23, [x21, #6]
    cbz w23, .Lpe_bad
    cmp w23, #96
    b.hi .Lpe_bad
    ldrh w10, [x21, #20]
    cmp w10, #240
    b.ne .Lpe_bad
    ldrh w10, [x21, #22]
    tst w10, #2
    b.eq .Lpe_bad
    tst w10, #1
    b.ne .Lpe_bad
    tst w10, #0x2000             /* Reject DLLs. */
    b.ne .Lpe_bad
    ldrh w10, [x21, #24]
    cmp w10, #0x20b
    b.ne .Lpe_bad
    ldrh w10, [x21, #92]
    cmp w10, #3                  /* console subsystem */
    b.ne .Lpe_bad
    ldrh w10, [x21, #94]
    mov w11, #0x140
    and w10, w10, w11
    cmp w10, #0x140              /* dynamic base + NX compatible */
    b.ne .Lpe_bad
    ldr w10, [x21, #132]
    cmp w10, #16                 /* fixed PE32+ data directory count */
    b.ne .Lpe_bad
    ldr x10, [x21, #48]          /* ImageBase must be 64KiB aligned. */
    cbz x10, .Lpe_bad
    tst x10, #65535
    b.ne .Lpe_bad
    ldr w10, [x21, #56]          /* SectionAlignment */
    cmp w10, #4096
    b.lo .Lpe_bad
    sub w11, w10, #1
    tst w10, w11
    b.ne .Lpe_bad
    str w10, [sp, #104]
    ldr w12, [x21, #60]          /* FileAlignment */
    cmp w12, #512
    b.lo .Lpe_bad
    ARM_IMM w13, 65536
    cmp w12, w13
    b.hi .Lpe_bad
    cmp w12, w10
    b.hi .Lpe_bad
    sub w13, w12, #1
    tst w12, w13
    b.ne .Lpe_bad
    str w12, [sp, #108]
    ldr w24, [x21, #40]          /* AddressOfEntryPoint */
    cbz w24, .Lpe_bad
    ldr w10, [x21, #80]          /* SizeOfImage */
    cmp w24, w10
    b.hs .Lpe_bad
    str w10, [sp, #64]
    ldr w11, [x21, #84]          /* SizeOfHeaders */
    cmp x11, x19
    b.hi .Lpe_bad
    add x22, x22, #264
    mov x10, #40
    madd x10, x23, x10, x22
    cmp x10, x19
    b.hi .Lpe_bad
    cmp x10, x11
    b.hi .Lpe_bad
    str x11, [sp, #72]          /* raw data cannot overlap SizeOfHeaders */
    ldr w12, [sp, #108]
    sub w12, w12, #1
    tst w11, w12
    b.ne .Lpe_bad
    ldr w10, [sp, #64]
    ldr w12, [sp, #104]
    sub w12, w12, #1
    tst w10, w12
    b.ne .Lpe_bad
    /* Every declared data directory has nonwrapping image/file bounds. */
    mov x10, #0
.Lpe_directory:
    add x11, x21, #136
    add x11, x11, x10, lsl #3
    ldr w12, [x11]
    ldr w13, [x11, #4]
    cbz w13, .Lpe_directory_next
    cbz w12, .Lpe_bad
    add x12, x12, x13
    ldr w13, [sp, #64]
    cmp x10, #4                  /* Certificate table uses file offsets. */
    csel x13, x19, x13, eq
    cmp x12, x13
    b.hi .Lpe_bad
.Lpe_directory_next:
    add x10, x10, #1
    cmp x10, #16
    b.lo .Lpe_directory
    str xzr, [sp, #80]          /* entry found */
    ldr x10, [sp, #72]
    str x10, [sp, #88]          /* first section cannot overlap headers */
    str xzr, [sp, #96]          /* previous raw end */
.Lpe_section:
    mov x0, x20
    mov x1, x22
    mov x2, #0
    ARM_CALL arm_lseek
    cmp x9, x22
    b.ne .Lpe_bad
    mov x0, x20
    mov x1, x21
    mov x2, #40
    ARM_CALL elf_read_exact
    cbnz x9, .Lpe_bad
    ldr w10, [x21, #36]
    ARM_IMM w11, 0xa0000000
    and w11, w10, w11
    ARM_IMM w12, 0xa0000000
    cmp w11, w12
    b.eq .Lpe_bad
    ldr w11, [x21, #12]          /* RVA */
    ldr w12, [sp, #104]
    sub w12, w12, #1
    tst w11, w12
    b.ne .Lpe_bad
    ldr w12, [x21, #8]           /* VirtualSize */
    ldr w13, [x21, #16]          /* SizeOfRawData */
    cmp w12, w13
    csel w12, w13, w12, lo
    add x12, x12, x11
    ldr w14, [sp, #64]
    cmp x12, x14
    b.hi .Lpe_bad
    ldr x14, [sp, #88]
    cmp x11, x14
    b.lo .Lpe_bad
    str x12, [sp, #88]
    cbz w13, .Lpe_next
    ldr w14, [x21, #20]          /* raw offset */
    ldr w15, [sp, #108]
    sub w15, w15, #1
    tst w14, w15
    b.ne .Lpe_bad
    tst w13, w15
    b.ne .Lpe_bad
    ldr x15, [sp, #72]
    cmp x14, x15
    b.lo .Lpe_bad
    add x15, x14, x13
    cmp x15, x19
    b.hi .Lpe_bad
    ldr x17, [sp, #96]
    cmp x14, x17
    b.lo .Lpe_bad
    str x15, [sp, #96]
    tst w10, #0x20000000
    b.eq .Lpe_next
    cmp x24, x11
    b.lo .Lpe_next
    add x11, x11, x13
    cmp x24, x11
    b.hs .Lpe_next
    mov x10, #1
    str x10, [sp, #80]
.Lpe_next:
    add x22, x22, #40
    subs x23, x23, #1
    b.ne .Lpe_section
    ldr x10, [sp, #80]
    cbz x10, .Lpe_bad
    mov x21, #0
    b .Lpe_close
.Lpe_bad:
    mov x21, #1
.Lpe_close:
    mov x0, x20
    ARM_CALL arm_close
    mov x9, x21
    b .Lpe_return
.Lpe_unopened:
    mov x9, #1
.Lpe_return:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #112
    ret
/* x0=handle, x1=owned buffer, x2=count; x9=0 or -5. No over-read. */
elf_read_exact:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x0
    mov x20, x1
    mov x21, x2
1:  cbz x21, 3f
    mov x0, x19
    mov x1, x20
    mov x2, x21
    ARM_CALL arm_read
    cmp x9, #0
    b.le 2f
    add x20, x20, x9
    sub x21, x21, x9
    b 1b
2:  mov x9, #-5
    b 4f
3:  mov x9, #0
4:  ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret
win_pub_validate_pe:
    ARM_SAVE x0
    ARM_SAVE x1
    ARM_ADDR x1, registry_host
    ARM_CALL streq
    ARM_RESTORE x1
    ARM_RESTORE x0
    cbz w9, pub_validate_elf
    ARM_ADDR x0, registry_temp_payload
    b validate_host_elf
.section .bss
.p2align 3
elf_stat: .skip 128
elf_header: .skip 64
elf_program_headers: .skip 7168
win_pe_header: .skip 264
