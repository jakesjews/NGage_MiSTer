// SPDX-License-Identifier: GPL-2.0-or-later
// PCM renderer for the native DSP E8 stream. Its control port is internal
// to the MDI peer. Signed 16-bit SDRAM samples are resampled to 48 kHz.
module upp_pcm #(
    parameter integer CLK_HZ = 104_000_000,
    parameter integer OUT_HZ = 48_000
) (
    input wire clk,
    input wire reset,
    input wire enabled,

    input  wire        wr,
    input  wire [ 7:0] off,
    input  wire [31:0] wdata,
    output wire [19:0] stream_status,

    // sample reads (Wishbone B3 classic)
    output reg         m_cyc,
    output wire        m_stb,
    output wire        m_we,
    output reg  [31:0] m_adr,
    output wire [31:0] m_dat_o,
    output wire [ 3:0] m_sel,
    input  wire        m_ack,
    input  wire        m_err,
    input  wire [31:0] m_dat_i,

    // the output, signed, at OUT_HZ
    output reg [15:0] out_l,
    output reg [15:0] out_r,
    output reg        out_valid,

    // for the bench: each frame as its samples arrive
    output reg         frame_we,
    output wire [15:0] frame_l,
    output wire [15:0] frame_r
);

    function integer clog2;
        input [63:0] value;
        reg [63:0] n;
        begin
            n = value - 64'd1;
            for (clog2 = 0; n != 0; clog2 = clog2 + 1) n = n >> 1;
        end
    endfunction

    localparam         [  63:0] CLOCK_64     = {32'd0, CLK_HZ};
    localparam         [  63:0] OUT_RATE_64  = {32'd0, OUT_HZ};
    localparam integer          FW           = clog2(CLOCK_64 + 64'd48001);
    localparam integer          OW           = clog2(CLOCK_64 + OUT_RATE_64 + 64'd1);
    // 2^40 / CLK_HZ: the frame phase (0 to CLK_HZ - 1) as 16 bits
    localparam         [  63:0] PK           = (64'd1 << 40) / CLOCK_64;
    localparam integer          KW           = clog2(PK + 64'd1);
    localparam         [FW-1:0] FRAME_CLOCK  = CLOCK_64                              [FW-1:0];
    localparam         [OW-1:0] OUTPUT_CLOCK = CLOCK_64                              [OW-1:0];
    localparam         [OW-1:0] OUTPUT_RATE  = OUT_RATE_64                           [OW-1:0];

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg [31:1] addr0, addr1;
    reg [31:0] pos;
    reg run;
    reg [15:0] rate;
    reg stereo, cur;
    reg [1:0] full, done;
    reg [FW-1:0] facc;

    assign stream_status = {done, full, run, pos[14:0]};

    // the frame clock
    wire [FW-1:0] fsum = facc + {{(FW - 16) {1'b0}}, rate};
    wire          tick = run && fsum >= FRAME_CLOCK;

    // the frame the tick plays
    wire        sw = !full[cur] && full[!cur];
    wire        b = sw ? !cur : cur;
    wire [31:0] p = sw ? 32'd0 : pos;
    wire        play = full[b];
    wire [31:0] p1 = p + 32'd1;
    // p1 >= blen without p1's carry chain in front of the compare: the
    // length minus one and its zero flag are registers, set with the length
    // (p + 1 >= blen is blen == 0, or p >= blen - 1 unless p + 1 wraps).
    reg [31:0] len0m1, len1m1;
    reg len0z, len1z;
    wire ends = (b ? len1z : len0z) || (p >= (b ? len1m1 : len0m1) && p != 32'hFFFF_FFFF);
    wire [31:1] fadr = (b ? addr1 : addr0) + (stereo ? {p[29:0], 1'b0} : p[30:0]);

    wire run_set = wr && off == 8'h04 && wdata[0] && !run;
    wire [15:0] rate_w = (wdata < 32'd4000) ? 16'd4000 : (wdata > 32'd48000) ? 16'd48000 : wdata[15:0];

    // the sample-read request: one deep, the latest frame
    reg rq_v, rq_play, rq_st;
    reg [31:1] rq_adr;  // halfword address
    reg        start;  // in the clock after a RUN 0 -> 1 write

    localparam [1:0] F_IDLE = 2'd0, F_L = 2'd1, F_R = 2'd2;
    reg  [1:0] fst;
    wire       f_take = enabled && fst == F_IDLE && rq_v && !start;

    always @(posedge clk) begin
        start <= 1'b0;
        if (run) facc <= tick ? fsum - FRAME_CLOCK : fsum;
        if (f_take || start) rq_v <= 1'b0;

        if (tick) begin
            cur     <= b;
            pos     <= p;
            if (play) begin
                pos <= p1;
                if (ends) begin
                    full[b] <= 1'b0;
                    done[b] <= 1'b1;
                    cur     <= !b;
                    pos     <= 32'd0;
                end
            end
            rq_v    <= 1'b1;
            rq_play <= play;
            rq_st   <= stereo;
            rq_adr  <= fadr;
        end

        if (wr) begin
            case (off)
                8'h04: begin
                    run <= wdata[0];
                    if (run_set) begin
                        cur     <= 1'b0;
                        pos     <= 32'd0;
                        facc    <= {FW{1'b0}};
                        start   <= 1'b1;
                    end
                    if (!wdata[0]) begin
                        full <= 2'b00;
                        done <= 2'b00;
                    end
                end
                8'h08:   stereo <= wdata[0];
                8'h0C: begin
                    if (rate_w != rate && run) facc <= {FW{1'b0}};
                    rate <= rate_w;
                end
                8'h10:   addr0 <= wdata[31:1];
                8'h14:   addr1 <= wdata[31:1];
                8'h18: begin
                    len0m1  <= wdata - 32'd1;
                    len0z   <= wdata == 32'd0;
                    full[0] <= wdata != 32'd0;
                end
                8'h1C: begin
                    len1m1  <= wdata - 32'd1;
                    len1z   <= wdata == 32'd0;
                    full[1] <= wdata != 32'd0;
                end
                8'h20: begin
                    if (wdata[0]) done[0] <= 1'b0;
                    if (wdata[1]) done[1] <= 1'b0;
                end
                default: ;
            endcase
        end

        if (reset || !enabled) begin
            run              <= 1'b0;
            stereo           <= 1'b0;
            rate             <= 16'd16000;
            addr0            <= 31'd0;
            addr1            <= 31'd0;
            len0m1           <= 32'hFFFF_FFFF;
            len1m1           <= 32'hFFFF_FFFF;
            len0z            <= 1'b1;
            len1z            <= 1'b1;
            full             <= 2'b00;
            done             <= 2'b00;
            cur              <= 1'b0;
            pos              <= 32'd0;
            facc             <= {FW{1'b0}};
            rq_v             <= 1'b0;
            start            <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Sample reads
    // ------------------------------------------------------------------
    reg w_st, w_hi, drop;
    reg [29:0] w_nxt;  // the word after the first
    reg [15:0] r_l, r_r;

    assign m_stb   = m_cyc;
    assign m_we    = 1'b0;
    assign m_dat_o = 32'd0;
    assign m_sel   = 4'b1111;

    wire [15:0] lo = m_err ? 16'd0 : m_dat_i[15:0];
    wire [15:0] hi = m_err ? 16'd0 : m_dat_i[31:16];
    wire        bus_end = m_ack || m_err;
    // the last read of a frame ends
    wire        fin = bus_end && ((fst == F_L && !(w_st && w_hi)) || fst == F_R);

    assign frame_l = r_l;
    assign frame_r = r_r;

    always @(posedge clk) begin
        frame_we <= 1'b0;
        case (fst)
            F_IDLE:
            if (f_take) begin
                w_st  <= rq_st;
                w_nxt <= rq_adr[31:2] + 30'd1;
                w_hi  <= rq_adr[1];
                if (rq_play) begin
                    m_cyc <= 1'b1;
                    m_adr <= {rq_adr[31:2], 2'b00};
                    fst   <= F_L;
                end else begin
                    frame_we <= 1'b1;
                    r_l      <= 16'd0;
                    r_r      <= 16'd0;
                end
            end
            F_L:
            if (bus_end) begin
                r_l <= w_hi ? hi : lo;
                if (w_st && w_hi) begin
                    m_adr <= {w_nxt, 2'b00};  // R in the next word
                    fst   <= F_R;
                end else begin
                    m_cyc    <= 1'b0;
                    fst      <= F_IDLE;
                    frame_we <= !drop && !start && enabled;
                    r_r      <= w_st ? hi : (w_hi ? hi : lo);
                end
            end
            F_R:
            if (bus_end) begin
                m_cyc    <= 1'b0;
                fst      <= F_IDLE;
                frame_we <= !drop && !start && enabled;
                r_r      <= lo;
            end
            default: fst <= F_IDLE;
        endcase
        // a read still under way when a run starts is from the run before
        if (fin) drop <= 1'b0;
        if ((start || !enabled) && fst != F_IDLE && !fin) drop <= 1'b1;
        if (reset) begin
            fst      <= F_IDLE;
            m_cyc    <= 1'b0;
            drop     <= 1'b0;
            frame_we <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // The output: linear interpolation at OUT_HZ
    // ------------------------------------------------------------------
    reg [15:0] fr_l, fr_r, o0_l, o0_r, o1_l, o1_r;
    reg [OW-1:0] oacc;
    reg ot1, ot2;
    reg [15:0] frac;
    reg signed [16:0] d_l, d_r;
    reg signed [15:0] b_l, b_r;
    reg [15:0] x_l, x_r;

    function [15:0] scale_step;
        input signed [16:0] step;
        input [15:0] fraction;
        reg signed [33:0] m;
        begin
            m = step * $signed({1'b0, fraction});
            scale_step = m[31:16];
        end
    endfunction

    wire [   OW-1:0] osum = oacc + OUTPUT_RATE;
    wire             otick = osum >= OUTPUT_CLOCK;
    wire [FW+KW-1:0] ph = facc * PK[KW-1:0];

    always @(posedge clk) begin
        oacc      <= otick ? osum - OUTPUT_CLOCK : osum;
        ot1       <= otick;
        ot2       <= ot1;
        out_valid <= ot2;

        if (frame_we) begin
            fr_l <= frame_l;
            fr_r <= frame_r;
        end
        if (tick) begin
            o0_l <= o1_l;
            o0_r <= o1_r;
            o1_l <= frame_we ? frame_l : fr_l;
            o1_r <= frame_we ? frame_r : fr_r;
        end
        // a run starts from silence: the frames at the RUN write, and a frame
        // that comes in just after it (from the run before)
        if (run_set) begin
            o0_l <= 16'd0;
            o0_r <= 16'd0;
            o1_l <= 16'd0;
            o1_r <= 16'd0;
        end
        if (start) begin
            fr_l <= 16'd0;
            fr_r <= 16'd0;
        end

        // stage 1, at the output tick: the phase and the step (0 while stopped)
        if (otick) begin
            frac <= ph[39:24];
            d_l  <= run ? $signed({o1_l[15], o1_l}) - $signed({o0_l[15], o0_l}) : 17'sd0;
            d_r  <= run ? $signed({o1_r[15], o1_r}) - $signed({o0_r[15], o0_r}) : 17'sd0;
            b_l  <= run ? $signed(o0_l) : 16'sd0;
            b_r  <= run ? $signed(o0_r) : 16'sd0;
        end
        // stage 2: the step times the phase
        if (ot1) begin
            x_l <= scale_step(d_l, frac);
            x_r <= scale_step(d_r, frac);
        end
        // stage 3
        if (ot2) begin
            out_l <= run ? b_l + x_l : 16'd0;
            out_r <= run ? b_r + x_r : 16'd0;
        end

        if (reset || !enabled) begin
            oacc      <= {OW{1'b0}};
            ot1       <= 1'b0;
            ot2       <= 1'b0;
            fr_l      <= 16'd0;
            fr_r      <= 16'd0;
            o0_l      <= 16'd0;
            o0_r      <= 16'd0;
            o1_l      <= 16'd0;
            o1_r      <= 16'd0;
            out_l     <= 16'd0;
            out_r     <= 16'd0;
            out_valid <= 1'b0;
        end
    end

endmodule
