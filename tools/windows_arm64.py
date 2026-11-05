#!/usr/bin/env python3
"""Prepare native Windows ARM64 assembly. This is a build tool, not a runtime.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / 'cli/windows/aarch64'
TOOL_PATHS = {
    'clang': 'C:/Program Files/LLVM/bin/clang.exe',
    'curl': 'C:/Windows/System32/curl.exe',
    'gzip': 'C:/Program Files/Git/usr/bin/gzip.exe',
    'gh': 'C:/Program Files/GitHub CLI/gh.exe',
}



def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f'expected one source anchor: {old[:100]!r}')
    return text.replace(old, new)


def routine(text: str, start: str, end: str, replacement: str) -> str:
    begin = text.index('\n' + start + ':')
    finish = text.index('\n' + end + ':', begin)
    return text[:begin] + '\n' + replacement.rstrip() + '\n' + text[finish:]


def prepare(source: Path) -> str:
    if source.name == 'platform.s':
        return (LOCAL / 'platform.s').read_text()
    if source.name == 'elf.s':
        return (LOCAL / 'pe.s').read_text()
    text = source.read_text()
    text = text.replace('aarch64-unknown-linux-gnu', 'aarch64-pc-windows-msvc')
    text = text.replace('aarch64-linux', 'aarch64-windows')
    text = re.sub(r'^\.section \.rodata$', '.section .rdata,"dr"', text, flags=re.M)
    text = re.sub(r'^\.section \.note.GNU-stack.*$', '', text, flags=re.M)
    # COFF does not support ELF .type/.size, and .arch is redundant with target.
    text = re.sub(r'^\.(?:arch|type|size)\b.*$', '', text, flags=re.M)
    if source.name == 'asm.s':
        start = '_start:\n    ARM_CALL win_startup\n    ARM_CALL win_managed_startup\n    mov x10, #1\n    ARM_ADDR x16, argi\n    str x10, [x16]\n'
        text = re.sub(r'_start:\n.*?(?=\.Lglobals:)', lambda _: start, text, count=1, flags=re.S)
        text = routine(text, 'spawn_wait', 'cmd_clean', 'spawn_wait:\n    b win_spawn_wait\n')
        text = text.replace('/usr/bin/as', 'C:/Program Files/LLVM/bin/clang.exe')
        text = text.replace('/usr/bin/ld', 'C:/Program Files/LLVM/bin/clang.exe')
        text = text.replace('GNU as + ld', 'LLVM clang + lld').replace('GNU as and ld', 'LLVM clang and lld')
        text = text.replace('registry and source commands require curl, sha256sum and gzip in /usr/bin. Install the missing tools', 'registry commands require Windows curl and Git gzip. Install the missing tools')
        text = text.replace('/usr/bin/curl', 'C:/Windows/System32/curl.exe').replace('/usr/bin/gzip', 'C:/Program Files/Git/usr/bin/gzip.exe').replace('/usr/bin/sha256sum', 'Windows BCrypt SHA-256')
        text = replace_once(text, 'as_arch: .asciz "-march=armv8-a"', 'as_arch: .asciz "-c"')
        text = replace_once(text, 'arg_z: .asciz "-z"', 'arg_z: .asciz "-nostdlib"')
        text = replace_once(text, 'noexecstack: .asciz "noexecstack"', 'noexecstack: .asciz "-Wl,/entry:_start,/subsystem:console,/dynamicbase,/nxcompat,/Brepro"')
        # Compiler argv has 16 entries. Explicit target is mandatory even on a
        # Windows host whose clang defaults to the emulated x64 environment.
        text = replace_once(text, 'ARM_ADDR x16, child_argv + 56\n    str x10, [x16]',
            'ARM_ADDR x16, child_argv + 56\n    ARM_ADDR x10, win_compile_target\n    str x10, [x16]\n    ARM_ADDR x16, child_argv + 64\n    ARM_ADDR x10, win_no_default_config\n    str x10, [x16]\n    ARM_ADDR x16, child_argv + 72\n    str xzr, [x16]')
        text = replace_once(text, 'ARM_ADDR x16, child_argv + 48\n    str x10, [x16]',
            'ARM_ADDR x16, child_argv + 48\n    ARM_ADDR x10, win_compile_target\n    str x10, [x16]\n    ARM_ADDR x16, child_argv + 56\n    ARM_ADDR x10, win_link_kernel\n    str x10, [x16]\n    ARM_ADDR x16, child_argv + 64\n    ARM_ADDR x10, win_link_lld\n    str x10, [x16]\n    ARM_ADDR x16, child_argv + 72\n    ARM_ADDR x10, win_no_default_config\n    str x10, [x16]\n    ARM_ADDR x16, child_argv + 80\n    str xzr, [x16]')
        for old, new in [('build/app"','build/app.exe"'), ('build/test"','build/test.exe"'), ('/app"','/app.exe"')]:
            text = text.replace(old, new)
        text += '\n.section .rdata,"dr"\nwin_no_default_config: .asciz "--no-default-config"\nwin_compile_target: .asciz "--target=aarch64-pc-windows-msvc"\nwin_link_kernel: .asciz "-Wl,kernel32.lib"\nwin_link_lld: .asciz "-fuse-ld=lld"\n'
        text = replace_once(text, 'valid_source:\n',
            'valid_source:\n    b win_valid_source\nwin_shared_valid_source:\n')
        text = re.sub(r'^targets_text:.*$', lambda _: 'targets_text: .asciz "aarch64-windows (host; LLVM clang + Windows SDK)\\n"', text, flags=re.M)
        text = re.sub(r'^targets_json:.*$', lambda _: 'targets_json: .asciz "{\\"host\\":\\"aarch64-windows\\",\\"targets\\":[\\"aarch64-windows\\"]}\\n"', text, flags=re.M)
        text = replace_once(text, r'\"targets\":[\"x86_64-linux\",\"aarch64-windows\",\"riscv64-linux\"]',
                            r'\"targets\":[\"aarch64-windows\"]')
    if source.name == 'cross_build.s':
        # Native table selection uses the existing build path. No foreign
        # Windows toolchain/sysroot contract has been qualified here.
        text = routine(text, 'cross_tools', 'cross_build_project',
            'cross_tools:\n.Lct_unsupported:\n.Lct_missing:\n.Lct_sysroot:\n    ARM_ADDR x0, cross_unsupported_error\n    mov w1, #2\n    b die\n')
    if source.name == 'programs.s':
        text = replace_once(text, '    ldrb w10, [x19]\n    cmp w10, #47\n    b.eq .Lp_absolute_copy',
            '    mov x0, x19\n    ARM_CALL win_is_absolute\n    cbnz w9, .Lp_absolute_copy')
        for label in ['program_path_error', '.Lp_walk_bad_initial', '.Lp_path_invalid']:
            old = f'    ldrb w10, [x19]\n    cmp w10, #47\n    b.ne {label}'
            text = replace_once(text, old, f'    mov x0, x19\n    ARM_CALL win_is_absolute\n    cbz w9, {label}')
        text = replace_once(text, '    ARM_ADDR x0, program_root',
            '    mov x0, x19\n    ARM_CALL win_drive_root\n    mov x0, x9')
        text = replace_once(text, '.Lp_absolute_done:\n    ARM_RESTORE x20', '.Lp_absolute_done:\n    ARM_ADDR x0, program_path\n    ARM_CALL win_slashes\n    ARM_RESTORE x20')
        text = replace_once(text, '    add x22, x19, #1', '    add x22, x19, #3')
        text = replace_once(text, '    add x1, x19, #1', '    add x1, x19, #3')
        text = text.replace('/.local/bin/asm"', '/.local/bin/asm.exe"')
        text = replace_once(text,
            '    ldr x0, [x19, #40]\n    ldrb w10, [x0]\n    cmp w10, #47\n    b.ne program_state_error',
            '    ldr x0, [x19, #40]\n    ARM_CALL win_is_absolute\n    cbz w9, program_state_error')
        text = replace_once(text, 'program_cli_name: .asciz "asm"', 'program_cli_name: .asciz "asm.exe"')
        text = replace_once(text, '    ldrb w10, [x0, #3]\n    cbnz w10, .Lp_cli_destination_safe',
            '    ldrb w10, [x0, #3]\n    cmp w10, #46\n    b.ne .Lp_cli_destination_safe\n    ldr w10, [x0, #4]\n    ARM_IMM w11, 0x00657865\n    ARM_IMM w12, 0x202020\n    orr w10, w10, w12\n    cmp w10, w11\n    b.ne .Lp_cli_destination_safe')
        text = replace_once(text, '.Lp_walk_component:\n', '.Lp_walk_component:\n    mov x0, x21\n    ARM_CALL win_managed_guard_fd\n    cbnz x9, .Lp_walk_bad\n')
    if source.name == 'templates.s':
        text = text.replace('.arch armv8-a\\n', '')
        text = text.replace('    mov x8, 64\\n    mov x0, 1\\n    adrp x1, message\\n    add x1, x1, :lo12:message\\n',
            '    mov w0, -11\\n    bl GetStdHandle\\n    adrp x1, message\\n    add x1, x1, :lo12:message\\n')
        text = text.replace('    mov x2, message_len\\n    svc 0\\n    mov x8, 93\\n    mov x0, 0\\n    svc 0\\n\\n',
            '    mov x2, message_len\\n    adrp x3, written\\n    add x3, x3, :lo12:written\\n    mov x4, 0\\n    bl WriteFile\\n    cbz w0, failed\\n    mov w0, 0\\n    bl ExitProcess\\nfailed:\\n    mov w0, 1\\n    bl ExitProcess\\n\\n')
        text = text.replace('    mov x8, 93\\n    mov x0, 0\\n    svc 0\\n', '    mov w0, 0\\n    bl ExitProcess\\n')
        text = text.replace('.section .rodata\\nmessage:', '.section .rdata,\\"dr\\"\\nmessage:')
        text = text.replace('.section .note.GNU-stack,\\"\\",@progbits\\n', '.bss\\n.p2align 2\\nwritten: .space 4\\n')
        text = replace_once(text,
            '    mov w0, -11\\n    bl GetStdHandle\\n    adrp x1, message\\n    add x1, x1, :lo12:message\\n',
            '    mov w0, -11\\n    bl GetStdHandle\\n    mov x19, x0\\n    adrp x20, message\\n    add x20, x20, :lo12:message\\n    mov x21, message_len\\nwrite_loop:\\n    mov x0, x19\\n    mov x1, x20\\n')
        text = replace_once(text,
            '    mov x2, message_len\\n    adrp x3, written\\n    add x3, x3, :lo12:written\\n    mov x4, 0\\n    bl WriteFile\\n    cbz w0, failed\\n    mov w0, 0\\n',
            '    mov x2, x21\\n    adrp x3, written\\n    add x3, x3, :lo12:written\\n    mov x4, 0\\n    bl WriteFile\\n    cbz w0, failed\\n    adrp x3, written\\n    add x3, x3, :lo12:written\\n    ldr w10, [x3]\\n    cbz w10, failed\\n    cmp x10, x21\\n    b.hi failed\\n    add x20, x20, x10\\n    subs x21, x21, x10\\n    b.ne write_loop\\n    mov w0, 0\\n')
    if source.name == 'dependencies.s':
        text = replace_once(text, 'dependency_acquire:\n', 'dependency_acquire:\n    ARM_CALL win_managed_check_cwd\n    cbnz x9, dependency_io_error\n')
    if source.name == 'registry.s':
        text = replace_once(text, 'registry_workspace:\n', 'registry_workspace:\n    ARM_CALL win_managed_check_cwd\n    cbnz x9, registry_io_error\n')
        text = routine(text, 'registry_download', 'registry_read_index', (LOCAL / 'download.s').read_text())
        text = routine(text, 'registry_verify_payload', 'registry_copy_local', (LOCAL / 'verify.s').read_text())
        text = text.replace('/usr/bin/curl', 'C:/Windows/System32/curl.exe')
        text = text.replace('/usr/bin/sha256sum', 'Windows BCrypt SHA-256')
        text = text.replace('index.tsv', 'index-all.tsv')
        # Preserve Linux artifact rows while adding the Windows host identity.
        for target in ['registry_host', 'target_macos_x86', 'target_windows_x86']:
            text = replace_once(text, 'registry_valid_target:\n',
                f'registry_valid_target:\n    ARM_SAVE x0\n    ARM_ADDR x1, {target}\n    ARM_CALL streq\n    ARM_RESTORE x0\n    cbnz w9, registry_valid\n')
        text = text.replace('registry_aarch64: .asciz "aarch64-windows"', 'registry_aarch64: .asciz "aarch64-linux"')
        begin = text.index('.Linstall_home:')
        end = text.index('    ARM_SAVE x0', begin)
        text = text[:begin] + '.Linstall_home:\n    add x0, x0, #5\n    ARM_CALL win_is_absolute\n    cbz w9, .Linstall_home_error\n' + text[end:]

        text = text.replace('host ELF executables', 'host ARM64 PE executables').replace('AArch64 ELF executable', 'ARM64 PE executable')
    if source.name == 'archive.s':
        begin = text.index('\narc_create_stage:')
        end = text.index('\narc_member_parent:', begin)
        stage = replace_once(text[begin:end], 'ARM_IMM w10, ARC_DIRECTORY',
                             'ARM_IMM w10, ARC_DIRECTORY | WIN_OPEN_SET_DACL')
        text = text[:begin] + stage + text[end:]
        text = routine(text, 'arc_decompress', 'arc_is_zero', (LOCAL / 'decompress.s').read_text())
        text = text.replace('/usr/bin/gzip', 'C:/Program Files/Git/usr/bin/gzip.exe')
        text = replace_once(text, '.Larc_path_last:', '.Larc_path_last:')
        begin = text.index('.Larc_path_last:')
        end = text.index('.Larc_path_bad:', begin)
        part = text[begin:end]
        part = replace_once(part, '    eor w9, w9, w9\n    tst w9, w9\n    ret', '    b win_archive_names')
        text = text[:begin] + part + text[end:]
    if source.name == 'publish.s':
        text = routine(text, 'pub_hash_payload', 'pub_append', 'pub_hash_payload:\n    ARM_ADDR x0, registry_temp_payload\n    ARM_ADDR x1, pub_hash_buffer\n    b win_hash_file\n')
        text = text.replace('ARM_CALL pub_validate_elf', 'ARM_CALL win_pub_validate_pe')
    if source.name == 'self_update_verify.s':
        text = replace_once(text,
            '    mov x0, x9\n    mov x1, x21\n    ARM_CALL copy_string\n.ifdef ASM_TRUSTED_DISTRIBUTION',
            '    mov x0, x9\n    mov x1, x21\n    ARM_CALL copy_string\n    ARM_CALL win_prepare_verifier_environment\n    tbnz x9, #63, self_io_error\n.ifdef ASM_TRUSTED_DISTRIBUTION')
        text = replace_once(text, '    ARM_ADDR x16, self_gh_environment + 10*8',
                            '    ARM_ADDR x16, self_gh_environment + 12*8')
        text = replace_once(text, '    .quad self_locale_environment, self_lang_environment',
            '    .quad self_locale_environment, self_lang_environment\n    .quad win_profile_environment, win_localappdata_environment')
        text = routine(text, 'self_capture', 'self_verifier_missing', (LOCAL / 'capture.s').read_text())
        text = text.replace('/usr/bin/gh', 'C:/Program Files/GitHub CLI/gh.exe').replace('/dev/null', 'NUL')
    if source.name == 'self_update_metadata.s':
        text = replace_once(text, 'smp_host_suffix: .asciz "-aarch64-windows"',
                            'smp_host_suffix: .asciz "-aarch64-windows.exe"')
    if source.name == 'self_update.s':
        text = text.replace('self_binary_name: .asciz "asm"', 'self_binary_name: .asciz "asm.exe"')
        text = text.replace('self_asset_suffix: .asciz "-aarch64-windows"', 'self_asset_suffix: .asciz "-aarch64-windows.exe"')
        text = routine(text, 'self_open_installation', 'self_open_parent', 'self_open_installation:\n    b win_managed_open_installation\n')
        text = routine(text, 'self_check_absolute_installation', 'self_check_file_stat', 'self_check_absolute_installation:\n    b win_managed_check_absolute_installation\n')
        text = routine(text, 'self_check_destination', 'self_release_paths', 'self_check_destination:\n    b win_managed_check_destination\n')
        text = routine(text, 'self_commit_update', 'self_update_cleanup', 'self_commit_update:\n    b win_managed_commit_update\n')
        text = replace_once(text, '    ARM_ADDR x16, self_root\n    mov x0, x16',
            '    ARM_ADDR x0, self_install_path\n    ARM_CALL win_drive_root\n    mov x0, x9')
        text = replace_once(text, '    add x16, x16, #1\n    mov x22, x16\n    eor w19', '    add x16, x16, #3\n    mov x22, x16\n    eor w19')
        text = replace_once(text, '.Lself_cleanup_done:\n', '.Lself_cleanup_done:\n    ARM_CALL win_managed_cleanup\n')
        text = text.replace('self update requires the direct HOME/.local/bin/asm installation', 'self update requires the active Windows versioned installation')
    if source.name == 'native_link.s':
        text = replace_once(text, "    ldrb w10, [x19]\n    cmp w10, #'/'\n    b.ne bad_args",
            '    mov x0, x19\n    ARM_CALL win_is_absolute\n    cbz w9, bad_args')
        text = replace_once(text, "    cmp w10, #':'\n    b.eq bad_args", "    cmp w10, #':'\n    b.ne .Lwin_native_not_colon\n    cmp x3, #1\n    b.ne bad_args\n.Lwin_native_not_colon:")
        text = routine(text, 'native_link_child_environment', '.Lnative_fixed_environment',
            'native_link_child_environment:\n    ARM_ADDR x16, native_cc_path\n    cmp x0, x16\n    b.eq .Lnative_fixed_environment\n    ARM_ADDR x16, as_path\n    cmp x0, x16\n    b.eq .Lnative_fixed_environment\n    ARM_ADDR x16, ld_path\n    cmp x0, x16\n    b.eq .Lnative_fixed_environment\n    ARM_ADDR x16, envp\n    ldr x9, [x16]\n    ret\n')
        text = text.replace('PATH=/usr/bin:/bin', 'PATH=C:/Program Files/LLVM/bin;C:/Windows/System32')
        text = text.replace('LC_ALL=C', 'SystemRoot=C:/Windows')
        text = replace_once(text, '    NATIVE_ARG native_cc_path\n    NATIVE_ARG native_syntax_only', '    NATIVE_ARG native_cc_path\n    NATIVE_ARG win_compile_target\n    NATIVE_ARG native_syntax_only')
        if text.count('    NATIVE_ARG native_cc_path\n') != 2:
            raise ValueError('expected checker and linker compiler argv anchors')
        text = text.replace('    NATIVE_ARG native_cc_path\n',
                            '    NATIVE_ARG native_cc_path\n    NATIVE_ARG win_no_default_config\n')
        text = text.replace('/usr/bin/cc', 'C:/Program Files/LLVM/bin/clang.exe')
        text = text.replace('NATIVE_ARG native_linux_pie\n    NATIVE_ARG native_linux_hardening', 'NATIVE_ARG win_compile_target\n    NATIVE_ARG win_native_hardening\n    NATIVE_ARG win_link_lld')
        text = text.replace('native_runtime_prefix: .asciz "-Wl,-rpath,"', 'native_runtime_prefix: .asciz "-L"')
        text += '\n.section .rdata,"dr"\nwin_native_hardening: .asciz "-Wl,/dynamicbase,/nxcompat,/Brepro"\n'
    if source.name == 'platform.inc':
        text += '\n.equ WIN_OPEN_IMAGE, 0x20000000\n.equ WIN_OPEN_HELD, 0x40000000\n.equ WIN_OPEN_SET_DACL, 0x04000000\n'
        text = text.replace('    str x30, [sp, #-16]!\n    bl', '    stp x29, x30, [sp, #-16]!\n    mov x29, sp\n    bl')
        text = text.replace('    ldr x30, [sp], #16', '    ldp x29, x30, [sp], #16')
    text = re.sub(r'^\.include "([^"]+)"', lambda m: prepare(ROOT / m[1]), text, flags=re.M)
    if source.name == 'asm.s':
        text += '\n' + '\n'.join((LOCAL / name).read_text() for name in ['files.s', 'security.s', 'process.s', 'pipe.s', 'hash.s', 'update.s', 'managed.s', 'launcher.s', 'versioned_update.s'])
        import importlib.util
        import sys
        if str(ROOT / 'tools') not in sys.path:
            sys.path.insert(0, str(ROOT / 'tools'))
        metadata_spec = importlib.util.spec_from_file_location('asm_windows_layout', ROOT / 'tools/windows_layout.py')
        metadata_module = importlib.util.module_from_spec(metadata_spec)
        metadata_spec.loader.exec_module(metadata_module)
        version = re.search(r'version_text: \.asciz "asm ([0-9]+\.[0-9]+\.[0-9]+) ', source.read_text())
        if not version:
            raise ValueError('built CLI version is missing')
        text += '\n' + metadata_module.metadata_assembly(version.group(1), 'aarch64')
        unsupported = r'ARM_CALL (arm_(?:fork|execve|wait4|readlink|readlinkat|fstatfs|rt_sigaction|rt_sigprocmask|getrlimit|setrlimit|prlimit64|alarm|kill|pipe2|dup2|uname|mmap|mprotect|munmap|umask))\b'
        match = re.search(unsupported, text)
        if match:
            raise ValueError(f'unhandled Linux platform call: {match.group(1)}')
        called_adapters = set(re.findall(r'\bARM_CALL\s+(arm_\w+)', text))
        defined_adapters = set(re.findall(r'^(arm_\w+):', text, flags=re.M))
        missing = called_adapters - defined_adapters
        if missing:
            raise ValueError('missing Windows adapters: ' + ', '.join(sorted(missing)))
        if re.search(r'\b[wx]18\b', re.sub(r'/\*.*?\*/', '', text, flags=re.S)):
            raise ValueError('Windows platform register x18 must remain untouched')
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    for tool in TOOL_PATHS:
        parser.add_argument(f'--{tool}-path')
    args = parser.parse_args()
    for tool, default in list(TOOL_PATHS.items()):
        value = getattr(args, f'{tool}_path')
        if value is not None:
            if not re.fullmatch(r'[A-Za-z]:/[^\\\"\r\n\x00]+\.exe', value):
                parser.error(f'{tool} path must be an absolute forward-slash .exe path')
            TOOL_PATHS[tool] = value
    text = prepare(ROOT / 'cli/aarch64/asm.s')
    if re.search(r'\b(?:svc|arm_fork|arm_execve|arm_wait4)\b', text):
        raise ValueError('unhandled Linux process/syscall assumption')
    for tool, original in {
        'clang': 'C:/Program Files/LLVM/bin/clang.exe',
        'curl': 'C:/Windows/System32/curl.exe',
        'gzip': 'C:/Program Files/Git/usr/bin/gzip.exe',
        'gh': 'C:/Program Files/GitHub CLI/gh.exe',
    }.items():
        text = text.replace(original, TOOL_PATHS[tool])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)


if __name__ == '__main__':
    main()
