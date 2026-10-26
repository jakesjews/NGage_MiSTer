// SPDX-License-Identifier: GPL-2.0-or-later
//
// Hardware trace for debugging the core on the MiSTer: ring buffers in
// block RAM of what the CPU did lately, written to DDR3 when something goes
// wrong, where the MiSTer's Linux side can read them (tools/mister_trace.py
// fetches a dump through /dev/mem and decodes it). Three rings:
//   * the CPU's writeback stage: every instruction that retires, and every
//     exception taken in its place, with the stage's PC (the instruction's
//     address + 8, or + 4 in Thumb), the CPSR before and after it, the event
//     and the low 16 bits of the clock;
//   * the CPU's data port: every access the data cache answers (a hit or a
//     miss alike), with its virtual address, the data read or written, the
//     byte select, the direction and the clock;
//   * the Wishbone port: every beat the memory system acknowledges, with the
//     address, the data, the select, the direction, err and CTI.
// A trigger (an abort or an undefined-instruction exception retiring, or
// trig_in) stops the rings, writes them to DDR3 at BASE + n * DUMP_WORDS
// through the loader port (one 64-bit write a word, as ddram_loader does)
// and starts them again. MAX_DUMPS dumps at most; later triggers are only
// counted. The clock counts from the CPU leaving reset, which also empties
// the rings.
//
// A dump, in 64-bit words (little-endian, as the HPS reads DDR3):
//   0x0000        "NGAGETRC"
//   0x0001        the clock at the trigger
//   0x0002        {dump[7:0], reason[7:0], pc_wptr[15:0], d_wptr[15:0],
//                  b_wptr[15:0]}
//   0x0003        {retired[31:0], triggers[31:0]}
//   0x0004        {data accesses[31:0], bus beats[31:0]}
//   0x0005        {32'b0, the trigger's PC (the stage's value)}
//   0x2000 + i    PC ring entry i: {cpsr after[31:28], ev[3:0], clock[15:0],
//                 cpsr before[7:0], pc[31:0]}
//   0x4000 + 2i   data ring entry i: {clock[31:0], va[31:0]},
//                 {data[31:0], 15'b0, we, 4'b0, sel[3:0], 8'b0}
//   0x6000 + 2i   bus ring entry i: {clock[31:0], adr[31:0]},
//                 {data[31:0], 12'b0, err, we, 2'b0, cti[2:0], 1'b0, sel[3:0],
//                  8'b0}
// Events: 1 retired, 2 SWI, 3 undefined, 4 prefetch abort, 5 data abort,
// 6 IRQ, 7 FIQ. Reason bits: 0 an exception, 1 trig_in. A write pointer is
// the entry written next, the ring's oldest.
module dbg_trace #(
	parameter logic [28:0] BASE      = 29'h0660_0000,   // 0x33000000 / 8
	parameter int          MAX_DUMPS = 4
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        cpu_reset,

	// the writeback stage (rtl/cpu/arm925t.sv dbg_wb_*)
	input  logic        wb_valid,
	input  logic        wb_dvalid,
	input  logic        wb_uop_last,
	input  logic [1:0]  wb_dabt,
	input  logic        wb_pabt,
	input  logic        wb_und,
	input  logic        wb_swi,
	input  logic        wb_irq,
	input  logic        wb_fiq,
	input  logic [31:0] wb_pc,
	input  logic [31:0] wb_cpsr,
	input  logic [31:0] wb_cpsr_nxt,

	// the data port: an access completes in a clock with d_done high
	input  logic        d_done,
	input  logic        d_we,
	input  logic [31:0] d_va,
	input  logic [3:0]  d_sel,
	input  logic [31:0] d_wdata,
	input  logic [31:0] d_rdata,

	// the Wishbone port
	input  logic        b_ack,
	input  logic        b_err,
	input  logic        b_we,
	input  logic [31:0] b_adr,
	input  logic [3:0]  b_sel,
	input  logic [2:0]  b_cti,
	input  logic [31:0] b_wdata,
	input  logic [31:0] b_rdata,

	input  logic        trig_in,

	// the loader port (ddram_flash through ngage_mem): a write is held until
	// a clock in which ld_busy is low
	output logic        ld_we,
	output logic [28:0] ld_addr,
	output logic [63:0] ld_din,
	output logic [7:0]  ld_be,
	input  logic        ld_busy,

	output logic [7:0]  dumps,
	output logic [7:0]  triggers,
	output logic        dumping,
	output logic [31:0] trig_pc       // the first trigger's PC
);

	localparam int PC_LOG2 = 9;
	localparam int D_LOG2  = 7;
	localparam int B_LOG2  = 7;
	localparam logic [28:0] DUMP_WORDS = 29'h8000;
	localparam logic [28:0] PC_OFF = 29'h2000;
	localparam logic [28:0] D_OFF  = 29'h4000;
	localparam logic [28:0] B_OFF  = 29'h6000;

	// ------------------------------------------------------------------
	// Stage 1: the taps, registered (they come from pipeline registers and
	// the bus with other loads)
	// ------------------------------------------------------------------
	logic [3:0] ev_c;
	always_comb begin
		if (wb_dabt[1])                                  ev_c = 4'd0;
		else if (wb_dabt[0])                             ev_c = 4'd5;
		else if (wb_fiq)                                 ev_c = 4'd7;
		else if (wb_irq)                                 ev_c = 4'd6;
		else if (wb_pabt)                                ev_c = 4'd4;
		else if (wb_swi)                                 ev_c = 4'd2;
		else if (wb_und)                                 ev_c = 4'd3;
		else if ((wb_valid || wb_dvalid) && wb_uop_last) ev_c = 4'd1;
		else                                             ev_c = 4'd0;
	end

	logic        s_run = 1'b0;
	logic [3:0]  s_ev = 4'd0;
	logic [31:0] s_pc;
	logic [7:0]  s_cpsr;       // mode, T, I, F
	logic [3:0]  s_flags_nxt;  // N Z C V after
	logic        s_d_done = 1'b0, s_d_we;
	logic [31:0] s_d_va, s_d_data;
	logic [3:0]  s_d_sel;
	logic        s_b_ack = 1'b0, s_b_err, s_b_we;
	logic [31:0] s_b_adr, s_b_data;
	logic [3:0]  s_b_sel;
	logic [2:0]  s_b_cti;
	logic        s_trig = 1'b0;

	always_ff @(posedge clk) begin
		s_run      <= !cpu_reset && !reset;
		s_ev       <= ev_c;
		s_pc       <= wb_pc;
		s_cpsr     <= wb_cpsr[7:0];
		s_flags_nxt <= wb_cpsr_nxt[31:28];
		s_d_done   <= d_done;
		s_d_we     <= d_we;
		s_d_va     <= d_va;
		s_d_data   <= d_we ? d_wdata : d_rdata;
		s_d_sel    <= d_sel;
		s_b_ack    <= b_ack;
		s_b_err    <= b_err;
		s_b_we     <= b_we;
		s_b_adr    <= b_adr;
		s_b_data   <= b_we ? b_wdata : b_rdata;
		s_b_sel    <= b_sel;
		s_b_cti    <= b_cti;
		s_trig     <= trig_in;
	end

	// ------------------------------------------------------------------
	// Stage 2: the rings
	// ------------------------------------------------------------------
	logic [39:0]        clk_cnt = '0;
	logic               frozen = 1'b0;
	logic [PC_LOG2-1:0] pc_w = '0;
	logic [D_LOG2-1:0]  d_w = '0;
	logic [B_LOG2-1:0]  b_w = '0;
	logic [31:0]        retired = '0, d_cnt = '0, b_cnt = '0;

	wire tracing /* verilator public_flat_rd */ = s_run && !frozen;   // (the bench watches it)
	wire pc_we   = tracing && s_ev != 4'd0;
	wire d_we_r  = tracing && s_d_done;
	wire b_we_r  = tracing && s_b_ack;

	wire [63:0]  pc_entry = {s_flags_nxt, s_ev, clk_cnt[15:0], s_cpsr, s_pc};
	wire [127:0] d_entry  = {clk_cnt[31:0], s_d_va, s_d_data, 15'b0, s_d_we, 4'b0, s_d_sel, 8'b0};
	wire [127:0] b_entry  = {clk_cnt[31:0], s_b_adr, s_b_data, 12'b0, s_b_err, s_b_we, 2'b0, s_b_cti, 1'b0, s_b_sel, 8'b0};

	logic [PC_LOG2-1:0] pc_raddr;
	logic [D_LOG2-1:0]  d_raddr;
	logic [B_LOG2-1:0]  b_raddr;
	logic [63:0]        pc_q;
	logic [127:0]       d_q, b_q;

	sdp_ram #(.AW(PC_LOG2), .DW(64)) pc_ring (
		.clk(clk), .we(pc_we), .waddr(pc_w), .wdata(pc_entry), .raddr(pc_raddr), .rdata(pc_q)
	);
	sdp_ram #(.AW(D_LOG2), .DW(128)) d_ring (
		.clk(clk), .we(d_we_r), .waddr(d_w), .wdata(d_entry), .raddr(d_raddr), .rdata(d_q)
	);
	sdp_ram #(.AW(B_LOG2), .DW(128)) b_ring (
		.clk(clk), .we(b_we_r), .waddr(b_w), .wdata(b_entry), .raddr(b_raddr), .rdata(b_q)
	);

	// a trigger: an exception the firmware never takes when all is well
	wire exc_trig = s_run && (s_ev == 4'd3 || s_ev == 4'd4 || s_ev == 4'd5);
	wire trig     = exc_trig || (s_run && s_trig);

	always_ff @(posedge clk) begin
		if (!s_run) begin
			clk_cnt <= '0;
			pc_w    <= '0;
			d_w     <= '0;
			b_w     <= '0;
			retired <= '0;
			d_cnt   <= '0;
			b_cnt   <= '0;
		end else begin
			clk_cnt <= clk_cnt + 40'd1;
			if (pc_we) begin
				pc_w <= pc_w + 1'd1;
				if (s_ev == 4'd1) retired <= retired + 32'd1;
			end
			if (d_we_r) begin
				d_w   <= d_w + 1'd1;
				d_cnt <= d_cnt + 32'd1;
			end
			if (b_we_r) begin
				b_w   <= b_w + 1'd1;
				b_cnt <= b_cnt + 32'd1;
			end
		end
	end

	// ------------------------------------------------------------------
	// The dump
	// ------------------------------------------------------------------
	typedef enum logic [2:0] {
		T_RUN,
		T_ADDR,
		T_READ,
		T_LATCH,
		T_WRITE,
		T_NEXT
	} state_t;

	state_t      state = T_RUN;
	logic [1:0]  seg;
	logic [12:0] idx;
	logic [39:0] trig_clk;
	logic [7:0]  reason;
	logic [15:0] h_pc_w, h_d_w, h_b_w;
	logic [31:0] h_retired, h_d_cnt, h_b_cnt, h_trig_pc;
	logic [63:0] ld_din_q;
	logic [28:0] ld_addr_q;

	assign dumping = state != T_RUN;
	assign ld_we   = state == T_WRITE;
	assign ld_din  = ld_din_q;
	assign ld_addr = ld_addr_q;
	assign ld_be   = 8'hFF;

	assign pc_raddr = idx[PC_LOG2-1:0];
	assign d_raddr  = idx[D_LOG2:1];
	assign b_raddr  = idx[B_LOG2:1];

	wire [12:0] seg_last = (seg == 2'd0) ? 13'd7 :
	                       (seg == 2'd1) ? 13'h1FFF :
	                       (seg == 2'd2) ? 13'h1FFF : 13'h0FFF;
	wire [28:0] seg_off  = (seg == 2'd0) ? 29'd0 :
	                       (seg == 2'd1) ? PC_OFF :
	                       (seg == 2'd2) ? D_OFF : B_OFF;

	logic [63:0] header;
	always_comb begin
		case (idx[2:0])
			3'd0:    header = 64'h4352_5445_4741_474E;   // "NGAGETRC"
			3'd1:    header = {24'b0, trig_clk};
			3'd2:    header = {dumps, reason, h_pc_w, h_d_w, h_b_w};
			3'd3:    header = {h_retired, triggers, 24'b0};
			3'd4:    header = {h_d_cnt, h_b_cnt};
			3'd5:    header = {32'b0, h_trig_pc};
			default: header = 64'b0;
		endcase
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			state    <= T_RUN;
			frozen   <= 1'b0;
			dumps    <= 8'd0;
			triggers <= 8'd0;
			trig_pc  <= 32'd0;
		end else begin
			if (trig) begin
				triggers <= triggers + 8'd1;
				if (triggers == 8'd0) trig_pc <= s_pc;
			end

			case (state)
				T_RUN: begin
					if (trig && dumps < 8'(MAX_DUMPS)) begin
						frozen    <= 1'b1;
						trig_clk  <= clk_cnt;
						reason    <= {6'b0, s_trig, exc_trig};
						h_pc_w    <= 16'(pc_w) + (pc_we ? 16'd1 : 16'd0);
						h_d_w     <= 16'(d_w) + (d_we_r ? 16'd1 : 16'd0);
						h_b_w     <= 16'(b_w) + (b_we_r ? 16'd1 : 16'd0);
						h_retired <= retired;
						h_d_cnt   <= d_cnt;
						h_b_cnt   <= b_cnt;
						h_trig_pc <= s_pc;
						seg       <= 2'd0;
						idx       <= 13'd0;
						state     <= T_ADDR;
					end
				end
				T_ADDR:  state <= T_READ;      // the ring RAMs read idx
				T_READ:  state <= T_LATCH;     // their outputs land
				T_LATCH: begin
					ld_din_q  <= (seg == 2'd0) ? header :
					             (seg == 2'd1) ? pc_q :
					             (seg == 2'd2) ? (idx[0] ? d_q[63:0] : d_q[127:64]) :
					                             (idx[0] ? b_q[63:0] : b_q[127:64]);
					ld_addr_q <= BASE + 29'(dumps) * DUMP_WORDS + seg_off + 29'(idx);
					state     <= T_WRITE;
				end
				T_WRITE: if (!ld_busy) state <= T_NEXT;
				T_NEXT: begin
					if (idx != seg_last) begin
						idx   <= idx + 13'd1;
						state <= T_ADDR;
					end else if (seg != 2'd3) begin
						seg   <= seg + 2'd1;
						idx   <= 13'd0;
						state <= T_ADDR;
					end else begin
						dumps  <= dumps + 8'd1;
						frozen <= 1'b0;
						state  <= T_RUN;
					end
				end
				default: state <= T_RUN;
			endcase
		end
	end

endmodule
