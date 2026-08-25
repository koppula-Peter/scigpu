# THIRD_PARTY.md — External References Register

Policy (LICENSE.md / SPEC-000 §12.22 GPU-DOC-REQ-009): every external component or reference is
recorded with name, version, source, license, exact purpose, and whether code is **vendored**
or merely **consulted**. Nothing proprietary is copied. Original SciGPU work remains proprietary
(ADR-010).

Status legend: CONSULTED = ideas/literature only · ORACLE = executed as independent reference in
verification software · VENDORED = code copied into repository (requires explicit authorization).

| # | Name | Version | Source | License | Purpose | Status |
|---|---|---|---|---|---|---|
| 1 | IEEE Std 754-2019 | — | IEEE | Standard document (licensed access) | Normative FP semantics reference for FP-001/ISA-001 | CONSULTED |
| 2 | Berkeley SoftFloat | 3e | https://github.com/ucb-bar/berkeley-softfloat3 | Permissive custom BSD-style (see upstream `COPYING.txt`) | Independent FP oracle inside differential test harnesses only; never translated into RTL | ORACLE |
| 3 | RISC-V ISA specs (RV32/RV64/V) | Ratified | https://riscv.org/technical/specifications | CC-BY 4.0 / Apache 2.0 (spec text) | ISA design-pattern study (encodings, CSR style, extension model) | CONSULTED |
| 4 | Lindholm et al., "NVIDIA Tesla: A Unified Graphics and Computing Architecture" | IEEE Micro 2008 | publisher/public literature | Copyright IEEE (fair scholarly use) | Public SIMT architecture concepts; comparison context only | CONSULTED |
| 5 | AMD GCN/CDNA public ISA & CDN docs | various | AMD developer documentation | AMD proprietary docs, publicly available | Wavefront organization concepts; comparison only. No AMD text/code reused | CONSULTED |
| 6 | Khronos OpenCL / SPIR-V specifications | current | https://www.khronos.org/opencl/ , /spir-v/ | Khronos open spec license | Vocabulary: grid/workgroup/work-item, memory scopes, barrier semantics | CONSULTED |
| 7 | Sorin, Hill, Wood — *A Primer on Memory Consistency and Cache Coherence* | 2nd ed. | Morgan & Claypool | Copyrighted book | Memory-model methodology (litmus tests, scopes) | CONSULTED |
| 8 | Hennessy & Patterson — *Computer Architecture: A Quantitative Approach* | 6th ed. | Elsevier | Copyrighted book | Roofline method, quantitative analysis discipline | CONSULTED |
| 9 | Dally & Towles — *Principles and Practices of Interconnection Networks* | 2004 | Morgan Kaufmann | Copyrighted book | NoC/fabric concepts for M16+ | CONSULTED |
| 10 | Verilator | 5.x | https://github.com/verilator/verilator | LGPL-3.0 / Artistic-2.0 (tool) | Primary normative RTL simulator/linter (tool usage only, no linkage into deliverables) | TOOL |
| 11 | cocotb | 1.x/2.x | https://github.com/cocotb/cocotb | BSD-3-Clause (tool) | Python testbench framework (verification tooling) | TOOL |
| 12 | Icarus Verilog | 12.x | http://iverilog.icarus.com | GPL-2.0 (tool) | Compatible smoke/unit simulation where feasible (tool usage only) | TOOL |
| 13 | AMD Vivado / Vitis | 2025.2 | https://www.xilinx.com/support/download.html | AMD EULA | FPGA synthesis/implementation + embedded software (permitted use under EULA) | TOOL |
| 14 | mpmath | 1.x | https://mpmath.org | BSD-3-Clause | High-precision SFU accuracy oracle in Python verification models | ORACLE |

Rules:
1. Any new dependency must be added here before first use, with license compatibility checked
   against ADR-010 (proprietary original work).
2. Vendoring any third-party code requires explicit authorization and a `licenses/` snapshot.
3. Tools marked TOOL are used as tools; their licenses do not propagate to SciGPU originals.
