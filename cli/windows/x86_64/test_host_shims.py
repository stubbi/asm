#!/usr/bin/env python3
"""Exercise actual Windows assembly control flow with deterministic host shims.

These checks do not qualify Windows API behavior. Native Windows tests remain
required. The shims execute x86-64 assembly on macOS/Rosetta or Linux x86-64.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import importlib.util
import platform
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
LOCAL = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('windows_x64', ROOT / 'tools/windows_x64.py')
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


def block(text, first, following):
    return text[text.index(first + ':\n'):text.index(following + ':\n', text.index(first + ':\n'))]


def fixture_pe(sections=((1, 0x1000, 512, 512), (1, 0x2000, 512, 1024)), *, image_size=0x3000, entry=0x1000):
    size = max(1536, *(raw + count for virtual, rva, count, raw in sections))
    data = bytearray(size)
    struct.pack_into('<H', data, 0, 0x5a4d)
    struct.pack_into('<I', data, 60, 64)
    nt = 64
    struct.pack_into('<IHH', data, nt, 0x4550, 0x8664, len(sections))
    struct.pack_into('<HH', data, nt + 20, 240, 2)
    struct.pack_into('<H', data, nt + 24, 0x20b)
    struct.pack_into('<I', data, nt + 40, entry)
    struct.pack_into('<II', data, nt + 56, 4096, 512)
    struct.pack_into('<II', data, nt + 80, image_size, 512)
    struct.pack_into('<HH', data, nt + 92, 3, 0x100)
    struct.pack_into('<I', data, nt + 132, 16)
    for i, section in enumerate(sections):
        struct.pack_into('<IIII', data, nt + 264 + i * 40 + 8, *section)
        struct.pack_into('<I', data, nt + 264 + i * 40 + 36, 0x60000020 if i == 0 else 0x40000040)
    return data


class GeneratorIntegration(unittest.TestCase):
    def test_generator_prepares_the_current_canonical_cli(self):
        with tempfile.TemporaryDirectory(prefix='asm-windows-x64-generator-') as temporary:
            destination = Path(temporary) / 'current.s'
            result = subprocess.run([sys.executable, str(ROOT / 'tools/windows_x64.py'),
                                     '--output', str(destination)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreater(destination.stat().st_size, 0)


class HostShims(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.clang = shutil.which('clang')
        if not cls.clang or platform.system() not in {'Darwin', 'Linux'}:
            raise unittest.SkipTest('host clang and macOS/Linux are required')
        if platform.system() == 'Linux' and platform.machine() not in {'x86_64', 'AMD64'}:
            raise unittest.SkipTest('Linux host shims require native x86-64')
        cls.temp = tempfile.TemporaryDirectory(prefix='asm-windows-x64-shims-')
        cls.directory = Path(cls.temp.name)
        cls.platform_source = (LOCAL / 'platform.s').read_text()
        cls.prepared = prep.prepare(ROOT / 'cli/asm.s')
        start = cls.platform_source.index('.macro WFRAME\n')
        end = cls.platform_source.index('.text\n', start)
        constants = '\n'.join(re.findall(r'^\.equ WIN_.*$',cls.prepared,re.M)) + '\n'
        cls.macros = '.intel_syntax noprefix\n' + constants + cls.platform_source[start:end] + '\n.text\n'
        cls.prefix = '_' if platform.system() == 'Darwin' else ''
        cls.build_pe()
        cls.build_path()
        cls.build_capture()
        cls.build_delete()
        cls.build_extended_cwd()
        cls.build_verifier_environment()
        cls.build_security()
        cls.build_process()
        cls.build_manifest_paths()
        cls.build_targets()
        cls.build_clang_arguments()
        cls.build_image_identity()
        cls.build_release_metadata()
        cls.build_display_path()
        cls.build_arc_stage_protection()
        cls.build_device_names()
        cls.build_diagnostic_last_error()
        cls.build_rename_constructor()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def build(cls, name, assembly, driver, exported):
        for symbol in exported:
            assembly = assembly.replace('.global ' + symbol + '\n', '.global ' + cls.prefix + symbol + '\n')
            assembly = assembly.replace('\n' + symbol + ':\n', '\n' + cls.prefix + symbol + ':\n')
        if cls.prefix:
            assembly = assembly.replace('.section .text', '.text').replace('.section .bss', '.data').replace('.section .rodata', '.data').replace('.section .data', '.data')
            assembly = assembly.replace('.section .rdata,"dr"', '.data')
        else:
            assembly += '\n.section .note.GNU-stack,"",@progbits\n'
        source = cls.directory / (name + '.s')
        source.write_text(assembly)
        csource = cls.directory / (name + '.c')
        csource.write_text(driver)
        command = [cls.clang, '--no-default-config', '-arch', 'x86_64'] if cls.prefix else [cls.clang, '--no-default-config', '-m64']
        result = subprocess.run(command + [str(source), str(csource), '-o', str(cls.directory / name)],
                       capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr)


    @classmethod
    def run_fixture(cls, name, *arguments):
        return subprocess.run([str(cls.directory / name), *arguments],
                              capture_output=True, text=True, timeout=10)

    @classmethod
    def build_pe(cls):
        assembly = cls.macros + (LOCAL / 'pe.s').read_text()
        assembly += f'''
.text
.global check_pe
check_pe:
    jmp validate_host_elf
win_syscall:
    WFRAME
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rax
    call {cls.prefix}io
    WLEAVE
'''
        driver = r'''
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
extern int check_pe(const char*,uint64_t);
long io(long n,long a,long b,long c) {
    struct stat st; long result=-38;
    if(n==2) result=open((char*)a,O_RDONLY);
    else if(n==3) result=close(a);
    else if(n==0) result=read(a,(void*)b,c);
    else if(n==8) result=lseek(a,b,c);
    else if(n==5) { result=fstat(a,&st); if(!result) {
        memset((void*)b,0,144); *(uint32_t*)(b+24)=0100000;
        *(uint64_t*)(b+48)=st.st_size;
    }}
    return result;
}
int main(int argc,char**argv) {
    struct stat st; if(argc!=2 || stat(argv[1],&st)) return 2;
    printf("%d\n",check_pe(argv[1],st.st_size)); return 0;
}
'''
        cls.build('pe', assembly, driver, ['check_pe'])

    @classmethod
    def build_path(cls):
        absolute = block(cls.prepared, 'program_absolute_path', 'program_open_state')
        # The platform-specific routine is included once the root cause fix
        # replaces the POSIX-only absolute-path builder.
        if 'win_program_absolute_path:\n' in cls.platform_source:
            absolute += block(cls.platform_source, 'win_program_absolute_path', 'win_compile_project')
        normalization = block(cls.platform_source, 'win_normalize_path', 'win_compile_project')
        if 'win_program_absolute_path:\n' in normalization:
            normalization = normalization[:normalization.index('win_program_absolute_path:\n')]
        assembly = cls.macros + absolute + normalization
        assembly += block(cls.prepared, 'strlen', 'write_cstr')
        assembly += f'''
.global make_path
make_path:
    mov rsi, rdi
    call program_absolute_path
    lea rdi, [rip + program_path]
    call win_normalize_path
    test rax, rax
    js program_path_error
    lea rax, [rip + program_path]
    ret
program_path_error:
    mov edi, 2
    and rsp, -16
    call {cls.prefix}exit
win_syscall:
    WFRAME
    lea rsi, [rip + test_cwd]
    call copy_string
    mov eax, 11
    WLEAVE
.data
test_cwd: .asciz "C:/project"
program_cwd: .space 4096
program_path: .space 4096
'''
        driver = '#include <stdio.h>\nextern const char* make_path(const char*);\nint main(int n,char**a){if(n!=2)return 3;puts(make_path(a[1]));}\n'
        cls.build('path', assembly, driver, ['make_path'])

    @classmethod
    def build_capture(cls):
        loop = cls.platform_source[cls.platform_source.index('.Lwp_poll:\n'):cls.platform_source.index('.Lwp_complete:\n')]
        assembly = cls.macros + '''
.global run_capture
run_capture:
    WFRAME
    call GetTickCount64
    mov r12, rax
    lea r14, [rip + test_capture_buffer]
    mov r15d, 64
    jmp .Lwp_poll
''' + loop + '''
.Lwp_complete:
    xor eax, eax
    WLEAVE
.Lwp_terminate:
    call TerminateProcess
    call WaitForSingleObject
    mov eax, 127
    WLEAVE
GetTickCount64:
    mov rax, [rip + test_clocks]
    inc qword ptr [rip + test_clocks]
    cmp eax, 2
    jb 1f
    cmp eax, 2
    je 2f
    mov eax, 120000
    ret
1:  xor eax, eax
    ret
2:  mov eax, 119999
    ret
PeekNamedPipe:
    mov rax, [rsp + 40]
    mov dword ptr [rax], 1
    mov eax, 1
    ret
ReadFile:
    inc qword ptr [rip + test_reads]
    mov byte ptr [rdx], 'x'
    mov dword ptr [r9], 1
    mov eax, 1
    ret
GetLastError:
    mov eax, 109
    ret
WaitForSingleObject:
    mov eax, 258
    ret
TerminateProcess:
    inc qword ptr [rip + test_kills]
    mov eax, 1
    ret
.global capture_reads
capture_reads:
    mov rax, [rip + test_reads]
    ret
.global capture_clocks
capture_clocks:
    mov rax, [rip + test_clocks]
    ret
.global capture_kills
capture_kills:
    mov rax, [rip + test_kills]
    ret
.global captured_length
captured_length:
    mov rax, [rip + win_capture_length]
    ret
.global captured_byte
captured_byte:
    movzx eax, byte ptr [rip + test_capture_buffer]
    ret
.data
win_capture_length: .quad 0
win_pipe_read: .quad 7
win_process_handle: .quad 8
test_reads: .quad 0
test_clocks: .quad 0
test_kills: .quad 0
test_peeks: .quad 0
test_capture_buffer: .space 64
'''
        driver = '#include <stdio.h>\nextern int run_capture(void);\nextern long capture_reads(void),capture_clocks(void),capture_kills(void);\nint main(){int s=run_capture();printf("%d %ld %ld %ld\\n",s,capture_reads(),capture_clocks(),capture_kills());}\n'
        exports = ['run_capture','capture_reads','capture_clocks','capture_kills','captured_length','captured_byte']
        cls.build('capture', assembly, driver, exports)
        final_byte = assembly
        final_byte = final_byte.replace(block(final_byte, 'GetTickCount64', 'PeekNamedPipe'), '''GetTickCount64:
    inc qword ptr [rip + test_clocks]
    xor eax, eax
    ret
''')
        final_byte = final_byte.replace(block(final_byte, 'PeekNamedPipe', 'ReadFile'), '''PeekNamedPipe:
    cmp qword ptr [rip + test_reads], 0
    jne .Lhost_final_eof
    mov rax, [rsp + 40]
    mov ecx, 1
    cmp qword ptr [rip + test_peeks], 0
    jne .Lhost_final_available
    xor ecx, ecx
.Lhost_final_available:
    inc qword ptr [rip + test_peeks]
    mov [rax], ecx
    mov eax, 1
    ret
.Lhost_final_eof:
    xor eax, eax
    ret
''')
        final_byte = final_byte.replace(block(final_byte, 'WaitForSingleObject', 'TerminateProcess'), '''WaitForSingleObject:
    xor eax, eax
    ret
''')
        final_driver = '#include <stdio.h>\nextern int run_capture(void);\nextern long capture_reads(void),capture_kills(void),captured_length(void),captured_byte(void);\nint main(){int s=run_capture();printf("%d %ld %ld %ld %ld\\n",s,capture_reads(),capture_kills(),captured_length(),captured_byte());}\n'
        cls.build('capture-final-byte', final_byte, final_driver, exports)

    @classmethod
    def build_delete(cls):
        deletion = cls.platform_source[cls.platform_source.index('.Lws_rmdir:\n'):cls.platform_source.index('.Lws_chdir:\n')]
        assembly = cls.macros + '''
.global run_delete
run_delete:
    WFRAME
    mov [rip + test_attributes], esi
    test edi, edi
    jz .Lws_unlink
    cmp edi, 1
    je .Lws_rmdir
    mov edx, 1
    jmp .Lws_unlinkat
''' + deletion + '''
.Lws_return:
    WLEAVE
.Lws_invalid:
    mov rax, -22
    WLEAVE
.Lws_error:
    mov rax, -13
    WLEAVE
win_open:
    mov eax, 3
    ret
win_handle:
    mov eax, 7
    ret
GetFileInformationByHandleEx:
    mov eax, [rip + test_attributes]
    mov [r8], eax
    mov eax, 1
    ret
SetFileInformationByHandle:
    inc qword ptr [rip + test_deletions]
    mov eax, 1
    ret
win_error:
    mov rax, -13
    ret
win_syscall:
    inc qword ptr [rip + test_closes]
    xor eax, eax
    ret
.global deletion_count
deletion_count:
    mov rax, [rip + test_deletions]
    ret
.global close_count
close_count:
    mov rax, [rip + test_closes]
    ret
.data
test_attributes: .long 0
.p2align 3
test_deletions: .quad 0
test_closes: .quad 0
'''
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long run_delete(int,int),deletion_count(void),close_count(void);\nint main(int n,char**a){if(n!=3)return 2;long s=run_delete(atoi(a[1]),atoi(a[2]));printf("%ld %ld %ld\\n",s,deletion_count(),close_count());}\n'
        cls.build('delete', assembly, driver, ['run_delete','deletion_count','close_count'])

    @classmethod
    def build_extended_cwd(cls):
        assembly = cls.macros + block(cls.platform_source, 'win_wide', 'win_utf8')
        if 'win_drive_path:\n' in cls.platform_source:
            assembly += block(cls.platform_source, 'win_drive_path', 'win_open')
        assembly += block(cls.platform_source, 'win_open', 'win_syscall')
        component = cls.platform_source[cls.platform_source.index('win_component_safe:\n'):]
        if 'win_prepare_verifier_environment:\n' in component:
            component = component[:component.index('win_prepare_verifier_environment:\n')]
        assembly += component
        assembly += block(cls.prepared, 'streq', 'strlen')
        assembly += '''
.text
.global open_from_cwd
open_from_cwd:
    WFRAME
    mov [rip + test_extended], edi
    mov rdi, -100
    lea rsi, [rip + test_relative_file]
    xor edx, edx
    xor r10d, r10d
    call win_open
    WLEAVE
MultiByteToWideChar:
    mov r11, [rsp + 40]
    xor eax, eax
.Lhost_cwd_convert:
    movzx ecx, byte ptr [r8 + rax]
    mov [r11 + rax*2], cx
    inc eax
    test ecx, ecx
    jnz .Lhost_cwd_convert
    ret
GetCurrentDirectoryW:
    lea r11, [rip + test_current_directory]
    mov eax, [rip + test_extended]
    cmp eax, 2
    je .Lhost_cwd_unc
    cmp eax, 3
    je .Lhost_cwd_device
    test eax, eax
    jnz .Lhost_cwd_copy
    add r11, 8
    jmp .Lhost_cwd_copy
.Lhost_cwd_unc:
    lea r11, [rip + test_unc_directory]
    jmp .Lhost_cwd_copy
.Lhost_cwd_device:
    lea r11, [rip + test_device_directory]
.Lhost_cwd_copy:
    xor eax, eax
.Lhost_cwd_unit:
    mov cx, [r11 + rax*2]
    mov [rdx + rax*2], cx
    test cx, cx
    jz .Lhost_cwd_return
    inc eax
    jmp .Lhost_cwd_unit
.Lhost_cwd_return:
    ret
win_nt_open:
    cmp edx, 16
    jne .Lhost_cwd_existing
    cmp word ptr [rsi], 'a'
    jne .Lhost_cwd_existing
    mov rax, -2
    ret
.Lhost_cwd_existing:
    mov eax, 8
    ret
win_handle:
    mov eax, 7
    ret
win_descriptor:
    mov eax, 3
    ret
CloseHandle:
    mov eax, 1
    ret
DuplicateHandle:
    mov qword ptr [r9], 8
    mov eax, 1
    ret
GetModuleFileNameW:
GetWindowsDirectoryW:
    xor eax, eax
    ret
win_error:
    mov rax, -13
    ret
.data
self_proc_exe: .asciz "/proc/self/exe"
.text
win_image_matches:
    xor eax, eax
    ret
.data
test_relative_file: .asciz "asm.toml"
test_extended: .long 0
test_current_directory: .short 92,92,63,92,67,58,92,112,114,111,106,101,99,116,0
test_unc_directory: .short 92,92,63,92,85,78,67,92,115,101,114,118,101,114,92,115,104,97,114,101,0
test_device_directory: .short 92,68,101,118,105,99,101,92,72,97,114,100,100,105,115,107,86,111,108,117,109,101,49,0
win_nt_root: .short 92,63,63,92,67,58,92,0
win_path_wide: .space 8192
win_full_wide: .space 8192
'''
        driver = '#include <stdio.h>\nextern long open_from_cwd(int);\nint main(){printf("%ld %ld %ld %ld\\n",open_from_cwd(0),open_from_cwd(1),open_from_cwd(2),open_from_cwd(3));}\n'
        cls.build('extended-cwd', assembly, driver, ['open_from_cwd'])
        image = assembly.replace('test_relative_file: .asciz "asm.toml"',
                                 'test_relative_file: .asciz "/proc/self/exe"')
        start, end = image.index('win_nt_open:\n'), image.index('win_handle:\n')
        image = image[:start] + 'win_nt_open:\n    mov eax, 8\n    ret\n' + image[end:]
        anchor = 'GetModuleFileNameW:\nGetWindowsDirectoryW:\n'
        assert image.count(anchor) == 1
        image = image.replace(anchor, '''GetModuleFileNameW:
    lea r11, [rip + test_module_name]
    xor eax, eax
.Lhost_image_copy:
    mov cx, [r11 + rax*2]
    mov [rdx + rax*2], cx
    test cx, cx
    jz .Lhost_image_return
    inc eax
    jmp .Lhost_image_copy
.Lhost_image_return:
    ret
GetWindowsDirectoryW:
''')
        image = image.replace('win_descriptor:\n    mov eax, 3',
                              'win_descriptor:\n    inc dword ptr [rip + test_image_counts + 4]\n    mov eax, 3')
        image = image.replace('CloseHandle:\n    mov eax, 1',
                              'CloseHandle:\n    inc dword ptr [rip + test_image_counts + 8]\n    mov eax, 1')
        image = image.replace('win_image_matches:\n    xor eax, eax\n    ret', '''win_image_matches:
    inc dword ptr [rip + test_image_counts]
    cmp rdi, 8
    jne .Lhost_image_bad_handle
    cmp dword ptr [rip + test_extended], 0
    jne .Lhost_image_stale
    xor eax, eax
    ret
.Lhost_image_stale:
    mov rax, -116
    ret
.Lhost_image_bad_handle:
    mov rax, -13
    ret
''')
        image += '\n.text\n.global image_counts\nimage_counts:\n    lea rax, [rip + test_image_counts]\n    ret\n.data\n.p2align 2\ntest_image_counts: .long 0,0,0\n.p2align 1\ntest_module_name: .short ' + ','.join(str(ord(c)) for c in 'C:\\project\\asm.exe') + ',0\n'
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long open_from_cwd(int);\nextern const unsigned* image_counts(void);\nint main(int n,char**a){long r=open_from_cwd(atoi(a[1]));const unsigned*c=image_counts();printf("%ld %u %u %u\\n",r,c[0],c[1],c[2]);}\n'
        cls.build('image-open',image,driver,['open_from_cwd','image_counts'])


    @classmethod
    def build_verifier_environment(cls):
        assembly = cls.macros + block(cls.platform_source, 'win_prepare_verifier_environment', 'win_valid_source')
        assembly += '\n.text\n' + block(cls.prepared, 'copy_string', 'write_cstr')
        assembly += '''
.text
.global prepare_verifier_environment
prepare_verifier_environment:
    WFRAME
    test edi, edi
    jz .Lhost_environment_valid
    mov byte ptr [rip + self_home_environment + 5], 92
.Lhost_environment_valid:
    call win_prepare_verifier_environment
    WLEAVE
.global verifier_environment
verifier_environment:
    lea rax, [rip + test_environment]
    mov rax, [rax + rdi*8]
    ret
.data
self_home_environment: .asciz "HOME=/C:/Users/test user/private/verifier"
    .space 8192
self_config_environment: .asciz "GH_CONFIG_DIR=/C:/Users/test user/private/verifier"
    .space 8192
self_cache_environment: .asciz "XDG_CACHE_HOME=/C:/Users/test user/private/verifier"
    .space 8192
self_xdg_environment: .asciz "XDG_CONFIG_HOME=/C:/Users/test user/private/verifier"
    .space 8192
.p2align 3
test_environment: .quad self_home_environment,self_config_environment,self_cache_environment,self_xdg_environment,win_profile_environment,win_localappdata_environment
'''
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long prepare_verifier_environment(int);\nextern const char* verifier_environment(int);\nint main(int n,char**a){long s=prepare_verifier_environment(n>1?atoi(a[1]):0);printf("%ld\\n",s);if(s==0)for(int i=0;i<6;i++)puts(verifier_environment(i));}\n'
        cls.build('verifier-environment', assembly, driver, ['prepare_verifier_environment','verifier_environment'])

    @classmethod
    def build_manifest_paths(cls):
        assembly = cls.macros + block(cls.prepared,'win_shared_valid_source','cmd_build')
        assembly += '\n.text\n' + block(cls.platform_source,'win_component_safe','win_prepare_verifier_environment')
        assembly += '\n.text\n' + block(cls.platform_source,'win_valid_source','win_image_matches')
        assembly += r"""
.text
.global source_case
source_case:
    jmp win_valid_source
win_wide:
    xor eax, eax
1:  movzx ecx, byte ptr [rdi + rax]
    mov [rsi + rax*2], cx
    inc eax
    test ecx, ecx
    jnz 1b
    ret
.data
win_path_wide: .space 8192
"""
        driver = '#include <stdio.h>\nextern long source_case(const char*);\nint main(int n,char**a){printf("%ld\\n",source_case(a[1]));}\n'
        cls.build('source-path',assembly,driver,['source_case'])

    @classmethod
    def build_targets(cls):
        assembly = cls.macros + block(cls.prepared,'project_canonical_target','project_set_target')
        assembly += '\n' + block(cls.prepared,'streq','strlen')
        assembly += '\n.global canonical_target\ncanonical_target:\n    jmp project_canonical_target\n.data\n'
        for name in ['host_target','host_target_alias','target_x86','target_arm','target_riscv','target_macos','target_macos_x86','target_windows_x86','target_windows_arm']:
            rows = re.findall(r'^' + name + r': .+$',cls.prepared,re.M)
            assert len(rows) == 1, name
            assembly += rows[0] + '\n'
        driver = '#include <stdio.h>\nextern const char* canonical_target(const char*);\nint main(int n,char**a){const char*p=canonical_target(a[1]);puts(p?p:"invalid");}\n'
        cls.build('canonical-target',assembly,driver,['canonical_target'])
        assembly = cls.macros + block(cls.prepared,'registry_valid_target','registry_valid_kind')
        assembly += '\n' + block(cls.prepared,'rm_named_target','rm_horizontal')
        assembly += '\n' + block(cls.prepared,'streq','strlen')
        assembly += '''
.global registry_target_case
registry_target_case:
    jmp registry_valid_target
.global named_target_case
named_target_case:
    sub rsp,8
    call rm_named_target
    add rsp,8
    test rax,rax
    jz 1f
    mov eax,edx
1:  ret
.data
'''
        for name in ['target_x86','target_arm','target_riscv','target_macos','target_macos_x86','target_windows_x86','target_windows_arm']:
            assembly += re.findall(r'^' + name + r': .+$',cls.prepared,re.M)[0] + '\n'
        assembly += cls.prepared[cls.prepared.index('rm_target_names:\n'):cls.prepared.index('rm_empty:')]
        driver = '#include <stdio.h>\nextern long registry_target_case(const char*),named_target_case(const char*);\nint main(int n,char**a){printf("%ld %ld\\n",registry_target_case(a[1]),named_target_case(a[1]));}\n'
        cls.build('registry-target',assembly,driver,['registry_target_case','named_target_case'])

        # Exercise the real publication dispatch. PE/ELF readers are separate
        # fixtures; these bounded stubs expose which reader can receive input.
        start = cls.prepared.index('pub_validate_elf:\n')
        end = cls.prepared.index('.Lwin_pub_linux_container:\n',start)
        assembly = cls.macros + cls.prepared[start:end] + '''
.Lwin_pub_linux_container:
    inc dword ptr [rip + elf_calls]
    xor eax,eax
    ret
.global publication_target_case
publication_target_case:
    mov [rip + pe_valid],esi
    mov esi,4096
    jmp pub_validate_elf
validate_host_elf:
    inc dword ptr [rip + pe_calls]
    mov eax,[rip + pe_valid]
    ret
.global publication_counts
publication_counts:
    mov eax,[rip + pe_calls]
    imul eax,eax,10
    add eax,[rip + elf_calls]
    ret
'''
        assembly += block(cls.prepared,'cross_tools','cross_build_project')
        assembly += '''
.global foreign_build_case
foreign_build_case:
    jmp cross_tools
die:
    mov eax,esi
    ret
'''
        assembly += block(cls.prepared,'streq','strlen') + '\n.data\n'
        for name in ['registry_host','win_registry_linux','registry_aarch64','registry_riscv64','registry_macos','cross_unsupported_error']:
            assembly += re.findall(r'^' + name + r': .+$',cls.prepared,re.M)[0] + '\n'
        assembly += 'registry_temp_payload: .asciz "candidate.exe"\nregistry_expected_size: .quad 4096\npe_calls: .long 0\nelf_calls: .long 0\npe_valid: .long 0\n'
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern int publication_target_case(const char*,int),publication_counts(void),foreign_build_case(void);\nint main(int n,char**a){int r=publication_target_case(a[1],atoi(a[2]));printf("%d %d %d\\n",r,publication_counts(),foreign_build_case());}\n'
        cls.build('publication-target',assembly,driver,['publication_target_case','publication_counts','foreign_build_case'])


    def test_windows_manifest_source_rejects_streams_devices_and_aliases(self):
        for value in ['src/main.s:stream','src/CON.s','src/NUL','src/main.s.','src/main.s ','src\\main.s','@options','src/@options','src/../main.s']:
            with self.subTest(value=value):
                r = self.run_fixture('source-path',value)
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertEqual(r.stdout.strip(),'0')
        for value in ['src/main.s','custom/tests.s']:
            self.assertEqual(self.run_fixture('source-path',value).stdout.strip(),'1')

    def test_manifest_target_identities_remain_distinct(self):
        for target in ['x86_64-linux','aarch64-linux','riscv64-linux','aarch64-macos','x86_64-macos','x86_64-windows','aarch64-windows']:
            self.assertEqual(self.run_fixture('canonical-target',target).stdout.strip(),target)
        self.assertEqual(self.run_fixture('canonical-target','x86_64-pc-windows-msvc').stdout.strip(),'x86_64-windows')
        self.assertEqual(self.run_fixture('canonical-target','made-up').stdout.strip(),'invalid')
        for target, mask in [('x86_64-linux',4),('aarch64-linux',8),('riscv64-linux',16),('aarch64-macos',32),('x86_64-macos',64),('x86_64-windows',128),('aarch64-windows',256)]:
            result = self.run_fixture('registry-target',target)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.strip(),f'1 {mask}')
        for target in ['','made-up','x86_64-pc-windows-msvc','x86_64-windows-extra','X86_64-WINDOWS','target.x86_64-windows','riscv64-windows']:
            result = self.run_fixture('registry-target',target)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.strip(),'0 0')

    def test_publication_keeps_target_specific_readers_and_foreign_build_refusal(self):
        cases = [('x86_64-windows',1,'0 10 2'),('x86_64-windows',0,'1 10 2')]
        cases += [(target,1,'0 1 2') for target in ['x86_64-linux','aarch64-linux','riscv64-linux']]
        cases += [(target,1,'1 0 2') for target in ['aarch64-windows','aarch64-macos','x86_64-macos','made-up','x86_64-pc-windows-msvc']]
        for target, pe_valid, expected in cases:
            with self.subTest(target=target,pe_valid=pe_valid):
                result = self.run_fixture('publication-target',target,str(pe_valid))
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),expected)


    @classmethod
    def build_rename_constructor(cls):
        assembly = cls.macros + block(cls.platform_source,'win_rename','win_open_parent')
        assembly += '\n.text\n' + block(cls.platform_source,'win_component_safe','win_prepare_verifier_environment')
        assembly += r"""
.text
.global rename_request
rename_request:
    WFRAME
    mov [rip + test_rename_status], edi
    mov r8, rsi
    mov edi, 11
    lea rsi, [rip + test_source]
    mov edx, 9
    lea r10, [rip + test_destination]
    call win_rename
    WLEAVE
.global rename_observation
rename_observation:
    lea rax, [rip + test_observation]
    ret
win_open:
    mov [rip + test_observation], rdx
    mov eax, 3
    ret
win_handle:
    mov eax, 101
    cmp edi, 3
    je 1f
    mov eax, 202
1:  ret
win_open_parent:
    mov [rip + test_observation + 64], rdi
    mov eax, 4
    ret
win_wide:
    xor eax, eax
1:  movzx ecx, byte ptr [rdi + rax]
    mov [rsi + rax*2], cx
    inc eax
    test ecx, ecx
    jnz 1b
    ret
NtSetInformationFile:
    mov [rip + test_observation + 8], rcx
    mov rax, [r8 + 8]
    mov [rip + test_observation + 16], rax
    mov eax, [r8]
    mov [rip + test_observation + 24], rax
    mov eax, [r8 + 16]
    mov [rip + test_observation + 32], rax
    mov [rip + test_observation + 40], r9
    mov rax, [rsp + 40]
    mov [rip + test_observation + 48], rax
    mov eax, [rip + test_rename_status]
    ret
win_nt_error:
    mov rax, -13
    ret
win_syscall:
    inc qword ptr [rip + test_observation + 56]
    xor eax, eax
    ret
.data
.p2align 3
test_observation: .space 72
test_rename_status: .long 0
test_source: .asciz "payload"
test_destination: .asciz "asm.exe"
.p2align 3
win_parent_basename: .quad test_destination
win_rename_info: .space 8216
"""
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long rename_request(long,long);\nextern const unsigned long long* rename_observation(void);\nint main(int n,char**a){long r=rename_request(strtoul(a[1],0,0),atoi(a[2]));const unsigned long long*p=rename_observation();printf("%ld",r);for(int i=0;i<9;i++)printf(" %llu",p[i]);puts("");}\n'
        cls.build('rename-constructor',assembly,driver,['rename_request','rename_observation'])

    def test_actual_rename_constructor_uses_one_held_root_and_required_flags(self):
        for status,result in [(0,0),(0xc0000022,-13)]:
            for no_replace,flags in [(0,3),(1,2)]:
                with self.subTest(status=status,no_replace=no_replace):
                    r = self.run_fixture('rename-constructor',str(status),str(no_replace))
                    self.assertEqual(r.returncode,0,r.stderr)
                    self.assertEqual(r.stdout.strip(),f'{result} 268435456 101 202 {flags} 14 34 65 2 9')

    @classmethod
    def build_diagnostic_last_error(cls):
        assembly = cls.macros + (LOCAL / 'diagnostic.s').read_text()
        assembly += r"""
.text
.global diagnostic_call
diagnostic_call:
    WFRAME
    mov eax, 17
    call win_diag_process_log
    WLEAVE
.global diagnostic_error
diagnostic_error:
    mov eax, [rip + test_last_error]
    ret
GetLastError:
    mov eax, [rip + test_last_error]
    ret
SetLastError:
    mov [rip + test_last_error], ecx
    ret
write_all:
    mov dword ptr [rip + test_last_error], 999
    xor eax, eax
    ret
WideCharToMultiByte:
    xor eax, eax
    ret
.data
test_last_error: .long 42
"""
        driver = '#include <stdio.h>\nextern long diagnostic_call(void),diagnostic_error(void);\nint main(){long v=diagnostic_call();long e=diagnostic_error();printf("%ld %ld\\n",v,e);}\n'
        cls.build('diagnostic-last-error',assembly,driver,['diagnostic_call','diagnostic_error'])

    def test_diagnostic_logging_preserves_api_result_and_last_error(self):
        self.assertEqual(self.run_fixture('diagnostic-last-error').stdout.strip(),'17 42')

    @classmethod
    def build_device_names(cls):
        assembly = cls.macros + block(cls.platform_source,'win_component_safe','win_prepare_verifier_environment')
        assembly += '\n.text\n.global device_component\ndevice_component:\n    lea rdx, [rsi*2]\n    jmp win_component_safe\n'
        driver = r"""
#include <stdio.h>
#include <stdlib.h>
extern long device_component(const unsigned short*,unsigned long);
int main(int n,char**a){unsigned short name[32];unsigned long z=0;for(const char*p=a[1];*p;p++)name[z++]=(unsigned char)*p;name[z++]=strtoul(a[2],0,0);if(atoi(a[3])){name[z++]='.';name[z++]='s';}printf("%ld\n",device_component(name,z));}
"""
        cls.build('device-names',assembly,driver,['device_component'])

    def test_superscript_reserved_devices_are_rejected_without_broad_unicode_rejection(self):
        for prefix in ['COM','LPT']:
            for digit in [0xb9,0xb2,0xb3]:
                for extension in [0,1]:
                    with self.subTest(prefix=prefix,digit=digit,extension=extension):
                        r = self.run_fixture('device-names',prefix,str(digit),str(extension))
                        self.assertEqual(r.returncode,0,r.stderr)
                        self.assertEqual(r.stdout.strip(),'0')
        for prefix,digit in [('data',0xb9),('data',0xb2),('data',0xb3),('COM',0x2074),('LPT',0x2074)]:
            for extension in [0,1]:
                self.assertEqual(self.run_fixture('device-names',prefix,str(digit),str(extension)).stdout.strip(),'1')

    @classmethod
    def build_arc_stage_protection(cls):
        assembly = cls.macros + '\n.equ ARC_DIRECTORY,722944\n' + block(cls.prepared,'arc_create_stage','arc_member_parent')
        assembly += '\n.text\n' + block(cls.platform_source,'win_nt_open','win_drive_path')
        assembly += '\n.text\n' + block(cls.platform_source,'win_protect','win_ntfs')
        assembly += r"""
.text
.global protect_arc_stage
protect_arc_stage:
    WFRAME
    call arc_create_stage
    test eax, eax
    jnz 1f
    mov rdi, [rip + arc_root_fd]
    call win_protect
1:  WLEAVE
win_syscall:
    WFRAME
    cmp eax, 318
    je .Lstage_random
    cmp eax, 258
    je .Lstage_mkdir
    cmp eax, 257
    jne .Lstage_unknown
    mov r10, rdx
    xor edi, edi
    lea rsi, [rip + test_stage_wide]
    mov edx, 10
    xor r8d, r8d
    call win_nt_open
    WLEAVE
.Lstage_random:
    mov rax, rsi
    mov qword ptr [rdi], 0
    mov qword ptr [rdi + 8], 0
    WLEAVE
.Lstage_mkdir:
    xor eax, eax
    WLEAVE
.Lstage_unknown:
    mov rax, -38
    WLEAVE
NtCreateFile:
    mov [rip + test_stage_access], edx
    mov qword ptr [rcx], 77
    xor eax, eax
    ret
GetFileInformationByHandleEx:
    mov qword ptr [r8], 16
    mov eax, 1
    ret
SetSecurityInfo:
    mov eax, 5
    cmp rcx, 77
    jne 1f
    test dword ptr [rip + test_stage_access], 0x40000
    jz 1f
    xor eax, eax
1:  ret
CloseHandle:
    ret
win_nt_error:
    mov rax, -13
    ret
.data
arc_parent_fd: .quad 7
arc_root_fd: .quad -1
arc_stage_created: .byte 0
arc_random: .space 16
arc_hex: .asciz "0123456789abcdef"
arc_stage_name: .asciz ".asm-stage-00000000000000000000000000000000"
.p2align 2
test_stage_access: .long 0
test_stage_wide: .short 's','t','a','g','e',0
win_private_sd: .space 64
win_private_acl: .space 4096
"""
        driver = '#include <stdio.h>\nextern long protect_arc_stage(void);\nint main(){printf("%ld\\n",protect_arc_stage());}\n'
        cls.build('arc-stage-protection',assembly,driver,['protect_arc_stage'])

    def test_private_archive_stage_open_permits_required_dacl_finalization(self):
        r = self.run_fixture('arc-stage-protection')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout.strip(),'0')

    @classmethod
    def build_release_metadata(cls):
        assembly = '.intel_syntax noprefix\n' + prep.prepare(ROOT / 'cli/self_update_metadata.s')
        assembly = assembly.replace('.global self_parse_release, self_source_commit','')
        assembly += '\n.global self_parse_release\n'
        driver = r"""
#include <stdio.h>
#include <stdlib.h>
extern int self_parse_release(const char*,unsigned long,const char**);
int main(int n,char**a){FILE*f=fopen(a[1],"rb");if(!f)return 2;char*b=malloc(1048576);size_t z=fread(b,1,1048576,f);fclose(f);
const char*row[]={"stubbi/asm","0.6.1","x86_64-windows","executable","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","https://github.com/stubbi/asm/releases/download/v0.6.1/asm-0.6.1-x86_64-windows.exe","1234","fixture"};
printf("%d\n",self_parse_release(b,z,row));free(b);}
"""
        cls.build('release-metadata',assembly,driver,['self_parse_release'])

    @classmethod
    def build_image_identity(cls):
        assembly = cls.macros + block(cls.platform_source,'win_image_matches','win_display_path')
        assembly += r"""
.text
.global image_identity
image_identity:
    WFRAME
    mov [rip + test_query_status], edi
    mov [rip + test_resolution], esi
    mov edi, 77
    call win_image_matches
    WLEAVE
GetModuleHandleW:
    cmp dword ptr [rip + test_resolution], 1
    je .Lmodule_missing
    mov eax, 9
    ret
.Lmodule_missing:
    xor eax, eax
    ret
GetProcAddress:
    cmp dword ptr [rip + test_resolution], 2
    je .Lmodule_missing
    lea rax, [rip + test_image_query]
    ret
test_image_query:
    cmp rcx, -1
    jne .Lquery_bad
    cmp edx, 44
    jne .Lquery_bad
    cmp r9d, 8
    jne .Lquery_bad
    cmp qword ptr [r8], 77
    jne .Lquery_bad
    cmp qword ptr [rsp + 40], 0
    jne .Lquery_bad
    mov eax, [rip + test_query_status]
    ret
.Lquery_bad:
    mov eax, 0xc000000d
    ret
.data
test_query_status: .long 0
test_resolution: .long 0
"""
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long image_identity(long,int);\nint main(int n,char**a){printf("%ld\\n",image_identity(strtoul(a[1],0,0),atoi(a[2])));}\n'
        cls.build('image-identity',assembly,driver,['image_identity'])
        assembly = cls.macros + block(cls.platform_source,'win_nt_open','win_drive_path')
        assembly += r"""
.text
.global image_access
image_access:
    WFRAME
    xor r10d, r10d
    test edi, edi
    jz 1f
    cmp edi, 2
    je 2f
    cmp edi, 3
    je 3f
    mov r10d, 0x40000000
    jmp 1f
2:  mov r10d, 0x0a000000
    jmp 1f
3:  mov r10d, 0x08000000
1:  xor edi, edi
    lea rsi, [rip + test_image_name]
    mov edx, 2
    xor r8d, r8d
    call win_nt_open
    mov eax, [rip + test_access]
    mov edx, [rip + test_share]
    shl rdx, 32
    or rax, rdx
    WLEAVE
NtCreateFile:
    mov [rip + test_access], edx
    mov edx, [rsp + 56]
    mov [rip + test_share], edx
    mov qword ptr [rcx], 77
    xor eax, eax
    ret
GetFileInformationByHandleEx:
    mov qword ptr [r8], 0
    mov eax, 1
    ret
CloseHandle:
    ret
win_nt_error:
    mov rax, -13
    ret
.data
test_access: .long 0
test_share: .long 0
test_image_name: .short 'a',0
win_private_sd: .space 64
"""
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long image_access(int);\nint main(int n,char**a){printf("%ld\\n",image_access(atoi(a[1])));}\n'
        cls.build('image-access',assembly,driver,['image_access'])


    @classmethod
    def build_display_path(cls):
        assembly = cls.macros + block(cls.platform_source,'win_display_path','win_json_path')
        assembly += '\n.global display_path\ndisplay_path:\n    jmp win_display_path\n'
        driver = '#include <stdio.h>\nextern const char* display_path(const char*);\nint main(int n,char**a){puts(display_path(a[1]));}\n'
        cls.build('display-path',assembly,driver,['display_path'])

    def test_release_metadata_binds_the_exact_windows_executable_name(self):
        manifest = {'schema':1,'project':'asm','version':'0.6.1','tag':'v0.6.1',
                    'repository':'https://github.com/stubbi/asm','source_commit':'a'*40,
                    'assets':[{'file':'asm-0.6.1-x86_64-windows.exe','bytes':1234,'sha256':'a'*64}]}
        path = self.directory / 'release.json'
        path.write_text(json.dumps(manifest))
        self.assertEqual(self.run_fixture('release-metadata',str(path)).stdout.strip(),'0')
        for change in [{'file':'asm-0.6.1-x86_64-windows'}, {'bytes':1235}, {'sha256':'b'*64}]:
            original = dict(manifest['assets'][0]);manifest['assets'][0].update(change)
            path.write_text(json.dumps(manifest))
            self.assertEqual(self.run_fixture('release-metadata',str(path)).stdout.strip(),'1')
            manifest['assets'][0] = original

    def test_execute_access_is_requested_only_for_the_image_open(self):
        ordinary = int(self.run_fixture('image-access','0').stdout.strip())
        image = int(self.run_fixture('image-access','1').stdout.strip())
        self.assertEqual(ordinary & 32,0)
        self.assertEqual(image,ordinary | 32)

    def test_managed_snapshots_deny_write_and_allow_read_delete_sharing(self):
        payload = int(self.run_fixture('image-access','2').stdout.strip())
        record = int(self.run_fixture('image-access','3').stdout.strip())
        self.assertEqual(payload >> 32, 5)
        self.assertEqual(record >> 32, 5)
        self.assertEqual(payload & 32, 32)
        self.assertEqual(record & 32, 0)

    def test_image_open_checks_the_held_file_before_descriptor_allocation(self):
        self.assertEqual(self.run_fixture('image-open','0').stdout.strip(),'3 1 1 2')
        self.assertEqual(self.run_fixture('image-open','1').stdout.strip(),'-116 1 0 3')

    def test_image_identity_accepts_only_exact_success_and_available_api(self):
        for status,resolution,expected in [(0,0,0),(0xc0000001,0,-116),(0x103,0,-95),(0x80000002,0,-95),(0,1,-95),(0,2,-95)]:
            r = self.run_fixture('image-identity',str(status),str(resolution))
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(r.stdout.strip(),str(expected))

    def test_windows_output_paths_use_native_drive_syntax(self):
        for value,expected in [('/C:/Users/test/app.exe','C:/Users/test/app.exe'),('C:/app.exe','C:/app.exe'),('relative.exe','relative.exe'),('/tmp/item','/tmp/item')]:
            self.assertEqual(self.run_fixture('display-path',value).stdout.strip(),expected)

    @classmethod
    def build_clang_arguments(cls):
        assembly = cls.macros + block(cls.platform_source,'win_compile_project','win_component_safe')
        assembly += '\n.text\n' + cls.prepared[cls.prepared.index('native_link_compile_check:\n'):cls.prepared.index('.section .rdata',cls.prepared.index('native_cc_spawn:\n'))]
        assembly += r"""
.text
.global clang_arguments
clang_arguments:
    cmp edi, 1
    je win_link_standalone
    cmp edi, 2
    je native_link_compile_check
    cmp edi, 3
    je native_link_build
    jmp win_compile_project
spawn_wait:
    mov rax, rsi
    ret
.data
as_path: .asciz "C:/LLVM/bin/clang.exe"
ld_path: .asciz "C:/LLVM/bin/clang.exe"
as_64: .asciz "-c"
arg_I: .asciz "-I"
arg_o: .asciz "-o"
arg_z: .asciz "-nostdlib"
dependency_packages_root: .asciz ".asm/packages"
stage_object: .asciz "build/private/main.o"
stage_binary: .asciz "build/private/app.exe"
package_source: .asciz "src/main.s"
package_test: .asciz "custom/test.s"
package_check: .asciz "abi.c"
package_libraries: .asciz "kernel32 ucrt"
test_mode: .byte 0
.p2align 3
native_include_count: .quad 0
native_library_count: .quad 0
native_include_dirs: .space 64
native_library_dirs: .space 64
native_library_args: .space 272
native_cc_argv: .space 512
child_argv: .space 512
"""
        for name in ['win_kernel32_lib','noexecstack']:
            assembly += re.findall(r'^' + name + r': .+$',cls.prepared,re.M)[0] + '\n'
        for row in re.findall(r'^native_\w+: .asciz .+$',cls.prepared,re.M):
            assembly += row + '\n'
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern const char** clang_arguments(int);\nint main(int n,char**a){const char**v=clang_arguments(atoi(a[1]));for(int i=0;i<64&&v[i];i++)puts(v[i]);}\n'
        cls.build('clang-arguments',assembly,driver,['clang_arguments'])

    def test_clang_default_configuration_is_actually_ignored(self):
        config = self.directory / 'compiler-config'
        config.mkdir()
        (config / 'x86_64-pc-windows-msvc-clang.cfg').write_text('--asm-ambient-configuration-must-not-load\n')
        base = [self.clang,'--target=x86_64-pc-windows-msvc',
                '--config-user-dir='+str(config),'--config-system-dir='+str(config),
                '-###','-E','-x','c','-']
        loaded = subprocess.run(base,input='',capture_output=True,text=True,timeout=10)
        self.assertNotEqual(loaded.returncode,0)
        self.assertIn('--asm-ambient-configuration-must-not-load',loaded.stderr)
        isolated = subprocess.run(base+['--no-default-config'],input='',capture_output=True,text=True,timeout=10)
        self.assertEqual(isolated.returncode,0,isolated.stderr)
        self.assertNotIn('--asm-ambient-configuration-must-not-load',isolated.stderr)

    def test_every_native_clang_path_disables_ambient_configuration(self):
        for mode in range(4):
            r = self.run_fixture('clang-arguments',str(mode))
            self.assertEqual(r.returncode,0,r.stderr)
            arguments = r.stdout.splitlines()
            self.assertEqual(arguments[1],'--no-default-config')
            if mode in [1,3]:
                self.assertIn('-fuse-ld=lld',arguments)
                self.assertTrue(any('/Brepro' in a for a in arguments))
            if mode == 1:
                self.assertIn('-Wl,kernel32.lib',arguments)
                self.assertNotIn('kernel32.lib',arguments)
            if mode == 2:
                self.assertIn('-fsyntax-only',arguments)
            if mode == 3:
                self.assertIn('-lkernel32',arguments)
                self.assertIn('-lucrt',arguments)

    @classmethod
    def build_process(cls):
        body = block(cls.platform_source,'win_process','win_explicit_environment')
        data = cls.platform_source[cls.platform_source.rindex('.section .data',0,cls.platform_source.index('win_pipe_security:')):cls.platform_source.index('win_hash_file:\n')]
        assembly = cls.macros + body + data + '\n.text\n' + block(cls.prepared,'streq','strlen') + r"""
.text
.global process_case
process_case:
    WFRAME
    lea rdi, [rip + as_path]
    lea rsi, [rip + test_argv]
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    mov r9, -1
    call win_process
    WLEAVE
win_wide:
win_wide_command:
""".replace('win_wide_command:\n','') + r"""
    mov eax, 1
    ret
MultiByteToWideChar:
    mov eax, 1
    ret
win_build_environment:
win_explicit_environment:
    xor eax, eax
    ret
CreateFileW:
    mov eax, 17
    ret
DuplicateHandle:
    test rdx, rdx
    jz 1f
    lea rax, [rdx + 100]
    mov [r9], rax
    mov eax, 1
    ret
1:  xor eax, eax
    ret
InitializeProcThreadAttributeList:
    test rcx, 7
    setz al
    movzx eax, al
    ret
UpdateProcThreadAttribute:
    mov eax, 1
    ret
CreateProcessW:
    mov rax, [rsp + 80]
    mov qword ptr [rax], 70
    mov qword ptr [rax + 8], 71
    mov eax, 1
    ret
GetTickCount64:
WaitForSingleObject:
    xor eax, eax
    ret
GetExitCodeProcess:
    mov dword ptr [rdx], 0
    mov eax, 1
    ret
DeleteProcThreadAttributeList:
CloseHandle:
TerminateProcess:
CreatePipe:
SetHandleInformation:
PeekNamedPipe:
ReadFile:
    mov eax, 1
    ret
GetLastError:
    mov eax, 109
    ret
win_handle:
    mov rax, rdi
    ret
.data
as_path: .asciz "C:/clang.exe"
native_cc_path: .asciz "C:/clang.exe"
.p2align 3
test_argv: .quad as_path,0
win_handles: .quad 10,11,12
"""
        cls.build('process',assembly,'#include <stdio.h>\nextern long process_case(void);\nint main(){printf("%ld\\n",process_case());}\n',['process_case'])
        # Exercise the production ownership transfers, not a cleanup model.
        # Modes fail SetHandleInformation, stdin open, or CreateProcessW;
        # the final mode completes capture and revisits stream cleanup.
        capture = assembly.replace('process_case:\n    WFRAME\n',
                                   'process_case:\n    WFRAME\n    mov [rip + test_mode], edi\n',1)
        capture = capture.replace('    xor r10d, r10d\n',
                                  '    lea r10, [rip + test_capture]\n',1)
        capture = capture.replace('    xor r8d, r8d\n    mov r9, -1\n',
                                  '    mov r8d, 64\n    mov r9, -1\n',1)
        capture = capture.replace('    call win_process\n    WLEAVE\n',
                                  '    call win_process\n    mov r12, rax\n    call win_close_child_streams\n    mov rax, r12\n    WLEAVE\n',1)
        capture = capture.replace('CreateFileW:\n    mov eax, 17\n    ret\n',r"""CreateFileW:
    cmp dword ptr [rip + test_mode], 2
    je 1f
    mov eax, 17
    ret
1:  mov rax, -1
    ret
""",1)
        capture = capture.replace('CreateProcessW:\n    mov rax, [rsp + 80]\n',r"""CreateProcessW:
    cmp dword ptr [rip + test_mode], 3
    jne 1f
    xor eax, eax
    ret
1:  mov rax, [rsp + 80]
""",1)
        capture = capture.replace('DeleteProcThreadAttributeList:\nCloseHandle:\nTerminateProcess:\nCreatePipe:\nSetHandleInformation:\nPeekNamedPipe:\nReadFile:\n',r"""CloseHandle:
    mov eax, [rip + test_close_count]
    cmp eax, 16
    jae 1f
    lea rdx, [rip + test_closed]
    mov [rdx + rax*8], rcx
1:  inc dword ptr [rip + test_close_count]
    mov eax, 1
    ret
CreatePipe:
    mov qword ptr [rcx], 41
    mov qword ptr [rdx], 42
    mov eax, 1
    ret
SetHandleInformation:
    cmp rcx, 41
    jne 1f
    cmp edx, 1
    jne 1f
    test r8d, r8d
    jnz 1f
    cmp dword ptr [rip + test_mode], 1
    setne al
    movzx eax, al
    ret
1:  mov dword ptr [rip + test_api_error], 1
    xor eax, eax
    ret
PeekNamedPipe:
    xor eax, eax
    ret
DeleteProcThreadAttributeList:
TerminateProcess:
ReadFile:
""",1)
        capture += r"""
.text
.global capture_close_count
capture_close_count:
    mov eax, [rip + test_close_count]
    ret
.global capture_close_at
capture_close_at:
    lea rax, [rip + test_closed]
    mov rax, [rax + rdi*8]
    ret
.global capture_cleanup_error
capture_cleanup_error:
    mov rax, [rip + win_child_stdin]
    or rax, [rip + win_child_stdout]
    or rax, [rip + win_child_stderr]
    or rax, [rip + win_pipe_write]
    or eax, [rip + test_api_error]
    ret
.data
.p2align 3
test_mode: .quad 0
test_close_count: .quad 0
test_api_error: .quad 0
test_closed: .space 128
test_capture: .space 64
"""
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long process_case(int),capture_close_count(void),capture_close_at(long),capture_cleanup_error(void);\nint main(int argc,char**argv){if(argc!=2)return 2;long status=process_case(atoi(argv[1]));long count=capture_close_count();printf("%ld %ld %ld",status,count,capture_cleanup_error());for(long i=0;i<count&&i<16;i++)printf(" %ld",capture_close_at(i));puts("");}\n'
        cls.build('process-capture-cleanup',capture,driver,
                  ['process_case','capture_close_count','capture_close_at','capture_cleanup_error'])

    def test_process_api_storage_has_required_alignment(self):
        r = self.run_fixture('process')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout.strip(),'0')

    def test_capture_setup_failure_closes_both_pipe_handles_once(self):
        for mode in ('1','2'):
            with self.subTest(failing_api='SetHandleInformation' if mode=='1' else 'CreateFileW'):
                result = self.run_fixture('process-capture-cleanup',mode)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),'127 2 0 42 41')

    def test_capture_process_failure_and_success_close_each_owned_handle_once(self):
        for mode,expected in (('3','127 4 0 17 42 112 41'),
                              ('4','0 6 0 17 42 112 41 70 71')):
            with self.subTest(mode=mode):
                result = self.run_fixture('process-capture-cleanup',mode)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout.strip(),expected)

    @classmethod
    def build_security(cls):
        body = block(cls.platform_source, 'win_stat', 'win_protect')
        if 'win_owner_class:\n' in cls.platform_source:
            body += block(cls.platform_source, 'win_owner_class', 'win_stat')
        assembly = cls.macros + body + r"""
.text
.global security_case
security_case:
    WFRAME
    mov [rip + test_owner_sid], edi
    mov [rip + win_token_elevation], esi
    mov [rip + test_grant_sid], edx
    mov [rip + test_ace + 4], ecx
    mov [rip + test_attributes], r8d
    mov edi, 7
    lea rsi, [rip + test_stat]
    call win_stat
    test rax, rax
    jnz 1f
    mov eax, [rip + test_stat + 28]
    shl eax, 8
    mov edx, [rip + test_stat + 24]
    and edx, 18
    or eax, edx
1:  WLEAVE
GetFileInformationByHandle:
    mov r9, rdx
    mov rdi, rdx
    mov ecx, 7
    xor eax, eax
    rep stosq
    mov eax, [rip + test_attributes]
    mov [r9], eax
    mov dword ptr [r9 + 28], 1
    mov dword ptr [r9 + 40], 1
    mov dword ptr [r9 + 48], 1
    mov eax, 1
    ret
GetSecurityInfo:
    lea rax, [rip + test_owner_sid]
    mov [r9], rax
    mov rdx, [rsp + 48]
    lea rax, [rip + test_acl]
    mov [rdx], rax
    mov rdx, [rsp + 64]
    mov [rdx], rax
    xor eax, eax
    ret
EqualSid:
    mov eax, [rcx]
    cmp eax, [rdx]
    sete al
    movzx eax, al
    ret
IsValidAcl:
IsValidSid:
    mov eax, 1
    ret
GetAce:
    mov eax, [rip + test_grant_sid]
    mov [rip + test_ace + 8], eax
    lea rax, [rip + test_ace]
    mov [r8], rax
    mov eax, 1
    ret
LocalFree:
    ret
win_error:
    mov rax, -5
    ret
.data
win_token_user: .quad test_user_sid
win_token_elevation: .long 0
test_user_sid: .long 1
win_system_sid: .long 2
win_admin_sid: .long 3
win_installer_sid: .long 4
win_owner_rights_sid: .long 6
test_owner_sid: .long 0
    .long 0
test_grant_sid: .long 0
test_attributes: .long 0
test_acl: .byte 2,0,0,0,1,0,0,0
test_ace: .byte 0,0,16,0
    .long 0,0,0
test_stat: .space 144
"""
        driver = '#include <stdio.h>\n#include <stdlib.h>\nextern long security_case(int,int,int,int,int);\nint main(int n,char**a){printf("%ld\\n",security_case(atoi(a[1]),atoi(a[2]),atoi(a[3]),strtoul(a[4],0,0),atoi(a[5]))); }\n'
        cls.build('security', assembly, driver, ['security_case'])

    def test_real_windows_owner_and_acl_contract(self):
        cases = [(4,0,2,0x1f01ff,16,0), (3,1,6,0x1f01ff,0,256),
                 (3,0,6,0x1f01ff,0,0), (3,1,6,0x1f01ff,16,0),
                 (5,1,6,0x1f01ff,0,530),
                 (1,0,5,2,16,274), (4,0,5,4,16,0),
                 (4,0,5,2,16,18), (1,0,1,0x1f01ff,0,256),
                 (1,0,6,0x1f01ff,0,256), (2,0,4,0x1f01ff,16,0)]
        for owner, elevated, grant, mask, attributes, expected in cases:
            with self.subTest(owner=owner,elevated=elevated,grant=grant,mask=mask):
                r = self.run_fixture('security', *map(str,(owner,elevated,grant,mask,attributes)))
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertEqual(r.stdout.strip(),str(expected))

    def test_native_api_literal_alignment_in_actual_coff(self):
        source = self.directory / 'literal-alignment.s'
        obj = self.directory / 'literal-alignment.obj'
        source.write_text(self.prepared)
        r = subprocess.run([self.clang,'--no-default-config','-target','x86_64-pc-windows-msvc','-c',str(source),'-o',str(obj)],capture_output=True,text=True,timeout=30)
        self.assertEqual(r.returncode,0,r.stderr)
        data = obj.read_bytes()
        _,_,_,offset,count,_,_ = struct.unpack_from('<HHIIIHH',data)
        strings = offset + count*18
        symbols = {}
        for i in range(count):
            location = offset + i*18
            name = data[location:location+8]
            if name[:4] == b'\0'*4:
                start = strings + struct.unpack_from('<I',name,4)[0]
                name = data[start:data.find(b'\0',start)]
            else:
                name = name.rstrip(b'\0')
            symbols[name.decode(errors='replace')] = struct.unpack_from('<I',data,location+8)[0]
        wide = ['win_nt_root','win_lock_name','win_installer_name','win_home_name',
                'win_profile_name','win_null_wide','win_sha256_name','win_object_length','win_ntdll_name']
        for name in wide:
            with self.subTest(symbol=name):
                self.assertEqual(symbols[name] % 2,0)
        self.assertEqual(symbols['win_build_names'] % 8,0)

    def test_drive_absolute_output_does_not_use_cwd(self):
        for value in ['C:/output/tool.exe', r'C:\output\tool.exe', '/C:/output/tool.exe']:
            with self.subTest(value=value):
                result = self.run_fixture('path', value)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '/C:/output/tool.exe')

    def test_relative_output_uses_cwd(self):
        result = self.run_fixture('path', 'tool.exe')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '/C:/project/tool.exe')

    def test_ambiguous_drive_and_network_paths_fail(self):
        for value in ['C:tool.exe', 'C:', '//server/share/tool.exe', r'\\server\share\tool.exe', r'\rooted\tool.exe']:
            with self.subTest(value=value):
                self.assertNotEqual(self.run_fixture('path', value).returncode, 0)

    def test_valid_pe_is_accepted(self):
        cases = [((1,0x1000,512,512),(1,0x2000,512,1024)),
                 ((4096,0x1000,512,512),(1,0x2000,512,1024)),
                 ((1,0x1000,4096,512),(1,0x2000,512,4608)),
                 ((1,0x1000,512,1024),(1,0x2000,512,512))]
        for i, sections in enumerate(cases):
            with self.subTest(case=i):
                path = self.directory / ('valid-' + str(i) + '.exe')
                path.write_bytes(fixture_pe(sections))
                self.assertEqual(self.run_fixture('pe', str(path)).stdout.strip(), '1')

    def test_overlapping_or_header_mapped_pe_is_rejected(self):
        cases = {
            'overlap': ((1,0x1000,512,512),(1,0x1000,512,1024)),
            'header': ((1,0x1000,512,512),(1,0,512,1024)),
            'first_header': ((1,0,512,512),(1,0x2000,512,1024)),
            'raw_extent': ((1,0x1000,8192,512),(1,0x2000,512,8704)),
            'raw_pointer_overlap': ((1,0x1000,512,512),(1,0x2000,512,512)),
            'virtual_extent': ((4097,0x1000,512,512),(1,0x2000,512,1024)),
            'overflow': ((1,0x1000,512,512),(0xffffffff,0xfffff000,512,1024)),
        }
        for name, sections in cases.items():
            with self.subTest(name=name):
                path = self.directory / (name + '.exe')
                path.write_bytes(fixture_pe(sections, image_size=0x5000 if name == 'raw_extent' else 0x3000,
                                            entry=0 if name == 'first_header' else 0x1000))
                result = self.run_fixture('pe', str(path))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '0')

    def test_busy_capture_checks_deadline_before_every_read(self):
        result = self.run_fixture('capture')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '127 2 4 1')

    def test_capture_drains_final_byte_after_observing_child_exit(self):
        result = self.run_fixture('capture-final-byte')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '0 1 0 1 120')

    def test_unlink_preserves_directories_and_rmdir_preserves_files(self):
        cases = [(0,16,'-21 0 1'),(0,0,'0 1 1'),(1,16,'0 1 1'),(1,0,'-20 0 1'),(2,0,'-22 0 0')]
        for mode, attributes, expected in cases:
            with self.subTest(mode=mode, attributes=attributes):
                result = self.run_fixture('delete', str(mode), str(attributes))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_relative_open_accepts_extended_dos_cwd_without_namespace_ambiguity(self):
        result = self.run_fixture('extended-cwd')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '-2 -2 -22 -22')

    def test_verifier_windows_paths_stay_in_the_private_directory(self):
        result = self.run_fixture('verifier-environment')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ['0'] + [name + '=C:/Users/test user/private/verifier' for name in
            ['HOME','GH_CONFIG_DIR','XDG_CACHE_HOME','XDG_CONFIG_HOME','USERPROFILE','LOCALAPPDATA']]
        self.assertEqual(result.stdout.splitlines(), expected)

    def test_verifier_environment_refuses_an_unexpected_namespace(self):
        result = self.run_fixture('verifier-environment', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '-22')


class DiagnosticEvidence(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('x64_diagnostic',LOCAL / 'native_diagnostics.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_timeout_keeps_bounded_partial_output_and_fails_collection(self):
        report = {'commands': []}
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'timeout.json'
            def operation():
                with mock.patch.object(self.module.subprocess,'run',side_effect=subprocess.TimeoutExpired(['fixture'],30,output=b'x'*70000,stderr=b'partial error')):
                    self.module.run_recorded(report,['fixture'])
            result = self.module.collect_evidence(destination,report,operation)
            saved = json.loads(destination.read_text())
        self.assertEqual(result,1)
        self.assertTrue(saved['commands'][0]['timed_out'])
        self.assertEqual(len(saved['commands'][0]['stdout']),65536)
        self.assertEqual(saved['commands'][0]['stderr'],'partial error')
        self.assertTrue(saved['commands'][0]['output_truncated'])

    def test_binary_probe_retains_digest_and_size_without_file_contents(self):
        report = {'commands': []}
        data = b'owned binary fixture\0'
        result = subprocess.CompletedProcess(['fixture'],0,data,b'')
        with mock.patch.object(self.module.subprocess,'run',return_value=result):
            self.module.run_recorded(report,['fixture'],binary=True,input=b'input')
        row = report['commands'][0]
        self.assertEqual(row['stdout'],'')
        self.assertEqual(row['stdout_bytes'],len(data))
        self.assertEqual(row['stdout_sha256'],self.module.hashlib.sha256(data).hexdigest())

    def test_source_probe_index_keeps_lf_under_windows_text_translation(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            project = work / 'project'
            (project / 'src').mkdir(parents=True)
            (project / 'asm.toml').write_bytes(b'[package]\nname = "hello"\n')
            (project / 'src/main.s').write_bytes(b'.text\n')
            def windows_text(path, text, *args, **options):
                return path.write_bytes(text.replace('\n','\r\n').encode('utf-8'))
            with mock.patch.object(Path,'write_text',autospec=True,side_effect=windows_text):
                artifact,index,raw = self.module.source_fixture(work,project)
            self.assertNotIn(b'\r',index.read_bytes())
            self.assertEqual(index.read_bytes().splitlines()[0],b'# asm-registry-v1')

    def test_native_rename_probe_uses_the_exact_windows_abi_layout(self):
        import ctypes
        spec = importlib.util.spec_from_file_location('native_rename_probe',LOCAL / 'rename_probe.py')
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        expected = {'UnicodeString':16,'ObjectAttributes':48,'IoStatus':16,
                    'FileInformation':52,'Startup':104,'ProcessInformation':24}
        for name,size in expected.items():
            self.assertEqual(ctypes.sizeof(getattr(probe,name)),size)
        data,length = probe.rename_buffer(0x1234,'asm.exe')
        self.assertEqual(length,34)
        self.assertEqual(probe.U32.from_buffer(data,0).value,3)
        self.assertEqual(probe.PTR.from_buffer(data,8).value,0x1234)
        self.assertEqual(probe.U32.from_buffer(data,16).value,14)
        self.assertEqual(data.raw[20:36],'asm.exe'.encode('utf-16-le')+b'\0\0')

    def test_os_error_and_later_exception_preserve_collected_rows(self):
        report = {'commands': []}
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'os-error.json'
            def operation():
                with mock.patch.object(self.module.subprocess,'run',side_effect=FileNotFoundError(2,'fixture missing')):
                    self.module.run_recorded(report,['fixture'])
                raise ValueError('later collection failure')
            result = self.module.collect_evidence(destination,report,operation)
            saved = json.loads(destination.read_text())
        self.assertEqual(result,1)
        self.assertEqual(saved['commands'][0]['os_error']['errno'],2)
        self.assertEqual(saved['collection_error']['type'],'ValueError')


class ManagedShims(unittest.TestCase):
    """Execute the managed record parser, borrowed PE reader, and image query."""
    build = classmethod(HostShims.build.__func__)
    run_fixture = classmethod(HostShims.run_fixture.__func__)

    @classmethod
    def setUpClass(cls):
        cls.clang = shutil.which('clang')
        cls.prefix = '_' if platform.system() == 'Darwin' else ''
        cls.temp = tempfile.TemporaryDirectory(prefix='asm-managed-x64-')
        cls.directory = Path(cls.temp.name)
        source = (LOCAL / 'managed.s').read_text()
        platform_source = (LOCAL / 'platform.s').read_text()
        start = platform_source.index('.macro WFRAME\n')
        end = platform_source.index('.text\n', start)
        macros = '.intel_syntax noprefix\n.equ ARTIFACT_LIMIT,67108864\n' + platform_source[start:end]
        registry = (ROOT / 'cli/registry.s').read_text()
        assembly = macros + '\n.text\n' + source.split('/* BEGIN RECORD PARSER */')[1].split('/* END RECORD PARSER */')[0]
        assembly += '\n.text\n' + block(registry, 'registry_valid_version', 'registry_valid_target')
        assembly += block(registry, 'registry_size_value', 'registry_valid_index_url') if 'registry_valid_index_url:\n' in registry else registry[registry.index('registry_size_value:\n'):registry.index('/* Input: RDI=index URL')]
        assembly += '''\nregistry_valid: mov eax,1\n ret\nregistry_invalid: xor eax,eax\n ret\n.equ ARTIFACT_LIMIT,67108864\n.global check_record\ncheck_record:\n jmp win_managed_parse_record\n'''
        assembly += f'\nstreq: jmp {cls.prefix}same\nstrlen: jmp {cls.prefix}strlen\n'
        assembly += '\n.data\nregistry_host: .asciz "x86_64-windows"\n'
        driver = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int check_record(char*,uint64_t);
int same(const char*a,const char*b){return strcmp(a,b)==0;}
int main(int argc,char**argv){char b[1024];FILE*f=fopen(argv[1],"rb");if(!f)return 2;size_t n=fread(b,1,sizeof b,f);fclose(f);printf("%d\n",check_record(b,n));return 0;}
'''
        cls.build('record', assembly, driver, ['check_record'])
        assembly = macros + '\n.text\n' + block(source, 'win_managed_path_role', 'win_managed_hold')
        assembly += '\n.global check_role\ncheck_role:\n sub rsp,8\n call win_managed_path_role\n add rsp,8\n ret\n'
        assembly += f'\nstrlen: jmp {cls.prefix}strlen\n'
        assembly += '\n.data\nwm_root_suffix: .asciz "/.local/bin/asm.exe"\nwm_exe_suffix: .asciz "/asm.exe"\nwm_versions_suffix: .asciz "/.asm-cli/versions/"\nwm_bin_suffix: .asciz "/.local/bin"\n'
        cls.build('role', assembly, '#include <stdio.h>\nextern int check_role(char*);\nint main(int n,char**a){printf("%d\\n",check_role(a[1]));}\n', ['check_role'])
        assembly = macros + '\n.text\n' + (LOCAL / 'pe.s').read_text()
        assembly += f'''
.text
.global check_metadata
check_metadata:
    jmp win_managed_pe
win_syscall:
    WFRAME
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rax
    call {cls.prefix}io
    WLEAVE
'''
        driver = r'''
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
extern long check_metadata(long,uint64_t,void*);
static int opens,closes;
long io(long n,long a,long b,long c){struct stat st;long r=-38;
if(n==2){opens++;return -1;}if(n==3){closes++;return close(a);}
if(n==0)r=read(a,(void*)b,c);if(n==8)r=lseek(a,b,c);
if(n==5){r=fstat(a,&st);if(!r){memset((void*)b,0,144);*(uint32_t*)(b+24)=0100000;*(uint64_t*)(b+48)=st.st_size;}}
return r;}
int main(int n,char**a){struct stat st;char meta[64];int fd=open(a[1],O_RDONLY);fstat(fd,&st);lseek(fd,123,0);long r=check_metadata(fd,st.st_size,meta);printf("%ld %d %d %d\n",r,opens,closes,fcntl(fd,F_GETFD)>=0);close(fd);return 0;}
'''
        cls.build('metadata', assembly, driver, ['check_metadata'])
        assembly = macros + '\n.text\n' + platform_source[platform_source.index('win_child_image_matches:\n'):platform_source.index('.text\n/* RDI=terminated path.', platform_source.index('win_child_image_matches:\n'))]
        assembly += r'''
.text
.global check_remote
check_remote:
    mov [rip + query_status], edi
    mov edi, 123
    mov esi, 77
    jmp win_child_image_matches
GetModuleHandleW:
    mov eax, 1
    ret
GetProcAddress:
    lea rax, [rip + query]
    ret
query:
    cmp rcx, 123
    jne 1f
    cmp edx, 44
    jne 1f
    cmp r9d, 8
    jne 1f
    cmp qword ptr [r8], 77
    jne 1f
    cmp qword ptr [rsp + 40], 0
    jne 1f
    mov eax, [rip + query_status]
    ret
1:  mov eax, 0xc000000d
    ret
.data
query_status: .long 0
'''
        cls.build('remote', assembly, '#include <stdio.h>\n#include <stdlib.h>\nextern long check_remote(unsigned);\nint main(int n,char**a){printf("%ld\\n",check_remote(strtoul(a[1],0,0)));}\n', ['check_remote'])
        cls.build_borrowed_hash(macros, platform_source)
        cls.build_cleanup(macros, source)
        cls.build_launcher(macros, platform_source)
        cls.build_held_rename(macros, platform_source)
        cls.build_startup_requirements(macros, source)
        cls.build_lock_admission(macros, platform_source)
        cls.build_directory_publication(macros, source)

    @classmethod
    def build_directory_publication(cls, macros, managed):
        source = (LOCAL / 'versioned_update.s').read_text()
        start = source.index('    mov eax, 258\n', source.index('win_managed_commit_update:\n'))
        end = source.index('.Lwmu_published:\n', start)
        assembly = macros + '\n.text\n.global check_publication\ncheck_publication:\n    WFRAME\n'
        assembly += source[start:end]
        assembly += '''
.Lwmu_published:
    xor eax,eax
    WLEAVE
self_io_error:
    mov rax,-5
    WLEAVE
self_permissions_error:
    mov rax,-13
    WLEAVE
self_changed:
    mov rax,-116
    WLEAVE
'''
        assembly += block(source, 'win_managed_candidate', 'win_managed_commit_update')
        assembly += source[source.index('win_managed_same_fd:\n'):]
        assembly += '\n.text\n' + block(managed, 'win_managed_version_text', 'win_managed_cleanup')
        assembly += block((ROOT / 'cli/self_update.s').read_text(), 'self_check_file_stat', 'self_check_destination')
        assembly += f'''
.text
win_syscall:
    WFRAME
    mov rcx,rdx
    mov rdx,rsi
    mov rsi,rdi
    mov rdi,rax
    call {cls.prefix}publication_io
    WLEAVE
win_open: jmp {cls.prefix}publication_open
win_managed_rename_fd: jmp {cls.prefix}publication_rename
win_hash_fd: jmp {cls.prefix}publication_hash
win_managed_pe: jmp {cls.prefix}publication_metadata
streq: jmp {cls.prefix}publication_same
win_handle:
    mov rax,rdi
    ret
.data
registry_selected: .quad selection
selection: .quad 0,selected_version,0,0,selected_hash,0,0
selected_version: .asciz "0.6.1"
selected_hash: .asciz "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
registry_expected_size: .quad 4096
self_uid: .long 1
self_binary_name: .asciz "asm.exe"
wm_version_stage: .asciz "version"
.p2align 3
self_stage_fd: .quad 10
wm_versions_fd: .quad 20
wm_candidate_fd: .quad 30
wm_candidate_dir_fd: .quad -1
wm_existing_dir_fd: .quad -1
wm_existing_fd: .quad -1
wm_candidate_stat: .space 144
wm_stat: .space 144
wm_hash: .space 65
wm_candidate_meta: .space 64
wm_launcher_meta: .space 24
    .long 0,6,0
    .space 28
'''
        driver = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern long check_publication(void);
static int mode,child_open=1,moved,published,closes,hashes,metadata;
int publication_same(const char*a,const char*b){return strcmp(a,b)==0;}
long publication_io(long n,long fd,void*buffer,long extra){
    if(n==258)return fd==10?0:-22;
    if(n==3){if(fd!=30||!child_open)abort();child_open=0;closes++;return mode==10?-5:0;}
    if(n!=5)abort();
    memset(buffer,0,144);uint64_t*s=buffer;uint32_t*w=buffer;
    s[0]=7;s[1]=(fd==40||fd==50)?100:200;s[2]=1;w[6]=(fd==40||fd==50)?0040700:0100700;w[7]=1;s[6]=4096;
    if(fd==50&&mode==1)s[1]=900; /* an existing valid digest directory */
    if(fd==60&&mode==1)s[1]=901;
    if(fd==50&&mode==2)s[1]++;
    if(fd==60&&mode==3)s[1]++;
    if(fd==60&&mode==6)s[2]=2;
    if(fd==60&&mode==7)w[7]=0;
    if(fd==60&&mode==8)w[6]|=0020;
    if(fd==50&&mode==9)w[6]|=0002;
    if(fd==50&&mode==14)w[6]=0100700;
    return 0;
}
long publication_open(long parent,const char*name,unsigned flags){
    if(parent==10&&!strcmp(name,"version"))return 40;
    if(parent==20&&!strcmp(name,"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")){
        if(child_open||(!published&&mode!=1))abort();return mode==13?-2:50;
    }
    if(parent==50&&!strcmp(name,"asm.exe")){
        if(!(flags&0x08000000))abort();return mode==12?-2:60;
    }
    abort();
}
long publication_rename(long source,long parent,const char*name,long no_replace){
    if(no_replace!=1)abort();
    if(source==30&&parent==40&&!strcmp(name,"asm.exe")){if(!child_open)abort();moved++;return 0;}
    if(source!=40||parent!=20||!moved)abort();
    /* Measured class65 behavior: an open descendant prevents this rename. */
    if(child_open)return -13;
    if(mode==1)return -17;
    if(mode==11)return -13;
    published++;return 0;
}
long publication_hash(long fd,long size,char*out){
    if(fd!=60||size!=4096)abort();hashes++;memset(out,mode==4?'b':'a',64);out[64]=0;return 0;
}
long publication_metadata(long fd,long size,uint32_t*out){
    if(fd!=60||size!=4096)abort();metadata++;memset(out,0,64);out[7]=6;out[8]=mode==15?2:1;out[10]=6;return mode==5?-22:0;
}
int main(int n,char**a){mode=atoi(a[1]);long r=check_publication();printf("%ld %d %d %d %d %d\n",r,closes,moved,published,hashes,metadata);}
'''
        cls.build('directory-publication', assembly, driver, ['check_publication'])

        assembly = macros + '\n.text\n' + block(managed, 'win_managed_open_slot', 'win_managed_startup')
        assembly += r'''
.text
.global check_snapshot_open
check_snapshot_open:
    mov r10d,edi
    mov edx,esi
    jmp win_managed_open_slot
win_open:
    mov [rip + open_flags],edx
    mov eax,30
    ret
win_managed_hold:
    mov eax,[rip + open_flags]
    ret
.data
open_flags: .long 0
'''
        cls.build('snapshot-open', assembly, '#include <stdio.h>\n#include <stdlib.h>\nextern long check_snapshot_open(int,int);\nint main(int n,char**a){printf("%ld\\n",check_snapshot_open(atoi(a[1]),atoi(a[2])));}\n', ['check_snapshot_open'])

    def test_directory_publication_closes_descendant_and_revalidates_destination(self):
        for mode, expected in [(0,'0 1 1 1 1 1'), (1,'0 1 1 0 1 1')]:
            with self.subTest(mode=mode):
                result = self.run_fixture('directory-publication', str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        for mode in range(2,16):
            with self.subTest(mode=mode):
                result = self.run_fixture('directory-publication', str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(result.stdout.split()[0], '0')

    def test_directory_snapshots_allow_publication_without_file_write_sharing(self):
        for directory, slot, expected in [(1,2,65536),(1,3,65536),(1,7,65536),(0,6,0x08000000),(0,8,0x0a000000)]:
            with self.subTest(directory=directory,slot=slot):
                result = self.run_fixture('snapshot-open', str(directory), str(slot))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(expected))

    @classmethod
    def build_startup_requirements(cls, macros, source):
        start = source.index('    lea rdi, [rip + wm_payload_meta]\n    mov rsi, [rip + wm_fields]\n')
        end = source.index('    cmp dword ptr [rip + wm_role], 1\n', start)
        decision = source[start:end]
        assembly = macros + '\n.text\n' + block(source, 'win_managed_metadata_record', 'win_managed_cleanup')
        assembly += r'''
.text
.global check_startup_requirements
check_startup_requirements:
    WFRAME
    cmp edi, 0
    je .Lrequirements_ready
    mov dword ptr [rip + wm_payload_meta + 40], 7
    cmp edi, 1
    jne 1f
    mov dword ptr [rip + wm_launcher_meta + 28], 8
    jmp .Lrequirements_ready
1:  lea rax, [rip + next_minimum]
    mov [rip + wm_fields + 40], rax
    cmp edi, 2
    je .Lrequirements_ready
    lea rax, [rip + wrong_version]
    mov [rip + wm_fields], rax
.Lrequirements_ready:
'''
        assembly += decision + '''    xor eax,eax
    WLEAVE
win_managed_error:
win_managed_compatibility_error:
    mov rax,-1
    WLEAVE
.data
wm_payload_meta: .quad 0,0,0
    .long 0,6,1,0,6,0
    .space 16
wm_launcher_meta: .quad 0,0,0
    .long 0,6,0,0,6,0
    .space 16
wm_fields: .quad good_version,0,0,0,0,good_minimum
good_version: .asciz "0.6.1"
wrong_version: .asciz "0.6.2"
good_minimum: .asciz "0.6.0"
next_minimum: .asciz "0.7.0"
'''
        cls.build('startup-requirements', assembly, '#include <stdio.h>\n#include <stdlib.h>\nextern long check_startup_requirements(int);\nint main(int n,char**a){printf("%ld\\n",check_startup_requirements(atoi(a[1])));}\n', ['check_startup_requirements'])

    @classmethod
    def build_lock_admission(cls, macros, source):
        assembly = macros + '\n.text\n' + block(source, 'win_lock', 'win_getdents')
        assembly += r'''
.text
.global check_lock_admission
check_lock_admission:
    WFRAME
    mov [rip + lock_case], edi
    mov edi,3
    mov esi,6
    call win_lock
    mov r12,rax
    cmp dword ptr [rip + lock_case],0
    je .Llock_expect_valid
    cmp dword ptr [rip + close_count],1
    jne .Llock_test_bad
    cmp dword ptr [rip + lock_calls],0
    jne .Llock_test_bad
    cmp qword ptr [rip + win_locks + 24],0
    jne .Llock_test_bad
    jmp .Llock_test_done
.Llock_expect_valid:
    cmp dword ptr [rip + close_count],0
    jne .Llock_test_bad
    cmp dword ptr [rip + lock_calls],1
    jne .Llock_test_bad
    cmp qword ptr [rip + win_locks + 24],77
    jne .Llock_test_bad
.Llock_test_done:
    mov rax,r12
    WLEAVE
.Llock_test_bad:
    /* Preserve the actual bad admission as a test result, not a crash. */
    mov eax,999
    WLEAVE
win_handle:
    mov eax,55
    ret
win_ntfs:
    xor eax,eax
    ret
GetFileInformationByHandle:
    mov dword ptr [rdx],16
    mov eax,1
    ret
win_nt_open:
    mov eax,77
    ret
win_duplicate:
    ud2
win_stat:
    cmp rdi,77
    jne .Llock_stat_bad
    mov qword ptr [rsi + 16],1
    mov dword ptr [rsi + 24],0x81c0
    mov dword ptr [rsi + 28],1
    mov eax,[rip + lock_case]
    cmp eax,1
    jne 1f
    mov qword ptr [rsi + 16],2
1:  cmp eax,2
    jne 2f
    or dword ptr [rsi + 24],18
2:  cmp eax,3
    jne 3f
    mov dword ptr [rsi + 28],2
3:  cmp eax,4
    jne 4f
    mov dword ptr [rsi + 24],0x41c0
4:  cmp eax,5
    je .Llock_stat_bad
    xor eax,eax
    ret
.Llock_stat_bad:
    mov rax,-13
    ret
LockFileEx:
    cmp rcx,77
    jne .Llock_stat_bad
    inc dword ptr [rip + lock_calls]
    mov eax,1
    ret
CloseHandle:
    cmp rcx,77
    jne .Llock_stat_bad
    inc dword ptr [rip + close_count]
    mov eax,1
    ret
.data
lock_case: .long 0
close_count: .long 0
lock_calls: .long 0
.p2align 3
win_locks: .space 2048
win_handles: .space 2048
win_lock_overlapped: .space 32
win_lock_name: .short 46,97,115,109,46,108,111,99,107,0
'''
        cls.build('lock-admission', assembly, '#include <stdio.h>\n#include <stdlib.h>\nextern long check_lock_admission(int);\nint main(int n,char**a){printf("%ld\\n",check_lock_admission(atoi(a[1])));}\n', ['check_lock_admission'])

    @classmethod
    def build_held_rename(cls, macros, platform_source):
        source = (LOCAL / 'versioned_update.s').read_text()
        assembly = macros + '\n.text\n' + block(source, 'win_managed_rename_fd', 'win_managed_same_fd')
        assembly += '\n.text\n' + block(platform_source, 'win_component_safe', 'win_prepare_verifier_environment')
        assembly += r'''
.text
.global check_held_rename
check_held_rename:
    mov [rip + rename_status], edi
    mov [rip + rename_mode], esi
    mov ecx, esi
    mov edi, 101
    mov esi, 202
    lea rdx, [rip + target_name]
    jmp win_managed_rename_fd
win_wide:
    xor eax, eax
1:  movzx ecx, byte ptr [rdi + rax]
    mov [rsi + rax*2], cx
    inc eax
    test ecx, ecx
    jnz 1b
    ret
NtSetInformationFile:
    cmp rcx, 101
    jne .Lheld_rename_bad
    cmp qword ptr [r8 + 8], 202
    jne .Lheld_rename_bad
    cmp dword ptr [r8 + 16], 22
    jne .Lheld_rename_bad
    cmp r9d, 42
    jne .Lheld_rename_bad
    cmp dword ptr [rsp + 40], 65
    jne .Lheld_rename_bad
    mov eax, 3
    sub eax, [rip + rename_mode]
    cmp [r8], eax
    jne .Lheld_rename_bad
    cmp word ptr [r8 + 20], 'c'
    jne .Lheld_rename_bad
    cmp word ptr [r8 + 40], 'v'
    jne .Lheld_rename_bad
    mov eax, [rip + rename_status]
    ret
.Lheld_rename_bad:
    ud2
win_nt_error:
    mov rax, -13
    ret
.data
rename_status: .long 0
rename_mode: .long 0
target_name: .asciz "current.tsv"
.p2align 3
win_rename_info: .space 8216
'''
        cls.build('held-rename', assembly, '#include <stdio.h>\n#include <stdlib.h>\nextern long check_held_rename(unsigned,int);\nint main(int n,char**a){printf("%ld\\n",check_held_rename(strtoul(a[1],0,0),atoi(a[2])));}\n', ['check_held_rename'])

    @classmethod
    def build_launcher(cls, macros, platform_source):
        assembly = macros + '\n' + (LOCAL / 'launcher.s').read_text()
        assembly += '\n.text\n' + block(platform_source, 'win_close_child_streams', 'win_explicit_environment')
        assembly += r'''
.text
.global check_launch
check_launch:
    WFRAME
    mov [rip + exit_code], edi
    mov [rip + fail_mode], esi
    call win_managed_launch
    mov r12, rax
    cmp dword ptr [rip + controls], 2
    jne bad_test
    cmp dword ptr [rip + fail_mode], 2
    je .Ltest_create_failed
    cmp dword ptr [rip + closes], 5
    jne bad_test
    cmp dword ptr [rip + waits], 1
    jne bad_test
    cmp dword ptr [rip + fail_mode], 1
    je .Ltest_mapping_failed
    cmp dword ptr [rip + resumes], 1
    jne bad_test
    cmp dword ptr [rip + terminates], 0
    jne bad_test
    jmp .Ltest_launch_done
.Ltest_mapping_failed:
    cmp dword ptr [rip + resumes], 0
    jne bad_test
    cmp dword ptr [rip + terminates], 1
    jne bad_test
    jmp .Ltest_launch_done
.Ltest_create_failed:
    cmp dword ptr [rip + closes], 3
    jne bad_test
    cmp dword ptr [rip + waits], 0
    jne bad_test
    cmp dword ptr [rip + resumes], 0
    jne bad_test
.Ltest_launch_done:
    mov rax, r12
    WLEAVE
bad_test:
    ud2
win_wide:
    cmp byte ptr [rdi], 'C'
    jne bad_test
    mov eax, 1
    ret
GetCommandLineW:
    lea rax, [rip + original_command]
    ret
win_inherit_duplicate:
    lea rax, [rdi + 100]
    ret
SetConsoleCtrlHandler:
    lea rax, [rip + win_managed_control]
    cmp rcx, rax
    jne bad_test
    inc dword ptr [rip + controls]
    mov eax, 1
    ret
InitializeProcThreadAttributeList:
    mov eax, 1
    ret
UpdateProcThreadAttribute:
    cmp r8d, 0x20002
    jne bad_test
    cmp qword ptr [r9], 110
    jne bad_test
    cmp qword ptr [r9 + 8], 111
    jne bad_test
    cmp qword ptr [r9 + 16], 112
    jne bad_test
    cmp qword ptr [rsp + 40], 24
    jne bad_test
    mov eax, 1
    ret
DeleteProcThreadAttributeList:
    ret
CreateProcessW:
    cmp qword ptr [rsp + 40], 1
    jne bad_test
    cmp qword ptr [rsp + 48], 0x80004
    jne bad_test
    cmp qword ptr [rsp + 56], 0
    jne bad_test
    cmp qword ptr [rsp + 64], 0
    jne bad_test
    xor ecx, ecx
    lea r8, [rip + original_command]
1:  mov ax, [r8 + rcx*2]
    cmp ax, [rdx + rcx*2]
    jne bad_test
    inc ecx
    test ax, ax
    jnz 1b
    mov rax, [rsp + 72]
    cmp dword ptr [rax + 60], 0x100
    jne bad_test
    cmp qword ptr [rax + 80], 110
    jne bad_test
    cmp qword ptr [rax + 88], 111
    jne bad_test
    cmp qword ptr [rax + 96], 112
    jne bad_test
    cmp dword ptr [rip + fail_mode], 2
    je 2f
    mov rax, [rsp + 80]
    mov qword ptr [rax], 800
    mov qword ptr [rax + 8], 801
    mov eax, 1
    ret
2:  xor eax, eax
    ret
win_handle:
    cmp rdi, 3
    jne bad_test
    mov eax, 77
    ret
win_child_image_matches:
    cmp rdi, 800
    jne bad_test
    cmp rsi, 77
    jne bad_test
    xor eax, eax
    cmp dword ptr [rip + fail_mode], 1
    jne 1f
    mov rax, -116
1:  ret
ResumeThread:
    cmp rcx, 801
    jne bad_test
    inc dword ptr [rip + resumes]
    mov eax, 1
    ret
WaitForSingleObject:
    cmp rcx, 800
    jne bad_test
    cmp edx, -1
    jne bad_test
    inc dword ptr [rip + waits]
    xor eax, eax
    ret
GetExitCodeProcess:
    cmp rcx, 800
    jne bad_test
    mov eax, [rip + exit_code]
    mov [rdx], eax
    mov eax, 1
    ret
TerminateProcess:
    cmp rcx, 800
    jne bad_test
    inc dword ptr [rip + terminates]
    mov eax, 1
    ret
CloseHandle:
    inc dword ptr [rip + closes]
    mov eax, 1
    ret
win_managed_error:
    mov eax, -1
    WLEAVE
.data
exit_code: .long 0
fail_mode: .long 0
closes: .long 0
waits: .long 0
resumes: .long 0
terminates: .long 0
controls: .long 0
original_command: .short 97,115,109,32,34,97,32,98,34,32,34,120,92,92,34,0
wm_launch_path: .asciz "/C:/payload.exe"
.p2align 3
wm_payload_fd: .quad 3
win_handles: .quad 10,11,12
win_process_handle: .quad 0
win_thread_handle: .quad 0
win_child_stdin: .quad 0
win_child_stdout: .quad 0
win_child_stderr: .quad 0
win_pipe_write: .quad 0
win_startup: .space 112
win_inherited_handles: .space 24
win_attribute_list: .space 1024
win_attribute_size: .quad 1024
win_process_info: .space 24
win_executable_wide: .space 8192
win_command_wide: .space 65534
'''
        cls.build('launcher', assembly, '#include <stdio.h>\n#include <stdlib.h>\nextern unsigned check_launch(unsigned,int);\nint main(int n,char**a){printf("%u\\n",check_launch(strtoul(a[1],0,0),atoi(a[2])));}\n', ['check_launch'])

    @classmethod
    def build_borrowed_hash(cls, macros, source):
        assembly = macros + '\n.text\n' + block(source, 'win_hash_fd', 'win_decompress')
        assembly += f'''
.text
.global check_hash
check_hash:
    jmp win_hash_fd
win_syscall:
    WFRAME
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rax
    call {cls.prefix}io
    WLEAVE
'''
        assembly += r'''
BCryptOpenAlgorithmProvider:
    mov qword ptr [rcx], 123
    xor eax, eax
    ret
BCryptGetProperty:
    mov dword ptr [r8], 128
    xor eax, eax
    ret
BCryptCreateHash:
    mov qword ptr [rdx], 456
    xor eax, eax
    ret
BCryptHashData:
    xor eax, eax
    ret
BCryptFinishHash:
    xor ecx, ecx
1:  mov byte ptr [rdx + rcx], 0x5a
    inc ecx
    cmp ecx, 32
    jb 1b
    xor eax, eax
    ret
BCryptDestroyHash:
BCryptCloseAlgorithmProvider:
    xor eax, eax
    ret
.data
win_hash_provider: .quad 0
win_hash_handle: .quad 0
win_hash_stat: .space 144
win_hash_object: .space 4096
win_hash_digest: .space 32
win_hash_buffer: .space 65536
win_sha256_name: .short 'S','H','A','2','5','6',0
win_object_length: .short 'O',0
registry_hex_digits: .ascii "0123456789abcdef"
'''
        driver = r'''
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern long check_hash(long,uint64_t,void*);
static int opens,closes,reads,fail;
long io(long n,long a,long b,long c){struct stat st;long r=-38;
if(n==2){opens++;return -1;}if(n==3){closes++;return close(a);}
if(n==0){reads++;if(fail&&reads==2)return -5;r=read(a,(void*)b,c>3?3:c);}if(n==8)r=lseek(a,b,c);
if(n==5){r=fstat(a,&st);if(!r){memset((void*)b,0,144);*(uint32_t*)(b+24)=0100000;*(uint64_t*)(b+48)=st.st_size;}}
return r;}
int main(int n,char**a){char out[65]={0};int fd=open(a[1],O_RDONLY);fail=atoi(a[3]);lseek(fd,7,0);long r=check_hash(fd,strtoll(a[2],0,0),out);printf("%ld %d %d %d %s\n",r,opens,closes,fcntl(fd,F_GETFD)>=0,r?"failed":out);close(fd);return 0;}
'''
        cls.build('hash', assembly, driver, ['check_hash'])

    @classmethod
    def build_cleanup(cls, macros, source):
        assembly = macros + '\n.text\n' + block(source, 'win_managed_cleanup', 'win_managed_home_error')
        assembly += r'''
.text
.global check_cleanup
check_cleanup:
    WFRAME
    call win_managed_cleanup
    call win_managed_cleanup
    mov eax, [rip + close_count]
    WLEAVE
win_syscall:
    cmp eax, 3
    jne 1f
    cmp rdi, 3
    jb 1f
    cmp rdi, 8
    ja 1f
    inc dword ptr [rip + close_count]
    xor eax, eax
    ret
1:  ud2
.data
wm_fds: .quad 3,-1,4,-1,5,6,-1,7,8
close_count: .long 0
'''
        cls.build('cleanup', assembly, '#include <stdio.h>\nextern int check_cleanup(void);\nint main(void){printf("%d\\n",check_cleanup());}\n', ['check_cleanup'])

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def record(self, value):
        path = self.directory / 'current.tsv'
        path.write_bytes(value)
        result = self.run_fixture('record', str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_record_exact_contract(self):
        record = b'# asm-cli-current-v1\n0.6.1\tx86_64-windows\t4096\t' + b'a'*64 + b'\t1\t0.6.0\n'
        self.assertEqual(self.record(record), '0')
        invalid = [record[:-1], record+b'\n', record.replace(b'4096',b'04096'), record.replace(b'4096',b'0'), record.replace(b'4096',b'67108865'), record.replace(b'0.6.1',b'00.6.1'), record.replace(b'a'*64,b'A'*64), record.replace(b'\t1\t',b'\t2\t'), record.replace(b'x86_64',b'aarch64'), record.replace(b'\n',b'\r\n'), record+b'\0', b'x'*257, b'']
        for candidate in invalid:
            with self.subTest(candidate=candidate):
                self.assertNotEqual(self.record(candidate), '0')

    def test_roles_use_the_executing_path(self):
        cases = [('/C:/elsewhere/asm.exe', 0), ('/C:/Users/Person/.local/bin/asm.exe', 1), ('/C:/Users/Person/.LOCAL/BIN/ASM.EXE', 1), ('/C:/Users/Person/.local/bin/.asm-cli/versions/'+'a'*64+'/asm.exe', 2), ('/C:/checkout/bin/asm.exe', 0)]
        for path, expected in cases:
            result = self.run_fixture('role', path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(expected))

    def test_metadata_is_unique_bounded_readonly_and_borrows_fd(self):
        data = fixture_pe(sections=((1, 0x1000, 512, 512), (64, 0x2000, 512, 1024)))
        data[368:376] = b'.asmmeta'
        data[1024:1088] = prep._layout.metadata_bytes('0.6.0')
        path = self.directory / 'metadata.exe'
        path.write_bytes(data)
        self.assertEqual(self.run_fixture('metadata', str(path)).stdout.strip(), '0 0 0 1')
        changes = [(368, b'.nothing'), (376, struct.pack('<I', 63)), (404, struct.pack('<I', 0xc0000040)), (1024, b'BADCLI1\0'), (1032, struct.pack('<I', 2)), (1087, b'\1'), (328, b'.asmmeta')]
        for offset, value in changes:
            changed = bytearray(data)
            changed[offset:offset+len(value)] = value
            path.write_bytes(changed)
            result = self.run_fixture('metadata', str(path))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '-22 0 0 1')

    def test_remote_mapping_uses_exact_process_file_and_status(self):
        for status, expected in [(0,0), (0xc0000001,-116), (0x103,-95), (0x80000002,-95), (0xc000000d,-95)]:
            result = self.run_fixture('remote', str(status))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(expected))

    def test_hash_rewinds_the_borrowed_fd_and_never_reopens_or_closes(self):
        path = self.directory / 'hash.bin'
        path.write_bytes(b'123456789')
        for size, fail, expected in [('9', '0', '0 0 0 1 '+'5a'*32), ('-1', '0', '0 0 0 1 '+'5a'*32), ('8', '0', '1 0 0 1 failed'), ('9', '1', '1 0 0 1 failed')]:
            result = self.run_fixture('hash', str(path), size, fail)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_cleanup_closes_each_owned_descriptor_once(self):
        result = self.run_fixture('cleanup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '6')

    def test_launcher_preserves_complete_status_argv_and_owned_handles(self):
        for status in [0, 17, 256, 259, 0xc000013a, 0xffffffff]:
            result = self.run_fixture('launcher', str(status), '0')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(status))
        for failure in ['1', '2']:
            result = self.run_fixture('launcher', '0', failure)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(0xffffffff))

    def test_activation_uses_borrowed_source_and_target_handles(self):
        for status, expected in [(0,0), (0xc0000022,-13)]:
            for mode in [0,1]:
                result = self.run_fixture('held-rename', str(status), str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_startup_rejects_record_minimum_and_launcher_incompatibility(self):
        for mode, expected in [(0,0), (1,-1), (2,-1), (3,-1)]:
            with self.subTest(mode=mode):
                result = self.run_fixture('startup-requirements', str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_lock_admission_checks_held_file_and_closes_refusals(self):
        for mode in range(6):
            with self.subTest(mode=mode):
                result = self.run_fixture('lock-admission', str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '0' if mode == 0 else '-13')

if __name__ == '__main__':
    unittest.main(verbosity=2)
