# ARM9 execute milestone

`./sim/cpu/arm9/run.sh` builds and runs the independent C++ reference against
`arm9_execute`, both SystemVerilog and sv2v output, with `PRE_SHIFTED=0` and `1`.
Every build uses Verilator `-Wall` with warnings fatal. Only the generated file's
filename/module mismatch is disabled. Builds live in `sim/cpu/build/arm9-execute`.
This does not assemble any ARM test or invoke QEMU.

Coverage includes all 256 register shift amounts (and all 32 immediate shift
encodings), both carry inputs, signed/unsigned boundaries, all sixteen ALU
operations and conditions, all NZCV combinations, every physical tag 0..39,
producer readiness and alias priority, invalid and condition-failed instructions,
and 100,000 deterministic mixed vectors per configuration. The shift reference
moves one bit at a time; arithmetic overflow uses signed 64-bit arithmetic.
These are datapath tests, not proof of CPU sequencing or ARM9 cycle counts.

`TRIAL=arm9_execute ./sim/cpu/quartus/run.sh` fits a register-file/D/E/M/W feedback
harness at 104 MHz using the existing CPU trial device and settings. The harness
is not a CPU: a serial stimulus register supplies arbitrary control and the
result remains observable. It includes all four existing RF read ports, all
three write ports, late result forwarding, flag feedback, stage enables and
branch-target generation. Registered D operands are intentional: RF read and
E arithmetic are distinct paths. Default output is
`sim/cpu/build/quartus-arm9-execute`; use an isolated `BUILD_DIR` when sharing the
server. It does not start a whole-core build or firmware boot bench.

The complete integration design and outstanding latency gates are in
`docs/ARM9.md`; continuation status is in the dated arm9 report.
