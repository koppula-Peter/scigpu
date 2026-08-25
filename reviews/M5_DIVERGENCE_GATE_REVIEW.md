# M5 Gate Review — Divergence and Reconvergence

| Field | Value |
|---|---|
| Review ID | M5-GATE |
| Date | 2026-08-23 |
| Disposition | **PASS WITH NON-BLOCKING ACTIONS** |

## 1. Starting repository state
Tag `gpu-m4-scheduler` @ 34fd2d4, branch main, clean tree (recorded in
CURRENT_WORK.md history). Duplicate publish copy in ipdev-remote removed;
single canonical repository maintained per owner directive.

## 2. M4 baseline
make regression M1–M3 GREEN + M4 full suite T1–T9 ALL PASS re-verified at gate
(reports/evidence/m5/baseline_m4.log, full_regression.log).

## 3. Stale project-state fixes
CURRENT_WORK contradiction resolved · OI-012 closed · SCHED-001 → IMPLEMENTED ·
ISA Rev1.3 history back-filled · evidence: project_state_cleanup.log.

## 4–7. Architecture documents
ADR-011 · EXEC-001 Rev1.1 §4 · ISA-001 Rev1.4 §16 (+0x0D/0x0E faults,
control-cond nibble) · MICRO-001 Rev0.4 §4 — all complete before RTL; M5 micro
review PASS on record before first RTL commit.

## 8. Golden-model refactor
Typed unified stack; LIVE_MASK; unwind engine; atomic faults; legacy
non-divergent RET bit-compatible. M1 GREEN post-refactor.

## 9. Opcode/fault additions
0x7C0/7C3–7CB allocated (no moves); FAULT_RECONVERGENCE_MISMATCH=0x0D,
FAULT_ILLEGAL_CONTROL_FLOW=0x0E; generated package drift-free
(generated_check.log).

## 10–16. Vector compare / stack / CBRANCH / RECONV / loops / break / continue / early return
scigpu_vector_compare_m5 shares backend ownership & VGPR read port (no second
lane machine); scigpu_mask_control_m5 implements ADR-011 D1–D10 with
atomic-fault discipline; m5_cu integrates CONTROL class + unwind routing.

## 17. Scheduler integration
RR arbiter unchanged; CONTROL issueability via mask_control_ready +
same-slot vector RAW gate; one NEW issue/cycle preserved; sched_issue_pipe
now driven (scalar/vector/control/fault).

## 18. PMCs
22 counters incl. PMC_PREDICATE_WRITES … PMC_EARLY_RETURN_LANES.

## 19. Formal
yosys + yosys-smtbmc(z3), BMC depth 12 on the engine (SV-subset preprocessed
copy): SP bounds, done/fault exclusivity, empty-pop underflow code+atomicity,
EXEC⊆LIVE on commits — Status: PASSED (formal_mask_stack.log).

## 20–27. Test results
Directed ×4 widths: 84 runs 0 fails · Fault matrix exact codes · Random
997 programs 0 mismatches (failures preserved under failures/) · Cross-width
248 shared binaries identical to golden · Multi-wf 250 scenarios (incl.
partial EXECs) 0 mismatches · Reset 14 points clean.

## 28. Requirement traceability
See VERIFICATION_STATUS.md M5 section (SPEC→spec docs→RTL→test→evidence).

## 29. Invariant status
ARCH-INV-001/002/006/007/**008 PRIMARY**/011/015/021/025 updated in
VERIFICATION_STATUS.md; INV-003 remains PARTIAL until M6.

## 30. Open issues
OI-006/007/008/009 carried (non-blockers). New: OI-013 (frozen M4 CU latent
defects; superseded by m5_cu), OI-014 (random BREAK-nesting constraint).

## 31. Evidence
reports/evidence/m5/ (40+ files): baseline_m4.log, tool_versions.txt,
cleanup/isa/generated/lint logs, directed_*.log, fault_matrix.log,
random_divergence.log, cross_width.log, random_multiwf.log, reset_stress.log,
formal_mask_stack.log, full_regression.log, m5_summary.md.

## 32. Known limitations
No scoreboard/production RF (M6) · no LSU/SMEM/barriers/cache/multi-CU (M8–M11)
· FP compares unimplemented in RTL (integer only, §99) · formal is stack-
mechanics smoke, not full-program proof · randomized BREAK restricted per
OI-014.

## 33. Exit checklist
Baseline green ✓ admin cleanup ✓ architecture docs ✓ micro review PASS ✓
vector compare ✓ simple/uniform/nested(≥8) divergence ✓ depth-32 stack ✓
overflow/underflow exact ✓ mismatch fault ✓ loops ✓ BREAK ✓ CONTINUE ✓ nested
loops ✓ early return ✓ partial wavefronts ✓ multi-wavefront isolation ✓ reset ✓
formal smoke ✓ random ≥1000 @0 mismatches ✓ cross-width ≥250 equal ✓ full
regression GREEN ✓.

## 34. Disposition
**PASS WITH NON-BLOCKING ACTIONS** — tag `gpu-m5-divergence`; proceed to
M6 — Register File + Scoreboard + Operand Collector.
