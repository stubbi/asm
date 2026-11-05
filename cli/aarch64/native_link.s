/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Bounded native-library build inputs and direct compiler invocation.
 * See docs/native-linking.md. This is CLI logic, not a package backend.
 */
.equ NATIVE_LINK_MACOS, 0
.global native_link_validate, package_link, package_libraries, package_check

.section .text
/* Input: x0=link, x1=library list, x2=check path, all NUL-terminated strings
 * with at most 255 bytes. Empty strings represent absent optional fields.
 * Output: w9=1 for the native-link contract, otherwise 0. Does not change
 * inputs or global package state. Preserves x19-x24; stack: 48 saved bytes.
 * valid_source checks relative paths and rejects leading @ in each component.
 * That restriction prevents compiler response-file expansion. */
native_link_validate:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x1
    mov x20, x2
    ldrb w10, [x0]
    cbz w10, .Lnative_validate_absent
    cmp w10, #'c'
    b.ne .Lnative_validate_bad
    ldrb w10, [x0, #1]
    cbnz w10, .Lnative_validate_bad
    mov x0, x19
    mov w4, #0                  /* total bytes */
    mov w5, #0                  /* library count */
    ldrb w10, [x0]
    cbz w10, .Lnative_validate_check
.Lnative_library_start:
    add w5, w5, #1
    cmp w5, #8
    b.hi .Lnative_validate_bad
    ldrb w10, [x0, x4]
    cmp w10, #'a'
    b.lo .Lnative_validate_bad
    cmp w10, #'z'
    b.hi .Lnative_validate_bad
    mov w6, #0                  /* bytes in this library */
.Lnative_library_chars:
    cmp w4, #255
    b.hs .Lnative_validate_bad
    add w4, w4, #1
    add w6, w6, #1
    cmp w6, #31
    b.hi .Lnative_validate_bad
    ldrb w10, [x0, x4]
    cbz w10, .Lnative_validate_check
    cmp w10, #' '
    b.eq .Lnative_library_separator
    cmp w10, #'a'
    b.lo .Lnative_library_digit
    cmp w10, #'z'
    b.ls .Lnative_library_chars
.Lnative_library_digit:
    cmp w10, #'0'
    b.lo .Lnative_library_punctuation
    cmp w10, #'9'
    b.ls .Lnative_library_chars
.Lnative_library_punctuation:
    cmp w10, #'_'
    b.eq .Lnative_library_chars
    cmp w10, #'-'
    b.eq .Lnative_library_chars
    b .Lnative_validate_bad
.Lnative_library_separator:
    add w4, w4, #1
    cmp w4, #255
    b.hs .Lnative_validate_bad
    b .Lnative_library_start
.Lnative_validate_check:
    ldrb w10, [x20]
    cbz w10, .Lnative_validate_good
    mov x21, #0
.Lnative_check_length:
    ldrb w10, [x20, x21]
    cbz w10, .Lnative_check_suffix
    cmp w10, #' '
    b.lo .Lnative_validate_bad
    cmp w10, #'~'
    b.hi .Lnative_validate_bad
    cmp w10, #92
    b.eq .Lnative_validate_bad
    add x21, x21, #1
    cmp x21, #255
    b.hi .Lnative_validate_bad
    b .Lnative_check_length
.Lnative_check_suffix:
    cmp x21, #2
    b.lo .Lnative_validate_bad
    sub x21, x21, #2
    ldrb w10, [x20, x21]
    cmp w10, #'.'
    b.ne .Lnative_validate_bad
    add x21, x21, #1
    ldrb w10, [x20, x21]
    cmp w10, #'c'
    b.ne .Lnative_validate_bad
    mov x0, x20
    ARM_CALL valid_source
    cbz w9, .Lnative_validate_bad
    b .Lnative_validate_good
.Lnative_validate_absent:
    ldrb w10, [x19]
    cbnz w10, .Lnative_validate_bad
    ldrb w10, [x20]
    cbnz w10, .Lnative_validate_bad
.Lnative_validate_good:
    mov w9, #1
    b .Lnative_validate_return
.Lnative_validate_bad:
    mov w9, #0
.Lnative_validate_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Input: x9=current borrowed argv option. Output: w9=1 if consumed, else 0.
 * Native directory options require native_allow. Stores at most eight borrowed
 * argv pointers per kind after checking absolute, printable ASCII paths of
 * 1..255 bytes without colon or comma. Invalid input exits 2 before writes to
 * the project. Preserves x19-x24; stack: 48 saved bytes plus nested calls. */
native_link_option:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    mov x19, x9
    mov x0, x19
    ARM_ADDR x1, native_opt_include
    ARM_CALL streq
    cbnz w9, .Lnative_include_option
    mov x0, x19
    ARM_ADDR x1, native_opt_library
    ARM_CALL streq
    cbnz w9, .Lnative_library_option
    mov w9, #0
    b .Lnative_option_return
.Lnative_include_option:
    ARM_ADDR x20, native_include_count
    ARM_ADDR x21, native_include_dirs
    b .Lnative_directory_option
.Lnative_library_option:
    ARM_ADDR x20, native_library_count
    ARM_ADDR x21, native_library_dirs
.Lnative_directory_option:
    ARM_ADDR x16, native_allow
    ldrb w10, [x16]
    cbz w10, bad_args
    ldr x10, [x20]
    cmp x10, #8
    b.hs bad_args
    ARM_CALL next_arg
    cbz x9, bad_args
    mov x19, x9
    ldrb w10, [x19]
    cmp w10, #'/'
    b.ne bad_args
    mov x3, #0
.Lnative_directory_chars:
    ldrb w10, [x19, x3]
    cbz w10, .Lnative_directory_valid
    cmp x3, #255
    b.hs bad_args
    cmp w10, #' '
    b.lo bad_args
    cmp w10, #'~'
    b.hi bad_args
    cmp w10, #':'
    b.eq bad_args
    cmp w10, #','
    b.eq bad_args
    add x3, x3, #1
    b .Lnative_directory_chars
.Lnative_directory_valid:
    ldr x10, [x20]
    str x19, [x21, x10, lsl #3]
    add x10, x10, #1
    str x10, [x20]
    mov w9, #1
.Lnative_option_return:
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Input: parsed package fields and directory options. Output: returns when
 * compatible; exits 2 if directories were supplied for a standalone project.
 * No files change. Scratch: x9-x11/x16. Stack: none. */
native_link_check_options:
    ARM_ADDR x16, package_link
    ldrb w10, [x16]
    cbnz w10, .Lnative_options_done
    ARM_ADDR x16, native_include_count
    ldr x10, [x16]
    ARM_ADDR x16, native_library_count
    ldr x11, [x16]
    orr x10, x10, x11
    cbnz x10, bad_args
.Lnative_options_done:
    ret

/* Append one known static pointer to the 64-entry private compiler argv.
 * x19 is the caller-owned next slot. All callers prove the total below 64. */
.macro NATIVE_ARG symbol
    ARM_ADDR x9, \symbol
    str x9, [x19], #8
.endm

/* Input: validated optional checker and <=8 include directories. Output:
 * w9=child status, or 0 when absent. Uses at most 24 argv slots (capacity 64).
 * The compiler receives -fsyntax-only and never executes the checker.
 * Preserves x19-x24; stack: 32 saved bytes plus spawn_wait's frames. */
native_link_compile_check:
    ARM_ADDR x16, package_check
    ldrb w10, [x16]
    cbnz w10, .Lnative_compile_check
    mov w9, #0
    ret
.Lnative_compile_check:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_ADDR x19, native_argv
    NATIVE_ARG native_cc_path
    NATIVE_ARG native_syntax_only
    NATIVE_ARG native_c11
    NATIVE_ARG native_wall
    NATIVE_ARG native_wextra
    NATIVE_ARG native_werror
    mov x20, #0
.Lnative_compile_includes:
    ARM_ADDR x16, native_include_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lnative_compile_source
    NATIVE_ARG arg_I
    ARM_ADDR x16, native_include_dirs
    ldr x10, [x16, x20, lsl #3]
    str x10, [x19], #8
    add x20, x20, #1
    b .Lnative_compile_includes
.Lnative_compile_source:
    NATIVE_ARG package_check
    str xzr, [x19]
    ARM_ADDR x0, native_cc_path
    ARM_ADDR x1, native_argv
    ARM_CALL spawn_wait
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Input: validated native fields, <=8 library directories, completed staged
 * object. Output: w9=compiler status; success writes only the staged binary.
 * Each library flag has capacity 34 (2+31+NUL), each runtime path capacity 272
 * (11+255+NUL), and argv capacity 64 (maximum 44 pointers including NUL).
 * No package flag or shell is accepted. Preserves x19-x24; stack: 64 saved
 * bytes plus copy_string/spawn_wait. Final publication stays in build_project. */
native_link_build:
    ARM_SAVE x19
    ARM_SAVE x20
    ARM_SAVE x21
    ARM_SAVE x22
    ARM_ADDR x19, native_argv
    NATIVE_ARG native_cc_path
.if NATIVE_LINK_MACOS
    NATIVE_ARG native_mac_arch
    NATIVE_ARG native_mac_arm64
    NATIVE_ARG native_mac_minimum
    NATIVE_ARG native_mac_pie
    NATIVE_ARG native_mac_no_uuid
.else
    NATIVE_ARG native_linux_pie
    NATIVE_ARG native_linux_hardening
.endif
    NATIVE_ARG arg_o
    NATIVE_ARG stage_binary
    NATIVE_ARG stage_object
    mov x20, #0
.Lnative_link_directories:
    ARM_ADDR x16, native_library_count
    ldr x10, [x16]
    cmp x20, x10
    b.hs .Lnative_link_libraries_begin
    NATIVE_ARG native_library_search
    ARM_ADDR x16, native_library_dirs
    ldr x21, [x16, x20, lsl #3]
    str x21, [x19], #8
    mov x10, #272
    mul x10, x20, x10
    ARM_ADDR x22, native_runtime_paths
    add x22, x22, x10
    mov x0, x22
    ARM_ADDR x1, native_runtime_prefix
    ARM_CALL copy_string
    mov x0, x9
    mov x1, x21
    ARM_CALL copy_string
    str x22, [x19], #8
    add x20, x20, #1
    b .Lnative_link_directories
.Lnative_link_libraries_begin:
    ARM_ADDR x21, package_libraries
    mov x20, #0
.Lnative_link_libraries:
    ldrb w10, [x21]
    cbz w10, .Lnative_link_execute
    mov x10, #34
    mul x10, x20, x10
    ARM_ADDR x22, native_library_flags
    add x22, x22, x10
    str x22, [x19], #8
    mov w10, #'-'
    strb w10, [x22], #1
    mov w10, #'l'
    strb w10, [x22], #1
.Lnative_link_library_copy:
    ldrb w10, [x21], #1
    cbz w10, .Lnative_link_library_last
    cmp w10, #' '
    b.eq .Lnative_link_library_next
    strb w10, [x22], #1
    b .Lnative_link_library_copy
.Lnative_link_library_next:
    strb wzr, [x22]
    add x20, x20, #1
    b .Lnative_link_libraries
.Lnative_link_library_last:
    strb wzr, [x22]
.Lnative_link_execute:
    str xzr, [x19]
    ARM_ADDR x0, native_cc_path
    ARM_ADDR x1, native_argv
    ARM_CALL spawn_wait
    ARM_RESTORE x22
    ARM_RESTORE x21
    ARM_RESTORE x20
    ARM_RESTORE x19
    ret

/* Input: x0=the fixed executable pointer selected by a CLI call. Output:
 * x9=borrowed environment pointer array. C compiler children receive only
 * PATH and LC_ALL. On macOS the assembler's clang driver also uses that
 * environment for native builds. Application execution retains user settings.
 * Scratch: x9-x11/x16; stack: none; preserves callee-saved registers. */
native_link_child_environment:
    ARM_ADDR x16, native_cc_path
    cmp x0, x16
    b.eq .Lnative_fixed_environment
.if NATIVE_LINK_MACOS
    ARM_ADDR x16, as_path
    cmp x0, x16
    b.ne .Lnative_inherited_environment
    ARM_ADDR x16, package_link
    ldrb w10, [x16]
    cbnz w10, .Lnative_fixed_environment
.endif
.Lnative_inherited_environment:
    ARM_ADDR x16, envp
    ldr x9, [x16]
    ret
.Lnative_fixed_environment:
    ARM_ADDR x9, native_tool_env
    ret

.section .rodata
native_opt_include: .asciz "--include-dir"
native_opt_library: .asciz "--library-dir"
native_cc_path: .asciz "/usr/bin/cc"
native_syntax_only: .asciz "-fsyntax-only"
native_c11: .asciz "-std=c11"
native_wall: .asciz "-Wall"
native_wextra: .asciz "-Wextra"
native_werror: .asciz "-Werror"
native_library_search: .asciz "-L"
native_runtime_prefix: .asciz "-Wl,-rpath,"
native_linux_pie: .asciz "-pie"
native_linux_hardening: .asciz "-Wl,-z,relro,-z,now,-z,noexecstack"
native_mac_arch: .asciz "-arch"
native_mac_arm64: .asciz "arm64"
native_mac_minimum: .asciz "-mmacosx-version-min=15.0"
native_mac_pie: .asciz "-Wl,-pie"
native_mac_no_uuid: .asciz "-Wl,-no_uuid"
native_env_path: .asciz "PATH=/usr/bin:/bin"
native_env_locale: .asciz "LC_ALL=C"
.section .data
.balign 8
native_tool_env: .quad native_env_path, native_env_locale, 0
.section .bss
.balign 8
package_link: .skip 256
package_libraries: .skip 256
package_check: .skip 256
native_allow: .skip 1
.balign 8
native_include_count: .skip 8
native_library_count: .skip 8
native_include_dirs: .skip 64
native_library_dirs: .skip 64
native_argv: .skip 512
native_library_flags: .skip 272
native_runtime_paths: .skip 2176
.section .note.GNU-stack,"",%progbits
