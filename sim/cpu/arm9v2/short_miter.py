#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Cycle-exact cache RAM/metadata miter against the immutable S10 source.

Compares all outputs and metadata state under arbitrary per-cycle requests,
byte writes, accepted HUM hits, holds, cache enable, fills and maintenance.
The golden RTL is read from git, not a reimplementation of its behavior.
"""
from pathlib import Path
import re, subprocess
root=Path(__file__).resolve().parents[3]
b=root/'sim/cpu/build/short-miter'; b.mkdir(parents=True,exist_ok=True)
s=subprocess.check_output(['git','show','c87d383:rtl/cpu/zap/zap_cache_tag_ram.sv'],cwd=root,text=True)
(b/'gold.sv').write_text(s.replace('zap_cache_tag_ram','gold_cache_tag_ram'))
# Extract the actual port declarations so every output is compared, including
# the registered AND next Wishbone ports during clean/line writeback.
ports=s[s.index(')(\n')+3:s.index('\n);')]
ports=re.sub(r'\(\*.*?\*\)','',ports,flags=re.S); ports=re.sub(r'/\*.*?\*/','',ports,flags=re.S); ports=re.sub(r'//[^\n]*','',ports)
entries=re.findall(r'\b(input|output)\s+logic\s*((?:\[[^\]]+\]\s*)*)([\w,\s]+?)(?=,?\s*\b(?:input|output)\b|$)',ports,re.S)
ins=[];outs=[];decl=''
for direction,width,names in entries:
 for name in re.findall(r'\b[io]_\w+',names):
  (ins if direction=='input' else outs).append(name)
  decl+=f'logic {width} {name};\n'
  if direction=='output':decl+=f'wire {width} gold_{name};\n'
assert len(ins)==30,(len(ins),ins)
con=lambda golden:',\n'.join(f'.{n}({"gold_" if golden and n in outs else ""}{n})' for n in ins+outs)
checks='\n'.join(f'assert({n} === gold_{n}) else $fatal(1,"cfg %0d cycle %0d {n}",CFG,cycle);' for n in outs)
checks+='\n'+'\n'.join(f'assert(dut.{n} === gold.{n}) else $fatal(1,"cfg %0d cycle %0d {n}",CFG,cycle);' for n in ['valid','dirty','lru','valid_q','dirty_q','lru_q','state_ff'])
rand='\n'.join(f'{n} = $random(rng);' for n in ins if n not in ['i_clk','i_reset'])
# Deliberately small enough for repeated full maintenance walks, yet all 16
# metadata banks are exercised (256 sets). A second instance uses 512 I sets.
tb='''`include "zap_defines.svh"
module test #(parameter CFG=0, parameter SHORT_READ=1, parameter WAYS=2,
 parameter CACHE_SIZE=8192, parameter CACHE_LINE=16)(output logic done);
localparam INDEX_SIZE=CACHE_SIZE;
'''+decl+f'''
gold_cache_tag_ram #(.SHORT_READ(SHORT_READ),.WAYS(WAYS),.CACHE_SIZE(CACHE_SIZE),.CACHE_LINE(CACHE_LINE),.ACCEPTED_HIT_UPDATE(CFG%2)) gold ({con(True)});
zap_cache_tag_ram #(.SHORT_READ(SHORT_READ),.WAYS(WAYS),.CACHE_SIZE(CACHE_SIZE),.CACHE_LINE(CACHE_LINE),.ACCEPTED_HIT_UPDATE(CFG%2)) dut ({con(False)});
integer rng=32'h187a62+CFG,cycle;
integer hits=0,held=0,cleans=0,clears=0,lines=0,hum=0,collisions=0;
task tick;
 i_clk=0; #5; i_clk=1; #5;
 {checks}
 if(dut.o_cache_hit)hits++;
 if(i_hold)held++;
 if(dut.tag_ram_clean)cleans++;
 if(dut.tag_ram_clear)clears++;
 if(dut.line_clear)lines++;
 if(i_accepted_hit&&i_hold)hum++;
 if(!i_hold&&dut.tag_ram_wr_en&&dut.rd_set==dut.tag_ram_wr_addr)collisions++;
endtask
initial begin
 done=0; i_clk=0; i_reset=1;
 {rand}
 i_hold=0; tick(); i_reset=0;
 for(cycle=0;cycle<200000;cycle++) begin
  {rand}
  i_cache_line={{$random(rng),$random(rng),$random(rng),$random(rng)}};
  i_cache_tag='0;
  i_hold=($random(rng)&3)==0;
  i_address=32'($random(rng)&16383);
  i_address_nxt=cycle%3==0 ? i_address : 32'($random(rng)&16383);
  i_lookup_address=i_address;
  i_lookup_check_address=i_address_nxt;
  i_accepted_address=cycle%2==0?i_address:i_address_nxt;
  i_cache_en=cycle%5000!=4999;
  // Keep maintenance requests long enough to complete, separated by an
  // idle interval. Exercise both VA and index line operations.
  i_cache_clean_req=cycle%5000>=3000 && cycle%5000<4000;
  i_cache_inv_req=cycle%5000>=4000 && cycle%5000<4010;
  i_line_req=cycle%5000>=4500 && cycle%5000<4800;
  i_line_addr=32'h400; i_line_op=2'(cycle/5000); i_line_va=1'(cycle/10000);
  i_wb_ack=($random(rng)&3)!=0;
  if(cycle<8192) begin
   // Initialize all lines with every single-byte mask, collision and hold.
   i_idle=0; i_cache_tag_wr_en=1; i_cache_way=1'(cycle>>8);
   i_address=32'((cycle&511)<<4); i_address_nxt=i_address;
   i_cache_line_ben=16'(1<<(cycle>>9));
  end
  tick();
 end
 // Drain a complete dirty walk, then explicitly invalidate. Random
 // traffic above may leave the walker busy past a short request window.
 i_reset=1; tick(); i_reset=0;
 i_cache_tag_wr_en=1; i_cache_line_ben='1; i_cache_tag_dirty=1;
 i_cache_en=1; i_idle=0; i_access=0;
 i_cache_clean_req=0; i_cache_inv_req=0; i_line_req=0; i_hold=0;
 for(int n=0;n<64;n++)begin i_address=32'(n<<4); tick(); end
 i_cache_tag_wr_en=0; i_cache_line_ben=0;
 i_accepted_hit=0; i_hold=0; i_wb_ack=1; i_line_req=0;
 i_cache_inv_req=0; i_cache_clean_req=1;
 repeat(20000)tick();
 i_cache_clean_req=0; repeat(4000)tick();
 i_line_req=1; i_line_op=3; i_line_va=0; i_line_way=i_cache_way; i_line_addr=0;
 repeat(64)tick(); i_line_req=0; repeat(8)tick();
 i_cache_inv_req=1; repeat(16)tick();
 $display("cfg %0d hit/hold/clean/clear/line/HUM/collision %0d %0d %0d %0d %0d %0d %0d",CFG,hits,held,cleans,clears,lines,hum,collisions);
 assert(hits>100&&held>100&&cleans>10&&clears>0&&lines>0&&hum>100&&collisions>100) else $fatal(1,"coverage");
 done=1;
end
endmodule
module short_miter;
wire [3:0] done;
test #(.CFG(0)) a(done[0]);
test #(.CFG(1),.CACHE_SIZE(16384)) b(done[1]);
test #(.CFG(2),.WAYS(1),.CACHE_SIZE(4096)) c(done[2]);
test #(.CFG(3),.SHORT_READ(0)) d(done[3]);
initial begin wait(&done); $display("PASS: 896616 old/new cache edges, all outputs and metadata"); $finish; end
endmodule
'''
(b/'tb.sv').write_text(tb)
args=['verilator','--binary','--timing','--assert','-Wno-fatal','--top-module','short_miter','-j','6','--Mdir',str(b/'obj'),'-I'+str(root/'rtl/cpu/zap'),str(b/'tb.sv'),str(b/'gold.sv'),str(root/'rtl/cpu/zap/zap_cache_tag_ram.sv'),str(root/'rtl/cpu/zap/zap_ram_simple.sv'),str(root/'rtl/cpu/port/zap_ram_simple_ben.sv')]
with (b/'build.log').open('w') as f:subprocess.run(args,stdout=f,stderr=subprocess.STDOUT,check=True)
with (b/'run.log').open('w') as f:subprocess.run([str(b/'obj/Vshort_miter')],stdout=f,stderr=subprocess.STDOUT,check=True)
print((b/'run.log').read_text())
