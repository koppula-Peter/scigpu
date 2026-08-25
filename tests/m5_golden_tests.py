#!/usr/bin/env python3
"""SciGPU M5 golden-model divergence suite (EXEC-001 Rev1.1 §9).

Validates the ADR-011 typed-stack semantics in the ISA simulator itself,
against serial per-lane CPU references. These run BEFORE/INDEPENDENT of RTL
(golden_refactor gate, directive §103).
"""
import os, sys, struct, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
from sgpu_asm import assemble, emit_sgp1

PASS, FAIL = [], []

def check(name, cond, detail=''):
    (PASS if cond else FAIL).append(name)
    print(f'[{"PASS" if cond else "FAIL"}] {name} {detail}')

def run(src_text, grid_x=1, wg_size=32, args_packed=b'', simd_lanes=8,
        mem_size=1 << 14, mem_preload=b'', mask_stack_depth=32):
    asm = assemble(src_text)
    fd, path = tempfile.mkstemp(suffix='.sgp1'); os.close(fd)
    emit_sgp1(asm, path)
    from simulator import Kernel, SimFault
    try:
        k = Kernel(path, grid_x=grid_x, wg_size=wg_size,
                   vgpr_req=max(asm['n_regs'][0], 16),
                   sgpr_req=max(asm['n_regs'][1], 24),
                   smem_req=asm['smem'], simd_lanes=simd_lanes,
                   mem_size=mem_size, args_packed=args_packed,
                   mask_stack_depth=mask_stack_depth)
        k.mem[0:len(mem_preload)] = mem_preload
        k.run()
        return k, None
    except SimFault as e:
        return None, e
    finally:
        os.unlink(path)

def loads(k, n, off=0, signed=True):
    f = '<' if signed else ''
    return list(struct.unpack_from(f'{n}I', k.mem, off))

# G01 simple if/else even-odd --------------------------------------------
G01 = """
.reg vgpr_count=16 sgpr_count=24
.kern g01 args=(out:PTR)
g01:
  V_LLANE v1
  V_MOVI  v7, 1
  V_AND   v2, v1, v7          ; parity
  V_CMP_EQ p0, v2, v7         ; odd lanes -> p0 true
  CBRANCH_IF p0, ELSE, MERGE
  V_MOVI  v3, 100             ; THEN: odd
  S_BRA   MERGE
ELSE:
  V_MOVI  v3, 200             ; ELSE: even
MERGE:
  RECONV
  V_STORE.W v3, s0 + v1*4
  RET_KERNEL_WF
"""
def g01():
    k, err = run(G01)
    got = loads(k, 32) if k else []
    exp = [100 if i % 2 else 200 for i in range(32)]
    check('G01 if/else even-odd', err is None and got == exp,
          '' if got == exp else f'got={got[:8]} err={err}')

# G02 nested IF depth 2 ---------------------------------------------------
G02 = """
.reg vgpr_count=16 sgpr_count=24
.kern g02 args=(out:PTR)
g02:
  V_LLANE v1
  V_MOVI  v7, 3
  V_AND   v2, v1, v7          ; lane & 3
  V_CMP_GT p0, v2, v7         ; impossible? use NEQ below instead
  V_CMP_NEQ p0, v2, v7        ; p0 = (lane&3)!=3
  CBRANCH_IF p0, E1, M1
  V_CMP_EQ p1, v2, v7
  V_MOVI v6, 3
  V_CMP_EQ p1, v2, v6         ; p1 = (lane&3)==3
  V_MOVI v5, 0
  V_CMP_LT p1, v5, v2         ; p1 = 0 < (lane&3)  => inner test
  CBRANCH_IF p1, E2, M2
  V_MOVI v3, 11               ; THEN THEN
  S_BRA M2
E2:
  V_MOVI v3, 12
M2:
  RECONV
  S_BRA M1
E1:
  V_MOVI v3, 20               ; outer else
M1:
  RECONV
  V_STORE.W v3, s0 + v1*4
  RET_KERNEL_WF
"""
def g02():
    k, err = run(G02)
    got = loads(k, 32) if k else []
    def exp_of(i):
        a = i & 3
        if a == 3: return 20           # outer else
        if a == 0: return 12           # then/else inner false
        return 11                      # both true
    exp = [exp_of(i) for i in range(32)]
    check('G02 nested IF depth2 four-path', err is None and got == exp,
          '' if got == exp else f'got={got[:8]} exp={exp[:8]} err={err}')

# G05 simple per-lane-count loop (progressive dropout) --------------------
G05 = """
.reg vgpr_count=16 sgpr_count=24
.kern g05 args=(out:PTR, n:U32)
g05:
  V_LLANE v1
  V_MOVI v10, 0               ; per-lane counter
  V_BCAST v2, s2              ; n
  V_SUB  v2, v2, v1           ; budget = n - lane_id
LOOP_BEGIN LEND
BODY:
  V_CMP_LE p0, v2, v10        ; budget <= counter -> this lane done
  CONTINUE p0
  V_ADD  v10, v10, 1
  V_CMP_LT p1, v10, v2        ; counter < budget -> iterate again
LEND:
  LOOP_END p1, BODY
DONE:
  V_STORE.W v10, s0 + v1*4
  RET_KERNEL_WF
"""
def g05():
    n = 8
    k, err = run(G05, args_packed=struct.pack('<III', 0, 0, n))
    if err is not None:
        check('G05 per-lane loop counts', False, f'err={err}')
        return
    got = loads(k, 32)
    exp = [max(n - i, 0) for i in range(32)]
    check('G05 per-lane loop counts (progressive dropout)', got == exp,
          '' if got == exp else f'got={got[:8]} exp={exp[:8]}')

# G04 break inside if (mandatory mask-scrub) ------------------------------
G04 = """
.reg vgpr_count=16 sgpr_count=24
.kern g04 args=(out:PTR)
g04:
  V_LLANE v1
  V_MOVI v10, 0               ; iteration count record
LOOP_BEGIN LEND
BODY:
  V_MOVI v4, 1
  V_AND  v2, v1, v4           ; parity
  V_CMP_EQ p0, v2, v4         ; odd lanes
  CBRANCH_IF p0, ELSEP, RP
  ; THEN (odd): break when counter reaches 1
  V_MOVI v5, 1
  V_CMP_EQ p1, v10, v5
  BREAK p1
  V_ADD  v10, v10, 1
  S_BRA RP
ELSEP:
  ; EVEN lanes keep iterating until counter 3
  V_MOJI_SENTINEL:
  V_MOVI v5, 3
  V_CMP_EQ p1, v10, v5
  CONTINUE p1                 ; skip increment on final even iteration
  V_ADD  v10, v10, 1
RP:
  RECONV
  ; loop-condition predicate: continue while counter < 3
  V_MOVI v5, 3
  V_CMP_LT p2, v10, v5
LEND:
  LOOP_END p2, BODY
DONE:
  V_STORE.W v10, s0 + v1*4
  RET_KERNEL_WF
"""
def g04():
    k, err = run(G04)
    if err is not None:
        # fall back: report failure with error
        check('G04 break+continue inside IF', False, f'err={err}')
        return
    got = loads(k, 32)
    # odd lanes: iterate; at iter==1 they BREAK -> stay at 1... then rejoin
    # after loop: counter stays 1? They broke during iteration where v10==1.
    # After loop exit all lanes store their recorded v10.
    # even lanes: continue at 3 without incrementing -> stop at 3.
    # odd lanes: iterations: v10=0 (no break, inc->1), next iter v10==1 -> BREAK
    #   so they never increment past 1. Loop continues for even lanes until 3.
    # At exit odd store 1, even store 3.
    exp = [3 if i % 2 == 0 else 1 for i in range(32)]
    check('G04 break+continue inside IF (scrub)', got == exp,
          '' if got == exp else f'got={got[:8]} exp={exp[:8]}')

def main():
    print('=' * 60)
    print('SciGPU M5 golden divergence suite')
    print('=' * 60)
    g01()
    g02()
    g04()
    g05()
    print('-' * 60)
    verdict = 'PASS' if not FAIL else 'FAIL'
    print(f'M5 GOLDEN RESULT: {verdict} ({len(PASS)} passed, {len(FAIL)} failed)')
    if FAIL:
        sys.exit(1)

if __name__ == '__main__':
    main()
