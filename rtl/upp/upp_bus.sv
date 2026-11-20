// SPDX-License-Identifier: GPL-2.0-or-later
//
// The UPP_WD2's memory map as the ARM sees it: a Wishbone B3 slave for the
// CPU (ZAP: classic cycles with SEL for uncached accesses, CTI/BTE bursts
// for cache line fills and write-backs) that decodes the physical address
// and serves each target:
//
//   0x00000000  CS0 NOR flash, 16 MB (mirrored in its 32 MB window)  nor_flash
//   0x02000000  CS1 NOR flash, 8 MB (mirrored)                       nor_flash
//   0x04000000  CS2 NOR flash on NEM-4; QD CS2 and both CS3 windows are empty
//   0x08000000  memory controller (EMIF) registers: plain storage,
//               2^EMIF_WORDS_LOG2 words, mirrored
//   0x0A000000  SDRAM, 16 MB (mirrored in its 32 MB window)          sdram
//   0x0C000000  ASIC ROM page, the v5 Thumb-return model
//   0x0C001000  on-chip RAM through 0x0C0FFFFF, backed by SDRAM above 16 MB;
//               distinct offsets include NOS comm RAM and both DSP uploads
//   0x0C100000  MDI rings through 0x0C1003E7, backed by SDRAM above on-chip RAM
//   0x0C1003E8  peripheral register bus, up to 0x0DFFFFFF (0x0C1xxxxx, the
//               0x0D000000 window and the STI trace window at 0x0DE00000)
//   elsewhere   unmapped: reads UNMAPPED_DATA (or an ERR with UNMAPPED_ERR)
//
// Wishbone: wb_ack, wb_err and wb_dat_o are registers. A beat is answered
// at the earliest a clock after it is seen; the clock in which ack is high
// shows the beat being answered, and the next beat may follow at once. An
// incrementing burst (CTI 010, BTE linear or wrap 4/8/16) promises the next
// beat's address, so the targets fetch it ahead:
//   * EMIF and ASIC ROM reads: a beat every clock after the first (2 clocks);
//   * SDRAM read: a burst is one line read (16 bytes, the asked word first),
//     a classic read one word; beats are answered as their words arrive (the
//     first 9 clocks after the beat is seen, then every 2 clocks); a burst
//     that runs on past the 16 bytes reads the next line. A line fill (a
//     wrap-4 burst) is read as a pair: the row's next 16 bytes come in the
//     same SDRAM read, eight clocks behind, and wait in the read-ahead
//     line. A fill that asks for them is answered from it (the first beat
//     2 clocks after it is seen, then one every clock) without an SDRAM
//     access. A write that may be to those 16 bytes drops them, and a read
//     of anything else that comes while they are still arriving cuts the
//     pair short, so that it waits no longer than after a line read;
//   * SDRAM write: posted. A classic write is answered as soon as the
//     request register is free; a burst's beats are gathered (a beat every
//     2 clocks) into one line write with byte enables;
//   * flash: in read-array mode (fl*_array), a read burst is one 16-byte line
//     read (two 8-byte beats from the chip's wide port, the asked 8-byte beat
//     first on a cache hit), answered as the words arrive (a cached line in 8
//     clocks, the first beat in 4); every other access uses the 16-bit bus
//     port (one or two halfword accesses per beat, only the halfwords SEL
//     asks for; during a status/query burst the next beat is read while the
//     current one waits, never past the burst's end or the chip's window);
//   * peripherals: one access a beat; EMIF writes: answered the clock after.
//
// Peripheral register bus (for the UPP peripheral models): p_sel rises with
// p_addr (the physical byte address, bits 27:0), p_we, p_be and p_wdata, and
// stays up until the first clock edge at which p_wait is low; that edge
// completes the access, and p_rdata is taken then. p_sel is low for at least
// one clock between accesses.
//
// idle is high in the clocks the bus is between transactions (it then takes
// a new one from whichever master is on the port; ngage_mem's arbiter changes
// masters only then). After a beat with CTI other than 010 has been answered,
// the bus is idle in the following clock.
//
// SDRAM port: see rtl/mem/sdram.sv. Flash ports: nor_flash's bus port (a
// request is held until the clock in which ack is high).
//
// Unknowns include the full physical on-chip RAM layout, what an empty chip
// select and an unmapped address read
// (EMPTY_DATA and UNMAPPED_DATA: 0, as in the model), whether unmapped
// accesses abort (UNMAPPED_ERR), the EMIF block's size, and the mirroring of
// the flash, SDRAM and RAM windows.
module upp_bus #(
	parameter int          EMIF_WORDS_LOG2 = 6,
	parameter logic [31:0] EMPTY_DATA      = 32'h0000_0000,
	parameter logic [31:0] UNMAPPED_DATA   = 32'h0000_0000,
	parameter bit          UNMAPPED_ERR    = 1'b0,
	parameter int          CS0_AW          = 23,
	parameter int          CS1_AW          = 22
) (
	input  logic              clk,
	input  logic              reset,
	input  logic              nem4,

	input  logic              wb_cyc,
	input  logic              wb_stb,
	input  logic              wb_we,
	input  logic [31:0]       wb_adr,
    input  logic [31:0]       decode_cpu_adr,
    input  logic [31:0]       decode_dma_adr,
    input  logic              decode_dma_owner,
	input  logic [31:0]       wb_dat_i,
	input  logic [3:0]        wb_sel,
	input  logic [2:0]        wb_cti,
	input  logic [1:0]        wb_bte,
	output logic              wb_ack,
	output logic              wb_err,
	// First-ACK attribute for one 16-byte wrap-4 READ burst. Once true,
	// every remaining beat is guaranteed not to ERR. Sample only with ACK.
	output logic              wb_no_late_error,
	output logic [31:0]       wb_dat_o,

	output logic              fl0_req,
	output logic              fl0_we,
	output logic [CS0_AW-1:0] fl0_addr,
	output logic [15:0]       fl0_wdata,
	input  logic [15:0]       fl0_rdata,
	input  logic              fl0_ack,
	input  logic              fl0_array,
	output logic              fl0_lreq,
	output logic [CS0_AW-1:2] fl0_laddr,
	input  logic              fl0_ltaken,
	input  logic              fl0_lrvalid,
	input  logic              fl0_lrbeat,
	input  logic [63:0]       fl0_lrdata,

	output logic              fl1_req,
	output logic              fl1_we,
	output logic [CS1_AW-1:0] fl1_addr,
	output logic [15:0]       fl1_wdata,
	input  logic [15:0]       fl1_rdata,
	input  logic              fl1_ack,
	input  logic              fl1_array,
	output logic              fl1_lreq,
	output logic [CS1_AW-1:2] fl1_laddr,
	input  logic              fl1_ltaken,
	input  logic              fl1_lrvalid,
	input  logic              fl1_lrbeat,
	input  logic [63:0]       fl1_lrdata,

	output logic              fl2_req,
	output logic              fl2_we,
	output logic [CS1_AW-1:0] fl2_addr,
	output logic [15:0]       fl2_wdata,
	input  logic [15:0]       fl2_rdata,
	input  logic              fl2_ack,
	input  logic              fl2_array,
	output logic              fl2_lreq,
	output logic [CS1_AW-1:2] fl2_laddr,
	input  logic              fl2_ltaken,
	input  logic              fl2_lrvalid,
	input  logic              fl2_lrbeat,
	input  logic [63:0]       fl2_lrdata,

	output logic              sdr_req,
	output logic              sdr_we,
	output logic              sdr_line,
	output logic              sdr_pair,
	output logic [24:2]       sdr_addr,
	output logic [127:0]      sdr_wdata,
	output logic [15:0]       sdr_wbe,
	input  logic              sdr_busy,
	input  logic              sdr_ready,      // low while the controller starts (again): nothing it was doing comes back
	input  logic              sdr_rvalid,
	input  logic [1:0]        sdr_rword,
	input  logic              sdr_rsecond,
	input  logic              sdr_rdrop,
	input  logic [31:0]       sdr_rdata,

	output logic              p_sel,
	output logic              p_we,
	output logic [27:0]       p_addr,
	output logic [31:0]       p_wdata,
	output logic [3:0]        p_be,
	input  logic [31:0]       p_rdata,
	input  logic              p_wait,

	output logic              unmapped,    // a pulse for each unmapped access
	output logic              idle         // between transactions (for an arbiter in front)
);

	localparam logic [31:0] ASIC_ROM_RETURN = 32'h4770_4770;
	localparam logic [2:0] CTI_INCR = 3'b010;
	localparam int FL_AW = (CS0_AW > CS1_AW) ? CS0_AW : CS1_AW;

	// ------------------------------------------------------------------
	// Decoding
	// ------------------------------------------------------------------
	typedef enum logic [3:0] {
		T_UNMAPPED,
		T_EMPTY,
		T_CS0,
		T_CS1,
		T_CS2,
		T_EMIF,
		T_SDRAM,
		T_ONCHIP,
		T_PERIPH,
		T_ASIC_ROM
	} tgt_t;

	function automatic tgt_t decode(input logic [31:0] a);
		if (a[31:28] != 4'h0) return T_UNMAPPED;
		case (a[27:25])
			3'd0: return T_CS0;
			3'd1: return T_CS1;
			3'd2: return nem4 ? T_CS2 : T_EMPTY;
			3'd3: return T_EMPTY;
			3'd4: return T_EMIF;
			3'd5: return T_SDRAM;
			3'd6: begin
				if (a[24:10] == 15'h0400 && a[9:0] < 10'h3E8) return T_ONCHIP;
				if (a[24:20] != 5'd0) return T_PERIPH;
				return (a[19:12] == 8'd0) ? T_ASIC_ROM : T_ONCHIP;
			end
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

	// nxt(nxt(a)) with one adder (it is on the block RAMs' read address path)
	function automatic logic [31:0] nxt2(input logic [31:0] a, input logic [1:0] bte);
		case (bte)
			2'b01: return {a[31:4], a[3:2] + 2'd2, 2'b00};
			2'b10: return {a[31:5], a[4:2] + 3'd2, 2'b00};
			2'b11: return {a[31:6], a[5:2] + 4'd2, 2'b00};
			default: return {a[31:2] + 30'd2, 2'b00};
		endcase
	endfunction

	// the SDRAM module's word address of a guest address
	function automatic logic [24:2] sdr_word(input logic [31:0] a, input logic oc);
		logic [24:0] b;
		if (oc) b = {4'b1000, a[20:0]};
		else    b = {1'b0, a[23:0]};
		return b[24:2];
	endfunction

	tgt_t      tgt;
    (* keep *) wire [3:0] cpu_target = decode(decode_cpu_adr);
    (* keep *) wire [3:0] dma_target = decode(decode_dma_adr);
    assign tgt = tgt_t'(decode_dma_owner ? dma_target : cpu_target);
    // synthesis translate_off
    always @(posedge clk) if (!reset)
        assert (tgt == decode(wb_adr))
            else $fatal(1, "UPP predecode disagrees with selected address");
    // synthesis translate_on
	wire       is_sdr  = tgt == T_SDRAM || tgt == T_ONCHIP;
	wire       burst   = wb_cti == CTI_INCR;
	wire [31:0] adr_n  = nxt(wb_adr, wb_bte);
	wire [31:0] adr_nn = nxt2(wb_adr, wb_bte);

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------
	typedef enum logic [2:0] {
		S_IDLE,
		S_ACK,       // the clock of a single beat's ack
		S_RAM,       // EMIF or ASIC ROM read
		S_SDR_RD,
		S_SDR_WR,    // gathering a write burst
		S_FLASH,
		S_FLASH_LINE,
		S_PERIPH
	} state_t;

	state_t      state = S_IDLE;
	logic        ack_q = 1'b0, err_q = 1'b0;
	logic [31:0] dat_q;

	assign wb_ack   = ack_q;
	assign wb_err   = err_q;
	logic no_late_error_q;
	assign wb_no_late_error = no_late_error_q;
	// synthesis translate_off
	always @(posedge clk)
		if (!reset && (ack_q || err_q) && no_late_error_q)
			assert (!err_q) else $fatal(1, "Guaranteed memory target returned ERR");
	// synthesis translate_on
	assign wb_dat_o = dat_q;
	assign idle     = state == S_IDLE;

	// the beat whose data is wanted next, and whether there is one: in a
	// clock with ack high the bus shows the beat being answered
	wire [31:0] tb    = ack_q ? adr_n : wb_adr;
	wire        tb_ok = wb_cyc && (!ack_q || burst);

	// ------------------------------------------------------------------
	// EMIF registers and the read-only ASIC ROM response
	// ------------------------------------------------------------------
	logic        ram_emif;               // the read in S_RAM is of the EMIF block
	wire  [31:0] ram_raddr = (state == S_IDLE) ? wb_adr : (ack_q ? adr_nn : adr_n);
	wire         ram_we    = state == S_IDLE && wb_cyc && wb_stb && wb_we && tgt == T_EMIF;
	logic [31:0] emif_q;

	bram32 #(.AW(EMIF_WORDS_LOG2)) emif (
		.clk(clk),
		.we(ram_we),
		.be(wb_sel),
		.waddr(wb_adr[2 +: EMIF_WORDS_LOG2]),
		.wdata(wb_dat_i),
		.raddr(ram_raddr[2 +: EMIF_WORDS_LOG2]),
		.rdata(emif_q)
	);

	wire [31:0] ram_q = ram_emif ? emif_q : ASIC_ROM_RETURN;

	// ------------------------------------------------------------------
	// SDRAM: one request register; read words land in the line buffer
	// ------------------------------------------------------------------
	logic [31:0] lb [4];
	logic [3:0]  lb_v;
	logic [27:0] blk;                    // the block (bus address 31:4) being read or gathered
	logic        blk_oc;                 // ... in the on-chip RAM's SDRAM copy
	logic [3:0]  rd_pend = 4'd0;         // read words still to come
	wire         sdr_free = !sdr_req;

	// The read-ahead line: the second 16 bytes of a pair read, as the SDRAM
	// held them when they were read. Requests are carried out in order and a
	// read is only asked for with no write waiting, so they stay true until
	// a later write to their block, and any write beat on the bus that may
	// be to it (its address as either mapping into the module would place
	// it, whatever it is decoded as) drops the line. A read is asked for
	// with no word outstanding (rd_pend), or, for anything but the line
	// itself, with only words of a pair's second block outstanding: the
	// controller then cuts the pair short and the line is dropped, as it is
	// when a refresh cuts the pair short (sdr_rdrop). So a live line is
	// whole whenever rd_pend is 0, and it is only used then.
	logic [31:0] pb [4];
	logic [24:4] pb_addr;                // its block in the module
	logic        pb_live = 1'b0;
	wire [24:2]  rd_word = sdr_word(wb_adr, tgt == T_ONCHIP);
	wire         line_rd = burst && wb_bte == 2'b01;               // a cache line fill
	wire         pb_hit  = line_rd && pb_live && rd_word[24:4] == pb_addr;
	wire         pair_ok = line_rd && wb_adr[9:4] != 6'h3F;      // the row has a next block
	wire         lb_in   = sdr_rvalid && !sdr_rsecond;             // a word for the line buffer
	wire         pb_wr   = is_sdr && rd_word[24:4] == pb_addr;
	// the words still to come are all of a pair's second block
	wire         rd_tail = sdr_pair && rd_pend <= 4'd4;
	wire         rd_go   = sdr_free && (rd_pend == 4'd0 || (rd_tail && !pb_hit));

	// tb's block test, word index and next block without nxt's adder on the
	// bus address. In a clock with ack high the bus shows the beat being
	// answered, which came from blk's line buffer, so wb_adr[31:4] == blk;
	// nxt(wb_adr) then stays in blk exactly when it does not cross the
	// block's end (bits 3:2 at 3 in a burst that is not wrap-4), and the
	// block it crosses into is blk's successor in the burst's order.
	wire        tb_cross  = wb_bte != 2'b01 && wb_adr[3:2] == 2'b11;
	wire        tb_in_blk = ack_q ? !tb_cross : wb_adr[31:4] == blk;
	wire [1:0]  tb_idx    = wb_adr[3:2] + {1'b0, ack_q};
	wire [27:0] blk_next  = wb_bte == 2'b10 ? {blk[27:1], ~blk[0]} :
	                        wb_bte == 2'b11 ? {blk[27:2], blk[1:0] + 2'd1} : blk + 28'd1;
	wire [31:0] tb_start  = ack_q ? {blk_next, 4'b0000} : wb_adr;   // tb, where a new block starts
	wire        tb_have   = lb_v[tb_idx] || (lb_in && sdr_rword == tb_idx);
	wire [31:0] tb_word   = (lb_in && sdr_rword == tb_idx) ? sdr_rdata : lb[tb_idx];
`ifndef SYNTHESIS
	always_ff @(posedge clk) if (!reset && state == S_SDR_RD && tb_ok) begin
		if (ack_q) assert (wb_adr[31:4] == blk) else $fatal(1, "upp_bus: an answered SDRAM beat outside blk");
		assert (tb_in_blk == (tb[31:4] == blk)) else $fatal(1, "upp_bus: tb_in_blk");
		assert (tb_idx == tb[3:2]) else $fatal(1, "upp_bus: tb_idx");
		if (!tb_in_blk) assert (tb_start == tb) else $fatal(1, "upp_bus: tb_start");
	end
`endif

	// ------------------------------------------------------------------
	// Flash: the halfword engine and a two-word queue of read beats
	// ------------------------------------------------------------------
	logic        fl_req = 1'b0;          // a halfword access is out
	logic [1:0]  fl_chip;
	logic        fl_we;
	logic [FL_AW-1:0] fl_ha;             // halfword address in the chip
	logic [15:0] fl_wdata;
	logic        fe_we_op;               // the flash transaction is a write
	logic [31:0] fe_adr;                 // the beat the engine works on
	logic [31:0] fe_prev;                // the beat before it in its burst
	logic [15:0] fe_wd_hi;               // its high write halfword
	logic        fe_hi;                  // the access out is the high halfword
	logic        fe_need_hi;             // the high halfword follows the low
	logic [15:0] fe_lo;
	logic [31:0] fe_next;                // the next beat of the burst to read
	logic        fw_v = 1'b0, fq_v = 1'b0;   // queue: fw (head), fq
	logic [31:0] fw_dat, fw_adr, fq_dat, fq_adr;
	logic [31:0] fw_prev, fq_prev;       // the beat before each in its burst

	wire [15:0] fl_rdata = fl_chip == 2'd2 ? fl2_rdata : fl_chip == 2'd1 ? fl1_rdata : fl0_rdata;
	wire        fl_ack   = fl_req && (fl_chip == 2'd2 ? fl2_ack : fl_chip == 2'd1 ? fl1_ack : fl0_ack);
	wire        fe_last  = fl_ack && !(!fe_hi && fe_need_hi);   // the beat's last halfword is taken
	// the finished word; halves not read are 0
	wire [31:0] fe_word  = fe_hi ? {fl_rdata, fe_need_hi ? fe_lo : 16'h0000} : {16'h0000, fl_rdata};

	assign fl0_req   = fl_req && fl_chip == 2'd0;
	assign fl1_req   = fl_req && fl_chip == 2'd1;
	assign fl0_we    = fl_we;
	assign fl1_we    = fl_we;
	assign fl0_addr  = fl_ha[CS0_AW-1:0];
	assign fl1_addr  = fl_ha[CS1_AW-1:0];
	assign fl0_wdata = fl_wdata;
	assign fl1_wdata = fl_wdata;
	assign fl2_req   = fl_req && fl_chip == 2'd2;
	assign fl2_we    = fl_we;
	assign fl2_addr  = fl_ha[CS1_AW-1:0];
	assign fl2_wdata = fl_wdata;

	// a read beat is answered from the head of the queue: the head is tb.
	// In a clock with ack high tb is nxt(wb_adr), and as nxt is one-to-one
	// that is "the beat before the head is wb_adr": no adder on this path.
	// (The head has a beat before it then: the first beat of a transaction
	// is popped in a clock with ack low.)
	wire fl_pop  = state == S_FLASH && !fe_we_op && tb_ok && fw_v && (ack_q ? fw_prev : fw_adr) == wb_adr;
	wire fl_push = fe_last && !fl_we;
	// fq is in use after this edge
	wire fq_next = fl_push ? (fl_pop ? fq_v : fw_v) : (fl_pop ? 1'b0 : fq_v);
	// the engine reads ahead the beat that is on the bus or promised by it,
	// when it is free (or frees now) and the queue will have room
	// (fe_next is nxt(fe_adr) with the burst's BTE, and nxt is one-to-one, so
	// "fe_next is the beat after the bus's" is fe_adr == wb_adr: no adder on
	// this path)
	wire fe_allowed = wb_cyc && (fe_next == wb_adr || (fe_adr == wb_adr && burst)) &&
	                  fe_next[31:27] == 5'd0 && fe_next[26:25] == fl_chip;
	wire fe_ahead   = state == S_FLASH && !fe_we_op && fe_allowed && (!fl_req || fe_last) && !fq_next;

	// Flash wide line read (16-byte line = two 64-bit beats in read-array mode)
	logic              fl_lreq = 1'b0;
	logic [1:0]        fl_lchip;
	logic [FL_AW-1:2]  fl_laddr;
	logic [31:0]       fl_lb [4];
	logic [3:0]        fl_lb_v;
	logic [1:0]        fl_lpend = 2'd0;
	logic [1:0]        fl_widx;
	logic              fl_in_blk;
	logic              fl_wrap4;

	wire               fl_lfree   = !fl_lreq && fl_lpend == 2'd0;
	wire               fl_ltaken  = fl_lreq && (fl_lchip == 2'd2 ? fl2_ltaken : fl_lchip == 2'd1 ? fl1_ltaken : fl0_ltaken);
	wire               fl_lrvalid = fl_lchip == 2'd2 ? fl2_lrvalid : fl_lchip == 2'd1 ? fl1_lrvalid : fl0_lrvalid;
	wire               fl_lrbeat  = fl_lchip == 2'd2 ? fl2_lrbeat : fl_lchip == 2'd1 ? fl1_lrbeat : fl0_lrbeat;
	wire [63:0]        fl_lrdata  = fl_lchip == 2'd2 ? fl2_lrdata : fl_lchip == 2'd1 ? fl1_lrdata : fl0_lrdata;

	assign fl0_lreq  = fl_lreq && fl_lchip == 2'd0;
	assign fl1_lreq  = fl_lreq && fl_lchip == 2'd1;
	assign fl0_laddr = fl_laddr[CS0_AW-1:2];
	assign fl1_laddr = fl_laddr[CS1_AW-1:2];
	assign fl2_lreq  = fl_lreq && fl_lchip == 2'd2;
	assign fl2_laddr = fl_laddr[CS1_AW-1:2];

	wire        fl_hit_live = fl_lrvalid && fl_lrbeat == fl_widx[1];
	wire        fl_have     = fl_lb_v[fl_widx] || fl_hit_live;
	wire [31:0] fl_word     = fl_hit_live ? (fl_widx[0] ? fl_lrdata[63:32] : fl_lrdata[31:0])
	                                      : fl_lb[fl_widx];

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
	wire        is_flash   = tgt == T_CS0 || tgt == T_CS1 || tgt == T_CS2;
	wire [1:0]  flash_chip = tgt == T_CS0 ? 2'd0 : tgt == T_CS1 ? 2'd1 : 2'd2;
	wire        fl_line_ok = burst && !wb_we && (tgt == T_CS0 ? fl0_array : tgt == T_CS1 ? fl1_array : fl2_array);
	wire        fs_go      = (state == S_IDLE && wb_cyc && wb_stb && is_flash &&
	                          fl_lfree && !fl_line_ok) || fe_ahead;
	wire [31:0] fs_adr = (state == S_IDLE) ? wb_adr : fe_next;
	wire [1:0]  fs_h   = (state == S_IDLE) ? halves(wb_sel, burst && !wb_we) : 2'b11;
	wire        fs_we  = (state == S_IDLE) && wb_we;

	always_ff @(posedge clk) begin
		unmapped <= 1'b0;

		// SDRAM: the request is taken at an edge where it is up and the
		// controller is not busy; read words fill the line buffer
		if (sdr_req && !sdr_busy) sdr_req <= 1'b0;
		// a read that is taken leaves no word of a pair before it to come,
		// nor does a refresh that cut the pair short
		if (sdr_req && !sdr_busy && !sdr_we) rd_pend <= sdr_line ? (sdr_pair ? 4'd8 : 4'd4) : 4'd1;
		else if (sdr_rdrop) rd_pend <= 4'd0;
		else if (sdr_rvalid && rd_pend != 4'd0) rd_pend <= rd_pend - 4'd1;
		// (with a read waiting, the line is already that read's or dropped)
		if (sdr_rdrop && !(sdr_req && !sdr_we)) pb_live <= 1'b0;
		if (lb_in) begin
			lb[sdr_rword]   <= sdr_rdata;
			lb_v[sdr_rword] <= 1'b1;
		end
		if (sdr_rvalid && !lb_in) pb[sdr_rword] <= sdr_rdata;

		// flash: wide line read in read-array mode
		if (fl_ltaken) fl_lreq <= 1'b0;
		if (!fl_lreq)  fl_laddr <= wb_adr[FL_AW:3];
		fl_lpend <= fl_lpend + ((state == S_IDLE && wb_cyc && wb_stb &&
		                         is_flash && fl_lfree && fl_line_ok) ? 2'd2 : 2'd0)
		                     - ((fl_lrvalid && fl_lpend != 2'd0) ? 2'd1 : 2'd0);
		if (fl_lrvalid) begin
			fl_lb[{fl_lrbeat, 1'b0}]   <= fl_lrdata[31:0];
			fl_lb[{fl_lrbeat, 1'b1}]   <= fl_lrdata[63:32];
			fl_lb_v[{fl_lrbeat, 1'b0}] <= 1'b1;
			fl_lb_v[{fl_lrbeat, 1'b1}] <= 1'b1;
		end

		// flash: the halfword engine. The halfword address is loaded with the
		// next beat's in every clock in which no access is out or one ends
		// (it matters only once fl_req is up), so the target decode and the
		// engine's decisions are not on its path.
		if (!fl_req || fl_ack) fl_ha <= {fs_adr[FL_AW:2], !fs_h[0]};
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
				if (!fw_v) begin fw_v <= 1'b1; fw_dat <= fe_word; fw_adr <= fe_adr; fw_prev <= fe_prev; end
				else begin fq_v <= 1'b1; fq_dat <= fe_word; fq_adr <= fe_adr; fq_prev <= fe_prev; end
			end
			2'b01: begin
				fw_v   <= fq_v;
				fw_dat <= fq_dat;
				fw_adr <= fq_adr;
				fw_prev <= fq_prev;
				fq_v   <= 1'b0;
			end
			2'b11: begin
				if (fq_v) begin
					fw_dat <= fq_dat; fw_adr <= fq_adr; fw_prev <= fq_prev;
					fq_dat <= fe_word; fq_adr <= fe_adr; fq_prev <= fe_prev;
				end else begin
					fw_dat <= fe_word; fw_adr <= fe_adr; fw_prev <= fe_prev;
				end
			end
			default: ;
		endcase
		// SDRAM write data: the controller latches it when it takes the
		// request, so with none waiting the bus's word is taken in every idle
		// clock, whatever the target (off the decode's path)
		if (state == S_IDLE && sdr_free) sdr_wdata[32 * wb_adr[3:2] +: 32] <= wb_dat_i;
		// write data: only a transaction's first beat (from S_IDLE) can be a
		// write, so it is taken from the bus in every idle clock with no
		// halfword access out, whatever the target (off the decode's path)
		if (state == S_IDLE && !fl_req) begin
			fe_wd_hi <= wb_dat_i[31:16];
			fl_wdata <= (wb_sel[1:0] != 2'b00 || wb_sel == 4'b0000) ? wb_dat_i[15:0] : wb_dat_i[31:16];
		end
		if (fs_go) begin
			fl_req     <= 1'b1;
			fl_we      <= fs_we;
			fe_adr     <= fs_adr;
			fe_prev    <= fe_adr;            // fs_adr = nxt(fe_adr) when it matters
			fe_hi      <= !fs_h[0];
			fe_need_hi <= fs_h[0] && fs_h[1];
			fe_next    <= nxt(fs_adr, wb_bte);
		end

		case (state)
			S_IDLE: begin
				if (wb_cyc && wb_stb) begin
					// Registered with target acceptance, ahead of its first ACK.
					// A wrap-4 fill cannot cross a decode boundary. RAM and
					// ASIC ROM reads have no ERR return channel. The flash wide
					// array port also has none (DDR3 wait/data-valid only).
					// Command/status/query/program/erase accesses, EMIF,
					// peripherals, empty CS and unmapped targets stay gated.
					// Flash mode is sampled here, before its line read makes
					// bus_array go low; no other bus master can change modes
					// during the accepted burst. Reset cancels the CPU too.
					no_late_error_q <= !wb_we && burst && wb_bte == 2'b01 &&
					    wb_sel == 4'hf &&
					    (is_sdr || tgt == T_ASIC_ROM ||
					     (is_flash && fl_line_ok));
					case (tgt)
						T_UNMAPPED, T_EMPTY: begin
							dat_q    <= (tgt == T_EMPTY) ? EMPTY_DATA : UNMAPPED_DATA;
							ack_q    <= !(UNMAPPED_ERR && tgt == T_UNMAPPED);
							err_q    <= UNMAPPED_ERR && tgt == T_UNMAPPED;
							unmapped <= tgt == T_UNMAPPED;
							state    <= S_ACK;
						end
						T_CS0, T_CS1, T_CS2: begin
							if (fl_lfree) begin
								fl_chip  <= flash_chip;
								fl_lchip <= flash_chip;
								if (fl_line_ok) begin
									fl_lreq   <= 1'b1;
									fl_lb_v   <= 4'b0000;
									fl_widx   <= wb_adr[3:2];
									fl_in_blk <= 1'b1;
									fl_wrap4  <= wb_bte == 2'b01;
									state     <= S_FLASH_LINE;
								end else begin
									fe_we_op <= wb_we;
									fw_v     <= 1'b0;
									fq_v     <= 1'b0;
									state    <= S_FLASH;
								end
							end
						end
						T_PERIPH: begin
							p_sel_q <= 1'b1;
							p_we    <= wb_we;
							p_addr  <= wb_adr[27:0];
							p_wdata <= wb_dat_i;
							p_be    <= wb_sel;
							state   <= S_PERIPH;
						end
						T_ASIC_ROM: begin
							ram_emif <= 1'b0;
							err_q <= wb_we;
							state <= wb_we ? S_ACK : S_RAM;
						end
						default: begin
							if (tgt == T_EMIF) begin
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
								if (rd_go) begin
									blk      <= wb_adr[31:4];
									blk_oc   <= tgt == T_ONCHIP;
									sdr_we   <= 1'b0;
									state    <= S_SDR_RD;
									if (pb_hit) begin
										// the read-ahead line is this fill
										for (int i = 0; i < 4; i++) lb[i] <= pb[i];
										lb_v <= 4'b1111;
									end else begin
										lb_v     <= 4'b0000;
										sdr_req  <= 1'b1;
										sdr_line <= burst;
										sdr_pair <= pair_ok;
										sdr_addr <= rd_word;
										if (pair_ok) begin
											pb_addr <= rd_word[24:4] + 21'd1;
											pb_live <= 1'b1;
										end else if (rd_pend != 4'd0) begin
											pb_live <= 1'b0;       // cut short
										end
									end
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
				// A linear read can leave the ASIC page and continue in SDRAM.
				if (!tb_ok || (!ram_emif && tb[12])) begin
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
				end else if (sdr_free && rd_pend == 4'd0) begin
					// the burst runs on into the next block
					blk      <= tb_start[31:4];
					lb_v     <= 4'b0000;
					sdr_req  <= 1'b1;
					sdr_line <= 1'b1;
					sdr_pair <= 1'b0;
					sdr_addr <= sdr_word(tb_start, blk_oc);
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
					if (!tb_ok || (!fl_req && !fw_v)) begin
						// the burst is over (or left this chip); let a halfword access in flight finish
						if (!fl_req || fl_ack) state <= S_IDLE;
					end else if (fl_pop) begin
						dat_q <= fw_dat;
						ack_q <= 1'b1;
					end
				end
			end

			S_FLASH_LINE: begin
				ack_q <= 1'b0;
				if (!tb_ok || !fl_in_blk) begin
					state <= S_IDLE;
				end else if (fl_have) begin
					dat_q   <= fl_word;
					ack_q   <= 1'b1;
					fl_widx <= fl_widx + 2'd1;
					if (fl_widx == 2'd3 && !fl_wrap4) fl_in_blk <= 1'b0;
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

		// a write beat that may be to the read-ahead line's block drops the line
		if (wb_cyc && wb_stb && wb_we && pb_wr) pb_live <= 1'b0;

		if (reset) begin
			pb_live  <= 1'b0;
			state    <= S_IDLE;
			ack_q    <= 1'b0;
			err_q    <= 1'b0;
			no_late_error_q <= 1'b0;
			// a write that has been answered is still carried out: the SDRAM may
			// be busy with a pair read's second block, which a write waits for
			if (!sdr_we) sdr_req <= 1'b0;
			fl_req   <= 1'b0;
			fl_lreq  <= 1'b0;
			fl_lpend <= 2'd0;
			fw_v     <= 1'b0;
			fq_v     <= 1'b0;
			p_sel_q  <= 1'b0;
		end

		// the controller starts again: no word of a read it had taken comes
		// back, and nothing is asked of it
		if (!sdr_ready) begin
			rd_pend <= 4'd0;
			sdr_req <= 1'b0;
		end
	end

endmodule
