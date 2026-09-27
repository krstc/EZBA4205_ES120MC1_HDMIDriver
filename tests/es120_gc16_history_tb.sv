`timescale 1ns/1ps
module es120_gc16_history_tb;
    localparam H=2560,V=1600,WORDS=320;
    reg clk=0,rst=0,clear_history=0,feeding=0;
    always #10 clk=~clk;
    wire ren,req,ready,done,dirty;
    wire [31:0] addr;
    wire [15:0] size;
    wire [63:0] data;
    wire [22:0] changes;
    reg [63:0] n,o;
    reg busy=0,valid=0;
    reg [13:0] query=0;
    integer frame=0,inword=0,outword=0,row=0,rows=0,ticks=0;
    function automatic [3:0] pixel(input integer f,y,x);
        if(f<0) pixel=15;
        else if(y==0 && x==0) pixel=f<2?7:6;
        else if(y==V-1 && x==H-1) pixel=f<2?8:9;
        else pixel=15;
    endfunction
    always_comb for(integer i=0;i<8;i=i+1) begin
        n[8*i+:8]={2{pixel(frame,inword/WORDS,inword%WORDS*8+i)}};
        o[8*i+:8]={2{pixel(frame-1,inword/WORDS,inword%WORDS*8+i)}};
    end
    fdma_w_gc16_es120mc1 dut (
        .clk(clk),.rst_n(rst),.clear_history(clear_history),.changed_pixels(changes),
        .newFrame_fifo_empty(!feeding || inword==WORDS*V || ticks%7==0),
        .oldFrame_fifo_empty(ticks%11==0),.gray_ren(ren),.newFrame(n),.oldFrame(o),
        .recovery_tile(query),.recovery_dirty(dirty),.buf_addr(32'he800000),
        .fdma_waddr(addr),.fdma_wareq(req),.fdma_wbusy(busy),.fdma_wdata(data),
        .fdma_wready(ready),.fdma_wsize(size),.fdma_wvalid(valid),.wbusy(),.fflag(done));
    always @(posedge clk) if(rst) begin
        if(ren) inword<=inword+1;
        if(done) rows<=rows+1;
        if(valid) begin
            for(integer i=0;i<8;i=i+1)
                if(data[8*i+:8]!=={pixel(frame,row,outword*8+i),pixel(frame-1,row,outword*8+i)})
                    $fatal(1,"native transition f=%0d y=%0d x=%0d",frame,row,outword*8+i);
            outword=outword+1;
        end
    end
    always @(negedge clk) if(rst) begin
        ticks=ticks+1;valid=0;
        if(!busy && req) begin
            if(size!=320 || addr!=32'he800000+row*2560) $fatal(1,"native history DMA stride");
            busy=1;outword=0;
        end else if(busy) begin
            if(outword==320) begin busy=0;row=row+1;end
            else valid=ready && ticks%5!=0;
        end
    end
    initial begin
        #100;rst=1;repeat(1050) @(negedge clk);
        for(integer f=0;f<4;f=f+1) begin
            frame=f;row=0;inword=0;rows=0;
            if(f==2 || f==3) begin
                clear_history=1;@(negedge clk);clear_history=0;
                repeat(1050) @(negedge clk);
            end
            feeding=1;wait(rows==V);@(negedge clk);feeding=0;
            if(changes!==((f==0 || f==2)?23'd2:23'd0)) $fatal(1,"4-bit differences lost: %0d",changes);
            for(integer t=0;t<8000;t=t+1) begin
                query=t;#1;
                if(dirty!==((f<3 && (t==0 || t==7999))?1'b1:1'b0))
                    $fatal(1,"dirty query f=%0d tile=%0d got=%b",f,t,dirty);
            end
            @(negedge clk);
        end
        $display("PASS GC16 history: all 8000 tiles, first/last pixels, gray-to-gray changes within same MSB, preserved history, clear and exact metrics");
        $finish;
    end
    initial begin #300000000;$fatal(1,"native history timeout");end
endmodule
