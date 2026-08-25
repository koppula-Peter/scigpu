// SciGPU M3 top — thin shell for lint/elaboration/synthesis smoke.
module scigpu_m3_top #(
  parameter int unsigned SGPR_COUNT = 64,
  parameter int unsigned VGPR_COUNT = 32,
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic clk, input logic rst,
  input  logic start_valid, output logic start_ready,
  input  logic [63:0] start_entry_pc, input logic [63:0] start_code_words,
  input  logic [31:0] start_wg_x, input logic [31:0] start_exec_mask,
  input  logic [8:0]  start_vgpr_req, input logic [8:0] start_sgpr_req,
  output logic if_req_valid, output logic [63:0] if_req_pc,
  input  logic if_req_ready,
  input  logic if_rsp_valid, input logic [63:0] if_rsp_insn,
  input  logic if_rsp_error, output logic if_rsp_ready,
  input  logic sgpr_init_valid, input logic [7:0] sgpr_init_addr,
  input  logic [31:0] sgpr_init_data, output logic sgpr_init_ready,
  input  logic pred_init_valid, input logic [3:0] pred_init_addr,
  input  logic [31:0] pred_init_data, output logic pred_init_ready,
  input  logic vgpr_init_valid, input logic [7:0] vgpr_init_addr,
  input  logic [4:0] vgpr_init_lane, input logic [31:0] vgpr_init_data,
  output logic vgpr_init_ready,
  output logic completion_valid, input logic completion_ready,
  output logic completion_fault, output logic [5:0] completion_fault_code,
  output logic [63:0] completion_pc, output logic [63:0] completion_retired_count,
  output logic trace_valid, output logic [63:0] trace_pc,
  output logic [63:0] trace_insn, output logic trace_sgpr_we,
  output logic [7:0] trace_sgpr_addr, output logic [31:0] trace_sgpr_wdata,
  output logic [3:0] trace_sc_flags, output logic trace_scc,
  output logic trace_branch_taken, output logic [63:0] trace_next_pc,
  output logic [31:0] trace_exec_mask, output logic [3:0] trace_pred_idx,
  output logic [31:0] trace_effective_mask,
  output logic trace_vgpr_we, output logic [7:0] trace_vgpr_addr,
  output logic [31:0] trace_vgpr_write_mask,
  output logic trace_fault_o, output logic [5:0] trace_fault_code_o,
  output logic beat_valid, output logic [4:0] beat_index,
  output logic [4:0] beat_base, output logic [SIMD_LANES-1:0] beat_mask,
  output logic [7:0] beat_vdst,
  output logic [63:0] dbg_pc, output scigpu_types_pkg::state_e dbg_state,
  input  logic [7:0] dbg_sgpr_addr, output logic [31:0] dbg_sgpr_data,
  input  logic [3:0] dbg_pred_addr, output logic [31:0] dbg_pred_data,
  input  logic [7:0] dbg_vgpr_addr, input logic [4:0] dbg_vgpr_lane,
  output logic [31:0] dbg_vgpr_data
);
  scigpu_m3_core #(
    .SGPR_COUNT(SGPR_COUNT), .VGPR_COUNT(VGPR_COUNT), .SIMD_LANES(SIMD_LANES)
  ) u_core (.* );
endmodule
