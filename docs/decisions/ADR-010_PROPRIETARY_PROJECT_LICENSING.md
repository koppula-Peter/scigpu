# ADR-010 — Proprietary Project Licensing

| Field | Value |
|---|---|
| ADR ID | ADR-010 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-16 (BSD-3-Clause/CC-BY proposal); OI-002 |
| Parent requirements | C-07, GPU-DOC-REQ-009, NG-04 |

## Context

SPEC R0.1 provisionally proposed permissive licensing (BSD-3-Clause code / CC-BY-4.0 docs).
The project's strategic intent is to retain **commercial IP options** over an original,
independently designed GPU architecture — core RTL, ISA, software stack, and documentation.
Early permissive publication would irrevocably dilute those options.

## Decision

All original SciGPU work is **PROPRIETARY / PROJECT INTERNAL / ALL RIGHTS RESERVED**:

- No BSD/MIT/Apache/GPL/CERN-OHL/Creative Commons license is applied to original SciGPU RTL,
  software, or documentation absent explicit future authorization.
- `LICENSE.md` states internal proprietary status and the directory license map.
- Third-party components keep their individual notices; `THIRD_PARTY.md` records name, version,
  source, license, exact purpose, vendored-vs-consulted status for every external item.
- Berkeley SoftFloat 3e may be used as an independent software/reference oracle subject to its
  own notice; it shall **not** be translated into RTL nor vendored without separate justification.

## Alternatives Considered

| Alternative | Why rejected (for now) |
|---|---|
| BSD-3-Clause / MIT everything | Forfeits commercial exclusivity permanently at the moment of first push to a public remote. |
| Apache-2.0 with patent grant | Same IP-dilution problem plus patent-grant breadth inappropriate while patent strategy is undecided. |
| GPL family | Copyleft obligations would contaminate future commercial dual-track options. |
| CERN-OHL-HW | Hardware reciprocity incompatible with retained-options goal. |
| CC-BY for docs + proprietary code | Split regime adds management burden now; docs can be relicensed later if a release strategy emerges. |
| Dual-license "later" | Only possible today by *not* licensing openly now; this decision does exactly that. |

## Positive Consequences

- All commercial paths remain open (proprietary product, dual licensing, acquisition, patent
  filings) — nothing is given away prematurely.
- Clean provenance: THIRD_PARTY.md discipline keeps contamination risk near zero.

## Negative Consequences

- Cannot accept external contributions under standard open workflows until a licensing strategy
  changes; collaboration happens inside the project.
- Community goodwill/ecosystem effects of open-sourcing are forgone for now.

## FPGA Consequences

None. Bitstreams built from proprietary sources are governed by the same status.

## ASIC Consequences

Strengthens future patent/trade-secret posture; no license hygiene blockers to tapeout partners.

## Compiler Consequences

Toolchain binaries distributed (if ever) under future explicit terms only; tool dependencies
(Verilator/cocotb/Icarus) are used as unmodified tools so their licenses never attach to
SciGPU originals.

## Verification Consequences

Verification collateral inherits proprietary status; third-party oracles (SoftFloat/mpmath)
execute as separate processes/software with notices preserved in THIRD_PARTY.md.

## Future Reconsideration Trigger

A deliberate commercialization decision (product ship, public reference, community program) may
open a new ADR selecting per-file or whole-repo licensing; until then any external exposure of
original work requires principal authorization recorded here as an amendment.
