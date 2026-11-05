/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native Windows versioned installation. See the frozen layout contract.
 * No candidate code runs during installation or update.
 */
.text
/* x0=owned record[257], x1=exact length. x9=0/-22; replaces field separators
 * with NUL only after bounded framing. Fields are borrowed until next parse.
 * Preserves x19-x24; stack64. Strict ASCII; one canonical six-field row.
 */
win_managed_parse_record:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    mov x19,x0
    mov x20,x1
    cmp x20,#256
    b.hi .Lwmpr_bad
    cmp x20,#21
    b.lo .Lwmpr_bad
    ARM_ADDR x21,wm_record_header
    mov x22,#0
1:  ldrb w10,[x21,x22]
    cbz w10,2f
    cmp x22,x20
    b.hs .Lwmpr_bad
    ldrb w11,[x19,x22]
    cmp w10,w11
    b.ne .Lwmpr_bad
    add x22,x22,#1
    b 1b
2:  ARM_ADDR x21,wm_fields
    add x10,x19,x22
    str x10,[x21]
    mov x23,#0
    mov x24,x22
3:  cmp x22,x20
    b.hs .Lwmpr_bad
    ldrb w10,[x19,x22]
    cbz w10,.Lwmpr_bad
    cmp w10,#13
    b.eq .Lwmpr_bad
    cmp w10,#127
    b.hs .Lwmpr_bad
    cmp w10,#9
    b.eq 4f
    cmp w10,#10
    b.eq 5f
    add x22,x22,#1
    b 3b
4:  cmp x22,x24
    b.eq .Lwmpr_bad
    cmp x23,#5
    b.hs .Lwmpr_bad
    strb wzr,[x19,x22]
    add x22,x22,#1
    mov x24,x22
    add x23,x23,#1
    add x10,x19,x22
    str x10,[x21,x23,lsl #3]
    b 3b
5:  cmp x23,#5
    b.ne .Lwmpr_bad
    cmp x22,x24
    b.eq .Lwmpr_bad
    add x10,x22,#1
    cmp x10,x20
    b.ne .Lwmpr_bad
    strb wzr,[x19,x22]
    ldr x0,[x21]
    ARM_ADDR x1,wm_record_version
    ARM_CALL win_managed_version
    cbnz x9,.Lwmpr_bad
    ldr x0,[x21,#8]
    ARM_ADDR x1,wm_host
    ARM_CALL win_managed_equal
    cbz x9,.Lwmpr_bad
    ldr x0,[x21,#16]
    ARM_IMM x1,67108864
    ARM_CALL win_managed_decimal
    tbnz x9,#63,.Lwmpr_bad
    cbz x9,.Lwmpr_bad
    ARM_ADDR x16,wm_record_size
    str x9,[x16]
    ldr x0,[x21,#24]
    ARM_CALL win_managed_digest
    cbnz x9,.Lwmpr_bad
    ldr x0,[x21,#32]
    ldrh w10,[x0]
    cmp w10,#49
    b.ne .Lwmpr_bad
    ldr x0,[x21,#40]
    ARM_ADDR x1,wm_record_min
    ARM_CALL win_managed_version
    cbnz x9,.Lwmpr_bad
    mov x9,#0
    b .Lwmpr_done
.Lwmpr_bad:
    mov x9,#-22
.Lwmpr_done:
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret
/* x0/x1=NUL strings. x9=1 exactly equal, 0 otherwise; volatile only. */
win_managed_equal:
1:  ldrb w10,[x0],#1
    ldrb w11,[x1],#1
    cmp w10,w11
    b.ne 2f
    cbnz w10,1b
    mov x9,#1
    ret
2:  mov x9,#0
    ret
/* x0=canonical decimal NUL string, x1=max. x9=value/-22.
 * Bound before multiply: max <=2147483647, at most10 digits. */
win_managed_decimal:
    mov x9,#0
    mov x12,#0
    ldrb w10,[x0]
    cmp w10,#48
    b.ne 1f
    ldrb w10,[x0,#1]
    cbnz w10,4f
    ret
1:  ldrb w10,[x0],#1
    cbz w10,3f
    sub w10,w10,#48
    cmp w10,#9
    b.hi 4f
    add x12,x12,#1
    cmp x12,#10
    b.hi 4f
    mov x11,#10
    madd x9,x9,x11,x10
    cmp x9,x1
    b.hi 4f
    b 1b
3:  cbz x12,4f
    ret
4:  mov x9,#-22
    ret
/* x0=version, x1=owned3u32. x9=0/-22. Max32 bytes, no leading zeros,
 * exactly3 decimal components, each <=2147483647. Volatile only. */
win_managed_version:
    mov x2,#0
    mov x3,#0
    mov x4,#0
    mov x5,#0
    mov x6,#0
1:  ldrb w10,[x0],#1
    cbz w10,5f
    add x2,x2,#1
    cmp x2,#32
    b.hi 8f
    cmp w10,#46
    b.eq 4f
    sub w10,w10,#48
    cmp w10,#9
    b.hi 8f
    cbz x4,2f
    cbnz x6,8f
2:  cbnz x4,3f
    cmp w10,#0
    cset x6,eq
3:  add x4,x4,#1
    cmp x4,#10
    b.hi 8f
    mov x11,#10
    madd x5,x5,x11,x10
    ARM_IMM x11,2147483647
    cmp x5,x11
    b.hi 8f
    b 1b
4:  cmp x3,#2
    b.hs 8f
    cbz x4,8f
    str w5,[x1,x3,lsl #2]
    add x3,x3,#1
    mov x4,#0
    mov x5,#0
    mov x6,#0
    b 1b
5:  cmp x3,#2
    b.ne 8f
    cbz x4,8f
    str w5,[x1,#8]
    mov x9,#0
    ret
8:  mov x9,#-22
    ret
/* x0=digest NUL string. Exactly64 lowercase hex. x9=0/-22. */
win_managed_digest:
    mov x11,#0
1:  ldrb w10,[x0,x11]
    sub w12,w10,#48
    cmp w12,#9
    b.ls 2f
    sub w12,w10,#97
    cmp w12,#5
    b.hi 3f
2:  add x11,x11,#1
    cmp x11,#64
    b.lo 1b
    ldrb w10,[x0,#64]
    cbnz w10,3f
    mov x9,#0
    ret
3:  mov x9,#-22
    ret
/* x0=64 metadata bytes. x9=0/-22. All protocol fields are frozen at1.
 * Version components fit canonical shared versions; reserved bytes zero. */
win_managed_metadata:
    ldr x10,[x0]
    ARM_IMM x11,0x0031494c434d5341
    cmp x10,x11
    b.ne 4f
    mov x12,#8
1:  ldr w10,[x0,x12]
    cmp w10,#1
    b.ne 4f
    add x12,x12,#4
    cmp x12,#24
    b.lo 1b
2:  ldr w10,[x0,x12]
    tbnz w10,#31,4f
    add x12,x12,#4
    cmp x12,#48
    b.lo 2b
    ldp x10,x11,[x0,#48]
    orr x10,x10,x11
    cbnz x10,4f
    mov x9,#0
    ret
4:  mov x9,#-22
    ret
.section .rdata,"dr"
wm_record_header: .asciz "# asm-cli-current-v1\n"
wm_host: .asciz "aarch64-windows"
.section .bss
.p2align 3
wm_fields: .skip 48
wm_record_size: .skip 8
wm_record_version: .skip 12
wm_record_min: .skip 12
/* MANAGED_PURE_END */
.text
.macro WM_LOAD reg,symbol
    ARM_ADDR x16,\symbol
    ldr \reg,[x16]
.endm
.macro WM_STORE reg,symbol
    ARM_ADDR x16,\symbol
    str \reg,[x16]
.endm
/* Read canonical native path of borrowed fd into owned4096 UTF8 bytes.
 * x9=0/-22. Native final-path output supplies long spelling for alias checks.
 * Preserves x19; stack32; wide scratch8192, no descriptor ownership. */
win_managed_final_path:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    mov x19,x1
    ARM_ADDR x1,wm_path_w
    mov x2,#4096
    mov x3,#0
    bl GetFinalPathNameByHandleW
    cbz w0,1f
    cmp w0,#4096
    b.hs 1f
    ARM_ADDR x0,wm_path_w
    ARM_CALL win_drive_view
    tbnz x9,#63,1f
    mov x2,x9
    mov w0,#65001
    mov w1,#0x80
    mov w3,#-1
    mov x4,x19
    mov x5,#4096
    mov x6,#0
    mov x7,#0
    bl WideCharToMultiByte
    cbz w0,1f
    mov x0,x19
    ARM_CALL win_slashes
    mov x9,#0
    b 2f
1:  mov x9,#-22
2:  ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    ret
/* Ordinal case-insensitive Windows path equality. x0/x1 bounded UTF8 paths;
 * x9=1 equal,0 mismatch/error. No locale-dependent fold. stack48. */
win_managed_path_equal:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    mov x19,x1
    ARM_ADDR x1,wm_compare_a
    mov x2,#4096
    ARM_CALL win_utf16
    tbnz x9,#63,1f
    mov x0,x19
    ARM_ADDR x1,wm_compare_b
    mov x2,#4096
    ARM_CALL win_utf16
    tbnz x9,#63,1f
    ARM_ADDR x0,wm_compare_a
    mov w1,#-1
    ARM_ADDR x2,wm_compare_b
    mov w3,#-1
    mov w4,#1
    bl CompareStringOrdinal
    cmp w0,#2
    cset x9,eq
    b 2f
1:  mov x9,#0
2:  ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret
/* x0=stat128; x1=0 file/1 directory. x9=0/-22.
 * A private object is current-user-owned and denies unsafe mutable grants.
 * Regular files require a single link. Windows security_stat supplies policy. */
win_managed_stat:
    ldr w10,[x0,#ARM_STAT_UID]
    ARM_ADDR x16,self_uid
    ldr w11,[x16]
    cmp w10,w11
    b.ne 3f
    ldr w10,[x0,#ARM_STAT_MODE]
    mov w11,#18
    tst w10,w11
    b.ne 3f
    and w11,w10,#61440
    cbnz x1,2f
    cmp w11,#32768
    b.ne 3f
    ldr w10,[x0,#ARM_STAT_LINKS]
    cmp w10,#1
    b.ne 3f
    mov x9,#0
    ret
2:  cmp w11,#16384
    b.ne 3f
    mov x9,#0
    ret
3:  mov x9,#-22
    ret
/* x0=fd,x1=owned stat128,x2=directory flag. No close. */
win_managed_check_fd:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    stp x1,x2,[sp,#16]
    ARM_CALL arm_fstat
    cbnz x9,1f
    ldp x0,x1,[sp,#16]
    ARM_CALL win_managed_stat
1:  ldp x29,x30,[sp],#32
    ret
/* x0/x1=stat128; x9=0 iff same volume+file identity. */
win_managed_same:
    ldp x10,x11,[x0]
    ldp x12,x13,[x1]
    eor x10,x10,x12
    eor x11,x11,x13
    orr x9,x10,x11
    ret
/* x0=private directory, x1=leaf, x2=owned stat128.
 * x9=owned private checked subdirectory or -22. stack48. */
win_managed_directory:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    mov x19,x2
    ARM_IMM x2,O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,2f
    mov x20,x9
    mov x0,x20
    mov x1,x19
    mov x2,#1
    ARM_CALL win_managed_check_fd
    cbnz x9,1f
    mov x9,x20
    b 2f
1:  mov x0,x20
    ARM_CALL arm_close
    mov x9,#-22
2:  ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret
/* Initialize fixed paths from normalized checked HOME. Bound3500 leaves room
 * for the entire digest path. Called only after actual role classification. */
win_managed_paths:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    ARM_CALL arm_getuid
    WM_STORE w9,self_uid
    ARM_ADDR x19,win_home_utf8 + 5
    mov x0,x19
    ARM_CALL win_is_absolute
    cbz x9,win_managed_fail
    mov x0,x19
    ARM_CALL strlen
    cmp x9,#3
    b.lo win_managed_fail
    cmp x9,#3500
    b.hi win_managed_fail
    WM_STORE x9,self_home_length
    add x10,x19,x9
    ldrb w10,[x10,#-1]
    cmp w10,#47
    b.eq win_managed_fail
    ARM_ADDR x0,self_install_path
    mov x1,x19
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_root_suffix
    ARM_CALL copy_string
    ARM_ADDR x0,self_parent_path
    mov x1,x19
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_store_suffix
    ARM_CALL copy_string
    ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    ret
/* Actual canonical image path determines role before HOME comparison.
 * x0=path; x9=0 standalone,1 root,2 versioned. x0 unchanged, volatile only.
 * Exact suffix/root+digest spelling; native ordinal comparison handles case. */
win_managed_role:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    mov x19,x0
    ARM_CALL strlen
    mov x20,x9
    cmp x20,#19
    b.lo 3f
    sub x0,x20,#19
    add x0,x19,x0
    ARM_ADDR x1,wm_root_suffix
    ARM_CALL win_managed_path_equal
    cbnz x9,1f
    cmp x20,#102
    b.lo 3f
    sub x0,x20,#102
    add x0,x19,x0
    /* Compare the fixed store suffix prefix by a bounded local copy. */
    ARM_ADDR x10,wm_role_prefix
    mov x11,#30
4:  ldrb w12,[x0],#1
    strb w12,[x10],#1
    subs x11,x11,#1
    b.ne 4b
    strb wzr,[x10]
    ARM_ADDR x0,wm_role_prefix
    ARM_ADDR x1,wm_version_suffix
    ARM_CALL win_managed_path_equal
    cbz x9,3f
    sub x0,x20,#8
    add x0,x19,x0
    ARM_ADDR x1,wm_exe_suffix
    ARM_CALL win_managed_path_equal
    cbz x9,3f
    mov x9,#2
    b 5f
1:  mov x9,#1
    b 5f
3:  mov x9,#0
5:  mov x0,x19
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret
/* Startup returns only for standalone/payload. Root launches and exits with
 * complete child's DWORD. Failures use validated argv --json even preglobals.
 * Owned contexts close on errors and before payload's ordinary CLI dispatch. */
win_managed_startup:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    WM_LOAD x19,argv
1:  ldr x0,[x19],#8
    cbz x0,2f
    ARM_ADDR x1,opt_json
    ARM_CALL streq
    cbz x9,1b
    ARM_ADDR x16,json_mode
    mov w10,#1
    strb w10,[x16]
    b 1b
2:  mov x0,#0
    ARM_ADDR x1,wm_image_path
    mov x2,#4095
    ARM_CALL win_read_running_image
    tbnz x9,#63,win_managed_fail
    ARM_ADDR x0,wm_image_path
    ARM_IMM x1,O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_IMAGE + WIN_OPEN_HELD
    mov x2,#0
    ARM_CALL arm_open
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_own_fd
    mov x0,x9
    ARM_ADDR x1,wm_image_path
    ARM_CALL win_managed_final_path
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_image_path
    ARM_CALL win_managed_role
    WM_STORE x9,wm_role
    cbz x9,.Lwms_return
    ARM_CALL win_managed_paths
    ARM_CALL win_managed_open_state
    WM_LOAD x10,wm_role
    cmp x10,#1
    b.ne .Lwms_payload
    ARM_ADDR x0,wm_image_path
    ARM_ADDR x1,self_install_path
    ARM_CALL win_managed_path_equal
    cbz x9,win_managed_fail
    WM_LOAD x0,wm_root_fd
    ARM_CALL win_image_matches
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_payload_path
    WM_LOAD x1,argv
    WM_LOAD x2,self_current_fd
    ARM_CALL win_managed_launch
    tbnz x9,#63,win_managed_fail
    mov w19,w9
    ARM_CALL win_managed_cleanup
    mov w0,w19
    bl ExitProcess
    brk #0
.Lwms_payload:
    /* A retained payload may differ from current.tsv. Its fixed digest path
     * still binds its own held bytes before any ordinary command runs. */
    ARM_ADDR x0,wm_image_path
    ARM_CALL strlen
    mov x20,x9
    sub x1,x20,#72
    ARM_ADDR x0,wm_image_path
    add x1,x0,x1
    ARM_ADDR x0,wm_own_digest
    mov x2,#64
3:  ldrb w10,[x1],#1
    strb w10,[x0],#1
    subs x2,x2,#1
    b.ne 3b
    strb wzr,[x0]
    ARM_ADDR x0,wm_own_digest
    ARM_CALL win_managed_digest
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_check_path
    ARM_ADDR x1,win_home_utf8 + 5
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_version_suffix
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_own_digest
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_exe_suffix
    ARM_CALL copy_string
    ARM_ADDR x0,wm_image_path
    ARM_ADDR x1,wm_check_path
    ARM_CALL win_managed_path_equal
    cbz x9,win_managed_fail
    WM_LOAD x0,wm_versions_fd
    ARM_ADDR x1,wm_own_digest
    ARM_ADDR x2,wm_own_dir_stat
    ARM_CALL win_managed_directory
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_own_dir_fd
    WM_LOAD x0,wm_own_fd
    ARM_ADDR x1,wm_own_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_own_dir_fd
    ARM_ADDR x1,self_binary_name
    ARM_ADDR x2,wm_own_stat
    mov x3,#0
    ARM_CALL win_managed_entry
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_own_fd
    ARM_CALL win_image_matches
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_own_fd
    ARM_ADDR x16,wm_own_stat
    ldr x1,[x16,#ARM_STAT_SIZE]
    ARM_ADDR x2,wm_hash
    ARM_CALL win_hash_fd
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_hash
    ARM_ADDR x1,wm_own_digest
    ARM_CALL streq
    cbz x9,win_managed_fail
    WM_LOAD x0,wm_own_fd
    ARM_ADDR x16,wm_own_stat
    ldr x1,[x16,#ARM_STAT_SIZE]
    ARM_ADDR x2,wm_own_meta
    ARM_CALL win_managed_pe
    cbnz x9,win_managed_fail
.Lwms_return:
    ARM_CALL win_managed_cleanup
    mov x9,#0
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#48
    ret
/* Open one protected layout and complete selection snapshot. Every descriptor
 * is stored in cleanup-owned state before a later check can fail. */
win_managed_open_state:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    ARM_CALL self_open_parent
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_bin_fd
    mov x0,x9
    ARM_ADDR x1,wm_bin_stat
    mov x2,#1
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_bin_fd
    ARM_CALL win_require_ntfs
    cbnz x9,win_managed_fail
    WM_LOAD x10,wm_updating
    cbz x10,1f
    ARM_CALL win_managed_lock
1:  WM_LOAD x0,wm_bin_fd
    ARM_ADDR x1,wm_store_name
    ARM_ADDR x2,self_parent_stat
    ARM_CALL win_managed_directory
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,self_parent_fd
    mov x0,x9
    ARM_ADDR x1,wm_versions_name
    ARM_ADDR x2,wm_versions_stat
    ARM_CALL win_managed_directory
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_versions_fd
    WM_LOAD x0,self_parent_fd
    ARM_ADDR x1,wm_layout_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_HELD
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_marker_fd
    mov x0,x9
    ARM_ADDR x1,wm_marker_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    ARM_ADDR x16,wm_marker_stat
    ldr x10,[x16,#ARM_STAT_SIZE]
    cmp x10,#20
    b.ne win_managed_fail
    WM_LOAD x0,wm_marker_fd
    ARM_ADDR x1,wm_marker_bytes
    mov x2,#20
    ARM_CALL elf_read_exact
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_marker_bytes
    ARM_ADDR x1,wm_layout_bytes
    ARM_CALL streq
    cbz x9,win_managed_fail
    WM_LOAD x0,self_parent_fd
    ARM_ADDR x1,wm_current_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_HELD
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_record_fd
    mov x0,x9
    ARM_ADDR x1,wm_record_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    ARM_ADDR x16,wm_record_stat
    ldr x19,[x16,#ARM_STAT_SIZE]
    cbz x19,win_managed_fail
    cmp x19,#256
    b.hi win_managed_fail
    WM_STORE x19,wm_record_length
    WM_LOAD x0,wm_record_fd
    ARM_ADDR x1,wm_record_raw
    mov x2,x19
    ARM_CALL elf_read_exact
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_record_fd
    ARM_ADDR x1,wm_eof_byte
    mov x2,#1
    ARM_CALL arm_read
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_record_raw
    ARM_ADDR x1,wm_record_parse
    mov x2,x19
2:  ldrb w10,[x0],#1
    strb w10,[x1],#1
    subs x2,x2,#1
    b.ne 2b
    ARM_ADDR x0,wm_record_parse
    mov x1,x19
    ARM_CALL win_managed_parse_record
    cbnz x9,win_managed_fail
    WM_LOAD x10,wm_role
    cmp x10,#1
    b.ne .Lwm_state_after_snapshot
/* Test synchronization point: root launcher only; old record HANDLE remains
 * held. No volatile register or flags carry state across this label. */
win_managed_snapshot_ready:
.Lwm_state_after_snapshot:
    WM_LOAD x0,wm_bin_fd
    ARM_ADDR x1,self_binary_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_IMAGE + WIN_OPEN_HELD
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_root_fd
    mov x0,x9
    ARM_ADDR x1,wm_root_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_root_fd
    ARM_ADDR x16,wm_root_stat
    ldr x1,[x16,#ARM_STAT_SIZE]
    ARM_ADDR x2,wm_root_meta
    ARM_CALL win_managed_pe
    cbnz x9,win_managed_fail
    WM_LOAD x0,wm_versions_fd
    ARM_ADDR x16,wm_fields
    ldr x1,[x16,#24]
    ARM_ADDR x2,wm_digest_stat
    ARM_CALL win_managed_directory
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_digest_fd
    mov x0,x9
    ARM_ADDR x1,self_binary_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + WIN_OPEN_IMAGE + WIN_OPEN_HELD
    mov x6,#0
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,self_current_fd
    mov x0,x9
    ARM_ADDR x1,self_current_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    WM_LOAD x0,self_current_fd
    WM_LOAD x1,wm_record_size
    ARM_ADDR x2,wm_hash
    ARM_CALL win_hash_fd
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_hash
    ARM_ADDR x16,wm_fields
    ldr x1,[x16,#24]
    ARM_CALL streq
    cbz x9,win_managed_fail
    WM_LOAD x0,self_current_fd
    WM_LOAD x1,wm_record_size
    ARM_ADDR x2,wm_payload_meta
    ARM_CALL win_managed_pe
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_payload_meta + 24
    ARM_ADDR x1,wm_record_version
    ARM_CALL win_managed_triple_equal
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_payload_meta + 36
    ARM_ADDR x1,wm_record_min
    ARM_CALL win_managed_triple_equal
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_root_meta
    ARM_ADDR x1,wm_payload_meta
    ARM_CALL win_managed_compatible
    cbnz x9,win_managed_fail
    ARM_ADDR x0,wm_payload_path
    ARM_ADDR x1,win_home_utf8 + 5
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_version_suffix
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x16,wm_fields
    ldr x1,[x16,#24]
    ARM_CALL copy_string
    mov x0,x9
    ARM_ADDR x1,wm_exe_suffix
    ARM_CALL copy_string
    ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    ret
win_managed_triple_equal:
    ldr x10,[x0]
    ldr x11,[x1]
    eor x10,x10,x11
    ldr w12,[x0,#8]
    ldr w13,[x1,#8]
    eor w12,w12,w13
    orr x9,x10,x12
    ret
/* Both metadata blocks already structurally validated. x0=actual root,
 * x1=payload. x9=0 iff actual launcher version >= required minimum. */
win_managed_compatible:
    add x0,x0,#24
    add x1,x1,#36
    mov x12,#3
1:  ldr w10,[x0],#4
    ldr w11,[x1],#4
    cmp w10,w11
    b.hi 2f
    b.lo 3f
    subs x12,x12,#1
    b.ne 1b
2:  mov x9,#0
    ret
3:  mov x9,#-22
    ret
/* Open stable private lock with shared access, then lock byte0,length1.
 * Lock remains held until cleanup closes wm_lock_fd; no delete-on-close. */
win_managed_lock:
    stp x29,x30,[sp,#-48]!
    mov x29,sp
    WM_LOAD x0,wm_bin_fd
    ARM_ADDR x1,wm_lock_name
    ARM_IMM x2,O_NOFOLLOW + O_CLOEXEC + 64 + 2
    mov x6,#384
    ARM_CALL arm_openat
    tbnz x9,#63,win_managed_fail
    WM_STORE x9,wm_lock_fd
    mov x0,x9
    ARM_ADDR x1,wm_check_stat
    mov x2,#0
    ARM_CALL win_managed_check_fd
    cbnz x9,win_managed_fail
    stp xzr,xzr,[sp,#16]
    stp xzr,xzr,[sp,#32]
    WM_LOAD x0,wm_lock_fd
    mov w1,#3
    mov w2,#0
    mov w3,#1
    mov w4,#0
    add x5,sp,#16
    bl LockFileEx
    cbz w0,self_busy
    ldp x29,x30,[sp],#48
    ret
/* Close owned candidate/next-record files before shared stage deletion.
 * No inputs or result. Each slot becomes -1 before close; repeated calls are
 * safe. Preserve other contexts and the original error. arm_close can change
 * ABI caller-saved registers and flags; stack16 plus arm_close.
 * No name-based deletion occurs here.
 * Legacy FileDispositionInfo retains names while these file handles remain.
 */
win_managed_release_stage_files:
    WM_LOAD x0,wm_candidate_fd
    mov x10,#-1
    WM_STORE x10,wm_candidate_fd
    tbnz x0,#63,1f
    ARM_CALL arm_close
1:  WM_LOAD x0,wm_newrecord_fd
    mov x10,#-1
    WM_STORE x10,wm_newrecord_fd
    tbnz x0,#63,2f
    ARM_CALL arm_close
2:  ret
/* Close only owned contexts. Idempotent; never reports cleanup as activation
 * failure. Shared updater cleanup may already have closed current/store. */
win_managed_cleanup:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    ARM_ADDR x19,wm_cleanup_slots
1:  ldr x10,[x19],#8
    cbz x10,3f
    ldr x0,[x10]
    mov x11,#-1
    str x11,[x10]
    tbnz x0,#63,1b
    ARM_CALL arm_close
    b 1b
3:  ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    ret
win_managed_fail:
    ARM_CALL win_managed_release_stage_files
    ARM_ADDR x0,wm_error
    mov w1,#1
    b self_fail
.section .rdata,"dr"
wm_root_suffix: .asciz "/.local/bin/asm.exe"
wm_store_suffix: .asciz "/.local/bin/.asm-cli"
wm_version_suffix: .asciz "/.local/bin/.asm-cli/versions/"
wm_exe_suffix: .asciz "/asm.exe"
wm_store_name: .asciz ".asm-cli"
wm_versions_name: .asciz "versions"
wm_layout_name: .asciz "layout"
wm_layout_bytes: .asciz "# asm-cli-layout-v1\n"
wm_current_name: .asciz "current.tsv"
wm_lock_name: .asciz ".asm.lock"
wm_error: .asciz "the managed Asm installation is invalid or changed; restore HOME or repair it with the bootstrap installer"
.p2align 3
wm_cleanup_slots:
    .quad wm_bin_fd,wm_versions_fd,wm_marker_fd,wm_record_fd,wm_root_fd
    .quad wm_own_fd,wm_own_dir_fd,wm_digest_fd,wm_lock_fd,wm_candidate_fd,wm_newdir_fd,wm_newrecord_fd
    .quad self_current_fd,self_parent_fd,0
.data
.p2align 3
wm_bin_fd: .quad -1
wm_versions_fd: .quad -1
wm_marker_fd: .quad -1
wm_record_fd: .quad -1
wm_root_fd: .quad -1
wm_own_fd: .quad -1
wm_own_dir_fd: .quad -1
wm_digest_fd: .quad -1
wm_lock_fd: .quad -1
wm_candidate_fd: .quad -1
wm_newdir_fd: .quad -1
wm_newrecord_fd: .quad -1
.section .bss
.p2align 3
wm_role: .skip 8
wm_updating: .skip 8
wm_record_length: .skip 8
wm_bin_stat: .skip 128
wm_versions_stat: .skip 128
wm_marker_stat: .skip 128
wm_record_stat: .skip 128
wm_root_stat: .skip 128
wm_digest_stat: .skip 128
wm_check_stat: .skip 128
wm_own_stat: .skip 128
wm_own_dir_stat: .skip 128
wm_root_meta: .skip 64
wm_payload_meta: .skip 64
wm_own_meta: .skip 64
wm_candidate_meta: .skip 64
wm_record_raw: .skip 257
wm_record_parse: .skip 257
wm_marker_bytes: .skip 21
wm_eof_byte: .skip 1
wm_role_prefix: .skip 64
wm_own_digest: .skip 65
wm_hash: .skip 65
wm_image_path: .skip 4096
wm_payload_path: .skip 4096
wm_check_path: .skip 4096
.p2align 3
wm_path_w: .skip 8192
wm_compare_a: .skip 8192
wm_compare_b: .skip 8192
.text
/* x0=borrowed checked ancestor HANDLE. x9=0 allowed/-13 reserved/error.
 * Invoked for EVERY descriptor in program_walk_parent, including inventory
 * paths, before it can create the next component. Canonical long paths catch
 * 8.3 names; the walk's retained file identities remain the mutation basis. */
win_managed_guard_fd:
    stp x29,x30,[sp,#-32]!
    mov x29,sp
    str x19,[sp,#16]
    mov x19,x0
    WM_LOAD x10,wm_role
    cbz x10,3f
    ARM_ADDR x1,wm_guard_stat
    ARM_CALL arm_fstat
    cbnz x9,1f
    ARM_ADDR x0,wm_guard_stat
    ARM_ADDR x1,self_parent_stat
    ARM_CALL win_managed_same
    cbz x9,1f
3:  mov x0,x19
    ARM_ADDR x1,wm_guard_path
    ARM_CALL win_managed_final_path
    cbnz x9,1f
    ARM_ADDR x0,wm_guard_path
    ARM_CALL win_managed_reserved_path
    b 2f
1:  mov x9,#-13
2:  ldr x19,[sp,#16]
    ldp x29,x30,[sp],#32
    ret
/* x0=canonical path from an actual held ancestor, <=4095 UTF8 bytes.
 * x9=0 allowed/-13 reserved. Does not trust HOME, inventory text, or 8.3
 * spelling. Any fixed .local/bin/.asm-cli ancestor reserves the whole tree.
 * Ordinal Windows matching; stack64, owned segment[21] and compare buffers. */
win_managed_reserved_path:
    stp x29,x30,[sp,#-64]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    mov x19,x0
    ARM_CALL strlen
    mov x20,x9
    mov x21,#0
1:  add x10,x21,#20
    cmp x10,x20
    b.hi 5f
    ldrb w10,[x19,x21]
    cmp w10,#47
    b.ne 4f
    add x22,x21,#20
    ldrb w10,[x19,x22]
    cbz w10,2f
    cmp w10,#47
    b.ne 4f
2:  add x0,x19,x21
    ARM_ADDR x1,wm_guard_segment
    mov x2,#20
3:  ldrb w10,[x0],#1
    strb w10,[x1],#1
    subs x2,x2,#1
    b.ne 3b
    strb wzr,[x1]
    ARM_ADDR x0,wm_guard_segment
    ARM_ADDR x1,wm_store_suffix
    ARM_CALL win_managed_path_equal
    cbnz x9,6f
4:  add x21,x21,#1
    b 1b
5:  mov x9,#0
    b 7f
6:  mov x9,#-13
7:  ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#64
    ret
.section .bss
wm_guard_stat: .skip 128
wm_guard_path: .skip 4096
wm_guard_segment: .skip 21

.text
/* x0=borrowed fd, x1=exact size, x2=owned64 metadata output.
 * x9=0/-22; no input close. Full container gate then unique bounded .asmmeta.
 * Preserves x19-x26; stack96. Does not map or execute any artifact.
 */
win_managed_pe:
    stp x29,x30,[sp,#-96]!
    mov x29,sp
    stp x19,x20,[sp,#16]
    stp x21,x22,[sp,#32]
    stp x23,x24,[sp,#48]
    stp x25,x26,[sp,#64]
    mov x19,x0
    mov x20,x1
    mov x21,x2
    ARM_CALL win_validate_pe_fd
    cbz x9,.Lwmpe_bad
    mov x0,x19
    mov x1,#60
    mov x2,#0
    ARM_CALL arm_lseek
    cmp x9,#60
    b.ne .Lwmpe_bad
    mov x0,x19
    ARM_ADDR x1,win_pe_header
    mov x2,#4
    ARM_CALL elf_read_exact
    cbnz x9,.Lwmpe_bad
    ARM_ADDR x16,win_pe_header
    ldr w22,[x16]
    mov x0,x19
    mov x1,x22
    mov x2,#0
    ARM_CALL arm_lseek
    cmp x9,x22
    b.ne .Lwmpe_bad
    mov x0,x19
    ARM_ADDR x1,win_pe_header
    mov x2,#24
    ARM_CALL elf_read_exact
    cbnz x9,.Lwmpe_bad
    ARM_ADDR x16,win_pe_header
    ldrh w23,[x16,#6]
    add x22,x22,#264
    mov x24,#0
    mov x25,#0
.Lwmpe_section:
    mov x0,x19
    mov x1,x22
    mov x2,#0
    ARM_CALL arm_lseek
    cmp x9,x22
    b.ne .Lwmpe_bad
    mov x0,x19
    ARM_ADDR x1,win_pe_header
    mov x2,#40
    ARM_CALL elf_read_exact
    cbnz x9,.Lwmpe_bad
    ARM_ADDR x16,win_pe_header
    ldr x10,[x16]
    ARM_IMM x11,0x6174656d6d73612e
    cmp x10,x11
    b.ne .Lwmpe_next
    cbnz x24,.Lwmpe_bad
    mov x24,#1
    ldr w10,[x16,#8]
    cmp w10,#64
    b.ne .Lwmpe_bad
    ldr w10,[x16,#16]
    cmp w10,#64
    b.lo .Lwmpe_bad
    ldr w25,[x16,#20]
    add x10,x25,x10
    cmp x10,x20
    b.hi .Lwmpe_bad
    ldr w10,[x16,#36]
    ARM_IMM w11,0xe00000e0
    and w10,w10,w11
    ARM_IMM w11,0x40000040
    cmp w10,w11
    b.ne .Lwmpe_bad
.Lwmpe_next:
    add x22,x22,#40
    subs x23,x23,#1
    b.ne .Lwmpe_section
    cbz x24,.Lwmpe_bad
    mov x0,x19
    mov x1,x25
    mov x2,#0
    ARM_CALL arm_lseek
    cmp x9,x25
    b.ne .Lwmpe_bad
    mov x0,x19
    mov x1,x21
    mov x2,#64
    ARM_CALL elf_read_exact
    cbnz x9,.Lwmpe_bad
    mov x0,x21
    ARM_CALL win_managed_metadata
    b .Lwmpe_done
.Lwmpe_bad:
    mov x9,#-22
.Lwmpe_done:
    ldp x25,x26,[sp,#64]
    ldp x23,x24,[sp,#48]
    ldp x21,x22,[sp,#32]
    ldp x19,x20,[sp,#16]
    ldp x29,x30,[sp],#96
    ret

/* MANAGED_PE_END */
.text
/* x0=actual mutation parent HANDLE. Only the active managed updater can
 * write its reserved store. Other commands check the actual held ancestor.
 * Returns x9=0/-13; preserves callee-saved registers; no fd ownership. */
win_managed_write_allowed:
    ARM_ADDR x16,self_active
    ldrb w10,[x16]
    cbz w10,1f
    WM_LOAD x10,wm_updating
    cmp x10,#1
    b.ne 1f
    mov x9,#0
    ret
1:  b win_managed_guard_fd
/* Check a registry/dependency workspace before any temporary object or lock.
 * No inputs; preserves x0-x7 and callee-saved registers. x9=0/-13. Owns one
 * temporary read-only cwd descriptor and always closes it. stack112. */
win_managed_check_cwd:
    WIN_SAVE
    sub sp,sp,#16
    ARM_ADDR x0,wm_dot
    ARM_IMM x1,O_DIRECTORY + O_NOFOLLOW + O_CLOEXEC
    mov x2,#0
    ARM_CALL arm_open
    tbnz x9,#63,1f
    str x9,[sp]
    mov x0,x9
    ARM_CALL win_managed_write_allowed
    str x9,[sp,#8]
    ldr x0,[sp]
    ARM_CALL arm_close
    ldr x9,[sp,#8]
    b 2f
1:  mov x9,#-13
2:  add sp,sp,#16
    WIN_RETURN
.section .rdata,"dr"
wm_dot: .asciz "."
