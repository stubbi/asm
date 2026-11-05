/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux little-endian RV64GC, LP64D. Native assembly; no application backend.
 * Calls follow the RISC-V psABI: a0-a7 arguments, a0 result, SP aligned to 16.
 * s0-s11, gp and tp are preserved. Per-routine frames save each used s-register
 * and ra. t0 holds an intermediate result; t1-t4 and t5-t6 are caller-saved
 * arithmetic/comparison temporaries. Byte comparisons do not read past bounds.
 * HTTP framing belongs to libmicrohttpd; database protocol/TLS belong to libpq.
 */

.equ RV_SYS_READ, 63
.equ RV_SYS_WRITE, 64
.equ RV_SYS_OPENAT, 56
.equ RV_SYS_CLOSE, 57
.equ RV_SYS_FSTAT, 80
.equ RV_SYS_GETUID, 174
.equ RV_AT_FDCWD, -100
.equ RV_CONFIG_OPEN_FLAGS, 0xa0800
.equ RV_STAT_MODE, 16
.equ RV_STAT_UID, 24

.option pic
.option norelax
.attribute arch, "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"
.equ DB_DEADLINE_MS, 2000
.equ MAX_REPLY, 16384
.equ CONFIG_LIMIT, 4096

.section .rodata
usage: .asciz "Usage: asm-hub serve\nSet ASM_BIND and ASM_DATABASE_URL_FILE before starting the runtime.\n"
serve_command: .asciz "serve"
env_bind: .asciz "ASM_BIND"
env_database: .asciz "ASM_DATABASE_URL_FILE"
config_error: .asciz "asm-hub: invalid configuration. Check ASM_BIND and the private TLS connection file against server/README.md.\n"
db_error: .asciz "asm-hub: the database role, schema, or catalog is not ready.\n"
listen_error: .asciz "asm-hub: the HTTP listener could not start.\n"
started: .asciz "asm-hub: listening; health and source identity only.\n"
get_method: .asciz "GET"
path_live: .asciz "/health/live"
path_ready: .asciz "/health/ready"
path_status: .asciz "/api/v2/status"
empty: .asciz ""
header_te: .asciz "Transfer-Encoding"
header_cl: .asciz "Content-Length"
header_type: .asciz "Content-Type"
header_cache: .asciz "Cache-Control"
header_nosniff: .asciz "X-Content-Type-Options"
header_connection: .asciz "Connection"
type_json: .asciz "application/json; charset=utf-8"
cache_no_store: .asciz "no-store"
nosniff: .asciz "nosniff"
close_value: .asciz "close"
live_body: .asciz "{\"status\":\"alive\"}\n"
ready_body: .asciz "{\"status\":\"ready\"}\n"
status_body:
.ascii "{\"service\":\"asm-hub\",\"application_language\":\"assembly\",\"source_revision\":\""
.ascii ASM_SOURCE_REVISION
.ascii "\",\"source_url\":\"https://github.com/stubbi/asm/tree/"
.ascii ASM_SOURCE_REVISION
.asciz "\"}\n"
bad_query_body: .asciz "{\"error\":{\"code\":\"invalid_query\",\"message\":\"This endpoint accepts no query fields.\"}}\n"
bad_body: .asciz "{\"error\":{\"code\":\"body_not_supported\",\"message\":\"Read requests cannot contain a body.\"}}\n"
bad_method_body: .asciz "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"This endpoint accepts GET requests only.\"}}\n"
not_found_body: .asciz "{\"error\":{\"code\":\"not_found\",\"message\":\"The route does not exist.\"}}\n"
unavailable_body: .asciz "{\"error\":{\"code\":\"temporarily_unavailable\",\"message\":\"The database request could not finish. Try again shortly.\"}}\n"
uri_body: .asciz "{\"error\":{\"code\":\"uri_too_long\",\"message\":\"The request URL exceeds 2048 bytes.\"}}\n"
headers_body: .asciz "{\"error\":{\"code\":\"headers_too_large\",\"message\":\"The headers exceed the service limit.\"}}\n"
db_key_dbname: .asciz "dbname"
db_key_gss: .asciz "gssencmode"
db_key_passfile: .asciz "passfile"
disabled: .asciz "disable"
null_file: .asciz "/dev/null"
db_key_timeout: .asciz "connect_timeout"
db_key_options: .asciz "options"
db_key_application: .asciz "application_name"
timeout_value: .asciz "2"
db_options: .asciz "-c default_transaction_read_only=on -c statement_timeout=1000 -c lock_timeout=200 -c search_path=pg_catalog,public"
application_name: .asciz "asm-hub"
guard_sql:
.incbin "guard.sql"
.byte 0
.section .data.rel.ro,"aw"
.balign 8
db_keys: .quad db_key_dbname, db_key_timeout, db_key_options, db_key_application, db_key_gss, db_key_passfile, 0
db_values: .quad db_config, timeout_value, db_options, application_name, disabled, null_file, 0

mhd_options:
    .quad 1, 32768, 0
    .quad 2, 16, 0
    .quad 3, 2, 0
    .quad 19, 262144, 0
    .quad 29, 1, 0
    .quad 40, 16, listen_address
    .quad 7, uri_bound, 0
    .quad 0, 0, 0

.section .data
.balign 8
listen_address:
    .short 2, 0
    .byte 127, 0, 0, 1
    .quad 0
sleep_interval: .quad 0, 100000000

.section .bss
.balign 8
.globl db_config
db_config: .zero CONFIG_LIMIT + 2
.balign 4
stop_requested: .zero 4

.section .text
.globl main
.type main,@function

main:
    /* a0=argc; a1=argv. Returns a0=process status. Owns the daemon and
     * immutable db_config[4098]. Rejects configuration/database failure before
     * starting the listener. SIGTERM/SIGINT request bounded shutdown.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 96 bytes; saves s1, ra. */
    addi sp, sp, -96
    sd s1, 72(sp)
    sd ra, 80(sp)
    mv t3, a0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 2
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lusage
    mv t4, a1
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    mv a0, t3
    la t3, serve_command
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
    bne t5,t6, .Lusage
    call clear_pg_environment
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
    beq t5,t6, .Lconfig_fail
    la t3, env_bind
    mv a0, t3
    call getenv
    mv t0, a0
    mv t3, t0
    mv a0, t3
    la t3, listen_address
    mv a1, t3
    call parse_bind
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
    beq t5,t6, .Lconfig_fail
    la t3, env_database
    mv a0, t3
    call getenv
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lconfig_fail
    mv t3, t0
    mv a0, t3
    call read_config
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
    beq t5,t6, .Lconfig_fail
    call validate_database_config
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
    beq t5,t6, .Lconfig_fail

    la t3, refuse_key_password
    mv a0, t3
    call PQsetSSLKeyPassHook_OpenSSL
    mv t0, a0
    li t3, 13
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call signal
    mv t0, a0
    mv t3, t0
    li t1, -1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_fail
    li t3, 15
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    la t3, request_stop
    mv a1, t3
    call signal
    mv t0, a0
    mv t3, t0
    li t1, -1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_fail
    li t3, 2
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    la t3, request_stop
    mv a1, t3
    call signal
    mv t0, a0
    mv t3, t0
    li t1, -1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_fail
    call database_ready
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
    beq t5,t6, .Ldatabase_fail

    li t3, 1036
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t5, t3
    li t6, 0
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
    la t3, handle_request
    mv a4, t3
    mv t3, a5
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a5
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a5, t3
    slli a5, a5, 32
    srli a5, a5, 32
    mv t5, t3
    li t6, 0
    li t3, 15
    mv t4, sp
    sd t3, 0(t4)
    la t3, mhd_options
    mv t0, t3
    mv t3, t0
    mv t4, sp
    li t2, 8
    add t4, t4, t2
    sd t3, 0(t4)
    li t3, 0
    mv t4, sp
    li t2, 16
    add t4, t4, t2
    sd t3, 0(t4)
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
    ld a6, 0(sp)
    ld a7, 8(sp)
    sd zero, 0(sp)  # ninth variadic argument: MHD_OPTION_END
    call MHD_start_daemon
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Llisten_fail
    mv t3, t0
    mv s1, t3
    la t3, started
    mv a0, t3
    call message
    mv t0, a0
.Lserve:
    la t4, stop_requested
    lwu t3, 0(t4)
    fence r, rw
    li t1, 0
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lstop
    la t3, sleep_interval
    mv a0, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t5, t3
    li t6, 0
    call nanosleep
    mv t0, a0
    j .Lserve
.Lstop:
    mv t3, s1
    mv a0, t3
    call MHD_quiesce_daemon
    mv t0, a0

    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    addi t4, sp, 80 - 16
    sw t3, 0(t4)
    mv t3, s1
    mv a0, t3
    call MHD_stop_daemon
    mv t0, a0
    addi t4, sp, 80 - 16
    lwu t3, 0(t4)
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    mv t3, a0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 0xffffffff  # compare the low32 socket value against -1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Ldaemon_stopped
    call close
    mv t0, a0
.Ldaemon_stopped:
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
    j .Lmain_done
.Lusage:
    la t3, usage
    mv a0, t3
    call message
    mv t0, a0
    li t3, 64
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lmain_done
.Lconfig_fail:
    la t3, config_error
    mv a0, t3
    call message
    mv t0, a0
    li t3, 78
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lmain_done
.Ldatabase_fail:
    la t3, db_error
    mv a0, t3
    call message
    mv t0, a0
    li t3, 78
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lmain_done
.Llisten_fail:
    la t3, listen_error
    mv a0, t3
    call message
    mv t0, a0
    li t3, 71
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
.Lmain_done:
    mv a0, t0
    ld s1, 72(sp)
    ld ra, 80(sp)
    addi sp, sp, 96
    ret
.size main,.-main


request_stop:
    /* a0=signal (ignored). Aligned atomic flag; release ordering. No calls.
     * Output ignored. Changes t0/t1; preserves every callee-saved register. */
    la t1, stop_requested
    li t0, 1
    fence rw, w
    sw t0, 0(t1)
    ret

refuse_key_password:
    /* a0=borrowed key buffer; a1=signed capacity; a2=connection.
     * Returns a0=0 to refuse prompting. Writes one NUL only when capacity >0.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    slli t5, t5, 32
    srai t5, t5, 32
    slli t6, t6, 32
    srai t6, t6, 32
    bge t6,t5, .Lkey_refused
    li t3, 0
    mv t4, a0
    sb t3, 0(t4)
.Lkey_refused:
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


message:
    /* a0=fixed NUL-terminated message. Writes stderr with short-write
     * and EINTR handling. No untrusted text or ownership transfer; output ignored.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 32 bytes; saves s1, s2, s3, ra. */
    addi sp, sp, -32
    sd s1, 0(sp)
    sd s2, 8(sp)
    sd s3, 16(sp)
    sd ra, 24(sp)
    mv t3, a0
    mv s2, t3
    call strlen
    mv t0, a0
    mv t3, t0
    mv s3, t3
.Lmessage_write:
    mv t3, s3
    mv t1, s3
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lmessage_done
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    li t3, 2
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    mv t3, s2
    mv a1, t3
    mv t3, s3
    mv a2, t3
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    li a7, RV_SYS_WRITE
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
    mv t3, t0
    li t1, -4
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lmessage_write
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bge t6,t5, .Lmessage_done
    mv t3, s2
    mv t1, t0
    add t3, t3, t1
    mv s2, t3
    mv t5, t3
    li t6, 0
    mv t3, s3
    mv t1, t0
    sub t3, t3, t1
    mv s3, t3
    mv t5, t3
    li t6, 0
    j .Lmessage_write
.Lmessage_done:
    mv a0, t0
    ld s1, 0(sp)
    ld s2, 8(sp)
    ld s3, 16(sp)
    ld ra, 24(sp)
    addi sp, sp, 32
    ret


read_config:
    /* a0=trusted operator path. Returns a0=1/0. Owns a descriptor
     * until close; opens with NOFOLLOW|CLOEXEC|NONBLOCK via openat(AT_FDCWD).
     * Uses RV64 stat: mode16/uid24. Requires a private regular file owned by
     * UID or root; reads <=4097 bytes to prove EOF within the 4096-byte bound.
     * Accepts one final LF and printable ASCII only. Initializes db_config[4098]
     * before threads. Syscalls retain borrowed arguments and retry EINTR.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 176 bytes; saves s1, s2. */
    addi sp, sp, -176
    sd s1, 160(sp)
    sd s2, 168(sp)
.Lconfig_open:
    li t3, 2
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    li t3, RV_CONFIG_OPEN_FLAGS
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
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
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    mv a3, a2
    mv a2, a1
    mv a1, a0
    li a0, RV_AT_FDCWD  # AT_FDCWD: openat rejects the final symlink
    li a7, RV_SYS_OPENAT
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
    mv t3, t0
    li t1, -4
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_open
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Lconfig_bad
    mv t3, t0
    mv s1, t3
.Lconfig_stat:
    li t3, 5
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, s1
    mv a0, t3
    mv t3, sp
    mv a1, t3
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    li a7, RV_SYS_FSTAT
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
    mv t3, t0
    li t1, -4
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_stat
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Lconfig_close_bad
    mv t4, sp
    li t2, RV_STAT_MODE
    add t4, t4, t2
    lwu t3, 0(t4)
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv a3, t3
    slli a3, a3, 32
    srli a3, a3, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 61440
    and t3, t3, t1
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
    li t1, 32768
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lconfig_close_bad
    mv t3, a3
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 63
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lconfig_close_bad
    li t3, 102
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    li a7, RV_SYS_GETUID
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
    mv t4, sp
    li t2, RV_STAT_UID
    add t4, t4, t2
    lwu t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_read_start
    mv t4, sp
    li t2, RV_STAT_UID
    add t4, t4, t2
    lwu t3, 0(t4)
    mv t1, t0
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lconfig_close_bad
.Lconfig_read_start:
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
.Lconfig_read:
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
    mv t3, s1
    mv a0, t3
    la t3, db_config
    mv a1, t3
    mv t3, a1
    mv t1, s2
    add t3, t3, t1
    mv a1, t3
    mv t5, t3
    li t6, 0
    li t3, CONFIG_LIMIT + 1
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    mv t3, a2
    mv t1, s2
    sub t3, t3, t1
    mv a2, t3
    mv t5, t3
    li t6, 0
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    li a7, RV_SYS_READ
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
    mv t3, t0
    li t1, -4
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lconfig_read
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Lconfig_close_bad
    beq t5,t6, .Lconfig_eof
    mv t3, s2
    mv t1, t0
    add t3, t3, t1
    mv s2, t3
    mv t5, t3
    li t6, 0
    mv t3, s2
    li t1, CONFIG_LIMIT
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lconfig_close_bad
    j .Lconfig_read
.Lconfig_eof:
    li t3, 3
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, s1
    mv a0, t3
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    li a7, RV_SYS_CLOSE
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
    mv t3, s2
    mv t1, s2
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lconfig_bad
    la t3, db_config
    mv a2, t3
    mv t4, a2
    add t4, t4, s2
    addi t4, t4, -1
    lbu t3, 0(t4)
    li t1, 10
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lconfig_scan
    mv t3, s2
    li t1, 1
    sub t3, t3, t1
    mv s2, t3
    mv t5, t3
    li t6, 0
.Lconfig_scan:
    mv t3, s2
    mv t1, s2
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lconfig_bad
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
.Lconfig_chars:
    mv t4, a2
    add t4, t4, a3
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
    bltu t5,t6, .Lconfig_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 126
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lconfig_bad
    mv t3, a3
    li t1, 1
    add t3, t3, t1
    mv a3, t3
    mv t5, t3
    li t6, 0
    mv t3, a3
    mv t1, s2
    mv t5, t3
    mv t6, t1
    bltu t5,t6, .Lconfig_chars
    li t3, 0
    mv t4, a2
    add t4, t4, s2
    sb t3, 0(t4)
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lconfig_return
.Lconfig_close_bad:
    li t3, 3
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, s1
    mv a0, t3
    addi sp, sp, -48
    sd a0, 0(sp)
    sd a1, 8(sp)
    sd a2, 16(sp)
    sd a3, 24(sp)
    sd a4, 32(sp)
    sd a5, 40(sp)
    li a7, RV_SYS_CLOSE
    ecall
    mv t0, a0
    ld a0, 0(sp)
    ld a1, 8(sp)
    ld a2, 16(sp)
    ld a3, 24(sp)
    ld a4, 32(sp)
    ld a5, 40(sp)
    addi sp, sp, 48
.Lconfig_bad:
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
.Lconfig_return:
    mv a0, t0
    ld s1, 160(sp)
    ld s2, 168(sp)
    addi sp, sp, 176
    ret


clock_ms:
    /* No input. Returns a0=monotonic milliseconds, or -1. Owns one
     * 16-byte timespec on the stack; clock_gettime uses CLOCK_MONOTONIC=1.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 32 bytes; saves ra. */
    addi sp, sp, -32
    sd ra, 24(sp)
    li t3, 1
    mv a0, t3
    slli a0, a0, 32
    srli a0, a0, 32
    mv t3, sp
    mv a1, t3
    call clock_gettime
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
    bne t5,t6, .Lclock_bad
    mv t4, sp
    ld t3, 0(t4)
    li t1, 1000
    mul t3, t3, t1
    mv a3, t3
    mv t5, t3
    li t6, 0
    mv t4, sp
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    mv t0, t3
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
    li t3, 1000000
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t3, a1
    remu a2, t0, t3
    divu t0, t0, t3
    mv t3, t0
    mv t1, a3
    add t3, t3, t1
    mv t0, t3
    mv t5, t3
    li t6, 0
    mv a0, t0
    ld ra, 24(sp)
    addi sp, sp, 32
    ret
.Lclock_bad:
    li t3, -1
    mv t0, t3
    mv a0, t0
    ld ra, 24(sp)
    addi sp, sp, 32
    ret


wait_database:
    /* a0=borrowed PGconn; a1=poll events; a2=absolute deadline.
     * Returns a0=1/0. Owns a local pollfd; retries EINTR using remaining time.
     * Rejects poll errors, hangup, invalid descriptor, and expired deadlines.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 48 bytes; saves s1, s2, s3, ra. */
    addi sp, sp, -48
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd ra, 40(sp)
    mv t3, a0
    mv s1, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s2, t3
    slli s2, s2, 32
    srli s2, s2, 32
    mv t3, a2
    mv s3, t3
    call PQsocket
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
    slli t5, t5, 32
    srai t5, t5, 32
    slli t6, t6, 32
    srai t6, t6, 32
    blt t5,zero, .Lwait_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t4, sp
    sw t3, 0(t4)
    mv t3, s2
    slli t3, t3, 48
    srli t3, t3, 48
    mv t4, sp
    li t2, 4
    add t4, t4, t2
    sh t3, 0(t4)
.Lwait_again:
    li t3, 0
    mv t4, sp
    li t2, 6
    add t4, t4, t2
    sh t3, 0(t4)
    call clock_ms
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Lwait_bad
    mv t3, s3
    mv a2, t3
    mv t3, a2
    mv t1, t0
    sub t3, t3, t1
    mv a2, t3
    mv t5, t3
    li t6, 0
    bge t6,t5, .Lwait_bad
    mv t3, sp
    mv a0, t3
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call poll
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
    beq t5,t6, .Lwait_bad
    slli t5, t5, 32
    srai t5, t5, 32
    slli t6, t6, 32
    srai t6, t6, 32
    blt t5,zero, .Lwait_errno
    mv t4, sp
    li t2, 6
    add t4, t4, t2
    lhu t3, 0(t4)
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 56
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lwait_bad
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, s2
    slli t1, t1, 32
    srli t1, t1, 32
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lwait_again
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lwait_return
.Lwait_errno:
    call __errno_location
    mv t0, a0
    mv t4, t0
    lbu t3, 0(t4)
    lbu t2, 1(t4)
    slli t2, t2, 8
    or t3, t3, t2
    lbu t2, 2(t4)
    slli t2, t2, 16
    or t3, t3, t2
    lbu t2, 3(t4)
    slli t2, t2, 24
    or t3, t3, t2
    li t1, 4
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lwait_again
.Lwait_bad:
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
.Lwait_return:
    mv a0, t0
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld ra, 40(sp)
    addi sp, sp, 48
    ret


database_query:
    /* a0=fixed SQL; a1=parameter count; a2=borrowed value pointers.
     * Returns an owned PGresult in a0, or NULL. Caller releases with PQclear.
     * Owns and closes its nonblocking connection on every path. Connect, write,
     * read, and drain share one two-second deadline. Requires exactly one
     * non-NULL field in one row and <=16384 response bytes. libpq owns framing,
     * authentication and TLS. All eight PQsendQueryParams arguments use a0-a7.
     * Requires PQsslInUse=1 after connection before sending SQL.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 112 bytes; saves s1, s2, s3, s4, s5, ra. */
    addi sp, sp, -112
    sd s1, 56(sp)
    sd s2, 64(sp)
    sd s3, 72(sp)
    sd s4, 80(sp)
    sd s5, 88(sp)
    sd ra, 96(sp)
    mv t3, a0
    mv s1, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s2, t3
    slli s2, s2, 32
    srli s2, s2, 32
    mv t3, a2
    mv s3, t3
    li t3, 0
    addi t4, sp, 96 - 48
    sd t3, 0(t4)
    mv t3, s5
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, s5
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s5, t3
    slli s5, s5, 32
    srli s5, s5, 32
    mv t5, t3
    li t6, 0
    call clock_ms
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Ldb_failed
    mv t3, t0
    li t2, DB_DEADLINE_MS
    add t3, t3, t2
    mv s4, t3
    la t3, db_keys
    mv a0, t3
    la t3, db_values
    mv a1, t3
    li t3, 1
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    call PQconnectStartParams
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Ldb_failed
    mv t3, t0
    mv s5, t3
    mv t3, s5
    mv a0, t3
    la t3, ignore_notice
    mv a1, t3
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
    call PQsetNoticeProcessor
    mv t0, a0
.Ldb_connect:
    call clock_ms
    mv t0, a0
    mv t3, t0
    mv t1, s4
    mv t5, t3
    mv t6, t1
    bgeu t5,t6, .Ldb_failed
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Ldb_failed
    mv t3, s5
    mv a0, t3
    call PQconnectPoll
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 3
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Ldb_connected
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Ldb_connect_wait
    li t3, 4
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 2
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
.Ldb_connect_wait:
    mv t3, s5
    mv a0, t3
    mv t3, s4
    mv a2, t3
    call wait_database
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
    beq t5,t6, .Ldb_failed
    j .Ldb_connect
.Ldb_connected:
    mv t3, s5
    mv a0, t3
    call PQsslInUse
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
    mv t3, s5
    mv a0, t3
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call PQsetnonblocking
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
    bne t5,t6, .Ldb_failed
    mv t3, s5
    mv a0, t3
    mv t3, s1
    mv a1, t3
    mv t3, s2
    slli t3, t3, 32
    srli t3, t3, 32
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
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
    mv t3, s3
    mv a4, t3
    mv t3, a5
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a5
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a5, t3
    slli a5, a5, 32
    srli a5, a5, 32
    mv t5, t3
    li t6, 0
    li t3, 0
    mv t4, sp
    sd t3, 0(t4)
    li t3, 0
    mv t4, sp
    li t2, 8
    add t4, t4, t2
    sd t3, 0(t4)
    ld a6, 0(sp)
    ld a7, 8(sp)  # all eight named parameters use argument registers
    call PQsendQueryParams
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
.Ldb_flush:
    mv t3, s5
    mv a0, t3
    call PQflush
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
    beq t5,t6, .Ldb_read
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
    mv t3, s5
    mv a0, t3
    li t3, 4
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t3, s4
    mv a2, t3
    call wait_database
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
    beq t5,t6, .Ldb_failed
    j .Ldb_flush
.Ldb_read:
    call clock_ms
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    blt t5,zero, .Ldb_failed
    mv t3, t0
    mv t1, s4
    mv t5, t3
    mv t6, t1
    bgeu t5,t6, .Ldb_failed
    mv t3, s5
    mv a0, t3
    call PQconsumeInput
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
    mv t3, s5
    mv a0, t3
    call PQisBusy
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
    beq t5,t6, .Ldb_result
    mv t3, s5
    mv a0, t3
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t3, s4
    mv a2, t3
    call wait_database
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
    beq t5,t6, .Ldb_failed
    j .Ldb_read
.Ldb_result:
    mv t3, s5
    mv a0, t3
    call PQgetResult
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Ldb_complete
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_extra_result
    mv t3, t0
    addi t4, sp, 96 - 48
    sd t3, 0(t4)
    mv t3, t0
    mv a0, t3
    call PQresultStatus
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 2
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    mv a0, t3
    call PQntuples
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    mv a0, t3
    call PQnfields
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Ldb_failed
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    mv a0, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t5, t3
    li t6, 0
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
    call PQgetisnull
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
    bne t5,t6, .Ldb_failed
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    mv a0, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t5, t3
    li t6, 0
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
    call PQgetlength
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
    slli t5, t5, 32
    srai t5, t5, 32
    slli t6, t6, 32
    srai t6, t6, 32
    bge t6,t5, .Ldb_failed
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, MAX_REPLY
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Ldb_failed
    j .Ldb_read
.Ldb_extra_result:
    mv t3, t0
    mv a0, t3
    call PQclear
    mv t0, a0
    j .Ldb_failed
.Ldb_complete:
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Ldb_failed
    mv t3, s5
    mv a0, t3
    call PQfinish
    mv t0, a0
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    mv t0, t3
    j .Ldb_return
.Ldb_failed:
    addi t4, sp, 96 - 48
    ld t3, 0(t4)
    mv a0, t3
    mv t3, a0
    mv t1, a0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Ldb_close
    call PQclear
    mv t0, a0
.Ldb_close:
    mv t3, s5
    mv t1, s5
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Ldb_null
    mv t3, s5
    mv a0, t3
    call PQfinish
    mv t0, a0
.Ldb_null:
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
.Ldb_return:
    mv a0, t0
    ld s1, 56(sp)
    ld s2, 64(sp)
    ld s3, 72(sp)
    ld s4, 80(sp)
    ld s5, 88(sp)
    ld ra, 96(sp)
    addi sp, sp, 112
    ret

ignore_notice:
    /* libpq notice callback. All arguments borrowed and ignored.
     * No calls, output, allocation, or memory changes; return value ignored.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    mv a0, t0
    ret


database_ready:
    /* No input. Returns a0=1 only when the fixed guard returns
     * exactly the bytes 1,NUL. Owns and frees its result before returning.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 16 bytes; saves s1, ra. */
    addi sp, sp, -16
    sd s1, 0(sp)
    sd ra, 8(sp)
    la t3, guard_sql
    mv a0, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t5, t3
    li t6, 0
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
    call database_query
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lready_no
    mv t3, t0
    mv s1, t3
    mv t3, t0
    mv a0, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv t1, a1
    slli t1, t1, 32
    srli t1, t1, 32
    xor t3, t3, t1
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t5, t3
    li t6, 0
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
    call PQgetvalue
    mv t0, a0
    mv t4, t0
    lbu t3, 0(t4)
    lbu t2, 1(t4)
    slli t2, t2, 8
    or t3, t3, t2
    li t1, 49
    mv t5, t3
    mv t6, t1
    xor t3, t5, t6
    seqz t3, t3
    li t2, -256
    and t0, t0, t2
    li t2, 255
    and t1, t3, t2
    or t0, t0, t1
    mv t3, t0
    slli t3, t3, 56
    srli t3, t3, 56
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    addi sp, sp, -16
    sd t0, 0(sp)
    mv t3, s1
    mv a0, t3
    call PQclear
    mv t0, a0
    ld t0, 0(sp)
    addi sp, sp, 16
    mv a0, t0
    ld s1, 0(sp)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret
.Lready_no:
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
    ld s1, 0(sp)
    ld ra, 8(sp)
    addi sp, sp, 16
    ret


uri_bound:
    /* MHD raw URI callback: a1=borrowed URI. Returns marker 1 in a0
     * when its bounded length exceeds 2048, otherwise 0. No buffer copies.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 16 bytes; saves ra. */
    addi sp, sp, -16
    sd ra, 0(sp)
    mv t3, a1
    mv a0, t3
    li t3, 2049
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strnlen
    mv t0, a0
    mv t3, t0
    li t1, 2048
    mv t5, t3
    mv t6, t1
    sltu t3, t6, t5
    li t2, -256
    and t0, t0, t2
    li t2, 255
    and t1, t3, t2
    or t0, t0, t1
    mv t3, t0
    slli t3, t3, 56
    srli t3, t3, 56
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv a0, t0
    ld ra, 0(sp)
    addi sp, sp, 16
    ret


header_bound:
    /* MHD iterator: a0=owned {count:u64,bytes:u64,bad:u64};
     * a3=key bytes; a5=value bytes. Returns a0=1/0. Rejects >64 headers or
     * >16384 total bytes. Borrows header strings without reading or logging them.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    mv t4, a0
    ld t3, 0(t4)
    li t1, 1
    add t3, t3, t1
    mv t4, a0
    sd t3, 0(t4)
    mv t5, t3
    li t6, 0
    mv t4, a0
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    mv t1, a3
    add t3, t3, t1
    mv t4, a0
    li t2, 8
    add t4, t4, t2
    sd t3, 0(t4)
    mv t5, t3
    li t6, 0
    mv t4, a0
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    mv t1, a5
    add t3, t3, t1
    mv t4, a0
    li t2, 8
    add t4, t4, t2
    sd t3, 0(t4)
    mv t5, t3
    li t6, 0
    mv t4, a0
    ld t3, 0(t4)
    li t1, 64
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lheader_bad
    mv t4, a0
    li t2, 8
    add t4, t4, t2
    ld t3, 0(t4)
    li t1, 16384
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lheader_bad
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    mv a0, t0
    ret
.Lheader_bad:
    li t3, 1
    mv t4, a0
    li t2, 16
    add t4, t4, t2
    sd t3, 0(t4)
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


query_value:
    /* MHD query iterator: a0=owned request-local bad flag.
     * Sets it to1 and returns a0=0. Every query field is unsupported.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 0 bytes; saves none. */
    li t3, 1
    mv t4, a0
    sd t3, 0(t4)
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


handle_request:
    /* MHD callback: a1=connection; a2=URL; a3=method;
     * a6=upload byte count pointer; a7=request marker pointer. Returns MHD_Result
     * in a0. Borrows all strings for this call only. Request-local header/query
     * state stays in the stack frame. Each database request owns its connection.
     * No body, file path, database error, or query text enters a log.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 160 bytes; saves s1, s2, s3, s4, s5, ra. */
    addi sp, sp, -160
    sd s1, 104(sp)
    sd s2, 112(sp)
    sd s3, 120(sp)
    sd s4, 128(sp)
    sd s5, 136(sp)
    sd ra, 144(sp)
    mv t3, a1
    mv s1, t3
    mv t3, a2
    mv s2, t3
    mv t3, a3
    mv s3, t3
    mv t0, a7  # eighth MHD callback argument: req_cls
    mv t4, t0
    ld t3, 0(t4)
    li t1, 2
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Lhandled
    mv t4, t0
    ld t3, 0(t4)
    li t1, 1
    mv t5, t3
    mv t6, t1
    beq t5,t6, .Luri_error
    li t3, 2
    mv t4, t0
    sd t3, 0(t4)
    mv t3, s3
    mv a0, t3
    la t3, get_method
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
    bne t5,t6, .Lmethod_error
    li t3, 0
    addi t4, sp, 144 - 64
    sd t3, 0(t4)
    li t3, 0
    addi t4, sp, 144 - 56
    sd t3, 0(t4)
    li t3, 0
    addi t4, sp, 144 - 48
    sd t3, 0(t4)
    mv t3, s1
    mv a0, t3
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    la t3, header_bound
    mv a2, t3
    addi t3, sp, 144 - 64
    mv a3, t3
    call MHD_get_connection_values_n
    mv t0, a0
    addi t4, sp, 144 - 48
    ld t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lheaders_error
    mv t3, s1
    mv a0, t3
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    la t3, header_te
    mv a2, t3
    call MHD_lookup_connection_value
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    bne t5,t6, .Lbody_error
    mv t3, s1
    mv a0, t3
    li t3, 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    la t3, header_cl
    mv a2, t3
    call MHD_lookup_connection_value
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lroute
    mv t4, t0
    lbu t3, 0(t4)
    lbu t2, 1(t4)
    slli t2, t2, 8
    or t3, t3, t2
    li t1, 48
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lbody_error
.Lroute:
    li t3, 0
    addi t4, sp, 144 - 72
    sd t3, 0(t4)
    mv t3, s1
    mv a0, t3
    li t3, 8
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    la t3, query_value
    mv a2, t3
    addi t3, sp, 144 - 72
    mv a3, t3
    call MHD_get_connection_values_n
    mv t0, a0
    addi t4, sp, 144 - 72
    ld t3, 0(t4)
    li t1, 0
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lquery_error
    mv t3, s2
    mv a0, t3
    la t3, path_live
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
    beq t5,t6, .Llive
    mv t3, s2
    mv a0, t3
    la t3, path_ready
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
    beq t5,t6, .Lready
    mv t3, s2
    mv a0, t3
    la t3, path_status
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
    beq t5,t6, .Lstatus
    j .Lnot_found
.Llive:
    la t3, live_body
    mv a2, t3
    li t3, 200
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lready:
    la t4, stop_requested
    lwu t3, 0(t4)
    fence r, rw
    li t1, 0
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lunavailable
    call database_ready
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
    beq t5,t6, .Lunavailable
    la t3, ready_body
    mv a2, t3
    li t3, 200
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lstatus:
    la t3, status_body
    mv a2, t3
    li t3, 200
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lnot_found:
    la t3, not_found_body
    mv a2, t3
    li t3, 404
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lmethod_error:
    la t3, bad_method_body
    mv a2, t3
    li t3, 405
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lbody_error:
    la t3, bad_body
    mv a2, t3
    li t3, 400
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lheaders_error:
    la t3, headers_body
    mv a2, t3
    li t3, 431
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lquery_error:
    la t3, bad_query_body
    mv a2, t3
    li t3, 400
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Luri_error:
    li t3, 2
    mv t4, t0
    sd t3, 0(t4)
    la t3, uri_body
    mv a2, t3
    li t3, 414
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    j .Lfixed_response
.Lunavailable:
    la t3, unavailable_body
    mv a2, t3
    li t3, 503
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
.Lfixed_response:
    mv t3, s1
    mv a0, t3
    call queue_json
    mv t0, a0
    j .Lrequest_return
.Lhandled:
    li t3, 1
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
.Lrequest_return:
    mv a0, t0
    ld s1, 104(sp)
    ld s2, 112(sp)
    ld s3, 120(sp)
    ld s4, 128(sp)
    ld s5, 136(sp)
    ld ra, 144(sp)
    addi sp, sp, 160
    ret


queue_json:
    /* a0=borrowed MHD connection; a1=HTTP status; a2=NUL-terminated
     * body <=16384 bytes. Returns MHD_Result in a0. MHD copies the body before
     * return. Owns and destroys its response on every path; no ownership escapes.
     * Changes caller-saved a0-a7/t0-t6; preserves s0-s11/gp/tp. */
    /* LP64D: a0-a7 inputs; a0 result. Frame 64 bytes; saves s1, s2, s3, s4, s5, ra. */
    addi sp, sp, -64
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd ra, 56(sp)
    mv t3, a0
    mv s1, t3
    mv t3, a1
    slli t3, t3, 32
    srli t3, t3, 32
    mv s2, t3
    slli s2, s2, 32
    srli s2, s2, 32
    mv t3, a2
    mv s3, t3
    mv t3, a2
    mv a0, t3
    li t3, MAX_REPLY + 1
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    call strnlen
    mv t0, a0
    mv t3, t0
    li t1, MAX_REPLY
    mv t5, t3
    mv t6, t1
    bltu t6,t5, .Lqueue_no
    mv t3, t0
    mv a0, t3
    mv t3, s3
    mv a1, t3
    li t3, 2
    mv a2, t3
    slli a2, a2, 32
    srli a2, a2, 32
    call MHD_create_response_from_buffer
    mv t0, a0
    mv t3, t0
    mv t1, t0
    mv t5, t3
    mv t6, t1
    and t5, t5, t6
    li t6, 0
    beq t5,t6, .Lqueue_no
    mv t3, t0
    mv s4, t3
    mv t3, s4
    mv a0, t3
    la t3, header_type
    mv a1, t3
    la t3, type_json
    mv a2, t3
    call MHD_add_response_header
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lqueue_destroy_no
    mv t3, s4
    mv a0, t3
    la t3, header_cache
    mv a1, t3
    la t3, cache_no_store
    mv a2, t3
    call MHD_add_response_header
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lqueue_destroy_no
    mv t3, s4
    mv a0, t3
    la t3, header_nosniff
    mv a1, t3
    la t3, nosniff
    mv a2, t3
    call MHD_add_response_header
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lqueue_destroy_no
    mv t3, s4
    mv a0, t3
    la t3, header_connection
    mv a1, t3
    la t3, close_value
    mv a2, t3
    call MHD_add_response_header
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    li t1, 1
    mv t5, t3
    mv t6, t1
    bne t5,t6, .Lqueue_destroy_no
    mv t3, s1
    mv a0, t3
    mv t3, s2
    slli t3, t3, 32
    srli t3, t3, 32
    mv a1, t3
    slli a1, a1, 32
    srli a1, a1, 32
    mv t3, s4
    mv a2, t3
    call MHD_queue_response
    mv t0, a0
    mv t3, t0
    slli t3, t3, 32
    srli t3, t3, 32
    mv s5, t3
    slli s5, s5, 32
    srli s5, s5, 32
    mv t3, s4
    mv a0, t3
    call MHD_destroy_response
    mv t0, a0
    mv t3, s5
    slli t3, t3, 32
    srli t3, t3, 32
    mv t0, t3
    slli t0, t0, 32
    srli t0, t0, 32
    j .Lqueue_return
.Lqueue_destroy_no:
    mv t3, s4
    mv a0, t3
    call MHD_destroy_response
    mv t0, a0
.Lqueue_no:
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
.Lqueue_return:
    mv a0, t0
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    ld s5, 48(sp)
    ld ra, 56(sp)
    addi sp, sp, 64
    ret

.section .note.GNU-stack,"",@progbits
