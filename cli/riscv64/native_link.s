/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Prepared from cli/aarch64/native_link.s by tools/riscv64.py.
 * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.
 * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.
 */
/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (c) 2026 ASM contributors
 * Bounded native-library build inputs and direct compiler invocation.
 * See docs/native-linking.md. This is CLI logic, not a package backend.
 */
.equ NATIVE_LINK_MACOS, 0
.global native_link_validate, package_link, package_libraries, package_check
.section .text
/* Input: a0=link, a1=library list, a2=check path, all NUL-terminated strings
 * with at most 255 bytes. Empty strings represent absent optional fields.
 * Output: t0=1 for the native-link contract, otherwise 0. Does not change
 * inputs or global package state. Preserves s0-s5; stack: 48 saved bytes.
 * valid_source supplies the existing relative-path syntax check. */
native_link_validate:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, a1
    mv s1, a2
    mv s8, a0
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link22
    tail .Lnative_validate_absent
.Lrv_cb_skip_native_link22:
    mv s8, t1
    li s10, 'c'
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lnative_validate_bad
    li s10, 1
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link26
    tail .Lnative_validate_bad
.Lrv_cb_skip_native_link26:
    mv a0, s0
    li a4, 0
    RV_ZEXT a4
    li a5, 0
    RV_ZEXT a5
    mv s8, a0
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link31
    tail .Lnative_validate_check
.Lrv_cb_skip_native_link31:
.Lnative_library_start:
    li s10, 1
    add a5, a5, s10
    RV_ZEXT a5
    mv s8, a5
    li s10, 8
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lnative_validate_bad
    mv s10, a4
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 'a'
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lnative_validate_bad
    mv s8, t1
    li s10, 'z'
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lnative_validate_bad
    li a6, 0
    RV_ZEXT a6
.Lnative_library_chars:
    mv s8, a4
    li s10, 255
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lnative_validate_bad
    li s10, 1
    add a4, a4, s10
    RV_ZEXT a4
    li s10, 1
    add a6, a6, s10
    RV_ZEXT a6
    mv s8, a6
    li s10, 31
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lnative_validate_bad
    mv s10, a4
    add s8, a0, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link50
    tail .Lnative_validate_check
.Lrv_cb_skip_native_link50:
    mv s8, t1
    li s10, ' '
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lnative_library_separator
    mv s8, t1
    li s10, 'a'
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lnative_library_digit
    mv s8, t1
    li s10, 'z'
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lnative_library_chars
.Lnative_library_digit:
    mv s8, t1
    li s10, '0'
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lnative_library_punctuation
    mv s8, t1
    li s10, '9'
    RV_FLAGS sub, 32
    RV_BCOND ls, .Lnative_library_chars
.Lnative_library_punctuation:
    mv s8, t1
    li s10, '_'
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lnative_library_chars
    mv s8, t1
    li s10, '-'
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lnative_library_chars
    tail .Lnative_validate_bad
.Lnative_library_separator:
    li s10, 1
    add a4, a4, s10
    RV_ZEXT a4
    mv s8, a4
    li s10, 255
    RV_FLAGS sub, 32
    RV_BCOND hs, .Lnative_validate_bad
    tail .Lnative_library_start
.Lnative_validate_check:
    mv s8, s1
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link75
    tail .Lnative_validate_good
.Lrv_cb_skip_native_link75:
    li s2, 0
.Lnative_check_length:
    mv s10, s2
    add s8, s1, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link79
    tail .Lnative_check_suffix
.Lrv_cb_skip_native_link79:
    mv s8, t1
    li s10, ' '
    RV_FLAGS sub, 32
    RV_BCOND lo, .Lnative_validate_bad
    mv s8, t1
    li s10, '~'
    RV_FLAGS sub, 32
    RV_BCOND hi, .Lnative_validate_bad
    mv s8, t1
    li s10, 92
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lnative_validate_bad
    li s10, 1
    add s2, s2, s10
    mv s8, s2
    li s10, 255
    RV_FLAGS sub, 64
    RV_BCOND hi, .Lnative_validate_bad
    tail .Lnative_check_length
.Lnative_check_suffix:
    mv s8, s2
    li s10, 2
    RV_FLAGS sub, 64
    RV_BCOND lo, .Lnative_validate_bad
    li s10, 2
    sub s2, s2, s10
    mv s10, s2
    add s8, s1, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, '.'
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lnative_validate_bad
    li s10, 1
    add s2, s2, s10
    mv s10, s2
    add s8, s1, s10
    RV_LOAD t1, 1
    mv s8, t1
    li s10, 'c'
    RV_FLAGS sub, 32
    RV_BCOND ne, .Lnative_validate_bad
    mv a0, s1
    RV_CALL valid_source
    mv s8, t0
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link103
    tail .Lnative_validate_bad
.Lrv_cb_skip_native_link103:
    tail .Lnative_validate_good
.Lnative_validate_absent:
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link107
    tail .Lnative_validate_bad
.Lrv_cb_skip_native_link107:
    mv s8, s1
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link109
    tail .Lnative_validate_bad
.Lrv_cb_skip_native_link109:
.Lnative_validate_good:
    li t0, 1
    RV_ZEXT t0
    tail .Lnative_validate_return
.Lnative_validate_bad:
    li t0, 0
    RV_ZEXT t0
.Lnative_validate_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Input: t0=current borrowed argv option. Output: t0=1 if consumed, else 0.
 * Native directory options require native_allow. Stores at most eight borrowed
 * argv pointers per kind after checking absolute, printable ASCII paths of
 * 1..255 bytes without colon or comma. Invalid input exits 2 before writes to
 * the project. Preserves s0-s5; stack: 48 saved bytes plus nested calls. */
native_link_option:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    mv s0, t0
    mv a0, s0
    RV_ADDR a1, native_opt_include
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link134
    tail .Lnative_include_option
.Lrv_cb_skip_native_link134:
    mv a0, s0
    RV_ADDR a1, native_opt_library
    RV_CALL streq
    mv s8, t0
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link138
    tail .Lnative_library_option
.Lrv_cb_skip_native_link138:
    li t0, 0
    RV_ZEXT t0
    tail .Lnative_option_return
.Lnative_include_option:
    RV_ADDR s1, native_include_count
    RV_ADDR s2, native_include_dirs
    tail .Lnative_directory_option
.Lnative_library_option:
    RV_ADDR s1, native_library_count
    RV_ADDR s2, native_library_dirs
.Lnative_directory_option:
    RV_ADDR s6, native_allow
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link151
    tail bad_args
.Lrv_cb_skip_native_link151:
    mv s8, s1
    RV_LOAD t1, 8
    mv s8, t1
    li s10, 8
    RV_FLAGS sub, 64
    RV_BCOND hs, bad_args
    RV_CALL next_arg
    mv s8, t0
    bnez s8, .Lrv_cb_skip_native_link156
    tail bad_args
.Lrv_cb_skip_native_link156:
    mv s0, t0
    mv s8, s0
    RV_LOAD t1, 1
    mv s8, t1
    li s10, '/'
    RV_FLAGS sub, 32
    RV_BCOND ne, bad_args
    li a3, 0
.Lnative_directory_chars:
    mv s10, a3
    add s8, s0, s10
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link164
    tail .Lnative_directory_valid
.Lrv_cb_skip_native_link164:
    mv s8, a3
    li s10, 255
    RV_FLAGS sub, 64
    RV_BCOND hs, bad_args
    mv s8, t1
    li s10, ' '
    RV_FLAGS sub, 32
    RV_BCOND lo, bad_args
    mv s8, t1
    li s10, '~'
    RV_FLAGS sub, 32
    RV_BCOND hi, bad_args
    mv s8, t1
    li s10, ':'
    RV_FLAGS sub, 32
    RV_BCOND eq, bad_args
    mv s8, t1
    li s10, ','
    RV_FLAGS sub, 32
    RV_BCOND eq, bad_args
    li s10, 1
    add a3, a3, s10
    tail .Lnative_directory_chars
.Lnative_directory_valid:
    mv s8, s1
    RV_LOAD t1, 8
    mv s10, t1
    slli s10, s10, 3
    add s8, s2, s10
    RV_STORE s0, 8
    li s10, 1
    add t1, t1, s10
    mv s8, s1
    RV_STORE t1, 8
    li t0, 1
    RV_ZEXT t0
.Lnative_option_return:
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Input: parsed package fields and directory options. Output: returns when
 * compatible; exits 2 if directories were supplied for a standalone project.
 * No files change. Scratch: t0-t2/s6. Stack: none. */
native_link_check_options:
    RV_ADDR s6, package_link
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link195
    tail .Lnative_options_done
.Lrv_cb_skip_native_link195:
    RV_ADDR s6, native_include_count
    mv s8, s6
    RV_LOAD t1, 8
    RV_ADDR s6, native_library_count
    mv s8, s6
    RV_LOAD t2, 8
    mv s10, t2
    or t1, t1, s10
    mv s8, t1
    beqz s8, .Lrv_cb_skip_native_link201
    tail bad_args
.Lrv_cb_skip_native_link201:
.Lnative_options_done:
    ret
/* Append one known static pointer to the 64-entry private compiler argv.
 * s0 is the caller-owned next slot. All callers prove the total below 64. */
.macro NATIVE_ARG symbol
    RV_ADDR t0, \symbol
    mv s8, s0
    RV_STORE t0, 8
    li s10, 8
    add s0, s0, s10
.endm
/* Input: validated optional checker and <=8 include directories. Output:
 * t0=child status, or 0 when absent. Uses at most 24 argv slots (capacity 64).
 * The compiler receives -fsyntax-only and never executes the checker.
 * Preserves s0-s5; stack: 32 saved bytes plus spawn_wait's frames. */
native_link_compile_check:
    RV_ADDR s6, package_check
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link219
    tail .Lnative_compile_check
.Lrv_cb_skip_native_link219:
    li t0, 0
    RV_ZEXT t0
    ret
.Lnative_compile_check:
    RV_SAVE s0
    RV_SAVE s1
    RV_ADDR s0, native_argv
    NATIVE_ARG native_cc_path
    NATIVE_ARG rv_cc_arch
    NATIVE_ARG rv_cc_abi
    NATIVE_ARG native_syntax_only
    NATIVE_ARG native_c11
    NATIVE_ARG native_wall
    NATIVE_ARG native_wextra
    NATIVE_ARG native_werror
    li s1, 0
.Lnative_compile_includes:
    RV_ADDR s6, native_include_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lnative_compile_source
    NATIVE_ARG arg_I
    RV_ADDR s6, native_include_dirs
    mv s10, s1
    slli s10, s10, 3
    add s8, s6, s10
    RV_LOAD t1, 8
    mv s8, s0
    RV_STORE t1, 8
    li s10, 8
    add s0, s0, s10
    li s10, 1
    add s1, s1, s10
    tail .Lnative_compile_includes
.Lnative_compile_source:
    NATIVE_ARG package_check
    mv s8, s0
    RV_STORE zero, 8
    RV_ADDR a0, native_cc_path
    RV_ADDR a1, native_argv
    RV_CALL spawn_wait
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Input: validated native fields, <=8 library directories, completed staged
 * object. Output: t0=compiler status; success writes only the staged binary.
 * Each library flag has capacity 34 (2+31+NUL), each runtime path capacity 272
 * (11+255+NUL), and argv capacity 64 (maximum 44 pointers including NUL).
 * No package flag or shell is accepted. Preserves s0-s5; stack: 64 saved
 * bytes plus copy_string/spawn_wait. Final publication stays in build_project. */
native_link_build:
    RV_SAVE s0
    RV_SAVE s1
    RV_SAVE s2
    RV_SAVE s3
    RV_ADDR s0, native_argv
    NATIVE_ARG native_cc_path
    NATIVE_ARG rv_cc_arch
    NATIVE_ARG rv_cc_abi
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
    li s1, 0
.Lnative_link_directories:
    RV_ADDR s6, native_library_count
    mv s8, s6
    RV_LOAD t1, 8
    mv s8, s1
    mv s10, t1
    RV_FLAGS sub, 64
    RV_BCOND hs, .Lnative_link_libraries_begin
    NATIVE_ARG native_library_search
    RV_ADDR s6, native_library_dirs
    mv s10, s1
    slli s10, s10, 3
    add s8, s6, s10
    RV_LOAD s2, 8
    mv s8, s0
    RV_STORE s2, 8
    li s10, 8
    add s0, s0, s10
    li t1, 272
    mv s10, t1
    mul t1, s1, s10
    RV_ADDR s3, native_runtime_paths
    mv s10, t1
    add s3, s3, s10
    mv a0, s3
    RV_ADDR a1, native_runtime_prefix
    RV_CALL copy_string
    mv a0, t0
    mv a1, s2
    RV_CALL copy_string
    mv s8, s0
    RV_STORE s3, 8
    li s10, 8
    add s0, s0, s10
    li s10, 1
    add s1, s1, s10
    tail .Lnative_link_directories
.Lnative_link_libraries_begin:
    RV_ADDR s2, package_libraries
    li s1, 0
.Lnative_link_libraries:
    mv s8, s2
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link312
    tail .Lnative_link_execute
.Lrv_cb_skip_native_link312:
    li t1, 34
    mv s10, t1
    mul t1, s1, s10
    RV_ADDR s3, native_library_flags
    mv s10, t1
    add s3, s3, s10
    mv s8, s0
    RV_STORE s3, 8
    li s10, 8
    add s0, s0, s10
    li t1, '-'
    RV_ZEXT t1
    mv s8, s3
    RV_STORE t1, 1
    li s10, 1
    add s3, s3, s10
    li t1, 'l'
    RV_ZEXT t1
    mv s8, s3
    RV_STORE t1, 1
    li s10, 1
    add s3, s3, s10
.Lnative_link_library_copy:
    mv s8, s2
    RV_LOAD t1, 1
    li s10, 1
    add s2, s2, s10
    mv s8, t1
    RV_ZEXT s8
    bnez s8, .Lrv_cb_skip_native_link324
    tail .Lnative_link_library_last
.Lrv_cb_skip_native_link324:
    mv s8, t1
    li s10, ' '
    RV_FLAGS sub, 32
    RV_BCOND eq, .Lnative_link_library_next
    mv s8, s3
    RV_STORE t1, 1
    li s10, 1
    add s3, s3, s10
    tail .Lnative_link_library_copy
.Lnative_link_library_next:
    mv s8, s3
    RV_STORE zero, 1
    li s10, 1
    add s1, s1, s10
    tail .Lnative_link_libraries
.Lnative_link_library_last:
    mv s8, s3
    RV_STORE zero, 1
.Lnative_link_execute:
    mv s8, s0
    RV_STORE zero, 8
    RV_ADDR a0, native_cc_path
    RV_ADDR a1, native_argv
    RV_CALL spawn_wait
    RV_RESTORE s3
    RV_RESTORE s2
    RV_RESTORE s1
    RV_RESTORE s0
    ret
/* Input: a0=the fixed executable pointer selected by a CLI call. Output:
 * t0=borrowed environment pointer array. C compiler children receive only
 * PATH and LC_ALL. On macOS the assembler's clang driver also uses that
 * environment for native builds. Application execution retains user settings.
 * Scratch: t0-t2/s6; stack: none; preserves callee-saved registers. */
native_link_child_environment:
    RV_ADDR s6, native_cc_path
    mv s8, a0
    mv s10, s6
    RV_FLAGS sub, 64
    RV_BCOND eq, .Lnative_fixed_environment
.if NATIVE_LINK_MACOS
    RV_ADDR s6, as_path
    mv s8, a0
    mv s10, s6
    RV_FLAGS sub, 64
    RV_BCOND ne, .Lnative_inherited_environment
    RV_ADDR s6, package_link
    mv s8, s6
    RV_LOAD t1, 1
    mv s8, t1
    RV_ZEXT s8
    beqz s8, .Lrv_cb_skip_native_link361
    tail .Lnative_fixed_environment
.Lrv_cb_skip_native_link361:
.endif
.Lnative_inherited_environment:
    RV_ADDR s6, envp
    mv s8, s6
    RV_LOAD t0, 8
    ret
.Lnative_fixed_environment:
    RV_ADDR t0, native_tool_env
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
.section .note.GNU-stack,""
