#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prove the FSM's actual summary capture expressions for arbitrary next locks.

The next bitmap is lock_ff with an arbitrary clear mask (o_reg_idx) and at
most one new lock at an arbitrary index, the form the FSM builds (its source
suite assertion checks lock_nxt against it); that covers simultaneous clears
and installs, same-register replacement, and every owner change. The owner
queries are the FSM's own expressions (LOCK_SPLIT's and the indexed form's).
The full CPU source suite separately checks that the queried owner follows
the W schedule.
"""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[3]
source = (root / 'rtl/cpu/zap/zap_dcache_fsm.sv').read_text()
updates = []
for name in ('lock_ff', 'o_lock_any', 'o_lock_owner'):
    expressions = re.findall(r'\b' + name + r'\s*<=\s*([^;]+);', source)
    assert len(expressions) == 2, (name, expressions)
    updates.append((name, expressions))
out = root / 'sim/cpu/build/lock-summary'
out.mkdir(parents=True, exist_ok=True)
model = '''module proof(input clk, reset, input [63:0] o_reg_idx,
    input lock_set_nxt, input [5:0] i_reg_idx_bin,
    input [5:0] i_lock_owner_hold, i_lock_owner_advance,
    input i_lock_owner_move);
localparam LOCK_SPLIT = @SPLIT@;
localparam LOCK_ANY_SPLIT = @SPLIT@;
reg [63:0] lock_ff;
wire [63:0] lock_nxt = (lock_ff & ~o_reg_idx) | (lock_set_nxt ? 64'd1 << i_reg_idx_bin : 64'd0);
reg o_lock_any, o_lock_owner;
reg [5:0] owner;
QUERIES
always @(posedge clk) begin
    owner <= reset ? 0 : i_lock_owner_move ? i_lock_owner_advance : i_lock_owner_hold;
'''
queries = re.findall(r'wire (\w+_set) = ([^;]+);', source)
assert len(queries) == 2, queries
locked = re.findall(r'wire (owner_\w+_locked) = ([^;]+);', source)
assert len(locked) == 2, locked
queries += [(n, ' '.join(e.split())) for n, e in locked]
model = model.replace('QUERIES', '\n'.join(f'wire {n} = {e};' for n,e in queries))
for name, (reset, update) in updates:
    model += f'    {name} <= reset ? ({reset}) : ({update});\n'
model += '''end
always @* begin
    assert(o_lock_any == (|lock_ff));
    assert(o_lock_owner == lock_ff[owner]);
end
endmodule
'''
command = 'read_verilog -formal proof.v; prep -top proof; flatten; chformal -lower; '
command += 'sat -seq 2 -tempinduct -maxsteps 4 -set-init-zero -prove-asserts -verify'
for split in (1, 0):
    (out / 'proof.v').write_text(model.replace('@SPLIT@', str(split)))
    with (out / f'proof{split}.log').open('w') as log:
        subprocess.run(['yosys', '-p', command], cwd=out, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
print('PASS: next locks (any clears, one install) and owner, reset and every-edge summary equality, split and indexed')
