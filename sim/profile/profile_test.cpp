// SPDX-License-Identifier: GPL-3.0-or-later
#include "cpu_profile.h"
int main(){
    using namespace cpu_profile;
    Profile p(true);p.enabled=true;Sample s;
    s.flags=(1ull<<24)|(1ull<<9)|(1ull<<6);s.retire_ins=0xe5900000;
    p.observe(s,true,false,'R',0x100);assert(p.total.why[Retired]==1&&p.total.load_words==1);
    p.observe(s,false,false,0,0);assert(p.total.why[DLock]==1);
    s.flags=(1ull<<22)|(1ull<<9);p.observe(s,false,false,0,0);assert(p.total.why[Uop]==1);
    s.flags=1ull<<17;s.target=0x200;p.observe(s,false,false,0,0);assert(p.total.why[BranchA]==1);
    s.flags=0;p.observe(s,true,false,'R',0x100);p.observe(s,false,false,0,0);assert(p.total.why[BranchA]==2);
    p.observe(s,true,false,'R',0x200);p.observe(s,false,false,0,0);assert(p.total.why[Pipeline]==1);
    assert(instruction(0xf0000000,true)==Branch);assert(instruction(0xf0001000,true)==Branch);
    assert(instruction(0xe121f000)==Msr);assert(instruction(0xe10f0000)==Mrs);
    assert(instruction(0xee110f10)==Mrc);assert(instruction(0xee010f10)==Mcr);
    assert(instruction(0xe8900000)==Ldm);assert(instruction(0xe8a00003)==Stm);
    uint64_t sum=0;for(auto x:p.total.why)sum+=x;assert(sum==p.total.clocks);
    puts("profile priority, recovery age, instruction classes and conservation PASS");
}
