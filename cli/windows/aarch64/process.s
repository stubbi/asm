/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native Windows process creation and startup; no shell or interpreter.
 */
.text
.macro WIN_QUOTE
    cbz x22, .Lwsp_fail
    strh w10, [x21], #2
    sub x22, x22, #1
.endm
.equ WIN_TOOL_WAIT_MS, 120000
.equ WIN_WAIT_INFINITE, 0xffffffff
/* Populate argc/argv/envp from Windows Unicode APIs. Owns buffers with process
 * lifetime: 1024 argv slots, 32768 UTF8 argument bytes, 131072 environment bytes.
 * Invalid encoding or a capacity overflow terminates with status 2.
 */
win_startup:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    ARM_CALL win_security_init
    bl GetCommandLineW
    add x1, sp, #64
    bl CommandLineToArgvW
    cbz x0, .Lwsu_bad
    mov x19, x0
    ldr w20, [sp, #64]
    cmp w20, #1023
    b.hi .Lwsu_bad
    ARM_ADDR x16, argc
    str x20, [x16]
    ARM_ADDR x21, win_argv
    ARM_ADDR x16, argv
    str x21, [x16]
    ARM_ADDR x22, win_args
    mov x23, #32768
    mov x24, #0
.Lwsu_arg:
    cmp x24, x20
    b.hs .Lwsu_env
    str x22, [x21, x24, lsl #3]
    mov w0, #65001
    mov w1, #0x80
    ldr x2, [x19, x24, lsl #3]
    mov w3, #-1
    mov x4, x22
    mov x5, x23
    mov x6, #0
    mov x7, #0
    bl WideCharToMultiByte
    cbz w0, .Lwsu_bad
    add x22, x22, x0
    sub x23, x23, x0
    add x24, x24, #1
    b .Lwsu_arg
.Lwsu_env:
    str xzr, [x21, x24, lsl #3]
    mov x0, x19
    bl LocalFree
    bl GetEnvironmentStringsW
    cbz x0, .Lwsu_bad
    mov x19, x0
    mov x20, x0
    ARM_ADDR x21, win_env_ptrs
    ARM_ADDR x16, envp
    str x21, [x16]
    ARM_ADDR x22, win_env_utf8
    ARM_IMM x23, 131072
    mov x24, #0
.Lwsu_env_next:
    ldrh w10, [x20]
    cbz w10, .Lwsu_env_done
    cmp x24, #1022
    b.hs .Lwsu_bad
    str x22, [x21, x24, lsl #3]
    mov w0, #65001
    mov w1, #0x80
    mov x2, x20
    mov w3, #-1
    mov x4, x22
    mov x5, x23
    mov x6, #0
    mov x7, #0
    bl WideCharToMultiByte
    cbz w0, .Lwsu_bad
    add x22, x22, x0
    sub x23, x23, x0
    add x24, x24, #1
1:  ldrh w10, [x20], #2
    cbnz w10, 1b
    b .Lwsu_env_next
.Lwsu_env_done:
    str xzr, [x21, x24, lsl #3]
    mov x0, x19
    bl FreeEnvironmentStringsW
    /* Supply HOME from USERPROFILE only when HOME was absent. */
    ARM_ADDR x0, win_home_name
    ARM_ADDR x1, win_home_w
    mov x2, #4096
    bl GetEnvironmentVariableW
    cbnz w0, .Lwsu_have_home
    ARM_ADDR x0, win_profile_name
    ARM_ADDR x1, win_home_w
    mov x2, #4096
    bl GetEnvironmentVariableW
    cbz w0, .Lwsu_return
.Lwsu_have_home:
    cmp w0, #4096
    b.hs .Lwsu_bad
    ARM_ADDR x0, win_home_utf8
    ARM_ADDR x1, win_home_prefix
    ARM_CALL copy_string
    mov x4, x9
    mov w0, #65001
    mov w1, #0x80
    ARM_ADDR x2, win_home_w
    mov w3, #-1
    mov x5, #4091
    mov x6, #0
    mov x7, #0
    bl WideCharToMultiByte
    cbz w0, .Lwsu_bad
    ARM_ADDR x0, win_home_utf8
1:  ldrb w10, [x0]
    cbz w10, 3f
    cmp w10, #92
    b.ne 2f
    mov w10, #47
    strb w10, [x0]
2:  add x0, x0, #1
    b 1b
3:  /* Place normalized HOME first; an inherited HOME cannot shadow it. */
    ARM_ADDR x10, win_home_utf8
    ARM_ADDR x11, win_env_home_ptrs
    str x10, [x11]
    mov x0, #0
4:  ldr x10, [x21, x0, lsl #3]
    add x12, x0, #1
    str x10, [x11, x12, lsl #3]
    cbz x10, 5f
    mov x0, x12
    b 4b
5:  ARM_ADDR x16, envp
    str x11, [x16]
.Lwsu_return:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
.Lwsu_bad:
    /* arm_write resolves borrowed stderr directly through GetStdHandle.
     * No argv, environment, or managed-layout initialization is required.
     * Preserve the documented status even if the complete write fails. */
    mov w0, #2
    ARM_ADDR x1, win_startup_error
    ARM_CALL write_cstr
    mov w0, #2
    bl ExitProcess
    brk #0

/* x0=executable UTF8, x1=argv (<=256 entries). Each argv string is converted
 * with strict UTF8 into bounded UTF16, then quoted using the Microsoft CRT
 * backslash/quote rule. Empty arguments and trailing backslashes round-trip.
 * x2=environment array or NULL to inherit. x3/x4=stdin/stdout HANDLE (0 std).
 * x5=0 for unbounded or 1..0xfffffffe milliseconds. Fixed tools use
 * WIN_TOOL_WAIT_MS; capture uses its separate bounded pump.
 * w9=child status or 127 on setup/timeout failure.
 * Parent owns all pointers and streams; child only inherits three duplicates.
 * All created process/thread/stream handles close before return. Stack 224.
 */
win_spawn_core:
    stp x29, x30, [sp, #-224]!
    mov x29, sp
    stp x19, x20, [sp, #32]
    stp x21, x22, [sp, #48]
    stp x23, x24, [sp, #64]
    stp x25, x26, [sp, #80]
    stp x27, x28, [sp, #96]
    mov x19, x1
    mov x20, x2
    mov x25, x3
    mov x26, x4
    mov x27, x5
    ARM_ADDR x1, win_exe_w
    mov x2, #4096
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwsp_fail
    ARM_ADDR x21, win_command_w
    mov x22, #32766
    mov x23, #0
.Lwsp_arg:
    ldr x0, [x19, x23, lsl #3]
    cbz x0, .Lwsp_ready
    cmp x23, #256
    b.hs .Lwsp_fail
    ARM_ADDR x1, win_arg_w
    mov x2, #16384
    ARM_CALL win_utf16
    tbnz x9, #63, .Lwsp_fail
    ARM_ADDR x24, win_arg_w
    mov w10, #'"'
    WIN_QUOTE
.Lwsp_char:
    mov x28, #0
.Lwsp_slashes:
    ldrh w10, [x24], #2
    cmp w10, #92
    b.ne .Lwsp_escaped
    add x28, x28, #1
    b .Lwsp_slashes
.Lwsp_escaped:
    cbz w10, .Lwsp_double
    cmp w10, #'"'
    b.ne .Lwsp_keep
.Lwsp_double:
    lsl x28, x28, #1
.Lwsp_keep:
    mov w11, w10
.Lwsp_emit_slash:
    cbz x28, .Lwsp_emit_char
    mov w10, #92
    WIN_QUOTE
    sub x28, x28, #1
    b .Lwsp_emit_slash
.Lwsp_emit_char:
    mov w10, w11
    cbz w10, .Lwsp_close_quote
    cmp w10, #'"'
    b.ne 1f
    mov w10, #92
    WIN_QUOTE
    mov w10, #'"'
1:  WIN_QUOTE
    b .Lwsp_char
.Lwsp_close_quote:
    mov w10, #'"'
    WIN_QUOTE
    mov w10, #32
    WIN_QUOTE
    add x23, x23, #1
    b .Lwsp_arg
.Lwsp_ready:
    strh wzr, [x21]
    /* Environment API conversion rejects oversized blocks. */
    mov x0, x20
    ARM_CALL win_environment_block
    tbnz x9, #63, .Lwsp_fail
    str x9, [sp, #128]
    /* Duplicate only the selected streams as inheritable handles. */
    mov x0, x25
    cbnz x0, 1f
    mov x0, #0
    ARM_CALL win_handle
1:  ARM_CALL win_inherit_duplicate
    tbnz x9, #63, .Lwsp_fail
    str x9, [sp, #136]
    mov x0, x26
    cbnz x0, 2f
    mov x0, #1
    ARM_CALL win_handle
2:  ARM_CALL win_inherit_duplicate
    tbnz x9, #63, .Lwsp_close_in
    str x9, [sp, #144]
    mov x0, #2
    ARM_CALL win_handle
    ARM_CALL win_inherit_duplicate
    tbnz x9, #63, .Lwsp_close_out
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
    cbz w0, .Lwsp_close_err
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
    cbz w0, .Lwsp_delete_attrs
    ARM_ADDR x0, win_exe_w
    ARM_ADDR x1, win_command_w
    mov x2, #0
    mov x3, #0
    mov w4, #1
    ARM_IMM w5, 0x80400          /* EXTENDED_STARTUPINFO + UNICODE_ENV */
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
    cbz w10, .Lwsp_fail
    ARM_ADDR x16, win_process_info
    ldr x0, [x16, #8]
    bl CloseHandle
    ARM_ADDR x16, win_process_info
    ldr x19, [x16]
    ARM_ADDR x16, win_capture_read
    ldr x10, [x16]
    cbz x10, .Lwsp_plain_wait
    mov x0, x19
    ARM_CALL win_pump_capture
    cbnz x9, .Lwsp_timeout
    b .Lwsp_exit
.Lwsp_plain_wait:
    mov x0, x19
    mov x1, x27
    cbnz x1, 4f
    ARM_IMM x1, WIN_WAIT_INFINITE
4:  bl WaitForSingleObject
    cbz w0, .Lwsp_exit
.Lwsp_timeout:
    mov x0, x19
    mov w1, #127
    bl TerminateProcess
    mov x0, x19
    mov w1, #-1
    bl WaitForSingleObject
    mov w20, #127
    b .Lwsp_process_close
.Lwsp_exit:
    mov x0, x19
    add x1, sp, #160
    bl GetExitCodeProcess
    cbz w0, 5f
    ldr w20, [sp, #160]
    b .Lwsp_process_close
5:  mov w20, #127
.Lwsp_process_close:
    mov x0, x19
    bl CloseHandle
    mov w9, w20
    b .Lwsp_return
.Lwsp_delete_attrs:
    ARM_ADDR x0, win_attribute_list
    bl DeleteProcThreadAttributeList
.Lwsp_close_err:
    ldr x0, [sp, #152]
    bl CloseHandle
.Lwsp_close_out:
    ldr x0, [sp, #144]
    bl CloseHandle
.Lwsp_close_in:
    ldr x0, [sp, #136]
    bl CloseHandle
.Lwsp_fail:
    mov w9, #127
.Lwsp_return:
    ldp x27, x28, [sp, #96]
    ldp x25, x26, [sp, #80]
    ldp x23, x24, [sp, #64]
    ldp x21, x22, [sp, #48]
    ldp x19, x20, [sp, #32]
    ldp x29, x30, [sp], #224
    ret
/* Quote emitter: x21=cursor, x22=remaining WCHARs, w10=value. Does not change
 * w11. A capacity failure terminates child setup through its owning frame. */
win_inherit_duplicate:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x1, x0
    mov x0, #-1
    mov x2, #-1
    add x3, sp, #16
    mov w4, #0
    mov w5, #1
    mov w6, #2
    bl DuplicateHandle
    cbz w0, 1f
    ldr x9, [sp, #16]
    b 2f
1:  mov x9, #-1
2:  ldp x29, x30, [sp], #32
    ret
/* x0=explicit UTF8 environment pointer array or NULL. Returns UTF16 block,
 * NULL for inheritance, or -22. Capacity=32768 WCHARs; max1024 entries. */
win_environment_block:
    cmn x0, #1
    b.eq win_build_environment
    cbnz x0, 1f
    mov x9, #0
    ret
1:  stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    ARM_ADDR x20, win_child_env_w
    mov x21, #32767
    mov x22, #0
2:  ldr x0, [x19, x22, lsl #3]
    cbz x0, 3f
    cmp x22, #1024
    b.hs 4f
    mov x1, x20
    mov x2, x21
    ARM_CALL win_utf16
    tbnz x9, #63, 4f
    add x20, x20, x9, lsl #1
    sub x21, x21, x9
    add x22, x22, #1
    b 2b
3:  strh wzr, [x20]
    cbnz x22, 6f
    strh wzr, [x20, #2]
6:  ARM_ADDR x9, win_child_env_w
    b 5f
4:  mov x9, #-22
5:  ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
/* x0=executable pointer, x1=argv using win_spawn_core's bounds and ownership.
 * Fixed compiler/assembler/linker pointers receive a private environment and
 * WIN_TOOL_WAIT_MS. Deliberately run applications retain user environment
 * and duration. Output w9=status or 127. Scratch x0-x17/NZCV; preserves x19-x29.
 * Stack 32 plus core/helpers; all argument buffers remain borrowed. */
win_spawn_wait:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    ARM_CALL native_link_child_environment
    ARM_ADDR x16, native_tool_env
    cmp x9, x16
    mov x10, #-1
    csel x2, x10, x9, eq
    mov x5, #0
    ARM_IMM x10, WIN_TOOL_WAIT_MS
    csel x5, x10, x5, eq
    mov x0, x19
    mov x1, x20
    mov x3, #0
    mov x4, #0
    ARM_CALL win_spawn_core
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.section .rdata,"dr"
win_startup_error:
    .asciz "asm: cannot initialize Windows arguments, paths, or user permissions. Check the command line and HOME.\n"
.p2align 1
win_home_name: .hword 72,79,77,69,0
.p2align 1
win_profile_name: .hword 85,83,69,82,80,82,79,70,73,76,69,0
win_home_prefix: .asciz "HOME="
.section .bss
.p2align 3
win_argv: .skip 8192
win_args: .skip 32768
win_env_ptrs: .skip 8192
win_env_home_ptrs: .skip 8200
win_env_utf8: .skip 131072
win_home_utf8: .skip 4096
win_home_w: .skip 8192
win_exe_w: .skip 8192
win_arg_w: .skip 32768
win_command_w: .skip 65536
win_child_env_w: .skip 65536
win_startup_info: .skip 112
win_inherited_handles: .skip 24
win_attribute_list: .skip 1024
win_process_info: .skip 24
.text
/* Construct the compiler/linker environment from a bounded allowlist.
 * SYSTEMROOT/WINDIR/TEMP/TMP/LIB/INCLUDE preserve native SDK discovery.
 * PATH is fixed. Compiler startup override variables and credentials are absent.
 * Returns win_child_env_w or -22. Capacity=32768 WCHARs; <=4095 per value.
 */
win_build_environment:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    ARM_ADDR x19, win_child_env_w
    mov x20, #32767
    ARM_ADDR x21, win_build_env_names
    mov x22, #0
.Lwbe_next:
    ldr x23, [x21, x22, lsl #3]
    cbz x23, .Lwbe_path
    mov x24, #0
1:  ldrh w10, [x23, x24, lsl #1]
    cbz w10, 2f
    cmp x20, #1
    b.ls .Lwbe_bad
    strh w10, [x19], #2
    sub x20, x20, #1
    add x24, x24, #1
    b 1b
2:  mov w10, #61
    strh w10, [x19], #2
    sub x20, x20, #1
    mov x0, x23
    mov x1, x19
    mov x2, x20
    cmp x2, #4096
    mov x10, #4096
    csel x2, x10, x2, hi
    bl GetEnvironmentVariableW
    cbz w0, 3f
    cmp x0, x20
    b.hs .Lwbe_bad
    cmp x0, #4096
    b.hs .Lwbe_bad
    add x0, x0, #1
    add x19, x19, x0, lsl #1
    sub x20, x20, x0
    b 4f
3:  add x24, x24, #1
    sub x19, x19, x24, lsl #1
    add x20, x20, x24
4:  add x22, x22, #1
    b .Lwbe_next
.Lwbe_path:
    ARM_ADDR x23, win_fixed_path_w
5:  ldrh w10, [x23], #2
    cmp x20, #1
    b.ls .Lwbe_bad
    strh w10, [x19], #2
    sub x20, x20, #1
    cbnz w10, 5b
    strh wzr, [x19]
    ARM_ADDR x9, win_child_env_w
    b .Lwbe_done
.Lwbe_bad:
    mov x9, #-22
.Lwbe_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
.section .rdata,"dr"
.p2align 3
win_build_env_names: .quad win_env_systemroot_w, win_env_windir_w, win_env_temp_w, win_env_tmp_w, win_env_lib_w, win_env_include_w, 0
.p2align 1
win_env_systemroot_w: .hword 83,121,115,116,101,109,82,111,111,116,0
.p2align 1
win_env_windir_w: .hword 87,73,78,68,73,82,0
.p2align 1
win_env_temp_w: .hword 84,69,77,80,0
.p2align 1
win_env_tmp_w: .hword 84,77,80,0
.p2align 1
win_env_lib_w: .hword 76,73,66,0
.p2align 1
win_env_include_w: .hword 73,78,67,76,85,68,69,0
.p2align 1
win_fixed_path_w: .hword 80,65,84,72,61,67,58,47,80,114,111,103,114,97,109,32,70,105,108,101,115,47,76,76,86,77,47,98,105,110,59,67,58,47,87,105,110,100,111,119,115,47,83,121,115,116,101,109,51,50,0
