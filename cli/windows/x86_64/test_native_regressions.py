#!/usr/bin/env python3
"""Execute affected x64 assembly with bounded host API shims, not native qualification.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
from pathlib import Path
import platform
import re
import shutil
import tempfile
import unittest

LOCAL = Path(__file__).resolve().parent
ROOT = LOCAL.parents[2]
spec = importlib.util.spec_from_file_location('x64_host_support', LOCAL / 'test_host_shims.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
block = support.block

# The API boundary supplies ASCII UTF16 fixture strings. Run the actual
# initialization/path/environment assembly; do not model its decisions here.
CONVERSION = r'''
win_utf8:
    xor eax, eax
1:  cmp rax, rdx
    jae 2f
    mov cl, [rdi + rax*2]
    mov [rsi + rax], cl
    inc rax
    test cl, cl
    jnz 1b
    ret
2:  mov rax, -22
    ret
'''


class NativeRegressions(unittest.TestCase):
    build = classmethod(support.HostShims.build.__func__)
    run_fixture = classmethod(support.HostShims.run_fixture.__func__)

    @classmethod
    def setUpClass(cls):
        cls.clang = shutil.which('clang')
        if not cls.clang or platform.system() not in {'Darwin', 'Linux'}:
            raise unittest.SkipTest('Host clang and x86-64 execution are required.')
        if platform.system() == 'Linux' and platform.machine() not in {'x86_64', 'AMD64'}:
            raise unittest.SkipTest('Linux host shims require native x86-64.')
        cls.temp = tempfile.TemporaryDirectory(prefix='asm-x64-native-regressions-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.prefix = '_' if platform.system() == 'Darwin' else ''
        cls.source = (LOCAL / 'platform.s').read_text()
        cls.prepared = support.prep.prepare(ROOT / 'cli/self_update_verify.s')
        constants = '\n'.join(re.findall(r'^\.equ WIN_.*$', cls.prepared, re.M))
        macros = cls.source[cls.source.index('.macro WFRAME\n'):cls.source.index('.text\n')]
        cls.macros = '.intel_syntax noprefix\n' + constants + '\n' + macros + '\n.text\n'
        cls.copy = block((ROOT / 'cli/asm.s').read_text(), 'copy_string', 'write_cstr')
        cls.build_initialize()
        cls.build_update_environment()

    @classmethod
    def build_initialize(cls):
        assembly = cls.macros + block(cls.source, 'win_initialize', 'win_error') + CONVERSION
        assembly += cls.copy
        data = cls.source[cls.source.index('.section .data\n', cls.source.index('win_fchdir:\n')):
                          cls.source.index('\n.text\n', cls.source.index('win_error_initialize:'))]
        assembly += data + r'''
.text
.global initialize_request
initialize_request:
    WFRAME
    mov [rip + wanted_count], edi
    mov [rip + failure_mode], esi
    lea rax, [rip + token]
    lea rdx, [rip + native_argv]
    mov ecx, 1025
1:  mov [rdx], rax
    add rdx, 8
    loop 1b
    call win_initialize
    mov [rip + result], rax
    test eax, eax
    jz 2f
    call win_initialization_error
2:  lea rax, [rip + result]
    WLEAVE
.global initialized_arguments
initialized_arguments:
    mov rax, [rip + argv]
    ret
GetCommandLineW:
    lea rax, [rip + token]
    ret
CommandLineToArgvW:
    cmp dword ptr [rip + failure_mode], 1
    je fail_api
    mov eax, [rip + wanted_count]
    mov [rdx], eax
    lea rax, [rip + native_argv]
    ret
LocalFree:
    inc qword ptr [rip + freed]
    ret
GetEnvironmentStringsW:
    cmp dword ptr [rip + failure_mode], 2
    je fail_api
    lea rax, [rip + empty_environment]
    ret
FreeEnvironmentStringsW:
    ret
GetEnvironmentVariableW:
    cmp dword ptr [rip + failure_mode], 3
    je fail_api
    mov rax, 0x005c003a0043
    mov [rdx], rax
    mov eax, 3
    ret
GetStdHandle:
    neg ecx
    mov eax, ecx
    ret
win_security_initialize:
    xor eax, eax
    cmp dword ptr [rip + failure_mode], 4
    sete al
    ret
fail_api:
    xor eax, eax
    ret
die:
    cmp qword ptr [rip + win_handles + 16], 12
    jne 1f
    movzx eax, byte ptr [rdi]
    test eax, eax
    jz 1f
    mov qword ptr [rip + error_reported], 1
1:  ret
.data
.p2align 3
result: .quad 0
freed: .quad 0
error_reported: .quad 0
wanted_count: .long 0
failure_mode: .long 0
argc: .quad 0
argv: .quad 0
envp: .quad 0
native_argv: .space 1025*8
token: .short 'l','i','t','e','r','a','l',' ','t','o','k','e','n',0
empty_environment: .short 0,0
'''
        driver = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern long *initialize_request(int,int);
extern const char **initialized_arguments(void);
int main(int n,char **a) {
 int count=atoi(a[1]),mode=atoi(a[2]); long *r=initialize_request(count,mode);int valid=0;
 if (!r[0]) { const char **v=initialized_arguments();valid=v&&v[count]==0;
  for(int i=0;i<count&&valid;i++)if(strcmp(v[i],"literal token"))valid=0; }
 printf("%ld %ld %ld %d\n",r[0],r[1],r[2],valid);
}
'''
        cls.build('initialize', assembly, driver, ['initialize_request', 'initialized_arguments'])

    @classmethod
    def build_update_environment(cls):
        update = (LOCAL / 'versioned_update.s').read_text()
        managed = (LOCAL / 'managed.s').read_text()
        prepare = block(cls.prepared, 'self_prepare_verifier', 'self_copy_proxy_environment')
        prepare = prepare[:prepare.index('.ifdef ASM_TRUSTED_DISTRIBUTION\n')]
        prepare += '    add rsp, 8\n    pop r12\n    pop rbx\n    ret\n'
        assembly = cls.macros + block(update, 'win_managed_open_installation', 'win_managed_recheck_entry')
        assembly += block(managed, 'win_managed_fd_path', 'win_managed_path_role')
        assembly += block(cls.source, 'win_normalize_path', 'win_program_absolute_path')
        assembly += block(cls.source, 'win_prepare_verifier_environment', 'win_valid_source')
        assembly += '\n.text\n' + prepare + cls.copy + CONVERSION + r'''
.text
.global prepare_update
prepare_update:
    WFRAME
    mov [rip + failure_mode], edi
    mov [rip + saved_frame], rbp
    call win_managed_open_installation
    call self_prepare_verifier
    xor eax, eax
    WLEAVE
.global update_environment
update_environment:
    lea rax, [rip + environments]
    mov rax, [rax + rdi*8]
    ret
.global update_observed
update_observed:
    lea rax, [rip + observed]
    ret
win_handle:
    lea rax, [rdi + 100]
    ret
win_image_matches:
win_managed_check_absolute_installation:
self_copy_proxy_environment:
    xor eax, eax
    ret
win_duplicate:
    lea rax, [rdi + 64]
    ret
win_syscall:
    cmp eax, 138
    jne 1f
    mov dword ptr [rsi], 0x5346544e
1:  cmp eax, 258
    jne 2f
    inc qword ptr [rip + observed + 8]
2:  xor eax, eax
    ret
GetFinalPathNameByHandleW:
    cmp rcx, 131
    jne self_io_error
    inc qword ptr [rip + observed]
    cmp dword ptr [rip + failure_mode], 1
    je 3f
    cmp dword ptr [rip + failure_mode], 2
    jne 1f
    mov eax, 4096
    ret
1:  lea r8, [rip + store_path]
    xor eax, eax
2:  mov cx, [r8 + rax*2]
    mov [rdx + rax*2], cx
    inc eax
    test cx, cx
    jnz 2b
    dec eax
    ret
3:  xor eax, eax
    ret
self_installation_error:
self_changed:
self_busy:
self_permissions_error:
self_filesystem_error:
self_io_error:
    mov rbp, [rip + saved_frame]
    mov rax, -700
    WLEAVE
.data
.p2align 3
saved_frame: .quad 0
failure_mode: .long 0
.p2align 3
observed: .quad 0,0
wm_role: .long 2
.p2align 3
wm_exec_fd: .quad 30
wm_store_fd: .quad 31
wm_bin_fd: .quad 32
wm_ids: .space 144
self_parent_fd: .quad -1
self_current_fd: .quad -1
self_file_mode: .long 0
self_filesystem_stat: .space 144
self_parent_stat: .space 144
self_current_stat: .space 144
self_parent_path: .space 4096
wm_final_wide: .space 8192
self_stage_fd: .quad 40
registry_temp_dir: .asciz ".asm-registry-42"
self_verifier_directory: .asciz "verifier"
self_verifier_suffix: .asciz "/verifier"
self_home_prefix: .asciz "HOME="
self_config_prefix: .asciz "GH_CONFIG_DIR="
self_cache_prefix: .asciz "XDG_CACHE_HOME="
self_xdg_prefix: .asciz "XDG_CONFIG_HOME="
self_home_environment: .space 8192
self_config_environment: .space 8192
self_cache_environment: .space 8192
self_xdg_environment: .space 8192
.p2align 3
environments: .quad self_home_environment,self_config_environment,self_cache_environment,self_xdg_environment,win_profile_environment,win_localappdata_environment
store_path: .short '\\','\\','?','\\','C',':','\\','h','o','m','e',' ','d','i','r','\\','.','l','o','c','a','l','\\','b','i','n','\\','.','a','s','m','-','c','l','i',0
'''
        driver = r'''
#include <stdio.h>
#include <stdlib.h>
extern long prepare_update(int);extern const char *update_environment(int);extern long *update_observed(void);
int main(int n,char**a){long r=prepare_update(atoi(a[1]));long *o=update_observed();
 printf("%ld %ld %ld\n",r,o[0],o[1]);if(!r)for(int i=0;i<6;i++)puts(update_environment(i));}
'''
        cls.build('update-environment', assembly, driver, ['prepare_update', 'update_environment', 'update_observed'])

    def test_initialize_accepts_every_argument_through_1023_and_terminates_array(self):
        for count in (1, 257, 512, 513, 1023):
            with self.subTest(count=count):
                result = self.run_fixture('initialize', str(count), '0')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '0 1 0 1')

    def test_initialize_refusals_have_stderr_and_release_native_arguments(self):
        for count, mode, frees in [(1024, 0, 1), (0, 0, 1), (1, 1, 0),
                                   (1, 2, 1), (1, 3, 1), (1, 4, 1)]:
            with self.subTest(count=count, mode=mode):
                result = self.run_fixture('initialize', str(count), str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f'1 {frees} 1 0')

    def test_managed_update_derives_all_six_private_verifier_paths_from_held_store(self):
        result = self.run_fixture('update-environment', '0')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], '0 1 1')
        suffix = 'C:/home dir/.local/bin/.asm-cli/.asm-registry-42/verifier'
        self.assertEqual(lines[1:], [prefix + suffix for prefix in
            ['HOME=', 'GH_CONFIG_DIR=', 'XDG_CACHE_HOME=', 'XDG_CONFIG_HOME=', 'USERPROFILE=', 'LOCALAPPDATA=']])

    def test_store_path_lookup_failure_refuses_before_verifier_directory_creation(self):
        for mode in (1, 2):
            with self.subTest(mode=mode):
                result = self.run_fixture('update-environment', str(mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '-700 1 0')


if __name__ == '__main__':
    unittest.main()
