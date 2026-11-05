/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only APIs. These are never linked into the Windows executable.
 * APIs intentionally destroy every volatile integer register except x0/LR.
 * Stack arguments are read at the callee entry SP, as Windows ARM64 requires.
 */
.text
.macro API_CLOBBER
    mov x1, #0x1111
    mov x2, #0x2222
    mov x3, #0x3333
    mov x4, #0x4444
    mov x5, #0x5555
    mov x6, #0x6666
    mov x7, #0x7777
    mov x8, #0x8888
    mov x9, #0x9999
    mov x10, #0xaaaa
    mov x11, #0xbbbb
    mov x12, #0xcccc
    mov x13, #0xdddd
    mov x14, #0xeeee
    mov x15, #0xffff
    mov x16, #0x1616
    mov x17, #0x1717
.endm
.macro REQUIRE_EQ left, right
    cmp \left, \right
    b.ne abi_failed
.endm
.global _main
_main:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x21, #0x2121
    mov x22, #0x2222
    mov x23, #0x2323
    mov x24, #0x2424
    mov x25, #0x2525
    mov x26, #0x2626
    mov x27, #0x2727
    mov x28, #0x2828
    mov x0, #0
    ARM_ADDR x1, abi_io_buffer
    mov x2, #7
    mov x3, #0x1234
    ARM_CALL arm_read
    REQUIRE_EQ x9, #7
    REQUIRE_EQ x0, #0
    ARM_ADDR x10, abi_io_buffer
    REQUIRE_EQ x1, x10
    REQUIRE_EQ x2, #7
    ARM_IMM x10, 0x1234
    REQUIRE_EQ x3, x10
    ldrb w10, [x1]
    REQUIRE_EQ w10, #65
    mov x0, #1
    ARM_ADDR x1, abi_io_buffer
    mov x2, #7
    ARM_CALL arm_write
    REQUIRE_EQ x9, #7
    REQUIRE_EQ x0, #1
    ARM_ADDR x10, abi_io_buffer
    REQUIRE_EQ x1, x10
    REQUIRE_EQ x2, #7
    ARM_IMM x19, 0x4400
    ARM_IMM x20, O_DIRECTORY
    ARM_ADDR x0, abi_component
    mov x1, #10
    mov x2, #1
    ARM_CALL win_nt_component
    ARM_IMM x10, 0x4404
    REQUIRE_EQ x9, x10
    mov x10, sp
    REQUIRE_EQ x10, x29
    mov x0, x19
    ARM_ADDR x1, abi_dirent
    mov x2, #1024
    ARM_CALL win_getdents
    REQUIRE_EQ x9, #24
    ARM_ADDR x10, abi_dirent
    ldrb w11, [x10, #19]
    REQUIRE_EQ w11, #111
    ldrb w11, [x10, #18]
    REQUIRE_EQ w11, #8
    mov x10, sp
    REQUIRE_EQ x10, x29
    mov x0, x19
    mov x1, #6
    ARM_CALL win_directory_lock
    REQUIRE_EQ x9, #0
    ARM_ADDR x10, win_dir_locks
    ldr x11, [x10]
    REQUIRE_EQ x11, x19
    ldr x11, [x10, #8]
    ARM_IMM x12, 0x4404
    REQUIRE_EQ x11, x12
    /* unlink must not delete directories; rmdir must reject regular files. */
    ARM_ADDR x10, abi_file_attributes
    mov w11, #16
    str w11, [x10]
    ARM_ADDR x0, abi_executable
    ARM_CALL arm_unlink
    cmn x9, #21
    b.ne abi_failed
    ARM_ADDR x10, abi_delete_calls
    ldr w11, [x10]
    cbnz w11, abi_failed
    ARM_ADDR x0, abi_executable
    ARM_CALL arm_rmdir
    REQUIRE_EQ x9, #0
    ARM_ADDR x10, abi_file_attributes
    str wzr, [x10]
    ARM_ADDR x0, abi_executable
    ARM_CALL arm_rmdir
    cmn x9, #20
    b.ne abi_failed
    ARM_ADDR x0, abi_executable
    ARM_CALL arm_unlink
    REQUIRE_EQ x9, #0
    ARM_ADDR x10, abi_delete_calls
    ldr w11, [x10]
    REQUIRE_EQ w11, #2
    ARM_ADDR x0, abi_executable
    ARM_ADDR x1, abi_argv
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    ARM_CALL win_spawn_core
    REQUIRE_EQ x9, #42
    mov x10, sp
    REQUIRE_EQ x10, x29
    ARM_IMM x10, 0x4400
    REQUIRE_EQ x19, x10
    ARM_IMM x10, O_DIRECTORY
    REQUIRE_EQ x20, x10
    /* A permanently readable pipe must still reach the elapsed deadline. */
    ARM_ADDR x10, win_capture_read
    mov x11, #0x9000
    str x11, [x10]
    ARM_ADDR x10, win_capture_write
    mov x11, #0x9004
    str x11, [x10]
    ARM_ADDR x10, win_capture_buffer
    ARM_ADDR x11, abi_capture_buffer
    str x11, [x10]
    ARM_ADDR x10, win_capture_limit
    mov x11, #16
    str x11, [x10]
    mov x0, #0x8000
    ARM_CALL win_pump_capture
    REQUIRE_EQ x9, #1
    ARM_ADDR x10, win_capture_size
    ldr x11, [x10]
    REQUIRE_EQ x11, #1
    /* Empty peek -> child exits -> pending final byte -> broken-pipe EOF. */
    ARM_ADDR x10, abi_capture_mode
    mov x11, #1
    str x11, [x10]
    ARM_ADDR x10, abi_capture_peeks
    str xzr, [x10]
    ARM_ADDR x10, abi_capture_waits
    str xzr, [x10]
    ARM_ADDR x10, abi_clock
    str xzr, [x10]
    ARM_ADDR x10, abi_capture_buffer
    strb wzr, [x10]
    ARM_ADDR x10, win_capture_write
    mov x11, #0x9004
    str x11, [x10]
    mov x0, #0x8000
    ARM_CALL win_pump_capture
    REQUIRE_EQ x9, #0
    ARM_ADDR x10, win_capture_size
    ldr x11, [x10]
    REQUIRE_EQ x11, #1
    ARM_ADDR x10, abi_capture_buffer
    ldrb w11, [x10]
    REQUIRE_EQ w11, #65
    ARM_ADDR x10, abi_capture_peeks
    ldr x11, [x10]
    REQUIRE_EQ x11, #3
    ARM_ADDR x10, abi_capture_waits
    ldr x11, [x10]
    REQUIRE_EQ x11, #1
    ARM_IMM x10, 0x2121
    REQUIRE_EQ x21, x10
    ARM_IMM x10, 0x2222
    REQUIRE_EQ x22, x10
    ARM_IMM x10, 0x2323
    REQUIRE_EQ x23, x10
    ARM_IMM x10, 0x2424
    REQUIRE_EQ x24, x10
    ARM_IMM x10, 0x2525
    REQUIRE_EQ x25, x10
    ARM_IMM x10, 0x2626
    REQUIRE_EQ x26, x10
    ARM_IMM x10, 0x2727
    REQUIRE_EQ x27, x10
    ARM_IMM x10, 0x2828
    REQUIRE_EQ x28, x10
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    mov w0, #0
    ldp x29, x30, [sp], #112
    ret
abi_failed:
    mov w0, #95
    b _exit

GetStdHandle:
    API_CLOBBER
    mov x0, #0x6000
    ret
ReadFile:
    mov x10, #0x9000
    cmp x0, x10
    b.eq .Labi_capture_read
    mov x10, #0x6000
    REQUIRE_EQ x0, x10
    ARM_ADDR x10, abi_io_buffer
    REQUIRE_EQ x1, x10
    REQUIRE_EQ x2, #7
    mov w10, #65
    strb w10, [x1]
    mov w10, #7
    str w10, [x3]
    API_CLOBBER
    mov w0, #1
    ret
.Labi_capture_read:
    REQUIRE_EQ x2, #1
    mov w10, #65
    strb w10, [x1]
    mov w10, #1
    str w10, [x3]
    API_CLOBBER
    mov w0, #1
    ret
WriteFile:
    mov x10, #0x6000
    REQUIRE_EQ x0, x10
    ARM_ADDR x10, abi_io_buffer
    REQUIRE_EQ x1, x10
    REQUIRE_EQ x2, #7
    mov w10, #7
    str w10, [x3]
    API_CLOBBER
    mov w0, #1
    ret
NtCreateFile:
    ldr x10, [sp]
    ldr x11, [sp, #8]
    cbnz x11, abi_failed
    ldr x11, [sp, #16]
    cbnz x11, abi_failed
    ARM_IMM x11, 0x120089
    cmp x1, x11
    b.ne .Labi_lock_create
    ARM_IMM x11, 0x200021
    REQUIRE_EQ x10, x11
    REQUIRE_EQ x6, #7
    REQUIRE_EQ x7, #1
    ldr x11, [x2, #8]
    ARM_IMM x12, 0x4400
    REQUIRE_EQ x11, x12
    ldr x11, [x2, #16]
    ldrh w12, [x11]
    REQUIRE_EQ w12, #10
    b .Labi_created
.Labi_lock_create:
    ARM_IMM x11, 0x13019f
    REQUIRE_EQ x1, x11
    ARM_IMM x11, 0x201060
    REQUIRE_EQ x10, x11
    REQUIRE_EQ x6, #0
    REQUIRE_EQ x7, #3
.Labi_created:
    mov x10, #0x4404
    str x10, [x0]
    stp xzr, xzr, [x3]
    API_CLOBBER
    mov x0, #0
    ret
GetFileInformationByHandle:
    mov x10, #0x4400
    cmp x0, x10
    mov w10, #16
    b.eq 1f
    mov x10, #0x4404
    REQUIRE_EQ x0, x10
    ARM_ADDR x10, abi_file_attributes
    ldr w10, [x10]
1:  str w10, [x1]
    API_CLOBBER
    mov w0, #1
    ret
NtQueryDirectoryFile:
    mov x10, #0x4400
    REQUIRE_EQ x0, x10
    ldr x10, [sp]
    REQUIRE_EQ x10, #1
    ldr x10, [sp, #8]
    cbnz x10, abi_failed
    ldr x10, [sp, #16]
    cbnz x10, abi_failed
    REQUIRE_EQ x7, #1
    stp xzr, xzr, [x4]
    mov w10, #6
    str w10, [x5, #60]
    str wzr, [x5, #56]
    mov w10, #111
    strh w10, [x5, #64]
    mov w10, #110
    strh w10, [x5, #66]
    mov w10, #101
    strh w10, [x5, #68]
    API_CLOBBER
    mov x0, #0
    ret
WideCharToMultiByte:
    mov x9, #0
1:  cmp x9, x3
    b.hs 2f
    ldrh w10, [x2, x9, lsl #1]
    strb w10, [x4, x9]
    add x9, x9, #1
    b 1b
2:  mov x0, x9
    API_CLOBBER
    ret
win_utf16:
    mov x9, #0
1:  ldrb w10, [x0, x9]
    strh w10, [x1, x9, lsl #1]
    add x9, x9, #1
    cbnz w10, 1b
    ret
win_environment_block:
    cbnz x0, abi_failed
    mov x9, #0
    ret
DuplicateHandle:
    ARM_ADDR x10, abi_next_handle
    ldr x11, [x10]
    add x11, x11, #4
    str x11, [x10]
    str x11, [x3]
    API_CLOBBER
    mov x0, #1
    ret
InitializeProcThreadAttributeList:
    REQUIRE_EQ x1, #1
    ldr x10, [x3]
    REQUIRE_EQ x10, #1024
    API_CLOBBER
    mov x0, #1
    ret
UpdateProcThreadAttribute:
    ARM_IMM x10, 0x20002
    REQUIRE_EQ x2, x10
    REQUIRE_EQ x4, #24
    ldp x10, x11, [x3]
    cmp x10, x11
    b.eq abi_failed
    ldr x12, [x3, #16]
    cmp x12, x10
    b.eq abi_failed
    cmp x12, x11
    b.eq abi_failed
    API_CLOBBER
    mov x0, #1
    ret
CreateProcessW:
    ldr x10, [sp]
    ARM_ADDR x11, win_startup_info
    REQUIRE_EQ x10, x11
    ldr x10, [sp, #8]
    ARM_ADDR x11, win_process_info
    REQUIRE_EQ x10, x11
    REQUIRE_EQ x4, #1
    ARM_IMM x11, 0x80400
    REQUIRE_EQ x5, x11
    cbnz x6, abi_failed
    cbnz x7, abi_failed
    mov x11, #0x8000
    str x11, [x10]
    mov x11, #0x8004
    str x11, [x10, #8]
    API_CLOBBER
    mov x0, #1
    ret
WaitForSingleObject:
    cbz x1, .Labi_capture_wait
    mov x10, #0x8000
    REQUIRE_EQ x0, x10
    ARM_IMM x10, 120000
    REQUIRE_EQ x1, x10
    API_CLOBBER
    mov x0, #0
    ret
.Labi_capture_wait:
    ARM_ADDR x10, abi_capture_mode
    ldr x11, [x10]
    REQUIRE_EQ x11, #1
    ARM_ADDR x10, abi_capture_peeks
    ldr x11, [x10]
    REQUIRE_EQ x11, #1
    ARM_ADDR x10, abi_capture_waits
    ldr x11, [x10]
    add x11, x11, #1
    str x11, [x10]
    API_CLOBBER
    mov x0, #0
    ret
GetExitCodeProcess:
    mov x10, #0x8000
    REQUIRE_EQ x0, x10
    mov w10, #42
    str w10, [x1]
    API_CLOBBER
    mov w0, #1
    ret
CloseHandle:
DeleteProcThreadAttributeList:
    API_CLOBBER
    mov x0, #1
    ret
LockFileEx:
TerminateProcess:
    b abi_failed
GetLastError:
    ARM_ADDR x10, abi_capture_mode
    ldr x11, [x10]
    REQUIRE_EQ x11, #1
    ARM_ADDR x10, abi_capture_peeks
    ldr x11, [x10]
    REQUIRE_EQ x11, #3
    API_CLOBBER
    mov w0, #109
    ret
win_open:
    API_CLOBBER
    mov x9, #0x4404
    ret
SetFileInformationByHandle:
    mov x10, #0x4404
    REQUIRE_EQ x0, x10
    REQUIRE_EQ x1, #4
    REQUIRE_EQ x3, #4
    ldr w10, [x2]
    REQUIRE_EQ w10, #1
    ARM_ADDR x10, abi_delete_calls
    ldr w11, [x10]
    add w11, w11, #1
    str w11, [x10]
    API_CLOBBER
    mov x0, #1
    ret
PeekNamedPipe:
    ARM_ADDR x10, abi_capture_mode
    ldr x11, [x10]
    cbz x11, .Labi_peek_continuous
    ARM_ADDR x10, abi_capture_peeks
    ldr x11, [x10]
    add x12, x11, #1
    str x12, [x10]
    cbz x11, .Labi_peek_empty
    cmp x11, #1
    b.eq .Labi_peek_pending
    REQUIRE_EQ x11, #2
    API_CLOBBER
    mov x0, #0
    ret
.Labi_peek_empty:
    str wzr, [x4]
    API_CLOBBER
    mov x0, #1
    ret
.Labi_peek_continuous:
.Labi_peek_pending:
    mov w10, #1
    str w10, [x4]
    API_CLOBBER
    mov x0, #1
    ret
GetTickCount64:
    ARM_ADDR x10, abi_capture_mode
    ldr x11, [x10]
    cbnz x11, .Labi_clock_fixed
    ARM_ADDR x10, abi_clock
    ldr x0, [x10]
    ARM_IMM x11, 60000
    add x11, x11, x0
    str x11, [x10]
    API_CLOBBER
    ret
.Labi_clock_fixed:
    API_CLOBBER
    mov x0, #0
    ret
Sleep:
    b abi_failed
win_error_code:
win_error:
win_nt_error:
    b abi_failed
.data
.p2align 3
abi_next_handle: .quad 0x7000
abi_executable: .asciz "program.exe"
abi_argument: .asciz "argument with spaces"
.p2align 3
abi_argv: .quad abi_executable, abi_argument, 0
abi_component: .hword 101,110,116,114,121,0
win_lock_name: .hword 46,97,115,109,45,108,111,99,107,0
.p2align 3
abi_io_buffer: .space 16
abi_dirent: .space 1024
win_private_sd: .space 40
win_dir_entry: .space 2048
win_dir_locks: .space 256
win_exe_w: .space 8192
win_arg_w: .space 32768
win_command_w: .space 65536
win_startup_info: .space 112
win_inherited_handles: .space 24
win_attribute_list: .space 1024
win_process_info: .space 24
win_capture_read: .quad 0

.p2align 3
abi_file_attributes: .quad 0
abi_delete_calls: .quad 0
abi_clock: .quad 0
abi_capture_buffer: .space 18
.p2align 3
win_capture_write: .quad 0
win_capture_buffer: .quad 0
win_capture_limit: .quad 0
win_capture_size: .quad 0

abi_capture_mode: .quad 0
abi_capture_peeks: .quad 0
abi_capture_waits: .quad 0
