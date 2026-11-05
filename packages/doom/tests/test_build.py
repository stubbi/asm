# SPDX-License-Identifier: GPL-2.0-or-later
"""Source consumers can build without the platform repository or Git metadata."""
import importlib.util
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]


class BuildTests(unittest.TestCase):
    def test_checkout_commit_ignores_ambient_git_repository_and_configuration(self):
        with patch.object(sys, 'path', [str(ROOT / 'tools'), *sys.path]):
            spec = importlib.util.spec_from_file_location('doom_git_environment_test_module', ROOT / 'tools/build.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        git_environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C', 'LANG': 'C',
                           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                           'GIT_OPTIONAL_LOCKS': '0'}
        git = ['/usr/bin/git', '--no-replace-objects']
        probe = subprocess.run([*git, 'rev-parse', '--show-toplevel'], cwd=ROOT,
                               env=git_environment, capture_output=True, text=True, check=False)
        if probe.returncode or ROOT.resolve() != pathlib.Path(probe.stdout.strip()).resolve() / 'packages/doom':
            self.skipTest('Standalone package source has no Asm checkout commit to bind.')
        repository = pathlib.Path(probe.stdout.strip()).resolve()
        expected_commit = subprocess.check_output([*git, 'rev-parse', 'HEAD'], cwd=repository,
                                                  env=git_environment, text=True).strip()
        # Read the verified cache without invoking a dependency build or changing shared files.
        cached = ROOT / 'build/sdl'
        library = cached / 'static/libSDL3.a'
        self.assertTrue(library.is_file(), 'Build the package once before running build-evidence tests.')
        recorded = json.loads((cached / 'build-options.json').read_text())
        self.assertEqual(hashlib.sha256(library.read_bytes()).hexdigest(),recorded['library_sha256'])
        self.assertEqual(hashlib.sha256((ROOT / 'tools/build_sdl.py').read_bytes()).hexdigest(),
                         recorded['recipe_sha256'])
        dependency = sys.modules[module.build.__module__]
        sdl = {'version': dependency.VERSION, 'source': dependency.URL, 'source_sha256': dependency.SHA256,
               'library': str(library.resolve()), 'include': str((cached / f'SDL3-{dependency.VERSION}/include').resolve()),
               'library_sha256': recorded['library_sha256'], 'link_args': dependency.LINK_ARGS,
               'build': {name: value for name, value in recorded.items() if name != 'library_sha256'}}
        with tempfile.TemporaryDirectory(prefix='doom-build-git-environment-') as temporary:
            directory = pathlib.Path(temporary)
            foreign = directory / 'foreign-repository'
            subprocess.run([*git, 'init', '--quiet', str(foreign)], env=git_environment,
                           capture_output=True, check=True)
            foreign_configuration = directory / 'foreign.gitconfig'
            foreign_configuration.write_text(f'[core]\n\tworktree = {foreign}\n')
            destination = directory / 'output/asm-doom'
            poison = {'GIT_DIR': str(foreign / '.git'), 'GIT_WORK_TREE': str(foreign),
                      'GIT_CONFIG_GLOBAL': str(foreign_configuration), 'GIT_CONFIG_COUNT': '1',
                      'GIT_CONFIG_KEY_0': 'core.worktree', 'GIT_CONFIG_VALUE_0': str(foreign)}
            with patch.object(module, 'build', return_value=sdl), patch.dict(os.environ, poison), \
                    patch.object(sys, 'argv', ['build.py', '--output', str(destination)]):
                module.main()
            evidence = json.loads((destination.parent / 'build-evidence.json').read_text())
            self.assertEqual(evidence['source_commit'], expected_commit)
            self.assertIsInstance(evidence['worktree_dirty'],bool)
            self.assertGreater(destination.stat().st_size,10000000)

    def test_output_link_and_directory_are_rejected_before_build_tools(self):
        with patch.object(sys, 'path', [str(ROOT / 'tools'), *sys.path]):
            spec = importlib.util.spec_from_file_location('doom_output_test_module', ROOT / 'tools/build.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            unrelated = directory / 'unrelated'
            unrelated.write_bytes(b'preserve this file')
            link = directory / 'output-link'
            link.symlink_to(unrelated)
            for destination in (link, directory):
                with patch.object(module, 'build', side_effect=AssertionError('A build tool ran before output validation')), \
                        patch.object(sys, 'argv', ['build.py', '--output', str(destination)]), \
                        self.assertRaisesRegex(SystemExit, 'output'):
                    module.main()
            self.assertEqual(unrelated.read_bytes(), b'preserve this file')
            self.assertTrue(link.is_symlink())

    def test_standalone_source_links_real_engine_with_unknown_git_origin(self):
        with patch.object(sys, 'path', [str(ROOT / 'tools'), *sys.path]):
            spec = importlib.util.spec_from_file_location('doom_build_test_module', ROOT / 'tools/build.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        # Reuse the pinned, checked platform library. The engine and linker run normally.
        sdl = module.build(ROOT / 'build/sdl')
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary) / 'source'
            source.mkdir()
            for name in ('src', 'assets', 'third_party'):
                shutil.copytree(ROOT / name, source / name)
            shutil.copyfile(ROOT / 'LICENSE', source / 'LICENSE')
            with patch.object(module, 'ROOT', source), patch.object(module, 'build', return_value=sdl), \
                    patch.dict(os.environ, {'SDKROOT': '/invalid-sdk', 'DEVELOPER_DIR': '/invalid-tools',
                                            'CCC_OVERRIDE_OPTIONS': '+-invalid-clang-option',
                                            'CPATH': '/invalid-headers', 'LIBRARY_PATH': '/invalid-libraries'}), \
                    patch.object(sys, 'argv', ['build.py']):
                module.main()
            evidence = json.loads((source / 'build/build-evidence.json').read_text())
            self.assertIsNone(evidence['source_commit'])
            self.assertIsNone(evidence['worktree_dirty'])
            self.assertGreater((source / 'build/asm-doom').stat().st_size, 10000000)


if __name__ == '__main__':
    unittest.main()
