# My own plan for the phone's speed, written before the consults (2026-10-24)

Written before reading the Codex and Antigravity answers to the same
brief (scratch consult-speed-brief.md), per the independence rule.

Where we are: 31 M instructions/s in play at CPI 3.3; the goal 47.
ZAP's ceiling with every memory-side lever is about 36-38. V2 passes
the suite but is level with ZAP on the random tests because the
load-use schedule costs five extra clocks, and sits at -2.1 ns.

1. V2 stays the path, but its cycle model has to show on the random
   tests before more timing work: the three-clock load pickup (true
   destination masks, W's load as a ready source) and the predictor's
   lost slot are the two items that separate it from the Pocket's
   CPI 1.7-1.9. If after session 6 crand/ctrand at 0:3 and 2:9 are
   not at least 20 % under ZAP, the design is wrong somewhere
   structural (the shared short-port cache contract, the forwarding
   network with three producers plus port C), and the Pocket's
   simpler organisation (5,000 ALMs) is the reference to compare
   stage by stage.
2. The clock: the Pocket runs 80 MHz on its own PLL. V2 at the
   frequency it closes at with CPI 1.9 (about 83 MHz, 44 M/s) beats
   104 MHz at -2 ns, which does not run reliably. A CPU clock domain
   with a crossing at the merger is a known MiSTer pattern; the
   cost is fill latency (a few clocks) and the firmware's timers
   staying on the 104 MHz side. Worth a design note now, not a build.
3. The memory side (the ZAP thread's scope): instrument the I-cache
   (misses, fills, fetch-FIFO empty with the cache ready) before
   buying a bigger I-cache again; the 48 % code-stall share is the
   number to explain. Then the write buffer in the merger (5-8 %
   estimate, parked), which helps both cores.
4. Not the Pocket's core itself: it has no CP15/MMU/abort model for
   the real kernel; porting it would be V2 again with less of what we
   need.
