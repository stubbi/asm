/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux AArch64 LP64, AAPCS64. Fixed-key non-serving configuration snapshot.
 * Single invocation before threads. Ancestors of supplied root paths are
 * trusted operator inputs; pinned dirfds protect only operations beneath them.
 */
.arch armv8-a
.macro PREP_ADDR reg, symbol
    adrp \reg, \symbol
    add \reg, \reg, :lo12:\symbol
.endm
.equ PREP_MKDIRAT, 34
.equ PREP_UNLINKAT, 35
.equ PREP_FSTATFS, 44
.equ PREP_FCHMOD, 52
.equ PREP_OPENAT, 56
.equ PREP_CLOSE, 57
.equ PREP_READ, 63
.equ PREP_WRITE, 64
.equ PREP_FSTAT, 80
.equ PREP_FSYNC, 82
.equ PREP_GETUID, 174
.equ PREP_GETEUID, 175
.equ PREP_GETGID, 176
.equ PREP_GETEGID, 177
.equ PREP_RENAMEAT2, 276
.equ PREP_GETRANDOM, 278
.equ PREP_OPENAT2, 437
.equ PREP_EINTR, 4
.equ PREP_ENOENT, 2
.equ PREP_EEXIST, 17
.equ PREP_INTERRUPTS, 16
.equ PREP_COLLISIONS, 16
.equ PREP_LIMIT, 4096
.equ PREP_READ_CAPACITY, 4097
.equ PREP_MODE, 16
.equ PREP_NLINK, 20
.equ PREP_UID, 24
.equ PREP_GID, 28
.equ PREP_SIZE, 48

.section .rodata
.Lprep_key: .asciz "database.url"
.Lprep_private: .asciz "private"
.Lprep_prefix: .ascii ".asm-prepare-"
.Lprep_hex: .ascii "0123456789abcdef"
.balign 8
/* Normal projected symlinks are allowed, but not escape, magiclink, or mount
 * crossing. O_RDONLY|O_NONBLOCK|O_CLOEXEC; openat2 has no fallback. */
.Lprep_source_how: .quad 0x80800, 0, 11

.section .bss
.balign 8
.Lprep_stat: .zero 160
.Lprep_statfs: .zero 128
.Lprep_bytes: .zero PREP_READ_CAPACITY
.Lprep_compare: .zero PREP_READ_CAPACITY
.Lprep_name: .zero 64
.Lprep_random: .zero 16

.section .text
.globl prepare_config
.type prepare_config,%function
/* x0=source absolute directory, x1=destination absolute directory. Borrowed
 * strings must be NUL-terminated within 1025 readable bytes. Returns w0=0
 * or78; no environment, DNS, database, listener, subprocess, or diagnostic.
 * Frame128 saves x19-x30, two root pointers, status and new-directory flag.
 * Preserves x19-x29/SP and changes caller-saved only. Owned BSS buffers are
 * single-invocation storage: bytes4097, comparison4097, stat160, statfs128,
 * random16, temporary name64. Raw syscall numbers/layouts need the ABI gate.
 * Roots/source are descriptors; no concatenated package/operator filename.
 * Same-UID actors and trusted ancestors remain outside the boundary.
 */
prepare_config:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    str x0, [sp, #96]
    str x1, [sp, #104]
    mov x19, #-1               /* source root */
    mov x20, #-1               /* destination root */
    mov x21, #-1               /* private child */
    mov x22, #-1               /* source file */
    mov x23, #-1               /* temporary file */
    mov x28, #0                /* only own name may be unlinked */
    str wzr, [sp, #120]
    bl .Lprep_path
    cbz w0, .Lprep_bad
    ldr x0, [sp, #104]
    bl .Lprep_path
    cbz w0, .Lprep_bad

    mov x8, #PREP_GETUID
    svc #0
    tbnz x0, #63, .Lprep_bad
    mov w25, w0
    cbz w25, .Lprep_bad
    mov x8, #PREP_GETEUID
    svc #0
    tbnz x0, #63, .Lprep_bad
    cmp w0, w25
    b.ne .Lprep_bad
    mov x8, #PREP_GETGID
    svc #0
    tbnz x0, #63, .Lprep_bad
    mov w26, w0
    cbz w26, .Lprep_bad
    mov x8, #PREP_GETEGID
    svc #0
    tbnz x0, #63, .Lprep_bad
    cmp w0, w26
    b.ne .Lprep_bad

    mov x0, #-100              /* AT_FDCWD, final component must be a directory */
    ldr x1, [sp, #96]
    mov w2, #0xc000
    movk w2, #8, lsl #16       /* O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC =0x8c000 */
    mov x3, #0
    mov x8, #PREP_OPENAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    mov x19, x0
    mov w1, #1                 /* source root requires readonly if group write */
    bl .Lprep_root_metadata
    cbnz w0, .Lprep_bad
    mov x0, #-100
    ldr x1, [sp, #104]
    mov w2, #0xc000
    movk w2, #8, lsl #16
    mov x3, #0
    mov x8, #PREP_OPENAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    mov x20, x0
    mov w1, #0
    bl .Lprep_root_metadata
    cbnz w0, .Lprep_bad

    mov x0, x19
    PREP_ADDR x1, .Lprep_key
    PREP_ADDR x2, .Lprep_source_how
    mov x3, #24
    mov x8, #PREP_OPENAT2
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    mov x22, x0
    PREP_ADDR x1, .Lprep_stat
    mov x8, #PREP_FSTAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    PREP_ADDR x11, .Lprep_stat
    ldr w9, [x11, #PREP_MODE]
    and w10, w9, #0xf000
    mov w12, #0x8000           /* S_IFREG */
    cmp w10, w12
    b.ne .Lprep_bad
    mov w10, #0x0e5f           /* every permission/special bit except0640 */
    tst w9, w10
    b.ne .Lprep_bad
    ldr w9, [x11, #PREP_NLINK]
    cmp w9, #1
    b.ne .Lprep_bad
    ldr w9, [x11, #PREP_UID]
    cbz w9, .Lprep_source_owner_ok
    cmp w9, w25
    b.ne .Lprep_bad
.Lprep_source_owner_ok:
    ldr w9, [x11, #PREP_GID]
    cmp w9, w26
    b.ne .Lprep_bad
    ldr x9, [x11, #PREP_SIZE]
    cbz x9, .Lprep_bad
    cmp x9, #PREP_LIMIT
    b.hi .Lprep_bad            /* unsigned also rejects negative length */
    mov x27, #0
.Lprep_read_source:
    mov x0, x22
    PREP_ADDR x1, .Lprep_bytes
    add x1, x1, x27
    mov x2, #PREP_READ_CAPACITY
    sub x2, x2, x27
    mov x8, #PREP_READ
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    cbz x0, .Lprep_source_eof
    add x27, x27, x0
    cmp x27, #PREP_LIMIT
    b.hi .Lprep_bad
    b .Lprep_read_source
.Lprep_source_eof:
    cbz x27, .Lprep_bad
    PREP_ADDR x9, .Lprep_bytes
    mov x10, #0
.Lprep_text:
    ldrb w11, [x9, x10]
    cmp w11, #10
    b.eq .Lprep_final_lf
    cmp w11, #32
    b.lo .Lprep_bad
    cmp w11, #126
    b.hi .Lprep_bad
    add x10, x10, #1
    cmp x10, x27
    b.lo .Lprep_text
    b .Lprep_text_ok
.Lprep_final_lf:
    cbz x10, .Lprep_bad
    add x10, x10, #1
    cmp x10, x27
    b.ne .Lprep_bad
.Lprep_text_ok:
    mov x0, x22
    mov x22, #-1
    mov x8, #PREP_CLOSE
    svc #0                    /* close is never retried */
    tbnz x0, #63, .Lprep_bad

    mov x0, x20
    PREP_ADDR x1, .Lprep_private
    mov w2, #0700
    mov x8, #PREP_MKDIRAT
    bl .Lprep_syscall_retry
    cbz x0, .Lprep_new_private
    cmn x0, #PREP_EEXIST
    b.ne .Lprep_bad
    b .Lprep_open_private
.Lprep_new_private:
    mov w9, #1
    str w9, [sp, #120]
.Lprep_open_private:
    mov x0, x20
    PREP_ADDR x1, .Lprep_private
    mov w2, #0xc000
    movk w2, #8, lsl #16
    mov x3, #0
    mov x8, #PREP_OPENAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    mov x21, x0
    ldr w9, [sp, #120]
    cbz w9, .Lprep_check_private
    mov w1, #0700             /* removes inherited SGID on our new child only */
    mov x8, #PREP_FCHMOD
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
.Lprep_check_private:
    mov x0, x21
    PREP_ADDR x1, .Lprep_stat
    mov x8, #PREP_FSTAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    PREP_ADDR x11, .Lprep_stat
    ldr w9, [x11, #PREP_MODE]
    mov w10, #0x41c0           /* S_IFDIR|0700, no special bits */
    cmp w9, w10
    b.ne .Lprep_bad
    ldr w9, [x11, #PREP_UID]
    cmp w9, w25
    b.ne .Lprep_bad
    bl .Lprep_existing
    cbz w0, .Lprep_good
    cmp w0, #1
    b.ne .Lprep_bad

    mov x24, #PREP_COLLISIONS
.Lprep_new_name:
    mov x12, #0
.Lprep_random_next:
    PREP_ADDR x0, .Lprep_random
    add x0, x0, x12
    mov x1, #16
    sub x1, x1, x12
    mov x2, #1                 /* GRND_NONBLOCK: refuse unavailable entropy */
    mov x8, #PREP_GETRANDOM
    bl .Lprep_syscall_retry
    cmp x0, #0
    b.le .Lprep_bad
    add x12, x12, x0
    cmp x12, #16
    b.lo .Lprep_random_next
    PREP_ADDR x9, .Lprep_name
    PREP_ADDR x10, .Lprep_prefix
    mov x11, #0
.Lprep_name_prefix:
    ldrb w12, [x10, x11]
    strb w12, [x9, x11]
    add x11, x11, #1
    cmp x11, #13
    b.lo .Lprep_name_prefix
    add x9, x9, #13
    PREP_ADDR x10, .Lprep_random
    PREP_ADDR x11, .Lprep_hex
    mov x12, #0
.Lprep_name_hex:
    ldrb w13, [x10, x12]
    lsr w14, w13, #4
    and w13, w13, #15
    ldrb w14, [x11, x14]
    ldrb w13, [x11, x13]
    strb w14, [x9], #1
    strb w13, [x9], #1
    add x12, x12, #1
    cmp x12, #16
    b.lo .Lprep_name_hex
    strb wzr, [x9]
    mov x0, x21
    PREP_ADDR x1, .Lprep_name
    mov w2, #0x88c1
    movk w2, #8, lsl #16       /* WRONLY|CREAT|EXCL|NONBLOCK|NOFOLLOW|CLOEXEC */
    mov w3, #0600
    mov x8, #PREP_OPENAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_name_error
    mov x23, x0
    mov x28, #1
    mov w1, #0600
    mov x8, #PREP_FCHMOD
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    mov x0, x23
    PREP_ADDR x1, .Lprep_stat
    mov x8, #PREP_FSTAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    bl .Lprep_output_metadata
    cbnz w0, .Lprep_bad
    PREP_ADDR x9, .Lprep_stat
    ldr x9, [x9, #PREP_SIZE]
    cbnz x9, .Lprep_bad
    mov x12, #0
.Lprep_write_next:
    mov x0, x23
    PREP_ADDR x1, .Lprep_bytes
    add x1, x1, x12
    sub x2, x27, x12
    mov x8, #PREP_WRITE
    bl .Lprep_syscall_retry
    cmp x0, #0
    b.le .Lprep_bad
    add x12, x12, x0
    cmp x12, x27
    b.lo .Lprep_write_next
    mov x0, x23
    mov x8, #PREP_FSYNC
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    mov x0, x23
    PREP_ADDR x1, .Lprep_stat
    mov x8, #PREP_FSTAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_bad
    bl .Lprep_output_metadata
    cbnz w0, .Lprep_bad
    PREP_ADDR x9, .Lprep_stat
    ldr x9, [x9, #PREP_SIZE]
    cmp x9, x27
    b.ne .Lprep_bad
    mov x0, x23
    mov x23, #-1
    mov x8, #PREP_CLOSE
    svc #0
    tbnz x0, #63, .Lprep_bad
    mov x0, x21
    PREP_ADDR x1, .Lprep_name
    mov x2, x21
    PREP_ADDR x3, .Lprep_key
    mov w4, #1                 /* RENAME_NOREPLACE */
    mov x8, #PREP_RENAMEAT2
    bl .Lprep_syscall_retry
    cbz x0, .Lprep_published
    cmn x0, #PREP_EEXIST
    b.ne .Lprep_bad
    bl .Lprep_existing
    cbnz w0, .Lprep_bad
    b .Lprep_good              /* remove only our still-owned temporary name */
.Lprep_name_error:
    cmn x0, #PREP_EEXIST
    b.ne .Lprep_bad
    subs x24, x24, #1
    b.ne .Lprep_new_name
    b .Lprep_bad
.Lprep_published:
    mov x28, #0                /* rename consumed our name */
.Lprep_good:
    mov w0, #0
    b .Lprep_cleanup
.Lprep_bad:
    mov w0, #78
.Lprep_cleanup:
    str w0, [sp, #112]
    cbz x28, .Lprep_close_temp
    mov x0, x21
    PREP_ADDR x1, .Lprep_name
    mov x2, #0
    mov x8, #PREP_UNLINKAT
    bl .Lprep_syscall_retry
    cmp x0, #0
    b.ge .Lprep_close_temp
    mov w9, #78
    str w9, [sp, #112]
.Lprep_close_temp:
    tbnz x23, #63, .Lprep_close_source
    mov x0, x23
    mov x8, #PREP_CLOSE
    svc #0
.Lprep_close_source:
    tbnz x22, #63, .Lprep_close_private
    mov x0, x22
    mov x8, #PREP_CLOSE
    svc #0
.Lprep_close_private:
    tbnz x21, #63, .Lprep_close_destination
    mov x0, x21
    mov x8, #PREP_CLOSE
    svc #0
.Lprep_close_destination:
    tbnz x20, #63, .Lprep_close_root
    mov x0, x20
    mov x8, #PREP_CLOSE
    svc #0
.Lprep_close_root:
    tbnz x19, #63, .Lprep_return
    mov x0, x19
    mov x8, #PREP_CLOSE
    svc #0
.Lprep_return:
    ldr w0, [sp, #112]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #128
    ret
.size prepare_config,.-prepare_config

/* x0=path borrowed from argv; w0=1/0. Leaf, no stack; changes x9-x13.
 * Reads at most1025 bytes. Absolute length1..1024; no ambiguous final
 * slash/dot/dot-dot component except literal /. Ancestors remain trusted. */
.Lprep_path:
    cbz x0, .Lprep_path_bad
    ldrb w9, [x0]
    cmp w9, #'/'
    b.ne .Lprep_path_bad
    mov x10, #0
.Lprep_path_length:
    ldrb w9, [x0, x10]
    cbz w9, .Lprep_path_end
    cmp x10, #1024
    b.hs .Lprep_path_bad
    add x10, x10, #1
    b .Lprep_path_length
.Lprep_path_end:
    cmp x10, #1
    b.eq .Lprep_path_good
    sub x11, x10, #1
    ldrb w9, [x0, x11]
    cmp w9, #'/'
    b.eq .Lprep_path_bad
    cmp w9, #'.'
    b.ne .Lprep_path_good
    sub x11, x11, #1
    ldrb w9, [x0, x11]
    cmp w9, #'/'
    b.eq .Lprep_path_bad
    cmp w9, #'.'
    b.ne .Lprep_path_good
    sub x11, x11, #1
    ldrb w9, [x0, x11]
    cmp w9, #'/'
    b.eq .Lprep_path_bad
.Lprep_path_good:
    mov w0, #1
    ret
.Lprep_path_bad:
    mov w0, #0
    ret

/* x8=syscall, x0-x5=arguments. Raw signed x0 result; at most16 EINTR
 * retries per operation. Leaf, no stack; changes x0,x9,x10 and flags only.
 * Linux AArch64 svc preserves argument registers other than result x0.
 * close must bypass this helper because Linux can already release its fd. */
.Lprep_syscall_retry:
    mov x9, x0
    mov x10, #PREP_INTERRUPTS
.Lprep_syscall_again:
    svc #0
    cmn x0, #PREP_EINTR
    b.ne .Lprep_syscall_return
    cbz x10, .Lprep_syscall_return
    sub x10, x10, #1
    mov x0, x9
    b .Lprep_syscall_again
.Lprep_syscall_return:
    ret

/* Internal: x0=root fd, w1=source flag, w25=current UID,w26=selected GID.
 * w0=0/78. Frame32 preserves x19/x20 and FP/LR; all other callee-saved
 * untouched. stat160/statfs128 are shared owned scratch; no concurrent use. */
.Lprep_root_metadata:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    PREP_ADDR x1, .Lprep_stat
    mov x8, #PREP_FSTAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_root_bad
    PREP_ADDR x11, .Lprep_stat
    ldr w9, [x11, #PREP_MODE]
    and w10, w9, #0xf000
    cmp w10, #0x4000
    b.ne .Lprep_root_bad
    tbnz w9, #1, .Lprep_root_bad /* no other write */
    ldr w10, [x11, #PREP_UID]
    cbz w10, .Lprep_root_owner_ok
    cmp w10, w25
    b.ne .Lprep_root_bad
.Lprep_root_owner_ok:
    ldr w10, [x11, #PREP_GID]
    cmp w10, w26
    b.ne .Lprep_root_bad
    cbz w20, .Lprep_root_good
    tbz w9, #4, .Lprep_root_good /* group writable source needs readonly mount */
    mov x0, x19
    PREP_ADDR x1, .Lprep_statfs
    mov x8, #PREP_FSTATFS
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_root_bad
    PREP_ADDR x11, .Lprep_statfs
    ldr x9, [x11, #80]
    tbz x9, #0, .Lprep_root_bad  /* ST_RDONLY */
.Lprep_root_good:
    mov w0, #0
    b .Lprep_root_return
.Lprep_root_bad:
    mov w0, #78
.Lprep_root_return:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

/* Internal: stat scratch describes output; w25/w26 required UID/GID.
 * Returns w0=0/78; leaf, no stack, caller-saved only. Requires exact regular
 * 0600, single link, current UID and selected GID; caller checks length. */
.Lprep_output_metadata:
    PREP_ADDR x11, .Lprep_stat
    ldr w9, [x11, #PREP_MODE]
    mov w10, #0x8180           /* S_IFREG|0600 */
    cmp w9, w10
    b.ne .Lprep_output_bad
    ldr w9, [x11, #PREP_NLINK]
    cmp w9, #1
    b.ne .Lprep_output_bad
    ldr w9, [x11, #PREP_UID]
    cmp w9, w25
    b.ne .Lprep_output_bad
    ldr w9, [x11, #PREP_GID]
    cmp w9, w26
    b.ne .Lprep_output_bad
    mov w0, #0
    ret
.Lprep_output_bad:
    mov w0, #78
    ret

/* Internal: x21=private dirfd,w25/w26=UID/GID,x27=expected length and owned
 * bytes buffer. w0=0 exact no-op,1 absent,78 refusal. Frame48 preserves
 * x19/x20 and FP/LR and owns status. Reads at most4097 into compare buffer;
 * opens NOFOLLOW|NONBLOCK to avoid following links or blocking on a FIFO.
 * Preserves existing bytes, inode, mtime, and its directory. Reading can
 * update atime under the filesystem's access-time policy. */
.Lprep_existing:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, #-1
    mov x0, x21
    PREP_ADDR x1, .Lprep_key
    mov w2, #0x8800
    movk w2, #8, lsl #16
    mov x3, #0
    mov x8, #PREP_OPENAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_existing_open_error
    mov x19, x0
    PREP_ADDR x1, .Lprep_stat
    mov x8, #PREP_FSTAT
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_existing_bad
    bl .Lprep_output_metadata
    cbnz w0, .Lprep_existing_bad
    PREP_ADDR x11, .Lprep_stat
    ldr x9, [x11, #PREP_SIZE]
    cmp x9, x27
    b.ne .Lprep_existing_bad
    mov x20, #0
.Lprep_existing_read:
    mov x0, x19
    PREP_ADDR x1, .Lprep_compare
    add x1, x1, x20
    mov x2, #PREP_READ_CAPACITY
    sub x2, x2, x20
    mov x8, #PREP_READ
    bl .Lprep_syscall_retry
    tbnz x0, #63, .Lprep_existing_bad
    cbz x0, .Lprep_existing_eof
    add x20, x20, x0
    cmp x20, x27
    b.hi .Lprep_existing_bad
    b .Lprep_existing_read
.Lprep_existing_eof:
    cmp x20, x27
    b.ne .Lprep_existing_bad
    PREP_ADDR x9, .Lprep_bytes
    PREP_ADDR x10, .Lprep_compare
    mov x11, #0
.Lprep_existing_compare:
    ldrb w12, [x9, x11]
    ldrb w13, [x10, x11]
    cmp w12, w13
    b.ne .Lprep_existing_bad
    add x11, x11, #1
    cmp x11, x27
    b.lo .Lprep_existing_compare
    mov w0, #0
    b .Lprep_existing_close
.Lprep_existing_open_error:
    cmn x0, #PREP_ENOENT
    b.ne .Lprep_existing_bad
    mov w0, #1
    b .Lprep_existing_close
.Lprep_existing_bad:
    mov w0, #78
.Lprep_existing_close:
    str w0, [sp, #32]
    tbnz x19, #63, .Lprep_existing_return
    mov x0, x19
    mov x8, #PREP_CLOSE
    svc #0
    cmp x0, #0
    b.ge .Lprep_existing_return
    mov w9, #78
    str w9, [sp, #32]
.Lprep_existing_return:
    ldr w0, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

.section .note.GNU-stack,"",%progbits
