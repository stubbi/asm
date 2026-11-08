/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Included only by the x86-64 Linux ASM_PUBLISHER runtime.
 * Application state is assembly. MHD, libpq and OpenSSL own their protocols.
 * Every request owns one zeroed P_SIZE allocation until completion callback.
 */
.equ P_STATE, 0
.equ P_ROUTE, 8
.equ P_DEADLINE, 16
.equ P_EXPECT, 24
.equ P_RECEIVED, 32
.equ P_FD, 40
.equ P_MD, 48
.equ P_COUNT, 56
.equ P_HEADER_BYTES, 64
.equ P_BAD, 72
.equ P_AUTH_N, 80
.equ P_CL_N, 88
.equ P_TYPE_N, 96
.equ P_KEY_N, 104
.equ P_TE_N, 112
.equ P_ERROR_BODY, 112 /* TE is forbidden; reuse after header admission */
.equ P_AUTH, 120
.equ P_KEY, 216
.equ P_TYPE, 256
.equ P_CL, 288
.equ P_TASK, 320
.equ P_DIGEST, 360
.equ P_TEMP, 432
.equ P_FINAL, 480
.equ P_LENGTH, 584
.equ P_LOCATION, 608
.equ P_BUFFER, 672
.equ P_SIZE, 66224
.equ P_MAX_OBJECT, 67108864
.equ P_TIMEOUT, 60000

.section .rodata
publisher_env_root: .asciz "ASM_UPLOAD_ROOT"
publisher_slash: .asciz "/"
publisher_post: .asciz "POST"
publisher_put: .asciz "PUT"
publisher_path: .asciz "/api/v2/publications"
publisher_prefix: .asciz "/api/v2/publications/"
publisher_artifacts: .asciz "/artifacts/"
publisher_bearer: .ascii "Bearer asm_pub_v1_"
publisher_hex_chars: .ascii "0123456789abcdef"
publisher_header_auth: .asciz "Authorization"
publisher_header_key: .asciz "Idempotency-Key"
publisher_header_location: .asciz "Location"
publisher_header_retry: .asciz "Retry-After"
publisher_retry_value: .asciz "1"
publisher_header_challenge: .asciz "WWW-Authenticate"
publisher_challenge_value: .asciz "Bearer realm=\"Asm publication\""
publisher_json: .asciz "application/json"
publisher_octets: .asciz "application/octet-stream"
publisher_problem: .asciz "application/problem+json"
publisher_create_sql: .asciz "SELECT * FROM asm_publication.create_publication($1::text,$2::text,$3::text)"
publisher_read_sql: .asciz "SELECT * FROM asm_publication.read_publication($1::text,$2::text)"
publisher_authorize_sql: .asciz "SELECT * FROM asm_publication.authorize_upload($1::text,$2::text,$3::text,$4::bigint)"
publisher_receipt_sql: .asciz "SELECT * FROM asm_publication.receipt_upload($1::text,$2::text,$3::text,$4::bigint)"
publisher_temp_prefix: .ascii ".upload-"
.macro publisher_error name, status, code, detail, retry=false
publisher_error_\name:
 .asciz "{\"type\":\"urn:asm:publication:error:\code\",\"title\":\"Publication request refused\",\"status\":\status,\"detail\":\"\detail\",\"code\":\"\code\",\"retryable\":\retry}\n"
.endm
publisher_error invalid, 400, invalid_request, "Correct the request headers, path, or body."
publisher_error auth, 401, invalid_credential, "Obtain a current scoped publication credential."
publisher_error forbidden, 403, not_authorized, "Request the required owner, package, or operation scope."
publisher_error missing, 404, task_not_found, "Check the publication task or route."
publisher_error conflict, 409, publication_conflict, "Inspect the existing task or version before retrying."
publisher_error expired, 410, upload_expired, "Create a new publication task with a current credential."
publisher_error limit, 413, limit_exceeded, "Reduce the request or object size."
publisher_error media, 415, unsupported_media_type, "Use the route's fixed content type."
publisher_error artifact, 422, artifact_invalid, "Correct the object length or digest and retry the complete object."
publisher_error admission, 429, admission_limited, "Wait for the Retry-After interval before retrying the same operation.", true
publisher_error unavailable, 503, temporarily_unavailable, "Inspect the task before retrying the same operation.", true

.section .data.rel.ro,"aw"
.balign 8
/* Only validated database statuses select these fixed public problems.
 * Private database error JSON is never copied into an HTTP response. */
publisher_public_problems:
 .quad 400,publisher_error_invalid
 .quad 401,publisher_error_auth
 .quad 403,publisher_error_forbidden
 .quad 404,publisher_error_missing
 .quad 409,publisher_error_conflict
 .quad 410,publisher_error_expired
 .quad 413,publisher_error_limit
 .quad 415,publisher_error_media
 .quad 422,publisher_error_artifact
 .quad 429,publisher_error_admission
 .quad 503,publisher_error_unavailable
 .quad 0,0
/* name, name bytes, counter offset, bounded destination offset/capacity */
publisher_headers:
 .quad publisher_header_auth,13,P_AUTH_N,P_AUTH,83
 .quad header_cl,14,P_CL_N,P_CL,21
 .quad header_type,12,P_TYPE_N,P_TYPE,32
 .quad publisher_header_key,15,P_KEY_N,P_KEY,33
 .quad header_te,17,P_TE_N,0,0
 .quad 0,0,0,0,0
.section .data
publisher_root: .quad -1

.section .text
/* No arguments. Open every absolute path component without following links.
 * EAX=1 or 0. Owns final root descriptor until process exit.
 * Stack4264 local bytes plus RBP/RBX/R12/R13.
 * Final directory must be owned by this UID and mode0700. Ancestors are
 * descriptor-walked trusted operator paths; same-UID administrators remain trusted. */
publisher_open_root:
 push rbp
 mov rbp,rsp
 push rbx
 push r12
 push r13
 sub rsp,4264
 lea rdi,[rip+publisher_env_root]
 call getenv@PLT
 test rax,rax
 jz .Lpr_bad
 mov r12,rax
 cmp byte ptr [rax],'/'
 jne .Lpr_bad
 mov rdi,rax
 mov esi,4097
 call strnlen@PLT
 cmp rax,2
 jb .Lpr_bad
 cmp rax,4096
 ja .Lpr_bad
 lea rdi,[rsp+160]
 mov rsi,r12
 lea rdx,[rax+1]
 call memcpy@PLT
 mov edi,-100
 lea rsi,[rip+publisher_slash]
 mov edx,0xb0000
 xor ecx,ecx
 call openat@PLT
 test eax,eax
 js .Lpr_bad
 mov ebx,eax
 lea r12,[rsp+161]
.Lpr_component:
 mov rdi,r12
 mov esi,'/'
 call strchr@PLT
 mov r13,rax
 test rax,rax
 jz .Lpr_open
 mov byte ptr [rax],0
.Lpr_open:
 cmp byte ptr [r12],0
 je .Lpr_close_bad
 cmp word ptr [r12],'.'
 je .Lpr_close_bad
 cmp byte ptr [r12],'.'
 jne .Lpr_open_selected
 cmp word ptr [r12+1],'.'
 je .Lpr_close_bad
.Lpr_open_selected:
 mov edi,ebx
 mov rsi,r12
 mov edx,0xb0000
 xor ecx,ecx
 call openat@PLT
 test eax,eax
 js .Lpr_close_bad
 mov r12d,eax
 mov edi,ebx
 call close@PLT
 mov ebx,r12d
 test r13,r13
 jz .Lpr_final
 lea r12,[r13+1]
 jmp .Lpr_component
.Lpr_final:
 mov edi,ebx
 mov rsi,rsp
 call fstat@PLT
 test eax,eax
 jnz .Lpr_close_bad
 mov eax,[rsp+24]
 and eax,0xffff
 cmp eax,0x41c0
 jne .Lpr_close_bad
 call getuid@PLT
 cmp eax,[rsp+28]
 jne .Lpr_close_bad
 mov [rip+publisher_root],rbx
 mov eax,1
 jmp .Lpr_done
.Lpr_close_bad:
 mov edi,ebx
 call close@PLT
.Lpr_bad:
 xor eax,eax
.Lpr_done:
 add rsp,4264
 pop r13
 pop r12
 pop rbx
 pop rbp
 ret

/* RDI=bytes, ESI=exact positive length. EAX=1 only for lowercase hex.
 * No calls, no stack, no read beyond length. Changes caller-saved only. */
publisher_hex:
 xor ecx,ecx
.Lph_loop:
 mov al,[rdi+rcx]
 cmp al,'0'
 jb .Lph_bad
 cmp al,'9'
 jbe .Lph_next
 cmp al,'a'
 jb .Lph_bad
 cmp al,'f'
 ja .Lph_bad
.Lph_next:
 inc ecx
 cmp ecx,esi
 jb .Lph_loop
 mov eax,1
 ret
.Lph_bad:
 xor eax,eax
 ret

/* MHD raw URI callback. Return marker1 for aliases, query, or oversized URI.
 * Request allocation/deadline begin after headers. No URI is logged. */
publisher_uri_bound:
 cmp byte ptr [rsi],'/'
 jne .Lpu_bad
 xor ecx,ecx
.Lpu_loop:
 cmp ecx,2048
 ja .Lpu_bad
 mov al,[rsi+rcx]
 test al,al
 jz .Lpu_good
 cmp al,33
 jb .Lpu_bad
 cmp al,126
 ja .Lpu_bad
 cmp al,'%'
 je .Lpu_bad
 cmp al,'?'
 je .Lpu_bad
 cmp al,'#'
 je .Lpu_bad
 cmp al,92
 je .Lpu_bad
 inc ecx
 jmp .Lpu_loop
.Lpu_good:
 xor eax,eax
 ret
.Lpu_bad:
 mov eax,1
 ret

/* MHD sized-header callback: CLS=owned request. Count/bound all fields.
 * Exact protected names compare case-insensitively. Duplicate protected
 * fields, TE, and excessive values fail before any DB or filesystem action.
 * Stack16 bytes plus five saves, pointers borrowed only during this call. */
publisher_header:
 push rbx
 push r12
 push r13
 push r14
 push r15
 sub rsp,16
 mov rbx,rdi
 mov r12,rdx
 mov r13,rcx
 mov r14,r8
 mov r15,r9
 inc qword ptr [rbx+P_COUNT]
 add [rbx+P_HEADER_BYTES],rcx
 add [rbx+P_HEADER_BYTES],r9
 cmp qword ptr [rbx+P_COUNT],64
 ja .Lhh_bad
 cmp qword ptr [rbx+P_HEADER_BYTES],16384
 ja .Lhh_bad
 lea rax,[rip+publisher_headers]
 mov [rsp],rax
.Lhh_candidate:
 mov rax,[rsp]
 cmp qword ptr [rax],0
 je .Lhh_good
 cmp r13,[rax+8]
 jne .Lhh_next
 mov rdi,r12
 mov rsi,[rax]
 mov rdx,r13
 call strncasecmp@PLT
 test eax,eax
 jnz .Lhh_next
 mov rax,[rsp]
 mov rcx,[rax+16]
 inc qword ptr [rbx+rcx]
 cmp qword ptr [rbx+rcx],1
 jne .Lhh_bad
 mov rcx,[rax+32]
 test rcx,rcx
 jz .Lhh_bad
 cmp r15,rcx
 jae .Lhh_bad
 mov r12,[rax+24]
 add r12,rbx
 mov rdi,r12
 mov rsi,r14
 mov rdx,r15
 call memcpy@PLT
 mov byte ptr [r12+r15],0
 jmp .Lhh_good
.Lhh_next:
 add qword ptr [rsp],40
 jmp .Lhh_candidate
.Lhh_bad:
 mov qword ptr [rbx+P_BAD],1
 xor eax,eax
 jmp .Lhh_done
.Lhh_good:
 mov eax,1
.Lhh_done:
 add rsp,16
 pop r15
 pop r14
 pop r13
 pop r12
 pop rbx
 ret

/* RDI=PGresult already constrained to one row/three columns. EAX=1/0.
 * Validate every non-null field, status digits, optional task, bounded body.
 * Preserves callee-saved. Stack 8 bytes plus four saves. */
publisher_result_valid:
 push rbx
 push r12
 push r13
 push r14
 sub rsp,8
 mov rbx,rdi
 xor r12d,r12d
.Lpv_fields:
 mov rdi,rbx
 xor esi,esi
 mov edx,r12d
 call PQgetisnull@PLT
 test eax,eax
 jnz .Lpv_bad
 inc r12d
 cmp r12d,3
 jb .Lpv_fields
 mov rdi,rbx
 xor esi,esi
 xor edx,edx
 call PQgetlength@PLT
 cmp eax,3
 jne .Lpv_bad
 mov rdi,rbx
 xor esi,esi
 xor edx,edx
 call PQgetvalue@PLT
 movzx r13d,byte ptr [rax]
 sub r13d,'0'
 cmp r13d,1
 jb .Lpv_bad
 cmp r13d,5
 ja .Lpv_bad
 imul r13d,r13d,100
 movzx ecx,byte ptr [rax+1]
 sub ecx,'0'
 cmp ecx,9
 ja .Lpv_bad
 imul ecx,ecx,10
 add r13d,ecx
 movzx ecx,byte ptr [rax+2]
 sub ecx,'0'
 cmp ecx,9
 ja .Lpv_bad
 add r13d,ecx
 mov rdi,rbx
 xor esi,esi
 mov edx,1
 call PQgetlength@PLT
 test eax,eax
 jnz .Lpv_task_present
 cmp r13d,202
 je .Lpv_bad
 jmp .Lpv_body
.Lpv_task_present:
 cmp eax,32
 jne .Lpv_bad
 mov rdi,rbx
 xor esi,esi
 mov edx,1
 call PQgetvalue@PLT
 mov rdi,rax
 mov esi,32
 call publisher_hex
 test eax,eax
 jz .Lpv_bad
.Lpv_body:
 mov rdi,rbx
 xor esi,esi
 mov edx,2
 call PQgetlength@PLT
 cmp eax,65536
 ja .Lpv_bad
 cmp r13d,204
 je .Lpv_empty
 test eax,eax
 jz .Lpv_bad
 jmp .Lpv_good
.Lpv_empty:
 test eax,eax
 jnz .Lpv_bad
.Lpv_good:
 mov eax,1
 jmp .Lpv_done
.Lpv_bad:
 xor eax,eax
.Lpv_done:
 add rsp,8
 pop r14
 pop r13
 pop r12
 pop rbx
 ret

/* Request completion owns all request resources, including error/disconnect.
 * RDX=req_cls pointer. Markers<=2 own nothing. Close/unlink partial only;
 * complete immutable files survive a later receipt/COMMIT failure. */
publisher_completed:
 push rbx
 push r12
 sub rsp,8
 mov rbx,[rdx]
 cmp rbx,2
 jbe .Lpc_done
 mov qword ptr [rdx],0
 mov rdi,[rbx+P_MD]
 test rdi,rdi
 jz .Lpc_file
 call EVP_MD_CTX_free@PLT
.Lpc_file:
 mov edi,[rbx+P_FD]
 cmp edi,-1
 je .Lpc_unlink
 call close@PLT
.Lpc_unlink:
 cmp byte ptr [rbx+P_TEMP],0
 je .Lpc_free
 mov rdi,[rip+publisher_root]
 lea rsi,[rbx+P_TEMP]
 xor edx,edx
 call unlinkat@PLT
.Lpc_free:
 mov rdi,rbx
 mov esi,P_SIZE
 call OPENSSL_cleanse@PLT
 mov rdi,rbx
 call free@PLT
.Lpc_done:
 add rsp,8
 pop r12
 pop rbx
 ret

/* RDI=request. EAX=1 after creating an owned random temporary object and
 * initializing SHA256; otherwise0. The descriptor remains in request state.
 * posix_fallocate reserves actual filesystem space before body admission.
 * Stack56 bytes plus four saves. Temporary files are always mode0600. */
publisher_stage:
 push rbx
 push r12
 push r13
 push r14
 sub rsp,56
 mov rbx,rdi
 xor r12d,r12d
.Lps_random:
 lea rdi,[rsp+r12]
 mov esi,16
 sub rsi,r12
 xor edx,edx
 call getrandom@PLT
 test rax,rax
 jg .Lps_got_random
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lps_random
 jmp .Lps_bad
.Lps_got_random:
 add r12,rax
 cmp r12,16
 jb .Lps_random
 lea rdi,[rbx+P_TEMP]
 lea rsi,[rip+publisher_temp_prefix]
 mov edx,8
 call memcpy@PLT
 xor ecx,ecx
 lea rdx,[rip+publisher_hex_chars]
.Lps_hex:
 movzx eax,byte ptr [rsp+rcx]
 mov esi,eax
 shr eax,4
 and esi,15
 mov al,[rdx+rax]
 mov [rbx+P_TEMP+8+rcx*2],al
 mov al,[rdx+rsi]
 mov [rbx+P_TEMP+9+rcx*2],al
 inc ecx
 cmp ecx,16
 jb .Lps_hex
 mov byte ptr [rbx+P_TEMP+40],0
 mov rdi,[rip+publisher_root]
 lea rsi,[rbx+P_TEMP]
 mov edx,0xa00c2
 mov ecx,384
 call openat@PLT
 test eax,eax
 js .Lps_not_owned
 mov [rbx+P_FD],rax
.Lps_reserve:
 mov edi,[rbx+P_FD]
 xor esi,esi
 mov rdx,[rbx+P_EXPECT]
 call posix_fallocate@PLT
 cmp eax,4
 je .Lps_reserve
 test eax,eax
 jnz .Lps_bad
 call EVP_MD_CTX_new@PLT
 test rax,rax
 jz .Lps_bad
 mov [rbx+P_MD],rax
 call EVP_sha256@PLT
 mov rdi,[rbx+P_MD]
 mov rsi,rax
 xor edx,edx
 call EVP_DigestInit_ex@PLT
 cmp eax,1
 jne .Lps_bad
 lea rdi,[rbx+P_FINAL]
 lea rsi,[rbx+P_TASK]
 mov edx,32
 call memcpy@PLT
 mov byte ptr [rbx+P_FINAL+32],'-'
 lea rdi,[rbx+P_FINAL+33]
 lea rsi,[rbx+P_DIGEST]
 mov edx,65
 call memcpy@PLT
 mov eax,1
 jmp .Lps_done
.Lps_not_owned:
 mov byte ptr [rbx+P_TEMP],0
.Lps_bad:
 xor eax,eax
.Lps_done:
 add rsp,56
 pop r14
 pop r13
 pop r12
 pop rbx
 ret

/* RDI=request. Finalize current EVP context and compare the complete SHA256
 * to the declared digest with mature constant-time comparison. EAX=1/0.
 * Stack112 bytes plus RBX. Digest storage is request-local, no global state. */
publisher_digest_matches:
 push rbx
 sub rsp,112
 mov rbx,rdi
 mov rdi,[rbx+P_MD]
 mov rsi,rsp
 lea rdx,[rsp+104]
 call EVP_DigestFinal_ex@PLT
 cmp eax,1
 jne .Lpd_bad
 cmp dword ptr [rsp+104],32
 jne .Lpd_bad
 xor ecx,ecx
 lea rdx,[rip+publisher_hex_chars]
.Lpd_hex:
 movzx eax,byte ptr [rsp+rcx]
 mov esi,eax
 shr eax,4
 and esi,15
 mov al,[rdx+rax]
 mov [rsp+32+rcx*2],al
 mov al,[rdx+rsi]
 mov [rsp+33+rcx*2],al
 inc ecx
 cmp ecx,32
 jb .Lpd_hex
 lea rdi,[rsp+32]
 lea rsi,[rbx+P_DIGEST]
 mov edx,64
 call CRYPTO_memcmp@PLT
 test eax,eax
 sete al
 movzx eax,al
 jmp .Lpd_done
.Lpd_bad:
 xor eax,eax
.Lpd_done:
 add rsp,112
 pop rbx
 ret

/* RDI=request, ESI=existing descriptor. Verify private regular file metadata,
 * bounded exact bytes and SHA256; fsync accepted bytes. EAX=1/0.
 * Descriptor borrowed. Uses request's buffer and EVP context. Stack168+4saves. */
publisher_existing:
 push rbx
 push r12
 push r13
 push r14
 sub rsp,168
 mov rbx,rdi
 mov r12d,esi
 mov edi,r12d
 mov rsi,rsp
 call fstat@PLT
 test eax,eax
 jnz .Lpe_bad
 mov eax,[rsp+24]
 and eax,0xf03f
 cmp eax,0x8000
 jne .Lpe_bad
 cmp qword ptr [rsp+16],1
 jne .Lpe_bad
 mov rax,[rsp+48]
 cmp rax,[rbx+P_EXPECT]
 jne .Lpe_bad
 call getuid@PLT
 cmp eax,[rsp+28]
 jne .Lpe_bad
 call EVP_sha256@PLT
 mov rdi,[rbx+P_MD]
 mov rsi,rax
 xor edx,edx
 call EVP_DigestInit_ex@PLT
 cmp eax,1
 jne .Lpe_bad
 xor r13d,r13d
.Lpe_read:
 mov edi,r12d
 lea rsi,[rbx+P_BUFFER]
 mov edx,32768
 call read@PLT
 test rax,rax
 js .Lpe_errno
 jz .Lpe_eof
 add r13,rax
 cmp r13,[rbx+P_EXPECT]
 ja .Lpe_bad
 mov rdi,[rbx+P_MD]
 lea rsi,[rbx+P_BUFFER]
 mov rdx,rax
 call EVP_DigestUpdate@PLT
 cmp eax,1
 jne .Lpe_bad
 call clock_ms
 test rax,rax
 js .Lpe_bad
 cmp rax,[rbx+P_DEADLINE]
 jae .Lpe_bad
 jmp .Lpe_read
.Lpe_errno:
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lpe_read
 jmp .Lpe_bad
.Lpe_eof:
 cmp r13,[rbx+P_EXPECT]
 jne .Lpe_bad
 mov rdi,rbx
 call publisher_digest_matches
 test eax,eax
 jz .Lpe_bad
.Lpe_sync:
 mov edi,r12d
 call fsync@PLT
 test eax,eax
 jz .Lpe_good
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lpe_sync
.Lpe_bad:
 xor eax,eax
 jmp .Lpe_done
.Lpe_good:
 mov eax,1
.Lpe_done:
 add rsp,168
 pop r14
 pop r13
 pop r12
 pop rbx
 ret

/* RDI=request. Verify received digest, fsync, conditional atomic rename and
 * directory fsync. EAX=1 durable,0 unavailable,-1 incorrect/corrupt bytes.
 * Published-stage names derive only from validated task/digest. Never replace.
 * Stack16 bytes plus three saves. Full files survive subsequent DB failures. */
publisher_finalize:
 push rbx
 push r12
 push r13
 sub rsp,16
 mov rbx,rdi
 call publisher_digest_matches
 test eax,eax
 jz .Lpf_corrupt
.Lpf_sync:
 mov edi,[rbx+P_FD]
 call fsync@PLT
 test eax,eax
 jz .Lpf_rename
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lpf_sync
 jmp .Lpf_bad
.Lpf_rename:
 mov rdi,[rip+publisher_root]
 lea rsi,[rbx+P_TEMP]
 mov rdx,rdi
 lea rcx,[rbx+P_FINAL]
 mov r8d,1
 call renameat2@PLT
 test eax,eax
 jz .Lpf_renamed
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lpf_rename
 cmp dword ptr [rax],17
 jne .Lpf_bad
 mov rdi,[rip+publisher_root]
 lea rsi,[rbx+P_FINAL]
 mov edx,0xa0800
 xor ecx,ecx
 call openat@PLT
 test eax,eax
 js .Lpf_bad
 mov r12d,eax
 mov rdi,rbx
 mov esi,eax
 call publisher_existing
 mov r13d,eax
 mov edi,r12d
 call close@PLT
 test r13d,r13d
 jz .Lpf_bad
 mov rdi,[rip+publisher_root]
 lea rsi,[rbx+P_TEMP]
 xor edx,edx
 call unlinkat@PLT
 test eax,eax
 jnz .Lpf_bad
.Lpf_renamed:
 mov byte ptr [rbx+P_TEMP],0
 mov edi,[rbx+P_FD]
 call close@PLT
 mov qword ptr [rbx+P_FD],-1
.Lpf_directory:
 mov rdi,[rip+publisher_root]
 call fsync@PLT
 test eax,eax
 jz .Lpf_good
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lpf_directory
.Lpf_bad:
 xor eax,eax
 jmp .Lpf_done
.Lpf_corrupt:
 mov eax,-1
 jmp .Lpf_done
.Lpf_good:
 mov eax,1
.Lpf_done:
 add rsp,16
 pop r13
 pop r12
 pop rbx
 ret

/* RDI=request, RSI=borrowed chunk, RDX=bounded bytes. EAX=1/0.
 * Handle short writes/EINTR, update SHA256 only after complete write.
 * Deadline starts after HTTP headers; blocking filesystem durability remains
 * a host qualification requirement. Stack8 bytes plus four saved registers. */
publisher_write:
 push rbx
 push r12
 push r13
 push r14
 sub rsp,8
 mov rbx,rdi
 mov r12,rsi
 mov r13,rdx
 xor r14d,r14d
.Lpw_loop:
 call clock_ms
 test rax,rax
 js .Lpw_bad
 cmp rax,[rbx+P_DEADLINE]
 jae .Lpw_bad
 mov edi,[rbx+P_FD]
 lea rsi,[r12+r14]
 mov rdx,r13
 sub rdx,r14
 call write@PLT
 test rax,rax
 jle .Lpw_errno
 add r14,rax
 cmp r14,r13
 jb .Lpw_loop
 mov rdi,[rbx+P_MD]
 mov rsi,r12
 mov rdx,r13
 call EVP_DigestUpdate@PLT
 cmp eax,1
 sete al
 movzx eax,al
 jmp .Lpw_done
.Lpw_errno:
 jz .Lpw_bad
 call __errno_location@PLT
 cmp dword ptr [rax],4
 je .Lpw_loop
.Lpw_bad:
 xor eax,eax
.Lpw_done:
 add rsp,8
 pop r14
 pop r13
 pop r12
 pop rbx
 ret

/* RDI=MHD connection, RSI=request, RDX=owned validated PGresult.
 * HTTP copy precedes PQclear on every path. Only approved success statuses
 * expose the bounded result body; errors select fixed public constants.
 * New-task Location derives only from32hex. EAX=MHD_Result.
 * Stack16 bytes plus five saved registers; preserves callee-saved registers. */
publisher_db_reply:
 push rbx
 push r12
 push r13
 push r14
 push r15
 sub rsp,16
 mov rbx,rdi
 mov r12,rsi
 mov r13,rdx
 mov qword ptr [r12+P_STATE],2
 mov rdi,r13
 xor esi,esi
 xor edx,edx
 call PQgetvalue@PLT
 mov rdi,rax
 call atoi@PLT
 mov r14d,eax
 mov qword ptr [rsp+8],0
 cmp eax,400
 jae .Lpb_error_body
 cmp eax,200
 je .Lpb_success
 cmp eax,201
 je .Lpb_success
 cmp eax,202
 je .Lpb_success
 cmp eax,204
 jne .Lpb_error_fallback
.Lpb_success:
 cmp eax,202
 jne .Lpb_body
 lea rdi,[r12+P_LOCATION]
 lea rsi,[rip+publisher_prefix]
 mov edx,21
 call memcpy@PLT
 mov rdi,r13
 xor esi,esi
 mov edx,1
 call PQgetvalue@PLT
 lea rdi,[r12+P_LOCATION+21]
 mov rsi,rax
 mov edx,33
 call memcpy@PLT
 lea rax,[r12+P_LOCATION]
 mov [rsp+8],rax
.Lpb_body:
 mov rdi,r13
 xor esi,esi
 mov edx,2
 call PQgetlength@PLT
 mov r15d,eax
 mov rdi,r13
 xor esi,esi
 mov edx,2
 call PQgetvalue@PLT
 mov rdx,rax
 mov ecx,r15d
 lea r8,[rip+publisher_json]
 jmp .Lpb_queue
.Lpb_error_body:
 lea r15,[rip+publisher_public_problems]
.Lpb_error_lookup:
 cmp qword ptr [r15],0
 je .Lpb_error_fallback
 cmp dword ptr [r15],r14d
 je .Lpb_error_selected
 add r15,16
 jmp .Lpb_error_lookup
.Lpb_error_selected:
 mov r15,[r15+8]
 jmp .Lpb_error_format
.Lpb_error_fallback:
 mov r14d,503
 lea r15,[rip+publisher_error_unavailable]
.Lpb_error_format:
 mov rdi,r15
 call strlen@PLT
 mov ecx,eax
 mov rdx,r15
 lea r8,[rip+publisher_problem]
.Lpb_queue:
 mov rdi,rbx
 mov esi,r14d
 mov r9,[rsp+8]
 call queue_response
 mov r12d,eax
 mov rdi,r13
 call PQclear@PLT
 mov eax,r12d
 add rsp,16
 pop r15
 pop r14
 pop r13
 pop r12
 pop rbx
 ret

/* MHD access callback, same pinned C ABI as the reader. Own request strings
 * only in P_SIZE memory. Fixed parameters never become SQL identifiers.
 * Post-header60s deadline covers admission, chunks and bounded DB I/O.
 * Stack104 bytes plus six saves; body storage is heap-owned, not thread stack. */
publisher_request:
 push rbp
 mov rbp,rsp
 push rbx
 push r12
 push r13
 push r14
 push r15
 sub rsp,104
 mov rbx,rsi
 mov r13,r9
 mov r14,[rbp+16]
 mov r15,[rbp+24]
 mov [rbp-88],rdx
 mov [rbp-96],rcx
 mov r12,[r15]
 cmp r12,1
 je .Lpub_invalid_marker
 cmp r12,2
 je .Lpub_yes
 test r12,r12
 jnz .Lpub_continue
 mov edi,1
 mov esi,P_SIZE
 call calloc@PLT
 test rax,rax
 jz .Lpub_close
 mov r12,rax
 mov [r15],rax
 mov qword ptr [r12+P_FD],-1
 call clock_ms
 test rax,rax
 js .Lpub_unavailable
 add rax,P_TIMEOUT
 mov [r12+P_DEADLINE],rax
 mov rdi,rbx
 mov esi,1
 lea rdx,[rip+publisher_header]
 mov rcx,r12
 call MHD_get_connection_values_n@PLT
 cmp qword ptr [r12+P_BAD],0
 jne .Lpub_invalid
 /* Parse a canonical decimal length before numeric conversion in SQL. */
 cmp qword ptr [r12+P_CL_N],0
 je .Lpub_route
 lea rdi,[r12+P_CL]
 cmp byte ptr [rdi],0
 je .Lpub_invalid
 cmp byte ptr [rdi],'0'
 jne .Lpub_length_start
 cmp byte ptr [rdi+1],0
 jne .Lpub_invalid
.Lpub_length_start:
 xor eax,eax
.Lpub_length:
 movzx ecx,byte ptr [rdi]
 test cl,cl
 jz .Lpub_length_done
 sub ecx,'0'
 cmp ecx,9
 ja .Lpub_invalid
 imul rax,rax,10
 add rax,rcx
 cmp rax,P_MAX_OBJECT
 ja .Lpub_limit
 inc rdi
 jmp .Lpub_length
.Lpub_length_done:
 mov [r12+P_EXPECT],rax
.Lpub_route:
 mov rdi,[rbp-96]
 lea rsi,[rip+get_method]
 call strcmp@PLT
 test eax,eax
 jnz .Lpub_api_route
 cmp qword ptr [r12+P_EXPECT],0
 jne .Lpub_invalid
 mov rdi,[rbp-88]
 lea rsi,[rip+path_live]
 call strcmp@PLT
 test eax,eax
 jz .Lpub_live
 mov rdi,[rbp-88]
 lea rsi,[rip+path_ready]
 call strcmp@PLT
 test eax,eax
 jz .Lpub_ready
 mov rdi,[rbp-88]
 lea rsi,[rip+path_status]
 call strcmp@PLT
 test eax,eax
 jz .Lpub_status
.Lpub_api_route:
 mov rdi,[rbp-88]
 call strlen@PLT
 cmp rax,20
 je .Lpub_create_route
 cmp rax,53
 je .Lpub_task_route
 cmp rax,128
 jne .Lpub_missing
 mov qword ptr [r12+P_ROUTE],3
 mov rdi,[rbp-96]
 lea rsi,[rip+publisher_put]
 call strcmp@PLT
 test eax,eax
 jnz .Lpub_invalid
 mov rdi,[rbp-88]
 add rdi,53
 lea rsi,[rip+publisher_artifacts]
 mov edx,11
 call strncmp@PLT
 test eax,eax
 jnz .Lpub_missing
 mov rdi,[rbp-88]
 add rdi,64
 mov esi,64
 call publisher_hex
 test eax,eax
 jz .Lpub_invalid
 lea rdi,[r12+P_DIGEST]
 mov rsi,[rbp-88]
 add rsi,64
 mov edx,65
 call memcpy@PLT
 jmp .Lpub_task_prefix
.Lpub_task_route:
 mov qword ptr [r12+P_ROUTE],2
 mov rdi,[rbp-96]
 lea rsi,[rip+get_method]
 call strcmp@PLT
 test eax,eax
 jnz .Lpub_invalid
.Lpub_task_prefix:
 mov rdi,[rbp-88]
 lea rsi,[rip+publisher_prefix]
 mov edx,21
 call strncmp@PLT
 test eax,eax
 jnz .Lpub_missing
 mov rdi,[rbp-88]
 add rdi,21
 mov esi,32
 call publisher_hex
 test eax,eax
 jz .Lpub_invalid
 lea rdi,[r12+P_TASK]
 mov rsi,[rbp-88]
 add rsi,21
 mov edx,32
 call memcpy@PLT
 jmp .Lpub_authorization
.Lpub_create_route:
 mov rdi,[rbp-88]
 lea rsi,[rip+publisher_path]
 call strcmp@PLT
 test eax,eax
 jnz .Lpub_missing
 mov rdi,[rbp-96]
 lea rsi,[rip+publisher_post]
 call strcmp@PLT
 test eax,eax
 jnz .Lpub_invalid
 mov qword ptr [r12+P_ROUTE],1
.Lpub_authorization:
 cmp qword ptr [r12+P_AUTH_N],1
 jne .Lpub_auth
 lea rdi,[r12+P_AUTH]
 call strlen@PLT
 cmp eax,82
 jne .Lpub_auth
 lea rdi,[r12+P_AUTH]
 lea rsi,[rip+publisher_bearer]
 mov edx,18
 call memcmp@PLT
 test eax,eax
 jnz .Lpub_auth
 lea rdi,[r12+P_AUTH+18]
 mov esi,64
 call publisher_hex
 test eax,eax
 jz .Lpub_auth
 lea rax,[r12+P_AUTH+7]
 mov [rbp-80],rax
 lea rax,[r12+P_TASK]
 mov [rbp-72],rax
 cmp qword ptr [r12+P_ROUTE],2
 je .Lpub_read
 cmp qword ptr [r12+P_CL_N],1
 jne .Lpub_invalid
 cmp qword ptr [r12+P_EXPECT],0
 je .Lpub_invalid
 cmp qword ptr [r12+P_TYPE_N],1
 jne .Lpub_media
 lea rdi,[r12+P_TYPE]
 lea rsi,[rip+publisher_octets]
 cmp qword ptr [r12+P_ROUTE],3
 je .Lpub_type
 lea rsi,[rip+publisher_json]
.Lpub_type:
 call strcmp@PLT
 test eax,eax
 jnz .Lpub_media
 cmp qword ptr [r12+P_ROUTE],3
 je .Lpub_authorize_upload
 cmp qword ptr [r12+P_EXPECT],65536
 ja .Lpub_limit
 cmp qword ptr [r12+P_KEY_N],1
 jne .Lpub_invalid
 lea rdi,[r12+P_KEY]
 call strlen@PLT
 cmp eax,32
 jne .Lpub_invalid
 lea rdi,[r12+P_KEY]
 mov esi,32
 call publisher_hex
 test eax,eax
 jz .Lpub_invalid
 mov qword ptr [r12+P_STATE],1
 jmp .Lpub_yes
.Lpub_read:
 lea rdi,[rip+publisher_read_sql]
 mov esi,2
 lea rdx,[rbp-80]
 mov ecx,65536
 mov r8,[r12+P_DEADLINE]
 call database_query
 jmp .Lpub_database_response
.Lpub_authorize_upload:
 lea rax,[r12+P_DIGEST]
 mov [rbp-64],rax
 lea rax,[r12+P_CL]
 mov [rbp-56],rax
 lea rdi,[rip+publisher_authorize_sql]
 mov esi,4
 lea rdx,[rbp-80]
 mov ecx,65536
 mov r8,[r12+P_DEADLINE]
 call database_query
 test rax,rax
 jz .Lpub_unavailable
 mov [rbp-104],rax
 mov rdi,rax
 xor esi,esi
 xor edx,edx
 call PQgetvalue@PLT
 cmp dword ptr [rax],0x00343032 /* exact204 and NUL */
 jne .Lpub_authorize_refused
 mov rdi,[rbp-104]
 call PQclear@PLT
 mov rdi,r12
 call publisher_stage
 test eax,eax
 jz .Lpub_unavailable
 mov qword ptr [r12+P_STATE],1
 jmp .Lpub_yes
.Lpub_authorize_refused:
 mov rax,[rbp-104]
 jmp .Lpub_database_response
.Lpub_continue:
 cmp qword ptr [r12+P_STATE],2
 je .Lpub_yes
 call clock_ms
 test rax,rax
 js .Lpub_close
 cmp rax,[r12+P_DEADLINE]
 jae .Lpub_close
 mov rdx,[r14]
 test rdx,rdx
 jz .Lpub_final_callback
 cmp qword ptr [r12+P_BAD],400
 jae .Lpub_discard_chunk
 mov rax,[r12+P_RECEIVED]
 add rax,rdx
 cmp rax,[r12+P_EXPECT]
 ja .Lpub_artifact
 cmp qword ptr [r12+P_ROUTE],3
 je .Lpub_upload_chunk
 xor ecx,ecx
.Lpub_ascii:
 mov al,[r13+rcx]
 test al,al
 jz .Lpub_invalid
 test al,0x80
 jnz .Lpub_invalid
 inc rcx
 cmp rcx,rdx
 jb .Lpub_ascii
 lea rdi,[r12+P_BUFFER]
 add rdi,[r12+P_RECEIVED]
 mov rsi,r13
 mov rdx,[r14]
 call memcpy@PLT
 jmp .Lpub_chunk_done
.Lpub_upload_chunk:
 mov rdi,r12
 mov rsi,r13
 call publisher_write
 test eax,eax
 jz .Lpub_unavailable
.Lpub_chunk_done:
 mov rax,[r14]
 add [r12+P_RECEIVED],rax
.Lpub_discard_chunk:
 mov qword ptr [r14],0
 jmp .Lpub_yes
.Lpub_final_callback:
 cmp qword ptr [r12+P_BAD],400
 jb .Lpub_body_complete
 mov rsi,[r12+P_BAD]
 mov rdx,[r12+P_ERROR_BODY]
 jmp .Lpub_problem
.Lpub_body_complete:
 mov rax,[r12+P_RECEIVED]
 cmp rax,[r12+P_EXPECT]
 jne .Lpub_artifact
 lea rax,[r12+P_AUTH+7]
 mov [rbp-80],rax
 cmp qword ptr [r12+P_ROUTE],3
 je .Lpub_finish_upload
 lea rax,[r12+P_KEY]
 mov [rbp-72],rax
 lea rax,[r12+P_BUFFER]
 mov [rbp-64],rax
 lea rdi,[rip+publisher_create_sql]
 mov esi,3
 jmp .Lpub_operation
.Lpub_finish_upload:
 mov rdi,r12
 call publisher_finalize
 test eax,eax
 js .Lpub_artifact
 jz .Lpub_unavailable
 lea rax,[r12+P_TASK]
 mov [rbp-72],rax
 lea rax,[r12+P_DIGEST]
 mov [rbp-64],rax
 lea rax,[r12+P_CL]
 mov [rbp-56],rax
 lea rdi,[rip+publisher_receipt_sql]
 mov esi,4
.Lpub_operation:
 lea rdx,[rbp-80]
 mov ecx,65536
 mov r8,[r12+P_DEADLINE]
 call database_query
.Lpub_database_response:
 test rax,rax
 jz .Lpub_unavailable
 mov rdi,rbx
 mov rsi,r12
 mov rdx,rax
 call publisher_db_reply
 jmp .Lpub_return
.Lpub_ready:
 call database_ready
 test eax,eax
 jz .Lpub_unavailable
 lea rdx,[rip+ready_body]
 jmp .Lpub_health_response
.Lpub_live:
 lea rdx,[rip+live_body]
 jmp .Lpub_health_response
.Lpub_status:
 lea rdx,[rip+status_body]
.Lpub_health_response:
 mov esi,200
 lea r8,[rip+publisher_json]
 jmp .Lpub_fixed
.Lpub_invalid_marker:
 mov qword ptr [r15],2
.Lpub_invalid:
 lea rdx,[rip+publisher_error_invalid]
 mov esi,400
 jmp .Lpub_problem
.Lpub_auth:
 lea rdx,[rip+publisher_error_auth]
 mov esi,401
 jmp .Lpub_problem
.Lpub_limit:
 lea rdx,[rip+publisher_error_limit]
 mov esi,413
 jmp .Lpub_problem
.Lpub_media:
 lea rdx,[rip+publisher_error_media]
 mov esi,415
 jmp .Lpub_problem
.Lpub_artifact:
 lea rdx,[rip+publisher_error_artifact]
 mov esi,422
 jmp .Lpub_problem
.Lpub_missing:
 lea rdx,[rip+publisher_error_missing]
 mov esi,404
 jmp .Lpub_problem
.Lpub_unavailable:
 lea rdx,[rip+publisher_error_unavailable]
 mov esi,503
.Lpub_problem:
 lea r8,[rip+publisher_problem]
.Lpub_fixed:
 cmp r12,2
 jbe .Lpub_fixed_marker
 cmp qword ptr [r12+P_STATE],1
 jne .Lpub_fixed_ready
 cmp qword ptr [r14],0
 je .Lpub_fixed_ready
 /* MHD cannot queue during a data callback. Retain the fixed failure,
  * discard remaining bounded body, then reply at FULL_REQ_RECEIVED. */
 mov [r12+P_BAD],rsi
 mov [r12+P_ERROR_BODY],rdx
 jmp .Lpub_discard_chunk
.Lpub_fixed_ready:
 mov qword ptr [r12+P_STATE],2
.Lpub_fixed_marker:
 mov qword ptr [r14],0
 mov r13,rdx
 mov r15d,esi
 mov [rbp-104],r8
 mov rdi,rdx
 call strlen@PLT
 mov rdi,rbx
 mov esi,r15d
 mov rdx,r13
 mov rcx,rax
 mov r8,[rbp-104]
 xor r9d,r9d
 call queue_response
 jmp .Lpub_return
.Lpub_yes:
 mov eax,1
 jmp .Lpub_return
.Lpub_close:
 xor eax,eax
.Lpub_return:
 add rsp,104
 pop r15
 pop r14
 pop r13
 pop r12
 pop rbx
 pop rbp
 ret
