/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Intel Darwin adapters. Input RAX=private Linux-shaped syscall number;
 * RDI/RSI/RDX/R10/R8/R9=args. Output RAX=result or negative contract errno.
 * Preserve all other registers except RCX/R11 and flags, as Linux SYSCALL does.
 * Every libSystem call uses a 16-byte-aligned stack. No SSE/AVX is required.
 * Private stat output is 144 bytes in the shared x86-64 layout.
 * Frame scratch: 2304 bytes; no buffers escape the call. FD streams are bounded.
 */
.intel_syntax noprefix
.text
.macro MAC_FRAME
    push rbp
    mov rbp, rsp
    sub rsp, 128
    mov [rbp - 8], rbx
    mov [rbp - 16], r12
    mov [rbp - 24], r13
    mov [rbp - 32], r14
    mov [rbp - 40], r15
    mov [rbp - 48], rdi
    mov [rbp - 56], rsi
    mov [rbp - 64], rdx
    mov [rbp - 72], r10
    mov [rbp - 80], r8
    mov [rbp - 88], r9
    and rsp, -16
    sub rsp, 2304
.endm
mac_syscall:
    MAC_FRAME
    lea r11, [rip + mac_syscall_table]
.Lmac_dispatch:
    cmp dword ptr [r11], -1
    je .Lmac_unsupported
    cmp eax, dword ptr [r11]
    je .Lmac_dispatch_found
    add r11, 16
    jmp .Lmac_dispatch
.Lmac_dispatch_found:
    mov rcx, r10
    jmp qword ptr [r11 + 8]
.Lmac_unsupported:
    mov rax, -38
    jmp mac_return
mac_result:
    cmp eax, -1
    jne mac_return
mac_errno:
    call ___error
    mov eax, [rax]
    cmp eax, 35
    jne 1f
    mov eax, 11
1:  cmp eax, 66
    jne 2f
    mov eax, 39
2:  cmp eax, 62
    jne 3f
    mov eax, 40
3:  cmp eax, 78
    jne 4f
    mov eax, 38
4:  neg rax
mac_return:
    mov rbx, [rbp - 8]
    mov r12, [rbp - 16]
    mov r13, [rbp - 24]
    mov r14, [rbp - 32]
    mov r15, [rbp - 40]
    mov rdi, [rbp - 48]
    mov rsi, [rbp - 56]
    mov rdx, [rbp - 64]
    mov r10, [rbp - 72]
    mov r8, [rbp - 80]
    mov r9, [rbp - 88]
    mov rsp, rbp
    pop rbp
    ret
.macro MAC_SIMPLE name, function
\name:
    call _\function
    jmp mac_result
.endm
/* ssize_t and off_t use all 64 result bits; int APIs above use EAX. */
.macro MAC_WIDE name, function
\name:
    call _\function
    cmp rax, -1
    je mac_errno
    jmp mac_return
.endm
MAC_WIDE mac_read, read
MAC_WIDE mac_write, write
MAC_WIDE mac_lseek, lseek
MAC_SIMPLE mac_access, access
MAC_SIMPLE mac_mkdir, mkdir
MAC_SIMPLE mac_unlink, unlink
MAC_SIMPLE mac_rmdir, rmdir
MAC_SIMPLE mac_rename, rename
MAC_SIMPLE mac_chmod, chmod
MAC_SIMPLE mac_fchmod, fchmod
MAC_SIMPLE mac_fsync, fsync
MAC_SIMPLE mac_flock, flock
MAC_SIMPLE mac_kill, kill
MAC_SIMPLE mac_wait4, wait4
MAC_SIMPLE mac_getpid, getpid
MAC_SIMPLE mac_chdir, chdir
MAC_SIMPLE mac_fchdir, fchdir
MAC_SIMPLE mac_getuid, getuid
MAC_SIMPLE mac_geteuid, geteuid
MAC_SIMPLE mac_getgid, getgid
MAC_SIMPLE mac_getegid, getegid
MAC_SIMPLE mac_umask, umask
MAC_SIMPLE mac_fork, fork
MAC_SIMPLE mac_dup2, dup2
MAC_SIMPLE mac_alarm, alarm
MAC_SIMPLE mac_getrlimit, getrlimit
MAC_SIMPLE mac_setrlimit, setrlimit
mac_exit:
    call _exit
    ud2
mac_execve:
    lea rax, [rip + registry_sha256sum]
    cmp rdi, rax
    jne 1f
    lea rdx, [rip + mac_empty_environment]
1:  call _execve
    jmp mac_result
mac_getcwd:
    call _getcwd
    test rax, rax
    jz mac_errno
    mov rdi, rax
    call _strlen
    inc rax
    jmp mac_return
/* RSI=contract open flags -> RSI=native flags. Other argument registers intact. */
mac_flags:
    mov eax, esi
    and eax, 3
    test esi, 64
    jz 1f
    or eax, 512
1:  test esi, 128
    jz 2f
    or eax, 2048
2:  test esi, 512
    jz 3f
    or eax, 1024
3:  test esi, 1024
    jz 4f
    or eax, 8
4:  test esi, O_NOFOLLOW
    jz 5f
    or eax, 256
5:  test esi, O_DIRECTORY
    jz 6f
    or eax, 0x100000
6:  test esi, O_CLOEXEC
    jz 7f
    or eax, 0x1000000
7:  test esi, O_NONBLOCK
    jz 8f
    or eax, 4
8:  mov esi, eax
    ret
mac_open:
    call mac_flags
    xor eax, eax /* variadic vector argument count */
    call _open
    jmp mac_result
mac_openat:
    mov r12, rsi
    mov rsi, rdx
    call mac_flags
    mov rdx, rsi
    mov rsi, r12
    mov rcx, [rbp - 72]
    cmp edi, -100
    jne 1f
    mov edi, -2
1:  xor eax, eax
    call _openat
    jmp mac_result
mac_mkdirat:
    cmp edi, -100
    jne 1f
    mov edi, -2
1:  call _mkdirat
    jmp mac_result
mac_unlinkat:
    cmp edi, -100
    jne 1f
    mov edi, -2
1:  cmp edx, 512
    mov edx, 0
    jne 2f
    mov edx, 128
2:  call _unlinkat
    jmp mac_result
mac_renameat2:
    cmp r8d, 1
    jne .Lmac_invalid
    mov r8d, 4 /* RENAME_EXCL */
    jmp .Lmac_renameat_common
mac_renameat:
    xor r8d, r8d
.Lmac_renameat_common:
    cmp edi, -100
    jne 1f
    mov edi, -2
1:  cmp edx, -100
    jne 2f
    mov edx, -2
2:  call _renameatx_np
    jmp mac_result
.Lmac_invalid:
    mov rax, -22
    jmp mac_return
/* Native ACLs: only empty or deny-only ACLs authorize protected files.
 * RDI owns an ACL or NULL. EAX=1 safe, 0 on allow entry/error. Always frees.
 * This helper has a separate aligned frame and preserves RBX/R12/R13.
 */
mac_acl_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 32
    mov rbx, rdi
    test rbx, rbx
    jz .Lmac_acl_missing
    call _acl_valid
    test eax, eax
    jnz .Lmac_acl_bad
    xor r12d, r12d
.Lmac_acl_loop:
    mov rdi, rbx
    mov esi, r12d
    lea rdx, [rsp]
    call _acl_get_entry
    test eax, eax
    jnz .Lmac_acl_end
    cmp r12d, 169
    jae .Lmac_acl_bad
    mov rdi, [rsp]
    lea rsi, [rsp + 8]
    call _acl_get_tag_type
    test eax, eax
    jnz .Lmac_acl_bad
    cmp dword ptr [rsp + 8], 2
    jne .Lmac_acl_bad
    inc r12d
    jmp .Lmac_acl_loop
.Lmac_acl_end:
    call ___error
    cmp dword ptr [rax], 22
    jne .Lmac_acl_bad
    mov rdi, rbx
    call _acl_free
    mov eax, 1
    jmp .Lmac_acl_return
.Lmac_acl_missing:
    call ___error
    cmp dword ptr [rax], 2
    sete al
    movzx eax, al
    jmp .Lmac_acl_return
.Lmac_acl_bad:
    mov rdi, rbx
    call _acl_free
    xor eax, eax
.Lmac_acl_return:
    add rsp, 32
    pop r12
    pop rbx
    pop rbp
    ret
mac_fstat:
    mov esi, 256
    call _acl_get_fd_np
    mov rdi, rax
    call mac_acl_safe
    test eax, eax
    jz .Lmac_acl_fail
mac_probe_fd_stat:
    mov rdi, [rbp - 48]
    mov rsi, rsp
    call _fstat$INODE64
    mov r12, [rbp - 56]
    jmp .Lmac_stat_result
mac_lstat:
    mov esi, 256
    call _acl_get_link_np
    mov rdi, rax
    call mac_acl_safe
    test eax, eax
    jz .Lmac_acl_fail
    mov rdi, [rbp - 48]
    mov rsi, rsp
    call _lstat$INODE64
    mov r12, [rbp - 56]
    jmp .Lmac_stat_result
mac_newfstatat:
    cmp edi, -100
    jne 1f
    mov edi, -2
1:  mov edx, 0x1000104 /* nofollow + nonblock + cloexec */
    xor ecx, ecx
    xor eax, eax
    call _openat
    cmp eax, -1
    je mac_errno
    mov r12, rax
    mov rdi, rax
    mov esi, 256
    call _acl_get_fd_np
    mov rdi, rax
    call mac_acl_safe
    mov r13d, eax
    mov rdi, r12
    call _close
    test r13d, r13d
    jz .Lmac_acl_fail
mac_probe_stat:
    mov rdi, [rbp - 48]
    mov rsi, [rbp - 56]
    cmp edi, -100
    jne 2f
    mov edi, -2
2:  mov rcx, [rbp - 72]
    cmp ecx, 256
    mov ecx, 0
    jne 3f
    mov ecx, 32
3:  mov rdx, rsp
    call _fstatat$INODE64
    mov r12, [rbp - 64]
.Lmac_stat_result:
    cmp eax, -1
    je mac_errno
    mov rdi, r12
    mov ecx, 18
    xor eax, eax
    rep stosq
    mov eax, [rsp]
    mov [r12], rax
    mov rax, [rsp + 8]
    mov [r12 + 8], rax
    movzx eax, word ptr [rsp + 6]
    mov [r12 + 16], rax
    movzx eax, word ptr [rsp + 4]
    mov [r12 + 24], eax
    mov rax, [rsp + 16]
    mov [r12 + 28], rax
    mov rax, [rsp + 96]
    mov [r12 + 48], rax
    xor eax, eax
    jmp mac_return
.Lmac_acl_fail:
    mov rax, -13
    jmp mac_return
mac_fcntl:
    cmp esi, 1030
    jne 1f
    mov esi, 67
1:  xor eax, eax
    call _fcntl
    jmp mac_result
mac_pipe2:
    call _pipe
    cmp eax, -1
    je mac_errno
    mov r12, [rbp - 48]
    mov edi, [r12]
    mov esi, 2
    mov edx, 1
    xor eax, eax
    call _fcntl
    cmp eax, -1
    je .Lmac_pipe_bad
    mov edi, [r12 + 4]
    mov esi, 2
    mov edx, 1
    xor eax, eax
    call _fcntl
    cmp eax, -1
    jne mac_return
.Lmac_pipe_bad:
    mov edi, [r12]
    call _close
    mov edi, [r12 + 4]
    call _close
    mov rax, -5
    jmp mac_return
mac_getrandom:
    cmp rsi, 256
    ja .Lmac_invalid
    call _getentropy
    cmp eax, -1
    je mac_errno
    mov rax, [rbp - 56]
    jmp mac_return
mac_sigaction:
    cmp edi, 14
    jne .Lmac_invalid
    xor esi, esi
    call _signal
    jmp mac_result
mac_sigprocmask:
    cmp edi, 1
    jne .Lmac_invalid
    mov edi, 2
    call _sigprocmask
    jmp mac_result
mac_readlink:
    call _getpid
    mov edi, eax
    mov rsi, [rbp - 56]
    mov rdx, [rbp - 64]
    call _proc_pidpath
    test eax, eax
    jnz mac_return
    mov rax, -5
    jmp mac_return
mac_fstatfs:
    mov rsi, rsp
    call _fstatfs$INODE64
    cmp eax, -1
    je mac_errno
    mov eax, [rsp + 64]
    test eax, 0x1000 /* MNT_LOCAL */
    jz .Lmac_fs_bad
    test eax, 0x200000 /* MNT_IGNORE_OWNERSHIP */
    jnz .Lmac_fs_bad
    cmp dword ptr [rsp + 72], 0x73667061
    jne .Lmac_fs_bad
    cmp byte ptr [rsp + 76], 0
    jne .Lmac_fs_bad
    mov rdi, [rbp - 56]
    mov dword ptr [rdi], 0x41504653
    xor eax, eax
    jmp mac_return
.Lmac_fs_bad:
    mov rax, -95
    jmp mac_return
mac_getdents64:
    cmp rdi, 1024
    jae .Lmac_fd_bad
    lea r12, [rip + mac_directory_streams]
    lea r12, [r12 + rdi*8]
    mov rdi, [r12]
    test rdi, rdi
    jnz .Lmac_readdir
    mov rdi, [rbp - 48]
    call _dup
    cmp eax, -1
    je mac_errno
    mov r13, rax
    mov rdi, rax
    call _fdopendir$INODE64
    test rax, rax
    jz .Lmac_fdopendir_bad
    mov [r12], rax
.Lmac_readdir:
    call ___error
    mov dword ptr [rax], 0
    mov rdi, [r12]
    call _readdir$INODE64
    test rax, rax
    jnz .Lmac_dirent
    call ___error
    cmp dword ptr [rax], 0
    jne mac_errno
    xor eax, eax
    jmp mac_return
.Lmac_dirent:
    movzx ecx, word ptr [rax + 18]
    cmp ecx, 1023
    ja .Lmac_fd_bad
    lea r13, [rcx + 27]
    and r13, -8
    cmp r13, [rbp - 64]
    ja .Lmac_fd_bad
    mov rdi, [rbp - 56]
    mov rdx, [rax]
    mov [rdi], rdx
    mov qword ptr [rdi + 8], 0
    mov [rdi + 16], r13w
    mov dl, [rax + 20]
    mov [rdi + 18], dl
    lea rsi, [rax + 21]
    add rdi, 19
    inc ecx
    rep movsb
    mov rax, r13
    jmp mac_return
.Lmac_fdopendir_bad:
    mov rdi, r13
    call _close
    mov rax, -5
    jmp mac_return
.Lmac_fd_bad:
    mov rax, -24
    jmp mac_return
mac_close:
    cmp rdi, 1024
    jae 1f
    lea r12, [rip + mac_directory_streams]
    lea r12, [r12 + rdi*8]
    mov rdi, [r12]
    test rdi, rdi
    jz 1f
    mov qword ptr [r12], 0
    call _closedir
1:  mov rdi, [rbp - 48]
    call _close
    jmp mac_result
/* RDI=resolved executable path. Bind its held FD to kernel text-region vnode.
 * Returns FD or negative error. No pathname-only authorization. */
mac_open_running_image:
    MAC_FRAME
    call _getpid
    mov edi, eax
    mov esi, 8 /* PROC_PIDREGIONPATHINFO */
    lea rdx, [rip + _main]
    mov rcx, rsp
    mov r8d, 1272
    call _proc_pidinfo
    cmp eax, 1272
    jne .Lmac_image_bad
    mov rdi, [rbp - 48]
    mov esi, 0x1000104
    xor edx, edx
    xor eax, eax
    call _open
    cmp eax, -1
    je mac_errno
    mov r12, rax
    mov rdi, rax
    mov esi, 256
    call _acl_get_fd_np
    mov rdi, rax
    call mac_acl_safe
    test eax, eax
    jz .Lmac_image_acl_bad
    mov rdi, r12
    lea rsi, [rsp + 1280]
    call _fstat$INODE64
    cmp eax, -1
    je .Lmac_image_close_bad
    mov eax, [rsp + 96]
    cmp eax, [rsp + 1280]
    jne .Lmac_image_close_bad
    mov rax, [rsp + 104]
    cmp rax, [rsp + 1288]
    jne .Lmac_image_close_bad
    mov rax, r12
    jmp mac_return
.Lmac_image_acl_bad:
    mov rdi, r12
    call _close
    mov rax, -13
    jmp mac_return
.Lmac_image_close_bad:
    mov rdi, r12
    call _close
.Lmac_image_bad:
    mov rax, -1
    jmp mac_return
/* Force architecture/deployment for universal clang, while preserving argument
 * strings as direct argv. The original assembler argv has eight bounded slots.
 * Input RDI=clang, RSI=argv. Output spawn_wait status; SysV preserved registers.
 */
mac_assemble_wait:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + mac_assembler_argv]
    xor ecx, ecx
1:  mov rax, [r12 + rcx*8]
    mov [r13 + rcx*8], rax
    inc ecx
    cmp ecx, 7
    jb 1b
    lea rax, [rip + mac_arch_option]
    mov [r13 + 56], rax
    lea rax, [rip + mac_arch_value]
    mov [r13 + 64], rax
    lea rax, [rip + mac_deployment_option]
    mov [r13 + 72], rax
    mov qword ptr [r13 + 80], 0
    mov rdi, rbx
    mov rsi, r13
    call spawn_wait
    pop r13
    pop r12
    pop rbx
    ret
/* The standalone linker argv has seven slots. Preserve them, append the
 * deployment floor and signature request, then let spawn_wait run clang. */
mac_link_wait:
    lea rax, [rip + mac_deployment_option]
    mov [rsi + 48], rax
    lea rax, [rip + mac_sign_option]
    mov [rsi + 56], rax
    mov qword ptr [rsi + 64], 0
    jmp spawn_wait
/* Native-library argv has 64 slots, with at most 40 used by the shared code.
 * Append the explicit ISA and minimum OS for compile-only checks and links. */
mac_cc_wait:
    xor ecx, ecx
1:  cmp qword ptr [rsi + rcx*8], 0
    je 2f
    inc ecx
    cmp ecx, 59
    jb 1b
    mov eax, 127
    ret
2:  lea rax, [rip + mac_arch_option]
    mov [rsi + rcx*8], rax
    lea rax, [rip + mac_arch_value]
    mov [rsi + rcx*8 + 8], rax
    lea rax, [rip + mac_deployment_option]
    mov [rsi + rcx*8 + 16], rax
    mov qword ptr [rsi + rcx*8 + 24], 0
    jmp spawn_wait
.data
mac_empty_environment: .quad 0
mac_sha256_option: .asciz "-a256"
mac_arch_option: .asciz "-arch"
mac_arch_value: .asciz "x86_64"
mac_sign_option: .asciz "-Wl,-adhoc_codesign"
mac_deployment_option: .asciz "-mmacosx-version-min=15.0"
.zerofill __DATA,__bss,mac_assembler_argv,88,3
.zerofill __DATA,__bss,mac_directory_streams,8192,3
.p2align 3
mac_syscall_table:
    .quad 0, mac_read
    .quad 1, mac_write
    .quad 2, mac_open
    .quad 3, mac_close
    .quad 5, mac_fstat
    .quad 6, mac_lstat
    .quad 8, mac_lseek
    .quad 13, mac_sigaction
    .quad 14, mac_sigprocmask
    .quad 21, mac_access
    .quad 32, mac_dup
    .quad 33, mac_dup2
    .quad 37, mac_alarm
    .quad 39, mac_getpid
    .quad 57, mac_fork
    .quad 59, mac_execve
    .quad 60, mac_exit
    .quad 61, mac_wait4
    .quad 62, mac_kill
    .quad 72, mac_fcntl
    .quad 73, mac_flock
    .quad 74, mac_fsync
    .quad 79, mac_getcwd
    .quad 80, mac_chdir
    .quad 81, mac_fchdir
    .quad 82, mac_rename
    .quad 83, mac_mkdir
    .quad 84, mac_rmdir
    .quad 87, mac_unlink
    .quad 89, mac_readlink
    .quad 90, mac_chmod
    .quad 91, mac_fchmod
    .quad 95, mac_umask
    .quad 97, mac_getrlimit
    .quad 102, mac_getuid
    .quad 104, mac_getgid
    .quad 107, mac_geteuid
    .quad 108, mac_getegid
    .quad 138, mac_fstatfs
    .quad 160, mac_setrlimit
    .quad 217, mac_getdents64
    .quad 257, mac_openat
    .quad 258, mac_mkdirat
    .quad 262, mac_newfstatat
    .quad 263, mac_unlinkat
    .quad 264, mac_renameat
    .quad 293, mac_pipe2
    .quad 316, mac_renameat2
    .quad 318, mac_getrandom
    .quad 1005, mac_probe_fd_stat
    .quad 1262, mac_probe_stat
    .quad -1, 0
.text
MAC_SIMPLE mac_dup, dup
