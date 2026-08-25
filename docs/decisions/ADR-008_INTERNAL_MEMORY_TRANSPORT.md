# ADR-008 — Vendor-Neutral Internal Memory Transport

| Field | Value |
|---|---|
| ADR ID | ADR-008 |
| Status | APPROVED (G0-SPEC, 2026-08-23) |
| Supersedes | SPEC-000 R0.1 TBD-000-09 |
| Parent requirements | GPU-MEM-REQ-002/003, GPU-CACHE-REQ-006, GPU-FPGA-REQ-001 |

## Context

The memory subsystem spans LSU → coalescer → L1 → L2 slices → fabric → platform controller.
AXI inside compute-unit architectural logic would (a) entangle GPU ordering/scoping semantics
with a bus protocol, (b) leak vendor concepts into portable RTL, and (c) constrain future NoC
packet design. Conversely, inventing yet another *external* interface would burden FPGA
integration.

## Decision

Define an internal, vendor-neutral **request/response transport** used everywhere inside the GPU
core:

- Request: `req_valid`, `req_ready`, operation, 64-bit address, access size, transaction ID,
  burst/transaction length, write data, byte enables, memory scope, memory ordering, cache hint,
  atomic operation, source identity.
- Response: `rsp_valid`, `rsp_ready`, transaction ID, read data, status/error, last.
- Parameters: `GPU_ADDR_W = 64` (fixed architectural); default `GPU_MEM_DATA_W = 256`
  (configurable); initial TID width ≈ 12 bits (configurable). Outstanding-capacity structures
  must be parameterized, never hard-coded around the initial 12-bit width.
- Ordering/backpressure: valid/ready with no-loss/no-duplication/no-deadlock arguments per C-08;
  response-to-request matching is 1:1 by TID within a source (ARCH-INV-004).
- AXI translation exists only in `platform/amd/` wrappers. Full signal/timing normative spec:
  MEM-001.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| AXI4 throughout the core | 4-KB burst semantics, QoS/lock/region signals, and AxLEN rules don't express GPU scopes/ordering; forces awkward bridges at every CU; vendor lock-in of thought. |
| AXI-Lite for everything data | Far too low bandwidth. |
| Multiple bespoke point-to-point protocols per link | Verification explosion; no common MSHR/tracking story. |
| NoC packets as the base transport from day one | Premature; crossbar G1 needs something simpler that can be *encapsulated* by NoC later — this transport is that payload. |

## Positive Consequences

- Scope/ordering/hint fields ride with the request — the memory model (MEM-001) maps 1:1 onto
  wire semantics.
- Single protocol → single verification stack (assertions, formals, scoreboard models).
- NoC (M16) encapsulates these packets as payloads; L2 slicing sees identical transactions.

## Negative Consequences

- One more wrapper to write/maintain in `platform/amd/` (thin: field mapping + clocking).
- Custom protocol lacks ecosystem IP reuse *inside* the core — acceptable since core blocks are
  all first-party anyway.

## FPGA Consequences

Wrapper translates to AXI4/AXI4-Lite for PS/HP ports and to memory-controller streams; width
adaptation (256 b ↔ controller bus) localized there; HBM topology considerations stay in
platform layer, informing L2 slice count only through configuration.

## ASIC Consequences

Transport maps to AMBA or proprietary NoC at top level without touching core RTL.

## Compiler Consequences

None (invisible above ISA attributes).

## Verification Consequences

One protocol assertion library reused across all levels; formal properties on request/response
lifetime (no orphan responses, no lost requests under backpressure); TID exhaustion tests;
parameter sweeps over DATA_W/TID widths.

## Future Reconsideration Trigger

If G5 MMU introduces page-fault semantics needing new response classes, the transport gains an
extension field via its parameterization — changes are additive; full replacement would require
new ADR.
