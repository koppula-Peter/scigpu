// SciGPU M3 — unified scalar/vector control FSM (MICRO-001 §1.3 + §2)
// Scalar path: M2 semantics unchanged. Vector path: SETUP -> RUN (II=1 beat/cyc);
// retire only after final beat commit. Zero-EXEC launch retires cleanly (§19).
// Faults before beat 0: no partial vector execution (§119).
module scigpu_m3_control #(
  parameter int unsigned SGPR_COUNT = 64,
  parameter int unsigned VGPR_COUNT = 32
) (
  input  logic        clk,
  input  logic        rst,

  // launch
  input  logic        start_valid,
  output logic        start_ready,
  input  logic [63:0] start_entry_pc,
  input  logic [63:0] start_code_words,
  input  logic [31:0] start_wg_x,
  input  logic [31:0] start_exec_mask,
  input  logic [8:0]  start_vgpr_req,
  input  logic [8:0]  start_sgpr_req,

  // fetch engine
  output logic        f_cmd_valid,
  output logic [63:0] f_cmd_pc,
  input  logic        f_req_accepted,
  input  logic        f_rsp_valid,
  input  logic [63:0] f_rsp_insn,
  input  logic        f_rsp_error,
  output logic        f_rsp_ready,

  // SGPR file
  output logic        sgpr_init_ready,
  output logic [7:0]  sgpr_raddr0,
  output logic [7:0]  sgpr_raddr1,
  input  logic [31:0] sgpr_rdata0,
  input  logic [31:0] sgpr_rdata1,
  input  logic        sgpr_rinv0,
  input  logic        sgpr_rinv1,
  output logic        sgpr_we,
  output logic [7:0]  sgpr_waddr,
  output logic [31:0] sgpr_wdata,

  // predicate file
  output logic        pred_init_ready,
  input  logic [31:0] pred_rd_data,

  // vector engine
  output logic        vec_setup_valid,
  input  logic        vec_setup_ready,
  output logic [4:0]  vec_op,
  output logic [1:0]  vec_bmux,
  output logic [7:0]  vec_vd,
  output logic [7:0]  vec_vs0,
  output logic [7:0]  vec_vs1,
  output logic [31:0] vec_imm,
  output logic [31:0] vec_bcast_data,
  output logic [31:0] vec_effective_mask,
  input  logic        vec_last_commit,

  // completion
  output logic        completion_valid,
  input  logic        completion_ready,
  output logic        completion_fault,
  output logic [5:0]  completion_fault_code,
  output logic [63:0] completion_pc,
  output logic [63:0] completion_retired_count,

  // retire trace (flat; directive §66)
  output logic        trace_valid,
  output logic [63:0] trace_pc,
  output logic [63:0] trace_insn,
  output logic        trace_sgpr_we,
  output logic [7:0]  trace_sgpr_addr,
  output logic [31:0] trace_sgpr_wdata,
  output logic [3:0]  trace_sc_flags,
  output logic        trace_scc,
  output logic        trace_branch_taken,
  output logic [63:0] trace_next_pc,
  output logic        trace_fault_o,
  output logic [5:0]  trace_fault_code_o,
  output logic [31:0] trace_exec_mask,
  output logic [3:0]  trace_pred_idx,
  output logic [31:0] trace_effective_mask,
  output logic        trace_vgpr_we,
  output logic [7:0]  trace_vgpr_addr,
  output logic [31:0] trace_vgpr_write_mask,

  // debug
  output logic [63:0] dbg_pc,
  output logic [31:0] dbg_exec_mask,
  output logic [3:0]  dbg_pred_idx,
  output logic [31:0] dbg_effective_mask,
  output logic        dbg_vgpr_we,
  output logic [7:0]  dbg_vgpr_addr,
  output logic [31:0] dbg_vgpr_write_mask,
  output scigpu_types_pkg::state_e dbg_state
);

  import scigpu_isa_pkg::*;
  import scigpu_types_pkg::*;

  state_e       st;
  logic [63:0]  pc_q, code_words_q;
  logic [63:0]  unused_code_words_q;
  logic         unused_d_legal, unused_d_is_vec;
  logic [31:0]  wg_x_q;
  logic [31:0]  exec_q;
  logic [8:0]   vgpr_req_q, sgpr_req_q;
  logic [8:0]   unused_vgpr_req_q, unused_sgpr_req_q;
  logic [63:0]  retired_q;
  logic [5:0]   fault_code_q;
  logic [63:0]  compl_pc_q;
  logic         compl_fault_q;
  logic [3:0]   flags_q;
  logic         scc_q;
  logic [63:0]  insn_q;

  logic         d_legal, d_is_vec;

  iclass_e      d_cls;
  logic [4:0]   d_va_op;  logic [1:0] d_va_bmux;
  logic [7:0]   d_dst, d_src0, d_src1;
  logic [7:0]   d_vd, d_vs0, d_vs1;
  logic         d_useimm;
  logic [31:0]  d_imm;
  logic signed [23:0] d_disp;
  logic [7:0]   d_cond;
  logic [3:0]   d_pred;

  logic         x_fault;
  logic [5:0]   x_fcode;
  logic         unused_x_fault;                     // consumed below (debug)
  logic [5:0]   unused_x_fcode;
  logic         x_we, x_br;
  logic [7:0]   x_wa;
  logic [31:0]  x_wd;
  logic [3:0]   x_flags;
  logic         x_scc;
  logic [63:0]  x_next_pc;
  logic         x_is_ret;
  logic [31:0]  x_exec;
  logic [3:0]   x_pred;
  logic [31:0]  x_eff;

  wire [11:0] opc = insn_q[63:52];
  wire [7:0]  dbg_getid_sel;
  wire [7:0]  dbg_getid_dst;   // driven solely by u_dec

  // ---------------- decode (registered out of DECODE) ------------------------
  logic         c_legal, c_isvec;
  iclass_e      c_cls;
  logic [4:0]   c_va_op;  logic [1:0] c_va_bmux;
  logic [7:0]   c_dst, c_src0, c_src1;
  logic [7:0]   c_vd, c_vs0, c_vs1;
  logic         c_useimm;
  logic [31:0]  c_imm;
  logic signed [23:0] c_disp;
  logic [7:0]   c_cond;
  logic [3:0]   c_pred;

  scigpu_decode_m3 u_dec (
    .insn(insn_q), .legal(c_legal), .is_vector(c_isvec), .cls(c_cls),
    .va_op(c_va_op), .va_bmux(c_va_bmux),
    .dst(c_dst), .src0(c_src0), .src1(c_src1),
    .vd(c_vd), .vs0(c_vs0), .vs1(c_vs1),
    .use_imm(c_useimm), .imm(c_imm), .disp24(c_disp), .cond(c_cond),
    .getid_sel(dbg_getid_sel), .getid_dst(dbg_getid_dst), .pred(c_pred)
  );

  // ---------------- scalar execute -------------------------------------------
  localparam logic [3:0] PRED_NONE4 = PRED_NONE[3:0];
  localparam bit [3:0] ALU_PASS_B=4'd0, ALU_ADD=4'd1, ALU_SUB=4'd2, ALU_AND=4'd3,
                       ALU_OR=4'd4, ALU_XOR=4'd5, ALU_NOT=4'd6, ALU_SHL=4'd7,
                       ALU_SHR=4'd8, ALU_SAR=4'd9, ALU_MUL=4'd10;

  logic [3:0]  alu_op;
  logic [31:0] alu_a, alu_b, alu_y;

  always_comb begin
    case (opc)
      OPC_S_ADD: alu_op=ALU_ADD;
      OPC_S_SUB: alu_op=ALU_SUB;
      OPC_S_AND: alu_op=ALU_AND;
      OPC_S_OR : alu_op=ALU_OR;
      OPC_S_XOR: alu_op=ALU_XOR;
      OPC_S_NOT: alu_op=ALU_NOT;
      OPC_S_SHL: alu_op=ALU_SHL;
      OPC_S_SHR: alu_op=ALU_SHR;
      OPC_S_SAR: alu_op=ALU_SAR;
      OPC_S_MUL: alu_op=ALU_MUL;
      default  : alu_op=ALU_PASS_B;
    endcase
  end

  always_comb begin
    alu_a = sgpr_rdata0;
    alu_b = c_useimm ? c_imm : sgpr_rdata1;
    if ((c_cls==CLS_MOV) && !c_useimm) alu_b = sgpr_rdata0;
    if ((c_cls==CLS_MOV) &&  c_useimm) alu_b = c_imm;
    if (c_cls==CLS_GETID) begin alu_a='0; alu_b=wg_x_q; end
  end

  scigpu_scalar_alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

  wire [31:0] cmp_r = sgpr_rdata0 - sgpr_rdata1;
  logic [1:0] cmp_kind;
  always_comb begin
    case (opc)
      OPC_S_CMP_LT: cmp_kind=2'd1;
      OPC_S_CMP_GT: cmp_kind=2'd2;
      default     : cmp_kind=2'd0;
    endcase
  end
  logic fl_z,fl_n,fl_c,fl_v,fl_scc;
  scigpu_scalar_flags u_flags (.a(sgpr_rdata0), .b(sgpr_rdata1), .r(cmp_r),
    .cmp_kind, .z(fl_z), .n(fl_n), .c(fl_c), .v(fl_v), .scc(fl_scc));

  logic cond_taken, cond_reserved;
  always_comb begin
    cond_reserved = (d_cond >= COND_RESERVED);
    cond_taken = 1'b0;
    case (d_cond)
      COND_ALWAYS: cond_taken=1'b1;
      COND_SCC : cond_taken=scc_q;     COND_NSCC: cond_taken=~scc_q;
      COND_Z   : cond_taken=flags_q[0]; COND_NZ : cond_taken=~flags_q[0];
      COND_N   : cond_taken=flags_q[1]; COND_NN : cond_taken=~flags_q[1];
      COND_C   : cond_taken=flags_q[2]; COND_NC : cond_taken=~flags_q[2];
      COND_V   : cond_taken=flags_q[3]; COND_NV : cond_taken=~flags_q[3];
      COND_LT_S: cond_taken=flags_q[1]^flags_q[3];
      COND_GE_S: cond_taken=~(flags_q[1]^flags_q[3]);
      COND_LT_U: cond_taken=~flags_q[2];
      COND_GE_U: cond_taken= flags_q[2];
      default  : cond_taken=1'b0;
    endcase
  end

  // effective mask captured once per instruction (from registered decode)
  wire [31:0] eff_mask = (d_pred == PRED_NONE4) ? exec_q :
                          (exec_q & pred_rd_data);

  // ---------------- validation ------------------------------------------------
  logic src0_used, src1_used, dst_used;
  always_comb begin
    src0_used=0; src1_used=0; dst_used=0;
    case (d_cls)
      CLS_MOV, CLS_ALU, CLS_MUL, CLS_CMP: begin
        src0_used=1; src1_used=!d_useimm; dst_used=(d_cls!=CLS_CMP); end
      CLS_GETID: dst_used=1;
      default: ;
    endcase
  end
  wire ex_bad_reg = (src0_used && sgpr_rinv0) ||
                    (src1_used && sgpr_rinv1) ||
                    (dst_used && (32'(d_dst) >= 32'(sgpr_req_q)));

  logic v_dst_used, v_s0_used, v_s1_used, v_scalar_used;
  always_comb begin
    v_dst_used=1; v_s0_used=0; v_s1_used=0; v_scalar_used=0;
    case (d_cls)
      CLS_VEC_PASS: begin
        v_s0_used     = (d_va_bmux == 2'd2);   // V_MOV reg,reg reads vs0
        v_scalar_used = (d_va_bmux == 2'd3);   // V_BCAST reads SGPR in vs0
      end
      CLS_VEC_ALU, CLS_VEC_MUL: begin
        v_s0_used=1; v_s1_used=(d_va_bmux==2'd0);
      end
      CLS_VEC_LLANE: ;
      default: ;
    endcase
  end
  wire v_bad_reg = (v_dst_used  && (32'(d_vd)  >= 32'(VGPR_COUNT))) ||
                   (v_s0_used   && (32'(d_vs0) >= 32'(VGPR_COUNT))) ||
                   (v_s1_used   && (32'(d_vs1) >= 32'(VGPR_COUNT))) ||
                   (v_scalar_used && (32'(d_vs0) >= 32'(sgpr_req_q)));

  // ---------------- scalar execute-stage results ------------------------------
  logic         e_fault; logic [5:0] e_fcode;
  logic         e_we; logic [7:0] e_wa; logic [31:0] e_wd;
  logic [3:0]   e_flags; logic e_scc;
  logic         e_br; logic [63:0] e_next_pc; logic e_is_ret;
  wire [63:0]   br_tgt = pc_q + 64'd1 + {{40{d_disp[23]}}, d_disp};

  always_comb begin
    e_fault=0; e_fcode=0; e_we=0; e_wa=d_dst; e_wd=alu_y;
    e_flags=flags_q; e_scc=scc_q; e_br=0; e_next_pc=pc_q+64'd1;
    e_is_ret=(d_cls==CLS_RET);
    if (ex_bad_reg) begin e_fault=1; e_fcode=FAULT_INVALID_REGISTER; end
    else case (d_cls)
      CLS_MOV, CLS_ALU, CLS_MUL: begin e_we=1; e_wa=d_dst; e_wd=alu_y; end
      CLS_GETID: begin
        if (dbg_getid_sel != 8'd0) begin e_fault=1; e_fcode=FAULT_ILLEGAL_OPCODE; end
        else begin e_we=1; e_wa=dbg_getid_dst; e_wd=wg_x_q; end
      end
      CLS_CMP: begin e_flags={fl_v,fl_c,fl_n,fl_z}; e_scc=fl_scc; end
      CLS_BRA: begin e_br=1; e_next_pc=br_tgt; end
      CLS_BRA_C: begin
        if (cond_reserved) begin e_fault=1; e_fcode=FAULT_ILLEGAL_OPCODE; end
        else begin e_br=cond_taken;
          e_next_pc = cond_taken ? br_tgt : pc_q+64'd1; end
      end
      CLS_NOP: ;
      CLS_RET: ;
      default: begin e_fault=1; e_fcode=FAULT_INTERNAL; end
    endcase
  end

  // ---------------- outputs ----------------------------------------------------
  assign f_cmd_valid = (st == ST_FETCH_REQ);
  assign f_cmd_pc    = pc_q;
  assign f_rsp_ready = (st == ST_FETCH_WAIT);

  assign sgpr_init_ready = (st == ST_IDLE);
  assign sgpr_raddr0     = (st == ST_EXECUTE || st == ST_VECTOR_SETUP) ? d_src0 : 8'd0;
  assign sgpr_raddr1     = (st == ST_EXECUTE) ? d_src1 : 8'd0;
  assign sgpr_we         = (st == ST_COMMIT) && x_we;
  assign sgpr_waddr      = x_wa;
  assign sgpr_wdata      = x_wd;
  assign pred_init_ready = (st == ST_IDLE);

  assign vec_setup_valid = (st == ST_VECTOR_SETUP);
  always_comb begin
    vec_op   = d_va_op;
    vec_bmux = d_va_bmux;
    vec_vd   = d_vd;
    vec_vs0  = d_vs0;
    vec_vs1  = d_vs1;
    vec_imm  = d_imm;
    case (d_cls)
      CLS_VEC_PASS: vec_vs1 = 8'hFF;          // unused marker for PASS path
      default     : vec_vs1 = d_vs1;
    endcase
  end
  assign vec_effective_mask = eff_mask;
  assign vec_bcast_data     = sgpr_rdata0;    // captured during VECTOR_SETUP read

  assign completion_valid         = (st == ST_COMPLETE) || (st == ST_FAULT);
  assign completion_fault         = compl_fault_q;
  assign completion_fault_code    = fault_code_q;
  assign completion_pc            = compl_pc_q;
  assign completion_retired_count = retired_q;

  always_comb begin
    trace_valid        = (st == ST_COMMIT) || (st == ST_VECTOR_RETIRE);
    trace_pc           = pc_q;
    trace_insn         = insn_q;
    trace_sgpr_we      = x_we;
    trace_sgpr_addr    = x_we ? x_wa : 8'd0;
    trace_sgpr_wdata   = x_we ? x_wd : 32'd0;
    trace_sc_flags     = x_flags;
    trace_scc          = x_scc;
    trace_branch_taken = x_br;
    trace_next_pc      = x_next_pc;
    trace_exec_mask    = x_exec;
    trace_pred_idx     = x_pred;
    trace_effective_mask = x_eff;
    trace_vgpr_we      = (st == ST_VECTOR_RETIRE);
    trace_vgpr_addr    = (st == ST_VECTOR_RETIRE) ? d_vd   : 8'd0;
    trace_vgpr_write_mask = (st == ST_VECTOR_RETIRE) ? x_eff : 32'd0;
    trace_fault_o      = 1'b0;
    trace_fault_code_o = 6'd0;
  end

  always_comb begin
    unused_code_words_q = code_words_q; // width-folding consumption
    unused_d_legal = d_legal; unused_d_is_vec = d_is_vec;
    unused_x_fault = x_fault; unused_x_fcode = x_fcode;
    unused_vgpr_req_q = vgpr_req_q; unused_sgpr_req_q = sgpr_req_q;
  end
  assign start_ready          = (st == ST_IDLE);
  assign dbg_pc               = pc_q;
  assign dbg_state            = st;
  assign dbg_exec_mask        = exec_q;
  assign dbg_pred_idx         = d_pred;
  assign dbg_effective_mask   = eff_mask;
  assign dbg_vgpr_we          = (st == ST_VECTOR_RETIRE);
  assign dbg_vgpr_addr        = d_vd;
  assign dbg_vgpr_write_mask  = eff_mask;


  // ============================ sequencer =====================================
  always_ff @(posedge clk) begin
    if (rst) begin
      st<=ST_IDLE; pc_q<='0; code_words_q<='0; wg_x_q<='0; exec_q<='0;
      vgpr_req_q<='0; sgpr_req_q<='0; retired_q<='0;
      fault_code_q<='0; compl_pc_q<='0; compl_fault_q<=1'b0;
      flags_q<='0; scc_q<=1'b0; insn_q<='0;
      d_legal<=1'b0; d_is_vec<=1'b0; d_cls<=CLS_NONE;
      d_va_op<='0; d_va_bmux<='0;
      d_dst<='0; d_src0<='0; d_src1<='0; d_vd<='0; d_vs0<='0; d_vs1<='0;
      d_useimm<=1'b0; d_imm<='0; d_disp<=24'sd0; d_cond<='0; d_pred<=PRED_NONE4;
      x_fault<=1'b0; x_fcode<='0; x_we<=1'b0; x_br<=1'b0; x_wa<='0; x_wd<='0;
      x_flags<='0; x_scc<=1'b0; x_next_pc<='0; x_is_ret<=1'b0;
      x_exec<='0; x_pred<='0; x_eff<='0;
    end else begin
      unique case (st)
        ST_IDLE: begin
          if (start_valid) begin
            pc_q         <= start_entry_pc;
            code_words_q <= start_code_words;
            wg_x_q       <= start_wg_x;
            exec_q       <= start_exec_mask;
            // declared-requirement validation (directive §27)
            if ((start_vgpr_req == 9'd0) || (32'(start_vgpr_req) > 32'(VGPR_COUNT)) ||
                (start_sgpr_req == 9'd0) || (32'(start_sgpr_req) > 32'(SGPR_COUNT))) begin
              fault_code_q <= FAULT_INVALID_REGISTER;
              compl_pc_q   <= start_entry_pc;
              compl_fault_q<= 1'b1;
              st           <= ST_FAULT;
            end else if (start_exec_mask == 32'd0) begin
              // empty tail wavefront: clean completion, zero retirement (§19)
              compl_pc_q    <= start_entry_pc;
              compl_fault_q <= 1'b0;
              st            <= ST_COMPLETE;
            end else begin
              vgpr_req_q <= start_vgpr_req;
              sgpr_req_q <= start_sgpr_req;
              flags_q    <= 4'd0;
              scc_q      <= 1'b0;
              retired_q  <= 64'd0;
              st         <= ST_FETCH_REQ;
            end
          end
        end

        ST_FETCH_REQ: if (f_req_accepted) st <= ST_FETCH_WAIT;

        ST_FETCH_WAIT: begin
          if (f_rsp_valid && f_rsp_ready) begin
            insn_q <= f_rsp_insn;
            if (f_rsp_error) begin
              fault_code_q  <= FAULT_INVALID_ADDRESS;
              compl_pc_q    <= pc_q;
              compl_fault_q <= 1'b1;
              st            <= ST_FAULT;
            end else st <= ST_DECODE;
          end
        end

        ST_DECODE: begin
          d_legal  <= c_legal;
          d_is_vec <= c_isvec;
          d_cls    <= c_cls;
          d_va_op  <= c_va_op;
          d_va_bmux<= c_va_bmux;
          d_dst    <= c_dst; d_src0 <= c_src0; d_src1 <= c_src1;
          d_vd     <= c_vd;  d_vs0  <= c_vs0;  d_vs1  <= c_vs1;
          d_useimm <= c_useimm;
          d_imm    <= c_imm;
          d_disp   <= c_disp;
          d_cond   <= c_cond;
          d_pred   <= c_pred;
          if (!c_legal) begin
            fault_code_q  <= FAULT_ILLEGAL_OPCODE;
            compl_pc_q    <= pc_q;
            compl_fault_q <= 1'b1;
            st            <= ST_FAULT;
          end else if (c_isvec) begin
            if (v_bad_reg) begin           // validate BEFORE any beat (§28/§119)
              fault_code_q  <= FAULT_INVALID_REGISTER;
              compl_pc_q    <= pc_q;
              compl_fault_q <= 1'b1;
              st            <= ST_FAULT;
            end else begin
              st <= ST_VECTOR_SETUP;
            end
          end else begin
            st <= ST_EXECUTE;
          end
        end

        ST_EXECUTE: begin
          x_fault <= e_fault; x_fcode <= e_fcode;
          x_exec <= exec_q; x_pred <= d_pred;
          x_eff  <= (d_pred == PRED_NONE4) ? exec_q
                                           : (exec_q & pred_rd_data);
          x_we    <= e_we && !e_fault;
          x_wa    <= e_wa;     x_wd <= e_wd;
          x_flags <= e_flags;  x_scc <= e_scc;
          x_br    <= e_br;     x_next_pc <= e_next_pc; x_is_ret <= e_is_ret;
          if (e_fault) begin
            fault_code_q <= e_fcode; compl_pc_q <= pc_q; compl_fault_q <= 1'b1;
            st <= ST_FAULT;
          end else st <= ST_COMMIT;
        end

        ST_COMMIT: begin
          pc_q      <= x_next_pc;
          flags_q   <= x_flags;
          scc_q     <= x_scc;
          retired_q <= retired_q + 64'd1;
          st        <= x_is_ret ? ST_COMPLETE : ST_FETCH_REQ;
          if (x_is_ret) begin
            compl_pc_q    <= pc_q;
            compl_fault_q <= 1'b0;
          end
        end

        ST_VECTOR_SETUP: begin
          if (vec_setup_ready) begin
            x_exec    <= exec_q;
            x_pred    <= d_pred;
            x_eff     <= (d_pred == PRED_NONE4) ? exec_q
                                                : (exec_q & pred_rd_data);
            x_next_pc <= pc_q + 64'd1;
            x_we      <= 1'b0;                 // vector writes tracked separately
            x_br      <= 1'b0;
            x_flags   <= flags_q;
            x_scc     <= scc_q;
            st <= ST_VECTOR_RUN;
          end
        end

        ST_VECTOR_RUN: begin
          if (vec_last_commit)
            st <= ST_VECTOR_RETIRE;              // retire cycle emits trace
        end

        ST_VECTOR_RETIRE: begin
          retired_q <= retired_q + 64'd1;
          pc_q      <= pc_q + 64'd1;
          st        <= ST_FETCH_REQ;
        end

        ST_COMPLETE, ST_FAULT: begin
          if (completion_ready) st <= ST_IDLE;
        end

        default: st <= ST_IDLE;
      endcase
    end
  end

`ifdef SCIGPU_FORMAL
  m3_assert_006: assert property (@(posedge clk) disable iff (rst)
    !(trace_valid && (st inside {ST_VECTOR_RUN})));
  m3_assert_014: assert property (@(posedge clk) disable iff (rst)
    (st == ST_VECTOR_RUN) |-> !f_cmd_valid);
`endif

endmodule
