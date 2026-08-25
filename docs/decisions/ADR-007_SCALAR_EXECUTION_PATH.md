# ADR-007 — Mandatory Scalar Execution Path

| Field | Value |
|---|---|
| ADR ID | ADR-007 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 GPU-EXEC-REQ-009 (P2 "may") and TBD-000-18 |
| Parent requirements | GPU-EXEC-REQ-008/009, GPU-ISA-REQ-016, GPU-REG-REQ-002 |

## Context

Scientific kernels contain substantial wavefront-uniform computation: address bases, loop bounds,
workgroup constants, reduction accumulators' control logic. Executing uniform work on the vector
path wastes lanes and energy; executing it nowhere forces awkward predicated hacks. SPEC R0.1
listed a scalar unit as an optional P2 study; the approved directive makes it architectural.

## Decision

SciGPU **shall** include both datapaths:

1. **Vector/SIMT datapath** — per-work-item values under the wavefront active mask (VGPRs).
2. **Scalar datapath** — values proven/defined uniform across a wavefront (SGPRs): scalar ALU,
   SGPR file, scalar branch/control path.

Per CU: scalar ALU + SGPR file + scalar control alongside vector ALUs + VGPR subsystem.
Timeline: not required in the M2/M3 prototype; incorporated during approximately **M6–M7**
architecture development (SGPR file lands with RF/scoreboard at M6; scalar ALU/branches live by
M7). ISA distinguishes scalar vs vector operations by encoding class and mnemonics (`S_*` vs
`V_*`). The encoding is independent SciGPU design; no vendor ISA is copied.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| No scalar path (vector-only, replicate uniform values) | 32× wasted lane-throughput on uniform math; every kernel carries per-lane redundancy of grid/group arithmetic; divergence handling for what is really uniform control flow becomes convoluted. |
| Scalar path deferred to G3 | Branch resolution and launch-parameter handling would be bolted on late, perturbing scoreboard/scheduler after they stabilize; directive sets M6–M7 instead. |
| Dual-issue scalar+vector from day one (M4) | Adds issue-bandwidth complexity before correctness baselines exist; single-issue G1 with scalar sharing the issue slot is sufficient. |

## Positive Consequences

- Uniform control flow (loops over tiles, bounds checks) executes once, not 32×.
- Kernel ABI arguments land in SGPRs naturally; VGPR startup registers reserved for true
  per-lane identity (EXEC-001/SW-001).
- Divergence machinery only engages for genuinely data-dependent control flow.

## Negative Consequences

- Compiler must perform uniform-value analysis (or programmers must) to exploit SGPRs;
  misclassification shows up as performance loss, never as wrong results if analysis errs
  conservative→vector.
- Two register files + two scoreboarding domains add modest CU control complexity.

## FPGA Consequences

Scalar ALU/RF are tiny (128–256 × 32 b SGPRs); negligible area; big BRAM-port relief because
uniform traffic leaves the VGPR banks.

## ASIC Consequences

Standard; enables aggressive clock gating of vector pipes during scalar phases (power win).

## Compiler Consequences

ISA v1 requires explicit scalar/vector distinction (no transparent auto-promotion in v1);
assembler macros hide tedium; later compiler phases add uniform-analysis passes.

## Verification Consequences

Differential testing scalar-vs-vector equivalents; scoreboard covers both domains
(GPU-EXEC-REQ-008); directed tests mixing scalar branches with masked vector branches.

## Future Reconsideration Trigger

None anticipated — removal would break ISA v1. Extensions (e.g., wider scalar ops for FP64
control math) follow normal ISA extension process.
