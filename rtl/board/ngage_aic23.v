// SPDX-License-Identifier: GPL-2.0-or-later
// Ported from NGage_MiSTer ngage-v5.
// N501 TLV320AIC23 control boundary. A complete address/control-word transfer
// replaces the physical I2C pins here; serial timing and PCM are not modeled.
// Diagnostic42 uses slave1A, register15/data0. Other controls are unsupported.
module ngage_aic23 (
    input  wire        clk,
    input  wire        reset,
    input  wire        control_valid,
    input  wire [ 6:0] control_address,
    input  wire [15:0] control_word,
    output wire        control_ready,
    output reg         response_valid,
    output reg         response_error,
    output reg         reset_seen
);
    assign control_ready = !reset;
    always @(posedge clk) begin
        if (reset) begin
            response_valid <= 0;
            response_error <= 0;
            reset_seen     <= 0;
        end else begin
            response_valid <= control_valid && control_ready;
            response_error <= 0;
            if (control_valid && control_ready) begin
                response_error <= control_address != 7'h1a || control_word != 16'h1e00;
                if (control_address == 7'h1a && control_word == 16'h1e00) reset_seen <= 1;
            end
        end
    end
endmodule
