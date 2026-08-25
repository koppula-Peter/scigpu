#!/usr/bin/env python3
"""M3 randomized vector-program generator (directive §99-103).

Deterministic per seed. Emits program + initial EXEC/PRED/VGPR state.
"""
import os, sys, random
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
sys.path.insert(0, os.path.join(ROOT, 'verification', 'm3'))
from sgpu_asm import assemble
from golden_trace_m3 import prep

SPECIAL = [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xAAAAAAAA, 0x55555555]

def rand_mask(rng):
    r = rng.random()
    if r < 0.10: return 0xFFFFFFFF
    if r < 0.16: return 0
    if r < 0.26: return 1 << rng.randrange(32)
    if r < 0.34: return 0xAAAAAAAA
    if r < 0.42: return 0x55555555
    if r < 0.50: return (1 << rng.randint(1, 31)) - 1      # contiguous low
    if r < 0.58: return 0xFFFFFFFF ^ ((1 << rng.randint(1, 31)) - 1)
    if r < 0.66: return rng.choice([0x80000001, 0x01010101, 0x80808080,
                                    0x00010008])
    return rng.getrandbits(32)

def gen(seed):
    rng = random.Random(seed)
    exec_mask = rand_mask(rng)
    preds = [rng.getrandbits(32) if rng.random() < 0.4 else rng.choice(SPECIAL)
             for _ in range(15)]
    vgpr_init = []
    for v in range(2, 6):
        for l in range(32):
            if rng.random() < 0.9:
                vgpr_init.append((v, l, rng.getrandbits(32)))
    lines = ['.reg vgpr_count=8 sgpr_count=32',
             f'.kern rnd args=()', 'rnd:',
             '  S_MOV   s20, 77']
    n = rng.randint(6, 30)
    for _ in range(n):
        d = f'v{rng.randint(2, 6)}'
        a = f'v{rng.randint(2, 6)}'
        b = f'v{rng.randint(2, 6)}'
        pred = ''
        if rng.random() < 0.25:
            pred = f' [p{rng.randint(0, 14)}]'
        r = rng.random()
        if r < 0.12:
            lines.append(f'  V_MOV   {d}, {a}{pred}')
        elif r < 0.22:
            imm = rng.choice([0, 1, -1, 32767, -32768]) if rng.random() < 0.5 \
                  else (rng.randint(-32768, 32767))
            lines.append(f'  V_MOVI  {d}, {imm}{pred}')
        elif r < 0.30:
            lines.append(f'  S_MOV   s21, {rng.choice(SPECIAL)}')
            lines.append(f'  V_BCAST {d}, s21{pred}')
        elif r < 0.36:
            lines.append(f'  V_LLANE {d}{pred}')
        elif r < 0.62:
            op = rng.choice(['V_ADD','V_SUB','V_MUL','V_AND','V_OR','V_XOR'])
            lines.append(f'  {op:7s} {d}, {a}, {b}{pred}')
        elif r < 0.72:
            op = rng.choice(['V_ADD','V_SUB','V_AND','V_OR','V_XOR'])
            imm = rng.choice([0, 1, -1, 32767, -32768, rng.randint(-32768, 32767)])
            lines.append(f'  {op:7s} {d}, {a}, {imm}{pred}')
        else:
            op = rng.choice(['V_SHL','V_SHR','V_SAR'])
            amt = rng.choice([0, 1, 15, 16, 31, 32, 33, 63, rng.randint(0, 40)])
            src = a
            if op == 'V_SAR':
                lines.append(f'  S_MOV   s22, {rng.choice(SPECIAL)}')
                lines.append(f'  V_BCAST {src}, s22')
            lines.append(f'  {op:7s} {d}, {src}, {amt}{pred}')
    # scalar tail exercising mixed stream + loop
    k = rng.randint(1, 3)
    lines.append('  S_MOV   s30, %d' % k)
    lines.append('LOOP:')
    lines.append('  S_ADD   s23, s23, 1')
    lines.append('  S_SUB   s30, s30, 1')
    lines.append('  S_MOV   s24, 0')
    lines.append('  S_CMP_EQ s30, s24')
    lines.append('  S_BRA_COND NZ, LOOP')
    lines.append('  RET_KERNEL_WF')
    return '\n'.join(lines) + '\n', exec_mask, preds, vgpr_init

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    root = sys.argv[2] if len(sys.argv) > 2 else 'reports/evidence/m3/random'
    manifest = []
    for seed in range(1, n+1):
        text, em, preds, vi = gen(seed)
        built = prep(os.path.join(root, f'seed{seed:04d}'), asm_text=text,
                     exec_mask=em, pred_init=preds, vgpr_init=vi,
                     vgpr_req=8, sgpr_req=32)
        open(os.path.join(root, f'seed{seed:04d}', 'prog.gpuasm'), 'w').write(text)
        manifest.append(f'seed{seed:04d} len={len(built["words"])} '
                        f'exec={em:08x} fault={built["fault"]:02x}')
    open(os.path.join(root, 'seed_manifest.txt'), 'w').write('\n'.join(manifest)+'\n')
    print(f'generated {n} programs under {root}')

if __name__ == '__main__':
    main()
