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
    logic [32:0] left_result;
    logic signed [33:0] right_input, right_result;
    logic [63:0] rotate_result;
    logic left, arithmetic, rotate;
    wire unused = &{1'b0, right_result[33], rotate_result[63:32]};
    assign left = i_type == 2'b00;
    assign arithmetic = i_type == 2'b10;
    assign rotate = i_type == 2'b11;
    // Parallel direction networks avoid bit-reversal muxes before and after
    // a shared barrel. All variable shifts are only five bits wide; the
    // ARM >=32 behavior is handled separately below.
    assign left_result = {i_carry, i_value} << i_amount[4:0];
    assign right_input = {arithmetic && i_value[31], i_value, i_carry};
    assign right_result = right_input >>> i_amount[4:0];
    assign rotate_result = {i_value, i_value} >> i_amount[4:0];
    always_comb begin
        case (i_type)
            2'b00: {o_carry, o_value} = left_result;
            2'b01, 2'b10: {o_value, o_carry} = right_result[32:0];
            default: begin
                o_value = rotate_result[31:0];
                o_carry = rotate_result[31];
            end
        endcase
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
            o_carry = rotate_result[31];
        end else if (|i_amount[7:5]) begin
            o_value = arithmetic ? {32{i_value[31]}} : 32'd0;
            o_carry = arithmetic ? i_value[31] :
                      i_amount == 8'd32 ? (left ? i_value[0] : i_value[31]) : 1'b0;
        end
    end
endmodule
