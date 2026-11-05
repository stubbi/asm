#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Assemble the handwritten engine and link pinned native platform services."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import tempfile
import zlib

from build_sdl import build, build_environment

ROOT = pathlib.Path(__file__).resolve().parents[1]


def check_destination(path, description):
    """Refuse an existing link or non-file; this check does not prevent races."""
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise SystemExit(f'The build {description} is not a regular file path. Choose another output path.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'build/asm-doom')
    parser.add_argument('--release', action='store_true', help='Require a clean commit and rebuild SDL in a private stage.')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('This build requires Apple Silicon macOS 15 or later.')
    args.output = args.output.absolute()
    evidence_output = args.output.parent / 'build-evidence.json'
    if args.output.name.casefold() == evidence_output.name.casefold():
        raise SystemExit('The executable and build evidence need different output paths.')
    check_destination(args.output, 'output')
    check_destination(evidence_output, 'evidence output')
    data = ROOT / 'assets/freedoom1.wad.zlib'
    metadata = json.loads((ROOT / 'assets/freedoom.json').read_text())
    compressed = data.read_bytes()
    if hashlib.sha256(compressed).hexdigest() != metadata['embedded_sha256']:
        raise SystemExit('Embedded Freedoom data does not match its recorded digest.')
    raw = zlib.decompress(compressed)
    if len(raw) != metadata['iwad_bytes'] or hashlib.sha256(raw).hexdigest() != metadata['iwad_sha256']:
        raise SystemExit('Expanded Freedoom data does not match its recorded digest.')
    repository = None
    commit = dirty = None
    git = ['/usr/bin/git', '--no-replace-objects']
    git_environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C', 'LANG': 'C',
                       'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                       'GIT_OPTIONAL_LOCKS': '0'}
    probe = subprocess.run([*git, 'rev-parse', '--show-toplevel'], cwd=ROOT,
                           capture_output=True, text=True, env=git_environment)
    if probe.returncode == 0:
        candidate = pathlib.Path(probe.stdout.strip()).resolve()
        if ROOT.resolve() == candidate / 'packages/doom':
            repository = candidate
            commit = subprocess.check_output([*git, 'rev-parse', 'HEAD'], cwd=repository, text=True, env=git_environment).strip()
            dirty = subprocess.check_output([*git, 'status', '--porcelain'], cwd=repository, text=True, env=git_environment)
    if args.release and repository is None:
        raise SystemExit('Release builds require the Asm Git checkout and its recorded commit.')
    if args.release and dirty:
        raise SystemExit('Release builds require a clean recorded Git commit.')
    sources = [ROOT / 'src' / name for name in
               ('main.s', 'clock.s', 'wad.s', 'textures.s', 'world.s', 'render.s', 'platform.s')]
    source_inputs = [*sources, *sorted((ROOT / 'src').glob('*.inc'))]
    source_bytes = {str(p.relative_to(ROOT)): p.read_bytes() for p in source_inputs}
    notice_paths = ('LICENSE', 'third_party/ENGINE-NOTICES.txt', 'third_party/COPYING.txt',
                    'third_party/CREDITS.txt', 'third_party/CREDITS-MUSIC.txt',
                    'third_party/sdl/LICENSE.txt', 'third_party/sdl/THIRD-PARTY-NOTICES.txt')
    notice_bytes = {p: (ROOT / p).read_bytes() for p in notice_paths}
    embedded_bytes = {**notice_bytes, 'assets/freedoom1.wad.zlib': compressed}
    if args.release:
        for relative, content in {**source_bytes, **embedded_bytes}.items():
            committed = subprocess.check_output([*git, 'show', f'{commit}:packages/doom/{relative}'], cwd=repository, env=git_environment)
            if content != committed:
                raise SystemExit(f'Release input differs from the recorded commit: {relative}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.doom-build-', dir=args.output.parent) as stage:
        stage = pathlib.Path(stage)
        environment = build_environment(stage / 'environment')
        destination = stage / 'asm-doom'
        for relative, content in {**source_bytes, **embedded_bytes}.items():
            path = stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        dependency = build(stage / 'sdl' if args.release else ROOT / 'build/sdl', environment=environment)
        library_bytes = pathlib.Path(dependency['library']).read_bytes()
        library_digest = hashlib.sha256(library_bytes).hexdigest()
        if library_digest != dependency['library_sha256']:
            raise SystemExit('The SDL library changed during build preparation.')
        library = stage / 'libSDL3.a'
        library.write_bytes(library_bytes)
        command = ['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=15.0',
                   '-isysroot', environment['SDKROOT'],
                   '-I', str(stage / 'src'), '-Wl,-no_uuid', '-o', str(destination),
                   *(str(stage / p) for p in source_bytes if p.endswith('.s')),
                   str(library), '-lz', *dependency['link_args']]
        subprocess.run(command, cwd=stage, check=True, env=environment)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(destination)], check=True, env=environment)
        evidence = {'artifact_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                    'artifact_bytes': destination.stat().st_size,
                    'target': 'aarch64-macos', 'minimum_macos': '15.0',
                    'compiler': subprocess.check_output(['/usr/bin/clang', '--version'], text=True, env=environment).splitlines()[0],
                    'sdk': dependency['build']['sdk'],
                    'source_commit': commit, 'worktree_dirty': None if dirty is None else bool(dirty),
                    'release_build': args.release,
                    'sources': {p: hashlib.sha256(content).hexdigest() for p, content in source_bytes.items()},
                    'notices': {p: hashlib.sha256(content).hexdigest() for p, content in notice_bytes.items()},
                    'freedoom': metadata, 'sdl': dependency,
                    'engine_origin': 'handwritten AArch64 assembly; no generated engine assembly or C engine objects'}
        staged_evidence = stage / 'build-evidence.json'
        staged_evidence.write_text(json.dumps(evidence, indent=2) + '\n')
        if args.release and (subprocess.check_output([*git, 'rev-parse', 'HEAD'], cwd=repository, text=True, env=git_environment).strip() != commit
                             or subprocess.check_output([*git, 'status', '--porcelain'], cwd=repository, text=True, env=git_environment)):
            raise SystemExit('The Git checkout changed during the release build.')
        check_destination(args.output, 'output')
        check_destination(evidence_output, 'evidence output')
        # Each rename is atomic. The pair is sequential, with no unsafe rollback.
        # A failure after the first rename can leave new bytes with old evidence.
        os.replace(destination, args.output)
        try:
            os.replace(staged_evidence, evidence_output)
        except OSError as error:
            raise SystemExit(f'The executable was replaced, but its build evidence was not published: {error}. '
                             'Rebuild both output files.') from error


if __name__ == '__main__':
    main()
