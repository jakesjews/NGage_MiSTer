`timescale 1ns/1ps
// Verilog-2001 testbench; the imported DMA and RAM use SystemVerilog.
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, acc = 0, wr = 0;
    reg [11:0] off = 0;
    reg [31:0] wdata = 0;
    wire [31:0] rmask, rdata;
    wire [7:0] irq;
    wire m_cyc, m_stb, m_we;
    wire [31:0] m_adr, m_dat_o;
    wire [3:0] m_sel;
    reg [31:0] m_dat_i;
    integer clocks = 0;
    wire m_ack = m_cyc && clocks % 5 >= 2;
    upp_dma dut (
        .clk(clk), .reset(reset), .acc(acc), .wr(wr), .off(off), .wdata(wdata),
        .rmask(rmask), .rdata(rdata), .irq(irq),
        .mmc_rx_ready(clocks % 7 >= 3), .mmc_tx_ready(clocks % 11 >= 5),
        .lcd_tx_ready(clocks % 13 >= 4),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr),
        .m_dat_o(m_dat_o), .m_sel(m_sel), .m_ack(m_ack), .m_err(1'b0), .m_dat_i(m_dat_i)
    );
    localparam [31:0] MMC_FIFO = 32'h0c120624, LCD_FIFO = 32'h0c121208;
    reg [7:0] memory [0:4095];
    reg [7:0] expected [0:4095];
    reg [7:0] stream [0:2047];
    integer cases = 0, words = 0, read_total = 0, written = 0;
    integer sw, dw, total, sa, da, kind;
    reg si, di;
    integer j;
    always @* begin
        m_dat_i = 0;
        if (m_adr == MMC_FIFO)
            for (j = 0; j < 4; j = j + 1)
                m_dat_i[j*8 +: 8] = (read_total + j) * 17 + 8'h35;
        else if (m_adr < 4093)
            for (j = 0; j < 4; j = j + 1)
                m_dat_i[j*8 +: 8] = memory[m_adr+j];
    end
    integer logical_addr, bytes, mask, i;
    reg [31:0] data;
    reg stalled = 0;
    reg [68:0] packet;
    always @(posedge clk) begin
        clocks = clocks + 1;
        if (reset) stalled = 0;
        else begin
            if (stalled && (!m_cyc || {m_we, m_adr, m_dat_o, m_sel} !== packet))
                $fatal(1, "held master packet changed");
            stalled = m_cyc && !m_ack;
            packet = {m_we, m_adr, m_dat_o, m_sel};
            if (m_ack) begin
                words = words + 1;
                if (m_we) begin
                    bytes = total - written;
                    if (bytes > dw) bytes = dw;
                    if (bytes <= 0) $fatal(1, "write exceeded byte budget case=%0d", cases);
                    logical_addr = da + (di ? written : 0);
                    mask = ((1 << bytes) - 1) << (logical_addr % 4);
                    data = 0;
                    for (i = 0; i < bytes; i = i + 1)
                        data[((logical_addr % 4)+i)*8 +: 8] = stream[written+i];
                    if (m_adr !== (logical_addr & 32'hfffffffc) || m_sel !== mask[3:0])
                        $fatal(1, "write packet extent case=%0d byte=%0d", cases, written);
                    for (i = 0; i < 4; i = i + 1)
                        if (m_sel[i] && m_dat_o[i*8 +: 8] !== data[i*8 +: 8])
                            $fatal(1, "write byte mismatch case=%0d byte=%0d", cases, written+i);
                    if (written + bytes > read_total) $fatal(1, "write consumed unread bytes");
                    if (kind != 1 && kind != 3)
                        for (i = 0; i < 4; i = i + 1)
                            if (m_sel[i]) memory[m_adr+i] = m_dat_o[i*8 +: 8];
                    written = written + bytes;
                end else begin
                    bytes = total - read_total;
                    if (bytes > sw) bytes = sw;
                    if (bytes <= 0) $fatal(1, "read exceeded byte budget case=%0d", cases);
                    logical_addr = sa + (si ? read_total : 0);
                    mask = ((1 << bytes) - 1) << (logical_addr % 4);
                    if (m_adr !== (logical_addr & 32'hfffffffc) || m_sel !== mask[3:0])
                        $fatal(1, "read packet extent case=%0d byte=%0d gotmask=%h expected=%h",
                               cases, read_total, m_sel, mask[3:0]);
                    read_total = read_total + bytes;
                end
            end
        end
    end

    task reg_write;
        input [11:0] address;
        input [31:0] value;
        begin
            @(negedge clk);
            off = address;
            wdata = value;
            wr = 1;
            acc = 1;
            @(negedge clk);
            wr = 0;
            acc = 0;
        end
    endtask

    // Unit count is deliberately independent of the memory access width.
    // control 1 counts halfwords. control 2 counts the fixed peripheral side.
    task run_case;
        input integer source_width, destination_width, units, control;
        input source_inc, destination_inc;
        input integer source_lane, destination_lane, fifo_kind;
        integer n, b, target, timeout_count;
        begin
            cases = cases + 1;
            sw = source_width;
            dw = destination_width;
            si = source_inc;
            di = destination_inc;
            kind = fifo_kind;
            sa = fifo_kind == 2 ? MMC_FIFO : 256 + source_lane;
            da = fifo_kind == 1 ? MMC_FIFO : fifo_kind == 3 ? LCD_FIFO : 2048 + destination_lane;
            total = units * (control == 1 ? 2 : di ? sw : dw);
            read_total = 0;
            written = 0;
            for (n = 0; n < 4096; n = n + 1) begin
                memory[n] = (n * 29 + cases * 13 + n / 7) % 256;
                expected[n] = memory[n];
            end
            for (n = 0; n < total; n = n + 1)
                stream[n] = fifo_kind == 2 ? (n * 17 + 8'h35) % 256 :
                            memory[sa + (si ? n : n % sw)];
            if (fifo_kind != 1 && fifo_kind != 3)
                for (n = 0; n < total; n = n + dw)
                    for (b = 0; b < dw && n+b < total; b = b + 1) begin
                        target = da + (di ? n : 0) + b;
                        expected[target] = stream[n+b];
                    end
            reg_write(12'h304, 1);
            reg_write(12'h314, sa);
            reg_write(12'h318, si ? 4 : 0);
            reg_write(12'h31c, sw * 8);
            reg_write(12'h320, da == MMC_FIFO ? 32'h10120624 : da == LCD_FIFO ? 32'h10121208 : da);
            reg_write(12'h324, di ? 4 : 0);
            reg_write(12'h328, dw * 8);
            reg_write(12'h32c, units - 1);
            reg_write(12'h308, control);
            timeout_count = 0;
            while (!irq[0]) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 100000) $fatal(1, "completion timeout case=%0d", cases);
            end
            if (read_total != total || written != total || m_cyc)
                $fatal(1, "incomplete success case=%0d moved=%0d/%0d expected=%0d", cases, read_total, written, total);
            for (n = 0; n < 4096; n = n + 1)
                if (memory[n] !== expected[n]) $fatal(1, "memory guard mismatch case=%0d byte=%0d", cases, n);
            reg_write(12'h308, 0);
            reg_write(12'h304, 0);
            if (irq[0]) $fatal(1, "IRQ did not clear");
        end
    endtask
    integer selected = 0, s, d, count, mode, sl, dl;
    initial begin
        if (!$value$plusargs("case=%d", selected)) selected = 0;
        repeat (4) @(negedge clk);
        reset = 0;
        if (selected == 0 || selected == 1) run_case(4, 4, 5, 1, 1, 1, 0, 0, 0);
        if (selected == 0 || selected == 2) run_case(4, 1, 512, 2, 1, 0, 0, 0, 1);
        if (selected == 0 || selected == 3) run_case(1, 4, 10, 2, 0, 1, 0, 0, 2);
        if (selected == 0 || selected == 4) run_case(4, 4, 7, 2, 1, 0, 0, 0, 3);
        if (selected == 0) begin
            for (s = 1; s <= 4; s = s * 2)
                for (d = 1; d <= 4; d = d * 2)
                    for (count = 1; count <= 9; count = count + 1)
                        for (sl = 0; sl < 4; sl = sl + s)
                            for (dl = 0; dl < 4; dl = dl + d) begin
                                for (mode = 0; mode < 4; mode = mode + 1)
                                    run_case(s, d, count, 1, mode[0], mode[1], sl, dl, 0);
                                run_case(s, d, count, 2, 1, 0, sl, dl, 0);
                                run_case(s, d, count, 2, 0, 1, sl, dl, 0);
                            end
        end
        $display("PASS donor DMA count: %0d cases, %0d words", cases, words);
        $finish;
    end
endmodule
