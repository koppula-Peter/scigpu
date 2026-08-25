# ADR-009 — Staged FPGA Target Hierarchy (ZC702-class / ZCU104-class / Alveo U55C)

| Field | Value |
|---|---|
| ADR ID | ADR-009 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 GPU-FPGA-REQ-002 open board selection; OI-004 architecture uncertainty |
| Parent requirements | GPU-FPGA-REQ-001..012, GPU-SYS-REQ-003/016 |

## Context

SciGPU must reach hardware without being distorted by any single board. Availability and pricing
fluctuate; architecture must not. The project needs (1) a cheap early bring-up vehicle, (2) a
reference embedded PS/PL platform for the Vitis driver story, and (3) a high-bandwidth part for
HBM-era characterization.

## Decision

Staged target hierarchy:

| Stage | Board class | Role | Constraints on architecture |
|---|---|---|---|
| FPGA-A | ZC702-class 7-series (or any conveniently available AMD board) | Small RTL bring-up: tiny SIMD_LANES (4–8), small RF, minimal cache, basic DDR access | None — this board does NOT define the architecture |
| FPGA-B | ZCU104-class Zynq UltraScale+ (equivalents substitutable on availability) | Reference embedded-development target: PS/PL integration, AXI wrappers, Vitis 2025.2 bare-metal driver, interrupts, DMA, small/medium GPU config (~200 MHz planning clock) | None |
| FPGA-C/D | AMD Alveo U55C | Primary high-performance reference: multiple CUs, SIMD_LANES up to 32, HBM experiments, coalescing/L2-slicing/NoC studies, PCIe host, performance characterization (250 MHz baseline / 300 MHz stretch) | Informs L2 slice-to-channel mapping via configuration only |

Architecture remains portable to future Versal/HBM platforms. Vendor primitives stay in
`platform/amd/` exclusively. BOARD_SELECTION.md reduces to a procurement confirmation before
purchase — not an architecture gate.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Single-board commitment (e.g., U55C from start) | Cost/risk concentration; slow iteration; violates staged bring-up discipline. |
| Zynq-7000 as primary reference | 7-series DSP/BRAM budget caps meaningful configs; fine for FPGA-A experimentation only. |
| Versal-first | Premium cost before correctness maturity; kept as forward-portability requirement instead. |
| Non-AMD vendor board | Conflicts with mandated Vivado/Vitis 2025.2 toolchain directive. |

## Positive Consequences

- Every architectural claim gets a fitting physical testbed at acceptable cost.
- Driver/runtime software path matures on real silicon (FPGA-B) before expensive parts power up.
- Clear upgrade ladder matches milestone M19–M23.

## Negative Consequences

- Three wrapper/integration efforts over time (mitigated by scripted builds).
- U55C procurement lead-time risk (tracked OI-006).

## FPGA Consequences

Clock planning per stage (≈150 MHz 7-series / ≈200 MHz ZUS+ / 250→300 MHz U55C) with
evidence-gated claims (GPU-FPGA-REQ-012); resource strategy documented in FPGA-001.

## ASIC Consequences

None directly; hierarchy exists purely to protect architecture neutrality.

## Compiler Consequences

Capability registers expose per-build truth; binaries never change across stages (ADR-001).

## Verification Consequences

Regression continuity rule: each stage passes all prior regressions (GPU-FPGA-REQ-003);
per-stage smoke/self-test applications (GPU-SW-REQ-013).

## Future Reconsideration Trigger

If U55C becomes unobtainable at M18 time, substitute equivalent UltraScale+/HBM part after
confirming transport/topology assumptions — recorded as an amendment here, not a redesign.
