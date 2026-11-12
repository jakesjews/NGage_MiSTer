`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, acc = 0, wr = 0;
    reg [11:0] off = 0;
    reg [31:0] wdata = 0;
    wire [7:0] irq;
    wire m_cyc, m_stb, m_we;
    wire [31:0] m_adr, m_dat_o;
    wire [3:0] m_sel;
    reg ack_enable = 1;
    reg [31:0] reads = 0;
    wire m_ack = m_cyc && ack_enable;
    wire [31:0] m_dat_i = m_adr ^ 32'h12345678;
    wire valid, ready;
    wire [31:0] data;
    wire fifo_ready;
    reg block_native = 0;
    reg lacc = 0, lwe = 1, lwr = 0, lrd = 0;
    reg [3:0] loff = 0;
    reg [31:0] lwdata = 0;
    wire [31:0] lmask, lrdata;
    wire busy, wrx, dcx;
    wire [7:0] dout;
    reg old_wrx = 1;
    integer native_words = 0, generic_lcd = 0, pin_bytes = 0;
    integer cycles = 0;
    reg fallback_commit = 0;
    reg [31:0] fallback_data;
    // Generic fallback emulates the bus' full-word LCD write completion.
    wire fallback = m_ack && m_we && m_adr == 32'h0c121208 && m_sel == 15;
    assign ready = fifo_ready && !block_native;
    upp_dma #(.ENGINES(2)) dma (
        .clk(clk), .reset(reset), .acc(acc), .wr(wr), .off(off), .wdata(wdata),
        .irq(irq), .rmask(), .rdata(), .mmc_rx_ready(1'b0), .mmc_tx_ready(1'b0),
        .lcd_tx_ready(1'b1), .lcd_valid(valid), .lcd_data(data), .lcd_ready(ready),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr),
        .m_dat_o(m_dat_o), .m_sel(m_sel), .m_ack(m_ack), .m_err(1'b0), .m_dat_i(m_dat_i)
    );
    upp_lcdif #(.QAW(2)) lcd (
        .clk(clk), .reset(reset), .acc(lacc || fallback_commit), .we(lwe),
        .wr(lwr || fallback_commit), .rd(lrd), .off(fallback_commit ? 4'h8 : loff),
        .wdata(fallback_commit ? fallback_data : lwdata), .rmask(lmask), .rdata(lrdata),
        .busy(busy), .dma_valid(valid && !block_native), .dma_data(data),
        .dma_ready(fifo_ready), .tx_ready(), .active(), .csx(), .dcx(dcx), .wrx(wrx),
        .rdx(), .resx(), .d_o(dout), .d_oe(), .d_i(8'h5a)
    );
    reg [31:0] first_source = 32'h0a000100;
    reg check_pixels = 0;
    reg [31:0] expected_word;
    reg [7:0] expected_byte;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        old_wrx <= wrx;
        fallback_commit <= fallback;
        if (fallback) begin fallback_data <= m_dat_o; generic_lcd <= generic_lcd + 1; end
        if (!reset) begin
            if (m_ack && !m_we) reads <= reads + 1;
            if (valid && ready) native_words <= native_words + 1;
            if (!old_wrx && wrx && dcx && check_pixels) begin
                expected_word = (first_source + (pin_bytes / 4) * 4) ^ 32'h12345678;
                expected_byte = expected_word >> ((pin_bytes % 4) * 8);
                if (dout !== expected_byte) $fatal(1, "panel byte %0d got %h expected %h", pin_bytes, dout, expected_byte);
                pin_bytes <= pin_bytes + 1;
            end
        end
        if (cycles > 30000) $fatal(1, "watchdog");
    end
    task regwrite;
        input [11:0] address;
        input [31:0] value;
        begin
            @(negedge clk); acc=1; wr=1; off=address; wdata=value;
            @(negedge clk); acc=0; wr=0;
        end
    endtask
    task lcdwrite;
        input [3:0] address;
        input [31:0] value;
        begin
            @(negedge clk); lacc=1; lwe=1; loff=address; lwdata=value;
            repeat (2) @(negedge clk);
            while (busy) @(negedge clk);
            lwr=1;
            @(negedge clk); lwr=0; lacc=0;
        end
    endtask
    task setup;
        input integer channel;
        input [31:0] source, destination, count, control;
        reg [11:0] base;
        begin
            base = 12'h300 + channel*64;
            regwrite(base+4,0);
            regwrite(base+20,source);
            regwrite(base+24,4);
            regwrite(base+28,32);
            regwrite(base+32,destination);
            regwrite(base+36,0);
            regwrite(base+40,32);
            regwrite(base+44,count-1);
            regwrite(base+8,control);
        end
    endtask
    integer before_words, before_reads, before_generic, channel;
    reg [31:0] held;
    initial begin
        repeat (4) @(negedge clk); reset=0;
        // Four-byte packing: exact pin bytes despite FIFO backpressure.
        lcdwrite(0,32'h092c009f); // 160 bytes
        check_pixels=1;
        setup(0,first_source,32'h10121208,40,2);
        wait (irq[0]);
        @(negedge clk);
        if (native_words != 40 || reads != 40 || generic_lcd != 0)
            $fatal(1,"native transfer counts %0d/%0d/%0d",native_words,reads,generic_lcd);
        wait (pin_bytes==160); repeat (4) @(negedge clk);
        if (pin_bytes != 160) $fatal(1,"duplicate panel bytes");
        check_pixels=0;
        loff=8; lacc=1; lwe=0;
        #1;
        if (lmask !== 32'hffffffff || lrdata !== ((first_source+156)^32'h12345678))
            $fatal(1,"native FIFO readback lost");
        @(negedge clk); lacc=0; lwe=1;
        // The fast reader is selected by descriptor, on every channel.
        for (channel=0; channel<8; channel=channel+1) begin
            before_words=native_words;
            setup(channel,first_source,32'h10121208,1,2);
            wait(irq[channel]); @(negedge clk);
            if(native_words!=before_words+1) $fatal(1,"channel routing %0d",channel);
        end
        // Unsupported source falls back to the generic worker.
        before_generic=generic_lcd;
        setup(0,32'h00000100,32'h10121208,1,2);
        wait (irq[0]); repeat (3) @(negedge clk);
        if (generic_lcd != before_generic+1) $fatal(1,"fallback missing");
        // CPU selection reserves FIFO admission before its write strobe.
        lacc=1; block_native=1;
        setup(0,first_source,32'h10121208,2,2);
        wait(valid); @(negedge clk); block_native=0;
        repeat (4) begin @(negedge clk); if(ready) $fatal(1,"CPU reservation ignored"); end
        // Stop drops held unaccepted data and cannot complete with IRQ.
        before_words=native_words;
        regwrite(12'h308,0);
        lacc=0;
        repeat(30) @(negedge clk);
        if (irq[0] || native_words!=before_words) $fatal(1,"stop emitted data/IRQ");
        // Stop/restart while a read is held: old response drains, then new src.
        ack_enable=0;
        setup(0,first_source,32'h10121208,3,2);
        wait(m_cyc); @(negedge clk); held=m_adr;
        regwrite(12'h308,0);
        setup(0,32'h0a000800,32'h10121208,1,2);
        repeat(4) begin @(negedge clk); if(!m_cyc || m_adr!==held) $fatal(1,"read changed on cancellation"); end
        before_words=native_words;
        ack_enable=1;
        wait(irq[0]); @(negedge clk);
        if(native_words!=before_words+1 || data!==(32'h0a000800^32'h12345678))
            $fatal(1,"restart consumed old response");
        for(channel=0; channel<8; channel=channel+1) regwrite(12'h304+channel*64,0);
        // Two stalled MMC workers must not stop LCD admission/completion.
        setup(1,first_source,32'h10120624,4,2);
        setup(2,first_source,32'h10120624,4,2);
        repeat(20) @(negedge clk);
        before_words=native_words;
        // An unsupported descriptor waiting for a general worker must not
        // prevent a later channel from reaching the independent LCD slot.
        setup(0,first_source,32'h0a000400,4,1);
        setup(7,first_source,32'h10121208,7,2);
        wait(irq[7]); @(negedge clk);
        if(native_words!=before_words+7 || irq[1] || irq[2]) $fatal(1,"LCD/general ownership");
        // Reset retracts local valid and drops ownership.
        block_native=1;
        setup(7,first_source,32'h10121208,2,2);
        wait(valid); @(negedge clk); reset=1;
        #1; if(valid) $fatal(1,"valid during reset");
        repeat(3) @(negedge clk); reset=0; block_native=0;
        before_words=native_words;
        repeat(30) @(negedge clk);
        if(irq || m_cyc || native_words!=before_words) $fatal(1,"reset leaked state");
        $display("PASS LCD native reader: ordered bytes, fallback, readback, CPU priority, stop/restart, blocked workers, reset");
        $finish;
    end
endmodule
