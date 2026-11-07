#!/usr/bin/env python3
"""Host-execute the actual release metadata parser for Windows executable names.
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
    prefix = module.prepare(abi_test.ROOT / 'cli/aarch64/platform.inc') + '\n' + module.prepare(abi_test.ROOT / 'cli/aarch64/self_update_metadata.s')
    manifest = {'schema':1,'project':'asm','version':'0.6.1','tag':'v0.6.1',
                'repository':'https://github.com/stubbi/asm','source_commit':'a'*40,
                'assets':[{'file':'asm-0.6.1-aarch64-windows.exe','bytes':1234,'sha256':'a'*64}]}
    results = {}
    with tempfile.TemporaryDirectory(prefix='asm-arm64-metadata-') as temporary:
        for name, change in [('native',{}),('missing_exe',{'file':'asm-0.6.1-aarch64-windows'}),('wrong_size',{'bytes':1235}),('wrong_digest',{'sha256':'b'*64})]:
            value = json.loads(json.dumps(manifest))
            value['assets'][0].update(change)
            data = json.dumps(value).encode()
            body = f'''\n.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    ARM_ADDR x0,fixture_manifest
    ARM_IMM x1,{len(data)}
    ARM_ADDR x2,fixture_row
    ARM_CALL self_parse_release
    cmp w9,#{0 if name=='native' else 1}
    cset w0,ne
    ldp x29,x30,[sp],#16
    ret
.data
fixture_manifest: .byte {','.join(map(str,data))}
fixture_package: .asciz "stubbi/asm"
fixture_version: .asciz "0.6.1"
fixture_target: .asciz "aarch64-windows"
fixture_kind: .asciz "executable"
fixture_sha: .asciz "{'a'*64}"
fixture_url: .asciz "https://github.com/stubbi/asm/releases/download/v0.6.1/asm-0.6.1-aarch64-windows.exe"
fixture_size: .asciz "1234"
fixture_summary: .asciz "fixture"
.p2align 3
fixture_row: .quad fixture_package,fixture_version,fixture_target,fixture_kind,fixture_sha,fixture_url,fixture_size,fixture_summary
'''
            source = (prefix + body).replace('.section .rdata,"dr"','.data').replace('.section .bss','.data').replace('.section .text','.text')
            source = source.replace('adrp \\reg, \\symbol','adrp \\reg, (\\symbol)@PAGE').replace('add \\reg, \\reg, :lo12:\\symbol','add \\reg, \\reg, (\\symbol)@PAGEOFF')
            results[name] = abi_test.run_case(Path(temporary), name, source)
    evidence = {'scope':'actual metadata parser with controlled Windows asset bindings; no provenance authentication',
                'result':'pass' if all(r.get('exit_code')==0 for r in results.values()) else 'fail','cases':results}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(evidence,indent=2))
    return evidence['result']!='pass'


if __name__=='__main__':
    raise SystemExit(main())
