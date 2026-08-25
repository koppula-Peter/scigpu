// SciGPU M3 — vector engine: beat sequencer + pipelined masked writeback
// (MICRO-001 §2.5/§2.8; directive §30-32, §49-52, §54).
//
// Contract:
//   * setup_valid && setup_ready : latch full instruction context, beat_idx=0,
//     running=1. setup_ready stays 0 until the final beat commits.
//   * Every cycle while running: issue beat k (VGPR comb read -> ALU),
//     register result; simultaneously commit previously registered beat k-1
//     (masked writeback). II = 1 beat/cycle. Commit lag = 1 cycle.
//   * last_commit pulses when beat B-1 commits -> control retires instruction.
//   * Empty beats (mask slice 0) advance the counter without writes (§54).
module scigpu_vector_engine #(
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic        clk,
  input  logic        rst,

  // setup channel (control)
  input  logic        setup_valid,
  output logic        setup_ready,
  input  logic [4:0]  setup_op,            // va_op_e (PASS_B/ADD/.../LLANE)
  input  logic [1:0]  setup_bmux,          // operand-B select (see localparam)
  input  logic [7:0]  setup_vd,
  input  logic [7:0]  setup_vs0,
  input  logic [7:0]  setup_vs1,
  input  logic [7:0]  setup_vs2,
  input  logic [31:0] setup_imm,
  input  logic [31:0] setup_bcast_data,
  input  logic [31:0] setup_effective_mask,// EXEC (& predicate), captured once

  // VGPR read port
  output logic [7:0]  vg_raddr0,
  output logic [7:0]  vg_raddr2,
  output logic [7:0]  vg_raddr1,
  output logic [4:0]  vg_rlane_base,
  input  logic [31:0] vg_rdata0 [SIMD_LANES],
  input  logic [31:0] vg_rdata1 [SIMD_LANES],
  input  logic [31:0] vg_rdata2 [SIMD_LANES],

  // VGPR write port (commit stage)
  output logic        vg_we,
  output logic [7:0]  vg_waddr,
  output logic [4:0]  vg_wlane_base,
  output logic [SIMD_LANES-1:0] vg_wmask,
  output logic [31:0] vg_wdata [SIMD_LANES],

  // beat trace (directive §67)
  output logic        beat_valid,
  output logic [4:0]  beat_index,
  output logic [4:0]  beat_base,
  output logic [SIMD_LANES-1:0] beat_mask,
  output logic [7:0]  beat_vdst,
  output logic        last_commit
);

  localparam int unsigned W = 32;                       // architectural, fixed
  localparam int unsigned B = W / SIMD_LANES;
  localparam int unsigned BCNT_W = (B <= 1) ? 1 : $clog2(B);

  // operand-B select
  localparam bit [1:0] BM_VS1   = 2'd0;   // second vector source
  localparam bit [1:0] BM_IMM    = 2'd1;  // sign-extended SIMM16
  localparam bit [1:0] BM_VS0   = 2'd2;   // V_MOV reg,reg passes src0
  localparam bit [1:0] BM_BCAST = 2'd3;   // captured SGPR value

  // ---- context registers ----------------------------------------------------
  logic        running_q;
  logic [4:0]  op_q;
  logic [1:0]  bmux_q;
  logic [7:0]  vd_q, vs0_q, vs1_q, vs2_q;
  logic [31:0] imm_q, bcast_q, emask_q;
  logic [BCNT_W-1:0] beat_q;                   // beat being ISSUED this cycle
  logic        last_issue_q;                  // issuing final beat

  assign setup_ready = !running_q;

  wire        do_setup = setup_valid && setup_ready;
  localparam logic [4:0] L5 = SIMD_LANES[4:0];
  wire [4:0]  iss_base = 5'(beat_q) * L5;
  wire [SIMD_LANES-1:0] iss_mask = emask_q[iss_base +: SIMD_LANES];

  // ---- VGPR read addressing (issue stage, combinational) --------------------
  assign vg_raddr0     = vs0_q;
  assign vg_raddr1     = vs1_q;
  assign vg_raddr2     = vs2_q;
  assign vg_rlane_base = iss_base;

  // ---- ALU ------------------------------------------------------------------
  logic [4:0]  alu_op;
  logic [31:0] alu_a [SIMD_LANES];
  logic [31:0] alu_b [SIMD_LANES];
  logic [31:0] alu_c [SIMD_LANES];

  always_comb begin
    alu_op = op_q;
    for (int j = 0; j < SIMD_LANES; j++) begin
      alu_a[j] = vg_rdata0[j];
      alu_c[j] = vg_rdata2[j];
      case (bmux_q)
        BM_VS1  : alu_b[j] = vg_rdata1[j];
        BM_IMM  : alu_b[j] = imm_q;
        BM_VS0  : alu_b[j] = vg_rdata0[j];
        BM_BCAST: alu_b[j] = bcast_q;
        default : alu_b[j] = vg_rdata1[j];
      endcase
    end
  end

  logic [31:0] alu_y [SIMD_LANES];
  // V_LLANE per-lane result: logical lane id = beat_base + physical index
  logic [31:0] llane_val [SIMD_LANES];
  always_comb begin
    for (int j = 0; j < SIMD_LANES; j++)
      llane_val[j] = 32'(iss_base) + 32'(j);
  end

  scigpu_vector_alu #(.SIMD_LANES(SIMD_LANES)) u_alu (
    .op(alu_op), .a(alu_a), .b(alu_b), .c(alu_c), .y(alu_y)
  );

  wire [4:0] com_base = 5'(com_idx_q) * L5;

  // ---- commit-stage registers (lag issue by one cycle) ----------------------
  logic                  com_valid_q;
  logic [BCNT_W-1:0]     com_idx_q;
  logic [7:0]            com_vd_q;
  logic [SIMD_LANES-1:0] com_mask_q;
  logic [31:0]           com_data_q [SIMD_LANES];

  // ---- outputs (commit stage) ------------------------------------------------
  assign vg_we         = com_valid_q;
  assign vg_waddr      = com_vd_q;
  always_comb vg_wlane_base = com_base;
  assign vg_wmask      = com_mask_q;
  always_comb begin
    for (int j = 0; j < SIMD_LANES; j++)
      vg_wdata[j] = com_data_q[j];
  end

  assign beat_valid    = com_valid_q;
  assign beat_index    = 5'(com_idx_q);
  assign beat_base     = com_base;
  assign beat_mask     = com_mask_q;
  assign beat_vdst     = com_vd_q;
  assign last_commit   = com_valid_q && (com_idx_q == BCNT_W'(B-1));

  // ---- sequencer --------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      running_q    <= 1'b0;
      op_q         <= '0; bmux_q <= '0;
      vd_q         <= '0; vs0_q <= '0; vs1_q <= '0; vs2_q <= '0;
      imm_q        <= '0; bcast_q <= '0; emask_q <= '0;
      beat_q       <= '0;
      last_issue_q <= 1'b0;
      com_valid_q  <= 1'b0;
      com_idx_q    <= '0;
      com_vd_q     <= '0;
      com_mask_q   <= '0;
    end else begin
      // ---- commit previous beat ----
      // (vg_* outputs are combinational from com_*_q; valid clears unless a new
      //  beat result is registered this same edge)
      // ---- issue current beat into commit register ----
      if (running_q) begin
        com_valid_q <= 1'b1;
        com_idx_q   <= beat_q;
        com_vd_q    <= vd_q;
        com_mask_q  <= iss_mask;
        for (int j = 0; j < SIMD_LANES; j++)
          com_data_q[j] <= (op_q == 5'd11) ? llane_val[j] : alu_y[j];

        if (last_issue_q) begin
          running_q    <= 1'b0;                 // final beat in flight; retire
          last_issue_q <= 1'b0;
        end else begin
          beat_q <= beat_q + 1'b1;
          if (beat_q == BCNT_W'(B-2))
            last_issue_q <= 1'b1;
        end
      end else begin
        com_valid_q <= 1'b0;
      end

      // ---- accept new instruction only when fully drained ----
      if (do_setup && !com_valid_q && !running_q) begin
        running_q <= 1'b1;
        op_q      <= setup_op;
        bmux_q    <= setup_bmux;
        vd_q      <= setup_vd;
        vs0_q     <= setup_vs0;
        vs1_q     <= setup_vs1;
        vs2_q     <= setup_vs2;
        imm_q     <= setup_imm;
        bcast_q   <= setup_bcast_data;
        emask_q   <= setup_effective_mask;
        beat_q    <= '0;
        last_issue_q <= (B == 1);
      end
    end
  end

`ifdef SCIGPU_FORMAL
  // M3-ASSERT-003/004 equivalents
  beat_bounds: assert property (@(posedge clk) disable iff (rst)
    beat_valid |-> (beat_index < BCNT_W'(B)));
  beat_base_map: assert property (@(posedge clk) disable iff (rst)
    beat_valid |-> (32'(beat_base) == 32'(beat_index) * 32'(SIMD_LANES)));
`endif

endmodule
