// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 timers 0-5 (0x0C120A00 + 0x20n), as the reference model has them
// (model/hw/ngage_intc.c; docs/UPP_WD2.md). The clock is 104/3 MHz = 34.67 MHz:
// the kernel converts microseconds with x34666/1000 (ekern 0x5031CB74) and its
// tick reload 0x843E2 (0x5031C6F0) gives the EKA1 1/64 s tick. Each timer
// counts down once every TIMER_DIV clocks, the phase counted from the write
// that (re)started it, as the model counts from the moment of the write.
//
//   +0x04 control: bit 1 = run, reloading from +0x18 on underflow (kernel tick
//         timer 0, 0x5031C6E4; boot timer 0, 0x31AC); bit 0 alone = run once
//         and stop at zero ([model guess]: the high-resolution timer 1 is
//         started with 1 and re-armed by writing +0x10 for each expiry,
//         0x5031CA78 / 0x5031CB1C). A write with bits 1:0 nonzero starts a
//         stopped timer from the value at +0x10; zero stops a running one,
//         which keeps its count. Reads give the value written (storage).
//   +0x08 interrupt acknowledge: any write clears the timer's interrupt,
//         which underflow sets (tick ISR writes 0 at 0x5031C5C0; timer-1 ISR
//         writes 1 at 0x5031CACC; boot and timer-4 ISRs write 1). Reads give
//         the value written (storage; the boot polls it at 0x3208).
//   +0x10 counter: reads the live count; a write loads it, restarts a running
//         timer from the new value, and re-arms a timer whose control has
//         bits 1:0 set (a one-shot that ran out).
//   +0x18 reload value (storage).
// Underflow: the count goes C, C-1, ..., 1 and then, at the tick that would
// make it 0, the interrupt is raised and the count becomes the reload value
// (bit 1 set) or 0 with the timer stopped (bit 1 clear). A count of 0 runs
// for 2^32 ticks. So the interrupt comes TIMER_DIV * C clocks after the start.
// An underflow and a register write at the same clock edge are taken in that
// order (the model's timer fires before the next instruction runs): an
// acknowledge then clears the new interrupt, a write of +0x10 restarts from
// the reloaded or stopped state.
// Interrupt source n is timer n (boot timer 0 is bit 0; the kernel's timer 4
// at 0x0C120A80 is bit 4, 0x5031C968).
// Accesses are 32-bit (upp_periph drops others, as the model's region does).
module upp_timers #(
	parameter int TIMER_DIV = 3
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        acc,
	input  logic        wr,
	input  logic [11:0] off,          // byte offset in the 0x0C120000 page
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,

	output logic [5:0]  irq
);

	localparam int PW = (TIMER_DIV > 1) ? $clog2(TIMER_DIV) : 1;

	logic [31:0]   cnt    [0:5];
	logic [31:0]   reload [0:5];
	logic [1:0]    ctrl   [0:5];
	logic [PW-1:0] pre    [0:5];
	logic [5:0]    running;

	wire [2:0]  n    = 3'((off - 12'hA00) >> 5);
	wire [4:0]  r    = off[4:0];

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		if (acc && r == 5'h10) begin
			rmask = '1;
			rdata = cnt[n];
		end
	end

	genvar t;
	generate
		for (t = 0; t < 6; t++) begin : g_timer
			wire hit  = wr && n == 3'(t);
			wire tick = running[t] && pre[t] == PW'(TIMER_DIV - 1);

			always_ff @(posedge clk) begin
				logic [31:0]   c;
				logic          run, irq_n;
				logic [PW-1:0] p;
				c     = cnt[t];
				run   = running[t];
				irq_n = irq[t];
				p     = pre[t];

				// the tick: an underflow comes before a write at the same edge,
				// as the model's timer fires before the next instruction
				if (run) p = (p == PW'(TIMER_DIV - 1)) ? '0 : p + 1'd1;
				if (tick) begin
					if (c == 32'd1) begin
						irq_n = 1'b1;
						if (ctrl[t][1]) begin
							c = reload[t];
						end else begin
							c   = 32'd0;
							run = 1'b0;
						end
					end else begin
						c = c - 32'd1;
					end
				end

				if (hit) begin
					case (r)
						5'h04: begin
							ctrl[t] <= wdata[1:0];
							if (wdata[1:0] != 2'd0 && !run) begin
								// a start, from the count at +0x10
								run = 1'b1;
								p   = '0;
							end else if (wdata[1:0] == 2'd0) begin
								run = 1'b0;
							end
						end
						5'h08: irq_n = 1'b0;
						5'h10: begin
							c = wdata;
							if (run || ctrl[t] != 2'd0) begin
								run = 1'b1;
								p   = '0;
							end
						end
						5'h18: reload[t] <= wdata;
						default: ;
					endcase
				end

				cnt[t]     <= c;
				running[t] <= run;
				irq[t]     <= irq_n;
				pre[t]     <= p;

				if (reset) begin
					cnt[t]     <= 32'd0;
					reload[t]  <= 32'd0;
					ctrl[t]    <= 2'd0;
					pre[t]     <= '0;
					running[t] <= 1'b0;
					irq[t]     <= 1'b0;
				end
			end
		end
	endgenerate


endmodule
