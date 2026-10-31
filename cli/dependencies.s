.intel_syntax noprefix
.global cmd_add, cmd_update, cmd_remove, cmd_lock, cmd_sync
.global verify_project_dependencies, release_dependency_lock

/* Direct source dependencies use exact versions. asm.lock stores the same
 * eight fields as registry v1, after a versioned header and registry origin.
 * No ranges, transitive resolution, hooks or implicit source imports exist.
 * Returning routines preserve RBX/RBP/R12-R15; other registers are scratch.
 */
.section .text
cmd_add:
    mov byte ptr [rip + registry_mode], 6
    jmp registry_command
cmd_update:
    mov byte ptr [rip + registry_mode], 7
    jmp registry_command

/* Input: registry_selected is validated and points into the registry buffer.
 * Save its eight pointers before loading the independent lock buffer. Require
 * a project and a single registry origin. Take a nonblocking exclusive project
 * lock. Existing lock records are retained until verified extraction succeeds.
 * Output: registry_selected points to dependency_new_record; locked rows are
 * in registry_rows. Stack: 24 saved bytes. Fatal failures preserve asm.lock. */
dependency_prepare_selection:
    push rbx
    push r12
    push r13
    call read_manifest
    lea rdi, [rip + dependency_new_record]
    mov rsi, [rip + registry_selected]
    mov ecx, 8
    rep movsq
    lea rax, [rip + dependency_new_record]
    mov [rip + registry_selected], rax
    mov rax, [rip + registry_url]
    cmp byte ptr [rip + registry_local_index], 0
    je .Ldep_new_origin
    lea rax, [rip + dependency_local_origin]
.Ldep_new_origin:
    mov [rip + dependency_new_origin], rax
    mov edi, 6
    mov esi, 1
    call dependency_acquire
    call dependency_load_lock
    test eax, eax
    jz .Ldep_check_origin
    mov rax, [rip + dependency_new_origin]
    mov [rip + dependency_origin], rax
    jmp .Ldep_find_previous
.Ldep_check_origin:
    mov rdi, [rip + dependency_origin]
    mov rsi, [rip + dependency_new_origin]
    call streq
    test eax, eax
    jz dependency_origin_error
.Ldep_find_previous:
    lea r12, [rip + registry_rows]
    xor r13d, r13d
    lea rbx, [rip + dependency_new_record]
.Ldep_previous_loop:
    cmp r13, [rip + registry_row_count]
    jae .Ldep_previous_done
    mov rdi, [r12]
    mov rsi, [rbx]
    call streq
    test eax, eax
    jz .Ldep_previous_next
    mov [rip + dependency_replace_row], r12
    cmp byte ptr [rip + registry_mode], 7
    je .Ldep_previous_done
    mov rdi, [r12 + 8]
    mov rsi, [rbx + 8]
    call streq
    test eax, eax
    jz dependency_already_locked
    mov rdi, [r12 + 32]
    mov rsi, [rbx + 32]
    call streq
    test eax, eax
    jz dependency_changed_release
    mov rdi, [r12 + 40]
    mov rsi, [rbx + 40]
    call streq
    test eax, eax
    jz dependency_changed_release
    mov rdi, [r12 + 48]
    mov rsi, [rbx + 48]
    call streq
    test eax, eax
    jz dependency_changed_release
    jmp .Ldep_previous_done
.Ldep_previous_next:
    add r12, 64
    inc r13
    jmp .Ldep_previous_loop
.Ldep_previous_done:
    cmp byte ptr [rip + registry_mode], 7
    jne .Ldep_prepare_done
    cmp qword ptr [rip + dependency_replace_row], 0
    je dependency_missing_selection
    /* Updating a version may not change the bytes of the same version. */
    mov r12, [rip + dependency_replace_row]
    mov rdi, [r12 + 8]
    mov rsi, [rbx + 8]
    call streq
    test eax, eax
    jz .Ldep_prepare_done
    mov rdi, [r12 + 32]
    mov rsi, [rbx + 32]
    call streq
    test eax, eax
    jz dependency_changed_release
    mov rdi, [r12 + 40]
    mov rsi, [rbx + 40]
    call streq
    test eax, eax
    jz dependency_changed_release
    mov rdi, [r12 + 48]
    mov rsi, [rbx + 48]
    call streq
    test eax, eax
    jz dependency_changed_release
.Ldep_prepare_done:
    lea rax, [rip + dependency_new_record]
    mov [rip + registry_selected], rax
    pop r13
    pop r12
    pop rbx
    ret

/* Input: verified private payload and dependency_new_record. Extract or compare
 * the exact source tree before changing asm.lock. Cache archives are derived
 * data named by their digest; a verified replacement can repair those bytes.
 * The lock rename is the final operation. Unreferenced cache data can remain
 * after a filesystem failure; the previous lock remains usable. No return. */
dependency_finish_add:
    lea rbx, [rip + dependency_new_record]
    mov [rip + registry_selected], rbx
    mov edi, 1
    call dependency_paths
    call dependency_accept_payload
    mov rdi, [rip + dependency_replace_row]
    test rdi, rdi
    jnz .Ldep_replace_record
    mov rax, [rip + registry_row_count]
    cmp rax, 4096
    jae dependency_lock_error
    shl rax, 6
    lea rdi, [rip + registry_rows]
    add rdi, rax
    inc qword ptr [rip + registry_row_count]
.Ldep_replace_record:
    lea rsi, [rip + dependency_new_record]
    mov ecx, 8
    rep movsq
    call dependency_write_lock
    call registry_cleanup
    call release_dependency_lock
    cmp byte ptr [rip + json_mode], 0
    jne .Ldep_add_json
    lea rdi, [rip + dependency_added_text]
    cmp byte ptr [rip + registry_mode], 7
    jne .Ldep_add_text
    lea rdi, [rip + dependency_updated_text]
.Ldep_add_text:
    call out
    jmp exit_ok
.Ldep_add_json:
    lea rdi, [rip + dependency_result_prefix]
    call out
    mov rdi, [rip + dependency_new_record]
    call registry_json_string
    lea rdi, [rip + registry_fetch_json_version]
    call out
    mov rdi, [rip + dependency_new_record + 8]
    call registry_json_string
    lea rdi, [rip + dependency_result_cache]
    call out
    lea rdi, [rip + dependency_package_path]
    call registry_json_string
    lea rdi, [rip + dependency_result_suffix]
    call out
    jmp exit_ok

/* Input: EDI=flock operation 5(shared/nonblocking) or 6(exclusive/nonblocking),
 * ESI=allow creating .asm. Output: held descriptor in dependency_lock_fd.
 * The empty coordination file is regular, non-symlink, and has one hard link.
 * Cooperation prevents lost updates between asm processes in this project.
 * It is not a sandbox against a process that ignores flock. Stack: 8 bytes. */
dependency_acquire:
    push r12
    mov r12d, edi
    test esi, esi
    jz .Ldep_existing_root
    lea rdi, [rip + dependency_root]
    call make_safe_dir
    test rax, rax
    js dependency_io_error
    jmp .Ldep_open_lock
.Ldep_existing_root:
    mov eax, 6
    lea rdi, [rip + dependency_root]
    lea rsi, [rip + dependency_stat]
    syscall
    test rax, rax
    js dependency_cache_missing
    mov eax, [rip + dependency_stat + 24]
    and eax, 61440
    cmp eax, 16384
    jne dependency_io_error
.Ldep_open_lock:
    mov eax, 2
    lea rdi, [rip + dependency_operation_lock]
    mov esi, 64 + 131072 + 524288 + 2048
    mov edx, 384
    syscall
    test rax, rax
    js dependency_io_error
    mov [rip + dependency_lock_fd], rax
    mov rdi, rax
    mov eax, 5
    lea rsi, [rip + dependency_stat]
    syscall
    test rax, rax
    js dependency_io_error
    mov eax, [rip + dependency_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne dependency_io_error
    cmp qword ptr [rip + dependency_stat + 16], 1
    jne dependency_io_error
    mov eax, 73
    mov rdi, [rip + dependency_lock_fd]
    mov esi, r12d
    syscall
    test rax, rax
    js dependency_busy
    pop r12
    ret

/* Closes only a descriptor acquired above, releasing its advisory lock.
 * Output: dependency_lock_fd=-1. Safe if no lock was acquired. Stack: none. */
release_dependency_lock:
    mov rdi, [rip + dependency_lock_fd]
    cmp rdi, 0
    jl .Ldep_release_done
    mov eax, 3
    syscall
    mov qword ptr [rip + dependency_lock_fd], -1
.Ldep_release_done:
    ret

/* Input: cwd. Reads a regular asm.lock into its own <=1MiB buffer. Output:
 * EAX=0 loaded, EAX=1 absent; registry_rows/count and dependency_origin updated.
 * The selected remote record must be saved before this routine is called.
 * Rejects duplicate package identities, non-source kinds, non-host targets and
 * malformed data before use. Stack: 32 bytes. Missing does not create a file. */
dependency_load_lock:
    push rbx
    push r12
    push r13
    push r14
    mov qword ptr [rip + registry_row_count], 0
    mov eax, 2
    lea rdi, [rip + dependency_lock_path]
    mov esi, 131072 + 524288 + 2048
    xor edx, edx
    syscall
    cmp rax, -2
    je .Ldep_no_lock
    test rax, rax
    js dependency_lock_error
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + dependency_stat]
    syscall
    test rax, rax
    js .Ldep_read_bad
    mov eax, [rip + dependency_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Ldep_read_bad
    cmp qword ptr [rip + dependency_stat + 48], 1048576
    ja .Ldep_read_bad
    xor r13d, r13d
.Ldep_read_loop:
    xor eax, eax
    mov rdi, r12
    lea rsi, [rip + dependency_lock_buffer]
    add rsi, r13
    mov edx, 1048577
    sub rdx, r13
    syscall
    cmp rax, -4
    je .Ldep_read_loop
    test rax, rax
    js .Ldep_read_bad
    jz .Ldep_read_done
    add r13, rax
    cmp r13, 1048576
    ja .Ldep_read_bad
    jmp .Ldep_read_loop
.Ldep_read_done:
    mov eax, 3
    mov rdi, r12
    syscall
    lea rdi, [rip + dependency_lock_buffer]
    lea r14, [rdi + r13]
    mov byte ptr [r14], 0
    lea rsi, [rip + dependency_header]
    call dependency_prefix
    test rax, rax
    jz dependency_lock_error
    mov rdi, rax
    lea rsi, [rip + dependency_origin_prefix]
    call dependency_prefix
    test rax, rax
    jz dependency_lock_error
    mov [rip + dependency_origin], rax
    mov r12, rax
    xor ecx, ecx
.Ldep_origin_scan:
    cmp r12, r14
    jae dependency_lock_error
    mov al, [r12]
    cmp al, 10
    je .Ldep_origin_end
    cmp al, 33
    jb dependency_lock_error
    cmp al, 126
    ja dependency_lock_error
    inc r12
    inc ecx
    cmp ecx, 4095
    ja dependency_lock_error
    jmp .Ldep_origin_scan
.Ldep_origin_end:
    mov byte ptr [r12], 0
    inc r12
    mov rdi, [rip + dependency_origin]
    lea rsi, [rip + dependency_local_origin]
    call streq
    test eax, eax
    jnz .Ldep_parse_rows
    mov rdi, [rip + dependency_origin]
    call registry_https_url
    test eax, eax
    jz dependency_lock_error
.Ldep_parse_rows:
    mov rdi, r12
    mov rsi, r14
    call registry_parse_records
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Ldep_validate_record:
    cmp r13, [rip + registry_row_count]
    jae .Ldep_loaded
    mov rdi, [r12 + 16]
    lea rsi, [rip + registry_host]
    call streq
    test eax, eax
    jz dependency_lock_error
    mov rdi, [r12 + 24]
    lea rsi, [rip + registry_source_kind]
    call streq
    test eax, eax
    jz dependency_lock_error
    lea rbx, [rip + registry_rows]
.Ldep_duplicate_package:
    cmp rbx, r12
    jae .Ldep_record_next
    mov rdi, [rbx]
    mov rsi, [r12]
    call streq
    test eax, eax
    jnz dependency_lock_error
    add rbx, 64
    jmp .Ldep_duplicate_package
.Ldep_record_next:
    add r12, 64
    inc r13
    jmp .Ldep_validate_record
.Ldep_loaded:
    xor eax, eax
    jmp .Ldep_load_return
.Ldep_no_lock:
    mov eax, 1
.Ldep_load_return:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Ldep_read_bad:
    mov eax, 3
    mov rdi, r12
    syscall
    jmp dependency_lock_error

/* Input: RDI=input, RSI=constant prefix. Output: RAX=first byte after prefix,
 * or zero on mismatch. Read-only; inputs point into bounded NUL buffers. */
dependency_prefix:
    xor ecx, ecx
.Ldep_prefix_loop:
    mov al, [rsi + rcx]
    test al, al
    jz .Ldep_prefix_done
    cmp al, [rdi + rcx]
    jne .Ldep_prefix_bad
    inc ecx
    jmp .Ldep_prefix_loop
.Ldep_prefix_done:
    lea rax, [rdi + rcx]
    ret
.Ldep_prefix_bad:
    xor eax, eax
    ret

/* Input: registry_selected=validated source record, EDI=create parent dirs.
 * Output: package path .asm/packages/owner/name/version/target (<=180 bytes),
 * and archive .asm/cache/<sha256>.tar.gz (<=90 bytes). Does not create the final
 * extraction directory. Existing directory components must not be symlinks.
 * Stack: 32 bytes. Buffer capacities 256 and 128. */
dependency_paths:
    push rbx
    push r12
    push r13
    push r14
    mov r14d, edi
    mov rbx, [rip + registry_selected]
    lea rdi, [rip + dependency_packages_root]
    mov esi, r14d
    call dependency_directory
    test rax, rax
    js dependency_io_error
    lea rdi, [rip + dependency_cache_root]
    mov esi, r14d
    call dependency_directory
    test rax, rax
    js dependency_io_error
.Ldep_path_copy:
    lea rdi, [rip + dependency_package_path]
    lea rsi, [rip + dependency_packages_prefix]
    call copy_string
    mov r12, rax
    mov r13, [rbx]
.Ldep_owner_copy:
    mov al, [r13]
    cmp al, '/'
    je .Ldep_owner_done
    mov [r12], al
    inc r12
    inc r13
    jmp .Ldep_owner_copy
.Ldep_owner_done:
    mov byte ptr [r12], 0
    lea rdi, [rip + dependency_package_path]
    mov esi, r14d
    call dependency_directory
    test rax, rax
    js dependency_io_error
.Ldep_name_copy:
    mov rdi, r12
    mov rsi, r13
    call copy_string
    mov r12, rax
    lea rdi, [rip + dependency_package_path]
    mov esi, r14d
    call dependency_directory
    test rax, rax
    js dependency_io_error
.Ldep_version_copy:
    mov byte ptr [r12], '/'
    lea rdi, [r12 + 1]
    mov rsi, [rbx + 8]
    call copy_string
    mov r12, rax
    lea rdi, [rip + dependency_package_path]
    mov esi, r14d
    call dependency_directory
    test rax, rax
    js dependency_io_error
.Ldep_target_copy:
    mov byte ptr [r12], '/'
    lea rdi, [r12 + 1]
    mov rsi, [rbx + 16]
    call copy_string
    lea rdi, [rip + dependency_archive_path]
    lea rsi, [rip + dependency_cache_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, [rbx + 32]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + registry_tar_suffix]
    call copy_string
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Input: RDI=one cache directory component, ESI=allow creation. Output: zero
 * or one for a real directory, negative on failure. Read-only mode still
 * rejects symbolic links at every checked component. Stack: none. */
dependency_directory:
    test esi, esi
    jnz make_safe_dir
    mov eax, 6
    lea rsi, [rip + dependency_stat]
    syscall
    test rax, rax
    js .Ldep_directory_return
    mov eax, [rip + dependency_stat + 24]
    and eax, 61440
    cmp eax, 16384
    jne .Ldep_directory_bad
    xor eax, eax
    ret
.Ldep_directory_bad:
    mov rax, -1
.Ldep_directory_return:
    ret

/* Input: private payload has passed size+SHA256; dependency paths are set.
 * Compare an existing cache tree or extract a new one with the native archive
 * module. Then atomically store the verified archive in the managed digest
 * cache. Does not modify asm.lock. No package code runs. */
dependency_accept_payload:
    mov rax, [rip + registry_selected]
    mov rsi, [rax]
    mov rdx, [rax + 8]
    mov rcx, [rax + 16]
    lea rdi, [rip + registry_temp_payload]
    call validate_source_package
    test eax, eax
    jnz dependency_archive_error
    mov eax, 6
    lea rdi, [rip + dependency_package_path]
    lea rsi, [rip + dependency_stat]
    syscall
    cmp rax, -2
    je .Ldep_extract_new
    test rax, rax
    js dependency_io_error
    mov eax, [rip + dependency_stat + 24]
    and eax, 61440
    cmp eax, 16384
    jne dependency_cache_changed
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + dependency_package_path]
    call verify_source_archive
    test eax, eax
    jnz dependency_cache_changed
    jmp .Ldep_store_archive
.Ldep_extract_new:
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + dependency_package_path]
    call extract_source_archive
    test eax, eax
    jnz dependency_archive_error
.Ldep_store_archive:
    mov eax, 90
    lea rdi, [rip + registry_temp_payload]
    mov esi, 420
    syscall
    test rax, rax
    js dependency_io_error
    mov eax, 82
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + dependency_archive_path]
    syscall
    test rax, rax
    js dependency_io_error
    ret

/* Input: registry_rows/count and one validated dependency_origin. Writes a
 * canonical lock to an exclusive private temporary file, fsyncs it, then
 * renames it onto asm.lock. The held project lock serializes writers. Each
 * field is already bounded printable text. Stack: 40 saved bytes plus calls. */
dependency_write_lock:
    push rbx
    push r12
    push r13
    push r14
    push r15
    /* Bound the serialized file, not just its record count. Otherwise an
     * append could write a lock that the bounded reader cannot reopen. */
    lea rdi, [rip + dependency_header]
    call strlen
    mov r15, rax
    lea rdi, [rip + dependency_origin_prefix]
    call strlen
    add r15, rax
    mov rdi, [rip + dependency_origin]
    call strlen
    lea r15, [r15 + rax + 1]
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Ldep_measure_record:
    cmp r13, [rip + registry_row_count]
    jae .Ldep_measure_done
    xor r14d, r14d
.Ldep_measure_field:
    mov rdi, [r12 + r14*8]
    call strlen
    lea r15, [r15 + rax + 1]
    cmp r15, 1048576
    ja dependency_lock_too_large
    inc r14d
    cmp r14d, 8
    jb .Ldep_measure_field
    add r12, 64
    inc r13
    jmp .Ldep_measure_record
.Ldep_measure_done:
    cmp r15, 1048576
    ja dependency_lock_too_large
    call registry_workspace
    lea rdi, [rip + dependency_temp_lock]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + dependency_lock_suffix]
    call copy_string
    lea rax, [rip + dependency_temp_lock]
    mov [rip + registry_extra_temp], rax
    mov eax, 2
    mov rdi, [rip + registry_extra_temp]
    mov esi, 193 + 131072 + 524288
    mov edx, 420
    syscall
    test rax, rax
    js dependency_io_error
    mov rbx, rax
    lea rsi, [rip + dependency_header]
    call dependency_write_string
    lea rsi, [rip + dependency_origin_prefix]
    call dependency_write_string
    mov rsi, [rip + dependency_origin]
    call dependency_write_string
    lea rsi, [rip + registry_newline]
    call dependency_write_string
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Ldep_write_record:
    cmp r13, [rip + registry_row_count]
    jae .Ldep_write_end
    xor r14d, r14d
.Ldep_write_field:
    mov rsi, [r12 + r14*8]
    call dependency_write_string
    lea rsi, [rip + registry_tab]
    cmp r14d, 7
    jne .Ldep_write_separator
    lea rsi, [rip + registry_newline]
.Ldep_write_separator:
    call dependency_write_string
    inc r14d
    cmp r14d, 8
    jb .Ldep_write_field
    add r12, 64
    inc r13
    jmp .Ldep_write_record
.Ldep_write_end:
    mov eax, 74
    mov rdi, rbx
    syscall
    test rax, rax
    js dependency_io_error
    mov eax, 3
    mov rdi, rbx
    syscall
    test rax, rax
    js dependency_io_error
    mov eax, 82
    lea rdi, [rip + dependency_temp_lock]
    lea rsi, [rip + dependency_lock_path]
    syscall
    test rax, rax
    js dependency_io_error
    mov qword ptr [rip + registry_extra_temp], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* Input: RBX=owned lock file descriptor, RSI=validated string. Returns only
 * after complete write; fatal error preserves the previous asm.lock. */
dependency_write_string:
    mov rdi, rbx
    call write_cstr
    test rax, rax
    js dependency_io_error
    ret

/* Core build entry. Input: require_lock selects strict missing-lock behavior.
 * Default builds verify every dependency when asm.lock exists. Every archive
 * is copied into a private stage, checked against its locked size/digest, and
 * compared byte-for-byte to its extracted cache, including unexpected members.
 * Output: returns with a shared project lock held until build completion.
 * Does not fetch, resolve new versions, execute code or modify source caches. */
verify_project_dependencies:
    push rbx
    push r12
    push r13
    mov eax, 6
    lea rdi, [rip + dependency_lock_path]
    lea rsi, [rip + dependency_stat]
    syscall
    cmp rax, -2
    jne .Ldep_verify_present
    cmp byte ptr [rip + require_lock], 0
    jne dependency_lock_missing
    jmp .Ldep_verify_done
.Ldep_verify_present:
    test rax, rax
    js dependency_lock_error
    mov edi, 5
    mov esi, 1
    call dependency_acquire
    call dependency_load_lock
    test eax, eax
    jnz dependency_lock_missing
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Ldep_verify_row:
    cmp r13, [rip + registry_row_count]
    jae .Ldep_verify_done
    mov [rip + registry_selected], r12
    mov rdi, [r12 + 48]
    call registry_size_value
    mov [rip + registry_expected_size], rax
    xor edi, edi
    call dependency_paths
    mov eax, 6
    lea rdi, [rip + dependency_archive_path]
    lea rsi, [rip + dependency_stat]
    syscall
    test rax, rax
    js dependency_cache_missing
    call registry_workspace
    lea rax, [rip + dependency_archive_path]
    mov [rip + registry_local_artifact], rax
    call registry_copy_local
    call registry_verify_payload
    lea rdi, [rip + registry_temp_payload]
    mov rsi, [r12]
    mov rdx, [r12 + 8]
    mov rcx, [r12 + 16]
    call validate_source_package
    test eax, eax
    jnz dependency_archive_error
    lea rdi, [rip + registry_temp_payload]
    lea rsi, [rip + dependency_package_path]
    call verify_source_archive
    test eax, eax
    jnz dependency_cache_changed
    call registry_cleanup
    add r12, 64
    inc r13
    jmp .Ldep_verify_row
.Ldep_verify_done:
    pop r13
    pop r12
    pop rbx
    ret

cmd_lock:
    call parse_options_only
    call read_manifest
    mov byte ptr [rip + require_lock], 1
    call verify_project_dependencies
    call release_dependency_lock
    lea rdi, [rip + dependency_locked_text]
    jmp dependency_count_report

cmd_remove:
    call dependency_parse_name
    call read_manifest
    mov edi, 6
    xor esi, esi
    call dependency_acquire
    call dependency_load_lock
    test eax, eax
    jnz dependency_lock_missing
    lea r12, [rip + registry_rows]
    mov r13, r12
    xor r14d, r14d
    xor r15d, r15d
.Ldep_remove_row:
    cmp r14, [rip + registry_row_count]
    jae .Ldep_remove_done
    mov rdi, [r12]
    mov rsi, [rip + dependency_remove_name]
    call streq
    test eax, eax
    jnz .Ldep_remove_match
    mov rdi, r13
    mov rsi, r12
    mov ecx, 8
    rep movsq
    add r13, 64
    jmp .Ldep_remove_next
.Ldep_remove_match:
    inc r15d
.Ldep_remove_next:
    add r12, 64
    inc r14
    jmp .Ldep_remove_row
.Ldep_remove_done:
    test r15d, r15d
    jz dependency_missing_selection
    sub [rip + registry_row_count], r15
    call dependency_write_lock
    call registry_cleanup
    call release_dependency_lock
    lea rdi, [rip + dependency_removed_text]
    jmp dependency_count_report

/* Parse remove's one owner/name operand and common output options. Input:
 * argv cursor follows command. Output: borrowed dependency_remove_name.
 * Unknown arguments or selectors with versions exit 2 before file changes. */
dependency_parse_name:
    call next_arg
    test rax, rax
    jz .Ldep_remove_args_done
    mov r12, rax
    call common_option
    test eax, eax
    jnz dependency_parse_name
    cmp qword ptr [rip + dependency_remove_name], 0
    jne registry_bad_args
    mov rdi, r12
    call registry_valid_package
    test eax, eax
    jz registry_bad_args
    mov [rip + dependency_remove_name], r12
    jmp dependency_parse_name
.Ldep_remove_args_done:
    cmp qword ptr [rip + dependency_remove_name], 0
    je registry_bad_args
    ret

/* Sync downloads locked exact URLs. It never reads a newer registry index.
 * --artifact FILE is an offline input only when the lock has one dependency.
 * Existing extracted source must match; sync does not discard local edits. */
cmd_sync:
.Ldep_sync_args:
    call next_arg
    test rax, rax
    jz .Ldep_sync_start
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + registry_opt_artifact]
    call streq
    test eax, eax
    jz .Ldep_sync_common
    cmp qword ptr [rip + dependency_sync_artifact], 0
    jne registry_bad_args
    call registry_arg_value
    mov [rip + dependency_sync_artifact], rax
    jmp .Ldep_sync_args
.Ldep_sync_common:
    mov rax, r12
    call common_option
    test eax, eax
    jz registry_bad_args
    jmp .Ldep_sync_args
.Ldep_sync_start:
    call read_manifest
    mov edi, 6
    mov esi, 1
    call dependency_acquire
    call dependency_load_lock
    test eax, eax
    jnz dependency_lock_missing
    cmp qword ptr [rip + dependency_sync_artifact], 0
    je .Ldep_sync_begin
    cmp qword ptr [rip + registry_row_count], 1
    jne registry_bad_args
.Ldep_sync_begin:
    lea r12, [rip + registry_rows]
    xor r13d, r13d
.Ldep_sync_row:
    cmp r13, [rip + registry_row_count]
    jae .Ldep_sync_done
    mov [rip + registry_selected], r12
    mov rdi, [r12 + 48]
    call registry_size_value
    mov [rip + registry_expected_size], rax
    mov edi, 1
    call dependency_paths
    call registry_workspace
    mov rax, [rip + dependency_sync_artifact]
    test rax, rax
    jz .Ldep_sync_remote
    mov [rip + registry_local_artifact], rax
    call registry_copy_local
    jmp .Ldep_sync_verified
.Ldep_sync_remote:
    mov rdi, [r12 + 40]
    lea rsi, [rip + registry_temp_payload]
    mov rdx, [r12 + 48]
    call registry_download
    test eax, eax
    jnz registry_download_error
.Ldep_sync_verified:
    call registry_verify_payload
    call dependency_accept_payload
    call registry_cleanup
    add r12, 64
    inc r13
    jmp .Ldep_sync_row
.Ldep_sync_done:
    call release_dependency_lock
    lea rdi, [rip + dependency_synced_text]
    jmp dependency_count_report

/* Terminal report. Input: RDI=plain success text; row_count is the exact locked
 * count. JSON writes a numeric count, not a package-safety claim. */
dependency_count_report:
    cmp byte ptr [rip + json_mode], 0
    je .Ldep_report_text
    lea rdi, [rip + dependency_count_prefix]
    call out
    mov rdi, [rip + registry_row_count]
    lea rsi, [rip + dependency_number + 31]
    call unsigned_decimal
    mov rdi, rax
    call out
    lea rdi, [rip + dependency_result_suffix]
.Ldep_report_text:
    call out
    jmp exit_ok

dependency_io_error:
    lea rdi, [rip + dependency_err_io]
    mov esi, 1
    jmp registry_fail
dependency_lock_error:
    lea rdi, [rip + dependency_err_lock]
    mov esi, 1
    jmp registry_fail
dependency_lock_missing:
    lea rdi, [rip + dependency_err_lock_missing]
    mov esi, 1
    jmp registry_fail
dependency_cache_missing:
    lea rdi, [rip + dependency_err_cache_missing]
    mov esi, 1
    jmp registry_fail
dependency_cache_changed:
    lea rdi, [rip + dependency_err_cache_changed]
    mov esi, 1
    jmp registry_fail
dependency_archive_error:
    lea rdi, [rip + dependency_err_archive]
    mov esi, 1
    jmp registry_fail
dependency_origin_error:
    lea rdi, [rip + dependency_err_origin]
    mov esi, 1
    jmp registry_fail
dependency_already_locked:
    lea rdi, [rip + dependency_err_already]
    mov esi, 1
    jmp registry_fail
dependency_changed_release:
    lea rdi, [rip + dependency_err_changed]
    mov esi, 1
    jmp registry_fail
dependency_missing_selection:
    lea rdi, [rip + dependency_err_selection]
    mov esi, 1
    jmp registry_fail
dependency_busy:
    lea rdi, [rip + dependency_err_busy]
    mov esi, 1
    jmp registry_fail
dependency_lock_too_large:
    lea rdi, [rip + dependency_err_large]
    mov esi, 1
    jmp registry_fail

.section .rodata
dependency_header: .asciz "# asm-lock-v1\n"
dependency_origin_prefix: .asciz "# registry "
dependency_local_origin: .asciz "local"
dependency_root: .asciz ".asm"
dependency_operation_lock: .asciz ".asm/operation.lock"
dependency_packages_root: .asciz ".asm/packages"
dependency_packages_prefix: .asciz ".asm/packages/"
dependency_cache_root: .asciz ".asm/cache"
dependency_cache_prefix: .asciz ".asm/cache/"
dependency_lock_path: .asciz "asm.lock"
dependency_lock_suffix: .asciz "/asm.lock"
dependency_added_text: .asciz "Added the exact source dependency. Run asm lock to check the cache.\n"
dependency_updated_text: .asciz "Updated the exact source dependency. The previous lock was retained until verification succeeded.\n"
dependency_removed_text: .asciz "Removed the dependency from asm.lock. Cache files were retained.\n"
dependency_locked_text: .asciz "Verified every locked archive and source file.\n"
dependency_synced_text: .asciz "Synchronized the exact locked source dependencies.\n"
dependency_result_prefix: .asciz "{\"ok\":true,\"package\":"
dependency_result_cache: .asciz ",\"cache\":"
dependency_result_suffix: .asciz "}\n"
dependency_count_prefix: .asciz "{\"ok\":true,\"dependencies\":"
dependency_err_io: .asciz "cannot write dependency state. Check project permissions and .asm directory types"
dependency_err_lock: .asciz "asm.lock is invalid. Restore a valid lock file before using dependencies"
dependency_err_lock_missing: .asciz "asm.lock is missing. Use asm add with an exact package version"
dependency_err_cache_missing: .asciz "a locked package is missing. Run asm sync before building"
dependency_err_cache_changed: .asciz "source cache verification failed. Remove the changed package cache directory, then run asm sync"
dependency_err_archive: .asciz "the source archive is invalid. The lock file was not changed"
dependency_err_origin: .asciz "the registry differs from asm.lock. Use the locked registry origin"
dependency_err_already: .asciz "the dependency has another locked version. Use asm update with an exact version"
dependency_err_changed: .asciz "a locked version has different release metadata. The lock file was not changed"
dependency_err_selection: .asciz "the package is not in asm.lock. Use asm add to create its first selection"
dependency_err_busy: .asciz "another asm command uses this project. Try again after it finishes"
dependency_err_large: .asciz "the dependency lock would exceed 1 MiB. Remove an unused dependency first"

.section .data
.balign 8
dependency_lock_fd: .quad -1
.section .bss
.balign 8
dependency_new_record: .skip 64
dependency_replace_row: .skip 8
dependency_origin: .skip 8
dependency_new_origin: .skip 8
dependency_remove_name: .skip 8
dependency_sync_artifact: .skip 8
dependency_stat: .skip 144
dependency_package_path: .skip 256
dependency_archive_path: .skip 128
dependency_temp_lock: .skip 96
dependency_number: .skip 32
dependency_lock_buffer: .skip 1048578
.section .note.GNU-stack,"",@progbits
