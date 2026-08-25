// SciGPU M2 — scalar condition state (ISA-001 Rev1.2 §7; directive §6-7)
// Dedicated Z/N/C/V + SCC architectural state. NOT SGPRs.
module scigpu_scalar_flags (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [31:0] r,          // R = A - B (mod 2^32)
  input  logic [1:0]  cmp_kind,   // 0=EQ 1=LT(signed) 2=GT(signed)
  output logic        z,
  output logic        n,
  output logic        c,          // 1 => no unsigned borrow
  output logic        v,
  output logic        scc
);

  assign z = (r == 32'd0);
  assign n = r[31];
  assign c = (a >= b);            // C = carry-out of A + ~B + 1 => no unsigned borrow

  wire a_neg = a[31];
  wire b_neg = b[31];
  wire r_neg = r[31];
  assign v = (a_neg != b_neg) && (r_neg != a_neg);

  wire eq    = (a == b);
  wire lt_s  = (n ^ v) == 1'b1;
  wire gt_s  = (~lt_s) && (z == 1'b0);

  always_comb begin
    unique case (cmp_kind)
      2'd0    : scc = eq;
      2'd1    : scc = lt_s;
      2'd2    : scc = gt_s;
      default : scc = 1'b0;
    endcase
  end

endmodule
