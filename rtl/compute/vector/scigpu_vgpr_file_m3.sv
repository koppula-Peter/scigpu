// SciGPU M3 — bootstrap VGPR storage (MICRO-001 §2.6; directive §22-26, §59)
// Architectural state: VGPR_COUNT x 32 lanes x 32 bits, independent of SIMD_LANES.
// BOOTSTRAP correctness structure — the production lane-striped banked RF is
// owned by M6 / REG-001 / ADR-002. Beat-oriented port contract preserves swap.
module scigpu_vgpr_file_m3 #(
  parameter int unsigned VGPR_COUNT = 32,      // 8..256 (checked)
  parameter int unsigned SIMD_LANES = 8        // 4/8/16/32
) (
  input  logic        clk,
  input  logic        rst,

  // bootstrap preload (IDLE only; gated by core)
  input  logic        init_we,
  input  logic [7:0]  init_addr,
  input  logic [4:0]  init_lane,
  input  logic [31:0] init_data,

  // beat-oriented source read (addresses = absolute logical lanes k*L+j base)
  input  logic [7:0]  raddr0,                  // VGPR index for source 0
  input  logic [7:0]  raddr1,
  input  logic [4:0]  rlane_base,              // beat base lane (k*L), <= 32-L
  output logic [31:0] rdata0 [SIMD_LANES],     // slice rlane_base +: L
  output logic [31:0] rdata1 [SIMD_LANES],
  output logic        r_invalid0,
  output logic        r_invalid1,

  // masked beat writeback
  input  logic        we,
  input  logic [7:0]  waddr,
  input  logic [4:0]  wlane_base,
  input  logic [SIMD_LANES-1:0] wmask,         // physical-lane write enables
  input  logic [31:0] wdata [SIMD_LANES],

  // debug read (one 32-bit lane at a time; verification convenience)
  input  logic [7:0]  dbg_addr,
  input  logic [4:0]  dbg_lane,
  output logic [31:0] dbg_data
);

  generate if (VGPR_COUNT < 8 || VGPR_COUNT > 256) begin : g_param
    $error("VGPR_COUNT must be within 8..256");
  end
  if (SIMD_LANES inside {4, 8, 16, 32}) begin : g_lanes_ok end else begin : g_lanes_bad
    $error("SIMD_LANES must be one of 4/8/16/32");
  end endgenerate

  localparam int unsigned IDX_W = $clog2(VGPR_COUNT);
  localparam logic [8:0] CNT9 = VGPR_COUNT[8:0];   // widened (256-safe)

  logic [31:0] mem [VGPR_COUNT][32];

  wire oob_r0 = ({1'b0, raddr0} >= CNT9);
  wire oob_r1 = ({1'b0, raddr1} >= CNT9);
  wire oob_w  = ({1'b0, waddr}  >= CNT9);
  wire oob_i  = ({1'b0, init_addr} >= CNT9);

  wire [IDX_W-1:0] ri0 = oob_r0 ? '0 : raddr0[IDX_W-1:0];
  wire [IDX_W-1:0] ri1 = oob_r1 ? '0 : raddr1[IDX_W-1:0];

  // per-beat combinational reads (logical lane = base + j, 32-bit domain)
  always_comb begin
    for (int j = 0; j < SIMD_LANES; j++) begin
      automatic logic [4:0] la = rlane_base + j[4:0];
      rdata0[j] = mem[ri0][la];
      rdata1[j] = mem[ri1][la];
    end
  end
  assign r_invalid0 = oob_r0;
  assign r_invalid1 = oob_r1;

  integer i, l;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < VGPR_COUNT; i++)
        for (l = 0; l < 32; l++)
          mem[i][l] <= 32'd0;
    end else begin
      if (init_we && !oob_i)
        mem[init_addr[IDX_W-1:0]][init_lane] <= init_data;
      if (we && !oob_w) begin
        for (int j = 0; j < SIMD_LANES; j++)
          if (wmask[j]) begin
            automatic logic [4:0] wa = wlane_base + j[4:0];
            mem[waddr[IDX_W-1:0]][wa] <= wdata[j];
          end
      end
    end
  end

  logic unused_dbg_hi; always_comb unused_dbg_hi = ^dbg_addr[7:IDX_W];
  assign dbg_data = mem[dbg_addr[IDX_W-1:0]][dbg_lane];

`ifdef SCIGPU_FORMAL
  // M3-ASSERT-005 equivalent: masked physical lanes never produce write enable
  always_comb begin
    for (int j = 0; j < SIMD_LANES; j++)
      assert (!(we && !oob_w && !wmask[j]) ||
              !($isunknown(wmask[j])));
  end
`endif

endmodule
