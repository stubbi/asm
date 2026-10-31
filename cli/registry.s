.intel_syntax noprefix
.global cmd_search, cmd_info, cmd_versions, cmd_fetch
.extern next_arg, streq, strlen, copy_string, out, write_cstr, write_all
.extern die, exit_ok, exit_code, spawn_wait, unsigned_decimal
.extern create_exclusive_file, json_mode

/* Registry v1 is a bounded TSV protocol. All parsing and decisions are native
 * assembly. curl supplies HTTPS; sha256sum supplies the digest implementation.
 * Package contents are never extracted or executed by fetch.
 * ABI: returning routines preserve RBX, RBP and R12-R15. RAX, RCX, RDX, RSI,
 * RDI and R8-R11 are scratch unless a narrower set is stated. Command/error
 * labels do not return. The executable uses Linux x86-64 syscalls, not libc.
 * Each borrowed string must end in accessible NUL memory. argv comes from the
 * kernel. Index strings are bounded and terminated by registry_parse_index.
 */
.equ INDEX_LIMIT, 1048576
.equ ROW_LIMIT, 4096
.equ ARTIFACT_LIMIT, 67108864
.equ O_NOFOLLOW, 131072
.equ O_CLOEXEC, 524288
.equ AT_FDCWD, -100

.section .text
cmd_search:
    mov byte ptr [rip + registry_mode], 1
    jmp registry_command
cmd_info:
    mov byte ptr [rip + registry_mode], 2
    jmp registry_command
cmd_versions:
    mov byte ptr [rip + registry_mode], 3
    jmp registry_command
cmd_fetch:
    mov byte ptr [rip + registry_mode], 4
/* Command entry: global argv cursor follows the command name. Parses options
 * before filesystem/network work. Owns the global registry_* buffers for the
 * process lifetime. Commands terminate the process; no caller stack survives. */
registry_command:
    lea rax, [rip + registry_default_url]
    mov [rip + registry_url], rax
    lea rax, [rip + registry_host]
    mov [rip + registry_target], rax
    lea rax, [rip + registry_source_kind]
    mov [rip + registry_kind], rax
    lea rax, [rip + registry_empty]
    mov [rip + registry_query], rax
.Lregistry_args:
    call next_arg
    test rax, rax
    jz .Lregistry_args_done
    mov r12, rax
    cmp byte ptr [rip + registry_literal], 0
    jne .Lregistry_query_arg
    mov rdi, r12
    lea rsi, [rip + registry_opt_json]
    call streq
    test eax, eax
    jnz .Lregistry_arg_json
    mov rdi, r12
    lea rsi, [rip + registry_opt_no_color]
    call streq
    test eax, eax
    jnz .Lregistry_args
    mov rdi, r12
    lea rsi, [rip + registry_opt_help]
    call streq
    test eax, eax
    jnz registry_help
    mov rdi, r12
    lea rsi, [rip + registry_separator]
    call streq
    test eax, eax
    jnz .Lregistry_arg_separator
    mov rdi, r12
    lea rsi, [rip + registry_opt_index]
    call streq
    test eax, eax
    jnz .Lregistry_arg_index
    mov rdi, r12
    lea rsi, [rip + registry_opt_registry]
    call streq
    test eax, eax
    jnz .Lregistry_arg_registry
    mov rdi, r12
    lea rsi, [rip + registry_opt_target]
    call streq
    test eax, eax
    jnz .Lregistry_arg_target
    mov rdi, r12
    lea rsi, [rip + registry_opt_kind]
    call streq
    test eax, eax
    jnz .Lregistry_arg_kind
    mov rdi, r12
    lea rsi, [rip + registry_opt_output]
    call streq
    test eax, eax
    jnz .Lregistry_arg_output
    mov rdi, r12
    lea rsi, [rip + registry_opt_artifact]
    call streq
    test eax, eax
    jnz .Lregistry_arg_artifact
    cmp byte ptr [r12], '-'
    je registry_bad_args
.Lregistry_query_arg:
    cmp byte ptr [rip + registry_has_query], 0
    jne registry_bad_args
    mov rdi, r12
    call strlen
    cmp rax, 168
    ja registry_bad_args
    mov [rip + registry_query], r12
    mov byte ptr [rip + registry_has_query], 1
    jmp .Lregistry_args
.Lregistry_arg_json:
    mov byte ptr [rip + json_mode], 1
    jmp .Lregistry_args
.Lregistry_arg_separator:
    mov byte ptr [rip + registry_literal], 1
    jmp .Lregistry_args
.Lregistry_arg_index:
    cmp byte ptr [rip + registry_origin_seen], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + registry_index_path], rax
    mov byte ptr [rip + registry_origin_seen], 1
    jmp .Lregistry_args
.Lregistry_arg_registry:
    cmp byte ptr [rip + registry_origin_seen], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + registry_url], rax
    mov rdi, rax
    call registry_https_url
    test eax, eax
    jz registry_bad_args
    mov byte ptr [rip + registry_origin_seen], 1
    jmp .Lregistry_args
.Lregistry_arg_target:
    call registry_arg_value
    mov [rip + registry_target], rax
    mov rdi, rax
    call registry_valid_target
    test eax, eax
    jz registry_bad_args
    jmp .Lregistry_args
.Lregistry_arg_kind:
    call registry_arg_value
    mov [rip + registry_kind], rax
    mov rdi, rax
    call registry_valid_kind
    test eax, eax
    jz registry_bad_args
    jmp .Lregistry_args
.Lregistry_arg_output:
    cmp qword ptr [rip + registry_output], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + registry_output], rax
    jmp .Lregistry_args
.Lregistry_arg_artifact:
    cmp qword ptr [rip + registry_local_artifact], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + registry_local_artifact], rax
    jmp .Lregistry_args
.Lregistry_args_done:
    cmp byte ptr [rip + registry_mode], 4
    je .Lregistry_fetch_args
    cmp qword ptr [rip + registry_output], 0
    jne registry_bad_args
    cmp qword ptr [rip + registry_local_artifact], 0
    jne registry_bad_args
    cmp byte ptr [rip + registry_mode], 1
    je .Lregistry_load
    mov rdi, [rip + registry_query]
    call registry_valid_package
    test eax, eax
    jz registry_bad_args
    jmp .Lregistry_load
.Lregistry_fetch_args:
    lea rdi, [rip + registry_selector]
    mov rsi, [rip + registry_query]
    call copy_string
    lea rdi, [rip + registry_selector]
    mov [rip + registry_query], rdi
    mov rsi, rdi
.Lselector_scan:
    mov al, [rsi]
    test al, al
    jz .Lselector_package
    cmp al, '@'
    je .Lselector_version
    inc rsi
    jmp .Lselector_scan
.Lselector_version:
    mov byte ptr [rsi], 0
    inc rsi
    mov [rip + registry_exact_version], rsi
    mov rdi, rsi
    call registry_valid_version
    test eax, eax
    jz registry_bad_args
.Lselector_package:
    mov rdi, [rip + registry_query]
    call registry_valid_package
    test eax, eax
    jz registry_bad_args
.Lregistry_load:
    cmp qword ptr [rip + registry_index_path], 0
    jne .Lregistry_read
    call registry_workspace
    mov rdi, [rip + registry_url]
    lea rsi, [rip + registry_temp_index]
    lea rdx, [rip + registry_index_max]
    call registry_download
    test eax, eax
    jnz registry_download_error
    lea rax, [rip + registry_temp_index]
    mov [rip + registry_index_path], rax
.Lregistry_read:
    call registry_read_index
    call registry_parse_index
    cmp byte ptr [rip + registry_mode], 4
    je registry_fetch
    jmp registry_list

/* Input: argv cursor follows a value option. Output: RAX=borrowed nonempty
 * string <=4095 bytes. Advances the cursor; exits 2 if absent or out of bounds.
 * Stack: one saved pointer. No filesystem or network effect. */
registry_arg_value:
    call next_arg
    test rax, rax
    jz registry_bad_args
    mov rdi, rax
    push rax
    call strlen
    test rax, rax
    jz registry_bad_args
    cmp rax, 4095
    ja registry_bad_args
    pop rax
    ret
registry_help:
    lea rdi, [rip + registry_help_text]
    call out
    jmp exit_ok
registry_bad_args:
    lea rdi, [rip + registry_err_args]
    mov esi, 2
    jmp registry_fail
registry_bad_index:
    lea rdi, [rip + registry_err_index]
    mov esi, 1
    jmp registry_fail
registry_download_error:
    lea rdi, [rip + registry_err_download]
    mov esi, 1
    jmp registry_fail
registry_io_error:
    lea rdi, [rip + registry_err_io]
    mov esi, 1
    jmp registry_fail
registry_not_found:
    lea rdi, [rip + registry_err_not_found]
    mov esi, 1
    jmp registry_fail
/* Input: RDI=static JSON-safe error, ESI=status 1..255. Removes owned temporary
 * files before calling die. No return. Stack: saves the two inputs (16 bytes). */
registry_fail:
    push rdi
    push rsi
    call registry_cleanup
    pop rsi
    pop rdi
    jmp die

/* Input: current working directory. Creates mode-0700 .asm-registry-<pid> only
 * if absent. Output: owned workspace and its three fixed paths, or fatal error.
 * Buffer capacities: directory=64, file paths=96; PID is <=20 decimal digits.
 * An existing path is never reused. Stack: one saved append pointer. */
registry_workspace:
    cmp byte ptr [rip + registry_has_workspace], 0
    jne .Lworkspace_done
    lea rdi, [rip + registry_temp_dir]
    lea rsi, [rip + registry_temp_prefix]
    call copy_string
    push rax
    mov eax, 39
    syscall
    mov rdi, rax
    lea rsi, [rip + registry_number_buffer + 31]
    call unsigned_decimal
    mov rsi, rax
    pop rdi
    call copy_string
    mov eax, 83
    lea rdi, [rip + registry_temp_dir]
    mov esi, 448
    syscall
    test rax, rax
    js registry_io_error
    mov byte ptr [rip + registry_has_workspace], 1
    lea rdi, [rip + registry_temp_index]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_index_suffix]
    call copy_string
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_payload_suffix]
    call copy_string
    lea rdi, [rip + registry_temp_checksum]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_checksum_suffix]
    call copy_string
.Lworkspace_done:
    ret

/* Input: ownership flag and fixed workspace paths. Unlinks only index, payload
 * and checksum, then removes the empty directory. Clears the ownership flag.
 * Does not replace an original error with a cleanup error. Stack: none. */
registry_cleanup:
    cmp byte ptr [rip + registry_has_workspace], 0
    je .Lcleanup_done
    mov eax, 87
    lea rdi, [rip + registry_temp_index]
    syscall
    mov eax, 87
    lea rdi, [rip + registry_temp_payload]
    syscall
    mov eax, 87
    lea rdi, [rip + registry_temp_checksum]
    syscall
    mov eax, 84
    lea rdi, [rip + registry_temp_dir]
    syscall
    mov byte ptr [rip + registry_has_workspace], 0
.Lcleanup_done:
    ret

/* curl's config is disabled before all other options. Protocol and redirects
 * remain HTTPS-only. The caller supplies a validated URL and a bounded size. */
/* Input: RDI=URL (<=4095 chars), RSI=owned temporary output path (<=95 chars),
 * RDX=decimal maximum bytes (1..67108864). Output: EAX=child status; missing
 * curl exits 127. Writes a fixed 23-pointer argv array. Tail-calls spawn_wait. */
registry_download:
    mov [rip + registry_curl_argv + 21*8], rdi
    mov [rip + registry_curl_argv + 19*8], rsi
    mov [rip + registry_curl_argv + 17*8], rdx
    mov eax, 21
    lea rdi, [rip + registry_curl]
    mov esi, 1
    syscall
    test rax, rax
    js .Lcurl_missing
    lea rdi, [rip + registry_curl]
    lea rsi, [rip + registry_curl_argv]
    jmp spawn_wait
.Lcurl_missing:
    lea rdi, [rip + registry_err_curl]
    mov esi, 127
    jmp registry_fail

/* Input: registry_index_path. Reads only a regular non-symlink file, bounded to
 * 1 MiB. Output: index bytes plus NUL, registry_index_end exclusive. Retries
 * EINTR/short reads; growth beyond the bound fails. Stack: 16 saved bytes. */
registry_read_index:
    push r12
    push r13
    mov eax, 2
    mov rdi, [rip + registry_index_path]
    mov esi, O_NOFOLLOW + O_CLOEXEC
    xor edx, edx
    syscall
    test rax, rax
    js registry_io_error
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    js .Lindex_read_error
    mov eax, [rip + registry_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lindex_read_error
    cmp qword ptr [rip + registry_stat + 48], INDEX_LIMIT
    ja .Lindex_read_error
    xor r13d, r13d
.Lindex_read_loop:
    xor eax, eax
    mov rdi, r12
    lea rsi, [rip + registry_index]
    add rsi, r13
    mov edx, INDEX_LIMIT + 1
    sub rdx, r13
    syscall
    cmp rax, -4
    je .Lindex_read_loop
    test rax, rax
    js .Lindex_read_error
    jz .Lindex_read_done
    add r13, rax
    cmp r13, INDEX_LIMIT
    ja .Lindex_read_error
    jmp .Lindex_read_loop
.Lindex_read_done:
    mov eax, 3
    mov rdi, r12
    syscall
    lea rax, [rip + registry_index]
    mov byte ptr [rax + r13], 0
    add rax, r13
    mov [rip + registry_index_end], rax
    pop r13
    pop r12
    ret
.Lindex_read_error:
    mov eax, 3
    mov rdi, r12
    syscall
    jmp registry_bad_index

/* Input: bounded index/end from registry_read_index. Output: <=4096 records,
 * each eight borrowed pointers into index. Replaces TAB/LF with NUL. Rejects
 * invalid headers, controls, non-ASCII, missing LF, >2048-byte rows, malformed
 * fields and duplicate artifact identities before any result is printed.
 * Capacity: registry_rows=4096*64 bytes. Stack: 32 saved bytes plus calls. */
registry_parse_index:
    push r12
    push r13
    push r14
    push r15
    lea r12, [rip + registry_index]
    lea rsi, [rip + registry_header]
    xor ecx, ecx
.Lindex_header:
    mov al, [rsi + rcx]
    test al, al
    jz .Lindex_header_done
    cmp al, [r12 + rcx]
    jne registry_bad_index
    inc ecx
    jmp .Lindex_header
.Lindex_header_done:
    add r12, rcx
.Lindex_row:
    cmp r12, [rip + registry_index_end]
    je .Lindex_parsed
    ja registry_bad_index
    mov rax, [rip + registry_row_count]
    cmp rax, ROW_LIMIT
    jae registry_bad_index
    shl rax, 6
    lea r13, [rip + registry_rows]
    add r13, rax
    mov [r13], r12
    xor r14d, r14d
    mov r15, r12
.Lindex_char:
    cmp r12, [rip + registry_index_end]
    jae registry_bad_index
    mov rax, r12
    sub rax, r15
    cmp rax, 2048
    jae registry_bad_index
    mov al, [r12]
    cmp al, 9
    je .Lindex_tab
    cmp al, 10
    je .Lindex_newline
    cmp al, 32
    jb registry_bad_index
    cmp al, 127
    jae registry_bad_index
    inc r12
    jmp .Lindex_char
.Lindex_tab:
    cmp r14d, 7
    jae registry_bad_index
    mov byte ptr [r12], 0
    inc r12
    inc r14d
    mov [r13 + r14*8], r12
    jmp .Lindex_char
.Lindex_newline:
    cmp r14d, 7
    jne registry_bad_index
    mov byte ptr [r12], 0
    inc r12
    mov rdi, r13
    call registry_validate_row
    inc qword ptr [rip + registry_row_count]
    jmp .Lindex_row
.Lindex_parsed:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

/* Input: RDI points to eight bounded, NUL-terminated field pointers. Output:
 * returns only for a valid row unique against prior registry_rows. Otherwise
 * exits before a fetch. Scratch: index is unchanged. Stack: up to 24 bytes. */
registry_validate_row:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call registry_valid_package
    test eax, eax
    jz registry_bad_index
    mov rdi, [rbx + 8]
    call registry_valid_version
    test eax, eax
    jz registry_bad_index
    mov rdi, [rbx + 16]
    call registry_valid_target
    test eax, eax
    jz registry_bad_index
    mov rdi, [rbx + 24]
    call registry_valid_kind
    test eax, eax
    jz registry_bad_index
    mov rdi, [rbx + 32]
    xor ecx, ecx
.Lhash_validate:
    mov al, [rdi + rcx]
    cmp al, '0'
    jb registry_bad_index
    cmp al, '9'
    jbe .Lhash_next
    cmp al, 'a'
    jb registry_bad_index
    cmp al, 'f'
    ja registry_bad_index
.Lhash_next:
    inc ecx
    cmp ecx, 64
    jb .Lhash_validate
    cmp byte ptr [rdi + 64], 0
    jne registry_bad_index
    mov rdi, [rbx + 40]
    call registry_release_url
    test eax, eax
    jz registry_bad_index
    mov rdi, [rbx + 48]
    call registry_size_value
    test rax, rax
    jz registry_bad_index
    mov rdi, [rbx + 56]
    call strlen
    test rax, rax
    jz registry_bad_index
    cmp rax, 160
    ja registry_bad_index
    /* A duplicate artifact identity must never choose an arbitrary digest. */
    push r12
    push r13
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Lduplicate_row:
    cmp r13, [rip + registry_row_count]
    jae .Lrow_valid
    mov rdi, [rbx]
    mov rsi, [r12]
    call streq
    test eax, eax
    jz .Lduplicate_next
    mov rdi, [rbx + 8]
    mov rsi, [r12 + 8]
    call streq
    test eax, eax
    jz .Lduplicate_next
    mov rdi, [rbx + 16]
    mov rsi, [r12 + 16]
    call streq
    test eax, eax
    jz .Lduplicate_next
    mov rdi, [rbx + 24]
    mov rsi, [r12 + 24]
    call streq
    test eax, eax
    jnz registry_bad_index
.Lduplicate_next:
    add r12, 64
    inc r13
    jmp .Lduplicate_row
.Lrow_valid:
    pop r13
    pop r12
    pop rbx
    ret

/* A namespace component is lowercase, does not end in '-' and has no '--'. */
/* Input: RDI=component, ESI=max length (39 or 64). Ends at '/' or NUL. Output:
 * EAX=length on success, zero on failure. Scratch: RAX/RCX/RDX. Stack: none. */
registry_component:
    mov al, [rdi]
    cmp al, 'a'
    jb registry_invalid
    cmp al, 'z'
    ja registry_invalid
    xor ecx, ecx
    xor edx, edx
.Lcomponent_loop:
    mov al, [rdi + rcx]
    test al, al
    jz .Lcomponent_end
    cmp al, '/'
    je .Lcomponent_end
    cmp ecx, esi
    jae registry_invalid
    cmp al, '-'
    je .Lcomponent_dash
    xor edx, edx
    cmp al, '0'
    jb registry_invalid
    cmp al, '9'
    jbe .Lcomponent_next
    cmp al, 'a'
    jb registry_invalid
    cmp al, 'z'
    ja registry_invalid
    jmp .Lcomponent_next
.Lcomponent_dash:
    test edx, edx
    jnz registry_invalid
    mov edx, 1
.Lcomponent_next:
    inc ecx
    jmp .Lcomponent_loop
.Lcomponent_end:
    test edx, edx
    jnz registry_invalid
    mov eax, ecx
    ret
/* Input: RDI=package string. Output: EAX=1 for owner/name, else zero. Owner is
 * <=39 chars, name <=64 chars; exactly one slash. Stack: one saved pointer. */
registry_valid_package:
    push rdi
    mov esi, 39
    call registry_component
    pop rdi
    test eax, eax
    jz registry_invalid
    cmp byte ptr [rdi + rax], '/'
    jne registry_invalid
    lea rdi, [rdi + rax + 1]
    push rdi
    mov esi, 64
    call registry_component
    pop rdi
    test eax, eax
    jz registry_invalid
    cmp byte ptr [rdi + rax], 0
    jne registry_invalid
    jmp registry_valid

/* Input: RDI=version. Output: EAX=1 for exactly three decimal components, each
 * <=2147483647, no leading zeroes. Maximum accepted length is 32. No overflow:
 * each multiply starts from a value <=2147483647. Stack: none. */
registry_valid_version:
    xor ecx, ecx
    xor r8d, r8d
.Lreg_version_component:
    xor edx, edx
    mov al, [rdi + rcx]
    cmp al, '0'
    jb registry_invalid
    cmp al, '9'
    ja registry_invalid
    cmp al, '0'
    je .Lreg_version_zero
.Lreg_version_digit:
    movzx eax, byte ptr [rdi + rcx]
    cmp al, '0'
    jb .Lreg_version_separator
    cmp al, '9'
    ja .Lreg_version_separator
    sub eax, '0'
    imul rdx, rdx, 10
    add rdx, rax
    cmp rdx, 2147483647
    ja registry_invalid
    inc ecx
    jmp .Lreg_version_digit
.Lreg_version_zero:
    inc ecx
.Lreg_version_separator:
    mov al, [rdi + rcx]
    test al, al
    jz .Lreg_version_end
    cmp al, '.'
    jne registry_invalid
    inc r8d
    cmp r8d, 2
    ja registry_invalid
    inc ecx
    jmp .Lreg_version_component
.Lreg_version_end:
    cmp r8d, 2
    jne registry_invalid
    jmp registry_valid

/* Input: RDI=string. Output: EAX=1 only for one of the three published targets.
 * This is artifact selection, not a claim that the host can execute it. */
registry_valid_target:
    push rdi
    lea rsi, [rip + registry_host]
    call streq
    pop rdi
    test eax, eax
    jnz registry_valid
    push rdi
    lea rsi, [rip + registry_aarch64]
    call streq
    pop rdi
    test eax, eax
    jnz registry_valid
    lea rsi, [rip + registry_riscv64]
    jmp streq
/* Input: RDI=string. Output: EAX=1 for source/executable, else zero.
 * Stack: one saved pointer. Does not authorize execution. */
registry_valid_kind:
    push rdi
    lea rsi, [rip + registry_source_kind]
    call streq
    pop rdi
    test eax, eax
    jnz registry_valid
    lea rsi, [rip + registry_executable_kind]
    jmp streq

/* Input: RDI=decimal string. Output: RAX=size 1..64 MiB, or zero on failure.
 * Rejects signs and leading zeroes. Checks each multiply against the bound.
 * Scratch: RAX/RCX/RDX. Stack: none. */
registry_size_value:
    xor eax, eax
    xor ecx, ecx
    cmp byte ptr [rdi], '1'
    jb registry_invalid
    cmp byte ptr [rdi], '9'
    ja registry_invalid
.Lsize_digit:
    movzx edx, byte ptr [rdi + rcx]
    test edx, edx
    jz .Lsize_done
    cmp edx, '0'
    jb registry_invalid
    cmp edx, '9'
    ja registry_invalid
    sub edx, '0'
    imul rax, rax, 10
    add rax, rdx
    cmp rax, ARTIFACT_LIMIT
    ja registry_invalid
    inc ecx
    jmp .Lsize_digit
.Lsize_done:
    ret

/* Input: RDI=index URL already bounded to 4095 chars. Output: EAX=1 for a
 * nonempty HTTPS URL with printable bytes and no userinfo/backslash, else zero.
 * This permits a user-selected registry origin; it is not artifact policy. */
registry_https_url:
    lea rsi, [rip + registry_https_prefix]
    xor ecx, ecx
.Lhttps_prefix:
    mov al, [rsi + rcx]
    test al, al
    jz .Lhttps_body
    cmp al, [rdi + rcx]
    jne registry_invalid
    inc ecx
    jmp .Lhttps_prefix
.Lhttps_body:
    cmp byte ptr [rdi + rcx], 0
    je registry_invalid
.Lhttps_char:
    mov al, [rdi + rcx]
    test al, al
    jz registry_valid
    cmp al, 33
    jb registry_invalid
    cmp al, 126
    ja registry_invalid
    cmp al, '@'
    je registry_invalid
    cmp al, '\\'
    je registry_invalid
    inc ecx
    jmp .Lhttps_char

/* GitHub release URLs have exactly six path components. Restrict the alphabet
 * and reject dot components, query strings, fragments and percent encoding. */
/* Input: RDI=bounded artifact URL. Output: EAX=1 or zero. Read-only validation;
 * the release URL does not establish namespace ownership. Stack: none. */
registry_release_url:
    lea rsi, [rip + registry_github_prefix]
    xor ecx, ecx
.Lrelease_prefix:
    mov al, [rsi + rcx]
    test al, al
    jz .Lrelease_path
    cmp al, [rdi + rcx]
    jne registry_invalid
    inc ecx
    jmp .Lrelease_prefix
.Lrelease_path:
    add rdi, rcx
    xor r8d, r8d
    mov r9, rdi
    xor ecx, ecx
.Lrelease_char:
    mov al, [rdi + rcx]
    test al, al
    jz .Lrelease_segment
    cmp al, '/'
    je .Lrelease_segment
    cmp al, '-'
    je .Lrelease_next
    cmp al, '_'
    je .Lrelease_next
    cmp al, '.'
    je .Lrelease_next
    cmp al, '+'
    je .Lrelease_next
    cmp al, '0'
    jb registry_invalid
    cmp al, '9'
    jbe .Lrelease_next
    cmp al, 'A'
    jb registry_invalid
    cmp al, 'Z'
    jbe .Lrelease_next
    cmp al, 'a'
    jb registry_invalid
    cmp al, 'z'
    ja registry_invalid
.Lrelease_next:
    inc ecx
    cmp ecx, 2048
    ja registry_invalid
    jmp .Lrelease_char
.Lrelease_segment:
    lea r10, [rdi + rcx]
    mov r11, r10
    sub r11, r9
    test r11, r11
    jz registry_invalid
    cmp byte ptr [r9], '.'
    jne .Lrelease_check_label
    cmp r11, 1
    je registry_invalid
    cmp r11, 2
    jne .Lrelease_check_label
    cmp byte ptr [r9 + 1], '.'
    je registry_invalid
.Lrelease_check_label:
    inc r8d
    cmp r8d, 3
    je .Lrelease_label_releases
    cmp r8d, 4
    je .Lrelease_label_download
    jmp .Lrelease_delimiter
.Lrelease_label_releases:
    cmp r11, 8
    jne registry_invalid
    mov rdx, 0x73657361656c6572
    cmp [r9], rdx
    jne registry_invalid
    jmp .Lrelease_delimiter
.Lrelease_label_download:
    cmp r11, 8
    jne registry_invalid
    mov rdx, 0x64616f6c6e776f64
    cmp [r9], rdx
    jne registry_invalid
.Lrelease_delimiter:
    test al, al
    jz .Lrelease_end
    cmp r8d, 6
    jae registry_invalid
    lea r9, [r10 + 1]
    inc ecx
    jmp .Lrelease_char
.Lrelease_end:
    cmp r8d, 6
    jne registry_invalid
    jmp registry_valid
registry_valid:
    mov eax, 1
    ret
registry_invalid:
    xor eax, eax
    ret

/* Terminal command: uses validated registry_rows. search matches package or
 * summary; info matches a package; versions suppresses duplicate versions.
 * Emits plain TSV or one JSON object. Cleans the workspace before exit. */
registry_list:
    cmp byte ptr [rip + json_mode], 0
    je .Llist_start
    lea rdi, [rip + registry_results_prefix]
    cmp byte ptr [rip + registry_mode], 3
    jne .Llist_prefix
    lea rdi, [rip + registry_versions_prefix]
.Llist_prefix:
    call out
.Llist_start:
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Llist_row:
    cmp r13, [rip + registry_row_count]
    jae .Llist_done
    mov rdi, [r12]
    mov rsi, [rip + registry_query]
    cmp byte ptr [rip + registry_mode], 1
    je .Llist_search
    call streq
    test eax, eax
    jz .Llist_next
    cmp byte ptr [rip + registry_mode], 3
    jne .Llist_match
    call registry_version_seen
    test eax, eax
    jnz .Llist_next
    jmp .Llist_match
.Llist_search:
    call registry_contains
    test eax, eax
    jnz .Llist_match
    mov rdi, [r12 + 56]
    mov rsi, [rip + registry_query]
    call registry_contains
    test eax, eax
    jz .Llist_next
.Llist_match:
    cmp byte ptr [rip + json_mode], 0
    je .Llist_human
    cmp qword ptr [rip + registry_matches], 0
    je .Llist_json_row
    lea rdi, [rip + registry_comma]
    call out
.Llist_json_row:
    cmp byte ptr [rip + registry_mode], 3
    je .Llist_json_version
    mov rdi, r12
    call registry_print_json_row
    jmp .Llist_count
.Llist_json_version:
    mov rdi, [r12 + 8]
    call registry_json_string
    jmp .Llist_count
.Llist_human:
    cmp byte ptr [rip + registry_mode], 3
    je .Llist_human_version
    mov rdi, r12
    call registry_print_text_row
    jmp .Llist_count
.Llist_human_version:
    mov rdi, [r12 + 8]
    call out
    lea rdi, [rip + registry_newline]
    call out
.Llist_count:
    inc qword ptr [rip + registry_matches]
.Llist_next:
    add r12, 64
    inc r13
    jmp .Llist_row
.Llist_done:
    cmp byte ptr [rip + json_mode], 0
    je .Llist_finish
    lea rdi, [rip + registry_results_suffix]
    call out
.Llist_finish:
    call registry_cleanup
    cmp qword ptr [rip + registry_matches], 0
    jne exit_ok
    cmp byte ptr [rip + registry_mode], 1
    jne registry_not_found
    cmp byte ptr [rip + json_mode], 0
    jne exit_ok
    lea rdi, [rip + registry_no_matches]
    call out
    jmp exit_ok

/* Input: RDI=haystack, RSI=needle, both bounded strings. Output: EAX=1 for a
 * case-sensitive substring (including empty needle), else zero. Read-only.
 * Scratch: RAX/RCX/R8. Stack: none. */
registry_contains:
    cmp byte ptr [rsi], 0
    je registry_valid
    mov r8, rdi
.Lcontains_start:
    cmp byte ptr [r8], 0
    je registry_invalid
    xor ecx, ecx
.Lcontains_chars:
    mov al, [rsi + rcx]
    test al, al
    jz registry_valid
    cmp al, [r8 + rcx]
    jne .Lcontains_next
    inc ecx
    jmp .Lcontains_chars
.Lcontains_next:
    inc r8
    jmp .Lcontains_start

/* Current row is r12. Suppress versions already printed for this package. */
/* Input: R12=current row in registry_rows. Output: EAX=1 if an earlier row has
 * the same package and version. Read-only; scan ends before R12. Stack: 8 bytes. */
registry_version_seen:
    push rbx
    lea rbx, [rip + registry_rows]
.Lversion_seen_row:
    cmp rbx, r12
    jae .Lversion_unseen
    mov rdi, [rbx]
    mov rsi, [r12]
    call streq
    test eax, eax
    jz .Lversion_seen_next
    mov rdi, [rbx + 8]
    mov rsi, [r12 + 8]
    call streq
    test eax, eax
    jnz .Lversion_seen_return
.Lversion_seen_next:
    add rbx, 64
    jmp .Lversion_seen_row
.Lversion_unseen:
    xor eax, eax
.Lversion_seen_return:
    pop rbx
    ret

/* Input: RDI=validated eight-pointer record. Writes one TSV row to stdout.
 * Record fields contain no tabs or controls. Stack: 16 saved bytes plus calls. */
registry_print_text_row:
    push rbx
    push r14
    mov rbx, rdi
    xor r14d, r14d
.Ltext_field:
    test r14d, r14d
    jz .Ltext_value
    lea rdi, [rip + registry_tab]
    call out
.Ltext_value:
    mov rdi, [rbx + r14*8]
    call out
    inc r14d
    cmp r14d, 8
    jb .Ltext_field
    lea rdi, [rip + registry_newline]
    call out
    pop r14
    pop rbx
    ret

/* Input: RDI=validated eight-pointer record. Writes one JSON object; bytes is
 * numeric and all other values are escaped strings. Stack: 24 saved bytes. */
registry_print_json_row:
    push rbx
    push r14
    push r15
    mov rbx, rdi
    lea rdi, [rip + registry_lbrace]
    call out
    xor r14d, r14d
    lea r15, [rip + registry_json_keys]
.Ljson_field:
    test r14d, r14d
    jz .Ljson_key
    lea rdi, [rip + registry_comma]
    call out
.Ljson_key:
    mov rdi, [r15 + r14*8]
    call out
    mov rdi, [rbx + r14*8]
    cmp r14d, 6
    je .Ljson_number
    call registry_json_string
    jmp .Ljson_next
.Ljson_number:
    call out
.Ljson_next:
    inc r14d
    cmp r14d, 8
    jb .Ljson_field
    lea rdi, [rip + registry_rbrace]
    call out
    pop r15
    pop r14
    pop rbx
    ret

/* Metadata is printable ASCII. File arguments may contain controls, which are
 * encoded as \u00XX. A 4095-byte path requires at most 24572 output bytes. */
/* Input: RDI=string <=4095 bytes. Output: writes a quoted JSON string. Owned
 * scratch buffer is 24576 bytes, including closing quote and NUL. Other bytes
 * are copied unchanged; non-ASCII paths must use UTF-8 for valid JSON. */
registry_json_string:
    mov rsi, rdi
    lea rdi, [rip + registry_json_buffer]
    mov byte ptr [rdi], '"'
    inc rdi
.Lquote_char:
    movzx eax, byte ptr [rsi]
    inc rsi
    test al, al
    jz .Lquote_end
    cmp al, 32
    jb .Lquote_control
    cmp al, '"'
    je .Lquote_escape
    cmp al, '\\'
    je .Lquote_escape
    mov [rdi], al
    inc rdi
    jmp .Lquote_char
.Lquote_escape:
    mov byte ptr [rdi], '\\'
    mov [rdi + 1], al
    add rdi, 2
    jmp .Lquote_char
.Lquote_control:
    mov byte ptr [rdi], '\\'
    mov byte ptr [rdi + 1], 'u'
    mov byte ptr [rdi + 2], '0'
    mov byte ptr [rdi + 3], '0'
    mov edx, eax
    shr edx, 4
    lea rcx, [rip + registry_hex_digits]
    mov dl, [rcx + rdx]
    mov [rdi + 4], dl
    and eax, 15
    mov al, [rcx + rax]
    mov [rdi + 5], al
    add rdi, 6
    jmp .Lquote_char
.Lquote_end:
    mov byte ptr [rdi], '"'
    mov byte ptr [rdi + 1], 0
    lea rdi, [rip + registry_json_buffer]
    jmp out

/* Terminal command: select exact or highest numeric version for package,
 * target and kind. Copy/download into the owned stage, check exact byte size,
 * run fixed sha256sum argv, then renameat2(RENAME_NOREPLACE). The destination
 * never receives execute bits. Existing outputs are retained on all failures.
 * The index authenticates no publisher; the digest check establishes integrity
 * relative to that selected index. Source archives remain opaque bytes. */
registry_fetch:
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Lfetch_select:
    cmp r13, [rip + registry_row_count]
    jae .Lfetch_selected
    mov rdi, [r12]
    mov rsi, [rip + registry_query]
    call streq
    test eax, eax
    jz .Lfetch_next
    mov rdi, [r12 + 16]
    mov rsi, [rip + registry_target]
    call streq
    test eax, eax
    jz .Lfetch_next
    mov rdi, [r12 + 24]
    mov rsi, [rip + registry_kind]
    call streq
    test eax, eax
    jz .Lfetch_next
    mov rsi, [rip + registry_exact_version]
    test rsi, rsi
    jz .Lfetch_latest
    mov rdi, [r12 + 8]
    call streq
    test eax, eax
    jz .Lfetch_next
    jmp .Lfetch_choose
.Lfetch_latest:
    mov rax, [rip + registry_selected]
    test rax, rax
    jz .Lfetch_choose
    mov rdi, [r12 + 8]
    mov rsi, [rax + 8]
    call registry_version_compare
    cmp eax, 0
    jle .Lfetch_next
.Lfetch_choose:
    mov [rip + registry_selected], r12
.Lfetch_next:
    add r12, 64
    inc r13
    jmp .Lfetch_select
.Lfetch_selected:
    mov rbx, [rip + registry_selected]
    test rbx, rbx
    jz registry_not_found
    mov rdi, [rbx + 48]
    call registry_size_value
    mov [rip + registry_expected_size], rax
    call registry_workspace
    cmp qword ptr [rip + registry_local_artifact], 0
    jne .Lfetch_local
    mov rdi, [rbx + 40]
    lea rsi, [rip + registry_temp_payload]
    mov rdx, [rbx + 48]
    call registry_download
    test eax, eax
    jnz registry_download_error
    jmp .Lfetch_verify
.Lfetch_local:
    call registry_copy_local
.Lfetch_verify:
    mov eax, 6
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    js registry_io_error
    mov eax, [rip + registry_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne registry_io_error
    mov rax, [rip + registry_stat + 48]
    cmp rax, [rip + registry_expected_size]
    jne registry_integrity_error
    lea rdi, [rip + registry_checksum_contents]
    mov rsi, [rbx + 32]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_two_spaces]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_temp_payload]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_newline]
    call copy_string
    lea rdi, [rip + registry_temp_checksum]
    lea rsi, [rip + registry_checksum_contents]
    lea rdx, [rip + registry_checksum_created]
    call create_exclusive_file
    test rax, rax
    js registry_io_error
    mov eax, 21
    lea rdi, [rip + registry_sha256sum]
    mov esi, 1
    syscall
    test rax, rax
    js .Lsha_missing
    lea rax, [rip + registry_temp_checksum]
    mov [rip + registry_sha_argv + 24], rax
    lea rdi, [rip + registry_sha256sum]
    lea rsi, [rip + registry_sha_argv]
    call spawn_wait
    test eax, eax
    jnz registry_integrity_error
    cmp qword ptr [rip + registry_output], 0
    jne .Lfetch_output_ready
    lea rdi, [rip + registry_default_output]
    mov rsi, [rbx]
.Loutput_package:
    mov al, [rsi]
    test al, al
    jz .Loutput_version
    cmp al, '/'
    jne .Loutput_package_char
    mov al, '-'
.Loutput_package_char:
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .Loutput_package
.Loutput_version:
    mov byte ptr [rdi], '-'
    inc rdi
    mov rsi, [rbx + 8]
    call copy_string
    mov byte ptr [rax], '-'
    lea rdi, [rax + 1]
    mov rsi, [rbx + 16]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_tar_suffix]
    mov rcx, [rbx + 24]
    cmp byte ptr [rcx], 's'
    je .Loutput_suffix
    lea rsi, [rip + registry_bin_suffix]
.Loutput_suffix:
    call copy_string
    lea rax, [rip + registry_default_output]
    mov [rip + registry_output], rax
.Lfetch_output_ready:
    /* fetch never sets an execute bit. Installation is a separate action. */
    mov eax, 90
    lea rdi, [rip + registry_temp_payload]
    mov esi, 420
    syscall
    test rax, rax
    js registry_io_error
    mov eax, 316
    mov rdi, AT_FDCWD
    lea rsi, [rip + registry_temp_payload]
    mov rdx, AT_FDCWD
    mov r10, [rip + registry_output]
    mov r8d, 1
    syscall
    test rax, rax
    js .Lfetch_output_error
    call registry_cleanup
    cmp byte ptr [rip + json_mode], 0
    jne .Lfetch_json
    lea rdi, [rip + registry_fetched_text]
    call out
    mov rdi, [rip + registry_output]
    call out
    lea rdi, [rip + registry_verified_text]
    call out
    jmp exit_ok
.Lfetch_json:
    lea rdi, [rip + registry_fetch_json_prefix]
    call out
    mov rdi, [rip + registry_output]
    call registry_json_string
    lea rdi, [rip + registry_fetch_json_package]
    call out
    mov rdi, [rbx]
    call registry_json_string
    lea rdi, [rip + registry_fetch_json_version]
    call out
    mov rdi, [rbx + 8]
    call registry_json_string
    lea rdi, [rip + registry_fetch_json_suffix]
    call out
    jmp exit_ok
.Lfetch_output_error:
    lea rdi, [rip + registry_err_output]
    mov esi, 1
    jmp registry_fail
.Lsha_missing:
    lea rdi, [rip + registry_err_sha]
    mov esi, 127
    jmp registry_fail
registry_integrity_error:
    lea rdi, [rip + registry_err_integrity]
    mov esi, 1
    jmp registry_fail

/* Input: local_artifact path and expected_size <=64 MiB. Output: private payload
 * file, or fatal error. Opens a regular non-symlink input and exclusive output.
 * Retries short/interrupted reads and writes; checks both initial and copied
 * lengths. Owned copy buffer=65536 bytes. Stack: 24 saved bytes plus calls. */
registry_copy_local:
    push r12
    push r13
    push r14
    mov eax, 2
    mov rdi, [rip + registry_local_artifact]
    mov esi, O_NOFOLLOW + O_CLOEXEC
    xor edx, edx
    syscall
    test rax, rax
    js registry_io_error
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + registry_stat]
    syscall
    test rax, rax
    js registry_io_error
    mov eax, [rip + registry_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne registry_io_error
    mov rax, [rip + registry_stat + 48]
    cmp rax, [rip + registry_expected_size]
    jne registry_integrity_error
    mov eax, 2
    lea rdi, [rip + registry_temp_payload]
    mov esi, O_NOFOLLOW + O_CLOEXEC + 193
    mov edx, 384
    syscall
    test rax, rax
    js registry_io_error
    mov r13, rax
    xor r14d, r14d
.Lcopy_artifact_read:
    xor eax, eax
    mov rdi, r12
    lea rsi, [rip + registry_copy_buffer]
    mov edx, 65536
    syscall
    cmp rax, -4
    je .Lcopy_artifact_read
    test rax, rax
    js registry_io_error
    jz .Lcopy_artifact_done
    add r14, rax
    cmp r14, [rip + registry_expected_size]
    ja registry_integrity_error
    mov rdx, rax
    mov rdi, r13
    lea rsi, [rip + registry_copy_buffer]
    call write_all
    test rax, rax
    js registry_io_error
    jmp .Lcopy_artifact_read
.Lcopy_artifact_done:
    mov eax, 3
    mov rdi, r12
    syscall
    mov eax, 3
    mov rdi, r13
    syscall
    test rax, rax
    js registry_io_error
    cmp r14, [rip + registry_expected_size]
    jne registry_integrity_error
    pop r14
    pop r13
    pop r12
    ret

/* Input: RDI/RSI=already validated numeric versions. Output: EAX=-1, 0 or 1
 * for left less/equal/greater. Values are <=2147483647 per component, so the
 * decimal conversion cannot overflow. Read-only. Stack: none. */
registry_version_compare:
    xor ecx, ecx
    xor edx, edx
.Lcompare_component:
    xor r8d, r8d
    xor r9d, r9d
.Lcompare_left:
    movzx eax, byte ptr [rdi + rcx]
    cmp al, '0'
    jb .Lcompare_right
    cmp al, '9'
    ja .Lcompare_right
    sub eax, '0'
    imul r8, r8, 10
    add r8, rax
    inc ecx
    jmp .Lcompare_left
.Lcompare_right:
    movzx eax, byte ptr [rsi + rdx]
    cmp al, '0'
    jb .Lcompare_values
    cmp al, '9'
    ja .Lcompare_values
    sub eax, '0'
    imul r9, r9, 10
    add r9, rax
    inc edx
    jmp .Lcompare_right
.Lcompare_values:
    cmp r8, r9
    ja .Lcompare_greater
    jb .Lcompare_less
    cmp byte ptr [rdi + rcx], 0
    je .Lcompare_equal
    inc ecx
    inc edx
    jmp .Lcompare_component
.Lcompare_greater:
    mov eax, 1
    ret
.Lcompare_less:
    mov eax, -1
    ret
.Lcompare_equal:
    xor eax, eax
    ret

.section .rodata
registry_default_url: .asciz "https://asm.build/registry/v1/index.tsv"
registry_header: .asciz "# asm-registry-v1\n"
registry_host: .asciz "x86_64-linux"
registry_aarch64: .asciz "aarch64-linux"
registry_riscv64: .asciz "riscv64-linux"
registry_source_kind: .asciz "source"
registry_executable_kind: .asciz "executable"
registry_empty: .asciz ""
registry_opt_json: .asciz "--json"
registry_opt_no_color: .asciz "--no-color"
registry_opt_help: .asciz "--help"
registry_opt_index: .asciz "--index"
registry_opt_registry: .asciz "--registry"
registry_opt_target: .asciz "--target"
registry_opt_kind: .asciz "--kind"
registry_opt_output: .asciz "--output"
registry_opt_artifact: .asciz "--artifact"
registry_separator: .asciz "--"
registry_https_prefix: .asciz "https://"
registry_github_prefix: .asciz "https://github.com/"
registry_curl: .asciz "/usr/bin/curl"
registry_sha256sum: .asciz "/usr/bin/sha256sum"
registry_curl_disable: .asciz "--disable"
registry_curl_fail: .asciz "--fail"
registry_curl_location: .asciz "--location"
registry_curl_silent: .asciz "--silent"
registry_curl_show_error: .asciz "--show-error"
registry_curl_proto: .asciz "--proto"
registry_curl_https: .asciz "=https"
registry_curl_proto_redir: .asciz "--proto-redir"
registry_curl_connect_timeout: .asciz "--connect-timeout"
registry_curl_fifteen: .asciz "15"
registry_curl_max_time: .asciz "--max-time"
registry_curl_120: .asciz "120"
registry_curl_max_redirs: .asciz "--max-redirs"
registry_curl_five: .asciz "5"
registry_curl_max_filesize: .asciz "--max-filesize"
registry_curl_output: .asciz "--output"
registry_sha_status: .asciz "--status"
registry_sha_check: .asciz "--check"
registry_index_max: .asciz "1048576"
registry_temp_prefix: .asciz ".asm-registry-"
registry_index_suffix: .asciz "/index.tsv"
registry_payload_suffix: .asciz "/payload"
registry_checksum_suffix: .asciz "/checksum.txt"
registry_tar_suffix: .asciz ".tar.gz"
registry_bin_suffix: .asciz ".bin"
registry_tab: .asciz "\t"
registry_newline: .asciz "\n"
registry_two_spaces: .asciz "  "
registry_comma: .asciz ","
registry_lbrace: .asciz "{"
registry_rbrace: .asciz "}"
registry_hex_digits: .asciz "0123456789abcdef"
registry_results_prefix: .asciz "{\"results\":["
registry_versions_prefix: .asciz "{\"versions\":["
registry_results_suffix: .asciz "]}\n"
registry_json_keys:
    .quad registry_json_package, registry_json_version, registry_json_target
    .quad registry_json_kind, registry_json_sha, registry_json_url
    .quad registry_json_bytes, registry_json_summary
registry_json_package: .asciz "\"package\":"
registry_json_version: .asciz "\"version\":"
registry_json_target: .asciz "\"target\":"
registry_json_kind: .asciz "\"kind\":"
registry_json_sha: .asciz "\"sha256\":"
registry_json_url: .asciz "\"url\":"
registry_json_bytes: .asciz "\"bytes\":"
registry_json_summary: .asciz "\"summary\":"
registry_fetch_json_prefix: .asciz "{\"ok\":true,\"artifact\":"
registry_fetch_json_package: .asciz ",\"package\":"
registry_fetch_json_version: .asciz ",\"version\":"
registry_fetch_json_suffix: .asciz ",\"verified\":true}\n"
registry_fetched_text: .asciz "Fetched "
registry_verified_text: .asciz " (size and SHA-256 verified; not executed)\n"
registry_no_matches: .asciz "No matching packages.\n"
registry_err_args: .asciz "invalid registry arguments; use asm search --help"
registry_err_index: .asciz "invalid registry index; expected the bounded asm-registry-v1 format"
registry_err_download: .asciz "HTTPS download failed; no package was installed"
registry_err_io: .asciz "cannot read a regular file or create a private registry workspace"
registry_err_not_found: .asciz "no matching package, version, target and artifact kind"
registry_err_curl: .asciz "registry downloads require /usr/bin/curl"
registry_err_sha: .asciz "artifact verification requires /usr/bin/sha256sum"
registry_err_integrity: .asciz "artifact size or SHA-256 verification failed; output was not created"
registry_err_output: .asciz "cannot create output; the destination must not exist and must be on the same filesystem"
registry_help_text:
    .ascii "Usage:\n"
    .ascii "  asm search [query] [--json]\n"
    .ascii "  asm info owner/name [--json]\n"
    .ascii "  asm versions owner/name [--json]\n"
    .ascii "  asm fetch owner/name[@version] [--target target] [--kind source|executable]\n"
    .ascii "            [--output path] [--artifact local-file] [--json]\n\n"
    .ascii "Use --index path for a local index or --registry https://... for an index URL.\n"
    .ascii "The default index is https://asm.build/registry/v1/index.tsv.\n"
    .ascii "fetch selects the highest numeric version if you omit @version.\n"
    .ascii "fetch defaults to source and x86_64-linux. It verifies bytes and SHA-256.\n"
    .ascii "fetch does not overwrite, extract, install, or run package contents.\n"
    .byte 0

.section .data
.balign 8
registry_curl_argv:
    .quad registry_curl, registry_curl_disable, registry_curl_fail
    .quad registry_curl_location, registry_curl_silent, registry_curl_show_error
    .quad registry_curl_proto, registry_curl_https, registry_curl_proto_redir
    .quad registry_curl_https, registry_curl_connect_timeout, registry_curl_fifteen
    .quad registry_curl_max_time, registry_curl_120, registry_curl_max_redirs
    .quad registry_curl_five, registry_curl_max_filesize, 0
    .quad registry_curl_output, 0, registry_separator, 0, 0
registry_sha_argv:
    .quad registry_sha256sum, registry_sha_status, registry_sha_check, 0, 0

.section .bss
.balign 8
registry_url: .skip 8
registry_index_path: .skip 8
registry_target: .skip 8
registry_kind: .skip 8
registry_query: .skip 8
registry_exact_version: .skip 8
registry_output: .skip 8
registry_local_artifact: .skip 8
registry_row_count: .skip 8
registry_index_end: .skip 8
registry_selected: .skip 8
registry_matches: .skip 8
registry_expected_size: .skip 8
registry_stat: .skip 144
registry_number_buffer: .skip 32
registry_temp_dir: .skip 64
registry_temp_index: .skip 96
registry_temp_payload: .skip 96
registry_temp_checksum: .skip 96
registry_checksum_contents: .skip 256
registry_selector: .skip 170
registry_default_output: .skip 256
registry_json_buffer: .skip 24576
registry_copy_buffer: .skip 65536
registry_rows: .skip ROW_LIMIT * 64
registry_index: .skip INDEX_LIMIT + 2
registry_mode: .skip 1
registry_has_query: .skip 1
registry_origin_seen: .skip 1
registry_literal: .skip 1
registry_has_workspace: .skip 1
registry_checksum_created: .skip 1
.section .note.GNU-stack,"",@progbits
