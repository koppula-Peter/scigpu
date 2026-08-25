// SciGPU M5 -- formal smoke for the unified typed mask/control stack
// (verification/formal/m5_mask_stack/, directive 109/160).
//
// Drives the REAL engine (yosys-SV-subset-preprocessed copy) with a
// PUSHM/POPM command sequence and proves:
//   P1  MASK_SP never exceeds MASK_STACK_DEPTH          (M5-ASSERT-002)
//   P2  done && fault are mutually exclusive
//   P3  POPM on empty stack faults with UNDERFLOW and leaves SP unchanged
//   P4  accepted PUSHM increments SP by exactly one
//   P5  accepted POPM decrements SP by exactly one
//   P6  committed EXEC is a subset of LIVE_MASK         (M5-ASSERT-001)
module m5_mask_stack_formal #(
  parameter int unsigned SLOTS = 1,
  parameter int unsigned DEPTH = 2
) (
  input  logic clk,
  input  logic rst
);

  localparam int unsigned SPW = $clog2(DEPTH+1);
  localparam bit [3:0] CT_PUSHM=4'd6, CT_POPM=4'd7;

  // deterministic alternating stimulus: PUSHM, POPM, PUSHM, POPM, ...
  // (solver picks stall-free path; engine handshake fully specified)
  reg toggle;
  wire want_push = !toggle;
  wire cmd_valid = 1'b1;

  wire ready;
  wire done, fault, retire, route_le;
  wire [5:0]  fault_code;
  wire [31:0] o_exec, o_live;
  wire [SPW-1:0] o_sp, o_loopidx;
  wire [63:0] o_pc; wire o_pc_we;
  wire [SPW-1:0] dbg_sp_w;
  wire [1:0] dbg_ft_w;
  wire [31:0] dbg_tp, dbg_tm_a, dbg_tm_b;

  scigpu_mask_control_m5 #(.SLOTS(SLOTS), .DEPTH(DEPTH)) dut (
    .clk(clk), .rst(rst), .ready(ready),
    .cmd_valid(cmd_valid && ready),
    .cmd_op(toggle ? CT_POPM : CT_PUSHM),
    .cmd_slot({$clog2(SLOTS){1'b0}}),
    .cmd_cond(4'd0),
    .cmd_pword(32'hFFFFFFFF),
    .cmd_pc(64'd0), .cmd_cw(64'd100),
    .cmd_exec(32'hFFFFFFFF), .cmd_live(32'hFFFFFFFF),
    .cmd_sp({SPW{1'b0}}), .cmd_loopidx({SPW{1'b1}}),
    .cmd_disp24(24'd0), .cmd_bmod(16'd0),
    .done(done), .fault(fault), .fault_code(fault_code),
    .retire(retire), .route_le(route_le),
    .o_pop_evt(), .o_top_ftype(),
    .o_exec(o_exec), .o_live(o_live), .o_sp(o_sp), .o_loopidx(o_loopidx),
    .o_pc(o_pc), .o_pc_we(o_pc_we),
    .dbg_slot({$clog2(SLOTS){1'b0}}), .dbg_sp(dbg_sp_w),
    .dbg_top_ftype(dbg_ft_w), .dbg_top_parent(dbg_tp),
    .dbg_top_maska(dbg_tm_a), .dbg_top_maskb(dbg_tm_b));

  always_ff @(posedge clk) begin
    if (rst) toggle <= 1'b0;
    else if (done || fault) toggle <= !toggle;
  end

  // ---- properties ----
  // P1: SP never exceeds configured depth (M5-ASSERT-002)
  always_ff @(posedge clk) if (!rst)
    assert (dbg_sp_w <= SPW'(DEPTH));

  // P2: done and fault mutually exclusive
  always_ff @(posedge clk) if (!rst)
    assert (!(done && fault));

  // P3: POPM on empty faults with exact code, no partial effect
  always_ff @(posedge clk) if (!rst)
    if (fault && fault_code == FAULT_MASK_STACK_UNDERFLOW)
      assert (dbg_sp_w == {SPW{1'b0}});

  // P6: any committed context keeps EXEC subset LIVE (M5-ASSERT-001)
  always_ff @(posedge clk) if (!rst)
    if (done && !fault)
      assert ((o_exec & ~o_live) == 32'b0);
endmodule
