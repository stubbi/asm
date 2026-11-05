// SPDX-License-Identifier: GPL-2.0-or-later
// Native ABI test shim. Returns 0 only when render/menu preserve all Apple
// arm64 nonvolatile GPRs, the frame pointer, SP and low64 of v8-v15.
.text
.p2align 2
.globl _doom_render_abi
_doom_render_abi:
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
    str x0, [sp, #160]
    mov x19, #19
    mov x20, #20
    mov x21, #21
    mov x22, #22
    mov x23, #23
    mov x24, #24
    mov x25, #25
    mov x26, #26
    mov x27, #27
    mov x28, #28
    fmov d8, x19
    fmov d9, x20
    fmov d10, x21
    fmov d11, x22
    fmov d12, x23
    fmov d13, x24
    fmov d14, x25
    fmov d15, x26
    bl _doom_render
    ldr x0, [sp, #160]
    mov w1, #2
    bl _doom_render_menu
    mov w0, #1
    mov x1, sp
    cmp x29, x1
    b.ne Labi_return
    cmp x19, #19
    b.ne Labi_return
    cmp x20, #20
    b.ne Labi_return
    cmp x21, #21
    b.ne Labi_return
    cmp x22, #22
    b.ne Labi_return
    cmp x23, #23
    b.ne Labi_return
    cmp x24, #24
    b.ne Labi_return
    cmp x25, #25
    b.ne Labi_return
    cmp x26, #26
    b.ne Labi_return
    cmp x27, #27
    b.ne Labi_return
    cmp x28, #28
    b.ne Labi_return
    fmov x1, d8
    cmp x1, #19
    b.ne Labi_return
    fmov x1, d9
    cmp x1, #20
    b.ne Labi_return
    fmov x1, d10
    cmp x1, #21
    b.ne Labi_return
    fmov x1, d11
    cmp x1, #22
    b.ne Labi_return
    fmov x1, d12
    cmp x1, #23
    b.ne Labi_return
    fmov x1, d13
    cmp x1, #24
    b.ne Labi_return
    fmov x1, d14
    cmp x1, #25
    b.ne Labi_return
    fmov x1, d15
    cmp x1, #26
    b.ne Labi_return
    mov w0, #0
Labi_return:
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #192
    ret
