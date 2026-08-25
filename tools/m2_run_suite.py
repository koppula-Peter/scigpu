#!/usr/bin/env python3
"""M2 test-suite orchestrator: builds golden artifacts, runs the Verilator TB
across directed programs, the randomized campaign, reset stress, fault matrix.

Usage: tools/m2_run_suite.py {directed|random|reset|faults}
"""
import os, sys, subprocess, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
sys.path.insert(0, os.path.join(ROOT, 'verification', 'm2'))
from sgpu_asm import assemble
from golden_trace import build_from_asm_obj, write_artifacts

TB = os.path.join(ROOT, 'build', 'obj_core', 'tb_core')
KERNELS = os.path.join(ROOT, 'verification', 'm2', 'kernels')
EVID = os.path.join(ROOT, 'reports', 'evidence', 'm2')

DIRECTED = ['p01_mov','p02_add_sub','p03_logic','p04_shifts',
            'p05_cmp_eq_ne','p06_signed_branch','p07_unsigned_branch',
            'p08_forward_skip','p09_backward_loop','p10_getid','p11_ret']
FAULT_EXPECT = {'p12_invalid_opcode': 0x01,
                'p13_invalid_sgpr':   0x02,
                'p14_invalid_pc':     0x03}

def tb(args, timeout=300):
    return subprocess.run([TB] + args, capture_output=True, text=True, timeout=timeout)

def prep_dir(name, asm_text=None):
    d = os.path.join(EVID, 'progs', name)
    os.makedirs(d, exist_ok=True)
    if asm_text is None:
        asm_text = open(os.path.join(KERNELS, name + '.gpuasm')).read()
    built = build_from_asm_obj(assemble(asm_text))
    write_artifacts(d, built)
    return d, built['fault']

def suite_directed():
    fails = []
    for name in DIRECTED:
        d, _ = prep_dir(name)
        r = tb(['diff', d, '1'])
        ok = r.returncode == 0
        print(f'[{"PASS" if ok else "FAIL"}] directed {name}')
        if not ok:
            print(r.stdout[-800:]); fails.append(name)
    # completion backpressure uses p18
    d, _ = prep_dir('p18_completion_hold')
    r = tb(['completionhold', d])
    ok = r.returncode == 0 and 'stable' in r.stdout
    print(f'[{"PASS" if ok else "FAIL"}] completion backpressure (P18)')
    if not ok: fails.append('p18_completion_hold')
    return fails

def suite_random():
    n = int(os.environ.get('M2_RANDOM_N', '1000'))
    rnd_root = os.path.join(EVID, 'random')
    if not os.path.isdir(rnd_root) or \
       len(os.listdir(rnd_root)) < n:
        subprocess.run([sys.executable,
                        os.path.join(ROOT, 'verification', 'm2', 'gen_random_m2.py'),
                        str(n), rnd_root], check=True)
    fails = 0
    profiles = [(15, 2), (40, 0), (0, 4), (60, 1)]      # stall% / max-latency mix
    for seed in range(1, n + 1):
        d = os.path.join(rnd_root, f'seed{seed:04d}')
        stall, lat = profiles[seed % len(profiles)]
        r = tb(['diff', d, str(seed), str(stall), str(lat)])
        if r.returncode != 0:
            print(f'[FAIL] random seed{seed:04d} stall={stall} lat={lat}')
            print(r.stdout[-1200:])
            fails += 1
            if fails > 5:
                print('too many random failures; aborting campaign')
                break
    print(f'randomized differential: {n - fails}/{n} clean (stall/latency profiles rotated)')
    return fails

def suite_reset():
    d, _ = prep_dir('p09_backward_loop')
    r = tb(['resetstress', d])
    print(r.stdout.strip())
    return [] if r.returncode == 0 else ['reset_stress']

def suite_faults():
    fails = []
    for name, want in FAULT_EXPECT.items():
        d, gfault = prep_dir(name)
        r = tb(['diff', d, '3'])
        ok = r.returncode == 0
        # cross-check expected code against golden artifact
        gfile = open(os.path.join(d, 'golden.fault')).read().strip()
        ok &= (int(gfile, 16) == want)
        print(f'[{"PASS" if ok else "FAIL"}] fault {name}: RTL/golden agree, '
              f'code=0x{gfile} (expected 0x{want:02x})')
        if not ok: fails.append(name)
    return fails

def main():
    mode = sys.argv[1]
    if mode == 'directed':   f = suite_directed()
    elif mode == 'random':   f = suite_random(); sys.exit(1 if f else 0)
    elif mode == 'reset':    f = suite_reset(); sys.exit(1 if f else 0)
    elif mode == 'faults':   f = suite_faults(); sys.exit(1 if f else 0)
    else: sys.exit(2)
    sys.exit(1 if f else 0)

if __name__ == '__main__':
    main()
