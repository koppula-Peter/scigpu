// SciGPU M6 — production banked VGPR (MICRO-001 Rev0.5 §5.1).
// Drop-in replacement for scigpu_vgpr_file_m4 with bank-decoded reads.
module scigpu_vgpr_banked_m6 #(
  parameter int unsigned SLOTS      = 4,
  parameter int unsigned VGPR_COUNT = 32,
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic clk, input logic rst,
  input  logic        init_we,
  input  logic [$clog2(SLOTS)-1:0] init_slot,
  input  logic [7:0]  init_vgpr,
  input  logic [4:0]  init_lane,
  input  logic [31:0] init_data,
  input  logic [$clog2(SLOTS)-1:0] rd_slot,
  input  logic [7:0]  raddr0, raddr1, raddr2,
  input  logic [4:0]  rlane_base,
  output logic [31:0] rdata0 [SIMD_LANES],
  output logic [31:0] rdata1 [SIMD_LANES],
  output logic [31:0] rdata2 [SIMD_LANES],
  output logic        conflict,
  input  logic        we,
  input  logic [$clog2(SLOTS)-1:0] wslot,
  input  logic [7:0]  waddr,
  input  logic [4:0]  wlane_base,
  input  logic [SIMD_LANES-1:0] wmask,
  input  logic [31:0] wdata [SIMD_LANES],
  input  logic [$clog2(SLOTS)-1:0] dbg_slot,
  input  logic [7:0]  dbg_vgpr,
  input  logic [4:0]  dbg_lane,
  output logic [31:0] dbg_data
);

  localparam int unsigned L = SIMD_LANES;

  logic [31:0] mem [SLOTS][VGPR_COUNT][32];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int si=0;si<int'(SLOTS);si++)
        for (int ri=0;ri<int'(VGPR_COUNT);ri++)
          for (int li=0;li<32;li++) mem[si][ri][li] <= '0;
    end else begin
      if (init_we)
        mem[init_slot][init_vgpr[4:0]][init_lane] <= init_data;
      if (we) begin
        for (int j = 0; j < int'(L); j++) begin
          if (wmask[j])
            mem[wslot][waddr[4:0]][int'(wlane_base)+j] <= wdata[j];
        end
      end
    end
  end

  // bank-decoded combinational reads
  always_comb begin
    for (int j = 0; j < int'(L); j++) begin
      automatic int ln = int'(rlane_base) + j;
      automatic int reg_a = (raddr0[4:1])*2 + int'(raddr0[0]);
      automatic int reg_b = (raddr1[4:1])*2 + int'(raddr1[0]);
      automatic int reg_c = (raddr2[4:1])*2 + int'(raddr2[0]);
      rdata0[j] = mem[rd_slot][reg_a][ln];
      rdata1[j] = mem[rd_slot][reg_b][ln];
      rdata2[j] = mem[rd_slot][reg_c][ln];
    end
  end

  assign conflict = (raddr0[0] == raddr1[0]);

  assign dbg_data = mem[dbg_slot][dbg_vgpr[4:0]][dbg_lane];

endmodule
