/* SPDX-License-Identifier: AGPL-3.0-or-later
 * RDI=declared executable target, RSI=exact size. EAX=0 success, 1 rejection.
 * Intel macOS dispatches to native Mach-O+codesign validation. Linux uses the
 * existing ELF validator. A different Darwin architecture fails closed here.
 */
.text
mac_pub_validate_executable:
    push rdi
    push rsi
    lea rsi, [rip + registry_host]
    call streq
    pop rsi
    pop rdi
    test eax, eax
    jz pub_validate_elf
    lea rdi, [rip + registry_temp_payload]
    call validate_host_elf
    xor eax, 1
    ret
