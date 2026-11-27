// SPDX-License-Identifier: GPL-2.0-or-later
// External NEM-4 DSP startup link. The UPP EUART drives the byte boundary;
// D551 and N501 supply the boot signature and codec diagnostic transaction.
module ngage_d550_boot (
    input  wire        clk,
    input  wire        reset,
    input  wire        clock_ready,
    input  wire        receive_enabled,
    input  wire        tx_valid,
    output wire        tx_ready,
    input  wire [ 7:0] tx_data,
    output wire        rx_valid,
    input  wire        rx_ready,
    output wire [ 7:0] rx_data
);
    wire codec_valid, codec_ready, codec_response_valid, codec_response_error;
    wire [6:0] codec_address;
    wire [15:0] codec_word, flash_marker;
    wire flash_valid;

    ngage_adsp_flash_signature d551 (
        .valid (flash_valid),
        .marker(flash_marker)
    );

    ngage_adsp d550 (
        .clk                 (clk),
        .reset               (reset),
        .enabled             (receive_enabled && clock_ready),
        .clock_ready         (clock_ready),
        .flash_valid         (flash_valid),
        .flash_marker        (flash_marker),
        .host_tx_valid       (tx_valid),
        .host_tx_ready       (tx_ready),
        .host_tx_data        (tx_data),
        .host_rx_valid       (rx_valid),
        .host_rx_ready       (rx_ready),
        .host_rx_data        (rx_data),
        .codec_valid         (codec_valid),
        .codec_ready         (codec_ready),
        .codec_address       (codec_address),
        .codec_word          (codec_word),
        .codec_response_valid(codec_response_valid),
        .codec_response_error(codec_response_error),
        .link_ready          (),
        .debug_status        ()
    );

    ngage_aic23 n501 (
        .clk            (clk),
        .reset          (reset),
        .control_valid  (codec_valid),
        .control_ready  (codec_ready),
        .control_address(codec_address),
        .control_word   (codec_word),
        .response_valid (codec_response_valid),
        .response_error (codec_response_error),
        .reset_seen     ()
    );
endmodule
