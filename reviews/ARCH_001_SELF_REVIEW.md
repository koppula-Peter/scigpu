# ARCH-001 Self-Review

| Field | Value |
|---|---|
| Review ID | ARCH-001-SR |
| Date | 2026-08-23 |
| Object | `docs/architecture/ARCH-001_GPU_SYSTEM_ARCHITECTURE.md` Rev 1.0 |
| Verdict | **COMPLETE — recommended for G0-ARCH** with recorded non-blocking items (§8); no substantive architecture issues outstanding |

## 1. Completeness Check (directive §35 subjects)

| Required subject | Covered in |
|---|---|
| Product architectural context (host→…→external memory) | §2 Fig 1 |
| Architectural hierarchy (front end…platform adapters) | §5, §6 |
| Compute cluster role/ownership | §8 Fig 3 |
| Compute unit (all listed sub-blocks) | §9 Fig 4 |
| Logical vs physical width (dedicated section, beats, mask slicing, completion, scoreboard-ready) | §10 Fig 5/6 |
| Architectural state (device/CU/wavefront/workgroup/work-item) | §11 |
| Scheduling hierarchy | §15 Fig 8 |
| Occupancy equations + limiting resources | §31 |
| Register architecture (high-level) | §12 Fig 7 |
| Scalar/vector interaction | §13 |
| FP architecture coexistence | §29 |
| Matrix/SIMT relationship | §30 |
| Memory hierarchy | §17 Fig 10, §18 Fig 11, §19 Fig 12 |
| Host interface generic (non-AXI) | §6.1, §20, §34.1 |
| Internal protocol boundaries | §20, §34 |
| Clock/reset | §24 Fig 16 |
| Interrupt/fault | §23 Fig 15 |
| Debug/observability | §25 Fig 17 |
| RAS | §25 |
| Security/isolation hooks | §26 |
| Parameterization model (arch vs µarch) | §27 |
| FPGA mapping strategy | §35 |
| ASIC portability | §36 |
| Scalability limits / bottlenecks | §32.1/32.2 |
| Deadlock risks | §32.3 |
| Architecture invariants with IDs | §33 (ARCH-INV-001..025) |
| Interface tables | §34 (13 interfaces) |
| Latency contracts (classes, not cycles) | §14.1 |
| Performance model hooks (quantities only, no fabricated numbers) | §31 |
| Traceability | §38 |
| Verification obligations | §37 |
| Diagrams (18 required) | Figures 1–18 present, all referenced from prose |

## 2. SPEC-000 Traceability Check

All 24 SPEC requirement groups mapped in §38; spot-verified: GPU-EXEC-REQ-002→§10;
GPU-MEM-REQ-002→§20/34.8; GPU-FPGA-REQ-002→§35; GPU-PERF-REQ-006→§31 (targets owned by
PERF-001, none fabricated here). ✅

## 3. Interface Consistency Check

Transport fields in §20 == ADR-008 list == SPEC GPU-MEM-REQ-002. Every §34 row names ordering,
backpressure, IDs, widths (parameterized where applicable), errors, domain. No AXI inside core;
AXI appears only as platform translation. ✅

## 4. Logical-vs-Physical Lane Consistency Check

WAVEFRONT_SIZE=32 constant in §10/§11/§27/§28; beats=32/SIMD_LANES; INV-001/002/003/025 enforce
semantic invariance; profiles vary SIMD_LANES only. No residual "LANES_PER_WARP" concept. ✅

## 5. Memory-Path Consistency Check

LSU→coalescer(per-beat)→L1-D(write-through default)→L2 slices(XOR, point of coherence/atomics)
→fabric→platform. Shared memory separate with no global traffic path (Fig 10). DMA rides the
same transport (no side doors). Coherence policy explicit (G1 synchronized; flush/invalidate).
✅

## 6. Software-Visible State Consistency Check

§11 state inventory == ISA/SW needs: wavefront PC/EXEC stack/VGPR/SGPR/predicates/scoreboard;
workgroup barrier generation + SMEM window; device ID/queues/faults/PMCs. ABI identity in VGPR
startup regs (per-lane), arguments in SGPRs (uniform) — matches ADR-007 and SW-001. ✅

## 7. FPGA Portability Check

No vendor primitives in core (§35/§36); all RAMs inference-friendly via geometry hooks; clock/
reset adaptation at platform boundary (§24); profiles map to stages A/B/C/D with honest planning
clocks. ✅

## 8. Unresolved (non-blocking) Items — with owners

1. L2 XOR bit-selection exact map → CACHE-001 (evidence: slice-conflict counters M10).
2. RF bank geometry/replication → REG-001 (conflict counters + synthesis M6).
3. TID final width, transport timing tables → MEM-001 (outstanding histograms M8+).
4. div/sqrt microarchitecture + SFU error tables → FP-001 (oracle campaigns M9–M13).
5. L1-I size per profile, store-buffer depth → MICRO-001 (traces M10).
6. NoC topology/VC plan → NOC-001 (traffic models M11+).
7. Watchdog defaults, queue counts/priorities → CMD-001 (bring-up + use cases).
8. Advanced scheduling policies → SCHED-001 P2 studies (utilization counters M12+).

## 9. Contradictions Found

None remaining after drafting; two wording fixes applied during authoring: (a) §14.1 MMA moved
from "F2" to "V variable-bounded" class to match §30 reservation semantics; (b) §34.5/34.6 widths
annotated parameterized to avoid implying fixed L. Both reflected in final text.

## 10. Major Technical Risks

- R-08 beat-folded divergence (mitigated by INV-025 differential testing across widths —
  mandatory obligation §37.1).
- R-03 RF port pressure at SIMD_LANES=32 (REG-001 study; operand collector serialization is the
  fallback).
- R-01 FP64 area on FPGA (ADR-005 ladder; HPC 1:1 remains U55C/ASIC-class option).
- Single-issue G1 throughput ceiling (accepted for G1; SCHED-001 owns improvement path).

## 11. Verdict

ARCH-001 is internally consistent, directive-compliant, and sufficient to derive MICRO/SCHED/
REG/FP/CACHE/NOC/CMD documents. **No substantive architecture issues remain.** Non-blocking
items (§8) carry owners and resolution evidence. Recommended: proceed to remaining baseline
documents (ISA-001 … ROADMAP-001), then ARCHITECTURE_BASELINE_REVIEW for G0-ARCH.
