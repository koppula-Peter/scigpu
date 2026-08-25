// SciGPU M2 — scalar control FSM, architectural commit, trace, completion
// MICRO-001 §1.3–§1.7. One instruction in flight; architectural state changes
// ONLY in ST_COMMIT (plus launch/reset initialisation). No speculation.
module scigpu_scalar_control #(
  parameter int unsigned SGPR_COUNT = 64
) (
  input  logic        clk,
  input  logic        rst,

  // ---- launch interface --------------------------------------------------
  input  logic        start_valid,
  output logic        start_ready,
  input  logic [63:0] start_entry_pc,
  input  logic [63:0] start_code_words,
  input  logic [31:0] start_wg_x,

  // ---- instruction fetch (via scigpu_fetch engine) ------------------------
  output logic        f_cmd_valid,
  output logic [63:0] f_cmd_pc,
  input  logic        f_req_accepted,
  input  logic        f_busy_unused,
  input  logic        f_rsp_valid,
  input  logic [63:0] f_rsp_insn,
  input  logic        f_rsp_error,
  output logic        f_rsp_ready,

  // ---- SGPR preload (bootstrap; backpressured unless IDLE) ----------------
  output logic        sgpr_init_ready,

  // ---- SGPR commit-side connections (file instantiated in core) ----------
  output logic [7:0]  sgpr_raddr0,
  output logic [7:0]  sgpr_raddr1,
  input  logic [31:0] sgpr_rdata0,
  input  logic [31:0] sgpr_rdata1,
  input  logic        sgpr_rinv0,
  input  logic        sgpr_rinv1,
  output logic        sgpr_we,
  output logic [7:0]  sgpr_waddr,
  output logic [31:0] sgpr_wdata,

  // ---- completion ----------------------------------------------------------
  output logic        completion_valid,
  input  logic        completion_ready,
  output logic        completion_fault,
  output logic [5:0]  completion_fault_code,
  output logic [63:0] completion_pc,
  output logic [63:0] completion_retired_count,

  // ---- retire trace (flattened; one event per committed instruction) --------
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

  // ---- debug ----------------------------------------------------------------
  output logic [63:0] dbg_pc,
  output logic [63:0] dbg_code_words,
  output logic [5:0]  dbg_last_fault_code,
  output scigpu_types_pkg::state_e dbg_state
);

  import scigpu_isa_pkg::*;
  import scigpu_types_pkg::*;

  // =============================== state ==================================
  state_e       st;
  logic [63:0]  pc_q;
  logic [63:0]  code_words_q;
  logic [31:0]  wg_x_q;
  logic [63:0]  retired_q;

  logic [63:0]  insn_q;

  logic [3:0]   flags_q;                        // {V,C,N,Z}
  logic         scc_q;

  logic [5:0]   fault_code_q;
  logic [63:0]  compl_pc_q;
  logic         compl_fault_q;

  // decoded (registered out of DECODE)
  logic         d_legal;
  wire          unused_d_legal = d_legal;   // reserved for ASSERT instrumentation
  iclass_e      d_cls;
  logic [7:0]   d_dst, d_src0, d_src1, d_gsel, d_gdst;
  logic         d_useimm;
  logic [31:0]  d_imm;
  logic signed [23:0] d_disp;
  logic [7:0]   d_cond;

  // execute results (registered out of EXECUTE)
  logic         x_fault;
  logic [5:0]   x_fcode;
  logic         x_we;
  logic [7:0]   x_wa;
  logic [31:0]  x_wd;
  logic [3:0]   x_flags;
  logic         x_scc;
  logic         x_br;
  logic [63:0]  x_next_pc;
  logic         x_is_ret;

  // =============================== decode ==================================
  logic         c_legal;
  iclass_e      c_cls;
  logic [7:0]   c_dst, c_src0, c_src1, c_gsel, c_gdst;
  logic         c_useimm;
  logic [31:0]  c_imm;
  logic signed [23:0] c_disp;
  logic [7:0]   c_cond;

  scigpu_decode u_decode (
    .insn      (insn_q),
    .legal     (c_legal),
    .cls       (c_cls),
    .dst       (c_dst),
    .src0      (c_src0),
    .src1      (c_src1),
    .use_imm   (c_useimm),
    .imm       (c_imm),
    .disp24    (c_disp),
    .cond      (c_cond),
    .getid_sel (c_gsel),
    .getid_dst (c_gdst)
  );

  // =============================== execute =================================
  wire logic [11:0] opc = insn_q[63:52];

  localparam bit [3:0] ALU_PASS_B=4'd0, ALU_ADD=4'd1, ALU_SUB=4'd2, ALU_AND=4'd3,
                       ALU_OR=4'd4, ALU_XOR=4'd5, ALU_NOT=4'd6, ALU_SHL=4'd7,
                       ALU_SHR=4'd8, ALU_SAR=4'd9, ALU_MUL=4'd10;

  logic [3:0]  alu_op;
  logic [31:0] alu_a, alu_b, alu_y;

  always_comb begin
    alu_op = ALU_PASS_B;
    case (opc)
      OPC_S_ADD: alu_op = ALU_ADD;
      OPC_S_SUB: alu_op = ALU_SUB;
      OPC_S_AND: alu_op = ALU_AND;
      OPC_S_OR : alu_op = ALU_OR;
      OPC_S_XOR: alu_op = ALU_XOR;
      OPC_S_NOT: alu_op = ALU_NOT;
      OPC_S_SHL: alu_op = ALU_SHL;
      OPC_S_SHR: alu_op = ALU_SHR;
      OPC_S_SAR: alu_op = ALU_SAR;
      OPC_S_MUL: alu_op = ALU_MUL;
      default  : alu_op = ALU_PASS_B;
    endcase
  end

  always_comb begin
    alu_a = sgpr_rdata0;
    alu_b = d_useimm ? d_imm : sgpr_rdata1;
    if ((d_cls == CLS_MOV) && !d_useimm)
      alu_b = sgpr_rdata0;                 // MOV reg,reg -> pass src0
    if ((d_cls == CLS_MOV) && d_useimm)
      alu_b = d_imm;                       // MOV dst,#imm -> pass imm
    if (d_cls == CLS_GETID) begin
      alu_a = 32'd0;
      alu_b = wg_x_q;                      // PASS_B carries WG_X
    end
  end

  scigpu_scalar_alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

  // compare flags: R = A - B
  wire [31:0] cmp_r = sgpr_rdata0 - sgpr_rdata1;
  logic [1:0] cmp_kind;
  always_comb begin
    case (opc)
      OPC_S_CMP_LT: cmp_kind = 2'd1;
      OPC_S_CMP_GT: cmp_kind = 2'd2;
      default     : cmp_kind = 2'd0;
    endcase
  end

  logic fl_z, fl_n, fl_c, fl_v, fl_scc;
  scigpu_scalar_flags u_flags (
    .a(sgpr_rdata0), .b(sgpr_rdata1), .r(cmp_r), .cmp_kind,
    .z(fl_z), .n(fl_n), .c(fl_c), .v(fl_v), .scc(fl_scc)
  );

  // conditional branch condition evaluation ({V,C,N,Z} = flags[3],flags[2],flags[1],flags[0])
  logic cond_taken;
  logic cond_reserved;
  always_comb begin
    cond_reserved = (d_cond >= COND_RESERVED);
    cond_taken    = 1'b0;
    case (d_cond)
      COND_ALWAYS: cond_taken = 1'b1;
      COND_SCC   : cond_taken = scc_q;
      COND_NSCC  : cond_taken = ~scc_q;
      COND_Z     : cond_taken = flags_q[0];
      COND_NZ    : cond_taken = ~flags_q[0];
      COND_N     : cond_taken = flags_q[1];
      COND_NN    : cond_taken = ~flags_q[1];
      COND_C     : cond_taken = flags_q[2];
      COND_NC    : cond_taken = ~flags_q[2];
      COND_V     : cond_taken = flags_q[3];
      COND_NV    : cond_taken = ~flags_q[3];
      COND_LT_S  : cond_taken = flags_q[1] ^ flags_q[3];
      COND_GE_S  : cond_taken = ~(flags_q[1] ^ flags_q[3]);
      COND_LT_U  : cond_taken = ~flags_q[2];
      COND_GE_U  : cond_taken =  flags_q[2];
      default    : cond_taken = 1'b0;
    endcase
  end

  // source/destination validity (INV-021: checked before any architectural effect)
  logic src0_used, src1_used, dst_used;
  always_comb begin
    src0_used = 1'b0; src1_used = 1'b0; dst_used = 1'b0;
    case (d_cls)
      CLS_MOV, CLS_ALU, CLS_MUL, CLS_CMP: begin
        src0_used = 1'b1;
        src1_used = !d_useimm;
        dst_used  = (d_cls != CLS_CMP);
      end
      CLS_GETID: dst_used = 1'b1;
      default: ;
    endcase
  end

  logic ex_bad_reg;
  assign ex_bad_reg = (src0_used && sgpr_rinv0) ||
                      (src1_used && sgpr_rinv1) ||
                      (dst_used  && ({1'b0, d_dst} >= SGPR_COUNT[8:0]));

  // execute-stage combinational result
  logic         e_fault;
  logic [5:0]   e_fcode;
  logic         e_we;
  logic [7:0]   e_wa;
  logic [31:0]  e_wd;
  logic [3:0]   e_flags;
  logic         e_scc;
  logic         e_br;
  logic [63:0]  e_next_pc;
  logic         e_is_ret;

  always_comb begin
    e_fault  = 1'b0; e_fcode = 6'd0;
    e_we     = 1'b0; e_wa = d_dst; e_wd = alu_y;
    e_flags  = flags_q; e_scc = scc_q;
    e_br     = 1'b0;
    e_next_pc= pc_q + 64'd1;
    e_is_ret = (d_cls == CLS_RET);

    if (ex_bad_reg) begin
      e_fault = 1'b1; e_fcode = FAULT_INVALID_REGISTER;
    end else begin
      case (d_cls)
        CLS_MOV, CLS_ALU, CLS_MUL: begin
          e_we = 1'b1; e_wa = d_dst; e_wd = alu_y;
        end
        CLS_GETID: begin
          if (d_gsel != 8'd0) begin   // GETID_WG_X == 0
            e_fault = 1'b1; e_fcode = FAULT_ILLEGAL_OPCODE; // unsupported selector
          end else begin
            e_we = 1'b1; e_wa = d_gdst; e_wd = wg_x_q;
          end
        end
        CLS_CMP: begin
          e_flags = {fl_v, fl_c, fl_n, fl_z};
          e_scc   = fl_scc;
        end
        CLS_BRA: begin
          e_br = 1'b1; e_next_pc = pc_q + 64'd1 + {{40{d_disp[23]}}, d_disp};
        end
        CLS_BRA_C: begin
          if (cond_reserved) begin
            e_fault = 1'b1; e_fcode = FAULT_ILLEGAL_OPCODE;
          end else begin
            e_br = cond_taken;
            e_next_pc = cond_taken ? (pc_q + 64'd1 + {{40{d_disp[23]}}, d_disp})
                                   : (pc_q + 64'd1);
          end
        end
        CLS_NOP: ;
        CLS_RET: ;                            // completion handled at commit
        default: begin
          e_fault = 1'b1; e_fcode = FAULT_INTERNAL;
        end
      endcase
    end
  end

  // =============================== fetch ====================================
  assign f_cmd_valid  = (st == ST_FETCH_REQ);
  assign f_cmd_pc     = pc_q;
  assign f_rsp_ready  = (st == ST_FETCH_WAIT);

  // =============================== commit-side SGPR write ===================
  assign sgpr_we    = (st == ST_COMMIT) && x_we;
  assign sgpr_waddr = x_wa;
  assign sgpr_wdata = x_wd;

  // read addresses valid during EXECUTE (registered decode drives them)
  assign sgpr_raddr0 = (st == ST_EXECUTE) ? d_src0 : 8'd0;
  assign sgpr_raddr1 = (st == ST_EXECUTE) ? d_src1 : 8'd0;

  // =============================== completion ===============================
  assign completion_valid        = (st == ST_COMPLETE) || (st == ST_FAULT);
  assign completion_fault        = compl_fault_q;
  assign completion_fault_code   = fault_code_q;
  assign completion_pc           = compl_pc_q;
  assign completion_retired_count= retired_q;

  // =============================== trace ====================================
  always_comb begin
    trace_valid        = (st == ST_COMMIT);
    trace_pc           = pc_q;
    trace_insn         = insn_q;
    trace_sgpr_we      = x_we;
    trace_sgpr_addr    = x_we ? x_wa : 8'd0;    // no-write => no payload (trace contract)
    trace_sgpr_wdata   = x_we ? x_wd : 32'd0;
    trace_sc_flags     = x_flags;
    trace_scc          = x_scc;
    trace_branch_taken = x_br;
    trace_next_pc      = x_next_pc;
    trace_fault_o      = 1'b0;       // commit never coincides with fault (FSM)
    trace_fault_code_o = 6'd0;
  end

  // =============================== outputs ==================================
  assign start_ready       = (st == ST_IDLE);
  assign sgpr_init_ready   = (st == ST_IDLE);
  assign dbg_pc            = pc_q;
  assign dbg_code_words    = code_words_q;
  assign dbg_last_fault_code = fault_code_q;
  logic unused_x_fault;               // faulting instrs divert to ST_FAULT pre-commit
  logic [5:0] unused_x_fcode;
  always_comb begin
    unused_x_fault = x_fault;
    unused_x_fcode = x_fcode;
  end
  assign dbg_state         = st;

  // =============================== sequential ===============================
  always_ff @(posedge clk) begin
    if (rst) begin
      st            <= ST_IDLE;
      pc_q          <= 64'd0;
      code_words_q  <= 64'd0;
      wg_x_q        <= 32'd0;
      retired_q     <= 64'd0;
      insn_q        <= 64'd0;
      flags_q       <= 4'd0;
      scc_q         <= 1'b0;
      fault_code_q  <= 6'd0;
      compl_pc_q    <= 64'd0;
      compl_fault_q <= 1'b0;
      d_legal       <= 1'b0;
      d_cls         <= CLS_NONE;
      d_dst         <= 8'd0; d_src0 <= 8'd0; d_src1 <= 8'd0; d_gsel <= 8'd0;
      d_gdst        <= 8'd0;
      d_useimm      <= 1'b0;
      d_imm         <= 32'd0;
      d_disp        <= 24'sd0;
      d_cond        <= 8'd0;
      x_fault       <= 1'b0; x_fcode <= 6'd0; x_we <= 1'b0;
      x_wa          <= 8'd0; x_wd <= 32'd0;
      x_flags       <= 4'd0; x_scc <= 1'b0; x_br <= 1'b0;
      x_next_pc     <= 64'd0; x_is_ret <= 1'b0;
    end else begin
      case (st)
        ST_IDLE: begin
          if (start_valid) begin
            pc_q        <= start_entry_pc;
            code_words_q<= start_code_words;
            wg_x_q      <= start_wg_x;
            flags_q     <= 4'd0;
            scc_q       <= 1'b0;
            retired_q   <= 64'd0;
            st          <= ST_FETCH_REQ;
          end
        end

        ST_FETCH_REQ: begin
          if (f_req_accepted)
            st <= ST_FETCH_WAIT;
        end

        ST_FETCH_WAIT: begin
          if (f_rsp_valid && f_rsp_ready) begin
            insn_q   <= f_rsp_insn;
            if (f_rsp_error) begin
              fault_code_q <= FAULT_INVALID_ADDRESS;
              compl_pc_q   <= pc_q;
              compl_fault_q<= 1'b1;
              st           <= ST_FAULT;
            end else begin
              st <= ST_DECODE;
            end
          end
        end

        ST_DECODE: begin
          d_legal <= c_legal;
          d_cls   <= c_cls;
          d_dst   <= c_dst;
          d_src0  <= c_src0;
          d_src1  <= c_src1;
          d_gsel  <= c_gsel;
          d_gdst  <= c_gdst;
          d_useimm<= c_useimm;
          d_imm   <= c_imm;
          d_disp  <= c_disp;
          d_cond  <= c_cond;
          if (!c_legal) begin
            fault_code_q <= FAULT_ILLEGAL_OPCODE;
            compl_pc_q   <= pc_q;
            compl_fault_q<= 1'b1;
            st           <= ST_FAULT;
          end else begin
            st <= ST_EXECUTE;
          end
        end

        ST_EXECUTE: begin
          x_fault <= e_fault;
          x_fcode <= e_fcode;
          x_we    <= e_we && !e_fault;               // faulting instr never writes
          x_wa    <= e_wa;
          x_wd    <= e_wd;
          x_flags <= e_flags;
          x_scc   <= e_scc;
          x_br    <= e_br;
          x_next_pc <= e_next_pc;
          x_is_ret  <= e_is_ret;
          if (e_fault) begin
            fault_code_q <= e_fcode;
            compl_pc_q   <= pc_q;
            compl_fault_q<= 1'b1;
            st           <= ST_FAULT;
          end else begin
            st <= ST_COMMIT;
          end
        end

        ST_COMMIT: begin
          pc_q      <= x_next_pc;
          flags_q   <= x_flags;
          scc_q     <= x_scc;
          retired_q <= retired_q + 64'd1;
          st        <= x_is_ret ? ST_COMPLETE : ST_FETCH_REQ;
          if (x_is_ret) begin
            compl_pc_q    <= pc_q;                   // retiring-instruction PC
            compl_fault_q <= 1'b0;
          end
        end

        ST_COMPLETE, ST_FAULT: begin
          if (completion_ready)
            st <= ST_IDLE;
        end

        default: st <= ST_IDLE;
      endcase
    end
  end

`ifdef SCIGPU_FORMAL
  // M2-ASSERT-002/003 equivalents (procedural-proof seeds; see VER-001 mapping)
  assert property (@(posedge clk) disable iff (rst)
    (st == ST_COMMIT) |-> !x_fault);
`endif

endmodule
