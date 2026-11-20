// SPDX-License-Identifier: GPL-2.0-or-later
//
// UPP internal DSP MDI startup transport, ported from the N-Gage NEM-4 core.
// Firmware and the startup peer share two 250-halfword rings in SDRAM.
// The peer publishes producer pointers only after the payload writes complete.
// DSP instructions, external D550 audio and electrical timing are unmodeled.
module upp_mdi (
    input  wire        clk,
    input  wire        reset,
    input  wire        tick,
    input  wire        wr,
    input  wire [ 1:0] reg_sel,       // 0: control, 1: M2D pointers, 2: D2M pointers
    input  wire [31:0] din,
    input  wire [ 3:0] sel,
    output reg  [31:0] dout,
    output reg  [ 1:0] irq_events,   // CTSI status bits 10:9

    output wire        mem_req,
    output wire        mem_we,
    output wire [ 7:0] mem_word,
    output wire [31:0] mem_wdata,
    output wire [ 3:0] mem_be,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ack,
    input  wire        mem_err
);
    localparam IDLE=0, READ_WORD=1, RX_HIGH=2, RX_LOW=3,
               TX_HIGH=4, TX_LOW=5, TX_WRITE=6, ANN_WRITE=7;
    localparam [4:0] LAST_ANNOUNCE_TICK = 5'd19;
    reg [3:0] state;
    reg [31:0] control, pointers, receive_ptr;
    reg pointers_seen, receive_seen, announced, announce_due;
    reg [4:0] elapsed;
    reg [15:0] incoming_word, outgoing_word;
    reg [15:0] word_index;
    reg [16:0] byte_index, frame_bytes;
    reg [7:0] write_index;
    reg [7:0] high_byte;
    reg reply_end;
    reg [1:0] announce_index;
    wire [31:0] mask = {{8{sel[3]}}, {8{sel[2]}}, {8{sel[1]}}, {8{sel[0]}}};
    wire running = control[15:0] == 16'h0500;
    wire [7:0] producer = pointers[7:0];
    wire [7:0] consumer = pointers[23:16];
    wire [7:0] output_producer = receive_ptr[7:0];
    wire [7:0] output_consumer = receive_ptr[23:16];
    wire [8:0] output_used = output_producer >= output_consumer ?
        {1'b0,output_producer}-{1'b0,output_consumer} :
        {1'b0,output_producer}+9'd250-{1'b0,output_consumer};
    wire [8:0] output_free = 9'd249 - output_used;
    wire pointer_valid = pointers[15:0] < 250 && pointers[31:16] < 250 &&
                         receive_ptr[15:0] < 250 && receive_ptr[31:16] < 250;
    function [7:0] next_index;
        input [7:0] index;
        begin
            next_index = index == 249 ? 0 : index + 1'b1;
        end
    endfunction
    wire       peer_rx_valid = state == RX_HIGH || state == RX_LOW;
    wire       peer_rx_last = word_index >= 2 && byte_index + 17'd1 == frame_bytes;
    wire [7:0] peer_rx_data = state == RX_HIGH ? incoming_word[15:8] : incoming_word[7:0];
    wire       peer_rx_ready, tx_valid, tx_last;
    wire [7:0] tx_data;
    wire       peer_tx_ready = state == TX_HIGH || state == TX_LOW;
    upp_mdi_peer peer (
        .clk        (clk),
        .reset      (reset || !running),
        .rx_valid   (peer_rx_valid),
        .rx_ready   (peer_rx_ready),
        .rx_data    (peer_rx_data),
        .rx_last    (peer_rx_last),
        .tx_valid   (tx_valid),
        .tx_ready   (peer_tx_ready),
        .tx_data    (tx_data),
        .tx_last    (tx_last),
        .unsupported()
    );

    wire [7:0] output_word = 8'd125 + {1'b0, write_index[7:1]};
    reg [15:0] engine_half_data;
    always @* begin
        engine_half_data = outgoing_word;
        if (state == ANN_WRITE) begin
            case (announce_index)
                0: engine_half_data = 16'h0000;
                1: engine_half_data = 16'h7cd0;
                2: engine_half_data = 16'h0001;
                3: engine_half_data = 16'h0400;
            endcase
        end
    end
    assign mem_we = state == TX_WRITE || state == ANN_WRITE;
    assign mem_req = running && pointer_valid && (mem_we || state == READ_WORD);
    assign mem_word = mem_we ? output_word : {1'b0, consumer[7:1]};
    assign mem_be = mem_we ? (write_index[0] ? 4'hc : 4'h3) : 4'hf;
    assign mem_wdata = {engine_half_data, engine_half_data};
    wire [15:0] read_half = consumer[0] ? mem_rdata[31:16] : mem_rdata[15:0];

    always @* begin
        case (reg_sel)
            2'd0: dout = control;
            2'd1: dout = pointers;
            2'd2: dout = receive_ptr;
            default: dout = 0;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            control        <= 0;
            pointers       <= 0;
            receive_ptr    <= 0;
            pointers_seen  <= 0;
            receive_seen   <= 0;
            state          <= IDLE;
            announced      <= 0;
            announce_due   <= 0;
            elapsed        <= 0;
            incoming_word  <= 0;
            outgoing_word  <= 0;
            word_index     <= 0;
            byte_index     <= 0;
            frame_bytes    <= 0;
            write_index    <= 0;
            high_byte      <= 0;
            reply_end      <= 0;
            announce_index <= 0;
            irq_events     <= 0;
        end else begin
            irq_events   <= 0;
            if (wr) begin
                case (reg_sel)
                    2'd0: control <= (control & ~mask) | (din & mask);
                    2'd1: begin
                        pointers_seen <= 1;
                        pointers <= (pointers & ~mask) | (din & mask);
                    end
                    2'd2: begin
                        receive_seen <= 1;
                        receive_ptr <= (receive_ptr & ~mask) | (din & mask);
                    end
                    default: ;
                endcase
            end
            if (!running || mem_err) begin
                state        <= IDLE;
                word_index   <= 0;
                byte_index   <= 0;
                frame_bytes  <= 0;
                announced    <= 0;
                announce_due <= 0;
                elapsed      <= 0;
            end else begin
                if (tick && pointers_seen && receive_seen && !announce_due && !announced) begin
                    if (elapsed == LAST_ANNOUNCE_TICK) announce_due <= 1;
                    else elapsed <= elapsed + 1'b1;
                end
                if (pointer_valid)
                    case (state)
                        IDLE: begin
                            if (announce_due && !announced && output_free >= 4) begin
                                write_index    <= output_producer;
                                announce_index <= 0;
                                state          <= ANN_WRITE;
                            end else if (tx_valid && output_free >= 8) begin
                                write_index <= output_producer;
                                state       <= TX_HIGH;
                            end else if (peer_rx_ready && !tx_valid && producer != consumer)
                                state <= READ_WORD;
                        end
                        READ_WORD: if (mem_ack) begin
                            incoming_word <= read_half;
                            if (word_index == 2)
                                frame_bytes <= {1'b0, read_half} + 17'd6;
                            state <= RX_HIGH;
                        end
                        RX_HIGH, RX_LOW:
                        if (peer_rx_valid && peer_rx_ready) begin
                            byte_index <= byte_index + 1'b1;
                            if (peer_rx_last || state == RX_LOW) begin
                                pointers[31:16] <= {8'b0, next_index(consumer)};
                                irq_events[0]   <= 1;
                                if (peer_rx_last) begin
                                    word_index  <= 0;
                                    byte_index  <= 0;
                                    frame_bytes <= 0;
                                end else word_index <= word_index + 1'b1;
                                state <= IDLE;
                            end else state <= RX_LOW;
                        end
                        TX_HIGH:
                        if (tx_valid) begin
                            high_byte <= tx_data;
                            state     <= TX_LOW;
                        end
                        TX_LOW:
                        if (tx_valid) begin
                            outgoing_word <= {high_byte, tx_data};
                            reply_end     <= tx_last;
                            state         <= TX_WRITE;
                        end
                        TX_WRITE: if (mem_ack) begin
                            write_index <= next_index(write_index);
                            if (reply_end) begin
                                receive_ptr[15:0] <= {8'b0, next_index(write_index)};
                                irq_events[1]    <= 1;
                                state             <= IDLE;
                            end else state <= TX_HIGH;
                        end
                        ANN_WRITE: if (mem_ack) begin
                            write_index    <= next_index(write_index);
                            announce_index <= announce_index + 1'b1;
                            if (announce_index == 3) begin
                                receive_ptr[15:0] <= {8'b0, next_index(write_index)};
                                irq_events[1]    <= 1;
                                announced         <= 1;
                                state             <= IDLE;
                            end
                        end
                        default:   state <= IDLE;
                    endcase
            end
        end
    end
endmodule
