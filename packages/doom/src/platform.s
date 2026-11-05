// SPDX-License-Identifier: GPL-2.0-or-later
// Handwritten Apple AArch64 platform, input, sound mixer and MUS synthesizer.
// SDL 3.4.18 owns native devices, conversion and presentation, never game rules.
// Every entry preserves x19-x28 and SP; x0-x17/v0-v7 are caller-clobbered.
// No function uses x18. Stack frames are 16-byte aligned. No audio callback:
// the main thread owns all mixer state and feeds SDL's thread-safe PCM queue.

.macro addr reg, symbol
    adrp \reg, \symbol@PAGE
    add \reg, \reg, \symbol@PAGEOFF
.endm

.equ SAMPLE_RATE, 48000
.equ MIX_FRAMES, 1024
.equ SFX_VOICES, 8
.equ MUSIC_VOICES, 32
.equ EVENT_KEY_DOWN, 0x300
.equ EVENT_KEY_UP, 0x301
.equ EVENT_FOCUS_GAIN, 0x20e
.equ EVENT_FOCUS_LOST, 0x20f
.equ EVENT_CLOSE, 0x210

.text
.p2align 2
.globl _doom_platform_error
// No inputs. x0 = borrowed 512-byte error string, never NULL. Leaf, stack 0.
_doom_platform_error:
    addr x0, Lerror
    ret

.globl _doom_platform_audio_available
// No inputs. w0 = 1 if an output stream is open, otherwise 0. Leaf, stack 0.
_doom_platform_audio_available:
    addr x9, Laudio
    ldr x9, [x9]
    cmp x9, #0
    cset w0, ne
    ret

.globl _doom_platform_capture
// w0=0 release/1 capture relative mouse. No-init safe. Stack16 bytes.
// Best-effort capture; unsupported test drivers can reject relative mode.
_doom_platform_capture:
    stp x29, x30, [sp, #-16]!
    cmp w0, #0
    cset w1, ne
    addr x9, Lwindow
    ldr x0, [x9]
    cbz x0, 1f
    bl _SDL_SetWindowRelativeMouseMode
1:  ldp x29, x30, [sp], #16
    ret

.globl _doom_platform_init
// No inputs. w0=0 success/-1 window failure. Audio failure permits muted play.
// Owns SDL window/renderer/texture/stream until shutdown. Stack 32 bytes.
_doom_platform_init:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    addr x9, Lactive
    ldr w9, [x9]
    cbnz w9, Linit_ok
    addr x0, Lerror
    strb wzr, [x0]
    bl _SDL_SetMainReady
    mov w0, #0x20
    bl _SDL_Init
    cbz w0, Linit_fail
    addr x0, Ltitle
    mov w1, #960
    mov w2, #600
    mov x3, #0x20
    bl _SDL_CreateWindow
    cbz x0, Linit_fail
    addr x9, Lwindow
    str x0, [x9]
    mov x1, #0
    bl _SDL_CreateRenderer
    cbz x0, Linit_fail
    mov x19, x0
    addr x9, Lrenderer
    str x0, [x9]
    mov w1, #320
    mov w2, #240
    mov w3, #2
    bl _SDL_SetRenderLogicalPresentation
    cbz w0, Linit_fail
    mov x0, x19
    mov w1, #1
    bl _SDL_SetRenderVSync
    mov x0, x19
    mov w1, #0x2004
    movk w1, #0x1636, lsl #16
    mov w2, #1
    mov w3, #320
    mov w4, #200
    bl _SDL_CreateTexture
    cbz x0, Linit_fail
    addr x9, Ltexture
    str x0, [x9]
    mov w1, #0
    bl _SDL_SetTextureScaleMode
    mov w0, #0x10
    bl _SDL_InitSubSystem
    cbz w0, Linit_mute
    mov w0, #-1
    addr x1, Laudio_spec
    mov x2, #0
    mov x3, #0
    bl _SDL_OpenAudioDeviceStream
    cbz x0, Linit_mute
    addr x9, Laudio
    str x0, [x9]
    bl _SDL_ResumeAudioStreamDevice
    cbnz w0, Linit_devices_done
    addr x9, Laudio
    ldr x0, [x9]
    bl _SDL_DestroyAudioStream
    addr x9, Laudio
    str xzr, [x9]
Linit_mute:
    bl Lsave_error
Linit_devices_done:
    addr x9, Lactive
    mov w10, #1
    str w10, [x9]
    addr x9, Lfocus
    str w10, [x9]
    addr x9, Lwindow
    ldr x0, [x9]
    mov w1, #1
    bl _SDL_SetWindowRelativeMouseMode
Linit_ok:
    mov w0, #0
    b Linit_return
Linit_fail:
    bl Lsave_error
    bl _doom_platform_shutdown
    mov w0, #-1
Linit_return:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// Copy SDL's current error before cleanup can change it. Stack 16 bytes.
Lsave_error:
    stp x29, x30, [sp, #-16]!
    bl _SDL_GetError
    mov x1, x0
    addr x0, Lerror
    mov x2, #512
    bl _SDL_strlcpy
    ldp x29, x30, [sp], #16
    ret

.globl _doom_platform_shutdown
// No inputs. Idempotent, including before initialization. Stack 16 bytes.
// Does not free any borrowed WAD data. Stops consumers before resources free.
_doom_platform_shutdown:
    stp x29, x30, [sp, #-16]!
    mov x0, #0
    bl Lmusic_stop
    addr x0, Lsfx
    mov x1, #256
    bl _bzero
    addr x9, Laudio
    ldr x0, [x9]
    str xzr, [x9]
    cbz x0, 1f
    bl _SDL_DestroyAudioStream
1:  addr x9, Ltexture
    ldr x0, [x9]
    str xzr, [x9]
    cbz x0, 2f
    bl _SDL_DestroyTexture
2:  addr x9, Lrenderer
    ldr x0, [x9]
    str xzr, [x9]
    cbz x0, 3f
    bl _SDL_DestroyRenderer
3:  addr x9, Lwindow
    ldr x0, [x9]
    str xzr, [x9]
    cbz x0, 4f
    bl _SDL_DestroyWindow
4:  bl _SDL_Quit
    addr x9, Lactive
    str wzr, [x9]
    addr x9, Lmouse_buttons
    str wzr, [x9]
    addr x0, Lkeys
    mov x1, #256
    bl _bzero
    ldp x29, x30, [sp], #16
    ret

.globl _doom_platform_ticks
// x0=monotonic SDL milliseconds. Tail call, stack 0.
_doom_platform_ticks:
    b _SDL_GetTicks
.globl _doom_platform_sleep
// w0=unsigned milliseconds. Tail call, stack 0.
_doom_platform_sleep:
    b _SDL_Delay

.globl _doom_platform_poll
// x0 points to writable 32-byte ABI input. w0=1 quit/0 otherwise.
// Key state is bounded to 256 scancodes. Event buffer is SDL's 128 bytes.
// Main thread only. Stack 64 bytes. Polling also replenishes output audio.
_doom_platform_poll:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    stp xzr, xzr, [x19]
    stp xzr, xzr, [x19, #16]
    mov w20, #0
    addr x21, Levent
    addr x22, Lkeys
    addr x9, Lactive
    ldr w9, [x9]
    cbz w9, Lpoll_return
Lpoll_event:
    mov x0, x21
    bl _SDL_PollEvent
    cbz w0, Lpoll_state
    ldr w9, [x21]
    cmp w9, #0x100
    b.eq Lpoll_quit
    cmp w9, #EVENT_CLOSE
    b.eq Lpoll_quit
    cmp w9, #EVENT_FOCUS_LOST
    b.eq Lpoll_focus_lost
    cmp w9, #EVENT_FOCUS_GAIN
    b.eq Lpoll_focus_gain
    cmp w9, #EVENT_KEY_UP
    b.eq Lpoll_key_up
    cmp w9, #EVENT_KEY_DOWN
    b.eq Lpoll_key_down
    cmp w9, #0x400
    b.eq Lpoll_mouse_motion
    cmp w9, #0x401
    b.eq Lpoll_mouse_down
    cmp w9, #0x402
    b.eq Lpoll_mouse_up
    b Lpoll_event
Lpoll_quit:
    mov w20, #1
    b Lpoll_event
Lpoll_focus_lost:
    addr x9, Lfocus
    str wzr, [x9]
    addr x9, _doom_paused
    mov w10, #1
    str w10, [x9]
    mov x0, x22
    mov x1, #256
    bl _bzero
    addr x9, Lmouse_buttons
    str wzr, [x9]
    b Lpoll_release
Lpoll_focus_gain:
    addr x9, Lfocus
    mov w10, #1
    str w10, [x9]
    b Lpoll_event
Lpoll_key_up:
    ldr w9, [x21, #24]
    cmp w9, #256
    b.hs Lpoll_event
    strb wzr, [x22, x9]
    b Lpoll_event
Lpoll_key_down:
    ldr w23, [x21, #24]
    cmp w23, #256
    b.hs Lpoll_event
    mov w10, #1
    strb w10, [x22, x23]
    ldrb w10, [x21, #37]
    cbnz w10, Lpoll_event
    cmp w23, #41
    b.eq Lpoll_escape
    cmp w23, #40
    b.eq Lpoll_enter
    cmp w23, #82
    b.eq Lpoll_up
    cmp w23, #81
    b.eq Lpoll_down
    cmp w23, #19
    b.eq Lpoll_pause
    cmp w23, #62
    b.eq Lpoll_save
    cmp w23, #66
    b.eq Lpoll_load
    cmp w23, #68
    b.eq Lpoll_fullscreen
    sub w9, w23, #30
    cmp w9, #7
    b.hs Lpoll_event
    add w9, w9, #1
    str w9, [x19, #16]
    b Lpoll_event
Lpoll_escape:
    mov w9, #1
    str w9, [x19, #20]
Lpoll_release:
    addr x9, Lwindow
    ldr x0, [x9]
    mov w1, #0
    bl _SDL_SetWindowRelativeMouseMode
    b Lpoll_event
Lpoll_enter:
    mov w9, #2
    str w9, [x19, #20]
    b Lpoll_capture
Lpoll_up:
    mov w9, #3
    str w9, [x19, #20]
    b Lpoll_event
Lpoll_down:
    mov w9, #4
    str w9, [x19, #20]
    b Lpoll_event
Lpoll_pause:
    ldr w9, [x19, #12]
    orr w9, w9, #8
    str w9, [x19, #12]
    b Lpoll_event
Lpoll_save:
    mov w9, #1
    str w9, [x19, #24]
    b Lpoll_event
Lpoll_load:
    mov w9, #2
    str w9, [x19, #24]
    b Lpoll_event
Lpoll_fullscreen:
    addr x9, Lfullscreen
    ldr w1, [x9]
    eor w1, w1, #1
    str w1, [x9]
    addr x9, Lwindow
    ldr x0, [x9]
    bl _SDL_SetWindowFullscreen
    b Lpoll_event
Lpoll_mouse_motion:
    addr x9, Lfocus
    ldr w9, [x9]
    cbz w9, Lpoll_event
    ldr s0, [x21, #36]
    addr x9, Lmouse_scale
    ldr s1, [x9]
    fmul s0, s0, s1
    ldr s1, [x19, #8]
    fadd s0, s0, s1
    str s0, [x19, #8]
    b Lpoll_event
Lpoll_mouse_down:
    ldrb w9, [x21, #24]
    cmp w9, #1
    b.ne Lpoll_event
    addr x9, Lmouse_buttons
    mov w10, #1
    str w10, [x9]
Lpoll_capture:
    addr x9, Lwindow
    ldr x0, [x9]
    mov w1, #1
    bl _SDL_SetWindowRelativeMouseMode
    b Lpoll_event
Lpoll_mouse_up:
    ldrb w9, [x21, #24]
    cmp w9, #1
    b.ne Lpoll_event
    addr x9, Lmouse_buttons
    str wzr, [x9]
    b Lpoll_event
Lpoll_state:
    addr x9, Lfocus
    ldr w9, [x9]
    cbz w9, Lpoll_audio
    fmov s4, #4.0
    ldrb w9, [x22, #225]
    ldrb w10, [x22, #229]
    orr w9, w9, w10
    cbz w9, 1f
    fmov s4, #8.0
    ldr w9, [x19, #12]
    orr w9, w9, #4
    str w9, [x19, #12]
1:  ldrb w9, [x22, #26]
    ldrb w10, [x22, #82]
    orr w9, w9, w10
    ldrb w10, [x22, #22]
    ldrb w11, [x22, #81]
    orr w10, w10, w11
    sub w9, w9, w10
    scvtf s0, w9
    fmul s0, s0, s4
    str s0, [x19]
    ldrb w9, [x22, #7]
    ldrb w10, [x22, #4]
    sub w9, w9, w10
    scvtf s0, w9
    fmul s0, s0, s4
    str s0, [x19, #4]
    ldrb w9, [x22, #80]
    ldrb w10, [x22, #79]
    sub w9, w9, w10
    scvtf s0, w9
    addr x9, Lkey_turn
    ldr s1, [x9]
    fmul s0, s0, s1
    ldr s1, [x19, #8]
    fadd s0, s0, s1
    fmov s2, #0.5
    fmin s0, s0, s2
    fneg s2, s2
    fmax s0, s0, s2
    str s0, [x19, #8]
    ldrb w9, [x22, #224]
    ldrb w10, [x22, #228]
    orr w9, w9, w10
    addr x10, Lmouse_buttons
    ldr w10, [x10]
    orr w9, w9, w10
    ldr w10, [x19, #12]
    cbz w9, 2f
    orr w10, w10, #2
2:  ldrb w9, [x22, #8]
    ldrb w11, [x22, #44]
    orr w9, w9, w11
    cbz w9, 3f
    orr w10, w10, #1
3:  str w10, [x19, #12]
Lpoll_audio:
    bl Laudio_pump
Lpoll_return:
    mov w0, w20
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

.globl _doom_platform_present
// x0=borrowed 320*200 u32 ARGB pixels. Stack 32 bytes; no retained frame.
// 320x200 texture fills a 320x240 logical area, letterboxed to preserve 4:3.
_doom_platform_present:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x19, x0
    addr x9, Ltexture
    ldr x0, [x9]
    cbz x0, Lpresent_done
    mov x1, #0
    mov x2, x19
    mov w3, #1280
    bl _SDL_UpdateTexture
    cbz w0, Lpresent_error
    addr x9, Lrenderer
    ldr x19, [x9]
    mov x0, x19
    mov w1, #0
    mov w2, #0
    mov w3, #0
    mov w4, #255
    bl _SDL_SetRenderDrawColor
    mov x0, x19
    bl _SDL_RenderClear
    mov x0, x19
    addr x9, Ltexture
    ldr x1, [x9]
    mov x2, #0
    addr x3, Ldisplay_rect
    bl _SDL_RenderTexture
    cbz w0, Lpresent_error
    mov x0, x19
    bl _SDL_RenderPresent
    cbnz w0, Lpresent_done
Lpresent_error:
    bl Lsave_error
Lpresent_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// Refill at most four 1024-frame blocks. Queue is bounded to ~86ms.
// Main thread only. Stack 48 bytes. SDL owns a copy of submitted PCM.
Laudio_pump:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    addr x9, Laudio
    ldr x19, [x9]
    cbz x19, Laudio_pump_done
    mov w20, #4
Laudio_pump_loop:
    mov x0, x19
    bl _SDL_GetAudioStreamQueued
    cmp w0, #12288
    b.ge Laudio_pump_done
    tbnz w0, #31, Laudio_pump_error
    addr x0, Lmix_buffer
    mov w1, #MIX_FRAMES
    bl _doom_audio_mix
    mov x0, x19
    addr x1, Lmix_buffer
    mov w2, #4096
    bl _SDL_PutAudioStreamData
    cbz w0, Laudio_pump_error
    subs w20, w20, #1
    b.ne Laudio_pump_loop
    b Laudio_pump_done
Laudio_pump_error:
    bl Lsave_error
    mov x0, x19
    bl _SDL_DestroyAudioStream
    addr x9, Laudio
    str xzr, [x9]
Laudio_pump_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

.globl _doom_sound
// w0 advisory sound id, x1 borrowed NUL/8-byte DS lump name. Stack 32 bytes.
// Validate Doom format3, rate 1..48000, count<=lump-8 before queuing.
// Owns no sample bytes; immutable WAD remains alive until platform shutdown.
_doom_sound:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    addr x9, Laudio
    ldr x9, [x9]
    cbz x9, Lsound_done
    cbz x1, Lsound_done
    mov x0, x1
    bl _doom_lump
    cbz x0, Lsound_done
    cmp x1, #8
    b.lo Lsound_done
    ldrh w9, [x0]
    cmp w9, #3
    b.ne Lsound_done
    ldrh w10, [x0, #2]
    cbz w10, Lsound_done
    mov w11, #SAMPLE_RATE
    cmp w10, w11
    b.hi Lsound_done
    ldr w12, [x0, #4]
    cbz w12, Lsound_done
    sub x1, x1, #8
    cmp x12, x1
    b.hi Lsound_done
    addr x13, Lsfx_next
    ldr w14, [x13]
    add w15, w14, #1
    and w15, w15, #7
    str w15, [x13]
    addr x13, Lsfx
    add x13, x13, x14, lsl #5
    add x0, x0, #8
    str x0, [x13]
    str w12, [x13, #8]
    str wzr, [x13, #12]
    str wzr, [x13, #16]
    lsl w10, w10, #16
    udiv w10, w10, w11
    str w10, [x13, #20]
    mov w10, #1
    str w10, [x13, #24]
Lsound_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl _doom_music
// x0=NUL/8-byte MUS lump name, or NULL to stop. Stack 48 bytes.
// Bounded MUS v1 score parser; 16 channels, 32 synthesized voices, 140Hz clock.
// Timbres are pulse/triangle/saw/noise families, not a General MIDI sound bank.
// No-init/headless calls are harmless. WAD memory is borrowed and immutable.
_doom_music:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    bl Lmusic_stop
    cbz x19, Lmusic_done
    addr x9, Laudio
    ldr x9, [x9]
    cbz x9, Lmusic_done
    mov x0, x19
    bl _doom_lump
    cbz x0, Lmusic_done
    mov x19, x0
    mov x20, x1
    bl Lchannels_reset
    mov x0, x19
    mov x1, x20
    cmp x1, #14
    b.lo Lmusic_done
    ldr w9, [x0]
    mov w10, #0x544d
    movk w10, #0x6468, lsl #16
    cmp w9, w10
    b.ne 9f
    bl Lmidi_init
    b Lmusic_done
9:
    cmp x1, #16
    b.lo Lmusic_done
    ldr w9, [x0]
    mov w10, #0x554d
    movk w10, #0x1a53, lsl #16
    cmp w9, w10
    b.ne Lmusic_done
    ldrh w9, [x0, #4]
    cbz w9, Lmusic_done
    ldrh w10, [x0, #6]
    ldrh w11, [x0, #8]
    cmp w11, #16
    b.hi Lmusic_done
    ldrh w11, [x0, #12]
    add w11, w11, w11
    add w11, w11, #16
    cmp w10, w11
    b.lo Lmusic_done
    add x11, x10, x9
    cmp x11, x1
    b.hi Lmusic_done
    add x10, x0, x10
    add x11, x0, x11
    addr x9, Lmusic_state
    str x10, [x9]
    str x11, [x9, #8]
    str x10, [x9, #16]
    mov w10, #1
    str w10, [x9, #32]
    b Lmusic_done

// Reset the bounded channel bank. Leaf, stack0.
Lchannels_reset:
    addr x9, Lsustain
    stp xzr, xzr, [x9]
    addr x9, Lchannels
    mov w10, #16
    mov w11, #100
    mov w12, #128
1:  str w11, [x9]
    str w11, [x9, #4]
    str wzr, [x9, #8]
    str w12, [x9, #12]
    add x9, x9, #16
    subs w10, w10, #1
    b.ne 1b
    ret

Lmusic_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// Stop synthesis and reset cursor. No input; caller registers clobbered.
// No SDL calls. Leaf, stack0. Does not clear queued SDL output (<=86ms).
Lmusic_stop:
    addr x9, Lmusic_state
    stp xzr, xzr, [x9]
    stp xzr, xzr, [x9, #16]
    stp xzr, xzr, [x9, #32]
    addr x9, Lvoices
    mov w10, #64
1:  stp xzr, xzr, [x9], #16
    subs w10, w10, #1
    b.ne 1b
    ret

// Fetch one bounded MUS byte. w0=0..255 or -1. Leaf, stack0.
Lmusic_byte:
    addr x9, Lmusic_state
    ldr x10, [x9, #16]
    ldr x11, [x9, #8]
    cmp x10, x11
    b.hs 1f
    ldrb w0, [x10], #1
    str x10, [x9, #16]
    ret
1:  mov w0, #-1
    ret

// Apply channel pitch to note increment. w0=note0..127,w1=pitch0..255.
// x0=unsigned phase step. MUS pitch bend approximates +/-2 semitones.
// Relative pitch uses a bounded linear frequency approximation. Leaf, stack0.
Lmusic_step:
    addr x9, Lnote_steps
    ldr w0, [x9, x0, lsl #2]
    sub w1, w1, #128
    mov w9, #60
    madd w1, w1, w9, wzr
    mov w9, #1
    lsl w9, w9, #16
    add w1, w1, w9
    umull x0, w0, w1
    lsr x0, x0, #16
    ret

// Consume one 140Hz score tick. Corrupt streams stop music, never read beyond
// validated score bounds. Max512 events and max4 variable delay bytes per tick.
// Stack96; preserves all callee-saved registers used.
Lmusic_tick:
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    addr x19, Lmusic_state
    ldr w9, [x19, #32]
    cbz w9, Lmus_tick_done
    ldr w9, [x19, #24]
    cbz w9, Lmus_events
    sub w9, w9, #1
    str w9, [x19, #24]
    cbnz w9, Lmus_tick_done
Lmus_events:
    mov w28, #512
Lmus_event:
    subs w28, w28, #1
    b.eq Lmus_bad
    bl Lmusic_byte
    tbnz w0, #31, Lmus_bad
    mov w20, w0
    and w21, w20, #15
    ubfx w22, w20, #4, #3
    addr x23, Lchannels
    add x23, x23, x21, lsl #4
    cmp w22, #0
    b.eq Lmus_release
    cmp w22, #1
    b.eq Lmus_play
    cmp w22, #2
    b.eq Lmus_pitch
    cmp w22, #3
    b.eq Lmus_system
    cmp w22, #4
    b.eq Lmus_controller
    cmp w22, #6
    b.eq Lmus_end
    b Lmus_bad
Lmus_release:
    bl Lmusic_byte
    cmp w0, #127
    b.hi Lmus_bad
    mov w1, w0
    mov w0, w21
    bl Lnote_off
    b Lmus_delay
Lmus_play:
    bl Lmusic_byte
    tbnz w0, #31, Lmus_bad
    and w24, w0, #127
    tbz w0, #7, 1f
    bl Lmusic_byte
    cmp w0, #127
    b.hi Lmus_bad
    str w0, [x23, #4]
1:  addr x25, Lvoices
    mov w26, #MUSIC_VOICES
2:  ldr w9, [x25, #20]
    cbz w9, Lmus_play_found
    add x25, x25, #32
    subs w26, w26, #1
    b.ne 2b
    ldr w9, [x19, #36]
    add w10, w9, #1
    and w10, w10, #31
    str w10, [x19, #36]
    addr x25, Lvoices
    add x25, x25, x9, lsl #5
Lmus_play_found:
    mov w0, w24
    ldr w1, [x23, #12]
    bl Lmusic_step
    str wzr, [x25]
    str w0, [x25, #4]
    ldr w9, [x23]
    ldr w10, [x23, #4]
    mul w9, w9, w10
    lsr w9, w9, #4
    str w9, [x25, #8]
    str w21, [x25, #12]
    str w24, [x25, #16]
    mov w9, #1
    str w9, [x25, #20]
    ldr w9, [x23, #8]
    ldr w11, [x23, #4]
    orr w9, w9, w11, lsl #8
    cmp w21, #15
    mov w10, #3
    orr w10, w10, w11, lsl #8
    csel w9, w10, w9, eq
    str w9, [x25, #24]
    str wzr, [x25, #28]
    b Lmus_delay
Lmus_pitch:
    bl Lmusic_byte
    tbnz w0, #31, Lmus_bad
    str w0, [x23, #12]
    addr x25, Lvoices
    mov w26, #MUSIC_VOICES
1:  ldr w9, [x25, #12]
    cmp w9, w21
    b.ne 2f
    ldr w0, [x25, #16]
    ldr w1, [x23, #12]
    bl Lmusic_step
    str w0, [x25, #4]
2:  add x25, x25, #32
    subs w26, w26, #1
    b.ne 1b
    b Lmus_delay
Lmus_system:
    bl Lmusic_byte
    cmp w0, #14
    b.hi Lmus_bad
    cmp w0, #10
    b.lo Lmus_bad
    cmp w0, #11
    b.hi Lmus_delay
    addr x25, Lvoices
    mov w26, #MUSIC_VOICES
1:  ldr w9, [x25, #12]
    cmp w9, w21
    b.ne 2f
    str wzr, [x25, #20]
2:  add x25, x25, #32
    subs w26, w26, #1
    b.ne 1b
    b Lmus_delay
Lmus_controller:
    bl Lmusic_byte
    cmp w0, #9
    b.hi Lmus_bad
    mov w24, w0
    bl Lmusic_byte
    cmp w0, #127
    b.hi Lmus_bad
    cbnz w24, 1f
    str w0, [x23, #8]
1:  cmp w24, #3
    b.ne 2f
    mov w1, w0
    mov w0, w21
    bl Lchannel_volume
    b Lmus_delay
2:  cmp w24, #8
    b.ne Lmus_delay
    mov w1, w0
    mov w0, w21
    bl Lchannel_sustain
    b Lmus_delay
Lmus_end:
    ldr x9, [x19]
    str x9, [x19, #16]
    mov w9, #1
    str w9, [x19, #24]
    addr x9, Lvoices
    mov w10, #64
1:  stp xzr, xzr, [x9], #16
    subs w10, w10, #1
    b.ne 1b
    b Lmus_tick_done
Lmus_delay:
    tbz w20, #7, Lmus_event
    mov w24, #0
    mov w25, #4
1:  bl Lmusic_byte
    tbnz w0, #31, Lmus_bad
    lsl w24, w24, #7
    and w9, w0, #127
    orr w24, w24, w9
    tbz w0, #7, 2f
    subs w25, w25, #1
    b.ne 1b
    b Lmus_bad
2:  str w24, [x19, #24]
    cbz w24, Lmus_event
    b Lmus_tick_done
Lmus_bad:
    bl Lmusic_stop
Lmus_tick_done:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// MIDI supplements MUS because the bundled Freedoom scores use SMF format1.
// All parsing, track merging, tempo scheduling and synthesis remain assembly.
// Supports format0/1, up to32 tracks, PPQN1..960, channel voice messages,
// bounded meta/SysEx skipping, tempo, program, volume, pitch and note release.
// Expression/spatial controllers are not modeled. Tempo<100000us per
// quarter is clamped to600BPM to bound scheduler work. No MIDI bytes execute.

// x0 cursor,x1 end -> w0 variable integer,x1 next cursor; x1=0 invalid.
// A MIDI variable integer has at most4 bytes. Leaf, stack0.
Lmidi_vlen:
    mov x9, x0
    mov x10, x1
    mov w0, #0
    mov w11, #4
1:  cmp x9, x10
    b.hs 3f
    ldrb w12, [x9], #1
    lsl w0, w0, #7
    and w13, w12, #127
    orr w0, w0, w13
    tbz w12, #7, 2f
    subs w11, w11, #1
    b.ne 1b
3:  mov x1, #0
    ret
2:  mov x1, x9
    ret

// x0 validated lump pointer,x1 length. Initialize bounded track cursors.
// Failure leaves music stopped. Stack80 bytes.
Lmidi_init:
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    add x20, x0, x1
    ldr w9, [x19, #4]
    rev w9, w9
    cmp w9, #6
    b.ne Lmidi_init_bad
    ldrh w9, [x19, #8]
    rev16 w9, w9
    cmp w9, #1
    b.hi Lmidi_init_bad
    ldrh w21, [x19, #10]
    rev16 w21, w21
    cbz w21, Lmidi_init_bad
    cmp w21, #32
    b.hi Lmidi_init_bad
    cbnz w9, 1f
    cmp w21, #1
    b.ne Lmidi_init_bad
1:
    ldrh w9, [x19, #12]
    rev16 w9, w9
    cbz w9, Lmidi_init_bad
    cmp w9, #960
    b.hi Lmidi_init_bad
    addr x25, Lmidi_state
    stp xzr, xzr, [x25]
    str w9, [x25, #16]
    str w21, [x25, #20]
    mov w9, #0xa120
    movk w9, #7, lsl #16
    str w9, [x25, #12]
    bl Lmidi_tempo_step
    add x19, x19, #14
    addr x22, Lmidi_tracks
Lmidi_init_track:
    sub x9, x20, x19
    cmp x9, #8
    b.lo Lmidi_init_bad
    ldr w9, [x19]
    mov w10, #0x544d
    movk w10, #0x6b72, lsl #16
    cmp w9, w10
    b.ne Lmidi_init_bad
    ldr w9, [x19, #4]
    rev w9, w9
    add x19, x19, #8
    sub x10, x20, x19
    cmp x9, x10
    b.hi Lmidi_init_bad
    cbz w9, Lmidi_init_bad
    add x24, x19, x9
    str x24, [x22, #8]
    str x19, [x22, #32]
    mov x0, x19
    mov x1, x24
    bl Lmidi_vlen
    cbz x1, Lmidi_init_bad
    str x1, [x22]
    str w0, [x22, #16]
    str wzr, [x22, #20]
    str wzr, [x22, #24]
    mov x19, x24
    add x22, x22, #48
    subs w21, w21, #1
    b.ne Lmidi_init_track
    addr x9, Lmusic_state
    mov w10, #1
    str w10, [x9, #32]
    str w10, [x9, #44]
    b Lmidi_init_return
Lmidi_init_bad:
    bl Lmusic_stop
Lmidi_init_return:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// Compute MIDI ticks/sample in unsigned Q24. State owns tempo/division.
// Inputs already bounded. Leaf, stack0; x9-x14 clobbered.
Lmidi_tempo_step:
    addr x9, Lmidi_state
    ldr w10, [x9, #16]
    mov w11, #0x4240
    movk w11, #15, lsl #16
    umull x10, w10, w11
    lsl x10, x10, #24
    ldr w11, [x9, #12]
    mov w12, #SAMPLE_RATE
    umull x11, w11, w12
    udiv x10, x10, x11
    str w10, [x9, #8]
    ret

// w0=channel0..15,w1=note0..127,w2=velocity0..127. Stack48.
// Allocate one bounded synth voice. Phase and amplitude belong to the mixer.
Lnote_on:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    mov w20, w1
    mov w21, w2
    addr x22, Lvoices
    mov w9, #MUSIC_VOICES
1:  ldr w10, [x22, #20]
    cbz w10, 3f
    add x22, x22, #32
    subs w9, w9, #1
    b.ne 1b
    addr x9, Lmusic_state
    ldr w10, [x9, #36]
    add w11, w10, #1
    and w11, w11, #31
    str w11, [x9, #36]
    addr x22, Lvoices
    add x22, x22, x10, lsl #5
3:  addr x9, Lchannels
    add x9, x9, x19, lsl #4
    ldr w1, [x9, #12]
    mov w0, w20
    bl Lmusic_step
    str wzr, [x22]
    str w0, [x22, #4]
    addr x9, Lchannels
    add x9, x9, x19, lsl #4
    ldr w10, [x9]
    mul w10, w10, w21
    lsr w10, w10, #4
    str w10, [x22, #8]
    str w19, [x22, #12]
    str w20, [x22, #16]
    mov w10, #1
    str w10, [x22, #20]
    ldr w10, [x9, #8]
    orr w10, w10, w21, lsl #8
    cmp w19, #15
    mov w11, #3
    orr w11, w11, w21, lsl #8
    csel w10, w11, w10, eq
    str w10, [x22, #24]
    str wzr, [x22, #28]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// w0=channel,w1=note. Mark matching voices for bounded release. Leaf, stack0.
Lnote_off:
    addr x9, Lsustain
    ldrb w12, [x9, x0]
    mov w13, #1
    cmp w12, #0
    cinc w13, w13, ne
    addr x9, Lvoices
    mov w10, #MUSIC_VOICES
1:  ldr w11, [x9, #12]
    cmp w11, w0
    b.ne 2f
    ldr w11, [x9, #16]
    cmp w11, w1
    b.ne 2f
    str w13, [x9, #28]
2:  add x9, x9, #32
    subs w10, w10, #1
    b.ne 1b
    ret

// w0=channel,w1=volume0..127. Apply volume to all current voices. Leaf, stack0.
Lchannel_volume:
    addr x9, Lchannels
    add x9, x9, x0, lsl #4
    str w1, [x9]
    addr x9, Lvoices
    mov w10, #MUSIC_VOICES
1:  ldr w11, [x9, #12]
    cmp w11, w0
    b.ne 2f
    ldr w11, [x9, #24]
    ubfx w11, w11, #8, #7
    mul w11, w11, w1
    lsr w11, w11, #4
    str w11, [x9, #8]
2:  add x9, x9, #32
    subs w10, w10, #1
    b.ne 1b
    ret

// w0=channel,w1=sustain0..127. Release held notes when pedal lifts. Leaf.
Lchannel_sustain:
    addr x9, Lsustain
    cmp w1, #64
    cset w10, hs
    strb w10, [x9, x0]
    cbnz w10, 3f
    addr x9, Lvoices
    mov w10, #MUSIC_VOICES
1:  ldr w11, [x9, #12]
    cmp w11, w0
    b.ne 2f
    ldr w11, [x9, #28]
    cmp w11, #2
    b.ne 2f
    mov w11, #1
    str w11, [x9, #28]
2:  add x9, x9, #32
    subs w10, w10, #1
    b.ne 1b
3:  ret

// Advance MIDI at the audio sample rate. Stack32. At most one tick/sample
// under the declared PPQN/tempo bounds. Initial tick is processed immediately.
Lmidi_sample:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    addr x19, Lmidi_state
    addr x9, Lmusic_state
    ldr w10, [x9, #40]
    cbnz w10, 1f
    mov w10, #1
    str w10, [x9, #40]
    bl Lmidi_tick
1:  ldr w9, [x19, #4]
    ldr w10, [x19, #8]
    add w9, w9, w10
    mov w10, #0x1000000
    cmp w9, w10
    b.lo 2f
    sub w9, w9, w10
    str w9, [x19, #4]
    ldr w9, [x19]
    add w9, w9, #1
    str w9, [x19]
    bl Lmidi_tick
    b 3f
2:  str w9, [x19, #4]
3:  ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// Merge up to32 MIDI tracks at their absolute tick. Each track is independently
// bounded. At most4096 events/tick, including zero-time events. Stack96.
Lmidi_tick:
    stp x29, x30, [sp, #-96]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    addr x19, Lmidi_state
    addr x20, Lmidi_tracks
    ldr w21, [x19, #20]
    mov w28, #4096
    mov w27, #0
Lmidi_track:
    ldr w9, [x20, #24]
    cbnz w9, Lmidi_next_track
    add w27, w27, #1
Lmidi_event:
    ldr w9, [x20, #16]
    ldr w10, [x19]
    cmp w10, w9
    b.lo Lmidi_next_track
    subs w28, w28, #1
    b.eq Lmidi_bad
    ldr x22, [x20]
    ldr x23, [x20, #8]
    cmp x22, x23
    b.hs Lmidi_bad
    ldrb w24, [x22], #1
    cmp w24, #0x80
    b.hs 1f
    sub x22, x22, #1
    ldr w24, [x20, #20]
    cmp w24, #0x80
    b.lo Lmidi_bad
    b 2f
1:  cmp w24, #0xf0
    b.hs Lmidi_special
    str w24, [x20, #20]
2:  cmp x22, x23
    b.hs Lmidi_bad
    ldrb w25, [x22], #1
    cmp w25, #127
    b.hi Lmidi_bad
    and w9, w24, #0xf0
    cmp w9, #0xc0
    b.eq Lmidi_program
    cmp w9, #0xd0
    b.eq Lmidi_finish_event
    cmp x22, x23
    b.hs Lmidi_bad
    ldrb w26, [x22], #1
    cmp w26, #127
    b.hi Lmidi_bad
    and w0, w24, #15
    bl Lmidi_channel
    mov w24, w0
    cmp w9, #0x80
    b.eq Lmidi_release
    cmp w9, #0x90
    b.eq Lmidi_note
    cmp w9, #0xb0
    b.eq Lmidi_controller
    cmp w9, #0xe0
    b.eq Lmidi_pitch
    b Lmidi_finish_event
Lmidi_note:
    cbz w26, Lmidi_release
    mov w0, w24
    mov w1, w25
    mov w2, w26
    bl Lnote_on
    b Lmidi_finish_event
Lmidi_release:
    mov w0, w24
    mov w1, w25
    bl Lnote_off
    b Lmidi_finish_event
Lmidi_program:
    and w0, w24, #15
    bl Lmidi_channel
    addr x9, Lchannels
    add x9, x9, x0, lsl #4
    str w25, [x9, #8]
    b Lmidi_finish_event
Lmidi_controller:
    cmp w25, #7
    b.eq 1f
    cmp w25, #64
    b.eq 5f
    cmp w25, #120
    b.eq 2f
    cmp w25, #123
    b.eq 2f
    b Lmidi_finish_event
1:  mov w0, w24
    mov w1, w26
    bl Lchannel_volume
    b Lmidi_finish_event
5:  mov w0, w24
    mov w1, w26
    bl Lchannel_sustain
    b Lmidi_finish_event
2:  addr x9, Lvoices
    mov w10, #MUSIC_VOICES
3:  ldr w11, [x9, #12]
    cmp w11, w24
    b.ne 4f
    str wzr, [x9, #20]
4:  add x9, x9, #32
    subs w10, w10, #1
    b.ne 3b
    b Lmidi_finish_event
Lmidi_pitch:
    lsl w26, w26, #7
    orr w26, w26, w25
    lsr w26, w26, #6
    addr x9, Lchannels
    add x9, x9, x24, lsl #4
    str w26, [x9, #12]
    addr x25, Lvoices
    mov w26, #MUSIC_VOICES
1:  ldr w9, [x25, #12]
    cmp w9, w24
    b.ne 2f
    ldr w0, [x25, #16]
    addr x9, Lchannels
    add x9, x9, x24, lsl #4
    ldr w1, [x9, #12]
    bl Lmusic_step
    str w0, [x25, #4]
2:  add x25, x25, #32
    subs w26, w26, #1
    b.ne 1b
    b Lmidi_finish_event
Lmidi_special:
    cmp w24, #0xff
    b.eq Lmidi_meta
    cmp w24, #0xf0
    b.eq 1f
    cmp w24, #0xf7
    b.ne Lmidi_bad
1:  str wzr, [x20, #20]
    mov x0, x22
    mov x1, x23
    bl Lmidi_vlen
    cbz x1, Lmidi_bad
    sub x9, x23, x1
    cmp x0, x9
    b.hi Lmidi_bad
    add x22, x1, x0
    b Lmidi_finish_event
Lmidi_meta:
    str wzr, [x20, #20]
    cmp x22, x23
    b.hs Lmidi_bad
    ldrb w25, [x22], #1
    cmp w25, #127
    b.hi Lmidi_bad
    mov x0, x22
    mov x1, x23
    bl Lmidi_vlen
    cbz x1, Lmidi_bad
    sub x9, x23, x1
    cmp x0, x9
    b.hi Lmidi_bad
    add x22, x1, x0
    cmp w25, #0x2f
    b.eq Lmidi_end_track
    cmp w25, #0x51
    b.ne Lmidi_finish_event
    cmp w0, #3
    b.ne Lmidi_bad
    ldrb w9, [x1]
    ldrb w10, [x1, #1]
    ldrb w11, [x1, #2]
    lsl w9, w9, #16
    orr w9, w9, w10, lsl #8
    orr w9, w9, w11
    cbz w9, Lmidi_bad
    mov w10, #0x86a0
    movk w10, #1, lsl #16
    cmp w9, w10
    csel w9, w10, w9, lo
    str w9, [x19, #12]
    bl Lmidi_tempo_step
Lmidi_finish_event:
    mov x0, x22
    mov x1, x23
    bl Lmidi_vlen
    cbz x1, Lmidi_bad
    str x1, [x20]
    ldr w9, [x20, #16]
    adds w9, w9, w0
    b.cs Lmidi_bad
    str w9, [x20, #16]
    b Lmidi_event
Lmidi_end_track:
    cbnz w0, Lmidi_bad
    cmp x22, x23
    b.ne Lmidi_bad
    mov w9, #1
    str w9, [x20, #24]
    sub w27, w27, #1
Lmidi_next_track:
    add x20, x20, #48
    subs w21, w21, #1
    b.ne Lmidi_track
    cbnz w27, Lmidi_tick_done
    ldr w9, [x19]
    cbz w9, Lmidi_bad
    // Loop the original immutable track streams after every track has ended.
    str wzr, [x19]
    str wzr, [x19, #4]
    mov w9, #0xa120
    movk w9, #7, lsl #16
    str w9, [x19, #12]
    bl Lmidi_tempo_step
    addr x20, Lmidi_tracks
    ldr w21, [x19, #20]
1:  ldr x0, [x20, #32]
    ldr x1, [x20, #8]
    bl Lmidi_vlen
    cbz x1, Lmidi_bad
    str x1, [x20]
    str w0, [x20, #16]
    str wzr, [x20, #20]
    str wzr, [x20, #24]
    add x20, x20, #48
    subs w21, w21, #1
    b.ne 1b
    addr x9, Lmusic_state
    str wzr, [x9, #40]
    addr x9, Lvoices
    mov w10, #64
2:  stp xzr, xzr, [x9], #16
    subs w10, w10, #1
    b.ne 2b
    bl Lchannels_reset
    b Lmidi_tick_done
Lmidi_bad:
    bl Lmusic_stop
Lmidi_tick_done:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// Map MIDI percussion channel9 to MUS percussion15, swapping melodic15 to9.
// w0=channel ->w0 internal channel. Leaf; preserves x9 type dispatch register.
Lmidi_channel:
    cmp w0, #9
    b.eq 1f
    cmp w0, #15
    mov w10, #9
    csel w0, w10, w0, eq
    ret
1:  mov w0, #15
    ret

.globl _doom_audio_mix
// Internal deterministic PCM routine. x0=writable interleaved signed16 stereo;
// w1=frame count 0..4096. Larger counts produce no writes. Stack80 bytes.
// Consumes bounded SFX/MUS state on the main thread. Both channels are equal.
// Samples saturate to signed16. Source resampling uses fixed16.16 phase.
_doom_audio_mix:
    cmp w1, #4096
    b.hi Lmix_noop
    cbz w1, Lmix_noop
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov w20, w1
    addr x21, Lsfx
    addr x22, Lvoices
    addr x23, Lmusic_state
Lmix_sample:
    // Parse initial event immediately, then advance the 140Hz MUS clock.
    ldr w9, [x23, #32]
    cbz w9, Lmix_effects
    ldr w9, [x23, #44]
    cbz w9, 9f
    bl Lmidi_sample
    b Lmix_effects
9:
    ldr w9, [x23, #40]
    cbnz w9, 1f
    mov w9, #1
    str w9, [x23, #40]
    bl Lmusic_tick
1:  ldr w9, [x23, #28]
    add w9, w9, #140
    mov w10, #SAMPLE_RATE
    cmp w9, w10
    b.lo 2f
    sub w9, w9, w10
    str w9, [x23, #28]
    bl Lmusic_tick
    b Lmix_effects
2:  str w9, [x23, #28]
Lmix_effects:
    mov w24, #0
    mov x25, x21
    mov w26, #SFX_VOICES
Lmix_sfx:
    ldr w9, [x25, #24]
    cbz w9, Lmix_sfx_next
    ldr w10, [x25, #12]
    ldr w11, [x25, #8]
    cmp w10, w11
    b.hs Lmix_sfx_end
    ldr x9, [x25]
    ldrb w9, [x9, x10]
    sub w9, w9, #128
    add w24, w24, w9, lsl #4
    ldr w9, [x25, #16]
    ldr w11, [x25, #20]
    add w9, w9, w11
    add w10, w10, w9, lsr #16
    and w9, w9, #65535
    str w9, [x25, #16]
    str w10, [x25, #12]
    b Lmix_sfx_next
Lmix_sfx_end:
    str wzr, [x25, #24]
Lmix_sfx_next:
    add x25, x25, #32
    subs w26, w26, #1
    b.ne Lmix_sfx
    mov x25, x22
    mov w26, #MUSIC_VOICES
Lmix_music:
    ldr w9, [x25, #20]
    cbz w9, Lmix_music_next
    ldr w10, [x25]
    ldr w11, [x25, #4]
    add w10, w10, w11
    str w10, [x25]
    ldr w11, [x25, #8]
    ldr w9, [x25, #28]
    cmp w9, #1
    b.ne 1f
    subs w11, w11, #1
    b.le Lmix_music_end
    str w11, [x25, #8]
1:  ldr w9, [x25, #24]
    and w9, w9, #3
    cmp w9, #1
    b.eq Lmix_triangle
    cmp w9, #2
    b.eq Lmix_saw
    cmp w9, #3
    b.eq Lmix_noise
    tst w10, #0x80000000
    cneg w11, w11, ne
    add w24, w24, w11
    b Lmix_music_next
Lmix_triangle:
    lsr w9, w10, #16
    tst w10, #0x80000000
    mov w12, #65535
    sub w12, w12, w9
    csel w9, w12, w9, ne
    sub w9, w9, #16384
    mul w9, w9, w11
    add w24, w24, w9, asr #14
    b Lmix_music_next
Lmix_saw:
    asr w9, w10, #16
    mul w9, w9, w11
    add w24, w24, w9, asr #15
    b Lmix_music_next
Lmix_noise:
    // Deterministic xorshift; percussion amplitude decays independently.
    addr x9, Lnoise
    ldr w10, [x9]
    eor w10, w10, w10, lsl #13
    eor w10, w10, w10, lsr #17
    eor w10, w10, w10, lsl #5
    str w10, [x9]
    asr w10, w10, #16
    mul w10, w10, w11
    add w24, w24, w10, asr #15
    mov w9, #1
    str w9, [x25, #28]
    b Lmix_music_next
Lmix_music_end:
    str wzr, [x25, #20]
Lmix_music_next:
    add x25, x25, #32
    subs w26, w26, #1
    b.ne Lmix_music
    mov w9, #32767
    cmp w24, w9
    csel w24, w9, w24, gt
    mov w9, #-32768
    cmp w24, w9
    csel w24, w9, w24, lt
    strh w24, [x19], #2
    strh w24, [x19], #2
    subs w20, w20, #1
    b.ne Lmix_sample
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
Lmix_noop:
    ret

.section __TEXT,__const
.p2align 3
Ltitle: .asciz "Asm Doom | W A S D move | mouse turn/fire | E use | Esc menu | F11 fullscreen"
.p2align 2
Laudio_spec: .long 0x8010, 2, SAMPLE_RATE
Ldisplay_rect: .single 0, 0, 320, 240
Lmouse_scale: .single -0.003
Lkey_turn: .single 0.07
// Mathematical phase table: round(440*2^((note-69)/12)*2^32/48000).
// This is static numeric data, not generated engine implementation.
Lnote_steps:
    .long 731558, 775059, 821146, 869974, 921705, 976513, 1034579, 1096099
    .long 1161276, 1230329, 1303488, 1380998, 1463116, 1550118, 1642292, 1739948
    .long 1843411, 1953026, 2069159, 2192197, 2322552, 2460658, 2606977, 2761996
    .long 2926232, 3100235, 3284585, 3479896, 3686822, 3906052, 4138318, 4384395
    .long 4645104, 4921317, 5213953, 5523991, 5852465, 6200470, 6569170, 6959793
    .long 7373644, 7812103, 8276635, 8768789, 9290209, 9842633, 10427907, 11047982
    .long 11704930, 12400941, 13138339, 13919586, 14747287, 15624207, 16553270, 17537579
    .long 18580418, 19685267, 20855814, 22095965, 23409859, 24801882, 26276679, 27839171
    .long 29494575, 31248413, 33106541, 35075158, 37160835, 39370534, 41711627, 44191930
    .long 46819719, 49603764, 52553357, 55678342, 58989149, 62496826, 66213081, 70150316
    .long 74321671, 78741067, 83423255, 88383859, 93639437, 99207528, 105106715, 111356685
    .long 117978298, 124993653, 132426162, 140300631, 148643341, 157482134, 166846509, 176767719
    .long 187278874, 198415056, 210213429, 222713370, 235956596, 249987305, 264852324, 280601263
    .long 297286682, 314964268, 333693018, 353535438, 374557749, 396830112, 420426858, 445426740
    .long 471913192, 499974611, 529704648, 561202526, 594573365, 629928537, 667386037, 707070876
    .long 749115498, 793660223, 840853716, 890853480, 943826385, 999949222, 1059409297, 1122405052

.data
.p2align 3
Lnoise: .long 0x6d2b79f5
.p2align 3
.zerofill __DATA,__bss,Lwindow,8,3
.zerofill __DATA,__bss,Lrenderer,8,3
.zerofill __DATA,__bss,Ltexture,8,3
.zerofill __DATA,__bss,Laudio,8,3
.zerofill __DATA,__bss,Lactive,4,2
.zerofill __DATA,__bss,Lfocus,4,2
.zerofill __DATA,__bss,Lfullscreen,4,2
.zerofill __DATA,__bss,Lmouse_buttons,4,2
.zerofill __DATA,__bss,Lkeys,256,4
.zerofill __DATA,__bss,Levent,128,4
.zerofill __DATA,__bss,Lerror,512,4
.zerofill __DATA,__bss,Lsfx,256,4
.zerofill __DATA,__bss,Lsfx_next,4,2
.zerofill __DATA,__bss,Lvoices,1024,4
.zerofill __DATA,__bss,Lchannels,256,4
.zerofill __DATA,__bss,Lmusic_state,48,4
.zerofill __DATA,__bss,Lmix_buffer,4096,4

.zerofill __DATA,__bss,Lmidi_state,32,4
.zerofill __DATA,__bss,Lmidi_tracks,1536,4
.zerofill __DATA,__bss,Lsustain,16,4
