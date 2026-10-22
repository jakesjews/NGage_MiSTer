// SPDX-License-Identifier: GPL-2.0-or-later
//
// The firmware's debug text on hardware: the kernel writes its trace text
// into the STI window (0x0DE00000, one byte an address; upp_periph brings
// the writes out as sti_*), which the model keeps as kern.log. This keeps
// the bytes in a 64 KB ring in DDR3 at BASE, written through the loader
// port one byte-lane write each, with the byte count (the ring's write
// pointer) at BASE + 0x10000 after every burst; tools/mister_trace.py
// fetch-sti reads them back through /dev/mem.
//
// The pointer counts from the power-on reset, not from a core reset, so
// the text of a warm reset follows the text before it. Bytes arrive up to
// four a clock and go out one a clock at best, so a FIFO of 256 writes
// (up to 1024 bytes) sits between; a full FIFO drops writes, counted in
// dropped.
module dbg_sti #(
	parameter logic [28:0] BASE = 29'h0662_0000     // 0x33100000 / 8
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        sti_we,
	input  logic [3:0]  sti_be,
	input  logic [31:0] sti_data,

	output logic        ld_we,
	output logic [28:0] ld_addr,
	output logic [63:0] ld_din,
	output logic [7:0]  ld_be,
	input  logic        ld_busy,

	output logic [15:0] count,       // bytes written, modulo 65536
	output logic [7:0]  dropped
);

	// ---- FIFO of writes {be, data} ----
	logic [35:0] fifo [256];
	logic [7:0]  wp = 8'd0, rp = 8'd0;
	wire         full  = (wp + 8'd1) == rp;
	wire         empty = wp == rp;
	logic [35:0] head;

	always_ff @(posedge clk) begin
		if (sti_we && !full) fifo[wp] <= {sti_be, sti_data};
		head <= fifo[rp];
	end

	// ---- the ring in DDR3: one lane write a byte ----
	typedef enum logic [1:0] { S_IDLE, S_BYTE, S_WRITE, S_PTR } state_t;
	state_t      state = S_IDLE;
	logic [3:0]  lanes;          // bytes of the head write still to go
	logic [31:0] data;
	logic [16:0] ptr = '0;       // byte count; bit 16 = wrapped once at least
	logic        pending = 1'b0; // a pointer write is owed

	assign count = ptr[15:0];
	assign ld_we = state == S_WRITE || state == S_PTR;

	function automatic logic [1:0] first_lane(input logic [2:0] l);
		return l[0] ? 2'd0 : l[1] ? 2'd1 : l[2] ? 2'd2 : 2'd3;
	endfunction
	wire [1:0]  lane = first_lane(lanes[2:0]);
	wire [7:0]  byte_now = data[8 * lane +: 8];

	always_ff @(posedge clk) begin
		if (sti_we && full) dropped <= dropped + 8'd1;
		if (sti_we && !full) wp <= wp + 8'd1;

		case (state)
			S_IDLE: begin
				if (!empty) begin
					lanes <= head[35:32];
					data  <= head[31:0];
					rp    <= rp + 8'd1;
					state <= S_BYTE;
				end else if (pending) begin
					ld_addr <= BASE + 29'h2000;
					ld_din  <= {32'd0, 15'd0, ptr};
					ld_be   <= 8'hFF;
					pending <= 1'b0;
					state   <= S_PTR;
				end
			end
			S_BYTE: begin
				if (lanes == 4'd0) begin
					state <= S_IDLE;
				end else begin
					ld_addr <= BASE + 29'(ptr[15:3]);
					ld_din  <= {8{byte_now}};
					ld_be   <= 8'b1 << ptr[2:0];
					lanes[lane] <= 1'b0;
					state   <= S_WRITE;
				end
			end
			S_WRITE: if (!ld_busy) begin
				ptr     <= ptr + 17'd1;
				pending <= 1'b1;
				state   <= S_BYTE;
			end
			S_PTR: if (!ld_busy) state <= S_IDLE;
			default: state <= S_IDLE;
		endcase

		if (reset) begin
			wp      <= 8'd0;
			rp      <= 8'd0;
			ptr     <= '0;
			pending <= 1'b0;
			dropped <= 8'd0;
			state   <= S_IDLE;
		end
	end

endmodule
