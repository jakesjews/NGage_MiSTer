# SPDX-License-Identifier: GPL-3.0-or-later
#
# CPU bench: directed ARM/Thumb tests run on the arm925t RTL (Verilator) and
# on QEMU's ti925t, with the results compared. docs/CPU.md describes it.
#
#   make bins      assemble the tests (needs arm-none-eabi binutils)
#   make model     build the Verilator model (RTL=gen: rtl/cpu/arm925t_gen.v,
#                  the default; RTL=sv: the SystemVerilog sources)
#   make run       run every test on the model, at several bus latencies
#   make qemu      run the tests on QEMU (needs qemu-system-arm and GDB)
#   make diff      compare signatures and traces of RTL and QEMU
#   make remote    bins here, then model and run on $(REMOTE) (the Verilator
#                  machine), and fetch the results back
#   make all       bins, remote, qemu, diff
#   make T=alu ... restrict to some tests
#
# Test tags (lines in the .S file):
#   @@ qemu: no        the test needs the bench (bench registers, interrupts,
#                      high RAM) or relies on ARM925T behaviour QEMU lacks
#   @@ trace: no       compare only the signature with QEMU, not the trace
#   @@ bench: ARGS     extra arguments for the bench (Vtb_cpu)
ROOT      := $(abspath ../..)
HERE      := $(ROOT)/sim/cpu
BUILD     := $(HERE)/build
RTL       ?= gen
VERILATOR ?= verilator
CROSS     ?= arm-none-eabi-
QEMU      ?= qemu-system-arm
GDB       ?= $(CROSS)gdb
PY        := python3 -I
REMOTE    ?= ubuntu
RDIR      ?= dev/mister/ngage-cpu
LATS      ?= 0:0 0:3 2:9
JOBS      ?= 8
SHELL     := bash

ALL_TESTS := $(sort $(basename $(notdir $(filter-out %/crt0.S,$(wildcard $(HERE)/tests/*.S)))))
T         ?= $(ALL_TESTS)
TB        := $(BUILD)/tests
MODEL_DIR := $(BUILD)/obj-$(RTL)
MODEL     := $(MODEL_DIR)/Vtb_cpu

ASFLAGS := -mcpu=arm9tdmi -mfloat-abi=soft -I $(HERE)/tests

.PHONY: all bins model run qemu diff remote clean
.SECONDARY:
all: bins remote qemu diff

# ---------------------------------------------------------------- tests
bins: $(foreach t,$(T),$(TB)/$(t).bin $(TB)/$(t).lst)

$(TB)/crt0.o: $(HERE)/tests/crt0.S $(HERE)/tests/test.inc
	@mkdir -p $(TB)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/%.o: $(HERE)/tests/%.S $(HERE)/tests/test.inc
	@mkdir -p $(TB)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/%.elf: $(TB)/%.o $(TB)/crt0.o $(HERE)/tests/link.ld
	$(CROSS)ld -T $(HERE)/tests/link.ld -o $@ $(TB)/crt0.o $<
$(TB)/%.bin: $(TB)/%.elf
	$(CROSS)objcopy -O binary $< $@
$(TB)/%.lst: $(TB)/%.elf
	$(CROSS)objdump -d $< > $@

# ---------------------------------------------------------------- model
VFLAGS := --cc --exe --build -j $(JOBS) -O3 --x-assign unique --x-initial unique \
          -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-ASSIGNIN \
          --top-module tb_cpu -CFLAGS "-O2 -std=c++17"
ZAP_SV  := $(wildcard $(ROOT)/rtl/cpu/zap/*.sv)
ifeq ($(RTL),sv)
RTL_SRC := +incdir+$(ROOT)/rtl/cpu/zap $(ROOT)/rtl/cpu/arm925t.sv $(ZAP_SV)
RTL_DEP := $(ROOT)/rtl/cpu/arm925t.sv $(ZAP_SV) $(wildcard $(ROOT)/rtl/cpu/zap/*.svh)
else
RTL_SRC := $(ROOT)/rtl/cpu/arm925t_gen.v
RTL_DEP := $(RTL_SRC)
endif

model: $(MODEL)
$(MODEL): $(RTL_DEP) $(HERE)/tb/tb_cpu.sv $(HERE)/tb/main.cpp
	@mkdir -p $(MODEL_DIR)
	$(VERILATOR) $(VFLAGS) --Mdir $(MODEL_DIR) -o Vtb_cpu $(RTL_SRC) \
		$(HERE)/tb/tb_cpu.sv $(HERE)/tb/main.cpp

# ---------------------------------------------------------------- RTL runs
# Every test at every latency setting; the first setting's signature and
# trace are kept for the comparison with QEMU.
tag = $(shell sed -n 's/^@@ $(2): *//p' $(HERE)/tests/$(1).S)

run: $(MODEL)
	@mkdir -p $(BUILD)/rtl
	@pass=0; fail=0; failed=""; \
	for t in $(T); do \
		bin=$(TB)/$$t.bin; \
		[ -f $$bin ] || { echo "$$t: no binary (make bins)"; fail=$$((fail+1)); failed="$$failed $$t"; continue; }; \
		extra=$$(sed -n 's/^@@ bench: *//p' $(HERE)/tests/$$t.S); \
		first=1; \
		for lat in $(LATS); do \
			if [ $$first = 1 ]; then keep="--sig $(BUILD)/rtl/$$t.sig --trace $(BUILD)/rtl/$$t.trace"; else keep=""; fi; \
			log=$(BUILD)/rtl/$$t.$${lat/:/-}.log; \
			if $(MODEL) --bin $$bin --lat $$lat --quiet $$keep $$extra > $$log 2>&1; then \
				pass=$$((pass+1)); \
			else \
				fail=$$((fail+1)); failed="$$failed $$t@$$lat"; \
				echo "$$t (lat $$lat): $$(tail -1 $$log)"; \
			fi; \
			first=0; \
		done; \
	done; \
	echo "RTL ($(RTL)): $$pass passed, $$fail failed$${failed:+:$$failed}"; \
	[ $$fail = 0 ]

# ---------------------------------------------------------------- QEMU runs
qemu: bins
	@mkdir -p $(BUILD)/qemu
	@n=0; skip=0; bad=0; \
	for t in $(T); do \
		if grep -q '^@@ qemu: *no' $(HERE)/tests/$$t.S; then skip=$$((skip+1)); continue; fi; \
		tr=1; grep -q '^@@ trace: *no' $(HERE)/tests/$$t.S && tr=0; \
		if QEMU=$(QEMU) GDB=$(GDB) $(HERE)/qemu/run.sh $(TB)/$$t.bin $(BUILD)/qemu/$$t $$tr; then n=$$((n+1)); \
		else bad=$$((bad+1)); fi; \
	done; \
	echo "QEMU: $$n run, $$skip skipped (qemu: no), $$bad failed to run"; \
	[ $$bad = 0 ]

# ---------------------------------------------------------------- compare
diff:
	@ok=0; bad=0; badl=""; \
	for t in $(T); do \
		[ -f $(BUILD)/qemu/$$t.sig ] || continue; \
		r=0; \
		$(PY) $(HERE)/tools/cmp_sig.py --name $$t $(BUILD)/rtl/$$t.sig $(BUILD)/qemu/$$t.sig || r=1; \
		if [ -f $(BUILD)/qemu/$$t.qlog ]; then \
			$(PY) $(HERE)/tools/cmp_trace.py --name $$t $(BUILD)/rtl/$$t.trace $(BUILD)/qemu/$$t.qlog || r=1; \
		fi; \
		if [ $$r = 0 ]; then ok=$$((ok+1)); else bad=$$((bad+1)); badl="$$badl $$t"; fi; \
	done; \
	echo "RTL vs QEMU: $$ok agree, $$bad differ$${badl:+:$$badl}"; \
	[ $$bad = 0 ]

# ---------------------------------------------------------------- remote
# The Verilator machine has no ARM toolchain: binaries are built here.
remote: bins
	ssh $(REMOTE) 'mkdir -p $(RDIR)/rtl/cpu $(RDIR)/sim/cpu'
	rsync -a --delete $(ROOT)/rtl/cpu/ $(REMOTE):$(RDIR)/rtl/cpu/
	rsync -a --delete --exclude 'build/obj-*' --exclude build/rtl --exclude build/qemu \
		$(HERE)/ $(REMOTE):$(RDIR)/sim/cpu/
	ssh $(REMOTE) 'make -C $(RDIR)/sim/cpu RTL=$(RTL) T="$(T)" LATS="$(LATS)" run' || st=$$?; \
	mkdir -p $(BUILD)/rtl; \
	rsync -a $(REMOTE):$(RDIR)/sim/cpu/build/rtl/ $(BUILD)/rtl/; \
	exit $${st:-0}

clean:
	rm -rf $(BUILD)
