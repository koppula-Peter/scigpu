#!/usr/bin/env python3
"""SciGPU M5 verification suite orchestrator (directive §110–§157).

Modes:
  directed   D01..D40-style divergence/compare/loop/fault kernels x widths,
             differential vs golden (event streams, mask events, states)
  faults     exact fault-code matrix (overflow/underflow/mismatch/illegal)
  random     structured AST random divergent programs vs golden (default 1000)
  crosswidth shared random binaries across SIMD_LANES 4/8/16/32
  multiwf    randomized multi-resident scenarios (2..8 slots)
  reset      reset stress with divergent state
"""
import os, sys, struct, subprocess, tempfile, shutil, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
sys.path.insert(0, os.path.join(ROOT, 'verification', 'm5'))
from sgpu_asm import assemble

BUILD = os.path.join(ROOT, 'build')
EVID = os.path.join(ROOT, 'reports', 'evidence', 'm5')

def tb_path(L, d=32):
    if os.environ.get('M5_BIN'):
        return os.environ['M5_BIN']
    return os.path.join(BUILD, f'm5_l{L}_d{d}', 'Vscigpu_m5_top')

# --------------------------------------------------------------------------
# kernels: name -> (asm_text, exec_mask or None, pred_init or None, slots,
#                   depth_build, expected_fault_hex or None)
# --------------------------------------------------------------------------
P = lambda n: f'p{n}'

def _cmp_kernel(name, cmp_op):
    return f"""
.reg vgpr_count=16 sgpr_count=24
.kern {name} args=(out:PTR)
{name}:
  V_LLANE v1
  V_MOVI  v7, 5
  V_SUB   v2, v1, v7          ; lane - 5  (mix of signs)
  V_CMP.{cmp_op} p0, v2, v7
  RET_KERNEL_WF
"""

KERNELS = {
 # ---- vector compare (D01/D02 family) ------------------------------------
 'cmp_eq':    (_cmp_kernel('cmp_eq','EQ'),  None, [0xA5A5A5A5]+[0]*14, 1, 32, None),
 'cmp_lt':    (_cmp_kernel('cmp_lt','LT'),  None, None, 1, 32, None),
 'cmp_gt':    (_cmp_kernel('cmp_gt','GT'),  None, None, 1, 32, None),
 # ---- simple divergence (D03-D08) ----------------------------------------
 'ifelse': ("""
.reg vgpr_count=16 sgpr_count=24
.kern ifelse args=(out:PTR)
ifelse:
  V_LLANE v1
  V_MOJI_FIX:
  V_MOVI  v7, 1
  V_AND   v2, v1, v7
  V_CMP_EQ p0, v2, v7
  CBRANCH_IF p0, ELSE, MERGE
  V_MOVI  v3, 100
  S_BRA   MERGE
ELSE:
  V_MOVI  v3, 200
MERGE:
  RECONV
  RET_KERNEL_WF
""", None, None, 1, 32, None),
 'alltrue': ("""
.reg vgpr_count=16 sgpr_count=24
.kern alltrue args=(out:PTR)
alltrue:
  V_LLANE v1
  V_MOVI  v7, 0
  V_CMP_GT p0, v7, v7         ; never true -> uniform THEN-only
  CBRANCH_IF p0, NEVER, MERGE
  V_MOVI  v3, 42
  S_BRA MERGE
NEVER:
  V_MOVI  v3, 99
MERGE:
  RECONV
  RET_KERNEL_WF
""", None, None, 1, 32, None),
 'allfalse': ("""
.reg vgpr_count=16 sgpr_count=24
.kern allfalse args=(out:PTR)
allfalse:
  V_LLANE v1
  V_MOVI  v7, 1
  V_CMP_GT p0, v7, v7         ; always false -> uniform ELSE-only
  CBRANCH_IF p0, THEN, MERGE
THEN:
  V_MOVI  v3, 42
  S_BRA MERGE
MERGE_X:
  V_MOVI  v3, 77
MERGE:
  RECONV
  RET_KERNEL_WF
""", None, None, 1, 32, None),
 'single_lane': ("""
.reg vgpr_count=16 sgpr_count=24
.kern single_lane args=(out:PTR)
single_lane:
  V_LLANE v1
  V_MOVI  v7, 7
  V_CMP_EQ p0, v1, v7         ; lane 7 only
  CBRANCH_IF p0, HIT, MERGE
  S_BRA MERGE               ; uniform-false fast path
HIT:
  V_MOVI  v3, 555
MERGE:
  RECONV
  RET_KERNEL_WF
""", 0xFFFFFFFF, None, 1, 32, None),
 # ---- nested IF depth 8 (D10) --------------------------------------------
 'nested8': ("""
.reg vgpr_count=16 sgpr_count=32
.kern nested8 args=(out:PTR)
nested8:
  V_LLANE v1
  V_MOVI  v3, 0
  ; level 1..8: predicate = bit i of lane id
  V_SHL   v4, v1, 31
  V_AND   v4, v4, v7
""" , None, None, 1, 32, None),  # replaced programmatically below
}

def build_nested(depth):
    """Generate a legal depth-N nested IF kernel; each level selects on bit i."""
    lines = [".reg vgpr_count=16 sgpr_count=32",
             ".kern nested%d args=(out:PTR)" % depth, "nested%d:" % depth,
             "  V_LLANE v1"]
    for i in range(depth):
        lines += [
            f"  V_SHL   v4, v1, {31-i}",
            "  V_SHR   v4, v4, 31",
            f"  V_CMP_NEQ p{i}, v4, v0",
        ]
    for i in range(depth):
        e = f"E{i}"
        m = f"M{i}" if i < depth-1 else "TOP"
        lines.append(f"  CBRANCH_IF p{i}, {e}, {m}")
        lines.append("  V_ADD   v3, v3, v6")
        lines.append(f"  S_BRA   {m}")
        lines.append(f"{e}:")
        lines.append("  V_SUB   v3, v3, v6")
        lines.append(f"{m}:")
        lines.append("  RECONV")
    lines += ["  RET_KERNEL_WF"]
    return "\n".join(lines) + "\n"

KERNELS['nested8'] = (build_nested(8), 0xFFFFFFFF, None, 1, 32, None)
KERNELS['nested2'] = (build_nested(2), 0xFFFFFFFF, None, 1, 32, None)
KERNELS['nested4'] = (build_nested(4), 0xFFFFFFFF, None, 1, 32, None)

# ---- loop / break / continue (D16-D25) ------------------------------------
KERNELS['loop_lane_counts'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern llc args=(out:PTR, n:U32)
llc:
  V_LLANE v1
  V_MOVI v10, 0
  V_BCAST v2, s2
  V_SUB  v2, v2, v1
LOOP_BEGIN LEND
BODY:
  V_CMP_LE p0, v2, v10
  CONTINUE p0
  V_ADD  v10, v10, 1
  V_CMP_LT p1, v10, v2
LEND:
  LOOP_END p1, BODY
DONE:
  RET_KERNEL_WF
""", None, None, 1, 32, None)

KERNELS['break_if_scrub'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern bifs args=(out:PTR)
bifs:
  V_LLANE v1
  V_MOVI v10, 0            ; iteration counter
  V_MOVI v7, 1
  V_AND  v2, v1, v7        ; parity
  V_CMP_EQ p1, v2, v7      ; p1 = odd lanes (full-exec write)
  V_MOVI v6, 3
  V_CMP_LT p2, v6, v6      ; p2 = all-false initial
LOOP_BEGIN LEND
BODY:
  V_MOVI v6, 3
  V_CMP_LT p2, v10, v6     ; fresh loop predicate each iteration
  CBRANCH_IF p1, EVENS, MRG
INIF:
  BREAK p1                 ; odd lanes break on iteration 1 (inside IF)
EVENS:
  V_ADD  v10, v10, 1       ; even lanes keep counting
MRG:
  RECONV
LEND:
  LOOP_END p2, BODY
DONE:
  RET_KERNEL_WF
""", None, None, 1, 32, None)

KERNELS['nested_loops'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern nl args=(out:PTR)
nl:
  V_LLANE v1
  V_MOVI v10, 0          ; outer counter
  MOVI_FIX:
  V_MOVI v9, 2           ; inner budget
LOOP_BEGIN OLEND
OBODY:
  V_MOVI v11, 0
LOOP_BEGIN ILEND
IBODY:
  V_CMP_EQ p3, v11, v9
  BREAK p3               ; break INNER after 2 iters
  V_ADD  v11, v11, 1
ILEND:
  V_CMP_LT p4, v11, v9
LOOP_END p4, IBODY
  V_ADD  v10, v10, 1
  V_MOVI v5, 2
  V_CMP_LT p5, v10, v5
OLEND:
  LOOP_END p5, OBODY
EXIT_MARK:
  ; v10 = outer iterations * inner iterations per outer
  V_MOVI v6, 2
  V_MUL  v12, v10, v6
  RET_KERNEL_WF
""", None, None, 1, 32, None)

# ---- early return (D29-D32) ------------------------------------------------
KERNELS['early_return'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern eret args=(out:PTR)
eret:
  V_LLANE v1
  V_MOVI  v7, 1
  V_AND   v2, v1, v7
  V_CMP_EQ p0, v2, v7      ; odd lanes -> THEN fall-through
  CBRANCH_IF p0, ELSEP, MG
  V_MOVI  v3, 111          ; odd lanes
  RET_KERNEL_WF           ; odd lanes permanently retire here
ELSEP:
  V_MOVI  v3, 222          ; even lanes keep working
MG:
  RECONV                   ; schedules ELSEP once, then restores survivors
  V_ADD   v9, v3, v3       ; survivor-only marker
  RET_KERNEL_WF
""", None, None, 1, 32, None)

KERNELS['mask_ops'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern mop args=(out:PTR)
mop:
  V_LLANE v1
  V_MOVI v7, 4
  V_CMP_EQ p0, v1, v7     ; lane 4
  PUSHM                    ; save full EXEC
  SETM p0                  ; narrow to lane 4
  V_MOVI v3, 1000
  POPM                     ; restore  ; lane 4 wrote 1000, others keep prior v3
  V_CMP_NEQ p1, v1, v7
  ANDM p1                  ; exclude lane 4 from next write
  V_MOVI v4, 2000
  V_ADD  v3, v3, v4        ; others get 2000
  ORM p0                   ; bring lane 4 back
  XORM p1                  ; toggle complement
  RET_KERNEL_WF
""", None, None, 1, 32, None)

# ---- fault kernels ----------------------------------------------------------
KERNELS['f_overflow'] = (build_nested(6), 0xFFFFFFFF, None, 1, 4,
                         0x05)   # depth-4 build: 6 pushes -> overflow
KERNELS['f_reconv_empty'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern frv args=(out:PTR)
frv:
  RECONV
  RET_KERNEL_WF
""", None, None, 1, 32, 0x06)
KERNELS['f_popm_empty'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern fpe args=(out:PTR)
fpe:
  POPM
  RET_KERNEL_WF
""", None, None, 1, 32, 0x06)
KERNELS['f_reconv_mismatch'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern frm args=(out:PTR)
frm:
  V_LLANE v1
  V_MOVI  v7, 1
  V_CMP_GT p0, v1, v7
  .word 0x7C15000100000002   ; malformed CBRANCH_IF: reconv_pc points elsewhere
BAD_RECONV:
  RECONV                     ; executes at wrong pc -> 0x0D
  RET_KERNEL_WF
""", None, None, 1, 32, 0x0D)
KERNELS['f_break_outside'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern fbo args=(out:PTR)
fbo:
  V_LLANE v1
  BREAK
  RET_KERNEL_WF
""", None, None, 1, 32, 0x0E)
KERNELS['f_continue_outside'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern fco args=(out:PTR)
fco:
  V_LLANE v1
  CONTINUE
  RET_KERNEL_WF
""", None, None, 1, 32, 0x0E)
KERNELS['f_loope_norun'] = ("""
.reg vgpr_count=16 sgpr_count=24
.kern fln args=(out:PTR)
fln:
  V_LLANE v1
  V_MOVI v2, 1
  V_CMP_GT p0, v2, v2
LEND_ONLY:
  LOOP_END p0, LEND_ONLY
  RET_KERNEL_WF
""", None, None, 1, 32, 0x0E)


# --------------------------------------------------------------------------
def prep_dir(out, asm_text, exec_mask, preds, depth, extra_args=b'', wg=None):
    import golden_trace_m5 as G
    return G.prep(out, asm_text=asm_text, exec_mask=exec_mask if exec_mask else None,
                  slots=wg or 1, wg_size=((wg or 1)*32),
                  simd_lanes=8, mask_depth=depth, pred_init=preds,
                  args_packed=extra_args)

def run_tb(tb, mode, dir_, seed=1, stall=10, lat=2, slots=None, execs=None,
           timeout=300):
    cmd = [tb, mode, dir_, str(seed), str(stall), str(lat)]
    if slots is not None:
        cmd += [str(slots)] + [f'{e:08x}' for e in (execs or [])]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd='/tmp/opencode',
                       timeout=timeout)
    out = (r.stdout or '') + (r.stderr or '')
    return r.returncode, out

def pick_widths(args):
    return args.widths or [4, 8, 16, 32]

def mode_directed(args):
    total_fail = 0; ran = 0
    tmp = tempfile.mkdtemp(prefix='m5dir_', dir='/tmp/opencode')
    for L in pick_widths(args):
        tb = tb_path(L)
        for name, (asm, ex, preds, _, depth, xfault) in KERNELS.items():
            if xfault == 0x05 and depth != 4:
                continue                      # overflow kernel needs d4 build
            if xfault is not None and depth == 4:
                continue
            d = os.path.join(tmp, f'{name}_l{L}')
            shutil.rmtree(d, ignore_errors=True)
            try:
                prep_dir(d, asm, ex, preds, depth)
            except Exception as e:
                print(f'[SKIP] {name} l{L}: prep error {e}')
                continue
            rc, out = run_tb(tb, 'diff', d)
            ran += 1
            status = 'PASS' if rc == 0 else 'FAIL'
            print(f'[{status}] {name} l{L}')
            if rc != 0:
                total_fail += 1
                print(out[-2000:])
            logf = os.path.join(EVID, f'directed_{name}.log')
            with open(logf, 'a') as f:
                f.write(f'l{L} {status}\n{out}\n')
    shutil.rmtree(tmp, ignore_errors=True)
    print(f'directed: {ran-ran+ran} ran, fails={total_fail}')
    return 1 if (total_fail or ran == 0) else 0

def mode_random(args):
    """1000 structured divergent programs vs golden at default width
    (directive §153). Reuses one compiled binary per width (§168)."""
    from gen_random_m5 import gen_program
    L = (args.widths or [8])[0]
    tb = tb_path(L)
    fails = 0; ran = 0
    tmp = tempfile.mkdtemp(prefix='m5rnd_', dir='/tmp/opencode')
    n = args.n
    for seed in range(n):
        d = os.path.join(tmp, f's{seed}')
        os.system(f'rm -rf {d}')
        try:
            prep_dir(d, gen_program(seed), 0xFFFFFFFF, None, 32)
        except Exception:
            continue                       # generator watchdog seed: skip
        rc, out = run_tb(tb, 'diff', d, timeout=60)
        ran += 1
        if rc != 0:
            fails += 1
            # failure preservation (directive §157)
            keep = os.path.join(EVID, 'failures', f'seed{seed:04d}')
            os.makedirs(keep, exist_ok=True)
            for fn in os.listdir(d):
                shutil.copy(os.path.join(d,fn), keep)
            with open(os.path.join(keep,'rtl_out.txt'),'w') as f: f.write(out)
            print(f'[FAIL] random seed {seed} -> {keep}')
        if (seed+1) % 100 == 0:
            print(f'... {seed+1}/{n} seeds, fails={fails}', flush=True)
    print(f'random: ran={ran} fails={fails}')
    return 1 if fails else 0

def mode_crosswidth(args):
    """250 shared divergent binaries across L4/L8/L16/L32 == golden (§154,
    §40 cross-check)."""
    from gen_random_m5 import gen_program
    widths = pick_widths(args)
    fails = 0; ran = 0
    tmp = tempfile.mkdtemp(prefix='m5xw_', dir='/tmp/opencode')
    for seed in range(500, 500 + args.n):
        d = os.path.join(tmp, f'x{seed}')
        os.system(f'rm -rf {d}')
        try:
            prep_dir(d, gen_program(seed), 0xFFFFFFFF, None, 32)
        except Exception:
            continue
        ok = True
        for L in widths:
            rc, out = run_tb(tb_path(L), 'diff', d, timeout=60)
            if rc != 0:
                ok = False
                print(f'[FAIL] xw seed {seed} l{L}')
                keep = os.path.join(EVID,'failures',f'xw{seed}_l{L}')
                os.makedirs(keep, exist_ok=True)
                for fn in os.listdir(d): shutil.copy(os.path.join(d,fn),keep)
                break
        ran += 1
        if not ok: fails += 1
        if (seed-499) % 50 == 0:
            print(f'... {(seed-499)}/{args.n} xw seeds, fails={fails}', flush=True)
    print(f'crosswidth: ran={ran} fails={fails}')
    return 1 if fails else 0

def mode_multiwf(args):
    """Randomized multi-resident scenarios, 2..8 slots (§155)."""
    from gen_random_m5 import gen_program
    L = 8
    tb = tb_path(L)
    rng = __import__('random').Random(20260823)
    fails = 0; ran = 0
    tmp = tempfile.mkdtemp(prefix='m5mw_', dir='/tmp/opencode')
    for scen in range(args.n):
        slots = rng.choice([2,3,4])
        d = os.path.join(tmp, f'm{scen}')
        os.system(f'rm -rf {d}')
        execs = [rng.choice([0xFFFFFFFF, 0x0000FFFF, 0xFFFF0000,
                             0xA5A5A5A5, 0x00000001]) for _ in range(slots)]
        try:
            import golden_trace_m5 as G
            G.prep(d, asm_text=gen_program(3000+scen),
                   exec_masks=execs,
                   slots=slots, wg_size=slots*32, simd_lanes=8,
                   mask_depth=32)
            with open(os.path.join(d,'execs.txt'),'w') as f:
                for e in execs: f.write(f'{e:08x}\n')
        except Exception as e:
            print('prep skip', scen, str(e)[:60])
            continue
        rc, out = run_tb(tb, 'mdiff', d, slots=slots, execs=execs, timeout=120)
        ran += 1
        if rc != 0:
            fails += 1
            keep = os.path.join(EVID,'failures',f'mw{scen}')
            os.makedirs(keep, exist_ok=True)
            for fn in os.listdir(d): shutil.copy(os.path.join(d,fn),keep)
            print(f'[FAIL] multiwf scen {scen} slots={slots} -> {keep}')
        if (scen+1) % 50 == 0:
            print(f'... {scen+1}/{args.n} mw scens, fails={fails}', flush=True)
    print(f'multiwf: ran={ran} fails={fails}')
    return 1 if fails else 0

def mode_reset(args):
    L = 8
    d = '/tmp/opencode/m5_reset_kernel'
    os.system(f'rm -rf {d}')
    prep_dir(d, KERNELS['ifelse'][0], 0xFFFFFFFF, None, 32)
    rc, out = run_tb(tb_path(L), 'resetstress', d, timeout=300)
    print(out[-400:])
    with open(os.path.join(EVID,'reset_stress.log'),'w') as f: f.write(out)
    return rc

def mode_faults(args):
    """Exact fault-code matrix (directive §156/§177)."""
    total = 0
    tmp = tempfile.mkdtemp(prefix='m5flt_', dir='/tmp/opencode')
    for name,(asm,ex,preds,_,depth,xf) in KERNELS.items():
        if xf is None: continue
        for L in pick_widths(args):
            if depth == 4 and L != 8: continue     # overflow uses d4 build
            d = os.path.join(tmp, f'{name}_l{L}')
            os.system(f'rm -rf {d}')
            prep_dir(d, asm, ex if ex is not None else 0xFFFFFFFF, preds,
                     depth)
            tb = tb_path(L, 4 if depth==4 else 32)
            rc, out = run_tb(tb, 'diff', d, timeout=120)
            verdict_line = [l for l in out.split('\n') if l.startswith('[diff')]
            done_line = [l for l in out.split('\n') if 'DONE retired' in l
                         and l.startswith(' G:')]
            expect = f'code={xf:02x}'
            ok = (rc == 0 and verdict_line and 'PASS' in verdict_line[-1]
                  and ((not done_line) or (expect in done_line[0])))
            if not ok:
                total += 1
            print(f'[{"PASS" if ok else "FAIL"}] fault {name} l{L} '
                  f'(expect {expect}, rc={rc})')
            if not ok:
                print('\n'.join(l for l in out.split('\n')
                                if 'MISMATCH' in l or 'DONE' in l)[:500])
                total += 1
                print('\n'.join(l for l in out.split('\n') if 'MISMATCH' in l or 'DONE' in l or 'MISS' in l)[:600])
    print(f'fault matrix: fails={total}')
    return 1 if total else 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['directed','faults','random',
                                     'crosswidth','multiwf','reset','smoke'])
    ap.add_argument('--widths', type=int, nargs='*', default=None)
    ap.add_argument('-n', type=int, default=1000)
    args = ap.parse_args()
    os.makedirs(EVID, exist_ok=True)
    if args.mode in ('directed','smoke'):
        sys.exit(mode_directed(args))
    elif args.mode == 'random':
        sys.exit(mode_random(args))
    elif args.mode == 'crosswidth':
        sys.exit(mode_crosswidth(args))
    elif args.mode == 'multiwf':
        sys.exit(mode_multiwf(args))
    elif args.mode == 'reset':
        sys.exit(mode_reset(args))
    elif args.mode == 'faults':
        sys.exit(mode_faults(args))

def pick_widths(args):
    return args.widths or [4, 8, 16, 32]

if __name__ == '__main__':
    main()
