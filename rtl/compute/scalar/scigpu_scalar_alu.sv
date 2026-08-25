// SciGPU M2 — scalar ALU (MICRO-001 §1.6/§1.7, directive §28)
// All arithmetic explicitly 32-bit. Shifts masked by [4:0].
// SAR uses an explicit signed cast (no reliance on inference).
module scigpu_scalar_alu (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [3:0]  op,          // alu_op_e below
  output logic [31:0] y
);

  // operation select (local to M2; decode maps instruction -> op)
  localparam bit [3:0] ALU_PASS_B = 4'd0;   // MOV reg / immediate path
  localparam bit [3:0] ALU_ADD    = 4'd1;
  localparam bit [3:0] ALU_SUB    = 4'd2;
  localparam bit [3:0] ALU_AND    = 4'd3;
  localparam bit [3:0] ALU_OR     = 4'd4;
  localparam bit [3:0] ALU_XOR    = 4'd5;
  localparam bit [3:0] ALU_NOT    = 4'd6;
  localparam bit [3:0] ALU_SHL    = 4'd7;
  localparam bit [3:0] ALU_SHR    = 4'd8;
  localparam bit [3:0] ALU_SAR    = 4'd9;
  localparam bit [3:0] ALU_MUL    = 4'd10;  // functional bootstrap multiplier

  wire [4:0] sh = b[4:0];
  logic [31:0] sar_res;
  always_comb sar_res = $unsigned($signed(a) >>> sh);   // explicit signed SAR

  always_comb begin
    unique case (op)
      ALU_PASS_B: y = b;
      ALU_ADD   : y = a + b;
      ALU_SUB   : y = a - b;
      ALU_AND   : y = a & b;
      ALU_OR    : y = a | b;
      ALU_XOR   : y = a ^ b;
      ALU_NOT   : y = ~a;
      ALU_SHL   : y = a << sh;
      ALU_SHR   : y = a >> sh;                 // logical
      ALU_SAR   : y = sar_res;                 // arithmetic (explicit cast)
      ALU_MUL   : y = a * b;                   // low 32 bits (bootstrap)
      default   : y = 32'd0;
    endcase
  end

endmodule
