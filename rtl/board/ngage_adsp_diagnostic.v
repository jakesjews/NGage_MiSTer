// SPDX-License-Identifier: GPL-2.0-or-later
// Ported from NGage_MiSTer ngage-v5.
// D550's bounded native test42 operation (451944/451B41 in E403A400H450).
// This is a transaction-level operation, not a C55x interpreter or a packet
// transport. The original test passes iff clock, flash marker and codec reset
// all succeed. Unknown test identifiers are explicitly unsupported.
module ngage_adsp_diagnostic (
    input  wire        clk,
    input  wire        reset,
    input  wire        request_valid,
    output wire        request_ready,
    input  wire [15:0] test_id,
    input  wire        clock_locked,
    input  wire        flash_valid,
    input  wire [15:0] flash_marker,
    output wire        codec_valid,
    input  wire        codec_ready,
    output wire [ 6:0] codec_address,
    output wire [15:0] codec_word,
    input  wire        codec_response_valid,
    input  wire        codec_response_error,
    output reg         response_valid,
    input  wire        response_ready,
    output reg         response_unsupported,
    output reg  [15:0] response_result
);
    localparam IDLE = 2'd0, SEND = 2'd1, WAIT = 2'd2, DONE = 2'd3;
    reg [1:0] state;
    reg       prerequisites;
    assign request_ready = !reset && state == IDLE;
    assign codec_valid   = !reset && state == SEND;
    assign codec_address = 7'h1a;
    assign codec_word    = 16'h1e00;
    always @(posedge clk) begin
        if (reset) begin
            state                <= IDLE;
            prerequisites        <= 0;
            response_valid       <= 0;
            response_result      <= 0;
            response_unsupported <= 0;
        end else begin
            case (state)
                IDLE:
                if (request_valid) begin
                    response_unsupported <= test_id != 16'h42;
                    prerequisites        <= clock_locked && flash_valid && flash_marker == 16'hfffc;
                    if (test_id == 16'h42) state <= SEND;
                    else begin
                        response_valid  <= 1;
                        response_result <= 16'h000c;
                        state           <= DONE;
                    end
                end
                SEND:    if (codec_ready) state <= WAIT;
                WAIT:
                if (codec_response_valid) begin
                    response_valid <= 1;
                    response_result <= prerequisites && !codec_response_error ? 16'h0000 : 16'h000c;
                    state <= DONE;
                end
                DONE:
                if (response_ready) begin
                    response_valid <= 0;
                    state          <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
