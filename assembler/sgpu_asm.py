#!/usr/bin/env python3
"""SciGPU M1 assembler: .gpuasm -> SGP1 binary (ISA-001 Appendix A/B subset).

Usage: python3 assembler/sgpu_asm.py input.gpuasm output.sgp1
"""
import re, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'models', 'isa'))
from scigpu_defs import OP, NAME_TO_OP, COND_NAMES, enc_vrr, enc_vri, enc_srr, \
    enc_sri, enc_mem, enc_br, enc_ctrl, enc_sys, enc_pcmp, enc_getid, write_sgp1

ARG_TYPES = {'PTR': 2, 'I32': 1, 'U32': 1, 'F32': 1}

def parse_args(spec):
    """'(a:PTR,b:PTR,c:PTR,n:I32)' -> [(name,type), ...]"""
    if not spec:
        return []
    out = []
    for tok in spec.split(','):
        name, ty = tok.strip().rsplit(':', 1)
        assert ty in ARG_TYPES, f'unknown arg type {ty}'
        out.append((name.strip(), ty))
    return out

MEM_RE = re.compile(r'^(LOCAL\s+)?s(\d+)\s*(?:\+\s*(?:(v)(\d+)\*(\d+)|(\d+|-?\d+)))?$')

class AsmError(Exception):
    pass

def assemble(text):
    lines = []
    for ln, raw in enumerate(text.splitlines(), 1):
        line = raw.split(';')[0].strip()
        if line:
            lines.append((ln, line))

    labels = {}
    kern_name = 'kernel'; args = []
    vgpr_count = sgpr_count = smem = None
    # ---- pass 0: directives + labels
    body = []
    for ln, line in lines:
        m = re.match(r'^\.reg\s+(.*)$', line)
        if m:
            for k, v in re.findall(r'(\w+)=(\d+)', m.group(1)):
                {'vgpr_count': 'vgpr_count', 'sgpr_count': 'sgpr_count'}.get(k)
                if k == 'vgpr_count': vgpr_count = int(v)
                elif k == 'sgpr_count': sgpr_count = int(v)
                elif k == 'smem': smem = int(v)
            continue
        m = re.match(r'^\.smem\s+(\d+)$', line)
        if m:
            smem = int(m.group(1)); continue
        m = re.match(r'^\.kern\s+(\w+)(?:\s+args=\((.*)\))?\s*$', line)
        if m:
            kern_name = m.group(1)
            args = parse_args(m.group(2) or '')
            continue
        m = re.match(r'^\.word\s+(0x[0-9a-fA-F]+|\d+)\s*$', line)
        if m:
            body.append((ln, line)); continue          # handled in encode pass
        if line.startswith('.'):
            raise AsmError(f'line {ln}: unknown directive {line}')
        m = re.match(r'^(\w+):\s*$', line)
        if m:
            labels[m.group(1)] = len(body)
            continue
        body.append((ln, line))

    def resolve(lbl, idx):
        if lbl not in labels:
            raise AsmError(f'line {ln}: undefined label {lbl}')
        return labels[lbl] - (idx + 1)

    words = []
    for idx, (ln, line) in enumerate(body):
        if line.startswith('.word'):
            words.append(int(line.split()[1], 0) & 0xFFFFFFFFFFFFFFFF)
            continue
        pred = 15                                   # PRED_NONE default (Rev1.3)
        parts = line.replace(',', ' , ').split()
        pm = re.fullmatch(r'\[p(\d+)\]', parts[-1])
        if pm:
            pv = int(pm.group(1))
            if pv == 15:
                raise AsmError(f'line {ln}: [p15] is the bypass encoding; '
                               f'omit the suffix for unpredicated')
            if not parts[0].startswith('V_') and not parts[0].startswith('VFCMP'):
                raise AsmError(f'line {ln}: predicate suffix on non-vector op')
            pred = pv
            parts = parts[:-1]
            line_ops = parts
        else:
            line_ops = None
        mnem = parts[0]
        base = mnem.split('.')[0]
        ops = [p for p in parts[1:] if p != ',']
        try:
            op = NAME_TO_OP.get(mnem) or NAME_TO_OP.get(base) or (
                NAME_TO_OP.get('VFCMP.' + '.'.join(mnem.split('.')[1:]) and None))
        except Exception:
            op = None
        if op is None:
            alt = 'VFCMP.' + mnem.split('.', 1)[1] if mnem.startswith('VFCMP') else None
            op = NAME_TO_OP.get(alt or mnem) or NAME_TO_OP.get(base)
        if op is None:
            raise AsmError(f'line {ln}: unknown mnemonic {mnem}')

        def reg(tok, cls='v'):
            m = re.fullmatch(r'[svp](\d+)', tok)
            if not m or tok[0] != cls:
                raise AsmError(f'line {ln}: expected {cls}-register, got {tok}')
            return int(m.group(1))

        def imm(tok):
            try:
                v = int(tok.lstrip('#'), 0)   # '#' tolerated (disasm output)
                return v
            except ValueError:
                raise AsmError(f'line {ln}: bad immediate {tok}')

        w = None
        if base in ('S_MOV',):
            w = enc_sri(op, reg(ops[0], 's'), 0, imm(ops[1]) & 0xFFFFFF) \
                if not ops[1].startswith('s') else enc_srr(op, reg(ops[0], 's'),
                                                           reg(ops[1], 's'))
        elif base in ('S_ADD','S_SUB','S_MUL','S_AND','S_OR','S_XOR',
                      'S_SHL','S_SHR','S_SAR','S_NOT'):
            two_op = len(ops) == 2 and base == 'S_NOT'
            if two_op:
                w = enc_srr(op, reg(ops[0],'s'), reg(ops[1],'s'), 0)
            elif ops[2].lstrip('-').isdigit():
                w = enc_sri(op, reg(ops[0],'s'), reg(ops[1],'s'),
                            imm(ops[2]) & 0xFFFFFF)
            else:
                w = enc_srr(op, reg(ops[0],'s'), reg(ops[1],'s'), reg(ops[2],'s'))
        elif base in ('S_CMP_EQ','S_CMP_LT','S_CMP_GT'):
            # SDST reserved per ISA-001 Rev1.2 §7 — encoded as zero
            w = enc_srr(op, 0, reg(ops[0], 's'), reg(ops[1], 's'))
        elif base == 'S_GETID':
            if ops[1] in COND_NAMES or ops[1] not in ('WG_X',) \
                    and not ops[1].isdigit():
                raise AsmError(f'line {ln}: unknown S_GETID selector {ops[1]}')
            sel = 0 if ops[1] == 'WG_X' else int(ops[1], 0)
            w = enc_getid(reg(ops[0], 's'), sel)
        elif base in ('S_BRA','S_BRA_COND','BRA_V','BRA'):
            disp = resolve(ops[-1], idx)
            cond = 0
            if base == 'S_BRA_COND':
                cname = ops[0]
                if cname not in COND_NAMES:
                    raise AsmError(f'line {ln}: unknown condition {cname}')
                cond = COND_NAMES[cname]
            w = enc_br(op, disp, cond=cond)
        elif base in ('V_MOV','V_BCAST'):
            if base == 'V_BCAST':
                w = enc_vrr(op, reg(ops[0]), reg(ops[1], 's'), pred=pred)
            else:
                w = enc_vrr(op, reg(ops[0]), reg(ops[1]), pred=pred)
        elif base in ('V_MOVI',):
            w = enc_vri(op, reg(ops[0]), 0, imm(ops[1]) & 0xFFFF, pred=pred)
        elif base == 'V_LLANE':
            w = enc_vrr(op, reg(ops[0]), 0, pred=pred)
        elif base in ('V_ADD','V_SUB','V_MUL','V_AND','V_OR','V_XOR','V_SHL','V_SHR',
                      'V_SAR','V_MIN','V_MAX'):
            srcs = [reg(p) if not p.lstrip('-').isdigit() else None for p in ops[1:]]
            if any(s is None for s in srcs):
                w = enc_vri(op, reg(ops[0]), srcs[0] or 0, imm(ops[2]) & 0xFFFF)
            else:
                w = enc_vrr(op, reg(ops[0]), *srcs, pred=pred)
        elif mnem in ('V_ADD.F32','V_SUB.F32','V_MUL.F32'):
            w = enc_vrr(op, reg(ops[0]), reg(ops[1]), reg(ops[2]), pred=pred)
        elif mnem == 'V_FMA.F32':
            w = enc_vrr(op, reg(ops[0]), reg(ops[1]), reg(ops[2]), reg(ops[3]), pred=pred)
        elif base == 'V_CVT':
            w = enc_vrr(op, reg(ops[0]), reg(ops[1]), pred=pred)
        elif base.startswith('VCMP') or base.startswith('VFCMP') \
                or base.startswith('V_CMP'):
            pdst = reg(ops[0], 'p')
            s1 = reg(ops[2]) if ops[2].startswith('v') else None
            if s1 is None:
                raise AsmError(f'line {ln}: M1 compares need two vector sources')
            w = enc_pcmp(op, pdst, reg(ops[1]), s1)
        elif mnem in ('V_LOAD.W','V_STORE.W','V_LOAD.LOCAL.W','V_STORE.LOCAL.W',
                      'S_LOAD.W','S_STORE.W','ATOM.ADD.U32'):
            mloc = MEM_RE.match(' '.join(ops[1:]))
            if not mloc:
                raise AsmError(f'line {ln}: bad memory operand {ops[1:]}')
            local, sb, isv, vi, stride, const = mloc.groups()
            data = reg(ops[0], 's') if base.startswith('S_') or base.startswith('ATOM') \
                else reg(ops[0])
            soff = int(const) if const else 0
            if isv:
                assert int(stride) == 4, 'M1 subset supports .W stride=4'
            size = 2                                     # SIZE=2 -> 4 bytes
            opc_map_ok = True
            w = enc_mem(op, data, int(sb), soff, scope=1 if local else 2,
                        order=0, size=size)
        elif base == 'BAR.WG':
            w = enc_sys(op)
        elif base == 'BAR':
            w = enc_sys(op)
        elif base == 'CBRANCH_IF':
            # normative M5 form: CBRANCH_IF pN, ELSE_LABEL, RECONV_LABEL
            if len(ops) != 3:
                raise AsmError(f'line {ln}: CBRANCH_IF requires '
                               f'pN, ELSE_LABEL, RECONV_LABEL')
            pdst = reg(ops[0], 'p')
            if pdst == 15:
                raise AsmError(f'line {ln}: CBRANCH_IF predicate must be '
                               f'P0..P14')
            else_disp = resolve(ops[1], idx)
            reconv_rel = labels.get(ops[2])
            if reconv_rel is None:
                raise AsmError(f'line {ln}: undefined label {ops[2]}')
            reconv_disp = reconv_rel - (idx + 1)
            if not -32768 <= reconv_disp <= 32767:
                raise AsmError(f'line {ln}: RECONV displacement '
                               f'{reconv_disp} exceeds BMOD16 range')
            w = enc_ctrl(op, else_disp, cond=pdst, bmod=reconv_disp)
        elif base == 'RECONV':
            w = enc_br(op, 0)
        elif base in ('PUSHM', 'POPM'):
            if ops:
                raise AsmError(f'line {ln}: {base} takes no operands')
            w = enc_br(op, 0)
        elif base in ('SETM', 'ANDM', 'ORM', 'XORM'):
            if len(ops) != 1:
                raise AsmError(f'line {ln}: {base} requires exactly one '
                               f'predicate operand pN')
            pv = reg(ops[0], 'p')
            if pv == 15:
                raise AsmError(f'line {ln}: {base} rejects p15 (ambiguous)')
            w = enc_ctrl(op, 0, cond=pv)
        elif base == 'LOOP_BEGIN':
            if len(ops) != 1:
                raise AsmError(f'line {ln}: LOOP_BEGIN requires LOOP_END_LABEL')
            disp = resolve(ops[0], idx)
            w = enc_ctrl(op, disp)
        elif base == 'LOOP_END':
            if len(ops) != 2:
                raise AsmError(f'line {ln}: LOOP_END requires pN, LOOP_HEAD')
            pv = reg(ops[0], 'p')
            disp = resolve(ops[1], idx)
            w = enc_ctrl(op, disp, cond=pv)
        elif base in ('BREAK', 'CONTINUE'):
            if len(ops) > 1:
                raise AsmError(f'line {ln}: {base} takes at most one '
                               f'predicate operand')
            cond = reg(ops[0], 'p') if ops else 15   # 15 = unconditional
            w = enc_ctrl(op, 0, cond=cond)
        elif base == 'RET_KERNEL_WF':
            w = enc_br(op, 0)
        elif base == 'NOP':
            w = enc_sys(OP.NOP)
        else:
            raise AsmError(f'line {ln}: unhandled mnemonic {mnem}')
        words.append(w & 0xFFFFFFFFFFFFFFFF)

    code = b''.join(w.to_bytes(8, 'little') for w in words)
    # ABI arg layout: PTR=2 SGPRs, I32=1 — packed little-endian at launch
    meta = bytearray()
    for name, ty in args:
        meta += b''
    path_holder = {}
    return dict(code=code, kern=kern_name, args=args, n_regs=(vgpr_count or 16,
                                                                sgpr_count or 32),
                smem=smem or 1024)

def emit_sgp1(asm_obj, out_path, features=0):
    import io, struct
    # build meta: arg descriptors {name_idx into inline string table, type code}
    types = {'PTR': 0, 'I32': 1, 'U32': 2, 'F32': 3}
    strtab = b'\x00'
    offs = {}
    meta = bytearray()
    for i, (name, ty) in enumerate(asm_obj['args']):
        offs[name] = len(strtab)
        strtab += name.encode() + b'\x00'
        meta += struct.pack('<II', offs[name], types[ty])
    buf = write_sgp1(out_path, features=features, code=asm_obj['code'],
                     meta=bytes(meta),
                     entry_name_idx=0,
                     vgpr_req=asm_obj['n_regs'][0], sgpr_req=asm_obj['n_regs'][1],
                     smem_req=asm_obj['smem'], arg_count=len(asm_obj['args']))
    return buf

def main():
    src, dst = sys.argv[1], sys.argv[2]
    asm = assemble(open(src).read())
    emit_sgp1(asm, dst)
    print(f'assembled {src} -> {dst} ({len(asm["code"])//8} instructions, '
          f'kernel {asm["kern"]}, args={len(asm["args"])})')

if __name__ == '__main__':
    main()
