# FPGA-001 — SciGPU FPGA Prototyping Strategy

| Field | Value |
|---|---|
| Document ID | FPGA-001 |
| Title | FPGA Prototyping Strategy (Vivado/Vitis 2025.2) |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2 (GPU-FPGA-REQ-001..012); ADR-009; ARCH-001 §35 |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete FPGA strategy baseline |

---

## 1. Staged Targets (ADR-009)

| Stage | Board class | Config intent | Planning clock | Purpose |
|---|---|---|---|---|
| FPGA-A | ZC702-class 7-series (or conveniently available board) | MINIMAL: 1 CU, SIMD_LANES 4–8, small RF, no/mini L1, basic DDR | ≈150 MHz | architecture/functionality bring-up only; never defines the architecture |
| FPGA-B | ZCU104-class ZUS+ (equivalents allowed) | MEDIUM: 1–2 clusters, SIMD_LANES 8–16, L1/L2 present | ≈200 MHz | PS/PL AXI integration; Vitis bare-metal driver reference; interrupts/DMA |
| FPGA-C | Alveo U55C | LARGE: multi-CU, SIMD_LANES 16–32 | 250 MHz baseline | HBM experiments, coalescing/L2-slicing studies, PCIe host |
| FPGA-D | Alveo U55C (mature build) | HPC: max residency, FP64 1:2 (1:1 option), MMA per CU | 250 base / 300 stretch | performance characterization vs PERF-001 |

Procurement confirmation before purchase is a schedule action only (OI-006) — not an
architecture gate.

## 2. Integration Architecture

Core RTL untouched per stage; all vendor interaction in `platform/amd/vivado_2025_2/`:

```
scigpu_core (generic SV)
  ↕ scigpu_transport↔AXI4 adapter        [wrapper]
  ↕ AXI4-Lite control adapter            [wrapper]
  ↕ clk/rst CDC + PLL/BUFG wrappers      [wrapper]
  → Zynq PS HP ports / DDR4 MIG / HBM MC / PCIe-XDMA (stage-dependent)
Vitis BSP: drivers/scigpu + apps (gpu_info/selftest/memtest/vector_add/saxpy/gemm/benchmark)
```

## 3. Resource Strategy (planning approach — estimates validated by synthesis only)

- RF banks / SMEM / caches: BRAM inference first; URAM for LARGE/HPC stripe capacity;
  LUTRAM for MINIMAL.
- INT8/FP16/BF16 MACs → DSP48E2 cascades (MMA micro-tiles map to DSP columns).
- FP32 FMA → DSP+fabric hybrid pipelines.
- FP64 → fabric multi-stage pipelines (ADR-005); ratio knob governs count.
- FIFOs/credit blocks infer block RAM; CDC primitives from the sanctioned register only
  (INV-024).
Every stage records utilization/timing metrics including negative results
(GPU-FPGA-REQ-006); critical paths documented with mitigation analysis tied to pipeline-contract
impact review (GPU-FPGA-REQ-007).

## 4. Build System

Source-controlled Tcl only (GPU-FPGA-REQ-004): `platform/amd/vivado_2025_2/{project.tcl,
synth.tcl, impl.tcl, constraints/<board>.xdc}` regenerate projects from scratch; configuration
generator emits the chosen profile's parameter header from the central source (GPU-SYS-REQ-014);
bitstream + XSA + address/IRQ/clock map archived per handoff policy (GPU-FPGA-REQ-005) with
build ID embedded (GPU-DBG-REQ-005).

## 5. Bring-Up Sequence (per stage)

JTAG/programming → clocks/reset integrity → AXI-Lite register smoke (ID/build regs) → memory
path memtest via DMA → command processor NOP/queue ops → single instruction execution →
vector_add kernel → full regression subset on target → benchmark suite (stages B+). Each step
has pass criteria and evidence capture (VER-001 §9 discipline).

## 6. Regression Continuity Rule

No stage advances until it passes ALL prior-stage regressions on-target (GPU-FPGA-REQ-003);
on-target runs use the tiny emulation configuration for speed where needed without changing
semantics (GPU-FPGA-REQ-010).

## 7. Clock/Timing Policy

Planning targets per §1 are goals; achieved frequencies are claimed only from implemented
timing reports (GPU-FPGA-REQ-012). Frequency changes never modify architectural behavior
(GPU-SYS-REQ-016).

## 8. Forward Portability

Versal/HBM3-class parts: only wrapper deltas expected (transport adapters + memory-controller
selection); L2 slice-to-channel mapping re-tuned via configuration informed by platform
topology (MEM-001 §6 note) — ISA semantics untouched.

*End of FPGA-001 Rev 1.0.*
