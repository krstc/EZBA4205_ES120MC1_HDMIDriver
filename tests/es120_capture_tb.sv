`timescale 1ns/1ps
module es120_capture_tb #(parameter RECOVERY=0,NATIVE=0);
    localparam H=2560, V=1600, INPUT_H=NATIVE?2560:2650, CROP=NATIVE?0:45;
    reg clk=0, pix=0, rst=0, start=0;
    always #10 clk=~clk;
    // Advertised HDMI clock, with the real 160-pixel horizontal blanking.
    always #(NATIVE?4.467:4.324) pix=~pix;
    reg de=0, vs=1;
    reg [7:0] gray=0;
    wire cropped_de,cropped_hs,cropped_vs;
    wire [7:0] cropped_gray;
    hdmi_input_es120mc1 #(.INPUT_H(INPUT_H),.FRAME_H(H),.FRAME_V(V),.NATIVE_GC16(NATIVE)) input_path(
        .pix_clk(pix),.rst_n(rst),.de_i(de),.hs_i(1'b1),.vs_i(vs),.gray_i(gray),
        .gray_de(cropped_de),.gray_hs(cropped_hs),.gray_vs(cropped_vs),
        .gray_data(cropped_gray),.video_valid(),.native_refine(NATIVE),.mode_notice(2'b0));
    wire [63:0] gray_out, new_out, drive_out;
    reg [63:0] old_data;
    wire gray_req, drive_req, ren, fifo_empty, gray_done, drive_done, gray_busy;
    wire [31:0] gray_addr, drive_addr;
    wire [15:0] gray_size, drive_size;
    reg gb=0, gv=0, db=0, dv=0;
    wire grdy, drdy;
    integer gy=0, dy=0, gc=0, dc=0, consumed=0, tick_count=0, completed=0;
    integer rendered_frame=0, capture_completions=0;
    reg stall=0;
    function automatic [7:0] pixel(input integer f,y,x);
        pixel = (((x+CROP)*37 + y*19 + f*67) % 256);
    endfunction
    function automatic [7:0] stored(input integer f,y,x);
        stored=NATIVE?((int'(pixel(f,y,x))+8)/17)*17:pixel(f,y,x);
    endfunction
    function automatic [1:0] code(input integer f,y,x);
        reg [7:0] n,o;
        begin
            n=pixel(f,y,x); o=(f==0) ? 255 : pixel(f-1,y,x);
            code=(n[7]==o[7]) ? 0 : (n[7] ? 2 : 1);
        end
    endfunction
    always_comb for(integer i=0;i<8;i=i+1)
        old_data[i*8+:8]=(consumed/(H/8*V)==0) ? 255 :
            stored(consumed/(H/8*V)-1,(consumed/(H/8))%V,(consumed%(H/8))*8+i);
    fdma_w_gray #(.MAX_H(H),.FRAME_H(H),.FRAME_V(V),.SAFE_CAPTURE(1)) capture(
        .clk(clk),.rst_n(rst),.pix_rst_n(rst),.fdma_wflag(start),.pix_clk(pix),
        .gray_data(cropped_gray),.gray_vs(cropped_vs),.gray_hs(cropped_hs),.gray_de(cropped_de),.buf_addr(32'h100000),
        .fdma_waddr(gray_addr),.fdma_wareq(gray_req),.fdma_wbusy(gb),.fdma_wdata(gray_out),
        .fdma_wready(grdy),.fdma_wsize(gray_size),.fdma_wvalid(gv),.wbusy(gray_busy),.fflag(gray_done),
        .fifo_ren(ren),.fifo_out(new_out),.fifo_full(),.fifo_empty(fifo_empty));
    generate if(NATIVE) begin
    fdma_w_gc16_es120mc1 #(.MAX_H(H),.FRAME_H(H),.FRAME_V(V)) convert(
        .clk(clk),.rst_n(rst),.newFrame_fifo_empty(fifo_empty),
        .clear_history(start),.changed_pixels(),.recovery_tile(14'd0),.recovery_dirty(),
        .oldFrame_fifo_empty(stall),.gray_ren(ren),.newFrame(new_out),.oldFrame(old_data),
        .buf_addr(32'h200000),.fdma_waddr(drive_addr),.fdma_wareq(drive_req),
        .fdma_wbusy(db),.fdma_wdata(drive_out),.fdma_wready(drdy),.fdma_wsize(drive_size),
        .fdma_wvalid(dv),.wbusy(),.fflag(drive_done));
    end else begin
    fdma_w_mono_es120mc1 #(.MAX_H(H),.FRAME_H(H),.FRAME_V(V),.LOCAL_RECOVERY(RECOVERY)) convert(
        .clk(clk),.rst_n(rst),.newFrame_fifo_empty(fifo_empty),
        .clear_history(start),.changed_pixels(),
        .oldFrame_fifo_empty(stall),.texture_fifo_empty(stall),.gray_ren(ren),
        .newFrame(new_out),.oldFrame(old_data),.texture(64'd0),.buf_addr(32'h200000),
        .fdma_waddr(drive_addr),.fdma_wareq(drive_req),.fdma_wbusy(db),.fdma_wdata(drive_out),
        .fdma_wready(drdy),.fdma_wsize(drive_size),.fdma_wvalid(dv),.wbusy(),.fflag(drive_done));
    end endgenerate
    reg [7:0] target_gray,old_gray;
    always @(posedge clk) if(rst) begin
        if(ren) begin
            if($isunknown(new_out) || $isunknown(old_data)) $fatal(1,"unknown FIFO word before conversion index=%0d",consumed);
            consumed <= consumed+1;
        end
        if(gv) begin
            for(integer i=0;i<8;i=i+1)
                if(gray_out[i*8+:8] !== stored(gy/V,gy%V,gc*8+i))
                    $fatal(1,"gray row=%0d pixel=%0d got=%h",gy,gc*8+i,gray_out[i*8+:8]);
            gc=gc+1;
        end
        if(dv) begin
            if(NATIVE) begin
                for(integer i=0;i<8;i=i+1) begin
                    target_gray=stored(dy/V,dy%V,dc*8+i);
                    old_gray=dy<V ? 255:stored(dy/V-1,dy%V,dc*8+i);
                    if(drive_out[i*8+:8]!=={target_gray[7:4],old_gray[7:4]})
                        $fatal(1,"GC16 transition row=%0d pixel=%0d got=%h expected=%h",dy,dc*8+i,drive_out[i*8+:8],{target_gray[7:4],old_gray[7:4]});
                end
            end else for(integer i=0;i<32;i=i+1)
                if(((RECOVERY && drive_out[i*2+:2] == 3) ? 2'b00 : drive_out[i*2+:2]) !== code(dy/V,dy%V,dc*32+i))
                    $fatal(1,"DU row=%0d pixel=%0d got=%h expected=%h",dy,dc*32+i,drive_out[i*2+:2],code(dy/V,dy%V,dc*32+i));
            dc=dc+1;
        end
        if(gray_done) capture_completions=capture_completions+1;
        if(drive_done) completed=completed+1;
    end
    always @(negedge clk) if(rst) begin
        tick_count=tick_count+1;
        stall=(tick_count%7==0);
        gv=0; dv=0;
        if(!gb && gray_req) begin
            if(gray_size!=320 || gray_addr!=32'h100000+(gy%V)*H) $fatal(1,"gray DMA size/stride");
            gb=1; gc=0;
        end else if(gb) begin
            if(gc==320) begin gb=0; gy=gy+1; end
            else gv=(tick_count%5!=0);
        end
        if(!db && drive_req) begin
            if(drive_size!=(NATIVE?320:80) || drive_addr!=32'h200000+(dy%V)*(NATIVE?H:H/4)) $fatal(1,"drive DMA size/stride");
            db=1; dc=0;
        end else if(db) begin
            if(dc==(NATIVE?320:80)) begin db=0; dy=dy+1; end
            else dv=drdy && tick_count%3!=0;
        end
    end
    initial begin
        #1000; rst=1; repeat(100) @(negedge clk);
        for(integer f=0;f<2;f=f+1) begin
            start=1; @(negedge clk); start=0;
            repeat(30) @(negedge pix);
            vs=0; repeat(100) @(negedge pix); vs=1;
            repeat(300) @(negedge pix);
            for(integer y=0;y<V;y=y+1) begin
                for(integer x=0;x<INPUT_H;x=x+1) begin
                    de=1; gray=pixel(f,y,x-CROP); @(negedge pix);
                end
                de=0; repeat(160) @(negedge pix);
            end
            wait(completed==(f+1)*V && capture_completions==f+1);
            repeat(100) @(negedge clk);
        end
        if(consumed!=2*V*320) $fatal(1,"incorrect gray consume count");
        $display("PASS capture: two full %0dx1600 inputs, 8192000 exact DDR pixels and transitions, DMA stalls, native=%0d recovery=%0d",INPUT_H,NATIVE,RECOVERY);
        $finish;
    end
    initial begin #150000000; $fatal(1,"capture timeout rows=%0d completed=%0d captures=%0d",gy,completed,capture_completions); end
endmodule
