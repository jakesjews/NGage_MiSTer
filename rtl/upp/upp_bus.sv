// SPDX-License-Identifier: GPL-2.0-or-later
//
// The UPP_WD2's memory map as the ARM sees it: a Wishbone B3 slave for the
// CPU (ZAP: classic cycles with SEL for uncached accesses, CTI/BTE bursts
// for cache line fills and write-backs) that decodes the physical address
// and serves each target:
//
//   0x00000000  CS0 NOR flash, 16 MB (mirrored in its 32 MB window)  nor_flash
//   0x02000000  CS1 NOR flash, 8 MB (mirrored)                       nor_flash
//   0x04000000  CS2, CS3: no flash on the QD; reads EMPTY_DATA, writes are dropped
//   0x08000000  memory controller (EMIF) registers: plain storage,
//               2^EMIF_WORDS_LOG2 words, mirrored
//   0x0A000000  SDRAM, 16 MB (mirrored in its 32 MB window)          sdram
//   0x0C000000  on-chip RAM, ONCHIP_BYTES (mirrored in 0x0C000000-0x0C0FFFFF);
//               block RAM, or SDRAM at ONCHIP_SDRAM_AT if larger than
//               ONCHIP_BRAM_MAX
//   0x0C100000  peripheral register bus, up to 0x0DFFFFFF (0x0C1xxxxx, the
//               0x0D000000 window and the STI trace window at 0x0DE00000)
//   elsewhere   unmapped: reads UNMAPPED_DATA (or an ERR with UNMAPPED_ERR)
//
// Wishbone: wb_ack, wb_err and wb_dat_o are registers. A beat is answered
// at the earliest a clock after it is seen; the clock in which ack is high
// shows the beat being answered, and the next beat may follow at once. An
// incrementing burst (CTI 010, BTE linear or wrap 4/8/16) promises the next
// beat's address, so the targets fetch it ahead:
//   * block RAM: a beat every clock after the first (2 clocks);
//   * SDRAM read: a burst is one line read (16 bytes, the asked word first),
//     a classic read one word; beats are answered as their words arrive (the
//     first 9 clocks after the beat is seen, then every 2 clocks); a burst
//     that runs on past the 16 bytes reads the next line;
//   * SDRAM write: posted. A classic write is answered as soon as the
//     request register is free; a burst's beats are gathered (a beat every
//     2 clocks) into one line write with byte enables;
//   * flash: 16-bit chips, so a beat is one or two halfword accesses of the
//     chip's bus port (only the halfwords SEL asks for; a burst beat both);
//     during a burst the next beat is read while the current one waits, but
//     never past the burst's end (a status read changes the chip's toggle
//     bits);
//   * peripherals: one access a beat; flash writes, EMIF and on-chip RAM
//     writes: answered the clock after.
//
// Peripheral register bus (for the UPP peripheral models): p_sel rises with
// p_addr (the physical byte address, bits 27:0), p_we, p_be and p_wdata, and
// stays up until the first clock edge at which p_wait is low; that edge
// completes the access, and p_rdata is taken then. p_sel is low for at least
// one clock between accesses.
//
// SDRAM port: see rtl/mem/sdram.sv. Flash ports: nor_flash's bus port (a
// request is held until the clock in which ack is high).
//
// Unknowns, each a parameter: the on-chip RAM size (ONCHIP_BYTES: the
// firmware's references found so far fall in 0x0C000000-0x0C005FFF, the QEMU
// model maps 256 KB), what an empty chip select and an unmapped address read
// (EMPTY_DATA and UNMAPPED_DATA: 0, as in the model), whether unmapped
// accesses abort (UNMAPPED_ERR), the EMIF block's size, and the mirroring of
// the flash, SDRAM and RAM windows.
module upp_bus #(
	parameter int          ONCHIP_BYTES    = 64 << 10,
	parameter int          ONCHIP_BRAM_MAX = 64 << 10,
	parameter logic [24:0] ONCHIP_SDRAM_AT = 25'h100_0000,
	parameter int          EMIF_WORDS_LOG2 = 6,
	parameter logic [31:0] EMPTY_DATA      = 32'h0000_0000,
	parameter logic [31:0] UNMAPPED_DATA   = 32'h0000_0000,
	parameter bit          UNMAPPED_ERR    = 1'b0,
	parameter int          CS0_AW          = 23,
	parameter int          CS1_AW          = 22
) (
	input  logic              clk,
	input  logic              reset,

	input  logic              wb_cyc,
	input  logic              wb_stb,
	input  logic              wb_we,
	input  logic [31:0]       wb_adr,
	input  logic [31:0]       wb_dat_i,
	input  logic [3:0]        wb_sel,
	input  logic [2:0]        wb_cti,
	input  logic [1:0]        wb_bte,
	output logic              wb_ack,
	output logic              wb_err,
	output logic [31:0]       wb_dat_o,

	output logic              fl0_req,
	output logic              fl0_we,
	output logic [CS0_AW-1:0] fl0_addr,
	output logic [15:0]       fl0_wdata,
	input  logic [15:0]       fl0_rdata,
	input  logic              fl0_ack,

	output logic              fl1_req,
	output logic              fl1_we,
	output logic [CS1_AW-1:0] fl1_addr,
	output logic [15:0]       fl1_wdata,
	input  logic [15:0]       fl1_rdata,
	input  logic              fl1_ack,

	output logic              sdr_req,
	output logic              sdr_we,
	output logic              sdr_line,
	output logic [24:2]       sdr_addr,
	output logic [127:0]      sdr_wdata,
	output logic [15:0]       sdr_wbe,
	input  logic              sdr_busy,
	input  logic              sdr_rvalid,
	input  logic [1:0]        sdr_rword,
	input  logic [31:0]       sdr_rdata,

	output logic              p_sel,
	output logic              p_we,
	output logic [27:0]       p_addr,
	output logic [31:0]       p_wdata,
	output logic [3:0]        p_be,
	input  logic [31:0]       p_rdata,
	input  logic              p_wait,

	output logic              unmapped     // a pulse for each unmapped access
);

	localparam bit ONCHIP_IN_SDRAM = ONCHIP_BYTES > ONCHIP_BRAM_MAX;
	localparam int OC_AW = $clog2(ONCHIP_BYTES) - 2;
	localparam logic [2:0] CTI_INCR = 3'b010;
	localparam int FL_AW = (CS0_AW > CS1_AW) ? CS0_AW : CS1_AW;

	// ------------------------------------------------------------------
	// Decoding
	// ------------------------------------------------------------------
	typedef enum logic [2:0] {
		T_UNMAPPED,
		T_EMPTY,
		T_CS0,
		T_CS1,
		T_EMIF,
		T_SDRAM,
		T_ONCHIP,
		T_PERIPH
	} tgt_t;

	function automatic tgt_t decode(input logic [31:0] a);
		if (a[31:28] != 4'h0) return T_UNMAPPED;
		case (a[27:25])
			3'd0: return T_CS0;
			3'd1: return T_CS1;
			3'd2, 3'd3: return T_EMPTY;
			3'd4: return T_EMIF;
			3'd5: return T_SDRAM;
			3'd6: return (a[24:20] == 5'd0) ? T_ONCHIP : T_PERIPH;
			default: return T_UNMAPPED;
		endcase
	endfunction

	// the address of the next beat of a burst
	function automatic logic [31:0] nxt(input logic [31:0] a, input logic [1:0] bte);
		case (bte)
			2'b01: return {a[31:4], a[3:2] + 2'd1, 2'b00};
			2'b10: return {a[31:5], a[4:2] + 3'd1, 2'b00};
			2'b11: return {a[31:6], a[5:2] + 4'd1, 2'b00};
			default: return {a[31:2] + 30'd1, 2'b00};
		endcase
	endfunction

	// the SDRAM module's word address of a guest address
	function automatic logic [24:2] sdr_word(input logic [31:0] a, input logic oc);
		logic [24:0] b;
		if (oc) b = ONCHIP_SDRAM_AT | 25'(a[$clog2(ONCHIP_BYTES)-1:0]);
		else    b = {1'b0, a[23:0]};
		return b[24:2];
	endfunction

	tgt_t      tgt;
	assign     tgt     = decode(wb_adr);
	wire       is_sdr  = tgt == T_SDRAM || (ONCHIP_IN_SDRAM && tgt == T_ONCHIP);
	wire       is_bram = tgt == T_EMIF || (!ONCHIP_IN_SDRAM && tgt == T_ONCHIP);
	wire       burst   = wb_cti == CTI_INCR;
	wire [31:0] adr_n  = nxt(wb_adr, wb_bte);
	wire [31:0] adr_nn = nxt(adr_n, wb_bte);

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------
	typedef enum logic [2:0] {
		S_IDLE,
		S_ACK,       // the clock of a single beat's ack
		S_RAM,       // block RAM read
		S_SDR_RD,
		S_SDR_WR,    // gathering a write burst
		S_FLASH,
		S_PERIPH
	} state_t;

	state_t      state = S_IDLE;
	logic        ack_q = 1'b0, err_q = 1'b0;
	logic [31:0] dat_q;

	assign wb_ack   = ack_q;
	assign wb_err   = err_q;
	assign wb_dat_o = dat_q;

	// the beat whose data is wanted next, and whether there is one: in a
	// clock with ack high the bus shows the beat being answered
	wire [31:0] tb    = ack_q ? adr_n : wb_adr;
	wire        tb_ok = wb_cyc && (!ack_q || burst);

	// ------------------------------------------------------------------
	// Block RAMs: on-chip RAM and the EMIF registers
	// ------------------------------------------------------------------
	logic        ram_emif;               // the read in S_RAM is of the EMIF block
	wire  [31:0] ram_raddr = (state == S_IDLE) ? wb_adr : (ack_q ? adr_nn : adr_n);
	wire         ram_we    = state == S_IDLE && wb_cyc && wb_stb && wb_we && is_bram;
	logic [31:0] emif_q, oc_q;

	bram32 #(.AW(EMIF_WORDS_LOG2)) emif (
		.clk(clk),
		.we(ram_we && tgt == T_EMIF),
		.be(wb_sel),
		.waddr(wb_adr[2 +: EMIF_WORDS_LOG2]),
		.wdata(wb_dat_i),
		.raddr(ram_raddr[2 +: EMIF_WORDS_LOG2]),
		.rdata(emif_q)
	);

	generate
		if (!ONCHIP_IN_SDRAM) begin : g_onchip
			bram32 #(.AW(OC_AW)) onchip (
				.clk(clk),
				.we(ram_we && tgt == T_ONCHIP),
				.be(wb_sel),
				.waddr(wb_adr[2 +: OC_AW]),
				.wdata(wb_dat_i),
				.raddr(ram_raddr[2 +: OC_AW]),
				.rdata(oc_q)
			);
		end else begin : g_no_onchip
			assign oc_q = 32'd0;
		end
	endgenerate

	wire [31:0] ram_q = ram_emif ? emif_q : oc_q;

	// ------------------------------------------------------------------
	// SDRAM: one request register; read words land in the line buffer
	// ------------------------------------------------------------------
	logic [31:0] lb [4];
	logic [3:0]  lb_v;
	logic [27:0] blk;                    // the block (bus address 31:4) being read or gathered
	logic        blk_oc;                 // ... in the on-chip RAM's SDRAM copy
	logic [2:0]  rd_pend = 3'd0;         // read words still to come
	wire         sdr_free = !sdr_req;

	wire        tb_in_blk = tb[31:4] == blk;
	wire        tb_have   = lb_v[tb[3:2]] || (sdr_rvalid && sdr_rword == tb[3:2]);
	wire [31:0] tb_word   = (sdr_rvalid && sdr_rword == tb[3:2]) ? sdr_rdata : lb[tb[3:2]];

	// ------------------------------------------------------------------
	// Flash: the halfword engine and a two-word queue of read beats
	// ------------------------------------------------------------------
	logic        fl_req = 1'b0;          // a halfword access is out
	logic        fl_chip;                // 1: CS1
	logic        fl_we;
	logic [FL_AW-1:0] fl_ha;             // halfword address in the chip
	logic [15:0] fl_wdata;
	logic        fe_we_op;               // the flash transaction is a write
	logic [31:0] fe_adr;                 // the beat the engine works on
	logic [15:0] fe_wd_hi;               // its high write halfword
	logic        fe_hi;                  // the access out is the high halfword
	logic        fe_need_hi;             // the high halfword follows the low
	logic [15:0] fe_lo;
	logic [31:0] fe_next;                // the next beat of the burst to read
	logic        fw_v = 1'b0, fq_v = 1'b0;   // queue: fw (head), fq
	logic [31:0] fw_dat, fw_adr, fq_dat, fq_adr;

	wire [15:0] fl_rdata = fl_chip ? fl1_rdata : fl0_rdata;
	wire        fl_ack   = fl_req && (fl_chip ? fl1_ack : fl0_ack);
	wire        fe_last  = fl_ack && !(!fe_hi && fe_need_hi);   // the beat's last halfword is taken
	// the finished word; halves not read are 0
	wire [31:0] fe_word  = fe_hi ? {fl_rdata, fe_need_hi ? fe_lo : 16'h0000} : {16'h0000, fl_rdata};

	assign fl0_req   = fl_req && !fl_chip;
	assign fl1_req   = fl_req && fl_chip;
	assign fl0_we    = fl_we;
	assign fl1_we    = fl_we;
	assign fl0_addr  = fl_ha[CS0_AW-1:0];
	assign fl1_addr  = fl_ha[CS1_AW-1:0];
	assign fl0_wdata = fl_wdata;
	assign fl1_wdata = fl_wdata;

	// a read beat is answered from the head of the queue
	wire fl_pop  = state == S_FLASH && !fe_we_op && tb_ok && fw_v && fw_adr == tb;
	wire fl_push = fe_last && !fl_we;
	// fq is in use after this edge
	wire fq_next = fl_push ? (fl_pop ? fq_v : fw_v) : (fl_pop ? 1'b0 : fq_v);
	// the engine reads ahead the beat that is on the bus or promised by it,
	// when it is free (or frees now) and the queue will have room
	wire fe_allowed = wb_cyc && (fe_next == wb_adr || (fe_next == adr_n && burst));
	wire fe_ahead   = state == S_FLASH && !fe_we_op && fe_allowed && (!fl_req || fe_last) && !fq_next;

	// the halfwords a beat needs
	function automatic logic [1:0] halves(input logic [3:0] sel, input logic b);
		if (b || sel == 4'b0000) return 2'b11;
		return {|sel[3:2], |sel[1:0]};
	endfunction

	// ------------------------------------------------------------------
	// Peripheral bus
	// ------------------------------------------------------------------
	logic p_sel_q = 1'b0;
	assign p_sel = p_sel_q;

	// ------------------------------------------------------------------
	// The state machine
	// ------------------------------------------------------------------
	// a beat for the engine: the first of a transaction (from S_IDLE) or the
	// next of a burst
	wire        fs_go  = (state == S_IDLE && wb_cyc && wb_stb && (tgt == T_CS0 || tgt == T_CS1)) || fe_ahead;
	wire [31:0] fs_adr = (state == S_IDLE) ? wb_adr : fe_next;
	wire [1:0]  fs_h   = (state == S_IDLE) ? halves(wb_sel, burst && !wb_we) : 2'b11;
	wire        fs_we  = (state == S_IDLE) && wb_we;

	always_ff @(posedge clk) begin
		unmapped <= 1'b0;

		// SDRAM: the request is taken at an edge where it is up and the
		// controller is not busy; read words fill the line buffer
		if (sdr_req && !sdr_busy) sdr_req <= 1'b0;
		rd_pend <= rd_pend + ((sdr_req && !sdr_busy && !sdr_we) ? (sdr_line ? 3'd4 : 3'd1) : 3'd0)
		                   - ((sdr_rvalid && rd_pend != 3'd0) ? 3'd1 : 3'd0);
		if (sdr_rvalid) begin
			lb[sdr_rword]   <= sdr_rdata;
			lb_v[sdr_rword] <= 1'b1;
		end

		// flash: the halfword engine
		if (fl_ack) begin
			if (!fe_hi && fe_need_hi) begin
				fe_lo    <= fl_rdata;
				fe_hi    <= 1'b1;
				fl_ha    <= {fe_adr[FL_AW:2], 1'b1};
				fl_wdata <= fe_wd_hi;
			end else begin
				fl_req <= 1'b0;
			end
		end
		case ({fl_push, fl_pop})
			2'b10: begin
				if (!fw_v) begin fw_v <= 1'b1; fw_dat <= fe_word; fw_adr <= fe_adr; end
				else begin fq_v <= 1'b1; fq_dat <= fe_word; fq_adr <= fe_adr; end
			end
			2'b01: begin
				fw_v   <= fq_v;
				fw_dat <= fq_dat;
				fw_adr <= fq_adr;
				fq_v   <= 1'b0;
			end
			2'b11: begin
				if (fq_v) begin
					fw_dat <= fq_dat; fw_adr <= fq_adr;
					fq_dat <= fe_word; fq_adr <= fe_adr;
				end else begin
					fw_dat <= fe_word; fw_adr <= fe_adr;
				end
			end
			default: ;
		endcase
		if (fs_go) begin
			fl_req     <= 1'b1;
			fl_we      <= fs_we;
			fe_adr     <= fs_adr;
			fe_wd_hi   <= wb_dat_i[31:16];
			fe_hi      <= !fs_h[0];
			fe_need_hi <= fs_h[0] && fs_h[1];
			fl_ha      <= {fs_adr[FL_AW:2], !fs_h[0]};
			fl_wdata   <= fs_h[0] ? wb_dat_i[15:0] : wb_dat_i[31:16];
			fe_next    <= nxt(fs_adr, wb_bte);
		end

		case (state)
			S_IDLE: begin
				if (wb_cyc && wb_stb) begin
					case (tgt)
						T_UNMAPPED, T_EMPTY: begin
							dat_q    <= (tgt == T_EMPTY) ? EMPTY_DATA : UNMAPPED_DATA;
							ack_q    <= !(UNMAPPED_ERR && tgt == T_UNMAPPED);
							err_q    <= UNMAPPED_ERR && tgt == T_UNMAPPED;
							unmapped <= tgt == T_UNMAPPED;
							state    <= S_ACK;
						end
						T_CS0, T_CS1: begin
							fl_chip  <= tgt == T_CS1;
							fe_we_op <= wb_we;
							fw_v     <= 1'b0;
							fq_v     <= 1'b0;
							state    <= S_FLASH;
						end
						T_PERIPH: begin
							p_sel_q <= 1'b1;
							p_we    <= wb_we;
							p_addr  <= wb_adr[27:0];
							p_wdata <= wb_dat_i;
							p_be    <= wb_sel;
							state   <= S_PERIPH;
						end
						default: begin
							if (is_bram) begin
								// writes go in at this edge; reads read at it
								ram_emif <= tgt == T_EMIF;
								if (wb_we) begin
									ack_q <= 1'b1;
									state <= S_ACK;
								end else begin
									state <= S_RAM;
								end
							end else if (is_sdr && wb_we) begin
								if (sdr_free) begin
									blk    <= wb_adr[31:4];
									blk_oc <= tgt == T_ONCHIP;
									sdr_we <= 1'b1;
									sdr_addr <= sdr_word(wb_adr, tgt == T_ONCHIP);
									sdr_wdata[32 * wb_adr[3:2] +: 32] <= wb_dat_i;
									sdr_wbe  <= 16'(wb_sel) << (4 * wb_adr[3:2]);
									ack_q    <= 1'b1;
									if (burst) begin
										sdr_line <= 1'b1;
										state    <= S_SDR_WR;
									end else begin
										sdr_line <= 1'b0;
										sdr_req  <= 1'b1;
										state    <= S_ACK;
									end
								end
							end else if (is_sdr) begin
								if (sdr_free && rd_pend == 3'd0) begin
									blk      <= wb_adr[31:4];
									blk_oc   <= tgt == T_ONCHIP;
									lb_v     <= 4'b0000;
									sdr_req  <= 1'b1;
									sdr_we   <= 1'b0;
									sdr_line <= burst;
									sdr_addr <= sdr_word(wb_adr, tgt == T_ONCHIP);
									state    <= S_SDR_RD;
								end
							end
						end
					endcase
				end
			end

			S_ACK: begin
				ack_q <= 1'b0;
				err_q <= 1'b0;
				state <= S_IDLE;
			end

			S_RAM: begin
				if (!tb_ok) begin
					ack_q <= 1'b0;
					state <= S_IDLE;
				end else begin
					// the first beat's word, or the next beat's, read ahead
					dat_q <= ram_q;
					ack_q <= 1'b1;
				end
			end

			S_SDR_RD: begin
				ack_q <= 1'b0;
				if (!tb_ok) begin
					state <= S_IDLE;
				end else if (tb_in_blk) begin
					if (tb_have) begin
						dat_q <= tb_word;
						ack_q <= 1'b1;
					end
				end else if (sdr_free && rd_pend == 3'd0) begin
					// the burst runs on into the next block
					blk      <= tb[31:4];
					lb_v     <= 4'b0000;
					sdr_req  <= 1'b1;
					sdr_line <= 1'b1;
					sdr_addr <= sdr_word(tb, blk_oc);
				end
			end

			S_SDR_WR: begin
				if (ack_q) begin
					// the bus shows the beat just taken
					ack_q <= 1'b0;
					if (!wb_cyc || !burst) begin
						sdr_req <= 1'b1;
						state   <= S_IDLE;
					end else if (adr_n[31:4] != blk) begin
						sdr_req <= 1'b1;            // this block is done; the next follows
					end
				end else if (!wb_cyc) begin
					if (sdr_wbe != 16'd0 && !sdr_req) sdr_req <= 1'b1;
					state <= S_IDLE;
				end else if (wb_stb && sdr_free) begin
					// the next beat
					if (wb_adr[31:4] != blk) begin
						blk      <= wb_adr[31:4];
						sdr_addr <= sdr_word(wb_adr, blk_oc);
						sdr_wbe  <= 16'(wb_sel) << (4 * wb_adr[3:2]);
					end else begin
						sdr_wbe  <= sdr_wbe | (16'(wb_sel) << (4 * wb_adr[3:2]));
					end
					for (int i = 0; i < 4; i++)
						if (wb_sel[i] || wb_adr[31:4] != blk) sdr_wdata[32 * wb_adr[3:2] + 8 * i +: 8] <= wb_dat_i[8 * i +: 8];
					ack_q <= 1'b1;
				end
			end

			S_FLASH: begin
				if (fe_we_op) begin
					// a write beat: answered when its last halfword is taken
					if (fl_ack && !(!fe_hi && fe_need_hi)) begin
						ack_q <= 1'b1;
						state <= S_ACK;
					end
				end else begin
					ack_q <= 1'b0;
					if (!tb_ok) begin
						// the burst is over; let a halfword access in flight finish
						if (!fl_req || fl_ack) state <= S_IDLE;
					end else if (fl_pop) begin
						dat_q <= fw_dat;
						ack_q <= 1'b1;
					end
				end
			end

			S_PERIPH: begin
				if (!p_wait) begin
					p_sel_q <= 1'b0;
					dat_q   <= p_rdata;
					ack_q   <= 1'b1;
					state   <= S_ACK;
				end
			end

			default: state <= S_IDLE;
		endcase

		if (reset) begin
			state   <= S_IDLE;
			ack_q   <= 1'b0;
			err_q   <= 1'b0;
			sdr_req <= 1'b0;
			fl_req  <= 1'b0;
			fw_v    <= 1'b0;
			fq_v    <= 1'b0;
			p_sel_q <= 1'b0;
		end
	end

endmodule
