module arm9v2_decode (
	i_clk,
	i_reset,
	i_flush,
	i_valid,
	o_ready,
	i_pc,
	i_word,
	i_thumb,
	i_fault,
	i_mode,
	i_predicted,
	i_pred_hit,
	i_pred_target,
	i_pred_state,
	i_pred_kind,
	i_ras_pointer,
	i_ras_count,
	i_wen,
	i_wr_addr_a,
	i_wr_addr_b,
	i_wr_addr_c,
	i_locked,
	i_early_tag,
	i_early_valid,
	i_wr_data_a,
	i_wr_data_b,
	i_wr_data_c,
	i_ready,
	o_valid,
	o_pc,
	o_instruction,
	o_pc_base,
	o_next_pc,
	o_raw,
	o_mode,
	o_thumb,
	o_fault,
	o_force_align,
	o_reg_shift,
	o_kind,
	o_condition,
	o_tag,
	o_used,
	o_value,
	o_dest,
	o_first,
	o_last,
	o_reg_count,
	o_offset,
	o_writeback_offset,
	o_transfer_reg,
	o_branch_target,
	o_direct,
	o_match_taken,
	o_match_fallthrough,
	o_predicted,
	o_pred_hit,
	o_pred_target,
	o_pred_state,
	o_pred_kind,
	o_ras_pointer,
	o_ras_count,
	o_hazard,
	o_redirect,
	o_redirect_thumb,
	o_redirect_target,
	o_redirect_link,
	o_redirect_pointer,
	o_redirect_count,
	o_redirect_action
);
	reg _sv2v_0;
	input wire i_clk;
	input wire i_reset;
	input wire i_flush;
	input wire i_valid;
	output wire o_ready;
	input wire [31:0] i_pc;
	input wire [31:0] i_word;
	input wire i_thumb;
	input wire i_fault;
	input wire [4:0] i_mode;
	input wire i_predicted;
	input wire i_pred_hit;
	input wire [31:0] i_pred_target;
	input wire [1:0] i_pred_state;
	input wire [1:0] i_pred_kind;
	input wire [2:0] i_ras_pointer;
	input wire [3:0] i_ras_count;
	input wire i_wen;
	input wire [39:0] i_wr_addr_a;
	input wire [39:0] i_wr_addr_b;
	input wire [39:0] i_wr_addr_c;
	input wire [39:0] i_locked;
	input wire [23:0] i_early_tag;
	input wire [3:0] i_early_valid;
	input wire [31:0] i_wr_data_a;
	input wire [31:0] i_wr_data_b;
	input wire [31:0] i_wr_data_c;
	input wire i_ready;
	output wire o_valid;
	output wire [31:0] o_pc;
	output wire [31:0] o_instruction;
	output wire [31:0] o_pc_base;
	output wire [31:0] o_next_pc;
	output wire [15:0] o_raw;
	output wire [4:0] o_mode;
	output wire o_thumb;
	output wire o_fault;
	output wire o_force_align;
	output wire o_reg_shift;
	output wire [3:0] o_kind;
	output wire [3:0] o_condition;
	output wire [23:0] o_tag;
	output wire [3:0] o_used;
	output wire [127:0] o_value;
	output wire [11:0] o_dest;
	output wire o_first;
	output wire o_last;
	output wire [4:0] o_reg_count;
	output wire signed [7:0] o_offset;
	output wire signed [7:0] o_writeback_offset;
	output wire [3:0] o_transfer_reg;
	output wire [31:0] o_branch_target;
	output wire o_direct;
	output wire o_match_taken;
	output wire o_match_fallthrough;
	output wire o_predicted;
	output wire o_pred_hit;
	output wire [31:0] o_pred_target;
	output wire [1:0] o_pred_state;
	output wire [1:0] o_pred_kind;
	output wire [2:0] o_ras_pointer;
	output wire [3:0] o_ras_count;
	output wire o_hazard;
	output wire o_redirect;
	output wire o_redirect_thumb;
	output wire [31:0] o_redirect_target;
	output wire [31:0] o_redirect_link;
	output wire [2:0] o_redirect_pointer;
	output wire [3:0] o_redirect_count;
	output wire [1:0] o_redirect_action;
	localparam [3:0] K_DP = 0;
	localparam [3:0] K_MRS = 1;
	localparam [3:0] K_MSR = 2;
	localparam [3:0] K_BRANCH = 3;
	localparam [3:0] K_BX = 4;
	localparam [3:0] K_MEM = 5;
	localparam [3:0] K_BLOCK = 6;
	localparam [3:0] K_CP = 7;
	localparam [3:0] K_UND = 8;
	localparam [3:0] K_SWI = 9;
	localparam [3:0] K_BL_PREFIX = 10;
	localparam [3:0] K_BL_SUFFIX = 11;
	localparam [3:0] K_SWP = 12;
	localparam [3:0] K_MUL = 13;
	localparam [3:0] K_MULL = 14;
	(* dont_retime *) reg [74:0] redirect_ff;
	(* dont_retime *) reg redirect_in_d2;
	(* dont_retime, ramstyle = "logic" *) reg [240:0] d1 [0:1];
	(* dont_retime *) reg tail;
	(* dont_retime *) reg [1:0] head_select;
	(* dont_retime *) reg [1:0] count;
	(* dont_retime *) reg d2_valid;
	(* dont_retime *) reg out_valid;
	(* dont_retime *) reg [366:0] d2;
	(* dont_retime *) reg [366:0] issued;
	(* dont_retime *) reg [127:0] values;
	(* dont_retime *) reg matches_taken;
	(* dont_retime *) reg matches_fallthrough;
	(* dont_retime *) reg previous_prefix;
	(* dont_retime *) reg prefix_valid;
	(* dont_retime *) reg [31:0] previous_next_pc;
	(* dont_retime *) reg [31:0] prefix_target;
	reg [240:0] incoming;
	wire [240:0] front;
	reg [366:0] decoded;
	reg [366:0] fast_branch;
	wire [366:0] admitted;
	wire [31:0] raw_word;
	wire [34:0] expanded;
	wire thumb_und;
	wire thumb_align;
	reg [15:0] reg_list;
	wire [15:0] next_remaining;
	wire [3:0] next_register;
	reg [31:0] suffix_base;
	reg [4:0] transfer_mode;
	wire [127:0] raw_values;
	reg [127:0] read_values;
	wire push;
	wire pop;
	wire accept;
	wire shortcut;
	wire fast_select;
	wire new_d2;
	wire late_redirect;
	wire step;
	wire kill_younger;
	wire taken_match;
	wire fallthrough_match;
	reg [3:0] early_used;
	reg [3:0] early_hazard;
	wire unused;
	assign unused = &{1'b0, expanded[33:32], issued[40-:5], issued[35-:16], issued[41], fast_arm_twos[31], fast_thumb_twos[31]};
	function automatic [2:0] count6;
		input reg [5:0] v;
		case (v)
			6'd0: count6 = 3'd0;
			6'd1: count6 = 3'd1;
			6'd2: count6 = 3'd1;
			6'd3: count6 = 3'd2;
			6'd4: count6 = 3'd1;
			6'd5: count6 = 3'd2;
			6'd6: count6 = 3'd2;
			6'd7: count6 = 3'd3;
			6'd8: count6 = 3'd1;
			6'd9: count6 = 3'd2;
			6'd10: count6 = 3'd2;
			6'd11: count6 = 3'd3;
			6'd12: count6 = 3'd2;
			6'd13: count6 = 3'd3;
			6'd14: count6 = 3'd3;
			6'd15: count6 = 3'd4;
			6'd16: count6 = 3'd1;
			6'd17: count6 = 3'd2;
			6'd18: count6 = 3'd2;
			6'd19: count6 = 3'd3;
			6'd20: count6 = 3'd2;
			6'd21: count6 = 3'd3;
			6'd22: count6 = 3'd3;
			6'd23: count6 = 3'd4;
			6'd24: count6 = 3'd2;
			6'd25: count6 = 3'd3;
			6'd26: count6 = 3'd3;
			6'd27: count6 = 3'd4;
			6'd28: count6 = 3'd3;
			6'd29: count6 = 3'd4;
			6'd30: count6 = 3'd4;
			6'd31: count6 = 3'd5;
			6'd32: count6 = 3'd1;
			6'd33: count6 = 3'd2;
			6'd34: count6 = 3'd2;
			6'd35: count6 = 3'd3;
			6'd36: count6 = 3'd2;
			6'd37: count6 = 3'd3;
			6'd38: count6 = 3'd3;
			6'd39: count6 = 3'd4;
			6'd40: count6 = 3'd2;
			6'd41: count6 = 3'd3;
			6'd42: count6 = 3'd3;
			6'd43: count6 = 3'd4;
			6'd44: count6 = 3'd3;
			6'd45: count6 = 3'd4;
			6'd46: count6 = 3'd4;
			6'd47: count6 = 3'd5;
			6'd48: count6 = 3'd2;
			6'd49: count6 = 3'd3;
			6'd50: count6 = 3'd3;
			6'd51: count6 = 3'd4;
			6'd52: count6 = 3'd3;
			6'd53: count6 = 3'd4;
			6'd54: count6 = 3'd4;
			6'd55: count6 = 3'd5;
			6'd56: count6 = 3'd3;
			6'd57: count6 = 3'd4;
			6'd58: count6 = 3'd4;
			6'd59: count6 = 3'd5;
			6'd60: count6 = 3'd4;
			6'd61: count6 = 3'd5;
			6'd62: count6 = 3'd5;
			6'd63: count6 = 3'd6;
		endcase
	endfunction
	function automatic [4:0] popcount16;
		input reg [15:0] v;
		reg [2:0] a;
		reg [2:0] b;
		reg [2:0] c;
		reg [2:0] ones;
		reg [2:0] twos;
		begin
			a = count6(v[5:0]);
			b = count6(v[11:6]);
			c = count6({2'b00, v[15:12]});
			ones = (a ^ b) ^ c;
			twos = ((a & b) | (a & c)) | (b & c);
			popcount16 = {2'b00, ones} + {1'b0, twos, 1'b0};
		end
	endfunction
	function automatic [15:0] clear_first;
		input reg [15:0] v;
		reg [15:0] result;
		begin
			begin : sv2v_autoblock_1
				reg signed [31:0] n;
				for (n = 0; n < 16; n = n + 1)
					result[n] = v[n] && |(v & (16'hffff >> (16 - n)));
			end
			clear_first = result;
		end
	endfunction
	function automatic [3:0] first16;
		input reg [14:0] v;
		reg [3:0] r;
		reg [6:0] b;
		reg [2:0] q;
		begin
			r[3] = !(|v[7:0]);
			b = (r[3] ? v[14:8] : v[6:0]);
			r[2] = !(|b[3:0]);
			q = (r[2] ? b[6:4] : b[2:0]);
			r[1] = !(|q[1:0]);
			r[0] = !(r[1] ? q[2] : q[0]);
			first16 = r;
		end
	endfunction
	function automatic [5:0] bank;
		input reg [4:0] r;
		input reg [4:0] mode;
		reg [5:0] result;
		begin
			result = {1'b0, r};
			if (r == 27)
				case (mode)
					5'h11: result = 35;
					5'h12: result = 36;
					5'h13: result = 37;
					5'h1b: result = 38;
					5'h17: result = 39;
					default: result = 17;
				endcase
			else if (((r >= 8) && (r <= 14)) && (mode == 5'h11))
				result = {1'b0, r} + 6'd10;
			else if ((r == 13) || (r == 14))
				case (mode)
					5'h12: result = {1'b0, r} + 6'd12;
					5'h13: result = {1'b0, r} + 6'd14;
					5'h1b: result = {1'b0, r} + 6'd16;
					5'h17: result = {1'b0, r} + 6'd18;
					default:
						;
				endcase
			bank = result;
		end
	endfunction
	function automatic [3:0] classify;
		input reg [31:0] ins;
		input reg [4:0] raw_class;
		input reg thumb;
		input reg und;
		input reg user_mode;
		input reg empty_list;
		reg [3:0] k;
		begin
			k = K_UND;
			if (ins[27:24] == 4'hf)
				k = K_SWI;
			else if (ins[27:25] == 3'b101)
				k = K_BRANCH;
			else if (ins[27:25] == 3'b100)
				k = K_BLOCK;
			else if ((ins[27:26] == 2'b01) && !(ins[25] && ins[4]))
				k = K_MEM;
			else if ((ins & 32'h0fc000f0) == 32'h00000090)
				k = K_MUL;
			else if ((ins & 32'h0f8000f0) == 32'h00800090)
				k = K_MULL;
			else if ((ins & 32'h0fb00ff0) == 32'h01000090)
				k = K_SWP;
			else if ((ins & 32'h0ffffff0) == 32'h012fff10)
				k = K_BX;
			else if ((ins & 32'h0fbf0fff) == 32'h010f0000)
				k = K_MRS;
			else if (((ins & 32'h0fb0fff0) == 32'h0120f000) || ((ins & 32'h0fb0f000) == 32'h0320f000))
				k = K_MSR;
			else if (((ins[27:24] == 4'he) && ins[4]) && (ins[11:8] == 4'hf))
				k = (user_mode ? K_UND : K_CP);
			else if ((((ins[27:25] == 0) && ins[7]) && ins[4]) && (ins[6:5] != 0))
				k = K_MEM;
			else if (((ins[27:26] == 0) && !((ins[7] && ins[4]) && !ins[25])) && !(!ins[20] && (ins[24:23] == 2'b10)))
				k = K_DP;
			if (thumb && (raw_class == 5'b11110))
				k = K_BL_PREFIX;
			if (thumb && (raw_class == 5'b11111))
				k = K_BL_SUFFIX;
			if ((((und || (!thumb && (ins[31:28] == 4'hf))) || ((((k == K_MEM) && (ins[27:26] == 0)) && !ins[20]) && ins[6])) || (thumb && (raw_class == 5'b11101))) || ((k == K_BLOCK) && empty_list))
				k = K_UND;
			classify = k;
		end
	endfunction
	assign raw_word = (i_thumb && i_pc[1] ? {16'd0, i_word[31:16]} : i_word);
	zap_mode16_decoder #(.V4T(1'b1)) u_thumb(
		.i_instruction(raw_word),
		.i_instruction_valid(1'b1),
		.i_offset(11'd0),
		.i_prev_prefix(1'b0),
		.i_irq(1'b0),
		.i_fiq(1'b0),
		.i_cpsr_ff_t(i_thumb),
		.o_instruction(expanded),
		.o_und(thumb_und),
		.o_force32_align(thumb_align),
		.o_instruction_valid(),
		.o_irq(),
		.o_fiq()
	);
	always @(*) begin
		if (_sv2v_0)
			;
		reg_list = i_word[15:0];
		if (i_thumb) begin
			reg_list = {8'd0, raw_word[7:0]};
			if (((raw_word[15:0] & 16'hf600) == 16'hb400) && raw_word[8]) begin
				if (raw_word[11])
					reg_list[15] = 1;
				else
					reg_list[14] = 1;
			end
		end
		incoming = 241'd0;
		incoming[240-:32] = i_pc;
		incoming[208-:32] = expanded[31:0];
		incoming[80-:16] = raw_word[15:0];
		incoming[176-:32] = i_pc + (i_thumb ? 32'd4 : 32'd8);
		incoming[144-:32] = i_pc + (i_thumb ? 32'd2 : 32'd4);
		incoming[32-:5] = i_mode;
		incoming[18] = i_thumb;
		incoming[17] = i_fault;
		incoming[16] = thumb_und;
		incoming[15] = thumb_align;
		incoming[14] = expanded[34];
		incoming[64-:16] = reg_list;
		incoming[48-:16] = clear_first(reg_list);
		incoming[27-:5] = popcount16(reg_list);
		incoming[22-:4] = first16(reg_list[14:0]);
		incoming[13] = (previous_prefix && i_thumb) && (i_pc == previous_next_pc);
		incoming[12] = i_predicted;
		incoming[11] = i_pred_hit;
		incoming[112-:32] = i_pred_target;
		incoming[10-:2] = i_pred_state;
		incoming[8-:2] = i_pred_kind;
		incoming[6-:3] = i_ras_pointer;
		incoming[3-:4] = i_ras_count;
	end
	(* keep *) wire [3:0] kind0 = classify(d1[0][208-:32], d1[0][80:76], d1[0][18], d1[0][16], d1[0][32-:5] == 5'h10, d1[0][27-:5] == 0);
	(* keep *) wire [3:0] kind1 = classify(d1[1][208-:32], d1[1][80:76], d1[1][18], d1[1][16], d1[1][32-:5] == 5'h10, d1[1][27-:5] == 0);
	assign front = (d1[0] & {241 {head_select[0]}}) | (d1[1] & {241 {head_select[1]}});
	(* keep *) wire [31:0] arm_target = front[176-:32] + {{6 {front[200]}}, front[200:177], 2'b00};
	(* keep *) wire [31:0] thumb_target = front[176-:32] + {{7 {front[200]}}, front[200:177], 1'b0};
	(* keep *) wire [31:0] prefix_sum = front[176-:32] + {{9 {front[75]}}, front[75:65], 12'd0};
	(* keep *) wire [31:0] suffix_sum = suffix_base + {20'd0, front[75:65], 1'b0};
	wire [31:0] fast_arm_offset = {{6 {i_word[23]}}, i_word[23:0], 2'b00};
	wire [31:0] fast_thumb_offset = {{20 {raw_word[10]}}, raw_word[10:0], 1'b0};
	(* keep *) wire [31:0] fast_arm_ones = (i_pc ^ fast_arm_offset) ^ 32'd8;
	(* keep *) wire [31:0] fast_arm_twos = (i_pc & fast_arm_offset) | ((i_pc | fast_arm_offset) & 32'd8);
	(* keep *) wire [31:0] fast_thumb_ones = (i_pc ^ fast_thumb_offset) ^ 32'd4;
	(* keep *) wire [31:0] fast_thumb_twos = (i_pc & fast_thumb_offset) | ((i_pc | fast_thumb_offset) & 32'd4);
	(* keep *) wire [31:0] fast_arm_sum = fast_arm_ones + {fast_arm_twos[30:0], 1'b0};
	(* keep *) wire [31:0] fast_thumb_sum = fast_thumb_ones + {fast_thumb_twos[30:0], 1'b0};
	always @(*) begin
		if (_sv2v_0)
			;
		fast_branch = 367'd0;
		fast_branch[366-:241] = incoming;
		fast_branch[334-:32] = (i_thumb ? {8'hea, {13 {raw_word[10]}}, raw_word[10:0]} : i_word);
		fast_branch[190-:16] = 0;
		fast_branch[174-:16] = 0;
		fast_branch[153-:5] = 0;
		fast_branch[148-:4] = 0;
		fast_branch[125-:4] = K_BRANCH;
		fast_branch[121-:4] = 4'he;
		fast_branch[78+:6] = bank(5'd14, i_mode);
		fast_branch[43] = 1;
		fast_branch[42] = 1;
		fast_branch[45] = 1;
		fast_branch[77-:32] = (i_thumb ? fast_thumb_sum : fast_arm_sum);
	end
	always @(*) begin
		if (_sv2v_0)
			;
		decoded = 367'd0;
		decoded[366-:241] = front;
		decoded[125-:4] = (kind0 & {4 {head_select[0]}}) | (kind1 & {4 {head_select[1]}});
		decoded[121-:4] = front[208:205];
		if ((((decoded[125-:4] == K_BL_PREFIX) || (decoded[125-:4] == K_BL_SUFFIX)) || (front[18] && (decoded[125-:4] == K_UND))) || (!front[18] && (front[208:205] == 4'hf)))
			decoded[121-:4] = 4'he;
		decoded[44] = ((decoded[125-:4] == K_DP) && !front[202]) && front[181];
		decoded[94+:6] = bank({1'b0, front[196:193]}, front[32-:5]);
		decoded[100+:6] = bank({1'b0, front[180:177]}, front[32-:5]);
		decoded[106+:6] = bank(5'd27, front[32-:5]);
		decoded[112+:6] = bank({1'b0, front[192:189]}, front[32-:5]);
		decoded[78+:6] = decoded[112+:6];
		decoded[84+:6] = decoded[94+:6];
		decoded[43] = 1;
		decoded[42] = 1;
		decoded[40-:5] = front[27-:5];
		decoded[35-:16] = front[48-:16];
		decoded[19-:4] = front[22-:4];
		decoded[7-:8] = (front[200] ? $signed({1'b0, front[27-:5], 2'b00}) : -$signed({1'b0, front[27-:5], 2'b00}));
		decoded[15-:8] = (front[200] ? (front[201] ? 8'sd4 : 8'sd0) : $signed(decoded[7-:8]) + (front[201] ? 8'sd0 : 8'sd4));
		transfer_mode = (front[199] && !(front[197] && front[64]) ? 5'h10 : front[32-:5]);
		case (decoded[125-:4])
			K_DP: begin
				decoded[90] = (front[201:198] != 4'd13) && (front[201:198] != 4'd15);
				decoded[91] = !front[202];
				decoded[92] = decoded[44];
				if (decoded[44])
					decoded[106+:6] = bank({1'b0, front[188:185]}, front[32-:5]);
				if (front[197] && (front[192:189] == 15)) begin
					decoded[112+:6] = bank(5'd27, front[32-:5]);
					decoded[93] = 1;
				end
			end
			K_MRS: begin
				decoded[92] = 1;
				if (!front[199])
					decoded[106+:6] = 6'd17;
			end
			K_MSR: begin
				decoded[91] = !front[202];
				decoded[92] = front[199];
			end
			K_BX: decoded[91] = 1;
			K_MEM: begin
				decoded[90] = 1;
				decoded[91] = (front[204:203] == 1 ? front[202] : !front[199]);
				decoded[93] = !front[197];
			end
			K_BLOCK: begin
				decoded[112+:6] = bank({1'b0, front[22-:4]}, transfer_mode);
				decoded[78+:6] = decoded[112+:6];
				decoded[90] = 1;
				decoded[93] = !front[197];
				decoded[42] = front[27-:5] == 1;
				decoded[92] = ((front[197] && front[199]) && decoded[42]) && (front[22-:4] == 15);
			end
			K_CP: decoded[93] = !front[197];
			K_SWP: decoded[93-:4] = 4'b0011;
			K_MUL, K_MULL: begin
				decoded[106+:6] = bank({1'b0, front[188:185]}, front[32-:5]);
				decoded[93-:4] = 4'b0110;
				if (front[198])
					decoded[93-:4] = (decoded[125-:4] == K_MUL ? 4'b1110 : 4'b1111);
				if (decoded[125-:4] == K_MUL)
					decoded[78+:6] = decoded[94+:6];
			end
			K_BRANCH, K_BL_PREFIX: decoded[78+:6] = bank(5'd14, front[32-:5]);
			K_BL_SUFFIX: begin
				decoded[94+:6] = bank(5'd14, front[32-:5]);
				decoded[90] = !front[13];
				decoded[78+:6] = decoded[94+:6];
			end
			default:
				;
		endcase
		decoded[77-:32] = (front[14] ? thumb_target : arm_target);
		if (front[18] && (front[80:76] == 5'b11110))
			decoded[77-:32] = prefix_sum;
		decoded[45] = (front[208:202] == 7'b1110101) && !front[16];
		suffix_base = prefix_target;
		if (d2_valid && (d2[125-:4] == K_BL_PREFIX))
			suffix_base = d2[77-:32];
		if (front[18] && (front[80:76] == 5'b11111)) begin
			decoded[77-:32] = suffix_sum;
			decoded[45] = (!front[16] && front[13]) && (prefix_valid || (d2_valid && (d2[125-:4] == K_BL_PREFIX)));
		end
		if (front[17]) begin
			decoded[45] = 0;
			decoded[93-:4] = 0;
			decoded[42] = 1;
		end
	end
	assign next_remaining = clear_first(d2[35-:16]);
	assign next_register = first16(d2[34:20]);
	assign taken_match = d2[238-:32] == {d2[77:47], d2[144]};
	assign fallthrough_match = d2[238-:32] == {d2[270:240], d2[144]};
	assign kill_younger = i_flush || redirect_ff[74];
	assign o_ready = (count < 2) && !kill_younger;
	assign accept = i_valid && o_ready;
	assign fast_select = ((count == 0) && !i_fault) && (i_thumb ? raw_word[15:11] == 5'b11100 : i_word[31:25] == 7'b1110101);
	assign shortcut = (accept && fast_select) && (!d2_valid || (step && d2[42]));
	assign push = accept && !shortcut;
	assign new_d2 = pop || shortcut;
	assign admitted = (fast_select ? fast_branch : decoded);
	assign late_redirect = ((step && d2[45]) && !d2[41]) && (!d2[138] || !taken_match);
	always @(*) begin
		if (_sv2v_0)
			;
		early_used = 0;
		case (d2[125-:4])
			K_DP: begin
				early_used[1] = d2[91] && (d2[314:307] != 0);
				early_used[2] = d2[92];
			end
			K_MUL, K_MULL: early_used = d2[93-:4];
			K_MEM, K_MSR: early_used[1] = d2[91];
			K_BLOCK: early_used[0] = d2[90];
			K_MRS: early_used[2] = d2[92] && (d2[106+:6] != 17);
			default:
				;
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		early_hazard = 0;
		begin : sv2v_autoblock_2
			reg signed [31:0] src;
			for (src = 0; src < 4; src = src + 1)
				begin : sv2v_autoblock_3
					reg signed [31:0] pending;
					for (pending = 0; pending < 4; pending = pending + 1)
						early_hazard[src] = early_hazard[src] | ((early_used[src] && i_early_valid[pending]) && (d2[94 + (src * 6)+:6] == i_early_tag[pending * 6+:6]));
				end
		end
	end
	assign o_hazard = d2_valid && (((((d2[90] && i_locked[d2[94+:6]]) || (d2[91] && i_locked[d2[100+:6]])) || (d2[92] && i_locked[d2[106+:6]])) || (d2[93] && i_locked[d2[112+:6]])) || |early_hazard);
	assign step = (((d2_valid && (!out_valid || i_ready)) && !o_hazard) && !i_flush) && (!redirect_ff[74] || redirect_in_d2);
	assign pop = ((count != 0) && (!d2_valid || (step && d2[42]))) && !kill_younger;
	zap_register_file u_registers(
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_wen(i_wen),
		.i_wr_addr_a(i_wr_addr_a),
		.i_wr_addr_b(i_wr_addr_b),
		.i_wr_addr_c(i_wr_addr_c),
		.i_wr_data_a(i_wr_data_a),
		.i_wr_data_b(i_wr_data_b),
		.i_wr_data_c(i_wr_data_c),
		.i_rd_addr_a(d2[94+:6]),
		.i_rd_addr_b(d2[100+:6]),
		.i_rd_addr_c(d2[106+:6]),
		.i_rd_addr_d(d2[112+:6]),
		.o_rd_data_a(raw_values[0+:32]),
		.o_rd_data_b(raw_values[32+:32]),
		.o_rd_data_c(raw_values[64+:32]),
		.o_rd_data_d(raw_values[96+:32])
	);
	always @(*) begin
		if (_sv2v_0)
			;
		read_values = raw_values;
		begin : sv2v_autoblock_4
			reg signed [31:0] n;
			for (n = 0; n < 4; n = n + 1)
				begin
					if (i_wen && i_wr_addr_a[d2[94 + (n * 6)+:6]])
						read_values[n * 32+:32] = i_wr_data_a;
					if (i_wen && i_wr_addr_b[d2[94 + (n * 6)+:6]])
						read_values[n * 32+:32] = i_wr_data_b;
					if (i_wr_addr_c[d2[94 + (n * 6)+:6]])
						read_values[n * 32+:32] = i_wr_data_c;
				end
		end
	end
	always @(posedge i_clk)
		if (i_reset) begin
			count <= 0;
			head_select <= 2'b01;
			tail <= 0;
			d2_valid <= 0;
			out_valid <= 0;
			redirect_ff[74] <= 0;
			redirect_in_d2 <= 0;
			previous_prefix <= 0;
			prefix_valid <= 0;
			previous_next_pc <= 0;
			prefix_target <= 0;
			d2 <= 367'd0;
			issued <= 367'd0;
			values <= 0;
			matches_taken <= 0;
			matches_fallthrough <= 0;
			redirect_ff[72-:32] <= 0;
			redirect_ff[73] <= 0;
			redirect_ff[40-:32] <= 0;
			redirect_ff[8-:3] <= 0;
			redirect_ff[5-:4] <= 0;
			redirect_ff[1-:2] <= 0;
		end
		else begin
			redirect_ff[74] <= 0;
			redirect_in_d2 <= 0;
			if (i_ready)
				out_valid <= 0;
			if (push) begin
				d1[tail] <= incoming;
				tail <= !tail;
			end
			if (accept) begin
				previous_prefix <= (i_thumb && !i_fault) && (raw_word[15:11] == 5'b11110);
				previous_next_pc <= incoming[144-:32];
			end
			if (pop)
				head_select <= {head_select[0], head_select[1]};
			case ({push, pop})
				2'b10: count <= count + 1'b1;
				2'b01: count <= count - 1'b1;
				default:
					;
			endcase
			if (!out_valid || i_ready) begin
				issued <= d2;
				values <= read_values;
				matches_taken <= taken_match;
				matches_fallthrough <= fallthrough_match;
			end
			if (step) begin
				out_valid <= 1;
				if (d2[125-:4] == K_BL_PREFIX) begin
					prefix_target <= d2[77-:32];
					prefix_valid <= !d2[143];
				end
				else
					prefix_valid <= 0;
				if (d2[42])
					d2_valid <= 0;
				else begin
					d2[43] <= 0;
					d2[40-:5] <= d2[40-:5] - 1'b1;
					d2[42] <= d2[40-:5] == 2;
					d2[35-:16] <= next_remaining;
					d2[19-:4] <= next_register;
					d2[15-:8] <= $signed(d2[15-:8]) + 8'sd4;
					d2[112+:6] <= bank({1'b0, next_register}, (d2[325] && !(d2[323] && d2[190]) ? 5'h10 : d2[158-:5]));
					d2[78+:6] <= bank({1'b0, next_register}, (d2[325] && !(d2[323] && d2[190]) ? 5'h10 : d2[158-:5]));
					d2[90] <= 0;
					d2[92] <= ((d2[323] && d2[325]) && (d2[40-:5] == 2)) && (next_register == 15);
				end
				if (late_redirect) begin
					redirect_ff[74] <= 1;
					redirect_ff[72-:32] <= d2[77-:32];
					redirect_ff[73] <= d2[144];
					redirect_ff[40-:32] <= {d2[270:240], d2[144]};
					redirect_ff[8-:3] <= d2[132-:3];
					redirect_ff[5-:4] <= d2[129-:4];
					redirect_ff[1-:2] <= ((d2[125-:4] == K_BL_SUFFIX) || d2[327] ? 2'd1 : 2'd0);
				end
			end
			if (new_d2) begin
				d2 <= admitted;
				d2_valid <= 1;
				if ((admitted[45] && !admitted[138]) && !late_redirect) begin
					d2[41] <= 1;
					redirect_in_d2 <= 1;
					redirect_ff[74] <= 1;
					redirect_ff[72-:32] <= admitted[77-:32];
					redirect_ff[73] <= admitted[144];
					redirect_ff[40-:32] <= {admitted[270:240], admitted[144]};
					redirect_ff[8-:3] <= admitted[132-:3];
					redirect_ff[5-:4] <= admitted[129-:4];
					redirect_ff[1-:2] <= ((admitted[125-:4] == K_BL_SUFFIX) || admitted[327] ? 2'd1 : 2'd0);
				end
			end
			if (kill_younger) begin
				count <= 0;
				head_select <= 2'b01;
				tail <= 0;
				previous_prefix <= 0;
				prefix_valid <= 0;
				if (i_flush || !redirect_in_d2)
					d2_valid <= 0;
			end
			if (i_flush) begin
				out_valid <= 0;
				redirect_ff[74] <= 0;
			end
		end
	assign o_valid = out_valid;
	assign o_pc = issued[366-:32];
	assign o_instruction = issued[334-:32];
	assign o_mode = issued[158-:5];
	assign o_raw = issued[206-:16];
	assign o_pc_base = issued[302-:32];
	assign o_next_pc = issued[270-:32];
	assign o_thumb = issued[144];
	assign o_fault = issued[143];
	assign o_force_align = issued[141];
	assign o_kind = issued[125-:4];
	assign o_condition = issued[121-:4];
	assign o_reg_shift = issued[44];
	assign o_tag = issued[117-:24];
	assign o_used = issued[93-:4];
	assign o_value = values;
	assign o_dest = issued[89-:12];
	assign o_first = issued[43];
	assign o_last = issued[42];
	assign o_reg_count = issued[153-:5];
	assign o_offset = $signed(issued[15-:8]);
	assign o_writeback_offset = $signed(issued[7-:8]);
	assign o_transfer_reg = issued[19-:4];
	assign o_branch_target = issued[77-:32];
	assign o_direct = issued[45];
	assign o_match_taken = matches_taken;
	assign o_match_fallthrough = matches_fallthrough;
	assign o_predicted = issued[138];
	assign o_pred_hit = issued[137];
	assign o_pred_target = issued[238-:32];
	assign o_pred_state = issued[136-:2];
	assign o_pred_kind = issued[134-:2];
	assign o_ras_pointer = issued[132-:3];
	assign o_ras_count = issued[129-:4];
	assign o_redirect = redirect_ff[74];
	assign o_redirect_thumb = redirect_ff[73];
	assign o_redirect_target = redirect_ff[72-:32];
	assign o_redirect_link = redirect_ff[40-:32];
	assign o_redirect_pointer = redirect_ff[8-:3];
	assign o_redirect_count = redirect_ff[5-:4];
	assign o_redirect_action = redirect_ff[1-:2];
	initial _sv2v_0 = 0;
endmodule
module arm9v2_execute (
	i_clk,
	i_reset,
	i_flush,
	i_cpsr,
	i_valid,
	o_ready,
	i_pc,
	i_instruction,
	i_pc_base,
	i_next_pc,
	i_thumb,
	i_fault,
	i_force_align,
	i_reg_shift,
	i_first,
	i_last,
	i_kind,
	i_condition,
	i_tag,
	i_used,
	i_value,
	i_dest,
	i_offset,
	i_writeback_offset,
	i_branch_target,
	i_pred_target,
	i_direct,
	i_predicted,
	i_match_taken,
	i_match_fallthrough,
	i_pred_hit,
	i_pred_state,
	i_ras_pointer,
	i_ras_count,
	i_mw_value,
	i_mw_tag,
	i_mw_valid,
	i_ready,
	o_valid,
	o_pc,
	o_instruction,
	o_cpsr,
	o_cpsr_next,
	o_kind,
	o_thumb,
	o_fault,
	o_first,
	o_last,
	o_condition_pass,
	o_dest,
	o_result,
	o_write,
	o_write_flags,
	o_pc_write,
	o_memory,
	o_store,
	o_address,
	o_store_data,
	o_flags,
	o_redirect,
	o_redirect_thumb,
	o_redirect_target,
	o_redirect_link,
	o_redirect_pointer,
	o_redirect_count,
	o_redirect_action,
	o_btb_update,
	o_btb_taken,
	o_btb_hit,
	o_btb_target,
	o_btb_state,
	o_btb_kind,
	o_a_valid,
	o_a_can_finish,
	o_s_write,
	o_a_dest,
	o_a_write,
	o_shift_wait,
	o_multiply_wait
);
	reg _sv2v_0;
	input wire i_clk;
	input wire i_reset;
	input wire i_flush;
	input wire [31:0] i_cpsr;
	input wire i_valid;
	output wire o_ready;
	input wire [31:0] i_pc;
	input wire [31:0] i_instruction;
	input wire [31:0] i_pc_base;
	input wire [31:0] i_next_pc;
	input wire i_thumb;
	input wire i_fault;
	input wire i_force_align;
	input wire i_reg_shift;
	input wire i_first;
	input wire i_last;
	input wire [3:0] i_kind;
	input wire [3:0] i_condition;
	input wire [23:0] i_tag;
	input wire [3:0] i_used;
	input wire [127:0] i_value;
	input wire [11:0] i_dest;
	input wire signed [7:0] i_offset;
	input wire signed [7:0] i_writeback_offset;
	input wire [31:0] i_branch_target;
	input wire [31:0] i_pred_target;
	input wire i_direct;
	input wire i_predicted;
	input wire i_match_taken;
	input wire i_match_fallthrough;
	input wire i_pred_hit;
	input wire [1:0] i_pred_state;
	input wire [2:0] i_ras_pointer;
	input wire [3:0] i_ras_count;
	input wire [127:0] i_mw_value;
	input wire [23:0] i_mw_tag;
	input wire [3:0] i_mw_valid;
	input wire i_ready;
	output reg o_valid;
	output reg [31:0] o_pc;
	output reg [31:0] o_instruction;
	output reg [31:0] o_cpsr;
	output reg [31:0] o_cpsr_next;
	output reg [3:0] o_kind;
	output reg o_thumb;
	output reg o_fault;
	output reg o_first;
	output reg o_last;
	output reg o_condition_pass;
	output reg [11:0] o_dest;
	output reg [63:0] o_result;
	output reg [1:0] o_write;
	output reg o_write_flags;
	output reg o_pc_write;
	output reg o_memory;
	output reg o_store;
	output reg [31:0] o_address;
	output reg [31:0] o_store_data;
	output wire [3:0] o_flags;
	output reg o_redirect;
	output reg o_redirect_thumb;
	output reg [31:0] o_redirect_target;
	output reg [31:0] o_redirect_link;
	output reg [2:0] o_redirect_pointer;
	output reg [3:0] o_redirect_count;
	output reg [1:0] o_redirect_action;
	output reg o_btb_update;
	output reg o_btb_taken;
	output reg o_btb_hit;
	output reg [31:0] o_btb_target;
	output reg [1:0] o_btb_state;
	output reg [1:0] o_btb_kind;
	output wire o_a_valid;
	output wire o_a_can_finish;
	output wire [1:0] o_s_write;
	output wire [11:0] o_a_dest;
	output wire [1:0] o_a_write;
	output wire o_shift_wait;
	output wire o_multiply_wait;
	localparam [3:0] DP = 0;
	localparam [3:0] MRS = 1;
	localparam [3:0] MSR = 2;
	localparam [3:0] BR = 3;
	localparam [3:0] BX = 4;
	localparam [3:0] MEM = 5;
	localparam [3:0] BLOCK = 6;
	localparam [3:0] CP = 7;
	localparam [3:0] UND = 8;
	localparam [3:0] SWI = 9;
	localparam [3:0] PREFIX = 10;
	localparam [3:0] SUFFIX = 11;
	localparam [3:0] SWP = 12;
	localparam [3:0] MUL = 13;
	localparam [3:0] MULL = 14;
	(* dont_retime *) reg [378:0] a;
	(* dont_retime *) reg a_valid;
	(* dont_retime *) reg prepared;
	(* dont_retime *) reg holding;
	(* dont_retime *) reg multiply_accumulate;
	(* dont_retime *) reg multiply_product_ready;
	(* dont_retime *) reg [3:0] flags;
	(* dont_retime *) reg [127:0] held;
	(* dont_retime *) reg [7:0] held_amount;
	(* dont_retime *) reg [31:0] block_base;
	(* dont_retime *) reg signed [33:0] ll;
	(* dont_retime *) reg signed [33:0] lh;
	(* dont_retime *) reg signed [33:0] hl;
	(* dont_retime *) reg signed [33:0] hh;
	(* dont_retime *) reg [63:0] product_saved;
	(* dont_retime *) reg [63:0] accumulator;
	wire [191:0] producer_value;
	wire [35:0] producer_tag;
	wire [5:0] producer_valid;
	wire [127:0] forwarded;
	reg [127:0] operand;
	reg [31:0] shift_input;
	wire [31:0] shifted;
	reg [7:0] shift_amount;
	reg [1:0] shift_type;
	reg shift_register;
	wire shift_carry;
	wire carry_preserve;
	wire rrx;
	reg [31:0] left_a;
	reg [31:0] right_a;
	reg [31:0] store_a;
	wire [31:0] alu_result;
	wire [3:0] alu_flags;
	reg [3:0] next_flags;
	reg condition_pass;
	wire finish;
	wire accept;
	wire space;
	wire product_phase;
	wire mac_phase;
	reg will_write_flags;
	reg [1:0] planned_writes;
	wire [63:0] product;
	wire [63:0] mac_result;
	wire [63:0] mult_result;
	reg [31:0] actual_target;
	reg actual_thumb;
	reg wrong_prediction;
	wire unused = &{1'b0, i_cpsr[27:0], CP, UND, SWI, actual_target[0], lh[33:32], hl[33:32], hh[33:32]};
	assign producer_value = {i_mw_value, o_result};
	assign producer_tag = {i_mw_tag, o_dest};
	assign producer_valid = {i_mw_valid, o_write & {2 {o_valid}}};
	arm9v2_forward u_forward(
		.i_value((holding ? held : i_value)),
		.i_tag(i_tag),
		.i_used(i_used),
		.i_producer_value(producer_value),
		.i_producer_tag(producer_tag),
		.i_producer_valid(producer_valid),
		.o_value(forwarded)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		operand = forwarded;
		begin : sv2v_autoblock_1
			reg signed [31:0] s;
			for (s = 0; s < 4; s = s + 1)
				begin
					if (i_tag[s * 6+:6] == 15) begin
						operand[s * 32+:32] = i_pc_base;
						if ((i_reg_shift && (s < 2)) || ((s == 3) && !i_thumb))
							operand[s * 32+:32] = i_pc_base + 32'd4;
						if ((s == 0) && i_force_align)
							operand[s * 32+:32] = {i_pc_base[31:2], 2'b00};
					end
					if (i_tag[s * 6+:6] == 17)
						operand[s * 32+:32] = {flags, i_cpsr[27:0]};
				end
		end
		shift_input = operand[32+:32];
		shift_type = i_instruction[6:5];
		shift_amount = (prepared ? held_amount : {3'd0, i_instruction[11:7]});
		shift_register = i_reg_shift;
		if (((i_kind == DP) || (i_kind == MSR)) && i_instruction[25]) begin
			shift_input = {24'd0, i_instruction[7:0]};
			shift_type = 3;
			shift_amount = {3'd0, i_instruction[11:8], 1'b0};
			shift_register = 1;
		end
		if ((i_kind == MEM) && (i_instruction[27:26] == 0)) begin
			shift_type = 0;
			shift_amount = 0;
			shift_register = 1;
		end
		if (((i_kind != DP) && (i_kind != MSR)) && (i_kind != MEM)) begin
			shift_type = 0;
			shift_amount = 0;
			shift_register = 1;
		end
		planned_writes = 0;
		case (i_kind)
			DP: planned_writes[0] = i_instruction[24:23] != 2'b10;
			MRS, MUL, PREFIX: planned_writes[0] = 1;
			MULL: planned_writes = 3;
			BR: planned_writes[0] = i_instruction[24];
			SUFFIX: planned_writes[0] = 1;
			default:
				;
		endcase
		if (i_fault)
			planned_writes = 0;
	end
	arm9v2_rotate u_rotate(
		.i_value(shift_input),
		.i_amount(shift_amount),
		.i_type(shift_type),
		.i_register(shift_register),
		.i_carry(1'b0),
		.o_value(shifted),
		.o_carry(shift_carry),
		.o_preserve(carry_preserve),
		.o_rrx(rrx)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		left_a = a[150-:32];
		right_a = a[118-:32];
		store_a = a[86-:32];
		begin : sv2v_autoblock_2
			reg signed [31:0] lane;
			for (lane = 0; lane < 2; lane = lane + 1)
				if (o_valid && o_write[lane]) begin
					if (a[8 + lane])
						left_a = o_result[lane * 32+:32];
					if (a[10 + lane])
						right_a = o_result[lane * 32+:32];
					if (a[12 + lane])
						store_a = o_result[lane * 32+:32];
				end
		end
		if (a[15])
			right_a[31] = flags[1];
	end
	arm9_alu u_alu(
		.i_a(left_a),
		.i_b(right_a),
		.i_op(a[22-:4]),
		.i_flags(flags),
		.i_shift_carry((a[16] ? flags[1] : a[17])),
		.o_result(alu_result),
		.o_flags(alu_flags)
	);
	wire [63:0] pp0 = {{30 {ll[33]}}, ll};
	wire [63:0] pp1 = {{14 {lh[33]}}, lh, 16'd0};
	wire [63:0] pp2 = {{14 {hl[33]}}, hl, 16'd0};
	wire [63:0] pp3 = {hh[31:0], 32'd0};
	wire [63:0] ones0 = (pp0 ^ pp1) ^ pp2;
	wire [63:0] twos0 = (((pp0 & pp1) | (pp1 & pp2)) | (pp0 & pp2)) << 1;
	wire [63:0] ones1 = (ones0 ^ twos0) ^ pp3;
	wire [63:0] twos1 = (((ones0 & twos0) | (ones0 & pp3)) | (twos0 & pp3)) << 1;
	assign product = ones1 + twos1;
	assign mac_result = product_saved + accumulator;
	assign mult_result = (a[336] ? mac_result : product);
	assign product_phase = (a_valid && ((a[190-:4] == MUL) || (a[190-:4] == MULL))) && !multiply_product_ready;
	assign mac_phase = (((a_valid && ((a[190-:4] == MUL) || (a[190-:4] == MULL))) && multiply_product_ready) && a[336]) && !multiply_accumulate;
	assign space = !a_valid || finish;
	assign o_shift_wait = (i_valid && i_reg_shift) && !prepared;
	assign o_multiply_wait = product_phase || mac_phase;
	assign o_ready = ((space && !o_shift_wait) && !i_flush) && !o_redirect;
	assign accept = i_valid && o_ready;
	assign finish = ((((a_valid && !product_phase) && !mac_phase) && (!o_valid || i_ready)) && !i_flush) && !o_redirect;
	assign o_a_valid = a_valid;
	assign o_a_can_finish = finish;
	assign o_s_write = planned_writes & {2 {i_valid}};
	assign o_a_dest = a[164-:12];
	assign o_a_write = a[152-:2];
	assign o_flags = flags;
	always @(*) begin
		if (_sv2v_0)
			;
		case (a[186-:4])
			0: condition_pass = flags[2];
			1: condition_pass = !flags[2];
			2: condition_pass = flags[1];
			3: condition_pass = !flags[1];
			4: condition_pass = flags[3];
			5: condition_pass = !flags[3];
			6: condition_pass = flags[0];
			7: condition_pass = !flags[0];
			8: condition_pass = flags[1] && !flags[2];
			9: condition_pass = !flags[1] || flags[2];
			10: condition_pass = flags[3] == flags[0];
			11: condition_pass = flags[3] != flags[0];
			12: condition_pass = !flags[2] && (flags[3] == flags[0]);
			13: condition_pass = flags[2] || (flags[3] != flags[0]);
			14: condition_pass = 1;
			default: condition_pass = 0;
		endcase
		next_flags = flags;
		will_write_flags = 0;
		if (condition_pass && !a[181])
			case (a[190-:4])
				DP:
					if (a[18] && (!a[151] || (a[153+:6] != 15))) begin
						next_flags = alu_flags;
						will_write_flags = 1;
					end
				MUL:
					if (a[18]) begin
						next_flags = {mult_result[31], mult_result[31:0] == 0, flags[1:0]};
						will_write_flags = 1;
					end
				MULL:
					if (a[18]) begin
						next_flags = {mult_result[63], mult_result == 0, flags[1:0]};
						will_write_flags = 1;
					end
				MSR:
					if (!a[337] && a[334]) begin
						next_flags = right_a[31:28];
						will_write_flags = 1;
					end
				default:
					;
			endcase
		actual_target = a[314-:32];
		actual_thumb = a[182];
		if ((a[190-:4] == BR) && condition_pass)
			actual_target = a[282-:32];
		wrong_prediction = (a[179] && a[177]) && !a[175];
		if (a[190-:4] == BR)
			wrong_prediction = (a[178] ? 1'b0 : (a[177] ? (condition_pass ? !a[176] : !a[175]) : condition_pass));
		if (a[190-:4] == SUFFIX)
			wrong_prediction = 0;
		if ((a[190-:4] == BX) && condition_pass) begin
			actual_thumb = right_a[0];
			actual_target = {right_a[31:2], right_a[1] & right_a[0], 1'b0};
			wrong_prediction = !a[177] || (a[250-:32] != {right_a[31:2], right_a[1] & right_a[0], right_a[0]});
		end
		if ((condition_pass && (a[153+:6] == 15)) && (a[151] || (((a[190-:4] == MEM) || (a[190-:4] == BLOCK)) && a[335])))
			wrong_prediction = 0;
		if (a[181])
			wrong_prediction = 0;
	end
	always @(posedge i_clk)
		if (i_reset || i_flush) begin
			a_valid <= 0;
			holding <= 0;
			prepared <= 0;
			multiply_accumulate <= 0;
			multiply_product_ready <= 0;
			o_valid <= 0;
			o_write <= 0;
			o_write_flags <= 0;
			o_redirect <= 0;
			o_btb_update <= 0;
			o_btb_taken <= 0;
			o_btb_hit <= 0;
			o_btb_target <= 0;
			o_btb_state <= 0;
			o_btb_kind <= 0;
			flags <= i_cpsr[31:28];
			a <= 379'd0;
			held <= 0;
			held_amount <= 0;
			block_base <= 0;
			ll <= 0;
			lh <= 0;
			hl <= 0;
			hh <= 0;
			product_saved <= 0;
			accumulator <= 0;
			o_pc <= 0;
			o_instruction <= 0;
			o_cpsr <= 0;
			o_cpsr_next <= 0;
			o_kind <= 0;
			o_thumb <= 0;
			o_fault <= 0;
			o_first <= 0;
			o_last <= 0;
			o_condition_pass <= 0;
			o_dest <= 0;
			o_result <= 0;
			o_pc_write <= 0;
			o_memory <= 0;
			o_store <= 0;
			o_address <= 0;
			o_store_data <= 0;
			o_redirect_thumb <= 0;
			o_redirect_target <= 0;
			o_redirect_link <= 0;
			o_redirect_pointer <= 0;
			o_redirect_count <= 0;
			o_redirect_action <= 0;
		end
		else begin
			o_redirect <= 0;
			o_btb_update <= 0;
			if (i_ready) begin
				o_valid <= 0;
				o_write <= 0;
				o_write_flags <= 0;
			end
			if (i_valid && !accept) begin
				holding <= 1;
				held <= operand;
			end
			if ((i_valid && i_reg_shift) && !prepared) begin
				prepared <= 1;
				held_amount <= operand[71-:8];
			end
			if (a_valid) begin
				a[150-:32] <= left_a;
				a[118-:32] <= right_a;
				a[86-:32] <= store_a;
				a[13-:6] <= 0;
			end
			if (product_phase) begin
				ll <= $signed({1'b0, a[102:87]}) * $signed({1'b0, a[38:23]});
				lh <= $signed({1'b0, a[102:87]}) * $signed({((a[190-:4] == MULL) && a[337]) && a[54], a[54:39]});
				hl <= $signed({((a[190-:4] == MULL) && a[337]) && a[118], a[118:103]}) * $signed({1'b0, a[38:23]});
				hh <= $signed({((a[190-:4] == MULL) && a[337]) && a[118], a[118:103]}) * $signed({((a[190-:4] == MULL) && a[337]) && a[54], a[54:39]});
				multiply_product_ready <= 1;
			end
			if (mac_phase) begin
				product_saved <= product;
				multiply_accumulate <= 1;
			end
			if (finish) begin
				a_valid <= 0;
				o_valid <= 1;
				o_pc <= a[378-:32];
				o_instruction <= a[346-:32];
				o_kind <= a[190-:4];
				o_thumb <= a[182];
				o_fault <= a[181];
				o_first <= a[180];
				o_last <= a[179];
				o_condition_pass <= condition_pass && !a[181];
				o_dest <= a[164-:12];
				o_cpsr <= {flags, a[218-:28]};
				o_cpsr_next <= {next_flags, a[218-:28]};
				flags <= next_flags;
				o_write_flags <= will_write_flags;
				o_write <= a[152-:2] & {2 {condition_pass && !a[181]}};
				o_result[0+:32] <= alu_result;
				o_result[32+:32] <= 0;
				o_address <= alu_result;
				o_store_data <= store_a;
				o_memory <= ((((a[190-:4] == MEM) || (a[190-:4] == BLOCK)) || (a[190-:4] == SWP)) && condition_pass) && !a[181];
				o_store <= (((a[190-:4] == SWP) || (((a[190-:4] == MEM) || (a[190-:4] == BLOCK)) && !a[335])) && condition_pass) && !a[181];
				o_pc_write <= (((a[151] && (a[153+:6] == 15)) || ((a[190-:4] == SUFFIX) && !a[178])) && condition_pass) && !a[181];
				begin : sv2v_autoblock_3
					reg signed [31:0] lane;
					for (lane = 0; lane < 2; lane = lane + 1)
						if (a[153 + (lane * 6)+:6] == 15)
							o_write[lane] <= 0;
				end
				case (a[190-:4])
					MRS: o_result[0+:32] <= (a[14] ? {flags, a[50:23]} : a[54-:32]);
					BR, SUFFIX: o_result[0+:32] <= {a[314:284], a[182]};
					PREFIX: o_result[0+:32] <= a[282-:32];
					MUL: o_result[0+:32] <= mult_result[31:0];
					MULL: begin
						o_result[0+:32] <= mult_result[31:0];
						o_result[32+:32] <= mult_result[63:32];
					end
					MEM: begin
						o_address <= (a[339] ? alu_result : left_a);
						o_result[32+:32] <= alu_result;
					end
					BLOCK: o_result[32+:32] <= left_a + {{24 {a[7]}}, $signed(a[7-:8])};
					SWP: begin
						o_address <= left_a;
						o_store_data <= right_a;
					end
					default:
						;
				endcase
				o_btb_update <= (((a[190-:4] == BR) || (a[190-:4] == BX)) || ((a[190-:4] == SUFFIX) && a[178])) && !a[181];
				o_btb_taken <= condition_pass;
				o_btb_hit <= a[174];
				o_btb_state <= a[173-:2];
				o_btb_target <= (a[190-:4] == BX ? {right_a[31:2], right_a[1] & right_a[0], right_a[0]} : {a[282:252], a[182]});
				o_btb_kind <= ((a[190-:4] == SUFFIX) || ((a[190-:4] == BR) && a[339]) ? 2'd1 : ((a[190-:4] == BX) && (a[318:315] == 14) ? 2'd2 : 2'd0));
				o_redirect <= wrong_prediction;
				o_redirect_target <= {actual_target[31:1], 1'b0};
				o_redirect_thumb <= actual_thumb;
				o_redirect_link <= {a[314:284], a[182]};
				o_redirect_pointer <= a[171-:3];
				o_redirect_count <= a[168-:4];
				o_redirect_action <= ((condition_pass && (a[190-:4] == BR)) && a[339] ? 2'd1 : ((condition_pass && (a[190-:4] == BX)) && (a[318:315] == 14) ? 2'd2 : 2'd0));
			end
			if (accept) begin
				a_valid <= 1;
				holding <= 0;
				prepared <= 0;
				multiply_accumulate <= 0;
				multiply_product_ready <= 0;
				a[378-:32] <= i_pc;
				a[346-:32] <= i_instruction;
				a[314-:32] <= i_next_pc;
				a[282-:32] <= i_branch_target;
				a[250-:32] <= i_pred_target;
				a[218-:28] <= i_cpsr[27:0];
				a[190-:4] <= i_kind;
				a[186-:4] <= i_condition;
				a[182] <= i_thumb;
				a[181] <= i_fault;
				a[180] <= i_first;
				a[179] <= i_last;
				a[178] <= i_direct;
				a[177] <= i_predicted;
				a[176] <= i_match_taken;
				a[175] <= i_match_fallthrough;
				a[174] <= i_pred_hit;
				a[173-:2] <= i_pred_state;
				a[171-:3] <= i_ras_pointer;
				a[168-:4] <= i_ras_count;
				a[164-:12] <= i_dest;
				a[152-:2] <= planned_writes;
				a[150-:32] <= operand[0+:32];
				a[118-:32] <= shifted;
				a[86-:32] <= operand[96+:32];
				a[54-:32] <= operand[64+:32];
				a[14] <= i_tag[12+:6] == 17;
				a[22-:4] <= i_instruction[24:21];
				a[18] <= i_instruction[20] || ((i_kind == DP) && (i_instruction[24:23] == 2'b10));
				a[17] <= shift_carry;
				a[16] <= carry_preserve;
				a[15] <= rrx;
				a[7-:8] <= i_writeback_offset;
				a[13-:6] <= 0;
				begin : sv2v_autoblock_4
					reg signed [31:0] lane;
					for (lane = 0; lane < 2; lane = lane + 1)
						if ((a_valid && a[151 + lane]) && (a[153 + (lane * 6)+:6] != 15)) begin
							if ((i_used[0] && (i_tag[0+:6] == a[153 + (lane * 6)+:6])) && (i_tag[0+:6] != 17))
								a[8 + lane] <= 1;
							if (((i_used[1] && (i_tag[6+:6] == a[153 + (lane * 6)+:6])) && (i_tag[6+:6] != 17)) && (((i_kind == BX) || (i_kind == SWP)) || (((i_kind == DP) && !i_instruction[25]) && (i_instruction[11:4] == 0))))
								a[10 + lane] <= 1;
							if ((i_used[3] && (i_tag[18+:6] == a[153 + (lane * 6)+:6])) && (i_tag[18+:6] != 17))
								a[12 + lane] <= 1;
						end
				end
				if (i_kind == MEM) begin
					a[22-:4] <= (i_instruction[23] ? 4'd4 : 4'd2);
					a[15] <= rrx;
					if ((i_instruction[27:26] == 1) && !i_instruction[25]) begin
						a[118-:32] <= {20'd0, i_instruction[11:0]};
						a[15] <= 0;
					end
					if ((i_instruction[27:26] == 0) && i_instruction[22]) begin
						a[118-:32] <= {24'd0, i_instruction[11:8], i_instruction[3:0]};
						a[15] <= 0;
					end
				end
				if (i_kind == BLOCK) begin
					a[22-:4] <= 4;
					a[150-:32] <= (i_first ? operand[0+:32] : block_base);
					a[118-:32] <= {{24 {i_offset[7]}}, i_offset};
					a[15] <= 0;
					if (i_first)
						block_base <= operand[0+:32];
				end
				if ((i_kind == BX) || (i_kind == SWP)) begin
					a[118-:32] <= operand[32+:32];
					a[15] <= 0;
				end
				if (i_kind == SUFFIX) begin
					a[22-:4] <= 4;
					a[118-:32] <= {20'd0, i_instruction[10:0], 1'b0};
					a[15] <= 0;
				end
				if ((i_kind == MUL) || (i_kind == MULL))
					accumulator <= (i_kind == MULL ? {operand[0+:32], operand[96+:32]} : {32'd0, operand[96+:32]});
			end
			if (o_redirect) begin
				a_valid <= 0;
				holding <= 0;
				prepared <= 0;
			end
		end
	initial _sv2v_0 = 0;
endmodule
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
	reg _sv2v_0;
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
	(* dont_retime *) reg [2:0] tail;
	(* dont_retime *) reg [7:0] head_select;
	(* dont_retime *) reg [3:0] count;
	reg [113:0] queue [0:7];
	reg [113:0] head_packet;
	wire [44:0] prediction;
	wire predicted;
	wire advance;
	wire push;
	wire pop;
	wire retry;
	wire launch_thumb;
	wire [31:0] launch_pc;
	(* keep *) wire [31:0] redirect_next = {i_redirect_target[31:1], 1'b0} + (i_redirect_thumb ? 32'd2 : 32'd4);
	(* keep *) wire [31:0] predicted_next = {prediction[42:12], 1'b0} + (prediction[11] ? 32'd2 : 32'd4);
	(* keep *) wire [31:0] sequential_next = sequential_pc + (sequential_thumb ? 32'd2 : 32'd4);
	wire unused;
	assign unused = &{1'b0, i_redirect_target[0], i_redirect_pointer, i_redirect_count, i_redirect_action, i_redirect_link, i_predictor_clear, i_update, i_update_pc, i_update_target, i_update_thumb, i_update_taken, i_update_hit, i_update_state, i_update_kind};
	assign predicted = (((PREDICTOR && prediction[44]) && f1[35]) && (f1[33-:2] == epoch)) && !killed;
	assign launch_pc = (i_redirect ? {i_redirect_target[31:1], 1'b0} : (predicted ? {prediction[42:12], 1'b0} : sequential_pc));
	assign launch_thumb = (i_redirect ? i_redirect_thumb : (predicted ? prediction[11] : sequential_thumb));
	assign o_address_nxt = launch_pc;
	assign o_address_check = f1[31-:32];
	assign o_address = f2[31-:32];
	assign o_request = (f2[35] && !killed) && !i_redirect;
	assign o_stall = ((count == 8) && !killed) || (f2[35] && !i_ack);
	assign advance = !o_stall;
	assign retry = (((f2[35] && i_ack) && i_retry) && !killed) && !i_redirect;
	assign push = (((((f2[35] && i_ack) && !i_retry) && advance) && !killed) && !i_redirect) && (f2[33-:2] == epoch);
	always @(*) begin
		if (_sv2v_0)
			;
		head_packet = 114'd0;
		begin : sv2v_autoblock_1
			reg signed [31:0] q;
			for (q = 0; q < 8; q = q + 1)
				head_packet = head_packet | (queue[q] & {114 {head_select[q]}});
		end
	end
	assign o_valid = ((count != 0) && !head_packet[47]) && (head_packet[46-:2] == epoch);
	assign pop = o_valid && i_ready;
	assign o_pc = head_packet[81-:32];
	assign o_word = head_packet[113-:32];
	assign o_thumb = head_packet[49];
	assign o_fault = head_packet[48];
	assign o_predicted = head_packet[44];
	assign o_pred_hit = head_packet[43];
	assign o_pred_target = head_packet[42-:32];
	assign o_pred_state = head_packet[10-:2];
	assign o_pred_kind = head_packet[8-:2];
	assign o_ras_pointer = head_packet[6-:3];
	assign o_ras_count = head_packet[3-:4];
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
			head_select <= 8'b00000001;
			tail <= 0;
			count <= 0;
		end
		else begin
			if (pop)
				head_select <= {head_select[6:0], head_select[7]};
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
				sequential_pc <= (predicted ? predicted_next : sequential_next);
				sequential_thumb <= launch_thumb;
				if (retry || killed) begin
					f1[35] <= 0;
					f2[35] <= 0;
					sequential_pc <= (i_redirect ? {i_redirect_target[31:1], 1'b0} : (retry ? f2[31-:32] : restart_pc));
					sequential_thumb <= (i_redirect ? i_redirect_thumb : (retry ? f2[34] : restart_thumb));
				end
				if (i_redirect) begin
					f1 <= {1'b1, i_redirect_thumb, epoch + 2'd1, i_redirect_target[31:1], 1'b0};
					f2[35] <= 0;
					sequential_pc <= redirect_next;
					sequential_thumb <= i_redirect_thumb;
				end
			end
			if (i_redirect) begin
				epoch <= epoch + 1'b1;
				head_select <= 8'b00000001;
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
	initial _sv2v_0 = 0;
endmodule
module arm9v2_forward (
	i_value,
	i_tag,
	i_used,
	i_producer_value,
	i_producer_tag,
	i_producer_valid,
	o_value
);
	reg _sv2v_0;
	input wire [127:0] i_value;
	input wire [23:0] i_tag;
	input wire [3:0] i_used;
	input wire [191:0] i_producer_value;
	input wire [35:0] i_producer_tag;
	input wire [5:0] i_producer_valid;
	output reg [127:0] o_value;
	reg [23:0] match_word;
	reg [23:0] grant;
	reg [3:0] seen;
	always @(*) begin
		if (_sv2v_0)
			;
		match_word = 0;
		grant = 0;
		seen = 0;
		o_value = 0;
		begin : sv2v_autoblock_1
			reg signed [31:0] s;
			for (s = 0; s < 4; s = s + 1)
				begin
					begin : sv2v_autoblock_2
						reg signed [31:0] rank;
						for (rank = 0; rank < 6; rank = rank + 1)
							begin
								match_word[(s * 6) + rank] = (i_used[s] && i_producer_valid[((rank / 2) * 2) + (1 - (rank % 2))]) && (i_tag[s * 6+:6] == i_producer_tag[(((rank / 2) * 2) + (1 - (rank % 2))) * 6+:6]);
								grant[(s * 6) + rank] = match_word[(s * 6) + rank] && !seen[s];
								seen[s] = seen[s] | match_word[(s * 6) + rank];
								o_value[s * 32+:32] = o_value[s * 32+:32] | (i_producer_value[(((rank / 2) * 2) + (1 - (rank % 2))) * 32+:32] & {32 {grant[(s * 6) + rank]}});
							end
					end
					o_value[s * 32+:32] = o_value[s * 32+:32] | (i_value[s * 32+:32] & {32 {!seen[s]}});
				end
		end
	end
	initial _sv2v_0 = 0;
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
	(* dont_retime *) reg [ENTRIES - 1:0] read_valid;
	reg [ENTRIES - 1:0] valid_next;
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
		.HOLD_READ(1'b1),
		.REGISTER_COLLISION(1'b1)
	) u_entries(
		.i_clk(i_clk),
		.i_wr_en(write_enable),
		.i_rd_en(i_lookup),
		.i_wr_data(write_entry),
		.i_wr_addr(wr_index),
		.i_rd_addr(rd_index),
		.o_rd_data(read_entry)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		valid_next = valid;
		if (write_enable)
			valid_next[wr_index] = 1'b1;
	end
	always @(posedge i_clk) begin
		if (i_reset || i_clear) begin
			valid <= {ENTRIES {1'b0}};
			read_valid <= {ENTRIES {1'b0}};
		end
		else begin
			valid <= valid_next;
			if (i_lookup)
				read_valid <= valid_next;
		end
		if (i_lookup) begin
			read_pc <= i_pc;
			read_thumb <= i_thumb;
		end
	end
	assign o_hit = (read_valid[read_pc[INDEX_W:1]] && (read_entry[TAG_W + 36-:((TAG_W + 36) >= 37 ? TAG_W + 0 : 38 - (TAG_W + 36))] == read_pc[31:INDEX_W + 1])) && (read_entry[36] == read_thumb);
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
module arm9v2_rotate (
	i_value,
	i_amount,
	i_type,
	i_register,
	i_carry,
	o_value,
	o_carry,
	o_preserve,
	o_rrx
);
	reg _sv2v_0;
	input wire [31:0] i_value;
	input wire [7:0] i_amount;
	input wire [1:0] i_type;
	input wire i_register;
	input wire i_carry;
	output reg [31:0] o_value;
	output reg o_carry;
	output reg o_preserve;
	output reg o_rrx;
	wire [4:0] amount = (i_type == 0 ? -i_amount[4:0] : i_amount[4:0]);
	wire [31:0] stage [0:5];
	assign stage[0] = i_value;
	genvar _gv_sa_rot_stage_1;
	generate
		for (_gv_sa_rot_stage_1 = 0; _gv_sa_rot_stage_1 < 5; _gv_sa_rot_stage_1 = _gv_sa_rot_stage_1 + 1) begin : g_rotate
			localparam sa_rot_stage = _gv_sa_rot_stage_1;
			genvar _gv_sa_rot_bit_1;
			for (_gv_sa_rot_bit_1 = 0; _gv_sa_rot_bit_1 < 32; _gv_sa_rot_bit_1 = _gv_sa_rot_bit_1 + 1) begin : g_bit
				localparam sa_rot_bit = _gv_sa_rot_bit_1;
				assign stage[sa_rot_stage + 1][sa_rot_bit] = (amount[sa_rot_stage] ? stage[sa_rot_stage][(sa_rot_bit + (1 << sa_rot_stage)) % 32] : stage[sa_rot_stage][sa_rot_bit]);
			end
		end
	endgenerate
	wire [31:0] left_mask = 32'hffffffff << i_amount[4:0];
	wire [31:0] right_mask = 32'hffffffff >> i_amount[4:0];
	always @(*) begin
		if (_sv2v_0)
			;
		o_preserve = 0;
		o_rrx = 0;
		case (i_type)
			0: begin
				o_value = stage[5] & left_mask;
				o_carry = stage[5][0];
			end
			1: begin
				o_value = stage[5] & right_mask;
				o_carry = stage[5][31];
			end
			2: begin
				o_value = (stage[5] & right_mask) | ({32 {i_value[31]}} & ~right_mask);
				o_carry = stage[5][31];
			end
			default: begin
				o_value = stage[5];
				o_carry = stage[5][31];
			end
		endcase
		if (i_amount == 0) begin
			o_value = i_value;
			o_carry = i_carry;
			o_preserve = 1;
			if (!i_register)
				case (i_type)
					1: begin
						o_value = 0;
						o_carry = i_value[31];
						o_preserve = 0;
					end
					2: begin
						o_value = {32 {i_value[31]}};
						o_carry = i_value[31];
						o_preserve = 0;
					end
					3: begin
						o_value = {i_carry, i_value[31:1]};
						o_carry = i_value[0];
						o_preserve = 0;
						o_rrx = 1;
					end
					default:
						;
				endcase
		end
		else if ((i_type != 3) && |i_amount[7:5]) begin
			o_value = (i_type == 2 ? {32 {i_value[31]}} : 32'd0);
			o_carry = (i_type == 2 ? i_value[31] : (i_amount == 32 ? (i_type == 0 ? i_value[0] : i_value[31]) : 1'b0));
		end
	end
	initial _sv2v_0 = 0;
endmodule
module arm9_alu (
	i_a,
	i_b,
	i_op,
	i_flags,
	i_shift_carry,
	o_result,
	o_flags
);
	reg _sv2v_0;
	input wire [31:0] i_a;
	input wire [31:0] i_b;
	input wire [3:0] i_op;
	input wire [3:0] i_flags;
	input wire i_shift_carry;
	output reg [31:0] o_result;
	output reg [3:0] o_flags;
	wire inv_a;
	wire inv_b;
	wire cin;
	reg arithmetic;
	wire [31:0] a;
	wire [31:0] b;
	wire [32:0] sum;
	wire unused = &{1'b0, i_flags[3:2]};
	assign inv_a = (i_op == 4'h3) || (i_op == 4'h7);
	assign inv_b = ((i_op == 4'h2) || (i_op == 4'h6)) || (i_op == 4'ha);
	assign cin = (((i_op == 4'h5) || (i_op == 4'h6)) || (i_op == 4'h7) ? i_flags[1] : inv_a || inv_b);
	assign a = i_a ^ {32 {inv_a}};
	assign b = i_b ^ {32 {inv_b}};
	assign sum = ({1'b0, a} + {1'b0, b}) + {32'd0, cin};
	always @(*) begin
		if (_sv2v_0)
			;
		arithmetic = 1'b0;
		case (i_op)
			4'h0, 4'h8: o_result = i_a & i_b;
			4'h1, 4'h9: o_result = i_a ^ i_b;
			4'hc: o_result = i_a | i_b;
			4'hd: o_result = i_b;
			4'he: o_result = i_a & ~i_b;
			4'hf: o_result = ~i_b;
			default: begin
				o_result = sum[31:0];
				arithmetic = 1'b1;
			end
		endcase
		o_flags = {o_result[31], o_result == 0, i_shift_carry, i_flags[0]};
		if (arithmetic) begin
			o_flags[3:2] = {sum[31], sum[31:0] == 0};
			o_flags[1] = sum[32];
			o_flags[0] = (a[31] == b[31]) && (a[31] != sum[31]);
		end
	end
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
	parameter [0:0] REGISTER_COLLISION = 1'b0;
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
	(* dont_retime *) reg hazard_ff;
	wire concurrent_access;
	assign concurrent_access = i_wr_en & i_rd_en;
	generate
		if (REGISTER_COLLISION) begin : g_registered_collision
			(* dont_retime *) reg [$clog2(DEPTH) - 1:0] rd_addr_ff;
			(* dont_retime *) reg [$clog2(DEPTH) - 1:0] wr_addr_ff;
			(* dont_retime *) reg concurrent_ff;
			always @(posedge i_clk)
				if (!HOLD_READ || i_rd_en) begin
					rd_addr_ff <= i_rd_addr;
					wr_addr_ff <= i_wr_addr;
					concurrent_ff <= concurrent_access;
					buffer_ff <= i_wr_data;
				end
			wire [1:1] sv2v_tmp_2E4ED;
			assign sv2v_tmp_2E4ED = concurrent_ff && (rd_addr_ff == wr_addr_ff);
			always @(*) hazard_ff = sv2v_tmp_2E4ED;
		end
		else begin : g_original_collision
			wire hazard_nxt = (i_wr_addr == i_rd_addr) && concurrent_access;
			wire [WIDTH - 1:0] buffer_nxt = (hazard_nxt ? i_wr_data : {WIDTH {1'bx}});
			always @(posedge i_clk)
				if (!HOLD_READ || i_rd_en) begin
					hazard_ff <= hazard_nxt;
					buffer_ff <= buffer_nxt;
				end
		end
	endgenerate
	assign o_rd_data = (hazard_ff ? buffer_ff : mem_rd_data);
endmodule
module zap_mode16_decoder (
	i_instruction,
	i_instruction_valid,
	i_offset,
	i_prev_prefix,
	i_irq,
	i_fiq,
	i_cpsr_ff_t,
	o_instruction,
	o_instruction_valid,
	o_und,
	o_force32_align,
	o_irq,
	o_fiq
);
	reg _sv2v_0;
	parameter [0:0] V4T = 1'd0;
	input wire [31:0] i_instruction;
	input wire i_instruction_valid;
	input wire [10:0] i_offset;
	input wire i_prev_prefix;
	input wire i_irq;
	input wire i_fiq;
	input wire i_cpsr_ff_t;
	output reg [34:0] o_instruction;
	output reg o_instruction_valid;
	output reg o_und;
	output reg o_force32_align;
	output reg o_irq;
	output reg o_fiq;
	localparam [1:0] SECTION_ID = 2'b10;
	localparam [1:0] PAGE_ID = 2'b01;
	localparam [1:0] FINE_ID = 2'b11;
	localparam [1:0] SPAGE_ID = 2'b10;
	localparam [1:0] LPAGE_ID = 2'b01;
	localparam [1:0] FPAGE_ID = 2'b11;
	localparam [3:0] APSR_NA_NA = 4'b0000;
	localparam [3:0] APSR_RO_RO = 4'b0001;
	localparam [3:0] APSR_RO_NA = 4'b0010;
	localparam [3:0] APSR_RW_NA = 4'b01zz;
	localparam [3:0] APSR_RW_RO = 4'b10zz;
	localparam [3:0] APSR_RW_RW = 4'b11zz;
	localparam [1:0] DAC_MANAGER = 2'b11;
	localparam [1:0] DAC_CLIENT = 2'b01;
	localparam [3:0] FSR_SECTION_DOMAIN_FAULT = 4'b1001;
	localparam [3:0] FSR_SECTION_TRANSLATION_FAULT = 4'b0101;
	localparam [3:0] FSR_SECTION_PERMISSION_FAULT = 4'b1101;
	localparam [3:0] FSR_L1_EXTERNAL_ABORT = 4'b1100;
	localparam [3:0] FSR_PAGE_TRANSLATION_FAULT = 4'b0111;
	localparam [3:0] FSR_PAGE_DOMAIN_FAULT = 4'b1011;
	localparam [3:0] FSR_PAGE_PERMISSION_FAULT = 4'b1111;
	localparam [3:0] FSR_L2_EXTERNAL_ABORT = 4'b1110;
	parameter [3:0] TERMINAL_EXCEPTION = 4'b0010;
	localparam [3:0] AND = 4'd0;
	localparam [3:0] EOR = 4'd1;
	localparam [3:0] SUB = 4'd2;
	localparam [3:0] RSB = 4'd3;
	localparam [3:0] ADD = 4'd4;
	localparam [3:0] ADC = 4'd5;
	localparam [3:0] SBC = 4'd6;
	localparam [3:0] RSC = 4'd7;
	localparam [3:0] TST = 4'd8;
	localparam [3:0] TEQ = 4'd9;
	localparam [3:0] CMP = 4'd10;
	localparam [3:0] CMN = 4'd11;
	localparam [3:0] ORR = 4'd12;
	localparam [3:0] MOV = 4'd13;
	localparam [3:0] BIC = 4'd14;
	localparam [3:0] MVN = 4'd15;
	localparam [4:0] MUL = 5'd16;
	localparam [4:0] MLA = 5'd17;
	localparam [4:0] FMOV = 5'd18;
	localparam [4:0] MMOV = 5'd19;
	localparam [4:0] UMLALL = 5'd20;
	localparam [4:0] UMLALH = 5'd21;
	localparam [4:0] SMLALL = 5'd22;
	localparam [4:0] SMLALH = 5'd23;
	localparam [4:0] CLZ = 5'd24;
	localparam [4:0] OP_QADD = 5'd25;
	localparam [4:0] OP_QSUB = 5'd26;
	localparam [4:0] OP_QDADD = 5'd27;
	localparam [4:0] OP_QDSUB = 5'd28;
	localparam [5:0] SMULW0 = 6'd30;
	localparam [5:0] SMULW1 = 6'd32;
	localparam [5:0] SMUL00 = 6'd34;
	localparam [5:0] SMUL01 = 6'd36;
	localparam [5:0] SMUL10 = 6'd38;
	localparam [5:0] SMUL11 = 6'd40;
	localparam [5:0] SMLA00 = 6'd42;
	localparam [5:0] SMLA01 = 6'd44;
	localparam [5:0] SMLA10 = 6'd46;
	localparam [5:0] SMLA11 = 6'd48;
	localparam [5:0] SMLAW0 = 6'd50;
	localparam [5:0] SMLAW1 = 6'd52;
	localparam [5:0] SMLAL00L = 6'd54;
	localparam [5:0] SMLAL00H = 6'd55;
	localparam [5:0] SMLAL01L = 6'd56;
	localparam [5:0] SMLAL01H = 6'd57;
	localparam [5:0] SMLAL10L = 6'd58;
	localparam [5:0] SMLAL10H = 6'd59;
	localparam [5:0] SMLAL11L = 6'd60;
	localparam [5:0] SMLAL11H = 6'd61;
	localparam [5:0] FADD = 6'd62;
	localparam [5:0] OP_SMULW0 = 6'd30;
	localparam [5:0] OP_SMULW1 = 6'd32;
	localparam [5:0] OP_SMUL00 = 6'd34;
	localparam [5:0] OP_SMUL01 = 6'd36;
	localparam [5:0] OP_SMUL10 = 6'd38;
	localparam [5:0] OP_SMUL11 = 6'd40;
	localparam [5:0] OP_SMLA00 = 6'd42;
	localparam [5:0] OP_SMLA01 = 6'd44;
	localparam [5:0] OP_SMLA10 = 6'd46;
	localparam [5:0] OP_SMLA11 = 6'd48;
	localparam [5:0] OP_SMLAW0 = 6'd50;
	localparam [5:0] OP_SMLAW1 = 6'd52;
	localparam [5:0] OP_SMLAL00L = 6'd54;
	localparam [5:0] OP_SMLAL00H = 6'd55;
	localparam [5:0] OP_SMLAL01L = 6'd56;
	localparam [5:0] OP_SMLAL01H = 6'd57;
	localparam [5:0] OP_SMLAL10L = 6'd58;
	localparam [5:0] OP_SMLAL10H = 6'd59;
	localparam [5:0] OP_SMLAL11L = 6'd60;
	localparam [5:0] OP_SMLAL11H = 6'd61;
	localparam [5:0] SAT_MOV = 6'd49;
	localparam [3:0] EQ = 4'h0;
	localparam [3:0] NE = 4'h1;
	localparam [3:0] CS = 4'h2;
	localparam [3:0] CC = 4'h3;
	localparam [3:0] MI = 4'h4;
	localparam [3:0] PL = 4'h5;
	localparam [3:0] VS = 4'h6;
	localparam [3:0] VC = 4'h7;
	localparam [3:0] HI = 4'h8;
	localparam [3:0] LS = 4'h9;
	localparam [3:0] GE = 4'ha;
	localparam [3:0] LT = 4'hb;
	localparam [3:0] GT = 4'hc;
	localparam [3:0] LE = 4'hd;
	localparam [3:0] AL = 4'he;
	localparam [3:0] NV = 4'hf;
	localparam [31:0] N = 32'd31;
	localparam [31:0] Z = 32'd30;
	localparam [31:0] C = 32'd29;
	localparam [31:0] V = 32'd28;
	localparam [31:0] Q = 32'd27;
	localparam [31:0] I = 32'd7;
	localparam [31:0] F = 32'd6;
	localparam [31:0] T = 32'd5;
	localparam [31:0] ZAP_CPSR_MODE = 32'd4;
	localparam [0:0] INDEX_EN = 1'd0;
	localparam [0:0] IMMED_EN = 1'd1;
	localparam [4:0] FIQ = 5'b10001;
	localparam [4:0] IRQ = 5'b10010;
	localparam [4:0] ABT = 5'b10111;
	localparam [4:0] SVC = 5'b10011;
	localparam [4:0] USR = 5'b10000;
	localparam [4:0] SYS = 5'b11111;
	localparam [4:0] UND = 5'b11011;
	localparam [31:0] SMLAxy = 32'bzzzz00010000zzzzzzzzzzzz1zz0zzzz;
	localparam [31:0] SMLAWy = 32'bzzzz00010010zzzzzzzzzzzz1z00zzzz;
	localparam [31:0] SMLALxy = 32'bzzzz00010100zzzzzzzzzzzz1zz0zzzz;
	localparam [31:0] SMULWy = 32'bzzzz00010010zzzz0000zzzz1z10zzzz;
	localparam [31:0] SMULxy = 32'bzzzz00010110zzzz0000zzzz1zz0zzzz;
	localparam [31:0] CLZ_INSTRUCTION = 32'bzzzz000101101111zzzz11110001zzzz;
	localparam [31:0] QADD = 32'bzzzz00010000zzzzzzzz00000101zzzz;
	localparam [31:0] QSUB = 32'bzzzz00010010zzzzzzzz00000101zzzz;
	localparam [31:0] QDADD = 32'bzzzz00010100zzzzzzzz00000101zzzz;
	localparam [31:0] QDSUB = 32'bzzzz00010110zzzzzzzz00000101zzzz;
	localparam [31:0] PLD = 32'b111101z1z101zzzz1111zzzzzzzzzzzz;
	localparam [31:0] DATA_PROCESSING_IMMEDIATE = 32'bzzzz001zzzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] DATA_PROCESSING_REGISTER_SPECIFIED_SHIFT = 32'bzzzz000zzzzzzzzzzzzzzzzz0zz1zzzz;
	localparam [31:0] DATA_PROCESSING_INSTRUCTION_SPECIFIED_SHIFT = 32'bzzzz000zzzzzzzzzzzzzzzzzzzz0zzzz;
	localparam [31:0] BRANCH_INSTRUCTION = 32'bzzzz101zzzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] MRS = 32'bzzzz00010z001111zzzzzzzzzzzzzzzz;
	localparam [31:0] MSR_IMMEDIATE = 32'bzzzz00110z10zzzz1111zzzzzzzzzzzz;
	localparam [31:0] MSR = 32'bzzzz00010z10zzzz1111zzzzzzzzzzzz;
	localparam [31:0] LS_INSTRUCTION_SPECIFIED_SHIFT = 32'bzzzz011zzzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] LS_IMMEDIATE = 32'bzzzz010zzzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] BX_INST = 32'bzzzz000100101111111111110001zzzz;
	localparam [31:0] MULT_INST = 32'bzzzz000000zzzzzzzzzzzzzz1001zzzz;
	localparam [31:0] LMULT_INST = 32'bzzzz00001zzzzzzzzzzzzzzz1001zzzz;
	localparam [31:0] HALFWORD_LS = 32'bzzzz000zzzzzzzzzzzzzzzzz1zz1zzzz;
	localparam [31:0] SOFTWARE_INTERRUPT = 32'bzzzz1111zzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] SWAP = 32'bzzzz00010z00zzzzzzzz00001001zzzz;
	localparam [31:0] MCR = 32'bzzzz1110zzz0zzzzzzzz1111zzz1zzzz;
	localparam [31:0] MCR2 = 32'b11111110zzz0zzzzzzzzzzzzzzz1zzzz;
	localparam [31:0] MRC = 32'bzzzz1110zzz1zzzzzzzz1111zzz1zzzz;
	localparam [31:0] MRC2 = 32'b11111110zzz1zzzzzzzzzzzzzzz1zzzz;
	localparam [31:0] LDC = 32'bzzzz110zzzz1zzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] STC = 32'bzzzz110zzzz0zzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] LDC2 = 32'b1111110zzzz1zzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] STC2 = 32'b1111110zzzz0zzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] CDP = 32'bzzzz1110zzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] BLX1 = 32'b1111101zzzzzzzzzzzzzzzzzzzzzzzzz;
	localparam [31:0] BLX2 = 32'bzzzz000100101111111111110011zzzz;
	localparam [31:0] BKPT = 32'b111000010010zzzzzzzzzzzz0111zzzz;
	localparam [15:0] T_BRANCH_COND = 16'b1101zzzzzzzzzzzz;
	localparam [15:0] T_BRANCH_NOCOND = 16'b11100zzzzzzzzzzz;
	localparam [15:0] T_BL = 16'b1111zzzzzzzzzzzz;
	localparam [15:0] T_BLX1 = 16'b11101zzzzzzzzzzz;
	localparam [15:0] T_BLX2 = 16'b010001111zzzz000;
	localparam [15:0] T_BX = 16'b010001110zzzz000;
	localparam [15:0] T_SWI = 16'b11011111zzzzzzzz;
	localparam [15:0] T_SHIFT = 16'b000zzzzzzzzzzzzz;
	localparam [15:0] T_ADD_SUB_LO = 16'b00011zzzzzzzzzzz;
	localparam [15:0] T_MCAS_IMM = 16'b001zzzzzzzzzzzzz;
	localparam [15:0] T_ALU_LO = 16'b010000zzzzzzzzzz;
	localparam [15:0] T_ALU_HI = 16'b010001zzzzzzzzzz;
	localparam [15:0] T_GET_ADDR = 16'b1010zzzzzzzzzzzz;
	localparam [15:0] T_MOD_SP = 16'b10110000zzzzzzzz;
	localparam [15:0] T_PC_REL_LOAD = 16'b01001zzzzzzzzzzz;
	localparam [15:0] T_LDR_STR_5BIT_OFF = 16'b011zzzzzzzzzzzzz;
	localparam [15:0] T_LDRH_STRH_5BIT_OFF = 16'b1000zzzzzzzzzzzz;
	localparam [15:0] T_LDRH_STRH_REG = 16'b0101zzzzzzzzzzzz;
	localparam [15:0] T_SP_REL_LDR_STR = 16'b1001zzzzzzzzzzzz;
	localparam [15:0] T_LDMIA_STMIA = 16'b1100zzzzzzzzzzzz;
	localparam [15:0] T_POP_PUSH = 16'b1011z10zzzzzzzzz;
	localparam [15:0] T_BKPT = 16'b10111110zzzzzzzz;
	localparam [31:0] TOTAL_ARCH_REGS = 28;
	localparam [3:0] ARCH_SP = 13;
	localparam [3:0] ARCH_LR = 14;
	localparam [3:0] ARCH_PC = 15;
	localparam [4:0] RAZ_REGISTER = 16;
	localparam [4:0] ARCH_USR2_R8 = 18;
	localparam [4:0] ARCH_USR2_R9 = 19;
	localparam [4:0] ARCH_USR2_R10 = 20;
	localparam [4:0] ARCH_USR2_R11 = 21;
	localparam [4:0] ARCH_USR2_R12 = 22;
	localparam [4:0] ARCH_USR2_R13 = 23;
	localparam [4:0] ARCH_USR2_R14 = 24;
	localparam [4:0] ARCH_DUMMY_REG0 = 25;
	localparam [4:0] ARCH_DUMMY_REG1 = 26;
	localparam [4:0] ARCH_CPSR = 17;
	localparam [4:0] ARCH_CURR_SPSR = 27;
	localparam [31:0] TOTAL_PHY_REGS = 40;
	localparam [5:0] PHY_PC = 15;
	localparam [5:0] PHY_RAZ_REGISTER = 16;
	localparam [5:0] PHY_CPSR = 17;
	localparam [5:0] PHY_USR_R0 = 0;
	localparam [5:0] PHY_USR_R1 = 1;
	localparam [5:0] PHY_USR_R2 = 2;
	localparam [5:0] PHY_USR_R3 = 3;
	localparam [5:0] PHY_USR_R4 = 4;
	localparam [5:0] PHY_USR_R5 = 5;
	localparam [5:0] PHY_USR_R6 = 6;
	localparam [5:0] PHY_USR_R7 = 7;
	localparam [5:0] PHY_USR_R8 = 8;
	localparam [5:0] PHY_USR_R9 = 9;
	localparam [5:0] PHY_USR_R10 = 10;
	localparam [5:0] PHY_USR_R11 = 11;
	localparam [5:0] PHY_USR_R12 = 12;
	localparam [5:0] PHY_USR_R13 = 13;
	localparam [5:0] PHY_USR_R14 = 14;
	localparam [5:0] PHY_FIQ_R8 = 18;
	localparam [5:0] PHY_FIQ_R9 = 19;
	localparam [5:0] PHY_FIQ_R10 = 20;
	localparam [5:0] PHY_FIQ_R11 = 21;
	localparam [5:0] PHY_FIQ_R12 = 22;
	localparam [5:0] PHY_FIQ_R13 = 23;
	localparam [5:0] PHY_FIQ_R14 = 24;
	localparam [5:0] PHY_IRQ_R13 = 25;
	localparam [5:0] PHY_IRQ_R14 = 26;
	localparam [5:0] PHY_SVC_R13 = 27;
	localparam [5:0] PHY_SVC_R14 = 28;
	localparam [5:0] PHY_UND_R13 = 29;
	localparam [5:0] PHY_UND_R14 = 30;
	localparam [5:0] PHY_ABT_R13 = 31;
	localparam [5:0] PHY_ABT_R14 = 32;
	localparam [5:0] PHY_DUMMY_REG0 = 33;
	localparam [5:0] PHY_DUMMY_REG1 = 34;
	localparam [5:0] PHY_FIQ_SPSR = 35;
	localparam [5:0] PHY_IRQ_SPSR = 36;
	localparam [5:0] PHY_SVC_SPSR = 37;
	localparam [5:0] PHY_UND_SPSR = 38;
	localparam [5:0] PHY_ABT_SPSR = 39;
	localparam [1:0] LSL = 0;
	localparam [1:0] LSR = 1;
	localparam [1:0] ASR = 2;
	localparam [1:0] ROR = 3;
	localparam [2:0] RRC = 4;
	localparam [2:0] RORI = 5;
	localparam [2:0] ROR_1 = 6;
	localparam [2:0] LSL_SAT = 7;
	localparam [2:0] CTI_BURST = 3'b010;
	localparam [2:0] CTI_EOB = 3'b111;
	localparam [31:0] RST_VECTOR = 32'h00000000;
	localparam [31:0] UND_VECTOR = 32'h00000004;
	localparam [31:0] SWI_VECTOR = 32'h00000008;
	localparam [31:0] PABT_VECTOR = 32'h0000000c;
	localparam [31:0] DABT_VECTOR = 32'h00000010;
	localparam [31:0] IRQ_VECTOR = 32'h00000018;
	localparam [31:0] FIQ_VECTOR = 32'h0000001c;
	localparam [1:0] SNT = 2'b00;
	localparam [1:0] WNT = 2'b01;
	localparam [1:0] WT = 2'b10;
	localparam [1:0] ST = 2'b11;
	localparam [31:0] ZAP_SRCDEST_EXTEND = 32'd32;
	localparam [31:0] ZAP_DP_RB_EXTEND = 32'd32;
	localparam [31:0] ZAP_BASE_EXTEND = 32'd33;
	localparam [31:0] ZAP_DP_RD_EXTEND = 32'd33;
	localparam [31:0] ZAP_DP_RA_EXTEND = 32'd34;
	localparam [31:0] ZAP_OPCODE_EXTEND = 32'd35;
	wire [10:0] offset_w;
	assign offset_w = i_offset[10:0];
	always @(*) begin
		if (_sv2v_0)
			;
		o_instruction_valid = i_instruction_valid;
		o_und = 1'd0;
		o_instruction[34:0] = {3'd0, i_instruction};
		o_irq = i_irq;
		o_fiq = i_fiq;
		o_force32_align = 1'd0;
		if (i_cpsr_ff_t && i_instruction_valid) begin
			if ((i_instruction[15:0] | 16'b0000000011111111) == 16'b1101111111111111) begin
				o_instruction[34:0] = 35'h00f000000;
				o_instruction[31:28] = AL;
				o_instruction[7:0] = i_instruction[7:0];
			end
			else if ((i_instruction[15:0] | 16'b0000011111111111) == 16'b0001111111111111) begin : tskDecodeAddSubLo
				reg [3:0] rn;
				reg [3:0] rd;
				reg [3:0] rs;
				reg [11:0] imm;
				o_instruction = 35'd0;
				rn = {1'd0, i_instruction[8:6]};
				rd = {1'd0, i_instruction[2:0]};
				rs = {1'd0, i_instruction[5:3]};
				imm = {8'd0, rn};
				case ({i_instruction[9], i_instruction[10]})
					0: o_instruction[31:0] = {AL, 3'b000, ADD, 1'd1, rs, rd, 8'd0, rn};
					1: o_instruction[31:0] = {AL, 3'b001, ADD, 1'd1, rs, rd, imm};
					2: o_instruction[31:0] = {AL, 3'b000, SUB, 1'd1, rs, rd, 8'd0, rn};
					3: o_instruction[31:0] = {AL, 3'b001, SUB, 1'd1, rs, rd, imm};
					default: o_instruction[31:0] = 1'sbx;
				endcase
			end
			else if ((i_instruction[15:0] | 16'b0000000001111000) == 16'b0100011111111000) begin
				o_instruction[34:0] = {31'h0e12fff3, i_instruction[6:3]};
				o_irq = 1'd0;
				o_fiq = 1'd0;
			end
			else if ((i_instruction[15:0] | 16'b0000000001111000) == 16'b0100011101111000) begin
				o_instruction[34:0] = 35'h0012fff10;
				o_instruction[31:28] = AL;
				o_instruction[3:0] = i_instruction[6:3];
			end
			else if ((i_instruction[15:0] | 16'b0000000011111111) == 16'b1011111011111111) begin : decodeBkPt
				o_instruction[31:0] = 32'b11100001001000000000000001110000;
			end
			else
				casez (i_instruction[15:0])
					T_BLX1: begin
						o_instruction[34:0] = 35'd0;
						o_instruction[31:25] = 7'b1111101;
						o_instruction[24] = 1'd0;
						o_instruction[23:0] = $signed({offset_w[10], offset_w[10], offset_w[10:0], i_instruction[10:0]});
						o_instruction[23:0] = o_instruction[23:0] - 1;
						o_instruction[34] = 1'd1;
						o_irq = 1'd0;
						o_fiq = 1'd0;
					end
					T_BRANCH_COND: begin
						o_instruction[34:0] = {3'h4, i_instruction[11:8], 28'ha000000};
						o_instruction[23:0] = $signed({{16 {i_instruction[7]}}, i_instruction[7:0]});
						if (i_instruction[11:8] == 4'b1110)
							o_und = 1'd1;
					end
					T_BRANCH_NOCOND: begin
						o_instruction[34:0] = {3'h4, AL, 28'ha000000};
						o_instruction[23:0] = $signed({{13 {i_instruction[10]}}, i_instruction[10:0]});
					end
					T_BL:
						case (i_instruction[11])
							1'd0: begin
								o_instruction[11:0] = i_instruction[11:0];
								o_instruction[27:12] = 16'd0;
								o_instruction[31:28] = 4'b1111;
								o_instruction[34:32] = 3'b000;
								o_irq = (V4T ? i_irq : 1'd0);
								o_fiq = (V4T ? i_fiq : 1'd0);
							end
							1'd1:
								if (V4T && !i_prev_prefix) begin
									o_instruction[34:0] = 35'd0;
									o_instruction[10:0] = i_instruction[10:0];
									o_instruction[27:12] = 16'd1;
									o_instruction[31:28] = 4'b1111;
									o_irq = i_irq;
									o_fiq = i_fiq;
								end
								else begin
									o_instruction[34:0] = {3'h4, AL, 28'hb000000};
									o_instruction[23:0] = $signed({offset_w[10], offset_w[10], offset_w[10:0], i_instruction[10:0]});
									o_instruction[23:0] = o_instruction[23:0] - 1;
									o_irq = (V4T ? i_irq : 1'd0);
									o_fiq = (V4T ? i_fiq : 1'd0);
								end
							default: begin
								o_instruction = 1'sbx;
								o_irq = 1'sbx;
								o_fiq = 1'sbx;
							end
						endcase
					T_SHIFT: begin
						o_instruction[34:0] = 35'd0;
						o_instruction[31:28] = AL;
						o_instruction[27:26] = 2'b00;
						o_instruction[25] = 1'd0;
						o_instruction[24:21] = MOV;
						o_instruction[20] = 1'd1;
						o_instruction[19:16] = 4'd0;
						o_instruction[15:12] = {1'd0, i_instruction[2:0]};
						o_instruction[11:7] = i_instruction[10:6];
						o_instruction[6:5] = i_instruction[12:11];
						o_instruction[3:0] = {1'd0, i_instruction[5:3]};
					end
					T_MCAS_IMM: begin : tskDecodeMcasImm
						reg [1:0] op;
						reg [3:0] rd;
						reg [11:0] imm;
						o_instruction[34:0] = 0;
						op = i_instruction[12:11];
						rd = {1'd0, i_instruction[10:8]};
						imm = {4'd0, i_instruction[7:0]};
						case (op)
							0: o_instruction[31:0] = {AL, 3'b001, MOV, 1'd1, rd, rd, imm};
							1: o_instruction[31:0] = {AL, 3'b001, CMP, 1'd1, rd, rd, imm};
							2: o_instruction[31:0] = {AL, 3'b001, ADD, 1'd1, rd, rd, imm};
							3: o_instruction[31:0] = {AL, 3'b001, SUB, 1'd1, rd, rd, imm};
							default: o_instruction[31:0] = 1'sbx;
						endcase
					end
					T_ALU_LO: begin : tskDecAluLo
						reg [3:0] op;
						reg [3:0] rs;
						reg [3:0] rd;
						op = i_instruction[9:6];
						rs = {1'd0, i_instruction[5:3]};
						rd = {1'd0, i_instruction[2:0]};
						o_instruction[34:0] = 35'd0;
						case (op)
							4'd0: o_instruction[31:0] = {AL, 3'b000, AND, 1'd1, rd, rd, 8'd0, rs};
							4'd1: o_instruction[31:0] = {AL, 3'b000, EOR, 1'd1, rd, rd, 8'd0, rs};
							4'd2: o_instruction[31:0] = {AL, 3'b000, MOV, 1'd1, rd, rd, rs, 1'd0, LSL, 1'd1, rd};
							4'd3: o_instruction[31:0] = {AL, 3'b000, MOV, 1'd1, rd, rd, rs, 1'd0, LSR, 1'd1, rd};
							4'd4: o_instruction[31:0] = {AL, 3'b000, MOV, 1'd1, rd, rd, rs, 1'd0, ASR, 1'd1, rd};
							4'd5: o_instruction[31:0] = {AL, 3'b000, ADC, 1'd1, rd, rd, 8'd0, rs};
							4'd6: o_instruction[31:0] = {AL, 3'b000, SBC, 1'd1, rd, rd, 8'd0, rs};
							4'd7: o_instruction[31:0] = {AL, 3'b000, MOV, 1'd1, rd, rd, rs, 1'd0, ROR, 1'd1, rd};
							4'd8: o_instruction[31:0] = {AL, 3'b000, TST, 1'd1, rd, rd, 8'd0, rs};
							4'd9: o_instruction[31:0] = {AL, 3'b001, RSB, 1'd1, rs, rd, 12'd0};
							4'd10: o_instruction[31:0] = {AL, 3'b000, CMP, 1'd1, rd, rd, 8'd0, rs};
							4'd11: o_instruction[31:0] = {AL, 3'b000, CMN, 1'd1, rd, rd, 8'd0, rs};
							4'd12: o_instruction[31:0] = {AL, 3'b000, ORR, 1'd1, rd, rd, 8'd0, rs};
							4'd13: o_instruction[31:0] = {AL, 8'h01, rd, 4'd0, rd, 4'b1001, rs};
							4'd14: o_instruction[31:0] = {AL, 3'b000, BIC, 1'd1, rd, rd, 8'd0, rs};
							4'd15: o_instruction[31:0] = {AL, 3'b000, MVN, 1'd1, rd, rd, 8'd0, rs};
							default: o_instruction[31:0] = 1'sbx;
						endcase
					end
					T_ALU_HI: begin : dcAluHi
						reg [1:0] op;
						reg [3:0] rd;
						reg [3:0] rs;
						o_instruction[34:0] = 35'd0;
						op = i_instruction[9:8];
						rd = {i_instruction[7], i_instruction[2:0]};
						rs = {i_instruction[6], i_instruction[5:3]};
						case (op)
							2'd0: o_instruction[31:0] = {AL, 3'b000, ADD, 1'b0, rd, rd, 8'd0, rs};
							2'd1: o_instruction[31:0] = {AL, 3'b000, CMP, 1'b1, rd, rd, 8'd0, rs};
							2'd2: o_instruction[31:0] = {AL, 3'b000, MOV, 1'b0, rd, rd, 8'd0, rs};
							default: o_instruction = 1'sbx;
						endcase
					end
					T_PC_REL_LOAD: begin : dcPcRelLoad
						reg [3:0] rd;
						reg [11:0] imm;
						rd = {1'd0, i_instruction[10:8]};
						imm = {2'd0, i_instruction[7:0], 2'd0};
						o_force32_align = 1'd1;
						o_instruction[34:0] = {3'd0, AL, 12'h59f, rd, imm};
					end
					T_LDR_STR_5BIT_OFF: begin : dcLdrStr5BitOff
						reg [3:0] rn;
						reg [3:0] rd;
						reg [11:0] imm;
						o_instruction[34:0] = 0;
						rn = {1'd0, i_instruction[5:3]};
						rd = {1'd0, i_instruction[2:0]};
						if (i_instruction[12] == 1'd0)
							imm[11:0] = {5'd0, i_instruction[10:6], 2'd0};
						else
							imm[11:0] = {7'd0, i_instruction[10:6]};
						o_instruction[34:0] = {3'd0, AL, 5'h0b, i_instruction[12], 1'd0, i_instruction[11], rn, rd, imm};
					end
					T_LDRH_STRH_5BIT_OFF: begin : dcdLdrhStrh5BitOff
						reg [3:0] rn;
						reg [3:0] rd;
						reg [7:0] imm;
						o_instruction[34:0] = 0;
						rn = {1'd0, i_instruction[5:3]};
						rd = {1'd0, i_instruction[2:0]};
						imm[7:0] = {2'd0, i_instruction[10:6], 1'd0};
						o_instruction[34:0] = {3'd0, AL, 7'b0001110, i_instruction[11], rn, rd, imm[7:4], 4'hb, imm[3:0]};
					end
					T_LDRH_STRH_REG: begin : sv2v_autoblock_1
						reg X;
						reg S;
						reg H;
						reg [3:0] srcdest;
						reg [3:0] base;
						reg [11:0] offset;
						X = i_instruction[9];
						S = i_instruction[10];
						H = i_instruction[11];
						srcdest = {1'd0, i_instruction[2:0]};
						base = {1'd0, i_instruction[5:3]};
						offset = {9'd0, i_instruction[8:6]};
						if (X == 0)
							case ({H, S})
								2'd0: o_instruction[34:0] = {3'd0, AL, 8'h78, base, srcdest, offset};
								2'd1: o_instruction[34:0] = {3'd0, AL, 8'h7c, base, srcdest, offset};
								2'd2: o_instruction[34:0] = {3'd0, AL, 8'h79, base, srcdest, offset};
								2'd3: o_instruction[34:0] = {3'd0, AL, 8'h7d, base, srcdest, offset};
								default: o_instruction[34:0] = 1'sbx;
							endcase
						else
							case ({S, H})
								2'd0: o_instruction[34:0] = {3'd0, AL, 8'h18, base, srcdest, 8'h0b, offset[3:0]};
								2'd1: o_instruction[34:0] = {3'd0, AL, 8'h19, base, srcdest, 8'h0b, offset[3:0]};
								2'd2: o_instruction[34:0] = {3'd0, AL, 8'h19, base, srcdest, 8'h0d, offset[3:0]};
								2'd3: o_instruction[34:0] = {3'd0, AL, 8'h19, base, srcdest, 8'h0f, offset[3:0]};
								default: o_instruction[34:0] = 1'sbx;
							endcase
					end
					T_SP_REL_LDR_STR: begin : sv2v_autoblock_2
						reg [3:0] srcdest;
						reg [3:0] base;
						reg [11:0] imm;
						srcdest = {1'd0, i_instruction[10:8]};
						base = ARCH_SP;
						imm = {2'd0, i_instruction[7:0], 2'd0};
						o_instruction[34:0] = {3'd0, AL, 7'h2c, i_instruction[11], base, srcdest, imm};
					end
					T_LDMIA_STMIA: begin : sv2v_autoblock_3
						reg [3:0] base;
						reg [15:0] reglist;
						base = {1'd0, i_instruction[10:8]};
						reglist = {8'd0, i_instruction[7:0]};
						o_instruction[34:0] = {3'd0, AL, 7'h45, i_instruction[11], base, reglist};
					end
					T_POP_PUSH: begin : sv2v_autoblock_4
						reg [3:0] base;
						reg [15:0] reglist;
						o_instruction[34:0] = 0;
						base = 13;
						reglist = {8'd0, i_instruction[7:0]};
						if ((i_instruction[8] == 1) && i_instruction[11])
							reglist[15] = 1'd1;
						else if ((i_instruction[8] == 1) && !i_instruction[11])
							reglist[14] = 1'd1;
						o_instruction[34:0] = {3'd0, AL, 7'h49, i_instruction[11], base, reglist};
						if (i_instruction[11])
							o_instruction[24:23] = 2'b01;
					end
					T_GET_ADDR: begin : sv2v_autoblock_5
						reg [11:0] imm;
						reg [3:0] rd;
						rd = {1'd0, i_instruction[10:8]};
						imm[7:0] = i_instruction[7:0];
						imm[11:8] = 4'd15;
						o_instruction[34:0] = 0;
						o_instruction[31:0] = {AL, 3'b001, ADD, 5'h0f, rd, imm};
						o_force32_align = 1;
						if (i_instruction[11])
							o_instruction[31:0] = {AL, 3'b001, ADD, 5'h0d, rd, imm};
					end
					T_MOD_SP: begin : sv2v_autoblock_6
						reg [11:0] imm;
						imm[7:0] = {1'd0, i_instruction[6:0]};
						imm[11:8] = 4'd15;
						o_instruction[34:0] = 0;
						o_instruction[31:0] = {AL, 3'b001, ADD, 9'h0dd, imm};
						if (i_instruction[7] != 0)
							o_instruction[31:0] = {AL, 3'b001, SUB, 9'h0dd, imm};
					end
					default: o_und = 1;
				endcase
		end
	end
	initial _sv2v_0 = 0;
endmodule
module zap_register_file (
	i_clk,
	i_reset,
	i_wen,
	i_wr_addr_a,
	i_wr_addr_b,
	i_wr_addr_c,
	i_wr_data_a,
	i_wr_data_b,
	i_wr_data_c,
	i_rd_addr_a,
	i_rd_addr_b,
	i_rd_addr_c,
	i_rd_addr_d,
	o_rd_data_a,
	o_rd_data_b,
	o_rd_data_c,
	o_rd_data_d
);
	input wire i_clk;
	input wire i_reset;
	input wire i_wen;
	input wire [39:0] i_wr_addr_a;
	input wire [39:0] i_wr_addr_b;
	input wire [39:0] i_wr_addr_c;
	input wire [31:0] i_wr_data_a;
	input wire [31:0] i_wr_data_b;
	input wire [31:0] i_wr_data_c;
	input wire [5:0] i_rd_addr_a;
	input wire [5:0] i_rd_addr_b;
	input wire [5:0] i_rd_addr_c;
	input wire [5:0] i_rd_addr_d;
	output wire [31:0] o_rd_data_a;
	output wire [31:0] o_rd_data_b;
	output wire [31:0] o_rd_data_c;
	output wire [31:0] o_rd_data_d;
	reg [1279:0] mem;
	always @(posedge i_clk)
		if (i_reset)
			mem <= {32'd40 {32'd0}};
		else begin : sv2v_autoblock_1
			reg signed [31:0] r;
			for (r = 0; r < 40; r = r + 1)
				begin
					if (i_wen && i_wr_addr_a[r])
						mem[r * 32+:32] <= i_wr_data_a;
					if (i_wen && i_wr_addr_b[r])
						mem[r * 32+:32] <= i_wr_data_b;
					if (i_wr_addr_c[r])
						mem[r * 32+:32] <= i_wr_data_c;
				end
		end
	assign o_rd_data_a = mem[i_rd_addr_a * 32+:32];
	assign o_rd_data_b = mem[i_rd_addr_b * 32+:32];
	assign o_rd_data_c = mem[i_rd_addr_c * 32+:32];
	assign o_rd_data_d = mem[i_rd_addr_d * 32+:32];
endmodule
module arm9v2_front_decode (
	i_clk,
	i_reset,
	i_flush,
	o_ready,
	i_mode,
	i_wen,
	i_wr_addr_a,
	i_wr_addr_b,
	i_wr_addr_c,
	i_locked,
	i_early_tag,
	i_early_valid,
	i_wr_data_a,
	i_wr_data_b,
	i_wr_data_c,
	i_ready,
	o_valid,
	o_pc,
	o_instruction,
	o_pc_base,
	o_next_pc,
	o_raw,
	o_mode,
	o_thumb,
	o_fault,
	o_force_align,
	o_reg_shift,
	o_kind,
	o_condition,
	o_tag,
	o_used,
	o_value,
	o_dest,
	o_first,
	o_last,
	o_reg_count,
	o_offset,
	o_writeback_offset,
	o_transfer_reg,
	o_branch_target,
	o_direct,
	o_match_taken,
	o_match_fallthrough,
	o_predicted,
	o_pred_hit,
	o_pred_target,
	o_pred_state,
	o_pred_kind,
	o_ras_pointer,
	o_ras_count,
	o_hazard,
	o_redirect,
	o_redirect_thumb,
	o_redirect_target,
	o_redirect_link,
	o_redirect_pointer,
	o_redirect_count,
	o_redirect_action,
	i_backend_target,
	i_backend_link,
	i_backend_thumb,
	i_backend_pointer,
	i_backend_count,
	i_backend_action,
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
	o_stall
);
	parameter [0:0] PREDICTOR = 1'b1;
	parameter [31:0] RESET_VECTOR = 0;
	input wire i_clk;
	input wire i_reset;
	input wire i_flush;
	output wire o_ready;
	input wire [4:0] i_mode;
	input wire i_wen;
	input wire [39:0] i_wr_addr_a;
	input wire [39:0] i_wr_addr_b;
	input wire [39:0] i_wr_addr_c;
	input wire [39:0] i_locked;
	input wire [23:0] i_early_tag;
	input wire [3:0] i_early_valid;
	input wire [31:0] i_wr_data_a;
	input wire [31:0] i_wr_data_b;
	input wire [31:0] i_wr_data_c;
	input wire i_ready;
	output wire o_valid;
	output wire [31:0] o_pc;
	output wire [31:0] o_instruction;
	output wire [31:0] o_pc_base;
	output wire [31:0] o_next_pc;
	output wire [15:0] o_raw;
	output wire [4:0] o_mode;
	output wire o_thumb;
	output wire o_fault;
	output wire o_force_align;
	output wire o_reg_shift;
	output wire [3:0] o_kind;
	output wire [3:0] o_condition;
	output wire [23:0] o_tag;
	output wire [3:0] o_used;
	output wire [127:0] o_value;
	output wire [11:0] o_dest;
	output wire o_first;
	output wire o_last;
	output wire [4:0] o_reg_count;
	output wire signed [7:0] o_offset;
	output wire signed [7:0] o_writeback_offset;
	output wire [3:0] o_transfer_reg;
	output wire [31:0] o_branch_target;
	output wire o_direct;
	output wire o_match_taken;
	output wire o_match_fallthrough;
	output wire o_predicted;
	output wire o_pred_hit;
	output wire [31:0] o_pred_target;
	output wire [1:0] o_pred_state;
	output wire [1:0] o_pred_kind;
	output wire [2:0] o_ras_pointer;
	output wire [3:0] o_ras_count;
	output wire o_hazard;
	output wire o_redirect;
	output wire o_redirect_thumb;
	output wire [31:0] o_redirect_target;
	output wire [31:0] o_redirect_link;
	output wire [2:0] o_redirect_pointer;
	output wire [3:0] o_redirect_count;
	output wire [1:0] o_redirect_action;
	input wire [31:0] i_backend_target;
	input wire [31:0] i_backend_link;
	input wire i_backend_thumb;
	input wire [2:0] i_backend_pointer;
	input wire [3:0] i_backend_count;
	input wire [1:0] i_backend_action;
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
	wire f_valid;
	wire f_thumb;
	wire f_fault;
	wire f_predicted;
	wire f_hit;
	wire [31:0] f_pc;
	wire [31:0] f_word;
	wire [31:0] f_target;
	wire [1:0] f_state;
	wire [1:0] f_kind;
	wire [2:0] f_pointer;
	wire [3:0] f_count;
	arm9v2_fetch #(
		.RESET_VECTOR(RESET_VECTOR),
		.PREDICTOR(PREDICTOR)
	) u_fetch(
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_redirect(i_flush || o_redirect),
		.i_redirect_target((i_flush ? i_backend_target : o_redirect_target)),
		.i_redirect_thumb((i_flush ? i_backend_thumb : o_redirect_thumb)),
		.i_redirect_pointer((i_flush ? i_backend_pointer : o_redirect_pointer)),
		.i_redirect_count((i_flush ? i_backend_count : o_redirect_count)),
		.i_redirect_action((i_flush ? i_backend_action : o_redirect_action)),
		.i_redirect_link((i_flush ? i_backend_link : o_redirect_link)),
		.i_predictor_clear(i_predictor_clear),
		.i_update(i_update),
		.i_update_pc(i_update_pc),
		.i_update_target(i_update_target),
		.i_update_thumb(i_update_thumb),
		.i_update_taken(i_update_taken),
		.i_update_hit(i_update_hit),
		.i_update_state(i_update_state),
		.i_update_kind(i_update_kind),
		.i_data(i_data),
		.i_ack(i_ack),
		.i_error(i_error),
		.i_retry(i_retry),
		.i_fill_pending(i_fill_pending),
		.i_fill_done(i_fill_done),
		.i_fill_fault(i_fill_fault),
		.o_address_nxt(o_address_nxt),
		.o_address_check(o_address_check),
		.o_address(o_address),
		.o_request(o_request),
		.o_stall(o_stall),
		.i_ready(o_ready),
		.o_valid(f_valid),
		.o_pc(f_pc),
		.o_word(f_word),
		.o_thumb(f_thumb),
		.o_fault(f_fault),
		.o_predicted(f_predicted),
		.o_pred_hit(f_hit),
		.o_pred_target(f_target),
		.o_pred_state(f_state),
		.o_pred_kind(f_kind),
		.o_ras_pointer(f_pointer),
		.o_ras_count(f_count)
	);
	arm9v2_decode u_decode(
		.i_valid(f_valid),
		.i_pc(f_pc),
		.i_word(f_word),
		.i_thumb(f_thumb),
		.i_fault(f_fault),
		.i_predicted(f_predicted),
		.i_pred_hit(f_hit),
		.i_pred_target(f_target),
		.i_pred_state(f_state),
		.i_pred_kind(f_kind),
		.i_ras_pointer(f_pointer),
		.i_ras_count(f_count),
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_flush(i_flush),
		.o_ready(o_ready),
		.i_mode(i_mode),
		.i_wen(i_wen),
		.i_wr_addr_a(i_wr_addr_a),
		.i_wr_addr_b(i_wr_addr_b),
		.i_wr_addr_c(i_wr_addr_c),
		.i_locked(i_locked),
		.i_early_tag(i_early_tag),
		.i_early_valid(i_early_valid),
		.i_wr_data_a(i_wr_data_a),
		.i_wr_data_b(i_wr_data_b),
		.i_wr_data_c(i_wr_data_c),
		.i_ready(i_ready),
		.o_valid(o_valid),
		.o_pc(o_pc),
		.o_instruction(o_instruction),
		.o_pc_base(o_pc_base),
		.o_next_pc(o_next_pc),
		.o_raw(o_raw),
		.o_mode(o_mode),
		.o_thumb(o_thumb),
		.o_fault(o_fault),
		.o_force_align(o_force_align),
		.o_reg_shift(o_reg_shift),
		.o_kind(o_kind),
		.o_condition(o_condition),
		.o_tag(o_tag),
		.o_used(o_used),
		.o_value(o_value),
		.o_dest(o_dest),
		.o_first(o_first),
		.o_last(o_last),
		.o_reg_count(o_reg_count),
		.o_offset(o_offset),
		.o_writeback_offset(o_writeback_offset),
		.o_transfer_reg(o_transfer_reg),
		.o_branch_target(o_branch_target),
		.o_direct(o_direct),
		.o_match_taken(o_match_taken),
		.o_match_fallthrough(o_match_fallthrough),
		.o_predicted(o_predicted),
		.o_pred_hit(o_pred_hit),
		.o_pred_target(o_pred_target),
		.o_pred_state(o_pred_state),
		.o_pred_kind(o_pred_kind),
		.o_ras_pointer(o_ras_pointer),
		.o_ras_count(o_ras_count),
		.o_hazard(o_hazard),
		.o_redirect(o_redirect),
		.o_redirect_thumb(o_redirect_thumb),
		.o_redirect_target(o_redirect_target),
		.o_redirect_link(o_redirect_link),
		.o_redirect_pointer(o_redirect_pointer),
		.o_redirect_count(o_redirect_count),
		.o_redirect_action(o_redirect_action)
	);
endmodule
module arm9v2_front_execute (
	i_clk,
	i_reset,
	i_flush,
	i_ready,
	i_cpsr,
	i_backend_target,
	i_backend_thumb,
	i_predictor_clear,
	i_locked,
	i_data,
	i_ack,
	i_error,
	i_retry,
	i_fill_pending,
	i_fill_done,
	i_fill_fault,
	o_execute_ready,
	o_valid,
	o_pc,
	o_instruction,
	o_cpsr,
	o_cpsr_next,
	o_kind,
	o_thumb,
	o_fault,
	o_first,
	o_last,
	o_condition_pass,
	o_dest,
	o_result,
	o_write,
	o_write_flags,
	o_pc_write,
	o_memory,
	o_store,
	o_data_address,
	o_store_data,
	o_flags,
	o_redirect,
	o_redirect_thumb,
	o_redirect_target,
	o_redirect_link,
	o_redirect_pointer,
	o_redirect_count,
	o_redirect_action,
	o_btb_update,
	o_btb_taken,
	o_btb_hit,
	o_btb_target,
	o_btb_state,
	o_btb_kind,
	o_a_valid,
	o_a_can_finish,
	o_s_write,
	o_a_dest,
	o_a_write,
	o_shift_wait,
	o_multiply_wait,
	o_address_nxt,
	o_address_check,
	o_address,
	o_retire_pc,
	o_retire_instruction,
	o_retire_value,
	o_request,
	o_stall,
	o_retire_valid
);
	parameter [0:0] PREDICTOR = 1'b1;
	parameter [31:0] RESET_VECTOR = 0;
	input wire i_clk;
	input wire i_reset;
	input wire i_flush;
	input wire i_ready;
	input wire [31:0] i_cpsr;
	input wire [31:0] i_backend_target;
	input wire i_backend_thumb;
	input wire i_predictor_clear;
	input wire [39:0] i_locked;
	input wire [31:0] i_data;
	input wire i_ack;
	input wire i_error;
	input wire i_retry;
	input wire i_fill_pending;
	input wire i_fill_done;
	input wire i_fill_fault;
	output wire o_execute_ready;
	output wire o_valid;
	output wire [31:0] o_pc;
	output wire [31:0] o_instruction;
	output wire [31:0] o_cpsr;
	output wire [31:0] o_cpsr_next;
	output wire [3:0] o_kind;
	output wire o_thumb;
	output wire o_fault;
	output wire o_first;
	output wire o_last;
	output wire o_condition_pass;
	output wire [11:0] o_dest;
	output wire [63:0] o_result;
	output wire [1:0] o_write;
	output wire o_write_flags;
	output wire o_pc_write;
	output wire o_memory;
	output wire o_store;
	output wire [31:0] o_data_address;
	output wire [31:0] o_store_data;
	output wire [3:0] o_flags;
	output wire o_redirect;
	output wire o_redirect_thumb;
	output wire [31:0] o_redirect_target;
	output wire [31:0] o_redirect_link;
	output wire [2:0] o_redirect_pointer;
	output wire [3:0] o_redirect_count;
	output wire [1:0] o_redirect_action;
	output wire o_btb_update;
	output wire o_btb_taken;
	output wire o_btb_hit;
	output wire [31:0] o_btb_target;
	output wire [1:0] o_btb_state;
	output wire [1:0] o_btb_kind;
	output wire o_a_valid;
	output wire o_a_can_finish;
	output wire [1:0] o_s_write;
	output wire [11:0] o_a_dest;
	output wire [1:0] o_a_write;
	output wire o_shift_wait;
	output wire o_multiply_wait;
	output wire [31:0] o_address_nxt;
	output wire [31:0] o_address_check;
	output wire [31:0] o_address;
	output wire [31:0] o_retire_pc;
	output wire [31:0] o_retire_instruction;
	output wire [31:0] o_retire_value;
	output wire o_request;
	output wire o_stall;
	output wire o_retire_valid;
	wire d_ready;
	wire d_valid;
	wire [31:0] d_pc;
	wire [31:0] d_instruction;
	wire [31:0] d_pc_base;
	wire [31:0] d_next_pc;
	wire [15:0] d_raw;
	wire [4:0] d_mode;
	wire d_thumb;
	wire d_fault;
	wire d_force_align;
	wire d_reg_shift;
	wire [3:0] d_kind;
	wire [3:0] d_condition;
	wire [23:0] d_tag;
	wire [3:0] d_used;
	wire [127:0] d_value;
	wire [11:0] d_dest;
	wire d_first;
	wire d_last;
	wire [4:0] d_reg_count;
	wire signed [7:0] d_offset;
	wire signed [7:0] d_writeback_offset;
	wire [3:0] d_transfer_reg;
	wire [31:0] d_branch_target;
	wire d_direct;
	wire d_match_taken;
	wire d_match_fallthrough;
	wire d_predicted;
	wire d_pred_hit;
	wire [31:0] d_pred_target;
	wire [1:0] d_pred_state;
	wire [1:0] d_pred_kind;
	wire [2:0] d_ras_pointer;
	wire [3:0] d_ras_count;
	wire d_hazard;
	wire d_redirect;
	wire d_redirect_thumb;
	wire [31:0] d_redirect_target;
	wire [31:0] d_redirect_link;
	wire [2:0] d_redirect_pointer;
	wire [3:0] d_redirect_count;
	wire [1:0] d_redirect_action;
	(* dont_retime *) reg [127:0] mw_value;
	(* dont_retime *) reg [23:0] mw_tag;
	(* dont_retime *) reg [3:0] mw_write;
	(* dont_retime *) reg [1:0] mw_valid;
	(* dont_retime *) reg [1:0] mw_flags;
	(* dont_retime *) reg [63:0] mw_pc;
	(* dont_retime *) reg [63:0] mw_ins;
	(* dont_retime *) reg [63:0] mw_cpsr;
	wire [39:0] wa;
	wire [39:0] wb;
	wire [39:0] wc;
	wire [23:0] early_tag;
	wire [3:0] early_valid;
	assign wa = (mw_write[2] && mw_valid[1] ? 40'd1 << mw_tag[12+:6] : 40'd0);
	assign wb = (mw_write[3] && mw_valid[1] ? 40'd1 << mw_tag[18+:6] : 40'd0);
	assign wc = (mw_flags[1] && mw_valid[1] ? 40'd1 << 17 : 40'd0);
	assign early_tag = {o_a_dest, d_dest};
	assign early_valid = {o_a_write & {2 {o_a_valid && !o_a_can_finish}}, o_s_write} & {early_tag[18+:6] != 15, early_tag[12+:6] != 15, early_tag[6+:6] != 15, early_tag[0+:6] != 15};
	always @(posedge i_clk)
		if (i_reset || i_flush) begin
			mw_valid <= 0;
			mw_write <= 0;
			mw_flags <= 0;
			mw_value <= 0;
			mw_tag <= 0;
			mw_pc <= 0;
			mw_ins <= 0;
			mw_cpsr <= 0;
		end
		else if (i_ready) begin
			mw_valid <= {mw_valid[0], o_valid};
			mw_write <= {mw_write[0+:2], o_write};
			mw_flags <= {mw_flags[0], o_write_flags};
			mw_value <= {mw_value[0+:64], o_result};
			mw_tag <= {mw_tag[0+:12], o_dest};
			mw_pc <= {mw_pc[0+:32], o_pc};
			mw_ins <= {mw_ins[0+:32], o_instruction};
			mw_cpsr <= {mw_cpsr[0+:32], o_cpsr_next};
		end
	assign o_retire_valid = (mw_valid[1] && i_ready) && !i_flush;
	assign o_retire_pc = mw_pc[32+:32];
	assign o_retire_instruction = mw_ins[32+:32];
	assign o_retire_value = mw_value[64+:32];
	arm9v2_front_decode #(
		.RESET_VECTOR(RESET_VECTOR),
		.PREDICTOR(PREDICTOR)
	) u_front_decode(
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_flush(i_flush || o_redirect),
		.i_mode(i_cpsr[4:0]),
		.i_wen(i_ready && !i_flush),
		.i_wr_addr_a(wa),
		.i_wr_addr_b(wb),
		.i_wr_addr_c(wc),
		.i_locked(i_locked),
		.i_early_tag(early_tag),
		.i_early_valid(early_valid),
		.i_wr_data_a(mw_value[64+:32]),
		.i_wr_data_b(mw_value[96+:32]),
		.i_wr_data_c(mw_cpsr[32+:32]),
		.i_ready(o_execute_ready),
		.i_backend_target((i_flush ? i_backend_target : o_redirect_target)),
		.i_backend_link(o_redirect_link),
		.i_backend_thumb((i_flush ? i_backend_thumb : o_redirect_thumb)),
		.i_backend_pointer((i_flush ? 3'd0 : o_redirect_pointer)),
		.i_backend_count((i_flush ? 4'd0 : o_redirect_count)),
		.i_backend_action((i_flush ? 2'd3 : o_redirect_action)),
		.i_predictor_clear(i_predictor_clear),
		.i_update(o_btb_update),
		.i_update_pc(o_pc),
		.i_update_target(o_btb_target),
		.i_update_thumb(o_thumb),
		.i_update_taken(o_btb_taken),
		.i_update_hit(o_btb_hit),
		.i_update_state(o_btb_state),
		.i_update_kind(o_btb_kind),
		.i_data(i_data),
		.i_ack(i_ack),
		.i_error(i_error),
		.i_retry(i_retry),
		.i_fill_pending(i_fill_pending),
		.i_fill_done(i_fill_done),
		.i_fill_fault(i_fill_fault),
		.o_ready(d_ready),
		.o_valid(d_valid),
		.o_pc(d_pc),
		.o_instruction(d_instruction),
		.o_pc_base(d_pc_base),
		.o_next_pc(d_next_pc),
		.o_raw(d_raw),
		.o_mode(d_mode),
		.o_thumb(d_thumb),
		.o_fault(d_fault),
		.o_force_align(d_force_align),
		.o_reg_shift(d_reg_shift),
		.o_kind(d_kind),
		.o_condition(d_condition),
		.o_tag(d_tag),
		.o_used(d_used),
		.o_value(d_value),
		.o_dest(d_dest),
		.o_first(d_first),
		.o_last(d_last),
		.o_reg_count(d_reg_count),
		.o_offset(d_offset),
		.o_writeback_offset(d_writeback_offset),
		.o_transfer_reg(d_transfer_reg),
		.o_branch_target(d_branch_target),
		.o_direct(d_direct),
		.o_match_taken(d_match_taken),
		.o_match_fallthrough(d_match_fallthrough),
		.o_predicted(d_predicted),
		.o_pred_hit(d_pred_hit),
		.o_pred_target(d_pred_target),
		.o_pred_state(d_pred_state),
		.o_pred_kind(d_pred_kind),
		.o_ras_pointer(d_ras_pointer),
		.o_ras_count(d_ras_count),
		.o_hazard(d_hazard),
		.o_redirect(d_redirect),
		.o_redirect_thumb(d_redirect_thumb),
		.o_redirect_target(d_redirect_target),
		.o_redirect_link(d_redirect_link),
		.o_redirect_pointer(d_redirect_pointer),
		.o_redirect_count(d_redirect_count),
		.o_redirect_action(d_redirect_action),
		.o_address_nxt(o_address_nxt),
		.o_address_check(o_address_check),
		.o_address(o_address),
		.o_request(o_request),
		.o_stall(o_stall)
	);
	arm9v2_execute u_execute(
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_flush(i_flush),
		.i_cpsr(i_cpsr),
		.i_valid(d_valid),
		.i_pc(d_pc),
		.i_instruction(d_instruction),
		.i_pc_base(d_pc_base),
		.i_next_pc(d_next_pc),
		.i_thumb(d_thumb),
		.i_fault(d_fault),
		.i_force_align(d_force_align),
		.i_reg_shift(d_reg_shift),
		.i_first(d_first),
		.i_last(d_last),
		.i_kind(d_kind),
		.i_condition(d_condition),
		.i_tag(d_tag),
		.i_used(d_used),
		.i_value(d_value),
		.i_dest(d_dest),
		.i_offset(d_offset),
		.i_writeback_offset(d_writeback_offset),
		.i_branch_target(d_branch_target),
		.i_pred_target(d_pred_target),
		.i_direct(d_direct),
		.i_predicted(d_predicted),
		.i_match_taken(d_match_taken),
		.i_match_fallthrough(d_match_fallthrough),
		.i_pred_hit(d_pred_hit),
		.i_pred_state(d_pred_state),
		.i_ras_pointer(d_ras_pointer),
		.i_ras_count(d_ras_count),
		.i_mw_value(mw_value),
		.i_mw_tag(mw_tag),
		.i_mw_valid(mw_write & {{2 {mw_valid[1]}}, {2 {mw_valid[0]}}}),
		.i_ready(i_ready),
		.o_ready(o_execute_ready),
		.o_valid(o_valid),
		.o_pc(o_pc),
		.o_instruction(o_instruction),
		.o_cpsr(o_cpsr),
		.o_cpsr_next(o_cpsr_next),
		.o_kind(o_kind),
		.o_thumb(o_thumb),
		.o_fault(o_fault),
		.o_first(o_first),
		.o_last(o_last),
		.o_condition_pass(o_condition_pass),
		.o_dest(o_dest),
		.o_result(o_result),
		.o_write(o_write),
		.o_write_flags(o_write_flags),
		.o_pc_write(o_pc_write),
		.o_memory(o_memory),
		.o_store(o_store),
		.o_address(o_data_address),
		.o_store_data(o_store_data),
		.o_flags(o_flags),
		.o_redirect(o_redirect),
		.o_redirect_thumb(o_redirect_thumb),
		.o_redirect_target(o_redirect_target),
		.o_redirect_link(o_redirect_link),
		.o_redirect_pointer(o_redirect_pointer),
		.o_redirect_count(o_redirect_count),
		.o_redirect_action(o_redirect_action),
		.o_btb_update(o_btb_update),
		.o_btb_taken(o_btb_taken),
		.o_btb_hit(o_btb_hit),
		.o_btb_target(o_btb_target),
		.o_btb_state(o_btb_state),
		.o_btb_kind(o_btb_kind),
		.o_a_valid(o_a_valid),
		.o_a_can_finish(o_a_can_finish),
		.o_s_write(o_s_write),
		.o_a_dest(o_a_dest),
		.o_a_write(o_a_write),
		.o_shift_wait(o_shift_wait),
		.o_multiply_wait(o_multiply_wait)
	);
	wire unused = &{1'b0, d_ready, d_raw, d_mode, d_reg_count, d_transfer_reg, d_pred_kind, d_hazard, d_redirect, d_redirect_thumb, d_redirect_target, d_redirect_link, d_redirect_pointer, d_redirect_count, d_redirect_action};
endmodule
module cpu_trial (
	clk,
	serial_in,
	address_o,
	data_o,
	observe_o
);
	input wire clk;
	input wire [31:0] serial_in;
	output reg [31:0] address_o;
	output reg [31:0] data_o;
	output reg [31:0] observe_o;
	(* dont_retime *) reg [159:0] stimulus;
	wire i_clk;
	wire i_reset;
	wire i_flush;
	wire i_ready;
	wire [31:0] i_cpsr;
	wire [31:0] i_backend_target;
	wire i_backend_thumb;
	wire i_predictor_clear;
	wire [39:0] i_locked;
	wire [31:0] i_data;
	wire i_ack;
	wire i_error;
	wire i_retry;
	wire i_fill_pending;
	wire i_fill_done;
	wire i_fill_fault;
	wire o_execute_ready;
	wire o_valid;
	wire [31:0] o_pc;
	wire [31:0] o_instruction;
	wire [31:0] o_cpsr;
	wire [31:0] o_cpsr_next;
	wire [3:0] o_kind;
	wire o_thumb;
	wire o_fault;
	wire o_first;
	wire o_last;
	wire o_condition_pass;
	wire [11:0] o_dest;
	wire [63:0] o_result;
	wire [1:0] o_write;
	wire o_write_flags;
	wire o_pc_write;
	wire o_memory;
	wire o_store;
	wire [31:0] o_data_address;
	wire [31:0] o_store_data;
	wire [3:0] o_flags;
	wire o_redirect;
	wire o_redirect_thumb;
	wire [31:0] o_redirect_target;
	wire [31:0] o_redirect_link;
	wire [2:0] o_redirect_pointer;
	wire [3:0] o_redirect_count;
	wire [1:0] o_redirect_action;
	wire o_btb_update;
	wire o_btb_taken;
	wire o_btb_hit;
	wire [31:0] o_btb_target;
	wire [1:0] o_btb_state;
	wire [1:0] o_btb_kind;
	wire o_a_valid;
	wire o_a_can_finish;
	wire [1:0] o_s_write;
	wire [11:0] o_a_dest;
	wire [1:0] o_a_write;
	wire o_shift_wait;
	wire o_multiply_wait;
	wire [31:0] o_address_nxt;
	wire [31:0] o_address_check;
	wire [31:0] o_address;
	wire [31:0] o_retire_pc;
	wire [31:0] o_retire_instruction;
	wire [31:0] o_retire_value;
	wire o_request;
	wire o_stall;
	wire o_retire_valid;
	assign i_clk = clk;
	assign i_reset = stimulus[0:0];
	assign i_flush = stimulus[1:1];
	assign i_ready = stimulus[2:2];
	assign i_cpsr = stimulus[34:3];
	assign i_backend_target = stimulus[66:35];
	assign i_backend_thumb = stimulus[67:67];
	assign i_predictor_clear = stimulus[68:68];
	assign i_locked = stimulus[108:69];
	assign i_data = stimulus[140:109];
	assign i_ack = stimulus[141:141];
	assign i_error = stimulus[142:142];
	assign i_retry = stimulus[143:143];
	assign i_fill_pending = stimulus[144:144];
	assign i_fill_done = stimulus[145:145];
	assign i_fill_fault = stimulus[146:146];
	wire unused = &{1'b0, stimulus[159:147]};
	wire [63:0] flat_o_result = o_result;
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	always @(posedge clk) begin
		stimulus <= {stimulus[127:0], serial_in};
		address_o <= o_address_nxt;
		data_o <= o_data_address;
		observe_o <= ((((((((((((((((((((((((((((((((((((((((((((((((((sv2v_cast_32(o_execute_ready) ^ sv2v_cast_32(o_valid)) ^ o_pc) ^ o_instruction) ^ o_cpsr) ^ o_cpsr_next) ^ sv2v_cast_32(o_kind)) ^ sv2v_cast_32(o_thumb)) ^ sv2v_cast_32(o_fault)) ^ sv2v_cast_32(o_first)) ^ sv2v_cast_32(o_last)) ^ sv2v_cast_32(o_condition_pass)) ^ sv2v_cast_32(o_dest)) ^ flat_o_result[31:0]) ^ flat_o_result[63:32]) ^ sv2v_cast_32(o_write)) ^ sv2v_cast_32(o_write_flags)) ^ sv2v_cast_32(o_pc_write)) ^ sv2v_cast_32(o_memory)) ^ sv2v_cast_32(o_store)) ^ o_data_address) ^ o_store_data) ^ sv2v_cast_32(o_flags)) ^ sv2v_cast_32(o_redirect)) ^ sv2v_cast_32(o_redirect_thumb)) ^ o_redirect_target) ^ o_redirect_link) ^ sv2v_cast_32(o_redirect_pointer)) ^ sv2v_cast_32(o_redirect_count)) ^ sv2v_cast_32(o_redirect_action)) ^ sv2v_cast_32(o_btb_update)) ^ sv2v_cast_32(o_btb_taken)) ^ sv2v_cast_32(o_btb_hit)) ^ o_btb_target) ^ sv2v_cast_32(o_btb_state)) ^ sv2v_cast_32(o_btb_kind)) ^ sv2v_cast_32(o_a_valid)) ^ sv2v_cast_32(o_a_can_finish)) ^ sv2v_cast_32(o_s_write)) ^ sv2v_cast_32(o_a_dest)) ^ sv2v_cast_32(o_a_write)) ^ sv2v_cast_32(o_shift_wait)) ^ sv2v_cast_32(o_multiply_wait)) ^ o_address_nxt) ^ o_address_check) ^ o_address) ^ o_retire_pc) ^ o_retire_instruction) ^ o_retire_value) ^ sv2v_cast_32(o_request)) ^ sv2v_cast_32(o_stall)) ^ sv2v_cast_32(o_retire_valid);
	end
	arm9v2_front_execute u_front_execute(
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_flush(i_flush),
		.i_ready(i_ready),
		.i_cpsr(i_cpsr),
		.i_backend_target(i_backend_target),
		.i_backend_thumb(i_backend_thumb),
		.i_predictor_clear(i_predictor_clear),
		.i_locked(i_locked),
		.i_data(i_data),
		.i_ack(i_ack),
		.i_error(i_error),
		.i_retry(i_retry),
		.i_fill_pending(i_fill_pending),
		.i_fill_done(i_fill_done),
		.i_fill_fault(i_fill_fault),
		.o_execute_ready(o_execute_ready),
		.o_valid(o_valid),
		.o_pc(o_pc),
		.o_instruction(o_instruction),
		.o_cpsr(o_cpsr),
		.o_cpsr_next(o_cpsr_next),
		.o_kind(o_kind),
		.o_thumb(o_thumb),
		.o_fault(o_fault),
		.o_first(o_first),
		.o_last(o_last),
		.o_condition_pass(o_condition_pass),
		.o_dest(o_dest),
		.o_result(o_result),
		.o_write(o_write),
		.o_write_flags(o_write_flags),
		.o_pc_write(o_pc_write),
		.o_memory(o_memory),
		.o_store(o_store),
		.o_data_address(o_data_address),
		.o_store_data(o_store_data),
		.o_flags(o_flags),
		.o_redirect(o_redirect),
		.o_redirect_thumb(o_redirect_thumb),
		.o_redirect_target(o_redirect_target),
		.o_redirect_link(o_redirect_link),
		.o_redirect_pointer(o_redirect_pointer),
		.o_redirect_count(o_redirect_count),
		.o_redirect_action(o_redirect_action),
		.o_btb_update(o_btb_update),
		.o_btb_taken(o_btb_taken),
		.o_btb_hit(o_btb_hit),
		.o_btb_target(o_btb_target),
		.o_btb_state(o_btb_state),
		.o_btb_kind(o_btb_kind),
		.o_a_valid(o_a_valid),
		.o_a_can_finish(o_a_can_finish),
		.o_s_write(o_s_write),
		.o_a_dest(o_a_dest),
		.o_a_write(o_a_write),
		.o_shift_wait(o_shift_wait),
		.o_multiply_wait(o_multiply_wait),
		.o_address_nxt(o_address_nxt),
		.o_address_check(o_address_check),
		.o_address(o_address),
		.o_retire_pc(o_retire_pc),
		.o_retire_instruction(o_retire_instruction),
		.o_retire_value(o_retire_value),
		.o_request(o_request),
		.o_stall(o_stall),
		.o_retire_valid(o_retire_valid)
	);
endmodule
