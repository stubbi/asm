"""Observable Intel Darwin port checks. Rosetta is reported separately from native Intel.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASM = ROOT / 'build/asm-x86_64-macos'


class IntelMacTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build = subprocess.run(['make', '-f', 'cli/macos/x86_64/Makefile', 'all'], cwd=ROOT,
                               capture_output=True, text=True, timeout=60)
        if build.returncode:
            raise AssertionError('Intel native build failed: ' + build.stdout + build.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'build')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()

    def cli(self, *args, cwd=None, code=0, env=None):
        result = subprocess.run([str(ASM), *map(str, args)], cwd=cwd or self.work,
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        return result

    def test_intel_identity_and_first_project(self):
        data = ASM.read_bytes()
        self.assertEqual(struct.unpack_from('<III', data), (0xfeedfacf, 0x1000007, 3))
        self.assertEqual(json.loads(self.cli('version', '--json').stdout)['host'], 'x86_64-macos')
        self.assertEqual(json.loads(self.cli('targets', '--json').stdout)['targets'], ['x86_64-macos'])
        self.cli('doctor')
        self.cli('new', 'hello world; touch NEVER')
        project = self.work / 'hello world; touch NEVER'
        self.assertIn('x86_64-macos', (project / 'asm.toml').read_text())
        self.assertEqual(self.cli('run', cwd=project).stdout, 'Hello from asm!\n')
        self.assertEqual(struct.unpack_from('<II', (project / 'build/app').read_bytes()),
                         (0xfeedfacf, 0x1000007))
        self.cli('test', cwd=project)
        self.assertFalse((self.work / 'NEVER').exists())
        self.cli('clean', cwd=project)
        self.assertFalse((project / 'build').exists())

    def test_bad_build_and_wrong_os_preserve_output(self):
        self.cli('new', 'hello')
        project = self.work / 'hello'
        self.cli('build', cwd=project)
        previous = (project / 'build/app').read_bytes()
        source = project / 'src/main.s'
        source.write_text('invalid assembly\n')
        self.cli('build', cwd=project, code=1)
        self.assertEqual((project / 'build/app').read_bytes(), previous)
        manifest = project / 'asm.toml'
        manifest.write_text(manifest.read_text().replace('x86_64-macos', 'x86_64-linux'))
        self.cli('build', cwd=project, code=2)
        self.assertEqual((project / 'build/app').read_bytes(), previous)
        self.assertEqual(list((project / 'build').glob('.asm-*')), [])
