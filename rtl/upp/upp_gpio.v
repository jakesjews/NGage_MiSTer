// SPDX-License-Identifier: GPL-2.0-or-later
// UPP GENIO set/clear and UEM-routed startup test loops from the NEM-4 core.
// These paths model the observed register contract. Pin timing is unverified.
module upp_gpio (
    input  wire        clk,
    input  wire        reset,
    input  wire        wr,
    input  wire [ 1:0] word_addr,
    input  wire [31:0] din,
    input  wire [ 3:0] sel,
    input  wire        ear_route,
    input  wire        sim_route,
    input  wire        tx_route,
    output wire [15:0] genio_out,
    output reg  [31:0] dout
);
    reg [31:0] r200, r204, r208, r20c;
    wire [31:0] mask = {{8{sel[3]}}, {8{sel[2]}}, {8{sel[1]}}, {8{sel[0]}}};
    localparam [31:0] GENIO1 = 32'h0002_0000;
    localparam [31:0] GENIO3 = 32'h0008_0000;
    localparam [31:0] GENIO17 = 32'h0000_0002;
    assign genio_out = r200[31:16];

    always @* begin
        case (word_addr)
            2'd0: dout = r200;
            2'd1: dout = r204;
            2'd2: dout = r208 | ((ear_route && r200[16]) ? GENIO1 : 32'd0) |
                                ((tx_route && r200[18]) ? GENIO3 : 32'd0);
            2'd3: dout = r20c | ((sim_route && r204[18] && r204[16]) ? GENIO17 : 32'd0);
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            r200 <= 0;
            r204 <= 0;
            r208 <= 0;
            r20c <= 0;
        end else if (wr) begin
            case (word_addr)
                2'd0: begin
                    r200 <= (r200 & ~mask) | (din & mask) | (r200 & mask & 32'hffff0000);
                    r204[15:0] <= r204[15:0] & ~(din[31:16] & mask[31:16]);
                end
                2'd1: begin
                    r204 <= (r204 & ~mask) | (din & mask) | (r204 & mask & 32'hffff0000);
                    r200[31:16] <= r200[31:16] & ~(din[15:0] & mask[15:0]);
                    r208[15:0] <= r208[15:0] & ~(din[31:16] & mask[31:16]);
                end
                2'd2: begin
                    r208 <= (r208 & ~mask) | (din & mask & ~(GENIO1 | GENIO3));
                    r204[31:16] <= r204[31:16] & ~(din[15:0] & mask[15:0]);
                end
                2'd3: r20c <= (r20c & ~mask) | (din & mask & ~GENIO17);
            endcase
        end
    end
endmodule
