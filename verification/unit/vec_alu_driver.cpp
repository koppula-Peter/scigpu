// M3 vector-ALU unit driver (directive §72): boundary + randomized vectors,
// per-lane checks against a C++ reference. Exit nonzero on failure.
#include <verilated.h>
#include "Vscigpu_vec_alu_tb.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

using u32 = uint32_t;
static Vscigpu_vec_alu_tb* d;
static int fails = 0;

static u32 ref(u32 op, u32 a, u32 b) {
    switch (op) {
        case 0: return b;                                  // PASS_B
        case 1: return a + b;                              // ADD
        case 2: return a - b;                              // SUB
        case 3: return a & b; case 4: return a | b;
        case 5: return a ^ b; case 6: return ~a;           // NOT
        case 7: return a << (b & 31);                      // SHL
        case 8: return a >> (b & 31);                      // SHR
        case 9: { int32_t s=a; return (u32)(s >> (b&31)); }// SAR
        case 10: return a * b;                             // MUL (low 32)
    }
    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vscigpu_vec_alu_tb;

    const u32 bounds[] = {0,1,0xFFFFFFFFu,0x80000000u,0x7FFFFFFFu};
    const struct{const char* nm; u32 op;} ops[] = {
        {"PASS_B",0},{"ADD",1},{"SUB",2},{"AND",3},{"OR",4},{"XOR",5},
        {"NOT",6},{"SHL",7},{"SHR",8},{"SAR",9},{"MUL",10}};
    long long checked = 0;

    // boundaries x bounds x ops
    for (auto A : bounds) for (auto B : bounds) for (auto& o : ops)
        for (int lane = 0; lane < 4; lane++) {
            u32 a[4]={A,A,A,A}, b[4]={B,B,B,B};
            d->op=o.op;
            d->a0=a[0];d->a1=a[1];d->a2=a[2];d->a3=a[3];
            d->b0=b[0];d->b1=b[1];d->b2=b[2];d->b3=b[3];
            d->eval();
            u32 ys[4]={d->y0,d->y1,d->y2,d->y3};
            u32 e = ref(o.op,A,B);
            if (ys[lane]!=e){ printf("VEC-ALU FAIL %s(%08x,%08x) lane%d:"
                " %08x != %08x\n",o.nm,A,B,lane,ys[lane],e); ++fails; }
            ++checked;
        }

    // shift-amount masking 0..63 on SAR with negative input
    for (u32 sh=0; sh<=63; ++sh) {
        d->op=9; d->a0=0xF1234567u; d->b0=sh; d->eval();
        int32_t s=(int32_t)0xF1234567u;
        if (d->y0!=(u32)(s>>(sh&31))){ printf("VEC-ALU SAR mask %u\n",sh); ++fails; }
        ++checked;
    }

    // randomized: 20000 vectors × all lanes
    std::mt19937 rng(31337);
    for (int i=0;i<20000;i++){
        u32 a=rng(), b=rng(); auto& o=ops[rng()%11];
        d->op=o.op; d->a0=a;d->a1=a^0xFFFF;d->a2=~a;d->a3=a+1;
        d->b0=b;d->b1=b^0xFFFF;d->b2=~b;d->b3=b+7;
        d->eval();
        u32 as[4]={a,a^0xFFFFu,~a,a+1}, bs[4]={b,b^0xFFFFu,~b,b+7};
        u32 ys[4]={d->y0,d->y1,d->y2,d->y3};
        for (int l=0;l<4;l++){
            u32 e=ref(o.op,as[l],bs[l]);
            if (ys[l]!=e){ printf("VEC-ALU RAND %s lane%d\n",o.nm,l); ++fails; }
            ++checked;
        }
    }
    delete d;
    printf("vec-alu checks=%lld fails=%d\n", checked, fails);
    if (!fails) printf("M3 UNIT RESULT: PASS\n");
    return fails ? 1 : 0;
}
