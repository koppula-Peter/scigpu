// SciGPU M2 unit-test wrapper: exposes ALU / FLAGS / DECODER / SGPR ports
// so the C++ driver can unit-test each block (directive §43-46).
// Simulation-only harness component — NOT part of product RTL.
module scigpu_units_tb (
  input  logic        clk,
  input  logic        rst,

  // ALU
  input  logic [31:0] ua_a, ua_b,
  input  logic [3:0]  ua_op,
  output logic [31:0] ua_y,

  // FLAGS
  input  logic [31:0] uf_a, uf_b, uf_r,
  input  logic [1:0]  uf_kind,
  output logic        uf_z, uf_n, uf_c, uf_v, uf_scc,

  // DECODE
  input  logic [63:0] ud_insn,
  output logic        ud_legal,
  output logic [3:0]  ud_cls,
  output logic [7:0]  ud_dst, ud_src0, ud_src1, ud_gsel, ud_gdst,
  output logic        ud_useimm,
  output logic [31:0] ud_imm,
  output logic signed [23:0] ud_disp,
  output logic [7:0]  ud_cond,

  // SGPR file
  input  logic        ug_init_we,
  input  logic [7:0]  ug_init_addr,
  input  logic [31:0] ug_init_data,
  input  logic [7:0]  ug_ra0, ug_ra1,
  input  logic        ug_we,
  input  logic [7:0]  ug_wa,
  input  logic [31:0] ug_wd,
  output logic [31:0] ug_q0, ug_q1,
  output logic        ug_inv0, ug_inv1
);

  scigpu_scalar_alu u_alu (.a(ua_a), .b(ua_b), .op(ua_op), .y(ua_y));

  scigpu_scalar_flags u_flags (
    .a(uf_a), .b(uf_b), .r(uf_r), .cmp_kind(uf_kind),
    .z(uf_z), .n(uf_n), .c(uf_c), .v(uf_v), .scc(uf_scc));

  scigpu_decode u_dec (
    .insn      (ud_insn),
    .legal     (ud_legal),
    .cls       (scigpu_types_pkg::iclass_e'(ud_cls)),
    .dst       (ud_dst),
    .src0      (ud_src0),
    .src1      (ud_src1),
    .use_imm   (ud_useimm),
    .imm       (ud_imm),
    .disp24    (ud_disp),
    .cond      (ud_cond),
    .getid_sel (ud_gsel),
    .getid_dst (ud_gdst)
  );

  scigpu_sgpr_file #(.SGPR_COUNT(64)) u_sgpr (
    .clk(clk), .rst(rst),
    .init_we(ug_init_we), .init_addr(ug_init_addr), .init_data(ug_init_data),
    .raddr0(ug_ra0), .raddr1(ug_ra1),
    .rdata0(ug_q0), .rdata1(ug_q1),
    .r_invalid0(ug_inv0), .r_invalid1(ug_inv1),
    .we(ug_we), .waddr(ug_wa), .wdata(ug_wd)
  );

endmodule
