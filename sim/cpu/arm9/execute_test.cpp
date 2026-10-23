// SPDX-License-Identifier: GPL-3.0-or-later
#include "Varm9_execute.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <utility>

#ifndef PRE_SHIFTED
#define PRE_SHIFTED 0
#endif

// Deliberately iterative reference, independent of the RTL barrel network.
static std::pair<uint32_t, bool> shift(uint32_t v, unsigned n, unsigned type,
                                      bool reg, bool c) {
    if (!reg && n == 0 && type) {
        if (type == 3) return {(uint32_t(c) << 31) | (v >> 1), bool(v & 1)};
        n = 32;
    }
    for (unsigned j = 0; j < n; ++j) {
        const bool bit = type == 0 ? (v >> 31) : (v & 1);
        if (type == 0) v <<= 1;
        if (type == 1) v >>= 1;
        if (type == 2) v = (v >> 1) | (v & 0x80000000u);
        if (type == 3) v = (v >> 1) | (uint32_t(bit) << 31);
        c = bit;
    }
    return {v, c};
}

static bool condition(unsigned cc, unsigned f) {
    const bool n=f&8, z=f&4, c=f&2, v=f&1;
    const bool cases[] = {z,!z,c,!c,n,!n,v,!v,c&&!z,!c||z,n==v,n!=v,
                          !z&&(n==v),z||(n!=v),true,false};
    return cases[cc];
}

static uint64_t checks;
static void verify(Varm9_execute& t) {
    t.eval();
    std::array<uint32_t,4> x;
    bool blocked=false;
    for (unsigned s=0;s<4;++s) {
        x[s]=t.i_value[s];
        if (!(t.i_used & (1u<<s))) continue;
        for (unsigned p=0;p<3;++p) {
            if ((t.i_write_valid & (1u<<p)) &&
                ((t.i_tag>>(6*s))&63)==((t.i_write_tag>>(6*p))&63)) {
                x[s]=t.i_write_value[p];
                blocked |= !(t.i_write_ready & (1u<<p));
                break;
            }
        }
    }
    auto [b,sc] = shift(x[1], t.i_shift_register ? (x[2]&255) : t.i_shift_amount,
                        t.i_shift_type,t.i_shift_register,t.i_flags&2);
    if (t.i_immediate || PRE_SHIFTED) { b=x[1]; sc=t.i_shift_carry; }
    const uint32_t a=x[0];
    const int64_t sa=int32_t(a), sb=int32_t(b);
    const unsigned ci=bool(t.i_flags&2);
    uint64_t u=0;
    int64_t signed_result=0;
    uint32_t r=0;
    bool arithmetic=false;
    switch(t.i_op) {
        case 0: case 8: r=a&b; break;
        case 1: case 9: r=a^b; break;
        case 2: case 10: u=uint64_t(a)+uint32_t(~b)+1; signed_result=sa-sb; arithmetic=true; break;
        case 3: u=uint64_t(b)+uint32_t(~a)+1; signed_result=sb-sa; arithmetic=true; break;
        case 4: case 11: u=uint64_t(a)+b; signed_result=sa+sb; arithmetic=true; break;
        case 5: u=uint64_t(a)+b+ci; signed_result=sa+sb+ci; arithmetic=true; break;
        case 6: u=uint64_t(a)+uint32_t(~b)+ci; signed_result=sa-sb-!ci; arithmetic=true; break;
        case 7: u=uint64_t(b)+uint32_t(~a)+ci; signed_result=sb-sa-!ci; arithmetic=true; break;
        case 12: r=a|b; break;
        case 13: r=b; break;
        case 14: r=a&~b; break;
        case 15: r=~b; break;
    }
    bool carry=sc, overflow=t.i_flags&1;
    if(arithmetic) {
        r=uint32_t(u); carry=u>>32;
        overflow=signed_result>INT32_MAX || signed_result<INT32_MIN;
    }
    const bool pass=condition(t.i_condition,t.i_flags);
    const bool wait=t.i_valid && pass && blocked;
    const bool execute=t.i_valid && pass && !blocked;
    const bool test=t.i_op>=8 && t.i_op<=11;
    const bool wf=execute && (test || t.i_set_flags);
    const unsigned f=wf ? ((r>>31)*8 + (!r)*4 + carry*2 + overflow) : t.i_flags;
    if(t.o_result!=r || t.o_flags!=f || t.o_condition_pass!=pass ||
       t.o_wait!=wait || t.o_execute!=execute || t.o_write_result!=(execute&&!test) ||
       t.o_write_flags!=wf || t.o_store_data!=x[3] ||
       t.o_branch_target!=uint32_t(t.i_pc8+t.i_branch_offset)) {
        std::fprintf(stderr,"FAIL check %llu op=%x a=%08x b=%08x flags=%x: result %08x/%08x flags %x/%x wait %u/%u\n",
          (unsigned long long)checks,t.i_op,a,b,t.i_flags,t.o_result,r,t.o_flags,f,t.o_wait,wait);
        std::exit(1);
    }
    ++checks;
}

int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    Varm9_execute t;
    const std::array<uint32_t,8> values={0,1,0x7fffffff,0x80000000,0xffffffff,
                                        0xaaaaaaaa,0x55555555,0x87654321};
    t.i_valid=1; t.i_condition=14; t.i_op=13; t.i_set_flags=1;
    t.i_used=0; t.i_write_valid=0; t.i_immediate=0;
    for(auto v:values) for(unsigned type=0;type<4;++type)
      for(unsigned reg=0;reg<2;++reg) for(unsigned c=0;c<2;++c)
       for(unsigned n=0;n<(reg?256:32);++n) {
        t.i_value[1]=v; t.i_value[2]=n; t.i_shift_amount=n&31;
        t.i_shift_register=reg; t.i_shift_type=type; t.i_flags=c*2;
        verify(t);
    }
    t.i_immediate=1;
    for(auto a:values) for(auto b:values) for(unsigned op=0;op<16;++op)
      for(unsigned f=0;f<16;++f) {
        t.i_value[0]=a; t.i_value[1]=b; t.i_op=op; t.i_flags=f;
        t.i_shift_carry=bool(f&2); verify(t);
    }
    // Every condition with all NZCV combinations, pending operands and bubbles.
    t.i_used=1; t.i_tag=0; t.i_write_tag=0; t.i_write_valid=7; t.i_write_ready=6;
    for(unsigned v=0;v<2;++v) for(unsigned c=0;c<16;++c) for(unsigned f=0;f<16;++f) {
        t.i_valid=v; t.i_condition=c; t.i_flags=f; verify(t);
    }
    // Exercise every producer/source, alias priority and ready combination.
    t.i_valid=1; t.i_condition=14; t.i_flags=0; t.i_op=4;
    t.i_write_value[0]=0x11111111; t.i_write_value[1]=0x22222222; t.i_write_value[2]=0x33333333;
    for(unsigned s=0;s<4;++s) for(unsigned tag=0;tag<40;++tag)
      for(unsigned valid=0;valid<8;++valid) for(unsigned ready=0;ready<8;++ready) {
        t.i_tag=tag<<(s*6); t.i_used=1<<s;
        t.i_write_tag=tag|(tag<<6)|(tag<<12);
        t.i_write_valid=valid; t.i_write_ready=ready; verify(t);
    }
    std::mt19937 random(0x9257);
    for(unsigned i=0;i<100000;++i) {
        t.i_valid=random()&1; t.i_condition=random()&15; t.i_op=random()&15;
        t.i_set_flags=random()&1; t.i_flags=random()&15; t.i_tag=0; t.i_write_tag=0;
        for(unsigned s=0;s<4;++s) {t.i_value[s]=random(); t.i_tag|=(random()%40)<<(s*6);}
        for(unsigned p=0;p<3;++p) {t.i_write_value[p]=random(); t.i_write_tag|=(random()%40)<<(p*6);}
        t.i_used=random()&15; t.i_write_valid=random()&7; t.i_write_ready=random()&7;
        t.i_shift_type=random()&3; t.i_shift_amount=random()&31; t.i_shift_register=random()&1;
        t.i_immediate=random()&1; t.i_shift_carry=random()&1;
        t.i_pc8=random(); t.i_branch_offset=random(); verify(t);
    }
    t.final();
    std::printf("ARM9 execute PRE_SHIFTED=%d: %llu checks passed\n",PRE_SHIFTED,(unsigned long long)checks);
}
