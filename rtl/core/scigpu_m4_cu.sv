// SciGPU M4 — multi-resident-wavefront Compute Unit (SCHED-001 Rev0.1)
// N resident contexts; shared scalar path + shared vector engine;
// deterministic RR issue (formally verified); tagged fetch/completions.
module scigpu_m4_cu #(
  parameter int unsigned SGPR_COUNT = 64,
  parameter int unsigned VGPR_COUNT = 32,
  parameter int unsigned SIMD_LANES = 8,
  parameter int unsigned RESIDENT_WAVEFRONTS_PER_CU = 4,
  parameter int unsigned PMC_WIDTH  = 64
) (
  input  logic clk, input logic rst,
  output logic if_req_valid, output logic [63:0] if_req_pc,
  input  logic if_req_ready,
  input  logic if_rsp_valid, input  logic [63:0] if_rsp_insn,
  input  logic if_rsp_error, output logic        if_rsp_ready,
  input  logic wf_launch_valid, output logic wf_launch_ready,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] wf_launch_slot,
  input  logic [63:0] wf_entry_pc, input logic [63:0] wf_code_words,
  input  logic [31:0] wf_wg_x, input logic [31:0] wf_exec_mask,
  input  logic [8:0]  wf_vgpr_req, input logic [8:0] wf_sgpr_req,
  output logic wf_completion_valid, input logic wf_completion_ready,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] wf_completion_slot,
  output logic wf_completion_fault,
  output logic [5:0]  wf_completion_fault_code,
  output logic [63:0] wf_completion_pc,
  output logic [63:0] wf_completion_retired_count,
  input  logic sgpr_init_valid,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] sgpr_init_slot,
  input  logic [7:0]  sgpr_init_addr, input logic [31:0] sgpr_init_data,
  output logic sgpr_init_ready,
  input  logic pred_init_valid,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] pred_init_slot,
  input  logic [3:0]  pred_init_addr, input logic [31:0] pred_init_data,
  output logic pred_init_ready,
  input  logic vgpr_init_valid,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] vgpr_init_slot,
  input  logic [7:0]  vgpr_init_addr, input logic [4:0] vgpr_init_lane,
  input  logic [31:0] vgpr_init_data, output logic vgpr_init_ready,
  output logic [RESIDENT_WAVEFRONTS_PER_CU-1:0] dbg_allocated,
  output logic [RESIDENT_WAVEFRONTS_PER_CU-1:0] dbg_issueable,
  output logic [RESIDENT_WAVEFRONTS_PER_CU-1:0] dbg_inflight,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] dbg_rr_ptr,
  output logic sched_issue_valid,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] sched_issue_wfid,
  output logic [63:0] sched_issue_pc, sched_issue_insn,
  output logic [1:0]  sched_issue_pipe,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] sched_rr_before,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] sched_rr_after,
  output logic [31:0] dbg_resident_count, dbg_ready_count,
  dbg_issueable_count,
  output logic [PMC_WIDTH-1:0] PMC_CYCLES, PMC_RESIDENT_CYCLES,
    PMC_ISSUE_CYCLES, PMC_SCALAR_ISSUES, PMC_VECTOR_ISSUES,
    PMC_NO_ISSUE_CYCLES, PMC_FETCH_WAIT_CYCLES, PMC_PIPE_BUSY_CYCLES,
    PMC_WAVEFRONTS_LAUNCHED, PMC_WAVEFRONTS_COMPLETED,
    PMC_WAVEFRONTS_FAULTED, PMC_CONTEXT_SWITCHES,
  output logic trace_s_valid,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] trace_s_wfid,
  output logic [63:0] trace_s_pc, trace_s_insn, trace_s_next_pc,
  output logic trace_s_sgpr_we, output logic [7:0] trace_s_sgpr_addr,
  output logic [31:0] trace_s_sgpr_wdata,
  output logic trace_v_valid,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] trace_v_wfid,
  output logic [63:0] trace_v_pc, trace_v_insn, trace_v_next_pc,
  output logic [31:0] trace_v_exec_mask, trace_v_effective_mask,
  output logic [3:0]  trace_v_pred_idx,
  output logic trace_v_we, output logic [7:0] trace_v_addr,
  output logic [31:0] trace_v_write_mask,
  output logic [63:0] dbg_last_compl_pc,
  output scigpu_types_pkg::state_e dbg_state,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] dbg_wf_sel,
  input  logic [7:0]  dbg_sgpr_addr, output logic [31:0] dbg_sgpr_data,
  input  logic [3:0]  dbg_pred_addr, output logic [31:0] dbg_pred_data,
  input  logic [7:0]  dbg_vgpr_addr, input logic [4:0] dbg_vgpr_lane,
  output logic [31:0] dbg_vgpr_data
);

  import scigpu_isa_pkg::*;
  import scigpu_types_pkg::*;

  localparam int unsigned N  = RESIDENT_WAVEFRONTS_PER_CU;
  localparam int unsigned PW = (N <= 1) ? 1 : $clog2(N);
  localparam int unsigned B  = 32 / SIMD_LANES;

  // ================= per-slot architectural state ===========================
  typedef enum logic [2:0] { WS_EMPTY=3'd0, WS_READY=3'd1, WS_ISSUED=3'd2,
                             WS_DONE=3'd3, WS_FAULTED=3'd4 } ws_e;

  ws_e         wstate [N];
  logic [63:0] pc_q   [N];
  logic [63:0] cw_q   [N];
  logic [31:0] exec_q [N];
  logic [31:0] wgx_q  [N];
  logic [8:0]  vreq_q [N], sreq_q [N];
  logic [63:0] ret_q  [N];
  logic [3:0]  flg_q  [N];
  logic        scc_q  [N];
  logic [5:0]  fc_q   [N];
  logic [63:0] cpc_q  [N];

  logic [N-1:0] ibuf_v;
  logic [63:0]  ibuf_i [N];
  logic [N-1:0] ibuf_e;

  logic          f_pend;
  logic [PW-1:0] f_owner;

  logic          ve_busy;
  logic [PW-1:0] ve_own;
  logic [63:0]   ve_tpc;
  logic [63:0]   ve_tinsn;
  logic [31:0]   ve_teff;
  logic [3:0]    ve_tpred;

  wire launch_ok   = (wstate[wf_launch_slot] == WS_EMPTY);
  assign wf_launch_ready = launch_ok;
  wire do_launch   = wf_launch_valid && launch_ok;

  genvar gv;
  generate for (gv = 0; gv < N; gv++) begin : g_ws
    always_ff @(posedge clk) begin
      if (rst) begin
        wstate[gv]<=WS_EMPTY; pc_q[gv]<='0; cw_q[gv]<='0; exec_q[gv]<='0;
        wgx_q[gv]<='0; vreq_q[gv]<='0; sreq_q[gv]<='0; ret_q[gv]<='0;
        flg_q[gv]<='0; scc_q[gv]<=1'b0; fc_q[gv]<='0; cpc_q[gv]<='0;
        ibuf_v[gv]<=1'b0; ibuf_i[gv]<='0; ibuf_e[gv]<=1'b0;
      end else if (do_launch && (wf_launch_slot == PW'(gv))) begin
        wstate[gv]<=WS_READY; pc_q[gv]<=wf_entry_pc; cw_q[gv]<=wf_code_words;
        exec_q[gv]<=wf_exec_mask; wgx_q[gv]<=wf_wg_x;
        vreq_q[gv]<=wf_vgpr_req; sreq_q[gv]<=wf_sgpr_req;
        ret_q[gv]<='0; flg_q[gv]<='0; scc_q[gv]<=1'b0;
        ibuf_v[gv]<=1'b0; ibuf_e[gv]<=1'b0;
      end
    end
  end endgenerate

  // ============================ fetch =======================================
  logic [N-1:0] needs_fetch, pc_oob;
  always_comb begin
    for (int s = 0; s < N; s++) begin
      automatic bit rdy = (wstate[s]==WS_READY) && !ibuf_v[s];
      needs_fetch[s] = rdy && !f_pend && !(pc_q[s] >= cw_q[s]);
      pc_oob[s]      = rdy && (pc_q[s] >= cw_q[s]);
    end
  end

  logic [PW-1:0] fetch_rr_q;
  logic          fg_found; logic [PW-1:0] fg_id;
  int unsigned f_sum; int unsigned f_mod; logic [PW-1:0] f_idx;
  always_comb begin
    fg_found = 1'b0; fg_id = '0;
    for (int unsigned k = 0; k < N; k++) begin
      f_sum = 32'(fetch_rr_q) + k;
      f_mod = f_sum % N;
      f_idx = PW'(f_mod);
      if (!fg_found && needs_fetch[f_idx]) begin
        fg_found = 1'b1; fg_id = f_idx;
      end
    end
  end

  logic f_cmd; logic [63:0] f_cmd_pc;
  logic f_acc, f_rspv, f_rspe; logic [63:0] f_rsp_i; logic f_rsprdy;
  scigpu_fetch u_fetch (
    .clk(clk), .rst(rst),
    .cmd_valid(f_cmd), .cmd_pc(f_cmd_pc), .busy(f_busy_unused), .req_accepted(f_acc),
    .if_req_valid(if_req_valid), .if_req_pc(if_req_pc),
    .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_insn(if_rsp_insn),
    .if_rsp_error(if_rsp_error), .if_rsp_ready(if_rsp_ready),
    .rsp_ready(f_rsprdy), .rsp_valid(f_rspv),
    .rsp_insn(f_rsp_i), .rsp_error(f_rspe));
  assign f_cmd = fg_found;
  wire fetch_fire = f_cmd && f_acc;
`ifdef SCIGPU_TB_DEBUG
  always_ff @(posedge clk) begin
    if (!rst && (fg_found || f_pend || |ibuf_v))
      $display("M4FETCH t=%0t found=%d id=%0d cmd=%d acc=%d fire=%d pend=%d owner=%0d rspv=%d ibuf=%b",
               $time, fg_found, fg_id, f_cmd, f_acc, fetch_fire, f_pend, f_owner, f_rspv, ibuf_v);
  end
`endif
  wire rsp_take   = f_rspv && f_rsprdy;
  assign f_rsprdy = 1'b1;

  always_comb begin
    f_cmd_pc = '0;
    for (int s = 0; s < N; s++)
      if (fg_id == PW'(s)) f_cmd_pc = pc_q[s];
  end

  integer ii;
  always_ff @(posedge clk) begin
    if (rst) begin
      fetch_rr_q <= '0; f_pend <= 1'b0; f_owner <= '0;
      for (ii = 0; ii < N; ii++) begin
        ibuf_v[ii] <= 1'b0; ibuf_i[ii] <= '0; ibuf_e[ii] <= 1'b0;
      end
    end else begin
      if (fetch_fire) begin
        fetch_rr_q <= (32'(fg_id)+1 == 32'(N)) ? '0 : fg_id + 1'b1;
        f_pend     <= 1'b1;
        f_owner    <= fg_id;
      end else if (rsp_take)
        f_pend <= 1'b0;

      if (rsp_take) begin
        ibuf_i[f_owner] <= f_rsp_i;
        ibuf_e[f_owner] <= f_rspe;
        ibuf_v[f_owner] <= 1'b1;
      end
    end
  end

  // OOB PC faults: immediate per-wavefront FAULTED (directive §60)
  integer io;
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (io = 0; io < N; io++)
        if (pc_oob[io]) begin
          wstate[io] <= WS_FAULTED;
          fc_q[io]   <= FAULT_INVALID_ADDRESS;
          cpc_q[io]  <= pc_q[io];
        end
    end
  end

  // ==================== per-slot predecode ==================================
  logic [N-1:0] d_legal_v, d_isvec_v, vmod_bad_v, getid_bad_v;
  iclass_e d_cls [N];
  logic [7:0]  d_dst[N], d_src0[N], d_src1[N];
  logic [7:0]  d_vd[N], d_vs0[N], d_vs1[N];
  logic [3:0]  d_va_op[N]; logic [1:0] d_va_bmux[N]; logic [3:0] d_pred[N];
  logic [31:0] d_imm[N]; logic d_useimm[N];
  logic signed [23:0] d_disp[N]; logic [7:0] d_cond[N];
  logic [7:0]  d_gsel[N];
  logic [7:0]  d_gdst[N];

  generate for (genvar gj = 0; gj < N; gj++) begin : g_dec
    scigpu_decode_m3 u_dec (
      .insn(ibuf_i[gj]), .legal(d_legal_v[gj]), .is_vector(d_isvec_v[gj]),
      .cls(d_cls[gj]), .va_op(d_va_op[gj]), .va_bmux(d_va_bmux[gj]),
      .dst(d_dst[gj]), .src0(d_src0[gj]), .src1(d_src1[gj]),
      .vd(d_vd[gj]), .vs0(d_vs0[gj]), .vs1(d_vs1[gj]),
      .use_imm(d_useimm[gj]), .imm(d_imm[gj]), .disp24(d_disp[gj]),
      .cond(d_cond[gj]), .getid_sel(d_gsel[gj]),
      .getid_dst(d_gdst[gj]), .pred(d_pred[gj]));
    assign vmod_bad_v[gj] = d_isvec_v[gj] && (ibuf_i[gj][11:0] != 12'd0);
    assign getid_bad_v[gj]= (!d_isvec_v[gj]) && (d_cls[gj]==CLS_GETID) &&
                            (d_gsel[gj] != 8'd0);
  end endgenerate

  // ============================ RR issue ====================================
  logic ve_setup_ready;
  logic ve_last_commit;

  logic [N-1:0] issueable;
  always_comb begin
    for (int s = 0; s < N; s++) begin
      automatic bit backend_ok = d_isvec_v[s] ? ve_setup_ready : 1'b1;
      automatic bit faultc = ibuf_e[s] || vmod_bad_v[s] ||
                             !d_legal_v[s] || getid_bad_v[s];
      issueable[s] = (wstate[s]==WS_READY) && ibuf_v[s] &&
                     (faultc || ((d_isvec_v[s] && backend_ok) ||
                                 (!d_isvec_v[s] && 1'b1)));
    end
  end

  logic gvv; logic [PW-1:0] gid, rr_q, rr_n; logic [N-1:0] g1h;
  scigpu_rr_scheduler #(.N(N)) u_rr (
    .clk(clk), .rst(rst), .issueable(issueable),
    .issue_accept(gvv),
    .grant_valid(gvv), .grant_id(gid), .grant_onehot(g1h),
    .rr_ptr(rr_q), .rr_ptr_next(rr_n));

  // granted-slot capture
  logic [7:0]  g_dst, g_src0, g_src1, g_vd, g_vs0, g_vs1;
  logic [31:0] g_imm; logic [3:0] g_pred, g_va_op;
  logic [1:0]  g_va_bmux; logic g_useimm; iclass_e g_cls;
  logic [63:0] g_pc; logic [31:0] g_exec, g_wgx;
  logic [8:0]  g_vq, g_sq;
  logic        g_isvec, g_legal, g_ibuferr, g_vmodbad, g_getidbad;
  logic [7:0]  g_cond, g_getiddst;
  always_comb begin
    g_dst='0; g_src0='0; g_src1='0; g_vd='0; g_vs0='0; g_vs1='0;
    g_imm='0; g_pred=PRED_NONE[3:0]; g_va_op='0; g_va_bmux='0; g_useimm=1'b0;
    g_cls=CLS_NONE; g_pc='0; g_exec='0; g_wgx='0; g_vq='0; g_sq='0;
    g_isvec=1'b0; g_legal=1'b0; g_ibuferr=1'b0; g_vmodbad=1'b0;
    g_getidbad=1'b0; g_cond='0; g_getiddst='0;
    for (int s = 0; s < N; s++)
      if (g1h[s]) begin
        g_dst=d_dst[s]; g_src0=d_src0[s]; g_src1=d_src1[s];
        g_vd=d_vd[s]; g_vs0=d_vs0[s]; g_vs1=d_vs1[s];
        g_imm=d_imm[s]; g_pred=d_pred[s]; g_va_op=d_va_op[s];
        g_va_bmux=d_va_bmux[s]; g_useimm=d_useimm[s]; g_cls=d_cls[s];
        g_pc=pc_q[s]; g_exec=exec_q[s]; g_wgx=wgx_q[s];
        g_vq=vreq_q[s]; g_sq=sreq_q[s];
        g_isvec=d_isvec_v[s]; g_legal=d_legal_v[s];
        g_ibuferr=ibuf_e[s]; g_vmodbad=vmod_bad_v[s];
        g_getidbad=getid_bad_v[s]; g_cond=d_cond[s]; g_getiddst=d_gsel[s];
      end
  end

  // validation before any effect (directive §28/§119)
  wire v_u0 = (g_cls==CLS_VEC_ALU)||(g_cls==CLS_VEC_MUL);
  wire v_u1 = v_u0 && (g_va_bmux==2'd0);
  wire v_ud = (g_cls==CLS_VEC_PASS)||(g_cls==CLS_VEC_ALU)||
              (g_cls==CLS_VEC_MUL)||(g_cls==CLS_VEC_LLANE);
  wire v_bcast = (g_cls==CLS_VEC_PASS)&&(g_va_bmux==2'd3);
  wire bad_vec_reg =
      (v_ud  && (32'(g_vd)  >= {1'b0,g_vq})) ||
      (v_u0  && (32'(g_vs0) >= {1'b0,g_vq})) ||
      (v_u1  && (32'(g_vs1) >= {1'b0,g_vq}));
  wire s_u0 = (g_cls==CLS_MOV)||(g_cls==CLS_ALU)||(g_cls==CLS_MUL)||
              (g_cls==CLS_CMP);
  wire s_u1 = s_u0 && !g_useimm && (g_cls!=CLS_MOV);
  wire s_ud = (g_cls==CLS_MOV)||(g_cls==CLS_ALU)||(g_cls==CLS_MUL)||
              (g_cls==CLS_GETID);
  wire bad_sc_reg =
      (s_u0 && (32'(g_src0) >= {1'b0,g_sq})) ||
      (s_u1 && (32'(g_src1) >= {1'b0,g_sq})) ||
      (s_ud && (32'(g_dst) >= {1'b0,g_sq}));

`ifdef SCIGPU_TB_DEBUG
  always_ff @(posedge clk) begin
    if (!rst && gvv)
      $display("M4ISSUE t=%0t gid=%0d cls=%0d vec=%d legal=%d vmod=%d gidbad=%d vreg=%d sreg=%d fault=%d fcode=%02x pc=%0d insn=%h",
        $time, gid, g_cls, g_isvec, g_legal, g_vmodbad, g_getidbad,
        bad_vec_reg, bad_sc_reg, issue_is_fault, issue_fcode, g_pc, ibuf_i[gid]);
  end
`endif
  wire issue_is_fault = g_ibuferr || !g_legal || g_vmodbad ||
                        g_getidbad || bad_vec_reg || bad_sc_reg;
  wire [5:0] issue_fcode =
      g_ibuferr                                  ? FAULT_INVALID_ADDRESS :
      (!g_legal || g_vmodbad || g_getidbad)      ? FAULT_ILLEGAL_OPCODE :
                                                   FAULT_INVALID_REGISTER;

  // effective mask for granted slot
  logic [31:0] p_iss_data;
  wire [31:0] g_eff = (g_pred == PRED_NONE[3:0]) ? g_exec : (g_exec & p_iss_data);

  // ==================== storage (slot-dimensioned) ==========================
  logic [7:0]  s_raddr0, s_raddr1, s_rb_addr;
  logic [31:0] s_rdata0, s_rdata1, s_rb_data;
  logic        s_we; logic [PW-1:0] s_wslot; logic [7:0] s_wa; logic [31:0] s_wd;

  scigpu_sgpr_file_m4 #(.SGPR_COUNT(SGPR_COUNT), .N(N)) u_sgpr (
    .clk(clk), .rst(rst),
    .init_we(sgpr_init_valid && sgpr_init_ready),
    .init_slot(sgpr_init_slot), .init_addr(sgpr_init_addr),
    .init_data(sgpr_init_data),
    .rd_slot(gid), .raddr0(s_raddr0), .raddr1(s_raddr1),
    .rdata0(s_rdata0), .rdata1(s_rdata1),
    .rb_slot(gid), .rb_addr(g_vs0), .rb_data(s_rb_data),
    .we(s_we), .wslot(gid), .waddr(sc_wa), .wdata(salu_y),
    .dbg_slot(dbg_wf_sel), .dbg_addr(dbg_sgpr_addr),
    .dbg_data(dbg_sgpr_data));

  logic [31:0] p_rep_data;
  scigpu_pred_file_m4 #(.N(N)) u_pred (
    .clk(clk), .rst(rst),
    .init_we(pred_init_valid && pred_init_ready),
    .init_slot(pred_init_slot), .init_addr(pred_init_addr),
    .init_data(pred_init_data),
    .rd_slot(ve_own), .rd_addr(ve_tpred), .rd_data(p_rep_data),
    .iss_slot(gid), .iss_addr(g_pred), .iss_data(p_iss_data),
    .dbg_slot(dbg_wf_sel), .dbg_addr(dbg_pred_addr),
    .dbg_data(dbg_pred_data));
  assign pred_init_ready = 1'b1;
  assign sgpr_init_ready = 1'b1;

  // vector engine
  logic [7:0]  ve_raddr0, ve_raddr1; logic [4:0] ve_rlane_base;
  logic [31:0] ve_rdata0 [SIMD_LANES]; logic [31:0] ve_rdata1 [SIMD_LANES];
  logic        ve_we; logic [7:0] ve_wa; logic [4:0] ve_wb;
  logic [SIMD_LANES-1:0] ve_wm; logic [31:0] ve_wd [SIMD_LANES];
  logic [3:0]  ve_setup_op; logic [1:0] ve_setup_bmux;
  logic [7:0]  ve_setup_vd, ve_setup_vs0, ve_setup_vs1;
  logic [31:0] ve_setup_imm, ve_setup_bcast;

  scigpu_vector_engine #(.SIMD_LANES(SIMD_LANES)) u_eng (
    .clk(clk), .rst(rst),
    .setup_valid(vec_setup_valid), .setup_ready(ve_setup_ready),
    .setup_op(ve_setup_op), .setup_bmux(ve_setup_bmux),
    .setup_vd(ve_setup_vd), .setup_vs0(ve_setup_vs0),
    .setup_vs1(ve_setup_vs1), .setup_imm(ve_setup_imm),
    .setup_bcast_data(ve_setup_bcast),
    .setup_effective_mask(ve_setup_eff),
    .vg_raddr0(ve_raddr0), .vg_raddr1(ve_raddr1),
    .vg_rlane_base(ve_rlane_base),
    .vg_rdata0(ve_rdata0), .vg_rdata1(ve_rdata1),
    .vg_we(ve_we), .vg_waddr(ve_wa), .vg_wlane_base(ve_wb),
    .vg_wmask(ve_wm), .vg_wdata(ve_wd),
    .beat_valid(beat_valid_u), .beat_index(beat_index_u),
    .beat_base(beat_base_u), .beat_mask(beat_mask_u), .beat_vdst(beat_vdst_u),
    .last_commit(ve_last_commit));

  scigpu_vgpr_file_m4 #(
    .VGPR_COUNT(VGPR_COUNT), .SIMD_LANES(SIMD_LANES), .N(N)
  ) u_vgpr (
    .clk(clk), .rst(rst),
    .init_we(vgpr_init_valid && vgpr_init_ready),
    .init_slot(vgpr_init_slot), .init_vgpr(vgpr_init_addr),
    .init_lane(vgpr_init_lane), .init_data(vgpr_init_data),
    .rd_slot(ve_own), .raddr0(ve_raddr0), .raddr1(ve_raddr1),
    .rlane_base(ve_rlane_base),
    .rdata0(ve_rdata0), .rdata1(ve_rdata1),
    .we(ve_we), .wslot(ve_own), .waddr(ve_wa), .wlane_base(ve_wb),
    .wmask(ve_wm), .wdata(ve_wd),
    .dbg_slot(dbg_wf_sel), .dbg_vgpr(dbg_vgpr_addr),
    .dbg_lane(dbg_vgpr_lane), .dbg_data(dbg_vgpr_data));
  assign vgpr_init_ready = 1'b1;

  // ================ issue-time routing ======================================
  assign vec_setup_valid      = gvv && !issue_is_fault && g_isvec;
  assign vec_op               = g_va_op;
  assign vec_bmux             = g_va_bmux;
  assign vec_vd               = g_vd;
  assign vec_vs0              = g_vs0;
  assign vec_vs1              = g_vs1;
  assign vec_imm              = g_imm;
  assign vec_effective_mask   = g_eff;
  assign vec_bcast_data       = s_rb_data;

  // read routing for granted slot
  always_comb begin
    s_raddr0='0; s_raddr1='0; s_rb_addr='0;
    if (!issue_is_fault && gvv) begin
      if (!g_isvec) begin
        s_raddr0 = g_src0;
        s_raddr1 = g_useimm ? '0 : g_src1;
      end else begin
        s_raddr0 = g_vs0;
        s_raddr1 = g_vs1;
        if (v_bcast) begin
          s_raddr0 = g_vs0; s_raddr1 = '0; s_rb_addr = g_vs0;
        end
        if (g_cls==CLS_VEC_LLANE ||
           (g_cls==CLS_VEC_PASS && g_va_bmux==2'd1)) begin
          s_raddr0='0; s_raddr1='0;
        end
      end
    end
  end
  assign p_iss_slot = gid;
  assign p_iss_addr = g_pred;

  wire [11:0] opc_g = ibuf_i[gid][63:52];

  // ==================== scalar execute ======================================
  localparam bit [3:0] ALU_PASS_B=4'd0, ALU_ADD=4'd1, ALU_SUB=4'd2,
    ALU_AND=4'd3, ALU_OR=4'd4, ALU_XOR=4'd5, ALU_NOT=4'd6, ALU_SHL=4'd7,
    ALU_SHR=4'd8, ALU_SAR=4'd9, ALU_MUL=4'd10;

  logic [3:0] salu_op; logic [31:0] salu_a, salu_b, salu_y;
  always_comb begin
    case (opc_g)
      OPC_S_ADD : salu_op=ALU_ADD;  OPC_S_SUB : salu_op=ALU_SUB;
      OPC_S_AND : salu_op=ALU_AND;  OPC_S_OR  : salu_op=ALU_OR;
      OPC_S_XOR : salu_op=ALU_XOR;  OPC_S_NOT : salu_op=ALU_NOT;
      OPC_S_SHL : salu_op=ALU_SHL;  OPC_S_SHR : salu_op=ALU_SHR;
      OPC_S_SAR : salu_op=ALU_SAR;  OPC_S_MUL : salu_op=ALU_MUL;
      default   : salu_op=ALU_PASS_B;
    endcase
  end
  always_comb begin
    salu_a = s_rdata0;
    salu_b = g_useimm ? g_imm : s_rdata1;
    if ((g_cls==CLS_MOV) && !g_useimm) salu_b = s_rdata0;
    if ((g_cls==CLS_MOV) &&  g_useimm) salu_b = g_imm;
    if (g_cls==CLS_GETID) begin salu_a='0; salu_b=g_wgx; end
  end
  scigpu_scalar_alu u_sal (.a(salu_a), .b(salu_b), .op(salu_op), .y(salu_y));

  wire [31:0] cmp_r = s_rdata0 - s_rdata1;
  logic [1:0] cmp_kind;
  always_comb begin
    case (opc_g)
      OPC_S_CMP_LT: cmp_kind=2'd1; OPC_S_CMP_GT: cmp_kind=2'd2;
      default     : cmp_kind=2'd0;
    endcase
  end
  logic fz,fn,fc_,fv,fscc;
  scigpu_scalar_flags u_fl (.a(s_rdata0), .b(s_rdata1), .r(cmp_r),
    .cmp_kind, .z(fz), .n(fn), .c(fc_), .v(fv), .scc(fscc));

  logic cond_taken;
  always_comb begin
    cond_taken = 1'b0;
    case (g_cond)
      COND_ALWAYS: cond_taken=1'b1;
      COND_SCC : cond_taken=scc_q[gid]; COND_NSCC: cond_taken=~scc_q[gid];
      COND_Z   : cond_taken=flg_q[gid][0]; COND_NZ: cond_taken=~flg_q[gid][0];
      COND_N   : cond_taken=flg_q[gid][1]; COND_NN: cond_taken=~flg_q[gid][1];
      COND_C   : cond_taken=flg_q[gid][2]; COND_NC: cond_taken=~flg_q[gid][2];
      COND_V   : cond_taken=flg_q[gid][3]; COND_NV: cond_taken=~flg_q[gid][3];
      COND_LT_S: cond_taken=flg_q[gid][1]^flg_q[gid][3];
      COND_GE_S: cond_taken=~(flg_q[gid][1]^flg_q[gid][3]);
      COND_LT_U: cond_taken=~flg_q[gid][2];
      COND_GE_U: cond_taken= flg_q[gid][2];
      default  : cond_taken=1'b0;
    endcase
  end

  // scalar single-cycle commit strobes
  wire sc_fire = gvv && !issue_is_fault && !g_isvec;
  wire sc_wen  = sc_fire &&
      ((g_cls==CLS_MOV)||(g_cls==CLS_ALU)||(g_cls==CLS_MUL)||
       (g_cls==CLS_GETID));
  wire sc_flags_w = sc_fire && (g_cls==CLS_CMP);
  wire sc_is_ret  = sc_fire && (g_cls==CLS_RET);
  wire [63:0] sc_next_pc = g_pc + 64'd1;
  wire sc_is_branch = sc_fire && ((g_cls==CLS_BRA)||(g_cls==CLS_BRA_C));

  logic [23:0] g_disp;
  always_comb begin
    g_disp = '0;
    for (int s = 0; s < N; s++)
      if (g1h[s]) g_disp = d_disp[s];
  end
  wire [63:0] br_tgt = g_pc + 64'd1 + {{40{g_disp[23]}}, g_disp};

  logic br_taken;
  always_comb begin
    br_taken = 1'b0;
    case (g_cond)
      COND_ALWAYS: br_taken=1'b1;
      COND_SCC : br_taken=scc_q[gid]; COND_NSCC: br_taken=~scc_q[gid];
      COND_Z   : br_taken=flg_q[gid][0]; COND_NZ: br_taken=~flg_q[gid][0];
      COND_N   : br_taken=flg_q[gid][1]; COND_NN: br_taken=~flg_q[gid][1];
      COND_C   : br_taken=flg_q[gid][2]; COND_NC: br_taken=~flg_q[gid][2];
      COND_V   : br_taken=flg_q[gid][3]; COND_NV: br_taken=~flg_q[gid][3];
      COND_LT_S: br_taken=flg_q[gid][1]^flg_q[gid][3];
      COND_GE_S: br_taken=~(flg_q[gid][1]^flg_q[gid][3]);
      COND_LT_U: br_taken=~flg_q[gid][2];
      COND_GE_U: br_taken= flg_q[gid][2];
      default  : br_taken=1'b0;
    endcase
  end

  wire [63:0] sc_next_pc_final =
      sc_is_branch ? (cond_taken ? br_tgt : g_pc + 64'd1) :
      sc_is_ret    ? g_pc :
      g_pc + 64'd1;

  // ==================== per-slot commits ====================================
  wire [7:0] getid_dst_g = ibuf_i[gid][15:8];

  always_ff @(posedge clk) begin
    if (!rst && sc_fire) begin
      pc_q[gid] <= sc_next_pc_final;
      ret_q[gid] <= ret_q[gid] + 64'd1;
      ibuf_v[gid] <= 1'b0;
      if (sc_flags_w) begin
        flg_q[gid] <= {fv,fc_,fn,fz};
        scc_q[gid] <= fscc;
      end
      if (sc_is_ret) begin
        wstate[gid] <= WS_DONE;
        fc_q[gid]   <= '0;
        cpc_q[gid]  <= g_pc;
      end else begin
        wstate[gid] <= WS_READY;
      end
    end
  end

  // SGPR write (single-cycle commit)
  wire sgpr_commit_we = sc_fire && sc_wen;
  wire [7:0] sgpr_commit_wa = (g_cls==CLS_GETID) ? getid_dst_g : g_dst;

  // fault-candidate immediate commit
  always_ff @(posedge clk) begin
    if (!rst && gvv && issue_is_fault) begin
      wstate[gid] <= WS_FAULTED;
      fc_q[gid]   <= issue_fcode;
      cpc_q[gid]  <= g_pc;
      ibuf_v[gid] <= 1'b0;
    end
  end

  // vector retire commit
  always_ff @(posedge clk) begin
    if (!rst && ve_last_commit) begin
      pc_q[ve_own]   <= pc_q[ve_own] + 64'd1;
      ret_q[ve_own]  <= ret_q[ve_own] + 64'd1;
      wstate[ve_own] <= WS_READY;
    end
  end

  // vector setup accept: latch owner + context
  wire vec_setup_accept = vec_setup_valid && ve_setup_ready;
  always_ff @(posedge clk) begin
    if (rst) begin
      ve_busy <= 1'b0; ve_own <= '0;
      ve_tpc <= '0; ve_tinsn <= '0; ve_teff <= '0; ve_tpred <= '0;
    end else begin
      if (vec_setup_accept) begin
        ve_busy <= 1'b1;
        ve_own  <= gid;
        ve_tpc   <= g_pc;
        ve_tinsn <= ibuf_i[gid];
        ve_teff  <= g_eff;
        ve_tpred <= g_pred;
      end else if (ve_last_commit)
        ve_busy <= 1'b0;
    end
  end

  // ==================== completion reporter =================================
  logic        rep_pending;
  logic [PW-1:0] rep_slot;
  logic [5:0] rep_fc; logic [63:0] rep_cpc; logic [63:0] rep_ret;
  logic       rep_fault;

  always_comb begin
    rep_pending = 1'b0; rep_slot='0; rep_fc='0; rep_cpc='0;
    rep_ret='0; rep_fault=1'b0;
    for (int s = N-1; s >= 0; s--) begin
      if ((wstate[s]==WS_DONE)||(wstate[s]==WS_FAULTED)) begin
        rep_pending = 1'b1;
        rep_slot = PW'(s);
        rep_fc   = fc_q[s];
        rep_cpc  = cpc_q[s];
        rep_ret  = ret_q[s];
        rep_fault= (wstate[s]==WS_FAULTED);
      end
    end
  end

  wire rep_release = wf_completion_valid && wf_completion_ready;
  integer ir;
  always_ff @(posedge clk) begin
    if (!rst && rep_release)
      wstate[rep_slot] <= WS_EMPTY;
  end

  assign wf_completion_valid         = rep_pending;
  assign wf_completion_slot          = rep_slot;
  assign wf_completion_fault         = rep_fault;
  assign wf_completion_fault_code    = rep_fc;
  assign wf_completion_pc            = rep_cpc;
  assign wf_completion_retired_count = rep_ret;

  // ==================== traces ==============================================
  logic        s_tvalid; logic [PW-1:0] s_twfid;
  logic [63:0] s_tpc, s_tinsn, s_tnx;
  logic        s_twe; logic [7:0] s_ta; logic [31:0] s_td;
  always_ff @(posedge clk) begin
    if (rst) s_tvalid <= 1'b0;
    else begin
      s_tvalid <= sc_fire;
      s_twfid  <= gid;
      s_tpc    <= g_pc;
      s_tinsn  <= ibuf_i[gid];
      s_tnx    <= sc_next_pc_final;
      s_twe    <= sc_wen;
      s_ta     <= (g_cls==CLS_GETID) ? getid_dst_g : g_dst;
      s_td     <= salu_y;
    end
  end
  assign trace_s_valid     = s_tvalid;
  assign trace_s_wfid      = s_twfid;
  assign trace_s_pc        = s_tpc;
  assign trace_s_insn      = s_tinsn;
  assign trace_s_next_pc   = s_tnx;
  assign trace_s_sgpr_we   = s_twe;
  assign trace_s_sgpr_addr = s_ta;
  assign trace_s_sgpr_wdata= s_td;
  assign trace_s_fault     = 1'b0;
  assign trace_s_fcode     = '0;

  logic        v_tvalid; logic [PW-1:0] v_twfid;
  logic [63:0] v_tpc, v_tinsn;
  logic [31:0] v_teff; logic [3:0] v_tpred;
  always_ff @(posedge clk) begin
    if (rst) v_tvalid <= 1'b0;
    else if (vec_setup_accept) begin
      v_tvalid <= 1'b0;
      v_twfid  <= gid;
      v_tpc    <= g_pc;
      v_tinsn  <= ibuf_i[gid];
      v_teff   <= g_eff;
      v_tpred  <= g_pred;
    end else if (ve_last_commit)
      v_tvalid <= 1'b1;
  end
  assign trace_v_valid     = v_tvalid && ve_last_commit;
  assign trace_v_wfid      = v_twfid;
  assign trace_v_pc        = v_tpc;
  assign trace_v_insn      = v_tinsn;
  assign trace_v_next_pc   = v_tpc + 64'd1;
  assign trace_v_exec_mask = exec_q[v_twfid];
  logic [31:0] vwm_replay;
  always_comb begin
    vwm_replay = exec_q[v_twfid];
    if (v_tpred != PRED_NONE[3:0])
      vwm_replay = exec_q[v_twfid] & p_rep_data;
  end
  assign trace_v_effective_mask = vwm_replay;
  assign trace_v_pred_idx  = v_tpred;
  assign trace_v_we        = 1'b1;
  assign trace_v_addr      = d_vd[v_twfid];
  assign trace_v_write_mask = vwm_replay;

  // ==================== PMCs ================================================
  logic [PW-1:0] prev_issue_wfid;
  logic          prev_issue_seen;
  wire any_resident = |dbg_allocated;
  wire issue_event  = gvv;
  wire sc_issue_ev  = gvv && !issue_is_fault && !g_isvec;
  wire vec_issue_ev = vec_setup_valid && ve_setup_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      PMC_CYCLES<='0; PMC_RESIDENT_CYCLES<='0; PMC_ISSUE_CYCLES<='0;
      PMC_SCALAR_ISSUES<='0; PMC_VECTOR_ISSUES<='0; PMC_NO_ISSUE_CYCLES<='0;
      PMC_FETCH_WAIT_CYCLES<='0; PMC_PIPE_BUSY_CYCLES<='0;
      PMC_WAVEFRONTS_LAUNCHED<='0; PMC_WAVEFRONTS_COMPLETED<='0;
      PMC_WAVEFRONTS_FAULTED<='0; PMC_CONTEXT_SWITCHES<='0;
      prev_issue_wfid<='0; prev_issue_seen<=1'b0;
    end else begin
      PMC_CYCLES <= PMC_CYCLES + 1'b1;
      if (any_resident) PMC_RESIDENT_CYCLES <= PMC_RESIDENT_CYCLES + 1'b1;
      if (do_launch)    PMC_WAVEFRONTS_LAUNCHED <= PMC_WAVEFRONTS_LAUNCHED + 1'b1;
      if (issue_event) begin
        PMC_ISSUE_CYCLES <= PMC_ISSUE_CYCLES + 1'b1;
        if (prev_issue_seen && (gid != prev_issue_wfid))
          PMC_CONTEXT_SWITCHES <= PMC_CONTEXT_SWITCHES + 1'b1;
        prev_issue_wfid <= gid;
        prev_issue_seen <= 1'b1;
        if (sc_issue_ev) PMC_SCALAR_ISSUES <= PMC_SCALAR_ISSUES + 1'b1;
        if (vec_issue_ev) PMC_VECTOR_ISSUES <= PMC_VECTOR_ISSUES + 1'b1;
      end else if (any_resident)
        PMC_NO_ISSUE_CYCLES <= PMC_NO_ISSUE_CYCLES + 1'b1;
      if ((|needs_fetch) && f_pend)
        PMC_FETCH_WAIT_CYCLES <= PMC_FETCH_WAIT_CYCLES + 1'b1;
      if ((|issueable) && ve_busy)
        PMC_PIPE_BUSY_CYCLES <= PMC_PIPE_BUSY_CYCLES + 1'b1;
      if (wf_completion_valid && wf_completion_ready) begin
        if (!wf_completion_fault)
          PMC_WAVEFRONTS_COMPLETED <= PMC_WAVEFRONTS_COMPLETED + 1'b1;
        else
          PMC_WAVEFRONTS_FAULTED <= PMC_WAVEFRONTS_FAULTED + 1'b1;
      end
    end
  end

  // ==================== debug ===============================================
  logic [N-1:0] allocated_c, ready_c;
  always_comb begin
    for (int s = 0; s < N; s++) begin
      allocated_c[s] = (wstate[s] != WS_EMPTY);
      ready_c[s] = (wstate[s] == WS_READY);
    end
  end
  assign dbg_allocated = allocated_c;
  assign dbg_issueable = issueable;
  logic [N-1:0] inflight_v;
  always_comb begin
    inflight_v = '0;
    if (ve_busy) inflight_v[ve_own] = 1'b1;
  end
  assign dbg_inflight = inflight_v;
  int unsigned cnt_a,cnt_b,cnt_c;
  always_comb begin
    cnt_a=0;cnt_b=0;cnt_c=0;
    for (int s=0;s<N;s++) begin
      if (allocated_c[s]) cnt_a++;
      if (ready_c[s]) cnt_b++;
      if (issueable[s]) cnt_c++;
    end
  end
  assign dbg_resident_count=32'(cnt_a);
  assign dbg_ready_count=32'(cnt_b);
  assign dbg_issueable_count=32'(cnt_c);
  assign dbg_last_compl_pc = cpc_q[dbg_wf_sel];
  assign dbg_state = dbg_allocated[dbg_wf_sel] ?
      (done_mask_dbg ? scigpu_types_pkg::ST_COMPLETE :
       scigpu_types_pkg::ST_IDLE) : scigpu_types_pkg::ST_IDLE;
  logic done_mask_dbg;
  always_comb done_mask_dbg = (wstate[dbg_wf_sel]==WS_DONE);

endmodule
