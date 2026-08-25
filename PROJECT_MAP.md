# PROJECT_MAP.md

Canonical project name: **SciGPU** · Canonical repository name: `scigpu`
(current filesystem path retained until a controlled clean-checkpoint rename — see OPEN_ISSUES.md history)

## Where to find things

| Area | Location | Status |
|---|---|---|
| Product requirements | `docs/requirements/SPEC-000_GPU_PRODUCT_REQUIREMENTS.md` | APPROVED (G0-SPEC) |
| System architecture | `docs/architecture/ARCH-001_GPU_SYSTEM_ARCHITECTURE.md` | Complete (G0-ARCH input) |
| ISA | `docs/isa/ISA-001_GPU_ISA_ARCHITECTURE.md` (+ SGP1 container, Appendix A) | Complete (G0-ARCH input) |
| SIMT execution model | `docs/execution/EXEC-001_SIMT_EXECUTION_MODEL.md` | Complete (G0-ARCH input) |
| Memory architecture + consistency | `docs/memory/MEM-001_GPU_MEMORY_ARCHITECTURE.md` | Complete (G0-ARCH input) |
| Performance model | `docs/performance/PERF-001_GPU_PERFORMANCE_MODEL.md` | Complete (G0-ARCH input) |
| Software stack | `docs/software/SW-001_GPU_SOFTWARE_STACK_ARCHITECTURE.md` | Complete (G0-ARCH input) |
| Verification master plan | `docs/verification/VER-001_GPU_VERIFICATION_MASTER_PLAN.md` | Complete (G0-ARCH input) |
| FPGA prototyping strategy | `docs/fpga/FPGA-001_FPGA_PROTOTYPING_STRATEGY.md` | Complete (G0-ARCH input) |
| Milestones | `docs/ROADMAP-001_GPU_ENGINEERING_MILESTONES.md` | Complete (G0-ARCH input) |
| Decision records | `docs/decisions/ADR-001..010_*.md` | Approved at G0-SPEC |
| **RTL (M2)** | `rtl/` — generated ISA pkg (`tools/gen_sv_isa.py`), scalar core `rtl/core/scigpu_scalar_core.sv`, top `rtl/top/scigpu_m2_top.sv` | APPROVED at M2 gate |
| Microarchitecture | `docs/microarchitecture/MICRO-001_COMPUTE_UNIT_MICROARCHITECTURE.md` | Rev 0.1 (M2 normative) |
| M2 verification | `verification/m2/` (TB, golden builder, random gen), `verification/unit/`, `verification/assertions/` | GREEN |
| Run all tests | `make regression` (M1+M2) · `make m2-regression` · `make generate` / `make check-generated` | GREEN |
| Evidence | `reports/evidence/` (m1_regression.log, m2/*) | Maintained |
| Verification status matrix | `VERIFICATION_STATUS.md` | Maintained |
| Reviews | `reviews/G0_SPEC_REVIEW.md`, `reviews/ARCH_001_SELF_REVIEW.md`, `reviews/M2_SCALAR_RTL_GATE_REVIEW.md`, `reviews/M3_MICROARCHITECTURE_REVIEW.md`, `reviews/M3_SIMD_ENGINE_GATE_REVIEW.md` | Recorded |
| Baseline review (G0-ARCH package) | `ARCHITECTURE_BASELINE_REVIEW.md` | Complete |
| Project state | `CURRENT_WORK.md` | Maintained |
| Open issues | `OPEN_ISSUES.md` | Maintained |
| Licensing | `LICENSE.md`, `THIRD_PARTY.md` | Maintained |

## Planned (created when work begins — do not pre-create empty trees)

`verification/` · `models/` · `assembler/` ·
`disassembler/` · `compiler/` · `runtime/` · `drivers/` · `libraries/` · `applications/` ·
`platform/simulation/`, `platform/amd/vivado_2025_2/` · `scripts/` · `tools/` · `regressions/` ·
`reports/evidence/`

## Gate model (never conflate)

- **G0-SPEC** — SPEC-000 approved → architecture derivation authorized. ✅ reached.
- **G0-ARCH ✅ ratified (principal directive, tag gpu-m0-architecture).
