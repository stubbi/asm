/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native ARMv8-A, little-endian Linux LP64, AAPCS64.
 * HTTP framing belongs to libmicrohttpd 1.0.3; PostgreSQL/auth/TLS to libpq.
 * Canonical read-only catalog with explicit database TLS policy.
 */

/* All routines use Linux AAPCS64: x0-x7 arguments, x0 result, x19-x29
 * preserved, SP aligned to 16. x16/x17 are reserved for PLT veneers.
 * No SIMD state is changed. Buffers remain owned by the documented caller. */
.arch armv8-a
.macro ADDR reg, symbol
    adrp \reg, \symbol
    add \reg, \reg, :lo12:\symbol
.endm
.equ SYS_OPENAT, 56
.equ SYS_CLOSE, 57
.equ SYS_READ, 63
.equ SYS_WRITE, 64
.equ SYS_FSTAT, 80
.equ SYS_GETUID, 174
.equ PRIVATE_OPEN_FLAGS, 0x88800
.equ STAT_MODE, 16
.equ STAT_UID, 24
.equ DB_DEADLINE_MS, 2000
.equ MAX_REPLY, 16384
.equ MAX_TSV, 1048576
.equ MAX_JSON, 4194304
.equ CONFIG_LIMIT, 4096

.section .rodata
usage: .asciz "Usage: asm-hub serve\nSet ASM_BIND and ASM_DATABASE_URL_FILE before starting the runtime.\n"
serve_command: .asciz "serve"
env_bind: .asciz "ASM_BIND"
env_database: .asciz "ASM_DATABASE_URL_FILE"
config_error: .asciz "asm-hub: invalid configuration. Check ASM_BIND and the private TLS connection file against server/README.md.\n"
db_error: .asciz "asm-hub: the database role, schema, or catalog is not ready.\n"
listen_error: .asciz "asm-hub: the HTTP listener could not start.\n"
started: .asciz "asm-hub: listening.\n"
get_method: .asciz "GET"
path_live: .asciz "/health/live"
path_ready: .asciz "/health/ready"
path_status: .asciz "/api/v2/status"
path_linux: .asciz "/registry/v1/index.tsv"
path_macos: .asciz "/registry/v1/index-macos.tsv"
path_index: .asciz "/registry/v1/index.json"
empty: .asciz ""
header_te: .asciz "Transfer-Encoding"
header_cl: .asciz "Content-Length"
header_type: .asciz "Content-Type"
header_cache: .asciz "Cache-Control"
header_nosniff: .asciz "X-Content-Type-Options"
header_connection: .asciz "Connection"
type_json: .asciz "application/json; charset=utf-8"
type_index: .asciz "application/json"
type_tsv: .asciz "text/tab-separated-values; charset=utf-8"
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
begin_read_only: .asciz "BEGIN READ ONLY"
guard_sql:
.incbin "catalog/reader-guard.sql"
.byte 0
export_sql:
.incbin "catalog/read-exports.sql"
.byte 0
.section .data.rel.ro,"aw"
.balign 8
db_keys: .quad db_key_dbname, db_key_timeout, db_key_options, db_key_application, db_key_gss, db_key_passfile, 0
db_values: .quad db_config, timeout_value, db_options, application_name, disabled, null_file, 0
/* MHD_OptionItem: enum + padding, intptr_t, pointer. The ABI test checks it. */
mhd_options:
    .quad 1, 32768, 0             /* per-connection HTTP memory */
    .quad 2, 16, 0                /* at most 16 connection threads */
    .quad 3, 2, 0                 /* inactivity timeout, seconds */
    .quad 19, 262144, 0           /* thread stack, bytes */
    .quad 29, 1, 0                /* strict client parsing */
    .quad 40, 16, listen_address  /* exact sockaddr length */
    .quad 7, uri_bound, 0         /* raw URI bound before decoding */
    .quad 0, 0, 0

.section .data
.balign 8
listen_address:
    .short 2, 0                  /* AF_INET, network-order port */
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
.type main,%function
/* w0=argc, x1=argv; w0=process status. Owns the daemon after startup.
 * Frame 64 bytes includes the stacked vararg sentinel and saved x19/x20.
 * No listener starts before configuration, library, and database checks. */
main:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]

    cmp w0, #2
    b.ne .Lusage
    ldr x0, [x1, #8]
    ADDR x1, serve_command
    bl strcmp
    cbnz w0, .Lusage
    bl clear_pg_environment
    cbz w0, .Lconfig_fail
    ADDR x0, env_bind
    bl getenv
    ADDR x1, listen_address
    bl parse_bind
    cbz w0, .Lconfig_fail
    ADDR x0, env_database
    bl getenv
    cbz x0, .Lconfig_fail
    bl read_config
    cbz w0, .Lconfig_fail
    bl validate_database_config
    cbz w0, .Lconfig_fail
    ADDR x0, refuse_key_password
    bl PQsetSSLKeyPassHook_OpenSSL

    mov w0, #13
    mov x1, #1
    bl signal
    cmn x0, #1
    b.eq .Lconfig_fail
    mov w0, #15
    ADDR x1, request_stop
    bl signal
    cmn x0, #1
    b.eq .Lconfig_fail
    mov w0, #2
    ADDR x1, request_stop
    bl signal
    cmn x0, #1
    b.eq .Lconfig_fail
    bl database_ready
    cbz w0, .Ldatabase_fail
    mov w0, #1036
    mov w1, #0
    mov x2, #0
    mov x3, #0
    ADDR x4, handle_request
    mov x5, #0
    mov w6, #15                 /* MHD_OPTION_ARRAY: first anonymous argument */
    ADDR x7, mhd_options
    /* Ninth argument is the sentinel. Keep FP/LR above outgoing stack args. */
    sub sp, sp, #16
    str xzr, [sp]
    bl MHD_start_daemon
    add sp, sp, #16
    cbz x0, .Llisten_fail
    mov x19, x0
    ADDR x0, started
    bl message
.Lserve:
    ADDR x1, stop_requested
    ldar w0, [x1]
    cbnz w0, .Lstop
    ADDR x0, sleep_interval
    mov x1, #0
    bl nanosleep
    b .Lserve
.Lstop:
    mov x0, x19
    bl MHD_quiesce_daemon
    mov w20, w0
    mov x0, x19
    bl MHD_stop_daemon
    cmn w20, #1
    b.eq .Ldaemon_stopped
    mov w0, w20
    bl close
.Ldaemon_stopped:

    mov w0, #0
    b .Lmain_done
.Lusage:
    ADDR x0, usage
    bl message
    mov w0, #64
    b .Lmain_done
.Lconfig_fail:
    ADDR x0, config_error
    bl message
    mov w0, #78
    b .Lmain_done
.Ldatabase_fail:
    ADDR x0, db_error
    bl message
    mov w0, #78
    b .Lmain_done
.Llisten_fail:
    ADDR x0, listen_error
    bl message
    mov w0, #71
.Lmain_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
.size main,.-main
/* OpenSSL key callback: x0=buffer,w1=capacity,x2=connection.
 * Returns w0=0 without prompting. Leaf; writes NUL only for positive capacity. */
refuse_key_password:
    cmp w1, #0
    b.le .Lkey_refused
    strb wzr, [x0]
.Lkey_refused:
    mov w0, #0
    ret

/* Signal callback: one aligned 32-bit release store. No calls or stack.
 * Main/worker acquire loads observe the flag; no other state is published. */
request_stop:
    ADDR x1, stop_requested
    mov w0, #1
    stlr w0, [x1]
    ret

/* x0=fixed NUL-terminated message; no output value. Frame 32, saves x19/x20.
 * Retries interrupted/short writes. Never logs untrusted database text. */
message:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    bl strlen
    mov x20, x0
.Lmessage_write:
    cbz x20, .Lmessage_done
    mov x8, #SYS_WRITE
    mov x0, #2
    mov x1, x19
    mov x2, x20
    svc #0
    cmn x0, #4
    b.eq .Lmessage_write
    cmp x0, #0
    b.le .Lmessage_done
    add x19, x19, x0
    sub x20, x20, x0
    b .Lmessage_write
.Lmessage_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

/* x0=path; w0=1/0. Frame 176: saved x19/x20 and 128-byte kernel stat.
 * Owns one descriptor; uses openat O_NOFOLLOW/CLOEXEC/NONBLOCK. Requires
 * regular owner-only bytes owned by this UID/root. Reads <=4097 bytes,
 * requires EOF and printable ASCII, and strips at most one trailing LF.
 * Writes only pre-thread db_config[4098]. All failure paths close ownership. */
read_config:
    stp x29, x30, [sp, #-176]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x21, x0
.Lconfig_open:
    mov x0, #-100
    mov x1, x21
    movz w2, #(PRIVATE_OPEN_FLAGS & 65535)
    movk w2, #(PRIVATE_OPEN_FLAGS >> 16), lsl #16
    mov w3, #0
    mov x8, #SYS_OPENAT
    svc #0
    cmn x0, #4
    b.eq .Lconfig_open
    cmp x0, #0
    b.lt .Lconfig_bad
    mov x19, x0
.Lconfig_stat:
    mov x0, x19
    add x1, sp, #48
    mov x8, #SYS_FSTAT
    svc #0
    cmn x0, #4
    b.eq .Lconfig_stat
    cmp x0, #0
    b.lt .Lconfig_close_bad
    ldr w0, [sp, #(48 + STAT_MODE)]
    and w1, w0, #61440
    cmp w1, #32768
    b.ne .Lconfig_close_bad
    tst w0, #63
    b.ne .Lconfig_close_bad
    mov x8, #SYS_GETUID
    svc #0
    ldr w1, [sp, #(48 + STAT_UID)]
    cbz w1, .Lconfig_read_start
    cmp w1, w0
    b.ne .Lconfig_close_bad
.Lconfig_read_start:
    mov x20, #0
.Lconfig_read:
    mov x0, x19
    ADDR x1, db_config
    add x1, x1, x20
    mov x2, #(CONFIG_LIMIT + 1)
    sub x2, x2, x20
    mov x8, #SYS_READ
    svc #0
    cmn x0, #4
    b.eq .Lconfig_read
    cmp x0, #0
    b.lt .Lconfig_close_bad
    b.eq .Lconfig_eof
    add x20, x20, x0
    cmp x20, #CONFIG_LIMIT
    b.hi .Lconfig_close_bad
    b .Lconfig_read
.Lconfig_eof:
    mov x0, x19
    mov x8, #SYS_CLOSE
    svc #0
    cbz x20, .Lconfig_bad
    ADDR x2, db_config
    sub x1, x20, #1
    ldrb w0, [x2, x1]
    cmp w0, #10
    b.ne .Lconfig_scan
    sub x20, x20, #1
.Lconfig_scan:
    cbz x20, .Lconfig_bad
    mov x1, #0
.Lconfig_chars:
    ldrb w0, [x2, x1]
    cmp w0, #32
    b.lo .Lconfig_bad
    cmp w0, #126
    b.hi .Lconfig_bad
    add x1, x1, #1
    cmp x1, x20
    b.lo .Lconfig_chars
    strb wzr, [x2, x20]
    mov w0, #1
    b .Lconfig_return
.Lconfig_close_bad:
    mov x0, x19
    mov x8, #SYS_CLOSE
    svc #0
.Lconfig_bad:
    mov w0, #0
.Lconfig_return:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #176
    ret

/* No inputs; x0=monotonic ms or -1. Frame 32 includes owned timespec[16]. */
clock_ms:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov w0, #1
    add x1, sp, #16
    bl clock_gettime
    cbnz w0, .Lclock_bad
    ldp x1, x2, [sp, #16]
    mov x3, #1000
    mul x1, x1, x3
    movz x3, #(1000000 & 65535)
    movk x3, #(1000000 >> 16), lsl #16
    udiv x2, x2, x3
    add x0, x1, x2
    b .Lclock_return
.Lclock_bad:
    mov x0, #-1
.Lclock_return:
    ldp x29, x30, [sp], #32
    ret

/* x0=PGconn, w1=poll events, x2=absolute deadline; w0=1 when ready else 0.
 * Frame 64 includes one pollfd and saved x19-x21. Retries EINTR until the
 * deadline. This routine borrows the connection and never shares it. */
wait_database:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov w20, w1
    mov x21, x2
    bl PQsocket
    cmp w0, #0
    b.lt .Lwait_bad
    str w0, [sp, #48]
    strh w20, [sp, #52]
.Lwait_again:
    strh wzr, [sp, #54]
    bl clock_ms
    cmp x0, #0
    b.lt .Lwait_bad
    subs x2, x21, x0
    b.le .Lwait_bad
    add x0, sp, #48
    mov x1, #1
    bl poll
    cbz w0, .Lwait_bad
    cmp w0, #0
    b.lt .Lwait_errno
    ldrh w0, [sp, #54]
    tst w0, #56
    b.ne .Lwait_bad
    tst w0, w20
    b.eq .Lwait_again
    mov w0, #1
    b .Lwait_return
.Lwait_errno:
    bl __errno_location
    ldr w0, [x0]
    cmp w0, #4
    b.eq .Lwait_again
.Lwait_bad:
    mov w0, #0
.Lwait_return:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

/* x0=fixed SQL or NULL for guard only, w1=count, x2=parameters,
 * w3=positive byte bound <=MAX_JSON. x0=owned PGresult or NULL; caller clears.
 * Frame 80 saves x19-x24; local bound/phase occupy offsets 64/72.
 * One TLS connection sends BEGIN READ ONLY, guard, then optional fixed SQL.
 * Every command drains; all I/O shares one absolute two-second deadline.
 * PQfinish closes the transaction; an accepted PGresult remains owned. */
database_query:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov w20, w1
    mov x21, x2
    mov x23, #0
    mov x24, #0
    str w3, [sp, #64]
    str wzr, [sp, #72]
    cmp w3, #0
    b.le .Ldb_failed
    cmp w3, #MAX_JSON
    b.hi .Ldb_failed
    bl clock_ms
    cmp x0, #0
    b.lt .Ldb_failed
    add x22, x0, #DB_DEADLINE_MS
    ADDR x0, db_keys
    ADDR x1, db_values
    mov w2, #1
    bl PQconnectStartParams
    cbz x0, .Ldb_failed
    mov x23, x0
    ADDR x1, ignore_notice
    mov x2, #0
    bl PQsetNoticeProcessor
.Ldb_connect:
    bl clock_ms
    cmp x0, #0
    b.lt .Ldb_failed
    cmp x0, x22
    b.hs .Ldb_failed
    mov x0, x23
    bl PQconnectPoll
    cmp w0, #3
    b.eq .Ldb_connected
    mov w1, #1
    cmp w0, #1
    b.eq .Ldb_connect_wait
    mov w1, #4
    cmp w0, #2
    b.ne .Ldb_failed
.Ldb_connect_wait:
    mov x0, x23
    mov x2, x22
    bl wait_database
    cbz w0, .Ldb_failed
    b .Ldb_connect
.Ldb_connected:
    mov x0, x23
    bl PQsslInUse
    cmp w0, #1
    b.ne .Ldb_failed
    mov x0, x23
    mov w1, #1
    bl PQsetnonblocking
    cbnz w0, .Ldb_failed
.Ldb_send:
    bl clock_ms
    cmp x0, #0
    b.lt .Ldb_failed
    cmp x0, x22
    b.hs .Ldb_failed
    mov x0, x23
    ADDR x1, begin_read_only
    mov w2, #0
    mov x4, #0
    ldr w8, [sp, #72]
    cbz w8, .Ldb_send_selected
    ADDR x1, guard_sql
    cmp w8, #1
    b.eq .Ldb_send_selected
    mov x1, x19
    mov w2, w20
    mov x4, x21
.Ldb_send_selected:
    mov x3, #0
    mov x5, #0
    mov x6, #0
    mov w7, #0
    bl PQsendQueryParams
    cmp w0, #1
    b.ne .Ldb_failed
.Ldb_flush:
    mov x0, x23
    bl PQflush
    cbz w0, .Ldb_read
    cmp w0, #1
    b.ne .Ldb_failed
    mov x0, x23
    mov w1, #4
    mov x2, x22
    bl wait_database
    cbz w0, .Ldb_failed
    b .Ldb_flush
.Ldb_read:
    bl clock_ms
    cmp x0, #0
    b.lt .Ldb_failed
    cmp x0, x22
    b.hs .Ldb_failed
    mov x0, x23
    bl PQconsumeInput
    cmp w0, #1
    b.ne .Ldb_failed
    mov x0, x23
    bl PQisBusy
    cbz w0, .Ldb_result
    mov x0, x23
    mov w1, #1
    mov x2, x22
    bl wait_database
    cbz w0, .Ldb_failed
    b .Ldb_read
.Ldb_result:
    mov x0, x23
    bl PQgetResult
    cbz x0, .Ldb_complete
    cbnz x24, .Ldb_extra_result
    mov x24, x0
    bl PQresultStatus
    ldr w8, [sp, #72]
    cbnz w8, .Ldb_tuple_status
    cmp w0, #1
    b.ne .Ldb_failed
    b .Ldb_read
.Ldb_tuple_status:
    cmp w0, #2
    b.ne .Ldb_failed
    mov x0, x24
    bl PQntuples
    cmp w0, #1
    b.ne .Ldb_failed
    mov x0, x24
    bl PQnfields
    cmp w0, #1
    b.ne .Ldb_failed
    mov x0, x24
    mov w1, #0
    mov w2, #0
    bl PQgetisnull
    cbnz w0, .Ldb_failed
    mov x0, x24
    mov w1, #0
    mov w2, #0
    bl PQgetlength
    cmp w0, #0
    b.le .Ldb_failed
    ldr w8, [sp, #72]
    cmp w8, #1
    b.ne .Ldb_export_length
    cmp w0, #1
    b.ne .Ldb_failed
    mov x0, x24
    mov w1, #0
    mov w2, #0
    bl PQgetvalue
    ldrh w8, [x0]
    cmp w8, #49
    b.ne .Ldb_failed
    b .Ldb_read
.Ldb_export_length:
    ldr w8, [sp, #64]
    cmp w0, w8
    b.hi .Ldb_failed
    b .Ldb_read
.Ldb_extra_result:
    bl PQclear
    b .Ldb_failed
.Ldb_complete:
    cbz x24, .Ldb_failed
    ldr w8, [sp, #72]
    cmp w8, #2
    b.eq .Ldb_finish
    cmp w8, #1
    b.ne .Ldb_next
    cbz x19, .Ldb_finish
.Ldb_next:
    mov x0, x24
    bl PQclear
    mov x24, #0
    ldr w8, [sp, #72]
    add w8, w8, #1
    str w8, [sp, #72]
    b .Ldb_send
.Ldb_finish:
    mov x0, x23
    bl PQfinish
    mov x0, x24
    b .Ldb_return
.Ldb_failed:
    cbz x24, .Ldb_close
    mov x0, x24
    bl PQclear
.Ldb_close:
    cbz x23, .Ldb_null
    mov x0, x23
    bl PQfinish
.Ldb_null:
    mov x0, #0
.Ldb_return:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

/* libpq notice callback: borrowed arguments; no calls, state, or logging. */
ignore_notice:
    ret

/* No inputs; w0=1 only for the guard's exact '1' result. Frame 32 saves
 * x19/x20; owns the result until PQclear and releases it on every path. */
database_ready:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x0, #0
    mov w1, #0
    mov x2, #0
    mov w3, #1
    bl database_query
    cbz x0, .Lready_no
    mov x19, x0
    mov w1, #0
    mov w2, #0
    bl PQgetvalue
    ldrh w0, [x0]
    cmp w0, #49
    cset w20, eq
    mov x0, x19
    bl PQclear
    mov w0, w20
    b .Lready_return
.Lready_no:
    mov w0, #0
.Lready_return:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

/* MHD URI callback: x1=borrowed URI. x0=opaque marker 1 if >2048 bytes.
 * Frame 16; strnlen reads at most 2049 bytes. No URI is copied or logged. */
uri_bound:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, x1
    mov x1, #2049
    bl strnlen
    cmp x0, #2048
    cset x0, hi
    ldp x29, x30, [sp], #16
    ret

/* MHD iterator: x0=owned {count,bytes,bad} u64 workspace; x3/x5=lengths.
 * w0=MHD_YES/NO. Leaf, no stack; changes caller-saved x6/x7 only. */
header_bound:
    ldp x6, x7, [x0]
    add x6, x6, #1
    add x7, x7, x3
    add x7, x7, x5
    stp x6, x7, [x0]
    cmp x6, #64
    b.hi .Lheader_bad
    cmp x7, #16384
    b.hi .Lheader_bad
    mov w0, #1
    ret
.Lheader_bad:
    mov x6, #1
    str x6, [x0, #16]
    mov w0, #0
    ret

/* x0=connection, w1=status, x2=NUL fixed JSON body <=MAX_REPLY.
 * w0=MHD_Result. Frame 48 saves x19-x21. The common response path copies bytes. */
queue_json:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov w20, w1
    mov x21, x2
    mov x0, x2
    mov x1, #(MAX_REPLY + 1)
    bl strnlen
    cmp x0, #MAX_REPLY
    b.hi .Lfixed_queue_no
    mov x3, x0
    mov x0, x19
    mov w1, w20
    mov x2, x21
    ADDR x4, type_json
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    b queue_response
.Lfixed_queue_no:
    mov w0, #0
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

/* x0=connection,w1=status,x2=borrowed bytes,x3=length<=MAX_JSON,x4=fixed type.
 * w0=MHD_Result. Frame 64 saves x19-x23 and stores type at 56.
 * MHD copies before return. Every path destroys its response; failure closes HTTP. */
queue_response:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov w20, w1
    mov x21, x2
    str x4, [sp, #56]
    cbz x3, .Lqueue_no
    cmp x3, #MAX_JSON
    b.hi .Lqueue_no
    mov x0, x3
    mov x1, x21
    mov w2, #2
    bl MHD_create_response_from_buffer
    cbz x0, .Lqueue_no
    mov x22, x0
    ADDR x1, header_type
    ldr x2, [sp, #56]
    bl MHD_add_response_header
    cmp w0, #1
    b.ne .Lqueue_destroy_no
    mov x0, x22
    ADDR x1, header_cache
    ADDR x2, cache_no_store
    bl MHD_add_response_header
    cmp w0, #1
    b.ne .Lqueue_destroy_no
    mov x0, x22
    ADDR x1, header_nosniff
    ADDR x2, nosniff
    bl MHD_add_response_header
    cmp w0, #1
    b.ne .Lqueue_destroy_no
    mov x0, x22
    ADDR x1, header_connection
    ADDR x2, close_value
    bl MHD_add_response_header
    cmp w0, #1
    b.ne .Lqueue_destroy_no
    mov x0, x19
    mov w1, w20
    mov x2, x22
    bl MHD_queue_response
    mov w23, w0
    mov x0, x22
    bl MHD_destroy_response
    mov w0, w23
    b .Lqueue_return
.Lqueue_destroy_no:
    mov x0, x22
    bl MHD_destroy_response
.Lqueue_no:
    mov w0, #0
.Lqueue_return:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
/* Any query field is unsupported. x0=owned bad flag; w0=NO.
 * Leaf callback, no stack or allocation. */
query_value:
    mov x1, #1
    str x1, [x0]
    mov w0, #0
    ret

/* MHD access callback: x0=cls,x1=connection,x2=url,x3=method,
 * x4=version,x5=upload,x6=size pointer,x7=request-state pointer. w0=result.
 * Frame 144 saves x19-x24 and owns header/query workspaces at offsets64/96.
 * Borrows library strings only during this call; never shares PGconn state. */
handle_request:
    stp x29, x30, [sp, #-144]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x1
    mov x20, x2
    mov x21, x3
    ldr x0, [x7]
    cmp x0, #2
    b.eq .Lhandled
    cmp x0, #1
    b.eq .Luri_error
    mov x0, #2
    str x0, [x7]
    mov x0, x21
    ADDR x1, get_method
    bl strcmp
    cbnz w0, .Lmethod_error
    stp xzr, xzr, [sp, #64]
    str xzr, [sp, #80]
    mov x0, x19
    mov w1, #1
    ADDR x2, header_bound
    add x3, sp, #64
    bl MHD_get_connection_values_n
    ldr x0, [sp, #80]
    cbnz x0, .Lheaders_error
    mov x0, x19
    mov w1, #1
    ADDR x2, header_te
    bl MHD_lookup_connection_value
    cbnz x0, .Lbody_error
    mov x0, x19
    mov w1, #1
    ADDR x2, header_cl
    bl MHD_lookup_connection_value
    cbz x0, .Lroute
    ldrh w0, [x0]
    cmp w0, #48
    b.ne .Lbody_error
.Lroute:

    str xzr, [sp, #96]
    mov x0, x19
    mov w1, #8
    ADDR x2, query_value
    add x3, sp, #96
    bl MHD_get_connection_values_n
    ldr x0, [sp, #96]
    cbnz x0, .Lquery_error
    mov x0, x20
    ADDR x1, path_live
    bl strcmp
    cbz w0, .Llive
    mov x0, x20
    ADDR x1, path_ready
    bl strcmp
    cbz w0, .Lready
    mov x0, x20
    ADDR x1, path_status
    bl strcmp
    cbz w0, .Lstatus
    mov x0, x20
    ADDR x1, path_linux
    bl strcmp
    cbz w0, .Llinux_export
    mov x0, x20
    ADDR x1, path_macos
    bl strcmp
    cbz w0, .Lmacos_export
    mov x0, x20
    ADDR x1, path_index
    bl strcmp
    cbz w0, .Ljson_export
    b .Lnot_found

.Llive:
    ADDR x2, live_body
    mov w1, #200
    b .Lfixed_response
.Lready:
    ADDR x1, stop_requested
    ldar w0, [x1]
    cbnz w0, .Lunavailable
    bl database_ready
    cbz w0, .Lunavailable
    ADDR x2, ready_body
    mov w1, #200
    b .Lfixed_response
.Lstatus:
    ADDR x2, status_body
    mov w1, #200
    b .Lfixed_response
.Llinux_export:
    ADDR x0, path_linux
    b .Ltsv_export
.Lmacos_export:
    ADDR x0, path_macos
.Ltsv_export:
    mov w23, #MAX_TSV
    ADDR x24, type_tsv
    b .Lcatalog_export
.Ljson_export:
    ADDR x0, path_index
    mov w23, #MAX_JSON
    ADDR x24, type_index
.Lcatalog_export:
    str x0, [sp, #104]         /* router-owned literal, not request text */
    ADDR x1, stop_requested
    ldar w0, [x1]
    cbnz w0, .Lunavailable
    ADDR x0, export_sql
    mov w1, #1
    add x2, sp, #104
    mov w3, w23
    bl database_query
    cbz x0, .Lunavailable
    mov x22, x0
    mov w1, #0
    mov w2, #0
    bl PQgetlength
    mov w23, w0
    mov x0, x22
    mov w1, #0
    mov w2, #0
    bl PQgetvalue
    mov x2, x0
    mov x0, x19
    mov w1, #200
    mov w3, w23
    mov x4, x24
    bl queue_response
    mov w21, w0
    mov x0, x22
    bl PQclear
    mov w0, w21
    b .Lrequest_return
.Lnot_found:
    ADDR x2, not_found_body
    mov w1, #404
    b .Lfixed_response
.Lmethod_error:
    ADDR x2, bad_method_body
    mov w1, #405
    b .Lfixed_response
.Lbody_error:
    ADDR x2, bad_body
    mov w1, #400
    b .Lfixed_response
.Lheaders_error:
    ADDR x2, headers_body
    mov w1, #431
    b .Lfixed_response
.Lquery_error:
    ADDR x2, bad_query_body
    mov w1, #400
    b .Lfixed_response
.Luri_error:
    mov x0, #2
    str x0, [x7]
    ADDR x2, uri_body
    mov w1, #414
    b .Lfixed_response
.Lunavailable:
    ADDR x2, unavailable_body
    mov w1, #503
.Lfixed_response:
    mov x0, x19
    bl queue_json
    b .Lrequest_return
.Lhandled:
    mov w0, #1
.Lrequest_return:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #144
    ret

.section .note.GNU-stack,"",%progbits
