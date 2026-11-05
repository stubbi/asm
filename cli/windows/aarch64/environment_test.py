#!/usr/bin/env python3
"""Execute the production private-verifier environment helper on Apple Silicon.
This tests bounded string preparation, not Windows child-process behavior.
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
    parts = [module.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc'),
             abi_test.region(abi_test.ROOT / 'cli/aarch64/asm.s', 'copy_string:', '/* Input: x0=file descriptor;'),
             abi_test.region(HERE / 'files.s', 'win_is_absolute:', '/* x0=validated C:/'),
             abi_test.region(HERE / 'files.s', 'win_slashes:', '/* x0=bounded UTF16'),
             (HERE / 'update.s').read_text().split('win_prepare_verifier_environment:')[1]]
    parts[-1] = 'win_prepare_verifier_environment:' + parts[-1]
    text = '\n.text\n'.join(parts) + r'''
.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ARM_CALL win_prepare_verifier_environment
    cbnz x9, 2f
    ARM_ADDR x0, win_profile_environment
    ARM_ADDR x1, expected_profile
    bl _strcmp
    cbnz w0, 2f
    ARM_ADDR x0, win_localappdata_environment
    ARM_ADDR x1, expected_local
    bl _strcmp
    cbnz w0, 2f
    ARM_ADDR x10, self_home_environment + 5
    mov w11, #47
    strb w11, [x10]
    ARM_CALL win_prepare_verifier_environment
    cmn x9, #22
    b.ne 2f
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret
2:  mov w0, #95
    b _exit
.data
self_home_environment: .asciz "HOME=C:\\private\\verifier"
    .space 8192
self_config_environment: .asciz "GH_CONFIG_DIR=C:/private/verifier"
    .space 8192
self_cache_environment: .asciz "XDG_CACHE_HOME=C:/private/verifier"
    .space 8192
self_xdg_environment: .asciz "XDG_CONFIG_HOME=C:/private/verifier"
    .space 8192
expected_profile: .asciz "USERPROFILE=C:/private/verifier"
expected_local: .asciz "LOCALAPPDATA=C:/private/verifier"
'''
    text = text.replace('.section .rdata,"dr"', '.data').replace('.section .bss', '.data')
    text = text.replace('adrp \\reg, \\symbol', 'adrp \\reg, (\\symbol)@PAGE')
    text = text.replace('add \\reg, \\reg, :lo12:\\symbol', 'add \\reg, \\reg, (\\symbol)@PAGEOFF')
    with tempfile.TemporaryDirectory(prefix='asm-arm64-environment-') as temporary:
        result = abi_test.run_case(Path(temporary), 'environment', text)
    evidence = {'scope': 'host execution of actual private verifier path preparation; not Windows qualification',
                'result': 'pass' if result.get('exit_code') == 0 else 'fail', 'execution': result}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
    return evidence['result'] != 'pass'


if __name__ == '__main__':
    raise SystemExit(main())
