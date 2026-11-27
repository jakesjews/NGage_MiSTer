// SPDX-License-Identifier: GPL-2.0-or-later
// Ported from NGage_MiSTer ngage-v5.
// D550 boot-only transaction model. No C55x CPU, audio execution or packet RAM.
// Original D0 startup, 2B/test42 diagnostics, and native error replies for
// unimplemented 17/4B audio controls. The byte stream
// replaces AMA/serial pins; clock/reset admission is the explicit board shim.
module ngage_adsp (
    input  wire        clk,
    input  wire        reset,
    input  wire        enabled,
    input  wire        clock_ready,
    input  wire        flash_valid,
    input  wire [15:0] flash_marker,
    input  wire        host_tx_valid,
    output wire        host_tx_ready,
    input  wire [ 7:0] host_tx_data,
    output wire        host_rx_valid,
    input  wire        host_rx_ready,
    output reg  [ 7:0] host_rx_data,
    output wire        codec_valid,
    input  wire        codec_ready,
    output wire [ 6:0] codec_address,
    output wire [15:0] codec_word,
    input  wire        codec_response_valid,
    input  wire        codec_response_error,
    output wire        link_ready,
    output wire [11:0] debug_status
);
    localparam BOOT=4'd0, LINK=4'd1, READY=4'd2, ACK=4'd3,
        DIAG=4'd4, RESULT=4'd5, REPLY=4'd6, CONFIRM=4'd7;
    reg [3:0] state;
    // Register admission before distributing reset to the peer state. Native
    // CBUS/UART decoding must not become a new long reset-enable cone at104MHz.
    reg       active;
    always @(posedge clk) begin
        if (reset) active <= 0;
        else active <= enabled;
    end
    wire local_reset = reset || !active;
    reg reset_only, ack_only, replay;
    wire bootstrap_valid, bootstrap_done;
    wire [7:0] bootstrap_data;
    ngage_adsp_bootstrap_tx bootstrap (
        .clk           (clk),
        .reset         (local_reset),
        .reset_only    (reset_only),
        .request_valid (state == BOOT),
        .request_ready (),
        .tx_valid      (bootstrap_valid),
        .tx_ready      (host_rx_ready),
        .tx_data       (bootstrap_data),
        .complete_valid(bootstrap_done),
        .complete_ready(1'b1)
    );
    wire diag_ready, diag_valid;
    wire [15:0] diag_result;
    reg [15:0] test_id, result;
    ngage_adsp_diagnostic diagnostic (
        .clk                 (clk),
        .reset               (local_reset),
        .request_valid       (state == DIAG),
        .request_ready       (diag_ready),
        .test_id             (test_id),
        .clock_locked        (clock_ready),
        .flash_valid         (flash_valid),
        .flash_marker        (flash_marker),
        .codec_valid         (codec_valid),
        .codec_ready         (codec_ready),
        .codec_address       (codec_address),
        .codec_word          (codec_word),
        .codec_response_valid(codec_response_valid),
        .codec_response_error(codec_response_error),
        .response_valid      (diag_valid),
        .response_ready      (state == RESULT),
        .response_unsupported(),
        .response_result     (diag_result)
    );

    // Drain serial TX even while powered down/busy. Device response ownership
    // must never recreate the old masked-interrupt UART drain deadlock.
    assign host_tx_ready = 1'b1;
    assign host_rx_valid = enabled && !local_reset && (bootstrap_valid || state==ACK || state==REPLY);
    assign link_ready = !local_reset && state >= READY;

    reg [1:0] rx_state;
    reg [7:0] rx_index, rx_last, rx_length, resource, control, rx_flags;
    reg [15:0] rx_check;
    reg rx_good, same_request, frame_done;
    // Streaming envelope candidates: bit0 diagnostic2B/service7/length12,
    // bit1 gain17/service3/length12, bit2 control4B/service3/length10.
    // Only two owned kind bits are added; no application packet is buffered.
    reg [2:0] reply_shapes;
    localparam DIAGNOSTIC = 2'd0, GAIN = 2'd1, CONTROL = 2'd2, UNKNOWN = 2'd3;
    reg [1:0] request_kind;
    wire [1:0] incoming_kind = host_tx_data == 8'h2b ? DIAGNOSTIC :
        host_tx_data == 8'h17 ? GAIN : host_tx_data == 8'h4b ? CONTROL : UNKNOWN;
    reg [7:0] object_dest, object_source, transaction;
    reg [2:0] request_sequence, rx_sequence, device_sequence;
    reg         previous_request;
    wire [15:0] rx_xor = rx_check ^ (rx_index[0] ? {8'b0, host_tx_data} : {host_tx_data, 8'b0});
    wire [ 7:0] rx_tail = rx_length + 8'd4;
    // Metadata is owned by a complete request until its reply is acknowledged.
    // Busy duplicates are compared while streaming, without a second buffer.
    always @(posedge clk) begin
        if (local_reset) begin
            rx_state      <= 0;
            rx_index      <= 0;
            rx_last       <= 0;
            rx_length     <= 0;
            resource      <= 0;
            control       <= 0;
            rx_flags      <= 0;
            rx_check      <= 0;
            rx_good       <= 0;
            reply_shapes  <= 0;
            request_kind  <= UNKNOWN;
            same_request  <= 0;
            frame_done    <= 0;
            object_dest   <= 0;
            object_source <= 0;
            transaction   <= 0;
            test_id       <= 0;
            rx_sequence   <= 0;
        end else begin
            frame_done <= 0;
            if (host_tx_valid && enabled) begin
                case (rx_state)
                    0:       if (host_tx_data == 8'h55) rx_state <= 1;
                    1: begin
                        if (host_tx_data == 8'h55) begin
                            rx_state     <= 2;
                            rx_index     <= 0;
                            rx_check     <= 0;
                            rx_good      <= 1;
                            reply_shapes <= 0;
                            same_request <= 1;
                        end else rx_state <= 0;
                    end
                    2: begin
                        rx_check <= rx_xor;
                        rx_index <= rx_index + 1'b1;
                        case (rx_index)
                            0: rx_good <= rx_good && host_tx_data == 8'h20;
                            1: rx_good <= rx_good && host_tx_data == 8'h78;
                            2: rx_good <= rx_good && host_tx_data == 0;
                            3: begin
                                resource <= host_tx_data;
                                rx_good<=rx_good && (host_tx_data==8'h82 || host_tx_data==8'hd0 || host_tx_data==8'h7f);
                            end
                            4: rx_good <= rx_good && host_tx_data == 0;
                            5: begin
                                rx_length    <= host_tx_data;
                                rx_last      <= 8'd7 + host_tx_data + {7'b0, host_tx_data[0]};
                                reply_shapes <= {host_tx_data == 10, {2{host_tx_data == 12}}};
                                if (host_tx_data < 2 || host_tx_data > 247) rx_state <= 0;
                            end
                            6: begin
                                control <= host_tx_data;
                                if (resource == 8'h82) begin
                                    same_request <= same_request && host_tx_data == object_dest;
                                    if (state == READY) object_dest <= host_tx_data;
                                end
                            end
                            7:
                            if (resource == 8'h82) begin
                                same_request <= same_request && host_tx_data == object_source;
                                if (state == READY) object_source <= host_tx_data;
                            end
                            8:
                            if (resource == 8'h82) begin
                                same_request <= same_request && host_tx_data == transaction;
                                if (state == READY) transaction <= host_tx_data;
                            end
                            9:
                            if (resource == 8'h82) begin
                                reply_shapes <= reply_shapes & {host_tx_data == 8'h4b,
                                    host_tx_data == 8'h17, host_tx_data == 8'h2b};
                                same_request <= same_request && incoming_kind == request_kind;
                                if (state == READY) request_kind <= incoming_kind;
                            end
                            10:
                            if (resource == 8'h82)
                                reply_shapes <= reply_shapes & {3{host_tx_data == 0}};
                            11:
                            if (resource == 8'h82)
                                reply_shapes <= reply_shapes & {{2{host_tx_data == 3}}, host_tx_data == 7};
                            12:
                            if (resource == 8'h82) begin
                                same_request <= same_request && host_tx_data == test_id[15:8];
                                if (state == READY) test_id[15:8] <= host_tx_data;
                            end
                            13:
                            if (resource == 8'h82) begin
                                same_request <= same_request && host_tx_data == test_id[7:0];
                                if (state == READY) test_id[7:0] <= host_tx_data;
                            end
                            default: ;
                        endcase
                        if (rx_index == rx_tail && resource == 8'h82)
                            rx_good <= rx_good && host_tx_data == 1;
                        if (rx_index == rx_tail + 1'b1) begin
                            rx_flags    <= host_tx_data;
                            rx_sequence <= host_tx_data[2:0];
                        end
                        if (rx_index >= 7 && rx_index == rx_last) begin
                            frame_done <= rx_good && rx_xor == 0;
                            rx_state   <= 0;
                        end
                    end
                    default: rx_state <= 0;
                endcase
            end
        end
    end

    // Passive DDR observations survive clock gating but clear on phone reset.
    // No observer feeds protocol control or backpressures the guest.
    reg diagnostic_seen, diagnostic_complete, diagnostic_ok, diagnostic_acked;
    assign debug_status = {
        diagnostic_acked,
        diagnostic_ok,
        diagnostic_complete,
        diagnostic_seen,
        enabled,
        clock_ready,
        link_ready,
        active,
        state
    };
    always @(posedge clk) begin
        if (reset) begin
            diagnostic_seen     <= 0;
            diagnostic_complete <= 0;
            diagnostic_ok       <= 0;
            diagnostic_acked    <= 0;
        end else if (!local_reset) begin
            if (state == DIAG && diag_ready && test_id == 16'h42) begin
                diagnostic_seen     <= 1;
                diagnostic_complete <= 0;
                diagnostic_ok       <= 0;
                diagnostic_acked    <= 0;
            end
            if (state == RESULT && diag_valid && test_id == 16'h42) begin
                diagnostic_complete <= 1;
                diagnostic_ok       <= diag_result == 0;
            end
            if (frame_done && resource == 8'h7f && control == 8'h82 &&
                rx_length == 2 && rx_sequence == device_sequence &&
                state == CONFIRM && !rx_flags[7] && request_kind == DIAGNOSTIC && test_id == 16'h42)
                diagnostic_acked <= 1;
        end
    end

    // One serializer/checksum for ACK, diagnostic and short error replies.
    // Native D550446C2B/446401 emit77/AB with service0003/status0002 for
    // invalid controls. Audio execution remains unimplemented: report that
    // native error, never pretend a gain/codec operation or DSP memory test
    // succeeded. A transport ACK alone leaves original clients waiting.
    // No wide packet register, variable-index packet array or extra FIFO.
    reg  [ 4:0] tx_index;
    reg  [15:0] tx_check;
    reg  [ 7:0] byte_data;
    wire        short_reply = request_kind != DIAGNOSTIC;
    wire [ 4:0] checksum_index = state == ACK ? 5'd10 : short_reply ? 5'd18 : 5'd20;
    always @* begin
        byte_data = 0;
        case (tx_index)
            0, 1: byte_data = 8'h55;
            2: byte_data = 8'h20;
            4: byte_data = 8'h78;
            5: byte_data = state == ACK ? 8'h7f : 8'h82;
            7: byte_data = state == ACK ? 8'h02 : short_reply ? 8'h0a : 8'h0c;
            8: byte_data = state == ACK ? 8'h82 : object_source;
            9: byte_data = state == ACK ? {5'b0, request_sequence} : object_dest;
            10: byte_data = transaction;
            11: byte_data = request_kind == GAIN ? 8'h77 : request_kind == CONTROL ? 8'hab : 8'h8b;
            13: byte_data = short_reply ? 8'h03 : 8'h07;
            14: byte_data = short_reply ? 8'h00 : test_id[15:8];
            15: byte_data = short_reply ? 8'h02 : test_id[7:0];
            16: byte_data = short_reply ? 8'h01 : result[15:8];
            17: byte_data = short_reply ? {5'b01100, device_sequence} : result[7:0];
            18: byte_data = 8'h01;
            19: byte_data = {5'b01100, device_sequence};
            default: ;
        endcase
        if (tx_index == checksum_index) byte_data = tx_check[15:8];
        if (tx_index == checksum_index + 1'b1) byte_data = tx_check[7:0];
        host_rx_data = bootstrap_valid ? bootstrap_data : byte_data;
    end
    always @(posedge clk) begin
        if (local_reset) begin
            state            <= BOOT;
            reset_only       <= 0;
            tx_index         <= 0;
            tx_check         <= 0;
            result           <= 0;
            request_sequence <= 0;
            device_sequence  <= 0;
            previous_request <= 0;
            ack_only         <= 0;
            replay           <= 0;
        end else begin
            case (state)
                BOOT:    if (bootstrap_done) state <= LINK;
                DIAG:    if (diag_ready) state <= RESULT;
                RESULT:
                if (diag_valid) begin
                    result   <= diag_result;
                    state    <= REPLY;
                    tx_index <= 0;
                    tx_check <= 0;
                end
                ACK, REPLY:
                if (host_rx_ready) begin
                    if (tx_index >= 2 && tx_index < checksum_index)
                        tx_check<=tx_check ^ (tx_index[0] ? {8'b0,byte_data} : {byte_data,8'b0});
                    if (tx_index == checksum_index + 1'b1) begin
                        tx_index <= 0;
                        tx_check <= 0;
                        if (state == REPLY) state <= CONFIRM;
                        else if (ack_only) state <= READY;
                        else if (replay) state <= REPLY;
                        else state <= short_reply ? REPLY : DIAG;
                    end else tx_index <= tx_index + 1'b1;
                end
                default: ;
            endcase
            if (frame_done) begin
                if (resource == 8'hd0 && control == 1 && state != BOOT) begin
                    state            <= BOOT;
                    reset_only       <= 1;
                    previous_request <= 0;
                    device_sequence  <= 0;
                end else if (resource==8'hd0 && control==5 && rx_length==3 &&
                    rx_flags==8'h40 && state==LINK) begin
                    state <= READY;
                end else if (resource==8'h7f && control==8'h82 && rx_length==2 &&
                    rx_sequence==device_sequence && state==CONFIRM) begin
                    if (rx_flags[7]) begin
                        state    <= REPLY;
                        tx_index <= 0;
                        tx_check <= 0;
                    end else begin
                        state           <= READY;
                        device_sequence <= device_sequence + 1'b1;
                    end
                end else if (resource==8'h82 && rx_flags[7:6]==2'b01 &&
                    (state==READY || state==CONFIRM)) begin
                    if (state==READY && (!previous_request || rx_sequence!=request_sequence)) begin
                        state            <= ACK;
                        tx_index         <= 0;
                        tx_check         <= 0;
                        request_sequence <= rx_sequence;
                        previous_request <= 1;
                        ack_only         <= !(|reply_shapes);
                        replay           <= 0;
                    end else if (previous_request && rx_sequence==request_sequence && same_request && (state==READY || (|reply_shapes))) begin
                        state    <= ACK;
                        tx_index <= 0;
                        tx_check <= 0;
                        ack_only <= state == READY;
                        replay   <= state == CONFIRM;
                    end
                end
            end
        end
    end
endmodule

// D551 boot-profile signature, recovered from the audited E403A400H450 image
// at file160000. Only diagnostic42's read is modeled; no flash array/CPU/loader
// or physical address mapping is implied. Constants cost no RAM.
module ngage_adsp_flash_signature (
    output wire        valid,
    output wire [15:0] marker
);
    assign valid  = 1'b1;
    assign marker = 16'hfffc;
endmodule
