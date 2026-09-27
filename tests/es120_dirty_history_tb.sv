`timescale 1ns/1ps
module es120_dirty_history_tb;
    localparam H=2560, V=1600, WORDS=H/8;
    reg clk=0, rst=0, clear_history=0, feeding=0;
    always #10 clk=~clk;
    wire ren, req, ready, done;
    wire [31:0] addr;
    wire [15:0] size;
    wire [63:0] drive;
    wire [22:0] changed_pixels;
    reg [63:0] n, o;
    reg busy=0, valid=0;
    integer frame=0, input_word=0, output_word=0, row=0, rows_done=0, ticks=0;
    function automatic bit pixel(input integer f, y, x);
        if(f<0) pixel=1;
        else if(f==0) pixel=!(y<4 && x<16);
        else if(f==4) pixel=!(y<4 && x>=40 && x<56) && !(y==V-1 && x==H-1);
        else pixel=!(y<4 && x>=40 && x<56);
    endfunction
    function automatic [1:0] expected(input integer f,y,x);
        if(pixel(f,y,x)!=pixel(f-1,y,x)) expected=pixel(f,y,x) ? 2:1;
        else if(f==2 && y<16 && x<64 && pixel(f,y,x)) expected=3;
        else if(f==6 && y>=V-16 && x>=H-32 && pixel(f,y,x)) expected=3;
        else expected=0;
    endfunction
    always_comb begin
        for(integer i=0;i<8;i=i+1) begin
            n[i*8+:8]=pixel(frame,input_word/WORDS,(input_word%WORDS)*8+i) ? 255:0;
            o[i*8+:8]=pixel(frame-1,input_word/WORDS,(input_word%WORDS)*8+i) ? 255:0;
        end
    end
    fdma_w_mono_es120mc1 #(.MAX_H(H),.FRAME_H(H),.FRAME_V(V),.LOCAL_RECOVERY(1)) dut(
        .clk(clk),.rst_n(rst),.clear_history(clear_history),.changed_pixels(changed_pixels),
        .newFrame_fifo_empty(!feeding || input_word==WORDS*V || ticks%7==0),
        .oldFrame_fifo_empty(ticks%11==0),.texture_fifo_empty(1'b0),
        .gray_ren(ren),.newFrame(n),.oldFrame(o),.texture(64'd0),.buf_addr(32'h200000),
        .fdma_waddr(addr),.fdma_wareq(req),.fdma_wbusy(busy),.fdma_wdata(drive),
        .fdma_wready(ready),.fdma_wsize(size),.fdma_wvalid(valid),.wbusy(),.fflag(done));
    always @(posedge clk) if(rst) begin
        if(ren) input_word<=input_word+1;
        if(done) rows_done<=rows_done+1;
        if(valid) begin
            // Frames 0/1 include freshly dirtied tiles while being collected;
            // test exact transitions there and exhaustive masks on stable frames.
            for(integer i=0;i<32;i=i+1) begin
                if(frame==0 || frame==1 || frame==5) begin
                    if(pixel(frame,row,output_word*32+i)!=pixel(frame-1,row,output_word*32+i)) begin
                        if(drive[i*2+:2]!==expected(frame,row,output_word*32+i))
                            $fatal(1,"lost transition f=%0d row=%0d x=%0d got=%h expect=%h word=%h",
                                   frame,row,output_word*32+i,drive[i*2+:2],
                                   expected(frame,row,output_word*32+i),drive);
                    end else if(drive[i*2+:2]!==0 && drive[i*2+:2]!==3)
                        $fatal(1,"stable pixel unexpectedly driven");
                end else if(drive[i*2+:2]!==expected(frame,row,output_word*32+i))
                    $fatal(1,"mask f=%0d y=%0d x=%0d got=%0d want=%0d",frame,row,output_word*32+i,
                           drive[i*2+:2],expected(frame,row,output_word*32+i));
            end
            output_word=output_word+1;
        end
    end
    always @(negedge clk) if(rst) begin
        ticks=ticks+1; valid=0;
        if(!busy && req) begin
            if(size!=80 || addr!=32'h200000+row*640) $fatal(1,"DMA size/address");
            busy=1; output_word=0;
        end else if(busy) begin
            if(output_word==80) begin busy=0; row=row+1; end
            else valid=ready && ticks%3!=0;
        end
    end
    initial begin
        #100; rst=1;
        repeat(100) @(negedge clk);
        for(integer f=0;f<7;f=f+1) begin
            @(negedge clk); frame=f; row=0; input_word=0; rows_done=0;
            if(f==3) begin
                clear_history=1; @(negedge clk); clear_history=0;
            end
            feeding=1;
            wait(rows_done==V);
            @(negedge clk); feeding=0;
            if(changed_pixels !== ((f==0)?64:(f==1)?128:(f==4 || f==5)?1:0))
                $fatal(1,"frame metric f=%0d changed=%0d",f,changed_pixels);
            repeat(20) @(negedge clk);
        end
        $display("PASS dirty history: exact whole-frame metrics, scrolling text masks, untouched tiles, clear/consume, last pixel and DMA stalls");
        $finish;
    end
    initial begin #500000000; $fatal(1,"dirty history timeout"); end
endmodule
