/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Dedicated managed invocation. No tool deadline, new group, or job policy.
 */
.intel_syntax noprefix
.text
/* No inputs. Returns the signaled child's complete DWORD in EAX.
 * Globals: checked wm_payload_fd and wm_launch_path; original native command
 * line is copied exactly into owned UTF16[32767], preserving argv quoting.
 * Owns process/thread and three explicit inherited duplicate stream handles.
 * A rejected suspended process is terminated and reaped before error output.
 * WFRAME preserves internal ABI and aligns all Windows calls. */
win_managed_launch:
    WFRAME
    mov qword ptr [rip + win_process_handle], 0
    mov qword ptr [rip + win_thread_handle], 0
    mov qword ptr [rip + win_child_stdin], 0
    mov qword ptr [rip + win_child_stdout], 0
    mov qword ptr [rip + win_child_stderr], 0
    mov byte ptr [rip + wm_control_owned], 0
    lea rdi, [rip + wm_launch_path + 1]
    lea rsi, [rip + win_executable_wide]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwml_failed
    call GetCommandLineW
    test rax, rax
    jz .Lwml_failed
    lea rdx, [rip + win_command_wide]
    xor ecx, ecx
.Lwml_command_copy:
    cmp ecx, 32766
    jae .Lwml_failed
    mov r8w, [rax + rcx*2]
    mov [rdx + rcx*2], r8w
    inc ecx
    test r8w, r8w
    jnz .Lwml_command_copy
    lea rdi, [rip + win_startup]
    xor eax, eax
    mov ecx, 14
    rep stosq
    mov dword ptr [rip + win_startup], 112
    mov dword ptr [rip + win_startup + 60], 0x100
    mov rdi, [rip + win_handles]
    call win_inherit_duplicate
    test rax, rax
    jz .Lwml_failed
    mov [rip + win_child_stdin], rax
    mov rdi, [rip + win_handles + 8]
    call win_inherit_duplicate
    test rax, rax
    jz .Lwml_failed
    mov [rip + win_child_stdout], rax
    mov rdi, [rip + win_handles + 16]
    call win_inherit_duplicate
    test rax, rax
    jz .Lwml_failed
    mov [rip + win_child_stderr], rax
    lea rcx, [rip + win_managed_control]
    mov edx, 1
    call SetConsoleCtrlHandler
    test eax, eax
    jz .Lwml_failed
    mov byte ptr [rip + wm_control_owned], 1
    /* Repeated handles in STARTUPINFO list would be invalid. All duplicates
     * above are distinct even when the caller redirects streams together. */
    mov rax, [rip + win_child_stdin]
    mov [rip + win_startup + 80], rax
    mov [rip + win_inherited_handles], rax
    mov rax, [rip + win_child_stdout]
    mov [rip + win_startup + 88], rax
    mov [rip + win_inherited_handles + 8], rax
    mov rax, [rip + win_child_stderr]
    mov [rip + win_startup + 96], rax
    mov [rip + win_inherited_handles + 16], rax
    lea rcx, [rip + win_attribute_list]
    mov edx, 1
    xor r8d, r8d
    lea r9, [rip + win_attribute_size]
    mov qword ptr [r9], 1024
    call InitializeProcThreadAttributeList
    test eax, eax
    jz .Lwml_failed
    lea rax, [rip + win_attribute_list]
    mov [rip + win_startup + 104], rax
    mov rcx, rax
    xor edx, edx
    mov r8d, 0x20002 /* PROC_THREAD_ATTRIBUTE_HANDLE_LIST */
    lea r9, [rip + win_inherited_handles]
    mov qword ptr [rsp + 32], 24
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    call UpdateProcThreadAttribute
    test eax, eax
    jz .Lwml_attributes_fail
    lea rcx, [rip + win_executable_wide]
    lea rdx, [rip + win_command_wide]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 1
    mov qword ptr [rsp + 40], 0x80004 /* EXTENDED_STARTUPINFO + CREATE_SUSPENDED */
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    lea rax, [rip + win_startup]
    mov [rsp + 64], rax
    lea rax, [rip + win_process_info]
    mov [rsp + 72], rax
    call CreateProcessW
    mov ebx, eax
    lea rcx, [rip + win_attribute_list]
    call DeleteProcThreadAttributeList
    test ebx, ebx
    jz .Lwml_failed
    mov rax, [rip + win_process_info]
    mov [rip + win_process_handle], rax
    mov rax, [rip + win_process_info + 8]
    mov [rip + win_thread_handle], rax
    call win_close_child_streams
    mov rdi, [rip + wm_payload_fd]
    call win_handle
    mov rsi, rax
    mov rdi, [rip + win_process_handle]
    call win_child_image_matches
    test rax, rax
    jnz .Lwml_terminate
    mov rcx, [rip + win_thread_handle]
    call ResumeThread
    cmp eax, -1
    je .Lwml_terminate
    mov rcx, [rip + win_process_handle]
    mov edx, -1
    call WaitForSingleObject
    test eax, eax
    jnz .Lwml_terminate
    mov rcx, [rip + win_process_handle]
    lea rdx, [rbp - 128]
    call GetExitCodeProcess
    test eax, eax
    jz .Lwml_terminate
    /* STILL_ACTIVE(259) is an ordinary exit DWORD after a signaled wait. */
    mov ebx, [rbp - 128]
    call win_managed_launch_cleanup
    mov eax, ebx
    WLEAVE
.Lwml_terminate:
    mov rcx, [rip + win_process_handle]
    mov edx, 127
    call TerminateProcess
    mov rcx, [rip + win_process_handle]
    mov edx, -1
    call WaitForSingleObject
    jmp .Lwml_failed
.Lwml_attributes_fail:
    lea rcx, [rip + win_attribute_list]
    call DeleteProcThreadAttributeList
.Lwml_failed:
    call win_managed_launch_cleanup
    jmp win_managed_error
/* Windows callback: ECX=control type. TRUE handles only this launcher's
 * Ctrl+C/Ctrl+Break. Custom handlers are process-local, unlike NULL ignore.
 * The payload retains normal control dispatch and determines its exit code. */
win_managed_control:
    xor eax, eax
    cmp ecx, 1
    seta al
    xor eax, 1
    ret
/* Close owned launch resources. No cleanup result changes child exit status. */
win_managed_launch_cleanup:
    WFRAME
    call win_close_child_streams
    mov rcx, [rip + win_thread_handle]
    mov qword ptr [rip + win_thread_handle], 0
    test rcx, rcx
    jz 1f
    call CloseHandle
1:  mov rcx, [rip + win_process_handle]
    mov qword ptr [rip + win_process_handle], 0
    test rcx, rcx
    jz 2f
    call CloseHandle
2:  cmp byte ptr [rip + wm_control_owned], 0
    je 3f
    lea rcx, [rip + win_managed_control]
    xor edx, edx
    call SetConsoleCtrlHandler
    mov byte ptr [rip + wm_control_owned], 0
3:  WLEAVE
.section .bss
wm_control_owned: .space 1
