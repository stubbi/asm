// SPDX-License-Identifier: GPL-2.0-or-later
// Doom monster state DATA, extracted without generating engine instructions.
// Copyright (C) 1993-1996 Id Software, Inc.
// Copyright (C) 2005-2014 Simon Howard
// Source: Chocolate Doom, src/doom/info.c and info.h.
// Commit: a2dfd51fcc00d272dc8a17a97ccd6683333ff4ea; observed 2026-11-05.
// https://github.com/chocolate-doom/chocolate-doom
// This program is free software; you can redistribute it and/or modify it
// under GNU GPL version 2, or (at your option) any later version.
// Distributed WITHOUT ANY WARRANTY; see the package LICENSE.
// Metadata:48 bytes per row. State:frame,tics,action,next index (16 bytes).
// A finite final death state exits to S_NULL; tics=-1 retains its last frame.
.section __DATA,__const
.p2align 3
.globl _monster_metadata
_monster_metadata:
 // MT_POSSESSED
 .long 3004,4
 .float 8.0
 .long 200
 .quad Lmonster_attack_3004
 .long 3,5
 .quad Lmonster_death_3004
 .quad 0
 // MT_SHOTGUY
 .long 9,3
 .float 8.0
 .long 170
 .quad Lmonster_attack_9
 .long 3,5
 .quad Lmonster_death_9
 .quad 0
 // MT_TROOP
 .long 3001,3
 .float 8.0
 .long 200
 .quad Lmonster_attack_3001
 .long 3,5
 .quad Lmonster_death_3001
 .quad 0
 // MT_SERGEANT
 .long 3002,2
 .float 10.0
 .long 180
 .quad Lmonster_attack_3002
 .long 3,6
 .quad Lmonster_death_3002
 .quad 0
 // MT_SHADOWS
 .long 58,2
 .float 10.0
 .long 180
 .quad Lmonster_attack_58
 .long 3,6
 .quad Lmonster_death_58
 .quad 0
 // MT_HEAD
 .long 3005,3
 .float 8.0
 .long 128
 .quad Lmonster_attack_3005
 .long 3,6
 .quad Lmonster_death_3005
 .quad 0
 // MT_BRUISER
 .long 3003,3
 .float 8.0
 .long 50
 .quad Lmonster_attack_3003
 .long 3,7
 .quad Lmonster_death_3003
 .quad 0
 // MT_SKULL
 .long 3006,6
 .float 8.0
 .long 256
 .quad Lmonster_attack_3006
 .long 4,6
 .quad Lmonster_death_3006
 .quad 0
 // MT_CYBORG
 .long 16,3
 .float 16.0
 .long 20
 .quad Lmonster_attack_16
 .long 6,10
 .quad Lmonster_death_16
 .quad 0
 // MT_SPIDER
 .long 7,3
 .float 12.0
 .long 40
 .quad Lmonster_attack_7
 .long 4,11
 .quad Lmonster_death_7
 .quad 0
 // MT_BARREL
 .long 2035,0
 .float 0.0
 .long 0
 .quad 0
 .long 0,5
 .quad Lmonster_death_2035
 .quad 0
 .space 48,0
.globl _monster_meta_end
_monster_meta_end:
.p2align 2
Lmonster_attack_3004:
 .long 4,10,1,1 // S_POSS_ATK1: A_FaceTarget
 .long 5,8,2,2 // S_POSS_ATK2: A_PosAttack
 .long 4,8,0,-1 // S_POSS_ATK3: NULL
Lmonster_death_3004:
 .long 7,5,0,1 // S_POSS_DIE1: NULL
 .long 8,5,0,2 // S_POSS_DIE2: A_Scream
 .long 9,5,20,3 // S_POSS_DIE3: A_Fall
 .long 10,5,0,4 // S_POSS_DIE4: NULL
 .long 11,-1,0,-1 // S_POSS_DIE5: NULL
Lmonster_attack_9:
 .long 4,10,1,1 // S_SPOS_ATK1: A_FaceTarget
 .long 5,10,3,2 // S_SPOS_ATK2: A_SPosAttack
 .long 4,10,0,-1 // S_SPOS_ATK3: NULL
Lmonster_death_9:
 .long 7,5,0,1 // S_SPOS_DIE1: NULL
 .long 8,5,0,2 // S_SPOS_DIE2: A_Scream
 .long 9,5,20,3 // S_SPOS_DIE3: A_Fall
 .long 10,5,0,4 // S_SPOS_DIE4: NULL
 .long 11,-1,0,-1 // S_SPOS_DIE5: NULL
Lmonster_attack_3001:
 .long 4,8,1,1 // S_TROO_ATK1: A_FaceTarget
 .long 5,8,1,2 // S_TROO_ATK2: A_FaceTarget
 .long 6,6,4,-1 // S_TROO_ATK3: A_TroopAttack
Lmonster_death_3001:
 .long 8,8,0,1 // S_TROO_DIE1: NULL
 .long 9,8,0,2 // S_TROO_DIE2: A_Scream
 .long 10,6,0,3 // S_TROO_DIE3: NULL
 .long 11,6,20,4 // S_TROO_DIE4: A_Fall
 .long 12,-1,0,-1 // S_TROO_DIE5: NULL
Lmonster_attack_3002:
 .long 4,8,1,1 // S_SARG_ATK1: A_FaceTarget
 .long 5,8,1,2 // S_SARG_ATK2: A_FaceTarget
 .long 6,8,5,-1 // S_SARG_ATK3: A_SargAttack
Lmonster_death_3002:
 .long 8,8,0,1 // S_SARG_DIE1: NULL
 .long 9,8,0,2 // S_SARG_DIE2: A_Scream
 .long 10,4,0,3 // S_SARG_DIE3: NULL
 .long 11,4,20,4 // S_SARG_DIE4: A_Fall
 .long 12,4,0,5 // S_SARG_DIE5: NULL
 .long 13,-1,0,-1 // S_SARG_DIE6: NULL
Lmonster_attack_58:
 .long 4,8,1,1 // S_SARG_ATK1: A_FaceTarget
 .long 5,8,1,2 // S_SARG_ATK2: A_FaceTarget
 .long 6,8,5,-1 // S_SARG_ATK3: A_SargAttack
Lmonster_death_58:
 .long 8,8,0,1 // S_SARG_DIE1: NULL
 .long 9,8,0,2 // S_SARG_DIE2: A_Scream
 .long 10,4,0,3 // S_SARG_DIE3: NULL
 .long 11,4,20,4 // S_SARG_DIE4: A_Fall
 .long 12,4,0,5 // S_SARG_DIE5: NULL
 .long 13,-1,0,-1 // S_SARG_DIE6: NULL
Lmonster_attack_3005:
 .long 1,5,1,1 // S_HEAD_ATK1: A_FaceTarget
 .long 2,5,1,2 // S_HEAD_ATK2: A_FaceTarget
 .long 3,5,6,-1 // S_HEAD_ATK3: A_HeadAttack
Lmonster_death_3005:
 .long 6,8,0,1 // S_HEAD_DIE1: NULL
 .long 7,8,0,2 // S_HEAD_DIE2: A_Scream
 .long 8,8,0,3 // S_HEAD_DIE3: NULL
 .long 9,8,0,4 // S_HEAD_DIE4: NULL
 .long 10,8,20,5 // S_HEAD_DIE5: A_Fall
 .long 11,-1,0,-1 // S_HEAD_DIE6: NULL
Lmonster_attack_3003:
 .long 4,8,1,1 // S_BOSS_ATK1: A_FaceTarget
 .long 5,8,1,2 // S_BOSS_ATK2: A_FaceTarget
 .long 6,8,7,-1 // S_BOSS_ATK3: A_BruisAttack
Lmonster_death_3003:
 .long 8,8,0,1 // S_BOSS_DIE1: NULL
 .long 9,8,0,2 // S_BOSS_DIE2: A_Scream
 .long 10,8,0,3 // S_BOSS_DIE3: NULL
 .long 11,8,20,4 // S_BOSS_DIE4: A_Fall
 .long 12,8,0,5 // S_BOSS_DIE5: NULL
 .long 13,8,0,6 // S_BOSS_DIE6: NULL
 .long 14,-1,21,-1 // S_BOSS_DIE7: A_BossDeath
Lmonster_attack_3006:
 .long 2,10,1,1 // S_SKULL_ATK1: A_FaceTarget
 .long 3,4,9,2 // S_SKULL_ATK2: A_SkullAttack
 .long 2,4,0,3 // S_SKULL_ATK3: NULL
 .long 3,4,0,2 // S_SKULL_ATK4: NULL
Lmonster_death_3006:
 .long 5,6,0,1 // S_SKULL_DIE1: NULL
 .long 6,6,0,2 // S_SKULL_DIE2: A_Scream
 .long 7,6,0,3 // S_SKULL_DIE3: NULL
 .long 8,6,20,4 // S_SKULL_DIE4: A_Fall
 .long 9,6,0,5 // S_SKULL_DIE5: NULL
 .long 10,6,0,-1 // S_SKULL_DIE6: NULL
Lmonster_attack_16:
 .long 4,6,1,1 // S_CYBER_ATK1: A_FaceTarget
 .long 5,12,8,2 // S_CYBER_ATK2: A_CyberAttack
 .long 4,12,1,3 // S_CYBER_ATK3: A_FaceTarget
 .long 5,12,8,4 // S_CYBER_ATK4: A_CyberAttack
 .long 4,12,1,5 // S_CYBER_ATK5: A_FaceTarget
 .long 5,12,8,-1 // S_CYBER_ATK6: A_CyberAttack
Lmonster_death_16:
 .long 7,10,0,1 // S_CYBER_DIE1: NULL
 .long 8,10,0,2 // S_CYBER_DIE2: A_Scream
 .long 9,10,0,3 // S_CYBER_DIE3: NULL
 .long 10,10,0,4 // S_CYBER_DIE4: NULL
 .long 11,10,0,5 // S_CYBER_DIE5: NULL
 .long 12,10,20,6 // S_CYBER_DIE6: A_Fall
 .long 13,10,0,7 // S_CYBER_DIE7: NULL
 .long 14,10,0,8 // S_CYBER_DIE8: NULL
 .long 15,30,0,9 // S_CYBER_DIE9: NULL
 .long 15,-1,21,-1 // S_CYBER_DIE10: A_BossDeath
Lmonster_attack_7:
 .long 0,20,1,1 // S_SPID_ATK1: A_FaceTarget
 .long 6,4,3,2 // S_SPID_ATK2: A_SPosAttack
 .long 7,4,3,3 // S_SPID_ATK3: A_SPosAttack
 .long 7,1,10,1 // S_SPID_ATK4: A_SpidRefire
Lmonster_death_7:
 .long 9,20,0,1 // S_SPID_DIE1: A_Scream
 .long 10,10,20,2 // S_SPID_DIE2: A_Fall
 .long 11,10,0,3 // S_SPID_DIE3: NULL
 .long 12,10,0,4 // S_SPID_DIE4: NULL
 .long 13,10,0,5 // S_SPID_DIE5: NULL
 .long 14,10,0,6 // S_SPID_DIE6: NULL
 .long 15,10,0,7 // S_SPID_DIE7: NULL
 .long 16,10,0,8 // S_SPID_DIE8: NULL
 .long 17,10,0,9 // S_SPID_DIE9: NULL
 .long 18,30,0,10 // S_SPID_DIE10: NULL
 .long 18,-1,21,-1 // S_SPID_DIE11: A_BossDeath
Lmonster_death_2035:
 .long 0,5,0,1 // S_BEXP: NULL
 .long 1,5,0,2 // S_BEXP2: A_Scream
 .long 2,5,0,3 // S_BEXP3: NULL
 .long 3,10,22,4 // S_BEXP4: A_Explode
 .long 4,10,0,-1 // S_BEXP5: NULL
