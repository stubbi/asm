#!/usr/bin/env python3
"""Run actual ARM64 owner/DACL routines against controlled host API fixtures.
This exercises policy branches, not Windows authorization or NTFS semantics.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import json
from pathlib import Path
import abi_test

HERE = Path(__file__).resolve().parent


def source_text():
    import importlib.util
    spec = importlib.util.spec_from_file_location('windows_arm64', abi_test.ROOT / 'tools/windows_arm64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = (HERE / 'security.s').read_text()
    policy = source[source.index('win_sid_class:'):source.index('/* x0=owned opened file')]
    constants = source[source.index('.section .rdata'):]
    if 'win_token_elevation:' not in constants:
        constants += '\nwin_token_elevation: .space 4\n'
    text = module.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc') + '\n.text\n' + policy + '\n' + constants
    text += '\n' + (HERE / 'security_shim.s').read_text()
    text = text.replace('.section .rdata,"dr"', '.data').replace('.section .bss', '.data')
    text = text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    text = text.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    return text


def main():
    import tempfile
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='asm-arm64-policy-') as temporary:
        result = abi_test.run_case(Path(temporary), 'policy', source_text())
    evidence = {'scope': 'host execution of actual owner/DACL assembly with controlled API fixtures; not Windows qualification',
                'cases': ['elevated BA directory remains ancestor only', 'current owner', 'elevated BA file owner', 'ordinary BA ancestor', 'TrustedInstaller ancestor',
                          'qualified OWNER_RIGHTS', 'foreign OWNER_RIGHTS', 'add-subdirectory ancestor',
                          'write-data ancestor', 'foreign grant', 'inherit-only grant'],
                'result': 'pass' if result.get('exit_code') == 0 else 'fail', 'execution': result}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
    return evidence['result'] != 'pass'


if __name__ == '__main__':
    raise SystemExit(main())
