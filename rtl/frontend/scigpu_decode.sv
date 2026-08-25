// SciGPU M2 — combinational scalar decoder (MICRO-001 §1.8, directive §35)
// Decodes exactly the M2 ISA subset (ISA-001 Rev1.2 §1.6 of MICRO-001).
// Unknown/reserved formats or opcodes assert illegal_* -> FAULT_ILLEGAL_OPCODE.
// No "default to NOP" behaviour exists.
module scigpu_decode (
  input  logic [63:0] insn,

  output logic        legal,            // instruction is in the M2 subset
  output scigpu_types_pkg::iclass_e cls,
  output logic [7:0]  dst,
  output logic [7:0]  src0,
  output logic [7:0]  src1,
  output logic        use_imm,
  output logic [31:0] imm,              // sign-extended SIMM24
  output logic signed [23:0] disp24,
  output logic [7:0]  cond,
  output logic [7:0]  getid_sel,
  output logic [7:0]  getid_dst
);

  import scigpu_isa_pkg::*;

  logic [11:0] opc;
  logic [3:0]  fmt;

  assign opc    = insn[63:52];
  assign fmt    = insn[51:48];

  assign dst    = insn[47:40];
  assign src0   = insn[39:32];
  assign src1   = insn[31:24];
  assign imm    = {{8{insn[31]}}, insn[31:8]};          // SIMM24 -> 32 b sign-ext
  assign disp24 = insn[47:24];                          // used as signed
  assign cond   = insn[23:16];
  assign getid_sel = insn[7:0];
  assign getid_dst = insn[15:8];

  wire is_srr = (fmt == FMT_SRR);
  wire is_sri = (fmt == FMT_SRI);
  wire is_br  = (fmt == FMT_BR);
  wire is_sys = (fmt == FMT_SYS);

  // opcode decode (M2 subset only)
  logic mov_r, mov_i, add_r, add_i, sub_r, sub_i, mul_r, and_r, or_r, xor_r,
        not_r, shl_r, shl_i, shr_r, shr_i, sar_r, sar_i,
        cmp_eq, cmp_lt, cmp_gt, bra, bra_c, getid, nop, ret;

  assign mov_r  = (opc == OPC_S_MOV)  && is_srr;
  assign mov_i  = (opc == OPC_S_MOV)  && is_sri;
  assign add_r  = (opc == OPC_S_ADD)  && is_srr;
  assign add_i  = (opc == OPC_S_ADD)  && is_sri;
  assign sub_r  = (opc == OPC_S_SUB)  && is_srr;
  assign sub_i  = (opc == OPC_S_SUB)  && is_sri;
  assign mul_r  = (opc == OPC_S_MUL)  && is_srr;
  assign and_r  = (opc == OPC_S_AND)  && is_srr;
  assign or_r   = (opc == OPC_S_OR)   && is_srr;
  assign xor_r  = (opc == OPC_S_XOR)  && is_srr;
  assign not_r  = (opc == OPC_S_NOT)  && is_srr;
  assign shl_r  = (opc == OPC_S_SHL)  && is_srr;
  assign shl_i  = (opc == OPC_S_SHL)  && is_sri;
  assign shr_r  = (opc == OPC_S_SHR)  && is_srr;
  assign shr_i  = (opc == OPC_S_SHR)  && is_sri;
  assign sar_r  = (opc == OPC_S_SAR)  && is_srr;
  assign sar_i  = (opc == OPC_S_SAR)  && is_sri;
  assign cmp_eq = (opc == OPC_S_CMP_EQ) && is_srr;
  assign cmp_lt = (opc == OPC_S_CMP_LT) && is_srr;
  assign cmp_gt = (opc == OPC_S_CMP_GT) && is_srr;
  assign bra    = ((opc == OPC_S_BRA) || (opc == OPC_BRA_V)) && is_br;
  assign bra_c  = (opc == OPC_S_BRA_COND) && is_br;
  assign getid  = (opc == OPC_S_GETID) && is_sys;
  assign nop    = (opc == OPC_NOP)      && is_sys;
  assign ret    = (opc == OPC_RET_KERNEL_WF) && is_br;

  always_comb begin
    legal = 1'b0;
    cls   = scigpu_types_pkg::CLS_NONE;
    use_imm = 1'b0;
    if (mov_r) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_MOV;
    end else if (and_r || or_r || xor_r || not_r ||
        shl_r || shr_r || sar_r) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_ALU;
    end else if (mov_i) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_MOV; use_imm = 1'b1;
    end else if (add_r || sub_r) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_ALU;
    end else if (add_i || sub_i || shl_i || shr_i || sar_i) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_ALU; use_imm = 1'b1;
    end else if (mul_r) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_MUL;
    end else if (cmp_eq || cmp_lt || cmp_gt) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_CMP;
    end else if (bra) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_BRA;
    end else if (bra_c) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_BRA_C;
    end else if (getid) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_GETID;
    end else if (nop) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_NOP;
    end else if (ret) begin
      legal = 1'b1; cls = scigpu_types_pkg::CLS_RET;
    end
  end

endmodule
