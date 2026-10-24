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
#   VEXTRA=..      extra Verilator options, e.g. -GICACHE_WAYS=1 or
#                  -GDCACHE_WAYS=1 for a direct-mapped cache (with
#                  MODEL_DIR=... for a model of its own)
#   RAND_SEEDS=..  the random tests rand<seed>, trand<seed> (Thumb) and
#                  crand/ctrand<seed> (caches on), tools/gen_random.py
#   gba_*          jsmolka/gba-tests (ext/gba-tests), translated by
#                  tools/fasm2gas.py; GBA_SKIP_* lists the tests left out
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
CORE      ?= ZAP
RESULTS   ?= $(BUILD)/$(if $(filter ZAP,$(CORE)),rtl,rtl-$(CORE))
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

RAND_SEEDS ?= 1 2 3 4 5 6 7 8
RAND_TESTS := $(foreach s,$(RAND_SEEDS),rand$(s) trand$(s) crand$(s) ctrand$(s))
# jsmolka/gba-tests (ext/gba-tests, tools/fasm2gas.py); docs/CPU.md says
# why these are skipped. gba_arm/gba_thumb run on the RTL only; the _q
# versions also leave out the unaligned word accesses QEMU aborts on, and
# are compared with QEMU.
GBA_TESTS := gba_arm gba_thumb gba_arm_q gba_thumb_q
GBA_SKIP_arm    ?= 224 225 234 235 356 362 408 409 510 513 514 515 522 523 524 \
                   525 526 527 528 529 530 531 532
GBA_SKIP_thumb  ?= 211 212 219 227 228 229 230 231
GBA_QSKIP_arm   := 354 355 407 452 508
GBA_QSKIP_thumb := 204 216 221 225 233
ALL_TESTS := $(sort $(basename $(notdir $(filter-out %/crt0.S,$(wildcard $(HERE)/tests/*.S))))) \
             $(RAND_TESTS) $(GBA_TESTS)
T         ?= $(ALL_TESTS)
TB        := $(BUILD)/tests
MODEL_DIR := $(BUILD)/obj-$(RTL)$(if $(filter ZAP,$(CORE)),,-$(CORE))
MODEL     := $(MODEL_DIR)/Vtb_cpu

ASFLAGS := -mcpu=arm9tdmi -mfloat-abi=soft -I $(HERE)/tests

.PHONY: all bins model run qemu diff remote boot boot-prep boot-model clean arm9-execute arm9v2-frontend arm9v2-decode arm9v2-execute
.SECONDARY:
all: bins remote qemu diff

# Standalone new-pipeline datapath checks; no ARM test rebuild or QEMU.
arm9-execute:
	$(HERE)/arm9/run.sh

arm9v2-execute:
	$(HERE)/arm9v2/execute_leaves.sh
	$(HERE)/arm9v2/execute.sh
	$(HERE)/arm9v2/execute_cache.sh

arm9v2-decode:
	$(HERE)/arm9v2/decode.sh
	$(HERE)/arm9v2/decode_cache.sh

arm9v2-frontend:
	$(HERE)/arm9v2/run.sh
	$(HERE)/arm9v2/cache.sh

# ---------------------------------------------------------------- tests
bins: $(foreach t,$(T),$(TB)/$(t).bin $(TB)/$(t).lst)

$(TB)/crt0.o: $(HERE)/tests/crt0.S $(wildcard $(HERE)/tests/*.inc)
	@mkdir -p $(TB)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/%.o: $(HERE)/tests/%.S $(wildcard $(HERE)/tests/*.inc)
	@mkdir -p $(TB)
	$(CROSS)as $(ASFLAGS) -o $@ $<
# random tests (tools/gen_random.py), generated into the build directory
$(TB)/rand%.S: $(HERE)/tools/gen_random.py
	@mkdir -p $(TB)
	$(PY) $< --seed $* > $@
$(TB)/rand%.o: $(TB)/rand%.S $(wildcard $(HERE)/tests/*.inc)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/trand%.S: $(HERE)/tools/gen_random.py
	@mkdir -p $(TB)
	$(PY) $< --thumb --seed $* > $@
$(TB)/crand%.S: $(HERE)/tools/gen_random.py
	@mkdir -p $(TB)
	$(PY) $< --cache --seed $* > $@
$(TB)/ctrand%.S: $(HERE)/tools/gen_random.py
	@mkdir -p $(TB)
	$(PY) $< --cache --thumb --seed $* > $@
$(TB)/crand%.o: $(TB)/crand%.S $(wildcard $(HERE)/tests/*.inc)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/ctrand%.o: $(TB)/ctrand%.S $(wildcard $(HERE)/tests/*.inc)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/trand%.o: $(TB)/trand%.S $(wildcard $(HERE)/tests/*.inc)
	$(CROSS)as $(ASFLAGS) -o $@ $<
# gba-tests, translated into the build directory
GBA_DEP := $(HERE)/tools/fasm2gas.py $(wildcard $(HERE)/ext/gba-tests/*/*.asm) $(HERE)/Makefile
$(TB)/gba_arm.S $(TB)/gba_thumb.S: $(TB)/gba_%.S: $(GBA_DEP)
	@mkdir -p $(TB)
	$(PY) $< --set $* $(HERE)/ext/gba-tests --tag "qemu: no" --skip $(GBA_SKIP_$*) > $@
$(TB)/gba_arm_q.S $(TB)/gba_thumb_q.S: $(TB)/gba_%_q.S: $(GBA_DEP)
	@mkdir -p $(TB)
	$(PY) $< --set $* $(HERE)/ext/gba-tests --skip $(GBA_SKIP_$*) $(GBA_QSKIP_$*) > $@
$(TB)/gba_%.o: $(TB)/gba_%.S $(wildcard $(HERE)/tests/*.inc)
	$(CROSS)as $(ASFLAGS) -o $@ $<
$(TB)/%.elf: $(TB)/%.o $(TB)/crt0.o $(HERE)/tests/link.ld
	$(CROSS)ld -T $(HERE)/tests/link.ld -o $@ $(TB)/crt0.o $<
$(TB)/%.bin: $(TB)/%.elf
	$(CROSS)objcopy -O binary $< $@
$(TB)/%.lst: $(TB)/%.elf
	$(CROSS)objdump -d $< > $@

# ---------------------------------------------------------------- model
VFLAGS := --cc --exe --build --assert -j $(JOBS) -O3 --x-assign unique --x-initial unique \
          -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-ASSIGNIN \
          --top-module tb_cpu -GCORE=\"$(CORE)\" -CFLAGS "-O2 -std=c++17" $(VEXTRA)
ARM9_SV := $(wildcard $(ROOT)/rtl/cpu/arm9/*.sv) $(wildcard $(ROOT)/rtl/cpu/arm9v2/*.sv)
ZAP_SV  := $(wildcard $(ROOT)/rtl/cpu/zap/*.sv)
ifeq ($(RTL),sv)
RTL_SRC := +incdir+$(ROOT)/rtl/cpu/zap $(ROOT)/rtl/cpu/arm925t.sv $(ARM9_SV) $(ZAP_SV)
RTL_DEP := $(ROOT)/rtl/cpu/arm925t.sv $(ARM9_SV) $(ZAP_SV) $(wildcard $(ROOT)/rtl/cpu/zap/*.svh)
else
RTL_SRC := $(ROOT)/rtl/cpu/arm925t_gen.v
RTL_DEP := $(RTL_SRC)
endif

model: $(MODEL)
$(MODEL): $(RTL_DEP) $(HERE)/tb/tb_cpu.sv $(HERE)/tb/main.cpp $(HERE)/tb/ngage.h
	@mkdir -p $(MODEL_DIR)
	$(VERILATOR) $(VFLAGS) --Mdir $(MODEL_DIR) -o Vtb_cpu $(RTL_SRC) \
		$(HERE)/tb/tb_cpu.sv $(HERE)/tb/main.cpp

# ---------------------------------------------------------------- RTL runs
# Every test at every latency setting; the first setting's signature and
# trace are kept for the comparison with QEMU.
tag = $(shell sed -n 's/^@@ $(2): *//p' $(HERE)/tests/$(1).S)

run: $(MODEL)
	@mkdir -p $(RESULTS)
	@pass=0; fail=0; failed=""; \
	for t in $(T); do \
		bin=$(TB)/$$t.bin; \
		[ -f $$bin ] || { echo "$$t: no binary (make bins)"; fail=$$((fail+1)); failed="$$failed $$t"; continue; }; \
		src=$(HERE)/tests/$$t.S; [ -f $$src ] || src=$(TB)/$$t.S; \
		extra=$$(sed -n 's/^@@ bench: *//p' $$src); \
		first=1; \
		for lat in $(LATS); do \
			if [ $$first = 1 ]; then keep="--sig $(RESULTS)/$$t.sig --trace $(RESULTS)/$$t.trace"; else keep=""; fi; \
			log=$(RESULTS)/$$t.$${lat/:/-}.log; \
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
		src=$(HERE)/tests/$$t.S; [ -f $$src ] || src=$(TB)/$$t.S; \
		if grep -q '^@@ qemu: *no' $$src; then skip=$$((skip+1)); continue; fi; \
		tr=1; grep -q '^@@ trace: *no' $$src && tr=0; \
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
		$(PY) $(HERE)/tools/cmp_sig.py --name $$t $(RESULTS)/$$t.sig $(BUILD)/qemu/$$t.sig || r=1; \
		if [ -f $(BUILD)/qemu/$$t.qlog ]; then \
			$(PY) $(HERE)/tools/cmp_trace.py --name $$t --bin $(TB)/$$t.bin \
				$(RESULTS)/$$t.trace $(BUILD)/qemu/$$t.qlog || r=1; \
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
		--exclude build/boot $(HERE)/ $(REMOTE):$(RDIR)/sim/cpu/
	ssh $(REMOTE) 'make -C $(RDIR)/sim/cpu RTL=$(RTL) T="$(T)" LATS="$(LATS)" run' || st=$$?; \
	mkdir -p $(BUILD)/rtl; \
	rsync -a $(REMOTE):$(RDIR)/sim/cpu/build/rtl/ $(BUILD)/rtl/; \
	exit $${st:-0}

# ---------------------------------------------------------------- boot
# The real boot code on the RTL (tb/ngage.h: the reference model's memory
# map and devices) and on the reference model, both on $(REMOTE), from the
# same flash images, with their register and CBUS logs compared.
#   make boot-prep    images from git HEAD's model files (NOS stand-in
#                     assembled here, patches applied as model/hw does)
#   make boot-model   the model, built on $(REMOTE) from git HEAD
#                     (model/build_linux.sh) and run on those images, with
#                     every device access in trace.log (model/trace_plugin.c;
#                     MODEL_TRACE=start=N,count=M traces instructions too)
#   make boot         the RTL on the same images, then the comparisons:
#                     register and CBUS logs, and every device access
#                     (boot/cmp_dev.py)
BOOT_CS0    ?= $(ROOT)/research/firmware/images/nor/rh29-4.60-cs0-model.bin
BOOT_CS1    ?= $(ROOT)/research/firmware/images/nor/rh29-4.60-cs1.bin
BOOT_CYCLES ?= 2700000000
BOOT_ARGS   ?=
BOOT        := $(BUILD)/boot
HEADM       := $(BOOT)/head
MDIR        ?= dev/mister/ngage-model
MODEL_SECS  ?= 120
MODEL_TRACE ?= start=0,count=100000000000,insns=0
ARMAS       := $(CROSS)as -march=armv4t
boot-prep:
	@mkdir -p $(BOOT)
	rm -rf $(HEADM) && mkdir -p $(HEADM)/.build
	git -C $(ROOT) archive HEAD model | tar -x -C $(HEADM) --strip-components=1
	$(ARMAS) -o $(HEADM)/.build/nos_stub.o $(HEADM)/nos-stub/nos_stub.S
	$(CROSS)ld -Ttext=0x5149E4D4 -o $(HEADM)/.build/nos_stub.elf $(HEADM)/.build/nos_stub.o
	$(CROSS)objcopy -O binary $(HEADM)/.build/nos_stub.elf $(HEADM)/.build/nos-stub.bin
	$(ARMAS) -o $(HEADM)/.build/nos_dll.o $(HEADM)/nos-stub/nos_dll.S
	$(CROSS)gcc -march=armv4t -marm -mthumb-interwork -Os -std=gnu11 -ffreestanding \
		-fno-builtin -fno-pic -fno-common -fno-unwind-tables -fno-asynchronous-unwind-tables \
		-c -o $(HEADM)/.build/nos_isi.o $(HEADM)/nos-stub/nos_isi.c
	$(CROSS)ld -T $(HEADM)/nos-stub/nos_dll.ld -o $(HEADM)/.build/nos_dll.elf $(HEADM)/.build/nos_dll.o \
		$(HEADM)/.build/nos_isi.o "$$($(CROSS)gcc -march=armv4t -marm -print-libgcc-file-name)"
	$(CROSS)objcopy -O binary $(HEADM)/.build/nos_dll.elf $(HEADM)/.build/nos-dll.bin
	sed 's|model/.build/|$(HEADM)/.build/|' $(HEADM)/rom-patches.txt > $(BOOT)/rom-patches.txt
	$(PY) $(HERE)/boot/prep.py --cs0 $(BOOT_CS0) --cs1 $(BOOT_CS1) \
		--patches $(BOOT)/rom-patches.txt --root $(ROOT) --out $(BOOT)
	cp $(HEADM)/upp-quirks.txt $(HEADM)/cbus-regs.txt $(BOOT)/

boot-model:
	ssh $(REMOTE) 'mkdir -p $(MDIR)/src $(MDIR)/run'
	git -C $(ROOT) archive HEAD model | ssh $(REMOTE) 'rm -rf $(MDIR)/src/model && tar -x -C $(MDIR)/src'
	rsync -a $(HERE)/model/ $(REMOTE):$(MDIR)/tools/
	rsync -a $(BOOT)/cs0.bin $(BOOT)/cs1.bin $(BOOT)/upp-quirks.txt $(BOOT)/cbus-regs.txt $(REMOTE):$(MDIR)/run/
	ssh $(REMOTE) 'cd $(MDIR) && tools/build_linux.sh src/model . $$PWD/deps/root >/dev/null && \
		tools/run_model.sh . run $(MODEL_SECS) $(MODEL_TRACE)'
	rsync -a '$(REMOTE):$(MDIR)/run/*.log' $(BOOT)/model/

boot:
	@mkdir -p $(BOOT)
	ssh $(REMOTE) 'mkdir -p $(RDIR)/rtl/cpu $(RDIR)/sim/cpu'
	rsync -a --delete $(ROOT)/rtl/cpu/ $(REMOTE):$(RDIR)/rtl/cpu/
	rsync -a --delete --exclude 'build/obj-*' --exclude build/rtl --exclude build/qemu \
		--exclude build/boot/head $(HERE)/ $(REMOTE):$(RDIR)/sim/cpu/
	ssh $(REMOTE) 'make -C $(RDIR)/sim/cpu RTL=$(RTL) model >/dev/null 2>&1 && cd $(RDIR)/sim/cpu/build/boot && \
		../obj-$(RTL)/Vtb_cpu --machine ngage --flash0 cs0.bin --flash1 cs1.bin \
		--quirks upp-quirks.txt --cbus-regs cbus-regs.txt --logdir . --lat 0:0 \
		--max-cycles $(BOOT_CYCLES) --progress 100000000 --devlog $(BOOT_ARGS) > run.log 2>&1; tail -1 run.log'
	rsync -a '$(REMOTE):$(RDIR)/sim/cpu/build/boot/*.log' $(BOOT)/
	$(PY) $(HERE)/boot/cmp_regs.py --name "register logs" --ignore 0x0C150100-0x0C150104 \
		$(BOOT)/regs.log $(BOOT)/model/regs.log; \
	r=$$?; $(PY) $(HERE)/boot/cmp_regs.py --name "CBUS logs" $(BOOT)/cbus.log $(BOOT)/model/cbus.log || r=1; \
	$(PY) $(HERE)/boot/cmp_dev.py $(BOOT)/dev.log $(BOOT)/model/trace.log || r=1; \
	exit $$r

clean:
	rm -rf $(BUILD)
