// SPDX-License-Identifier: GPL-2.0-or-later
// The UPP's internal DSP device 7C owns the game PCM resource E8.
// The original MDI driver supplies big-endian Phonet frames. The playback
// engine reads samples from the two handset SDRAM halves named by the client.
// A buffer's sample count is taken as the client gives it, also when it is
// more than the half size of the start message: SoundDevice's first buffer
// of a stream can be (Tony Hawk: 8192 samples of silence with halves of
// 5600), and without its reply the stream never starts. Such a buffer is
// played from the half's address on, past the half's end, as the stand-in
// of the earlier releases played it. What the phone's DSP does with one is
// not known.
module upp_dsp_pcm (
    input  wire        clk,
    input  wire        reset,
    input  wire        rx_valid,
    output wire        rx_ready,
    input  wire [ 7:0] rx_data,
    input  wire        rx_last,
    input  wire        idle_slot,
    output wire        tx_valid,
    input  wire        tx_ready,
    output reg  [ 7:0] tx_data,
    output wire        tx_last,
    input  wire [19:0] pcm_status,
    output reg         pcm_write,
    output reg  [ 7:0] pcm_offset,
    output reg  [31:0] pcm_data
);
    localparam RX = 4'd0, CHECK = 4'd1, FORMAT = 4'd2, RATE = 4'd3, ADDRESS0 = 4'd4,
               ADDRESS1 = 4'd5, START = 4'd6, STOP = 4'd7, REPLY = 4'd8, SUBMIT = 4'd9;

    reg [3:0] state;
    reg [4:0] received;
    reg [7:0] header   [0:23];
    reg opened, first_buffer, requested, requested_half, final_valid, final_half;
    reg [1:0] free_halves;
    reg [15:0] final_frames;
    reg [7:0] media, device, object_id, dsp_device, dsp_object;
    reg [7:0] reply_transaction, reply_opcode;
    reg [15:0] reply_value;
    reg [ 3:0] transmitted;

    wire [ 1:0] done = pcm_status[19:18];
    wire [ 1:0] full = pcm_status[17:16];
    wire        playing = pcm_status[15];
    wire [14:0] position = pcm_status[14:0];

    wire [7:0] opcode = header[9];
    wire [15:0] frames = {header[12], header[13]};
    wire [16:0] buffer_bytes = {frames, 1'b0};
    wire [31:0] address0 = {header[14], header[15], header[16], header[17]};
    wire [31:0] address1 = {header[18], header[19], header[20], header[21]};
    // Reject out-of-range high bits before calculating within the mapped pages.
    wire [16:0] low0 = address0[16:0];
    wire [16:0] low1 = address1[16:0];
    wire [17:0] end0 = {1'b0, low0} + {1'b0, buffer_bytes};
    wire [17:0] end1 = {1'b0, low1} + {1'b0, buffer_bytes};
    wire start_valid = received == 24 && header[10] == 8'h82 && header[11] == 2 &&
                       header[22] == 0 && (header[23] == 8'h32 || header[23] == 8'h46) &&
                       address0[31:17] == 15'h0503 && address1[31:17] == 15'h0503 &&
                       low0 >= 17'h01000 && low1 >= 17'h01000 && !low0[0] && !low1[0] &&
                       frames != 0 && end0 <= 18'h10000 && end1 <= 18'h10000 &&
                       (end0 <= {1'b0, low1} || end1 <= {1'b0, low0});
    wire owner = opened && device == header[2] && object_id == header[7] &&
                           dsp_device == header[1] && dsp_object == header[6];
    wire half = opcode == 8'h23 ? header[10][0] : requested_half;
    wire [1:0] half_mask = half ? 2'b10 : 2'b01;
    wire submit_valid = received == 14 && owner && !final_valid &&
                        ((opcode == 8'h23 && header[10] < 2) ||
                         (opcode == 8'h27 && requested)) &&
                        !full[half] && (header[11] == 1 || header[11] == 2);
    wire final_done = final_valid && (done[final_half] || (final_frames == 0 && full == 0));
    wire request_due = free_halves != 0 && !requested && !final_valid;
    wire idle = state == RX && received == 0 && idle_slot && opened;

    assign rx_ready = state == RX;
    assign tx_valid = state == REPLY;
    assign tx_last  = tx_valid && transmitted == 13;
    always @* begin
        case (transmitted)
            0:       tx_data = media;
            1:       tx_data = device;
            2:       tx_data = dsp_device;
            3:       tx_data = 8'he8;
            5:       tx_data = 8'd8;
            6:       tx_data = object_id;
            7:       tx_data = dsp_object;
            8:       tx_data = reply_transaction;
            9:       tx_data = reply_opcode;
            10:      tx_data = reply_value[15:8];
            11:      tx_data = reply_value[7:0];
            default: tx_data = 0;
        endcase
    end

    always @* begin
        pcm_write  = 0;
        pcm_offset = 0;
        pcm_data   = 0;
        if (!reset) begin
            case (state)
                CHECK: begin
                    if (opcode == 8'h20 && start_valid) begin
                        pcm_write  = 1;
                        pcm_offset = 8'h04;
                    end else if (submit_valid) begin
                        // An explicit half submission can arrive before we have
                        // consumed its prior DONE. Clear that old completion
                        // before publishing the new length for this half.
                        pcm_write  = 1;
                        pcm_offset = 8'h20;
                        pcm_data   = {30'd0, half_mask};
                    end
                end
                SUBMIT: begin
                    pcm_write  = 1;
                    pcm_offset = half ? 8'h1c : 8'h18;
                    pcm_data   = {16'd0, frames};
                end
                FORMAT: begin
                    pcm_write  = 1;
                    pcm_offset = 8'h08;
                end
                RATE: begin
                    pcm_write  = 1;
                    pcm_offset = 8'h0c;
                    pcm_data   = header[23] == 8'h32 ? 32'd8000 : 32'd16000;
                end
                ADDRESS0: begin
                    pcm_write  = 1;
                    pcm_offset = 8'h10;
                    pcm_data   = address0;
                end
                ADDRESS1: begin
                    pcm_write  = 1;
                    pcm_offset = 8'h14;
                    pcm_data   = address1;
                end
                START, STOP: begin
                    pcm_write  = 1;
                    pcm_offset = 8'h04;
                    // Completion goes back to NOS through MDI, leaving IRQ 5 to the timer.
                    pcm_data   = state == START ? 32'd1 : 32'd0;
                end
                RX: begin
                    if (idle && done != 0 && !final_done) begin
                        pcm_write  = 1;
                        pcm_offset = 8'h20;
                        pcm_data   = {30'd0, done};
                    end
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state             <= RX;
            received          <= 0;
            opened            <= 0;
            first_buffer      <= 1;
            requested         <= 0;
            requested_half    <= 0;
            final_valid       <= 0;
            final_half        <= 0;
            free_halves       <= 0;
            final_frames      <= 0;
            media             <= 0;
            device            <= 0;
            object_id         <= 0;
            dsp_device        <= 0;
            dsp_object        <= 0;
            reply_transaction <= 0;
            reply_opcode      <= 0;
            reply_value       <= 0;
            transmitted       <= 0;
        end else begin
            case (state)
                RX: begin
                    if (rx_valid) begin
                        if (received < 24) header[received] <= rx_data;
                        if (rx_last) begin
                            if (received >= 9 && received < 24 && header[3] == 8'he8 &&
                                header[1][7:2] == 6'h1f) begin
                                received <= received + 1'b1;
                                state    <= CHECK;
                            end else received <= 0;
                        end else if (received < 24) received <= received + 1'b1;
                    end else if (idle && final_done) begin
                        reply_transaction <= 0;
                        reply_opcode      <= 8'h2b;
                        reply_value       <= {final_frames[14:0], 1'b0};
                        state             <= STOP;
                    end else if (idle && done != 0) begin
                        free_halves <= free_halves | (done & ~full);
                    end else if (idle && request_due) begin
                        requested         <= 1;
                        requested_half    <= !free_halves[0];
                        free_halves       <= free_halves & (free_halves[0] ? 2'b10 : 2'b01);
                        reply_transaction <= 0;
                        reply_opcode      <= 8'h26;
                        reply_value       <= {15'd0, !free_halves[0]};
                        state             <= REPLY;
                    end
                end
                CHECK: begin
                    received          <= 0;
                    reply_transaction <= header[8];
                    reply_value       <= 0;
                    if ((opcode == 8'h20 && start_valid) ||
                        (opcode == 8'h2a && received == 10 && !opened)) begin
                        media      <= header[0];
                        device     <= header[2];
                        object_id  <= header[7];
                        dsp_device <= header[1];
                        dsp_object <= header[6];
                    end
                    if (opcode == 8'h20 && start_valid) begin
                        opened       <= 1;
                        first_buffer <= 1;
                        requested    <= 0;
                        final_valid  <= 0;
                        free_halves  <= 0;
                        reply_opcode <= 8'h21;
                        state        <= FORMAT;
                    end else if (opcode == 8'h2a && received == 10 && (owner || !opened)) begin
                        reply_opcode <= 8'h2b;
                        reply_value  <= owner && playing ? {position, 1'b0} : 16'd0;
                        state        <= STOP;
                    end else if (submit_valid) begin
                        if (requested && half == requested_half) requested <= 0;
                        if (header[11] == 1) begin
                            final_valid  <= 1;
                            final_half   <= half;
                            final_frames <= frames;
                        end
                        first_buffer <= 0;
                        free_halves <= (free_halves | (first_buffer ? {half_mask[0], half_mask[1]} : 2'b00)) & ~half_mask;
                        reply_opcode <= opcode + 1'b1;
                        state <= SUBMIT;
                    end else state <= RX;
                end
                FORMAT:   state <= RATE;
                RATE:     state <= ADDRESS0;
                ADDRESS0: state <= ADDRESS1;
                ADDRESS1: state <= REPLY;
                SUBMIT:   state <= playing || frames == 0 ? REPLY : START;
                START:    state <= REPLY;
                STOP: begin
                    opened <= 0;
                    state  <= REPLY;
                end
                REPLY: begin
                    if (tx_ready) begin
                        transmitted <= tx_last ? 4'd0 : transmitted + 1'b1;
                        if (tx_last) state <= RX;
                    end
                end
                default:  state <= RX;
            endcase
        end
    end
endmodule
