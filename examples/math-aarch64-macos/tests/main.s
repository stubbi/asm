.include "src/min.s"

.text
.p2align 2
.global _main
/* Assembly-only value and ABI checks.
 * Input: platform process entry or Apple main call frame.
 * Output: process status 0 on pass, 1 on a value or preservation failure.
 * Saves: incoming x19-x30 and lower 64 bits of v8-v15 in a 192-byte frame.
 * Checks: x19-x28 sentinels, valid x29 frame, SP, d8-d15, and stack canary.
 * Buffers: fixed read-only case/sentinel tables; private frame-address word.
 * Calls: asm_u64_min with 16-byte aligned SP. No external test backend.
 */
_main:
    stp x29, x30, [sp, #-192]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    adrp x9, frame_address@PAGE
    add x9, x9, frame_address@PAGEOFF
    str x29, [x9]
    adrp x9, sentinels@PAGE
    add x9, x9, sentinels@PAGEOFF
    ldp x19, x20, [x9]
    ldp x21, x22, [x9, #16]
    ldp x23, x24, [x9, #32]
    ldp x25, x26, [x9, #48]
    ldp x27, x28, [x9, #64]
    ldp d8, d9, [x9, #80]
    ldp d10, d11, [x9, #96]
    ldp d12, d13, [x9, #112]
    ldp d14, d15, [x9, #128]
    adrp x9, cases@PAGE
    add x9, x9, cases@PAGEOFF
    str x9, [sp, #160]
    mov x10, #16
    str x10, [sp, #168]
    mov x10, #0x5a5a
    str x10, [sp, #184]
Lcase:
    ldr x9, [sp, #160]
    ldp x0, x1, [x9]
    ldr x10, [x9, #16]
    str x10, [sp, #176]
    bl _asm_u64_min
    adrp x9, frame_address@PAGE
    add x9, x9, frame_address@PAGEOFF
    ldr x10, [x9]
    mov x11, sp
    cmp x11, x10
    b.ne Lfailure
    cmp x29, x10
    b.ne Lfailure
    ldr x10, [sp, #176]
    cmp x0, x10
    b.ne Lfailure
    ldr x10, [sp, #184]
    mov x11, #0x5a5a
    cmp x10, x11
    b.ne Lfailure
    adrp x9, sentinels@PAGE
    add x9, x9, sentinels@PAGEOFF
    ldr x10, [x9, #0]
    cmp x19, x10
    b.ne Lfailure
    ldr x10, [x9, #8]
    cmp x20, x10
    b.ne Lfailure
    ldr x10, [x9, #16]
    cmp x21, x10
    b.ne Lfailure
    ldr x10, [x9, #24]
    cmp x22, x10
    b.ne Lfailure
    ldr x10, [x9, #32]
    cmp x23, x10
    b.ne Lfailure
    ldr x10, [x9, #40]
    cmp x24, x10
    b.ne Lfailure
    ldr x10, [x9, #48]
    cmp x25, x10
    b.ne Lfailure
    ldr x10, [x9, #56]
    cmp x26, x10
    b.ne Lfailure
    ldr x10, [x9, #64]
    cmp x27, x10
    b.ne Lfailure
    ldr x10, [x9, #72]
    cmp x28, x10
    b.ne Lfailure
    ldr x10, [x9, #80]
    fmov x11, d8
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #88]
    fmov x11, d9
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #96]
    fmov x11, d10
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #104]
    fmov x11, d11
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #112]
    fmov x11, d12
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #120]
    fmov x11, d13
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #128]
    fmov x11, d14
    cmp x11, x10
    b.ne Lfailure
    ldr x10, [x9, #136]
    fmov x11, d15
    cmp x11, x10
    b.ne Lfailure
    ldr x9, [sp, #160]
    add x9, x9, #24
    str x9, [sp, #160]
    ldr x10, [sp, #168]
    subs x10, x10, #1
    str x10, [sp, #168]
    b.ne Lcase
    mov x0, #0
    b Lrestore
Lfailure:
    mov x0, #1
    adrp x9, frame_address@PAGE
    add x9, x9, frame_address@PAGEOFF
    ldr x10, [x9]
    mov sp, x10
Lrestore:
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    ldp x29, x30, [sp], #192
    ret

.section __TEXT,__const
.p2align 3
cases:
    .quad 0, 0, 0
    .quad 0, 0xffffffffffffffff, 0
    .quad 0xffffffffffffffff, 0, 0
    .quad 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff
    .quad 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff
    .quad 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff
    .quad 12, 37, 12
    .quad 37, 12, 12
    .quad 42, 42, 42
    .quad 1, 0xffffffffffffffff, 1
    .quad 0xffffffffffffffff, 1, 1
    .quad 1, 2, 1
    .quad 2, 1, 1
    .quad 0x8000000000000000, 1, 1
    .quad 0x100000000, 0x10000000000, 0x100000000
    .quad 0x10000000000, 0x100000000, 0x100000000
sentinels:
    .quad 0x1919191919191919
    .quad 0x2020202020202020
    .quad 0x2121212121212121
    .quad 0x2222222222222222
    .quad 0x2323232323232323
    .quad 0x2424242424242424
    .quad 0x2525252525252525
    .quad 0x2626262626262626
    .quad 0x2727272727272727
    .quad 0x2828282828282828
    .quad 0x0808080808080808
    .quad 0x0909090909090909
    .quad 0x1010101010101010
    .quad 0x1111111111111111
    .quad 0x1212121212121212
    .quad 0x1313131313131313
    .quad 0x1414141414141414
    .quad 0x1515151515151515

.data
.p2align 3
frame_address: .quad 0
