#!/usr/bin/env python3
"""Prepare shared assembly for Apple's assembler; no CLI runtime logic.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[1]

def prepare(source: Path) -> str:
    text = source.read_text()
    if source.name == 'platform.s':
        return (ROOT / 'cli/macos/platform.s').read_text()
    if source.name == 'elf.s':
        return (ROOT / 'cli/macos/macho.s').read_text()
    text = text.replace('aarch64-unknown-linux-gnu', 'arm64-apple-macos').replace('aarch64-linux', 'aarch64-macos')
    text = text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    text = text.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    text = text.replace('.section .text', '.text').replace('.section .rodata', '.data').replace('.section .data', '.data')
    text = re.sub(r'^\.section \.note.GNU-stack.*$', '', text, flags=re.M)
    text = text.replace('.section .bss', '.data')
    text = re.sub(r'^(\w+): \.skip (.+)$', r'.zerofill __DATA,__bss,\1,\2,3', text, flags=re.M)
    text = re.sub(r'^(\w+:)?(\s*)\.quad', r'.p2align 3\n\1\2.quad', text, flags=re.M)
    if source.name == 'asm.s':
        text = text.replace('/usr/bin/sha256sum', '/usr/bin/shasum').replace('GNU as + ld', 'Apple clang + libSystem').replace('GNU as and ld', 'Apple clang')
        text = text.replace('/usr/bin/as', '/usr/bin/clang').replace('/usr/bin/ld', '/usr/bin/clang')
        start = '''_main:
    ARM_ADDR x16, argc
    str x0, [x16]
    ARM_ADDR x16, argv
    str x1, [x16]
    ARM_ADDR x16, envp
    str x2, [x16]
    mov x10, #1
    ARM_ADDR x16, argi
    str x10, [x16]
'''
        text = text.replace('.global _start', '.global _main')
        text = re.sub(r'_start:\n.*?(?=\.Lglobals:)', lambda m: start, text, count=1, flags=re.S)
        text = text.replace('as_arch: .asciz "-march=armv8-a"', 'as_arch: .asciz "-c"')
        text = text.replace('arg_z: .asciz "-z"', 'arg_z: .asciz "-arch"')
        text = text.replace('noexecstack: .asciz "noexecstack"', 'noexecstack: .asciz "arm64"')
    if source.name == 'self_update.s':
        text = text.replace('ARM_CALL arm_open\n    tst x9, x9\n    b.mi self_installation_error',
                            'ARM_CALL mac_open_running_image\n    cmn x9, #13\n    b.eq self_permissions_error\n    tst x9, x9\n    b.mi self_installation_error')
        text = text.replace('check ownership and write permissions from / through HOME/.local/bin',
                            'check ownership, write permissions, and ACL allow entries from / through HOME/.local/bin')
        text = text.replace('a supported local filesystem; use your package manager or install the verified release manually',
                            'local APFS with ownership enabled; choose a protected APFS installation path')
        # Darwin's shared sticky temporary directory has a canonical path.
        old_tmp = '    ARM_IMM w11, 4\n    cmp w2, w11\n    b.ne .Lself_walk_bad_permissions\n    mov x16, x21 /* exact /tmp */\n    ldr w10, [x16]\n    ARM_IMM w11, 1886221359\n'
        new_tmp = '    ARM_IMM w11, 12\n    cmp w2, w11\n    b.ne .Lself_walk_bad_permissions\n    mov x16, x21 /* exact /private/tmp */\n    ldr x10, [x16]\n    ARM_IMM x11, 0x657461766972702f\n    cmp x10, x11\n    b.ne .Lself_walk_bad_permissions\n    ldr w10, [x16, #8]\n    ARM_IMM w11, 0x706d742f\n'
        assert text.count(old_tmp) == 1
        text = text.replace(old_tmp, new_tmp)
        text = text.replace('ARM_ADDR x16, self_proc_exe\n    mov x0, x16\n    ARM_IMM w10, O_CLOEXEC',
                            'ARM_ADDR x16, self_exe_path\n    mov x0, x16\n    ARM_IMM w10, O_CLOEXEC')
        begin = text.index('    ARM_ADDR x16, self_filesystem_stat\n    ldr w10')
        end = text.index('.Lself_local_filesystem:', begin)
        text = text[:begin] + '    ARM_ADDR x16, self_filesystem_stat\n    ldr w10, [x16]\n    ARM_IMM w11, 0x41504653\n    cmp w10, w11\n    b.ne self_filesystem_error\n' + text[end:]
    if source.name == 'self_update_trust.s':
        text = text.replace('self_trust_index: .asciz "index.tsv"', 'self_trust_index: .asciz "index-macos.tsv"')
    if source.name == 'self_update_verify.s':
        text = text.replace('/usr/bin/gh', '/opt/homebrew/bin/gh')
    if source.name == 'registry.s':
        text = text.replace('https://asm.build/registry/v1/index.tsv', 'https://asm.build/registry/v1/index-macos.tsv')
        text = text.replace('registry_aarch64: .asciz "aarch64-macos"', 'registry_aarch64: .asciz "aarch64-linux"')
        text = text.replace('a supported AArch64 ELF executable', 'a supported arm64 Mach-O executable')

        text = text.replace('/usr/bin/sha256sum', '/usr/bin/shasum')
        text = text.replace('registry_sha_argv + 24', 'registry_sha_argv + 32')
        text = text.replace('.quad registry_sha256sum, registry_sha_status, registry_sha_check, 0, 0',
                            '.quad registry_sha256sum, mac_sha256_option, registry_sha_status, registry_sha_check, 0, 0')
        text += '\n.data\nmac_sha256_option: .asciz "-a256"\n'
    if source.name == 'publish.s':
        text = text.replace('ARM_CALL pub_validate_elf', 'ARM_CALL mac_pub_validate_executable')
        text += (ROOT / 'cli/macos/publish.s').read_text()
        text = text.replace('.quad registry_sha256sum, 0', '.quad registry_sha256sum, mac_sha256_option, 0')
    if source.name == 'templates.s':
        text = text.replace('_start', '_main')
        # These are MIT starter strings, using the documented libSystem ABI.
        text = text.replace('.arch armv8-a\\n.global _start\\n\\n.section .text\\n_start:', '.global _main\\n.text\\n_main:')
        text = text.replace('    mov x8, 64\\n    mov x0, 1\\n    adrp x1, message\\n    add x1, x1, :lo12:message\\n',
                            '    mov x0, 1\\n    adrp x1, message@PAGE\\n    add x1, x1, message@PAGEOFF\\n')
        text = text.replace('    mov x2, message_len\\n    svc 0\\n    mov x8, 93\\n    mov x0, 0\\n    svc 0\\n\\n',
                            '    mov x2, message_len\\n    bl _write\\n    mov x0, 0\\n    bl _exit\\n\\n')
        text = text.replace('    mov x8, 93\\n    mov x0, 0\\n    svc 0\\n', '    mov x0, 0\\n    bl _exit\\n')
        text = text.replace('.section .rodata\\nmessage:', '.data\\nmessage:')
        text = text.replace('.section .note.GNU-stack,\\"\\",@progbits\\n', '')
    text = re.sub(r'^\.include "([^"]+)"', lambda m: prepare(ROOT / m[1]), text, flags=re.M)
    return text

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(prepare(ROOT / 'cli/aarch64/asm.s'))
