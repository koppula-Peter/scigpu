# ADR-004 — Per-Wavefront Register-Granularity Scoreboard

| Field | Value |
|---|---|
| ADR ID | ADR-004 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-06 |
| Parent requirements | GPU-EXEC-REQ-005/006/008, GPU-REG-REQ-003 |

## Context

SIMT issue requires precise dependency tracking so that latency hiding (many resident wavefronts)
never produces incorrect operand consumption. Options ranged from coarse per-instruction
scoreboards to full renaming/ROB machinery.

## Decision

Adopt a **per-wavefront, register-granularity scoreboard** with these normative semantics:

- Tracks at minimum: pending VGPR writes, pending SGPR writes, long-latency execution results,
  outstanding loads, outstanding stores where required, atomic transactions, execution-unit
  availability, barrier dependencies.
- **RAW**: issue blocked until source registers are ready.
- **WAW**: shall not permit architecturally incorrect completion ordering (destination may not be
  marked ready by an older instruction after a newer writer has claimed it; ordering enforced by
  claim-at-issue + ready-at-completion discipline).
- **WAR**: prevented structurally through the defined operand-capture model — source operands are
  read/captured before the writing instruction can complete past capture points; combined with
  in-order issue per wavefront this removes WAR as a hazard class needing runtime tracking in G1.
- **No register renaming in generation 1.**
- Destination-ready rule interacts with beat folding: a vector destination becomes ready only
  when its final execution beat commits (ARCH-INV-003).

Detailed structures, bit layouts, and stall-signal timing belong to SCHED-001 / REG-001 /
MICRO-001. ARCH-001 fixes the interactions above.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Instruction-granularity scoreboard (whole-wavefront busy bit) | Trivially correct but destroys throughput: one long op freezes all subsequent independent ops of the wavefront; contradicts latency-hiding goal. |
| Full OoO with renaming + ROB | 10× control complexity, huge state per CU, unnecessary for SIMT throughput model; G1 explicitly excludes renaming. |
| Compiler-only scheduling with hardware hazard-ignored mode | Insufficient for memory latencies that are runtime-variable; unsafe under divergence; kept as compiler *assistance*, never sole mechanism. |
| Per-lane (per-register-per-beat) tracking | Precision beyond need; register-granularity is sufficient because a register's beats complete contiguously. |

## Positive Consequences

- Deterministic, formally tractable hazard logic (small FSMs per wavefront) — good formal targets.
- Pairs cleanly with deterministic round-robin scheduling (GPU-EXEC-REQ-006).
- Register indices are stable; ABI unaffected.

## Negative Consequences

- WAW to the same VGPR serializes within a wavefront (acceptable: rare in well-formed kernels;
  compiler avoids).
- Scoreboard bits scale with VGPR_COUNT × resident_wavefronts (e.g., 128 × 16 = 2 Kbit/CU) —
  modest.

## FPGA Consequences

LUTRAM/FF implementation is small and flat; no CAM-heavy structures; timing-friendly.

## ASIC Consequences

Same structure ports directly; could later add renaming as G3+ study without ISA change.

## Compiler Consequences

Compiler can rely on RAW/WAW stalling exactly as modeled in its scheduler description; software
pipelining across wavefronts (interleaving) is the primary ILP tool, which matches the hardware.

## Verification Consequences

Scoreboard invariants become assertions/formal properties (SPEC GPU-VER-REQ-005): no issue with
pending source; single ready transition per write claim; no lost wakeups; no duplicate ready.
Directed tests for WAW chains, long-latency + load interleavings, beat-folded destinations.

## Future Reconsideration Trigger

If M12+ scheduler-utilization counters show ≥15% issue loss from WAW/false dependencies in real
kernels, a renaming study (G3+) may open — requires new ADR; ISA unchanged either way.
