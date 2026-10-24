# 104 MHz, the N-Gage QD's CPU clock and the core's clk_sys. Pins are not
# timed: the trial registers them on both sides.
create_clock -name clk -period 9.615 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [all_inputs] -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]
