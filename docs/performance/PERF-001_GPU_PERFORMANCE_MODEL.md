# PERF-001 — SciGPU Performance Model

| Field | Value |
|---|---|
| Document ID | PERF-001 |
| Title | Performance Model, Roofline Methodology, and Efficiency Objectives |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2 (GPU-PERF-REQ-001..009); ARCH-001 §31–32 |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete performance-model baseline |

---

## 1. Principles

No absolute TFLOP/s or GB/s numbers are invented before synthesis/hardware baselines exist
(GPU-PERF-REQ-006). This document defines the *formulas*, *measurement method*, and
*engineering objectives*; measured values land in `reports/performance/` with evidence.

## 2. Theoretical Peak Formulas

Per configuration C with clock f (measured, never assumed):

```
Beats(C)          = 32 / SIMD_LANES
FP32_peak(C)      = NUM_CU × SIMD_LANES × 2 × f              [FLOP/s]   (1 FMA = 2 FLOP)
FP64_peak(C)      = FP32_peak(C) × FP64_ratio                            (ratio ∈ {off,⅛,¼,½,1})
MMA_peak_fp16(C)  = NUM_MMA_UNITS × CU? — per unit: 512 MAC/inst × 2 FLOP × inst_rate(f, pipeline II)
INT_peak(C)       = NUM_CU × SIMD_LANES × ops_per_cycle × f
ExtBW_peak(C)     = channels × bus_width × transfers/s × efficiency_model
ArithIntensity(X) = FLOP_count(X) / bytes_moved_from_DRAM(X)
```

Beat-awareness: an instruction delivers 32 lane-results in B cycles → effective per-CU lane
throughput = SIMD_LANES results/cycle regardless of B; the formulas above already encode this.

## 3. Derating Model (scaling law)

```
Perf(kernel) ≈ min( compute_bound_term , memory_bound_term ) × η_sched × η_dep
η_sched : fraction of cycles the scheduler issued any instruction
          (objective ≥85% when ≥4 wavefronts ready, no external blocking — §5)
η_dep   : dependency/divergence derate from PMC-measured stall attribution
```
PERF-001 maintains per-kernel entries: {AI, measured perf, bound classification, top stall cause}.

## 4. Roofline Method

For each benchmark kernel: compute roofline = max(FP32/FP64/MMA peak); memory roofline =
measured usable ExtBW (stream triad calibrated, not vendor number); plot achieved vs AI;
classify compute/memory/latency-bound; record which resource's counter saturates first.
Artifacts: `reports/performance/<config>/<kernel>_roofline.{csv,png}` + analysis note.

## 5. Efficiency Objectives (engineering goals from directive; not pass/fail gates)

| Objective | Threshold condition | Target |
|---|---|---|
| Compute microbench (dependency-free ALU/FMA chains, warmed up) | large N | ≥80% of configuration theoretical arithmetic peak |
| GEMM via MMA micro-tiles, appropriately tiled & staged in shared memory | compute-bound shape | ≥70% of theoretical MMA-engine peak after architecture optimization |
| Sequential streaming (triad-class) | simple pattern | ≥70% of **measured usable** board bandwidth |
| Scheduler issue utilization | ≥4 independent READY wavefronts, no external blocking | ≥85% where architecture permits |
| Active-lane utilization | branch-free full-wavefront kernels | ≥95% |

Failure to meet a target is analyzed and recorded (root-cause + follow-up), never silently
accepted nor treated as functional failure.

## 6. Measurement Method

1. Correctness gate first (GPU-PERF-REQ-005 separation).
2. Warm-up excluded; steady-state windows ≥10⁷ cycles; PMC epochs bracket measurement.
3. Counters used: issue-active cycles, beats executed, active-lane cycles, stall reasons
   (scoreboard/mem/barrier), RF-bank conflicts, SMEM conflicts, L2 slice hit/miss + hash
   distribution, fabric occupancy, DRAM transactions.
4. Every published number carries: config hash (parameters), clock (measured), tool versions,
   dataset size, and raw log path under `reports/evidence/`.
5. Cross-checks: simulator cycle model vs RTL within documented tolerance before either is
   quoted for planning.

## 7. Benchmark Suite Mapping (SPEC GPU-SW-REQ-010)

| Kernel | Primary metric | Bound expectation |
|---|---|---|
| vector add / SAXPY / DAXPY | GB/s, %stream peak | memory |
| DOT / reduction / NRM2 | GB/s + reduction efficiency | memory+sync |
| transpose | GB/s, SMEM conflict rate | memory |
| GEMV | GB/s | memory |
| GEMM (naive→tiled→MMA) | %MMA peak | compute (target kernel) |
| stencil 5-pt | GB/s, cache behavior | memory |
| FFT (radix stages) | GFLOP/s | mixed |
| histogram | atomics throughput | atomic |
| prefix sum | steps×bw | sync-heavy |
| N-body pair force | FP64/FP32 FLOP/s, SFU use | compute |
| Monte Carlo (RNG) | draws/s | SFU/int |

## 8. Performance Regression Tracking

`make perf-regression`: runs fixed kernels on golden configs, diffs against
`reports/performance/baseline.json`; ±3% noise band; regressions outside band block milestone
gates until analyzed (GPU-PERF-REQ-004). Baselines updated only with recorded justification.

## 9. Reporting Templates

Config sheet (all §27.2 parameters), theory sheet (§2 values), measurement sheet (§6 fields),
roofline artifact, verdict vs §5 objectives with analysis. One directory per configuration per
milestone.

*End of PERF-001 Rev 1.0.*
