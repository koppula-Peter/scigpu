// SciGPU M3 — vector ALU: SIMD_LANES parallel 32-bit integer slices
// (MICRO-001 §2.7; directive §48-50). Combinational; registered in the engine.
module scigpu_vector_alu #(
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic [4:0]            op,        // va_op_e
  input  logic [31:0]           a [SIMD_LANES],
  input  logic [31:0]           b [SIMD_LANES],
  output logic [31:0]           y [SIMD_LANES]
);

  localparam bit [4:0] OP_PASS_B = 5'd00, OP_ADD = 5'd01, OP_SUB = 5'd02,
                       OP_AND = 5'd03, OP_OR = 5'd04, OP_XOR = 5'd05,
                       OP_NOT = 5'd06, OP_SHL = 5'd07, OP_SHR = 5'd08,
                       OP_SAR = 5'd09, OP_MUL = 5'd10,
                       OP_MIN = 5'd13, OP_MAX = 5'd14;


  // ---- FP32 path: dedicated fp32_alu drives y for ops >= 16 ----
  wire        fp_sel  = (op >= 5'd16);
  wire [4:0]  fp_op_w = op - 5'd16;  // 0=FADD 1=FSUB 2=FMUL 3=I2F 4=F2I
  logic [31:0] fp_y [SIMD_LANES];
  scigpu_fp32_alu #(.SIMD_LANES(SIMD_LANES)) u_fp32 (
    .op(fp_op_w), .a(a), .b(b), .y(fp_y)
  );

  genvar g;
  generate for (g = 0; g < SIMD_LANES; g++) begin : g_lane
    wire [4:0] sh   = b[g][4:0];
    wire [31:0] sar = $unsigned($signed(a[g]) >>> sh);
    always_comb begin
      case (op)
        OP_PASS_B: y[g] = b[g];
        OP_ADD   : y[g] = a[g] + b[g];
        OP_SUB   : y[g] = a[g] - b[g];
        OP_AND   : y[g] = a[g] & b[g];
        OP_OR    : y[g] = a[g] | b[g];
        OP_XOR   : y[g] = a[g] ^ b[g];
        OP_NOT   : y[g] = ~a[g];
        OP_SHL   : y[g] = a[g] << sh;
        OP_SHR   : y[g] = a[g] >> sh;                    // logical
        OP_SAR   : y[g] = sar;                           // explicit signed cast
        OP_MUL   : y[g] = a[g] * b[g];                   // low 32 (bootstrap)
        OP_MIN   : y[g] = ($signed(a[g]) <  $signed(b[g])) ? a[g] : b[g];
        OP_MAX   : y[g] = ($signed(a[g]) >= $signed(b[g])) ? a[g] : b[g];
        default  : y[g] = 32'd0;
      endcase
      if (fp_sel) y[g] = fp_y[g];
    end
  end endgenerate

endmodule
