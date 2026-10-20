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
rtl/mister/ngage_input.sv
rtl/mister/ddram_loader.sv
rtl/mister/lcd_testgen.sv
NGage.sv
