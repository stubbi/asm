.intel_syntax noprefix
.global _start

/* asm's CLI is native x86-64 assembly. No C runtime or shell is involved.
 * Calls use the System V register convention; Linux syscalls use r10 for arg4.
 */
.equ SYS_read, 0
.equ SYS_write, 1
.equ SYS_open, 2
.equ SYS_close, 3
.equ SYS_fstat, 5
.equ SYS_lstat, 6
.equ SYS_access, 21
.equ SYS_getpid, 39
.equ SYS_fork, 57
.equ SYS_execve, 59
.equ SYS_exit, 60
.equ SYS_wait4, 61
.equ SYS_uname, 63
.equ SYS_chdir, 80
.equ SYS_fchdir, 81
.equ SYS_rename, 82
.equ SYS_mkdir, 83
.equ SYS_rmdir, 84
.equ SYS_unlink, 87
.equ O_NOFOLLOW, 131072
.equ O_DIRECTORY, 65536
.equ O_CLOEXEC, 524288

.section .text
_start:
    mov rax, [rsp]
    mov [rip + argc], rax
    lea rax, [rsp + 8]
    mov [rip + argv], rax
    mov rcx, [rip + argc]
    lea rax, [rax + rcx*8 + 8]
    mov [rip + envp], rax
    mov qword ptr [rip + argi], 1
.Lglobals:
    call next_arg
    test rax, rax
    jz cmd_help
    mov r12, rax
    lea rsi, [rip + opt_json]
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lglobal_json
    lea rsi, [rip + opt_no_color]
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Lglobals
    lea rsi, [rip + opt_help]
    mov rdi, r12
    call streq
    test eax, eax
    jnz cmd_help
    lea rsi, [rip + opt_h]
    mov rdi, r12
    call streq
    test eax, eax
    jnz cmd_help
    lea rsi, [rip + opt_version]
    mov rdi, r12
    call streq
    test eax, eax
    jnz cmd_version
    lea rsi, [rip + opt_V]
    mov rdi, r12
    call streq
    test eax, eax
    jnz cmd_version
    lea rbx, [rip + commands]
.Ldispatch:
    mov rsi, [rbx]
    test rsi, rsi
    jz unknown_command
    mov rdi, r12
    call streq
    test eax, eax
    jnz .Ldispatch_match
    add rbx, 16
    jmp .Ldispatch
.Ldispatch_match:
    jmp [rbx + 8]
.Lglobal_json:
    mov byte ptr [rip + json_mode], 1
    jmp .Lglobals

/* Return next argument or zero. */
next_arg:
    mov rax, [rip + argi]
    cmp rax, [rip + argc]
    jae .Lnext_none
    mov rcx, [rip + argv]
    mov rax, [rcx + rax*8]
    inc qword ptr [rip + argi]
    ret
.Lnext_none:
    xor eax, eax
    ret

streq:
    xor ecx, ecx
.Leq_loop:
    mov al, [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .Leq_no
    inc rcx
    test al, al
    jnz .Leq_loop
    mov eax, 1
    ret
.Leq_no:
    xor eax, eax
    ret

strlen:
    xor eax, eax
.Llen_loop:
    cmp byte ptr [rdi + rax], 0
    je .Llen_done
    inc rax
    jmp .Llen_loop
.Llen_done:
    ret

/* copy NUL-terminated string; return pointer to destination NUL. */
copy_string:
    mov rax, rdi
.Lcopy_loop:
    mov cl, [rsi]
    mov [rax], cl
    test cl, cl
    jz .Lcopy_done
    inc rsi
    inc rax
    jmp .Lcopy_loop
.Lcopy_done:
    ret

/* write_cstr(fd=rdi, string=rsi), retry EINTR and short writes. */
write_cstr:
    xor edx, edx
.Lwrite_len:
    cmp byte ptr [rsi + rdx], 0
    je write_all
    inc rdx
    jmp .Lwrite_len
write_all:
    test rdx, rdx
    jz .Lwrite_ok
    mov eax, SYS_write
    syscall
    cmp rax, -4
    je write_all
    test rax, rax
    jle .Lwrite_done
    add rsi, rax
    sub rdx, rax
    jmp write_all
.Lwrite_ok:
    xor eax, eax
.Lwrite_done:
    ret
out:
    mov rsi, rdi
    mov edi, 1
    jmp write_cstr

/* report(text=rdi, json=rsi). All text passed here includes a newline. */
report:
    cmp byte ptr [rip + json_mode], 0
    je out
    mov rdi, rsi
    jmp out

/* Fail with a static, JSON-safe one-line error (without a trailing newline). */
die:
    mov r12d, esi
    mov r13, rdi
    cmp byte ptr [rip + json_mode], 0
    je .Ldie_plain
    mov edi, 2
    lea rsi, [rip + error_json_prefix]
    call write_cstr
    mov edi, 2
    mov rsi, r13
    call write_cstr
    mov edi, 2
    lea rsi, [rip + error_json_suffix]
    call write_cstr
    jmp .Ldie_exit
.Ldie_plain:
    mov edi, 2
    lea rsi, [rip + error_prefix]
    call write_cstr
    mov edi, 2
    mov rsi, r13
    call write_cstr
    mov edi, 2
    lea rsi, [rip + newline]
    call write_cstr
.Ldie_exit:
    mov edi, r12d
    jmp exit_code
exit_ok:
    xor edi, edi
exit_code:
    mov eax, SYS_exit
    syscall

unknown_command:
    lea rdi, [rip + err_unknown_command]
    mov esi, 2
    jmp die
bad_args:
    lea rdi, [rip + err_arguments]
    mov esi, 2
    jmp die
unsupported_target:
    lea rdi, [rip + err_target]
    mov esi, 2
    jmp die

/* Shared trailing options. rax=argument. Returns 1 if consumed, 0 otherwise.
 * --target accepts only the supported host and its documented alias. */
common_option:
    push rbx
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + opt_json]
    call streq
    test eax, eax
    jnz .Lopt_json
    mov rdi, rbx
    lea rsi, [rip + opt_no_color]
    call streq
    test eax, eax
    jnz .Lopt_yes
    mov rdi, rbx
    lea rsi, [rip + opt_target]
    call streq
    test eax, eax
    jnz .Lopt_target
    mov rdi, rbx
    lea rsi, [rip + opt_help]
    call streq
    test eax, eax
    jnz cmd_help
    mov rdi, rbx
    lea rsi, [rip + opt_h]
    call streq
    test eax, eax
    jnz cmd_help
    xor eax, eax
    pop rbx
    ret
.Lopt_json:
    mov byte ptr [rip + json_mode], 1
.Lopt_yes:
    mov eax, 1
    pop rbx
    ret
.Lopt_target:
    call next_arg
    test rax, rax
    jz bad_args
    mov rdi, rax
    call validate_target
    test eax, eax
    jz unsupported_target
    jmp .Lopt_yes

validate_target:
    push rdi
    lea rsi, [rip + host_target]
    call streq
    pop rdi
    test eax, eax
    jnz .Ltarget_done
    lea rsi, [rip + host_target_alias]
    call streq
.Ltarget_done:
    ret

parse_options_only:
    call next_arg
    test rax, rax
    jz .Lopts_done
    call common_option
    test eax, eax
    jz bad_args
    jmp parse_options_only
.Lopts_done:
    ret

cmd_help:
    call parse_options_only
    lea rdi, [rip + help_text]
    lea rsi, [rip + help_json]
    call report
    jmp exit_ok
cmd_version:
    call parse_options_only
    lea rdi, [rip + version_text]
    lea rsi, [rip + version_json]
    call report
    jmp exit_ok
cmd_targets:
    call parse_options_only
    lea rdi, [rip + targets_text]
    lea rsi, [rip + targets_json]
    call report
    jmp exit_ok
cmd_status:
    call parse_options_only
    lea rdi, [rip + status_json]
    call out
    jmp exit_ok
cmd_doctor:
    call parse_options_only
    call check_tools
    lea rdi, [rip + doctor_text]
    lea rsi, [rip + doctor_json]
    call report
    jmp exit_ok

check_tools:
    mov eax, SYS_access
    lea rdi, [rip + as_path]
    mov esi, 1
    syscall
    test rax, rax
    jnz .Ltools_missing
    mov eax, SYS_access
    lea rdi, [rip + ld_path]
    mov esi, 1
    syscall
    test rax, rax
    jnz .Ltools_missing
    ret
.Ltools_missing:
    lea rdi, [rip + err_tools]
    mov esi, 127
    jmp die

cmd_unimplemented:
    call parse_unimplemented_options
    lea rdi, [rip + err_unimplemented]
    mov esi, 69
    jmp die
parse_unimplemented_options:
    call next_arg
    test rax, rax
    jz .Lunimplemented_done
    mov rdi, rax
    lea rsi, [rip + opt_json]
    call streq
    test eax, eax
    jz parse_unimplemented_options
    mov byte ptr [rip + json_mode], 1
    jmp parse_unimplemented_options
.Lunimplemented_done:
    ret

/* Project creation: preflight all files, use O_EXCL|O_NOFOLLOW, roll back only
 * files/directories created by this invocation if any operation fails. */
cmd_new:
    mov byte ptr [rip + new_mode], 1
cmd_init:
    lea rax, [rip + dot]
    mov [rip + project_path], rax
.Linit_parse:
    call next_arg
    test rax, rax
    jz .Linit_parsed
    mov r12, rax
    cmp byte ptr [rip + literal_path], 0
    jne .Linit_path
    mov rdi, r12
    lea rsi, [rip + opt_separator]
    call streq
    test eax, eax
    jz .Linit_options
    mov byte ptr [rip + literal_path], 1
    jmp .Linit_parse
.Linit_options:
    mov rax, r12
    call common_option
    test eax, eax
    jnz .Linit_parse
    cmp byte ptr [r12], '-'
    je bad_args
.Linit_path:
    cmp byte ptr [rip + path_seen], 0
    jne bad_args
    mov rdi, r12
    call strlen
    test rax, rax
    jz bad_args
    cmp rax, 4095
    ja bad_args
    mov [rip + project_path], r12
    mov byte ptr [rip + path_seen], 1
    jmp .Linit_parse
.Linit_parsed:
    cmp byte ptr [rip + new_mode], 0
    je .Linit_save_cwd
    cmp byte ptr [rip + path_seen], 0
    je bad_args
.Linit_save_cwd:
    mov eax, SYS_open
    lea rdi, [rip + dot]
    mov esi, O_DIRECTORY + O_CLOEXEC
    xor edx, edx
    syscall
    test rax, rax
    js .Linit_path_error
    mov [rip + initial_cwd_fd], rax
    cmp byte ptr [rip + new_mode], 0
    je .Linit_chdir
    mov eax, SYS_mkdir
    mov rdi, [rip + project_path]
    mov esi, 493
    syscall
    test rax, rax
    js .Linit_path_error
    mov byte ptr [rip + made_project], 1
.Linit_chdir:
    mov eax, SYS_chdir
    mov rdi, [rip + project_path]
    syscall
    test rax, rax
    js init_rollback
    lea rdi, [rip + manifest_path]
    call require_absent
    lea rdi, [rip + source_default]
    call require_absent
    lea rdi, [rip + test_source]
    call require_absent
    lea rdi, [rip + src_dir]
    call make_safe_dir
    test rax, rax
    js init_rollback
    mov [rip + made_src], al
    lea rdi, [rip + tests_dir]
    call make_safe_dir
    test rax, rax
    js init_rollback
    mov [rip + made_tests], al
    /* A name derived from the last path component, if valid; otherwise app. */
    lea rdi, [rip + package_name]
    lea rsi, [rip + default_name]
    call copy_string
    mov rsi, [rip + project_path]
    mov r12, rsi
.Lbasename_scan:
    mov al, [rsi]
    test al, al
    jz .Lbasename_ready
    cmp al, '/'
    jne .Lbasename_next
    lea r12, [rsi + 1]
.Lbasename_next:
    inc rsi
    jmp .Lbasename_scan
.Lbasename_ready:
    mov rdi, r12
    call valid_name
    test eax, eax
    jz .Linit_manifest
    lea rdi, [rip + package_name]
    mov rsi, r12
    call copy_string
.Linit_manifest:
    lea rdi, [rip + manifest_buffer]
    lea rsi, [rip + manifest_prefix]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + package_name]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + manifest_suffix]
    call copy_string
    lea rdi, [rip + manifest_path]
    lea rsi, [rip + manifest_buffer]
    lea rdx, [rip + made_manifest]
    call create_exclusive_file
    test rax, rax
    js init_rollback
    lea rdi, [rip + source_default]
    lea rsi, [rip + main_template]
    lea rdx, [rip + made_main]
    call create_exclusive_file
    test rax, rax
    js init_rollback
    lea rdi, [rip + test_source]
    lea rsi, [rip + test_template]
    lea rdx, [rip + made_test]
    call create_exclusive_file
    test rax, rax
    js init_rollback
    lea rdi, [rip + init_text]
    lea rsi, [rip + init_json]
    call report
    jmp exit_ok
.Linit_path_error:
    lea rdi, [rip + err_init_path]
    mov esi, 1
    jmp die

require_absent:
    mov eax, SYS_lstat
    lea rsi, [rip + stat_buffer]
    syscall
    cmp rax, -2
    jne init_rollback
    ret

/* make_safe_dir(path): 1 created, 0 existing real directory, -1 failure. */
make_safe_dir:
    push rbx
    mov rbx, rdi
    mov eax, SYS_mkdir
    mov esi, 493
    syscall
    test rax, rax
    jz .Ldir_created
    cmp rax, -17
    jne .Ldir_fail
    mov eax, SYS_lstat
    mov rdi, rbx
    lea rsi, [rip + stat_buffer]
    syscall
    test rax, rax
    js .Ldir_fail
    mov eax, [rip + stat_buffer + 24]
    and eax, 61440
    cmp eax, 16384
    jne .Ldir_fail
    xor eax, eax
    pop rbx
    ret
.Ldir_created:
    mov eax, 1
    pop rbx
    ret
.Ldir_fail:
    mov rax, -1
    pop rbx
    ret

create_exclusive_file:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    mov eax, SYS_open
    mov esi, O_NOFOLLOW + O_CLOEXEC + 193
    mov edx, 420
    syscall
    test rax, rax
    js .Lcreate_end
    mov byte ptr [r13], 1
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    call write_cstr
    mov r12, rax
    mov eax, SYS_close
    mov rdi, rbx
    syscall
    test r12, r12
    js .Lcreate_write_error
    jmp .Lcreate_end
.Lcreate_write_error:
    mov rax, r12
.Lcreate_end:
    pop r13
    pop r12
    pop rbx
    ret

init_rollback:
    cmp byte ptr [rip + made_test], 0
    je .Lrollback_main
    mov eax, SYS_unlink
    lea rdi, [rip + test_source]
    syscall
.Lrollback_main:
    cmp byte ptr [rip + made_main], 0
    je .Lrollback_manifest
    mov eax, SYS_unlink
    lea rdi, [rip + source_default]
    syscall
.Lrollback_manifest:
    cmp byte ptr [rip + made_manifest], 0
    je .Lrollback_tests
    mov eax, SYS_unlink
    lea rdi, [rip + manifest_path]
    syscall
.Lrollback_tests:
    cmp byte ptr [rip + made_tests], 0
    je .Lrollback_src
    mov eax, SYS_rmdir
    lea rdi, [rip + tests_dir]
    syscall
.Lrollback_src:
    cmp byte ptr [rip + made_src], 0
    je .Lrollback_project
    mov eax, SYS_rmdir
    lea rdi, [rip + src_dir]
    syscall
.Lrollback_project:
    cmp byte ptr [rip + made_project], 0
    je .Lrollback_error
    mov eax, SYS_fchdir
    mov rdi, [rip + initial_cwd_fd]
    syscall
    test rax, rax
    js .Lrollback_error
    mov eax, SYS_rmdir
    mov rdi, [rip + project_path]
    syscall
.Lrollback_error:
    lea rdi, [rip + err_init_conflict]
    mov esi, 1
    jmp die

/* Strict, documented TOML subset. Sections and string fields are parsed, not
 * ignored. Unknown keys, duplicate fields, escapes and unsupported targets fail. */
read_manifest:
    mov eax, SYS_open
    lea rdi, [rip + manifest_path]
    mov esi, O_NOFOLLOW + O_CLOEXEC
    xor edx, edx
    syscall
    test rax, rax
    js manifest_error
    mov r12, rax
    mov eax, SYS_fstat
    mov rdi, r12
    lea rsi, [rip + stat_buffer]
    syscall
    test rax, rax
    js .Lmanifest_close_error
    mov eax, [rip + stat_buffer + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lmanifest_close_error
    mov rax, [rip + stat_buffer + 48]
    test rax, rax
    jz .Lmanifest_close_error
    cmp rax, 8191
    ja .Lmanifest_close_error
    xor r13d, r13d
.Lmanifest_read:
    mov eax, SYS_read
    mov rdi, r12
    lea rsi, [rip + manifest_buffer]
    add rsi, r13
    mov edx, 8191
    sub rdx, r13
    syscall
    cmp rax, -4
    je .Lmanifest_read
    test rax, rax
    js .Lmanifest_close_error
    jz .Lmanifest_read_done
    add r13, rax
    cmp r13, 8191
    jae .Lmanifest_close_error
    jmp .Lmanifest_read
.Lmanifest_read_done:
    lea rax, [rip + manifest_buffer]
    xor ecx, ecx
.Lmanifest_no_nul:
    cmp rcx, r13
    jae .Lmanifest_terminate
    cmp byte ptr [rax + rcx], 0
    je .Lmanifest_close_error
    inc rcx
    jmp .Lmanifest_no_nul
.Lmanifest_terminate:
    mov byte ptr [rax + r13], 0
    mov eax, SYS_close
    mov rdi, r12
    syscall
    lea r12, [rip + manifest_buffer]
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d
.Lmanifest_line:
    mov al, [r12]
    test al, al
    jz .Lmanifest_finish
    cmp al, ' '
    je .Lmanifest_skip
    cmp al, 9
    je .Lmanifest_skip
    cmp al, 13
    je .Lmanifest_skip
    cmp al, 10
    je .Lmanifest_skip
    cmp al, '#'
    je .Lmanifest_comment
    cmp al, '['
    je .Lmanifest_section
    mov rdi, r12
    xor ecx, ecx
.Lmanifest_key:
    mov al, [r12]
    cmp al, 'a'
    jb .Lmanifest_key_end
    cmp al, 'z'
    ja .Lmanifest_key_end
    inc ecx
    inc r12
    cmp ecx, 32
    ja manifest_error
    jmp .Lmanifest_key
.Lmanifest_key_end:
    test ecx, ecx
    jz manifest_error
    lea rsi, [rip + key_buffer]
    xor edx, edx
.Lmanifest_key_copy:
    mov al, [rdi + rdx]
    mov [rsi + rdx], al
    inc edx
    cmp edx, ecx
    jb .Lmanifest_key_copy
    mov byte ptr [rsi + rdx], 0
    call skip_horizontal
    cmp byte ptr [r12], '='
    jne manifest_error
    inc r12
    call skip_horizontal
    cmp byte ptr [r12], '"'
    jne manifest_error
    inc r12
    lea rdi, [rip + key_buffer]
    lea rsi, [rip + key_name]
    call streq
    test eax, eax
    jnz .Lfield_name
    lea rdi, [rip + key_buffer]
    lea rsi, [rip + key_version]
    call streq
    test eax, eax
    jnz .Lfield_version
    lea rdi, [rip + key_buffer]
    lea rsi, [rip + key_source]
    call streq
    test eax, eax
    jnz .Lfield_source
    lea rdi, [rip + key_buffer]
    lea rsi, [rip + key_target]
    call streq
    test eax, eax
    jnz .Lfield_target
    jmp manifest_error
.Lfield_name:
    cmp r13d, 1
    jne manifest_error
    lea rdi, [rip + package_name]
    mov esi, 63
    mov edx, 1
    jmp .Lfield_read
.Lfield_version:
    cmp r13d, 1
    jne manifest_error
    lea rdi, [rip + package_version]
    mov esi, 63
    mov edx, 2
    jmp .Lfield_read
.Lfield_source:
    cmp r13d, 2
    jne manifest_error
    lea rdi, [rip + package_source]
    mov esi, 255
    mov edx, 4
    jmp .Lfield_read
.Lfield_target:
    cmp r13d, 2
    jne manifest_error
    lea rdi, [rip + package_target]
    mov esi, 63
    mov edx, 8
.Lfield_read:
    test r14d, edx
    jnz manifest_error
    or r14d, edx
    xor ecx, ecx
.Lfield_chars:
    mov al, [r12]
    cmp al, '"'
    je .Lfield_end
    cmp al, 32
    jb manifest_error
    cmp al, 127
    je manifest_error
    cmp al, '\\'
    je manifest_error
    cmp ecx, esi
    jae manifest_error
    mov [rdi + rcx], al
    inc r12
    inc ecx
    jmp .Lfield_chars
.Lfield_end:
    test ecx, ecx
    jz manifest_error
    mov byte ptr [rdi + rcx], 0
    inc r12
    jmp .Lline_end
.Lmanifest_section:
    inc r12
    lea rdi, [rip + key_buffer]
    xor ecx, ecx
.Lsection_chars:
    mov al, [r12]
    cmp al, ']'
    je .Lsection_end
    cmp al, 'a'
    jb manifest_error
    cmp al, 'z'
    ja manifest_error
    cmp ecx, 31
    jae manifest_error
    mov [rdi + rcx], al
    inc ecx
    inc r12
    jmp .Lsection_chars
.Lsection_end:
    mov byte ptr [rdi + rcx], 0
    inc r12
    lea rsi, [rip + section_package]
    call streq
    test eax, eax
    jnz .Lsection_package
    lea rdi, [rip + key_buffer]
    lea rsi, [rip + section_build]
    call streq
    test eax, eax
    jz manifest_error
    test r15d, 2
    jnz manifest_error
    or r15d, 2
    mov r13d, 2
    jmp .Lline_end
.Lsection_package:
    test r15d, 1
    jnz manifest_error
    or r15d, 1
    mov r13d, 1
.Lline_end:
    call skip_horizontal
    mov al, [r12]
    cmp al, '#'
    je .Lmanifest_comment
    cmp al, 10
    je .Lmanifest_skip
    test al, al
    jz .Lmanifest_finish
    jmp manifest_error
.Lmanifest_skip:
    inc r12
    jmp .Lmanifest_line
.Lmanifest_comment:
    mov al, [r12]
    test al, al
    jz .Lmanifest_finish
    inc r12
    cmp al, 10
    jne .Lmanifest_comment
    jmp .Lmanifest_line
.Lmanifest_finish:
    cmp r14d, 15
    jne manifest_error
    lea rdi, [rip + package_name]
    call valid_name
    test eax, eax
    jz manifest_error
    lea rdi, [rip + package_version]
    call valid_version
    test eax, eax
    jz manifest_error
    lea rdi, [rip + package_source]
    call valid_source
    test eax, eax
    jz manifest_error
    lea rdi, [rip + package_target]
    call validate_target
    test eax, eax
    jz unsupported_target
    ret
.Lmanifest_close_error:
    mov eax, SYS_close
    mov rdi, r12
    syscall
manifest_error:
    lea rdi, [rip + err_manifest]
    mov esi, 1
    jmp die

skip_horizontal:
    mov al, [r12]
    cmp al, ' '
    je .Lhorizontal_next
    cmp al, 9
    je .Lhorizontal_next
    cmp al, 13
    jne .Lhorizontal_end
.Lhorizontal_next:
    inc r12
    jmp skip_horizontal
.Lhorizontal_end:
    ret

valid_name:
    mov al, [rdi]
    cmp al, 'a'
    jb .Linvalid
    cmp al, 'z'
    ja .Linvalid
    mov ecx, 1
.Lname_loop:
    mov al, [rdi + rcx]
    test al, al
    jz .Lvalid
    cmp ecx, 63
    jae .Linvalid
    cmp al, '-'
    je .Lname_next
    cmp al, '0'
    jb .Linvalid
    cmp al, '9'
    jbe .Lname_next
    cmp al, 'a'
    jb .Linvalid
    cmp al, 'z'
    ja .Linvalid
.Lname_next:
    inc ecx
    jmp .Lname_loop
/* v0.1 accepts numeric major.minor.patch, without leading zeroes. */
valid_version:
    xor ecx, ecx
    xor edx, edx
.Lversion_component:
    mov al, [rdi + rcx]
    cmp al, '0'
    jb .Linvalid
    cmp al, '9'
    ja .Linvalid
    mov r8b, al
    inc ecx
    cmp r8b, '0'
    je .Lversion_sep
.Lversion_digits:
    mov al, [rdi + rcx]
    cmp al, '0'
    jb .Lversion_sep
    cmp al, '9'
    ja .Lversion_sep
    inc ecx
    cmp ecx, 63
    jae .Linvalid
    jmp .Lversion_digits
.Lversion_sep:
    mov al, [rdi + rcx]
    test al, al
    jz .Lversion_final
    cmp al, '.'
    jne .Linvalid
    inc edx
    cmp edx, 2
    ja .Linvalid
    inc ecx
    jmp .Lversion_component
.Lversion_final:
    cmp edx, 2
    je .Lvalid
    jmp .Linvalid

/* Relative source paths, no empty/. /.. segments, no option-like basename. */
valid_source:
    cmp byte ptr [rdi], '/'
    je .Linvalid
    xor ecx, ecx
    xor edx, edx
.Lsource_segment:
    mov al, [rdi + rcx]
    cmp al, '-'
    je .Linvalid
    mov edx, ecx
.Lsource_loop:
    mov al, [rdi + rcx]
    test al, al
    jz .Lsource_end_segment
    cmp al, '/'
    je .Lsource_end_segment
    cmp al, 32
    jb .Linvalid
    inc ecx
    jmp .Lsource_loop
.Lsource_end_segment:
    mov r8d, ecx
    sub r8d, edx
    jz .Linvalid
    cmp byte ptr [rdi + rdx], '.'
    jne .Lsource_continue
    cmp r8d, 1
    je .Linvalid
    cmp r8d, 2
    jne .Lsource_continue
    cmp byte ptr [rdi + rdx + 1], '.'
    je .Linvalid
.Lsource_continue:
    test al, al
    jz .Lvalid
    inc ecx
    jmp .Lsource_segment
.Lvalid:
    mov eax, 1
    ret
.Linvalid:
    xor eax, eax
    ret

/* Build outputs in a fresh process-specific staging directory, then rename
 * completed artifacts into place. Never pass project paths through a shell. */
cmd_build:
    call parse_options_only
    call read_manifest
    call build_project
    lea rdi, [rip + build_text]
    lea rsi, [rip + build_json]
    call report
    jmp exit_ok
cmd_run:
    mov byte ptr [rip + run_mode], 1
.Lrun_options:
    call next_arg
    test rax, rax
    jz .Lrun_args_done
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + opt_separator]
    call streq
    test eax, eax
    jnz .Lrun_args_done
    mov rax, r12
    call common_option
    test eax, eax
    jz bad_args
    jmp .Lrun_options
.Lrun_args_done:
    mov rax, [rip + argi]
    mov [rip + run_argi], rax
    call read_manifest
    call build_project
    /* Reuse argv's contiguous tail, replacing the preceding slot with argv0. */
    mov rax, [rip + run_argi]
    dec rax
    mov rsi, [rip + argv]
    lea rsi, [rsi + rax*8]
    lea rdi, [rip + app_output]
    mov [rsi], rdi
    call spawn_wait
    mov edi, eax
    jmp exit_code
cmd_test:
    call parse_options_only
    call read_manifest
    mov byte ptr [rip + test_mode], 1
    call build_project
    lea rdi, [rip + test_output]
    mov [rip + child_argv], rdi
    mov qword ptr [rip + child_argv + 8], 0
    lea rsi, [rip + child_argv]
    call spawn_wait
    test eax, eax
    jnz .Ltest_failed
    lea rdi, [rip + test_text]
    lea rsi, [rip + test_json]
    call report
    jmp exit_ok
.Ltest_failed:
    mov esi, eax
    lea rdi, [rip + err_test]
    jmp die

build_project:
    call check_tools
    lea rdi, [rip + build_dir]
    call make_safe_dir
    test rax, rax
    js build_directory_error
    lea rdi, [rip + stage_dir]
    lea rsi, [rip + stage_prefix]
    call copy_string
    mov r12, rax
    mov eax, SYS_getpid
    syscall
    mov rdi, rax
    lea rsi, [rip + number_buffer + 31]
    call unsigned_decimal
    mov rdi, r12
    mov rsi, rax
    call copy_string
    mov eax, SYS_mkdir
    lea rdi, [rip + stage_dir]
    mov esi, 448
    syscall
    test rax, rax
    js build_directory_error
    lea rdi, [rip + stage_object]
    lea rsi, [rip + stage_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + object_suffix]
    call copy_string
    lea rdi, [rip + stage_binary]
    lea rsi, [rip + stage_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + binary_suffix]
    call copy_string
    lea rax, [rip + as_path]
    mov [rip + child_argv], rax
    lea rax, [rip + as_64]
    mov [rip + child_argv + 8], rax
    lea rax, [rip + arg_o]
    mov [rip + child_argv + 16], rax
    lea rax, [rip + stage_object]
    mov [rip + child_argv + 24], rax
    lea rax, [rip + package_source]
    cmp byte ptr [rip + test_mode], 0
    je .Lbuild_source_set
    lea rax, [rip + test_source]
.Lbuild_source_set:
    mov [rip + child_argv + 32], rax
    mov qword ptr [rip + child_argv + 40], 0
    lea rdi, [rip + as_path]
    lea rsi, [rip + child_argv]
    call spawn_wait
    test eax, eax
    jnz build_child_error
    lea rax, [rip + ld_path]
    mov [rip + child_argv], rax
    lea rax, [rip + arg_z]
    mov [rip + child_argv + 8], rax
    lea rax, [rip + noexecstack]
    mov [rip + child_argv + 16], rax
    lea rax, [rip + arg_o]
    mov [rip + child_argv + 24], rax
    lea rax, [rip + stage_binary]
    mov [rip + child_argv + 32], rax
    lea rax, [rip + stage_object]
    mov [rip + child_argv + 40], rax
    mov qword ptr [rip + child_argv + 48], 0
    lea rdi, [rip + ld_path]
    lea rsi, [rip + child_argv]
    call spawn_wait
    test eax, eax
    jnz build_child_error
    mov eax, SYS_rename
    lea rdi, [rip + stage_binary]
    lea rsi, [rip + app_output]
    cmp byte ptr [rip + test_mode], 0
    je .Lrename_binary
    lea rsi, [rip + test_output]
.Lrename_binary:
    syscall
    test rax, rax
    js build_io_error
    mov eax, SYS_rename
    lea rdi, [rip + stage_object]
    lea rsi, [rip + object_output]
    cmp byte ptr [rip + test_mode], 0
    je .Lrename_object
    lea rsi, [rip + test_object_output]
.Lrename_object:
    syscall
    test rax, rax
    js build_io_error
    call cleanup_stage
    ret
build_child_error:
    mov r15d, eax
    call cleanup_stage
    lea rdi, [rip + err_build]
    mov esi, r15d
    jmp die
build_io_error:
    call cleanup_stage
build_directory_error:
    lea rdi, [rip + err_build_io]
    mov esi, 1
    jmp die
cleanup_stage:
    mov eax, SYS_unlink
    lea rdi, [rip + stage_object]
    syscall
    mov eax, SYS_unlink
    lea rdi, [rip + stage_binary]
    syscall
    mov eax, SYS_rmdir
    lea rdi, [rip + stage_dir]
    syscall
    ret

unsigned_decimal:
    mov byte ptr [rsi], 0
    mov rax, rdi
    mov r8d, 10
.Ldecimal_loop:
    xor edx, edx
    div r8
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .Ldecimal_loop
    mov rax, rsi
    ret

/* Spawn a fixed executable with explicit argv, inherit env and file streams.
 * Return child's exit code, or 128+signal; never turn a failed exec into success. */
spawn_wait:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov eax, SYS_fork
    syscall
    test rax, rax
    js .Lspawn_failed
    jz .Lspawn_child
    mov rbx, rax
.Lwait_again:
    mov eax, SYS_wait4
    mov rdi, rbx
    lea rsi, [rip + child_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lwait_again
    test rax, rax
    js .Lspawn_failed
    mov eax, [rip + child_status]
    mov edx, eax
    and edx, 127
    jnz .Lspawn_signal
    shr eax, 8
    and eax, 255
    jmp .Lspawn_return
.Lspawn_signal:
    lea eax, [rdx + 128]
    jmp .Lspawn_return
.Lspawn_child:
    mov eax, SYS_execve
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + envp]
    syscall
    mov edi, 127
    jmp exit_code
.Lspawn_failed:
    mov eax, 127
.Lspawn_return:
    pop r13
    pop r12
    pop rbx
    ret

cmd_clean:
    call parse_options_only
    call read_manifest
    mov eax, SYS_lstat
    lea rdi, [rip + build_dir]
    lea rsi, [rip + stat_buffer]
    syscall
    cmp rax, -2
    je .Lclean_done
    test rax, rax
    js .Lclean_error
    mov eax, [rip + stat_buffer + 24]
    and eax, 61440
    cmp eax, 16384
    jne .Lclean_error
    lea rdi, [rip + app_output]
    call clean_file
    lea rdi, [rip + object_output]
    call clean_file
    lea rdi, [rip + test_output]
    call clean_file
    lea rdi, [rip + test_object_output]
    call clean_file
    mov eax, SYS_rmdir
    lea rdi, [rip + build_dir]
    syscall
    test rax, rax
    jz .Lclean_done
    cmp rax, -39
    je .Lclean_done
    cmp rax, -2
    jne .Lclean_error
.Lclean_done:
    lea rdi, [rip + clean_text]
    lea rsi, [rip + clean_json]
    call report
    jmp exit_ok
.Lclean_error:
    lea rdi, [rip + err_clean]
    mov esi, 1
    jmp die
clean_file:
    mov eax, SYS_unlink
    syscall
    test rax, rax
    jz .Lclean_file_done
    cmp rax, -2
    jne .Lclean_error
.Lclean_file_done:
    ret

.section .rodata
commands:
    .quad command_help, cmd_help, command_version, cmd_version
    .quad command_doctor, cmd_doctor, command_init, cmd_init
    .quad command_new, cmd_new, command_build, cmd_build
    .quad command_run, cmd_run, command_test, cmd_test
    .quad command_clean, cmd_clean, command_target, cmd_targets
    .quad command_targets, cmd_targets, command_status, cmd_status
    .quad command_add, cmd_unimplemented, command_remove, cmd_unimplemented
    .quad command_search, cmd_unimplemented, command_publish, cmd_unimplemented
    .quad command_install, cmd_unimplemented, command_update, cmd_unimplemented
    .quad command_lock, cmd_unimplemented, command_login, cmd_unimplemented
    .quad command_yank, cmd_unimplemented, 0, 0
command_help: .asciz "help"
command_version: .asciz "version"
command_doctor: .asciz "doctor"
command_init: .asciz "init"
command_new: .asciz "new"
command_build: .asciz "build"
command_run: .asciz "run"
command_test: .asciz "test"
command_clean: .asciz "clean"
command_target: .asciz "target"
command_targets: .asciz "targets"
command_status: .asciz "status"
command_add: .asciz "add"
command_remove: .asciz "remove"
command_search: .asciz "search"
command_publish: .asciz "publish"
command_install: .asciz "install"
command_update: .asciz "update"
command_lock: .asciz "lock"
command_login: .asciz "login"
command_yank: .asciz "yank"
opt_json: .asciz "--json"
opt_no_color: .asciz "--no-color"
opt_help: .asciz "--help"
opt_h: .asciz "-h"
opt_version: .asciz "--version"
opt_V: .asciz "-V"
opt_target: .asciz "--target"
opt_separator: .asciz "--"
host_target: .asciz "x86_64-linux"
host_target_alias: .asciz "x86_64-unknown-linux-gnu"
as_path: .asciz "/usr/bin/as"
ld_path: .asciz "/usr/bin/ld"
as_64: .asciz "--64"
arg_o: .asciz "-o"
arg_z: .asciz "-z"
noexecstack: .asciz "noexecstack"
dot: .asciz "."
manifest_path: .asciz "asm.toml"
source_default: .asciz "src/main.s"
test_source: .asciz "tests/main.s"
src_dir: .asciz "src"
tests_dir: .asciz "tests"
build_dir: .asciz "build"
app_output: .asciz "build/app"
object_output: .asciz "build/main.o"
test_output: .asciz "build/test"
test_object_output: .asciz "build/test.o"
stage_prefix: .asciz "build/.asm-"
object_suffix: .asciz "/main.o"
binary_suffix: .asciz "/app"
default_name: .asciz "app"
key_name: .asciz "name"
key_version: .asciz "version"
key_source: .asciz "source"
key_target: .asciz "target"
section_package: .asciz "package"
section_build: .asciz "build"
newline: .asciz "\n"
error_prefix: .asciz "asm: "
error_json_prefix: .asciz "{\"ok\":false,\"error\":\""
error_json_suffix: .asciz "\"}\n"
err_unknown_command: .asciz "unknown command; use asm help"
err_arguments: .asciz "invalid arguments; use asm help"
err_target: .asciz "unsupported target; this release supports x86_64-linux only"
err_tools: .asciz "GNU as and ld must be executable at /usr/bin/as and /usr/bin/ld"
err_unimplemented: .asciz "registry operations are not implemented in this build; use asm status"
err_init_path: .asciz "cannot create project directory; new requires a path that does not exist"
err_init_conflict: .asciz "cannot initialize project; existing files and symlink directories are never overwritten"
err_manifest: .asciz "invalid or missing asm.toml; expected package name/version and build source/target"
err_build: .asciz "build failed; see tool diagnostics above"
err_build_io: .asciz "cannot write build artifacts; build must be a real directory"
err_test: .asciz "test program failed"
err_clean: .asciz "cannot clean artifacts; build must be a real directory"

version_text: .asciz "asm 0.1.0 (x86_64-linux)\n"
version_json: .asciz "{\"name\":\"asm\",\"version\":\"0.1.0\",\"host\":\"x86_64-linux\"}\n"
targets_text: .asciz "x86_64-linux (host; GNU as + ld)\n"
targets_json: .asciz "{\"host\":\"x86_64-linux\",\"targets\":[\"x86_64-linux\"]}\n"
doctor_text: .asciz "Host: x86_64-linux\nAssembler: /usr/bin/as\nLinker: /usr/bin/ld\nReady to build.\n"
doctor_json: .asciz "{\"ok\":true,\"host\":\"x86_64-linux\",\"assembler\":\"/usr/bin/as\",\"linker\":\"/usr/bin/ld\"}\n"
init_text: .asciz "Created asm.toml, src/main.s and tests/main.s.\nNext: asm run\n"
init_json: .asciz "{\"ok\":true,\"created\":[\"asm.toml\",\"src/main.s\",\"tests/main.s\"]}\n"
build_text: .asciz "Built build/app\n"
build_json: .asciz "{\"ok\":true,\"artifact\":\"build/app\"}\n"
test_text: .asciz "Passed tests/main.s\n"
test_json: .asciz "{\"ok\":true,\"test\":\"tests/main.s\"}\n"
clean_text: .asciz "Removed asm build artifacts.\n"
clean_json: .asciz "{\"ok\":true,\"cleaned\":true}\n"
help_text:
    .ascii "asm 0.1.0 - build assembly projects\n\n"
    .ascii "Usage: asm [--json] [--no-color] <command> [options]\n\n"
    .ascii "  new <path>       Create a project in a new directory\n"
    .ascii "  init [path]      Initialize an existing directory (default: .)\n"
    .ascii "  build            Assemble and link to build/app\n"
    .ascii "  run [-- args]    Build, then run with forwarded arguments\n"
    .ascii "  test             Assemble and execute tests/main.s\n"
    .ascii "  clean            Remove only asm's named build artifacts\n"
    .ascii "  doctor           Check the local GNU assembler and linker\n"
    .ascii "  targets          List supported targets\n"
    .ascii "  status           Print machine-readable command availability\n"
    .ascii "  version          Print the CLI version\n"
    .ascii "  help             Show this help\n\n"
    .ascii "Options: --target x86_64-linux, --json, --no-color, --help\n"
    .ascii "For a path starting with -, use: asm new -- <path>\n"
    .ascii "JSON describes asm's own output; child output is passed through.\n"
    .ascii "Registry commands currently fail explicitly with exit status 69.\n"
    .byte 0
help_json:
    .asciz "{\"name\":\"asm\",\"version\":\"0.1.0\",\"usage\":\"asm [--json] <command> [options]\",\"commands\":[\"new\",\"init\",\"build\",\"run\",\"test\",\"clean\",\"doctor\",\"targets\",\"status\",\"version\",\"help\"]}\n"
status_json:
    .asciz "{\"version\":\"0.1.0\",\"implementation\":\"x86_64 assembly\",\"targets\":[\"x86_64-linux\"],\"implemented\":[\"help\",\"version\",\"doctor\",\"init\",\"new\",\"build\",\"run\",\"test\",\"clean\",\"targets\",\"status\"],\"unimplemented\":[\"add\",\"remove\",\"search\",\"install\",\"update\",\"lock\",\"publish\",\"login\",\"yank\"]}\n"
manifest_prefix: .asciz "[package]\nname = \""
manifest_suffix: .asciz "\"\nversion = \"0.1.0\"\n\n[build]\nsource = \"src/main.s\"\ntarget = \"x86_64-linux\"\n"
main_template:
    .ascii ".intel_syntax noprefix\n.global _start\n\n.section .text\n_start:\n"
    .ascii "    mov eax, 1\n    mov edi, 1\n    lea rsi, [rip + message]\n"
    .ascii "    mov edx, OFFSET message_len\n    syscall\n    mov eax, 60\n    xor edi, edi\n    syscall\n\n"
    .ascii ".section .rodata\nmessage: .ascii \"Hello from asm!\\n\"\n.equ message_len, . - message\n"
    .ascii ".section .note.GNU-stack,\"\",@progbits\n"
    .byte 0
test_template:
    .ascii ".intel_syntax noprefix\n.global _start\n\n.section .text\n_start:\n"
    .ascii "    # Exit zero for success; replace this with your assertions.\n"
    .ascii "    mov eax, 60\n    xor edi, edi\n    syscall\n"
    .ascii ".section .note.GNU-stack,\"\",@progbits\n"
    .byte 0

.section .bss
.balign 8
argc: .skip 8
argv: .skip 8
envp: .skip 8
argi: .skip 8
run_argi: .skip 8
project_path: .skip 8
initial_cwd_fd: .skip 8
child_argv: .skip 128
child_status: .skip 8
stat_buffer: .skip 144
number_buffer: .skip 32
stage_dir: .skip 64
stage_object: .skip 96
stage_binary: .skip 96
key_buffer: .skip 64
package_name: .skip 64
package_version: .skip 64
package_source: .skip 256
package_target: .skip 64
manifest_buffer: .skip 8192
json_mode: .skip 1
new_mode: .skip 1
run_mode: .skip 1
test_mode: .skip 1
literal_path: .skip 1
path_seen: .skip 1
made_project: .skip 1
made_src: .skip 1
made_tests: .skip 1
made_manifest: .skip 1
made_main: .skip 1
made_test: .skip 1
.section .note.GNU-stack,"",@progbits
