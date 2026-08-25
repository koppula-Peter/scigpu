// SciGPU M2 — scalar core integration (MICRO-001 §1.8)
// Fetch engine + SGPR file + control. One execution context, one instruction
// in flight. Vector datapath arrives at M3+; boundaries prepared, not implemented.
module scigpu_scalar_core #(
  parameter int unsigned SGPR_COUNT = 64
) (
  input  logic        clk,
  input  logic        rst,

  // launch
  input  logic        start_valid,
  output logic        start_ready,
  input  logic [63:0] start_entry_pc,
  input  logic [63:0] start_code_words,
  input  logic [31:0] start_wg_x,

  // instruction memory (generic req/rsp; fetch engine is the sole owner)
  output logic        if_req_valid,
  output logic [63:0] if_req_pc,
  input  logic        if_req_ready,
  input  logic        if_rsp_valid,
  input  logic [63:0] if_rsp_insn,
  input  logic        if_rsp_error,
  output logic        if_rsp_ready,

  // SGPR preload (bootstrap)
  input  logic        sgpr_init_valid,
  input  logic [7:0]  sgpr_init_addr,
  input  logic [31:0] sgpr_init_data,
  output logic        sgpr_init_ready,

  // completion
  output logic        completion_valid,
  input  logic        completion_ready,
  output logic        completion_fault,
  output logic [5:0]  completion_fault_code,
  output logic [63:0] completion_pc,
  output logic [63:0] completion_retired_count,

  // retire trace (flattened)
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

  // debug
  output logic [63:0] dbg_pc,
  output logic [63:0] dbg_code_words,
  output logic [5:0]  dbg_last_fault_code,
  output scigpu_types_pkg::state_e dbg_state
);

  import scigpu_types_pkg::*;

  // ---- fetch engine (sole owner of external if_* handshake) -----------------
  logic         f_cmd_valid;
  logic [63:0]  f_cmd_pc;
  logic         f_req_accepted;
  logic         f_busy;
  logic         f_rsp_valid;
  logic [63:0]  f_rsp_insn;
  logic         f_rsp_error;
  logic         f_rsp_ready;

  scigpu_fetch u_fetch (
    .clk          (clk),
    .rst          (rst),
    .cmd_valid    (f_cmd_valid),
    .cmd_pc       (f_cmd_pc),
    .busy         (f_busy),
    .req_accepted (f_req_accepted),
    .if_req_valid (if_req_valid),
    .if_req_pc    (if_req_pc),
    .if_req_ready (if_req_ready),
    .if_rsp_valid (if_rsp_valid),
    .if_rsp_insn  (if_rsp_insn),
    .if_rsp_error (if_rsp_error),
    .if_rsp_ready (if_rsp_ready),
    .rsp_ready    (f_rsp_ready),
    .rsp_valid    (f_rsp_valid),
    .rsp_insn     (f_rsp_insn),
    .rsp_error    (f_rsp_error)
  );

  // ---- SGPR file -------------------------------------------------------------
  logic [7:0]  raddr0, raddr1;
  logic [31:0] rdata0, rdata1;
  logic        rinv0, rinv1;
  logic        w_we;
  logic [7:0]  w_wa;
  logic [31:0] w_wd;

  scigpu_sgpr_file #(
    .SGPR_COUNT(SGPR_COUNT)
  ) u_sgpr (
    .clk       (clk),
    .rst       (rst),
    .init_we   (sgpr_init_valid && sgpr_init_ready),
    .init_addr (sgpr_init_addr),
    .init_data (sgpr_init_data),
    .raddr0    (raddr0),
    .raddr1    (raddr1),
    .rdata0    (rdata0),
    .rdata1    (rdata1),
    .r_invalid0(rinv0),
    .r_invalid1(rinv1),
    .we        (w_we),
    .waddr     (w_wa),
    .dbg_addr  (8'd0),
    .dbg_data  (dbg_sgpr_dump),
    .wdata     (w_wd)
  );

  // ---- control ----------------------------------------------------------------
  scigpu_scalar_control #(
    .SGPR_COUNT(SGPR_COUNT)
  ) u_ctrl (
    .clk                      (clk),
    .rst                      (rst),
    .start_valid              (start_valid),
    .start_ready              (start_ready),
    .start_entry_pc           (start_entry_pc),
    .start_code_words         (start_code_words),
    .start_wg_x               (start_wg_x),
    .f_cmd_valid              (f_cmd_valid),
    .f_cmd_pc                 (f_cmd_pc),
    .f_req_accepted           (f_req_accepted),
    .f_busy_unused            (f_busy),
    .f_rsp_valid              (f_rsp_valid),
    .f_rsp_insn               (f_rsp_insn),
    .f_rsp_error              (f_rsp_error),
    .f_rsp_ready              (f_rsp_ready),
    .sgpr_init_ready          (sgpr_init_ready),
    .sgpr_raddr0              (raddr0),
    .sgpr_raddr1              (raddr1),
    .sgpr_rdata0              (rdata0),
    .sgpr_rdata1              (rdata1),
    .sgpr_rinv0               (rinv0),
    .sgpr_rinv1               (rinv1),
    .sgpr_we                  (w_we),
    .sgpr_waddr               (w_wa),
    .sgpr_wdata               (w_wd),
    .completion_valid         (completion_valid),
    .completion_ready         (completion_ready),
    .completion_fault         (completion_fault),
    .completion_fault_code    (completion_fault_code),
    .completion_pc            (completion_pc),
    .completion_retired_count (completion_retired_count),
    .trace_valid              (trace_valid),
    .trace_pc                 (trace_pc),
    .trace_insn               (trace_insn),
    .trace_sgpr_we            (trace_sgpr_we),
    .trace_sgpr_addr          (trace_sgpr_addr),
    .trace_sgpr_wdata         (trace_sgpr_wdata),
    .trace_sc_flags           (trace_sc_flags),
    .trace_scc                (trace_scc),
    .trace_branch_taken       (trace_branch_taken),
    .trace_next_pc            (trace_next_pc),
    .trace_fault_o            (trace_fault_o),
    .trace_fault_code_o       (trace_fault_code_o),
    .dbg_pc                   (dbg_pc),
    .dbg_code_words           (dbg_code_words),
    .dbg_last_fault_code     (dbg_last_fault_code),
    .dbg_state                (dbg_state)
  );

endmodule
