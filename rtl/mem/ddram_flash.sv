// SPDX-License-Identifier: GPL-2.0-or-later
//
// The arrays of the two NOR flash chips, served from DDR3 through the
// framework's DDRAM port: the memory ports of nor_flash CS0 (16 MB image at
// 0x31000000) and CS1 (8 MB at 0x32000000), and the image loader
// (ddram_loader, writes only) on the same port.
//
// Reads go through a direct-mapped read cache in block RAM (LINES of
// 8 << LINE_LOG2 bytes, 4096 x 32 bytes = 128 KB by default, in M10K) and a one-beat
// buffer per chip in registers:
//   * the chip's last 8-byte beat answers a read in the clock it is asked
//     (sequential fetches hit it three times in four);
//   * a cache hit answers two clocks after the request;
//   * a miss reads the whole line as one DDR3 burst from its start, answers
//     when the wanted beat arrives and keeps the line;
//   * a 16-byte line read (cs0_lreq / cs1_lreq, beat address cs*_laddr) is
//     taken in S_IDLE (cs*_ltaken) and returns its two 8-byte beats on
//     cs*_lrvalid / cs*_lrbeat / cs*_lrdata (the critical 8-byte beat first
//     on a cache hit, or in burst order on a miss) and updates the beat
//     buffer.
// The ZAP I-cache sees flash only through 16-byte line fills, so this is a
// second level for execute-in-place code and the ROM file system.
//
// Writes (word program, and the 0xFFFF words of an erase) are written
// through: one DDR3 write of the halfword's two byte lanes, answered when the
// port takes it; a cached copy of the line and the beat buffer are updated.
// The DDR3 bridge serves requests in order, so a read after a write sees it.
//
// The loader's writes have the port whenever this module is not using it; a
// command left waiting by DDRAM_BUSY is presented again, unchanged, until it
// is taken (Avalon-MM). The cache is emptied (one tag a clock) after every
// reset and after any loader write, and requests wait until that is done; a
// read or write in flight when reset comes is finished on the DDR3 side but
// not answered, and a line read then is not kept.
//
// Saving CS1 (rtl/mister/flash_save.sv): every CS1 word written pulses
// mark with its 512-byte block (mark_blk). A block read (bk_req, bk_blk)
// reads that block of CS1 from DDR3 as one 64-beat burst; bk_taken pulses
// in the clock the read is issued and bk_valid / bk_data carry its beats.
// mark and bk_taken come from the same state machine and are never high
// together; a write issued before bk_taken is in the block's data (the port
// serves requests in order), one after it marks the block again. A block
// read alternates with flash requests when both wait, and a reset does not
// cut one short (its beats still arrive).
//
// Ports: nor_flash's req/ack memory port (see rtl/board/nor_flash.sv): a
// request is held until the clock in which ack is high; addr is the word
// address in the chip.
module ddram_flash #(
	parameter logic [28:0] CS0_BASE   = 29'h0620_0000,   // 0x31000000 / 8
	parameter logic [28:0] CS1_BASE   = 29'h0640_0000,   // 0x32000000 / 8
	parameter int          CS0_AW     = 23,
	parameter int          CS1_AW     = 22,
	parameter int          LINE_LOG2  = 2,               // 8-byte beats a line
	parameter int          LINES_LOG2 = 12              // 4096 x 32 bytes = 128 KB
) (
	input  logic              clk,
	input  logic              reset,

	input  logic              cs0_req,
	input  logic              cs0_we,
	input  logic [CS0_AW-1:0] cs0_addr,
	input  logic [15:0]       cs0_wdata,
	output logic [15:0]       cs0_rdata,
	output logic              cs0_ack,
	input  logic              cs0_lreq,
	input  logic [CS0_AW-1:2] cs0_laddr,
	output logic              cs0_ltaken,
	output logic              cs0_lrvalid,
	output logic              cs0_lrbeat,
	output logic [63:0]       cs0_lrdata,

	input  logic              cs1_req,
	input  logic              cs1_we,
	input  logic [CS1_AW-1:0] cs1_addr,
	input  logic [15:0]       cs1_wdata,
	output logic [15:0]       cs1_rdata,
	output logic              cs1_ack,
	input  logic              cs1_lreq,
	input  logic [CS1_AW-1:2] cs1_laddr,
	output logic              cs1_ltaken,
	output logic              cs1_lrvalid,
	output logic              cs1_lrbeat,
	output logic [63:0]       cs1_lrdata,

	input  logic              ld_we,
	input  logic [28:0]       ld_addr,
	input  logic [63:0]       ld_din,
	input  logic [7:0]        ld_be,
	output logic              ld_busy,

	output logic              mark,
	output logic [CS1_AW-9:0] mark_blk,
	output logic              c_blank,     // no non-erased C: data since the image load
	input  logic              bk_req,
	input  logic [CS1_AW-9:0] bk_blk,
	output logic              bk_taken,
	output logic              bk_valid,
	output logic [63:0]       bk_data,

	input  logic              ddram_busy,
	output logic [7:0]        ddram_burstcnt,
	output logic [28:0]       ddram_addr,
	input  logic [63:0]       ddram_dout,
	input  logic              ddram_dout_ready,
	output logic              ddram_rd,
	output logic [63:0]       ddram_din,
	output logic [7:0]        ddram_be,
	output logic              ddram_we
);

	localparam int AW    = (CS0_AW > CS1_AW) ? CS0_AW : CS1_AW;
	localparam int GW    = AW + 1;                         // {chip, word}
	localparam int BW    = GW - 2;                         // beat address
	localparam int LW    = BW - LINE_LOG2;                 // line address
	localparam int TAGW  = LW - LINES_LOG2;
	localparam int BEATS = 1 << LINE_LOG2;
	localparam int DAW   = LINES_LOG2 + LINE_LOG2;

	// ------------------------------------------------------------------
	// Requests as {chip, word}
	// ------------------------------------------------------------------
	wire [CS0_AW-1:0] a0 = cs0_lreq ? {cs0_laddr, 2'b00} : cs0_addr;
	wire [CS1_AW-1:0] a1 = cs1_lreq ? {cs1_laddr, 2'b00} : cs1_addr;
	wire [GW-1:0] g0 = {1'b0, AW'(a0)};
	wire [GW-1:0] g1 = {1'b1, AW'(a1)};

	function automatic logic [LINES_LOG2-1:0] index_of(input logic [GW-1:0] g);
		return g[2 + LINE_LOG2 +: LINES_LOG2];
	endfunction
	function automatic logic [TAGW-1:0] tag_of(input logic [GW-1:0] g);
		return g[GW-1 -: TAGW];
	endfunction
	function automatic logic [28:0] beat_of(input logic [GW-1:0] g);
		return (g[GW-1] ? CS1_BASE : CS0_BASE) + 29'(g[AW-1:2]);
	endfunction
	function automatic logic [15:0] lane(input logic [63:0] d, input logic [1:0] l);
		return d[16 * l +: 16];
	endfunction

	// ------------------------------------------------------------------
	// Beat buffers
	// ------------------------------------------------------------------
	logic [1:0]    bb_v = 2'b00;
	logic [BW-1:0] bb_beat [2];
	logic [63:0]   bb_data [2];
	logic [1:0]    ack_q = 2'b00;
	logic [15:0]   rdata_q [2];
	logic [1:0]    lrvalid_q = 2'b00;
	logic          lrbeat_q = 1'b0;
	logic [63:0]   lrdata_q;

	typedef enum logic [2:0] {
		S_SWEEP,
		S_IDLE,
		S_LOOK,
		S_LINE,
		S_FILL,
		S_WRITE,
		S_BULK
	} state_t;

	localparam int BK_BEATS = 64;                          // 512 bytes

	state_t state = S_SWEEP;
	logic   sweep_req = 1'b1;

	wire can_hit = !reset && state != S_SWEEP && !sweep_req;
	wire [1:0] bb_hit = {
		can_hit && cs1_req && !cs1_lreq && !cs1_we && !ack_q[1] && bb_v[1] && bb_beat[1] == g1[GW-1:2],
		can_hit && cs0_req && !cs0_lreq && !cs0_we && !ack_q[0] && bb_v[0] && bb_beat[0] == g0[GW-1:2]
	};

	assign cs0_ack     = !reset && (ack_q[0] || bb_hit[0]);
	assign cs1_ack     = !reset && (ack_q[1] || bb_hit[1]);
	assign cs0_rdata   = ack_q[0] ? rdata_q[0] : lane(bb_data[0], cs0_addr[1:0]);
	assign cs1_rdata   = ack_q[1] ? rdata_q[1] : lane(bb_data[1], cs1_addr[1:0]);
	assign cs0_lrvalid = !reset && lrvalid_q[0];
	assign cs1_lrvalid = !reset && lrvalid_q[1];
	assign cs0_lrbeat  = lrbeat_q;
	assign cs1_lrbeat  = lrbeat_q;
	assign cs0_lrdata  = lrdata_q;
	assign cs1_lrdata  = lrdata_q;

	// The port the state machine looks at (round robin), and whether it may
	// take that request: not answered from a beat buffer, not the one being
	// answered now. The cache RAMs read the picked request's line at once.
	logic last_port = 1'b0;
	wire  req0  = cs0_req || cs0_lreq;
	wire  req1  = cs1_req || cs1_lreq;
	wire  want0 = (cs0_req && !ack_q[0] && !bb_hit[0]) || cs0_lreq;
	wire  want1 = (cs1_req && !ack_q[1] && !bb_hit[1]) || cs1_lreq;
	wire  pick  = (req0 && req1) ? ~last_port : req1;   // 1: CS1
	wire [GW-1:0] pick_g = pick ? g1 : g0;
	wire  take  = pick ? want1 : want0;
	wire  take_go = state == S_IDLE && !sweep_req && !reset && take && !(bk_req && bk_turn);

	assign cs0_ltaken = take_go && !pick && cs0_lreq;
	assign cs1_ltaken = take_go &&  pick && cs1_lreq;

	// ------------------------------------------------------------------
	// Cache RAMs
	// ------------------------------------------------------------------
	logic                 tag_we;
	logic [LINES_LOG2-1:0] tag_waddr;
	logic [TAGW:0]        tag_wdata;
	logic [LINES_LOG2-1:0] tag_raddr;
	logic [TAGW:0]        tag_q;

	logic [3:0]           dat_we;
	logic [DAW-1:0]       dat_waddr;
	logic [63:0]          dat_wdata;
	logic [DAW-1:0]       dat_raddr;
	logic [63:0]          dat_q;

	sdp_ram #(.AW(LINES_LOG2), .DW(TAGW + 1)) tags (
		.clk(clk), .we(tag_we), .waddr(tag_waddr), .wdata(tag_wdata), .raddr(tag_raddr), .rdata(tag_q)
	);

	genvar i;
	generate
		for (i = 0; i < 4; i++) begin : g_lane
			sdp_ram #(.AW(DAW), .DW(16)) data (
				.clk(clk), .we(dat_we[i]), .waddr(dat_waddr), .wdata(dat_wdata[16 * i +: 16]),
				.raddr(dat_raddr), .rdata(dat_q[16 * i +: 16])
			);
		end
	endgenerate

	// ------------------------------------------------------------------
	// DDRAM port: our command or the loader's
	// ------------------------------------------------------------------
	logic        own_rd = 1'b0, own_we = 1'b0, own_bulk = 1'b0;
	logic [28:0] own_addr;
	logic [63:0] own_din;
	logic [7:0]  own_be;
	logic        hold_q = 1'b0, hold_ld = 1'b0;

	// C: is blank until any non-FFFF data is loaded/programmed in CS1's
	// upper half. Erases and core resets must not re-enable the fast format.
	// Both full-image loaders start at CS1_BASE, byte lane 0; re-arm there
	// and scan enabled byte lanes as the image arrives while the CPU is held.
	localparam logic [28:0] C_FIRST_BEAT = CS1_BASE + (29'd1 << (CS1_AW - 3));
	localparam logic [28:0] CS1_END_BEAT = CS1_BASE + (29'd1 << (CS1_AW - 2));
	logic c_blank_q = 1'b1;
	assign c_blank = c_blank_q;

	wire own_cmd = own_rd | own_we;
	wire sel_ld  = hold_q ? hold_ld : (ld_we && !own_cmd);
	wire own_taken = !sel_ld && own_cmd && !ddram_busy;
	wire ld_taken  = sel_ld && ld_we && !ddram_busy;
	// Only a write into the flash images themselves empties the cache: the
	// debug trace and the kernel-text ring share the loader port and write
	// elsewhere in DDR3 (NGage.sv), and must not.
	wire ld_flash  = ld_taken && (ld_addr[28:21] == CS0_BASE[28:21] || ld_addr[28:20] == CS1_BASE[28:20]);

	assign ddram_rd       = !sel_ld && own_rd;
	assign ddram_we       = sel_ld ? ld_we : own_we;
	assign ddram_addr     = sel_ld ? ld_addr : own_addr;
	assign ddram_din      = sel_ld ? ld_din : own_din;
	assign ddram_be       = sel_ld ? ld_be : own_be;
	assign ddram_burstcnt = (!sel_ld && own_rd) ? (own_bulk ? 8'(BK_BEATS) : 8'(BEATS)) : 8'd1;
	assign ld_busy        = !(sel_ld && !ddram_busy);

	always_ff @(posedge clk) begin
		if (ld_taken && ld_addr == CS1_BASE && ld_be[0]) c_blank_q <= 1'b1;
		if (ld_taken && ld_addr >= C_FIRST_BEAT && ld_addr < CS1_END_BEAT)
			for (int i = 0; i < 8; i++)
				if (ld_be[i] && ld_din[8 * i +: 8] != 8'hFF) c_blank_q <= 1'b0;
		if (state == S_LOOK && !abandon && cur_we && cur_g[GW-1] &&
		    cur_g[CS1_AW-1] && cur_wdata != 16'hFFFF)
			c_blank_q <= 1'b0;
	end

	// ------------------------------------------------------------------
	// The state machine
	// ------------------------------------------------------------------
	logic                  cur_port;
	logic                  cur_we;
	logic                  cur_line;
	logic [GW-1:0]         cur_g;
	logic [15:0]           cur_wdata;
	logic                  abandon;
	logic [LINE_LOG2-1:0]  fill_cnt;
	logic [LINES_LOG2-1:0] sweep_ptr = '0;
	logic [5:0]            bk_cnt;
	logic                  bk_turn = 1'b0;   // a block read goes first when both wait

	// a block read now, rather than a flash request
	wire bk_go = state == S_IDLE && !sweep_req && !reset && bk_req && (bk_turn || !take);

	assign bk_taken = bk_go;
	assign bk_valid = state == S_BULK && ddram_dout_ready;
	assign bk_data  = ddram_dout;
	assign mark     = state == S_LOOK && cur_we && !abandon && cur_g[GW-1];
	assign mark_blk = cur_g[CS1_AW-1:8];

	wire                  cur_hit  = tag_q[TAGW] && tag_q[TAGW-1:0] == tag_of(cur_g);
	wire [LINE_LOG2-1:0]  cur_beat = cur_g[2 +: LINE_LOG2];

	always_comb begin
		tag_raddr = index_of(pick_g);
		dat_raddr = (state == S_LOOK) ? {index_of(cur_g), cur_beat ^ LINE_LOG2'(1)}
		                              : {index_of(pick_g), pick_g[2 +: LINE_LOG2]};

		tag_we    = 1'b0;
		tag_waddr = index_of(cur_g);
		tag_wdata = {!abandon, tag_of(cur_g)};
		dat_we    = 4'b0000;
		dat_waddr = {index_of(cur_g), cur_beat};
		dat_wdata = {4{cur_wdata}};

		case (state)
			S_SWEEP: begin
				tag_we    = 1'b1;
				tag_waddr = sweep_ptr;
				tag_wdata = '0;
			end
			S_LOOK: begin
				// a write updates a cached copy of its line
				if (cur_we && cur_hit && !abandon) dat_we = 4'b0001 << cur_g[1:0];
			end
			S_FILL: begin
				if (ddram_dout_ready) begin
					dat_we    = 4'b1111;
					dat_waddr = {index_of(cur_g), fill_cnt};
					dat_wdata = ddram_dout;
					if (fill_cnt == LINE_LOG2'(BEATS - 1)) tag_we = 1'b1;
				end
			end
			default: ;
		endcase
	end

	always_ff @(posedge clk) begin
		ack_q     <= 2'b00;
		lrvalid_q <= 2'b00;
		if (own_taken) begin
			own_rd <= 1'b0;
			own_we <= 1'b0;
		end
		hold_q  <= (ddram_rd || ddram_we) && ddram_busy;
		hold_ld <= sel_ld;
		if (ld_flash) begin
			sweep_req <= 1'b1;
			bb_v      <= 2'b00;
		end
		if (reset) begin
			// a sweep already running covers every line; asking for another
			// made a reset of more than one clock sweep twice
			if (state != S_SWEEP) sweep_req <= 1'b1;
			bb_v      <= 2'b00;
			abandon   <= 1'b1;
		end

		case (state)
			S_SWEEP: begin
				sweep_ptr <= sweep_ptr + 1'd1;
				bb_v      <= 2'b00;
				if (&sweep_ptr && !reset && !sweep_req) state <= S_IDLE;
				if (&sweep_ptr) sweep_req <= reset || ld_flash;
			end

			S_IDLE: begin
				if (sweep_req || reset) begin
					state     <= S_SWEEP;
					sweep_ptr <= '0;
					sweep_req <= 1'b0;
				end else if (bk_go) begin
					own_rd   <= 1'b1;
					own_bulk <= 1'b1;
					own_addr <= CS1_BASE + 29'({bk_blk, 6'd0});
					bk_cnt   <= 6'd0;
					bk_turn  <= 1'b0;
					state    <= S_BULK;
				end else if (take) begin
					bk_turn   <= 1'b1;
					// the tag and the beat are read at this edge
					cur_port  <= pick;
					last_port <= pick;
					cur_line  <= pick ? cs1_lreq : cs0_lreq;
					cur_we    <= pick ? (!cs1_lreq && cs1_we) : (!cs0_lreq && cs0_we);
					cur_g     <= pick_g;
					cur_wdata <= pick ? cs1_wdata : cs0_wdata;
					abandon   <= 1'b0;
					state     <= S_LOOK;
				end
			end

			S_LOOK: begin
				if (abandon || reset) begin
					state <= S_IDLE;
				end else if (cur_we) begin
					own_we   <= 1'b1;
					own_addr <= beat_of(cur_g);
					own_din  <= {4{cur_wdata}};
					own_be   <= 8'b11 << {cur_g[1:0], 1'b0};
					if (bb_v[cur_port] && bb_beat[cur_port] == cur_g[GW-1:2])
						bb_data[cur_port][16 * cur_g[1:0] +: 16] <= cur_wdata;
					state <= S_WRITE;
				end else if (cur_hit) begin
					if (cur_line) begin
						lrvalid_q[cur_port] <= 1'b1;
						lrbeat_q            <= cur_g[2];
						lrdata_q            <= dat_q;
						state               <= S_LINE;
					end else begin
						ack_q[cur_port]   <= 1'b1;
						rdata_q[cur_port] <= lane(dat_q, cur_g[1:0]);
						if (!sweep_req && !ld_flash) begin
							bb_v[cur_port]    <= 1'b1;
							bb_beat[cur_port] <= cur_g[GW-1:2];
							bb_data[cur_port] <= dat_q;
						end
						state <= S_IDLE;
					end
				end else begin
					own_rd   <= 1'b1;
					own_bulk <= 1'b0;
					own_addr <= beat_of({cur_g[GW-1:2 + LINE_LOG2], {LINE_LOG2{1'b0}}, 2'b00});
					fill_cnt <= '0;
					state    <= S_FILL;
				end
			end

			S_LINE: begin
				if (!abandon && !reset) begin
					lrvalid_q[cur_port] <= 1'b1;
					lrbeat_q            <= ~cur_g[2];
					lrdata_q            <= dat_q;
					if (!sweep_req && !ld_flash) begin
						bb_v[cur_port]    <= 1'b1;
						bb_beat[cur_port] <= {cur_g[GW-1:3], ~cur_g[2]};
						bb_data[cur_port] <= dat_q;
					end
				end
				state <= S_IDLE;
			end

			S_FILL: begin
				if (ddram_dout_ready) begin
					fill_cnt <= fill_cnt + 1'd1;
					if (cur_line) begin
						if ((fill_cnt >> 1) == (cur_beat >> 1) && !abandon && !reset) begin
							lrvalid_q[cur_port] <= 1'b1;
							lrbeat_q            <= fill_cnt[0];
							lrdata_q            <= ddram_dout;
							if (!sweep_req && !ld_flash) begin
								bb_v[cur_port]    <= 1'b1;
								bb_beat[cur_port] <= {cur_g[GW-1:3], fill_cnt[0]};
								bb_data[cur_port] <= ddram_dout;
							end
						end
					end else if (fill_cnt == cur_beat && !abandon && !reset) begin
						ack_q[cur_port]   <= 1'b1;
						rdata_q[cur_port] <= lane(ddram_dout, cur_g[1:0]);
						if (!sweep_req && !ld_flash) begin
							bb_v[cur_port]    <= 1'b1;
							bb_beat[cur_port] <= cur_g[GW-1:2];
							bb_data[cur_port] <= ddram_dout;
						end
					end
					if (fill_cnt == LINE_LOG2'(BEATS - 1)) state <= S_IDLE;
				end
			end

			S_WRITE: begin
				if (own_taken) begin
					if (!abandon && !reset) ack_q[cur_port] <= 1'b1;
					state <= S_IDLE;
				end
			end

			// a block read for flash_save: its beats arrive whatever reset does
			S_BULK: begin
				if (ddram_dout_ready) begin
					bk_cnt <= bk_cnt + 6'd1;
					if (bk_cnt == 6'(BK_BEATS - 1)) state <= S_IDLE;
				end
			end

			default: state <= S_IDLE;
		endcase

		if (reset) begin
			ack_q     <= 2'b00;
			lrvalid_q <= 2'b00;
		end
	end

endmodule
