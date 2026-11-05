/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux little-endian RV64GC, LP64D. Native assembly; no application backend.
 * Calls follow the RISC-V psABI: a0-a7 arguments, a0 result, SP aligned to 16.
 * s0-s11, gp and tp are preserved. Per-routine frames save each used s-register
 * and ra. t0 holds an intermediate result; t1-t4 and t5-t6 are caller-saved
 * arithmetic/comparison temporaries. Byte comparisons do not read past bounds.
 * HTTP framing belongs to libmicrohttpd; database protocol/TLS belong to libpq.
 */

.option pic
.option norelax
.attribute arch, "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"

.section .rodata
uri_prefix: .asciz "postgresql://"
verify_full: .asciz "verify-full"
key_user: .asciz "user"
key_database: .asciz "dbname"
key_host: .asciz "host"
key_address: .asciz "hostaddr"
key_port: .asciz "port"
key_mode: .asciz "sslmode"
key_root: .asciz "sslrootcert"
key_cert: .asciz "sslcert"
key_key: .asciz "sslkey"
query_mode: .asciz "sslmode="
query_root: .asciz "sslrootcert="
query_cert: .asciz "sslcert="
query_key: .asciz "sslkey="
query_address: .asciz "hostaddr="

.section .data.rel.ro,"aw"
.balign 8

allowed:
    .quad key_user, 1, 0
    .quad key_database, 2, 0
    .quad key_host, 4, 1
    .quad key_address, 8, 2
    .quad key_port, 16, 3
    .quad key_mode, 32, 4
    .quad key_root, 64, 5
    .quad key_cert, 128, 5
    .quad key_key, 256, 5
    .quad 0, 0, 0
query_fields:
    .quad query_mode, 8, 1
    .quad query_root, 12, 2
    .quad query_cert, 8, 4
    .quad query_key, 7, 8
    .quad query_address, 9, 16
    .quad 0, 0, 0

.section .text
.globl clear_pg_environment
.type clear_pg_environment,@function

clear_pg_environment:
    /* No input. Returns a0=1/0. Removes every PG-prefixed
     * environment entry before threads. Owns a 272-byte name buffer; rejects
     * names >255 bytes or unsetenv failure. Reloads environ through its GOT
     * address after every removal. Never logs environment values.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 304 bytes; saves s1, s2, ra. */
    addi sp, sp, -304
    sd s1, 272(sp)
    sd s2, 280(sp)
    sd ra, 288(sp)
.Lenv_restart:
    la t3, environ
    mv t0, t3
    mv t4, t0
    ld t3, 0(t4)
    mv s1, t3
.Lenv_next:
    mv t4, s1
    ld t3, 0(t4)
    mv s2, t3
    mv t3, s2
    mv t1, s2
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lenv_ok
    mv t4, s2
    lbu t3, 0(t4)
    li t1, 'P'
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lenv_advance
    mv t4, s2
    li t2, 1
    add t4, t4, t2
    lbu t3, 0(t4)
    li t1, 'G'
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lenv_advance
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a3
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
.Lenv_name:
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 255
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lenv_bad
    mv t4, s2
    add t4, t4, a3
    lbu t3, 0(t4)
    li t2, -256
    and t0, t0, t2
    li t2, 255
    and t1, t3, t2
    or t0, t0, t1
    mv t3, t0
    slli t3, t3, 56
    srli t3, t3, 56
    mv t1, t0
    slli t1, t1, 56
    srli t1, t1, 56
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lenv_bad
    mv t3, t0
    slli t3, t3, 56
    srli t3, t3, 56
    li t1, '='
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lenv_unset
    mv t3, t0
    slli t3, t3, 56
    srli t3, t3, 56
    mv t4, sp
    add t4, t4, a3
    sb t3, 0(t4)
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    add t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
    j .Lenv_name
.Lenv_unset:
    li t3, 0
    mv t4, sp
    add t4, t4, a3
    sb t3, 0(t4)
    mv t3, sp
    mv a0, t3
    call unsetenv
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lenv_bad
    j .Lenv_restart
.Lenv_advance:
    mv t3, s1
    li t1, 8
    add t3, t3, t1
    mv s1, t3
    mv t5, t3
    li t6, 0
    j .Lenv_next
.Lenv_ok:
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lenv_done
.Lenv_bad:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
.Lenv_done:
    mv a0, t0
    ld s1, 272(sp)
    ld s2, 280(sp)
    ld ra, 288(sp)
    addi sp, sp, 304
    ret
.size clear_pg_environment,.-clear_pg_environment

.globl parse_bind
.type parse_bind,@function

parse_bind:
    /* a0=borrowed environment value or NULL; a1=owned sockaddr_in[16].
     * Returns a0=1/0. Copies <=22 bytes into a private stack buffer. Accepts
     * one IPv4 literal and decimal port1024..65535; performs no DNS lookup.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 96 bytes; saves s1, s2, s3, ra. */
    addi sp, sp, -96
    sd s1, 64(sp)
    sd s2, 72(sp)
    sd s3, 80(sp)
    sd ra, 88(sp)
    mv t3, a0
    mv t1, a0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lbind_bad
    mv t3, a0
    mv s1, t3
    mv t3, a1
    mv s2, t3
    li t3, 23
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strnlen
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 22
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lbind_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lbind_bad
    mv t3, t0
    li t2, 1
    add t3, t3, t2
    mv a2, t3
    mv t3, sp
    mv a0, t3
    mv t3, s1
    mv a1, t3
    call memcpy
    mv t0, a0
    mv t3, sp
    mv a0, t3
    li t3, ':'
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strchr
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lbind_bad
    li t3, 0
    mv t4, t0
    sb t3, 0(t4)
    mv t3, t0
    li t2, 1
    add t3, t3, t2
    mv s3, t3
    li t3, 2
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    mv t3, sp
    mv a1, t3
    mv t3, s2
    li t2, 4
    add t3, t3, t2
    mv a2, t3
    call inet_pton
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lbind_bad
    mv t3, s3
    mv a0, t3
    call port_number
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1024
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Lbind_bad
    andi t3, t0, 255
    slli t3, t3, 8
    srli t1, t0, 8
    andi t1, t1, 255
    or t3, t3, t1
    li t2, -65536
    and t0, t0, t2
    or t0, t0, t3
    mv t3, t0
    slli t3, t3, 48
    srli t3, t3, 48
    mv t4, s2
    li t2, 2
    add t4, t4, t2
    sh t3, 0(t4)
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lbind_done
.Lbind_bad:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
.Lbind_done:
    mv a0, t0
    ld s1, 64(sp)
    ld s2, 72(sp)
    ld s3, 80(sp)
    ld ra, 88(sp)
    addi sp, sp, 96
    ret
.size parse_bind,.-parse_bind


port_number:
    /* a0=borrowed NUL-terminated decimal string. Returns a0=1..65535
     * or0. Reads at most six bytes to enforce five digits; rejects leading zero.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    mv t4, a0
    lbu t3, 0(t4)
    li t1, '0'
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lport_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a3
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
.Lport_next:
    mv t4, a0
    add t4, t4, a3
    lbu t3, 0(t4)
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    mv t3, a2
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a2
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lport_return
    mv t3, a2
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '0'
    sub t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    mv t5, t3
    li t6, 0
    mv t3, a2
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 9
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lport_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 10
    mul t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a2
    slli t1, t1, 32
    srli t1, t1, 32
    add t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 65535
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lport_bad
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    add t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 5
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lport_bad
    j .Lport_next
.Lport_bad:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
.Lport_return:
    mv a0, t0
    ret


check_query:
    /* a0=borrowed trusted ASCII URL <=4096 bytes. Returns a0=1/0.
     * Requires each of five raw query keys exactly once before libpq parses
     * values. No connection, copy, logging, or ownership transfer.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 48 bytes; saves s1, s2, s3, s4, ra. */
    addi sp, sp, -48
    sd s1, 8(sp)
    sd s2, 16(sp)
    sd s3, 24(sp)
    sd s4, 32(sp)
    sd ra, 40(sp)
    li t3, '?'
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strchr
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lquery_invalid
    mv t3, t0
    li t2, 1
    add t3, t3, t2
    mv s1, t3
    mv t3, s2
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, s2
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s2, t3
    slli s2, s2, 32
    srli s2, s2, 32
    mv t5, t3
    li t6, 0
.Lquery_field:
    la t3, query_fields
    mv s3, t3
.Lquery_candidate:
    mv t4, s3
    ld t3, 0(t4)
    mv a1, t3
    mv t3, a1
    mv t1, a1
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lquery_invalid
    mv t3, s1
    mv a0, t3
    mv t4, s3
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    mv a2, t3
    call strncmp
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lquery_match
    mv t3, s3
    li t1, 24
    add t3, t3, t1
    mv s3, t3
    mv t5, t3
    li t6, 0
    j .Lquery_candidate
.Lquery_match:
    mv t4, s3
    li t2, 16
    add t4, t4, t2
    ld t3, 0(t4)
    mv s4, t3
    mv t3, s2
    mv t1, s4
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lquery_invalid
    mv t3, s2
    mv t1, s4
    or t3, t3, t1
    mv s2, t3
    mv t5, t3
    li t6, 0
    mv t3, s1
    mv t4, s3
    li t2, 8
    add t4, t4, t2
    ld t1, 0(t4)
    add t3, t3, t1
    mv s1, t3
    mv t5, t3
    li t6, 0
    mv t4, s1
    lbu t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lquery_invalid
    mv t4, s1
    lbu t3, 0(t4)
    li t1, '&'
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lquery_invalid
    mv t3, s1
    mv a0, t3
    li t3, '&'
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strchr
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lquery_end
    mv t3, t0
    li t2, 1
    add t3, t3, t2
    mv s1, t3
    j .Lquery_field
.Lquery_end:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
    mv t3, s2
    li t1, 31
    mv t5, t3
    mv t6, t1
    xor t3, t5, t6
    seqz t3, t3
    li t2, -256
    and t0, t0, t2
    li t2, 255
    and t1, t3, t2
    or t0, t0, t1
    j .Lquery_done
.Lquery_invalid:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
.Lquery_done:
    mv a0, t0
    ld s1, 8(sp)
    ld s2, 16(sp)
    ld s3, 24(sp)
    ld s4, 32(sp)
    ld ra, 40(sp)
    addi sp, sp, 48
    ret

.globl validate_database_config
.type validate_database_config,@function

validate_database_config:
    /* No input. Reads immutable db_config[4098]. Returns a0=1/0.
     * PQconninfoParse owns its option array until PQconninfoFree. Frees errors
     * without logging. Requires explicit user/database/host/IPv4 address/port,
     * verify-full and CA/client certificate/key paths. Rejects passwords and
     * unknown options. PQconninfoOption size56/value24 is a build assertion.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 80 bytes; saves s1, s2, s3, s4, s5, ra. */
    addi sp, sp, -80
    sd s1, 24(sp)
    sd s2, 32(sp)
    sd s3, 40(sp)
    sd s4, 48(sp)
    sd s5, 56(sp)
    sd ra, 64(sp)
    la t3, db_config
    mv a0, t3
    la t3, uri_prefix
    mv a1, t3
    li t3, 13
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    call strncmp
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lpolicy_no_array
    la t3, db_config
    mv a0, t3
    call check_query
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_no_array
    li t3, 0
    mv t4, sp
    sd t3, 0(t4)
    la t3, db_config
    mv a0, t3
    mv t3, sp
    mv a1, t3
    call PQconninfoParse
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_parse_error
    mv t3, t0
    mv s5, t3
    mv t3, t0
    mv s1, t3
    mv t3, s2
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, s2
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s2, t3
    slli s2, s2, 32
    srli s2, s2, 32
    mv t5, t3
    li t6, 0
.Lpolicy_option:
    mv t4, s1
    ld t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lpolicy_finish
    mv t4, s1
    li t2, 24
    add t4, t4, t2
    ld t3, 0(t4)
    mv s3, t3
    mv t3, s3
    mv t1, s3
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_next
    la t3, allowed
    mv s4, t3
.Lpolicy_candidate:
    mv t4, s4
    ld t3, 0(t4)
    mv a1, t3
    mv t3, a1
    mv t1, a1
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_bad
    mv t4, s1
    ld t3, 0(t4)
    mv a0, t3
    call strcmp
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_value
    mv t3, s4
    li t1, 24
    add t3, t3, t1
    mv s4, t3
    mv t5, t3
    li t6, 0
    j .Lpolicy_candidate
.Lpolicy_value:
    mv t4, s4
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    mv t0, t3
    mv t3, s2
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lpolicy_bad
    mv t3, s2
    mv t1, t0
    or t3, t3, t1
    mv s2, t3
    mv t5, t3
    li t6, 0
    mv t4, s4
    li t2, 16
    add t4, t4, t2
    ld t3, 0(t4)
    mv t0, t3
    mv t3, s3
    mv a0, t3
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_identifier
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lpolicy_hostname
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 2
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lpolicy_address
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 3
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lpolicy_port
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 4
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lpolicy_mode

    mv t4, s3
    lbu t3, 0(t4)
    li t1, '/'
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lpolicy_bad
    li t3, 1025
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strnlen
    mv t0, a0
    mv t3, t0
    li t1, 1024
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lpolicy_bad
    mv t3, t0
    mv a3, t3
    mv t3, a2
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a2
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    mv t5, t3
    li t6, 0
.Lpolicy_path_char:
    mv t3, a2
    mv t1, a3
    mv t5, t3
    mv t6, t1
    bgeu t5,t6, .Lpolicy_next
    mv t4, s3
    add t4, t4, a2
    lbu t3, 0(t4)
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 32
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Lpolicy_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 126
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lpolicy_bad
    mv t3, a2
    li t1, 1
    add t3, t3, t1
    mv a2, t3
    mv t5, t3
    li t6, 0
    j .Lpolicy_path_char
.Lpolicy_identifier:
    call identifier
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_bad
    j .Lpolicy_next
.Lpolicy_hostname:
    call hostname
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_bad
    j .Lpolicy_next
.Lpolicy_address:
    mv t3, s3
    mv a1, t3
    li t3, 2
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    mv t3, sp
    li t2, 8
    add t3, t3, t2
    mv a2, t3
    call inet_pton
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lpolicy_bad
    j .Lpolicy_next
.Lpolicy_port:
    call port_number
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_bad
    j .Lpolicy_next
.Lpolicy_mode:
    la t3, verify_full
    mv a1, t3
    call strcmp
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lpolicy_bad
.Lpolicy_next:
    mv t3, s1
    li t1, 56
    add t3, t3, t1
    mv s1, t3
    mv t5, t3
    li t6, 0
    j .Lpolicy_option
.Lpolicy_finish:
    mv t3, s1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, s1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s1, t3
    slli s1, s1, 32
    srli s1, s1, 32
    mv t5, t3
    li t6, 0
    mv t3, s2
    li t1, 511
    mv t5, t3
    mv t6, t1
    xor t3, t5, t6
    seqz t3, t3
    li t2, -256
    and s1, s1, t2
    li t2, 255
    and t1, t3, t2
    or s1, s1, t1
    j .Lpolicy_free
.Lpolicy_bad:
    mv t3, s1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, s1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s1, t3
    slli s1, s1, 32
    srli s1, s1, 32
    mv t5, t3
    li t6, 0
.Lpolicy_free:
    mv t3, s5
    mv a0, t3
    call PQconninfoFree
    mv t0, a0
    mv t3, s1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lpolicy_return
.Lpolicy_parse_error:
    mv t4, sp
    ld t3, 0(t4)
    mv a0, t3
    mv t3, a0
    mv t1, a0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lpolicy_no_array
    call PQfreemem
    mv t0, a0
.Lpolicy_no_array:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
.Lpolicy_return:
    mv a0, t0
    ld s1, 24(sp)
    ld s2, 32(sp)
    ld s3, 40(sp)
    ld s4, 48(sp)
    ld s5, 56(sp)
    ld ra, 64(sp)
    addi sp, sp, 80
    ret
.size validate_database_config,.-validate_database_config


identifier:
    /* a0=borrowed decoded SQL identifier. Returns a0=1/0.
     * Enforces 1..63 ASCII bytes: lower case/underscore first, then digits too.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    mv t4, a0
    lbu t3, 0(t4)
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '_'
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lidentifier_loop_start
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 'a'
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 'z'
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Ltext_bad
.Lidentifier_loop_start:
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a3
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
.Lidentifier_char:
    mv t4, a0
    add t4, t4, a3
    lbu t3, 0(t4)
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Ltext_ok
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 63
    mv t5, t3
    mv t6, t1
    bgeu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '_'
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lidentifier_next
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '0'
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '9'
    mv t5, t3
    mv t6, t1
    bgeu t6,t5, .Lidentifier_next
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 'a'
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 'z'
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Ltext_bad
.Lidentifier_next:
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    add t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
    j .Lidentifier_char


hostname:
    /* a0=borrowed decoded verification hostname. Returns a0=1/0.
     * Enforces 1..253 ASCII letters/digits/dots/hyphens. No DNS or host lists.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a3
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
.Lhostname_char:
    mv t4, a0
    add t4, t4, a3
    lbu t3, 0(t4)
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lhostname_end
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 253
    mv t5, t3
    mv t6, t1
    bgeu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '.'
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lhostname_next
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '-'
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lhostname_next
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '0'
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, '9'
    mv t5, t3
    mv t6, t1
    bgeu t6,t5, .Lhostname_next
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 32
    or t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 'a'
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Ltext_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 'z'
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Ltext_bad
.Lhostname_next:
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    add t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t5, t3
    li t6, 0
    j .Lhostname_char
.Lhostname_end:
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a3
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Ltext_bad
.Ltext_ok:
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv a0, t0
    ret
.Ltext_bad:
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t5, t3
    li t6, 0
    mv a0, t0
    ret

.section .note.GNU-stack,"",@progbits
