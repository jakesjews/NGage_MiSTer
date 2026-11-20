// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from NGage_MiSTer ngage-v5 at f2d9c04.
// Synthetic GSM T=0 test card matching scratch/simif-investigation/test_card.h.
// Fabricated test identities; this is not a physical card dump or a full SIM.
// Byte interface is a transaction-level bridge, not electrical SIM timing.
module upp_test_sim #(
    parameter integer CLOCK_DIV = 1
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    input  wire       rx_pop,
    output wire       rx_valid,
    output wire [7:0] rx_data,
    output reg        overflow,
    output wire [6:0] available,
    output wire       tx_will_emit,
    output wire       busy
);
    // At 104 MHz, CLOCK_DIV=32 provides a 3.25 MHz service enable. This
    // schedules transaction-level card work; it is not a SIM serial/baud model.
    localparam integer DIV_AW = CLOCK_DIV > 1 ? $clog2(CLOCK_DIV) : 1;
    reg  [DIV_AW-1:0] divider;
    wire              cen = CLOCK_DIV == 1 || {{(32-DIV_AW){1'b0}}, divider} == CLOCK_DIV - 1;
    reg pending_tx, pending_pop;
    reg [7:0] pending_data;
    reg enabled_tx, enabled_pop;
    reg  [7:0] enabled_data;
    wire       work_tx = CLOCK_DIV == 1 ? tx_valid : enabled_tx;
    wire       work_pop = CLOCK_DIV == 1 ? rx_pop : enabled_pop;
    wire [7:0] work_data = CLOCK_DIV == 1 ? tx_data : enabled_data;
    localparam EMIT_IDLE = 2'd0, EMIT_WRITE = 2'd1, EMIT_PUBLISH = 2'd2;
    reg  [1:0] emit_state;
    wire       emitting = emit_state != EMIT_IDLE;
    assign busy = emitting || (CLOCK_DIV != 1 && (pending_tx || pending_pop || enabled_tx || enabled_pop));
    always @(posedge clk) begin
        if (reset) begin
            divider      <= 0;
            pending_tx   <= 0;
            pending_pop  <= 0;
            pending_data <= 0;
            enabled_tx   <= 0;
            enabled_pop  <= 0;
            enabled_data <= 0;
        end else begin
            if (cen) divider <= 0;
            else divider <= divider + 1'b1;
            if (cen) begin
                // Service inputs cross a CEN register before FIFO processing,
                // giving them a complete enable interval even when an event
                // arrives one system clock before the service edge.
                enabled_tx   <= pending_tx;
                enabled_pop  <= pending_pop;
                enabled_data <= pending_data;
                pending_tx   <= 0;
                pending_pop  <= 0;
            end
            if (CLOCK_DIV != 1 && !busy && (tx_valid || rx_pop)) begin
                pending_tx   <= tx_valid;
                pending_pop  <= rx_pop;
                pending_data <= tx_data;
            end
        end
    end
    reg [7:0] header[0:3];
    reg [5:0] head, tail;
    reg [6:0] used;
    reg [15:0] selected, directory;
    reg [7:0] file_id_high;
    reg [2:0] header_count;
    reg [1:0] select_left;
    reg [7:0] terminal_left;
    integer        i;
    localparam RESPONSE_PAIR=3'd0, RESPONSE_PROC=3'd1, RESPONSE_EF_HEADER=3'd2,
        RESPONSE_DF_HEADER=3'd3, RESPONSE_EF_DATA=3'd4;
    reg [ 2:0] response_kind;
    reg [15:0] response_pair;
    reg [4:0] response_length, accepted_length, emit_index;
    wire [7:0] fifo_data;
    wire       pop_now = cen && !emitting && work_pop && used != 0;
    wire [6:0] next_used = used - {6'd0, pop_now};
    wire [6:0] free_slots = 7'd64 - next_used;
    wire [15:0] next_file = {file_id_high, work_data};
    // One physical write per system clock. Earlier parallel emit() calls were
    // inferred as one8-bit write port by Quartus; RTL simulation allowed more
    // writes than that port can perform. Publish after all writes and a read-
    // settle edge. The64-byte queue remains one M10K, without a packet buffer.
    sdp_ram #(.AW(6), .DW(8)) fifo (
        .clk(clk),
        .we(!reset && emit_state == EMIT_WRITE),
        .waddr(tail + {1'b0, emit_index}),
        .wdata(response_byte(
            emit_index, response_kind, selected, directory, response_length, response_pair
        )),
        .raddr(pop_now ? head + 6'd1 : head),
        .rdata(fifo_data)
    );
    assign tx_will_emit=tx_valid && ((terminal_left==1) ||
        (terminal_left==0 && select_left==1) ||
        (terminal_left==0 && select_left==0 && header_count==4));
    assign rx_valid = used != 0;
    assign rx_data = used != 0 ? fifo_data : 8'b0;
    assign available = used;
    task queue_response;
        input [2:0] kind;
        input [4:0] count;
        input [15:0] pair;
        begin
            response_kind   <= kind;
            response_pair   <= pair;
            response_length <= count;
            accepted_length <= {2'd0, count} < free_slots ? count : free_slots[4:0];
            emit_index      <= 0;
            emit_state      <= free_slots != 0 ? EMIT_WRITE : EMIT_PUBLISH;
            if ({2'd0, count} > free_slots) overflow <= 1;
        end
    endtask
    function supported_ef;
        input [15:0] f;
        begin
            case (f)
                16'h6fb7,16'h6f05,16'h6fae,16'h6f38,16'h6f7e,16'h6fad,16'h6f07,16'h6f78,16'h2fe2,
                16'h6f74,16'h6f20,16'h6f7b:
                supported_ef = 1;
                default: supported_ef = 0;
            endcase
        end
    endfunction
    function [4:0] ef_length;
        input [15:0] f;
        begin
            case (f)
                16'h6fb7:           ef_length = 3;
                16'h6f38, 16'h6f74: ef_length = 16;
                16'h6f7e:           ef_length = 11;
                16'h6fad:           ef_length = 4;
                16'h6f07, 16'h6f20: ef_length = 9;
                16'h6f7b:           ef_length = 12;
                16'h6f78:           ef_length = 2;
                16'h2fe2:           ef_length = 10;
                default:            ef_length = 1;
            endcase
        end
    endfunction

    function [7:0] ef_byte;
        input [15:0] file;
        input [4:0] index;
        begin
            ef_byte = 0;
            case (file)
                // TS51.011 mandatory boot reads: BCCH is an empty bitmap
                // (default zero), Kc has no available key (sequence7), and
                // FPLMN has no entries. These remain constant test-card data;
                // no authentication, network or writable-file claim is made.
                16'h6f20: if (index == 8) ef_byte = 8'h07;
                16'h6f7b: ef_byte = 8'hff;
                16'h2fe2:
                case (index)
                    0:       ef_byte = 8'h98;
                    1:       ef_byte = 8'h10;
                    2:       ef_byte = 8'h10;
                    3:       ef_byte = 8'h32;
                    4:       ef_byte = 8'h54;
                    5:       ef_byte = 8'h76;
                    6:       ef_byte = 8'h98;
                    7:       ef_byte = 8'h10;
                    8:       ef_byte = 8'h32;
                    9:       ef_byte = 8'hf8;
                    default: ;
                endcase
                16'h6f78: if (index == 1) ef_byte = 1;
                16'h6f07:
                case (index)
                    0:       ef_byte = 8;
                    1:       ef_byte = 8'h09;
                    2, 3, 4: ef_byte = 8'h10;
                    5:       ef_byte = 8'h32;
                    6:       ef_byte = 8'h54;
                    7:       ef_byte = 8'h76;
                    8:       ef_byte = 8'h98;
                    default: ;
                endcase
                16'h6fad: if (index == 3) ef_byte = 2;
                16'h6f7e: ef_byte = index < 10 ? 8'hff : 8'h01;
                16'h6fae: ef_byte = 3;
                16'h6f05: ef_byte = 1;
                16'h6fb7:
                case (index)
                    0:       ef_byte = 8'h11;
                    1:       ef_byte = 8'hf2;
                    default: ef_byte = 8'hff;
                endcase
                default: ;
            endcase
        end
    endfunction
    function [7:0] response_byte;
        input [4:0] index;
        input [2:0] kind;
        input [15:0] file, dir;
        input [4:0] count;
        input [15:0] pair;
        begin
            response_byte = 0;
            case (kind)
                RESPONSE_PAIR: response_byte = index == 0 ? pair[15:8] : pair[7:0];
                RESPONSE_PROC: response_byte = pair[15:8];
                RESPONSE_EF_HEADER:
                case (index)
                    0:       response_byte = 8'hc0;
                    4:       response_byte = {3'd0, ef_length(file)};
                    5:       response_byte = file[15:8];
                    6:       response_byte = file[7:0];
                    7:       response_byte = 4;
                    9:       response_byte = 8'h0f;
                    10, 11:  response_byte = 8'hff;
                    12:      response_byte = 1;
                    13:      response_byte = 2;
                    16:      response_byte = 8'h90;
                    default: ;
                endcase
                RESPONSE_DF_HEADER: begin
                    case (index)
                        0:       response_byte = 8'hf2;
                        5:       response_byte = dir[15:8];
                        6:       response_byte = dir[7:0];
                        7:       response_byte = dir == 16'h3f00 ? 1 : 2;
                        13:      response_byte = 9;
                        14:      response_byte = 8'hb0;
                        17:      response_byte = 2;
                        19, 21:  response_byte = 8'h83;
                        20, 22:  response_byte = 8'h8a;
                        default: ;
                    endcase
                    if (index == count - 2) response_byte = 8'h90;
                    if (index == count - 1) response_byte = 0;
                end
                RESPONSE_EF_DATA: begin
                    if (index == 0) response_byte = 8'hb0;
                    else if (index == count - 2) response_byte = 8'h90;
                    else if (index != count - 1) response_byte = ef_byte(file, index - 1'b1);
                end
                default: ;
            endcase
        end
    endfunction
    always @(posedge clk) begin
        if (reset) begin
            head            <= 0;
            tail            <= 0;
            used            <= 0;
            selected        <= 16'h3f00;
            directory       <= 16'h3f00;
            file_id_high    <= 0;
            header_count    <= 0;
            select_left     <= 0;
            terminal_left   <= 0;
            overflow        <= 0;
            emit_state      <= EMIT_IDLE;
            response_kind   <= RESPONSE_PAIR;
            response_pair   <= 0;
            response_length <= 0;
            accepted_length <= 0;
            emit_index      <= 0;
            for (i = 0; i < 4; i = i + 1) header[i] <= 0;
        end else begin
            if (emit_state == EMIT_WRITE) begin
                if (emit_index + 1'b1 == accepted_length) emit_state <= EMIT_PUBLISH;
                else emit_index <= emit_index + 1'b1;
            end else if (emit_state == EMIT_PUBLISH) begin
                tail       <= tail + {1'b0, accepted_length};
                used       <= used + {2'b0, accepted_length};
                emit_state <= EMIT_IDLE;
            end
            if (cen && !emitting) begin
                if (pop_now) head <= head + 1'b1;
                used <= next_used;
                if (work_tx) begin
                    if (terminal_left != 0) begin
                        terminal_left <= terminal_left - 1'b1;
                        if (terminal_left == 1) queue_response(RESPONSE_PAIR, 2, 16'h9000);
                    end else if (select_left != 0) begin
                        file_id_high <= work_data;
                        select_left <= select_left - 1'b1;
                        if (select_left == 1) begin
                            if(next_file==16'h3f00 || next_file==16'h7f20 ||
                                (next_file==16'h2fe2 && directory==16'h3f00) ||
                                (supported_ef(
                                    next_file
                                ) && next_file != 16'h2fe2 && directory == 16'h7f20)) begin
                                selected <= next_file;
                                if (next_file == 16'h3f00 || next_file == 16'h7f20)
                                    directory <= next_file;
                                queue_response(RESPONSE_PAIR, 2,
                                               (next_file==16'h3f00 || next_file==16'h7f20) ? 16'h9f16 : 16'h9f0f);
                            end else queue_response(RESPONSE_PAIR, 2, 16'h9404);
                        end
                    end else if (header_count != 4) begin
                        header[header_count[1:0]] <= work_data;
                        header_count              <= header_count + 1'b1;
                    end else begin
                        header_count <= 0;
                        if (header[0] != 8'ha0) queue_response(RESPONSE_PAIR, 2, 16'h6e00);
                        else if(header[1]==8'h10 && header[2]==0 && header[3]==0 && work_data!=0) begin
                            terminal_left <= work_data;
                            queue_response(RESPONSE_PROC, 1, 16'h1000);
                        end else if(header[1]==8'ha4 && header[2]==0 && header[3]==0 && work_data==2) begin
                            file_id_high <= 0;
                            select_left <= 2;
                            queue_response(RESPONSE_PROC, 1, 16'ha400);
                        end else if(header[1]==8'hc0 && header[2]==0 && header[3]==0 && work_data==15 && supported_ef(
                                selected
                            ))
                            queue_response(RESPONSE_EF_HEADER, 18, 0);
                        else if(header[1]==8'hf2 && header[2]==0 && header[3]==0 && (work_data==15 || work_data==22))
                            queue_response(RESPONSE_DF_HEADER, work_data[4:0] + 5'd3, 0);
                        else if(header[1]==8'hb0 && header[2]==0 && header[3]==0 &&
                            work_data=={3'd0, ef_length(selected)} && supported_ef(
                                selected
                            ))
                            queue_response(RESPONSE_EF_DATA, ef_length(selected) + 5'd3, 0);
                        else queue_response(RESPONSE_PAIR, 2, 16'h6d00);
                    end
                end
            end
        end
    end
endmodule
