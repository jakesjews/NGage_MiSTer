// SPDX-License-Identifier: GPL-3.0-or-later
// ARMv4 barrel shifter. i_register distinguishes Rs[7:0] shifts from
// immediate shift encodings (LSR/ASR #0 mean #32; ROR #0 means RRX).
module arm9_shift (
    input  logic [31:0] i_value,
    input  logic [7:0]  i_amount,
    input  logic [1:0]  i_type,       // LSL, LSR, ASR, ROR
    input  logic        i_register,
    input  logic        i_carry,
    output logic [31:0] o_value,
    output logic        o_carry
);
    logic [5:0][31:0] stage;
    logic [5:0] carry;
    logic [31:0] reversed, shifted;
    logic left, arithmetic, rotate;
    assign left = i_type == 2'b00;
    assign arithmetic = i_type == 2'b10;
    assign rotate = i_type == 2'b11;
    for (genvar b = 0; b < 32; b++) begin : g_reverse
        assign reversed[b] = i_value[31-b];
        assign shifted[b] = left ? stage[5][31-b] : stage[5][b];
    end
    assign stage[0] = left ? reversed : i_value;
    assign carry[0] = i_carry;
    // One right barrel also implements left shifts, by reversing the bits.
    for (genvar s = 0; s < 5; s++) begin : g_barrel
        localparam integer K = 1 << s;
        wire [K-1:0] fill = rotate ? stage[s][K-1:0] :
                                      {K{arithmetic && i_value[31]}};
        assign stage[s+1] = i_amount[s] ? {fill, stage[s][31:K]} : stage[s];
        assign carry[s+1] = i_amount[s] ? stage[s][K-1] : carry[s];
    end
    always_comb begin
        o_value = shifted;
        o_carry = carry[5];
        if (i_amount == 0) begin
            o_value = i_value;
            o_carry = i_carry;
            if (!i_register) begin
                case (i_type)
                    2'b01: begin o_value = 0; o_carry = i_value[31]; end
                    2'b10: begin o_value = {32{i_value[31]}}; o_carry = i_value[31]; end
                    2'b11: begin o_value = {i_carry, i_value[31:1]}; o_carry = i_value[0]; end
                    default: begin end // LSL #0 preserves C.
                endcase
            end
        end else if (rotate) begin
            // Rs=32,64,... rotates by zero but copies bit 31 to carry.
            o_carry = shifted[31];
        end else if (|i_amount[7:5]) begin
            o_value = arithmetic ? {32{i_value[31]}} : 32'd0;
            o_carry = arithmetic ? i_value[31] :
                      i_amount == 8'd32 ? (left ? i_value[0] : i_value[31]) : 1'b0;
        end
    end
endmodule
