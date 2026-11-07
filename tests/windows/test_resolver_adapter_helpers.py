"""Check resolver fixture adaptation; these are not native Windows results.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ast
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('windows_resolver_adapter',
    ROOT / 'tests/windows/test_resolver_runtime.py')
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


def shared_source():
    path = ROOT / 'tests/test_resolver_cli.py'
    if path.is_file():
        return path.read_bytes()
    # Development-only test input. The native adapter has no Git fallback.
    return subprocess.check_output(['git', 'show', '66f432b:tests/test_resolver_cli.py'], cwd=ROOT)


class ResolverAdapterHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = shared_source()
        tree = ast.parse(cls.source)
        cls.names = sorted(node.name for item in tree.body if isinstance(item, ast.ClassDef)
                           for node in item.body if isinstance(node, ast.FunctionDef)
                           and node.name.startswith('test_'))

    def load(self, target):
        return adapter.load_shared_resolver(self.source, ROOT / 'tests/test_resolver_cli.py', target)

    def test_private_target_context_preserves_all_shared_test_methods(self):
        original_host = sys.modules.get('host')
        original_path = list(sys.path)
        for target, arm in [('x86_64-windows', False), ('aarch64-windows', True)]:
            with self.subTest(target=target):
                module = self.load(target)
                self.assertEqual(module.TARGET, target)
                self.assertEqual(module.IS_ARM64, arm)
                self.assertFalse(module.IS_MACOS)
                self.assertFalse(module.IS_RISCV64)
                self.assertEqual(module.manifest('alpha').split('target = ')[1].splitlines()[0],
                                 '"' + target + '"')
                names = unittest.defaultTestLoader.getTestCaseNames(module.ResolverCliTests)
                self.assertEqual(names, self.names)
                self.assertEqual(len(names), 33)
                self.assertEqual(module.ADAPTER_PROFILE['shared_source_sha256'],
                                 hashlib.sha256(self.source).hexdigest())
        self.assertIs(sys.modules.get('host'), original_host)
        self.assertEqual(sys.path, original_path)

    def test_only_four_executable_literals_change_and_loader_has_no_duplicates(self):
        module = self.load('x86_64-windows')
        self.assertEqual(module.ADAPTER_PROFILE['executable_path_literals'], 4)
        runtime = types.SimpleNamespace(TARGET='x86_64-windows')
        standalone, managed = adapter.runtime_classes(module, runtime)
        self.assertEqual(unittest.defaultTestLoader.loadTestsFromTestCase(standalone).countTestCases(), 33)
        self.assertEqual(unittest.defaultTestLoader.loadTestsFromTestCase(managed).countTestCases(), 1)
        for name in self.names:
            self.assertIs(getattr(standalone, name), getattr(module.ResolverCliTests, name))
            self.assertNotIn('build/app', getattr(standalone, name).__code__.co_consts)
        name = 'test_transitive_graph_builds_and_runs_from_the_exact_offline_lock'
        self.assertIs(getattr(managed, name), getattr(module.ResolverCliTests, name))

    def test_windows_index_writer_keeps_exact_lf_bytes_and_arguments(self):
        module = self.load('aarch64-windows')
        standalone, _ = adapter.runtime_classes(module, types.SimpleNamespace(TARGET=module.TARGET))
        with tempfile.TemporaryDirectory() as temporary:
            case = standalone('test_dependency_cycle_fails_without_changing_the_manifest')
            case.index = Path(temporary) / 'index.tsv'
            case.rows = ['one\ttwo\n', 'three\tfour\n']
            observed = []
            case.cli = lambda *args, **kwargs: observed.append((args, kwargs))
            case.artifacts = Path(temporary) / 'artifacts'
            case.resolve('--features', 'extra', code=1, timeout=30)
            self.assertEqual(case.index.read_bytes(), b'# asm-registry-v1\none\ttwo\nthree\tfour\n')
            self.assertEqual(observed[0][0], ('resolve', '--index', case.index, '--artifacts',
                                             case.artifacts, '--features', 'extra'))
            self.assertEqual(observed[0][1], {'code': 1, 'cwd': None, 'timeout': 30})

    def test_cli_adapter_forwards_target_binary_deadline_and_project_directory(self):
        seen = []
        class NativeBoundary:
            def cli(self, *args, **kwargs):
                seen.append((args, kwargs))
                return 'observed'
        module = self.load('x86_64-windows')
        runtime = types.SimpleNamespace(TARGET=module.TARGET, ASM=Path('C:/owned/standalone.exe'),
                                        WindowsRuntimeTests=NativeBoundary)
        standalone, _ = adapter.runtime_classes(module, runtime)
        case = standalone(self.names[0])
        case.project = Path('C:/owned/project')
        self.assertEqual(case.cli('resolve', code=1, timeout=60), 'observed')
        self.assertEqual(seen[-1], (('resolve',), {'cwd': case.project, 'binary': runtime.ASM,
                                                  'code': 1, 'timeout': 60}))
        case.binary = Path('C:/owned/home/.local/bin/asm.exe')
        case.cli('lock')
        self.assertEqual(seen[-1][1]['binary'], case.binary)

    def test_unknown_target_and_changed_adapter_boundaries_are_refused(self):
        with self.assertRaises(ValueError):
            adapter.load_shared_resolver(self.source, ROOT / 'tests/test_resolver_cli.py', 'riscv64-linux')
        for changed in (self.source.replace(b'from host import', b'from changed_host import'),
                        self.source.replace(b'build/app', b'build/changed', 1)):
            with self.subTest(changed=hashlib.sha256(changed).hexdigest()), self.assertRaises(ValueError):
                adapter.load_shared_resolver(changed, ROOT / 'tests/test_resolver_cli.py', 'x86_64-windows')

    def test_consumer_sources_cross_assemble_for_both_windows_abis(self):
        clang = shutil.which('clang')
        self.assertIsNotNone(clang, 'The fixture build contract requires clang.')
        for target in ('x86_64-windows', 'aarch64-windows'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                dependency = root / f'stubbi/alpha/1.0.0/{target}/src/alpha.s'
                dependency.parent.mkdir(parents=True)
                body = ('mov x0, #7' if target == 'aarch64-windows' else 'mov eax, 7')
                syntax = '.intel_syntax noprefix\n' if target == 'x86_64-windows' else ''
                dependency.write_text(syntax + '.text\nasm_value_alpha:\n' + body + '\nret\n')
                source = root / 'consumer.s'
                source.write_text(adapter.consumer_source('alpha', '1.0.0', target))
                obj = root / 'consumer.obj'
                result = subprocess.run([clang, '--no-default-config',
                    '--target=' + target.removesuffix('-windows') + '-pc-windows-msvc',
                    '-c', source, '-o', obj], cwd=root, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreater(obj.stat().st_size, 0)
                self.assertNotIn('syscall', source.read_text())
                self.assertNotIn('svc #0', source.read_text())


if __name__ == '__main__':
    unittest.main()
