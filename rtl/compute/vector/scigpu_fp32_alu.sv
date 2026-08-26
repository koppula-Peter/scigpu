// SciGPU M7 — IEEE 754 single-precision vector ALU
// Ops: 0=FADD 1=FSUB 2=FMUL 3=I2F 4=F2I 5=FMA. RN-even; subnormals supported;
// NaN -> canonical qNaN 0x7FC00000; F2I truncates toward zero with saturation.
module scigpu_fp32_alu #(
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic [4:0]   op,
  input  logic [31:0]  a [SIMD_LANES],
  input  logic [31:0]  b [SIMD_LANES],
  input  logic [31:0]  c [SIMD_LANES],
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
    logic sa, sb, rsign, stk_a, stk_n, round_up;
    logic [7:0]  ea, eb, Ea, Eb, E;
    logic [22:0] ma, mb;
    logic [23:0] pa, pb;
    logic [26:0] bigv, smallv, mask;
    logic [27:0] acc;
    int d;
    begin
      stk_a = 1'b0;
      stk_n = 1'b0;
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
      stk_a = 1'b0;
      stk_n = 1'b0;
      if (d > 27) begin
        stk_a  = (smallv != 27'd0);
        smallv = 27'd0;
      end else if (d > 0) begin
        mask   = (27'd1 << d) - 27'd1;
        stk_a  = |(smallv & mask);
        smallv = smallv >> d;
      end

      if (sa == sb)
        acc = {1'b0, bigv} + {1'b0, smallv};
      else
        acc = {1'b0, bigv} - {1'b0, smallv};   // big >= small guaranteed

      if (acc == 28'd0) return 32'b0;                      // exact cancel -> +0
      if (acc[27]) begin                                   // carry out
        stk_n = stk_a | acc[0];
        acc   = {1'b0, acc[27:1]};
        E     = E + 8'd1;
      end else begin
        stk_n = stk_a;
        // left-normalize (fixed-bound: max 26 shifts)
        for (int i = 0; i < 26; i++)
          if ((acc[26] == 1'b0) && (E > 8'd1)) begin
            acc = {1'b0, acc[25:0], 1'b0};
            E   = E - 8'd1;
          end
      end

      // round RN-even: G=[2] R=[1] S_d=[0]; two tail sources at an exact
      // grid-half: stk_n = normalize-fold of the result magnitude (pushes
      // above half -> UP); stk_a = alignment tail of the eff-sub guest
      // (pulls below half -> DOWN; adds -> UP). Pure tie -> parity.
      if (!acc[2])
        round_up = 1'b0;
      else if (acc[1] || acc[0])
        round_up = 1'b1;
      else if (stk_n)
        round_up = 1'b1;
      else if (stk_a)
        round_up = (sa != sb) ? 1'b0 : 1'b1;
      else
        round_up = acc[3];
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

  // ======== IEEE 754 SP FUSED MULTIPLY-ADD ===============================
  // vd = a*b + c, ONE rounding. Exact 48-bit product combined with the
  // addend on a common unit-exponent grid (value = acc * 2^u); results
  // below min-normal use the direct fraction-grid path. RN-even with the
  // fp_add asymmetric on-grid-half rule for folded tails.
  function automatic logic [31:0] fp_fma(input logic [31:0] xa, input logic [31:0] xb,
                                         input logic [31:0] xc);
    logic sa, sb, sc, sp, s_big, s_small, rsign, round_up;
    logic stk_a, stk_n;
    logic [7:0]  ea, eb, ec, Ea, Eb, Ec;
    logic [22:0] ma, mb, mc;
    logic [23:0] pa, pb, pcv;
    logic [47:0] prod;
    int epp, epB, kp, kc, vpp, vpc, u, k, d, fld;
    longint unsigned acc, tmp, one;
    begin
      sa = xa[31]; ea = xa[30:23]; ma = xa[22:0];
      sb = xb[31]; eb = xb[30:23]; mb = xb[22:0];
      sc = xc[31]; ec = xc[30:23]; mc = xc[22:0];
      one = 64'd1;
      stk_a = 1'b0;
      stk_n = 1'b0;
      sp = sa ^ sb;

      // ---- specials ----
      begin
        logic a_nan, b_nan, c_nan, a_inf, b_inf, c_inf, a_zer, b_zer;
        a_nan = (&ea) && (|ma);  b_nan = (&eb) && (|mb);  c_nan = (&ec) && (|mc);
        a_inf = (&ea) && !a_nan; b_inf = (&eb) && !b_nan; c_inf = (&ec) && !c_nan;
        a_zer = (ea == 8'd0) && (ma == 23'd0);
        b_zer = (eb == 8'd0) && (mb == 23'd0);
        if (a_nan || b_nan || c_nan) return QNAN;
        if (a_inf || b_inf) begin
          if ((a_inf && b_zer) || (b_inf && a_zer)) return QNAN;   // inf*0
          if (c_inf && (sc != sp)) return QNAN;                    // inf + (-inf)
          return {sp, 8'hFF, 23'b0};
        end
        if (c_inf) begin
          if (a_zer || b_zer) return QNAN;                         // (0*x)+inf
          return {sc, 8'hFF, 23'b0};
        end
      end

      pa  = (ea != 8'd0) ? {1'b1, ma} : {1'b0, ma};
      pb  = (eb != 8'd0) ? {1'b1, mb} : {1'b0, mb};
      pcv = (ec != 8'd0) ? {1'b1, mc} : {1'b0, mc};
      Ea  = (ea != 8'd0) ? ea : 8'd1;
      Eb  = (eb != 8'd0) ? eb : 8'd1;
      Ec  = (ec != 8'd0) ? ec : 8'd1;

      prod = pa * pb;
      epp  = int'(Ea) + int'(Eb) - 300;                  // prod * 2^epp
      epB  = int'(Ec) - 150;                             // pcv * 2^epB

      // ---- zero shortcuts ----
      if (prod == 48'd0) begin
        if ((ec == 8'd0) && (mc == 23'd0))
          return {(sp & sc), 31'b0};
        return xc;
      end
      if ((ec == 8'd0) && (mc == 23'd0))
        return fp_round(sp, {16'd0, prod}, epp);

      // ---- value exponents (MSB-normalized) ----
      kp = 47;
      for (int i = 46; i >= 0; i--)
        if ((kp == 47) && ((({16'd0, prod} >> i) & one) != 64'd0)) kp = i;
      kc = 23;
      for (int i = 22; i >= 0; i--)
        if ((kc == 23) && ((({40'd0, pcv} >> i) & one) != 64'd0)) kc = i;
      vpp = epp + kp;
      vpc = epB + kc;

      // ===== window path: at least one term in normal range ==============
      u = (vpp >= vpc) ? vpp : vpc;
      u = u - 50;
      if (vpp >= vpc) begin
        acc = ({16'd0, prod}) << (50 - kp);
        tmp = ({40'd0, pcv}) << (50 - kc);
        sp  = sp;                     // product is host candidate
        s_big = sp; s_small = sc;
      end else begin
        acc = ({40'd0, pcv}) << (50 - kc);
        tmp = ({16'd0, prod}) << (50 - kp);
        s_big = sc; s_small = sp;
      end
      d = (vpp >= vpc) ? (vpp - vpc) : (vpc - vpp);

      // guest shift w/ sticky (single assignment into window sticky)
      if (d > 60) begin
        stk_a = (tmp != 64'd0);
        tmp = 64'd0;
      end else if (d > 0) begin
        stk_a = |(tmp & ((one << d) - one));
        tmp = tmp >> d;
      end else begin
        stk_a = 1'b0;
      end

      // ---- signed combine (host magnitude vs aligned guest) ----
      if (sp == sc) begin
        acc   = acc + tmp;
        rsign = sp;
      end else if (acc >= tmp) begin
        acc   = acc - tmp;
        rsign = s_big;
      end else begin
        acc   = tmp - acc;
        rsign = s_small;
      end
      if (acc == 64'd0) return 32'b0;

      // ---- normalize MSB to bit 26 ----
      k = 63;
      for (int i = 62; i >= 0; i--)
        if ((k == 63) && (((acc >> i) & one) != 64'd0)) k = i;
      if (k > 26) begin
        d = k - 26;
        if (d <= 60) stk_n = (acc & ((one << d) - one)) != 64'd0;
        else         stk_n = 1'b1;
        acc >>= d;
        u    += d;
        k    = 26;
      end else if (k < 26) begin
        for (int i = 0; i < 26; i++)
          if ((k < 26) && (u > -152)) begin
            acc = acc << 1;
            u   = u - 1;
            k   = k + 1;
          end
      end

      // ---- settle subnormal anchor: bring unit exponent to -152 --------
      if (u > -152) begin
        for (int i = 0; i < 26; i++)
          if ((k < 26) && (u > -152)) begin
            acc = acc << 1;
            u   = u - 1;
            k   = k + 1;
          end
      end else if (u < -152) begin
        d = -152 - u;
        if (d > 60) begin
          stk_a = 1'b1;
          acc   = 64'd0;
        end else begin
          stk_a = stk_a | ((acc & ((one << d) - one)) != 64'd0);
          acc   = acc >> d;
        end
        u = -152;
        k = 63;
        for (int i = 62; i >= 0; i--)
          if ((k == 63) && (((acc >> i) & one) != 64'd0)) k = i;
      end

      // ---- round RN-even -------------------------------------------------
      // Two distinct tail sources at an exact grid-half:
      //   stk_n   - normalize-fold bits of the RESULT magnitude: real mass,
      //             pushes rem above half -> round UP.
      //   stk_a   - alignment tail of the ALIGNED (subtracted-on-eff-sub)
      //             guest: pulls rem below half on eff-sub -> DOWN; adds
      //             on true-add -> UP.
      if (!acc[2])
        round_up = 1'b0;
      else if (acc[1] || acc[0])
        round_up = 1'b1;
      else if (stk_n)
        round_up = 1'b1;
      else if (stk_a)
        round_up = (sp != sc) ? 1'b0 : 1'b1;
      else
        round_up = acc[3];
      if (round_up) acc = acc + (one << 3);

      // ---- assemble ----
      if (acc[27]) begin                                   // frac carry-out
        acc = (one << 26);
        u   = u + 1;
      end
      fld = u + 153;
      if (fld >= 255) return {rsign, 8'hFF, 23'b0};
      if (acc[26] && (fld >= 1))
        return {rsign, fld[7:0], acc[25:3]};
      return {rsign, 8'h00, acc[25:3]};                    // subnormal
    end
  endfunction

  // ======== lane datapath ================================================
  // Single sequential always_comb: one evaluation context for all lanes so
  // inlined function temporaries cannot interleave between lanes.
  integer gi;
  always_comb begin
    for (gi = 0; gi < int'(SIMD_LANES); gi++) begin
      case (op)
        5'd00:   y[gi] = fp_add(a[gi], b[gi]);                               // FADD
        5'd01:   y[gi] = fp_add(a[gi], {~b[gi][31], b[gi][30:0]});           // FSUB
        5'd02:   y[gi] = fp_mul(a[gi], b[gi]);                               // FMUL
        5'd03:   y[gi] = fp_i2f(a[gi]);                                      // I2F
        5'd04:   y[gi] = fp_f2i(a[gi]);                                      // F2I
        5'd05:   y[gi] = fp_fma(a[gi], b[gi], c[gi]);                        // FMA
        default: y[gi] = 32'b0;
      endcase
    end
  end

endmodule
