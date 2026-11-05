// SPDX-License-Identifier: GPL-2.0-or-later
// Handwritten Apple AArch64 WAD reader. Doom format references: id Software
// linuxdoom-1.10/w_wad.c and doomdata.h. No generated engine code.
.text
.p2align 2

// x0 borrowed bytes, x1 size. w0=0 or -1. Preserves all nonvolatile registers.
// Stack 64 bytes. Validate the complete directory before changing active data.
.globl _doom_wad_init
_doom_wad_init:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    mov x19,x0
    mov x20,x1
    cbz x19,Lwi_bad
    cmp x20,#12
    b.lo Lwi_bad
    mov x8,#0x4000000
    cmp x20,x8
    b.hi Lwi_bad
    ldr w8,[x19]
    mov w9,#0x5749
    movk w9,#0x4441,lsl#16
    cmp w8,w9
    b.eq Lwi_magic
    mov w9,#0x5750
    movk w9,#0x4441,lsl#16
    cmp w8,w9
    b.ne Lwi_bad
Lwi_magic:
    ldr w21,[x19,#4]
    mov w8,#65536
    cmp w21,w8
    b.hi Lwi_bad
    ldr w22,[x19,#8]
    cmp x22,#12
    b.lo Lwi_bad
    lsl x8,x21,#4
    add x8,x8,x22
    cmp x8,x20
    b.hi Lwi_bad
    add x23,x19,x22
    mov x24,#0
Lwi_loop:
    cmp x24,x21
    b.hs Lwi_commit
    add x9,x23,x24,lsl#4
    ldr w10,[x9]
    ldr w11,[x9,#4]
    add x12,x10,x11
    cmp x12,x20
    b.hi Lwi_bad
    add x24,x24,#1
    b Lwi_loop
Lwi_commit:
    bl _doom_textures_free
    bl Lmap_clear
    adrp x8,Lwad_base@PAGE
    str x19,[x8,Lwad_base@PAGEOFF]
    adrp x8,Lwad_size@PAGE
    str x20,[x8,Lwad_size@PAGEOFF]
    adrp x8,Lwad_directory@PAGE
    str x23,[x8,Lwad_directory@PAGEOFF]
    adrp x8,Lwad_count@PAGE
    str w21,[x8,Lwad_count@PAGEOFF]
    adrp x0,Lplaypal@PAGE
    add x0,x0,Lplaypal@PAGEOFF
    bl _doom_lump
    cmp x1,#768
    csel x0,x0,xzr,hs
    adrp x8,_doom_palette@PAGE
    str x0,[x8,_doom_palette@PAGEOFF]
    adrp x0,Lcolormap@PAGE
    add x0,x0,Lcolormap@PAGEOFF
    bl _doom_lump
    // The renderer can select32 ramps of256 entries each.
    cmp x1,#8192
    csel x0,x0,xzr,hs
    adrp x8,_doom_colormap@PAGE
    str x0,[x8,_doom_colormap@PAGEOFF]
    mov w0,#0
    b Lwi_done
Lwi_bad:
    mov w0,#-1
Lwi_done:
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret

// x0 readable 8-byte or NUL-terminated name. x0 normalized 8-byte key.
// Leaf, no stack. Changes x0-x5. ASCII letters are case insensitive.
.globl _doom_name_key
_doom_name_key:
    mov x1,#0
    mov x2,#0
    cbz x0,Lnk_done
Lnk_loop:
    ldrb w3,[x0,x2]
    cbz w3,Lnk_done
    cmp w3,#'a'
    b.lo Lnk_store
    cmp w3,#'z'
    b.hi Lnk_store
    sub w3,w3,#32
Lnk_store:
    lsl x4,x2,#3
    lsl x3,x3,x4
    orr x1,x1,x3
    add x2,x2,#1
    cmp x2,#8
    b.lo Lnk_loop
Lnk_done:
    mov x0,x1
    ret

// x0 name; w0 last matching directory index or -1. Stack 16. Changes volatile.
.globl _doom_lump_number
_doom_lump_number:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    bl _doom_name_key
    adrp x8,Lwad_count@PAGE
    ldr w8,[x8,Lwad_count@PAGEOFF]
    adrp x9,Lwad_directory@PAGE
    ldr x9,[x9,Lwad_directory@PAGEOFF]
    cbz x9,Lln_absent
Lln_loop:
    cbz w8,Lln_absent
    sub w8,w8,#1
    add x10,x9,x8,lsl#4
    ldr x11,[x10,#8]
    cmp x11,x0
    b.ne Lln_loop
    mov w0,w8
    b Lln_done
Lln_absent:
    mov w0,#-1
Lln_done:
    ldp x29,x30,[sp],#16
    ret

// w0 index; x0 borrowed data or NULL, x1 bytes. Leaf, no stack, x8-x11 changed.
.globl _doom_lump_index
_doom_lump_index:
    adrp x8,Lwad_count@PAGE
    ldr w8,[x8,Lwad_count@PAGEOFF]
    cmp w0,w8
    b.hs Lli_absent
    adrp x9,Lwad_directory@PAGE
    ldr x9,[x9,Lwad_directory@PAGEOFF]
    add x9,x9,w0,uxtw#4
    ldr w10,[x9]
    ldr w1,[x9,#4]
    adrp x8,Lwad_base@PAGE
    ldr x8,[x8,Lwad_base@PAGEOFF]
    add x0,x8,x10
    ret
Lli_absent:
    mov x0,#0
    mov x1,#0
    ret

// x0 name; x0 borrowed data or NULL, x1 bytes. Stack16.
.globl _doom_lump
_doom_lump:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    bl _doom_lump_number
    bl _doom_lump_index
    ldp x29,x30,[sp],#16
    ret

// x0 name; x0 borrowed 64x64 flat or NULL. Stack16. No allocation.
.globl _doom_flat
_doom_flat:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    bl _doom_lump
    cmp x1,#4096
    csel x0,x0,xzr,eq
    ldp x29,x30,[sp],#16
    ret

// x0 map marker; w0=0/-1. Stack256. Only publishes after all validations.
// Every record index is checked before a consumer can access the new map.
.globl _doom_map_load
_doom_map_load:
    stp x29,x30,[sp,#-256]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    stp x25,x26,[sp,#64]
    bl _doom_lump_number
    cmn w0,#1
    b.eq Lml_bad
    mov w19,w0
    mov w20,#0
    adrp x21,Lmap_names@PAGE
    add x21,x21,Lmap_names@PAGEOFF
    adrp x22,Lmap_record_sizes@PAGE
    add x22,x22,Lmap_record_sizes@PAGEOFF
    add x23,sp,#80
Lml_lumps:
    add w0,w19,w20
    add w0,w0,#1
    adrp x8,Lwad_count@PAGE
    ldr w8,[x8,Lwad_count@PAGEOFF]
    cmp w0,w8
    b.hs Lml_bad
    adrp x8,Lwad_directory@PAGE
    ldr x8,[x8,Lwad_directory@PAGEOFF]
    add x8,x8,w0,uxtw#4
    ldr x9,[x8,#8]
    ldr x10,[x21,x20,lsl#3]
    cmp x9,x10
    b.ne Lml_bad
    bl _doom_lump_index
    add x8,x23,x20,lsl#4
    str x0,[x8]
    ldrb w9,[x22,x20]
    udiv w10,w1,w9
    msub w11,w10,w9,w1
    cbnz w11,Lml_bad
    // REJECT and BLOCKMAP use byte lengths, not topology record counts.
    cmp w20,#8
    b.hs Lml_record_store
    cmp w10,#32768
    b.hi Lml_bad
Lml_record_store:
    str w10,[x8,#8]
    add w20,w20,#1
    cmp w20,#10
    b.lo Lml_lumps
    // Required topology records cannot be empty.
    mov w20,#1
Lml_nonempty:
    add x8,x23,x20,lsl#4
    ldr w9,[x8,#8]
    cbnz w9,Lml_next_required
    cmp w20,#6
    b.ne Lml_bad
Lml_next_required:
    add w20,w20,#1
    cmp w20,#8
    b.lo Lml_nonempty
    // LINEDEFS: vertices, front/back sidedefs. 0xffff denotes no side.
    ldr x19,[x23,#16]
    ldr w20,[x23,#24]
    ldr w21,[x23,#56]
    ldr w22,[x23,#40]
Lml_lines:
    cbz w20,Lml_sides_start
    ldrh w8,[x19]
    cmp w8,w21
    b.hs Lml_bad
    ldrh w8,[x19,#2]
    cmp w8,w21
    b.hs Lml_bad
    ldrh w8,[x19,#10]
    cmp w8,w22
    b.hs Lml_bad
    ldrh w8,[x19,#12]
    mov w9,#65535
    cmp w8,w9
    b.eq Lml_line_next
    cmp w8,w22
    b.hs Lml_bad
Lml_line_next:
    add x19,x19,#14
    sub w20,w20,#1
    b Lml_lines
Lml_sides_start:
    ldr x19,[x23,#32]
    ldr w20,[x23,#40]
    ldr w21,[x23,#120]
Lml_sides:
    cbz w20,Lml_segs_start
    ldrh w8,[x19,#28]
    cmp w8,w21
    b.hs Lml_bad
    add x19,x19,#30
    sub w20,w20,#1
    b Lml_sides
Lml_segs_start:
    ldr x19,[x23,#64]
    ldr w20,[x23,#72]
    ldr w21,[x23,#56]
    ldr w22,[x23,#24]
    ldr x24,[x23,#16]
Lml_segs:
    cbz w20,Lml_sub_start
    ldrh w8,[x19]
    cmp w8,w21
    b.hs Lml_bad
    ldrh w8,[x19,#2]
    cmp w8,w21
    b.hs Lml_bad
    ldrh w8,[x19,#6]
    cmp w8,w22
    b.hs Lml_bad
    ldrh w9,[x19,#8]
    cmp w9,#1
    b.hi Lml_bad
    mov w10,#14
    madd x8,x8,x10,x24
    add x8,x8,x9,lsl#1
    ldrh w8,[x8,#10]
    mov w9,#65535
    cmp w8,w9
    b.eq Lml_bad
    add x19,x19,#12
    sub w20,w20,#1
    b Lml_segs
Lml_sub_start:
    ldr x19,[x23,#80]
    ldr w20,[x23,#88]
    ldr w21,[x23,#72]
Lml_sub:
    cbz w20,Lml_nodes_start
    ldrh w8,[x19]
    cbz w8,Lml_bad
    ldrh w9,[x19,#2]
    add w8,w8,w9
    cmp w8,w21
    b.hi Lml_bad
    add x19,x19,#4
    sub w20,w20,#1
    b Lml_sub
Lml_nodes_start:
    ldr x19,[x23,#96]
    ldr w20,[x23,#104]
    ldr w21,[x23,#88]
    mov w22,#0
Lml_nodes:
    cbz w20,Lml_commit
    mov w24,#24
Lml_child:
    ldrh w8,[x19,x24]
    tbnz w8,#15,Lml_leaf
    // Standard Doom BSP has children before parents. Reject cycles.
    cmp w8,w22
    b.hs Lml_bad
    b Lml_child_next
Lml_leaf:
    and w8,w8,#0x7fff
    cmp w8,w21
    b.hs Lml_bad
Lml_child_next:
    add w24,w24,#2
    cmp w24,#28
    b.lo Lml_child
    add x19,x19,#28
    add w22,w22,#1
    sub w20,w20,#1
    b Lml_nodes
Lml_commit:
    adrp x19,Lmap_globals@PAGE
    add x19,x19,Lmap_globals@PAGEOFF
    mov w20,#0
Lml_publish:
    add x8,x23,x20,lsl#4
    ldr x9,[x8]
    ldr w10,[x8,#8]
    add x11,x19,x20,lsl#4
    str x9,[x11]
    str w10,[x11,#8]
    add w20,w20,#1
    cmp w20,#10
    b.lo Lml_publish
    mov w0,#0
    b Lml_done
Lml_bad:
    mov w0,#-1
Lml_done:
    ldp x25,x26,[sp,#64]
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#256
    ret

// Releases owned texture caches; borrowed WAD ownership stays with caller.
.globl _doom_resources_free
_doom_resources_free:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    bl _doom_textures_free
    bl Lmap_clear
    adrp x8,Lwad_base@PAGE
    str xzr,[x8,Lwad_base@PAGEOFF]
    adrp x8,Lwad_directory@PAGE
    str xzr,[x8,Lwad_directory@PAGEOFF]
    adrp x8,Lwad_count@PAGE
    str wzr,[x8,Lwad_count@PAGEOFF]
    adrp x8,_doom_palette@PAGE
    str xzr,[x8,_doom_palette@PAGEOFF]
    adrp x8,_doom_colormap@PAGE
    str xzr,[x8,_doom_colormap@PAGEOFF]
    ldp x29,x30,[sp],#16
    ret

// Leaf: invalidate all borrowed map pointers/counts. No owned memory changes.
Lmap_clear:
    adrp x8,Lmap_globals@PAGE
    add x8,x8,Lmap_globals@PAGEOFF
    mov w9,#10
Lmap_clear_loop:
    stp xzr,xzr,[x8],#16
    subs w9,w9,#1
    b.ne Lmap_clear_loop
    ret

.section __TEXT,__const
Lplaypal: .asciz "PLAYPAL"
Lcolormap: .asciz "COLORMAP"
Lmap_names:
    .ascii "THINGS\0\0LINEDEFS"
    .ascii "SIDEDEFSVERTEXES"
    .ascii "SEGS\0\0\0\0SSECTORS"
    .ascii "NODES\0\0\0SECTORS\0"
    .ascii "REJECT\0\0BLOCKMAP"
Lmap_record_sizes: .byte 10,14,30,4,12,4,28,26,1,1

.data
.p2align 3
Lwad_base: .quad 0
Lwad_size: .quad 0
Lwad_directory: .quad 0
Lwad_count: .quad 0
.globl _doom_palette,_doom_colormap
_doom_palette: .quad 0
_doom_colormap: .quad 0
// Pointer/count entries stay 16-byte aligned for transactional publication.
.p2align 4
Lmap_globals:
.globl _doom_things,_doom_thing_count
_doom_things: .quad 0
_doom_thing_count: .long 0,0
.globl _doom_lines,_doom_line_count
_doom_lines: .quad 0
_doom_line_count: .long 0,0
.globl _doom_sides,_doom_side_count
_doom_sides: .quad 0
_doom_side_count: .long 0,0
.globl _doom_vertices,_doom_vertex_count
_doom_vertices: .quad 0
_doom_vertex_count: .long 0,0
.globl _doom_segs,_doom_seg_count
_doom_segs: .quad 0
_doom_seg_count: .long 0,0
.globl _doom_subsectors,_doom_subsector_count
_doom_subsectors: .quad 0
_doom_subsector_count: .long 0,0
.globl _doom_nodes,_doom_node_count
_doom_nodes: .quad 0
_doom_node_count: .long 0,0
.globl _doom_sectors,_doom_sector_count
_doom_sectors: .quad 0
_doom_sector_count: .long 0,0
.globl _doom_reject,_doom_reject_bytes
_doom_reject: .quad 0
_doom_reject_bytes: .long 0,0
.globl _doom_blockmap,_doom_blockmap_bytes
_doom_blockmap: .quad 0
_doom_blockmap_bytes: .long 0,0
.subsections_via_symbols
