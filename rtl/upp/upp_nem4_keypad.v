// SPDX-License-Identifier: GPL-2.0-or-later
// NEM-4 keypad GPIO and CTSI behavior from ngage-v5's native ekeyb.dll tests.
// Pin levels and reset drive state follow the reference model.
module upp_nem4_keypad (
    input  wire        clk,
    input  wire        reset,
    input  wire [25:0] keys,
    input  wire        access,
    input  wire        write,
    input  wire [27:0] addr,
    input  wire [31:0] din,
    input  wire [ 3:0] sel,
    input  wire        genio1_driven,
    input  wire [15:0] genio_out,
    output reg  [31:0] rmask,
    output reg  [31:0] rdata,
    output wire        irq
);
    localparam [27:0] CTSI_ENABLE = 28'hC150014, CTSI_STATUS = 28'hC150100;
    localparam [27:0] GENIO_CLEAR = 28'hC150204,
                      GENIO_IN = 28'hC150208, GENIO_DIR = 28'hC15020C,
                      GENIO_DIR_HI = 28'hC150210;
    localparam [27:0] PORT_D = 28'hC150400, PORT_D_ENABLE = 28'hC150404,
                      PORT_E = 28'hC15040C, PORT_E_ENABLE = 28'hC150410;
    localparam [27:0] KPC_IN = 28'hC120C04, KPC_SET = 28'hC120C0C,
                      KPC_CLEAR = 28'hC120C10, KPC_DIR = 28'hC120C14;
    localparam [31:0] KEYPAD_IRQ_MASK = 32'h00EE0004;
    localparam [15:0] ROCKER_MASK = 16'h2C06;

    reg [4:0] d_drive, d_data, d_enable;
    reg [5:0] e_drive, e_data, e_enable;
    reg [15:0] genio_dir;
    reg [7:0] genio_enable;
    reg music_dir, music_out;
    reg kpc_drive, kpc_data;
    reg [5:0] last_e;
    reg [5:0] last_genio;
    reg [31:0] pending;
    reg [4:0] d_pins;
    reg [5:0] e_pins;
    reg [15:0] genio_pins, rocker;
    reg [31:0] press_events;
    integer key;
    integer row;

    wire [4:0] d_low = d_drive & ~d_data;
    wire [5:0] e_low = e_drive & ~e_data;
    wire [5:0] e_falls = last_e & ~e_pins & e_enable & ~e_drive;
    // Right, Music, Up, Left, OK, Down in CTSI bit order (23:21, 19:17).
    wire [5:0] genio_irq_pins = {genio_pins[2], genio_pins[12], genio_pins[1],
                                genio_pins[13], genio_pins[11], genio_pins[10]};
    wire [5:0] genio_irq_drive = {genio_dir[2], music_dir, genio_dir[1],
                                 genio_dir[13], genio_dir[11], genio_dir[10]};
    wire [5:0] genio_falls = last_genio & ~genio_irq_pins & ~genio_irq_drive &
                             {genio_enable[7:5], genio_enable[3:1]};
    wire [31:0] lanes = {{8{sel[3]}}, {8{sel[2]}}, {8{sel[1]}}, {8{sel[0]}}};
    wire [31:0] clear = write && addr == CTSI_STATUS ? din & lanes : 32'd0;
    assign irq = |pending;

    always @* begin
        press_events = 32'd0;
        // The NEM-4 matrix handler tests port E's edge bit. The rocker and
        // music inputs have their own bits in the upper CTSI status word.
        press_events[2]  = |e_falls;
        {press_events[23:21], press_events[19:17]} = genio_falls;
    end

    always @(posedge clk) begin
        if (reset) begin
            d_drive      <= 5'h1F;
            e_drive      <= 6'd0;
            d_data       <= 5'd0;
            e_data       <= 6'd0;
            d_enable     <= 5'd0;
            e_enable     <= 6'd0;
            genio_dir    <= 16'd0;
            genio_enable <= 8'd0;
            music_dir    <= 1'b0;
            music_out    <= 1'b0;
            kpc_drive    <= 1'b1;
            kpc_data     <= 1'b0;
            last_e       <= 6'h3F;
            last_genio   <= 6'h3F;
            pending      <= 32'd0;
        end else begin
            // Observe levels while masked too. An IRQ enable for a held key
            // does not create an edge, and a new edge wins a simultaneous ACK.
            last_e     <= e_pins;
            last_genio <= genio_irq_pins;
            pending    <= (pending & ~clear) | press_events;
            if (write) begin
                case (addr)
                    PORT_D: begin
                        d_drive <= (d_drive | (din[20:16] & {5{sel[2]}})) &
                                              ~(din[28:24] & {5{sel[3]}});
                        if (sel[0]) d_data <= din[4:0];
                    end
                    PORT_E: begin
                        e_drive <= (e_drive | (din[21:16] & {6{sel[2]}})) &
                                              ~(din[29:24] & {6{sel[3]}});
                        if (sel[0]) e_data <= din[5:0];
                    end
                    PORT_D_ENABLE: d_enable <= (d_enable | (din[4:0] & {5{sel[0]}})) &
                                                           ~(din[12:8] & {5{sel[1]}});
                    PORT_E_ENABLE: e_enable <= (e_enable | (din[5:0] & {6{sel[0]}})) &
                                                           ~(din[13:8] & {6{sel[1]}});
                    GENIO_CLEAR:  if (sel[3] && din[28]) music_out <= 1'b1;
                    GENIO_IN:     if (sel[1] && din[12]) music_out <= 1'b0;
                    GENIO_DIR:    genio_dir <= (genio_dir & ~lanes[31:16]) | (din[31:16] & lanes[31:16]);
                    GENIO_DIR_HI: if (sel[1]) music_dir <= din[12];
                    CTSI_ENABLE: genio_enable <= (genio_enable | (din[23:16] & {8{sel[2]}})) &
                                                                ~(din[7:0] & {8{sel[0]}});
                    KPC_SET:   if (sel[2] && din[19]) kpc_data <= 1'b1;
                    KPC_CLEAR: if (sel[2] && din[19]) kpc_data <= 1'b0;
                    KPC_DIR:   if (&sel) kpc_drive <= !din[19];
                    default: ;
                endcase
            end
        end
    end

    always @* begin
        d_pins = ~d_low;
        e_pins = ~e_low;
        rocker = 16'h3C06;
        if (keys[0]) rocker[1]  = 1'b0;  // Up
        if (keys[1]) rocker[10] = 1'b0;  // Down
        if (keys[2]) rocker[13] = 1'b0;  // Left
        if (keys[3]) rocker[2]  = 1'b0;  // Right
        if (keys[4]) rocker[11] = 1'b0;  // OK
        genio_pins = (rocker & ~genio_dir) | (genio_out & genio_dir);
        genio_pins[12] = music_dir ? music_out : !keys[25];
        // The UEM loopback can drive this line during the native I/O test.
        if (genio1_driven && !genio_dir[1]) genio_pins[1] = genio_out[0] & !keys[0];

        if (keys[5] && e_low[0]) d_pins[0] = 1'b0;
        if (keys[6] && e_low[0]) d_pins[1] = 1'b0;
        if (keys[7] && e_low[1]) d_pins[0] = 1'b0;
        if (keys[8] && e_low[1]) d_pins[1] = 1'b0;
        for (key = 0; key < 12; key = key + 1)
            if (keys[9+key] && e_low[2+key/3]) d_pins[2+key%3] = 1'b0;

        if ((keys[5] && d_low[0]) || (keys[6] && d_low[1])) e_pins[0] = 1'b0;
        if ((keys[7] && d_low[0]) || (keys[8] && d_low[1])) e_pins[1] = 1'b0;
        for (row = 0; row < 4; row = row + 1)
            if ((keys[9+3*row] && d_low[2]) || (keys[10+3*row] && d_low[3]) ||
                (keys[11+3*row] && d_low[4]) || (keys[21+row] && kpc_drive && !kpc_data))
                e_pins[2+row] = 1'b0;

        d_pins = (d_pins & ~d_drive) | (d_data & d_drive);
        e_pins = (e_pins & ~e_drive) | (e_data & e_drive);
    end

    always @* begin
        rmask = 32'd0;
        rdata = 32'd0;
        if (access) begin
            case (addr)
                CTSI_STATUS: begin
                    rmask = KEYPAD_IRQ_MASK;
                    rdata = pending;
                end
                CTSI_ENABLE: begin
                    rmask = 32'h00EE00EE;
                    rdata = {8'd0, genio_enable, 8'd0, genio_enable} & rmask;
                end
                GENIO_IN: begin
                    rmask = {ROCKER_MASK, 16'd0};
                    rdata = {genio_pins & ROCKER_MASK, 16'd0};
                end
                GENIO_DIR: begin
                    rmask = {ROCKER_MASK, 16'h1000};
                    rdata = {genio_dir & ROCKER_MASK, 3'd0, genio_pins[12], 12'd0};
                end
                GENIO_DIR_HI: begin
                    rmask = 32'h00001000;
                    rdata = {19'd0, music_dir, 12'd0};
                end
                PORT_D: begin
                    rmask = 32'h001F001F;
                    rdata = {11'd0, d_drive, 11'd0, d_pins};
                end
                PORT_E: begin
                    rmask = 32'h003F003F;
                    rdata = {10'd0, e_drive, 10'd0, e_pins};
                end
                PORT_D_ENABLE: begin
                    rmask = 32'h0000001F;
                    rdata = {27'd0, d_enable};
                end
                PORT_E_ENABLE: begin
                    rmask = 32'h0000003F;
                    rdata = {26'd0, e_enable};
                end
                KPC_IN: begin
                    rmask[19] = 1'b1;
                    rdata[19] = kpc_drive ? kpc_data : !((keys[21] && e_low[2]) ||
                                                        (keys[22] && e_low[3]) ||
                                                        (keys[23] && e_low[4]) ||
                                                        (keys[24] && e_low[5]));
                end
                default: ;
            endcase
        end
    end
endmodule
