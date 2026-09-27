`timescale 1ns/1ps
module es120_transport_tb;
    reg clk=0, wr_clk=0, rst_n=0, start=0;
    always #34.039 clk=~clk;
    always #10 wr_clk=~wr_clk;
    wire skv, spv, xcl, le, stl, request, done, pop;
    wire [63:0] din;
    wire [15:0] dout;
    reg [63:0] feed;
    reg wr_en=0;
    wire full, empty;
    integer requested=0, requests_seen=0, feed_word=0, fed_rows=0;
    integer samples=0, pops=0, latches=0, rises=0;
    integer row, col, k;
    reg old_le=0, old_skv=0;
    reg [15:0] source_row[0:319];
    function automatic [15:0] expected(input integer row_no, word_no);
        expected = ((row_no*701) ^ (word_no*37) ^ 16'ha735);
    endfunction
    frame_ctrl_es120mc1 timing(.rst_n(rst_n), .epd_clk(clk), .s_flag(start),
        .SKV(skv), .SPV(spv), .XCL(xcl), .XLE(le), .XSTL(stl),
        .r_flag(request), .end_flag(done));
    data_mgr #(.IN_WID(64), .OUT_WID(16), .LINE_DATA_COUNT(320)) serializer(
        .clk(clk), .rst_n(rst_n), .fifo_ren(pop), .din(din), .data_ren(!stl), .dout(dout));
    xpm_fifo_rdata_buf #(.FDMA_WID(64), .EPD_H(2560)) fifo(
        .rst_n(rst_n), .wr_clk(wr_clk), .rd_clk(clk), .din(feed), .wr_en(wr_en),
        .rd_en(pop), .dout(din), .full(full), .empty(empty));
    always @(posedge clk) if(rst_n) begin
        if(request) requested=requested+1;
        if(pop) begin
            if(empty) $fatal(1,"FIFO underflow row %0d", samples/320);
            pops=pops+1;
        end
        if(!stl) begin
            row=samples/320; col=samples%320;
            if(dout !== expected(row,col))
                $fatal(1,"pixel mismatch row=%0d word=%0d got=%h expected=%h",row,col,dout,expected(row,col));
            source_row[col]=dout;
            samples=samples+1;
        end
        if(skv && !old_skv) rises=rises+1;
        if(le && !old_le) begin
            if(samples != (latches+1)*320) $fatal(1,"LE before complete row %0d samples=%0d",latches,samples);
            for(k=0;k<320;k=k+1)
                if(source_row[k] !== expected(latches,k)) $fatal(1,"latched row mismatch");
            latches=latches+1;
        end
        old_le=le; old_skv=skv;
        if(done) begin
            if(samples!=512000 || pops!=128000 || requested!=1600 || latches!=1600)
                $fatal(1,"counts samples=%0d pops=%0d requests=%0d LE=%0d",samples,pops,requested,latches);
            $display("PASS transport: 1600 rows, 512000 ordered 16-bit samples, 128000 FIFO pops, 1600 LE latches");
            $finish;
        end
    end
    // Delayed DDR bursts with bubbles exercise the real asynchronous XPM FIFO.
    always @(negedge wr_clk) begin
        wr_en=0;
        if(rst_n && requests_seen<requested && !full) begin
            if(($time/20)%5 != 0) begin
                for(integer j=0;j<4;j=j+1) feed[16*j+:16]=expected(fed_rows,feed_word*4+j);
                wr_en=1;
                if(feed_word==79) begin feed_word=0; fed_rows=fed_rows+1; requests_seen=requests_seen+1; end
                else feed_word=feed_word+1;
            end
        end
    end
    initial begin
        #1000; rst_n=1;
        repeat(40) @(posedge clk);
        start=1; @(posedge clk); start=0;
        #50000000; $fatal(1,"transport timeout");
    end
endmodule
