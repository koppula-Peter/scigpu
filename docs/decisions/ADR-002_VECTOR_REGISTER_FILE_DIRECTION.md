# ADR-002 — Lane-Striped Banked Vector Register File Direction

| Field | Value |
|---|---|
| ADR ID | ADR-002 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-04 (RF implementation open) |
| Parent requirements | GPU-REG-REQ-001..005, GPU-EXEC-REQ-008 |

## Context

The vector register file is the most resource-critical CU block. Each resident wavefront needs
`VGPR_COUNT × 32 lanes × 32-bit` of architectural state, and each vector operation logically
requires two source reads + one destination write per execution beat. FPGAs offer BRAM/URAM with
two ports per primitive and LUTRAM with limited read ports; a naive multiported design is
infeasible. The architecture must fix the *organization direction* now so REG-001 can later fix
exact geometry from measured evidence.

## Decision

Adopt a **lane-striped, banked** vector register architecture:

- Lane `i`'s element of VGPR `v` is stored in the bank/word location selected by
  `(v, i)` striping — lane data is distributed across banks so that one beat's
  `SIMD_LANES` accesses naturally spread across banks.
- Register addressing (`VDst/SRCn` fields) is **independent of physical SIMD width**: the same
  ISA register index maps to different physical beat slices depending on SIMD_LANES.
- Logical port contract: 2R + 1W per vector op per beat (scalar ops use the separate SGPR file).
- Port feasibility achieved by configuration-appropriate combination of: BRAM/URAM banking,
  replication for read ports, operand-collector arbitration, multi-beat time multiplexing,
  (optionally LUTRAM for small configs).
- Small FPGA configurations may trade latency (extra operand-collection cycles) for resources;
  LARGE/HPC configurations maximize sustained issue rate.
- Mandatory hooks: RF parity (SECDED optional HPC), register-bank conflict counters.

Exact bank count, geometry, and replication factor are **non-blocking tuning studies** owned by
REG-001 (SPEC §15.3), resolved with conflict counters + synthesis area at M6.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| FF-based RF | Register count explodes (e.g., 16 wavefronts × 128 VGPR × 32 lanes × 32 b ≈ 2 Mbit/CU minimum); FPGA FF density makes this non-viable beyond toy configs. |
| Fully replicated multi-port RAM (per-read-port copies) | Write fan-out and area scale linearly with ports; acceptable only as a *component* inside banking for small configs, not as the whole strategy. |
| Single monolithic dual-port BRAM time-multiplexed over everything | Serializes operand supply; destroys issue rate in medium/large configs; conflicts with latency-hiding goal. |
| Value-predicating / renaming to hide conflicts | Violates G1 no-renaming decision (ADR-004); complexity unjustified. |
| URAM-only | URAM depth-oriented (4K×72); shallow wide RFs waste it; keep URAM as an option for LARGE/HPC stripe capacity, not baseline. |

## Positive Consequences

- Beat folding (ADR-001) synergizes: smaller SIMD_LANES → fewer concurrent bank accesses per
  beat → easier timing/closure on small parts.
- Uniform addressing model keeps ISA simulator and RTL aligned trivially.
- Conflict counters give quantitative evidence for REG-001 without redesign risk.

## Negative Consequences

- Bank conflicts can stall issue; must be measured and minimized by compiler scheduling.
- Operand collector adds a pipeline stage of latency in some configurations.

## FPGA Consequences

Baseline mapping is BRAM (SDP/TDP primitives) with optional replication; URAM reserved for
high-capacity profiles; LUTRAM permitted for MINIMAL. All inference-friendly (no vendor
primitives in core).

## ASIC Consequences

Same organization maps directly to SRAM macros with more physical ports; striping survives
unchanged; no re-architecture needed for ASIC.

## Compiler Consequences

Compiler should minimize same-cycle distinct-register pressure across banks once geometry is
known; ABI reserves that register *indices* remain stable regardless of geometry.

## Verification Consequences

tb_register_file + tb_operand_collector check: stripe correctness under all SIMD_LANES values;
conflict serialization semantics; parity hook fault injection; invariant ARCH-INV-003 (destination
ready only after final beat commit).

## Future Reconsideration Trigger

If M6 synthesis shows sustained-issue shortfall >20% vs PERF-001 model attributable to bank
structure, REG-001 may alter geometry/banking within the lane-striped paradigm; abandoning
striping itself would require a new ADR.
