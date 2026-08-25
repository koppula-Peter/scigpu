# EXEC-001 — SciGPU SIMT Execution Model

| Field | Value |
|---|---|
| Document ID | EXEC-001 |
| Title | SIMT Execution Model: wavefronts, masks, divergence, barriers |
| Status | APPROVED — Rev 1.1 (M5 divergence semantics normative) |
| Parent | SPEC-000 Rev 0.2; ARCH-001 §§9–11, 15; ADR-001, ADR-007, ADR-011 |
| Normative for | ISA-001 §4/§16, MICRO-001, SCHED-001 |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.1 | 2026-08-23 | Principal GPU Architect | M5 divergence rewrite of §4 (normative): one unified typed mask/control stack per wavefront (FRAME_IF/FRAME_LOOP/FRAME_MANUAL — ADR-011); LIVE_MASK architectural state + invariant EXEC ⊆ LIVE_MASK; CBRANCH_IF explicit ELSE+RECONV displacements (BMOD), always-push rule; RECONV two-phase alternate-path scheduling with reconvergence-target check (FAULT_RECONVERGENCE_MISMATCH = 0x0D); LOOP_BEGIN/LOOP_END/BREAK/CONTINUE nearest-loop semantics with mask scrubbing; divergent RET_KERNEL_WF + automatic unwind engine; atomic overflow/underflow/illegal-control-flow faults (FAULT_ILLEGAL_CONTROL_FLOW = 0x0E). §4.3 early-return ambiguity resolved: legitimate structured early return is never classified as underflow. §5 barriers unchanged (M9/M15). |
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete execution-model baseline |

---

## 1. Model Definitions

| Concept | Definition |
|---|---|
| Work-item | The unit of programmability: one logical thread with private register view and identity. |
| Wavefront | Exactly **32** work-items bound into one scheduled SIMD entity (WAVEFRONT_SIZE=32, ADR-001). All architectural masks are 32-bit. |
| Lane | Position i ∈ [0,32) of a work-item inside its wavefront; lane i executes work-item i's operations. |
| Execution beat | One pass over the physical datapath covering SIMD_LANES consecutive lanes; B = 32/SIMD_LANES beats per vector instruction (ARCH §10 — normative). |
| Workgroup | Set of work-items sharing a shared-memory window and barrier domain; mapped to ceil(wg_size/32) whole wavefronts on one CU. |
| Grid | Array of workgroups launched by one descriptor. |

A work-item NEVER spans wavefronts; a partial tail workgroup yields a final partial wavefront
represented by an initial EXEC mask of its valid lanes.

## 2. Wavefront Lifecycle

```
EMPTY(slot free) → INIT(hw writes PC=entry, EXEC=partial?, SGPR args, VGPR identity)
  → READY → [ISSUED(beats in flight) ⇄ READY] interleaved by scheduler RR
  → WAIT_* {SCOREBOARD, MEMORY, BARRIER} → READY …
  → DONE(retire slot; completion counted toward kernel)
FAULTED(any fault path) → kernel-level drain → completion(failed)
```

State is per-resident-wavefront in the CU scheduler table (ARCH §11); transitions occur only at
instruction boundaries or fault events.

## 3. Effective Mask Computation

For every vector instruction:

```
effective_mask = EXEC ∧ P[pred]      (pred = P15 ⇒ effective_mask = EXEC)
beat k uses bits [k·L, k·L+L) of effective_mask
```

Rules:
1. Inactive lanes have zero architectural effect (ARCH-INV-002).
2. Masked-out memory lanes issue nothing (INV-016).
3. Scalar instructions ignore masks entirely (uniform context, ADR-007).

## 4. Divergence and Reconvergence (normative — Rev1.1, ADR-011)

Mechanism: **one unified typed mask/control stack per wavefront** (`MASK_STACK`,
`MASK_STACK_DEPTH` frames; default 32, architecture ≥ 32) holding typed frames
FRAME_IF / FRAME_LOOP / FRAME_MANUAL. Hardware never computes post-dominators: every
structured target is compiler-provided in the instruction word. Overflow/underflow are
controlled faults (ARCH-INV-008); all control-flow validation is atomic (no partial
architectural effects on fault).

### 4.0 Architectural mask state

```
EXEC[31:0]      lanes currently executing the present control-flow path
LIVE_MASK[31:0] lanes of the wavefront that have not permanently returned
P0..P14         predicate registers (P15 = unpredicated selector, not writable)
MASK_SP         number of valid stack frames (0 .. MASK_STACK_DEPTH)
current_loop_index   frame index of innermost active LOOP frame (INVALID when none)

Invariant M5-ASSERT-001: EXEC & ~LIVE_MASK == 0        (a retired lane never re-activates)
Launch/reset: EXEC ← LIVE_MASK ← initial_EXEC ; MASK_SP ← 0 ; current_loop_index ← INVALID
```

A lane absent from EXEC may still be LIVE (diverged, continued, broken). A lane absent from
LIVE_MASK is permanently retired and may never appear in EXEC or any frame mask again.

### 4.1 If / else / endif — CBRANCH_IF (0x7C1, FMT=5), RECONV (0x7C2)

Encoding provides both targets explicitly:
```
COND[3:0]      predicate index P0..P14 (15 illegal for branch conditions → fault)
DISP24[47:24]  signed displacement to ELSE path     : else_pc   = PC+1+sext24(DISP24)
BMOD [15:0]    signed displacement to RECONV instr  : reconv_pc = PC+1+sext16(BMOD)
```

At `CBRANCH_IF cond, else_pc, reconv_pc` (validation first: predicate index, both PCs within
code range, MASK_SP < DEPTH — any failure faults with zero state change):
```
T = EXEC ∧ P[cond] ; F = EXEC ∧ ¬P[cond]
push FRAME_IF { parent_exec=EXEC, pending_mask=F, pending_pc=else_pc,
                reconv_pc, phase=THEN }          -- ALWAYS pushed (uniform branches too)
EXEC ← T ; PC ← old_PC + 1                       -- THEN continues fall-through
if T==0 ∧ F≠0: phase←ELSE ; EXEC←F ; PC←else_pc  -- ELSE-only entry
```

At `RECONV` (requires MASK_SP>0, top frame FRAME_IF, PC == frame.reconv_pc; violations raise
FAULT_MASK_STACK_UNDERFLOW / FAULT_ILLEGAL_CONTROL_FLOW / FAULT_RECONVERGENCE_MISMATCH):
```
if phase==THEN ∧ (pending_mask ∧ LIVE_MASK)≠0:   -- first arrival: schedule alternate path
    EXEC ← pending_mask ∧ LIVE_MASK ; PC ← pending_pc
    pending_mask ← 0 ; phase ← ELSE              -- frame stays on the stack
else:                                            -- no live alternate path remains
    EXEC ← parent_exec ∧ LIVE_MASK               -- subject to enclosing-loop eligibility (§4.2)
    pop IF frame ; PC ← reconv_pc + 1
```

Nested ifs nest naturally via LIFO frames (verified to depth ≥ 8). The always-push rule makes
compiler-emitted RECONV uniform: every CBRANCH_IF has exactly one matching RECONV.

### 4.2 Loops — LOOP_BEGIN (0x7C8), LOOP_END (0x7C9), BREAK (0x7CA), CONTINUE (0x7CB)

Control-operand convention (divergence-control instructions only): `COND 0..14 = P0..P14`;
`COND 15 = unconditional (current EXEC)`. Distinct from S_BRA_COND's flag table.

```
LOOP_BEGIN end_label:   push FRAME_LOOP { parent_exec=EXEC, iteration_mask=EXEC(future),
                        continue_mask=0, head_pc=PC+1, end_pc=PC+1+sext24(DISP24),
                        prev_loop_idx=current_loop_index } ; current_loop_index ← new ;
                        EXEC unchanged
CONTINUE [pN]:  M = EXEC (or EXEC∧P[n]); requires nearest LOOP else FAULT_ILLEGAL_CONTROL_FLOW;
                continue_mask |= M ; iteration_mask &= ~M ; EXEC &= ~M ;
                scrub M from IF frames above the loop (no resurrection this iteration)
BREAK [pN]:     same M and legality; future_loop_mask &= ~M ; iteration_mask &= ~M ; EXEC &= ~M ;
                scrub as above; lanes stay LIVE and rejoin at loop exit
LOOP_END pN, head:  validates PC == stored end_pc and DISP-encoded head == stored head_pc
                (mismatch → FAULT_RECONVERGENCE_MISMATCH; no loop → FAULT_ILLEGAL_CONTROL_FLOW);
                candidate = (EXEC | continue_mask) ∧ future_loop_mask ∧ LIVE_MASK ;
                next_mask = candidate ∧ P[cond] ;
                next_mask ≠ 0 → iterate: future=next ; iteration=next ; continue←0 ;
                                 EXEC←next ; PC←head_pc
                next_mask = 0 → exit: EXEC ← parent_exec ∧ LIVE_MASK ; pop LOOP frame ;
                                 current_loop_index ← prev_loop_idx ; PC ← end_pc + 1
```

Broken lanes therefore rejoin after loop exit; returned lanes do not (they left LIVE_MASK).

### 4.3 Early return — RET_KERNEL_WF divergent semantics

```
returning = EXEC ; LIVE_MASK &= ~returning ; EXEC ← 0 ;
scrub returning from ALL frame masks capable of restoring those lanes (control-engine walk);
then automatic unwind engine resumes remaining live paths:
  top IF with live pending path → resume it (EXEC←pending∧LIVE, PC←pending_pc)
  exhausted IF → restore parent_exec∧LIVE (∧ nearest-loop iteration eligibility), pop, repeat
  top LOOP with future∧LIVE ≠ 0 → route to LOOP_END iteration/exit semantics
  MANUAL frame → pop, repeat
  stack empty but LIVE_MASK ≠ 0 → FAULT_INTERNAL (structural impossibility)
LIVE_MASK == 0 → wavefront DONE.
```

Full-wavefront early return with residual structured frames is a legitimate completion: frames
are discarded after proving they hold no live lanes, final depth recorded for debug, and it is
NEVER classified as underflow (Rev1.0 wording corrected). Non-divergent RET (empty stack) is
bit-identical to M2–M4 behavior.

### 4.4 Worked example

```asm
        ; EXEC = LIVE = 0xFFFFFFFF entering
        V_CMP_GT p0, v1, v2     ; per-lane predicate
        CBRANCH_IF p0, ELSE, MERGE
        V_ADD v3, v4, v5        ; THEN path (lanes with p0 true)
        S_BRA MERGE
ELSE:   V_SUB v3, v4, v5        ; alternate path (p0 false lanes)
MERGE:  RECONV                  ; first arrival schedules ELSE; second restores parent EXEC
```

Execution order remains program-visible as if each lane executed its path serially — tested
against the golden simulator's per-lane serial reference.

## 5. Barriers

`BAR.WG` semantics (ARCH §21, INV-012):

1. Every resident wavefront of the workgroup arrives exactly once per generation.
2. Arrival registers a release-fence (workgroup scope) of that wavefront's prior accesses.
3. Waiting consumes no transport resources (deadlock rule ARCH §32.3.3).
4. On full arrival generation: acquire effect granted to all members; execution resumes all
   members' schedulers deterministically (ascending wf id).
5. Illegal patterns (arrival count ≠ membership, duplicate arrival) → FAULT_ILLEGAL_BARRIER;
   watchdog bounds indefinite waits (kernel-level abort, GPU-SYS-REQ-009).

Barriers within divergent code: legal only when all member wavefronts reach it uniformly;
compiler enforces structured placement (barrier outside divergent regions), hardware detects
violation via generation accounting.

## 6. Interaction with Scheduling

- Scheduler picks among READY wavefronts round-robin (ARCH §15); WAIT_* states are skipped
  without starvation (RR order preserved).
- Issue reserves the target pipe for B beats; other wavefronts may issue to *different* pipes
  meanwhile (single-issue-per-CU G1: they wait; multi-pipe overlap is SCHED-001 territory).
- Scoreboard releases destination at final beat commit (ARCH-INV-003); loads release on routed
  response; barriers on generation completion.

## 7. Determinism Statement

Given identical binary + inputs + configuration (including MASK_STACK_DEPTH, SIMD_LANES,
RESIDENT_WAVEFRONTS_PER_CU), instruction issue order per wavefront, arithmetic results, memory
values observed through properly synchronized programs, and PMC event *sets* are deterministic.
Cross-wavefront interleaving affects only performance counters' magnitudes, not results, for
data-race-free kernels under MEM-001. Deterministic-mode (GPU-SW-REQ-012) additionally fixes
reduction ordering conventions and restricts relaxed atomics.

## 8. Occupancy Reference

Equations live in ARCH §31; execution-relevant consequences: residency choices trade latency
hiding vs register pressure; the simulator exposes per-kernel achieved residency and stall-attribution
counters for PERF-001 calibration.

## 9. Verification Obligations (from this document)

1. Golden-vs-RTL divergence equivalence: the ISA simulator executes divergent kernels per-lane
   serially (typed-stack model, ADR-011); RTL must match final state for every test in the suite
   (nested ifs depth ≥ 8, loops with break/continue at multiple nesting levels, early returns,
   partial wavefronts at grid edges).
2. Mask-stack overflow/underflow directed tests assert exact fault codes (INV-008) with atomic
   no-partial-effect behavior.
3. Barrier generation accounting formal property (INV-012) + illegal-barrier injection tests
   — owned by M9/M15; NOT claimed at M5.
4. Beat-slicing equivalence across SIMD_LANES ∈ {4,8,16,32} for divergent kernels too
   (R-08; INV-001/002/025).
5. Reconvergence-target mismatch (corrupt binary) → FAULT_RECONVERGENCE_MISMATCH, not silent
   misexecution.
6. M5 additions: returned-lane non-resurrection (EXEC ⊆ LIVE_MASK always), BREAK/CONTINUE lane
   eligibility across iterations, per-wavefront stack isolation under the M4 scheduler, reset
   with non-empty stacks.

*End of EXEC-001 Rev 1.1.*
