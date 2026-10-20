VERILATOR ?= verilator

# Modules linted as tops of their own, so that a block is checked with its
# default parameters even where the shell ties ports off.
LINT_TOPS := lcd_panel video_out keypad_matrix nor_flash

.PHONY: help lint lint-prepare test clean

help:
	@echo "make lint   Lint the RTL with Verilator (-Wall)"
	@echo "make test   Build and run every Verilator bench in sim/ (one at a time)"
	@echo "make -C sim <bench>   One bench: lcd video keypad flash mmc top"
	@echo "make clean  Remove sim/build"

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
