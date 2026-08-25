// SciGPU M5 - vector compare slice producing predicate masks (MICRO-001
// Rev0.4 s4.4). Shares the CU's VGPR read port and issue-ownership with the
// M3/M4 vector engine (one vector-class instruction in flight CU-wide); no
// second 32-lane machine is instantiated (directive 87). Executes B =
// 32/SIMD_LANES beats; accumulates cmp_mask; commits predicates once:
//
//   P[pdst] = (P_old & ~EXEC) | (cmp_result & EXEC)      (INV-002)
//   PDST=15 rejected before beat 0 by the CU validation path.
//
// Compare semantics = current golden model (ISA-001 Rev1.4 s16.3):
//   EQ/NEQ bitwise; LT/LE/GT/GE signed I32.
module scigpu_vector_compare_m5 #(
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic clk, input logic rst,

  // setup (accepted only when the shared vector backend is free)
  input  logic        setup_valid,
  output logic        setup_ready,
  input  logic [1:0]  setup_kind,        // 00 EQ, 01 LT(s), 10 LE(s)
  input  logic        setup_invert,      // NEQ / GE / GT
  input  logic [7:0]  setup_vs0,
  input  logic [7:0]  setup_vs1,
  input  logic [31:0] setup_exec,        // EXEC captured at accept
  input  logic [31:0] setup_pold,        // P[pdst] captured at accept

  // shared VGPR read port (driven by this unit while it owns the backend)
  output logic [7:0]  vg_raddr0,
  output logic [7:0]  vg_raddr1,
  output logic [4:0]  vg_rlane_base,
  input  logic [31:0] vg_rdata0 [SIMD_LANES],
  input  logic [31:0] vg_rdata1 [SIMD_LANES],

  // commit pulse (final beat): predicate writeback payload valid
  output logic        last_commit,
  output logic [31:0] commit_pdata,       // new predicate value
  output logic        busy
);

  localparam int unsigned W = 32;
  localparam int unsigned B = W / SIMD_LANES;
  localparam int unsigned BCNT_W = (B <= 1) ? 1 : $clog2(B);
  localparam logic [4:0] L5 = SIMD_LANES[4:0];

  logic        run_q;
  logic [1:0]  kind_q;
  logic        inv_q;
  logic [7:0]  vs0_q, vs1_q;
  logic [31:0] exec_q, pold_q, acc_q;
  logic [BCNT_W-1:0] beat_q;
  logic        last_issue_q;

  assign setup_ready = !run_q;
  assign busy = run_q;

  wire do_setup = setup_valid && setup_ready;

  wire [4:0] iss_base = L5 * 5'(beat_q);
  wire [SIMD_LANES-1:0] iss_mask = exec_q[iss_base +: SIMD_LANES];

  assign vg_raddr0     = vs0_q;
  assign vg_raddr1     = vs1_q;
  assign vg_rlane_base = iss_base;

  // per-lane compare result (this beat's issue stage)
  logic [SIMD_LANES-1:0] beat_res;
  logic [SIMD_LANES-1:0] raw_res;
  always_comb begin
    for (int j = 0; j < SIMD_LANES; j++) begin
      logic signed [31:0] a_s, b_s;
      a_s = 32'(vg_rdata0[j]);
      b_s = 32'(vg_rdata1[j]);
      unique case (kind_q)
        2'b00:   raw_res[j] = (vg_rdata0[j] == vg_rdata1[j]);
        2'b01:   raw_res[j] = (a_s <  b_s);
        2'b10:   raw_res[j] = (a_s <= b_s);
        default: raw_res[j] = 1'b0;
      endcase
    end
  end
  assign beat_res = (inv_q ? ~raw_res : raw_res) & iss_mask;

  assign last_commit = com_valid_q && (com_idx_q == BCNT_W'(B-1));
  // final accumulated mask registered one beat earlier is complete because the
  // accumulation for beat k happens in the cycle beat k issues (>= 1 cycle
  // before last_commit pulses).
  assign commit_pdata = (pold_q & ~exec_q) | (acc_q & exec_q);

  logic                  com_valid_q;
  logic [BCNT_W-1:0]     com_idx_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      run_q <= 1'b0; kind_q <= '0; inv_q <= 1'b0;
      vs0_q <= '0; vs1_q <= '0;
      exec_q <= '0; pold_q <= '0; acc_q <= '0;
      beat_q <= '0; last_issue_q <= 1'b0;
      com_valid_q <= 1'b0; com_idx_q <= '0;
    end else begin
      if (run_q) begin
        com_valid_q <= 1'b1;
        com_idx_q   <= beat_q;
        acc_q       <= acc_q | { {(32-SIMD_LANES){1'b0}}, beat_res }
                               << iss_base;
        if (last_issue_q) begin
          run_q <= 1'b0;
          last_issue_q <= 1'b0;
        end else begin
          beat_q <= beat_q + 1'b1;
          if (beat_q == BCNT_W'(B-2)) last_issue_q <= 1'b1;
        end
      end else begin
        com_valid_q <= 1'b0;
      end

      if (do_setup && !com_valid_q && !run_q) begin
        run_q <= 1'b1;
        kind_q <= setup_kind;
        inv_q  <= setup_invert;
        vs0_q  <= setup_vs0;
        vs1_q  <= setup_vs1;
        exec_q <= setup_exec;
        pold_q <= setup_pold;
        acc_q  <= '0;
        beat_q <= '0;
        last_issue_q <= (B == 1);
      end
    end
  end

`ifdef SCIGPU_FORMAL
  cmp_beat_bounds: assert property (@(posedge clk) disable iff (rst)
    com_valid_q |-> (5'(com_idx_q) < B[4:0]));
`endif

endmodule
