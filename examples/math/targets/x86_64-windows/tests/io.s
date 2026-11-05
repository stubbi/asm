# SPDX-License-Identifier: MIT
# Test the actual write routine with deterministic Windows API boundary results.
# Cases: complete, short, NULL, invalid, failed, zero-progress, oversized write.
.set MATH_IO_TEST, 1
.include "targets/x86_64-windows/src/main.s"

.text
.global mainCRTStartup
.seh_proc mainCRTStartup
# Input: none. Output: ExitProcess(0) on pass, ExitProcess(1) on failure.
# Clobbers volatile registers and flags. Stack: 40 bytes, Win64 shadow space.
mainCRTStartup:
    sub rsp, 40
    .seh_stackalloc 40
    .seh_endprologue
test_next:
    mov dword ptr [rip + completed], 0
    mov dword ptr [rip + calls], 0
    call math_write_stdout
    mov ecx, dword ptr [rip + scenario]
    xor edx, edx
    cmp ecx, 2
    setae dl
    cmp eax, edx
    jne test_failed
    lea rdx, [rip + expected_calls]
    mov eax, dword ptr [rdx + rcx * 4]
    cmp eax, dword ptr [rip + calls]
    jne test_failed
    cmp dword ptr [rip + boundary_failed], 0
    jne test_failed
    inc dword ptr [rip + scenario]
    cmp dword ptr [rip + scenario], 7
    jb test_next
    xor ecx, ecx
    jmp test_exit
test_failed:
    mov ecx, 1
test_exit:
    call qword ptr [rip + __imp_ExitProcess]
    int3
.seh_endproc

# Win64 API fixture. No stack allocation or nonvolatile register changes.
# Returns the configured handle; rejects an incorrect selector or alignment.
fixture_get_handle:
    mov rax, rsp
    and eax, 15
    cmp eax, 8
    jne boundary_bad
    cmp ecx, -11
    jne boundary_bad
    mov eax, dword ptr [rip + scenario]
    cmp eax, 2
    je null_handle
    cmp eax, 3
    je invalid_handle
    mov eax, 0x1234
    ret
null_handle:
    xor eax, eax
    ret
invalid_handle:
    mov rax, -1
    ret

# Inputs use WriteFile's ABI. Checks the actual buffer, remaining length,
# handle, alignment, and NULL OVERLAPPED. Writes only to the supplied DWORD.
# Clobbers volatile registers; owns no external resources and uses no stack.
fixture_write_file:
    mov rax, rsp
    and eax, 15
    cmp eax, 8
    jne boundary_bad
    cmp rcx, 0x1234
    jne boundary_bad
    cmp qword ptr [rsp + 40], 0
    jne boundary_bad
    inc dword ptr [rip + calls]
    mov r10d, dword ptr [rip + completed]
    lea r11, [rip + message]
    add r11, r10
    cmp rdx, r11
    jne boundary_bad
    mov eax, 17
    sub eax, r10d
    cmp r8d, eax
    jne boundary_bad
    lea r11, [rip + expected_message]
    add r11, r10
    xor ecx, ecx
check_bytes:
    mov al, byte ptr [rdx + rcx]
    cmp al, byte ptr [r11 + rcx]
    jne boundary_bad
    inc ecx
    cmp ecx, r8d
    jb check_bytes
    # The callee may use all four caller-provided shadow slots.
    mov qword ptr [rsp + 8], -1
    mov qword ptr [rsp + 16], -1
    mov qword ptr [rsp + 24], -1
    mov qword ptr [rsp + 32], -1
    mov eax, dword ptr [rip + scenario]
    cmp eax, 4
    je fixture_failure
    cmp eax, 5
    je fixture_zero
    cmp eax, 6
    je fixture_oversized
    cmp eax, 1
    jne fixture_complete
    test r10d, r10d
    jnz fixture_complete
    mov r8d, 5
fixture_complete:
    mov dword ptr [r9], r8d
    add dword ptr [rip + completed], r8d
    mov eax, 1
    ret
fixture_zero:
    mov dword ptr [r9], 0
    mov eax, 1
    ret
fixture_oversized:
    mov dword ptr [r9], 18
    mov eax, 1
    ret
fixture_failure:
    mov dword ptr [r9], 0
    xor eax, eax
    ret
boundary_bad:
    mov dword ptr [rip + boundary_failed], 1
    xor eax, eax
    ret

.section .rdata,"dr"
expected_message: .ascii "min(12, 37) = 12\n"
.p2align 2
expected_calls: .long 1, 2, 0, 0, 1, 1, 1
.data
.p2align 3
__imp_GetStdHandle: .quad fixture_get_handle
__imp_WriteFile: .quad fixture_write_file
scenario: .long 0
completed: .long 0
calls: .long 0
boundary_failed: .long 0
