# SW-001 — SciGPU Software Stack Architecture

| Field | Value |
|---|---|
| Document ID | SW-001 |
| Title | Software Stack: simulator, toolchain, ABI, runtime, drivers |
| Status | APPROVED — G0-ARCH BASELINE |
| Parent | SPEC-000 Rev 0.2 (GPU-SW-REQ-001..013); ISA-001 (ISA/SGP1); ARCH-001 §§6, 11 |

## Revision History

| Rev | Date | Author | Description |
|---|---|---|---|
| 1.0 | 2026-08-23 | Principal GPU Architect | Initial complete software-stack baseline |

---

## 1. Stack Overview

```
applications / benchmarks
        │
libscigpu.so  (runtime API)              ── M18+
        │
driver: bare-metal (Vitis, M21) | Linux (M22) | sim-host driver (M18)
        │
device: command queues → command processor → dispatcher → CUs
        ▲
toolchain: assembler/disassembler (M1–M2) · macros (M2+) · C-like compiler (M18+)
           · LLVM backend (study)
models:    ISA simulator = golden (M1) · cycle-approximate perf model (M10+)
```

## 2. ISA Simulator (golden functional model)

Language: C++ (primary) + Python harness. Executes SGP1 images against a flat memory model with
the MEM-001 semantics implemented per-lane serially for control flow (golden divergence
reference, EXEC-001 §9). Models: wavefronts of exactly 32 work-items; SGPR/VGPR/P files; mask
stack; barriers; atomics at simulated L2 point; window faults; fault codes identical to RTL.
Outputs final memory image + register dumps + trace JSON consumed by differential testers.
**The simulator is the normative architectural oracle for all RTL comparisons.**

## 3. Cycle-Approximate Performance Model

Event/cycle hybrid: pipeline latencies/IIs from MICRO/FP property tables; transport latency
distributions parameterized from board measurements when available; caches/banks/TIDs modeled at
resource-counter granularity. Calibrated against RTL PMC outputs before any published projection
(PERF-001 §6.5). Used for design-space studies only — never cited as achieved hardware results.

## 4. Assembler and Disassembler

Input `.gpuasm` per ISA-001 Appendix B grammar; output SGP1 (Appendix A). Features: labels,
constants (`EQU`), register/predicate symbols, directives (.reg/.kern/.args/.const/.align/
.feature), macro facility (Phase 2), diagnostics with line/column, feature-flag enforcement for
capability-gated opcodes. Disassembler consumes SGP1 → annotated listing (symbolic labels,
predicate/mask annotation). Both are deterministic builds (SPEC GPU-SYS-REQ-015) and run in CI
regression from M1–M2.

## 5. Kernel ABI (v1)

Launch hardware writes per wavefront:

| Region | Content |
|---|---|
| SGPR arg block s[0..k] | kernel arguments in declaration order: scalars packed 32/64 b; pointers as 64-bit device addresses (2 SGPRs); const-buf/shared args as base addresses |
| SGPR system aliases (fixed high indices) | grid dims, wg dims, wg id xyz, dispatch seq, device/cu/wf ids |
| VGPR startup regs v[ABI_START..] | v[lane]=lane_id(0..31); global_id.x/y/z per lane (32-bit components v1); local linear id; wg-local base |

Rules: work-item identity is ALWAYS per-lane VGPR data (never uniform — ADR-007 rule 4);
argument layout frozen per SGP1 format major; completion = queue record with seq_id + exit code
per wavefront group {OK, FAULT(code)}.

Shared-memory contract: `smem_req` bytes reserved contiguously per resident workgroup; private
regions carved by convention [wg_base + lane*priv_stride …]; kernels must initialize before
cross-lane reads (MEM-001 §5).

## 6. Runtime libscigpu (C API)

```c
sgpu_status sgpu_init(void);
sgpu_status sgpu_device_open(int index, sgpu_device_h*);
void*       sgpu_mem_alloc(sgpu_device_h, size_t, sgpu_mem_type_e /*device,pinned,shared,dma*/);
sgpu_status sgpu_mem_free(sgpu_device_h, void*);
sgpu_status sgpu_memcpy_h2d/d2h/d2d(sgpu_device_h, dst, src, size, stream);
sgpu_status sgpu_module_load(sgpu_device_h, const void* sgp1_image, size_t, sgpu_module_h*);
sgpu_status sgpu_kernel_get(sgpu_module_h, const char* name, sgpu_kernel_h*);
sgpu_status sgpu_kernel_launch(sgpu_device_h, sgpu_kernel_h, const sgpu_launch_params_t*, sgpu_event_h*);
sgpu_status sgpu_wait(sgpu_event_h, timeout);
sgpu_status sgpu_sync(sgpu_device_h);
sgpu_status sgpu_profiler_start/stop/read(...);
sgpu_status sgpu_get_error_string(sgpu_status, char*, size_t);   // human-readable (GPU-HIF-REQ-006)
sgpu_status sgpu_device_close(sgpu_device_h);
```
Capabilities queried from ID registers (never assumed — GPU-SYS-REQ-004). Deterministic-mode
flag propagates into launch descriptor flags.

## 7. Drivers

**Sim-host driver (M18)**: implements the same driver-facing interface as hardware drivers but
talks MMIO to the RTL simulation process (socket/shared-memory transport to a Verilator model
with the front-end registers mapped) — enabling full-stack cosim runs (GPU-HIF-REQ-005).

**Bare-metal Vitis driver (M21)** `drivers/scigpu/`: scigpu.c/h, scigpu_hw.h (register map
constants generated from the central config source), scigpu_selftest.c, scigpu_intr.c, docs.
Responsibilities: probe/init (reset→ID query→queue setup→IRQ enable), DMA descriptors,
command submission, watchdog config, error decode, PMC readout.

**Linux driver (M22)** `/dev/scigpu0`: character device, ioctl surface mirroring runtime needs,
mmap for pinned buffers, IRQ handling, platform-IOMMU where present (GPU-SW-REQ-008).

## 8. Compiler Path

Phases (SPEC GPU-SW-REQ-004): hand assembly → assembler macros (loop/unroll/launch boilerplate)
→ simple typed C-like kernel language ("scigpu-c": kernels, pointers address-spaced
global/shared/constant, restricted control flow mapping onto structured divergence) → optional
LLVM backend study (target description, ISel, RA over VGPR/SGPR classes, divergence lowering to
CBRANCH family, SGP1 emission). Uniform-value analysis pass feeds scalar vs vector selection
post-M7 (ADR-007). No CUDA/OpenCL compatibility claims.

## 9. Libraries & Benchmarks

libscigpu_math and BLAS-class primitives follow architecture stabilization (G4, SPEC
GPU-SW-REQ-011); benchmark suite structure per PERF-001 §7 with correctness references on host.

## 10. Versioning & Compatibility

Independent versions (SPEC GPU-DOC-REQ-012): ISA (major/minor in SGP1 + ID reg), command ABI
(queue descriptor fmt version), kernel ABI (SGP1 major), runtime API (soname), driver ABI,
register map version. Compatibility policy: minor = additive; breaking changes bump major and
require capability-bit negotiation.

*End of SW-001 Rev 1.0.*
