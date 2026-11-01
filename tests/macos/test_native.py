"""Black-box Darwin qualification; never run a Linux or translated executable."""
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASM = ROOT / 'build/asm'

@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'requires native Apple Silicon')
class NativeMacTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'build')
        self.work = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def cli(self, *args, cwd=None, code=0):
        result = subprocess.run([str(ASM), *map(str, args)], cwd=cwd or self.work,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        return result

    def test_native_identity(self):
        self.assertEqual(ASM.read_bytes()[:4], bytes.fromhex('cffaedfe'))
        self.assertEqual(json.loads(self.cli('version', '--json').stdout)['host'], 'aarch64-macos')
        self.assertIn('Usage:', self.cli('help').stdout)
        self.assertEqual(json.loads(self.cli('targets', '--json').stdout)['targets'], ['aarch64-macos'])
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(ASM)], check=True)

    def test_first_project(self):
        self.cli('doctor')
        project = self.work / 'hello world; touch NEVER'
        self.cli('new', project)
        self.assertIn('aarch64-macos', (project / 'asm.toml').read_text())
        self.assertEqual(self.cli('run', cwd=project).stdout, 'Hello from asm!\n')
        self.assertEqual((project / 'build/app').read_bytes()[:4], bytes.fromhex('cffaedfe'))
        self.cli('test', cwd=project)
        self.assertFalse((self.work / 'NEVER').exists())
        self.cli('clean', cwd=project)
        self.assertFalse((project / 'build').exists())

    def test_failed_build_preserves_output(self):
        self.cli('new', 'hello')
        project = self.work / 'hello'
        self.cli('build', cwd=project)
        previous = (project / 'build/app').read_bytes()
        (project / 'src/main.s').write_text('invalid assembly here\n')
        self.cli('build', cwd=project, code=1)
        self.assertEqual((project / 'build/app').read_bytes(), previous)
        self.assertEqual(list((project / 'build').glob('.asm-*')), [])

    def test_existing_project_and_wrong_os_preserve_files(self):
        self.cli('new', 'hello')
        project = self.work / 'hello'
        before = (project / 'asm.toml').read_bytes()
        self.cli('new', 'hello', code=1)
        self.assertEqual((project / 'asm.toml').read_bytes(), before)
        (project / 'asm.toml').write_text(before.decode().replace('aarch64-macos', 'aarch64-linux'))
        self.cli('build', cwd=project, code=2)
        self.assertFalse((project / 'build/app').exists())

    def test_perl_startup_configuration_cannot_bypass_digest(self):
        payload = self.work / 'payload'
        payload.write_bytes(b'tampered artifact')
        index = self.work / 'index.tsv'
        index.write_text('# asm-registry-v1\nstubbi/test\t0.1.0\taarch64-macos\texecutable\t'
                         + '0' * 64 + '\thttps://github.com/stubbi/asm/releases/download/v0.1.0/payload\t'
                         + str(payload.stat().st_size) + '\tUntrusted digest\n')
        (self.work / 'SkipHash.pm').write_text('BEGIN { exit 0; }\n1;\n')
        environment = dict(os.environ, PERL5LIB=str(self.work), PERL5OPT='-MSkipHash')
        result = subprocess.run([str(ASM), 'fetch', 'stubbi/test', '--kind', 'executable',
                                 '--index', str(index), '--artifact', str(payload), '--output', 'accepted'],
                                cwd=self.work, env=environment, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse((self.work / 'accepted').exists())
