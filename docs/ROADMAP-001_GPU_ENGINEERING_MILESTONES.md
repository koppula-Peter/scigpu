# ROADMAP-001 — SciGPU Engineering Milestones

| Field | Value |
|---|---|
| Document ID | ROADMAP-001 |
| Title | Engineering Milestones, Gates, and Exit Criteria |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2 (§14); all baseline docs |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete roadmap |

---

## 1. Gate Model (normative)

```
G0-SPEC ✅ SPEC-000 Rev 0.2 approved → architecture derivation authorized
   └── M0 documents: ARCH-001 · ISA-001 · EXEC-001 · MEM-001 · PERF-001 ·
                     SW-001 · VER-001 · FPGA-001 · ROADMAP-001 · ARCHITECTURE_BASELINE_REVIEW
G0-ARCH ✅ full baseline approved → GPU RTL authorized (nothing before this)
```

## 2. Milestone Table

| M | Name | Exit criteria | Primary artifacts/evidence |
|---|---|---|---|
| M0 | Requirements & architecture | This baseline complete + reviewed; G0-SPEC done; G0-ARCH disposition recorded | doc set; reviews/; baseline review |
| M1 | ISA simulator | Golden sim executes SGP1 kernels (add/mul/branch/reduce) matching hand-computed refs; assembler+disassembler skeleton round-trips ISA v1 subset; `make regression` exists | models/isa; assembler tests; evidence logs |
| M2 | Scalar prototype RTL | Minimal config executes uniform programs through fetch→decode→SGPR ALU→retire; golden-diff clean; lint clean | rtl/ (first authorized code); tb set |
| M3 | SIMD engine | Vector path with masking across ≥2 SIMD_LANES values; INV-001/002/025 differential suite green | beat-model tests |
| M4 | Wavefront scheduler | ≥2 resident wavefronts interleaving under RR; basic PMCs live; scheduler formal smoke | SCHED checks |
| M5 | Divergence | EXEC-001 §9 suite green incl. stack overflow/underflow faults | divergence TB |
| M6 | RF + scoreboard + operand collector | Lane-striped banked VGPRs + SGPR file; RAW/WAW correctness vs golden; bank-conflict counters visible; REG-001 geometry data captured | synthesis area snapshot |
| M7 | Scalar datapath integrated | ADR-007 complete: scalar branches/uniform ops live beside vector path | mixed S/V kernel tests |
| M8 | LSU/coalescing/transport | MEM-001 protocol asserts green; coalescer pattern matrix passes; MSHR exhaustion behavior verified | transport assertion logs |
| M9 | Shared memory + barrier model | Banked SMEM semantics + conflicts counted; software-mode barriers pass; ILLEGAL_BARRIER faults | SMEM TB |
| M10 | Cache hierarchy | L1-I/L1-D/L2 with policies per MEM-001 §6; coherence doc review gate; XOR-hash distribution counters | cache traces → finalize CACHE-001 studies |
| M11 | Multi-CU | ≥2 CUs through fabric; cross-CU traffic correct; fairness tests | fabric stress |
| M12 | Global dispatcher | Occupancy-based placement; occupancy counters; scheduler-utilization objectives measured (PERF-001 §5 baseline #4) | perf report v1 |
| M13 | MMA engine | 8×8×8 tiles FP16/BF16/INT8 differential-clean; dot products; starvation bound test; GEMM tiling demo | MMA oracle campaign |
| M14 | FP64 | FP64 add/mul/FMA (+div/sqrt path start) SoftFloat-oracle campaigns; profile ratios measurable | FP64 evidence pack |
| M15 | Atomics & HW barriers | Scoped RMW at L2 serialization point; litmus subset on RTL; barrier generation property formal | atomic litmus logs |
| M16 | NoC | Packet fabric replaces crossbar behind same transport for large configs; deadlock arguments documented (NOC-001) | NoC stress |
| M17 | Command processor/DMA | Full front end: queues, launch descriptors, IRQ, watchdog, register map v1; command-validation faults | FE system tests |
| M18 | Runtime/toolchain on sim | libscigpu end-to-end via sim-host driver; cosim of real runtime path (GPU-HIF-REQ-005); compiler Phase 3 demo | full-stack system test |
| M19 | FPGA-A synthesis | MINIMAL bitstream implements at planning-class clocks with recorded metrics; regressions pass pre-silicon | Vivado reports |
| M20 | FPGA bring-up | Staged §bring-up complete through kernel execution on board | bring-up log/evidence |
| M21 | Vitis driver | drivers/scigpu bare-metal + required apps green on FPGA-B | Vitis workspace |
| M22 | Linux driver/runtime | /dev/scigpu0 + libscigpu.so host stack operational | LKM tests |
| M23 | HPC optimization | BLAS-class kernels vs PERF-001 rooflines; efficiency objectives analyzed; perf-regression baselines locked | perf reports |

FPGA stage mapping: M19–M20 = FPGA-A; M21 = FPGA-B; post-M21 optimization cycles advance
FPGA-C/D on U55C (ADR-009), each gated by the continuity rule.

## 3. Dependency Notes

M6 blocks M7 (scalar needs RF/scoreboard). M8–M10 order enforces transport-before-caches.
M13/M14 independent (parallelizable). M17 requires M11/M12 placement infra. No milestone may be
skipped or reordered without a recorded directive amendment (SPEC process rules).

## 4. Tag Plan

`gpu-m0-architecture` (this baseline) · `gpu-m1-isa-sim` · `gpu-m2-scalar` · `gpu-m3-simd` ·
`gpu-m4-scheduler` · … mirroring table §2 (SPEC GPU-DOC-REQ-013).

*End of ROADMAP-001 Rev 1.0.*
