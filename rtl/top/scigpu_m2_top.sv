// SciGPU M2 top — thin integration shell for lint/elaboration/synthesis smoke.
// No vendor primitives; generic clock/reset; instruction memory external.
module scigpu_m2_top #(
  parameter int unsigned SGPR_COUNT = 64
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        start_valid,
  output logic        start_ready,
  input  logic [63:0] start_entry_pc,
  input  logic [63:0] start_code_words,
  input  logic [31:0] start_wg_x,

  output logic        if_req_valid,
  output logic [63:0] if_req_pc,
  input  logic        if_req_ready,
  input  logic        if_rsp_valid,
  input  logic [63:0] if_rsp_insn,
  input  logic        if_rsp_error,
  output logic        if_rsp_ready,

  input  logic        sgpr_init_valid,
  input  logic [7:0]  sgpr_init_addr,
  input  logic [31:0] sgpr_init_data,
  output logic        sgpr_init_ready,

  output logic        completion_valid,
  input  logic        completion_ready,
  output logic        completion_fault,
  output logic [5:0]  completion_fault_code,
  output logic [63:0] completion_pc,
  output logic [63:0] completion_retired_count,

  output logic        trace_valid,
  output logic [63:0] trace_pc,
  output logic [63:0] trace_insn,
  output logic        trace_sgpr_we,
  output logic [7:0]  trace_sgpr_addr,
  output logic [31:0] trace_sgpr_wdata,
  output logic [3:0]  trace_sc_flags,
  output logic        trace_scc,
  output logic        trace_branch_taken,
  output logic [63:0] trace_next_pc,
  output logic        trace_fault_o,
  output logic [5:0]  trace_fault_code_o,

  output logic [63:0] dbg_pc,
  output logic [63:0] dbg_code_words,
  output logic [5:0]  dbg_last_fault_code,
  output scigpu_types_pkg::state_e dbg_state
);

  scigpu_scalar_core #(
    .SGPR_COUNT(SGPR_COUNT)
  ) u_core (
    .*                        // explicit port list above; same names
  );

endmodule
