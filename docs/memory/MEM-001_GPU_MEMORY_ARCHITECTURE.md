# MEM-001 — SciGPU Memory Architecture and Consistency Model

| Field | Value |
|---|---|
| Document ID | MEM-001 |
| Title | Memory Architecture, Transport Protocol, and Consistency Model |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2; ARCH-001 §§16–21; ADR-003, ADR-008 |
| Normative for | CACHE-001, NOC-001, MICRO-001, CMD-001, DRV-001 |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete memory baseline |

---

## Table of Contents

1. Address Spaces and Windows
2. Internal Transport Protocol (normative)
3. Outstanding-Request Tracking
4. Coalescing Rules
5. Shared / Local Memory Programming Semantics
6. Cache Policies (G1 baseline)
7. Consistency Model (normative)
8. Atomics Semantics
9. DMA Visibility
10. G5 Virtual-Memory Accommodation
11. Deadlock and Fairness Statements
12. Verification Obligations

---

## 1. Address Spaces and Windows

All addresses are 64-bit (`GPU_ADDR_W=64`). Through G4 the device uses **physical device
addresses or host-provided IOVA** directly — no on-device translation, no page faults (SPEC
GPU-CACHE-REQ-006).

| Space | ISA form | Backing | Bounds enforcement |
|---|---|---|---|
| Global | base SGPR + offset; scope attributes apply | device DDR/HBM windows + host-mapped buffers | per-allocation window table checked in LSU path → FAULT_INVALID_ADDRESS |
| Shared (workgroup) | LOCAL opcode split; wg-private window | CU scratchpad banks | dispatcher-granted window; overflow = launch fault |
| Local/private | LOCAL space, per-work-item region allocated by ABI convention within wg window or global backing | SMEM or global (performance choice only; semantics identical) | same as shared/global |
| Constant/read-only | P2 | cached read-only path | read-only fault on write |

Window table: populated at kernel launch from allocation descriptors; entries {base, limit,
perms}; lookup by top-bit compare (few entries); misses fault.

## 2. Internal Transport Protocol (normative — ADR-008 instantiation)

### 2.1 Request channel

| Signal | Dir | Width | Notes |
|---|---|---|---|
| req_valid | SRC→DST | 1 | |
| req_ready | DST→SRC | 1 | may combinational-depend only on DST state |
| op | SRC→DST | 3 | RD, WR, ATOMIC, PREFETCH, CTRL(flush/invalidate) |
| addr | SRC→DST | 64 | byte address of first access |
| size | SRC→DST | 3 | 0=1B 1=2B 2=4B 3=8B 4=32B(beat) 5=64B(line) 6/7 rsv |
| tid | SRC→DST | TID_WIDTH† (default 12) | unique among outstanding of this source |
| burst_len | SRC→DST | 4 | beats in transaction − 1 |
| wdata | SRC→DST | GPU_MEM_DATA_W† (256 default) | valid when op=WR/ATOMIC-write side |
| be | SRC→DST | GPU_MEM_DATA_W/8 | byte enables; INV-017 constrains provenance |
| scope | SRC→DST | 2 | wf/wg/dev/rsv |
| order | SRC→DST | 2 | relaxed/acq/rel/acq_rel |
| hint | SRC→DST | 2 | default/streaming/no-allocate/rsv |
| atomic_op | SRC→DST | 5 | §8 encoding |
| source_id | SRC→DST | 10 | {kind(CU/DMA/CP/debug), cu#, stream#} |

### 2.2 Response channel

| Signal | Dir | Width |
|---|---|---|
| rsp_valid | DST→SRC | 1 |
| rsp_ready | SRC→DST | 1 |
| tid | DST→SRC | TID_WIDTH† |
| rdata | DST→SRC | GPU_MEM_DATA_W† |
| status | DST→SRC | 6 {OK, DECODE, WINDOW, ALIGN, ECC_CE, ECC_UE, POISON, RETRY_LATER, UNSUP_ATOMIC, TIMEOUT, INTERNAL, RSV} |
| last | DST→SRC | 1 (burst completion marker) |

### 2.3 Channel rules

R1. Requests/responses use valid/ready handshake: transfer exactly when both high (C-08).
R2. A source may not reuse a TID until its final response (last=1) is accepted.
R3. Responses return in **request order per TID**; different TIDs from one source may complete
   out of order unless ORDER/scope constraints say otherwise (§7).
R4. Request channel never blocks on response channel state at the *same* link (deadlock rule
   ARCH §32.3.1); intermediaries buffer responses independently.
R5. Flow control per link class: CU↔L1/L2 local links = ready stall acceptable;
   fabric links = credit-based (credits ≥ max_inflight of that client class).
R6. status ≠ OK responses carry no usable data obligation (INV-018 allows zero-fill) and must be
   delivered exactly once for the TID.
R7. POISON propagates: a poisoned line/transaction answers downstream with status=POISON and
   never silently corrects (RAS hook).

## 3. Outstanding-Request Tracking

Per LSU: MSHR-class table with `MAX_OUTSTANDING_MEM_REQ`† entries holding {TID, dest VGPR map
(instruction tag), beat/lane route map, type, remaining bursts}. One *scoreboard* pending-load
per destination register; multiple transactions may serve it. Allocation happens before issue;
exhaustion stalls the wavefront at LSU (never mid-fabric). Atomics hold an entry until response.
Stores: fire-and-forget with write-completion tracked only where ORDER requires (release needs
acknowledgment before fence completion — implemented via store-ack counter).

## 4. Coalescing Rules

Input: beat-k active-lane addresses (≤ L ≤ 32), each SIZE-sized.

1. Group lanes whose byte ranges fall inside one aligned 64-B line AND union-range ≤ line:
   merge into one transaction (be = union of lane bytes).
2. Same-line but non-contiguous beyond merge policy v1 (union > half line): separate
   transactions per contiguous run (policy knob documented; INV-017 bounds coverage to requested
   bytes either way).
3. Cross-line lanes never merge (ADR-003 boundary rule).
4. Unaligned base with policy=fault → FAULT_ALIGNMENT pre-merge.
5. Loads: route map records (line-offset ← lane) pairs; response scatter writes each lane's
   register bytes from its requested range only (zero-fill elsewhere is invisible because lanes
   read only their element width).
6. Atomics/gathers/scatters do not coalesce (one transaction per lane).

## 5. Shared / Local Memory Programming Semantics

- Visibility: workgroup-private; contents undefined at workgroup start (software must initialize
  before cross-lane reads; barrier does not clear).
- Bank behavior observable only as performance: conflicts serialize; identical-address broadcast.
- Scope 'wg' fences/barriers cover SMEM traffic identically to global (same axioms §7).
- Local/private aliasing into SMEM follows the same banking; private per-lane regions are
  layout-owned by ABI (SW-001).

## 6. Cache Policies (G1 baseline)

| Level | Policy baseline |
|---|---|
| L1-D | 64-B lines (ADR-003); set-assoc ≤4-way capable; **write-through, no-write-allocate**; pseudo-LRU default; coherent-by-flush model: kernel/workgroup boundaries + explicit CACHE_CTRL flush/invalidate; hit-under-miss permitted, miss-under-miss limited by MSHR |
| L1-I | read-only, prefetch-permitted (hint-driven), invalidated by CACHE_CTRL after image load |
| L2 | 64-B lines; write-back vs DRAM; XOR-hash slice interleave (ARCH §19; bit map = CACHE-001 study); point of coherence & atomics; SECDED per profile |

Explicit controls (CACHE_CTRL command): FLUSH.L1D, INVALIDATE.L1I, FLUSH.L1D+WAIT (device-scope),
INVALIDATE.L2.LINE (debug/RAS). DMA coherence via §9 rules instead of snooping (G1 explicitly
synchronized architecture — SPEC GPU-CACHE-REQ-004).

## 7. Consistency Model (normative)

### 7.1 Primitives

Operations carry (op, address, size, scope σ ∈ {wf, wg, dev}, order ω ∈ {rlx, acq, rel, acq_rel}).
Fences F(σ, pattern ∈ {acq, rel, full}). Barrier B_wg = execution join + release(acq)-pair effect
at wg scope over all member accesses.

### 7.2 Axioms

A1 (Program order / same-location coherence). Each work-item's own accesses to a single byte
range appear in program order to every observer at every scope (per-location total order exists;
INV-009).

A2 (Relaxed freedom). Plain (ω=rlx) accesses to *different* locations may be observed in any
order across work-items absent synchronization.

A3 (Release/Acquire). A release-store (or release side of RMW, or rel-fence) at scope σ
synchronizes-with an acquire-load (or acquire side, or acq-fence) at scope ⊇ matching domain on
the same location-or-fence-chain: writes before the release become visible to reads after the
acquire that observes them (causality chains compose transitively; no out-of-thin-air).

A4 (Fences). F_rel(σ) orders all prior plain accesses of the thread against subsequent
release-visible effects at σ; F_acq(σ) symmetrically for later loads; F_full both ways.

A5 (Barrier). B_wg makes every member's prior accesses visible to every member's subsequent
accesses at wg scope (implementation: release on arrival + acquire on departure).

A6 (Atomicity). RMWs are single-copy atomic at their scope: all observers agree on the order of
RMWs to a location; plain accesses interleave per A1 (INV-010).

A7 (Progress). Properly synchronized (A3–A5) data-race-free programs observe no values outside
happens-before consistency.

### 7.3 Litmus set (verification seed)

LB (load buffering), SB (store buffering), MP (message passing) + acquire/release fixes,
fence-WRC, barrier-visibility, RMW-vs-plain interleavings, IRIW under device scope. Expected
results enumerated in VER-001 test matrix; simulator executes sequentially-consistent golden
where model says allowed outcomes are checked statistically under RTL stress.

## 8. Atomics Semantics

Encoding per ISA-001 §14. Ordering: rlx default; acq/rel/acq_rel legal. Scope wg or dev.
Serialization point: L2 slice owning the line (single total RMW order per location). Return-old/
new per HINT. Failure modes: UNSUP_ATOMIC (reserved FP encodings), WINDOW/ECC statuses as loads.
CAS: weak CAS (may spuriously fail under conflict retry is software's concern — documented);
no loop built in.

## 9. DMA Visibility

DMA engines issue through the identical transport with source_id kind=DMA:

- H2D writes then doorbell/completion: device consumers observe DMA writes only after
  (a) DMA completion record, AND (b) consumer's acquire at dev scope (or fresh kernel launch —
  launch acts as dev-scope acquire of all prior completed DMA per queue ordering, INV-014).
- D2H reads similarly ordered before completion record.
- CPU-side visibility handled by platform driver (cache maintenance/IOMMU attributes) — outside
  core scope, specified in DRV-001.

## 10. G5 Virtual-Memory Accommodation

Reserved now, required later: transport `status` code PAGE_FAULT; source_id carries context field
space (upper bits reserved); window-table structure replaceable by TLB walk unit without format
change; SGP1 feature flag VM_REQUIRED; ISA unchanged (addresses already 64-bit). No other
architectural commitment made (SPEC GPU-CACHE-REQ-006).

## 11. Deadlock and Fairness Statements

Restatement of ARCH §32.3 obligations with owners: transport independence R4 (MEM-001),
MSHR pre-allocation (§3), barrier resource-free waiting (EXEC-001 §5), ring monotonicity
(CMD-001), NoC VC separation (NOC-001), DMA RR fairness (CMD-001). Every arbiter documents its
fairness bound; starvation tests mandatory (VER-001).

## 12. Verification Obligations

1. Transport assertion library: R1–R7 encoded as SVA; formal on R2/R4/R6 properties.
2. Litmus suite §7.3 executed on simulator + RTL cosim stress.
3. Coalescer directed matrix (SPEC GPU-LSU-REQ-004 patterns) incl. INV-016/017 checks.
4. Exhaustion tests: MSHR full, TID exhaustion (parameter sweep TID_WIDTH), ring-full handling.
5. Poison injection end-to-end visibility (status propagation, no silent correction).
6. DMA visibility litmus with interleaved compute traffic.

*End of MEM-001 Rev 1.0.*
