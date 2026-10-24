module proof(input clk, reset, input [63:0] lock_nxt,
    input [5:0] i_lock_owner_next);
reg [63:0] lock_ff;
reg o_lock_any, o_lock_owner;
reg [5:0] owner;
always @(posedge clk) begin
    owner <= reset ? 0 : i_lock_owner_next;
    lock_ff <= reset ? (64'd0) : (lock_nxt);
    o_lock_any <= reset ? (0) : (|lock_nxt);
    o_lock_owner <= reset ? (0) : (lock_nxt[i_lock_owner_next]);
end
always @* begin
    assert(o_lock_any == (|lock_ff));
    assert(o_lock_owner == lock_ff[owner]);
end
endmodule
