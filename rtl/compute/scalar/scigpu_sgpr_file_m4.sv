// SciGPU M4 — per-resident-slot SGPR storage (bootstrap; directive §13-15)
// Isolation by construction: address = {slot, index}. Production shared RF is M6.
module scigpu_sgpr_file_m4 #(
  parameter int unsigned SGPR_COUNT = 64,
  parameter int unsigned N = 4
) (
  input  logic clk, input logic rst,
  // preload
  input  logic init_we, input logic [$clog2(N)-1:0] init_slot,
  input  logic [7:0] init_addr, input logic [31:0] init_data,
  // scalar read channel A (issuing slot: src0/src1)
  input  logic [$clog2(N)-1:0] rd_slot,
  input  logic [7:0] raddr0, raddr1,
  output logic [31:0] rdata0, rdata1,
  // scalar read channel B (V_BCAST capture: slot + SGPR index)
  input  logic [$clog2(N)-1:0] rb_slot,
  input  logic [7:0] rb_addr,
  output logic [31:0] rb_data,
  // scalar commit (owner slot)
  input  logic we, input logic [$clog2(N)-1:0] wslot,
  input  logic [7:0] waddr, input logic [31:0] wdata,
  // debug dump
  input  logic [$clog2(N)-1:0] dbg_slot, input logic [7:0] dbg_addr,
  output logic [31:0] dbg_data
);
  localparam int unsigned IDX_W = $clog2(SGPR_COUNT); // reserved for banking
  logic unused_idxw; always_comb unused_idxw = IDX_W[0] ^ 1'b0;
  logic [31:0] unused_didx_hi; always_comb unused_didx_hi = didx >> 8;
  logic [31:0] unused_r0r1_hi; always_comb unused_r0r1_hi = (r0 >> 8) ^ (r1 >> 8);
  logic unused_r0_hi;   always_comb unused_r0_hi   = ^r0[31:8];
  localparam int unsigned TOT = SGPR_COUNT * N;
  logic [31:0] mem [TOT];
  wire [31:0] iidx = 32'(init_slot)*32'(SGPR_COUNT) + 32'(init_addr);
  wire [31:0] didx = 32'(dbg_slot)*32'(SGPR_COUNT) + 32'(dbg_addr);
  wire [31:0] r0   = 32'(rd_slot)*32'(SGPR_COUNT) + 32'(raddr0);
  wire [31:0] r1   = 32'(rd_slot)*32'(SGPR_COUNT) + 32'(raddr1);
  wire [31:0] rbx  = 32'(rb_slot)*32'(SGPR_COUNT) + 32'(rb_addr);
  logic [31:0] unused_rbx_hi; always_comb unused_rbx_hi = rbx >> 8;
  assign rb_data = mem[rbx];
  wire [31:0] wdx  = 32'(wslot)*32'(SGPR_COUNT) + 32'(waddr);
  assign rdata0 = mem[r0];
  assign rdata1 = mem[r1];
  assign dbg_data = mem[didx];
  integer i;
  always_ff @(posedge clk) begin
    if (rst) for (i=0;i<TOT;i++) mem[i] <= '0;
    else begin
      if (init_we && iidx < TOT) mem[iidx] <= init_data;
      if (we && wdx < TOT)       mem[wdx]  <= wdata;
    end
  end
endmodule
