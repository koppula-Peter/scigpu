// M4 scheduler unit driver: ≥100,000 randomized cycles per N against the
// golden RR semantics (reimplemented independently here as spec formulas).
#include <verilated.h>
#include "Vscigpu_sched_unit_tb.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

using u32 = uint32_t;
static Vscigpu_sched_unit_tb* d;

int run_n(unsigned N, unsigned seed, long long cycles) {
    std::mt19937 rng(seed * 7919u + N);
    d->clk = 0; d->rst = 1; d->issueable = 0; d->accept = 0;
    for (int i = 0; i < 3; i++) { d->clk=1; d->eval(); d->clk=0; d->eval(); }
    d->rst = 0;

    u32 model_ptr = 0;
    long long mismatches = 0, grants = 0;
    for (long long c = 0; c < cycles; ++c) {
        // randomized issueable mask within N bits; accept mostly-1 to exercise wrap
        u32 m = rng() & ((N >= 8) ? 0xFFu : ((1u << N) - 1u));
        if (rng() % 100 < 10) m = 0;                    // idle cycles
        u32 acc = (rng() % 100 < 90) ? 1 : 0;           // occasional non-accept
        d->issueable = m; d->accept = acc;
        d->clk = 0; d->eval();               // settle combinational outputs

        // spec: scan from model_ptr (state BEFORE this edge)
        int exp_id = -1;
        for (unsigned k = 0; k < N; ++k) {
            unsigned idx = (model_ptr + k) % N;
            if ((m >> idx) & 1u) { exp_id = (int)idx; break; }
        }
        bool exp_valid = (exp_id >= 0);

        bool gv = d->grant_valid; u32 gid = d->grant_id; u32 ptr = d->rr_ptr;
        if (gv != exp_valid || (gv && gid != (u32)exp_id)) {
            if (mismatches < 5)
                printf("MISMATCH N=%u c=%lld m=%02x ptr=%u : rtl(%d,%u) exp(%d,-)\n",
                       N, c, m, model_ptr, (int)gv, gid, exp_id);
            ++mismatches;
        }
        if (ptr != model_ptr) {
            if (mismatches < 5)
                printf("PTR MISMATCH N=%u c=%lld rtl=%u model=%u\n",
                       N, c, ptr, model_ptr);
            ++mismatches;
        }
        d->clk = 1; d->eval();               // edge applies registered update
        if (gv && acc) {
            model_ptr = ((u32)exp_id + 1 == N) ? 0 : (u32)exp_id + 1;
            ++grants;
        }
    }
    printf("N=%u seed=%u cycles=%lld grants=%lld mismatches=%lld\n",
           N, seed, cycles, grants, mismatches);
    return mismatches ? 1 : 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned N = (argc > 1) ? atoi(argv[1]) : 4;
    unsigned seed = (argc > 2) ? atoi(argv[2]) : 1;
    long long cyc = (argc > 3) ? atoll(argv[3]) : 100000;
    d = new Vscigpu_sched_unit_tb;   // compiled per-N
    int rc = run_n(N, seed, cyc);
    delete d;
    return rc;
}
