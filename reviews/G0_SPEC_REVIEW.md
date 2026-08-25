# G0-SPEC Review — SPEC-000 Rev 0.1 → Rev 0.2

| Field | Value |
|---|---|
| Review ID | G0-SPEC |
| Date | 2026-08-23 |
| Documents reviewed | `docs/requirements/SPEC-000_GPU_PRODUCT_REQUIREMENTS.md` Rev 0.1; approved principal-architect directive (30 sections); `OPEN_ISSUES.md`; `CURRENT_WORK.md` |
| Reviewer | Principal GPU Architect (verification lead countersigned checklist) |
| Disposition | **PASS WITH NON-BLOCKING ACTIONS** |

## 1. Scope of Review

Verify SPEC Rev 0.1 against: (a) internal consistency; (b) the approved directive; (c) gate-model
integrity; (d) completeness of TBD resolution; (e) open-issue closure; then authorize Rev 0.2 as
the requirements baseline for architecture derivation.

## 2. Contradictions / Defects Found in Rev 0.1

| # | Finding | Resolution in Rev 0.2 |
|---|---|---|
| F-01 | `LANES_PER_WARP` overloaded logical wavefront size with physical FPGA width; made ISA semantics implementation-dependent | Replaced by `WAVEFRONT_SIZE=32` (architectural, fixed) + `SIMD_LANES ∈ {4,8,16,32}` (µarch) + execution-beat folding; GPU-EXEC-REQ-002 rewritten; GPU-SYS-REQ-016 added |
| F-02 | Gate "G0" used for both SPEC approval and full-baseline approval | Two-gate model G0-SPEC / G0-ARCH defined (§2, §14.1, §20); only G0-ARCH authorizes RTL |
| F-03 | TBD register (20 items) mixed resolved decisions with genuine unknowns | Replaced by §15.1 resolved decisions, §15.2 tunable parameters, §15.3 non-blocking studies with owner documents |
| F-04 | R0.1 proposed open-source licensing (BSD/CC) contradicting commercial-IP intent | ADR-010; proprietary/internal; LICENSE.md; THIRD_PARTY.md |
| F-05 | C-03 demanded equal feature support in Verilator AND Icarus, constraining legitimate SV | Verilator-primary policy; Icarus non-blocking (C-03) |
| F-06 | Scalar unit listed as P2 "may" vs directive "shall" | GPU-EXEC-REQ-009 rewritten P0, ADR-007, timeline M6–M7 |
| F-07 | Matrix tile size open; TF32 listed as optional internal type | 8×8×8 micro-tile fixed (ADR-006); TF32 excluded ISA v1 (NG-09); FP32 matrix deferred |
| F-08 | L2 hashing working assumption was "prime-hash" | Power-of-two XOR hashing of line address bits (GPU-CACHE-REQ-003); exact bit map → CACHE-001 non-blocking |
| F-09 | Divergence mechanism listed as open candidate set | Resolved: HW active-mask stack (default 32 entries, configurable) + compiler reconvergence targets; overflow/underflow faults (GPU-EXEC-REQ-003) |
| F-10 | Kernel container format unspecified | SGP1 defined (GPU-ISA-REQ-014): magic `SGP1`, LE, 64-bit offsets, full section list |
| F-11 | Virtual memory timing ambiguous ("later") | Physical/IOVA through G1–G4; MMU = G5; packet formats must accommodate (GPU-CACHE-REQ-006, C-11) |
| F-12 | No clock planning targets | GPU-FPGA-REQ-012: ≈150/≈200/250–300 MHz planning targets, evidence-gated claims |
| F-13 | No board hierarchy; BOARD_SELECTION as open architecture gate | ADR-009 staged hierarchy; BOARD_SELECTION reduced to procurement confirmation |
| F-14 | Performance targets entirely unset | GPU-PERF-REQ-006 efficiency objectives adopted (≥80/≥70/≥70/≥85/≥95) as engineering goals; absolute values deferred to baselines |
| F-15 | "warp" terminology scattered (WARPS_PER_CU, tb_warp_scheduler, prose) | Fixed terminology set (§5); parameter renamed RESIDENT_WAVEFRONTS_PER_CU; testbench names updated (tb_wavefront_scheduler); "warp" permitted only in cross-architecture comparison |
| F-16 | Scoreboard architecture fully open | Direction fixed per-wavefront register granularity; RAW blocks; WAW ordered; WAR structural; no renaming G1 (ADR-004, GPU-EXEC-REQ-008) |
| F-17 | RF implementation fully open | Lane-striped banked direction fixed with port strategy + hooks (ADR-002, GPU-REG-REQ-003) |
| F-18 | Memory transport fields unspecified; TID width risk of hard-coding | ADR-008 field list; GPU_ADDR_W=64; GPU_MEM_DATA_W=256 default; TID ≈12 b configurable, no hard-coded capacity |
| F-19 | Memory model risked "implementation-defined" | Scoped relaxed model normative in MEM-001 (GPU-MEM-REQ-001) |
| F-20 | ECC/RAS scope open | GPU-RAS-REQ-001/002 baseline: RF parity (SECDED opt HPC), SMEM SECDED, L2 SECDED, cmd-mem per criticality, injection capability |
| F-21 | Shared-memory banking unspecified | 32 banks × 32-bit, 4-byte granularity, conflict stats (GPU-SHM-REQ-002) |
| F-22 | I-cache size/organization open | Separate L1-I, 8–16 KiB/CU-or-cluster; final value non-blocking study (§15.3) |
| F-23 | FP64 ratio per profile open | ADR-005 table; MINIMAL may omit with honest capability reporting |
| F-24 | ISA encoding open (TBD-000-03) | 64-bit fixed LE + single extension word; no compression ISA v1 (GPU-ISA-REQ-002) |

## 3. Requirement Preservation Check

- All Rev 0.1 requirement IDs (GPU-SYS 001–015, GPU-ISA 001–015, GPU-INT 001–006, GPU-FP 001–013,
  GPU-SFU 001–004, GPU-MAT 001–004, GPU-EXEC 001–012, GPU-REG 001–005, GPU-LSU 001–004,
  GPU-SHM 001–003, GPU-CACHE 001–006, GPU-MEM 001–007, GPU-ATM 001–002, GPU-FE 001–006,
  GPU-HIF 001–006, GPU-DBG 001–005, GPU-RAS 001–006, GPU-SW 001–013, GPU-VER 001–017,
  GPU-FPGA 001–011, GPU-DOC 001–014, GPU-PERF 001–009) — **retained**.
- Reworded only where directive supersedes (F-01, F-06, F-07, F-09, F-10, F-11, F-16, F-17,
  F-18, F-20, F-23, F-24 and related); all other wording preserved.
- Added: GPU-SYS-REQ-016, GPU-ISA-REQ-016, GPU-ISA-REQ-017, GPU-FPGA-REQ-012.
- Removed: none.

## 4. TBD Dispositions (R0.1 register → Rev 0.2)

| R0.1 TBD | Disposition |
|---|---|
| TBD-000-01 wavefront width | RESOLVED — ADR-001 (32 logical; SIMD_LANES folding) |
| TBD-000-02 FP64 ratio | RESOLVED — ADR-005 |
| TBD-000-03 ISA encoding | RESOLVED — 64-bit LE fixed + extension word (GPU-ISA-REQ-002) |
| TBD-000-04 RF banking | DIRECTION RESOLVED — ADR-002; geometry → REG-001 (non-blocking study) |
| TBD-000-05 cache line | RESOLVED — 64 B (ADR-003) |
| TBD-000-06 scoreboard | RESOLVED — ADR-004 |
| TBD-000-07 matrix tile | RESOLVED — 8×8×8 (ADR-006) |
| TBD-000-08 board | RESOLVED — ADR-009 hierarchy; procurement = OI-006 |
| TBD-000-09 transport signals | RESOLVED — ADR-008 field list; normative spec → MEM-001 |
| TBD-000-10 clock target | RESOLVED as planning targets — GPU-FPGA-REQ-012 |
| TBD-000-11 kernel container | RESOLVED — SGP1 (GPU-ISA-REQ-014) |
| TBD-000-12 divergence mechanism | RESOLVED — mask stack + compiler targets (GPU-EXEC-REQ-003) |
| TBD-000-13 shared memory size | RESOLVED — 16/64/64/64(→128) KiB defaults (GPU-SHM-REQ-001) |
| TBD-000-14 L2 hashing | RESOLVED — power-of-two XOR; exact bits → CACHE-001 (non-blocking) |
| TBD-000-15 ECC scope | RESOLVED — GPU-RAS-REQ-001 baseline |
| TBD-000-16 license | RESOLVED — proprietary (ADR-010) |
| TBD-000-17 terminology | RESOLVED — fixed set (§5) |
| TBD-000-18 scalar unit | RESOLVED — mandatory (ADR-007) |
| TBD-000-19 perf targets | RESOLVED as policy — efficiency objectives (GPU-PERF-REQ-006); absolutes deferred by design |
| TBD-000-20 virtual memory | RESOLVED — physical/IOVA G1–G4; MMU = G5 (GPU-CACHE-REQ-006) |

## 5. Open-Issue Dispositions

OI-001 → CLOSED (§4 above). OI-002 → CLOSED (ADR-010). OI-003 → CLOSED (canonical `scigpu`,
rename deferred, OI-007 tracks rename). OI-004 → CLOSED at architecture level (ADR-009;
OI-006 procurement). OI-005 → CLOSED (GPU-PERF-REQ-006).

## 6. Consistency Verification Performed

- Cross-checked every §15.1 decision against requirement rows it touches — no contradictions found
  in Rev 0.2 text.
- Verified §11 profile table vs ADR-001/005 and §15.1 (WAVEFRONT_SIZE constant 32 in all columns;
  FP64 ratios match).
- Verified §12.3 rollout vs §14.2 milestones (M13 MMA, M14 FP64, M15 atomics).
- Verified acceptance criteria §17 vs milestones (scalar datapath row added at M6–M7).
- Verified gate language: §2, §14.1, §20 all state RTL authorization exclusively via G0-ARCH.

## 7. Residual Risks (accepted, tracked)

- R-01 FP64 FPGA cost (ADR-005 ladder mitigates; U55C for HPC).
- R-08 beat-folded semantic divergence (mitigation: invariants ARCH-INV-001/002/003 + differential
  sim-vs-RTL across SIMD_LANES; elevated to explicit risk in Rev 0.2).
- R-04 tool divergence (Verilator-primary reduces surface).

## 8. Non-Blocking Actions (do not gate this approval)

1. CACHE-001: finalize L2 XOR bit-selection map and L1 replacement policy (M10 evidence).
2. REG-001: RF bank geometry from conflict counters + synthesis (M6).
3. MEM-001: final TID width from outstanding-request histograms (M8+).
4. FP-001: div/sqrt algorithm choice + SFU error tables (M9–M13).
5. Procurement confirmation for ZCU104-class and U55C before purchase (OI-006).
6. Controlled repo rename at a clean checkpoint (OI-007).

## 9. Gate Checklist

| # | Criterion | Result |
|---|---|---|
| 1 | All P0 requirements internally consistent | ✅ |
| 2 | TBD register complete: every open value owned + resolution method | ✅ (§15.3 studies all owned) |
| 3 | Risks have mitigations or accepted exposure | ✅ (§16) |
| 4 | Milestones consistent with acceptance criteria | ✅ |
| 5 | Gate model unambiguous (G0-SPEC ≠ G0-ARCH) | ✅ |
| 6 | Directive decisions all reflected; none silently altered | ✅ (F-01..F-24) |
| 7 | No requirement lost from R0.1 | ✅ (§3) |
| 8 | Open issues resolved with references | ✅ (§5) |

## 10. Final Disposition

**PASS WITH NON-BLOCKING ACTIONS.**

SPEC-000 Rev 0.2 is **APPROVED at G0-SPEC** as the authoritative product-requirements baseline.
Architecture derivation (ARCH-001 first, then ISA-001 … ROADMAP-001) is authorized.
**GPU RTL development remains unauthorized until G0-ARCH** (complete M0 baseline +
`ARCHITECTURE_BASELINE_REVIEW.md` approved).
