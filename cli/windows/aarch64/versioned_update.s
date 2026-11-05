/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Managed update changes only current.tsv. Shared release/provenance gates
 * remain unchanged. No candidate process is created; old payloads remain.
 */
.text
win_managed_open_installation:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    WM_LOAD x10,wm_role
    cmp x10,#2
    b.ne win_managed_fail
    mov x10,#1
    WM_STORE x10,wm_updating
    ARM_CALL win_managed_paths
    ARM_CALL win_managed_open_state
    ARM_ADDR x0,wm_image_path
    ARM_ADDR x1,wm_payload_path
    ARM_CALL win_managed_path_equal
    cbz x9,win_managed_fail
    /* The current selected held file, not a path or parent claim, must be
     * the creation image of this executing payload before update begins. */
    WM_LOAD x0,self_current_fd
    ARM_CALL win_image_matches
    cbnz x9,win_managed_fail
    ARM_CALL win_managed_check_absolute_installation
    WM_LOAD x0,self_parent_fd
    ARM_CALL arm_fchdir
    cbnz x9,win_managed_fail
    mov w10,#493
    WM_STORE w10,self_file_mode
    ldp x29,x30,[sp],#16
    ret
/* x0=parent,x1=leaf,x2=retained stat,x3=directory flag. Recheck private
 * metadata and full identity; scratch check_stat128; stack48, no owned fd. */
win_managed_entry:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    mov x19,x2
    mov x20,x3
    ARM_ADDR x2,wm_check_stat
    mov x6,#256
    ARM_CALL arm_newfstatat
    cbnz x9,1f
    ARM_ADDR x0,wm_check_stat
    mov x1,x20
    ARM_CALL win_managed_stat
    cbnz x9,1f
    ARM_ADDR x0,wm_check_stat
    mov x1,x19
    ARM_CALL win_managed_same
    cbnz x9,1f
    cbnz x20,2f
    ARM_ADDR x16,wm_check_stat
    ldr x10,[x16,#ARM_STAT_SIZE]
    ldr x11,[x19,#ARM_STAT_SIZE]
    cmp x10,x11
    b.eq 2f
1:  mov x9,#-22
2:  ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret
win_managed_check_absolute_installation:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    ARM_CALL self_open_parent
    tbnz x9,#63,win_managed_fail
    mov x19,x9
    mov x0,x19
    ARM_ADDR x1,wm_check_stat
    ARM_CALL arm_fstat
    str x9,[sp,#24]
    mov x0,x19
    ARM_CALL arm_close
    ldr x9,[sp,#24]
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_check_stat
    ARM_ADDR x1,wm_bin_stat
    ARM_CALL win_managed_same
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_bin_fd
    ARM_ADDR x1,wm_store_name
    ARM_ADDR x2,self_parent_stat
    mov x3,#1
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,self_parent_fd
    ARM_ADDR x1,wm_versions_name
    ARM_ADDR x2,wm_versions_stat
    mov x3,#1
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,self_parent_fd
    ARM_ADDR x1,wm_layout_name
    ARM_ADDR x2,wm_marker_stat
    mov x3,#0
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_bin_fd
    ARM_ADDR x1,self_binary_name
    ARM_ADDR x2,wm_root_stat
    mov x3,#0
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    ARM_CALL win_managed_check_destination
    ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    ret
win_managed_check_destination:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    WM_LOAD x0,self_parent_fd
    ARM_ADDR x1,wm_current_name
    ARM_ADDR x2,wm_record_stat
    mov x3,#0
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_versions_fd
    ARM_ADDR x16,wm_fields
    ldr x1,[x16,#24]
    ARM_ADDR x2,wm_digest_stat
    mov x3,#1
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_digest_fd
    ARM_ADDR x1,self_binary_name
    ARM_ADDR x2,self_current_stat
    mov x3,#0
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    ldp x29,x30,[sp],#16
    ret
/* x0=held source with DELETE, x1=held destination directory, x2=leafUTF8,
 * x3=1 no-replace/0 replace. x9=0/negative. Leaf<=255 UTF16; bounded native
 * rename buffer, no source reopen, one FileRenameInformationEx call.
 * Never closes borrowed handles; stack80 and volatile API registers. */
win_managed_rename_fd:
    stp x29,x30,[sp,#-80]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov x19,x0
    mov x20,x1
    mov x21,x3
    mov x0,x2
    ARM_ADDR x1,wm_rename_w
    mov x2,#256
    ARM_CALL win_utf16
    tbnz x9,#63,.Lwmrf_bad
    sub x22,x9,#1
    ARM_ADDR x0,wm_rename_w
    lsl x1,x22,#1
    ARM_CALL win_leaf_name
    cbz x9,.Lwmrf_bad
    ARM_ADDR x2,wm_rename_info
    mov w10,#2
    cbnz x21,1f
    orr w10,w10,#1
1:  str w10,[x2]
    str x20,[x2,#8]
    lsl x22,x22,#1
    str w22,[x2,#16]
    ARM_ADDR x10,wm_rename_w
    add x11,x2,#20
    mov x12,#0
2:  cmp x12,x22
    b.hs 3f
    ldrb w13,[x10,x12]
    strb w13,[x11,x12]
    add x12,x12,#1
    b 2b
3:  mov x0,x19
    add x1,sp,#48
    add x3,x22,#20
    mov w4,#65
    bl NtSetInformationFile
    cbz w0,4f
    ARM_CALL win_nt_error
    b 5f
4:  mov x9,#0
    b 5f
.Lwmrf_bad:
    mov x9,#-22
5:  ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#80
    ret
/* Candidate is already downloaded and passes all shared signed bindings.
 * Validate held candidate again, protect/flush, no-replace publish, validate
 * exact published file, prepare/flush record, recheck identities, activate.
 * Owned contexts are cleanup slots. Failure before rename preserves selection.
 */
win_managed_commit_update:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    WM_LOAD x19,registry_selected
    WM_LOAD x0,self_stage_fd
    ARM_ADDR x1,self_payload_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + 2 + WIN_OPEN_HELD + WIN_OPEN_SET_DACL
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_candidate_fd
    mov x0,x9
    ARM_ADDR x1,wm_check_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_candidate_fd
    WM_LOAD x1,registry_expected_size
    ARM_ADDR x2,wm_hash
    ARM_CALL win_hash_fd
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_hash
    ldr x1,[x19,#32]
    ARM_CALL streq
    cbz x9,win_managed_fail
    WM_LOAD x0,wm_candidate_fd
    WM_LOAD x1,registry_expected_size
    ARM_ADDR x2,wm_candidate_meta
    ARM_CALL win_managed_pe
    cbnz x9,win_managed_fail
    ldr x0,[x19,#8]
    ARM_ADDR x1,wm_candidate_version
    ARM_CALL win_managed_version
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_candidate_meta + 24
    ARM_ADDR x1,wm_candidate_version
    ARM_CALL win_managed_triple_equal
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_root_meta
    ARM_ADDR x1,wm_candidate_meta
    ARM_CALL win_managed_compatible
    cbnz x9,win_managed_incompatible
    WM_LOAD x0,wm_candidate_fd
    mov w1,#493
    ARM_CALL arm_fchmod
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_candidate_fd
win_managed_payload_flush:
    ARM_CALL arm_fsync
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_versions_fd
    ldr x1,[x19,#32]
    mov x2,#448
    ARM_CALL arm_mkdirat
    mov x20,x9
    cbz x20,1f
    cmn x20,#17
    b.ne win_managed_fail
1:  WM_LOAD x0,wm_versions_fd
    ldr x1,[x19,#32]
    ARM_ADDR x2,wm_newdir_stat
    ARM_CALL win_managed_directory
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_newdir_fd
    cbnz x20,2f
    WM_LOAD x0,wm_candidate_fd
    WM_LOAD x1,wm_newdir_fd
    ARM_ADDR x2,self_binary_name
    mov x3,#1
    ARM_CALL win_managed_rename_fd
    cbnz x9,win_managed_fail
2:  WM_LOAD x0,wm_candidate_fd
    mov x10,#-1
    WM_STORE x10,wm_candidate_fd
    ARM_CALL arm_close
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_newdir_fd
    ARM_ADDR x1,self_binary_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_IMAGE + WIN_OPEN_HELD
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_candidate_fd
    mov x0,x9
    ARM_ADDR x1,wm_newpayload_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_candidate_fd
    WM_LOAD x1,registry_expected_size
    ARM_ADDR x2,wm_hash
    ARM_CALL win_hash_fd
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_hash
    ldr x1,[x19,#32]
    ARM_CALL streq
    cbz x9,win_managed_fail
    WM_LOAD x0,wm_candidate_fd
    WM_LOAD x1,registry_expected_size
    ARM_ADDR x2,wm_candidate_meta
    ARM_CALL win_managed_pe
    cbnz x9,win_managed_fail
    ARM_CALL win_managed_build_record
    WM_LOAD x0,self_stage_fd
    ARM_ADDR x1,wm_next_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + 64 + 128 + 2 + WIN_OPEN_HELD
    mov x6,#384
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_newrecord_fd
    ARM_ADDR x20,wm_next_record
    WM_LOAD x21,wm_next_length
3:  WM_LOAD x0,wm_newrecord_fd
    mov x1,x20
    mov x2,x21
win_managed_record_write:
    ARM_CALL arm_write
    cmp x9,#0
    b.le win_managed_fail
    cmp x9,x21
    b.hi win_managed_fail
    add x20,x20,x9
    subs x21,x21,x9
    b.ne 3b
    WM_LOAD x0,wm_newrecord_fd
win_managed_record_flush:
    ARM_CALL arm_fsync
    cbnz x9,win_managed_fail
    ARM_CALL win_managed_check_absolute_installation
    WM_LOAD x0,wm_versions_fd
    ldr x1,[x19,#32]
    ARM_ADDR x2,wm_newdir_stat
    mov x3,#1
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_newdir_fd
    ARM_ADDR x1,self_binary_name
    ARM_ADDR x2,wm_newpayload_stat
    mov x3,#0
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_newrecord_fd
    WM_LOAD x1,self_parent_fd
    ARM_ADDR x2,wm_current_name
    mov x3,#0
/* Test-only failure injection targets this exact final activation operation.
 * x0=flushed held record; x1=store dir; x2=current.tsv; x3=replace0. */
win_managed_activation_rename:
    ARM_CALL win_managed_rename_fd
    cbnz x9,win_managed_fail
    /* Commit complete. Only cleanup follows; cleanup cannot report failure. */
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret
/* Serialize <=256 bytes using already canonical release fields and parsed
 * metadata minimum. x19=selected row. Stack64, scratch decimal32. */
win_managed_build_record:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    WM_LOAD x19,registry_selected
    ARM_ADDR x0,wm_next_record
    ARM_ADDR x1,wm_record_header
    ARM_CALL copy_string
    mov x0,x9
    ldr x1,[x19,#8]
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_tab_host
    ARM_CALL copy_string
    mov x0,x9
    ldr x1,[x19,#48]
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_tab
    ARM_CALL copy_string
    mov x0,x9
    ldr x1,[x19,#32]
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_protocol
    ARM_CALL copy_string
    mov x20,x9
    ARM_ADDR x21,wm_candidate_meta + 36
    mov x22,#0
1:  ldr w0,[x21,x22,lsl #2]
    ARM_ADDR x1,wm_decimal + 31
    ARM_CALL unsigned_decimal
    mov x1,x9
    mov x0,x20
    ARM_CALL copy_string
    mov x20,x9
    add x22,x22,#1
    cmp x22,#3
    b.eq 2f
    mov w10,#46
    strb w10,[x20],#1
    b 1b
2:  mov w10,#10
    strb w10,[x20],#1
    strb wzr,[x20]
    ARM_ADDR x10,wm_next_record
    sub x20,x20,x10
    cmp x20,#256
    b.hi win_managed_fail
    WM_STORE x20,wm_next_length
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret
win_managed_incompatible:
    ARM_ADDR x0,wm_compat_error
    mov w1,#1
    b self_fail
.section .rdata,"dr"
wm_compat_error: .asciz "the candidate requires a newer launcher; run the bootstrap installer with -RepairLauncher after Asm processes exit"
wm_next_name: .asciz "current.next"
wm_tab_host: .asciz "\taarch64-windows\t"
wm_tab: .asciz "\t"
wm_protocol: .asciz "\t1\t"
.section .bss
.p2align 3
wm_newdir_stat: .skip 128
wm_newpayload_stat: .skip 128
wm_candidate_version: .skip 12
wm_next_record: .skip 257
wm_decimal: .skip 32
.p2align 3
wm_next_length: .skip 8
wm_rename_info: .skip 544
wm_rename_w: .skip 512
