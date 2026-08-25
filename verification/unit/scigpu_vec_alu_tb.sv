// SciGPU M3 vector-ALU unit testbench (directive §72).
// Simulation-only wrapper: drives scigpu_vector_alu with flat scalar lanes.
module scigpu_vec_alu_tb #(
  parameter int unsigned SIMD_LANES = 4
) (
  input  logic [3:0]     op,
  input  logic [31:0]    a0, a1, a2, a3, b0, b1, b2, b3,
  output logic [31:0]    y0, y1, y2, y3
);
  logic [31:0] a [SIMD_LANES];
  logic [31:0] b [SIMD_LANES];
  logic [31:0] y [SIMD_LANES];

  always_comb begin
    a[0]=a0; a[1]=(SIMD_LANES>1)?a1:a0; a[2]=(SIMD_LANES>2)?a2:a0;
    a[3]=(SIMD_LANES>3)?a3:a0;
    b[0]=b0; b[1]=(SIMD_LANES>1)?b1:b0; b[2]=(SIMD_LANES>2)?b2:b0;
    b[3]=(SIMD_LANES>3)?b3:b0;
  end

  scigpu_vector_alu #(.SIMD_LANES(SIMD_LANES)) u (
    .op(op), .a(a), .b(b), .y(y));

  assign y0=y[0]; assign y1=(SIMD_LANES>1)?y[1]:y[0];
  assign y2=(SIMD_LANES>2)?y[2]:y[0]; assign y3=(SIMD_LANES>3)?y[3]:y[0];
endmodule
