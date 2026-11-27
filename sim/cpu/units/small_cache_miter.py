#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The large cache told to be the small one, against the small one, edge for edge.

arm925t_cache_tag_ram built at 32 KB with SMALL_SIZE and i_small high (the
core's "real cache sizes" setting) must do in every clock what the same unit
built at SMALL_SIZE does: every output and the registered metadata are
compared under random requests over addresses that differ in the index bits
only the large cache has, random tags from a small pool (so that lookups
hit), byte writes, accepted hits, holds, cache enable, whole-cache cleans and
invalidates, and line operations by address and by index. Two pairs: the
D-cache's configuration (8 KB in 32 KB, dirty bits, the collision register,
the accepted-hit LRU update, the reported 8 KB index) and the I-cache's
(16 KB in 32 KB, read-only).

Stimulus and contracts as sim/cpu/units/metadata_miter.py (installs come at
most every fourth clock: the FSMs' one-entry deferred-LRU contract).
"""
from pathlib import Path
import re, subprocess
root = Path(__file__).resolve().parents[3]
b = root / 'sim/cpu/build/small-cache-miter'; b.mkdir(parents=True, exist_ok=True)

def port_list(src):
    ports = src[src.index(')(\n') + 3:src.index('\n);')]
    ports = re.sub(r'\(\*.*?\*\)', '', ports, flags=re.S); ports = re.sub(r'/\*.*?\*/', '', ports, flags=re.S); ports = re.sub(r'//[^\n]*', '', ports)
    return re.findall(r'\b(input|output)\s+logic\s*((?:\[[^\]]+\]\s*)*)([\w,\s]+?)(?=,?\s*\b(?:input|output)\b|$)', ports, re.S)

ins, outs, decl = [], [], ''
for direction, width, names in port_list((root / 'rtl/cpu/arm925t_cache_tag_ram.sv').read_text()):
    for name in re.findall(r'\b[io]_\w+', names):
        if direction == 'input':
            ins.append(name); decl += f'logic {width} {name};\n'
        else:
            outs.append(name); decl += f'wire {width} ref_{name};\nwire {width} dut_{name};\n'
assert 'i_small' in ins and len(ins) == 28 and len(outs) >= 20, (len(ins), len(outs))
con = lambda pre: ',\n'.join([f'.{n}({n})' for n in ins if n != 'i_small'] + [f'.{n}({pre}_{n})' for n in outs])
checks = '\n'.join(f'assert(dut_{n} === ref_{n}) else $fatal(1,"cfg %0d cycle %0d {n}",CFG,cycle);' for n in outs)
checks += '\n' + '\n'.join(f'assert(dut.{n} === phone.{n}) else $fatal(1,"cfg %0d cycle %0d {n}",CFG,cycle);' for n in ['valid_q', 'dirty_q', 'lru_q', 'state_ff'])
rand = '\n'.join(f'{n} = $random(rng);' for n in ins if n not in ['i_clk', 'i_reset', 'i_small'])

tb = '''`include "arm925t_defines.svh"
// CFG 0: the D-cache's unit; CFG 1: the I-cache's.
module test #(parameter CFG=0, parameter WAYS=2, parameter CACHE_SIZE=8192, parameter CACHE_LINE=16)(output logic done);
localparam SMALL_SIZE=CACHE_SIZE;     // for the port widths: the tag is the small cache's in both
localparam LARGE_SIZE=32768;
localparam SETS=CACHE_SIZE/WAYS/CACHE_LINE;
''' + decl + f'''
arm925t_cache_tag_ram #(.WAYS(WAYS),.CACHE_SIZE(CACHE_SIZE),.CACHE_LINE(CACHE_LINE),
    .TRACK_DIRTY(CFG==0),.REG_COLLISION(CFG==0),.ACCEPTED_HIT_UPDATE(CFG==0)) phone (.i_small(1'b0),
{con('ref')});
arm925t_cache_tag_ram #(.WAYS(WAYS),.CACHE_SIZE(LARGE_SIZE),.SMALL_SIZE(CACHE_SIZE),.CACHE_LINE(CACHE_LINE),
    .TRACK_DIRTY(CFG==0),.REG_COLLISION(CFG==0),.ACCEPTED_HIT_UPDATE(CFG==0),
    .INDEX_SIZE(CFG==0 ? 32'd8192 : LARGE_SIZE)) dut (.i_small(1'b1),
{con('dut')});
integer rng=32'h51a77+CFG,cycle;
integer hits=0,held=0,cleans=0,clears=0,lines=0,hum=0,collisions=0,high=0;
// An address: sixteen values of the bits above the small D-cache's index
// (they hold the index bits only the large cache has), any line and offset.
function automatic [31:0] adr; input integer r; adr = 32'(r & 16'hFFFF); endfunction
task tick;
 i_clk=0; #5; i_clk=1; #5;
 {checks}
 if(dut_o_cache_hit)hits++;
 if(i_hold)held++;
 if(dut.tag_ram_clean)cleans++;
 if(dut.tag_ram_clear)clears++;
 if(dut.line_clear)lines++;
 if(i_accepted_hit&&i_hold)hum++;
 if(!i_hold&&dut.tag_ram_wr_en&&dut.rd_set==dut.tag_ram_wr_addr)collisions++;
 if(dut_o_cache_hit&&i_lookup_address[13:12]!=0)high++;
 assert(dut.rd_set<SETS && dut.tag_ram_wr_addr<SETS) else $fatal(1,"cfg %0d cycle %0d a set above the small cache",CFG,cycle);
endtask
initial begin
 done=0; i_clk=0; i_reset=1;
 {rand}
 i_hold=0; tick(); i_reset=0;
 for(cycle=0;cycle<400000;cycle++) begin
  {rand}
  i_cache_line={{$random(rng),$random(rng),$random(rng),$random(rng)}};
  i_hold=($random(rng)&3)==0;
  i_address=adr($random(rng));
  i_address_nxt=cycle%3==0 ? i_address : adr($random(rng));
  i_lookup_address=cycle%7==0 ? adr($random(rng)) : i_address;
  i_accepted_address=cycle%2==0?i_address:i_address_nxt;
  // the tag written: the address's own bits above the index, any physical line
  i_cache_tag[`ARM925T_CACHE_TAG__TAG]=i_address[`ARM925T_VA__CACHE_TAG];
  i_cache_en=cycle%5000!=4999;
  i_cache_clean_req=cycle%5000>=3000 && cycle%5000<4000;
  i_cache_inv_req=cycle%5000>=4000 && cycle%5000<4010 && (cycle/5000)%4==3;
  i_line_req=cycle%5000>=4500 && cycle%5000<4800;
  i_line_addr=adr(32'h3450+(cycle/5000)*32'h1010); i_line_op=2'(cycle/5000); i_line_va=1'(cycle/10000);
  i_line_way=1'(cycle/20000);
  i_wb_ack=($random(rng)&3)!=0;
  i_cache_tag_wr_en=i_cache_tag_wr_en&&(cycle%4==0);
  i_accepted_hit=i_accepted_hit&&(cycle%4==0);
  i_access=i_access&&(cycle%4==0);
  if(cycle<16384) begin
   // every line of the small cache twice, with every single-byte mask, collision and hold
   i_idle=0; i_cache_tag_wr_en=1; i_accepted_hit=0; i_access=0; i_cache_way=1'(cycle>>9);
   i_address=32'((cycle&511)<<4) | 32'((cycle>>13)<<12); i_address_nxt=i_address;
   i_cache_tag[`ARM925T_CACHE_TAG__TAG]=i_address[`ARM925T_VA__CACHE_TAG];
   i_cache_line_ben=16'(1<<((cycle>>9)&15));
  end
  tick();
 end
 // a whole dirty walk to its end, a line operation by index, an invalidate
 i_reset=1; tick(); i_reset=0;
 i_cache_tag_wr_en=1; i_cache_line_ben='1; i_cache_tag_dirty=1;
 i_cache_en=1; i_idle=0; i_access=0;
 i_cache_clean_req=0; i_cache_inv_req=0; i_line_req=0; i_hold=0;
 for(int n=0;n<1024;n++)begin i_address=32'(n<<4); i_cache_way=1'(n>>8); i_cache_tag[`ARM925T_CACHE_TAG__TAG]=i_address[`ARM925T_VA__CACHE_TAG]; tick(); tick(); tick(); tick(); end
 i_cache_tag_wr_en=0; i_cache_line_ben=0;
 i_accepted_hit=0; i_hold=0; i_wb_ack=1; i_line_req=0;
 i_cache_inv_req=0; i_cache_clean_req=1;
 repeat(40000)tick();
 i_cache_clean_req=0; repeat(4000)tick();
 i_line_req=1; i_line_op=3; i_line_va=0; i_line_way=i_cache_way; i_line_addr=32'h3120;
 repeat(64)tick(); i_line_req=0; repeat(8)tick();
 i_cache_inv_req=1; repeat(16)tick();
 $display("cfg %0d hit/hold/clean/clear/line/HUM/collision/high %0d %0d %0d %0d %0d %0d %0d %0d",CFG,hits,held,cleans,clears,lines,hum,collisions,high);
 assert(hits>1000&&held>100&&cleans>(CFG==0?10:-1)&&clears>0&&lines>(CFG==0?0:-1)&&hum>100&&collisions>100&&high>500) else $fatal(1,"coverage");
 done=1;
end
endmodule
module small_miter;
wire [1:0] done;
test #(.CFG(0)) d(done[0]);
test #(.CFG(1),.CACHE_SIZE(16384)) i(done[1]);
initial begin wait(&done); $display("PASS: the 32 KB cache as the phone's, against the phone's: every output and the registered metadata, D and I"); $finish; end
endmodule
'''
(b / 'tb.sv').write_text(tb)
args = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '--top-module', 'small_miter', '-j', '6', '--Mdir', str(b / 'obj'),
        '-I' + str(root / 'rtl/cpu'), str(b / 'tb.sv'), str(root / 'rtl/cpu/arm925t_cache_tag_ram.sv'), str(root / 'rtl/cpu/arm925t_ram.sv'),
        str(root / 'sim/stubs/altsyncram.sv')]   # the RAMs are Altera's megafunction; the bench's model of it
with (b / 'build.log').open('w') as f: subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, check=True)
with (b / 'run.log').open('w') as f: subprocess.run([str(b / 'obj/Vsmall_miter')], stdout=f, stderr=subprocess.STDOUT, check=True)
print((b / 'run.log').read_text())
