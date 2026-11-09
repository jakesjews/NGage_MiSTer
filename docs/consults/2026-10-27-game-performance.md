# Game performance investigation, 2026-10-27

The user's concern covers game performance generally. Tony Hawk and Call of
Duty are both primary workloads; Sonic N and Asphalt remain regression checks.
The requested Tony Hawk gain is at least five actual frames per second. Timing
closure, unchanged firmware-visible behavior and real gameplay remain required.
No such improvement has been demonstrated yet.

The fixed-time PC diagnostic is complete on both games. Each capture has
32 validated 1,024-entry windows, covering 1.28835 seconds at a 4,093-clock
cadence. All 5,584 THPS and 4,628 CoD game PCs match original opcodes; all
6,023/4,240 sampled ARM ROM words also match. Game code accounts for
75.91%/82.74% of samples. EUser Copy/Move accounts for 8.28%/1.93%, so this
firmware loop is not the common dominant cost. Multiply-wait samples are
0.70%/0.42%; no-retirement data-fill samples are 11.87%/11.08%. These are
overlapping observations at the last retired PC, not causal speedup bounds.

The unchanged functional CPU gives THPS 21.500 complete/changing uploads/s
and CoD 7.566667 complete uploads/s in the main windows, with no sampled
fault, loader error or incomplete/untracked upload. The six-pair post-trace
windows give 21.666667/7.666667 complete uploads/s. These are observer checks,
not a new optimization. CoD animation settles to unchanged pictures; its
changing-image rate is not substituted for throughput. Both boot idle by
50 seconds. The first CoD attempt missed the 90-second launch deadline and
is explicitly excluded; no game input or FPS measurement occurred there.

The diagnostic fit uses 36,602 ALMs, 43,316 registers, 532 M10Ks and 42 DSPs,
with -2.765/+0.102 ns minimum setup/hold. Original stripped RBF/INI/CFG are
restored and hash-verified; the restored phone is idle at 50 seconds and
temporary helpers/Quartus containers are gone. No root functional promotion.
See `research/pc-sample/hardware-result.json`, its validation artifacts, and
`active-experiments-pc-sample.json`.

Latest experiment: late constant-shift forwarding is set aside. Source and
generated CPU results match on all 351 records, and held/alias tests match
QEMU, but THPS gains only 0.208 FPS and CoD changes little. Setup worsens to
-2.125 ns stripped / -2.514 ns with counters. Original hardware is restored
and idle at 50 seconds. See `active-experiments-late-shift.json`; the stronger
combined candidate below remains the performance reference.

Current checkpoint: the combined CPU/cache/memory candidate improves the
braked THPS Warehouse scene from 18.041667 to 21.541667 complete/changing
uploads/s (+3.5 FPS). CoD's settled-scene comparison improves complete uploads
from 6.933333 to 7.566667/s (+9.1%); separate boots and unequal settling
windows remain limitations. Its stripped/profiled setup slack is
-1.735/-2.082 ns, so timing is still failing. No functional RTL is promoted.
Original stripped RBF/INI/CFG hashes are restored, with phone idle verified
at 50 s. See `active-experiments-combined.json` for the completed comparison.

Four new isolated trials compare eight-entry classic and burst-capable
posted-store queues. Validation and all four fits are complete. Both queue
variants measure 21.208333 complete/changing THPS uploads/s. CoD measures
7.533333 classic versus 7.866667 burst complete uploads/s in matched 260-second
settling windows, a single-run 4.4% difference that needs repetition before
claiming a reliable gain. All four builds fail setup timing. The burst model's
354 source/generated records match exactly (339 passes and the parent's 15
known policy-expectation failures); all 38 focused checks pass. No functional
RTL is promoted. Original settings/build are restored and phone idle is
verified at 50 seconds. See `active-experiments-posted-burst.json` and its
linked comparison. Results below retain the investigation chronology.

A predicated-off execute shortcut passes its 1,440-case directed matrix at
four memory latencies, with parent/candidate signatures identical. It saves
no clocks on the warm load-to-failed-ADD sequence (511 for 128 pairs in both
models); the failed-multiply window improves from 255 to 128 clocks. No game
benefit is demonstrated, so the prototype is set aside without fits or a
full regression. The earlier cold-window matrix also matched QEMU; the warm
binary has not been rerun there.

The instruction-bus timing lead now has passing compositional proofs. The
actual fetch/CP15 startup contract is proved, followed by no I-cache writes
for one/two ways and equivalence of all merger controls and active-write data
with code write data tied to zero. The isolated trial is rejected: worst setup
is -2.600 ns versus its parent's -1.735 ns. All 348 source regression records
match the parent exactly; 37 generated records also match before the remaining
run was stopped following the failed fit. There is no hardware test or FPS
claim for this trial. Framework and hardware remain unchanged.
Evidence: `research/icache-readbus/` and
`active-experiments-icache-readbus.json` under timing-closure.

The isolated 64 KiB instruction-cache trial is set aside after hardware
comparison. It retains the 32 KiB data cache, 16-byte lines and existing
fill/error behavior. All 351 source/generated regression records match
exactly (336 passes and the same 15 parent policy-expectation failures).
The stripped/counter builds use all 553 M10Ks and fail setup by
1.745/2.320 ns. Matched fresh controls give THPS 21.583 versus 21.708
changing uploads/s and CoD 7.833 versus 7.800 complete uploads/s. These
single windows demonstrate no useful gain. Original stripped build/settings
are restored and phone idle is verified at 50 seconds. No root functional
promotion. See `research/icache-capacity/` and its experiment state JSON.

A separate 32 KiB timing trial removes the hit-lookup dependency only from
the read-only cache's RAM write enables and their forwarding descriptors.
The actual cache is proved never to write tag/data RAM while its request
FSM is idle, at both 32/64 KiB and one/two ways, using the separately proved
fetch/CP15 startup contract. Under that property, a combinational proof shows
all tag/data write enables unchanged. Existing metadata bookkeeping retains
its original selector. All 21 focused source/generated records exactly match
the 32 KiB parent; whole-core lint and generated-source checks pass. The
Ubuntu fit completes at -1.926 ns setup / +0.086 ns hold, worse than its
parent's -1.735 ns setup. It uses 33,864 ALMs, 39,472 registers, 519 M10Ks
and 42 DSPs and is set aside without hardware deployment. Evidence:
`research/icache-fillway/` and `active-experiments-icache-fillway.json`.

The execute-class timing trial is complete and rejected. It registers the
execute record's existing speculative-load classification on the same edge
as the record. Reset-base and induction proofs pass with arbitrary
acceptance; unchanged execute logic and core integration are checked
exactly. Whole-core lint, freshness and all 45 focused source/generated
records pass and match the parent, including 249,808,893 cycles per model,
trace hashes and signatures. Its fit is worse than the parent: -2.185 ns
setup / +0.084 ns hold, 34,559 ALMs, 39,598 registers, 519 M10Ks and 42 DSPs.
It is not deployed or promoted. See `research/execute-loadclass/` and
`active-experiments-execute-loadclass.json`.

The refreshed retirement observer on the combined 32/32 KiB candidate is
verified on both games. CPU-side noninterference, lint and freshness pass;
the recorder/reader remain unchanged from their earlier component tests.
Its diagnostic fit is -2.538 ns setup / +0.078 ns hold, with 36,691 ALMs,
43,205 registers, 532 M10Ks and 42 DSPs. Each game capture has 32 windows and
32,768 events, read twice identically. Original game instructions match all
4,031 sampled THPS PCs and all 3,350 CoD PCs; weak DLL guesses are rejected.
Both reach idle by 50 seconds, and no sampled CPU/loader errors or malformed
uploads occur. THPS gives 21.583 changing uploads/s during capture and
21.500 after it. CoD gives 7.467 complete uploads/s in the early window and
7.833 after capture; its stationary view repeats images, so these complete
upload counts are distinct from unique-picture FPS. This is a refreshed
profile of the existing faster candidate, not a new performance gain.

Equal-duration trace tails show 430 adjacent ALU-to-LSL #8 and 379
ALU-to-LSL #1 events in THPS, all with two-clock retirement intervals, within
the unconditional no-flags subset. CoD also has repeated dependent shifts.
These observations motivate testing late constant-shift operands through the
existing forwarding/lock mechanism; they are not causal cycle penalties or
a speedup prediction. No shift RTL has been implemented yet. Original
stripped RBF/INI/CFG hashes are restored, idle is verified at 50 seconds,
and all temporary helpers/build containers have exited. See
`research/combined-retire/` and `active-experiments-combined-retire.json`.

The separate FixQD investigation now confirms the utility's intended RAM
writes, but same-RBF A/B tests show no useful gain in either primary game.
See `2026-10-27-fixqd.md`. A separate experiment measures unconditional
traffic logging in the project's own NOS stand-in. Suppression gives only a
small single-window Tony Hawk difference (18.083 to 18.500 changing uploads/s)
and no useful CoD gain; a stripped-build benefit remains unmeasured.

## Hardware baseline

The existing 104 MHz `tlb-fix-rfmemprof104-s13` diagnostic is used without JTAG.
RBF SHA-256:
`45737862a2cdceb5c7ee80b6769eb542f17d23f250b5aaabeacb48669f266e42`.
This build still fails setup by 1.875 ns; it is not a release candidate.
Direct Video is temporarily disabled. Original INI/CFG backups and the
restoration launcher are recorded in each capture directory. Existing game
cards and the C: save are retained, without copying or resetting saves.

| Game and view | Unique counter snapshots | LCD updates/s, mean (range) | Instructions/s | SDRAM controller busy | CPU SDRAM wait |
|---|---:|---:|---:|---:|---:|
| Tony Hawk, Warehouse Free Skate | 24 | 19.17 (17–22) | 43.99 M | 29.56% | 25.51% |
| Call of Duty, opening forest, initial view | 27 | 6.85 (6–7) | 54.85 M | 20.35% | 16.53% |
| Call of Duty, same position after holding Right for two seconds | 24 | 10.38 (8–11) | 53.05 M | 23.13% | 18.36% |

These are LCD update events, not optical measurements of unique rendered
frames. Consecutive identical counter snapshots are excluded (three of thirty
in the first Call of Duty window). The turned view includes its first settling
sample. It demonstrates scene dependence, not a performance improvement.
Overlapping stall counters cannot be added as independent CPU penalties.
Controller busy time includes refresh and protocol overhead. Neither game
shows sustained controller saturation in these windows.

Call of Duty boots to the phone idle screen by the 50-second capture, launches,
loads the opening Greenhorn mission and responds to turning input. No fault
record or loader error appears in the sampled windows. Select the difficulty
with the left soft key (F1); `5` did not select that menu item.

Evidence:

- `build/timing-closure/hardware/rfmemprof104-thps/`: existing Warehouse captures.
- `build/timing-closure/hardware/rfmemprof104-cod/`: deployment record, actions,
  screenshots, raw counter words and `mission-*-summary.json`.

## Isolated experiments in progress

- `tlb-fix-rfi32d32prof104-s13`: physical I/D caches enlarged from 16/16 KiB to
  32/32 KiB, retaining CP15 identity, 104 MHz and the same diagnostic counters.
  Both the board's `NGAGE_ICACHE_32K` override and the CPU testbench's
  `-GICACHE_SIZE=32768` must be set; changing the wrapper default alone does not
  change either instantiation. All 345 source CPU cases pass (410,261,158
  clocks); their result signatures match the existing 16/32 KiB trial.
  All 345 generated-Verilog cases also pass and match the source results,
  cycle counts and traces exactly. The completed fit uses 35,604
  ALMs, 519 M10K blocks and 42 DSP blocks, with setup slack of -1.852 ns
  (hot) / -2.029 ns (cold), and minimum hold +0.072 ns. The diagnostic
  hardware build boots by 50 seconds. In the same starting forest view,
  thirty samples average 6.97 LCD updates/s (6–7), versus 6.85 in the
  baseline; 57.76 M instructions/s versus 54.85 M. CPU SDRAM wait falls to
  14.72% and controller busy to 18.52%. This is not a useful demonstrated
  FPS gain and does not justify the extra RAM and worse setup. The scene
  is matched by the untouched starting camera, not deterministic replay;
  do not treat the small 0.11 update/s difference as established speedup.
  Evidence: `build/timing-closure/hardware/rfi32d32prof104-cod/`.
  Tony Hawk's first Free Skate window averages 21.25 LCD updates/s
  (19–24), versus 19.17 in the original memory-profile baseline, with
  instruction fills down about 30% and CPU SDRAM wait 23.56% versus
  25.51%. However, a second window after Retry averages only 18.83
  (16–23), versus 18.33 in the pipeline-profile baseline's retry.
  Both larger-cache windows retire about 46.03 M instructions/s. The
  inconsistent update-rate benefit and moving-camera variation prevent a
  repeatable FPS claim. Both windows have 24 samples and no sampled fault
  or loader error. Evidence: `hardware/rfi32d32prof104-thps/`.
- `tlb-fix-rfpipeprof104-s13`: unchanged functional datapath with counters 8–35
  replaced by finer pipeline observations. Its counter map is stored in
  `build/validation/counter-map.json`. The first sixteen added observations
  exclude clocks with a retired micro-operation, but still overlap. These are
  diagnostic evidence, not additive estimates of achievable speedup. All
  345 generated-Verilog CPU cases pass with complete result rows, cycle
  counts and trace hashes identical to the reference. The completed fit
  uses 34,751 ALMs, 483 M10K blocks and 42 DSP blocks; minimum setup is
  -1.880 ns and minimum hold +0.116 ns. The same CoD starting view averages
  6.83 LCD updates/s over thirty samples, consistent with the earlier
  diagnostic baseline, with no sampled fault or loader error. Detailed
  observations during clocks without retirement: data fill busy 15.55%,
  S empty 15.29%, S valid but blocked 13.97%, W blocked 12.35%, data request
  waiting 8.61%, background lock 7.04%, decode load hazard 5.84%, decode
  early-operand hazard 5.05%, memory retry 2.14%, multiply wait 0.39%,
  shift wait 0.23%. These overlap. Predictor training sees 4.54 M entry
  hits in 5.22 M updates/s; this is an entry-hit metric, not branch
  prediction accuracy. Execute/decode redirects average 0.65 M/0.15 M
  per second. Evidence: `build/timing-closure/hardware/rfpipeprof104-cod/`.
  Tony Hawk Warehouse Free Skate averages 18.63 updates/s (17–22) over
  24 samples, and 18.33 (13–21) in a second window after Retry. The moving
  camera and settling differ, so these are workload profiles, not evidence
  of a regression or a gain against the earlier 19.17 mean. The first
  window's no-retirement observations are: S blocked 21.04%, data fill
  busy 20.83%, S empty 19.68%, W blocked 18.96%, data request waiting
  13.43%, decode load hazard 10.31%, background lock 8.45%, early-operand
  hazard 6.81%, retry 3.54%, multiply wait 0.65%, shift wait 0.20%.
  Predictor entry hits are 82.11% of updates. No sampled fault or loader
  error was observed. Both windows and screenshots are under
  `build/timing-closure/hardware/rfpipeprof104-thps/`. The attempted warm
  card selection was abandoned before mounting; open-file verification
  still showed the CoD card. A known THPS MGL was then cold-booted and
  reached phone idle by 50 seconds. Zaparoo was stopped afterward.
- `tlb-fix-rffbpack104-s13`: a separate stripped-core experiment partitions
  the existing sixteen-bit LCD framebuffer into three five-bit planes and
  one one-bit plane. Addresses, every stored colour bit, old-data collision
  behavior and registered read latency are unchanged. The existing LCD
  reference-model bench passes all checks over 2,436,315 clocks. The fit
  rejected the hypothesis: each five-bit plane uses 23 M10Ks and the last
  bit uses five, for 74 LCD blocks instead of 72. Whole-core use is 485
  M10Ks and 33,487 ALMs, with setup -1.936 ns / -1.687 ns (hot/cold)
  and minimum hold +0.074 ns. This saves no RAM and is not promoted or
  hardware-tested. The CPU and framework were byte-identical to the parent.

A further isolated experiment (`tlb-fix-rfbpfoldprof104-s13`, and its stripped
counterpart `tlb-fix-rfbpfold104-s13`) changes only the branch-predictor address
index. The original index uses PC[8:1], whose bottom bit is always zero for
ARM instructions. Folding PC[9] into that bit lets word-aligned code occupy
all 256 entries, retaining the full original tag, table size and lookup
latency. The existing source/generated predictor and fetch suites pass all
ten configurations, including a new capacity check for 256 ARM addresses.
Whole-core debug and stripped lint pass. All 345 source CPU cases pass.
342 signatures match the reference exactly; the three interrupt-sweep
signatures differ only in documented timing/window/landing statistics,
with zero failure/handler-error fields. Aggregate clocks change by -0.05%,
which does not establish game speedup. All 345 generated cases also pass, with complete result rows identical to
the source. The fits complete: stripped 33,030 ALMs / 38,251 registers,
setup -2.313/-2.080 ns (hot/cold), hold >= +0.104 ns; diagnostic 35,160
ALMs / 41,231 registers, setup -1.467/-1.316 ns, hold >= +0.076 ns.
Both use 483 M10Ks and 42 DSPs. The stripped timing is worse than the
best existing -1.301 ns build. CoD hardware testing gives 6.73 LCD updates/s over thirty samples versus
6.83 in the pipeline-profile baseline. Instruction throughput is effectively
unchanged (55.12 versus 55.16 M/s). Predictor entry hits improve from 87.02%
to 92.10% and execute redirects fall from 0.651 to 0.521 M/s, but there is
no useful measured game gain. No sampled fault/loader error is observed,
and the phone is idle by 50 seconds. Tony Hawk averages 19.25 LCD updates/s in its first Free Skate window
versus 18.63 baseline, and 18.50 after Retry versus 18.33 baseline. These
small differences, with camera/animation variation, do not demonstrate the
requested five-FPS improvement or justify the worse stripped timing. Both
games run without sampled faults/loader errors. Neither variant is promoted.
Evidence: `hardware/rfbpfoldprof104-cod/` and `hardware/rfbpfoldprof104-thps/`.

None of these experiments is promoted. No MiSTer framework file is changed.

## Verifying completed picture uploads

Native MiSTer screenshots measured 64 captures in 7.71 seconds, about
8.3 captures/s including the required command spacing. The first eleven
image files were accidentally overwritten by the earlier failed capture
attempt while collecting results; those images have been separated, and
only the later 53 retain a valid match to the capture timestamps. That is too slow to
resolve Tony Hawk's frame rate. The capture-throughput files under the
Tony Hawk pipeline-profile directory are a capture-speed test while paused,
not FPS measurements. Linux framebuffer capture has not been validated as a faster alternative.

An isolated diagnostic `tlb-fix-rfframeprof104-s13` adds a one-way LCD
observer. It checks all 36,608 pixel coordinates of a full-screen upload,
computes a 64-bit payload checksum and counts complete uploads and changes
from the previous complete payload separately. Interrupted and unsupported
(partial-window or transformed-display-mode) uploads are counted separately;
these invalidate comparison. Continuous full-window wrapping is supported.
This measures changed complete LCD uploads, not optical scan-out/tearing.
Checksum equality is probabilistic. The original LCD command-start counter
is retained for comparison. Pipeline counters 12/15/16/23 are replaced by
complete/changed/incomplete/untracked upload events; use its own counter map.

The observer drives no LCD/CPU control. CPU RTL and framework are byte-identical
to the pipeline-profile baseline. A directed LCD suite checks duplicates,
changes at both endpoints, wrapping, aborts, partial windows, display-off,
transposition, 12/16/18-bit pixels and reset. The existing reference-model
checks also pass, totaling 4,706,182 clocks. Whole-core debug/stripped lint
passes with only unused-signal/parameter warnings waived (the existing
diagnostic taps and primitive stub). The completed fit uses 35,292 ALMs,
41,245 registers, 483 M10Ks and 42 DSPs. Setup is -1.403/-1.381 ns
(hot/cold); minimum hold is +0.053 ns. It boots to phone idle by 50
seconds, but the Tony Hawk title menu's uploads are all classified as
untracked (32 starts and 32 untracked in the first capture). This exposes
a mismatch between the observer's full-window/display-mode qualification
and actual firmware behavior. Its complete/changed counters cannot yet
support a hardware frame-rate claim.

`tlb-fix-rfframewinprof104-s13` preserves that observer and adds a read-only
snapshot of the LCD window and mode at RAMWR. Overlay words 8/9/10 replace
RTC/audio observations with column endpoints, page endpoints, and the
tagged mode/flags. All event counters and fault/loader records remain.
CPU and framework are byte-identical to the parent. Its purpose is to
identify the rejected condition rather than relax the observer blindly.
Whole-core debug/stripped lint and the LCD suite, including snapshot
checks, pass. Its compile was stopped once the firmware disassembly exposed
the extra ending-row convention, superseded by the observer revision below.
No RBF or timing result is claimed for this intermediate trial.

`tlb-fix-rfi32frameprof104-s13` separately tests 32 KiB instruction / 16 KiB
data caches. All 345 source cases pass with complete result rows identical
to the pipeline-profile reference (406,232,597 clocks). The generated CPU
regression also passes all 345 cases, with full result rows identical to
the source and reference. The fit uses 35,608 ALMs, 42,003 registers,
499 M10Ks and 42 DSPs. Setup is -2.226/-2.178 ns (hot/cold), minimum
hold +0.059 ns; it is not a timing improvement. CoD boots by 50 seconds
and runs its untouched opening forest scene at 6.77 LCD updates/s over
30 samples (6–7), versus 6.83 in the pipeline baseline. Throughput is
55.26 M instructions/s and SDRAM wait 15.99%. No sampled fault or loader
error is observed. This is no useful game-performance gain. Evidence:
`hardware/rfi32frameprof104-cod/`.
It inherits the first observer and its current hardware limitation; the
original LCD-start counter remains available. A 64/16 KiB trial is only
prepared, with no simulation, fit or hardware result yet.

A follow-on counter-mapping build was started, then stopped during synthesis
when source inspection confirmed that the older memory-profile captures
already contain the four D-cache event counts at indices 21–24. No extra
fit or hardware run is needed to recover those measurements. The abandoned
trial is preserved as `tlb-fix-rfframedcacheprof104-s13`; no result or RBF
is claimed. The completed-image observer runs before the debug overlay,
so overlay changes cannot inflate its unique-upload count.

Sparse PC samples include EUser.dll's bulk-copy loop at
0x503a239c–0x503a23e0 in both games. The local extracted ROM disassembly
shows eight LDM/STM pairs per loop iteration. This is a workload lead,
not a measured share of stall time. Most samples lie outside the firmware
ROM address range; their loaded application/DLL owners are not yet mapped.
`hardware/pc-sampling-notes.json` preserves the samples and limits.

The firmware transfer helpers at `lcd.ldd` 0x50401f28–0x50401f64 pass
`start + rows` as PASET's ending coordinate while transmitting `rows` of
pixels. The first observer required the exact inclusive panel endpoint.
`tlb-fix-rfframev2prof104-s13` instead accepts an address window covering
the physical panel, excludes coordinates the panel itself discards, and
still requires all 36,608 visible coordinates in order before completion.
It retains the window/mode snapshot to confirm actual hardware conditions.
The LCD reference/directed suite passes 5,148,612 clocks, including extra
ending rows, actual off-panel rows/columns, duplicates and continuous wraps.
Debug/stripped whole-core lint passes. CPU/framework are byte-identical.
The fit completes at 34,454 ALMs, 40,888 registers, 483 M10Ks and 42 DSPs;
minimum setup is -2.365 ns and hold +0.081 ns. CoD boots to phone idle by
50 seconds. The RAMWR snapshot confirms xs=0, xe=175, ys=0, ye=208,
MADCTL=0xD4 and COLMOD=3, validating the extra ending-row diagnosis.
A paused/menu picture produces many complete uploads but few changed ones.
In the opening forest, thirty paired samples average 6.533 changed complete
uploads/s (6–7), exactly matching complete and start counts, with zero
incomplete or untracked uploads. Throughput is 55.574 M instructions/s;
no sampled fault or loader error appears. Each selected capture is verified
by two consecutive identical 36-counter vectors (at most five captures to
find a stable pair). This avoids mixing counter windows during screenshot
raster capture, which affected one preliminary single-capture sample.
Evidence: `hardware/rfframev2prof104-cod/mission-paired-summary.json`.
This establishes low changing-image throughput; it does not measure optical
scan-out or establish a speedup. Tony Hawk's braked Warehouse scene gives
18.125 changing complete uploads/s over 24 paired samples (18–19), with
zero incomplete/untracked uploads and 45.376 M instructions/s. This agrees
with the earlier 18.04 LCD-start baseline and validates its interpretation
for this steady gameplay scene. No sampled faults or loader errors occur.
Evidence: `hardware/rfframev2prof104-thps/stable-summary.json`.

A Tony Hawk procedure improvement: select Retry, confirm with a 160 ms
5 press, immediately hold Down continuously, and wait five seconds before
measurement. Screenshots show a fixed starting camera while the skater's
idle animation continues. Twelve pilot snapshots average 18.08 LCD starts/s
(18–19), with 45.27 M instructions/s and 24.63% CPU SDRAM wait. This is
a new scene baseline, not a gain over the moving-camera windows. Evidence:
`hardware/rfframeprof104-thps/stopped-*`. Temporary held-key helpers live
only under the ignored build directory and release held keys when closed.

The same braked scene was repeated for 24 samples: baseline 18.04 updates/s
(18–19), 45.32 M instructions/s, 24.60% CPU SDRAM wait. The 32/32 KiB cache
build gives 19.13 (19–20), 47.96 M instructions/s, 21.89% wait. A second
24-sample 32/32 window gives 19.17 (19–20). Screenshots show the same
starting background and stopped skater. Small cross-run pixel differences
remain: the best background-crop matches are 75%/91% exact, with mean
channel differences 3.03/1.11 on a 0–255 scale. This is a controlled
stationary scene, not deterministic replay. The measurements show a consistent approximately
6% improvement in this specific workload, about one update/s; it does not
meet the five-FPS goal or establish a comparable benefit for CoD. The first
observer's unsupported-window limitation still applies to its changed-frame
metric. The cache comparison uses the preserved original LCD-start counter.
Evidence: `hardware/rfframeprof104-thps/stable-*` and
`hardware/rfi32d32prof104-thps-stable/{stable,repeat}-*`.

`tlb-fix-rfsptlb1kprof104-s13` separately increases only the small-page
translation caches from 256 to 1024 entries on each side. It keeps the
16/16 KiB I/D caches, all other TLB sizes, CP15 identity, pipeline latency,
104 MHz and the original memory-profile counters. Repeated table walks in
both games motivate the experiment; no speedup or fitted RAM saving is
assumed. Whole-core debug/stripped lint and focused source MMU/TLB/fault
tests pass. All 345 source and 345 generated CPU cases pass, with identical
complete result rows (406,210,725 clocks). All signatures match the reference;
six cases change timing/traces as expected with fewer translation conflicts.
The fit completes at 36,652 ALMs, 42,896 registers, 489 M10Ks and 42 DSPs;
minimum setup -1.770 ns and hold +0.071 ns. CoD boots by 50 seconds and
runs its opening forest at 6.933 LCD starts/s over 30 paired samples,
versus the earlier memory-profile baseline's 6.852. Throughput is
55.236 M instructions/s versus 54.851, and SDRAM wait 16.15% versus
16.53%. Data table-walk beats fall from 120,776/s to 79,851/s, but the
small update-rate difference does not establish a useful game gain.
No sampled CPU fault or FPGA flash-loader error occurs. Tony Hawk's braked
Warehouse scene averages 18.292 LCD starts/s over 24 paired samples,
versus roughly 18.1 baseline; 46.005 M instructions/s, 23.93% SDRAM wait.
The initial capture attempt failed on a truncated PNG during a file transfer
and is discarded; the reported clean window follows transfer completion
and a fresh Retry. Neither game shows a useful gain. Framework files are
byte-identical. Nothing is promoted.
Evidence: `hardware/rfsptlb1kprof104-cod/mission-stable-summary.json`.

Tony Hawk evidence: `hardware/rfsptlb1kprof104-thps/clean-summary.json`.

## 64 KiB data-cache capacity trial

`tlb-fix-rfd64framev2prof104-s13` retains the 16 KiB instruction cache and
changes only physical data-cache capacity from 16 to 64 KiB, preserving the
CP15 identity and architectural index-maintenance traversal. All 345 source
and 345 generated CPU cases pass with exactly equal complete result rows,
416,221,228 clocks. Against the original reference, 339 signatures are exact;
six differ only in documented timer/interrupt-sweep statistics, with failure
fields zero. A separate upper-colour test checks dirty writeback, invalidation,
both ways and alias ownership at physical set colour seven. All three bus
latencies pass in both models with identical signatures and cycle counts.
Whole-core debug and stripped lint pass.

The fit uses 36,333 ALMs, 42,662 registers, 545/553 M10Ks and 42 DSPs.
Setup is -2.066 ns (hot) / -1.962 ns (cold); minimum hold is +0.070 ns.
RBF SHA-256: `fa91eea3a41ae4478d8f07a20192e2dd26994a73a07ae5d964966f693771b802`.
This is a diagnostic with failing timing. Framework source is unchanged.

Both games reach phone idle by 50 seconds. Braked Tony Hawk averages 19.167
changing complete uploads/s over 24 paired samples, versus FrameV2's 18.125;
48.071 M instructions/s and 20.928% CPU SDRAM wait versus 45.376 M and 24.567%.
This is essentially the smaller 32/32 KiB cache trial's 19.13–19.17 result,
so the additional RAM has not earned its cost. CoD's opening forest averages
6.867 complete uploads/s over 30 paired samples, 56.302 M instructions/s,
14.207% CPU SDRAM wait. There is no useful throughput gain. Its stationary
background animation mostly settles (0.467 changing uploads/s); this cannot
be compared directly to runs with the background actor still moving. A
separate held-Right check produces changing pictures for every complete upload
(6–10/s as the view turns), confirming movement response. It is not a matched
performance benchmark.

All three paired windows have zero incomplete/untracked uploads and no
sampled CPU fault or FPGA flash-loader error. Neither cache capacity nor
timing is promoted. Evidence: `hardware/rfd64framev2prof104-{thps,cod}/` and
the trial's `build/validation/provenance.json` under timing-closure.

## Fetch sampling and rendering dependencies

The existing FrameSTI diagnostic is reused, without another FPGA build.
Its overlay PC is `zap_top.cpu_iaddr`: the fetch address after FCSE, before
MMU translation, latched at the video-frame boundary. It is not a retirement
PC. Each game has 600 jittered screenshot samples over approximately 158–164
seconds. Fetch locations can identify busy regions, but these sparse,
potentially correlated observations do not measure exact instruction shares,
stall ownership or frame-time outliers.

Fresh paired baseline windows remain consistent: Tony Hawk gives 18.083
changing complete uploads/s and 45.342 M instructions/s; CoD gives 6.533
complete uploads/s and 54.766 M instructions/s. CoD's background actor has
largely settled, so its 0.933 changing uploads/s is not a throughput measure.
Both games boot by 50 seconds, run and pause normally, with no sampled CPU
fault, flash-loader error, incomplete upload or untracked upload.

470/600 CoD fetch samples and 454/600 Tony Hawk samples fall outside firmware
ROM, in loaded-code address ranges. The original CoD application is extracted
for static inspection. Tony Hawk's small E32 executable is a loader: its
four-byte footer points to a gzip stream at file offset 0x3a4. Standard gzip
decompression verifies its CRC and length and yields a 928,312-byte EXCL
payload, including 0xd2e00 bytes of ARM code. No game bytes are changed.
Candidate code mappings of 0xfff00000 for CoD and 0xff900000 for Tony Hawk
align hot samples with palette/texture loops containing dependent byte and
halfword loads. These runtime mappings remain inferences, not independently
confirmed module addresses. EUser bulk-copy code also appears in both profiles.

An isolated synthetic benchmark models two such instruction patterns and
checks every output pixel. Removing only the CPU's early address-generation
parameter (`S_AGU=0`) provides a cost bound for that pipeline cut:

| Loop, 512 output pixels | Baseline clocks, bus 0:0 / 0:3 / 2:9 | S_AGU=0 clocks |
|---|---:|---:|
| Packed palette conversion | 7,747 / 7,824 / 8,695 | 6,508 / 6,892 / 7,864 |
| Texture byte followed by palette halfword | 11,199 / 11,411 / 12,275 | 10,198 / 10,410 / 11,321 |

All nine runs pass. Baseline source and generated models match exactly.
Experiment signatures and complete event/PC sequences match the baseline;
the only trace differences are three pending-load availability markers, with
all jointly available register values and flags equal. The first generated
loadpipe attempt omitted `RAM_RF_TAP`, falsely reading the removed register
mirror; that run is labelled invalid and replaced with the correct bank probe.

These 8–16% loop-cycle reductions are not game FPS gains. The experiment
removes an intentional timing cut, has no Quartus or hardware result, and is
not promoted. It motivates investigating dependent-load latency while
retaining the registered memory lookup. Source RTL and framework remain
unchanged by this investigation.

Evidence is under `build/timing-closure/hardware/pc-profile-{cod,thps}/` and
`build/timing-closure/research/game-hotspots/`, including the gzip manifest,
sampling limitations and complete benchmark/trace review. The original INI,
core configuration and stripped seed-13 RBF are restored with matching
SHA-256 hashes. The phone is visibly idle at 50 seconds; temporary input and
Zaparoo servers and Quartus containers are absent. Restoration evidence:
`hardware/pc-profile-restored-stripped104/`. The restored RBF still has
-1.301 ns setup slack. Neither timing closure nor the five-FPS goal is met.

## Selective memory-base bypass experiments

Two isolated trials retain FrameProfileV2's 104 MHz clock, caches, profiler,
constraints and byte-identical framework. Each changes only three CPU source
files and the generated CPU. The memory lookup address remains registered:

- `tlb-fix-rfbaseforwardframe104-s13` forwards an unconditional ALU result
  directly to a following scalar memory instruction with immediate zero
  offset. The zero-offset address bypass avoids a second arithmetic stage.
- `tlb-fix-rfmovebaseframe104-s13` forwards an unconditional shifted or
  immediate MOV's already-registered operand to a following scalar memory
  base. Ordinary unshifted-register MOV and RRX are excluded because their
  values may still need a late operand or live carry.

Each trial passes all 345 source and 345 generated CPU cases. Complete
result rows match, as do all 115 first-latency signatures and traces.
Totals are 406,196,467 clocks for zero-offset and 406,143,651 for MOV.
Against the old baseline, 114/115 first-latency signatures match exactly;
the interrupt sweep differs only in documented clock/window and interrupt
landing statistics. All its failure fields remain zero. Generated models
use the required `RAM_RF_TAP` observer. A new directed dependency fixture
checks conditional writers, RRX/carry, byte/halfword/word loads and cold/warm
caches; all three bus latencies pass in baseline and both source/generated
candidates. Debug and stripped whole-core lint pass.

| Synthetic loop | Baseline clocks, 0:0 / 0:3 / 2:9 | Zero-offset bypass | MOV bypass |
|---|---:|---:|---:|
| Packed palette | 7,747 / 7,824 / 8,695 | 7,747 / 7,847 / 8,695 | 7,021 / 7,326 / 8,259 |
| Texture/palette | 11,199 / 11,411 / 12,275 | 10,758 / 10,907 / 11,800 | 11,199 / 11,392 / 12,275 |

Both source/generated models agree on those counts and pass the output-pixel
checks. These are small synthetic loops, not game performance predictions.

Quartus 17.0.2 on Ubuntu completes both seed-13 fits. Timing still fails:

| Trial | ALMs | Registers | M10Ks | DSPs | Worst setup | Worst hold |
|---|---:|---:|---:|---:|---:|---:|
| Zero-offset | 34,949 | 41,453 | 483 | 42 | -2.334 ns | +0.115 ns |
| MOV | 35,604 | 42,144 | 483 | 42 | -2.466 ns | +0.085 ns |

Fresh Tony Hawk Warehouse measurements use original cards and the existing
C: save, the same cold-boot/scene procedure and 24 stable paired snapshots
per window. The unchanged FrameProfileV2 control gives 18.292 changing
complete uploads/s; zero-offset gives 18.167 and MOV gives 18.042. All three
reach phone idle by 50 seconds. No sampled CPU faults, flash-loader errors,
incomplete uploads or untracked uploads occur. Screenshots verify the
stopped starting scene, but this is not deterministic replay. Neither
candidate demonstrates useful Tony Hawk throughput improvement.

CoD's corresponding 30-pair cold-boot windows give 6.533 complete uploads/s
for the fresh control, 6.567 for zero-offset and 6.767 for MOV. The MOV
difference is small and has not been repeated; it is not evidence of a
general speed improvement. Changing-image rates are 1.167, 0.900 and 1.500/s
as the stationary forest animation settles, so those are not substituted
for render throughput. Both candidate CoD boots are idle at 50 seconds,
and both games run and pause normally. All six windows have zero sampled
CPU faults/loader errors and zero incomplete/untracked uploads. Neither
optimization is promoted. `hardware/baseforward-game-comparison.json`
collects the paired results and their limits.

The zero-offset hardware does exercise the new path: the no-retirement
early-dependency counter falls from 6.377% to 3.879% of clocks. Load-hazard
and data-fill-busy counters remain near 9.8% and 19.5%, respectively, and
the measured frame rate stays flat. These stall categories overlap; the
counter reduction cannot be treated as clocks saved or added to another
category's improvement. See `hardware/baseforward-thps-comparison.json`.

Evidence: each trial's `build/validation/{provenance,source-generated-comparison}.json`,
`research/game-hotspots/baseforward_rtl.S` and rendering fixtures, plus
`hardware/{baseforward-control,baseforward,movebase}-thps/` under
`build/timing-closure/`. The separately installed RBF hashes are
`77da9b0ec11dc7507475e125d0e980e757df91aeb748a2a25a44fb7b2cedc4f4`
and `afd94cb7f090bbcbb99ec5d5d67bc470a03829359e7d0f846912b78f71d8a182`.

After testing, the original INI and core configuration and the stripped
104 MHz seed-13 RBF are restored with verified SHA-256 hashes. The original
Tony Hawk card and existing save are retained. The phone is visibly idle
at the 50-second check. No input helper, Zaparoo server, CPU simulation or
Quartus container remains running. Evidence is in
`hardware/baseforward-restored-stripped104/`. The restored RBF still has
-1.301 ns setup slack; the five-FPS goal and timing closure remain open.

## Measured SDRAM row locality

`tlb-fix-rfrowprof104-s13` adds a registered observation output to the SDRAM
controller and reuses the 36-counter FrameV2 overlay. It counts accepted
word/line reads/writes, actual row hits/closed banks/conflicts, cache fills,
and two shadow bank layouts. The shadows see exactly the original accepted
addresses and refreshes; neither drives memory control. All 35 CPU source
files and 57 framework files are byte-identical to FrameV2. Formal equivalence
proves all 885 checked original controller outputs/state signals unchanged.
SDRAM chip-model tests, both UPP configurations, debug/stripped lint and the
new screenshot decoder checks pass. The fit uses 35,411 ALMs, 42,103 registers,
483 M10Ks and 42 DSPs; setup is -2.085 ns and minimum hold +0.116 ns.
RBF SHA-256 is
`02b136c41a4c44306050cd3a03c453abc3fb42caf22b058ac20ed143dc463ca7`.

Both games boot to phone idle by 50 seconds using original cards and the
existing C: save. The same stopped scenes give these paired measurements:

| Measurement | Tony Hawk, 24 samples | CoD, 30 samples |
|---|---:|---:|
| Complete LCD uploads/s | 18.042 | 6.700 |
| Changing complete uploads/s | 18.042 | 1.733 |
| Accepted SDRAM requests/s | 2,512,888 | 1,577,082 |
| Actual row hits | 38.89% | 30.85% |
| Actual closed-bank accesses | 7.87% | 11.21% |
| Actual row conflicts | 53.24% | 57.95% |
| Shadow 1 KiB interleaving hits | 44.34% | 34.82% |
| Shadow 4 KiB interleaving hits | 56.83% | 43.62% |
| Controller busy | 28.46% | 20.35% |
| Request queued while busy | 1.80% | 0.97% |
| D-cache load/store fills per second | 528,243 / 343,119 | 487,147 / 255,072 |
| I-cache demand fills per second | 598,354 | 345,480 |

All selected snapshots have zero CPU fault/loader errors and zero incomplete
or untracked uploads. The decoder verifies consecutive identical counter
vectors, pixel-to-record equality and the conservation equation
`reads + writes = hits + closed + conflicts`. CoD's stationary background
animation settles, so its changing-image rate is not substituted for render
throughput. These remain upload measurements, not optical scan-out or
frame-time-tail measurements. The observer has not improved performance.

The observed stream favors 4 KiB interleaving (bank byte bits 13:12, row
`{24:14,11:10}`), unlike the synthetic random stream. The extra shadow hits
times the controller's six-clock conflict-to-hit difference correspond to
2.60% of Tony Hawk's clock budget and 1.16% of CoD's. This optimistic scale
estimate ignores additional closed-bank activations, CPU overlap and stream
changes; it is neither an FPS prediction nor a strict speedup bound. It does
not explain the missing five FPS by itself.

Evidence: `hardware/rfrowprof-{thps,cod}/`,
`hardware/row-profile-comparison.json`, and the diagnostic's `build/validation/`
under `build/timing-closure/`. Original INI/CFG and the stripped seed-13 RBF
were restored and hash-verified; the phone is idle at 50 seconds and temporary
input/Zaparoo servers are absent. See `hardware/row-profile-restored-stripped104/`.

Two isolated 4 KiB mapping trials complete fitting: the row-profile variant
and `tlb-fix-rfbank4k104-s13`, whose only synthesis-source change from the
best stripped parent is the SDRAM address permutation. No CPU or framework
file is changed relative to either parent. SDRAM timing/data/byte-mask and
boundary tests, two longer random seeds, fault injections, both UPP
configurations and whole-core/HPS-read checks pass for the diagnostic.
The first whole-core run used the older loader-overlay coordinates and
failed four pixel-read assertions; after moving those reads to the actual
FrameV2 rows 201/205, all checks pass over 150,622,764 clocks. That first
run is retained as invalid.

| 4 KiB build | ALMs | Registers | M10Ks | DSPs | Worst setup | Minimum hold |
|---|---:|---:|---:|---:|---:|---:|
| Row/frame diagnostic | 35,056 | 41,640 | 483 | 42 | -1.792 ns | +0.037 ns |
| Stripped | 33,593 | 38,509 | 483 | 42 | -1.529 ns | +0.115 ns |

The diagnostic RBF hash is
`4de634a30e4dd842b072358b20cf4d7806aa11a6c18edb22934bae21d8a679b7`;
the stripped hash is
`124cc93a13b8a908c5068f90ba2d76ce0550e3c9cf32bf00c00c7e402b184b36`.

The diagnostic runs both games and reaches phone idle by 50 seconds on both
boots. Tony Hawk's two 24-pair stopped Warehouse windows give **18.583 and
18.500 changing complete uploads/s**, versus 18.042 in the fresh original-
mapping control. Instruction throughput is 46.606 M/s in both windows,
versus 45.397 M/s. Actual row hits reach 56.92% / 56.88%, conflicts fall
to about 29.04%, and CPU SDRAM wait falls from 24.58% to about 22.59%.
This is a repeated small gain of approximately half a frame per second,
not the requested five. Screenshots show the same starting camera and
stopped position; this remains a matched scene rather than deterministic
replay. The second window uses Retry without reloading the core.

CoD's 30-pair opening-forest window gives 6.767 complete uploads/s versus
6.700 control, with 55.092 versus 55.258 M instructions/s. This is no
meaningful demonstrated gain. Its changing-image rate is 1.100/s as the
background settles. Actual row hits increase to 43.36% and conflicts fall
to 36.09%; CPU SDRAM wait falls from 16.58% to 15.62%. Every selected sample
in all three candidate windows has actual row hits exactly equal to the
independent 4 KiB shadow counter. All sampled fault/loader records and
incomplete/untracked upload counts are zero. Both games run and pause.

Evidence: `hardware/rfbank4k-{thps,cod}/`,
`hardware/bank4k-game-comparison.json` and `hardware/deploy-rfbank4k/`.
Neither candidate is promoted: the stripped fit is worse than the existing
-1.301 ns best, the five-FPS goal remains unmet, and the stripped 4 KiB RBF
has not been hardware-tested.

A separate timing-only trial, `tlb-fix-rfflashselect104-s13`, changes the
flash array-mode selection in `upp_bus` to use address bit 25 directly.
Every use is qualified by a decoded CS0/CS1 target; a SAT proof verifies
the replacement for all addresses and control inputs under that guard.
This removes the full range decoder from the chip-selection mux without
adding a clock. Both UPP configurations pass, and all 94 transaction-count
and latency-summary rows match the unchanged controller exactly. CPU and
framework sources are byte-identical to the stripped parent. This is not
a whole-bus formal proof or an FPS improvement. Its fit completes at
33,093 ALMs, 38,430 registers, 483 M10Ks and 42 DSPs, with -1.751 ns setup
and minimum hold +0.050 ns. The leading path is now `late_done` to
`o_lock_any`; this does not improve overall timing. RBF SHA-256:
`a7c3789fc3a6e3460fd6b6ce0792751916cb2a4f7aae9e6c2950fbe4de7d17ed`.
It is not hardware-tested or promoted.

After all measurements, the original INI/CFG and stripped seed-13 RBF are
hash-verified and restored, with phone idle visible at the 50-second check.
No temporary input/Zaparoo server, local simulation or Quartus process or
container remains. Restoration evidence:
`hardware/bank4k-restored-stripped104/`. The best restored setup remains
-1.301 ns; the five-FPS goal and timing closure remain open.

## D-cache fill waits and shorter lookup restoration

`tlb-fix-rffillprof104-s13` is an isolated FrameV2 diagnostic. It exports
19 registered observations from the D-cache FSM and reuses the previous
36-counter overlay. Counters partition raw request waits by filling line,
victim line and other line; by whether the requested fill word has arrived;
and by fetch, writeback, installation and final lookup-restoration state.
Additional counters identify reads/stores and permission-qualified waits.
These are observations, not claims of removable CPU cycles. No control or
payload consumes the new signals.

A Yosys equivalence check at the actual 16 KB/two-way/16-byte geometry proves
all 1,686 original FSM output/state cells unchanged after removing only the
new observation output. The wrapper changes only connect that port. All 57
framework files remain byte-identical. Source and generated CPU builds pass
nine directed cache cases each, with identical cycle counts, signatures and
retirement traces. Debug and stripped whole-core lint pass with the existing
unused debug/stub signal warnings suppressed. The default lint target first
failed because its file list lacks the pre-existing altdpram simulation stub;
explicitly supplying that stub resolves elaboration. Reader fixtures pass at
1x/2x/4x and reject five inconsistent partitions and a fault record. Quartus
and hardware measurements remain pending at this checkpoint.

A separate functional candidate, `tlb-fix-rfrelookup2frame104-s13`, shortens
both background repair and final restoration from three edges to two: one
RAM read edge and one registered comparison/data-response edge. It preserves
fill installation, victim writeback, permissions and the CPU's own reload
schedule. Only the D-cache FSM and regenerated CPU change relative to
FrameV2. Its first 21 focused source checks pass, including cache aliases,
held accesses, fill ordering and the stale-TLB regression. The full source
suite and two Quartus fits are running. The second fit,
`tlb-fix-rfrelookup2104-s13`, applies the same state change to the best
stripped parent. Neither candidate is hardware-tested or promoted yet.

Current job and evidence pointers are in
`build/timing-closure/active-experiments-fill.json`. The MiSTer still has its
original stripped build and original INI/CFG at this checkpoint.

The fill profiler completes fitting at 34,764 ALMs, 40,834 registers,
483 M10Ks, 42 DSPs and 3,641,769 RAM bits. Worst setup is -2.247 ns;
minimum hold is +0.067 ns. Its RBF SHA-256 is
`f0a83d29597cb769156880c53304da5a10c8cfc9164e6dbe40ea488d8e8bb47a`.
Both original game cards boot to phone idle by 50 seconds and run/pause.
All 24 Tony Hawk and 30 CoD paired windows validate their counter partitions,
with zero sampled CPU/loader faults and zero incomplete/untracked uploads.

| Measured quantity | Tony Hawk | CoD |
|---|---:|---:|
| Complete uploads/s | 18.333 | 6.700 |
| Changing complete uploads/s | 18.333 | 1.067 |
| Retired million instructions/s | 45.817 | 54.534 |
| Request waiting during D-fill (% clocks) | 9.771 | 9.141 |
| Waiting for the filling line | 7.502 | 6.769 |
| Same line, requested word already buffered | 3.198 | 2.816 |
| Same line, requested word not buffered | 4.304 | 3.953 |
| Same-line ready load waits | 1.425 | 1.966 |
| Same-line ready store waits | 1.773 | 0.850 |
| Final lookup restoration waits | 1.106 | 0.992 |
| Waiting for the evicted victim line | 0.019 | 0.001 |
| Other-line waits | 2.249 | 2.371 |

All wait rows are percentages of the 104 MHz clock, and several rows
**overlap**. In particular lookup-restoration time is not an additional
cost to add to already-buffered-word waits. These measurements do not
support expecting five more FPS from fill-buffer forwarding alone. CoD's
stationary background again settles, so changing-image frequency is not
used as its rendering-throughput measure. Evidence:
`hardware/rffillprof-{thps,cod}/` and `hardware/fill-profile-comparison.json`
under timing-closure.

The two-edge restoration now passes all 345 source and 345 generated CPU
cases, with every cycle count and all 115 first-latency signatures/traces
identical between source and generated models: 403,907,560 clocks per suite.
Against the previous validated ALU-base-forwarding candidate, 113 signatures
are byte-identical. The other two contain only changed absolute bench timer
readings (`iprefetch_rtl`) and interrupt landing/timing fields
(`arm9_irq_ldm_rtl`); all interrupt failure fields remain zero across 19
sweeps. This is not a cycle-identical change. The two synthetic rendering
windows improve only 0.25–0.88% at the three bus latencies, with unchanged
result signatures; these are not FPS predictions.

| Two-edge restoration build | ALMs | Registers | M10Ks | DSPs | Worst setup | Minimum hold |
|---|---:|---:|---:|---:|---:|---:|
| Frame diagnostic | 35,291 | 42,664 | 483 | 42 | -1.748 ns | +0.092 ns |
| Stripped | 33,497 | 38,318 | 483 | 42 | -2.651 ns | +0.115 ns |

The diagnostic RBF SHA-256 is
`3a18eb1df8a6560be12735c909f15f87c80de8d2888237023a8e9e875c8ac2b3`;
the stripped hash is
`fd015b3698e78a37e0cc920fc47fbc78cc5284a03026a620f5601890c4ac93fa`.
The stripped fit is worse than the existing -1.301 ns best. The reported
hot-corner leading path is in decode (`d1` to `d2_q`), not the shortened
cache state sequence.
Neither build is promoted. The diagnostic reaches phone idle by 50 seconds;
its two-game performance check is in progress. The stripped RBF remains
hardware-untested. All three Quartus jobs have finished and their temporary
Docker containers have exited.

The two-edge diagnostic runs both games and boots to phone idle by
50 seconds on both attempts. Tony Hawk's 24 paired samples average
18.375 changing complete uploads/s and 45.911 M instructions/s, versus
18.333 and 45.817 M in the fresh fill-profiler control. CoD's 30 pairs
average 6.667 complete uploads/s and 55.141 M instructions/s, versus
6.700 and 54.534 M control. No useful FPS improvement is demonstrated.
CoD's changed-image rate is 0.900/s as background animation settles.
Both games run and pause; all selected samples have zero fault/loader
records and zero incomplete/untracked uploads. The control profiler is
formally behavior-equivalent to FrameV2 but is a different instrumented
RBF; this remains a matched-scene comparison, not deterministic replay.

The candidate is rejected: the tiny synthetic improvement did not become
a useful game-speed gain, and the stripped fit worsens setup to -2.651 ns.
No root functional RTL is promoted. Evidence:
`hardware/rfrelookup2-{thps,cod}/`,
`hardware/relookup2-game-comparison.json`, and both trials' `build/validation/`.
The original stripped104 build and original INI/CFG have been copied back
and hash-verified; the final 50-second boot check is running at this entry.

Final restoration is verified: original INI/CFG/RBF hashes match, phone idle
is visible at the 50-second check, and no temporary input/Zaparoo server,
local simulation or Quartus process/container remains. Evidence:
`hardware/relookup2-restored-stripped104/`. The restored best setup remains
-1.301 ns. The +5 FPS objective and 104 MHz timing closure remain open.

## Zero-offset late-base experiment

`tlb-fix-rfzerobaseframe104-s13` starts from FrameProfileV2. A preindexed
scalar load/store with an immediate zero offset, no base writeback and no
PC base uses A's existing late operand forwarding for its address. Decode
marks that base as late; a registered class bit selects the resolved base
instead of the earlier S-stage address. Other memory addresses keep the
S-stage adder/register. Existing ownership, self-dependency trust, fault,
condition and retirement checks remain. The stripped counterpart starts
from `tlb-fix-rfexplicit104-s13`. Both retain their parent's top, clock,
constraints and 57 framework files byte-for-byte. No root CPU change is
promoted.

The 21 focused source cases pass. Full source coverage is 345 cases after
six targeted reruns, totaling 405,961,903 clocks. The first full run's four
failures remain recorded: the warmed `ldr_base` window is intentionally
four clocks instead of five, and three `arm9_sagu_rtl` runs trip an old
assertion assuming all memory bases consume S's AGU result. The isolated
cycle model changes only the configured-predictor `ldr_base` expectation.
The assertion now checks early memory bases; a separate assertion checks
the late class, resolved operand and exact zero-offset address. Regeneration
before and after this assertion-only adjustment produces byte-identical
synthesis Verilog. All six affected cases then pass; no architectural test
or failure check is disabled.

Against the behavior-equivalent pipeline-profile control, 112 of 115
signatures are identical. `iprefetch_rtl` differs only in saved absolute
R7/R11 timer reads, `walloc_rtl` only in four saved R3 timer reads, and
`arm9_irq_ldm_rtl` only in sweep timing and interrupt landing observations.
All 19 interrupt sweeps complete with zero failure, handler-error and
differing-register fields. The checked rendering loops pass on source and
generated models with identical signatures, traces and clocks: palette
7,747 / 7,847 / 8,695; texture 10,758 / 10,907 / 11,800 at bus latencies
0:0 / 0:3 / 2:9. This is about 4% fewer clocks in the texture loop and
essentially no palette benefit; it is not a game-FPS prediction.

Whole-core debug/stripped lint passes. Fresh FrameProfileV2 controls use the
original cards and existing save: Tony Hawk reaches phone idle by 50
seconds and gives 18.041667 changing complete uploads/s across 24 paired
windows, with no sampled faults, loader errors or incomplete/untracked
uploads. CoD's control boot is also idle by 50 seconds.
Evidence: both trial `build/validation/` directories,
`hardware/zerobase-control-{thps,cod}/`, and
`build/timing-closure/active-experiments-zerobase.json`.

Both fits complete with failing setup:

| Zero-base variant | ALMs | Registers | M10Ks | DSPs | Worst setup | Minimum hold |
|---|---:|---:|---:|---:|---:|---:|
| Diagnostic | 35,122 | 41,648 | 483 | 42 | -2.790 ns | +0.057 ns |
| Stripped | 33,856 | 38,315 | 483 | 42 | -2.653 ns | +0.081 ns |

Both retain 3,641,769 block-memory bits. The stripped result is worse than
the existing -1.301 ns best. Its hot-corner worst path goes from CPU W's
record to D-cache metadata `valid_live_q`; another violated path goes from
A into the TLB read-valid logic. The diagnostic's hot-corner worst path is
within decode, D1 to D2. Its colder -2.790 ns path has not been separately
inspected. Diagnostic RBF SHA-256 is
`5dfbb7541f6484562f743ecc11ed21f18f266784d03abc8e92e28fa56897d139`;
stripped SHA-256 is
`92f75a0dc95a12105f6abdf5f3ea0404c05691971f6abce2f2f43a56106f8b86`.

The fresh CoD control averages 6.800 complete uploads/s over 30 paired
windows, with no sampled errors or incomplete/untracked uploads. Its
0.933 changing uploads/s reflects the stopped scene's settling animation.
The candidate diagnostic reaches phone idle by 50 seconds with both games.
The stripped RBF is not hardware-tested.

The full generated-Verilog suite completes on Ubuntu (Verilator 5.032):
345/345 pass, with all result codes, cycle/instruction counts, signatures
and streamed trace hashes exactly matching the combined Mac source results
(Verilator 5.052). Each suite totals 405,961,903 clocks. The only Mac runs
repeated after the test-scaffolding corrections are the six documented
`arm9_cycles`/`arm9_sagu_rtl` cases. Original mismatch logs remain intact.
The independent generated suite is a clean full pass. Evidence:
`build/validation/source-generated-comparison.json` in the diagnostic trial.

Both candidate games run and pause normally. Tony Hawk's 24 paired windows
average 18.541667 changing complete uploads/s and 46.214 M instructions/s,
versus 18.041667 and 45.309 M control. This one-window +0.5 gain is far below
the five-FPS objective. CoD's 30 paired windows average 6.633333 complete
uploads/s and 54.981 M instructions/s, versus 6.800000 and 54.439 M control;
there is no demonstrated improvement. Its changing-image rate is 1.633333/s
as stationary-scene animation settles. All selected windows have zero
fault/loader records and incomplete/untracked uploads.

These are matched scenes and input sequences, not deterministic replays;
phone-idle dwell and animation phase differ. The long elapsed timestamp
before candidate CoD launch is analysis time spent at phone idle, not a
boot delay. Both idle screenshots are already ready at 50 seconds.
Evidence: `hardware/rfzerobase-{thps,cod}/` and
`hardware/zerobase-game-comparison.json` under timing-closure.

The candidate is not promoted: it gives no useful two-game improvement and
worsens stripped setup from -1.301 to -2.653 ns. No root functional RTL is
changed by this experiment. The original stripped104 RBF and original
INI/CFG hashes match, the original Tony Hawk card is mounted, and phone
idle is visibly ready at the 50-second restoration check. Temporary input/
Zaparoo servers, local simulations and Quartus processes/containers are
absent. Restoration evidence is in `hardware/zerobase-restored-stripped104/`.
The five-FPS objective and timing closure remain open.

## Cache live-bit lookup timing experiment

Two isolated stripped104 trials, `tlb-fix-rflivemux4104-s13` and
`tlb-fix-rflivemux16104-s13`, divide the cache's `valid_live` register lookup
into four or sixteen parallel bank reads. The bank results and high index
are registered on the original read edge; a small selection follows it.
There is no additional cycle or change to RAM capacity, RAM primitives,
valid-group initialization, invalidate behavior or the CPU pipeline.
The parent is the existing best stripped104, not the rejected late-base CPU.
This targets a path that became critical in late-base experiments; the
parent's current worst path is still audio arbitration into flash control.
A global timing improvement is not assumed.

Both changed blocks are extracted from their actual sources and proved
equivalent by temporal induction for 32 through 2,048 sets (seven sizes).
Inputs are arbitrary, including simultaneous writes, holds, clears and
cache-disable. State is not assigned artificial initial values; the property
checks equivalence after a reset has occurred. The low read-bit register is
also checked after its first read edge. Source and generated four-bank cache
miters pass all common outputs and registered metadata in four configurations,
including read-only instruction metadata and full maintenance walks.
The added read-only case correctly expects zero dirty-clean events; the
original three dirty-cache coverage requirements remain unchanged.

Both variants pass debug and stripped whole-core lint. Their top, QSF, SDC,
QIP and 57 framework files match the parent. Only the cache tag RAM source
and regenerated CPU differ. The sixteen-bank source/generated cache miters
also pass with the same coverage counts as the four-bank variant. Both
Quartus fits subsequently complete; results are recorded below. Neither
cache-only candidate has been loaded on hardware.
Evidence: each trial's `build/validation/`,
`research/metadata-live/{prove,miter}.py`, and
`active-experiments-live-lookup.json` under timing-closure.

Two companion variants, `tlb-fix-rfliveor8104-s13` and
`tlb-fix-rfliveor16104-s13`, register zero for unselected banks and OR the
registered bank results. This moves the high-index selection before the
same register edge and changes the logic after it. Both pass the same seven
induction proofs, debug/stripped lint and four-configuration source/generated
cache miters. Coverage counts match all four trials. All four Ubuntu fits
complete, with these results:

| Lookup variant | ALMs | Registers | Worst setup | Minimum hold |
|---|---:|---:|---:|---:|
| Four selected banks | 33,021 | 38,392 | -2.551 ns | +0.060 ns |
| Sixteen selected banks | 33,610 | 38,192 | -1.613 ns | +0.078 ns |
| Eight gated banks, OR | 33,464 | 38,557 | -2.084 ns | +0.077 ns |
| Sixteen gated banks, OR | 33,776 | 38,370 | -1.651 ns | +0.062 ns |

All retain 483 M10Ks, 42 DSPs and 3,641,769 RAM bits. None improves the
parent's -1.301 ns worst setup, so none is promoted or hardware-tested.
Post-fit reports nevertheless show a local benefit: the sixteen-bank OR
family has +0.564 ns outgoing and -0.319 ns incoming hot-corner slack,
versus -0.805 and -0.764 ns for the parent's original lookup family.
Those wildcard families include physical-synthesis copies/OTERM registers;
their counts are not counts of original logical registers. Local improvement
does not establish global timing closure. Reports and compact comparisons
are in `research/metadata-live/{fit-comparison,family-comparison}.json` and
each trial's `build/live-lookup-timing/`.

While those fits run, the existing simulation-only `S_AGU=0` model is being
tested against the full CPU suite. Its actual source is verified against
FrameV2: only the existing `S_AGU` default differs, and the model is newer
than every SystemVerilog input. Original cycle expectations remain in place
so any changes are visible for review. This is separate from the cycle-exact
metadata experiments and has no fitted or hardware-tested core yet.
Evidence: `research/game-hotspots/cpu-sagu0/full-validation/`.

The initial `arm9_cycles` result changes only `ldr_base`, four clocks instead
of five in both visits. A separate full trial,
`tlb-fix-rfsagu0frame104-s13`, has matching source inputs and a freshly
generated CPU/model with `RAM_RF_TAP`. Its isolated cycle expectation changes
only that configured-predictor row; the predictor-off column, original table
and original failure log are retained. The validation sequence waits for all
original source results and stops on any unexpected failure before running
the three targeted source cases and full generated suite. It runs at most one
Mac simulation at a time. No Quartus build or hardware test of this option has
started. Results/status will be in that trial's `build/validation/sequence.json`
and `source-generated-comparison.json`.

## Full late-address option: validation, fits and gameplay

The `S_AGU=0` trial above subsequently completes its source/generated CPU
validation and both Quartus fits. The only functional source edit is the
existing parameter's default, plus regenerated Verilog. All 345 source and
345 generated cases pass, with exactly matching result codes, cycle and
instruction counts, signatures and streamed trace hashes: 405,345,215 clocks
per suite. The sole updated cycle-window expectation is `ldr_base`, from five
to four clocks in the configured-predictor column; the predictor-off column
is unchanged. No HDL assertion was relaxed. The original failure and table
are retained, and all three latency cases of that test were rerun.

Against the behavior-equivalent pipeline-profile control, 112/115
first-latency signatures match exactly. The other three contain only reviewed
absolute timer snapshots (`iprefetch_rtl`, `walloc_rtl`) or interrupt landing
statistics (`arm9_irq_ldm_rtl`); relative checks and all failure fields pass.
Source/generated equality does not mean cycle equivalence to the old CPU.
See `build/validation/baseline-signature-comparison.json` and
`source-generated-comparison.json` in `tlb-fix-rfsagu0frame104-s13`.

| Build | ALMs | Registers | M10Ks | DSPs | Worst setup | Minimum hold |
|---|---:|---:|---:|---:|---:|---:|
| FrameV2 diagnostic | 34,887 | 42,050 | 483 | 42 | -2.106 ns | +0.074 ns |
| Stripped | 33,301 | 37,980 | 483 | 42 | -1.529 ns | +0.088 ns |

Both fail setup. The stripped hot-corner leading path (-1.524 ns) starts at
W's short-load selector, passes through operand forwarding and the ALU
address calculation, and ends at the cache valid-live lookup. There is no
change to top-level configuration, constraints or the 57 framework files.
The diagnostic RBF SHA is
`9197acd9442c3e1ad74cf222606335fce4ed360223eb9ad578257abcf43c7645`;
the stripped SHA is
`4219bb045005a07b39af2e63845e2dcc51ab30fa7c899eb02d78149660e085a8`.
The stripped candidate has not been hardware-tested.

Fresh controls and candidates use the original cards, existing save and
identical scene sequences. Boot readiness is checked at 50 seconds; the
first game-selection input is scheduled at 120 seconds after loading for
all four measurements. The 120-second dwell is deliberate, not boot time.
A deadline guard rejects late starts before sending any game input. Two
abandoned control starts are retained and excluded from game measurements.

| Game | Paired windows per build | Control uploads/s | S_AGU=0 uploads/s | Control / candidate M instructions/s |
|---|---:|---:|---:|---:|
| Tony Hawk, braked Warehouse | 24 | 18.375 | 18.583 | 45.797 / 46.484 |
| Call of Duty, opening forest | 30 | 6.600 | 7.000 | 54.609 / 57.259 |

Tony Hawk's full uploads all change. CoD's candidate changes 1.333 images/s
as background animation settles; its complete upload rate is used for
render throughput. These are matched scenes, not deterministic replays or
optical frame-pacing measurements. Both candidates reach idle by 50 seconds,
run and pause normally; screenshots are inspected. All selected snapshots
have zero sampled CPU/loader faults and zero incomplete/untracked uploads.
The first-window gains (+0.208 Tony Hawk, +0.400 CoD) are below the five-FPS
goal and do not justify promoting a slower-timing build. Root functional RTL
is unchanged by this experiment. Evidence: `hardware/sagu0-control-{thps,cod}`,
`hardware/rfsagu0-{thps,cod}`, `hardware/sagu0-game-comparison.json`, and
`active-experiments-sagu0.json`, all under `build/timing-closure/`.

After measurement the original stripped104 RBF, INI and CFG hashes match
their saved originals. The original Tony Hawk launcher/card is loaded and
phone idle is visibly ready at 50 seconds. Temporary input/Zaparoo servers,
local simulations and Ubuntu Quartus processes/containers are absent.
Restoration evidence is in `hardware/sagu0-restored-stripped104/`.
The five-FPS objective and 104 MHz timing closure remain open.

## Exhaustive cycle partition diagnostic

`tlb-fix-rfcycleprof104-s13` replaces only the existing FrameV2 CPU observation
output with registered diagnostic events. Fourteen mutually exclusive
categories count retirement, WFI, the oldest W/memory-queue/A/S record,
decode hazards, or other frontend clocks. The memory queue includes both M
and the skid record. Their steady-state per-second counts must total exactly
104,000,000. This partitions observed occupancy, not hypothetical removable
stall costs. In particular, A with a background lock present does not prove
that lock is A's dependency. Four additional correlations explicitly overlap.

Six companion counters partition clocks by retirement and oldest-record PC:
ROM 0x50000000–0x51ffffff, the observed loaded-code ranges
0xff900000–0xff9fffff / 0xfff00000–0xfffeffff, and other/unknown. Loaded module
ownership remains unconfirmed. When no W/M/skid/A/S record is valid the
attribution is unknown; frontend PCs are not silently substituted. Completed,
changed, incomplete and untracked LCD counters remain in their original slots.
The observer adds one registered edge before counting; the original base
instruction counter is unchanged.

Formal checks prove one phase and one PC category for every possible input,
including reserved LCD slots remaining zero. A separate modular equivalence
proof compares all original CPU outputs and every input to its four child
blocks while treating the byte-identical children's outputs as shared
arbitrary inputs. All 9,233 equivalence cells pass; the other 29 generated
modules are byte-identical. This proves functional noninterference, not
identical FPGA placement. Debug/stripped whole-core lint passes. The capture
reader passes 13 positive/rejection checks, including 1x/2x/4x screenshots,
incorrect conservation totals, fault/loader records, partial uploads and
inconsistent paired captures. The initial compile was stopped during synthesis
to include skid occupancy; the corrected build completed successfully through
fitting and failed the setup check as reported below.

The fitted diagnostic uses 34,787 ALMs, 42,359 registers, 483 M10Ks, 42 DSPs
and 3,641,769 block-memory bits. Worst setup is -1.660 ns and minimum hold
is +0.113 ns. Its RBF SHA-256 is
`adf94afc25c41b2d318808df45320b23500337ed4e14323bbc518f5167484cc1`.
The generated CPU and all 57 framework hashes are checked against provenance
before staging. This build is for observation and is not promoted.

Both original game cards reach phone idle by 50 seconds, then use the
existing save and the same input sequences starting at 120 seconds. The
120-second start is deliberate dwell, not boot time. Tony Hawk's 24 paired
windows and CoD's 30 pairs each verify exactly 104,000,000 clocks in both
independent partitions. All selected snapshots have zero CPU/loader faults,
incomplete uploads and untracked uploads. Gameplay and pause screenshots are
visually checked.

| Measured quantity | Tony Hawk, braked Warehouse | CoD, opening forest |
|---|---:|---:|
| Complete uploads/s | 18.042 | 6.467 |
| Changing complete uploads/s | 18.042 | 6.033 |
| Million instructions/s | 45.368 | 55.530 |
| Retired micro-operations (% clocks) | 47.049 | 55.841 |
| No retirement: W request waiting | 12.221 | 9.978 |
| No retirement: W locked | 0.071 | 0.049 |
| No retirement: W other | 4.819 | 3.563 |
| No retirement: M/skid oldest | 13.977 | 15.549 |
| No retirement: A oldest, background lock present | 3.702 | 2.148 |
| No retirement: A oldest, other | 4.041 | 4.114 |
| No retirement: S oldest, load wait | 0.000 | 0.000 |
| No retirement: S oldest, other | 3.236 | 2.976 |
| No retirement: decode load/lock hazard | 0.500 | 0.240 |
| No retirement: decode early hazard | 0.000 | 0.000 |
| No retirement: decode fence | 0.074 | 0.026 |
| No retirement: other frontend | 10.311 | 5.517 |
| No retirement: WFI | 0.000 | 0.000 |

All phase rows are percentages of the full clock, not percentages of
non-retiring clocks. M/skid being oldest does not mean the queue itself
blocked that clock; a preceding dependency or frontend bubble can produce
this occupancy. Similarly, the zero decode-early category means that hazard
was never the highest-priority category, not that early-operand hazards never
occurred. These observations must not become additive speedup predictions.

The independent PC partition attributes 18.440% / 20.932% of clocks to an
oldest ROM record, 70.477% / 73.195% to the observed loaded-code ranges, and
11.084% / 5.873% to other or unknown records (Tony Hawk / CoD). The loaded
module identities remain unconfirmed, and frontend gaps cannot be reassigned
to ROM or application code. These results do not establish a ROM-only time
budget or a bound on possible kernel-fix gains.

The overlapping no-retirement correlations are data fill busy
19.331% / 15.572%, background lock 8.001% / 6.911%, instruction request
waiting 7.552% / 3.705%, and redirect/flush 0.258% / 0.146%. They are
separate from the exclusive table. No FPS improvement is demonstrated by this
observation-only build. The five-FPS objective and 104 MHz closure remain open.

The next source investigation is whether a cache-hit load can safely supply
a dependent ALU operation one stage earlier. The existing two-edge cache and
registered MMU checks must be respected; raw tag/data availability alone
does not establish a usable load. There is no new early-load RTL or proven
safe bypass at this checkpoint, and no estimated game gain is claimed.

After measurement the original stripped104 RBF, INI and CFG hashes match
their originals. The original Tony Hawk launcher/card is loaded and phone
idle is visibly ready at 50 seconds. Temporary input and Zaparoo processes,
local simulations and Ubuntu Quartus processes/containers are absent. Evidence:
`research/cycle-partition/`, the trial's `build/validation/`,
`summarize_cycle_pairs.py`, `hardware/cycle-profile-results.json`,
`hardware/cycleprof-{thps,cod}/`, `hardware/cycleprof-restored-stripped104/`
and `active-experiments-cycle-profile.json`, all under
`build/timing-closure/`. The MiSTer framework, top-level configuration,
constraints and memory geometry are unchanged.

## Early cache-hit load forwarding: rejected

The isolated `tlb-fix-rfearlyload104-s13` experiment offers the permitted,
formatted M-stage cache hit to a dependent late ALU operand before the
existing W register. It preserves permission checks, cache geometry and
the 104 MHz clock. Eligibility excludes fills, locks, maintenance, faults
and older operations that can invalidate ownership. Directed predictor-on
word, byte, halfword, signed and unaligned load-to-ALU windows shorten from
four clocks to three. All six changes are recorded in a separate cycle
expectation table; predictor-off is not tested.

The first source regression passes 342/345. Its three failures expose an
omitted older PC-write exclusion: `moveq pc,lr` schedules a registered flush
that cancels the following literal load. The early data matches the normal
data, but the assertion correctly rejects the promise of an accepted load.
The v2 simulation trial adds `!w.pc_write`, retains all assertions, and
passes all 345 cases (406,132,325 clocks). The exact-parent control passes
345 cases (406,232,597 clocks). These totals include timing-dependent
interrupt sweeps and are not gameplay measurements. All but two signatures
match; the differences are interrupt-sweep statistics. Several retirement
traces differ, and a complete equivalence claim is not made.

The physical results reject the direct data path:

| Original bypass fit | Worst setup | Worst hold | ALMs | Registers | M10K | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Stripped | -6.757 ns | +0.105 ns | 32,991 | 37,532 | 483 | 42 |
| FrameV2 diagnostic | -7.054 ns | +0.060 ns | 34,507 | 40,509 | 483 | 42 |

The stripped critical path crosses cache word selection/formatting,
forwarding and execution arithmetic before reaching M, with 14.551 ns of
data delay. The best original stripped fit remains -1.301 ns. Adding the
v2 redirect guard does not shorten that data path, so v2 is not fitted.
The generated-code regression is deliberately stopped after 37 passing
cases, each exactly matching source cycles, instructions, signatures and
traces. It requires `-DRAM_RF_TAP` to observe the banked register file;
the earlier run without that probe is invalid harness evidence. A full
generated regression and hardware validation are not claimed.

The palette and texture kernels have identical cycles, instructions,
signatures and traces to the parent at all three memory latencies, despite
nonzero early-use counters. A follow-up source-only trial,
`tlb-fix-rfearlyissue104-s13`, retains only the decode admission relaxation
and the original registered load pickup. Its three cycle tests and three
kernel runs also match the parent exactly; no fit is warranted by those
results. Neither variation is promoted or deployed.

The original MiSTer RBF, INI and CFG hashes are reverified unchanged. No
framework or root functional RTL is changed in this experiment, and its
simulation/build processes and temporary Quartus containers are finished
or stopped. Evidence is in `research/early-load/results.json`,
`research/early-load/reference/v2-comparison.json`, the three bypass trial
validation directories and `active-experiments-early-load.json` under
`build/timing-closure/`. The five-FPS goal and 104 MHz timing closure remain
unachieved.


## Retirement-window diagnostic: verified on both games

The previous PC samples observe fetch addresses, and the synthetic palette
and texture improvements have not translated into the requested game gain.
A new isolated `tlb-fix-rfretireprof104-s13` diagnostic records actual
retirement sequences before selecting another functional CPU change.

It adds only the decoded instruction word beside the existing writeback
outputs. A core-boundary equivalence proof passes; the two generated wrappers
differ only in this output/connection and the remaining 27 generated modules
are byte-identical. Framework sources, clock configuration and timing
constraints remain identical to the FrameProfileV2 parent.

A 1,024-entry, 128-bit ring records micro-operations, conditional failures
and exceptions with their PCs, instruction words, clocks, processor mode,
flags and accumulated existing stall taps. It freezes 32 jittered windows
starting at 180 CPU seconds, dumping each afterward through the existing
loader into the already-reserved 1 MiB DDR trace area. Headers are invalidated
first and committed last. The loader is shared with flash traffic; the CPU
proof does not establish absence of a board-level observer effect.

Component simulations at 8 and 1,024 entries verify exact payloads,
wraparound, backpressure and a CPU reset during an incomplete dump. The reader
round-trips 2,075 simulated events, rejects malformed headers and handles
32-bit timestamp wrap. Equal-duration 1,000-clock slices supplement the
variable-duration event rings to avoid double-weighting slow samples. An
interval ending at an instruction is not isolated instruction latency or
proof of the cause of its delay. A synthetic check recovers the known base
of 1,024 original Tony Hawk instruction words. Real hardware mapping results
are below.

Generated top-level lint passes with and without the debug macro, with named
unused observation signals and primitive-stub warnings scoped out. The Ubuntu
fit finishes at -1.508 ns setup, +0.103 ns hold, 36,051 ALMs, 42,573 registers,
496 M10Ks and 42 DSPs. Its RBF SHA-256 is
`18c286148042127786d666a38dca89a2bfed754cbd257f4ac2960c31ce3ee409`.
It is a timing-failing diagnostic, not a release candidate.

Both games boot to the phone idle screen by the 50-second check and produce
32 complete windows, or 32,768 events each. Exact original ARM opcode matches
confirm Tony Hawk at 0xff900000 (3,992/3,992 distinct sampled in-range PCs) and
CoD at 0xfff00000 (3,550/3,550). Weak DLL candidate matches are not accepted as
module mappings. Equal-duration analysis uses 32,000 clocks per game.

Tony Hawk's stopped Warehouse scene averages 18.417 complete/changing uploads/s
over 24 paired samples; six post-trace pairs give 18.333. CoD's initial forest
averages 6.667 complete uploads/s over 30 pairs and 6.833 afterward. Its changing
image rate falls to zero after the background settles: this is a static scene,
not zero rendering throughput. Both have zero incomplete/untracked uploads and
no sampled CPU faults or loader errors. These are matched scenes, not
deterministic replay or a demonstrated performance improvement.

The captured Tony Hawk two-store loop at 0xff92d7f8 has 149 complete observed
iterations, averaging 21.826 clocks: 74 take seven clocks and 67 take 37.
This motivates testing streaming stores and allocation, but the stall taps
do not prove an isolated cause. In particular, the code-stall bit includes
front-end backpressure and is not an instruction-cache-miss counter. The
loop samples also overlap other windows and are not a whole-game cost model.

The original stripped RBF, INI and CFG are restored and SHA-256 verified.
The restored phone is idle at the 50-second screenshot. No temporary input
server, Zaparoo process or Quartus container remains running. Evidence is in
`hardware/rfretireprof104-{thps,cod}-run2/` and
`hardware/retire-restored-stripped104/`, under `build/timing-closure/`.
Recorder validation and the resumable workflow are in
`research/retire-windows/`; job state is in
`active-experiments-retire-windows.json`. No functional RTL is promoted;
the five-FPS goal and timing closure remain unachieved.

## Posted write-back misses: small hardware gain, timing still fails

The isolated `tlb-fix-rfpostedstore104-s13` adds a four-entry ordered FIFO
for permission-checked physical write-back store misses when MMU and CP15 W
are enabled. Those stores no longer allocate cache lines. Dirty physical
synonyms retain clean-before-fill handling; WT, uncached and W-disabled
behavior is unchanged. The FIFO precedes later data fills, page-table walks
and maintenance, and CP15 drain includes its pending writes. This is a
partial policy experiment, not full TI925T write-buffer fidelity.

A 31,000-clock FIFO scoreboard checks ordering, payloads, full backpressure,
simultaneous push/pop and reset. Source and generated CPU regressions agree
exactly on all 345 result records: 330 pass; 15 failures assert the old
write-allocation policy. Seven focused policy/legacy tests at three latencies
all pass in both models, with identical cycles/signatures. The old repeated
store-only STM8 benchmark genuinely slows from nine clocks to 12/21 without
implicit cache warming; this is recorded rather than relabeled as unchanged
performance. Source/generation equivalence is not game validation.

The observed THPS five-instruction store loop improves in simulation: at
2:9 bus latency its cold 4 KiB stream falls from 12,424 to 7,774 clocks,
or 21,373 to 7,879 including cleanup/drain. Warm throughput is essentially
unchanged. Palette and texture kernels also improve, with checked outputs.

Stripped fit: -1.993 ns setup, +0.087 ns hold, 33,283 ALMs, 38,687 registers,
483 M10Ks and 42 DSPs. Its worst path remains forwarded data through the
execute shifter. The matching FrameV2 diagnostic is -1.794/+0.074 ns,
34,950 ALMs and 41,899 registers, with the same RAM/DSP count. Both fail
timing; the stripped fit is worse than the original best -1.301 ns.

Both original game cards boot to phone idle by 50 seconds. The scripted
braked Warehouse scene gives 18.917 complete/changing uploads/s and 47.463 M
instructions/s (24 paired samples), a small gain over the 18.1–18.4 controls.
CoD's initial forest gives 6.867 complete uploads/s and 56.601 M instructions/s
(30 pairs), essentially unchanged. All selected captures have zero incomplete
or untracked uploads and no sampled CPU faults or loader errors. Gameplay
screenshots are inspected. These are matched scenes, not deterministic replay;
CoD's changing-image count depends on the small background animation.

No functional RTL is promoted. The original INI/CFG/RBF hashes are restored
and the phone is visibly idle at the 50-second check. Evidence and source
provenance are under `build/timing-closure/research/posted-store/`,
`hardware/postedstore104-{thps,cod}/`, and
`hardware/postedstore-restored-stripped104/`. The next isolated prototype
tests the manual's additional WT/NCB buffering modes. Neither the five-FPS
goal nor timing closure is achieved.

## Additional WT/NCB modes: verified, little additional game gain

The isolated `tlb-fix-rfpostedmodes104-s13` extends the same four-entry
FIFO to the write-through and noncacheable-bufferable combinations in
TI SPRU671 table 2. It carries the PTE B bit through the registered TLB
check. WT hits update the cache and preserve its dirty state; queue-full
backpressure prevents acceptance and duplicate bus writes. Uncached SWP
remains synchronous. W-disabled behavior, FIFO capacity, cache geometry,
clock and constraints are unchanged. This is still partial TI925T buffer
fidelity, with no burst combining.

Source and generated regressions agree exactly on all 348 records: 333
pass and the same 15 old write-allocation assertions fail. The seven
focused policy/legacy tests pass at three latencies in both models.
Mode and external-error tests pass at four latencies with matching source
and generated counts/signatures. They cover WT clean-line preservation,
partial writes, read ordering, buffer-full handling, W/C-disabled controls,
SWP, permissions and precise versus ignored external aborts. Synthetic
WT/NCB streams improve; these are not game FPS measurements.

Stripped fit: -2.084 ns setup, +0.076 ns hold, 33,377 ALMs, 38,663 registers,
483 M10Ks and 42 DSPs. The profiling fit is -2.196/+0.098 ns, 35,091 ALMs
and 41,820 registers, with the same RAM/DSP count. Both fail setup.

Both games reach phone idle by 50 seconds. In the same scripted scenes,
THPS measures 19.000 complete/changing uploads/s and 47.623 M instructions/s
(24 paired samples); CoD measures 6.967 complete uploads/s and 56.747 M
instructions/s (30 pairs). The prior WB-only FIFO gave 18.917 and 6.867,
respectively. These tiny differences do not establish useful additional
game performance. CoD's 2.333 changing images/s reflects the partly static
scene, not rendering throughput. All selected samples have zero malformed
uploads and no recorded CPU faults or loader errors; screenshots are viewed.

The original stripped RBF, INI and CFG are restored and hash-verified; the
restored phone is visibly idle at 50 seconds. No functional source is
promoted. Evidence is under `build/timing-closure/research/posted-modes/`,
`hardware/postedmodes104-{thps,cod}/` and
`hardware/postedmodes-restored-stripped104/`. The five-FPS goal and timing
closure remain unachieved.

A separate controller-only experiment verifies 4,096 writes with full and
halfword masks at three seeds using unchanged memory-controller RTL.
Four-word bursts use 9,504 clocks versus 12,625 for classic writes, but
two-word bursts use 18,884 clocks. All data and untouched bytes are checked;
the timed interval includes a final ordered read. This rejects naive
two-entry coalescing. No CPU burst implementation or game gain is claimed.


## Address predecode fits and combined follow-up

The UPP target decoder now runs separately on CPU and DMA addresses before
selecting the existing registered owner, in isolated timing trials. All-address
SAT equivalence, top-level lint and the memory/peripheral harness pass. Parent
and candidate transaction/cycle records match exactly, including concurrent
DMA. No pipeline or bus cycle is added. A second pair uses one-hot targets;
its equivalence proof includes the binary-to-one-hot encoding relationship.

| Trial | Worst setup ns | Min hold ns | ALMs | Registers | M10K | DSP |
|---|---:|---:|---:|---:|---:|---:|
| Original parent, encoded predecode | -2.080 | +0.078 | 32,934 | 37,711 | 483 | 42 |
| Posted-modes parent, encoded predecode | -1.699 | +0.109 | 33,242 | 38,656 | 483 | 42 |
| Original parent, one-hot predecode | -2.008 | +0.090 | 33,364 | 38,345 | 483 | 42 |
| Posted-modes parent, one-hot predecode | -1.613 | +0.107 | 34,401 | 39,007 | 483 | 42 |

All four fail setup. The posted variants improve their -2.084 ns parent,
but none beats the original stripped -1.301 ns result. CPU/cache paths become
the leading failures. These builds are not hardware-tested or promoted.
Reports and hashes are retained in `active-experiments-address-predecode.json`
and each trial's `build/` directory.

The next pair combines previously tested posted writes, 32 KiB I/D caches,
S_AGU=0 and 4 KiB SDRAM bank interleaving. It includes the encoded predecode
for its lower area than the one-hot variant. The individual FPS deltas must
not be added as a prediction; combined throughput is unmeasured. Both generated
CPUs are current and top-level lint passes; source regression and two Ubuntu
fits are running. The testbench explicitly selects the same 32 KiB I-cache
as the board macro. No framework, firmware, clock or timing-constraint changes
are included. The original board build/settings remain restored. Evidence:
`research/combined/`, `active-experiments-combined.json`, and the
`tlb-fix-rfcombined{,frame}104-s13` trials under `build/timing-closure/`.

Combined source CPU validation completes at 333/348 passes, with only the same
15 original allocation-policy assertions failing. All 30 focused source checks
pass, including the exact cycle model with only `ldr_base` changed from five
to four clocks. Two changed passing signatures contain only reviewed timer or
interrupt-landing fields; failure fields remain zero. Generated regression and
two fits remain active. The Ubuntu memory/peripheral tests pass after fixing
the harness's missing `ld_rd=0` initialization and reusing the existing bank4k
physical-memory fixture helper. Optional firmware-log replays and the Sonic
card fixture are absent/skipped, so no real-game coverage is claimed from them.
No combined candidate has been deployed or promoted.


The combined generated CPU regression is now complete and all 348 complete
records match source exactly, including counts, signatures and trace hashes.
All 30 focused generated checks also pass and match source. The stripped fit
uses 33,947 ALMs, 39,316 registers, 519 M10Ks and 42 DSPs, with -1.735 ns setup
and +0.080 ns hold. The profiling fit uses 35,906 ALMs and 43,090 registers,
with the same RAM/DSP count and -2.082/+0.100 ns slack. Neither closes timing.
Fresh controls measure 18.041667 complete/changing uploads/s for THPS and
6.433333 for CoD, using 24/30 paired samples. Both reach idle by 50 seconds and
have no sampled faults or malformed uploads. A first CoD capture is excluded
because of a truncated PNG; the screenshot helper now waits for the PNG IEND
trailer instead of a short fixed delay. Combined hardware testing is underway.


Combined hardware testing is complete. THPS improves from 18.041667 to
21.541667 complete/changing uploads/s, +3.500000 (19.4%), in the braked
Warehouse scene. Instruction throughput rises from 45.350674 to 53.191194 M/s.
All 24 selected pairs have complete frames and no recorded CPU fault or
loader error. The stopped scene and 50-second phone-idle boot are inspected.

CoD's first comparison is limited by different animation state: the candidate
is already static at 170 seconds while the initial control still changes.
A fresh control allowed to settle until 260 seconds gives 6.933333 complete
uploads/s, versus 7.566667 for the candidate (+9.1%). Both windows have zero
changing images and 30 valid pairs. Instructions/s are 54.570597 M versus
61.288889 M. The camera/start location matches visually, but this remains
separate boots and unequal elapsed settling windows, not deterministic replay.
A follow-up resume/turn test verifies the candidate responds to input and
renders changing images; it is not frozen. No selected sample has a malformed
upload, sampled CPU fault or FPGA loader error. CoD phone idle is visible by
50 seconds. Evidence is under hardware/combined104-{thps,cod},
hardware/combined104-control-cod-settled and research/combined/*comparison.json.

The five-FPS THPS goal and timing closure remain unmet. The larger gain is
from core CPU/cache/memory changes, with no FixQD or other new firmware patch.
No functional RTL has been promoted. Original INI/CFG/RBF hashes are restored and verified. The stripped build is
visibly at phone idle by 50 seconds and the temporary input server has exited.
Restoration evidence: hardware/combined104-restored-stripped104.

Separately, two isolated timing trials factor the cache-lock summary across
its clear/install operations without adding cycles. Both pass the existing
source-extracted temporal induction proof; regenerated Verilog differs from
each parent in exactly the intended expression. Source elaboration passes
with the parent's existing unused full_product[65:64] warning. Ubuntu fits
are running for the original best seed-13 and the combined stripped parents;
results are in active-experiments-lock-any.json when complete.

The combined-parent lock-summary fit finishes at -2.408 ns setup / +0.115 ns
minimum hold across corners, 34,589 ALMs, 39,409 registers, 519 M10Ks and 42 DSPs. It is worse than
its parent and is not promoted. The original-parent fit also fails at -1.526 ns setup / +0.087 ns minimum
hold, 33,695 ALMs, 38,529 registers, 483 M10Ks and 42 DSPs. Both are worse
than their parents; neither is promoted. All Quartus processes/containers
have completed and auto-removed.

## Eight-entry posted queue and four-word SDRAM bursts

Four isolated combined-parent trials compare an eight-entry classic queue
against an eight-entry queue that can issue complete, aligned four-word SDRAM
bursts, each with stripped and FrameV2 builds. Groups must already be buffered
when launched. Later arrivals cannot upgrade an outstanding classic transfer;
device writes remain classic and incomplete groups drain immediately. Byte
masks and write order are retained. Framework, top-level settings, clock,
constraints and memory geometry match the parents. Root functional RTL is
unchanged and no candidate is promoted.

Both queue configurations pass 800,203 standalone stress clocks; the burst
case exercises 9,450 groups. Each source CPU model passes 30 existing focused
cases and eight new physical-SDRAM cases. The dense fixture uses distinct STM
data and mixed byte masks across WT, NCB and WB-miss mappings; at 20:20 latency
it exercises 93 groups. Source/generated burst-model records match exactly
on all 38 focused cases. An initial physical-window fixture overlapped the
bench stack; its results are superseded by mappings outside low RAM. Full
354-case regressions and four Ubuntu fits remain in progress.

The captured classic/burst traffic also passes replay against the unchanged
memory RTL and independent SDRAM chip/reference model at seeds 1, 17 and 71,
including final readback of every written word. Removing idle gaps, the mixed
trace takes 9,386 classic versus 9,312 burst clocks, a 0.79% saving. This is
controller-only replay, not a coupled CPU simulation or measured game gain.
The earlier dense streaming benchmark's 24.7% saving cannot be used to predict
this experiment's FPS. Hardware remains restored to the original stripped
build/settings, with hashes rechecked. Evidence and live job handles are in
`build/timing-closure/research/posted-burst/` and
`build/timing-closure/active-experiments-posted-burst.json`.

The full source regression subsequently completes: 339/354 pass, with
396,898,200 passed clocks and exactly the parent's 15 policy-expectation
failures. The four changed passing signatures contain only reviewed IRQ
landing/sweep statistics and prefetch timing registers; failure fields are
zero. The generated full regression and all four fits remain active. The
temporary controller-replay model has been cleaned after retaining its logs.

The generated full regression completes with all 354 records exactly matching
source, including the 339 passes and the same 15 known failures. All four fits
finish with these minimum setup/hold values across corners:

| Eight-entry queue | Setup ns | Hold ns | ALMs | Registers | M10K | DSP |
|---|---:|---:|---:|---:|---:|---:|
| Classic stripped | -2.394 | +0.102 | 34,084 | 39,523 | 519 | 42 |
| Burst stripped | -1.978 | +0.081 | 34,620 | 39,887 | 519 | 42 |
| Classic FrameV2 | -1.976 | +0.084 | 36,279 | 43,502 | 519 | 42 |
| Burst FrameV2 | -2.902 | +0.080 | 36,327 | 43,036 | 519 | 42 |

The captured THPS two-store loop also passes on both configurations at four
bus latencies. The candidate groups writes at nonzero latency, confirming
activation for that real instruction pattern. Fixed per-beat latency mostly
masks the bandwidth benefit and is not a game-FPS predictor.

Both FrameV2 builds reach phone idle by 50 seconds with the original game
cards/save, and both run the expected THPS Warehouse and CoD forest scenes.
THPS averages exactly 21.208333 complete/changing uploads/s for both queues
(24 verified pairs each), versus the previous combined four-entry result of
21.541667. The latter is an earlier separate boot, not a fresh control for
declaring a regression. Instructions/s are 52.551161 M classic and 52.632386 M
burst. No improvement toward the five-FPS target is demonstrated.

CoD starts its measurement at elapsed 260 seconds in both variants. It gives
7.533333 classic versus 7.866667 burst complete uploads/s (30 pairs each,
zero changing pictures in both settled views), a 4.4% single-window difference.
Instructions/s are 61.281761 M versus 61.695551 M. The starting position and
camera match visually; this is neither deterministic replay nor a repeated
comparison. All four windows have zero incomplete/untracked uploads and no
sampled CPU faults or FPGA loader errors. These variants have not been tested
in Sonic N or Asphalt, and are not promoted. Evidence is in
`research/posted-burst/hardware-comparison.json` and the four
`hardware/postedburst104-{control,candidate}-{thps,cod}` directories.

Original INI/CFG/RBF hashes are restored and reverified, with phone idle visible
at 50 seconds and no temporary input server, simulation or Quartus container
remaining. Restoration evidence: `hardware/postedburst104-restored-stripped104`.
The original build still has its known -1.301 ns setup violation.

A separate timing lead concerns instruction-bus write data. Its first generic
cache proof fails because unconstrained holds can consume uninitialized
response metadata immediately after reset. The actual fetch/CP15 reset
contracts have not yet been included/proved in that harness. This is not a
reproduced game fault and does not justify a bus-data tie-off. No RTL change
or fit was made for that lead; the failed proof and next required checks are
retained in `research/icache-readbus/checkpoint.md`.

## Late constant LSL forwarding: prototype under validation

The isolated `tlb-fix-rflateshift104-s13` candidate keeps unconditional ARM
non-flag-setting LSL-by-1 and LSL-by-8 operands raw through S and selects them
through the existing permission-qualified late A forwarding. The constant
shift is applied once at the ALU input; held A records retain the raw word.
PC operands/destinations, other shifts, Thumb, conditional and flag-setting
operations retain the parent schedule. Decode/execute eligibility and existing
forwarding references are asserted. No framework or root functional changes.

The checked palette loop falls from 5,906 to 5,138 clocks (13.0% fewer);
texture falls from 9,773 to 8,749 at zero bus latency (10.5% fewer). At the
other two latency settings the same savings persist. All instruction counts,
architectural trace hashes and signatures match the parent; source and
generated CPU results match exactly. These are kernel timings, not game FPS.

A new directed test checks 1,152 combinations of twelve ALU operations, both
shifts, both carry states, four values, producer spacing, and cached/uncached
load dependencies. Eight RTL runs (source/generated, four bus latencies up to
2:40) pass and match QEMU's signature. The source coverage probe observes
50,087 held/waiting A clocks at 2:40, with all 1,152 eligible operations
finishing. Full source regression runs on the Mac and generated regression
on Ubuntu. Stripped and existing-frame-counter fits run on Ubuntu. Top-level
lint and generated freshness pass for both; only the frame parent's ten
unused observation signals receive exact-name lint waivers. Neither candidate
is deployed or promoted. Original hardware settings/build remain restored.
Evidence: `build/timing-closure/research/late-shift/`, the trial validation
folders and `active-experiments-late-shift.json`.

The full source CPU regression completes: 336/351 pass, with exactly the same
15 allocation-policy expectations failing as the parent. All 348 parent
signatures are unchanged; 399,070,475 passing clocks are checked. The three
trust-sweep trace hashes differ. A full 0:3 comparison audits all 616,351
records: 27 fields change their pending-register mask; every mutually
available register, event, PC and CPSR matches. No other trace differences
are observed in that audited latency. The final signatures match at all
three latencies. An additional 1,152-case read/modify/write alias test (Rd=Rm
or Rd=Rn) passes source and generated models at 0:0 and 2:40 and matches QEMU;
45,310 held/waiting clocks are observed in its longer-latency source run.

Fresh combined-frame controls reach idle by 50 seconds. THPS measures
21.541667 changing complete uploads/s (24 pairs, 53.253484 M instructions/s).
CoD, measured after the matched 260-second settling point, gives 7.566667
complete uploads/s (30 pairs, 61.307488 M instructions/s); its stationary
view repeats the same image. Both have zero incomplete/untracked uploads
and no sampled CPU/loader errors. Evidence: `hardware/late-shift-control104-*`.
Direct Video remains temporarily off for candidate tests; original settings
are backed up in `hardware/late-shift-control104-staging`. Candidate fits and
the generated regression remain in progress; no hardware gain is claimed.

The generated regression finishes and exactly matches all 351 source records,
including counts, trace/signature hashes, 336 passes and the same 15 known
allocation-policy failures. Both fits finish with timing failures:

| Late-shift variant | ALMs | Registers | M10Ks | DSPs | Setup min | Hold min |
|---|---:|---:|---:|---:|---:|---:|
| Stripped | 33,812 | 39,230 | 519 | 42 | -2.125 ns | +0.058 ns |
| Frame counters | 36,101 | 42,660 | 519 | 42 | -2.514 ns | +0.044 ns |

The stripped worst path goes through late operand selection, the new shift
selector and the ALU into `check_ff`; data delay is 10.937 ns across seven
logic levels, with 67% routing delay. The stripped parent's -1.735 ns and
frame parent's -2.082 ns are both better. No constraint/framework changes.

Hardware boots idle by 50 seconds in both games. Fresh matched stopped THPS
windows give 21.541667 → 21.750000 complete/changing uploads/s (24 pairs),
53.253484 → 53.807554 M instructions/s. Settled CoD gives 7.566667 → 7.700000
complete uploads/s (30 pairs), 61.307488 → 62.513849 M instructions/s; both
stationary views repeat unchanged images. A supplemental held-right turning
window gives 10.250000 → 10.333333 complete/changing uploads/s (24 pairs),
60.315845 → 61.796110 M instructions/s. Screenshots confirm actual movement.
These are single windows; the turning trajectories and absolute boot times
are not identical. The initial control turning attempt failed to resume
from the pause menu and is explicitly rejected, never counted as gameplay.
All valid samples have no CPU/loader error, incomplete or untracked upload.

The late-shift trial is set aside: the small measured game changes do not
justify its worse timing. No root functional change is promoted and this
is not the requested five-FPS gain. Detailed artifacts and comparison:
`research/late-shift/hardware-comparison.json`, `active-experiments-late-shift.json`.
Original stripped build and display settings are now being restored.

Restoration is complete: original RBF, INI and CFG hashes match; the phone
is visibly idle at the 50-second check. Temporary input/capture helpers,
CPU simulations and Quartus containers are stopped. Evidence:
`hardware/late-shift-restored-stripped104/manifest.json` and `boot50.png`.
The original build still has its known -1.301 ns setup failure. Neither the
five-FPS improvement nor 104 MHz timing closure has been achieved.
