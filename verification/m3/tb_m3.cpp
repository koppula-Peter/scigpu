// SciGPU M3 verification driver (Verilator). Compiled once per width with
// -GSIMD_LANES=<L>. Modes: diff | resetstress | completionhold  (directive §94-103).
#include <verilated.h>
#include "Vscigpu_m3_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <random>

using u64 = uint64_t; using u32 = uint32_t;
static Vscigpu_m3_top* dut;

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
static void hard_reset() {
    dut->rst = 1;
    dut->start_valid = 0; dut->completion_ready = 1;
    dut->sgpr_init_valid = 0; dut->pred_init_valid = 0; dut->vgpr_init_valid = 0;
    for (int i = 0; i < 3; i++) tick();
    dut->rst = 0; tick();
}

struct Imem {
    std::vector<u64> mem;
    std::mt19937 rng; int stall_pct, max_lat;
    bool pend=false, out_valid=false, out_err=false;
    u64 pend_pc=0, out_insn=0; int wait=0;
    void reset(unsigned seed,int sp,int ml){ rng.seed(seed); stall_pct=sp; max_lat=ml;
        pend=out_valid=out_err=false; wait=0; }
    void hard_clear(){ pend=false; out_valid=false; wait=0; }
    void pre(vluint8_t& rv, u64& rpc, vluint8_t& rrdy,
             vluint8_t& pv, u64& pi, vluint8_t& pe) {
        rrdy = (!pend && !out_valid && ((int)(rng()%100) >= stall_pct)) ? 1 : 0;
        if (pend && wait==0 && !out_valid) {
            out_err = pend_pc >= mem.size();
            out_insn = out_err ? 0 : mem[pend_pc];
            out_valid = true; pend = false;
        }
        pv = out_valid; pi = out_insn; pe = out_err;
    }
    void post(bool rf, bool pf) {
        if (rf) { pend=true; pend_pc=dut->if_req_pc; wait=(int)(rng()%(max_lat+1)); }
        if (pf) out_valid=false;
        if (pend && wait>0) --wait;
    }
};
static Imem imem;

static bool load_meta(const std::string& dir, u32& exec, u32& vq, u32& sq) {
    std::ifstream f(dir + "/meta.txt"); std::string k; char eq;
    std::string tok;
    exec=0xFFFFFFFF; vq=16; sq=16;
    while (f >> tok) {
        size_t e = tok.find('=');
        std::string key = tok.substr(0,e), val = tok.substr(e+1);
        if (key=="exec") exec = std::stoul(val,nullptr,16);
        else if (key=="vgpr_req") vq = std::stoul(val);
        else if (key=="sgpr_req") sq = std::stoul(val);
    }
    return true;
}
static bool load_words(const std::string& dir) {
    std::ifstream f(dir+"/prog.words.hex"); if(!f) return false;
    std::string s; imem.mem.clear();
    while (f>>s) imem.mem.push_back(std::stoull(s,nullptr,16));
    return !imem.mem.empty();
}
static bool load_pred(const std::string& dir, std::vector<u32>& p) {
    std::ifstream f(dir+"/pred.hex"); if(!f) { p.assign(15,0); return true; }
    std::string s; p.clear();
    while (f>>s) p.push_back(std::stoul(s,nullptr,16));
    while (p.size()<15) p.push_back(0);
    return true;
}
static bool load_vgprinit(const std::string& dir,
                          std::vector<std::tuple<unsigned,unsigned,u32>>& v) {
    std::ifstream f(dir+"/vgpr.hex"); if(!f) return true;
    std::string a,l,d;
    while (f >> a >> l >> d)
        v.emplace_back(std::stoul(a), std::stoul(l), std::stoul(d,nullptr,16));
    return true;
}

static void do_preloads(const std::vector<u32>& sgpr_words,
                        const std::vector<u32>& preds,
                        const std::vector<std::tuple<unsigned,unsigned,u32>>& vg) {
    // SGPR
    for (size_t i=0;i<sgpr_words.size();i++) {
        dut->sgpr_init_valid=1; dut->sgpr_init_addr=i; dut->sgpr_init_data=sgpr_words[i];
        do { dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); } while(!dut->sgpr_init_ready);
    }
    dut->sgpr_init_valid=0;
    // predicates
    for (int i=0;i<15;i++) {
        dut->pred_init_valid=1; dut->pred_init_addr=i; dut->pred_init_data=preds[i];
        do { dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); } while(!dut->pred_init_ready);
    }
    dut->pred_init_valid=0;
    // VGPR
    for (auto& [va,vl,vd] : vg) {
        dut->vgpr_init_valid=1; dut->vgpr_init_addr=va; dut->vgpr_init_lane=vl;
        dut->vgpr_init_data=vd;
        do { dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); } while(!dut->vgpr_init_ready);
    }
    dut->vgpr_init_valid=0;
}

static std::string trace_line() {
    char L[320];
    snprintf(L,sizeof L,
        "%016llx %016llx %x %02x %08x %x %x %x %016llx %08x %x %08x %x %02x %08x",
        (unsigned long long)dut->trace_pc,(unsigned long long)dut->trace_insn,
        (unsigned)dut->trace_sgpr_we & 1u,(unsigned)dut->trace_sgpr_addr,
        (unsigned)dut->trace_sgpr_wdata,
        (unsigned)dut->trace_sc_flags & 0xFu,(unsigned)dut->trace_scc & 1u,
        (unsigned)dut->trace_branch_taken & 1u,
        (unsigned long long)dut->trace_next_pc,
        (unsigned long long)dut->trace_exec_mask,
        (unsigned)dut->trace_pred_idx & 0xFu,
        (unsigned long long)dut->trace_effective_mask,
        (unsigned)dut->trace_vgpr_we & 1u,
        (unsigned)dut->trace_vgpr_addr,
        (unsigned long long)dut->trace_vgpr_write_mask);
    return std::string(L);
}
static std::string done_line() {
    char D[128];
    snprintf(D,sizeof D,"DONE retired=%llu fault=%02x pc=%016llx",
        (unsigned long long)dut->completion_retired_count,
        (unsigned)dut->completion_fault_code,
        (unsigned long long)dut->completion_pc);
    return std::string(D);
}
static std::string state_dump(u32 sgpr_n, u32 vgpr_n) {
    std::ostringstream o;
    char B[16]; bool first;
    o << "SGPR "; first=true;
    for (u32 i=0;i<sgpr_n;i++){ dut->dbg_sgpr_addr=i; dut->eval();
        snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_sgpr_data);
        if(!first) o << " "; o << B; first=false; }
    o << "\nPRED "; first=true;
    for (int i=0;i<15;i++){ dut->dbg_pred_addr=i; dut->eval();
        snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_pred_data);
        if(!first) o << " "; o << B; first=false; }
    o << "\nEXEC ";
    { char E[16]; snprintf(E,sizeof E,"%08x",(unsigned)dut->trace_exec_mask);
      o << E; }
    o << "\n";
    for (u32 v=0;v<vgpr_n;v++) {
        o << "VGPR " << std::hex << std::setw(2) << std::setfill('0') << v << " ";
        bool fw=true;
        for (int ln=0;ln<32;ln++){
            dut->dbg_vgpr_addr=v; dut->dbg_vgpr_lane=ln; dut->eval();
            snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_vgpr_data);
            if(!fw) o << " "; o << B; fw=false;
        }
        o << "\n";
    }
    return o.str();
}

static int run_core(const std::string& dir, u32 exec, unsigned seed,
                    int stall, int lat, const std::string& tag) {
    std::ofstream tr(dir + "/rtl"+tag+".trace");
    dut->start_valid=0; dut->completion_ready=1;
    dut->start_entry_pc=0; dut->start_code_words=imem.mem.size();
    dut->start_wg_x=0; dut->start_exec_mask=exec;
    // declared reqs from meta
    u32 vq=16,sq=16; { std::ifstream f(dir+"/meta.txt"); std::string t;
        while (f>>t){ auto e=t.find('='); auto k=t.substr(0,e), v=t.substr(e+1);
            if(k=="vgpr_req") vq=std::stoul(v); else if(k=="sgpr_req") sq=std::stoul(v);} }
    dut->start_vgpr_req=vq; dut->start_sgpr_req=sq;
    dut->start_valid=1;
    long long cyc=0;
    while (cyc++ < 100000) {
        imem.pre(dut->if_req_valid,dut->if_req_pc,dut->if_req_ready,
                 dut->if_rsp_valid,dut->if_rsp_insn,dut->if_rsp_error);
        dut->clk=0; dut->eval();
        if (dut->rst) { dut->if_req_ready=0; dut->if_rsp_ready=0; }
        bool rf=!dut->rst && dut->if_req_valid && dut->if_req_ready;
        bool pf=!dut->rst && dut->if_rsp_valid && dut->if_rsp_ready;
        dut->clk=1; dut->eval();
        imem.post(rf,pf);
        if (getenv("SCIGPU_TB_DEBUG"))
            printf("c%04lld st=%d sV=%d sR=%d bV=%d bI=%u bB=%u wm=%08x vwe=%d wa=%02x\n",
                (int)cyc,(int)dut->dbg_state,(int)dut->trace_valid,
                0,(int)dut->beat_valid,(unsigned)dut->beat_index,
                (unsigned)dut->beat_base,
                (unsigned)dut->trace_vgpr_write_mask,
                0,0);
        if (dut->trace_valid) tr << trace_line() << "\n";
        if (dut->completion_valid && dut->completion_ready) {
            tr << done_line() << "\n"; dut->start_valid=0;
            tr.close();
            std::ofstream st(dir+"/rtl"+tag+".state");
            st << state_dump(64,32); st.close();
            return 0;
        }
        dut->clk=0; dut->eval();
    }
    tr.close();
    return (cyc>=100000) ? -1 : 0;
}

static int compare_files(const std::string& a, const std::string& b,
                         const char* what) {
    std::ifstream fa(a), fb(b);
    std::string la, lb; int line=0;
    while (true) {
        bool ga=(bool)getline(fa,la), gb=(bool)getline(fb,lb);
        if (!ga && !gb) break;
        ++line;
        if (!ga||!gb||la!=lb) {
            printf("MISMATCH %s line %d\n  A: %s\n  B: %s\n",what,line,
                   la.c_str(),lb.c_str());
            return 1;
        }
    }
    return 0;
}

static int mode_diff(const std::string& dir, unsigned seed, int stall, int lat) {
    if (!load_words(dir)) { printf("missing words\n"); return 1; }
    u32 exec,vq,sq; load_meta(dir,exec,vq,sq);
    std::vector<u32> preds; load_pred(dir,preds);
    std::vector<std::tuple<unsigned,unsigned,u32>> vg; load_vgprinit(dir,vg);
    hard_reset(); imem.reset(seed,stall,lat);
    do_preloads(/*no sgpr preloads in m3 suites*/{}, preds, vg);
    int rc = run_core(dir, exec, seed, stall, lat, "");
    if (rc) { printf("cycle cap exceeded\n"); return 1; }
    int bad = compare_files(dir+"/golden.trace", dir+"/rtl.trace", "retire-trace");
    bad |= compare_files(dir+"/golden.state", dir+"/rtl.state", "final-state");
    return bad;
}

static int mode_resetstress(const std::string& dir) {
    if (!load_words(dir)) return 1;
    u32 exec,vq,sq; load_meta(dir,exec,vq,sq);
    std::vector<u32> preds; load_pred(dir,preds);
    std::vector<std::tuple<unsigned,unsigned,u32>> vg; load_vgprinit(dir,vg);
    // clean reference
    hard_reset(); imem.reset(9,10,2);
    do_preloads({},preds,vg);
    run_core(dir,exec,9,10,2,"ref");
    std::ifstream rf(dir+"/rtlref.trace");
    std::vector<std::string> ref; std::string l;
    while (getline(rf,l)) ref.push_back(l);
    if (!ref.empty() && ref.back().rfind("DONE",0)==0)
        ref.pop_back();                       // compare retire lines only

    for (int k=1;k<=40;k++) {
        hard_reset(); imem.reset(200+k,20,2);
        do_preloads({},preds,vg);
        dut->completion_ready=1;
        dut->start_valid=1; dut->start_entry_pc=0;
        dut->start_code_words=imem.mem.size(); dut->start_wg_x=0;
        dut->start_exec_mask=exec; dut->start_vgpr_req=vq; dut->start_sgpr_req=sq;
        long long cyc=0; bool did=false, post=false;
        std::vector<std::string> postl;
        while (cyc++ < 40000) {
            imem.pre(dut->if_req_valid,dut->if_req_pc,dut->if_req_ready,
                     dut->if_rsp_valid,dut->if_rsp_insn,dut->if_rsp_error);
            if (cyc==k && !did) dut->rst=1;
            dut->clk=0; dut->eval();
            if (dut->rst) { dut->if_req_ready=0; dut->if_rsp_ready=0; }
            bool rf=!dut->rst&&dut->if_req_valid&&dut->if_req_ready;
            bool pf=!dut->rst&&dut->if_rsp_valid&&dut->if_rsp_ready;
            dut->clk=1; dut->eval();
            if (dut->rst) imem.hard_clear(); else imem.post(rf,pf);
            if (cyc==k && !did) {
                dut->rst=0; did=true; post=true;
                imem.hard_clear();
                if (dut->completion_valid!=0){printf("GHOST COMPLETION k=%d\n",k);return 1;}
                if (dut->start_ready!=1){printf("start_ready!=1 k=%d\n",k);return 1;}
                dut->start_valid=1; dut->start_entry_pc=0;
                dut->start_code_words=imem.mem.size(); dut->start_wg_x=0;
                dut->start_exec_mask=exec; dut->start_vgpr_req=vq;
                dut->start_sgpr_req=sq;
            }
            if (post && dut->trace_valid) postl.push_back(trace_line());
            if (post && dut->completion_valid && dut->completion_ready) break;
        }
        if (postl.size()!=ref.size()) {
            printf("RESET k=%d count mismatch (%zu vs %zu)\n",k,
                   postl.size(),ref.size()); return 1;
        }
        for (size_t i=0;i<postl.size();++i)
            if (postl[i]!=ref[i]) { printf("RESET k=%d divergence @%zu\n",k,i); return 1; }
    }
    printf("reset stress: 40 injection points clean (vector pipeline)\n");
    return 0;
}

static int mode_completionhold(const std::string& dir) {
    if (!load_words(dir)) return 1;
    u32 exec,vq,sq; load_meta(dir,exec,vq,sq);
    std::vector<u32> preds; load_pred(dir,preds);
    std::vector<std::tuple<unsigned,unsigned,u32>> vg; load_vgprinit(dir,vg);
    hard_reset(); imem.reset(7,10,2); do_preloads({},preds,vg);
    dut->completion_ready=0;                       // hold-by-default
    dut->start_valid=1; dut->start_entry_pc=0;
    dut->start_code_words=imem.mem.size(); dut->start_wg_x=0;
    dut->start_exec_mask=exec; dut->start_vgpr_req=vq; dut->start_sgpr_req=sq;
    long long cyc=0; int holds=0;
    u64 hp=0,hr=0; int hf=-1; u32 hc=0;
    while (cyc++<40000) {
        if (dut->completion_valid) {
            if (holds==0) { hp=dut->completion_pc; hr=dut->completion_retired_count;
                            hf=dut->completion_fault; hc=dut->completion_fault_code; }
            else if (hp!=dut->completion_pc||hr!=dut->completion_retired_count||
                     hf!=(int)dut->completion_fault||hc!=dut->completion_fault_code) {
                printf("COMPLETION UNSTABLE\n"); return 1; }
            if (++holds==5) dut->completion_ready=1;
        }
        imem.pre(dut->if_req_valid,dut->if_req_pc,dut->if_req_ready,
                 dut->if_rsp_valid,dut->if_rsp_insn,dut->if_rsp_error);
        dut->clk=0; dut->eval();
        if (dut->rst) { dut->if_req_ready=0; dut->if_rsp_ready=0; }
        bool rf=!dut->rst&&dut->if_req_valid&&dut->if_req_ready;
        bool pf=!dut->rst&&dut->if_rsp_valid&&dut->if_rsp_ready;
        dut->clk=1; dut->eval();
        imem.post(rf,pf);
        if (holds>=5 && dut->completion_valid && dut->completion_ready) break;
    }
    printf("completion hold: stable across %d held cycles\n", holds);
    return (holds>=5)?0:1;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr,"usage: tb diff|resetstress|completionhold <dir> "
                                    "[seed] [stall%%] [maxlat]\n"); return 2; }
    dut = new Vscigpu_m3_top;
    hard_reset();
    std::string mode=argv[1];
    int rc;
    if (mode=="diff") {
        unsigned seed=(argc>3)?(unsigned)atoi(argv[3]):1;
        int stall=(argc>4)?atoi(argv[4]):15;
        int lat=(argc>5)?atoi(argv[5]):2;
        rc=mode_diff(argv[2],seed,stall,lat);
    } else if (mode=="resetstress") rc=mode_resetstress(argv[2]);
    else if (mode=="completionhold") rc=mode_completionhold(argv[2]);
    else { fprintf(stderr,"unknown mode\n"); rc=2; }
    delete dut;
    return rc;
}
