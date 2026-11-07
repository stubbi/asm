#!/usr/bin/env python3
"""Actual held ARM64 PE metadata parser; host file adapters, not Windows.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse, hashlib, json, struct, tempfile
from pathlib import Path
import abi_test, pe_test
HERE=Path(__file__).resolve().parent

def main():
    p=argparse.ArgumentParser();p.add_argument('--artifact',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    data=a.artifact.read_bytes();pe=struct.unpack_from('<I',data,60)[0];n=struct.unpack_from('<H',data,pe+6)[0];table=pe+264
    meta=next(table+40*i for i in range(n) if data[table+40*i:table+40*i+8]==b'.asmmeta');raw=struct.unpack_from('<I',data,meta+20)[0]
    cases={'valid':(data,0)}
    def change(name,off,value):
        d=bytearray(data);d[off:off+len(value)]=value;cases[name]=(d,-22)
    change('wrong_magic',raw,b'X');change('unknown_schema',raw+8,struct.pack('<I',2));change('unknown_protocol',raw+12,struct.pack('<I',2));change('reserved_nonzero',raw+48,b'X');change('overflow_version',raw+24,struct.pack('<I',0x80000000));change('wrong_virtual_size',meta+8,struct.pack('<I',63));change('writable_metadata',meta+36,struct.pack('<I',0xc0000040));change('executable_metadata',meta+36,struct.pack('<I',0x60000040));change('missing_section',meta,b'.nothing');change('duplicate_section',table+40,b'.asmmeta')
    text=(HERE/'managed.s').read_text();helper=text[text.index('win_managed_pe:'):text.index('/* MANAGED_PE_END */')];validator=text[text.index('win_managed_metadata:'):text.index('.section .rdata,"dr"')]
    results={}
    with tempfile.TemporaryDirectory(prefix='asm-held-pe-') as tmp:
        for name,(content,want) in cases.items():
            path=Path(tmp)/(name+'.exe');path.write_bytes(content)
            src=pe_test.source_text(path,len(content),1)
            src=src.replace('    ARM_CALL validate_host_elf\n    cmp w9,#1',f'''    mov x1,#0
    mov x2,#0
    ARM_CALL arm_open
    mov x19,x9
    mov x0,x19
    ARM_IMM x1,{len(content)}
    ARM_ADDR x2,held_meta
    ARM_CALL win_managed_pe
    mov x20,x9
    mov x0,x19
    ARM_CALL arm_close
    mov x9,x20
    mov x10,#{want}
    cmp x9,x10''')
            # Extra callee-saved registers are owned by this test entrypoint.
            src=src.replace('    stp x29,x30,[sp,#-16]!\n    mov x29,sp\n    ARM_ADDR x0, pe_path','    stp x29,x30,[sp,#-32]!\n    mov x29,sp\n    stp x19,x20,[sp,#16]\n    ARM_ADDR x0, pe_path').replace('    ldp x29,x30,[sp],#16\n    ret','    ldp x19,x20,[sp,#16]\n    ldp x29,x30,[sp],#32\n    ret',1)
            src+='\n.text\n'+helper+validator+'\n.data\nheld_meta: .space 64\n'
            results[name]=abi_test.run_case(Path(tmp),name,src)
    out={'scope':'actual held ARM64 PE metadata parser, host adapters, not Windows authorization','artifact_sha256':hashlib.sha256(data).hexdigest(),'result':'pass' if all(v.get('exit_code')==0 for v in results.values()) else 'fail','cases':results};a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2));return out['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
