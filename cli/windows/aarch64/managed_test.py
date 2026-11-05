#!/usr/bin/env python3
"""Execute managed ARM64 pure boundaries on Apple Silicon, not Windows.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse, hashlib, importlib.util, json, tempfile
from pathlib import Path
import abi_test
HERE=Path(__file__).resolve().parent

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--output',type=Path,required=True); args=ap.parse_args()
    spec=importlib.util.spec_from_file_location('arm',abi_test.ROOT/'tools/windows_arm64.py'); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    prefix=m.prepare(abi_test.ROOT/'cli/aarch64/platform.inc')+'\n.text\n'
    path=HERE/'managed.s'
    if path.exists():
        text=path.read_text(); prefix+=text[text.index('win_managed_parse_record:'):text.index('/* MANAGED_PURE_END */')]
    record=b'# asm-cli-current-v1\n0.6.0\taarch64-windows\t1234\t'+b'a'*64+b'\t1\t0.6.0\n'
    cases={'canonical':(record,0),'leading_zero':(record.replace(b'1234',b'01234'),-22),'extra_line':(record+b'\n',-22),'extra_field':(record[:-1]+b'\tx\n',-22),'nul':(record[:-1]+b'\0',-22),'crlf':(record.replace(b'\n',b'\r\n'),-22),'oversized':(b'x'*257,-22),'bad_target':(record.replace(b'aarch64-windows',b'x86_64-windows'),-22),'bad_digest':(record.replace(b'a'*64,b'A'*64),-22),'version_overflow':(record.replace(b'0.6.0',b'2147483648.6.0',1),-22),'truncated':(record[:-1],-22), 'zero_size':(record.replace(b'1234',b'0'),-22), 'excess_size':(record.replace(b'1234',b'67108865'),-22), 'maximum_values':(record.replace(b'0.6.0',b'2147483647.2147483647.2147483647').replace(b'1234',b'67108864'),0), 'version_leading_zero':(record.replace(b'0.6.0',b'00.6.0',1),-22), 'bom':(b'\xef\xbb\xbf'+record,-22), 'empty':(b'',-22)}
    results={}
    with tempfile.TemporaryDirectory(prefix='asm-arm64-managed-') as d:
        for name,(data,want) in cases.items():
            src=prefix+f'''\n.text
.global _main
_main:
    stp x29,x30,[sp,#-16]!
    mov x29,sp
    ARM_ADDR x0,input_record
    mov x1,#{len(data)}
    ARM_CALL win_managed_parse_record
    mov x10,#{want}
    cmp x9,x10
    cset w0,ne
    ldp x29,x30,[sp],#16
    ret
.data
input_record: .byte {','.join(map(str,data+bytes(1)))}
'''
            src=src.replace('.section .rdata,"dr"','.data').replace('.section .bss','.data').replace('adrp \\reg, \\symbol','adrp \\reg, (\\symbol)@PAGE').replace('add \\reg, \\reg, :lo12:\\symbol','add \\reg, \\reg, (\\symbol)@PAGEOFF')
            results[name]=abi_test.run_case(Path(d),name,src)
    out={'scope':'actual ARM64 managed parser; Apple Silicon host, not Windows runtime','result':'pass' if all(x.get('exit_code')==0 for x in results.values()) else 'fail','cases':results}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2));return out['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
