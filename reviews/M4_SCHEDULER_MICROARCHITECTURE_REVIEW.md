# M4 Scheduler Microarchitecture Review (pre-RTL gate, directive §180-181)

| Check | Result |
|---|---|
| Shared execution engines (no M3-core × N replication) | ✅ one scalar pipe + one vector engine, owner-tagged |
| Per-wavefront contexts complete & isolated | ✅ SCHED-001 §6/§14; per-slot bootstrap RF documented as M6-replaceable |
| One-in-flight-per-wavefront (replaces scoreboard) | ✅ SCHED-001 §18; INV-003 stays PARTIAL |
| RR definition precise (scan-from-ptr, advance-on-accept-only, mod-N wrap) | ✅ §13–15 |
| Non-power-of-two N (3/5) explicit wrap + tests | ✅ formal N=2/3/4 + unit random N∈{2,3,4,5,8} |
| Pipe-aware eligibility; busy vector candidate cannot starve scalar candidates | ✅ generic issueable mask + skip |
| Scalar/vector overlap allowed; single NEW-issue per cycle preserved | ✅ §17/directive §17-18 |
| Fetch tagged by stored owner; fetch independent of execution | ✅ separate fetch RR pointer, one outstanding |
| Completion tagging; no rr_ptr routing; same-wfid simultaneous completion impossible+asserted | ✅ §19 |
| Dynamic launch into EMPTY; release on handshake; no same-edge reuse | ✅ §21 |
| PMCs defined with exact events & wrap | ✅ §24 |
| Formal plan feasible: RR module ISA-agnostic, no RF/decoder deps | ✅ pure comb+1 register → yosys-smtbmc tractable (sby unavailable; direct SMTBMC fallback) |
| M5/M6 boundaries respected (hooks only) | ✅ WAIT_* reserved; issueable extensible |

**Verdict: PASS — scheduler RTL implementation authorized.**
