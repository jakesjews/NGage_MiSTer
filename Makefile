VERILATOR ?= verilator

# Modules linted as tops of their own, so that a block is checked with its
# default parameters even where the shell ties ports off.
LINT_TOPS := emu lcd_panel video_out keypad_matrix nor_flash mmc_card ngage_input ddram_loader lcd_testgen dbg_trace dbg_sti \
             sdram ddram_flash upp_bus ngage_mem wb_selftest flash_save rtc_wall \
             upp_periph upp_intc upp_timers upp_dma upp_mmc upp_lcdif upp_uif upp_cbus upp_haudio wb_arb2

.PHONY: help lint lint-prepare test clean cpu-gen cpu-gen-check standin standin-check image-check

help:
	@echo "make lint   Lint the RTL with Verilator (-Wall)"
	@echo "make test   Build and run every Verilator bench in sim/ (one at a time)"
	@echo "make -C sim <bench>   One bench: lcd video keypad flash mmc sdram sdram-faults ddrflash upp"
	@echo "                      intc timers haudio periph save top"
	@echo "make clean  Remove sim/build"
	@echo "make cpu-gen        Regenerate rtl/cpu/arm925t_gen.v (tools/gen_cpu.sh, needs sv2v)"
	@echo "make cpu-gen-check  Check that rtl/cpu/arm925t_gen.v matches its sources"
	@echo "make -C sim/cpu     CPU tests (see sim/cpu/Makefile)"
	@echo "make standin        Rebuild tools/standin (the NOS stand-in binaries mkimage.py puts in CS0)"
	@echo "make standin-check  Check that tools/standin matches model/nos-stub"
	@echo "make image-check CS0=.. CS1=..  Check tools/mkimage.py against the model's own patcher"

lint: lint-prepare
	@for t in $(LINT_TOPS); do \
		echo "lint $$t"; \
		$(VERILATOR) --lint-only -Wall --top-module $$t -f lint/rtl.f || exit 1; \
	done

lint-prepare:
	@mkdir -p lint/gen
	@printf '`define BUILD_DATE "lint"\n' > lint/gen/build_id.v

test:
	$(MAKE) -C sim test

clean:
	$(MAKE) -C sim clean

# The CPU netlist Quartus compiles is generated from rtl/cpu (sv2v); the
# committed copy must match its sources.
cpu-gen:
	tools/gen_cpu.sh

cpu-gen-check:
	@tmp=$$(mktemp); \
	if tools/gen_cpu.sh $$tmp && cmp -s $$tmp rtl/cpu/arm925t_gen.v; then \
		rm -f $$tmp; echo "rtl/cpu/arm925t_gen.v is current"; \
	else \
		rm -f $$tmp; echo "rtl/cpu/arm925t_gen.v is out of date: run make cpu-gen"; exit 1; \
	fi

# The NOS stand-in binaries that tools/mkimage.py writes into CS0 (model
# shortcut, model/rom-patches.txt), built as model/build.sh builds them (needs
# arm-none-eabi-gcc) from the committed model/nos-stub, so that the committed
# binaries always go with committed sources; tools/build_standin.sh builds
# from any directory.
standin:
	@tmp=$$(mktemp -d); git archive HEAD model/nos-stub | tar -x -C $$tmp && \
	tools/build_standin.sh $$tmp/model/nos-stub tools/standin && chmod 644 tools/standin/*.bin; s=$$?; rm -rf $$tmp; exit $$s

standin-check:
	@tmp=$$(mktemp -d); git archive HEAD model/nos-stub | tar -x -C $$tmp; \
	if tools/build_standin.sh $$tmp/model/nos-stub $$tmp/out >/dev/null 2>&1 && \
	   cmp -s $$tmp/out/nos-stub.bin tools/standin/nos-stub.bin && cmp -s $$tmp/out/nos-dll.bin tools/standin/nos-dll.bin; then \
		rm -rf $$tmp; echo "tools/standin is current"; \
	else \
		rm -rf $$tmp; echo "tools/standin is out of date: run make standin"; exit 1; \
	fi

# mkimage.py against the reference model's patcher on a pair of images
# (default: the model's own; the firmware is not in the repository)
CS0 ?= research/firmware/images/nor/rh29-4.60-cs0-model.bin
CS1 ?= research/firmware/images/nor/rh29-4.60-cs1.bin
image-check:
	tools/patchcheck.sh $(CS0) $(CS1)
