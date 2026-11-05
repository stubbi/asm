"""Observable selected-target build contracts; no foreign executable is run.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import tomllib
import unittest
from host import TARGET, IS_MACOS, MAC_ARCH

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / 'build/asm'
LINUX = {'x86_64-linux': 62, 'aarch64-linux': 183, 'riscv64-linux': 243}

class CrossBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asm-cross-', dir=ROOT / 'build')
        self.work = Path(self.temp.name)
        shutil.copytree(ROOT / 'examples/hello', self.work / 'hello', ignore=shutil.ignore_patterns('build', '.asm', 'asm.lock'))
        self.project = self.work / 'hello'

    def tearDown(self):
        self.temp.cleanup()

    def cli(self, *args, code=0, cwd=None, env=None):
        result = subprocess.run([str(ASM), *args], cwd=cwd or self.project, env=env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        return result

    def tool_available(self, target):
        if IS_MACOS:
            prefix = '/opt/homebrew' if MAC_ARCH == 'arm64' else '/usr/local'
            return Path(prefix + '/opt/llvm/bin/clang').exists() and Path(prefix + '/opt/lld/bin/ld.lld').exists()
        triple = target.replace('-linux', '-linux-gnu')
        return Path('/usr/bin/' + triple + '-as').exists() and Path('/usr/bin/' + triple + '-ld').exists()

    def test_no_run_builds_native_test_without_executing_it(self):
        report = json.loads(self.cli('test', '--no-run', '--json').stdout)
        self.assertEqual(report, {'ok': True, 'artifact': 'build/test', 'executed': False})
        self.assertTrue((self.project / 'build/test').is_file())

    def test_cross_execution_is_refused_before_build_changes(self):
        foreign = next(target for target in LINUX if target != TARGET)
        for command in ('run', 'test'):
            result = self.cli(command, '--target', foreign, code=2)
            self.assertIn('cannot execute', result.stderr)
            self.assertFalse((self.project / 'build').exists())

    def test_foreign_template_is_refused_before_writes(self):
        foreign = next(target for target in LINUX if target != TARGET)
        destination = self.work / 'new-project'
        self.cli('new', '--target', foreign, str(destination), code=2, cwd=self.work)
        self.assertFalse(destination.exists())

    def test_linux_target_builds_and_clean_keep_outputs_separate(self):
        available = [target for target in LINUX if target != TARGET and self.tool_available(target)]
        if not available:
            self.skipTest('Fixed cross assembler and linker are unavailable')
        self.cli('build')
        native = (self.project / 'build/app').read_bytes()
        for target in available:
            with self.subTest(target=target):
                relative = f'build/{target}/app'
                report = json.loads(self.cli('build', '--target', target, '--json').stdout)
                self.assertEqual(report, {'ok': True, 'artifact': relative})
                data = (self.project / relative).read_bytes()
                self.assertEqual(data[:5], b'\x7fELF\x02')
                self.assertEqual(struct.unpack_from('<H', data, 18)[0], LINUX[target])
                test = json.loads(self.cli('test', '--target', target, '--no-run', '--json').stdout)
                self.assertEqual(test, {'ok': True, 'artifact': f'build/{target}/test', 'executed': False})
                before = (self.project / relative).read_bytes()
                declaration = tomllib.loads((self.project / 'asm.toml').read_text())['target'][target]
                (self.project / declaration['source']).write_text('this is invalid assembly\n')
                result = subprocess.run([str(ASM), 'build', '--target', target], cwd=self.project, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.project / relative).read_bytes(), before)
                self.assertFalse(list((self.project / f'build/{target}').glob('.asm-stage-*')))
                self.cli('clean', '--target', target)
                self.assertFalse((self.project / relative).exists())
                self.assertEqual((self.project / 'build/app').read_bytes(), native)

    def test_cross_build_ignores_effective_ambient_tool_configuration(self):
        available = [target for target in LINUX if target != TARGET and self.tool_available(target)]
        if not available:
            self.skipTest('Fixed cross assembler and linker are unavailable')
        clean = {**os.environ}
        clean.pop('CCC_OVERRIDE_OPTIONS', None)
        clean.pop('GNUTARGET', None)
        tool_environment = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
        self.cli('build', env=clean)
        native = (self.project / 'build/app').read_bytes()
        declarations = tomllib.loads((self.project / 'asm.toml').read_text())['target']
        for target in available:
            with self.subTest(target=target):
                source = self.project / declarations[target]['source']
                object_path = self.work / (target + '.o')
                if IS_MACOS:
                    prefix = '/opt/homebrew' if MAC_ARCH == 'arm64' else '/usr/local'
                    assembler = prefix + '/opt/llvm/bin/clang'
                    assemble = [assembler, '--target=' + target, '-c', str(source)]
                    poison = {'CCC_OVERRIDE_OPTIONS': '+-###'}
                else:
                    triple = target.replace('-linux', '-linux-gnu')
                    assembler = '/usr/bin/' + triple + '-as'
                    assemble = [assembler, str(source)]
                    poison = {'GNUTARGET': 'asm-invalid-bfd-target'}
                control = subprocess.run([*assemble, '-o', str(object_path)], env=tool_environment,
                                         capture_output=True, text=True, timeout=20)
                self.assertEqual(control.returncode, 0, (control.stdout, control.stderr))
                self.assertTrue(object_path.is_file())
                rejected = self.work / (target + '.poisoned')
                if IS_MACOS:
                    # The clang override requests a dry run, so it creates no object.
                    probe = subprocess.run([*assemble, '-o', str(rejected)],
                                           env={**tool_environment, **poison},
                                           capture_output=True, text=True, timeout=20)
                    self.assertEqual(probe.returncode, 0, (probe.stdout, probe.stderr))
                    self.assertIn('CCC_OVERRIDE_OPTIONS', probe.stderr)
                    self.assertFalse(rejected.exists(), 'The clang override did not prevent assembly')
                else:
                    linker = '/usr/bin/' + triple + '-ld'
                    linked = self.work / (target + '.clean')
                    link = [linker, '-z', 'noexecstack', str(object_path)]
                    control = subprocess.run([*link, '-o', str(linked)], env=tool_environment,
                                             capture_output=True, text=True, timeout=20)
                    self.assertEqual(control.returncode, 0, (control.stdout, control.stderr))
                    self.assertTrue(linked.is_file())
                    # Reuse the same object to prove that GNUTARGET changes linker behavior.
                    probe = subprocess.run([*link, '-o', str(rejected)],
                                           env={**tool_environment, **poison},
                                           capture_output=True, text=True, timeout=20)
                    self.assertNotEqual(probe.returncode, 0, 'GNUTARGET did not affect the fixed linker')
                environment = {**clean, **poison}
                relative = f'build/{target}/app'
                report = json.loads(self.cli('build', '--target', target, '--json', env=environment).stdout)
                self.assertEqual(report, {'ok': True, 'artifact': relative})
                data = (self.project / relative).read_bytes()
                self.assertEqual(data[:5], b'\x7fELF\x02')
                self.assertEqual(struct.unpack_from('<H', data, 18)[0], LINUX[target])
                self.assertEqual((self.project / 'build/app').read_bytes(), native)
                source.write_text('this is invalid assembly\n')
                self.cli('build', '--target', target, code=1, env=environment)
                self.assertEqual((self.project / relative).read_bytes(), data)
                self.assertEqual((self.project / 'build/app').read_bytes(), native)
                self.assertFalse(list((self.project / f'build/{target}').glob('.asm-stage-*')))

    def test_missing_selected_target_is_not_replaced_by_host(self):
        foreign = next(target for target in LINUX if target != TARGET)
        manifest = self.project / 'asm.toml'
        manifest.write_text(f'[package]\nname="hello"\nversion="0.1.0"\n[target.{TARGET}]\nsource="src/main.s"\n')
        result = self.cli('build', '--target', foreign, code=2)
        self.assertIn('selected target', result.stderr)
        self.assertFalse((self.project / 'build').exists())

    def test_cross_native_library_requires_sysroot_before_changes(self):
        foreign = next(target for target in LINUX if target != TARGET)
        manifest = self.project / 'asm.toml'
        declaration = tomllib.loads(manifest.read_text())['target'][foreign]
        manifest.write_text(f'[package]\nname="hello"\nversion="0.1.0"\n[target.{foreign}]\nsource="{declaration["source"]}"\nlink="c"\nlibraries="c"\n')
        result = self.cli('build', '--target', foreign, code=2)
        self.assertIn('sysroot', result.stderr)
        self.assertFalse((self.project / 'build').exists())

    def test_unsupported_declared_build_target_fails_without_changes(self):
        for target in ('x86_64-macos', 'x86_64-windows', 'aarch64-windows'):
            if target == TARGET:
                continue
            with self.subTest(target=target):
                (self.project / 'asm.toml').write_text(f'[package]\nname="hello"\nversion="0.1.0"\n[target.{target}]\nsource="src/main.s"\n')
                result = self.cli('build', '--target', target, code=2)
                self.assertIn('build toolchain', result.stderr)
                self.assertFalse((self.project / 'build').exists())
