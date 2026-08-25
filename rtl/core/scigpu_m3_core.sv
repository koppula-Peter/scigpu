// SciGPU M3 — integrated scalar+vector core (MICRO-001 §2)
module scigpu_m3_core #(
  parameter int unsigned SGPR_COUNT = 64,
  parameter int unsigned VGPR_COUNT = 32,
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic        clk,
  input  logic        rst,
  // launch
  input  logic        start_valid,
  output logic        start_ready,
  input  logic [63:0] start_entry_pc,
  input  logic [63:0] start_code_words,
  input  logic [31:0] start_wg_x,
  input  logic [31:0] start_exec_mask,
  input  logic [8:0]  start_vgpr_req,
  input  logic [8:0]  start_sgpr_req,
  // instruction memory
  output logic        if_req_valid, output logic [63:0] if_req_pc,
  input  logic        if_req_ready,
  input  logic        if_rsp_valid, input  logic [63:0] if_rsp_insn,
  input  logic        if_rsp_error, output logic        if_rsp_ready,
  // preload (bootstrap)
  input  logic        sgpr_init_valid, input  logic [7:0]  sgpr_init_addr,
  input  logic [31:0] sgpr_init_data,  output logic        sgpr_init_ready,
  input  logic        pred_init_valid, input  logic [3:0]  pred_init_addr,
  input  logic [31:0] pred_init_data,  output logic        pred_init_ready,
  input  logic        vgpr_init_valid, input  logic [7:0]  vgpr_init_addr,
  input  logic [4:0]  vgpr_init_lane,  input  logic [31:0] vgpr_init_data,
  output logic        vgpr_init_ready,
  // completion
  output logic        completion_valid, input  logic completion_ready,
  output logic        completion_fault,
  output logic [5:0]  completion_fault_code,
  output logic [63:0] completion_pc,
  output logic [63:0] completion_retired_count,
  // retire trace (flat)
  output logic        trace_valid, output logic [63:0] trace_pc,
  output logic [63:0] trace_insn, output logic trace_sgpr_we,
  output logic [7:0]  trace_sgpr_addr, output logic [31:0] trace_sgpr_wdata,
  output logic [3:0]  trace_sc_flags, output logic trace_scc,
  output logic        trace_branch_taken, output logic [63:0] trace_next_pc,
  output logic [31:0] trace_exec_mask, output logic [3:0] trace_pred_idx,
  output logic [31:0] trace_effective_mask,
  output logic        trace_vgpr_we, output logic [7:0] trace_vgpr_addr,
  output logic [31:0] trace_vgpr_write_mask,
  output logic        trace_fault_o, output logic [5:0] trace_fault_code_o,
  // beat trace
  output logic        beat_valid, output logic [4:0] beat_index,
  output logic [4:0]  beat_base, output logic [SIMD_LANES-1:0] beat_mask,
  output logic [7:0]  beat_vdst,
  // debug / final-state dump ports (verification convenience)
  output logic [63:0] dbg_pc,
  output scigpu_types_pkg::state_e dbg_state,
  input  logic [7:0]  dbg_sgpr_addr,  output logic [31:0] dbg_sgpr_data,
  input  logic [3:0]  dbg_pred_addr,  output logic [31:0] dbg_pred_data,
  input  logic [7:0]  dbg_vgpr_addr,  input  logic [4:0] dbg_vgpr_lane,
  output logic [31:0] dbg_vgpr_data
);

  import scigpu_types_pkg::*;

  // fetch
  logic f_cmd_valid; logic [63:0] f_cmd_pc; logic f_req_accepted, f_busy;
  logic f_rsp_valid; logic [63:0] f_rsp_insn; logic f_rsp_error; logic f_rsp_ready;
  logic unused_f_busy;
  scigpu_fetch u_fetch (
    .clk(clk), .rst(rst), .cmd_valid(f_cmd_valid), .cmd_pc(f_cmd_pc),
    .busy(f_busy), .req_accepted(f_req_accepted),
    .if_req_valid(if_req_valid), .if_req_pc(if_req_pc), .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_insn(if_rsp_insn),
    .if_rsp_error(if_rsp_error), .if_rsp_ready(if_rsp_ready),
    .rsp_ready(f_rsp_ready), .rsp_valid(f_rsp_valid),
    .rsp_insn(f_rsp_insn), .rsp_error(f_rsp_error));

  // SGPR file
  logic [7:0] sr0, sr1; logic [31:0] sq0, sq1; logic si0, si1;
  logic s_we; logic [7:0] s_wa; logic [31:0] s_wd;
  scigpu_sgpr_file #(.SGPR_COUNT(SGPR_COUNT)) u_sgpr (
    .clk(clk), .rst(rst),
    .init_we(sgpr_init_valid && sgpr_init_ready), .init_addr(sgpr_init_addr),
    .init_data(sgpr_init_data),
    .raddr0(sr0), .raddr1(sr1), .rdata0(sq0), .rdata1(sq1),
    .r_invalid0(si0), .r_invalid1(si1),
    .we(s_we), .waddr(s_wa), .wdata(s_wd),
    .dbg_addr(dbg_sgpr_addr), .dbg_data(dbg_sgpr_data));

  // predicate file (ready = file accepts AND control is IDLE)
  logic pr_ready; logic [31:0] pr_rd;
  logic ctrl_pred_ready;
  scigpu_predicate_file_m3 u_pred (
    .clk(clk), .rst(rst), .init_valid(pred_init_valid),
    .init_addr(pred_init_addr), .init_ready(pr_ready),
    .init_data(pred_init_data), .rd_addr(trace_pred_idx), .rd_data(pr_rd),
    .dbg_addr(dbg_pred_addr), .dbg_data(dbg_pred_data));
  assign pred_init_ready = pr_ready && ctrl_pred_ready;

  // VGPR file
  logic vr0, vr1;
  logic unused_vr0, unused_vr1; logic [31:0] vd0 [SIMD_LANES]; logic [31:0] vd1 [SIMD_LANES];
  logic v_we; logic [7:0] v_wa; logic [4:0] v_wb;
  logic [SIMD_LANES-1:0] v_wm; logic [31:0] v_wd_arr [SIMD_LANES];
  scigpu_vgpr_file_m3 #(
    .VGPR_COUNT(VGPR_COUNT), .SIMD_LANES(SIMD_LANES)
  ) u_vgpr (
    .clk(clk), .rst(rst),
    .init_we(vgpr_init_valid && vgpr_init_ready), .init_addr(vgpr_init_addr),
    .init_lane(vgpr_init_lane), .init_data(vgpr_init_data),
    .raddr0(eng_raddr0), .raddr1(eng_raddr1), .rlane_base(eng_rlane_base),
    .rdata0(vd0), .rdata1(vd1),
    .r_invalid0(vr0), .r_invalid1(vr1),
    .we(v_we), .waddr(v_wa), .wlane_base(v_wb), .wmask(v_wm), .wdata(v_wd_arr),
    .dbg_addr(dbg_vgpr_addr), .dbg_lane(dbg_vgpr_lane),
    .dbg_data(dbg_vgpr_data));

  // vector engine
  logic eng_setup_valid, eng_setup_ready, eng_last_commit;
  logic [3:0] eng_op; logic [1:0] eng_bmux;
  logic [7:0] eng_vd, eng_vs0, eng_vs1;
  logic [31:0] eng_imm, eng_bcast, eng_emask;
  logic [7:0] eng_raddr0, eng_raddr1; logic [4:0] eng_rlane_base;
  scigpu_vector_engine #(.SIMD_LANES(SIMD_LANES)) u_eng (
    .clk(clk), .rst(rst),
    .setup_valid(eng_setup_valid), .setup_ready(eng_setup_ready),
    .setup_op(eng_op), .setup_bmux(eng_bmux), .setup_vd(eng_vd),
    .setup_vs0(eng_vs0), .setup_vs1(eng_vs1), .setup_imm(eng_imm),
    .setup_bcast_data(eng_bcast), .setup_effective_mask(eng_emask),
    .vg_raddr0(eng_raddr0), .vg_raddr1(eng_raddr1), .vg_rlane_base(eng_rlane_base),
    .vg_rdata0(vd0), .vg_rdata1(vd1),
    .vg_we(v_we), .vg_waddr(v_wa), .vg_wlane_base(v_wb), .vg_wmask(v_wm),
    .vg_wdata(v_wd_arr),
    .beat_valid(beat_valid), .beat_index(beat_index), .beat_base(beat_base),
    .beat_mask(beat_mask), .beat_vdst(beat_vdst),
    .last_commit(eng_last_commit));

  always_comb begin
    unused_f_busy = f_busy;
    unused_vr0 = vr0; unused_vr1 = vr1;   // vector validation uses declared reqs
  end
  assign vgpr_init_ready = (dbg_state == scigpu_types_pkg::ST_IDLE);

  // control
  scigpu_m3_control #(
    .SGPR_COUNT(SGPR_COUNT), .VGPR_COUNT(VGPR_COUNT)
  ) u_ctrl (
    .clk(clk), .rst(rst),
    .start_valid(start_valid), .start_ready(start_ready),
    .start_entry_pc(start_entry_pc), .start_code_words(start_code_words),
    .start_wg_x(start_wg_x), .start_exec_mask(start_exec_mask),
    .start_vgpr_req(start_vgpr_req), .start_sgpr_req(start_sgpr_req),
    .f_cmd_valid(f_cmd_valid), .f_cmd_pc(f_cmd_pc),
    .f_req_accepted(f_req_accepted), .f_rsp_valid(f_rsp_valid),
    .f_rsp_insn(f_rsp_insn), .f_rsp_error(f_rsp_error),
    .f_rsp_ready(f_rsp_ready),
    .sgpr_init_ready(sgpr_init_ready),
    .sgpr_raddr0(sr0), .sgpr_raddr1(sr1),
    .sgpr_rdata0(sq0), .sgpr_rdata1(sq1),
    .sgpr_rinv0(si0), .sgpr_rinv1(si1),
    .sgpr_we(s_we), .sgpr_waddr(s_wa), .sgpr_wdata(s_wd),
    .pred_init_ready(ctrl_pred_ready),
    .pred_rd_data(pr_rd),
    .vec_setup_valid(eng_setup_valid), .vec_setup_ready(eng_setup_ready),
    .vec_op(eng_op), .vec_bmux(eng_bmux), .vec_vd(eng_vd), .vec_vs0(eng_vs0),
    .vec_vs1(eng_vs1), .vec_imm(eng_imm), .vec_bcast_data(eng_bcast),
    .vec_effective_mask(eng_emask), .vec_last_commit(eng_last_commit),
    .completion_valid(completion_valid), .completion_ready(completion_ready),
    .completion_fault(completion_fault),
    .completion_fault_code(completion_fault_code),
    .completion_pc(completion_pc),
    .completion_retired_count(completion_retired_count),
    .trace_valid(trace_valid), .trace_pc(trace_pc), .trace_insn(trace_insn),
    .trace_sgpr_we(trace_sgpr_we), .trace_sgpr_addr(trace_sgpr_addr),
    .trace_sgpr_wdata(trace_sgpr_wdata), .trace_sc_flags(trace_sc_flags),
    .trace_scc(trace_scc), .trace_branch_taken(trace_branch_taken),
    .trace_next_pc(trace_next_pc), .trace_exec_mask(trace_exec_mask),
    .trace_pred_idx(trace_pred_idx),
    .trace_effective_mask(trace_effective_mask),
    .trace_vgpr_we(trace_vgpr_we), .trace_vgpr_addr(trace_vgpr_addr),
    .trace_vgpr_write_mask(trace_vgpr_write_mask),
    .trace_fault_o(trace_fault_o), .trace_fault_code_o(trace_fault_code_o),
    .dbg_pc(dbg_pc),
    .dbg_exec_mask(trace_exec_mask),       // exposed via retire trace + debug
    .dbg_pred_idx(trace_pred_idx),
    .dbg_effective_mask(trace_effective_mask),
    .dbg_vgpr_we(trace_vgpr_we),
    .dbg_vgpr_addr(trace_vgpr_addr),
    .dbg_vgpr_write_mask(trace_vgpr_write_mask),
    .dbg_state(dbg_state));

endmodule
