/* SPDX-License-Identifier: AGPL-3.0-or-later
 * GNU Intel-syntax assembly, Linux x86-64 System V ABI.
 * HTTP parsing belongs to libmicrohttpd 1.0.3. PostgreSQL protocol and TLS
 * belong to libpq. No C, Rust, Python, or shell application backend is used.
 * Canonical read-only catalog. Operator commands remain a separate tool.
 */
.intel_syntax noprefix
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
.type main,@function
/* Input: EDI=argc, RSI=argv. Output: ordinary process status.
 * Owns the daemon and immutable configuration. Stack: 72 bytes + saved RBX.
 * Starts no listener before the database role and schema pass the guard. */
main:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 72
    cmp edi, 2
    jne .Lusage
    mov rdi, [rsi + 8]
    lea rsi, [rip + serve_command]
    call strcmp@PLT
    test eax, eax
    jnz .Lusage
    call clear_pg_environment
    test eax, eax
    jz .Lconfig_fail
    lea rdi, [rip + env_bind]
    call getenv@PLT
    mov rdi, rax
    lea rsi, [rip + listen_address]
    call parse_bind
    test eax, eax
    jz .Lconfig_fail
    lea rdi, [rip + env_database]
    call getenv@PLT
    test rax, rax
    jz .Lconfig_fail
    mov rdi, rax
    call read_config
    test eax, eax
    jz .Lconfig_fail
    call validate_database_config
    test eax, eax
    jz .Lconfig_fail
    /* A projected encrypted key must fail, never open a terminal prompt. */
    lea rdi, [rip + refuse_key_password]
    call PQsetSSLKeyPassHook_OpenSSL@PLT
    mov edi, 13                  /* SIGPIPE */
    mov esi, 1                   /* SIG_IGN */
    call signal@PLT
    cmp rax, -1
    je .Lconfig_fail
    mov edi, 15                  /* SIGTERM */
    lea rsi, [rip + request_stop]
    call signal@PLT
    cmp rax, -1
    je .Lconfig_fail
    mov edi, 2                   /* SIGINT */
    lea rsi, [rip + request_stop]
    call signal@PLT
    cmp rax, -1
    je .Lconfig_fail
    call database_ready
    test eax, eax
    jz .Ldatabase_fail
    /* ITC wakes admission cleanup when a full set of connections closes. */
    mov edi, 1036                /* internal polling + thread per connection + ITC */
    xor esi, esi                 /* port comes from sockaddr */
    xor edx, edx
    xor ecx, ecx
    lea r8, [rip + handle_request]
    xor r9d, r9d
    mov qword ptr [rsp], 15       /* MHD_OPTION_ARRAY */
    lea rax, [rip + mhd_options]
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    xor eax, eax
    call MHD_start_daemon@PLT
    test rax, rax
    jz .Llisten_fail
    mov rbx, rax
    lea rdi, [rip + started]
    call message
.Lserve:
    cmp dword ptr [rip + stop_requested], 0
    jne .Lstop
    lea rdi, [rip + sleep_interval]
    xor esi, esi
    call nanosleep@PLT
    jmp .Lserve
.Lstop:
    mov rdi, rbx
    call MHD_quiesce_daemon@PLT
    /* Threaded MHD can retain this descriptor until stop has joined threads. */
    mov [rbp - 16], eax
    mov rdi, rbx
    call MHD_stop_daemon@PLT
    mov edi, [rbp - 16]
    cmp edi, -1
    je .Ldaemon_stopped
    call close@PLT
.Ldaemon_stopped:
    xor eax, eax
    jmp .Lmain_done
.Lusage:
    lea rdi, [rip + usage]
    call message
    mov eax, 64
    jmp .Lmain_done
.Lconfig_fail:
    lea rdi, [rip + config_error]
    call message
    mov eax, 78
    jmp .Lmain_done
.Ldatabase_fail:
    lea rdi, [rip + db_error]
    call message
    mov eax, 78
    jmp .Lmain_done
.Llisten_fail:
    lea rdi, [rip + listen_error]
    call message
    mov eax, 71
.Lmain_done:
    add rsp, 72
    pop rbx
    pop rbp
    ret
.size main,.-main

/* Async signal handler: one aligned sig_atomic_t store; no library call. */
request_stop:
    mov dword ptr [rip + stop_requested], 1
    ret

/* libpq OpenSSL key callback: RDI=buffer, ESI=capacity, RDX=connection.
 * Output EAX=0 refuses encrypted keys. No calls, allocation, or stack use.
 * Changes caller-saved registers only; writes one byte when capacity permits. */
refuse_key_password:
    test esi, esi
    jle .Lkey_refused
    mov byte ptr [rdi], 0
.Lkey_refused:
    xor eax, eax
    ret

/* Input RDI=fixed NUL-terminated error. Output none; errors cannot recurse.
 * Preserves callee-saved registers; changes caller-saved registers. Stack 24.
 * Linux write handles short writes and EINTR. No database text is accepted. */
message:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call strlen@PLT
    mov r13, rax
.Lmessage_write:
    test r13, r13
    jz .Lmessage_done
    mov eax, 1
    mov edi, 2
    mov rsi, r12
    mov rdx, r13
    syscall
    cmp rax, -4
    je .Lmessage_write
    test rax, rax
    jle .Lmessage_done
    add r12, rax
    sub r13, rax
    jmp .Lmessage_write
.Lmessage_done:
    pop r13
    pop r12
    pop rbx
    ret

/* Input RDI=configuration path. Output EAX=1 or 0. Callee-saved preserved.
 * Uses direct Linux calls. Reads <=4097 bytes, requires EOF, a regular
 * owner-only file owned by this UID or root, and no embedded NUL. One final
 * LF is accepted. The 4098-byte global buffer is initialized before threads. */
read_config:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 160
.Lconfig_open:
    mov eax, 2
    mov esi, 0xa0800             /* O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK */
    xor edx, edx
    syscall
    cmp rax, -4
    je .Lconfig_open
    test rax, rax
    js .Lconfig_bad
    mov rbx, rax
.Lconfig_stat:
    mov eax, 5
    mov rdi, rbx
    mov rsi, rsp
    syscall
    cmp rax, -4
    je .Lconfig_stat
    test rax, rax
    js .Lconfig_close_bad
    mov eax, [rsp + 24]
    mov ecx, eax
    and eax, 61440
    cmp eax, 32768
    jne .Lconfig_close_bad
    test ecx, 63                 /* no group or other permissions */
    jnz .Lconfig_close_bad
    mov eax, 102
    syscall
    cmp dword ptr [rsp + 28], 0
    je .Lconfig_read_start
    cmp [rsp + 28], eax
    jne .Lconfig_close_bad
.Lconfig_read_start:
    xor r12d, r12d
.Lconfig_read:
    xor eax, eax
    mov rdi, rbx
    lea rsi, [rip + db_config]
    add rsi, r12
    mov edx, CONFIG_LIMIT + 1
    sub rdx, r12
    syscall
    cmp rax, -4
    je .Lconfig_read
    test rax, rax
    js .Lconfig_close_bad
    jz .Lconfig_eof
    add r12, rax
    cmp r12, CONFIG_LIMIT
    ja .Lconfig_close_bad
    jmp .Lconfig_read
.Lconfig_eof:
    mov eax, 3
    mov rdi, rbx
    syscall
    test r12, r12
    jz .Lconfig_bad
    lea rdx, [rip + db_config]
    cmp byte ptr [rdx + r12 - 1], 10
    jne .Lconfig_scan
    dec r12
.Lconfig_scan:
    test r12, r12
    jz .Lconfig_bad
    xor ecx, ecx
.Lconfig_chars:
    movzx eax, byte ptr [rdx + rcx]
    cmp eax, 32
    jb .Lconfig_bad
    cmp eax, 126
    ja .Lconfig_bad
    inc rcx
    cmp rcx, r12
    jb .Lconfig_chars
    mov byte ptr [rdx + r12], 0
    mov eax, 1
    jmp .Lconfig_return
.Lconfig_close_bad:
    mov eax, 3
    mov rdi, rbx
    syscall
.Lconfig_bad:
    xor eax, eax
.Lconfig_return:
    add rsp, 160
    pop r12
    pop rbx
    pop rbp
    ret

/* Output RAX=monotonic milliseconds, -1 on failure. Stack: one timespec. */
clock_ms:
    sub rsp, 24
    mov edi, 1
    mov rsi, rsp
    call clock_gettime@PLT
    test eax, eax
    jnz .Lclock_bad
    imul rcx, [rsp], 1000
    mov rax, [rsp + 8]
    xor edx, edx
    mov esi, 1000000
    div rsi
    add rax, rcx
    add rsp, 24
    ret
.Lclock_bad:
    mov rax, -1
    add rsp, 24
    ret

/* Input RDI=PGconn, ESI=poll events, RDX=absolute monotonic deadline.
 * Output EAX=1 for requested readiness, else 0. Retries EINTR until deadline.
 * Owns a 16-byte pollfd workspace; does not share a connection across threads. */
wait_database:
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    call PQsocket@PLT
    test eax, eax
    js .Lwait_bad
    mov [rsp], eax
    mov [rsp + 4], r12w
.Lwait_again:
    mov word ptr [rsp + 6], 0
    call clock_ms
    test rax, rax
    js .Lwait_bad
    mov rdx, r13
    sub rdx, rax
    jle .Lwait_bad
    mov rdi, rsp
    mov esi, 1
    call poll@PLT
    test eax, eax
    jz .Lwait_bad
    js .Lwait_errno
    movzx eax, word ptr [rsp + 6]
    test eax, 56                 /* POLLERR | POLLHUP | POLLNVAL */
    jnz .Lwait_bad
    test eax, r12d
    jz .Lwait_again
    mov eax, 1
    jmp .Lwait_return
.Lwait_errno:
    call __errno_location@PLT
    cmp dword ptr [rax], 4
    je .Lwait_again
.Lwait_bad:
    xor eax, eax
.Lwait_return:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

/* Input RDI=fixed SQL or NULL for guard only; ESI=count, RDX=parameters,
 * ECX=positive result byte limit, at most MAX_JSON. Borrows all arguments.
 * Output RAX=owned PGresult with one non-null field, or NULL. Caller PQclear.
 * One connection runs BEGIN READ ONLY, the exact guard, then the optional SQL.
 * Every command drains before the next. One absolute deadline covers all I/O.
 * PQfinish closes the transaction on every path; the result remains owned.
 * libpq handles framing, parameter encoding, authentication, and any TLS.
 * Arguments remain valid for this call. Callee-saved registers preserved.
 * Stack: 56 bytes local/outgoing arguments plus six saved registers. */
database_query:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov qword ptr [rbp - 48], 0
    mov dword ptr [rbp - 56], 0  /* phase: BEGIN, guard, export */
    mov [rbp - 64], ecx
    xor r15d, r15d
    test ecx, ecx
    jle .Ldb_failed
    cmp ecx, MAX_JSON
    ja .Ldb_failed
    call clock_ms
    test rax, rax
    js .Ldb_failed
    lea r14, [rax + DB_DEADLINE_MS]
    lea rdi, [rip + db_keys]
    lea rsi, [rip + db_values]
    mov edx, 1
    call PQconnectStartParams@PLT
    test rax, rax
    jz .Ldb_failed
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + ignore_notice]
    xor edx, edx
    call PQsetNoticeProcessor@PLT
.Ldb_connect:
    call clock_ms
    cmp rax, r14
    jae .Ldb_failed
    test rax, rax
    js .Ldb_failed
    mov rdi, r15
    call PQconnectPoll@PLT
    cmp eax, 3                   /* PGRES_POLLING_OK */
    je .Ldb_connected
    mov esi, 1                   /* POLLIN */
    cmp eax, 1
    je .Ldb_connect_wait
    mov esi, 4                   /* POLLOUT */
    cmp eax, 2
    jne .Ldb_failed
.Ldb_connect_wait:
    mov rdi, r15
    mov rdx, r14
    call wait_database
    test eax, eax
    jz .Ldb_failed
    jmp .Ldb_connect
.Ldb_connected:
    mov rdi, r15
    call PQsslInUse@PLT
    cmp eax, 1
    jne .Ldb_failed
    mov rdi, r15
    mov esi, 1
    call PQsetnonblocking@PLT
    test eax, eax
    jnz .Ldb_failed
.Ldb_send:
    call clock_ms
    test rax, rax
    js .Ldb_failed
    cmp rax, r14
    jae .Ldb_failed
    mov rdi, r15
    lea rsi, [rip + begin_read_only]
    xor edx, edx
    xor r8d, r8d
    cmp dword ptr [rbp - 56], 0
    je .Ldb_send_selected
    lea rsi, [rip + guard_sql]
    cmp dword ptr [rbp - 56], 1
    je .Ldb_send_selected
    mov rsi, rbx
    mov edx, r12d
    mov r8, r13
.Ldb_send_selected:
    xor ecx, ecx                 /* infer types in the fixed SQL */
    xor r9d, r9d                /* null lengths: text parameters */
    mov qword ptr [rsp], 0       /* text formats */
    mov qword ptr [rsp + 8], 0   /* text result */
    call PQsendQueryParams@PLT
    cmp eax, 1
    jne .Ldb_failed
.Ldb_flush:
    mov rdi, r15
    call PQflush@PLT
    test eax, eax
    jz .Ldb_read
    cmp eax, 1
    jne .Ldb_failed
    mov rdi, r15
    mov esi, 4
    mov rdx, r14
    call wait_database
    test eax, eax
    jz .Ldb_failed
    jmp .Ldb_flush
.Ldb_read:
    call clock_ms
    test rax, rax
    js .Ldb_failed
    cmp rax, r14
    jae .Ldb_failed
    mov rdi, r15
    call PQconsumeInput@PLT
    cmp eax, 1
    jne .Ldb_failed
    mov rdi, r15
    call PQisBusy@PLT
    test eax, eax
    jz .Ldb_result
    mov rdi, r15
    mov esi, 1
    mov rdx, r14
    call wait_database
    test eax, eax
    jz .Ldb_failed
    jmp .Ldb_read
.Ldb_result:
    mov rdi, r15
    call PQgetResult@PLT
    test rax, rax
    jz .Ldb_complete
    cmp qword ptr [rbp - 48], 0
    jne .Ldb_extra_result
    mov [rbp - 48], rax
    mov rdi, rax
    call PQresultStatus@PLT
    cmp dword ptr [rbp - 56], 0
    jne .Ldb_tuple_status
    cmp eax, 1                   /* PGRES_COMMAND_OK for BEGIN */
    jne .Ldb_failed
    jmp .Ldb_read
.Ldb_tuple_status:
    cmp eax, 2                   /* PGRES_TUPLES_OK */
    jne .Ldb_failed
    mov rdi, [rbp - 48]
    call PQntuples@PLT
    cmp eax, 1
    jne .Ldb_failed
    mov rdi, [rbp - 48]
    call PQnfields@PLT
    cmp eax, 1
    jne .Ldb_failed
    mov rdi, [rbp - 48]
    xor esi, esi
    xor edx, edx
    call PQgetisnull@PLT
    test eax, eax
    jnz .Ldb_failed
    mov rdi, [rbp - 48]
    xor esi, esi
    xor edx, edx
    call PQgetlength@PLT
    test eax, eax
    jle .Ldb_failed
    cmp dword ptr [rbp - 56], 1
    jne .Ldb_export_length
    cmp eax, 1
    jne .Ldb_failed
    mov rdi, [rbp - 48]
    xor esi, esi
    xor edx, edx
    call PQgetvalue@PLT
    cmp word ptr [rax], 49       /* exact '1', NUL */
    jne .Ldb_failed
    jmp .Ldb_read
.Ldb_export_length:
    cmp eax, [rbp - 64]
    ja .Ldb_failed
    jmp .Ldb_read                /* drain to NULL before closing */
.Ldb_extra_result:
    mov rdi, rax
    call PQclear@PLT
    jmp .Ldb_failed
.Ldb_complete:
    cmp qword ptr [rbp - 48], 0
    je .Ldb_failed
    cmp dword ptr [rbp - 56], 2
    je .Ldb_finish
    cmp dword ptr [rbp - 56], 1
    jne .Ldb_next
    test rbx, rbx
    jz .Ldb_finish
.Ldb_next:
    mov rdi, [rbp - 48]
    call PQclear@PLT
    mov qword ptr [rbp - 48], 0
    inc dword ptr [rbp - 56]
    jmp .Ldb_send
.Ldb_finish:
    mov rdi, r15
    call PQfinish@PLT
    mov rax, [rbp - 48]
    jmp .Ldb_return
.Ldb_failed:
    mov rdi, [rbp - 48]
    test rdi, rdi
    jz .Ldb_close
    call PQclear@PLT
.Ldb_close:
    test r15, r15
    jz .Ldb_null
    mov rdi, r15
    call PQfinish@PLT
.Ldb_null:
    xor eax, eax
.Ldb_return:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

ignore_notice:
    ret

/* Output EAX=1 only when the fixed guard returns exactly '1'. */
database_ready:
    push rbx
    xor edi, edi
    xor esi, esi
    xor edx, edx
    mov ecx, 1
    call database_query
    test rax, rax
    jz .Lready_no
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call PQgetvalue@PLT
    cmp word ptr [rax], 49       /* bytes '1', NUL */
    setz al
    movzx eax, al
    push rax
    sub rsp, 8
    mov rdi, rbx
    call PQclear@PLT
    add rsp, 8
    pop rax
    pop rbx
    ret
.Lready_no:
    xor eax, eax
    pop rbx
    ret

/* MHD raw-URI callback: returns opaque marker 1 if the URI is too long. */
uri_bound:
    mov rdi, rsi
    mov esi, 2049
    sub rsp, 8
    call strnlen@PLT
    cmp rax, 2048
    seta al
    movzx eax, al
    add rsp, 8
    ret

/* Header iterator. CLS points to {count:u64, bytes:u64, bad:u64}.
 * No header values are logged or copied. Stack none, caller-saved only. */
header_bound:
    inc qword ptr [rdi]
    add [rdi + 8], rcx
    add [rdi + 8], r9
    cmp qword ptr [rdi], 64
    ja .Lheader_bad
    cmp qword ptr [rdi + 8], 16384
    ja .Lheader_bad
    mov eax, 1
    ret
.Lheader_bad:
    mov qword ptr [rdi + 16], 1
    xor eax, eax
    ret

/* Query iterator: any query field is unsupported. Caller-saved only. */
query_value:
    mov qword ptr [rdi], 1
    xor eax, eax
    ret

/* MHD access callback; C signature is checked against the pinned header.
 * Uses 104 local bytes plus six saved registers. Borrows request strings only during this call.
 * Each database operation owns its own connection; global data is immutable.
 * No request body, file path, database error, or query text enters a log. */
handle_request:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 104
    mov rbx, rsi                 /* MHD connection */
    mov r12, rdx                 /* path */
    mov r13, rcx                 /* method */
    mov rax, [rbp + 24]          /* req_cls */
    cmp qword ptr [rax], 2
    je .Lhandled
    cmp qword ptr [rax], 1
    je .Luri_error
    mov qword ptr [rax], 2
    mov rdi, r13
    lea rsi, [rip + get_method]
    call strcmp@PLT
    test eax, eax
    jnz .Lmethod_error
    mov qword ptr [rbp - 64], 0
    mov qword ptr [rbp - 56], 0
    mov qword ptr [rbp - 48], 0
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + header_bound]
    lea rcx, [rbp - 64]
    call MHD_get_connection_values_n@PLT
    cmp qword ptr [rbp - 48], 0
    jne .Lheaders_error
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + header_te]
    call MHD_lookup_connection_value@PLT
    test rax, rax
    jnz .Lbody_error
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + header_cl]
    call MHD_lookup_connection_value@PLT
    test rax, rax
    jz .Lroute
    cmp word ptr [rax], 48       /* exact '0', NUL */
    jne .Lbody_error
.Lroute:
    mov qword ptr [rbp - 72], 0
    mov rdi, rbx
    mov esi, 8
    lea rdx, [rip + query_value]
    lea rcx, [rbp - 72]
    call MHD_get_connection_values_n@PLT
    cmp qword ptr [rbp - 72], 0
    jne .Lquery_error
    mov rdi, r12
    lea rsi, [rip + path_live]
    call strcmp@PLT
    test eax, eax
    jz .Llive
    mov rdi, r12
    lea rsi, [rip + path_ready]
    call strcmp@PLT
    test eax, eax
    jz .Lready
    mov rdi, r12
    lea rsi, [rip + path_status]
    call strcmp@PLT
    test eax, eax
    jz .Lstatus
    mov rdi, r12
    lea rsi, [rip + path_linux]
    call strcmp@PLT
    test eax, eax
    jz .Llinux_export
    mov rdi, r12
    lea rsi, [rip + path_macos]
    call strcmp@PLT
    test eax, eax
    jz .Lmacos_export
    mov rdi, r12
    lea rsi, [rip + path_index]
    call strcmp@PLT
    test eax, eax
    jz .Ljson_export
    jmp .Lnot_found
.Llive:
    lea rdx, [rip + live_body]
    mov esi, 200
    jmp .Lfixed_response
.Lready:
    cmp dword ptr [rip + stop_requested], 0
    jne .Lunavailable
    call database_ready
    test eax, eax
    jz .Lunavailable
    lea rdx, [rip + ready_body]
    mov esi, 200
    jmp .Lfixed_response
.Lstatus:
    lea rdx, [rip + status_body]
    mov esi, 200
    jmp .Lfixed_response
.Llinux_export:
    lea rax, [rip + path_linux]
    jmp .Ltsv_export
.Lmacos_export:
    lea rax, [rip + path_macos]
.Ltsv_export:
    mov r14d, MAX_TSV
    lea r15, [rip + type_tsv]
    jmp .Lcatalog_export
.Ljson_export:
    lea rax, [rip + path_index]
    mov r14d, MAX_JSON
    lea r15, [rip + type_index]
.Lcatalog_export:
    /* Only router-owned literals enter the borrowed parameter array. */
    mov [rbp - 80], rax
    cmp dword ptr [rip + stop_requested], 0
    jne .Lunavailable
    lea rdi, [rip + export_sql]
    mov esi, 1
    lea rdx, [rbp - 80]
    mov ecx, r14d
    call database_query
    test rax, rax
    jz .Lunavailable
    mov r12, rax                /* own PGresult until MHD has copied it */
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call PQgetlength@PLT
    mov r14d, eax
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call PQgetvalue@PLT
    mov rdi, rbx
    mov esi, 200
    mov rdx, rax
    mov ecx, r14d
    mov r8, r15
    call queue_response
    mov r13d, eax
    mov rdi, r12
    call PQclear@PLT
    mov eax, r13d
    jmp .Lrequest_return
.Lnot_found:
    lea rdx, [rip + not_found_body]
    mov esi, 404
    jmp .Lfixed_response
.Lmethod_error:
    lea rdx, [rip + bad_method_body]
    mov esi, 405
    jmp .Lfixed_response
.Lbody_error:
    lea rdx, [rip + bad_body]
    mov esi, 400
    jmp .Lfixed_response
.Lheaders_error:
    lea rdx, [rip + headers_body]
    mov esi, 431
    jmp .Lfixed_response
.Lquery_error:
    lea rdx, [rip + bad_query_body]
    mov esi, 400
    jmp .Lfixed_response
.Luri_error:
    mov qword ptr [rax], 2
    lea rdx, [rip + uri_body]
    mov esi, 414
    jmp .Lfixed_response
.Lunavailable:
    lea rdx, [rip + unavailable_body]
    mov esi, 503
.Lfixed_response:
    mov rdi, rbx
    call queue_json
    jmp .Lrequest_return
.Lhandled:
    mov eax, 1
.Lrequest_return:
    add rsp, 104
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

/* Fixed JSON wrapper: RDI=connection, ESI=status, RDX=NUL body <=MAX_REPLY.
 * EAX=MHD_Result. Preserves callee-saved registers; stack 24 saved bytes.
 * The common response path copies the body before returning. */
queue_json:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, rdx
    mov esi, MAX_REPLY + 1
    call strnlen@PLT
    cmp rax, MAX_REPLY
    ja .Lfixed_queue_no
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    mov rcx, rax
    lea r8, [rip + type_json]
    pop r13
    pop r12
    pop rbx
    jmp queue_response
.Lfixed_queue_no:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=connection, ESI=status, RDX=borrowed bytes, RCX=length <=MAX_JSON,
 * R8=fixed content type. EAX=MHD_Result. MHD copies before return.
 * Owns/destroys the response on every path; allocation failure closes HTTP.
 * Callee-saved preserved; stack 16 local bytes plus five saved registers. */
queue_response:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov [rsp], r8
    test rcx, rcx
    jz .Lqueue_no
    cmp rcx, MAX_JSON
    ja .Lqueue_no
    mov rdi, rcx
    mov rsi, r13
    mov edx, 2
    call MHD_create_response_from_buffer@PLT
    test rax, rax
    jz .Lqueue_no
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + header_type]
    mov rdx, [rsp]
    call MHD_add_response_header@PLT
    cmp eax, 1
    jne .Lqueue_destroy_no
    mov rdi, r14
    lea rsi, [rip + header_cache]
    lea rdx, [rip + cache_no_store]
    call MHD_add_response_header@PLT
    cmp eax, 1
    jne .Lqueue_destroy_no
    mov rdi, r14
    lea rsi, [rip + header_nosniff]
    lea rdx, [rip + nosniff]
    call MHD_add_response_header@PLT
    cmp eax, 1
    jne .Lqueue_destroy_no
    mov rdi, r14
    lea rsi, [rip + header_connection]
    lea rdx, [rip + close_value]
    call MHD_add_response_header@PLT
    cmp eax, 1
    jne .Lqueue_destroy_no
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r14
    call MHD_queue_response@PLT
    mov r15d, eax
    mov rdi, r14
    call MHD_destroy_response@PLT
    mov eax, r15d
    jmp .Lqueue_return
.Lqueue_destroy_no:
    mov rdi, r14
    call MHD_destroy_response@PLT
.Lqueue_no:
    xor eax, eax
.Lqueue_return:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.section .note.GNU-stack,"",@progbits
