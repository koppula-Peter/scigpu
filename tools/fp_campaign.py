#!/usr/bin/env python3
"""M7 FP differential campaign (phase 3).

Generates structured random float kernels:
  - VGPR seeds drawn from exponent-bucketed classes (normals wide/narrow,
    near-subnormal, subnormal, zeros) with random signs
  - VF_ADD/VF_SUB/VF_MUL + V_CVT.F32.I32/V_CVT.I32_F32 bodies
  - optional divergence: VCMP-guarded CBRANCH_IF around some FP writes
Differential vs golden (full final state + retire stream). NaN/Inf operand
patterns are excluded at generation (canonical-NaN payload semantics are an
FP-001 milestone item, not an M7 gate item).
"""
import os, sys, struct, random, subprocess, shutil, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
sys.path.insert(0, os.path.join(ROOT, 'verification', 'm5'))
from golden_trace_m5 import prep

def f2b(f): return struct.unpack('<I', struct.pack('<f', f))[0]

def rand_fp_bits(rng, cls):
    """Return 32-bit pattern; never NaN/Inf (exp field != 255)."""
    while True:
        if cls == 'normal_wide':      # ~1e-30 .. 1e30
            e = rng.randint(8, 231)
        elif cls == 'normal_small':   # ~1e-38 .. 1e-20 region incl. subnormal edge
            e = rng.randint(0, 110)
        elif cls == 'near_sub':       # exp field 0..3 -> subnormals & min normals
            e = rng.randint(0, 3)
        elif cls == 'subnormal':
            e = 0
        else:                         # zeros / tiny
            e = rng.choice([0, 0, 1])
        m = rng.getrandbits(23)
        s = rng.getrandbits(1)
        bits = (s << 31) | (e << 23) | m
        if ((bits >> 23) & 0xFF) != 0xFF:
            return bits

def gen_kernel(seed):
    """Return (asm_text, vgpr_init triples, n_vgpr_used)."""
    rng = random.Random(seed)
    classes = ['normal_wide', 'normal_small', 'near_sub', 'subnormal', 'zeros']
    va, vb = rng.sample(classes, 2)
    a0 = rand_fp_bits(rng, va)
    b0 = rand_fp_bits(rng, vb)
    # V_MOVI immediates are sign-extended 16-bit: bit15=1 forms 0xFFFFxxxx =
    # always a NaN pattern. Keep bit15=0 so seeded constants stay finite
    # (RTL canonicalizes NaN payloads; golden preserves them -> never mix).
    imm_f = rand_fp_bits(rng, rng.choice(classes)) & 0x7FFF

    lines = [
        '.reg vgpr_count=16 sgpr_count=24',
        '.kern fp%d args=(out:PTR)' % seed,
        'fp%d:' % seed,
        '  V_LLANE v1',
        # seed v4 with lane-varying floats: cvt(lane) scaled by a constant bit pattern
        '  V_CVT.F32.I32 v4, v1',
        '  V_MOVI v6, %d' % (imm_f & 0xFFFF),
    ]
    # per-lane seeds via vgpr_init on v5/v6 lanes then a broadcast blend
    vgpr_init = []
    for l in range(32):
        if rng.random() < 0.75:
            vgpr_init.append((5, l, rand_fp_bits(rng, va)))
        if rng.random() < 0.75:
            vgpr_init.append((6, l, rand_fp_bits(rng, vb)))
    vgpr_init.append((7, 0, a0))
    vgpr_init.append((7, 1, b0))

    ops = []
    n_ops = rng.randint(4, 9)
    dst_pool = [3] + list(range(10, 15))
    for i in range(n_ops):
        op = rng.choice(['FADD', 'FSUB', 'FMUL', 'FMUL', 'FMA', 'I2F', 'F2I'])
        vd = rng.choice(dst_pool)
        if op == 'FMA':
            lines.append('  V_FMA.F32 v%d, v%d, v%d, v%d' % (
                vd, rng.choice([4,5,6,7]), rng.choice([4,5,6,7]), rng.choice([4,5,6,7])))
        elif op in ('FADD', 'FSUB', 'FMUL'):
            vs0 = rng.choice([4, 5, 6, 7])
            vs1 = rng.choice([4, 5, 6, 7])
            mnem = {'FADD': 'V_ADD.F32', 'FSUB': 'V_SUB.F32', 'FMUL': 'V_MUL.F32'}[op]
            lines.append('  %s v%d, v%d, v%d' % (mnem, vd, vs0, vs1))
        elif op == 'I2F':
            lines.append('  V_CVT.F32.I32 v%d, v%d' % (vd, rng.choice([1, 4])))
        else:
            lines.append('  V_CVT.I32.F32 v%d, v%d' % (vd, rng.choice([5, 6, 7])))
        ops.append(op)

    # divergence wrapper: predicated compare then CBRANCH over one FP write
    if rng.random() < 0.5:
        lines += [
            '  V_CMP_GT p5, v1, v7',
            '  CBRANCH_IF p5, FPE, FPM',
            '    V_MUL.F32 v14, v5, v6',
            '    S_BRA FPM',
            '  FPE:',
            '    V_ADD.F32 v14, v5, v6',
            '  FPM:',
            '    RECONV',
        ]
    lines.append('  RET_KERNEL_WF')
    return '\n'.join(lines), vgpr_init

def run_seed(seed, tb):
    asm, init = gen_kernel(seed)
    d = '/tmp/opencode/fpcamp/s%d' % seed
    shutil.rmtree(d, ignore_errors=True)
    try:
        prep(d, asm, simd_lanes=8, vgpr_init=init)
    except Exception as e:
        return 'skip', str(e)
    try:
        r = subprocess.run([tb, 'diff', d], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return 'fail', 'timeout'
    if r.returncode != 0:
        keep = os.path.join(ROOT, 'reports/evidence/m7/failures', 'fp%d' % seed)
        os.makedirs(keep, exist_ok=True)
        for fn in os.listdir(d):
            shutil.copy(os.path.join(d, fn), keep)
        return 'fail', r.stdout[-600:]
    return 'pass', ''

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    L = sys.argv[2] if len(sys.argv) > 2 else '8'
    tb = os.path.join(ROOT, 'build', 'm5_l%s_d32' % L, 'Vscigpu_m5_top')
    os.makedirs('/tmp/opencode/fpcamp', exist_ok=True)
    fails = ran = 0
    for seed in range(n):
        st, msg = run_seed(seed, tb)
        if st == 'fail':
            fails += 1
            print('[FAIL] fp seed %d\n%s' % (seed, msg), flush=True)
        elif st == 'pass':
            ran += 1
        if (seed + 1) % 50 == 0:
            print('... %d/%d fp seeds, fails=%d' % (seed + 1, n, fails), flush=True)
    print('FP CAMPAIGN: ran=%d fails=%d' % (ran, fails))
    return 1 if fails else 0

if __name__ == '__main__':
    sys.exit(main())
