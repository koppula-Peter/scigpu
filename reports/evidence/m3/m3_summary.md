# M3 Summary — SIMD Engine & Physical-Lane Folding

Configurations verified: SIMD_LANES = 4, 8, 16, 32 (Verilator 5.032; one binary per width,
built once). WAVEFRONT_SIZE=32 architectural constant everywhere.

## Vector instruction subset (M3)
V_MOV V_MOVI V_BCAST V_LLANE V_ADD V_SUB V_MUL V_AND V_OR V_XOR V_SHL V_SHR V_SAR
(+ M2 scalar subset in unified stream). Predication [pN] with P15 bypass on every vector op.

## Results
- Lint -Wall: exit 0 at all four widths (verilator_lint_l*.log)
- Unit: vector ALU 81,164 checks 0 fails; mask/beat slice property PASS (unit_vector.log)
- Directed: 14 programs x 4 widths + single-lane sweep lanes0..31 x widths + completion-hold:
  ALL PASS (directed.log)
- Width equivalence: identical binary (sha256 pinned) -> retire traces and FULL final state
  (SGPR/PRED/EXEC/VGPR lane-level) identical across widths AND vs golden
  (width_equivalence.log, width_binary_sha256.txt)
- Randomized differential: 1000 shared-seed programs x 4 widths = 4000 RTL executions,
  0 mismatches (random_differential.log, random/seed_manifest.txt)
- Reset stress: 40 injection points x 4 widths, vector pipeline included: clean
  (reset_stress.log)
- Fault matrix: invalid declared register / invalid VMOD / invalid PC / illegal opcode:
  controlled codes, zero partial writes (fault_matrix.log)
- Full regression M1+M2+M3: GREEN (full_regression.log)

## Characterization (bootstrap only; NOT product performance)
Cycles per vector instruction ~= setup + B beats + drain (B=32/L): L32 ~4, L16 ~5,
L8 ~7, L4 ~11 cycles for simple ops. Logical active fraction = popcount(eff)/32 is
width-independent by construction.

## Invariant status
INV-001 PASS · INV-002 PASS (register/state portion) · INV-003 PARTIAL (completion aspect;
scoreboard-ready at M6) · INV-006 PASS · INV-007 PASS · INV-021 PASS · INV-025 **PASS
(primary M3 proof)** · INV-016 FUTURE (M8 LSU).

## Known limitations
No scheduler/multiple wavefronts/divergence RTL/vector compares/predicate-producing ops/
production RF banking/operand collector/scoreboard/LSU/shared memory/caches/FP/MMA/atomics/
command processor/DMA/AXI/driver. Vivado smoke NOT RUN (OI-009, tool unavailable).
