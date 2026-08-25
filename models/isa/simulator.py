"""SciGPU golden ISA simulator — normative architectural reference.

Executes SGP1 images per SPEC-000 R0.2 / ISA-001 Rev1.4 / EXEC-001 Rev1.1 /
MEM-001 semantics:
  - wavefronts of exactly 32 work-items (WAVEFRONT_SIZE=32, ADR-001)
  - execution beats: B = 32 / SIMD_LANES; results invariant to SIMD_LANES (INV-025)
  - active masks; inactive lanes have zero architectural effect (INV-002)
  - M5 divergence: ONE unified typed mask/control stack per wavefront (ADR-011):
    FRAME_IF / FRAME_LOOP / FRAME_MANUAL, LIVE_MASK, atomic faults, automatic
    unwind engine, early return. Replaces the pre-M5 dual wf.stack/wf.mstack model.
  - workgroup barriers with generation accounting (INV-012)
  - flat global memory + per-workgroup shared memory; window faults
Fault codes match ARCH-001 §23 (+ 0x0D/0x0E per ISA-001 Rev1.4).
"""
import struct
from scigpu_defs import (OP, MNEMONIC, decode, read_sgp1, MASK32, VECTOR_ALU,
                         PRED_NONE as PRED_NONE_VALUE,
                         FRAME_IF, FRAME_LOOP, FRAME_MANUAL,
                         IF_THEN, IF_ELSE, COND_CTRL_EXEC)

VF_ADD, VF_SUB, VF_MUL, VF_FMA = OP.VF_ADD, OP.VF_SUB, OP.VF_MUL, OP.VF_FMA

W = 32                                   # WAVEFRONT_SIZE (architectural constant)
BEATS_DEFAULT_L = 8                      # default physical width for runs

class SimFault(Exception):
    def __init__(self, code, msg=''):
        self.code = code
        super().__init__(f'FAULT 0x{code:02X}: {msg}')

# fault codes (ARCH-001 §23; M5 additions per ISA-001 Rev1.4 §21)
F_ILLEGAL_OPCODE=0x01; F_INVALID_REGISTER=0x02; F_INVALID_ADDRESS=0x03
F_ALIGNMENT=0x04; F_MASK_OVERFLOW=0x05; F_MASK_UNDERFLOW=0x06
F_ILLEGAL_BARRIER=0x07; F_WATCHDOG=0x08; F_INTERNAL=0x0C
F_RECONV_MISMATCH=0x0D; F_ILLEGAL_CONTROL_FLOW=0x0E

def f32_bits(x):
    return struct.unpack('<I', struct.pack('<f', float(x)))[0]
def bits_f32(b):
    return struct.unpack('<f', struct.pack('<I', b & MASK32))[0]

def _chk_r(idx, limit, kind='VGPR'):
    if idx >= limit:
        raise SimFault(F_INVALID_REGISTER, f'{kind} index {idx} ≥ {limit}')

class Frame:
    """ADR-011 typed mask/control stack frame (one physical record, type-directed)."""
    __slots__ = ('ftype','parent','mask_a','mask_b','pc_a','pc_b','future',
                 'phase','prev_loop')
    def __init__(self, ftype, parent, pc_a=0, pc_b=0, phase=IF_THEN,
                 prev_loop=None):
        self.ftype = ftype
        self.parent = parent & MASK32   # IF/LOOP: EXEC before entry; MANUAL: saved_exec
        self.mask_a = 0                 # IF: pending_mask | LOOP: iteration_mask
        self.mask_b = 0                 # LOOP: continue_mask
        self.pc_a = pc_a                # IF: pending_pc(else) | LOOP: head_pc
        self.pc_b = pc_b                # IF: reconv_pc       | LOOP: end_pc
        self.future = 0                 # LOOP: future_loop_mask
        self.phase = phase              # IF: THEN/ELSE
        self.prev_loop = prev_loop      # LOOP: enclosing loop frame index

class Wavefront:
    def __init__(self, wid, wgx, code, entry_pc, vgpr_n, sgpr_n, wg_base, wg_size,
                 args_sgpr, mask_stack_depth=32):
        self.id = wid; self.wgx = wgx
        self.vgpr = [[0]*W for _ in range(vgpr_n)]
        self.sgpr = list(args_sgpr) + [0]*max(0, sgpr_n-len(args_sgpr))
        self.pred = [0]*16
        self.stack = []                  # ADR-011 unified typed control stack
        self.mask_depth = mask_stack_depth
        self.live = 0                    # LIVE_MASK (set by Kernel after exec init)
        self.loop_idx = None             # nearest active LOOP frame index / None
        self.await_loop_end = False      # unwind routed to LOOP_END validation
        # dedicated scalar condition state (ISA-001 Rev1.2 §7) — NOT SGPRs
        self.sc_flags = {'Z': 0, 'N': 0, 'C': 0, 'V': 0}
        self.scc = 0
        self.pc = entry_pc
        self.retired = False; self.faulted = None
        self.wait_barrier_gen = None
        self.wg_base = wg_base; self.wg_size = wg_size
        # NOTE (M3): no implicit VGPR startup writes. Per-lane identity is
        # produced architecturally by V_LLANE; ABI startup registers are defined
        # in SW-001 and will be initialised by the dispatcher at later milestones.

class Workgroup:
    def __init__(self, wgid, smem_bytes, n_wf):
        self.id = wgid
        self.smem = bytearray(smem_bytes)
        self.n_wf = n_wf
        self.bar_arrived = set()
        self.bar_generation = 0
        self.bar_waiters = {}            # generation -> set(ids)

class Kernel:
    def __init__(self, sgp1_path, grid_x=1, wg_size=32, vgpr_req=None, sgpr_req=None,
                 smem_req=None, simd_lanes=BEATS_DEFAULT_L, mem_size=1 << 20,
                 args_packed=b'', trace=False,
                 exec_mask=None, pred_init=None, vgpr_init=None,
                 mask_stack_depth=32, exec_masks=None):
        self.trace_enabled = trace
        self.trace = []                  # list of retire-trace dicts (ISA-001 Rev1.2)
        self.mask_events = []            # M5 mask-control event stream (directive §90)
        self.mask_depth = mask_stack_depth
        img = read_sgp1(sgp1_path)
        self.code = [struct.unpack_from('<Q', img['code'], i)[0]
                     for i in range(0, len(img['code']), 8)]
        e = img['entry']
        self.vgpr_n = vgpr_req if vgpr_req is not None else max(e['vgpr'], 4)
        self.sgpr_n = sgpr_req if sgpr_req is not None else max(e['sgpr'], 8)
        self.smem_n = smem_req if smem_req is not None else e['smem']
        assert img['entry']['pc'] == 0
        self.grid_x = grid_x; self.wg_size = wg_size
        self.n_wf_per_wg = (wg_size + W - 1)//W
        self.L = simd_lanes
        self.B = W // self.L
        assert W % self.L == 0
        self.mem = bytearray(mem_size)
        self.args_packed = args_packed
        # unpack args into per-wavefront SGPR prefix (ABI: PTR=2 SGPRs lo/hi, I32=1)
        self.args_sgpr = []
        off = 0
        while off < len(args_packed):
            self.args_sgpr.append(struct.unpack_from('<I', args_packed, off)[0])
            off += 4
        self.wgs = [Workgroup(g, self.smem_n, self.n_wf_per_wg)
                    for g in range(grid_x)]
        self.wfs = []
        for g, wg in enumerate(self.wgs):
            for k in range(self.n_wf_per_wg):
                partial_tail = (g*self.wg_size + k*W) >= grid_x*wg_size
                valid = [(g*self.wg_size + k*W + l) < grid_x*wg_size for l in range(W)]
                wf = Wavefront(k, g, self.code, 0, self.vgpr_n, self.sgpr_n,
                               g, self.wg_size, self.args_sgpr,
                               mask_stack_depth=self.mask_depth)
                wf.partial_valid = valid
                init_exec = sum(1 << l for l in range(W) if valid[l]) & MASK32
                wf.exec_mask = 0 if all(not v for v in valid) else init_exec
                wf.live = wf.exec_mask          # LIVE_MASK ← initial EXEC (ADR-011 D3)
                if wf.exec_mask == 0:
                    wf.retired = True           # fully-empty tail wavefront
                self.wfs.append(wf)
        # M3 bootstrap state overrides (applied to every wavefront uniformly)
        if pred_init is not None:
            for wf in self.wfs:
                for i in range(min(15, len(pred_init))):
                    wf.pred[i] = pred_init[i] & MASK32
        if vgpr_init is not None:
            for wf in self.wfs:
                for (va, vl, vdata) in vgpr_init:
                    if va < len(wf.vgpr):
                        wf.vgpr[va][vl] = vdata & MASK32
        if exec_masks is not None:
            for i, wf in enumerate(self.wfs):
                if i < len(exec_masks):
                    wf.exec_mask = exec_masks[i] & MASK32
                    wf.live = wf.exec_mask
                    if wf.exec_mask == 0:
                        wf.retired = True
        elif exec_mask is not None:
            for wf in self.wfs:
                wf.exec_mask = exec_mask & MASK32
                wf.live = wf.exec_mask          # LIVE_MASK ← initial EXEC
                if wf.exec_mask == 0:
                    wf.retired = True          # empty tail wavefront (§19)

        self.cycles = 0; self.instructions = 0

    def dump_state(self, sgpr_n=64, vgpr_n=32):
        """Architectural final-state lines for differential comparison."""
        out = []
        wf0 = self.wfs[0]
        out.append('SGPR ' + ' '.join(f'{wf0.sgpr[i]:08x}' for i in range(sgpr_n)))
        out.append('PRED ' + ' '.join(f'{wf0.pred[i]:08x}' for i in range(15)))
        out.append(f'EXEC {wf0.exec_mask:08x}')
        for v in range(vgpr_n):
            words = ' '.join(f'{self.wfs[0].vgpr[v][l]:08x}' for l in range(32))
            out.append(f'VGPR {v:02x} ' + words)
        return '\n'.join(out) + '\n'

    def dump_state_m5(self, sgpr_n=64, vgpr_n=32):
        """M5 final-state comparison lines: adds LIVE_MASK + stack depth
        (directive §158). Legacy dump format unchanged for M2–M4 flows."""
        out = [self.dump_state(sgpr_n, vgpr_n).rstrip('\n')]
        wf0 = self.wfs[0]
        out.append(f'LIVE {wf0.live:08x}')
        out.append(f'SP {len(wf0.stack)}')
        return '\n'.join(out) + '\n'

    def dump_mask_events(self):
        """Mask-control event stream, coarse comparable contract (directive 90):
        wfid / kind / pc / ftype / push / pop / fault — identical formatting to
        the RTL testbench stream."""
        out = []
        for e in self.mask_events:
            out.append('w=%u k=%s pc=%x ft=%u pu=%u po=%u f=%02x' % (
                e['wfid'], e['kind'], e['pc'], e['frame_type'],
                e['push'], e['pop'], e['fault']))
        return chr(10).join(out) + (chr(10) if out else '')

    # -------------------------------------------------- execution engine ---
    def run(self, watchdog=10_000_000, isolate_faults=False):
        """isolate_faults=True: a faulting wavefront is marked FAULTED and
        co-resident wavefronts continue to completion (M5 multi-wavefront
        fault-isolation semantics, directive §144/§35). Default False keeps
        the legacy whole-kernel abort contract used by M1–M4 flows."""
        order = sorted(range(len(self.wfs)),
                       key=lambda i: (self.wfs[i].wgx, self.wfs[i].id))
        ptr = 0; steps = 0
        while any(not wf.retired and wf.faulted is None for wf in self.wfs):
            steps += 1
            if steps > watchdog:
                raise SimFault(F_WATCHDOG, 'instruction-step watchdog tripped')
            progressed = False
            for idx in order:                    # deterministic round-robin
                wf = self.wfs[idx]
                if wf.retired or wf.faulted is not None or wf.wait_barrier_gen is not None:
                    continue
                if isolate_faults:
                    saved_trace_len = len(self.trace)
                    saved_mev_len = len(self.mask_events)
                    try:
                        self.step(wf)
                    except SimFault as e:
                        # unwind partial-step effects so streams align with RTL
                        del self.trace[saved_trace_len:]
                        del self.mask_events[saved_mev_len:]
                        wf._pevt = None
                        wf.faulted = (e.code, str(e))
                        self.mask_events.append(dict(
                            wfid=wf.id, kind='FAULT', pc=wf.pc,
                            old_exec=wf.exec_mask, new_exec=wf.exec_mask,
                            old_live=wf.live, new_live=wf.live,
                            sp_before=len(wf.stack), sp_after=len(wf.stack),
                            frame_type=0, push=0, pop=0,
                            pending_mask=0, target_pc=None, fault=e.code))
                else:
                    self.step(wf)
                progressed = True
            if not progressed:                   # all remaining are at barriers?
                pending = [wf for wg in self.wgs
                           for wf in ([w for w in self.wfs if w.wgx == wg.id])]
                stuck = any((not w_.retired and w_.wait_barrier_gen is None)
                            for w_ in self.wfs)
                if stuck:
                    raise SimFault(F_INTERNAL, 'scheduler livelock')
                raise SimFault(F_ILLEGAL_BARRIER, 'barrier deadlock detected')
            self.cycles += 1
        return self

    # -------------------------------------------- M5 mask-control engine ---
    def _mev(self, wf, kind, old_exec, new_exec, old_live, new_live,
             sp_before, sp_after, ftype=0, push=0, pop=0, pending=0, target=None,
             fault=0):
        """Stage one mask-control event; flushed after the automatic unwind
        so emitted fields reflect final settled state (matches RTL)."""
        wf._pevt = dict(
            wfid=wf.id, kind=kind, pc=wf.pc,
            old_exec=old_exec, new_exec=new_exec,
            old_live=old_live, new_live=new_live,
            sp_before=sp_before, sp_after=sp_after,
            frame_type=ftype, push=push, pop=pop,
            pending_mask=pending, target_pc=target, fault=fault)

    def _evt_flush(self, wf):
        e = getattr(wf, '_pevt', None)
        if e is not None:
            wf._pevt = None
            e['new_exec'] = wf.exec_mask
            e['new_live'] = wf.live
            e['sp_after'] = len(wf.stack)
            self.mask_events.append(e)

    def _scrub_above_loop(self, wf, m, loop_idx):
        """Directive §58: clear lane bits m from IF/MANUAL frames above the
        target LOOP frame so later RECONV/POPM cannot resurrect them inside the
        current loop iteration."""
        for j in range(len(wf.stack)-1, loop_idx, -1):
            fr = wf.stack[j]
            fr.parent &= ~m & MASK32
            if fr.ftype == FRAME_IF:
                fr.mask_a &= ~m & MASK32     # pending

    def _scrub_all_frames(self, wf, m):
        """Directive §59: returned lanes must be cleared from ALL restorable masks."""
        for fr in wf.stack:
            fr.parent &= ~m & MASK32
            fr.mask_a &= ~m & MASK32
            fr.mask_b &= ~m & MASK32
            fr.future &= ~m & MASK32

    def _unwind(self, wf):
        """ADR-011 D8 automatic mask-unwind engine. Called whenever EXEC==0 while
        the wavefront is not retired. Resumes live alternate paths, pops exhausted
        IF frames, routes dead-loop contexts to LOOP_END, or retires when every
        lane has permanently returned."""
        while wf.exec_mask == 0:
            if wf.live == 0:
                # full early return: residual frames provably hold no live lanes;
                # discard silently — NEVER classified as underflow (directive §82)
                wf.retired = True
                return
            if not wf.stack:
                raise SimFault(F_INTERNAL,
                               'mask stack empty with LIVE_MASK != 0 '
                               '(structural impossibility, directive §81)')
            fr = wf.stack[-1]
            if fr.ftype == FRAME_IF:
                pend = fr.mask_a & wf.live
                if pend:
                    # resume pending alternate path (directive §78)
                    wf.exec_mask = pend
                    wf.pc = fr.pc_a
                    fr.mask_a = 0; fr.phase = IF_ELSE
                    return
                # exhausted IF frame: restore parent subject to scrubbing, pop
                base = fr.parent & wf.live
                reconv = fr.pc_b
                wf.stack.pop()
                wf.exec_mask = base
                wf.pc = reconv + 1
                continue
            if fr.ftype == FRAME_LOOP:
                # route to LOOP_END semantics (directive §80); LOOP_END validates
                wf.pc = fr.pc_b
                wf.await_loop_end = True
                return
            # MANUAL: restore saved context outside any live-lane prohibition
            base = fr.parent & wf.live
            wf.stack.pop()
            wf.exec_mask = base
            # loop continues if still zero

    def step(self, wf):
        # PC bounds: pc < code_words else FAULT_INVALID_ADDRESS (fetch-side)
        if wf.pc >= len(self.code):
            raise SimFault(F_INVALID_ADDRESS,
                           f'pc {wf.pc} >= code_words {len(self.code)}')
        # M5 automatic unwind (replaces pre-M5 fetch-from-stack rule)
        if wf.exec_mask == 0 and not wf.retired:
            self._unwind(wf)
            if wf.retired:
                return
        word = self.code[wf.pc]
        d = decode(word)
        self.instructions += 1
        pc_next = wf.pc + 1
        op = d.op

        # M5 control-condition nibble (ISA-001 Rev1.4 §16.2): word[23:20]
        cc4 = (word >> 20) & 0xF

        # unwind routed here for loop-end processing: next instruction MUST be
        # the LOOP_END (structured binary contract; directive §80/§64)
        if wf.await_loop_end:
            if op != OP.LOOP_END:
                raise SimFault(F_ILLEGAL_CONTROL_FLOW,
                               f'unwind routed to pc {wf.pc} but instruction '
                               f'is not LOOP_END')
            wf.await_loop_end = False

        # ---- retire-trace accumulators (post-commit architectural values) ----
        t_we, t_wa, t_wd = 0, 0, 0
        br_taken = 0
        wf.last_emask = None; wf.last_vwe = 0; wf.last_va = 0

        def src(idx):
            _chk_r(idx, self.sgpr_n, 'SGPR')
            return wf.sgpr[idx]

        def wr(dst, val):
            nonlocal t_we, t_wa, t_wd
            _chk_r(dst, self.sgpr_n, 'SGPR')
            wf.sgpr[dst] = val & MASK32
            t_we, t_wa, t_wd = 1, dst, val & MASK32

        def sval(_):
            return (self._simm(d) & MASK32) if d.fmt == 3 else src(d.vs1)

        def sub_flags(a, b):
            r = (a - b) & MASK32
            z = 1 if r == 0 else 0
            n = (r >> 31) & 1
            c = 1 if a >= b else 0
            va_, vb_ = (a >> 31) & 1, (b >> 31) & 1
            v = 1 if (va_ != vb_) and (((r >> 31) & 1) != va_) else 0
            return r, {'Z': z, 'N': n, 'C': c, 'V': v}

        def scc_of(kind, a, b):
            sa = a - (a >> 31 << 32); sb = b - (b >> 31 << 32)
            return {'EQ': int(a == b), 'LT': int(sa < sb),
                    'GT': int(sa > sb)}[kind]

        def src(idx):
            _chk_r(idx, self.sgpr_n, 'SGPR')
            return wf.sgpr[idx]

        def wr(dst, val):
            nonlocal t_we, t_wa, t_wd
            _chk_r(dst, self.sgpr_n, 'SGPR')
            wf.sgpr[dst] = val & MASK32
            t_we, t_wa, t_wd = 1, dst, val & MASK32

        def sval(_):
            return (self._simm(d) & MASK32) if d.fmt == 3 else src(d.vs1)

        # ---- decode legality (mirror RTL decoder; ISA-001 Rev1.2/1.3) ----
        _F = None
        if op in (OP.S_MOV, OP.S_ADD, OP.S_SUB, OP.S_AND, OP.S_OR, OP.S_XOR,
                  OP.S_SHL, OP.S_SHR, OP.S_SAR):
            _F = (2, 3)
        elif op in (OP.S_MUL, OP.S_NOT, OP.S_CMP_EQ, OP.S_CMP_LT, OP.S_CMP_GT):
            _F = (2,)
        elif op in (OP.S_BRA, OP.BRA_V, OP.S_BRA_COND, OP.RET_KERNEL_WF,
                    OP.CBRANCH_IF, OP.RECONV, OP.PUSHM, OP.POPM, OP.SETM,
                    OP.ANDM, OP.ORM, OP.XORM, OP.LOOP_BEGIN, OP.LOOP_END,
                    OP.BREAK, OP.CONTINUE):
            _F = (5,)
        elif op in (OP.S_GETID, OP.NOP):
            _F = (6,)
        elif op in (OP.VLDW, OP.VSTW, OP.SLDW, OP.SSTW, OP.VLDLW, OP.VSTLW,
                    OP.ATOM_ADD_U32):
            _F = (4,)
        elif op == OP.BAR_WG:
            _F = (6,)
        elif op in VECTOR_ALU or op in (OP.V_MOV, OP.V_MOVI, OP.V_BCAST,
                                        OP.V_LLANE, OP.VCVT_F32_I32,
                                        OP.VCVT_I32_F32):
            _F = (0, 1)
        elif op in (OP.VCMP_EQ, OP.VCMP_NEQ, OP.VCMP_LT, OP.VCMP_LE,
                    OP.VCMP_GT, OP.VCMP_GE, OP.VFCMP_LT_O, OP.VFCMP_GT_O,
                    OP.VFCMP_LE_O):
            _F = (9,)
        if _F is None or d.fmt not in _F:
            raise SimFault(F_ILLEGAL_OPCODE,
                           f'{MNEMONIC.get(op, hex(op))}: illegal format {d.fmt}')
        if op in VECTOR_ALU or op in (OP.V_MOV, OP.V_MOVI, OP.V_BCAST,
                                      OP.V_LLANE, OP.VCVT_F32_I32,
                                      OP.VCVT_I32_F32, OP.VCMP_EQ, OP.VCMP_NEQ,
                                      OP.VCMP_LT, OP.VCMP_LE, OP.VCMP_GT,
                                      OP.VCMP_GE, OP.VFCMP_LT_O, OP.VFCMP_GT_O,
                                      OP.VFCMP_LE_O):
            if d.typesel or d.rnd or d.sat or d.abs0 or d.neg0 or d.neg1 \
                    or d.vflags:
                raise SimFault(F_ILLEGAL_OPCODE, 'unsupported VMOD modifiers')

        if op == OP.NOP:
            pass
        elif op == OP.S_MOV:
            wr(d.vd, self._simm(d) if d.fmt == 3 else src(d.vs0))
        elif op in (OP.S_ADD, OP.S_SUB):
            a = src(d.vs0); b = sval(None)
            wr(d.vd, ((a + b) if op == OP.S_ADD else (a - b)) & MASK32)
        elif op == OP.S_MUL:
            wr(d.vd, src(d.vs0) * src(d.vs1))     # functional bootstrap multiply
        elif op == OP.S_AND:
            wr(d.vd, src(d.vs0) & src(d.vs1))
        elif op == OP.S_OR:
            wr(d.vd, src(d.vs0) | src(d.vs1))
        elif op == OP.S_XOR:
            wr(d.vd, src(d.vs0) ^ src(d.vs1))
        elif op == OP.S_NOT:
            wr(d.vd, ~src(d.vs0) & MASK32)
        elif op == OP.S_SHL:
            wr(d.vd, src(d.vs0) << (sval(None) & 31))
        elif op == OP.S_SHR:
            wr(d.vd, src(d.vs0) >> (sval(None) & 31))
        elif op == OP.S_SAR:
            sa_v = src(d.vs0)
            sa_signed = sa_v - (sa_v >> 31 << 32)
            wr(d.vd, (sa_signed >> (sval(None) & 31)) & MASK32)
        elif op in (OP.S_CMP_EQ, OP.S_CMP_LT, OP.S_CMP_GT):
            a, b = src(d.vs0), src(d.vs1)
            _, fl = sub_flags(a, b)
            kind = MNEMONIC[op].split('_')[-1]
            wf.sc_flags = fl
            wf.scc = scc_of(kind, a, b)
        elif op == OP.S_GETID:
            sel = word & 0xFF
            sd = (word >> 8) & 0xFF
            if sel != 0:
                raise SimFault(F_ILLEGAL_OPCODE,
                               f'unsupported S_GETID selector {sel}')
            wr(sd, wf.wgx & MASK32)
        elif op in (OP.S_BRA, OP.BRA_V):
            br_taken = 1
            pc_next = wf.pc + 1 + d.disp
        elif op == OP.S_BRA_COND:
            cc = d.cond & 0xFF
            f = wf.sc_flags
            taken = {0x00: True, 0x01: wf.scc == 1, 0x02: wf.scc == 0,
                     0x03: f['Z'] == 1, 0x04: f['Z'] == 0,
                     0x05: f['N'] == 1, 0x06: f['N'] == 0,
                     0x07: f['C'] == 1, 0x08: f['C'] == 0,
                     0x09: f['V'] == 1, 0x0A: f['V'] == 0,
                     0x0B: bool(f['N'] ^ f['V']),
                     0x0C: not (f['N'] ^ f['V']),
                     0x0D: f['C'] == 0, 0x0E: f['C'] == 1}.get(cc)
            if taken is None:
                raise SimFault(F_ILLEGAL_OPCODE,
                               f'reserved branch condition {cc:#x}')
            br_taken = int(taken)
            pc_next = wf.pc + 1 + d.disp if taken else wf.pc + 1
        elif op in VECTOR_ALU or op in (OP.V_MOV, OP.V_MOVI, OP.V_BCAST,
                                        OP.V_LLANE, OP.VCVT_F32_I32,
                                        OP.VCVT_I32_F32):
            self._vec_alu(wf, d, op) if op in VECTOR_ALU else (
                self._vec_move(wf, d, op) if op in (OP.V_MOV, OP.V_MOVI,
                                                    OP.V_BCAST, OP.V_LLANE)
                else self._vec_cvt(wf, d, op))
        elif op in (OP.VCMP_EQ, OP.VCMP_NEQ, OP.VCMP_LT, OP.VCMP_LE,
                    OP.VCMP_GT, OP.VCMP_GE, OP.VFCMP_LT_O, OP.VFCMP_GT_O,
                    OP.VFCMP_LE_O):
            self._vec_cmp(wf, d, op)
        elif op in (OP.VLDW, OP.VSTW, OP.SLDW, OP.SSTW, OP.VLDLW, OP.VSTLW,
                    OP.ATOM_ADD_U32):
            pc_next = self._mem_op(wf, d, op)
        elif op == OP.BAR_WG:
            self._barrier(wf)
        elif op == OP.CBRANCH_IF:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if cc4 >= COND_CTRL_EXEC:
                raise SimFault(F_ILLEGAL_CONTROL_FLOW,
                               'CBRANCH_IF requires predicate P0..P14')
            else_pc = wf.pc + 1 + d.disp
            reconv_pc = wf.pc + 1 + (d.payload - 0x10000
                                     if d.payload & 0x8000 else d.payload)
            if not (0 <= else_pc < len(self.code)) or \
                    not (0 <= reconv_pc < len(self.code)):
                raise SimFault(F_INVALID_ADDRESS,
                               f'CBRANCH_IF target else={else_pc} '
                               f'reconv={reconv_pc} out of range')
            if len(wf.stack) >= wf.mask_depth:
                self._mev(wf, 'CBRANCH_IF', old_exec, old_exec, old_live,
                          old_live, sp, sp, FRAME_IF, fault=F_MASK_OVERFLOW)
                raise SimFault(F_MASK_OVERFLOW,
                               f'mask stack full ({wf.mask_depth}) — atomic')
            cond_mask = wf.pred[cc4]
            t = wf.exec_mask & cond_mask
            f = wf.exec_mask & (~cond_mask & MASK32)
            fr = Frame(FRAME_IF, wf.exec_mask, pc_a=else_pc, pc_b=reconv_pc,
                       phase=IF_THEN)
            fr.mask_a = f                      # pending alternate path
            wf.stack.append(fr)
            if t:
                wf.exec_mask = t               # THEN continues fall-through
                pc_next = wf.pc + 1
            else:
                wf.exec_mask = f               # ELSE-only entry
                fr.phase = IF_ELSE
                pc_next = else_pc
            div = int(t != 0 and f != 0)
            self._mev(wf, 'CBRANCH_IF', old_exec, wf.exec_mask, old_live,
                      wf.live, sp, len(wf.stack), FRAME_IF, push=1,
                      pending=f, target=pc_next if not t else else_pc)
            self.pmc_div = getattr(self, 'pmc_div', 0) + div
        elif op == OP.RECONV:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if not wf.stack:
                self._mev(wf, 'RECONV', old_exec, old_exec, old_live, old_live,
                          sp, sp, fault=F_MASK_UNDERFLOW)
                raise SimFault(F_MASK_UNDERFLOW, 'RECONV with empty mask stack')
            fr = wf.stack[-1]
            if fr.ftype != FRAME_IF:
                self._mev(wf, 'RECONV', old_exec, old_exec, old_live, old_live,
                          sp, sp, fr.ftype, fault=F_ILLEGAL_CONTROL_FLOW)
                raise SimFault(F_ILLEGAL_CONTROL_FLOW,
                               'RECONV top frame is not IF')
            if wf.pc != fr.pc_b:
                self._mev(wf, 'RECONV', old_exec, old_exec, old_live, old_live,
                          sp, sp, FRAME_IF, fault=F_RECONV_MISMATCH)
                raise SimFault(F_RECONV_MISMATCH,
                               f'RECONV at pc {wf.pc}, expected {fr.pc_b}')
            if fr.phase == IF_THEN and (fr.mask_a & wf.live):
                # first arrival: schedule alternate path; frame stays (§36)
                new_exec = fr.mask_a & wf.live
                wf.exec_mask = new_exec
                pc_next = fr.pc_a
                fr.mask_a = 0; fr.phase = IF_ELSE
                self._mev(wf, 'RECONV', old_exec, new_exec, old_live,
                          wf.live, sp, sp, FRAME_IF, pending=new_exec,
                          target=pc_next)
            else:
                base = fr.parent & wf.live     # final reconvergence (§37)
                wf.stack.pop()
                wf.exec_mask = base
                pc_next = fr.pc_b + 1
                self._mev(wf, 'RECONV', old_exec, base, old_live,
                          wf.live, sp, len(wf.stack), FRAME_IF, pop=1,
                          target=pc_next)
                self.pmc_reconv = getattr(self, 'pmc_reconv', 0) + 1
        elif op == OP.LOOP_BEGIN:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            end_pc = wf.pc + 1 + d.disp
            head_pc = wf.pc + 1
            if not (0 <= end_pc < len(self.code)):
                raise SimFault(F_INVALID_ADDRESS,
                               f'LOOP_BEGIN end {end_pc} out of range')
            if len(wf.stack) >= wf.mask_depth:
                self._mev(wf, 'LOOP_BEGIN', old_exec, old_exec, old_live,
                          old_live, sp, sp, FRAME_LOOP, fault=F_MASK_OVERFLOW)
                raise SimFault(F_MASK_OVERFLOW, 'mask stack full — atomic')
            fr = Frame(FRAME_LOOP, wf.exec_mask, pc_a=head_pc, pc_b=end_pc,
                       prev_loop=wf.loop_idx)
            fr.mask_a = wf.exec_mask           # iteration mask
            fr.future = wf.exec_mask           # future loop mask
            wf.stack.append(fr)
            prev_idx = wf.loop_idx
            wf.loop_idx = len(wf.stack) - 1
            pc_next = wf.pc + 1                # EXEC unchanged
            self._mev(wf, 'LOOP_BEGIN', old_exec, wf.exec_mask, old_live,
                      wf.live, sp, len(wf.stack), FRAME_LOOP, push=1,
                      target=end_pc)
        elif op == OP.LOOP_END:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if wf.loop_idx is None:
                self._mev(wf, 'LOOP_END', old_exec, old_exec, old_live,
                          old_live, sp, sp, fault=F_ILLEGAL_CONTROL_FLOW)
                raise SimFault(F_ILLEGAL_CONTROL_FLOW, 'LOOP_END outside loop')
            fr = wf.stack[wf.loop_idx]
            if fr.ftype != FRAME_LOOP:
                raise SimFault(F_INTERNAL, 'loop_idx invariant broken')
            if len(wf.stack) - 1 != wf.loop_idx:
                self._mev(wf, 'LOOP_END', old_exec, old_exec, old_live,
                          old_live, sp, sp, FRAME_LOOP,
                          fault=F_ILLEGAL_CONTROL_FLOW)
                raise SimFault(F_ILLEGAL_CONTROL_FLOW,
                               'stale structured frames above LOOP at LOOP_END')
            if wf.pc != fr.pc_b:
                self._mev(wf, 'LOOP_END', old_exec, old_exec, old_live,
                          old_live, sp, sp, FRAME_LOOP,
                          fault=F_RECONV_MISMATCH)
                raise SimFault(F_RECONV_MISMATCH,
                               f'LOOP_END at pc {wf.pc}, expected {fr.pc_b}')
            if wf.pc + 1 + d.disp != fr.pc_a:
                self._mev(wf, 'LOOP_END', old_exec, old_exec, old_live,
                          old_live, sp, sp, FRAME_LOOP,
                          fault=F_RECONV_MISMATCH)
                raise SimFault(F_RECONV_MISMATCH,
                               'LOOP_END head displacement mismatch')
            cond_mask = MASK32 if d.cond == COND_CTRL_EXEC else wf.pred[cc4]
            candidate = ((wf.exec_mask | fr.mask_b) & fr.future) & wf.live
            nxt = candidate & cond_mask
            if nxt:
                fr.future = nxt; fr.mask_a = nxt; fr.mask_b = 0
                wf.exec_mask = nxt
                pc_next = fr.pc_a              # iterate from head
                self._mev(wf, 'LOOP_END', old_exec, nxt, old_live, wf.live,
                          sp, sp, FRAME_LOOP, target=pc_next)
            else:
                base = fr.parent & wf.live     # broken lanes rejoin here
                wf.stack.pop()
                wf.loop_idx = fr.prev_loop
                wf.exec_mask = base
                pc_next = fr.pc_b + 1          # continue after loop
                self._mev(wf, 'LOOP_END', old_exec, base, old_live, wf.live,
                          sp, len(wf.stack), FRAME_LOOP, pop=1,
                          target=pc_next)
        elif op in (OP.BREAK, OP.CONTINUE):
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            kind = 'BREAK' if op == OP.BREAK else 'CONTINUE'
            if wf.loop_idx is None or wf.await_loop_end:
                self._mev(wf, kind, old_exec, old_exec, old_live, old_live,
                          sp, sp, fault=F_ILLEGAL_CONTROL_FLOW)
                raise SimFault(F_ILLEGAL_CONTROL_FLOW, f'{kind} outside loop')
            fr = wf.stack[wf.loop_idx]
            m = wf.exec_mask if d.cond == COND_CTRL_EXEC \
                else (wf.exec_mask & wf.pred[cc4])
            self._scrub_above_loop(wf, m, wf.loop_idx)
            if op == OP.BREAK:
                fr.future &= ~m & MASK32
                fr.mask_a &= ~m & MASK32       # iteration
            else:
                fr.mask_b |= m                 # continue_mask
                fr.mask_a &= ~m & MASK32       # iteration
            wf.exec_mask &= ~m & MASK32
            pc_next = wf.pc + 1
            self._mev(wf, kind, old_exec, wf.exec_mask, old_live, wf.live,
                      sp, sp, FRAME_LOOP)
            if kind == 'BREAK':
                self.pmc_break = getattr(self, 'pmc_break', 0) + 1
            else:
                self.pmc_cont = getattr(self, 'pmc_cont', 0) + 1
        elif op == OP.PUSHM:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if len(wf.stack) >= wf.mask_depth:
                self._mev(wf, 'PUSHM', old_exec, old_exec, old_live, old_live,
                          sp, sp, FRAME_MANUAL, fault=F_MASK_OVERFLOW)
                raise SimFault(F_MASK_OVERFLOW, 'mask stack full — atomic')
            fr = Frame(FRAME_MANUAL, wf.exec_mask)
            wf.stack.append(fr)                # saved_exec; no EXEC change
            pc_next = wf.pc + 1
            self._mev(wf, 'PUSHM', old_exec, wf.exec_mask, old_live, wf.live,
                      sp, len(wf.stack), FRAME_MANUAL, push=1)
        elif op == OP.POPM:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if not wf.stack:
                self._mev(wf, 'POPM', old_exec, old_exec, old_live, old_live,
                          sp, sp, fault=F_MASK_UNDERFLOW)
                raise SimFault(F_MASK_UNDERFLOW, 'POPM with empty mask stack')
            fr = wf.stack[-1]
            if fr.ftype != FRAME_MANUAL:
                self._mev(wf, 'POPM', old_exec, old_exec, old_live, old_live,
                          sp, sp, fr.ftype, fault=F_ILLEGAL_CONTROL_FLOW)
                raise SimFault(F_ILLEGAL_CONTROL_FLOW,
                               'POPM top frame is not MANUAL')
            base = fr.parent & wf.live
            wf.stack.pop()
            wf.exec_mask = base
            pc_next = wf.pc + 1
            self._mev(wf, 'POPM', old_exec, base, old_live, wf.live,
                      sp, len(wf.stack), FRAME_MANUAL, pop=1)
        elif op in (OP.SETM, OP.ANDM, OP.ORM, OP.XORM):
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if cc4 >= COND_CTRL_EXEC:
                raise SimFault(F_ILLEGAL_CONTROL_FLOW,
                               f'{MNEMONIC[op]} rejects COND 15 (ambiguous)')
            pm = wf.pred[cc4] & MASK32
            if op == OP.SETM:   nw = pm & wf.live
            elif op == OP.ANDM: nw = wf.exec_mask & pm & wf.live
            elif op == OP.ORM:  nw = (wf.exec_mask | pm) & wf.live
            else:               nw = (wf.exec_mask ^ pm) & wf.live
            wf.exec_mask = nw & MASK32         # EXEC ⊆ LIVE enforced
            pc_next = wf.pc + 1
            self._mev(wf, MNEMONIC[op], old_exec, nw, old_live, wf.live,
                      sp, sp)
        elif op == OP.RET_KERNEL_WF:
            old_exec, old_live, sp = wf.exec_mask, wf.live, len(wf.stack)
            if not wf.stack:
                # non-divergent RET: identical to M2–M4 behavior. Empty stack
                # ⇒ EXEC==LIVE, so LIVE becomes 0 and the wavefront is DONE.
                # EXEC register value preserved at completion (legacy convention).
                wf.retired = True
                wf.live &= ~old_exec & MASK32
                pc_next = wf.pc + 1
                self._mev(wf, 'RET_KERNEL_WF', old_exec, old_exec,
                          old_live, 0, sp, sp)
            else:
                returning = old_exec           # directive §74: divergent return
                wf.live &= ~returning & MASK32
                wf.exec_mask = 0
                self._scrub_all_frames(wf, returning)
                self._mev(wf, 'RET_KERNEL_WF', old_exec, 0, old_live,
                          wf.live, sp, sp)
                pc_next = wf.pc + 1            # unwind engine routes before fetch
        else:
            raise SimFault(F_ILLEGAL_OPCODE,
                           f'{MNEMONIC.get(op, hex(op))} not in M1 subset')

        # M5: settle automatic unwind inline, then emit the single deferred
        # mask-control event with settled context (ADR-011 D8 alignment).
        if getattr(wf, '_pevt', None) is not None and \
                wf.exec_mask == 0 and not wf.retired and wf.live != 0:
            self._unwind(wf)
            if getattr(wf, '_pevt', None) is not None:
                e = wf._pevt
                e['new_exec'] = wf.exec_mask
                e['new_live'] = wf.live
                e['sp_after'] = len(wf.stack)
        self._evt_flush(wf)

        if self.trace_enabled:
            emask = wf.last_emask if getattr(wf, 'last_emask', None) is not None \
                else wf.exec_mask
            self.trace.append(dict(
                wid=wf.id,
                pc=wf.pc, insn=word,
                sgpr_we=t_we, sgpr_addr=t_wa, sgpr_wdata=t_wd,
                Z=wf.sc_flags['Z'], N=wf.sc_flags['N'],
                C=wf.sc_flags['C'], V=wf.sc_flags['V'],
                scc=wf.scc, branch_taken=br_taken, next_pc=pc_next,
                exec_mask=wf.exec_mask, effective_mask=emask,
                pred=d.pred,
                vgpr_we=wf.last_vwe,
                vgpr_addr=wf.last_va))
        if not wf.retired:
            wf.pc = pc_next

    def _simm(self, d):
        return d.imm & MASK32

    # per-beat vector application (ADR-001 beat model; INV-002/003)
    def _effective_mask(self, wf, d):
        """Normative: EXEC (pred==15) else EXEC & P[pred]  (ISA-001 Rev1.3)."""
        if d.pred == PRED_NONE_VALUE:
            return wf.exec_mask
        return wf.exec_mask & wf.pred[d.pred] if d.pred < len(wf.pred) \
            else wf.exec_mask

    def _vec_active(self, wf, emask):
        for k in range(self.B):
            lo = k*self.L
            active = [l for l in range(lo, lo+self.L) if (emask >> l) & 1]
            yield k, active

    def _vec_alu(self, wf, d, op):
        for s in ((d.vs0, d.vs1, d.vs2) if op == OP.VF_FMA else (d.vs0, d.vs1)):
            _chk_r(s, self.vgpr_n)
        emask = self._effective_mask(wf, d)
        dst = wf.vgpr[d.vd]
        s0v = wf.vgpr[d.vs0]
        s1v = wf.vgpr[d.vs1] if d.fmt != 1 else None
        s2v = wf.vgpr[d.vs2] if op == OP.VF_FMA else None
        imm = d.imm if d.fmt == 1 else None
        for k, active in self._vec_active(wf, emask):
            for l in active:
                a = s0v[l]
                b = (imm & MASK32) if imm is not None else (
                    s1v[l] if s1v is not None else 0)
                if op == OP.V_ADD:   r = a + b
                elif op == OP.V_SUB: r = a - b
                elif op == OP.V_MUL: r = a * b
                elif op == OP.V_AND: r = a & b
                elif op == OP.V_OR:  r = a | b
                elif op == OP.V_XOR: r = a ^ b
                elif op == OP.V_SHL: r = a << (b & 31)
                elif op == OP.V_SHR: r = a >> (b & 31)
                elif op == OP.V_SAR:
                    sa = a - ((a >> 31) << 32); r = sa >> (b & 31)
                elif op == OP.V_MIN:
                    sa,sb = a-(a>>31<<32), b-(b>>31<<32); r = a if sa <= sb else b
                elif op == OP.V_MAX:
                    sa,sb = a-(a>>31<<32), b-(b>>31<<32); r = a if sa >= sb else b
                elif op == VF_ADD:   r = f32_bits(bits_f32(a) + bits_f32(b))
                elif op == VF_SUB:   r = f32_bits(bits_f32(a) - bits_f32(b))
                elif op == VF_MUL:   r = f32_bits(bits_f32(a) * bits_f32(b))
                elif op == VF_FMA:
                    r = f32_bits(bits_f32(a)*bits_f32(s1v[l]) + bits_f32(s2v[l]))
                else:
                    raise SimFault(F_ILLEGAL_OPCODE)
                dst[l] = r & MASK32
        wf.last_emask = emask; wf.last_vwe = 1; wf.last_va = d.vd
        return emask

    def _vec_cmp(self, wf, d, op):
        _chk_r(d.vs0, self.vgpr_n); _chk_r(d.vs1, self.vgpr_n)
        emask = self._effective_mask(wf, d)
        s0v, s1v = wf.vgpr[d.vs0], wf.vgpr[d.vs1]
        res = 0
        for k, active in self._vec_active(wf, emask):
            for l in active:
                a, b = s0v[l], s1v[l]
                if op in (OP.VFCMP_LT_O, OP.VFCMP_GT_O, OP.VFCMP_LE_O):
                    fa, fb = bits_f32(a), bits_f32(b)
                    ok = {OP.VFCMP_LT_O: fa < fb, OP.VFCMP_GT_O: fa > fb,
                          OP.VFCMP_LE_O: fa <= fb}[op]
                else:
                    sa, sb = a-(a>>31<<32), b-(b>>31<<32)
                    ok = {OP.VCMP_EQ: a==b, OP.VCMP_NEQ: a!=b, OP.VCMP_LT: sa<sb,
                          OP.VCMP_LE: sa<=sb, OP.VCMP_GT: sa>sb,
                          OP.VCMP_GE: sa>=sb}[op]
                if ok: res |= 1 << l
        # INV-002 predicate preservation: inactive EXEC lanes keep old bits
        wf.pred[d.pd] = ((wf.pred[d.pd] & ~wf.exec_mask & MASK32) |
                         (res & wf.exec_mask))

    def _vec_move(self, wf, d, op):
        _chk_r(d.vd, self.vgpr_n)
        emask = self._effective_mask(wf, d)
        dst = wf.vgpr[d.vd]
        if op == OP.V_MOVI:
            v = d.imm & MASK32
            for k, active in self._vec_active(wf, emask):
                for l in active: dst[l] = v
        elif op == OP.V_LLANE:
            # physical-width oracle: logical lane id from beat base + phys idx
            L = self.L
            for k in range(self.B):
                base = k * L
                for j in range(L):
                    l = base + j
                    if (emask >> l) & 1:
                        dst[l] = base + j
        elif op == OP.V_BCAST:
            _chk_r(d.vs0, self.sgpr_n, 'SGPR')
            v = wf.sgpr[d.vs0]
            for k, active in self._vec_active(wf, emask):
                for l in active: dst[l] = v
        else:                                     # V_MOV
            _chk_r(d.vs0, self.vgpr_n)
            sv = wf.vgpr[d.vs0]
            for k, active in self._vec_active(wf, emask):
                for l in active: dst[l] = sv[l]
        wf.last_emask = emask; wf.last_vwe = 1; wf.last_va = d.vd
        return emask

    def _vec_cvt(self, wf, d, op):
        _chk_r(d.vd, self.vgpr_n); _chk_r(d.vs0, self.vgpr_n)
        emask = self._effective_mask(wf, d)
        sv, dv = wf.vgpr[d.vs0], wf.vgpr[d.vd]
        import math
        for k, active in self._vec_active(wf, emask):
            for l in active:
                if op == OP.VCVT_F32_I32:
                    dv[l] = f32_bits(float(sv[l]))
                else:
                    dv[l] = int(math.trunc(bits_f32(sv[l]))) & MASK32
        return emask

    def _mem_op(self, wf, d, op):
        base = wf.sgpr[d.saddr] if d.saddr < len(wf.sgpr) else 0
        soff = d.soff
        data = d.vd
        scalar = op in (OP.SLDW, OP.SSTW)
        local = op in (OP.VLDLW, OP.VSTLW)
        store = op in (OP.VSTW, OP.SSTW, OP.VSTLW)
        atomic = op == OP.ATOM_ADD_U32
        if scalar:
            addrs = {0: (base + soff)}
        else:
            addrs = {}
            m = wf.exec_mask
            L = self.L
            for k in range(self.B):
                base_l = k * L
                for j in range(L):
                    l = base_l + j
                    if (m >> l) & 1:
                        addrs[l] = base + l*4 + soff
        region = self.wgs[wf.wgx].smem if local else self.mem
        if local:
            pass                                  # addr already an smem offset
        for l, addr in addrs.items():
            if addr + 4 > len(region):
                raise SimFault(F_INVALID_ADDRESS, f'addr 0x{addr:x} out of window')
        if atomic:
            l0 = next(iter(addrs))
            addr = addrs[l0]
            old = struct.unpack_from('<I', region, addr)[0]
            struct.pack_into('<I', region, addr, (old + wf.vgpr[data][l0]) & MASK32)
            wf.vgpr[data][l0] = old               # return-old
            return wf.pc + 1
        for l, addr in addrs.items():
            if store:
                struct.pack_into('<I', region, addr, wf.vgpr[data][l])
            else:
                wf.vgpr[data][l] = struct.unpack_from('<I', region, addr)[0]
        return wf.pc + 1

    def _barrier(self, wf):
        wg = self.wgs[wf.wgx]
        gen = wg.bar_generation
        if wf.wait_barrier_gen is not None:
            raise SimFault(F_ILLEGAL_BARRIER, 'duplicate arrival (INV-012)')
        wg.bar_arrived.add(wf.id)
        if len(wg.bar_arrived) == wg.n_wf:
            wg.bar_arrived.clear()
            wg.bar_generation += 1
            for other in self.wfs:
                if other.wgx == wf.wgx and other.wait_barrier_gen == gen:
                    other.wait_barrier_gen = None
        else:
            wf.wait_barrier_gen = gen
