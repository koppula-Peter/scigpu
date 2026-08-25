# ADR-006 — Matrix Engine: Native 8×8×8 MMA Micro-Tile

| Field | Value |
|---|---|
| ADR ID | ADR-006 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-07 |
| Parent requirements | GPU-MAT-REQ-001..004, GPU-ISA-REQ-012 |

## Context

Scientific and ML kernels need dense matrix acceleration that coexists with SIMT execution. The
engine must map efficiently onto FPGA DSP columns (DSP48E2: 27×18 signed multiplies, cascade
chains) while remaining synthesizable generically, and must serve FP16/BF16→FP32 and INT8→INT32
accumulation patterns.

## Decision

Adopt a native physical **8×8×8 multiply-accumulate micro-tile** (`D += A×B`, 512 MACs/op):

- Primary initial operand/accumulator types:
  - **FP16 × FP16 → FP32 accumulate**
  - **BF16 × BF16 → FP32 accumulate**
  - **INT8 × INT8 → INT32 accumulate**
- Logical operations of 16×16 or larger are constructed by software/compiler scheduling over
  repeated micro-tiles; the ISA exposes only the micro-tile plus descriptor-carrying forms where
  an extension word is justified.
- FP32 matrix acceleration: later extension (NG-09). TF32: excluded from ISA v1. FP64 MMA: not
  mandatory initially — general FP64 SIMT remains mandatory.
- The engine is a CU-local unit fed through the standard scoreboard/operand path; it must not
  deadlock or starve vector issue (GPU-MAT-REQ-003).

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| 2×2 or 4×4 tiles | Control overhead dominates; MAC utilization per descriptor word poor; forces ISA churn later anyway. |
| 16×16 native tile | 4096 MACs per op: DSP/LUT wall on FPGA-B class; register/operand delivery bandwidth doubles+; software tiling already composes larger logical shapes from 8×8×8, so a bigger native tile buys little. |
| Systolic N×N array as *the* programming model | Ties ISA to one dataflow; complicates coexistence with SIMT scheduling; the micro-tile + software tiling achieves systolic-like reuse in libraries without hard-wiring it. |
| Vector-only dot products (no tile) | Insufficient peak for UC-03/UC-08; leaves DSP columns idle. |

## Positive Consequences

- 8×8×8 = 512 MACs maps cleanly to cascaded DSP48E2 groups for INT8/FP16 paths; K-dimension
  accumulation stays in-tile before FP32 spill.
- Software tiling keeps ISA stable across future physical-size changes (mirrors ADR-001
  philosophy at matrix level).
- Clean coexistence: MMA occupies a reservation-tracked long-latency slot like precise div/sqrt.

## Negative Consequences

- Small matrices (K<8, M<8) waste partial tiles unless masked/padded — library responsibility.
- Descriptor forms may consume extension words, spending encoding budget carefully.

## FPGA Consequences

INT8 mode targets near-max DSP packing; FP16/BF16 modes use DSP internal alignment; FP32
accumulate adds fabric adder trees. U55C-class parts can host 1 MMA/CU; FPGA-B may start with 0–1
per cluster.

## ASIC Consequences

Tile size becomes a die-strategy knob (wider tiles possible); ISA unchanged thanks to software
tiling layer.

## Compiler Consequences

BLAS/GEMM codegen emits micro-tile schedules with shared-memory staging; register allocation
reserves accumulator VGPR blocks; kernel ABI reports scratch needs accordingly.

## Verification Consequences

Differential vs integer/float golden models on randomized tiles incl. denormal/NaN inputs,
accumulator ordering documentation (fixed K-chunk order per micro-tile for determinism),
starvation tests concurrent with vector load (GPU-MAT-REQ-003).

## Future Reconsideration Trigger

If GEMM efficiency stalls <70% of modelled peak (GPU-PERF-REQ-006) due to tile-shape mismatch,
MICRO/ISA may add new micro-tile shapes as *additional* encodings (never redefining existing
ones).
