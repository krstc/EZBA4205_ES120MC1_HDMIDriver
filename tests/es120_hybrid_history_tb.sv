`timescale 1ns/1ps
module es120_hybrid_history_tb;
    localparam H=2560,V=1600,WORDS=320,N=H*V;
    reg clk=0,rst=0,feeding=0,fast=0,refine=0,clear_band=0;
    reg [11:0] band=0;
    always #10 clk=~clk;
    reg [7:0] desired[0:N-1],source_old[0:N-1],physical[0:N-1];
    reg [7:0] reference[0:N-1];
    reg [63:0] n,o,s;
    wire ren,req,ready,done,dirty;
    wire [31:0] addr;
    wire [15:0] size;
    wire [63:0] data;
    wire [22:0] changes,drives,pending;
    reg busy=0,valid=0;
    reg [13:0] query=0;
    integer inword=0,outword=0,row=0,rows=0,ticks=0,expected_changes,expected_pending;
    integer cycles=0;
    always_comb for(integer i=0;i<8;i=i+1) begin
        n[8*i+:8]=desired[(inword*8+i)%N];
        o[8*i+:8]=source_old[(inword*8+i)%N];
        s[8*i+:8]={physical[(inword*8+i)%N][3:0],4'h0};
    end
    fdma_w_gc16_es120mc1 #(.HYBRID_REFRESH(1)) dut (
        .clk(clk),.rst_n(rst),.clear_history(1'b0),.changed_pixels(changes),
        .fast_update(fast),.refine_update(refine),.refine_y(band),.clear_band(clear_band),
        .state_fifo_empty(ticks%13==0),.panel_state(s),.drive_pixels(drives),.pending_pixels(pending),
        .newFrame_fifo_empty(!feeding || inword==WORDS*V || ticks%7==0),
        .oldFrame_fifo_empty(ticks%11==0),.gray_ren(ren),.newFrame(n),.oldFrame(o),
        .recovery_tile(query),.recovery_dirty(dirty),.buf_addr(32'he800000),
        .fdma_waddr(addr),.fdma_wareq(req),.fdma_wbusy(busy),.fdma_wdata(data),
        .fdma_wready(ready),.fdma_wsize(size),.fdma_wvalid(valid),.wbusy(),.fflag(done));
    always @(posedge clk) if(rst) begin
        if(ren) inword<=inword+1;
        if(done) rows<=rows+1;
        if(valid) begin
            for(integer i=0;i<8;i=i+1) begin
                if(data[8*i+:8]!==reference[row*H+outword*8+i])
                    $fatal(1,"hybrid actual-state transition y=%0d x=%0d got=%h want=%h",
                        row,outword*8+i,data[8*i+:8],reference[row*H+outword*8+i]);
                physical[row*H+outword*8+i]={4'h0,data[8*i+4+:4]};
            end
            outword=outword+1;
        end
    end
    always @(negedge clk) if(rst) begin
        ticks=ticks+1;valid=0;
        if(!busy && req) begin
            if(size!=320 || addr!=32'he800000+row*2560) $fatal(1,"hybrid history DMA stride");
            busy=1;outword=0;
        end else if(busy) begin
            if(outword==320) begin busy=0;row=row+1;end
            else valid=ready && ticks%5!=0;
        end
    end
    task capture_frame(input bit f,input bit r,input integer by);
        reg [3:0] target;
        begin
            @(negedge clk);fast=f;refine=r;band=by;
            expected_changes=0;expected_pending=0;
            for(integer p=0;p<N;p=p+1) begin
                target=desired[p][7:4];
                if(desired[p]!=source_old[p]) expected_changes++;
                if(f || (r && (p/H<by || p/H>=by+128))) begin
                    if(desired[p]!=source_old[p]) target=desired[p][7]?15:0;
                    else target=physical[p][3:0];
                end
                if(target!=desired[p][7:4]) expected_pending++;
                reference[p]={target,physical[p][3:0]};
            end
            row=0;inword=0;rows=0;feeding=1;
            wait(rows==V);@(negedge clk);feeding=0;
            if(changes!=expected_changes || pending!=expected_pending)
                $fatal(1,"hybrid metrics changes=%0d/%0d pending=%0d/%0d",changes,expected_changes,pending,expected_pending);
            for(integer p=0;p<N;p=p+1) source_old[p]=desired[p];
            cycles++;
        end
    endtask
    task consume_band(input integer by);
        @(negedge clk);band=by;clear_band=1;
        @(negedge clk);clear_band=0;repeat(1050) @(negedge clk);
    endtask
    initial begin
        for(integer p=0;p<N;p=p+1) begin
            desired[p]=8'hff;source_old[p]=8'hff;physical[p]=15;
        end
        #100;rst=1;repeat(1050) @(negedge clk);
        desired[0]=8'h66;desired[H*129]=8'h99;desired[N-1]=8'h33;
        capture_frame(0,0,0); // A prior native image, including bottom-right.
        for(integer p=0;p<N;p=p+1) desired[p]=source_old[p];
        desired[H*129]=8'h22;desired[N-1]=8'hbb;
        capture_frame(1,0,0);
        if(physical[0]!=6 || physical[H*129]!=0 || physical[N-1]!=15)
            $fatal(1,"fast update changed static native gray or lost endpoints");
        capture_frame(1,0,0);
        if(drives!=0) $fatal(1,"identical coarse frame was repeatedly driven");
        // Refine one band while NEW scrolling arrives outside it.
        desired[10]=8'h44;
        capture_frame(0,1,128);
        if(physical[10]!=0 || physical[H*129]!=2 || physical[N-1]!=15)
            $fatal(1,"partial refinement lost a new outside-band input change");
        consume_band(128);
        query=0;#1;if(!dirty) $fatal(1,"cleared unrelated top history");
        query=80*8;#1;if(dirty) $fatal(1,"consumed band history retained");
        query=7999;#1;if(!dirty) $fatal(1,"cleared bottom history too soon");
        capture_frame(0,1,1536);consume_band(1536);
        if(physical[N-1]!=11) $fatal(1,"last partial band missing");
        capture_frame(0,1,0);consume_band(0);
        capture_frame(1,0,0);
        if(drives || pending) $fatal(1,"refined static image regressed to binary");
        // Scrolled black text becomes white; keep a local recharge debt.
        desired[10]=8'hff;capture_frame(1,0,0);capture_frame(0,1,0);
        if(drives==0) $fatal(1,"stable white in scrolled tile not recharged");
        consume_band(0);capture_frame(0,1,0);
        if(drives!=0) $fatal(1,"white repair repeats after debt consumed");
        $display("PASS hybrid history: %0d full 2560x1600 frames, actual panel states, static gray held, mixed fast/refine, bottom edge, partial history consumption, one-shot white recharge",cycles);
        $finish;
    end
    initial begin #900000000;$fatal(1,"hybrid history timeout");end
endmodule
