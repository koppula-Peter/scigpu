// SciGPU M3 — unified scalar/vector decoder (MICRO-001 §2; directive §57, §120)
// Unknown/reserved formats and opcodes are ILLEGAL (no NOP defaulting).
// Vector VMOD: only PRED may be nonzero for M3 integer instructions.
module scigpu_decode_m3 (
  input  logic [63:0] insn,

  output logic        legal,
  output logic        is_vector,
  output scigpu_types_pkg::iclass_e cls,     // scalar classes reused
  output logic [4:0]  va_op,                 // vector ALU op (va_op_e below)
  output logic [1:0]  va_bmux,               // operand-B select
  output logic [7:0]  dst,                   // SGPR dst (scalar)
  output logic [7:0]  src0, src1,
  output logic [7:0]  vd, vs0, vs1,          // VGPR indices / bcast SGPR in vs0
  output logic        use_imm,
  output logic [31:0] imm,
  output logic signed [23:0] disp24,
  output logic [7:0]  cond,
  output logic [7:0]  getid_sel, getid_dst,
  output logic [3:0]  pred
);

  import scigpu_isa_pkg::*;

  logic [11:0] opc;
  wire [3:0] fmt = insn[51:48];

  assign opc = insn[63:52];

  assign dst   = insn[47:40];
  assign src0  = insn[39:32];
  assign src1  = insn[31:24];
  assign vd    = insn[47:40];
  assign vs0   = insn[39:32];
  assign vs1   = insn[31:24];
  // Per-format immediate layouts (ISA-001 §5.2):
  //   FMT_VRI : SIMM16 @ [31:16]
  //   FMT_SRI : SIMM24 @ [31:8]
  assign imm   = (fmt == FMT_VRI) ? {{16{insn[31]}}, insn[31:16]}
                                  : {{8{insn[31]}}, insn[31:8]};
  assign disp24= insn[47:24];
  assign cond  = insn[23:16];
  assign getid_sel = insn[7:0];
  assign getid_dst = insn[15:8];
  // Predicate field exists only on vector formats; scalar/system/branch
  // instructions are architecturally unpredicated (Rev1.3 §5.2).
  wire       vecfmt = (fmt == FMT_VRR) || (fmt == FMT_VRI);
  assign pred  = vecfmt ? insn[15:12] : 4'hF;

  // ---------------- scalar decode (identical semantics to M2) ---------------
  wire srr=(fmt==FMT_SRR), sri=(fmt==FMT_SRI), brf=(fmt==FMT_BR),
       sysf=(fmt==FMT_SYS);
  wire mov_r =(opc==OPC_S_MOV)&&srr,  mov_i =(opc==OPC_S_MOV)&&sri;
  wire add_r =(opc==OPC_S_ADD)&&srr,  add_i =(opc==OPC_S_ADD)&&sri;
  wire sub_r =(opc==OPC_S_SUB)&&srr,  sub_i =(opc==OPC_S_SUB)&&sri;
  wire mul_r =(opc==OPC_S_MUL)&&srr;
  wire and_r =(opc==OPC_S_AND)&&srr,  or_r  =(opc==OPC_S_OR)&&srr;
  wire xor_r =(opc==OPC_S_XOR)&&srr,  not_r =(opc==OPC_S_NOT)&&srr;
  wire shl_r =(opc==OPC_S_SHL)&&srr,  shl_i =(opc==OPC_S_SHL)&&sri;
  wire shr_r =(opc==OPC_S_SHR)&&srr,  shr_i =(opc==OPC_S_SHR)&&sri;
  wire sar_r =(opc==OPC_S_SAR)&&srr,  sar_i =(opc==OPC_S_SAR)&&sri;
  wire cmp_ez=(opc==OPC_S_CMP_EQ)&&srr, cmp_lt=(opc==OPC_S_CMP_LT)&&srr,
       cmp_gt=(opc==OPC_S_CMP_GT)&&srr;
  wire bra   =((opc==OPC_S_BRA)||(opc==OPC_BRA_V))&&brf;
  wire bra_c =(opc==OPC_S_BRA_COND)&&brf;
  wire getid =(opc==OPC_S_GETID)&&sysf;
  wire nop   =(opc==OPC_NOP)&&sysf;
  wire ret   =(opc==OPC_RET_KERNEL_WF)&&brf;

  // ---------------- vector decode (M3 subset) --------------------------------
  wire vfmt = (fmt == FMT_VRR) || (fmt == FMT_VRI);
  wire vmov  =(opc==OPC_V_MOV)&&vfmt,  vmovi =(opc==OPC_V_MOVI)&&vfmt;
  wire vbcast=(opc==OPC_V_BCAST)&&vfmt,vllane=(opc==OPC_V_LLANE)&&vfmt;
  wire vadd  =(opc==OPC_V_ADD)&&vfmt,  vsub  =(opc==OPC_V_SUB)&&vfmt;
  wire vmul  =(opc==OPC_V_MUL)&&vfmt;
  wire vand  =(opc==OPC_V_AND)&&vfmt,  vor   =(opc==OPC_V_OR)&&vfmt;
  wire vxor  =(opc==OPC_V_XOR)&&vfmt;
  wire vshl  =(opc==OPC_V_SHL)&&vfmt,  vshr  =(opc==OPC_V_SHR)&&vfmt;
  wire vsar  =(opc==OPC_V_SAR)&&vfmt;

  wire v_any = vmov|vmovi|vbcast|vllane|vadd|vsub|vmul|vand|vor|vxor|vshl|vshr|vsar;
  wire vmod_ok = (insn[11:0] == 12'd0);        // TYPESEL/ROUND/SAT/ABS/NEG/FLAGS = 0

  // ---------------- classify --------------------------------------------------
  always_comb begin
    legal = 1'b0; is_vector = 1'b0; use_imm = (fmt == FMT_VRI);
    cls = scigpu_types_pkg::CLS_NONE; va_op = 5'd0; va_bmux = 2'd0;
    if (v_any) begin
      legal = vmod_ok;                       // unsupported VMOD -> illegal
      is_vector = 1'b1;
      case (opc)
        OPC_V_MOV : begin cls=scigpu_types_pkg::CLS_VEC_PASS; va_op=5'd0;
                           va_bmux=(fmt==FMT_VRI)?2'd1:2'd2; end   // BM_IMM/BM_VS0
        OPC_V_MOVI: begin cls=scigpu_types_pkg::CLS_VEC_PASS; va_op=5'd0;
                           va_bmux=2'd1; end
        OPC_V_BCAST:begin cls=scigpu_types_pkg::CLS_VEC_PASS; va_op=5'd0;
                           va_bmux=2'd3; end
        OPC_V_LLANE:begin cls=scigpu_types_pkg::CLS_VEC_LLANE; va_op=5'd11;
                           va_bmux=2'd0; end
        OPC_V_ADD : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd1; va_bmux=2'd0; end
        OPC_V_SUB : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd2; va_bmux=2'd0; end
        OPC_V_MUL : begin cls=scigpu_types_pkg::CLS_VEC_MUL; va_op=5'd10; va_bmux=2'd0; end
        OPC_V_AND : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd3; va_bmux=2'd0; end
        OPC_V_OR  : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd4; va_bmux=2'd0; end
        OPC_V_XOR : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd5; va_bmux=2'd0; end
        OPC_V_SHL : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd7; va_bmux=2'd0; end
        OPC_V_SHR : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd8; va_bmux=2'd0; end
        OPC_V_SAR : begin cls=scigpu_types_pkg::CLS_VEC_ALU; va_op=5'd9; va_bmux=2'd0; end
        default: ;
      endcase
      if (fmt == FMT_VRI) va_bmux = 2'd1;    // immediate form overrides
    end else begin
      if (mov_r||shl_r||shr_r||sar_r) begin legal=1'b1; cls=scigpu_types_pkg::CLS_ALU; end
      else if (mov_i) begin legal=1'b1; cls=scigpu_types_pkg::CLS_MOV; use_imm=1'b1; end
      else if (add_r||sub_r) begin legal=1'b1; cls=scigpu_types_pkg::CLS_ALU; end
      else if (add_i||sub_i||shl_i||shr_i||sar_i) begin
        legal=1'b1; cls=scigpu_types_pkg::CLS_ALU; use_imm=1'b1;
      end
      else if (mul_r) begin legal=1'b1; cls=scigpu_types_pkg::CLS_MUL; end
      else if (and_r||or_r||xor_r||not_r) begin legal=1'b1; cls=scigpu_types_pkg::CLS_ALU; end
      else if (cmp_ez||cmp_lt||cmp_gt) begin legal=1'b1; cls=scigpu_types_pkg::CLS_CMP; end
      else if (bra)    begin legal=1'b1; cls=scigpu_types_pkg::CLS_BRA; end
      else if (bra_c)  begin legal=1'b1; cls=scigpu_types_pkg::CLS_BRA_C; end
      else if (getid)  begin legal=1'b1; cls=scigpu_types_pkg::CLS_GETID; end
      else if (nop)    begin legal=1'b1; cls=scigpu_types_pkg::CLS_NOP; end
      else if (ret)    begin legal=1'b1; cls=scigpu_types_pkg::CLS_RET; end
    end
  end

endmodule
