// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP_WD2 interrupt controller (0x0C120100-0x0C12027F) and OS-timer
// interrupt unit (0x0C120040-0x0C12007F), register for register as the
// reference model has them (model/hw/ngage_intc.c; evidence collected in
// docs/UPP_WD2.md, RH-29 v4.60 code):
//
// Two planes of three 32-source banks; bank k of the IRQ plane at
// 0x0C120100 + 0x40k, of the FIQ plane at 0x0C1201C0 + 0x40k. Per bank:
//   +0x08  write: 1s enable those sources on this plane (ekern 0x5031E874
//          IRQ, 0x5031E998 FIQ: single-bit writes; boot 0x31D4); read: the
//          enable bits
//   +0x0C  write: 1s disable (ekern 0x5031E8CC / 0x5031E9F0; boot ISR 0x3074);
//          reads 0
//   +0x10  read: the source levels of the bank (ekern 0x5031E7B0 / 0x5031E930)
//   +0x14  read: 1 + the number of the lowest pending enabled source in the
//          bank, 0 = none. The IRQ dispatcher 0x5031C87C calls ISR n + 0x5C +
//          32 * bank, the FIQ dispatcher 0x5031C99C ISR n - 1 + 32 * bank.
//          [model guess] the priority order: the model takes the lowest bit.
//   other offsets: storage (the generic store in upp_periph answers them).
// Sources are levels (bit b of bank k = source 32k + b); the controller
// latches nothing: the devices hold their requests until acknowledged.
// irq / fiq are high while any source pending on that plane is enabled.
//
// OS-timer unit:
//   +0x04 (0x0C120044)  storage; bits 2:0 enable the status bits onto FIQ
//                        (the kernel writes 2 at 0x5031C7A8)
//   +0x10 (0x0C120050)  status bits 2:0, write 1 to clear. The FIQ dispatcher
//                        reads it first and treats bit 1 as the system tick
//                        (0x5031C99C). [model guess, open] nothing is known to
//                        set it; ost_set is the hook, tied off in upp_periph.
//   other offsets: storage.
// Accesses are 32-bit (the model's regions take only those); upp_periph
// drops others before they get here.
module upp_intc (
	input  logic        clk,
	input  logic        reset,

	input  logic [95:0] src,
	input  logic [2:0]  ost_set,

	input  logic        acc,
	input  logic        wr,
	input  logic [11:0] off,          // byte offset in the 0x0C120000 page
	input  logic [31:0] wdata,
	output logic [31:0] rmask,
	output logic [31:0] rdata,

	output logic        irq,
	output logic        fiq,
	output logic [31:0] dbg_en0_irq,     // debug overlay: IRQ-plane enables, bank 0
	output logic [31:0] dbg_en0_fiq      // debug overlay: FIQ-plane enables, bank 0
);

	logic [31:0] en [0:5];            // 0-2 IRQ banks, 3-5 FIQ banks
	logic [2:0]  ost_status, ost_en;

	// the bank an offset in 0x100-0x27F names, and the register in it
	wire        is_ost  = off[11:6] == 6'h01;                 // 0x040-0x07F
	wire [2:0]  idx     = 3'((off - 12'h100) >> 6);           // 0..5
	wire [1:0]  bank    = (idx >= 3'd3) ? 2'(idx - 3'd3) : idx[1:0];
	wire [5:0]  r       = off[5:0];

	assign dbg_en0_irq = en[0];
	assign dbg_en0_fiq = en[3];
	wire [31:0] pend_b  = src[32 * bank +: 32];
	wire [31:0] act_b   = pend_b & en[idx];

	function automatic logic [5:0] lowest(input logic [31:0] v);
		for (int i = 0; i < 32; i++)
			if (v[i]) return 6'(i + 1);
		return 6'd0;
	endfunction

	always_comb begin
		rmask = 32'd0;
		rdata = 32'd0;
		if (acc) begin
			if (is_ost) begin
				if (r == 6'h10) begin
					rmask = '1;
					rdata = {29'd0, ost_status};
				end
			end else begin
				case (r)
					6'h08: begin rmask = '1; rdata = en[idx]; end
					6'h0C: begin rmask = '1; rdata = 32'd0; end
					6'h10: begin rmask = '1; rdata = pend_b; end
					6'h14: begin rmask = '1; rdata = {26'd0, lowest(act_b)}; end
					default: ;
				endcase
			end
		end
	end

	always_ff @(posedge clk) begin
		ost_status <= ost_status | ost_set;
		if (wr) begin
			if (is_ost) begin
				if (r == 6'h04) ost_en <= wdata[2:0];
				if (r == 6'h10) ost_status <= (ost_status & ~wdata[2:0]) | ost_set;
			end else begin
				if (r == 6'h08) en[idx] <= en[idx] | wdata;
				if (r == 6'h0C) en[idx] <= en[idx] & ~wdata;
			end
		end
		if (reset) begin
			for (int i = 0; i < 6; i++) en[i] <= 32'd0;
			ost_status <= 3'd0;
			ost_en     <= 3'd0;
		end
	end


	always_ff @(posedge clk) begin
		irq <= |(src[31:0] & en[0]) | |(src[63:32] & en[1]) | |(src[95:64] & en[2]);
		fiq <= |(src[31:0] & en[3]) | |(src[63:32] & en[4]) | |(src[95:64] & en[5]) |
		       |(ost_status & ost_en);
		if (reset) begin
			irq <= 1'b0;
			fiq <= 1'b0;
		end
	end

endmodule
