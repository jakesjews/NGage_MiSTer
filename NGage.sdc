derive_pll_clocks

# The framework's low-latency tuner (sys/pll_hdmi_adj.vhd, process Delay)
# clocks 41 registers from bit 6 of the scaler's lltune bus, which is the
# video clock, and sys_top ANDs that bus with cfg_done: a clock gated in a
# LUT (comb~0, the first anonymous node of sys_top) and routed locally.
# CLK_VIDEO is clk_sys in this core, so without a clock of their own those
# registers sit in clk_sys's domain, and derive_clock_uncertainty, which
# works per clock pair, gives every clk_sys transfer the gated branch's
# figures (setup 0.300, hold 0.280 ns) instead of the PLL's own (0.140 and
# 0.080). The gate's output is declared a generated clock: the gated
# registers and their crossings keep the larger figures, the registers on
# the global network get theirs. The new clock stays on clk_sys's side of
# the framework's exclusive groups. tools/report_timing.tcl fails the build
# if the gate is not where this expects it (clk_sys's uncertainty tells).
set ll_gate [get_pins -compatibility_mode -nowarn {comb~0|combout}]
if {[get_collection_size $ll_gate] == 1} {
    create_generated_clock -name lltune_clk \
        -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}] $ll_gate
    set_clock_groups -exclusive \
        -group [get_clocks {lltune_clk *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
        -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
        -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
        -group [get_clocks {hdmi_sck}] \
        -group [get_clocks {*|h2f_user0_clk}] \
        -group [get_clocks {FPGA_CLK1_50}] \
        -group [get_clocks {FPGA_CLK2_50}] \
        -group [get_clocks {FPGA_CLK3_50}]
}
derive_clock_uncertainty

# core specific constraints

# The UPP peripheral bus (rtl/upp/upp_bus.sv header): p_addr, p_be, p_wdata
# and p_we change only on the edge an access starts, with p_sel, and hold
# until it completes. upp_periph completes a write no earlier than the second
# clock (done needs cnt != 0) and a read no earlier than the third (cnt[1]),
# and the timers and the MMC FIFO change state only on its wr/rd strobes, so
# these payload registers into the read data and those registers have two
# clocks. Not included: upp_periph's first-clock registers (rdy_q, dma_hit_q,
# off_q), which an access uses in its second clock, and every other register.
set periph_payload [get_registers {*upp_bus:bus|p_addr[*] *upp_bus:bus|p_be[*] *upp_bus:bus|p_wdata[*] *upp_bus:bus|p_we}]
set periph_slow [get_registers {*upp_periph:upp_periph|rd_q[*] *upp_timers:timers|* \
    *upp_mmc:mmc|nfifo[*] *upp_mmc:mmc|fmem* *upp_mmc:mmc|fwp[*] *upp_mmc:mmc|frp[*] *upp_mmc:mmc|fcnt[*]}]
set_multicycle_path -setup -end 2 -from $periph_payload -to $periph_slow
set_multicycle_path -hold -end 1 -from $periph_payload -to $periph_slow
