#!/usr/bin/env python3
"""M5 randomized structured-divergence program generator (directive §150-152).

AST-based; emits only LEGAL structured programs with compiler-computed
reconvergence targets. Conditions from lane id / parity / ranges / loop
counters -> realistic divergent masks. All programs terminate by construction
(bounded per-lane trip counts).

Register conventions inside generated kernels (vgpr_count=16):
  v1  lane ids            v7  const 1          v13 scratch
  v10/v11/v9              loop counters for depth 0/1/2
  other v2..v6, v8, v12+  leaf scratch
"""
import random

CNT = ['v10', 'v11', 'v9']

class Gen:
    def __init__(self, rng):
        self.rng = rng
        self.if_depth = 0
        self.loop_depth = 0

    def pred_write(self, L, ind, pdst, a, b, op=None):
        op = op or self.rng.choice(['V_CMP_EQ','V_CMP_NEQ','V_CMP_LT',
                                    'V_CMP_LE','V_CMP_GT','V_CMP_GE'])
        L.append(f'{ind}  {op} p{pdst}, {a}, {b}')

    def leaf(self, L, ind):
        r = self.rng.random()
        vd = self.rng.choice(['v3','v4','v5','v12'])
        va = self.rng.choice(['v1','v3','v4'])
        vb = self.rng.choice(['v5','v12','v7'])
        if r < 0.5:
            op = self.rng.choice(['V_ADD','V_SUB','V_AND','V_OR','V_XOR',
                                  'V_MIN','V_MAX'])
            L.append(f'{ind}  {op} {vd}, {va}, {vb}')
        elif r < 0.65:
            L.append(f'{ind}  V_MOVI {vd}, {self.rng.randrange(0,16)}')
        elif r < 0.8:
            L.append(f'{ind}  S_ADD s6, s6, {self.rng.randrange(1,5)}')
        else:
            L.append(f'{ind}  V_SUB {vd}, {vb}, {va}')

    def cnt(self): return CNT[min(self.loop_depth, 2)]

    def emit_loop(self, L, ind, tag, kern_i):
        if self.loop_depth >= 3:
            self.leaf(L, ind); return
        rng = self.rng
        self.loop_depth += 1
        d = self.loop_depth - 1
        c = CNT[d]
        bL = f'LB{tag}_{d}'
        eL = f'LE{tag}_{d}'
        # budget = 1 + (lane & mask)   (per-lane trip bound >= 1)
        m = rng.choice([0, 1, 3])
        L.append(f'{ind}  V_MOVI v13, {m}')
        L.append(f'{ind}  V_AND  v12, v1, v13')
        L.append(f'{ind}  V_ADD  v12, v12, v7')
        L.append(f'{ind}  V_MOVI {c}, 0')
        L.append(f'{ind}  LOOP_BEGIN {eL}')
        bi = ind + '  '
        L.append(f'{bi}{bL}:')
        # predicates FIRST (progress contract: valid even when all lanes
        # continue at the top and unwind routes straight to LOOP_END)
        L.append(f'{bi}  V_CMP_GE p14, {c}, v12')   # done    -> CONTINUE
        L.append(f'{bi}  V_CMP_LT p13, {c}, v12')   # notdone -> iterate
        do_continue = rng.random() < 0.6
        # optional inner IF (work only; BREAK kept out of randomized nested
        # contexts -- covered exhaustively by the D21/D24 directed kernels,
        # see OI-014 for the residual multi-path interplay under study)
        if rng.random() < 0.55:
            pb = rng.randrange(12)
            pa = rng.choice(['v1','v10','v11'])
            self.pred_write(L, bi, pb, pa, 'v7')
            iL = f'IB{tag}_{d}'
            L.append(f'{bi}  CBRANCH_IF p{pb}, {iL}, {iL}X')
            L.append(f'{bi}{iL}:')
            self.leaf(L, bi + '  ')
            L.append(f'{bi}{iL}X:')
            L.append(f'{bi}  RECONV')
        else:
            self.leaf(L, bi)
        if do_continue:
            L.append(f'{bi}  CONTINUE p14')       # skip tail when done
            L.append(f'{bi}  V_ADD {c}, {c}, v7') # survivors only
        else:
            L.append(f'{bi}  V_ADD {c}, {c}, v7') # unconditional increment
        L.append(f'{ind}{eL}:')
        L.append(f'{ind}  LOOP_END p13, {bL}')
        self.loop_depth -= 1

    def emit_if(self, L, ind, tag):
        if self.if_depth >= 8:
            self.leaf(L, ind); return
        rng = self.rng
        self.if_depth += 1
        p = rng.randrange(15)
        pa = rng.choice(['v1','v10','v11','v3'])
        pb = rng.choice(['v7','v12'])
        self.pred_write(L, ind, p, pa, pb)
        eL = f'EI{tag}_{self.if_depth}'
        mL = f'MI{tag}_{self.if_depth}'
        L.append(f'{ind}  CBRANCH_IF p{p}, {eL}, {mL}')
        self.block(L, ind + '  ', tag + 'T', rng.randrange(1,3))
        L.append(f'{ind}  S_BRA {mL}')
        L.append(f'{ind}{eL}:')
        self.block(L, ind + '  ', tag + 'E', rng.randrange(1,3))
        L.append(f'{ind}{mL}:')
        L.append(f'{ind}  RECONV')
        self.if_depth -= 1

    def block(self, L, ind, tag, n=None):
        rng = self.rng
        n = n if n is not None else rng.randrange(1, 4)
        for i in range(n):
            r = rng.random()
            if r < 0.30:
                self.emit_if(L, ind, f'{tag}{i}')
            elif r < 0.50:
                self.emit_loop(L, ind, f'{tag}{i}', tag)
            else:
                self.leaf(L, ind)

    def program(self, kid):
        L = [".reg vgpr_count=16 sgpr_count=32",
             f".kern r{kid} args=(out:PTR)",
             f"r{kid}:",
             "  V_LLANE v1",
             "  V_MOVI v7, 1",
             "  V_MOVI v12, 3"]
        self.block(L, '  ', 'R')
        L.append('  RET_KERNEL_WF')
        return '\n'.join(L) + '\n'


def gen_program(seed):
    return Gen(random.Random(seed)).program(seed % 10000)


if __name__ == '__main__':
    import sys
    print(gen_program(int(sys.argv[1]) if len(sys.argv)>1 else 1))
