#!/usr/bin/env python3
"""Prepare native RV64 assembly from the reviewed assembly command sources.

This is a build tool. It translates assembly instructions before assembly and
never participates in CLI execution. No package operation is implemented here.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import argparse
import ast
import json
import re

ROOT = Path(__file__).resolve().parents[1]
REGISTERS = {**{f"x{i}": f"a{i}" for i in range(8)}, "x9": "t0",
             **{f"x{i}": f"t{i-9}" for i in range(10, 16)},
             "x16": "s6", "x17": "s7", **{f"x{i}": f"s{i-19}" for i in range(19,25)},
             "x30": "ra", "sp": "sp", "xzr": "zero", "wzr": "zero"}
REGISTERS.update({"w"+k[1:]:v for k,v in tuple(REGISTERS.items()) if k.startswith("x") and k[1:].isdigit()})


def register(value):
    value = value.strip()
    if value.startswith("\\"):
        return value
    if value not in REGISTERS:
        raise ValueError(f"unsupported source register {value}")
    return REGISTERS[value]


def width(value):
    return 32 if value.strip().startswith("w") else 64


def split_operands(value):
    result, start, depth, quote, escape = [], 0, 0, None, False
    for index, character in enumerate(value):
        if quote:
            if escape: escape=False
            elif character == "\\": escape=True
            elif character == quote: quote=None
        elif character in "\"'": quote=character
        elif character in "[({": depth+=1
        elif character in "])}": depth-=1
        elif character == "," and depth == 0:
            result.append(value[start:index].strip());start=index+1
    result.append(value[start:].strip())
    return result


def clean_instruction(line, block):
    output=[];i=0;quote=None;escape=False
    while i<len(line):
        if block:
            end=line.find("*/",i)
            if end<0:return "",True
            i=end+2;block=False;continue
        ch=line[i]
        if quote:
            output.append(ch)
            if escape:escape=False
            elif ch=="\\":escape=True
            elif ch==quote:quote=None
            i+=1;continue
        if ch in "\"'":quote=ch;output.append(ch);i+=1;continue
        if line.startswith("/*",i):block=True;i+=2;continue
        if line.startswith("//",i):break
        output.append(ch);i+=1
    return "".join(output).strip(),block


def materialize(value, target):
    value=value.strip()
    if value.startswith("#"):
        return [f"li {target}, {value[1:]}"]
    return [f"mv {target}, {register(value)}"]


def zext(reg, bits):
    return [f"RV_ZEXT {reg}"] if bits==32 and reg!="zero" else []


def address(value):
    match=re.fullmatch(r"\[(.*)\](!?)",value.strip())
    if not match:raise ValueError(f"unsupported address {value}")
    parts=split_operands(match[1]);base=register(parts[0]);out=[]
    if len(parts)==1:out.append(f"mv s8, {base}")
    elif parts[1].startswith("#"):
        out += materialize(parts[1],"s10") + [f"add s8, {base}, s10"]
    else:
        out += materialize(parts[1],"s10")
        if len(parts)>2:
            shift=re.fullmatch(r"lsl\s+#(\d+)",parts[2])
            if not shift:raise ValueError(f"unsupported index {value}")
            out.append(f"slli s10, s10, {shift[1]}")
        out.append(f"add s8, {base}, s10")
    if match[2]:out.append(f"mv {base}, s8")
    return out,base


def instruction(op, args, serial):
    a=split_operands(args) if args else []
    if op=="RV_ELF_FLAGS":
        return [f"andi s8, {register(a[0])}, -6", f"beqz s8, .Lrv_flags_ok_{serial}", f"RV_JUMP {a[1]}", f".Lrv_flags_ok_{serial}:"]
    if op=="ARM_ADDR":return [f"RV_ADDR {register(a[0])}, {a[1]}"]
    if op=="ARM_IMM":return [f"RV_IMM {register(a[0])}, {a[1]}, {width(a[0])}"]
    if op in ("ARM_SAVE","ARM_RESTORE","ARM_CALL_REG"):
        return [f"{op.replace('ARM_','RV_')} {register(a[0])}"]
    if op=="ARM_CALL":return [f"RV_CALL {a[0].replace('arm_','rv_',1)}"]
    if op in ("P_LOAD","P_STORE","P_BYTE"):
        return [f"{op} {register(a[0])}, {a[1]}"]
    if op in ("P_SET","NATIVE_ARG"):return [f"{op} {args}"]
    if op=="mov":return materialize(a[1],register(a[0]))+zext(register(a[0]),width(a[0]))
    if op in ("cmp","cmn","tst"):
        kind={"cmp":"sub","cmn":"add","tst":"and"}[op]
        return materialize(a[0],"s8")+materialize(a[1],"s10")+[f"RV_FLAGS {kind}, {width(a[0])}"]
    if op in ("adds","subs","ands"):
        kind={"adds":"add","subs":"sub","ands":"and"}[op]
        return materialize(a[1],"s8")+materialize(a[2],"s10")+[f"RV_FLAGS {kind}, {width(a[0])}",f"mv {register(a[0])}, s11"]
    if op in ("add","sub","and","orr","eor","mul"):
        kind={"orr":"or","eor":"xor"}.get(op,op)
        out=materialize(a[2],"s10")
        if len(a)>3:
            shift=re.fullmatch(r"lsl\s+#(\d+)",a[3])
            if not shift:raise ValueError(f"unsupported shifted operand {args}")
            out.append(f"slli s10, s10, {shift[1]}")
        out += [f"{kind} {register(a[0])}, {register(a[1])}, s10"]
        return out+zext(register(a[0]),width(a[0]))
    if op in ("lsl","lsr","lslv","lsrv"):
        dest,left=register(a[0]),register(a[1]);bits=width(a[0]);kind="sll" if op.startswith("lsl") else "srl"
        if a[2].startswith("#"):out=[f"{kind}i{'w' if bits==32 else ''} {dest}, {left}, {a[2][1:]}"]
        else:out=[f"{kind}{'w' if bits==32 else ''} {dest}, {left}, {register(a[2])}"]
        return out+zext(dest,bits)
    if op=="udiv":
        dest,left,right=map(register,a);bits=width(a[0]);out=[]
        if bits==32:
            out=[f"mv s8, {left}","RV_ZEXT s8",f"mv s10, {right}","RV_ZEXT s10"]
            left,right="s8","s10"
        return out+[f"beqz {right}, .Lrv_div_zero_{serial}",f"divu{'w' if bits==32 else ''} {dest}, {left}, {right}",
                f"j .Lrv_div_done_{serial}",f".Lrv_div_zero_{serial}:",f"li {dest}, 0",f".Lrv_div_done_{serial}:"]+zext(dest,bits)
    if op=="msub":
        return [f"mul s8, {register(a[1])}, {register(a[2])}",f"sub {register(a[0])}, {register(a[3])}, s8"]+zext(register(a[0]),width(a[0]))
    if op=="uxtb":return [f"andi {register(a[0])}, {register(a[1])}, 255"]
    if op=="sxtw":return [f"sext.w {register(a[0])}, {register(a[1])}"]
    if op=="bfi":
        dest,src=register(a[0]),register(a[1]);low,size=int(a[2].lstrip('#')),int(a[3].lstrip('#'))
        mask=(((1<<size)-1)<<low)&((1<<64)-1);signed=mask if mask<1<<63 else mask-(1<<64)
        return [f"li s10, {signed}",f"slli s11, {src}, {low}","and s11, s11, s10","not s10, s10",f"and {dest}, {dest}, s10",f"or {dest}, {dest}, s11"]+zext(dest,width(a[0]))
    if op.startswith("b."):return [f"RV_BCOND {op[2:]}, {args}"]
    if op in ("b","bl"):
        return [f"{'RV_JUMP' if op=='b' else 'call'} {args}"]
    if op=="br":return [f"jr {register(a[0])}"]
    if op=="ret":return ["ret"]
    if op=="brk":return ["ebreak"]
    if op in ("cbz","cbnz"):
        out=materialize(a[0],"s8")+zext("s8",width(a[0]))
        inverse="bnez" if op=="cbz" else "beqz"
        return out+[f"{inverse} s8, .Lrv_cb_skip_{serial}",f"RV_JUMP {a[1]}",f".Lrv_cb_skip_{serial}:"]
    if op in ("tbz","tbnz"):
        inverse="bnez" if op=="tbz" else "beqz"
        return [f"srli s8, {register(a[0])}, {a[1].lstrip('#')}","andi s8, s8, 1",f"{inverse} s8, .Lrv_tb_skip_{serial}",f"RV_JUMP {a[2]}",f".Lrv_tb_skip_{serial}:"]
    if op=="cset":
        dest=register(a[0])
        return [f"RV_BCOND {a[1]}, .Lrv_cset_true_{serial}",f"li {dest}, 0",f"j .Lrv_cset_done_{serial}",f".Lrv_cset_true_{serial}:",f"li {dest}, 1",f".Lrv_cset_done_{serial}:"]
    if op=="csel":
        dest=register(a[0]);bits=width(a[0])
        return [f"RV_BCOND {a[3]}, .Lrv_csel_true_{serial}",f"mv {dest}, {register(a[2])}",f"j .Lrv_csel_done_{serial}",f".Lrv_csel_true_{serial}:",f"mv {dest}, {register(a[1])}",f".Lrv_csel_done_{serial}:"]+zext(dest,bits)
    if op in ("ldr","ldrb","ldrh","str","strb","strh"):
        size={"ldrb":1,"strb":1,"ldrh":2,"strh":2}.get(op,4 if width(a[0])==32 else 8)
        out,base=address(a[1]);out.append(f"RV_{'LOAD' if op.startswith('ld') else 'STORE'} {register(a[0])}, {size}")
        if len(a)>2:out += materialize(a[2],"s10")+[f"add {base}, {base}, s10"]
        return out
    if op in ("ldp","stp"):
        out,base=address(a[2]);size=4 if width(a[0])==32 else 8
        kind="RV_LOAD" if op=="ldp" else "RV_STORE"
        out += [f"{kind} {register(a[0])}, {size}",f"addi s8, s8, {size}",f"{kind} {register(a[1])}, {size}"]
        if len(a)>3:out += materialize(a[3],"s10")+[f"add {base}, {base}, s10"]
        return out
    raise ValueError(f"unsupported instruction {op} {args}")


def prepare(source):
    source=Path(source);text=source.read_text();output=[];block=False
    if source.name=='asm.s':
        start=text.index('    ARM_ADDR x16, as_path',text.index('build_project:'))
        end=text.index('    ARM_ADDR x16, as_path\n    mov x0, x16',start)
        text=text[:start]+'    ARM_CALL rv_prepare_assembly\n'+text[end:]
        text=text.replace('as_arch: .asciz "-march=armv8-a"','as_arch: .asciz "-march=rv64i"')
    if source.name=='native_link.s':
        text=text.replace('    NATIVE_ARG native_cc_path','    NATIVE_ARG native_cc_path\n    NATIVE_ARG rv_cc_arch\n    NATIVE_ARG rv_cc_abi')
    if source.name=='elf.s':
        old='    ldr w10, [x16]\n    ARM_IMM w11, 0\n    cmp w10, w11\n    b.ne .Lelf_fail'
        # Only the e_flags sequence follows the ELF header offset48 load.
        start=text.index('    add x16, x16, #48')
        tail=text[start:]
        if old not in tail:raise ValueError('ELF flag validation boundary changed')
        tail=tail.replace(old,'    ldr w10, [x16]\n    RV_ELF_FLAGS w10, .Lelf_fail',1)
        text=text[:start]+tail
    output += ["/* SPDX-License-Identifier: AGPL-3.0-or-later", " * Copyright (c) 2026 ASM contributors",
               f" * Prepared from {source.relative_to(ROOT)} by tools/riscv64.py.",
               " * Runtime code is native RV64IM/LP64 assembly. Private ABI: platform.inc.",
               " * Do not hand-edit prepared instructions; edit the assembly source or preparation rule.", " */"]
    for number,line in enumerate(text.splitlines(),1):
        was_block=block
        code,block=clean_instruction(line,block)
        stripped=line.strip()
        if not code and (was_block or stripped.startswith(('/*','*','//'))):
            comment=line
            if stripped.startswith('//'):comment='/* '+stripped[2:].strip()+' */'
            comment=re.sub(r'\b(?:x|w)[0-9]+\b',lambda m:REGISTERS.get(m[0],m[0]),comment)
            comment=comment.replace('AArch64','RISC-V64').replace('ARM_CALL','RV_CALL').replace('ARMv8-A','RV64IM').replace('SVC','ECALL').replace('NZCV','s9 conditions')
            output.append(comment)
        code=code.replace('ARM_STAT_', 'RV_STAT_')
        if code.startswith('.section .note.GNU-stack'):
            code='.section .note.GNU-stack,""'
        if not code:continue
        # Source labels are unique within the single assembly translation unit.
        serial=re.sub(r'\W','_',source.stem)+str(number)
        if code.startswith('.include '):
            output.append(code.replace('cli/aarch64/','cli/riscv64/'));continue
        if code.endswith(':') or code.startswith('.'):
            if code.startswith('.arch '):continue
            code=code.replace('%progbits','@progbits').replace('ARM_STAT_','RV_STAT_')
            if code.startswith('.incbin '):code=code.replace('aarch64-linux','riscv64-linux')
            if '.asciz' in code or '.ascii' in code:
                if source.name in ('asm.s','self_update.s','self_update_metadata.s'):
                    code=code.replace('aarch64-unknown-linux-gnu','riscv64-unknown-linux-gnu').replace('aarch64-linux','riscv64-linux').replace('aarch64 assembly','riscv64 assembly')
                elif source.name=='registry.s' and not code.startswith('registry_aarch64:'):
                    if code.startswith('registry_host:') or 'requires aarch64-linux' in code or 'defaults to source and aarch64-linux' in code:
                        code=code.replace('aarch64-linux','riscv64-linux')
            output.append(code);continue
        if ':' in code.split()[0]:
            label,rest=code.split(':',1)
            if rest.strip().startswith('.'):
                data=label+':'+rest
                if source.name in ('asm.s','self_update.s','self_update_metadata.s'):
                    data=data.replace('aarch64-unknown-linux-gnu','riscv64-unknown-linux-gnu').replace('aarch64-linux','riscv64-linux').replace('aarch64 assembly','riscv64 assembly')
                elif source.name=='registry.s':
                    if label in ('registry_host', 'registry_err_install_target'):
                        data=data.replace('aarch64-linux','riscv64-linux')
                    elif label=='registry_err_elf':
                        data=data.replace('AArch64 ELF','RISC-V64 ELF')
                output.append(data.replace('ARM_STAT_','RV_STAT_'));continue
        parts=code.split(None,1);op=parts[0];args=parts[1] if len(parts)>1 else ''
        if source.name=='elf.s' and op=='ARM_IMM' and args.strip()=='w11, 183':args='w11, 243'
        try:out=instruction(op,args,serial)
        except ValueError as error:raise ValueError(f'{source}:{number}: {error}') from error
        output.extend('    '+item if not item.endswith(':') else item for item in out)
    if source.name=='asm.s':output.append('.include \"cli/riscv64/build.s\"')
    return '\n'.join(output)+'\n'


def prepare_templates(source):
    text=Path(source).read_text();parts=text.split('main_template:',1)
    prefix=parts[0].replace('aarch64-linux','riscv64-linux')
    main=parts[1].split('test_template:',1)[0]
    notice=[]
    for line in main.splitlines():
        if '.ascii' in line:notice.append(ast.literal_eval(line.split('.ascii',1)[1].strip()))
    header=''.join(notice).split('.arch armv8-a',1)[0]
    body=header+('.option norelax\n.section .rodata\n'
                 'message: .ascii "Hello from asm!\\n"\n.equ message_len, . - message\n'
                 '.global _start\n.section .text\n_start:\n'
                 '    li a0, 1\n    lla a1, message\n    li a2, message_len\n    li a7, 64\n    ecall\n'
                 '    li a0, 0\n    li a7, 93\n    ecall\n'
                 '.section .note.GNU-stack,"",@progbits\n')
    test=header+('.option norelax\n.global _start\n.section .text\n_start:\n'
                 '    li a0, 0\n    li a7, 93\n    ecall\n.section .note.GNU-stack,"",@progbits\n')
    return prefix+'main_template:\n    .asciz '+json.dumps(body)+'\ntest_template:\n    .asciz '+json.dumps(test)+'\n'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',type=Path,default=ROOT/'cli/riscv64')
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args();args.output_dir.mkdir(parents=True,exist_ok=True)
    for source in sorted((ROOT/'cli/aarch64').glob('*.s')):
        if source.name=='platform.s':continue
        text=prepare_templates(source) if source.name=='templates.s' else prepare(source)
        output=args.output_dir/source.name
        if args.check:
            if not output.exists() or output.read_text()!=text:raise SystemExit(f'prepared source differs: {output}')
        else:output.write_text(text)

if __name__=='__main__':main()
