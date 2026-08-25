# M5 Microarchitecture Review — Divergence and Reconvergence

| Field | Value |
|---|---|
| Review ID | M5-MICRO |
| Date | 2026-08-23 |
| Disposition | **PASS** |
| Authority gate | Directive §101: RTL implementation authorized only after this review PASSes |

## Scope reviewed
ADR-011 · EXEC-001 Rev1.1 §4 · ISA-001 Rev1.4 §16 · MICRO-001 Rev0.4 §4, against the M4
baseline (tag gpu-m4-scheduler, commit 34fd2d4) and directive M5 §§11–101.

## Item dispositions

| # | Item | Decision | Rationale |
|---|---|---|---|
| 1 | Unified typed stack | ADOPT — one MASK_STACK/wavefront, frames FRAME_IF/LOOP/MANUAL, common physical record (MICRO §4.2) | Retires golden-model dual-stack ambiguity (`wf.stack`/`wf.mstack`); single definition across spec/golden/assembler/RTL |
| 2 | IF algorithm | ADOPT — atomic validate → always-push → T/F split; uniform branches push too | Uniform RECONV pairing removes special cases; overflow impossible post-validation |
| 3 | RECONV algorithm | ADOPT — two-phase (THEN→ELSE→final); PC==reconv_pc check; mismatch fault 0x0D; never silent pop | Fixes EXEC-001 Rev1.0 vs golden divergence; enables deterministic fault on corrupt binaries |
| 4 | Explicit ELSE+RECONV targets | ADOPT — DISP24=else, BMOD[15:0]=reconv, both rel PC+1; no HW post-dominators | Hardware stays checker/executor only (directive §39) |
| 5 | LIVE_MASK | ADOPT — architectural per-wavefront register; launch=initial EXEC; invariant EXEC⊆LIVE_MASK asserted+formalized | Mandatory for correct early return; returned-lane non-resurrection provable |
| 6 | V_CMP write semantics | ADOPT — P[d]=(P[d]&~EXEC)∨(cmp&EXEC); PDST=15 faults pre-beat-0; shared vector engine, B beats | INV-002 continuation; no second lane machine (directive §87) |
| 7 | Loop frame | ADOPT — parent/future/iteration/continue masks + head/end PCs + prev_loop_idx | Supports per-lane iteration counts, progressive dropout |
| 8 | Nested loops | ADOPT — current_loop_index chain via prev_loop_idx; BREAK/CONTINUE target nearest loop only | O(1) locate; walks confined to multi-cycle scrub paths |
| 9 | BREAK | ADOPT — future∧=~M ∧ iteration∧=~M ∧ EXEC∧=~M; lanes stay LIVE; rejoin at loop exit | Verified by D19/D20/D24 |
| 10 | CONTINUE | ADOPT — continue∨=M ∧ iteration∧=~M ∧ EXEC∧=~M; resume next iteration | Verified by D18/D22/D25 |
| 11 | Mask scrubbing above loop | ADOPT — BREAK/CONTINUE clear bits from IF-frame parent/pending masks between loop head and instruction | Prevents resurrection inside current iteration (D21/D22); control-engine walk acceptable in M5 |
| 12 | Early return | ADOPT — RET: LIVE∧=~EXEC; scrub all restorable frame masks; unwind engine resumes live paths; LIVE==0 ⇒ DONE (never underflow-classified) | Fixes Rev1.0 ambiguous wording; preserves non-divergent RET bit-exactness |
| 13 | Mask-unwind engine | ADOPT — multi-cycle internal microsequence (IF pending → exhausted IF → LOOP route → MANUAL pop); FAULT_INTERNAL on structurally impossible empty-stack-live state | Wavefront never exposed READY with EXEC==0 ∧ LIVE≠0 for ordinary fetch |
| 14 | Stack overflow/underflow | ADOPT — SP-counted semantics 0..DEPTH; atomic faults 0x05/0x06 with zero partial effects | Directive §§83–84; exact fault codes through normal fault architecture |
| 15 | Reconvergence mismatch | ADOPT — FAULT_RECONVERGENCE_MISMATCH=0x0D for IF reconv_pc and LOOP end/head mismatch | Corrupt-binary detection (EXEC-001 §9.5) |
| 16 | Illegal control flow | ADOPT — FAULT_ILLEGAL_CONTROL_FLOW=0x0E: BREAK/CONTINUE outside loop, LOOP_END w/o loop, wrong frame type, malformed manual op, COND=15 misuse where rejected | Distinct codes keep diagnostics precise; no existing code moves |
| 17 | Per-wavefront stack isolation | ADOPT — stack storage slot-indexed; engine carries owner_wfid whole-operation; assertions 015/016 | M4 context switch needs no extra save/restore |
| 18 | Scheduler integration | ADOPT — RR arbiter unchanged; CONTROL class via mask_control_ready; one NEW issue/cycle preserved | SCHED-001 `issueable` extension point used as designed |
| 19 | M6 boundary | CONFIRMED — no scoreboard, no production RF, no same-wavefront multi-issue; one-in-flight ordering retained | Predicate/control dependencies naturally ordered |

## Fault-code allocation check
0x0D, 0x0E previously unused (existing: 01,02,03,04,05,06,07,08,0C). No moves. Generated SV
package will be regenerated from scigpu_defs.py (single source of truth).

## Opcode allocation check
7C0 PUSHM, 7C3 POPM, 7C4 SETM, 7C5 ANDM, 7C6 ORM, 7C7 XORM, 7C8 LOOP_BEGIN, 7C9 LOOP_END,
7CA BREAK, 7CB CONTINUE verified free (only 7C1/7C2/7CF existed). No conflicts; no opcode moves.

## Risks accepted (non-blocking)
- Register-array frame storage (~18 kb default config) is a correctness structure; BRAM/URAM
  mapping deferred to FPGA milestones (platform wrappers own it).
- Control-engine stack walks are multi-cycle; performance characterization limited to
  diagnostic metrics per directive §171.
- Unsigned V_CMP variants remain future additive ISA work.

## Exit disposition
**PASS** — proceed to golden-model refactor, then assembler/disassembler, then RTL in
directive §186 order.
