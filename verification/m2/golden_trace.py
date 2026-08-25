#!/usr/bin/env python3
"""M2 golden-artifact builder: .gpuasm -> {prog.words.hex, golden.trace, golden.final}

Shared trace format (RTL TB emits identical):
  one line per retired instruction:
    PC INSN WE WA WD ZNCV SCC BR NX          (hex; ZNCV nibble bit3..0={V,C,N,Z})
  terminal line:
    DONE retired=<n> fault=<code> pc=<retiring-or-faulting-pc>
"""
import os, sys, struct, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
from sgpu_asm import assemble, emit_sgp1
from simulator import Kernel, SimFault

SGPR_COUNT = 64

def build_from_asm(asm_text, wg_x=0):
    asm = assemble(asm_text)
    return build_from_asm_obj(asm, wg_x)

def build_from_asm_obj(asm, wg_x=0):
    fd, path = tempfile.mkstemp(suffix='.sgp1'); os.close(fd)
    emit_sgp1(asm, path)
    try:
        img_words = []
        raw = open(path, 'rb').read()
        # code section located like read_sgp1 but without checksum assert here;
        # reuse loader (INV-022 enforced) then extract words
        from scigpu_defs import read_sgp1
        img = read_sgp1(path)
        code = img['code']
        for i in range(0, len(code), 8):
            img_words.append(struct.unpack_from('<Q', code, i)[0])
        k = Kernel(path, grid_x=wg_x+1, wg_size=32,
                   vgpr_req=max(asm['n_regs'][0], 4),
                   sgpr_req=max(SGPR_COUNT, asm['n_regs'][1]),
                   smem_req=asm['smem'], simd_lanes=8, trace=True)
        wf = k.wfs[wg_x]
        fault = 0
        term_pc = 0
        try:
            k.run()
            term_pc = k.trace[-1]['pc'] if k.trace else 0   # retiring-instruction PC
        except SimFault as e:
            fault = e.code
            term_pc = wf.pc                                 # faulting-instruction PC
        lines = []
        for t in k.trace:
            # per-instruction flag snapshot: architectural Z/N/C/V AFTER this
            # instruction commits (matches RTL x_flags commit convention)
            nib = ((t['V'] << 3) | (t['C'] << 2) | (t['N'] << 1) | t['Z'])
            lines.append(f"{t['pc']:016x} {t['insn']:016x} {t['sgpr_we']:x} "
                         f"{t['sgpr_addr']:02x} {t['sgpr_wdata']:08x} {nib:x} "
                         f"{t['scc']:x} {t['branch_taken']:x} {t['next_pc']:016x}")
        lines.append(f"DONE retired={len(k.trace)} fault={fault:02x} "
                     f"pc={term_pc:016x}")
        return dict(words=img_words, trace='\n'.join(lines) + '\n',
                    sgpr=[wf.sgpr[i] for i in range(SGPR_COUNT)],
                    fault=fault, retired=(len(k.trace)))
    finally:
        os.unlink(path)

def _retired_before_fault(k, wf):
    return len(k.trace)

def write_artifacts(out_dir, built):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, 'prog.words.hex'), 'w') as f:
        for w in built['words']:
            f.write(f'{w:016x}\n')
    open(os.path.join(out_dir, 'golden.trace'), 'w').write(built['trace'])
    with open(os.path.join(out_dir, 'golden.sgpr'), 'w') as f:
        f.write(' '.join(f'{v:08x}' for v in built['sgpr']) + '\n')
    open(os.path.join(out_dir, 'golden.fault'), 'w').write(f"{built['fault']:02x}\n")

def build_file(asm_path, out_dir=None, wg_x=0):
    built = build_from_asm(open(asm_path).read(), wg_x)
    if out_dir:
        write_artifacts(out_dir, built)
    return built

if __name__ == '__main__':
    build_file(sys.argv[1], sys.argv[2])
    print('golden artifacts written to', sys.argv[2])
