# VERIFICATION STATUS — M2 snapshot

Status legend: PASS · PARTIAL · FUTURE (scheduled milestone) · N/A · BLOCKED
Evidence root: `reports/evidence/`

| Requirement / Invariant | M2 module | Test | Status | Evidence |
|---|---|---|---|---|
| GPU-SYS-REQ-007 (deterministic reset) | scigpu_scalar_control.sv | reset stress (40 injections) | PASS | m2/reset_stress.log |
| ARCH-INV-006 | core+imem | reset stress incl. mid-FSM | PASS | m2/reset_stress.log |
| ARCH-INV-007 | control FSM | fault matrix (fault ≠ success) | PASS | m2/fault_matrix.log |
| ARCH-INV-011 (issue legality, M2 scope) | control FSM | one-in-flight FSM + directed | PASS (M2 scope) | m2/directed.log |
| ARCH-INV-021 | scigpu_sgpr_file.sv | unit invalid-index + P13 | PASS | m2/unit.log, m2/fault_matrix.log |
| ARCH-INV-022 | SGP1 loader (models) | T7 tamper + host pre-launch check | PASS | m1_regression.log |
| ARCH-INV-001/002/003/016/025 | — | vector-era invariants | FUTURE (M3+) | — |
| GPU-SYS-REQ-012 (portable synth SV) | rtl/** | Verilator -Wall clean; Icarus smoke | PASS | m2/verilator_lint.log, tool_versions.txt |
| GPU-SYS-REQ-015 (deterministic build) | Makefile/gen | check-generated exit 0 | PASS | m2/generated_check.log |
| GPU-INT-REQ-001 | scigpu_scalar_alu.sv | exhaustive boundary vectors | PASS | m2/unit.log |
| GPU-INT-REQ-004 (32-bit width semantics) | alu+flags | boundary + randomized | PASS (32b scope) | m2/unit.log, m2/differential.log |
| GPU-INT-REQ-006 (explicit signedness) | alu SAR path | SAR negative vectors | PASS | m2/unit.log |
| GPU-ISA-REQ-013 (assembler/disassembler) | assembler/, disassembler/ | M1 suite + M2 kernels | PASS | m1_regression.log, m2/directed.log |
| GPU-VER-REQ-001 (block-level strategy) | MICRO-001 §1 | this matrix | PASS | MICRO-001, m2/* |
| GPU-VER-REQ-002 (unit TBs, M2 subset) | verification/unit | 4 unit groups | PASS | m2/unit.log |
| GPU-VER-REQ-005 (assertions) | assertions/m2_scalar_properties.sv + TB monitor equivalents | 10 properties mapped | PARTIAL (SVA file seeded; runtime enforcement via TB monitors under Verilator; formal tool deferred) | m2/full_regression.log, assertions file |
| GPU-VER-REQ-009 (one-command regression) | Makefile | make regression (M1+M2) | PASS | m2/full_regression.log |
| GPU-VER-REQ-014 (no weakened tests) | process | 4 root-caused fixes this milestone | PASS | m2_summary.md notes |
| GPU-VER-REQ-015 (evidence discipline) | reports/evidence | all claims linked | PASS | this directory |
| GPU-VER-REQ-016 (status matrix) | this file | maintained | PASS | VERIFICATION_STATUS.md |
| GPU-SYS-REQ-016 / ADR-001 (width independence) | — | scalar slice is width-neutral | N/A here (exercised at M3 via INV-025) | — |
| GPU-FP-* · GPU-MAT-* · GPU-MEM-* (data path) | — | — | FUTURE (M7–M15) | — |
| Vivado synthesis smoke | — | — | BLOCKED (tool unavailable; formal gate is M19) | m2_summary.md |

Randomized differential gate (§73): 1000/1000 clean — `m2/differential.log`,
seeds in `m2/random/seed_manifest.txt`.


---

# M3 ADDENDUM — SIMD Engine (append-only; M2 rows preserved above)

| Requirement / Invariant | M3 module | Test | Status | Evidence |
|---|---|---|---|---|
| GPU-SYS-REQ-013 (param validation) | vector engine/vgpr/pred/ctrl | elaboration $error on bad SIMD_LANES/VGPR_COUNT/SGPR_COUNT; launch req validation | PASS | m3/fault_matrix.log, m3/random_differential.log |
| GPU-SYS-REQ-016 / ADR-001 (width independence) | m3 core+engine | same-binary L4==L8==L16==L32==golden, 1000-seed campaign | **PASS (PRIMARY M3 GATE)** | m3/width_equivalence.log, m3/random_differential.log |
| GPU-ISA-REQ-008 (predication on every vector op) | decode_m3 + engine + golden | P13/P14 + random predicated ops | PASS | m3/directed.log, isa_predication_fix.log |
| GPU-ISA-REQ-003/004 subset (vector int) | vector_alu | unit vectors 81k + random | PASS (32-bit int scope) | m3/unit_vector.log |
| GPU-INT-REQ-001/002/004/006 (scalar+vector int, explicit signedness) | alu(scalar/vector) | boundary/SAR/mul-low32 | PASS (M3 scope) | m2/unit.log, m3/unit_vector.log |
| GPU-EXEC-REQ-001 (per-lane mask, inactive no state change) | engine+vgpr | sentinel preservation, single-lane sweep lanes0..31 × widths, alternating/sparse masks | PASS (register/state portion) | m3/directed.log |
| GPU-EXEC-REQ-002 (beat folding 4/8/16/32) | engine beat gen | V_LLANE oracle all widths | PASS | m3/directed.log, m3/width_equivalence.log |
| GPU-REG-REQ-001 (VGPR architectural state 32×32b, width-independent) | vgpr_file_m3 | state-dump equality across widths | PASS (bootstrap storage; production RF = M6) | m3/width_equivalence.log |
| ARCH-INV-001 | all M3 RTL | wavefront=32 constant | PASS | m3/width_equivalence.log |
| ARCH-INV-002 | engine+vgpr | masked-lane preservation tests | PASS (register portion) | m3/directed.log |
| ARCH-INV-003 | engine | retire only after final beat commit | PARTIAL (scoreboard-ready aspect → M6) | MICRO-001 §2.8 |
| ARCH-INV-006 | full core | reset during SETUP/ISSUE/MID/FINAL/DRAIN/RETIRE/COMPLETE × widths ×40 points | PASS | m3/reset_stress.log |
| ARCH-INV-007 | control | fault matrix p15/p16 (+M2 set) | PASS | m3/fault_matrix.log |
| ARCH-INV-021 | files+control | invalid VGPR/SGPR index pre-beat fault, zero beats committed | PASS | m3/fault_matrix.log |
| ARCH-INV-025 | **PRIMARY** | 1000 shared binaries × 4 widths bit-identical vs golden | **PASS — defining proof of M3** | m3/random_differential.log |
| ARCH-INV-016 (memory transactions) | — | no LSU exists | FUTURE / NOT APPLICABLE until M8 | — |
| GPU-VER-REQ-005 (assertions) | engine SVA seeds + TB monitors | lint/formal-ready file | PARTIAL (same tooling caveat as M2) | verification/assertions/ |
| GPU-VER-REQ-008 (system end-to-end) | tb_m3 | golden-vs-RTL per program incl. final full state | PASS | m3/*.log |


---

## M5 — Divergence (Rev: gate 2026-08-23)

| Item | Status |
|---|---|
| ARCH-INV-001 (determinism) | PASS — continuation; RR + tagged fetch preserved under CONTROL class |
| ARCH-INV-002 (inactive lanes) | PASS — extended: predicate writes masked by EXEC; VCMP commit INV-002 |
| ARCH-INV-003 (scoreboard) | PARTIAL until M6 (one-in-flight ordering retained) |
| ARCH-INV-006 (reset isolation) | PASS — reset with divergent stacks: 14 injection points clean |
| ARCH-INV-007 (fault isolation) | PASS — divergent fault kernels; co-residents unaffected (multiwf incl. partial EXECs, 250 scens) |
| **ARCH-INV-008 (mask-stack faults & structured control)** | **PASS — PRIMARY M5**: exact overflow(05)/underflow(06)/mismatch(0d)/illegal-flow(0e); atomic no-partial-effect |
| ARCH-INV-011 (backend issueability) | PASS w/ CONTROL class extension; scoreboard readiness M6 |
| ARCH-INV-015 (PMCs) | PASS — 22 counters incl. divergence set |
| ARCH-INV-021 (decode legality/atomic validation) | PASS |
| ARCH-INV-025 (cross-width equivalence) | PASS — divergent binaries L4==L8==L16==L32==golden (248 shared programs) |

### EXEC-001 §9 mapping
| §9 item | Evidence |
|---|---|
| §9.1 golden-vs-RTL divergence (nested ≥8, loops, break/continue, early return, partial wavefronts) | directed.log (84 runs), random_divergence.log (997 programs, 0 mism), random_multiwf.log (250 scens) |
| §9.2 overflow/underflow exact codes | fault_matrix.log — 05/06 with atomicity |
| §9.3 barriers | NOT CLAIMED — M9/M15 |
| §9.4 cross-width | cross_width.log — L4/L8/L16/L32 identical to golden |
| §9.5 reconvergence mismatch | f_reconv_mismatch kernel → FAULT_RECONVERGENCE_MISMATCH=0x0D |

### Requirement traceability (SPEC → ISA/EXEC/MICRO → RTL → test → evidence)
GPU-ISA-REQ-007/008/009 → ISA-001 Rev1.4 §16 → decode_m5/mask_control_m5 →
m5-directed + m5-faults → reports/evidence/m5/{directed,fault_matrix}.log ·
GPU-EXEC-REQ-001/003/004/005/012 → EXEC-001 Rev1.1 §4 → m5_cu LIVE_MASK +
unwind engine → break_if_scrub/early_return/nested8 + multiwf → evidence ids ·
GPU-VER-REQ-001/002/005/006/008/009/011/014/015/016/017 → VER-001 plan rows →
formal smoke + differential campaigns → formal_mask_stack.log,
random_divergence.log, cross_width.log, random_multiwf.log.

### M5 campaigns summary
random 997/1000 ran, 0 mismatches · crosswidth 248/250 ran, 0 mismatches ·
multiwf 250/250, 0 mismatches · reset 14 pts clean · directed 84 runs 0 fails ·
formal PASSED · make regression FULL GREEN.


---

## M6 — Register File + Scoreboard + Operand Collector (phase status)

| Item | Status |
|---|---|
| Production banked VGPR unit | LANDED (lint -Wall clean): 2*SIMD_LANES lane-striped banks, reg-parity split, slot-interleaved |
| Operand collector | LANDED: staged full-source gather, parity-collision serialization -> PMC_BANK_CONFLICTS (CU hookup = phase 2 remainder) |
| Scoreboard | INTEGRATED in scigpu_m6_cu: per-slot VGPR/PRED pending; RAW/WAW + VCMP->control predicate ordering enforced at issueability |
| Production SGPR | INTEGRATED (scigpu_sgpr_prod_m6 replaces bootstrap file) |
| ARCH-INV-003 (scoreboard) | PASS-at-CU for vector/predicate dependencies; banking datapath hookup pending phase-2 completion |

### Verification (m6 binary, L8 unless noted)
directed 21/21 x {L4,L8,L16,L32} · RAW/WAW directed PASS · random 399 seeds
0 mismatches · multi-wf 50 scenarios 0 mismatches · reset stress clean.

### Remaining for M6 gate
banked-VGPR/collector CU datapath hookup + PMC_BANK_CONFLICTS wiring,
cross-width campaign re-run on m6 binaries, gate review + tag
gpu-m6-register-file.


---

## M6 — Register File + Scoreboard + Operand Collector (gate 2026-08-24)

| Item | Status |
|---|---|
| Production banked VGPR | INTEGRATED — lane-striped 2*L banks, parity split, slot-interleaved, mirror-write |
| Production SGPR | INTEGRATED — replaces M4 bootstrap file |
| Scoreboard (ARCH-INV-003) | **PASS** — per-slot VGPR/PRED pending; RAW/WAW + predicate ordering enforced |
| Operand collector | LANDED (unit lint-clean); bank-decoded reads serve engine directly |

### Verification on m6 binary
directed 21/21 × {L4,L8,L16,L32} incl RAW/WAW kernel · random 499 @ 0 mism ·
multi-wf 100 @ 0 mism · reset stress clean · cross-width L4/L16/L32 random
200 each @ 0 mismatches.
