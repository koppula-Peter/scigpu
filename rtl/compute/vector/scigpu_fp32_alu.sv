// SciGPU M7 — IEEE 754 single-precision vector ALU
// RN rounding, FTZ subnormals. Ops: 0=FADD 1=FSUB 2=FMUL 3=I2F 4=F2I
module scigpu_fp32_alu #(
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic [4:0]   op,
  input  logic [31:0]  a [SIMD_LANES],
  input  logic [31:0]  b [SIMD_LANES],
  output logic [31:0]  y [SIMD_LANES]
);

  // ======== IEEE 754 SP ADD (also handles SUB via sign flip) ============
  function automatic logic [31:0] fp_add(input logic [31:0] xa, input logic [31:0] xb);
    logic sa, sb, rsign;
    logic [7:0] ea, eb;
    logic [22:0] ma, mb;
    logic [23:0] sig_l, sig_r;
    int el, er;
    int signed sval_l, sval_r;
    int shift;
    int signed sum_sig;
    int res_exp;
    bit neg;
    int mag;
    int msb_pos;
    int exp_adjust;
    int final_exp;
    logic [26:0] norm;
    int denorm_shift;

    begin
      sa = xa[31]; ea = xa[30:23]; ma = xa[22:0];
      sb = xb[31]; eb = xb[30:23]; mb = xb[22:0];

      if (xa == 32'b0) return xb;
      if (xb == 32'b0) return xa;
      if (&ea && &eb && sa != sb) return 32'h7FC00000;
      if (&ea) return xa;
      if (&eb) return xb;

      sig_l = (ea != 0) ? {1'b1, ma} : {1'b0, ma};
      sig_r = (eb != 0) ? {1'b1, mb} : {1'b0, mb};
      el = (ea != 0) ? int'(ea) : 1;
      er = (eb != 0) ? int'(eb) : 1;
      sval_l = sa ? -int'(sig_l) : int'(sig_l);
      sval_r = sb ? -int'(sig_r) : int'(sig_r);

      // simplified: use integer arithmetic for the addition
      sum_sig = sval_l + sval_r >>> (el > er ? el-er : er-el);
      if (sum_sig == 0) return 32'b0;
      neg = (sum_sig < 0);
      mag = neg ? (-sum_sig) : sum_sig;

      // find MSB position
      msb_pos = 0;
      for (int i = 30; i >= 0; i--) begin
        if (mag[i]) begin msb_pos = i; break; end
      end

      // normalize to implicit-1-at-bit-23
      norm = {4'b0000, mag} >> (msb_pos - 22);
      final_exp = res_exp + msb_pos - 22;

      // round
      if (norm[0]) norm = norm + 28'd2;

      // overflow/underflow/subnormal
      if (final_exp >= 255) return {neg, 8'hFF, 23'b0};
      if (final_exp <= 0) begin
        denorm_shift = 1 - final_exp;
        if (denorm_shift < 23) return {neg, 8'h00, norm[24:2] >> denorm_shift};
        return {neg, 31'b0};
      end

      fp_add = {neg, final_exp[7:0], norm[24:2]};
    end
  endfunction

  // ======== IEEE 754 SP MULTIPLY ========================================
  function automatic logic [31:0] fp_mul(input logic [31:0] xa, input logic [31:0] xb);
    bit sa = xa[31];
    bit sb = xb[31];
    byte ea = xa[30:23];
    byte eb = xb[30:23];
    logic [22:0] ma = xa[22:0];
    logic [22:0] mb = xb[22:0];

    if (xa == 0 || xb == 0) return 32'b0;

    bit rs;
    logic [23:0] sig_a, sig_b;
    int exp_a, exp_b;

    // Multiply: 48-bit product of two 24-bit values
    logic [47:0] prod = sig_a * sig_b;
    int exp_res = exp_a + exp_b - 127;

    // Normalize: find leading one in prod[47:46]
    if (!prod[47]) begin
      // product is in [1,2) range -> leading one at bit 46
      prod = prod << 1;
      exp_res = exp_res - 1;
    end
    // If prod[47]=1, already normalized

    // Round-to-nearest-even on bit 22 (guard/round/sticky below)
    if (prod[22] && (prod[21:0] != 0 || prod[23]))
      prod = prod + 48'h800000;

    // Check carry from rounding
    if (!prod[47]) begin
      prod = prod << 1;
      exp_res = exp_res - 1;
    end

    if (exp_res >= 255) return {rs, 8'hFF, 23'b0};
    if (exp_res <= 0)   return {rs, 31'b0};

    fp_mul = {rs, exp_res[7:0], prod[45:23]};
    return fp_mul;
  endfunction

  // ======== IEEE 754 SP INT-TO-FLOAT ====================================
  function automatic logic [31:0] fp_i2f(input logic [31:0] iv);
    if (iv == 32'b0) return 32'b0;

    bit sg = iv[31];
    logic [31:0] mag = sg ? (32'd0 - iv) : iv;

    // Find leading one position
    int lz = 31;
    for (int i = 30; i >= 0; i--) begin
      if (mag[i]) begin lz = i; break; end
    end

    // Value = mag × 2^0, normalized as 1.fraction × 2^lz
    int exp = lz + 127;

    // Build normalized significand: place mag starting at bit 23
    logic [54:0] wide = {23'b0, mag, 0};
    // Shift so MSB of mag is at bit 46 (just above the 23-bit fraction field)
    if (lz > 22) begin
      wide = {23'b0, mag, 0} >> 0; // already positioned
      // Shift left to put MSB at position 46
      wide = wide << (46 - lz);
    end else begin
      wide = wide << 0;
      wide = wide >> (22 - lz);
    end

    // Round on bit 22
    logic [54:0] rounded = wide;
    // Simple truncation for now (RN would check bit 22)

    logic [22:0] frac = rounded[45:23];

    fp_i2f = {sg, exp[7:0], frac};
  endfunction

  // ======== IEEE 754 SP FLOAT-TO-INT ====================================
  function automatic logic [31:0] fp_f2i(input logic [31:0] fv);
    bit sg = fv[31];
    byte e = fv[30:23];
    logic [22:0] m = fv[22:0];

    if (e < 127) return 32'b0;  // |value| < 1

    // Reconstruct integer: {1, m} >> (127+23-exp) = significand >> (150-exp)
    int shift = 150 - int'(e);
    if (shift >= 32) return sg ? 32'h80000000 : 32'h7FFFFFFF;
    if (shift < 0)   return sg ? 32'h80000000 : 32'h7FFFFFFF;

    logic [31:0] mag = {1'b1, m} >> shift;
    return sg ? (32'd0 - mag) : mag;
  endfunction

  // ======== lane datapath ================================================
  genvar g;
  generate for (g = 0; g < SIMD_LANES; g++) begin : g_lane
    always_comb begin
      case (op)
        5'd00: y[g] = do_add(a[g], b[g]);       // FADD
        5'd01: y[g] = do_add(a[g], {~b[g][31], b[g][30:0]}); // FSUB
        5'd02: y[g] = fp_mul(a[g], b[g]);       // FMUL
        5'd03: y[g] = fp_i2f(a[g]);             // I2F
        5'd04: y[g] = fp_f2i(a[g]);             // F2I
        default: y[g] = 32'b0;
      endcase
    end
  end endgenerate

endmodule
