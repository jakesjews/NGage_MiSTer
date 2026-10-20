// SPDX-License-Identifier: GPL-2.0-or-later
//
// Samsung K8S2815ETA (128 Mbit, CS0) / K8S6415ETA (64 Mbit, CS1) NOR flash as
// the N-Gage QD's firmware sees it: a 16-bit word device with the AMD command
// set. The array lives in an external memory reached through a request port
// (served by an SDRAM or DDR3 controller); this module adds the command
// decoder, the embedded program and erase operations and their status reads.
//
// Commands (word addresses; only A10-A0 and DQ7-DQ0 are decoded in the
// unlock cycles, as on AMD parts):
//   F0                       reset to reading the array (any time but during
//                            an operation; also clears a failed program)
//   555/AA 2AA/55 555/90     autoselect: +00 manufacturer, +01 device,
//                            +02 sector protection (none), +0E/+0F extra IDs
//   55/98 (or 555/98)        CFI query
//   555/AA 2AA/55 555/A0 PA/PD           word program
//   555/AA 2AA/55 555/80 555/AA 2AA/55 555/10   chip erase
//   555/AA 2AA/55 555/80 555/AA 2AA/55 SA/30    sector erase; more SA/30
//                            within the erase window add sectors
//   B0 / 30                  erase suspend / resume (any address)
//   555/AA 2AA/55 555/20     unlock bypass: then xxx/A0 PA/PD programs,
//                            xxx/80 xxx/10 or SA/30 erases, xxx/90 xxx/00 leaves
//   555/AA 2AA/55 555/C0     burst configuration [taken and ignored: the
//                            burst interface is not modelled]
//   xxx/60 BA/60             Samsung block lock (A6 = 0) or unlock (A6 = 1)
//                            of the sector at BA; autoselect +02 there reads
//                            1 while it is locked. A locked sector is not
//                            programmed or erased (the command is dropped).
//                            The firmware's LFFS driver medint.pdd unlocks
//                            this way and checks +02 (model/hw/ngage_flash.c).
// Programming can only clear bits (new = old & data).
//
// Status (reads in a bank that is busy; DQ15-DQ8 read 0):
//   program:        DQ7 = not data bit 7, DQ6 toggles each read, DQ5 = 1 if
//                   the program asked for a 0 to become 1 (PROGRAM_FAIL_DQ5;
//                   then only F0 returns to the array), DQ2 = 1
//   erase:          DQ7 = 0, DQ6 toggles, DQ3 = 0 in the erase window and 1
//                   after it, DQ2 toggles on reads in a selected sector
//   erase suspended: reads in a selected sector give DQ7 = 1, DQ6 steady,
//                   DQ2 toggling; everything else reads the array, and words
//                   outside the selected sectors may be programmed.
// Other banks read the array during an operation (read-while-write).
//
// Timing: an operation lasts at least its busy time and at least as long as
// its memory accesses take: PROGRAM_CLKS a word, SECTOR_ERASE_CLKS a sector
// (chip erase = every sector in turn), ERASE_WINDOW_CLKS for more sectors.
//
// Ports, both req/ack: a request is held, unchanged, until the cycle in which
// ack is high, which completes it; read data comes with that ack. The next
// request may follow in the next cycle, so a responder must not take req as
// a new request in the cycle in which it acks. bus_* is the ASIC side (one
// request at a time); mem_* goes to the array (word address within the chip).
// rst_n is the RP# pin: it stops any operation (a sector being erased is left
// part-erased) and returns to reading the array.
//
// Facts the research leaves open, behind parameters and marked [assumed]:
//   * the sector map: TOP_BOOT, eight 4K-word parameter sectors at the top
//     ("T" in the part number) and 32K-word main sectors elsewhere;
//   * BANKS_LOG2 = 4: sixteen equal banks for read-while-write;
//   * the busy times (typical figures for 1.8 V NOR of the time), and the
//     CFI timing, voltage and burst fields derived from them;
//   * DEVICE_ID2/3, the extra autoselect words;
//   * autoselect and CFI answer at every address, not per bank;
//   * LOCKED_AT_RESET = 0: every sector unlocked at power-up and on RP# (the
//     QEMU model never locks and the firmware runs; on some Samsung parts
//     every block powers up locked).
module nor_flash #(
	parameter int          AW                = 23,          // word address bits: 23 = 16 MB, 22 = 8 MB
	parameter logic [15:0] MANUFACTURER      = 16'h00EC,
	parameter logic [15:0] DEVICE_ID         = 16'h22F8,
	parameter logic [15:0] DEVICE_ID2        = 16'h0000,
	parameter logic [15:0] DEVICE_ID3        = 16'h0000,
	parameter bit          TOP_BOOT          = 1'b1,
	parameter int          BANKS_LOG2        = 4,
	parameter int          CLK_HZ            = 104_000_000,
	parameter int          PROGRAM_CLKS      = CLK_HZ / 100_000,      // 10 us
	parameter int          SECTOR_ERASE_CLKS = CLK_HZ / 10 * 7,       // 0.7 s
	parameter int          ERASE_WINDOW_CLKS = CLK_HZ / 20_000,       // 50 us
	parameter bit          PROGRAM_FAIL_DQ5  = 1'b1,
	parameter bit          LOCKED_AT_RESET   = 1'b0
) (
	input  logic          clk,
	input  logic          reset,
	input  logic          rst_n,

	input  logic          bus_req,
	input  logic          bus_we,
	input  logic [AW-1:0] bus_addr,
	input  logic [15:0]   bus_wdata,
	output logic [15:0]   bus_rdata,
	output logic          bus_ack,

	output logic          mem_req,
	output logic          mem_we,
	output logic [AW-1:0] mem_addr,
	output logic [15:0]   mem_wdata,
	input  logic [15:0]   mem_rdata,
	input  logic          mem_ack,

	// an embedded operation is running (RY/BY# inverted)
	output logic          busy
);

	localparam int NMAIN = (1 << (AW - 15)) - 1;   // 32K-word sectors
	localparam int NSECT = NMAIN + 8;              // plus eight 4K-word sectors
	localparam int SW = $clog2(NSECT + 1);
	localparam int NBANKS = 1 << BANKS_LOG2;

	// CFI timing fields: 2^n us a word, 2^n ms a sector and the chip
	localparam int PROG_US  = (PROGRAM_CLKS / (CLK_HZ / 1_000_000) < 1) ? 1 : PROGRAM_CLKS / (CLK_HZ / 1_000_000);
	localparam int SERASE_MS = (SECTOR_ERASE_CLKS / (CLK_HZ / 1000) < 1) ? 1 : SECTOR_ERASE_CLKS / (CLK_HZ / 1000);
	localparam logic [7:0] CFI_PROG   = 8'($clog2(PROG_US));
	localparam logic [7:0] CFI_SERASE = 8'($clog2(SERASE_MS));
	localparam logic [7:0] CFI_CERASE = 8'($clog2(SERASE_MS) + $clog2(NSECT));

	// ------------------------------------------------------------------
	// Sector map
	// ------------------------------------------------------------------
	localparam logic [SW-1:0] NMAIN_S = NMAIN[SW-1:0];
	localparam logic [SW-1:0] NSECT_S = NSECT[SW-1:0];
	localparam logic [SW-1:0] EIGHT_S = 8;
	localparam logic [SW-1:0] SEVEN_S = 7;

	function automatic logic [SW-1:0] sector_of(input logic [AW-1:0] a);
		logic [SW-1:0] blk;
		blk = '0;
		blk[AW-16:0] = a[AW-1:15];
		if (TOP_BOOT) begin
			if (&a[AW-1:15]) return NMAIN_S + {{(SW-3){1'b0}}, a[14:12]};
			return blk;
		end else begin
			if (a[AW-1:15] == '0) return {{(SW-3){1'b0}}, a[14:12]};
			return blk + SEVEN_S;
		end
	endfunction

	function automatic logic is_small(input logic [SW-1:0] s);
		return TOP_BOOT ? (s >= NMAIN_S) : (s < EIGHT_S);
	endfunction

	function automatic logic [AW-1:0] sector_base(input logic [SW-1:0] s);
		logic [AW-1:0] b;
		logic [SW-1:0] d;
		b = '0;
		if (TOP_BOOT) begin
			d = s - NMAIN_S;
			if (s >= NMAIN_S) b = {{(AW-15){1'b1}}, d[2:0], 12'd0};
			else              b[AW-1:15] = s[AW-16:0];
		end else begin
			d = s - SEVEN_S;
			if (s < EIGHT_S) b[14:12] = s[2:0];
			else             b[AW-1:15] = d[AW-16:0];
		end
		return b;
	endfunction

	function automatic logic [BANKS_LOG2-1:0] bank_of(input logic [AW-1:0] a);
		return a[AW-1 -: BANKS_LOG2];
	endfunction

	function automatic logic [15:0] status(input logic dq7, input logic dq6, input logic dq5,
			input logic dq3, input logic dq2);
		return {8'h00, dq7, dq6, dq5, 1'b0, dq3, dq2, 2'b00};
	endfunction

	function automatic logic [15:0] autoselect(input logic [7:0] a, input logic locked);
		case (a)
			8'h00:   return MANUFACTURER;
			8'h01:   return DEVICE_ID;
			8'h02:   return {15'd0, locked};
			8'h0E:   return DEVICE_ID2;
			8'h0F:   return DEVICE_ID3;
			default: return 16'h0000;
		endcase
	endfunction

	function automatic logic [7:0] cfi(input logic [7:0] a);
		logic [15:0] nm1;
		nm1 = 16'(NMAIN - 1);
		case (a)
			8'h10: return 8'h51;            // "QRY"
			8'h11: return 8'h52;
			8'h12: return 8'h59;
			8'h13: return 8'h02;            // AMD/Fujitsu standard command set
			8'h15: return 8'h40;            // primary extended table at 0x40
			8'h1B: return 8'h17;            // Vcc 1.7 V to 1.95 V
			8'h1C: return 8'h19;
			8'h1F: return CFI_PROG;
			8'h21: return CFI_SERASE;
			8'h22: return CFI_CERASE;
			8'h23: return 8'h04;            // maxima: 16 times typical
			8'h25: return 8'h04;
			8'h26: return 8'h04;
			8'h27: return 8'(AW + 1);       // 2^n bytes
			8'h28: return 8'h01;            // x16 only
			8'h2C: return 8'h02;            // two erase block regions
			8'h2D: return TOP_BOOT ? nm1[7:0] : 8'h07;
			8'h2E: return TOP_BOOT ? nm1[15:8] : 8'h00;
			8'h2F: return TOP_BOOT ? 8'h00 : 8'h20;
			8'h30: return TOP_BOOT ? 8'h01 : 8'h00;
			8'h31: return TOP_BOOT ? 8'h07 : nm1[7:0];
			8'h32: return TOP_BOOT ? 8'h00 : nm1[15:8];
			8'h33: return TOP_BOOT ? 8'h20 : 8'h00;
			8'h34: return TOP_BOOT ? 8'h00 : 8'h01;
			8'h40: return 8'h50;            // "PRI" 1.3
			8'h41: return 8'h52;
			8'h42: return 8'h49;
			8'h43: return 8'h31;
			8'h44: return 8'h33;
			8'h46: return 8'h02;            // erase suspend: read and program
			8'h47: return 8'h01;
			8'h49: return 8'h04;
			8'h4B: return 8'h01;            // burst mode
			8'h4F: return TOP_BOOT ? 8'h03 : 8'h02;
			default: return 8'h00;
		endcase
	endfunction

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------
	localparam logic [1:0] M_READ = 2'd0;
	localparam logic [1:0] M_AUTO = 2'd1;
	localparam logic [1:0] M_CFI  = 2'd2;

	// command sequence
	localparam logic [3:0] C_IDLE   = 4'd0;
	localparam logic [3:0] C_U1     = 4'd1;   // after 555/AA
	localparam logic [3:0] C_U2     = 4'd2;   // after 2AA/55
	localparam logic [3:0] C_PROG   = 4'd3;   // next write programs
	localparam logic [3:0] C_E1     = 4'd4;   // after 80
	localparam logic [3:0] C_E2     = 4'd5;   // after 80 AA
	localparam logic [3:0] C_E3     = 4'd6;   // after 80 AA 55
	localparam logic [3:0] C_BERASE = 4'd7;   // unlock bypass, after 80
	localparam logic [3:0] C_BEXIT  = 4'd8;   // unlock bypass, after 90
	localparam logic [3:0] C_LOCK   = 4'd9;   // after 60

	localparam logic [1:0] P_IDLE = 2'd0;
	localparam logic [1:0] P_RUN  = 2'd1;
	localparam logic [1:0] P_FAIL = 2'd2;

	localparam logic [1:0] E_IDLE   = 2'd0;
	localparam logic [1:0] E_WINDOW = 2'd1;
	localparam logic [1:0] E_RUN    = 2'd2;
	localparam logic [1:0] E_SUSP   = 2'd3;

	localparam logic [1:0] S_FIND  = 2'd0;    // erase: looking for the next sector
	localparam logic [1:0] S_WRITE = 2'd1;    // writing its words
	localparam logic [1:0] S_WAIT  = 2'd2;    // waiting out its busy time

	localparam logic [1:0] SRC_BUS   = 2'd0;
	localparam logic [1:0] SRC_PROG  = 2'd1;
	localparam logic [1:0] SRC_ERASE = 2'd2;

	logic [1:0]        mode;
	logic [3:0]        cseq;
	logic              bypass;
	logic              tog6, tog2;

	// program engine
	logic [1:0]        p_state;
	logic [AW-1:0]     p_addr;
	logic [15:0]       p_data, p_old;
	logic [1:0]        p_step;                // 0 read, 1 write, 2 memory done
	logic [31:0]       p_timer;

	// erase engine
	logic [1:0]        e_state;
	logic [NSECT-1:0]  sel;
	logic [NSECT-1:0]  lock;
	// A sector's erase selection or lock bit is set a clock after the command
	// that names it, from a registered sector number: the decode of bus_addr
	// into NSECT bits stays off the bus path (it was the core's worst path).
	// The erase engine looks at sel only after the erase window, and the next
	// bus access comes clocks later, so the delay shows nowhere.
	logic              sec_set_q, lock_set_q, lock_v_q;
	logic [SW-1:0]     sec_q;
	logic [NBANKS-1:0] bank_sel;
	logic [SW-1:0]     e_sector;
	logic [1:0]        e_step;
	logic [AW-1:0]     e_ptr;
	logic [15:0]       e_left;
	logic [31:0]       e_timer;

	// memory port
	logic              m_active;
	logic [1:0]        m_src;
	logic              m_stale;               // its owner was reset meanwhile

	// a bus read waiting for the array
	logic              b_wait;
	logic [AW-1:0]     b_addr;

	wire alive = ~reset & rst_n;
	// a bus write is taken this cycle (it may restart or end the erase window)
	wire bus_wr_now = alive & bus_req & ~bus_ack & ~b_wait & bus_we;

	// ------------------------------------------------------------------
	// Decisions on the current bus request
	// ------------------------------------------------------------------
	wire [BANKS_LOG2-1:0] rq_bank = bank_of(bus_addr);
	wire [SW-1:0]         rq_sec  = sector_of(bus_addr);
	wire                  rq_sel  = sel[rq_sec];
	wire                  rq_lock = lock[rq_sec];
	wire                  rq_ul1  = bus_addr[10:0] == 11'h555;
	wire                  rq_ul2  = bus_addr[10:0] == 11'h2AA;
	wire [7:0]            rq_cmd  = bus_wdata[7:0];

	wire prog_status  = p_state != P_IDLE && rq_bank == bank_of(p_addr);
	wire erase_status = (e_state == E_WINDOW || e_state == E_RUN) && bank_sel[rq_bank];
	wire susp_status  = e_state == E_SUSP && rq_sel;

	// may a program start at bus_addr now?
	wire prog_ok = p_state == P_IDLE && (e_state == E_IDLE || (e_state == E_SUSP && !rq_sel));
	wire idle_ok = p_state == P_IDLE && e_state == E_IDLE;

	assign busy = p_state != P_IDLE || e_state == E_WINDOW || e_state == E_RUN;

	// ------------------------------------------------------------------
	// Everything
	// ------------------------------------------------------------------
	task automatic start_program();
		p_state <= P_RUN;
		p_addr  <= bus_addr;
		p_data  <= bus_wdata;
		p_step  <= 2'd0;
		p_timer <= 32'(PROGRAM_CLKS);
		mode    <= M_READ;
	endtask

	task automatic start_chip_erase();
		sel      <= ~lock;
		bank_sel <= '1;
		e_state  <= E_RUN;
		e_sector <= '0;
		e_step   <= S_FIND;
		mode     <= M_READ;
	endtask

	task automatic start_sector_erase();
		sec_set_q         <= 1'b1;        // sel[rq_sec], unless locked, next clock
		sec_q             <= rq_sec;
		bank_sel[rq_bank] <= 1'b1;
		e_state           <= E_WINDOW;
		e_timer           <= 32'(ERASE_WINDOW_CLKS);
		e_sector          <= '0;
		e_step            <= S_FIND;
		mode              <= M_READ;
	endtask

	task automatic sector_bits();
		sec_set_q  <= 1'b0;
		lock_set_q <= 1'b0;
		if (sec_set_q && !lock[sec_q]) sel[sec_q] <= 1'b1;
		if (lock_set_q) lock[sec_q] <= lock_v_q;
	endtask

	task automatic bus_write();
		if (p_state == P_FAIL) begin
			if (rq_cmd == 8'hF0) begin
				p_state <= P_IDLE;
				cseq    <= C_IDLE;
				mode    <= M_READ;
			end
		end else if (p_state == P_RUN) begin
			// commands are ignored while a word is programmed
		end else if (e_state == E_WINDOW) begin
			if (rq_cmd == 8'h30) begin
				sec_set_q         <= 1'b1;
				sec_q             <= rq_sec;
				bank_sel[rq_bank] <= 1'b1;
				e_timer           <= 32'(ERASE_WINDOW_CLKS);
			end else if (rq_cmd == 8'hB0) begin
				e_state <= E_SUSP;
			end else begin
				// anything else ends the window and the erase with it
				e_state  <= E_IDLE;
				sel      <= '0;
				bank_sel <= '0;
				cseq     <= C_IDLE;
			end
		end else if (e_state == E_RUN) begin
			if (rq_cmd == 8'hB0) e_state <= E_SUSP;
		end else if (rq_cmd == 8'hF0 && cseq != C_PROG) begin
			cseq <= C_IDLE;
			mode <= M_READ;
		end else begin
			// reading the array (or erase-suspend read): command sequences
			case (cseq)
				C_IDLE: begin
					if (bypass) begin
						case (rq_cmd)
							8'hA0: cseq <= C_PROG;
							8'h80: if (idle_ok) cseq <= C_BERASE;
							8'h90: cseq <= C_BEXIT;
							default: ;
						endcase
					end else if (rq_ul1 && rq_cmd == 8'hAA) begin
						cseq <= C_U1;
					end else if (rq_cmd == 8'h98 && (bus_addr[7:0] == 8'h55 || rq_ul1)) begin
						mode <= M_CFI;
					end else if (rq_cmd == 8'h30 && e_state == E_SUSP) begin
						e_state <= E_RUN;
						mode    <= M_READ;
					end else if (rq_cmd == 8'h60) begin
						cseq <= C_LOCK;
					end
				end
				C_U1: cseq <= (rq_ul2 && rq_cmd == 8'h55) ? C_U2 : C_IDLE;
				C_U2: begin
					cseq <= C_IDLE;
					if (rq_ul1) begin
						case (rq_cmd)
							8'h90: mode <= M_AUTO;
							8'h98: mode <= M_CFI;
							8'hA0: cseq <= C_PROG;
							8'h80: if (idle_ok) cseq <= C_E1;
							8'h20: if (idle_ok) begin bypass <= 1'b1; mode <= M_READ; end
							default: ;            // C0 burst configuration and the rest
						endcase
					end
				end
				C_PROG: begin
					cseq <= C_IDLE;
					if (prog_ok && !rq_lock) start_program();
				end
				C_LOCK: begin
					cseq <= C_IDLE;
					if (rq_cmd == 8'h60) begin
						lock_set_q <= 1'b1;
						lock_v_q   <= ~bus_addr[6];
						sec_q      <= rq_sec;
					end
				end
				C_E1: cseq <= (rq_ul1 && rq_cmd == 8'hAA) ? C_E2 : C_IDLE;
				C_E2: cseq <= (rq_ul2 && rq_cmd == 8'h55) ? C_E3 : C_IDLE;
				C_E3: begin
					cseq <= C_IDLE;
					if (rq_cmd == 8'h10 && rq_ul1) start_chip_erase();
					else if (rq_cmd == 8'h30) start_sector_erase();
				end
				C_BERASE: begin
					cseq <= C_IDLE;
					if (rq_cmd == 8'h10) start_chip_erase();
					else if (rq_cmd == 8'h30) start_sector_erase();
				end
				C_BEXIT: begin
					cseq <= C_IDLE;
					if (rq_cmd == 8'h00) begin
						bypass <= 1'b0;
						mode   <= M_READ;
					end
				end
				default: cseq <= C_IDLE;
			endcase
		end
	endtask

	always_ff @(posedge clk) begin
		bus_ack <= 1'b0;

		// ---- the sector bit a command named a clock ago ----
		sector_bits();

		// ---- bus requests ----
		if (bus_req && !bus_ack && !b_wait) begin
			if (!alive) begin
				bus_rdata <= 16'hFFFF;
				bus_ack   <= 1'b1;
			end else if (bus_we) begin
				bus_write();
				bus_ack <= 1'b1;
			end else if (prog_status) begin
				bus_rdata <= status(~p_data[7], tog6, p_state == P_FAIL, 1'b0, 1'b1);
				tog6      <= ~tog6;
				bus_ack   <= 1'b1;
			end else if (erase_status) begin
				bus_rdata <= status(1'b0, tog6, 1'b0, e_state == E_RUN, rq_sel ? tog2 : 1'b1);
				tog6      <= ~tog6;
				if (rq_sel) tog2 <= ~tog2;
				bus_ack   <= 1'b1;
			end else if (susp_status) begin
				bus_rdata <= status(1'b1, tog6, 1'b0, 1'b1, tog2);
				tog2      <= ~tog2;
				bus_ack   <= 1'b1;
			end else if (mode == M_AUTO) begin
				bus_rdata <= autoselect(bus_addr[7:0], rq_lock);
				bus_ack   <= 1'b1;
			end else if (mode == M_CFI) begin
				bus_rdata <= {8'h00, cfi(bus_addr[7:0])};
				bus_ack   <= 1'b1;
			end else begin
				b_wait <= 1'b1;
				b_addr <= bus_addr;
			end
		end

		// ---- the program engine's busy time ----
		if (p_state == P_RUN) begin
			if (p_timer != 32'd0) p_timer <= p_timer - 32'd1;
			if (p_step == 2'd2 && p_timer == 32'd0)
				p_state <= (PROGRAM_FAIL_DQ5 && (p_old & p_data) != p_data) ? P_FAIL : P_IDLE;
		end

		// ---- the erase engine ----
		case (e_state)
			E_WINDOW: begin
				if (bus_wr_now) ;               // bus_write() decides
				else if (e_timer == 32'd0) e_state <= E_RUN;
				else e_timer <= e_timer - 32'd1;
			end
			E_RUN: begin
				case (e_step)
					S_FIND: begin
						if (e_sector == NSECT_S) begin
							e_state  <= E_IDLE;
							sel      <= '0;
							bank_sel <= '0;
						end else if (sel[e_sector]) begin
							e_ptr   <= sector_base(e_sector);
							e_left  <= is_small(e_sector) ? 16'd4096 : 16'd32768;
							e_timer <= 32'(SECTOR_ERASE_CLKS);
							e_step  <= S_WRITE;
						end else begin
							e_sector <= e_sector + 1'd1;
						end
					end
					default: begin
						if (e_timer != 32'd0) e_timer <= e_timer - 32'd1;
						if (e_step == S_WAIT && e_timer == 32'd0) begin
							e_sector <= e_sector + 1'd1;
							e_step   <= S_FIND;
						end
					end
				endcase
			end
			default: ;
		endcase

		// ---- the memory port ----
		if (!m_active) begin
			if (b_wait) begin
				m_active  <= 1'b1;
				m_src     <= SRC_BUS;
				mem_req   <= 1'b1;
				mem_we    <= 1'b0;
				mem_addr  <= b_addr;
			end else if (p_state == P_RUN && p_step != 2'd2) begin
				m_active  <= 1'b1;
				m_src     <= SRC_PROG;
				mem_req   <= 1'b1;
				mem_we    <= p_step == 2'd1;
				mem_addr  <= p_addr;
				mem_wdata <= p_old & p_data;
			end else if (e_state == E_RUN && e_step == S_WRITE && e_left != 16'd0) begin
				m_active  <= 1'b1;
				m_src     <= SRC_ERASE;
				mem_req   <= 1'b1;
				mem_we    <= 1'b1;
				mem_addr  <= e_ptr;
				mem_wdata <= 16'hFFFF;
			end
		end else if (mem_ack) begin
			m_active <= 1'b0;
			mem_req  <= 1'b0;
			m_stale  <= 1'b0;
			if (!m_stale) begin
				case (m_src)
					SRC_BUS: begin
						bus_rdata <= mem_rdata;
						bus_ack   <= 1'b1;
						b_wait    <= 1'b0;
					end
					SRC_PROG: begin
						if (p_step == 2'd0) begin
							p_old  <= mem_rdata;
							p_step <= 2'd1;
						end else begin
							p_step <= 2'd2;
						end
					end
					default: begin
						e_ptr  <= e_ptr + 1'd1;
						e_left <= e_left - 16'd1;
						if (e_left == 16'd1) e_step <= S_WAIT;
					end
				endcase
			end
		end

		// ---- reset: stop everything; a memory access in flight finishes ----
		if (!alive) begin
			mode     <= M_READ;
			cseq     <= C_IDLE;
			bypass   <= 1'b0;
			p_state  <= P_IDLE;
			e_state  <= E_IDLE;
			sel      <= '0;
			bank_sel <= '0;
			lock     <= {NSECT{LOCKED_AT_RESET}};
			sec_set_q  <= 1'b0;
			lock_set_q <= 1'b0;
			b_wait   <= 1'b0;
			if (m_active && !mem_ack) m_stale <= 1'b1;
		end
		if (reset) begin
			m_active <= 1'b0;
			mem_req  <= 1'b0;
			m_stale  <= 1'b0;
			bus_ack  <= 1'b0;
		end
	end

endmodule
