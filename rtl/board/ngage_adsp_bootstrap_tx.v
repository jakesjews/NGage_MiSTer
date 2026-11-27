// SPDX-License-Identifier: GPL-2.0-or-later
// Ported from NGage_MiSTer ngage-v5.
// D550 startup stream, derived from original C55x 03FCA4..03FCD5 and
// 448C33/448CDA. The device initiates D0/01 then D0/04, sequence zero.
// Byte transactions replace serial pins; no baud or physical reset mapping is
// claimed. The parent must request this only after device initialization.
// Completion means bytes delivered, NOT link ready or diagnostic success.
module ngage_adsp_bootstrap_tx (
    input  wire       clk,
    input  wire       reset,
    input  tri0       reset_only,
    input  wire       request_valid,
    output wire       request_ready,
    output wire       tx_valid,
    input  wire       tx_ready,
    output reg  [7:0] tx_data,
    output wire       complete_valid,
    input  wire       complete_ready
);
    localparam IDLE = 2'd0, SEND = 2'd1, DONE = 2'd2;
    reg [1:0] state;
    reg [4:0] index;

    assign request_ready  = !reset && state == IDLE;
    assign tx_valid       = !reset && state == SEND;
    assign complete_valid = !reset && state == DONE;

    // Sync55/55 is excluded from the big-endian XOR16 checksum. Packet one
    // has length4; packet two length3 plus one alignment byte before checksum.
    // Exact vectors are independently accepted by the original ARM verifier.
    always @* begin
        case (index)
            0, 1, 14, 15: tx_data = 8'h55;
            2, 16:        tx_data = 8'h20;
            4, 18:        tx_data = 8'h78;
            5, 19:        tx_data = 8'hd0;
            7, 22:        tx_data = 8'h04;
            8, 10, 23:    tx_data = 8'h01;
            9:            tx_data = 8'h11;
            11, 24:       tx_data = 8'h60;
            12:           tx_data = 8'h58;
            13:           tx_data = 8'ha5;
            21:           tx_data = 8'h03;
            26:           tx_data = 8'h3c;
            27:           tx_data = 8'hd2;
            default:      tx_data = 8'h00;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            index <= 0;
        end else begin
            case (state)
                IDLE:
                if (request_valid) begin
                    index <= reset_only ? 5'd14 : 5'd0;
                    state <= SEND;
                end
                SEND:
                if (tx_ready) begin
                    if (index == 27) state <= DONE;
                    else index <= index + 1'b1;
                end
                DONE:    if (complete_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
