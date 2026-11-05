/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors.
 * Native-library build arguments and validation. No shell or package hook.
 */
.intel_syntax noprefix
.global native_link_validate
.global package_link, package_libraries, package_check

.section .text
/* Input: RDI=link, RSI=libraries, RDX=check, each a NUL-terminated string
 * bounded to 255 bytes. Empty strings represent absent fields. Output: EAX=1
 * for the native-linking contract, else zero. No memory changes. Scratch:
 * caller-saved registers. Preserves all SysV callee-saved registers. Stack:8.
 * check uses the ordinary source path rules and must end with .c. */
native_link_validate:
    push rbx
    mov rbx, rdx
    cmp byte ptr [rdi], 0
    je .Lnative_validate_absent
    cmp word ptr [rdi], 99
    jne .Lnative_validate_bad
    cmp byte ptr [rsi], 0
    je .Lnative_validate_check
    xor r8d, r8d
.Lnative_library_start:
    inc r8d
    cmp r8d, 8
    ja .Lnative_validate_bad
    mov al, [rsi]
    cmp al, 'a'
    jb .Lnative_validate_bad
    cmp al, 'z'
    ja .Lnative_validate_bad
    xor ecx, ecx
.Lnative_library_character:
    inc ecx
    cmp ecx, 31
    ja .Lnative_validate_bad
    inc rsi
    mov al, [rsi]
    test al, al
    jz .Lnative_validate_check
    cmp al, ' '
    je .Lnative_library_separator
    cmp al, 'a'
    jb .Lnative_library_other
    cmp al, 'z'
    jbe .Lnative_library_character
.Lnative_library_other:
    cmp al, '0'
    jb .Lnative_library_punctuation
    cmp al, '9'
    jbe .Lnative_library_character
.Lnative_library_punctuation:
    cmp al, '_'
    je .Lnative_library_character
    cmp al, '-'
    je .Lnative_library_character
    jmp .Lnative_validate_bad
.Lnative_library_separator:
    inc rsi
    jmp .Lnative_library_start
.Lnative_validate_check:
    cmp byte ptr [rbx], 0
    je .Lnative_validate_good
    xor ecx, ecx
.Lnative_check_character:
    mov al, [rbx + rcx]
    test al, al
    jz .Lnative_check_path
    cmp ecx, 255
    jae .Lnative_validate_bad
    cmp al, 32
    jb .Lnative_validate_bad
    cmp al, 126
    ja .Lnative_validate_bad
    cmp al, '\\'
    je .Lnative_validate_bad
    inc ecx
    jmp .Lnative_check_character
.Lnative_check_path:
    mov rdi, rbx
    call valid_source
    test eax, eax
    jz .Lnative_validate_bad
    mov rdi, rbx
    call strlen
    cmp rax, 2
    jb .Lnative_validate_bad
    cmp word ptr [rbx + rax - 2], 0x632e
    jne .Lnative_validate_bad
.Lnative_validate_good:
    mov eax, 1
    pop rbx
    ret
.Lnative_validate_absent:
    cmp byte ptr [rsi], 0
    jne .Lnative_validate_bad
    cmp byte ptr [rbx], 0
    je .Lnative_validate_good
.Lnative_validate_bad:
    xor eax, eax
    pop rbx
    ret

/* Input: RAX=current option. Output: EAX=1 if consumed, else zero. Directory
 * pointers remain borrowed from argv. Each list holds at most eight entries;
 * strings are absolute printable ASCII, <=255 bytes, without ':' or ','.
 * Invalid options exit before a build stage exists. Scratch: caller-saved.
 * Preserves callee-saved registers. Stack:24 bytes plus bounded callees. */
native_link_option:
    push rbx
    push r12
    push r13
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + native_opt_include]
    call streq
    test eax, eax
    jnz .Lnative_option_include
    mov rdi, rbx
    lea rsi, [rip + native_opt_library]
    call streq
    test eax, eax
    jz .Lnative_option_return
    lea r12, [rip + native_library_count]
    lea r13, [rip + native_library_dirs]
    jmp .Lnative_option_directory
.Lnative_option_include:
    lea r12, [rip + native_include_count]
    lea r13, [rip + native_include_dirs]
.Lnative_option_directory:
    cmp byte ptr [rip + native_allow], 0
    je bad_args
    cmp qword ptr [r12], 8
    jae bad_args
    call next_arg
    test rax, rax
    jz bad_args
    mov rbx, rax
    cmp byte ptr [rbx], '/'
    jne bad_args
    xor ecx, ecx
.Lnative_directory_character:
    mov al, [rbx + rcx]
    test al, al
    jz .Lnative_directory_ready
    cmp ecx, 255
    jae bad_args
    cmp al, 32
    jb bad_args
    cmp al, 126
    ja bad_args
    cmp al, ':'
    je bad_args
    cmp al, ','
    je bad_args
    inc ecx
    jmp .Lnative_directory_character
.Lnative_directory_ready:
    mov rax, [r12]
    mov [r13 + rax*8], rbx
    inc qword ptr [r12]
    mov eax, 1
.Lnative_option_return:
    pop r13
    pop r12
    pop rbx
    ret

/* Input: validated package buffers and parsed option counts. No output or
 * memory changes. Non-C builds with directory options exit with bad_args.
 * Scratch: flags only. Stack:none; no external calls. */
native_link_check_options:
    cmp byte ptr [rip + package_link], 0
    jne .Lnative_options_valid
    cmp qword ptr [rip + native_include_count], 0
    jne bad_args
    cmp qword ptr [rip + native_library_count], 0
    jne bad_args
.Lnative_options_valid:
    ret

/* Input: parsed package_check and include-directory pointers. Output:EAX is
 * the compiler status, or zero if absent. Fixed /usr/bin/cc receives only the
 * native_tool_env entries. It performs syntax checks and executes no package
 * checker. Shared argv holds 64 pointers; this path needs at most 24. Scratch:
 * caller-saved. Preserves callee-saved registers. Stack:24 plus callees. */
native_link_compile_check:
    cmp byte ptr [rip + package_check], 0
    je .Lnative_no_check
    push rbx
    push r12
    push r13
    xor r12d, r12d
    lea rax, [rip + native_cc_path]
    call native_argv_add
    lea rax, [rip + native_syntax_only]
    call native_argv_add
    lea rax, [rip + native_c11]
    call native_argv_add
    lea rax, [rip + native_wall]
    call native_argv_add
    lea rax, [rip + native_wextra]
    call native_argv_add
    lea rax, [rip + native_werror]
    call native_argv_add
    xor r13d, r13d
.Lnative_check_include:
    cmp r13, [rip + native_include_count]
    jae .Lnative_check_source
    lea rax, [rip + arg_I]
    call native_argv_add
    lea rbx, [rip + native_include_dirs]
    mov rax, [rbx + r13*8]
    call native_argv_add
    inc r13
    jmp .Lnative_check_include
.Lnative_check_source:
    lea rax, [rip + package_check]
    call native_argv_add
    call native_cc_spawn
    pop r13
    pop r12
    pop rbx
    ret
.Lnative_no_check:
    xor eax, eax
    ret

/* Input: stage_object and stage_binary name private stage files; all manifest
 * fields and directory options were validated. Output:EAX=compiler status.
 * Links with the system C ABI and hardening. No checker or application runs.
 * Each directory uses a 272-byte rpath buffer; each library uses 34 bytes.
 * Shared argv has 64 slots; at most 40 are used, including its final NUL.
 * Preserves callee-saved registers. Stack:24 bytes plus bounded callees. */
native_link_build:
    push rbx
    push r12
    push r13
    xor r12d, r12d
    lea rax, [rip + native_cc_path]
    call native_argv_add
    lea rax, [rip + native_fpie]
    call native_argv_add
    lea rax, [rip + native_pie]
    call native_argv_add
    lea rax, [rip + native_hardening]
    call native_argv_add
    lea rax, [rip + arg_o]
    call native_argv_add
    lea rax, [rip + stage_binary]
    call native_argv_add
    lea rax, [rip + stage_object]
    call native_argv_add
    xor r13d, r13d
.Lnative_link_directory:
    cmp r13, [rip + native_library_count]
    jae .Lnative_link_libraries
    lea rax, [rip + native_arg_L]
    call native_argv_add
    lea rbx, [rip + native_library_dirs]
    mov rax, [rbx + r13*8]
    call native_argv_add
    imul rax, r13, 272
    lea rbx, [rip + native_rpath_args]
    add rbx, rax
    mov rdi, rbx
    lea rsi, [rip + native_rpath_prefix]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + native_library_dirs]
    mov rsi, [rsi + r13*8]
    call copy_string
    mov rax, rbx
    call native_argv_add
    inc r13
    jmp .Lnative_link_directory
.Lnative_link_libraries:
    lea rbx, [rip + package_libraries]
    xor r13d, r13d
.Lnative_link_library:
    cmp byte ptr [rbx], 0
    je .Lnative_link_spawn
    imul rax, r13, 34
    lea r10, [rip + native_library_args]
    add r10, rax
    mov word ptr [r10], 0x6c2d
    mov ecx, 2
.Lnative_link_library_copy:
    mov al, [rbx]
    test al, al
    jz .Lnative_link_library_end
    cmp al, ' '
    je .Lnative_link_library_separator
    mov [r10 + rcx], al
    inc ecx
    inc rbx
    jmp .Lnative_link_library_copy
.Lnative_link_library_separator:
    inc rbx
.Lnative_link_library_end:
    mov byte ptr [r10 + rcx], 0
    mov rax, r10
    call native_argv_add
    inc r13
    jmp .Lnative_link_library
.Lnative_link_spawn:
    call native_cc_spawn
    pop r13
    pop r12
    pop rbx
    ret

/* Private argv builder. Input:RAX=borrowed string, R12=current pointer count
 * proven below 63. Output:R12 increments. Scratch:RCX. Stack:none. */
native_argv_add:
    lea rcx, [rip + native_cc_argv]
    mov [rcx + r12*8], rax
    inc r12
    ret

/* Input:R12=argument count <=63. Terminates owned argv and invokes fixed cc.
 * Output:EAX=child status. Scratch:caller-saved; stack:8 plus spawn_wait. */
native_cc_spawn:
    lea rsi, [rip + native_cc_argv]
    mov qword ptr [rsi + r12*8], 0
    lea rdi, [rip + native_cc_path]
    sub rsp, 8
    call spawn_wait
    add rsp, 8
    ret

.section .rodata
native_key_link: .asciz "link"
native_key_libraries: .asciz "libraries"
native_key_check: .asciz "check"
native_opt_include: .asciz "--include-dir"
native_opt_library: .asciz "--library-dir"
native_cc_path: .asciz "/usr/bin/cc"
native_syntax_only: .asciz "-fsyntax-only"
native_c11: .asciz "-std=c11"
native_wall: .asciz "-Wall"
native_wextra: .asciz "-Wextra"
native_werror: .asciz "-Werror"
native_fpie: .asciz "-fPIE"
native_pie: .asciz "-pie"
native_hardening: .asciz "-Wl,-z,relro,-z,now,-z,noexecstack"
native_arg_L: .asciz "-L"
native_rpath_prefix: .asciz "-Wl,-rpath,"
native_env_path: .asciz "PATH=/usr/bin:/bin"
native_env_locale: .asciz "LC_ALL=C"
.balign 8
native_tool_env: .quad native_env_path, native_env_locale, 0

.section .bss
.balign 8
package_link: .skip 256
package_libraries: .skip 256
package_check: .skip 256
native_include_count: .skip 8
native_library_count: .skip 8
native_include_dirs: .skip 64
native_library_dirs: .skip 64
native_cc_argv: .skip 512
native_rpath_args: .skip 2176
native_library_args: .skip 272
native_allow: .skip 1
