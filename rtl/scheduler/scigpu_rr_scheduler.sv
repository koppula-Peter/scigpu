// SciGPU M4 — deterministic round-robin issue scheduler (SCHED-001 §13-15)
// ISA-agnostic: caller supplies issueable[] and consumes grant. One grant max.
// Pointer advances ONLY on accepted issue. Explicit mod-N wrap (non-power-of-two).
module scigpu_rr_scheduler #(
  parameter int unsigned N = 4              // resident slots, >= 1
) (
  input  logic               clk,
  input  logic               rst,
  input  logic [N-1:0]       issueable,     // eligibility mask (generic)
  input  logic               issue_accept,  // grant consumed this cycle
  output logic               grant_valid,
  output logic [$clog2(N)-1:0] grant_id,
  output logic [N-1:0]       grant_onehot,
  output logic [$clog2(N)-1:0] rr_ptr,
  // debug
  output logic [$clog2(N)-1:0] rr_ptr_next
);

  localparam int unsigned PTR_W = (N <= 1) ? 1 : $clog2(N);

  logic [PTR_W-1:0] ptr_q;

  // circular priority scan from ptr_q: first issueable slot
  logic                     scan_found;
  logic [PTR_W-1:0]         scan_id;
  int unsigned sum32;
  int unsigned mod32;
  logic [PTR_W-1:0] idx;

  always_comb begin
    scan_found = 1'b0;
    scan_id    = '0;
    for (int unsigned k = 0; k < N; k++) begin
      // explicit mod-N wrap: all arithmetic in 32-bit, folded to PTR_W below.
      // mod32 upper bits intentionally unused (bounded by construction).
      sum32 = 32'(ptr_q) + 32'(k);
      mod32 = sum32 % 32'(N);
      idx   = PTR_W'(mod32);
      if (mod32 >= 32'(N)) begin
        // unreachable by construction; consume full width for lint symmetry
        idx = PTR_W'(mod32);
      end
      if (!scan_found && issueable[idx]) begin
        scan_found = 1'b1;
        scan_id    = idx;
      end
    end
  end

  assign grant_valid   = scan_found && !rst;   // §82: no grants during reset
  assign grant_id      = scan_id;
  assign rr_ptr        = ptr_q;

  always_comb begin
    grant_onehot             = '0;
    grant_onehot[scan_id]    = scan_found;
    rr_ptr_next = scan_found ? ((32'(scan_id) == 32'(N)-1)
                                  ? PTR_W'(0) : scan_id + 1'b1)
                             : ptr_q;
  end

  always_ff @(posedge clk) begin
    if (rst)
      ptr_q <= '0;                            // defined reset slot 0
    else if (grant_valid && issue_accept)
      ptr_q <= (32'(scan_id) == 32'(N)-1) ? PTR_W'(0) : scan_id + 1'b1;
    // else: pointer unchanged (directive §33)
  end

`ifdef SCIGPU_FORMAL
  // M4-ASSERT-001/002/010/011 equivalents (formal harness proves these too)
  a_onehot0:  assert property (@(posedge clk) disable iff (rst)
                $onehot0(grant_onehot));
  a_eligible: assert property (@(posedge clk) disable iff (rst)
                (grant_onehot & ~issueable) == '0);
  a_range:    assert property (@(posedge clk) disable iff (rst)
                (rr_ptr < N));
`endif

endmodule
