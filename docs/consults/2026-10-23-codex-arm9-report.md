# ARM9 replacement: session 2 continuation report

## First integration checkpoint

The selectable ARM9 controller now runs actual instructions through the retained
cache/MMU/CP15 system and the session-1 execute datapath. `CORE="ZAP"` remains the
default. This is a **non-overlapped bring-up skeleton**, not a claim of an ARM9
performance implementation. Milestone 3's basic functional coverage is present;
its intended overlapping pipeline and cycle counts remain open.

Implemented: ARM data processing and shifts, conditions, B/BL/BX and PC writes,
MRS/MSR with banked SPSRs, byte/halfword/word transfers, basic LDM/STM, SWP/SWPB,
Thumb translation and separate BL halves, synchronous exceptions and initial
IRQ/FIQ sampling, and the retained CP15 block. Register file and exception-entry
logic are reused from `zap_writeback`; its predictor and fetch-PC outputs are
disconnected. The new fetch controller owns the PC. Stores cannot pass older
faults because only one instruction is in flight.

The cache contract preserves three RAM edges. A data request drives the lookup
address in M1, M2 and M3, with the TLB check in M3, then asserts the request in M.
Fetch similarly waits F1/F2/F3 before asserting its request. Addresses presented
to the cache are word aligned; the original VA and format retain the low bits.
`err2` repeats the lookup without retirement. A data acknowledgement is classified
on the following edge because the miss lock becomes visible only after the ack
edge. A locked load waits for its one-hot completion and captures that data before
W. Background completion never writes the architectural register file directly.
An early I-cache word waits for the fill's completion/fault before decode.

Verification at this checkpoint: ARM9 `alu align modes exc`, all three latencies,
12/12 pass, all four QEMU signatures and instruction traces agree. `shift cp15
fiq_movs fiq_perm` also pass at all three latencies. Full instruction-set coverage
is not claimed: multiply is still undefined, `thumb` consequently fails, and
`ldm` exposes the not-yet-implemented restoration of a base loaded before an abort.
Further results are added below as session 2 continues.

Measured cycles and instruction counts are retained in
`arm9/session2-step1-arm9.json`. The nine-test ZAP baseline is
`arm9/session2-baseline.json`; after-integration counts are
`arm9/session2-step1-zap.json`. All 27 ZAP cycle and instruction counts are
identical, including cache 760787/888787/1222550, ctrand1
72594/102419/179154 and crand1 73608/105167/187620 (0:0, 0:3, 2:9).

The session-1 design, 18 ps execute timing margin, fit artifacts and original
stopping point are preserved in [session1-report.md](arm9/session1-report.md).
The execute leaves have not changed. No integrated timing closure is claimed;
new D control and M enables can change placement and timing. The explicit M
phase registers preserve the RAM contract, but do not meet the TRM+1 goal.
No firmware boot or hardware game measurement is run here.

Checkpoint validation: ZAP focused 27/27, full 198/198, QEMU 52/0; all focused
counts unchanged. Top-level `make lint` and `make cpu-gen-check` pass. The source
ARM9 core also passes `-Wall` with the existing ZAP implementation excluded from
that additional lint run. All 582,272 execute-leaf reference checks pass.
The legacy bench assumes a cache completion writes the register file on the
same edge; ARM9's blocking-load capture needs a separate assertion and retirement
check. Its current cache runs therefore report that expected monitor mismatch,
not successful cache validation. This is addressed next, without weakening the
cache's existing critical-word/lock checks.
