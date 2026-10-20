VERILATOR ?= verilator

# Modules linted as tops of their own, so that a block is checked with its
# default parameters even where the shell ties ports off.
LINT_TOPS := emu lcd_panel video_out keypad_matrix nor_flash mmc_card ngage_input ddram_loader lcd_testgen

.PHONY: help lint lint-prepare test clean cpu-gen cpu-gen-check

help:
	@echo "make lint   Lint the RTL with Verilator (-Wall)"
	@echo "make test   Build and run every Verilator bench in sim/ (one at a time)"
	@echo "make -C sim <bench>   One bench: lcd video keypad flash mmc top"
	@echo "make clean  Remove sim/build"
	@echo "make cpu-gen        Regenerate rtl/cpu/arm925t_gen.v (tools/gen_cpu.sh, needs sv2v)"
	@echo "make cpu-gen-check  Check that rtl/cpu/arm925t_gen.v matches its sources"
	@echo "make -C sim/cpu     CPU tests (see sim/cpu/Makefile)"

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
