# DMA count contract regression

From the repository root:

```sh
make -C sim dma-count
```

Requirements: Python 3, a C11 compiler, and Icarus Verilog. The imported DMA
and RAM are compiled in SystemVerilog mode; `tb.v` uses Verilog-2001 syntax.
Output is under `sim/build/dma-count/`. `DMA_COUNT_OUT` selects another output
directory, relative to the repository root. `DMA_COUNT_CASE=1`, `2`, `3` or
`4` selects one directed case instead of the complete matrix.

The count register has two contracts, independent of memory access width:

| Control | Total bytes |
| --- | --- |
| 1, memory-to-memory | `(raw_count + 1) * 2` |
| 2, paced TX to a fixed destination | `(raw_count + 1) * destination_width_bytes` |
| 2, paced RX from a fixed source | `(raw_count + 1) * source_width_bytes` |

The directed cases are a 10-byte 32-to-32 M2M copy (raw count 4), 512-byte
32-to-8 MMC TX (raw count 511), 10-byte 8-to-32 MMC RX (raw count 9), and
seven 32-bit LCD FIFO words (raw count 6). The original source-unit-count
implementation fails the first two by reading beyond the requested budget;
the RX and LCD cases retain their original byte counts.

The full 2,650-case matrix includes all nine native width combinations,
every naturally aligned lane, fixed/incrementing M2M modes and both paced
directions, with 1 through 9 count units. A byte oracle independently derives
all source bytes, source/destination address sequences, exact access sizes or
lane masks, FIFO output and complete destination memory plus untouched guards.
This catches undercopy, overcopy, source overread and final partial units.
The RTL bench also stalls responses and paced endpoints, checks immutable
held bus packets and observes completion/acknowledgment.

`model_test.c` executes the actual `dma_phys()`, `width_bytes()` and `dma_run()`
functions extracted verbatim from `model/hw/ngage_dma.c` at test time. It
stubs QEMU allocation, memory and IRQ dependencies. It does not rebuild or
boot QEMU. The full peripheral regression remains `make -C sim periph`,
including real SDRAM/card models, simultaneous channels, CPU traffic, stop,
LCD and MMC paths. Its M2M setup counts halfwords and MMC phases count fixed
FIFO bytes regardless of SDRAM width.

Evidence: original NEM-4 DMA code shifts the byte argument right by one at
`0x50321424` for M2M, and by the peripheral table shift at `0x503215C4` for
paced transfers. These are software contract observations; exact physical
UPP timing and error status remain unverified. This change does not alter
the donor's existing bus-error handling, address aliases or IRQ map.
