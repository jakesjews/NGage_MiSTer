// SPDX-License-Identifier: GPL-2.0-or-later
// Minimal synthetic UPP DSP protocol peer, not a DSP instruction interpreter.
// Native Info_SrvMgr requests version data through resource F1, message A0.
// The identity is fabricated and explicit; original NOS builds/validates its
// own INFO reply and runs its unchanged startup test. No SIM-ready or test
// result is injected here. Unknown requests remain unanswered.
module upp_mdi_peer #(
    parameter [ 7:0] RF_VERSION     = 8'h03,
    parameter [39:0] DSP_SW_VERSION = 40'h48444c3031  // "HDL01"
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       rx_valid,
    output wire       rx_ready,
    input  wire [7:0] rx_data,
    input  wire       rx_last,
    output wire       tx_valid,
    input  wire       tx_ready,
    output reg  [7:0] tx_data,
    output wire       tx_last,
    output reg        unsupported
);
    reg [7:0] header   [0:10];
    reg [4:0] received;
    reg active, rf_reply;
    reg  [3:0] sent;
    wire [3:0] reply_last = rf_reply ? 4'd11 : 4'd15;
    assign rx_ready = !active;
    assign tx_valid = active;
    assign tx_last  = active && sent == reply_last;
    always @* begin
        tx_data = 0;
        case (sent)
            0:  tx_data = header[0];
            1:  tx_data = header[2];
            2:  tx_data = header[1];
            3:  tx_data = header[3];
            4:  tx_data = 0;
            5:  tx_data = rf_reply ? 8'd6 : 8'd10;
            6:  tx_data = header[7];
            7:  tx_data = header[6];
            8:  tx_data = header[8];
            9:  tx_data = 8'ha1;
            10: tx_data = rf_reply ? 8'd1 : 8'd5;
            11: tx_data = rf_reply ? RF_VERSION : DSP_SW_VERSION[39:32];
            12: tx_data = DSP_SW_VERSION[31:24];
            13: tx_data = DSP_SW_VERSION[23:16];
            14: tx_data = DSP_SW_VERSION[15:8];
            15: tx_data = DSP_SW_VERSION[7:0];
        endcase
    end
    always @(posedge clk) begin
        if (reset) begin
            received    <= 0;
            active      <= 0;
            rf_reply    <= 0;
            sent        <= 0;
            unsupported <= 0;
        end else begin
            unsupported <= 0;
            if (rx_valid && rx_ready) begin
                if (received < 11) header[received[3:0]] <= rx_data;
                if (rx_last) begin
                    received <= 0;
                    // The native MDI task emits media12. Media00 remains
                    // supported for the existing transport-level fixtures.
                    if (received == 11 && (header[0] == 8'h12 || header[0] == 0) &&
                        (header[1] & 8'hfc) == 8'h7c && header[3] == 8'hf1 &&
                        header[4] == 0 && header[5] == 6 && header[9] == 8'ha0 &&
                        ((header[8] == 8'h20 && header[10] == 2) ||
                         (header[8] == 8'h40 && header[10] == 1))) begin
                        active   <= 1;
                        rf_reply <= header[8] == 8'h20;
                        sent     <= 0;
                    end else unsupported <= 1;
                end else if (received != 31) received <= received + 1'b1;
            end
            if (tx_valid && tx_ready) begin
                if (tx_last) begin
                    active <= 0;
                    sent   <= 0;
                end else sent <= sent + 1'b1;
            end
        end
    end
endmodule
