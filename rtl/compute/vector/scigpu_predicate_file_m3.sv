// SciGPU M3 — predicate file: P0..P14 storage; P15 is bypass (no storage).
module scigpu_predicate_file_m3 (
  input  logic        clk,
  input  logic        rst,
  input  logic        init_valid,       // accepted only in IDLE (core gates)
  input  logic [3:0]  init_addr,
  output logic        init_ready,       // 0 for addr==15 (invalid target)
  input  logic [31:0] init_data,

  input  logic [3:0]  rd_addr,          // may be 15 -> caller treats as bypass
  output logic [31:0] rd_data,

  // debug read (verification convenience)
  input  logic [3:0]  dbg_addr,
  output logic [31:0] dbg_data
);

  logic [31:0] mem [15];

  assign init_ready = (init_addr != 4'd15);
  wire wr = init_valid && init_ready;

  integer i;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < 15; i++) mem[i] <= 32'd0;
    end else if (wr) begin
      mem[init_addr] <= init_data;
    end
  end

  assign rd_data = (rd_addr == 4'd15) ? 32'hFFFF_FFFF : mem[rd_addr];
  assign dbg_data = (dbg_addr == 4'd15) ? 32'hFFFF_FFFF : mem[dbg_addr];

endmodule
