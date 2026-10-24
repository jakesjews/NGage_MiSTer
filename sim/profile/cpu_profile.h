// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <cassert>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>

namespace cpu_profile {
// Exclusive attribution is a priority classification of sampled evidence,
// not additive causal penalties. Retiring clocks win, then older blocking
// work, then dependencies, then frontend starvation/recovery, then bubbles.
enum Class { Reset, Retired, ThumbContinuation, Exception, DUncached, DWriteThrough,
    DTranslation, DLock, DMiss, DRequest, Serial, Replay, Reservation, Multiply, Shift,
    LoadUse, Dependency, ITlb, IMiss, FetchRedirect, FetchOther, BranchA, BranchD,
    ReturnRepair, SerialRefill, Uop, BlockSequence, Pipeline, Wfi, Classes };
inline constexpr const char *names[]={"reset","retired","thumb_continuation","exception",
    "dc_uncached","dc_write_through","dc_tlb","dc_lock","dc_miss_busy","dc_request_other","serial_cp15",
    "replay","reservation_recovery","dep_multiply","dep_shift","dep_load_use","dep_other",
    "fetch_tlb","fetch_icache","fetch_redirect","fetch_other","branch_a","branch_decode_early",
    "return_pc_repair","serial_refill","structural_uop","structural_block","structural_pipeline","wfi"};
enum Mix { Other, Load, Store, Ldm, Stm, Branch, Mult, Msr, Mrs, Mrc, Mcr, Swp, Swi, Unknown, Mixes };
inline constexpr const char *mix_names[]={"other","load","store","ldm","stm","branch","multiply","msr","mrs","mrc","mcr","swp","swi","unknown"};
struct Sample { uint64_t flags=0; uint32_t decode_pc=0,decode_ins=0,retire_ins=0,target=0;uint8_t stall=0,icache=0,dcache=0; };
struct Counts {
    uint64_t clocks=0;
    std::array<uint64_t,Classes> why{};
    std::array<uint64_t,Mixes> mix{};
    std::array<uint64_t,46> evidence{};
    std::array<uint64_t,8> stall{},icache{};
    std::array<uint64_t,4> dcache{};
    std::array<uint64_t,3> overlap{};
    uint64_t thumb=0,failed=0,load_words=0,store_words=0,taken=0,not_taken=0,returns=0;
};
inline Counts subtract(const Counts &a,const Counts &b) {
    Counts c=a;c.clocks-=b.clocks;
    for(unsigned i=0;i<Classes;i++)c.why[i]-=b.why[i];
    for(unsigned i=0;i<Mixes;i++)c.mix[i]-=b.mix[i];
    for(unsigned i=0;i<46;i++)c.evidence[i]-=b.evidence[i];
    for(unsigned i=0;i<8;i++){c.stall[i]-=b.stall[i];c.icache[i]-=b.icache[i];}
    for(unsigned i=0;i<4;i++)c.dcache[i]-=b.dcache[i];
    for(unsigned i=0;i<3;i++)c.overlap[i]-=b.overlap[i];
    c.thumb-=b.thumb;c.failed-=b.failed;c.load_words-=b.load_words;c.store_words-=b.store_words;
    c.taken-=b.taken;c.not_taken-=b.not_taken;c.returns-=b.returns;return c;
}
inline Mix instruction(uint32_t i,bool thumb=false) {
    // The shared Thumb expander uses NV-coded BL half markers. The bench
    // counts a paired BL at its first half, matching existing QEMU icount.
    if(thumb&&((i&0xfffff800)==0xf0000000||(i&0xfffff800)==0xf0001000))return Branch;
    if((i&0x0f000000)==0x0f000000)return Swi;
    if((i&0x0e000000)==0x0a000000 || (i&0x0ffffff0)==0x012fff10)return Branch;
    if((i&0x0e000000)==0x08000000)return i&(1u<<20)?Ldm:Stm;
    if((i&0x0fc000f0)==0x00000090 || (i&0x0f8000f0)==0x00800090)return Mult;
    if((i&0x0fb00ff0)==0x01000090)return Swp;
    if((i&0x0fbf0fff)==0x010f0000)return Mrs;
    if((i&0x0db0f000)==0x0120f000)return Msr;
    if((i&0x0f000010)==0x0e000010)return i&(1u<<20)?Mrc:Mcr;
    if((i&0x0c000000)==0x04000000 || (i&0x0e000090)==0x00000090)return i&(1u<<20)?Load:Store;
    return Other;
}
class Profile {
    bool v2_; FILE *csv_=nullptr; Counts second_,segment_; uint64_t second_start_=0,segment_start_=0;
    std::unordered_map<uint32_t,uint32_t> decoded_;
    uint64_t last_decode_=~uint64_t(0); Class recovery_=Pipeline,pending_w_=ReturnRepair;
    uint32_t target_=0; bool recovering_=false;
    void row(const char *scope,const char *label,uint64_t from,uint64_t to,const Counts &c) {
        if(!csv_)return;
        uint64_t sum=0,mix=0;for(auto x:c.why)sum+=x;for(auto x:c.mix)mix+=x;
        if(sum!=c.clocks||mix!=c.why[Retired]){fprintf(stderr,"profile conservation failure\n");std::abort();}
        fprintf(csv_,"%s,%s,%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64,v2_?"ARM9":"ZAP",scope,label,from,to,c.clocks);
        for(auto x:c.why)fprintf(csv_,",%" PRIu64,x);
        for(auto x:c.mix)fprintf(csv_,",%" PRIu64,x);
        for(auto x:{c.thumb,c.failed,c.load_words,c.store_words,c.taken,c.not_taken,c.returns})fprintf(csv_,",%" PRIu64,x);
        for(auto x:c.evidence)fprintf(csv_,",%" PRIu64,x);
        for(auto x:c.stall)fprintf(csv_,",%" PRIu64,x);
        for(auto x:c.icache)fprintf(csv_,",%" PRIu64,x);
        for(auto x:c.dcache)fprintf(csv_,",%" PRIu64,x);
        for(auto x:c.overlap)fprintf(csv_,",%" PRIu64,x);
        fputc('\n',csv_);fflush(csv_);
    }
public:
    Counts total; bool enabled=false;
    explicit Profile(bool v2):v2_(v2){}
    ~Profile(){if(csv_)fclose(csv_);}
    void open(const std::string &path) {
        csv_=fopen(path.c_str(),"w");if(!csv_){perror(path.c_str());std::abort();}enabled=true;
        fprintf(csv_,"core,scope,label,start,end,clocks");
        for(auto n:names)fprintf(csv_,",%s",n);
        for(auto n:mix_names)fprintf(csv_,",mix_%s",n);
        fprintf(csv_,",thumb,condition_failed,load_words,store_words,branches_taken,branches_not_taken,returns");
        for(int i=0;i<46;i++)fprintf(csv_,",e%d",i);
        for(int i=0;i<8;i++)fprintf(csv_,",stall%d",i);
        for(int i=0;i<8;i++)fprintf(csv_,",ic%d",i);
        for(int i=0;i<4;i++)fprintf(csv_,",dc%d",i);
        fprintf(csv_,",retired_dfill,retired_dlock,retired_ifill");
        fputc('\n',csv_);
    }
    void observe(const Sample &s,bool retired,bool continuation,char ev,uint32_t pc) {
        if(!enabled)return;
        const auto f=s.flags;auto bit=[&](int n){return bool((f>>n)&1);};
        total.clocks++;
        // Iterate only set bits: negligible work on ordinary ALU clocks.
        for(uint64_t bits=f;bits;bits&=bits-1){unsigned n=__builtin_ctzll(bits);if(n<46)total.evidence[n]++;}
        for(unsigned bits=s.stall;bits;bits&=bits-1)total.stall[__builtin_ctz(bits)]++;
        for(unsigned bits=s.icache;bits;bits&=bits-1)total.icache[__builtin_ctz(bits)]++;
        for(unsigned bits=s.dcache;bits;bits&=bits-1)total.dcache[__builtin_ctz(bits)]++;
        if(bit(40)) {
            uint64_t key=(uint64_t(s.decode_pc)<<32)|s.decode_ins;
            if(key!=last_decode_){decoded_[s.decode_pc]=s.decode_ins;last_decode_=key;}
        }
        // Keep recovery alive past older in-flight retirements. It ends on
        // the target's retirement, not the first unrelated retirement.
        if(bit(0)){recovering_=false;pending_w_=ReturnRepair;}
        bool start=false;
        if(v2_&&bit(41)){recovery_=pending_w_;start=true;}
        else if(!v2_&&(bit(15)||bit(19)||bit(20)||bit(21))){recovery_=bit(15)?Replay:bit(20)?Exception:bit(21)?SerialRefill:ReturnRepair;start=true;}
        else if(bit(17)||bit(43)){recovery_=BranchA;start=true;}
        else if(bit(18)){recovery_=BranchD;start=true;}
        if(start){recovering_=true;target_=s.target&~1u;}
        if(v2_&&(bit(19)||bit(20)||bit(21)))pending_w_=bit(20)?Exception:bit(21)?SerialRefill:ReturnRepair;
        if(retired&&pc==target_&&!start)recovering_=false;
        Class why=Pipeline;
        if(bit(0))why=Reset;
        else if(retired)why=Retired;
        else if(continuation)why=ThumbContinuation;
        else if(ev=='D'||ev=='P'||ev=='I'||ev=='F')why=Exception;
        else if(bit(22)&&!bit(23))why=Uop;
        else if(bit(6)&&bit(7))why=DUncached;
        else if(bit(6)&&bit(8))why=DWriteThrough;
        else if(bit(6)&&bit(5))why=DTranslation;
        else if(bit(9))why=DLock;
        else if(bit(6)&&bit(4))why=DMiss;
        else if(bit(6))why=DRequest;
        else if(bit(14))why=Serial;
        else if(bit(15))why=Replay;
        else if(bit(16))why=Reservation;
        else if(bit(12))why=Multiply;
        else if(bit(11))why=Shift;
        else if(bit(10))why=LoadUse;
        else if(bit(13))why=Dependency;
        else if(bit(1)&&bit(3))why=ITlb;
        else if(bit(1)&&bit(2))why=IMiss;
        else if(bit(1)&&recovering_)why=FetchRedirect;
        else if(bit(1)&&bit(27))why=FetchOther;
        else if(recovering_)why=recovery_;
        else if(bit(26))why=BlockSequence;
        else if(bit(39))why=Wfi;
        total.why[why]++;
        if(retired){
            uint32_t ins=s.retire_ins;bool known=v2_;
            if(!v2_){auto it=decoded_.find(pc);known=it!=decoded_.end();if(known)ins=it->second;}
            total.overlap[0]+=bit(4);total.overlap[1]+=bit(45);total.overlap[2]+=bit(2);
            Mix m=known?instruction(ins,bit(25)):Unknown;total.mix[m]++;total.thumb+=bit(25);total.failed+=!bit(24)&&ev=='R';
            if(bit(24)){
                unsigned words=(m==Ldm||m==Stm)?__builtin_popcount(ins&65535):1;
                if(!words)words=1; // Empty list transfers PC once; base advances by 16 words.
                if(m==Load||m==Ldm||m==Swp)total.load_words+=words;
                if(m==Store||m==Stm||m==Swp)total.store_words+=words;
            }
            const bool pc_write=(m==Load&&((ins>>12)&15)==15)||(m==Ldm&&(ins&32768))||
                (m==Other&&(ins&0x0c000000)==0&&((ins>>12)&15)==15&&((ins>>21)&15)<8)||
                (m==Other&&(ins&0x0c000000)==0&&((ins>>12)&15)==15&&((ins>>21)&15)>=12);
            if(m==Branch||pc_write){if(bit(24))total.taken++;else total.not_taken++;}
            total.returns+=bit(24)&&((ins&0x0fffffff)==0x012fff1e||(ins&0x0fffffff)==0x01a0f00e||(m==Ldm&&(ins&32768)));
        }
    }
    void second(uint64_t clock){row("interval","second",second_start_,clock,subtract(total,second_));second_=total;second_start_=clock;}
    void mark(const char *label,uint64_t clock){row("segment",label,segment_start_,clock,subtract(total,segment_));row("cumulative",label,0,clock,total);segment_=total;segment_start_=clock;}
    void finish(uint64_t clock){if(clock!=second_start_)second(clock);mark("end",clock);}
};
}
