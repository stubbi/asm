/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native ARMv8-A, little-endian Linux LP64, AAPCS64.
 * HTTP framing belongs to libmicrohttpd 1.0.3; PostgreSQL/auth/TLS to libpq.
 * Loopback prototype: experimental read endpoints only.
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
.equ CONFIG_LIMIT, 4096
.equ QUERY_LIMIT, 160
.equ AFTER_LIMIT, 104

.section .rodata
usage: .asciz "Usage: asm-hub-prototype HTTP_PORT DATABASE_URL_FILE\nThis experiment binds to 127.0.0.1 and forces a loopback database host.\n"
config_error: .asciz "asm-hub-prototype: use a regular, private database URL file and a port from 1024 to 65535.\n"
db_error: .asciz "asm-hub-prototype: the database role, schema, or catalog is not ready.\n"
listen_error: .asciz "asm-hub-prototype: the loopback HTTP listener could not start.\n"
library_error: .asciz "asm-hub-prototype: use libmicrohttpd 1.0.3 and libpq 16.15. Rebuild with the pinned libraries.\n"
http_version: .asciz "1.0.3"
started: .asciz "asm-hub-prototype: listening on loopback; experimental read endpoints only.\n"
get_method: .asciz "GET"
path_live: .asciz "/health/live"
path_ready: .asciz "/health/ready"
path_packages: .asciz "/prototype/packages"
path_status: .asciz "/"
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
status_body: .asciz "{\"service\":\"asm-hub-prototype\",\"experimental\":true,\"application_language\":\"assembly\",\"http_library\":\"GNU libmicrohttpd 1.0.3\",\"database_library\":\"libpq\",\"publishing\":false}\n"
bad_query_body: .asciz "{\"error\":{\"code\":\"invalid_query\",\"message\":\"Use q and after once each. The query must use printable ASCII within the stated limits.\"}}\n"
bad_body: .asciz "{\"error\":{\"code\":\"body_not_supported\",\"message\":\"Read requests cannot contain a body.\"}}\n"
bad_method_body: .asciz "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"This experiment accepts GET requests only.\"}}\n"
not_found_body: .asciz "{\"error\":{\"code\":\"not_found\",\"message\":\"The experimental route does not exist.\"}}\n"
unavailable_body: .asciz "{\"error\":{\"code\":\"temporarily_unavailable\",\"message\":\"The database request could not finish. Try again shortly.\"}}\n"
uri_body: .asciz "{\"error\":{\"code\":\"uri_too_long\",\"message\":\"The request URL exceeds 2048 bytes.\"}}\n"
headers_body: .asciz "{\"error\":{\"code\":\"headers_too_large\",\"message\":\"The headers exceed the service limit.\"}}\n"
db_key_dbname: .asciz "dbname"
db_key_hostaddr: .asciz "hostaddr"
db_key_host: .asciz "host"
db_key_timeout: .asciz "connect_timeout"
db_key_options: .asciz "options"
db_key_application: .asciz "application_name"
loopback: .asciz "127.0.0.1"
timeout_value: .asciz "2"
db_options: .asciz "-c default_transaction_read_only=on -c statement_timeout=1000 -c lock_timeout=200 -c search_path=pg_catalog,public"
application_name: .asciz "asm-assembly-prototype"
guard_sql:
.incbin "guard.sql"
.byte 0
search_sql:
.incbin "search.sql"
.byte 0

.section .data.rel.ro,"aw"
.balign 8
db_keys: .quad db_key_dbname, db_key_hostaddr, db_key_host, db_key_timeout, db_key_options, db_key_application, 0
db_values: .quad db_config, loopback, loopback, timeout_value, db_options, application_name, 0
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

    cmp w0, #3
    b.ne .Lusage
    mov x19, x1
    bl validate_libraries
    cbz w0, .Llibrary_fail
    ldr x1, [x19, #8]
    mov w0, #0
    mov x2, #0
.Lport_digit:
    ldrb w3, [x1, x2]
    cbz w3, .Lport_done
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lconfig_fail
    mov w4, #10
    madd w0, w0, w4, w3
    mov w4, #65535
    cmp w0, w4
    b.hi .Lconfig_fail
    add x2, x2, #1
    cmp x2, #5
    b.hi .Lconfig_fail
    b .Lport_digit
.Lport_done:
    cmp w0, #1024
    b.lo .Lconfig_fail
    rev16 w0, w0
    ADDR x2, listen_address
    strh w0, [x2, #2]
    ldr x0, [x19, #16]
    bl read_config
    cbz w0, .Lconfig_fail

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
    bl MHD_stop_daemon

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
/* Library mismatch has the same configuration-error status. */
.Llibrary_fail:
    ADDR x0, library_error
    bl message
    mov w0, #78
    b .Lmain_done

/* No inputs; w0=1 only for reviewed runtime versions. No buffers owned.
 * Frame 16; changes caller-saved registers. Runs before config/listeners. */
validate_libraries:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl MHD_get_version
    cbz x0, .Llibrary_invalid
    ADDR x1, http_version
    bl strcmp
    cbnz w0, .Llibrary_invalid
    bl PQlibVersion
    movz w1, #(160015 & 65535)
    movk w1, #(160015 >> 16), lsl #16
    cmp w0, w1
    cset w0, eq
    b .Llibrary_checked
.Llibrary_invalid:
    mov w0, #0
.Llibrary_checked:
    ldp x29, x30, [sp], #16
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

/* x0=fixed SQL, w1=count, x2=borrowed parameter array. x0=owned PGresult
 * or NULL; caller clears it. Frame 80 saves x19-x24. Owns exactly one
 * connection and one bounded, one-row/one-column result. All I/O/drain stages
 * share one two-second deadline; every failure clears and closes ownership. */
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
    mov w1, #1
    bl PQsetnonblocking
    cbnz w0, .Ldb_failed
    mov x0, x23
    mov x1, x19
    mov w2, w20
    mov x3, #0
    mov x4, x21
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
    cmp w0, #MAX_REPLY
    b.hi .Ldb_failed
    b .Ldb_read
.Ldb_extra_result:
    bl PQclear
    b .Ldb_failed
.Ldb_complete:
    cbz x24, .Ldb_failed
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
    ADDR x0, guard_sql
    mov w1, #0
    mov x2, #0
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

/* x0=borrowed connection, w1=status, x2=NUL body <=MAX_REPLY.
 * Frame 64 saves x19-x23. Owns each response until MHD copies/queues the
 * body and destroys the response on success or error. No result survives. */
queue_json:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov w20, w1
    mov x21, x2
    mov x0, x2
    mov x1, #(MAX_REPLY + 1)
    bl strnlen
    cmp x0, #MAX_REPLY
    b.hi .Lqueue_no
    mov x1, x21
    mov w2, #2
    bl MHD_create_response_from_buffer
    cbz x0, .Lqueue_no
    mov x22, x0
    ADDR x1, header_type
    ADDR x2, type_json
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

/* MHD query iterator: x0=owned {q,after,seen,bad}, x2=key,x3=key length,
 * x4=borrowed value,x5=value length. w0=MHD_YES/NO. Leaf; no stack.
 * The library owns value bytes until the access callback returns. */
query_value:
    cbz x4, .Lquery_bad
    cmp x3, #1
    b.ne .Lquery_after
    ldrb w6, [x2]
    cmp w6, #'q'
    b.ne .Lquery_bad
    ldr x6, [x0, #16]
    tst x6, #1
    b.ne .Lquery_bad
    cmp x5, #QUERY_LIMIT
    b.hi .Lquery_bad
    orr x6, x6, #1
    str x6, [x0, #16]
    str x4, [x0]
    b .Lquery_chars
.Lquery_after:
    cmp x3, #5
    b.ne .Lquery_bad
    ldr w6, [x2]
    movz w7, #0x6661
    movk w7, #0x6574, lsl #16
    cmp w6, w7
    b.ne .Lquery_bad
    ldrb w6, [x2, #4]
    cmp w6, #'r'
    b.ne .Lquery_bad
    ldr x6, [x0, #16]
    tst x6, #2
    b.ne .Lquery_bad
    cmp x5, #AFTER_LIMIT
    b.hi .Lquery_bad
    orr x6, x6, #2
    str x6, [x0, #16]
    str x4, [x0, #8]
.Lquery_chars:
    mov x6, #0
.Lquery_char:
    cmp x6, x5
    b.hs .Lquery_ok
    ldrb w7, [x4, x6]
    cmp w7, #32
    b.lo .Lquery_bad
    cmp w7, #126
    b.hi .Lquery_bad
    add x6, x6, #1
    b .Lquery_char
.Lquery_ok:
    mov w0, #1
    ret
.Lquery_bad:
    mov x6, #1
    str x6, [x0, #24]
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
    ADDR x1, path_packages
    bl strcmp
    cbnz w0, .Lnot_found
    ADDR x0, empty
    stp x0, x0, [sp, #96]
    stp xzr, xzr, [sp, #112]
    mov x0, x19
    mov w1, #8
    ADDR x2, query_value
    add x3, sp, #96
    bl MHD_get_connection_values_n
    ldr x0, [sp, #120]
    cbnz x0, .Lquery_error
    ADDR x1, stop_requested
    ldar w0, [x1]
    cbnz w0, .Lunavailable
    ADDR x0, search_sql
    mov w1, #2
    add x2, sp, #96
    bl database_query
    cbz x0, .Lunavailable
    mov x22, x0
    mov w1, #0
    mov w2, #0
    bl PQgetvalue
    mov x2, x0
    mov x0, x19
    mov w1, #200
    bl queue_json
    mov w23, w0
    mov x0, x22
    bl PQclear
    mov w0, w23
    b .Lrequest_return

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
