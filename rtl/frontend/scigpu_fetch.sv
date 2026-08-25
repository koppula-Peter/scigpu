// SciGPU M2 — instruction-fetch handshake engine (MICRO-001 §1.5, §1.8)
// Decoupled if_* interface: one outstanding request, arbitrary response latency,
// full backpressure in both directions, 1-deep response skid buffer.
// Later replaced by L1-I client without core-side semantic change (ARCH-001 §19).
module scigpu_fetch (
  input  logic        clk,
  input  logic        rst,

  // control side: command to issue one fetch
  input  logic        cmd_valid,          // assert while requesting (until accepted)
  input  logic [63:0] cmd_pc,
  output logic        busy,               // request outstanding / response pending
  output logic        req_accepted,       // request handed to memory this cycle

  // instruction memory side (generic req/rsp, valid-ready)
  output logic        if_req_valid,
  output logic [63:0] if_req_pc,
  input  logic        if_req_ready,

  input  logic        if_rsp_valid,
  input  logic [63:0] if_rsp_insn,
  input  logic        if_rsp_error,
  output logic        if_rsp_ready,       // accept whenever skid slot free

  // control side: latched response
  input  logic        rsp_ready,           // control consuming the buffered response
  output logic        rsp_valid,
  output logic [63:0] rsp_insn,
  output logic        rsp_error
);

  logic        busy_q;
  logic        out_valid_q;
  logic [63:0] out_insn_q;
  logic        out_err_q;

  assign busy         = busy_q || out_valid_q;
  assign if_req_valid = cmd_valid && !busy_q && !out_valid_q;
  assign if_req_pc    = cmd_pc;

  wire req_fire = if_req_valid && if_req_ready;
  assign req_accepted = req_fire;

  // accept a response whenever the skid slot is free
  assign if_rsp_ready = !out_valid_q;
  wire rsp_capture = if_rsp_valid && if_rsp_ready;

  assign rsp_valid   = out_valid_q;
  assign rsp_insn    = out_insn_q;
  assign rsp_error   = out_err_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q     <= 1'b0;
      out_valid_q<= 1'b0;
      out_insn_q <= '0;
      out_err_q  <= 1'b0;
    end else begin
      if (req_fire)
        busy_q <= 1'b1;

      if (rsp_capture) begin
        out_insn_q  <= if_rsp_insn;
        out_err_q   <= if_rsp_error;
        out_valid_q <= 1'b1;
        busy_q      <= 1'b0;              // outstanding request fulfilled
      end

      // control consuming the buffered response
      if (rsp_valid && rsp_ready) begin
        out_valid_q <= 1'b0;
      end
    end
  end

`ifdef SCIGPU_FORMAL
  // M2-ASSERT-001 equivalent: never more than one outstanding request
  assert property (@(posedge clk) disable iff (rst)
    !(req_fire && (busy_q || out_valid_q)));
`endif

endmodule
