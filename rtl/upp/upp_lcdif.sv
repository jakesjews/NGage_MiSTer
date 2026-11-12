// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 LCD bus interface (0x0C121200-0x0C12120F) driving the display
// module's 8-bit 8080 bus, as the reference model has it
// (model/hw/ngage_lcd.c; bootstrap 0x6600-0x6F40, lcd.ldd 0x50401D34-
// 0x50406968; docs/UPP_WD2.md):
//
//   +0x00 control. A write sets the phase for the following +0x08 accesses:
//         bits 15:0 = bytes - 1; bits 19:18 = how a FIFO word becomes bus
//         bytes:
//           2 (0x09280000)  one command byte, word bits 7:0, D/CX low; not
//                           counted against the phase length
//           1 (0x0924xxxx, 0x8314xxxx, 0x8924xxxx)  three bytes from the
//                           12-bit units u0 = w[11:0], u1 = w[27:16]: with
//                           bit 31 clear V = u0 | u1 << 12, least significant
//                           byte first (CASET/PASET parameters, bootstrap
//                           0x694C); with bit 31 set u0[11:4], u0[3:0]u1[11:8],
//                           u1[7:0], two 0x0RGB pixels in DCS 12-bit order
//                           (lcd.ldd 0x50402188; [model guess] bit 31's meaning)
//           3 (0x092Cxxxx LUT, 0x082Cxxxx 16-bit pixels)  four bytes, least
//                           significant first
//           0               words are dropped
//         Data bytes past the phase length are dropped. Control bits 27:24 =
//         7 (0x0784xxxx) is a read phase: each +0x08 read is one bus read
//         cycle (the panel sends a dummy byte first; bootstrap RDDID 0x6C44).
//         Read: the value written, with bit 30 = ready. The drivers write
//         0x49200000 and poll bit 30 (lcd.ldd 0x504068A0, which after 16 tries
//         resets the FIFO). The model is always ready; here ready means the
//         FIFO is empty and the bus idle, which is what the model's instant
//         interface always is.
//   +0x04 auxiliary: storage; bit 2 reads 1 while the FIFO can take a word
//         (polled before data writes, bootstrap 0x6858, lcd.ldd 0x50401F14;
//         always 1 in the model). Writes of 2 then 1 (0x6834, "FIFO reset")
//         do nothing, as in the model.
//   +0x08 FIFO: a write queues a word for the current phase (also the LCD DMA
//         target 0x10121208, 32-bit). A read in a read phase returns the next
//         byte from the panel; otherwise the last word written (storage).
// Control words and data words share one queue, so phases apply in order
// however far the bus lags. A write to a full queue waits (busy), which only
// happens when the writer ignores bit 2. Reads in a read phase wait until the
// queue has drained and the bus read is done.
//
// Bus: /CS low and /RES high from reset (the QD's panel sits on the bus
// alone; [open] whether a GENIO line drives /RES: the model has no panel
// reset). A write byte holds D and D/CX, /WR low for WR_LOW clocks and high
// for WR_HIGH clocks (the panel takes it on the rising edge); a read holds
// /RD low for RD_LOW clocks, samples D at the end, then high for RD_HIGH
// clocks. [assumed] the bus timing: the UPP_WD2's is not known; 2 + 2 clocks
// is 26 MB/s, a 12-bpp frame in about 2.1 ms.
// Accesses are 32-bit (upp_periph drops others, as the model's region does).
module upp_lcdif #(
	parameter int WR_LOW  = 2,
	parameter int WR_HIGH = 2,
	parameter int RD_LOW  = 4,
	parameter int RD_HIGH = 6,
	parameter int QAW     = 4           // queue depth 2^QAW words
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        we,
	input  logic        wr,
	input  logic        rd,
	input  logic [3:0]  off,
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,
	output logic        busy,

	input  wire         dma_valid,
	input  wire [31:0]  dma_data,
	output wire         dma_ready,

	output logic        tx_ready,       // the queue can take a word (DMA pacing)
	output logic        active,         // the bus has carried a byte since reset

	output logic        csx,
	output logic        dcx,
	output logic        wrx,
	output logic        rdx,
	output logic        resx,
	output logic [7:0]  d_o,
	output logic        d_oe,
	input  logic [7:0]  d_i
);

	localparam int TW = 4;
	localparam logic [2:0] S_IDLE  = 3'd0;
	localparam logic [2:0] S_WR_LO = 3'd1;
	localparam logic [2:0] S_WR_HI = 3'd2;
	localparam logic [2:0] S_RD_LO = 3'd3;
	localparam logic [2:0] S_RD_HI = 3'd4;

	// ------------------------------------------------------------------
	// Register side
	// ------------------------------------------------------------------
	logic [3:0]  prog_ctrl;              // bits 27:24 of the control word last written
	logic        rd_have;                // rd_byte holds the byte for the read in progress
	logic [7:0]  rd_byte;
	logic        ready;

	wire read_phase = prog_ctrl == 4'h7;
	logic        q_pop;
	wire         q_full, q_empty, q_valid;
	wire [32:0]  q_dout;

	wire cpu_push = wr && (off == 4'h0 || off == 4'h8);
	// Reserve for a selected CPU access before its pipelined ready sample.
	// Native traffic cannot fill the FIFO between that sample and CPU commit.
	assign dma_ready = !reset && !acc && !q_full;
	wire dma_push = dma_valid && dma_ready;
	wire push = cpu_push || dma_push;
	reg [31:0] last_word;
	always @(posedge clk) begin
		if (dma_push) last_word <= dma_data;
		if (wr && off == 4'h8) last_word <= wdata;
		if (reset) last_word <= 0;
	end
	wire want_read = acc && !we && off == 4'h8 && read_phase;

	upp_fifo #(.DW(33), .AW(QAW)) queue (
		.clk(clk),
		.flush(reset),
		.push(push),
		.din(dma_push ? {1'b0, dma_data} : {off == 4'h0, wdata}),
		.pop(q_pop),
		.dout(q_dout),
		.valid(q_valid),
		.full(q_full),
		.empty(q_empty),
		.room()
	);

	assign tx_ready = !q_full;

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		busy  = 1'b0;
		if (acc) begin
			case (off)
				4'h0: begin
					rmask = 32'h4000_0000;
					rdata = {1'b0, ready, 30'd0};
					busy  = we && q_full;
				end
				4'h4: begin
					rmask = 32'h0000_0004;
					rdata = {29'd0, !q_full, 2'd0};
				end
				4'h8: begin
					if (!read_phase) begin
						rmask = 32'hffffffff;
						rdata = last_word;
					end
					if (we) begin
						busy = q_full;
					end else if (read_phase) begin
						rmask = '1;
						rdata = {24'd0, rd_byte};
						busy  = !rd_have;
					end
				end
				default: ;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// Bus side
	// ------------------------------------------------------------------
	logic [2:0]    st;
	logic [TW-1:0] tmr;
	logic          cur_dcs;              // bit 31 of the current phase: DCS pixel order
	logic [1:0]    pack;                 // bits 19:18 of the current phase
	logic [16:0]   left;                 // data bytes left in the phase
	logic [31:0]   obuf;                 // bytes of the word being sent, next in 7:0
	logic [2:0]    ocnt;
	logic          odata;                // they are data (D/CX high), counted in left

	assign q_pop = st == S_IDLE && ocnt == 3'd0 && q_valid;
	wire [11:0] u0    = q_dout[11:0];
	wire [11:0] u1    = q_dout[27:16];
	wire [23:0] v12   = {u1, u0};

	assign ready = q_empty && st == S_IDLE && ocnt == 3'd0;

	always_ff @(posedge clk) begin
		if (wr && off == 4'h0) prog_ctrl <= wdata[27:24];
		if (rd) rd_have <= 1'b0;

		case (st)
			S_IDLE: begin
				if (ocnt != 3'd0) begin
					if (odata && left == 17'd0) begin
						ocnt <= 3'd0;          // past the phase length: dropped
					end else begin
						d_o    <= obuf[7:0];
						dcx    <= odata;
						wrx    <= 1'b0;
						active <= 1'b1;
						tmr    <= TW'(WR_LOW - 1);
						st     <= S_WR_LO;
					end
				end else if (q_valid) begin
					// q_pop takes the word now
					if (q_dout[32]) begin
						cur_dcs  <= q_dout[31];
						pack     <= q_dout[19:18];
						left     <= {1'b0, q_dout[15:0]} + 17'd1;
					end else begin
						case (pack)
							2'd2: begin obuf <= {24'd0, q_dout[7:0]}; ocnt <= 3'd1; odata <= 1'b0; end
							2'd1: begin
								obuf  <= cur_dcs ? {8'd0, u1[7:0], u0[3:0], u1[11:8], u0[11:4]}
								                      : {8'd0, v12};
								ocnt  <= 3'd3;
								odata <= 1'b1;
							end
							2'd3: begin obuf <= q_dout[31:0]; ocnt <= 3'd4; odata <= 1'b1; end
							default: ;             // no phase: dropped
						endcase
					end
				end else if (want_read && !rd_have && !rd) begin
					dcx  <= 1'b1;
					d_oe <= 1'b0;
					rdx  <= 1'b0;
					tmr  <= TW'(RD_LOW - 1);
					st   <= S_RD_LO;
				end
			end
			S_WR_LO: begin
				if (tmr == '0) begin
					wrx <= 1'b1;
					tmr <= TW'(WR_HIGH - 1);
					st  <= S_WR_HI;
				end else begin
					tmr <= tmr - 1'd1;
				end
			end
			S_WR_HI: begin
				if (tmr == '0) begin
					obuf <= {8'd0, obuf[31:8]};
					ocnt <= ocnt - 3'd1;
					if (odata) left <= left - 17'd1;
					st   <= S_IDLE;
				end else begin
					tmr <= tmr - 1'd1;
				end
			end
			S_RD_LO: begin
				if (tmr == '0) begin
					rd_byte <= d_i;
					rdx     <= 1'b1;
					tmr     <= TW'(RD_HIGH - 1);
					st      <= S_RD_HI;
				end else begin
					tmr <= tmr - 1'd1;
				end
			end
			S_RD_HI: begin
				if (tmr == '0) begin
					d_oe    <= 1'b1;
					rd_have <= 1'b1;
					st      <= S_IDLE;
				end else begin
					tmr <= tmr - 1'd1;
				end
			end
			default: st <= S_IDLE;
		endcase

		if (reset) begin
			st        <= S_IDLE;
			prog_ctrl <= 4'd0;
			cur_dcs   <= 1'b0;
			pack      <= 2'd0;
			left      <= 17'd0;
			ocnt      <= 3'd0;
			rd_have   <= 1'b0;
			active    <= 1'b0;
			wrx       <= 1'b1;
			rdx       <= 1'b1;
			dcx       <= 1'b1;
			d_oe      <= 1'b1;
			d_o       <= 8'h00;
		end
	end

	assign csx  = 1'b0;
	assign resx = 1'b1;


endmodule
