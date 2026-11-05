// SPDX-License-Identifier: GPL-2.0-or-later
// Handwritten patch posts and wall texture composition. Format references:
// id Software linuxdoom-1.10/r_data.c. Input bytes are always untrusted.
.text
.p2align 2

// x0 name, x0 borrowed cached descriptor or NULL. Stack64, C ABI.
.globl _doom_patch
_doom_patch:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov x19,x0
    bl _doom_name_key
    mov x20,x0
    mov w1,#0
    bl Lcache_find
    cbnz x0,Lpatch_done
    mov x0,x19
    bl _doom_lump
    cbz x0,Lpatch_done
    bl _doom_decode_patch
    cbz x0,Lpatch_done
    mov x19,x0
    mov x1,x20
    mov w2,#0
    bl Lcache_add
    cbnz w0,Lpatch_cached
    mov x0,x19
    bl _free
    mov x0,#0
    b Lpatch_done
Lpatch_cached:
    mov x0,x19
Lpatch_done:
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret

// x0 bytes,x1 size; returns owned32-byte descriptor + pixels + alpha, orNULL.
// Max1024x1024, stack96. No pointer is used before checking remaining size.
.globl _doom_decode_patch
_doom_decode_patch:
    stp x29,x30,[sp,#-96]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    stp x25,x26,[sp,#64]
    stp x27,x28,[sp,#80]
    mov x19,x0
    mov x20,x1
    cmp x20,#8
    b.lo Ldp_bad
    ldrh w21,[x19]
    ldrh w22,[x19,#2]
    cbz w21,Ldp_bad
    cbz w22,Ldp_bad
    cmp w21,#1024
    b.hi Ldp_bad
    cmp w22,#1024
    b.hi Ldp_bad
    lsl x8,x21,#2
    add x8,x8,#8
    cmp x8,x20
    b.hi Ldp_bad
    mul w23,w21,w22
    lsl x0,x23,#1
    add x0,x0,#32
    bl _malloc
    cbz x0,Ldp_bad
    mov x24,x0
    str w21,[x24]
    str w22,[x24,#4]
    add x0,x24,#32
    str x0,[x24,#8]
    add x8,x0,x23
    str x8,[x24,#24]
    ldrsh w8,[x19,#4]
    str w8,[x24,#16]
    ldrsh w8,[x19,#6]
    str w8,[x24,#20]
    mov w1,#255
    mov x2,x23
    bl _memset
    ldr x0,[x24,#24]
    mov w1,#0
    mov x2,x23
    bl _memset
    mov w25,#0
Ldp_column:
    cmp w25,w21
    b.hs Ldp_success
    add x8,x19,#8
    ldr w26,[x8,x25,lsl#2]
    mov w27,#-1
    mov w28,#0
Ldp_post:
    cmp x26,x20
    b.hs Ldp_free_bad
    // At most height+256 posts per column, including tall-patch offsets.
    add w28,w28,#1
    add w8,w22,#256
    cmp w28,w8
    b.hi Ldp_free_bad
    ldrb w8,[x19,x26]
    cmp w8,#255
    b.eq Ldp_next_column
    add x9,x26,#4
    cmp x9,x20
    b.hi Ldp_free_bad
    add x9,x19,x26
    ldrb w10,[x9,#1]
    add x11,x26,#4
    add x11,x11,x10
    cmp x11,x20
    b.hi Ldp_free_bad
    // Tall patches encode relative post origins after the first post.
    cmp w8,w27
    b.gt Ldp_absolute
    add w8,w8,w27
Ldp_absolute:
    mov w27,w8
    add w12,w8,w10
    cmp w12,w22
    b.hi Ldp_free_bad
    add x9,x9,#3
    ldr x12,[x24,#8]
    madd x12,x8,x21,x12
    add x12,x12,x25
    ldr x15,[x24,#24]
    madd x15,x8,x21,x15
    add x15,x15,x25
    mov w13,#0
Ldp_copy:
    cmp w13,w10
    b.hs Ldp_post_next
    ldrb w14,[x9,x13]
    strb w14,[x12]
    mov w14,#1
    strb w14,[x15]
    add x12,x12,x21
    add x15,x15,x21
    add w13,w13,#1
    b Ldp_copy
Ldp_post_next:
    mov x26,x11
    b Ldp_post
Ldp_next_column:
    add w25,w25,#1
    b Ldp_column
Ldp_success:
    mov x0,x24
    b Ldp_done
Ldp_free_bad:
    mov x0,x24
    bl _free
Ldp_bad:
    mov x0,#0
Ldp_done:
    ldp x27,x28,[sp,#80]
    ldp x25,x26,[sp,#64]
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#96
    ret

// x0 normalized key,w1 kind. Leaf changes x8-x11; cache owns return.
Lcache_find:
    adrp x8,Lcache@PAGE
    ldr x8,[x8,Lcache@PAGEOFF]
Lcf_loop:
    cbz x8,Lcf_absent
    ldr x9,[x8,#8]
    cmp x9,x0
    b.ne Lcf_next
    ldr w10,[x8,#16]
    cmp w10,w1
    b.ne Lcf_next
    ldr x0,[x8,#24]
    ret
Lcf_next:
    ldr x8,[x8]
    b Lcf_loop
Lcf_absent:
    mov x0,#0
    ret

// x0 owned descriptor,x1 key,w2 kind; w0 bool success. Stack48.
// Bound retained decoded texture pixels to64MiB and4096 descriptors.
Lcache_add:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov x19,x0
    mov x20,x1
    mov w21,w2
    ldr w8,[x19]
    ldr w9,[x19,#4]
    mul w22,w8,w9
    lsl x22,x22,#1
    add x22,x22,#32
    adrp x8,Lcache_bytes@PAGE
    ldr x8,[x8,Lcache_bytes@PAGEOFF]
    add x8,x8,x22
    mov x9,#0x4000000
    cmp x8,x9
    b.hi Lca_bad
    adrp x8,Lcache_count@PAGE
    ldr w8,[x8,Lcache_count@PAGEOFF]
    cmp w8,#4096
    b.hs Lca_bad
    mov x0,#32
    bl _malloc
    cbz x0,Lca_bad
    adrp x8,Lcache@PAGE
    ldr x9,[x8,Lcache@PAGEOFF]
    str x9,[x0]
    str x20,[x0,#8]
    str w21,[x0,#16]
    str x19,[x0,#24]
    str x0,[x8,Lcache@PAGEOFF]
    adrp x8,Lcache_bytes@PAGE
    ldr x9,[x8,Lcache_bytes@PAGEOFF]
    add x9,x9,x22
    str x9,[x8,Lcache_bytes@PAGEOFF]
    adrp x8,Lcache_count@PAGE
    ldr w9,[x8,Lcache_count@PAGEOFF]
    add w9,w9,#1
    str w9,[x8,Lcache_count@PAGEOFF]
    mov w0,#1
    b Lca_done
Lca_bad:
    mov w0,#0
Lca_done:
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret

// x0 TEXTURE bytes,x1 length,x2 name key. x0 definition orNULL,x1 remaining.
// Leaf with all pointer arithmetic bounded by actual lump length.
Ltexture_find:
    cmp x1,#4
    b.lo Ltf_bad
    ldr w8,[x0]
    cmp w8,#4096
    b.hi Ltf_bad
    lsl x9,x8,#2
    add x9,x9,#4
    cmp x9,x1
    b.hi Ltf_bad
    mov w10,#0
Ltf_loop:
    cmp w10,w8
    b.hs Ltf_bad
    add x11,x0,#4
    ldr w11,[x11,x10,lsl#2]
    add x12,x11,#22
    cmp x12,x1
    b.hi Ltf_bad
    add x12,x0,x11
    ldr x13,[x12]
    cmp x13,x2
    b.eq Ltf_found
    add w10,w10,#1
    b Ltf_loop
Ltf_found:
    sub x1,x1,x11
    mov x0,x12
    ret
Ltf_bad:
    mov x0,#0
    mov x1,#0
    ret

// x0 wall texture name; returns borrowed descriptor orNULL. Stack160.
.globl _doom_texture
_doom_texture:
    stp x29,x30,[sp,#-160]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    stp x25,x26,[sp,#64]
    stp x27,x28,[sp,#80]
    bl _doom_name_key
    mov x19,x0
    mov w1,#1
    bl Lcache_find
    cbnz x0,Ltex_done
    adrp x0,Ltexture1@PAGE
    add x0,x0,Ltexture1@PAGEOFF
    bl _doom_lump
    cbz x0,Ltex_try_second
    mov x2,x19
    bl Ltexture_find
    cbnz x0,Ltex_definition
Ltex_try_second:
    adrp x0,Ltexture2@PAGE
    add x0,x0,Ltexture2@PAGEOFF
    bl _doom_lump
    cbz x0,Ltex_bad
    mov x2,x19
    bl Ltexture_find
    cbz x0,Ltex_bad
Ltex_definition:
    mov x20,x0
    ldrh w21,[x20,#12]
    ldrh w22,[x20,#14]
    ldrh w23,[x20,#20]
    cbz w21,Ltex_bad
    cbz w22,Ltex_bad
    cmp w21,#2048
    b.hi Ltex_bad
    cmp w22,#2048
    b.hi Ltex_bad
    cmp w23,#256
    b.hi Ltex_bad
    mov x8,#10
    madd x8,x23,x8,xzr
    add x8,x8,#22
    cmp x8,x1
    b.hi Ltex_bad
    adrp x0,Lpnames@PAGE
    add x0,x0,Lpnames@PAGEOFF
    bl _doom_lump
    cmp x1,#4
    b.lo Ltex_bad
    mov x24,x0
    ldr w25,[x24]
    mov w8,#65536
    cmp w25,w8
    b.hi Ltex_bad
    lsl x8,x25,#3
    add x8,x8,#4
    cmp x8,x1
    b.hi Ltex_bad
    mul w8,w21,w22
    lsl x0,x8,#1
    add x0,x0,#32
    str x0,[sp,#96]
    bl _malloc
    cbz x0,Ltex_bad
    mov x26,x0
    str w21,[x26]
    str w22,[x26,#4]
    add x0,x26,#32
    str x0,[x26,#8]
    str xzr,[x26,#16]
    mul w8,w21,w22
    add x8,x0,x8
    str x8,[x26,#24]
    mov w1,#255
    ldr x2,[sp,#96]
    sub x2,x2,#32
    lsr x2,x2,#1
    bl _memset
    ldr x0,[x26,#24]
    mov w1,#0
    mul w2,w21,w22
    bl _memset
    add x20,x20,#22
    mov w27,#0
Ltex_patch_loop:
    cmp w27,w23
    b.hs Ltex_cache
    ldrh w8,[x20,#4]
    cmp w8,w25
    b.hs Ltex_free_bad
    add x0,x24,#4
    add x0,x0,x8,lsl#3
    bl _doom_patch
    cbz x0,Ltex_free_bad
    mov x28,x0
    ldrsh w8,[x20]
    ldrsh w9,[x20,#2]
    str w8,[sp,#104]
    str w9,[sp,#108]
    ldr w10,[x28]
    ldr w11,[x28,#4]
    ldr x12,[x28,#8]
    ldr x13,[x26,#8]
    ldr x6,[x28,#24]
    ldr x7,[x26,#24]
    mov w14,#0
Ltex_y:
    cmp w14,w11
    b.hs Ltex_patch_next
    add w15,w14,w9
    cmp w15,w22
    b.hs Ltex_y_next
    mov w16,#0
Ltex_x:
    cmp w16,w10
    b.hs Ltex_y_next
    add w17,w16,w8
    cmp w17,w21
    b.hs Ltex_x_next
    madd w0,w14,w10,w16
    cbz x6,Ltex_legacy_pixel
    ldrb w2,[x6,x0]
    cbz w2,Ltex_x_next
    ldrb w0,[x12,x0]
    b Ltex_copy_pixel
Ltex_legacy_pixel:
    ldrb w0,[x12,x0]
    cmp w0,#255
    b.eq Ltex_x_next
Ltex_copy_pixel:
    madd w1,w15,w21,w17
    strb w0,[x13,x1]
    mov w2,#1
    strb w2,[x7,x1]
Ltex_x_next:
    add w16,w16,#1
    b Ltex_x
Ltex_y_next:
    add w14,w14,#1
    b Ltex_y
Ltex_patch_next:
    add x20,x20,#10
    add w27,w27,#1
    b Ltex_patch_loop
Ltex_cache:
    mov x0,x26
    mov x1,x19
    mov w2,#1
    bl Lcache_add
    cbz w0,Ltex_free_bad
    mov x0,x26
    b Ltex_done
Ltex_free_bad:
    mov x0,x26
    bl _free
Ltex_bad:
    mov x0,#0
Ltex_done:
    ldp x27,x28,[sp,#80]
    ldp x25,x26,[sp,#64]
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#160
    ret

// Release cache descriptors and nodes. Stack32. No borrowed WAD frees.
.globl _doom_textures_free
_doom_textures_free:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    adrp x8,Lcache@PAGE
    ldr x19,[x8,Lcache@PAGEOFF]
    str xzr,[x8,Lcache@PAGEOFF]
Lfree_loop:
    cbz x19,Lfree_done
    ldr x20,[x19]
    ldr x0,[x19,#24]
    bl _free
    mov x0,x19
    bl _free
    mov x19,x20
    b Lfree_loop
Lfree_done:
    adrp x8,Lcache_bytes@PAGE
    str xzr,[x8,Lcache_bytes@PAGEOFF]
    adrp x8,Lcache_count@PAGE
    str wzr,[x8,Lcache_count@PAGEOFF]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#32
    ret

.section __TEXT,__cstring,cstring_literals
Ltexture1: .asciz "TEXTURE1"
Ltexture2: .asciz "TEXTURE2"
Lpnames: .asciz "PNAMES"
.data
.p2align 3
Lcache: .quad 0
Lcache_bytes: .quad 0
Lcache_count: .quad 0
.subsections_via_symbols
