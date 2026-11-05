#!/usr/bin/env python3
"""Exercise actual Windows assembly control flow with deterministic host shims.

These checks do not qualify Windows API behavior. Native Windows tests remain
required. The shims execute x86-64 assembly on macOS/Rosetta or Linux x86-64.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import importlib.util
import platform
import shutil
import struct
import subprocess
import tempfile
import unittest

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
        cls.macros = '.intel_syntax noprefix\n' + cls.platform_source[start:end] + '\n.text\n'
        cls.prefix = '_' if platform.system() == 'Darwin' else ''
        cls.build_pe()
        cls.build_path()
        cls.build_capture()
        cls.build_delete()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def build(cls, name, assembly, driver, exported):
        for symbol in exported:
            assembly = assembly.replace('.global ' + symbol + '\n', '.global ' + cls.prefix + symbol + '\n')
            assembly = assembly.replace('\n' + symbol + ':\n', '\n' + cls.prefix + symbol + ':\n')
        if cls.prefix:
            assembly = assembly.replace('.section .bss', '.data').replace('.section .rodata', '.data')
            assembly = assembly.replace('.section .rdata,"dr"', '.data')
        else:
            assembly += '\n.section .note.GNU-stack,"",@progbits\n'
        source = cls.directory / (name + '.s')
        source.write_text(assembly)
        csource = cls.directory / (name + '.c')
        csource.write_text(driver)
        command = [cls.clang, '-arch', 'x86_64'] if cls.prefix else [cls.clang, '-m64']
        subprocess.run(command + [str(source), str(csource), '-o', str(cls.directory / name)],
                       check=True, capture_output=True, text=True, timeout=30)

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
                 ((1,0x1000,4096,512),(1,0x2000,512,4608))]
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
