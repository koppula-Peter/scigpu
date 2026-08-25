# M3 Gate Review — SIMD Engine and Physical-Lane Folding

| Field | Value |
|---|---|
| Review ID | M3-GATE |
| Date | 2026-08-23 |
| Disposition | **PASS WITH NON-BLOCKING ACTIONS** |

## 1. Scope
One wavefront (WAVEFRONT_SIZE=32) execution context with SIMD_LANES ∈ {4,8,16,32} physical
folding; vector integer subset; EXEC + predicate effective-mask architecture; VGPR bootstrap
storage; mixed scalar/vector streams. Excludes M4+ items (scheduler, divergence, LSU, FP…).

## 2. Starting state
Commit `gpu-m2-scalar` (5fb633a…→04f2bc1 lineage), clean tree; baseline M1 7/7 + M2 GREEN
(`reports/evidence/m3/baseline_m2.log`).

## 3. Pre-M3 corrections
OI-010 predicate encoding/model fix; OI-011 SGPR_COUNT=256 bounds fix. Both closed with
regression evidence (`isa_predication_fix.log`, `post_predication_fix_m1.log`,
`sgpr_256_fix.log`). M1 re-verified green after each.

## 4–5. ISA Rev 1.3 / MICRO-001 Rev 0.2
ISA-001 Rev 1.3 records predication clarification + P15 bypass enforcement + assembler syntax;
no opcode renumbering. MICRO-001 §2 normative for M3 (beats, masks, pipeline contract, timing
examples, mask worked example). Pre-RTL review: reviews/M3_MICROARCHITECTURE_REVIEW.md PASS.

## 6. Module inventory
rtl/compute/vector/{scigpu_vgpr_file_m3, scigpu_predicate_file_m3, scigpu_vector_alu,
scigpu_vector_engine}.sv · rtl/frontend/scigpu_decode_m3.sv · rtl/compute/scalar/
scigpu_m3_control.sv · rtl/core/scigpu_m3_core.sv · rtl/top/scigpu_m3_top.sv · GENERATED
scigpu_isa_pkg.sv (+VMOD/PRED constants).

## 7. SIMD parameter validation
Elaboration $error for SIMD_LANES ∉ {4,8,16,32} and VGPR_COUNT ∉ [8,256]; SGPR range check
retained; launch-time declared-requirement validation → FAULT_INVALID_REGISTER.

## 8. VGPR implementation
Bootstrap 2D array (VGPR_COUNT×32×32b) — documented as NOT the production RF (M6/REG-001/
ADR-002). Lane-oriented read/write port contract preserves the swap.

## 9. EXEC/predicate behavior
EXEC launch-constant; zero-EXEC ⇒ clean empty completion (P10); P15 bypass enforced
(assembler rejects [p15]); effective mask captured once per instruction; VCMP-style inactive
preservation encoded in golden reference now.

## 10–11. ALU pipeline & beats
II=1 beat/cycle, commit lag 1 cycle, retire only after final beat commit; L=4 runs eight
genuine parallel-lane beats (never serializes internally). Empty beats advance counter.

## 12. Directed results
14 programs × 4 widths PASS incl. partial-mask sentinel preservation (P02), in-place ops
(P04), immediates (P05), shifts incl. ≥32 amounts (P06), MUL low-32 (P07), BCAST (P08),
mixed scalar/vector (P09), zero-exec (P10), single-lane sweep lanes0..31×widths (P11),
alternating masks (P12), predication intersection (P13), bypass lock (P14), completion hold
(P17), fetch stalls (P18).

## 13. Width equivalence
Same assembled binary (sha256 recorded in width_binary_sha256.txt) executed on L4/L8/L16/L32:
retire traces identical AND full final state (SGPR/PRED/EXEC/VGPR lane-level) identical to
golden. **L4==L8==L16==L32==golden.**

## 14. Random differential
1000 shared-seed programs × 4 widths = 4000 RTL executions + golden: **0 mismatches**
(`random_differential.log`, `random/seed_manifest.txt`, per-seed artifacts under `random/`).
Timing variation (stall %, latency) rotated per seed.

## 15. Reset stress
40 injection points × 4 widths across SETUP/beat-issue/mid-beat/final-beat/drain/retire/
completion-hold: no ghost writes/completions; relaunch bit-identical (`reset_stress.log`).

## 16. Faults
Invalid declared register (pre-beat, zero beats committed), invalid VMOD, invalid PC, invalid
opcode, bad GETID selector — all controlled codes, fault ≠ success.

## 17. Assertions
M3-ASSERT-001..014 defined; SVA seeds in verification/assertions/ (engine beat/base bounds,
no-retire-before-final-beat, start-only-idle); runtime equivalents enforced by TB monitors.
Formal-capable-tool run remains non-blocking.

## 18. Traceability
VERIFICATION_STATUS.md M3 addendum maps directive §106 list honestly (PASS/PARTIAL/FUTURE/N-A).

## 19. Evidence
reports/evidence/m3/* (baseline_m2, isa_predication_fix, sgpr_256_fix, post_predication_fix_m1,
verilator_lint_l*, build_l*, unit_vector, directed, width_equivalence + sha file,
random_differential + random/, reset_stress, fault_matrix, full_regression, m3_summary.md).

## 20. Known limitations (future milestones, not defects)
No multiple wavefronts/scheduler · no divergence/reconvergence RTL · no vector-compare/predicate-
producing instructions · no production RF banking/operand collector/scoreboard · no LSU/shared/
caches · no FP/MMA/atomics · no command processor/DMA/AXI/driver.

## 21–22. Open issues & exit criteria
OI-006..009 unchanged (009 Vivado smoke still NOT RUN — tool unavailable, non-blocking).
Directive §137 checklist: all mandatory items ✅ (see VERIFICATION_STATUS.md M3 addendum).

## 23. Disposition
**PASS WITH NON-BLOCKING ACTIONS.** Tag `gpu-m3-simd` applied. STOP — M4 awaits user review.
