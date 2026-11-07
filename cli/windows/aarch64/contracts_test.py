#!/usr/bin/env python3
"""Host-execute production source-path and publication-target boundary bodies.
Controlled assembly stubs check dispatch; no Windows/PE validation is claimed.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import abi_test

HERE = Path(__file__).resolve().parent


def source_text():
    spec = importlib.util.spec_from_file_location('windows_arm64', abi_test.ROOT / 'tools/windows_arm64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    asm = module.prepare(abi_test.ROOT / 'cli/aarch64/asm.s')
    parts = [module.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc'),
             asm[asm.index('streq:'):asm.index('/* Input: x0 is a valid string.')],
             asm[asm.index('win_shared_valid_source:'):asm.index('cmd_build:')],
             abi_test.region(HERE / 'files.s', 'win_component_name:', '/* Extra Windows archive'),
             (HERE / 'files.s').read_text().split('win_valid_source:')[1],
             abi_test.region(HERE / 'pe.s', 'win_pub_validate_pe:', '.section .bss')]
    parts[4] = 'win_valid_source:' + parts[4]
    text = '\n.text\n'.join(parts) + '\n' + (HERE / 'contracts_shim.s').read_text()
    text = text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    text = text.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = source_text()
    begin = source.index('win_valid_source:')
    end = source.index('win_pub_validate_pe:', begin)
    mutations = {'source_policy_removed': source[:begin] + 'win_valid_source:\n    b win_shared_valid_source\n' + source[end:],
                 'foreign_elf_fallback': source.replace('    cbz w9, .Lwin_pub_foreign', '    cbz w9, pub_validate_elf', 1)}
    with tempfile.TemporaryDirectory(prefix='asm-arm64-contracts-') as temporary:
        results = {'current': abi_test.run_case(Path(temporary), 'current', source)}
        results.update({key: abi_test.run_case(Path(temporary), key, value) for key, value in mutations.items()})
    passed = results['current'].get('exit_code') == 0 and all(r.get('build_exit_code') == 0 and r.get('exit_code', 0) != 0 for k,r in results.items() if k != 'current')
    data = {'scope': 'host execution of actual source policy and target dispatch; Windows filesystem and PE container behavior untested',
            'result': 'pass' if passed else 'fail', 'cases': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + '\n')
    print(json.dumps(data, indent=2))
    return not passed


if __name__ == '__main__':
    raise SystemExit(main())
