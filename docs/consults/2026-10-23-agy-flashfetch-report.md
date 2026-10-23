# NOR Flash Line-Wide Fetch Path — 2026-10-23

Worktree: `NGage_MiSTer-agy-flash`, branch `agy/flashfetch`, starting commit `57bc20e`.

## Summary

Implemented a registered 64-bit-per-beat (16-byte line = two 8-byte beats) read-array fetch path across [`ddram_flash.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/mem/ddram_flash.sv), [`nor_flash.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/board/nor_flash.sv), [`upp_bus.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/upp/upp_bus.sv), and [`ngage_mem.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/upp/ngage_mem.sv) for 4-beat Wishbone incrementing bursts (`CTI = 3'b010`) when the target flash chip is idle in read-array mode:

- **Warm / cached 16-byte line fill (4 beats):** reduced from **35–39 clocks** (`12` wait clocks on the first beat + `7 + 9 + 7 = 23` wait clocks on the next three beats + `4` ack clocks; ~24 clocks average on hardware when mixing beat-buffer and cache hits) to **8 clocks** (**4 wait clocks** on the first beat, i.e. first beat acknowledged on clock 5, and **0 wait clocks** on beats 2, 3, and 4). This holds for both linear bursts (`BTE = 2'b00`) and critical-word-first wrap-4 bursts (`BTE = 2'b01`) starting at any word offset (`+0`, `+4`, `+8`, or `+12`).
- **Cold DDR3-miss 16-byte line fill (4 beats):** reduced from **54–56 clocks** (`27–29` wait clocks on the first beat + `23` wait clocks on the next three beats + `4` ack clocks) to **23–24 clocks** (`19–20` wait clocks on the first beat + `0` wait clocks on beats 2, 3, and 4 + `4` ack clocks). Fetching the sibling 16-byte half of the same 32-byte M10K cache line then completes in **8 clocks**.
- **Random mixed workload (`make -C sim upp`):** mean clocks per 4-beat flash read burst dropped from **56.9 clocks** (`28.0` first-beat wait + `3 × 8.3` next-beat wait + `4` acks) to **26.7 clocks** (`20.0` first-beat wait + `3 × 0.9` next-beat wait + `4` acks) on CS0, and from **55.8 clocks** to **25.1 clocks** on CS1.
- No files under `sys/` or `rtl/cpu/` were modified.

---

## Design

### 1. [`ddram_flash.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/mem/ddram_flash.sv)
- Added a wide line-read request/response port per chip:
  - `cs0_lreq`, `cs0_laddr[CS0_AW-1:2]`, `cs0_ltaken`, `cs0_lrvalid`, `cs0_lrbeat`, `cs0_lrdata[63:0]`
  - `cs1_lreq`, `cs1_laddr[CS1_AW-1:2]`, `cs1_ltaken`, `cs1_lrvalid`, `cs1_lrbeat`, `cs1_lrdata[63:0]`
- Each 16-byte CPU cache line consists of two consecutive 8-byte (64-bit) beats (`beat[0] = 0` and `beat[0] = 1`) within a single 32-byte M10K cache line (`LINE_LOG2 = 2`, four 8-byte beats per M10K line).
- **Critical-8-byte-beat-first on cache hits (`S_IDLE -> S_LOOK -> S_LINE`):**
  - In `S_IDLE`, `a0 = cs0_lreq ? {cs0_laddr, 2'b00} : cs0_addr` (and similarly `a1`), so the M10K `tags` and `data` RAMs immediately read the requested 32-byte line and the **critical 8-byte beat** (`cur_beat = pick_g[2 +: LINE_LOG2]`, where `cur_beat[0] = cur_g[2]` is the 8-byte half containing the CPU's critical word).
  - Notice that `pick = (req0 && req1) ? ~last_port : req1` depends only on the request signals (`req0`, `req1`, `last_port`) and not on the beat-buffer tag comparator `bb_hit`, keeping the M10K RAM read-address path short.
  - In `S_LOOK`, `dat_raddr` is switched to the sibling 8-byte beat of the 16-byte line (`{index_of(cur_g), cur_beat ^ LINE_LOG2'(1)}`).
  - On a cache hit (`cur_hit && cur_line`), `S_LOOK` registers the first 64-bit beat into `lrdata_q <= dat_q`, `lrbeat_q <= cur_g[2]`, `lrvalid_q[cur_port] <= 1'b1`, and advances to `S_LINE`.
  - One clock later in `S_LINE`, `dat_q` holds the sibling 64-bit beat; `S_LINE` registers `lrdata_q <= dat_q`, `lrbeat_q <= ~cur_g[2]`, `lrvalid_q[cur_port] <= 1'b1`, updates the chip's beat buffer (`bb_v`, `bb_beat`, `bb_data`), and returns to `S_IDLE`.
- **Cache miss (`S_LOOK -> S_FILL`):**
  - On a cache miss (`!cur_hit && cur_line`), `S_LOOK` issues the 4-beat (32-byte) DDR3 burst read and transitions to `S_FILL` exactly as for a halfword miss.
  - In `S_FILL`, as the four 8-byte beats return from DDR3 (`ddram_dout_ready`), the two beats belonging to the requested 16-byte half-line (`(fill_cnt >> 1) == (cur_beat >> 1)`) are registered into `lrvalid_q[cur_port] <= 1'b1`, `lrbeat_q <= fill_cnt[0]`, `lrdata_q <= ddram_dout`, while all four beats fill the M10K cache line as usual.
- Also hardened `S_LOOK` to check `if (abandon || reset)` so a `reset` asserted on the clock `ddram_flash` enters `S_LOOK` never starts an unacknowledged DDR3 write.

### 2. [`nor_flash.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/board/nor_flash.sv)
- Added `bus_array` and the wide line-read pass-through port (`bus_lreq / bus_laddr / bus_ltaken / bus_lrvalid / bus_lrbeat / bus_lrdata` to `mem_lreq / mem_laddr / mem_ltaken / mem_lrvalid / mem_lrbeat / mem_lrdata`).
- `bus_array` is asserted when the chip is alive (`~reset & rst_n`), in `M_READ` mode, with no unlock or command sequence in progress (`cseq == C_IDLE`), no program or erase active or suspended (`p_state == P_IDLE && e_state == E_IDLE`), and no bus or memory access in flight (`!b_wait && !m_active && !l_active`).
- When `bus_ltaken` pulses, `nor_flash` sets `l_pend <= 2'd2` (`l_active = l_pend != 2'd0`), which blocks any halfword `rq_pend` or `bus_wr_now` until both 64-bit beats have returned (`mem_lrvalid`).
- If `rst_n` (`RP#`) drops during an in-flight line read, `l_stale` is set and `bus_lrdata` returns `64'hFFFF_FFFF_FFFF_FFFF` so the bus transaction still terminates cleanly without hanging.

### 3. [`upp_bus.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/upp/upp_bus.sv) and [`ngage_mem.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/upp/ngage_mem.sv)
- Added `S_FLASH_LINE` and a 4-word (16-byte) registered line buffer (`fl_lb[4]`, `fl_lb_v[3:0]`), mirroring `S_SDR_RD`'s line buffer architecture.
- In `S_IDLE`, when a transaction targets `T_CS0` or `T_CS1` and `fl_lfree` (`!fl_lreq && fl_lpend == 2'd0`):
  - If `burst && !wb_we && ((tgt == T_CS0) ? fl0_array : fl1_array)` (`fl_line_ok`), `upp_bus` asserts `fl_lreq <= 1'b1`, latches `fl_widx <= wb_adr[3:2]`, `fl_wrap4 <= (wb_bte == 2'b01)`, `fl_in_blk <= 1'b1`, clears `fl_lb_v <= 4'b0000`, sets `fl_lpend <= 2'd2`, and enters `S_FLASH_LINE`. `fl_laddr <= wb_adr[FL_AW:3]` is loaded unconditionally whenever `!fl_lreq` to stay off the decode critical path.
  - Otherwise (any single/uncached access, write, or burst while `fl*_array` is low), `upp_bus` triggers `fs_go` and enters `S_FLASH` (the halfword path) unchanged.
- In `S_FLASH_LINE`:
  - Each returning 64-bit beat (`fl_lrvalid`) writes two 32-bit words into `fl_lb[{fl_lrbeat, 1'b0}]` and `fl_lb[{fl_lrbeat, 1'b1}]`, sets their `fl_lb_v` bits, and decrements `fl_lpend`.
  - The current beat's word index is held in the 2-bit register `fl_widx` (incremented by `2'd1` on each `ack_q <= 1'b1`), so `fl_hit_live = fl_lrvalid && fl_lrbeat == fl_widx[1]`, `fl_have = fl_lb_v[fl_widx] || fl_hit_live`, and `fl_word` depend **only on registers** (`fl_widx`, `fl_lb_v`, `fl_lb`, `fl_lrvalid`, `fl_lrbeat`, `fl_lrdata`) — no combinational `nxt(wb_adr)` adder feeds `dat_q` or `ack_q`.
  - When `ack_q <= 1'b1` on word 3 of a non-wrap-4 burst (`fl_widx == 2'd3 && !fl_wrap4`), `fl_in_blk` is cleared to `1'b0`.
  - When `!tb_ok || !fl_in_blk`, `S_FLASH_LINE` immediately transitions `state <= S_IDLE` (satisfying [`wb_arb2.sv`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/rtl/upp/wb_arb2.sv)'s invariant that `idle` is high on the clock following the final beat's `ack`). If a burst continues across a 16-byte boundary or across a chip-select boundary, `S_IDLE` re-decodes `wb_adr` on the next clock.
- In `S_FLASH` (the halfword path), constrained `fe_allowed` with `fe_next[31:27] == 5'd0 && fe_next[26:25] == {1'b0, fl_chip}` and returned `S_FLASH` to `S_IDLE` when `!tb_ok || (!fl_req && !fw_v)`, so a burst in status/autoselect mode that crosses out of a chip window (e.g. CS1 `0x03FFFFFC` -> CS2 `0x04000000`) stops reading the flash chip at the boundary and serves `0x04000000` as `T_EMPTY` (`EMPTY_DATA`).

---

## Cases Handled

| Case | Path taken | Behavior |
|---|---|---|
| 4-beat read burst (`CTI = 010`, linear `BTE = 00`) in read-array mode | `S_FLASH_LINE` | Fetches two 64-bit beats via `fl*_lreq`; answers 4 words in 8 clocks on a cache hit (first beat in 4 wait clocks, next 3 in 0 wait clocks) or 23–24 clocks on a DDR3 miss. |
| 4-beat wrap-4 read burst (`CTI = 010`, `BTE = 01`) at offset `+0`, `+4`, `+8`, or `+12` in read-array mode | `S_FLASH_LINE` | `ddram_flash` reads the critical 8-byte beat (`cur_g[2]`) first on a cache hit (`S_LOOK`) and the other 8-byte beat next (`S_LINE`). `fl_widx` wraps modulo 4 (`fl_widx + 2'd1`). All 4 offsets complete in **8 clocks** on a cache hit. |
| Uncached single byte / halfword / word read (`CTI != 010`) | `S_FLASH` | Uses the existing 16-bit halfword engine (`halves(wb_sel, 0)`), reading only the halfwords selected by `wb_sel`. |
| Flash command writes, word programs, sector/chip erases | `S_FLASH` | Uses the existing 16-bit halfword path; `ddram_flash` writes through to DDR3 and updates any cached M10K line and beat buffer in place. |
| Burst or single read during unlock sequence (`cseq != C_IDLE`), autoselect (`M_AUTO`), CFI (`M_CFI`), program busy/fail (`p_state != P_IDLE`), erase window/run/suspend (`e_state != E_IDLE`), or `rst_n == 0` | `S_FLASH` | `fl*_array` is `0`; `upp_bus` uses `S_FLASH` so status reads toggle `DQ6`/`DQ2` per halfword read and never read ahead past the burst's end. |
| CS0 (16 MB in 32 MB `0x00000000–0x01FFFFFF`) and CS1 (8 MB in 32 MB `0x02000000–0x03FFFFFF`) address mirroring | `S_FLASH_LINE` / `S_FLASH` | `fl0_laddr` uses `wb_adr[23:3]` (ignoring bit 24) and `fl1_laddr` uses `wb_adr[22:3]` (ignoring bits 24:23), matching `fl0_addr` and `fl1_addr`. |
| Burst crossing from CS1 into CS2/CS3 (`0x03FFFFF8..0x04000004`) or CS0 into CS1 (`0x01FFFFF8..0x02000004`) | `S_FLASH_LINE` or `S_FLASH` -> `S_IDLE` | After answering `0x03FFFFFC` (`fl_widx == 3 && !fl_wrap4` on the wide path, or `!fe_allowed` on the halfword path), `upp_bus` returns to `S_IDLE`, which decodes `0x04000000` as `T_EMPTY` (`EMPTY_DATA = 0x00000000`) or `0x02000000` as `T_CS1`. |
| Loader writes (`ld_we`) and system `reset` | `ddram_flash` | Flash image writes via `ld_we` trigger `S_SWEEP` to invalidate all 4,096 M10K tags and clear `bb_v`; `reset` aborts in-flight requests cleanly. |

---

## Verification & Bench Results

All required checks and benches pass with zero warnings/errors:
- `make lint` (Verilator across all 97 modules / 16 top targets, warnings as errors)
- `make -C sim flash` (`Vnor_flash` for CS0 16 MB and CS1 8 MB, extended with `test_line_port` in [`sim/harness/flash_main.cpp`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/sim/harness/flash_main.cpp))
- `make -C sim ddrflash` (`Vddram_flash`, extended with `line_read` on CS0 and CS1 in [`sim/harness/ddrflash_main.cpp`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/sim/harness/ddrflash_main.cpp))
- `make -C sim upp` (`Vngage_mem` with 64 KB BRAM on-chip and 256 KB SDRAM on-chip, extended with `flash_line_bursts` in [`sim/harness/upp_main.cpp`](file:///Users/jacob/dev/fpga/mister/NGage_MiSTer-agy-flash/sim/harness/upp_main.cpp))
- `make -C sim top` (`Vemu` full-core testbench; `memory test: first pass in 92220 clocks` vs `99639 clocks` before, `emu: all checks passed`)

### Clocks per 16-Byte Flash Line (`sim/harness/upp_main.cpp`, seed 1)

Wait clocks are measured from a beat being presented on the Wishbone bus to the rising edge where `wb_ack` is high (`lat` table in `upp_main.cpp`); total clocks per 4-beat line equal the sum of the 4 beats' wait clocks plus 4 ack clocks:

| Flash 4-beat (16 B) burst scenario | Before: beat wait clocks (b0 / b1–b3) | Before: total clocks / line | After: beat wait clocks (b0 / b1–b3) | After: total clocks / line |
|---|---:|---:|---:|---:|
| Quiet CS0 cold line fill (DDR3 miss, `0x00010000`) | `29 / 7, 9, 7` | **56** | `19 / 0, 0, 0` | **23–24** |
| Quiet CS0 sibling line fill (M10K hit, `0x00010010`) | `12 / 7, 9, 7` | **39** | `4 / 0, 0, 0` | **8** |
| Quiet CS0/CS1 warm line fill (linear `BTE = 00`) | `8–12 / 7, 9, 7` | **35–39** | `4 / 0, 0, 0` | **8** |
| Quiet CS0/CS1 warm line fill (wrap-4 `BTE = 01`, offsets `+0/+4/+8/+12`) | `8–12 / 7, 9, 7` | **35–39** | `4 / 0, 0, 0` | **8 / 8 / 8 / 8** |
| Random workload CS0 burst (`upp`, 64 KB on-chip) | `28.0 / 3 × 8.3` | **56.9** | `20.0 / 3 × 0.9` | **26.7** |
| Random workload CS1 burst (`upp`, 64 KB on-chip) | `26.9 / 3 × 8.3` | **55.8** | `18.7 / 3 × 0.8` | **25.1** |
| Random workload CS0 burst (`upp256`, 256 KB on-chip) | `28.7 / 3 × 8.4` | **57.9** | `20.1 / 3 × 1.0` | **27.1** |
| Random workload CS1 burst (`upp256`, 256 KB on-chip) | `28.6 / 3 × 8.5` | **58.1** | `18.9 / 3 × 0.9` | **25.6** |

---

## Timing, Area, Risks, and What Is Not Covered

- **Timing:**
  - `ddram_flash` registers its wide outputs (`lrvalid_q`, `lrbeat_q`, `lrdata_q`). Its M10K `tags`/`data` read-address mux `pick` in `S_IDLE` depends only on `cs0_req || cs0_lreq`, `cs1_req || cs1_lreq`, and `last_port` (not `bb_hit`).
  - `upp_bus` registers the incoming 64-bit beats into `fl_lb[4]` / `fl_lb_v[3:0]` and selects the Wishbone beat word using the 2-bit register `fl_widx` (avoiding the 30-bit `nxt(wb_adr)` adder on `tb`). `dat_q` and `ack_q` Remain direct flip-flop outputs (`wb_dat_o = dat_q`, `wb_ack = ack_q`) with zero combinational logic added after `dat_q` or `ack_q`.
- **Area:**
  - Adds one 64-bit register (`lrdata_q`) plus 4 control flip-flops in `ddram_flash`, 3 control flip-flops per `nor_flash` instance, and a 128-bit (`4 × 32`) line buffer (`fl_lb`) plus 33 flip-flops (`fl_laddr`, `fl_lb_v`, `fl_lpend`, `fl_widx`, `fl_in_blk`, `fl_wrap4`, `fl_lreq`, `fl_lchip`) in `upp_bus` (~235 flip-flops total, 0 M10K blocks).
- **Risks:**
  - Although all signals feeding `dat_q` and `ack_q` in `S_FLASH_LINE` are registered, `upp_bus` adds one more state to the `dat_q` / `ack_q` input mux and routes a 64-bit read bus (`fl0_lrdata`, `fl1_lrdata`) from `ddram_flash` to `upp_bus`. Quartus placement and routing at 104 MHz must confirm that this 64-bit interconnect does not encroach on the core's critical setup paths.
- **Not covered here:**
  - Quartus 17 synthesis, fitting, and static timing analysis at 104 MHz.
  - Full Symbian firmware boot bench (`sim/top` runs the self-test and small CPU program, not the full OS boot).
  - On-board game speed and flash wait-counter measurements in Tony Hawk, SonicN, and Asphalt on the DE10-Nano hardware.
