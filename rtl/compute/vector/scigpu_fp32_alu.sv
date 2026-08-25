// SciGPU M7 — IEEE 754 single-precision vector ALU
// Ops: 0=FADD 1=FSUB 2=FMUL 3=I2F 4=F2I. RN-even; subnormals supported;
// NaN -> canonical qNaN 0x7FC00000; F2I truncates toward zero with saturation.
module scigpu_fp32_alu #(
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic [4:0]   op,
  input  logic [31:0]  a [SIMD_LANES],
  input  logic [31:0]  b [SIMD_LANES],
  output logic [31:0]  y [SIMD_LANES]
);

  localparam logic [31:0] QNAN = 32'h7FC00000;

  // ======== exact-value round-to-nearest-even ============================
  // value = mag * 2^ep  (mag >= 0)  ->  IEEE SP encoding
  function automatic logic [31:0] fp_round(input bit sg,
                                           input longint unsigned mag,
                                           input int ep);
    int k;
    int e;
    longint unsigned hi, rem, half, one, f;
    begin
      one = 64'd1;
      if (mag == 0) return {sg, 31'b0};
      k = 0;
      for (int i = 63; i >= 0; i--)
        if (k == 0 && ((mag >> i) & one) != 64'd0) k = i;
      e = k + ep + 127;
      if (e >= 255) return {sg, 8'hFF, 23'b0};             // overflow -> inf
      if (e >= 1) begin
        // normal: build 24-bit significand at bits [23:0]
        if (k >= 23) begin
          hi  = mag >> (k - 23);
          rem = mag & ((one << (k - 23)) - one);
          if (k >= 24) begin
            half = one << (k - 24);
            if ((rem > half) || ((rem == half) && ((hi & one) == one)))
              hi = hi + one;
          end
        end else begin
          hi = mag << (23 - k);
        end
        if (hi == (one << 24)) begin                       // rounding carry
          hi = one << 23;
          e  = e + 1;
          if (e >= 255) return {sg, 8'hFF, 23'b0};
        end
        return {sg, e[7:0], hi[22:0]};
      end
      // subnormal / zero:  f = round(mag * 2^(ep+149))
      begin
        int s, n;
        longint unsigned fq;
        s  = ep + 149;
        f  = 0;
        if (s >= 0) begin
          f = mag << s;                        // exact; < 2^23 given e < 1
        end else begin
          n    = -s;
          if (n > 63) begin
            f = 0;                             // value < half of min subnormal
          end else begin
            fq   = mag >> n;
            rem  = mag & ((one << n) - one);
            half = one << (n - 1);
            if ((rem > half) || ((rem == half) && ((fq & one) == one)))
              fq = fq + one;
            f = fq;
          end
        end
        if (f >= (one << 23)) return {sg, 8'd1, 23'b0};    // rounds to min normal
        return {sg, 8'h00, f[22:0]};
      end
    end
  endfunction

  // ======== IEEE 754 SP ADD (SUB via operand sign flip) ==================
  function automatic logic [31:0] fp_add(input logic [31:0] xa, input logic [31:0] xb);
    logic sa, sb, rsign, stk, round_up;
    logic [7:0]  ea, eb, Ea, Eb, E;
    logic [22:0] ma, mb;
    logic [23:0] pa, pb;
    logic [26:0] bigv, smallv, mask;
    logic [27:0] acc;
    int d;
    begin
      sa = xa[31]; ea = xa[30:23]; ma = xa[22:0];
      sb = xb[31]; eb = xb[30:23]; mb = xb[22:0];

      // specials: NaN / infinities / zeros
      if (((&ea) && (|ma)) || ((&eb) && (|mb))) return QNAN;
      if (&ea && &eb && (sa != sb)) return QNAN;           // inf - inf
      if (&ea) return {sa, 8'hFF, 23'b0};
      if (&eb) return {sb, 8'hFF, 23'b0};
      if ((ea == 8'd0) && (ma == 23'd0) && (eb == 8'd0) && (mb == 23'd0))
        return {sa & sb, 31'b0};
      if ((ea == 8'd0) && (ma == 23'd0)) return xb;
      if ((eb == 8'd0) && (mb == 23'd0)) return xa;

      pa = (ea != 8'd0) ? {1'b1, ma} : {1'b0, ma};
      pb = (eb != 8'd0) ? {1'b1, mb} : {1'b0, mb};
      Ea = (ea != 8'd0) ? ea : 8'd1;
      Eb = (eb != 8'd0) ? eb : 8'd1;

      // order operands: big magnitude first
      if ((Ea > Eb) || ((Ea == Eb) && (pa >= pb))) begin
        bigv = {pa, 3'b000}; smallv = {pb, 3'b000};
        E = Ea; rsign = sa; d = int'(Ea) - int'(Eb);
      end else begin
        bigv = {pb, 3'b000}; smallv = {pa, 3'b000};
        E = Eb; rsign = sb; d = int'(Eb) - int'(Ea);
      end

      // align smaller operand into GRS window
      stk = 1'b0;
      if (d > 27) begin
        stk    = (smallv != 27'd0);
        smallv = 27'd0;
      end else if (d > 0) begin
        mask   = (27'd1 << d) - 27'd1;
        stk    = |(smallv & mask);
        smallv = smallv >> d;
      end

      if (sa == sb)
        acc = {1'b0, bigv} + {1'b0, smallv};
      else
        acc = {1'b0, bigv} - {1'b0, smallv};   // big >= small guaranteed

      if (acc == 28'd0) return 32'b0;                      // exact cancel -> +0
                                                           // (addition cannot produce 0:
                                                           //  operands >= min-normal*2^3)
      if (acc[27]) begin                                   // carry out
        stk = stk | acc[0];
        acc = {1'b0, acc[27:1]};
        E   = E + 8'd1;
      end else begin
        // left-normalize (fixed-bound: max 26 shifts)
        for (int i = 0; i < 26; i++)
          if ((acc[26] == 1'b0) && (E > 8'd1)) begin
            acc = {1'b0, acc[25:0], 1'b0};
            E   = E - 8'd1;
          end
      end

      // round RN-even: G=[2] R=[1] S_d=[0], alignment sticky in stk,
      // tie LSB=[3]. On-grid half behaves differently for add vs eff-sub:
      // add pushes above half; subtract pulls below.
      if (!acc[2])
        round_up = 1'b0;
      else if (acc[1] || acc[0])
        round_up = 1'b1;
      else if (sa != sb)
        round_up = stk ? 1'b0 : acc[3];
      else
        round_up = stk ? 1'b1 : acc[3];
      if (round_up) acc = acc + 28'd8;
      if (acc[26]) begin                                   // normal result
        if (acc[27]) begin                                 // frac carry-out
          acc = 28'd1 << 26;
          E   = E + 8'd1;
        end
        if (E >= 8'd255) return {rsign, 8'hFF, 23'b0};
        return {rsign, E, acc[25:3]};
      end
      return {rsign, 8'h00, acc[25:3]};                    // subnormal
    end
  endfunction

  // ======== IEEE 754 SP MULTIPLY =========================================
  function automatic logic [31:0] fp_mul(input logic [31:0] xa, input logic [31:0] xb);
    bit sa, sb, rs;
    logic [7:0]  ea, eb, Ea, Eb;
    logic [22:0] ma, mb;
    logic [23:0] pa, pb;
    logic [47:0] prod;
    int ep;
    begin
      sa = xa[31]; ea = xa[30:23]; ma = xa[22:0];
      sb = xb[31]; eb = xb[30:23]; mb = xb[22:0];
      rs = sa ^ sb;

      if (((&ea) && (|ma)) || ((&eb) && (|mb))) return QNAN;
      if (&ea && (&eb))                       return {rs, 8'hFF, 23'b0};
      if (&ea && (eb == 8'd0) && (mb == 0))   return QNAN; // inf * 0
      if (&eb && (ea == 8'd0) && (ma == 0))   return QNAN;
      if (&ea) return {rs, 8'hFF, 23'b0};
      if (&eb) return {rs, 8'hFF, 23'b0};
      if (((ea == 8'd0) && (ma == 0)) || ((eb == 8'd0) && (mb == 0)))
        return {rs, 31'b0};

      pa   = (ea != 8'd0) ? {1'b1, ma} : {1'b0, ma};
      pb   = (eb != 8'd0) ? {1'b1, mb} : {1'b0, mb};
      Ea   = (ea != 8'd0) ? ea : 8'd1;
      Eb   = (eb != 8'd0) ? eb : 8'd1;
      prod = pa * pb;
      ep   = int'(Ea) + int'(Eb) - 300;
      return fp_round(rs, {16'd0, prod}, ep);
    end
  endfunction

  // ======== IEEE 754 SP INT-TO-FLOAT =====================================
  function automatic logic [31:0] fp_i2f(input logic [31:0] iv);
    bit sg;
    logic [31:0] mag;
    begin
      sg  = iv[31];
      mag = sg ? (32'd0 - iv) : iv;
      return fp_round(sg, {32'd0, mag}, 0);
    end
  endfunction

  // ======== IEEE 754 SP FLOAT-TO-INT (trunc toward zero, saturating) =====
  function automatic logic [31:0] fp_f2i(input logic [31:0] fv);
    bit sg;
    logic [7:0]  e;
    logic [22:0] m;
    logic [32:0] wide;
    logic [31:0] mag;
    int k2;
    begin
      sg = fv[31]; e = fv[30:23]; m = fv[22:0];
      if (e < 8'd127) return 32'b0;                        // |v| < 1 (incl 0/subnormals)
      if (&e)         return sg ? 32'h80000000 : 32'h7FFFFFFF;
      if (e > 8'd158) return sg ? 32'h80000000 : 32'h7FFFFFFF;
      if (e >= 8'd150) begin
        wide = {9'd0, 1'b1, m};
        for (k2 = 0; k2 < 9; k2++)                         // e-150 in [0..8]
          if ((int'(e) - 150) > k2) wide = {wide[31:0], 1'b0};
        mag  = wide[31:0];
        if (!sg && (wide[32] || (mag >= 32'h80000000)))
          return 32'h7FFFFFFF;
        if (sg && (mag > 32'h80000000)) return 32'h80000000;
      end else begin
        mag = {8'd0, 1'b1, m} >> (150 - e);                // 150-e in [1..23]
      end
      return sg ? (32'd0 - mag) : mag;
    end
  endfunction

  // ======== lane datapath ================================================
  genvar g;
  generate for (g = 0; g < SIMD_LANES; g++) begin : g_lane
    always_comb begin
      case (op)
        5'd00:   y[g] = fp_add(a[g], b[g]);                                  // FADD
        5'd01:   y[g] = fp_add(a[g], {~b[g][31], b[g][30:0]});               // FSUB
        5'd02:   y[g] = fp_mul(a[g], b[g]);                                  // FMUL
        5'd03:   y[g] = fp_i2f(a[g]);                                        // I2F
        5'd04:   y[g] = fp_f2i(a[g]);                                        // F2I
        default: y[g] = 32'b0;
      endcase
    end
  end endgenerate

endmodule
