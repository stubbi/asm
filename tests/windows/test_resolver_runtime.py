"""Apply the shared resolver contract to real Windows assembly executables.

Only fixture context and executable paths differ. Resolution stays in assembly.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ast
import hashlib
import os
from pathlib import Path
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ('x86_64-windows', 'aarch64-windows')
HOST_NAMES = {'IS_ARM64', 'IS_RISCV64', 'IS_MACOS', 'OTHER_TARGET', 'TARGET', 'program'}
TRANSITIVE_CASE = 'test_transitive_graph_builds_and_runs_from_the_exact_offline_lock'


def windows_program(body, target):
    if target not in TARGETS:
        raise ValueError('The resolver fixture requires an exact Windows target.')
    syntax = '.intel_syntax noprefix\n' if target == 'x86_64-windows' else ''
    return syntax + '.text\n.global _start\n.extern ExitProcess\n_start:\n' + body + '\n'


def consumer_source(name, version, target):
    """Build the same value-seven consumer using the declared Windows ABI."""
    symbol = 'asm_value_' + name.replace('-', '_')
    if target == 'aarch64-windows':
        body = f'sub sp, sp, #32\nbl {symbol}\nsub x0, x0, #7\nbl ExitProcess'
    elif target == 'x86_64-windows':
        body = f'sub rsp, 40\ncall {symbol}\nmov ecx, eax\nsub ecx, 7\ncall ExitProcess'
    else:
        raise ValueError('The resolver consumer requires an exact Windows target.')
    return f'.include "stubbi/{name}/{version}/{target}/src/{name}.s"\n' + windows_program(body, target)


def load_shared_resolver(source, filename, target):
    """Load unchanged shared tests in a private Windows fixture namespace.

    Remove exactly one host-context import before defaults bind to TARGET.
    Rewrite only the four literal output paths. Unexpected shapes fail closed.
    No global host module or import path is replaced.
    """
    if target not in TARGETS or not isinstance(source, bytes) or len(source) > 131072:
        raise ValueError('Require bounded shared resolver source and an exact Windows target.')
    tree = ast.parse(source, filename=str(filename))
    imports = [node for node in tree.body if isinstance(node, ast.ImportFrom) and node.module == 'host']
    if (len(imports) != 1 or imports[0].level != 0
            or {name.name for name in imports[0].names} != HOST_NAMES
            or any(name.asname for name in imports[0].names)):
        raise ValueError('The shared resolver host import changed; review its Windows adapter.')
    tree.body.remove(imports[0])
    paths = [node for node in ast.walk(tree) if isinstance(node, ast.Constant) and node.value == 'build/app']
    if len(paths) != 4:
        raise ValueError('The shared resolver executable paths changed; review its Windows adapter.')
    for node in paths:
        node.value = 'build/app.exe'
    module = types.ModuleType('_asm_windows_shared_resolver')
    module.__file__ = str(filename)
    module.TARGET = target
    module.OTHER_TARGET = TARGETS[1] if target == TARGETS[0] else TARGETS[0]
    module.IS_ARM64 = target == 'aarch64-windows'
    module.IS_MACOS = module.IS_RISCV64 = False
    module.program = lambda body: windows_program(body, target)
    exec(compile(tree, str(filename), 'exec'), module.__dict__)
    methods = unittest.defaultTestLoader.getTestCaseNames(module.ResolverCliTests)
    if not methods or TRANSITIVE_CASE not in methods:
        raise ValueError('The shared resolver acceptance class is incomplete.')
    module.ADAPTER_PROFILE = {'shared_source_sha256': hashlib.sha256(source).hexdigest(),
                              'shared_source_bytes': len(source), 'target': target,
                              'executable_path_literals': len(paths),
                              'shared_test_methods': methods,
                              'standalone_cases': len(methods), 'managed_cases': 1,
                              'scope': 'shared resolver tests with Windows fixture context'}
    return module


def runtime_classes(shared, runtime):
    """Return the complete standalone contract and one installed-root flow."""
    class WindowsResolverRuntimeTests(shared.ResolverCliTests):
        managed = False

        def setUp(self):
            # This uses ordinary user TEMP, a private HOME, and the existing
            # native receipt path. It never writes to the real user profile.
            runtime.WindowsRuntimeTests.setUp(self)
            self.project = self.work / 'project with spaces'
            self.artifacts = self.work / 'artifact directory'
            self.artifacts.mkdir()
            self.rows = []
            if self.managed:
                from managed_helpers import source_install, selection
                source_install(self, runtime.ASM.read_bytes(), name='resolver-managed')
                self.binary = self.home / '.local/bin/asm.exe'
                self.managed_record = selection(self)[2]
            self.cli('new', self.project, cwd=self.work)

        def cli(self, *args, cwd=None, code=0, timeout=15):
            return runtime.WindowsRuntimeTests.cli(self, *args, cwd=cwd or self.project,
                binary=getattr(self, 'binary', runtime.ASM), code=code, timeout=timeout)

        def resolve(self, *args, code=0, cwd=None, timeout=15):
            # Registry framing is LF bytes on every host. Path.write_text on
            # Windows would otherwise translate this strict wire fixture.
            self.index.write_bytes(('# asm-registry-v1\n' + ''.join(self.rows)).encode('utf-8'))
            return self.cli('resolve', '--index', self.index, '--artifacts', self.artifacts,
                            *args, code=code, cwd=cwd, timeout=timeout)

        def consumer(self, name, version='1.0.0', *, project=None):
            (project or self.project).joinpath('src/main.s').write_text(
                consumer_source(name, version, runtime.TARGET), encoding='utf-8')

    class ManagedResolverRuntimeTests(unittest.TestCase):
        managed = True
        setUp = WindowsResolverRuntimeTests.setUp
        cli = WindowsResolverRuntimeTests.cli
        resolve = WindowsResolverRuntimeTests.resolve
        consumer = WindowsResolverRuntimeTests.consumer
        root_manifest = shared.ResolverCliTests.root_manifest
        package = shared.ResolverCliTests.package
        selections = shared.ResolverCliTests.selections

        def tearDown(self):
            from managed_helpers import selection
            self.assertEqual(self.binary.read_bytes(), runtime.ASM.read_bytes())
            self.assertEqual(selection(self)[2], self.managed_record)

    # Alias one actual shared test, avoiding another full set of installations.
    setattr(ManagedResolverRuntimeTests, TRANSITIVE_CASE, getattr(shared.ResolverCliTests, TRANSITIVE_CASE))
    WindowsResolverRuntimeTests.__qualname__ = 'WindowsResolverRuntimeTests'
    ManagedResolverRuntimeTests.__qualname__ = 'ManagedResolverRuntimeTests'
    return WindowsResolverRuntimeTests, ManagedResolverRuntimeTests


def load_tests(loader, tests, pattern):
    if os.name != 'nt' or not all(key in os.environ for key in ('ASM_WINDOWS_EXE', 'ASM_WINDOWS_TARGET')):
        raise RuntimeError('Run resolver acceptance through the native Windows runtime driver.')
    import test_runtime as runtime
    filename = ROOT / 'tests/test_resolver_cli.py'
    if not filename.is_file():
        raise RuntimeError('The shared resolver acceptance source is missing from this checkout.')
    source = filename.read_bytes()
    shared = load_shared_resolver(source, filename, runtime.TARGET)
    runtime.TEST_ARTIFACTS.append({'role': 'windows-shared-resolver-acceptance',
        **shared.ADAPTER_PROFILE,
        'adapter_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
    standalone, managed = runtime_classes(shared, runtime)
    return unittest.TestSuite([loader.loadTestsFromTestCase(standalone),
                               loader.loadTestsFromTestCase(managed)])


if __name__ == '__main__':
    unittest.main()
