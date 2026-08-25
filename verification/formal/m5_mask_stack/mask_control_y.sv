// SciGPU M5 - unified typed mask/control stack + divergence-control engine
// (ADR-011; MICRO-001 Rev0.4 s4.2/s4.3; EXEC-001 Rev1.1 s4).
//
// One instance per CU; slot-dimensioned frame storage gives each resident
// wavefront an architecturally private stack (directive 21). Every operation
// carries its owner slot (= wfid) across the whole possibly-multi-cycle
// lifetime (45/48): scrub walks and the automatic unwind engine advance one
// frame per cycle.
//
// Contract mirrors models/isa/simulator.py exactly (ADR-011):
//   * atomic overflow/underflow/reconv-mismatch/illegal-flow faults with ZERO
//     partial architectural effects,
//   * EXEC subset of LIVE_MASK maintained on every commit,
//   * always-push structured IF frames, two-phase RECONV with PC check,
//   * nearest-loop BREAK/CONTINUE + mask scrubbing of frames above the loop,
//   * divergent RET_KERNEL_WF + unwind engine; full early return silently
//     discards dead frames (never classified as underflow).
module scigpu_mask_control_m5 #(
  parameter int unsigned SLOTS = 4,
  parameter int unsigned DEPTH = 32
) (
  input  logic clk,
  input  logic rst,
  output logic ready,

  input  logic        cmd_valid,
  input  logic [3:0]  cmd_op,
  input  logic [$clog2(SLOTS)-1:0] cmd_slot,
  input  logic [3:0]  cmd_cond,
  input  logic [31:0] cmd_pword,
  input  logic [63:0] cmd_pc,
  input  logic [63:0] cmd_cw,
  input  logic [31:0] cmd_exec,
  input  logic [31:0] cmd_live,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [$clog2(DEPTH+1)-1:0] cmd_sp,   // reserved: engine reads sp_q directly
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [$clog2(DEPTH+1)-1:0] cmd_loopidx,
  input  logic [23:0] cmd_disp24,
  input  logic [15:0] cmd_bmod,

  output logic        done,
  output logic        fault,
  output logic [5:0]  fault_code,
  output logic        retire,
  output logic        route_le,
  output logic        o_pop_evt,              // this completion popped a frame
  output logic [1:0]   o_top_ftype,            // owner's current top frame
  output logic [31:0] o_exec, o_live,
  output logic [$clog2(DEPTH+1)-1:0] o_sp, o_loopidx,
  output logic [63:0] o_pc,
  output logic        o_pc_we,

  input  logic [$clog2(SLOTS)-1:0] dbg_slot,
  output logic [$clog2(DEPTH+1)-1:0] dbg_sp,
  output logic [1:0]  dbg_top_ftype,
  output logic [31:0] dbg_top_parent, dbg_top_maska, dbg_top_maskb
);

  localparam bit [5:0] FAULT_ILLEGAL_OPCODE=6'h01, FAULT_INVALID_REGISTER=6'h02,
      FAULT_INVALID_ADDRESS=6'h03, FAULT_MASK_STACK_OVERFLOW=6'h05,
      FAULT_MASK_STACK_UNDERFLOW=6'h06, FAULT_INTERNAL=6'h0C,
      FAULT_RECONVERGENCE_MISMATCH=6'h0D,
      FAULT_ILLEGAL_CONTROL_FLOW=6'h0E;

  localparam int unsigned SPW = $clog2(DEPTH+1);
  localparam int unsigned LIW = $clog2(DEPTH+1);
  localparam int unsigned IW  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam bit [LIW-1:0] LI_NONE = (DEPTH);

  localparam bit [3:0] CT_CBRANCH=4'd0, CT_RECONV=4'd1, CT_LOOPB=4'd2,
                       CT_LOOPE=4'd3, CT_BREAK=4'd4, CT_CONT=4'd5,
                       CT_PUSHM=4'd6, CT_POPM=4'd7, CT_SETM=4'd8,
                       CT_ANDM=4'd9, CT_ORM=4'd10, CT_XORM=4'd11,
                       CT_RETW=4'd12;

  localparam bit [1:0] FT_IF=2'd1, FT_LOOP=2'd2, FT_MANUAL=2'd3;

  typedef struct packed {
    logic [1:0]     ftype;
    logic [31:0]    parent;
    logic [31:0]    mask_a;
    logic [31:0]    mask_b;
    logic [31:0]    future;
    logic [63:0]    pc_a;
    logic [63:0]    pc_b;
    logic           phase;
    logic [LIW-1:0] prev_loop;
  } frame_t;

  frame_t frames [SLOTS][DEPTH];
  logic [SPW-1:0] sp_q [SLOTS];

  typedef enum logic [2:0] { S_IDLE=3'd0, S_VALID=3'd1, S_SCRUB=3'd2,
                             S_RETSCRUB=3'd3, S_UNWIND=3'd4 } st_e;
  st_e st_q;

  // ---- latched command / working context ----
  logic [3:0]   op_q, cond_q;
  logic [31:0]  pw_q;
  logic [$clog2(SLOTS)-1:0] sl_q;
  logic [63:0]  pc_q, cw_q;
  logic [23:0]  dsp_q;
  logic [15:0]  bmod_q;
  logic [31:0]  ex_q, lv_q, m_q, retm_q;
  logic [31:0]  wex_q, wlv_q;
  logic [LIW-1:0] li_q;
  logic [SPW-1:0] wi_q;

  assign ready = (st_q == S_IDLE);

  // ---- combinational frame reads (owner slot) ----
  wire [IW-1:0] top_idx = (sp_q[sl_q] != '0)
                        ? (sp_q[sl_q] - (1)) : (0);
  frame_t top_r, li_r;
  assign top_r = (sp_q[sl_q] != '0) ? frames[sl_q][top_idx] : '0;
  assign li_r  = ((li_q != LI_NONE) && (li_q < (DEPTH)))
               ? frames[sl_q][li_q[IW-1:0]] : '0;

  // ---- storage write port ----
  frame_t         wf_d;
  logic           wf_en;
  logic [IW-1:0]  wf_i;
  logic           sp_en;
  logic [SPW-1:0] sp_v;

  frame_t fr_tmp;
  integer si_, di_;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (si_ = 0; si_ < int'(SLOTS); si_++) begin
        sp_q[si_] <= '0;
        for (di_ = 0; di_ < int'(DEPTH); di_++) frames[si_][di_] <= '0;
      end
    end else begin
      if (wf_en) frames[sl_q][wf_i] <= wf_d;
      if (sp_en) sp_q[sl_q]         <= sp_v;
    end
  end

  // ---- completion staging ----
  logic        d_pop_q;
  logic        d_done_q, d_fault_q, d_ret_q, d_route_q, d_pcwe_q;
  logic [5:0]  d_fc_q;
  logic [31:0] d_ex_q, d_lv_q;
  logic [SPW-1:0] d_sp_q;
  logic [LIW-1:0] d_li_q;
  logic [63:0]    d_pc_q;

  assign done       = d_done_q;
  assign fault      = d_fault_q;
  assign fault_code = d_fc_q;
  assign retire     = d_ret_q;
  assign route_le   = d_route_q;
  assign o_pop_evt  = d_pop_q;
  assign o_top_ftype = top_r.ftype;
  assign o_exec     = d_ex_q;
  assign o_live     = d_lv_q;
  assign o_sp       = d_sp_q;
  assign o_loopidx  = d_li_q;
  assign o_pc       = d_pc_q;
  assign o_pc_we    = d_pcwe_q;

  // ---- S_VALID combinational resolution --------------------------------------
  wire [63:0] tgt_else_c = pc_q + 64'd1 + {{40{dsp_q[23]}}, dsp_q};
  wire [63:0] tgt_rcv_c  = pc_q + 64'd1 +
                           {{48{bmod_q[15]}}, bmod_q};
  wire [63:0] tgt_end_c  = tgt_else_c;
  wire [63:0] tgt_head_c = tgt_else_c;

  wire        cbr_bad    = (cond_q >= 4'd15) ||
                            (tgt_else_c >= cw_q) || (tgt_rcv_c >= cw_q) ||
                            (sp_q[sl_q] >= (DEPTH));
  wire [5:0]  cbr_fcode  = (cond_q >= 4'd15) ? FAULT_ILLEGAL_CONTROL_FLOW :
                           ((tgt_else_c >= cw_q) || (tgt_rcv_c >= cw_q)) ?
                             FAULT_INVALID_ADDRESS :
                             FAULT_MASK_STACK_OVERFLOW;
  wire        cbr_t_ne0  = ((ex_q & pw_q) != 32'b0);
  wire [31:0] cbr_t      = ex_q & pw_q;
  wire [31:0] cbr_f      = ex_q & ~pw_q;

  wire        rcv_bad    = (sp_q[sl_q] == '0)                    ? 1'b1 :
                           (top_r.ftype != FT_IF)                 ? 1'b1 :
                           (pc_q != top_r.pc_b)                   ? 1'b1 : 1'b0;
  wire [5:0]  rcv_fcode  = (sp_q[sl_q] == '0) ? FAULT_MASK_STACK_UNDERFLOW :
                           (top_r.ftype != FT_IF) ? FAULT_ILLEGAL_CONTROL_FLOW :
                                                    FAULT_RECONVERGENCE_MISMATCH;
  wire        rcv_alt    = ((top_r.phase == 1'b0) &&
                            ((top_r.mask_a & lv_q) != 32'b0));

  wire        lpb_bad    = (tgt_end_c >= cw_q) || (sp_q[sl_q] >= (DEPTH));
  wire [5:0]  lpb_fcode  = (tgt_end_c >= cw_q) ? FAULT_INVALID_ADDRESS :
                                                    FAULT_MASK_STACK_OVERFLOW;

  wire        lpe_bad    = (li_q == LI_NONE) ||
                           (sp_q[sl_q] != (li_q + (1)))       ? 1'b1 :
                           (pc_q != li_r.pc_b) || (tgt_head_c != li_r.pc_a);
  wire [5:0]  lpe_fcode  = (li_q == LI_NONE) ||
                           (sp_q[sl_q] != (li_q + (1)))
                             ? FAULT_ILLEGAL_CONTROL_FLOW
                             : FAULT_RECONVERGENCE_MISMATCH;
  wire [31:0] lpe_cand   = ((ex_q | li_r.mask_b) & li_r.future) & lv_q;
  wire [31:0] lpe_nxt    = (cond_q == 4'd15) ? lpe_cand : (lpe_cand & pw_q);

  wire        bc_no_loop = (li_q == LI_NONE);

  wire        pop_bad    = (sp_q[sl_q] == '0) || (top_r.ftype != FT_MANUAL);
  wire [5:0]  pop_fcode  = (sp_q[sl_q] == '0) ? FAULT_MASK_STACK_UNDERFLOW
                                                  : FAULT_ILLEGAL_CONTROL_FLOW;
  wire        mx_bad     = (cond_q >= 4'd15);
  wire [31:0] mx_res     = (op_q == CT_SETM) ? (pw_q & lv_q) :
                           (op_q == CT_ANDM) ? (ex_q & pw_q & lv_q) :
                           (op_q == CT_ORM ) ? ((ex_q | pw_q) & lv_q) :
                                               ((ex_q ^ pw_q) & lv_q);

  // commit bundle produced by S_VALID resolution
  logic        c_wfen;  frame_t c_wfd;  logic [IW-1:0] c_wfi;
  logic        c_spen;  logic [SPW-1:0] c_spv;
  logic        c_done,  c_fault, c_ret, c_route, c_pcwe, c_pop;
  logic [5:0]  c_fc;
  logic [31:0] c_ex, c_lv;
  logic [SPW-1:0] c_sp;
  logic [LIW-1:0] c_li;
  logic [63:0]    c_pc;
  st_e            c_nst;

  always_comb begin
    c_wfen=1'b0; c_wfd='0;              c_wfi='0;
    c_spen=1'b0; c_spv='0;
    c_done=1'b0; c_fault=1'b0; c_ret=1'b0; c_route=1'b0; c_pcwe=1'b0;
    c_pop=1'b0;
    c_fc='0; c_ex='0; c_lv='0; c_sp='0; c_li='0; c_pc='0; c_nst=S_IDLE;
    if (st_q == S_VALID) begin
      case (op_q)
        CT_CBRANCH: begin
`ifdef SCIGPU_M5_DBG
          $display("M5ENGIN CBR dsp=%0d bmod=%h tgtE=%0d tgtR=%0d",
              dsp_q, bmod_q, tgt_else_c, tgt_rcv_c);
`endif
          if (cbr_bad) begin
            c_fault=1'b1; c_fc=cbr_fcode;
          end else begin
            c_wfd.ftype=FT_IF;       c_wfd.parent=ex_q;
            c_wfd.mask_a=cbr_f;      c_wfd.mask_b='0;   c_wfd.future='0;
            c_wfd.pc_a=tgt_else_c;   c_wfd.pc_b=tgt_rcv_c;
            c_wfd.phase=cbr_t_ne0 ? 1'b0 : 1'b1;
            c_wfd.prev_loop=li_q;
            c_wfen=1'b1; c_wfi=(sp_q[sl_q]);
            c_spen=1'b1; c_spv=sp_q[sl_q]+(1);
            c_done=1'b1; c_ex=cbr_t_ne0 ? cbr_t : cbr_f;  c_lv=lv_q;
            c_sp=c_spv;  c_li=li_q;
            c_pc=cbr_t_ne0 ? (pc_q+64'd1) : tgt_else_c;   c_pcwe=1'b1;
          end
        end

        CT_RECONV: begin
          if (rcv_bad) begin
            c_fault=1'b1; c_fc=rcv_fcode;
          end else if (rcv_alt) begin
            c_wfd=top_r; c_wfd.mask_a='0; c_wfd.phase=1'b1;
            c_wfen=1'b1; c_wfi=top_idx;
            c_done=1'b1; c_ex=top_r.mask_a & lv_q;  c_lv=lv_q;
            c_sp=sp_q[sl_q]; c_li=li_q;
            c_pc=top_r.pc_a; c_pcwe=1'b1;
          end else begin
            c_spen=1'b1; c_spv=sp_q[sl_q]-(1);
            c_pop=1'b1;
            c_done=1'b1; c_ex=top_r.parent & lv_q;  c_lv=lv_q;
            c_sp=c_spv;  c_li=li_q;
            c_pc=top_r.pc_b+64'd1; c_pcwe=1'b1;
            c_nst=((top_r.parent & lv_q)==32'b0) ? S_UNWIND : S_IDLE;
          end
        end

        CT_LOOPB: begin
          if (lpb_bad) begin
            c_fault=1'b1; c_fc=lpb_fcode;
          end else begin
            c_wfd.ftype=FT_LOOP;     c_wfd.parent=ex_q;
            c_wfd.mask_a=ex_q;       c_wfd.mask_b='0;   c_wfd.future=ex_q;
            c_wfd.pc_a=pc_q+64'd1;   c_wfd.pc_b=tgt_end_c;
            c_wfd.phase=1'b0;        c_wfd.prev_loop=li_q;
            c_wfen=1'b1; c_wfi=(sp_q[sl_q]);
            c_spen=1'b1; c_spv=sp_q[sl_q]+(1);
            c_done=1'b1; c_ex=ex_q;  c_lv=lv_q;
            c_sp=c_spv;  c_li=(sp_q[sl_q]);
            c_pc=pc_q+64'd1; c_pcwe=1'b1;
          end
        end

        CT_LOOPE: begin
          if (lpe_bad) begin
            c_fault=1'b1; c_fc=lpe_fcode;
          end else if (lpe_nxt != 32'b0) begin
            c_wfd=li_r; c_wfd.future=lpe_nxt; c_wfd.mask_a=lpe_nxt;
            c_wfd.mask_b='0;
            c_wfen=1'b1; c_wfi=li_q[IW-1:0];
            c_done=1'b1; c_ex=lpe_nxt; c_lv=lv_q;
            c_sp=sp_q[sl_q]; c_li=li_q;
            c_pc=li_r.pc_a; c_pcwe=1'b1;
          end else begin
            c_spen=1'b1; c_spv=sp_q[sl_q]-(1);
            c_pop=1'b1;
            c_done=1'b1; c_ex=li_r.parent & lv_q;  c_lv=lv_q;
            c_sp=c_spv;  c_li=li_r.prev_loop;
            c_pc=li_r.pc_b+64'd1; c_pcwe=1'b1;
            c_nst=((li_r.parent & lv_q)==32'b0) ? S_UNWIND : S_IDLE;
          end
        end

        CT_PUSHM: begin
          if (sp_q[sl_q] >= (DEPTH)) begin
            c_fault=1'b1; c_fc=FAULT_MASK_STACK_OVERFLOW;
          end else begin
            c_wfd.ftype=FT_MANUAL;   c_wfd.parent=ex_q;
            c_wfd.mask_a='0; c_wfd.mask_b='0; c_wfd.future='0;
            c_wfd.pc_a='0; c_wfd.pc_b='0;
            c_wfd.phase=1'b0;        c_wfd.prev_loop=li_q;
            c_wfen=1'b1; c_wfi=(sp_q[sl_q]);
            c_spen=1'b1; c_spv=sp_q[sl_q]+(1);
            c_done=1'b1; c_ex=ex_q;  c_lv=lv_q;
            c_sp=c_spv;  c_li=li_q;
            c_pc=pc_q+64'd1; c_pcwe=1'b1;
          end
        end

        CT_POPM: begin
          if (pop_bad) begin
            c_fault=1'b1; c_fc=pop_fcode;
          end else begin
            c_spen=1'b1; c_spv=sp_q[sl_q]-(1);
            c_pop=1'b1;
            c_done=1'b1; c_ex=top_r.parent & lv_q;  c_lv=lv_q;
            c_sp=c_spv;  c_li=li_q;
            c_pc=pc_q+64'd1; c_pcwe=1'b1;
            c_nst=((top_r.parent & lv_q)==32'b0) ? S_UNWIND : S_IDLE;
          end
        end

        CT_SETM, CT_ANDM, CT_ORM, CT_XORM: begin
          if (mx_bad) begin
            c_fault=1'b1; c_fc=FAULT_ILLEGAL_CONTROL_FLOW;
          end else begin
            c_done=1'b1; c_ex=mx_res; c_lv=lv_q;
            c_sp=sp_q[sl_q]; c_li=li_q;
            c_pc=pc_q+64'd1; c_pcwe=1'b1;
            c_nst=(mx_res==32'b0) ? S_UNWIND : S_IDLE;
          end
        end

        CT_RETW: begin
          if (sp_q[sl_q]=='0) begin
            c_done=1'b1; c_ret=1'b1;
            c_ex=ex_q;                       // legacy: EXEC value preserved
            c_lv=lv_q & ~ex_q;               // LIVE becomes 0 -> DONE
            c_sp=sp_q[sl_q]; c_li=li_q; c_pcwe=1'b0;
          end else begin
            c_nst=S_RETSCRUB;
          end
        end

        default: begin /* BREAK/CONT dispatched to scrub below */ end
      endcase
    end
  end

  // BREAK/CONTINUE validation (separate so scrub path can share it)
  wire bc_dispatch = (st_q==S_VALID) &&
                     ((op_q==CT_BREAK)||(op_q==CT_CONT));
  wire bc_direct   = (sp_q[sl_q] == (li_q + (1)));

`ifdef SCIGPU_M5_DBG
  always_ff @(posedge clk) begin
    if (!rst && st_q==S_VALID)
      $display("M5ENGIN %0t op=%0d sp=%0d li=%0d tft=%b ph=%b ma=%h pc=%0d",
        $time, op_q, sp_q[sl_q], li_q, top_r.ftype, top_r.phase,
        top_r.mask_a, pc_q);
    if (!rst && (d_done_q||d_fault_q))
      $display("M5ENGIN %0t RESULT done=%b fault=%b pop=%b pc=%0d we=%b ex=%h st=%0d",
        $time, d_done_q, d_fault_q, d_pop_q, d_pc_q, d_pcwe_q, d_ex_q, st_q);
  end
`endif

  // ==============================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      st_q <= S_IDLE;
      op_q<='0; cond_q<='0; pw_q<='0; sl_q<='0;
      pc_q<='0; cw_q<='0; dsp_q<='0; bmod_q<='0;
      ex_q<='0; lv_q<='0; m_q<='0; retm_q<='0;
      wex_q<='0; wlv_q<='0; li_q<=LI_NONE; wi_q<='0;
      d_done_q<=1'b0; d_fault_q<=1'b0; d_fc_q<='0; d_ret_q<=1'b0;
      d_pop_q<=1'b0;
      d_route_q<=1'b0; d_ex_q<='0; d_lv_q<='0; d_sp_q<='0; d_li_q<=LI_NONE;
      d_pc_q<='0; d_pcwe_q<=1'b0;
      wf_en<=1'b0; wf_d<='0; wf_i<='0; sp_en<=1'b0; sp_v<='0;
    end else begin
      d_done_q <= 1'b0; d_fault_q <= 1'b0; d_ret_q <= 1'b0; d_route_q <= 1'b0;
      d_pop_q   <= 1'b0;
      wf_en <= 1'b0; sp_en <= 1'b0;

      case (st_q)
        S_IDLE: begin
          if (cmd_valid) begin
            op_q<=cmd_op; cond_q<=cmd_cond; pw_q<=cmd_pword; sl_q<=cmd_slot;
            pc_q<=cmd_pc; cw_q<=cmd_cw; dsp_q<=cmd_disp24; bmod_q<=cmd_bmod;
            ex_q<=cmd_exec; lv_q<=cmd_live;
            li_q<=cmd_loopidx;
            m_q<='0; retm_q<='0; wi_q<='0;
            st_q<=S_VALID;
          end
        end

        S_VALID: begin
          if (bc_dispatch) begin
            if (bc_no_loop) begin
              d_fault_q<=1'b1; d_fc_q<=FAULT_ILLEGAL_CONTROL_FLOW;
              st_q<=S_IDLE;
            end else begin
              m_q<=(cond_q==4'd15) ? ex_q : (ex_q & pw_q);
              if (bc_direct) begin
                st_q<=S_SCRUB; wi_q<=(DEPTH); // sentinel: apply now
              end else begin
                wi_q<=sp_q[sl_q]-(1);
                st_q<=S_SCRUB;
              end
            end
          end else if (op_q==CT_RETW && !c_done && !c_fault) begin
            retm_q<=ex_q;
            wlv_q<=lv_q & ~ex_q;
            wex_q<='0;
            wi_q<='0;
            st_q<=S_RETSCRUB;
          end else if (c_nst==S_UNWIND) begin
            // defer architectural completion until unwind settles
            wf_en<=c_wfen; wf_d<=c_wfd; wf_i<=c_wfi;
            sp_en<=c_spen; sp_v<=c_spv;
            wex_q<=c_ex; wlv_q<=c_lv;
            st_q<=S_UNWIND;
          end else begin
            d_done_q<=c_done; d_fault_q<=c_fault; d_fc_q<=c_fc;
            d_ret_q<=c_ret;   d_route_q<=c_route;
            d_ex_q<=c_ex;     d_lv_q<=c_lv;
            d_sp_q<=c_sp;     d_li_q<=c_li;
            d_pc_q<=c_pc;     d_pcwe_q<=c_pcwe;
            d_pop_q<=c_pop;
            wf_en<=c_wfen; wf_d<=c_wfd; wf_i<=c_wfi;
            sp_en<=c_spen; sp_v<=c_spv;
            st_q<=c_nst;
          end
        end

        S_SCRUB: begin
`ifdef SCIGPU_M5_DBG
          $display("M5ENGIN SCRUB op=%0d m=%h ex=%h li=%0d wi=%0d sp=%0d",
            op_q, m_q, ex_q, li_q, wi_q, sp_q[sl_q]);
`endif
          if (wi_q == (DEPTH)) begin
            // direct apply: nothing above loop
            wf_d<=li_r;
            if (op_q==CT_BREAK) begin
              wf_d.future<=li_r.future & ~m_q;
              wf_d.mask_a<=li_r.mask_a  & ~m_q;
            end else begin
              wf_d.mask_b<=li_r.mask_b | m_q;
              wf_d.mask_a<=li_r.mask_a & ~m_q;
            end
            wf_en<=1'b1; wf_i<=li_q[IW-1:0];
            if ((ex_q & ~m_q)==32'b0) begin
              wex_q<=32'b0; wlv_q<=lv_q;
              st_q<=S_UNWIND;                 // deferred completion
            end else begin
              d_done_q<=1'b1;
              d_ex_q<=ex_q & ~m_q; d_lv_q<=lv_q;
              d_sp_q<=sp_q[sl_q];  d_li_q<=li_q;
              d_pc_q<=pc_q+64'd1;  d_pcwe_q<=1'b1;
              st_q<=S_IDLE;
            end
          end else if (wi_q <= (li_q)) begin
            // walk complete: apply at loop frame
            wf_d<=li_r;
            if (op_q==CT_BREAK) begin
              wf_d.future<=li_r.future & ~m_q;
              wf_d.mask_a<=li_r.mask_a  & ~m_q;
            end else begin
              wf_d.mask_b<=li_r.mask_b | m_q;
              wf_d.mask_a<=li_r.mask_a & ~m_q;
            end
            wf_en<=1'b1; wf_i<=li_q[IW-1:0];
            if ((ex_q & ~m_q)==32'b0) begin
              wex_q<=32'b0; wlv_q<=lv_q;
              st_q<=S_UNWIND;                 // deferred completion
            end else begin
              d_done_q<=1'b1;
              d_ex_q<=ex_q & ~m_q; d_lv_q<=lv_q;
              d_sp_q<=sp_q[sl_q];  d_li_q<=li_q;
              d_pc_q<=pc_q+64'd1;  d_pcwe_q<=1'b1;
              st_q<=S_IDLE;
            end
          end else begin
            fr_tmp = frames[sl_q][wi_q[IW-1:0]];
            if ((fr_tmp.ftype==FT_IF)||(fr_tmp.ftype==FT_MANUAL)) begin
              wf_d<=fr_tmp;
              wf_d.parent<=fr_tmp.parent & ~m_q;
              wf_d.mask_a<=fr_tmp.mask_a  & ~m_q;
              wf_en<=1'b1; wf_i<=wi_q[IW-1:0];
            end
            wi_q<=wi_q-(1);
          end
        end

        S_RETSCRUB: begin
          if (wi_q >= sp_q[sl_q]) begin
            st_q<=S_UNWIND;                    // EXEC=0, LIVE=wlv_q already
          end else begin
            fr_tmp = frames[sl_q][wi_q[IW-1:0]];
            wf_d<=fr_tmp;
            wf_d.parent<=fr_tmp.parent & ~retm_q;
            wf_d.mask_a<=fr_tmp.mask_a  & ~retm_q;
            wf_d.mask_b<=fr_tmp.mask_b  & ~retm_q;
            wf_d.future<=fr_tmp.future  & ~retm_q;
            wf_en<=1'b1; wf_i<=wi_q[IW-1:0];
            wi_q<=wi_q+(1);
          end
        end

        S_UNWIND: begin
          if (wlv_q==32'b0) begin
            d_done_q<=1'b1; d_ret_q<=1'b1;      // full early return: silent
            d_ex_q<=wex_q; d_lv_q<=wlv_q;
            d_sp_q<=sp_q[sl_q]; d_li_q<=li_q; d_pcwe_q<=1'b0;
            st_q<=S_IDLE;
          end else if (sp_q[sl_q]=='0) begin
            d_fault_q<=1'b1; d_fc_q<=FAULT_INTERNAL;
            st_q<=S_IDLE;
          end else begin
            fr_tmp = top_r;
            if (fr_tmp.ftype==FT_IF) begin
              if ((fr_tmp.mask_a & wlv_q)!=32'b0) begin
`ifdef SCIGPU_M5_DBG
                $display("M5ENGIN RESUME fr_tmp.pc_a=%0d pc_b=%0d sp=%0d",
                    fr_tmp.pc_a, fr_tmp.pc_b, sp_q[sl_q]);
`endif
                wf_d<=fr; wf_d.mask_a<='0; wf_d.phase<=1'b1;
                wf_en<=1'b1; wf_i<=top_idx;
                d_done_q<=1'b1;
                d_ex_q<=fr_tmp.mask_a & wlv_q; d_lv_q<=wlv_q;
                d_sp_q<=sp_q[sl_q]; d_li_q<=li_q;
                d_pc_q<=fr_tmp.pc_a; d_pcwe_q<=1'b1;
                st_q<=S_IDLE;
              end else begin
                sp_en<=1'b1; sp_v<=sp_q[sl_q]-(1);
                wex_q<=fr_tmp.parent & wlv_q;
                d_pc_q<=fr_tmp.pc_b+64'd1; d_pcwe_q<=1'b1;
                if ((fr_tmp.parent & wlv_q)!=32'b0) begin
                  d_done_q<=1'b1;
                  d_ex_q<=fr_tmp.parent & wlv_q; d_lv_q<=wlv_q;
                  d_sp_q<=sp_v; d_li_q<=li_q;
                  st_q<=S_IDLE;
                end
                // else remain in UNWIND and keep popping
              end
            end else if (fr_tmp.ftype==FT_LOOP) begin
              d_done_q<=1'b1; d_route_q<=1'b1;
              d_ex_q<=32'b0; d_lv_q<=wlv_q;
              d_sp_q<=sp_q[sl_q]; d_li_q<=li_q;
              d_pc_q<=fr_tmp.pc_b; d_pcwe_q<=1'b1;
              st_q<=S_IDLE;
            end else begin
              sp_en<=1'b1; sp_v<=sp_q[sl_q]-(1);   // MANUAL
              wex_q<=fr_tmp.parent & wlv_q;
              if ((fr_tmp.parent & wlv_q)!=32'b0) begin
                d_done_q<=1'b1;
                d_ex_q<=fr_tmp.parent & wlv_q; d_lv_q<=wlv_q;
                d_sp_q<=sp_v; d_li_q<=li_q;
                d_pcwe_q<=1'b0;
                st_q<=S_IDLE;
              end
            end
          end
        end

        default: st_q<=S_IDLE;
      endcase
    end
  end

`ifdef SCIGPU_FORMAL
  // M5-ASSERT-002: stack pointer never exceeds configured depth
  sp_bounds_check: assert property (@(posedge clk) disable iff (rst)
    (sp_q[dbg_slot] <= (DEPTH)));
`endif

  assign dbg_sp = sp_q[dbg_slot];
  wire [IW-1:0] dbg_ti = (sp_q[dbg_slot]!='0)
                       ? (sp_q[dbg_slot]-(1)) : (0);

endmodule
