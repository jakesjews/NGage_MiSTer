// SPDX-License-Identifier: GPL-2.0-or-later
// NEM-4 packed LCD transactions, following ngage-v5's native row-band decoder.
// Convert each RGB444 pair into two writes to the shared RGB565 framebuffer.
module ngage_nem4_lcd (
    input  wire        clk,
    input  wire        reset,
    input  wire        word_valid,
    input  wire        word_header,
    input  wire [31:0] word_data,
    output wire        word_ready,
    output wire        word_idle,
    output wire        pixel_valid,
    output wire [15:0] pixel_addr,
    output wire [15:0] pixel_rgb,
    output reg         display_on
);
    localparam [14:0] FRAME_PAIRS = 15'd18304;
    reg [31:0] header, first_window_word;
    reg [7:0] last_command;
    reg [1:0] window_words;
    reg row_valid, column_valid;
    reg [14:0] band_start, band_end;
    reg [16:0] band_bytes;
    reg [14:0] cursor, pixel_limit;
    reg pixel_header, memory_write;
    reg second_pending;
    reg [14:0] second_pair;
    reg [11:0] second_rgb;
    reg staged_valid, staged_header;
    reg [31:0] staged_data;

    wire full_window = row_valid && column_valid && band_start == 0 &&
        (band_end == FRAME_PAIRS || band_end == 15'd18216);
    wire legacy_header = full_window && staged_data == 32'h8924d67f;
    wire valid_header = staged_data[31:16] == 16'h8924 &&
        (legacy_header || (row_valid && column_valid && {1'b0, staged_data[15:0]} + 17'd1 == band_bytes));
    wire [7:0] first_row = first_window_word[7:0];
    wire [7:0] end_row = first_window_word[27:20];
    wire [14:0] first_pair = {7'd0, first_row} * 15'd88;
    wire [14:0] end_pair = {7'd0, end_row} * 15'd88;
    wire decode_word = staged_valid && !second_pending;
    wire first_pixel = decode_word && !staged_header && pixel_header && memory_write && cursor < pixel_limit;
    wire [11:0] rgb444 = second_pending ? second_rgb : staged_data[11:0];

    // Accept into an empty slot or replace the word consumed on this edge.
    // Keep the mux and the header decoder on opposite sides of the register.
    assign word_ready = !staged_valid || !second_pending;
    assign word_idle  = !staged_valid && !second_pending;
    assign pixel_valid = !reset && (first_pixel || second_pending);
    assign pixel_addr = second_pending ? {second_pair, 1'b1} : {cursor, 1'b0};
    assign pixel_rgb = {rgb444[11:8], rgb444[11], rgb444[7:4], rgb444[7:6], rgb444[3:0], rgb444[3]};

    always @(posedge clk) begin
        if (reset) staged_valid <= 1'b0;
        else if (word_ready) staged_valid <= word_valid;
        if (word_ready && word_valid) begin
            staged_header <= word_header;
            staged_data   <= word_data;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            header            <= 0;
            first_window_word <= 0;
            last_command      <= 0;
            window_words      <= 0;
            row_valid         <= 1;
            column_valid      <= 1;
            band_start        <= 0;
            band_end          <= FRAME_PAIRS;
            band_bytes        <= 17'd54912;
            cursor            <= 0;
            pixel_limit       <= FRAME_PAIRS;
            pixel_header      <= 0;
            memory_write      <= 0;
            display_on        <= 0;
            second_pending    <= 0;
            second_pair       <= 0;
            second_rgb        <= 0;
        end else begin
            second_pending <= first_pixel;
            if (decode_word && staged_header) begin
                header       <= staged_data;
                pixel_header <= valid_header;
                pixel_limit  <= legacy_header ? FRAME_PAIRS : band_end;
                window_words <= 0;
                if (staged_data == 32'h09240003 && last_command == 8'h75) begin
                    window_words <= 2;
                    row_valid    <= 0;
                end else if (staged_data == 32'h09240003 && last_command == 8'h15) begin
                    window_words <= 2;
                    column_valid <= 0;
                end
            end else if (decode_word) begin
                if (header == 32'h09200000) begin
                    last_command <= staged_data[7:0];
                    memory_write <= 0;
                    case (staged_data)
                        32'h15: column_valid <= 0;
                        32'h75: row_valid <= 0;
                        32'haf: display_on <= 1;
                        32'h5c: if (row_valid && column_valid) begin
                            memory_write <= 1;
                            cursor       <= band_start;
                        end
                        default: ;
                    endcase
                end else if (header == 32'h09240003 && window_words != 0) begin
                    window_words <= window_words - 1'b1;
                    if (window_words == 2) first_window_word <= staged_data;
                    else if (last_command == 8'h75) begin
                        row_valid  <= staged_data == 0 && (first_window_word & 32'hf00fff00) == 0 &&
                                      first_row < end_row && end_row <= 208;
                        band_start <= first_pair;
                        band_end   <= end_pair;
                        band_bytes <= {2'b0, end_pair - first_pair} * 17'd3;
                    end else begin
                        column_valid <= staged_data == 0 && first_window_word == 32'h0b100002;
                    end
                end else if (first_pixel) begin
                    second_pair <= cursor;
                    second_rgb  <= staged_data[27:16];
                    if (cursor == pixel_limit - 1'b1) memory_write <= 0;
                    else cursor <= cursor + 1'b1;
                end
            end
        end
    end
endmodule
