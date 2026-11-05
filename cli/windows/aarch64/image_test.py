#!/usr/bin/env python3
"""Exercise the production class44 adapter with hostile API shims.
This proves argument/result handling; actual Windows mapped-image tests remain required.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import abi_test

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('windows_arm64', abi_test.ROOT / 'tools/windows_arm64.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    shim = (HERE / 'abi_shim.s').read_text()
    clobber = shim[shim.index('.macro API_CLOBBER'):shim.index('.endm')+6]
    production = (HERE / 'update.s').read_text().split('win_image_matches:')[1]
    source = module.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc') + '\n.text\n' + clobber + '\n'
    source += abi_test.region(HERE / 'platform.s', '.macro WIN_SAVE', '/* x0=Win32 error')
    source += '\nwin_image_matches:' + production + '\n' + (HERE / 'image_shim.s').read_text()
    source = source.replace('.section .rdata,"dr"', '.data')
    source = source.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    source = source.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    remote = source.replace('    mov x0,#0x4404\n    ARM_CALL win_image_matches', '    mov x0,#0x7707\n    mov x1,#0x4404\n    ARM_CALL win_child_image_matches').replace('ARM_IMM x11,0x4404\n    cmp x0,x11', 'ARM_IMM x11,0x7707\n    cmp x0,x11').replace('    cmn x0,#1\n    b.ne image_failed', '    ARM_IMM x10,0x7707\n    cmp x0,x10\n    b.ne image_failed')
    with tempfile.TemporaryDirectory(prefix='asm-arm64-image-') as temporary:
        result = abi_test.run_case(Path(temporary), 'image', source)
        remote_result = abi_test.run_case(Path(temporary), 'remote_image', remote)
    evidence = {'scope': 'host execution of actual class44 call boundary, not Windows image qualification',
                'cases': ['exact status0','mismatch C0000001','unsupported class','positive pending status','missing module','missing API'],
                'result': 'pass' if result.get('exit_code') == 0 and remote_result.get('exit_code') == 0 else 'fail', 'execution': result, 'remote_execution': remote_result}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
    return evidence['result'] != 'pass'


if __name__ == '__main__':
    raise SystemExit(main())
