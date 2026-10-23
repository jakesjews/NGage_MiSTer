# ARM9 session 6 timing continuation

Continued from `d9c773d` on `codex/arm9`. ZAP remains the default. The earlier
cycle-gate implementation and fit are preserved in [session 6b](arm9/session6b-report.md).

## Milestone (a): registered late-event clear

Implemented separate `clear_e_late` and `clear_pipe_late` registers. E's branch
correction preserves the branch and older memory/writeback records. A retiring
fault, loaded PC or serialized redirect also invalidates the younger backend
on the following edge. Only record validity is cleared; invalid payload bits
need no clear mux. The decision edge still suppresses younger data requests on
an older W fault or PC write, and the registered clear suppresses retirement,
execution and data requests until those records are invalidated.

Block base restoration remains ordered before exception entry. A stale BTB
prediction on a block start discards younger E work but preserves the active
block sequencer. Older faults still cancel younger multiplies and stores.
Fetch redirects immediately; its refill interval absorbs the late clear, so
no cycle-window or whole-test count changes in this milestone.

Verification: each of ARM9 predictor-on, ARM9 predictor-off and ZAP passes
234 runs, 63 QEMU comparisons and all 85 windows. Windows check exact hot
0:0 ARM9 counts and coverage at all latencies/configurations. All 702 cycle and
instruction counts match the baseline. Top-level lint, both explicit ARM9
lints and `make cpu-gen-check` pass. No binaries/QEMU references were rebuilt.
[Verification](arm9/session6c-a-verification.txt), [all counts](arm9/session6c-a-cycles.json).

## Integrated trial and remaining path

Seed 2, 104 MHz, CPU-only trial on Ubuntu through `sim/cpu/quartus/run.sh`.
Both compile and TimeQuest completed successfully. No Quartus ran on the Mac.

| Fit | Slow 100C | Slow -40C | Fast 100C | Fast -40C | ALMs | Registers |
|---|---:|---:|---:|---:|---:|---:|
| Baseline ARM9 | -8.332 | -8.246 | -0.008 | +1.485 | 16,755 | 15,236 |
| Registered clear | -7.532 | -7.236 | +0.282 | +1.671 | 17,078 | 16,632 |
| ZAP reference | -2.647 | -2.696 | +2.885 | +4.005 | 15,917 | 17,360 |

All hold corners are positive (+0.325/+0.271/+0.172/+0.117 ns). RAM remains
72 blocks / 334,240 bits and DSP use remains 3. [Fit artifacts](arm9/session6c-a-fit-seed2/manifest.json).

The previous 807-fanout backend clear no longer heads the worst path. The
remaining slow-100C path is held forwarding -> E branch adder -> target equality
-> early_redirect -> fetch o_valid -> tag_e capture -> operand forwarding:
14 logic levels, 16.481 ns data delay, -7.532 ns slack. The execute module is
unchanged; the next boundary to remove is the combinational fetch-to-D validity
and instruction selection, including E redirect qualification.

The fit is not within the requested -0.5 ns limit. Area is also over the 5%
limit: 17,078 is 1,161 (7.29%) above ZAP, 366 above the largest integer count
within that limit (16,712).

## Area attribution

The baseline's approximately 840 extra ALMs are 838 after rounding. Fitter
hierarchy estimates attribute +935.5 to the pipeline, -156.3 to the I-cache,
-15.8 to the D-cache, and +74.2 to remaining/wrapper logic. Within the pipeline,
the retained register-file instance is +681.8 ALMs (1,774.8 versus 1,093.0);
the rest accounts for +253.7. This is fitted attribution, not a claim that
identical register-file RTL intrinsically costs that much more: surrounding
logic, retiming, replication and packing affect the result.

After the clear change, pipeline/I-cache/D-cache estimates are
8,754.8/3,547.9/4,579.6 ALMs. The baseline ARM9 values were
8,498.5/3,517.6/4,548.4. The register-file instance falls to 1,740.0, while
physical synthesis adds registers elsewhere. The RTL adds two control bits;
the net +1,396 fitted registers are optimization/retiming effects, not a new
architectural pipeline stage. [Baseline ARM9](arm9/session6c-baseline-arm9-area.csv),
[ZAP](arm9/session6c-baseline-zap-area.csv), [after clear](arm9/session6c-a-fit-seed2/area.csv).

## Cycle comparison

All values are unchanged by (a). Positive saving means ARM9 is faster.

| Test | Latency | ARM9 before/after | ZAP | Saving |
|---|---|---:|---:|---:|
| cache | 0:0 | 639,745 | 760,787 | 121,042 |
| cache | 0:3 | 764,132 | 888,787 | 124,655 |
| cache | 2:9 | 1,097,644 | 1,222,550 | 124,906 |
| dcache_rtl | 0:0 | 56,947 | 58,301 | 1,354 |
| dcache_rtl | 0:3 | 82,975 | 85,328 | 2,353 |
| dcache_rtl | 2:9 | 152,747 | 154,143 | 1,396 |
| ctrand1 | 0:0 | 69,278 | 72,594 | 3,316 |
| ctrand1 | 0:3 | 99,236 | 102,419 | 3,183 |
| ctrand1 | 2:9 | 179,061 | 179,154 | 93 |
| crand1 | 0:0 | 70,348 | 73,608 | 3,260 |
| crand1 | 0:3 | 101,657 | 105,167 | 3,510 |
| crand1 | 2:9 | 186,313 | 187,620 | 1,307 |
| gba_arm | 0:0 | 5,973 | 8,291 | 2,318 |
| gba_arm | 0:3 | 8,074 | 10,887 | 2,813 |
| gba_arm | 2:9 | 13,794 | 17,749 | 3,955 |
| gba_thumb | 0:0 | 4,014 | 4,913 | 899 |
| gba_thumb | 0:3 | 5,418 | 6,523 | 1,105 |
| gba_thumb | 2:9 | 9,371 | 10,877 | 1,506 |
| mmu_page | 0:0 | 74,763 | 77,102 | 2,339 |
| mmu_page | 0:3 | 109,212 | 112,796 | 3,584 |
| mmu_page | 2:9 | 200,922 | 203,209 | 2,287 |

## Milestone (b): registered fetch boundary, retained for the control pass

The completed interrupted trial is -6.513 ns at Slow 100C, -6.382 at Slow
-40C, +0.853/+2.149 at the fast corners. Hold slack remains positive
(+0.262/+0.248/+0.138/+0.119). Area is 17,248 ALMs and 16,769 registers;
RAM/DSP are unchanged. That is 1,331 ALMs (8.36%) above ZAP, still outside
5%. [Fit and worst 30 paths](arm9/session6c-b-fit-seed2/manifest.json).

The fetch queue now supplies registered instruction, decoded word, fault,
prediction metadata and validity to D. No cache-hit or permission-qualified
bypass remains. D may capture a younger word on a redirect edge; the registered
late kill prevents execution. The predictor lookup/decision position is
unchanged. This is retained despite the measured cycle cost because it cuts
a real cross-boundary control/data chain and timing is the project priority.

All three configurations pass 234 runs, 63 QEMU comparisons and 85 windows;
lint and generation checks pass. Predicted B/BL remains two clocks, immediate
load-use remains two, and the one-edge RAM is unchanged. Unpredicted B/BL is
now five clocks. Ordered PC-write windows gain one; MRC and exception/vector
windows gain two. The external expectation files and ARM9.md are updated.
[Verification](arm9/session6c-b-verification.txt), [windows](arm9/session6c-b-windows.csv).
Non-timer instruction counts are identical. The four cycle-timer IRQ/FIQ tests
change spin-loop counts with interrupt arrival, while passing their checks.

| Test | Latency | After (a) | After (b) | ZAP | Saving after (b) |
|---|---|---:|---:|---:|---:|
| cache | 0:0 | 639,745 | 644,977 | 760,787 | +115,810 |
| cache | 0:3 | 764,132 | 766,283 | 888,787 | +122,504 |
| cache | 2:9 | 1,097,644 | 1,098,750 | 1,222,550 | +123,800 |
| dcache_rtl | 0:0 | 56,947 | 61,209 | 58,301 | -2,908 |
| dcache_rtl | 0:3 | 82,975 | 84,193 | 85,328 | +1,135 |
| dcache_rtl | 2:9 | 152,747 | 153,136 | 154,143 | +1,007 |
| ctrand1 | 0:0 | 69,278 | 73,537 | 72,594 | -943 |
| ctrand1 | 0:3 | 99,236 | 100,374 | 102,419 | +2,045 |
| ctrand1 | 2:9 | 179,061 | 179,218 | 179,154 | -64 |
| crand1 | 0:0 | 70,348 | 74,652 | 73,608 | -1,044 |
| crand1 | 0:3 | 101,657 | 102,973 | 105,167 | +2,194 |
| crand1 | 2:9 | 186,313 | 186,669 | 187,620 | +951 |
| gba_arm | 0:0 | 5,973 | 6,494 | 8,291 | +1,797 |
| gba_arm | 0:3 | 8,074 | 8,803 | 10,887 | +2,084 |
| gba_arm | 2:9 | 13,794 | 15,170 | 17,749 | +2,579 |
| gba_thumb | 0:0 | 4,014 | 4,039 | 4,913 | +874 |
| gba_thumb | 0:3 | 5,418 | 5,444 | 6,523 | +1,079 |
| gba_thumb | 2:9 | 9,371 | 9,416 | 10,877 | +1,461 |
| mmu_page | 0:0 | 74,763 | 80,454 | 77,102 | -3,352 |
| mmu_page | 0:3 | 109,212 | 110,892 | 112,796 | +1,904 |
| mmu_page | 2:9 | 200,922 | 201,250 | 203,209 | +1,959 |

Five rows lose to ZAP: dcache_rtl 0:0 by 2,908, ctrand1 0:0 by 943 and
2:9 by 64, crand1 0:0 by 1,044, and mmu_page 0:0 by 3,352 clocks. The
removed empty-queue bypass adds response-to-D/refill latency. Predicted hot
branch spacing and load interlock counts did not regress; the table measures
whole programs including setup and uncached traffic. There is no claim that
this suite proxy measures game CPI or hardware frame rate.

All 30 worst Slow-100C paths share decode admission: queue word -> kind/read
register tags -> decode-forward readiness -> issue/pop (28 paths) or block_issue
(2 paths) -> retimed E/M control -> E forwarding. They are 13–14 logic levels,
15.337–15.441 ns data delay, -6.399..-6.513 ns slack. Clear, fetch-valid,
cache-hit and redirect are not independent families in these worst 30; their
absence here does not prove those domains close. [Grouping](arm9/session6c-b-fit-seed2/path-groups.txt).

## Exact milestone stopping point

(a) is committed as 3aadad1. (b) is retained, verified and fitted; this commit
preserves it with its measured cost. The next action follows the lead's revised
instruction: one structural control-boundary pass, one integrated seed-2 trial,
then all verification and updated cycle rows. If that pass is still below
-2 ns, stop and hand off the remaining chains with lengths. ZAP remains default;
no firmware boot, push, local Quartus or sys/ changes.
