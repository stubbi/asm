/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Installed programs are distinct from project source dependencies.
 * System V internal ABI: RDI/RSI/RDX inputs, RAX result.
 * Returning routines preserve RBX/RBP/R12-R15. Saves use 8 stack bytes.
 * RAX/RCX/RDX/RSI/RDI/R8-R11 and flags are scratch unless stated otherwise.
 * Linux syscalls use R10 for argument four; fstat writes 144-byte records.
 * Commands terminate; fatal paths retain the original error through cleanup.
 */
.intel_syntax noprefix
.equ PROGRAM_STAT_BYTES, 144
.equ PROGRAM_STAT_DEVICE, 0
.equ PROGRAM_STAT_INODE, 8
.equ PROGRAM_STAT_MODE, 24
.equ PROGRAM_STAT_LINKS, 16
.equ PROGRAM_STAT_UID, 28
.equ PROGRAM_STAT_SIZE, 48
.equ PROGRAM_LIMIT, 128
.equ PROGRAM_STATE_LIMIT, 1048576

.section .text
cmd_upgrade:
    mov qword ptr [rip + program_upgrade], 1
    mov r8d, 5
    lea r11, [rip + registry_mode]
    mov byte ptr [r11], r8b
    jmp registry_command
cmd_installed:
    jmp program_local_command
cmd_uninstall:
    mov qword ptr [rip + program_remove], 1

/* Parse local-only commands before touching the filesystem. Inputs are argv;
 * owns program_query. No registry access occurs. Stack: no local reservation. */
program_local_command:
    call next_arg
    test rax, rax
    jz .Lp_local_done
    mov qword ptr [rip + program_arg], rax
    mov rdi, rax
    lea rsi, [rip + registry_opt_json]
    call streq
    test eax, eax
    jnz .Lp_local_json
    mov rdi, qword ptr [rip + program_arg]
    lea rsi, [rip + registry_opt_no_color]
    call streq
    test eax, eax
    jnz program_local_command
    mov rdi, qword ptr [rip + program_arg]
    lea rsi, [rip + registry_opt_help]
    call streq
    test eax, eax
    jnz program_help
    mov rdi, qword ptr [rip + program_arg]
    movzx r8d, byte ptr [rdi]
    cmp r8d, 45
    je program_bad_args
    mov r8, qword ptr [rip + program_query]
    test r8, r8
    jnz program_bad_args
    mov r8, qword ptr [rip + program_remove]
    test r8, r8
    jz program_bad_args
    mov rdi, qword ptr [rip + program_arg]
    call registry_valid_package
    test eax, eax
    jz program_bad_args
    mov r8, qword ptr [rip + program_arg]
    mov qword ptr [rip + program_query], r8
    jmp program_local_command
.Lp_local_json:
    mov r8d, 1
    lea r11, [rip + json_mode]
    mov byte ptr [r11], r8b
    jmp program_local_command
.Lp_local_done:
    mov r8, qword ptr [rip + program_remove]
    test r8, r8
    jz .Lp_local_open
    mov r8, qword ptr [rip + program_query]
    test r8, r8
    jz program_bad_args
.Lp_local_open:
    mov edi, 0
    call program_open_state
    call program_read_state
    mov r8, qword ptr [rip + program_remove]
    test r8, r8
    jz program_list
    mov rdi, qword ptr [rip + program_query]
    call program_find
    test rax, rax
    jz program_not_managed
    mov qword ptr [rip + program_found], rax
    mov rsi, qword ptr [rax + 40]
    lea rdi, [rip + program_path]
    call copy_string
    call program_open_destination
    call program_check_existing
    call program_make_stage
    call program_write_state
    call program_recheck_destination
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    mov rdx, qword ptr [rip + program_stage_fd]
    lea r10, [rip + program_previous]
    mov eax, 264
    syscall
    test rax, rax
    js program_io_error
    mov qword ptr [rip + program_mutated], 1
    call program_commit_state
    test rax, rax
    js .Lp_uninstall_rollback
    mov qword ptr [rip + program_mutated], 0
    call registry_cleanup
    movzx r8d, byte ptr [rip + json_mode]
    test r8d, r8d
    jz exit_ok
    lea rdi, [rip + program_ok_json]
    call out
    jmp exit_ok
.Lp_uninstall_rollback:
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_previous]
    mov rdx, qword ptr [rip + program_dest_fd]
    mov r10, qword ptr [rip + program_dest_name]
    mov r8d, 1
    mov eax, 316
    syscall
    test rax, rax
    js program_recovery_error
    mov qword ptr [rip + program_mutated], 0
    jmp program_io_error

/* mode=5 preflight, called after arguments are validated but before index IO.
 * Acquires the inventory lock; its descriptor remains held until cleanup.
 * Upgrade reuses its recorded HTTPS origin unless explicitly overridden.
 * Local origins need --index because local index paths are not persisted.
 * Stack: one saved register. Preserves registry-selected pointers. */
program_before_load:
    push rbx
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jz .Lp_preflight_open
    mov r8, qword ptr [rip + registry_output]
    test r8, r8
    jnz program_bad_args
.Lp_preflight_open:
    mov edi, 1
    call program_open_state
    call program_read_state
    mov rdi, qword ptr [rip + registry_query]
    call program_find
    mov qword ptr [rip + program_found], rax
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jnz .Lp_preflight_upgrade
    test rax, rax
    jnz program_already_managed
    mov r8, qword ptr [rip + program_count]
    cmp r8, PROGRAM_LIMIT
    jae program_state_error
    pop rbx
    ret
.Lp_preflight_upgrade:
    test rax, rax
    jz program_not_managed
    mov rbx, rax
.ifdef ASM_REGISTRY_V2
    mov rdi, [rbx + 48]
    lea rsi, [rip + r2_origin_prefix]
    call self_prefix
    test rax, rax
    jnz r2_legacy_upgrade
.endif
    mov r8, qword ptr [rbx + 40]
    mov qword ptr [rip + registry_output], r8
    movzx r8d, byte ptr [rip + registry_origin_seen]
    test r8d, r8d
    jnz .Lp_preflight_origin
    mov rdi, qword ptr [rbx + 48]
    lea rsi, [rip + program_local]
    call streq
    test eax, eax
    jnz program_local_index_error
    mov r8, qword ptr [rbx + 48]
    mov qword ptr [rip + registry_url], r8
.Lp_preflight_origin:
    movzx r8d, byte ptr [rip + registry_local_index]
    test r8d, r8d
    jz .Lp_preflight_https
    lea rdi, [rip + program_local]
    jmp .Lp_preflight_compare
.Lp_preflight_https:
    mov rdi, qword ptr [rip + registry_url]
.Lp_preflight_compare:
    mov rsi, qword ptr [rbx + 48]
    call streq
    test eax, eax
    jz program_origin_error
    pop rbx
    ret

/* Validated selected registry row is borrowed from registry_selected. Before
 * transfer, upgrades check the managed bytes and reject older selections.
 * Equal selections require identical digest/size and leave files unchanged.
 * Stack: two saved registers. Buffer ownership stays with each parser. */
program_prepare_selection:
    push rbx
    push rbp
    mov rbx, qword ptr [rip + registry_selected]
    mov rbp, qword ptr [rip + program_found]
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jz .Lp_prepare_done
    mov rsi, qword ptr [rbp + 40]
    lea rdi, [rip + program_path]
    call copy_string
    call program_open_destination
    call program_check_existing
    mov rdi, qword ptr [rbx + 8]
    mov rsi, qword ptr [rbp + 8]
    call registry_version_compare
    cmp eax, 0
    jl program_downgrade_error
    jg .Lp_prepare_done
    mov rdi, qword ptr [rbx + 32]
    mov rsi, qword ptr [rbp + 24]
    call streq
    test eax, eax
    jz program_changed_release
    mov rdi, qword ptr [rbx + 48]
    mov rsi, qword ptr [rbp + 32]
    call streq
    test eax, eax
    jz program_changed_release
    call registry_cleanup
    movzx r8d, byte ptr [rip + json_mode]
    test r8d, r8d
    jz exit_ok
    lea rdi, [rip + program_unchanged_json]
    call out
    jmp exit_ok
.Lp_prepare_done:
    pop rbp
    pop rbx
    ret

/* Commit a checked executable. Candidate and rollback bytes are copied into a
 * private directory on the destination filesystem, fsynced, then renamed.
 * Inventory failure restores previous bytes/mode or removes a new install.
 * Power/process interruption between the two renames can leave a stage and
 * mismatched receipt. Directory crash durability and hostile same-UID races
 * are outside this advisory-lock contract. Stack: four saved registers. */
program_commit_install:
    push rbx
    push rbp
    push r12
    push r13
    mov rbx, qword ptr [rip + registry_selected]
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jnz .Lp_commit_opened
    mov rsi, qword ptr [rip + registry_output]
    call program_absolute_path
    call program_open_destination
    call program_check_new_path
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    lea rdx, [rip + program_check_stat]
    mov r10, 256
    mov eax, 262
    syscall
    cmp rax, -2
    jne program_destination_exists
.Lp_commit_opened:
    call program_make_stage
    lea rdi, [rip + registry_temp_payload]
    mov rsi, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov rdx, 0
    mov eax, 2
    syscall
    test rax, rax
    js program_io_error
    mov r12, rax
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_candidate]
    mov rdx, 493
    call program_copy_into_stage
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    syscall
    test r13, r13
    jnz program_io_error
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jz .Lp_commit_new_row
    mov rdi, qword ptr [rip + program_current_fd]
    mov rsi, 0
    mov rdx, 0
    mov eax, 8
    syscall
    test rax, rax
    js program_io_error
    mov r12, qword ptr [rip + program_current_fd]
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_previous]
    mov r8, qword ptr [rip + program_current_mode]
    mov rdx, r8
    and rdx, 1023
    call program_copy_into_stage
    test rax, rax
    jnz program_io_error
.Lp_commit_new_row:
    lea rbp, [rip + program_new_row]
    mov r8, qword ptr [rbx]
    mov r9, qword ptr [rbx + 8]
    mov qword ptr [rbp], r8
    mov qword ptr [rbp + 8], r9
    mov r8, qword ptr [rbx + 16]
    mov qword ptr [rbp + 16], r8
    mov r8, qword ptr [rbx + 32]
    mov qword ptr [rbp + 24], r8
    mov r8, qword ptr [rbx + 48]
    mov qword ptr [rbp + 32], r8
    lea r8, [rip + program_path]
    mov qword ptr [rbp + 40], r8
    movzx r8d, byte ptr [rip + registry_local_index]
    test r8d, r8d
    jz .Lp_commit_https
    lea r8, [rip + program_local]
    jmp .Lp_commit_origin_set
.Lp_commit_https:
    mov r8, qword ptr [rip + registry_url]
.Lp_commit_origin_set:
    mov qword ptr [rbp + 48], r8
    call program_write_state
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jz .Lp_commit_absent
    call program_recheck_destination
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_candidate]
    mov rdx, qword ptr [rip + program_dest_fd]
    mov r10, qword ptr [rip + program_dest_name]
    mov eax, 264
    syscall
    jmp .Lp_commit_payload_result
.Lp_commit_absent:
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_candidate]
    mov rdx, qword ptr [rip + program_dest_fd]
    mov r10, qword ptr [rip + program_dest_name]
    mov r8, 1
    mov eax, 316
    syscall
.Lp_commit_payload_result:
    test rax, rax
    js program_destination_exists
    mov qword ptr [rip + program_mutated], 1
    call program_commit_state
    test rax, rax
    js .Lp_commit_rollback
    mov qword ptr [rip + program_mutated], 0
    lea r8, [rip + program_path]
    mov qword ptr [rip + registry_output], r8
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lp_commit_rollback:
    mov r8, qword ptr [rip + program_upgrade]
    test r8, r8
    jz .Lp_commit_rollback_install
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_previous]
    mov rdx, qword ptr [rip + program_dest_fd]
    mov r10, qword ptr [rip + program_dest_name]
    mov eax, 264
    syscall
    jmp .Lp_commit_rollback_result
.Lp_commit_rollback_install:
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    mov rdx, 0
    mov eax, 263
    syscall
.Lp_commit_rollback_result:
    test rax, rax
    js program_recovery_error
    mov qword ptr [rip + program_mutated], 0
    jmp program_io_error

/* RSI=nonempty relative/absolute output <=4095. Produces absolute program_path
 * without resolving symlinks. The descriptor walk rejects '.'/'..' and empty
 * components. Buffers: cwd/path 4096 each. Stack: two saved registers. */
program_absolute_path:
    push rbx
    push rbp
    mov rbx, rsi
    mov rdi, rsi
    call strlen
    mov rbp, rax
    movzx r8d, byte ptr [rbx]
    cmp r8d, 47
    je .Lp_absolute_copy
    lea rdi, [rip + program_cwd]
    mov rsi, 4096
    mov eax, 79
    syscall
    test rax, rax
    js program_path_error
    lea rdi, [rip + program_cwd]
    call strlen
    lea r8, [rax + rbp]
    lea r8, [r8 + 1]
    cmp r8, 4095
    ja program_path_error
    lea rdi, [rip + program_path]
    lea rsi, [rip + program_cwd]
    call copy_string
    mov r8d, 47
    mov byte ptr [rax], r8b
    lea rax, [rax + 1]
    mov rdi, rax
    mov rsi, rbx
    call copy_string
    jmp .Lp_absolute_done
.Lp_absolute_copy:
    cmp rbp, 4095
    ja program_path_error
    lea rdi, [rip + program_path]
    mov rsi, rbx
    call copy_string
.Lp_absolute_done:
    pop rbp
    pop rbx
    ret

/* RDI=create state directories (0/1). HOME must be absolute <=3800 bytes.
 * Opens protected directory ancestors and acquires a nonblocking exclusive
 * directory flock. Missing state in read-only mode is an empty inventory.
 * Stack: two saved registers. All held descriptors belong to this process. */
program_open_state:
    push rbx
    push rbp
    mov rbp, rdi
    mov eax, 102
    syscall
    mov qword ptr [rip + program_uid], rax
    mov rbx, rax
    mov eax, 107
    syscall
    cmp rax, rbx
    jne program_path_error
    mov rbx, qword ptr [rip + envp]
.Lp_home_loop:
    mov rdi, qword ptr [rbx]
    lea rbx, [rbx + 8]
    test rdi, rdi
    jz program_path_error
    movzx r8d, byte ptr [rdi]
    cmp r8d, 72
    jne .Lp_home_loop
    movzx r8d, byte ptr [rdi + 1]
    cmp r8d, 79
    jne .Lp_home_loop
    movzx r8d, byte ptr [rdi + 2]
    cmp r8d, 77
    jne .Lp_home_loop
    movzx r8d, byte ptr [rdi + 3]
    cmp r8d, 69
    jne .Lp_home_loop
    movzx r8d, byte ptr [rdi + 4]
    cmp r8d, 61
    jne .Lp_home_loop
    lea rbx, [rdi + 5]
    movzx r8d, byte ptr [rbx]
    cmp r8d, 47
    jne program_path_error
    mov rdi, rbx
    call strlen
    cmp rax, 3800
    ja program_path_error
    cmp rax, 1
    jbe program_path_error
    mov qword ptr [rip + program_home_length], rax
    mov qword ptr [rip + program_home], rbx
    lea rdi, [rip + program_state_path]
    mov rsi, rbx
    call copy_string
    mov rdi, rax
    lea rsi, [rip + program_state_suffix]
    call copy_string
    lea rdi, [rip + program_state_path]
    mov rsi, rbp
    call program_walk_parent
    cmp rax, -2
    je .Lp_state_missing
    test rax, rax
    js program_path_error
    mov qword ptr [rip + program_state_fd], rax
    mov rdi, rax
    mov rsi, 6
    mov eax, 73
    syscall
    test rax, rax
    js program_busy_error
.Lp_state_missing:
    pop rbp
    pop rbx
    ret

/* RDI=absolute mutable path <=4095, RSI=allow mkdir below HOME (0/1).
 * RAX=owned parent FD or negative errno; program_basename borrows final name.
 * Rejects symlinks, traversal, ASCII controls, invalid UTF-8 and >255-byte names.
 * Ancestors must be root/user owned and deny group/other writes. HOME and
 * descendants must belong to this UID. Exact root-owned sticky /tmp and
 * /private/tmp are exceptions above HOME; their child must be user-owned.
 * Uses descriptor-relative opens and restores temporary NUL separators.
 * Stack: six saved registers and 16 local bytes; stat scratch is 144 bytes. */
program_walk_parent:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov qword ptr [rsp], 0
    mov rbx, rdi
    mov rbp, rsi
    mov rdi, rbx
    call program_valid_absolute_path
    test eax, eax
    jz .Lp_walk_bad_initial
    movzx r8d, byte ptr [rbx]
    cmp r8d, 47
    jne .Lp_walk_bad_initial
    lea rdi, [rip + program_root]
    mov rsi, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov rdx, 0
    mov eax, 2
    syscall
    test rax, rax
    js .Lp_walk_return
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + program_walk_stat]
    mov eax, 5
    syscall
    test rax, rax
    js .Lp_walk_bad
    lea r11, [rip + program_walk_stat]
    mov r8d, dword ptr [r11 + PROGRAM_STAT_MODE]
    mov r10d, 18
    test r8d, r10d
    jne .Lp_walk_bad
    mov r8d, dword ptr [r11 + PROGRAM_STAT_UID]
    test r8d, r8d
    jz .Lp_walk_root_owned
    mov r9, qword ptr [rip + program_uid]
    cmp r8d, r9d
    jne .Lp_walk_bad
.Lp_walk_root_owned:
    lea r13, [rbx + 1]
    /* Only matching HOME descendants inherit the user-only ownership rule. */
    mov rsi, qword ptr [rip + program_home]
    mov rdx, rbx
.Lp_walk_home_prefix:
    movzx r8d, byte ptr [rsi]
    lea rsi, [rsi + 1]
    test r8d, r8d
    jz .Lp_walk_home_prefix_end
    movzx r9d, byte ptr [rdx]
    lea rdx, [rdx + 1]
    cmp r8d, r9d
    jne .Lp_walk_outside_home
    jmp .Lp_walk_home_prefix
.Lp_walk_home_prefix_end:
    movzx r8d, byte ptr [rdx]
    cmp r8d, 47
    jne .Lp_walk_outside_home
    mov r15, qword ptr [rip + program_home_length]
    jmp .Lp_walk_component
.Lp_walk_outside_home:
    mov r15, -1
.Lp_walk_component:
    mov r14, r13
.Lp_walk_scan:
    movzx r8d, byte ptr [r14]
    test r8d, r8d
    jz .Lp_walk_final
    cmp r8d, 47
    je .Lp_walk_separator
    cmp r8d, 32
    jb .Lp_walk_bad
    cmp r8d, 127
    je .Lp_walk_bad
    mov r9, r14
    sub r9, r13
    cmp r9, 254
    ja .Lp_walk_bad
    lea r14, [r14 + 1]
    jmp .Lp_walk_scan
.Lp_walk_separator:
    cmp r14, r13
    je .Lp_walk_bad
    mov byte ptr [r14], 0
    call program_component_valid
    test eax, eax
    jz .Lp_walk_bad_restore
    mov rdi, r12
    mov rsi, r13
    mov rdx, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov r10, 0
    mov eax, 257
    syscall
    cmp rax, -2
    jne .Lp_walk_open_result
    test rbp, rbp
    jz .Lp_walk_open_result
    mov r8, r13
    sub r8, rbx
    cmp r8, r15
    jb .Lp_walk_open_result
    mov rdi, r12
    mov rsi, r13
    mov rdx, 448
    mov eax, 258
    syscall
    test rax, rax
    jnz .Lp_walk_open_result
    mov rdi, r12
    mov rsi, r13
    mov rdx, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov r10, 0
    mov eax, 257
    syscall
.Lp_walk_open_result:
    mov r8, rax
    mov r9d, 47
    mov byte ptr [r14], r9b
    test r8, r8
    js .Lp_walk_close_error
    mov rdi, r12
    mov r12, r8
    mov eax, 3
    syscall
    mov rdi, r12
    lea rsi, [rip + program_walk_stat]
    mov eax, 5
    syscall
    test rax, rax
    js .Lp_walk_bad
    /* A directory identity, rather than its spelling, reserves state on
     * case-insensitive filesystems too. Refuse its entire descendant tree. */
    mov rdi, qword ptr [rip + program_state_fd]
    test rdi, rdi
    js .Lp_walk_not_state
    lea rsi, [rip + program_check_stat]
    mov eax, 5
    syscall
    test rax, rax
    js .Lp_walk_bad
    lea rdi, [rip + program_walk_stat]
    lea rsi, [rip + program_check_stat]
    mov r8, qword ptr [rdi + PROGRAM_STAT_DEVICE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_DEVICE]
    cmp r8, r9
    jne .Lp_walk_not_state
    mov r8, qword ptr [rdi + PROGRAM_STAT_INODE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_INODE]
    cmp r8, r9
    je .Lp_walk_bad
.Lp_walk_not_state:
    lea r11, [rip + program_walk_stat]
    mov r8d, dword ptr [r11 + PROGRAM_STAT_MODE]
    mov r9d, r8d
    and r9d, 61440
    cmp r9d, 16384
    jne .Lp_walk_bad
    mov r9d, dword ptr [r11 + PROGRAM_STAT_UID]
    mov rdx, qword ptr [rip + program_uid]
    mov rcx, r14
    sub rcx, rbx
    cmp rcx, r15
    jae .Lp_walk_user
    mov r10, qword ptr [rsp]
    test r10, r10
    jnz .Lp_walk_user
    test r9d, r9d
    jz .Lp_walk_mode
.Lp_walk_user:
    cmp r9d, edx
    jne .Lp_walk_bad
.Lp_walk_mode:
    mov r10d, 18
    test r8d, r10d
    je .Lp_walk_protected
    test r9d, r9d
    jnz .Lp_walk_bad
    test r8d, 512
    je .Lp_walk_bad
    cmp rcx, r15
    jae .Lp_walk_bad
    cmp rcx, 4
    je .Lp_walk_tmp4
    cmp rcx, 12
    jne .Lp_walk_bad
    lea rsi, [rip + program_private_tmp]
    jmp .Lp_walk_check_tmp
.Lp_walk_tmp4:
    lea rsi, [rip + program_tmp]
.Lp_walk_check_tmp:
    mov r8d, 0
    mov byte ptr [r14], r8b
    mov rdi, rbx
    call streq
    mov r8d, 47
    mov byte ptr [r14], r8b
    test eax, eax
    jz .Lp_walk_bad
    mov r8, 1
    mov qword ptr [rsp], r8
    jmp .Lp_walk_next
.Lp_walk_protected:
    mov qword ptr [rsp], 0
.Lp_walk_next:
    lea r13, [r14 + 1]
    jmp .Lp_walk_component
.Lp_walk_final:
    cmp r14, r13
    je .Lp_walk_bad
    call program_component_valid
    test eax, eax
    jz .Lp_walk_bad
    mov qword ptr [rip + program_basename], r13
    mov rax, r12
    jmp .Lp_walk_return
.Lp_walk_bad_restore:
    mov r8d, 47
    mov byte ptr [r14], r8b
.Lp_walk_bad:
    mov r8, -13
.Lp_walk_close_error:
    mov qword ptr [rsp + 8], r8
    mov rdi, r12
    mov eax, 3
    syscall
    mov rax, qword ptr [rsp + 8]
    jmp .Lp_walk_return
.Lp_walk_bad_initial:
    mov rax, -22
.Lp_walk_return:
    lea rsp, [rsp + 16]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
/* R13=NUL component; EAX=1 except '.'/'..'; no stack or memory changes. */
program_component_valid:
    movzx r8d, byte ptr [r13]
    cmp r8d, 46
    jne .Lp_component_good
    movzx r8d, byte ptr [r13 + 1]
    test r8d, r8d
    jz .Lp_component_bad
    cmp r8d, 46
    jne .Lp_component_good
    movzx r8d, byte ptr [r13 + 2]
    test r8d, r8d
    jz .Lp_component_bad
.Lp_component_good:
    mov eax, 1
    ret
.Lp_component_bad:
    mov eax, 0
    ret

/* Opens the constructed destination's protected parent, retains its FD and
 * basename, and reserves HOME/.local/bin/asm for the provenance updater.
 * No directory is created. Stack: one saved register. */
program_open_destination:
    push rbx
    lea rdi, [rip + program_reserved_path]
    mov rsi, qword ptr [rip + program_home]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + program_reserved_suffix]
    call copy_string
    lea rdi, [rip + program_path]
    lea rsi, [rip + program_reserved_path]
    call streq
    test eax, eax
    jnz program_reserved_error
    lea rdi, [rip + program_state_path]
    call strlen
    mov rdx, rax
    sub rdx, 13 /* installed.tsv */
    lea rdi, [rip + program_path]
    lea rsi, [rip + program_state_path]
.Lp_destination_internal:
    test rdx, rdx
    jz program_internal_error
    movzx r8d, byte ptr [rdi]
    lea rdi, [rdi + 1]
    movzx r9d, byte ptr [rsi]
    lea rsi, [rsi + 1]
    cmp r8d, r9d
    jne .Lp_destination_external
    sub rdx, 1
    jmp .Lp_destination_internal
.Lp_destination_external:
    lea rdi, [rip + program_path]
    mov rsi, 0
    call program_walk_parent
    test rax, rax
    js program_path_error
    mov qword ptr [rip + program_dest_fd], rax
    mov r8, qword ptr [rip + program_basename]
    mov qword ptr [rip + program_dest_name], r8
    call program_check_cli_destination
    movzx r8d, byte ptr [rip + registry_has_workspace]
    test r8d, r8d
    jz .Lp_destination_workspace_safe
    lea rdi, [rip + registry_temp_dir]
    mov rsi, O_DIRECTORY + O_CLOEXEC + O_NOFOLLOW
    mov rdx, 0
    mov eax, 2
    syscall
    test rax, rax
    js program_path_error
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + program_walk_stat]
    mov eax, 5
    syscall
    mov qword ptr [rip + program_internal_stat_result], rax
    mov rdi, rbx
    mov eax, 3
    syscall
    mov rax, qword ptr [rip + program_internal_stat_result]
    test rax, rax
    js program_path_error
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rsi, [rip + program_check_stat]
    mov eax, 5
    syscall
    test rax, rax
    js program_path_error
    lea rdi, [rip + program_walk_stat]
    lea rsi, [rip + program_check_stat]
    mov r8, qword ptr [rdi + PROGRAM_STAT_DEVICE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_DEVICE]
    cmp r8, r9
    jne .Lp_destination_workspace_safe
    mov r8, qword ptr [rdi + PROGRAM_STAT_INODE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_INODE]
    cmp r8, r9
    je program_internal_error
.Lp_destination_workspace_safe:
    pop rbx
    ret

/* Reserve case aliases of the CLI basename by the actual bin directory
 * identity. Never assume that path spelling identifies a filesystem entry.
 * Input: destination FD/name and constructed reserved_path. Stack: two saves.
 * A missing default bin directory cannot alias an existing destination parent. */
program_check_cli_destination:
    push rbx
    push rbp
    mov rdi, qword ptr [rip + program_dest_name]
    movzx r8d, byte ptr [rdi]
    or r8d, 32
    cmp r8d, 97
    jne .Lp_cli_destination_safe
    movzx r8d, byte ptr [rdi + 1]
    or r8d, 32
    cmp r8d, 115
    jne .Lp_cli_destination_safe
    movzx r8d, byte ptr [rdi + 2]
    or r8d, 32
    cmp r8d, 109
    jne .Lp_cli_destination_safe
    movzx r8d, byte ptr [rdi + 3]
    test r8d, r8d
    jnz .Lp_cli_destination_safe
    lea rdi, [rip + program_reserved_path]
    mov rsi, 0
    call program_walk_parent
    test rax, rax
    js .Lp_cli_destination_safe
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + program_walk_stat]
    mov eax, 5
    syscall
    mov rbp, rax
    mov rdi, rbx
    mov eax, 3
    syscall
    test rbp, rbp
    js program_path_error
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rsi, [rip + program_check_stat]
    mov eax, 5
    syscall
    test rax, rax
    js program_path_error
    lea rdi, [rip + program_walk_stat]
    lea rsi, [rip + program_check_stat]
    mov r8, qword ptr [rdi + PROGRAM_STAT_DEVICE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_DEVICE]
    cmp r8, r9
    jne .Lp_cli_destination_safe
    mov r8, qword ptr [rdi + PROGRAM_STAT_INODE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_INODE]
    cmp r8, r9
    je program_reserved_error
.Lp_cli_destination_safe:
    pop rbp
    pop rbx
    ret

/* Read a regular, owned, protected single-link inventory. Empty/missing files
 * are distinct: missing means no programs; an empty file is malformed.
 * All bytes are bounded before parsing; no results print until validation.
 * Stack: two saved registers. program_input has limit+1 byte capacity. */
program_read_state:
    push rbx
    push rbp
    mov qword ptr [rip + program_count], 0
    mov rdi, qword ptr [rip + program_state_fd]
    test rdi, rdi
    js .Lp_read_done
    lea rsi, [rip + program_state_name]
    mov rdx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov r10, 0
    mov eax, 257
    syscall
    cmp rax, -2
    je .Lp_read_done
    test rax, rax
    js program_state_error
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + program_check_stat]
    mov eax, 5
    syscall
    test rax, rax
    js .Lp_read_bad
    lea rdi, [rip + program_check_stat]
    call program_regular_stat
    test eax, eax
    jz .Lp_read_bad
    lea r11, [rip + program_check_stat]
    mov r8, qword ptr [r11 + PROGRAM_STAT_SIZE]
    mov r9, PROGRAM_STATE_LIMIT
    cmp r8, r9
    ja .Lp_read_bad
    mov rbp, 0
.Lp_read_loop:
    mov rdi, rbx
    lea rsi, [rip + program_input]
    lea rsi, [rsi + rbp]
    mov rdx, PROGRAM_STATE_LIMIT + 1
    sub rdx, rbp
    mov eax, 0
    syscall
    cmp rax, -4
    je .Lp_read_loop
    test rax, rax
    js .Lp_read_bad
    test rax, rax
    jz .Lp_read_eof
    lea rbp, [rbp + rax]
    mov r8, PROGRAM_STATE_LIMIT
    cmp rbp, r8
    ja .Lp_read_bad
    jmp .Lp_read_loop
.Lp_read_eof:
    mov rdi, rbx
    mov eax, 3
    syscall
    mov qword ptr [rip + program_input_size], rbp
    call program_parse_state
.Lp_read_done:
    pop rbp
    pop rbx
    ret
.Lp_read_bad:
    mov rdi, rbx
    mov eax, 3
    syscall
    jmp program_state_error

/* Parses seven TSV fields per record; metadata is printable ASCII, <=128 records. Borrowed
 * pointers have process lifetime in program_input. Every field is validated,
 * including duplicates, before any mutation. Stack: six saved registers. */
program_parse_state:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    lea rbx, [rip + program_input]
    mov rbp, qword ptr [rip + program_input_size]
    lea rbp, [rbp + rbx]
    lea r12, [rip + program_header]
.Lp_parse_header:
    movzx r8d, byte ptr [r12]
    lea r12, [r12 + 1]
    test r8d, r8d
    jz .Lp_parse_row
    cmp rbx, rbp
    jae program_state_error
    movzx r9d, byte ptr [rbx]
    lea rbx, [rbx + 1]
    cmp r8d, r9d
    jne program_state_error
    jmp .Lp_parse_header
.Lp_parse_row:
    cmp rbx, rbp
    je .Lp_parse_done
    mov r14, qword ptr [rip + program_count]
    cmp r14, PROGRAM_LIMIT
    jae program_state_error
    lea r12, [rip + program_rows]
    mov r11, r14
    shl r11, 6
    lea r12, [r12 + r11]
    mov qword ptr [r12], rbx
    mov r13, 0
    mov r15, rbx
.Lp_parse_char:
    cmp rbx, rbp
    jae program_state_error
    movzx r8d, byte ptr [rbx]
    cmp r8d, 9
    je .Lp_parse_tab
    cmp r8d, 10
    je .Lp_parse_newline
    cmp r8d, 32
    jb program_state_error
    cmp r8d, 127
    je program_state_error
    jb .Lp_parse_ascii
    cmp r13, 5
    jne program_state_error
.Lp_parse_ascii:
    mov r9, rbx
    sub r9, r15
    cmp r9, 4094
    ja program_state_error
    lea rbx, [rbx + 1]
    jmp .Lp_parse_char
.Lp_parse_tab:
    cmp rbx, r15
    je program_state_error
    cmp r13, 6
    jae program_state_error
    mov byte ptr [rbx], 0
    lea rbx, [rbx + 1]
    lea r13, [r13 + 1]
    mov qword ptr [r12 + r13*8], rbx
    mov r15, rbx
    jmp .Lp_parse_char
.Lp_parse_newline:
    cmp r13, 6
    jne program_state_error
    cmp rbx, r15
    je program_state_error
    mov byte ptr [rbx], 0
    lea rbx, [rbx + 1]
    mov rdi, r12
    call program_validate_row
    lea r14, [r14 + 1]
    mov qword ptr [rip + program_count], r14
    jmp .Lp_parse_row
.Lp_parse_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=seven-pointer row; checks canonical identities/size/hash, absolute path,
 * HTTPS/local origin, and uniqueness against earlier rows. Stack: 3 saves. */
program_validate_row:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    mov rdi, qword ptr [rbx]
    call registry_valid_package
    test eax, eax
    jz program_state_error
    mov rdi, qword ptr [rbx + 8]
    call registry_valid_version
    test eax, eax
    jz program_state_error
    mov rdi, qword ptr [rbx + 16]
    call registry_valid_target
    test eax, eax
    jz program_state_error
    mov rdi, qword ptr [rbx + 24]
    call strlen
    cmp rax, 64
    jne program_state_error
    mov rdi, qword ptr [rbx + 24]
    mov rdx, 0
.Lp_validate_hash:
    movzx r8d, byte ptr [rdi + rdx]
    cmp r8d, 48
    jb program_state_error
    cmp r8d, 57
    jbe .Lp_validate_hash_next
    cmp r8d, 97
    jb program_state_error
    cmp r8d, 102
    ja program_state_error
.Lp_validate_hash_next:
    lea rdx, [rdx + 1]
    cmp rdx, 64
    jb .Lp_validate_hash
    movzx r8d, byte ptr [rdi + 64]
    test r8d, r8d
    jnz program_state_error
    mov rdi, qword ptr [rbx + 32]
    call registry_size_value
    test rax, rax
    jz program_state_error
    mov rdi, qword ptr [rbx + 40]
    call program_valid_absolute_path
    test eax, eax
    jz program_state_error
    mov rdi, qword ptr [rbx + 40]
    movzx r8d, byte ptr [rdi]
    cmp r8d, 47
    jne program_state_error
    mov rdi, qword ptr [rbx + 48]
    lea rsi, [rip + program_local]
    call streq
    test eax, eax
    jnz .Lp_validate_unique
    mov rdi, qword ptr [rbx + 48]
.ifdef ASM_REGISTRY_V2
    call r2_inventory_origin
    test eax, eax
    jnz .Lp_validate_unique
    mov rdi, qword ptr [rbx + 48]
.endif
    call registry_https_url
    test eax, eax
    jz program_state_error
.Lp_validate_unique:
    lea rbp, [rip + program_rows]
.Lp_validate_duplicate:
    cmp rbp, rbx
    je .Lp_validate_done
    mov rdi, qword ptr [rbx]
    mov rsi, qword ptr [rbp]
    call streq
    test eax, eax
    jnz program_state_error
    mov rdi, qword ptr [rbx + 40]
    mov rsi, qword ptr [rbp + 40]
    call streq
    test eax, eax
    jnz program_state_error
    lea rbp, [rbp + 64]
    jmp .Lp_validate_duplicate
.Lp_validate_done:
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=canonical package; RAX=borrowed matching row or zero. Stack: 3 saves. */
program_find:
    push rbx
    push rbp
    push r12
    mov rbx, rdi
    lea rbp, [rip + program_rows]
    mov r12, qword ptr [rip + program_count]
.Lp_find_loop:
    test r12, r12
    jz .Lp_find_absent
    mov rdi, rbx
    mov rsi, qword ptr [rbp]
    call streq
    test eax, eax
    jnz .Lp_find_found
    lea rbp, [rbp + 64]
    sub r12, 1
    jmp .Lp_find_loop
.Lp_find_absent:
    mov rax, 0
    jmp .Lp_find_done
.Lp_find_found:
    mov rax, rbp
.Lp_find_done:
    pop r12
    pop rbp
    pop rbx
    ret

/* RDI=NUL-terminated text <=4095 bytes; EAX=1 for canonical UTF-8. Rejects
 * overlong encodings, surrogate code points, and values above U+10FFFF.
 * No writes or stack use. Scratch RDI,RDX,R8,R9; stops at the first NUL. */
program_valid_utf8:
.Lp_utf8_next:
    movzx r8d, byte ptr [rdi]
    lea rdi, [rdi + 1]
    test r8d, r8d
    jz .Lp_utf8_good
    cmp r8d, 128
    jb .Lp_utf8_next
    cmp r8d, 194
    jb .Lp_utf8_bad
    cmp r8d, 224
    jb .Lp_utf8_one
    cmp r8d, 240
    jb .Lp_utf8_three
    cmp r8d, 245
    jae .Lp_utf8_bad
    movzx r9d, byte ptr [rdi]
    lea rdi, [rdi + 1]
    cmp r9d, 128
    jb .Lp_utf8_bad
    cmp r9d, 192
    jae .Lp_utf8_bad
    cmp r8d, 240
    jne .Lp_utf8_four_upper
    cmp r9d, 144
    jb .Lp_utf8_bad
.Lp_utf8_four_upper:
    cmp r8d, 244
    jne .Lp_utf8_four_tail
    cmp r9d, 144
    jae .Lp_utf8_bad
.Lp_utf8_four_tail:
    mov edx, 2
    jmp .Lp_utf8_tail
.Lp_utf8_three:
    movzx r9d, byte ptr [rdi]
    lea rdi, [rdi + 1]
    cmp r9d, 128
    jb .Lp_utf8_bad
    cmp r9d, 192
    jae .Lp_utf8_bad
    cmp r8d, 224
    jne .Lp_utf8_three_upper
    cmp r9d, 160
    jb .Lp_utf8_bad
.Lp_utf8_three_upper:
    cmp r8d, 237
    jne .Lp_utf8_one
    cmp r9d, 160
    jae .Lp_utf8_bad
.Lp_utf8_one:
    mov edx, 1
.Lp_utf8_tail:
    movzx r9d, byte ptr [rdi]
    lea rdi, [rdi + 1]
    cmp r9d, 128
    jb .Lp_utf8_bad
    cmp r9d, 192
    jae .Lp_utf8_bad
    sub edx, 1
    jne .Lp_utf8_tail
    jmp .Lp_utf8_next
.Lp_utf8_good:
    mov eax, 1
    ret
.Lp_utf8_bad:
    mov eax, 0
    ret

/* RDI=NUL path <=4095 bytes; EAX=1 for an absolute canonical UTF-8 file path.
 * Reject controls, empty components, '.'/'..', and names above 255 bytes.
 * Pure validation does not open files, so listing detects malformed receipts
 * even when destinations are absent. Stack: one saved register. */
program_valid_absolute_path:
    push rbx
    mov rbx, rdi
    call program_valid_utf8
    test eax, eax
    jz .Lp_path_invalid
    movzx r8d, byte ptr [rbx]
    cmp r8d, 47
    jne .Lp_path_invalid
    lea rsi, [rbx + 1]
    mov rdx, rsi
.Lp_path_scan:
    movzx r8d, byte ptr [rdx]
    test r8d, r8d
    jz .Lp_path_component
    cmp r8d, 47
    je .Lp_path_component
    cmp r8d, 32
    jb .Lp_path_invalid
    cmp r8d, 127
    je .Lp_path_invalid
    lea rdx, [rdx + 1]
    jmp .Lp_path_scan
.Lp_path_component:
    mov rcx, rdx
    sub rcx, rsi
    test rcx, rcx
    jz .Lp_path_invalid
    cmp rcx, 255
    ja .Lp_path_invalid
    cmp rcx, 2
    ja .Lp_path_component_valid
    movzx r9d, byte ptr [rsi]
    cmp r9d, 46
    jne .Lp_path_component_valid
    cmp rcx, 1
    je .Lp_path_invalid
    movzx r9d, byte ptr [rsi + 1]
    cmp r9d, 46
    je .Lp_path_invalid
.Lp_path_component_valid:
    test r8d, r8d
    jz .Lp_path_valid
    lea rsi, [rdx + 1]
    mov rdx, rsi
    jmp .Lp_path_scan
.Lp_path_invalid:
    mov eax, 0
    pop rbx
    ret
.Lp_path_valid:
    mov eax, 1
    pop rbx
    ret

/* A missing file still belongs to its installation record. Compare actual
 * parent directory identities, then let that directory resolve the names.
 * Only a parent collision needs a probe. One O_EXCL mode-000 empty file at
 * the new destination exposes the filesystem's exact case/Unicode rules.
 * No data is written and no execution is possible. Remove the owned probe
 * before staging the executable. An interruption can leave an empty inert
 * new destination; previous files and inventory bytes remain unchanged.
 * Inputs: held destination FD/name, canonical program_path, <=128 rows.
 * Names are borrowed from parsed rows; names[129] includes reserved asm.
 * Stack: six saved registers. No shell, child, or Unicode approximation.
 */
program_check_new_path:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rsi, [rip + program_alias_parent_stat]
    mov eax, 5
    syscall
    test rax, rax
    js program_path_error
    lea rbx, [rip + program_rows]
    mov rbp, qword ptr [rip + program_count]
    mov r13, 0
.Lp_new_path_loop:
    test rbp, rbp
    jz .Lp_new_path_cli
    lea rdi, [rip + program_path]
    mov rsi, qword ptr [rbx + 40]
    call streq
    test eax, eax
    jnz program_destination_exists
    mov rdi, qword ptr [rbx + 40]
    mov rsi, 0
    call program_walk_parent
    cmp rax, -2
    je .Lp_new_path_next
    test rax, rax
    js program_path_error
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + program_alias_record_stat]
    mov eax, 5
    syscall
    mov r14, rax
    mov rdi, r12
    mov eax, 3
    syscall
    test r14, r14
    js program_path_error
    lea rdi, [rip + program_alias_parent_stat]
    lea rsi, [rip + program_alias_record_stat]
    call program_same_identity
    test eax, eax
    jz .Lp_new_path_next
    mov r8, qword ptr [rip + program_basename]
    lea r11, [rip + program_alias_names]
    mov qword ptr [r11 + r13*8], r8
    lea r13, [r13 + 1]
.Lp_new_path_next:
    lea rbx, [rbx + 64]
    sub rbp, 1
    jmp .Lp_new_path_loop
.Lp_new_path_cli:
    /* Reserve filesystem aliases of asm, including Unicode case aliases. */
    lea rdi, [rip + program_reserved_path]
    mov rsi, 0
    call program_walk_parent
    test rax, rax
    js .Lp_new_path_probe
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + program_alias_record_stat]
    mov eax, 5
    syscall
    mov r14, rax
    mov rdi, r12
    mov eax, 3
    syscall
    test r14, r14
    js program_path_error
    lea rdi, [rip + program_alias_parent_stat]
    lea rsi, [rip + program_alias_record_stat]
    call program_same_identity
    test eax, eax
    jz .Lp_new_path_probe
    lea r8, [rip + program_cli_name]
    lea r11, [rip + program_alias_names]
    mov qword ptr [r11 + r13*8], r8
    lea r13, [r13 + 1]
.Lp_new_path_probe:
    test r13, r13
    jz .Lp_new_path_done
    mov qword ptr [rip + program_alias_count], r13
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    mov rdx, O_NOFOLLOW + O_CLOEXEC + 193
    mov r10, 0
    mov eax, 257
    syscall
    cmp rax, -17
    je program_destination_exists
    test rax, rax
    js program_probe_error
    mov qword ptr [rip + program_probe_fd], rax
    mov qword ptr [rip + program_probe_active], 1
    mov rdi, rax
    lea rsi, [rip + program_probe_stat]
    mov eax, 5
    syscall
    test rax, rax
    js program_probe_error
    mov r15, 0
.Lp_new_path_lookup:
    lea r11, [rip + program_alias_names]
    mov rsi, qword ptr [r11 + r15*8]
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rdx, [rip + program_probe_entry_stat]
    mov r10, 256
    mov eax, 262
    syscall
    cmp rax, -2
    je .Lp_new_path_lookup_next
    test rax, rax
    js program_probe_error
    lea rdi, [rip + program_probe_stat]
    lea rsi, [rip + program_probe_entry_stat]
    call program_same_identity
    test eax, eax
    jnz .Lp_new_path_collision
.Lp_new_path_lookup_next:
    lea r15, [r15 + 1]
    cmp r15, r13
    jb .Lp_new_path_lookup
    call program_remove_probe
    test rax, rax
    jnz program_probe_error
.Lp_new_path_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lp_new_path_collision:
    call program_remove_probe
    test rax, rax
    jnz program_probe_error
    lea r11, [rip + program_alias_names]
    mov r8, qword ptr [r11 + r15*8]
    lea r9, [rip + program_cli_name]
    cmp r8, r9
    je program_reserved_error
    jmp program_destination_exists

/* RDI/RSI=normalized stat structures. EAX=1 only for equal device and inode.
 * Identity comparison grants no ownership, permission, or digest result.
 * No stack or writes; scratch R8/R9. */
program_same_identity:
    mov r8, qword ptr [rdi + PROGRAM_STAT_DEVICE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_DEVICE]
    cmp r8, r9
    jne .Lp_identity_different
    mov r8, qword ptr [rdi + PROGRAM_STAT_INODE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_INODE]
    cmp r8, r9
    jne .Lp_identity_different
    mov eax, 1
    ret
.Lp_identity_different:
    mov eax, 0
    ret

/* Remove only a destination that still identifies the held exclusive probe.
 * A replacement entry is retained. ENOENT means absence already holds.
 * RAX=0 on restored absence, -1 if inspection/removal/close fails. Never exits.
 * The probe FD is closed on every path. Same-UID races remain outside the
 * advisory-lock contract; identity is rechecked before each unlink attempt.
 * Stack: two saved registers. No writes to file contents or inventory.
 */
program_remove_probe:
    push rbx
    push rbp
    mov rbp, 0
    mov r8, qword ptr [rip + program_probe_active]
    test r8, r8
    jz .Lp_probe_remove_done
    mov rbx, qword ptr [rip + program_probe_fd]
    test rbx, rbx
    js .Lp_probe_remove_bad
    mov rdi, rbx
    lea rsi, [rip + program_probe_stat]
    mov eax, 5
    syscall
    test rax, rax
    js .Lp_probe_remove_bad
.Lp_probe_remove_check:
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    lea rdx, [rip + program_probe_entry_stat]
    mov r10, 256
    mov eax, 262
    syscall
    cmp rax, -2
    je .Lp_probe_remove_close
    test rax, rax
    js .Lp_probe_remove_bad
    lea rdi, [rip + program_probe_stat]
    lea rsi, [rip + program_probe_entry_stat]
    call program_same_identity
    test eax, eax
    jz .Lp_probe_remove_bad
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    mov rdx, 0
    mov eax, 263
    syscall
    cmp rax, -4
    je .Lp_probe_remove_check
    test rax, rax
    js .Lp_probe_remove_bad
    jmp .Lp_probe_remove_close
.Lp_probe_remove_bad:
    mov rbp, -1
.Lp_probe_remove_close:
    mov rdi, qword ptr [rip + program_probe_fd]
    test rdi, rdi
    js .Lp_probe_remove_clear
    mov eax, 3
    syscall
    test rax, rax
    jns .Lp_probe_remove_clear
    mov rbp, -1
.Lp_probe_remove_clear:
    mov qword ptr [rip + program_probe_fd], -1
    mov qword ptr [rip + program_probe_active], 0
.Lp_probe_remove_done:
    mov rax, rbp
    pop rbp
    pop rbx
    ret

/* RDI=normalized stat; EAX=1 for protected single-link user regular files.
 * No stack. File execute permission is checked separately for destinations. */
program_regular_stat:
    mov r8d, dword ptr [rdi + PROGRAM_STAT_MODE]
    mov r9d, r8d
    and r9d, 61440
    cmp r9d, 32768
    jne .Lp_regular_bad
    mov r9d, 3090
    test r8d, r9d
    jne .Lp_regular_bad
    mov r9, qword ptr [rdi + PROGRAM_STAT_LINKS]
    cmp r9, 1
    jne .Lp_regular_bad
    mov r9d, dword ptr [rdi + PROGRAM_STAT_UID]
    mov rdx, qword ptr [rip + program_uid]
    cmp r9d, edx
    jne .Lp_regular_bad
    mov eax, 1
    ret
.Lp_regular_bad:
    mov eax, 0
    ret

/* Opens current executable by held parent FD. Copies it to the private registry
 * payload for hashing through the mature fixed-argv adapter, then removes the
 * snapshot. Keeps current_fd and original stat for backup/recheck. Requires
 * size/hash match; never executes the program. Stack: four saved registers. */
program_check_existing:
    push rbx
    push rbp
    push r12
    push r13
    mov rbx, qword ptr [rip + program_found]
    mov rdi, qword ptr [rbx + 16]
    lea rsi, [rip + registry_host]
    call streq
    test eax, eax
    jz program_changed_file
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    mov rdx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    mov r10, 0
    mov eax, 257
    syscall
    test rax, rax
    js program_changed_file
    mov r12, rax
    mov qword ptr [rip + program_current_fd], rax
    mov rdi, r12
    lea rsi, [rip + program_current_stat]
    mov eax, 5
    syscall
    test rax, rax
    js program_changed_file
    lea rdi, [rip + program_current_stat]
    call program_regular_stat
    test eax, eax
    jz program_changed_file
    lea r11, [rip + program_current_stat]
    mov r8d, dword ptr [r11 + PROGRAM_STAT_MODE]
    test r8d, 64
    je program_changed_file
    mov qword ptr [rip + program_current_mode], r8
    mov rdi, qword ptr [rbx + 32]
    call registry_size_value
    lea r11, [rip + program_current_stat]
    mov r8, qword ptr [r11 + PROGRAM_STAT_SIZE]
    cmp r8, rax
    jne program_changed_file
    call registry_workspace
    lea rdi, [rip + registry_temp_payload]
    mov rsi, O_NOFOLLOW + O_CLOEXEC + 193
    mov rdx, 384
    mov eax, 2
    syscall
    test rax, rax
    js program_io_error
    mov r13, rax
    mov rdi, r12
    mov rsi, r13
    call program_copy_fds
    mov rbp, rax
    mov rdi, r13
    mov eax, 3
    syscall
    test rbp, rbp
    jnz program_io_error
    call pub_hash_payload
    test eax, eax
    jnz program_changed_file
    lea rdi, [rip + pub_hash_buffer]
    mov rsi, qword ptr [rbx + 24]
    mov rdx, 64
.Lp_existing_digest:
    movzx r8d, byte ptr [rdi]
    lea rdi, [rdi + 1]
    movzx r9d, byte ptr [rsi]
    lea rsi, [rsi + 1]
    cmp r8d, r9d
    jne program_changed_file
    sub rdx, 1
    jne .Lp_existing_digest
    lea rdi, [rip + registry_temp_payload]
    mov eax, 87
    syscall
    test rax, rax
    js program_io_error
    call program_check_existing_claims
    call program_recheck_destination
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Refuse mutation when another valid inventory row names the held file.
 * Input: trusted program_current_stat and program_found; <=128 parsed rows.
 * Walk each other parent and perform raw nofollow identity lookup. No file is
 * created or changed. Missing paths cannot claim this existing inode; other
 * lookup failures fail closed. A matching device/inode is ambiguous state.
 * Owns each temporary parent FD until its immediate close. Scratch stat is
 * program_alias_record_stat. Stack: four saved registers. Listing never calls
 * this routine and continues to report recorded metadata without filesystem IO.
 */
program_check_existing_claims:
    push rbx
    push rbp
    push r12
    push r13
    lea rbx, [rip + program_rows]
    mov rbp, qword ptr [rip + program_count]
.Lp_existing_claim_loop:
    test rbp, rbp
    jz .Lp_existing_claim_done
    mov r8, qword ptr [rip + program_found]
    cmp rbx, r8
    je .Lp_existing_claim_next
    mov rdi, qword ptr [rbx + 40]
    mov rsi, 0
    call program_walk_parent
    cmp rax, -2
    je .Lp_existing_claim_next
    test rax, rax
    js program_path_error
    mov r12, rax
    mov rdi, r12
    mov rsi, qword ptr [rip + program_basename]
    lea rdx, [rip + program_alias_record_stat]
    mov r10, 256
    mov eax, 262
    syscall
    mov r13, rax
    mov rdi, r12
    mov eax, 3
    syscall
    cmp r13, -2
    je .Lp_existing_claim_next
    test r13, r13
    js program_state_error
    lea rdi, [rip + program_current_stat]
    lea rsi, [rip + program_alias_record_stat]
    call program_same_identity
    test eax, eax
    jnz program_state_error
.Lp_existing_claim_next:
    lea rbx, [rbx + 64]
    sub rbp, 1
    jmp .Lp_existing_claim_loop
.Lp_existing_claim_done:
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Require unchanged destination identity/mode/size immediately before mutation.
 * Descriptor-relative nofollow stat. Stack: no local reservation. */
program_recheck_destination:
    mov rdi, qword ptr [rip + program_dest_fd]
    mov rsi, qword ptr [rip + program_dest_name]
    lea rdx, [rip + program_check_stat]
    mov r10, 256
    mov eax, 262
    syscall
    test rax, rax
    js program_changed_file
    lea rdi, [rip + program_check_stat]
    call program_regular_stat
    test eax, eax
    jz program_changed_file
    lea rdi, [rip + program_current_stat]
    lea rsi, [rip + program_check_stat]
    mov r8, qword ptr [rdi + PROGRAM_STAT_DEVICE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_DEVICE]
    cmp r8, r9
    jne program_changed_file
    mov r8, qword ptr [rdi + PROGRAM_STAT_INODE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_INODE]
    cmp r8, r9
    jne program_changed_file
    mov r8, qword ptr [rdi + PROGRAM_STAT_SIZE]
    mov r9, qword ptr [rsi + PROGRAM_STAT_SIZE]
    cmp r8, r9
    jne program_changed_file
    mov r8d, dword ptr [rdi + PROGRAM_STAT_MODE]
    mov r9d, dword ptr [rsi + PROGRAM_STAT_MODE]
    cmp r8d, r9d
    jne program_changed_file
    ret

/* RDI=input FD, RSI=output FD; RAX=0/-1. Copies <=64MiB and retries EINTR and
 * short writes with write_all. Caller owns both FDs. Stack: four saves. */
program_copy_fds:
    push rbx
    push rbp
    push r12
    push r13
    mov rbx, rdi
    mov rbp, rsi
    mov r12, 0
.Lp_copy_read:
    mov rdi, rbx
    lea rsi, [rip + registry_copy_buffer]
    mov rdx, 65536
    mov eax, 0
    syscall
    cmp rax, -4
    je .Lp_copy_read
    test rax, rax
    js .Lp_copy_bad
    test rax, rax
    jz .Lp_copy_ok
    lea r12, [r12 + rax]
    mov r8, 67108864
    cmp r12, r8
    ja .Lp_copy_bad
    mov rdx, rax
    mov rdi, rbp
    lea rsi, [rip + registry_copy_buffer]
    call write_all
    test rax, rax
    js .Lp_copy_bad
    jmp .Lp_copy_read
.Lp_copy_bad:
    mov rax, -1
    jmp .Lp_copy_done
.Lp_copy_ok:
    mov rax, 0
.Lp_copy_done:
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

/* Exclusive stage lives in the destination's filesystem. Its predictable PID
 * name is safe because mkdirat must create it. Never reuses an existing path.
 * Stack: none beyond nested link frames. */
program_make_stage:
    lea rdi, [rip + program_stage_name]
    lea rsi, [rip + program_stage_prefix]
    call copy_string
    mov qword ptr [rip + program_append], rax
    mov eax, 39
    syscall
    mov rdi, rax
    lea rsi, [rip + program_number + 31]
    call unsigned_decimal
    mov rsi, rax
    mov rdi, qword ptr [rip + program_append]
    call copy_string
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rsi, [rip + program_stage_name]
    mov rdx, 448
    mov eax, 258
    syscall
    test rax, rax
    jnz program_io_error
    mov qword ptr [rip + program_stage_created], 1
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rsi, [rip + program_stage_name]
    mov rdx, O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov r10, 0
    mov eax, 257
    syscall
    test rax, rax
    js program_io_error
    mov qword ptr [rip + program_stage_fd], rax
    ret

/* RDI=stage directory FD, RSI=fixed file name, RDX=mode, R12=source FD.
 * RAX=0/-1; copies, chmods and fsyncs an exclusive file. Stack: three saves.
 * Backup mode is retained, but rollback may create a different inode. */
program_copy_into_stage:
    push rbx
    push rbp
    push r13
    mov rbp, rdx
    mov rdx, O_NOFOLLOW + O_CLOEXEC + 193
    mov r10, 384
    mov eax, 257
    syscall
    test rax, rax
    js .Lp_stage_copy_bad
    mov rbx, rax
    mov rdi, r12
    mov rsi, rbx
    call program_copy_fds
    test rax, rax
    jnz .Lp_stage_copy_close_bad
    mov rdi, rbx
    mov rsi, rbp
    mov eax, 91
    syscall
    test rax, rax
    js .Lp_stage_copy_close_bad
    mov rdi, rbx
    mov eax, 74
    syscall
    test rax, rax
    js .Lp_stage_copy_close_bad
    mov rdi, rbx
    mov eax, 3
    syscall
    test rax, rax
    js .Lp_stage_copy_bad
    mov rax, 0
    jmp .Lp_stage_copy_done
.Lp_stage_copy_close_bad:
    mov rdi, rbx
    mov eax, 3
    syscall
.Lp_stage_copy_bad:
    mov rax, -1
.Lp_stage_copy_done:
    pop r13
    pop rbp
    pop rbx
    ret

/* Serialize a complete replacement inventory to an exclusive temporary file
 * under the locked state FD. Removal skips found; upgrade replaces found;
 * install appends new_row. File fsync precedes any executable mutation.
 * Stack: four saved registers. Total output remains <=1 MiB. */
program_write_state:
    push rbx
    push rbp
    push r12
    push r13
    lea rdi, [rip + program_state_temp]
    lea rsi, [rip + program_state_prefix]
    call copy_string
    mov qword ptr [rip + program_append], rax
    mov eax, 39
    syscall
    mov rdi, rax
    lea rsi, [rip + program_number + 31]
    call unsigned_decimal
    mov rsi, rax
    mov rdi, qword ptr [rip + program_append]
    call copy_string
    mov rdi, qword ptr [rip + program_state_fd]
    lea rsi, [rip + program_state_temp]
    mov rdx, O_NOFOLLOW + O_CLOEXEC + 193
    mov r10, 384
    mov eax, 257
    syscall
    test rax, rax
    js program_io_error
    mov rbx, rax
    mov qword ptr [rip + program_temp_fd], rax
    mov qword ptr [rip + program_state_created], 1
    mov qword ptr [rip + program_written], 0
    lea rsi, [rip + program_header]
    call program_write_piece
    lea rbp, [rip + program_rows]
    mov r12, qword ptr [rip + program_count]
.Lp_write_row:
    test r12, r12
    jz .Lp_write_append
    mov r8, qword ptr [rip + program_found]
    cmp rbp, r8
    jne .Lp_write_old
    mov r8, qword ptr [rip + program_remove]
    test r8, r8
    jnz .Lp_write_next
    lea rdi, [rip + program_new_row]
    jmp .Lp_write_emit
.Lp_write_old:
    mov rdi, rbp
.Lp_write_emit:
    call program_write_row
.Lp_write_next:
    lea rbp, [rbp + 64]
    sub r12, 1
    jmp .Lp_write_row
.Lp_write_append:
    mov r8, qword ptr [rip + program_found]
    test r8, r8
    jnz .Lp_write_sync
    lea rdi, [rip + program_new_row]
    call program_write_row
.Lp_write_sync:
    mov rdi, rbx
    mov eax, 74
    syscall
    test rax, rax
    js program_io_error
    mov rdi, rbx
    mov eax, 3
    syscall
    mov qword ptr [rip + program_temp_fd], -1
    test rax, rax
    js program_io_error
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
/* RDI=seven-pointer row; RBX=output FD. Stack: two saves. */
program_write_row:
    push rbp
    push r12
    mov rbp, rdi
    mov r12, 0
.Lp_write_field:
    mov rsi, qword ptr [rbp + r12*8]
    call program_write_piece
    lea r12, [r12 + 1]
    cmp r12, 7
    je .Lp_write_row_end
    lea rsi, [rip + registry_tab]
    call program_write_piece
    jmp .Lp_write_field
.Lp_write_row_end:
    lea rsi, [rip + registry_newline]
    call program_write_piece
    pop r12
    pop rbp
    ret
/* RSI=NUL text, RBX=FD. Bounds cumulative bytes; stack: one save. */
program_write_piece:
    push rbp
    mov rbp, rsi
    mov rdi, rsi
    call strlen
    mov r8, qword ptr [rip + program_written]
    lea r8, [r8 + rax]
    mov r9, PROGRAM_STATE_LIMIT
    cmp r8, r9
    ja program_state_error
    mov qword ptr [rip + program_written], r8
    mov rdi, rbx
    mov rsi, rbp
    call write_cstr
    test rax, rax
    js program_io_error
    pop rbp
    ret
/* Final inventory replacement. RAX=rename result; no fatal branch, so callers
 * can roll back their executable mutation before reporting any error. */
program_commit_state:
    mov rdi, qword ptr [rip + program_state_fd]
    lea rsi, [rip + program_state_temp]
    mov rdx, rdi
    lea r10, [rip + program_state_name]
    mov eax, 264
    syscall
    test rax, rax
    js .Lp_state_commit_done
    mov qword ptr [rip + program_state_created], 0
.Lp_state_commit_done:
    ret

/* Stable native inventory output. Parse errors have already failed without
 * stdout. JSON encodes paths through the shared bounded encoder. Stack: 3 saves. */
program_list:
    push rbx
    push rbp
    push r12
    movzx r8d, byte ptr [rip + json_mode]
    test r8d, r8d
    jz .Lp_list_text
    lea rdi, [rip + program_list_prefix]
    call out
    lea rbx, [rip + program_rows]
    mov rbp, qword ptr [rip + program_count]
    mov r12, 0
.Lp_list_json_row:
    test rbp, rbp
    jz .Lp_list_json_done
    test r12, r12
    jz .Lp_list_json_first
    lea rdi, [rip + registry_comma]
    call out
.Lp_list_json_first:
    lea rdi, [rip + program_json_package]
    call out
    mov rdi, qword ptr [rbx]
    call registry_json_string
    lea rdi, [rip + program_json_version]
    call out
    mov rdi, qword ptr [rbx + 8]
    call registry_json_string
    lea rdi, [rip + program_json_target]
    call out
    mov rdi, qword ptr [rbx + 16]
    call registry_json_string
    lea rdi, [rip + program_json_sha]
    call out
    mov rdi, qword ptr [rbx + 24]
    call registry_json_string
    lea rdi, [rip + program_json_bytes]
    call out
    mov rdi, qword ptr [rbx + 32]
    call out
    lea rdi, [rip + program_json_path]
    call out
    mov rdi, qword ptr [rbx + 40]
    call registry_json_string
    lea rdi, [rip + program_json_registry]
    call out
    mov rdi, qword ptr [rbx + 48]
    call registry_json_string
    lea rdi, [rip + registry_rbrace]
    call out
    lea rbx, [rbx + 64]
    sub rbp, 1
    mov r12, 1
    jmp .Lp_list_json_row
.Lp_list_json_done:
    lea rdi, [rip + program_list_suffix]
    call out
    jmp .Lp_list_done
.Lp_list_text:
    mov rbp, qword ptr [rip + program_count]
    test rbp, rbp
    jnz .Lp_list_text_rows
    lea rdi, [rip + program_empty_text]
    call out
    jmp .Lp_list_done
.Lp_list_text_rows:
    lea rbx, [rip + program_rows]
.Lp_list_text_row:
    mov rdi, qword ptr [rbx]
    call out
    lea rdi, [rip + program_at]
    call out
    mov rdi, qword ptr [rbx + 8]
    call out
    lea rdi, [rip + registry_tab]
    call out
    mov rdi, qword ptr [rbx + 16]
    call out
    lea rdi, [rip + registry_tab]
    call out
    mov rdi, qword ptr [rbx + 40]
    call out
    lea rdi, [rip + registry_newline]
    call out
    lea rbx, [rbx + 64]
    sub rbp, 1
    jne .Lp_list_text_row
.Lp_list_done:
    call registry_cleanup
    jmp exit_ok

/* Cleanup closes only owned descriptors and removes only invocation-owned
 * stage names. A failed rollback retains its backup directory for recovery.
 * Cleanup failure cannot replace an earlier error. Stack: one saved register. */
program_cleanup:
    push rbx
    call program_remove_probe
    mov rdi, qword ptr [rip + program_temp_fd]
    test rdi, rdi
    js .Lp_cleanup_temp_name
    mov eax, 3
    syscall
    mov qword ptr [rip + program_temp_fd], -1
.Lp_cleanup_temp_name:
    mov r8, qword ptr [rip + program_state_created]
    test r8, r8
    jz .Lp_cleanup_stage
    mov rdi, qword ptr [rip + program_state_fd]
    lea rsi, [rip + program_state_temp]
    mov rdx, 0
    mov eax, 263
    syscall
    mov qword ptr [rip + program_state_created], 0
.Lp_cleanup_stage:
    mov r8, qword ptr [rip + program_keep_stage]
    test r8, r8
    jnz .Lp_cleanup_close
    mov rdi, qword ptr [rip + program_stage_fd]
    test rdi, rdi
    js .Lp_cleanup_stage_dir
    lea rsi, [rip + program_candidate]
    mov rdx, 0
    mov eax, 263
    syscall
    mov rdi, qword ptr [rip + program_stage_fd]
    lea rsi, [rip + program_previous]
    mov rdx, 0
    mov eax, 263
    syscall
.Lp_cleanup_stage_dir:
    mov r8, qword ptr [rip + program_stage_created]
    test r8, r8
    jz .Lp_cleanup_close
    mov rdi, qword ptr [rip + program_dest_fd]
    lea rsi, [rip + program_stage_name]
    mov rdx, 512
    mov eax, 263
    syscall
    mov qword ptr [rip + program_stage_created], 0
.Lp_cleanup_close:
    lea rbx, [rip + program_fds]
    mov r8, 4
    mov qword ptr [rip + program_cleanup_count], r8
.Lp_cleanup_fd:
    mov rdi, qword ptr [rbx]
    test rdi, rdi
    js .Lp_cleanup_fd_next
    mov eax, 3
    syscall
    mov r8, -1
    mov qword ptr [rbx], r8
.Lp_cleanup_fd_next:
    lea rbx, [rbx + 8]
    mov r8, qword ptr [rip + program_cleanup_count]
    sub r8, 1
    mov qword ptr [rip + program_cleanup_count], r8
    jne .Lp_cleanup_fd
    pop rbx
    ret

program_help:
    lea rdi, [rip + program_help_text]
    call out
    jmp exit_ok
program_bad_args:
    lea rdi, [rip + program_error_args]
    mov rsi, 2
    jmp registry_fail
program_path_error:
    lea rdi, [rip + program_error_path]
    jmp program_error
program_state_error:
    lea rdi, [rip + program_error_state]
    jmp program_error
program_busy_error:
    lea rdi, [rip + program_error_busy]
    jmp program_error
program_not_managed:
    lea rdi, [rip + program_error_unmanaged]
    jmp program_error
program_already_managed:
    lea rdi, [rip + program_error_already]
    jmp program_error
program_local_index_error:
    lea rdi, [rip + program_error_local]
    jmp program_error
program_origin_error:
    lea rdi, [rip + program_error_origin]
    jmp program_error
program_downgrade_error:
    lea rdi, [rip + program_error_downgrade]
    jmp program_error
program_changed_release:
    lea rdi, [rip + program_error_release]
    jmp program_error
program_changed_file:
    lea rdi, [rip + program_error_changed]
    jmp program_error
program_destination_exists:
    lea rdi, [rip + program_error_exists]
    jmp program_error
program_reserved_error:
    lea rdi, [rip + program_error_reserved]
    jmp program_error
program_internal_error:
    lea rdi, [rip + program_error_internal]
    jmp program_error
program_recovery_error:
    mov qword ptr [rip + program_keep_stage], 1
    lea rdi, [rip + program_error_recovery]
    jmp program_error
program_probe_error:
    lea rdi, [rip + program_error_probe]
    jmp program_error
program_io_error:
    lea rdi, [rip + program_error_io]
program_error:
    mov rsi, 1
    jmp registry_fail

.section .rodata
program_header: .asciz "# asm-installed-v1\n"
program_state_suffix: .asciz "/.local/state/asm/installed.tsv"
program_state_name: .asciz "installed.tsv"
program_state_prefix: .asciz ".installed-"
program_stage_prefix: .asciz ".asm-program-"
program_reserved_suffix: .asciz "/.local/bin/asm"
program_candidate: .asciz "candidate"
program_cli_name: .asciz "asm"
program_previous: .asciz "previous"
program_local: .asciz "local"
program_root: .asciz "/"
program_tmp: .asciz "/tmp"
program_private_tmp: .asciz "/private/tmp"
program_at: .asciz "@"
program_ok_json: .asciz "{\"ok\":true}\n"
program_unchanged_json: .asciz "{\"ok\":true,\"unchanged\":true}\n"
program_list_prefix: .asciz "{\"installed\":["
program_list_suffix: .asciz "]}\n"
program_json_package: .asciz "{\"package\":"
program_json_version: .asciz ",\"version\":"
program_json_target: .asciz ",\"target\":"
program_json_sha: .asciz ",\"sha256\":"
program_json_bytes: .asciz ",\"bytes\":"
program_json_path: .asciz ",\"path\":"
program_json_registry: .asciz ",\"registry\":"
program_empty_text: .asciz "No installed programs.\n"
program_help_text: .asciz "Usage:\n  asm installed [--json]\n  asm upgrade owner/name[@version] [--index PATH | --registry HTTPS_URL] [--artifact PATH] [--json]\n  asm uninstall owner/name [--json]\nupdate and remove manage project source dependencies.\n"
program_error_args: .asciz "invalid installed-program arguments; use asm installed --help"
program_error_path: .asciz "program management requires protected user-owned paths; check HOME, directory ownership, permissions, and symlinks"
program_error_state: .asciz "installed.tsv is invalid or exceeds its limit; restore the inventory before changing programs"
program_error_busy: .asciz "another command holds the installed-program lock; wait for it to finish and try again"
program_error_unmanaged: .asciz "this package has no installation record; use asm install for a new destination"
program_error_already: .asciz "this package is already managed; use asm upgrade to change its installed version"
program_error_local: .asciz "this installation has a local index origin; supply its --index PATH to upgrade"
program_error_origin: .asciz "the registry differs from the installation record; use the recorded registry origin"
program_error_downgrade: .asciz "upgrade refuses an older version; select the installed version or a newer version"
program_error_release: .asciz "the installed version has different release bytes; restore the original registry record"
program_error_changed: .asciz "the installed file is missing or changed; restore its recorded bytes and protected permissions before continuing"
program_error_exists: .asciz "the destination exists or cannot be replaced; choose a new destination and check its directory permissions"
program_error_internal: .asciz "the destination is inside Asm installation state or its temporary workspace; choose another program destination"
program_error_reserved: .asciz "HOME/.local/bin/asm is reserved for the CLI updater; use asm self update"
program_error_recovery: .asciz "program rollback failed; preserve the .asm-program-PID directory beside the destination and its previous file for recovery"
program_error_probe: .asciz "the program name check failed; inspect the new destination for an empty nonexecutable file before retrying"
program_error_io: .asciz "program management could not finish; check free space, directory permissions, and retained .asm-program-PID stages"

.section .data
.balign 8
program_fds:
program_state_fd: .quad -1
program_dest_fd: .quad -1
program_stage_fd: .quad -1
program_current_fd: .quad -1
program_temp_fd: .quad -1
program_probe_fd: .quad -1
.section .bss
.balign 8
program_upgrade: .skip 8
program_remove: .skip 8
program_arg: .skip 8
program_query: .skip 8
program_found: .skip 8
program_count: .skip 8
program_uid: .skip 8
program_home: .skip 8
program_home_length: .skip 8
program_basename: .skip 8
program_dest_name: .skip 8
program_input_size: .skip 8
program_current_mode: .skip 8
program_append: .skip 8
program_written: .skip 8
program_mutated: .skip 8
program_keep_stage: .skip 8
program_stage_created: .skip 8
program_state_created: .skip 8
program_cleanup_count: .skip 8
program_internal_stat_result: .skip 8
program_probe_active: .skip 8
program_alias_count: .skip 8
program_number: .skip 32
program_state_temp: .skip 64
program_stage_name: .skip 64
program_new_row: .skip 64
program_walk_stat: .skip PROGRAM_STAT_BYTES
program_check_stat: .skip PROGRAM_STAT_BYTES
program_current_stat: .skip PROGRAM_STAT_BYTES
program_probe_stat: .skip PROGRAM_STAT_BYTES
program_probe_entry_stat: .skip PROGRAM_STAT_BYTES
program_alias_parent_stat: .skip PROGRAM_STAT_BYTES
program_alias_record_stat: .skip PROGRAM_STAT_BYTES
program_alias_names: .skip (PROGRAM_LIMIT + 1) * 8
program_state_path: .skip 4096
program_reserved_path: .skip 4096
program_path: .skip 4096
program_cwd: .skip 4096
program_rows: .skip PROGRAM_LIMIT * 64
program_input: .skip PROGRAM_STATE_LIMIT + 1
.section .note.GNU-stack,"",@progbits
