/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Windows x64 platform adapter. Shared routines retain the SysV internal ABI.
 * No Windows kernel syscall number is encoded. Calls use documented exports.
 * WFRAME preserves RBX/R12-R15/RDI/RSI/RDX/R8-R10 and RBP, aligns RSP,
 * and reserves 32 bytes of shadow space plus argument slots. RAX/RCX/R11 and
 * flags are scratch. Each frame uses <=512 bytes; no red zone is assumed.
 * Descriptor slots own non-inheritable handles. Slots 0..2 borrow std streams.
 * Paths are strict UTF-8, at most 4095 bytes / 4095 UTF-16 code units.
 * File opens walk one component per held NT directory handle. Every component
 * is opened with FILE_OPEN_REPARSE_POINT and rejected when its handle reports
 * FILE_ATTRIBUTE_REPARSE_POINT. No name-based recheck substitutes for this.
 */
.intel_syntax noprefix
.macro WFRAME
    push rbp
    mov rbp, rsp
    sub rsp, 512
    and rsp, -16
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov [rbp - 48], rdi
    mov [rbp - 56], rsi
    mov [rbp - 64], rdx
    mov [rbp - 72], r8
    mov [rbp - 80], r9
    mov [rbp - 88], r10
.endm
.macro WLEAVE
    mov rbx, [rbp - 8]
    mov r12, [rbp - 16]
    mov r13, [rbp - 24]
    mov r14, [rbp - 32]
    mov r15, [rbp - 40]
    mov rdi, [rbp - 48]
    mov rsi, [rbp - 56]
    mov rdx, [rbp - 64]
    mov r8, [rbp - 72]
    mov r9, [rbp - 80]
    mov r10, [rbp - 88]
    mov rsp, rbp
    pop rbp
    ret
.endm
.text
/* Convert one terminated UTF-8 string. RDI input; RSI owned output of RDX
 * UTF-16 units. RAX=units including NUL, or negative EINVAL. No truncation. */
win_wide:
    WFRAME
    mov r12, rdi
    xor eax, eax
.Lww_bound:
    cmp eax, 4096
    jae .Lww_bad
    cmp byte ptr [r12 + rax], 0
    je .Lww_convert
    inc eax
    jmp .Lww_bound
.Lww_convert:
    mov ecx, 65001
    mov edx, 8
    mov r8, r12
    mov r9d, -1
    mov rax, [rbp - 56]
    mov [rsp + 32], rax
    mov rax, [rbp - 64]
    mov [rsp + 40], rax
    call MultiByteToWideChar
    test eax, eax
    jnz .Lww_return
.Lww_bad:
    mov rax, -22
.Lww_return:
    WLEAVE

/* RDI=wide terminated string, RSI=owned UTF-8 buffer, RDX=byte capacity.
 * RAX=bytes including NUL or -EINVAL. Invalid surrogate pairs are rejected. */
win_utf8:
    WFRAME
    mov ecx, 65001
    mov edx, 128
    mov r8, rdi
    mov r9d, -1
    mov [rsp + 32], rsi
    mov rax, [rbp - 64]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jnz .Lwu_return
    mov rax, -22
.Lwu_return:
    WLEAVE

/* Startup owns argv/environment storage for process lifetime. Bounds: 512
 * arguments, 65536 argument bytes, 512 environment entries, 65536 bytes.
 * USERPROFILE supplies HOME only when HOME is absent. HOME uses /C:/... form
 * internally so the shared absolute-path walker retains its explicit contract.
 * RAX=0 or 1; no project files are changed. */
win_initialize:
    WFRAME
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rip + win_argc]
    call CommandLineToArgvW
    test rax, rax
    jz .Lwi_bad
    mov r12, rax
    mov eax, [rip + win_argc]
    test eax, eax
    jz .Lwi_free_bad
    cmp eax, 512
    ja .Lwi_free_bad
    mov [rip + argc], rax
    lea rax, [rip + win_argv]
    mov [rip + argv], rax
    lea r13, [rip + win_arguments]
    xor r14d, r14d
.Lwi_argument:
    mov rdi, [r12 + r14*8]
    mov rsi, r13
    lea rdx, [rip + win_arguments + 65536]
    sub rdx, r13
    call win_utf8
    test rax, rax
    js .Lwi_free_bad
    lea rcx, [rip + win_argv]
    mov [rcx + r14*8], r13
    add r13, rax
    inc r14
    cmp r14, [rip + argc]
    jb .Lwi_argument
    mov qword ptr [rcx + r14*8], 0
    mov rcx, r12
    call LocalFree
    call GetEnvironmentStringsW
    test rax, rax
    jz .Lwi_bad
    mov r12, rax
    mov r15, rax
    lea r13, [rip + win_environment_bytes]
    xor r14d, r14d
.Lwi_env:
    cmp word ptr [r12], 0
    je .Lwi_env_done
    cmp r14d, 510
    jae .Lwi_env_bad
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + win_environment_bytes + 65536]
    sub rdx, r13
    call win_utf8
    test rax, rax
    js .Lwi_env_bad
    lea rcx, [rip + win_environment]
    mov [rcx + r14*8], r13
    add r13, rax
    inc r14
.Lwi_env_skip:
    mov ax, [r12]
    add r12, 2
    test ax, ax
    jnz .Lwi_env_skip
    jmp .Lwi_env
.Lwi_env_bad:
    mov rcx, r15
    call FreeEnvironmentStringsW
    jmp .Lwi_bad
.Lwi_env_done:
    mov rcx, r15
    call FreeEnvironmentStringsW
    /* Obtain HOME independently; allow a deliberate HOME selection. */
    lea rcx, [rip + win_home_name]
    lea rdx, [rip + win_home_wide]
    mov r8d, 4096
    call GetEnvironmentVariableW
    test eax, eax
    jnz .Lwi_home_value
    lea rcx, [rip + win_profile_name]
    lea rdx, [rip + win_home_wide]
    mov r8d, 4096
    call GetEnvironmentVariableW
.Lwi_home_value:
    test eax, eax
    jz .Lwi_bad
    cmp eax, 4096
    jae .Lwi_bad
    lea rdi, [rip + win_home_wide]
    lea rsi, [rip + win_home + 6]
    mov edx, 4090
    call win_utf8
    test rax, rax
    js .Lwi_bad
    lea rdi, [rip + win_home + 5]
    mov byte ptr [rdi], '/'
    lea rsi, [rdi + 1]
    cmp byte ptr [rsi], '/'
    jne .Lwi_home_slashes
    /* Already internal absolute path: remove the extra prefix slash. */
    call copy_string
.Lwi_home_slashes:
    mov al, [rdi]
    test al, al
    jz .Lwi_home_ready
    cmp al, '\\'
    jne 1f
    mov byte ptr [rdi], '/'
1:  inc rdi
    jmp .Lwi_home_slashes
.Lwi_home_ready:
    lea rcx, [rip + win_environment]
    lea rax, [rip + win_home]
    mov [rcx + r14*8], rax
    inc r14
    mov qword ptr [rcx + r14*8], 0
    /* Replace any original HOME entry with the normalized entry. */
    xor ebx, ebx
.Lwi_replace_home:
    cmp rbx, r14
    jae .Lwi_environment_ready
    mov rdx, [rcx + rbx*8]
    cmp dword ptr [rdx], 0x454d4f48
    jne 2f
    cmp byte ptr [rdx + 4], '='
    jne 2f
    mov [rcx + rbx*8], rax
2:  inc rbx
    jmp .Lwi_replace_home
.Lwi_environment_ready:
    mov [rip + envp], rcx
    /* Non-inheritable native std descriptors. */
    mov ecx, -10
    call GetStdHandle
    mov [rip + win_handles], rax
    mov ecx, -11
    call GetStdHandle
    mov [rip + win_handles + 8], rax
    mov ecx, -12
    call GetStdHandle
    mov [rip + win_handles + 16], rax
    call win_security_initialize
    test eax, eax
    jnz .Lwi_bad
    xor eax, eax
    WLEAVE
.Lwi_free_bad:
    mov rcx, r12
    call LocalFree
.Lwi_bad:
    mov eax, 1
    WLEAVE
win_initialization_error:
    lea rdi, [rip + win_error_initialize]
    mov esi, 1
    jmp die

/* Native error mapping preserves distinctions consumed by the shared core.
 * RAX=negative Linux-contract errno. No input; Win32 last error is consumed. */
win_error:
    WFRAME
    call GetLastError
    cmp eax, 2
    je .Lwe_missing
    cmp eax, 3
    je .Lwe_missing
    cmp eax, 183
    je .Lwe_exists
    cmp eax, 80
    je .Lwe_exists
    cmp eax, 32
    je .Lwe_busy
    cmp eax, 33
    je .Lwe_busy
    cmp eax, 145
    je .Lwe_notempty
    cmp eax, 17
    je .Lwe_cross
    mov rax, -13
    jmp .Lwe_return
.Lwe_missing: mov rax, -2
    jmp .Lwe_return
.Lwe_exists: mov rax, -17
    jmp .Lwe_return
.Lwe_busy: mov rax, -11
    jmp .Lwe_return
.Lwe_notempty: mov rax, -39
    jmp .Lwe_return
.Lwe_cross: mov rax, -18
.Lwe_return:
    WLEAVE
win_nt_error:
    WFRAME
    mov ecx, eax
    call RtlNtStatusToDosError
    mov ecx, eax
    call SetLastError
    call win_error
    WLEAVE

/* RDI=owned HANDLE; allocate descriptor >=3. Capacity=256. Takes ownership
 * only on success. RAX=fd/-EMFILE; failure closes the supplied handle. */
win_descriptor:
    WFRAME
    lea rdx, [rip + win_handles]
    mov eax, 3
.Lwd_slot:
    cmp qword ptr [rdx + rax*8], 0
    je .Lwd_found
    inc eax
    cmp eax, 256
    jb .Lwd_slot
    mov rcx, rdi
    call CloseHandle
    mov rax, -24
    WLEAVE
.Lwd_found:
    mov [rdx + rax*8], rdi
    WLEAVE

/* RDI=fd, RAX=HANDLE or zero. No changes except RAX/flags. */
win_handle:
    xor eax, eax
    cmp rdi, 256
    jae 1f
    lea rax, [rip + win_handles]
    mov rax, [rax + rdi*8]
1:  ret

/* RDI=root HANDLE or 0; RSI=one UTF16 component; EDX=byte length;
 * R10=Linux open flags; R8=private mode. RAX=owned HANDLE or negative errno.
 * NtCreateFile accepts exactly one component, or the initial drive root.
 * FILE_OPEN_REPARSE_POINT + post-open FileAttributeTagInfo rejects links.
 * All creations receive the protected current-user DACL. */
win_nt_open:
    WFRAME
    mov r12, rdi
    mov r13, rsi
    mov r14, r10
    mov r15d, edx
    /* UNICODE_STRING */
    mov word ptr [rbp - 128], dx
    mov word ptr [rbp - 126], dx
    mov [rbp - 120], rsi
    /* OBJECT_ATTRIBUTES */
    mov qword ptr [rbp - 192], 48
    mov [rbp - 184], r12
    lea rax, [rbp - 128]
    mov [rbp - 176], rax
    mov qword ptr [rbp - 168], 64
    mov qword ptr [rbp - 160], 0
    test r14d, 64
    jz 1f
    lea rax, [rip + win_private_sd]
    mov [rbp - 160], rax
1:  mov qword ptr [rbp - 152], 0
    lea rcx, [rbp - 208]
    mov edx, 0x00120080 /* synchronize, read control, attributes */
    test r14d, 0x10000000 /* internal DELETE access */
    jz 2f
    or edx, 0x10000
2:  or edx, 1 /* file read data or directory list */
3:  test r14d, 3
    jz 4f
    or edx, 0x116 /* write data, append, attributes, EA */
4:  test r14d, 64
    jz 8f
    or edx, 0x40000 /* created files need WRITE_DAC for final protection */
8:  test r14d, WIN_OPEN_SET_DACL /* private stage's later protection needs WRITE_DAC */
    jz 11f
    or edx, 0x40000
11: test r14d, 0x20000000
    jz 9f
    or edx, 0x40002
9:  test r14d, 0x40000000 /* internal image-only FILE_EXECUTE access */
    jz 10f
    or edx, 0x20
10: lea r8, [rbp - 192]
    lea r9, [rbp - 224]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 128
    mov qword ptr [rsp + 48], 7
    mov eax, 1 /* FILE_OPEN */
    test r14d, 64
    jz 5f
    mov eax, 3 /* FILE_OPEN_IF */
    test r14d, 128
    jz 5f
    mov eax, 2 /* FILE_CREATE */
5:  test r14d, 512
    jz 6f
    mov eax, 5 /* FILE_OVERWRITE_IF */
6:  mov [rsp + 56], rax
    mov eax, 0x200020 /* reparse point, synchronous IO nonalert */
    test r14d, 65536
    jz 7f
    or eax, 1
7:  mov [rsp + 64], rax
    mov qword ptr [rsp + 72], 0
    mov qword ptr [rsp + 80], 0
    call NtCreateFile
    test eax, eax
    js .Lwno_error
    mov r12, [rbp - 208]
    mov rcx, r12
    mov edx, 9 /* FileAttributeTagInfo */
    lea r8, [rbp - 240]
    mov r9d, 8
    call GetFileInformationByHandleEx
    test eax, eax
    jz .Lwno_close
    test dword ptr [rbp - 240], 0x400
    jnz .Lwno_close
    mov rax, r12
    WLEAVE
.Lwno_close:
    mov rcx, r12
    call CloseHandle
    mov rax, -40
    WLEAVE
.Lwno_error:
    call win_nt_error
    WLEAVE

/* RDI=dirfd/AT_FDCWD, RSI=UTF8 path, RDX=open flags, R10=mode.
 * RAX=owned descriptor or negative errno. Uses global 8192-byte UTF16 path
 * buffer; process is single threaded. Explicit drive paths, /C:/ paths, and
 * relative names are accepted. UNC/device names, ADS, trailing dots/spaces,
 * reserved DOS names, and traversal components are rejected before mutation.
 * Existing held roots remain anchored when another process renames a parent.
 */
/* RDI=bounded API-produced UTF16 path. RAX=pointer to its drive-absolute
 * spelling, skipping only an exact extended DOS prefix, or -EINVAL.
 * Rejects UNC, device, volume-GUID and drive-relative namespaces. The caller
 * retains ownership of the original buffer; no character is changed.
 * Scratch: RAX/RCX/RDX/flags. No stack or external calls. */
win_drive_path:
    mov rcx, rdi
    mov rax, 0x005c003f005c005c /* UTF16 \\?\ */
    cmp [rcx], rax
    jne .Lwdp_drive
    add rcx, 8
.Lwdp_drive:
    movzx eax, word ptr [rcx]
    or eax, 32
    cmp eax, 'a'
    jb .Lwdp_invalid
    cmp eax, 'z'
    ja .Lwdp_invalid
    cmp word ptr [rcx + 2], ':'
    jne .Lwdp_invalid
    cmp word ptr [rcx + 4], '\\'
    jne .Lwdp_invalid
    mov rax, rcx
    ret
.Lwdp_invalid:
    mov rax, -22
    ret

win_open:
    WFRAME
    mov r12, rdi
    mov r13, rdx
    mov r14, r10
    mov rdi, rsi
    /* /proc/self/exe refers to the loaded image path, never Linux procfs. */
    lea rsi, [rip + self_proc_exe]
    call streq
    test eax, eax
    jz 1f
    lea rcx, [rip + win_path_wide]
    mov rdx, rcx
    mov r8d, 4096
    xor ecx, ecx
    call GetModuleFileNameW
    test eax, eax
    jz .Lwo_invalid
    cmp eax, 4096
    jae .Lwo_invalid
    or r13d, 0x40000000 /* held running-image binding; final component only */
    jmp .Lwo_absolute_wide
1:  mov rdi, [rbp - 56]
    cmp byte ptr [rdi], '/'
    jne 2f
    cmp byte ptr [rdi + 2], ':'
    jne 2f
    inc rdi
2:  lea rsi, [rip + win_path_wide]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwo_return
    lea r15, [rip + win_path_wide]
    xor ebx, ebx
.Lwo_slashes:
    mov ax, [r15 + rbx*2]
    test ax, ax
    jz .Lwo_slashes_done
    cmp ax, '/'
    jne 3f
    mov word ptr [r15 + rbx*2], '\\'
3:  inc ebx
    jmp .Lwo_slashes
.Lwo_slashes_done:
    cmp word ptr [r15 + 2], ':'
    je .Lwo_drive
    cmp word ptr [r15], '\\'
    jne .Lwo_relative
    cmp word ptr [r15 + 2], 0
    jne .Lwo_invalid /* no UNC or root-relative ambiguity */
    /* Shared absolute walker starts at virtual /. Use Windows system drive. */
    lea rcx, [rip + win_full_wide]
    mov edx, 4096
    call GetWindowsDirectoryW
    test eax, eax
    jz .Lwo_invalid
    lea r15, [rip + win_full_wide]
    mov word ptr [r15 + 4], '\\'
    mov word ptr [r15 + 6], 0
    jmp .Lwo_root
.Lwo_drive:
    cmp word ptr [r15 + 4], 0
    jne 4f
    mov word ptr [r15 + 4], '\\'
    mov word ptr [r15 + 6], 0
4:  cmp word ptr [r15 + 4], '\\'
    jne .Lwo_invalid
.Lwo_absolute_wide:
    lea r15, [rip + win_path_wide]
.Lwo_root:
    mov rdi, r15
    call win_drive_path
    test rax, rax
    js .Lwo_invalid
    mov r15, rax
    /* Native drive root \??\C:\. */
    lea rsi, [rip + win_nt_root]
    mov ax, [r15]
    mov [rsi + 8], ax
    xor edi, edi
    mov edx, 14
    mov r10d, 65536
    xor r8d, r8d
    call win_nt_open
    test rax, rax
    js .Lwo_return
    mov r12, rax
    add r15, 6
    cmp word ptr [r15], 0
    je .Lwo_finish
    jmp .Lwo_component
.Lwo_relative:
    cmp r12, -100
    jne 5f
    /* Resolve the process directory once, then walk its components too. */
    mov ecx, 4096
    lea rdx, [rip + win_full_wide]
    call GetCurrentDirectoryW
    test eax, eax
    jz .Lwo_invalid
    cmp eax, 4096
    jae .Lwo_invalid
    /* Append relative path to the cwd in the alternate buffer. */
    mov ebx, eax
    lea rdi, [rip + win_full_wide]
    mov word ptr [rdi + rbx*2], '\\'
    inc ebx
    lea rsi, [rip + win_path_wide]
.Lwo_append:
    cmp ebx, 4095
    jae .Lwo_invalid
    mov ax, [rsi]
    mov [rdi + rbx*2], ax
    inc ebx
    add rsi, 2
    test ax, ax
    jnz .Lwo_append
    lea r15, [rip + win_full_wide]
    jmp .Lwo_root
5:  mov rdi, r12
    call win_handle
    test rax, rax
    jz .Lwo_invalid
    /* Duplicate to keep caller ownership independent of this walk. */
    mov rdx, rax
    mov rcx, -1
    mov r8, -1
    lea r9, [rbp - 240]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 2
    call DuplicateHandle
    test eax, eax
    jz .Lwo_error
    mov r12, [rbp - 240]
.Lwo_component:
    mov rbx, r15
.Lwo_scan:
    mov ax, [rbx]
    test ax, ax
    jz .Lwo_last
    cmp ax, '\\'
    je .Lwo_middle
    /* A colon introduces an alternate stream; reject it except virtual drive. */
    cmp ax, ':'
    je .Lwo_close_invalid
    cmp ax, 32
    jb .Lwo_close_invalid
    cmp ax, '"'
    je .Lwo_close_invalid
    cmp ax, '*'
    je .Lwo_close_invalid
    cmp ax, '?'
    je .Lwo_close_invalid
    cmp ax, '|'
    je .Lwo_close_invalid
    cmp ax, '<'
    je .Lwo_close_invalid
    cmp ax, '>'
    je .Lwo_close_invalid
    add rbx, 2
    mov rax, rbx
    sub rax, r15
    cmp rax, 510
    ja .Lwo_close_invalid
    jmp .Lwo_scan
.Lwo_middle:
    mov r10d, 65536
    jmp .Lwo_open_component
.Lwo_last:
    mov r10, r13
.Lwo_open_component:
    mov rdx, rbx
    sub rdx, r15
    test rdx, rdx
    jz .Lwo_close_invalid
    cmp word ptr [rbx - 2], ' '
    je .Lwo_close_invalid
    cmp word ptr [rbx - 2], '.'
    jne 6f
    /* Single . is permitted for local project directory operations. */
    cmp edx, 2
    jne .Lwo_close_invalid
    cmp word ptr [rbx], 0
    jne .Lwo_close_invalid
    jmp .Lwo_finish
6:  mov rdi, r15
    call win_component_safe
    test eax, eax
    jz .Lwo_close_invalid
    mov rdi, r12
    mov rsi, r15
    mov r8, r14
    call win_nt_open
    mov [rbp - 248], rax
    mov rcx, r12
    call CloseHandle
    mov r12, [rbp - 248]
    test r12, r12
    js .Lwo_handle_error
    cmp word ptr [rbx], 0
    je .Lwo_finish
    lea r15, [rbx + 2]
    jmp .Lwo_component
.Lwo_finish:
    test r13d, 0x40000000
    jz .Lwo_descriptor
    mov rdi, r12
    call win_image_matches
    test rax, rax
    jns .Lwo_descriptor
    mov rbx, rax
    mov rcx, r12
    call CloseHandle
    mov rax, rbx
    jmp .Lwo_return
.Lwo_descriptor:
    mov rdi, r12
    call win_descriptor
    jmp .Lwo_return
.Lwo_close_invalid:
    mov rcx, r12
    call CloseHandle
.Lwo_invalid:
    mov rax, -22
    jmp .Lwo_return
.Lwo_handle_error:
    mov rax, r12
    jmp .Lwo_return
.Lwo_error:
    call win_error
.Lwo_return:
    WLEAVE

/* Linux-contract dispatcher. Inputs are RAX number and RDI/RSI/RDX/R10/R8/R9.
 * Preserves every input except RAX, matching syscall callers' expectations.
 * Unknown operations return -ENOSYS. No fake permission or durability success.
 */
win_syscall:
    WFRAME
    cmp eax, 0
    je .Lws_read
    cmp eax, 1
    je .Lws_write
    cmp eax, 2
    je .Lws_open
    cmp eax, 3
    je .Lws_close
    cmp eax, 5
    je .Lws_stat
    cmp eax, 6
    je .Lws_lstat
    cmp eax, 8
    je .Lws_seek
    cmp eax, 21
    je .Lws_access
    cmp eax, 39
    je .Lws_pid
    cmp eax, 60
    je .Lws_exit
    cmp eax, 72
    je .Lws_fcntl
    cmp eax, 73
    je .Lws_lock
    cmp eax, 74
    je .Lws_sync
    cmp eax, 79
    je .Lws_getcwd
    cmp eax, 80
    je .Lws_chdir
    cmp eax, 81
    je .Lws_fchdir
    cmp eax, 82
    je .Lws_rename
    cmp eax, 83
    je .Lws_mkdir
    cmp eax, 84
    je .Lws_rmdir
    cmp eax, 87
    je .Lws_unlink
    cmp eax, 89
    je .Lws_readlink
    cmp eax, 90
    je .Lws_chmod
    cmp eax, 91
    je .Lws_fchmod
    cmp eax, 102
    je .Lws_uid
    cmp eax, 104
    je .Lws_uid
    cmp eax, 107
    je .Lws_uid
    cmp eax, 108
    je .Lws_uid
    cmp eax, 138
    je .Lws_fs
    cmp eax, 217
    je .Lws_getdents
    cmp eax, 257
    je .Lws_openat
    cmp eax, 258
    je .Lws_mkdirat
    cmp eax, 262
    je .Lws_statat
    cmp eax, 263
    je .Lws_unlinkat
    cmp eax, 264
    je .Lws_renameat
    cmp eax, 316
    je .Lws_renameat2
    cmp eax, 318
    je .Lws_random
    mov rax, -38
    jmp .Lws_return
.Lws_open:
    mov r10, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, -100
.Lws_openat:
    call win_open
    jmp .Lws_return
.Lws_read:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rcx, rax
    mov rdx, rsi
    mov r8, [rbp - 64]
    cmp r8, 0x7fffffff
    ja .Lws_invalid
    lea r9, [rbp - 128]
    mov qword ptr [rsp + 32], 0
    call ReadFile
    test eax, eax
    jnz .Lws_io_result
    call GetLastError
    cmp eax, 109 /* broken pipe means EOF */
    jne .Lws_error
    xor eax, eax
    jmp .Lws_return
.Lws_write:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rcx, rax
    mov rdx, rsi
    mov r8, [rbp - 64]
    cmp r8, 0x7fffffff
    ja .Lws_invalid
    lea r9, [rbp - 128]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    test eax, eax
    jz .Lws_error
.Lws_io_result:
    mov eax, [rbp - 128]
    jmp .Lws_return
.Lws_close:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov r12, rax
    lea rax, [rip + win_locks]
    mov rcx, [rax + rdi*8]
    mov qword ptr [rax + rdi*8], 0
    test rcx, rcx
    jz 1f
    call CloseHandle
1:  mov rcx, r12
    lea rax, [rip + win_handles]
    mov qword ptr [rax + rdi*8], 0
    lea rax, [rip + win_directory_started]
    mov byte ptr [rax + rdi], 0
    call CloseHandle
    jmp .Lws_bool
.Lws_stat:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rdi, rax
    call win_stat
    jmp .Lws_return
.Lws_lstat:
    mov r12, rsi
    mov rsi, rdi
    mov rdi, -100
    xor edx, edx
    xor r10d, r10d
    call win_open
    jmp .Lws_stat_opened
.Lws_statat:
    mov r12, rdx
    xor edx, edx
    xor r10d, r10d
    call win_open
.Lws_stat_opened:
    test rax, rax
    js .Lws_return
    mov r13, rax
    mov rdi, rax
    call win_handle
    mov rdi, rax
    mov rsi, r12
    call win_stat
    mov r14, rax
    mov rdi, r13
    mov eax, 3
    call win_syscall
    mov rax, r14
    jmp .Lws_return
.Lws_seek:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rcx, rax
    mov rdx, rsi
    lea r8, [rbp - 128]
    mov r9, [rbp - 64]
    call SetFilePointerEx
    test eax, eax
    jz .Lws_error
    mov rax, [rbp - 128]
    jmp .Lws_return
.Lws_access:
    mov rsi, rdi
    mov rdi, -100
    xor edx, edx
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lws_return
    mov rdi, rax
    mov eax, 3
    call win_syscall
    jmp .Lws_return
.Lws_pid:
    call GetCurrentProcessId
    jmp .Lws_return
.Lws_exit:
    mov ecx, edi
    call ExitProcess
    ud2
.Lws_uid:
    mov eax, 1
    jmp .Lws_return
.Lws_mkdir:
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, -100
.Lws_mkdirat:
    mov r10, rdx
    mov edx, 65536 + 64 + 128
    call win_open
    test rax, rax
    js .Lws_return
    mov rdi, rax
    mov eax, 3
    call win_syscall
    jmp .Lws_return
.Lws_rmdir:
    mov r10d, 512
    jmp .Lws_delete_path
.Lws_unlink:
    xor r10d, r10d
.Lws_delete_path:
    mov rdx, r10
    mov rsi, rdi
    mov rdi, -100
.Lws_unlinkat:
    /* Only AT_REMOVEDIR is a defined unlinkat flag in the shared contract. */
    test rdx, rdx
    jz .Lws_delete_flags_valid
    cmp rdx, 512
    jne .Lws_invalid
.Lws_delete_flags_valid:
    mov r14, rdx
    mov r10, rdx
    mov edx, 0x10000000
    cmp r10d, 512
    jne 1f
    or edx, 65536
1:  xor r10d, r10d
    call win_open
    test rax, rax
    js .Lws_return
    mov r12, rax
    mov rdi, rax
    call win_handle
    mov r15, rax
    mov rcx, r15
    mov edx, 9 /* FileAttributeTagInfo on the exact held file */
    lea r8, [rbp - 152]
    mov r9d, 8
    call GetFileInformationByHandleEx
    test eax, eax
    jz .Lws_delete_error
    test dword ptr [rbp - 152], 16
    jz .Lws_delete_regular
    test r14, r14
    jz .Lws_delete_is_directory
    jmp .Lws_delete_kind_valid
.Lws_delete_regular:
    test r14, r14
    jnz .Lws_delete_not_directory
.Lws_delete_kind_valid:
    mov rcx, r15
    mov edx, 21 /* FileDispositionInfoEx */
    mov dword ptr [rbp - 128], 3 /* DELETE | POSIX_SEMANTICS */
    lea r8, [rbp - 128]
    mov r9d, 4
    call SetFileInformationByHandle
    test eax, eax
    jz .Lws_delete_error
    xor r13d, r13d
    jmp .Lws_delete_close
.Lws_delete_is_directory:
    mov r13, -21 /* EISDIR: unlink must preserve directories */
    jmp .Lws_delete_close
.Lws_delete_not_directory:
    mov r13, -20 /* ENOTDIR: rmdir must preserve regular files */
    jmp .Lws_delete_close
.Lws_delete_error:
    /* Capture last error before CloseHandle can change it. */
    call win_error
    mov r13, rax
.Lws_delete_close:
    mov rdi, r12
    mov eax, 3
    call win_syscall
    mov rax, r13
    jmp .Lws_return
.Lws_chdir:
    mov rsi, rdi
    mov rdi, -100
    mov edx, 65536
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lws_return
    mov r12, rax
    mov rdi, rax
    call win_fchdir
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    call win_syscall
    mov rax, r13
    jmp .Lws_return
.Lws_fchdir:
    call win_fchdir
    jmp .Lws_return
.Lws_getcwd:
    mov ecx, 4096
    lea rdx, [rip + win_path_wide]
    call GetCurrentDirectoryW
    test eax, eax
    jz .Lws_error
    cmp eax, 4096
    jae .Lws_invalid
    lea rdi, [rip + win_path_wide]
    call win_drive_path
    test rax, rax
    js .Lws_invalid
    mov rdi, rax
    mov rsi, [rbp - 48]
    mov rdx, [rbp - 56]
    call win_utf8
    jmp .Lws_return
.Lws_readlink:
    xor ecx, ecx
    lea rdx, [rip + win_path_wide]
    mov r8d, 4096
    call GetModuleFileNameW
    test eax, eax
    jz .Lws_error
    cmp eax, 4096
    jae .Lws_invalid
    lea rdi, [rip + win_path_wide]
    mov rsi, [rbp - 56]
    mov rdx, [rbp - 64]
    call win_utf8
    test rax, rax
    js .Lws_return
    dec rax
    jmp .Lws_return
.Lws_sync:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rcx, rax
    call FlushFileBuffers
    jmp .Lws_bool
.Lws_fchmod:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rdi, rax
    call win_protect
    jmp .Lws_return
.Lws_chmod:
    mov rsi, rdi
    mov rdi, -100
    mov edx, 0x20000002
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lws_return
    mov r12, rax
    mov rdi, rax
    mov eax, 91
    call win_syscall
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    call win_syscall
    mov rax, r13
    jmp .Lws_return
.Lws_rename:
    mov r10, rsi
    mov rsi, rdi
    mov rdi, -100
    mov rdx, -100
.Lws_renameat:
    xor r8d, r8d
.Lws_renameat2:
    call win_rename
    jmp .Lws_return
.Lws_lock:
    call win_lock
    jmp .Lws_return
.Lws_fcntl:
    call win_duplicate
    jmp .Lws_return
.Lws_fs:
    call win_handle
    test rax, rax
    jz .Lws_badfd
    mov rdi, rax
    call win_ntfs
    test rax, rax
    js .Lws_return
    mov rsi, [rbp - 56]
    mov dword ptr [rsi], 0x5346544e /* NTFS sentinel */
    xor eax, eax
    jmp .Lws_return
.Lws_random:
    xor ecx, ecx
    mov rdx, rdi
    mov r8, rsi
    mov r9d, 2 /* system preferred RNG */
    call BCryptGenRandom
    test eax, eax
    js .Lws_ioerror
    mov rax, [rbp - 56]
    jmp .Lws_return
.Lws_getdents:
    call win_getdents
    jmp .Lws_return
.Lws_bool:
    test eax, eax
    jz .Lws_error
    xor eax, eax
    jmp .Lws_return
.Lws_badfd: mov rax, -9
    jmp .Lws_return
.Lws_invalid: mov rax, -22
    jmp .Lws_return
.Lws_ioerror: mov rax, -5
    jmp .Lws_return
.Lws_error:
    call win_error
.Lws_return:
    WLEAVE

win_fchdir:
    WFRAME
    call win_handle
    test rax, rax
    jz .Lwfc_bad
    mov rcx, rax
    lea rdx, [rip + win_full_wide]
    mov r8d, 4096
    xor r9d, r9d
    call GetFinalPathNameByHandleW
    test eax, eax
    jz .Lwfc_bad
    cmp eax, 4096
    jae .Lwfc_bad
    lea rcx, [rip + win_full_wide]
    call SetCurrentDirectoryW
    test eax, eax
    jz .Lwfc_bad
    xor eax, eax
    WLEAVE
.Lwfc_bad:
    mov rax, -13
    WLEAVE

.section .data
.p2align 1
win_nt_root: .short '\\','?','?','\\','C',':','\\',0
win_home: .ascii "HOME="
    .space 4096
.section .rdata,"dr"
.p2align 1
win_home_name: .short 'H','O','M','E',0
.p2align 1
win_profile_name: .short 'U','S','E','R','P','R','O','F','I','L','E',0
win_kernel32_lib: .asciz "-Wl,kernel32.lib"
win_error_initialize: .asciz "cannot initialize Windows arguments, paths, or user permissions"
.section .bss
.p2align 3
win_argc: .space 8
win_argv: .space 4104
win_arguments: .space 65536
win_environment: .space 4104
win_environment_bytes: .space 65536
win_home_wide: .space 8192
win_handles: .space 2048
win_directory_started: .space 256
win_path_wide: .space 8192
win_full_wide: .space 8192
win_private_sd: .space 64
win_hash_hex: .space 65

.text
/* Initializes a protected DACL that grants full access only to the current
 * token user and LocalSystem. Owner SID and ACL storage live for the process.
 * RAX=0/1. Token HANDLE and API allocated buffers have explicit ownership. */
win_security_initialize:
    WFRAME
    mov rcx, -1
    mov edx, 8
    lea r8, [rbp - 128]
    call OpenProcessToken
    test eax, eax
    jz .Lwsi_bad
    mov r12, [rbp - 128]
    mov rcx, r12
    mov edx, 1
    lea r8, [rip + win_token_user]
    mov r9d, 4096
    lea rax, [rbp - 136]
    mov [rsp + 32], rax
    call GetTokenInformation
    mov r13d, eax
    mov rcx, r12
    mov edx, 20 /* TokenElevation: explicit elevated-token exception only */
    lea r8, [rip + win_token_elevation]
    mov r9d, 4
    lea rax, [rbp - 136]
    mov [rsp + 32], rax
    call GetTokenInformation
    mov r14d, eax
    mov rcx, r12
    call CloseHandle
    test r13d, r13d
    jz .Lwsi_bad
    test r14d, r14d
    jz .Lwsi_bad
    mov ecx, 22 /* WinLocalSystemSid */
    xor edx, edx
    lea r8, [rip + win_system_sid]
    lea r9, [rip + win_sid_capacity]
    call CreateWellKnownSid
    test eax, eax
    jz .Lwsi_bad
    mov dword ptr [rip + win_sid_capacity], 68
    mov ecx, 26 /* WinBuiltinAdministratorsSid */
    xor edx, edx
    lea r8, [rip + win_admin_sid]
    lea r9, [rip + win_sid_capacity]
    call CreateWellKnownSid
    test eax, eax
    jz .Lwsi_bad
    mov dword ptr [rip + win_sid_capacity], 68
    mov ecx, 71 /* WinCreatorOwnerRightsSid */
    xor edx, edx
    lea r8, [rip + win_owner_rights_sid]
    lea r9, [rip + win_sid_capacity]
    call CreateWellKnownSid
    test eax, eax
    jz .Lwsi_bad
    /* Resolve the fixed OS service identity, never a caller-selected name. */
    xor ecx, ecx
    lea rdx, [rip + win_installer_name]
    lea r8, [rip + win_installer_sid]
    lea r9, [rip + win_installer_capacity]
    lea rax, [rbp - 400] /* owned domain[128 UTF16] */
    mov [rsp + 32], rax
    mov dword ptr [rbp - 128], 128
    lea rax, [rbp - 128]
    mov [rsp + 40], rax
    lea rax, [rbp - 136]
    mov [rsp + 48], rax
    call LookupAccountNameW
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_acl]
    mov edx, 4096
    mov r8d, 2
    call InitializeAcl
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_acl]
    mov edx, 2
    mov r8d, 0x1f01ff
    mov r9, [rip + win_token_user]
    call AddAccessAllowedAce
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_acl]
    mov edx, 2
    mov r8d, 0x1f01ff
    lea r9, [rip + win_system_sid]
    call AddAccessAllowedAce
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_sd]
    mov edx, 1
    call InitializeSecurityDescriptor
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_sd]
    mov rdx, [rip + win_token_user]
    xor r8d, r8d
    call SetSecurityDescriptorOwner
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_sd]
    mov edx, 1
    lea r8, [rip + win_private_acl]
    xor r9d, r9d
    call SetSecurityDescriptorDacl
    test eax, eax
    jz .Lwsi_bad
    lea rcx, [rip + win_private_sd]
    mov edx, 0x1000 /* SE_DACL_PROTECTED */
    mov r8d, 0x1000
    call SetSecurityDescriptorControl
    test eax, eax
    jz .Lwsi_bad
    xor eax, eax
    WLEAVE
.Lwsi_bad:
    mov eax, 1
    WLEAVE

/* RDI=valid owner SID; ESI=1 ordinary file,0 directory/grant.
 * EAX=1 current owner,0 trusted system,2 foreign.
 * Administrators counts as current only for a verified elevated token.
 * WFRAME preserves inputs; SID storage is process-owned. */
win_owner_class:
    WFRAME
    mov r12, rdi
    mov rcx, r12
    call IsValidSid
    test eax, eax
    jz .Lwoc_foreign
    mov rcx, r12
    mov rdx, [rip + win_token_user]
    call EqualSid
    test eax, eax
    jnz .Lwoc_user
    mov rcx, r12
    lea rdx, [rip + win_admin_sid]
    call EqualSid
    test eax, eax
    jz .Lwoc_system
    test esi, esi
    jz .Lwoc_root
    cmp dword ptr [rip + win_token_elevation], 0
    jne .Lwoc_user
    jmp .Lwoc_root
.Lwoc_system:
    mov rcx, r12
    lea rdx, [rip + win_system_sid]
    call EqualSid
    test eax, eax
    jnz .Lwoc_root
    mov rcx, r12
    lea rdx, [rip + win_installer_sid]
    call EqualSid
    test eax, eax
    jnz .Lwoc_root
.Lwoc_foreign:
    mov eax, 2
    WLEAVE
.Lwoc_user:
    mov eax, 1
    WLEAVE
.Lwoc_root:
    xor eax, eax
    WLEAVE

/* RDI=validated effective grant SID; ESI=owner class0..2. EAX=1 safe/0.
 * OWNER_RIGHTS denotes only an already qualified object owner. Foreign
 * owner rights remain unsafe. Privileged OS principals retain their scope. */
win_grant_safe:
    WFRAME
    mov r12, rdi
    mov r13d, esi
    xor esi, esi
    call win_owner_class
    cmp eax, 2
    jne .Lwgs_safe
    cmp r13d, 2
    je .Lwgs_bad
    mov rcx, r12
    lea rdx, [rip + win_owner_rights_sid]
    call EqualSid
    test eax, eax
    jnz .Lwgs_safe
.Lwgs_bad:
    xor eax, eax
    WLEAVE
.Lwgs_safe:
    mov eax, 1
    WLEAVE

/* RDI=owned file HANDLE, RSI=owned normalized stat[144]. RAX=0/-errno.
 * Volume serial + NTFS file index identify the file. Linux mode/uid fields
 * are an internal encoding of the actual Windows owner and DACL, never a
 * substitute for a permission check. An unsafe DACL sets group-write bits.
 * RAX/RCX/R11 scratch; all input registers preserved. */
win_stat:
    WFRAME
    mov r12, rdi
    mov r13, rsi
    mov rcx, r12
    lea rdx, [rbp - 192]
    call GetFileInformationByHandle
    test eax, eax
    jz .Lwst_error
    test dword ptr [rbp - 192], 0x400
    jnz .Lwst_unsafe
    mov rdi, r13
    mov ecx, 18
    xor eax, eax
    rep stosq
    mov eax, [rbp - 164] /* volume serial */
    mov [r13], rax
    mov eax, [rbp - 148] /* file index high */
    shl rax, 32
    mov edx, [rbp - 144]
    or rax, rdx
    mov [r13 + 8], rax
    mov eax, [rbp - 152] /* links */
    mov [r13 + 16], rax
    mov eax, 0x81c0 /* regular 0700 */
    test dword ptr [rbp - 192], 16
    jz 1f
    mov eax, 0x41c0
1:  mov [r13 + 24], eax
    mov eax, [rbp - 160] /* size high */
    shl rax, 32
    mov edx, [rbp - 156]
    or rax, rdx
    mov [r13 + 48], rax
    mov rcx, r12
    mov edx, 1 /* SE_FILE_OBJECT */
    mov r8d, 5 /* OWNER + DACL */
    lea r9, [rbp - 208]
    mov qword ptr [rsp + 32], 0
    lea rax, [rbp - 216]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    lea rax, [rbp - 224]
    mov [rsp + 56], rax
    call GetSecurityInfo
    test eax, eax
    jnz .Lwst_unsafe
    mov r14, [rbp - 224]
    mov rdi, [rbp - 208]
    xor esi, esi
    test dword ptr [rbp - 192], 16
    setz sil
    call win_owner_class
    mov [r13 + 28], eax
.Lwst_acl:
    mov r12, [rbp - 216]
    test r12, r12
    jz .Lwst_acl_bad
    mov rcx, r12
    call IsValidAcl
    test eax, eax
    jz .Lwst_acl_bad
    movzx r15d, word ptr [r12 + 4]
    cmp r15d, 256
    ja .Lwst_acl_bad
    xor ebx, ebx
.Lwst_ace:
    cmp ebx, r15d
    jae .Lwst_acl_done
    mov rcx, r12
    mov edx, ebx
    lea r8, [rbp - 232]
    call GetAce
    test eax, eax
    jz .Lwst_acl_bad
    mov rax, [rbp - 232]
    test byte ptr [rax + 1], 8 /* inherit-only ACE */
    jnz .Lwst_ace_next
    cmp byte ptr [rax], 1 /* ACCESS_DENIED_ACE */
    je .Lwst_ace_next
    cmp byte ptr [rax], 0 /* ACCESS_ALLOWED_ACE */
    jne .Lwst_acl_bad
    mov edx, 0x500d0156
    test dword ptr [r13 + 24], 0x4000
    jz 3f
    cmp dword ptr [r13 + 28], 0
    jne 3f
    /* Only FILE_ADD_SUBDIRECTORY is harmless to existing protected children. */
    and edx, -5
3:  test [rax + 4], edx
    jz .Lwst_ace_next
    /* A known ACE must contain a complete valid SID before comparison. */
    movzx edx, word ptr [rax + 2]
    cmp edx, 16
    jb .Lwst_acl_bad
    movzx ecx, byte ptr [rax + 9]
    lea ecx, [rcx*4 + 16]
    cmp ecx, edx
    ja .Lwst_acl_bad
    lea rcx, [rax + 8]
    call IsValidSid
    test eax, eax
    jz .Lwst_acl_bad
    mov rdi, [rbp - 232]
    add rdi, 8
    mov esi, [r13 + 28]
    call win_grant_safe
    test eax, eax
    jz .Lwst_acl_bad
.Lwst_ace_next:
    inc ebx
    jmp .Lwst_ace
.Lwst_acl_bad:
    or dword ptr [r13 + 24], 18
.Lwst_acl_done:
    mov rcx, r14
    call LocalFree
    xor eax, eax
    WLEAVE
.Lwst_unsafe:
    mov rax, -13
    WLEAVE
.Lwst_error:
    call win_error
    WLEAVE

/* RDI=HANDLE with WRITE_DAC. Replace its DACL with the protected private
 * DACL. RAX=0/-errno. This is the Windows executable permission contract;
 * no POSIX chmod call silently succeeds. */
win_protect:
    WFRAME
    mov rcx, rdi
    mov edx, 1
    mov r8d, 0x80000004
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    lea rax, [rip + win_private_acl]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    call SetSecurityInfo
    test eax, eax
    jz .Lwpr_good
    mov rax, -13
    WLEAVE
.Lwpr_good:
    xor eax, eax
    WLEAVE

/* RDI=volume HANDLE. RAX=0 for local NTFS, -EOPNOTSUPP otherwise.
 * Failure does not imply filesystem compatibility. Buffer:32 UTF16 units. */
win_ntfs:
    WFRAME
    mov rcx, rdi
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    lea rax, [rbp - 128]
    mov [rsp + 40], rax
    lea rax, [rbp - 208]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 32
    call GetVolumeInformationByHandleW
    test eax, eax
    jz .Lwn_bad
    mov rax, 0x005300460054004e
    cmp [rbp - 208], rax
    jne .Lwn_bad
    cmp word ptr [rbp - 200], 0
    jne .Lwn_bad
    /* FILE_REMOTE_DEVICE=0x10 is queried separately by NtQueryVolumeInformationFile. */
    mov rcx, [rbp - 48]
    lea rdx, [rbp - 144]
    lea r8, [rbp - 160]
    mov r9d, 8
    mov qword ptr [rsp + 32], 4 /* FileFsDeviceInformation */
    call NtQueryVolumeInformationFile
    test eax, eax
    js .Lwn_bad
    test dword ptr [rbp - 156], 0x10
    jnz .Lwn_bad
    xor eax, eax
    WLEAVE
.Lwn_bad:
    mov rax, -95
    WLEAVE

/* RDI=source dirfd, RSI=source component/path, RDX=destination dirfd,
 * R10=destination component, R8=0 replace or 1 no-replace. RAX=0/-errno.
 * The source is opened with DELETE; destination parent is held. Nt rename
 * performs one filesystem operation. No copy fallback crosses volumes.
 */
win_rename:
    WFRAME
    mov r12, rdx
    mov r13, r10
    mov r14, r8
    mov edx, 0x10000000
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lwr_return
    mov r15, rax
    mov rdi, rax
    call win_handle
    mov [rbp - 128], rax
    /* Resolve target parent with the same component walker. */
    mov rdi, r12
    mov rsi, r13
    call win_open_parent
    test rax, rax
    js .Lwr_close_source
    mov r12, rax
    mov rdi, rax
    call win_handle
    mov r13, rax
    mov rdi, [rip + win_parent_basename]
    lea rsi, [rip + win_rename_info + 20]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwr_close_both
    dec eax
    shl eax, 1
    mov [rip + win_rename_info + 16], eax
    mov [rip + win_rename_info + 8], r13
    mov edx, eax
    lea rdi, [rip + win_rename_info + 20]
    call win_component_safe
    test eax, eax
    jz .Lwr_name_bad
    mov dword ptr [rip + win_rename_info], 2 /* POSIX_SEMANTICS */
    test r14, r14
    jnz 1f
    or dword ptr [rip + win_rename_info], 1
1:  lea r8, [rip + win_rename_info]
    mov r9d, [rip + win_rename_info + 16]
    add r9d, 20
    mov rcx, [rbp - 128]
    lea rdx, [rbp - 144]
    mov qword ptr [rsp + 32], 65 /* FileRenameInformationEx */
    call NtSetInformationFile
    test eax, eax
    js .Lwr_error
    xor eax, eax
    jmp .Lwr_close_both
.Lwr_error:
    call win_nt_error
    jmp .Lwr_close_both
.Lwr_name_bad:
    mov rax, -22
.Lwr_close_both:
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    call win_syscall
    mov rax, r13
.Lwr_close_source:
    mov r13, rax
    mov rdi, r15
    mov eax, 3
    call win_syscall
    mov rax, r13
.Lwr_return:
    WLEAVE

/* RDI=dirfd, RSI=path <=4095 bytes. RAX=held parent fd; global basename
 * borrows the last component of win_parent_path[4096]. Rejects empty names.
 * No mkdir occurs. Shared callers already validate traversal and destinations.
 */
win_open_parent:
    WFRAME
    mov r12, rdi
    mov rdi, rsi
    call strlen
    cmp rax, 4095
    ja .Lwop_bad
    lea rdi, [rip + win_parent_path]
    mov rsi, [rbp - 56]
    call copy_string
    mov r13, rax
    lea rbx, [rip + win_parent_path]
    mov r14, rbx
.Lwop_scan:
    cmp r13, rbx
    je .Lwop_noparent
    dec r13
    cmp byte ptr [r13], '/'
    je .Lwop_separator
    cmp byte ptr [r13], '\\'
    jne .Lwop_scan
.Lwop_separator:
    lea rax, [r13 + 1]
    cmp byte ptr [rax], 0
    je .Lwop_bad
    mov [rip + win_parent_basename], rax
    mov byte ptr [r13], 0
    mov rsi, rbx
    cmp r13, rbx
    jne .Lwop_open
    lea rsi, [rip + win_root_utf8]
    jmp .Lwop_open
.Lwop_noparent:
    cmp byte ptr [rbx], 0
    je .Lwop_bad
    mov [rip + win_parent_basename], rbx
    lea rsi, [rip + dot]
.Lwop_open:
    mov rdi, r12
    mov edx, 65536
    xor r10d, r10d
    call win_open
    WLEAVE
.Lwop_bad:
    mov rax, -22
    WLEAVE

/* Descriptor duplication supports only F_DUPFD_CLOEXEC. RAX=new fd/-errno. */
win_duplicate:
    WFRAME
    cmp esi, 1030
    jne .Lwdup_bad
    call win_handle
    test rax, rax
    jz .Lwdup_bad
    mov rcx, -1
    mov rdx, rax
    mov r8, -1
    lea r9, [rbp - 128]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 2
    call DuplicateHandle
    test eax, eax
    jz .Lwdup_bad
    mov rdi, [rbp - 128]
    call win_descriptor
    WLEAVE
.Lwdup_bad:
    mov rax, -22
    WLEAVE

/* Directory locks use a private, no-share file anchored to the directory.
 * The lock HANDLE remains associated with the descriptor and is released
 * when that descriptor closes. Existing lock files are reusable; no unlink
 * race controls lock ownership. RDI=fd RSI=LOCK_EX|LOCK_NB or LOCK_UN.
 * RAX=0/-EWOULDBLOCK/-errno. Only local NTFS is supported. */
win_lock:
    WFRAME
    cmp rdi, 256
    jae .Lwl_bad
    mov r12, rdi
    lea rbx, [rip + win_locks]
    test esi, 8
    jnz .Lwl_unlock
    cmp qword ptr [rbx + r12*8], 0
    jne .Lwl_good
    call win_handle
    test rax, rax
    jz .Lwl_bad
    mov rdi, rax
    call win_ntfs
    test rax, rax
    js .Lwl_return
    mov rdi, r12
    call win_handle
    mov rcx, rax
    lea rdx, [rbp - 192]
    call GetFileInformationByHandle
    test eax, eax
    jz .Lwl_bad
    test dword ptr [rbp - 192], 16
    jz .Lwl_regular
    mov rdi, r12
    call win_handle
    mov rdi, rax
    lea rsi, [rip + win_lock_name]
    mov edx, 18
    mov r10d, 64 + 2
    mov r8d, 384
    call win_nt_open
    test rax, rax
    js .Lwl_return
    mov r13, rax
    jmp .Lwl_native_lock
.Lwl_regular:
    mov rdi, r12
    mov esi, 1030
    mov edx, 3
    call win_duplicate
    test rax, rax
    js .Lwl_return
    mov rdi, rax
    call win_handle
    mov r13, rax
    /* Transfer the duplicate HANDLE into lock ownership without closing it. */
    lea rax, [rip + win_handles]
    mov qword ptr [rax + rdi*8], 0
.Lwl_native_lock:
    /* LockFileEx gives kernel-held nonblocking byte-range exclusion. */
    mov rcx, r13
    mov edx, 1
    test qword ptr [rbp - 56], 2
    jz 4f
    or edx, 2
4:
    xor r8d, r8d
    mov r9d, 1
    mov qword ptr [rsp + 32], 0
    lea rax, [rip + win_lock_overlapped]
    mov [rsp + 40], rax
    call LockFileEx
    test eax, eax
    jz .Lwl_close_error
    mov [rbx + r12*8], r13
.Lwl_good:
    xor eax, eax
    WLEAVE
.Lwl_unlock:
    mov rcx, [rbx + r12*8]
    mov qword ptr [rbx + r12*8], 0
    test rcx, rcx
    jz .Lwl_good
    call CloseHandle
    jmp .Lwl_good
.Lwl_close_error:
    mov rcx, r13
    call CloseHandle
    mov rax, -11
    WLEAVE
.Lwl_bad:
    mov rax, -9
.Lwl_return:
    WLEAVE

/* RDI=directory fd, RSI=owned output, RDX=capacity >= 280. Returns one
 * normalized Linux dirent64 (aligned length), EOF=0, or negative errno.
 * The OS enumeration cursor belongs to the held directory HANDLE. Unicode
 * conversion is strict; unknown type/reparse entries remain visible to the
 * assembly archive checker, which rejects unexpected or linked members. */
win_getdents:
    WFRAME
    cmp rdi, 256
    jae .Lwgd_bad
    cmp rdx, 280
    jb .Lwgd_bad
    mov r12, rdi
    mov r13, rsi
    call win_handle
    test rax, rax
    jz .Lwgd_bad
    mov rcx, rax
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rbp - 128]
    mov [rsp + 32], rax
    lea rax, [rip + win_directory_info]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 1024
    mov qword ptr [rsp + 56], 1 /* FileDirectoryInformation */
    mov qword ptr [rsp + 64], 1 /* single entry */
    mov qword ptr [rsp + 72], 0
    lea rax, [rip + win_directory_started]
    movzx eax, byte ptr [rax + r12]
    xor eax, 1
    mov [rsp + 80], rax
    call NtQueryDirectoryFile
    cmp eax, 0x80000006 /* STATUS_NO_MORE_FILES */
    je .Lwgd_eof
    test eax, eax
    js .Lwgd_error
    lea rax, [rip + win_directory_started]
    mov byte ptr [rax + r12], 1
    lea rbx, [rip + win_directory_info]
    mov eax, [rbx + 60]
    cmp eax, 510
    ja .Lwgd_bad
    test al, 1
    jnz .Lwgd_bad
    mov word ptr [rbx + rax + 64], 0
    lea rdi, [rbx + 64]
    lea rsi, [r13 + 19]
    mov rdx, [rbp - 64]
    sub rdx, 19
    call win_utf8
    test rax, rax
    js .Lwgd_return
    add rax, 26
    and rax, -8
    cmp rax, [rbp - 64]
    ja .Lwgd_bad
    mov qword ptr [r13], 1
    mov qword ptr [r13 + 8], 0
    mov [r13 + 16], ax
    mov byte ptr [r13 + 18], 8
    test dword ptr [rbx + 56], 16
    jz 1f
    mov byte ptr [r13 + 18], 4
1:  test dword ptr [rbx + 56], 0x400
    jz .Lwgd_return
    mov byte ptr [r13 + 18], 10
    jmp .Lwgd_return
.Lwgd_eof:
    xor eax, eax
    jmp .Lwgd_return
.Lwgd_error:
    call win_nt_error
    jmp .Lwgd_return
.Lwgd_bad:
    mov rax, -22
.Lwgd_return:
    WLEAVE

.section .data
.p2align 2
win_sid_capacity: .long 68
.p2align 2
win_installer_capacity: .long 68
.section .rdata,"dr"
win_root_utf8: .asciz "/"
.p2align 1
win_installer_name: .short 78,84,32,83,69,82,86,73,67,69,92,84,114,117,115,116,101,100,73,110,115,116,97,108,108,101,114,0
.p2align 1
win_lock_name: .short '.','a','s','m','.','l','o','c','k',0
.section .bss
.p2align 3
win_token_user: .space 4096
win_system_sid: .space 68
win_admin_sid: .space 68
win_installer_sid: .space 68
win_owner_rights_sid: .space 68
win_token_elevation: .space 4
.p2align 3
win_private_acl: .space 4096
.p2align 3
win_rename_info: .space 8216
win_parent_path: .space 4096
win_parent_basename: .space 8
win_locks: .space 2048
win_lock_overlapped: .space 32
win_directory_info: .space 1024

.text
/* RDI=fixed/explicit executable UTF8, RSI=argv[<=512], RDX=environment array
 * or 0, R10=capture buffer or 0, R8=capture capacity, R9=stdin fd or -1.
 * Returns EAX=child status 0..255 or 127; capture length is win_capture_length.
 * Exact argv quotation follows the Windows CRT backslash/quote rules. The
 * application name is supplied separately, so argv never selects a program.
 * Captures use a pipe and polling with a 120-second deadline, terminating and
 * reaping on overflow or timeout. Ordinary applications inherit their streams.
 * Owns process/thread/pipe/duplicated stream handles until every return path.
 * Buffer capacities: command UTF8 32767, UTF16 32767; argv <=512 entries.
 * Windows only inherits the three explicit stream handles created here; native
 * file, directory, token and inventory handles are never inheritable.
 */
win_process:
    WFRAME
    mov r12, rdi
    mov r13, rsi
    mov r14, r10
    mov r15, r8
    mov qword ptr [rip + win_capture_length], 0
    mov qword ptr [rip + win_process_handle], 0
    mov qword ptr [rip + win_thread_handle], 0
    mov qword ptr [rip + win_pipe_read], 0
    mov qword ptr [rip + win_pipe_write], 0
    mov qword ptr [rip + win_child_stdin], 0
    mov qword ptr [rip + win_child_stdout], 0
    mov qword ptr [rip + win_child_stderr], 0
    mov rdi, r12
    lea rsi, [rip + win_executable_wide]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwp_failed
    lea rbx, [rip + win_command_utf8]
    xor r8d, r8d
    xor r9d, r9d
.Lwp_argument:
    cmp r9d, 512
    jae .Lwp_failed
    mov rsi, [r13 + r9*8]
    test rsi, rsi
    jz .Lwp_command_done
    test r9d, r9d
    jz 1f
    mov al, ' '
    call win_command_byte
    test eax, eax
    jnz .Lwp_failed
1:  mov al, '"'
    call win_command_byte
    test eax, eax
    jnz .Lwp_failed
    xor edx, edx
    xor ecx, ecx
.Lwp_character:
    cmp ecx, 4096
    jae .Lwp_failed
    mov al, [rsi + rcx]
    cmp al, '\\'
    jne .Lwp_non_backslash
    inc edx
    inc ecx
    jmp .Lwp_character
.Lwp_non_backslash:
    test al, al
    jz .Lwp_trailing
    cmp al, '"'
    jne .Lwp_emit_slashes
    add edx, edx
    inc edx
.Lwp_emit_slashes:
    test edx, edx
    jz .Lwp_emit_character
    mov al, '\\'
    call win_command_byte
    test eax, eax
    jnz .Lwp_failed
    dec edx
    jmp .Lwp_emit_slashes
.Lwp_emit_character:
    mov al, [rsi + rcx]
    call win_command_byte
    test eax, eax
    jnz .Lwp_failed
    inc ecx
    jmp .Lwp_character
.Lwp_trailing:
    add edx, edx
.Lwp_trailing_loop:
    test edx, edx
    jz .Lwp_close_quote
    mov al, '\\'
    call win_command_byte
    test eax, eax
    jnz .Lwp_failed
    dec edx
    jmp .Lwp_trailing_loop
.Lwp_close_quote:
    mov al, '"'
    call win_command_byte
    test eax, eax
    jnz .Lwp_failed
    inc r9d
    jmp .Lwp_argument
.Lwp_command_done:
    mov byte ptr [rbx + r8], 0
    mov rdi, rbx
    lea rsi, [rip + win_command_wide]
    mov edx, 32767
    call win_wide_command
    test eax, eax
    jz .Lwp_failed
    /* Every fixed tool gets the bounded build environment. */
    mov rdi, [rbp - 64]
    test rdi, rdi
    jnz .Lwp_explicit_environment
    lea rsi, [rip + as_path]
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lwp_tool_environment
    lea rsi, [rip + native_cc_path]
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lwp_tool_environment
    mov qword ptr [rip + win_child_environment], 0
    jmp .Lwp_streams
.Lwp_tool_environment:
    call win_build_environment
    test eax, eax
    jnz .Lwp_failed
    lea rax, [rip + win_environment_wide]
    mov [rip + win_child_environment], rax
    jmp .Lwp_streams
.Lwp_explicit_environment:
    call win_explicit_environment
    test eax, eax
    jnz .Lwp_failed
    lea rax, [rip + win_environment_wide]
    mov [rip + win_child_environment], rax
.Lwp_streams:
    /* STARTUPINFOEX includes a strict inherited handle list. */
    lea rdi, [rip + win_startup]
    xor eax, eax
    mov ecx, 14
    rep stosq
    mov dword ptr [rip + win_startup], 112
    mov dword ptr [rip + win_startup + 60], 0x100
    test r14, r14
    jz .Lwp_uncaptured
    lea rcx, [rip + win_pipe_read]
    lea rdx, [rip + win_pipe_write]
    lea r8, [rip + win_pipe_security]
    xor r9d, r9d
    call CreatePipe
    test eax, eax
    jz .Lwp_failed
    /* Own both successful outputs before the next fallible API call. */
    mov rax, [rip + win_pipe_write]
    mov [rip + win_child_stdout], rax
    mov rcx, [rip + win_pipe_read]
    mov edx, 1
    xor r8d, r8d
    call SetHandleInformation
    test eax, eax
    jz .Lwp_failed
    jmp .Lwp_stdin
.Lwp_uncaptured:
    mov rdi, [rip + win_handles + 8]
    call win_inherit_duplicate
    test rax, rax
    jz .Lwp_failed
    mov [rip + win_child_stdout], rax
.Lwp_stdin:
    mov rdi, [rip + win_handles]
    cmp qword ptr [rbp - 80], -1
    je .Lwp_null_input
    cmp qword ptr [rbp - 80], 0
    jle .Lwp_stdin_ready
    mov rdi, [rbp - 80]
    call win_handle
    mov rdi, rax
    jmp .Lwp_stdin_ready
.Lwp_null_input:
    lea rcx, [rip + win_null_wide]
    mov edx, 0x80000000
    mov r8d, 3
    lea r9, [rip + win_pipe_security]
    mov qword ptr [rsp + 32], 3
    mov qword ptr [rsp + 40], 128
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    cmp rax, -1
    je .Lwp_failed
    mov [rip + win_child_stdin], rax
    jmp .Lwp_stderr
.Lwp_stdin_ready:
    call win_inherit_duplicate
    test rax, rax
    jz .Lwp_failed
    mov [rip + win_child_stdin], rax
.Lwp_stderr:
    mov rdi, [rip + win_handles + 16]
    call win_inherit_duplicate
    test rax, rax
    jz .Lwp_failed
    mov [rip + win_child_stderr], rax
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
    jz .Lwp_failed
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
    jz .Lwp_delete_attributes_fail
    lea rcx, [rip + win_executable_wide]
    lea rdx, [rip + win_command_wide]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 1
    mov qword ptr [rsp + 40], 0x80400 /* EXTENDED_STARTUPINFO + UNICODE_ENV */
    mov rax, [rip + win_child_environment]
    mov [rsp + 48], rax
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
    jz .Lwp_failed
    mov rax, [rip + win_process_info]
    mov [rip + win_process_handle], rax
    mov rax, [rip + win_process_info + 8]
    mov [rip + win_thread_handle], rax
    /* Parent must close its write pipe before waiting for EOF. */
    call win_close_child_streams
    call GetTickCount64
    mov r12, rax
.Lwp_poll:
    test r14, r14
    jz .Lwp_wait
    /* A continuously readable pipe must not bypass the capture deadline. */
    call GetTickCount64
    sub rax, r12
    cmp rax, 120000
    jae .Lwp_terminate
    mov rcx, [rip + win_pipe_read]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rbp - 136]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    call PeekNamedPipe
    test eax, eax
    jz .Lwp_pipe_end
    mov r8d, [rbp - 136]
    test r8d, r8d
    jz .Lwp_wait
    mov rax, [rip + win_capture_length]
    mov rdx, r15
    sub rdx, rax
    jbe .Lwp_terminate
    cmp r8, rdx
    cmova r8, rdx
    mov rcx, [rip + win_pipe_read]
    lea rdx, [r14 + rax]
    lea r9, [rbp - 144]
    mov qword ptr [rsp + 32], 0
    call ReadFile
    test eax, eax
    jz .Lwp_pipe_end
    mov eax, [rbp - 144]
    add [rip + win_capture_length], rax
    jmp .Lwp_poll
.Lwp_pipe_end:
    call GetLastError
    cmp eax, 109
    jne .Lwp_terminate
    mov rcx, [rip + win_process_handle]
    mov edx, 10
    call WaitForSingleObject
    test eax, eax
    jz .Lwp_complete
    jmp .Lwp_deadline
.Lwp_wait:
    mov rcx, [rip + win_process_handle]
    mov edx, 10
    call WaitForSingleObject
    test eax, eax
    jz .Lwp_exited
    cmp eax, 258
    jne .Lwp_terminate
.Lwp_deadline:
    /* The top of every capture iteration checks the clock, including the
     * drain path. Deliberately run applications retain caller-owned duration. */
    jmp .Lwp_poll
.Lwp_exited:
    test r14, r14
    jz .Lwp_complete
    /* Drain remaining pipe data after the process exits. */
    mov rcx, [rip + win_pipe_read]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rbp - 136]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    call PeekNamedPipe
    test eax, eax
    jz .Lwp_complete
    cmp dword ptr [rbp - 136], 0
    jne .Lwp_poll
.Lwp_complete:
    mov rcx, [rip + win_process_handle]
    lea rdx, [rbp - 152]
    call GetExitCodeProcess
    test eax, eax
    jz .Lwp_failed
    mov ebx, [rbp - 152]
    cmp ebx, 255
    jbe .Lwp_cleanup
    mov ebx, 127
    jmp .Lwp_cleanup
.Lwp_terminate:
    mov rcx, [rip + win_process_handle]
    mov edx, 127
    call TerminateProcess
    mov rcx, [rip + win_process_handle]
    mov edx, -1
    call WaitForSingleObject
    jmp .Lwp_failed
.Lwp_delete_attributes_fail:
    lea rcx, [rip + win_attribute_list]
    call DeleteProcThreadAttributeList
.Lwp_failed:
    mov ebx, 127
.Lwp_cleanup:
    call win_close_child_streams
    mov rcx, [rip + win_pipe_read]
    test rcx, rcx
    jz 1f
    call CloseHandle
1:  mov rcx, [rip + win_process_handle]
    test rcx, rcx
    jz 2f
    call CloseHandle
2:  mov rcx, [rip + win_thread_handle]
    test rcx, rcx
    jz 3f
    call CloseHandle
3:  mov eax, ebx
    WLEAVE

/* AL=byte, RBX=32767-byte output, R8=length. EAX=0/1; preserves all but RAX
 * and R8. Quotation never writes a byte after the command-line bound. */
win_command_byte:
    cmp r8, 32766
    jae 1f
    mov [rbx + r8], al
    inc r8
    xor eax, eax
    ret
1:  mov eax, 1
    ret

win_wide_command:
    WFRAME
    mov ecx, 65001
    mov edx, 8
    mov r8, rdi
    mov r9d, -1
    mov [rsp + 32], rsi
    mov rax, [rbp - 64]
    mov [rsp + 40], rax
    call MultiByteToWideChar
    WLEAVE
win_inherit_duplicate:
    WFRAME
    mov rcx, -1
    mov rdx, rdi
    mov r8, -1
    lea r9, [rbp - 128]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 1
    mov qword ptr [rsp + 48], 2
    call DuplicateHandle
    test eax, eax
    jz 1f
    mov rax, [rbp - 128]
    WLEAVE
1:  xor eax, eax
    WLEAVE
win_close_child_streams:
    WFRAME
    mov rcx, [rip + win_child_stdin]
    mov qword ptr [rip + win_child_stdin], 0
    test rcx, rcx
    jz 1f
    call CloseHandle
1:  mov rcx, [rip + win_child_stdout]
    mov qword ptr [rip + win_child_stdout], 0
    mov qword ptr [rip + win_pipe_write], 0
    test rcx, rcx
    jz 2f
    call CloseHandle
2:  mov rcx, [rip + win_child_stderr]
    mov qword ptr [rip + win_child_stderr], 0
    test rcx, rcx
    jz 3f
    call CloseHandle
3:  WLEAVE

/* RDI=explicit environment pointer array, <=512 entries <=4095 bytes each.
 * RAX=0/1. Output UTF16 block <=32767 units, with two final NULs. Only the
 * environment selected by the caller reaches verifier/transport children.
 */
win_explicit_environment:
    WFRAME
    mov r12, rdi
    lea r13, [rip + win_environment_wide]
    xor r14d, r14d
.Lwee_entry:
    cmp r14d, 512
    jae .Lwee_bad
    mov rdi, [r12 + r14*8]
    test rdi, rdi
    jz .Lwee_end
    mov rsi, r13
    lea rdx, [rip + win_environment_wide + 65532]
    sub rdx, r13
    shr rdx, 1
    call win_wide
    test rax, rax
    js .Lwee_bad
    lea r13, [r13 + rax*2]
    inc r14d
    jmp .Lwee_entry
.Lwee_end:
    mov dword ptr [r13], 0
    xor eax, eax
    WLEAVE
.Lwee_bad:
    mov eax, 1
    WLEAVE

/* Fixed tools inherit only Windows toolchain/location variables. Compiler
 * option variables, DLL redirection options, credentials, CA overrides,
 * HOME, Git and curl startup configuration are excluded. OS DLL loading uses
 * the fixed executable's installed directory and the Windows system search.
 * RAX=0/1. Environment output is the same bounded UTF16 block as above. */
win_build_environment:
    WFRAME
    lea r12, [rip + win_build_names]
    lea r13, [rip + win_environment_wide]
.Lwbe_name:
    mov rcx, [r12]
    test rcx, rcx
    jz .Lwbe_done
    mov r14, rcx
    mov rdi, rcx
.Lwbe_copy_name:
    mov ax, [rdi]
    test ax, ax
    jz .Lwbe_get
    mov [r13], ax
    add r13, 2
    add rdi, 2
    jmp .Lwbe_copy_name
.Lwbe_get:
    mov word ptr [r13], '='
    add r13, 2
    mov rcx, r14
    mov rdx, r13
    lea r8, [rip + win_environment_wide + 65532]
    sub r8, r13
    shr r8, 1
    cmp r8, 2
    jb .Lwbe_bad
    cmp r8, 4096
    cmova r8, qword ptr [rip + win_4096]
    mov r15, r8
    call GetEnvironmentVariableW
    test eax, eax
    jz .Lwbe_missing
    cmp rax, r15
    jae .Lwbe_bad
    lea r13, [r13 + rax*2 + 2]
    add r12, 8
    jmp .Lwbe_name
.Lwbe_missing:
    /* Roll back name plus '=' when the variable is absent. */
    sub r13, 2
.Lwbe_rollback:
    sub rdi, 2
    sub r13, 2
    cmp rdi, r14
    ja .Lwbe_rollback
    add r12, 8
    jmp .Lwbe_name
.Lwbe_done:
    mov dword ptr [r13], 0
    xor eax, eax
    WLEAVE
.Lwbe_bad:
    mov eax, 1
    WLEAVE

.section .data
.p2align 3
.p2align 2
win_pipe_security: .long 24,0
    .quad 0
    .long 1,0
.p2align 3
win_attribute_size: .quad 1024
.section .rdata,"dr"
.p2align 1
win_null_wide: .short 'N','U','L',0
.p2align 3
win_4096: .quad 4096
.p2align 3
win_build_names: .quad win_env_systemroot,win_env_windir,win_env_temp,win_env_tmp,win_env_lib,win_env_include,win_env_path,0
.p2align 1
win_env_systemroot: .short 'S','y','s','t','e','m','R','o','o','t',0
.p2align 1
win_env_windir: .short 'W','I','N','D','I','R',0
.p2align 1
win_env_temp: .short 'T','E','M','P',0
.p2align 1
win_env_tmp: .short 'T','M','P',0
.p2align 1
win_env_lib: .short 'L','I','B',0
.p2align 1
win_env_include: .short 'I','N','C','L','U','D','E',0
.p2align 1
win_env_path: .short 'P','A','T','H',0
.section .bss
.p2align 3
win_executable_wide: .space 8192
win_command_utf8: .space 32767
.p2align 1
win_command_wide: .space 65534
.p2align 4
win_environment_wide: .space 65536
win_child_environment: .space 8
.p2align 4
win_startup: .space 112
.p2align 4
win_attribute_list: .space 1024
win_inherited_handles: .space 24
win_process_info: .space 24
win_process_handle: .space 8
win_thread_handle: .space 8
win_pipe_read: .space 8
win_pipe_write: .space 8
win_child_stdin: .space 8
win_child_stdout: .space 8
win_child_stderr: .space 8
win_capture_length: .space 8

.text
/* RDI=regular path, RSI=exact expected bytes or -1, RDX=hex output[65].
 * RAX=0/1. SHA-256 uses BCrypt; all opened handles/providers/hashes close.
 * Reads have a 64 MiB cumulative bound and require the initial exact size.
 * No external program or ambient algorithm configuration selects the digest.
 */
win_hash_file:
    WFRAME
    mov r12, rsi
    mov r13, rdx
    mov qword ptr [rip + win_hash_provider], 0
    mov qword ptr [rip + win_hash_handle], 0
    mov qword ptr [rbp - 128], -1
    mov rsi, rdi
    mov rdi, -100
    xor edx, edx
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lwhf_bad
    mov [rbp - 128], rax
    mov rdi, rax
    lea rsi, [rip + win_hash_stat]
    mov eax, 5
    call win_syscall
    test rax, rax
    js .Lwhf_bad
    mov eax, [rip + win_hash_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lwhf_bad
    mov r14, [rip + win_hash_stat + 48]
    cmp r14, 67108864
    ja .Lwhf_bad
    cmp r12, -1
    je 1f
    cmp r12, r14
    jne .Lwhf_bad
1:  lea rcx, [rip + win_hash_provider]
    lea rdx, [rip + win_sha256_name]
    xor r8d, r8d
    xor r9d, r9d
    call BCryptOpenAlgorithmProvider
    test eax, eax
    js .Lwhf_bad
    mov rcx, [rip + win_hash_provider]
    lea rdx, [rip + win_object_length]
    lea r8, [rbp - 136]
    mov r9d, 4
    lea rax, [rbp - 144]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    call BCryptGetProperty
    test eax, eax
    js .Lwhf_bad
    cmp dword ptr [rbp - 136], 4096
    ja .Lwhf_bad
    mov rcx, [rip + win_hash_provider]
    lea rdx, [rip + win_hash_handle]
    lea r8, [rip + win_hash_object]
    mov r9d, [rbp - 136]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    call BCryptCreateHash
    test eax, eax
    js .Lwhf_bad
    xor r15d, r15d
.Lwhf_read:
    mov rdi, [rbp - 128]
    lea rsi, [rip + win_hash_buffer]
    mov edx, 65536
    xor eax, eax
    call win_syscall
    test rax, rax
    js .Lwhf_bad
    jz .Lwhf_finish
    add r15, rax
    cmp r15, r14
    ja .Lwhf_bad
    mov rcx, [rip + win_hash_handle]
    lea rdx, [rip + win_hash_buffer]
    mov r8d, eax
    xor r9d, r9d
    call BCryptHashData
    test eax, eax
    js .Lwhf_bad
    jmp .Lwhf_read
.Lwhf_finish:
    cmp r15, r14
    jne .Lwhf_bad
    mov rcx, [rip + win_hash_handle]
    lea rdx, [rip + win_hash_digest]
    mov r8d, 32
    xor r9d, r9d
    call BCryptFinishHash
    test eax, eax
    js .Lwhf_bad
    xor ecx, ecx
    lea rsi, [rip + win_hash_digest]
    lea rdi, [rip + registry_hex_digits]
.Lwhf_hex:
    movzx eax, byte ptr [rsi + rcx]
    mov edx, eax
    shr eax, 4
    and edx, 15
    mov al, [rdi + rax]
    mov dl, [rdi + rdx]
    mov [r13 + rcx*2], al
    mov [r13 + rcx*2 + 1], dl
    inc ecx
    cmp ecx, 32
    jb .Lwhf_hex
    mov byte ptr [r13 + 64], 0
    xor ebx, ebx
    jmp .Lwhf_cleanup
.Lwhf_bad:
    mov ebx, 1
.Lwhf_cleanup:
    mov rcx, [rip + win_hash_handle]
    test rcx, rcx
    jz 2f
    call BCryptDestroyHash
2:  mov rcx, [rip + win_hash_provider]
    test rcx, rcx
    jz 3f
    xor edx, edx
    call BCryptCloseAlgorithmProvider
3:  mov rdi, [rbp - 128]
    test rdi, rdi
    js 4f
    mov eax, 3
    call win_syscall
4:  mov eax, ebx
    WLEAVE

/* Native process capture adapts gzip's stream output to the existing bounded
 * assembly tar parser. Opens one regular source and passes its handle as
 * stdin. No archive member is extracted by gzip or by a shell. RAX=0/1. */
win_decompress:
    WFRAME
    mov rsi, [rip + arc_input_path]
    mov rdi, -100
    xor edx, edx
    xor r10d, r10d
    call win_open
    test rax, rax
    js .Lwdc_bad_unopened
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + arc_stat]
    mov eax, 5
    call win_syscall
    test rax, rax
    js .Lwdc_bad
    mov eax, [rip + arc_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lwdc_bad
    cmp qword ptr [rip + arc_stat + 48], 67108864
    ja .Lwdc_bad
    lea rdi, [rip + arc_gzip]
    lea rsi, [rip + arc_gzip_argv]
    lea rdx, [rip + arc_empty_env]
    lea r10, [rip + arc_data]
    mov r8d, 67108865
    mov r9, r12
    call win_process
    test eax, eax
    jnz .Lwdc_bad
    mov rax, [rip + win_capture_length]
    cmp rax, 67108864
    ja .Lwdc_bad
    mov [rip + arc_raw_size], rax
    xor ebx, ebx
    jmp .Lwdc_close
.Lwdc_bad:
    mov ebx, 1
.Lwdc_close:
    mov rdi, r12
    mov eax, 3
    call win_syscall
    mov eax, ebx
    WLEAVE
.Lwdc_bad_unopened:
    mov eax, 1
    WLEAVE

/* RDI=validated HTTPS URL, RSI=owned private output path, RDX=decimal bound.
 * curl receives fixed flags and an explicit environment without CA/config or
 * credentials. Its stdout is independently bounded by the parent. Only a
 * successful child and <=bound bytes create the exclusive destination.
 * RAX=0/127/child failure; no partial destination is retained after a failure.
 */
win_download:
    WFRAME
    mov r12, rsi
    mov [rip + registry_curl_argv + 21*8], rdi
    lea rax, [rip + win_stdout_dash]
    mov [rip + registry_curl_argv + 19*8], rax
    mov [rip + registry_curl_argv + 17*8], rdx
    mov rdi, rdx
    call registry_size_value
    test rax, rax
    jz .Lwdown_bad
    cmp rax, 67108864
    ja .Lwdown_bad
    mov r13, rax
    lea rdi, [rip + registry_curl]
    lea rsi, [rip + registry_curl_argv]
    lea rdx, [rip + arc_empty_env]
    lea r10, [rip + arc_data]
    lea r8, [r13 + 1]
    mov r9, -1
    call win_process
    test eax, eax
    jnz .Lwdown_return
    mov r14, [rip + win_capture_length]
    cmp r14, r13
    ja .Lwdown_bad
    mov rdi, -100
    mov rsi, r12
    mov edx, 193
    mov r10d, 384
    call win_open
    test rax, rax
    js .Lwdown_bad
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + arc_data]
    mov rdx, r14
    call write_all
    mov r14, rax
    mov rdi, r15
    mov eax, 3
    call win_syscall
    test rax, rax
    js .Lwdown_remove
    test r14, r14
    js .Lwdown_remove
    xor eax, eax
    jmp .Lwdown_return
.Lwdown_remove:
    mov rdi, r12
    mov eax, 87
    call win_syscall
.Lwdown_bad:
    mov eax, 127
.Lwdown_return:
    WLEAVE

.section .rdata,"dr"
win_stdout_dash: .asciz "-"
.p2align 1
win_sha256_name: .short 'S','H','A','2','5','6',0
.p2align 1
win_object_length: .short 'O','b','j','e','c','t','L','e','n','g','t','h',0
.section .bss
.p2align 3
win_hash_provider: .space 8
win_hash_handle: .space 8
win_hash_stat: .space 144
win_hash_object: .space 4096
win_hash_digest: .space 32
win_hash_buffer: .space 65536

.text
/* RDI=owned mutable absolute path[4096]. Convert C:\... and C:/... to the
 * shared /C:/... representation. Existing internal paths remain unchanged.
 * RAX=length or -EINVAL. Required capacity includes a possible prefix byte;
 * callers use only their owned 4096-byte destination buffers. No filesystem
 * change occurs. This function does not accept drive-relative or UNC paths.
 */
win_normalize_path:
    WFRAME
    mov r12, rdi
    xor ecx, ecx
.Lwnp_length:
    cmp ecx, 4094
    jae .Lwnp_bad
    cmp byte ptr [r12 + rcx], 0
    je .Lwnp_convert
    inc ecx
    jmp .Lwnp_length
.Lwnp_convert:
    cmp byte ptr [r12], '/'
    je .Lwnp_slashes
    cmp byte ptr [r12 + 1], ':'
    jne .Lwnp_bad
    cmp byte ptr [r12 + 2], '/'
    je .Lwnp_shift
    cmp byte ptr [r12 + 2], '\\'
    jne .Lwnp_bad
.Lwnp_shift:
    mov edx, ecx
.Lwnp_copy_back:
    mov al, [r12 + rdx]
    mov [r12 + rdx + 1], al
    dec rdx
    jns .Lwnp_copy_back
    mov byte ptr [r12], '/'
    inc ecx
.Lwnp_slashes:
    xor edx, edx
.Lwnp_slash_loop:
    mov al, [r12 + rdx]
    test al, al
    jz .Lwnp_ready
    cmp al, '\\'
    jne 1f
    mov byte ptr [r12 + rdx], '/'
1:  inc edx
    jmp .Lwnp_slash_loop
.Lwnp_ready:
    cmp byte ptr [r12 + 2], ':'
    jne .Lwnp_bad
    cmp byte ptr [r12 + 3], '/'
    jne .Lwnp_bad
    movzx eax, byte ptr [r12 + 1]
    or eax, 32
    cmp eax, 'a'
    jb .Lwnp_bad
    cmp eax, 'z'
    ja .Lwnp_bad
    mov rax, rcx
    WLEAVE
.Lwnp_bad:
    mov rax, -22
    WLEAVE

/* Compile the selected trusted-local source with a fixed LLVM driver. Shared
 * child_argv owns 64 pointer slots; this routine uses ten. RAX=child status.
 * Paths remain argv elements and never enter a shell command. */
/* RSI=borrowed output path, <=4093 bytes. Produces program_path[4096]
 * in the shared /C:/... form. Drive-absolute inputs are recognized before
 * considering cwd. Drive-relative, UNC and root-relative names fail before
 * any filesystem operation. Relative names are appended to the actual cwd.
 * RAX=length on success; malformed/oversize paths terminate through the
 * shared program_path_error. Preserves all internal callee-saved registers.
 * Stack: WFRAME plus bounded string and syscall callees. */
win_program_absolute_path:
    WFRAME
    mov r12, rsi
    mov rdi, rsi
    call strlen
    test rax, rax
    jz program_path_error
    cmp rax, 4093
    ja program_path_error
    mov r13, rax
    cmp byte ptr [r12], '\\'
    je program_path_error
    cmp byte ptr [r12], '/'
    je .Lwpa_internal
    cmp r13, 2
    jb .Lwpa_relative
    cmp byte ptr [r12 + 1], ':'
    jne .Lwpa_relative
    cmp r13, 3
    jb program_path_error
    cmp byte ptr [r12 + 2], '/'
    je .Lwpa_absolute
    cmp byte ptr [r12 + 2], '\\'
    jne program_path_error
    jmp .Lwpa_absolute
.Lwpa_internal:
    cmp r13, 4
    jb program_path_error
    cmp byte ptr [r12 + 2], ':'
    jne program_path_error
    cmp byte ptr [r12 + 3], '/'
    je .Lwpa_absolute
    cmp byte ptr [r12 + 3], '\\'
    jne program_path_error
.Lwpa_absolute:
    lea rdi, [rip + program_path]
    mov rsi, r12
    call copy_string
    jmp .Lwpa_normalize
.Lwpa_relative:
    lea rdi, [rip + program_cwd]
    mov esi, 4096
    mov eax, 79
    call win_syscall
    test rax, rax
    js program_path_error
    lea rdi, [rip + program_cwd]
    call strlen
    lea rdx, [rax + r13 + 1]
    cmp rdx, 4093
    ja program_path_error
    lea rdi, [rip + program_path]
    lea rsi, [rip + program_cwd]
    call copy_string
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, r12
    call copy_string
.Lwpa_normalize:
    lea rdi, [rip + program_path]
    call win_normalize_path
    test rax, rax
    js program_path_error
    WLEAVE

win_compile_project:
    WFRAME
    lea rbx, [rip + child_argv]
    lea rax, [rip + as_path]
    mov [rbx], rax
    lea rax, [rip + win_clang_no_config]
    mov [rbx + 8], rax
    lea rax, [rip + win_clang_target]
    mov [rbx + 16], rax
    lea rax, [rip + as_64]
    mov [rbx + 24], rax
    lea rax, [rip + arg_I]
    mov [rbx + 32], rax
    lea rax, [rip + dependency_packages_root]
    mov [rbx + 40], rax
    lea rax, [rip + arg_o]
    mov [rbx + 48], rax
    lea rax, [rip + stage_object]
    mov [rbx + 56], rax
    lea rax, [rip + package_source]
    cmp byte ptr [rip + test_mode], 0
    je 1f
    lea rax, [rip + package_test]
1:  mov [rbx + 64], rax
    mov qword ptr [rbx + 72], 0
    lea rdi, [rip + as_path]
    mov rsi, rbx
    call spawn_wait
    WLEAVE

/* Standalone links use the Windows system ABI, explicit _start and NX.
 * LLVM receives kernel32.lib from the installed SDK. No C runtime is linked.
 * RAX=child status. Capacity: child_argv[64], eleven pointers used. */
win_link_standalone:
    WFRAME
    lea rbx, [rip + child_argv]
    lea rax, [rip + ld_path]
    mov [rbx], rax
    lea rax, [rip + win_clang_no_config]
    mov [rbx + 8], rax
    lea rax, [rip + win_clang_target]
    mov [rbx + 16], rax
    lea rax, [rip + win_lld_flag]
    mov [rbx + 24], rax
    lea rax, [rip + arg_z]
    mov [rbx + 32], rax
    lea rax, [rip + noexecstack]
    mov [rbx + 40], rax
    lea rax, [rip + arg_o]
    mov [rbx + 48], rax
    lea rax, [rip + stage_binary]
    mov [rbx + 56], rax
    lea rax, [rip + stage_object]
    mov [rbx + 64], rax
    lea rax, [rip + win_kernel32_lib]
    mov [rbx + 72], rax
    mov qword ptr [rbx + 80], 0
    lea rdi, [rip + ld_path]
    mov rsi, rbx
    call spawn_wait
    WLEAVE

.section .rdata,"dr"
win_clang_no_config: .asciz "--no-default-config"
win_clang_target: .asciz "--target=x86_64-pc-windows-msvc"
win_lld_flag: .asciz "-fuse-ld=lld"

.text
/* RDI=UTF16 component, RDX=even byte length 2..510. EAX=1/0; scratch
 * RAX/RCX/R8/R9. Refuses ADS, separators, controls, trailing dot/space,
 * traversal and reserved DOS device basenames, including extension aliases.
 */
win_component_safe:
    cmp rdx, 2
    jb .Lwcs_bad
    cmp rdx, 510
    ja .Lwcs_bad
    test dl, 1
    jnz .Lwcs_bad
    cmp word ptr [rdi + rdx - 2], '.'
    je .Lwcs_bad
    cmp word ptr [rdi + rdx - 2], ' '
    je .Lwcs_bad
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
.Lwcs_character:
    cmp rcx, rdx
    jae .Lwcs_devices
    movzx eax, word ptr [rdi + rcx]
    cmp eax, 32
    jb .Lwcs_bad
    cmp eax, '/'
    je .Lwcs_bad
    cmp eax, '\\'
    je .Lwcs_bad
    cmp eax, ':'
    je .Lwcs_bad
    cmp eax, '"'
    je .Lwcs_bad
    cmp eax, '*'
    je .Lwcs_bad
    cmp eax, '?'
    je .Lwcs_bad
    cmp eax, '|'
    je .Lwcs_bad
    cmp eax, '<'
    je .Lwcs_bad
    cmp eax, '>'
    je .Lwcs_bad
    cmp eax, '.'
    je .Lwcs_dot
    test r9d, r9d
    jnz .Lwcs_next
    inc r8d
    jmp .Lwcs_next
.Lwcs_dot:
    mov r9d, 1
.Lwcs_next:
    add ecx, 2
    jmp .Lwcs_character
.Lwcs_devices:
    cmp r8d, 3
    je .Lwcs_three
    cmp r8d, 4
    je .Lwcs_four
.Lwcs_good:
    mov eax, 1
    ret
.Lwcs_three:
    movzx eax, word ptr [rdi]
    or eax, 32
    cmp eax, 'c'
    je .Lwcs_con
    cmp eax, 'p'
    je .Lwcs_prn
    cmp eax, 'a'
    je .Lwcs_aux
    cmp eax, 'n'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 2]
    or eax, 32
    cmp eax, 'u'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 4]
    or eax, 32
    cmp eax, 'l'
    je .Lwcs_bad
    jmp .Lwcs_good
.Lwcs_con:
    movzx eax, word ptr [rdi + 2]
    or eax, 32
    cmp eax, 'o'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 4]
    or eax, 32
    cmp eax, 'n'
    je .Lwcs_bad
    jmp .Lwcs_good
.Lwcs_prn:
    movzx eax, word ptr [rdi + 2]
    or eax, 32
    cmp eax, 'r'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 4]
    or eax, 32
    cmp eax, 'n'
    je .Lwcs_bad
    jmp .Lwcs_good
.Lwcs_aux:
    movzx eax, word ptr [rdi + 2]
    or eax, 32
    cmp eax, 'u'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 4]
    or eax, 32
    cmp eax, 'x'
    je .Lwcs_bad
    jmp .Lwcs_good
.Lwcs_four:
    movzx eax, word ptr [rdi + 6]
    cmp eax, 0xb9 /* Windows also recognizes superscript1/2/3 devices */
    je .Lwcs_device_digit
    cmp eax, 0xb2
    je .Lwcs_device_digit
    cmp eax, 0xb3
    je .Lwcs_device_digit
    cmp eax, '1'
    jb .Lwcs_good
    cmp eax, '9'
    ja .Lwcs_good
.Lwcs_device_digit:
    movzx eax, word ptr [rdi]
    or eax, 32
    cmp eax, 'c'
    je .Lwcs_com
    cmp eax, 'l'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 2]
    or eax, 32
    cmp eax, 'p'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 4]
    or eax, 32
    cmp eax, 't'
    je .Lwcs_bad
    jmp .Lwcs_good
.Lwcs_com:
    movzx eax, word ptr [rdi + 2]
    or eax, 32
    cmp eax, 'o'
    jne .Lwcs_good
    movzx eax, word ptr [rdi + 4]
    or eax, 32
    cmp eax, 'm'
    je .Lwcs_bad
    jmp .Lwcs_good
.Lwcs_bad:
    xor eax, eax
    ret

.text
/* Normalize the four privately constructed verifier path values from /C:/...
 * to native C:/... and add Windows user/cache locations. All six values refer
 * to the same newly created verifier directory; no ambient profile is copied.
 * RAX=0/-EINVAL. The caller's four 8192-byte buffers own the original strings;
 * the two Windows strings have separate 8192-byte buffers. Prefix lengths are
 * fixed by the shared HOME/GH_CONFIG_DIR/XDG constants. No filesystem mutation.
 * Stack: WFRAME plus copy_string; preserves internal callee-saved registers. */
win_prepare_verifier_environment:
    WFRAME
    lea r12, [rip + win_verifier_path_values]
    mov r13d, 4
.Lwvpe_value:
    mov rdi, [r12]
    cmp byte ptr [rdi], '/'
    jne .Lwvpe_bad
    movzx eax, byte ptr [rdi + 1]
    or eax, 32
    cmp eax, 'a'
    jb .Lwvpe_bad
    cmp eax, 'z'
    ja .Lwvpe_bad
    cmp byte ptr [rdi + 2], ':'
    jne .Lwvpe_bad
    cmp byte ptr [rdi + 3], '/'
    jne .Lwvpe_bad
    xor ecx, ecx
.Lwvpe_bound:
    cmp ecx, 8170
    jae .Lwvpe_bad
    cmp byte ptr [rdi + rcx], 0
    je .Lwvpe_strip
    inc ecx
    jmp .Lwvpe_bound
.Lwvpe_strip:
    xor ecx, ecx
.Lwvpe_copy_left:
    mov al, [rdi + rcx + 1]
    mov [rdi + rcx], al
    inc ecx
    test al, al
    jnz .Lwvpe_copy_left
    add r12, 8
    dec r13d
    jnz .Lwvpe_value
    lea rdi, [rip + win_profile_environment]
    lea rsi, [rip + win_profile_prefix]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_home_environment + 5]
    call copy_string
    lea rdi, [rip + win_localappdata_environment]
    lea rsi, [rip + win_localappdata_prefix]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_home_environment + 5]
    call copy_string
    xor eax, eax
    WLEAVE
.Lwvpe_bad:
    mov rax, -22
    WLEAVE
.section .rdata,"dr"
.p2align 3
win_verifier_path_values:
    .quad self_home_environment + 5, self_config_environment + 14
    .quad self_cache_environment + 15, self_xdg_environment + 16
win_profile_prefix: .asciz "USERPROFILE="
win_localappdata_prefix: .asciz "LOCALAPPDATA="
.section .bss
.p2align 3
win_profile_environment: .space 8192
win_localappdata_environment: .space 8192

.text
/* RDI=source path bounded to255 UTF8 bytes. EAX=1 valid/0 invalid.
 * The shared syntax gate remains authoritative for option/response aliases.
 * Then reject Windows ADS, device names, separators and trailing aliases per
 * component before compiler invocation. Borrows win_path_wide[4096 units].
 * WFRAME preserves input registers and internal callee-saved registers. */
win_valid_source:
    WFRAME
    call win_shared_valid_source
    test eax, eax
    jz .Lwvs_bad
    lea rsi, [rip + win_path_wide]
    mov edx, 4096
    call win_wide
    test rax, rax
    js .Lwvs_bad
    lea r12, [rip + win_path_wide]
    mov r13, r12
.Lwvs_scan:
    movzx eax, word ptr [r13]
    test eax, eax
    jz .Lwvs_component
    cmp eax, '/'
    je .Lwvs_component
    add r13, 2
    jmp .Lwvs_scan
.Lwvs_component:
    mov rdi, r12
    mov rdx, r13
    sub rdx, r12
    call win_component_safe
    test eax, eax
    jz .Lwvs_bad
    cmp word ptr [r13], 0
    je .Lwvs_good
    lea r12, [r13 + 2]
    mov r13, r12
    jmp .Lwvs_scan
.Lwvs_bad:
    xor eax, eax
    WLEAVE
.Lwvs_good:
    mov eax, 1
    WLEAVE

.text
/* RDI=held image file HANDLE opened with FILE_EXECUTE|SYNCHRONIZE.
 * RAX=0 exact image, -ESTALE mismatch, -EOPNOTSUPP unsupported. WFRAME preserves inputs.
 * Runtime-resolved internal Windows class 44 accepts an INPUT HANDLE pointer
 * of 8 bytes, not an output filename. Only STATUS_SUCCESS(0) qualifies.
 * Missing/unsupported APIs, warning statuses and mismatches fail closed.
 * Qualified assumption: native Windows Server 2025 observed original 0 and
 * byte-identical replacement C0000001. This is not a portable Win32 promise.
 */
win_image_matches:
    WFRAME
    mov r12, rdi
    lea rcx, [rip + win_ntdll_name]
    call GetModuleHandleW
    test rax, rax
    jz .Lwim_unsupported
    mov rcx, rax
    lea rdx, [rip + win_image_query_name]
    call GetProcAddress
    test rax, rax
    jz .Lwim_unsupported
    mov r11, rax
    mov [rbp - 128], r12
    mov rcx, -1
    mov edx, 44 /* ProcessImageFileMapping */
    lea r8, [rbp - 128]
    mov r9d, 8
    mov qword ptr [rsp + 32], 0
    call r11
    test eax, eax
    jz .Lwim_match
    cmp eax, 0xc0000001 /* observed image-file mismatch */
    jne .Lwim_unsupported
    mov rax, -116 /* internal ESTALE identity marker */
    WLEAVE
.Lwim_match:
    xor eax, eax
    WLEAVE
.Lwim_unsupported:
    mov rax, -95
    WLEAVE
.section .rdata,"dr"
.p2align 1
win_ntdll_name: .short 'n','t','d','l','l','.','d','l','l',0
win_image_query_name: .asciz "NtQueryInformationProcess"
.text
/* RDI=terminated path. RAX=borrowed native display pointer. Strip only the
 * internal /C:/ drive marker, leaving all other bytes and receipt storage
 * untouched. No calls, writes or stack. Scratch:RAX/RCX. */
win_display_path:
    mov rax, rdi
    cmp byte ptr [rdi], '/'
    jne .Lwdisplay_done
    movzx ecx, byte ptr [rdi + 1]
    or ecx, 32
    cmp ecx, 'a'
    jb .Lwdisplay_done
    cmp ecx, 'z'
    ja .Lwdisplay_done
    cmp byte ptr [rdi + 2], ':'
    jne .Lwdisplay_done
    cmp byte ptr [rdi + 3], '/'
    jne .Lwdisplay_done
    inc rax
.Lwdisplay_done:
    ret
win_json_path:
    call win_display_path
    mov rdi, rax
    jmp registry_json_string
win_out_path:
    call win_display_path
    mov rdi, rax
    jmp out

.text
win_self_image_changed:
    lea rdi, [rip + win_error_image_changed]
    mov esi, 1
    jmp self_fail
win_self_identity_unsupported:
    lea rdi, [rip + win_error_identity_unsupported]
    mov esi, 1
    jmp self_fail
.section .rdata,"dr"
win_error_image_changed: .asciz "the running executable differs from the installed file; no replacement was made; start the installed command again"
win_error_identity_unsupported: .asciz "this Windows host cannot verify the running image identity; no replacement was made; install the verified release manually"
