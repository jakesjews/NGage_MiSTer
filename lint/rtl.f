// Run from the repository root after make lint-prepare.
// Supply a default for modules without a timescale; preserve explicit ones.
--timescale 1ns/1ps

// Read the warning policy before sources.
lint/exclusions.vlt
+incdir+lint/gen
+incdir+sys
-y sys

// Lint-only PLL boundary.
lint/pll.sv
// The behavioural altsyncram (the CPU netlist instantiates it).
sim/stubs/altsyncram.sv
// The behavioural altdpram (the register file's banks in the CPU netlist).
sim/stubs/altdpram.sv

// Framework modules that the video output uses and that are not in a file of
// their own name.
sys/hq2x.sv
sys/math.sv

// Sources from files.qip; keep this list in sync.
rtl/board/ngage_keys.sv
rtl/board/sdp_ram.sv
rtl/board/tdp_ram.sv
rtl/board/lcd_panel.sv
rtl/board/video_out.sv
rtl/board/keypad_matrix.sv
rtl/board/nor_flash.sv
rtl/board/mmc_card.sv
rtl/board/bt_module.sv
rtl/mem/bram32.sv
rtl/mem/sdram.sv
rtl/mem/ddram_flash.sv
rtl/upp/upp_bus.sv
rtl/upp/upp_fifo.sv
rtl/upp/upp_intc.sv
rtl/upp/upp_timers.sv
rtl/upp/upp_dma.sv
rtl/upp/upp_mmc.sv
rtl/upp/upp_lcdif.sv
rtl/upp/upp_uif.sv
rtl/upp/upp_cbus.sv
rtl/upp/upp_haudio.sv
rtl/upp/upp_periph.sv
rtl/upp/wb_arb2.sv
rtl/upp/ngage_mem.sv
rtl/mister/ngage_input.sv
rtl/mister/ddram_loader.sv
rtl/mister/phoenix_load.sv
rtl/mister/flash_save.sv
rtl/mister/rtc_wall.sv
rtl/mister/dbg_trace.sv
rtl/mister/dbg_sti.sv
rtl/mister/dbg_counters.sv
rtl/cpu/arm925t_gen.v
NGage.sv
