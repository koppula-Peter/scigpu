// SciGPU M2 verification driver (Verilator, directive §42/§48-§52).
// Modes:
//   diff <progdir> <stall_seed>   run one program vs golden artifacts
//   resetstress <progdir>         reset mid-flight at every cycle k
//   completionhold <progdir>      hold completion_ready low; check stability
// Exits nonzero on any failure. All failures print MISMATCH details.
#include <verilated.h>
#include "Vscigpu_scalar_core.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <random>

using u64 = uint64_t;
using u32 = uint32_t;
static Vscigpu_scalar_core* dut;
static vluint64_t main_time = 0;

// ---------------------------------------------------------------- helpers --
static void eval_half(int hi) {
    dut->clk = hi;
    dut->eval();
}
static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

struct Imem {
    std::vector<u64> mem;
    // request/response model with randomized ready + latency (directive §51)
    std::mt19937 rng;
    int stall_pct;          // % cycles if_req_ready=0 while idle
    int max_lat;            // response latency 0..max_lat cycles
    bool pend = false; u64 pend_pc = 0; int wait = 0;
    bool out_valid = false; u64 out_insn = 0; bool out_err = false;

    void reset(unsigned seed, int sp, int ml) {
        rng.seed(seed); stall_pct = sp; max_lat = ml;
        pend = false; out_valid = false; wait = 0;
    }
    void hard_clear() {                  // directive §19: same reset clears imem model
        pend = false; out_valid = false; wait = 0;
    }
    void pre(vluint8_t& req_valid, u64& req_pc, vluint8_t& req_ready,
             vluint8_t& rsp_valid, u64& rsp_insn, vluint8_t& rsp_error) {
        req_ready = (!pend && !out_valid &&
                     ((int)(rng() % 100) >= stall_pct)) ? 1 : 0;
        if (pend && wait == 0 && !out_valid) {
            out_valid = true;
            out_err = (pend_pc >= mem.size());
            out_insn = out_err ? 0ull : mem[pend_pc];
            pend = false;
        }
        rsp_valid = out_valid;
        rsp_insn = out_insn;
        rsp_error = out_err;
    }
    void post(bool req_fire, bool rsp_fire) {
        if (req_fire) { pend = true; pend_pc = dut->if_req_pc; wait = (int)(rng() % (max_lat + 1)); }
        if (rsp_fire) out_valid = false;
        if (pend && wait > 0) --wait;
    }
};

static Imem imem;

static void drive_idle_inputs() {
    dut->start_valid = 0;
    dut->completion_ready = 1;
    dut->sgpr_init_valid = 0;
}

// run until completion or cap; collect trace lines; returns fault code
static int run_core(u64 entry, u64 code_words, u32 wg_x,
                    const std::string& rtl_trace_path,
                    long long cycle_cap = 200000) {
    std::ofstream tr(rtl_trace_path);
    drive_idle_inputs();
    // launch
    dut->start_valid = 1;
    dut->start_entry_pc = entry;
    dut->start_code_words = code_words;
    dut->start_wg_x = wg_x;
    long long cyc = 0;
    while (cyc++ < cycle_cap) {
        imem.pre(dut->if_req_valid, dut->if_req_pc, dut->if_req_ready,
                 dut->if_rsp_valid, dut->if_rsp_insn, dut->if_rsp_error);
        eval_half(0);                       // clk low: combinational settle
        bool req_fire = dut->if_req_valid && dut->if_req_ready;   // pre-edge
        bool rsp_fire = dut->if_rsp_valid && dut->if_rsp_ready;   // pre-edge
        dut->clk = 1; dut->eval();          // posedge
        imem.post(req_fire, rsp_fire);

        if (dut->trace_valid) {
            char L[256];
            snprintf(L, sizeof L, "%016llx %016llx %x %02x %08x %x %x %x %016llx",
                     (unsigned long long)dut->trace_pc,
                     (unsigned long long)dut->trace_insn,
                     (unsigned)dut->trace_sgpr_we & 1u,
                     (unsigned)dut->trace_sgpr_addr,
                     (unsigned)dut->trace_sgpr_wdata,
                     (unsigned)dut->trace_sc_flags & 0xFu,
                     (unsigned)dut->trace_scc & 1u,
                     (unsigned)dut->trace_branch_taken & 1u,
                     (unsigned long long)dut->trace_next_pc);
            tr << L << "\n";
        }
        if (getenv("SCIGPU_TB_DEBUG"))
            printf("c%04lld st=%d sready=%d reqv=%d rrdy=%d rspv=%d rrdy=%d "
                   "tracev=%d pc=%llu\n", cyc, (int)dut->dbg_state,
                   (int)dut->start_ready, (int)dut->if_req_valid,
                   (int)dut->if_req_ready, (int)dut->if_rsp_valid,
                   (int)dut->if_rsp_ready, (int)dut->trace_valid,
                   (unsigned long long)dut->dbg_pc);
        if (dut->completion_valid && dut->completion_ready) {
            char D[128];
            snprintf(D, sizeof D, "DONE retired=%llu fault=%02x pc=%016llx",
                     (unsigned long long)dut->completion_retired_count,
                     (unsigned)dut->completion_fault_code,
                     (unsigned long long)dut->completion_pc);
            tr << D << "\n";
            dut->start_valid = 0;
            break;
        }
        dut->clk = 0; dut->eval();
    }
    tr.close();
    if (cyc >= cycle_cap) { fprintf(stderr, "cycle cap exceeded\n"); return -1; }
    return dut->completion_fault ? (int)dut->completion_fault_code : 0;
}

static void hard_reset() {
    dut->rst = 1; drive_idle_inputs();
    for (int i = 0; i < 3; i++) tick();
    dut->rst = 0;
    tick();
}

// read words.hex into imem.mem
static bool load_words(const std::string& dir) {
    std::ifstream f(dir + "/prog.words.hex");
    if (!f) return false;
    std::string s;
    imem.mem.clear();
    while (f >> s) imem.mem.push_back(std::stoull(s, nullptr, 16));
    return !imem.mem.empty();
}

static int compare_artifacts(const std::string& dir, const std::string& rtl_trace,
                             unsigned seed, int stall_pct, int max_lat) {
    std::ifstream g(dir + "/golden.trace");
    std::ifstream r(rtl_trace);
    std::string gl, rl;
    int line = 0;
    while (true) {
        bool gg = (bool)std::getline(g, gl);
        bool rr = (bool)std::getline(r, rl);
        if (!gg && !rr) break;
        ++line;
        if (!gg || !rr || gl != rl) {
            printf("MISMATCH seed=%u stall=%d lat=%d trace line %d\n"
                   "  golden: %s\n  rtl   : %s\n",
                   seed, stall_pct, max_lat, line, gl.c_str(), rl.c_str());
            return 1;
        }
    }
    return 0;
}

static int mode_diff(const std::string& dir, unsigned seed, int stall, int lat) {
    if (!load_words(dir)) { printf("no prog.words.hex in %s\n", dir.c_str()); return 1; }
    hard_reset();
    imem.reset(seed, stall, lat);
    int rc = run_core(0, imem.mem.size(), /*wg_x*/0, dir + "/rtl.trace");
    (void)rc;
    return compare_artifacts(dir, dir + "/rtl.trace", seed, stall, lat);
}

static int mode_reset_stress(const std::string& dir) {
    if (!load_words(dir)) return 1;
    // clean reference
    hard_reset();
    imem.reset(1, 10, 2);
    int rc = run_core(0, imem.mem.size(), 0, dir + "/rtl.ref");
    std::ifstream ref(dir + "/rtl.ref");
    std::vector<std::string> ref_lines;
    { std::string l; while (getline(ref, l)) ref_lines.push_back(l); }

    // reset at every k-th cycle of a re-run; after reset relaunch and require
    // identical final DONE + identical full trace from the relaunch
    for (int k = 1; k <= 40; ++k) {
        hard_reset();
        imem.reset(100 + k, 20, 2);
        drive_idle_inputs();
        dut->start_valid = 1; dut->start_entry_pc = 0;
        dut->start_code_words = imem.mem.size(); dut->start_wg_x = 0;
        long long cyc = 0;
        bool did_reset = false;
        std::vector<std::string> post_trace;
        bool post = false;
        bool rf=false, pf=false;
        int final_fault = -1; u64 final_ret = 0;
        while (cyc++ < 20000) {
            imem.pre(dut->if_req_valid, dut->if_req_pc, dut->if_req_ready,
                     dut->if_rsp_valid, dut->if_rsp_insn, dut->if_rsp_error);
            if (cyc == k && !did_reset)
                dut->rst = 1;
            dut->clk = 0; dut->eval();
            if (dut->rst) { dut->if_req_ready = 0; dut->if_rsp_ready = 0; }
            bool req_fire = !dut->rst && dut->if_req_valid && dut->if_req_ready;
            bool rsp_fire = !dut->rst && dut->if_rsp_valid && dut->if_rsp_ready;
            dut->clk = 1; dut->eval();
            if (getenv("SCIGPU_TB_DEBUG") && cyc <= (long long)k + 10)
                printf("S k=%d c%04lld st=%d svalid=%d tv=%d pc=%llu ret=%llu\n",
                       k, cyc, (int)dut->dbg_state, (int)dut->start_valid,
                       (int)dut->trace_valid, (unsigned long long)dut->dbg_pc,
                       (unsigned long long)dut->completion_retired_count);
            if (getenv("SCIGPU_TB_DEBUG") && cyc <= (long long)k + 6)
                printf("S+ k=%d c%04lld rst=%d srdy=%d reqv=%d rrdy=%d\n",
                       k, cyc, (int)dut->rst, (int)dut->start_ready,
                       (int)dut->if_req_valid, (int)dut->if_req_ready);
            if (cyc == k && !did_reset) {
                dut->rst = 0;
                imem.hard_clear();       // §19: memory model resets with core
                did_reset = true;
                // invariants after reset (directive §27 / §74 / INV-006)
                if (dut->completion_valid != 0) {
                    printf("RESET GHOST COMPLETION at k=%d\n", k); return 1;
                }
                if (dut->start_ready != 1) {
                    printf("RESET start_ready!=1 at k=%d\n", k); return 1;
                }
                dut->start_valid = 1;
                dut->start_entry_pc = 0;
                dut->start_code_words = imem.mem.size();
                dut->start_wg_x = 0;
                post = true;
            }
            imem.post(req_fire, rsp_fire);
            if (post && dut->trace_valid) {
                char L[256];
                snprintf(L, sizeof L, "%016llx %016llx %x %02x %08x %x %x %x %016llx",
                         (unsigned long long)dut->trace_pc, (unsigned long long)dut->trace_insn,
                         (unsigned)dut->trace_sgpr_we, (unsigned)dut->trace_sgpr_addr,
                         (unsigned)dut->trace_sgpr_wdata, (unsigned)dut->trace_sc_flags,
                         (unsigned)dut->trace_scc, (unsigned)dut->trace_branch_taken,
                         (unsigned long long)dut->trace_next_pc);
                post_trace.push_back(L);
            }
            if (post && dut->completion_valid && dut->completion_ready) {
                final_fault = dut->completion_fault;
                final_ret = dut->completion_retired_count;
                break;
            }
            dut->clk = 0; dut->eval();
        }
        if (!did_reset || final_fault < 0) {
            printf("RESET k=%d: no completion after relaunch (cap)\n", k);
            return 1;
        }
        // compare post-reset execution against reference trace lines
        if (post_trace.size() + 0 != ref_lines.size() - 1) {
            printf("RESET k=%d: retire count mismatch (%zu vs %zu)\n",
                   k, post_trace.size(), ref_lines.size() - 1);
            std::ofstream df("/tmp/reset_ref.txt"), dp("/tmp/reset_post.txt");
            for (auto& l : ref_lines) df << l << "\n";
            for (auto& l : post_trace) dp << l << "\n";
            return 1;
        }
        for (size_t i = 0; i < post_trace.size(); ++i)
            if (post_trace[i] != ref_lines[i]) {
                printf("RESET k=%d: trace divergence at %zu\n", k, i); return 1;
            }
        int ref_fault = (int)strtoull(ref_lines.back().substr(ref_lines.back().find("fault=") + 6).c_str(), nullptr, 16);
        if ((int)final_fault != ref_fault) {
            printf("RESET k=%d: fault status mismatch\n", k); return 1;
        }
        (void)final_ret;
    }
    printf("reset stress: 40 injection points clean\n");
    return 0;
}

static int mode_completion_hold(const std::string& dir) {
    if (!load_words(dir)) return 1;
    hard_reset();
    imem.reset(7, 10, 2);
    drive_idle_inputs();
    dut->completion_ready = 0;                 // hold-by-default mode
    dut->start_valid = 1; dut->start_entry_pc = 0;
    dut->start_code_words = imem.mem.size(); dut->start_wg_x = 0;
    long long cyc = 0;
    int holds = 0;
    u64 hold_pc = 0, hold_ret = 0; int hold_fault = -1; u32 hold_code = 0;
    bool accepted = false;
    while (cyc++ < 20000) {
        if (dut->completion_valid) {
            if (holds == 0) {
                hold_pc = dut->completion_pc; hold_ret = dut->completion_retired_count;
                hold_fault = dut->completion_fault; hold_code = dut->completion_fault_code;
            }
            if (holds < 5) {
                // stability across every held cycle (ASSERT-005 equivalent)
                if (hold_pc != dut->completion_pc || hold_ret != dut->completion_retired_count ||
                    hold_fault != (int)dut->completion_fault || hold_code != dut->completion_fault_code) {
                    printf("COMPLETION UNSTABLE during backpressure (hold %d)\n", holds);
                    return 1;
                }
                ++holds;
                dut->completion_ready = (holds == 5);   // release on 5th
            }
        } else {
            dut->completion_ready = 0;
        }
        imem.pre(dut->if_req_valid, dut->if_req_pc, dut->if_req_ready,
                 dut->if_rsp_valid, dut->if_rsp_insn, dut->if_rsp_error);
        dut->clk = 0; dut->eval();
        bool rf = dut->if_req_valid && dut->if_req_ready;
        bool pf = dut->if_rsp_valid && dut->if_rsp_ready;
        dut->clk = 1; dut->eval();
        imem.post(rf, pf);
        if (holds == 5 && !dut->completion_valid) { accepted = true; break; }
        if (holds == 5 && dut->completion_ready && dut->completion_valid) { /* releasing */ }
        if (holds == 5 && accepted) break;
    }
    printf("completion hold: stable across %d held cycles, accepted=%d\n", holds, accepted);
    return (holds == 5 && accepted) ? 0 : 1;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        fprintf(stderr, "usage: tb_m2 diff <dir> <seed> [stall%%] [maxlat] |\n"
                        "           tb_m2 resetstress <dir> | tb_m2 completionhold <dir>\n");
        return 2;
    }
    dut = new Vscigpu_scalar_core;
    std::string mode = argv[1];
    hard_reset();
    int rc;
    if (mode == "diff") {
        unsigned seed = (argc > 3) ? (unsigned)atoi(argv[3]) : 1;
        int stall = (argc > 4) ? atoi(argv[4]) : 15;
        int lat = (argc > 5) ? atoi(argv[5]) : 2;
        rc = mode_diff(argv[2], seed, stall, lat);
    } else if (mode == "resetstress") {
        rc = mode_reset_stress(argv[2]);
    } else if (mode == "completionhold") {
        rc = mode_completion_hold(argv[2]);
    } else {
        fprintf(stderr, "unknown mode\n"); rc = 2;
    }
    delete dut;
    return rc;
}
