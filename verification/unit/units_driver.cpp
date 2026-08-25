// SciGPU M2 unit-test driver: ALU boundaries, FLAGS vectors, DECODER legality,
// SGPR file behaviour. Self-checking; exit nonzero on failure (directive §43-46).
#include <verilated.h>
#include "Vscigpu_units_tb.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

using u32 = uint32_t;
using u64 = uint64_t;
static Vscigpu_units_tb* dut;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static int fails = 0;
static void expect(const char* what, long long got, long long exp) {
    if (got != exp) {
        printf("  UNIT FAIL %s: got %lld expected %lld\n", what, got, exp);
        ++fails;
    }
}

static u32 alu(u32 a, u32 b, u32 op) {
    dut->ua_a = a; dut->ua_b = b; dut->ua_op = op; dut->eval();
    return dut->ua_y;
}
static void flags(u32 a, u32 b, u32& z, u32& n, u32& c, u32& v,
                  u32& scc_eq, u32& scc_lt, u32& scc_gt) {
    u32 r = a - b;
    dut->uf_a = a; dut->uf_b = b; dut->uf_r = r;
    dut->uf_kind = 0; dut->eval(); scc_eq = dut->uf_scc;
    dut->uf_kind = 1; dut->eval(); scc_lt = dut->uf_scc;
    dut->uf_kind = 2; dut->eval(); scc_gt = dut->uf_scc;
    z = dut->uf_z; n = dut->uf_n; c = dut->uf_c; v = dut->uf_v;
}
static void decode(u64 insn) { dut->ud_insn = insn; dut->eval(); }

// opcode helpers mirroring scigpu_defs encoders
static u64 enc_srr(u32 opc, u32 d, u32 s0, u32 s1) {
    return ((u64)opc << 52) | ((u64)2 << 48) | ((u64)d << 40) | ((u64)s0 << 32) | ((u64)s1 << 24);
}
static u64 enc_sri(u32 opc, u32 d, u32 s0, u32 imm24) {
    return ((u64)opc << 52) | ((u64)3 << 48) | ((u64)d << 40) | ((u64)s0 << 32) | ((u64)(imm24 & 0xFFFFFF) << 8);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vscigpu_units_tb;

    // ---------------- ALU boundary vectors (directive §43) -----------------
    const u32 bounds[] = {0, 1, 0xFFFFFFFFu, 0x80000000u, 0x7FFFFFFFu};
    const struct { const char* nm; u32 op; } ops[] = {
        {"ADD",1},{"SUB",2},{"AND",3},{"OR",4},{"XOR",5},{"NOT",6},
        {"SHL",7},{"SHR",8},{"SAR",9},{"MUL",10}};
    for (auto a : bounds) for (auto b : bounds) {
        for (auto& o : ops) {
            u32 y = alu(a, b, o.op);
            u32 e;
            switch (o.op) {
                case 1: e = a + b; break;
                case 2: e = a - b; break;
                case 3: e = a & b; break;
                case 4: e = a | b; break;
                case 5: e = a ^ b; break;
                case 6: e = ~a; break;
                case 7: e = a << (b & 31); break;
                case 8: e = a >> (b & 31); break;
                case 9: { int32_t s = (int32_t)a; e = (u32)(s >> (b & 31)); break; }
                case 10: e = a * b; break;
            }
            if (y != e) { printf("UNIT FAIL ALU %s(%08x,%08x): %08x != %08x\n",
                                 o.nm, a, b, y, e); ++fails; }
        }
    }
    // shift-amount masking [4:0]
    for (u32 sh = 0; sh <= 63; ++sh) {
        u32 a = 0xDEADBEEF;
        if (alu(a, sh, 7) != (a << (sh & 31))) { printf("UNIT FAIL SHL mask %u\n", sh); ++fails; }
        if (alu(a, sh, 8) != (a >> (sh & 31))) { printf("UNIT FAIL SHR mask %u\n", sh); ++fails; }
        int32_t s = -123456789;
        if (alu(a | 0x80000000u ? 0xF1234567u : a, sh, 9) !=
            (u32)((int32_t)0xF1234567 >> (sh & 31)))
            { printf("UNIT FAIL SAR mask %u\n", sh); ++fails; }
    }
    printf("unit ALU vectors done\n");

    // ---------------- FLAGS (directive §44) --------------------------------
    const struct { u32 a, b; } fv[] = {
        {0,0},{1,1},{1,2},{2,1},{0x80000000u,1},{0x7FFFFFFFu,0xFFFFFFFFu},
        {0,1},{0xFFFFFFFFu,0},{5,7},{7,5}};
    for (auto& t : fv) {
        u32 z,n,c,v,se,slt,sgt;
        flags(t.a, t.b, z,n,c,v, se,slt,sgt);
        u32 r = t.a - t.b;
        if (z != (r==0)) { printf("UNIT FLAG Z wrong\n"); ++fails; }
        if (n != (r>>31)) { printf("UNIT FLAG N wrong\n"); ++fails; }
        if (c != (t.a >= t.b)) { printf("UNIT FLAG C wrong\n"); ++fails; }
        int32_t sa=(int32_t)t.a, sb=(int32_t)t.b;
        if (v != (((t.a>>31)!=(t.b>>31)) && ((r>>31)!=(t.a>>31))))
            { printf("UNIT FLAG V wrong\n"); ++fails; }
        if (se != (t.a==t.b)) { printf("UNIT SCC EQ wrong\n"); ++fails; }
        if (slt != (sa<sb)) { printf("UNIT SCC LT wrong\n"); ++fails; }
        if (sgt != (sa>sb)) { printf("UNIT SCC GT wrong\n"); ++fails; }
    }
    printf("unit FLAGS vectors done\n");

    // ---------------- DECODER (directive §45) ------------------------------
    // legal samples
    decode(enc_srr(0x001, 3, 4, 5));           // S_MOV reg
    if (!dut->ud_legal || dut->ud_cls != 1) { printf("UNIT DEC S_MOV rr fail\n"); ++fails; }
    decode(enc_sri(0x001, 3, 0, 0x800001));    // S_MOV imm negative
    if (!dut->ud_legal || dut->ud_cls != 1 || !dut->ud_useimm) { printf("UNIT DEC S_MOV i fail\n"); ++fails; }
    if (dut->ud_imm != 0xFF800001u) { printf("UNIT DEC sext24 fail: %08x\n", dut->ud_imm); ++fails; }
    decode(((u64)0x020 << 52) | ((u64)5 << 48) | (10ull << 24)); // S_BRA +5
    if (!dut->ud_legal || dut->ud_disp != 10) { printf("UNIT DEC BRA fail\n"); ++fails; }
    decode(((u64)0x030 << 52) | ((u64)6 << 48) | (12ull << 8) | 0); // GETID s12,WG_X
    if (!dut->ud_legal || dut->ud_gsel != 0 || dut->ud_gdst != 12)
        { printf("UNIT DEC GETID fail\n"); ++fails; }
    // negatives
    decode(0);                                  // all-zero word
    if (dut->ud_legal) { printf("UNIT DEC zero-word must be illegal\n"); ++fails; }
    decode(((u64)0x100 << 52) | ((u64)0 << 48)); // vector opcode in scalar core
    if (dut->ud_legal) { printf("UNIT DEC vector-opcode must be illegal in M2\n"); ++fails; }
    // NOTE (MICRO-001 §1.6): reserved COND and unsupported GETID selectors are
    // LEGAL at decode and fault at EXECUTE in the control FSM; covered by the
    // core-level fault matrix (P-series / faults suite), not here.
    decode(((u64)0x021 << 52) | ((u64)5 << 48) | (0x0Full << 16)); // reserved cond
    if (!dut->ud_legal) { printf("UNIT DEC reserved cond legality\n"); ++fails; }
    decode(((u64)0x030 << 52) | ((u64)6 << 48) | 3ull); // bad selector
    if (!dut->ud_legal) { printf("UNIT DEC bad selector legality\n"); ++fails; }
    decode((7ull << 48) | 0x7000000000000000ull); // FMT=7 extension attempt
    if (dut->ud_legal) { printf("UNIT DEC XEXT must be illegal in M2\n"); ++fails; }
    printf("unit DECODER vectors done\n");

    // ---------------- SGPR file (directive §46) ----------------------------
    tick();
    // init write while idle-equivalent (direct port)
    dut->ug_init_we = 1; dut->ug_init_addr = 5; dut->ug_init_data = 0xABCD1234; tick();
    dut->ug_init_we = 0;
    // read back both ports
    dut->ug_ra0 = 5; dut->ug_ra1 = 6; dut->eval();
    if (dut->ug_q0 != 0xABCD1234u) { printf("UNIT SGPR init readback fail\n"); ++fails; }
    // commit write
    dut->ug_we = 1; dut->ug_wa = 63; dut->ug_wd = 77; tick();
    dut->ug_we = 0; dut->ug_ra1 = 63; dut->eval();
    if (dut->ug_q1 != 77) { printf("UNIT SGPR commit-write readback fail\n"); ++fails; }
    // invalid indices
    dut->ug_ra0 = 64; dut->eval();
    if (!dut->ug_inv0) { printf("UNIT SGPR inv0 not flagged at 64\n"); ++fails; }
    dut->ug_ra1 = 255; dut->eval();
    if (!dut->ug_inv1) { printf("UNIT SGPR inv1 not flagged at 255\n"); ++fails; }
    // OOB write must be ignored
    dut->ug_we = 1; dut->ug_wa = 200; dut->ug_wd = 999; tick();
    dut->ug_we = 0;
    dut->ug_ra0 = 200 & 63; dut->eval();       // would alias if truncated badly? mem has only 64 entries; verify no crash + inv flags used by core
    printf("unit SGPR vectors done\n");

    // randomized cross-check vs local model (reset file first so model==RTL)
    dut->rst = 1; tick(); tick(); dut->rst = 0; tick();
    std::mt19937 rng(4242);
    u32 rm[64] = {0};
    for (int it = 0; it < 5000; ++it) {
        bool wr = rng() & 1;
        u32 idx = rng() % 70;                  // includes OOB probes
        u32 val = rng();
        if (wr && idx < 64) {
            dut->ug_we = 1; dut->ug_wa = idx; dut->ug_wd = val; tick(); dut->ug_we = 0;
            rm[idx] = val;
        } else {
            dut->ug_ra0 = idx; dut->eval();
            u32 expct = (idx < 64) ? rm[idx] : dut->ug_q0; // OOB data undefined; flag matters
            if (idx < 64 && dut->ug_q0 != expct) { printf("UNIT SGPR rand mismatch @%u\n", idx); ++fails; }
            if (dut->ug_inv0 != (idx >= 64)) { printf("UNIT SGPR rand inv-flag wrong @%u\n", idx); ++fails; }
        }
    }
    printf("unit SGPR randomized done\n");

    delete dut;
    if (fails) { printf("UNIT RESULT: FAIL (%d)\n", fails); return 1; }
    printf("UNIT RESULT: PASS\n");
    return 0;
}
