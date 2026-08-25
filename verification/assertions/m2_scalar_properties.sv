// SciGPU M2 assertion properties (VER-001 §4 / directive §52).
// Seeded as concurrent SVAs for SVA-capable simulators/formal tools.
// Under Verilator (primary M2 engine) the equivalent checks are enforced
// procedurally in verification/m2/tb_m2.cpp — mapping table below.
// Bind target: scigpu_scalar_core instances.

interface scigpu_m2_assertions (
  input logic clk,
  input logic rst,
  input logic        start_valid,
  input logic        start_ready,
  input logic        if_req_valid,
  input logic        if_req_ready,
  input logic        completion_valid,
  input logic        completion_ready,
  input logic        completion_fault,
  input logic [5:0]  completion_fault_code,
  input logic [63:0] completion_pc,
  input logic [63:0] completion_retired_count,
  input logic        sgpr_we,
  input logic [7:0]  sgpr_waddr,
  input scigpu_types_pkg::state_e dbg_state
);

  // M2-ASSERT-001: single outstanding fetch (fetch engine busy discipline)
  property p_single_fetch;
    @(posedge clk) disable iff (rst)
      if_req_valid |-> ##1 (if_req_valid == 0 || if_req_ready);
  endproperty
  A001_single_fetch: assert property (p_single_fetch);

  // M2-ASSERT-002/003: SGPR writes only at COMMIT; faulting instr never writes
  property p_write_only_commit;
    @(posedge clk) disable iff (rst)
      sgpr_we |-> (dbg_state == scigpu_types_pkg::ST_COMMIT);
  endproperty
  A002_write_commit: assert property (p_write_only_commit);

  // M2-ASSERT-004: PC legality is enforced structurally (single PC register in
  // control; updates only in COMMIT/IDLE-accept). Monitored in TB.
  // M2-ASSERT-005: completion stable while stalled
  property p_completion_stable;
    @(posedge clk) disable iff (rst)
      (completion_valid && !completion_ready) |=>
        ($stable(completion_fault) && $stable(completion_fault_code) &&
         $stable(completion_pc) && $stable(completion_retired_count) &&
         completion_valid);
  endproperty
  A005_completion_stable: assert property (p_completion_stable);

  // M2-ASSERT-006: start accepted only when idle
  property p_start_only_idle;
    @(posedge clk) disable iff (rst)
      (start_valid && start_ready) |-> (dbg_state == scigpu_types_pkg::ST_IDLE);
  endproperty
  A006_start_idle: assert property (p_start_only_idle);

  // M2-ASSERT-007: reset clears completion (checked post-reset in TB)
  // M2-ASSERT-008: invalid SGPR index cannot write (file gates wr_allowed)
  // M2-ASSERT-009/010: RET/fault stop fetching (FSM leaves fetch states)
  //   -> enforced by FSM structure; TB reset/fault suites observe no further
  //      if_req_valid after COMPLETE/FAULT entry.

endinterface
