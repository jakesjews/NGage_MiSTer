derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The memory test's master select, test_on_q (NGage.sv), changes only in the
# first clock of a reset pulse that test_sw then holds for four clocks, with
# the CPU in its own reset: its paths into the Wishbone master muxes, the
# SDRAM write data and the self-test engine may take four clocks. The only
# single-clock consumer is test_sw itself (the pulse generator).
set_multicycle_path -setup -end 4 -from [get_registers {*|test_on_q*}] \
    -to [remove_from_collection [get_registers *] [get_registers {*|test_sw*}]]
set_multicycle_path -hold -end 3 -from [get_registers {*|test_on_q*}] \
    -to [remove_from_collection [get_registers *] [get_registers {*|test_sw*}]]

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
