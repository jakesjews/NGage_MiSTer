# Simulation CPU profiles

This observer binds to `arm925t` in a Verilator build. It has no outputs to
the CPU, no state in the synthesized design, and no entry in `files.qip`,
`lint/rtl.f` or `tools/gen_cpu.sh`. The whole-core bench reads the bound
signals alongside its existing debug taps; no emu hardware port is added.
Do not add this file to a Quartus source list.

`cpu_profile_probe.sv` supports both source RTL and the generated netlist.
Its V2 packed-record slices describe the S12 layout. The W-width assertion
catches a size change, **not a same-width field reorder**; update the probe
when changing the record definitions. ZAP's original instruction is kept
in a bench-side PC-to-decoded-word map; V2 carries it to W. A changed word
at the same PC replaces the map entry. This assumes no self-modifying word
overtakes an older instruction at that PC; `mix_unknown` exposes missing
decode observations, not that alias case.

## Run

Use separate build directories when changing profile/core parameters:

```sh
# Whole core: profile on by default, ordinary Verilator optimization flags.
make -C sim BUILD=/absolute/build/path \
  VEXTRA='-DNGAGE_DCACHE_16K=1 -DNGAGE_CORE_ARM9=1' \
  /absolute/build/path/coreboot/Vemu
# Omit NGAGE_CORE_ARM9 for ZAP. CORE_PROFILE=0 removes the bound probe.
# --no-profile disables accumulation in the same instrumented binary.
/absolute/build/path/coreboot/Vemu +verilator+seed+1 +verilator+rand+reset+2 \
  --cs0 /path/cs0.bin --cs1 /path/cs1.bin --out /existing/output/dir \
  --progress 104000000 --profile-at 468000000 --cycles 468000000

# CPU-only bench; reuse existing binaries and QEMU references.
make -C sim/cpu model CORE=ARM9 PROFILE=1 VEXTRA=-GDCACHE_SIZE=16384 \
  MODEL_DIR=/absolute/cpu/build
/absolute/cpu/build/Vtb_cpu --bin sim/cpu/build/tests/crand1.bin --lat 2:9 \
  --profile /tmp/crand1.csv --profile-start 0x344 --profile-end 0x128

c++ -std=c++17 -O2 sim/profile/profile_test.cpp -o /tmp/cpu-profile-test
/tmp/cpu-profile-test
python3 sim/profile/report.py /tmp/crand1.csv --from post_setup --to body_end
python3 sim/profile/report.py /path/V2/profile.csv /path/ZAP/profile.csv \
  --from first_exec --to thread_1
python3 sim/profile/report.py /path/game/profile.csv --seconds 200:235
```

S13's Ubuntu Verilator 5.032 also uses `-Wno-BLKANDNBLK`, as the preceding
whole-core builds do. All builds retain `-O3 --x-assign unique --x-initial
unique`; the C++ optimization flag is the existing `-O2`. CPU suite profiles
start after the selected marker retires. The S12 markers are `0x344` for
crand1/ctrand1, `0x324` for mmu_page, and `0x128` (first test_pass MOV) for
the end of the body. The latter separates the final cache-clean operation.
These are binary-specific addresses, not symbol discovery.

## Accounting contract

One sample immediately before each rising edge, classified using that
edge's existing harness retirement decision. Every counted clock belongs
to exactly one class; all instruction-mix bins sum to `retired`. Both
identities are checked on CSV writes and by `report.py`. The CSV range is
half-open `[start,end)` and `clocks=end-start`. Whole-core reset clocks
before the output file opens are included as reset.

The classification is **exclusive priority attribution of observed
conditions, not a causal or additive stall-penalty model**. A fill can
overlap an interlock or a redirect. Removing one bottleneck can expose
another class without creating a new physical delay. Retired clocks win
even during a fill. Raw evidence and retired/fill overlap columns preserve
those simultaneous conditions.

Priority, highest first:

1. Reset, retired instruction, Thumb BL continuation, taken exception.
2. Successful non-final block/uop retirement (`structural_uop`).
3. Waiting data request: uncached, write-through, translation; then a
   genuinely locked consumer; then fill-busy request; then other request.
4. Serial/CP15 fence, replay, reservation/reload recovery.
5. Multiply, early-shift, load-use, other dependency/admission hold.
6. Empty/unavailable fetch queue: TLB walk, I-fill, redirect, other fetch.
7. Outstanding branch/return/serial/exception/replay recovery.
8. Block sequencing, WFI, residual pipeline/structural bubble.

A recovery interval ends when its target retires, not when an older
instruction retires; a later redirect replaces it. Its non-retirement
clocks can be attributed to a higher-priority wait. V2's W cause is saved
until its registered flush arrives. There is no attempt to reconstruct
all simultaneous speculative epochs. The recovery class is a bounded
observer estimate, not a timing-window assertion.

## Core mappings and limitations

| Class/evidence | V2 | ZAP |
|---|---|---|
| Fetch unavailable | queue empty or quarantined head | FIFO not valid |
| I/D fill and translation | shared FSM fill state and TLB busy | same |
| Data request waiting | request and not done | data_stall |
| Locked consumer | D2 used sources/real destinations, pending S/A operands, W owner | issue load-lock with locked source/destination slot |
| Load/shift/dependency | D2 load/early hazards, held execution operands/admission | issue load/shift locks, issue/shifter stall |
| Multiply | multiply wait | shifter multiplier busy |
| Serial | decode fenced or incomplete W CP | predecode cp_stall |
| Reservation | memory WAIT/RELOAD states, fill-ended | shared cache RELOOKUP states; no equivalent V2 ownership-reload event |
| A / early redirect | A redirect / D2 redirect | ALU or shifter redirect / decode redirect |
| W return/PC | return_event recovery | W clear excluding replay, exception and CP release |
| RAS repair | registered W repair action=2 | no separate equivalent tap |
| Predicted fetch / branch validation | advance+predicted / A BTB update+hit | no equivalent counter exposed here; zero means unavailable |

ZAP's separate issue-stage and shifter-stage stalls cannot identify the
same early/late-operand categories as V2. Compare their aggregate dependency
class, then inspect subcategories as explanations within each core.
An active D miss engine alone does **not** classify the clock as D wait:
there must be a waiting request or a consumer lock. Likewise, fetch fill
busy counts as starvation only when the queue cannot supply an instruction.

Instruction primary bins use the original expanded ARM encoding, including
the shared decoder's two NV-coded Thumb BL markers. The firmware bench
counts a Thumb BL pair once using its existing retirement heuristic; CPU
microbench counting retains its existing convention. `thumb_continuation`
accounts for a retired second half omitted by that firmware convention.
Conditional failures remain in the mix; load/store word counts require a
passing condition. LDM/STM words are the list population (empty list means
one PC transfer). `branches_taken/not_taken` includes explicit branches and
ordinary PC destinations; `returns` is **return candidates** (BX lr, MOV pc
lr, LDM with pc), not proof that every such instruction returns from a call.

Miss counts are completed line fills, not lookup misses or retry counts:
`e29` D load fill, `e30` D store fill, `e31` I fill. Fills crossing an interval
are counted where they complete. The raw debug events also include dirty
writebacks and uncached transactions. No game CPI is inferred from boot.

## CSV rows and raw fields

`interval,second` is an independent consecutive guest-second interval
(104,000,000 clocks, with a shorter final interval). `segment,<label>` is
since the previous milestone; `cumulative,<label>` is since clock zero.
Do not sum interval, segment and cumulative rows together. `report.py`
subtracts cumulative boundaries or sums only consecutive second rows.

Whole-core milestones: first SWI=`first_exec`; entry at PC `503247bc` with
LR=0=`thread_N`. With the S9/S12 boot images, thread_1 is EFile, thread_2/3
its workers, thread_4 EStart. The labels themselves do not inspect a
process name, and other images can create a different order. `--profile-at`
adds an exact-clock boundary. Suite boundaries are `post_setup`, `body_end`.

`eN` counts sampled evidence, overlapping rather than exclusive:

| N | Evidence |
|---|---|
| 0–5 | reset, fetch unavailable, I fill busy, I TLB busy, D fill busy, D TLB busy |
| 6–9 | data request waiting, uncached state, write-through state, locked consumer |
| 10–14 | load hazard, early/shift hazard, multiply, other dependency, serial fence |
| 15–21 | replay, reservation/reload, A redirect, D redirect, W return, exception recovery, serial recovery |
| 22–28 | W uop, last uop, condition passed, Thumb W, block sequence, fetch wait, predicted fetch advance |
| 29–35 | D load fill, D store fill, I fill, V2 branch validation, V2 prediction hit, A clear, memory word commit |
| 36–42 | W valid, A valid, D valid, WFI, decoded word valid, V2 registered W flush, decoded Thumb |
| 43–45 | ZAP shifter redirect, V2 W RAS repair, D lock vector nonempty |

`e35` is all V2 memory words but only ZAP loads; use decoded `load_words`
and `store_words` for cross-core comparisons. `stall0..7`, `ic0..7`,
`dc0..3` are the existing raw debug taps (see `tools/mister_dbg.py` and cache
wrappers for their definitions), not an exclusive partition. The final
three columns count retirement while a D fill, any D lock, or I fill is
active. These show overlap that would disappear in a stall-only table.
