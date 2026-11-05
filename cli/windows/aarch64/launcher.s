/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Dedicated managed launcher; derived from the existing native argv quoting
 * and explicit three-stream inheritance boundary. x0=payload UTF8 path,
 * x1=original argv, x2=borrowed verified payload HANDLE. x9=full DWORD or -1.
 * Creates suspended, binds exact creation image before ResumeThread, and
 * waits infinitely. Rejected children are terminated and reaped. No job or
 * process group policy is introduced. Handler is owned by this process only.
 * Stack224 plus explicit outgoing16; preserves x19-x29. Closes owned handles.
 */
.text
.macro WM_QUOTE
    cbz x22, .Lwml_fail
    strh w10, [x21], #2
    sub x22, x22, #1
.endm
win_managed_launch:
    stp x29, x30, [sp, #-224]!
    mov x29, sp
    stp x19, x20, [sp, #32]
    stp x21, x22, [sp, #48]
    stp x23, x24, [sp, #64]
    stp x25, x26, [sp, #80]
    stp x27, x28, [sp, #96]
    str xzr, [sp, #192]          /* owned handler registration */
    mov x19, x1
    str x2, [sp, #184]
    mov x20, #0
    mov x25, #0
    mov x26, #0
    mov x27, #0
    ARM_ADDR x1, win_exe_w
    mov x2, #4096
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwml_fail
    ARM_ADDR x21, win_command_w
    mov x22, #32766
    mov x23, #0
.Lwml_arg:
    ldr x0, [x19, x23, lsl #3]
    cbz x0, .Lwml_ready
    cmp x23, #256
    b.hs .Lwml_fail
    ARM_ADDR x1, win_arg_w
    mov x2, #16384
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwml_fail
    ARM_ADDR x24, win_arg_w
    mov w10, #'"'
    WM_QUOTE
.Lwml_char:
    mov x28, #0
.Lwml_slashes:
    ldrh w10, [x24], #2
    cmp w10, #92
    b.ne .Lwml_escaped
    add x28, x28, #1
    b .Lwml_slashes
.Lwml_escaped:
    cbz w10, .Lwml_double
    cmp w10, #'"'
    b.ne .Lwml_keep
.Lwml_double:
    lsl x28, x28, #1
.Lwml_keep:
    mov w11, w10
.Lwml_emit_slash:
    cbz x28, .Lwml_emit_char
    mov w10, #92
    WM_QUOTE
    sub x28, x28, #1
    b .Lwml_emit_slash
.Lwml_emit_char:
    mov w10, w11
    cbz w10, .Lwml_close_quote
    cmp w10, #'"'
    b.ne 1f
    mov w10, #92
    WM_QUOTE
    mov w10, #'"'
1:  WM_QUOTE
    b .Lwml_char
.Lwml_close_quote:
    mov w10, #'"'
    WM_QUOTE
    mov w10, #32
    WM_QUOTE
    add x23, x23, #1
    b .Lwml_arg
.Lwml_ready:
    strh wzr, [x21]
    /* Environment API conversion rejects oversized blocks. */
    mov x0, x20
    ARM_CALL win_environment_block
    tbnz x9, #63, .Lwml_fail
    str x9, [sp, #128]
    /* Duplicate only the selected streams as inheritable handles. */
    mov x0, x25
    cbnz x0, 1f
    mov x0, #0
    ARM_CALL win_handle
1:  ARM_CALL win_inherit_duplicate
    tbnz x9, #63, .Lwml_fail
    str x9, [sp, #136]
    mov x0, x26
    cbnz x0, 2f
    mov x0, #1
    ARM_CALL win_handle
2:  ARM_CALL win_inherit_duplicate
    tbnz x9, #63, .Lwml_close_in
    str x9, [sp, #144]
    mov x0, #2
    ARM_CALL win_handle
    ARM_CALL win_inherit_duplicate
    tbnz x9, #63, .Lwml_close_out
    str x9, [sp, #152]
    ARM_ADDR x10, win_startup_info
    mov x11, #0
3:  str xzr, [x10, x11]
    add x11, x11, #8
    cmp x11, #112
    b.lo 3b
    mov w11, #112
    str w11, [x10]
    mov w11, #256                /* STARTF_USESTDHANDLES */
    str w11, [x10, #60]
    ldr x11, [sp, #136]
    str x11, [x10, #80]
    ldr x11, [sp, #144]
    str x11, [x10, #88]
    ldr x11, [sp, #152]
    str x11, [x10, #96]
    ARM_ADDR x12, win_inherited_handles
    ldr x11, [sp, #136]
    str x11, [x12]
    ldr x11, [sp, #144]
    str x11, [x12, #8]
    ldr x11, [sp, #152]
    str x11, [x12, #16]
    ARM_ADDR x0, win_attribute_list
    mov x1, #1
    mov x2, #0
    add x3, sp, #176
    mov x11, #1024
    str x11, [x3]
    bl InitializeProcThreadAttributeList
    cbz w0, .Lwml_close_err
    ARM_ADDR x0, win_attribute_list
    ARM_ADDR x16, win_startup_info
    str x0, [x16, #104]
    mov x1, #0
    ARM_IMM x2, 0x20002
    ARM_ADDR x3, win_inherited_handles
    mov x4, #24
    mov x5, #0
    mov x6, #0
    bl UpdateProcThreadAttribute
    cbz w0, .Lwml_delete_attrs
    /* Register before owning a child. Console events cannot leave an owned
     * suspended child behind by terminating this launcher during binding. */
    ARM_ADDR x0, win_managed_ctrl
    mov w1, #1
    bl SetConsoleCtrlHandler
    cbz w0, .Lwml_delete_attrs
    mov x10, #1
    str x10, [sp, #192]
    ARM_ADDR x0, win_exe_w
    ARM_ADDR x1, win_command_w
    mov x2, #0
    mov x3, #0
    mov w4, #1
    ARM_IMM w5, 0x80404          /* EXTENDED_STARTUPINFO + UNICODE_ENV */
    ldr x6, [sp, #128]
    mov x7, #0
    sub sp, sp, #16             /* outgoing args9..10, not the saved frame */
    ARM_ADDR x10, win_startup_info
    str x10, [sp]
    ARM_ADDR x10, win_process_info
    str x10, [sp, #8]
    bl CreateProcessW
    add sp, sp, #16
    str w0, [sp, #160]
    ARM_ADDR x0, win_attribute_list
    bl DeleteProcThreadAttributeList
    ldr x0, [sp, #152]
    bl CloseHandle
    ldr x0, [sp, #144]
    bl CloseHandle
    ldr x0, [sp, #136]
    bl CloseHandle
    ldr w10, [sp, #160]
    cbz w10, .Lwml_fail
    ARM_ADDR x16, win_process_info
    ldr x19, [x16]
    ldr x20, [x16, #8]
    mov x0, x19
    ldr x1, [sp, #184]
    ARM_CALL win_child_image_matches
    cbnz x9, .Lwml_reject
    mov x0, x20
    bl ResumeThread
    cmn w0, #1
    b.eq .Lwml_remove_reject
    mov x0, x20
    bl CloseHandle
    mov x0, x19
    mov w1, #-1
    bl WaitForSingleObject
    cbz w0, .Lwml_exit
    b .Lwml_remove_terminate
.Lwml_remove_reject:
.Lwml_reject:
    mov x0, x20
    bl CloseHandle
    b .Lwml_terminate
.Lwml_remove_terminate:
.Lwml_terminate:
    mov x0, x19
    mov w1, #127
    bl TerminateProcess
    mov x0, x19
    mov w1, #-1
    bl WaitForSingleObject
    mov x20, #-1
    b .Lwml_process_close
.Lwml_exit:
    mov x0, x19
    add x1, sp, #160
    bl GetExitCodeProcess
    cbz w0, 5f
    ldr w20, [sp, #160]
    b .Lwml_process_close
5:  mov w20, #127
.Lwml_process_close:
    mov x0, x19
    bl CloseHandle
    mov x9, x20
    b .Lwml_return
.Lwml_delete_attrs:
    ARM_ADDR x0, win_attribute_list
    bl DeleteProcThreadAttributeList
.Lwml_close_err:
    ldr x0, [sp, #152]
    bl CloseHandle
.Lwml_close_out:
    ldr x0, [sp, #144]
    bl CloseHandle
.Lwml_close_in:
    ldr x0, [sp, #136]
    bl CloseHandle
.Lwml_fail:
    mov x9, #-1
.Lwml_return:
    str x9, [sp, #200]
    ldr x10, [sp, #192]
    cbz x10, 9f
    ARM_ADDR x0, win_managed_ctrl
    mov w1, #0
    bl SetConsoleCtrlHandler
9:  ldr x9, [sp, #200]
    ldp x27, x28, [sp, #96]
    ldp x25, x26, [sp, #80]
    ldp x23, x24, [sp, #64]
    ldp x21, x22, [sp, #48]
    ldp x19, x20, [sp, #32]
    ldp x29, x30, [sp], #224
    ret

/* BOOL handler(DWORD event): handles only Ctrl+C0 and Ctrl+Break1 locally.
 * A non-NULL handler does not change inherited console-ignore state. */
win_managed_ctrl:
    cmp w0,#1
    cset w0,ls
    ret
