// SciGPU M4 — scheduler unit-test wrapper for Verilator (directive §134).
// Fixed 8-slot maximum; unused slots tie issueable=0.
module scigpu_sched_unit_tb #(
  parameter int unsigned N = 4
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [7:0]  issueable,          // only [N-1:0] meaningful
  input  logic        accept,
  output logic        grant_valid,
  output logic [$clog2(N)-1:0] grant_id,
  output logic                 gid_w_unused,
  output logic [7:0]  grant_onehot8,
  output logic [$clog2(N)-1:0] rr_ptr
);
  logic [N-1:0] oh;
  logic [PW-1:0] gid_w;

  scigpu_rr_scheduler #(.N(N)) dut (
    .clk(clk), .rst(rst),
    .issueable(issueable[N-1:0]), .issue_accept(accept),
    .grant_valid(grant_valid), .grant_id(gid_w),
    .grant_onehot(oh), .rr_ptr(rr_ptr), .rr_ptr_next());

  localparam int unsigned PW = (N <= 1) ? 1 : $clog2(N);
  wire [PW-1:0] unused_gid = gid_w;
  logic unused_gid_w; always_comb unused_gid_w = ^gid_w;

  always_comb begin
    grant_onehot8 = '0;
    grant_onehot8[N-1:0] = oh;
    grant_id = gid_w;
  end
endmodule
