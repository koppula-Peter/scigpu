# ISA-001 — SciGPU Instruction Set Architecture

| Field | Value |
|---|---|
| Document ID | ISA-001 |
| Title | SciGPU GPU Instruction Set Architecture (ISA v1.0) |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2; ARCH-001 §§10–14, 20–21, 26 |
| ADRs | ADR-001 (wavefront), ADR-006 (MMA), ADR-007 (scalar/vector), ADR-008 (transport attributes) |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.4 | 2026-08-23 | Principal GPU Architect | M5 divergence refinement (additive; ISA major version stays 1; no existing opcode moves): mask-stack family OPCs allocated — 0x7C0 PUSHM, 0x7C3 POPM, 0x7C4 SETM, 0x7C5 ANDM, 0x7C6 ORM, 0x7C7 XORM, 0x7C8 LOOP_BEGIN, 0x7C9 LOOP_END, 0x7CA BREAK, 0x7CB CONTINUE, 0x7CC–0x7CE reserved; CBRANCH_IF (0x7C1) fixed to explicit dual-target form `CBRANCH_IF pN, ELSE_LABEL, RECONV_LABEL` with DISP24=ELSE displacement and BMOD/PAYLOAD[15:0]=RECONV displacement (both relative to PC+1); control-operand convention COND 0..14=P0..P14 / COND 15=current EXEC for divergence-control instructions only; new fault codes FAULT_RECONVERGENCE_MISMATCH=0x0D, FAULT_ILLEGAL_CONTROL_FLOW=0x0E (no existing code moved); V_CMP_* PDST=15 faults INVALID_REGISTER (P15 unwritable); §16 rewritten normative per ADR-011/EXEC-001 Rev1.1. |
| 1.3 | 2026-08-23 | Principal GPU Architect | Vector predication correction (M3, OI-010): P15 = unpredicated/bypass selector — effective_mask = EXEC (was ambiguous PRED=0 default); assembler defaults PRED=15 for unpredicated vector instructions; explicit input predication syntax `V_OP [pN], ...` (PRED=0..14); VMOD legality enforced (unsupported TYPESEL/NEGABS combinations fault INVALID_OPCODE before any architectural effect); predicate writeback preserves inactive-EXEC lane bits: P[d] = (P[d] & ~EXEC) | (res & EXEC) — INV-002. Implemented and verified at M3; row back-filled at M5 opening per directive §10. No encoding values changed. |
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete ISA v1.0 baseline |
| 1.2 | 2026-08-23 | Principal GPU Architect | Scalar condition amendment (M2): dedicated SC_FLAGS {Z,N,C,V} + SCC architectural state replaces the temporary SGPR63 convention (SGPR63 is now an ordinary SGPR); FMT=5 COND[7:0] table defined for S_BRA_COND (ALWAYS..GE_U; 0x0F reserved→fault); opcode allocations 0x007 S_SUB, 0x008 S_XOR, 0x009 S_NOT, 0x00A S_SHR, 0x00B S_SAR (0x00C/0x00D ROL/ROR reserved); S_CMP_* SDST reserved (assembler encodes 0, decoder tolerates-and-ignores legacy 63); S_GETID selector WG_X=0 only, unsupported selectors fault; completion_pc = retiring RET address; retire-trace field contract fixed. See new §23. |
| 1.1 | 2026-08-23 | Principal GPU Architect | Additive amendment (per §22 policy item 1): FMT=9 **PCMP** allocated (was reserved) — predicate-compare format `[47:44]PDST [43:36]VSRC0 [35:28]VSRC1`, opcodes 0x300–33F as already tabled. Required by M1 assembler/simulator; purely additive, no existing encoding changed. Also records M1 implemented subset: memory granularity .W; ATOM.ADD.U32 return-old device-scope; scalar flag link = SGPR63 convention for S_CMP/S_BRA_COND in the golden model until dedicated flags land in MICRO-001. |

---

## Table of Contents

1. Conventions
2. Data Types
3. Register Model
4. Execution State and Masks
5. Instruction Encoding (64-bit fixed)
6. Opcode Map
7. Scalar Instructions
8. Vector Integer Instructions
9. Compare / Predicate / Select
10. Floating-Point Instructions
11. Conversion Instructions
12. SFU Instructions (precise / approximate)
13. Memory Instructions
14. Atomics
15. Synchronization: Barriers and Fences
16. Control Flow and Divergence
17. Matrix (MMA) and Dot Products
18. Collectives (reserved)
19. System / Debug Instructions
20. Latency Classes and Pipeline Contracts
21. Exceptions and Faults per Instruction Class
22. Extension Policy
Appendix A — SGP1 Kernel Container (normative)
Appendix B — Assembler Syntax Overview

---

## 1. Conventions

- Bit 0 = least significant. Memory byte order **little-endian**; instruction words are 64-bit
  little-endian in SGP1 code sections.
- `V*` = vector (per-lane) operand in VGPR space; `S*` = scalar operand in SGPR space;
  `P*` = predicate register.
- Notation: `Rd ← Ra op Rb`. "mask" = current effective EXEC mask (EXEC-001 §3).
- All register indices are unsigned; out-of-range indices raise INVALID_REGISTER before any
  architectural effect (ARCH-INV-021).
- "architectural effect" excludes microarchitectural side effects; inactive lanes produce none.

## 2. Data Types

| Mnemonic | Type | Width | Notes |
|---|---|---|---|
| U8/I8, U16/I16 | integers | 8/16 b | storage/convert + packed ops (P2 study); ALU v1 operates at 32/64 b after explicit CVT |
| U32/I32 | integers | 32 b | primary G1 width |
| U64/I64 | integers | 64 b | from G2 (§12.3 SPEC) |
| F16 / BF16 | float | 16 b | IEEE half / brain-float; storage+CVT G2, arithmetic/MMA G3 |
| F32 | float | 32 b | IEEE single; primary FP |
| F64 | float | 64 b | IEEE double; capability-reported presence |

FP semantics reference: IEEE 754-2019 as instantiated in FP-001 (rounding RN default; sNaN→qNaN;
subnormal modes per FTZ control). Compliance claims gated by verification (NG-01).

## 3. Register Model

Per resident wavefront:

| File | Count | Width | Access |
|---|---|---|---|
| VGPR v0..VGPR_COUNT-1 | ≤256 | 32 lanes × 32 b | vector instructions (lane-striped physical organization invisible to ISA) |
| SGPR s0..SGPR_COUNT-1 | ≤256 | 32 b | scalar instructions; also read as broadcast sources by some V-forms via VSR flag |
| PREG p0..p15 | 16 | 32-bit lane masks | written by compares; consumed by branches/masking |
| PC | 1 | implementation | word-addressed instruction pointer |
| LIVE_MASK | 1 | 32-bit lane mask | lanes not permanently returned (EXEC ⊆ LIVE_MASK; ISA-001 Rev1.4) |
| Mask/control stack | depth ≥32 (cfg) | typed frames IF/LOOP/MANUAL (ADR-011) + MASK_SP + current_loop_index | managed by 0x7C0–0x7CF family |

Pairing convention for 64-bit values: even VGPR/SGPR holds the low word (`v4:v5`), little-endian
order; unaligned pairing is an assembler error.

System-read-only SGPR aliases (mapped at fixed indices above sgpr_req by hardware, readable via
`S_GETID`): device id, CU id, wavefront id, workgroup ids (uniform), dispatch seq id.

## 4. Execution State and Masks

- `EXEC` = 32-bit active mask, top of the wavefront's mask state.
- Predicate combination: effective_mask = EXEC ∧ P[p] when instruction's pred field ≠ 15
  (P15 encodes "no predicate").
- Divergence-capable branches manipulate a stack of {EXEC, resume_PC} frames (EXEC-001 normative
  algorithms): overflow → FAULT_MASK_STACK_OVERFLOW; underflow → FAULT_MASK_STACK_UNDERFLOW
  (ARCH-INV-008).
- Partial wavefronts at grid edges start with EXEC = valid-work-item mask.

## 5. Instruction Encoding (ADR-fixed)

Base word: **64 bits, little-endian**. Rare forms append exactly one 64-bit extension word
(max 128 b total). No compressed encodings in v1.

### 5.1 Common header

| Bits | Field | Notes |
|---|---|---|
| 63:52 | OPC (12 b) | 4096 primary opcodes |
| 51:48 | FMT (4 b) | format selector |

### 5.2 Formats

**FMT=0 VRR — vector 3-source**
```
47:40 VDST | 39:32 VSRC0 | 31:24 VSRC1 | 23:16 VSRC2 | 15:0 VMOD
VMOD: [15:12] PRED(p index; 15=none) | [11:10] TYPESEL(width/type variant) |
      [9:8]  ROUND(f32/f64 ops) | [7] SAT | [6] ABS0 | [5] NEG0 | [4] NEG1 | [3:0] FLAGS
```

**FMT=1 VRI — vector immediate**
```
47:40 VDST | 39:32 VSRC0 | 31:16 SIMM16 (sign-extended unless TYPESEL says Z) | 15:0 VMOD (as above)
```

**FMT=2 SRR — scalar 2-src (+opt 3rd via ext)**
```
47:40 SDST | 39:32 SSRC0 | 31:24 SSRC1 | 23:0 SMOD/reserved
SMOD: [22:20] PRED-scalar-condition select | rest reserved (must be 0)
```

**FMT=3 SRI — scalar immediate**
```
47:40 SDST | 39:32 SSRC0 | 31:8 SIMM24 | 7:0 SMOD
```

**FMT=4 MEM — memory (load/store/atomic)**
```
47:40 VDATA  (data VGPR base; pair for 64 b)
39:32 SADDR  (base address SGPR; uniform)
31:12 SOFF20 (signed element offset)
11:10 SCOPE  (0=wf 1=wg 2=dev 3=rsv)
9:8   ORDER  (0=relaxed 1=acquire 2=release 3=acq_rel/rsv per op class)
7:4   SIZE   (0=1B 1=2B 2=4B 3=8B 4..rsv; vector vs scalar = opcode split)
3:0   HINT   (cache hint: 0=default 1=streaming 2=no-allocate 3..rsv)
```

**FMT=5 BR — branch/control**
```
47:24 DISP24s (signed WORD offset from PC+1)
23:16 COND    (condition select: p-index | SC flags | always)
15:0  BMOD    (mask-stack operation encoding for divergence family)
```

**FMT=6 SYS** — payload `[47:0]` per opcode (system/debug/perf).

**FMT=7 XEXT** — declares that this opcode consumes one extension word:
```
next word: EXT_PAYLOAD[63:0], meaning defined by OPC (immediates, MMA descriptors, call targets…)
```

**FMT=8 MMA**
```
47:40 DDST  (accumulator tile VGPR base)
39:32 ASRC  (A tile base)
31:24 BSRC  (B tile base)
23:16 CSRC  (C tile base; may == DDST)
15:8  SDESC (SGPR descriptor pointer: strides/K-chunk count)
7:0  MMAMOD ([7:6] type: 0=F16→F32acc 1=BF16→F32acc 2=I8→I32acc 3=rsv; [5:0] stage flags rsv=0)
```
Tile layout: row-major 8×8 elements; each element occupies consecutive VGPR lanes per row
(layout table §17). Descriptor SGPR block: {stride_a, stride_b, stride_c/d, k_chunks}.

### 5.3 Rationale (recorded per directive)

Simple fixed decode; 8-bit register indices cover 256-entry files with room for ABI startup
registers; three vector sources support FMA/MMA-style operands natively; predicate + rounding +
modifiers fit without extension words; 12-bit opcode space leaves >60% reserved for extensions;
compiler-friendly regularity (all ALU forms share VMOD positions).

## 6. Opcode Map (v1 assignment)

| Range (OPC hex) | Class | Notes |
|---|---|---|
| 000–0FF | Scalar core | S_* ALU, branches, S_GETID |
| 100–1FF | Vector integer 32 | add/sub/min/max/abs/neg/logic/shifts |
| 200–23F | Vector integer wide | mul/mulhi/bitfield/popcnt/clz/ctz/rot |
| 240–27F | Vector 64-bit integer | G2 |
| 300–33F | Compare/predicate/select | all types |
| 340–37F | Moves/broadcast/shuffle-placeholders | incl. V_MOV variants |
| 400–45F | FP32 | add/sub/mul/fma/fms/div-class entry/sqrt-class/cmp/class |
| 460–49F | FP16/BF16 pack & convert | cvt/pack/unpack/dot-prep |
| 4A0–4BF | FP16/BF16 arithmetic (G3) | incl. dot |
| 500–55F | FP64 | mirror of FP32 set (capability-gated) |
| 600–63F | Memory loads/stores | scalar+vector, sizes, scopes |
| 680–69F | Atomics | RMW set |
| 6A0–6AF | Barriers/Fences | wg barrier, wf/device fences |
| 700–71F | SFU precise | div/sqrt/rcp/rsqrt bracket forms |
| 720–74F | SFU approximate | ex2/lg2/sin/cos/tan/atan/atan2/pow/rcp/rsqrt.approx |
| 780–79F | MMA | 8×8×8 tiles per MMAMOD type |
| 7A0–7AF | Dot products | sub-tile forms |
| 7C0–7CF | Mask-stack / structured control (§16) | PUSHM, CBRANCH_IF, RECONV, POPM, SETM, ANDM, ORM, XORM, LOOP_BEGIN, LOOP_END, BREAK, CONTINUE, reserved×3, RET_KERNEL_WF |
| 800–83F | **RESERVED collectives** | shuffle/broadcast/ballot/vote/prefix (never allocate elsewhere) |
| 840–85F | System/debug | nop/break/trap/rdclock/sevfault/dbg |
| F00–FFF | Vendor/extension window | future capability bits gate decode |

Unlisted opcodes within assigned ranges are RESERVED → executing raises ILLEGAL_OPCODE.

## 7. Scalar Instructions (SGPR, FMT=2/3; OPC 000–0FF)

| Mnemonic | Semantics | Class |
|---|---|---|
| S_ADD/S_SUB/S_ADDC/S_SUBB | I32 add/sub with carry chain (pairs for 64) | F1 |
| S_MUL_I32 | 32×32→32 | F1 |
| S_MULHI_U64/I64 | high word of 64-bit product | F1 |
| S_AND/OR/XOR/NOT/ANDNOR | bitwise | F1 |
| S_SHL/SHR/SAR/ROL/ROR | shifts by SSRC1 or SIMM5 | F1 |
| S_CMP_* | writes SC flags {Z,N,C,V} | F1 |
| S_BRA/BRA_COND/CALL/RET | PC control; CALL pushes return PC to scalar link stack (depth 8) | F1 |
| S_GETID SDST, sel | system-read alias read (device/cu/wf/wg/seq) | F1 |
| S_MOV, S_MOVI32 | move / 24 b imm sign-extended | F1 |
| S_CVT_F32_I32 etc. | scalar conversions (uniform math) | F1 |

Scalar branches never touch the mask stack (ADR-007 rule 1).

## 8. Vector Integer Instructions (VGPR, FMT=0/1; OPC 100–27F)

All operate per active lane under effective mask.

| Group | Instructions |
|---|---|
| Arithmetic | V_ADD.U32/I32, V_ADDC, V_SUB, V_SUBB, V_NEG, V_ABS, V_MIN/MAX U/I |
| Multiply | V_MUL.U32/I32, V_MULHI.U64/I64 (240-range for full 64 forms in G2) |
| Division | V_DIVMOD.U32/I32 → {quotient VGPR pair via two-dest form or bracket class §12} — v1: bracketed precise path (V-class), no direct II=1 divide |
| Logic | V_AND/OR/XOR/NOR/NOT/ANDNOR |
| Shifts | V_SHL/SHR/SAR (SSRC0 data, VSRC1/VRI amount mod 32/64), V_ROL/ROR |
| Bit ops | V_POPCNT, V_CLZ, V_CTZ, V_BFI (bit field insert), V_BFE (extract), V_SBREV |
| 64-bit (G2) | mirror set on even:odd pairs: V_ADD.U64 … V_MULHI.U64, V_DIVMOD.U64 (bracketed) |
| Moves | V_MOV (reg-reg), V_MOVI, V_BCAST (S→all lanes), V_SEL (3-src select by P/pred bit) |

Signedness explicit in mnemonic; mixed-width requires CVT (GPU-INT-REQ-004/006).

## 9. Compare / Predicate / Select (OPC 300–33F)

```
V_CMP_*.TYPE vd? none — writes P[PDST] = lane-mask(result)
```
Forms: EQ/NE/LT/LE/GT/GE × U32/I32/U64/I64/F32/F16/BF16/F64; unordered variants F classes
(FLT_O etc.). `P_PASSTHRU`, `P_NOT`, `P_AND/OR/XOR` predicate logic ops.
`V_CNDMASK` selects src0/src1 per predicate bit. Comparisons produce no traps for FP; flags per
FP-001 (quiet semantics).

## 10. Floating-Point Instructions

### 10.1 FP32 (OPC 400–45F) — FMT=0/1, VMOD rounding/abs/neg fields live

| Instruction | Semantics | Class | Notes |
|---|---|---|---|
| V_ADD.F32 | Ra+Rb | F1 | RN default; VMOD ROUND ∈ {RN,RZ,RUp,RDn} (RU/RD P1 builds) |
| V_SUB.F32, V_MUL.F32 | | F1 | |
| V_FMA.F32, V_FMS.F32 | ±a*b+c single-rounding | F1 | true fused (GPU-FP-REQ-002) |
| V_MAX/MIN.F32 | signed-zero & NaN rules per FP-001 | F1 | propagates canonical qNaN |
| V_CLASS.F32 | writes class code (per FP-001 table) | F1 | |
| V_RCP/V_RSQRT.F32 | precise-class entry (see §12) | V | |
| V_SQRT.F32, V_DIV.F32 | precise iterative | V | bounded iterations documented in FP-001 |

### 10.2 FP16/BF16 (OPC 460–4BF)

Pack/unpack (2×F16 ↔ 32 b lane), CVT F16↔F32, BF16↔F32 (truncate/round-to-nearest variants),
arithmetic G3: V_ADD/MUL/FMA.F16 (pairs-in-lane semantics documented), V_DOT2.F16.F32
(a·b pairwise dot with FP32 accumulate). BF16 mirrors. NaN/subnormal behavior per FP-001
(FTZ mode bit honored where defined).

### 10.3 FP64 (OPC 500–55F; capability-gated)

Mirror of the FP32 core: ADD/SUB/MUL/FMA/FMS/MIN/MAX/CLASS + precise DIV/SQRT/RCP/RSQRT (§12).
True-fused FMA mandatory when present. Rounding via VMOD as FP32. Absent capability →
ILLEGAL_OPCODE at decode (capability bits prevent binaries from shipping such paths — assembler/
runtime check).

## 11. Conversion Instructions (OPC 460–49F shared block)

`V_CVT.SRC.DST` matrix over {I8,U8,I16,U16,I32,U32,I64,U64,F16,BF16,F32,F64} with:
rounding field (int→float uses RN; float→int honors RZ default, RN/RUp/RDn optional and
out-of-range → defined saturation/clamp per FP-001 table); F16/BF16↔F32 exactness documented.
Packed conversions (two lanes per word) marked `.PACKED`.

## 12. SFU Instructions

**Precise class (OPC 700–71F)** — correctly-rounded targets, V-class latency, bracket protocol:

```
V_DIV_START.F32 vd, va, vb      // begin iterative refine; reservation held
V_DIV_END.F32   vd               // commit quotient; releases reservation
```
(SQRT/RCP/RSQRT analogous; FP64 mirrors.) Bracket misuse (missing END before dependent read)
is impossible architecturally because scoreboard keeps destination pending until END commits;
omitted END raises INTERNAL fault at kernel end watchdog sweep.

**Approximate class (OPC 720–74F)** — F1/F2 class, published ULP *targets* validated by FP-001
oracle campaigns before compliance claims: RCP.APPX, RSQRT.APPX, EX2, LG2, SIN, COS, TAN, ATAN,
ATAN2, POW (ATAN2/POW consume extension word for domain metadata). Documented input domains;
outside-domain results defined (NaN/saturation table, FP-001).

## 13. Memory Instructions (OPC 600–63F; FMT=4)

Vector forms iterate beats; only active lanes contribute (INV-016).

| Family | Forms |
|---|---|
| Load vector | V_LOAD.TYPE vdata, saddr+soff (SIZE ∈ B/H/W/D) |
| Store vector | V_STORE.TYPE vdata, saddr+soff |
| Load/store scalar | S_LOAD/S_STORE (SDATA instead of VDATA; single-element) |
| Local/private | opcode split LOCAL: same encoding, address space = workgroup private window (MEM-001 §spaces) |
| Gather/scatter (G3) | V_GATHER/V_SCATTER: per-lane independent addresses from VGPR base |

Attributes ride SCOPE/ORDER/HINT (§5.2): ORDER meaningful on loads (acquire), stores (release),
and fences; relaxed is default. Alignment policy: naturally-aligned required at v1; misaligned →
FAULT_ALIGNMENT (policy knob per build may downgrade to defined byte-lane emulation later —
MEM-001 owns final policy text).

Address model: effective_addr = SGPR[SADDR] (64 b) + signext(SOFF20) × size (+ lane-scaled offset
for vector contiguous addressing: element stride = size; strided/gathered patterns use
GATHER/scatter forms or explicit address arithmetic).

## 14. Atomics (OPC 680–69F)

`ATOM.OP.TYPE vdata_out{optional}, saddr+soff` — OP ∈ {ADD,SUB,XCHG,MIN,MAX,AND,OR,XOR,CAS},
TYPE ∈ {U32,U64}. CAS consumes a second source register (compare value) via VSRC1 field mapping.
SCOPE ∈ {wg, dev}; ORDER ∈ {relaxed, acq, rel, acq_rel} (acq_rel legal on RMWs). Serialized at L2
point of coherence (ARCH §19); single-copy atomicity (INV-010). Return-old vs return-new via
HINT[0] (0=old, default). FP atomic add: reserved encodings (P2, GPU-ATM-REQ-002).

## 15. Barriers and Fences (OPC 6A0–6AF)

| Instruction | Semantics |
|---|---|
| BAR.WG | workgroup barrier: all resident wavefronts of the workgroup arrive; join point; implies wg-scope release→acquire visibility (ARCH §21). Duplicate arrival within one generation → FAULT_ILLEGAL_BARRIER (INV-012). |
| FENCE.WG / FENCE.DEV | order prior plain accesses at scope before subsequent ones (MEM-001 axioms). No execution join. |
| FENCE.ACQ/REL variants | folded via ORDER field on fence opcode. |

Barriers are S-class (stall-on-resource) instructions: they occupy no transport resources while
waiting (deadlock rule ARCH §32.3.3).

## 16. Control Flow and Divergence (OPC branch range + 7C0–7CF) — Rev1.4

Uniform control flow: `S_BRA`, `S_CALL`, `S_RET` (scalar; unchanged).

Divergence-capable structured family — all FMT=5, per ADR-011 typed unified mask stack,
EXEC-001 Rev1.1 algorithms. Hardware never computes post-dominators: both branch targets are
compiler-provided displacements relative to PC+1.

### 16.1 Opcode allocation (fixed at Rev1.4)

| OPC | Mnemonic | Operands (assembler) |
|---|---|---|
| 0x7C0 | PUSHM | none |
| 0x7C1 | CBRANCH_IF | `pN, ELSE_LABEL, RECONV_LABEL` |
| 0x7C2 | RECONV | none |
| 0x7C3 | POPM | none |
| 0x7C4 | SETM | `pN` |
| 0x7C5 | ANDM | `pN` |
| 0x7C6 | ORM | `pN` |
| 0x7C7 | XORM | `pN` |
| 0x7C8 | LOOP_BEGIN | `LOOP_END_LABEL` |
| 0x7C9 | LOOP_END | `pN, LOOP_HEAD_LABEL` |
| 0x7CA | BREAK | `[pN]` optional |
| 0x7CB | CONTINUE | `[pN]` optional |
| 0x7CC–0x7CE | reserved | — |
| 0x7CF | RET_KERNEL_WF | none |

CBRANCH_ELSE_RESUME is retired as a separate opcode concept: RECONV (0x7C2) with the
frame-carried reconv_pc supersedes it.

### 16.2 FMT=5 field usage for the divergence family

```
COND[3:0]   = insn[23:20] : control-condition selector
DISP24      = insn[47:24] : signed displacement #1
BMOD/PAYLOAD[15:0] = insn[15:0] : signed displacement #2 / op payload
```

**Control-operand convention** (divergence-control instructions ONLY; distinct from §23
S_BRA_COND flag table): `COND 0..14 = predicate P0..P14`; `COND 15 = unconditional — current
EXEC`. CBRANCH_IF additionally rejects COND=15 (branch on "current EXEC" is meaningless →
FAULT_ILLEGAL_CONTROL_FLOW); SETM/ANDM/ORM/XORM reject COND=15 (ambiguous vs LIVE/EXEC → fault;
see §16.3).

Per instruction:

| Instruction | Field semantics |
|---|---|
| CBRANCH_IF pN, ELSE, RECONV | COND=N; else_pc = PC+1+sext24(DISP24); reconv_pc = PC+1+sext16(BMOD). Atomic validation: N≠15, both PCs within [0, code_words), MASK_SP < DEPTH. Always pushes FRAME_IF{parent_exec=EXEC, pending=F=EXEC&~P[N], pending_pc=else_pc, reconv_pc, phase=THEN}. Then T=EXEC&P[N]: EXEC←T, PC←PC+1; if T==0∧F≠0: phase←ELSE, EXEC←F, PC←else_pc. |
| RECONV | Requires MASK_SP>0 ∧ top frame FRAME_IF ∧ PC==frame.reconv_pc; faults otherwise (UNDERFLOW / ILLEGAL_CONTROL_FLOW / RECONVERGENCE_MISMATCH). First arrival with pending_mask∧LIVE≠0: EXEC←pending∧LIVE, PC←pending_pc, pending←0, phase←ELSE (frame stays). Otherwise EXEC←parent_exec∧LIVE_MASK (∧ nearest-loop iteration eligibility), pop, PC←reconv_pc+1. |
| LOOP_BEGIN END_LBL | DISP24 = end label −(PC+1). Pushes FRAME_LOOP{parent_exec=EXEC, iteration/future=EXEC, continue=0, head_pc=PC+1, end_pc=PC+1+sext24(DISP24), prev_loop_idx}; current_loop_index ← new frame; EXEC unchanged. Overflow atomic. |
| LOOP_END pN, HEAD_LBL | COND=N (control convention; 15 = unconditional: all eligible candidates iterate); DISP24 = head −(PC+1). Validates top-of-loop context: current_loop_index valid ∧ PC==stored end_pc ∧ stored head_pc == PC+1+sext24(DISP24); else FAULT_RECONVERGENCE_MISMATCH / FAULT_ILLEGAL_CONTROL_FLOW. candidate=(EXEC∨continue_mask)∧future_loop_mask∧LIVE_MASK; next=candidate∧cond_mask (COND 15 ⇒ cond_mask=all-ones). next≠0 → iterate (future=iteration=next; continue=0; EXEC=next; PC=head_pc). next==0 → exit (EXEC=parent_exec∧LIVE_MASK; pop; current_loop_index←prev_loop_idx; PC=end_pc+1). |
| BREAK [pN] / CONTINUE [pN] | M = EXEC (COND=15) or EXEC∧P[N]. Requires valid nearest loop else FAULT_ILLEGAL_CONTROL_FLOW. BREAK: future∧=~M, iteration∧=~M, EXEC∧=~M. CONTINUE: continue∨=M, iteration∧=~M, EXEC∧=~M. Both scrub M from IF frames above the target loop (no resurrection inside current iteration); lanes stay LIVE. Multi-cycle OK. |
| PUSHM | Pushes FRAME_MANUAL{saved_exec=EXEC}; no EXEC change. Overflow atomic. |
| POPM | Requires MASK_SP>0 (else UNDERFLOW) ∧ top FRAME_MANUAL (else ILLEGAL_CONTROL_FLOW); EXEC←saved_exec∧LIVE_MASK; pop. |
| SETM pN | EXEC←P[N]∧LIVE_MASK. COND=15 rejected (FAULT_ILLEGAL_CONTROL_FLOW). |
| ANDM pN | EXEC←EXEC∧P[N]∧LIVE_MASK. |
| ORM pN | EXEC←(EXEC∨P[N])∧LIVE_MASK (cannot resurrect returned lanes). |
| XORM pN | EXEC←(EXEC⊕P[N])∧LIVE_MASK. |
| RET_KERNEL_WF | returning=EXEC; LIVE_MASK∧=~returning; EXEC←0; scrub returning from all restorable frame masks; unwind engine resumes remaining live paths or completes wavefront when LIVE_MASK==0 (residual frames discarded, never underflow-classified). Empty-stack non-divergent RET behavior unchanged from M2–M4. |

All EXEC-producing operations of this family enforce EXEC ⊆ LIVE_MASK (ADR-011 invariant);
returned lanes can never reappear in any restored mask.

### 16.3 Predicate destination legality for V_CMP_*

`PDST[47:44] = 15` faults INVALID_REGISTER before any comparison beat commits (P15 is the
unpredicated input selector, never a writable destination). PDST 0..14 valid; writeback
preserves inactive-EXEC lanes (Rev1.3 INV-002 rule).

### 16.4 Recursion and call depth

Normative algorithms + worked examples: EXEC-001 Rev1.1 §4; ADR-011. Recursion prohibited v1
(SPEC NG/GPU-ISA-REQ-009); CALL depth limited to scalar link stack 8.

## 17. Matrix (MMA) and Dot Products (OPC 780–79F, 7A0–7AF)

`MMA.TILE.TYPExACC ddst, asrc, bsrc, csrc, sdesc` (FMT=8):

| MMAMOD type | Compute | Accumulator |
|---|---|---|
| 0 | FP16 × FP16 | FP32 |
| 1 | BF16 × BF16 | FP32 |
| 2 | INT8 × INT8 | INT32 |

Tile layout: A 8×8, B 8×8 row-major; row r elements held in VGPR lanes of consecutive registers
starting at base (exact VGPR tiling table in MICRO-001 Appendix; ISA fixes logical shape only).
K-chunk accumulation order fixed inside tile (deterministic; documented sequence k=0..7).
Descriptor SGPRs: strides (elements), k_chunks (v1 fixed 1 micro-tile per instruction; larger K =
software loops). Larger matrices = software scheduling over micro-tiles (ADR-006).

Dot products: `V_DOT.ADD.I8.I32`, `V_DOT.ADD.I16.I32`, `V_DOT.F16.F32`, `V_DOT.BF16.F32`,
`V_DOT.F32` (HINT[0] selects accumulate-into-vdst vs overwrite).

MMA is V-class: reservation-tracked, completion after accumulator commit; concurrent vector issue
guaranteed not to starve beyond documented bound (test obligation VER-001).

## 18. Collectives — RESERVED (OPC 800–83F)

Reserved encodings for shuffle/shuffle-up/shuffle-down/shuffle-XOR/broadcast/ballot/vote/
inclusive-prefix/exclusive-prefix. Not implemented v1 (SPEC §12.3); CU lane-interconnect must
remain capable (ARCH §9 note). Assemblers reject these mnemonics until capability bit appears.

## 19. System / Debug Instructions (OPC 840–85F; privileged unless noted)

NOP, BREAK (debug trap → FAULT_DEBUG_TRAP), TRAP imm (fault injection from kernel, privileged),
RDCLOCK sdst (free-running cycle counter, non-privileged), SEVFAULT code (privileged test hook),
DBG.HALT/STEP (privileged; halt FSM ARCH §25). All SYS forms are scalar-context; execution under
partial masks treats them as whole-wavefront actions.

## 20. Latency Classes and Pipeline Contracts

Per SPEC GPU-ISA-REQ-015 every instruction above carries: class (F1/F2/V/D/S per ARCH §14.1),
II (1 except V/D/S), operand-capture timing (start-of-first-beat sources captured; WAR-safe per
ADR-004), result path (write-back beat granularity; dest ready at final commit), exceptions
(§21). Exact cycle depths are MICRO-001/FP-001 property tables (deliberately not fixed here —
directive §39).

## 21. Exceptions and Faults per Class

| Class | Possible faults |
|---|---|
| Integer ALU/logic | INVALID_REGISTER (decode-time index check) |
| Integer div/mod bracket | + INTERNAL (unclosed bracket at retire) |
| FP ops | none trap; flags accumulate per FP-001 (P1 capture mechanism); invalid ops on absent capability → ILLEGAL_OPCODE |
| Memory | INVALID_ADDRESS, ALIGNMENT, ECC_UNCORRECTABLE(status), transport status errors mapped 1:1 |
| Atomics | same as memory + UNSUPPORTED_ATOMIC (reserved encodings) |
| Barriers/fences | ILLEGAL_BARRIER |
| Control/divergence | MASK_STACK_OVERFLOW, MASK_STACK_UNDERFLOW, RECONVERGENCE_MISMATCH (0x0D), ILLEGAL_CONTROL_FLOW (0x0E) — all atomic (no partial state on fault, ADR-011 D9) |
| MMA | INVALID_REGISTER(tile overrun), INTERNAL(descriptor malformed) |
| System | privilege violation → ILLEGAL_OPCODE class fault w/ cause bit |

Fault delivery: wavefront marked FAULTED, scheduler drains co-resident wavefronts of the kernel,
fault record written (ARCH §23), kernel completion reports failure (INV-007).

## 22. Extension Policy

New instructions: (1) fill unallocated slots inside an assigned range if same format/class;
(2) otherwise new range in reserved space (e.g., 860–8FF); collectives range 800–83F is frozen
forever for its purpose; (3) capability bit + SGP1 feature flag required before any binary may
reference new encodings; (4) breaking changes require ISA major bump (versioning policy SPEC
GPU-DOC-REQ-012). Wave64 would enter exclusively through this policy (NG-08).

---

## 23. Rev 1.2 Scalar Condition Amendment (normative summary)

### 23.1 SC_FLAGS / SCC

Per scalar execution context: `SC_FLAGS = {Z, N, C, V}` and boolean `SCC`. Derived from
`R = A - B` (mod 2^32): Z=(R==0); N=R[31]; C = carry-out of A + ~B + 1 (= no unsigned borrow,
i.e., C=1 ⇔ A ≥ B unsigned); V = (A[31]≠B[31]) ∧ (R[31]≠A[31]). SCC per compare op:
EQ=(A==B); LT_S=signed(A)<signed(B); GT_S=signed(A)>signed(B). Compare instructions write NO
SGPR (SDST reserved; assembler encodes 0; decoders tolerate legacy 63 but ignore it).

### 23.2 Branch COND[7:0] table

0x00 ALWAYS · 0x01 SCC · 0x02 NSCC · 0x03 Z · 0x04 NZ · 0x05 N · 0x06 NN · 0x07 C · 0x08 NC ·
0x09 V · 0x0A NV · 0x0B LT_S(N^V) · 0x0C GE_S(¬(N^V)) · 0x0D LT_U(¬C) · 0x0E GE_U(C) ·
0x0F RESERVED (execution faults).

### 23.3 Opcode allocations (no existing opcode moved)

0x007 S_SUB · 0x008 S_XOR · 0x009 S_NOT · 0x00A S_SHR · 0x00B S_SAR · 0x00C/0x00D ROL/ROR
reserved. Shift amounts use operand[4:0]; SAR uses explicit signed semantics.

### 23.4 S_GETID

SYS payload[15:8]=SDST, [7:0]=selector. WG_X=0 mandatory from M2; any other selector raises
FAULT_ILLEGAL_OPCODE (unsupported).

### 23.5 Completion PC convention

completion_pc records the address of the retiring RET_KERNEL_WF (or the faulting instruction).
Identical convention in RTL, golden simulator, trace, tests.

# Appendix A — SGP1 Kernel Container (normative)

Little-endian throughout; all offsets/lengths **64-bit**; file begins at offset 0.

```text
Offset  Size  Field
0x0000  4     Magic "SGP1" (0x31504753 LE)
0x0004  2     Format major (=1)
0x0006  2     Format minor
0x0008  2     Required ISA major
0x000A  2     Required ISA minor
0x000C  4     Feature flags (bit0 FTZ-default, bit1 rounding-modes, bit2 FP64-required,
              bit3 MMA-required, bit4 collectives-required, bit5 deterministic-mode… )
0x0010  8     Integrity checksum (CRC-64/ECMA over whole file with this field zeroed)
0x0018  8     Section-table offset
0x0020  4     Section count
0x0024  4     Entry-point-table offset (relative)
...             (header padded to 64 bytes)

Section entry (repeated):
  u32 type   {1=CODE 2=RODATA_CONSTANTS 3=KERNEL_META 4=SYMBOL 5=STRING 6=RELOC(opt) 7=DEBUG(opt)}
  u32 flags
  u64 offset ; u64 length ; u64 name_str_index

Entry-point record (per kernel):
  u32 name_idx; u32 flags;
  u64 pc_offset (into CODE);
  u32 vgpr_req; u32 sgpr_req; u32 smem_req; u32 rsv;
  u32 arg_desc_off (into KERNEL_META); u32 arg_count;

KERNEL_META section: argument descriptors {name_idx, type(F32/F64/I32…I64/PTR/CONST_BUF/
SHARED_PTR), size, sgpr_init_slot}; launch constraints; deterministic-mode requirements.

SYMBOL/STRING/RELOC/DEBUG: standard tables; relocations optional (static images preferred v1).

Rules: loader validates magic/version/ISA requirement/checksum (INV-022) and resource bounds vs
hardware capabilities before any fetch; multiple kernels per image allowed via entry-point table.
ELT-coexistence: types/naming chosen so future ELF sections can wrap SGP1 without reinterpretation
(SPEC GPU-ISA-REQ-014; ELF itself NOT required at M1).
```

# Appendix B — Assembler Syntax Overview

```text
; comment
.reg  vgpr_count=128 sgpr_count=64
.kern vector_add  args=(a:PTR_F32, b:PTR_F32, c:PTR_F32, n:I32)

vector_add:
  S_GETID   s10, WG_X            ; uniform ids
  S_MUL     s11, s10, s8         ; workgroup base element
  V_BCAST   v0, s11              ; base -> all lanes
  V_LLANE   v1                   ; v1[lane]=lane  (ABI startup reg alias)
  V_ADD     v1, v1, v0           ; global index
  V_CVT     F32.I32 v2, v1
  V_LOAD.W  v3, s0 + v1*4        ; a[i]
  V_LOAD.W  v4, s1 + v1*4        ; b[i]
  V_ADD.F32 v5, v3, v4
  V_STORE.W v5, s2 + v1*4        ; c[i]
  RET_KERNEL_WF
```

Directives: `.reg .kern .args .label .const .align`; operands use `s#/v#/p#`, immediates
decimal/hex; predicates suffix `[p#]`; vector memory syntax shows base+offset with implicit
lane scaling; strict diagnostics (unknown symbol, bad width pairing, reserved-opcode use without
feature flag). Full grammar ships with the assembler toolchain doc (SW-001 dependency, M1–M2).

*End of ISA-001 Rev 1.2.*
