/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native ARMv8-A, little-endian Linux LP64, AAPCS64.
 * Configuration is immutable before HTTP threads. libpq parses URLs;
 * this assembly layer restricts their authority without opening a connection.
 * x0-x7 arguments, x0 result; preserve x19-x29 and 16-byte SP alignment.
 * x16/x17 are PLT scratch; no SIMD state is changed.
 */
.arch armv8-a
.macro ADDR reg, symbol
    adrp \reg, \symbol
    add \reg, \reg, :lo12:\symbol
.endm
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
/* Keyword, required-field bit, validator: identifier, hostname, IP, port,
 * fixed TLS mode, or absolute certificate path. No other URL option exists. */
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
.type clear_pg_environment,%function
/* No inputs; w0=1 or 0. Frame 320 owns a 272-byte name buffer and saves
 * x19/x20. Removes PG-prefixed settings before threads; never logs values.
 * Reloads environ after each unsetenv because its array can move. */
clear_pg_environment:
    stp x29, x30, [sp, #-320]!
    mov x29, sp
    stp x19, x20, [sp, #16]
.Lenv_restart:
    adrp x9, :got:environ
    ldr x9, [x9, :got_lo12:environ]
    ldr x19, [x9]
.Lenv_next:
    ldr x20, [x19]
    cbz x20, .Lenv_ok
    ldrb w9, [x20]
    cmp w9, #'P'
    b.ne .Lenv_advance
    ldrb w9, [x20, #1]
    cmp w9, #'G'
    b.ne .Lenv_advance
    mov x10, #0
    add x11, sp, #48
.Lenv_name:
    cmp x10, #255
    b.hi .Lenv_bad
    ldrb w9, [x20, x10]
    cbz w9, .Lenv_bad
    cmp w9, #'='
    b.eq .Lenv_unset
    strb w9, [x11, x10]
    add x10, x10, #1
    b .Lenv_name
.Lenv_unset:
    strb wzr, [x11, x10]
    mov x0, x11
    bl unsetenv
    cbnz w0, .Lenv_bad
    b .Lenv_restart
.Lenv_advance:
    add x19, x19, #8
    b .Lenv_next
.Lenv_ok:
    mov w0, #1
    b .Lenv_done
.Lenv_bad:
    mov w0, #0
.Lenv_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #320
    ret
.size clear_pg_environment,.-clear_pg_environment

.globl parse_bind
.type parse_bind,%function
/* x0=borrowed environment string or NULL, x1=owned sockaddr_in[16].
 * w0=1/0. Frame 112 includes a 64-byte copy and saved x19-x21. Accepts
 * IPv4 literal:decimal port 1024..65535. Never resolves or changes input. */
parse_bind:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    cbz x0, .Lbind_bad
    mov x19, x0
    mov x20, x1
    mov x1, #23
    bl strnlen
    cmp x0, #22
    b.hi .Lbind_bad
    cbz x0, .Lbind_bad
    add x2, x0, #1
    add x0, sp, #48
    mov x1, x19
    bl memcpy
    add x0, sp, #48
    mov w1, #':'
    bl strchr
    cbz x0, .Lbind_bad
    strb wzr, [x0]
    add x21, x0, #1
    mov w0, #2
    add x1, sp, #48
    add x2, x20, #4
    bl inet_pton
    cmp w0, #1
    b.ne .Lbind_bad
    mov x0, x21
    bl port_number
    cmp w0, #1024
    b.lo .Lbind_bad
    rev16 w0, w0
    strh w0, [x20, #2]
    mov w0, #1
    b .Lbind_done
.Lbind_bad:
    mov w0, #0
.Lbind_done:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #112
    ret
.size parse_bind,.-parse_bind

/* x0=decimal string; w0=1..65535 or 0. Leaf; caller-saved only, no stack.
 * Rejects leading zero and more than five digits before accepting a port. */
port_number:
    mov x1, x0
    ldrb w3, [x1]
    cmp w3, #'0'
    b.eq .Lport_bad
    mov w0, #0
    mov x2, #0
.Lport_next:
    ldrb w3, [x1, x2]
    cbz w3, .Lport_return
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lport_bad
    mov w4, #10
    madd w0, w0, w4, w3
    mov w4, #65535
    cmp w0, w4
    b.hi .Lport_bad
    add x2, x2, #1
    cmp x2, #5
    b.hi .Lport_bad
    b .Lport_next
.Lport_bad:
    mov w0, #0
.Lport_return:
    ret

/* x0=ASCII connection URL <=4096 bytes. w0=1 iff five raw query keys
 * occur exactly once. Frame 48 saves x19-x22; no allocation or mutation.
 * Checks keys before libpq normalization can hide duplicate options. */
check_query:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w1, #'?'
    bl strchr
    cbz x0, .Lquery_invalid
    add x19, x0, #1
    mov x20, #0
.Lquery_field:
    ADDR x21, query_fields
.Lquery_candidate:
    ldr x1, [x21]
    cbz x1, .Lquery_invalid
    mov x0, x19
    ldr x2, [x21, #8]
    bl strncmp
    cbz w0, .Lquery_match
    add x21, x21, #24
    b .Lquery_candidate
.Lquery_match:
    ldr x22, [x21, #16]
    tst x20, x22
    b.ne .Lquery_invalid
    orr x20, x20, x22
    ldr x9, [x21, #8]
    add x19, x19, x9
    ldrb w9, [x19]
    cbz w9, .Lquery_invalid
    cmp w9, #'&'
    b.eq .Lquery_invalid
    mov x0, x19
    mov w1, #'&'
    bl strchr
    cbz x0, .Lquery_end
    add x19, x0, #1
    b .Lquery_field
.Lquery_end:
    cmp x20, #31
    cset w0, eq
    b .Lquery_done
.Lquery_invalid:
    mov w0, #0
.Lquery_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

.globl validate_database_config
.type validate_database_config,%function
/* Immutable global db_config[4098] is the sole input; w0=1/0. No network.
 * Frame 96 saves x19-x24; owns PQconninfoParse's array until PQconninfoFree.
 * Parse-error memory is released without logging. Requires explicit user,
 * database, hostname, IPv4, port, verify-full and CA/client certificate/key.
 * No password or other option is accepted. PQconninfoOption is 56 bytes,
 * val at24; build-time assertions bind this layout to reviewed headers. */
validate_database_config:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    ADDR x0, db_config
    ADDR x1, uri_prefix
    mov x2, #13
    bl strncmp
    cbnz w0, .Lpolicy_no_array
    ADDR x0, db_config
    bl check_query
    cbz w0, .Lpolicy_no_array
    str xzr, [sp, #64]
    ADDR x0, db_config
    add x1, sp, #64
    bl PQconninfoParse
    cbz x0, .Lpolicy_parse_error
    mov x23, x0
    mov x19, x0
    mov x20, #0
.Lpolicy_option:
    ldr x9, [x19]
    cbz x9, .Lpolicy_finish
    ldr x21, [x19, #24]
    cbz x21, .Lpolicy_next
    ADDR x22, allowed
.Lpolicy_candidate:
    ldr x1, [x22]
    cbz x1, .Lpolicy_bad
    ldr x0, [x19]
    bl strcmp
    cbz w0, .Lpolicy_value
    add x22, x22, #24
    b .Lpolicy_candidate
.Lpolicy_value:
    ldr x9, [x22, #8]
    tst x20, x9
    b.ne .Lpolicy_bad
    orr x20, x20, x9
    ldr x9, [x22, #16]
    mov x0, x21
    cbz w9, .Lpolicy_identifier
    cmp w9, #1
    b.eq .Lpolicy_hostname
    cmp w9, #2
    b.eq .Lpolicy_address
    cmp w9, #3
    b.eq .Lpolicy_port
    cmp w9, #4
    b.eq .Lpolicy_mode
    ldrb w9, [x21]
    cmp w9, #'/'
    b.ne .Lpolicy_bad
    mov x1, #1025
    bl strnlen
    cmp x0, #1024
    b.hi .Lpolicy_bad
    mov x1, x0
    mov x2, #0
.Lpolicy_path_char:
    cmp x2, x1
    b.hs .Lpolicy_next
    ldrb w0, [x21, x2]
    cmp w0, #32
    b.lo .Lpolicy_bad
    cmp w0, #126
    b.hi .Lpolicy_bad
    add x2, x2, #1
    b .Lpolicy_path_char
.Lpolicy_identifier:
    bl identifier
    cbz w0, .Lpolicy_bad
    b .Lpolicy_next
.Lpolicy_hostname:
    bl hostname
    cbz w0, .Lpolicy_bad
    b .Lpolicy_next
.Lpolicy_address:
    mov x1, x21
    mov w0, #2
    add x2, sp, #72
    bl inet_pton
    cmp w0, #1
    b.ne .Lpolicy_bad
    b .Lpolicy_next
.Lpolicy_port:
    bl port_number
    cbz w0, .Lpolicy_bad
    b .Lpolicy_next
.Lpolicy_mode:
    ADDR x1, verify_full
    bl strcmp
    cbnz w0, .Lpolicy_bad
.Lpolicy_next:
    add x19, x19, #56
    b .Lpolicy_option
.Lpolicy_finish:
    cmp x20, #511
    cset w24, eq
    b .Lpolicy_free
.Lpolicy_bad:
    mov w24, #0
.Lpolicy_free:
    mov x0, x23
    bl PQconninfoFree
    mov w0, w24
    b .Lpolicy_return
.Lpolicy_parse_error:
    ldr x0, [sp, #64]
    cbz x0, .Lpolicy_no_array
    bl PQfreemem
.Lpolicy_no_array:
    mov w0, #0
.Lpolicy_return:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret
.size validate_database_config,.-validate_database_config

/* x0=decoded identifier; w0=1/0. First byte lower-case ASCII/underscore,
 * then lower-case/digits/underscore, 1..63 bytes. Leaf, no owned buffers. */
identifier:
    mov x1, x0
    ldrb w9, [x1]
    cmp w9, #'_'
    b.eq .Lidentifier_start
    cmp w9, #'a'
    b.lo .Ltext_bad
    cmp w9, #'z'
    b.hi .Ltext_bad
.Lidentifier_start:
    mov x2, #0
.Lidentifier_char:
    ldrb w9, [x1, x2]
    cbz w9, .Ltext_ok
    cmp x2, #63
    b.hs .Ltext_bad
    cmp w9, #'_'
    b.eq .Lidentifier_next
    cmp w9, #'0'
    b.lo .Ltext_bad
    cmp w9, #'9'
    b.ls .Lidentifier_next
    cmp w9, #'a'
    b.lo .Ltext_bad
    cmp w9, #'z'
    b.hi .Ltext_bad
.Lidentifier_next:
    add x2, x2, #1
    b .Lidentifier_char

/* x0=decoded host; w0=1/0. Up to253 ASCII letters/digits/dot/hyphen.
 * Leaf, no DNS calls, allocation, state, or callee-saved changes. */
hostname:
    mov x1, x0
    mov x2, #0
.Lhostname_char:
    ldrb w9, [x1, x2]
    cbz w9, .Lhostname_end
    cmp x2, #253
    b.hs .Ltext_bad
    cmp w9, #'.'
    b.eq .Lhostname_next
    cmp w9, #'-'
    b.eq .Lhostname_next
    cmp w9, #'0'
    b.lo .Ltext_bad
    cmp w9, #'9'
    b.ls .Lhostname_next
    orr w9, w9, #32
    cmp w9, #'a'
    b.lo .Ltext_bad
    cmp w9, #'z'
    b.hi .Ltext_bad
.Lhostname_next:
    add x2, x2, #1
    b .Lhostname_char
.Lhostname_end:
    cbz x2, .Ltext_bad
.Ltext_ok:
    mov w0, #1
    ret
.Ltext_bad:
    mov w0, #0
    ret

.section .note.GNU-stack,"",%progbits
