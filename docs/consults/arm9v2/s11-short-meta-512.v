module proof (
	i_clk,
	i_reset,
	i_hold,
	tag_ram_clear,
	tag_ram_clean,
	line_clear,
	valid,
	dirty,
	lru,
	rd_set,
	tag_ram_wr_addr,
	pend_addr,
	hit_upd_set,
	hit_pend_set,
	tag_ram_wr_en,
	pend_en,
	i_cache_tag_dirty,
	pend_dirty,
	hit_upd_en,
	hit_upd_way,
	hit_pend_en,
	hit_pend_val,
	wr_sel,
	pend_sel
);
	reg _sv2v_0;
	input i_clk;
	input i_reset;
	input i_hold;
	input tag_ram_clear;
	input tag_ram_clean;
	input line_clear;
	input [1023:0] valid;
	input [1023:0] dirty;
	input [511:0] lru;
	input [8:0] rd_set;
	input [8:0] tag_ram_wr_addr;
	input [8:0] pend_addr;
	input [8:0] hit_upd_set;
	input [8:0] hit_pend_set;
	input tag_ram_wr_en;
	input pend_en;
	input i_cache_tag_dirty;
	input pend_dirty;
	input hit_upd_en;
	input hit_upd_way;
	input hit_pend_en;
	input hit_pend_val;
	input [1:0] wr_sel;
	input [1:0] pend_sel;
	localparam SHORT_READ = 1;
	localparam WAYS = 2;
	localparam LINES = 512;
	localparam SET_W = 9;
	localparam WAY_W = 1;
	localparam FLAT_W = 10;
	wire [1:0] valid_q;
	wire [1:0] dirty_q;
	wire lru_q;
	reg [1:0] old_valid;
	reg [1:0] old_dirty;
	reg old_lru;
	function automatic [9:0] sv2v_cast_10;
		input reg [9:0] inp;
		sv2v_cast_10 = inp;
	endfunction
	function automatic [9:0] flat;
		input [0:0] w;
		input [8:0] set;
		flat = sv2v_cast_10({w, set});
	endfunction
	function automatic lru_fwd;
		input [8:0] set;
		input reg prev;
		lru_fwd = ((set == hit_pend_set) && hit_pend_en ? hit_pend_val : (((set == pend_addr) && pend_en) && |pend_sel ? pend_sel[0] : prev));
	endfunction
	function automatic lru_fwd_now;
		input [8:0] set;
		input reg prev;
		lru_fwd_now = ((set == hit_upd_set) && hit_upd_en ? ~hit_upd_way : (((set == tag_ram_wr_addr) && tag_ram_wr_en) && |wr_sel ? wr_sel[0] : lru_fwd(set, prev)));
	endfunction
	function automatic [4:0] sv2v_cast_5;
		input reg [4:0] inp;
		sv2v_cast_5 = inp;
	endfunction
	function automatic signed [0:0] sv2v_cast_1_signed;
		input reg signed [0:0] inp;
		sv2v_cast_1_signed = inp;
	endfunction
	function automatic signed [8:0] sv2v_cast_9_signed;
		input reg signed [8:0] inp;
		sv2v_cast_9_signed = inp;
	endfunction
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	generate
		if (SHORT_READ) begin : g_short_meta
			localparam LOW_W = 4;
			localparam BANKS = 32;
			localparam BANK_W = 5;
			reg [32:0] descriptor;
			reg [32:0] valid_desc;
			reg [32:0] dirty_desc;
			wire unused_valid_dirty;
			assign unused_valid_dirty = |{valid_desc[1], valid_desc[0]};
			reg [63:0] valid_bank;
			reg [63:0] dirty_bank;
			reg [4:0] valid_select;
			reg [4:0] dirty_select;
			always @(*) begin
				if (_sv2v_0)
					;
				descriptor[32-:9] = rd_set;
				descriptor[23-:9] = tag_ram_wr_addr;
				descriptor[14-:9] = pend_addr;
				descriptor[5-:2] = wr_sel & {WAYS {tag_ram_wr_en}};
				descriptor[3-:2] = pend_sel & {WAYS {pend_en}};
				descriptor[1] = i_cache_tag_dirty;
				descriptor[0] = pend_dirty;
			end
			always @(posedge i_clk)
				if (i_reset) begin
					valid_desc <= 1'sb0;
					dirty_desc <= 1'sb0;
					valid_bank <= 1'sb0;
					dirty_bank <= 1'sb0;
					valid_select <= 1'sb0;
					dirty_select <= 1'sb0;
				end
				else begin
					if ((!i_hold || tag_ram_clear) || line_clear) begin
						valid_desc <= descriptor;
						valid_select <= sv2v_cast_5(rd_set >> LOW_W);
						begin : sv2v_autoblock_1
							reg signed [31:0] w;
							for (w = 0; w < WAYS; w = w + 1)
								begin : sv2v_autoblock_2
									reg signed [31:0] b;
									for (b = 0; b < BANKS; b = b + 1)
										valid_bank[(w * 32) + b] <= valid[flat(sv2v_cast_1_signed(w), sv2v_cast_9_signed((b << LOW_W) | sv2v_cast_32_signed(rd_set[3:0])))];
								end
						end
					end
					if ((!i_hold || tag_ram_clean) || line_clear) begin
						dirty_desc <= descriptor;
						dirty_select <= sv2v_cast_5(rd_set >> LOW_W);
						begin : sv2v_autoblock_3
							reg signed [31:0] w;
							for (w = 0; w < WAYS; w = w + 1)
								begin : sv2v_autoblock_4
									reg signed [31:0] b;
									for (b = 0; b < BANKS; b = b + 1)
										dirty_bank[(w * 32) + b] <= dirty[flat(sv2v_cast_1_signed(w), sv2v_cast_9_signed((b << LOW_W) | sv2v_cast_32_signed(rd_set[3:0])))];
								end
						end
					end
				end
			genvar _gv_w_1;
			for (_gv_w_1 = 0; _gv_w_1 < WAYS; _gv_w_1 = _gv_w_1 + 1) begin : g_way
				localparam w = _gv_w_1;
				assign valid_q[w] = (((valid_desc[32-:9] == valid_desc[23-:9]) && valid_desc[4 + w]) || ((valid_desc[32-:9] == valid_desc[14-:9]) && valid_desc[2 + w])) || valid_bank[(w * 32) + valid_select];
				assign dirty_q[w] = ((dirty_desc[32-:9] == dirty_desc[23-:9]) && dirty_desc[4 + w] ? dirty_desc[1] : ((dirty_desc[32-:9] == dirty_desc[14-:9]) && dirty_desc[2 + w] ? dirty_desc[0] : dirty_bank[(w * 32) + dirty_select]));
			end
			if (1) begin : g_lru
				reg [31:0] bank_q;
				reg [4:0] bank_select;
				reg [35:0] update_set;
				reg [3:0] update_en;
				reg [3:0] update_val;
				reg [8:0] read_set;
				always @(posedge i_clk)
					if (i_reset) begin
						bank_q <= 1'sb0;
						bank_select <= 1'sb0;
						read_set <= 1'sb0;
						update_set <= 1'sb0;
						update_en <= 1'sb0;
						update_val <= 1'sb0;
					end
					else if ((!i_hold || tag_ram_clear) || line_clear) begin
						read_set <= rd_set;
						bank_select <= sv2v_cast_5(rd_set >> LOW_W);
						begin : sv2v_autoblock_5
							reg signed [31:0] b;
							for (b = 0; b < BANKS; b = b + 1)
								bank_q[b] <= lru[sv2v_cast_9_signed((b << LOW_W) | sv2v_cast_32_signed(rd_set[3:0]))];
						end
						update_set <= {hit_upd_set, tag_ram_wr_addr, hit_pend_set, pend_addr};
						update_en <= {hit_upd_en, tag_ram_wr_en && |wr_sel, hit_pend_en, pend_en && |pend_sel};
						update_val <= {~hit_upd_way, wr_sel[0], hit_pend_val, pend_sel[0]};
					end
				assign lru_q = (update_en[3] && (read_set == update_set[27+:9]) ? update_val[3] : (update_en[2] && (read_set == update_set[18+:9]) ? update_val[2] : (update_en[1] && (read_set == update_set[9+:9]) ? update_val[1] : (update_en[0] && (read_set == update_set[0+:9]) ? update_val[0] : bank_q[bank_select]))));
			end
		end
	endgenerate
	always @(posedge i_clk)
		if (i_reset) begin
			old_valid <= 0;
			old_dirty <= 0;
			old_lru <= 0;
		end
		else begin
			if ((!i_hold || tag_ram_clear) || line_clear) begin
				begin : sv2v_autoblock_6
					reg signed [31:0] w;
					for (w = 0; w < WAYS; w = w + 1)
						old_valid[w] <= (((rd_set == tag_ram_wr_addr) && tag_ram_wr_en) && wr_sel[w] ? 1'd1 : (((rd_set == pend_addr) && pend_en) && pend_sel[w] ? 1'd1 : valid[flat(sv2v_cast_1_signed(w), rd_set)]));
				end
				old_lru <= lru_fwd_now(rd_set, lru[rd_set]);
			end
			if ((!i_hold || tag_ram_clean) || line_clear) begin : sv2v_autoblock_7
				reg signed [31:0] w;
				for (w = 0; w < WAYS; w = w + 1)
					old_dirty[w] <= (((rd_set == tag_ram_wr_addr) && tag_ram_wr_en) && wr_sel[w] ? i_cache_tag_dirty : (((rd_set == pend_addr) && pend_en) && pend_sel[w] ? pend_dirty : dirty[flat(sv2v_cast_1_signed(w), rd_set)]));
			end
		end
	always @(*)
		;
	initial _sv2v_0 = 0;
endmodule
