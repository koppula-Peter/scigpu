# M3 Microarchitecture Review (pre-RTL gate, directive §135)

| Check | Result |
|---|---|
| WAVEFRONT_SIZE fixed at 32 (no parameterization in RTL ISA semantics) | ✅ `localparam W=32` only; SIMD_LANES is the sole width parameter |
| Beat mapping k·L + j, mask bit0 = lane0 | ✅ MICRO-001 §2.5/§2.13; dedicated V_LLANE oracle test planned (P01/P11) |
| Register semantics independent of L (VGPR[v][lane 0..31] architectural) | ✅ §2.6 |
| Masking precise: effective mask captured once; inactive lanes write nothing | ✅ §2.4/§2.5; sentinel-preservation tests planned (directive §97) |
| M4 scheduler NOT implemented early | ✅ single context, no ready/RR/residency structures |
| M6 RF NOT prematurely fixed | ✅ bootstrap 2D array documented as non-production (§2.6); beat-oriented port contract preserves M6 swap |
| No conflict with ISA-001 Rev1.3 / EXEC-001 / ARCH-001 | ✅ predication matches Rev1.3 §5.2; beats match ADR-001; faults reuse ARCH codes |
| SGPR/VGPR bounds widened arithmetic (256-safe) | ✅ SGPR fix landed; VGPR file uses same discipline |
| VMOD unsupported modifiers fault (not ignored) | ✅ golden enforced; RTL decode_m3 will enforce identically |

**Verdict: PASS — RTL implementation authorized.**
