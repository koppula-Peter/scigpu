// SciGPU M6 — per-resident-slot scoreboard (MICRO-001 Rev0.5 §5.4).
//
// Tracks one outstanding vector-class destination per slot (G1
// one-in-flight): VGPR pending (vector-ALU destination) and PRED pending
// (VCMP predicate destination). Issue-time source checks close RAW; a
// matching destination also holds WAW. Releases occur at the owning
// instruction's commit (last beat / compare commit).
module scigpu_scoreboard_m6 #(
  parameter int unsigned SLOTS = 4
) (
  input  logic clk, input logic rst,

  // ---- issue-time source check (granted slot, combinational) ----
  input  logic [$clog2(SLOTS)-1:0] chk_slot,
  input  logic [7:0]  chk_src0,
  input  logic [7:0]  chk_src1,
  input  logic [7:0]  chk_src2,
  input  logic        chk_src2_en,
  input  logic [3:0]  chk_pred,        // control-condition selector
  output logic        vgpr_wait,       // vector src hits pending VGPR dst
  output logic        pred_wait,       // control cond hits pending PRED dst

  // ---- set (issue accept) ----
  input  logic        vec_set,
  input  logic [$clog2(SLOTS)-1:0] vec_set_slot,
  input  logic [7:0]  vec_set_reg,
  input  logic        pred_set,
  input  logic [$clog2(SLOTS)-1:0] pred_set_slot,
  input  logic [3:0]  pred_set_reg,

  // ---- release (commit) ----
  input  logic        vec_release,
  input  logic [$clog2(SLOTS)-1:0] vec_rel_slot,
  input  logic        pred_release,
  input  logic [$clog2(SLOTS)-1:0] pred_rel_slot,

  // per-slot pending-state exposure (CU-side per-slot issue gating)
  output logic [SLOTS-1:0] o_v_val,
  output logic [8*SLOTS-1:0] o_vreg,
  output logic [SLOTS-1:0] o_p_val,
  output logic [4*SLOTS-1:0] o_pred
);

  logic       v_val [SLOTS];
  logic [7:0] v_reg [SLOTS];
  logic       p_val [SLOTS];
  logic [3:0] p_reg [SLOTS];

  // exposed state (per-slot)
  integer xe;
  always_comb begin
    for (xe = 0; xe < int'(SLOTS); xe++) begin
      o_v_val[xe]   = v_val[xe];
      o_p_val[xe]   = p_val[xe];
    end
    for (xe = 0; xe < int'(SLOTS); xe++) begin
      o_vreg[8*xe +: 8] = v_reg[xe];
      o_pred[4*xe +: 4] = p_reg[xe];
    end
  end

  // combinational source checks against current (pre-edge) state
  always_comb begin
    /* verilator lint_off UNUSEDSIGNAL */
    automatic int s = int'(chk_slot);
    /* verilator lint_on UNUSEDSIGNAL */
    vgpr_wait = v_val[s] && ((chk_src0 == v_reg[s]) || (chk_src1 == v_reg[s]) ||
                             (chk_src2_en && (chk_src2 == v_reg[s])));
    pred_wait = p_val[s] && (chk_pred == p_reg[s]);
  end

  integer s_;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (s_ = 0; s_ < int'(SLOTS); s_++) begin
        v_val[s_] <= 1'b0; v_reg[s_] <= '0;
        p_val[s_] <= 1'b0; p_reg[s_] <= '0;
      end
    end else begin
      // releases (a release may coincide with another slot's set)
      if (vec_release)  v_val[vec_rel_slot] <= 1'b0;
      if (pred_release) p_val[pred_rel_slot] <= 1'b0;

      // sets
      if (vec_set)  begin v_val[vec_set_slot]   <= 1'b1;
                           v_reg[vec_set_slot]  <= vec_set_reg; end
      if (pred_set) begin p_val[pred_set_slot]  <= 1'b1;
                           p_reg[pred_set_slot] <= pred_set_reg; end
    end
  end

endmodule
