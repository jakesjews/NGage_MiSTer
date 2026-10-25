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
