# ARCHITECTURE_BASELINE_REVIEW — M0 / G0-ARCH Package

| Field | Value |
|---|---|
| Review ID | G0-ARCH-BASELINE |
| Date | 2026-08-23 |
| Inputs reviewed | SPEC-000 R0.2 · ARCH-001 · ISA-001 · EXEC-001 · MEM-001 · PERF-001 · SW-001 · VER-001 · FPGA-001 · ROADMAP-001 (+ ADR-001..010, G0_SPEC_REVIEW, ARCH_001_SELF_REVIEW) |
| Disposition | **PASS WITH NON-BLOCKING ACTIONS — recommended for G0-ARCH approval** |

## 1. Consistency Matrix (cross-document)

| Check | Result |
|---|---|
| WAVEFRONT_SIZE=32 identical in all docs; SIMD_LANES ∈ {4,8,16,32} µarch-only | ✅ grep-audited |
| No `LANES_PER_WARP` / prime-hash concepts outside historical review records | ✅ grep-audited |
| "warp" appears only in comparison/historical contexts (SPEC §5 rule) | ✅ grep-audited |
| Gate model: only G0-ARCH authorizes RTL (SPEC §2/§14/§20; ARCH §1; PROJECT_MAP) | ✅ consistent |
| Transport fields: ADR-008 == SPEC GPU-MEM-REQ-002 == MEM-001 §2 == ARCH §20 | ✅ |
| Beat model: ADR-001 == EXEC-001 §3–4 == ISA-001 §5 == ARCH §10 (B=32/L) | ✅ |
| Memory axioms: MEM-001 §7 normative; EXEC barrier effect matches A5; INV-009/010/012 aligned | ✅ |
| Divergence: mask stack + compiler targets; faults 0x05/0x06 in ARCH §23 == EXEC §4 == ISA §21 | ✅ |
| MMA 8×8×8 types: ADR-006 == SPEC GPU-MAT == ISA-001 §17 == ARCH §30 | ✅ |
| FP64 ratios: ADR-005 == SPEC §11 table == ARCH §29 | ✅ |
| Cache: 64 B line, XOR-hash L2 {1,2,4,8,16}, SMEM 32×32 b — SPEC/CACHE rows/MEM §6/ARCH §18–19 | ✅ |
| Scalar datapath mandatory M6–M7: ADR-007 == SPEC GPU-EXEC-REQ-009 == ARCH §13 == ROADMAP M7 | ✅ |
| Milestones: SPEC §14 == ROADMAP §2 (incl. scalar at M7); acceptance criteria §17 aligned | ✅ |
| Perf objectives: GPU-PERF-REQ-006 == PERF-001 §5 verbatim thresholds | ✅ |
| Licensing proprietary: C-07 == ADR-010 == LICENSE.md == THIRD_PARTY.md | ✅ |
| FPGA stages A/B/C/D + clocks: ADR-009 == GPU-FPGA-REQ-002/012 == FPGA-001 §1 == ARCH §35 | ✅ |
| SGP1 container: SPEC GPU-ISA-REQ-014 == ISA-001 App A == SW-001 §4 loader rules | ✅ |

## 2. Defects Found During Review

None requiring document changes. (Two wording fixes were applied inside ARCH-001 during its
authoring and are recorded in its self-review §9.)

## 3. Non-Blocking Items Carried Forward (owned, with resolution evidence)

L2 XOR bit map → CACHE-001 (M10 traces) · RF geometry → REG-001 (M6 conflicts+synthesis) ·
TID final width & timing tables → MEM-001 (M8 histograms) · div/sqrt algorithm + SFU ULP tables
→ FP-001 (M9–M13 oracles) · L1-I size/store-buffer depth → MICRO-001 (M10) · NoC topology →
NOC-001 (M11+) · watchdog defaults/queue counts → CMD-001 · advanced scheduling → SCHED-001.
These are tuning studies within fixed architecture — none are holes.

## 4. Residual Risks

R-01 FP64 FPGA cost · R-03 RF port pressure @SIMD=32 · R-08 beat-fold divergence (mandatory
differential testing per VER-001 §4) · R-04 tool variance (Verilator-primary). All carry
mitigations recorded in SPEC §16 and respective docs.

## 5. Gate Checklist

| # | Criterion | Result |
|---|---|---|
| 1 | All G0-ARCH inputs exist and are internally consistent | ✅ (§1) |
| 2 | Every Rev 0.1 TBD resolved or owned as non-blocking study | ✅ (SPEC §15; §3 above) |
| 3 | Invariants enumerated for assertion/formal seeding (25 × ARCH-INV) | ✅ |
| 4 | Interfaces specified at contract level (ARCH §34; MEM §2) | ✅ |
| 5 | RTL scope unambiguous: authorized ONLY by G0-ARCH approval of this package | ✅ |
| 6 | Traceability req→arch maintained (SPEC §18; ARCH §38) | ✅ |

## 6. Disposition

**PASS WITH NON-BLOCKING ACTIONS.** The M0 architecture baseline is complete and mutually
consistent.

> **G0-ARCH RATIFICATION — RECORDED.** The project principal directed continuation into
> implementation without further pause ("complete all the tasks that have to be done so we can
> start the actual implementation … cannot stop until the end of task"), 2026-08-23. This is
> recorded as principal sign-off of this review package. Effect: **GPU implementation is
> authorized**, beginning with M1 (ISA simulator + assembler/disassembler + regression) per
> ROADMAP-001, under VER-001 discipline. Tag: `gpu-m0-architecture`.

*End of ARCHITECTURE_BASELINE_REVIEW.*
