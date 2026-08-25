#!/usr/bin/env python3
"""M5 golden-artifact preparation (differential oracle, directive §102/§158).

For a kernel + config produces under <out>:
  prog.words.hex     binary words
  meta.txt           exec / slots / mask_depth / vgpr_req / sgpr_req / n_wf
  pred.hex           P0..P14 initial values
  vgpr.hex           VGPR bootstrap triples (addr lane data)
  golden.trace       global retire trace (wfid-tagged; single-WF diff)
  golden.wf<k>.trace per-wavefront retire stream (multi-WF compare)
  golden.state       wf0 architectural dump (+LIVE/SP)
  golden.wf<k>.state per-slot dumps for multi-WF runs
  golden.masktrace   mask-control event stream (text)
  golden.fault       expected completion line: DONE retired= fault= pc=
"""
import os, sys, struct, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
sys.path.insert(0, os.path.join(ROOT, 'assembler'))
from sgpu_asm import assemble, emit_sgp1


def prep(out_dir, asm_text=None, exec_mask=0xFFFFFFFF, slots=1,
         wg_size=None, grid_x=1, simd_lanes=8, mask_depth=32,
         pred_init=None, vgpr_init=None, args_packed=b'', mem_preload=b'',
         exec_masks=None):
    os.makedirs(out_dir, exist_ok=True)
    asm = assemble(asm_text)
    fd, path = tempfile.mkstemp(suffix='.sgp1'); os.close(fd)
    emit_sgp1(asm, path)
    try:
        words = open(path, 'rb').read()
        code_words = len(asm['code']) // 8
        from simulator import Kernel
        k = Kernel(path, grid_x=grid_x,
                   wg_size=(wg_size if wg_size else slots * 32),
                   vgpr_req=max(asm['n_regs'][0], 16),
                   sgpr_req=max(asm['n_regs'][1], 24),
                   smem_req=asm['smem'], simd_lanes=simd_lanes,
                   args_packed=args_packed, trace=True,
                   exec_mask=exec_mask, pred_init=pred_init,
                   vgpr_init=vgpr_init, mask_stack_depth=mask_depth,
                   exec_masks=exec_masks)
        k.mem[0:len(mem_preload)] = mem_preload
        init_exec = (exec_masks[0] if exec_masks else k.wfs[0].exec_mask)
        from simulator import SimFault
        k.run(isolate_faults=True)
        fault = None
        for wf in k.wfs:
            if wf.faulted is not None:
                fault = (wf.faulted[0], wf.faulted[1])
                break
        # ---- artifacts ----
        with open(f'{out_dir}/prog.words.hex', 'w') as f:
            for i in range(code_words):
                w = struct.unpack_from('<Q', asm['code'], i * 8)[0]
                f.write(f'{w:016x}\n')
        n_wf = k.n_wf_per_wg * grid_x
        with open(f'{out_dir}/meta.txt', 'w') as f:
            f.write(f'exec={init_exec:08x}\nslots={slots}\n'
                    f'mask_depth={mask_depth}\n'
                    f'vgpr_req={max(asm["n_regs"][0], 16)}\n'
                    f'sgpr_req={max(asm["n_regs"][1], 24)}\n'
                    f'n_wf={n_wf}\n')
        preds = pred_init if pred_init is not None else [0] * 15
        with open(f'{out_dir}/pred.hex', 'w') as f:
            for i in range(15):
                f.write(f'{(preds[i] & 0xFFFFFFFF):08x}\n')
        with open(f'{out_dir}/vgpr.hex', 'w') as f:
            for (va, vl, vd) in (vgpr_init or []):
                f.write(f'{va} {vl} {vd & 0xFFFFFFFF:08x}\n')
        with open(f'{out_dir}/sgpr.hex', 'w') as f:
            for wd in k.args_sgpr:
                f.write(f'{wd & 0xFFFFFFFF:08x}\n')

        def trace_line(t):
            return (f"{t['pc']:016x} {t['insn']:016x} {t['sgpr_we']&1:x} "
                    f"{t['sgpr_addr']:02x} {t['sgpr_wdata']:08x} "
                    f"{t['Z']:x} {t['N']:x} {t['C']:x} {t['V']:x} {t['scc']:x} "
                    f"{t['branch_taken']&1:x} "
                    f"{t['next_pc']&0xFFFFFFFFFFFFFFFF:016x} "
                    f"{t['exec_mask']:08x} {t['pred']&0xF:x} "
                    f"{t['effective_mask']:08x} {t['vgpr_we']&1:x} "
                    f"{t['vgpr_addr']:02x}")

        CTRL_OPS = {0x7C0,0x7C1,0x7C2,0x7C3,0x7C4,0x7C5,0x7C6,0x7C7,
                    0x7C8,0x7C9,0x7CA,0x7CB,0x7CF}
        def ev_line(t):
            return '%x %016x %x %02x %08x %08x' % (
                t['pc'], t['insn'], t['sgpr_we'] & 1, t['sgpr_addr'],
                t['sgpr_wdata'], t['exec_mask'])
        # non-control architectural event stream (exec-after included)
        ev = {}
        for t in k.trace:
            if (t['insn'] >> 52) not in CTRL_OPS:
                ev.setdefault(t['wid'], []).append(ev_line(t))
        with open(f'{out_dir}/golden.ev', 'w') as f:
            for t in k.trace:
                if (t['insn'] >> 52) not in CTRL_OPS:
                    f.write(f"{t['wid']} " + ev_line(t) + '\n')
        for wid in range(n_wf):
            with open(f'{out_dir}/golden.wf{wid}.ev', 'w') as f:
                for ln in ev.get(wid, []):
                    f.write(ln + '\n')
        per = {}
        for t in k.trace:
            per.setdefault(t['wid'], []).append(trace_line(t))
        for wid in range(n_wf):
            with open(f'{out_dir}/golden.wf{wid}.trace', 'w') as f:
                for ln in per.get(wid, []):
                    f.write(ln + '\n')

        # completion lines per wavefront (directive 158 comparison keys)
        for wid in range(n_wf):
            wf = k.wfs[wid]
            fl = 0; fc = 0; pc = 0
            if wf.faulted is not None:
                fc, _msg = wf.faulted
                fl = 1
                pc = wf.pc
            n_ret = len(per.get(wid, []))
            if fl == 0:
                pc = wf.pc                # retiring RET address convention
            with open(f'{out_dir}/golden.wf{wid}.done', 'w') as f:
                f.write(f'{wid} DONE retired={n_ret} fault={fl} code={fc:02x} '
                        f'pc={pc:x} live={wf.live & 0xFFFFFFFF:08x}\n')

        # states
        def state_of(wf, sgpr_n=64, vgpr_n=32):
            sg = list(wf.sgpr) + [0] * max(0, sgpr_n - len(wf.sgpr))
            out = ['SGPR ' + ' '.join(f'{sg[i]:08x}' for i in range(sgpr_n)),
                   'PRED ' + ' '.join(f'{wf.pred[i]:08x}' for i in range(15))]
            out.append(f'EXEC {wf.exec_mask:08x}')
            out.append(f'LIVE {wf.live:08x}')
            out.append(f'SP {len(wf.stack):08x}')
            for v in range(vgpr_n):
                vv = wf.vgpr[v] if v < len(wf.vgpr) else [0]*32
                out.append('VGPR %02x ' % v +
                           ' '.join(f'{vv[l]:08x}' for l in range(32)))
            return '\n'.join(out) + '\n'

        with open(f'{out_dir}/golden.state', 'w') as f:
            f.write(state_of(k.wfs[0]))
        for wid in range(n_wf):
            with open(f'{out_dir}/golden.wf{wid}.state', 'w') as f:
                f.write(state_of(k.wfs[wid]))

        with open(f'{out_dir}/golden.masktrace', 'w') as f:
            f.write(k.dump_mask_events())
        with open(f'{out_dir}/golden.fault', 'w') as f:
            if fault is not None:
                f.write(f'fault={fault[0]:02x}\n')
            else:
                f.write('fault=00\n')
        return dict(retired=[int(w.retired and 1 or 0) for w in k.wfs],
                    fault=(fault[0] if fault else 0))
    finally:
        os.unlink(path)


if __name__ == '__main__':
    print('library module — use tools/m5_run_suite.py')
