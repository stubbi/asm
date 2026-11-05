// SPDX-License-Identifier: GPL-2.0-or-later
// Handwritten native application lifecycle. Apple arm64 ABI, macOS15+.
.text
.p2align 2
.set FREEDOOM_BYTES, 28795076
.globl _main
_main:
    stp x29,x30,[sp,#-128]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    stp x25,x26,[sp,#64]
    mov w19,w0
    mov x20,x1
    mov w21,#1
Larg_loop:
    cmp w21,w19
    b.hs Largs_done
    ldr x22,[x20,x21,lsl#3]
    mov x0,x22
    adrp x1,Lopt_help@PAGE
    add x1,x1,Lopt_help@PAGEOFF
    bl _strcmp
    cbz w0,Lhelp
    mov x0,x22
    adrp x1,Lopt_version@PAGE
    add x1,x1,Lopt_version@PAGEOFF
    bl _strcmp
    cbz w0,Lversion
    mov x0,x22
    adrp x1,Lopt_license@PAGE
    add x1,x1,Lopt_license@PAGEOFF
    bl _strcmp
    cbz w0,Llicense
    mov x0,x22
    adrp x1,Lopt_headless@PAGE
    add x1,x1,Lopt_headless@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_value
    adrp x8,Lheadless@PAGE
    mov w9,#1
    str w9,[x8,Lheadless@PAGEOFF]
    b Larg_next
Larg_value:
    add w21,w21,#1
    cmp w21,w19
    b.hs Lbad_args
    ldr x23,[x20,x21,lsl#3]
    mov x0,x22
    adrp x1,Lopt_ticks@PAGE
    add x1,x1,Lopt_ticks@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_map
    mov x0,x23
    add x1,sp,#96
    mov w2,#10
    bl _strtol
    cmp x0,#1
    b.lt Lbad_args
    mov x8,#0x9680
    movk x8,#0x98,lsl#16
    cmp x0,x8
    b.hi Lbad_args
    ldr x8,[sp,#96]
    ldrb w8,[x8]
    cbnz w8,Lbad_args
    adrp x8,Lmax_ticks@PAGE
    str w0,[x8,Lmax_ticks@PAGEOFF]
    b Larg_next
Larg_map:
    mov x0,x22
    adrp x1,Lopt_map@PAGE
    add x1,x1,Lopt_map@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_screenshot
    mov x0,x23
    bl _strlen
    cmp x0,#4
    b.ne Lbad_args
    ldrb w8,[x23]
    cmp w8,#'E'
    b.ne Lbad_args
    ldrb w8,[x23,#2]
    cmp w8,#'M'
    b.ne Lbad_args
    ldrb w8,[x23,#1]
    sub w8,w8,#'1'
    cmp w8,#3
    b.hi Lbad_args
    ldrb w8,[x23,#3]
    sub w8,w8,#'1'
    cmp w8,#8
    b.hi Lbad_args
    ldr w9,[x23]
    adrp x8,Lmap_name@PAGE
    add x8,x8,Lmap_name@PAGEOFF
    str w9,[x8]
    b Larg_next
Larg_screenshot:
    mov x0,x22
    adrp x1,Lopt_screenshot@PAGE
    add x1,x1,Lopt_screenshot@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_iwad
    adrp x8,Lscreenshot@PAGE
    str x23,[x8,Lscreenshot@PAGEOFF]
    b Larg_next
Larg_iwad:
    mov x0,x22
    adrp x1,Lopt_iwad@PAGE
    add x1,x1,Lopt_iwad@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_save
    adrp x8,Liwad_path@PAGE
    str x23,[x8,Liwad_path@PAGEOFF]
    b Larg_next
Larg_save:
    mov x0,x22
    adrp x1,Lopt_save@PAGE
    add x1,x1,Lopt_save@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_load
    adrp x8,Lsave_path@PAGE
    str x23,[x8,Lsave_path@PAGEOFF]
    b Larg_next
Larg_load:
    mov x0,x22
    adrp x1,Lopt_load@PAGE
    add x1,x1,Lopt_load@PAGEOFF
    bl _strcmp
    cbnz w0,Larg_input
    adrp x8,Lload_path@PAGE
    str x23,[x8,Lload_path@PAGEOFF]
    b Larg_next
Larg_input:
    mov x0,x22
    adrp x1,Lopt_input@PAGE
    add x1,x1,Lopt_input@PAGEOFF
    bl _strcmp
    cbnz w0,Lbad_args
    adrp x8,Linput_path@PAGE
    str x23,[x8,Linput_path@PAGEOFF]
Larg_next:
    add w21,w21,#1
    b Larg_loop
Lhelp:
    adrp x0,Lhelp_text@PAGE
    add x0,x0,Lhelp_text@PAGEOFF
    mov w1,#1
    bl Lprint
    mov w0,#0
    b Lmain_return
Lversion:
    adrp x0,Lversion_text@PAGE
    add x0,x0,Lversion_text@PAGEOFF
    mov w1,#1
    bl Lprint
    mov w0,#0
    b Lmain_return
// --license writes only embedded notice data; it does not initialize resources
// or native devices. Lwrite_all handles short writes and interrupted calls.
Llicense:
    mov w0,#1
    adrp x1,Llicense_notices@PAGE
    add x1,x1,Llicense_notices@PAGEOFF
    adrp x2,Llicense_notices_end@PAGE
    add x2,x2,Llicense_notices_end@PAGEOFF
    sub x2,x2,x1
    bl Lwrite_all
    cbnz w0,Llicense_write_error
    mov w0,#0
    b Lmain_return
Llicense_write_error:
    adrp x0,Llicense_error_text@PAGE
    add x0,x0,Llicense_error_text@PAGEOFF
    mov w1,#2
    bl Lprint
    mov w0,#1
    b Lmain_return
Lbad_args:
    adrp x0,Largs_error@PAGE
    add x0,x0,Largs_error@PAGEOFF
    mov w1,#2
    bl Lprint
    mov w0,#2
    b Lmain_return
Largs_done:
    mov w19,#1
    mov x20,#0
    mov w21,#0
    adrp x8,Liwad_path@PAGE
    ldr x0,[x8,Liwad_path@PAGEOFF]
    cbz x0,Lembedded
    bl Lread_file
    cbz x0,Ldata_error
    mov x20,x0
    mov x22,x1
    b Lwad_init
Lembedded:
    mov x0,#(FREEDOOM_BYTES & 65535)
    movk x0,#(FREEDOOM_BYTES >> 16),lsl#16
    bl _malloc
    cbz x0,Ldata_error
    mov x20,x0
    mov x8,#(FREEDOOM_BYTES & 65535)
    movk x8,#(FREEDOOM_BYTES >> 16),lsl#16
    str x8,[sp,#96]
    add x1,sp,#96
    adrp x2,_doom_embedded_start@PAGE
    add x2,x2,_doom_embedded_start@PAGEOFF
    adrp x3,_doom_embedded_end@PAGE
    add x3,x3,_doom_embedded_end@PAGEOFF
    sub x3,x3,x2
    bl _uncompress
    cbnz w0,Ldata_error
    ldr x22,[sp,#96]
Lwad_init:
    mov x0,x20
    mov x1,x22
    bl _doom_wad_init
    cbnz w0,Ldata_error
    adrp x0,Lmap_name@PAGE
    add x0,x0,Lmap_name@PAGEOFF
    bl _doom_world_init
    cbnz w0,Ldata_error
    adrp x8,Lload_path@PAGE
    ldr x0,[x8,Lload_path@PAGEOFF]
    cbz x0,Lload_done
    bl _doom_world_restore
    cbnz w0,Lsave_error
Lload_done:
    bl Lsync_map
    adrp x8,Linput_path@PAGE
    ldr x0,[x8,Linput_path@PAGEOFF]
    cbz x0,Linput_done
    adrp x8,Lheadless@PAGE
    ldr w8,[x8,Lheadless@PAGEOFF]
    cbz w8,Linput_error
    bl Lread_input
    cbnz w0,Linput_error
Linput_done:
    adrp x8,Lheadless@PAGE
    ldr w8,[x8,Lheadless@PAGEOFF]
    cbnz w8,Lheadless_loop_start
    bl _doom_platform_init
    cbnz w0,Lplatform_error
    mov w21,#1
    bl _doom_platform_audio_available
    cbnz w0,Laudio_ready
    adrp x0,Lmute_notice@PAGE
    add x0,x0,Lmute_notice@PAGEOFF
    mov w1,#2
    bl Lprint
Laudio_ready:
    mov w0,#0
    bl _doom_platform_capture
    bl Lstart_music
    bl _doom_platform_ticks
    mov x23,x0
Lwindow_loop:
    bl _doom_platform_ticks
    cmp x0,x23
    b.hs Lwindow_tick
    sub x0,x23,x0
    cmp x0,#10
    mov x8,#10
    csel x0,x0,x8,lo
    bl _doom_platform_sleep
    b Lwindow_loop
Lwindow_tick:
    sub x8,x0,x23
    cmp x8,#200
    csel x23,x0,x23,hi
    mov x0,x23
    adrp x8,Lclock_remainder@PAGE
    ldr w1,[x8,Lclock_remainder@PAGEOFF]
    bl _doom_clock_step
    mov x23,x0
    adrp x8,Lclock_remainder@PAGE
    str w1,[x8,Lclock_remainder@PAGEOFF]
    adrp x0,Linput@PAGE
    add x0,x0,Linput@PAGEOFF
    bl _doom_platform_poll
    cbnz w0,Lsuccess
    adrp x8,Linput@PAGE
    add x8,x8,Linput@PAGEOFF
    ldr w9,[x8,#20]
    cmp w9,#1
    b.ne Lmenu_not_escape
    adrp x10,Lmenu_open@PAGE
    ldr w11,[x10,Lmenu_open@PAGEOFF]
    eor w11,w11,#1
    str w11,[x10,Lmenu_open@PAGEOFF]
    cbnz w11,Lmenu_not_escape
    b Lclose_menu
Lmenu_not_escape:
    // Focus loss and the pause key return to a visible, keyboard-usable menu.
    adrp x10,_doom_paused@PAGE
    ldr w10,[x10,_doom_paused@PAGEOFF]
    cbz w10,Lmenu_focus_ready
    adrp x10,Lmenu_open@PAGE
    mov w11,#1
    str w11,[x10,Lmenu_open@PAGEOFF]
Lmenu_focus_ready:
    adrp x10,Lmenu_open@PAGE
    ldr w10,[x10,Lmenu_open@PAGEOFF]
    cbz w10,Lgame_input
    mov w0,#0
    bl _doom_platform_capture
    adrp x8,Linput@PAGE
    add x8,x8,Linput@PAGEOFF
    ldr w9,[x8,#20]
    adrp x10,Lmenu_selection@PAGE
    ldr w11,[x10,Lmenu_selection@PAGEOFF]
    cmp w9,#3
    b.ne Lmenu_down
    subs w11,w11,#1
    mov w12,#4
    csel w11,w12,w11,mi
Lmenu_down:
    cmp w9,#4
    b.ne Lmenu_choose
    add w11,w11,#1
    cmp w11,#5
    csel w11,wzr,w11,hs
Lmenu_choose:
    str w11,[x10,Lmenu_selection@PAGEOFF]
    cmp w9,#2
    b.ne Ldraw_frame
    cmp w11,#4
    b.eq Lsuccess
    cmp w11,#1
    b.eq Lnew_game
    cmp w11,#2
    b.eq Lmenu_save
    cmp w11,#3
    b.eq Lmenu_restore
    b Lclose_menu
Lnew_game:
    adrp x0,Lmap_name@PAGE
    add x0,x0,Lmap_name@PAGEOFF
    mov w8,#'1'
    strb w8,[x0,#3]
    bl _doom_world_init
    cbnz w0,Ldata_error
    bl Lstart_music
    b Lclose_menu
Lmenu_save:
    bl Ldefault_save_path
    cbz x0,Lmenu_save_failed
    bl _doom_world_save
    cbz w0,Lclose_menu
Lmenu_save_failed:
    adrp x0,Lsave_error_text@PAGE
    add x0,x0,Lsave_error_text@PAGEOFF
    mov w1,#2
    bl Lprint
    b Ldraw_frame
Lmenu_restore:
    bl Ldefault_save_path
    cbz x0,Lmenu_save_failed
    bl _doom_world_restore
    cbnz w0,Lmenu_save_failed
    bl Lstart_music
Lclose_menu:
    adrp x8,Lmenu_open@PAGE
    str wzr,[x8,Lmenu_open@PAGEOFF]
    adrp x8,_doom_paused@PAGE
    str wzr,[x8,_doom_paused@PAGEOFF]
    mov w0,#1
    bl _doom_platform_capture
    b Ldraw_frame
Lgame_input:
    ldr w9,[x8,#24]
    cmp w9,#1
    b.eq Lmenu_save
    cmp w9,#2
    b.eq Lmenu_restore
    mov x0,x8
    bl _doom_world_tick
    bl Lcheck_level
    cbnz w0,Ldata_error
    // Catch up fixed simulation ticks before rendering another expensive frame.
    bl _doom_platform_ticks
    cmp x0,x23
    b.lo Ldraw_frame
    adrp x8,Lcatchup_steps@PAGE
    ldr w9,[x8,Lcatchup_steps@PAGEOFF]
    add w9,w9,#1
    str w9,[x8,Lcatchup_steps@PAGEOFF]
    cmp w9,#4
    b.lo Lwindow_loop
Ldraw_frame:
    // An overloaded simulation must still show frames and menu feedback.
    adrp x8,Lcatchup_steps@PAGE
    str wzr,[x8,Lcatchup_steps@PAGEOFF]
    adrp x0,Lframebuffer@PAGE
    add x0,x0,Lframebuffer@PAGEOFF
    bl _doom_render
    adrp x8,Lmenu_open@PAGE
    ldr w8,[x8,Lmenu_open@PAGEOFF]
    cbz w8,Lpresent
    adrp x0,Lframebuffer@PAGE
    add x0,x0,Lframebuffer@PAGEOFF
    adrp x8,Lmenu_selection@PAGE
    ldr w1,[x8,Lmenu_selection@PAGEOFF]
    bl _doom_render_menu
Lpresent:
    adrp x0,Lframebuffer@PAGE
    add x0,x0,Lframebuffer@PAGEOFF
    bl _doom_platform_present
    b Lwindow_loop
Lheadless_loop_start:
    mov w23,#0
    adrp x8,Lmax_ticks@PAGE
    ldr w24,[x8,Lmax_ticks@PAGEOFF]
Lheadless_loop:
    cmp w23,w24
    b.hs Lheadless_finish
    adrp x0,Linput@PAGE
    add x0,x0,Linput@PAGEOFF
    adrp x8,Lreplay_count@PAGE
    ldr w8,[x8,Lreplay_count@PAGEOFF]
    cmp w23,w8
    b.hs Lheadless_tick
    adrp x8,Lreplay_records@PAGE
    ldr x8,[x8,Lreplay_records@PAGEOFF]
    add x0,x8,x23,lsl#5
Lheadless_tick:
    bl _doom_world_tick
    bl Lcheck_level
    cbnz w0,Ldata_error
    add w23,w23,#1
    b Lheadless_loop
Lheadless_finish:
    adrp x0,Lframebuffer@PAGE
    add x0,x0,Lframebuffer@PAGEOFF
    bl _doom_render
    adrp x8,Lscreenshot@PAGE
    ldr x0,[x8,Lscreenshot@PAGEOFF]
    cbz x0,Lheadless_save
    bl Lwrite_ppm
    cbnz w0,Lscreenshot_error
Lheadless_save:
    adrp x8,Lsave_path@PAGE
    ldr x0,[x8,Lsave_path@PAGEOFF]
    cbz x0,Lheadless_json
    bl _doom_world_save
    cbnz w0,Lsave_error
Lheadless_json:
    // Apple variadic arguments are stack slots, including floating values.
    sub sp,sp,#80
    adrp x8,Lmap_name@PAGE
    add x8,x8,Lmap_name@PAGEOFF
    str x8,[sp]
    str x23,[sp,#8]
    adrp x8,_doom_player@PAGE
    add x8,x8,_doom_player@PAGEOFF
    ldr s0,[x8]
    fcvt d0,s0
    str d0,[sp,#16]
    ldr s0,[x8,#4]
    fcvt d0,s0
    str d0,[sp,#24]
    ldr w9,[x8,#16]
    str x9,[sp,#32]
    ldr w9,[x8,#20]
    str x9,[sp,#48]
    ldr w9,[x8,#24]
    str x9,[sp,#56]
    ldr w9,[x8,#72]
    str x9,[sp,#64]
    ldr w9,[x8,#44]
    str x9,[sp,#72]
    adrp x8,_doom_actor_count@PAGE
    ldr w9,[x8,_doom_actor_count@PAGEOFF]
    str x9,[sp,#40]
    adrp x0,Ljson_format@PAGE
    add x0,x0,Ljson_format@PAGEOFF
    bl _printf
    add sp,sp,#80
Lsuccess:
    mov w19,#0
    b Lcleanup
Ldata_error:
    adrp x0,Ldata_error_text@PAGE
    add x0,x0,Ldata_error_text@PAGEOFF
    b Lerror_print
Lplatform_error:
    bl _doom_platform_error
    mov w1,#2
    bl Lprint
    adrp x0,Lplatform_error_text@PAGE
    add x0,x0,Lplatform_error_text@PAGEOFF
    b Lerror_print
Lscreenshot_error:
    adrp x0,Lscreenshot_error_text@PAGE
    add x0,x0,Lscreenshot_error_text@PAGEOFF
    b Lerror_print
Lsave_error:
    adrp x0,Lsave_error_text@PAGE
    add x0,x0,Lsave_error_text@PAGEOFF
    b Lerror_print
Linput_error:
    adrp x0,Linput_error_text@PAGE
    add x0,x0,Linput_error_text@PAGEOFF
Lerror_print:
    mov w1,#2
    bl Lprint
Lcleanup:
    cbz w21,Lcleanup_resources
    bl _doom_platform_shutdown
Lcleanup_resources:
    bl _doom_render_free
    bl _doom_resources_free
    adrp x8,Lreplay_owned@PAGE
    ldr x0,[x8,Lreplay_owned@PAGEOFF]
    bl _free
    mov x0,x20
    bl _free
    mov w0,w19
Lmain_return:
    ldp x25,x26,[sp,#64]
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#128
    ret

// Private print x0=NUL text,w1=fd. Stack48. Partial writes and EINTR handled.
Lprint:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    mov x19,x0
    mov w20,w1
    cbz x19,Lprint_done
    bl _strlen
    mov x2,x0
    mov w0,w20
    mov x1,x19
    bl Lwrite_all
Lprint_done:
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret

// w0 fd,x1 bytes,x2 length; w0=0/-1. Stack48. Does not own fd or buffer.
Lwrite_all:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov w19,w0
    mov x20,x1
    mov x21,x2
Lwa_loop:
    cbz x21,Lwa_ok
    mov w0,w19
    mov x1,x20
    mov x2,x21
    bl _write
    cmp x0,#0
    b.gt Lwa_progress
    b.eq Lwa_bad
    bl ___error
    ldr w8,[x0]
    cmp w8,#4
    b.eq Lwa_loop
    b Lwa_bad
Lwa_progress:
    add x20,x20,x0
    sub x21,x21,x0
    b Lwa_loop
Lwa_ok:
    mov w0,#0
    b Lwa_done
Lwa_bad:
    mov w0,#-1
Lwa_done:
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret

// x0 path. x0 owned malloc bytes orNULL,x1 size. Stack240 incl Darwin stat.
// Open refuses final symlink; require a regular file of12..64MiB.
Lread_file:
    stp x29,x30,[sp,#-240]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov w1,#0x104 // Darwin O_NOFOLLOW|O_NONBLOCK: do not wait on a FIFO.
    bl _open
    cmp w0,#0
    b.lt Lrf_bad
    mov w19,w0
    add x1,sp,#64
    bl _fstat
    cbnz w0,Lrf_close_bad
    ldrh w8,[sp,#68]
    and w8,w8,#0xf000
    cmp w8,#8,lsl#12
    b.ne Lrf_close_bad
    ldr x21,[sp,#160]
    cmp x21,#12
    b.lo Lrf_close_bad
    mov x8,#0x4000000
    cmp x21,x8
    b.hi Lrf_close_bad
    mov x0,x21
    bl _malloc
    cbz x0,Lrf_close_bad
    mov x20,x0
    mov x22,#0
Lrf_loop:
    cmp x22,x21
    b.hs Lrf_success
    mov w0,w19
    add x1,x20,x22
    sub x2,x21,x22
    bl _read
    cmp x0,#0
    b.gt Lrf_progress
    b.eq Lrf_free_bad
    bl ___error
    ldr w8,[x0]
    cmp w8,#4
    b.eq Lrf_loop
    b Lrf_free_bad
Lrf_progress:
    add x22,x22,x0
    b Lrf_loop
Lrf_success:
    mov w0,w19
    bl _close
    mov x0,x20
    mov x1,x21
    b Lrf_done
Lrf_free_bad:
    mov x0,x20
    bl _free
Lrf_close_bad:
    mov w0,w19
    bl _close
Lrf_bad:
    mov x0,#0
    mov x1,#0
Lrf_done:
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#240
    ret

// x0 input path; w0=0/-1. Stack64. Versioned fixed32-byte records.
// At most262144 records; validates every float/control before simulation.
Lread_input:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    bl Lread_file
    cbz x0,Lri_bad
    mov x19,x0
    cmp x1,#16
    b.lo Lri_free
    ldr x8,[x19]
    adrp x9,Linput_magic@PAGE
    ldr x9,[x9,Linput_magic@PAGEOFF]
    cmp x8,x9
    b.ne Lri_free
    ldr w20,[x19,#8]
    cbz w20,Lri_free
    mov w8,#0x40000
    cmp w20,w8
    b.hi Lri_free
    ldr w8,[x19,#12]
    cbnz w8,Lri_free
    lsl x8,x20,#5
    add x8,x8,#16
    cmp x8,x1
    b.ne Lri_free
    add x21,x19,#16
    mov w22,#0
Lri_record:
    cmp w22,w20
    b.hs Lri_commit
    mov w8,#32
    scvtf s1,w8
    ldr s0,[x21]
    fabs s0,s0
    fcmp s0,s1
    b.hi Lri_free
    ldr s0,[x21,#4]
    fabs s0,s0
    fcmp s0,s1
    b.hi Lri_free
    ldr s0,[x21,#8]
    fabs s0,s0
    fmov s1,#1.0
    fcmp s0,s1
    b.hi Lri_free
    ldr w8,[x21,#12]
    tst w8,#0xfffffff0
    b.ne Lri_free
    ldr w8,[x21,#16]
    cmp w8,#7
    b.hi Lri_free
    ldr w8,[x21,#20]
    ldr x9,[x21,#24]
    orr x8,x8,x9
    cbnz x8,Lri_free
    add x21,x21,#32
    add w22,w22,#1
    b Lri_record
Lri_commit:
    adrp x8,Lreplay_owned@PAGE
    str x19,[x8,Lreplay_owned@PAGEOFF]
    adrp x8,Lreplay_records@PAGE
    add x9,x19,#16
    str x9,[x8,Lreplay_records@PAGEOFF]
    adrp x8,Lreplay_count@PAGE
    str w20,[x8,Lreplay_count@PAGEOFF]
    mov w0,#0
    b Lri_done
Lri_free:
    mov x0,x19
    bl _free
Lri_bad:
    mov w0,#-1
Lri_done:
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret

// x0 destination. Private0600 stage + link finalization; never overwrites.
// Stack64; owns descriptor/tempname until cleanup. No race-free directory claim.
Lwrite_ppm:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov x19,x0
    mov w20,#-1
    mov w22,#0
    bl _strlen
    cbz x0,Lppm_bad
    cmp x0,#4000
    b.hi Lppm_bad
    adrp x21,Lppm_temp@PAGE
    add x21,x21,Lppm_temp@PAGEOFF
    mov x0,x21
    mov x1,x19
    bl _strcpy
    mov x0,x21
    adrp x1,Lppm_suffix@PAGE
    add x1,x1,Lppm_suffix@PAGEOFF
    bl _strcat
    adrp x8,Lframebuffer@PAGE
    add x8,x8,Lframebuffer@PAGEOFF
    adrp x9,Lrgb@PAGE
    add x9,x9,Lrgb@PAGEOFF
    mov w10,#0
    mov w11,#64000
Lppm_convert:
    ldr w12,[x8],#4
    lsr w13,w12,#16
    strb w13,[x9],#1
    lsr w13,w12,#8
    strb w13,[x9],#1
    strb w12,[x9],#1
    add w10,w10,#1
    cmp w10,w11
    b.lo Lppm_convert
    mov x0,x21
    bl _mkstemp
    cmp w0,#0
    b.lt Lppm_bad
    mov w20,w0
    mov w22,#1
    adrp x1,Lppm_header@PAGE
    add x1,x1,Lppm_header@PAGEOFF
    mov x2,#15
    bl Lwrite_all
    cbnz w0,Lppm_bad
    mov w0,w20
    adrp x1,Lrgb@PAGE
    add x1,x1,Lrgb@PAGEOFF
    mov x2,#0xee00
    movk x2,#2,lsl#16
    bl Lwrite_all
    cbnz w0,Lppm_bad
    mov w0,w20
    bl _fsync
    cbnz w0,Lppm_bad
    mov w0,w20
    bl _close
    mov w20,#-1
    cbnz w0,Lppm_bad
    mov x0,x21
    mov x1,x19
    bl _link
    cbnz w0,Lppm_bad
    mov x0,x21
    bl _unlink
    mov w0,#0
    b Lppm_done
Lppm_bad:
    cmp w20,#0
    b.lt Lppm_remove_stage
    mov w0,w20
    bl _close
Lppm_remove_stage:
    cbz w22,Lppm_return_bad
    mov x0,x21
    bl _unlink
Lppm_return_bad:
    mov w0,#-1
Lppm_done:
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret

// Default save under a private owned directory inHOME. Stack208.
Ldefault_save_path:
    stp x29,x30,[sp,#-208]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    adrp x0,Lhome@PAGE
    add x0,x0,Lhome@PAGEOFF
    bl _getenv
    cbz x0,Ldsp_bad
    mov x19,x0
    ldrb w8,[x19]
    cmp w8,#'/'
    b.ne Ldsp_bad
    bl _strlen
    cmp x0,#4000
    b.hi Ldsp_bad
    adrp x20,Lsave_buffer@PAGE
    add x20,x20,Lsave_buffer@PAGEOFF
    mov x0,x20
    mov x1,x19
    bl _strcpy
    mov x0,x20
    adrp x1,Lsave_directory@PAGE
    add x1,x1,Lsave_directory@PAGEOFF
    bl _strcat
    mov x0,x20
    mov w1,#0x1c0
    bl _mkdir
    mov x0,x20
    add x1,sp,#48
    bl _lstat
    cbnz w0,Ldsp_bad
    ldrh w8,[sp,#52]
    and w9,w8,#0xf000
    cmp w9,#4,lsl#12
    b.ne Ldsp_bad
    tst w8,#0x3f
    b.ne Ldsp_bad
    bl _geteuid
    ldr w8,[sp,#64]
    cmp w0,w8
    b.ne Ldsp_bad
    mov x0,x20
    adrp x1,Lsave_filename@PAGE
    add x1,x1,Lsave_filename@PAGEOFF
    bl _strcat
    mov x0,x20
    b Ldsp_done
Ldsp_bad:
    mov x0,#0
Ldsp_done:
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#208
    ret

// Called after gameplaytick. w0=0 or-1. Map transition is explicit gameplay.
Lcheck_level:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    adrp x8,_doom_level_complete@PAGE
    ldr w9,[x8,_doom_level_complete@PAGEOFF]
    cbz w9,Lcl_ok
    adrp x19,Lmap_name@PAGE
    add x19,x19,Lmap_name@PAGEOFF
    ldrb w10,[x19,#3]
    cmp w9,#2
    b.ne Lcl_normal
    mov w10,#'9'
    b Lcl_set
Lcl_normal:
    cmp w10,#'8'
    b.lo Lcl_increment
    // Secret maps return to the normal campaign route.
    cmp w10,#'9'
    b.ne Lcl_next_episode
    ldrb w11,[x19,#1]
    sub w11,w11,#'1'
    adrp x12,Lsecret_returns@PAGE
    add x12,x12,Lsecret_returns@PAGEOFF
    ldrb w10,[x12,x11]
    b Lcl_set
Lcl_next_episode:
    ldrb w11,[x19,#1]
    add w11,w11,#1
    cmp w11,#'4'
    mov w12,#'1'
    csel w11,w12,w11,hi
    strb w11,[x19,#1]
    mov w10,#'1'
    b Lcl_set
Lcl_increment:
    add w10,w10,#1
Lcl_set:
    strb w10,[x19,#3]
    mov x0,x19
    bl _doom_world_transition
    cbnz w0,Lcl_done
    bl Lstart_music
Lcl_ok:
    mov w0,#0
Lcl_done:
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret

Lstart_music:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    bl Lsync_map
    adrp x8,Lmap_name@PAGE
    add x8,x8,Lmap_name@PAGEOFF
    adrp x0,Lmusic_name@PAGE
    add x0,x0,Lmusic_name@PAGEOFF
    ldr w9,[x8]
    str w9,[x0,#2]
    bl _doom_music
    ldp x29,x30,[sp],#16
    ret

// Synchronize the displayed/progression map after a cross-map restore.
Lsync_map:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    bl _doom_world_map
    cbz x0,Lsm_done
    ldr w9,[x0]
    adrp x8,Lmap_name@PAGE
    add x8,x8,Lmap_name@PAGEOFF
    str w9,[x8]
Lsm_done:
    ldp x29,x30,[sp],#16
    ret

.section __TEXT,__cstring,cstring_literals
Lopt_help: .asciz "--help"
Lopt_version: .asciz "--version"
Lopt_license: .asciz "--license"
Lopt_headless: .asciz "--headless"
Lopt_ticks: .asciz "--ticks"
Lopt_map: .asciz "--map"
Lopt_screenshot: .asciz "--screenshot"
Lopt_iwad: .asciz "--iwad"
Lopt_save: .asciz "--save"
Lopt_load: .asciz "--load"
Lopt_input: .asciz "--input"
Lhome: .asciz "HOME"
Lsave_directory: .asciz "/.asm-doom"
Lsave_filename: .asciz "/save1.bin"
Lppm_suffix: .asciz ".tmp.XXXXXX"
Lversion_text: .asciz "asm-doom 0.1.0 (alpha; aarch64-macos; handwritten engine)\n"
Lhelp_text:
    .ascii "Asm Doom for Apple Silicon macOS 15 or later.\n"
    .ascii "Bundled data: Freedoom Phase 1, version 0.13.0.\n"
    .ascii "Controls: WASD move; mouse/arrows turn; Ctrl/click fire; E/Space use.\n"
    .ascii "Use 1-7 for weapons, Esc for menu, F5 to save, F9 to load.\n"
    .ascii "Usage: doom [--map E1M1] [--iwad FILE]\n"
    .ascii "       doom --headless --ticks N [--screenshot NEW.ppm]\n"
    .ascii "       Add --save NEWFILE or --load SAVEFILE for state checks.\n"
    .ascii "       Headless input records: --input FILE (ASMINP1 format).\n"
    .ascii "       doom --license prints complete license and copyright notices.\n"
    .asciz "Engine: GPL-2.0-or-later. Freedoom data: BSD-3-Clause. SDL: Zlib.\n"
Llicense_error_text: .asciz "doom: Cannot write license notices. Check the output destination.\n"
Largs_error: .asciz "doom: Invalid option or value. Use --help for available options.\n"
Ldata_error_text: .asciz "asm-doom: Cannot load the game data or map. Check the WAD and map name.\n"
Lplatform_error_text: .asciz "\nasm-doom: Cannot open the native window. Check the macOS display session.\n"
Lscreenshot_error_text: .asciz "asm-doom: Cannot write the screenshot. Choose a new writable destination.\n"
Lsave_error_text: .asciz "asm-doom: Cannot save or restore. Check the path and save-file version.\n"
Linput_error_text: .asciz "asm-doom: Invalid input recording. Check its ASMINP1 header and control bounds.\n"
Lmute_notice: .asciz "asm-doom: Audio is unavailable. The game will continue without sound.\n"
Ljson_format: .asciz "{\"map\":\"%s\",\"ticks\":%u,\"x\":%.3f,\"y\":%.3f,\"health\":%d,\"actors\":%u,\"armor\":%d,\"bullets\":%u,\"owned_weapons\":%u,\"keys\":%u}\n"
.section __TEXT,__const
Lppm_header: .ascii "P6\n320 200\n255\n"
.p2align 3
Linput_magic: .ascii "ASMINP1\0"
Lsecret_returns: .ascii "4673"
.section __TEXT,__const
.p2align 4
.globl _doom_embedded_start,_doom_embedded_end
_doom_embedded_start: .incbin "assets/freedoom1.wad.zlib"
_doom_embedded_end:
.data
.p2align 3
Lmap_name: .asciz "E1M1"
Lmusic_name: .asciz "D_E1M1"
.p2align 3
Lheadless: .long 0
Lmax_ticks: .long 1
Lmenu_open: .long 1
Lmenu_selection: .long 0
Lclock_remainder: .long 0
Lcatchup_steps: .long 0
Liwad_path: .quad 0
Lscreenshot: .quad 0
Lsave_path: .quad 0
Lload_path: .quad 0
Linput_path: .quad 0
Lreplay_owned: .quad 0
Lreplay_records: .quad 0
Lreplay_count: .quad 0
.zerofill __DATA,__bss,Linput,32,4
.zerofill __DATA,__bss,Lframebuffer,256000,4
.zerofill __DATA,__bss,Lrgb,192000,4
.zerofill __DATA,__bss,Lsave_buffer,4096,4
.zerofill __DATA,__bss,Lppm_temp,4096,4
.subsections_via_symbols

// Original notice bytes remain plain data in the single installed executable.
.section __TEXT,__const
.p2align 3
Llicense_notices:
    .incbin "third_party/ENGINE-NOTICES.txt"
    .ascii "\n=== GNU General Public License, version 2 ===\n"
    .incbin "LICENSE"
    .ascii "\n=== Freedoom 0.13.0 copyright and license ===\n"
    .incbin "third_party/COPYING.txt"
    .ascii "\n=== Freedoom contributor credits ===\n"
    .incbin "third_party/CREDITS.txt"
    .ascii "\n=== Freedoom music credits ===\n"
    .incbin "third_party/CREDITS-MUSIC.txt"
    .ascii "\n=== SDL 3.4.18 license ===\n"
    .incbin "third_party/sdl/LICENSE.txt"
    .ascii "\n=== Additional SDL source and dependency notices ===\n"
    .incbin "third_party/sdl/THIRD-PARTY-NOTICES.txt"
Llicense_notices_end:
