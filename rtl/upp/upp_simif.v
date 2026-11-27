// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from NGage_MiSTer ngage-v5 at f2d9c04.
// Staged diagnostic SIMIF register and event hypothesis. This is not verified
// UPP/UEM electrical timing; the card boundary is a byte-level transaction.
// Presence is sampled only during reset; changing the input later has no effect.
module upp_simif (
    input  wire        clk,
    input  wire        reset,
    input  wire        present,
    input  wire        req,
    input  wire        commit,
    input  wire        we,
    input  wire [27:2] addr,
    input  wire [31:0] din,
    input  wire [ 3:0] sel,
    output reg         claim,
    output reg         bad,
    output reg  [31:0] dout,
    output wire        fiq_pending,
    output wire        card_tx_valid,
    output wire [ 7:0] card_tx_data,
    input  wire        card_rx_valid,
    input  wire [ 7:0] card_rx_data,
    input  wire [ 6:0] card_available,
    input  wire        card_tx_will_emit,
    output wire        card_rx_pop
);
    wire [31:0] a = {4'd0, addr, 2'b00};
    wire [31:0] mask = {{8{sel[3]}}, {8{sel[2]}}, {8{sel[1]}}, {8{sel[0]}}};
    wire valid_sel=sel==1 || sel==2 || sel==4 || sel==8 || sel==3 || sel==12 || sel==15;
    reg present_latched, injected;
    reg [15:0] status;
    reg [31:0] reg804, reg808, reg80c;
    reg  [31:0] position;
    reg  [ 1:0] phase;
    reg  [31:0] read804;
    wire        low_access = |(sel & 4'h3);
    assign fiq_pending = |status;
    assign card_tx_valid=commit && claim && !bad && we && a==32'h0c15080c && low_access && injected;
    assign card_tx_data = din[7:0];
    assign card_rx_pop=commit && claim && !bad && !we && a==32'h0c15080c && low_access && present_latched && phase!=0 && card_rx_valid;
    always @* begin
        claim=req && ((a==32'h0c150800 && low_access) || a==32'h0c150804 || a==32'h0c150808 || a==32'h0c15080c ||
                (a==32'h0c1500b8 && !we && low_access));
        bad = claim && !valid_sel;
        dout = 0;
        read804 = reg804;
        if (a == 32'h0c150804 && !we && |(sel & 4'hc)) begin
            if (reg804[31:16] == 16'h79) read804 = reg804 & ~32'h003a0000;
            else if (reg804[31:16] == 16'h7e) read804 = reg804 & ~32'h00390000;
        end
        case (a)
            32'h0c1500b8: dout = fiq_pending ? 4 : 0;
            32'h0c150800: dout = {16'b0, status};
            32'h0c150804: dout = read804 & mask;
            32'h0c150808: dout = reg808 & mask;
            32'h0c15080c: begin
                if (!we && low_access) begin
                    if (!present_latched) dout = 0;
                    else if (phase == 0) dout = position == 0 ? 32'h3b : 0;
                    else if (!card_rx_valid) bad = 1;
                    else dout = {24'b0, card_rx_data};
                end else dout = reg80c & mask;
            end
            default: ;
        endcase
    end
    always @(posedge clk) begin
        if (reset) begin
            present_latched <= present;
            injected        <= 0;
            status          <= 0;
            reg804          <= 0;
            reg808          <= 0;
            reg80c          <= 0;
            position        <= 0;
            phase           <= 0;
        end else begin
            if (commit && claim && !bad) begin
                case (a)
                    32'h0c150800:
                    if (we && low_access) begin
                        status <= status & ~din[15:0];
                        if (status[3] && din[3] && phase == 1) begin
                            if (card_available != 0) status <= (status & ~din[15:0]) | 16'h10;
                            phase <= 2;
                        end
                    end
                    32'h0c150804: begin
                        if (we) reg804 <= (reg804 & ~mask) | (din & mask);
                        else if (|(sel & 12)) reg804 <= read804;
                    end
                    32'h0c150808:
                    if (we) begin
                        reg808 <= (reg808 & ~mask) | (din & mask);
                        if (low_access && din[15:0] == 1 && present_latched && !injected) begin
                            injected <= 1;
                            status   <= 16'h10;
                        end
                    end
                    32'h0c15080c: begin
                        if (we) begin
                            reg80c <= (reg80c & ~mask) | (din & mask);
                            if (card_tx_valid && card_available == 0 && card_tx_will_emit) begin
                                phase    <= 1;
                                status   <= 8;
                                position <= 0;
                            end
                        end else if (low_access && present_latched) begin
                            if (phase == 0) position <= position + 1'b1;
                            else if (card_rx_valid) begin
                                position <= position + 1'b1;
                                if (card_available == 1) status <= 0;
                                else if (position[0]) status <= 16'h10;
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
