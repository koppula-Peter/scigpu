// SciGPU M4 scheduler formal harness — shadow-model equivalence style.
// Harness owns a spec-defined shadow pointer; RTL pointer must match every
// cycle after the shadow becomes valid. Plus combinational safety checks.
module rr_sched_formal #(
  parameter int unsigned N = 4
) (
  input  logic clk,
  input  logic rst,
  input  logic [N-1:0] issueable,
  input  logic         accept
);
  localparam int unsigned PW = (N <= 1) ? 1 : $clog2(N);

  logic grant_valid;
  logic [PW-1:0] gid, ptr, pn;
  logic [N-1:0] onehot;

  scigpu_rr_scheduler #(.N(N)) dut (
    .clk(clk), .rst(rst), .issueable(issueable), .issue_accept(accept),
    .grant_valid(grant_valid), .grant_id(gid), .grant_onehot(onehot),
    .rr_ptr(ptr), .rr_ptr_next(pn));

`ifdef FORMAL
  // start in reset so both pointers begin at the defined reset slot
  initial assume (rst == 1'b1);

  // ---- shadow model of SCHED-001 §13-15 ---------------------------------
  logic [PW-1:0] sh_ptr;
  logic          sh_valid;
  logic          sh_grant;
  logic [PW-1:0] sh_gid;

  // circular first-issueable scan from sh_ptr
  always_comb begin
    int unsigned idx32;
    sh_grant = 1'b0; sh_gid = '0;
    for (int unsigned k = 0; k < N; k++) begin
      idx32   = (32'(sh_ptr) + 32'(k)) % 32'(N);
      if (!sh_grant && issueable[idx32[PW-1:0]]) begin
        sh_grant = 1'b1;
        sh_gid   = idx32[PW-1:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sh_ptr   <= '0;
      sh_valid <= 1'b0;
    end else begin
      if (sh_valid || (sh_grant && accept)) sh_valid <= 1'b1;
      if ((sh_valid || (sh_grant && accept)) && sh_grant && accept)
        sh_ptr <= (32'(sh_gid) == 32'(N)-1) ? '0 : sh_gid + 1'b1;
    end
  end

  // ---- obligations ---------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      // after a reset edge, RTL must equal freshly-reset shadow on next cycle
      // (checked below once warmup elapsed)
    end else begin
      a_onehot0  : assert ($onehot0(onehot));                     // §77
      a_eligible : assert ((onehot & ~issueable) == '0);          // §78
      a_range    : assert (ptr < N);                              // §M4-011
      a_prefers  : assert (!(grant_valid && issueable[ptr]) ||
                           (gid == ptr));                          // §13 first-examined
      a_no_repeat_full: assert (
          !($past(accept && grant_valid && (&issueable)) &&
            (&issueable) && accept) || (gid != $past(gid)));       // §81
    end
  end

  logic [3:0] warm;
  always_ff @(posedge clk) begin
    if (rst) warm <= '0; else if (!warm[3]) warm <= warm + 1'b1;
  end

  // pointer equivalence once out of reset (both cleared by the same reset)
  always_comb begin
    if (!rst && warm != '0 && sh_valid)
      a_ptr_eq_shadow: assert (ptr == sh_ptr);
  end

`endif
endmodule
