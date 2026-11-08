#!/usr/bin/env python3
"""Build-time assembly preparation for Intel Darwin. No runtime command logic.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import json
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]


def prepare(source: Path) -> str:
    if source.name == 'elf.s':
        return (ROOT / 'cli/macos/x86_64/macho.s').read_text()
    text = source.read_text()
    if source.name == 'asm.s':
        # Only native identity changes. Recipe IDs and foreign tool triples
        # retain Linux names even when the CLI itself runs on Darwin.
        labels = ('host_target', 'host_target_alias', 'version_text', 'version_json',
                  'doctor_text', 'doctor_json')
        text = re.sub(r'^(?:' + '|'.join(labels) + r'):.*$',
                      lambda m: m[0].replace('x86_64-unknown-linux-gnu', 'x86_64-apple-macos')
                                    .replace('x86_64-linux', 'x86_64-macos'), text, flags=re.M)
        build_targets = ['x86_64-linux', 'aarch64-linux', 'riscv64-linux', 'x86_64-macos']
        report = {'host': 'x86_64-macos', 'targets': build_targets}
        text = re.sub(r'^targets_json:.*$', lambda m: 'targets_json: .asciz ' +
                      json.dumps(json.dumps(report, separators=(',', ':')) + '\n'), text, flags=re.M)
        target_text = 'x86_64-macos (host; Apple clang + libSystem)\n' + ''.join(
            target + ' (cross; LLVM)\n' for target in build_targets[:-1])
        text = re.sub(r'^targets_text:.*$', lambda m: 'targets_text: .asciz ' + json.dumps(target_text), text, flags=re.M)
        match = re.search(r'(status_json:\n\s*\.ascii )(.+)', text)
        status = json.loads(json.loads(match[2]) + ']}')
        status['targets'] = build_targets
        text = text[:match.start(2)] + json.dumps(json.dumps(status, separators=(',', ':')).removesuffix(']}')) + text[match.end(2):]
        text = text.replace('.global _start', '.global _main')
        text = re.sub(r'_start:\n.*?(?=\.Lglobals:)', '''_main:
    cld
    mov [rip + argc], rdi
    mov [rip + argv], rsi
    mov [rip + envp], rdx
    mov qword ptr [rip + argi], 1
''', text, count=1, flags=re.S)
        text = text.replace('/usr/bin/as', '/usr/bin/clang').replace('/usr/bin/ld', '/usr/bin/clang')
        text = text.replace('as_64: .asciz "--64"', 'as_64: .asciz "-c"')
        text = text.replace('arg_z: .asciz "-z"', 'arg_z: .asciz "-arch"')
        text = text.replace('noexecstack: .asciz "noexecstack"', 'noexecstack: .asciz "x86_64"')
        # clang is a universal tool. Force its assembler target even under Rosetta.
        begin = text.index('build_project:')
        end = text.index('cleanup_stage:', begin)
        block = text[begin:end]
        assert block.count('call spawn_wait') == 2
        block = block.replace('call spawn_wait', 'call mac_assemble_wait', 1)
        block = block.replace('call spawn_wait', 'call mac_link_wait', 1)
        text = text[:begin] + block + text[end:]
        text = text.replace('GNU as + ld', 'Apple clang + libSystem').replace('GNU as and ld', 'Apple clang')
        text = text.replace('host ELF executable', 'host Mach-O executable')
    if source.name == 'native_link.s':
        text = text.replace('native_hardening: .asciz \"-Wl,-z,relro,-z,now,-z,noexecstack\"', 'native_hardening: .asciz \"-Wl,-adhoc_codesign\"')
        text = text.replace('    call spawn_wait', '    call mac_cc_wait')
    if source.name == 'registry.s':
        text = text.replace('registry_host: .asciz "x86_64-linux"', 'registry_host: .asciz "x86_64-macos"')
        text = text.replace('installation requires x86_64-linux', 'installation requires x86_64-macos')
        text = text.replace('source and x86_64-linux.', 'source and x86_64-macos.')
        text = text.replace('https://asm.build/registry/v1/index.tsv', 'https://asm.build/registry/v1/index-macos.tsv')
        text = text.replace('registry_sha_argv + 24', 'registry_sha_argv + 32')
        text = text.replace('.quad registry_sha256sum, registry_sha_status, registry_sha_check, 0, 0',
                            '.quad registry_sha256sum, mac_sha256_option, registry_sha_status, registry_sha_check, 0, 0')
        # The host plus all existing index targets remain distinct.
        text = text.replace('registry_macos: .asciz "aarch64-macos"',
                            'registry_macos: .asciz "aarch64-macos"\nregistry_linux_x86: .asciz "x86_64-linux"')
        text = text.replace('registry_valid_target:\n', '''registry_valid_target:
    push rdi
    lea rsi, [rip + registry_linux_x86]
    call streq
    pop rdi
    test eax, eax
    jnz registry_valid
''')
        text = text.replace('a supported x86-64 ELF executable', 'a supported x86-64 Mach-O executable')
    if source.name == 'publish.s':
        text = text.replace('.quad registry_host, 4, registry_aarch64, 8',
                            '.quad registry_linux_x86, 4, registry_aarch64, 8')
        text = text.replace('call pub_validate_elf', 'call mac_pub_validate_executable')
        text = text.replace('.quad registry_sha256sum, 0', '.quad registry_sha256sum, mac_sha256_option, 0')
        text += (ROOT / 'cli/macos/x86_64/publish.s').read_text()
    if source.name == 'registry_v2.s':
        text = text.replace('build/asm-verify-x86_64-linux', 'build/asm-verify-x86_64-macos')
    if source.name == 'self_update.s':
        text = text.replace('self_asset_suffix: .asciz "-x86_64-linux"',
                            'self_asset_suffix: .asciz "-x86_64-macos"')
        old = '''    mov eax, 2
    lea rdi, [rip + self_proc_exe]
    mov esi, O_CLOEXEC + O_NONBLOCK
    xor edx, edx
    syscall
    test rax, rax
    js self_installation_error'''
        new = '''    lea rdi, [rip + self_exe_path]
    call mac_open_running_image
    cmp rax, -13
    je self_permissions_error
    test rax, rax
    js self_installation_error'''
        assert text.count(old) == 1
        text = text.replace(old, new)
        begin = text.index('    mov eax, [rip + self_filesystem_stat]')
        end = text.index('.Lself_local_filesystem:', begin)
        text = text[:begin] + '''    cmp dword ptr [rip + self_filesystem_stat], 0x41504653
    jne self_filesystem_error
''' + text[end:]
        text = text.replace('cmp edx, 4\n    jne .Lself_walk_bad_permissions\n    cmp dword ptr [r12], 0x706d742f /* exact /tmp */',
                            'cmp edx, 12\n    jne .Lself_walk_bad_permissions\n    mov rax, 0x657461766972702f\n    cmp qword ptr [r12], rax\n    jne .Lself_walk_bad_permissions\n    cmp dword ptr [r12 + 8], 0x706d742f /* exact /private/tmp */')
        text = text.replace('a supported local filesystem; use your package manager or install the verified release manually',
                            'local APFS with ownership enabled; choose a protected APFS installation path')
    if source.name == 'self_update_metadata.s':
        text = text.replace('smp_host: .asciz "x86_64-linux"', 'smp_host: .asciz "x86_64-macos"')
        text = text.replace('smp_host_suffix: .asciz "-x86_64-linux"', 'smp_host_suffix: .asciz "-x86_64-macos"')
    if source.name == 'self_update_verify.s':
        text = text.replace('/usr/bin/gh', '/usr/local/bin/gh')
    if source.name == 'self_update_trust.s':
        text = text.replace('build/asm-verify-x86_64-linux', 'build/asm-verify-x86_64-macos')
        text = text.replace('mov edx, self_helper_end - self_helper_bytes', 'mov edx, OFFSET mac_self_helper_length')
        text += '\n.equ mac_self_helper_length, self_helper_end - self_helper_bytes\n'
        text = text.replace('self_trust_index: .asciz "index.tsv"', 'self_trust_index: .asciz "index-macos.tsv"')
    if source.name == 'programs.s':
        # Identity-only mode-000 probes must not be opened to authorize a file.
        text = text.replace('mov eax, 5\n    syscall\n    test rax, rax\n    js program_probe_error',
                            'mov eax, 1005\n    syscall\n    test rax, rax\n    js program_probe_error')
        for label, endlabel in [('program_remove_probe:', 'program_regular_stat:'), ('.Lp_new_path_probe:', '.Lp_new_path_done:')]:
            if label in text and endlabel in text:
                start = text.index(label)
                end = text.index(endlabel, start)
                part = text[start:end].replace('mov eax, 5\n', 'mov eax, 1005\n').replace('mov eax, 262\n', 'mov eax, 1262\n')
                text = text[:start] + part + text[end:]
    if source.name == 'templates.s':
        text = text.replace('x86_64-linux', 'x86_64-macos')
        text = text.replace('_start', '_main')
        text = text.replace('    mov eax, 1\\n    mov edi, 1', '    push rbp\\n    mov rbp, rsp\\n    mov edi, 1')
        text = text.replace('mov edx, OFFSET message_len\\n    syscall\\n    mov eax, 60\\n    xor edi, edi\\n    syscall',
                            'mov edx, OFFSET message_len\\n    call _write\\n    xor edi, edi\\n    call _exit')
        text = text.replace('    mov eax, 60\\n    xor edi, edi\\n    syscall',
                            '    push rbp\\n    mov rbp, rsp\\n    xor edi, edi\\n    call _exit')
        text = text.replace('.section .text', '.text').replace('.section .rodata', '.data')
        text = text.replace('.section .note.GNU-stack,\\"\\",@progbits\\n', '')
    if source.name == 'cross_build.s':
        text = text.replace('cross_tools:\n', 'cross_tools:\n    jmp mac_cross_tools\n', 1)
        begin = text.index('cross_build_project:')
        end = text.index('project_build_report:', begin)
        block = text[begin:end]
        assert block.count('call spawn_wait') == 2
        block = block.replace('call spawn_wait', 'call mac_cross_assemble_wait', 1)
        block = block.replace('call spawn_wait', 'call mac_cross_link_wait', 1)
        text = text[:begin] + block + text[end:]
        text += (ROOT / 'cli/macos/x86_64/cross_build.s').read_text()
    text = text.replace('/usr/bin/sha256sum', '/usr/bin/shasum')
    text = text.replace('.section .text', '.text').replace('.section .rodata', '.data').replace('.section .data', '.data')
    text = re.sub(r'^\.section \.note.GNU-stack.*$', '', text, flags=re.M)
    text = text.replace('.section .bss', '.data')
    text = re.sub(r'^(\w+): \.skip (.+)$', r'.zerofill __DATA,__bss,\1,\2,3', text, flags=re.M)
    text = re.sub(r'^(\w+):\n(?=[ \t]*\.quad)', r'.p2align 3\n\1:\n', text, flags=re.M)
    text = re.sub(r'^(\w+:)?([ \t]*)\.quad', r'.p2align 3\n\1\2.quad', text, flags=re.M)
    text = re.sub(r'^([ \t]*)syscall\b', r'\1call mac_syscall', text, flags=re.M)
    text = re.sub(r'^\.include "([^"]+)"', lambda m: prepare(ROOT / m[1]), text, flags=re.M)
    return text


def complete() -> str:
    return prepare(ROOT / 'cli/asm.s') + '\n' + (ROOT / 'cli/macos/x86_64/platform.s').read_text()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(complete())
