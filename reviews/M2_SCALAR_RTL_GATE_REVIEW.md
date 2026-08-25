# M2 Gate Review — Scalar Prototype RTL (Bootstrap Uniform Scalar Slice)

| Field | Value |
|---|---|
| Review ID | M2-GATE |
| Date | 2026-08-23 |
| Scope | Directive §71 steps 1–27; MICRO-001 Rev0.1; ISA-001 Rev1.2 |
| Disposition | **PASS WITH NON-BLOCKING ACTIONS** |

## 1. Milestone scope
Bootstrap scalar slice per MICRO-001 §1: fetch→decode→SGPR→execute→commit→retire/fault in
synthesizable SV; one context, one instruction in flight; no vector/scoreboard/cache/FP/MMA
(excluded by directive §66–69).

## 2–3. Files
Created: rtl/{generated,common,frontend,compute/scalar,core,top}/* (9 files),
tools/gen_sv_isa.py, tools/m2_run_suite.py, verification/{m2,unit,assertions}/*,
verification/m2/kernels/*.gpuasm (15), docs/microarchitecture/MICRO-001, VERIFICATION_STATUS.md,
evidence m2/*. Modified: models/isa/{scigpu_defs,simulator}.py, assembler/, disassembler/,
tests/run_m1_tests.py (untouched semantics), Makefile, 9 doc status headers, ROADMAP gate mark,
ISA-001 Rev1.1/1.2, PROJECT_MAP, OPEN_ISSUES.

## 4. Baseline: M1 regression pre-M2 = **7/7 PASS** (`reports/evidence/m2/baseline_m1.log`).

## 5. ISA amendment summary (Rev1.2, additive/corrective)
SC_FLAGS{Z,N,C,V}+SCC dedicated state (SGPR63 convention removed everywhere); COND[7:0] table;
opcodes 0x007/8/9/A/B allocated (C/D reserved); CMP SDST reserved-0; GETID WG_X-only;
completion_pc = retiring RET. No existing opcode moved.

## 6. MICRO-001 review
§1 complete and consistent with SPEC/ARCH/ISA/EXEC; later sections explicitly FUTURE. No
conflicts found against approved baseline.

## 7–14. Verification results (evidence: reports/evidence/m2/)
| Item | Result |
|---|---|
| Verilator lint/elab (-Wall) | CLEAN — single documented waiver (UNUSEDPARAM inside GENERATED pkg, justification embedded) |
| Unit (ALU boundaries incl. shifts 0..63 masking & SAR negatives; FLAGS Z/N/C/V/SCC vectors; DECODER legal/negative; SGPR init/read/write/OOB/randomized) | PASS |
| Directed P01–P11 + P18 completion-hold | PASS |
| Differential vs golden retire trace | PASS (directed + **1000/1000 random seeds**, rotated stall/latency profiles; bit-exact traces, final SGPR, completion) |
| Reset stress (40 injections across FSM states incl. FETCH_WAIT/COMMIT/COMPLETE-hold) | CLEAN — no ghost completion/fault/PC/write (INV-006) |
| Fault matrix | illegal-opcode=01, invalid-SGPR=02, invalid-PC=03; no unintended writeback (INV-007/021) |
| Assertions | 10 properties defined; SVA file seeded for formal-capable tools; runtime equivalents enforced in TB monitors under Verilator (PARTIAL by tooling, documented) |
| Vivado smoke | NOT RUN — tool unavailable (recorded per §56; not an M2 blocker) |
| Icarus smoke | compiles clean (informational 'sorry' notes only) |

## 15. Traceability
VERIFICATION_STATUS.md maps the directive's minimum requirement set → module → test → evidence.
Requirement-to-RTL chain begins here (e.g., GPU-INT-REQ-001 → scigpu_scalar_alu.sv → unit.log).

## 16. Evidence paths
reports/evidence/m2/{baseline_m1.log, tool_versions.txt, verilator_lint.log, unit.log,
directed.log, differential.log, reset_stress.log, fault_matrix.log, full_regression.log,
generated_check.log, build_core.log, build_units.log, random/seed_manifest.txt,
random/seed0001..1000/, progs/p*/}, m2_summary.md

## 17. Known limitations (not defects — later milestones)
No vector/SIMD lanes/VGPR/masks · no scheduler/resident wavefronts · no divergence stack ·
no scoreboard/operand collector · no LSU/data memory/shared memory/caches · no FP/SFU/MMA ·
no atomics · no command processor/DMA/AXI/driver. Bootstrap CPI ≈6 cycles/instruction is
implementation-specific, NOT the architectural F1 class.

## 18. Open issues
OI-006 (procurement), OI-007 (rename at clean checkpoint), OI-008 (tuning studies),
**OI-009 NEW** (Vivado unavailable → synth smoke deferred to M19 environment), plus recorded
M1-subset notes in CURRENT_WORK.

## 19. Exit-criterion checklist (directive §72)
Architecture ✅ · RTL ✅ (vendor-free, deterministic reset, portable) · Functional ✅ (MOV/ADD/
SUB/logic/shifts/compare/branch-cond/branch-uncond/GETID/RET) · Faults ✅ (3 codes, no stray
writeback) · Verification ✅ (M1 green, unit, directed, 1000-seed diff, reset, faults,
assertion-equivalents) · Tooling ✅ (lint clean, one-command regression green) ·
Traceability ✅ · Evidence ✅.

## 20. Disposition
**PASS WITH NON-BLOCKING ACTIONS** — non-blocking items: Vivado smoke deferred (OI-009);
SVA runtime enforcement upgrades when a formal-capable simulator joins the toolchain;
Icarus remains smoke-only per C-03.
