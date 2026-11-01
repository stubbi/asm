/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Publication format dispatch: x0 target, x1 size; x9 zero on success.
 * Other targets retain the shared ELF checks. macOS requires this host's
 * bounded Mach-O and codesign checks. Preserves the shared callee-saved ABI.
 */
.text
mac_pub_validate_executable:
    ARM_SAVE x0
    ARM_SAVE x1
    ARM_ADDR x1, registry_macos
    ARM_CALL streq
    ARM_RESTORE x1
    ARM_RESTORE x0
    cbz w9, pub_validate_elf
    ARM_ADDR x0, registry_temp_payload
    ARM_CALL validate_host_elf
    eor w9, w9, #1
    ret
