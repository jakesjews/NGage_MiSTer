#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inductively compare actual short metadata captures with S10's equations.

Arrays and maintenance/write descriptors are arbitrary inputs on every edge.
Thus this covers all read addresses, simultaneous bypasses, reset and distinct
hold enables, independently of any assumptions about cache FSM traffic.
The full-module miter separately checks unchanged array-update priority.
"""
from pathlib import Path
import re,subprocess
r=Path(__file__).resolve().parents[3]; b=r/'sim/cpu/build/short-meta-proof';b.mkdir(parents=True,exist_ok=True)
s=(r/'rtl/cpu/zap/zap_cache_tag_ram.sv').read_text()
g=subprocess.check_output(['git','show','c87d383:rtl/cpu/zap/zap_cache_tag_ram.sv'],cwd=r,text=True)
a=s.index('if (SHORT_READ) begin : g_short_meta');z=s.index('// ----------------------------------------------------------------------------',a)
new=s[a:z]
functions=g[g.index('        function automatic logic lru_fwd ('):g.index('        always_ff',g.index('        function automatic logic lru_fwd ('))]
expr={n:re.search(n+r'_q\[w\]\s*<= SHORT_READ \?\s*\((.*?)\)\s*:',g,re.S)[1] for n in ['valid','dirty']}
for sets in [256,512]:
 p=b/str(sets);p.mkdir(exist_ok=True)
 model=f'''module proof(input i_clk,i_reset,i_hold,tag_ram_clear,tag_ram_clean,line_clear,
 input [2*{sets}-1:0] valid,dirty,input [{sets}-1:0] lru,
 input [$clog2({sets})-1:0] rd_set,tag_ram_wr_addr,pend_addr,hit_upd_set,hit_pend_set,
 input tag_ram_wr_en,pend_en,i_cache_tag_dirty,pend_dirty,hit_upd_en,hit_upd_way,hit_pend_en,hit_pend_val,
 input [1:0] wr_sel,pend_sel);
 localparam SHORT_READ=1,WAYS=2,LINES={sets},SET_W=$clog2(LINES),WAY_W=1,FLAT_W=SET_W+1;
 wire [1:0] valid_q,dirty_q;wire lru_q;
 reg [1:0] old_valid,old_dirty;reg old_lru;
 function automatic [FLAT_W-1:0] flat(input [WAY_W-1:0] w,input [SET_W-1:0] set);
 return FLAT_W'({{w,set}}); endfunction
 '''+functions+new+f'''
 always @(posedge i_clk)begin
 if(i_reset)begin old_valid<=0;old_dirty<=0;old_lru<=0;end
 else begin
 if(!i_hold||tag_ram_clear||line_clear)begin
 for(int w=0;w<WAYS;w++)old_valid[w]<={expr['valid']};
 old_lru<=lru_fwd_now(rd_set,lru[rd_set]);end
 if(!i_hold||tag_ram_clean||line_clear)for(int w=0;w<WAYS;w++)old_dirty[w]<={expr['dirty']};
 end
 end
 always @* begin assert(valid_q==old_valid);assert(dirty_q==old_dirty);assert(lru_q==old_lru);end
 endmodule
 '''
 (p/'proof.sv').write_text(model)
 with (p/'proof.v').open('w')as f:subprocess.run(['sv2v',str(p/'proof.sv')],stdout=f,check=True)
 cmd='read_verilog -formal proof.v; prep -top proof; flatten; chformal -lower; sat -seq 2 -tempinduct -maxsteps 4 -set-init-zero -prove-asserts -verify'
 with (p/'proof.log').open('w')as f:subprocess.run(['yosys','-p',cmd],cwd=p,stdout=f,stderr=subprocess.STDOUT,check=True)
 print(f'PASS: {sets} sets, arbitrary arrays, enables and descriptors, inductive metadata equivalence',flush=True)
