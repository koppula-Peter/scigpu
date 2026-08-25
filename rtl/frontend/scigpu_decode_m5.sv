// SciGPU M5 — unified decoder with divergence-control + vector-compare classes
// (MICRO-001 Rev0.4 §4; ISA-001 Rev1.4 §16). Used by scigpu_m5_cu.
// Legacy M2/M3 classes decode identically to scigpu_decode_m3 (superset).
// VFCMP.* (FP ordered compares) remain ILLEGAL in RTL at M5 (directive §99:
// integer comparisons only); golden-model-only until an FP milestone needs them.
module scigpu_decode_m5 (
  input  logic [63:0] insn,

  output logic        legal,
  output logic        is_vector,                 // engine-routed vector ALU
  output logic        is_ctrl,                   // mask-control family
  output logic        is_vcmp,                   // vector compare (predicate wr)
  output logic [3:0]  ctrl_op,                   // ctrl_op_e encoding
  output scigpu_types_pkg::iclass_e cls,
  output logic [4:0]  va_op,
  output logic [1:0]  va_bmux,
  output logic [7:0]  dst,
  output logic [7:0]  src0, src1,
  output logic [7:0]  vd, vs0, vs1,
  output logic [7:0]  vs2,
  output logic        use_imm,
  output logic [31:0] imm,
  output logic signed [23:0] disp24,
  output logic [15:0] bmod16,                    // CBRANCH_IF reconv payload
  output logic [3:0]  cond4,                     // control-condition selector
  output logic [7:0]  cond,                      // legacy scalar branch cond
  output logic [7:0]  getid_sel, getid_dst,
  output logic [3:0]  pred,
  output logic [3:0]  pdst                       // VCMP predicate destination
);

  import scigpu_isa_pkg::*;
  import scigpu_types_pkg::*;

  // ctrl_op_e — mask-control engine command encoding
  localparam bit [3:0] CT_CBRANCH=4'd0, CT_RECONV =4'd1, CT_LOOPB=4'd2,
                       CT_LOOPE  =4'd3, CT_BREAK  =4'd4, CT_CONT =4'd5,
                       CT_PUSHM  =4'd6, CT_POPM   =4'd7, CT_SETM =4'd8,
                       CT_ANDM   =4'd9, CT_ORM    =4'd10, CT_XORM=4'd11,
                       CT_RETW   =4'd12;

  wire [11:0] opc = insn[63:52];
  wire [3:0]  fmt = insn[51:48];

  assign dst   = insn[47:40];
  assign src0  = insn[39:32];
  assign src1  = insn[31:24];
  // FMT9 PCMP relocates the register fields: [47:44]PDST [43:36]VSRC0
  // [35:28]VSRC1 (ISA-001 s5.2)
  assign vd    = insn[47:40];
  assign vs0   = (fmt == FMT_PCMP) ? insn[43:36] : insn[39:32];
  assign vs1   = (fmt == FMT_PCMP) ? insn[35:28] : insn[31:24];
  // FMA third source rides VRR VS2 @[23:16] (overlaps imm low half)
  assign vs2   = insn[23:16];
  assign imm   = (fmt == FMT_VRI) ? {{16{insn[31]}}, insn[31:16]}
                                  : {{8{insn[31]}}, insn[31:8]};
  assign disp24= insn[47:24];
  assign bmod16= insn[15:0];
  assign cond  = insn[23:16];
  assign cond4 = insn[23:20];
  assign getid_sel = insn[7:0];
  assign getid_dst = insn[15:8];
  wire       vecfmt = (fmt == FMT_VRR) || (fmt == FMT_VRI);
  assign pred  = vecfmt ? insn[15:12] : 4'hF;
  assign pdst  = insn[47:44];

  // ---------------- scalar (identical to M2/M3) ------------------------------
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

  // ---------------- vector ALU / moves (M3 subset) ---------------------------
  wire vfmt = (fmt == FMT_VRR) || (fmt == FMT_VRI);
  wire vmov  =(opc==OPC_V_MOV)&&vfmt,  vmovi =(opc==OPC_V_MOVI)&&vfmt;
  wire vbcast=(opc==OPC_V_BCAST)&&vfmt,vllane=(opc==OPC_V_LLANE)&&vfmt;
  wire vadd  =(opc==OPC_V_ADD)&&vfmt,  vsub  =(opc==OPC_V_SUB)&&vfmt;
  wire vmul  =(opc==OPC_V_MUL)&&vfmt;
  wire vand  =(opc==OPC_V_AND)&&vfmt,  vor   =(opc==OPC_V_OR)&&vfmt;
  wire vxor  =(opc==OPC_V_XOR)&&vfmt;
  wire vshl  =(opc==OPC_V_SHL)&&vfmt,  vshr  =(opc==OPC_V_SHR)&&vfmt;
  wire vfadd =(opc==12'h400)&&vfmt, vfsub=(opc==12'h401)&&vfmt,
       vfmul =(opc==12'h402)&&vfmt, vfma =(opc==12'h403)&&vfmt,
       vfcvt_i=(opc==12'h460)&&vfmt, vfcvt_f=(opc==12'h461)&&vfmt;
  wire vsar  =(opc==OPC_V_SAR)&&vfmt;
  wire vmin  =(opc==OPC_V_MIN)&&vfmt, vmax=(opc==OPC_V_MAX)&&vfmt;
  wire v_any = vmov|vmovi|vbcast|vllane|vadd|vsub|vmul|vand|vor|vxor|vshl|vshr|vsar|
               vmin|vmax|vfadd|vfsub|vfmul|vfma|vfcvt_i|vfcvt_f;
  wire vmod_ok = (insn[11:0] == 12'd0);

  // ---------------- M5 vector compare (integer, FMT9) ------------------------
  wire pcmpf = (fmt == FMT_PCMP);
  wire vc_eq  =(opc==OPC_VCMP_EQ )&&pcmpf;
  wire vc_neq =(opc==OPC_VCMP_NEQ)&&pcmpf;
  wire vc_lt  =(opc==OPC_VCMP_LT )&&pcmpf;
  wire vc_le  =(opc==OPC_VCMP_LE )&&pcmpf;
  wire vc_gt  =(opc==OPC_VCMP_GT )&&pcmpf;
  wire vc_ge  =(opc==OPC_VCMP_GE )&&pcmpf;
  wire vc_any = vc_eq|vc_neq|vc_lt|vc_le|vc_gt|vc_ge;
  // compare-slice op: {1(mode), invert, kind} kind:00 EQ 01 LT(s) 10 LE(s)
  wire [4:0] vc_op = vc_eq  ? 5'b01000 :
                     vc_neq ? 5'b01100 :
                     vc_lt  ? 5'b01001 :
                     vc_ge  ? 5'b01101 :
                     vc_le  ? 5'b01010 :
                              5'b01110 ;   // GT

  // ---------------- M5 divergence-control family (FMT5) ----------------------
  wire c_cbranch=(opc==OPC_CBRANCH_IF)&&brf;
  wire c_reconv =(opc==OPC_RECONV)&&brf;
  wire c_pushm  =(opc==OPC_PUSHM)&&brf;
  wire c_popm   =(opc==OPC_POPM)&&brf;
  wire c_setm   =(opc==OPC_SETM)&&brf;
  wire c_andm   =(opc==OPC_ANDM)&&brf;
  wire c_orm    =(opc==OPC_ORM)&&brf;
  wire c_xorm   =(opc==OPC_XORM)&&brf;
  wire c_loopb  =(opc==OPC_LOOP_BEGIN)&&brf;
  wire c_loope  =(opc==OPC_LOOP_END)&&brf;
  wire c_break  =(opc==OPC_BREAK)&&brf;
  wire c_cont   =(opc==OPC_CONTINUE)&&brf;
  wire c_retw   =(opc==OPC_RET_KERNEL_WF)&&brf;      // now CONTROL-classified
  wire c_any    = c_cbranch|c_reconv|c_pushm|c_popm|c_setm|c_andm|c_orm|
                  c_xorm|c_loopb|c_loope|c_break|c_cont|c_retw;

  wire [3:0] ctrl_op_w =
      c_cbranch ? CT_CBRANCH : c_reconv ? CT_RECONV :
      c_pushm   ? CT_PUSHM   : c_popm   ? CT_POPM   :
      c_setm    ? CT_SETM    : c_andm   ? CT_ANDM   :
      c_orm     ? CT_ORM     : c_xorm   ? CT_XORM   :
      c_loopb   ? CT_LOOPB   : c_loope  ? CT_LOOPE  :
      c_break   ? CT_BREAK   : c_cont   ? CT_CONT   : CT_RETW;

  // ---------------- classify -------------------------------------------------
  always_comb begin
    legal = 1'b0; is_vector = 1'b0; is_ctrl = 1'b0; is_vcmp = 1'b0;
    use_imm = (fmt == FMT_VRI);
    ctrl_op = '0; va_op = 5'd00; va_bmux = 2'd0;
    cls = CLS_NONE;
    if (v_any) begin
      legal = vmod_ok;
      is_vector = 1'b1;
      case (opc)
        OPC_V_MOV : begin cls=CLS_VEC_PASS; va_op=5'd00;
                          va_bmux=(fmt==FMT_VRI)?2'd1:2'd2; end
        OPC_V_MOVI: begin cls=CLS_VEC_PASS; va_op=5'd00; va_bmux=2'd1; end
        OPC_V_BCAST:begin cls=CLS_VEC_PASS; va_op=5'd00; va_bmux=2'd3; end
        OPC_V_LLANE:begin cls=CLS_VEC_LLANE; va_op=5'd011; va_bmux=2'd0; end
        OPC_V_ADD : begin cls=CLS_VEC_ALU; va_op=5'd01; va_bmux=2'd0; end
        OPC_V_SUB : begin cls=CLS_VEC_ALU; va_op=5'd02; va_bmux=2'd0; end
        OPC_V_MUL : begin cls=CLS_VEC_MUL; va_op=5'd010; va_bmux=2'd0; end
        OPC_V_AND : begin cls=CLS_VEC_ALU; va_op=5'd03; va_bmux=2'd0; end
        OPC_V_OR  : begin cls=CLS_VEC_ALU; va_op=5'd04; va_bmux=2'd0; end
        OPC_V_XOR : begin cls=CLS_VEC_ALU; va_op=5'd05; va_bmux=2'd0; end
        OPC_V_SHL : begin cls=CLS_VEC_ALU; va_op=5'd07; va_bmux=2'd0; end
        OPC_V_SHR : begin cls=CLS_VEC_ALU; va_op=5'd08; va_bmux=2'd0; end
        OPC_VF_ADD : begin cls=CLS_VEC_ALU; va_op=5'd16;
                           if (fmt == FMT_VRI) va_bmux = 2'd1; end
        OPC_VF_SUB : begin cls=CLS_VEC_ALU; va_op=5'd17;
                           if (fmt == FMT_VRI) va_bmux = 2'd1; end
        OPC_VF_MUL : begin cls=CLS_VEC_ALU; va_op=5'd18;
                           if (fmt == FMT_VRI) va_bmux = 2'd1; end
        OPC_VF_FMA : begin cls=CLS_VEC_ALU; va_op=5'd21; va_bmux=2'd0; end
        OPC_VCVT_F32_I32 : begin cls=CLS_VEC_ALU; va_op=5'd19; va_bmux=2'd2; end
        OPC_VCVT_I32_F32 : begin cls=CLS_VEC_ALU; va_op=5'd20; va_bmux=2'd2; end
        OPC_V_SAR : begin cls=CLS_VEC_ALU; va_op=5'd09; va_bmux=2'd0; end
        OPC_V_MIN : begin cls=CLS_VEC_ALU; va_op=5'd013; va_bmux=2'd0; end
        OPC_V_MAX : begin cls=CLS_VEC_ALU; va_op=5'd014; va_bmux=2'd0; end
        default: ;
      endcase
      if (fmt == FMT_VRI) va_bmux = 2'd1;
    end else if (vc_any) begin
      legal = 1'b1;
      is_vcmp = 1'b1;
      cls = CLS_VCMP;
      va_op = vc_op;
    end else if (c_any) begin
      legal = 1'b1;
      is_ctrl = 1'b1;
      cls = CLS_CTRL;
      ctrl_op = ctrl_op_w;
    end else begin
      if (mov_r||shl_r||shr_r||sar_r) begin legal=1'b1; cls=CLS_ALU; end
      else if (mov_i) begin legal=1'b1; cls=CLS_MOV; use_imm=1'b1; end
      else if (add_r||sub_r) begin legal=1'b1; cls=CLS_ALU; end
      else if (add_i||sub_i||shl_i||shr_i||sar_i) begin
        legal=1'b1; cls=CLS_ALU; use_imm=1'b1;
      end
      else if (mul_r) begin legal=1'b1; cls=CLS_MUL; end
      else if (and_r||or_r||xor_r||not_r) begin legal=1'b1; cls=CLS_ALU; end
      else if (cmp_ez||cmp_lt||cmp_gt) begin legal=1'b1; cls=CLS_CMP; end
      else if (bra)    begin legal=1'b1; cls=CLS_BRA; end
      else if (bra_c)  begin legal=1'b1; cls=CLS_BRA_C; end
      else if (getid)  begin legal=1'b1; cls=CLS_GETID; end
      else if (nop)    begin legal=1'b1; cls=CLS_NOP; end
      // RET_KERNEL_WF handled in the c_any control branch above (M5 semantics)
    end
  end


`ifdef SCIGPU_M5_DBG
  always_comb begin
    if (insn[63:52] == OPC_CBRANCH_IF)
      $display("M5DEC %0t insn=%h cond4=%0d", $time, insn, cond4);
  end
`endif
endmodule
