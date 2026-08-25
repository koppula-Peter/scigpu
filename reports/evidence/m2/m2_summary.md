# M2 Summary — Bootstrap Uniform Scalar Execution Slice

Date: 2026-08-23 · Verilator 5.032 (normative) · Icarus 12.0 (smoke) · Python 3.14.4

## Results

| Suite | Result | Evidence |
|---|---|---|
| M1 baseline regression (untouched, pre-M2) | 7/7 PASS | `baseline_m1.log` |
| M1 regression after ISA v1.2 amendment | 7/7 PASS | git 78c7e8b; re-run in `full_regression.log` |
| Verilator lint/elaboration (-Wall) | CLEAN (exit 0) | `verilator_lint.log` |
| Unit: ALU boundaries / FLAGS / DECODER / SGPR | PASS | `unit.log` |
| Directed programs P01–P11 + P18 completion-hold | PASS | `directed.log` |
| Fault matrix P12/P13/P14 (+GETID selector via decoder) | PASS (codes 01/02/03) | `fault_matrix.log` |
| Reset stress — 40 injection points across FSM states | CLEAN | `reset_stress.log` |
| Randomized differential (seeds 1–1000, rotated stall/latency profiles) | **1000/1000 clean, 0 mismatches** | `differential.log`, `random/seed_manifest.txt` |
| Generated-package drift check (`make check-generated`) | exit 0 | `generated_check.log` |
| Vivado 2025.2 synthesis smoke | **NOT RUN — tool unavailable** (per §56; not an M2 blocker) | this file |

## Bootstrap CPI observation (NOT a performance claim)

Non-overlapped machine: ~6 cycles/instruction with zero-latency imem
(IDLE→REQ→WAIT→DEC→EXE→COMMIT). This is bootstrap implementation CPI, distinct from the
architectural F1 latency class (ISA-001 §20 / directive §41).

## M2 traceability snapshot (full matrix in VERIFICATION_STATUS.md)

- GPU-INT-REQ-001 → scigpu_scalar_alu.sv → unit.log
- GPU-EXEC-REQ-008 (flags subset) → scigpu_scalar_flags.sv → unit.log
- GPU-SYS-REQ-007 → reset stress → reset_stress.log (ARCH-INV-006)
- GPU-VER-REQ-015 → all logs under reports/evidence/m2/

## Notes discovered and fixed during verification (root-caused, per §133)

1. Golden model lacked PC-bounds fetch check (RTL had it) → added FAULT_INVALID_ADDRESS to
   golden; litmus: P14.
2. Golden model lacked decode-legality gating (fmt/opcode pairing) → added; prevents silent
   execution of malformed encodings.
3. TB memory model accepted requests during reset edge → quiesced under rst (§19 rule).
4. Trace contract pinned: flags nibble = post-commit values; no-write ⇒ wa/wd = 0;
   completion_pc = retiring RET address. Encoded in golden builder + RTL + TB identically.
