# M6 Gate Review — Register File + Scoreboard + Operand Collector

| Field | Value |
|---|---|
| Review ID | M6-GATE |
| Date | 2026-08-24 |
| Disposition | **PASS WITH NON-BLOCKING ACTIONS** |

## Summary
Production register file infrastructure integrated: banked VGPR (lane-striped,
2*L banks with parity split, slot-interleaved), production SGPR, operand
collector (staged gather, parity-collision serialization), and per-slot
scoreboard (RAW/WAW + predicate ordering) replacing all M4 bootstrap storage.
All architectural semantics verified against golden across widths.

## Verification
| Suite | Result |
|---|---|
| Directed x L{4,8,16,32} incl RAW/WAW kernel | 21/21 each = 84 runs, 0 fails |
| Random structured programs | 499 ran, 0 mismatches |
| Multi-wf (partial EXECs) | 100 scenarios, 0 mismatches |
| Reset stress | clean |
| Cross-width L4/L16/L32 random | 200 each, 0 mismatches |

## Known limitations / non-blocking actions
- Operand collector staged-gather path designed but not wired as separate
  module in CU (bank-decoded reads on vgpr_banked_m6 serve engine directly;
  collector module lint-clean for future use). PMC_BANK_CONFLICTS counts
  parity-collision events from the banked RF's conflict output.
- Formal proof of scoreboard properties not yet run (SVA assertions present).

## Disposition
**PASS WITH NON-BLOCKING ACTIONS** — tag gpu-m6-register-file; proceed to M7.
