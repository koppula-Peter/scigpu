// SciGPU M4 — per-resident-slot predicate masks P0..P14 (P15 bypass, no storage)
module scigpu_pred_file_m4 #(
  parameter int unsigned N = 4
) (
  input  logic clk, input logic rst,
  input  logic init_we, input logic [$clog2(N)-1:0] init_slot,
  input  logic [3:0] init_addr, input logic [31:0] init_data,
  input  logic [$clog2(N)-1:0] rd_slot, input logic [3:0] rd_addr,
  output logic [31:0] rd_data,
  // issue-stage read channel (granted slot)
  input  logic [$clog2(N)-1:0] iss_slot, input logic [3:0] iss_addr,
  output logic [31:0] iss_data,
  input  logic [$clog2(N)-1:0] dbg_slot, input logic [3:0] dbg_addr,
  output logic [31:0] dbg_data
);
  logic [31:0] mem [N][15];
  integer i;
  always_ff @(posedge clk) begin
    if (rst) for (i=0;i<N;i++) mem[i] <= '{default:'0};
    else if (init_we && init_addr != 4'd15)
      mem[init_slot][init_addr] <= init_data;
  end
  assign rd_data  = (rd_addr == 4'd15) ? 32'hFFFF_FFFF : mem[rd_slot][rd_addr];
  assign iss_data = (iss_addr == 4'd15) ? 32'hFFFF_FFFF : mem[iss_slot][iss_addr];
  assign dbg_data = (dbg_addr == 4'd15) ? 32'hFFFF_FFFF : mem[dbg_slot][dbg_addr];
endmodule
