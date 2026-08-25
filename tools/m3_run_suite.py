#!/usr/bin/env python3
"""M3 suite orchestrator: directed / width-equiv / random / reset / faults.

Runs the per-width Verilator binaries against golden artifacts.
"""
import os, sys, subprocess, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'verification', 'm3'))
from golden_trace_m3 import prep

WIDTHS = [4, 8, 16, 32]
EVID = os.path.join(ROOT, 'reports', 'evidence', 'm3')
K = os.path.join(ROOT, 'verification', 'm3', 'kernels')

def tb(width, args):
    exe = os.path.join(ROOT, f'build/m3_l{width}', 'tb_m3')
    return subprocess.run([exe]+args, capture_output=True, text=True)

# sidecars: exec / pred_init / vgpr_init sentinels
def sentinel_vgpr():
    return [(v, l, 0xA5000000 | (v << 8) | l)
            for v in range(8) for l in range(32)]

def sidecar_for(name):
    return _SIDECARS.get(name, {})

_SIDECARS = {
    'p02_movi_partial': dict(exec_mask=0x000F00F0,
        vgpr_init=[(3, l, 0xDEADBEEF | l) for l in range(32)]),
    'p10_zero_exec': dict(exec_mask=0),
    'p11_single_lane': dict(exec_mask=1 << 5),
    'p12_alt_mask': dict(exec_mask=0xAAAAAAAA),
    'p13_predication': dict(exec_mask=0xFFFF00FF,
        pred_init=[0xAAAAAAAA] + [0]*14),
}

def sha_words(d):
    h = hashlib.sha256()
    h.update(open(os.path.join(d,'prog.words.hex'),'rb').read())
    return h.hexdigest()

def suite_directed(fails):
    names = ['p01_llane','p02_movi_partial','p03_add','p04_inplace','p05_imm',
             'p06_shifts','p07_mul','p08_bcast','p09_mixed','p10_zero_exec',
             'p13_predication','p14_pred_bypass','p17_completion_hold',
             'p18_fetch_stall']
    for name in names:
        d = os.path.join(EVID,'progs',name)
        kw = dict(sidecar_for(name) or {})
        text = open(os.path.join(K,name+'.gpuasm')).read()
        prep(d, asm_text=text, **kw)
        for L in WIDTHS:
            r = tb(L, ['diff', d, '1'])
            ok = r.returncode == 0
            print(f'[{"PASS" if ok else "FAIL"}] {name} L={L}')
            if not ok:
                print(r.stdout[-600:]); fails.append((name,L))
    # single-lane sweep P11 across widths
    d = os.path.join(EVID,'progs','p11_single_lane')
    for lane in range(32):
        prep(d, asm_text=open(os.path.join(K,'p11_single_lane.gpuasm')).read(),
             exec_mask=(1 << lane), vgpr_req=8, sgpr_req=16)
        for L in WIDTHS:
            r = tb(L, ['diff', d, str(lane+1)])
            ok = r.returncode == 0
            if not ok:
                print(f'[FAIL] p11 lane={lane} L={L}'); print(r.stdout[-400:])
                fails.append(('p11',lane,L))
    print('[PASS] p11_single_lane sweep lanes 0..31 x widths' if not fails else '')

def suite_width_equiv(fails):
    d = os.path.join(EVID,'progs','wequiv')
    text = open(os.path.join(K,'p09_mixed.gpuasm')).read()
    built = prep(d, asm_text=text, exec_mask=0xF0F00F0F,
                 pred_init=[0xAAAAAAAA]+[0]*14,
                 vgpr_init=sentinel_vgpr(), vgpr_req=8, sgpr_req=24)
    sha = sha_words(d)
    print('binary sha256:', sha, '(identical words used for every width)')
    open(os.path.join(EVID,'width_binary_sha256.txt'),'w').write(
        sha+'  prog.words.hex (same file executed by L4/L8/L16/L32)\n')
    traces = {}
    for L in WIDTHS:
        r = tb(L, ['diff', d, '42', '25', '2'])
        if r.returncode:
            print(f'[FAIL] width-equiv L={L}'); print(r.stdout[-500:])
            fails.append(('wequiv',L))
        else:
            traces[L] = open(os.path.join(d,'rtl.trace')).read()
    vals = set(traces.values())
    if len(traces)==4 and len(vals)!=1:
        print('[FAIL] width-equivalence: retire traces differ across widths')
        fails.append(('wequiv-differs',))
    elif len(traces)==4:
        g = open(os.path.join(d,'golden.trace')).read()
        if g != traces[4]:
            print('[FAIL] width-equivalence vs GOLDEN'); fails.append(('wequiv-golden',))
        else:
            print('[PASS] width equivalence L4==L8==L16==L32==golden '
                  '(retire trace + full final state)')

def suite_random(fails):
    n = int(os.environ.get('M3_RANDOM_N','1000'))
    root = os.path.join(EVID,'random')
    sys.path.insert(0, os.path.join(ROOT,'verification','m3'))
    from gen_random_m3 import gen
    for seed in range(1, n+1):
        text, em, preds, vi = gen(seed)
        d = os.path.join(root, f'seed{seed:04d}')
        if not os.path.exists(os.path.join(d,'prog.words.hex')):
            prep(d, asm_text=text, exec_mask=em, pred_init=preds,
                 vgpr_init=vi, vgpr_req=8, sgpr_req=32)
        bad_local = False
        for L in WIDTHS:
            r = tb(L, ['diff', d, str(seed), str(15+(seed%30)), str(seed%4)])
            if r.returncode:
                print(f'[FAIL] seed{seed:04d} L={L}')
                print(r.stdout[-900:]); fails.append((seed,L)); bad_local=True
                break
        if seed % 200 == 0:
            print(f'... {seed}/{n} programs clean so far')
        if bad_local and os.environ.get('M3_STOP_ON_FAIL'):
            break
    print(f'randomized differential: {n-len(fails)}/{n} seeds clean '
          f'(x4 widths each = {(n-len(fails))*4} RTL executions)')

def suite_reset(fails):
    for L in WIDTHS:
        d = os.path.join(EVID,'progs','reset_p09')
        if not os.path.exists(os.path.join(d,'prog.words.hex')):
            prep(d, asm_text=open(os.path.join(K,'p09_mixed.gpuasm')).read(),
                 exec_mask=0xFFFFFFFF, vgpr_req=8, sgpr_req=24)
        r = tb(L, ['resetstress', d])
        ok = r.returncode==0
        print(f'[{"PASS" if ok else "FAIL"}] reset stress L={L}: {r.stdout.strip()[:60]}')
        if not ok: fails.append(('reset',L))

def suite_faults(fails):
    cases = {'p15_reg_bounds': None,      # v31 with declared vgpr_req=8 -> fault 02
             'p16_invalid_vmod': 0x01}
    # p15 needs small declared req: override meta via custom prep
    d = os.path.join(EVID,'progs','p15_reg_bounds')
    prep(d, asm_text=open(os.path.join(K,'p15_reg_bounds.gpuasm')).read(),
         vgpr_req=8, sgpr_req=64)
    for name, want in cases.items():
        dd = os.path.join(EVID,'progs',name)
        if name=='p15_reg_bounds':
            pass
        else:
            prep(dd, asm_text=open(os.path.join(K,name+'.gpuasm')).read(),
                 vgpr_req=8, sgpr_req=16)
        gf = int(open(os.path.join(dd,'golden.fault')).read().strip(),16)
        exp = want if want is not None else gf
        for L in [WIDTHS[0]]:
            r = tb(L, ['diff', dd, '1'])
            rtl_ok = r.returncode==0
            got = int(open(os.path.join(dd,'golden.fault')).read().strip(),16)
            ok = rtl_ok and got==exp and gf==exp
            print(f'[{"PASS" if ok else "FAIL"}] fault {name}: code=0x{got:02x} '
                  f'(expected 0x{exp:02x})')
            if not ok: fails.append((name,L))

def main():
    mode = sys.argv[1]
    fails = []
    if mode=='directed': suite_directed(fails)
    elif mode=='width':  suite_width_equiv(fails)
    elif mode=='random': suite_random(fails); sys.exit(1 if fails else 0)
    elif mode=='reset':  suite_reset(fails); sys.exit(1 if fails else 0)
    elif mode=='faults': suite_faults(fails); sys.exit(1 if fails else 0)
    else: sys.exit(2)
    if fails: print('FAILED:', fails); sys.exit(1)
    sys.exit(0)

if __name__=='__main__':
    main()
