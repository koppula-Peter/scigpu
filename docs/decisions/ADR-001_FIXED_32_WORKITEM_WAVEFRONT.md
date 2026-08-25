# ADR-001 — Fixed 32-Work-Item Wavefront with Configurable Physical SIMD_LANES

| Field | Value |
|---|---|
| ADR ID | ADR-001 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-01 (`LANES_PER_WARP` configurability) |
| Parent requirements | GPU-EXEC-REQ-001/002, GPU-SYS-REQ-016, GPU-ISA-REQ-002/008 |

## Context

SciGPU must choose the logical width of its scheduled lane group and how that width relates to
physical execution resources. Early SPEC R0.1 treated lane-group size as a fully open
configuration parameter over {4,8,16,32,64}, which would have made ISA semantics
implementation-dependent: kernels compiled for one physical width would differ semantically from
another, defeating the project's core principle that architectural semantics are independent of
implementation parameters.

## Decision

1. `WAVEFRONT_SIZE = 32` is an **architectural constant** for ISA v1. Every wavefront always
   represents exactly 32 logical work-items in architectural state, scheduling state, divergence
   masks, and the ISA simulator.
2. A separate **microarchitectural** parameter `SIMD_LANES ∈ {4, 8, 16, 32}` defines the number
   of physical lanes per vector pipeline. One wavefront instruction executes in
   `BEATS = WAVEFRONT_SIZE / SIMD_LANES` consecutive execution beats (4→8 beats, 8→4, 16→2,
   32→1).
3. Partial wavefronts (fewer than 32 active work-items at grid edges) are represented exclusively
   through active masks.
4. Wave64 is excluded from ISA v1 (SPEC NG-08); any future widening requires an architectural
   extension with a new ISA capability bit.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Fully configurable logical wavefront {4..64} per build | Makes kernel binaries implementation-dependent; forks software ecosystem; complicates ABI and divergence semantics; violates architecture/implementation separation. |
| Wavefront = 16 | Halves mask/divergence bookkeeping granularity benefits; below industry-typical granularity reduces coalescing efficiency per instruction; no compensating simplicity — beat folding already provides small-footprint options. |
| Wavefront = 64 (à la GCN) | Larger register/state footprint per wavefront; worse fine-grained divergence behavior; complicates small-FPGA configs; no scientific-computing requirement demands it; excluded from v1 by directive. |
| Fixed SIMD_LANES = 32 only (no folding) | Prevents small-FPGA bring-up (FPGA-A) entirely or forces architectural truncation; loses the elegant resource scaling of beats. |
| Dynamic wavefront size at runtime | Enormous scheduler/scoreboard complexity; no verified benefit; rejected outright. |

## Positive Consequences

- One compiled SGP1 binary runs on every configuration from ZC702-class to U55C unchanged.
- Divergence stack entries, masks, PC handling, and the ISA simulator all use a single fixed
  logical shape (32-bit masks).
- Occupancy math and ABI identity registers are implementation-independent.
- Small implementations scale resources down without semantic change (R-08 mitigated by
  invariant-based testing).

## Negative Consequences

- When SIMD_LANES < 32, an instruction occupies the datapath multiple beats: peak throughput per
  CU scales with SIMD_LANES, not 32.
- Scoreboard destination-ready logic must be beat-aware (ready only after final beat commit).
- Memory coalescing operates per beat unless a µarch optimization merges across beats.

## FPGA Consequences

FPGA-A can ship SIMD_LANES=4 with minimal DSP/LUT/RF pressure; U55C targets SIMD_LANES=32.
Register file ports per beat scale with SIMD_LANES (smaller widths ease BRAM porting).

## ASIC Consequences

Identical RTL spans ASIC configurations; wide-SIMD ASICs simply set SIMD_LANES=32 for maximum
throughput with zero software impact.

## Compiler Consequences

Compiler targets exactly one logical machine: 32-wide masked vector ops. It never sees
SIMD_LANES; no per-board recompilation; loop unrolling and mask analysis assume 32 lanes.

## Verification Consequences

Every vector test must run under at least two SIMD_LANES values and be differential-checked
against the ISA simulator (which models beats identically). Invariants ARCH-INV-001/002/003
become assertions. Beat-boundary corner cases (mask edges, memory transactions crossing beats)
get directed tests.

## Future Reconsideration Trigger

If measured scientific workloads demonstrate systematic ≥25% divergence-waste or register-pressure
loss attributable to the 32-item shape AND a formal extension proposal (Wave64 capability bit)
passes architecture review, ISA v2 may introduce widening. Any change requires new ISA major
version and SGP1 feature flags.
