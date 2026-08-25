# LICENSE.md

## SciGPU — Proprietary / Project Internal / All Rights Reserved

Copyright (c) 2026 the SciGPU project. **All rights reserved.**

Original SciGPU work — including all RTL, verification collateral, reference models, ISA and
architecture documentation, assembler/disassembler, runtime, drivers, benchmarks, and this
documentation set — is proprietary and internal to the project. No open-source license (BSD,
MIT, Apache, GPL, CERN-OHL, Creative Commons, or any other) is applied to original SciGPU work.
See ADR-010 for rationale: the project retains all commercial IP options.

Redistribution, publication, or use outside the project requires explicit written authorization
from the project principal.

### Third-party components

Third-party components used by the project keep their own license notices and obligations.
The authoritative register is [`THIRD_PARTY.md`](THIRD_PARTY.md). Notably:

- Berkeley SoftFloat 3e is used strictly as an independent software oracle inside verification
  harnesses; it is not vendored into SciGPU deliverables and its implementation is never
  translated into RTL.
- Verilator, cocotb, Icarus Verilog, Vivado, and Vitis are used as tools under their respective
  licenses/EULAs; tool licenses do not attach to SciGPU original work.

### Directory license map

| Path | Status |
|---|---|
| `rtl/`, `verification/`, `models/`, `assembler/`, `disassembler/`, `runtime/`, `drivers/`, `libraries/`, `applications/`, `platform/`, `scripts/`, `tools/` | Proprietary — All Rights Reserved |
| `docs/` | Proprietary — All Rights Reserved |
| `LICENSES/` | Snapshot copies of third-party notices only (created when/if anything is ever vendored) |
