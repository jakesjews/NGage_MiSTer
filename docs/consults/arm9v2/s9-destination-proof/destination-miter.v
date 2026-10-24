module destination_miter (
	ins,
	raw_class,
	mode,
	nregs,
	thumb,
	und,
	first,
	list_pc,
	ok
);
	reg _sv2v_0;
	input [31:0] ins;
	input [4:0] raw_class;
	input [4:0] mode;
	input [4:0] nregs;
	input thumb;
	input und;
	input [3:0] first;
	input list_pc;
	output wire ok;
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
	function automatic [5:0] destination0;
		input reg [240:0] p;
		reg valid_class;
		reg half_link;
		reg block;
		reg multiply;
		reg branch;
		reg spsr;
		reg unused_packet;
		reg [4:0] block_mode;
		begin
			unused_packet = &{1'b0, p};
			valid_class = (!p[16] && (p[18] || (p[208:205] != 4'hf))) && !(p[18] && (p[80:76] == 5'b11101));
			half_link = p[18] && ((p[80:76] == 5'b11110) || (p[80:76] == 5'b11111));
			block = ((valid_class && !half_link) && (p[204:202] == 3'b100)) && (p[27-:5] != 0);
			multiply = (valid_class && !half_link) && ((p[208-:32] & 32'h0fc000f0) == 32'h00000090);
			branch = valid_class && (half_link || (p[204:202] == 3'b101));
			spsr = ((((valid_class && !half_link) && p[199]) && (p[32-:5] != 5'h10)) && (p[32-:5] != 5'h1f)) && (((p[208-:32] & 32'h0fb0fff0) == 32'h0120f000) || ((p[208-:32] & 32'h0fb0f000) == 32'h0320f000));
			block_mode = (p[199] && !(p[197] && p[64]) ? 5'h10 : p[32-:5]);
			destination0 = ((((bank({1'b0, p[192:189]}, p[32-:5]) & {6 {!(((block || multiply) || branch) || spsr)}}) | (bank({1'b0, p[22-:4]}, block_mode) & {6 {block}})) | (bank({1'b0, p[196:193]}, p[32-:5]) & {6 {multiply}})) | (bank(5'd14, p[32-:5]) & {6 {branch}})) | (bank(5'd27, p[32-:5]) & {6 {spsr}});
		end
	endfunction
	reg [240:0] p;
	reg [5:0] reference;
	reg [3:0] kind;
	always @(*) begin
		if (_sv2v_0)
			;
		p = 1'sb0;
		p[208-:32] = ins;
		p[80:76] = raw_class;
		p[32-:5] = mode;
		p[27-:5] = nregs;
		p[18] = thumb;
		p[16] = und;
		p[22-:4] = first;
		p[64] = list_pc;
		kind = classify(ins, raw_class, thumb, und, mode == 5'h10, nregs == 0);
		reference = bank({1'b0, ins[15:12]}, mode);
		case (kind)
			K_BLOCK: reference = bank({1'b0, first}, (ins[22] && !(ins[20] && list_pc) ? 5'h10 : mode));
			K_MUL: reference = bank({1'b0, ins[19:16]}, mode);
			K_BRANCH, K_BL_PREFIX, K_BL_SUFFIX: reference = bank(5'd14, mode);
			K_MSR:
				if ((ins[22] && (mode != 5'h10)) && (mode != 5'h1f))
					reference = bank(5'd27, mode);
			default:
				;
		endcase
	end
	assign ok = reference == destination0(p);
	initial _sv2v_0 = 0;
endmodule
