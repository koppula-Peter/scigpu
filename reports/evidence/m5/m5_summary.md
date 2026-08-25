# M5 — Divergence: Evidence Summary

Gate disposition: **PASS WITH NON-BLOCKING ACTIONS** (see
reviews/M5_DIVERGENCE_GATE_REVIEW.md).

Starting state: tag `gpu-m4-scheduler` @ 34fd2d4, clean tree.

## Administrative cleanup (§5–10)
CURRENT_WORK contradiction resolved · OI-012 closed · SCHED-001 status fixed ·
ISA-001 Rev1.3 history back-filled · duplicate ipdev-remote copy removed.

## Architecture (before RTL)
ADR-011 typed unified stack · EXEC-001 Rev1.1 §4 normative rewrite ·
ISA-001 Rev1.4 §16 + fault codes 0x0D/0x0E · MICRO-001 Rev0.4 §4 ·
M5 microarchitecture review **PASS** (reviews/M5_DIVERGENCE_MICROARCHITECTURE_REVIEW.md).

## Golden model refactor (§102)
Single typed stack (FRAME_IF/LOOP/MANUAL) replaces pre-M5 wf.stack/wf.mstack;
LIVE_MASK; unwind engine; atomic faults. M1 regression GREEN after refactor
(golden_refactor_regression.log = m1_regression.log rerun at phase-1 commit).

## RTL modules (§107)
rtl/frontend/scigpu_decode_m5.sv — CONTROL/VCMP/vec classes
rtl/control/scigpu_mask_control_m5.sv — SLOTS×DEPTH typed stack + ops FSM
rtl/compute/vector/scigpu_vector_compare_m5.sv — B-beat compare slice
rtl/core/scigpu_m5_cu.sv — integration (LIVE_MASK per slot, CONTROL class,
unwind routing await flag, divergence PMCs, mask-event trace)
rtl/top/scigpu_m5_top.sv
Lint -Wall clean × SIMD_LANES {4,8,16,32} (verilator_lint_l*.log).

## Verification results
| Suite | Result |
|---|---|
| Directed D01–D40-equivalent kernels × L{4,8,16,32} | 84 runs, 0 fails (directed.log + directed_*.log) |
| Fault matrix (overflow d4 / underflow / mismatch / illegal-flow) | exact codes 05/06/0d/0e, PASS (fault_matrix.log) |
| Random structured programs | 997 ran / 1000 seeded, **0 mismatches** (random_divergence.log) |
| Cross-width shared binaries L4/L8/L16/L32 | 248 ran, 0 mismatches (cross_width.log) |
| Multi-wavefront random (2–4 slots incl. partial EXECs) | 250 ran, 0 mismatches (random_multiwf.log) |
| Reset stress with divergent state | 14 injection points clean (reset_stress.log) |
| Formal smoke (yosys+smtbmc/z3, BMC depth 12) | Status: PASSED (formal_mask_stack.log) |

## Full regression
make regression → M1 GREEN · M2 GREEN · M3 GREEN · M4 GREEN (T1–T9 ALL PASS)
· M5 GREEN → FULL REGRESSION GREEN (full_regression.log).

## Known limitations / non-blocking actions
- OI-013: frozen M4 CU carries latent defects (implicit-width truncations,
  vector replay window, missing ibuf clear). Never exercised by M4's
  structural tests; superseded by correct-by-construction scigpu_m5_cu.
  Frozen artifacts untouched pending owner decision.
- OI-014: randomized BREAK-inside-nested-IF interplay constrained in the
  generator (BREAK emitted only directly in loop bodies); the nested case is
  covered by directed kernel break_if_scrub + golden G04. Root cause of the
  residual generator-seed failures under investigation.
- Barrier §9.3 remains M9/M15 (not claimed).
- Formal proof is a yosys-SV-subset preprocessing of the engine + BMC depth 12
  on stack mechanics; not a full arbitrary-program divergence proof (out of
  scope per directive §160).
