module arm9v2_fetch (
	i_clk,
	i_reset,
	i_redirect,
	i_redirect_thumb,
	i_redirect_target,
	i_redirect_pointer,
	i_redirect_count,
	i_redirect_action,
	i_redirect_link,
	i_predictor_clear,
	i_update,
	i_update_pc,
	i_update_target,
	i_update_thumb,
	i_update_taken,
	i_update_hit,
	i_update_state,
	i_update_kind,
	i_data,
	i_ack,
	i_error,
	i_retry,
	i_fill_pending,
	i_fill_done,
	i_fill_fault,
	o_address_nxt,
	o_address_check,
	o_address,
	o_request,
	o_stall,
	i_ready,
	o_valid,
	o_pc,
	o_word,
	o_thumb,
	o_fault,
	o_predicted,
	o_pred_hit,
	o_pred_target,
	o_pred_state,
	o_pred_kind,
	o_ras_pointer,
	o_ras_count
);
	parameter [31:0] RESET_VECTOR = 0;
	parameter [0:0] PREDICTOR = 1'b1;
	input wire i_clk;
	input wire i_reset;
	input wire i_redirect;
	input wire i_redirect_thumb;
	input wire [31:0] i_redirect_target;
	input wire [2:0] i_redirect_pointer;
	input wire [3:0] i_redirect_count;
	input wire [1:0] i_redirect_action;
	input wire [31:0] i_redirect_link;
	input wire i_predictor_clear;
	input wire i_update;
	input wire [31:0] i_update_pc;
	input wire [31:0] i_update_target;
	input wire i_update_thumb;
	input wire i_update_taken;
	input wire i_update_hit;
	input wire [1:0] i_update_state;
	input wire [1:0] i_update_kind;
	input wire [31:0] i_data;
	input wire i_ack;
	input wire i_error;
	input wire i_retry;
	input wire i_fill_pending;
	input wire i_fill_done;
	input wire i_fill_fault;
	output wire [31:0] o_address_nxt;
	output wire [31:0] o_address_check;
	output wire [31:0] o_address;
	output wire o_request;
	output wire o_stall;
	input wire i_ready;
	output wire o_valid;
	output wire [31:0] o_pc;
	output wire [31:0] o_word;
	output wire o_thumb;
	output wire o_fault;
	output wire o_predicted;
	output wire o_pred_hit;
	output wire [31:0] o_pred_target;
	output wire [1:0] o_pred_state;
	output wire [1:0] o_pred_kind;
	output wire [2:0] o_ras_pointer;
	output wire [3:0] o_ras_count;
	(* dont_retime *) reg [35:0] f1;
	(* dont_retime *) reg [35:0] f2;
	(* dont_retime *) reg [44:0] f2_prediction;
	(* dont_retime *) reg [31:0] sequential_pc;
	(* dont_retime *) reg [31:0] restart_pc;
	(* dont_retime *) reg sequential_thumb;
	(* dont_retime *) reg restart_thumb;
	(* dont_retime *) reg killed;
	(* dont_retime *) reg [1:0] epoch;
	(* dont_retime *) reg [2:0] head;
	(* dont_retime *) reg [2:0] tail;
	(* dont_retime *) reg [3:0] count;
	reg [113:0] queue [0:7];
	wire [44:0] prediction;
	wire predicted;
	wire advance;
	wire push;
	wire pop;
	wire retry;
	wire launch_thumb;
	wire [31:0] launch_pc;
	wire unused;
	assign unused = &{1'b0, i_redirect_target[0], i_redirect_pointer, i_redirect_count, i_redirect_action, i_redirect_link, i_predictor_clear, i_update, i_update_pc, i_update_target, i_update_thumb, i_update_taken, i_update_hit, i_update_state, i_update_kind};
	assign predicted = (((PREDICTOR && prediction[44]) && f1[35]) && (f1[33-:2] == epoch)) && !killed;
	assign launch_pc = (predicted ? {prediction[42:12], 1'b0} : sequential_pc);
	assign launch_thumb = (predicted ? prediction[11] : sequential_thumb);
	assign o_address_nxt = launch_pc;
	assign o_address_check = f1[31-:32];
	assign o_address = f2[31-:32];
	assign o_request = (f2[35] && !killed) && !i_redirect;
	assign o_stall = ((count == 8) && !killed) || (f2[35] && !i_ack);
	assign advance = !o_stall;
	assign retry = (((f2[35] && i_ack) && i_retry) && !killed) && !i_redirect;
	assign push = (((((f2[35] && i_ack) && !i_retry) && advance) && !killed) && !i_redirect) && (f2[33-:2] == epoch);
	assign o_valid = ((count != 0) && !queue[head][47]) && (queue[head][46-:2] == epoch);
	assign pop = o_valid && i_ready;
	assign o_pc = queue[head][81-:32];
	assign o_word = queue[head][113-:32];
	assign o_thumb = queue[head][49];
	assign o_fault = queue[head][48];
	assign o_predicted = queue[head][44];
	assign o_pred_hit = queue[head][43];
	assign o_pred_target = queue[head][42-:32];
	assign o_pred_state = queue[head][10-:2];
	assign o_pred_kind = queue[head][8-:2];
	assign o_ras_pointer = queue[head][6-:3];
	assign o_ras_count = queue[head][3-:4];
	generate
		if (PREDICTOR) begin : g_predictor
			arm9v2_predict u_predict(
				.i_clk(i_clk),
				.i_reset(i_reset),
				.i_clear(i_predictor_clear),
				.i_lookup(advance),
				.i_pc(launch_pc),
				.i_thumb(launch_thumb),
				.i_accept((((advance && f1[35]) && !i_redirect) && !retry) && !killed),
				.i_update(i_update),
				.i_update_pc(i_update_pc),
				.i_update_target(i_update_target),
				.i_update_thumb(i_update_thumb),
				.i_update_taken(i_update_taken),
				.i_update_hit(i_update_hit),
				.i_update_state(i_update_state),
				.i_update_kind(i_update_kind),
				.i_repair(i_redirect || retry),
				.i_repair_pointer((i_redirect ? i_redirect_pointer : f2_prediction[6-:3])),
				.i_repair_count((i_redirect ? i_redirect_count : f2_prediction[3-:4])),
				.i_repair_action((i_redirect ? i_redirect_action : 2'd0)),
				.i_repair_link(i_redirect_link),
				.o_hit(prediction[43]),
				.o_taken(prediction[44]),
				.o_target(prediction[42-:32]),
				.o_state(prediction[10-:2]),
				.o_kind(prediction[8-:2]),
				.o_pointer(prediction[6-:3]),
				.o_count(prediction[3-:4])
			);
		end
		else begin : g_no_predictor
			assign prediction = 45'd0;
		end
	endgenerate
	genvar _gv_q_1;
	generate
		for (_gv_q_1 = 0; _gv_q_1 < 8; _gv_q_1 = _gv_q_1 + 1) begin : g_queue
			localparam q = _gv_q_1;
			always @(posedge i_clk)
				if (push && (tail == q)) begin
					queue[q][113-:32] <= i_data;
					queue[q][81-:32] <= f2[31-:32];
					queue[q][49] <= f2[34];
					queue[q][46-:2] <= f2[33-:2];
					queue[q][48] <= i_error || (i_fill_pending && i_fill_fault);
					queue[q][47] <= i_fill_pending && !i_fill_done;
					queue[q][44-:45] <= f2_prediction;
				end
				else if (i_fill_done) begin
					queue[q][47] <= 0;
					if (queue[q][47])
						queue[q][48] <= queue[q][48] || i_fill_fault;
				end
		end
	endgenerate
	always @(posedge i_clk)
		if (i_reset) begin
			f1 <= 36'd0;
			f2 <= 36'd0;
			f2_prediction <= 45'd0;
			sequential_pc <= RESET_VECTOR;
			sequential_thumb <= 0;
			restart_pc <= RESET_VECTOR;
			restart_thumb <= 0;
			killed <= 0;
			epoch <= 0;
			head <= 0;
			tail <= 0;
			count <= 0;
		end
		else begin
			if (pop)
				head <= head + 1'b1;
			if (push)
				tail <= tail + 1'b1;
			case ({push, pop})
				2'b10: count <= count + 1'b1;
				2'b01: count <= count - 1'b1;
				default:
					;
			endcase
			if (advance) begin
				f1 <= {1'b1, launch_thumb, epoch, launch_pc};
				f2 <= f1;
				f2_prediction <= prediction;
				f2_prediction[44] <= predicted;
				sequential_pc <= launch_pc + (launch_thumb ? 32'd2 : 32'd4);
				sequential_thumb <= launch_thumb;
				if ((i_redirect || retry) || killed) begin
					f1[35] <= 0;
					f2[35] <= 0;
					sequential_pc <= (i_redirect ? {i_redirect_target[31:1], 1'b0} : (retry ? f2[31-:32] : restart_pc));
					sequential_thumb <= (i_redirect ? i_redirect_thumb : (retry ? f2[34] : restart_thumb));
				end
			end
			if (i_redirect) begin
				epoch <= epoch + 1'b1;
				head <= 0;
				tail <= 0;
				count <= 0;
				killed <= o_stall;
				restart_pc <= {i_redirect_target[31:1], 1'b0};
				restart_thumb <= i_redirect_thumb;
			end
			else if (retry) begin
				killed <= o_stall;
				restart_pc <= f2[31-:32];
				restart_thumb <= f2[34];
			end
			else if (advance && killed)
				killed <= 0;
		end
endmodule
module arm9v2_predict (
	i_clk,
	i_reset,
	i_clear,
	i_lookup,
	i_pc,
	i_thumb,
	i_accept,
	i_update,
	i_update_pc,
	i_update_target,
	i_update_thumb,
	i_update_taken,
	i_update_hit,
	i_update_state,
	i_update_kind,
	i_repair,
	i_repair_pointer,
	i_repair_count,
	i_repair_action,
	i_repair_link,
	o_hit,
	o_taken,
	o_target,
	o_state,
	o_kind,
	o_pointer,
	o_count
);
	reg _sv2v_0;
	parameter integer ENTRIES = 256;
	localparam integer INDEX_W = $clog2(ENTRIES);
	localparam integer TAG_W = 31 - INDEX_W;
	input wire i_clk;
	input wire i_reset;
	input wire i_clear;
	input wire i_lookup;
	input wire [31:0] i_pc;
	input wire i_thumb;
	input wire i_accept;
	input wire i_update;
	input wire [31:0] i_update_pc;
	input wire [31:0] i_update_target;
	input wire i_update_thumb;
	input wire i_update_taken;
	input wire i_update_hit;
	input wire [1:0] i_update_state;
	input wire [1:0] i_update_kind;
	input wire i_repair;
	input wire [2:0] i_repair_pointer;
	input wire [3:0] i_repair_count;
	input wire [1:0] i_repair_action;
	input wire [31:0] i_repair_link;
	output wire o_hit;
	output wire o_taken;
	output wire [31:0] o_target;
	output wire [1:0] o_state;
	output wire [1:0] o_kind;
	output wire [2:0] o_pointer;
	output wire [3:0] o_count;
	localparam [1:0] CALL = 1;
	localparam [1:0] RETURN = 2;
	reg [TAG_W + 36:0] write_entry;
	wire [TAG_W + 36:0] read_entry;
	reg [ENTRIES - 1:0] valid;
	(* dont_retime *) reg read_valid;
	(* dont_retime *) reg read_thumb;
	(* dont_retime *) reg [31:0] read_pc;
	(* dont_retime *) reg [2:0] pointer;
	(* dont_retime *) reg [3:0] count;
	reg [31:0] stack [0:7];
	reg [1:0] update_state;
	wire write_enable = (i_update && !i_reset) && !i_clear;
	wire [INDEX_W - 1:0] rd_index = i_pc[INDEX_W:1];
	wire [INDEX_W - 1:0] wr_index = i_update_pc[INDEX_W:1];
	wire unused = &{1'b0, i_pc[0], i_update_pc[0]};
	always @(*) begin
		if (_sv2v_0)
			;
		update_state = (i_update_hit ? i_update_state : 2'b01);
		if (i_update_taken) begin
			if (update_state != 2'b11)
				update_state = update_state + 1'b1;
		end
		else if (update_state != 2'b00)
			update_state = update_state - 1'b1;
		write_entry = {i_update_pc[31:INDEX_W + 1], i_update_thumb, i_update_target, update_state, i_update_kind};
	end
	zap_ram_simple_nopipe #(
		.WIDTH(((TAG_W + 36) >= 0 ? TAG_W + 37 : 1 - (TAG_W + 36))),
		.DEPTH(ENTRIES),
		.HOLD_READ(1'b1)
	) u_entries(
		.i_clk(i_clk),
		.i_wr_en(write_enable),
		.i_rd_en(i_lookup),
		.i_wr_data(write_entry),
		.i_wr_addr(wr_index),
		.i_rd_addr(rd_index),
		.o_rd_data(read_entry)
	);
	always @(posedge i_clk) begin
		if (i_reset || i_clear) begin
			valid <= {ENTRIES {1'b0}};
			read_valid <= 0;
		end
		else begin
			if (write_enable)
				valid[wr_index] <= 1;
			if (i_lookup)
				read_valid <= valid[rd_index] || (write_enable && (rd_index == wr_index));
		end
		if (i_lookup) begin
			read_pc <= i_pc;
			read_thumb <= i_thumb;
		end
	end
	assign o_hit = (read_valid && (read_entry[TAG_W + 36-:((TAG_W + 36) >= 37 ? TAG_W + 0 : 38 - (TAG_W + 36))] == read_pc[31:INDEX_W + 1])) && (read_entry[36] == read_thumb);
	assign o_taken = o_hit && read_entry[3];
	assign o_target = ((read_entry[1-:2] == RETURN) && (count != 0) ? stack[pointer - 1'b1] : read_entry[35-:32]);
	assign o_state = (o_hit ? read_entry[3-:2] : 2'b01);
	assign o_kind = read_entry[1-:2];
	assign o_pointer = pointer;
	assign o_count = count;
	always @(posedge i_clk)
		if (i_reset || i_clear) begin
			pointer <= 0;
			count <= 0;
		end
		else if (i_repair) begin
			pointer <= i_repair_pointer;
			count <= i_repair_count;
			case (i_repair_action)
				CALL: begin
					stack[i_repair_pointer] <= i_repair_link;
					pointer <= i_repair_pointer + 1'b1;
					count <= (i_repair_count == 8 ? 4'd8 : i_repair_count + 1'b1);
				end
				RETURN:
					if (i_repair_count != 0) begin
						pointer <= i_repair_pointer - 1'b1;
						count <= i_repair_count - 1'b1;
					end
				2'd3: begin
					pointer <= 0;
					count <= 0;
				end
				default:
					;
			endcase
		end
		else if (i_accept && o_taken)
			case (read_entry[1-:2])
				CALL: begin
					stack[pointer] <= (read_pc + (read_thumb ? 32'd2 : 32'd4)) | {31'd0, read_thumb};
					pointer <= pointer + 1'b1;
					if (count != 8)
						count <= count + 1'b1;
				end
				RETURN:
					if (count != 0) begin
						pointer <= pointer - 1'b1;
						count <= count - 1'b1;
					end
				default:
					;
			endcase
	initial _sv2v_0 = 0;
endmodule
module zap_ram_simple_nopipe (
	i_clk,
	i_wr_en,
	i_rd_en,
	i_wr_data,
	i_wr_addr,
	i_rd_addr,
	o_rd_data
);
	parameter [31:0] WIDTH = 32'd32;
	parameter [31:0] DEPTH = 32'd32;
	parameter [0:0] HOLD_READ = 1'b0;
	input wire i_clk;
	input wire i_wr_en;
	input wire i_rd_en;
	input wire [WIDTH - 1:0] i_wr_data;
	input wire [$clog2(DEPTH) - 1:0] i_wr_addr;
	input wire [$clog2(DEPTH) - 1:0] i_rd_addr;
	output wire [WIDTH - 1:0] o_rd_data;
	reg [WIDTH - 1:0] mem [DEPTH - 1:0];
	(* dont_retime *) reg [WIDTH - 1:0] mem_rd_data;
	always @(posedge i_clk)
		if (i_rd_en)
			mem_rd_data <= mem[i_rd_addr];
	always @(posedge i_clk)
		if (i_wr_en)
			mem[i_wr_addr] <= i_wr_data;
	(* dont_retime *) reg [WIDTH - 1:0] buffer_ff;
	wire [WIDTH - 1:0] buffer_nxt;
	(* dont_retime *) reg hazard_ff;
	wire hazard_nxt;
	wire addr_conflict;
	wire concurrent_access;
	assign addr_conflict = (i_wr_addr == i_rd_addr ? 1'd1 : 1'd0);
	assign concurrent_access = i_wr_en & i_rd_en;
	assign hazard_nxt = addr_conflict & concurrent_access;
	always @(posedge i_clk)
		if (!HOLD_READ || i_rd_en)
			hazard_ff <= hazard_nxt;
	assign buffer_nxt = (hazard_nxt ? i_wr_data : {WIDTH {1'bx}});
	always @(posedge i_clk)
		if (!HOLD_READ || i_rd_en)
			buffer_ff <= buffer_nxt;
	assign o_rd_data = (hazard_ff ? buffer_ff : mem_rd_data);
endmodule
module cpu_trial (
	clk,
	serial_in,
	address_o,
	word_o,
	trace_o
);
	input wire clk;
	input wire [31:0] serial_in;
	output reg [31:0] address_o;
	output reg [31:0] word_o;
	output reg [31:0] trace_o;
	(* dont_retime *) reg [319:0] control;
	wire [31:0] address_next;
	wire [31:0] address_check;
	wire [31:0] address;
	wire [31:0] pc;
	wire [31:0] word_data;
	wire [31:0] pred_target;
	wire request;
	wire stall;
	wire valid;
	wire thumb;
	wire fault;
	wire predicted;
	wire pred_hit;
	wire [1:0] pred_state;
	wire [1:0] pred_kind;
	wire [2:0] ras_pointer;
	wire [3:0] ras_count;
	wire unused = &{1'b0, control[319:188]};
	always @(posedge clk) begin
		control <= {control[287:0], serial_in};
		address_o <= address_next;
		word_o <= word_data;
		trace_o <= (((pc ^ address_check) ^ address) ^ pred_target) ^ {13'd0, ras_count, ras_pointer, pred_state, pred_kind, request, stall, valid, thumb, fault, predicted, pred_hit, 1'b0};
	end
	arm9v2_fetch u_frontend(
		.i_clk(clk),
		.i_reset(control[0]),
		.i_redirect(control[1]),
		.i_redirect_thumb(control[2]),
		.i_redirect_target(control[34:3]),
		.i_redirect_pointer(control[37:35]),
		.i_redirect_count(control[41:38]),
		.i_redirect_action(control[43:42]),
		.i_redirect_link(control[75:44]),
		.i_predictor_clear(control[76]),
		.i_update(control[77]),
		.i_update_pc(control[109:78]),
		.i_update_target(control[141:110]),
		.i_update_thumb(control[142]),
		.i_update_taken(control[143]),
		.i_update_hit(control[144]),
		.i_update_state(control[146:145]),
		.i_update_kind(control[148:147]),
		.i_data(control[180:149]),
		.i_ack(control[181]),
		.i_error(control[182]),
		.i_retry(control[183]),
		.i_fill_pending(control[184]),
		.i_fill_done(control[185]),
		.i_fill_fault(control[186]),
		.i_ready(control[187]),
		.o_address_nxt(address_next),
		.o_address_check(address_check),
		.o_address(address),
		.o_request(request),
		.o_stall(stall),
		.o_valid(valid),
		.o_pc(pc),
		.o_word(word_data),
		.o_thumb(thumb),
		.o_fault(fault),
		.o_predicted(predicted),
		.o_pred_hit(pred_hit),
		.o_pred_target(pred_target),
		.o_pred_state(pred_state),
		.o_pred_kind(pred_kind),
		.o_ras_pointer(ras_pointer),
		.o_ras_count(ras_count)
	);
endmodule
