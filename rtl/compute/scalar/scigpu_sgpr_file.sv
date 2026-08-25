// SciGPU M2 — SGPR file (MICRO-001 §1.8; directive §22-23)
// Two combinational read ports, one synchronous commit write port.
// Bootstrap implementation: NOT the production scalar/vector RF (REG-001 owns that).
module scigpu_sgpr_file #(
  parameter int unsigned SGPR_COUNT = 64     // valid range 16..256 (checked below)
) (
  input  logic        clk,
  input  logic        rst,

  // preload / init port (bootstrap only; honored in IDLE by the control FSM)
  input  logic        init_we,
  input  logic [7:0]  init_addr,
  input  logic [31:0] init_data,

  // combinational read ports
  input  logic [7:0]  raddr0,
  input  logic [7:0]  raddr1,
  output logic [31:0] rdata0,
  output logic [31:0] rdata1,
  output logic        r_invalid0,            // index >= SGPR_COUNT (INV-021)
  output logic        r_invalid1,

  // architectural commit write port
  input  logic        we,
  input  logic [7:0]  waddr,
  input  logic [31:0] wdata,

  // debug read (verification convenience; M2 file reused by M3 core)
  input  logic [7:0]  dbg_addr,
  output logic [31:0] dbg_data
);

  generate if (SGPR_COUNT < 16 || SGPR_COUNT > 256) begin : gen_param_check
    $error("SGPR_COUNT must be within 16..256");   // elaboration-time failure
  end endgenerate

  logic [31:0] mem [0:SGPR_COUNT-1];

  // Widened bounds arithmetic: SGPR_COUNT may be 256 which does NOT fit in
  // 8 bits. Compare {1'b0,index} against a 9-bit count (directive §12-13).
  localparam int unsigned IDX_W = $clog2(SGPR_COUNT);
  localparam logic [8:0] CNT9 = SGPR_COUNT[8:0];
  wire [8:0] ext0 = {1'b0, raddr0};
  wire [8:0] ext1 = {1'b0, raddr1};
  wire [8:0] extw = {1'b0, waddr};
  wire [8:0] exti = {1'b0, init_addr};
  wire oob0 = (ext0 >= CNT9);
  wire oob1 = (ext1 >= CNT9);
  wire [IDX_W-1:0] ra0 = oob0 ? '0 : raddr0[IDX_W-1:0];
  wire [IDX_W-1:0] ra1 = oob1 ? '0 : raddr1[IDX_W-1:0];
  assign rdata0     = mem[ra0];
  assign rdata1     = mem[ra1];
  assign r_invalid0 = oob0;
  assign r_invalid1 = oob1;

  wire wr_allowed   = we && (extw < CNT9);       // ASSERT-008 equivalent

  wire        dbg_oob = ({1'b0, dbg_addr} >= CNT9);
  wire [IDX_W-1:0] dbg_idx = dbg_oob ? '0 : dbg_addr[IDX_W-1:0];
  assign dbg_data = mem[dbg_idx];
  logic unused_dbg_oob; always_comb unused_dbg_oob = dbg_oob;

  integer i;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < SGPR_COUNT; i++)
        mem[i] <= 32'd0;
    end else begin
      if (init_we && (exti < CNT9))
        mem[init_addr[IDX_W-1:0]] <= init_data;
      if (wr_allowed)
        mem[waddr[IDX_W-1:0]] <= wdata;
    end
  end

endmodule
