# CURRENT_WORK

## Current completed milestone
**M4 — Wavefront Scheduler — COMPLETE**

Gate:
PASS WITH NON-BLOCKING ACTIONS (`reviews/M4_WAVEFRONT_SCHEDULER_GATE_REVIEW.md`)

Tag:
`gpu-m4-scheduler` (commit 34fd2d4)

Gates/milestones: G0-SPEC ✅ · G0-ARCH ✅ · M0 ✅ · M1 ✅ · M2 ✅ · M3 ✅ · **M4 ✅**
Tags: `gpu-m0-architecture` `gpu-m1-isa-sim` `gpu-m2-scalar` `gpu-m3-simd`
`gpu-m4-scheduler`

## Completed (M4 highlights)
- Deterministic RR scheduling of RESIDENT_WAVEFRONTS_PER_CU resident wavefronts;
  scheduler formally verified (yosys-smtbmc/z3, N=2/3/4).
- Per-slot full context, tagged fetch, shared scalar backend + vector engine,
  per-wavefront completion with fault isolation.
- D01 smoke + T1–T9 full suite PASS on L4/L8/L16/L32, N=3/5, non-power-of-two N,
  reset mid-flight + slot reuse.
- Evidence: `reports/evidence/m4/`.

## Current milestone
**M5 — Divergence — COMPLETE**

Gate:
PASS WITH NON-BLOCKING ACTIONS (reviews/M5_DIVERGENCE_GATE_REVIEW.md)

Tag:
`gpu-m5-divergence`

Highlights: ADR-011 typed mask stack (golden+RTL), LIVE_MASK + unwind engine,
vector-compare predicate unit, CONTROL scheduler class, exact fault codes,
directed 84/84, random 997 @ 0 mismatches, cross-width 248 @ 0, multi-wf 250
@ 0, reset clean, formal PASSED, make regression M1–M5 FULL GREEN.

## Current milestone
**M6 — Register File + Scoreboard + Operand Collector — COMPLETE**

Gate:
PASS WITH NON-BLOCKING ACTIONS (reviews/M6_GATE_REVIEW.md)

Tag:
`gpu-m6-register-file`

Highlights: banked VGPR integrated in m6_cu datapath; production SGPR;
per-slot scoreboard enforcing RAW/WAW/predicate ordering; directed 21/21 x4
widths; random 499 @ 0 mismatches; multi-wf 100 @ 0; cross-width L4/L16/L32
200 each @ 0; reset clean.
Landed: production SGPR + scoreboard INTEGRATED in scigpu_m6_cu (RAW/WAW +
VCMP->control predicate ordering verified: directed 21/21 x L8 incl. RAW/WAW
kernel, random 399 @ 0 mism, multi-wf 50 @ 0, reset clean).
Banked-VGPR/collector units lint-clean; datapath hookup has addressing issue
tracked as OI-015.

Landed (lint -Wall clean):
- rtl/compute/vector/scigpu_vgpr_banked_m6.sv  (lane-striped, 2*L banks,
  slot-interleaved, collector read ports, conflict output)
- rtl/compute/vector/scigpu_operand_collect_m6.sv (staged gather; parity-
  collision serialization -> PMC_BANK_CONFLICTS)
- rtl/compute/vector/scigpu_scoreboard_m6.sv (per-slot VGPR/PRED pending:
  RAW/WAW/predicate ordering; closes ARCH-INV-003 at integration)
- rtl/compute/scalar/scigpu_sgpr_prod_m6.sv (production SGPR)
- MICRO-001 Rev0.5 §5 normative-at-gate

Next (phase 2): m6_cu integration (bootstrap storage retirement, scoreboard
gating in issueability, staged-supply datapath mux, bank-conflict PMC),
directed RAW/WAW/conflict kernels, differential campaigns, gate review.

## Current milestone
**M7 — FP32 Vector Arithmetic — phase 2 COMPLETE (OI-016 closed)**

Highlights:
- scigpu_fp32_alu.sv fully rewritten: IEEE 754 SP RN-even, subnormals,
  canonical qNaN; GRS adder with asymmetric on-grid-half tie handling;
  exact-product multiplier + unified exact-value rounder; I2F/F2I exact with
  saturating truncation.
- Unit TB (verification/unit/tb_fp32.cpp): directed edges + 30k random x8
  lanes vs host IEEE SP — PASS 0/240424 (reports/evidence/m7/fp32_unit.log).
- Integrated: vector_alu drives FP ops 16..20 from decode_m5 through
  fp32_alu; core differential kernels fp_arith + fp_consts PASS on m6
  binary vs golden (reports/evidence/m6/directed_fp_*.log).
- va_op[4:0] reconciliation across decode_m3/m3_control/m5_cu/m3_core
  (decode_m5 already emitted 5-bit ops); width nits fixed at source;
  m5-lint WIDTH waivers documented (pre-existing at HEAD).
- Regression: M1 GREEN · M2 GREEN · M3 GREEN (lint/build x4, unit,
  directed, width-equiv, random 1000x4, reset, faults) · M4 GREEN ·
  M5 GREEN (incl. formal) · M6 directed 23/23 @ L8 incl. FP kernels.

Next (phase 3): M7 gate review — random FP differential campaigns
(structured float kernels), V_FMA.F32 single-rounding path, F32 compare
(VFCMP.*) class, then tag gpu-m7-fp32.

## Open issues
OI-006 procurement · OI-007 rename at clean checkpoint · OI-008 tuning studies ·
OI-009 Vivado 2025.2 unavailable (non-blocking) · OI-010/OI-011/OI-012 closed.
