# MICRO-001 — SciGPU Compute Unit Microarchitecture

| Field | Value |
|---|---|
| Document ID | MICRO-001 |
| Title | Compute Unit Microarchitecture (living document) |
| Revision | 0.5 — adds Section 5 (M6 production RF, banking, operand collector, scoreboard) |
| Status | ACTIVE — §1–§3 normative · §4 normative (M5 gate PASSED) · §5 normative at M6 gate |
| Parent | SPEC-000 R0.2 · ARCH-001 · ISA-001 Rev1.4 · EXEC-001 Rev1.1 · ADR-002/004/007/011 |

## Revision History

| Rev | Date | Description |
|---|---|---|
| 0.1 | 2026-08-23 | Initial: M2 Bootstrap Uniform Scalar Execution Slice fully specified; vector/CU sections reserved. |
| 0.2 | 2026-08-23 | Added normative §2 (M3 SIMD engine, physical-lane folding); §3+ remain FUTURE. |
| 0.3 | 2026-08-23 | Added normative §3 (M4 multi-resident-wavefront scheduler, shared backends, tagged fetch/completion, PMCs); authority delegated to SCHED-001 Rev0.1. |
| 0.4 | 2026-08-23 | Added §4 (M5 divergence/reconvergence): unified typed mask stack per wavefront, LIVE_MASK, mask-control backend engine, vector-compare mode, scheduler CONTROL classification, divergence PMCs. Status header corrected: §1–§3 normative for completed milestones; §4 becomes normative at M5 gate. |
| 0.5 | 2026-08-23 | Added §5 (M6): lane-striped banked VGPR (2·SIMD_LANES banks, reg-parity split), production slot-interleaved SGPR, operand collector with bank-conflict serialization + PMC, per-wavefront scoreboard (RAW/WAW/predicate-pending) closing ARCH-INV-003 PARTIAL. Bootstrap storage retired. |

---

## 1. M2 — Bootstrap Uniform Scalar Execution Slice

### 1.1 Purpose and Scope

M2 proves, in synthesizable SystemVerilog, the minimal architectural chain:

```
fetch → decode → SGPR read → scalar execute → branch/control → architectural commit → retire/fault
```

**In scope (exactly):** one execution context; ≤1 instruction in flight; non-overlapped FSM;
ISA-001 v1.2 scalar subset (§1.6); dedicated SC_FLAGS/SCC; PC/branch semantics per §1.4;
decoupled instruction-fetch interface; launch interface; SGPR preload (bootstrap) interface;
completion interface; retire trace; defined faults; deterministic reset.

**Out of scope:** VGPRs, EXEC masks, SIMD lanes, wavefront scheduler, divergence stack,
scoreboard, operand collector, LSU/data memory, shared memory, caches, FP/SFU/MMA, atomics,
command processor, DMA, AXI, interrupts. These are M3+ milestones (ARCH-001 §9 shows the CU
block map; only the shaded bootstrap slice exists in M2).

### 1.2 Relationship to Final Scalar Architecture (ADR-007)

M2 is **not** the M7 integrated scalar unit. It deliberately omits hazard machinery because
one-in-flight execution makes RAW/WAW impossible (ARCH-001 §18 rationale). Module boundaries
(sgpr_file / alu / flags / decode) are chosen to survive into M6/M7 unchanged.

### 1.3 Execution FSM

States (`scigpu_types_pkg.sv`):

| State | Behavior |
|---|---|
| IDLE | wait start_valid&&ready → latch entry_pc/code_words/wg_x; clear flags/SCC/counters; → FETCH_REQ |
| FETCH_REQ | assert if_req_valid with current PC; on accepted → FETCH_WAIT |
| FETCH_WAIT | await if_rsp_valid&&ready; capture insn (or rsp_error→FAULT) → DECODE |
| DECODE | combinational decode registered here; illegal fmt/opcode → FAULT(ILLEGAL_OPCODE); → EXECUTE |
| EXECUTE | read SGPRs (comb), evaluate ALU/flags/target; invalid src/dst index → FAULT(INVALID_REGISTER) pre-writeback → COMMIT |
| COMMIT | single write point: sgpr_we/addr/data, PC←next_pc, flags/SCC load, retired++, trace pulse → FETCH_REQ (or COMPLETE on RET) |
| COMPLETE | completion_valid=1 (fault=0) until ready → IDLE |
| FAULT | completion_valid=1 (fault=1, code latched) until ready → IDLE |

Architectural state changes **only** in COMMIT (and launch/reset). One instruction in flight;
no bypassing; CPI is implementation-specific and NOT the F1 latency class (ISA-001 §20).

### 1.4 PC and Branch Semantics

PC = word-addressed, 64-bit. `next_pc = pc+1`; `branch_target = pc+1+sext(DISP24)`; fetch
bounds check `pc < code_words` else FAULT_INVALID_ADDRESS before any effect. completion_pc =
address of RET_KERNEL_WF (retiring-instruction convention; golden model matches).

### 1.5 Interfaces (contracts)

| Interface | Dir | Signals | Contract |
|---|---|---|---|
| Launch | in | start_valid/ready, entry_pc[63:0], code_words[63:0], wg_x[31:0] | accepted only in IDLE; init per ARCH §15 |
| Instruction fetch | out/in | if_req_valid/ready/pc[63:0]; if_rsp_valid/ready/insn[63:0]/error | 1 outstanding max; arbitrary latency; full backpressure both sides; error→fault |
| SGPR preload (bootstrap) | in | sgpr_init_valid/ready/addr[7:0]/data[31:0] | writes only honored in IDLE; ready=0 otherwise (backpressure, not fault). Verification infrastructure — replaced by dispatcher at M12+. |
| Completion | out | completion_valid/ready, fault, fault_code[5:0], pc[63:0], retired_count[63:0] | valid held until ready; stable (INV: ASSERT-005) |
| Retire trace | out | trace_valid + fields (pc, insn, sgpr_we/addr/wdata, Z/N/C/V, scc, branch_taken, next_pc, fault, fault_code) | exactly one event per committed instruction |

### 1.6 M2 ISA subset (normative for RTL)

NOP(0x850) · RET_KERNEL_WF(0x7CF) · S_MOV(0x001 reg/imm) · S_ADD(0x002) · S_SUB(0x007) ·
S_MUL(0x003, functional bootstrap multiplier — not the future pipelined design) · S_AND(0x004)
· S_OR(0x005) · S_XOR(0x008) · S_NOT(0x009) · S_SHL(0x006) · S_SHR(0x00A logical) ·
S_SAR(0x00B arithmetic, explicit signed cast) · S_CMP_EQ/LT/GT(0x010–0x012, SDST reserved-0,
writes Z/N/C/V from R=A−B plus SCC per op) · S_BRA(0x020) · S_BRA_COND(0x021, COND table
0x00–0x0E, 0x0F fault) · S_GETID(0x030, selector WG_X=0 only; others fault).
Shift amounts use operand[4:0]. All arithmetic mod 2^32, no overflow trap.

Faults: ILLEGAL_OPCODE(0x01), INVALID_REGISTER(0x02), INVALID_ADDRESS(0x03),
INTERNAL(0x0C). Fault ⇒ no writeback of faulting instruction, stop fetching, hold completion
(Arch INV-006/007/021 mapped).

### 1.7 Pipeline Contracts (M2 implementation timing)

| Class | Read | Execute | Commit | Variable? |
|---|---|---|---|---|
| MOV/ALU | SGPR | comb ALU | SGPR wr | no |
| CMP | SGPR | flag calc | SC state | no |
| BRA | flags | target calc | PC | no |
| GETID | wg_x | select | SGPR wr | no |
| NOP | – | – | none | no |
| RET | – | – | retire/completion | no |

Measured M2 state timing recorded in `reports/evidence/m2/m2_summary.md` post-implementation.
These are bootstrap CPI numbers, distinct from architectural F1 class.

### 1.8 Module Decomposition

```
rtl/generated/scigpu_isa_pkg.sv      GENERATED from models/isa/scigpu_defs.py
rtl/common/scigpu_types_pkg.sv       FSM states, shared types
rtl/frontend/scigpu_fetch.sv         if_* handshake engine (1 outstanding)
rtl/frontend/scigpu_decode.sv        comb decoder: legality + fields + class
rtl/compute/scalar/scigpu_sgpr_file.sv   2R comb + 1W commit; param SGPR_COUNT
rtl/compute/scalar/scigpu_scalar_alu.sv  add/sub/logic/shift/mul(bootstrap)/pass
rtl/compute/scalar/scigpu_scalar_flags.sv Z/N/C/V + SCC
rtl/compute/scalar/scigpu_scalar_control.sv FSM + commit + trace + completion
rtl/core/scigpu_scalar_core.sv        integration (the M2 "execution context")
rtl/top/scigpu_m2_top.sv             thin top for lint/synth smoke
```

### 1.9 Reset

Synchronous active-high `rst`. Clears FSM/PC/pending-fetch/flags/SCC/fault/completion/
counters/SGPRs (explicit clearing acceptable at M2 sizes). Post-reset: start_ready=1,
completion_valid=0, no ghost retirement (INV-006; stress-tested per directive §27/§74).

### 1.10 Future Reuse

fetch module → L1-I client (M10); sgpr_file → REG-001 scalar partition; flags/ALU fold into
scalar pipe (M7); control FSM skeleton generalizes to wavefront scheduler slot logic (M4);
trace port becomes DEBUG-001 retire trace source.

## 2. M3 — SIMD Engine and Physical-Lane Folding (normative)

### 2.1 Purpose
Prove in RTL that one binary produces bit-identical architectural state for a 32-work-item
wavefront regardless of SIMD_LANES ∈ {4,8,16,32} (ADR-001; ARCH-INV-025).

### 2.2 Scope
ONE wavefront context; ONE architectural instruction in flight; vector ops decompose into
B = 32/L execution beats with II = 1 beat/cycle after setup. Included instructions: V_MOV,
V_MOVI, V_BCAST, V_LLANE, V_ADD, V_SUB, V_MUL, V_AND, V_OR, V_XOR, V_SHL, V_SHR, V_SAR
(32-bit integer). Excluded: FP, MMA, compares, CBRANCH/mask-stack, LSU, caches (M4+).

### 2.3 State
Per context: PC, EXEC[31:0] (launch-constant in M3), SGPR file (M2), VGPR file
(VGPR_COUNT × 32 lanes × 32 b), P0..P14 predicate masks (P15 = bypass, no storage),
SC_FLAGS/SCC, retired count, fault state.

### 2.4 Effective mask (captured once per instruction)
`effective = (pred == 15) ? EXEC : EXEC & P[pred]`, latched at VECTOR_SETUP; predicate or
EXEC changes mid-instruction are impossible (single instruction in flight).

### 2.5 Beat generator
Beat k covers logical lanes [k·L, k·L+L); mask bit order: bit0=lane0 … bit31=lane31;
beat_mask = effective[k*L +: L]. Empty beats still advance the counter (§54 directive).

### 2.6 VGPR bootstrap storage
`logic [31:0] vgpr [VGPR_COUNT][32]` — correctness structure only; production lane-striped
banked RF + operand collector is M6/REG-001/ADR-002. Per-beat logical ports: 2 reads × L
lanes, 1 masked write × L lanes.

### 2.7 Vector ALU
L parallel 32-bit slices: ADD/SUB/AND/OR/XOR/SHL/SHR/SAR combinational; MUL single-cycle
registered `*` low-32 (functional bootstrap; final multiplier owned by later microarch).
SAR uses explicit $signed cast. Shift amounts B[4:0].

### 2.8 Pipeline contract
VECTOR_SETUP (validate regs vs declared reqs, latch effective mask, capture BCAST scalar)
→ per beat: ISSUE (read srcs for slice, ALU) → registered → COMMIT next cycle (masked
writeback) while issuing next beat (II=1). Retire occurs only after beat B−1 commits
(ARCH-INV-003 M3 portion). Next instruction never starts earlier (no scoreboard needed).

### 2.9 Fault atomicity
Opcode/format/VMOD/operand-index validation completes before beat 0; any failure raises
FAULT_INVALID_REGISTER / FAULT_ILLEGAL_OPCODE with zero beats committed (INV-007/021).

### 2.10 Zero-EXEC launch
start_exec_mask==0 ⇒ accept launch, fetch nothing, retire 0, completion clean.

### 2.11 Trace
Retire record gains {exec_mask, pred, effective_mask, vgpr_we, vgpr_addr}; full lane-level
state exported via dbg_vgpr dump port for differential equality checks across widths.

### 2.12 Timing examples (issue→commit pipelined, II=1 beat/cycle)
```
L=32 (B=1): SETUP ISS(0) COM(0)+RET          -> ~5 cycles/instr
L=16 (B=2): SETUP ISS(0) ISS(1)/COM(0) COM(1)+RET
L=8  (B=4): SETUP ISS0 ISS1/C0 ISS2/C1 ISS3/C2 COM3+RET
L=4  (B=8): SETUP then 8 issue slots overlapping commits, retire after last commit
```

### 2.13 Mask worked example (bit order check)
EXEC=0xF0F0_0F0F, P0=0xAAAA_AAAA ⇒ effective = 0xA0A0_0A0A.
L=8 slices: beat0=0x0A, beat1=0x0A, beat2=0xA0? — exact bytes: lanes0..7=0x0A, 8..15=0x0A,
16..23=0xA0, 24..31=0xA0. Beat k mask = effective[k*8 +: 8].

## 3. M4 — Multi-Resident-Wavefront Scheduling (normative summary)

Authority: **SCHED-001 Rev 0.1** (docs/scheduling/). Key microarchitectural decisions:

- RESIDENT_WAVEFRONTS_PER_CU slots (default 4; verified 2/3/4/5/8; WF_ID_W=max(1,clog2(N)));
  per-slot full context incl. PC/EXEC/SGPR/VGPR/P0..P14/flags/SCC/reqs/retired/faults and a
  1-entry instruction buffer; per-slot bootstrap SGPR/VGPR/predicate storage (correctness
  structure — production shared RF is M6).
- Shared backends: one scalar pipe + one vector engine (owner-wfid tagged for entire
  instruction lifetime; beat non-preemption preserved from M3).
- Tagged shared fetch: separate fetch-RR pointer, one outstanding request,
  fetch_owner_wfid routing, per-wavefront PC≥code_words fault isolation.
- Issue: generic `issueable` mask (allocated ∧ READY ∧ ibuf ∧ ¬inflight ∧ backend-ready)
  feeding an independent testable RR arbiter (rtl/scheduler/scigpu_rr_scheduler.sv):
  scan-from-pointer, grant first issueable, advance pointer only on accepted issue,
  explicit mod-N wrap (non-power-of-two safe), skip blocked candidates.
- One-in-flight per wavefront replaces the scoreboard in M4 (INV-003 PARTIAL).
- Per-wavefront completion channels (scalar/vector) with wfid tags; simultaneous
  different-context commits allowed; same-wfid simultaneous commit impossible+asserted.
- Dynamic launch into EMPTY slots; DONE/FAULTED release on completion handshake.
- Basic PMCs (64-bit mod wrap): CYCLES/RESIDENT/ISSUE/SCALAR/VECTOR/NO_ISSUE/FETCH_WAIT/
  PIPE_BUSY/LAUNCHED/COMPLETED/FAULTED/CONTEXT_SWITCHES.

## 4. M5 — Divergence and Reconvergence Microarchitecture (Rev0.4 — becomes normative at M5 gate)

Authority: ADR-011 (typed unified mask stack) · EXEC-001 Rev1.1 §4 · ISA-001 Rev1.4 §16.

### 4.1 Per-wavefront architectural additions

Every resident slot gains:

```
LIVE_MASK[31:0]        lanes not permanently returned; launch/reset ← initial EXEC
MASK_STACK             MASK_STACK_DEPTH typed frames (default 32, ≥32 arch; 2/4/8 for verification)
MASK_SP[log2(D+1):0]   valid-frame count 0..DEPTH; reset 0
current_loop_index     index of innermost active LOOP frame; INVALID = all-ones; reset INVALID
```

Invariant M5-ASSERT-001 `EXEC & ~LIVE_MASK == 0` is asserted in RTL and formally proven on the
standalone stack unit.

### 4.2 Physical frame mapping (normative for RTL)

One physical record serves all three frame types (register array, no dynamic allocation):

| Field | Width | FRAME_IF | FRAME_LOOP | FRAME_MANUAL |
|---|---|---|---|---|
| ftype | 2 | 2'b01 | 2'b10 | 2'b11 |
| parent_exec | 32 | EXEC before branch | EXEC before LOOP_BEGIN | EXEC at PUSHM |
| mask_a | 32 | pending_mask | iteration_mask (current-iteration eligibility) | 0 |
| mask_b | 32 | 0 | continue_mask | 0 |
| pc_a | PCW | pending_pc (else path) | head_pc | 0 |
| pc_b | PCW | reconv_pc | end_pc | 0 |
| future_mask | 32 | — | future_loop_mask (iteration eligibility across iterations) | — |
| phase | 2 | THEN=0 / ELSE=1 | — | — |
| prev_loop_idx | LWID | — | enclosing loop index (INVALID if none) | — |
| valid | 1 | 1 while on stack | 1 | 1 |

PCW = code address width; LWID = log2(MASK_STACK_DEPTH) bits. `future_loop_mask` is stored in
the LOOP frame and refreshed at each LOOP_END continuation.

### 4.3 Mask-control backend engine (`scigpu_mask_control_m5`)

A shared CU backend (like the vector engine) owning the complete structured-control operation,
tagged with `owner_wfid` for its whole multi-cycle lifetime. Operations:
CBRANCH_IF, RECONV, LOOP_BEGIN, LOOP_END, BREAK, CONTINUE, PUSHM, POPM, SETM, ANDM, ORM, XORM,
divergent-RET control + automatic unwind microsequence (ADR-011 D8). Correctness over speed:
frame update, lane-mask scrubbing (BREAK/CONTINUE/RET clearing bits from IF frames above the
target loop), loop-frame location, and early-return unwind may take several cycles. Other
resident wavefronts keep issuing to scalar/vector meanwhile. G1 policy preserved: at most ONE
NEW architectural instruction issued per cycle per CU; control issueability gates through
`mask_control_ready`.

### 4.4 Vector compare mode (`scigpu_vector_compare_m5`)

VCMP_EQ/NEQ/LT/LE/GT/GT/GE (0x300–0x305, FMT9) execute on the EXISTING M3/M4 vector engine as
a compare mode — no second lane machine. B=32/SIMD_LANES beats; results accumulate into a
temporary cmp_mask[31:0]; final-beat commit writes predicates only (no VGPR destination):

```
P[pdst] = (P[pdst] & ~EXEC) | (cmp_result & EXEC)      -- inactive-EXEC preservation (INV-002)
PDST=15 → fault INVALID_REGISTER before beat 0 (no partial predicate write)
LT/LE/GT/GE = signed I32 per current ordered-comparison semantics (no silent reinterpretation;
unsigned variants remain future additive work)
```

Validation (opcode/format/VSRC/PDST/VGPR bounds) completes before beat 0. Instruction owns the
vector backend until its final beat; retires after full predicate commit.

### 4.5 Scheduler integration

RR arbiter unchanged. Issueability extends to a CONTROL class alongside SCALAR/VECTOR/FAULT:

```
issueable[s] = READY ∧ ibuf_valid ∧ ¬inflight ∧ selected_backend_ready
control instructions: selected_backend_ready ≡ mask_control_ready (engine free + no unwind busy)
```

The dangling `sched_issue_pipe` output of the M4 top is now driven with the granted class.
Faulting control instructions retire through the normal FAULT class with exact fault codes
(0x05 overflow / 0x06 underflow / 0x0D mismatch / 0x0E illegal control flow), atomic.

### 4.6 Divergence PMCs (debug counters; final perf-counter architecture NOT claimed)

PMC_PREDICATE_WRITES · PMC_DIVERGENT_BRANCHES (T≠0∧F≠0) · PMC_UNIFORM_BRANCHES ·
PMC_RECONV_EVENTS · PMC_MASK_PUSHES · PMC_MASK_POPS · PMC_MASK_STACK_MAX_DEPTH ·
PMC_BREAK_EVENTS · PMC_CONTINUE_EVENTS · PMC_EARLY_RETURN_LANES. Optional diagnostics:
active-lane fraction per vector instruction; branch_lane_efficiency =
max(popcount(T),popcount(F))/popcount(parent EXEC).

### 4.7 Trace contract

Mask-control trace fields: mask_event_valid/wfid, old_exec/new_exec, old_live/new_live,
stack_sp_before/after, frame_type, push/pop flags, pending_mask, target_pc, fault/fault_code.
Vector-compare trace adds pred_we/pred_addr/pred_write_mask/pred_new_value + owner_wfid.

## 5. M6 — Production Register File, Banking, Operand Collector, Scoreboard

### 5.1 Banked VGPR (`scigpu_vgpr_banked_m6`)
Single physical instance shared by all resident slots (slot-interleaved
addressing `{slot, reg, lane}`). Lane-striped: SIM D_LANES lane-columns map to
SIMD_LANES banks; register parity doubles the bank count so two source
registers occupy disjoint bank sets whenever their parities differ:
`banks = 2*SIMD_LANES`, bank(set s, column j) = {s, j}. One read port per bank
per cycle; masked L-lane write distributes one write across distinct banks
(no structural write hazard).

### 5.2 Bank conflicts + operand collector
A vector operand fetch requests column set p(vs0) and p(vs1). When
p(vs0)==p(vs1) the two reads collide -> collector performs a TWO-CYCLE gather
(second set read one cycle later) and pulses PMC_BANK_CONFLICTS. Otherwise the
gather completes in one cycle. Collector output registers feed the vector
engine/compare setup directly (bootstrap bypass retired).

### 5.3 Production SGPR (`scigpu_sgpr_prod_m6`)
Slot-interleaved flat file, 2-read/1-write, replacing the bootstrap file;
scalar pipe keeps its single-cycle commit contract.

### 5.4 Scoreboard (`scigpu_scoreboard_m6`)
Per-resident-slot pending-destination tracking:
  * VGPR: valid + 8-bit register (one outstanding vector write per slot —
    G1 one-in-flight), released at vector/compare last-commit;
  * PRED: valid + 4-bit register (VCMP), released at compare commit;
Issue-time source checks: vector src0/src1 vs VGPR-pending, control
condition (LOOP_END/CBRANCH family cond nibble) vs PRED-pending ->
src_wait stalls issue (not a fault), closing RAW; WAW covered because a
matching destination also holds until release. ARCH-INV-003 becomes PASS at
M6 gate.

### 5.5 PMCs
PMC_BANK_CONFLICTS joins the counter set. All M4/M5 counters continue.
