// Run from the repository root after make lint-prepare.
// Supply a default for modules without a timescale; preserve explicit ones.
--timescale 1ns/1ps

// Read the warning policy before sources.
lint/exclusions.vlt
+incdir+lint/gen
+incdir+sys
-y sys

// Board-level devices and the shell; keep in sync with files.qip.
rtl/board/sdp_ram.sv
rtl/board/lcd_panel.sv
rtl/board/video_out.sv
