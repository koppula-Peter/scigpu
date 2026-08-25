# ADR-005 — FP64 Execution Ratio per Configuration Profile

| Field | Value |
|---|---|
| ADR ID | ADR-005 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-02 |
| Parent requirements | GPU-FP-REQ-001..013, GPU-PERF-REQ-001/006 |

## Context

SciGPU is a scientific GPU: FP64 credibility is a product requirement, not an afterthought.
Commercial gaming-derived GPUs ship FP64 at 1:32 or worse; HPC-class accelerators use 1:2 or
1:1. On FPGAs, FP64 costs significant LUT/FF (no native FP64 DSP), so the ratio must be a
build-time parameter balanced against profile intent.

## Decision

FP64 remains a first-class architectural requirement. The ISA defines full FP64 regardless of
physical population; profiles set throughput ratios:

| Profile | FP64:FP32 throughput target | Notes |
|---|---|---|
| GPU_MINIMAL | omitted, or ≈1:8 | First physical prototypes may omit FP64 entirely; ISA support stays defined; capability register reports absence honestly |
| GPU_MEDIUM | **1:4** | Embedded/scientific development sweet spot on ZCU104-class |
| GPU_LARGE | **1:2** | Multi-CU parts with real HBM bandwidth |
| GPU_HPC | **1:2 default; 1:1 optional build** | U55C-class/ASIC; 1:1 for pure HPC builds |

True-fused FP64 FMA is eventually mandatory wherever FP64 exists. IEEE-compliance claims remain
gated by verification evidence (NG-01).

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Fixed 1:8 everywhere | Undercuts the scientific mission; DAXPY/GEMM/N-body UC-07 would be memory-bound *and* compute-starved simultaneously. |
| Fixed 1:1 everywhere | Wastes silicon/DSP-LUT budget in ML-leaning and embedded profiles where FP16/BF16 MMA matters more; unaffordable on FPGA-B class. |
| FP64 via software emulation only (no HW) | 10–50× slowdown; unacceptable for a scientific GPU brand promise; rejected except as the legal MINIMAL omission case (reported honestly via capability bits). |
| Packed-2×FP64-on-256b trickery as "1:1" | Misleading accounting; rejected — ratios are defined on true FP64 FMA lanes. |

## Positive Consequences

- Clear marketing/architecture ladder aligned to board classes; single RTL source covers all
  ratios by parameterization.
- Roofline analysis (PERF-001) gets honest peak numbers per build.

## Negative Consequences

- FP64 pipelines are area-hungry on FPGA; LARGE/HPC builds must budget BRAM/DSP/LUT carefully
  (R-01 risk retained).
- Two pipeline families (FP32-class and FP64-class) complicate operand-collector arbitration
  slightly.

## FPGA Consequences

FP64 add ≈ LUT-dominated multi-stage pipeline; FP64 FMA substantially larger than FP32 FMA;
planning targets (150/200/250 MHz) assume staged pipelines, not combinational monsters
(GPU-FP-REQ-001). U55C DSP48E2 abundance assists FP32 paths so shared infrastructure can lean on
DSPs while FP64 uses fabric.

## ASIC Consequences

Ratio becomes a die-strategy knob; 1:1 viable; nothing in ISA changes.

## Compiler Consequences

`cvt` + FP64 ops compile identically everywhere; capability registers let runtime libraries pick
FP64 vs emulated paths on MINIMAL builds.

## Verification Consequences

FP64 needs its own exhaustive/randomized strategy (GPU-VER-REQ-012); SoftFloat double-precision
oracle campaigns; beat-folded FP64 under SIMD_LANES folding included.

## Future Reconsideration Trigger

If FPGA-D measurements show FP64 demand exceeding supply at 1:2 (queue-depth counters, issue
stall attribution), a 1:1 HPC build is already sanctioned — no ADR change needed. Dropping below
1:2 for LARGE would require revisiting this ADR.
