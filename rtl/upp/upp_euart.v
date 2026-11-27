// SPDX-License-Identifier: GPL-2.0-or-later
// Ported from NGage_MiSTer ngage-v5.
// UPP EUART1 transaction model derived from the original NEM-4 ADSPComm driver.
// Byte streams stand in for serial pins; baud/electrical timing is unverified.
// No DSP response or diagnostic success is manufactured by this controller.
module upp_euart (
    input  wire        clk,
    input  wire        reset,
    input  wire        req,
    input  wire        enabled,
    input  wire        commit,
    input  wire        we,
    input  wire [27:2] addr,
    input  wire [31:0] din,
    input  wire [ 3:0] sel,
    output wire        claim,
    output wire        bad,
    output wire        ready,
    output reg  [31:0] dout,
    output wire        irq_pending,
    output wire        tx_valid,
    input  wire        tx_ready,
    output wire [ 7:0] tx_data,
    input  wire        rx_valid,
    output wire        rx_ready,
    input  wire [ 7:0] rx_data,
    output wire        receive_enabled
);
    wire [31:0] a = {4'd0, addr, 2'b00};
    wire low_lane = |sel[1:0];
    wire high_lane = |sel[3:2];
    wire [31:0] mask = {{8{sel[3]}}, {8{sel[2]}}, {8{sel[1]}}, {8{sel[0]}}};
    wire lanes_ok = sel==1 || sel==2 || sel==4 || sel==8 || sel==3 || sel==12 || sel==15;
    wire data_word = a == 32'h0c150554;
    wire tx_write = data_word && we && low_lane;
    wire rx_read = data_word && !we && high_lane;
    wire status_word = a == 32'h0c1500b8 && high_lane;
    wire [15:0] status;
    reg [31:0] uart_config, line_control, batch_control, rx_control;
    reg [15:0] enables;
    reg        tx_done;
    reg [ 4:0] batch_left;
    reg [3:0] tx_producer, tx_consumer, rx_producer, rx_consumer;
    reg  [4:0] tx_count;
    wire [3:0] rx_count = rx_producer - rx_consumer;
    reg [1:0] tx_sample, rx_sample;
    wire accepted = req && commit && claim && !bad && ready;
    wire rx_flush = accepted && we && a == 32'h0c150560 && low_lane && |din[2:0];
    wire tx_push = accepted && tx_write;
    wire tx_pop = tx_valid && tx_ready;
    wire rx_push = rx_valid && rx_ready;
    wire rx_pop = accepted && rx_read;
    wire [7:0] tx_q, rx_q;
    // Separate synchronous queues keep ingress and egress independent. Each
    // tiny queue is a BRAM, not a wide variable-index FF read mux. The
    // queues use the core's synchronous simple-dual-port RAM template.
    sdp_ram #(.AW(4), .DW(8)) tx_fifo (
        .clk  (clk),
        .we   (tx_push),
        .waddr(tx_producer),
        .wdata(din[15:8]),
        .raddr(tx_consumer),
        .rdata(tx_q)
    );
    sdp_ram #(.AW(4), .DW(8)) rx_fifo (
        .clk  (clk),
        .we   (rx_push),
        .waddr(rx_producer),
        .wdata(rx_data),
        .raddr(rx_consumer),
        .rdata(rx_q)
    );
    assign claim = req && enabled && (a == 32'h0c150510 || a == 32'h0c150514 ||
        data_word || a == 32'h0c150558 || a == 32'h0c15055c ||
        a == 32'h0c150560 || status_word);
    assign bad = claim && (!lanes_ok || (rx_read && rx_count == 0));
    assign ready = !claim || (!tx_write || tx_count < 16) &&
        (!rx_read || rx_count == 0 || rx_sample == 2);
    assign tx_valid = !reset && tx_count != 0 && tx_sample == 2;
    assign tx_data = tx_q;
    // Native RX producer/consumer indices are four bits; leave one slot empty.
    assign receive_enabled = !reset && enables[3] && rx_control[2:0] == 0;
    assign rx_ready = !reset && !rx_flush && rx_count != 15;
    assign status = (rx_count != 0 ? 16'h0008 : 0) | (tx_done ? 16'h0010 : 0);
    assign irq_pending = !reset && |(status & enables & 16'h0018);
    always @* begin
        dout = 0;
        case (a)
            32'h0c150510: dout = uart_config;
            32'h0c150514:
            dout = (line_control & ~32'h4) | (tx_count == 0 && batch_left == 0 ? 32'h4 : 0);
            32'h0c150554: dout = {rx_q, 8'b0, 16'b0};
            32'h0c150558: dout = batch_control;
            32'h0c15055c: dout = {24'b0, tx_producer, tx_consumer};
            32'h0c150560: dout = {8'b0, rx_producer, rx_consumer, rx_control[15:0]};
            32'h0c1500b8: dout = {status, 16'b0};
        endcase
        dout = dout & mask;
    end
    always @(posedge clk) begin
        if (reset) begin
            uart_config   <= 0;
            line_control  <= 0;
            batch_control <= 0;
            rx_control    <= 0;
            enables       <= 0;
            tx_done       <= 0;
            batch_left    <= 0;
            tx_producer   <= 0;
            tx_consumer   <= 0;
            rx_producer   <= 0;
            rx_consumer   <= 0;
            tx_count      <= 0;
            tx_sample     <= 0;
            rx_sample     <= 0;
        end else begin
            // The original driver enables RX/TX through halfword00E;00C
            // clears those enables. This is a transaction shortcut for CTSI.
            if (req && enabled && commit && we && lanes_ok && a == 32'h0c15000c)
                enables <= (enables & ~(din[15:0] & mask[15:0])) | (din[31:16] & mask[31:16]);
            if (accepted && we) begin
                case (a)
                    32'h0c150510: uart_config <= (uart_config & ~mask) | (din & mask);
                    32'h0c150514: line_control <= (line_control & ~mask) | (din & mask);
                    32'h0c150558: begin
                        batch_control <= (batch_control & ~mask) | (din & mask);
                        if (high_lane) begin
                            batch_left <= {1'b0, din[19:16]} + 1'b1;
                            tx_done    <= 0;
                        end
                    end
                    32'h0c150560:
                    if (low_lane) begin
                        rx_control <= (rx_control & ~mask) | (din & mask);
                        // Native stop writes7 before reinitializing RX, then0.
                    end
                    32'h0c1500b8: if (high_lane && din[20]) tx_done <= 0;
                endcase
            end
            case ({
                tx_push, tx_pop
            })
                2'b10:   tx_count <= tx_count + 1'b1;
                2'b01:   tx_count <= tx_count - 1'b1;
                default: ;
            endcase
            if (tx_push) tx_producer <= tx_producer + 1'b1;
            if (tx_pop) begin
                tx_consumer <= tx_consumer + 1'b1;
                tx_sample   <= 0;
                if (batch_left != 0) begin
                    batch_left <= batch_left - 1'b1;
                    if (batch_left == 1) tx_done <= 1;
                end
            end else if (tx_count != 0 && tx_sample != 2) tx_sample <= tx_sample + 1'b1;
            if (rx_flush) begin
                rx_producer <= 0;
                rx_consumer <= 0;
                rx_sample   <= 0;
            end else begin
                if (rx_push) rx_producer <= rx_producer + 1'b1;
                if (rx_pop) begin
                    rx_consumer <= rx_consumer + 1'b1;
                    rx_sample   <= 0;
                end else if (rx_count != 0 && rx_sample != 2) rx_sample <= rx_sample + 1'b1;
            end
        end
    end
endmodule
