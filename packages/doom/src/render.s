// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Asm contributors.
// Handwritten Apple AArch64 renderer for the Doom sector/side/line model.
// The per-column portal walk uses original map coordinates, sector heights and
// sidedef textures. No rectangular grid or generated game implementation exists.
// All storage is bounded by ABI.md's validated 32768-record map limit.
// Doom flat orientation and fullbright sky behavior were checked against
// id Software's linuxdoom-1.10/r_plane.c on 2026-11-05:
// https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/r_plane.c
// System sinf/cosf/atan2f supply primitive math; game rules stay in assembly.

.equ R_WIDTH, 320
.equ R_VIEW, 168
.equ R_HEIGHT, 200
.equ R_EDGE_BYTES, 80
.equ C_FB, 0
.equ C_PX, 8
.equ C_PY, 12
.equ C_EYE, 16
.equ C_COS, 20
.equ C_SIN, 24
.equ C_RX, 28
.equ C_RY, 32
.equ C_COL, 36
.equ C_SECTOR, 40
.equ C_TOP, 44
.equ C_BOTTOM, 48
.equ C_PREV, 52
.equ C_DIST, 56
.equ C_U, 60
.equ C_EDGE, 64
.equ C_TEX, 72
.equ C_ANCHOR, 80
.equ C_SKYU, 84
.equ C_LIGHT, 88
.equ C_START, 96
.equ C_END, 100
.equ C_PLANE, 104
.equ C_FLAT, 112
.equ C_SKY, 120

.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _doom_render
// x0: writable 64000-pixel framebuffer. No return value. Writes exactly that
// range. Preserves Apple callee-saved registers. Stack: 160 bytes plus callees.
// Shared caches are owned here and used on the single game thread only.
_doom_render:
    stp x29, x30, [sp, #-160]!
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
    adrp x19, _r_context@PAGE
    add x19, x19, _r_context@PAGEOFF
    str x0, [x19, #C_FB]
    mov x20, x0
    cbz x20, Lrender_done
    // Fully initialize opaque output and the scene's per-pixel depth buffer.
    mov w0, #0x1010
    movk w0, #0xff10, lsl #16
    mov w1, #64000
    mov x2, x20
Lclear_color:
    str w0, [x2], #4
    subs w1, w1, #1
    b.ne Lclear_color
    adrp x2, _r_depth@PAGE
    add x2, x2, _r_depth@PAGEOFF
    mov w0, #0x78ec
    movk w0, #0x60ad, lsl #16
    mov w1, #53760
Lclear_depth:
    str w0, [x2], #4
    subs w1, w1, #1
    b.ne Lclear_depth
    bl Lbuild_cache
    bl Lbegin_frame
    adrp x21, _doom_player@PAGE
    add x21, x21, _doom_player@PAGEOFF
    ldr s0, [x21]
    str s0, [x19, #C_PX]
    ldr s0, [x21, #4]
    str s0, [x19, #C_PY]
    ldr s0, [x21, #8]
    ldr s1, [x21, #52]
    fadd s0, s0, s1
    str s0, [x19, #C_EYE]
    ldr s0, [x21, #12]
    bl _cosf
    str s0, [x19, #C_COS]
    ldr s0, [x21, #12]
    bl _sinf
    str s0, [x19, #C_SIN]
    ldr w22, [x21, #48]
    adrp x0, _doom_sector_count@PAGE
    ldr w0, [x0, _doom_sector_count@PAGEOFF]
    cmp w22, w0
    b.lo Lsector_ok
    ldr s0, [x19, #C_PX]
    ldr s1, [x19, #C_PY]
    bl _doom_point_sector
    mov w22, w0
Lsector_ok:
    tbnz w22, #31, Lscene_done
    mov w23, #0
Lcolumn:
    str w23, [x19, #C_COL]
    str w22, [x19, #C_SECTOR]
    str wzr, [x19, #C_TOP]
    mov w0, #167
    str w0, [x19, #C_BOTTOM]
    fmov s0, #0.0
    str s0, [x19, #C_PREV]
    // East=0 and north=pi/2. Right is (sin(angle), -cos(angle)).
    scvtf s0, w23
    fmov s1, #0.5
    fadd s0, s0, s1
    mov w0, #160
    scvtf s1, w0
    fsub s0, s0, s1
    fdiv s0, s0, s1
    ldr s1, [x19, #C_COS]
    ldr s2, [x19, #C_SIN]
    fmadd s3, s0, s2, s1
    fmsub s4, s0, s1, s2
    str s3, [x19, #C_RX]
    str s4, [x19, #C_RY]
    fmov s0, s4
    fmov s1, s3
    bl _atan2f
    str s0, [x19, #C_SKYU]
    mov w24, #0
Lportal:
    bl Lnearest_edge
    ldr x0, [x19, #C_EDGE]
    bl Lrefresh_material
    bl Ldraw_sector_planes
    ldr x21, [x19, #C_EDGE]
    cbz x21, Lcolumn_done
    ldr w25, [x21, #24]
    tbnz w25, #31, Lsolid_wall
    adrp x0, _doom_sector_count@PAGE
    ldr w0, [x0, _doom_sector_count@PAGEOFF]
    cmp w25, w0
    b.hs Lsolid_wall
    // Dynamic heights, rather than immutable WAD heights, drive portals.
    adrp x0, _doom_sector_floors@PAGE
    ldr x0, [x0, _doom_sector_floors@PAGEOFF]
    ldr s8, [x0, w25, uxtw #2]
    adrp x0, _doom_sector_ceilings@PAGE
    ldr x0, [x0, _doom_sector_ceilings@PAGEOFF]
    ldr s9, [x0, w25, uxtw #2]
    ldr w1, [x19, #C_SECTOR]
    adrp x0, _doom_sector_floors@PAGE
    ldr x0, [x0, _doom_sector_floors@PAGEOFF]
    ldr s10, [x0, w1, uxtw #2]
    adrp x0, _doom_sector_ceilings@PAGE
    ldr x0, [x0, _doom_sector_ceilings@PAGEOFF]
    ldr s11, [x0, w1, uxtw #2]
    fcmp s8, s11
    b.ge Lsolid_wall
    fcmp s9, s10
    b.le Lsolid_wall
    // Upper wall between the current ceiling and the next ceiling.
    fcmp s9, s11
    b.ge Llower_wall
    adrp x0, _r_sectors@PAGE
    add x0, x0, _r_sectors@PAGEOFF
    ldr w1, [x19, #C_SECTOR]
    add x1, x0, x1, lsl #5
    ldr w1, [x1, #24]
    add x0, x0, x25, lsl #5
    ldr w0, [x0, #24]
    and w0, w0, w1
    cbnz w0, Llower_wall
    ldr x0, [x21, #48]
    str x0, [x19, #C_TEX]
    fmov s0, s11
    bl Lproject
    mov w26, w0
    fmov s0, s9
    bl Lproject
    sub w1, w0, #1
    mov w0, w26
    fmov s2, s11
    // Doom upper texture pegs to the lower ceiling unless DONTPEGTOP.
    ldr w3, [x21, #68]
    tbnz w3, #3, Lupper_anchor
    ldr x3, [x19, #C_TEX]
    cbz x3, Lupper_anchor
    ldr w3, [x3, #4]
    scvtf s2, w3
    fadd s2, s9, s2
Lupper_anchor:
    str s2, [x19, #C_ANCHOR]
    bl Ldraw_wall
Llower_wall:
    fcmp s8, s10
    b.le Lmasked_wall
    ldr x0, [x21, #56]
    str x0, [x19, #C_TEX]
    fmov s0, s8
    bl Lproject
    mov w26, w0
    fmov s0, s10
    bl Lproject
    mov w1, w0
    mov w0, w26
    fmov s2, s8
    ldr w3, [x21, #68]
    tbz w3, #4, Llower_anchor
    fmov s2, s11
Llower_anchor:
    str s2, [x19, #C_ANCHOR]
    bl Ldraw_wall
Lmasked_wall:
    // Transparent middle textures never close the portal aperture.
    ldr x0, [x21, #40]
    cbz x0, Ladvance_portal
    str x0, [x19, #C_TEX]
    fmin s12, s9, s11
    fmax s13, s8, s10
    fmov s0, s12
    ldr w1, [x21, #68]
    tbz w1, #4, Lmasked_anchor_ready
    ldr x1, [x19, #C_TEX]
    ldr w1, [x1, #4]
    scvtf s0, w1
    fadd s0, s13, s0
Lmasked_anchor_ready:
    str s0, [x19, #C_ANCHOR]
    fmov s0, s12
    bl Lproject
    mov w26, w0
    fmov s0, s13
    bl Lproject
    mov w1, w0
    mov w0, w26
    // Mode 1 clips middle texture vertically instead of repeating it.
    mov w2, #1
    bl Ldraw_wall_mode
Ladvance_portal:
    fmov s0, s9
    bl Lproject
    ldr w1, [x19, #C_TOP]
    cmp w0, w1
    csel w0, w0, w1, gt
    str w0, [x19, #C_TOP]
    fmov s0, s8
    bl Lproject
    ldr w1, [x19, #C_BOTTOM]
    cmp w0, w1
    csel w0, w0, w1, lt
    str w0, [x19, #C_BOTTOM]
    ldr w1, [x19, #C_TOP]
    cmp w1, w0
    b.gt Lcolumn_done
    str w25, [x19, #C_SECTOR]
    ldr s0, [x19, #C_DIST]
    str s0, [x19, #C_PREV]
    add w24, w24, #1
    cmp w24, #32768
    b.lo Lportal
    b Lcolumn_done
Lsolid_wall:
    ldr w1, [x19, #C_SECTOR]
    adrp x0, _doom_sector_ceilings@PAGE
    ldr x0, [x0, _doom_sector_ceilings@PAGEOFF]
    ldr s8, [x0, w1, uxtw #2]
    adrp x0, _doom_sector_floors@PAGE
    ldr x0, [x0, _doom_sector_floors@PAGEOFF]
    ldr s9, [x0, w1, uxtw #2]
    ldr x0, [x21, #40]
    str x0, [x19, #C_TEX]
    fmov s0, s8
    bl Lproject
    mov w26, w0
    fmov s0, s9
    bl Lproject
    mov w1, w0
    mov w0, w26
    ldr w3, [x21, #68]
    tbz w3, #4, Lsolid_anchor
    ldr x3, [x19, #C_TEX]
    cbz x3, Lsolid_anchor
    ldr w3, [x3, #4]
    scvtf s8, w3
    fadd s8, s8, s9
Lsolid_anchor:
    str s8, [x19, #C_ANCHOR]
    bl Ldraw_wall
Lcolumn_done:
    add w23, w23, #1
    cmp w23, #320
    b.lo Lcolumn
Lscene_done:
    bl Ldraw_actors
    bl Ldraw_weapon
    bl Ldamage_tint
    bl Ldraw_hud
Lrender_done:
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #160
    ret

// Build immutable adjacency and resource caches. x19=context; preserves x19+.
// Edge: next:u32,x/y/dx/dy:f32,textureX:f32,back:i32,pad,side:pointer,
// middle/upper/lower:descriptor pointers,length:f32,lineflags:u32,sideIndex:u32,
// materialEpoch:u32. Geometry remains immutable; material queries refresh once
// per used side/frame. Sector cache adds floor-material epoch at byte28.
// Stack112. Checks side and sector indices. The map loader validates vertices.
Lbuild_cache:
    stp x29, x30, [sp, #-112]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    adrp x20, _doom_lines@PAGE
    ldr x20, [x20, _doom_lines@PAGEOFF]
    adrp x21, _r_cached_lines@PAGE
    ldr x0, [x21, _r_cached_lines@PAGEOFF]
    cmp x0, x20
    b.ne Lcache_rebuild
    adrp x0, _doom_line_count@PAGE
    ldr w0, [x0, _doom_line_count@PAGEOFF]
    adrp x1, _r_cached_count@PAGE
    ldr w1, [x1, _r_cached_count@PAGEOFF]
    cmp w0, w1
    b.eq Lcache_done
Lcache_rebuild:
    str x20, [x21, _r_cached_lines@PAGEOFF]
    adrp x0, _doom_line_count@PAGE
    ldr w0, [x0, _doom_line_count@PAGEOFF]
    adrp x1, _r_cached_count@PAGE
    str w0, [x1, _r_cached_count@PAGEOFF]
    adrp x21, _r_heads@PAGE
    add x21, x21, _r_heads@PAGEOFF
    mov w0, #-1
    mov w1, #32768
    mov x2, x21
Lheads_clear:
    str w0, [x2], #4
    subs w1, w1, #1
    b.ne Lheads_clear
    adrp x22, _doom_sector_count@PAGE
    ldr w22, [x22, _doom_sector_count@PAGEOFF]
    mov w0, #32768
    cmp w22, w0
    csel w22, w22, w0, lo
    mov w23, #0
Lcache_sector:
    cmp w23, w22
    b.hs Lcache_edges_start
    adrp x0, _doom_sectors@PAGE
    ldr x0, [x0, _doom_sectors@PAGEOFF]
    mov w1, #26
    umaddl x24, w23, w1, x0
    adrp x25, _r_sectors@PAGE
    add x25, x25, _r_sectors@PAGEOFF
    add x25, x25, x23, lsl #5
    str x24, [x25, #16]
    add x0, x24, #4
    bl _doom_flat
    str x0, [x25]
    add x0, x24, #12
    bl _doom_flat
    str x0, [x25, #8]
    ldr w0, [x24, #12]
    mov w1, #0x5f46
    movk w1, #0x4b53, lsl #16
    cmp w0, w1
    cset w0, eq
    str w0, [x25, #24]
    str wzr, [x25, #28]
    add w23, w23, #1
    b Lcache_sector
Lcache_edges_start:
    // Ultimate Doom episodes select their own sky texture.
    mov w0, #0x4b53
    movk w0, #0x3159, lsl #16
    str w0, [sp, #96]
    str wzr, [sp, #100]
    bl _doom_world_map
    cbz x0, Lcache_sky_ready
    ldrb w0, [x0, #1]
    cmp w0, #49
    b.lo Lcache_sky_ready
    cmp w0, #52
    b.hi Lcache_sky_ready
    strb w0, [sp, #99]
Lcache_sky_ready:
    add x0, sp, #96
    bl _doom_texture
    adrp x1, _r_sky@PAGE
    str x0, [x1, _r_sky@PAGEOFF]
    mov w23, #0
Lcache_line:
    adrp x0, _r_cached_count@PAGE
    ldr w0, [x0, _r_cached_count@PAGEOFF]
    cmp w23, w0
    b.hs Lcache_done
    cmp w23, #32768
    b.hs Lcache_done
    mov w0, #14
    umaddl x24, w23, w0, x20
    mov w25, #0
Lcache_side:
    add x0, x24, x25, lsl #1
    ldrh w26, [x0, #10]
    adrp x1, _doom_side_count@PAGE
    ldr w1, [x1, _doom_side_count@PAGEOFF]
    cmp w26, w1
    b.hs Lcache_next_side
    adrp x0, _doom_sides@PAGE
    ldr x0, [x0, _doom_sides@PAGEOFF]
    mov w1, #30
    umaddl x26, w26, w1, x0
    ldrh w27, [x26, #28]
    cmp w27, w22
    b.hs Lcache_next_side
    add w28, w25, w23, lsl #1
    adrp x0, _r_edges@PAGE
    add x0, x0, _r_edges@PAGEOFF
    mov w1, #80
    umaddl x28, w28, w1, x0
    ldr w0, [x21, w27, uxtw #2]
    str w0, [x28]
    add w0, w25, w23, lsl #1
    str w0, [x21, w27, uxtw #2]
    str wzr, [x28, #76]
    add x0, x24, x25, lsl #1
    ldrh w0, [x0, #10]
    str w0, [x28, #72]
    ldrsh w0, [x26]
    scvtf s0, w0
    str s0, [x28, #20]
    str x26, [x28, #32]
    ldrh w0, [x24, #4]
    str w0, [x28, #68]
    eor w0, w25, #1
    add x0, x24, x0, lsl #1
    ldrh w0, [x0, #10]
    adrp x1, _doom_side_count@PAGE
    ldr w1, [x1, _doom_side_count@PAGEOFF]
    cmp w0, w1
    b.hs Lcache_no_back
    adrp x1, _doom_sides@PAGE
    ldr x1, [x1, _doom_sides@PAGEOFF]
    mov w2, #30
    umaddl x0, w0, w2, x1
    ldrh w0, [x0, #28]
    b Lcache_back_set
Lcache_no_back:
    mov w0, #-1
Lcache_back_set:
    str w0, [x28, #24]
    // Reversing the second sidedef preserves Doom's texture direction.
    ldrh w0, [x24]
    ldrh w1, [x24, #2]
    cmp w25, #0
    csel w2, w0, w1, eq
    csel w3, w1, w0, eq
    adrp x0, _doom_vertices@PAGE
    ldr x0, [x0, _doom_vertices@PAGEOFF]
    add x1, x0, x2, lsl #2
    add x0, x0, x3, lsl #2
    ldrsh w2, [x1]
    ldrsh w3, [x1, #2]
    ldrsh w4, [x0]
    ldrsh w5, [x0, #2]
    scvtf s0, w2
    scvtf s1, w3
    sub w4, w4, w2
    sub w5, w5, w3
    scvtf s2, w4
    scvtf s3, w5
    stp s0, s1, [x28, #4]
    stp s2, s3, [x28, #12]
    fmul s0, s2, s2
    fmadd s0, s3, s3, s0
    fsqrt s0, s0
    str s0, [x28, #64]
    add x0, x26, #20
    bl _doom_texture
    str x0, [x28, #40]
    add x0, x26, #4
    bl _doom_texture
    str x0, [x28, #48]
    add x0, x26, #12
    bl _doom_texture
    str x0, [x28, #56]
Lcache_next_side:
    add w25, w25, #1
    cmp w25, #2
    b.lo Lcache_side
    add w23, w23, #1
    b Lcache_line
Lcache_done:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #112
    ret

// Advance material epoch. On u32 wrap, clear all bounded epoch fields before
// reusing epoch1. Leaf, no stack; changes renderer-owned state only.
Lbegin_frame:
    adrp x0, _r_epoch@PAGE
    ldr w1, [x0, _r_epoch@PAGEOFF]
    adds w1, w1, #1
    b.ne Lepoch_set
    adrp x2, _r_edges@PAGE
    add x2, x2, _r_edges@PAGEOFF
    mov w3, #65536
Lepoch_edges:
    str wzr, [x2, #76]
    add x2, x2, #80
    subs w3, w3, #1
    b.ne Lepoch_edges
    adrp x2, _r_sectors@PAGE
    add x2, x2, _r_sectors@PAGEOFF
    mov w3, #32768
Lepoch_sectors:
    str wzr, [x2, #28]
    add x2, x2, #32
    subs w3, w3, #1
    b.ne Lepoch_sectors
    mov w1, #1
Lepoch_set:
    str w1, [x0, _r_epoch@PAGEOFF]
    ret

// x0 optional edge -> refreshed borrowed textures and total X offset. Dynamic
// material accessors are called at most once per used sidedef/frame, never from
// a pixel loop. Missing material names keep bounded null descriptors. Stack48.
Lrefresh_material:
    cbz x0, Lrefresh_return
    adrp x1, _r_epoch@PAGE
    ldr w1, [x1, _r_epoch@PAGEOFF]
    ldr w2, [x0, #76]
    cmp w1, w2
    b.eq Lrefresh_return
    str w1, [x0, #76]
    stp x29, x30, [sp, #-48]!
    stp x21, x22, [sp, #16]
    mov x21, x0
    ldr w22, [x21, #72]
    mov w0, w22
    mov w1, #0
    bl _doom_world_side_texture
    cbz x0, Lrefresh_upper_ready
    bl _doom_texture
Lrefresh_upper_ready:
    str x0, [x21, #48]
    mov w0, w22
    mov w1, #1
    bl _doom_world_side_texture
    cbz x0, Lrefresh_lower_ready
    bl _doom_texture
Lrefresh_lower_ready:
    str x0, [x21, #56]
    mov w0, w22
    mov w1, #2
    bl _doom_world_side_texture
    cbz x0, Lrefresh_middle_ready
    bl _doom_texture
Lrefresh_middle_ready:
    str x0, [x21, #40]
    mov w0, w22
    bl _doom_world_side_offset
    str s0, [x21, #20]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #48
Lrefresh_return:
    ret

// Find the first crossing of the current sector after C_PREV. No stack/calls.
// Uses cross products with original line segments; stores edge, depth and U.
Lnearest_edge:
    str xzr, [x19, #C_EDGE]
    mov w0, #0x2400
    movk w0, #0x4974, lsl #16  // 1000000.0
    fmov s7, w0
    str s7, [x19, #C_DIST]
    ldr w0, [x19, #C_SECTOR]
    cmp w0, #32768
    b.hs Lnearest_done
    adrp x1, _r_heads@PAGE
    add x1, x1, _r_heads@PAGEOFF
    ldr w0, [x1, w0, uxtw #2]
    adrp x1, _r_edges@PAGE
    add x1, x1, _r_edges@PAGEOFF
    ldr s16, [x19, #C_RX]
    ldr s17, [x19, #C_RY]
    ldr s18, [x19, #C_PX]
    ldr s19, [x19, #C_PY]
    ldr s20, [x19, #C_PREV]
    mov w2, #0x126f
    movk w2, #0x3a83, lsl #16  // 0.001
    fmov s21, w2
    fadd s20, s20, s21
    mov w3, #0
Lnearest_loop:
    tbnz w0, #31, Lnearest_done
    cmp w0, #65536
    b.hs Lnearest_done
    mov w2, #80
    umaddl x4, w0, w2, x1
    ldp s0, s1, [x4, #4]
    ldp s2, s3, [x4, #12]
    fmul s4, s16, s3
    fmsub s5, s17, s2, s4
    fmov s4, s5                 // cross(ray, edge)
    fabs s5, s4
    fcmp s5, s21
    b.le Lnearest_next
    fsub s0, s0, s18
    fsub s1, s1, s19
    fmul s5, s0, s3
    fmsub s6, s1, s2, s5
    fmov s5, s6
    fdiv s5, s5, s4
    fcmp s5, s20
    b.le Lnearest_next
    fcmp s5, s7
    b.ge Lnearest_next
    fmul s6, s0, s17
    fmsub s0, s1, s16, s6
    fmov s6, s0
    fdiv s6, s6, s4
    fcmp s6, #0.0
    b.lt Lnearest_next
    fmov s0, #1.0
    fcmp s6, s0
    b.gt Lnearest_next
    fmov s7, s5
    str s5, [x19, #C_DIST]
    str s6, [x19, #C_U]
    str x4, [x19, #C_EDGE]
Lnearest_next:
    ldr w0, [x4]
    add w3, w3, #1
    cmp w3, #65536
    b.lo Lnearest_loop
Lnearest_done:
    ret

// s0 world height -> w0 rounded screen row. x19 context. No calls/stack.
// Clamps before conversion so corrupt/extreme view values cannot wrap indices.
Lproject:
    ldr s1, [x19, #C_EYE]
    fsub s0, s0, s1
    mov w0, #160
    scvtf s1, w0
    fmul s0, s0, s1
    ldr s1, [x19, #C_DIST]
    fdiv s0, s0, s1
    mov w0, #84
    scvtf s1, w0
    fsub s0, s1, s0
    mov w0, #8192
    scvtf s1, w0
    fmin s0, s0, s1
    fneg s1, s1
    fmax s0, s0, s1
    fcvtms w0, s0
    ret

// Current sector's visible planes before its nearest line. Stack 64 bytes.
Ldraw_sector_planes:
    stp x29, x30, [sp, #-64]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    ldr w21, [x19, #C_SECTOR]
    adrp x22, _r_sectors@PAGE
    add x22, x22, _r_sectors@PAGEOFF
    add x22, x22, x21, lsl #5
    adrp x0, _doom_sector_lights@PAGE
    ldr x0, [x0, _doom_sector_lights@PAGEOFF]
    cbz x0, Lplane_full_light
    ldr w0, [x0, w21, uxtw #2]
    b Lplane_light_set
Lplane_full_light:
    mov w0, #255
Lplane_light_set:
    str w0, [x19, #C_LIGHT]
    // Ceiling: top aperture through ceiling's intersection with the wall.
    adrp x0, _doom_sector_ceilings@PAGE
    ldr x0, [x0, _doom_sector_ceilings@PAGEOFF]
    cbz x0, Lplanes_done
    ldr s0, [x0, w21, uxtw #2]
    // Doom's sky hack joins adjacent sky sectors despite different heights.
    // Project the lower of their ceilings and omit the corresponding upper wall.
    ldr w1, [x22, #24]
    cbz w1, Lceiling_height_ready
    ldr x1, [x19, #C_EDGE]
    cbz x1, Lceiling_height_ready
    ldr w1, [x1, #24]
    adrp x2, _doom_sector_count@PAGE
    ldr w2, [x2, _doom_sector_count@PAGEOFF]
    cmp w1, w2
    b.hs Lceiling_height_ready
    adrp x2, _r_sectors@PAGE
    add x2, x2, _r_sectors@PAGEOFF
    add x2, x2, x1, lsl #5
    ldr w2, [x2, #24]
    cbz w2, Lceiling_height_ready
    ldr s1, [x0, w1, uxtw #2]
    fmin s0, s0, s1
Lceiling_height_ready:
    str s0, [x19, #C_PLANE]
    bl Lproject
    sub w1, w0, #1
    ldr w0, [x19, #C_TOP]
    ldr x2, [x22, #8]
    str x2, [x19, #C_FLAT]
    ldr w2, [x22, #24]
    str w2, [x19, #C_SKY]
    bl Ldraw_plane
    // Floor from the wall floor down to the lower aperture.
    ldr w0, [x22, #28]
    adrp x1, _r_epoch@PAGE
    ldr w1, [x1, _r_epoch@PAGEOFF]
    cmp w0, w1
    b.eq Lfloor_material_ready
    mov w0, w21
    bl _doom_world_floor_flat
    cbz x0, Lfloor_material_store
    bl _doom_flat
Lfloor_material_store:
    str x0, [x22]
    adrp x1, _r_epoch@PAGE
    ldr w1, [x1, _r_epoch@PAGEOFF]
    str w1, [x22, #28]
Lfloor_material_ready:
    adrp x0, _doom_sector_floors@PAGE
    ldr x0, [x0, _doom_sector_floors@PAGEOFF]
    cbz x0, Lplanes_done
    ldr s0, [x0, w21, uxtw #2]
    str s0, [x19, #C_PLANE]
    bl Lproject
    add w0, w0, #1
    ldr w1, [x19, #C_BOTTOM]
    ldr x2, [x22]
    str x2, [x19, #C_FLAT]
    str wzr, [x19, #C_SKY]
    bl Ldraw_plane
Lplanes_done:
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// w0..w1 inclusive vertical plane range. Perspective maps 64x64 flat in world
// coordinates; negative coordinates wrap with two's-complement AND. Stack 80.
Ldraw_plane:
    stp x29, x30, [sp, #-80]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp d8, d9, [sp, #48]
    cmp w0, #0
    csel w21, w0, wzr, gt
    mov w2, #167
    cmp w1, w2
    csel w22, w1, w2, lt
    cmp w21, w22
    b.gt Ldraw_plane_done
    ldr x23, [x19, #C_FLAT]
    ldr s8, [x19, #C_PLANE]
    ldr s0, [x19, #C_EYE]
    fsub s8, s8, s0
    mov w0, #160
    scvtf s0, w0
    fmul s8, s8, s0
Lplane_pixel:
    ldr w0, [x19, #C_SKY]
    cbnz w0, Lsky_depth
    mov w0, #84
    sub w0, w0, w21
    cbz w0, Lplane_next
    scvtf s0, w0
    fdiv s9, s8, s0
    fcmp s9, #0.0
    b.le Lplane_next
    ldr s0, [x19, #C_RX]
    ldr s1, [x19, #C_PX]
    fmadd s0, s9, s0, s1
    ldr s1, [x19, #C_RY]
    ldr s2, [x19, #C_PY]
    fmadd s1, s9, s1, s2
    fneg s1, s1              // Doom flat rows run opposite world Y.
    fcvtms w0, s0
    fcvtms w1, s1
    and w0, w0, #63
    and w1, w1, #63
    add w0, w0, w1, lsl #6
    cbz x23, Lplane_fallback
    ldrb w0, [x23, w0, uxtw]
    b Lplane_color
Lplane_fallback:
    and w0, w0, #8
    add w0, w0, #32
    b Lplane_color
Lsky_depth:
    mov w0, #0x78ec
    movk w0, #0x60ad, lsl #16
    fmov s9, w0
Lsky_pixel:
    // Sky remains at infinity, with horizontal orientation tied to view angle.
    adrp x2, _r_sky@PAGE
    ldr x2, [x2, _r_sky@PAGEOFF]
    cbz x2, Lsky_fallback
    ldp w3, w4, [x2]
    cbz w3, Lsky_fallback
    cbz w4, Lsky_fallback
    cmp w3, #4096
    b.hi Lsky_fallback
    cmp w4, #4096
    b.hi Lsky_fallback
    ldr x2, [x2, #8]
    cbz x2, Lsky_fallback
    ldr s0, [x19, #C_SKYU]
    mov w0, #0xf983
    movk w0, #0x4322, lsl #16 // 1024/(2*pi), Doom's angular sky columns.
    fmov s1, w0
    fmul s0, s0, s1
    fcvtms w0, s0
    sdiv w1, w0, w3
    msub w0, w1, w3, w0
    cmp w0, #0
    add w1, w0, w3
    csel w0, w1, w0, lt
    mul w1, w21, w4
    mov w5, #168
    udiv w1, w1, w5
    madd w0, w1, w3, w0
    ldrb w0, [x2, w0, uxtw]
    b Lplane_color
Lsky_fallback:
    mov w0, #112
Lplane_color:
    ldr w1, [x19, #C_SKY]
    cbnz w1, Lplane_sky_color
    fmov s0, s9
    bl Lpalette_color
    b Lplane_put
Lplane_sky_color:
    bl Lpalette_lookup
Lplane_put:
    mov w1, w21
    fmov s0, s9
    bl Lput_depth
Lplane_next:
    add w21, w21, #1
    cmp w21, w22
    b.le Lplane_pixel
Ldraw_plane_done:
    ldp d8, d9, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// Wall span w0..w1. C_TEX descriptor, C_ANCHOR world top, C_EDGE/U/DIST.
// Clips every access; solid missing textures show a bounded checker. Stack 112.
Ldraw_wall:
    mov w2, #0
Ldraw_wall_mode:
    stp x29, x30, [sp, #-112]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp d8, d9, [sp, #64]
    stp d10, d11, [sp, #80]
    mov w26, w2
    ldr w2, [x19, #C_TOP]
    cmp w0, w2
    csel w21, w0, w2, gt
    cmp w21, #0
    csel w21, w21, wzr, gt
    ldr w2, [x19, #C_BOTTOM]
    cmp w1, w2
    csel w22, w1, w2, lt
    mov w2, #167
    cmp w22, w2
    csel w22, w22, w2, lt
    cmp w21, w22
    b.gt Lwall_done
    ldr x23, [x19, #C_TEX]
    str xzr, [sp, #104]
    mov w24, #64
    mov w25, #64
    cbz x23, Lwall_descriptor_done
    ldp w24, w25, [x23]
    cmp w24, #1
    b.lo Lwall_bad_descriptor
    cmp w25, #1
    b.lo Lwall_bad_descriptor
    cmp w24, #4096
    b.hi Lwall_bad_descriptor
    cmp w25, #4096
    b.hi Lwall_bad_descriptor
    ldr x0, [x23, #24]
    str x0, [sp, #104]
    ldr x23, [x23, #8]
    b Lwall_descriptor_done
Lwall_bad_descriptor:
    mov x23, #0
    mov w24, #64
    mov w25, #64
Lwall_descriptor_done:
    ldr x2, [x19, #C_EDGE]
    ldr s0, [x19, #C_U]
    ldr s1, [x2, #64]
    fmul s0, s0, s1
    ldr s1, [x2, #20]
    fadd s0, s0, s1
    ldr x2, [x2, #32]
    fcvtms w0, s0
    sdiv w1, w0, w24
    msub w0, w1, w24, w0
    cmp w0, #0
    add w1, w0, w24
    csel w0, w1, w0, lt
    str w0, [sp, #96]
    ldrsh w0, [x2, #2]
    scvtf s11, w0
    ldr s8, [x19, #C_DIST]
    mov w0, #160
    scvtf s0, w0
    fdiv s9, s8, s0
    ldr s10, [x19, #C_ANCHOR]
    ldr s0, [x19, #C_EYE]
    fsub s10, s10, s0
    fadd s10, s10, s11
Lwall_pixel:
    mov w0, #84
    sub w0, w21, w0
    scvtf s0, w0
    fmadd s0, s0, s9, s10
    fcvtms w0, s0
    cbz w26, Lwall_repeat
    cmp w0, w25
    b.hs Lwall_next
    b Lwall_sample
Lwall_repeat:
    sdiv w1, w0, w25
    msub w0, w1, w25, w0
    cmp w0, #0
    add w1, w0, w25
    csel w0, w1, w0, lt
Lwall_sample:
    ldr w1, [sp, #96]
    madd w0, w0, w24, w1
    cbz x23, Lwall_fallback
    ldr x2, [sp, #104]
    cbz x2, Lwall_legacy_alpha
    ldrb w1, [x2, w0, uxtw]
    cbz w1, Lwall_next
    ldrb w0, [x23, w0, uxtw]
    b Lwall_color
Lwall_legacy_alpha:
    ldrb w0, [x23, w0, uxtw]
    cmp w0, #255
    b.eq Lwall_next
    b Lwall_color
Lwall_fallback:
    eor w0, w0, w1
    and w0, w0, #8
    add w0, w0, #96
Lwall_color:
    fmov s0, s8
    bl Lpalette_color
    mov w1, w21
    fmov s0, s8
    bl Lput_depth
Lwall_next:
    add w21, w21, #1
    cmp w21, w22
    b.le Lwall_pixel
Lwall_done:
    ldp d10, d11, [sp, #80]
    ldp d8, d9, [sp, #64]
    ldp x25, x26, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #112
    ret

// w0 palette index, s0 depth -> w0 opaque 0xffRRGGBB. No stack or calls.
// COLORMAP supplies the data-defined lighting ramp. Without it, retain palette.
Lpalette_color:
    and w0, w0, #255
    adrp x2, _doom_colormap@PAGE
    ldr x2, [x2, _doom_colormap@PAGEOFF]
    cbz x2, Lpalette_lookup
    ldr w3, [x19, #C_LIGHT]
    cmp w3, #0
    csel w3, w3, wzr, gt
    mov w4, #255
    cmp w3, w4
    csel w3, w3, w4, lt
    sub w3, w4, w3
    lsr w3, w3, #3
    fcvtzu w4, s0
    lsr w4, w4, #7
    add w3, w3, w4
    mov w4, #31
    cmp w3, w4
    csel w3, w3, w4, lo
    add w0, w0, w3, lsl #8
    ldrb w0, [x2, w0, uxtw]
Lpalette_lookup:
    adrp x2, _doom_palette@PAGE
    ldr x2, [x2, _doom_palette@PAGEOFF]
    cbz x2, Lpalette_gray
    add w3, w0, w0, lsl #1
    add x2, x2, w3, uxtw
    ldrb w3, [x2]
    ldrb w4, [x2, #1]
    ldrb w0, [x2, #2]
    orr w0, w0, w4, lsl #8
    orr w0, w0, w3, lsl #16
    b Lpalette_alpha
Lpalette_gray:
    orr w0, w0, w0, lsl #8
    orr w0, w0, w0, lsl #16
Lpalette_alpha:
    orr w0, w0, #0xff000000
    ret

// w0 RGBA,w1 valid scene row,s0 depth. Column from context. Depth test prevents
// masked middle textures and walls from overwriting nearer geometry. No stack.
Lput_depth:
    ldr w2, [x19, #C_COL]
    mov w3, #320
    madd w2, w1, w3, w2
    adrp x3, _r_depth@PAGE
    add x3, x3, _r_depth@PAGEOFF
    ldr s1, [x3, w2, uxtw #2]
    fcmp s0, s1
    b.gt Lput_done
    str s0, [x3, w2, uxtw #2]
    ldr x3, [x19, #C_FB]
    str w0, [x3, w2, uxtw #2]
Lput_done:
    ret

// World sprites: perspective billboard patches, masked pixels, per-pixel world
// depth test. Actor storage is ABI-owned and limited to 4096. Stack 144 bytes.
Ldraw_actors:
    stp x29, x30, [sp, #-144]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp d8, d9, [sp, #80]
    stp d10, d11, [sp, #96]
    stp d12, d13, [sp, #112]
    adrp x21, _doom_actors@PAGE
    add x21, x21, _doom_actors@PAGEOFF
    adrp x22, _doom_actor_count@PAGE
    ldr w22, [x22, _doom_actor_count@PAGEOFF]
    mov w0, #4096
    cmp w22, w0
    csel w22, w22, w0, lo
    mov w23, #0
Lactor:
    cmp w23, w22
    b.hs Lactors_done
    ldr w0, [x21, #32]
    tbnz w0, #6, Lactor_next
    ldr s0, [x21]
    ldr s1, [x21, #4]
    ldr s2, [x19, #C_PX]
    ldr s3, [x19, #C_PY]
    fsub s0, s0, s2
    fsub s1, s1, s3
    ldr s2, [x19, #C_COS]
    ldr s3, [x19, #C_SIN]
    fmul s8, s0, s2
    fmadd s8, s1, s3, s8
    fmov s4, #1.0
    fcmp s8, s4
    b.le Lactor_next
    fmul s9, s1, s2
    fmsub s4, s0, s3, s9
    fneg s9, s4
    mov x0, x21
    bl Lactor_patch
    cbz x0, Lactor_next
    mov x24, x0
    ldp w25, w26, [x24]
    cmp w25, #4096
    b.hi Lactor_next
    cmp w26, #4096
    b.hi Lactor_next
    cbz w25, Lactor_next
    cbz w26, Lactor_next
    mov w0, #160
    scvtf s10, w0
    fdiv s10, s10, s8
    fmul s9, s9, s10
    scvtf s0, w0
    fadd s9, s9, s0
    ldr w0, [x24, #16]
    ldr w1, [x19, #C_START]
    cbz w1, Lactor_offset_ready
    sub w0, w25, w0
Lactor_offset_ready:
    scvtf s0, w0
    fmsub s0, s0, s10, s9
    fmov s11, s0             // screen left
    ldr s0, [x21, #8]
    ldr w0, [x24, #20]
    scvtf s1, w0
    fadd s0, s0, s1
    ldr s1, [x19, #C_EYE]
    fsub s0, s0, s1
    fmul s0, s0, s10
    mov w0, #84
    scvtf s1, w0
    fsub s12, s1, s0         // screen top
    scvtf s0, w25
    fmadd s0, s0, s10, s11
    fcvtps w27, s0
    mov w0, #319
    cmp w27, w0
    csel w27, w27, w0, lt
    fcvtms w28, s11
    cmp w28, #0
    csel w28, w28, wzr, gt
    // Find sector light for this actor, independent of the last world column.
    ldr s0, [x21]
    ldr s1, [x21, #4]
    bl _doom_point_sector
    adrp x1, _doom_sector_count@PAGE
    ldr w1, [x1, _doom_sector_count@PAGEOFF]
    cmp w0, w1
    b.hs Lactor_full_light
    adrp x1, _doom_sector_lights@PAGE
    ldr x1, [x1, _doom_sector_lights@PAGEOFF]
    cbz x1, Lactor_full_light
    ldr w0, [x1, w0, uxtw #2]
    b Lactor_light_set
Lactor_full_light:
    mov w0, #255
Lactor_light_set:
    str w0, [x19, #C_LIGHT]
Lactor_x:
    cmp w28, w27
    b.gt Lactor_next
    str w28, [x19, #C_COL]
    scvtf s0, w28
    fsub s0, s0, s11
    fdiv s0, s0, s10
    fcvtms w0, s0
    cmp w0, w25
    b.hs Lactor_x_next
    ldr w1, [x19, #C_START]
    cbz w1, Lactor_source_x
    sub w0, w25, w0
    sub w0, w0, #1
Lactor_source_x:
    str w0, [sp, #128]
    scvtf s0, w26
    fmadd s0, s0, s10, s12
    fcvtps w0, s0
    mov w1, #167
    cmp w0, w1
    csel w0, w0, w1, lt
    str w0, [sp, #132]
    fcvtms w0, s12
    cmp w0, #0
    csel w0, w0, wzr, gt
    str w0, [sp, #136]
Lactor_y:
    ldr w1, [sp, #136]
    ldr w0, [sp, #132]
    cmp w1, w0
    b.gt Lactor_x_next
    scvtf s0, w1
    fsub s0, s0, s12
    fdiv s0, s0, s10
    fcvtms w0, s0
    cmp w0, w26
    b.hs Lactor_y_next
    ldr w2, [sp, #128]
    madd w0, w0, w25, w2
    ldr x2, [x24, #8]
    cbz x2, Lactor_x_next
    ldr x3, [x24, #24]
    cbz x3, Lactor_legacy_alpha
    ldrb w3, [x3, w0, uxtw]
    cbz w3, Lactor_y_next
    ldrb w0, [x2, w0, uxtw]
    b Lactor_pixel_color
Lactor_legacy_alpha:
    ldrb w0, [x2, w0, uxtw]
    cmp w0, #255
    b.eq Lactor_y_next
Lactor_pixel_color:
    fmov s0, s8
    bl Lpalette_color
    ldr w1, [sp, #136]
    fmov s0, s8
    bl Lput_depth
Lactor_y_next:
    ldr w0, [sp, #136]
    add w0, w0, #1
    str w0, [sp, #136]
    b Lactor_y
Lactor_x_next:
    add w28, w28, #1
    b Lactor_x
Lactor_next:
    add x21, x21, #80
    add w23, w23, #1
    b Lactor
Lactors_done:
    ldp d12, d13, [sp, #112]
    ldp d10, d11, [sp, #96]
    ldp d8, d9, [sp, #80]
    ldp x27, x28, [sp, #64]
    ldp x25, x26, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #144
    ret

// x0 actor -> x0 borrowed patch descriptor, C_START mirror flag. Eight Doom
// view rotations are selected from actor angle. Supports paired A2A8/A3A7/A4A6
// lumps and individual six-character names; missing views fall back to the
// actor's supplied name. atan2f is a system primitive, not a game backend.
// Stack64; preserves all Apple ABI nonvolatile state.
Lactor_patch:
    stp x29, x30, [sp, #-64]!
    stp x21, x22, [sp, #16]
    mov x21, x0
    str wzr, [x19, #C_START]
    ldr x1, [x21, #48]
    str x1, [sp, #32]
    ldrb w1, [x21, #53]
    cmp w1, #49
    b.lo Lactor_patch_fallback
    cmp w1, #56
    b.hi Lactor_patch_fallback
    ldr s0, [x19, #C_PY]
    ldr s1, [x21, #4]
    fsub s0, s0, s1
    ldr s1, [x19, #C_PX]
    ldr s2, [x21]
    fsub s1, s1, s2
    bl _atan2f
    ldr s1, [x21, #12]
    fsub s0, s0, s1
    mov w0, #0xf983
    movk w0, #0x3fa2, lsl #16 // 4/pi
    fmov s1, w0
    fmul s0, s0, s1
    fcvtns w22, s0
    and w22, w22, #7
    add w22, w22, #1
    add w0, w22, #48
    strb w0, [sp, #37]
    strh wzr, [sp, #38]
    add x0, sp, #32
    bl _doom_patch
    cbnz x0, Lactor_patch_return
    cmp w22, #1
    b.eq Lactor_patch_fallback
    cmp w22, #5
    b.eq Lactor_patch_fallback
    cmp w22, #5
    b.lo Lactor_pair_ready
    mov w0, #10
    sub w22, w0, w22
    mov w0, #1
    str w0, [x19, #C_START]
Lactor_pair_ready:
    add w0, w22, #48
    strb w0, [sp, #37]
    ldrb w0, [sp, #36]
    strb w0, [sp, #38]
    mov w0, #58
    sub w0, w0, w22
    strb w0, [sp, #39]
    add x0, sp, #32
    bl _doom_patch
    cbnz x0, Lactor_patch_return
Lactor_patch_fallback:
    str wzr, [x19, #C_START]
    add x0, x21, #48
    bl _doom_patch
Lactor_patch_return:
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// Draw an unscaled masked UI patch. x0 descriptor,w1 left,w2 top,w3 bottom clip
// (167 scene or 199 HUD). Fullbright palette, no depth. Stack 96 bytes.
Lui_patch:
    cbz x0, Lui_patch_return
    stp x29, x30, [sp, #-96]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    mov x21, x0
    mov w22, w1
    mov w23, w2
    mov w24, w3
    ldr x1, [x21, #24]
    str x1, [sp, #80]
    ldp w25, w26, [x21]
    cmp w25, #4096
    b.hi Lui_patch_done
    cmp w26, #4096
    b.hi Lui_patch_done
    ldr x21, [x21, #8]
    cbz x21, Lui_patch_done
    mov w27, #0
Lui_y:
    cmp w27, w26
    b.hs Lui_patch_done
    add w0, w23, w27
    cmp w0, w24
    b.gt Lui_patch_done
    tbnz w0, #31, Lui_next_y
    mov w28, #0
Lui_x:
    cmp w28, w25
    b.hs Lui_next_y
    add w0, w22, w28
    cmp w0, #320
    b.hs Lui_next_x
    madd w0, w27, w25, w28
    ldr x1, [sp, #80]
    cbz x1, Lui_legacy_alpha
    ldrb w2, [x1, w0, uxtw]
    cbz w2, Lui_next_x
    ldrb w0, [x21, w0, uxtw]
    b Lui_pixel_color
Lui_legacy_alpha:
    ldrb w0, [x21, w0, uxtw]
    cmp w0, #255
    b.eq Lui_next_x
Lui_pixel_color:
    // Preserve data-defined RGB without world lighting.
    adrp x1, _doom_palette@PAGE
    ldr x1, [x1, _doom_palette@PAGEOFF]
    cbz x1, Lui_gray
    add w2, w0, w0, lsl #1
    add x1, x1, w2, uxtw
    ldrb w2, [x1]
    ldrb w3, [x1, #1]
    ldrb w0, [x1, #2]
    orr w0, w0, w3, lsl #8
    orr w0, w0, w2, lsl #16
    b Lui_alpha
Lui_gray:
    orr w0, w0, w0, lsl #8
    orr w0, w0, w0, lsl #16
Lui_alpha:
    orr w0, w0, #0xff000000
    add w1, w23, w27
    mov w2, #320
    mul w1, w1, w2
    add w1, w1, w22
    add w1, w1, w28
    ldr x2, [x19, #C_FB]
    str w0, [x2, w1, uxtw #2]
Lui_next_x:
    add w28, w28, #1
    b Lui_x
Lui_next_y:
    add w27, w27, #1
    b Lui_y
Lui_patch_done:
    ldp x27, x28, [sp, #64]
    ldp x25, x26, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #96
Lui_patch_return:
    ret

Ldraw_weapon:
    stp x29, x30, [sp, #-48]!
    stp x21, x22, [sp, #16]
    adrp x21, _doom_player@PAGE
    add x21, x21, _doom_player@PAGEOFF
    ldr w0, [x21, #40]
    cmp w0, #1
    b.lo Lweapon_done
    cmp w0, #7
    b.hi Lweapon_done
    sub w0, w0, #1
    adrp x1, _r_weapon_names@PAGE
    add x1, x1, _r_weapon_names@PAGEOFF
    add x0, x1, x0, lsl #3
    ldr x1, [x0]
    str x1, [sp, #32]
    ldr w1, [x21, #68]
    cmp w1, #0
    b.le Lweapon_name_ready
    mov w1, #66
    strb w1, [sp, #36]
Lweapon_name_ready:
    add x0, sp, #32
    bl _doom_patch
    cbz x0, Lweapon_done
    ldr w1, [x0]
    lsr w1, w1, #1
    mov w2, #160
    sub w1, w2, w1
    ldr w2, [x0, #4]
    mov w3, #168
    sub w2, w3, w2
    mov w3, #167
    bl Lui_patch
Lweapon_done:
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// Damage feedback: blend scene pixels toward red while world flash is active.
// No input/return, no stack/calls. Only the 53760 scene pixels are changed.
Ldamage_tint:
    adrp x0, _doom_player@PAGE
    add x0, x0, _doom_player@PAGEOFF
    ldr w0, [x0, #76]
    cmp w0, #0
    b.le Ldamage_done
    ldr x0, [x19, #C_FB]
    mov w1, #53760
Ldamage_pixel:
    ldr w2, [x0]
    ubfx w3, w2, #16, #8
    ubfx w4, w2, #8, #8
    and w5, w2, #255
    add w3, w3, w3, lsl #1
    add w3, w3, #255
    lsr w3, w3, #2
    add w4, w4, w4, lsl #1
    lsr w4, w4, #2
    add w5, w5, w5, lsl #1
    lsr w5, w5, #2
    orr w2, w5, w4, lsl #8
    orr w2, w2, w3, lsl #16
    orr w2, w2, #0xff000000
    str w2, [x0], #4
    subs w1, w1, #1
    b.ne Ldamage_pixel
Ldamage_done:
    ret

Ldraw_hud:
    stp x29, x30, [sp, #-48]!
    stp x21, x22, [sp, #16]
    adrp x0, _r_status_name@PAGE
    add x0, x0, _r_status_name@PAGEOFF
    bl _doom_patch
    mov w1, #0
    mov w2, #168
    mov w3, #199
    bl Lui_patch
    adrp x21, _doom_player@PAGE
    add x21, x21, _doom_player@PAGEOFF
    ldr w0, [x21, #16]
    mov w1, #90
    mov w2, #171
    bl Lui_number
    ldr w0, [x21, #20]
    mov w1, #221
    mov w2, #171
    bl Lui_number
    ldr w0, [x21, #40]
    cmp w0, #3
    b.eq Lammo_shells
    cmp w0, #5
    b.eq Lammo_rockets
    cmp w0, #6
    b.hs Lammo_cells
    ldr w0, [x21, #24]
    b Lammo_ready
Lammo_shells:
    ldr w0, [x21, #28]
    b Lammo_ready
Lammo_rockets:
    ldr w0, [x21, #32]
    b Lammo_ready
Lammo_cells:
    ldr w0, [x21, #36]
Lammo_ready:
    mov w1, #42
    mov w2, #171
    bl Lui_number
    adrp x0, _r_face_name@PAGE
    add x0, x0, _r_face_name@PAGEOFF
    ldr x0, [x0]
    str x0, [sp, #32]
    ldr w0, [x21, #16]
    mov w1, #100
    sub w0, w1, w0
    cmp w0, #0
    csel w0, w0, wzr, gt
    mov w1, #20
    udiv w0, w0, w1
    mov w1, #4
    cmp w0, w1
    csel w0, w0, w1, lo
    add w0, w0, #48
    strb w0, [sp, #37]
    add x0, sp, #32
    bl _doom_patch
    mov w1, #143
    mov w2, #168
    mov w3, #199
    bl Lui_patch
    mov w22, #0
Lhud_key:
    ldr w0, [x21, #44]
    lsr w0, w0, w22
    tbz w0, #0, Lhud_key_next
    adrp x0, _r_key_name@PAGE
    add x0, x0, _r_key_name@PAGEOFF
    ldr x0, [x0]
    str x0, [sp, #32]
    add w0, w22, #48
    strb w0, [sp, #38]
    add x0, sp, #32
    bl _doom_patch
    mov w1, #239
    mov w2, #10
    madd w2, w22, w2, wzr
    add w2, w2, #171
    mov w3, #199
    bl Lui_patch
Lhud_key_next:
    add w22, w22, #1
    cmp w22, #3
    b.lo Lhud_key
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// w0 nonnegative number,w1 right coordinate,w2 top. Data-defined status digits.
// A bounded 3-digit decimal also has a readable fallback font. Stack 80 bytes.
Lui_number:
    stp x29, x30, [sp, #-80]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    mov w21, w0
    cmp w21, #0
    csel w21, w21, wzr, gt
    mov w0, #999
    cmp w21, w0
    csel w21, w21, w0, lt
    mov w22, w1
    mov w23, w2
    adrp x0, _r_digit_name@PAGE
    add x0, x0, _r_digit_name@PAGEOFF
    ldr x0, [x0]
    str x0, [sp, #48]
Lnumber_digit:
    mov w0, #10
    udiv w24, w21, w0
    msub w0, w24, w0, w21
    add w0, w0, #48
    strb w0, [sp, #54]
    add x0, sp, #48
    bl _doom_patch
    cbz x0, Lnumber_fallback
    ldr w1, [x0]
    sub w22, w22, w1
    mov w1, w22
    mov w2, w23
    mov w3, #199
    bl Lui_patch
    b Lnumber_next
Lnumber_fallback:
    ldrb w0, [sp, #54]
    strb w0, [sp, #64]
    strb wzr, [sp, #65]
    sub w22, w22, #12
    add x0, sp, #64
    mov w1, w22
    mov w2, w23
    mov w3, #2
    mov w4, #0xffff
    movk w4, #0xfff0, lsl #16
    bl Ltext
Lnumber_next:
    mov w21, w24
    cbnz w21, Lnumber_digit
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

.globl _doom_render_menu
// x0 framebuffer,w1 selection0..4. Draws bounded readable keyboard menu on the
// existing frame. Preserves Apple ABI; stack 80 bytes plus text helper.
_doom_render_menu:
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    adrp x19, _r_context@PAGE
    add x19, x19, _r_context@PAGEOFF
    str x0, [x19, #C_FB]
    cbz x0, Lmenu_done
    mov w20, w1
    // Dim the view with an opaque, reversible-on-next-frame checker.
    mov w1, #0
Ldim:
    ldr w2, [x0, w1, uxtw #2]
    lsr w2, w2, #1
    mov w3, #0x7f7f
    movk w3, #0x007f, lsl #16
    and w2, w2, w3
    orr w2, w2, #0xff000000
    str w2, [x0, w1, uxtw #2]
    add w1, w1, #1
    mov w3, #53760
    cmp w1, w3
    b.lo Ldim
    adrp x0, _r_menu_title@PAGE
    add x0, x0, _r_menu_title@PAGEOFF
    mov w1, #106
    mov w2, #18
    mov w3, #2
    mov w4, #0xe0e0
    movk w4, #0xffe0, lsl #16
    bl Ltext
    mov w21, #0
Lmenu_item:
    adrp x0, _r_menu_items@PAGE
    add x0, x0, _r_menu_items@PAGEOFF
    mov w1, #16
    umaddl x0, w21, w1, x0
    mov w1, #108
    mov w2, #18
    madd w2, w21, w2, wzr
    add w2, w2, #44
    mov w3, #2
    mov w4, #0xd0d0
    movk w4, #0xffd0, lsl #16
    cmp w21, w20
    b.ne Lmenu_text
    mov w4, #0xb0ff
    movk w4, #0xffff, lsl #16
Lmenu_text:
    bl Ltext
    cmp w21, w20
    b.ne Lmenu_next
    adrp x0, _r_arrow@PAGE
    add x0, x0, _r_arrow@PAGEOFF
    mov w1, #88
    mov w2, #18
    madd w2, w21, w2, wzr
    add w2, w2, #44
    mov w3, #2
    mov w4, #0xb0ff
    movk w4, #0xffff, lsl #16
    bl Ltext
Lmenu_next:
    add w21, w21, #1
    cmp w21, #5
    b.lo Lmenu_item
    adrp x0, _r_controls_move@PAGE
    add x0, x0, _r_controls_move@PAGEOFF
    mov w1, #80
    mov w2, #140
    mov w3, #1
    mov w4, #0xd0d0
    movk w4, #0xffd0, lsl #16
    bl Ltext
    adrp x0, _r_controls_fire@PAGE
    add x0, x0, _r_controls_fire@PAGEOFF
    mov w1, #80
    mov w2, #149
    mov w3, #1
    mov w4, #0xd0d0
    movk w4, #0xffd0, lsl #16
    bl Ltext
    adrp x0, _r_controls_save@PAGE
    add x0, x0, _r_controls_save@PAGEOFF
    mov w1, #80
    mov w2, #158
    mov w3, #1
    mov w4, #0xd0d0
    movk w4, #0xffd0, lsl #16
    bl Ltext
Lmenu_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// x0 NUL ASCII text (max64),w1 x,w2 y,w3 scale1..2,w4 RGBA.
// Hand-entered 5x7 font for digits and uppercase ASCII. No calls or stack.
// Every output coordinate is checked; unsupported characters advance as spaces.
Ltext:
    mov x5, x0
    mov w6, w1
    mov w7, w2
    mov w8, w3
    cmp w8, #1
    b.lo Ltext_done
    cmp w8, #2
    b.hi Ltext_done
    mov w9, #0
Ltext_char:
    cmp w9, #64
    b.hs Ltext_done
    ldrb w0, [x5], #1
    cbz w0, Ltext_done
    cmp w0, #48
    b.lo Ltext_space
    cmp w0, #57
    b.ls Ltext_digit
    cmp w0, #65
    b.lo Ltext_space
    cmp w0, #90
    b.hi Ltext_space
    sub w0, w0, #55
    b Ltext_glyph
Ltext_digit:
    sub w0, w0, #48
Ltext_glyph:
    adrp x10, _r_font@PAGE
    add x10, x10, _r_font@PAGEOFF
    mov w1, #7
    umaddl x10, w0, w1, x10
    mov w11, #0
Ltext_row:
    ldrb w12, [x10, w11, uxtw]
    mov w13, #0
Ltext_column:
    mov w0, #4
    sub w0, w0, w13
    lsr w0, w12, w0
    tbz w0, #0, Ltext_column_next
    mov w14, #0
Ltext_scale_y:
    madd w15, w11, w8, w7
    add w15, w15, w14
    cmp w15, #200
    b.hs Ltext_scale_y_next
    mov w16, #0
Ltext_scale_x:
    madd w17, w13, w8, w6
    add w17, w17, w16
    cmp w17, #320
    b.hs Ltext_scale_x_next
    mov w0, #320
    madd w0, w15, w0, w17
    ldr x1, [x19, #C_FB]
    str w4, [x1, w0, uxtw #2]
Ltext_scale_x_next:
    add w16, w16, #1
    cmp w16, w8
    b.lo Ltext_scale_x
Ltext_scale_y_next:
    add w14, w14, #1
    cmp w14, w8
    b.lo Ltext_scale_y
Ltext_column_next:
    add w13, w13, #1
    cmp w13, #5
    b.lo Ltext_column
    add w11, w11, #1
    cmp w11, #7
    b.lo Ltext_row
Ltext_space:
    mov w0, #6
    madd w6, w0, w8, w6
    add w9, w9, #1
    b Ltext_char
Ltext_done:
    ret

.globl _doom_render_free
// Static bounded storage has no allocator lifetime. Invalidate resource pointers
// before the resource module frees its allocations. No stack or changed state
// outside renderer-owned globals.
_doom_render_free:
    adrp x0, _r_cached_lines@PAGE
    str xzr, [x0, _r_cached_lines@PAGEOFF]
    adrp x0, _r_cached_count@PAGE
    mov w1, #-1
    str w1, [x0, _r_cached_count@PAGEOFF]
    ret

.section __TEXT,__const
_r_status_name: .asciz "STBAR"
_r_face_name: .asciz "STFST00"
_r_key_name: .asciz "STKEYS0"
_r_digit_name: .asciz "STTNUM0"
_r_weapon_names:
    .ascii "PUNGA0\0\0PISGA0\0\0SHTGA0\0\0CHGGA0\0\0MISGA0\0\0PLSGA0\0\0BFGGA0\0\0"
_r_menu_title: .asciz "FREEDOOM"
_r_arrow: .asciz "X"
_r_controls_move: .asciz "WASD MOVE  MOUSE TURN"
_r_controls_fire: .asciz "CTRL FIRE  E USE  ESC MENU"
_r_controls_save: .asciz "F5 SAVE  F9 LOAD  ENTER CHOOSE"
_r_menu_items:
    .asciz "RESUME"
    .space 9
    .asciz "NEW GAME"
    .space 7
    .asciz "SAVE"
    .space 11
    .asciz "LOAD"
    .space 11
    .asciz "QUIT"
    .space 11
// Row bitmaps: 0..9,A..Z. Five low bits in each byte, leftmost at bit4.
_r_font:
    .byte 14,17,19,21,25,17,14
    .byte 4,12,4,4,4,4,14
    .byte 14,17,1,2,4,8,31
    .byte 30,1,1,14,1,1,30
    .byte 2,6,10,18,31,2,2
    .byte 31,16,16,30,1,1,30
    .byte 14,16,16,30,17,17,14
    .byte 31,1,2,4,8,8,8
    .byte 14,17,17,14,17,17,14
    .byte 14,17,17,15,1,1,14
    .byte 14,17,17,31,17,17,17
    .byte 30,17,17,30,17,17,30
    .byte 14,17,16,16,16,17,14
    .byte 30,17,17,17,17,17,30
    .byte 31,16,16,30,16,16,31
    .byte 31,16,16,30,16,16,16
    .byte 14,17,16,23,17,17,15
    .byte 17,17,17,31,17,17,17
    .byte 14,4,4,4,4,4,14
    .byte 7,2,2,2,2,18,12
    .byte 17,18,20,24,20,18,17
    .byte 16,16,16,16,16,16,31
    .byte 17,27,21,21,17,17,17
    .byte 17,25,21,19,17,17,17
    .byte 14,17,17,17,17,17,14
    .byte 30,17,17,30,16,16,16
    .byte 14,17,17,17,21,18,13
    .byte 30,17,17,30,20,18,17
    .byte 15,16,16,14,1,1,30
    .byte 31,4,4,4,4,4,4
    .byte 17,17,17,17,17,17,14
    .byte 17,17,17,17,17,10,4
    .byte 17,17,17,21,21,27,17
    .byte 17,17,10,4,10,17,17
    .byte 17,17,10,4,4,4,4
    .byte 31,1,2,4,8,16,31

.zerofill __DATA,__bss,_r_context,128,4
.zerofill __DATA,__bss,_r_cached_lines,8,3
.zerofill __DATA,__bss,_r_cached_count,4,2
.zerofill __DATA,__bss,_r_epoch,4,2
.zerofill __DATA,__bss,_r_sky,8,3
.zerofill __DATA,__bss,_r_depth,215040,4
.zerofill __DATA,__bss,_r_heads,131072,4
.zerofill __DATA,__bss,_r_sectors,1048576,4
.zerofill __DATA,__bss,_r_edges,5242880,4
