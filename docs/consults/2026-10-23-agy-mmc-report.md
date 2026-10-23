<!-- Antigravity (gemini-4-argon-high), 2026-10-23, implementation report for branch agy/mmc. -->

# Implementation Report: MMC Card Counters, 26 MHz Wire Clock & 4 KB Chunk Fetch (`agy/mmc`)

## 1. Overview of Changes

This change implements the three-part MMC game-load optimization plan from [`docs/consults/2026-10-23-antigravity-loadtimes.md`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/docs/consults/2026-10-23-antigravity-loadtimes.md) on branch `agy/mmc`:

1. **Card Diagnostic Counters (`1175aef`):** Added three per-second counters to `dbg_counters` in [`NGage.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/NGage.sv#L1008-L1036) (`DBG_CNT` `18 -> 21`) and updated [`tools/mister_dbg.py`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/tools/mister_dbg.py#L46-L97) to decode and print `mmc_blk/s`, `mmc_busy` (%), and `mmc_wait` (%) on the stalls line.
2. **26 MHz MMC Wire Clock (`27f65ab`):** Lowered the default `MMC_DIV` (`DIV`) from `12` (`8.67 MHz`) to `4` (`26.00 MHz`, 3× wire speed) and widened `MMC_TIMEOUT_LOG2` (`TIMEOUT_LOG2`) from `21` to `23` (`2^23 / 26 MHz = 322.6 ms` hardware data/busy timeout) in [`rtl/upp/upp_periph.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_periph.sv#L59-L60) and [`rtl/upp/upp_mmc.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_mmc.sv#L63-L65), keeping both as parameters with comments noting `12` (`8.66 MHz` from the service manual, with `TIMEOUT_LOG2 = 21`) for an accuracy build.
3. **4 KB `hps_io` Chunk Fetch & 8 KB Slot Buffer:** Expanded `buffer` in [`rtl/board/mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L259-L409) from `1 KB` (`tdp_ram #(.AW(9), .DW(16))`, 2 slots) to `8 KB` (`tdp_ram #(.AW(12), .DW(16))`, 16 × 512-byte sector slots), fetching aligned 4 KB chunks (`sd_blk_cnt = 7`, clamped to `nblk`) on `CMD18` streaming reads, prefetching the next 4 KB chunk while the second half of the current chunk shifts out, reserving 4 dedicated 512-byte slots for `CMD17` metadata reads and writes, and suppressing speculative fetches once the controller has queued `CMD12`.

---

## 2. Component 1: Card Counters & Exact Overlay Words / LCD Rows

In [`NGage.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/NGage.sv#L1008-L1027), `DBG_CNT` was increased from `18` to `21`, appending three events at the top of `dbg_ev` (`dbg_ev[20:18]`) so existing counters `0..17` keep their exact indices and overlay positions:

```systemverilog
localparam DBG_CNT = 21;
reg         dbg_mmc_busy_q = 0;
always @(posedge clk_sys) dbg_mmc_busy_q <= dbg_src0[22];
wire        tr_wb_retire = (tr_wb_valid || tr_wb_dvalid) && !tr_wb_dabt[1];
wire [DBG_CNT-1:0] dbg_ev = {
	dbg_src0[22] && dbg_src0[23] && !card_dat_oe,         // 20 mmc wire waits for Linux
	dbg_src0[22],                                         // 19 mmc clocks in data phase
	dbg_mmc_busy_q && !dbg_src0[22],                      // 18 mmc 512-byte blocks completed
```

> [!NOTE]
> In [`rtl/upp/upp_mmc.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_mmc.sv#L608) (`assign irq = {status[B_RESP], !status[B_CMD_BUSY], status[B_DATA_BUSY], !status[B_DATA_BUSY]};`) and [`rtl/upp/upp_periph.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_periph.sv#L266), `dbg_src0[22]` (`MMCDataRdy`) is `status[B_DATA_BUSY]` and `dbg_src0[23]` (`MMCCmdIdle`) is `!status[B_CMD_BUSY]`. Therefore, `B_DATA_BUSY` high and `B_CMD_BUSY` low with `card_dat_oe` low is `dbg_src0[22] && dbg_src0[23] && !card_dat_oe`.

### Overlay Word & LCD Row Mapping ([`NGage.sv:1110-1155`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/NGage.sv#L1110-L1155))

The overlay encodes `12 + DBG_CNT = 33` 32-bit words (`words 0..32`). Words `0..9` (`DBG_W0..DBG_W9`) occupy LCD rows `64..103` (4 rows per word); `dbg_cnt[0..20]` (`words 10..32`) start at LCD row `104` at 2 rows per 32-bit word (`y[1] == 0` encodes `w[31:16]`, `y[1] == 1` encodes `w[15:0]`):

| Counter Index | Overlay Word Index (`12 + idx`) | Signal / Expression | Meaning | LCD Rows (`scan_y`) | Decoder Output ([`tools/mister_dbg.py`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/tools/mister_dbg.py#L81-L97)) |
|---:|---:|---|---|---|---|
| `dbg_cnt[18]` | **Word 30** | `dbg_mmc_busy_q && !dbg_src0[22]` | 512-byte blocks completed/s (falling edge of `B_DATA_BUSY`) | **Rows 128–129** (`[31:16]`), **130–131** (`[15:0]`) | `mmc <N> blk/s` |
| `dbg_cnt[19]` | **Word 31** | `dbg_src0[22]` | `clk_sys` clocks in an MMC data phase (`B_DATA_BUSY` high) | **Rows 132–133** (`[31:16]`), **134–135** (`[15:0]`) | `busy <X.X>%` (of `104,000,000` clks/s) |
| `dbg_cnt[20]` | **Word 32** | `dbg_src0[22] && dbg_src0[23] && !card_dat_oe` | `clk_sys` clocks the wire waits in `D_RWAIT` for Linux (`B_DATA_BUSY` high, `B_CMD_BUSY` low, `card_dat_oe` low) | **Rows 136–137** (`[31:16]`), **138** (`[15:0]`) | `wait <X.X>%` (of `104,000,000` clks/s) |

- **Total LCD row check:** `DBG_WEND = 8'd104 + 8'(2 * (DBG_CNT - 2)) - 8'd3 = 139`, well within the 208-row LCD panel height (`69` rows of margin below row `139`).
- [`tools/game_keys.py`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/tools/game_keys.py) and [`tools/boot_profile.py`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/tools/boot_profile.py) delegate all screenshot decoding to `mister_dbg.read_overlay()` and required no changes.

---

## 3. Component 2: 26 MHz Wire Clock (`MMC_DIV = 4`, `MMC_TIMEOUT_LOG2 = 23`)

- In [`rtl/upp/upp_periph.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_periph.sv#L59-L60) and [`rtl/upp/upp_mmc.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_mmc.sv#L63-L65):
  - `MMC_DIV` (`DIV`) is reduced from `12` (`104 MHz / 12 = 8.67 MHz`) to `4` (`104 MHz / 4 = 26.00 MHz`).
  - `MMC_TIMEOUT_LOG2` (`TIMEOUT_LOG2`) is widened from `21` (`2^21 / 8.67 MHz = 242.0 ms`) to `23` (`2^23 / 26.00 MHz = 322.6 ms`).
- **Card model minimum half-period check:** [`rtl/board/mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L151-L154) requires at least 2 `clk_sys` cycles per `mmc_clk` half-period (`HALF = DIV / 2 = 2` at `DIV = 4`). Within `mmc_card.sv`, the 2-stage tag lookup + `settle` counter (`4` `clk_sys` cycles) and the registered BRAM byte read (`f_go -> f_v -> nxt_ok`, `2` `clk_sys` cycles) complete in `6` `clk_sys` cycles, fitting inside `NAC = 2` (`8` `clk_sys` cycles at `DIV = 4`) and inside a single shifted byte (`8 × 4 = 32` `clk_sys` cycles at `DIV = 4`).
- **DMA pacing check:** In [`rtl/upp/upp_mmc.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_mmc.sv#L277-L278), `dat_hold` pauses `mmc_clk` at byte boundaries whenever the 16-byte FIFO (`fmem`) is full on receive or empty on transmit. At `DIV = 4`, 4 bytes take `32 × 4 = 128` `clk_sys` cycles on the serial wire, while `upp_dma` drains 4 bytes (four 1-byte Wishbone reads + one 32-bit SDRAM write) in `~26` `clk_sys` cycles (`~20%` bus utilization), verified with concurrent CPU traffic in `make -C sim periph`.

---

## 4. Component 3: 4 KB Chunk Fetch & 8 KB Slot Buffer in `mmc_card.sv`

### Slot Organisation (`12 + 4` Split in a Single 8 KB `tdp_ram`)

[`rtl/board/mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L259-L367) replaces the `1 KB` (`2 × 512 B`) buffer with an `8 KB` true dual-port RAM (`tdp_ram #(.AW(12), .DW(16))`, 4,096 × 16-bit words = **16 × 512-byte sector slots**, `8` M10K blocks = **`+7 M10K`** over baseline):

| Slot Range | Size | Addressing (`slot[3:0]`) | Purpose & Replacement Policy |
|---|---|---|---|
| **Slots `0..11`** | `6 KB` (`3 × 2 KB` quarters of 4 sectors each) | `{mod3(s[22:2]), s[1:0]}` (`slot[3:2] in {2'b00, 2'b01, 2'b10}`) | **Aligned 4 KB (`8`-sector) `CMD18` streaming chunks.** Each 4 KB chunk (`s[22:3]`) consists of an even 2 KB half-chunk (`g0 = {s[22:3], 1'b0}`, 4 sectors) and an odd 2 KB half-chunk (`g1 = {s[22:3], 1'b1}`, 4 sectors), placed in quarters `q0 = mod3(g0)` and `q1 = mod3(g1)`. |
| **Slots `12..15`** | `2 KB` (`4 × 512 B` individual sector slots) | `{2'b11, m_idx}` (`slot[3:2] == 2'b11`, `m_idx in 0..3`) | **Reserved metadata / single-sector slots** for `CMD17` FAT and directory reads, `CMD24`/`CMD25` block writes, and the mount-time sidecar block, allocated round-robin via `m_repl`. |

### Why This Organisation Was Chosen

1. **Fits the strict `+7 M10K` budget:** As documented in [`docs/PROGRESS-LOG.md`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/docs/PROGRESS-LOG.md#L3422-L3441), b15 uses `470 / 553` M10Ks and the planned 32 KB I-cache + 32 KB D-cache require `~56` M10Ks (`526 / 553`), budgeting `+7 M10K` (`1 -> 8` M10K, a single 8 KB `tdp_ram`) for `mmc_card.sv`.
2. **Zero collision between active streaming data, next-chunk 4 KB prefetch, and `CMD17` metadata:**
   - If all 16 slots of the 8 KB RAM were used as two 4 KB streaming halves (`2 × 8` slots) with no dedicated metadata slots, every `CMD17` FAT or directory read between 4 KB `CMD18` bursts would overwrite a sector of the prefetched 4 KB streaming chunk (forcing a re-fetch on the next `CMD18`) and subsequent `CMD18` prefetches would overwrite all cached FAT sectors.
   - By mapping streaming 2 KB half-chunks `g = s[22:2]` modulo 3 into **three 2 KB quarters (`slots 0..11`)** and reserving **four 512 B slots (`slots 12..15`)** for `CMD17` metadata:
     - When `CMD18` fetches chunk `C` (`sectors 0..7`), half-chunk `2C` (`sectors 0..3`) goes into quarter `q0 = (2C) mod 3` and half-chunk `2C+1` (`sectors 4..7`) goes into quarter `q1 = (2C+1) mod 3`.
     - As soon as `CMD18` finishes shifting out `sectors 0..3` from `q0` and enters `sector 4` (`a_rlo[2] == 1`) in `q1`, quarter `q0` is no longer needed by the current chunk. The card immediately prefetches the next 4 KB chunk `C+1` (`sectors 8..15`) into quarters `q2 = (2C+2) mod 3` (`sectors 8..11`) and `q0 = (2C+3) mod 3` (`sectors 12..15`) while `sectors 4..7` shift out from `q1`!
     - Because any three consecutive 2 KB half-chunks (`2C+1`, `2C+2`, `2C+3`, spanning `6 KB = 12 sectors`) have distinct residues modulo 3, the 4 KB next-chunk prefetch never overwrites the active half-chunk `q1`, and has **4 full sector shift times (`65,824` clocks = `632.9 µs` at `DIV = 4`; `197,472` clocks = `1,898.8 µs` at `DIV = 12`)** to complete before `sector 7` finishes.
     - Meanwhile, `CMD17` FAT/directory reads use `slots 12..15`, so up to 4 distinct FAT/directory sectors stay cached across any number of `CMD18` streaming chunks without ever evicting streaming data or being evicted by `CMD18`.

### Incremental Per-Sector Validation, Clamping, and Write Coherency

- **Incremental validation (`sd_buff_addr[7:0] == 8'hFF`):** During a multi-sector `hps_io` read (`H_XFER`, `!h_meta`), [`mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L541-L549) marks each 512 B slot `h_cur_slot` valid as soon as its 256th 16-bit word arrives (`sd_buff_addr[7:0] == 8'hFF`). Thus `CMD18` begins shifting out the first requested sector as soon as that sector arrives in the chunk (without waiting for the remaining sectors of the 4 KB chunk to finish transferring from `hps_io`).
- **End-of-image & sidecar clamping:** For any streaming chunk `want_base = {want[22:3], 3'b000}`, `rem_blks = nblk - {9'd0, want_base}` and `want_cnt = (rem_blks >= 32'd8) ? 6'd7 : 6'(rem_blks - 32'd1)` ([`mmc_card.sv:478-480`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L478-L480)). Requests at or beyond `nblk` (where `nblk = l_blocks - 1` when an `NGAGEMMC` sidecar is present) never assert `sd_rd` and instead set `tzero[slot] <= 1'b1`, so the sidecar block and blocks past EOF are never crossed.
- **Write coherency:** `CMD24`/`CMD25` writes stay single-sector (`sd_blk_cnt = 0`) using a metadata slot `{2'b11, w_m_idx}` and invalidate the corresponding streaming quarter `w_q = mod3(w_sec[22:2])` (`4` slots) on `W_START`; conversely, streaming chunk fills invalidate any matching LBA tag in `slots 12..15`.

### Suppressing Speculative Fetches on `CMD12` & In-Flight Fetch Behaviour

1. **No speculative fetch once the controller has queued `CMD12`:**
   - In [`rtl/upp/upp_mmc.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/upp/upp_mmc.sv#L566-L573), when the CPU issues transfer type 10 (the final block of a `CMD18` burst with `CMD12` queued in `C_AFTER`), `status[B_CMD_BUSY]` (`!dbg_src0[23]`) is asserted immediately at the start of that final block and stays high until `CMD12`'s response tail completes.
   - [`mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L70) takes `input logic stop_queued` (wired to `!dbg_src0[23]` in [`NGage.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/NGage.sv#L814) and [`sim/harness/periph_tb.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/sim/harness/periph_tb.sv#L189)) and gates `allow_fetch` with `(!want_spec || !stop_queued)` ([`mmc_card.sv:485-487`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L485-L487)).
   - In addition, `mmc_card.sv` never speculates on the 8th sector of a chunk (`a_rlo[2:0] != 3'd7`, [`mmc_card.sv:404`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L404)) and, after `D_REL` advances `d_addr` at the end of a block (`!d_first`), requires `cmd_quiet && (d_state == D_DATA || (d_state == D_WAIT && nac > 8'(NAC)))` before launching a fetch. Because `CMD12` pulls `cmd_i` low on the very first `fall` (`nac == 0`) and sets `rx_on` on the first `rise` (`nac == 1`), `cmd_quiet` drops to `0` before `nac > NAC (2)` is ever reached, preventing the post-block demand fetch that previously fired during the 48-bit `CMD12` frame reception.
2. **Behaviour when a fetch is already in flight:**
   - **On a buffer hit (or hit on an already-delivered sector of an in-flight chunk):** Because `buffer` is a true dual-port RAM (`tdp_ram`) with `hps_io` writing on Port A and the card's read engine reading on Port B, `D_WAIT` ([`mmc_card.sv:748-754`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L748-L754)) does not wait for `h_state == H_IDLE`. Any `CMD17` or `CMD18` whose target sector is valid in `slots 0..15` starts shifting out on `DAT0` immediately (`NAC = 2`) while the `hps_io` transfer continues in the background on Port A.
   - **Why an in-flight `hps_io` transfer cannot be aborted on a buffer miss:** In [`sys/hps_io.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/sys/hps_io.sv#L329-L331) (lines 329–331 and 394–407), Linux `Main_MiSTer` polls `{sd_blk_cnt, ..., sd_rd}` and `sd_lba` in SPI command `'h16` (`UIO_GET_SDSTAT`) without asserting `sd_ack`, performs `pread()` in user-space, and only asserts `sd_ack` in a later SPI transaction (`'h0X17`). There is no cancel or abort signal in the `hps_io` protocol: dropping `sd_rd` or changing `sd_lba` during `H_REQ` can tear `sd_lba` across words 2–3 of `'h16` or cause the subsequent `'h0X17` data burst from the old `pread()` to be written into the new request's slot tags. Suppressing speculative fetches on `CMD12` and starting the 4 KB prefetch at sector 4 ensures `h_state == H_IDLE` by the time `CMD12` completes.

---

## 5. Verification Cases & 4 KB `CMD18` Burst Clock Table

### Directed Cases Added to [`sim/harness/mmc_main.cpp`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/sim/harness/mmc_main.cpp#L684-L907)

All cases run at **both `DIV = 12` (`8.67 MHz`) and `DIV = 4` (`26.00 MHz`)** in `test_streaming_and_slots()`:
1. **Aligned 4 KB `CMD18` chunks + `CMD17` metadata reads between chunks:** Reads chunk `64..71` (which prefetches `72..79`), issues four cold `CMD17` FAT reads (`blocks 2, 5, 12, 19`) into `slots 12..15`, then reads chunk `72..79` and verifies all 8 blocks hit with `NAC = 2` (confirming `CMD17` did not evict the prefetched streaming chunk).
2. **Repeated FAT reads hitting reserved slots:** Repeats the four `CMD17` FAT reads forward and backward before and after `CMD18` streaming bursts, verifying `0` new `hps_io` reads and `NAC = 2` on every repeat.
3. **Mid-chunk `CMD18` starts:** Tests `CMD18` starting in the first half (`block 162 = 160 + 2`, reading 10 blocks `162..171` across the `168` chunk boundary) and in the second half (`block 205 = 200 + 5`, reading 8 blocks `205..212` across the `208` chunk boundary), verifying `NAC = 2` across both chunk boundaries.
4. **Seek right after `CMD12` & in-flight hit:**
   - Asserts `stop_queued = 1` on the 5th block (`324`) of a `320..324` burst with `250 µs` HPS latency, verifying no speculative prefetch is launched (`1` HPS read total), `active == 0` after `CMD12`, and an immediate seek to `block 500` asserts `sd_rd` within `< 20` clocks.
   - Stops a `400..404` burst without `stop_queued` at `500 µs` HPS latency while the prefetch of `408..415` is still in flight (`active == 1`), then issues `CMD17` for cached metadata (`block 5`) and active-quarter streaming data (`block 405`), verifying both complete immediately with `NAC = 2` without waiting for the in-flight prefetch.
5. **Reads at the image's end and across the clamp:** On a `1,021`-data-block image (`127 × 8 + 5` blocks + 1 sidecar block at `1,021`, CSD capacity `32,760`), reads `blocks 1014..1023` across the `1016` chunk boundary and past `nblk`, verifying `sd_blk_cnt` is clamped to `4` (`5` blocks `1016..1020`) and `blocks 1021..1023` return zeros with `0` HPS reads of the sidecar block.

### 4 KB `CMD18` Burst Clock Table (Before vs. After)

**What the bench models:** `clk_sys = 104 MHz` (`1 µs = 104` clocks). When `sd_rd` is asserted, the `Hps` model in [`sim/harness/mmc_main.cpp`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/sim/harness/mmc_main.cpp#L108-L162) waits `fixed_delay` clocks (`100 µs = 10,400` clks, `250 µs = 26,000` clks, `500 µs = 52,000` clks) to model Linux `Main_MiSTer`'s `'h16` polling + `pread()` latency, then raises `sd_ack` and transfers `(sd_blk_cnt + 1) × 256` 16-bit words at `fixed_gap = 3` clocks/word (`768` clks = `7.38 µs` per 512 B sector; `6,144` clks = `59.08 µs` per 4 KB chunk).

The benchmark runs four consecutive 4 KB (`8`-sector) `CMD18 ... CMD12` bursts (`sectors 80..111`) with an interleaved `CMD17` FAT read (`sector 2`) before bursts 2 and 3:

| Wire Clock (`MMC_DIV`) | `hps_io` Latency (`fixed_delay`) | Metric | **Before** (`sd_blk_cnt = 0`, 1 KB 2-Slot Buffer) | **After** (`sd_blk_cnt = 7`, 8 KB 16-Slot Buffer) | Improvement |
|---|---|---|---:|---:|---|
| **`DIV = 12`** (`8.67 MHz`) | `100 µs` (`10,400` clks) | Cold 4 KB `CMD18` burst<br>Warm 4 KB `CMD18` burst (after FAT `CMD17`)<br>Repeated `CMD17` FAT read<br>HPS `sd_rd` count (16 KB + 2 FAT reads) | `408,144` clks<br>`408,144` clks (`1.00 MiB/s`)<br>`70,464` clks<br>`37` reads | `408,144` clks<br>**`397,584` clks (`1.02 MiB/s`)**<br>**`50,568` clks**<br>**`6` reads** | `0` exposed HPS wait<br>FAT hit (`-19,896` clks)<br>**`6.2×` fewer HPS reads** |
| **`DIV = 12`** (`8.67 MHz`) | `250 µs` (`26,000` clks) | Cold 4 KB `CMD18` burst<br>Warm 4 KB `CMD18` burst (after FAT `CMD17`)<br>Repeated `CMD17` FAT read<br>HPS `sd_rd` count (16 KB + 2 FAT reads) | `423,744` clks<br>`423,744` clks (`0.96 MiB/s`)<br>`101,664` clks<br>`37` reads | `423,744` clks<br>**`397,584` clks (`1.02 MiB/s`)**<br>**`50,568` clks**<br>**`6` reads** | **`-26,160` clks/burst**<br>**`2.01×` faster FAT read**<br>**`6.2×` fewer HPS reads** |
| **`DIV = 12`** (`8.67 MHz`) | `500 µs` (`52,000` clks) | Cold 4 KB `CMD18` burst<br>Warm 4 KB `CMD18` burst (after FAT `CMD17`)<br>Repeated `CMD17` FAT read<br>HPS `sd_rd` count (16 KB + 2 FAT reads) | `473,436` clks<br>`473,436` clks (`0.86 MiB/s`)<br>`104,292` clks<br>`36` reads | `449,748` clks<br>**`397,584` clks (`1.02 MiB/s`)**<br>**`50,568` clks**<br>**`6` reads** | **`-75,852` clks/burst (`1.19×`)**<br>**`2.06×` faster FAT read**<br>**`6.0×` fewer HPS reads** |
| **`DIV = 4`** (`26.00 MHz`) | `100 µs` (`10,400` clks) | Cold 4 KB `CMD18` burst<br>Warm 4 KB `CMD18` burst (after FAT `CMD17`)<br>Repeated `CMD17` FAT read<br>HPS `sd_rd` count (16 KB + 2 FAT reads) | `143,508` clks<br>`143,508` clks (`2.83 MiB/s`)<br>`38,396` clks<br>`37` reads | `143,504` clks<br>**`132,528` clks (`3.07 MiB/s`)**<br>**`16,856` clks**<br>**`6` reads** | **`3.08×` vs `DIV=12` before**<br>**`2.28×` faster FAT read**<br>**`6.2×` fewer HPS reads** |
| **`DIV = 4`** (`26.00 MHz`) | `250 µs` (`26,000` clks) | Cold 4 KB `CMD18` burst<br>Warm 4 KB `CMD18` burst (after FAT `CMD17`)<br>Repeated `CMD17` FAT read<br>HPS `sd_rd` count (16 KB + 2 FAT reads) | `231,296` clks<br>`231,296` clks (`1.76 MiB/s`)<br>`53,132` clks<br>`36` reads | `159,104` clks<br>**`132,528` clks (`3.07 MiB/s`)**<br>**`16,856` clks**<br>**`6` reads** | **`1.75×` vs `DIV=4` 1-sec**<br>**`3.20×` vs `DIV=12` before**<br>**`6.0×` fewer HPS reads** |
| **`DIV = 4`** (`26.00 MHz`) | `500 µs` (`52,000` clks) | Cold 4 KB `CMD18` burst<br>Warm 4 KB `CMD18` burst (after FAT `CMD17`)<br>Repeated `CMD17` FAT read<br>HPS `sd_rd` count (16 KB + 2 FAT reads) | `439,296` clks<br>`439,296` clks (`0.93 MiB/s`)<br>`105,132` clks<br>`36` reads | `185,104` clks<br>**`132,528` clks (`3.07 MiB/s`)**<br>**`16,856` clks**<br>**`6` reads** | **`3.31×` vs `DIV=4` 1-sec**<br>**`3.57×` vs `DIV=12` before**<br>**`6.0×` fewer HPS reads** |

### Suite Clocks Summary

- `make -C sim mmc`: `108` block reads, `0` block writes; **`13,907,842` clocks** (seed 1; seeds 1–5 all pass).
- `make -C sim periph`: `10` block reads, `12` block writes; **`3,643,060` clocks** (down from `29` block reads before Component 3).
- `make -C sim upp`: **`521,092` clocks** (`upp`) and **`379,022` clocks** (`upp256`).
- `make -C sim top`: **`119,463,677` clocks**.
- `make lint`: **0 warnings** across all 27 top modules.

---

## 6. Resource Cost, Timing, Risks & What Is Not Covered

- **M10K & Logic Cost:**
  - `buffer` in [`rtl/board/mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L290-L300) grows from `tdp_ram #(.AW(9), .DW(16))` (`1 KB` = `1` M10K) to `tdp_ram #(.AW(12), .DW(16))` (`8 KB` = `8` M10Ks), costing **`+7 M10K` blocks** (bringing b15's `470 / 553` M10Ks to `477 / 553`, within the planned budget).
  - Tag registers (`16 × 23-bit` `tag`, `16-bit` `tvalid`/`tzero`), `mod3()` combinational adder tree, and 3 additional 32-bit counters in `dbg_counters` add ~150–200 ALMs.
- **Timing:**
  - Nothing in `mmc_card.sv`, `upp_mmc.sv`, or `dbg_counters.sv` sits on the ARM925T CPU critical path.
  - All tag comparisons and `mod3()` slot calculations in `mmc_card.sv` remain pipelined across the two registered stages (`stage A` -> `stage B` guarded by `settle`, [`mmc_card.sv:375-408`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L375-L408)), `buffer` reads remain registered (`f_go -> f_v -> nxt_ok`), and `dat_o`/`cmd_o` remain driven directly from flip-flops.
- **Risks:**
  - If Linux `Main_MiSTer` experiences an SD/filesystem stall longer than `633 µs` during the second half of a 4 KB `CMD18` burst at `DIV = 4`, the next 4 KB chunk's prefetch will still be in progress when the next `CMD18` begins; in that case `D_WAIT` simply waits for the remaining clocks of that already-started prefetch (and up to `322.6 ms` before `B_DATA_TO`).
  - If a workload interleaves more than 4 distinct single-sector `CMD17` metadata LBAs between repeats, `m_repl` wraps around the 4 metadata slots (`12..15`) in FIFO order without affecting streaming slots `0..11`.
- **What Is Not Covered:**
  - Whole-core Quartus compilation and on-board measurement of *The Elder Scrolls Travels: Shadowkey* and *Tony Hawk's Pro Skater* against `b15` (to be run separately).
  - CPU/flash XIP stall improvements (covered in separate worktrees) and the optional internal `upp_mmc` -> `upp_dma` FIFO read bypass (`512` single-byte Wishbone arbitrations per block, ~3%–19% of bus cycles during a block).

---

## 7. Follow-Up: Pipelining Slot Arithmetic & Whole-Core Timing Closure

### Problem Observed in Whole-Core Builds `b21` and `b22`

In whole-core Quartus builds `b21` (`-1.212 ns` at Slow 1100mV 100C) and `b22` (`-1.370 ns` at Slow 1100mV 100C), the `mmc_card` slot-lookup and HPS request arithmetic became the worst critical-path family:
- **`b22` (`-1.370 ns`, Paths #1, #4, #5, #11):** `emu|mmc_card|tag[13][18]` -> `m_ok~34` -> `m_ok~39` -> `has_sec~28` -> `has_sec~56` -> `want[2]~0` -> `want~16` -> `Add114~22_OTERM14147` (`-1.370 ns`, `-1.353 ns`, `-1.348 ns`, `-1.277 ns`; 8 logic levels, `10.212 ns` data delay).
- **`b21` (`-1.192 ns`, Path #2):** `emu|mmc_card|a_srlo[3]` -> `Mux23~3` -> `Mux23~4` -> `s_ok~25` -> `want[2]~0` -> `want~14` -> `Add75~21_OTERM2947` (`-1.192 ns`; 7 logic levels, `10.394 ns` data delay).

**Root cause:** In the initial 2-stage bookkeeping block:
1. Stage A computed `w_rhi = sec_of(d_addr + bl - 1)` and `w_pchunk = {w_rlo[22:3] + 1, 3'b000}` and fed both adders directly into `s_slot()` (`mod3()` 4-level adder tree) in the same clock.
2. Stage B indexed `tag[0..15]` via `a_srlo`/`a_srhi`/`a_spchunk` (a 23-bit 16:1 mux `Mux23`), compared against `a_rlo`/`a_rhi`/`a_pchunk` (`s_ok`, `m_ok`), and selected `want` via priority muxes.
3. Downstream of `want`, the HPS request launch combinationally computed `rem_blks = nblk - {9'd0, want_base}` (32-bit subtractor `Add114`/`Add75`), `want_cnt = (rem_blks >= 8) ? 7 : (rem_blks - 1)`, `want_q0 = mod3(want_base[22:2])`, `want_q1 = mod3(want_base[22:2] + 1)`, and `s_slot(want)`. With `PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON`, Quartus retimed `want` forward into the middle of `Add114`/`Add75`, merging the tag mux, 23-bit equality compare, priority mux, and subtractor carry chain into a single 8-level path.

### Pipeline Restructuring in [`rtl/board/mmc_card.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-mmc/rtl/board/mmc_card.sv#L344-L483)

Because `if (bk_chg) settle <= 2'd3` already waits 4 clock edges before asserting `bk_ok`, the bookkeeping and HPS request computation was split into **four lightweight register stages** (`Stage 0` -> `Stage 1` -> `Stage 2` -> `Stage 3`) that fit inside the exact same 4-clock `settle` window:

1. **Stage 0 (`s0_*`, adders only):** Registers the candidate sector addresses `s0_rlo <= sec_of(d_addr)`, `s0_rhi <= sec_of(d_addr + {23'd0, bl} - 33'd1)`, and `s0_pchunk <= {w_rlo[22:3] + 20'd1, 3'b000}` with no `mod3` or comparisons in series.
2. **Stage 1 (`s1_*`, parallel `mod3` and per-slot tag compares):** From the registered `s0_*` sectors, computes `s1_srlo <= s_slot(s0_rlo)`, `s1_srhi <= s_slot(s0_rhi)`, and `s1_spchunk <= s_slot(s0_pchunk)` in parallel with per-slot 23-bit equality compares `s1_eq_lo[0..15]`, `s1_eq_hi[0..15]`, `s1_eq_pc[0..11]`, and the prefetch window flags `s1_pc_win` / `s1_pc_in` (`2–3` LUT levels per register).
3. **Stage 2 (`have_lo`, `have_hi`, `slot_lo`, `slot_hi`, `s2_want*`):** Replaces the 23-bit 16:1 tag mux + 23-bit comparator with a **1-bit** mux (`s1_eq_lo[s1_srlo]`) and 4-bit OR (`|s1_eq_lo[15:12]`), registering `have_lo`, `have_hi`, `slot_lo`, `slot_hi`, `s2_want`, and `s2_want_slot` (`2–3` LUT levels).
4. **Stage 3 (`want`, `want_slot`, `want_v`, `want_spec`, `want_oor`, `want_q0`, `want_q1`, `want_cnt`):**
   - Derives the two streaming quarters `want_q0` and `want_q1` directly from `s2_want_slot[3:2]` (`mod3(s2_want[22:2])`) and `s2_want[2]` via a 2-bit modulo-3 wrap (`s2_q_next`, `s2_q_prev`), eliminating both extra `mod3()` trees and the 21-bit incrementer (`want_base[22:2] + 21'd1`).
   - Replaces the 32-bit subtractor `rem_blks = nblk - {9'd0, want_base}` (`Add114`/`Add75`) with the exact chunk-equality check `({9'd0, s2_want[22:3]} == nblk[31:3]) ? {3'd0, nblk[2:0] - 3'd1} : 6'd7`, and registers `want_cnt`, `want_oor`, `want_q0`, and `want_q1` one clock before `H_REQ` launches.
5. **Additional single-cycle path cleanups:**
   - Registered read byte-fetch offsets (`f_one`, `f_next`, `f_more`, `d_last`) so `c_addr` in `D_WAIT`/`D_DATA` is a 1-LUT-level 2:1 mux between `slot_lo` and `slot_hi`.
   - Registered write-slot lookups (`w_q`, `w_in_file`, `w_m_hit[3:0]`) ahead of `W_START`/`W_PROG`.
   - Replaced the 23-bit adder `h_lba[22:0] + {20'd0, sd_buff_addr[10:8]}` in `H_XFER` with `{h_lba[22:3], sd_buff_addr[10:8]}` (since `h_lba` is 8-sector aligned when `!h_meta`) and registered `h_m_match[3:0]`.

### Verification & Whole-Core Timing Results

- **Simulation & 4 KB burst clocks:** Because all 4 stages settle within `settle <= 2'd3`, the `make -C sim mmc` 4 KB burst clocks are **cycle-for-cycle identical** to the merged figures (`132,528` clocks warm / `143,504`–`185,104` clocks cold at `DIV = 4`; `397,584` clocks warm at `DIV = 12`; `13,907,842` total clocks in `sim mmc`, `3,643,060` in `sim periph`, `521,092`/`379,022` in `sim upp`, `159,279,244` in `sim top`, `0` lint warnings).
- **Whole-core Quartus compile (`BUILD_DIR=dev/mister/NGage_MiSTer-mmct ./build.sh remote compile`):**

| Corner | Setup Worst Slack | Hold Worst Slack | Recovery | Removal |
|---|---:|---:|---:|---:|
| **Slow 1100mV 100C** | **`-1.295 ns`** (was `-1.370 ns` in `b22`) | `0.206 ns` | `3.073 ns` | `1.039 ns` |
| **Slow 1100mV -40C** | **`-1.194 ns`** | `0.091 ns` | `3.274 ns` | `0.971 ns` |
| **Fast 1100mV 100C** | **`2.940 ns`** | `0.130 ns` | `4.522 ns` | `0.504 ns` |
| **Fast 1100mV -40C** | **`3.518 ns`** | `0.091 ns` | `4.904 ns` | `0.425 ns` |

- **Top 30 critical paths (`build/critical-paths.rpt`):** **`0` paths in `mmc_card`** appear anywhere in the worst 30 setup paths (Path #1 is `ngage_mem|wb_arb2:arb|gnt_ad -> upp_bus:bus|fe_next[22]` at `-1.295 ns`, and Path #30 is `gnt_ad -> fe_next[3]` at `-0.962 ns`, confirming all `mmc_card` paths now have slack better than `-0.962 ns`, improving `mmc_card` by `> +0.41 ns`).
- **Fitter utilization (`output_files/NGage.fit.summary`):** `36,429 / 41,910` ALMs (`87%`), `44,611` registers, `477 / 553` M10K blocks (`86%`).
