// SPDX-License-Identifier: GPL-2.0-or-later
// NEM-4 packed LCD DMA. Like v5's LCD stream, reserve one aligned packet
// at a time, retain returned words under panel backpressure, and drain
// an owned request on cancel. The memory peer here is the UPP Wishbone
// arbiter, which returns 32-bit beats and rotates at packet boundaries.
module upp_lcd_dma #(
    parameter integer PACKET_WORDS = 4
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [23:2] source,
    input  wire [21:0] count_minus_one,
    input  wire        stop,
    output wire        busy,
    output wire        done,

    output wire        read_req,
    input  wire        read_owned,
    output wire [31:0] read_addr,
    output wire        read_more,
    input  wire        read_ack,
    input  wire        read_err,
    input  wire [31:0] read_data,

    output wire        pixel_valid,
    output wire [31:0] pixel_data,
    input  wire        pixel_ready,
    input  wire        panel_idle
);
    localparam [2:0] IDLE = 0, RESERVE = 1, FETCH = 2, SEND = 3, FENCE = 4;
    reg [2:0] state;
    reg [23:2] addr;
    reg [22:0] words_left;
    reg [1:0] last_word, index;
    reg stopped;
    reg [31:0] packet [0:PACKET_WORDS-1];

    assign busy        = state != IDLE;
    assign done        = state == FENCE && panel_idle && !stop;
    assign read_req    = state == FETCH && !stop;
    assign read_addr   = {8'h0a, addr, 2'b00};
    assign read_more   = index != last_word;
    assign pixel_valid = state == SEND && !stop;
    assign pixel_data  = packet[PACKET_WORDS == 1 ? 0 : index];

    always @(posedge clk) begin
        if (reset) begin
            state   <= IDLE;
            stopped <= 1'b0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    addr       <= source;
                    words_left <= {1'b0, count_minus_one} + 23'd1;
                    stopped    <= 1'b0;
                    state      <= RESERVE;
                end
                RESERVE: begin
                    last_word <= PACKET_WORDS == 4 && addr[3:2] == 0 && words_left >= 4 ? 2'd3 : 2'd0;
                    index     <= 0;
                    state     <= stop ? IDLE : FETCH;
                end
                FETCH: begin
                    if (stop) stopped <= 1'b1;
                    if ((stop && !read_owned) || read_err) begin
                        state <= IDLE;
                    end else if (read_ack) begin
                        packet[PACKET_WORDS == 1 ? 0 : index] <= read_data;
                        addr       <= addr + 1'b1;
                        words_left <= words_left - 1'b1;
                        index      <= index + 1'b1;
                        if (!read_more) begin
                            index <= 0;
                            state <= stop || stopped ? IDLE : SEND;
                        end
                    end
                end
                SEND: begin
                    if (stop) begin
                        state <= IDLE;
                    end else if (pixel_ready) begin
                        index <= index + 1'b1;
                        if (index == last_word) state <= words_left == 0 ? FENCE : RESERVE;
                    end
                end
                FENCE: if (panel_idle || stop) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (!reset && (read_ack || read_err) && (state != FETCH || !read_owned))
            $fatal(1, "LCD DMA received an unowned reply");
    end
    // synthesis translate_on
endmodule
