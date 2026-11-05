/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native RV64IM/LP64 arithmetic, byte-access, and private-ABI assertions.
 * Entry: Linux process stack. Exit: zero for pass, numbered assertion failure.
 * No C runtime is used. Each RV_CALL must restore ra and 16-byte stack balance.
 */
.include "cli/riscv64/platform.inc"
.global alu_test_start
.text
.macro ARITH operation,width,left,right,result,flags,code
    li s8, \left
    li s10, \right
    RV_FLAGS \operation,\width
    li a0, \code
    li t1, \result
    bne s11, t1, failed
    li t1, \flags
    bne s9, t1, failed
.endm
.macro CONDITION condition,mask,code
    li s0, 0
    li s2, \mask
.Lcondition_loop\@:
    mv s9, s0
    li s3, 0
    RV_BCOND \condition,.Lcondition_take\@
    j .Lcondition_check\@
.Lcondition_take\@:
    li s3, 1
.Lcondition_check\@:
    srl t1, s2, s0
    andi t1, t1, 1
    li a0, \code
    bne s3, t1, failed
    addi s0, s0, 1
    li t1, 16
    bltu s0, t1, .Lcondition_loop\@
.endm
.macro MEMORY size,offset,expected,code
    lla t1, memory
    li t2, 32
    li t3, 0xa5
.Lmemory_reset\@:
    sb t3, 0(t1)
    addi t1, t1, 1
    addi t2, t2, -1
    bnez t2, .Lmemory_reset\@
    lla s8, memory
    addi s8, s8, \offset
    li t2, 0x8877665544332211
    li s9, 11
    RV_STORE t2,\size
    RV_LOAD t0,\size
    li a0, \code
    li t1, \expected
    bne t0, t1, failed
    li t1, 11
    bne s9, t1, failed
    li t1, 0
    lla t2, memory
    lla t3, pattern
.Lmemory_check\@:
    lbu t4, 0(t2)
    li t5, 0xa5
    li t6, \offset
    bltu t1, t6, .Lmemory_guard\@
    li t6, (\offset+\size)
    bgeu t1, t6, .Lmemory_guard\@
    addi t6, t1, -\offset
    add t6, t3, t6
    lbu t5, 0(t6)
.Lmemory_guard\@:
    bne t4, t5, failed
    addi t1, t1, 1
    addi t2, t2, 1
    li t6, 32
    bltu t1, t6, .Lmemory_check\@
.endm
.macro ABI_CHECK code
    li a0, \code
    li t1, 0x11223344
    bne s0, t1, failed
    li t1, 0x22334455
    bne s1, t1, failed
    li t1, 0x33445566
    bne s2, t1, failed
    li t1, 0x44556677
    bne s3, t1, failed
    li t1, 0x55667788
    bne s4, t1, failed
    li t1, 0x66778899
    bne s5, t1, failed
    li t1, 0x12345678
    bne ra, t1, failed
    li t1, 0x76543210
    bne gp, t1, failed
    li t1, 0x65432109
    bne tp, t1, failed
    lla t1, initial_sp
    ld t1, 0(t1)
    bne sp, t1, failed
    andi t1, sp, 15
    bnez t1, failed
.endm
.macro PREP target,left,right,result,code
    li a0, \left
    li a1, \right
    li s9, 11
    RV_CALL \target
    li a0, \code
    li t1, \result
    bne t0, t1, failed
    li t1, 11
    bne s9, t1, failed
.endm
alu_test_start:
    lla t1, initial_sp
    sd sp, 0(t1)
    ld t1, 0(sp)
    li t2, 2
    bne t1, t2, bad_mode
    ld t1, 16(sp)
    lbu t2, 0(t1)
    li t3, 'f'
    beq t2, t3, flags
    li t3, 'c'
    beq t2, t3, conditions
    li t3, 'm'
    beq t2, t3, memory_tests
    li t3, 'a'
    beq t2, t3, abi
    li t3, 'p'
    beq t2, t3, prepared
bad_mode:
    li a0, 254
    j failed
flags:
    lbu t2, 5(t1)
    li t3, '6'
    beq t2, t3, flags64
    li t3, '3'
    bne t2, t3, bad_mode
    ARITH add,32,0,0,0,4,30
    ARITH add,32,0xffffffff,1,0,6,31
    ARITH add,32,0x7fffffff,1,0x80000000,9,32
    ARITH add,32,0x80000000,0x80000000,0,7,33
    ARITH add,32,0xffffffff,0xffffffff,0xfffffffe,10,34
    ARITH add,32,0xffffffff00000000,0xffffffff00000000,0,4,35
    ARITH sub,32,0,0,0,6,36
    ARITH sub,32,0,1,0xffffffff,8,37
    ARITH sub,32,0x80000000,1,0x7fffffff,3,38
    ARITH sub,32,0x7fffffff,0xffffffff,0x80000000,9,39
    ARITH sub,32,0x80000000,0x7fffffff,1,3,40
    ARITH and,32,0xffffffff,0,0,4,41
    ARITH and,32,0xffffffffffffffff,0x80000000,0x80000000,8,42
    ARITH and,32,0x80000000,0x7fffffff,0,4,43
    j passed
flags64:
    ARITH add,64,0,0,0,4,10
    ARITH add,64,-1,1,0,6,11
    ARITH add,64,0x7fffffffffffffff,1,0x8000000000000000,9,12
    ARITH add,64,0x8000000000000000,0x8000000000000000,0,7,13
    ARITH add,64,-1,-1,-2,10,14
    ARITH sub,64,0,0,0,6,15
    ARITH sub,64,0,1,-1,8,16
    ARITH sub,64,0x8000000000000000,1,0x7fffffffffffffff,3,17
    ARITH sub,64,0x7fffffffffffffff,-1,0x8000000000000000,9,18
    ARITH sub,64,0x8000000000000000,0x7fffffffffffffff,1,3,19
    ARITH and,64,-1,0,0,4,20
    ARITH and,64,-1,0x8000000000000000,0x8000000000000000,8,21
    ARITH and,64,0x8000000000000000,0x7fffffffffffffff,0,4,22
    j passed
conditions:
    CONDITION eq,0xf0f0,60
    CONDITION ne,0x0f0f,61
    CONDITION cs,0xcccc,62
    CONDITION hs,0xcccc,63
    CONDITION cc,0x3333,64
    CONDITION lo,0x3333,65
    CONDITION mi,0xff00,66
    CONDITION pl,0x00ff,67
    CONDITION hi,0x0c0c,68
    CONDITION ls,0xf3f3,69
    CONDITION ge,0xaa55,70
    CONDITION lt,0x55aa,71
    CONDITION gt,0x0a05,72
    CONDITION le,0xf5fa,73
    CONDITION vs,0xaaaa,74
    CONDITION vc,0x5555,75
    j passed
memory_tests:
    MEMORY 1,1,0x11,80
    MEMORY 2,3,0x2211,81
    MEMORY 4,7,0x44332211,82
    MEMORY 8,1,0x8877665544332211,83
    MEMORY 8,7,0x8877665544332211,84
    j passed
prepared:
    PREP alu_mov32,-1,0,0xffffffff,90
    PREP alu_add32,0xffffffffffffffff,1,0,91
    PREP alu_sub32,0,1,0xffffffff,92
    PREP alu_lsr32,0x100000000,0,0,93
    PREP alu_lsr32,0xffffffffffffffff,0,0x7fffffff,94
    PREP alu_udiv32,7,0x100000000,0,95
    PREP alu_udiv32,0x100000009,2,4,96
    PREP alu_udiv32,0xffffffff,1,0xffffffff,97
    j passed
abi:
    li s0, 0x11223344
    li s1, 0x22334455
    li s2, 0x33445566
    li s3, 0x44556677
    li s4, 0x55667788
    li s5, 0x66778899
    li gp, 0x76543210
    li tp, 0x65432109
    lla a0, text
    li ra, 0x12345678
    RV_CALL strlen
    li t1, 5
    li a0, 100
    bne t0, t1, failed
    ABI_CHECK 101
    lla a0, text
    lla a1, text
    li ra, 0x12345678
    RV_CALL streq
    li t1, 1
    li a0, 102
    bne t0, t1, failed
    ABI_CHECK 103
    lla a0, copied
    lla a1, text
    li ra, 0x12345678
    RV_CALL copy_string
    lla t1, copied+5
    li a0, 104
    bne t0, t1, failed
    ABI_CHECK 105
    lla a0, version
    lla a1, range
    li ra, 0x12345678
    RV_CALL rm_range_matches
    li a0, 106
    li t1, 1
    bne t0, t1, failed
    ABI_CHECK 107
    lla a0, link
    lla a1, libraries
    lla a2, checker
    li ra, 0x12345678
    RV_CALL native_link_validate
    li a0, 108
    li t1, 1
    bne t0, t1, failed
    ABI_CHECK 109
    j passed
passed:
    li a0, 0
failed:
    li a7, 93
    ecall
.section .rodata
pattern: .byte 0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88
text: .asciz "hello"
range: .asciz ">=1.0.0, <2.0.0"
version: .asciz "1.2.3"
link: .asciz "c"
libraries: .asciz "m"
checker: .asciz "check.c"
.bss
.balign 8
initial_sp: .skip 8
memory: .skip 32
copied: .skip 16
.section .note.GNU-stack,""
