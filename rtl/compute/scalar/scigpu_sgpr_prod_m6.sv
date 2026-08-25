// SciGPU M6 — production SGPR file (MICRO-001 Rev0.5 §5.3).
// Slot-interleaved flat storage, 2 combinational reads for the scalar pipe,
// single write, plus a bootstrap preload channel muxed by the caller.
module scigpu_sgpr_prod_m6 #(
  parameter int unsigned SLOTS      = 4,
  parameter int unsigned SGPR_COUNT = 64
) (
  input  logic clk, input logic rst,
  // bootstrap preload
  input  logic        boot_we,
  input  logic [$clog2(SLOTS)-1:0] boot_slot,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [7:0]  boot_addr,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] boot_data,
  // scalar pipe
  input  logic [$clog2(SLOTS)-1:0] rd_slot,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [7:0]  raddr0, raddr1,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] rdata0, rdata1,
  input  logic        we,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [7:0]  waddr,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] wdata,
  // debug peek
  input  logic [$clog2(SLOTS)-1:0] dbg_slot,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [7:0]  dbg_addr,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] dbg_data
);

  logic [31:0] mem [SLOTS][SGPR_COUNT];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int s = 0; s < int'(SLOTS); s++)
        for (int a = 0; a < int'(SGPR_COUNT); a++) mem[s][a] <= '0;
    end else begin
      if (boot_we)                    mem[boot_slot][$clog2(SGPR_COUNT)'(boot_addr)] <= boot_data;
      if (we)                         mem[rd_slot][$clog2(SGPR_COUNT)'(waddr)] <= wdata;
    end
  end

  assign rdata0   = mem[rd_slot][$clog2(SGPR_COUNT)'(raddr0)];
  assign rdata1   = mem[rd_slot][$clog2(SGPR_COUNT)'(raddr1)];
  assign dbg_data = mem[dbg_slot][$clog2(SGPR_COUNT)'(dbg_addr)];

endmodule
