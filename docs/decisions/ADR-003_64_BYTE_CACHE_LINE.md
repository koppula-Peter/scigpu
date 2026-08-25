# ADR-003 — 64-Byte Cache Line

| Field | Value |
|---|---|
| ADR ID | ADR-003 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-05 |
| Parent requirements | GPU-CACHE-REQ-001/003, GPU-MEM-REQ-002 |

## Context

L1/L2 line size determines transaction efficiency against the 256-bit default memory transport,
coalescer behavior, BRAM tagging cost, and false-sharing sensitivity for scientific access
patterns (streaming, stencils, tiled GEMM).

## Decision

**64-byte cache lines** are the L1 and L2 baseline. Any future change requires a measured
architectural study with overwhelming evidence and remains an ISA-neutral implementation
parameter (never visible to kernels).

## Alternatives Considered

| Alternative | Why rejected (as baseline) |
|---|---|
| 32 B | Doubles tag/metadata overhead per byte; halves worst-case burst efficiency on the 256-bit transport (2 beats/line vs 1); modern GPUs converged on ≥64 B for good reason. Remains possible later as a MINIMAL-profile tuning knob if evidence demands. |
| 128 B | Better DRAM burst usage in theory, but doubles over-fetch penalty on scattered/gathered scientific patterns and inflates L1 area per CU; not justified pre-measurement. |
| Variable line size per level | Complexity across coalescer/MSHR/L2 slicing for unproven benefit; rejected. |

## Positive Consequences

- One 64-B line = exactly one full beat pair at GPU_MEM_DATA_W=256 (4×64-bit lanes… precisely:
  256 b = 32 B/beat → 2 beats per line fill), matching transport granularity cleanly.
- Aligns coalescing targets: contiguous wavefront loads of 32×float = 128 B = 2 lines.
- Tag overhead ratio is industry-proven territory.

## Negative Consequences

- Sparse scalar access patterns over-fetch up to 63 B; mitigated by sector/partial-line validity
  as a CACHE-001 study (non-blocking).

## FPGA Consequences

64 B fits BRAM row organization naturally (e.g., 512-bit data + tags); U55C HBM efficiency is
line-size friendly.

## ASIC Consequences

Standard SRAM macro geometries; nothing exotic.

## Compiler Consequences

None directly; tiling guidance in libraries assumes 128-B alignment for best behavior.

## Verification Consequences

Directed tests: boundary-crossing accesses at ±1 B around line edges, partial masks at line
boundaries, stride patterns hitting same set.

## Future Reconsideration Trigger

If M10+ cache traces show >15% wasted bandwidth from over-fetch on representative HPC kernels,
CACHE-001 may propose sectoring (sub-line validity) — preferred over changing line size.
