// SPDX-License-Identifier: GPL-3.0-or-later
// The register file's architectural contents for the whole-core benches
// (sim/harness/coreboot_main.cpp reads `regs`): each register from the bank
// of its latest writer, or from a write the file holds for a clock. The CPU
// has no such view of its own; the CPU bench builds the same one in
// sim/cpu/tb/tb_cpu.sv.
module core_regs_tap;
    `define RF emu.arm925t.u_top.u_core.u_writeback.u_register_file.g_write_ff
    logic [39:0][31:0] regs /* verilator public_flat_rd */;
    wire [79:0] owner = `RF.latest;
    for (genvar r = 0; r < 40; r++) begin : g_reg
        wire [31:0] stored = !`RF.initialized[r] ? 32'd0 :
            owner[r*2+:2] == 0 ? `RF.g_read[0].ram_a.mem[r] :
            owner[r*2+:2] == 1 ? `RF.g_read[0].ram_b.mem[r] :
                                 `RF.g_read[0].ram_c.mem[r];
        assign regs[r] = `RF.held_c[r] ? `RF.held_data_c :
            `RF.held_b[r] ? `RF.held_data_b : `RF.held_a[r] ? `RF.held_data_a : stored;
    end
    `undef RF
endmodule

bind emu core_regs_tap u_core_regs_tap ();
