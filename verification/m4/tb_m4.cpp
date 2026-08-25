// SciGPU M4 D01 smoke test — 2 wavefronts, independent scalar programs
#include <verilated.h>
#include "Vscigpu_m4_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

using u64 = uint64_t; using u32 = uint32_t;
static Vscigpu_m4_top* d;

static bool dut_if_req_valid() { return d->if_req_valid != 0; }
static bool dut_if_req_ready() { return d->if_req_ready != 0; }
static void tick() { d->clk=0; d->eval(); d->clk=1; d->eval(); }

struct Imem {
    std::vector<u64> mem;
    bool pend=false; u64 pend_pc=0;
    bool out_valid=false, out_err=false; u64 out_insn=0;
    void pre(vluint8_t& rv, u64& rpc, vluint8_t& rrdy,
             vluint8_t& pv, u64& pi, vluint8_t& pe) {
        rrdy = (!pend && !out_valid) ? 1 : 0;
        if (pend && !out_valid) {
            out_err = pend_pc >= mem.size();
            out_insn = out_err ? 0 : mem[pend_pc];
            out_valid=true; pend=false;
        }
        pv=out_valid; pi=out_insn; pe=out_err;
    }
    void post(bool rf, bool pf) {
        if(rf){pend=true;pend_pc=d->if_req_pc;}
        if(pf) out_valid=false;
    }
};
static Imem imem;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vscigpu_m4_top;
    // reset
    d->rst=1; d->wf_launch_valid=0; d->wf_completion_ready=1;
    for(int i=0;i<3;i++) tick();
    d->rst=0; tick();

    // Program: S_ADD s2,s1,s1 ; RET
    std::vector<u64> prog = {
        ((u64)0x002 << 52) | ((u64)2 << 48) | ((u64)2 << 40) |
        ((u64)1 << 32) | ((u64)1 << 24),   // S_ADD s2,s1,s1
        0x7cf5000000000000ULL               // RET
    };
    imem.mem = prog;

    printf("post-reset\n"); fflush(stdout);
    // Preload s1 differently per wavefront
    for (u32 wf = 0; wf < 2; wf++) {
        u32 val = (wf==0) ? 42 : 99;
        d->sgpr_init_valid=1; d->sgpr_init_slot=wf;
        d->sgpr_init_addr=1; d->sgpr_init_data=val;
        do tick(); while (!d->sgpr_init_ready);
        d->sgpr_init_valid=0;
    }

    printf("pre-launch\n"); fflush(stdout);
    printf("launch_ready=%d alloc=%02x\n", (int)d->wf_launch_ready,
           (unsigned)d->dbg_allocated); fflush(stdout);
    // Launch both
    for (u32 wf = 0; wf < 2; wf++) {
        d->wf_launch_valid=1; d->wf_launch_slot=wf;
        d->wf_entry_pc=0; d->wf_code_words=prog.size();
        d->wf_wg_x=wf; d->wf_exec_mask=0xFFFFFFFF;
        d->wf_vgpr_req=8; d->wf_sgpr_req=16;
        // Launch is accepted on the first posedge when target is EMPTY.
        // wf_launch_ready drops after acceptance — do NOT wait on it here.
        d->clk=0; d->eval(); d->clk=1; d->eval();
        d->wf_launch_valid=0;
        d->clk=0; d->eval();
    }

    printf("DBG: launched, entering run loop\n");
    int compls = 0;
    long long cyc = 0;
    for (long long c = 0; c < 5000; ++c) {
        imem.pre(d->if_req_valid,d->if_req_pc,d->if_req_ready,
                 d->if_rsp_valid,d->if_rsp_insn,d->if_rsp_error);
        d->clk = 0; d->eval();               // settle comb
        bool rf = !d->rst && dut_if_req_valid() && dut_if_req_ready();
        bool pf = !d->rst && d->if_rsp_valid && d->if_rsp_ready;
        d->clk = 1; d->eval();               // posedge applies
        imem.post(rf, pf);
        if (d->wf_completion_valid && d->wf_completion_ready) {
            printf("WF%u: fault=%u code=%02x pc=%llx ret=%llu\n",
                (unsigned)d->wf_completion_slot,
                (unsigned)d->wf_completion_fault,
                (unsigned)d->wf_completion_fault_code,
                (unsigned long long)d->wf_completion_pc,
                (unsigned)d->wf_completion_slot,
                (unsigned)d->wf_completion_fault,
                (unsigned long long)d->wf_completion_retired_count);
            ++compls;
            if (compls == 2) break;
        }
    }
    delete d;
    printf("D01 %s (%d completions)\n", compls==2 ? "PASS" : "FAIL", compls);
    return compls==2 ? 0 : 1;
}
