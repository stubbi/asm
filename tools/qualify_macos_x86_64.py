#!/usr/bin/env python3
"""Qualify exact-source Intel Darwin bytes; never publish or declare support.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import registry
import release
ROOT = Path(__file__).resolve().parents[1]


def run(arguments, *, cwd=ROOT, timeout=60):
    process = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if process.returncode:
        raise RuntimeError(json.dumps({'command': arguments, 'cwd': str(cwd), 'exit': process.returncode,
                                      'stdout': process.stdout[-65536:], 'stderr': process.stderr[-65536:]}))
    return process.stdout.strip()


def source_files(repository: Path, reference: str):
    """Read original committed blobs/modes without replacement or archive filters."""
    commit = release.resolve_commit(repository, reference)
    return commit, registry.git_files(repository, commit, '.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--commit', default='HEAD')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-rosetta', action='store_true', help='retain translated evidence; never mark native')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('qualification requires Darwin')
    translated = subprocess.run(['/usr/sbin/sysctl', '-in', 'sysctl.proc_translated'], capture_output=True, text=True).stdout.strip()
    native = platform.machine() == 'x86_64' and translated != '1'
    if not native and not args.allow_rosetta:
        parser.error('native Intel hardware is required; Rosetta results need --allow-rosetta and remain translated')
    commit, files = source_files(ROOT, args.commit)
    if run(['git', '--no-replace-objects', 'status', '--porcelain']):
        parser.error('qualification requires a clean source checkout')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    evidence = {'schema': 1, 'target': 'x86_64-macos', 'source_commit': commit,
                'isa': 'x86-64', 'os': 'macos', 'abi': 'Apple System V AMD64 LP64',
                'minimum_os': '15.0', 'additional_cpu_features': [],
                'execution': 'native' if native else 'rosetta',
                'host': {'machine': platform.machine(), 'macos': platform.mac_ver()[0],
                         'translated_process': translated or '0'},
                'tools': {'clang': run(['/usr/bin/clang', '--version']),
                          'sdk': run(['/usr/bin/xcrun', '--show-sdk-version']), 'python': platform.python_version()},
                'status': 'error', 'developer_id': 'not-run', 'notarization': 'not-run',
                'installer_release_integration': 'not-run'}
    try:
        with tempfile.TemporaryDirectory(prefix='intel-source-') as temporary:
            directory = Path(temporary)
            binaries = []
            checkouts = []
            for number in range(2):
                checkout = directory / str(number)
                release.materialize(files, checkout)
                evidence['stage'] = f'clean-build-{number + 1}'
                with (output / f'build-{number + 1}.log').open('w') as log:
                    process = subprocess.run(['make', '-f', 'cli/macos/x86_64/Makefile', 'all'], cwd=checkout,
                                             stdout=log, stderr=subprocess.STDOUT, timeout=120)
                if process.returncode:
                    raise RuntimeError(f'clean build {number + 1} failed; retain build-{number + 1}.log')
                checkouts.append(checkout)
                binaries.append((checkout / 'build/asm-x86_64-macos').read_bytes())
            if binaries[0] != binaries[1]:
                raise RuntimeError('two clean Intel builds produced different bytes')
            version = json.loads((checkouts[0] / 'cli/commands.json').read_text())['version']
            asset = f'asm-{version}-x86_64-macos'
            payload = output / asset
            payload.write_bytes(binaries[0]); payload.chmod(0o755)
            evidence.update(version=version, file=asset, bytes=len(binaries[0]),
                            sha256=hashlib.sha256(binaries[0]).hexdigest(), reproducible_builds=2)
            checkout = checkouts[0]
            alias = checkout / 'build/asm'
            alias.write_bytes(binaries[0]); alias.chmod(0o755)
            report = output / 'native-tests.json'
            evidence['stage'] = 'runtime-tests'
            with (output / 'native-tests.log').open('w') as log:
                process = subprocess.run([sys.executable, 'tools/test_macos_x86_64.py', '--report', str(report)],
                                         cwd=checkout, stdout=log, stderr=subprocess.STDOUT, timeout=900)
            if report.exists():
                evidence['runtime'] = json.loads(report.read_text())
            if process.returncode:
                raise RuntimeError('Intel native behavioral suite failed; retain native-tests.log')
            if (checkout / 'build/asm-x86_64-macos').read_bytes() != binaries[0]:
                raise RuntimeError('the artifact changed during qualification')
            run(['/usr/bin/codesign', '--verify', '--strict', str(payload)])
            identity = json.loads(run([str(payload), 'version', '--json']))
            if identity['host'] != 'x86_64-macos' or identity['version'] != version:
                raise RuntimeError('wrong native executable identity')
            evidence.update(stage='complete', status='pass', code_signature='ad-hoc',
                            support_claim='native-runtime-qualified' if native else 'translated-runtime-only')
    except Exception as error:
        evidence['error'] = str(error)
        raise
    finally:
        (output / 'native-intel-release.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))

if __name__ == '__main__':
    main()
