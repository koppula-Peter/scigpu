// SciGPU M4 — per-resident-slot VGPR storage (bootstrap; directive §22-23).
// Address = {slot, vgpr, lane}. Owner tag guarantees cross-context isolation.
module scigpu_vgpr_file_m4 #(
  parameter int unsigned VGPR_COUNT = 32,
  parameter int unsigned SIMD_LANES = 8,
  parameter int unsigned N = 4
) (
  input  logic clk, input logic rst,
  input  logic init_we, input logic [$clog2(N)-1:0] init_slot,
  input  logic [7:0] init_vgpr, input logic [4:0] init_lane,
  input  logic [31:0] init_data,
  // engine read (owner slot)
  input  logic [$clog2(N)-1:0] rd_slot,
  input  logic [7:0] raddr0, raddr1, input logic [4:0] rlane_base,
  output logic [31:0] rdata0 [SIMD_LANES],
  output logic [31:0] rdata1 [SIMD_LANES],
  // engine writeback (owner slot)
  input  logic we, input logic [$clog2(N)-1:0] wslot,
  input  logic [7:0] waddr, input logic [4:0] wlane_base,
  input  logic [SIMD_LANES-1:0] wmask,
  input  logic [31:0] wdata [SIMD_LANES],
  // debug
  input  logic [$clog2(N)-1:0] dbg_slot, input logic [7:0] dbg_vgpr,
  input  logic [4:0] dbg_lane, output logic [31:0] dbg_data
);
  localparam int unsigned TOT = VGPR_COUNT * 32 * N;

  // slot base = slot * VGPR_COUNT * 32 (computed inline; no helper function)
  logic [31:0] rd_base, w_base, i_base, d_base;
  always_comb begin
    rd_base = 32'(rd_slot)   * 32'(VGPR_COUNT) * 32'd32;
    w_base  = 32'(wslot)     * 32'(VGPR_COUNT) * 32'd32;
    i_base  = 32'(init_slot) * 32'(VGPR_COUNT) * 32'd32;
    d_base  = 32'(dbg_slot)  * 32'(VGPR_COUNT) * 32'd32;
  end

  logic [31:0] mem [TOT];
  always_comb begin
    for (int j = 0; j < SIMD_LANES; j++) begin
      rdata0[j] = mem[rd_base + 32'(raddr0)*32 + 32'(rlane_base) + 32'(j)];
      rdata1[j] = mem[rd_base + 32'(raddr1)*32 + 32'(rlane_base) + 32'(j)];
    end
  end
  wire [31:0] didx = i_base + 32'(init_vgpr)*32 + 32'(init_lane);
  assign dbg_data = mem[d_base + 32'(dbg_vgpr)*32 + 32'(dbg_lane)];
  integer i;
  always_ff @(posedge clk) begin
    if (rst) for (i=0;i<TOT;i++) mem[i] <= '0;
    else begin
      if (init_we && didx < TOT) mem[didx] <= init_data;
      if (we) for (int j = 0; j < SIMD_LANES; j++)
        if (wmask[j])
          mem[w_base + 32'(waddr)*32 + 32'(wlane_base) + 32'(j)] <= wdata[j];
    end
  end
endmodule
