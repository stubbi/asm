/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Linux x86-64 System V ABI. Configuration is immutable before HTTP threads.
 * libpq parses the connection URL. This layer restricts its authority.
 */
.intel_syntax noprefix

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

.section .bss
.balign 8
database_hostname: .zero 254

.section .text
.globl clear_pg_environment
.type clear_pg_environment,@function
/* Input none. Output EAX=1, or 0 if a name exceeds 255 bytes/unset fails.
 * Removes every PG-prefixed environment variable before library threads.
 * Uses 272 local bytes and preserves RBX/R12. No environment value is logged.
 * getenv/unsetenv use the system C runtime; environ is reloaded after a change. */
clear_pg_environment:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 272
.Lenv_restart:
    mov rax, [rip + environ@GOTPCREL]
    mov rbx, [rax]
.Lenv_next:
    mov r12, [rbx]
    test r12, r12
    jz .Lenv_ok
    cmp byte ptr [r12], 'P'
    jne .Lenv_advance
    cmp byte ptr [r12 + 1], 'G'
    jne .Lenv_advance
    xor ecx, ecx
.Lenv_name:
    cmp ecx, 255
    ja .Lenv_bad
    mov al, [r12 + rcx]
    test al, al
    jz .Lenv_bad
    cmp al, '='
    je .Lenv_unset
    mov [rsp + rcx], al
    inc ecx
    jmp .Lenv_name
.Lenv_unset:
    mov byte ptr [rsp + rcx], 0
    mov rdi, rsp
    call unsetenv@PLT
    test eax, eax
    jnz .Lenv_bad
    jmp .Lenv_restart
.Lenv_advance:
    add rbx, 8
    jmp .Lenv_next
.Lenv_ok:
    mov eax, 1
    jmp .Lenv_done
.Lenv_bad:
    xor eax, eax
.Lenv_done:
    add rsp, 272
    pop r12
    pop rbx
    pop rbp
    ret
.size clear_pg_environment,.-clear_pg_environment

.globl parse_bind
.type parse_bind,@function
/* RDI=environment string or NULL; RSI=owned 16-byte sockaddr_in.
 * EAX=1 or 0. Accepts an IPv4 literal and a decimal port in 1024..65535.
 * Preserves callee-saved registers; changes caller-saved. Stack 64 + saves.
 * Does not resolve hostnames or modify the environment string. */
parse_bind:
    push rbx
    push r12
    push r13
    sub rsp, 64
    test rdi, rdi
    jz .Lbind_bad
    mov rbx, rdi
    mov r12, rsi
    mov esi, 23
    call strnlen@PLT
    cmp eax, 22
    ja .Lbind_bad
    test eax, eax
    jz .Lbind_bad
    lea rdx, [rax + 1]
    mov rdi, rsp
    mov rsi, rbx
    call memcpy@PLT
    mov rdi, rsp
    mov esi, ':'
    call strchr@PLT
    test rax, rax
    jz .Lbind_bad
    mov byte ptr [rax], 0
    lea r13, [rax + 1]
    mov edi, 2
    mov rsi, rsp
    lea rdx, [r12 + 4]
    call inet_pton@PLT
    cmp eax, 1
    jne .Lbind_bad
    mov rdi, r13
    call port_number
    cmp eax, 1024
    jb .Lbind_bad
    xchg al, ah
    mov [r12 + 2], ax
    mov eax, 1
    jmp .Lbind_done
.Lbind_bad:
    xor eax, eax
.Lbind_done:
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret
.size parse_bind,.-parse_bind

/* RDI=NUL-terminated decimal. EAX=1..65535 or 0. Caller-saved only, no stack.
 * At most five characters are read before rejection. Leading zero is rejected. */
port_number:
    cmp byte ptr [rdi], '0'
    je .Lport_bad
    xor eax, eax
    xor ecx, ecx
.Lport_next:
    movzx edx, byte ptr [rdi + rcx]
    test edx, edx
    jz .Lport_return
    sub edx, '0'
    cmp edx, 9
    ja .Lport_bad
    imul eax, eax, 10
    add eax, edx
    cmp eax, 65535
    ja .Lport_bad
    inc ecx
    cmp ecx, 5
    ja .Lport_bad
    jmp .Lport_next
.Lport_bad:
    xor eax, eax
.Lport_return:
    ret

/* RDI=trusted ASCII connection URL, <=4096 bytes and NUL-terminated.
 * EAX=1 iff four TLS keys occur once, with an optional unique hostaddr. Preserves callee-saved.
 * Values are parsed later by libpq. Stack 8 + RBX/R12/R13/R14.
 * Checks raw keys before libpq can normalize duplicate query options. */
check_query:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov esi, '?'
    call strchr@PLT
    test rax, rax
    jz .Lquery_invalid
    lea rbx, [rax + 1]
    xor r12d, r12d
.Lquery_field:
    lea r13, [rip + query_fields]
.Lquery_candidate:
    mov rsi, [r13]
    test rsi, rsi
    jz .Lquery_invalid
    mov rdi, rbx
    mov rdx, [r13 + 8]
    call strncmp@PLT
    test eax, eax
    jz .Lquery_match
    add r13, 24
    jmp .Lquery_candidate
.Lquery_match:
    mov r14, [r13 + 16]
    test r12, r14
    jnz .Lquery_invalid
    or r12, r14
    add rbx, [r13 + 8]
    cmp byte ptr [rbx], 0
    je .Lquery_invalid
    cmp byte ptr [rbx], '&'
    je .Lquery_invalid
    mov rdi, rbx
    mov esi, '&'
    call strchr@PLT
    test rax, rax
    jz .Lquery_end
    lea rbx, [rax + 1]
    jmp .Lquery_field
.Lquery_end:
    xor eax, eax
    mov rdx, r12
    and edx, 15
    cmp edx, 15
    sete al
    jmp .Lquery_done
.Lquery_invalid:
    xor eax, eax
.Lquery_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.globl validate_database_config
.type validate_database_config,@function
/* Input: immutable db_config[4098] from the private-file reader.
 * EAX=1 or 0. No connection is opened. PQconninfoParse owns its result until
 * PQconninfoFree. An error message is freed without logging its contents.
 * Requires explicit user/database/host/port, optional IPv4 hostaddr, verify-full,
 * CA/client certificate/key paths. Passwords and other options are rejected.
 * Callee-saved preserved. Stack 24 bytes plus six saved registers.
 * PQconninfoOption ABI (56 bytes, value at 24) is checked at build time. */
validate_database_config:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    lea rdi, [rip + db_config]
    lea rsi, [rip + uri_prefix]
    mov edx, 13
    call strncmp@PLT
    test eax, eax
    jnz .Lpolicy_no_array
    lea rdi, [rip + db_config]
    call check_query
    test eax, eax
    jz .Lpolicy_no_array
    mov qword ptr [rsp], 0
    lea rdi, [rip + db_config]
    mov rsi, rsp
    call PQconninfoParse@PLT
    test rax, rax
    jz .Lpolicy_parse_error
    mov r15, rax
    mov rbx, rax
    xor r12d, r12d
.Lpolicy_option:
    cmp qword ptr [rbx], 0
    je .Lpolicy_finish
    mov r13, [rbx + 24]
    test r13, r13
    jz .Lpolicy_next
    lea r14, [rip + allowed]
.Lpolicy_candidate:
    mov rsi, [r14]
    test rsi, rsi
    jz .Lpolicy_bad
    mov rdi, [rbx]
    call strcmp@PLT
    test eax, eax
    jz .Lpolicy_value
    add r14, 24
    jmp .Lpolicy_candidate
.Lpolicy_value:
    mov rax, [r14 + 8]
    test r12, rax
    jnz .Lpolicy_bad
    or r12, rax
    mov rax, [r14 + 16]
    mov rdi, r13
    test eax, eax
    jz .Lpolicy_identifier
    cmp eax, 1
    je .Lpolicy_hostname
    cmp eax, 2
    je .Lpolicy_address
    cmp eax, 3
    je .Lpolicy_port
    cmp eax, 4
    je .Lpolicy_mode
    /* Absolute explicit certificate paths. No decoded controls are accepted. */
    cmp byte ptr [r13], '/'
    jne .Lpolicy_bad
    mov esi, 1025
    call strnlen@PLT
    cmp rax, 1024
    ja .Lpolicy_bad
    mov rcx, rax
    xor edx, edx
.Lpolicy_path_char:
    cmp rdx, rcx
    jae .Lpolicy_next
    movzx eax, byte ptr [r13 + rdx]
    cmp eax, 32
    jb .Lpolicy_bad
    cmp eax, 126
    ja .Lpolicy_bad
    inc rdx
    jmp .Lpolicy_path_char
.Lpolicy_identifier:
    call identifier
    test eax, eax
    jz .Lpolicy_bad
    jmp .Lpolicy_next
.Lpolicy_hostname:
    call hostname
    test eax, eax
    jz .Lpolicy_bad
    mov rdi, r13
    call strlen@PLT
    lea rdx, [rax + 1]
    lea rdi, [rip + database_hostname]
    mov rsi, r13
    call memcpy@PLT
    jmp .Lpolicy_next
.Lpolicy_address:
    mov rsi, r13
    mov edi, 2
    lea rdx, [rsp + 8]
    call inet_pton@PLT
    cmp eax, 1
    jne .Lpolicy_bad
    jmp .Lpolicy_next
.Lpolicy_port:
    call port_number
    test eax, eax
    jz .Lpolicy_bad
    jmp .Lpolicy_next
.Lpolicy_mode:
    lea rsi, [rip + verify_full]
    call strcmp@PLT
    test eax, eax
    jnz .Lpolicy_bad
.Lpolicy_next:
    add rbx, 56
    jmp .Lpolicy_option
.Lpolicy_finish:
    mov rax, r12
    and eax, 503
    cmp eax, 503
    jne .Lpolicy_bad
    mov ebx, 1
    jmp .Lpolicy_free
.Lpolicy_bad:
    xor ebx, ebx
.Lpolicy_free:
    mov rdi, r15
    call PQconninfoFree@PLT
    mov eax, ebx
    test ebx, ebx
    jz .Lpolicy_return
    test r12, 8
    jnz .Lpolicy_return
    lea rdi, [rip + database_hostname]
    call resolve_database_address
    jmp .Lpolicy_return
.Lpolicy_parse_error:
    mov rdi, [rsp]
    test rdi, rdi
    jz .Lpolicy_no_array
    call PQfreemem@PLT
.Lpolicy_no_array:
    xor eax, eax
.Lpolicy_return:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.size validate_database_config,.-validate_database_config

/* RDI=decoded SQL identifier. EAX=1 or 0. ASCII lower case/underscore first,
 * then lower case/digits/underscore, 1..63 bytes. Caller-saved only; no stack. */
identifier:
    movzx eax, byte ptr [rdi]
    cmp eax, '_'
    je .Lidentifier_loop_start
    cmp eax, 'a'
    jb .Ltext_bad
    cmp eax, 'z'
    ja .Ltext_bad
.Lidentifier_loop_start:
    xor ecx, ecx
.Lidentifier_char:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Ltext_ok
    cmp ecx, 63
    jae .Ltext_bad
    cmp eax, '_'
    je .Lidentifier_next
    cmp eax, '0'
    jb .Ltext_bad
    cmp eax, '9'
    jbe .Lidentifier_next
    cmp eax, 'a'
    jb .Ltext_bad
    cmp eax, 'z'
    ja .Ltext_bad
.Lidentifier_next:
    inc ecx
    jmp .Lidentifier_char

/* RDI=decoded verification hostname. EAX=1 or 0; no DNS call. At most 253
 * ASCII letters/digits/dots/hyphens; no host lists. Caller-saved only. */
hostname:
    xor ecx, ecx
.Lhostname_char:
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lhostname_end
    cmp ecx, 253
    jae .Ltext_bad
    cmp eax, '.'
    je .Lhostname_next
    cmp eax, '-'
    je .Lhostname_next
    cmp eax, '0'
    jb .Ltext_bad
    cmp eax, '9'
    jbe .Lhostname_next
    or eax, 32
    cmp eax, 'a'
    jb .Ltext_bad
    cmp eax, 'z'
    ja .Ltext_bad
.Lhostname_next:
    inc ecx
    jmp .Lhostname_char
.Lhostname_end:
    test ecx, ecx
    jz .Ltext_bad
.Ltext_ok:
    mov eax, 1
    ret
.Ltext_bad:
    xor eax, eax
    ret

.section .note.GNU-stack,"",@progbits
