# OPEN_ISSUES

Issue policy: each issue carries ID, description, severity, affected component, status
(mission rule §164). Issues are never deleted — closed issues move to the history table with
resolution + decision reference + date/revision. New issues are appended with the next free ID.

## Active issues

| ID | Description | Severity | Affected component | Status |
|---|---|---|---|---|
| OI-006 | Procurement check for FPGA boards (ZCU104-class; Alveo U55C) — availability/pricing must be re-verified before hardware purchase. Not an architecture blocker (ADR-009 defines hierarchy). | Low | FPGA milestones M19+ | Open — action before M19 |
| OI-007 | Controlled filesystem rename `gpu_dev` → `scigpu` deferred to a clean Git checkpoint (per directive §27). Canonical name recorded everywhere. | Low | Repository | Open — opportunistic |
| OI-008 | Non-blocking tuning studies tracked in SPEC-000 §15.3 (L2 XOR bit map, L1-I size, TID width, RF geometry, div/sqrt algorithm, SFU polynomials, etc.) are owned by their future documents and are NOT open architecture holes; they are listed here only as a pointer. | Info | Multiple (owners per SPEC §15.3) | Open by design |

| OI-009 | Vivado 2025.2 not installed in current environment → M2 synthesis smoke NOT RUN (recorded per directive §56). Formal FPGA gate remains M19; install or defer to FPGA-A milestone. | Low | GPU-FPGA-REQ-012 smoke | Open — non-blocking |

| OI-010 | Vector predicate default/tool-model inconsistency (PRED=0 vs normative 15; golden ignored VMOD) | Closed: encoders default PRED=15; [pN] syntax; golden effective-mask helper; VMOD legality faults. Evidence: reports/evidence/m3/{isa_predication_fix.log,post_predication_fix_m1.log} | ISA-001 Rev1.3; directive §4-11 | 2026-08-23, M3 |
| OI-011 | SGPR_COUNT=256 truncated bounds compare made every index invalid | Closed: widened 9-bit compares in sgpr_file+control; discipline applied to VGPR file. Evidence: reports/evidence/m3/sgpr_256_fix.log | Directive §12-13; GPU-REG-REQ-001 | 2026-08-23, M3 |

## Issue history (closed)

| ID | Description | Resolution | Decision reference | Closed |
|---|---|---|---|---|
| OI-012 | M4 CU integration not complete (scheduler verified; scigpu_m4_cu/top + suites remained). Design was preserved in rtl/core/scigpu_m4_cu.sv.wip. | Closed: CU integration complete — rtl/core/scigpu_m4_cu.sv + rtl/top/scigpu_m4_top.sv implement multi-resident fetch/issue/execute/completion; D01 smoke + T1–T9 suite PASS on L4/L8/L16/L32 and N=3/5; gate PASS WITH NON-BLOCKING ACTIONS. Evidence: reports/evidence/m4/m4_summary.md | reviews/M4_WAVEFRONT_SCHEDULER_GATE_REVIEW.md; tag gpu-m4-scheduler | 2026-08-23, M4 |
| OI-001 | All SPEC Rev 0.1 TBD items needed resolution or explicit non-blocking classification | Closed: TBD register replaced by resolved decisions (§15.1) + configuration parameters (§15.2) + non-blocking studies (§15.3) | SPEC-000 R0.2; ADR-001..010; reviews/G0_SPEC_REVIEW.md | 2026-08-23, SPEC R0.2 |
| OI-002 | Project license not selected (BSD proposed in R0.1) | Closed: proprietary/project-internal/all-rights-reserved; LICENSE.md created; THIRD_PARTY.md governs external items | ADR-010; C-07 | 2026-08-23, G0-SPEC |
| OI-003 | Repository naming (`gpu_dev` workspace vs mission sketch `scigpu/`) | Closed: canonical repo name = `scigpu`; current path retained until clean checkpoint rename | Directive §27; GPU-DOC-REQ-013; PROJECT_MAP.md | 2026-08-23, G0-SPEC |
| OI-004 | FPGA board selection uncertain | Closed at architecture level: staged hierarchy A=ZC702-class, B=ZCU104-class, C/D=Alveo U55C; procurement remains a pre-purchase check only | ADR-009; GPU-FPGA-REQ-002 | 2026-08-23, G0-SPEC |
| OI-005 | Numeric performance targets intentionally unset | Closed: efficiency-objective policy adopted (≥80% compute / ≥70% GEMM / ≥70% usable BW / ≥85% scheduler / ≥95% lanes); absolute values derived later in PERF-001 + hardware baselines | GPU-PERF-REQ-006 | 2026-08-23, G0-SPEC |

| OI-013 | Frozen M4 CU (scigpu_m4_cu.sv) carries latent defects found during M5 audit: implicit 1-bit nets truncate vector-context paths (ve_setup_eff, vec_*, sc_wa), vector ibuf never cleared at/after grant allowing replay, fetch fire/rsp overlap can wedge f_pend. Never exposed by M4's structural T1–T9 suite (no value differentials). scigpu_m5_cu is correct-by-construction and supersedes it. | High | scigpu_m4_cu | Open — repair or retire at M6 entry |
| OI-016 | FP32 vector ALU: rounding edge cases in subnormal handling and subtraction normalization produce incorrect results for certain operand patterns (VCVT works, FADD/FSUB/FMUL partially working). Root cause: multi-bit left-shift normalization loop in fp_add and sticky-bit propagation. | Medium | scigpu_vector_alu.sv FP functions | Open — M7 phase 2 |
| OI-015 | Banked-VGPR write/read addressing mismatch in m6_cu integration: engine writes land at unexpected bank index causing VGPR state divergence vs golden on all kernels. Mirror-write workaround attempted; root cause is column-index vs lane-index confusion in multi-dim unpacked array addressing. Units pass lint individually. Fix: rewrite storage as flat packed array with computed flat address. | Medium | scigpu_vgpr_banked_m6 + m6_cu hookup | Open — M6 phase 3 |
| OI-014 | Random generator emits BREAK inside nested IF within loops whose multi-path drain/resume interplay shows golden-vs-RTL event-stream divergence in a residual seed set; generator currently restricts randomized BREAK to loop-body scope (nested case covered by directed break_if_scrub + golden G04). Root-cause analysis pending joint stepping harness. | Medium | tools/gen_random_m5.py, mask-control semantics | Open — before M6 random regression |
