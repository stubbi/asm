/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux RV64GC/LP64D fixed-key configuration snapshot. No networking/libpq.
 * Ancestor directories are trusted operator input; final roots are pinned.
 * openat2 is mandatory. Unsupported or blocked calls fail without a fallback.
 * The private child excludes other UIDs, not other processes of the same UID.
 */
.option pic
.option norelax
.attribute arch, "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"
.equ PC_EINTR_RETRIES, 16
.equ PC_NAME_ATTEMPTS, 16
.equ PC_CONTENT_LIMIT, 4096
.equ PC_READ_CAPACITY, 4097
.equ PC_PATH_LIMIT, 1024
.equ PC_FRAME, 8832
.equ PC_NAME, 128
.equ PC_RANDOM, 192
.equ PC_STAT, 224
.equ PC_STATFS, 384
.equ PC_HOW, 512
.equ PC_SOURCE, 544
.equ PC_EXISTING, 4656
.equ PC_NAME_LEFT, 8784
.equ PC_NEW_PRIVATE, 8792
.equ PC_RANDOM_DONE, 8800
.equ PC_RESULT, 8808
.equ PC_SYS_MKDIRAT, 34
.equ PC_SYS_UNLINKAT, 35
.equ PC_SYS_FSTATFS, 44
.equ PC_SYS_FCHMOD, 52
.equ PC_SYS_OPENAT, 56
.equ PC_SYS_CLOSE, 57
.equ PC_SYS_READ, 63
.equ PC_SYS_WRITE, 64
.equ PC_SYS_FSTAT, 80
.equ PC_SYS_FSYNC, 82
.equ PC_SYS_GETUID, 174
.equ PC_SYS_GETEUID, 175
.equ PC_SYS_GETGID, 176
.equ PC_SYS_GETEGID, 177
.equ PC_SYS_RENAMEAT2, 276
.equ PC_SYS_GETRANDOM, 278
.equ PC_SYS_OPENAT2, 437
.equ PC_AT_FDCWD, -100
.equ PC_ROOT_FLAGS, 0xb0000   /* O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC */
.equ PC_SOURCE_FLAGS, 0x80800 /* O_RDONLY | O_CLOEXEC | O_NONBLOCK */
.equ PC_EXISTING_FLAGS, 0xa0800
.equ PC_TEMP_FLAGS, 0xa00c1   /* WRONLY | CREAT | EXCL | NOFOLLOW | CLOEXEC */
.equ PC_RESOLVE, 11           /* BENEATH | NO_MAGICLINKS | NO_XDEV */
.equ PC_RENAME_NOREPLACE, 1
.equ PC_STAT_MODE, 16
.equ PC_STAT_LINKS, 20
.equ PC_STAT_UID, 24
.equ PC_STAT_GID, 28
.equ PC_STAT_SIZE, 48
.equ PC_STATFS_FLAGS, 80

.macro pc_address destination, offset
    li \destination, \offset
    add \destination, sp, \destination
.endm

.section .rodata
.Lpc_key: .asciz "database.url"
.Lpc_private: .asciz "private"
.Lpc_prefix: .ascii ".asm-config-"
.Lpc_hex: .ascii "0123456789abcdef"

.section .text
.globl prepare_config
.type prepare_config,@function
/* a0/a1=borrowed absolute SOURCE_DIR/DEST_DIR, each <=1024 bytes plus NUL.
 * Returns a0=0 or78. Changes caller-saved; preserves s0-s11/gp/tp and SP16.
 * Frame8832 owns two4097-byte buffers, stat160, statfs128, open_how24,
 * temporary-name64/random16 and scalar state. No buffer is shared or returned.
 * Raw Linux errors remain signed longs; every retryable syscall has16 EINTR
 * retries. close is never retried. Only this invocation's temporary is removed.
 * fsync covers file bytes; no power-loss directory-durability claim is made. */
prepare_config:
    li t0, PC_FRAME
    sub sp, sp, t0
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd s6, 56(sp)
    sd s7, 64(sp)
    sd s8, 72(sp)
    sd s9, 80(sp)
    sd s10, 88(sp)
    sd s11, 96(sp)
    mv s10, a0
    mv s11, a1
    li s2, -1                 /* pinned source root */
    li s3, -1                 /* pinned destination root */
    li s4, -1                 /* pinned input file */
    li s5, -1                 /* pinned private child */
    li s6, -1                 /* owned temporary file */
    li s7, -1                 /* existing destination file */
    li s9, 0                  /* owned temporary name exists */
    pc_address t0, PC_RESULT
    li t1, 78
    sd t1, 0(t0)
    call .Lpc_path
    beqz a0, .Lpc_cleanup
    mv a0, s11
    call .Lpc_path
    beqz a0, .Lpc_cleanup
    li a7, PC_SYS_GETUID
    ecall
    blez a0, .Lpc_cleanup
    mv s0, a0
    li a7, PC_SYS_GETEUID
    ecall
    bne a0, s0, .Lpc_cleanup
    li a7, PC_SYS_GETGID
    ecall
    blez a0, .Lpc_cleanup
    mv s1, a0
    li a7, PC_SYS_GETEGID
    ecall
    bne a0, s1, .Lpc_cleanup

    li a0, PC_AT_FDCWD
    mv a1, s10
    li a2, PC_ROOT_FLAGS
    li a3, 0
    li a7, PC_SYS_OPENAT
    call .Lpc_syscall
    bltz a0, .Lpc_cleanup
    mv s2, a0
    li a1, 1
    mv a2, s0
    mv a3, s1
    pc_address a4, PC_STAT
    pc_address a5, PC_STATFS
    call .Lpc_root
    bnez a0, .Lpc_cleanup
    li a0, PC_AT_FDCWD
    mv a1, s11
    li a2, PC_ROOT_FLAGS
    li a3, 0
    li a7, PC_SYS_OPENAT
    call .Lpc_syscall
    bltz a0, .Lpc_cleanup
    mv s3, a0
    li a1, 0
    mv a2, s0
    mv a3, s1
    pc_address a4, PC_STAT
    pc_address a5, PC_STATFS
    call .Lpc_root
    bnez a0, .Lpc_cleanup

    pc_address t0, PC_HOW
    li t1, PC_SOURCE_FLAGS
    sd t1, 0(t0)
    sd zero, 8(t0)
    li t1, PC_RESOLVE
    sd t1, 16(t0)
    mv a0, s2
    la a1, .Lpc_key
    mv a2, t0
    li a3, 24
    li a7, PC_SYS_OPENAT2
    call .Lpc_syscall
    bltz a0, .Lpc_cleanup
    mv s4, a0
    pc_address a1, PC_STAT
    li a7, PC_SYS_FSTAT
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
    pc_address t0, PC_STAT
    lwu t1, PC_STAT_MODE(t0)
    li t2, 0170000
    and t2, t1, t2
    li t3, 0100000
    bne t2, t3, .Lpc_cleanup
    li t2, 07777
    and t1, t1, t2
    li t2, 0640
    not t2, t2
    and t1, t1, t2
    bnez t1, .Lpc_cleanup
    lwu t1, PC_STAT_LINKS(t0)
    li t2, 1
    bne t1, t2, .Lpc_cleanup
    lwu t1, PC_STAT_UID(t0)
    beqz t1, .Lpc_source_owner_ok
    bne t1, s0, .Lpc_cleanup
.Lpc_source_owner_ok:
    lwu t1, PC_STAT_GID(t0)
    bne t1, s1, .Lpc_cleanup
    ld t1, PC_STAT_SIZE(t0)
    blez t1, .Lpc_cleanup
    li t2, PC_CONTENT_LIMIT
    bgtu t1, t2, .Lpc_cleanup
    mv a0, s4
    pc_address a1, PC_SOURCE
    li a2, PC_READ_CAPACITY
    call .Lpc_read
    blez a0, .Lpc_cleanup
    li t0, PC_CONTENT_LIMIT
    bgtu a0, t0, .Lpc_cleanup
    mv s8, a0
    pc_address t0, PC_SOURCE
    li t1, 0
.Lpc_ascii:
    add t2, t0, t1
    lbu t3, 0(t2)
    li t4, 10
    beq t3, t4, .Lpc_lf
    li t4, 32
    bltu t3, t4, .Lpc_cleanup
    li t4, 126
    bgtu t3, t4, .Lpc_cleanup
    addi t1, t1, 1
    bltu t1, s8, .Lpc_ascii
    j .Lpc_content_ok
.Lpc_lf:
    beqz t1, .Lpc_cleanup
    addi t1, t1, 1
    bne t1, s8, .Lpc_cleanup
.Lpc_content_ok:
    mv a0, s3
    la a1, .Lpc_private
    li a2, 0700
    li a7, PC_SYS_MKDIRAT
    call .Lpc_syscall
    pc_address t0, PC_NEW_PRIVATE
    sd zero, 0(t0)
    beqz a0, .Lpc_new_private
    li t1, -17               /* EEXIST: inspect, never replace. */
    bne a0, t1, .Lpc_cleanup
    j .Lpc_open_private
.Lpc_new_private:
    li t1, 1
    sd t1, 0(t0)
.Lpc_open_private:
    mv a0, s3
    la a1, .Lpc_private
    li a2, PC_ROOT_FLAGS
    li a3, 0
    li a7, PC_SYS_OPENAT
    call .Lpc_syscall
    bltz a0, .Lpc_cleanup
    mv s5, a0
    pc_address t0, PC_NEW_PRIVATE
    ld t1, 0(t0)
    beqz t1, .Lpc_private_stat
    li a1, 0700              /* Clear inherited SGID and restrictive umask. */
    li a7, PC_SYS_FCHMOD
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
.Lpc_private_stat:
    mv a0, s5
    pc_address a1, PC_STAT
    li a7, PC_SYS_FSTAT
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
    pc_address t0, PC_STAT
    lwu t1, PC_STAT_MODE(t0)
    li t2, 0177777
    and t1, t1, t2
    li t2, 040700
    bne t1, t2, .Lpc_cleanup
    lwu t1, PC_STAT_UID(t0)
    bne t1, s0, .Lpc_cleanup

.Lpc_existing_open:
    mv a0, s5
    la a1, .Lpc_key
    li a2, PC_EXISTING_FLAGS
    li a3, 0
    li a7, PC_SYS_OPENAT
    call .Lpc_syscall
    bgez a0, .Lpc_existing_found
    li t0, -2                /* ENOENT is the only creation path. */
    bne a0, t0, .Lpc_cleanup
    bnez s9, .Lpc_cleanup     /* A raced-away final target is a bounded refusal. */
    j .Lpc_create_temp
.Lpc_existing_found:
    mv s7, a0
    pc_address a1, PC_STAT
    li a7, PC_SYS_FSTAT
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
    pc_address a0, PC_STAT
    mv a1, s0
    mv a2, s1
    mv a3, s8
    call .Lpc_output_metadata
    bnez a0, .Lpc_cleanup
    mv a0, s7
    pc_address a1, PC_EXISTING
    li a2, PC_READ_CAPACITY
    call .Lpc_read
    bne a0, s8, .Lpc_cleanup
    pc_address t0, PC_SOURCE
    pc_address t1, PC_EXISTING
    li t2, 0
.Lpc_compare:
    add t3, t0, t2
    lbu t4, 0(t3)
    add t3, t1, t2
    lbu t5, 0(t3)
    bne t4, t5, .Lpc_cleanup
    addi t2, t2, 1
    bltu t2, s8, .Lpc_compare
    j .Lpc_success

.Lpc_create_temp:
    pc_address t0, PC_NAME_LEFT
    li t1, PC_NAME_ATTEMPTS
    sd t1, 0(t0)
.Lpc_name_attempt:
    pc_address t0, PC_NAME_LEFT
    ld t1, 0(t0)
    beqz t1, .Lpc_cleanup
    addi t1, t1, -1
    sd t1, 0(t0)
    pc_address t0, PC_RANDOM_DONE
    sd zero, 0(t0)
.Lpc_random_read:
    pc_address t0, PC_RANDOM_DONE
    ld t1, 0(t0)
    pc_address a0, PC_RANDOM
    add a0, a0, t1
    li a1, 16
    sub a1, a1, t1
    li a2, 0
    li a7, PC_SYS_GETRANDOM
    call .Lpc_syscall
    blez a0, .Lpc_cleanup
    pc_address t0, PC_RANDOM_DONE
    ld t1, 0(t0)
    add t1, t1, a0
    sd t1, 0(t0)
    li t2, 16
    bltu t1, t2, .Lpc_random_read
    bne t1, t2, .Lpc_cleanup
    pc_address t0, PC_NAME
    la t1, .Lpc_prefix
    li t2, 0
.Lpc_copy_prefix:
    add t3, t1, t2
    lbu t4, 0(t3)
    add t3, t0, t2
    sb t4, 0(t3)
    addi t2, t2, 1
    li t3, 12
    bltu t2, t3, .Lpc_copy_prefix
    addi t0, t0, 12
    pc_address t1, PC_RANDOM
    la t2, .Lpc_hex
    li t3, 0
.Lpc_hex_byte:
    add t4, t1, t3
    lbu t4, 0(t4)
    srli t5, t4, 4
    add t5, t2, t5
    lbu t5, 0(t5)
    sb t5, 0(t0)
    andi t4, t4, 15
    add t4, t2, t4
    lbu t4, 0(t4)
    sb t4, 1(t0)
    addi t0, t0, 2
    addi t3, t3, 1
    li t4, 16
    bltu t3, t4, .Lpc_hex_byte
    sb zero, 0(t0)
    mv a0, s5
    pc_address a1, PC_NAME
    li a2, PC_TEMP_FLAGS
    li a3, 0600
    li a7, PC_SYS_OPENAT
    call .Lpc_syscall
    bgez a0, .Lpc_temp_created
    li t0, -17
    beq a0, t0, .Lpc_name_attempt
    j .Lpc_cleanup
.Lpc_temp_created:
    mv s6, a0
    li s9, 1
    li a1, 0600
    li a7, PC_SYS_FCHMOD
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
    mv a0, s6
    pc_address a1, PC_SOURCE
    mv a2, s8
    call .Lpc_write
    bnez a0, .Lpc_cleanup
    mv a0, s6
    li a7, PC_SYS_FSYNC
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
    mv a0, s6
    pc_address a1, PC_STAT
    li a7, PC_SYS_FSTAT
    call .Lpc_syscall
    bnez a0, .Lpc_cleanup
    pc_address a0, PC_STAT
    mv a1, s0
    mv a2, s1
    mv a3, s8
    call .Lpc_output_metadata
    bnez a0, .Lpc_cleanup
    mv a0, s5
    pc_address a1, PC_NAME
    mv a2, s5
    la a3, .Lpc_key
    li a4, PC_RENAME_NOREPLACE
    li a7, PC_SYS_RENAMEAT2
    call .Lpc_syscall
    beqz a0, .Lpc_published
    li t0, -17
    beq a0, t0, .Lpc_existing_open
    j .Lpc_cleanup
.Lpc_published:
    li s9, 0                  /* The temporary name no longer exists. */
.Lpc_success:
    pc_address t0, PC_RESULT
    sd zero, 0(t0)
.Lpc_cleanup:
    beqz s9, .Lpc_close_existing
    mv a0, s5
    pc_address a1, PC_NAME
    li a2, 0
    li a7, PC_SYS_UNLINKAT
    call .Lpc_syscall
    /* A cleanup error cannot turn a refusal into success. */
    beqz a0, .Lpc_close_existing
    pc_address t0, PC_RESULT
    li t1, 78
    sd t1, 0(t0)
.Lpc_close_existing:
    bltz s7, .Lpc_close_temp
    mv a0, s7
    li a7, PC_SYS_CLOSE
    ecall
.Lpc_close_temp:
    bltz s6, .Lpc_close_private
    mv a0, s6
    li a7, PC_SYS_CLOSE
    ecall
.Lpc_close_private:
    bltz s5, .Lpc_close_source
    mv a0, s5
    li a7, PC_SYS_CLOSE
    ecall
.Lpc_close_source:
    bltz s4, .Lpc_close_dest
    mv a0, s4
    li a7, PC_SYS_CLOSE
    ecall
.Lpc_close_dest:
    bltz s3, .Lpc_close_root
    mv a0, s3
    li a7, PC_SYS_CLOSE
    ecall
.Lpc_close_root:
    bltz s2, .Lpc_return
    mv a0, s2
    li a7, PC_SYS_CLOSE
    ecall
.Lpc_return:
    pc_address t0, PC_RESULT
    ld a0, 0(t0)
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    ld s5, 48(sp)
    ld s6, 56(sp)
    ld s7, 64(sp)
    ld s8, 72(sp)
    ld s9, 80(sp)
    ld s10, 88(sp)
    ld s11, 96(sp)
    li t0, PC_FRAME
    add sp, sp, t0
    ret
.size prepare_config,.-prepare_config

.type .Lpc_path,@function
/* a0=borrowed path. a0=1/0. Reads <=1025 bytes, no calls/stack/callee changes.
 * Absolute <=1024; only literal / can end in slash. Final . and .. are refused. */
.Lpc_path:
    beqz a0, .Lpc_path_bad
    lbu t0, 0(a0)
    li t1, '/'
    bne t0, t1, .Lpc_path_bad
    li t0, 0
    li t1, PC_PATH_LIMIT
.Lpc_path_length:
    bgtu t0, t1, .Lpc_path_bad
    add t2, a0, t0
    lbu t3, 0(t2)
    beqz t3, .Lpc_path_end
    addi t0, t0, 1
    j .Lpc_path_length
.Lpc_path_end:
    li t1, 1
    beq t0, t1, .Lpc_path_ok
    addi t2, t2, -1
    lbu t3, 0(t2)
    li t4, '/'
    beq t3, t4, .Lpc_path_bad
    li t4, '.'
    bne t3, t4, .Lpc_path_ok
    lbu t3, -1(t2)
    li t4, '/'
    beq t3, t4, .Lpc_path_bad
    li t4, '.'
    bne t3, t4, .Lpc_path_ok
    li t1, 3
    bltu t0, t1, .Lpc_path_ok
    lbu t3, -2(t2)
    li t4, '/'
    beq t3, t4, .Lpc_path_bad
.Lpc_path_ok:
    li a0, 1
    ret
.Lpc_path_bad:
    li a0, 0
    ret
.size .Lpc_path,.-.Lpc_path

.type .Lpc_syscall,@function
/* Raw a7 syscall/a0-a5 arguments -> signed a0 result. Preserves callee-saved.
 * Frame64 owns argument copies for at most16 EINTR retries; no other calls.
 * Linux ecalls preserve t-registers; a0 is reloaded before each retry. */
.Lpc_syscall:
    addi sp, sp, -64
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    sd a7, 48(sp)
    li t0, PC_EINTR_RETRIES
.Lpc_syscall_retry:
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    ld a7, 48(sp)
    ecall
    li t1, -4
    bne a0, t1, .Lpc_syscall_done
    beqz t0, .Lpc_syscall_done
    addi t0, t0, -1
    j .Lpc_syscall_retry
.Lpc_syscall_done:
    addi sp, sp, 64
    ret
.size .Lpc_syscall,.-.Lpc_syscall

.type .Lpc_root,@function
/* a0=dirfd, a1=is source, a2=current UID, a3=GID; a4=stat[160], a5=statfs[128].
 * a0=0/78. Frame64 saves arguments/ra; caller-owned buffers receive metadata.
 * Changes caller-saved only. Input group write additionally requires ST_RDONLY. */
.Lpc_root:
    addi sp, sp, -64
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    sd ra, 48(sp)
    mv a1, a4
    li a7, PC_SYS_FSTAT
    call .Lpc_syscall
    bnez a0, .Lpc_root_bad
    ld t0, 32(sp)
    lwu t1, PC_STAT_MODE(t0)
    li t2, 0170000
    and t2, t1, t2
    li t3, 040000
    bne t2, t3, .Lpc_root_bad
    andi t2, t1, 2
    bnez t2, .Lpc_root_bad
    lwu t2, PC_STAT_UID(t0)
    beqz t2, .Lpc_root_owner_ok
    ld t3, 16(sp)
    bne t2, t3, .Lpc_root_bad
.Lpc_root_owner_ok:
    lwu t2, PC_STAT_GID(t0)
    ld t3, 24(sp)
    bne t2, t3, .Lpc_root_bad
    ld t2, 8(sp)
    beqz t2, .Lpc_root_ok
    andi t1, t1, 020
    beqz t1, .Lpc_root_ok
    ld a0, 0(sp)
    ld a1, 40(sp)
    li a7, PC_SYS_FSTATFS
    call .Lpc_syscall
    bnez a0, .Lpc_root_bad
    ld t0, 40(sp)
    ld t1, PC_STATFS_FLAGS(t0)
    andi t1, t1, 1
    beqz t1, .Lpc_root_bad
.Lpc_root_ok:
    li a0, 0
    j .Lpc_root_return
.Lpc_root_bad:
    li a0, 78
.Lpc_root_return:
    ld ra, 48(sp)
    addi sp, sp, 64
    ret
.size .Lpc_root,.-.Lpc_root

.type .Lpc_read,@function
/* a0=fd, a1=owned buffer, a2=capacity (4097). Returns bytes read or -1.
 * Frame48 saves s0-s3/ra; short reads advance within the supplied capacity.
 * EOF is required unless capacity is filled; callers reject the filled bound. */
.Lpc_read:
    addi sp, sp, -48
    sd s0, 0(sp)
    sd s1, 8(sp)
    sd s2, 16(sp)
    sd s3, 24(sp)
    sd ra, 32(sp)
    mv s0, a0
    mv s1, a1
    mv s2, a2
    li s3, 0
.Lpc_read_more:
    mv a0, s0
    add a1, s1, s3
    sub a2, s2, s3
    li a7, PC_SYS_READ
    call .Lpc_syscall
    bltz a0, .Lpc_read_bad
    beqz a0, .Lpc_read_done
    add s3, s3, a0
    bltu s3, s2, .Lpc_read_more
    bne s3, s2, .Lpc_read_bad
.Lpc_read_done:
    mv a0, s3
    j .Lpc_read_return
.Lpc_read_bad:
    li a0, -1
.Lpc_read_return:
    ld s0, 0(sp)
    ld s1, 8(sp)
    ld s2, 16(sp)
    ld s3, 24(sp)
    ld ra, 32(sp)
    addi sp, sp, 48
    ret
.size .Lpc_read,.-.Lpc_read

.type .Lpc_write,@function
/* a0=fd, a1=borrowed bytes, a2=length<=4096. Returns0/-1. No ownership transfer.
 * Frame48 preserves s0-s3/ra; short writes progress, zero/error refuses. */
.Lpc_write:
    addi sp, sp, -48
    sd s0, 0(sp)
    sd s1, 8(sp)
    sd s2, 16(sp)
    sd s3, 24(sp)
    sd ra, 32(sp)
    mv s0, a0
    mv s1, a1
    mv s2, a2
    li s3, 0
.Lpc_write_more:
    mv a0, s0
    add a1, s1, s3
    sub a2, s2, s3
    li a7, PC_SYS_WRITE
    call .Lpc_syscall
    blez a0, .Lpc_write_bad
    add s3, s3, a0
    bltu s3, s2, .Lpc_write_more
    bne s3, s2, .Lpc_write_bad
    li a0, 0
    j .Lpc_write_return
.Lpc_write_bad:
    li a0, -1
.Lpc_write_return:
    ld s0, 0(sp)
    ld s1, 8(sp)
    ld s2, 16(sp)
    ld s3, 24(sp)
    ld ra, 32(sp)
    addi sp, sp, 48
    ret
.size .Lpc_write,.-.Lpc_write

.type .Lpc_output_metadata,@function
/* a0=stat[160], a1=current UID, a2=selected GID, a3=expected length<=4096.
 * Returns0/78. Leaf, no stack, caller-saved only. Reads only asserted fields. */
.Lpc_output_metadata:
    lwu t0, PC_STAT_MODE(a0)
    li t1, 0177777
    and t0, t0, t1
    li t1, 0100600
    bne t0, t1, .Lpc_output_bad
    lwu t0, PC_STAT_LINKS(a0)
    li t1, 1
    bne t0, t1, .Lpc_output_bad
    lwu t0, PC_STAT_UID(a0)
    bne t0, a1, .Lpc_output_bad
    lwu t0, PC_STAT_GID(a0)
    bne t0, a2, .Lpc_output_bad
    ld t0, PC_STAT_SIZE(a0)
    bne t0, a3, .Lpc_output_bad
    li a0, 0
    ret
.Lpc_output_bad:
    li a0, 78
    ret
.size .Lpc_output_metadata,.-.Lpc_output_metadata
.section .note.GNU-stack,"",@progbits
