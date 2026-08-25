// SciGPU M5 verification driver (Verilator); built per -GSIMD_LANES=<L> and
// optionally -GMASK_STACK_DEPTH=<D>.
//
// Modes:
//   diff <dir>                      single-wavefront full differential:
//                                   event stream + mask events + final state
//   mdiff <dir> <slots>             multi-wavefront: per-wf event streams,
//                                   completion records, per-slot final states
//   resetstress <dir>               reset with divergent state mid-execution
#include <verilated.h>
#include "Vscigpu_m5_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <random>
#include <iomanip>

using u64 = uint64_t; using u32 = uint32_t;
static Vscigpu_m5_top* dut;

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
static void hard_reset() {
    dut->rst = 1;
    dut->wf_launch_valid = 0; dut->wf_completion_ready = 1;
    dut->sgpr_init_valid = 0; dut->pred_init_valid = 0; dut->vgpr_init_valid = 0;
    for (int i = 0; i < 3; i++) tick();
    dut->rst = 0; tick();
}

struct Imem {
    std::vector<u64> mem;
    std::mt19937 rng; int stall_pct, max_lat;
    bool pend=false, out_valid=false, out_err=false;
    u64 pend_pc=0, out_insn=0; int wait=0;
    void reset(unsigned seed,int sp,int ml){ rng.seed(seed); stall_pct=sp;
        max_lat=ml; pend=out_valid=out_err=false; wait=0; }
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
        if (getenv("M5DBG")&&(rf||pf)) printf("TBMEM rf=%d pf=%d pc=%llu\n", rf, pf, (unsigned long long)dut->if_req_pc);
        if (rf) { pend=true; pend_pc=dut->if_req_pc;
                  wait=(int)(rng()%(max_lat+1)); }
        if (pf) out_valid=false;
        if (pend && wait>0) --wait;
    }
};
static Imem imem;

static std::vector<u32> load_hexf(const std::string& f) {
    std::vector<u32> v; std::ifstream in(f); std::string s;
    while (in >> s) v.push_back(std::stoul(s,nullptr,16));
    return v;
}
static void load_meta(const std::string& dir, u32& exec, u32& vq, u32& sq,
                      u32& nw) {
    exec=0xFFFFFFFF; vq=16; sq=24; nw=1;
    std::ifstream f(dir+"/meta.txt"); std::string tok;
    while (f >> tok) {
        size_t e = tok.find('=');
        std::string k=tok.substr(0,e), val=tok.substr(e+1);
        if (k=="exec") exec=std::stoul(val,nullptr,16);
        else if (k=="vgpr_req") vq=std::stoul(val);
        else if (k=="sgpr_req") sq=std::stoul(val);
        else if (k=="n_wf") nw=std::stoul(val);
    }
}
static bool load_words(const std::string& dir) {
    std::ifstream f(dir+"/prog.words.hex"); if(!f) return false;
    std::string s; imem.mem.clear();
    while (f>>s) imem.mem.push_back(std::stoull(s,nullptr,16));
    return !imem.mem.empty();
}
static void load_vgprinit(const std::string& dir,
                          std::vector<std::tuple<unsigned,unsigned,u32>>& v) {
    std::ifstream f(dir+"/vgpr.hex"); if(!f) return;
    std::string a,l,d;
    while (f >> a >> l >> d)
        v.emplace_back(std::stoul(a), std::stoul(l), std::stoul(d,nullptr,16));
}

struct DoneRec { u32 slot; u32 retired; u32 fault; u32 code; u64 pc; };
static std::vector<DoneRec> dones;

static void launch_wf(u32 sl, u64 cw, u32 ex, u32 vq, u32 sq) {
    dut->wf_launch_valid=1; dut->wf_launch_slot=sl;
    dut->wf_entry_pc=0; dut->wf_code_words=cw; dut->wf_wg_x=0;
    dut->wf_exec_mask=ex; dut->wf_vgpr_req=vq; dut->wf_sgpr_req=sq;
    int guard=0;
    while (!dut->wf_launch_ready && ++guard<100) { dut->clk=0; dut->eval();
                                              dut->clk=1; dut->eval(); }
    if (getenv("M5DBG")) { dut->eval();
        printf("TB launch sl=%u ready=%d guard=%d alloc=%b st1_raw=%u\n", sl,
        (int)dut->wf_launch_ready, guard,
        (unsigned)dut->dbg_allocated, (unsigned)dut->dbg_state); }
    dut->clk=0; dut->eval(); dut->clk=1; dut->eval();
    dut->wf_launch_valid=0; dut->clk=0; dut->eval();
}

static std::ofstream fs_ev;                 // unified event stream (wid-tagged)
static std::ofstream fs_m;                  // mask events
static int total_fails = 0;

static const char* kind_name(unsigned k) {
    static const char* N[16] = {"CBRANCH_IF","RECONV","LOOP_BEGIN","LOOP_END",
        "BREAK","CONTINUE","PUSHM","POPM","SETM","ANDM","ORM","XORM",
        "RET_KERNEL_WF","r13","r14","r15"};
    return N[k & 0xF];
}

static long dbg_ev_cyc = 0;
static void capture_events() {
    if (getenv("M5DBG")) {
        printf("TB cyc=%ld sV=%d vV=%d sW=%u vW=%u mV=%d\n", dbg_ev_cyc,
            (int)dut->trace_s_valid,(int)dut->trace_v_valid,
            (unsigned)dut->trace_s_wfid,(unsigned)dut->trace_v_wfid,
            (int)dut->trace_m_valid);
    }
    dbg_ev_cyc++;
    if (dut->trace_s_valid || dut->trace_v_valid) {
        u32 wid  = dut->trace_s_valid ? dut->trace_s_wfid : dut->trace_v_wfid;
        u64 pc   = dut->trace_s_valid ? dut->trace_s_pc   : dut->trace_v_pc;
        u64 insn = dut->trace_s_valid ? dut->trace_s_insn : dut->trace_v_insn;
        u32 we   = dut->trace_s_valid ? (dut->trace_s_sgpr_we&1u) : 0u;
        u32 ad   = dut->trace_s_valid ? dut->trace_s_sgpr_addr : 0u;
        u32 dt   = dut->trace_s_valid ? dut->trace_s_sgpr_wdata : 0u;
        u32 ex   = dut->trace_s_valid ? dut->trace_s_exec : dut->trace_v_exec_mask;
        if (!we) { ad = 0; dt = 0; }   // non-writing events carry no data
        char L[160];
        snprintf(L,sizeof L,"%u %llx %016llx %x %02x %08x %08x",
            wid,(unsigned long long)pc,(unsigned long long)insn,we,ad,dt,ex);
        fs_ev << L << "\n";
    }
    if (dut->sched_issue_valid &&
        dut->sched_issue_pipe==2 /*CONTROL*/) {
        u64 ins = dut->sched_issue_insn;
        u32 cc = (u32)(ins>>20)&0xF;
        u32 opc= (u32)(ins>>52)&0xFFF;
        dut->dbg_pred_addr = cc; dut->eval();
        printf("TBCTRL pc=%llu op=%03x cond=%u P=%08x\n",
            (unsigned long long)dut->sched_issue_pc, opc, cc,
            (unsigned)dut->dbg_pred_data);
    }
    if (dut->trace_m_valid && dut->trace_m_wfid==0) {
        dut->dbg_wf_sel=0; dut->dbg_pred_addr=1; dut->eval();
        printf("TBPRE pre-P1=%08x kind=%u\n",
            (unsigned)dut->dbg_pred_data,(unsigned)dut->trace_m_kind);
    }
    if (dut->trace_v_valid && dut->trace_v_pred_we) {
        printf("TBPW w=%u addr=%u val=%08x\n",(unsigned)dut->trace_v_wfid,
            (unsigned)dut->trace_v_pred_addr,(unsigned)dut->trace_v_pred_value);
    }
    if (dut->trace_m_valid) {
        unsigned flt = dut->trace_m_fault & 1u;
        char L[200];
        if (flt)
            snprintf(L,sizeof L,"w=%u k=FAULT pc=%llx ft=%u pu=%u po=%u f=%02x",
                (unsigned)dut->trace_m_wfid,
                (unsigned long long)dut->trace_m_pc,
                0u,
                (unsigned)(dut->trace_m_push&1u),
                (unsigned)(dut->trace_m_pop&1u),
                (unsigned)dut->trace_m_fcode);
        else
            snprintf(L,sizeof L,"w=%u k=%s pc=%llx ft=%u pu=%u po=%u f=%02x",
                (unsigned)dut->trace_m_wfid,
                kind_name(dut->trace_m_kind),
                (unsigned long long)dut->trace_m_pc,
                (unsigned)dut->trace_m_ftype,
                (unsigned)(dut->trace_m_push&1u),
                (unsigned)(dut->trace_m_pop&1u),
                0u);
        fs_m << L << "\n";
    }
}

static std::string state_dump_slot(u32 slot, u32 sgpr_n, u32 vgpr_n) {
    std::ostringstream o;
    char B[16]; bool first;
    dut->dbg_wf_sel = slot;
    o << "SGPR "; first=true;
    for (u32 i=0;i<sgpr_n;i++){ dut->dbg_sgpr_addr=i; dut->eval();
        snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_sgpr_data);
        if(!first) o << " "; o << B; first=false; }
    o << "\nPRED "; first=true;
    for (int i=0;i<15;i++){ dut->dbg_pred_addr=i; dut->eval();
        snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_pred_data);
        if(!first) o << " "; o << B; first=false; }
    dut->eval();
    snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_exec_data); o << "\nEXEC " << B;
    snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_live_data); o << "\nLIVE " << B;
    dut->dbg_mc_slot = slot; dut->eval();
    snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_mc_sp); o << "\nSP " << B;
    o << "\n";
    for (u32 v=0;v<vgpr_n;v++) {
        o << "VGPR " << std::hex << std::setw(2) << std::setfill('0') << v << " ";
        bool fw=true;
        for (int ln=0;ln<32;ln++){
            dut->dbg_vgpr_addr=v; dut->dbg_vgpr_lane=ln; dut->eval();
            snprintf(B,sizeof B,"%08x",(unsigned)dut->dbg_vgpr_data);
            if(!fw) o << " "; o << B; fw=false;
        }
        o << "\n" << std::dec;
    }
    return o.str();
}

static int compare_files(const std::string& a, const std::string& b,
                         const char* what, int maxshow=3) {
    std::ifstream fa(a), fb(b);
    if (!fa.good() ^ !fb.good()) { printf("MISSING %s\n", what); return 1; }
    std::string la, lb; int line=0; int bad=0;
    while (true) {
        bool ga=(bool)getline(fa,la), gb=(bool)getline(fb,lb);
        if (!ga && !gb) break;
        ++line;
        if (!ga||!gb||la!=lb) {
            if (bad<maxshow) printf("MISMATCH %s line %d\n  A: %s\n  B: %s\n",
                                    what,line,la.c_str(),lb.c_str());
            bad++;
        }
    }
    return bad;
}

static long run_until(std::vector<bool>& done, long cap) {
    long cyc=0; size_t ndone=0;
    while (cyc++ < cap) {
        imem.pre(dut->if_req_valid,dut->if_req_pc,dut->if_req_ready,
                 dut->if_rsp_valid,dut->if_rsp_insn,dut->if_rsp_error);
        dut->clk=0; dut->eval();
        bool rf=!dut->rst&&dut->if_req_valid&&dut->if_req_ready;
        bool pf=!dut->rst&&dut->if_rsp_valid&&dut->if_rsp_ready;
        dut->clk=1; dut->eval();
        imem.post(rf,pf);
        capture_events();
        if (getenv("M5DBG") && cyc%50==0)
            printf("TBST c=%ld pend=%d ppc=%llu wait=%d ov=%d\n",cyc,
                (int)imem.pend,(unsigned long long)imem.pend_pc,imem.wait,
                (int)imem.out_valid);
        if (dut->wf_completion_valid && dut->wf_completion_ready) {
            u32 sl=dut->wf_completion_slot;
            if (sl<done.size() && !done[sl]) {
                done[sl]=true; ++ndone;
                dut->dbg_wf_sel = sl; dut->eval();
                u32 lv = (unsigned)dut->dbg_live_data;
                dones.push_back({sl,
                    (unsigned)dut->wf_completion_retired_count,
                    (unsigned)(dut->wf_completion_fault?1u:0u),
                    (unsigned)dut->wf_completion_fault_code,
                    ((unsigned long long)lv << 32) |
                     (unsigned long long)dut->wf_completion_pc});
                dut->wf_completion_ready=0; tick(); dut->wf_completion_ready=1;
            }
        }
        if (ndone==done.size()) break;
    }
    return (ndone==done.size()) ? cyc : -1;
}

static void do_preloads_dir(const std::string& dir, u32 slot,
                            const std::vector<std::tuple<unsigned,unsigned,u32>>& vg) {
    auto sg = load_hexf("/tmp/opencode/empty.txt");
    (void)sg;
    std::ifstream sf(dir+"/sgpr.hex");
    std::string tokw;
    u32 addr=0;
    if (sf.good()) {
        while (sf >> tokw) {
            dut->sgpr_init_valid=1; dut->sgpr_init_slot=slot;
            dut->sgpr_init_addr=addr++;
            dut->sgpr_init_data=std::stoul(tokw,nullptr,16);
            do { tick(); } while(!dut->sgpr_init_ready);
        }
    }
    dut->sgpr_init_valid=0;
    auto preds = load_hexf(dir+"/pred.hex");
    for (int i=0;i<15;i++) {
        dut->pred_init_valid=1; dut->pred_init_slot=slot;
        dut->pred_init_addr=i;
        dut->pred_init_data=(i<(int)preds.size())?preds[i]:0;
        do { tick(); } while(!dut->pred_init_ready);
    }
    dut->pred_init_valid=0;
    for (auto& t : vg) {
        dut->vgpr_init_valid=1; dut->vgpr_init_slot=slot;
        dut->vgpr_init_addr=std::get<0>(t);
        dut->vgpr_init_lane=std::get<1>(t);
        dut->vgpr_init_data=std::get<2>(t);
        do { tick(); } while(!dut->vgpr_init_ready);
    }
    dut->vgpr_init_valid=0;
}

// ------------------------------- modes --------------------------------------
static int run_common(const std::string& dir, const std::string& tag,
                      u32 slots_to_use, u32 n_wf, u32 exec, u32 vq, u32 sq,
                      const std::vector<u32>& exec_over, unsigned seed,
                      int stall, int lat) {
    hard_reset(); imem.reset(seed,stall,lat);
    std::vector<std::tuple<unsigned,unsigned,u32>> vg; load_vgprinit(dir,vg);
    // preloads happen before any launch (bootstrap channels are global-muxed
    // per slot inside do_preloads_dir)
    for (u32 w = 0; w < slots_to_use; w++) do_preloads_dir(dir, w, vg);

    fs_ev.open(dir+"/rtl"+tag+".ev");
    fs_m.open(dir+"/rtl"+tag+".masktrace");

    // interleaved launch + run: launches issue as their slot frees; the same
    // cycle loop services completions and captures events.
    std::vector<bool> done(slots_to_use,false);
    long cyc=0; size_t ndone=0; u32 next_launch=0;
    while (cyc++ < 400000) {
        if (next_launch < slots_to_use && dut->wf_launch_ready) {
            u32 w = next_launch++;
            u32 em = (w < exec_over.size()) ? exec_over[w] : exec;
            dut->wf_launch_valid=1; dut->wf_launch_slot=w;
            dut->wf_entry_pc=0; dut->wf_code_words=imem.mem.size();
            dut->wf_wg_x=0; dut->wf_exec_mask=em;
            dut->wf_vgpr_req=vq; dut->wf_sgpr_req=sq;
        }
        imem.pre(dut->if_req_valid,dut->if_req_pc,dut->if_req_ready,
                 dut->if_rsp_valid,dut->if_rsp_insn,dut->if_rsp_error);
        dut->clk=0; dut->eval();
        bool rf=!dut->rst&&dut->if_req_valid&&dut->if_req_ready;
        bool pf=!dut->rst&&dut->if_rsp_valid&&dut->if_rsp_ready;
        dut->clk=1; dut->eval();
        if (next_launch>0) { dut->wf_launch_valid=0; }
        imem.post(rf,pf);
        capture_events();
        if (dut->wf_completion_valid && dut->wf_completion_ready) {
            u32 sl=dut->wf_completion_slot;
            if (sl<done.size() && !done[sl]) {
                done[sl]=true; ++ndone;
                dut->dbg_wf_sel = sl; dut->eval();
                u32 lv=(unsigned)dut->dbg_live_data;
                dones.push_back({sl,
                    (unsigned)dut->wf_completion_retired_count,
                    (unsigned)(dut->wf_completion_fault?1u:0u),
                    (unsigned)dut->wf_completion_fault_code,
                    ((unsigned long long)lv<<32) |
                     (unsigned long long)dut->wf_completion_pc});
                dut->wf_completion_ready=0; tick(); dut->wf_completion_ready=1;
            }
        }
        if (ndone==done.size() && next_launch>=slots_to_use) break;
    }
    fs_ev.close(); fs_m.close();
    if (!(ndone==done.size() && next_launch>=slots_to_use)) {
        printf("cycle cap exceeded (%s)\n", tag.c_str()); return -1; }
    // per-slot final states (registers persist post-completion)
    for (u32 w = 0; w < slots_to_use; w++) {
        std::ofstream sf(dir+"/rtl"+tag+".state"+std::to_string(w));
        sf << state_dump_slot(w,64,32); sf.close();
    }

    // split RTL events per wf
    {
        std::ifstream all(dir+"/rtl"+tag+".ev");
        std::vector<std::ofstream*> per(n_wf,nullptr);
        for (u32 w=0;w<n_wf;w++)
            per[w]=new std::ofstream(dir+"/rtl"+tag+".wf"+std::to_string(w)+".ev");
        std::string l;
        while (getline(all,l)) {
            if (l.empty()) continue;
            u32 w = std::stoul(l)&0xF;
            if (w<n_wf && per[w]) *per[w] << l.substr(l.find(' ')+1) << "\n";
        }
        for (auto p:per) delete p;
    }
    return 0;
}

static int mode_diff(const std::string& dir, unsigned seed, int stall,
                     int lat) {
    if (!load_words(dir)) { printf("missing words\n"); return 1; }
    u32 exec,vq,sq,nw; load_meta(dir,exec,vq,sq,nw);
    int rc = run_common(dir,"",1,nw,exec,vq,sq,{},seed,stall,lat);
    if (rc) return rc;
    int bad = 0;
    bad += compare_files(dir+"/golden.wf0.ev", dir+"/rtl.wf0.ev","events");
    bad += compare_files(dir+"/golden.masktrace", dir+"/rtl.masktrace",
                         "mask-events");
    bad += compare_files(dir+"/golden.wf0.state", dir+"/rtl.state0","state");
    // completion record (full line including live)
    {
        std::ifstream gf(dir+"/golden.wf0.done");
        std::string gl; getline(gf,gl);
        gl = gl.substr(gl.find("DONE"));   // strip slot prefix
        if (!dones.empty()) {
            char E[160];
            snprintf(E,sizeof E,
                "DONE retired=%u fault=%u code=%02x pc=%llx live=%08x",
                dones[0].retired,dones[0].fault,dones[0].code,
                (unsigned long long)(dones[0].pc & 0xFFFFFFFFull),
                (unsigned)(dones[0].pc >> 32));
            if (gl.rfind(std::string(E), 0) != 0) {
                printf("DONE mismatch:\n G:%s\n R:%s\n", gl.c_str(), E);
                bad++;
            }
        } else { printf("no completion\n"); bad++; }
    }
    printf("[diff %s] %s (%d mismatches)\n", dir.c_str(),
           bad?"FAIL":"PASS", bad);
    return bad?1:0;
}

static int mode_mdiff(const std::string& dir, u32 slots, unsigned seed,
                      int stall, int lat, std::vector<u32>& exec_over) {
    if (!load_words(dir)) { printf("missing words\n"); return 1; }
    u32 exec,vq,sq,nw; load_meta(dir,exec,vq,sq,nw);
    if (slots > 8) slots = 8;
    // per-slot exec overrides from golden side take precedence
    {
        std::ifstream ef(dir+"/execs.txt"); std::string t;
        while (ef >> t && (u32)exec_over.size() < 8)
            exec_over.push_back(std::stoul(t,nullptr,16));
    }
    int rc = run_common(dir,"_m",slots,nw,exec,vq,sq,exec_over,seed,stall,lat);
    if (rc) return rc;
    int bad = 0;
    for (u32 w = 0; w < nw && w < slots; w++)
        bad += compare_files(dir+"/golden.wf"+std::to_string(w)+".ev",
                             dir+"/rtl_m.wf"+std::to_string(w)+".ev",
                             ("wf"+std::to_string(w)+" events").c_str());
    // completions: match by slot
    std::vector<std::string> gdone;
    for (u32 w = 0; w < slots; w++) {
        std::ifstream gf(dir+"/golden.wf"+std::to_string(w)+".done");
        std::string gl; if (getline(gf,gl)) gdone.push_back(gl);
        else gdone.push_back("");
    }
    if (dones.size() != gdone.size()) {
        printf("completion count mismatch %zu vs %zu\n",dones.size(),gdone.size());
        bad++;
    } else {
        for (auto& d : dones) {
            std::string expect;
            for (auto& g : gdone) {
                if (g.size()<5) continue;
                size_t sp2=g.find(' ');
                u32 gw = std::stoul(g.substr(0,sp2));
                if (gw == d.slot) { expect=g.substr(sp2+1); break; }
            }
            if (expect.empty()) { printf("no golden done wf%u\n",d.slot); bad++; continue; }
            char E[200];
            snprintf(E,sizeof E,
                "DONE retired=%u fault=%u code=%02x pc=%llx live=%08x",
                d.retired,d.fault,d.code,
                (unsigned long long)(d.pc & 0xFFFFFFFFull),
                (unsigned)(d.pc >> 32));
            if (std::string(E) != expect.substr(0, strlen(E))) {
                printf("DONE wf%u mismatch:\n G:%s\n R:%s\n",
                       d.slot,expect.c_str(),E);
                bad++;
            }
        }
    }
    // final states per slot
    for (u32 w = 0; w < slots; w++) {
        std::ofstream sf(dir+"/rtl_m.state"+std::to_string(w));
        sf << state_dump_slot(w,64,32); sf.close();
        bad += compare_files(dir+"/golden.wf"+std::to_string(w)+".state",
                             dir+"/rtl_m.state"+std::to_string(w),
                             ("state"+std::to_string(w)).c_str());
    }
    printf("[mdiff %s x%u] %s (%d mismatches)\n", dir.c_str(), slots,
           bad?"FAIL":"PASS", bad);
    return bad?1:0;
}

static int mode_resetstress(const std::string& dir) {
    if (!load_words(dir)) return 1;
    u32 exec,vq,sq,nw; load_meta(dir,exec,vq,sq,nw);
    std::vector<std::tuple<unsigned,unsigned,u32>> vg; load_vgprinit(dir,vg);
    int fails=0;
    for (int k=3;k<=42;k+=3) {
        hard_reset(); imem.reset(200+k,15,2);
        do_preloads_dir(dir,0,vg);
        fs_ev.open(dir+"/rtl_rs.ev"); fs_m.open(dir+"/rtl_rs.masktrace");
        launch_wf(0, imem.mem.size(), exec, vq, sq);
        long cyc=0; bool did=false;
        std::vector<std::string> post;
        std::vector<bool> done(1,false);
        while (cyc++ < 60000) {
            imem.pre(dut->if_req_valid,dut->if_req_pc,dut->if_req_ready,
                     dut->if_rsp_valid,dut->if_rsp_insn,dut->if_rsp_error);
            if (cyc==k && !did) dut->rst=1;
            dut->clk=0; dut->eval();
            bool rfq=!dut->rst&&dut->if_req_valid&&dut->if_req_ready;
            bool pf=!dut->rst&&dut->if_rsp_valid&&dut->if_rsp_ready;
            dut->clk=1; dut->eval();
            if (dut->rst) imem.hard_clear(); else imem.post(rfq,pf);
            if (cyc==k && !did) {
                dut->rst=0; did=true; imem.hard_clear();
                if (dut->wf_completion_valid){printf("GHOST COMPLETION k=%d\n",k);
                    fails++; break;}
                launch_wf(0, imem.mem.size(), exec, vq, sq);
                continue;
            }
            if (did) capture_events();
            if (dut->wf_completion_valid && dut->wf_completion_ready &&
                !done[0]) {
                done[0]=true;
                // completion + FINAL STATE equality vs golden (directive §158)
                char D[200];
                snprintf(D,sizeof D,
                    "DONE retired=%u fault=%u code=%02x",
                    (unsigned)dut->wf_completion_retired_count,
                    (unsigned)(dut->wf_completion_fault?1u:0u),
                    (unsigned)dut->wf_completion_fault_code);
                std::ifstream gf(dir+"/golden.wf0.done");
                std::string gl; getline(gf,gl);
                gl = gl.substr(gl.find("DONE"));
                bool okd = gl.rfind(std::string(D),0)==0;
                std::ofstream sf(dir+"/rtl_rs.state");
                sf << state_dump_slot(0,64,32); sf.close();
                int bs = compare_files(dir+"/golden.wf0.state",
                                      dir+"/rtl_rs.state","rs-state",1);
                if (!okd || bs) { printf("RESET k=%d mismatch\n",k); fails++; }
                dut->wf_completion_ready=0; tick(); dut->wf_completion_ready=1;
                break;
            }
        }
        fs_ev.close(); fs_m.close();
        if (!done[0]) { printf("RESET k=%d no completion\n",k); fails++; }
    }
    printf("reset stress: %s (%d injection points)\n",
           fails?"FAIL":"clean", 14);
    return fails?1:0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr,"usage: tb diff|mdiff|resetstress <dir> "
        "[seed] [stall%%] [lat] [slots] [ex0 hex ...]\n"); return 2; }
    dut = new Vscigpu_m5_top;
    std::string mode=argv[1];
    unsigned seed=(argc>3)?(unsigned)atoi(argv[3]):1;
    int stall=(argc>4)?atoi(argv[4]):12;
    int lat=(argc>5)?atoi(argv[5]):2;
    int rc;
    if (mode=="diff") rc=mode_diff(argv[2],seed,stall,lat);
    else if (mode=="resetstress") rc=mode_resetstress(argv[2]);
    else if (mode=="mdiff") {
        u32 slots=(argc>6)?(u32)atoi(argv[6]):2;
        std::vector<u32> eo;
        for (int i=7;i<argc;i++) eo.push_back(std::stoul(argv[i],nullptr,16));
        rc=mode_mdiff(argv[2],slots,seed,stall,lat,eo);
    }
    else { fprintf(stderr,"unknown mode\n"); rc=2; }
    delete dut;
    return rc||total_fails;
}
