#!/usr/bin/env python3
"""Prepare native x64 assembly for COFF. No CLI runtime logic.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import argparse
import importlib.util
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / 'cli/windows/x86_64'
_layout_spec = importlib.util.spec_from_file_location('asm_windows_layout', ROOT / 'tools/windows_layout.py')
_layout = importlib.util.module_from_spec(_layout_spec)
sys.path.insert(0, str(ROOT / 'tools'))
_layout_spec.loader.exec_module(_layout)
sys.path.pop(0)


def replace_routine(text, name, following, replacement):
    assert text.count('\n' + name + ':\n') == 1, name
    assert text.count('\n' + following + ':\n') == 1, following
    start = text.index(name + ':\n')
    end = text.index(following + ':\n', start)
    return text[:start] + replacement + '\n' + text[end:]


def prepare(source, toolchain_bin='C:/Program Files/LLVM/bin'):
    text = source.read_text()
    if source.name == 'templates.s':
        return (LOCAL / 'templates.s').read_text()
    if source.name == 'elf.s':
        return (LOCAL / 'pe.s').read_text()
    if source.name == 'asm.s':
        anchor = '.intel_syntax noprefix\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '.equ WIN_OPEN_SET_DACL, 0x04000000\n', 1)
        text = replace_routine(text, '_start', '.Lglobals', '''_start:
    cld
    call win_initialize
    test eax, eax
    jnz win_initialization_error
    call win_managed_startup
    mov qword ptr [rip + argi], 1
''')
        text = replace_routine(text, 'spawn_wait', 'cmd_clean', '''spawn_wait:
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    jmp win_process
''')
        begin = text.index('    lea rax, [rip + as_path]\n', text.index('build_project:\n'))
        end = text.index('.Lbuild_link_result:\n', begin)
        text = text[:begin] + '''    call win_compile_project
    test eax, eax
    jnz build_child_error
    cmp byte ptr [rip + package_link], 0
    je .Lbuild_standalone_link
    call native_link_build
    jmp .Lbuild_link_result
.Lbuild_standalone_link:
    call win_link_standalone
''' + text[end:]
        # clang performs assembly and linking. Explicit COFF target and entry
        # replace Linux assembler/linker switches in the fixed argv.
        text = text.replace('as_64: .asciz "--64"', 'as_64: .asciz "-c"')
        text = text.replace('arg_z: .asciz "-z"', 'arg_z: .asciz "-nostdlib"')
        text = text.replace('noexecstack: .asciz "noexecstack"',
                            'noexecstack: .asciz "-Wl,/entry:_start,/subsystem:console,/nxcompat,/dynamicbase,/Brepro"')
        text = text.replace('mov qword ptr [rip + child_argv + 48], 0\n    lea rdi, [rip + ld_path]',
                            'lea rax, [rip + win_kernel32_lib]\n    mov [rip + child_argv + 48], rax\n    mov qword ptr [rip + child_argv + 56], 0\n    lea rdi, [rip + ld_path]')
        text = text.replace('valid_source:\n', 'valid_source:\n    jmp win_valid_source\nwin_shared_valid_source:\n', 1)
        text += '\n' + (LOCAL / 'platform.s').read_text()
        for module in ('managed.s', 'launcher.s', 'versioned_update.s'):
            text += '\n' + (LOCAL / module).read_text()
        version = re.search(r'version_text: \.asciz "asm ([0-9]+\.[0-9]+\.[0-9]+) ', text).group(1)
        text += '\n' + _layout.metadata_assembly(version, syntax='x86_64')
    if source.name == 'cross_build.s':
        text = replace_routine(text, 'cross_tools', 'cross_build_project', '''cross_tools:
    lea rdi, [rip + cross_unsupported_error]
    mov esi, 2
    jmp die
''')
    if source.name == 'registry.s':
        text = text.replace('registry_workspace:\n', '''registry_workspace:
    cmp byte ptr [rip + self_active], 0
    jne .Lwin_managed_workspace_allowed
    call win_managed_check_workspace
.Lwin_managed_workspace_allowed:
''', 1)
        text = text.replace('.Lprogram_fetch_finalization:\n', '''.Lprogram_fetch_finalization:
    mov rsi, [rip + registry_output]
    call win_program_absolute_path
    lea rdi, [rip + program_path]
    call win_managed_reserved_path
    test eax, eax
    jnz program_reserved_error
''', 1)
        for output in ['registry_json_string', 'out']:
            anchor = '    mov rdi, [rip + registry_output]\n    call ' + output + '\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor.replace('call ' + output, 'call win_json_path' if output == 'registry_json_string' else 'call win_out_path'))
        text = replace_routine(text, 'registry_download', 'registry_read_index', '''registry_download:
    jmp win_download
''')
        text = replace_routine(text, 'registry_verify_payload', 'registry_copy_local', '''registry_verify_payload:
    push rbx
    lea rdi, [rip + registry_temp_payload]
    mov rsi, [rip + registry_expected_size]
    lea rdx, [rip + win_hash_hex]
    call win_hash_file
    test eax, eax
    jnz registry_integrity_error
    mov rbx, [rip + registry_selected]
    lea rdi, [rip + win_hash_hex]
    mov rsi, [rbx + 32]
    call streq
    test eax, eax
    jz registry_integrity_error
    pop rbx
    ret
''')
        text = text.replace('https://asm.build/registry/v1/index.tsv',
                            'https://asm.build/registry/v1/index-all.tsv')
        text = text.replace('registry_bin_suffix: .asciz ".bin"', 'registry_bin_suffix: .asciz ".exe"')
        anchor = '''.Linstall_name_start:
    inc rsi
    call copy_string
'''
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '''    mov rdi, rax
    lea rsi, [rip + registry_bin_suffix]
    call copy_string
''')
        text = replace_routine(text, 'registry_valid_target', 'registry_valid_kind', '''registry_valid_target:
    /* Reuse the canonical seven-target table; registry rows forbid aliases.
     * rm_named_target returns a pointer, while this interface requires 1/0. */
    sub rsp, 8
    call rm_named_target
    add rsp, 8
    test rax, rax
    setnz al
    movzx eax, al
    ret
''')
        text += '\n.section .rodata\nwin_registry_linux: .asciz "x86_64-linux"\n'
    if source.name == 'programs.s':
        anchor = '    lea rdi, [rip + program_state_path]\n    mov rsi, rbp\n    call program_walk_parent\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '''    lea rdi, [rip + program_state_path]
    call win_managed_reserved_path
    test eax, eax
    jnz program_reserved_error
''' + anchor)
        for output in ['registry_json_string', 'out']:
            anchor = '    mov rdi, qword ptr [rbx + 40]\n    call ' + output + '\n'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor.replace('call ' + output, 'call win_json_path' if output == 'registry_json_string' else 'call win_out_path'))
        text = replace_routine(text, 'program_absolute_path', 'program_open_state', '''program_absolute_path:
    jmp win_program_absolute_path
''')
        text = text.replace('program_open_destination:\n    push rbx\n', '''program_open_destination:
    lea rdi, [rip + program_path]
    call win_normalize_path
    test rax, rax
    js program_path_error
    lea rdi, [rip + program_path]
    call win_managed_reserved_path
    test eax, eax
    jnz program_reserved_error
    push rbx
''')
        text = text.replace('program_reserved_suffix: .asciz "/.local/bin/asm"',
                            'program_reserved_suffix: .asciz "/.local/bin/asm.exe"')
        anchor = '''    movzx r8d, byte ptr [rdi + 3]
    test r8d, r8d
    jnz .Lp_cli_destination_safe
'''
        assert text.count(anchor) == 1
        text = text.replace(anchor, '''    cmp byte ptr [rdi + 3], '.'
    jne .Lp_cli_destination_safe
    movzx r8d, byte ptr [rdi + 4]
    or r8d, 32
    cmp r8d, 'e'
    jne .Lp_cli_destination_safe
    movzx r8d, byte ptr [rdi + 5]
    or r8d, 32
    cmp r8d, 'x'
    jne .Lp_cli_destination_safe
    movzx r8d, byte ptr [rdi + 6]
    or r8d, 32
    cmp r8d, 'e'
    jne .Lp_cli_destination_safe
    cmp byte ptr [rdi + 7], 0
    jne .Lp_cli_destination_safe
''')
        anchor = '    call program_valid_absolute_path\n    test eax, eax\n    jz program_state_error\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '    mov rdi, qword ptr [rbx + 40]\n    call win_managed_reserved_path\n    test eax, eax\n    jnz program_state_error\n')
    if source.name == 'self_update_metadata.s':
        anchor = 'smp_host_suffix: .asciz "-x86_64-linux"'
        assert text.count(anchor) == 1
        text = text.replace(anchor, 'smp_host_suffix: .asciz "-x86_64-windows.exe"')
    if source.name == 'dependencies.s':
        text = text.replace('dependency_acquire:\n', 'dependency_acquire:\n    call win_managed_check_workspace\n', 1)
    if source.name == 'self_update.s':
        anchor = '    mov eax, 2\n    lea rdi, [rip + self_proc_exe]\n    mov esi, O_CLOEXEC + O_NONBLOCK\n    xor edx, edx\n    syscall\n    test rax, rax\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '    cmp rax, -116\n    je win_self_image_changed\n    cmp rax, -95\n    je win_self_identity_unsupported\n    test rax, rax\n')
        text = text.replace('self_install_suffix: .asciz "/.local/bin/asm"',
                            'self_install_suffix: .asciz "/.local/bin/asm.exe"')
        text = text.replace('self_binary_name: .asciz "asm"', 'self_binary_name: .asciz "asm.exe"')
        text = text.replace('self_asset_suffix: .asciz "-x86_64-linux"',
                            'self_asset_suffix: .asciz "-x86_64-windows.exe"')
        text = text.replace('    sub rcx, 4\n    rep movsb', '    sub rcx, 8\n    rep movsb')
        text = text.replace('    lea rsi, [rip + self_install_path]\n    call streq',
                            '    call win_normalize_path\n    test rax, rax\n    js self_installation_error\n    lea rsi, [rip + self_install_path]\n    call streq')
        begin = text.index('    mov eax, [rip + self_filesystem_stat]\n')
        end = text.index('.Lself_local_filesystem:', begin)
        text = text[:begin] + '''    cmp dword ptr [rip + self_filesystem_stat], 0x5346544e
    jne self_filesystem_error
''' + text[end:]
        begin = text.index('self_commit_update:\n')
        text = text[:begin] + text[begin:].replace('mov edx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK',
                                                  'mov edx, O_NOFOLLOW + O_CLOEXEC + O_NONBLOCK + 0x20000002', 1)
        for name, following in (
                ('self_open_installation', 'self_open_parent'),
                ('self_check_absolute_installation', 'self_check_file_stat'),
                ('self_check_destination', 'self_release_paths'),
                ('self_commit_update', 'self_update_cleanup')):
            text = replace_routine(text, name, following, name + ':\n    jmp win_managed_' + name[5:] + '\n')
        text = text.replace('self_update_cleanup:\n', 'self_update_cleanup:\n    call win_managed_update_cleanup\n', 1)
        text = text.replace('.Lself_cleanup_done:\n    ret', '.Lself_cleanup_done:\n    call win_managed_cleanup\n    ret', 1)
        text = text.replace('self update requires the direct HOME/.local/bin/asm installation; use the bootstrap installer or your package manager', 'self update requires the active managed Windows payload; start the installed command or use the Windows installer')
        text = text.replace('Manually update the direct HOME/.local/bin/asm installation.', 'Manually update the active managed Windows CLI payload.')
    if source.name == 'self_update_verify.s':
        anchor = '    mov rsi, r12\n    call copy_string\n.ifdef ASM_TRUSTED_DISTRIBUTION\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '''    mov rsi, r12
    call copy_string
    call win_prepare_verifier_environment
    test rax, rax
    js self_io_error
.ifdef ASM_TRUSTED_DISTRIBUTION
''')
        anchor = '    lea rax, [rip + self_gh_environment + 10*8]\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '    lea rax, [rip + self_gh_environment + 12*8]\n')
        anchor = '    .quad self_locale_environment, self_lang_environment\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '    .quad win_profile_environment, win_localappdata_environment\n')
        text = replace_routine(text, 'self_capture', 'self_verifier_missing', '''self_capture:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call self_check_absolute_installation
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    lea r10, [rip + self_capture_buffer]
    mov r8d, 4097
    mov r9, -1
    call win_process
    mov rdx, [rip + win_capture_length]
    cmp rdx, 4096
    ja .Lwin_self_capture_overflow
    mov [rip + self_capture_length], rdx
    lea rcx, [rip + self_capture_buffer]
    mov byte ptr [rcx + rdx], 0
    jmp .Lwin_self_capture_return
.Lwin_self_capture_overflow:
    mov eax, 127
.Lwin_self_capture_return:
    pop r14
    pop r13
    pop r12
    ret
''')
    if source.name == 'native_link.s':
        text = text.replace('this path needs at most 24.', 'this path needs at most 26.')
        anchor = '    lea rax, [rip + native_cc_path]\n    call native_argv_add\n'
        assert text.count(anchor) == 2
        text = text.replace(anchor, anchor + '    lea rax, [rip + win_clang_no_config]\n    call native_argv_add\n')
        text = text.replace('native_fpie: .asciz "-fPIE"', 'native_fpie: .asciz "-fuse-ld=lld"')
        text = text.replace('native_pie: .asciz "-pie"',
                            'native_pie: .asciz "--target=x86_64-pc-windows-msvc"')
        text = text.replace('native_hardening: .asciz "-Wl,-z,relro,-z,now,-z,noexecstack"',
                            'native_hardening: .asciz "-Wl,/nxcompat,/dynamicbase,/Brepro"')
        begin = text.index('    imul rax, r13, 272\n')
        end = text.index('    inc r13\n', begin)
        text = text[:begin] + text[end:]
        text = text.replace("    cmp al, ':'\n    je bad_args\n", '')
        anchor = '    lea rax, [rip + native_syntax_only]\n'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '''    lea rax, [rip + native_pie]
    call native_argv_add
''' + anchor)
        text = text.replace("    cmp byte ptr [rbx], '/'\n    jne bad_args", '''    cmp byte ptr [rbx], '/'
    je .Lwin_native_directory_absolute
    cmp byte ptr [rbx + 1], ':'
    jne bad_args
    cmp byte ptr [rbx + 2], '/'
    je .Lwin_native_directory_absolute
    cmp byte ptr [rbx + 2], '\\\\'
    jne bad_args
.Lwin_native_directory_absolute:''')
    if source.name == 'archive.s':
        begin, end = text.index('arc_create_stage:\n'), text.index('arc_member_parent:\n')
        stage = text[begin:end]
        anchor = '    mov edx, ARC_DIRECTORY\n'
        assert stage.count(anchor) == 1
        stage = stage.replace(anchor, '    mov edx, ARC_DIRECTORY + WIN_OPEN_SET_DACL\n')
        text = text[:begin] + stage + text[end:]
        text = replace_routine(text, 'arc_decompress', 'arc_is_zero', '''arc_decompress:
    jmp win_decompress
''')
    if source.name == 'publish.s':
        begin = text.index('pub_validate_elf:\n')
        end = text.index('pub_hash_payload:\n', begin)
        linux_validator = text[begin:end].replace('pub_validate_elf:\n', 'win_pub_validate_linux_elf:\n', 1)
        # Only the three established Linux ELF containers use this validator.
        # A declared foreign PE/Mach-O target does not become ELF-compatible.
        linux_validator = linux_validator.replace('win_pub_validate_linux_elf:\n', '''win_pub_validate_linux_elf:
    push rdi
    push rsi
    lea rsi, [rip + win_registry_linux]
    call streq
    test eax, eax
    jnz .Lwin_pub_linux_known
    mov rdi, [rsp + 8]
    lea rsi, [rip + registry_aarch64]
    call streq
    test eax, eax
    jnz .Lwin_pub_linux_known
    mov rdi, [rsp + 8]
    lea rsi, [rip + registry_riscv64]
    call streq
.Lwin_pub_linux_known:
    pop rsi
    pop rdi
    test eax, eax
    jnz .Lwin_pub_linux_container
    mov eax, 1
    ret
.Lwin_pub_linux_container:
''', 1)
        # Publication now delegates recipe/target validation to the shared
        # manifest parser. Its canonical target table needs no host rewrite.
        # Fail if that delegation changes instead of restoring a private table.
        anchor = '    mov rdx, [rip + pub_project_target]\n    call rm_parse_manifest\n'
        assert text.count(anchor) == 1, 'shared publication manifest parser'
        text = replace_routine(text, 'pub_validate_elf', 'pub_hash_payload', '''pub_validate_elf:
    push rdi
    push rsi
    lea rsi, [rip + registry_host]
    call streq
    pop rsi
    pop rdi
    test eax, eax
    jz win_pub_validate_linux_elf
    lea rdi, [rip + registry_temp_payload]
    mov rsi, [rip + registry_expected_size]
    call validate_host_elf
    xor eax, 1
    ret
''' + linux_validator)
        text = replace_routine(text, 'pub_hash_payload', 'pub_append', '''pub_hash_payload:
    lea rdi, [rip + registry_temp_payload]
    mov rsi, -1
    lea rdx, [rip + pub_hash_buffer]
    jmp win_hash_file
''')
    text = text.replace('x86_64-unknown-linux-gnu', 'x86_64-pc-windows-msvc')
    text = text.replace('x86_64-linux', 'x86_64-windows')
    # Canonical foreign target rows are data, not host aliases. Keep the seven
    # target table and v2-lock identities distinct after host substitutions.
    if source.name == 'asm.s':
        text = text.replace('target_x86: .asciz "x86_64-windows"',
                            'target_x86: .asciz "x86_64-linux"')
        text = text.replace('section_target_x86: .asciz "target.x86_64-windows"',
                            'section_target_x86: .asciz "target.x86_64-linux"')
        text = re.sub(r'^targets_text:.*$', lambda m: 'targets_text: .asciz "x86_64-windows (host; LLVM clang + Windows SDK)\\n"', text, flags=re.M)
        text = re.sub(r'^targets_json:.*$', lambda m: 'targets_json: .asciz "{\\"host\\":\\"x86_64-windows\\",\\"targets\\":[\\"x86_64-windows\\"]}\\n"', text, flags=re.M)
    if source.name == 'cross_build.s':
        text = text.replace('/usr/bin/x86_64-windows-gnu-', '/usr/bin/x86_64-linux-gnu-')

    # Existing known-target rows remain valid data. The host literal alone
    # selects Windows installation. Each host uses its own native index.
    text = text.replace('win_registry_linux: .asciz "x86_64-windows"',
                        'win_registry_linux: .asciz "x86_64-linux"')
    text = text.replace(r'\"targets\":[\"x86_64-windows\",\"aarch64-linux\",\"riscv64-linux\"]', r'\"targets\":[\"x86_64-windows\"]')
    text = text.replace('x86-64 ELF', 'x86-64 PE')
    text = text.replace('host ELF', 'host PE')
    text = re.sub(r'build/app(?!\.exe)', 'build/app.exe', text)
    text = text.replace('/usr/bin/as', toolchain_bin + '/clang.exe')
    text = text.replace('/usr/bin/ld', toolchain_bin + '/clang.exe')
    text = text.replace('/usr/bin/cc', toolchain_bin + '/clang.exe')
    text = text.replace('/usr/bin/curl', 'C:/Windows/System32/curl.exe')
    text = text.replace('/usr/bin/gzip', 'C:/Program Files/Git/usr/bin/gzip.exe')
    text = text.replace('/usr/bin/sha256sum', 'C:/Windows/System32/bcrypt.dll')
    text = text.replace('/usr/bin/gh', 'C:/Program Files/GitHub CLI/gh.exe')
    text = text.replace('GNU as + ld', 'LLVM clang + Windows SDK').replace('GNU as and ld', 'LLVM clang and the Windows SDK')
    text = text.replace('app_output: .asciz "build/app"', 'app_output: .asciz "build/app.exe"')
    text = text.replace('test_output: .asciz "build/test"', 'test_output: .asciz "build/test.exe"')
    text = text.replace('binary_suffix: .asciz "/app"', 'binary_suffix: .asciz "/app.exe"')
    text = re.sub(r'^([ \t]*)syscall\s*$', r'\1call win_syscall', text, flags=re.M)
    text = text.replace('.section .rodata', '.section .rdata,"dr"')
    text = re.sub(r'^\.section \.note\.GNU-stack.*$', '', text, flags=re.M)
    # Apply platform substitutions to each source exactly once. Flatten only
    # afterward: a fixed Git path contains /usr/bin/gzip as a substring.
    text = re.sub(r'^\.include "([^"]+)"',
                  lambda m: prepare(ROOT / m[1], toolchain_bin), text, flags=re.M)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--toolchain-bin', default='C:/Program Files/LLVM/bin')
    parser.add_argument('--curl-path', default='C:/Windows/System32/curl.exe',
                        help='fixed build-time transport path; qualification fixtures only')
    parser.add_argument('--gh-path', default='C:/Program Files/GitHub CLI/gh.exe',
                        help='fixed build-time verifier path; qualification fixtures only')
    args = parser.parse_args()
    for value in (args.toolchain_bin, args.curl_path, args.gh_path):
        if any(c in value for c in '\n\r"\\'):
            parser.error('fixed tool paths must use forward slashes without quotes or controls')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    text = prepare(ROOT / 'cli/asm.s', args.toolchain_bin)
    text = text.replace('C:/Windows/System32/curl.exe', args.curl_path)
    text = text.replace('C:/Program Files/GitHub CLI/gh.exe', args.gh_path)
    args.output.write_text(text)


if __name__ == '__main__':
    main()
