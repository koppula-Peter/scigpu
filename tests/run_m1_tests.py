#!/usr/bin/env python3
"""SciGPU M1 regression: end-to-end kernel tests (asm -> SGP1 -> golden sim).

Covers ROADMAP-001 M1 exit criteria:
  T1 vector_add, bit-exact, partial-wavefront masks exercised separately
  T2 SAXPY FMA vs host reference
  T3 if/else divergence + reconvergence vs serial per-lane reference
  T4 barrier liveness across two wavefronts
  T5 INV-025: bit-identical results across SIMD_LANES {4,8,16,32}
  T6 partial wavefront (mask edges) correctness
  T7 SGP1 checksum tamper detection (INV-022)
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

def run_kernel(src_text, grid_x, wg_size=32, args_packed=b'', mem_size=1 << 14,
               simd_lanes=8, mem_preload=b''):
    asm = assemble(src_text)
    fd, path = tempfile.mkstemp(suffix='.sgp1'); os.close(fd)
    emit_sgp1(asm, path)
    from simulator import Kernel
    try:
        k = Kernel(path, grid_x=grid_x, wg_size=wg_size,
                   vgpr_req=max(asm['n_regs'][0], 16),
                   sgpr_req=max(asm['n_regs'][1], 24),
                   smem_req=asm['smem'], simd_lanes=simd_lanes,
                   mem_size=mem_size, args_packed=args_packed)
        k.mem[0:len(mem_preload)] = mem_preload
        k.run()
        return k, None
    except Exception as e:
        return None, e
    finally:
        os.unlink(path)

# ---------------------------------------------------------------- kernels ---
ADD = """
.reg vgpr_count=16 sgpr_count=24
.kern add args=(a:PTR, b:PTR, c:PTR)
add:
  V_LLANE   v1
  V_LOAD.W  v3, s0 + v1*4
  V_LOAD.W  v4, s2 + v1*4
  V_ADD.F32 v5, v3, v4
  V_STORE.W v5, s4 + v1*4
  RET_KERNEL_WF
"""

SAXPY = """
.reg vgpr_count=16 sgpr_count=24
.kern saxpy args=(x:PTR, y:PTR, alpha:F32)
saxpy:
  V_LLANE   v1
  V_BCAST   v2, s4            ; alpha broadcast (ABI: s4)
  V_LOAD.W  v3, s0 + v1*4     ; x
  V_LOAD.W  v4, s2 + v1*4     ; y
  V_FMA.F32 v6, v3, v2, v4    ; a*x+y single-rounded
  V_STORE.W v6, s2 + v1*4
  RET_KERNEL_WF
"""

DIVERGE = """
.reg vgpr_count=16 sgpr_count=24
.kern diverge args=(out:PTR, sel:PTR)
diverge:
  V_LLANE   v1
  V_LOAD.W  v2, s2 + v1*4     ; selector per lane
  V_MOVI    v7, 0
  V_CMP.GT  p1, v2, v7
  CBRANCH_IF p1, ELSE_LBL, MERGE   ; M5: explicit else + reconvergence targets
  V_MOVI    v3, 100           ; THEN (pos lanes)
  BRA       MERGE
ELSE_LBL:
  V_MOVI    v3, 200           ; ELSE (neg lanes)
MERGE:
  RECONV
  V_MOVI    v4, 7
  V_ADD.I32 v6, v3, v4        ; all lanes post-merge
  V_STORE.W v6, s0 + v1*4
  RET_KERNEL_WF
"""

BARRY = """
.reg vgpr_count=16 sgpr_count=8
.kern barry args=(out:PTR)
barry:
  V_LLANE   v1
  BAR.WG
  V_MOVI    v7, 0
  V_MOVI    v3, 99
  V_CMP_EQ  p1, v1, v7
  CBRANCH_IF p1, ISZERO, ISZERO  ; M5: else entry == reconvergence point
  V_MOVI    v3, 42          ; lane 0 only
ISZERO:
  RECONV
  V_STORE.W v3, s0 + v1*4
  RET_KERNEL_WF
"""

MASKEDGE = """
.reg vgpr_count=16 sgpr_count=24
.kern edge args=(out:PTR, n:U32)
edge:
  V_LLANE   v1
  V_BCAST   v2, s2          ; n broadcast (SGPR arg slot of n = s2? see ABI: a=2sgpr,n=1 -> n in s2)
  V_CMP.LT  p1, v1, v2      ; lane < n ?
  CBRANCH_IF p1, OUTRANGE, PUT  ; M5: explicit targets
  V_MOVI    v3, 1           ; valid side
  BRA       PUT
OUTRANGE:
  V_MOVI    v3, -1          ; invalid side
PUT:
  RECONV
  V_STORE.W v3, s0 + v1*4
  RET_KERNEL_WF
"""

def f32u(x): return struct.unpack('<I', struct.pack('<f', float(x)))[0]

def t1_vector_add():
    n = 32
    a = [float(i) for i in range(n)]
    b = [float(3*i) for i in range(n)]
    args = struct.pack('<IIIIII', 0, 0, n*4, 0, 2*n*4, 0)
    preload = struct.pack(f'<{2*n}f', *(a + b))
    k, err = run_kernel(ADD, grid_x=1, args_packed=args,
                        mem_size=1 << 14, mem_preload=preload)
    ok = err is None
    got = list(struct.unpack_from(f'<{n}f', k.mem, 2*n*4)) if ok else []
    exact = ok and got == [a[i] + b[i] for i in range(n)]      # bit-exact
    check('T1 vector_add bit-exact', exact, f'err={err}')

def t2_saxpy():
    import random
    random.seed(7)
    n = 32
    x = [random.uniform(-9, 9) for _ in range(n)]
    y = [random.uniform(-9, 9) for _ in range(n)]
    al = 2.5
    args = struct.pack('<IIIII', 0, 0, n*4, 0, f32u(al))
    preload = struct.pack(f'<{2*n}f', *(x + y))
    k, err = run_kernel(SAXPY, grid_x=1, args_packed=args,
                        mem_preload=preload)
    ok = err is None
    got = list(struct.unpack_from(f'<{n}f', k.mem, n*4)) if ok else []
    exp = [al*x[i] + y[i] for i in range(n)]
    close = ok and all(abs(g-e) <= 1e-6*max(1.0, abs(e)) for g, e in zip(got, exp))
    check('T2 SAXPY FMA alpha*x+y', close, f'err={err}')

def t3_divergence():
    n = 32
    sel = [(i % 4) for i in range(n)]
    args = struct.pack('<IIII', 0, 0, n*4, 0)
    k, err = run_kernel(DIVERGE, grid_x=1, args_packed=args,
                        mem_preload=struct.pack('<I', 0)*32 +
                                    struct.pack(f'<{n}i', *sel))
    ok = err is None
    got = list(struct.unpack_from(f'<{n}i', k.mem, 0)) if ok else []
    exp = [107 if s > 0 else 207 for s in sel]
    check('T3 divergence/reconvergence vs serial reference', ok and got == exp,
          '' if ok and got == exp else f'got[:6]={got[:6]} err={err}')

def t4_barrier():
    k, err = run_kernel(BARRY, grid_x=2, args_packed=struct.pack('<II', 0, 0),
                        mem_size=1 << 12)
    ok = err is None
    check('T4 BAR.WG release across 2 wavefronts', ok, f'err={err}')

def t5_beats():
    n = 32
    args = struct.pack('<IIIIII', 0, 0, n*4, 0, 2*n*4, 0)
    preload = struct.pack(f'<{2*n}f', *([float(i) for i in range(n)] +
                                        [float(7 - i) for i in range(n)]))
    outs = {}
    for L in (4, 8, 16, 32):
        k, err = run_kernel(ADD, grid_x=1, args_packed=args, simd_lanes=L,
                            mem_preload=preload)
        outs[L] = None if err else bytes(k.mem[2*n*4:2*n*4+n*4])
    ok = all(v is not None for v in outs.values()) and \
         len({outs[4], outs[8], outs[16], outs[32]}) == 1
    check('T5 INV-025 beat equivalence SIMD_LANES∈{4,8,16,32}', bool(ok))

def t6_mask_edge():
    n_valid = 20
    args = struct.pack('<III', 0, 0, n_valid)
    k, err = run_kernel(MASKEDGE, grid_x=1, args_packed=args)
    ok = err is None
    got = list(struct.unpack_from('<32i', k.mem, 0)) if ok else []
    exp = [1 if i < n_valid else -1 for i in range(32)]
    check('T6 partial-wavefront mask edges (INV-002/016)', ok and got == exp,
          '' if ok and got == exp else f'got={got} err={err}')

def t7_checksum():
    asm = assemble(ADD)
    fd, path = tempfile.mkstemp(suffix='.sgp1'); os.close(fd)
    emit_sgp1(asm, path)
    blob = bytearray(open(path, 'rb').read())
    blob[64] ^= 0xFF                              # corrupt first code byte
    open(path, 'wb').write(blob)
    from scigpu_defs import read_sgp1
    try:
        read_sgp1(path)
        caught = False
    except AssertionError as e:
        caught = 'checksum' in str(e).lower()
    finally:
        os.unlink(path)
    check('T7 SGP1 checksum tamper detection (INV-022)', caught)

def main():
    print('=' * 60)
    print('SciGPU M1 regression — golden ISA simulator')
    print('=' * 60)
    t1_vector_add()
    t2_saxpy()
    t3_divergence()
    t4_barrier()
    t5_beats()
    t6_mask_edge()
    t7_checksum()
    print('-' * 60)
    verdict = 'PASS' if not FAIL else 'FAIL'
    print(f'REGRESSION RESULT: {verdict} ({len(PASS)} passed, {len(FAIL)} failed)')
    if FAIL:
        print('FAILED:', ', '.join(FAIL))
        sys.exit(1)

if __name__ == '__main__':
    main()
