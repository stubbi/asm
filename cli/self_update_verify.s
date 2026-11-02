/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * See LICENSE and LICENSING.md for the terms and scope.
 */
.intel_syntax noprefix
.equ SELF_VERIFIER_DEADLINE_SECONDS, 120

/* GitHub CLI supplies Sigstore verification and its own trusted-root handling.
 * Asm supplies fixed identity constraints and checks the verified repository ID.
 * Release-supplied roots, GH credentials, custom hosts, and shell expressions are
 * never accepted. This manual protocol provides no registry freshness or
 * revocation guarantee. It does not implement a TUF release-metadata client.
 */
.section .text

/* Build a fresh verifier HOME/config/cache inside the private stage, then
 * require the fixed executable to report a stable version >=2.93.0.
 * Inputs: held self_stage_fd, parent path, private stage name. Output:
 * self_gh_environment strings (each 8192 bytes), otherwise fatal error.
 * Stack: 16 saved bytes plus 8 alignment bytes. Only proxy routing entries
 * are copied from the calling environment. */
self_prepare_verifier:
    push rbx
    push r12
    sub rsp, 8
    call self_copy_proxy_environment
    mov eax, 258
    mov rdi, [rip + self_stage_fd]
    lea rsi, [rip + self_verifier_directory]
    mov edx, 448
    syscall
    test rax, rax
    js self_io_error
    lea rdi, [rip + self_home_environment]
    lea rsi, [rip + self_home_prefix]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_parent_path]
    call copy_string
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    lea rsi, [rip + registry_temp_dir]
    call copy_string
    mov rdi, rax
    lea rsi, [rip + self_verifier_suffix]
    call copy_string
    lea r12, [rip + self_home_environment + 5]
    lea rdi, [rip + self_config_environment]
    lea rsi, [rip + self_config_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, r12
    call copy_string
    lea rdi, [rip + self_cache_environment]
    lea rsi, [rip + self_cache_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, r12
    call copy_string
    lea rdi, [rip + self_xdg_environment]
    lea rsi, [rip + self_xdg_prefix]
    call copy_string
    mov rdi, rax
    mov rsi, r12
    call copy_string
.ifdef ASM_TRUSTED_DISTRIBUTION
    call self_prepare_embedded_verifier
.else
    lea rdi, [rip + self_gh_path]
    lea rsi, [rip + self_version_argv]
    lea rdx, [rip + self_gh_environment]
    call self_capture
    test eax, eax
    jnz self_verifier_missing
    lea rdi, [rip + self_capture_buffer]
    lea rsi, [rip + self_gh_version_prefix]
    call self_prefix
    test rax, rax
    jz self_verifier_missing
    mov rsi, rax
    lea rdi, [rip + self_gh_version]
    xor ecx, ecx
.Lself_gh_version_character:
    cmp ecx, 32
    ja self_verifier_missing
    mov al, [rsi + rcx]
    cmp al, ' '
    je .Lself_gh_version_end
    cmp al, 10
    je .Lself_gh_version_end
    test al, al
    jz self_verifier_missing
    mov [rdi + rcx], al
    inc ecx
    jmp .Lself_gh_version_character
.Lself_gh_version_end:
    mov byte ptr [rdi + rcx], 0
    call registry_valid_version
    test eax, eax
    jz self_verifier_missing
    lea rdi, [rip + self_gh_version]
    lea rsi, [rip + self_gh_minimum_version]
    call registry_version_compare
    cmp eax, 0
    jl self_verifier_missing
.endif
    add rsp, 8
    pop r12
    pop rbx
    ret

/* Copy only the eight standard proxy variables into bounded child env arrays.
 * Routing is configurable; certificate roots, signatures, identities, GH
 * tokens, hosts, and config remain fixed. Each complete entry is <=4096 bytes;
 * duplicate names fail rather than let two child tools interpret them
 * differently. Values remain borrowed from the initial process environment.
 * Output: <=8 pointers plus NUL in network env, appended after 10 fixed gh
 * entries. Stack: 40 saved bytes. No environment values are logged. */
self_copy_proxy_environment:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, [rip + envp]
    xor r14d, r14d
    xor r15d, r15d
.Lself_proxy_entry:
    mov r13, [r12]
    test r13, r13
    jz .Lself_proxy_done
    xor ebx, ebx
.Lself_proxy_name:
    mov rdi, r13
    lea rax, [rip + self_proxy_prefixes]
    mov rsi, [rax + rbx*8]
    call self_prefix
    test rax, rax
    jnz .Lself_proxy_found
    inc ebx
    cmp ebx, 8
    jb .Lself_proxy_name
    jmp .Lself_proxy_next
.Lself_proxy_found:
    bt r15, rbx
    jc self_proxy_error
    bts r15, rbx
    mov rdi, r13
    call strlen
    cmp rax, 4096
    ja self_proxy_error
    lea rax, [rip + self_network_environment]
    mov [rax + r14*8], r13
    lea rax, [rip + self_gh_environment + 10*8]
    mov [rax + r14*8], r13
    inc r14
.Lself_proxy_next:
    add r12, 8
    jmp .Lself_proxy_entry
.Lself_proxy_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

/* RDI=terminated input, RSI=terminated prefix. Output RAX points immediately
 * after a matching prefix, else zero. Does not read past the input NUL.
 * Scratch RAX/RCX/RDI/RSI; no stack or mutation. */
self_prefix:
    mov al, [rsi]
    test al, al
    jz .Lself_prefix_match
    cmp al, [rdi]
    jne .Lself_prefix_no
    inc rsi
    inc rdi
    jmp self_prefix
.Lself_prefix_match:
    mov rax, rdi
    ret
.Lself_prefix_no:
    xor eax, eax
    ret

/* Download the <=1 MiB manifest and Sigstore bundle from the exact versioned
 * release. Verify manifest identity first; parse all metadata natively; then
 * verify manifest and payload with the same exact source/signer commit.
 * Each verifier result must contain exactly the pinned numeric repository ID.
 * Returns only after all checks succeed. Never executes the candidate.
 * Stack: 8 saved bytes. Owns bounded manifest buffer and gh argument array. */
self_verify_release:
    push rbx
    lea rdi, [rip + self_manifest_url]
    lea rsi, [rip + self_manifest_path]
    lea rdx, [rip + registry_index_max]
    call registry_download
    test eax, eax
    jnz self_download_error
    lea rdi, [rip + self_bundle_url]
    lea rsi, [rip + self_bundle_path]
    lea rdx, [rip + registry_index_max]
    call registry_download
    test eax, eax
    jnz self_download_error
    lea rdi, [rip + self_manifest_path]
    call self_bounded_regular_file
    lea rdi, [rip + self_bundle_path]
    call self_bounded_regular_file
    lea rax, [rip + self_bundle_path]
    mov [rip + self_verify_argv + 16*8], rax
    lea rax, [rip + self_manifest_path]
    mov [rip + self_verify_argv + 3*8], rax
    mov qword ptr [rip + self_verify_argv + 23*8], 0
    call self_verify_attestation
    call self_load_manifest
    lea rdi, [rip + self_manifest_data]
    mov rsi, [rip + self_manifest_length]
    mov rdx, [rip + registry_selected]
    call self_parse_release
    test eax, eax
    jnz self_metadata_error
    lea rax, [rip + self_source_digest_option]
    mov [rip + self_verify_argv + 23*8], rax
    lea rax, [rip + self_source_commit]
    mov [rip + self_verify_argv + 24*8], rax
    mov [rip + self_verify_argv + 26*8], rax
    lea rax, [rip + self_signer_digest_option]
    mov [rip + self_verify_argv + 25*8], rax
    call self_verify_attestation
    lea rax, [rip + registry_temp_payload]
    mov [rip + self_verify_argv + 3*8], rax
    call self_verify_attestation
    pop rbx
    ret

/* Read only the parsed certificate repository ID from a successful verifier.
 * gh --jq is a fixed argument, never a shell command or untrusted expression.
 * The exact single-line result rejects absent, duplicate, or renamed IDs.
 * Stack: 8 alignment bytes. */
self_verify_attestation:
    sub rsp, 8
.ifdef ASM_TRUSTED_DISTRIBUTION
    call self_embedded_provenance
.else
    lea rdi, [rip + self_gh_path]
    lea rsi, [rip + self_verify_argv]
    lea rdx, [rip + self_gh_environment]
    call self_capture
.endif
    test eax, eax
    jnz self_attestation_error
    cmp qword ptr [rip + self_capture_length], 11
    jne self_attestation_error
    lea rdi, [rip + self_capture_buffer]
    lea rsi, [rip + self_repository_id_line]
    call streq
    test eax, eax
    jz self_attestation_error
    add rsp, 8
    ret

/* RDI=owned staged file path. Require a regular single-link file 1..1MiB.
 * lstat refuses final symlinks; private ancestor is owned and held. Output:
 * RAX=byte size, or terminal failure. Scratch stat buffer 144 bytes. */
self_bounded_regular_file:
    mov eax, 6
    lea rsi, [rip + self_check_stat]
    syscall
    test rax, rax
    js self_metadata_error
    mov eax, [rip + self_check_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne self_metadata_error
    cmp qword ptr [rip + self_check_stat + 16], 1
    jne self_metadata_error
    mov rax, [rip + self_check_stat + 48]
    test rax, rax
    jz self_metadata_error
    cmp rax, INDEX_LIMIT
    ja self_metadata_error
    ret

/* Read the attested manifest into INDEX_LIMIT+1 owned bytes. Open without
 * following links; check the final length against fstat; retry EINTR.
 * Output: buffer plus NUL and manifest_length. Stack 24 saved bytes. */
self_load_manifest:
    push r12
    push r13
    push r14
    mov eax, 2
    lea rdi, [rip + self_manifest_path]
    mov esi, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js self_metadata_error
    mov r12, rax
    mov eax, 5
    mov rdi, r12
    lea rsi, [rip + self_check_stat]
    syscall
    test rax, rax
    js .Lself_manifest_close_error
    mov eax, [rip + self_check_stat + 24]
    and eax, 61440
    cmp eax, 32768
    jne .Lself_manifest_close_error
    mov r14, [rip + self_check_stat + 48]
    test r14, r14
    jz .Lself_manifest_close_error
    cmp r14, INDEX_LIMIT
    ja .Lself_manifest_close_error
    xor r13d, r13d
.Lself_manifest_read:
    xor eax, eax
    mov rdi, r12
    lea rsi, [rip + self_manifest_data]
    add rsi, r13
    mov edx, INDEX_LIMIT + 1
    sub rdx, r13
    syscall
    cmp rax, -4
    je .Lself_manifest_read
    test rax, rax
    js .Lself_manifest_close_error
    jz .Lself_manifest_end
    add r13, rax
    cmp r13, INDEX_LIMIT
    ja .Lself_manifest_close_error
    jmp .Lself_manifest_read
.Lself_manifest_end:
    cmp r13, r14
    jne .Lself_manifest_close_error
    mov eax, 3
    mov rdi, r12
    syscall
    test rax, rax
    js self_metadata_error
    lea rax, [rip + self_manifest_data]
    mov byte ptr [rax + r13], 0
    mov [rip + self_manifest_length], r13
    pop r14
    pop r13
    pop r12
    ret
.Lself_manifest_close_error:
    mov eax, 3
    mov rdi, r12
    syscall
    jmp self_metadata_error

/* RDI=fixed executable, RSI=argv, RDX=explicit environment. Fork and capture
 * stdout into self_capture_buffer[4098], rejecting >4096 bytes. Child stdin
 * is /dev/null, stderr is inherited, and alarm bounds each child to 120s.
 * Output EAX=exit status (128+signal; 127 for child setup/exec/fork failure),
 * capture_length plus NUL. No shell. Stack 48 saved bytes plus 8 alignment
 * bytes for the absolute-path check; FDs close on every parent return path.
 */
self_capture:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    sub rsp, 8
    call self_check_absolute_installation
    add rsp, 8
    mov qword ptr [rip + self_capture_length], 0
    mov byte ptr [rip + self_capture_buffer], 0
    mov eax, 293
    lea rdi, [rip + self_capture_pipe]
    mov esi, O_CLOEXEC
    syscall
    test rax, rax
    js .Lself_capture_fork_error
    mov eax, 57
    syscall
    test rax, rax
    js .Lself_capture_pipe_error
    jz .Lself_capture_child
    mov rbx, rax
    mov eax, 3
    mov edi, [rip + self_capture_pipe + 4]
    syscall
    xor r15d, r15d
    xor ebp, ebp
.Lself_capture_read:
    xor eax, eax
    mov edi, [rip + self_capture_pipe]
    lea rsi, [rip + self_capture_buffer]
    add rsi, r15
    mov edx, 4097
    sub rdx, r15
    syscall
    cmp rax, -4
    je .Lself_capture_read
    test rax, rax
    js .Lself_capture_kill
    jz .Lself_capture_wait
    add r15, rax
    cmp r15, 4096
    ja .Lself_capture_kill
    jmp .Lself_capture_read
.Lself_capture_kill:
    mov ebp, 1
    mov eax, 62
    mov rdi, rbx
    mov esi, 9
    syscall
.Lself_capture_wait:
    mov eax, 3
    mov edi, [rip + self_capture_pipe]
    syscall
.Lself_capture_wait_retry:
    mov eax, 61
    mov rdi, rbx
    lea rsi, [rip + self_capture_wait_status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -4
    je .Lself_capture_wait_retry
    test rax, rax
    js .Lself_capture_fork_error
    mov [rip + self_capture_length], r15
    lea rax, [rip + self_capture_buffer]
    mov byte ptr [rax + r15], 0
    test ebp, ebp
    jnz .Lself_capture_failed
    mov eax, [rip + self_capture_wait_status]
    mov edx, eax
    and edx, 127
    jnz .Lself_capture_signaled
    shr eax, 8
    and eax, 255
    jmp .Lself_capture_return
.Lself_capture_signaled:
    lea eax, [rdx + 128]
    jmp .Lself_capture_return
.Lself_capture_failed:
    mov eax, 1
    jmp .Lself_capture_return
.Lself_capture_pipe_error:
    mov eax, 3
    mov edi, [rip + self_capture_pipe]
    syscall
    mov eax, 3
    mov edi, [rip + self_capture_pipe + 4]
    syscall
.Lself_capture_fork_error:
    mov eax, 127
.Lself_capture_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lself_capture_child:
    mov eax, 3
    mov edi, [rip + self_capture_pipe]
    syscall
    mov eax, 33
    mov edi, [rip + self_capture_pipe + 4]
    mov esi, 1
    syscall
    test rax, rax
    js .Lself_capture_child_error
    /* dup2(fd,fd) leaves CLOEXEC set, so clear stdout's flag explicitly. */
    mov eax, 72
    mov edi, 1
    mov esi, 2
    xor edx, edx
    syscall
    test rax, rax
    js .Lself_capture_child_error
    cmp dword ptr [rip + self_capture_pipe + 4], 1
    je .Lself_capture_child_stdin
    mov eax, 3
    mov edi, [rip + self_capture_pipe + 4]
    syscall
.Lself_capture_child_stdin:
    mov eax, 2
    lea rdi, [rip + self_dev_null]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .Lself_capture_child_error
    mov rbp, rax
    mov rdi, rax
    mov eax, 33
    xor esi, esi
    syscall
    test rax, rax
    js .Lself_capture_child_error
    test rbp, rbp
    jz .Lself_capture_child_alarm
    mov eax, 3
    mov rdi, rbp
    syscall
.Lself_capture_child_alarm:
    /* Ignored dispositions and blocked masks survive execve. Reset SIGALRM
     * and explicitly unblock it before enforcing the child deadline. The
     * Linux x86-64 kernel signal set is eight bytes; bit 13 is SIGALRM. */
    mov eax, 13
    mov edi, 14
    lea rsi, [rip + self_default_signal]
    xor edx, edx
    mov r10d, 8
    syscall
    test rax, rax
    js .Lself_capture_child_error
    mov eax, 14
    mov edi, 1 /* SIG_UNBLOCK */
    lea rsi, [rip + self_alarm_signal_mask]
    xor edx, edx
    mov r10d, 8
    syscall
    test rax, rax
    js .Lself_capture_child_error
    mov eax, 37
    mov edi, SELF_VERIFIER_DEADLINE_SECONDS
    syscall
    test rax, rax
    js .Lself_capture_child_error
    mov eax, 59
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    syscall
.Lself_capture_child_error:
    mov edi, 127
    jmp exit_code

self_verifier_missing:
    lea rdi, [rip + self_error_verifier]
    mov esi, 1
    jmp self_fail
self_attestation_error:
    lea rdi, [rip + self_error_attestation]
    mov esi, 1
    jmp self_fail
self_metadata_error:
    lea rdi, [rip + self_error_metadata]
    mov esi, 1
    jmp self_fail
self_proxy_error:
    lea rdi, [rip + self_error_proxy]
    mov esi, 2
    jmp self_fail

.section .rodata
self_gh_path: .asciz "/usr/bin/gh"
self_dev_null: .asciz "/dev/null"
self_verifier_directory: .asciz "verifier"
self_verifier_suffix: .asciz "/verifier"
self_home_prefix: .asciz "HOME="
self_config_prefix: .asciz "GH_CONFIG_DIR="
self_cache_prefix: .asciz "XDG_CACHE_HOME="
self_xdg_prefix: .asciz "XDG_CONFIG_HOME="
self_gh_host_environment: .asciz "GH_HOST=github.com"
self_gh_prompt_environment: .asciz "GH_PROMPT_DISABLED=1"
self_gh_update_environment: .asciz "GH_NO_UPDATE_NOTIFIER=1"
self_gh_extension_environment: .asciz "GH_NO_EXTENSION_UPDATE_NOTIFIER=1"
self_locale_environment: .asciz "LC_ALL=C"
self_lang_environment: .asciz "LANG=C"
self_gh_version_option: .asciz "--version"
self_gh_version_prefix: .asciz "gh version "
self_gh_minimum_version: .asciz "2.93.0"
self_attestation_command: .asciz "attestation"
self_verify_command: .asciz "verify"
self_repository_option: .asciz "--repo"
self_certificate_option: .asciz "--cert-identity"
self_certificate_identity: .asciz "https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main"
self_issuer_option: .asciz "--cert-oidc-issuer"
self_issuer_identity: .asciz "https://token.actions.githubusercontent.com"
self_source_ref_option: .asciz "--source-ref"
self_source_ref: .asciz "refs/heads/main"
self_hosted_option: .asciz "--deny-self-hosted-runners"
self_predicate_option: .asciz "--predicate-type"
self_predicate_type: .asciz "https://slsa.dev/provenance/v1"
self_bundle_option: .asciz "--bundle"
self_format_option: .asciz "--format"
self_json_format: .asciz "json"
self_jq_option: .asciz "--jq"
self_repository_expression: .asciz ".[].verificationResult.signature.certificate.sourceRepositoryIdentifier"
self_repository_id_line: .asciz "1441332955\n"
self_hostname_option: .asciz "--hostname"
self_hostname: .asciz "github.com"
self_source_digest_option: .asciz "--source-digest"
self_signer_digest_option: .asciz "--signer-digest"
self_error_verifier: .asciz "self update requires GitHub CLI 2.93.0 or later at /usr/bin/gh; install it from cli.github.com and try again"
self_error_attestation: .asciz "release attestation verification failed; the previous binary remains; check the official release and verifier connection"
self_error_metadata: .asciz "the attested release metadata does not match the selected Asm artifact; the previous binary remains; check the release"
self_error_proxy: .asciz "proxy environment entries must be unique and at most 4096 bytes; correct the proxy settings and try again"
self_proxy_https_upper: .asciz "HTTPS_PROXY="
self_proxy_https_lower: .asciz "https_proxy="
self_proxy_http_upper: .asciz "HTTP_PROXY="
self_proxy_http_lower: .asciz "http_proxy="
self_proxy_no_upper: .asciz "NO_PROXY="
self_proxy_no_lower: .asciz "no_proxy="
self_proxy_all_upper: .asciz "ALL_PROXY="
self_proxy_all_lower: .asciz "all_proxy="
.balign 8
self_proxy_prefixes:
    .quad self_proxy_https_upper, self_proxy_https_lower, self_proxy_http_upper, self_proxy_http_lower
    .quad self_proxy_no_upper, self_proxy_no_lower, self_proxy_all_upper, self_proxy_all_lower
self_default_signal: .quad 0, 0, 0, 0
self_alarm_signal_mask: .quad 1 << (14 - 1)
self_version_argv: .quad self_gh_path, self_gh_version_option, 0
.section .data
.balign 8
self_gh_environment:
    .quad self_home_environment, self_config_environment, self_cache_environment
    .quad self_xdg_environment, self_gh_host_environment, self_gh_prompt_environment
    .quad self_gh_update_environment, self_gh_extension_environment
    .quad self_locale_environment, self_lang_environment
    .rept 9
    .quad 0
    .endr
.balign 8
self_verify_argv:
    .quad self_gh_path, self_attestation_command, self_verify_command, 0
    .quad self_repository_option, self_package, self_certificate_option, self_certificate_identity
    .quad self_issuer_option, self_issuer_identity, self_source_ref_option, self_source_ref
    .quad self_hosted_option, self_predicate_option, self_predicate_type
    .quad self_bundle_option, 0, self_format_option, self_json_format
    .quad self_jq_option, self_repository_expression, self_hostname_option, self_hostname
    .quad 0, 0, 0, 0, 0
.section .bss
.balign 8
self_manifest_length: .skip 8
self_network_environment: .skip 9 * 8
self_capture_length: .skip 8
self_capture_pipe: .skip 8
self_capture_wait_status: .skip 4
self_gh_version: .skip 33
self_capture_buffer: .skip 4098
self_home_environment: .skip 8192
self_config_environment: .skip 8192
self_cache_environment: .skip 8192
self_xdg_environment: .skip 8192
self_manifest_data: .skip INDEX_LIMIT + 1
