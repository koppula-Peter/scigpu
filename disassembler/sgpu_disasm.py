#!/usr/bin/env python3
"""SciGPU disassembler: SGP1 -> human-readable listing.

M5: structured-control instructions round-trip bit-exactly
(assembly -> binary -> disassembly -> reassembly -> identical binary,
directive §105) via synthesized L_<index> labels.
"""
import sys, os, struct
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'models', 'isa'))
from scigpu_defs import (decode, MNEMONIC, read_sgp1, OP, COND_REV,
                         COND_CTRL_EXEC)

def _cc4(w):
    return (w >> 20) & 0xF

def _sext16(v):
    return v - 0x10000 if v & 0x8000 else v

def _targets(d, idx):
    """Return set of code-index targets referenced by a control word."""
    t = []
    if d.fmt != 5:
        return t
    if d.op in (OP.S_BRA, OP.BRA_V, OP.S_BRA_COND):
        t.append(idx + 1 + d.disp)
    elif d.op == OP.CBRANCH_IF:
        t.append(idx + 1 + d.disp)
        t.append(idx + 1 + _sext16(d.payload))
    elif d.op == OP.LOOP_BEGIN:
        t.append(idx + 1 + d.disp)
    elif d.op == OP.LOOP_END:
        t.append(idx + 1 + d.disp)
    return [x for x in t if x >= 0]

def disasm_line(w, idx, lbl):
    """One listing line using synthesized labels (empty string if none)."""
    try:
        d = decode(w)
    except ValueError:
        return f'.word 0x{w:016X}   ; bad FMT'
    m = MNEMONIC.get(d.op, f'OPC_{d.op:03X}')
    def L(i):
        s = lbl.get(i)
        return s if s else f'{i:+d}'
    if d.fmt == 5 and d.op in (OP.S_BRA, OP.BRA_V):
        return f'S_BRA {L(idx + 1 + d.disp)}'
    if d.fmt == 5 and d.op == OP.S_BRA_COND:
        cn = COND_REV.get(d.cond & 0xF)
        if cn is None or d.cond > 0xF:
            return f'.word 0x{w:016X}   ; reserved cond'
        return f'S_BRA_COND {cn}, {L(idx + 1 + d.disp)}'
    if d.fmt == 5 and d.op == OP.CBRANCH_IF:
        els = idx + 1 + d.disp
        rc = idx + 1 + _sext16(d.payload)
        c = _cc4(w)
        cs = '' if c == COND_CTRL_EXEC else f'p{c}, '
        return f'CBRANCH_IF {cs}{L(els)}, {L(rc)}'
    if d.fmt == 5 and d.op == OP.LOOP_BEGIN:
        return f'LOOP_BEGIN {L(idx + 1 + d.disp)}'
    if d.fmt == 5 and d.op == OP.LOOP_END:
        c = _cc4(w)
        cs = 'p15' if c == COND_CTRL_EXEC else f'p{c}'
        return f'LOOP_END {cs}, {L(idx + 1 + d.disp)}'
    if d.fmt == 5 and d.op in (OP.BREAK, OP.CONTINUE):
        c = _cc4(w)
        cs = '' if c == COND_CTRL_EXEC else f' p{c}'
        return f'{m}{cs}'
    if d.fmt == 5 and d.op in (OP.PUSHM, OP.POPM, OP.RECONV, OP.RET_KERNEL_WF):
        return m
    if d.fmt == 5 and d.op in (OP.SETM, OP.ANDM, OP.ORM, OP.XORM):
        return f'{m} p{_cc4(w)}'
    # ---- non-control families (unchanged formats) ----
    if d.fmt == 0:
        return f'{m} v{d.vd}, v{d.vs0}, v{d.vs1}, v{d.vs2}'.rstrip(', ')
    if d.fmt == 1:
        if d.op == OP.V_MOVI:
            return f'{m} v{d.vd}, #{d.imm}'
        return f'{m} v{d.vd}, v{d.vs0}, #{d.imm}'
    if d.fmt == 2:
        return f'{m} s{d.vd}, s{d.vs0}, s{d.vs1}'
    if d.fmt == 3:
        return f'{m} s{d.vd}, s{d.vs0}, #{d.imm}'
    if d.fmt == 4:
        scope = {0:'wf',1:'wg',2:'dev'}.get(d.scope,'?')
        return (f'{m} {"s" if m.startswith(("S_","ATOM")) else "v"}{d.vd}, '
                f's{d.saddr}{d.soff:+d} [{scope}]')
    if d.fmt == 9:
        return f'{m} p{d.pd}, v{d.vs0}, v{d.vs1}'
    if d.fmt == 6:
        return f'{m} payload=0x{d.payload:X}'
    return f'.word 0x{w:016X}'

def disasm_words(words):
    """Full-program listing with synthesized labels (round-trip exact)."""
    dec = []
    lbl = {}
    for i, w in enumerate(words):
        try:
            d = decode(w)
        except ValueError:
            d = None
        dec.append(d)
        if d:
            for t in _targets(d, i):
                lbl.setdefault(t, f'L_{t}')
    lines = []
    for i, w in enumerate(words):
        if i in lbl:
            lines.append(f'{lbl[i]}:')
        lines.append(disasm_line(w, i, lbl))
    return '\n'.join(lines)

def disasm_word(w):
    """Legacy single-word helper (no label context)."""
    return disasm_line(w, 0, {})

def main():
    img = read_sgp1(sys.argv[1])
    print(f'; SGP1 fmt{img["fmt"]} ISA{img["isa"]} features=0x{img["features"]:X}')
    e = img['entry']
    print(f'; entry pc={e["pc"]} vgpr={e["vgpr"]} sgpr={e["sgpr"]} '
          f'smem={e["smem"]} args={e["args"]}')
    words = [struct.unpack_from('<Q', img['code'], i)[0]
             for i in range(0, len(img['code']), 8)]
    for i, line in enumerate(disasm_words(words).split('\n')):
        print(f'{line}' if line.endswith(':') else f'{i:04d}: {line}')

if __name__ == '__main__':
    main()
