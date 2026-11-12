# Native LCD DMA, experimental implementation (2026-11-12)

Production now has two general DMA workers and one specialized LCD reader.
There is no old/new switch. Use a separate master build for comparison.
No CPU, generated CPU, SDRAM-controller, physical panel timing or clock changes.

The reader shares the existing registered DMA memory master with the general
workers. It only reads memory; the destination write is a valid/ready enqueue
into the existing LCD command/data FIFO, bypassing the audio/CPU Wishbone and
peripheral-register path. Panel packing, phase limits, reads and byte timing
remain in upp_lcdif. Completion means the final FIFO word has been accepted,
matching the generic destination-write boundary, not physical panel drain.

Eligibility: peripheral-paced transfer; incrementing aligned source wholly in
0x0a000000..0x0affffff; fixed LCD FIFO destination (0x10121208 or0x0c121208);
32-bit source/destination widths. The normal byte budget/count-minus-one rules
remain. Other descriptors still use generic width conversion, not invented
native semantics. Requests on all eight channels are supported. Starts queue
when their worker class is full; only two generic transfers run concurrently.

A selected CPU LCD access reserves FIFO admission before its sampled ready
state, including reads and control writes. The native word waits under that
reservation or a full FIFO. There is one ordered FIFO, no new payload RAM.
A32-bit last-word shadow preserves ordinary FIFO-register readback after native
writes. Read-phase data still comes from the panel's read sequence.

Stop/restart suppresses unaccepted native data; a launched memory read keeps
its registered request until ACK/ERR, then cancellation drops its old result.
Read errors retain the generic zero-data behavior. Same-channel restart waits
for its old owner to leave. The shared loader rotates through queued channels,
retrying when the required worker class is full so blocked generic work cannot
prevent LCD dispatch. Reset clears reader/loader/queue ownership as before.

This first version uses scalar memory reads, with one held word. Burst prefetch
is deferred, and the existing SDRAM controller already supports it. This
isolates the native destination path and worker specialization for your manual
experiment. Do not infer FPS, setup slack or ALM savings from this source.

## Checks and manual experiment

Local Icarus **elaboration only** passes for DMA, LCD interface, their focused
bench and the integrated peripheral hierarchy. The hierarchy has existing
Icarus constant-select notices and an existing audio assertion warning.
Docker cannot be reached by this agent session (Unix socket operation not
permitted), so no runtime test, Verilator top regression or Quartus fit has
been executed. Treat this as an unqualified experimental candidate.

Run inside the already installed image, from this checkout:

```sh
docker run --rm --pull=never --network none --platform linux/arm64 \
  -v "$PWD:/work" -w /work --entrypoint sh jotego/simulator:arm64 \
  -c 'make -C sim lcd-fast dma-count periph top'
```

`lcd-fast` exercises exact serialized bytes with a small FIFO, all-channel
routing, unsupported-source fallback, last-word readback, CPU priority,
held-word stop, outstanding-read restart, two blocked MMC workers plus a queued
generic request, and reset. It is provided but has not been executed here.
Run the complete normal suite before promoting this experiment.

Build the core normally (`quartus_sh --flow compile NGage`) and compare against
a separate master build with matching clock, firmware/save/card and scene.
The 1,000-path reporting changes are a separate patch, not required for this
LCD implementation. No core was built or deployed by this work.

For gameplay measure completed uploads and frame intervals alongside CPU
progress/stalls; a shorter transfer alone does not establish a higher game FPS.
A36608-pixel RGB444 frame removes18304 shared-bus destination writes, retaining
18304 scalar source reads. FIFO backpressure and CPU arbitration remain real.
