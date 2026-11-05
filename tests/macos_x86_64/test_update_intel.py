"""Real Intel Darwin updater operations with transport/provenance-policy fixtures.
No fixture result claims genuine Sigstore verification or published Intel support.
"""
import importlib.util
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
os.environ['ASM_TEST_TARGET'] = 'x86_64-macos'
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tools'))
import test_self_update as common
import macos_x86_64
# Import under a distinct name so shared Linux helpers remain unambiguous.
spec = importlib.util.spec_from_file_location('darwin_update_contract', ROOT / 'tests/macos/test_self_update_macos.py')
darwin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(darwin)


class IntelSelfUpdateTests(darwin.MacSelfUpdateTests):
    @classmethod
    def setUpClass(cls):
        cls.suite_temp = tempfile.TemporaryDirectory(prefix='intel-self-', dir=ROOT / 'build')
        cls.fixture = Path(cls.suite_temp.name)
        cls.source = cls.fixture / 'source'
        cls.source.mkdir()
        transport = re.sub(r'with socket.socket.*?(?=if state.get\("hold"\))',
                           'assert "GH_TOKEN" not in os.environ or state.get("allow_ambient_transport")\n', common.TRANSPORT, flags=re.S)
        verifier = common.VERIFIER.replace('assert set(os.environ) <= allowed',
                    'allowed.add("__CF_USER_TEXT_ENCODING")\nassert set(os.environ) <= allowed')
        for name, body in [('curl-fixture', transport), ('gh-fixture', verifier)]:
            path = cls.fixture / name
            path.write_text(f'#!{sys.executable}\n' + body)
            path.chmod(0o755)
        cls.original_source = macos_x86_64.complete().replace(
            'registry_curl: .asciz "/usr/bin/curl"', f'registry_curl: .asciz "{cls.fixture}/curl-fixture"').replace(
            'self_gh_path: .asciz "/usr/local/bin/gh"', f'self_gh_path: .asciz "{cls.fixture}/gh-fixture"')
        cls.current_bytes = cls.compile_version(common.CURRENT)
        cls.next_bytes = cls.compile_version(common.NEXT)
        original = cls.original_source
        cls.original_source = original.replace('.equ SELF_VERIFIER_DEADLINE_SECONDS, 120',
                                               '.equ SELF_VERIFIER_DEADLINE_SECONDS, 1')
        cls.short_deadline_bytes = cls.compile_version(common.CURRENT)
        cls.original_source = original

    @classmethod
    def compile_version(cls, version):
        source = cls.source / 'asm.s'
        source.write_text(cls.original_source.replace(common.CURRENT, version))
        output = cls.source / 'asm'
        output.unlink(missing_ok=True)
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                        '-Wl,-no_uuid', '-Wl,-adhoc_codesign', '-o', str(output), str(source)],
                       check=True, capture_output=True, timeout=30)
        return output.read_bytes()

    def test_displaced_running_vnode_is_refused(self):
        # Stop after loading, before checking the current pathname. Replacing that
        # path must not authorize replacement of the unrelated new executable.
        stopped = self.original_source.replace('.Lglobals:\n', '''    mov eax, 39
    call mac_syscall
    mov rdi, rax
    mov esi, 17
    mov eax, 62
    call mac_syscall
.Lglobals:
''', 1)
        source = self.work / 'stopped.s'
        source.write_text(stopped)
        self.installed.unlink()
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                        '-Wl,-adhoc_codesign', '-o', str(self.installed), str(source)], check=True, capture_output=True)
        process = subprocess.Popen([str(self.installed), 'self', 'update'], cwd=self.work,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            _, status = os.waitpid(process.pid, os.WUNTRACED)
            self.assertTrue(os.WIFSTOPPED(status))
            displaced = self.installed.with_name('displaced')
            self.installed.rename(displaced)
            self.installed.write_bytes(self.current_bytes)
            self.installed.chmod(0o755)
            process.send_signal(signal.SIGCONT)
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 1, (stdout, stderr))
            self.assertEqual(self.installed.read_bytes(), self.current_bytes)
            self.assertEqual(self.calls(), [])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_native_update_never_executes_the_candidate(self):
        import hashlib
        marker = self.work / 'candidate-ran'
        source = self.work / 'candidate.s'
        source.write_text('''.intel_syntax noprefix
.global _main
.text
_main:
    push rbp
    mov rbp, rsp
    lea rdi, [rip + marker]
    mov esi, 384
    call _creat
    xor edi, edi
    call _exit
.data
marker: .asciz "''' + str(marker) + '"\n')
        binary = self.work / 'candidate'
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                        '-Wl,-adhoc_codesign', '-o', str(binary), str(source)], check=True)
        payload = binary.read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        (self.fixture / 'artifact').write_bytes(payload)
        self.record['assets'][0].update(bytes=len(payload), sha256=digest)
        self.write_index(self.row(digest=digest, size=len(payload)))
        self.save()
        self.cli('self', 'update')
        self.assertEqual(self.installed.read_bytes(), payload)
        self.assertFalse(marker.exists())
