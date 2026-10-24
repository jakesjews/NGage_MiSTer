#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prove the FSM's actual summary capture expressions for arbitrary next locks.

The unconstrained 64-bit next bitmap includes simultaneous clears and installs,
multiple locks, same-register replacement, and every owner change. The full CPU
source suite separately checks that the queried owner follows the W schedule.
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
model = '''module proof(input clk, reset, input [63:0] lock_nxt,
    input [5:0] i_lock_owner_next);
reg [63:0] lock_ff;
reg o_lock_any, o_lock_owner;
reg [5:0] owner;
always @(posedge clk) begin
    owner <= reset ? 0 : i_lock_owner_next;
'''
for name, (reset, update) in updates:
    model += f'    {name} <= reset ? ({reset}) : ({update});\n'
model += '''end
always @* begin
    assert(o_lock_any == (|lock_ff));
    assert(o_lock_owner == lock_ff[owner]);
end
endmodule
'''
(out / 'proof.v').write_text(model)
command = 'read_verilog -formal proof.v; prep -top proof; flatten; chformal -lower; '
command += 'sat -seq 2 -tempinduct -maxsteps 4 -set-init-zero -prove-asserts -verify'
with (out / 'proof.log').open('w') as log:
    subprocess.run(['yosys', '-p', command], cwd=out, stdout=log,
                   stderr=subprocess.STDOUT, check=True)
print('PASS: arbitrary next locks and owner, reset and every-edge summary equality')
