// SPDX-License-Identifier: GPL-2.0-or-later
// Handwritten AArch64 world simulation, copyright (c) 2026 Asm contributors.
// Doom record formats and behavior reference: id Software linuxdoom-1.10,
// p_map.c, p_mobj.c, p_spec.c and info.c (1993-1996 id Software).
// Additional behavioral/data reference: Chocolate Doom commit
// a2dfd51fcc00d272dc8a17a97ccd6683333ff4ea, observed2026-11-05.
// Copyright (C)1993-1996 Id Software; (C)2005-2014 Simon Howard.
// https://github.com/chocolate-doom/chocolate-doom (GPL-2.0-or-later).
// This is a new native implementation, not compiler output. Compatibility
// limits are recorded in the package evidence; no demo determinism is implied.
// All pointers are borrowed map data or statically owned arrays. The game is
// single-threaded. Every external call uses the Apple arm64 ABI and SP % 16=0.

.equ MAX_SECTORS, 32768
.equ MAX_ACTORS, 4096
.equ ACTOR_SIZE, 80
.equ MOVER_SIZE, 24
.equ PLAYER_HEIGHT, 56
.equ PICKUP_BELOW_REACH, 8
.equ SAVE_CAP, 4194304

.macro ADDR reg, name
 adrp \reg, \name@PAGE
 add \reg, \reg, \name@PAGEOFF
.endm
.macro PTR reg, name
 adrp \reg, \name@PAGE
 ldr \reg, [\reg, \name@PAGEOFF]
.endm
.macro COUNT reg, name
 adrp x17, \name@PAGE
 ldr \reg, [x17, \name@PAGEOFF]
.endm
.macro FUNC name
 .p2align 2
 .globl _\name
_\name:
.endm

.text
// Borrowed NUL map name. Leaf; valid until next world initialization.
FUNC doom_world_map
 ADDR x0,_world_map
 ret

// x0:NUL map name ->w0 0/-1. Stack96,x19-x24 preserved.
// map_load validates transactionally. Fixed arrays avoid later allocation failure.
FUNC doom_world_init
 stp x29,x30,[sp,#-96]!
 mov x29,sp
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 mov x19,x0
 bl _doom_map_load
 cbnz w0,Linit_fail
 ADDR x20,_world_map
 ldr w8,[x19]
 str w8,[x20]
 ldrb w8,[x19,#4]
 strb w8,[x20,#4]
 strb wzr,[x20,#5]
 ADDR x0,_world_momentum
 mov x1,#8
 bl _bzero
 ADDR x0,_world_combat_state
 mov x1,#28
 bl _bzero
 ADDR x0,_doom_player
 mov x1,#128
 bl _bzero
 ADDR x0,_doom_actors
 mov x1,#(MAX_ACTORS*ACTOR_SIZE)
 bl _bzero
 ADDR x0,_world_movers
 mov x1,#(MAX_SECTORS*MOVER_SIZE)
 bl _bzero
 ADDR x0,_world_seen_secrets
 mov x1,#MAX_SECTORS
 bl _bzero
 ADDR x20,_doom_player
 mov w8,#100
 str w8,[x20,#16]
 mov w8,#50
 str w8,[x20,#24]
 mov w8,#2
 str w8,[x20,#40]
 mov w8,#6
 str w8,[x20,#72]
 mov w16,#41
 scvtf s0,w16
 str s0,[x20,#52]
 ADDR x8,_doom_actor_count
 str wzr,[x8]
 ADDR x8,_doom_tic
 str wzr,[x8]
 ADDR x8,_doom_level_complete
 str wzr,[x8]
 ADDR x8,_doom_paused
 str wzr,[x8]
 ADDR x8,_world_buttons
 str wzr,[x8]
 ADDR x8,_world_vertical
 str wzr,[x8]
 ADDR x8,_world_suit
 str wzr,[x8]
 ADDR x8,_world_invul
 str wzr,[x8]
 PTR x21,_doom_sectors
 COUNT w22,_doom_sector_count
 ADDR x23,_world_floors
 ADDR x24,_world_ceilings
 ADDR x9,_world_lights
 mov w10,#0
Linit_sector:
 cmp w10,w22
 b.hs Linit_things
 ldrsh w11,[x21]
 scvtf s0,w11
 str s0,[x23,x10,lsl #2]
 ldrsh w11,[x21,#2]
 scvtf s0,w11
 str s0,[x24,x10,lsl #2]
 ldrsh w11,[x21,#20]
 str w11,[x9,x10,lsl #2]
 add x21,x21,#26
 add w10,w10,#1
 b Linit_sector
Linit_things:
 bl Lmetadata_init
 PTR x21,_doom_things
 COUNT w22,_doom_thing_count
 mov w23,#0
 mov w24,#0
Linit_thing:
 cmp w23,w22
 b.hs Linit_done
 ldrh w8,[x21,#6]
 cmp w8,#1
 b.ne Linit_other
 cbnz w24,Linit_next
 ldrsh w8,[x21]
 scvtf s0,w8
 str s0,[x20]
 ldrsh w8,[x21,#2]
 scvtf s1,w8
 str s1,[x20,#4]
 bl _doom_point_sector
 str w0,[x20,#48]
 tbnz w0,#31,Linit_next
 ADDR x8,_world_floors
 ldr s0,[x8,w0,uxtw #2]
 str s0,[x20,#8]
 ldrsh w8,[x21,#4]
 scvtf s0,w8
 ADDR x8,_deg_to_rad
 ldr s1,[x8]
 fmul s0,s0,s1
 str s0,[x20,#12]
 mov w24,#1
 b Linit_next
Linit_other:
 // Cooperative and deathmatch start markers never become world actors.
 cmp w8,#2
 b.eq Linit_next
 cmp w8,#3
 b.eq Linit_next
 cmp w8,#4
 b.eq Linit_next
 cmp w8,#11
 b.eq Linit_next
 // Multiplayer-only flag16 is excluded. Skill flags1/2/4 select actors.
 ldrh w9,[x21,#8]
 tbnz w9,#4,Linit_next
 COUNT w10,_doom_skill
 cmp w10,#2
 mov w11,#1
 b.ls Linit_skill
 cmp w10,#4
 mov w11,#4
 mov w12,#2
 csel w11,w11,w12,hs
Linit_skill:
 tst w9,w11
 b.eq Linit_next
 mov w0,w8
 bl Ldefinition
 mov x1,x0
 mov x0,x21
 bl Lspawn
Linit_next:
 add x21,x21,#10
 add w23,w23,#1
 b Linit_thing
Linit_done:
 // A validated map without a player start uses its first vertex deliberately.
 cbnz w24,Linit_ok
 PTR x8,_doom_vertices
 ldrsh w9,[x8]
 scvtf s0,w9
 str s0,[x20]
 ldrsh w9,[x8,#2]
 scvtf s1,w9
 str s1,[x20,#4]
 bl _doom_point_sector
 str w0,[x20,#48]
 tbnz w0,#31,Linit_ok
 ADDR x8,_world_floors
 ldr s0,[x8,w0,uxtw #2]
 str s0,[x20,#8]
Linit_ok:
 ldr w0,[x20,#48]
 tbnz w0,#31,Linit_floor_default
 ADDR x8,_world_floors
 ldr s0,[x8,w0,uxtw #2]
 ADDR x8,_world_player_floor
 str s0,[x8]
 b Linit_success
Linit_floor_default:
 ADDR x8,_world_player_floor
 str wzr,[x8]
Linit_success:
 mov w0,#0
 b Linit_return
Linit_fail:
 mov w0,#-1
Linit_return:
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// Dynamic materials are copied from immutable WAD records once per map.
// Sector meta16:floor name8,special4,reserved4; side meta32:names24,x/yfloat.
// Line meta8:used4,button countdown4. All arrays have MAX_SECTORS entries.
Lmetadata_init:
 PTR x8,_doom_sectors
 COUNT w9,_doom_sector_count
 ADDR x10,_world_sector_meta
Lmeta_sector:
 cbz w9,Lmeta_sides_start
 ldr x11,[x8,#4]
 str x11,[x10]
 ldrh w11,[x8,#22]
 str w11,[x10,#8]
 str wzr,[x10,#12]
 add x8,x8,#26
 add x10,x10,#16
 sub w9,w9,#1
 b Lmeta_sector
Lmeta_sides_start:
 PTR x8,_doom_sides
 COUNT w9,_doom_side_count
 ADDR x10,_world_side_meta
Lmeta_side:
 cbz w9,Lmeta_lines_start
 ldr x11,[x8,#4]
 str x11,[x10]
 ldr x11,[x8,#12]
 str x11,[x10,#8]
 ldr x11,[x8,#20]
 str x11,[x10,#16]
 ldrsh w11,[x8]
 scvtf s0,w11
 str s0,[x10,#24]
 ldrsh w11,[x8,#2]
 scvtf s0,w11
 str s0,[x10,#28]
 add x8,x8,#30
 add x10,x10,#32
 sub w9,w9,#1
 b Lmeta_side
Lmeta_lines_start:
 ADDR x8,_world_line_meta
 ADDR x9,_world_side_scroll
 mov w10,#MAX_SECTORS
Lmeta_clear_lines:
 str xzr,[x8],#8
 strb wzr,[x9],#1
 subs w10,w10,#1
 b.ne Lmeta_clear_lines
 PTR x8,_doom_lines
 COUNT w9,_doom_line_count
 ADDR x10,_world_side_scroll
Lmeta_scroll:
 cbz w9,Lmeta_done
 ldrh w11,[x8,#6]
 cmp w11,#48
 b.ne Lmeta_scroll_next
 ldrh w11,[x8,#10]
 mov w12,#65535
 cmp w11,w12
 b.eq Lmeta_scroll_next
 mov w12,#1
 strb w12,[x10,w11,uxtw]
Lmeta_scroll_next:
 add x8,x8,#14
 sub w9,w9,#1
 b Lmeta_scroll
Lmeta_done:
 ret

// w0 side,w1 upper0/lower1/middle2 -> x0 borrowed8-byte dynamic texture name.
FUNC doom_world_side_texture
 mov w0,w0 // The integer ABI does not specify the upper32 argument bits.
 COUNT w8,_doom_side_count
 cmp w0,w8
 b.hs Lmaterial_invalid
 cmp w1,#2
 b.hi Lmaterial_invalid
 ADDR x8,_world_side_meta
 add x0,x8,x0,lsl #5
 add x0,x0,w1,uxtw #3
 ret
// w0 sector -> x0 borrowed8-byte dynamic flat name.
FUNC doom_world_floor_flat
 COUNT w8,_doom_sector_count
 cmp w0,w8
 b.hs Lmaterial_invalid
 ADDR x8,_world_sector_meta
 add x0,x8,w0,uxtw #4
 ret
Lmaterial_invalid:
 mov x0,#0
 ret
// w0 side -> s0 total X offset, including raw offset and type48 scrolling.
FUNC doom_world_side_offset
 mov w0,w0
 COUNT w8,_doom_side_count
 cmp w0,w8
 b.hs Loffset_invalid
 ADDR x8,_world_side_meta
 add x8,x8,x0,lsl #5
 ldr s0,[x8,#24]
 ADDR x8,_world_side_scroll
 ldrb w8,[x8,w0,uxtw]
 cbz w8,Loffset_return
 COUNT w8,_doom_tic
 scvtf s1,w8
 fadd s0,s0,s1
Loffset_return:
 ret
Loffset_invalid:
 fmov s0,wzr
 ret

// s0/s1 finite coordinates. w0 sector/-1. Leaf; stack0; destroys x0-x17,v0-v7.
// BSP descent bounded by node_count+1, including malformed-cycle defense.
FUNC doom_point_sector
 fcmp s0,s0
 b.vs Lsector_bad
 fcmp s1,s1
 b.vs Lsector_bad
 COUNT w8,_doom_node_count
 cbz w8,Lsector_zero
 sub w9,w8,#1
 add w8,w8,#1
 PTR x10,_doom_nodes
Lsector_node:
 subs w8,w8,#1
 b.eq Lsector_bad
 mov w11,#28
 madd x11,x9,x11,x10
 ldrsh w12,[x11]
 scvtf s2,w12
 ldrsh w12,[x11,#2]
 scvtf s3,w12
 ldrsh w12,[x11,#4]
 scvtf s4,w12
 ldrsh w12,[x11,#6]
 scvtf s5,w12
 fsub s2,s0,s2
 fsub s3,s1,s3
 fmul s2,s2,s5
 fmsub s2,s3,s4,s2
 fcmp s2,#0.0
 cset w12,lt
 add x11,x11,w12,uxtw #1
 ldrh w9,[x11,#24]
 tbnz w9,#15,Lsector_leaf
 b Lsector_node
Lsector_zero:
 mov w9,#0x8000
Lsector_leaf:
 and w9,w9,#0x7fff
 COUNT w8,_doom_subsector_count
 cmp w9,w8
 b.hs Lsector_bad
 PTR x10,_doom_subsectors
 add x10,x10,w9,uxtw #2
 ldrh w9,[x10,#2]
 COUNT w8,_doom_seg_count
 cmp w9,w8
 b.hs Lsector_bad
 PTR x10,_doom_segs
 mov w11,#12
 madd x10,x9,x11,x10
 ldrh w9,[x10,#6]
 ldrh w12,[x10,#8]
 COUNT w8,_doom_line_count
 cmp w9,w8
 b.hs Lsector_bad
 PTR x10,_doom_lines
 mov w11,#14
 madd x10,x9,x11,x10
 and w12,w12,#1
 add x10,x10,w12,uxtw #1
 ldrh w9,[x10,#10]
 COUNT w8,_doom_side_count
 cmp w9,w8
 b.hs Lsector_bad
 PTR x10,_doom_sides
 mov w11,#30
 madd x10,x9,x11,x10
 ldrh w0,[x10,#28]
 ret
Lsector_bad:
 mov w0,#-1
 ret

// w0 type -> x0 definition, fallback decoration. Leaf; only x0,x8,x9 changed.
Ldefinition:
 ADDR x8,_definitions
Ldef_loop:
 ldr w9,[x8]
 cbz w9,Ldef_found
 cmp w9,w0
 b.eq Ldef_found
 add x8,x8,#40
 b Ldef_loop
Ldef_found:
 mov x0,x8
 ret

// Allocate an actor slot. Reuse only expired projectiles (negative type,
// hidden flag64), preserving teleport destinations and consumed pickup records.
// x0 pointer/0 full,w1 index. Leaf,x8-x12 destroyed; append count bounded4096.
Lallocate_actor:
 ADDR x8,_doom_actors
 COUNT w9,_doom_actor_count
 mov w1,#0
Lallocate_reuse:
 cmp w1,w9
 b.hs Lallocate_append
 ldr w10,[x8,#24]
 cmp w10,#0
 b.ge Lallocate_next
 ldr w10,[x8,#32]
 tbnz w10,#6,Lallocate_found
Lallocate_next:
 add x8,x8,#ACTOR_SIZE
 add w1,w1,#1
 b Lallocate_reuse
Lallocate_append:
 cmp w9,#MAX_ACTORS
 b.hs Lallocate_full
 ADDR x10,_doom_actor_count
 add w9,w9,#1
 str w9,[x10]
Lallocate_found:
 mov x0,x8
 ret
Lallocate_full:
 mov x0,#0
 ret

// x0 deadactor. Doom ammunition/weapon drops are ordinary pickup actors.
// A dropped clip gives5 bullets; a dropped shotgun gives4 shells.
// Stack80,x19,x20 preserved; raw temporary thing is owned stack storage.
Ldrop:
 stp x29,x30,[sp,#-80]!
 stp x19,x20,[sp,#16]
 mov x19,x0
 ldr w8,[x19,#24]
 mov w20,#2007
 cmp w8,#3004
 b.eq Ldrop_make
 cmp w8,#84
 b.eq Ldrop_make
 mov w20,#2001
 cmp w8,#9
 b.eq Ldrop_make
 mov w20,#2002
 cmp w8,#65
 b.ne Ldrop_end
Ldrop_make:
 ldp s0,s1,[x19]
 fcvtzs w8,s0
 fcvtzs w9,s1
 strh w8,[sp,#40]
 strh w9,[sp,#42]
 strh wzr,[sp,#44]
 strh w20,[sp,#46]
 mov w8,#7
 strh w8,[sp,#48]
 mov w0,w20
 bl Ldefinition
 mov x1,x0
 add x0,sp,#40
 bl Lspawn
 cbz x0,Ldrop_end
 mov w8,#1
 str w8,[x0,#76]
Ldrop_end:
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#80
 ret

// x0 raw10-byte thing, x1 definition40 bytes. Appends actor if capacity permits.
// Stack48, preserves x19-x21; all source fields read within fixed record bounds.
Lspawn:
 stp x29,x30,[sp,#-48]!
 stp x19,x20,[sp,#16]
 str x21,[sp,#32]
 mov x19,x0
 mov x20,x1
 bl Lallocate_actor
 mov x21,x0
 cbz x21,Lspawn_return
 mov x1,#ACTOR_SIZE
 bl _bzero
 ldrsh w8,[x19]
 scvtf s0,w8
 str s0,[x21]
 str s0,[x21,#68]
 ldrsh w8,[x19,#2]
 scvtf s1,w8
 str s1,[x21,#4]
 str s1,[x21,#72]
 bl _doom_point_sector
 tbnz w0,#31,Lspawn_floor
 ADDR x8,_world_floors
 ldr s0,[x8,w0,uxtw #2]
 str s0,[x21,#8]
Lspawn_floor:
 ldrsh w8,[x19,#4]
 scvtf s0,w8
 ADDR x8,_deg_to_rad
 ldr s1,[x8]
 fmul s0,s0,s1
 str s0,[x21,#12]
 ldp w8,w9,[x20,#8]
 stp w8,w9,[x21,#16]
 ldrh w8,[x19,#6]
 str w8,[x21,#24]
 ldr w8,[x20,#4]
 str w8,[x21,#28]
 ldr w8,[x20,#16]
 and w9,w8,#127
 str w9,[x21,#32]
 tbz w8,#7,Lspawn_sprite
 tbnz w0,#31,Lspawn_sprite
 ADDR x8,_world_ceilings
 ldr s0,[x8,w0,uxtw #2]
 ldr s1,[x21,#20]
 fsub s0,s0,s1
 str s0,[x21,#8]
Lspawn_sprite:
 ldr x8,[x20,#28]
 str x8,[x21,#48]
 mov w8,#-1
 str w8,[x21,#44]
Lspawn_return:
 mov x0,x21
 ldr x21,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#48
 ret

// s0 x,s1 y,s2 feet,s3 radius,s4 height,w0 actor index(-1 player),w1 monster.
// w0 sector/-1, s0 candidate floor. Stack64; preserves x19,x20,v8-v12 lower64.
// Tests a candidate disk against every line and solid actor. Player momentum
// is bounded by30 per axis; monster chase steps<=16 with their body radii.
Lcan_move:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp d8,d9,[sp,#32]
 stp d10,d11,[sp,#48]
 str d12,[sp,#64]
 stp w0,w1,[sp,#72]
 fmov s8,s0
 fmov s9,s1
 fmov s10,s2
 fmov s11,s3
 fmov s12,s4
 bl _doom_point_sector
 tbnz w0,#31,Lmove_bad
 str w0,[sp,#80]
 ADDR x8,_world_floors
 ldr s6,[x8,w0,uxtw #2]
 str s6,[sp,#84]
 fmov s5,#24.0
 fadd s5,s10,s5
 fcmp s6,s5
 b.gt Lmove_bad
 fmax s6,s6,s10
 ADDR x8,_world_ceilings
 ldr s5,[x8,w0,uxtw #2]
 fsub s5,s5,s6
 fcmp s5,s12
 b.lt Lmove_bad
 PTR x19,_doom_lines
 COUNT w20,_doom_line_count
 mov w14,#0
Lmove_line:
 cmp w14,w20
 b.hs Lmove_actors
 ldrh w8,[x19]
 ldrh w9,[x19,#2]
 PTR x10,_doom_vertices
 add x8,x10,w8,uxtw #2
 add x9,x10,w9,uxtw #2
 ldrsh w10,[x8]
 scvtf s0,w10
 ldrsh w10,[x8,#2]
 scvtf s1,w10
 ldrsh w10,[x9]
 scvtf s2,w10
 ldrsh w10,[x9,#2]
 scvtf s3,w10
 fsub s2,s2,s0
 fsub s3,s3,s1
 fsub s4,s8,s0
 fsub s5,s9,s1
 fmul s6,s2,s2
 fmadd s6,s3,s3,s6
 fcmp s6,#0.0
 b.eq Lmove_line_next
 fmul s7,s4,s2
 fmadd s7,s5,s3,s7
 fdiv s7,s7,s6
 fmov s6,#1.0
 fmin s7,s7,s6
 fmov s6,wzr
 fmax s7,s7,s6
 fmsub s0,s7,s2,s4
 fmsub s1,s7,s3,s5
 fmul s0,s0,s0
 fmadd s0,s1,s1,s0
 fmul s1,s11,s11
 fcmp s0,s1
 b.ge Lmove_line_next
 ldrh w8,[x19,#4]
 tbnz w8,#0,Lmove_bad
 ldr w9,[sp,#76]
 cbz w9,Lmove_notmonster
 tbnz w8,#1,Lmove_bad
Lmove_notmonster:
 ldrh w8,[x19,#10]
 ldrh w9,[x19,#12]
 mov w10,#65535
 cmp w8,w10
 b.eq Lmove_bad
 cmp w9,w10
 b.eq Lmove_bad
 PTR x10,_doom_sides
 mov w11,#30
 madd x8,x8,x11,x10
 madd x9,x9,x11,x10
 ldrh w8,[x8,#28]
 ldrh w9,[x9,#28]
 ADDR x10,_world_floors
 ldr s0,[x10,w8,uxtw #2]
 ldr s1,[x10,w9,uxtw #2]
 fmax s0,s0,s1
 ldr s6,[sp,#84]
 fmax s6,s6,s0
 str s6,[sp,#84]
 fmov s1,#24.0
 fadd s1,s10,s1
 fcmp s0,s1
 b.gt Lmove_bad
 fmax s0,s0,s10
 ADDR x10,_world_ceilings
 ldr s1,[x10,w8,uxtw #2]
 ldr s2,[x10,w9,uxtw #2]
 fmin s1,s1,s2
 fsub s1,s1,s0
 fcmp s1,s12
 b.lt Lmove_bad
Lmove_line_next:
 add x19,x19,#14
 add w14,w14,#1
 b Lmove_line
Lmove_actors:
 ADDR x19,_doom_actors
 COUNT w20,_doom_actor_count
 ldr w14,[sp,#72]
 mov w15,#0
Lmove_actor:
 cmp w15,w20
 b.hs Lmove_good
 cmp w15,w14
 b.eq Lmove_actor_next
 ldr w8,[x19,#32]
 tbnz w8,#6,Lmove_actor_next
 tbz w8,#0,Lmove_actor_next
 ldr s0,[x19,#8]
 ldr s1,[x19,#20]
 fadd s1,s0,s1
 fcmp s10,s1
 b.ge Lmove_actor_next
 fadd s1,s10,s12
 fcmp s0,s1
 b.ge Lmove_actor_next
 ldp s0,s1,[x19]
 fsub s0,s8,s0
 fsub s1,s9,s1
 fmul s0,s0,s0
 fmadd s0,s1,s1,s0
 ldr s1,[x19,#16]
 fadd s1,s1,s11
 fmul s1,s1,s1
 fcmp s0,s1
 b.lt Lmove_bad
Lmove_actor_next:
 add x19,x19,#ACTOR_SIZE
 add w15,w15,#1
 b Lmove_actor
Lmove_good:
 ldr w0,[sp,#80]
 ldr s0,[sp,#84]
 b Lmove_return
Lmove_bad:
 mov w0,#-1
Lmove_return:
 ldp d8,d9,[sp,#32]
 ldp d10,d11,[sp,#48]
 ldr d12,[sp,#64]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret
// Fixed35Hz tick. x0 input32. Stack128; preserves x19-x24,d8-d13.
FUNC doom_world_tick
 stp x29,x30,[sp,#-128]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 stp d12,d13,[sp,#96]
 mov x19,x0
 ADDR x20,_doom_player
 ldr w21,[x19,#12]
 ADDR x8,_world_buttons
 ldr w9,[x8]
 str w21,[x8]
 bic w22,w21,w9
 tbz w22,#3,Ltick_pause
 ADDR x8,_doom_paused
 ldr w9,[x8]
 eor w9,w9,#1
 str w9,[x8]
Ltick_pause:
 COUNT w8,_doom_paused
 cbnz w8,Ltick_end
 ldr w8,[x20,#16]
 cmp w8,#0
 b.gt Ltick_alive
 and w8,w22,#3
 cbz w8,Ltick_end
 ADDR x0,_world_map
 bl _doom_world_init
 b Ltick_end
Ltick_alive:
 ADDR x8,_doom_tic
 ldr w9,[x8]
 add w9,w9,#1
 str w9,[x8]
 ldr w8,[x20,#76]
 subs w8,w8,#1
 csel w8,w8,wzr,gt
 str w8,[x20,#76]
 ldr w8,[x20,#68]
 subs w8,w8,#1
 csel w8,w8,wzr,gt
 str w8,[x20,#68]
 // Select only an owned weapon after the current attack windup.
 COUNT w8,_world_attack_windup
 cbnz w8,Ltick_angle
 ldr w8,[x19,#16]
 cmp w8,#1
 b.lt Ltick_angle
 cmp w8,#7
 b.gt Ltick_angle
 mov w9,#1
 lsl w9,w9,w8
 ldr w10,[x20,#72]
 tst w9,w10
 b.eq Ltick_angle
 cmp w8,#1
 b.ne Ltick_weapon_store
 COUNT w9,_world_saw_owned
 cbz w9,Ltick_weapon_store
 COUNT w9,_world_strength
 cbz w9,Ltick_choose_saw
 COUNT w9,_world_saw_active
 cbz w9,Ltick_choose_saw
 ADDR x9,_world_saw_active
 str wzr,[x9]
 b Ltick_weapon_store
Ltick_choose_saw:
 ADDR x9,_world_saw_active
 mov w10,#1
 str w10,[x9]
Ltick_weapon_store:
 str w8,[x20,#40]
Ltick_angle:
 ldr s0,[x20,#12]
 ldr s1,[x19,#8]
 fcmp s1,s1
 b.vs Ltick_angle_finite
 fmov s2,#1.0
 fmin s1,s1,s2
 fneg s2,s2
 fmax s1,s1,s2
 fadd s0,s0,s1
Ltick_angle_finite:
 ADDR x8,_two_pi
 ldr s1,[x8]
 fcmp s0,s1
 b.lt Ltick_angle_low
 fsub s0,s0,s1
Ltick_angle_low:
 fcmp s0,#0.0
 b.ge Ltick_angle_store
 fadd s0,s0,s1
Ltick_angle_store:
 str s0,[x20,#12]
 bl _cosf
 fmov s8,s0
 ldr s0,[x20,#12]
 bl _sinf
 fmov s9,s0
 ldp s0,s1,[x19]
 fcmp s0,s0
 b.vc Ltick_forward_finite
 fmov s0,wzr
Ltick_forward_finite:
 fcmp s1,s1
 b.vc Ltick_strafe_finite
 fmov s1,wzr
Ltick_strafe_finite:
 fmov s2,#8.0
 fmin s0,s0,s2
 fmin s1,s1,s2
 fneg s2,s2
 fmax s0,s0,s2
 fmax s1,s1,s2
 ADDR x8,_world_momentum
 ldp s10,s11,[x8]
 // Original on-ground thrust: input4 -> command25 ->25*2048/65536.
 ldr s2,[x20,#8]
 ADDR x8,_world_player_floor
 ldr s3,[x8]
 fcmp s2,s3
 b.gt Ltick_momentum_limit
 ADDR x8,_thrust_input_scale
 ldr s2,[x8]
 fmul s0,s0,s2
 fmul s1,s1,s2
 fmul s2,s0,s8
 fmadd s2,s1,s9,s2
 fadd s10,s10,s2
 fmul s2,s0,s9
 fmsub s2,s1,s8,s2
 fadd s11,s11,s2
Ltick_momentum_limit:
 fmov s2,#30.0
 fmin s10,s10,s2
 fmin s11,s11,s2
 fneg s2,s2
 fmax s10,s10,s2
 fmax s11,s11,s2
 ADDR x8,_world_momentum
 stp s10,s11,[x8]
 ldp s12,s13,[x20]
 fadd s0,s12,s10
 fmov s1,s13
 ldr s2,[x20,#8]
 fmov s3,#16.0
 mov w16,#56
 scvtf s4,w16
 mov w0,#-1
 mov w1,#0
 bl Lcan_move
 tbnz w0,#31,Ltick_block_x
 ldr s1,[x20]
 fadd s1,s1,s10
 str s1,[x20]
 str w0,[x20,#48]
 ADDR x8,_world_player_floor
 str s0,[x8]
 ldr s1,[x20,#8]
 fmax s1,s1,s0
 str s1,[x20,#8]
 b Ltick_move_y
Ltick_block_x:
 ADDR x8,_world_momentum
 str wzr,[x8]
 fmov s10,wzr
Ltick_move_y:
 ldr s0,[x20]
 fadd s1,s13,s11
 ldr s2,[x20,#8]
 fmov s3,#16.0
 mov w16,#56
 scvtf s4,w16
 mov w0,#-1
 mov w1,#0
 bl Lcan_move
 tbnz w0,#31,Ltick_block_y
 ldr s1,[x20,#4]
 fadd s1,s1,s11
 str s1,[x20,#4]
 str w0,[x20,#48]
 ADDR x8,_world_player_floor
 str s0,[x8]
 ldr s1,[x20,#8]
 fmax s1,s1,s0
 str s1,[x20,#8]
 b Ltick_cross
Ltick_block_y:
 ADDR x8,_world_momentum
 str wzr,[x8,#4]
 fmov s11,wzr
Ltick_cross:
 fmov s0,s12
 fmov s1,s13
 mov w0,#-1
 bl Lcross_lines
Ltick_no_move:
 bl Lsectors_tick
 mov x0,x19
 bl Lplayer_friction
 // Ground step snap, falling acceleration, and low-ceiling eye height.
 ldr w8,[x20,#48]
 tbnz w8,#31,Ltick_actions
 ADDR x9,_world_player_floor
 ldr s0,[x9]
 ldr s1,[x20,#8]
 fcmp s1,s0
 b.gt Ltick_fall
 str s0,[x20,#8]
 ADDR x9,_world_vertical
 str wzr,[x9]
 b Ltick_sector_damage
Ltick_fall:
 ADDR x9,_world_vertical
 ldr s2,[x9]
 fmov s3,#1.0
 fsub s2,s2,s3
 str s2,[x9]
 fadd s1,s1,s2
 fmax s1,s1,s0
 str s1,[x20,#8]
Ltick_sector_damage:
 ADDR x9,_world_sector_meta
 add x9,x9,w8,uxtw #4
 ldr w10,[x9,#8]
 cmp w10,#9
 b.ne Ltick_hazard
 ADDR x9,_world_seen_secrets
 ldrb w11,[x9,w8,uxtw]
 cbnz w11,Ltick_actions
 mov w11,#1
 strb w11,[x9,w8,uxtw]
 ldr w11,[x20,#64]
 add w11,w11,#1
 str w11,[x20,#64]
 b Ltick_actions
Ltick_hazard:
 COUNT w11,_doom_tic
 tst w11,#31
 b.ne Ltick_actions
 cmp w10,#4
 b.eq Ltick_hurt20
 cmp w10,#16
 b.eq Ltick_hurt20
 cmp w10,#5
 b.eq Ltick_hurt10
 cmp w10,#7
 b.eq Ltick_hurt5
 cmp w10,#11
 b.ne Ltick_actions
 ldr w11,[x20,#16]
 cmp w11,#10
 b.gt Ltick_hurt20
 ADDR x9,_doom_level_complete
 mov w11,#1
 str w11,[x9]
 b Ltick_actions
Ltick_hurt20:
 mov w0,#20
 b Ltick_hurt
Ltick_hurt10:
 mov w0,#10
 b Ltick_hurt
Ltick_hurt5:
 mov w0,#5
Ltick_hurt:
 COUNT w11,_world_suit
 cbnz w11,Ltick_actions
 bl Ldamage_player
Ltick_actions:
 tbz w22,#0,Ltick_fire
 bl Luse
Ltick_fire:
 ADDR x8,_world_attack_windup
 ldr w9,[x8]
 cbz w9,Ltick_fire_input
 sub w9,w9,#1
 str w9,[x8]
 cbnz w9,Ltick_actors
 bl Lfire
 b Ltick_actors
Ltick_fire_input:
 tbz w21,#1,Ltick_actors
 ldr w8,[x20,#68]
 cbnz w8,Ltick_actors
 bl Lbegin_fire
Ltick_actors:
 bl Lactors_tick
 ADDR x8,_world_suit
 ldr w9,[x8]
 subs w9,w9,#1
 csel w9,w9,wzr,gt
 str w9,[x8]
 ADDR x8,_world_invul
 ldr w9,[x8]
 subs w9,w9,#1
 csel w9,w9,wzr,gt
 str w9,[x8]
Ltick_end:
 ldp d12,d13,[sp,#96]
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#128
 ret

// Three-dimensional ray clipping. s0x,s1y,s2dx,s3dy,s4range,s5z,s6slope
// ->s0 nearest blocked distance. Two-sided lines clip against their actual
// dynamic opening at ray height; the movement-only blocking flag is ignored.
// Stack144;x19-x21,d8-d14 preserved; unit horizontal direction required.
Ltrace:
 stp x29,x30,[sp,#-144]!
 stp x19,x20,[sp,#16]
 str x21,[sp,#32]
 stp d8,d9,[sp,#48]
 stp d10,d11,[sp,#64]
 stp d12,d13,[sp,#80]
 str d14,[sp,#96]
 fmov s8,s0
 fmov s9,s1
 fmov s10,s2
 fmov s11,s3
 fmov s12,s4
 fmov s13,s5
 fmov s14,s6
 PTR x19,_doom_lines
 COUNT w20,_doom_line_count
Ltrace_loop:
 cbz w20,Ltrace_done
 mov x0,x19
 fmov s0,s8
 fmov s1,s9
 fmov s2,s10
 fmov s3,s11
 bl Lray_line
 fcmp s0,#0.0
 b.le Ltrace_next
 fcmp s0,s12
 b.gt Ltrace_next
 str s0,[sp,#112]
 ldrh w8,[x19,#10]
 ldrh w9,[x19,#12]
 mov w10,#65535
 cmp w8,w10
 b.eq Ltrace_wall
 cmp w9,w10
 b.eq Ltrace_wall
 PTR x10,_doom_sides
 mov w11,#30
 madd x8,x8,x11,x10
 madd x9,x9,x11,x10
 ldrh w8,[x8,#28]
 ldrh w9,[x9,#28]
 ADDR x10,_world_floors
 ldr s0,[x10,w8,uxtw #2]
 ldr s1,[x10,w9,uxtw #2]
 fmax s0,s0,s1
 ADDR x10,_world_ceilings
 ldr s1,[x10,w8,uxtw #2]
 ldr s2,[x10,w9,uxtw #2]
 fmin s1,s1,s2
 ldr s3,[sp,#112]
 fmadd s3,s3,s14,s13
 fcmp s3,s0
 b.le Ltrace_wall
 fcmp s3,s1
 b.lt Ltrace_next
Ltrace_wall:
 ldr s12,[sp,#112]
Ltrace_next:
 add x19,x19,#14
 sub w20,w20,#1
 b Ltrace_loop
Ltrace_done:
 fmov s0,s12
 ldr d14,[sp,#96]
 ldp d12,d13,[sp,#80]
 ldp d10,d11,[sp,#64]
 ldp d8,d9,[sp,#48]
 ldr x21,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#144
 ret

// w0 damage. Armor absorbs one third. Stack32, preserves x19.
Ldamage_player:
 stp x29,x30,[sp,#-32]!
 str x19,[sp,#16]
 COUNT w8,_world_invul
 cbnz w8,Ldamage_player_done
 ADDR x19,_doom_player
 ldr w8,[x19,#16]
 cmp w8,#0
 b.le Ldamage_player_done
 mov w9,#3
 COUNT w11,_world_armor_type
 cmp w11,#2
 mov w12,#2
 csel w9,w12,w9,eq
 udiv w9,w0,w9
 ldr w10,[x19,#20]
 cmp w9,w10
 csel w9,w9,w10,ls
 sub w10,w10,w9
 str w10,[x19,#20]
 cbnz w10,Ldamage_armor_live
 ADDR x11,_world_armor_type
 str wzr,[x11]
Ldamage_armor_live:
 sub w0,w0,w9
 sub w8,w8,w0
 cmp w8,#0
 csel w8,w8,wzr,gt
 str w8,[x19,#16]
 mov w8,#12
 str w8,[x19,#76]
 mov w0,#1
 ADDR x1,_snd_pain
 bl _doom_sound
Ldamage_player_done:
 ldr x19,[sp,#16]
 ldp x29,x30,[sp],#32
 ret

// x0 actor, w1 damage. Stack32, preserves x19. Kills stay visible as corpses.
Ldamage_actor:
 stp x29,x30,[sp,#-32]!
 str x19,[sp,#16]
 mov x19,x0
 ldr w8,[x19,#28]
 cmp w8,#0
 b.le Ldamage_actor_end
 sub w8,w8,w1
 str w8,[x19,#28]
 cmp w8,#0
 b.gt Ldamage_actor_alive
 ldr w8,[x19,#32]
 tst w8,#32
 b.eq Ldamage_actor_corpse
 ADDR x9,_doom_player
 ldr w10,[x9,#56]
 add w10,w10,#1
 str w10,[x9,#56]
Ldamage_actor_corpse:
 mov w8,#8
 str w8,[x19,#32]
 mov w8,#3
 str w8,[x19,#36]
 mov w8,#72
 strb w8,[x19,#52]
 mov w8,#48
 strb w8,[x19,#53]
 mov w0,#2
 ADDR x1,_snd_death
 bl _doom_sound
 mov x0,x19
 bl Ldrop
 mov x0,x19
 bl Ldeath_begin
 b Ldamage_actor_end
Ldamage_actor_alive:
 // Attacks awaken a monster; source pain chances control interruption.
 ldr w8,[x19,#32]
 tbz w8,#5,Ldamage_actor_end
 str wzr,[x19,#44]
 ldr w0,[x19,#24]
 bl Lmonster_meta
 cbz x0,Ldamage_actor_end
 ldr w8,[x0,#12]
 str w8,[sp,#24]
 bl Lrandom
 and w0,w0,#255
 ldr w8,[sp,#24]
 cmp w0,w8
 b.hs Ldamage_actor_end
 mov w8,#6
 ldr w9,[x19,#24]
 cmp w9,#3001
 b.eq Ldamage_pain4
 cmp w9,#3002
 b.eq Ldamage_pain4
 cmp w9,#58
 b.eq Ldamage_pain4
 cmp w9,#3003
 b.eq Ldamage_pain4
 cmp w9,#3005
 b.ne Ldamage_pain_cyber
 mov w8,#12
 b Ldamage_pain_set
Ldamage_pain_cyber:
 cmp w9,#16
 b.ne Ldamage_pain_set
 mov w8,#10
 b Ldamage_pain_set
Ldamage_pain4:
 mov w8,#4
Ldamage_pain_set:
 str w8,[x19,#60]
 mov w8,#1
 str w8,[x19,#36]
 str wzr,[x19,#40]
 str wzr,[x19,#76]
Ldamage_actor_end:
 ldr x19,[sp,#16]
 ldp x29,x30,[sp],#32
 ret

// Deterministic xorshift32 random. w0 random. Leaf; x8-x10 changed.
Lrandom:
 ADDR x8,_world_rng
 ldr w0,[x8]
 eor w0,w0,w0,lsl #13
 eor w0,w0,w0,lsr #17
 eor w0,w0,w0,lsl #5
 str w0,[x8]
 ret

// Begin an attack. State timings are Doom35Hz weapon transitions: initial
// action windups4/4/3/0/8/0/30, repeat cycles17/14/37/4/20/3/40.
// Fist/saw share ABI weapon1; obtaining a saw selects its4tic action.
// Leaf; x8-x15 changed. Lfire is tail-called for zero-windup attacks.
Lbegin_fire:
 ADDR x8,_doom_player
 ldr w9,[x8,#40]
 sub w10,w9,#1
 ADDR x11,_weapon_cycles
 ldr w12,[x11,w10,uxtw #2]
 ADDR x11,_weapon_windups
 ldr w13,[x11,w10,uxtw #2]
 cmp w9,#1
 b.ne Lbegin_timing
 COUNT w14,_world_saw_active
 cbz w14,Lbegin_timing
 mov w12,#4
 mov w13,#0
Lbegin_timing:
 str w12,[x8,#68]
 ADDR x11,_world_attack_windup
 str w13,[x11]
 cbz w13,Lfire
 ret

// Perform the scheduled action. Uses per-pellet damage/spread, bounded native
// hitscan, or a real projectile. Stack96,x19-x24,d8,d9 preserved.
Lfire:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 ADDR x19,_doom_player
 ldr w20,[x19,#40]
 cmp w20,#1
 b.eq Lfire_melee
 cmp w20,#3
 b.eq Lfire_shell
 cmp w20,#5
 b.eq Lfire_rocket
 cmp w20,#6
 b.ge Lfire_cell
 ldr w8,[x19,#24]
 cbz w8,Lfire_empty
 sub w8,w8,#1
 str w8,[x19,#24]
 mov w22,#1
 b Lfire_pellets
Lfire_shell:
 ldr w8,[x19,#28]
 cbz w8,Lfire_empty
 sub w8,w8,#1
 str w8,[x19,#28]
 mov w22,#7
 b Lfire_pellets
Lfire_melee:
 bl Lrandom
 mov w8,#10
 udiv w9,w0,w8
 msub w0,w9,w8,w0
 add w0,w0,#1
 lsl w21,w0,#1
 COUNT w8,_world_strength
 cbz w8,Lfire_melee_range
 COUNT w8,_world_saw_active
 cbnz w8,Lfire_melee_range
 mov w8,#10
 mul w21,w21,w8
Lfire_melee_range:
 mov w16,#64
 scvtf s1,w16
 COUNT w8,_world_saw_active
 cbz w8,Lfire_melee_shoot
 mov w16,#65
 scvtf s1,w16
Lfire_melee_shoot:
 ldr s0,[x19,#12]
 mov w0,w21
 mov w1,#0
 bl Lhitscan
 b Lfire_sound
Lfire_pellets:
 // First pistol/chaingun shot is accurate. Refire scatters by original BAM
 // unit18, with the same spread applied independently to7 shotgun pellets.
 mov w23,#0
 cmp w20,#3
 b.eq Lfire_scatter
 COUNT w8,_doom_tic
 COUNT w9,_world_last_shot
 cbz w9,Lfire_pellet_loop
 sub w8,w8,w9
 cmp w8,#15
 b.hi Lfire_pellet_loop
Lfire_scatter:
 mov w23,#1
Lfire_pellet_loop:
 ldr s8,[x19,#12]
 cbz w23,Lfire_pellet_damage
 bl Lrandom
 and w24,w0,#255
 bl Lrandom
 and w0,w0,#255
 sub w0,w24,w0
 scvtf s0,w0
 ADDR x8,_bullet_spread
 ldr s1,[x8]
 fmadd s8,s0,s1,s8
Lfire_pellet_damage:
 bl Lrandom
 mov w8,#3
 udiv w9,w0,w8
 msub w0,w9,w8,w0
 add w0,w0,#1
 mov w8,#5
 mul w0,w0,w8
 fmov s0,s8
 mov w8,#2048
 scvtf s1,w8
 mov w1,#0
 bl Lhitscan
 subs w22,w22,#1
 b.ne Lfire_pellet_loop
 b Lfire_sound
Lfire_rocket:
 ldr w8,[x19,#32]
 cbz w8,Lfire_empty
 sub w8,w8,#1
 str w8,[x19,#32]
 mov w21,#20
 b Lfire_missile
Lfire_cell:
 ldr w8,[x19,#36]
 mov w9,#1
 cmp w20,#7
 mov w10,#40
 csel w9,w10,w9,eq
 cmp w8,w9
 b.lt Lfire_empty
 sub w8,w8,w9
 str w8,[x19,#36]
 mov w21,#5
 cmp w20,#7
 mov w8,#100
 csel w21,w8,w21,eq
Lfire_missile:
 mov w0,#0
 mov w1,#1
 ldr s0,[x19,#12]
 mov w8,#2048
 scvtf s1,w8
 bl Lhitscan
 fmov s1,s0
 mov x0,#0
 neg w1,w20
 mov w2,w21
 ldr s0,[x19,#12]
 bl Lspawn_missile
Lfire_sound:
 COUNT w8,_doom_tic
 ADDR x9,_world_last_shot
 str w8,[x9]
 mov w0,#3
 ADDR x1,_snd_pistol
 cmp w20,#1
 b.ne Lfire_sound_shell
 ADDR x1,_snd_punch
 b Lfire_sound_call
Lfire_sound_shell:
 cmp w20,#3
 b.ne Lfire_sound_rocket
 ADDR x1,_snd_shotgun
 b Lfire_sound_call
Lfire_sound_rocket:
 cmp w20,#5
 b.ne Lfire_sound_plasma
 ADDR x1,_snd_rocket
 b Lfire_sound_call
Lfire_sound_plasma:
 cmp w20,#6
 b.ne Lfire_sound_bfg
 ADDR x1,_snd_plasma
 b Lfire_sound_call
Lfire_sound_bfg:
 cmp w20,#7
 b.ne Lfire_sound_call
 ADDR x1,_snd_bfg
Lfire_sound_call:
 bl _doom_sound
 b Lfire_end
Lfire_empty:
 mov w8,#1
 str w8,[x19,#40]
Lfire_end:
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// Player hitscan: s0 angle,s1 range,w0 damage ->w0 hit0/1. Stack128,
// x19-x24,d8-d12 preserved. Every solid wall and actor interval is bounded.
Lhitscan:
 stp x29,x30,[sp,#-128]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 str d12,[sp,#96]
 mov w20,w0
 str w1,[sp,#108]
 fmov s11,s0
 fmov s12,s1
 ADDR x19,_doom_player
 bl _cosf
 fmov s8,s0
 fmov s0,s11
 bl _sinf
 fmov s9,s0
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s12
 ldr s5,[x19,#8]
 ldr s6,[x19,#52]
 fadd s5,s5,s6
 fmov s6,wzr
 bl Ltrace
 str s0,[sp,#112]
 fmov s10,s12
 mov x24,#0
 ADDR x21,_doom_actors
 COUNT w22,_doom_actor_count
Lhit_actor:
 cbz w22,Lhit_selected
 ldr w8,[x21,#32]
 tbz w8,#1,Lhit_next
 tbnz w8,#6,Lhit_next
 ldp s0,s1,[x21]
 ldp s2,s3,[x19]
 fsub s0,s0,s2
 fsub s1,s1,s3
 fmul s2,s0,s8
 fmadd s2,s1,s9,s2
 fcmp s2,#0.0
 b.le Lhit_next
 fcmp s2,s10
 b.ge Lhit_next
 fmul s3,s0,s9
 fmul s4,s1,s8
 fsub s3,s3,s4
 fabs s3,s3
 ldr s4,[x21,#16]
 fcmp s3,s4
 b.gt Lhit_next
 str s2,[sp,#120]
 ldr s5,[x19,#8]
 ldr s6,[x19,#52]
 fadd s5,s5,s6
 ldr s6,[x21,#20]
 fmov s7,#0.5
 fmul s6,s6,s7
 ldr s7,[x21,#8]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s2
 fabs s7,s6
 fmov s4,#0.625
 fcmp s7,s4
 b.gt Lhit_next
 str s6,[sp,#124]
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 ldr s4,[sp,#120]
 bl Ltrace
 ldr s1,[sp,#120]
 fcmp s0,s1
 b.lt Lhit_next
 fmov s10,s1
 ldr s0,[sp,#124]
 str s0,[sp,#116]
 mov x24,x21
Lhit_next:
 add x21,x21,#ACTOR_SIZE
 sub w22,w22,#1
 b Lhit_actor
Lhit_selected:
 cbnz x24,Lhit_selected_actor
 ldr s10,[sp,#112]
Lhit_selected_actor:
 ldr w8,[sp,#108]
 cbnz w8,Lhit_damage
 ldr w8,[x19,#40]
 cmp w8,#2
 b.lt Lhit_damage
 cmp w8,#4
 b.gt Lhit_damage
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s10
 bl Lshoot_specials
Lhit_damage:
 cbz x24,Lhit_miss
 cbz w20,Lhit_query
 mov x0,x24
 mov w1,w20
 bl Ldamage_actor
Lhit_query:
 ldr s0,[sp,#116]
 mov w0,#1
 b Lhit_end
Lhit_miss:
 fmov s0,wzr
 mov w0,#0
Lhit_end:
 ldr d12,[sp,#96]
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#128
 ret

// x0 owner actor or0 player; s0 angle; w1 negative missile type; w2 damage.
// Stack80,x19-x22,d8-d9 preserved. Reuses expired missile slots; no allocation.
// s1 is the player autoaim slope; enemy vertical aim uses the target height.
// Missile misc packs owner index low16 and signed8.8 vertical velocity high16.
Lspawn_missile:
 stp x29,x30,[sp,#-80]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 mov x19,x0
 mov w20,w1
 mov w21,w2
 fmov s8,s0
 fmov s9,s1
 bl Lallocate_actor
 mov x22,x0
 cbz x22,Lmissile_spawn_end
 mov x0,x22
 mov x1,#ACTOR_SIZE
 bl _bzero
 str s8,[x22,#12]
 str w20,[x22,#24]
 str w21,[x22,#28]
 mov w8,#16
 str w8,[x22,#32]
 mov w8,#2100
 str w8,[x22,#64]
 mov w8,#-1
 str w8,[x22,#44]
 fmov s0,#6.0
 str s0,[x22,#16]
 fmov s0,#8.0
 str s0,[x22,#20]
 cbnz x19,Lmissile_owner
 ADDR x19,_doom_player
 mov w8,#65535
 str w8,[x22,#76]
 b Lmissile_position
Lmissile_owner:
 ADDR x8,_doom_actors
 sub x8,x19,x8
 mov x9,#ACTOR_SIZE
 udiv x8,x8,x9
 str w8,[x22,#76]
Lmissile_position:
 ldp s0,s1,[x19]
 stp s0,s1,[x22]
 ldr s0,[x19,#8]
 mov w16,#32
 scvtf s1,w16
 fadd s0,s0,s1
 str s0,[x22,#8]
 // Correct projectile speeds are derived from family, never from WAD code.
 fmov s2,#10.0
 cmp w20,#-3
 b.ne Lmissile_spawn_speed_rocket
 fmov s2,#15.0
Lmissile_spawn_speed_rocket:
 cmp w20,#-5
 b.ne Lmissile_spawn_speed_plasma
 fmov s2,#20.0
Lmissile_spawn_speed_plasma:
 cmp w20,#-6
 b.eq Lmissile_spawn_speed25
 cmp w20,#-7
 b.ne Lmissile_spawn_velocity
Lmissile_spawn_speed25:
 fmov s2,#25.0
Lmissile_spawn_velocity:
 ldr w8,[x22,#76]
 mov w9,#65535
 cmp w8,w9
 b.eq Lmissile_spawn_player_vz
 ADDR x8,_doom_player
 ldp s3,s4,[x8]
 ldp s5,s6,[x19]
 fsub s3,s3,s5
 fsub s4,s4,s6
 fmul s3,s3,s3
 fmadd s3,s4,s4,s3
 fsqrt s3,s3
 fdiv s3,s3,s2
 fmov s4,#1.0
 fmax s3,s3,s4
 ldr s4,[x8,#8]
 ldr s5,[x19,#8]
 fsub s4,s4,s5
 fdiv s4,s4,s3
 b Lmissile_spawn_pack_vz
Lmissile_spawn_player_vz:
 fmul s4,s9,s2
Lmissile_spawn_pack_vz:
 mov w8,#127
 scvtf s5,w8
 fmin s4,s4,s5
 fneg s5,s5
 fmax s4,s4,s5
 mov w8,#256
 scvtf s5,w8
 fmul s4,s4,s5
 fcvtzs w9,s4
 ldr w8,[x22,#76]
 orr w8,w8,w9,lsl #16
 str w8,[x22,#76]
 ADDR x8,_sprite_fireball
 cmp w20,#-2
 b.ne Lmissile_spawn_green
 ADDR x8,_sprite_cacoball
Lmissile_spawn_green:
 cmp w20,#-3
 b.ne Lmissile_spawn_bfg
 ADDR x8,_sprite_greenball
Lmissile_spawn_bfg:
 cmp w20,#-7
 b.ne Lmissile_spawn_rocket
 ADDR x8,_sprite_bfgball
Lmissile_spawn_rocket:
 cmp w20,#-5
 b.ne Lmissile_sprite_plasma
 ADDR x8,_sprite_rocket
 b Lmissile_sprite
Lmissile_sprite_plasma:
 cmp w20,#-6
 b.ne Lmissile_sprite
 ADDR x8,_sprite_plasma
Lmissile_sprite:
 ldr x8,[x8]
 str x8,[x22,#48]
Lmissile_spawn_end:
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#80
 ret

// Tick actors, pickups, pursuit and missiles. Stack112,x19-x24,d8-d11 saved.
// State2/3 use bounded source DATA; state4 is a lost-soul charge.
Lactors_tick:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 ADDR x19,_doom_actors
 ADDR x20,_doom_player
 COUNT w21,_doom_actor_count
 mov w22,#0
Lactor_loop:
 cmp w22,w21
 b.hs Lactor_end
 ldr w8,[x19,#32]
 tbnz w8,#6,Lactor_next
 tbnz w8,#3,Lactor_dead
 tbnz w8,#4,Lactor_missile
 tbnz w8,#2,Lactor_pickup
 tbz w8,#5,Lactor_next
 ldr w9,[x19,#28]
 cmp w9,#0
 b.le Lactor_next
 ldr w9,[x19,#60]
 cbz w9,Lactor_monster
 sub w9,w9,#1
 str w9,[x19,#60]
 b Lactor_next
Lactor_pickup:
 ldp s0,s1,[x19]
 ldp s2,s3,[x20]
 fsub s0,s0,s2
 fsub s1,s1,s3
 fmul s0,s0,s0
 fmadd s0,s1,s1,s0
 mov w8,#1024
 scvtf s1,w8
 fcmp s0,s1
 b.gt Lactor_next
 // Original special-item reach is asymmetric: deltaZ in[-8,playerheight].
 ldr s2,[x19,#8]
 ldr s3,[x20,#8]
 fsub s2,s2,s3
 mov w8,#PLAYER_HEIGHT
 scvtf s3,w8
 fcmp s2,s3
 b.gt Lactor_next
 mov w8,#-PICKUP_BELOW_REACH
 scvtf s3,w8
 fcmp s2,s3
 b.lt Lactor_next
 mov x0,x19
 bl Lpickup
 b Lactor_next
Lactor_dead:
 mov x0,x19
 bl Lmonster_tick
 b Lactor_next
Lactor_monster:
 ldr w8,[x19,#36]
 cmp w8,#2
 b.eq Lactor_state_tick
 cmp w8,#4
 b.eq Lactor_skull_tick
 mov x0,x19
 bl Lfloat_actor
 ldr w8,[x20,#16]
 cmp w8,#0
 b.le Lactor_next
 ldp s0,s1,[x20]
 ldp s2,s3,[x19]
 fsub s8,s0,s2
 fsub s9,s1,s3
 fmul s10,s8,s8
 fmadd s10,s9,s9,s10
 fsqrt s10,s10
 fmov s0,#1.0
 fmax s10,s10,s0
 fdiv s8,s8,s10
 fdiv s9,s9,s10
 // Sight bound and obstruction. Awakened monsters retain player target.
 ldr w8,[x19,#44]
 cmp w8,#0
 b.eq Lactor_awake
 mov w8,#1024
 scvtf s0,w8
 fcmp s10,s0
 b.gt Lactor_next
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s10
 ldr s5,[x19,#20]
 fmov s6,#0.75
 fmul s5,s5,s6
 ldr s6,[x19,#8]
 fadd s5,s5,s6
 ldr s6,[x20,#8]
 ldr s7,[x20,#52]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s10
 bl Ltrace
 fcmp s0,s10
 b.lt Lactor_next
 str wzr,[x19,#44]
Lactor_awake:
 // Turn toward the player for direction-sensitive rendering.
 fmov s0,s9
 fmov s1,s8
 bl _atan2f
 str s0,[x19,#12]
 ldr w0,[x19,#24]
 bl Ldefinition
 mov x23,x0
 ldr w8,[x19,#64]
 cbz w8,Lactor_attack_check
 sub w8,w8,#1
 str w8,[x19,#64]
 b Lactor_walk
Lactor_attack_check:
 ldr w24,[x23,#24]
 mov w16,#64
 scvtf s0,w16
 fcmp s10,s0
 b.le Lactor_attack_sight
 cbz w24,Lactor_walk
 mov w8,#640
 scvtf s0,w8
 fcmp s10,s0
 b.gt Lactor_walk
Lactor_attack_sight:
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s10
 ldr s5,[x19,#20]
 fmov s6,#0.75
 fmul s5,s5,s6
 ldr s6,[x19,#8]
 fadd s5,s5,s6
 ldr s6,[x20,#8]
 ldr s7,[x20,#52]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s10
 bl Ltrace
 fcmp s0,s10
 b.lt Lactor_walk
Lactor_attack:
 mov x0,x19
 bl Lmonster_begin
 b Lactor_next
Lactor_state_tick:
 mov x0,x19
 bl Lmonster_tick
 b Lactor_next
Lactor_skull_tick:
 mov x0,x19
 mov w1,w22
 bl Lskull_tick
 b Lactor_next
Lactor_walk:
 ldr w0,[x19,#24]
 bl Lmonster_meta
 cbz x0,Lactor_walk_fallback
 ldr w8,[x0,#4]
 cbz w8,Lactor_next
 COUNT w9,_doom_tic
 udiv w10,w9,w8
 msub w9,w10,w8,w9
 cbnz w9,Lactor_next
 ldr s11,[x0,#8]
 b Lactor_walk_speed
Lactor_walk_fallback:
 ldr s11,[x23,#20]
Lactor_walk_speed:
 ldp s0,s1,[x19]
 stp s0,s1,[sp,#96]
 fmul s8,s8,s11
 fmul s9,s9,s11
 ldp s0,s1,[x19]
 fadd s0,s0,s8
 fadd s1,s1,s9
 // Stop before overlapping the player.
 ldp s2,s3,[x20]
 fsub s2,s0,s2
 fsub s3,s1,s3
 fmul s2,s2,s2
 fmadd s2,s3,s3,s2
 ldr s3,[x19,#16]
 fmov s4,#16.0
 fadd s3,s3,s4
 fmul s3,s3,s3
 fcmp s2,s3
 b.lt Lactor_next
 ldr s2,[x19,#8]
 ldr s3,[x19,#16]
 ldr s4,[x19,#20]
 mov w0,w22
 mov w1,#1
 bl Lcan_move
 tbnz w0,#31,Lactor_slide
 ldp s1,s2,[x19]
 fadd s1,s1,s8
 fadd s2,s2,s9
 stp s1,s2,[x19]
 ldr w8,[x19,#24]
 cmp w8,#3005
 b.eq Lactor_move_float
 cmp w8,#3006
 b.ne Lactor_move_ground
Lactor_move_float:
 ldr s1,[x19,#8]
 fmax s0,s0,s1
Lactor_move_ground:
 str s0,[x19,#8]
 b Lactor_animate
Lactor_slide:
 mov x0,x19
 mov w1,w22
 bl Lmonster_use
 // Alternate perpendicular turn prevents permanent corner locking.
 COUNT w8,_doom_tic
 tst w8,#32
 b.eq Lactor_slide_left
 fneg s9,s9
 b Lactor_slide_try
Lactor_slide_left:
 fneg s8,s8
Lactor_slide_try:
 ldp s0,s1,[x19]
 fadd s0,s0,s9
 fadd s1,s1,s8
 ldr s2,[x19,#8]
 ldr s3,[x19,#16]
 ldr s4,[x19,#20]
 mov w0,w22
 mov w1,#1
 bl Lcan_move
 tbnz w0,#31,Lactor_next
 ldp s1,s2,[x19]
 fadd s1,s1,s9
 fadd s2,s2,s8
 stp s1,s2,[x19]
 ldr w8,[x19,#24]
 cmp w8,#3005
 b.eq Lactor_slide_float
 cmp w8,#3006
 b.ne Lactor_slide_ground
Lactor_slide_float:
 ldr s1,[x19,#8]
 fmax s0,s0,s1
Lactor_slide_ground:
 str s0,[x19,#8]
Lactor_animate:
 ldp s0,s1,[sp,#96]
 mov w0,w22
 bl Lcross_lines
 COUNT w8,_doom_tic
 lsr w8,w8,#3
 and w8,w8,#3
 str w8,[x19,#56]
 add w8,w8,#65
 strb w8,[x19,#52]
 b Lactor_next
Lactor_missile:
 mov x0,x19
 mov w1,w22
 bl Lmissile_tick
Lactor_next:
 add x19,x19,#ACTOR_SIZE
 add w22,w22,#1
 b Lactor_loop
Lactor_end:
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// x0 actor missile,w1 index. Four bounded substeps prevent wall tunneling.
// Stack112,x19-x23,d8-d11 preserved.
Lmissile_tick:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 str x23,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 mov x19,x0
 mov w20,w1
 ldr w8,[x19,#64]
 subs w8,w8,#1
 str w8,[x19,#64]
 b.le Lmissile_hide
 ldr s0,[x19,#12]
 bl _cosf
 fmov s8,s0
 ldr s0,[x19,#12]
 bl _sinf
 fmov s9,s0
 ldr w8,[x19,#24]
 fmov s10,#2.5
 cmp w8,#-3
 b.ne Lmissile_baron_speed
 fmov s10,#3.75
Lmissile_baron_speed:
 cmp w8,#-5
 b.ne Lmissile_fast
 fmov s10,#5.0
Lmissile_fast:
 cmp w8,#-6
 b.eq Lmissile_plasma_speed
 cmp w8,#-7
 b.ne Lmissile_speed
Lmissile_plasma_speed:
 fmov s10,#6.25
Lmissile_speed:
 fmul s8,s8,s10
 fmul s9,s9,s10
 mov w21,#4
Lmissile_substep:
 ldr w8,[x19,#76]
 asr w8,w8,#16
 scvtf s0,w8
 mov w8,#1024
 scvtf s1,w8
 fdiv s0,s0,s1
 ldr s1,[x19,#8]
 fadd s0,s0,s1
 str s0,[x19,#8]
 ldp s0,s1,[x19]
 fadd s0,s0,s8
 fadd s1,s1,s9
 ldr s2,[x19,#8]
 fmov s3,#3.0
 fmov s4,#8.0
 // Missile actors do not run actor collision here: source overlap is allowed.
 mov w0,w20
 mov w1,#0
 bl Lmissile_map_move
 tbnz w0,#31,Lmissile_explode
 ldp s0,s1,[x19]
 fadd s0,s0,s8
 fadd s1,s1,s9
 stp s0,s1,[x19]
 ldr w8,[x19,#76]
 and w8,w8,#65535
 mov w9,#65535
 cmp w8,w9
 b.eq Lmissile_hit_monsters
 ADDR x8,_doom_player
 ldp s2,s3,[x8]
 fsub s2,s0,s2
 fsub s3,s1,s3
 fmul s2,s2,s2
 fmadd s2,s3,s3,s2
 mov w8,#576
 scvtf s3,w8
 fcmp s2,s3
 b.gt Lmissile_continue
 ADDR x8,_doom_player
 ldr s2,[x19,#8]
 ldr s3,[x8,#8]
 mov w9,#56
 scvtf s4,w9
 fadd s4,s3,s4
 fcmp s2,s4
 b.ge Lmissile_continue
 fmov s4,#8.0
 fadd s2,s2,s4
 fcmp s2,s3
 b.le Lmissile_continue
 bl Lrandom
 and w8,w0,#7
 add w8,w8,#1
 ldr w0,[x19,#28]
 mul w0,w0,w8
 bl Ldamage_player
 b Lmissile_explode
Lmissile_hit_monsters:
 ADDR x22,_doom_actors
 COUNT w23,_doom_actor_count
Lmissile_target:
 cbz w23,Lmissile_continue
 ldr w8,[x22,#32]
 tbz w8,#1,Lmissile_target_next
 ldp s2,s3,[x22]
 ldp s0,s1,[x19]
 fsub s2,s0,s2
 fsub s3,s1,s3
 fmul s2,s2,s2
 fmadd s2,s3,s3,s2
 ldr s3,[x22,#16]
 fmov s4,#6.0
 fadd s3,s3,s4
 fmul s3,s3,s3
 fcmp s2,s3
 b.gt Lmissile_target_next
 ldr s2,[x19,#8]
 ldr s3,[x22,#8]
 ldr s4,[x22,#20]
 fadd s4,s3,s4
 fcmp s2,s4
 b.ge Lmissile_target_next
 fmov s4,#8.0
 fadd s2,s2,s4
 fcmp s2,s3
 b.le Lmissile_target_next
 bl Lrandom
 and w8,w0,#7
 add w8,w8,#1
 ldr w1,[x19,#28]
 mul w1,w1,w8
 mov x0,x22
 bl Ldamage_actor
 b Lmissile_explode
Lmissile_target_next:
 add x22,x22,#ACTOR_SIZE
 sub w23,w23,#1
 b Lmissile_target
Lmissile_continue:
 subs w21,w21,#1
 b.ne Lmissile_substep
 b Lmissile_end
Lmissile_explode:
 ldr w8,[x19,#24]
 cmp w8,#-7
 b.eq Lmissile_bfg_spray
 cmp w8,#-5
 b.ne Lmissile_hide
 mov x0,x19
 mov w1,#128
 bl Lradius_damage
 b Lmissile_hide
Lmissile_bfg_spray:
 mov x0,x19
 bl Lbfg_spray
Lmissile_hide:
 mov w8,#64
 str w8,[x19,#32]
Lmissile_end:
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldr x23,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// Missile collision uses a ray for wall crossing, plus target sector clearance.
// Inputs same as can_move. Stack64,d8-d11 preserved; x19 is the missile.
Lmissile_map_move:
 stp x29,x30,[sp,#-64]!
 stp d8,d9,[sp,#16]
 stp d10,d11,[sp,#32]
 fmov s8,s0
 fmov s9,s1
 fmov s10,s2
 bl _doom_point_sector
 tbnz w0,#31,Lmissile_map_bad
 ADDR x8,_world_floors
 ldr s0,[x8,w0,uxtw #2]
 fcmp s10,s0
 b.lt Lmissile_map_bad
 ADDR x8,_world_ceilings
 ldr s0,[x8,w0,uxtw #2]
 fmov s1,#8.0
 fadd s1,s10,s1
 fcmp s1,s0
 b.gt Lmissile_map_bad
 str w0,[sp,#48]
 ldp s0,s1,[x19]
 fsub s2,s8,s0
 fsub s3,s9,s1
 fmul s4,s2,s2
 fmadd s4,s3,s3,s4
 fsqrt s4,s4
 fmov s11,s4
 fdiv s2,s2,s4
 fdiv s3,s3,s4
 ldr s5,[x19,#8]
 fmov s6,wzr
 bl Ltrace
 fcmp s0,s11
 b.lt Lmissile_map_bad
 ldr w0,[sp,#48]
 b Lmissile_map_end
Lmissile_map_bad:
 mov w0,#-1
Lmissile_map_end:
 ldp d10,d11,[sp,#32]
 ldp d8,d9,[sp,#16]
 ldp x29,x30,[sp],#64
 ret
// x0 explosion center actor,w1 radius and maximum damage<=128.
// Splash includes the player and uses wall visibility. Stack112, preserves
// x19-x23,d8-d11. A dying barrel becomes nonshootable before recursive damage.
Lradius_damage:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 str x23,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 mov x19,x0
 mov w22,w1
 ldp s8,s9,[x19]
 ADDR x20,_doom_actors
 COUNT w21,_doom_actor_count
Lradius_actor:
 cbz w21,Lradius_player
 ldr w8,[x20,#32]
 tbz w8,#1,Lradius_next
 tbnz w8,#6,Lradius_next
 ldr w8,[x20,#24]
 cmp w8,#16
 b.eq Lradius_next
 cmp w8,#7
 b.eq Lradius_next
 ldp s2,s3,[x20]
 fsub s2,s2,s8
 fsub s3,s3,s9
 fmul s10,s2,s2
 fmadd s10,s3,s3,s10
 fsqrt s10,s10
 fcvtzs w8,s10
 subs w23,w22,w8
 b.le Lradius_next
 fcmp s10,#0.0
 b.eq Lradius_damage_actor
 fdiv s2,s2,s10
 fdiv s3,s3,s10
 fmov s0,s8
 fmov s1,s9
 fmov s4,s10
 ldr s5,[x19,#8]
 ldr s6,[x20,#8]
 ldr s7,[x20,#20]
 fmov s4,#0.5
 fmadd s6,s7,s4,s6
 fsub s6,s6,s5
 fdiv s6,s6,s10
 fmov s4,s10
 bl Ltrace
 fcmp s0,s10
 b.lt Lradius_next
Lradius_damage_actor:
 mov x0,x20
 mov w1,w23
 bl Ldamage_actor
Lradius_next:
 add x20,x20,#ACTOR_SIZE
 sub w21,w21,#1
 b Lradius_actor
Lradius_player:
 ADDR x20,_doom_player
 ldp s2,s3,[x20]
 fsub s2,s2,s8
 fsub s3,s3,s9
 fmul s10,s2,s2
 fmadd s10,s3,s3,s10
 fsqrt s10,s10
 fcvtzs w8,s10
 subs w23,w22,w8
 b.le Lradius_end
 fcmp s10,#0.0
 b.eq Lradius_hurt_player
 fdiv s2,s2,s10
 fdiv s3,s3,s10
 fmov s0,s8
 fmov s1,s9
 fmov s4,s10
 ldr s5,[x19,#8]
 ldr s6,[x20,#8]
 ldr s7,[x20,#52]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s10
 bl Ltrace
 fcmp s0,s10
 b.lt Lradius_end
Lradius_hurt_player:
 mov w0,w23
 bl Ldamage_player
Lradius_end:
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldr x23,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// Boss deaths bind to the actual episode/map and require all matching bosses
// dead. E2M8/E3M8 complete; E1M8/E4M8 lower tagged666; E4M6 opens tagged666.
// x0 actor; leaf except neighbor query, stack64,x19-x22 preserved.
Lboss_death:
 stp x29,x30,[sp,#-64]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 ldr w19,[x0,#24]
 ADDR x8,_world_map
 ldrb w20,[x8,#1]
 ldrb w21,[x8,#3]
 cmp w21,#56
 b.eq Lboss_map8
 cmp w20,#52
 b.ne Lboss_end
 cmp w21,#54
 b.ne Lboss_end
 cmp w19,#16
 b.ne Lboss_end
 mov w22,#1
 b Lboss_all_dead
Lboss_map8:
 mov w22,#0
 cmp w20,#49
 b.eq Lboss_baron
 cmp w20,#50
 b.eq Lboss_cyber
 cmp w20,#51
 b.eq Lboss_spider
 cmp w20,#52
 b.ne Lboss_end
 cmp w19,#7
 b.ne Lboss_end
 b Lboss_all_dead
Lboss_baron:
 cmp w19,#3003
 b.ne Lboss_end
 b Lboss_all_dead
Lboss_cyber:
 cmp w19,#16
 b.ne Lboss_end
 mov w22,#2
 b Lboss_all_dead
Lboss_spider:
 cmp w19,#7
 b.ne Lboss_end
 mov w22,#2
Lboss_all_dead:
 ADDR x8,_doom_actors
 COUNT w9,_doom_actor_count
Lboss_alive_loop:
 cbz w9,Lboss_action
 ldr w10,[x8,#24]
 cmp w10,w19
 b.ne Lboss_alive_next
 ldr w10,[x8,#28]
 cmp w10,#0
 b.gt Lboss_end
Lboss_alive_next:
 add x8,x8,#ACTOR_SIZE
 sub w9,w9,#1
 b Lboss_alive_loop
Lboss_action:
 cmp w22,#2
 b.ne Lboss_sectors
 ADDR x8,_doom_level_complete
 mov w9,#1
 str w9,[x8]
 b Lboss_end
Lboss_sectors:
 mov w19,#0
 COUNT w20,_doom_sector_count
 PTR x21,_doom_sectors
Lboss_sector_loop:
 cmp w19,w20
 b.hs Lboss_end
 ldrh w8,[x21,#24]
 cmp w8,#666
 b.ne Lboss_sector_next
 mov w0,w19
 bl Lneighbors
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x8,x19,x9,x8
 cbnz w22,Lboss_open
 str s1,[x8,#4]
 mov w9,#2
 str w9,[x8]
 b Lboss_speed
Lboss_open:
 fmov s1,#4.0
 fsub s0,s0,s1
 str s0,[x8,#4]
 mov w9,#1
 str w9,[x8]
 str wzr,[x8,#20]
Lboss_speed:
 fmov s0,#2.0
 str s0,[x8,#8]
Lboss_sector_next:
 add x21,x21,#26
 add w19,w19,#1
 b Lboss_sector_loop
Lboss_end:
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#64
 ret

// x0 pickup actor. Consumes only when the held resource can change.
// Stack48; preserves x19-x21. Definitions use standard Doom thing numbers.
Lpickup:
 stp x29,x30,[sp,#-48]!
 stp x19,x20,[sp,#16]
 str x21,[sp,#32]
 mov x19,x0
 ADDR x20,_doom_player
 ldr w21,[x19,#24]
 cmp w21,#2011
 b.eq Lpickup_stim
 cmp w21,#2012
 b.eq Lpickup_medi
 cmp w21,#2014
 b.eq Lpickup_bonus
 cmp w21,#2013
 b.eq Lpickup_soul
 cmp w21,#2023
 b.eq Lpickup_berserk
 cmp w21,#2018
 b.eq Lpickup_armor
 cmp w21,#2019
 b.eq Lpickup_armor2
 cmp w21,#2015
 b.eq Lpickup_armorbonus
 cmp w21,#5
 b.eq Lpickup_blue
 cmp w21,#40
 b.eq Lpickup_blue
 cmp w21,#6
 b.eq Lpickup_yellow
 cmp w21,#39
 b.eq Lpickup_yellow
 cmp w21,#13
 b.eq Lpickup_red
 cmp w21,#38
 b.eq Lpickup_red
 cmp w21,#2022
 b.eq Lpickup_invul
 cmp w21,#2025
 b.eq Lpickup_suit
 cmp w21,#2024
 b.eq Lpickup_consume
 cmp w21,#2026
 b.eq Lpickup_consume
 cmp w21,#2045
 b.eq Lpickup_consume
 cmp w21,#8
 b.eq Lpickup_backpack
 cmp w21,#2001
 b.eq Lpickup_shotgun
 cmp w21,#2002
 b.eq Lpickup_chaingun
 cmp w21,#2003
 b.eq Lpickup_launcher
 cmp w21,#2004
 b.eq Lpickup_plasma
 cmp w21,#2006
 b.eq Lpickup_bfg
 cmp w21,#2005
 b.eq Lpickup_chainsaw
 cmp w21,#2007
 b.eq Lpickup_clip
 cmp w21,#2048
 b.eq Lpickup_box
 cmp w21,#2008
 b.eq Lpickup_shells
 cmp w21,#2049
 b.eq Lpickup_shellbox
 cmp w21,#2010
 b.eq Lpickup_rocket
 cmp w21,#2046
 b.eq Lpickup_rocketbox
 cmp w21,#2047
 b.eq Lpickup_cell
 cmp w21,#17
 b.eq Lpickup_cellpack
 b Lpickup_end
Lpickup_stim:
 mov w8,#10
 mov w9,#100
 b Lpickup_health
Lpickup_medi:
 mov w8,#25
 mov w9,#100
 b Lpickup_health
Lpickup_bonus:
 mov w8,#1
 mov w9,#200
 b Lpickup_health
Lpickup_soul:
 mov w8,#100
 mov w9,#200
 b Lpickup_health
Lpickup_berserk:
 ADDR x8,_world_strength
 mov w9,#1
 str w9,[x8]
 ADDR x8,_world_saw_active
 str wzr,[x8]
 str w9,[x20,#40]
 ldr w8,[x20,#16]
 cmp w8,#100
 b.ge Lpickup_consume
 mov w8,#100
 str w8,[x20,#16]
 b Lpickup_consume
Lpickup_health:
 ldr w10,[x20,#16]
 cmp w10,w9
 b.ge Lpickup_end
 add w10,w10,w8
 cmp w10,w9
 csel w10,w10,w9,lt
 str w10,[x20,#16]
 b Lpickup_consume
Lpickup_armor:
 mov w8,#100
 b Lpickup_armorset
Lpickup_armor2:
 mov w8,#200
Lpickup_armorset:
 ldr w9,[x20,#20]
 cmp w9,w8
 b.ge Lpickup_end
 str w8,[x20,#20]
 mov w9,#1
 cmp w8,#200
 mov w10,#2
 csel w9,w10,w9,eq
 ADDR x10,_world_armor_type
 str w9,[x10]
 b Lpickup_consume
Lpickup_armorbonus:
 ldr w8,[x20,#20]
 cbnz w8,Lpickup_armorbonus_amount
 ADDR x9,_world_armor_type
 mov w10,#1
 str w10,[x9]
Lpickup_armorbonus_amount:
 cmp w8,#200
 b.ge Lpickup_end
 add w8,w8,#1
 str w8,[x20,#20]
 b Lpickup_consume
Lpickup_blue:
 mov w8,#1
 b Lpickup_key
Lpickup_yellow:
 mov w8,#2
 b Lpickup_key
Lpickup_red:
 mov w8,#4
Lpickup_key:
 ldr w9,[x20,#44]
 orr w9,w9,w8
 str w9,[x20,#44]
 b Lpickup_consume
Lpickup_invul:
 ADDR x8,_world_invul
 mov w9,#1050
 str w9,[x8]
 b Lpickup_consume
Lpickup_suit:
 ADDR x8,_world_suit
 mov w9,#2100
 str w9,[x8]
 b Lpickup_consume
Lpickup_shotgun:
 mov w8,#3
 mov w9,#28
 mov w10,#8
 ldr w12,[x19,#76]
 cbz w12,Lpickup_shotgun_amount
 mov w10,#4
Lpickup_shotgun_amount:
 mov w11,#50
 b Lpickup_weapon
Lpickup_chaingun:
 mov w8,#4
 mov w9,#24
 mov w10,#20
 ldr w12,[x19,#76]
 cbz w12,Lpickup_chaingun_amount
 mov w10,#10
Lpickup_chaingun_amount:
 mov w11,#200
 b Lpickup_weapon
Lpickup_launcher:
 mov w8,#5
 mov w9,#32
 mov w10,#2
 mov w11,#50
 b Lpickup_weapon
Lpickup_plasma:
 mov w8,#6
 mov w9,#36
 mov w10,#40
 mov w11,#300
 b Lpickup_weapon
Lpickup_bfg:
 mov w8,#7
 mov w9,#36
 mov w10,#40
 mov w11,#300
 b Lpickup_weapon
Lpickup_chainsaw:
 ADDR x8,_world_saw_owned
 mov w9,#1
 str w9,[x8]
 ADDR x8,_world_saw_active
 str w9,[x8]
 mov w8,#1
 mov w9,#24
 mov w10,#0
 mov w11,#200
Lpickup_weapon:
 mov w12,#1
 lsl w12,w12,w8
 ldr w13,[x20,#72]
 orr w13,w13,w12
 str w13,[x20,#72]
 str w8,[x20,#40]
 COUNT w12,_world_backpack
 lsl w11,w11,w12
 b Lpickup_ammo
Lpickup_clip:
 mov w9,#24
 mov w10,#10
 ldr w12,[x19,#76]
 cbz w12,Lpickup_clip_amount
 mov w10,#5
Lpickup_clip_amount:
 mov w11,#200
 b Lpickup_ammo_check
Lpickup_box:
 mov w9,#24
 mov w10,#50
 mov w11,#200
 b Lpickup_ammo_check
Lpickup_shells:
 mov w9,#28
 mov w10,#4
 mov w11,#50
 b Lpickup_ammo_check
Lpickup_shellbox:
 mov w9,#28
 mov w10,#20
 mov w11,#50
 b Lpickup_ammo_check
Lpickup_rocket:
 mov w9,#32
 mov w10,#1
 mov w11,#50
 b Lpickup_ammo_check
Lpickup_rocketbox:
 mov w9,#32
 mov w10,#5
 mov w11,#50
 b Lpickup_ammo_check
Lpickup_cell:
 mov w9,#36
 mov w10,#20
 mov w11,#300
 b Lpickup_ammo_check
Lpickup_cellpack:
 mov w9,#36
 mov w10,#100
 mov w11,#300
Lpickup_ammo_check:
 COUNT w12,_world_backpack
 lsl w11,w11,w12
 ldr w8,[x20,w9,uxtw]
 cmp w8,w11
 b.ge Lpickup_end
Lpickup_ammo:
 COUNT w12,_doom_skill
 cmp w12,#1
 b.eq Lpickup_ammo_double
 cmp w12,#5
 b.ne Lpickup_ammo_amount
Lpickup_ammo_double:
 lsl w10,w10,#1
Lpickup_ammo_amount:
 ldr w8,[x20,w9,uxtw]
 add w8,w8,w10
 cmp w8,w11
 csel w8,w8,w11,lt
 str w8,[x20,w9,uxtw]
 b Lpickup_consume
Lpickup_backpack:
 ADDR x8,_world_backpack
 mov w9,#1
 str w9,[x8]
 ADDR x8,_ammo_caps
 ADDR x9,_ammo_clips
 mov w10,#0
Lpickup_backpack_ammo:
 ldr w11,[x8,w10,uxtw #2]
 lsl w11,w11,#1
 ldr w12,[x9,w10,uxtw #2]
 COUNT w13,_doom_skill
 cmp w13,#1
 b.eq Lpickup_backpack_double
 cmp w13,#5
 b.ne Lpickup_backpack_amount
Lpickup_backpack_double:
 lsl w12,w12,#1
Lpickup_backpack_amount:
 add w13,w10,#6
 ldr w14,[x20,w13,uxtw #2]
 add w14,w14,w12
 cmp w14,w11
 csel w14,w14,w11,lo
 str w14,[x20,w13,uxtw #2]
 add w10,w10,#1
 cmp w10,#4
 b.lo Lpickup_backpack_ammo
Lpickup_consume:
 mov w8,#64
 str w8,[x19,#32]
 ldr w8,[x20,#60]
 add w8,w8,#1
 str w8,[x20,#60]
 mov w0,#4
 ADDR x1,_snd_item
 bl _doom_sound
Lpickup_end:
 ldr x21,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#48
 ret

// x0 raw linedef, s0/s1 origin, s2/s3 unit ray -> s0 distance/-1.
// Finite bounded records. Leaf, x8-x13 and s4-s7 destroyed, stack16.
Lray_line:
 sub sp,sp,#16
 stp s0,s1,[sp]
 PTR x8,_doom_vertices
 ldrh w9,[x0]
 ldrh w10,[x0,#2]
 add x9,x8,w9,uxtw #2
 add x10,x8,w10,uxtw #2
 ldrsh w11,[x9]
 scvtf s4,w11
 ldrsh w11,[x9,#2]
 scvtf s5,w11
 ldrsh w11,[x10]
 scvtf s6,w11
 ldrsh w11,[x10,#2]
 scvtf s7,w11
 fsub s6,s6,s4
 fsub s7,s7,s5
 fsub s4,s4,s0
 fsub s5,s5,s1
 // det = ray.x * edge.y - ray.y * edge.x
 fmul s0,s2,s7
 fmul s1,s3,s6
 fsub s0,s0,s1
 fcmp s0,#0.0
 b.eq Lray_none
 // t = cross(A-origin,edge)/det
 fmul s1,s4,s7
 fmul s7,s5,s6
 fsub s1,s1,s7
 fdiv s1,s1,s0
 fcmp s1,#0.0
 b.lt Lray_none
 // u = cross(A-origin,ray)/det
 fmul s4,s4,s3
 fmul s5,s5,s2
 fsub s4,s4,s5
 fdiv s4,s4,s0
 fcmp s4,#0.0
 b.lt Lray_none
 fmov s5,#1.0
 fcmp s4,s5
 b.gt Lray_none
 fmov s0,s1
 b Lray_return
Lray_none:
 fmov s0,#-1.0
Lray_return:
 add sp,sp,#16
 ret

// Use the nearest facing special within64 units. Stack96; x19-x22,d8-d11.
Luse:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 stp d10,d11,[sp,#64]
 ADDR x19,_doom_player
 ldr s0,[x19,#12]
 bl _cosf
 fmov s8,s0
 ldr s0,[x19,#12]
 bl _sinf
 fmov s9,s0
 mov w16,#64
 scvtf s10,w16
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s10
 ldr s5,[x19,#8]
 ldr s6,[x19,#52]
 fadd s5,s5,s6
 fmov s6,wzr
 bl Ltrace
 fmov s10,s0
 mov x22,#0
 PTR x20,_doom_lines
 COUNT w21,_doom_line_count
Luse_loop:
 cbz w21,Luse_found
 ldrh w8,[x20,#6]
 cbz w8,Luse_next
 ADDR x9,_use_specials
Luse_kind:
 ldrb w10,[x9],#1
 cbz w10,Luse_next
 cmp w10,w8
 b.ne Luse_kind
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 mov x0,x20
 bl Lray_line
 fcmp s0,#0.0
 b.lt Luse_next
 fcmp s0,s10
 b.gt Luse_next
 fmov s11,s0
 mov x0,x20
 ldp s0,s1,[x19]
 bl Lline_side
 cbnz w0,Luse_next
 fmov s10,s11
 mov x22,x20
Luse_next:
 add x20,x20,#14
 sub w21,w21,#1
 b Luse_loop
Luse_found:
 cbz x22,Luse_end
 mov x0,x22
 mov w1,#1
 mov w2,#-1
 mov w3,#0
 bl Lactivate
Luse_end:
 ldp d10,d11,[sp,#64]
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// s0/s1 old position, current player position defines a short crossing ray.
// Only walk-triggered special IDs activate here. Stack96; x19-x22,d8-d11.
Lcross_lines:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 stp d10,d11,[sp,#64]
 mov w22,w0
 fmov s8,s0
 fmov s9,s1
 ADDR x8,_doom_player
 tbnz w22,#31,Lcross_entity
 ADDR x8,_doom_actors
 mov w9,#ACTOR_SIZE
 madd x8,x22,x9,x8
Lcross_entity:
 ldp s0,s1,[x8]
 fsub s10,s0,s8
 fsub s11,s1,s9
 fmul s0,s10,s10
 fmadd s0,s11,s11,s0
 fsqrt s0,s0
 str s0,[sp,#80]
 fcmp s0,#0.0
 b.eq Lcross_end
 fdiv s10,s10,s0
 fdiv s11,s11,s0
 PTR x19,_doom_lines
 COUNT w20,_doom_line_count
Lcross_loop:
 cbz w20,Lcross_end
 ldrh w8,[x19,#6]
 // Doom walk triggers plus repeat variants. Use-only switches stay untouched.
 ADDR x9,_walk_specials
Lcross_kind:
 ldrb w10,[x9],#1
 cbz w10,Lcross_next
 cmp w8,w10
 b.ne Lcross_kind
 mov x0,x19
 fmov s0,s8
 fmov s1,s9
 fmov s2,s10
 fmov s3,s11
 bl Lray_line
 fcmp s0,#0.0
 b.lt Lcross_next
 ldr s1,[sp,#80]
 fcmp s0,s1
 b.gt Lcross_next
 mov x0,x19
 fmov s0,s8
 fmov s1,s9
 bl Lline_side
 mov w3,w0
 mov x0,x19
 mov w1,#2
 mov w2,w22
 bl Lactivate
Lcross_next:
 add x19,x19,#14
 sub w20,w20,#1
 b Lcross_loop
Lcross_end:
 ldp d10,d11,[sp,#64]
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// x0 line,s0/s1 point -> w0 front/right0 or back/left1. Leaf.
Lline_side:
 PTR x8,_doom_vertices
 ldrh w9,[x0]
 ldrh w10,[x0,#2]
 add x9,x8,w9,uxtw #2
 add x10,x8,w10,uxtw #2
 ldrsh w11,[x9]
 scvtf s2,w11
 ldrsh w11,[x9,#2]
 scvtf s3,w11
 ldrsh w11,[x10]
 scvtf s4,w11
 ldrsh w11,[x10,#2]
 scvtf s5,w11
 fsub s4,s4,s2
 fsub s5,s5,s3
 fsub s0,s0,s2
 fsub s1,s1,s3
 fmul s0,s0,s5
 fmul s1,s1,s4
 fsub s0,s0,s1
 fcmp s0,#0.0
 cset w0,lt
 ret

// Hitscan-only switches24/46/47 activate at a visible ray intersection.
// s0x,s1y,s2dx,s3dy,s4range. Stack112,x19-x22,d8-d12 preserved.
Lshoot_specials:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 stp d10,d11,[sp,#64]
 str d12,[sp,#80]
 fmov s8,s0
 fmov s9,s1
 fmov s10,s2
 fmov s11,s3
 fmov s12,s4
 PTR x19,_doom_lines
 COUNT w20,_doom_line_count
 mov x21,#0
Lshot_special_loop:
 cbz w20,Lshot_special_found
 ldrh w8,[x19,#6]
 cmp w8,#24
 b.eq Lshot_special_test
 cmp w8,#46
 b.eq Lshot_special_test
 cmp w8,#47
 b.ne Lshot_special_next
Lshot_special_test:
 mov x0,x19
 fmov s0,s8
 fmov s1,s9
 fmov s2,s10
 fmov s3,s11
 bl Lray_line
 fcmp s0,#0.0
 b.lt Lshot_special_next
 fcmp s0,s12
 b.gt Lshot_special_next
 fmov s12,s0
 mov x21,x19
Lshot_special_next:
 add x19,x19,#14
 sub w20,w20,#1
 b Lshot_special_loop
Lshot_special_found:
 cbz x21,Lshot_special_end
 mov x0,x21
 mov w1,#4
 mov w2,#-1
 mov w3,#0
 bl Lactivate
Lshot_special_end:
 ldr d12,[sp,#80]
 ldp d10,d11,[sp,#64]
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// x0 special linedef. Chooses sector by tag, or the back side for manual doors.
// Stack96; preserves x19-x24,d8,d9. Static raw sectors never change.
Lactivate:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 mov x19,x0
 str w2,[sp,#80]
 str w3,[sp,#84]
 str w1,[sp,#88]
 ldrh w20,[x19,#6]
 cmp w1,#4
 b.eq Lactivate_shot_kind
 cmp w1,#2
 b.eq Lactivate_walk_kind
 ADDR x8,_use_specials
 b Lactivate_trigger_scan
Lactivate_walk_kind:
 ADDR x8,_walk_specials
 b Lactivate_trigger_scan
Lactivate_shot_kind:
 cmp w20,#24
 b.eq Lactivate_actor_rule
 cmp w20,#46
 b.eq Lactivate_actor_rule
 cmp w20,#47
 b.ne Lactivate_end
 b Lactivate_actor_rule
Lactivate_trigger_scan:
 ldrb w9,[x8],#1
 cbz w9,Lactivate_end
 cmp w9,w20
 b.ne Lactivate_trigger_scan
Lactivate_actor_rule:
 ldr w8,[sp,#80]
 tbnz w8,#31,Lactivate_player_rule
 // Monsters use only the original small set of allowed triggers.
 cmp w20,#1
 b.eq Lactivate_rule_ok
 cmp w20,#4
 b.eq Lactivate_rule_ok
 cmp w20,#10
 b.eq Lactivate_rule_ok
 cmp w20,#88
 b.eq Lactivate_rule_ok
 cmp w20,#39
 b.eq Lactivate_rule_ok
 cmp w20,#97
 b.eq Lactivate_rule_ok
 cmp w20,#125
 b.eq Lactivate_rule_ok
 cmp w20,#126
 b.eq Lactivate_rule_ok
 cmp w20,#46
 b.ne Lactivate_end
 b Lactivate_rule_ok
Lactivate_player_rule:
 cmp w20,#125
 b.eq Lactivate_end
 cmp w20,#126
 b.eq Lactivate_end
Lactivate_rule_ok:
 cmp w20,#11
 b.eq Lactivate_exit
 cmp w20,#52
 b.eq Lactivate_exit
 cmp w20,#197
 b.eq Lactivate_exit
 cmp w20,#51
 b.eq Lactivate_secret
 cmp w20,#124
 b.eq Lactivate_secret
 cmp w20,#198
 b.eq Lactivate_secret
 // Keyed doors: blue26/32/99/133, yellow27/34/136/137, red28/33/134/135.
 mov w8,#0
 cmp w20,#26
 b.eq Lactivate_blue
 cmp w20,#32
 b.eq Lactivate_blue
 cmp w20,#99
 b.eq Lactivate_blue
 cmp w20,#133
 b.eq Lactivate_blue
 cmp w20,#27
 b.eq Lactivate_yellow
 cmp w20,#34
 b.eq Lactivate_yellow
 cmp w20,#136
 b.eq Lactivate_yellow
 cmp w20,#137
 b.eq Lactivate_yellow
 cmp w20,#28
 b.eq Lactivate_red
 cmp w20,#33
 b.eq Lactivate_red
 cmp w20,#134
 b.eq Lactivate_red
 cmp w20,#135
 b.ne Lactivate_keycheck
Lactivate_red:
 mov w8,#4
 b Lactivate_keycheck
Lactivate_blue:
 mov w8,#1
 b Lactivate_keycheck
Lactivate_yellow:
 mov w8,#2
Lactivate_keycheck:
 cbz w8,Lactivate_classify
 ADDR x9,_doom_player
 ldr w9,[x9,#44]
 tst w8,w9
 b.eq Lactivate_end
Lactivate_classify:
 // A used one-shot line remains inert. Raw records are never rewritten.
 PTR x8,_doom_lines
 sub x8,x19,x8
 mov x9,#14
 udiv x8,x8,x9
 ADDR x9,_world_line_meta
 add x9,x9,x8,lsl #3
 ldr w10,[x9]
 cbnz w10,Lactivate_end
 ldr w10,[x9,#4]
 cbnz w10,Lactivate_end
 // Explicit table: special, action1door/2floor-up/3floor-down/4lift/5light/6teleport.
 ADDR x9,_special_actions
 mov w21,#0
Lactivate_find:
 ldrh w8,[x9]
 cbz w8,Lactivate_end
 cmp w8,w20
 b.eq Lactivate_kind
 add x9,x9,#4
 b Lactivate_find
Lactivate_kind:
 ldrh w21,[x9,#2]
 cmp w21,#6
 b.eq Lactivate_teleport
 ldrh w22,[x19,#8]
 mov w23,#0
 COUNT w24,_doom_sector_count
Lactivate_sector:
 cmp w23,w24
 b.hs Lactivate_sound
 cbz w22,Lactivate_back
 PTR x8,_doom_sectors
 mov w9,#26
 madd x8,x23,x9,x8
 ldrh w8,[x8,#24]
 cmp w8,w22
 b.ne Lactivate_next
 b Lactivate_target
Lactivate_back:
 ldrh w8,[x19,#12]
 mov w9,#65535
 cmp w8,w9
 b.eq Lactivate_end
 PTR x9,_doom_sides
 mov w10,#30
 madd x8,x8,x10,x9
 ldrh w8,[x8,#28]
 cmp w8,w23
 b.ne Lactivate_next
Lactivate_target:
 cmp w21,#5
 b.eq Lactivate_light
 cmp w21,#7
 b.eq Lactivate_stairs8
 cmp w21,#8
 b.eq Lactivate_stairs16
 cmp w21,#11
 b.eq Lactivate_donut
 cmp w21,#13
 b.eq Lactivate_stop
 // Doors own their active reversal policy. Other active plane movers ignore
 // retriggers before any speed, timer, target or return height can change.
 cmp w21,#1
 b.eq Lactivate_door
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x8,x23,x9,x8
 ldr w9,[x8]
 cbnz w9,Lactivate_next
 mov w0,w23
 bl Lneighbors
 // s0 minimum neighbor ceiling, s1 min floor, s2 max floor.
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x8,x23,x9,x8
 ADDR x9,_world_floors
 ldr s8,[x9,w23,uxtw #2]
 ADDR x9,_world_ceilings
 ldr s9,[x9,w23,uxtw #2]
 fmov s3,#1.0
 str s3,[x8,#8]
 str wzr,[x8,#12]
 str wzr,[x8,#20]
 cmp w21,#9
 b.eq Lactivate_crusher
 cmp w21,#10
 b.eq Lactivate_ceiling_floor
 cmp w21,#12
 b.eq Lactivate_ceil_floor
 cmp w21,#14
 b.eq Lactivate_perpetual
 cmp w21,#3
 b.eq Lactivate_lower
 cmp w21,#4
 b.eq Lactivate_lift
 mov w0,w23
 mov w1,w20
 mov x2,x19
 bl Lfloor_action
 b Lactivate_next
Lactivate_lower:
 mov w0,w23
 mov w1,w20
 mov x2,x19
 bl Lfloor_action
 b Lactivate_next
Lactivate_lift:
 str s8,[x8,#16]
 str s1,[x8,#4]
 fmov s3,#4.0
 cmp w20,#120
 b.lt Lactivate_lift_speed
 cmp w20,#123
 b.gt Lactivate_lift_speed
 fmov s3,#8.0
Lactivate_lift_speed:
 str s3,[x8,#8]
 mov w9,#5
 str w9,[x8]
 b Lactivate_next
Lactivate_perpetual:
 str s1,[x8,#4]
 str s2,[x8,#16]
 mov w9,#10
 str w9,[x8]
 b Lactivate_next
Lactivate_crusher:
 fmov s3,#8.0
 fadd s3,s8,s3
 str s3,[x8,#4]
 str s9,[x8,#16]
 fmov s3,#1.0
 cmp w20,#6
 b.eq Lactivate_crusher_fast
 cmp w20,#77
 b.ne Lactivate_crusher_speed
Lactivate_crusher_fast:
 fmov s3,#2.0
Lactivate_crusher_speed:
 str s3,[x8,#8]
 str s3,[x8,#20]
 mov w9,#7
 str w9,[x8]
 b Lactivate_next
Lactivate_ceiling_floor:
 // Action40 opens ceiling to highest adjacent ceiling and lowers floor.
 mov w0,w23
 bl Lhighest_ceiling
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x8,x23,x9,x8
 str s0,[x8,#4]
 str s1,[x8,#16]
 mov w9,#14
 str w9,[x8]
 b Lactivate_next
Lactivate_ceil_floor:
 str s8,[x8,#4]
 cmp w20,#44
 b.eq Lactivate_ceil_crushgap
 cmp w20,#72
 b.ne Lactivate_ceil_target
Lactivate_ceil_crushgap:
 mov w9,#1
 str w9,[x8,#20]
 fmov s3,#8.0
 fadd s3,s8,s3
 str s3,[x8,#4]
Lactivate_ceil_target:
 mov w9,#9
 str w9,[x8]
 b Lactivate_next
Lactivate_stairs8:
 mov w0,w23
 mov w1,#8
 bl Lstairs
 b Lactivate_next
Lactivate_stairs16:
 mov w0,w23
 mov w1,#16
 bl Lstairs
 b Lactivate_next
Lactivate_donut:
 mov w0,w23
 bl Ldonut
 b Lactivate_next
Lactivate_stop:
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x8,x23,x9,x8
 str wzr,[x8]
 b Lactivate_next
Lactivate_door:
 mov w0,w23
 mov w1,w20
 bl Ldoor_action
 b Lactivate_next
Lactivate_light:
 mov w0,w23
 mov w1,w20
 bl Llight_action
Lactivate_next:
 add w23,w23,#1
 b Lactivate_sector
Lactivate_sound:
 mov x0,x19
 ldr w1,[sp,#88]
 bl Lswitch
 mov w0,#5
 ADDR x1,_snd_door
 bl _doom_sound
 b Lactivate_end
Lactivate_exit:
 mov w8,#1
 b Lactivate_complete
Lactivate_secret:
 mov w8,#2
Lactivate_complete:
 ADDR x9,_doom_level_complete
 str w8,[x9]
 b Lactivate_end
Lactivate_teleport:
 ldr w8,[sp,#84]
 cbnz w8,Lactivate_end
 // Destination thing14 must be in a sector with this line's tag.
 ADDR x22,_doom_actors
 COUNT w23,_doom_actor_count
 ldrh w24,[x19,#8]
Lteleport_find:
 cbz w23,Lactivate_end
 ldr w8,[x22,#24]
 cmp w8,#14
 b.ne Lteleport_next
 ldp s0,s1,[x22]
 bl _doom_point_sector
 tbnz w0,#31,Lteleport_next
 PTR x8,_doom_sectors
 mov w9,#26
 madd x8,x0,x9,x8
 ldrh w8,[x8,#24]
 cmp w8,w24
 b.ne Lteleport_next
 ADDR x8,_doom_player
 ldr w9,[sp,#80]
 tbnz w9,#31,Lteleport_entity
 ADDR x8,_doom_actors
 mov w10,#ACTOR_SIZE
 madd x8,x9,x10,x8
Lteleport_entity:
 ldp s0,s1,[x22]
 stp s0,s1,[x8]
 ldr s0,[x22,#8]
 str s0,[x8,#8]
 ldr s0,[x22,#12]
 str s0,[x8,#12]
 ldr w9,[sp,#80]
 tbz w9,#31,Lteleport_mark
 str w0,[x8,#48]
Lteleport_mark:
 mov x0,x19
 mov w1,#2
 bl Lswitch
 b Lactivate_end
Lteleport_next:
 add x22,x22,#ACTOR_SIZE
 sub w23,w23,#1
 b Lteleport_find
Lactivate_end:
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// w0 sector -> s0 lowest adjacent ceiling,s1 lowest floor,s2 highest floor.
// Leaf. Bounds derive from validated map line/side indices. x8-x17,v0-v7 changed.
Lneighbors:
 ADDR x8,_world_ceilings
 ldr s4,[x8,w0,uxtw #2]
 mov w9,#32767
 scvtf s0,w9
 scvtf s3,w9
 ADDR x8,_world_floors
 ldr s1,[x8,w0,uxtw #2]
 fmov s6,s1
 mov w9,#-32768
 scvtf s2,w9
 PTR x8,_doom_lines
 COUNT w9,_doom_line_count
 PTR x10,_doom_sides
Lneighbor_line:
 cbz w9,Lneighbor_done
 ldrh w11,[x8,#10]
 ldrh w12,[x8,#12]
 mov w13,#65535
 cmp w11,w13
 b.eq Lneighbor_next
 cmp w12,w13
 b.eq Lneighbor_next
 mov w13,#30
 madd x11,x11,x13,x10
 madd x12,x12,x13,x10
 ldrh w11,[x11,#28]
 ldrh w12,[x12,#28]
 cmp w11,w0
 b.eq Lneighbor_use12
 cmp w12,w0
 b.ne Lneighbor_next
 b Lneighbor_use11
Lneighbor_use12:
 mov w11,w12
Lneighbor_use11:
 cmp w11,w0
 b.eq Lneighbor_next
 ADDR x13,_world_ceilings
 ldr s5,[x13,w11,uxtw #2]
 fmin s0,s0,s5
 fmax s4,s4,s5
 ADDR x13,_world_floors
 ldr s5,[x13,w11,uxtw #2]
 fmin s1,s1,s5
 fmax s2,s2,s5
 fcmp s5,s6
 b.le Lneighbor_next
 fmin s3,s3,s5
Lneighbor_next:
 add x8,x8,#14
 sub w9,w9,#1
 b Lneighbor_line
Lneighbor_done:
 mov w9,#32767
 scvtf s5,w9
 fcmp s3,s5
 fcsel s3,s6,s3,eq
 mov w9,#-32768
 scvtf s5,w9
 fcmp s2,s5
 fcsel s2,s6,s2,eq
 ret
Lhighest_ceiling:
 stp x29,x30,[sp,#-16]!
 bl Lneighbors
 fmov s0,s4
 ldp x29,x30,[sp],#16
 ret

// Tick movers. Types0idle,1doorup,2flooronce,3doordown,4doorwait,
//5liftdown,6liftwait,7crusherdown,8crusherup,9ceilingonce,10platform,
//11platformwait,12doorclose30,13door30wait. Stack176, x19-x28,d8-d12 saved.
Lsectors_tick:
 stp x29,x30,[sp,#-176]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp x25,x26,[sp,#64]
 stp x27,x28,[sp,#80]
 stp d8,d9,[sp,#96]
 stp d10,d11,[sp,#112]
 str d12,[sp,#128]
 bl Lbuttons_tick
 mov w19,#0
 COUNT w20,_doom_sector_count
 ADDR x21,_world_movers
 ADDR x22,_world_floors
 ADDR x23,_world_ceilings
Lsector_tick_loop:
 cmp w19,w20
 b.hs Lsector_tick_end
 ldr w24,[x21]
 cbz w24,Lsector_light_update
 cmp w24,#14
 b.eq Lsector_combined
 cmp w24,#4
 b.eq Lsector_wait_mode
 cmp w24,#6
 b.eq Lsector_wait_mode
 cmp w24,#11
 b.eq Lsector_wait_mode
 cmp w24,#13
 b.eq Lsector_wait_mode
 ldr s8,[x22,w19,uxtw #2]
 ldr s9,[x23,w19,uxtw #2]
 ldr s10,[x21,#4]
 ldr s11,[x21,#8]
 mov w25,#0
 cmp w24,#2
 b.eq Lsector_floor_mode
 cmp w24,#5
 b.eq Lsector_floor_mode
 cmp w24,#10
 b.eq Lsector_floor_mode
 mov w25,#1
 fmov s12,s9
 b Lsector_step_toward
Lsector_floor_mode:
 fmov s12,s8
Lsector_step_toward:
 fcmp s12,s10
 b.gt Lsector_step_down
 fadd s12,s12,s11
 fmin s12,s12,s10
 b Lsector_check_bodies
Lsector_step_down:
 fsub s12,s12,s11
 fmax s12,s12,s10
Lsector_check_bodies:
 mov w26,#0
 cmp w24,#7
 b.eq Lsector_crush_mode
 cmp w24,#9
 b.eq Lsector_ceiling_crush_mode
 cmp w24,#2
 b.ne Lsector_check_normal
 ldr w26,[x21,#20]
 b Lsector_check_normal
Lsector_crush_mode:
 mov w26,#1
 b Lsector_check_normal
Lsector_ceiling_crush_mode:
 ldr w26,[x21,#20]
Lsector_check_normal:
 mov w0,w19
 mov w1,w26
 fmov s0,s8
 fmov s1,s9
 cbnz w25,Lsector_check_ceiling
 fmov s0,s12
 b Lsector_check_call
Lsector_check_ceiling:
 fmov s1,s12
Lsector_check_call:
 fmov s2,s8
 bl Lsector_occupied
 cbz w0,Lsector_store_new
 cbnz w26,Lsector_crushed
 cmp w24,#3
 b.eq Lsector_reopen
 cmp w24,#12
 b.eq Lsector_reopen
 b Lsector_light_update
Lsector_reopen:
 cmp w24,#12
 b.ne Lsector_reopen_target
 str wzr,[x21,#20]
Lsector_reopen_target:
 ldr s0,[x21,#16]
 str s0,[x21,#4]
 mov w8,#1
 str w8,[x21]
 b Lsector_light_update
Lsector_crushed:
 cmp w24,#7
 b.ne Lsector_store_new
 ldr s0,[x21,#20]
 fmov s1,#1.0
 fcmp s0,s1
 b.ne Lsector_store_new
 fmov s0,#0.125
 str s0,[x21,#8]
Lsector_store_new:
 cbnz w25,Lsector_store_ceiling
 str s12,[x22,w19,uxtw #2]
 mov w0,w19
 fmov s0,s8
 fmov s1,s12
 bl Lsector_carry
 b Lsector_reached
Lsector_store_ceiling:
 str s12,[x23,w19,uxtw #2]
Lsector_reached:
 fcmp s12,s10
 b.ne Lsector_light_update
 cmp w24,#1
 b.eq Lsector_open_reached
 cmp w24,#5
 b.eq Lsector_lift_reached
 cmp w24,#7
 b.eq Lsector_crusher_up
 cmp w24,#8
 b.eq Lsector_crusher_down
 cmp w24,#10
 b.eq Lsector_platform_reached
 cmp w24,#12
 b.eq Lsector_close30_reached
 str wzr,[x21]
 b Lsector_light_update
Lsector_open_reached:
 ldr w8,[x21,#20]
 cbz w8,Lsector_stop
 str w8,[x21,#12]
 mov w8,#4
 str w8,[x21]
 b Lsector_light_update
Lsector_lift_reached:
 mov w8,#6
 str w8,[x21]
 mov w8,#105
 str w8,[x21,#12]
 b Lsector_light_update
Lsector_crusher_up:
 ldr s0,[x21,#16]
 str s0,[x21,#4]
 ldr s0,[x21,#20]
 str s0,[x21,#8]
 mov w8,#8
 str w8,[x21]
 b Lsector_light_update
Lsector_crusher_down:
 fmov s0,#8.0
 fadd s0,s0,s8
 str s0,[x21,#4]
 ldr s0,[x21,#20]
 str s0,[x21,#8]
 mov w8,#7
 str w8,[x21]
 b Lsector_light_update
Lsector_platform_reached:
 ldr s0,[x21,#16]
 str s0,[x21,#4]
 str s10,[x21,#16]
 mov w8,#11
 str w8,[x21]
 mov w8,#105
 str w8,[x21,#12]
 b Lsector_light_update
Lsector_close30_reached:
 mov w8,#13
 str w8,[x21]
 mov w8,#1050
 str w8,[x21,#12]
 b Lsector_light_update
Lsector_combined:
 ldr s8,[x22,w19,uxtw #2]
 ldr s9,[x23,w19,uxtw #2]
 ldr s10,[x21,#4]
 ldr s11,[x21,#16]
 ldr s0,[x21,#8]
 fadd s9,s9,s0
 fmin s9,s9,s10
 fsub s12,s8,s0
 fmax s12,s12,s11
 str s9,[x23,w19,uxtw #2]
 str s12,[x22,w19,uxtw #2]
 mov w0,w19
 fmov s0,s8
 fmov s1,s12
 bl Lsector_carry
 fcmp s9,s10
 b.ne Lsector_light_update
 fcmp s12,s11
 b.ne Lsector_light_update
 str wzr,[x21]
 b Lsector_light_update
Lsector_wait_mode:
 ldr w8,[x21,#12]
 subs w8,w8,#1
 str w8,[x21,#12]
 b.gt Lsector_light_update
 cmp w24,#4
 b.eq Lsector_wait_close
 cmp w24,#6
 b.eq Lsector_wait_raise
 cmp w24,#11
 b.eq Lsector_wait_platform
 // Door close30 waits then opens without another closing cycle.
 ldr s0,[x21,#16]
 str s0,[x21,#4]
 str wzr,[x21,#20]
 mov w8,#1
 str w8,[x21]
 b Lsector_light_update
Lsector_wait_close:
 ldr s0,[x22,w19,uxtw #2]
 str s0,[x21,#4]
 mov w8,#3
 str w8,[x21]
 b Lsector_light_update
Lsector_wait_raise:
 ldr s0,[x21,#16]
 str s0,[x21,#4]
 mov w8,#2
 str w8,[x21]
 b Lsector_light_update
Lsector_wait_platform:
 mov w8,#10
 str w8,[x21]
 b Lsector_light_update
Lsector_stop:
 str wzr,[x21]
Lsector_light_update:
 mov w0,w19
 bl Llight_tick
 add x21,x21,#MOVER_SIZE
 add w19,w19,#1
 b Lsector_tick_loop
Lsector_tick_end:
 ldr d12,[sp,#128]
 ldp d10,d11,[sp,#112]
 ldp d8,d9,[sp,#96]
 ldp x27,x28,[sp,#80]
 ldp x25,x26,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#176
 ret

// w0 sector,s0 proposedfloor,s1 ceiling,s2 oldfloor,w1crush ->w0 occupied.
// Check player and solid actors before normal motion. Crusher damage10/4tics.
// Stack128,x19-x25,d8-d11 preserved. Each actor sector lookup is bounded.
Lsector_occupied:
 stp x29,x30,[sp,#-128]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 str x25,[sp,#64]
 stp d8,d9,[sp,#80]
 stp d10,d11,[sp,#96]
 mov w19,w0
 mov w20,w1
 fmov s8,s0
 fmov s9,s1
 fmov s10,s2
 mov w23,#0
 ADDR x21,_doom_player
 ldr w8,[x21,#16]
 cmp w8,#0
 b.le Loccupied_actors
 ldr w8,[x21,#48]
 cmp w8,w19
 b.ne Loccupied_actors
 ldr s0,[x21,#8]
 fcmp s0,s10
 fcsel s0,s8,s0,le
 fmax s0,s0,s8
 mov w8,#56
 scvtf s1,w8
 fadd s0,s0,s1
 fcmp s0,s9
 b.le Loccupied_actors
 mov w23,#1
 cbz w20,Loccupied_actors
 COUNT w8,_doom_tic
 tst w8,#3
 b.ne Loccupied_actors
 mov w0,#10
 bl Ldamage_player
Loccupied_actors:
 ADDR x21,_doom_actors
 COUNT w22,_doom_actor_count
Loccupied_loop:
 cbz w22,Loccupied_end
 ldr w8,[x21,#32]
 tbz w8,#0,Loccupied_next
 tbnz w8,#6,Loccupied_next
 ldp s0,s1,[x21]
 bl _doom_point_sector
 cmp w0,w19
 b.ne Loccupied_next
 ldr s0,[x21,#8]
 fcmp s0,s10
 fcsel s0,s8,s0,le
 fmax s0,s0,s8
 ldr s1,[x21,#20]
 fadd s0,s0,s1
 fcmp s0,s9
 b.le Loccupied_next
 mov w23,#1
 cbz w20,Loccupied_next
 COUNT w8,_doom_tic
 tst w8,#3
 b.ne Loccupied_next
 ldr w8,[x21,#32]
 tbz w8,#1,Loccupied_remove
 mov x0,x21
 mov w1,#10
 bl Ldamage_actor
 b Loccupied_next
Loccupied_remove:
 mov w8,#64
 str w8,[x21,#32]
Loccupied_next:
 add x21,x21,#ACTOR_SIZE
 sub w22,w22,#1
 b Loccupied_loop
Loccupied_end:
 mov w0,w23
 ldp d10,d11,[sp,#96]
 ldp d8,d9,[sp,#80]
 ldr x25,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#128
 ret

// w0 sector,s0 oldfloor,s1 newfloor. Carry standing bodies in both directions.
// Stack80,x19-x22,d8,d9 preserved.
Lsector_carry:
 stp x29,x30,[sp,#-80]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 mov w19,w0
 fmov s8,s0
 fmov s9,s1
 ADDR x20,_doom_player
 ldr w8,[x20,#48]
 cmp w8,w19
 b.ne Lcarry_actors
 ADDR x8,_world_player_floor
 str s9,[x8]
 ldr s0,[x20,#8]
 fcmp s0,s8
 b.gt Lcarry_actors
 str s9,[x20,#8]
Lcarry_actors:
 ADDR x20,_doom_actors
 COUNT w21,_doom_actor_count
Lcarry_actor:
 cbz w21,Lcarry_end
 ldr w8,[x20,#32]
 tbnz w8,#6,Lcarry_next
 ldr s0,[x20,#8]
 fcmp s0,s8
 b.gt Lcarry_next
 ldp s0,s1,[x20]
 bl _doom_point_sector
 cmp w0,w19
 b.ne Lcarry_next
 str s9,[x20,#8]
Lcarry_next:
 add x20,x20,#ACTOR_SIZE
 sub w21,w21,#1
 b Lcarry_actor
Lcarry_end:
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#80
 ret

// Revert momentary switch materials after35tics. Stack48,x19-x21 preserved.
Lbuttons_tick:
 stp x29,x30,[sp,#-48]!
 stp x19,x20,[sp,#16]
 str x21,[sp,#32]
 PTR x19,_doom_lines
 COUNT w20,_doom_line_count
 ADDR x21,_world_line_meta
Lbutton_loop:
 cbz w20,Lbutton_end
 ldr w8,[x21,#4]
 cbz w8,Lbutton_next
 subs w8,w8,#1
 str w8,[x21,#4]
 b.ne Lbutton_next
 mov x0,x19
 mov w1,#1
 bl Lswitch
 str wzr,[x21,#4]
Lbutton_next:
 add x19,x19,#14
 add x21,x21,#8
 sub w20,w20,#1
 b Lbutton_loop
Lbutton_end:
 ldr x21,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#48
 ret

// w0 sector -> neighbor raw light minimum w0 and maximum w1. Leaf.
Llight_neighbors:
 mov w15,w0
 PTR x8,_doom_lines
 COUNT w9,_doom_line_count
 PTR x10,_doom_sides
 PTR x14,_doom_sectors
 mov w13,#26
 madd x13,x15,x13,x14
 ldrh w0,[x13,#20]
 mov w1,#0
Llight_neighbor:
 cbz w9,Llight_neighbor_end
 ldrh w11,[x8,#10]
 ldrh w12,[x8,#12]
 mov w13,#65535
 cmp w11,w13
 b.eq Llight_neighbor_next
 cmp w12,w13
 b.eq Llight_neighbor_next
 mov w13,#30
 madd x11,x11,x13,x10
 madd x12,x12,x13,x10
 ldrh w11,[x11,#28]
 ldrh w12,[x12,#28]
 cmp w11,w15
 b.eq Llight_use_back
 cmp w12,w15
 b.ne Llight_neighbor_next
 mov w12,w11
Llight_use_back:
 mov w13,#26
 madd x12,x12,x13,x14
 ldrh w12,[x12,#20]
 cmp w12,w0
 csel w0,w12,w0,lo
 cmp w12,w1
 csel w1,w12,w1,hi
Llight_neighbor_next:
 add x8,x8,#14
 sub w9,w9,#1
 b Llight_neighbor
Llight_neighbor_end:
 ret

// w0 sector,w1 light special. Numeric levels and neighbor bounds follow
// the original trigger variants;17 starts a strobe without moving a plane.
// Stack48,x19-x21 preserved.
Llight_action:
 stp x29,x30,[sp,#-48]!
 stp x19,x20,[sp,#16]
 str x21,[sp,#32]
 mov w19,w0
 mov w20,w1
 bl Llight_neighbors
 mov w21,#255
 cmp w20,#12
 b.eq Llight_action_bright
 cmp w20,#80
 b.eq Llight_action_bright
 cmp w20,#35
 b.eq Llight_action_dark35
 cmp w20,#79
 b.eq Llight_action_dark35
 cmp w20,#104
 b.eq Llight_action_dark
 cmp w20,#139
 b.eq Llight_action_dark
 b Llight_action_store
Llight_action_bright:
 mov w21,w1
 b Llight_action_store
Llight_action_dark35:
 mov w21,#35
 b Llight_action_store
Llight_action_dark:
 mov w21,w0
Llight_action_store:
 ADDR x8,_world_sector_meta
 add x8,x8,w19,uxtw #4
 str wzr,[x8,#8]
 cmp w20,#17
 b.ne Llight_action_level
 mov w9,#3
 str w9,[x8,#8]
 b Llight_action_end
Llight_action_level:
 ADDR x8,_world_lights
 str w21,[x8,w19,uxtw #2]
Llight_action_end:
 ldr x21,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#48
 ret

// w0 sector. Stateful light flashing/strobes/glow/fire using sector metadata.
// Stack64,x19-x22 preserved. Fade boundaries use adjacent minimum and raw max.
Llight_tick:
 stp x29,x30,[sp,#-64]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 mov w19,w0
 ADDR x20,_world_sector_meta
 add x20,x20,w19,uxtw #4
 ldr w21,[x20,#8]
 cmp w21,#1
 b.eq Llight_effect
 cmp w21,#2
 b.eq Llight_effect
 cmp w21,#3
 b.eq Llight_effect
 cmp w21,#4
 b.eq Llight_effect
 cmp w21,#8
 b.eq Llight_effect
 cmp w21,#12
 b.eq Llight_effect
 cmp w21,#13
 b.eq Llight_effect
 cmp w21,#17
 b.ne Llight_end
Llight_effect:
 bl Llight_neighbors
 mov w22,w0
 PTR x8,_doom_sectors
 mov w9,#26
 madd x8,x19,x9,x8
 ldrh w9,[x8,#20]
 ADDR x10,_world_lights
 add x10,x10,w19,uxtw #2
 cmp w21,#8
 b.eq Llight_glow
 cmp w21,#1
 b.eq Llight_flash
 cmp w21,#17
 b.eq Llight_fire
 COUNT w8,_doom_tic
 cmp w21,#12
 b.eq Llight_slow
 cmp w21,#3
 b.eq Llight_slow_offset
 mov w11,#20
 b Llight_period
Llight_slow_offset:
 add w8,w8,w19
Llight_slow:
 mov w11,#40
Llight_period:
 udiv w12,w8,w11
 msub w8,w12,w11,w8
 cmp w8,#5
 csel w9,w9,w22,lo
 str w9,[x10]
 b Llight_end
Llight_glow:
 ldr w8,[x20,#12]
 ldr w11,[x10]
 cbnz w8,Llight_glow_up
 sub w11,w11,#8
 cmp w11,w22
 b.gt Llight_glow_store
 mov w8,#1
 str w8,[x20,#12]
 mov w11,w22
 b Llight_glow_store
Llight_glow_up:
 add w11,w11,#8
 cmp w11,w9
 b.lt Llight_glow_store
 str wzr,[x20,#12]
 mov w11,w9
Llight_glow_store:
 str w11,[x10]
 b Llight_end
Llight_flash:
 COUNT w8,_doom_tic
 eor w8,w8,w19,lsl #2
 tst w8,#7
 b.ne Llight_end
 tst w8,#16
 csel w9,w9,w22,eq
 str w9,[x10]
 b Llight_end
Llight_fire:
 COUNT w8,_doom_tic
 tst w8,#3
 b.ne Llight_end
 eor w8,w8,w19
 and w8,w8,#3
 sub w9,w9,w8,lsl #4
 add w22,w22,#16
 cmp w9,w22
 csel w9,w9,w22,gt
 mov w11,#255
 cmp w9,w11
 csel w9,w9,w11,lo
 str w9,[x10]
Llight_end:
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#64
 ret

// Save v2:128-byte header; player128; actors80*n; sector arrays53*n,
// side materials32*n; line state8*n. Maximum serialized capacity is4MiB.
// Sector arrays contain planes, lights, movers, secrets and floor metadata.
// FNV1a detects corruption;
// it is not authentication. New saves use a private temporary file and link
// publication. A valid owned save can be replaced after a repeated identity
// check. Private0700 parent directories prevent other-user path swaps. The
// final lstat/rename pair does not claim protection from same-user races.
// x0 path NUL <=1000 bytes. w0 0/-1. Stack112, preserves x19-x26.
FUNC doom_world_save
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp x25,x26,[sp,#64]
 mov x19,x0
 mov x20,#-1
 mov w26,#0
 mov x1,#1001
 bl _strnlen
 cmp x0,#1000
 b.hi Lsave_fail
 cbz x0,Lsave_fail
 mov x21,x0
 mov x0,x19
 bl Lsave_destination
 tbnz w0,#31,Lsave_fail
 str w0,[sp,#88]
 str w2,[sp,#92]
 str x1,[sp,#96]
 ADDR x0,_save_path
 mov x1,x19
 mov x2,x21
 bl _memcpy
 ADDR x8,_save_path
 add x8,x8,x21
 ADDR x9,_temp_suffix
 ldr x10,[x9]
 str x10,[x8]
 ldr w10,[x9,#8]
 str w10,[x8,#8]
 // Header initializes every reserved byte before hashing.
 ADDR x0,_save_stage
 mov x1,#128
 bl _bzero
 ADDR x21,_save_stage
 ADDR x8,_save_magic
 ldr x8,[x8]
 str x8,[x21]
 mov w8,#2
 str w8,[x21,#8]
 COUNT w22,_doom_actor_count
 str w22,[x21,#16]
 COUNT w23,_doom_sector_count
 str w23,[x21,#20]
 COUNT w8,_doom_tic
 str w8,[x21,#24]
 COUNT w8,_doom_skill
 str w8,[x21,#28]
 ADDR x8,_world_map
 ldr x8,[x8]
 str x8,[x21,#32]
 COUNT w8,_doom_level_complete
 str w8,[x21,#44]
 COUNT w8,_world_rng
 str w8,[x21,#48]
 COUNT w8,_world_suit
 str w8,[x21,#52]
 COUNT w8,_world_invul
 str w8,[x21,#56]
 COUNT w8,_doom_side_count
 str w8,[x21,#64]
 COUNT w8,_doom_line_count
 str w8,[x21,#68]
 ADDR x0,_world_map
 bl Lmap_fingerprint
 str w0,[x21,#72]
 COUNT w8,_world_vertical
 str w8,[x21,#76]
 COUNT w8,_world_buttons
 str w8,[x21,#80]
 add x0,x21,#84
 ADDR x1,_world_combat_state
 mov x2,#28
 bl _memcpy
 ADDR x8,_world_momentum
 ldr x9,[x8]
 str x9,[x21,#112]
 COUNT w8,_world_player_floor
 str w8,[x21,#120]
 add x24,x21,#128
 mov x0,x24
 ADDR x1,_doom_player
 mov x2,#128
 bl _memcpy
 add x24,x24,#128
 mov x0,x24
 ADDR x1,_doom_actors
 mov w8,#ACTOR_SIZE
 mul w25,w22,w8
 mov w2,w25
 bl _memcpy
 add x24,x24,x25
 mov x0,x24
 ADDR x1,_world_floors
 lsl w2,w23,#2
 bl _memcpy
 add x24,x24,x23,lsl #2
 mov x0,x24
 ADDR x1,_world_ceilings
 lsl w2,w23,#2
 bl _memcpy
 add x24,x24,x23,lsl #2
 mov x0,x24
 ADDR x1,_world_lights
 lsl w2,w23,#2
 bl _memcpy
 add x24,x24,x23,lsl #2
 mov x0,x24
 ADDR x1,_world_movers
 mov w8,#MOVER_SIZE
 mul w25,w23,w8
 mov w2,w25
 bl _memcpy
 add x24,x24,x25
 mov x0,x24
 ADDR x1,_world_seen_secrets
 mov w2,w23
 bl _memcpy
 add x24,x24,x23
 mov x0,x24
 ADDR x1,_world_sector_meta
 lsl w2,w23,#4
 bl _memcpy
 add x24,x24,x23,lsl #4
 mov x0,x24
 ADDR x1,_world_side_meta
 COUNT w25,_doom_side_count
 lsl w2,w25,#5
 bl _memcpy
 add x24,x24,x25,lsl #5
 mov x0,x24
 ADDR x1,_world_line_meta
 COUNT w25,_doom_line_count
 lsl w2,w25,#3
 bl _memcpy
 add x24,x24,x25,lsl #3
 sub x24,x24,x21
 str w24,[x21,#12]
 mov x0,x21
 mov x1,x24
 bl Lchecksum
 str w0,[x21,#40]
 ADDR x0,_save_path
 bl _mkstemp
 tbnz w0,#31,Lsave_fail
 mov w20,w0
 mov w26,#1
 mov x22,x21
 mov x23,x24
Lsave_write:
 cbz x23,Lsave_sync
 mov w0,w20
 mov x1,x22
 mov x2,x23
 bl _write
 cmp x0,#0
 b.gt Lsave_written
 b.eq Lsave_fail
 bl ___error
 ldr w8,[x0]
 cmp w8,#4
 b.eq Lsave_write
 b Lsave_fail
Lsave_written:
 add x22,x22,x0
 sub x23,x23,x0
 b Lsave_write
Lsave_sync:
 mov w0,w20
 bl _fsync
 cbnz w0,Lsave_fail
 mov w0,w20
 bl _close
 mov x20,#-1
 cbnz w0,Lsave_fail
 ldr w8,[sp,#88]
 cbnz w8,Lsave_replace
 ADDR x0,_save_path
 mov x1,x19
 bl _link
 cbnz w0,Lsave_fail
 b Lsave_published
Lsave_replace:
 mov x0,x19
 bl Lsave_destination
 cmp w0,#1
 b.ne Lsave_fail
 ldr x8,[sp,#96]
 cmp x1,x8
 b.ne Lsave_fail
 ldr w8,[sp,#92]
 cmp w2,w8
 b.ne Lsave_fail
 ADDR x0,_save_path
 mov x1,x19
 bl _rename
 cbnz w0,Lsave_fail
Lsave_published:
 ADDR x0,_save_path
 bl _unlink
 mov w0,#0
 b Lsave_return
Lsave_fail:
 cmp x20,#0
 b.lt Lsave_unlink
 mov w0,w20
 bl _close
Lsave_unlink:
 cbz w26,Lsave_error
 ADDR x0,_save_path
 bl _unlink
Lsave_error:
 mov w0,#-1
Lsave_return:
 ldp x25,x26,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// x0 path -> w0 0/-1. Validate all bytes before world/map replacement.
// Open refuses final symlink and nonregular files. Read/write retry EINTR.
// Stack384;x19-x28 preserved. Staging capacity4MiB is owned by this module.
FUNC doom_world_restore
 mov w1,#1
 b Lload_world
Lload_world:
 stp x29,x30,[sp,#-384]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp x25,x26,[sp,#64]
 stp x27,x28,[sp,#80]
 str w1,[sp,#96]
 mov w1,#0x104 // Darwin O_NOFOLLOW | O_NONBLOCK | O_RDONLY
 bl _open
 tbnz w0,#31,Lrestore_fail_nofd
 mov w19,w0
 add x1,sp,#112
 bl _fstat
 cbnz w0,Lrestore_close_fail
 ldrh w8,[sp,#116] // Darwin struct stat.st_mode
 and w8,w8,#0xf000
 cmp w8,#0x8000
 b.ne Lrestore_close_fail
 ldr x20,[sp,#208] // Darwin struct stat.st_size at96
 cmp x20,#256
 b.lo Lrestore_close_fail
 mov x8,#64
 lsl x8,x8,#16
 cmp x20,x8
 b.hi Lrestore_close_fail
 ADDR x21,_save_stage
 mov x22,x21
 mov x23,x20
Lrestore_read:
 cbz x23,Lrestore_eof
 mov w0,w19
 mov x1,x22
 mov x2,x23
 bl _read
 cmp x0,#0
 b.gt Lrestore_readbytes
 b.eq Lrestore_close_fail
 bl ___error
 ldr w8,[x0]
 cmp w8,#4
 b.eq Lrestore_read
 b Lrestore_close_fail
Lrestore_readbytes:
 add x22,x22,x0
 sub x23,x23,x0
 b Lrestore_read
Lrestore_eof:
 mov w0,w19
 add x1,sp,#104
 mov x2,#1
 bl _read
 cbnz x0,Lrestore_close_fail
 mov w0,w19
 bl _close
 mov w19,#-1
 ADDR x8,_save_magic
 ldr x8,[x8]
 ldr x9,[x21]
 cmp x8,x9
 b.ne Lrestore_fail_nofd
 ldr w8,[x21,#8]
 cmp w8,#2
 b.ne Lrestore_fail_nofd
 ldr w8,[x21,#12]
 cmp x8,x20
 b.ne Lrestore_fail_nofd
 ldr w22,[x21,#16]
 cmp w22,#MAX_ACTORS
 b.hi Lrestore_fail_nofd
 ldr w23,[x21,#20]
 cbz w23,Lrestore_fail_nofd
 cmp w23,#MAX_SECTORS
 b.hi Lrestore_fail_nofd
 mov w8,#80
 mul w8,w22,w8
 mov w9,#53
 madd w8,w23,w9,w8
 ldr w9,[x21,#64]
 cbz w9,Lrestore_fail_nofd
 cmp w9,#MAX_SECTORS
 b.hi Lrestore_fail_nofd
 add w8,w8,w9,lsl #5
 ldr w9,[x21,#68]
 cbz w9,Lrestore_fail_nofd
 cmp w9,#MAX_SECTORS
 b.hi Lrestore_fail_nofd
 add w8,w8,w9,lsl #3
 add w8,w8,#256
 cmp x8,x20
 b.ne Lrestore_fail_nofd
 ldr w24,[x21,#40]
 str wzr,[x21,#40]
 mov x0,x21
 mov x1,x20
 bl Lchecksum
 str w24,[x21,#40]
 cmp w0,w24
 b.ne Lrestore_fail_nofd
 ldr w8,[x21,#28]
 sub w8,w8,#1
 cmp w8,#4
 b.hi Lrestore_fail_nofd
 ldr w8,[x21,#44]
 cmp w8,#2
 b.hi Lrestore_fail_nofd
 ldr w8,[x21,#52]
 cmp w8,#2100
 b.hi Lrestore_fail_nofd
 ldr w8,[x21,#56]
 cmp w8,#1050
 b.hi Lrestore_fail_nofd
 ldrb w8,[x21,#32]
 cmp w8,#69
 b.ne Lrestore_fail_nofd
 ldrb w8,[x21,#33]
 sub w8,w8,#49
 cmp w8,#3
 b.hi Lrestore_fail_nofd
 ldrb w8,[x21,#34]
 cmp w8,#77
 b.ne Lrestore_fail_nofd
 ldrb w8,[x21,#35]
 sub w8,w8,#49
 cmp w8,#8
 b.hi Lrestore_fail_nofd
 ldr w8,[x21,#36]
 cbnz w8,Lrestore_fail_nofd
 // Validate player coordinates, inventory and cached sector.
 add x24,x21,#128
 mov x0,x24
 mov w1,#4
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 ldr w8,[x24,#16]
 cmp w8,#200
 b.hi Lrestore_fail_nofd
 ldr w8,[x24,#20]
 cmp w8,#200
 b.hi Lrestore_fail_nofd
 mov w10,#24
Lrestore_ammo:
 ldr w8,[x24,w10,uxtw]
 cmp w8,#1000
 b.hi Lrestore_fail_nofd
 add w10,w10,#4
 cmp w10,#40
 b.lo Lrestore_ammo
 ldr w8,[x24,#40]
 sub w8,w8,#1
 cmp w8,#6
 b.hi Lrestore_fail_nofd
 ldr w8,[x24,#44]
 cmp w8,#7
 b.hi Lrestore_fail_nofd
 ldr w8,[x24,#48]
 cmp w8,w23
 b.hs Lrestore_fail_nofd
 ldr s0,[x24,#52]
 fcmp s0,s0
 b.vs Lrestore_fail_nofd
 fmov s1,#1.0
 fcmp s0,s1
 b.lt Lrestore_fail_nofd
 mov w8,#64
 scvtf s1,w8
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
 add x25,x24,#128
 mov w26,#0
Lrestore_actor:
 cmp w26,w22
 b.hs Lrestore_sector_values
 mov x0,x25
 mov w1,#6
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 ldr s0,[x25,#16]
 fcmp s0,#0.0
 b.le Lrestore_fail_nofd
 ldr s0,[x25,#20]
 fcmp s0,#0.0
 b.lt Lrestore_fail_nofd
 ldr w8,[x25,#32]
 tst w8,#0xffffff80
 b.ne Lrestore_fail_nofd
 ldr s0,[x25,#16]
 ldr s1,[x25,#20]
 mov w9,#256
 scvtf s2,w9
 fcmp s0,s2
 b.gt Lrestore_fail_nofd
 fcmp s1,s2
 b.gt Lrestore_fail_nofd
 ldr w8,[x25,#28]
 mov w9,#10000
 cmp w8,w9
 b.gt Lrestore_fail_nofd
 neg w9,w9
 cmp w8,w9
 b.lt Lrestore_fail_nofd
 ldr w8,[x25,#44]
 cmp w8,#-1
 b.eq Lrestore_actor_target_ok
 cmp w8,w22
 b.hi Lrestore_fail_nofd
Lrestore_actor_target_ok:
 ldr w8,[x25,#36]
 cmp w8,#4
 b.hi Lrestore_fail_nofd
 ldr w9,[x25,#40]
 cmp w9,#-1
 b.lt Lrestore_fail_nofd
 mov w10,#10000
 cmp w9,w10
 b.gt Lrestore_fail_nofd
 cmp w8,#2
 b.eq Lrestore_actor_state_table
 cmp w8,#3
 b.eq Lrestore_actor_state_table
 cmp w8,#4
 b.eq Lrestore_actor_charge
 cmp w9,#-1
 b.eq Lrestore_fail_nofd
 b Lrestore_actor_projectile
Lrestore_actor_state_table:
 ldr w0,[x25,#24]
 bl Lmonster_meta
 cbz x0,Lrestore_fail_nofd
 ldr w8,[x25,#36]
 cmp w8,#3
 b.eq Lrestore_actor_death_count
 ldr w9,[x0,#24]
 ldr x10,[x0,#16]
 b Lrestore_actor_state_index
Lrestore_actor_death_count:
 ldr w9,[x0,#28]
 ldr x10,[x0,#32]
Lrestore_actor_state_index:
 ldr w8,[x25,#76]
 cmp w8,w9
 b.hs Lrestore_fail_nofd
 cbz x10,Lrestore_fail_nofd
 ldr w9,[x25,#40]
 cmp w9,#-1
 b.ne Lrestore_actor_projectile
 add x10,x10,w8,uxtw #4
 ldr w8,[x10,#4]
 cmp w8,#-1
 b.ne Lrestore_fail_nofd
 b Lrestore_actor_projectile
Lrestore_actor_charge:
 ldr w8,[x25,#24]
 cmp w8,#3006
 b.ne Lrestore_fail_nofd
 add x0,x25,#68
 mov w1,#3
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 ldp s0,s1,[x25,#68]
 ldr s2,[x25,#76]
 fabs s0,s0
 fabs s1,s1
 fabs s2,s2
 mov w8,#256
 scvtf s3,w8
 fcmp s0,s3
 b.gt Lrestore_fail_nofd
 fcmp s1,s3
 b.gt Lrestore_fail_nofd
 fcmp s2,s3
 b.gt Lrestore_fail_nofd
Lrestore_actor_projectile:
 ldr w8,[x25,#24]
 cmp w8,#0
 b.ge Lrestore_actor_valid
 cmn w8,#7
 b.lt Lrestore_fail_nofd
 cmn w8,#4
 b.eq Lrestore_fail_nofd
 ldr w8,[x25,#76]
 and w8,w8,#65535
 mov w9,#65535
 cmp w8,w9
 b.eq Lrestore_actor_valid
 cmp w8,w22
 b.hs Lrestore_fail_nofd
Lrestore_actor_valid:
 add x25,x25,#ACTOR_SIZE
 add w26,w26,#1
 b Lrestore_actor
Lrestore_sector_values:
 // x25 floors; floors and ceilings are finite and remain ordered.
 add x26,x25,x23,lsl #2
 add x27,x26,x23,lsl #2
 mov w28,#0
Lrestore_heights:
 cmp w28,w23
 b.hs Lrestore_mover_values
 ldr s0,[x25,w28,uxtw #2]
 ldr s1,[x26,w28,uxtw #2]
 fcmp s0,s0
 b.vs Lrestore_fail_nofd
 fcmp s1,s1
 b.vs Lrestore_fail_nofd
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
 fabs s0,s0
 fabs s1,s1
 mov w8,#32768
 scvtf s2,w8
 fcmp s0,s2
 b.gt Lrestore_fail_nofd
 fcmp s1,s2
 b.gt Lrestore_fail_nofd
 ldr w8,[x27,w28,uxtw #2]
 cmp w8,#255
 b.hi Lrestore_fail_nofd
 add w28,w28,#1
 b Lrestore_heights
Lrestore_mover_values:
 add x27,x27,x23,lsl #2
 mov x26,x27
 mov w28,#0
Lrestore_mover:
 cmp w28,w23
 b.hs Lrestore_metadata
 ldr w8,[x26]
 cmp w8,#14
 b.hi Lrestore_fail_nofd
 add x0,x26,#4
 mov w1,#2
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 ldr w8,[x26,#12]
 mov w9,#10000
 cmp w8,w9
 b.hi Lrestore_fail_nofd
 add x0,x26,#16
 mov w1,#1
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 // Moving planes require finite positive speed and bounded destinations.
 ldr w8,[x26]
 ldr s0,[x26,#4]
 fabs s0,s0
 mov w9,#32768
 scvtf s1,w9
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
 ldr s0,[x26,#16]
 fabs s0,s0
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
 ldr s0,[x26,#8]
 fcmp s0,#0.0
 b.lt Lrestore_fail_nofd
 cbz w8,Lrestore_mover_aux
 fcmp s0,#0.0
 b.eq Lrestore_fail_nofd
Lrestore_mover_aux:
 mov w9,#128
 scvtf s1,w9
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
 cmp w8,#7
 b.eq Lrestore_crusher_aux
 cmp w8,#8
 b.eq Lrestore_crusher_aux
 ldr w9,[x26,#20]
 cmp w8,#2
 b.eq Lrestore_floor_aux
 cmp w8,#9
 b.eq Lrestore_floor_aux
 cmp w8,#1
 b.eq Lrestore_door_aux
 cmp w8,#4
 b.eq Lrestore_door_aux
 cmp w8,#12
 b.eq Lrestore_door_aux
 cmp w8,#13
 b.eq Lrestore_door_aux
 cbnz w9,Lrestore_fail_nofd
 b Lrestore_mover_valid
Lrestore_floor_aux:
 cmp w9,#1
 b.hi Lrestore_fail_nofd
 b Lrestore_mover_valid
Lrestore_door_aux:
 cmp w9,#1050
 b.hi Lrestore_fail_nofd
 b Lrestore_mover_valid
Lrestore_crusher_aux:
 ldr s0,[x26,#20]
 fcmp s0,s0
 b.vs Lrestore_fail_nofd
 fcmp s0,#0.0
 b.le Lrestore_fail_nofd
 fmov s1,#2.0
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
Lrestore_mover_valid:
 add x26,x26,#MOVER_SIZE
 add w28,w28,#1
 b Lrestore_mover
Lrestore_metadata:
 // Secret flags, sector names/specials, side names/offsets, and button state.
 mov x28,x26
 mov w9,#0
Lrestore_secret_flags:
 cmp w9,w23
 b.hs Lrestore_sector_meta
 ldrb w8,[x28,w9,uxtw]
 cmp w8,#1
 b.hi Lrestore_fail_nofd
 add w9,w9,#1
 b Lrestore_secret_flags
Lrestore_sector_meta:
 add x28,x26,x23
 str x28,[sp,#224]
 mov w9,#0
Lrestore_sector_meta_loop:
 cmp w9,w23
 b.hs Lrestore_side_meta
 add x8,x28,w9,uxtw #4
 ldr w10,[x8,#8]
 cmp w10,#17
 b.hi Lrestore_fail_nofd
 ldr w10,[x8,#12]
 cmp w10,#1
 b.hi Lrestore_fail_nofd
 add w9,w9,#1
 b Lrestore_sector_meta_loop
Lrestore_side_meta:
 add x28,x28,x23,lsl #4
 str x28,[sp,#232]
 ldr w9,[x21,#64]
 mov w10,#0
Lrestore_side_meta_loop:
 cmp w10,w9
 b.hs Lrestore_line_meta
 add x8,x28,x10,lsl #5
 ldr s0,[x8,#24]
 ldr s1,[x8,#28]
 fcmp s0,s0
 b.vs Lrestore_fail_nofd
 fcmp s1,s1
 b.vs Lrestore_fail_nofd
 fabs s0,s0
 fabs s1,s1
 mov w11,#65536
 scvtf s2,w11
 fcmp s0,s2
 b.gt Lrestore_fail_nofd
 fcmp s1,s2
 b.gt Lrestore_fail_nofd
 add w10,w10,#1
 b Lrestore_side_meta_loop
Lrestore_line_meta:
 add x28,x28,x9,lsl #5
 str x28,[sp,#240]
 ldr w9,[x21,#68]
 mov w10,#0
Lrestore_line_meta_loop:
 cmp w10,w9
 b.hs Lrestore_saved_physics
 add x8,x28,x10,lsl #3
 ldr w11,[x8]
 cmp w11,#1
 b.hi Lrestore_fail_nofd
 ldr w11,[x8,#4]
 cmp w11,#35
 b.hi Lrestore_fail_nofd
 add w10,w10,#1
 b Lrestore_line_meta_loop
Lrestore_saved_physics:
 add x0,x21,#76
 mov w1,#1
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 ldr w8,[x21,#80]
 tst w8,#0xfffffff0
 b.ne Lrestore_fail_nofd
 ldr w8,[x21,#84]
 cmp w8,#30
 b.hi Lrestore_fail_nofd
 mov w9,#88
Lrestore_combat_flags:
 ldr w8,[x21,w9,uxtw]
 cmp w8,#1
 b.hi Lrestore_fail_nofd
 add w9,w9,#4
 cmp w9,#104
 b.lo Lrestore_combat_flags
 ldr w8,[x21,#108]
 cmp w8,#2
 b.hi Lrestore_fail_nofd
 add x0,x21,#112
 mov w1,#3
 bl Lfinite_coords
 cbnz w0,Lrestore_fail_nofd
 ldp s0,s1,[x21,#112]
 fabs s0,s0
 fabs s1,s1
 fmov s2,#30.0
 fcmp s0,s2
 b.gt Lrestore_fail_nofd
 fcmp s1,s2
 b.gt Lrestore_fail_nofd
 ldr s0,[x21,#120]
 fabs s0,s0
 mov w8,#32768
 scvtf s1,w8
 fcmp s0,s1
 b.gt Lrestore_fail_nofd
Lrestore_targetmap:
 // Check target lump count without replacing active raw map globals.
 add x0,x21,#32
 bl _doom_lump_number
 tbnz w0,#31,Lrestore_fail_nofd
 add w0,w0,#8
 bl _doom_lump_index
 cbz x0,Lrestore_fail_nofd
 mov x8,#26
 udiv x9,x1,x8
 msub x10,x9,x8,x1
 cbnz x10,Lrestore_fail_nofd
 cmp x9,x23
 b.ne Lrestore_fail_nofd
 add x0,x21,#32
 bl _doom_lump_number
 add w0,w0,#3
 bl _doom_lump_index
 cbz x0,Lrestore_fail_nofd
 mov x8,#30
 udiv x9,x1,x8
 msub x10,x9,x8,x1
 cbnz x10,Lrestore_fail_nofd
 ldr w8,[x21,#64]
 cmp x9,x8
 b.ne Lrestore_fail_nofd
 add x0,x21,#32
 bl _doom_lump_number
 add w0,w0,#2
 bl _doom_lump_index
 cbz x0,Lrestore_fail_nofd
 mov x8,#14
 udiv x9,x1,x8
 msub x10,x9,x8,x1
 cbnz x10,Lrestore_fail_nofd
 ldr w8,[x21,#68]
 cmp x9,x8
 b.ne Lrestore_fail_nofd
 add x0,x21,#32
 bl Lmap_fingerprint
 ldr w8,[x21,#72]
 cmp w0,w8
 b.ne Lrestore_fail_nofd
 ldr w8,[sp,#96]
 cbz w8,Lrestore_validate_ok
 add x0,x21,#32
 bl _doom_world_init
 cbnz w0,Lrestore_fail_nofd
 // All validation has passed. The following copies cannot fail.
 ADDR x0,_doom_player
 mov x1,x24
 mov x2,#128
 bl _memcpy
 ADDR x0,_doom_actors
 add x1,x24,#128
 mov w8,#ACTOR_SIZE
 mul w2,w22,w8
 bl _memcpy
 ADDR x8,_doom_actor_count
 str w22,[x8]
 ADDR x0,_world_floors
 mov x1,x25
 lsl w2,w23,#2
 bl _memcpy
 ADDR x0,_world_ceilings
 add x1,x25,x23,lsl #2
 lsl w2,w23,#2
 bl _memcpy
 ADDR x0,_world_lights
 add x1,x25,x23,lsl #3
 lsl w2,w23,#2
 bl _memcpy
 ADDR x0,_world_movers
 mov x1,x27
 mov w8,#MOVER_SIZE
 mul w2,w23,w8
 bl _memcpy
 ADDR x0,_world_seen_secrets
 mov x1,x26
 mov w2,w23
 bl _memcpy
 ADDR x0,_world_sector_meta
 ldr x1,[sp,#224]
 lsl w2,w23,#4
 bl _memcpy
 ADDR x0,_world_side_meta
 ldr x1,[sp,#232]
 ldr w8,[x21,#64]
 lsl w2,w8,#5
 bl _memcpy
 ADDR x0,_world_line_meta
 ldr x1,[sp,#240]
 ldr w8,[x21,#68]
 lsl w2,w8,#3
 bl _memcpy
 ldr w8,[x21,#76]
 ADDR x9,_world_vertical
 str w8,[x9]
 ldr w8,[x21,#80]
 ADDR x9,_world_buttons
 str w8,[x9]
 ldr w8,[x21,#24]
 ADDR x9,_doom_tic
 str w8,[x9]
 ldr w8,[x21,#28]
 ADDR x9,_doom_skill
 str w8,[x9]
 ldr w8,[x21,#44]
 ADDR x9,_doom_level_complete
 str w8,[x9]
 ldr w8,[x21,#48]
 ADDR x9,_world_rng
 str w8,[x9]
 ldr w8,[x21,#52]
 ADDR x9,_world_suit
 str w8,[x9]
 ldr w8,[x21,#56]
 ADDR x9,_world_invul
 str w8,[x9]
 ADDR x0,_world_combat_state
 add x1,x21,#84
 mov x2,#28
 bl _memcpy
 ADDR x8,_world_momentum
 ldr x9,[x21,#112]
 str x9,[x8]
 ADDR x8,_world_player_floor
 ldr w9,[x21,#120]
 str w9,[x8]
Lrestore_validate_ok:
 mov w0,#0
 b Lrestore_return
Lrestore_close_fail:
 mov w0,w19
 bl _close
Lrestore_fail_nofd:
 mov w0,#-1
Lrestore_return:
 ldp x27,x28,[sp,#80]
 ldp x25,x26,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#384
 ret

// x0 destination -> w0 0 absent/1 owned valid save/-1 reject.
// On1: x1 inode,w2 device. Stack304, x19,x20 preserved. Checks final path only.
Lsave_destination:
 stp x29,x30,[sp,#-304]!
 stp x19,x20,[sp,#16]
 mov x19,x0
 bl _getuid
 mov w20,w0
 mov x0,x19
 add x1,sp,#48
 bl _lstat
 cbnz w0,Ldestination_absent
 ldrh w8,[sp,#52]
 and w8,w8,#0xf000
 cmp w8,#0x8000
 b.ne Ldestination_reject
 ldrh w8,[sp,#54]
 cmp w8,#1
 b.ne Ldestination_reject
 ldr w8,[sp,#64]
 cmp w8,w20
 b.ne Ldestination_reject
 mov x0,x19
 mov w1,#0
 bl Lload_world
 cbnz w0,Ldestination_reject
 ldr x1,[sp,#56]
 ldr w2,[sp,#48]
 mov w0,#1
 b Ldestination_return
Ldestination_absent:
 bl ___error
 ldr w8,[x0]
 cmp w8,#2
 b.ne Ldestination_reject
 mov w0,#0
 mov x1,#0
 mov w2,#0
 b Ldestination_return
Ldestination_reject:
 mov w0,#-1
Ldestination_return:
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#304
 ret

// x0 map -> w0 fingerprint of ten raw map lumps and lengths. This binds a
// save to its map bytes; it provides corruption detection, not authentication.
// Stack64,x19-x22 preserved. Empty records hash as a zero-length byte sequence.
Lmap_fingerprint:
 stp x29,x30,[sp,#-64]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 bl _doom_lump_number
 tbnz w0,#31,Lfingerprint_bad
 mov w19,w0
 mov w20,#1
 mov w21,#0x45d9
Lfingerprint_lump:
 add w0,w19,w20
 bl _doom_lump_index
 cbz x0,Lfingerprint_bad
 mov x22,x1
 bl Lchecksum
 ror w21,w21,#27
 eor w21,w21,w0
 eor w21,w21,w22
 add w20,w20,#1
 cmp w20,#10
 b.ls Lfingerprint_lump
 mov w0,w21
 b Lfingerprint_end
Lfingerprint_bad:
 mov w0,#0
Lfingerprint_end:
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#64
 ret

// x0 bytes,x1 count -> w0 FNV1a. Leaf; x8,x9 changed. Integrity only.
Lchecksum:
 mov w8,#0x9dc5
 movk w8,#0x811c,lsl #16
 mov w9,#0x193
 movk w9,#0x100,lsl #16
Lchecksum_byte:
 cbz x1,Lchecksum_done
 ldrb w10,[x0],#1
 eor w8,w8,w10
 mul w8,w8,w9
 sub x1,x1,#1
 b Lchecksum_byte
Lchecksum_done:
 mov w0,w8
 ret

// x0 floats,w1 count -> w0 0/-1. Finite, abs<=65536. Leaf, x8,v0-v1.
Lfinite_coords:
 mov w8,#65536
 scvtf s1,w8
Lfinite_loop:
 cbz w1,Lfinite_ok
 ldr s0,[x0],#4
 fcmp s0,s0
 b.vs Lfinite_bad
 fabs s0,s0
 fcmp s0,s1
 b.gt Lfinite_bad
 sub w1,w1,#1
 b Lfinite_loop
Lfinite_ok:
 mov w0,#0
 ret
Lfinite_bad:
 mov w0,#-1
 ret
.section __TEXT,__const
.p2align 3
_deg_to_rad: .float 0.0174532925199433
_two_pi: .float 6.283185307179586
_save_magic: .ascii "ASMDMS02"
_temp_suffix: .asciz ".tmp.XXXXXX"
_snd_pain: .asciz "DSPLPAIN"
_snd_death: .asciz "DSPODTH1"
_snd_pistol: .asciz "DSPISTOL"
_snd_shotgun: .asciz "DSSHOTGN"
_snd_item: .asciz "DSITEMUP"
_snd_door: .asciz "DSDOROPN"
_sprite_fireball: .ascii "BAL1A0\0\0"
_sprite_rocket: .ascii "MISLA1\0\0"
_sprite_plasma: .ascii "PLSSA0\0\0"
_walk_specials: .byte 2,3,4,5,6,8,10,12,13,16,17,19,22,25,30,35,36,37,38,39,40,44,52,53,54,56,57,58,59,72,73,74,75,76,77,79,80,81,82,83,84,86,87,88,89,90,91,92,93,94,95,96,97,98,100,104,108,109,110,119,120,121,124,125,126,128,129,130,141,0
.p2align 2
_special_actions:
// door open/close families, keyed doors, blazing doors
.short 1,1,2,1,3,1,4,1,16,1,26,1,27,1,28,1,29,1,31,1,32,1,33,1,34,1,42,1,46,1,50,1,61,1,63,1,75,1,76,1,86,1,90,1,99,1,103,1,105,1,106,1,107,1,108,1,109,1,110,1,111,1,112,1,113,1,114,1,115,1,116,1,117,1,118,1,133,1,134,1,135,1,136,1,137,1
// floor up, stairs and donut are currently represented as a tagged floor move
.short 5,2,7,7,8,7,100,8,127,8,18,2,20,2,22,2,24,2,30,2,47,2,55,2,56,2,58,2,59,2,64,2,65,2,66,2,67,2,69,2,91,2,92,2,93,2,94,2,95,2,96,2,101,2,119,2,128,2,129,2,130,2,131,2,132,2,140,2
// floor down, crushing ceilings represented conservatively as floor lower
.short 9,11,19,3,23,3,36,3,37,3,38,3,45,3,60,3,70,3,71,3,82,3,83,3,84,3,98,3,102,3
// lifts
.short 10,4,14,2,15,2,21,4,53,14,87,14,62,4,68,2,88,4,120,4,121,4,122,4,123,4
// ceiling movers, stop actions, combined ceiling/floor
.short 6,9,25,9,49,9,73,9,77,9,141,9,40,10,41,12,43,12,44,12,72,12,54,13,57,13,74,13,89,13
// light and teleport
.short 12,5,13,5,17,5,35,5,79,5,80,5,81,5,104,5,138,5,139,5,39,6,97,6,125,6,126,6,0,0

//40-byte definition: type,health,radius,height,flags,speed,attack,sprite8,damage.
.macro DEF type, health, radius, height, flags, speed, attack, sprite, damage
 .long \type,\health
 .float \radius,\height
 .long \flags
 .float \speed
 .long \attack
 .ascii "\sprite"
 .byte 0,0
 .long \damage
.endm
.p2align 3
_definitions:
 DEF 3004,20,20,56,35,1.1,1,POSSA1,5
 DEF 9,30,20,56,35,1.1,1,SPOSA1,12
 DEF 3001,60,20,56,35,1.2,2,TROOA1,12
 DEF 3002,150,30,56,35,1.6,0,SARGA1,16
 DEF 58,150,30,56,35,1.6,0,SARGA1,16
 DEF 3005,400,31,56,35,1.0,2,HEADA1,20
 DEF 3003,1000,24,64,35,1.2,2,BOSSA1,24
 DEF 69,500,24,64,35,1.2,2,BOS2A1,24
 DEF 3006,100,16,56,35,2.0,2,SKULA1,10
 DEF 16,4000,40,110,35,1.7,2,CYBRA1,100
 DEF 7,3000,128,100,35,1.2,1,SPIDA1,15
 DEF 64,700,20,56,35,2.0,2,VILEA1,20
 DEF 65,70,20,56,35,1.2,1,CPOSA1,10
 DEF 66,300,20,56,35,1.4,2,SKELA1,20
 DEF 67,600,48,64,35,1.0,2,FATTA1,24
 DEF 68,500,64,64,35,1.2,2,BSPIA1,20
 DEF 71,400,31,56,35,1.1,2,PAINA1,20
 DEF 84,50,20,56,35,1.1,1,SSWVA1,5
 DEF 72,100,16,72,3,0.0,0,KEENA0,0
 DEF 88,250,16,16,2,0.0,0,BBRNA0,0
 DEF 2035,20,10,42,3,0.0,0,BAR1A0,0
 DEF 2011,0,12,16,4,0.0,0,STIMA0,0
 DEF 2012,0,12,16,4,0.0,0,MEDIA0,0
 DEF 2013,0,16,16,4,0.0,0,SOULA0,0
 DEF 2014,0,8,16,4,0.0,0,BON1A0,0
 DEF 2015,0,8,16,4,0.0,0,BON2A0,0
 DEF 2018,0,20,16,4,0.0,0,ARM1A0,0
 DEF 2019,0,20,16,4,0.0,0,ARM2A0,0
 DEF 5,0,8,16,4,0.0,0,BKEYA0,0
 DEF 6,0,8,16,4,0.0,0,YKEYA0,0
 DEF 13,0,8,16,4,0.0,0,RKEYA0,0
 DEF 38,0,8,16,4,0.0,0,RSKUA0,0
 DEF 39,0,8,16,4,0.0,0,YSKUA0,0
 DEF 40,0,8,16,4,0.0,0,BSKUA0,0
 DEF 2001,0,20,16,4,0.0,0,SHOTA0,0
 DEF 2002,0,20,16,4,0.0,0,MGUNA0,0
 DEF 2003,0,20,16,4,0.0,0,LAUNA0,0
 DEF 2004,0,20,16,4,0.0,0,PLASA0,0
 DEF 2005,0,20,16,4,0.0,0,CSAWA0,0
 DEF 2006,0,20,16,4,0.0,0,BFUGA0,0
 DEF 2007,0,8,16,4,0.0,0,CLIPA0,0
 DEF 2008,0,8,16,4,0.0,0,SHELA0,0
 DEF 2010,0,8,16,4,0.0,0,ROCKA0,0
 DEF 2047,0,8,16,4,0.0,0,CELLA0,0
 DEF 2048,0,12,16,4,0.0,0,AMMOA0,0
 DEF 2049,0,12,16,4,0.0,0,SBOXA0,0
 DEF 2046,0,12,16,4,0.0,0,BROKA0,0
 DEF 17,0,12,16,4,0.0,0,CELPA0,0
 DEF 8,0,12,16,4,0.0,0,BPAKA0,0
 DEF 2022,0,16,16,4,0.0,0,PINVA0,0
 DEF 2023,0,16,16,4,0.0,0,PSTRA0,0
 DEF 2024,0,16,16,4,0.0,0,PINSA0,0
 DEF 2025,0,16,16,4,0.0,0,SUITA0,0
 DEF 2026,0,16,16,4,0.0,0,PMAPA0,0
 DEF 2045,0,16,16,4,0.0,0,PVISA0,0
 DEF 14,0,1,1,64,0.0,0,TFOGA0,0
 DEF 10,0,20,16,8,0.0,0,PLAYW0,0
 DEF 12,0,20,16,8,0.0,0,PLAYW0,0
 DEF 15,0,20,16,8,0.0,0,PLAYN0,0
 DEF 18,0,20,16,8,0.0,0,POSSL0,0
 DEF 19,0,20,16,8,0.0,0,SPOSL0,0
 DEF 20,0,20,16,8,0.0,0,TROOM0,0
 DEF 21,0,20,16,8,0.0,0,SARGN0,0
 DEF 22,0,20,16,8,0.0,0,HEADL0,0
 DEF 23,0,16,16,8,0.0,0,SKULK0,0
 DEF 24,0,20,16,8,0.0,0,POL5A0,0
 DEF 25,0,16,16,1,0.0,0,POL1A0,0
 DEF 26,0,16,16,1,0.0,0,POL6A0,0
 DEF 27,0,16,16,1,0.0,0,POL4A0,0
 DEF 28,0,16,16,1,0.0,0,POL2A0,0
 DEF 29,0,16,16,1,0.0,0,POL3A0,0
 DEF 30,0,16,16,1,0.0,0,COL1A0,0
 DEF 31,0,16,16,1,0.0,0,COL2A0,0
 DEF 32,0,16,16,1,0.0,0,COL3A0,0
 DEF 33,0,16,16,1,0.0,0,COL4A0,0
 DEF 34,0,20,16,0,0.0,0,CANDA0,0
 DEF 35,0,16,16,1,0.0,0,CBRAA0,0
 DEF 36,0,16,16,1,0.0,0,COL5A0,0
 DEF 37,0,16,16,1,0.0,0,COL6A0,0
 DEF 41,0,16,16,1,0.0,0,CEYEA0,0
 DEF 42,0,16,16,1,0.0,0,FSKUA0,0
 DEF 43,0,16,16,1,0.0,0,TRE1A0,0
 DEF 44,0,16,16,1,0.0,0,TBLUA0,0
 DEF 45,0,16,16,1,0.0,0,TGRNA0,0
 DEF 46,0,16,16,1,0.0,0,TREDA0,0
 DEF 47,0,16,16,1,0.0,0,SMITA0,0
 DEF 48,0,16,16,1,0.0,0,ELECA0,0
 DEF 49,0,16,64,1,0.0,0,GOR1A0,0
 DEF 50,0,16,64,1,0.0,0,GOR2A0,0
 DEF 51,0,16,84,129,0.0,0,GOR3A0,0
 DEF 52,0,16,64,1,0.0,0,GOR4A0,0
 DEF 53,0,16,52,129,0.0,0,GOR5A0,0
 DEF 54,0,32,16,1,0.0,0,TRE2A0,0
 DEF 55,0,16,16,1,0.0,0,SMBTA0,0
 DEF 56,0,16,16,1,0.0,0,SMGTA0,0
 DEF 57,0,16,16,1,0.0,0,SMRTA0,0
 DEF 70,0,16,48,1,0.0,0,FCANA0,0
 DEF 85,0,16,48,1,0.0,0,TLMPA0,0
 DEF 86,0,16,32,1,0.0,0,TLP2A0,0
 DEF 59,0,20,84,128,0.0,0,GOR2A0,0
 DEF 60,0,20,68,128,0.0,0,GOR4A0,0
 DEF 61,0,20,52,128,0.0,0,GOR3A0,0
 DEF 62,0,20,52,128,0.0,0,GOR5A0,0
 DEF 63,0,20,68,128,0.0,0,GOR1A0,0
 DEF 2028,0,16,16,1,0.0,0,COLUA0,0
 DEF 0,0,16,40,1,0.0,0,COLUA0,0

.data
.p2align 3
.globl _doom_sector_floors,_doom_sector_ceilings,_doom_sector_lights
_doom_sector_floors: .quad _world_floors
_doom_sector_ceilings: .quad _world_ceilings
_doom_sector_lights: .quad _world_lights
.globl _doom_skill
_doom_skill: .long 3
_world_rng: .long 0x6d2b79f5

.bss
.p2align 4
.globl _doom_player,_doom_actors,_doom_actor_count,_doom_tic,_doom_level_complete,_doom_paused
_doom_player: .space 128
_doom_actors: .space MAX_ACTORS*ACTOR_SIZE
_doom_actor_count: .space 4
_doom_tic: .space 4
_doom_level_complete: .space 4
_doom_paused: .space 4
_world_buttons: .space 4
_world_vertical: .space 4
_world_suit: .space 4
_world_invul: .space 4
_world_map: .space 8
.p2align 4
_world_floors: .space MAX_SECTORS*4
_world_ceilings: .space MAX_SECTORS*4
_world_lights: .space MAX_SECTORS*4
_world_movers: .space MAX_SECTORS*MOVER_SIZE
_world_seen_secrets: .space MAX_SECTORS
_world_sector_meta: .space MAX_SECTORS*16
_world_side_meta: .space MAX_SECTORS*32
_world_line_meta: .space MAX_SECTORS*8
_world_side_scroll: .space MAX_SECTORS
_save_path: .space 1024
.p2align 4
_save_stage: .space SAVE_CAP
.text
// w0 sector,w1 stair increment8/16. Follow oriented two-sided lines whose
// destination floor name equals the first sector. Each sector is scheduled
// once; the mover flag bounds cycles. Stack80, x19-x24,d8,d9 preserved.
Lstairs:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 mov w19,w0
 mov w20,w1
 PTR x8,_doom_sectors
 mov w9,#26
 madd x8,x19,x9,x8
 ldr x21,[x8,#4]
 ADDR x8,_world_floors
 ldr s8,[x8,w19,uxtw #2]
 scvtf s9,w20
 COUNT w24,_doom_sector_count
Lstair_schedule:
 cbz w24,Lstair_end
 sub w24,w24,#1
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x8,x19,x9,x8
 ldr w9,[x8]
 cbnz w9,Lstair_end
 fadd s8,s8,s9
 mov w9,#2
 str w9,[x8]
 str s8,[x8,#4]
 fmov s0,#0.25
 cmp w20,#16
 b.ne Lstair_speed
 fmov s0,#4.0
Lstair_speed:
 str s0,[x8,#8]
 str wzr,[x8,#20]
 PTR x22,_doom_lines
 COUNT w23,_doom_line_count
Lstair_next_line:
 cbz w23,Lstair_end
 ldrh w8,[x22,#4]
 tbz w8,#2,Lstair_next
 ldrh w8,[x22,#10]
 ldrh w9,[x22,#12]
 mov w10,#65535
 cmp w8,w10
 b.eq Lstair_next
 cmp w9,w10
 b.eq Lstair_next
 PTR x10,_doom_sides
 mov w11,#30
 madd x8,x8,x11,x10
 madd x9,x9,x11,x10
 ldrh w8,[x8,#28]
 cmp w8,w19
 b.ne Lstair_next
 ldrh w9,[x9,#28]
 PTR x10,_doom_sectors
 mov w11,#26
 madd x10,x9,x11,x10
 ldr x10,[x10,#4]
 cmp x10,x21
 b.ne Lstair_next
 ADDR x10,_world_movers
 mov w11,#MOVER_SIZE
 madd x10,x9,x11,x10
 ldr w10,[x10]
 cbnz w10,Lstair_next
 mov w19,w9
 b Lstair_schedule
Lstair_next:
 add x22,x22,#14
 sub w23,w23,#1
 b Lstair_next_line
Lstair_end:
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// w0 sector,w1 excluded neighbor(-1 none) -> w0 first adjacent sector/-1.
// Leaf; x8-x17 destroyed. Skips one-sided and same-sector lines.
Ladjacent:
 mov w15,w0
 PTR x8,_doom_lines
 COUNT w9,_doom_line_count
 PTR x10,_doom_sides
Ladjacent_loop:
 cbz w9,Ladjacent_none
 ldrh w11,[x8,#10]
 ldrh w12,[x8,#12]
 mov w13,#65535
 cmp w11,w13
 b.eq Ladjacent_next
 cmp w12,w13
 b.eq Ladjacent_next
 mov w13,#30
 madd x11,x11,x13,x10
 madd x12,x12,x13,x10
 ldrh w11,[x11,#28]
 ldrh w12,[x12,#28]
 cmp w11,w15
 b.eq Ladjacent_back
 cmp w12,w15
 b.ne Ladjacent_next
 mov w12,w11
Ladjacent_back:
 cmp w12,w15
 b.eq Ladjacent_next
 cmp w12,w1
 b.eq Ladjacent_next
 mov w0,w12
 ret
Ladjacent_next:
 add x8,x8,#14
 sub w9,w9,#1
 b Ladjacent_loop
Ladjacent_none:
 mov w0,#-1
 ret

// w0 tagged pillar. Lower pillar and raise its ring to the surrounding floor.
// Invalid/no outer neighbor leaves the world unchanged. Stack64,x19-x22 saved.
Ldonut:
 stp x29,x30,[sp,#-64]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 mov w19,w0
 mov w1,#-1
 bl Ladjacent
 tbnz w0,#31,Ldonut_end
 mov w20,w0
 mov w1,w19
 bl Ladjacent
 tbnz w0,#31,Ldonut_end
 mov w21,w0
 ADDR x8,_world_floors
 ldr s0,[x8,w21,uxtw #2]
 ADDR x8,_world_movers
 mov w9,#MOVER_SIZE
 madd x10,x19,x9,x8
 madd x11,x20,x9,x8
 ldr w12,[x10]
 cbnz w12,Ldonut_end
 ldr w12,[x11]
 cbnz w12,Ldonut_end
 mov w12,#2
 str w12,[x10]
 str w12,[x11]
 str s0,[x10,#4]
 str s0,[x11,#4]
 fmov s0,#0.5
 str s0,[x10,#8]
 str s0,[x11,#8]
 ADDR x8,_world_sector_meta
 add x9,x8,w21,uxtw #4
 ldr x9,[x9]
 add x8,x8,w20,uxtw #4
 str x9,[x8]
 str wzr,[x8,#8]
Ldonut_end:
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#64
 ret

// w0 sector,w1 door special. Door speeds2/8 and wait150 tics are original units.
// Mover return16 is always its top height. Stack64,x19-x22,d8,d9 saved.
Ldoor_action:
 stp x29,x30,[sp,#-80]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 mov w19,w0
 mov w20,w1
 bl Lneighbors
 fmov s2,#4.0
 fsub s8,s0,s2
 ADDR x8,_world_floors
 ldr s9,[x8,w19,uxtw #2]
 ADDR x21,_world_movers
 mov w8,#MOVER_SIZE
 madd x21,x19,x8,x21
 ldr w22,[x21]
 // Only manual doors reverse an active door on a second use.
 cbz w22,Ldoor_new
 cmp w20,#1
 b.eq Ldoor_reverse
 cmp w20,#26
 b.lt Ldoor_end
 cmp w20,#34
 b.le Ldoor_reverse
 cmp w20,#117
 b.ne Ldoor_end
Ldoor_reverse:
 cmp w22,#3
 b.eq Ldoor_reopen
 cmp w22,#1
 b.eq Ldoor_reclose
 cmp w22,#4
 b.ne Ldoor_end
Ldoor_reclose:
 str s9,[x21,#4]
 mov w8,#3
 str w8,[x21]
 b Ldoor_end
Ldoor_reopen:
 ldr s8,[x21,#16]
 str s8,[x21,#4]
 mov w8,#1
 str w8,[x21]
 b Ldoor_end
Ldoor_new:
 fmov s0,#2.0
 cmp w20,#99
 b.eq Ldoor_fast
 cmp w20,#105
 b.lt Ldoor_speed
 cmp w20,#118
 b.le Ldoor_fast
 cmp w20,#133
 b.lt Ldoor_speed
 cmp w20,#137
 b.gt Ldoor_speed
Ldoor_fast:
 fmov s0,#8.0
Ldoor_speed:
 str s0,[x21,#8]
 str wzr,[x21,#12]
 str s8,[x21,#16]
 mov w8,#150
 str w8,[x21,#20]
 // Close and close-then-open variants.
 ADDR x8,_door_close_ids
Ldoor_close_kind:
 ldrb w9,[x8],#1
 cbz w9,Ldoor_check_open
 cmp w9,w20
 b.ne Ldoor_close_kind
 ADDR x8,_world_ceilings
 ldr s0,[x8,w19,uxtw #2]
 str s0,[x21,#16]
 str s9,[x21,#4]
 mov w8,#3
 str w8,[x21]
 str wzr,[x21,#20]
 cmp w20,#16
 b.eq Ldoor_close30
 cmp w20,#76
 b.ne Ldoor_end
Ldoor_close30:
 mov w8,#12
 str w8,[x21]
 mov w8,#1050
 str w8,[x21,#20]
 b Ldoor_end
Ldoor_check_open:
 ADDR x8,_door_open_ids
Ldoor_open_kind:
 ldrb w9,[x8],#1
 cbz w9,Ldoor_schedule_open
 cmp w9,w20
 b.ne Ldoor_open_kind
 str wzr,[x21,#20]
Ldoor_schedule_open:
 str s8,[x21,#4]
 mov w8,#1
 str w8,[x21]
Ldoor_end:
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#80
 ret

// w0 sector,w1 special,x2 triggerline. Exact floor destination families.
// Stack96; x19-x24,d8-d11 saved. Material changes use owned metadata only.
Lfloor_action:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 mov w19,w0
 mov w20,w1
 mov x21,x2
 bl Lneighbors
 fmov s8,s0
 fmov s9,s1
 fmov s10,s2
 fmov s11,s3
 ADDR x8,_world_floors
 ldr s4,[x8,w19,uxtw #2]
 ADDR x22,_world_movers
 mov w9,#MOVER_SIZE
 madd x22,x19,x9,x22
 ldr w9,[x22]
 cbnz w9,Lfloor_end
 fmov s0,#1.0
 str s0,[x22,#8]
 str wzr,[x22,#20]
 // Table row: special, destination code, material0/1front/2lowest, speed quarters.
 ADDR x23,_floor_parameters
Lfloor_find:
 ldrh w8,[x23]
 cbz w8,Lfloor_end
 cmp w8,w20
 b.eq Lfloor_found
 add x23,x23,#8
 b Lfloor_find
Lfloor_found:
 ldrh w24,[x23,#2]
 ldrh w8,[x23,#6]
 scvtf s0,w8
 fmov s1,#0.25
 fmul s0,s0,s1
 str s0,[x22,#8]
 cmp w24,#1
 b.eq Lfloor_toceil
 cmp w24,#2
 b.eq Lfloor_crush
 cmp w24,#3
 b.eq Lfloor_next
 cmp w24,#4
 b.eq Lfloor_24
 cmp w24,#5
 b.eq Lfloor_32
 cmp w24,#6
 b.eq Lfloor_512
 cmp w24,#7
 b.eq Lfloor_high
 cmp w24,#8
 b.eq Lfloor_turbo_low
 cmp w24,#9
 b.eq Lfloor_low
 cmp w24,#10
 b.eq Lfloor_texture
 b Lfloor_end
Lfloor_toceil:
 ADDR x8,_world_ceilings
 ldr s0,[x8,w19,uxtw #2]
 fmin s0,s0,s8
 b Lfloor_target
Lfloor_crush:
 ADDR x8,_world_ceilings
 ldr s0,[x8,w19,uxtw #2]
 fmin s0,s0,s8
 fmov s1,#8.0
 fsub s0,s0,s1
 mov w8,#1
 str w8,[x22,#20]
 b Lfloor_target
Lfloor_next:
 fmov s0,s11
 b Lfloor_target
Lfloor_24:
 fmov s0,#24.0
 fadd s0,s0,s4
 b Lfloor_target
Lfloor_32:
 mov w16,#32
 scvtf s0,w16
 fadd s0,s0,s4
 b Lfloor_target
Lfloor_512:
 mov w16,#512
 scvtf s0,w16
 fadd s0,s0,s4
 b Lfloor_target
Lfloor_high:
 fmin s0,s10,s4
 b Lfloor_target
Lfloor_turbo_low:
 fmin s0,s10,s4
 fcmp s0,s4
 b.eq Lfloor_target
 fmov s1,#8.0
 fadd s0,s0,s1
 b Lfloor_target
Lfloor_low:
 fmov s0,s9
 b Lfloor_target
Lfloor_texture:
 mov w0,w19
 bl Lshortest_lower_texture
 ADDR x8,_world_floors
 ldr s4,[x8,w19,uxtw #2]
 fadd s0,s0,s4
Lfloor_target:
 str s0,[x22,#4]
 mov w8,#2
 str w8,[x22]
 ldrh w8,[x23,#4]
 cbz w8,Lfloor_end
 cmp w8,#1
 b.ne Lfloor_change_low
 ldrh w8,[x21,#10]
 PTR x9,_doom_sides
 mov w10,#30
 madd x8,x8,x10,x9
 ldrh w8,[x8,#28]
 b Lfloor_change_from
Lfloor_change_low:
 // Find adjacent sector at the lower destination, preserving exact name.
 mov w0,w19
 ldr s0,[x22,#4]
 bl Ladjacent_height
 tbnz w0,#31,Lfloor_end
 mov w8,w0
Lfloor_change_from:
 ADDR x9,_world_sector_meta
 add x8,x9,w8,uxtw #4
 ldr x8,[x8]
 add x9,x9,w19,uxtw #4
 str x8,[x9]
 str wzr,[x9,#8]
Lfloor_end:
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// w0 sector -> s0 minimum adjacent lower texture height; no texture gives0.
// Stack80;x19-x24,d8 saved. Uses resource descriptors, never dereferences null.
Lshortest_lower_texture:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 str d8,[sp,#64]
 mov w19,w0
 PTR x20,_doom_lines
 COUNT w21,_doom_line_count
 mov w8,#32767
 scvtf s8,w8
Llower_tex_line:
 cbz w21,Llower_tex_done
 ldrh w8,[x20,#10]
 ldrh w9,[x20,#12]
 mov w10,#65535
 cmp w8,w10
 b.eq Llower_tex_next
 cmp w9,w10
 b.eq Llower_tex_next
 PTR x10,_doom_sides
 mov w11,#30
 madd x22,x8,x11,x10
 madd x23,x9,x11,x10
 ldrh w8,[x22,#28]
 ldrh w9,[x23,#28]
 cmp w8,w19
 b.eq Llower_tex_both
 cmp w9,w19
 b.ne Llower_tex_next
Llower_tex_both:
 add x0,x22,#12
 bl _doom_texture
 cbz x0,Llower_tex_back
 ldr w8,[x0,#4]
 scvtf s0,w8
 fmin s8,s8,s0
Llower_tex_back:
 add x0,x23,#12
 bl _doom_texture
 cbz x0,Llower_tex_next
 ldr w8,[x0,#4]
 scvtf s0,w8
 fmin s8,s8,s0
Llower_tex_next:
 add x20,x20,#14
 sub w21,w21,#1
 b Llower_tex_line
Llower_tex_done:
 mov w8,#32767
 scvtf s0,w8
 fcmp s8,s0
 b.ne Llower_tex_return
 fmov s8,wzr
Llower_tex_return:
 fmov s0,s8
 ldr d8,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

// Switches toggle SW1*/SW2* materials. Repeat buttons revert after35tics.
// x0line; leaf. One-shot state is owned line meta, raw special remains unchanged.
Lswitch:
 mov w15,w1
 mov x16,x0
 PTR x8,_doom_lines
 sub x8,x0,x8
 mov x9,#14
 udiv x8,x8,x9
 ADDR x10,_world_line_meta
 add x10,x10,x8,lsl #3
 ldrh w11,[x0,#6]
 cmp w11,#1
 b.eq Lswitch_end
 cmp w11,#26
 b.eq Lswitch_end
 cmp w11,#27
 b.eq Lswitch_end
 cmp w11,#28
 b.eq Lswitch_end
 cmp w11,#117
 b.eq Lswitch_end
 ADDR x12,_repeat_specials
Lswitch_repeat:
 ldrb w13,[x12],#1
 cbz w13,Lswitch_once
 cmp w13,w11
 b.ne Lswitch_repeat
 cmp w15,#2
 b.eq Lswitch_end
 mov w13,#35
 str w13,[x10,#4]
 b Lswitch_material
Lswitch_once:
 mov w13,#1
 str w13,[x10]
 cmp w15,#2
 b.eq Lswitch_end
Lswitch_material:
 ldrh w11,[x16,#10]
 mov w12,#65535
 cmp w11,w12
 b.eq Lswitch_end
 ADDR x12,_world_side_meta
 add x12,x12,x11,lsl #5
 mov w13,#3
Lswitch_slot:
 ldrb w14,[x12]
 cmp w14,#83
 b.ne Lswitch_slot_next
 ldrb w14,[x12,#1]
 cmp w14,#87
 b.ne Lswitch_slot_next
 ldrb w14,[x12,#2]
 cmp w14,#49
 b.eq Lswitch_to2
 cmp w14,#50
 b.ne Lswitch_slot_next
 mov w14,#49
 strb w14,[x12,#2]
 b Lswitch_end
Lswitch_to2:
 mov w14,#50
 strb w14,[x12,#2]
 b Lswitch_end
Lswitch_slot_next:
 add x12,x12,#8
 subs w13,w13,#1
 b.ne Lswitch_slot
Lswitch_end:
 ret

.section __TEXT,__const
_door_close_ids: .byte 3,16,42,50,75,76,107,110,113,116,0
_door_open_ids: .byte 2,31,32,33,34,46,61,86,99,103,106,109,112,115,118,133,134,135,136,137,0
_repeat_specials: .byte 1,26,27,28,42,43,45,60,61,62,63,64,65,66,67,68,69,70,72,73,74,75,76,77,79,80,81,82,83,84,86,87,88,89,90,91,92,93,94,95,96,97,98,99,105,106,107,114,115,116,117,120,123,126,128,129,132,134,136,138,139,0
.p2align 2
_floor_parameters:
// special,destination1ceil/2crush/3next/4+24/5+32/6+512/7highest/8turbo/9low/10texture,change,speed*4
.short 5,1,0,4,64,1,0,4,91,1,0,4,101,1,0,4
.short 55,2,0,4,56,2,0,4,65,2,0,4,94,2,0,4
.short 18,3,0,4,69,3,0,4,119,3,0,4,128,3,0,4
.short 129,3,0,16,130,3,0,16,131,3,0,16,132,3,0,16
.short 58,4,0,4,92,4,0,4,59,4,1,4,93,4,1,4
.short 15,4,1,2,66,4,1,2,14,5,1,2,67,5,1,2
.short 20,3,1,2,22,3,1,2,47,3,1,2,68,3,1,2,95,3,1,2
.short 140,6,0,4,19,7,0,4,45,7,0,4,83,7,0,4,102,7,0,4
.short 36,8,0,16,70,8,0,16,71,8,0,16,98,8,0,16
.short 23,9,0,4,38,9,0,4,60,9,0,4,82,9,0,4,37,9,2,4,84,9,2,4
.short 30,10,0,4,96,10,0,4,0,0,0,0

.section __TEXT,__const
_use_specials: .byte 1,7,9,11,14,15,18,20,21,23,26,27,28,29,31,32,33,34,41,42,43,45,49,50,51,55,60,61,62,63,64,65,66,67,68,69,70,71,99,101,102,103,111,112,113,114,115,116,117,118,122,123,127,131,132,133,134,135,136,137,138,139,140,0

.section __TEXT,__const
.p2align 2
_weapon_cycles: .long 17,14,37,4,20,3,40
_weapon_windups: .long 4,4,3,0,8,0,30
_bullet_spread: .float 0.00038349519697141
_snd_punch: .asciz "DSPUNCH"
_snd_rocket: .asciz "DSRLAUNC"
_snd_plasma: .asciz "DSPLASMA"
_snd_bfg: .asciz "DSBFG"
.bss
.p2align 2
_world_combat_state:
_world_attack_windup: .space 4
_world_strength: .space 4
_world_saw_owned: .space 4
_world_saw_active: .space 4
_world_backpack: .space 4
_world_last_shot: .space 4
_world_armor_type: .space 4

.section __TEXT,__const
_sprite_cacoball: .ascii "BAL2A0\0\0"
_sprite_greenball: .ascii "BAL7A0\0\0"
_sprite_bfgball: .ascii "BFS1A0\0\0"
.text
// BFG impact:40 rays across90degrees from the current player position.
// Each hit receives sum15 independent1..8 damage rolls. Stack80,x19-x22,d8 saved.
Lbfg_spray:
 stp x29,x30,[sp,#-80]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 str d8,[sp,#48]
 ldr s8,[x0,#12]
 ADDR x8,_quarter_pi
 ldr s0,[x8]
 fsub s8,s8,s0
 mov w19,#40
Lbfg_ray:
 mov w20,#15
 mov w21,#0
Lbfg_damage_roll:
 bl Lrandom
 and w8,w0,#7
 add w8,w8,#1
 add w21,w21,w8
 subs w20,w20,#1
 b.ne Lbfg_damage_roll
 mov w0,w21
 mov w1,#1
 fmov s0,s8
 mov w8,#1024
 scvtf s1,w8
 bl Lhitscan
 ADDR x8,_bfg_ray_step
 ldr s0,[x8]
 fadd s8,s8,s0
 subs w19,w19,#1
 b.ne Lbfg_ray
 ldr d8,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#80
 ret
.section __TEXT,__const
_quarter_pi: .float 0.7853981633974483
_bfg_ray_step: .float 0.0392699081698724
.text
// Exact source state DATA is interpreted by these handwritten routines.
// Metadata48:{type,chaseticks,speedf,painchance,attackptr,attackcount,
// deathcount,deathptr,reserved8}. State16:{frame,tics,action,nextindex}.
// w0 type ->x0 metadata or0; bounded by the type0 sentinel. Leaf.
Lmonster_meta:
 ADDR x8,_monster_metadata
Lmonster_meta_loop:
 ldr w9,[x8]
 cbz w9,Lmonster_meta_none
 cmp w9,w0
 b.eq Lmonster_meta_found
 add x8,x8,#48
 b Lmonster_meta_loop
Lmonster_meta_found:
 mov x0,x8
 ret
Lmonster_meta_none:
 mov x0,#0
 ret

// x0 actor: start exact attack state0. Stack48,x19,x20 preserved.
Lmonster_begin:
 stp x29,x30,[sp,#-48]!
 stp x19,x20,[sp,#16]
 mov x19,x0
 ldr w0,[x19,#24]
 bl Lmonster_meta
 cbz x0,Lmonster_begin_end
 ldr x20,[x0,#16]
 cbz x20,Lmonster_begin_end
 mov w8,#2
 str w8,[x19,#36]
 str wzr,[x19,#76]
 ldr w8,[x20,#4]
 str w8,[x19,#40]
 ldr w8,[x20]
 add w8,w8,#65
 strb w8,[x19,#52]
 mov w8,#49
 strb w8,[x19,#53]
 mov x0,x19
 ldr w1,[x20,#8]
 bl Lmonster_action
Lmonster_begin_end:
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#48
 ret

// x0 actor: initialize a death sequence; drops are already created by kill.
// Barrel changes prefix toBEXP. Stack48,x19,x20 preserved.
Ldeath_begin:
 stp x29,x30,[sp,#-48]!
 stp x19,x20,[sp,#16]
 mov x19,x0
 ldr w0,[x19,#24]
 bl Lmonster_meta
 cbz x0,Ldeath_begin_end
 ldr x20,[x0,#32]
 cbz x20,Ldeath_begin_end
 ldr w8,[x19,#24]
 cmp w8,#2035
 b.ne Ldeath_begin_frame
 ADDR x8,_barrel_death_prefix
 ldr w8,[x8]
 str w8,[x19,#48]
Ldeath_begin_frame:
 mov w8,#3
 str w8,[x19,#36]
 str wzr,[x19,#76]
 ldr w8,[x20,#4]
 str w8,[x19,#40]
 ldr w8,[x20]
 add w8,w8,#65
 strb w8,[x19,#52]
 mov w8,#48
 strb w8,[x19,#53]
 mov x0,x19
 ldr w1,[x20,#8]
 bl Lmonster_action
Ldeath_begin_end:
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#48
 ret

// x0 actor: bounded attack/death state transition. Every saved misc index is
// checked against its table count before dereference. Invalid state becomes
// standing without reading a table. Stack64,x19-x22 preserved.
Lmonster_tick:
 stp x29,x30,[sp,#-64]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 mov x19,x0
 ldr w20,[x19,#36]
 ldr w8,[x19,#40]
 cmp w8,#-1
 b.eq Lmonster_tick_end
 subs w8,w8,#1
 str w8,[x19,#40]
 b.gt Lmonster_tick_end
 ldr w0,[x19,#24]
 bl Lmonster_meta
 cbz x0,Lmonster_state_invalid
 mov x22,x0
 cmp w20,#3
 b.eq Lmonster_death_table
 ldr x21,[x22,#16]
 ldr w10,[x22,#24]
 b Lmonster_state_table
Lmonster_death_table:
 ldr x21,[x22,#32]
 ldr w10,[x22,#28]
Lmonster_state_table:
 cbz x21,Lmonster_state_invalid
 ldr w9,[x19,#76]
 cmp w9,w10
 b.hs Lmonster_state_invalid
 add x8,x21,w9,uxtw #4
 ldr w9,[x8,#12]
 tbnz w9,#31,Lmonster_state_terminal
 cmp w9,w10
 b.hs Lmonster_state_invalid
 add x21,x21,w9,uxtw #4
 str w9,[x19,#76]
 ldr w8,[x21,#4]
 str w8,[x19,#40]
 ldr w8,[x21]
 add w8,w8,#65
 strb w8,[x19,#52]
 mov x0,x19
 ldr w1,[x21,#8]
 bl Lmonster_action
 b Lmonster_tick_end
Lmonster_state_terminal:
 cmp w20,#3
 b.ne Lmonster_attack_done
 // Positive-duration death with no next state vanishes (lost soul/barrel).
 mov w8,#64
 str w8,[x19,#32]
 b Lmonster_tick_end
Lmonster_attack_done:
 mov w8,#1
 str w8,[x19,#36]
 str wzr,[x19,#76]
 ldr w8,[x22,#4]
 str w8,[x19,#64]
 b Lmonster_tick_end
Lmonster_state_invalid:
 mov w8,#1
 str w8,[x19,#36]
 str wzr,[x19,#76]
 str wzr,[x19,#40]
Lmonster_tick_end:
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#64
 ret

// x0 actor,w1 state action. Original monster families use their own damage,
// projectile or burst behavior. FaceTarget updates aim at each source state.
// Stack112,x19-x24,d8-d11 preserved.
Lmonster_action:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 mov x19,x0
 mov w20,w1
 cbz w20,Lma_end
 cmp w20,#20
 b.eq Lma_fall
 cmp w20,#21
 b.eq Lma_boss
 cmp w20,#22
 b.eq Lma_explode
 ADDR x21,_doom_player
 ldp s0,s1,[x21]
 ldp s2,s3,[x19]
 fsub s8,s0,s2
 fsub s9,s1,s3
 fmul s10,s8,s8
 fmadd s10,s9,s9,s10
 fsqrt s10,s10
 fmov s0,#1.0
 fmax s10,s10,s0
 fdiv s8,s8,s10
 fdiv s9,s9,s10
 fmov s0,s9
 fmov s1,s8
 bl _atan2f
 str s0,[x19,#12]
 cmp w20,#1
 b.eq Lma_end
 cmp w20,#10
 b.eq Lma_refire
 cmp w20,#9
 b.eq Lma_charge
 cmp w20,#2
 b.eq Lma_posgun
 cmp w20,#3
 b.eq Lma_shotgun
 cmp w20,#8
 b.eq Lma_cyber
 // Melee attacks require both the original range and clear3D sight.
 ldr s0,[x19,#16]
 mov w8,#44
 scvtf s1,w8
 fadd s0,s0,s1
 fcmp s10,s0
 b.gt Lma_ranged
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s10
 ldr s5,[x19,#8]
 mov w8,#32
 scvtf s6,w8
 fadd s5,s5,s6
 ldr s6,[x21,#8]
 ldr s7,[x21,#52]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s10
 bl Ltrace
 fcmp s0,s10
 b.lt Lma_end
 mov w22,#8
 mov w23,#3
 cmp w20,#5
 b.ne Lma_melee_caco
 mov w22,#10
 mov w23,#4
Lma_melee_caco:
 cmp w20,#6
 b.ne Lma_melee_baron
 mov w22,#6
 mov w23,#10
Lma_melee_baron:
 cmp w20,#7
 b.ne Lma_roll_melee
 mov w22,#8
 mov w23,#10
Lma_roll_melee:
 bl Lrandom
 udiv w8,w0,w22
 msub w0,w8,w22,w0
 add w0,w0,#1
 mul w0,w0,w23
 bl Ldamage_player
 b Lma_end
Lma_ranged:
 cmp w20,#5
 b.eq Lma_end
 mov w22,#-1
 mov w23,#3
 cmp w20,#6
 b.ne Lma_baron_missile
 mov w22,#-2
 mov w23,#5
Lma_baron_missile:
 cmp w20,#7
 b.ne Lma_spawn
 mov w22,#-3
 mov w23,#8
 b Lma_spawn
Lma_cyber:
 mov w22,#-5
 mov w23,#20
Lma_spawn:
 mov x0,x19
 mov w1,w22
 mov w2,w23
 ldr s0,[x19,#12]
 fmov s1,wzr
 bl Lspawn_missile
 b Lma_end
Lma_posgun:
 mov x0,x19
 mov w1,#1
 bl Lmonster_gun
 b Lma_end
Lma_shotgun:
 mov x0,x19
 mov w1,#3
 bl Lmonster_gun
 b Lma_end
Lma_refire:
 // Source refire returns to chase when the target is dead or no longer seen.
 ldr w8,[x21,#16]
 cmp w8,#0
 b.le Lma_refire_stop
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 fmov s4,s10
 ldr s5,[x19,#8]
 mov w8,#32
 scvtf s6,w8
 fadd s5,s5,s6
 ldr s6,[x21,#8]
 ldr s7,[x21,#52]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s10
 bl Ltrace
 fcmp s0,s10
 b.ge Lma_end
Lma_refire_stop:
 mov w8,#1
 str w8,[x19,#36]
 str wzr,[x19,#76]
 b Lma_end
Lma_charge:
 // Skull charge keeps a fixed20unit/tic vector until collision.
 fmov s0,#20.0
 fmul s1,s8,s0
 fmul s2,s9,s0
 str s1,[x19,#68]
 str s2,[x19,#72]
 ldr s1,[x21,#8]
 ldr s2,[x19,#8]
 fsub s1,s1,s2
 fdiv s1,s1,s10
 fmul s1,s1,s0
 fmov w8,s1
 str w8,[x19,#76]
 mov w8,#4
 str w8,[x19,#36]
 b Lma_end
Lma_fall:
 ldr w8,[x19,#32]
 and w8,w8,#0xfffffffe
 str w8,[x19,#32]
 b Lma_end
Lma_boss:
 mov x0,x19
 bl Lboss_death
 b Lma_end
Lma_explode:
 mov x0,x19
 mov w1,#128
 bl Lradius_damage
Lma_end:
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// x0 shooter,w1 pellets. Enemy hitscan uses3*(1..5) per pellet and BAM20
// scatter. A pellet can miss the player's radius and still clips map geometry.
// Stack112,x19-x24,d8-d11 preserved.
Lmonster_gun:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 mov x19,x0
 mov w20,w1
 ADDR x21,_doom_player
Lmg_pellet:
 bl Lrandom
 and w22,w0,#255
 bl Lrandom
 and w0,w0,#255
 sub w0,w22,w0
 scvtf s0,w0
 ADDR x8,_monster_spread
 ldr s1,[x8]
 ldr s2,[x19,#12]
 fmadd s8,s0,s1,s2
 fmov s0,s8
 bl _cosf
 fmov s9,s0
 fmov s0,s8
 bl _sinf
 fmov s8,s0
 ldp s0,s1,[x21]
 ldp s2,s3,[x19]
 fsub s0,s0,s2
 fsub s1,s1,s3
 fmul s10,s0,s9
 fmadd s10,s1,s8,s10
 fcmp s10,#0.0
 b.le Lmg_next
 fmul s2,s0,s8
 fmul s3,s1,s9
 fsub s2,s2,s3
 fabs s2,s2
 fmov s3,#16.0
 fcmp s2,s3
 b.gt Lmg_next
 ldp s0,s1,[x19]
 fmov s2,s9
 fmov s3,s8
 fmov s4,s10
 ldr s5,[x19,#8]
 mov w8,#32
 scvtf s6,w8
 fadd s5,s5,s6
 ldr s6,[x21,#8]
 ldr s7,[x21,#52]
 fadd s6,s6,s7
 fsub s6,s6,s5
 fdiv s6,s6,s10
 bl Ltrace
 fcmp s0,s10
 b.lt Lmg_next
 bl Lrandom
 mov w8,#5
 udiv w9,w0,w8
 msub w0,w9,w8,w0
 add w0,w0,#1
 mov w8,#3
 mul w0,w0,w8
 bl Ldamage_player
Lmg_next:
 subs w20,w20,#1
 b.ne Lmg_pellet
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret

// x0 skull,w1actor index: four5unit substeps at20units/tic, with vertical aim.
// Collision ends charge; contact damage10*(1..8). Stack112,x19-x24,d8-d11 saved.
Lskull_tick:
 stp x29,x30,[sp,#-112]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 stp d8,d9,[sp,#64]
 stp d10,d11,[sp,#80]
 mov x19,x0
 mov w20,w1
 ldr s8,[x19,#68]
 ldr s9,[x19,#72]
 ldr s10,[x19,#76]
 fmov s0,#0.25
 fmul s8,s8,s0
 fmul s9,s9,s0
 fmul s10,s10,s0
 mov w21,#4
 ADDR x22,_doom_player
Lskull_step:
 ldp s0,s1,[x19]
 fadd s0,s0,s8
 fadd s1,s1,s9
 ldr s2,[x19,#8]
 fadd s2,s2,s10
 ldr s3,[x19,#16]
 ldr s4,[x19,#20]
 mov w0,w20
 mov w1,#3
 bl Lcan_move
 tbnz w0,#31,Lskull_stop
 ldp s0,s1,[x19]
 fadd s0,s0,s8
 fadd s1,s1,s9
 stp s0,s1,[x19]
 ldr s2,[x19,#8]
 fadd s2,s2,s10
 str s2,[x19,#8]
 ldp s2,s3,[x22]
 fsub s2,s2,s0
 fsub s3,s3,s1
 fmul s2,s2,s2
 fmadd s2,s3,s3,s2
 ldr s3,[x19,#16]
 fmov s4,#16.0
 fadd s3,s3,s4
 fmul s3,s3,s3
 fcmp s2,s3
 b.gt Lskull_continue
 bl Lrandom
 and w0,w0,#7
 add w0,w0,#1
 mov w8,#10
 mul w0,w0,w8
 bl Ldamage_player
 b Lskull_stop
Lskull_continue:
 subs w21,w21,#1
 b.ne Lskull_step
 b Lskull_end
Lskull_stop:
 mov w8,#1
 str w8,[x19,#36]
 str wzr,[x19,#76]
 mov w8,#6
 str w8,[x19,#64]
Lskull_end:
 ldp d10,d11,[sp,#80]
 ldp d8,d9,[sp,#64]
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#112
 ret
.section __TEXT,__const
_monster_spread: .float 0.00153398078788564
_barrel_death_prefix: .ascii "BEXP"

.include "monster-data.inc"
.text
// x0 actor: Doom flying types adjust altitude toward their target, constrained
// by the current dynamic floor/ceiling. Stack64,x19,x20,d8,d9 preserved.
Lfloat_actor:
 stp x29,x30,[sp,#-64]!
 stp x19,x20,[sp,#16]
 stp d8,d9,[sp,#32]
 mov x19,x0
 ldr w8,[x19,#24]
 cmp w8,#3005
 b.eq Lfloat_type
 cmp w8,#3006
 b.ne Lfloat_end
Lfloat_type:
 ADDR x20,_doom_player
 ldp s0,s1,[x20]
 ldp s2,s3,[x19]
 fsub s0,s0,s2
 fsub s1,s1,s3
 fmul s0,s0,s0
 fmadd s0,s1,s1,s0
 fsqrt s0,s0
 ldr s8,[x19,#8]
 ldr s1,[x20,#8]
 fsub s1,s1,s8
 fabs s2,s1
 fmov s3,#3.0
 fmul s2,s2,s3
 fcmp s0,s2
 b.ge Lfloat_bounds
 fcmp s1,#0.0
 b.lt Lfloat_down
 fadd s8,s8,s3
 b Lfloat_bounds
Lfloat_down:
 fsub s8,s8,s3
Lfloat_bounds:
 ldp s0,s1,[x19]
 bl _doom_point_sector
 tbnz w0,#31,Lfloat_end
 ADDR x8,_world_floors
 ldr s0,[x8,w0,uxtw #2]
 fmax s8,s8,s0
 ADDR x8,_world_ceilings
 ldr s0,[x8,w0,uxtw #2]
 ldr s1,[x19,#20]
 fsub s0,s0,s1
 fmin s8,s8,s0
 str s8,[x19,#8]
Lfloat_end:
 ldp d8,d9,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#64
 ret

.section __TEXT,__const
_ammo_caps: .long 200,50,50,300
_ammo_clips: .long 10,4,1,20
.text
// x0 next map ->w0 0/-1. Carry persistent inventory, backpack and saw/armor
// properties. Keep the new map's spawn, keys0 and counters0. Level powers reset.
// Stack240,x19-x24 preserved. A rejected map leaves the prior world unchanged.
FUNC doom_world_transition
 stp x29,x30,[sp,#-240]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp x23,x24,[sp,#48]
 mov x19,x0
 COUNT w20,_world_backpack
 COUNT w21,_world_armor_type
 COUNT w22,_world_saw_owned
 COUNT w23,_world_saw_active
 add x0,sp,#80
 ADDR x1,_doom_player
 mov x2,#128
 bl _memcpy
 mov x0,x19
 bl _doom_world_init
 cbnz w0,Ltransition_end
 ADDR x24,_doom_player
 ldp w8,w9,[sp,#96]
 stp w8,w9,[x24,#16]
 ldp x8,x9,[sp,#104]
 stp x8,x9,[x24,#24]
 ldr w8,[sp,#120]
 str w8,[x24,#40]
 ldr w8,[sp,#152]
 str w8,[x24,#72]
 ADDR x8,_world_backpack
 str w20,[x8]
 ADDR x8,_world_armor_type
 str w21,[x8]
 ADDR x8,_world_saw_owned
 str w22,[x8]
 ADDR x8,_world_saw_active
 str w23,[x8]
 mov w0,#0
Ltransition_end:
 ldp x23,x24,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#240
 ret
.text
// w0 sector,s0 floorheight ->w0 matching adjacent sector/-1. Leaf.
Ladjacent_height:
 mov w15,w0
 PTR x8,_doom_lines
 COUNT w9,_doom_line_count
 PTR x10,_doom_sides
Ladjacent_height_loop:
 cbz w9,Ladjacent_height_none
 ldrh w11,[x8,#10]
 ldrh w12,[x8,#12]
 mov w13,#65535
 cmp w11,w13
 b.eq Ladjacent_height_next
 cmp w12,w13
 b.eq Ladjacent_height_next
 mov w13,#30
 madd x11,x11,x13,x10
 madd x12,x12,x13,x10
 ldrh w11,[x11,#28]
 ldrh w12,[x12,#28]
 cmp w11,w15
 b.eq Ladjacent_height_back
 cmp w12,w15
 b.ne Ladjacent_height_next
 mov w12,w11
Ladjacent_height_back:
 ADDR x13,_world_floors
 ldr s1,[x13,w12,uxtw #2]
 fcmp s0,s1
 b.ne Ladjacent_height_next
 mov w0,w12
 ret
Ladjacent_height_next:
 add x8,x8,#14
 sub w9,w9,#1
 b Ladjacent_height_loop
Ladjacent_height_none:
 mov w0,#-1
 ret

// x0 monster,w1 index. Use only a facing, nearby normal manual door.
// Stack96,x19-x22,d8-d11 preserved. Used when forward movement hits geometry.
Lmonster_use:
 stp x29,x30,[sp,#-96]!
 stp x19,x20,[sp,#16]
 stp x21,x22,[sp,#32]
 stp d8,d9,[sp,#48]
 stp d10,d11,[sp,#64]
 mov x19,x0
 mov w22,w1
 ldr s0,[x19,#12]
 bl _cosf
 fmov s8,s0
 ldr s0,[x19,#12]
 bl _sinf
 fmov s9,s0
 PTR x20,_doom_lines
 COUNT w21,_doom_line_count
Lmonster_use_line:
 cbz w21,Lmonster_use_end
 ldrh w8,[x20,#6]
 cmp w8,#1
 b.ne Lmonster_use_next
 ldrh w8,[x20,#4]
 tbnz w8,#5,Lmonster_use_next // Secret doors cannot be opened by monsters.
 mov x0,x20
 ldp s0,s1,[x19]
 fmov s2,s8
 fmov s3,s9
 bl Lray_line
 fcmp s0,#0.0
 b.lt Lmonster_use_next
 mov w8,#64
 scvtf s1,w8
 fcmp s0,s1
 b.gt Lmonster_use_next
 mov x0,x20
 ldp s0,s1,[x19]
 bl Lline_side
 cbnz w0,Lmonster_use_next
 mov x0,x20
 mov w1,#1
 mov w2,w22
 mov w3,#0
 bl Lactivate
 b Lmonster_use_end
Lmonster_use_next:
 add x20,x20,#14
 sub w21,w21,#1
 b Lmonster_use_line
Lmonster_use_end:
 ldp d10,d11,[sp,#64]
 ldp d8,d9,[sp,#48]
 ldp x21,x22,[sp,#32]
 ldp x19,x20,[sp,#16]
 ldp x29,x30,[sp],#96
 ret

.text
// x0 input32. Apply original floor friction0xe800/65536 and stop threshold
//0x1000/65536 after XY movement. Air momentum is retained. Leaf,x8-x15,v0-v7.
Lplayer_friction:
 ADDR x8,_doom_player
 ldr s0,[x8,#8]
 ADDR x9,_world_player_floor
 ldr s1,[x9]
 fcmp s0,s1
 b.gt Lfriction_done
 ADDR x8,_world_momentum
 ldp s0,s1,[x8]
 fabs s2,s0
 fabs s3,s1
 ADDR x9,_stop_speed
 ldr s4,[x9]
 fcmp s2,s4
 b.ge Lfriction_apply
 fcmp s3,s4
 b.ge Lfriction_apply
 ldp s2,s3,[x0]
 fcmp s2,#0.0
 b.ne Lfriction_apply
 fcmp s3,#0.0
 b.ne Lfriction_apply
 str xzr,[x8]
 ret
Lfriction_apply:
 ADDR x9,_original_friction
 ldr s2,[x9]
 fmul s0,s0,s2
 fmul s1,s1,s2
 stp s0,s1,[x8]
Lfriction_done:
 ret
.section __TEXT,__const
_thrust_input_scale: .float 0.1953125
_original_friction: .float 0.90625
_stop_speed: .float 0.0625
.bss
.p2align 3
_world_momentum: .space 8
_world_player_floor: .space 4
