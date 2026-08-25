# SPEC-000 — SciGPU Product Requirements Specification

| Field | Value |
|---|---|
| Document ID | SPEC-000 |
| Title | SciGPU Product Requirements Specification |
| Project | SciGPU — Scientific Computing GPGPU Architecture |
| Canonical repository | `scigpu` (current filesystem path: this workspace; see OPEN_ISSUES.md history) |
| Classification | Proprietary — Project Internal — All Rights Reserved |
| Status | **APPROVED — G0-SPEC** (approved for architecture derivation; does NOT authorize RTL) |
| Parent document | None (top of specification hierarchy) |
| Child documents | ARCH-001, ISA-001, EXEC-001, MEM-001, PERF-001, SW-001, VER-001, FPGA-001, ROADMAP-001 |
| Supersedes | SPEC-000 Rev 0.1 |
| Target release | Generation G4 (see §13.2); G5 reserved for GPU virtual memory |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 0.1 | 2026-08-23 | Principal GPU Architect | Initial draft for review |
| 0.2 | 2026-08-23 | Principal GPU Architect | G0-SPEC resolution revision. Approved principal directives applied: two-gate model (G0-SPEC / G0-ARCH); fixed `WAVEFRONT_SIZE=32` with separate microarchitectural `SIMD_LANES ∈ {4,8,16,32}` and execution-beat folding; terminology set fixed; 64-bit fixed-width little-endian ISA encoding (+1 extension word); mandatory scalar+vector architecture; lane-striped banked register file direction; register-granularity scoreboard direction; FP64 profile ratios; 8×8×8 matrix micro-tile; 64-byte cache lines; L2 power-of-two XOR slice hashing; shared-memory banking baseline (32 × 32-bit); vendor-neutral memory transport parameters; scoped relaxed memory model; divergence = HW mask stack + compiler reconvergence targets; proprietary licensing; SGP1 kernel container; physical/IOVA addressing through G4 (MMU → G5); planning clock targets; FPGA-A/B/C/D board hierarchy; preliminary efficiency objectives; Verilator-primary simulator policy; TBD register replaced by resolved decisions + non-blocking studies; OI-001..005 closed. All Rev 0.1 requirement IDs preserved unless explicitly superseded below. |

---

## 1. Purpose

This document is the top-level product requirements specification for the SciGPU project: an
independently designed, programmable, general-purpose **scientific-computing GPU/GPGPU
architecture** implemented in HDL, developed simulation-first in portable SystemVerilog, and
prototyped on AMD FPGA platforms via Vivado/Vitis 2025.2.

SPEC-000 defines **what the product must do and how its success is judged**. It does not define
*how* the product is built; microarchitecture, ISA encoding detail, and interface detail are
owned by the derived documents listed in §21. No derived document may contradict SPEC-000. If a
conflict is discovered, it shall be raised as a specification inconsistency and resolved through
document revision — never silently.

Requirement IDs are immutable and never reused. Rev 0.2 supersedes specific *wording* where an
approved architectural directive resolves a previously open point; every such change is recorded
in the Revision History and in `reviews/G0_SPEC_REVIEW.md`.

## 2. Normative Language and Conventions

- **shall** = mandatory requirement. **should** = strongly recommended; deviation requires
  recorded justification. **may** = optional.
- **Priority**: **P0** mandatory for correctness/usability, blocks milestone gates; **P1**
  required for full product vision, scheduled by ROADMAP-001; **P2** desirable/future,
  architecture must not preclude it.
- **Verification methods**: REV (review), ANA (analysis), INS (inspection), SIM (simulation),
  FRM (formal), HW (hardware demonstration).
- **Milestones** M0–M23 are defined in §14 and normatively in ROADMAP-001.
- **Gates** (normative, two distinct gates — never conflate):
  - **G0-SPEC**: approval of THIS document as the authoritative product-requirements baseline.
    Authorizes derivation of architecture documents. Does **not** authorize RTL.
  - **G0-ARCH**: approval of the complete M0 architecture baseline (SPEC-000 + ARCH-001 +
    ISA-001 + EXEC-001 + MEM-001 + PERF-001 + SW-001 + VER-001 + FPGA-001 + ROADMAP-001 +
    ARCHITECTURE_BASELINE_REVIEW). **Only G0-ARCH authorizes GPU RTL development.**
- **TBD/TBC**: any newly arising unknown is registered in OPEN_ISSUES.md with owner document and
  resolution method. The Rev 0.1 TBD register has been replaced by §15 (resolved decisions) and
  §15.3 (explicitly non-blocking future studies). No silent assumptions.
- Requirement IDs are immutable and never reused.

## 3. Product Vision and Mission

Build a **modern scientific GPGPU architecture from first principles**: a massively parallel
SIMT compute machine optimized for numerical and scientific workloads (linear algebra, signal
processing, simulation, Monte Carlo, ML compute), with excellent FP64 capability, high sustained
arithmetic throughput, high memory-bandwidth utilization, latency hiding through many resident
wavefronts, scalable compute-unit replication, and deterministic, deeply verifiable behavior.

The fundamental architectural distinction of SciGPU is maintained throughout all documents:
**architectural semantics are independent of implementation parameters.** A compiled kernel
binary executes identically (same results, same semantics) whether the physical implementation
has 4 or 32 SIMD lanes.

Development proceeds across four environments:

1. **Architecture & simulation** — ISA simulator, reference models, portable SystemVerilog RTL
   verified with open tools (Verilator primary; cocotb; C++/Python models; Icarus where feasible).
2. **FPGA prototype** — AMD Vivado 2025.2, portable core plus isolated `platform/amd/` wrappers,
   staged board hierarchy (ADR-009).
3. **Embedded bring-up & software** — Vitis 2025.2 bare-metal driver, runtime, applications.
4. **Productization** — Linux driver, userspace runtime, math/BLAS libraries, HPC optimization.

Graphics functionality is secondary and initially absent (§4.3).

**Honesty policy.** Until the acceptance criteria of §17 are met with evidence, the design shall
be referred to as a *developmental GPGPU*. No claim of equivalence to commercial accelerators is
permitted at any point. Performance is characterized against the project's own theoretical
models and measured baselines, never against marketing numbers.

## 4. Product Scope

### 4.1 In Scope

- Internal GPU ISA v1 (scalar + vector integer, floating point, SFU classes, matrix MMA,
  control with structured divergence, scoped memory operations, atomics, barriers/fences;
  collectives architecturally reserved), with assembler/disassembler and the SGP1 kernel container.
- SIMT execution model: logical wavefronts of exactly 32 work-items executed over configurable
  physical `SIMD_LANES` via execution beats; per-lane execution masks; hardware mask-stack
  divergence/reconvergence; hardware wavefront scheduling; latency hiding via residency.
- Compute hierarchy: host interface → command processor → work distributor → compute clusters →
  CUs (wavefront scheduler, scalar unit, vector pipelines, VGPR/SGPR subsystems, operand
  collector, scoreboard, LSU, shared memory, L1-I/L1-D, SFU, matrix engine, barrier unit) →
  L2 (sliced) → vendor-neutral memory fabric → platform memory controller.
- Precision: FP16, BF16, FP32, FP64 with IEEE 754-2019 semantics where claimed; INT8–INT64.
- Memory system: coalescing, MSHR-class tracking, banked shared memory, caches, explicit scoped
  consistency model, atomics, optional NoC at scale.
- Front end: command processor, queues, kernel dispatch, workgroup distribution, occupancy
  calculation, DMA, interrupts, watchdog, fault reporting.
- Debug/observability: debug registers, traces, performance counters, build identification.
- Software stack: ISA simulator, cycle-approximate model, assembler/disassembler, staged
  compiler path, kernel ABI, runtime (`libscigpu`), bare-metal and Linux drivers, simulation
  host driver, benchmarks, math/BLAS libraries.
- Verification: unit/subsystem/system testbenches, differential FP verification (SoftFloat-class
  oracle), assertions derived from ARCH-001 invariants, selective formal, coverage, regression
  automation, evidence records.
- FPGA implementation: portability rules, AMD wrappers, staged targets FPGA-A/B/C/D, scripted
  Vivado 2025.2 builds, bring-up, Vitis 2025.2 software.

### 4.2 Out of Scope (Initial Generations)

Rasterization, triangle setup, texture mapping, display output, graphics APIs, gaming shaders,
video codecs, virtualization, multi-GPU interconnect, DVFS power management, GPU-managed page
faults / full VM subsystem (reserved for G5), and confidential/proprietary implementation
material from any vendor.

### 4.3 Non-Goals and Claim Restrictions

| ID | Restriction |
|---|---|
| NG-01 | No IEEE 754 compliance claim until the VER-001 floating-point suite passes with recorded evidence. |
| NG-02 | No CUDA, OpenCL, ROCm, or SYCL compatibility claims. API *similarity* permitted; compatibility not claimed. |
| NG-03 | No performance-equivalence claims to commercial GPUs. |
| NG-04 | No copying of proprietary GPU RTL/drivers/documentation. Open references recorded in THIRD_PARTY.md. |
| NG-05 | No GPU virtual memory/MMU before G5 (physical device addresses or host-provided IOVA through G1–G4). |
| NG-06 | No multi-context, preemption, or multi-GPU in initial generations; architecture shall not preclude them. |
| NG-07 | No weakening of tests to pass; failures require root-cause analysis. |
| NG-08 | Wave64 (64-work-item wavefronts) is NOT part of ISA v1; introduction requires an architectural extension/new ISA capability. |
| NG-09 | TF32 is not in ISA v1. FP32 matrix acceleration is a later extension. |

## 5. Definitions, Acronyms, Terminology

Terminology is **fixed project-wide** (ADR context, directive-resolved). Internal source code,
ISA documentation, and architecture documents use exactly these terms. The word "warp" may
appear only when comparing SciGPU against another architecture.

| Term | Definition |
|---|---|
| Grid | The full 3-D domain of workgroups launched by one kernel dispatch. |
| Workgroup | A set of work items that share a CU's shared memory and synchronize via barriers. |
| Work-item | One logical thread of execution; owns private scalar/vector architectural state view. |
| Wavefront | A scheduled group of **exactly 32 work-items** executing in lockstep (SIMD). Architectural size is fixed for ISA v1 regardless of physical lane count (ADR-001). Formerly called "warp" in other architectures. |
| Lane | One logical slice of a wavefront, associated 1:1 with a work-item within the wavefront. |
| Execution beat | One pass of a wavefront instruction over the physical datapath; a full wavefront instruction requires `32/SIMD_LANES` beats. |
| SIMD_LANES | Microarchitectural parameter: physical lanes per vector pipeline ∈ {4,8,16,32}. Invisible to compiled kernels. |
| WAVEFRONT_SIZE | Architectural constant: 32 logical work-items per wavefront (ISA v1). |
| CU | Compute Unit — replicated resource owning scheduler(s), register files, pipelines, LSU, shared memory, L1. |
| Compute Cluster | Group of CUs sharing local fabric/L1-adjacent resources; replication unit below device level. |
| VGPR / SGPR | Vector register (per-lane element, lane-striped storage) / scalar register (uniform across wavefront). |
| SIMT | Single Instruction, Multiple Threads — the SciGPU execution model. |
| Divergence | Condition where lanes of a wavefront take differing control-flow paths; managed by active masking + mask-stack reconvergence. |
| FMA | Fused multiply–add; single rounding. |
| MMA | Matrix multiply-accumulate engine; native 8×8×8 micro-tile. |
| SFU | Special Function Unit (precise + approximate transcendental classes). |
| LSU | Load/Store Unit. |
| MSHR | Miss-State Holding Register; outstanding memory-request tracker. |
| SGP1 | SciGPU generation-1 kernel binary container format (magic `SGP1`). |
| IOVA | I/O virtual address provided by host/platform (used directly as device physical address through G4). |
| NoC | Network-on-Chip. |
| RAS | Reliability, Availability, Serviceability. |
| ULP | Unit in the Last Place; numerical error metric. |
| G1–G5 | Product generations defined in §13.2. |
| FPGA-A..D | FPGA scaling stages defined in §14.3 / FPGA-001. |

## 6. Stakeholders

| Stakeholder | Interest |
|---|---|
| Architecture/RTL lead (primary) | Correct, portable, well-documented, synthesizable design. |
| Verification lead | Reproducible evidence; no unverified claims. |
| Scientific users (future) | FP64 quality, deterministic numerics, usable toolchain. |
| FPGA implementers | Resource/timing feasibility; scripted reproducible builds. |
| Software/driver developers | Stable ABIs, capability discovery, debuggability. |
| IP holder | Retention of commercial options (proprietary licensing, ADR-010). |

## 7. Use Cases

| ID | Use case | Drives |
|---|---|---|
| UC-01 | Vector arithmetic `C=A+B`, `C=A×B`, `D=A×B+C` over many threads | M1–M3 first-execution milestones |
| UC-02 | Reductions: sum, dot, min/max, norms | M4+, barriers/synchronization |
| UC-03 | Dense linear algebra: GEMV, GEMM, tiled shared-memory GEMM | M13, MMA engine, shared memory |
| UC-04 | Stencil / finite-difference PDE kernels | coalescing, caches |
| UC-05 | FFT / signal processing | memory patterns, precision |
| UC-06 | Monte Carlo (RNG, transcendental SFU use) | SFU, divergence |
| UC-07 | N-body / particle simulation (FP64-heavy) | FP64 ratio, SFU, bandwidth |
| UC-08 | ML compute: FP16/BF16 MMA with FP32 accumulate | matrix engine, dot products |
| UC-09 | Arbitrary user kernels (programmability validation) | ISA completeness, compiler path |
| UC-10 | Benchmark/regression workloads for performance characterization | PERF-001 |

## 8. System Context and Operating Environments

```
Host (Linux x86 sim | Zynq UltraScale+ PS | PCIe host)
   │  control + data (generic host interface → AXI4/AXI4-Lite/AXI4-Stream on FPGA)
   ▼
SciGPU device
   ├─ Host interface / registers / interrupts
   ├─ Command processor → global dispatcher → compute clusters → CUs
   ├─ L2 (sliced) / memory fabric
   └─ Vendor-neutral memory transport → platform memory controller (DDR/HBM)
```

- **ENV-1 (primary, M0–M18):** x86-64 Linux host; Verilator (primary normative RTL
  simulator/linter), cocotb, Python/C++ reference models; generic memory models; Icarus used for
  compatible smoke/unit tests where feasible (shall not constrain RTL architecture).
- **ENV-2 (M19–M21):** AMD FPGA platforms per FPGA stage hierarchy (§14.3); Vivado 2025.2
  synthesis/elaboration is the FPGA implementation authority from M19; Vitis 2025.2 bare-metal.
- **ENV-3 (M22+):** Linux host driver `/dev/scigpu0`, userspace `libscigpu.so`.

The GPU core is identical across environments; only `platform/` wrappers differ.

## 9. Quality Attributes (ranked)

1. **Correctness** — verified behavior; no unproven claims.
2. **Architectural cleanliness** — clean separation of architectural semantics from
   implementation parameters (fundamental SciGPU principle).
3. **Verifiability** — every block has spec, reference model, tests, coverage.
4. **Determinism** — same binary + inputs + configuration ⇒ same results, within documented
   atomics/reduction-order caveats.
5. **Portability** — portable synthesizable SystemVerilog core; vendor code isolated.
6. **Scalability** — one parameterized RTL source spans GPU_MINIMAL→GPU_HPC.
7. **Observability** — counters, traces, debug, build identity.
8. **Maintainability/traceability** — docs, ADRs, unique requirement IDs.
9. **Performance** — characterized honestly against theoretical models and measurements.

## 10. Constraints

| ID | Constraint |
|---|---|
| C-01 | Primary RTL language: SystemVerilog (IEEE 1800-2017 synthesizable subset). Verilog-2001 permitted where advantageous. Testbench-only constructs confined to `verification/`. |
| C-02 | Architectural RTL shall not instantiate vendor primitives; all AMD-specific code confined to `platform/amd/`. |
| C-03 | **Simulator policy:** Verilator is the primary normative open-source RTL simulator/linter. Supported additionally: cocotb, C++/Python reference models. Icarus Verilog runs compatible smoke/unit tests where feasible; Icarus compatibility is desirable but shall NOT force inferior RTL architecture or prohibit well-supported synthesizable SystemVerilog constructs. Vivado 2025.2 elaboration/synthesis is authoritative for FPGA from M19. Optional commercial simulators may be supported later. |
| C-04 | FPGA tools: AMD Vivado 2025.2 and Vitis 2025.2; scripted, source-controlled, reproducible builds. |
| C-05 | Process: specification → model → microarchitecture → RTL → unit verification → integration verification → synthesis → performance → optimization → FPGA → software → validation. |
| C-06 | Resources: small team (principal + verification + AI-agent assistance); open tools preferred; schedule milestone-gated. |
| C-07 | **Licensing:** SciGPU original RTL, software, and documentation are **PROPRIETARY / PROJECT INTERNAL / ALL RIGHTS RESERVED** (ADR-010). No open-source license shall be applied to original work absent explicit future authorization. Third-party components keep their own license notices and are tracked in THIRD_PARTY.md. Berkeley SoftFloat 3e may be used strictly as an independent reference/oracle subject to its own notice; SoftFloat shall NOT be translated into RTL. |
| C-08 | Every streaming interface defines valid/ready backpressure with no-loss/no-duplication/no-deadlock arguments. |
| C-09 | All clock-domain crossings use reviewed CDC mechanisms; no independent multi-bit synchronizers. Clock frequency never alters architectural semantics. |
| C-10 | Evidence for all claims stored under `reports/evidence/`; fabricated results prohibited. |
| C-11 | Architectural addresses are 64-bit everywhere (`GPU_ADDR_W=64`). Through G4: physical device addresses or host-provided IOVA; no GPU-managed page faults. Interface/packet formats must accommodate a future G5 MMU without redesign. |

## 11. Product Configurations

One parameterized RTL source implements all configurations. `WAVEFRONT_SIZE = 32` is an
**architectural constant identical in every profile**; only microarchitectural parameters vary.
Values are planning envelopes pending PERF-001 refinement — they are not achieved designs.

| Parameter | GPU_MINIMAL | GPU_MEDIUM | GPU_LARGE | GPU_HPC |
|---|---|---|---|---|
| NUM_CLUSTERS | 1 | 1–2 | 2–4 | 4–16 |
| CU_PER_CLUSTER | 1 | 2–4 | 4–8 | 4–8 |
| WAVEFRONT_SIZE (architectural) | 32 | 32 | 32 | 32 |
| SIMD_LANES (µarch) | 4 or 8 | 8–16 | 16–32 | 32 where resources permit |
| RESIDENT_WAVEFRONTS_PER_CU (slots) | 2–4 | 8–16 | 16–32 | 16–64 |
| VGPR_COUNT (per work-item) | 32–64 | 64–128 | 128–256 | 128–256 |
| SGPR_COUNT (per wavefront) | 32–64 | 64–128 | 128–256 | 128–256 |
| SHARED_MEM_BYTES per CU | 16 KiB default | 64 KiB default | 64 KiB default | 64 KiB default, configurable 128 KiB |
| L1_D_SIZE per CU | minimal/optional | ~32 KiB | ~32 KiB | ~32 KiB+ |
| L1_I_SIZE | small (8 KiB class) | 8–16 KiB | 8–16 KiB/CU or cluster | 8–16 KiB/CU or cluster |
| L2_SIZE / slices | none–small / 1 | 128–512 KiB / 1–2 | 1–4 MiB / 4–8 | multi-MiB / 8–16 |
| FP64:FP32 throughput ratio | omitted or ~1:8 | **1:4** | **1:2** | **1:2 default; 1:1 option** |
| MATRIX_UNITS | 0 | 0–1/CU | 1/CU | 1/CU |
| MEMORY_DATA_WIDTH (`GPU_MEM_DATA_W`) | 64–128 b | 128–256 b | 256 b | 256 b+ |
| MAX_OUTSTANDING_MEM_REQ | 8–16 | 32–64 | 64–128 | 128+ |

Rules: invalid parameter combinations shall fail elaboration/configuration checks with a clear
diagnostic; configuration is centralized and generates consistent RTL/simulator/runtime views;
generated files marked "GENERATED — DO NOT EDIT" with generator reference. Physical
configuration shall never require kernel recompilation (ADR-001).

## 12. Functional and Technical Requirements

All requirements APPROVED at G0-SPEC unless annotated otherwise. Owning documents and
traceability targets are in §21.

### 12.1 System and Integration (GPU-SYS)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-SYS-REQ-001 | The product shall be a programmable general-purpose compute accelerator executing user kernels expressed in the SciGPU ISA (ISA-001). | P0 | SIM | M1+ |
| GPU-SYS-REQ-002 | Kernel execution shall follow the hierarchy grid → workgroup → work-item → wavefront → lane using the fixed terminology of §5 in all documents, RTL, and software. | P0 | REV | M1 |
| GPU-SYS-REQ-003 | All configurations (§11) shall be built from a single parameterized RTL source tree; no per-configuration forks. | P0 | INS | M3+ |
| GPU-SYS-REQ-004 | Software shall discover device capabilities via registers (CU count, SIMD_LANES, precision support, caches, memory), never by hardcoded assumption. | P0 | INS | M17 |
| GPU-SYS-REQ-005 | All MMIO registers shall be defined in one versioned register-map specification; magic offsets scattered through RTL/software are prohibited. | P0 | INS | M17 |
| GPU-SYS-REQ-006 | Identification registers shall expose vendor ID, architecture ID/version, RTL version, build/git ID, CU count, SIMD_LANES, feature bits, memory capabilities. | P0 | INS | M17 |
| GPU-SYS-REQ-007 | Every sequential module shall define its post-reset state; the GPU shall reach a known deterministic state after any defined reset. | P0 | SIM | M2+ |
| GPU-SYS-REQ-008 | The initial architecture shall use one primary synchronous GPU clock; any additional clock domains require documented, reviewed CDC per C-09. | P0 | REV | M0+ |
| GPU-SYS-REQ-009 | A configurable watchdog shall detect stuck kernels and support: disable, cycle timeout, graceful abort, hard reset. | P1 | SIM | M17 |
| GPU-SYS-REQ-010 | All faults shall map to defined documented error codes covering illegal opcode, invalid register, invalid address, alignment fault, exec-mask stack overflow/underflow, illegal barrier, timeout, watchdog, cache ECC error, command parser error, malformed kernel, internal consistency failure. | P0 | SIM | M9+ |
| GPU-SYS-REQ-011 | A driver-triggerable self-test shall exercise registers, memories, ALU/FP, DMA, and command processor. | P1 | HW | M21 |
| GPU-SYS-REQ-012 | Core RTL shall be lint-clean and elaboration-clean under Verilator (primary) and synthesizable under Vivado; testbench/assertion code segregated. | P0 | INS | M2+ |
| GPU-SYS-REQ-013 | Configuration parameter sets shall be validated; illegal combinations shall fail elaboration with a clear message. | P0 | SIM | M3 |
| GPU-SYS-REQ-014 | RTL, simulator, and runtime configuration views shall be generated from a central source of truth; generated files marked "GENERATED — DO NOT EDIT" with generator reference. | P1 | INS | M6+ |
| GPU-SYS-REQ-015 | A clean checkout shall reproduce simulator, assembler, tests, and (later) FPGA builds deterministically, with documented dependencies. | P0 | INS | M2 |
| GPU-SYS-REQ-016 | Architectural semantics shall be invariant to SIMD_LANES, clock frequency, and other microarchitectural parameters; a kernel binary shall not require recompilation when physical configuration changes. | P0 | SIM | M3+ |

### 12.2 Instruction Set Architecture (GPU-ISA)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-ISA-REQ-001 | An internal GPU ISA shall be fully specified in ISA-001, independently versioned; the ISA version shall be discoverable via register. | P0 | REV | M1 |
| GPU-ISA-REQ-002 | **ISA v1 encoding:** 64-bit fixed-width, little-endian base instructions. A rare instruction class may consume exactly one additional 64-bit extension word (maximum 128-bit encoded operation) for extended immediates, some matrix descriptors, and specialized control information. No 16/32-bit compressed encodings in ISA v1. Instruction fetch and I-cache architecture shall nevertheless be bandwidth-scalable. Rationale (simple decode, adequate register indices, multiple operands, predicate/mask info, FP modifiers, immediates, extension space, compiler friendliness) documented in ISA-001/ADR record. | P0 | REV | M1 |
| GPU-ISA-REQ-003 | The ISA shall define integer operations: ADD, SUB, MUL, MULHI, DIV, REM, MIN, MAX, ABS, NEG, AND, OR, XOR, NOT, SHL, SHR, SAR, ROT, POPCNT, CLZ, CTZ, bit-field insert/extract — scheduled per §12.3 priorities. | P0 | SIM | M1–M9 |
| GPU-ISA-REQ-004 | The ISA shall support data types INT8/UINT8/INT16/UINT16/INT32/UINT32/INT64/UINT64, introduced per §12.3. | P0/P1 | SIM | M2–M11 |
| GPU-ISA-REQ-005 | The ISA shall define floating-point operations: add, sub, mul, FMA, FMS, divide, reciprocal, sqrt, rsqrt, min, max, abs, neg, compare, conversion, rounding, classification — for supported precisions, in precise and approximate classes where applicable. | P0 | SIM | M1–M14 |
| GPU-ISA-REQ-006 | Conversions shall be defined between all supported numeric types with defined rounding and exception behavior. | P0 | SIM | M7+ |
| GPU-ISA-REQ-007 | Compare and classification instructions shall expose ordered/unordered results and FP class codes; comparisons shall feed the predicate/exec-mask mechanism. | P0 | SIM | M7 |
| GPU-ISA-REQ-008 | Every vector instruction shall operate under the wavefront active mask exposed through ISA-visible predication/mask semantics. | P0 | SIM | M3–M5 |
| GPU-ISA-REQ-009 | Control flow shall include conditional/unconditional branch (vector-masked and scalar/uniform), call, return, loop support, break/continue, and explicit mask-stack push/pop/reconvergence-target semantics; recursion prohibited initially. | P0 | SIM | M4–M5 |
| GPU-ISA-REQ-010 | Memory instructions shall include scalar/vector load/store at 8/16/32/64-bit granularity with scope/ordering/hint attributes, fences, and (later) atomics. | P0 | SIM | M8+ |
| GPU-ISA-REQ-011 | Workgroup barrier and scoped memory-fence instructions shall exist. | P0 | SIM | M9/M15 |
| GPU-ISA-REQ-012 | Matrix MMA instructions (native 8×8×8 micro-tile; FP16→FP32acc, BF16→FP32acc, INT8→INT32acc; larger logical tiles composed in software) and vector dot-product instructions shall be defined with clean encoding; descriptor-carrying forms may use the extension word. | P1 | SIM | M13 |
| GPU-ISA-REQ-013 | An assembler (labels, constants, registers, predicates, directives, comments, diagnostics) and disassembler shall exist before any RTL milestone executes code. | P0 | SIM | M1–M2 |
| GPU-ISA-REQ-014 | Kernel binary container **SGP1**: magic `SGP1`; little-endian; 64-bit offsets/lengths; containing format major/minor, required ISA major/minor, feature flags, entry-point table, section table, code, read-only constants, kernel metadata, symbol table, string table, optional relocations, register requirements (VGPR/SGPR), shared-memory requirements, kernel argument descriptions, optional debug information, integrity field/checksum. Design shall permit future ELF tooling coexistence; ELF is not required at M1. Normative layout in ISA-001 Appendix A. | P0 | SIM | M1/M18 |
| GPU-ISA-REQ-015 | Every instruction shall be documented with encoding, semantics, latency class, pipeline contract, exception behavior, and compiler-utility notes. | P0 | REV | M1+ |
| GPU-ISA-REQ-016 | The ISA shall include a scalar (uniform) instruction set operating on SGPRs — arithmetic/logic/shift/bit ops, scalar branches/control, uniform address computation — clearly distinguished from vector operations by encoding and mnemonic convention. | P0 | SIM | M1 (spec) / M6–M7 (RTL) |
| GPU-ISA-REQ-017 | A contiguous opcode range shall be RESERVED (not allocated) for lane collectives (shuffle/shuffle-up/shuffle-down/XOR-shuffle/broadcast/ballot/vote/prefix) so their later addition cannot fragment encoding space. | P1 | REV | M1 |

### 12.3 Numeric Precision Rollout (normative schedule)

| Capability | Introduced | Priority | Notes |
|---|---|---|---|
| INT32/UINT32 ALU (add/sub/logic/shift/mul) | M2–M3 | P0 | Scalar first, then SIMD |
| INT64/UINT64 | M9–M11 | P1 | |
| INT16/INT8 (+packed/SIMD-in-register) | G3 study | P2 | |
| POPCNT/CLZ/CTZ/bit-field/ROT | M3–M9 | P1 | |
| FP32 add/sub/mul/compare/convert | M7 | P0 | |
| FP32 FMA (true fused) | M7–M8 | P0 | |
| FP32 precise div/sqrt/rcp/rsqrt | M9–M12 | P1 | |
| FP16/BF16 storage + conversions | M9–M12 | P1 | |
| FP16/BF16 FMA / dot / MMA | M13 | P1 | With matrix engine |
| FP64 add/mul/FMA (full IEEE path) | M14 | P0 | Profile ratios per ADR-005 |
| FP64 div/sqrt | M14+ | P1 | |
| SFU approximate set (exp/log/trig/atan/pow) | M13+ | P1 | Documented ULP bounds |
| MMA 8×8×8 FP16/BF16→FP32, INT8→INT32 | M13 | P1 | ADR-006 |
| FP32 matrix / TF32 / FP64 matrix | study | P2 | NG-09; TF32 excluded ISA v1 |
| Atomics (int32/64, scoped) | M15 | P1 | FP atomic add P2 |
| Collectives (shuffle/ballot/prefix) | G3+ | P1 | Encodings reserved at M1 |

### 12.4 Integer Pipeline (GPU-INT)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-INT-REQ-001 | Pipelined integer units (scalar and vector) shall support ADD/SUB, compare, logic, shifts, rotates, bit operations with documented latency class and initiation interval. | P0 | SIM | M2–M3 |
| GPU-INT-REQ-002 | Integer multiply (incl. MULHI) shall be pipelined with documented latency class. | P0 | SIM | M3–M9 |
| GPU-INT-REQ-003 | DIV/REM shall be separated long-latency operations that do not stall the main pipeline; latency class and scoreboard interaction documented. | P0 | SIM | M9 |
| GPU-INT-REQ-004 | Width support per §12.3; mixed-width operations have defined conversion semantics. | P0/P1 | SIM | M2–M11 |
| GPU-INT-REQ-005 | POPCNT, CLZ, CTZ, bit-field insert/extract supported (scalar and vector). | P1 | SIM | M3–M9 |
| GPU-INT-REQ-006 | Signed/unsigned semantics explicit in ISA; unintended signed-conversion behavior prohibited in RTL. | P0 | INS | M2+ |

### 12.5 Floating-Point Architecture (GPU-FP)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-FP-REQ-001 | FP32 add/sub/mul/FMA/FMS shall be pipelined (staged unpack/align/op/normalize/round/pack style), with documented pipeline contracts. | P0 | SIM | M7 |
| GPU-FP-REQ-002 | FMA shall be truly fused (single rounding) for FP32 and FP64; non-fused mul+add sequences identifiable and documented. | P0 | SIM | M7/M14 |
| GPU-FP-REQ-003 | FP32 divide, sqrt, reciprocal, rsqrt shall exist in a *precise* class with documented accuracy targets. | P1 | SIM | M9–M12 |
| GPU-FP-REQ-004 | FP64 add/mul/FMA per §12.3 with true-fused FP64 FMA eventually mandatory. Profile FP64:FP32 throughput targets (ADR-005): MINIMAL omit-or≈1:8; MEDIUM 1:4; LARGE 1:2; HPC default 1:2 with 1:1 build option. Architectural ISA support defined even when omitted physically. | P0 | SIM | M14 |
| GPU-FP-REQ-005 | FP16/BF16 arithmetic per §12.3 with FP32 accumulate types (MMA/dot). | P1 | SIM | M13 |
| GPU-FP-REQ-006 | Semantics for ±0, infinities, sNaN/qNaN, subnormals, overflow, underflow, cancellation, rounding fully specified per operation in FP-001. | P0 | REV | M7 (FP32), M14 (FP64) |
| GPU-FP-REQ-007 | Rounding: round-to-nearest-even P0; round-toward-zero/±∞ P1; dynamic per-wavefront rounding mode P2. | P0/P1 | SIM | M7+ |
| GPU-FP-REQ-008 | Subnormal support: FP32/FP64 accept and produce subnormals at least in HPC; flush-to-zero mode may exist elsewhere; mode behavior documented. | P0 (HPC)/P1 | SIM | M7/M14 |
| GPU-FP-REQ-009 | FP exception flags (invalid, divide-by-zero, overflow, underflow, inexact) defined; capture mechanism per-wavefront specified in FP-001. | P1 | SIM | M12+ |
| GPU-FP-REQ-010 | min/max/abs/neg/classification and ordered/unordered comparison defined for all precisions. | P0 | SIM | M7+ |
| GPU-FP-REQ-011 | No IEEE 754-2019 compliance claim until VER-001 FP suite passes with evidence (NG-01). | P0 | REV | gate |
| GPU-FP-REQ-012 | Arithmetic results deterministic for identical inputs/configuration; no dependence on uninitialized state. | P0 | SIM | M7+ |
| GPU-FP-REQ-013 | FP units differentially verified against an independent oracle (SoftFloat-class reference used as software oracle only — never translated to RTL — per C-07) over randomized and corner-case vectors. | P0 | SIM | M7/M14 |

### 12.6 Special Function Unit (GPU-SFU)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-SFU-REQ-001 | SFU operations partitioned into *precise* (documented exact/correctly-rounded) and *approximate* (documented ULP target) classes, distinguishable in the ISA. | P0 | REV | M9 |
| GPU-SFU-REQ-002 | Approximate class includes recip, rsqrt, exp/exp2, log/log2, sin, cos, tan, atan, atan2, pow with published maximum-error targets over the documented domain. | P1 | SIM | M13+ |
| GPU-SFU-REQ-003 | SFU accuracy validated against high-precision references (mpmath-class); error tables in FP-001. | P0 | SIM | M13+ |
| GPU-SFU-REQ-004 | Hyperbolic functions may be added if justified. | P2 | SIM | study |

### 12.7 Matrix/Tensor and Dot Products (GPU-MAT)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-MAT-REQ-001 | The native physical MMA micro-tile is **8×8×8** multiply-accumulate (`D += A×B`). Logical operations of 16×16 or larger shall be constructed from native micro-tiles through software/compiler scheduling. | P1 | SIM | M13 |
| GPU-MAT-REQ-002 | Primary initial MMA types: **FP16×FP16→FP32 accumulate; BF16×BF16→FP32 accumulate; INT8×INT8→INT32 accumulate.** FP32 matrix acceleration is a later extension; TF32 excluded from ISA v1 (NG-09); FP64 MMA not mandatory initially. General FP64 SIMT remains mandatory (GPU-FP-REQ-004). | P1 | SIM | M13 |
| GPU-MAT-REQ-003 | MMA execution shall coexist with general SIMT execution without deadlock or starvation; arbitration documented. | P1 | SIM | M13 |
| GPU-MAT-REQ-004 | Vector dot-product instructions (INT8, INT16, FP16, BF16, FP32) with selectable accumulator types shall exist. | P1 | SIM | M13 |

### 12.8 SIMT Execution, Scheduling, Dependencies (GPU-EXEC)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-EXEC-REQ-001 | Every vector instruction executes under a per-lane active mask; inactive lanes shall not modify architectural state. | P0 | SIM | M3–M5 |
| GPU-EXEC-REQ-002 | **Execution width architecture (ADR-001):** the architectural wavefront size `WAVEFRONT_SIZE = 32` is FIXED for ISA v1 — independent of FPGA implementation size. A separate microarchitectural parameter `SIMD_LANES ∈ {4, 8, 16, 32}` defines physical lanes. A logical 32-work-item wavefront executes over `32/SIMD_LANES` execution beats (4 lanes→8 beats; 8→4; 16→2; 32→1). Architectural wavefront state always contains 32 work-items; partial wavefronts are represented through active masks; compiled kernels never change with SIMD_LANES. Wave64 is excluded from ISA v1 (NG-08) and would require an architectural extension. | P0 | SIM/ANA | M1–M3 |
| GPU-EXEC-REQ-003 | **Divergence mechanism (resolved):** hardware active-mask stack + compiler/assembler-provided reconvergence targets (structured control flow). Shall support nested conditional branches, loops, break, continue, early return, partial wavefronts, masked memory operations. Default stack depth 32 entries, configurable. Hardware shall NOT dynamically compute post-dominators. Stack overflow/underflow raises a controlled GPU fault. | P0 | SIM | M5 |
| GPU-EXEC-REQ-004 | A dedicated divergence test suite (nested ifs, loops with breaks, early returns, masked memory ops) exists and passes. | P0 | SIM | M5 |
| GPU-EXEC-REQ-005 | A hardware wavefront scheduler per CU tracks per-wavefront PC, active mask, ready/stalled state, register/memory dependencies, barrier state, completion. | P0 | SIM | M4 |
| GPU-EXEC-REQ-006 | Initial scheduling policy: simplest deterministic correct algorithm (round-robin among ready wavefronts); fairness documented; advanced policies (greedy-then-oldest, latency-aware, dual-issue) are P2 studies. | P0 | SIM/FRM | M4 |
| GPU-EXEC-REQ-007 | Multiple wavefronts simultaneously resident per CU to hide pipeline/memory latency; occupancy limits computed from VGPR/SGPR capacity, scratchpad, wavefront slots (equations in ARCH-001/PERF-001). | P0 | SIM | M4–M6 |
| GPU-EXEC-REQ-008 | **Scoreboard direction (ADR-004):** per-wavefront register-granularity dependency scoreboard tracking at minimum: pending VGPR writes, pending SGPR writes, long-latency results, outstanding loads, outstanding stores where required, atomic transactions, execution-unit availability, barrier dependencies. RAW hazards block issue. WAW hazards shall not permit architecturally incorrect completion ordering. WAR prevented through the defined operand-capture/issue model. No register renaming in generation 1. Detailed implementation owned by SCHED-001/REG-001/MICRO-001. | P0 | SIM | M6 |
| GPU-EXEC-REQ-009 | **Scalar datapath (ADR-007):** SciGPU SHALL include both a vector/SIMT datapath (per-work-item values under active mask) and a scalar datapath (values uniform across a wavefront). Each CU eventually contains: scalar ALU, SGPR file, scalar branch/control path, vector ALUs, VGPR subsystem. Not required in earliest M2/M3 prototype; incorporated during approximately M6–M7 architecture development. Compiler/ISA clearly identify scalar vs vector operations. Independent SciGPU encoding; no vendor ISA copied. | P0 | SIM | M6–M7 |
| GPU-EXEC-REQ-010 | Predicate registers (per-lane predicate bits produced by comparisons, consumed by branches/masking) shall be provided. | P1 | SIM | M5+ |
| GPU-EXEC-REQ-011 | Collectives — shuffle/shuffle-up/shuffle-down/XOR shuffle, broadcast, ballot/vote, prefix scans — shall have a preserved architectural path (CU lane data-movement network must not preclude them); implementation per §12.3. | P1 | SIM | G3+ |
| GPU-EXEC-REQ-012 | Exception model defines behavior for illegal instruction, invalid register/address, alignment fault, div-by-zero, FP exception, exec-mask stack fault, watchdog: trap, kernel termination, or fault report. | P0 | SIM | M9+ |

### 12.9 Register File and Operand Collection (GPU-REG)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-REG-REQ-001 | Each CU owns a vector register file with configurable VGPRs per work-item and resident wavefront count; architectural state exists for all 32 logical lanes of each resident wavefront regardless of SIMD_LANES. | P0 | SIM | M3–M6 |
| GPU-REG-REQ-002 | A scalar SGPR file exists per CU serving the scalar datapath (ADR-007). | P0 | SIM | M6–M7 |
| GPU-REG-REQ-003 | **Register architecture direction (ADR-002):** lane-striped banked vector register architecture. Register addressing independent of physical SIMD width; logical requirement two source reads + one destination write per vector operation per beat. FPGA implementations achieve ports through BRAM/URAM replication, banking, operand collection, multi-beat time multiplexing per configuration. Small FPGA configurations may trade latency for RF resources; LARGE/HPC maximize sustained issue rate. ARCH-001 defines the architecture sufficiently that REG-001 specifies exact physical implementation. Hooks required: RF parity, eventual RF ECC, register-bank conflict counters. | P0 | ANA | M6 |
| GPU-REG-REQ-004 | Multi-port problem addressed via banking + operand collector + arbitration (± replication/time-multiplexing), strategy documented. | P0 | SIM | M6 |
| GPU-REG-REQ-005 | Operand collector maps register operands to banks, arbitrates conflicts, delivers operands per beat; register-bank conflict rate measurable via counter. | P0 | SIM | M6 |

### 12.10 Load/Store Unit and Coalescing (GPU-LSU)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-LSU-REQ-001 | LSU supports scalar and vector load/store at byte/halfword/word/doubleword granularity for aligned accesses. | P0 | SIM | M8 |
| GPU-LSU-REQ-002 | Unaligned access behavior (handled or trapped) defined in MEM-001, implemented consistently. | P1 | SIM | M8+ |
| GPU-LSU-REQ-003 | Gather/scatter supported. | P1 | SIM | G3 |
| GPU-LSU-REQ-004 | Coalescer groups active-lane addresses into minimal memory transactions and routes return data to lanes; tested for contiguous, stride-2/4, random, partial masks, boundary crossings, unaligned patterns. | P0 | SIM | M8 |

### 12.11 Shared Memory (GPU-SHM)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-SHM-REQ-001 | Per-CU, workgroup-visible, software-managed, banked scratchpad. Sizes (defaults): MINIMAL 16 KiB; MEDIUM 64 KiB; LARGE 64 KiB; HPC 64 KiB default configurable to 128 KiB. | P0 | SIM | M9 |
| GPU-SHM-REQ-002 | Banking baseline: **32 banks × 32-bit bank width, 4-byte bank granularity.** Broadcast on uniform-address accesses; conflict detection with serialization; bank-conflict statistics/counters. | P0 | SIM | M9 |
| GPU-SHM-REQ-003 | Workgroup placement honors shared-memory requirements. | P0 | SIM | M11–M12 |

### 12.12 Cache Hierarchy (GPU-CACHE)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-CACHE-REQ-001 | Per-CU L1 data cache: **64-byte lines (baseline)**; approximately 32 KiB for medium/large profiles; configurable; set-associative; architecture shall permit 4-way implementation. Policy baseline (write-through/no-write-allocate G1 default) normatively specified in CACHE-001. | P1 | SIM | M10 |
| GPU-CACHE-REQ-002 | Separate instruction cache (~8–16 KiB per CU or cluster per architecture analysis), bandwidth-scalable fetch per GPU-ISA-REQ-002. | P1 | SIM | M10 |
| GPU-CACHE-REQ-003 | Shared L2: banked/**sliced**; configurable slice count ≈ {1,2,4,8,16}; **power-of-two XOR hashing of cache-line address bits** selects slices (no prime hashing); slice-to-memory-channel mapping must consider FPGA DDR/HBM topology. Exact XOR bit-selection parameterized and analyzed in CACHE-001 (non-blocking tuning). | P1 | SIM | M10 |
| GPU-CACHE-REQ-004 | Initial coherence policy (explicitly synchronized / non-coherent) documented, including L1/L2, DMA visibility, host coherence with flush/invalidate controls. | P0 | REV | M10 |
| GPU-CACHE-REQ-005 | Read-only/constant path may be provided. | P2 | SIM | study |
| GPU-CACHE-REQ-006 | **Addressing:** all architectural addresses 64-bit. Through G4: physical device addresses or host-provided IOVA, pinned/mapped host memory, no GPU-managed page faults, no full GPU VM subsystem; Linux may employ a platform IOMMU where available. A complete GPU MMU (page-table walker, TLB, ASID/context, page faults, migration) belongs to future **G5**; current packet/interface formats shall accommodate it later. | P0 | REV | G1–G4 |

### 12.13 Memory System, Consistency, Fabric (GPU-MEM)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-MEM-REQ-001 | **Scoped memory model (normative in MEM-001):** scopes = wavefront, workgroup, device. Plain global accesses follow a relaxed model with precisely defined per-work-item ordering. Explicit acquire, release, acquire-release semantics; device-scope and workgroup-scope fences; workgroup barrier semantics. Atomic operations eventually carry ordering/scope attributes. The model shall NOT be "implementation-defined." | P0 | REV/SIM | M9–M15 |
| GPU-MEM-REQ-002 | **Vendor-neutral internal memory transport** (AXI appears nowhere inside compute-unit architectural logic; translation isolated under `platform/amd/`). Baseline request fields: req_valid, req_ready, operation, 64-bit address, access size, transaction ID, burst/transaction length, write data, byte enables, memory scope, memory ordering, cache hint, atomic operation, source identity. Baseline response fields: rsp_valid, rsp_ready, transaction ID, read data, status/error, last. Parameters: `GPU_ADDR_W = 64`; default `GPU_MEM_DATA_W = 256` (configurable); initial transaction ID width ≈ 12 bits (configurable); outstanding-transaction capacity shall NOT be hard-coded around the initial TID width. Full signal/timing spec in MEM-001. | P0 | SIM | M8 |
| GPU-MEM-REQ-003 | MSHR-class request tracker allowing multiple outstanding loads/stores/atomics/misses with configurable depth. | P0 | SIM | M8–M10 |
| GPU-MEM-REQ-004 | Global fabric starts as crossbar, scales hierarchically; NoC for large configurations (packet fields: source, destination, transaction ID, address, op, byte-enable, data, response info; VC/arbitration/deadlock/flow-control studied). | P0 (xbar)/P2 (NoC) | SIM | M11/M16 |
| GPU-MEM-REQ-005 | Deadlock analysis documented for NoC, cache misses, barriers, command queues, memory requests, FIFOs. | P0 | REV | M11+ |
| GPU-MEM-REQ-006 | Arbiters specify fairness policy; starvation scenarios tested. | P0 | SIM/FRM | M6+ |
| GPU-MEM-REQ-007 | Resource-exhaustion behavior (full request tables, FIFOs, max wavefronts, max barriers) defined and tested. | P0 | SIM | M8+ |

### 12.14 Atomics (GPU-ATM)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-ATM-REQ-001 | Atomic add/sub/exchange/CAS/AND/OR/XOR/min/max on 32/64-bit integers, with scope/ordering attributes per MEM-001. | P1 | SIM | M15 |
| GPU-ATM-REQ-002 | FP32 (and potentially FP64) atomic add may be supported; ordering semantics defined in the memory model. | P2 | SIM | study |

### 12.15 Front End: Command Processor, Queues, Dispatch (GPU-FE)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-FE-REQ-001 | Hardware command processor executes: NOP, initialize, memory copy, memory fill, launch kernel, barrier, cache control, synchronization, performance query, debug operation. Software-equivalent dispatch exists in the ISA simulator from M1. | P1 | SIM | M17 |
| GPU-FE-REQ-002 | Commands reside in host-visible ring buffers/queues with head/tail/descriptors/completion; multiple queues and priorities P2. | P1 | SIM | M17 |
| GPU-FE-REQ-003 | Kernel launch descriptor contains: entry address, grid dimensions, workgroup dimensions, argument address, scratch/shared-memory requirement, VGPR/SGPR requirements, execution flags. Defined at M1 (software), enforced in HW at M17. | P0 | SIM | M1/M17 |
| GPU-FE-REQ-004 | Workgroup distributor places workgroups fairly across CUs using occupancy, avoiding oversubscription, honoring scratch/register requirements. | P0 | SIM | M11–M12 |
| GPU-FE-REQ-005 | Occupancy calculator determines max resident workgroups from registers, scratchpad, wavefront slots, CU limits; occupancy counters exposed. | P1 | SIM | M12 |
| GPU-FE-REQ-006 | Command interfaces validate malformed descriptors, illegal addresses, invalid opcodes, privilege violations; rejection with defined faults. | P1 | SIM | M17 |

### 12.16 Host Interface, DMA, Interrupts (GPU-HIF)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-HIF-REQ-001 | Generic host/command interface supports initialization, memory allocation, command queues, kernel submission, completion, DMA, interrupts, performance counters; simulation form from M1–M4; AXI4/AXI4-Lite/AXI4-Stream wrappers at M19+ isolated in `platform/amd/`. | P0 | SIM/HW | M1–M21 |
| GPU-HIF-REQ-002 | DMA engine supports H2D/D2H/D2D, scatter-gather descriptors, multiple outstanding transactions, interrupt (coalescing). | P1 | SIM/HW | M17 |
| GPU-HIF-REQ-003 | Interrupt sources: command completion, kernel completion, DMA completion, fault, memory error, watchdog, debug trap — status/mask/clear architecture. | P1 | SIM/HW | M17 |
| GPU-HIF-REQ-004 | Versioned register map groups: identification, control, command queues, DMA, interrupts, faults, performance, debug, memory management. | P0 | INS | M17 |
| GPU-HIF-REQ-005 | Simulation host driver lets the real runtime talk to the simulated GPU; RTL cosimulation via simulated MMIO possible. | P1 | SIM | M18 |
| GPU-HIF-REQ-006 | Driver/runtime errors human-readable, not bare numeric codes. | P1 | INS | M18+ |

### 12.17 Debug, Trace, Performance Counters (GPU-DBG)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-DBG-REQ-001 | Debug infrastructure supports halting the GPU, inspecting wavefront state (PC, active mask, registers), memory, command trace, fault trace; single-step where practical. | P1 | SIM | M12+ |
| GPU-DBG-REQ-002 | Configurable trace units cover instructions, memory transactions, cache events, scheduler events, stalls, commands, faults; disabled by default in production configurations. | P1 | SIM | M12+ |
| GPU-DBG-REQ-003 | Performance counters include at least: total cycles, instructions, active lanes, issued/stalled wavefronts, FP ops, INT ops, FP64 ops, matrix ops, loads/stores, cache hits/misses, shared-memory conflicts, register-bank conflicts, branch divergence, NoC traffic, DRAM transactions. Basic counters from M4; full set by M12. | P0 | SIM | M4–M12 |
| GPU-DBG-REQ-004 | Profiling API (`sgpu_profiler_start/stop/read`) exposes counters through software. | P1 | SIM | M18 |
| GPU-DBG-REQ-005 | Every bitstream/build exposes a build/git identifier. | P0 | INS | M17+ |

### 12.18 Reliability, Security, Power (GPU-RAS)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-RAS-REQ-001 | **ECC/RAS baseline (resolved):** register file parity initially (full SECDED optional for HPC); shared memory SECDED for scientific/HPC configurations; L2 SECDED; command/control memories SECDED or parity per storage width/criticality; control FSM/state parity or redundant encoding where justified. Error-injection capability for verification required wherever protection is implemented. | P1 | SIM | G3+ |
| GPU-RAS-REQ-002 | RAS features: correctable-error counters, uncorrectable-error counters, fault location, timestamp/event records where practical, poison propagation where appropriate, watchdogs, fatal/nonfatal classification. | P1 | SIM | G3+ |
| GPU-RAS-REQ-003 | Future address windows / per-context bounds / IOMMU integration architecturally possible. | P2 | REV | G5+ |
| GPU-RAS-REQ-004 | Multi-context, preemption, multi-GPU architecturally possible, not implemented initially. | P2 | REV | TBD |
| GPU-RAS-REQ-005 | Power opportunities (clock gating, inactive CU/lane/memory gating) identified per block using FPGA-appropriate techniques. | P1 | ANA | M19+ |
| GPU-RAS-REQ-006 | Every CDC classified (level/pulse/handshake/FIFO/Gray) and reviewed. | P0 | REV | whenever >1 clock |

### 12.19 Software Stack (GPU-SW)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-SW-REQ-001 | ISA simulator (golden functional model; C++ or Python) executes kernels, modeling threads, wavefronts, registers, memory, divergence, barriers, with error reporting. | P0 | SIM | M1 |
| GPU-SW-REQ-002 | Cycle-approximate performance model covers pipeline latency, scheduling, memory latency, caches, bank conflicts, NoC, DRAM bandwidth. | P1 | ANA | M10+ |
| GPU-SW-REQ-003 | Assembler (`.gpuasm` → SGP1) and disassembler per GPU-ISA-REQ-013/014. | P0 | SIM | M1–M2 |
| GPU-SW-REQ-004 | Compiler path progresses: hand assembly → assembler macros → simple C-like kernel compiler → optional LLVM backend. No CUDA/OpenCL compatibility claims. | P1 | SIM | M18+ |
| GPU-SW-REQ-005 | Kernel ABI specifies scalar/pointer argument passing (SGPR initialization), per-work-item identity (VGPR initialization: local/global IDs), workgroup dimensions, constant buffers, shared memory, completion. | P0 | REV/SIM | M4 |
| GPU-SW-REQ-006 | Runtime `libscigpu`: init, device open, alloc/free, memcpy H2D/D2H/D2D, module load (SGP1), kernel get/launch, wait, sync, close. | P1 | SIM | M18 |
| GPU-SW-REQ-007 | Vitis 2025.2 bare-metal driver (`drivers/scigpu/`: scigpu.c/h, scigpu_hw.h, selftest, interrupts, docs) supporting init, register access, DMA, interrupts, command submission, reset, error handling, performance monitoring. | P1 | HW | M21 |
| GPU-SW-REQ-008 | Linux driver (character device `/dev/scigpu0`, mmap, ioctl, DMA buffer management, interrupts, command queues), developed independently; platform IOMMU used when available. | P2 | HW | M22 |
| GPU-SW-REQ-009 | Memory allocation API supports device, host-pinned, shared, DMA buffers with defined alignment. | P1 | SIM | M18 |
| GPU-SW-REQ-010 | Benchmark suite maintained: vector add, SAXPY, DAXPY, DOT, reduction, GEMV, GEMM, transpose, histogram, prefix sum, FFT, stencil, N-body, Monte Carlo. | P1 | SIM | M8+ |
| GPU-SW-REQ-011 | BLAS-class primitives (AXPY/DOT/NRM2/SCAL/GEMV/GEMM) and `libscigpu_math` follow architecture stabilization. | P2 | SIM | G4 |
| GPU-SW-REQ-012 | Optional deterministic execution mode controlling scheduling/reduction order/atomics where possible, limitations documented. | P1 | SIM | G3 |
| GPU-SW-REQ-013 | Vitis applications: gpu_info, gpu_selftest, gpu_memtest, gpu_vector_add, gpu_saxpy, gpu_gemm, gpu_benchmark, plus performance reporting tool. | P1 | HW | M21 |

### 12.20 Verification and Quality (GPU-VER)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-VER-REQ-001 | Every hardware block has: specification, reference model, directed tests, randomized tests, assertions, corner cases, coverage targets, regression inclusion. | P0 | REV/SIM | continuous |
| GPU-VER-REQ-002 | Unit testbenches exist at each block's milestone, including tb_integer_alu, tb_fp32_add, tb_fp32_mul, tb_fp32_fma, tb_fp64_fma, tb_register_file, tb_operand_collector, tb_scoreboard, tb_wavefront_scheduler, tb_shared_memory, tb_l1_cache, tb_l2_cache, tb_coalescer, tb_compute_unit, tb_command_processor, tb_mma, tb_divsqrt. | P0 | SIM | per block |
| GPU-VER-REQ-003 | Arithmetic RTL differentially verified against Python/C++/SoftFloat-oracle references (oracle usage per C-07) over millions of randomized inputs where practical. | P0 | SIM | M7/M14 |
| GPU-VER-REQ-004 | FP corner suites cover ±0, infinities, NaNs, subnormals, smallest normal, largest finite, overflow, underflow, cancellation, rounding boundaries. | P0 | SIM | M7/M14 |
| GPU-VER-REQ-005 | Assertions check ARCH-001 invariants (ARCH-INV-*) plus FIFO over/underflow, response-only-for-request, wavefront-state consistency, scoreboard invariants, transaction lifetime, no duplicate completion. | P0 | SIM/FRM | M3+ |
| GPU-VER-REQ-006 | Formal verification applied selectively: FIFOs, arbiters, scoreboards, handshakes, command queues, cache control, ordering logic, divergence stacks. | P1 | FRM | M6+ |
| GPU-VER-REQ-007 | Coverage plan tracks functional, assertion, code coverage where available. | P1 | INS | M6+ |
| GPU-VER-REQ-008 | System tests execute kernels end-to-end (assembler → runtime → command path → GPU → memory → completion) against CPU references. | P0 | SIM | per milestone |
| GPU-VER-REQ-009 | One-command regression (`make regression`) runs unit/ISA/subsystem/integration tests; nonzero on failure. | P0 | INS | M2 |
| GPU-VER-REQ-010 | Optional CI covers lint, compile, unit tests, regression, documentation checks. | P2 | INS | study |
| GPU-VER-REQ-011 | Stress tests (long randomized mixed workloads) and fault injection (memory error, malformed command, invalid opcode, timeout, unexpected response) verify controlled recovery; ECC error injection wherever ECC implemented. | P1 | SIM | G3 |
| GPU-VER-REQ-012 | FP64 has an independent exhaustive/randomized verification strategy. | P0 | SIM | M14 |
| GPU-VER-REQ-013 | Numerical results reported as exact equality, absolute error, relative error, and/or ULP as appropriate. | P0 | SIM | M7+ |
| GPU-VER-REQ-014 | Failed tests never weakened to pass; root cause identified and recorded. | P0 | REV | continuous |
| GPU-VER-REQ-015 | No result claimed passed/succeeded/closed without stored tool evidence; evidence under `reports/evidence/`. | P0 | REV | continuous |
| GPU-VER-REQ-016 | Verification status matrix (requirement → test → result → evidence) maintained. | P0 | INS | M2+ |
| GPU-VER-REQ-017 | Milestone review gates verify requirements, architecture, tests, RTL, regressions, documentation before advancing; milestone reports produced. | P0 | REV | per milestone |

### 12.21 FPGA Implementation (GPU-FPGA)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-FPGA-REQ-001 | GPU core remains vendor-neutral; AXI4/AXI4-Lite/AXI4-Stream, DDR/HBM, PCIe, reset, clock wrappers isolated under `platform/amd/`. | P0 | INS | M19 |
| GPU-FPGA-REQ-002 | **Staged board hierarchy (ADR-009)** governs targets: FPGA-A small bring-up (may reuse an available ZC702-class 7-series board if convenient; does NOT define the architecture); FPGA-B reference embedded target ZCU104-class Zynq UltraScale+ (PS/PL, AXI, Vitis bare-metal, interrupts, DMA); FPGA-C/D primary high-performance reference AMD Alveo U55C (multi-CU, larger SIMD, HBM experiments, coalescing/L2 slicing/NoC studies, PCIe host characterization). Equivalent/better boards may substitute on availability. Architecture remains portable to future Versal/HBM platforms. BOARD_SELECTION.md reduces to procurement confirmation (availability/pricing) before purchase — not an architecture blocker. | P0 | ANA | pre-M19 |
| GPU-FPGA-REQ-003 | FPGA stages FPGA-A → B → C → D each pass all prior regressions. | P0 | HW | M19–M20+ |
| GPU-FPGA-REQ-004 | Vivado 2025.2 projects recreated from source-controlled Tcl/scripts; GUI-only state prohibited. | P0 | INS | M19 |
| GPU-FPGA-REQ-005 | Hardware handoff records target, bitstream, XSA, address map, interrupt map, clock frequencies, GPU configuration. | P0 | INS | M20–M21 |
| GPU-FPGA-REQ-006 | Implementation metrics (LUT, LUTRAM, FF, BRAM, URAM, DSP, BUFG, congestion, WNS, TNS, Fmax, estimated power) recorded including negative results. | P0 | INS | M19+ |
| GPU-FPGA-REQ-007 | Critical timing paths documented; pipeline changes analyzed for ISA/scheduler/scoreboard impact before adoption. | P0 | ANA | M19+ |
| GPU-FPGA-REQ-008 | Generic RTL infers RAMs, multipliers/DSP mapping, FIFOs; platform-specific optimization confined to wrappers. | P0 | INS | M19 |
| GPU-FPGA-REQ-009 | Bring-up proceeds progressively: JTAG → clock/reset → AXI registers → memory → DMA → command processor → single instruction → kernel → benchmark. | P0 | HW | M20 |
| GPU-FPGA-REQ-010 | Tiny FPGA-emulation configuration exists for RTL verification without changing architecture semantics. | P0 | SIM | M19 |
| GPU-FPGA-REQ-011 | FPGA-vs-ASIC limitations (register density, RAM ports, interconnect, frequency, power, FP64 cost, NoC routing) documented; FPGA results are not ASIC predictions. | P1 | REV | M19+ |
| GPU-FPGA-REQ-012 | **Planning clock targets** (synthesis goals, never semantic modifiers; achieved frequencies claimed only with synthesis/implementation evidence): small 7-series ≈150 MHz; Zynq UltraScale+ ≈200 MHz; Alveo U55C 250 MHz baseline, 300 MHz stretch. | P1 | INS | M19+ |

### 12.22 Documentation and Process (GPU-DOC)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-DOC-REQ-001 | Mission-defined document set (SPEC-000 … RAS-001) produced and maintained. | P0 | REV | staged |
| GPU-DOC-REQ-002 | Every major architectural choice has an ADR (context, decision, alternatives considered, why rejected, positive/negative consequences, FPGA consequences, ASIC consequences, compiler consequences, verification consequences, future reconsideration trigger). ADR-001…ADR-010 record the G0-SPEC decisions. | P0 | REV | per decision |
| GPU-DOC-REQ-003 | Every requirement has a unique ID traced requirement → architecture → RTL → test → result. | P0 | INS | continuous |
| GPU-DOC-REQ-004 | Unknowns marked TBD/TBC with need, temporary assumption, impact, resolution method; registered in OPEN_ISSUES.md. | P0 | REV | continuous |
| GPU-DOC-REQ-005 | PROJECT_MAP.md, CURRENT_WORK.md, OPEN_ISSUES.md maintained. | P0 | INS | M0+ |
| GPU-DOC-REQ-006 | Verification status and performance status matrices maintained. | P0 | INS | M2+ |
| GPU-DOC-REQ-007 | User documentation suite produced for productization. | P1/P2 | REV | G4 |
| GPU-DOC-REQ-008 | Developer documentation (adding instructions/units/lanes/CUs/cache/registers/ABI/driver features, running regressions, debugging failures) maintained. | P1 | REV | G3+ |
| GPU-DOC-REQ-009 | THIRD_PARTY.md and LICENSE.md maintained: third-party name, version, source, license, exact purpose, vendored vs consulted status. Original work proprietary (C-07, ADR-010). | P0 | REV | continuous |
| GPU-DOC-REQ-010 | Literature review maintained and cited in ADRs. | P1 | REV | continuous |
| GPU-DOC-REQ-011 | Design reviews at major decisions cover strengths, weaknesses, alternatives, resource/performance/verification/software impact. | P0 | REV | per decision |
| GPU-DOC-REQ-012 | Repository structure per mission §104; independent versioning of ISA, RTL, command ABI, kernel ABI, runtime API, driver ABI, register ABI with documented compatibility policy. | P0 | INS | M0+ |
| GPU-DOC-REQ-013 | Git usage: meaningful commits, feature branches, milestone tags; no deletion of prior work without checkpoint/justification. Canonical repository name `scigpu` (current filesystem path retained; controlled rename permitted at a clean checkpoint). | P0 | INS | continuous |
| GPU-DOC-REQ-014 | Specifications are the source of truth; conflicts raised, never silently resolved. If analysis proves an approved decision physically impossible, an architecture issue is recorded with evidence rather than silent change. | P0 | REV | continuous |

### 12.23 Performance Engineering (GPU-PERF)

| ID | Requirement | Pri | Verify | M |
|---|---|---|---|---|
| GPU-PERF-REQ-001 | Every configuration publishes a theoretical throughput model: peak FP32/FP64 FLOP/s = CUs × SIMD_LANES × ops/lane/cycle × frequency (execution-beat aware); peak MMA throughput from tile rate; peak memory bandwidth from transport/board; plus arithmetic-intensity thresholds separating compute-bound from memory-bound operation. | P0 | ANA | M8+ |
| GPU-PERF-REQ-002 | Roofline analysis produced for benchmark kernels; performance classified compute-, memory-, or latency-bound. | P1 | ANA | M10+ |
| GPU-PERF-REQ-003 | For every major configuration, measured frequency, issue/IPC metrics, active-lane utilization, FLOP/s (FP32/FP64), MMA throughput, memory/cache bandwidth, hit rates, latency, occupancy recorded. | P0 | SIM/ANA | M8+ |
| GPU-PERF-REQ-004 | Performance regressions tracked across commits; silent degradation prohibited. | P0 | INS | M8+ |
| GPU-PERF-REQ-005 | Correctness tests and throughput/stress tests separated. | P0 | REV | M8+ |
| GPU-PERF-REQ-006 | **Preliminary efficiency objectives (engineering goals; refined by PERF-001 roofline analysis; failure is analyzed and recorded, not automatically a functional failure):** compute microbenchmarks ≥80% of configuration theoretical arithmetic peak after warm-up; appropriately tiled compute-bound GEMM ≥70% of theoretical MMA-engine peak after optimization; simple sequential streaming ≥70% of measured usable board memory bandwidth (not vendor-theoretical); scheduler ≥85% issue utilization with ≥4 ready wavefronts and no external blocking resource where architecture permits; ≥95% active-lane utilization for branch-free full-wavefront kernels. Absolute TFLOP/s targets are NOT invented before synthesis/hardware baselines exist. | P0 | ANA/SIM | M10/M14/M19 |
| GPU-PERF-REQ-007 | Scientific comparisons vs CPUs state CPU model, compiler, precision, data size, FPGA configuration, clocks. | P1 | REV | M19+ |
| GPU-PERF-REQ-008 | Scaling modeled as CUs × SIMD_LANES × ops/cycle × frequency, derated by scheduler utilization, memory stalls, divergence, cache misses, dependencies. | P0 | ANA | M10+ |
| GPU-PERF-REQ-009 | Bandwidth modeled as channels × bus width × transfer rate; effective bandwidth measured. | P0 | ANA/SIM | M10+ |

## 13. Precision and Generations

### 13.1 Numerical Policy

- IEEE 754-2019 semantics are the FP reference; compliance claims gated by GPU-FP-REQ-011 and
  GPU-VER-REQ-003/004/012.
- FP64 is first-class: profile throughput ratios per ADR-005 (MINIMAL omit-or≈1:8; MEDIUM 1:4;
  LARGE 1:2; HPC 1:2 default / 1:1 option); true-fused FP64 FMA eventually mandatory.
- Approximate mathematics (SFU, fast-math) publish error bounds; precise/approximate classes are
  ISA-distinguishable.
- Deterministic numerics: reduction order and atomics nondeterminism documentable and, where
  possible, controllable (GPU-SW-REQ-012).

### 13.2 Product Generations

| Gen | Name | Milestones | Theme |
|---|---|---|---|
| G1 | Scalar/SIMD bring-up | M0–M8 | ISA, simulator, scalar → SIMD, FP32, first memory path |
| G2 | Memory & locality | M9–M12 | Shared memory, coalescing hardening, caches, multi-CU, INT64, global dispatcher |
| G3 | Scale & specialization | M13–M17 | MMA engine, FP64, atomics/barriers, NoC, command processor/DMA |
| G4 | Productization | M18–M23 | Software stack, FPGA, drivers, libraries, HPC optimization |
| G5 | Virtual memory & beyond | post-G4 | GPU MMU/TLB/ASID/page faults/migration; IOMMU integration; contexts |

## 14. Milestones and Gates

### 14.1 Gate Model

```
G0-SPEC  (THIS document approved)      → authorizes ARCHITECTURE DERIVATION only
   └─ derive: ARCH-001, ISA-001, EXEC-001, MEM-001, PERF-001, SW-001, VER-001,
              FPGA-001, ROADMAP-001
G0-ARCH (complete baseline + ARCHITECTURE_BASELINE_REVIEW approved) → authorizes GPU RTL
```

### 14.2 Milestone Sequence

| M | Name | Exit criterion (summary) |
|---|---|---|
| M0 | Requirements & architecture | G0-SPEC then G0-ARCH complete; no GPU RTL before G0-ARCH |
| M1 | ISA simulator | Golden model runs simple kernels; assembler/disassembler skeleton; ISA v1 frozen for G1 subset |
| M2 | Scalar prototype | One lane (SGPR path acceptable pre-scalardatapath note: scalar *unit* formalized M6–M7; M2 uses minimal uniform handling) executes programs via RTL + regression harness |
| M3 | SIMD engine | Multi-lane execution with masking; SIMD_LANES folding exercised (≥2 widths) |
| M4 | Wavefront scheduler | Multiple resident wavefronts; deterministic RR scheduling; basic counters |
| M5 | Divergence | Mask-stack + reconvergence-target suite passes incl. overflow/underflow faults |
| M6 | Register file + scoreboard + operand collector | Dependency-correct execution; lane-striped banked RF; SGPR file present |
| M7 | Scalar datapath integrated | Scalar ALU/branch path live alongside vector path |
| M8 | Load/store + coalescing | Memory path with coalescer, MSHR-class tracker, transport per GPU-MEM-REQ-002 |
| M9 | Shared memory | Banked 32×32-bit scratchpad; barrier semantics modeled |
| M10 | Cache hierarchy | L1-I/L1-D/L2 with documented coherence policy; 64-byte lines |
| M11 | Multiple CUs | Multi-CU execution via fabric |
| M12 | Global dispatcher | Workgroup distribution + occupancy calculator |
| M13 | MMA engine | 8×8×8 micro-tile ops; dot products; software tiling demonstrated |
| M14 | FP64 | FP64 pipelines differentially verified; profile ratios measurable |
| M15 | Atomics & barriers | HW barriers + scoped atomic RMW |
| M16 | NoC | Packet fabric for large configs |
| M17 | Command processor/DMA | HW front end, queues, interrupts, watchdog, register map v1 |
| M18 | Runtime/assembler/compiler | libscigpu + toolchain on simulator; cosim host path |
| M19 | FPGA synthesis | FPGA-A implements with recorded metrics |
| M20 | FPGA bring-up | Staged hardware validation |
| M21 | Vitis driver | Bare-metal stack + applications on hardware |
| M22 | Linux driver/runtime | Host OS stack |
| M23 | HPC optimization | Library/kernel optimization against rooflines |

### 14.3 FPGA Stages

| Stage | Board class | Purpose |
|---|---|---|
| FPGA-A | ZC702-class 7-series (or conveniently available board) | Small RTL bring-up: tiny SIMD_LANES, small RF, basic DDR access. Does NOT define architecture. |
| FPGA-B | ZCU104-class Zynq UltraScale+ | Reference embedded development: PS/PL, AXI, Vitis bare-metal driver, interrupts, DMA, small/medium config. Equivalents substitutable. |
| FPGA-C/D | AMD Alveo U55C | Primary large scientific reference: multiple CUs, larger SIMD_LANES, HBM experiments, coalescing/L2-slicing/NoC studies, PCIe host, performance characterization. Portable forward to Versal/HBM. |

## 15. Resolved Baseline Decisions and Non-Blocking Studies

### 15.1 Resolved Decisions (approved at G0-SPEC; ADR references normative)

| Decision | Value | Record |
|---|---|---|
| Architectural wavefront size | WAVEFRONT_SIZE = 32, ISA v1 fixed; Wave64 excluded | ADR-001 |
| Physical execution width | SIMD_LANES ∈ {4,8,16,32}; beats = 32/SIMD_LANES | ADR-001 |
| Terminology | Grid/Workgroup/Work-item/Wavefront/Lane/CU/Compute Cluster/VGPR/SGPR/SIMT; "warp" only in cross-architecture comparison | Directive; §5 |
| ISA encoding | 64-bit fixed LE + optional single extension word; no compression ISA v1 | GPU-ISA-REQ-002 |
| Scalar datapath | Mandatory; incorporated ~M6–M7 | ADR-007 |
| Register file | Lane-striped banked VGPR + SGPR file; 2R+1W logical; operand collector | ADR-002 |
| Scoreboard | Per-wavefront register granularity; RAW blocks; no renaming G1 | ADR-004 |
| FP64 ratios | MINIMAL omit/≈1:8; MEDIUM 1:4; LARGE 1:2; HPC 1:2 default, 1:1 option | ADR-005 |
| Matrix engine | Native 8×8×8 MMA; FP16/BF16→FP32, INT8→INT32; software tiling above; no TF32 ISA v1 | ADR-006 |
| Cache line | 64 bytes (L1/L2 baseline) | ADR-003 |
| L1-D | ~32 KiB medium/large, set-assoc, 4-way-capable | §11, CACHE-001 |
| L1-I | Separate; 8–16 KiB/CU-or-cluster | §11, CACHE-001 |
| L2 slices | {1,2,4,8,16} power-of-two; XOR hash of line address bits | §11; CACHE-001 tunes bits |
| Shared memory | 16/64/64/64(→128) KiB; 32 banks × 32-bit, 4-byte granularity | §11 |
| Memory transport | Vendor-neutral req/rsp; GPU_ADDR_W=64; GPU_MEM_DATA_W=256 default; TID≈12b configurable | ADR-008 |
| Memory model | Scoped (wavefront/workgroup/device); relaxed plain + acquire/release + fences + barriers | MEM-001 |
| Divergence | HW active-mask stack (default 32 entries, configurable) + compiler reconvergence targets; overflow/underflow fault | EXEC-001 |
| Collectives | Reserved opcode range; data-movement network must not preclude | GPU-ISA-REQ-017 |
| ECC/RAS | RF parity (SECDED opt HPC); SMEM SECDED (sci/HPC); L2 SECDED; cmd mem SECDED/parity; injection capability | GPU-RAS-REQ-001/002 |
| Licensing | Proprietary/internal, all rights reserved | ADR-010 |
| Kernel container | SGP1, magic `SGP1`, LE, 64-bit offsets | GPU-ISA-REQ-014 |
| Addressing | 64-bit; physical/IOVA G1–G4; MMU=G5 | GPU-CACHE-REQ-006 |
| Clock planning | 7-series ≈150 MHz; ZUS+ ≈200 MHz; U55C 250 base/300 stretch; evidence-gated claims | GPU-FPGA-REQ-012 |
| FPGA hierarchy | A=ZC702-class; B=ZCU104-class; C/D=Alveo U55C | ADR-009 |
| Efficiency objectives | ≥80% compute peak; ≥70% GEMM MMA peak; ≥70% usable BW streaming; ≥85% scheduler issue; ≥95% active lanes | GPU-PERF-REQ-006 |
| Simulator authority | Verilator primary normative; Icarus non-blocking; Vivado authority M19+ | C-03 |
| Repository | canonical `scigpu`; current path retained until clean-checkpoint rename | GPU-DOC-REQ-013 |

### 15.2 Configuration Parameters (tunable, non-semantic)

SIMD_LANES; NUM_CLUSTERS; CU_PER_CLUSTER; RESIDENT_WAVEFRONTS_PER_CU; VGPR_COUNT; SGPR_COUNT;
SHARED_MEM_BYTES; L1_D_SIZE; L1_I_SIZE; L2_SIZE; L2_SLICES; GPU_MEM_DATA_W; TID_WIDTH;
MAX_OUTSTANDING_MEM_REQ; MASK_STACK_DEPTH (default 32); FP64 ratio build option; MATRIX_UNITS.
Changing these never changes architectural results.

### 15.3 Explicitly Non-Blocking Future Studies (owned, not holes)

| Study | Owner doc | Why deferred | Evidence that will resolve it |
|---|---|---|---|
| Exact L2 XOR bit-selection map | CACHE-001 | Tuning; distribution measured best in simulation | Slice-conflict counters on benchmark traces (M10+) |
| L1-I size 8 vs 16 KiB per profile | MICRO-001 | Fetch-bandwidth vs BRAM budget | Miss-rate traces at M10 |
| TID width final value (>12b?) | MEM-001 | Must not hard-code structures; measure pressure | Outstanding-request histograms (M8+) |
| RF bank count / geometry / replication factor | REG-001 | Depends on measured port pressure | Bank-conflict counters, synthesis area (M6) |
| L1 replacement policy (pseudo-LRU default) | CACHE-001 | Policy choice; low risk | Hit-rate comparison (M10) |
| Precise div/sqrt algorithm (NR vs digit-recurrence) | FP-001 | Area/latency tradeoff | Synthesis + accuracy evidence (M9–M12) |
| Approx SFU polynomial/segment choices + ULP tables | FP-001 | Numerical analysis effort | Oracle campaigns (M13+) |
| Collective network topology | MICRO-001 | Not implemented G1–G2 | ISA reservation keeps space; design at G3 |
| NoC topology/VC count at scale | NOC-001 | Only needed M16 | Traffic models (M11+) |
| Watchdog default timeouts | CMD-001 | Deployment-dependent | Bring-up experience (M17+) |
| Queue count/priorities | CMD-001 | P2 feature | Use-case demand (post-M17) |
| Store buffer depth, L1 write policy confirmation | CACHE-001/MICRO-001 | µarch tuning | Stall traces (M10) |
| Dual-issue / greedy scheduling policies | SCHED-001 | P2; RR correct first | Scheduler utilization counters (M12+) |
| FP32/FP64 matrix extensions | ISA-001 (future rev) | Excluded ISA v1 by directive | Market/architecture need + DSP feasibility study |
| INT16/INT8 packed vector ISA | ISA-001 (future rev) | G3 study | Compiler demand evidence |
| Hyperbolic SFU functions | FP-001 | Justification pending | User-kernel profiling |

## 16. Risks (top-level, product view)

| ID | Risk | Impact | Mitigation |
|---|---|---|---|
| R-01 | FP64 cost on FPGA fabric (large LUT/FF cost; no native FP64 DSP) limits HPC profiles on affordable boards | High | Configurable ratio (ADR-005); Alveo U55C target for FPGA-C/D; ASIC-portable design; ratio omission legal for MINIMAL |
| R-02 | FP verification depth exceeds effort budget | High | SoftFloat-oracle differential testing, randomized campaigns, formal for control |
| R-03 | Register-file bandwidth on FPGA constrains issue rate | High | ADR-002 banking + operand collector + beat-time-multiplexing; REG-001 geometry study |
| R-04 | Tool semantic divergence (Verilator vs Vivado vs Icarus) causes false pass/fail | Medium | Common synthesizable subset; Verilator lint normative; cross-tool runs at milestones |
| R-05 | Board memory bandwidth starves compute on scientific kernels | Medium | Roofline honesty; shared-memory tiling; U55C HBM for FPGA-C/D |
| R-06 | Schedule risk from single-team breadth | Medium | Milestone gating, one-command regression, simulation-first |
| R-07 | Scope creep toward graphics/features | Medium | §4.3 non-goals enforced at gates |
| R-08 | Beat-folded execution (SIMD_LANES<32) subtly diverges from flat semantics | High | INV-based assertions; ISA simulator models beats identically; differential sim-vs-RTL per width |

## 17. Acceptance Criteria (architecture-level)

The design may be called a *modern scientific GPGPU architecture* only when all of the following
exist with recorded evidence. Until then it is a *developmental GPGPU* (§3).

| # | Capability | Target milestone |
|---|---|---|
| 1 | Programmable kernel execution | M2 |
| 2 | Scalable SIMT + per-lane masking + width folding | M3–M5 |
| 3 | Multiple resident wavefronts + hardware scheduling | M4 |
| 4 | Branch divergence/reconvergence | M5 |
| 5 | Register dependency management (scoreboard) | M6 |
| 6 | Vector integer arithmetic | M3–M9 |
| 7 | Scalar datapath | M6–M7 |
| 8 | FP32 + FMA | M7 |
| 9 | FP64 + FMA | M14 |
| 10 | Shared memory | M9 |
| 11 | Memory coalescing | M8 |
| 12 | Caching (L1/L2) | M10 |
| 13 | Atomics | M15 |
| 14 | Barriers | M9/M15 |
| 15 | Multiple compute units | M11 |
| 16 | Scalable memory fabric (+NoC) | M11/M16 |
| 17 | Matrix acceleration (8×8×8 MMA) | M13 |
| 18 | Command queues + DMA | M17 |
| 19 | Host runtime | M18 |
| 20 | Drivers (bare-metal; Linux later) | M21/M22 |
| 21 | Assembler/disassembler toolchain (SGP1) | M1–M2 |
| 22 | FPGA implementation | M19 |
| 23 | Hardware validation | M20–M21 |
| 24 | Numerical benchmarks with error reporting | M8+ |
| 25 | Performance counters | M4–M12 |

## 18. Requirement Traceability Model

```
SPEC-000 requirement ID
  → derived document section (ARCH/ISA/EXEC/MEM/PERF/SW/VER/FPGA/ROADMAP)
    → RTL module(s)            [only after G0-ARCH]
      → testbench/regression entry
        → evidence artifact in reports/evidence/
```

| Requirement group | Owning derived doc(s) | Primary verification |
|---|---|---|
| GPU-SYS | ARCH-001, VER-001 | SIM/INS |
| GPU-ISA | ISA-001 | SIM |
| GPU-INT | ISA-001, MICRO-001 | SIM |
| GPU-FP | FP-001, MICRO-001 | SIM (differential) |
| GPU-SFU | FP-001 | SIM |
| GPU-MAT | MICRO-001, ISA-001 | SIM |
| GPU-EXEC | EXEC-001, SCHED-001, MICRO-001 | SIM/FRM |
| GPU-REG | REG-001, MICRO-001 | SIM/ANA |
| GPU-LSU | MEM-001, MICRO-001 | SIM |
| GPU-SHM | MICRO-001, MEM-001 | SIM |
| GPU-CACHE | CACHE-001, MEM-001 | SIM |
| GPU-MEM | MEM-001, NOC-001 | SIM/REV |
| GPU-ATM | MEM-001 | SIM |
| GPU-FE | CMD-001, ARCH-001 | SIM |
| GPU-HIF | DRV-001, ARCH-001 | SIM/HW |
| GPU-DBG | DEBUG-001 | SIM/INS |
| GPU-RAS | RAS-001 | SIM/REV |
| GPU-SW | RT-001, SW-001, ABI-001, VITIS-001 | SIM/HW |
| GPU-VER | VER-001 | REV/INS |
| GPU-FPGA | FPGA-001, VITIS-001 | INS/HW |
| GPU-DOC | all | REV |
| GPU-PERF | PERF-001 | ANA/SIM |

Note: MICRO-001, SCHED-001, REG-001, FP-001, CACHE-001, NOC-001, CMD-001, ABI-001, DRV-001,
RT-001, DEBUG-001, RAS-001 are post-G0-ARCH derivations; ARCH-001 carries sufficient substance
for their later derivation.

## 19. References and Prior Art Policy

Legitimate public materials consulted for learning/validation only; usage tracked in
THIRD_PARTY.md; nothing proprietary is copied.

- IEEE Std 754-2019 — normative FP semantics reference.
- Berkeley SoftFloat 3e — independent FP oracle (software only; license per THIRD_PARTY.md).
- RISC-V unprivileged/Vector specifications — ISA design patterns.
- Lindholm et al., "NVIDIA Tesla: A Unified Graphics and Computing Architecture," IEEE Micro 2008 — public SIMT concepts.
- AMD GCN/CDNA public ISA guides — wavefront organization concepts (reference/comparison only).
- Khronos OpenCL/SPIR-V specifications — execution/ABI vocabulary; memory-scope concepts.
- Hennessy & Patterson, *Computer Architecture: A Quantitative Approach*.
- Dally & Towles, *Principles and Practices of Interconnection Networks*.
- Sorin, Hill, Wood, *A Primer on Memory Consistency and Cache Coherence* — memory model method.
- Verilator, cocotb, Icarus Verilog project documentation (open tools).

## 20. Approval Record

| Item | State |
|---|---|
| G0-SPEC review artifact | `reviews/G0_SPEC_REVIEW.md` |
| Review disposition | **PASS WITH NON-BLOCKING ACTIONS** (see artifact) |
| Approved by | Principal GPU Architect (directive authority), 2026-08-23 |
| Effect | SPEC-000 Rev 0.2 is the authoritative product-requirements baseline; derivation of ARCH-001 et al. authorized. **RTL remains unauthorized until G0-ARCH.** |
| G0-ARCH inputs | SPEC-000 (this), ARCH-001, ISA-001, EXEC-001, MEM-001, PERF-001, SW-001, VER-001, FPGA-001, ROADMAP-001, ARCHITECTURE_BASELINE_REVIEW |

*End of SPEC-000 Rev 0.2 — APPROVED at G0-SPEC.*
