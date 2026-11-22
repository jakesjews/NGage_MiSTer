# Verilator benches for the board-level devices, the memory system and the
# MiSTer shell. Run from the repository root with `make test`, or one bench
# at a time with `make -C sim lcd` (lcd, video, keypad, flash, mmc, bt, sdram,
# sdram-faults, ddrflash, upp, intc, timers, periph, save, top). Each bench is built
# into sim/build/<name> and run at once; pictures go to sim/build/out.
# The benches run one after the other. `make -C sim coreboot` (not part of
# `make test`) boots the firmware on the whole core; see its target below.
ROOT      := $(abspath ..)
BUILD     := $(ROOT)/sim/build
OUT       := $(BUILD)/out
VERILATOR ?= verilator
SEED      ?= 1

# Benches check behaviour, `make lint` checks style: warnings are not fatal
# here. X values start random, so nothing may rely on power-up contents.
VFLAGS := --cc --exe --build -j 4 -O3 --x-assign unique --x-initial unique \
          -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
          -CFLAGS "-O2 -std=c++17 -I$(ROOT)/sim/harness"
# Whole-core compile options (Verilator defines or parameters).
VEXTRA ?=
RUNFLAGS := +verilator+seed+$(SEED) +verilator+rand+reset+2

BENCHES := lcd video keypad flash mmc bt sdram sdram-faults ddrflash trace upp intc timers periph save pmm-save top

.PHONY: test $(BENCHES) coreboot flashcopy hps-read-test clean

test:
	@for b in $(BENCHES); do $(MAKE) --no-print-directory $$b || exit 1; done

$(OUT):
	mkdir -p $@

# The display module through its 8080 bus
LCD_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/board/lcd_panel.sv $(ROOT)/rtl/board/ngage_nem4_lcd.v
$(BUILD)/lcd/Vlcd_panel: $(LCD_RTL) $(ROOT)/sim/harness/lcd_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/lcd && $(VERILATOR) $(VFLAGS) --top-module lcd_panel --Mdir $(BUILD)/lcd -o Vlcd_panel \
		-GCLK_HZ=2000000 -GTE_HPULSE_CLKS=4 -GID1=69 -GID2=131 -GID3=90 \
		$(LCD_RTL) $(ROOT)/sim/harness/lcd_main.cpp
lcd: $(BUILD)/lcd/Vlcd_panel | $(OUT)
	$< $(RUNFLAGS) --seed $(SEED) --out $(OUT)

clean:
	rm -rf $(BUILD)

# The scan-out to MiSTer video
VIDEO_RTL := $(ROOT)/rtl/board/video_out.sv
$(BUILD)/video/Vvideo_out: $(VIDEO_RTL) $(ROOT)/sim/harness/video_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/video && $(VERILATOR) $(VFLAGS) --top-module video_out --Mdir $(BUILD)/video -o Vvideo_out \
		$(VIDEO_RTL) $(ROOT)/sim/harness/video_main.cpp
video: $(BUILD)/video/Vvideo_out | $(OUT)
	$< $(RUNFLAGS) --out $(OUT)

# The keypad matrix
KEYPAD_RTL := $(ROOT)/rtl/board/ngage_keys.sv $(ROOT)/rtl/board/keypad_matrix.sv
$(BUILD)/keypad/Vkeypad_matrix: $(KEYPAD_RTL) $(ROOT)/sim/harness/keypad_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/keypad && $(VERILATOR) $(VFLAGS) --top-module keypad_matrix --Mdir $(BUILD)/keypad -o Vkeypad_matrix \
		$(KEYPAD_RTL) $(ROOT)/sim/harness/keypad_main.cpp
keypad: $(BUILD)/keypad/Vkeypad_matrix
	$< $(RUNFLAGS) --seed $(SEED)

# The NOR flash, as the 16 MB CS0 chip and the 8 MB CS1 chip, with short busy times
FLASH_RTL := $(ROOT)/rtl/board/nor_flash.sv
FLASH_G   := -GPROGRAM_CLKS=40 -GSECTOR_ERASE_CLKS=3000 -GERASE_WINDOW_CLKS=200
$(BUILD)/flash_cs0/Vnor_flash: $(FLASH_RTL) $(ROOT)/sim/harness/flash_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/flash_cs0 && $(VERILATOR) $(VFLAGS) --top-module nor_flash --Mdir $(BUILD)/flash_cs0 -o Vnor_flash \
		$(FLASH_G) -GAW=23 -GDEVICE_ID=8952 $(FLASH_RTL) $(ROOT)/sim/harness/flash_main.cpp
$(BUILD)/flash_cs1/Vnor_flash: $(FLASH_RTL) $(ROOT)/sim/harness/flash_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/flash_cs1 && $(VERILATOR) $(VFLAGS) --top-module nor_flash --Mdir $(BUILD)/flash_cs1 -o Vnor_flash \
		$(FLASH_G) -GAW=22 -GDEVICE_ID=8954 $(FLASH_RTL) $(ROOT)/sim/harness/flash_main.cpp
flash: $(BUILD)/flash_cs0/Vnor_flash $(BUILD)/flash_cs1/Vnor_flash
	$(BUILD)/flash_cs0/Vnor_flash $(RUNFLAGS) --aw 23 --id 0x22F8 --seed $(SEED)
	$(BUILD)/flash_cs1/Vnor_flash $(RUNFLAGS) --aw 22 --id 0x22FA --seed $(SEED)

# The MMC card against a host on its bus and a model of hps_io
MMC_RTL := $(ROOT)/rtl/board/tdp_ram.sv $(ROOT)/rtl/board/mmc_card.sv
$(BUILD)/mmc/Vmmc_card: $(MMC_RTL) $(ROOT)/sim/harness/mmc_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/mmc && $(VERILATOR) $(VFLAGS) --top-module mmc_card --Mdir $(BUILD)/mmc -o Vmmc_card \
		$(MMC_RTL) $(ROOT)/sim/harness/mmc_main.cpp
mmc: $(BUILD)/mmc/Vmmc_card
	$< $(RUNFLAGS) --seed $(SEED)

# The SDRAM controller against the chip model (sim/harness/sdram_model.h)
SDRAM_RTL := $(ROOT)/rtl/mem/sdram.sv
SDRAM_DEPS := $(SDRAM_RTL) $(ROOT)/sim/harness/sdram_main.cpp $(ROOT)/sim/harness/sdram_model.h $(ROOT)/sim/harness/sdram_address.h $(ROOT)/sim/harness/common.h
$(BUILD)/sdram/Vsdram: $(SDRAM_DEPS)
	mkdir -p $(BUILD)/sdram && $(VERILATOR) $(VFLAGS) --top-module sdram --Mdir $(BUILD)/sdram -o Vsdram \
		$(SDRAM_RTL) $(ROOT)/sim/harness/sdram_main.cpp
sdram: $(BUILD)/sdram/Vsdram
	$< $(RUNFLAGS) --seed $(SEED)

# The same with a timing fault each, which the chip model must report: read
# capture a clock early, tRCD of one clock, tRFC of five clocks, refreshes
# too far apart
SDRAM_FAULTS := capture:-GCAPTURE_CLKS=0 rcd:-GT_RCD_NS=10 rfc:-GT_RFC_NS=50 refresh:-GREFRESH_SLACK=-150
SDRAM_FAULT_BINS := $(foreach f,$(SDRAM_FAULTS),$(BUILD)/sdram_$(word 1,$(subst :, ,$(f)))/Vsdram)
$(BUILD)/sdram_%/Vsdram: $(SDRAM_DEPS)
	mkdir -p $(BUILD)/sdram_$* && $(VERILATOR) $(VFLAGS) --top-module sdram --Mdir $(BUILD)/sdram_$* -o Vsdram \
		$(word 2,$(subst :, ,$(filter $*:%,$(SDRAM_FAULTS)))) $(SDRAM_RTL) $(ROOT)/sim/harness/sdram_main.cpp
sdram-faults: $(SDRAM_FAULT_BINS)
	@for b in $(SDRAM_FAULT_BINS); do echo "$$b"; $$b $(RUNFLAGS) --seed $(SEED) --cycles 60000 --expect-fail 2>/dev/null || exit 1; done

# The flash arrays in DDR3 against the DDRAM port model
DDRFLASH_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/mem/ddram_flash.sv
$(BUILD)/ddrflash/Vddram_flash: $(DDRFLASH_RTL) $(ROOT)/sim/harness/ddrflash_main.cpp $(ROOT)/sim/harness/ddram_model.h $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/ddrflash && $(VERILATOR) $(VFLAGS) --top-module ddram_flash --Mdir $(BUILD)/ddrflash -o Vddram_flash \
		$(DDRFLASH_RTL) $(ROOT)/sim/harness/ddrflash_main.cpp
ddrflash: $(BUILD)/ddrflash/Vddram_flash
	$< $(RUNFLAGS) --seed $(SEED)

# The hardware trace rings and their dump through the loader port
TRACE_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/mister/dbg_trace.sv
$(BUILD)/trace/Vdbg_trace: $(TRACE_RTL) $(ROOT)/sim/harness/trace_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/trace && $(VERILATOR) $(VFLAGS) --top-module dbg_trace --Mdir $(BUILD)/trace -o Vdbg_trace \
		$(TRACE_RTL) $(ROOT)/sim/harness/trace_main.cpp
trace: $(BUILD)/trace/Vdbg_trace
	$< $(RUNFLAGS) --seed $(SEED)

# The memory system (upp_bus, SDRAM including the on-chip RAM window,
# flash chips, DDR3 path) under a scripted Wishbone master
UPP_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/board/nor_flash.sv $(ROOT)/rtl/mem/bram32.sv \
           $(ROOT)/rtl/mem/sdram.sv $(ROOT)/rtl/mem/ddram_flash.sv $(ROOT)/rtl/upp/upp_bus.sv $(ROOT)/rtl/upp/wb_arb2.sv \
           $(ROOT)/rtl/upp/ngage_mem.sv
UPP_DEPS := $(UPP_RTL) $(ROOT)/sim/harness/upp_main.cpp $(ROOT)/sim/harness/sdram_model.h \
            $(ROOT)/sim/harness/ddram_model.h $(ROOT)/sim/harness/common.h
UPP_G := -GFLASH_PROGRAM_CLKS=40 -GFLASH_SECTOR_ERASE_CLKS=3000 -GFLASH_ERASE_WINDOW_CLKS=200
$(BUILD)/upp/Vngage_mem: $(UPP_DEPS)
	mkdir -p $(BUILD)/upp && $(VERILATOR) $(VFLAGS) --top-module ngage_mem --Mdir $(BUILD)/upp -o Vngage_mem \
		$(UPP_G) $(UPP_RTL) $(ROOT)/sim/harness/upp_main.cpp
upp: $(BUILD)/upp/Vngage_mem
	$< $(RUNFLAGS) --seed $(SEED)

# The Bluetooth module against the reference model's (model/hw/ngage_bt_chip.h,
# the same header the model is built from), with the phone's own traffic
# first; its reset takes 50 clocks here and an inquiry's 1.28 s 200
BT_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/board/bt_module.sv
$(BUILD)/bt/Vbt_module: $(BT_RTL) $(ROOT)/sim/harness/bt_main.cpp $(ROOT)/sim/harness/common.h \
                        $(ROOT)/model/hw/ngage_bt_chip.h
	mkdir -p $(BUILD)/bt && $(VERILATOR) $(VFLAGS) --top-module bt_module --Mdir $(BUILD)/bt -o Vbt_module \
		-GRESET_CLKS=50 -GINQ_UNIT_CLKS=200 $(BT_RTL) $(ROOT)/sim/harness/bt_main.cpp
bt: $(BUILD)/bt/Vbt_module
	$< $(RUNFLAGS) --seed $(SEED) --session $(ROOT)/sim/harness/bt_session.txt

# The UPP interrupt controller and timers, each against a port of the model
$(BUILD)/intc/Vupp_intc: $(ROOT)/rtl/upp/upp_intc.sv $(ROOT)/sim/harness/intc_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/intc && $(VERILATOR) $(VFLAGS) --top-module upp_intc --Mdir $(BUILD)/intc -o Vupp_intc \
		$(ROOT)/rtl/upp/upp_intc.sv $(ROOT)/sim/harness/intc_main.cpp
intc: $(BUILD)/intc/Vupp_intc
	$< $(RUNFLAGS) --seed $(SEED)

$(BUILD)/timers/Vupp_timers: $(ROOT)/rtl/upp/upp_timers.sv $(ROOT)/sim/harness/timers_main.cpp $(ROOT)/sim/harness/common.h
	mkdir -p $(BUILD)/timers && $(VERILATOR) $(VFLAGS) --top-module upp_timers --Mdir $(BUILD)/timers -o Vupp_timers \
		$(ROOT)/rtl/upp/upp_timers.sv $(ROOT)/sim/harness/timers_main.cpp
timers: $(BUILD)/timers/Vupp_timers
	$< $(RUNFLAGS) --seed $(SEED)

# The UPP peripherals in the memory system, with the board devices they drive
# (sim/harness/periph_tb.sv), under a scripted CPU; replays the model's logs
# from model/.out when they are there
ADSP_RTL := $(ROOT)/rtl/board/ngage_aic23.v \
            $(ROOT)/rtl/board/ngage_adsp_bootstrap_tx.v \
            $(ROOT)/rtl/board/ngage_adsp_diagnostic.v \
            $(ROOT)/rtl/board/ngage_adsp.v \
            $(ROOT)/rtl/board/ngage_d550_boot.v \
            $(ROOT)/rtl/upp/upp_euart.v
PERIPH_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/board/tdp_ram.sv $(ROOT)/rtl/board/nor_flash.sv \
              $(ROOT)/rtl/board/lcd_panel.sv $(ROOT)/rtl/board/ngage_nem4_lcd.v \
              $(ROOT)/rtl/board/mmc_card.sv $(ROOT)/rtl/board/ngage_keys.sv \
              $(ROOT)/rtl/board/bt_module.sv \
              $(ROOT)/rtl/board/keypad_matrix.sv $(ROOT)/rtl/mem/bram32.sv $(ROOT)/rtl/mem/sdram.sv \
              $(ROOT)/rtl/mem/ddram_flash.sv $(ROOT)/rtl/upp/upp_bus.sv $(ROOT)/rtl/upp/wb_arb2.sv \
              $(ROOT)/rtl/upp/ngage_mem.sv $(ROOT)/rtl/upp/upp_fifo.sv $(ROOT)/rtl/upp/upp_intc.sv \
              $(ROOT)/rtl/upp/upp_timers.sv $(ROOT)/rtl/upp/upp_dma.sv $(ROOT)/rtl/upp/upp_mmc.sv \
              $(ROOT)/rtl/upp/upp_lcdif.sv $(ROOT)/rtl/upp/upp_uif.sv $(ROOT)/rtl/upp/upp_cbus.sv \
              $(ROOT)/rtl/upp/upp_gpio.v $(ROOT)/rtl/upp/upp_nem4_keypad.v \
              $(ROOT)/rtl/upp/upp_simif.v $(ROOT)/rtl/upp/upp_test_sim.v \
              $(ROOT)/rtl/upp/upp_mdi.v $(ROOT)/rtl/upp/upp_mdi_peer.v \
              $(ROOT)/rtl/upp/upp_pcm.v $(ROOT)/rtl/upp/upp_dsp_pcm.v $(ROOT)/rtl/upp/upp_periph.sv $(ROOT)/rtl/mister/rtc_wall.sv \
              $(ADSP_RTL) $(ROOT)/sim/harness/periph_tb.sv
$(BUILD)/periph/Vperiph_tb: $(PERIPH_RTL) $(ROOT)/sim/harness/periph_main.cpp $(ROOT)/sim/harness/common.h \
                            $(ROOT)/sim/harness/sdram_model.h $(ROOT)/sim/harness/ddram_model.h
	mkdir -p $(BUILD)/periph && $(VERILATOR) $(VFLAGS) --top-module periph_tb --Mdir $(BUILD)/periph -o Vperiph_tb \
		$(PERIPH_RTL) $(ROOT)/sim/harness/periph_main.cpp
# a real game card's image (tools/mkcard.py; local data, never committed): the
# bench reads its first sectors when the file is there
MMC_CARD ?= $(ROOT)/model/.out/cards/sonicn.mmc
periph: $(BUILD)/periph/Vperiph_tb | $(OUT)
	$< $(RUNFLAGS) --seed $(SEED) --out $(OUT) --model-out $(ROOT)/model/.out --card $(MMC_CARD)

# The CS1 save file (rtl/mister/flash_save.sv) with the memory system: mount,
# marks, write-back (sim/harness/save_tb.sv)
SAVE_RTL := $(ROOT)/rtl/board/sdp_ram.sv $(ROOT)/rtl/board/nor_flash.sv $(ROOT)/rtl/mem/bram32.sv \
            $(ROOT)/rtl/mem/sdram.sv $(ROOT)/rtl/mem/ddram_flash.sv $(ROOT)/rtl/upp/upp_bus.sv \
            $(ROOT)/rtl/upp/wb_arb2.sv $(ROOT)/rtl/upp/ngage_mem.sv $(ROOT)/rtl/mister/flash_save.sv \
            $(ROOT)/sim/harness/save_tb.sv
$(BUILD)/save/Vsave_tb: $(SAVE_RTL) $(ROOT)/sim/harness/save_main.cpp $(ROOT)/sim/harness/common.h \
                        $(ROOT)/sim/harness/sdram_model.h $(ROOT)/sim/harness/ddram_model.h
	mkdir -p $(BUILD)/save && $(VERILATOR) $(VFLAGS) --top-module save_tb --Mdir $(BUILD)/save -o Vsave_tb \
		$(SAVE_RTL) $(ROOT)/sim/harness/save_main.cpp
save: $(BUILD)/save/Vsave_tb
	$< $(RUNFLAGS) --seed $(SEED)

$(BUILD)/pmm-save/Vsave_tb: $(SAVE_RTL) $(ROOT)/sim/harness/save_main.cpp $(ROOT)/sim/harness/common.h \
                            $(ROOT)/sim/harness/sdram_model.h $(ROOT)/sim/harness/ddram_model.h
	mkdir -p $(BUILD)/pmm-save && $(VERILATOR) $(VFLAGS) --top-module save_tb -GPMM=1 --Mdir $(BUILD)/pmm-save -o Vsave_tb \
		$(SAVE_RTL) $(ROOT)/sim/harness/save_main.cpp
pmm-save: $(BUILD)/pmm-save/Vsave_tb
	$< $(RUNFLAGS) --seed $(SEED) --pmm
	$< $(RUNFLAGS) --seed $(SEED) --pmm --nem4

# The whole core: NGage.sv with the board devices; hps_io, the PLL and
# video_mixer stood in for (sim/stubs); the framework's video_freak (the
# aspect ratio, the vertical crop and the integer scaling) as it is
TOP_RTL := $(ROOT)/sim/stubs/hps_io.sv $(ROOT)/sim/stubs/pll.sv $(ROOT)/sim/stubs/video_mixer.sv \
           $(ROOT)/sys/video_freak.sv $(ROOT)/sys/math.sv \
           $(shell sed -n 's/^set_global_assignment -name \(SYSTEM\)*VERILOG_FILE //p' $(ROOT)/files.qip | sed 's|^|$(ROOT)/|') \

$(BUILD)/top/Vemu: $(TOP_RTL) $(ROOT)/files.qip $(ROOT)/sim/harness/top_main.cpp $(ROOT)/sim/harness/common.h \
                   $(ROOT)/sim/harness/sdram_model.h $(ROOT)/sim/harness/ddram_model.h
	mkdir -p $(BUILD)/top && cd $(ROOT) && $(VERILATOR) $(VFLAGS) $(VEXTRA) --timescale 1ns/1ps --pins-inout-enables \
		--top-module emu -DNGAGE_DEBUG=1 --Mdir $(BUILD)/top -o Vemu -I$(ROOT) -I$(ROOT)/sim/stubs \
		$(TOP_RTL) $(ROOT)/sim/harness/top_main.cpp
top: $(BUILD)/top/Vemu | $(OUT)
	cd $(ROOT) && $< $(RUNFLAGS) --out $(OUT)
	cd $(ROOT) && sim/harness/hps_read_test.sh $(BUILD)/top

# The firmware on the whole core (sim/harness/coreboot_main.cpp): not in
# `make test`, it needs the flash images (tools/mkimage.py; firmware, never
# committed) and runs for hours. CORE_THREADS > 1 builds a multithreaded model
# (slower here: 4 threads ran at a quarter of the single-threaded speed). The
# model is built --savable: the bench's --save/--save-at and --restore keep a
# snapshot (the firmware at its idle screen, say) so later runs skip the boot.
# Speed: an M2 Max runs it at about 565 k clocks/s with --x-assign fast
# --x-initial fast and -O3, a Ryzen 5950X at 250-290 k with the defaults.
CORE_CS0     ?= $(ROOT)/build/coreboot/cs0.bin
CORE_CS1     ?= $(ROOT)/build/coreboot/cs1.bin
CORE_MMC     ?=
CORE_ARGS    ?= --cycles 1000000000
CORE_OUT     ?= $(BUILD)/coreboot/out
CORE_THREADS ?= 1
$(BUILD)/coreboot/Vemu: $(TOP_RTL) $(ROOT)/files.qip $(ROOT)/sim/harness/coreboot_main.cpp $(ROOT)/sim/harness/coreboot.vlt \
                        $(ROOT)/sim/harness/core_regs_tap.sv \
                        $(ROOT)/sim/harness/common.h $(ROOT)/sim/harness/sdram_model.h $(ROOT)/sim/harness/ddram_model.h $(ROOT)/sim/harness/snapshot.h
	mkdir -p $(BUILD)/coreboot && cd $(ROOT) && $(VERILATOR) $(VFLAGS) $(VEXTRA) --timescale 1ns/1ps --pins-inout-enables --savable \
		$(if $(filter-out 1,$(CORE_THREADS)),--threads $(CORE_THREADS)) \
		--top-module emu -DNGAGE_DEBUG=1 --Mdir $(BUILD)/coreboot -o Vemu -I$(ROOT) -I$(ROOT)/sim/stubs \
		$(ROOT)/sim/harness/coreboot.vlt $(TOP_RTL) $(ROOT)/sim/harness/core_regs_tap.sv $(ROOT)/sim/harness/coreboot_main.cpp
# The LFFS sector copy on the whole core (sim/harness/flashcopy.S, no
# firmware needed): the CPU copies C: sectors out of the flash window with
# Mem::Copy's sequence through the real memory side; --check-flash compares
# every flash read beat with the image. VEXTRA chooses the CPU as for
# coreboot; FC_ARGS adds bench options
# (e.g. --ddr-lat 6:30 --ddr-busy 20 --buslog FILE).
FC_DIR  ?= $(BUILD)/flashcopy
FC_ARGS ?=
$(FC_DIR)/cs0.bin: $(ROOT)/sim/harness/flashcopy.S $(ROOT)/sim/cpu/tests/mem_copy.inc $(ROOT)/sim/harness/flashcopy_images.py
	mkdir -p $(FC_DIR)
	arm-none-eabi-as -mcpu=arm9tdmi -mfloat-abi=soft -I$(ROOT)/sim/cpu/tests -o $(FC_DIR)/flashcopy.o $<
	arm-none-eabi-ld -Ttext=0 -Tdata=0x0A300000 -o $(FC_DIR)/flashcopy.elf $(FC_DIR)/flashcopy.o
	arm-none-eabi-objcopy -O binary -j .text $(FC_DIR)/flashcopy.elf $(FC_DIR)/flashcopy.bin
	python3 $(ROOT)/sim/harness/flashcopy_images.py $(FC_DIR)/flashcopy.bin $@ $(FC_DIR)/cs1.bin
flashcopy: $(BUILD)/coreboot/Vemu $(FC_DIR)/cs0.bin
	cd $(ROOT) && $< $(RUNFLAGS) --cs0 $(FC_DIR)/cs0.bin --cs1 $(FC_DIR)/cs1.bin --out $(FC_DIR) \
		--check-flash --until '#END' --cycles 400000000 --progress 0 $(FC_ARGS) | tee $(FC_DIR)/run.log
	cat $(FC_DIR)/kern.log
	grep -q ' 0 mismatch(es)' $(FC_DIR)/run.log && grep -q ' 00000000 failures' $(FC_DIR)/kern.log

# What a data line fill costs on the whole core (sim/harness/dfill.S, no
# firmware needed): loops of loads timed with UPP timer 1 through the real
# cache, bus and SDRAM controller. VEXTRA sets the cache sizes, e.g.
# BUILD=$(BUILD)-d16 VEXTRA=-GDCACHE_SIZE=16384 for a 16 KB D-cache.
DF_DIR ?= $(BUILD)/dfill
$(DF_DIR)/cs0.bin: $(ROOT)/sim/harness/dfill.S $(ROOT)/sim/harness/flashcopy_images.py
	mkdir -p $(DF_DIR)
	arm-none-eabi-as -mcpu=arm9tdmi -mfloat-abi=soft -o $(DF_DIR)/dfill.o $<
	arm-none-eabi-ld -Ttext=0 -o $(DF_DIR)/dfill.elf $(DF_DIR)/dfill.o
	arm-none-eabi-objcopy -O binary -j .text $(DF_DIR)/dfill.elf $(DF_DIR)/dfill.bin
	python3 $(ROOT)/sim/harness/flashcopy_images.py $(DF_DIR)/dfill.bin $@ $(DF_DIR)/cs1.bin
.PHONY: dfill
dfill: $(BUILD)/coreboot/Vemu $(DF_DIR)/cs0.bin
	cd $(ROOT) && $< $(RUNFLAGS) --cs0 $(DF_DIR)/cs0.bin --cs1 $(DF_DIR)/cs1.bin --out $(DF_DIR) \
		--until '#END' --cycles 100000000 --progress 0 > $(DF_DIR)/run.log
	cat $(DF_DIR)/kern.log
	grep -q 'dfill: done' $(DF_DIR)/kern.log

# Exercise the firmware bench's HPS adapter without firmware images.
hps-read-test: $(BUILD)/coreboot/Vemu
	cd $(ROOT) && sim/harness/hps_read_test.sh $(BUILD)/coreboot

coreboot: $(BUILD)/coreboot/Vemu
	mkdir -p $(CORE_OUT)
	cd $(ROOT) && $< $(RUNFLAGS) --cs0 $(CORE_CS0) --cs1 $(CORE_CS1) $(if $(CORE_MMC),--mmc $(CORE_MMC)) --out $(CORE_OUT) $(CORE_ARGS)
