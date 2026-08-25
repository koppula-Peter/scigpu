// SciGPU M5 - multi-resident Compute Unit with SIMT divergence
// (MICRO-001 Rev0.4 s4; EXEC-001 Rev1.1; ADR-011).
//
// Reuses M2-M4 modules verbatim: scigpu_fetch, scigpu_rr_scheduler,
// scigpu_sgpr_file_m4, scigpu_vgpr_file_m4, scigpu_pred_file_m4,
// scigpu_vector_engine (+alu), scigpu_scalar_alu, scigpu_scalar_flags.
// New M5 machinery: scigpu_decode_m5, scigpu_mask_control_m5,
// scigpu_vector_compare_m5.
//
// Issue classes: SCALAR | VECTOR(engine or compare) | CONTROL(mask engine) |
// FAULT. G1 policy: max ONE NEW instruction issued per cycle; one in flight
// per wavefront. Ordinary (non-control) instructions require EXEC!=0;
// control instructions are wavefront-scope operations evaluated by the mask
// engine regardless of EXEC (LOOP_END after unwind routing).
//
// Per-slot architectural additions: LIVE_MASK, typed control stack (in the
// engine, slot-indexed), current_loop_index, unwind-await flag.
module scigpu_m5_cu #(
  parameter int unsigned SGPR_COUNT = 64,
  parameter int unsigned VGPR_COUNT = 32,
  parameter int unsigned SIMD_LANES = 8,
  parameter int unsigned RESIDENT_WAVEFRONTS_PER_CU = 4,
  parameter int unsigned MASK_STACK_DEPTH = 32,
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
    PMC_PREDICATE_WRITES, PMC_DIVERGENT_BRANCHES, PMC_UNIFORM_BRANCHES,
    PMC_RECONV_EVENTS, PMC_MASK_PUSHES, PMC_MASK_POPS,
    PMC_MASK_STACK_MAX_DEPTH, PMC_BREAK_EVENTS, PMC_CONTINUE_EVENTS,
    PMC_EARLY_RETURN_LANES,
  output logic trace_s_valid,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] trace_s_wfid,
  output logic [63:0] trace_s_pc, trace_s_insn, trace_s_next_pc,
  output logic trace_s_sgpr_we, output logic [7:0] trace_s_sgpr_addr,
  output logic [31:0] trace_s_sgpr_wdata,
  output logic [31:0] trace_s_exec, trace_s_live,
  output logic trace_v_valid,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] trace_v_wfid,
  output logic [63:0] trace_v_pc, trace_v_insn, trace_v_next_pc,
  output logic [31:0] trace_v_exec_mask, trace_v_effective_mask,
  output logic [3:0]  trace_v_pred_idx,
  output logic [31:0] trace_v_live,
  output logic        trace_v_pred_we,
  output logic [3:0]  trace_v_pred_addr,
  output logic [31:0] trace_v_pred_wmask, trace_v_pred_value,
  output logic trace_m_valid,
  output logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] trace_m_wfid,
  output logic [3:0]  trace_m_kind,
  output logic [63:0] trace_m_pc,
  output logic [31:0] trace_m_old_exec, trace_m_new_exec,
  output logic [31:0] trace_m_old_live, trace_m_new_live,
  output logic [$clog2(MASK_STACK_DEPTH+1)-1:0] trace_m_sp_before,
  output logic [$clog2(MASK_STACK_DEPTH+1)-1:0] trace_m_sp_after,
  output logic [1:0]  trace_m_ftype,
  output logic        trace_m_push, trace_m_pop,
  output logic [31:0] trace_m_pending,
  output logic [63:0] trace_m_target,
  output logic        trace_m_fault,
  output logic [5:0]  trace_m_fcode,
  output logic [63:0] dbg_last_compl_pc,
  output scigpu_types_pkg::state_e dbg_state,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] dbg_wf_sel,
  input  logic [7:0]  dbg_sgpr_addr, output logic [31:0] dbg_sgpr_data,
  input  logic [3:0]  dbg_pred_addr, output logic [31:0] dbg_pred_data,
  input  logic [7:0]  dbg_vgpr_addr, input logic [4:0] dbg_vgpr_lane,
  output logic [31:0] dbg_vgpr_data,
  output logic [31:0] dbg_exec_data, dbg_live_data,
  input  logic [$clog2(RESIDENT_WAVEFRONTS_PER_CU)-1:0] dbg_mc_slot,
  output logic [31:0] dbg_mc_sp,
  output logic [31:0] dbg_mc_top_parent, dbg_mc_top_maska, dbg_mc_top_maskb
);

  import scigpu_isa_pkg::*;
  import scigpu_types_pkg::*;

  localparam int unsigned N   = RESIDENT_WAVEFRONTS_PER_CU;
  localparam int unsigned PW  = (N <= 1) ? 1 : $clog2(N);
  localparam int unsigned SPW = $clog2(MASK_STACK_DEPTH+1);

  // ctrl_op_e (sync: decode_m5 / mask_control_m5)
  localparam bit [3:0] CT_CBRANCH=4'd0, CT_RECONV=4'd1, CT_LOOPB=4'd2,
                       CT_LOOPE=4'd3, CT_BREAK=4'd4, CT_CONT=4'd5,
                       CT_PUSHM=4'd6, CT_POPM=4'd7, CT_RETW=4'd12;
  localparam bit [1:0] FT_IF=2'd1, FT_LOOP=2'd2, FT_MANUAL=2'd3;
  localparam bit [1:0] PIPE_SCALAR=2'd0, PIPE_VECTOR=2'd1,
                       PIPE_CONTROL=2'd2, PIPE_FAULT=2'd3;

  // =======================================================================
  // per-slot context
  // =======================================================================
  typedef enum logic [2:0] { WS_EMPTY=3'd0, WS_READY=3'd1, WS_DONE=3'd3,
                             WS_FAULTED=3'd4 } ws_e;

  ws_e         wstate [N];
  logic [63:0] pc_q   [N];
  logic [63:0] cw_q   [N];
  logic [31:0] exec_q [N];
  logic [31:0] live_q [N];
  logic        await_q [N];
  logic [N-1:0] ctrl_ifl;             // control op in flight per slot
  localparam bit [SPW-1:0] LI_NONE_C = SPW'(MASK_STACK_DEPTH);
  logic [SPW-1:0] li_q  [N];
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

  logic        ctrl_busy_q;
  logic        mc_pop_evt;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]  mc_top_ft;   // engine exposes top ftype; trace uses static map
  /* verilator lint_on UNUSEDSIGNAL */
  wire launch_ok   = (wstate[wf_launch_slot] == WS_EMPTY);
  assign wf_launch_ready = launch_ok;
  wire do_launch   = wf_launch_valid && launch_ok;

  genvar gv;
  generate for (gv = 0; gv < N; gv++) begin : g_ctx
    always_ff @(posedge clk) begin
      if (rst) begin
        wstate[gv]<=WS_EMPTY; pc_q[gv]<='0; cw_q[gv]<='0; exec_q[gv]<='0;
        live_q[gv]<='0; await_q[gv]<=1'b0; li_q[gv]<=LI_NONE_C;
        wgx_q[gv]<='0; vreq_q[gv]<='0; sreq_q[gv]<='0; ret_q[gv]<='0;
        flg_q[gv]<='0; scc_q[gv]<=1'b0; fc_q[gv]<='0; cpc_q[gv]<='0;
        ibuf_v[gv]<=1'b0; ibuf_i[gv]<='0; ibuf_e[gv]<=1'b0;
      end else if (do_launch && (wf_launch_slot == PW'(gv))) begin
        wstate[gv]<=WS_READY; pc_q[gv]<=wf_entry_pc; cw_q[gv]<=wf_code_words;
        exec_q[gv]<=wf_exec_mask; live_q[gv]<=wf_exec_mask;
        await_q[gv]<=1'b0; li_q[gv]<=LI_NONE_C;
        wgx_q[gv]<=wf_wg_x;
        vreq_q[gv]<=wf_vgpr_req; sreq_q[gv]<=wf_sgpr_req;
        ret_q[gv]<='0; flg_q[gv]<='0; scc_q[gv]<=1'b0;
        fc_q[gv]<='0;
        ibuf_v[gv]<=1'b0; ibuf_e[gv]<=1'b0;
      end
    end
  end endgenerate

`ifdef SCIGPU_M5_DBG
  int unsigned dbg_cyc;
  always_ff @(posedge clk) begin
    if (rst) dbg_cyc <= 0; else dbg_cyc <= dbg_cyc + 1;
    if (!rst && fetch_fire)
      $display("M5DBG %0t FFIRE acc=%b v=%b rdy=%b pc=%0d",
        $time, f_acc, f_cmd, if_req_ready, f_cmd_pc);
    if (!rst && f_rspv)
      $display("M5DBG %0t RSPV own=%0d taken=%b", $time, f_owner, f_rspv && f_rsprdy);
    if (!rst && rsp_take)
      $display("M5DBG %0t RTAKE own=%0d", $time, f_owner);
    if (!rst && do_launch)
      $display("M5DBG %0t LAUNCH sl=%0d entry=%0d cw=%0d ex=%h",
               $time, wf_launch_slot, wf_entry_pc, wf_code_words,
               wf_exec_mask);
    if (!rst && dbg_cyc < 200 && |dbg_allocated) begin
      $display("M5DBG %0t cyc=%0d alloc=%b issbl=%b | s0(pc=%0d st=%0d ib=%b) s1(st=%0d ib=%b pc=%0d) s2(st=%0d ib=%b pc=%0d)",
               $time, dbg_cyc, 8'(dbg_allocated), 4'(issueable),
               pc_q[0], wstate[0], ibuf_v[0],
               wstate[1], ibuf_v[1], pc_q[1],
               wstate[2], ibuf_v[2], pc_q[2],
               f_pend, f_owner, f_busy, f_rspv);
      if (gvv && issue_is_fault)
        $display("M5DBG %0t FGRANT gid=%0d fc=%02x insn=%h vq=%0d",
          $time, gid, issue_fcode, g_insn, g_vq);
      if (gvv && g_isctrl) $display("M5DBG %0t CTRLGRANT disp=%h bmod=%h insn=%h ibuf=%h",
          $time, g_disp_u, g_bmod, g_insn, ibuf_i[gid]);
      if (gvv) $display("M5DBG %0t GRANT gid=%0d ctrl=%b vcmp=%b vec=%b sc=%b op=%0d pdst=%0d cond4=%0d pw=%h pc=%0d",
          $time, gid, g_isctrl, g_isvcmp, g_isvec, sc_fire, g_ctrl_op, g_pdst,
          g_cond4, p_iss_data, g_pc, g_insn[31:0], d_cond4[gid]);
      $display("M5DBG   ex=%h lv=%h issbl=%h", exec_q[0], live_q[0], issueable[0]);
      if (mc_done || mc_fault)
        $display("M5DBG %0t MCDONE d=%b f=%b code=%02x own=%0d oex=%h osp=%0d",
          $time, mc_done, mc_fault, mc_fcode, c_own, mc_oexec, mc_osp);
    end
  end
`endif

  // =======================================================================
  // fetch (shared, tagged) — M4 pattern
  // =======================================================================
  logic          f_pend;
  logic [PW-1:0] f_owner;

  logic [N-1:0] needs_fetch;
  logic [N-1:0] pc_oob;
  always_comb begin
    for (int s = 0; s < N; s++) begin
      automatic bit rdy = (wstate[s]==WS_READY) && !ibuf_v[s]
                          && !ctrl_ifl[s];
      needs_fetch[s] = rdy && !f_pend && !(pc_q[s] >= cw_q[s]);
      pc_oob[s]      = (wstate[s]==WS_READY) && !ibuf_v[s] && !ctrl_ifl[s]
                       && (pc_q[s] >= cw_q[s]);
    end
  end

  logic [PW-1:0] fetch_rr_q;
  logic          fg_found; logic [PW-1:0] fg_id;
  always_comb begin
    fg_found = 1'b0; fg_id = '0;
    for (int unsigned k = 0; k < N; k++) begin
      /* verilator lint_off UNUSEDSIGNAL */
      automatic int unsigned fidx = 32'((32'(fetch_rr_q) + k) % 32'(N));
      /* verilator lint_on UNUSEDSIGNAL */
      automatic logic [PW-1:0] fid = PW'(fidx);
      if (!fg_found && needs_fetch[fid]) begin
        fg_found = 1'b1; fg_id = fid;
      end
    end
  end

  logic f_cmd; logic [63:0] f_cmd_pc;
  /* verilator lint_off UNUSEDSIGNAL */
  logic f_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic f_acc, f_rspv, f_rspe;
  logic [63:0] f_rsp_i; logic f_rsprdy;

  scigpu_fetch u_fetch (
    .clk(clk), .rst(rst),
    .cmd_valid(f_cmd), .cmd_pc(f_cmd_pc), .busy(f_busy),
    .req_accepted(f_acc),
    .if_req_valid(if_req_valid), .if_req_pc(if_req_pc),
    .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_insn(if_rsp_insn),
    .if_rsp_error(if_rsp_error), .if_rsp_ready(if_rsp_ready),
    .rsp_ready(f_rsprdy), .rsp_valid(f_rspv),
    .rsp_insn(f_rsp_i), .rsp_error(f_rspe));

  // Request channel: cmd held until accepted (scigpu_fetch contract:
  // cmd_valid must remain asserted until req_accepted pulses).
  logic        f_cmd_held;
  logic [PW-1:0] f_cmd_id;

  assign f_cmd   = f_cmd_held;
  wire fetch_fire = f_cmd_held && f_acc;   // exactly-once per request
  assign f_rsprdy = 1'b1;
  wire rsp_take   = f_rspv && f_rsprdy;

  always_comb begin
    f_cmd_pc = '0;
    for (int s = 0; s < N; s++)
      if (f_cmd_id == PW'(s)) f_cmd_pc = pc_q[s];
  end

  integer ii;
  always_ff @(posedge clk) begin
    if (rst) begin
      fetch_rr_q <= '0; f_pend <= 1'b0; f_owner <= '0;
      f_cmd_held <= 1'b0; f_cmd_id <= '0;
      for (ii = 0; ii < N; ii++) ibuf_v[ii] <= 1'b0;
    end else begin
      // request channel: latch target when idle, hold until accepted
      if (!f_cmd_held) begin
        if (fg_found) begin
          f_cmd_id   <= fg_id;
          f_cmd_held <= 1'b1;
        end
      end else if (f_acc) begin
        f_cmd_held <= 1'b0;
        f_owner     <= f_cmd_id;
        fetch_rr_q  <= (32'(f_cmd_id)+1 == 32'(N)) ? '0 : f_cmd_id + 1'b1;
      end

      // response channel (independent of request channel)
      if (rsp_take) begin
        ibuf_i[f_owner] <= f_rsp_i;
        ibuf_e[f_owner] <= f_rspe;
        ibuf_v[f_owner] <= 1'b1;
      end

      // outstanding tracking: set on accept, clear on consume;
      // both may coincide (accept N+1 while consuming N)
      f_pend <= (fetch_fire && !rsp_take) ? 1'b1 :
                (!fetch_fire && rsp_take) ? 1'b0 : f_pend;
    end
  end

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

  // =======================================================================
  // per-slot predecode
  // =======================================================================
  logic [N-1:0] d_legal_v, d_isvec_v, d_isctrl_v, d_isvcmp_v;
  iclass_e d_cls [N];
  logic [3:0]  d_ctrl_op[N];
  logic [7:0]  d_dst[N], d_src0[N], d_src1[N];
  logic [7:0]  d_vd[N], d_vs0[N], d_vs1[N], d_vs2[N];
  logic [4:0]  d_va_op[N]; logic [1:0] d_va_bmux[N]; logic [3:0] d_pred[N];
  logic [3:0]  d_pdst[N];
  logic [31:0] d_imm[N]; logic d_useimm[N];
  logic signed [23:0] d_disp[N]; logic [15:0] d_bmod[N];
  logic [3:0]  d_cond4[N];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]  d_cond[N];   // scalar cond table (read from insn bits directly)
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]  d_gsel_w[N], d_gdst_w[N];   // GETID fields read from insn bits
  /* verilator lint_on UNUSEDSIGNAL */
  generate for (genvar gj = 0; gj < N; gj++) begin : g_dec
    scigpu_decode_m5 u_dec (
      .insn(ibuf_i[gj]), .legal(d_legal_v[gj]), .is_vector(d_isvec_v[gj]),
      .is_ctrl(d_isctrl_v[gj]), .is_vcmp(d_isvcmp_v[gj]),
      .ctrl_op(d_ctrl_op[gj]), .cls(d_cls[gj]),
      .va_op(d_va_op[gj]), .va_bmux(d_va_bmux[gj]),
      .dst(d_dst[gj]), .src0(d_src0[gj]), .src1(d_src1[gj]),
      .vd(d_vd[gj]), .vs0(d_vs0[gj]), .vs1(d_vs1[gj]), .vs2(d_vs2[gj]),
      .use_imm(d_useimm[gj]), .imm(d_imm[gj]), .disp24(d_disp[gj]),
      .bmod16(d_bmod[gj]), .cond4(d_cond4[gj]), .cond(d_cond[gj]),
      .getid_sel(d_gsel_w[gj]), .getid_dst(d_gdst_w[gj]),
      .pred(d_pred[gj]), .pdst(d_pdst[gj]));
  end endgenerate

  // =======================================================================
  // issueability + RR grant
  // =======================================================================
  logic ve_setup_ready;             // engine idle
  logic cmp_setup_ready;            // compare unit idle
  logic mc_ready;                   // mask-control engine idle
  logic ve_run;                     // shared vector backend owned
  logic [PW-1:0] ve_own;
  logic        ve_is_cmp;
  wire vc_free = !ve_run;

  logic [N-1:0] issueable;
  always_comb begin
    for (int s = 0; s < N; s++) begin
      automatic bit faultc = ibuf_e[s] || !d_legal_v[s];
      automatic bit execok = (exec_q[s] != 32'b0) || d_isctrl_v[s];
      automatic bit vec_raw = ve_run && (ve_own == PW'(s));
      automatic bit be_ok  = d_isctrl_v[s] ? (mc_ready && !ctrl_busy_q &&
                                              !vec_raw) :
                             d_isvcmp_v[s] ? (vc_free && cmp_setup_ready) :
                             d_isvec_v[s]  ? (vc_free && ve_setup_ready) :
                                             1'b1;
      issueable[s] = (wstate[s]==WS_READY) && ibuf_v[s] &&
                      (faultc || (execok && be_ok));
    end
  end

  logic gvv; logic [PW-1:0] gid, rr_q, rr_n; logic [N-1:0] g1h;
  scigpu_rr_scheduler #(.N(N)) u_rr (
    .clk(clk), .rst(rst), .issueable(issueable),
    .issue_accept(gvv),
    .grant_valid(gvv), .grant_id(gid), .grant_onehot(g1h),
    .rr_ptr(rr_q), .rr_ptr_next(rr_n));

  // granted-slot capture
  logic [7:0]  g_dst, g_src0, g_src1, g_vd, g_vs0, g_vs1, g_vs2;
  logic [31:0] g_imm;
  logic [3:0]  g_pred, g_pdst, g_ctrl_op, g_cond4;
  logic [4:0]  g_va_op;
  logic [15:0] g_bmod;
  logic [1:0]  g_va_bmux;
  logic        g_useimm;
  iclass_e     g_cls;
  logic [63:0] g_pc;
  logic [31:0] g_exec, g_wgx;
  logic [8:0]  g_vq, g_sq;
  logic        g_isvec, g_isctrl, g_isvcmp, g_legal, g_ibuferr;
  logic [23:0] g_disp_u;
  logic [63:0] g_insn;
  always_comb begin
    g_dst='0; g_src0='0; g_src1='0; g_vd='0; g_vs0='0; g_vs1='0;
    g_imm='0; g_pred=4'hF; g_va_op='0; g_pdst='0; g_ctrl_op='0; g_cond4='0; g_vs0='0; g_vs1='0; g_vs2='0;
    g_bmod='0; g_va_bmux='0; g_useimm=1'b0;
    g_cls=CLS_NONE; g_pc='0; g_exec='0; g_wgx='0; g_vq='0; g_sq='0;
    g_isvec=1'b0; g_isctrl=1'b0; g_isvcmp=1'b0; g_legal=1'b0; g_ibuferr=1'b0;
    g_disp_u='0; g_insn='0;
    for (int s = 0; s < N; s++)
      if (g1h[s]) begin
        g_dst=d_dst[s]; g_src0=d_src0[s]; g_src1=d_src1[s];
        g_vd=d_vd[s]; g_vs0=d_vs0[s]; g_vs1=d_vs1[s]; g_vs2=d_vs2[s];
        g_imm=d_imm[s]; g_pred=d_pred[s]; g_va_op=d_va_op[s];
        g_va_bmux=d_va_bmux[s]; g_useimm=d_useimm[s]; g_cls=d_cls[s];
        g_pc=pc_q[s]; g_exec=exec_q[s]; g_wgx=wgx_q[s];
        g_vq=vreq_q[s]; g_sq=sreq_q[s];
        g_isvec=d_isvec_v[s]; g_isctrl=d_isctrl_v[s]; g_isvcmp=d_isvcmp_v[s];
        g_legal=d_legal_v[s]; g_ibuferr=ibuf_e[s];
        g_ctrl_op=d_ctrl_op[s]; g_cond4=d_cond4[s];
        g_bmod=d_bmod[s]; g_pdst=d_pdst[s];
        g_disp_u=24'(unsigned'(d_disp[s]));
        g_insn=ibuf_i[s];
      end
  end

  // validation before any effect
  wire v_u0 = (g_cls==CLS_VEC_ALU)||(g_cls==CLS_VEC_MUL);
  wire v_u1 = v_u0 && (g_va_bmux==2'd0);
  wire v_ud = (g_cls==CLS_VEC_PASS)||(g_cls==CLS_VEC_ALU)||
              (g_cls==CLS_VEC_MUL)||(g_cls==CLS_VEC_LLANE);
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
      (s_ud && (32'(g_dst)  >= {1'b0,g_sq}));
  wire bad_cmp_reg = g_isvcmp &&
      ((32'(g_vs0) >= {1'b0,g_vq}) || (32'(g_vs1) >= {1'b0,g_vq}));
  wire bad_pdst   = g_isvcmp && (g_pdst == 4'd15);

  // unwind routing contract: next instruction must be LOOP_END
  wire await_bad   = await_q[gid] &&
                     !(g_isctrl && (g_ctrl_op == CT_LOOPE));

  wire issue_is_fault = g_ibuferr || !g_legal || bad_vec_reg || bad_sc_reg ||
                        bad_cmp_reg || bad_pdst || await_bad;
  wire [5:0] issue_fcode =
      g_ibuferr ? FAULT_INVALID_ADDRESS :
      !g_legal  ? FAULT_ILLEGAL_OPCODE :
      bad_pdst || bad_cmp_reg || bad_vec_reg || bad_sc_reg
                  ? FAULT_INVALID_REGISTER :
                  FAULT_ILLEGAL_CONTROL_FLOW;   // await_bad

  // predicate issue-read address:
  //   vector ALU -> input pred ; VCMP -> destination read ; CTRL -> cond sel
  logic [31:0] p_iss_data;
  wire [3:0] p_iss_addr = g_isvcmp ? g_pdst :
                          g_isctrl ? g_cond4 : g_pred;

  // issue-time strobes (declared early; driven in routing section below)
  logic vec_setup_valid, cmp_setup_valid, mc_cmd_valid;
  logic [31:0] mc_pword_w;
  logic [PW-1:0] ctrl_owner_next;

  /* verilator lint_off UNUSEDSIGNAL */
  logic        beat_valid_u; logic [4:0] beat_index_u, beat_base_u;
  logic [SIMD_LANES-1:0] beat_mask_u; logic [7:0] beat_vdst_u;
  logic        cmp_busy_u;
  /* verilator lint_on UNUSEDSIGNAL */

  // =======================================================================
  // storage: SGPR / predicate (with runtime-write mux) / VGPR
  // =======================================================================
  logic [7:0]  s_raddr0, s_raddr1;
  logic [31:0] s_rdata0, s_rdata1, s_rb_data;
  logic        s_we; logic [7:0] s_wa; logic [31:0] s_wd;

  scigpu_sgpr_file_m4 #(.SGPR_COUNT(SGPR_COUNT), .N(N)) u_sgpr (
    .clk(clk), .rst(rst),
    .init_we(sgpr_init_valid && sgpr_init_ready),
    .init_slot(sgpr_init_slot), .init_addr(sgpr_init_addr),
    .init_data(sgpr_init_data),
    .rd_slot(gid), .raddr0(s_raddr0), .raddr1(s_raddr1),
    .rdata0(s_rdata0), .rdata1(s_rdata1),
    .rb_slot(gid), .rb_addr(g_vs0), .rb_data(s_rb_data),
    .we(s_we), .wslot(gid), .waddr(s_wa), .wdata(s_wd),
    .dbg_slot(dbg_wf_sel), .dbg_addr(dbg_sgpr_addr),
    .dbg_data(dbg_sgpr_data));
  assign sgpr_init_ready = 1'b1;

  // predicate runtime write (VCMP commit) muxed onto the bootstrap port:
  // bootstrap writes finish before launch; VCMP commits occur only after.
  wire        pred_boot_we = pred_init_valid && pred_init_ready;
  wire        pred_rt_we;
  wire [PW-1:0]  pred_rt_slot_w = ve_own;
  wire [3:0]     pred_rt_addr_w;
  wire [31:0]    pred_rt_data_w;

  logic        cmp_last_commit;
  logic [31:0] cmp_pdata;

  scigpu_pred_file_m4 #(.N(N)) u_pred (
    .clk(clk), .rst(rst),
    .init_we(pred_boot_we || pred_rt_we),
    .init_slot(pred_rt_we ? pred_rt_slot_w : pred_init_slot),
    .init_addr(pred_rt_we ? pred_rt_addr_w : pred_init_addr),
    .init_data(pred_rt_we ? pred_rt_data_w : pred_init_data),
    .rd_slot(ve_own), .rd_addr(ve_tpdst), .rd_data(p_rep_now),
    .iss_slot(gid), .iss_addr(p_iss_addr), .iss_data(p_iss_data),
    .dbg_slot(dbg_wf_sel), .dbg_addr(dbg_pred_addr),
    .dbg_data(dbg_pred_data));
  assign pred_init_ready = 1'b1;

  wire [31:0] g_eff = (g_pred == 4'hF) ? g_exec : (g_exec & p_iss_data);

  // =======================================================================
  // shared vector backend: engine (ALU) + compare slice
  // =======================================================================
  logic [4:0]  ve_setup_op; logic [1:0] ve_setup_bmux;
  logic [7:0]  ve_setup_vd, ve_setup_vs0, ve_setup_vs1;
  logic [31:0] ve_setup_imm, ve_setup_bcast, ve_setup_eff;
  logic [7:0]  ve_setup_vs2;

  logic [7:0]  ve_raddr0, ve_raddr1, ve_raddr2; logic [4:0] ve_rlane_base;
  logic        ve_we; logic [7:0] ve_wa; logic [4:0] ve_wb;
  logic [SIMD_LANES-1:0] ve_wm; logic [31:0] ve_wd [SIMD_LANES];
  logic [31:0] vg_rdata0 [SIMD_LANES]; logic [31:0] vg_rdata1 [SIMD_LANES];
  logic [31:0] vg_rdata2 [SIMD_LANES];
  logic        ve_last_commit;

  logic [7:0] c_raddr0, c_raddr1;
  logic [4:0] c_rbase;
  logic [3:0]  ve_tpdst;
  logic [31:0] p_rep_now;

  wire use_cmp_port = ve_run && ve_is_cmp;

  scigpu_vector_engine #(.SIMD_LANES(SIMD_LANES)) u_eng (
    .clk(clk), .rst(rst),
    .setup_valid(vec_setup_valid), .setup_ready(ve_setup_ready),
    .setup_op(ve_setup_op), .setup_bmux(ve_setup_bmux),
    .setup_vd(ve_setup_vd), .setup_vs0(ve_setup_vs0),
    .setup_vs1(ve_setup_vs1), .setup_vs2(ve_setup_vs2), .setup_imm(ve_setup_imm),
    .setup_bcast_data(ve_setup_bcast),
    .setup_effective_mask(ve_setup_eff),
    .vg_raddr0(ve_raddr0), .vg_raddr1(ve_raddr1), .vg_raddr2(ve_raddr2),
    .vg_rlane_base(ve_rlane_base),
    .vg_rdata0(vg_rdata0), .vg_rdata1(vg_rdata1), .vg_rdata2(vg_rdata2),
    .vg_we(ve_we), .vg_waddr(ve_wa), .vg_wlane_base(ve_wb),
    .vg_wmask(ve_wm), .vg_wdata(ve_wd),
    .beat_valid(beat_valid_u), .beat_index(beat_index_u),
    .beat_base(beat_base_u), .beat_mask(beat_mask_u),
    .beat_vdst(beat_vdst_u),
    .last_commit(ve_last_commit));

  scigpu_vector_compare_m5 #(.SIMD_LANES(SIMD_LANES)) u_cmp (
    .clk(clk), .rst(rst),
    .setup_valid(cmp_setup_valid), .setup_ready(cmp_setup_ready),
    .setup_kind(g_va_op[1:0]), .setup_invert(g_va_op[2]),
    .setup_vs0(g_vs0), .setup_vs1(g_vs1),
    .setup_exec(g_exec), .setup_pold(p_iss_data),
    .vg_raddr0(c_raddr0), .vg_raddr1(c_raddr1), .vg_rlane_base(c_rbase),
    .vg_rdata0(vg_rdata0), .vg_rdata1(vg_rdata1),
    .last_commit(cmp_last_commit), .commit_pdata(cmp_pdata), .busy(cmp_busy_u));

  wire [7:0] vg_ra0 = use_cmp_port ? c_raddr0 : ve_raddr0;
  wire [7:0] vg_ra1 = use_cmp_port ? c_raddr1 : ve_raddr1;
  wire [4:0] vg_rb  = use_cmp_port ? c_rbase  : ve_rlane_base;
  wire [7:0] vg_ra2 = ve_raddr2;

  scigpu_vgpr_file_m4 #(
    .VGPR_COUNT(VGPR_COUNT), .SIMD_LANES(SIMD_LANES), .N(N)
  ) u_vgpr (
    .clk(clk), .rst(rst),
    .init_we(vgpr_init_valid && vgpr_init_ready),
    .init_slot(vgpr_init_slot), .init_vgpr(vgpr_init_addr),
    .init_lane(vgpr_init_lane), .init_data(vgpr_init_data),
    .rd_slot(ve_own), .raddr0(vg_ra0), .raddr1(vg_ra1), .raddr2(vg_ra2),
    .rlane_base(vg_rb),
    .rdata0(vg_rdata0), .rdata1(vg_rdata1), .rdata2(vg_rdata2),
    .we(ve_we), .wslot(ve_own), .waddr(ve_wa), .wlane_base(ve_wb),
    .wmask(ve_wm), .wdata(ve_wd),
    .dbg_slot(dbg_wf_sel), .dbg_vgpr(dbg_vgpr_addr),
    .dbg_lane(dbg_vgpr_lane), .dbg_data(dbg_vgpr_data));
  assign vgpr_init_ready = 1'b1;

  // runtime predicate write channel
  assign pred_rt_we    = cmp_last_commit;
  assign pred_rt_addr_w= ve_tpdst;
  assign pred_rt_data_w= cmp_pdata;

  // =======================================================================
  // mask-control engine
  // =======================================================================
  logic        mc_done, mc_fault, mc_retire, mc_route_le;
  logic [5:0]  mc_fcode;
  logic [31:0] mc_oexec, mc_olive;
  logic [SPW-1:0] mc_osp, mc_oli;
  logic [63:0] mc_opc;
  logic        mc_opcwe;

  scigpu_mask_control_m5 #(
    .SLOTS(N), .DEPTH(MASK_STACK_DEPTH)
  ) u_mc (
    .clk(clk), .rst(rst), .ready(mc_ready),
    .cmd_valid(mc_cmd_valid), .cmd_op(g_ctrl_op),
    .cmd_slot(ctrl_owner_next), .cmd_cond(g_cond4), .cmd_pword(mc_pword_w),
    .cmd_pc(g_pc), .cmd_cw(cw_q[ctrl_owner_next]),
    .cmd_exec(exec_q[ctrl_owner_next]), .cmd_live(live_q[ctrl_owner_next]),
    .cmd_sp('0), .cmd_loopidx(li_q[ctrl_owner_next]),
    .cmd_disp24(g_disp_u), .cmd_bmod(g_bmod),
    .done(mc_done), .fault(mc_fault), .fault_code(mc_fcode),
    .retire(mc_retire), .route_le(mc_route_le),
    .o_pop_evt(mc_pop_evt), .o_top_ftype(mc_top_ft),
    .o_exec(mc_oexec), .o_live(mc_olive), .o_sp(mc_osp), .o_loopidx(mc_oli),
    .o_pc(mc_opc), .o_pc_we(mc_opcwe),
    .dbg_slot(dbg_mc_slot), .dbg_sp(dbg_mc_sp_w),
    .dbg_top_ftype(dbg_mc_ft_w), .dbg_top_parent(dbg_mc_top_parent),
    .dbg_top_maska(dbg_mc_top_maska), .dbg_top_maskb(dbg_mc_top_maskb));
  logic [SPW-1:0] dbg_mc_sp_w;  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]     dbg_mc_ft_w;  /* verilator lint_on UNUSEDSIGNAL */
  assign dbg_mc_sp = { {(32-SPW){1'b0}}, dbg_mc_sp_w };

  // =======================================================================
  // issue-time routing + strobes
  // =======================================================================
  wire grant_ok = gvv && !issue_is_fault;

  always_comb begin
    ctrl_owner_next = '0;
    for (int s = 0; s < N; s++) if (g1h[s]) ctrl_owner_next = PW'(s);
  end

  assign vec_setup_valid = grant_ok && g_isvec && vc_free;
  assign cmp_setup_valid = grant_ok && g_isvcmp && vc_free;
  assign mc_cmd_valid    = grant_ok && g_isctrl;
  assign mc_pword_w      = p_iss_data;   // P[cond]; all-ones when COND==15

  wire vec_accept = vec_setup_valid && ve_setup_ready && vc_free;
  wire cmp_accept = cmp_setup_valid && cmp_setup_ready && vc_free;

  always_comb begin
    ve_setup_op    = g_va_op;
    ve_setup_bmux  = g_va_bmux;
    ve_setup_vd    = g_vd;
    ve_setup_vs0   = g_vs0;
    ve_setup_vs1   = g_vs1;
    ve_setup_vs2   = g_vs2;
    ve_setup_imm   = g_imm;
    ve_setup_bcast = s_rb_data;
    ve_setup_eff   = g_eff;
  end

  // scalar read routing
  always_comb begin
    s_raddr0='0; s_raddr1='0;
    if (grant_ok) begin
      if (!g_isvec && !g_isctrl && !g_isvcmp) begin
        s_raddr0 = g_src0;
        s_raddr1 = g_useimm ? '0 : g_src1;
      end else if (g_isvec) begin
        s_raddr0 = g_vs0;
        s_raddr1 = g_vs1;
        if ((g_cls==CLS_VEC_PASS) && (g_va_bmux==2'd3)) begin
          s_raddr1 = '0;
        end
        if ((g_cls==CLS_VEC_LLANE) ||
            ((g_cls==CLS_VEC_PASS) && (g_va_bmux==2'd1))) begin
          s_raddr0='0; s_raddr1='0;
        end
      end
    end
  end

  // =======================================================================
  // scalar execute (M4 subset minus RET, which is CONTROL-classified now)
  // =======================================================================
  localparam bit [3:0] ALU_PASS_B=4'd0, ALU_ADD=4'd1, ALU_SUB=4'd2,
    ALU_AND=4'd3, ALU_OR=4'd4, ALU_XOR=4'd5, ALU_NOT=4'd6, ALU_SHL=4'd7,
    ALU_SHR=4'd8, ALU_SAR=4'd9, ALU_MUL=4'd10;

  wire [11:0] opc_g = g_insn[63:52];
  logic [3:0] salu_op;
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
  logic [31:0] salu_a, salu_b, salu_y;
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

  // FMT5 COND table for S_BRA_COND (scalar branch condition)
  logic cond_taken;
  always_comb begin
    cond_taken = 1'b0;
    case (g_insn[23:16])
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

  wire sc_fire      = grant_ok && !g_isvec && !g_isctrl && !g_isvcmp;
  wire sc_wen       = sc_fire &&
      ((g_cls==CLS_MOV)||(g_cls==CLS_ALU)||(g_cls==CLS_MUL)||
       (g_cls==CLS_GETID));
  wire sc_flags_w   = sc_fire && (g_cls==CLS_CMP);
  wire sc_is_branch = sc_fire && ((g_cls==CLS_BRA)||(g_cls==CLS_BRA_C));
  wire [63:0] br_tgt = g_pc + 64'd1 + {{40{g_disp_u[23]}}, g_disp_u};
  wire [63:0] sc_next_pc_final =
      sc_is_branch ? (cond_taken ? br_tgt : g_pc + 64'd1) :
                     g_pc + 64'd1;

  assign s_we = sc_fire && sc_wen;
  assign s_wa = (g_cls==CLS_GETID) ? g_insn[15:8] : g_dst;
  assign s_wd = salu_y;

  // =======================================================================
  // architectural commits
  // =======================================================================
  // control-op owner snapshot (single control op in flight)
  logic [PW-1:0] c_own;
  logic [63:0]   c_pc;
  logic [31:0]   c_oex, c_olv, c_pend;
  logic [3:0]    c_kind;
  logic [63:0]   c_tgt;
  logic [SPW-1:0] c_spb;
  logic [1:0]    c_ft;
  integer ic;

  always_ff @(posedge clk) begin
    if (rst) begin
      sched_issue_valid <= 1'b0;
      for (ic = 0; ic < N; ic++) begin
        ctrl_ifl[ic] <= 1'b0;
        await_q[ic]  <= 1'b0;
      end
      ctrl_busy_q       <= 1'b0;
      ve_run            <= 1'b0;
      ve_own            <= '0;
      ve_is_cmp         <= 1'b0;
      ve_tpdst          <= '0;
      p_rep_now_r       <= '0;
      p_cmp_value_r     <= '0;
      was_cmp_q         <= 1'b0;
      ve_lc_d           <= 1'b0;
      cmp_lc_d          <= 1'b0;
      c_own             <= '0;
      c_pc              <= '0;
      c_oex <= '0; c_olv <= '0; c_pend <= '0; c_kind <= '0;
      c_tgt <= '0; c_spb <= '0; c_ft <= '0;
      for (ic = 0; ic < N; ic++) sp_shadow[ic] <= '0;
    end else begin
      // ---- grant-side common actions ----
      if (gvv) begin
        sched_issue_valid <= 1'b1;
        sched_issue_wfid  <= gid;
        sched_issue_pc    <= g_pc;
        sched_issue_insn  <= g_insn;
        sched_issue_pipe  <= issue_is_fault ? PIPE_FAULT :
                             g_isctrl      ? PIPE_CONTROL :
                             (g_isvec||g_isvcmp) ? PIPE_VECTOR : PIPE_SCALAR;
      end else begin
        sched_issue_valid <= 1'b0;
      end

      // ---- decode/operand faults: immediate ----
      if (gvv && issue_is_fault) begin
        wstate[gid] <= WS_FAULTED;
        fc_q[gid]   <= issue_fcode;
        cpc_q[gid]  <= g_pc;
      end

      // ---- control-engine busy window ----
      if (mc_cmd_valid && mc_ready && !ctrl_busy_q)
        ctrl_busy_q <= 1'b1;
      else if ((mc_done || mc_fault) && ctrl_busy_q)
        ctrl_busy_q <= 1'b0;

      // ---- await flag consumed by clean LOOP_END issue ----
      if (grant_ok && await_q[gid] && g_isctrl && (g_ctrl_op == CT_LOOPE))
        await_q[gid] <= 1'b0;

      // ---- scalar commit ----
      if (sc_fire) begin
        pc_q[gid]   <= sc_next_pc_final;
        ret_q[gid]  <= ret_q[gid] + 64'd1;
        ibuf_v[gid] <= 1'b0;               // consumed at commit
        if (sc_flags_w) begin
          flg_q[gid] <= {fv,fc_,fn,fz};
          scc_q[gid] <= fscc;
        end
      end

      // ---- vector backend ownership + retire ----
      if (vec_accept || cmp_accept) begin
        ve_run    <= 1'b1;
        ve_own    <= gid;
        ve_is_cmp <= cmp_accept;
        ve_tpdst  <= g_pdst;
      end else if (ve_last_commit || cmp_last_commit)
        ve_run <= 1'b0;

      if (ve_last_commit) begin
        pc_q[ve_own]  <= pc_q[ve_own] + 64'd1;
        ret_q[ve_own] <= ret_q[ve_own] + 64'd1;
        ibuf_v[ve_own]<= 1'b0;
      end
      if (cmp_last_commit) begin
        pc_q[ve_own]  <= pc_q[ve_own] + 64'd1;
        ret_q[ve_own] <= ret_q[ve_own] + 64'd1;
        ibuf_v[ve_own]<= 1'b0;
      end

      // ---- control engine completion ----
      if (mc_cmd_valid) begin
        ctrl_ifl[gid] <= 1'b1;
        c_own <= gid; c_pc <= g_pc;
        c_oex <= exec_q[gid]; c_olv <= live_q[gid];
        c_kind<= g_ctrl_op;
        c_pend<= (g_ctrl_op==CT_CBRANCH) ? (exec_q[gid] & ~p_iss_data) : 32'b0;
        c_tgt <= g_pc + 64'd1 + {{40{g_disp_u[23]}}, g_disp_u};
        c_spb <= sp_shadow[gid];
        // frame-type trace convention (= golden model): structural pushes log
        // their frame type; RECONV/LOOPE/POPM log the frame they act on;
        // BREAK/CONTINUE log their target LOOP; all others 0.
        c_ft  <= (g_ctrl_op==CT_CBRANCH) ? FT_IF :
                 (g_ctrl_op==CT_RECONV)  ? FT_IF :
                 (g_ctrl_op==CT_LOOPB)   ? FT_LOOP :
                 (g_ctrl_op==CT_LOOPE)   ? FT_LOOP :
                 (g_ctrl_op==CT_BREAK)   ? FT_LOOP :
                 (g_ctrl_op==CT_CONT)    ? FT_LOOP :
                 (g_ctrl_op==CT_PUSHM ||
                  g_ctrl_op==CT_POPM)    ? FT_MANUAL : 2'b00;
      end
      if (mc_done || mc_fault) begin
        ctrl_ifl[c_own] <= 1'b0;
      end
      if (mc_done) begin
        ibuf_v[c_own] <= 1'b0;           // consumed at engine completion
        exec_q[c_own] <= mc_oexec;
        live_q[c_own] <= mc_olive;
        li_q [c_own]  <= mc_oli;
        ret_q[c_own]  <= ret_q[c_own] + 64'd1;
        sp_shadow[c_own] <= mc_osp;
        if (mc_opcwe) pc_q[c_own] <= mc_opc;
        if (mc_route_le) await_q[c_own] <= 1'b1;
        if (mc_retire) begin
          wstate[c_own] <= WS_DONE;
          fc_q[c_own]   <= '0;
          cpc_q[c_own]  <= c_pc;
        end
      end
      if (mc_fault) begin
        ibuf_v[c_own] <= 1'b0;
        wstate[c_own] <= WS_FAULTED;
        fc_q[c_own]   <= mc_fcode;
        cpc_q[c_own]  <= c_pc;
      end
    end
  end

  // per-slot SP shadow (updated from engine results; sampled for PMC max)
  logic [SPW-1:0] sp_shadow [N];

  // =======================================================================
  // completion reporter
  // =======================================================================
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
  always_ff @(posedge clk) begin
    if (!rst && rep_release) wstate[rep_slot] <= WS_EMPTY;
  end
  assign wf_completion_valid         = rep_pending;
  assign wf_completion_slot          = rep_slot;
  assign wf_completion_fault         = rep_fault;
  assign wf_completion_fault_code    = rep_fc;
  assign wf_completion_pc            = rep_cpc;
  assign wf_completion_retired_count = rep_ret;

  // =======================================================================
  // traces
  // =======================================================================
  logic        s_tvalid; logic [PW-1:0] s_twfid;
  logic [63:0] s_tpc, s_tinsn, s_tnx;
  logic        s_twe; logic [7:0] s_ta; logic [31:0] s_td;
  logic [31:0] s_tex, s_tlv;
  always_ff @(posedge clk) begin
    if (rst) begin
      s_tvalid<=1'b0; s_twfid<='0; s_tpc<='0; s_tinsn<='0; s_tnx<='0;
      s_twe<=1'b0; s_ta<='0; s_td<='0; s_tex<='0; s_tlv<='0;
    end else begin
      s_tvalid <= sc_fire;
      s_twfid  <= gid;  s_tpc <= g_pc;  s_tinsn <= g_insn;
      s_tnx    <= sc_next_pc_final;
      s_twe    <= sc_wen;
      s_ta     <= (g_cls==CLS_GETID) ? g_insn[15:8] : g_dst;
      s_td     <= salu_y;
      s_tex    <= g_exec;   // scalar ops never alter masks
      s_tlv    <= live_q[gid];
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
  assign trace_s_exec      = s_tex;
  assign trace_s_live      = s_tlv;

  // vector events: ALU commit and VCMP predicate commit
  logic [PW-1:0] v_twfid;
  logic [63:0] v_tpc, v_tinsn;
  logic [3:0]  v_tpred;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] v_teff, p_rep_now_r;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        was_cmp_q;
  wire ve_lc_now  = ve_last_commit && !ve_is_cmp && ve_run;
  wire cmp_lc_now = cmp_last_commit;
  logic ve_lc_d, cmp_lc_d;
  always_ff @(posedge clk) begin
    if (rst) begin
      v_twfid<='0; v_tpc<='0; v_tinsn<='0; v_tpred<='0; v_teff<='0;
      p_rep_now_r<='0; was_cmp_q<=1'b0; ve_lc_d<=1'b0; cmp_lc_d<=1'b0;
    end else begin
      ve_lc_d  <= ve_lc_now;
      cmp_lc_d <= cmp_lc_now;
      if (vec_accept || cmp_accept) begin
        v_twfid <= gid; v_tpc <= g_pc; v_tinsn <= g_insn;
        v_tpred <= g_isvcmp ? g_pdst : g_pred;
        p_rep_now_r <= p_rep_now;
        was_cmp_q   <= cmp_accept;
      end
    end
  end
  logic [31:0] vwm_replay;
  always_comb begin
    if (was_cmp_q)      vwm_replay = exec_q[v_twfid];
    else if (v_tpred != 4'hF)
      vwm_replay = exec_q[v_twfid] & p_rep_now_r;
    else                vwm_replay = exec_q[v_twfid];
  end
  assign trace_v_valid     = ve_lc_d || cmp_lc_d;
  assign trace_v_wfid      = v_twfid;
  assign trace_v_pc        = v_tpc;
  assign trace_v_insn      = v_tinsn;
  assign trace_v_next_pc   = v_tpc + 64'd1;
  assign trace_v_exec_mask = exec_q[v_twfid];
  assign trace_v_effective_mask = vwm_replay;
  assign trace_v_pred_idx  = v_tpred;
  assign trace_v_live      = live_q[v_twfid];
  assign trace_v_pred_we   = cmp_lc_d;
  assign trace_v_pred_addr = v_tpred;
  assign trace_v_pred_wmask= exec_q[v_twfid];
  assign trace_v_pred_value= p_cmp_value_r;

  logic [31:0] p_cmp_value_r;
  always_ff @(posedge clk) begin
    if (rst) p_cmp_value_r <= '0;
    else if (cmp_last_commit) p_cmp_value_r <= cmp_pdata;
  end

  // mask-control trace
  logic        m_tvalid;
  logic [PW-1:0] m_twfid; logic [3:0] m_tkind;
  logic [63:0] m_tpc, m_ttarget;
  logic [31:0] m_toex, m_tnex, m_tolv, m_tnlv, m_tpend;
  logic [SPW-1:0] m_tspb, m_tspa;
  logic [1:0]  m_tft;
  logic        m_tpush, m_tpop, m_tfault;
  logic [5:0]  m_tfcode;
  wire mc_event = mc_done || mc_fault;
  always_ff @(posedge clk) begin
    if (rst) begin
      m_tvalid<=1'b0; m_twfid<='0; m_tkind<='0; m_tpc<='0; m_ttarget<='0;
      m_toex<='0; m_tnex<='0; m_tolv<='0; m_tnlv<='0; m_tpend<='0;
      m_tspb<='0; m_tspa<='0; m_tft<='0; m_tpush<=1'b0; m_tpop<=1'b0;
      m_tfault<=1'b0; m_tfcode<='0;
    end else begin
      m_tvalid <= mc_event;
      m_twfid  <= c_own;     m_tkind <= c_kind;
      m_tpc    <= c_pc;      m_ttarget <= c_tgt;
      m_toex   <= c_oex;     m_tolv <= c_olv;
      m_tpend  <= c_pend;    m_tspb <= c_spb;  m_tft <= c_ft;
      m_tnex   <= mc_oexec;  m_tnlv <= mc_olive;
      m_tspa   <= mc_osp;
      m_tpush  <= mc_done &&
                  ((c_kind==CT_CBRANCH)||(c_kind==CT_LOOPB)||
                   (c_kind==CT_PUSHM));
      m_tpop   <= mc_done && !mc_route_le && mc_pop_evt;
      m_tfault <= mc_fault;
      m_tfcode <= mc_fcode;
    end
  end
  assign trace_m_valid     = m_tvalid;
  assign trace_m_wfid      = m_twfid;
  assign trace_m_kind      = m_tkind;
  assign trace_m_pc        = m_tpc;
  assign trace_m_old_exec  = m_toex;
  assign trace_m_new_exec  = m_tnex;
  assign trace_m_old_live  = m_tolv;
  assign trace_m_new_live  = m_tnlv;
  assign trace_m_sp_before = m_tspb;
  assign trace_m_sp_after  = m_tspa;
  assign trace_m_ftype     = m_tft;
  assign trace_m_push      = m_tpush;
  assign trace_m_pop       = m_tpop;
  assign trace_m_pending   = m_tpend;
  assign trace_m_target    = m_ttarget;
  assign trace_m_fault     = m_tfault;
  assign trace_m_fcode     = m_tfcode;

  // =======================================================================
  // PMCs (M4 set + M5 divergence set; debug counters — directive 91/171)
  // =======================================================================
  logic [PW-1:0] prev_issue_wfid;
  logic          prev_issue_seen;
  logic [SPW-1:0] sp_max_q;
  wire any_resident = |dbg_allocated;
  wire cbr_grant = grant_ok && g_isctrl && (g_ctrl_op == CT_CBRANCH);
  wire cbr_div   = cbr_grant &&
                   (((g_exec & p_iss_data) != 32'b0) &&
                    ((g_exec & ~p_iss_data) != 32'b0));

  always_ff @(posedge clk) begin
    if (rst) begin
      PMC_CYCLES<='0; PMC_RESIDENT_CYCLES<='0; PMC_ISSUE_CYCLES<='0;
      PMC_SCALAR_ISSUES<='0; PMC_VECTOR_ISSUES<='0; PMC_NO_ISSUE_CYCLES<='0;
      PMC_FETCH_WAIT_CYCLES<='0; PMC_PIPE_BUSY_CYCLES<='0;
      PMC_WAVEFRONTS_LAUNCHED<='0; PMC_WAVEFRONTS_COMPLETED<='0;
      PMC_WAVEFRONTS_FAULTED<='0; PMC_CONTEXT_SWITCHES<='0;
      PMC_PREDICATE_WRITES<='0; PMC_DIVERGENT_BRANCHES<='0;
      PMC_UNIFORM_BRANCHES<='0; PMC_RECONV_EVENTS<='0;
      PMC_MASK_PUSHES<='0; PMC_MASK_POPS<='0;
      PMC_MASK_STACK_MAX_DEPTH<='0; PMC_BREAK_EVENTS<='0;
      PMC_CONTINUE_EVENTS<='0; PMC_EARLY_RETURN_LANES<='0;
      prev_issue_wfid<='0; prev_issue_seen<=1'b0; sp_max_q<='0;
    end else begin
      PMC_CYCLES <= PMC_CYCLES + 1'b1;
      if (any_resident) PMC_RESIDENT_CYCLES <= PMC_RESIDENT_CYCLES + 1'b1;
      if (do_launch) PMC_WAVEFRONTS_LAUNCHED <= PMC_WAVEFRONTS_LAUNCHED+1'b1;
      if (gvv) begin
        PMC_ISSUE_CYCLES <= PMC_ISSUE_CYCLES + 1'b1;
        if (prev_issue_seen && (gid != prev_issue_wfid))
          PMC_CONTEXT_SWITCHES <= PMC_CONTEXT_SWITCHES + 1'b1;
        prev_issue_wfid <= gid;
        prev_issue_seen <= 1'b1;
      end else if (any_resident)
        PMC_NO_ISSUE_CYCLES <= PMC_NO_ISSUE_CYCLES + 1'b1;
      if (sc_fire)          PMC_SCALAR_ISSUES <= PMC_SCALAR_ISSUES + 1'b1;
      if (vec_accept||cmp_accept)
                            PMC_VECTOR_ISSUES <= PMC_VECTOR_ISSUES + 1'b1;
      if ((|needs_fetch) && f_pend)
                            PMC_FETCH_WAIT_CYCLES<=PMC_FETCH_WAIT_CYCLES+1'b1;
      if ((|issueable) && ve_run)
                            PMC_PIPE_BUSY_CYCLES<=PMC_PIPE_BUSY_CYCLES+1'b1;
      if (rep_release) begin
        if (!wf_completion_fault)
          PMC_WAVEFRONTS_COMPLETED <= PMC_WAVEFRONTS_COMPLETED + 1'b1;
        else
          PMC_WAVEFRONTS_FAULTED <= PMC_WAVEFRONTS_FAULTED + 1'b1;
      end
      // ---- M5 divergence counters ----
      if (cmp_last_commit)
        PMC_PREDICATE_WRITES <= PMC_PREDICATE_WRITES + 1'b1;
      if (cbr_div)
        PMC_DIVERGENT_BRANCHES <= PMC_DIVERGENT_BRANCHES + 1'b1;
      else if (cbr_grant)
        PMC_UNIFORM_BRANCHES <= PMC_UNIFORM_BRANCHES + 1'b1;
      if (mc_done && !mc_route_le && (c_kind==CT_RECONV))
        PMC_RECONV_EVENTS <= PMC_RECONV_EVENTS + 1'b1;
      if (mc_done && !mc_route_le &&
          ((c_kind==CT_CBRANCH)||(c_kind==CT_LOOPB)||(c_kind==CT_PUSHM)))
        PMC_MASK_PUSHES <= PMC_MASK_PUSHES + 1'b1;
      if (mc_done && !mc_route_le &&
          ((c_kind==CT_LOOPE)||(c_kind==CT_POPM)||(c_kind==CT_RECONV)))
        PMC_MASK_POPS <= PMC_MASK_POPS + 1'b1;
      if (mc_done && (c_kind==CT_BREAK))
        PMC_BREAK_EVENTS <= PMC_BREAK_EVENTS + 1'b1;
      if (mc_done && (c_kind==CT_CONT))
        PMC_CONTINUE_EVENTS <= PMC_CONTINUE_EVENTS + 1'b1;
      if (mc_cmd_valid && (g_ctrl_op==CT_RETW))
        PMC_EARLY_RETURN_LANES <= PMC_EARLY_RETURN_LANES +
                                  PMC_WIDTH'($countones(g_exec));
      for (int s2 = 0; s2 < N; s2++)
        if (sp_shadow[s2] > sp_max_q) sp_max_q <= sp_shadow[s2];
      PMC_MASK_STACK_MAX_DEPTH <= {{(PMC_WIDTH-SPW){1'b0}}, sp_max_q};
    end
  end

  // =======================================================================
  // debug
  // =======================================================================
  logic [N-1:0] allocated_c, ready_c;
  always_comb begin
    for (int s = 0; s < N; s++) begin
      allocated_c[s] = (wstate[s] != WS_EMPTY);
      ready_c[s]     = (wstate[s] == WS_READY);
    end
  end
  assign dbg_allocated = allocated_c;
  assign dbg_issueable = issueable;
  assign dbg_rr_ptr    = rr_q;
  assign sched_rr_before = rr_q;
  assign sched_rr_after  = rr_n;
  logic [N-1:0] inflight_v;
  always_comb begin
    inflight_v = '0;
    if (ve_run) inflight_v[ve_own] = 1'b1;
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
  assign dbg_resident_count  = 32'(cnt_a);
  assign dbg_ready_count     = 32'(cnt_b);
  assign dbg_issueable_count = 32'(cnt_c);
  assign dbg_last_compl_pc   = cpc_q[dbg_wf_sel];
  always_comb dbg_state = !dbg_allocated[dbg_wf_sel] ? ST_IDLE :
      (wstate[dbg_wf_sel]==WS_DONE) ? ST_COMPLETE : ST_IDLE;
  assign dbg_exec_data = exec_q[dbg_wf_sel];
  assign dbg_live_data = live_q[dbg_wf_sel];

endmodule
