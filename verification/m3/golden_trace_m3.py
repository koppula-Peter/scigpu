#!/usr/bin/env python3
"""M3 golden-artifact builder (extends M2 format with vector fields).

Per-retire line (shared with RTL TB):
  PC INSN SWE SWA SWD FLAGS SCC BR NX EXEC PRED EFF VWE VA VMASK
DONE line:  DONE retired=<n> fault=<code> pc=<ret-or-fault-pc>
State file: SGPR/PRED/EXEC/VGPR lines (dump_state()).
meta.txt:   exec=<hex> vgpr_req=<n> sgpr_req=<n> wg_x=<n>
pred.hex:   15 words (P0..P14)
vgpr.hex:   lines 'addr lane data' (decimal addr/lane, hex data)
"""
import os, sys, struct, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
from sgpu_asm import assemble, emit_sgp1
from simulator import Kernel, SimFault

SGPR_COUNT = 64
VGPR_COUNT = 32

def build(asm_text=None, asm_obj=None, wg_x=0, exec_mask=0xFFFFFFFF,
          pred_init=None, vgpr_init=None, sgpr_req=16, vgpr_req=16):
    asm = asm_obj if asm_obj is not None else assemble(asm_text)
    fd, path = tempfile.mkstemp(suffix='.sgp1'); os.close(fd)
    emit_sgp1(asm, path)
    try:
        from scigpu_defs import read_sgp1
        img = read_sgp1(path)
        code = img['code']
        words = [struct.unpack_from('<Q', code, i)[0]
                 for i in range(0, len(code), 8)]
        k = Kernel(path, grid_x=wg_x+1, wg_size=32,
                   vgpr_req=max(VGPR_COUNT, 4), sgpr_req=max(SGPR_COUNT, 8),
                   smem_req=asm['smem'], simd_lanes=8, trace=True,
                   exec_mask=exec_mask, pred_init=pred_init,
                   vgpr_init=vgpr_init)
        wf = k.wfs[wg_x]
        fault = 0; term_pc = 0
        try:
            k.run()
            term_pc = k.trace[-1]['pc'] if k.trace else 0
        except SimFault as e:
            fault = e.code; term_pc = wf.pc
        lines = []
        for t in k.trace:
            nib = ((t['V'] << 3) | (t['C'] << 2) | (t['N'] << 1) | t['Z'])
            vwe = int(bool(t.get('vgpr_we')))
            va = t.get('vgpr_addr') or 0
            vmask = t.get('effective_mask') or 0
            lines.append(f"{t['pc']:016x} {t['insn']:016x} {t['sgpr_we']:x} "
                         f"{t['sgpr_addr']:02x} {t['sgpr_wdata']:08x} {nib:x} "
                         f"{t['scc']:x} {t['branch_taken']:x} {t['next_pc']:016x} "
                         f"{t['exec_mask']:08x} {t['pred']:x} {vmask:08x} "
                         f"{vwe:x} {va:02x} {vmask:08x}")
        lines.append(f"DONE retired={len(k.trace)} fault={fault:02x} "
                     f"pc={term_pc:016x}")
        return dict(words=words,
                    trace='\n'.join(lines) + '\n',
                    state=k.dump_state(SGPR_COUNT, VGPR_COUNT),
                    fault=fault, retired=len(k.trace))
    finally:
        os.unlink(path)

def write_artifacts(out_dir, built, exec_mask=0xFFFFFFFF, vgpr_req=16,
                    sgpr_req=16, pred_init=None, vgpr_init=None):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, 'prog.words.hex'), 'w') as f:
        for w in built['words']:
            f.write(f'{w:016x}\n')
    open(os.path.join(out_dir, 'golden.trace'), 'w').write(built['trace'])
    open(os.path.join(out_dir, 'golden.state'), 'w').write(built['state'])
    open(os.path.join(out_dir, 'golden.fault'), 'w').write(f"{built['fault']:02x}\n")
    open(os.path.join(out_dir, 'meta.txt'), 'w').write(
        f"exec={exec_mask:08x} vgpr_req={vgpr_req} sgpr_req={sgpr_req} wg_x=0\n")
    pi = pred_init if pred_init is not None else [0]*15
    open(os.path.join(out_dir, 'pred.hex'), 'w').write(
        ''.join(f'{v:08x}\n' for v in pi))
    with open(os.path.join(out_dir, 'vgpr.hex'), 'w') as f:
        for (va, vl, vd) in (vgpr_init or []):
            f.write(f'{va} {vl} {vd:08x}\n')

def prep(out_dir, asm_text=None, asm_obj=None, **kw):
    em = kw.pop('exec_mask', 0xFFFFFFFF)
    pi = kw.pop('pred_init', None)
    vi = kw.pop('vgpr_init', None)
    vq = kw.pop('vgpr_req', 16)
    sq = kw.pop('sgpr_req', 16)
    built = build(asm_text=asm_text, asm_obj=asm_obj, exec_mask=em,
                  pred_init=pi, vgpr_init=vi, vgpr_req=vq, sgpr_req=sq, **kw)
    write_artifacts(out_dir, built, exec_mask=em, vgpr_req=vq, sgpr_req=sq,
                    pred_init=pi, vgpr_init=vi)
    return built
