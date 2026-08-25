# ADR-011 — Unified Typed Divergence Mask Stack (M5)

| Field | Value |
|---|---|
| ADR ID | ADR-011 |
| Status | APPROVED (M5 opening, 2026-08-23) |
| Supersedes | The pre-M5 dual-structure golden-model divergence representation (`wf.stack` deferred-path list + `wf.mstack` saved-EXEC list) and the ambiguous EXEC-001 Rev1.0 §4 wording |
| Parent | ARCH-001 §§10–11, 15; ISA-001 Rev1.4 §16; EXEC-001 Rev1.1 §4; MICRO-001 Rev0.4 §4; directive M5 §11–§24, §49–§82 |

## Context

EXEC-001 Rev1.0 described divergence as a hardware active-mask stack of `{saved_EXEC,
resume_PC}` frames, but the golden simulator implemented two conceptually separate stacks
(a deferred-work list and a saved-mask merge list) with no reconvergence-target check. RTL had
no divergence state at all (M4 CU: flat per-slot EXEC only). M5 requires nested IF, loops with
break/continue, early return, exact overflow/underflow faults, and reconvergence-mismatch
detection. Three divergent definitions cannot coexist: this ADR fixes **one** precise typed
control-flow stack architecture; the golden model, assembler, documentation, and RTL all
implement exactly this.

## Decision

### D1 — One typed unified stack per wavefront

Each resident wavefront owns exactly **one** mask/control stack (`MASK_STACK`) of
`MASK_STACK_DEPTH` frames (default 32; architecture minimum ≥ 32; verification builds may use
2/4/8). There are no auxiliary ad-hoc control stacks. All structured-control operations
(CBRANCH_IF, RECONV, LOOP_BEGIN, LOOP_END, BREAK, CONTINUE, PUSHM, POPM, RET unwind) manipulate
only this stack through the shared mask-control engine.

Frame types:

```
FRAME_IF     (2'b01)   pushed by CBRANCH_IF
FRAME_LOOP   (2'b10)   pushed by LOOP_BEGIN
FRAME_MANUAL (2'b11)   pushed by PUSHM
FRAME_NONE   (2'b00)   invalid/empty slot
```

A frame is one physical record wide enough for every type (register array, not dynamic
allocation); interpretation is type-directed. Exact physical field mapping is normative in
MICRO-001 Rev0.4 §4.

Common physical frame fields (per slot, per depth):

```
frame_type            2    FRAME_IF / FRAME_LOOP / FRAME_MANUAL
parent_exec          32    EXEC before the structure was entered
mask_a               32    IF: pending_mask      | LOOP: iteration_mask | MANUAL: unused (0)
mask_b               32    IF: 0                 | LOOP: continue_mask  | MANUAL: unused (0)
pc_a                 PCW   IF: pending_pc        | LOOP: head_pc        | MANUAL: 0
pc_b                 PCW   IF: reconv_pc         | LOOP: end_pc         | MANUAL: 0
phase                 2    IF phase {THEN=0, ELSE=1}; loop future_mask lives in a per-WF register (see D6)
prev_loop_idx         LW   loop-chain link (index of enclosing LOOP frame; INVALID if none)
valid                 1    frame slot occupied
```

`future_loop_mask` is stored in the LOOP-frame's `mask_a` on push and refreshed at each
LOOP_END continuation; `iteration_mask` tracks eligibility for the current iteration.
(Where MICRO-001 differs in letter, MICRO-001 §4 governs RTL; both documents agree on
semantics.)

### D2 — Stack pointer semantics

`MASK_SP` counts valid frames: `0 .. MASK_STACK_DEPTH`. Empty = 0, full = DEPTH.

```
push(frame):
    if MASK_SP == MASK_STACK_DEPTH → FAULT_MASK_STACK_OVERFLOW (atomic, see D9)
    else stack[MASK_SP] ← frame ; MASK_SP++

pop() → frame:
    if MASK_SP == 0 → FAULT_MASK_STACK_UNDERFLOW (atomic, see D9)
    else MASK_SP-- ; frame ← stack[MASK_SP]
```

Pointer never wraps; index arithmetic is bounds-checked before any state change.

### D3 — LIVE_MASK

Per wavefront, alongside EXEC:

```
LIVE_MASK = lanes that have not permanently returned
EXEC ⊆ LIVE_MASK  (invariant M5-ASSERT-001; checked by assertion + formal)
launch/reset: LIVE_MASK ← initial_EXEC ; EXEC ← initial_EXEC ; MASK_SP ← 0 ;
              current_loop_index ← INVALID
```

A lane may leave EXEC temporarily (divergence, break, continue) while staying LIVE. A lane
removed from LIVE_MASK may NEVER re-enter EXEC or any frame mask (returned lanes never
return). `RET_KERNEL_WF`: `LIVE_MASK &= ~EXEC; EXEC ← 0`, then run the unwind engine (D8).
Wavefront reaches DONE only when LIVE_MASK == 0 (all lanes permanently gone).

### D4 — IF frames (CBRANCH_IF 0x7C1, FMT=5)

Encoding: `COND[3:0]` = predicate index P0..P14 (P15 as branch condition is illegal → fault);
`DISP24[47:24]` = signed ELSE displacement; `BMOD/PAYLOAD[15:0]` = signed RECONV displacement;
both relative to `PC+1`.

```
else_pc   = PC + 1 + sext24(DISP24)
reconv_pc = PC + 1 + sext16(BMOD)
T = EXEC & P[cond] ; F = EXEC & ~P[cond]
validate (pred≠15, else/reconv PCs in code range, MASK_SP < DEPTH) atomically first
push FRAME_IF{ parent_exec=old EXEC, pending_mask=F, pending_pc=else_pc,
               reconv_pc, phase=THEN }           -- ALWAYS pushed, even if T==0 or F==0
EXEC ← T ; PC ← old_PC + 1                    -- THEN path continues fall-through
if T == 0 && F != 0: phase←ELSE; EXEC←F; PC←else_pc   (ELSE-only case)
```

Uniform branches still push one IF frame so compiler-emitted RECONV always has its matching
frame (uniformity is a PMC distinction, not a special case).

### D5 — RECONV (0x7C2, no operands)

Requires `MASK_SP > 0` and top frame type == FRAME_IF, else controlled fault (underflow /
FAULT_ILLEGAL_CONTROL_FLOW respectively). Requires current `PC == frame.reconv_pc`, else
`FAULT_RECONVERGENCE_MISMATCH`. Never pops silently.

```
if phase == THEN and (pending_mask & LIVE_MASK) != 0:
        EXEC ← pending_mask & LIVE_MASK ; PC ← pending_pc
        pending_mask ← 0 ; phase ← ELSE        (frame stays; alternate path runs)
else:
        EXEC ← parent_exec & LIVE_MASK (& nearest-loop iteration eligibility, see D7)
        pop IF frame ; PC ← reconv_pc + 1      (final reconvergence)
```

### D6 — LOOP frames

`LOOP_BEGIN` (0x7C8, FMT=5): `DISP24` = `loop_end_label - (PC+1)`. Pushes
`FRAME_LOOP{ parent_exec=EXEC, iteration_mask=EXEC, continue_mask=0, head_pc=PC+1,
end_pc=PC+1+sext24(DISP24), prev_loop_idx=current_loop_index }`; sets
`current_loop_index` to the new frame; EXEC unchanged.

Nearest-loop tracking: per-wavefront register `current_loop_index` (frame index of innermost
active LOOP, INVALID when none) updated on LOOP_BEGIN push and on LOOP_END pop (restores
`prev_loop_idx`). BREAK/CONTINUE consult it directly — no combinational stack walk on the
hot path; walks happen only inside the multi-cycle control engine when masks must be scrubbed
(D7/D8).

`LOOP_END pN` (0x7C9, FMT=5): `COND[3:0]` selects continue-condition predicate using the
control-operand convention (`COND 0..14 = P[N]`, `COND 15 = current EXEC`); `DISP24` =
encoded loop-head target, validated against stored `head_pc`, and `PC == end_pc` validated,
else FAULT_RECONVERGENCE_MISMATCH (target mismatch) / FAULT_ILLEGAL_CONTROL_FLOW (no loop).

```
candidate  = (EXEC | continue_mask) & iteration_future & LIVE_MASK   -- iteration_future = frame.future_loop_mask
next_mask  = candidate & cond_mask
if next_mask != 0:  future_loop_mask←next_mask ; iteration_mask←next_mask ; continue_mask←0 ;
                    EXEC←next_mask ; PC←head_pc            (iterate)
else:               EXEC ← parent_exec & LIVE_mask ; pop LOOP frame ;
                    current_loop_index ← prev_loop_idx ; PC ← end_pc + 1   (exit)
```

### D7 — BREAK / CONTINUE

Control-operand convention for divergence-control instructions: `COND 0..14 = P0..P14`,
`COND 15 = unconditional (current EXEC)`. This convention is distinct from the S_BRA_COND
flag table (ISA-001 Rev1.4 §16.4).

```
CONTINUE (0x7CB): M = EXEC or EXEC&P[n]; nearest LOOP required else FAULT_ILLEGAL_CONTROL_FLOW
    continue_mask |= M ; iteration_mask &= ~M ; EXEC &= ~M ; scrub M from IF frames above the loop
BREAK (0x7CA):    M = EXEC or EXEC&P[n]; nearest LOOP required else FAULT_ILLEGAL_CONTROL_FLOW
    future_loop_mask &= ~M ; iteration_mask &= ~M ; EXEC &= ~M ; scrub M from IF frames above the loop
```

Scrubbing clears M from parent_exec/pending/continue masks of active IF frames above the
target LOOP so later RECONV cannot resurrect those lanes inside the current iteration. Broken
lanes stay in LIVE_MASK and rejoin at loop exit via `parent_exec & LIVE_MASK`.

### D8 — Early return and automatic unwind engine

`RET_KERNEL_WF` (0x7CF): `returning = EXEC; LIVE_MASK &= ~returning; EXEC ← 0`;
scrub `returning` bits from ALL frame masks capable of restoring them (control-engine stack
walk, multi-cycle OK); then:

```
unwind engine (runs while EXEC == 0 and LIVE_MASK != 0):
    top FRAME_IF with (pending_mask & LIVE_MASK) ≠ 0 → EXEC ← pending&LIVE ; PC←pending_pc ;
        pending←0 ; phase←ELSE ; return to READY
    top FRAME_IF exhausted → EXEC ← parent_exec & LIVE (& loop eligibility) ; pop ; repeat if still 0
    top FRAME_LOOP with (future_loop_mask & LIVE) ≠ 0 → route to LOOP_END semantics (iterate/exit)
    top FRAME_MANUAL → pop (saved_exec ∩ LIVE contributes nothing while EXEC=0) ; repeat
    stack empty but LIVE_MASK ≠ 0 → FAULT_INTERNAL (structural impossibility)
LIVE_MASK == 0 → wavefront DONE (residual frames discarded; final depth recorded for debug;
    NOT classified as underflow)
```

Non-divergent RET (MASK_SP == 0 → LIVE becomes 0) preserves M2–M4 behavior exactly.

### D9 — Atomic faults

Overflow push, underflow pop, reconvergence mismatch, illegal control flow
(`FAULT_ILLEGAL_CONTROL_FLOW = 0x0E`, new), invalid predicate destination (PDST=15),
and out-of-range branch targets modify NO architectural state (EXEC/LIVE_MASK/PC/stack/
SP/predicates) — validation completes before commit. New fault code
`FAULT_RECONVERGENCE_MISMATCH = 0x0D` without moving existing codes.

### D10 — Ownership and isolation

The stack is architecturally private per wavefront: WF0.stack ≠ WF1.stack. The mask-control
engine carries `owner_wfid` for the entire operation (possibly multi-cycle); all frame reads/
writes index storage by owner wfid; assertion M5-ASSERT-016 forbids cross-wfid corruption.
M4 scheduler context switching needs no extra save/restore because stack state is static
per-slot context (register arrays), preserved automatically across READY⇄ISSUED.

## FPGA implementation implications (ADR-009 stages)

- Register-array frame storage: N slots × DEPTH × ~140 b ≈ 4×32×140 ≈ 17.9 kb default — fits
  LUTRAM/distributed RAM on Zynq-7000-class at reduced DEPTH (config ≥ 8 for bring-up) and
  block-RAM or URAM on UltraScale+ at full DEPTH. No vendor primitives in core RTL (platform
  wrappers own mapping, per project rule).
- Multi-cycle control engine keeps the critical path off a monolithic stack walk; single-cycle
  fast path remains for uniform branches.
- No dynamic allocation, no pointer chasing; DEPTH is an elaboration parameter.

## Later ASIC implications

Same organization scales with banked/duplicated frame storage and wider issue; the typed-stack
contract and owner-tagged engine are unchanged. ASIC timing can fold the unwind engine into
the branch unit; the architectural semantics (this ADR) do not move.

## Consequences

- Golden simulator, ISA-001 §16, EXEC-001 §4, MICRO-001 §4, assembler/disassembler, and RTL
  share exactly one divergence definition.
- Pre-M5 golden behavior that conflicts with D1–D9 (dual stacks, unchecked RECONV, mstack-only
  merges, RET-faults-if-stack-nonempty) is retired; M1 kernels are updated to explicit
  ELSE+RECONV label syntax.
- Verification obligations: overflow/underflow atomicity, EXEC⊆LIVE_MASK, non-resurrection of
  returned lanes, mismatch faults, cross-width equivalence — formalized for small DEPTH
  (verification/formal/m5_mask_stack/) and randomized against the golden model at scale.
