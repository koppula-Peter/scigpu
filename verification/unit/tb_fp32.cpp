// M7 FP32 ALU unit TB: directed IEEE-754 edges + randomized differential
// against host single-precision arithmetic (RN-even reference).
#include <verilated.h>
#include "Vscigpu_fp32_alu.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
using u32 = uint32_t;

static inline u32 f2b(float f){ u32 u; std::memcpy(&u,&f,4); return u; }
static inline float b2f(u32 u){ float f; std::memcpy(&f,&u,4); return f; }

static Vscigpu_fp32_alu* dut;
static int fails=0, total=0;

static u32 ref_f2i(u32 bits){
    float f=b2f(bits);
    if(std::isnan(f)) return 0x7FFFFFFF;
    if(f>=2147483648.0f || std::isinf(f)) return 0x7FFFFFFF;
    if(f<=-2147483648.0f) return 0x80000000;
    return (u32)(int32_t)f;
}

static void tick(u32 op, const u32* A, const u32* B, const u32* exp, const char* tag){
    dut->op=op;
    for(int l=0;l<8;l++){ dut->a[l]=A[l]; dut->b[l]=B[l]; }
    dut->eval();
    for(int l=0;l<8;l++){
        total++;
        u32 got=dut->y[l];
        if(got!=exp[l]){
            fails++;
            if(fails<=20)
                printf("[FAIL] %s lane%d op%u a=%08x b=%08x got=%08x exp=%08x\n",
                       tag,l,op,A[l],B[l],got,exp[l]);
        }
    }
}

static void one(u32 op,u32 a,u32 b,u32 e,const char* tag){
    u32 A[8],B[8],E[8];
    for(int l=0;l<8;l++){A[l]=a;B[l]=b;E[l]=e;}
    tick(op,A,B,E,tag);
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    dut=new Vscigpu_fp32_alu;
    u32 A[8],B[8],E[8];

    // ---- directed: basic values ----
    one(3,0x00000001,0,0x3F800000,"i2f(1)");
    one(3,0x00000002,0,0x40000000,"i2f(2)");
    one(3,0x0000000A,0,0x41200000,"i2f(10)");
    one(3,0x80000000,0,0xCF000000,"i2f(-2^31)");
    one(0,0x3F800000,0x40000000,0x40400000,"fadd(1,2)=3");
    one(0,0x40000000,0x40400000,0x40A00000,"fadd(2,3)=5");
    one(1,0x40400000,0x3F800000,0x40000000,"fsub(3,1)=2");
    one(1,0x40400000,0x40400000,0,"fsub(3,3)=0");
    one(2,0x40400000,0x40A00000,0x41700000,"fmul(3,5)=15");
    one(4,0x3F800000,0,0x00000001,"f2i(1.0)");
    one(4,0xBF800000,0,(u32)-1,"f2i(-1.0)");
    one(4,0xC1700000,0,(u32)-15,"f2i(-15.0)");

    // ---- directed: zeros / signs ----
    one(0,0x00000000,0x00000000,0x00000000,"+0++0");
    one(0,0x80000000,0x80000000,0x80000000,"-0+-0");
    one(0,0x00000000,0x80000000,0x00000000,"+0+-0");
    one(0,0x3F800000,0x80000000,0x3F800000,"1+(-0)");
    one(0,0xBF800000,0x00000000,0xBF800000,"-1+(+0)");
    one(1,0x3F800000,0x3F800000,0x00000000,"1-1=+0");

    // ---- directed: inf / NaN ----
    one(0,0x7F800000,0x7F800000,0x7F800000,"inf+inf");
    one(0,0xFF800000,0x7F800000,0x7FC00000,"-inf+inf=NaN");
    one(0,0x7F800000,0x3F800000,0x7F800000,"inf+1");
    one(1,0x7F800000,0xFF800000,0x7F800000,"inf-(-inf)=+inf");
    one(2,0x7F800000,0x00000000,0x7FC00000,"inf*0=NaN");
    one(2,0x7F800000,0x40000000,0x7F800000,"inf*2");
    one(2,0xFF800000,0xC0000000,0x7F800000,"-inf*-2=+inf");
    one(0,0x7FC00000,0x3F800000,0x7FC00000,"qNaN propagates");

    // ---- directed: rounding ties (RN-even) ----
    // 1 + 2^-24 = tie between 1.0 and nextafter -> even -> 1.0
    one(0,0x3F800000,0x33800000,0x3F800000,"tie-to-even down");
    // 1 + 3*2^-24 rounds up to nextafter(1)
    one(0,0x3F800000,0x34000000,0x3F800001,"round up odd LSB");
    // 2^24 + 1 -> ties to even: 2^24
    one(0,0x4B800000,0x3F800000,0x4B800000,"tie 2^24+1/2 ulp");
    // 2^24 + 2 -> exact, representable
    one(0,0x4B800000,0x40000000,0x4B800001,"exact 2^24+2");

    // ---- directed: subnormals ----
    one(0,0x00000001,0x00000001,0x00000002,"min_sub+min_sub");
    one(2,0x00800000,0x3F000000,0x00400000,"min_norm*0.5=2^-127 sub");
    one(2,0x00000002,0x3F000000,0x00000001,"2sub*0.5=sub");
    one(0,0x007FFFFF,0x00800000,0x00FFFFFF,"max_sub+min_norm");
    one(2,0x00000001,0x40000000,0x00000002,"min_sub*2 exact");
    one(2,0x00000003,0x40000000,0x00000006,"3sub*2 exact");
    one(4,0x00800000,0,0x00000000,"f2i(min_norm)=0");
    one(4,0x80800000,0,0x00000000,"f2i(-min_norm)=0");

    // ---- directed: f2i saturation / extremes ----
    one(4,0x4F000000,0,0x7FFFFFFF,"f2i(2^31)sat");
    one(4,0xCF000000,0,0x80000000,"f2i(-2^31)exact");
    one(4,0x4EFFFFFF,0,0x7FFFFF80,"f2i(2147483520)exact");
    one(4,0xCF000001,0,0x80000000,"f2i(<-2^31)sat");
    one(4,0x3F000000,0,0x00000000,"f2i(0.5)=0");
    one(4,0xBF000000,0,0x00000000,"f2i(-0.5)=0");
    one(4,0xBFC00000,0,(u32)-1,"f2i(-1.5)=-1");

    // ---- directed: same-operand carries / cancellations ----
    one(0,0x3F800000,0x3F800000,0x40000000,"fadd(1,1)=2");
    one(0,0x40000000,0x40000000,0x40800000,"fadd(2,2)=4");
    one(0,0x00800000,0x00800000,0x01000000,"fadd(min_norm,min_norm)");
    one(0,0x33800000,0x33800000,0x34000000,"fadd(tiny,tiny)");
    one(0,0x7F7FFFFF,0x7F7FFFFF,0x7F800000,"fadd(max,max)=inf");
    one(2,0x40400000,0x40400000,0x41100000,"fmul(3,3)=9");
    one(1,0x40000000,0x40000000,0,"fsub(2,2)=+0");
    one(0,0xBF800000,0x3F800000,0,"fadd(-1,+1)=+0");

    // ---- randomized differential vs host ----
    srand(12345);
    for(int it=0;it<30000;it++){
        int mode=it%5;
        u32 op=it%5;
        for(int l=0;l<8;l++){
            u32 ra=(u32(rand())<<16)^rand();
            u32 rb=(u32(rand())<<16)^rand();
            if(mode==0){ ra&=0x41FFFFFF; ra|=0x30000000; rb&=0x41FFFFFF; rb|=0x30000000; } // normals ~1e-9..~1e10
            else if(mode==1){ ra&=0x807FFFFF; rb&=0x807FFFFF; }                            // zero/subnormal band
            else if(mode==2){ ra&=0x47FFFFFF; rb&=0x47FFFFFF; }                            // wide finite
            else if(mode==3){ rb=ra; }                                                     // identical operands (x+x, x-x)
            else { ra=rand(); rb=rand(); }                                                 // full bit space (finite filtered below)
            if(((ra>>23)&0xFF)==0xFF||((rb>>23)&0xFF)==0xFF){ l--; continue; }
            A[l]=ra; B[l]=rb;
            float fa=b2f(ra), fb=b2f(rb);
            switch(op){
                case 0: E[l]=f2b(fa+fb); break;
                case 1: E[l]=f2b(fa-fb); break;
                case 2: E[l]=f2b(fa*fb); break;
                case 3: E[l]=f2b((float)(int32_t)ra); break;
                case 4: E[l]=ref_f2i(ra); break;
            }
        }
        tick(op,A,B,E,op==0?"rnd_fadd":op==1?"rnd_fsub":op==2?"rnd_fmul":op==3?"rnd_i2f":"rnd_f2i");
    }

    printf("FP32 UNIT: %s (%d fails / %d checks)\n",fails?"FAIL":"PASS",fails,total);
    delete dut;
    return fails?1:0;
}
