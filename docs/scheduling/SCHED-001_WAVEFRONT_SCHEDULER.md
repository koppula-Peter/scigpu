# SCHED-001 — Wavefront Scheduler

| Field | Value |
|---|---|
| Document ID | SCHED-001 |
| Title | Multi-Resident-Wavefront Scheduler (CU scope) |
| Revision | 0.1 |
| Status | IMPLEMENTED — M4 BASELINE |
| Parent | SPEC-000 R0.2 · ARCH-001 §15 · EXEC-001 · MICRO-001 Rev0.3 §3 |

## 1. Purpose
Define the deterministic, fair, round-robin scheduler that allows one Compute Unit to hold
multiple resident wavefront contexts and issue their instructions to shared scalar/vector
backends, replacing the single-context M3 control flow while preserving all architectural
semantics.

## 2. Scope (M4)
RESIDENT_WAVEFRONTS_PER_CU slots (default 4; verified 2/3/4/5/8; architecture to 64),
per-slot full context, per-slot 1-entry instruction buffer, tagged shared fetch, RR issue
arbiter, tagged scalar pipe + vector engine adapters, per-wavefront completion, basic PMCs,
reset/fault isolation. Single CU. Single issue of a NEW instruction per cycle.

## 3. Non-scope
Scoreboard (M6), memory/LSU stalls as real events (M8), barriers (M9), divergence/mask stack
(M5), dispatcher (M12), caches (M10), multi-CU (M11).

## 4. Relationship to ARCH-001
Implements ARCH-001 §15 scheduler box with states EMPTY/READY/ISSUED/DONE/FAULTED and
reserved WAIT_* encodings. Eligibility feeds a generic `issueable` concept so M6/M8/M9 can
extend it without changing the arbiter (directive §198).

## 5. Slot model
Slot i ∈ [0,N). `allocated` = slot holds a context. N may be non-power-of-two.

## 6. Per-wavefront state
valid · sched_state · PC[63:0] · code_words[63:0] · EXEC[31:0] · SGPR view · VGPR view ·
P0..P14 · SC_FLAGS/SCC · wg_x · declared vgpr/sgpr reqs · retired_count[63:0] · fault
state/code/pc · ibuf{valid,pc,insn,err} · inflight · fetch_pending.

## 7. Slot lifecycle
EMPTY →(launch)→ READY →(accepted issue)→ ISSUED →(completion)→ READY | DONE | FAULTED;
DONE/FAULTED →(completion handshake)→ EMPTY. See state diagram in §99-of-directive /
docs diagram below. WAIT_* reserved.

```
EMPTY --launch--> READY --issue--> ISSUED --complete--> READY
                                    |                        ^
                                    |--fault--> FAULTED      |
                                    |--RET---> DONE          |
                          (handshake) v                        |
                          EMPTY <------------------------------+
```

## 8. State semantics
READY: resident, awaiting issue eligibility. ISSUED: one instruction in flight (per-wavefront,
replaces scoreboard for M4 — directive §16/§91). DONE: executed RET; completion pending.
FAULTED: faulted; completion pending; never issues. EMPTY: no context.

## 9. Instruction buffer
1 entry/slot {valid, pc, insn, err}. Filled only by the response carrying that slot's stored
fetch ownership. Consumed at accepted issue (§167 directive: no speculative refetch).

## 10. Fetch arbitration
Separate RR pointer (`fetch_rr_ptr`) over slots needing fetch:
active ∧ ¬done ∧ ¬faulted ∧ ¬inflight ∧ ¬ibuf_valid ∧ ¬fetch_pending.
One outstanding fetch globally (pre-L1-I). Request carries internal `fetch_owner_wfid`;
response routes by stored owner, never by current scheduler pointer. PC ≥ code_words ⇒
per-wavefront FAULT_INVALID_ADDRESS without an external request. Fetch runs concurrently
with execution.

## 11. Issue eligibility (generic)
issueable[i] = allocated ∧ READY ∧ ibuf_valid ∧ ¬inflight ∧ backend_ready(class(i)) ∧
¬stall. Backend ready: scalar pipe idle-accepting; vector engine setup_ready. Invalid
instructions are their own "class" (immediate-fault candidate) and remain issueable (§40).

## 12. Predecode/resource classification
Lightweight combinational class per buffered word: SCALAR / VECTOR / FAULT-CANDIDATE
(reuses decoder legality logic; bootstrap area tradeoff documented).

## 13–15. RR algorithm / pointer / non-power-of-two
rr_ptr names first-examined slot. Scan rr_ptr, rr_ptr+1 … wrapping through N−1 → 0. Grant
first issueable. On ACCEPTED issue: rr_ptr ← (selected+1) mod N (explicit wrap, no binary
overflow reliance). No grant accepted ⇒ pointer unchanged. Blocked candidates are skipped
without losing future fairness.

## 16–17. Backend gating & overlap
Vector-busy blocks only vector candidates (engine reserved B beats — beat non-preemption
per M3 contract); scalar candidates from other slots stay issueable. Scalar pipe accepts
one instruction; completions tagged wfid.

## 18. One-in-flight rule
READY→ISSUED on acceptance; ISSUED→READY only at that instruction's commit. Same-wavefront
hazards therefore impossible without a scoreboard (M6).

## 19. Completion handling
Scalar completion {wfid,next_pc,we/wa/wd,flags,scc,fault…}; vector final-commit completion
{wfid,pc+1}. Both update only context[wfid]. Simultaneous same-cycle scalar+vector
completions from different wavefronts commit together; same-wfid simultaneous completion is
structurally impossible (one-in-flight) and asserted.

## 20. Fault behavior
Faulting wavefront → FAULTED (stop fetch/issue), expose completion, others unaffected.
CU-bootstrap containment; kernel-wide aggregation later.

## 21. Dynamic launch/release
wf_launch_{valid,ready,slot,…}: accepted only when target EMPTY (ready=0 otherwise).
DONE/FAULTED release on completion handshake; relaunch legal on a later cycle (no
same-edge reuse).

## 22. Fairness
Continuously-issueable candidate receives service within ≤ N accepted issues (bounded
fairness); formalized via age counter in formal smoke + randomized model comparison.

## 23. Determinism
Identical inputs/state ⇒ identical accepted-issue sequence. No random arbitration.

## 24. PMCs (64-bit mod-2^64 wrap; independent event counters unless noted)
PMC_CYCLES · PMC_RESIDENT_CYCLES (≥1 resident) · PMC_ISSUE_CYCLES (accepted issue) ·
PMC_SCALAR_ISSUES · PMC_VECTOR_ISSUES · PMC_NO_ISSUE_CYCLES (≥1 resident, none issued) ·
PMC_FETCH_WAIT_CYCLES (resident & some slot needs-fetch) · PMC_PIPE_BUSY_CYCLES (resident &
buffered candidate exists but backend busy) · PMC_WAVEFRONTS_LAUNCHED/COMPLETED/FAULTED ·
PMC_CONTEXT_SWITCHES (accepted issue with wfid ≠ previous accepted wfid; excludes first).
Stall attribution precedence for the two stall counters: FETCH before PIPE_BUSY; both may
coexist with NO_ISSUE (independent-event model, documented here).

## 25. Debug/trace
Issue trace {valid,wfid,pc,insn,pipe,rr_before,rr_after}; masks (resident/ready/issueable/
inflight/done/faulted), counts, per-retire wfid on both scalar/vector retire channels.

## 26. Reset
Clears all slots to EMPTY, pointers to 0, buffers/pipeline valids, PMCs. No ghost events
(directive §132-133 tests).

## 27. Parameterization
RESIDENT_WAVEFRONTS_PER_CU (2..64, default 4), WF_ID_W = max(1,$clog2(N)),
PMC_WIDTH (default 64; unit-test 8 for wrap), SIMD_LANES inherited.

## 28. Formal properties
one-hot0 grant · grant⊆issueable · ptr stability when unaccepted · ptr advance on accept
(incl. N=3 wrap) · reset behavior · bounded fairness via age counter. Harness:
verification/formal/m4_scheduler (yosys-smtbmc + z3/boolector; sby unavailable).

## 29–30. Verification
Directed D01–D30 (directive list); scheduler unit random ≥100k cycles vs
models/scheduler/rr_scheduler_model.py for N∈{2,3,4,5,8}; integrated random ≥1000
multi-wavefront scenarios × widths with dual-oracle checks (ISA golden = semantics;
RR model = selection).

## 31–33. Future integration
M6 adds scoreboard term to issueable; M8/M9 add WAIT_MEMORY/WAIT_BARRIER entry conditions.
Scheduler module unchanged.

## 34. Traceability
See VERIFICATION_STATUS.md M4 addendum (GPU-EXEC-REQ-005/006/007, GPU-SYS-REQ-007/013,
GPU-DBG-REQ-003 PARTIAL, VER-REQ set, ARCH-INV-011 primary).
