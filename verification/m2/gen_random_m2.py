#!/usr/bin/env python3
"""Constrained-random M2 scalar program generator (directive §49-50).

Guaranteed-terminating programs: only counted backward loops with a strictly
decrementing bound register; forward skips are branch-only. Deterministic per seed.
"""
import os, sys, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', 'assembler'))
from sgpu_asm import assemble
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', 'verification', 'm2'))
from golden_trace import build_from_asm_obj, write_artifacts

BOUND = 's30'      # loop counter register
ZERO  = 's29'      # constant zero

SPECIAL = [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xAAAAAAAA, 0x55555555]

def rand_val(rng):
    r = rng.random()
    if r < 0.35:
        return f'{rng.choice(SPECIAL)}'
    return str(rng.getrandbits(32))

def gen_program(rng):
    lines = ['.reg vgpr_count=4 sgpr_count=64',
             '.kern rnd args=()', 'rnd:',
             f'  S_MOV   {ZERO}, 0']
    nbody = rng.randint(6, 40)
    label_n = 0
    for _ in range(nbody):
        r = rng.random()
        d = f's{rng.randint(1, 20)}'
        a = f's{rng.randint(1, 20)}'
        b = f's{rng.randint(1, 20)}'
        if r < 0.18:
            lines.append(f'  S_MOV   {d}, {rand_val(rng)}')
        elif r < 0.34:
            op = rng.choice(['S_ADD','S_SUB','S_AND','S_OR','S_XOR','S_MUL'])
            lines.append(f'  {op:8s}{d}, {a}, {b}')
        elif r < 0.42:
            op = rng.choice(['S_ADD','S_SUB'])
            lines.append(f'  {op:8s}{d}, {a}, {rand_val(rng)}')
        elif r < 0.50:
            op = rng.choice(['S_SHL','S_SHR','S_SAR'])
            lines.append(f'  {op:8s}{d}, {a}, {rng.randint(0, 33)}')
        elif r < 0.56:
            op = rng.choice(['S_SHL','S_SHR','S_SAR'])
            lines.append(f'  {op:8s}{d}, {a}, {b}')
        elif r < 0.62:
            lines.append(f'  S_NOT   {d}, {a}')
        elif r < 0.74:
            kind = rng.choice(['EQ','LT','GT'])
            lines.append(f'  S_CMP_{kind} {a}, {b}')
            lbl = f'SK{label_n}'; label_n += 1
            cond = rng.choice(['SCC','NSCC','Z','NZ','LT_S','GE_S','LT_U','GE_U'])
            skip = ['  NOP'] * rng.randint(1, 3)
            lines.append(f'  S_BRA_COND {cond}, {lbl}')
            lines += skip
            lines.append(f'{lbl}:')
            lines.append('  RECONV_PLACEHOLDER')  # removed below; scalar path needs no reconvergence
        elif r < 0.80:
            lines.append(f'  S_GETID {d}, WG_X')
        else:
            lines.append('  NOP')
    # one counted loop (terminates by construction)
    k = rng.randint(1, 4)
    lines.append(f'  S_MOV   {BOUND}, {k}')
    lines.append('LOOP:')
    lines.append(f'  S_ADD   s21, s21, 1')
    lines.append(f'  S_SUB   {BOUND}, {BOUND}, 1')
    lines.append(f'  S_CMP_EQ {BOUND}, {ZERO}')
    lines.append(f'  S_BRA_COND NZ, LOOP')
    lines.append('  RET_KERNEL_WF')

    # scalar ISA has no RECONV — strip placeholders (kept generator simple)
    lines = [l for l in lines if 'RECONV_PLACEHOLDER' not in l]
    # forward-skip labels referenced S_BRA_COND targets must exist even if we
    # stripped nothing here; ensure label exists:
    text = '\n'.join(lines) + '\n'
    return text

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    out_root = sys.argv[2] if len(sys.argv) > 2 else 'reports/evidence/m2/random'
    manifest = []
    for seed in range(1, n + 1):
        rng = random.Random(seed)
        text = gen_program(rng)
        try:
            built = build_from_asm_obj(assemble(text))
        except Exception as e:
            print(f'seed {seed}: build error {e}', file=sys.stderr)
            raise
        d = os.path.join(out_root, f'seed{seed:04d}')
        write_artifacts(d, built)
        open(os.path.join(d, 'prog.gpuasm'), 'w').write(text)
        manifest.append(f'seed{seed:04d} len={len(built["words"])} fault={built["fault"]:02x}')
    open(os.path.join(out_root, 'seed_manifest.txt'), 'w').write('\n'.join(manifest) + '\n')
    print(f'generated {n} programs under {out_root}')

if __name__ == '__main__':
    main()
