// SPDX-License-Identifier: GPL-2.0-or-later
// Fixed35Hz timebase with integer millisecond deadlines and no accumulated drift.
.text
.p2align 2
.globl _doom_clock_step
// x0 previous deadline, w1 fractional remainder0..34.
// x0 next deadline, w1 new remainder. Changes x8/flags, no stack or memory.
// 1000/35 =28+20/35; the main loop owns the remainder and monotonic epoch.
_doom_clock_step:
    add x0,x0,#28
    add w1,w1,#20
    cmp w1,#35
    cset w8,hs
    add x0,x0,x8
    sub w8,w1,#35
    csel w1,w8,w1,hs
    ret
