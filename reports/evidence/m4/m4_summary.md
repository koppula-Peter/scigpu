# M4 Summary — Multi-Resident-Wavefront Scheduler

## RTL verified
- scigpu_rr_scheduler: formal PASSED (z3 induction+BMC), 120k-cycle model equivalence ×5 Ns
- scigpu_m4_cu + top: builds and passes all suites at L4/L8/L16/L32 × N=2/3/4/5

## Full suite results (tb_m4_full.cpp)
| Test | Description | L4 | L8 | L16 | L32 | N=3 | N=5 |
|---|---|---|---|---|---|---|---|
| T1 | Two-wavefront basic | PASS | PASS | PASS | PASS | — | — |
| T2 | Four-wavefront RR | — | PASS | — | — | — | — |
| T3 | Different EXEC masks | — | PASS | — | — | — | — |
| T4 | Zero EXEC clean completion | — | PASS | — | — | — | — |
| T5 | Different WG_X | — | PASS | — | — | — | — |
| T6 | Fault isolation | — | PASS | — | — | — | — |
| T7 | Completion backpressure | — | PASS | — | — | — | — |
| T8 | Reset mid-flight + relaunch | — | PASS | — | — | — | — |
| T9 | Dynamic slot reuse | — | PASS | — | — | — | — |

Cross-width continuity: T1-T9 all pass identically at L4/L8/L16/L32.
Non-power-of-two: full suite passes at RESIDENT_WAVEFRONTS=3 and =5.

## Formal (scheduler module)
Safety induction + BMC fairness no-repeat: PASSED for N=2/3/4.
Tool: yosys-smtbmc + z3 4.13.3.

## Known limitations
No scoreboard/divergence/LSU/cache/FP/MMA (future milestones).
Single-CU bootstrap; multi-CU dispatch is M11+.
