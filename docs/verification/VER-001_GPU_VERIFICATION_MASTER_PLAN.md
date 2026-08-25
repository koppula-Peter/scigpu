# VER-001 — SciGPU Verification Master Plan

| Field | Value |
|---|---|
| Document ID | VER-001 |
| Title | Verification Master Plan |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2 (GPU-VER-REQ-001..017); ARCH-001 §33/§37; MEM-001 §7/§12; EXEC-001 §9 |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete verification baseline |

---

## 1. Strategy

Verification is simulation-first, oracle-backed, invariant-driven:

```
specification → reference model (ISA simulator = golden)
             → unit TBs → subsystem TBs → system TBs
             → differential vs golden / SoftFloat-class oracles
             → assertions from ARCH-INV-* → selective formal
             → coverage → one-command regression → evidence
```

Rules inherited: no weakened tests (NG-07), no claims without stored tool output (GPU-VER-
REQ-015), root-cause discipline on failures, milestone gates include verification status review.

## 2. Testbench Ladder

| Level | Artifacts | Runs on |
|---|---|---|
| Unit | tb_integer_alu, tb_register_file, tb_operand_collector, tb_scoreboard, tb_wavefront_scheduler, tb_fp32_add/mul/fma, tb_fp64_fma, tb_divsqrt, tb_sfu_appx, tb_mma, tb_shared_memory, tb_coalescer, tb_l1_cache, tb_l2_cache, tb_command_processor, tb_dma, tb_barrier_unit | Verilator (+cocotb harnesses); Icarus smoke where feasible (C-03) |
| Subsystem | tb_compute_unit, tb_cluster_fabric, tb_memory_transport (protocol asserts), tb_launch_path | Verilator |
| System | full-config tiny profiles running SGP1 kernels end-to-end via sim-host driver; cosim with runtime stack | Verilator + Python/C++ |
| Hardware | FPGA-A/B/C/D stage suites (FPGA-001 §bring-up) | HW |

## 3. Oracles and Differential Testing

- **Golden**: ISA simulator (EXEC-001/MEM-001 semantics) — every RTL milestone diffed at
  register/memory/trace level.
- **FP oracle**: Berkeley SoftFloat 3e as *software oracle only* (C-07/ADR-010 — never
  translated to RTL): millions-input randomized campaigns per operation × rounding mode +
  corner suites (SPEC GPU-VER-REQ-004 list). mpmath for SFU accuracy tables.
- **Integer/reference**: C++ model + property checks.

## 4. Invariant-to-Assertion Mapping (seed)

| ARCH-INV | Property style | Method |
|---|---|---|
| 001/002/025 | lane-effect equivalence across SIMD_LANES; inactive-lane zero-effect | differential SIM vs RTL per width; SVA on write ports |
| 003 | dest-ready ⇒ all beats committed | SVA + scheduler scoreboard formal |
| 004/016/017/018 | transport 1:1 TID; masked lanes silent; BE provenance | protocol SVA library (MEM-001 R1–R7); formal on orphan/dup response |
| 005/012 | barrier accounting | counters-as-assertions; directed illegal-barrier injection |
| 006 | reset determinism | reset-mid-flight stress + state-dump compare |
| 007/020/022 | fault/completion integrity; image checksum gate | fault-injection matrix |
| 008 | mask-stack balance/faults | directed overflow/underflow + EXEC-001 suite |
| 009/010 | coherence & atomicity | litmus set (MEM-001 §7.3) under cosim stress; formal on RMW order at single slice |
| 011/013/014 | issue legality; queue monotonicity; DMA visibility | SVA; queue model checker-lite in TB |
| 021/023 | index bounds; ID immutability | decode-time checkers |

Formal priorities (P1): FIFOs, arbiters, scoreboard FSMs, handshake converters, mask-stack,
barrier counter, transport ordering properties.

## 5. Coverage Plan

Functional coverage bins per ISA instruction × format × predicate × rounding × width class;
memory op × size × scope × order; divergence shapes (nesting depth buckets, loop-exit modes);
transport (burst lengths × status codes × backpressure states); config coverage (each SIMD_LANES,
FP64 ratio present/absent, MMA on/off). Code coverage (line/toggle) where tool support exists;
assertion coverage tracked. Targets set per block at its milestone; gaps reviewed at gates.

## 6. Regression Automation

`make regression` stages: lint(verilator) → compile-all → unit → subsystem → system →
differential summaries → coverage merge; JUnit-style logs into `reports/evidence/<date>/`;
nonzero exit on any failure. `make perf-regression` separate (PERF-001 §8) so correctness and
throughput never mix (GPU-PERF-REQ-005).

## 7. Stress & Fault Injection

Long randomized kernels mixing arithmetic/memory/divergence/barriers/atomics against golden;
resource-exhaustion scenarios (MSHR/TID/ring/barrier saturation — expected behavior table);
fault injection: ECC error ports (where implemented), malformed descriptors/opcodes, timeout
watchdog trip, unexpected early responses — verify controlled recovery per INV-007/019/020.

## 8. Milestone Gate Checklists

Each M-gate requires: updated requirement→test matrix (GPU-VER-REQ-016), regression green with
evidence links, coverage summary vs targets, open-failure root-cause log, docs deltas. G0-ARCH
additionally requires the baseline consistency review (ARCHITECTURE_BASELINE_REVIEW.md).

## 9. Evidence Discipline

Every "pass" claim references a stored artifact path; reports auto-indexed by commit hash;
fabrication = project-integrity violation (SPEC GPU-VER-REQ-015).

*End of VER-001 Rev 1.0.*
