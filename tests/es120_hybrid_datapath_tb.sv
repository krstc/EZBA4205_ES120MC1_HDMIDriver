`timescale 1ns/1ps
module es120_hybrid_datapath_tb;
    localparam H=2560,V=1600,N=H*V,WORDS=H/8;
    reg clk=0,pix=0,epd=0,rst=0,cap=0,clear=0,fast=0,refine=0;
    reg vs=0,de=0,scan_start=0;
    reg [11:0] band=0;
    reg [7:0] gray=0;
    always #10 clk=~clk;
    always #4.467 pix=~pix;
    always #11.346154 epd=~epd;
    wire cd,cld,req,pop,stl,scan_done,empty;
    wire [22:0] changed,driven,pending;
    wire [63:0] fifo;
    wire [15:0] pins;
    reg [7:0] source_prev[0:N-1],actual[0:N-1],transitions[0:N-1];
    reg [1:0] lut[0:8191];
    integer scenario=0,reads=0,samples=0,frames=0;
    reg checking=0;
    reg [31:0] latest;
    function automatic [3:0] desired(input integer f,y,x);
        reg [3:0] v;
        begin
            v=(x/23+y/11)%16;
            if(f>=1 && (x%13==0 || y==V-1)) v=(v+7)%16;
            if(f>=3 && y==0 && x==0) v=4'd12;
            desired=v;
        end
    endfunction
    frame_processor #(.EPD_WID(16),.EPD_H(H),.EPD_V(V),.MAX_H(H),.MAX_V(V),
        .FRAME_H(H),.FRAME_V(V),.NATIVE_GC16(1),.HYBRID_REFRESH(1),
        .GRAY_0_ADDR_MEM_OFFSET(32'h0),.GRAY_1_ADDR_MEM_OFFSET(32'h400000),
        .DATA_0_ADDR_MEM_OFFSET(32'h800000),.DATA_1_ADDR_MEM_OFFSET(32'hc00000)) dut (
        .clk(clk),.rst_n(rst),.pix_rst_n(rst),.epd_rst_n(rst),
        .w_gray_s_flag(cap),.pix_clk(pix),.gray_de(de),.gray_hs(1'b0),.gray_vs(vs),.gray_data(gray),
        .w_gray_busy(),.w_gray_fflag(cd),.clr_s_flag(clear),.clear_history(1'b0),
        .changed_pixels(changed),.drive_pixels(driven),.pending_pixels(pending),
        .hybrid_fast(fast),.hybrid_refine(refine),.clear_band(1'b0),.refine_y(band),
        .clr_fflag(cld),.epd_clk(epd),.gc16_phase(8'd1),.gc16_recovery(1'b0),
        // Deliberately never toggle this: skipped captures must not require it.
        .sw_rdata_addr(1'b0),.r_data_flag(req),.r_data_fifo_ren(pop),.r_data_fifo_out(fifo),
        .CLK_50M(),.GPIO_O(),.dma_idle());
    frame_ctrl_es120mc1 #(.EPD_V(V)) timing (
        .rst_n(rst),.epd_clk(epd),.s_flag(scan_start),.SKV(),.SPV(),.XCL(),
        .XLE(),.XSTL(stl),.r_flag(req),.end_flag(scan_done));
    data_mgr #(.IN_WID(64),.OUT_WID(16),.LINE_DATA_COUNT(320)) serializer (
        .clk(epd),.rst_n(rst),.fifo_ren(pop),.din(fifo),.data_ren(!stl),.dout(pins));
    task capture(input integer f,input bit fmode,input bit rmode,input integer by);
        reg [3:0] d,t;
        reg [63:0] got;
        integer src_changes,gray_pending;
        begin
            scenario=f;fast=fmode;refine=rmode;band=by;
            $display("PROGRESS capture %0d: fast=%0d refine=%0d at %0t",frames,fmode,rmode,$time);
            src_changes=0;gray_pending=0;
            for(integer p=0;p<N;p++) begin
                d=desired(f,p/H,p%H);t=d;
                if(d!=source_prev[p]) src_changes++;
                if(fmode || (rmode && (p/H<by || p/H>=by+128)))
                    t=d!=source_prev[p]?(d[3]?15:0):actual[p][3:0];
                transitions[p]={t,actual[p][3:0]};
                if(t!=d) gray_pending++;
            end
            @(negedge clk);cap=1;@(negedge clk);cap=0;
            repeat(30) @(negedge pix);
            vs=1;repeat(100) @(negedge pix);vs=0;
            repeat(300) @(negedge pix);
            for(integer y=0;y<V;y++) begin
                for(integer x=0;x<H;x++) begin
                    de=1;gray={2{desired(f,y,x)}};@(negedge pix);
                end
                de=0;repeat(160) @(negedge pix);
            end
            wait(cd);repeat(12) @(negedge clk);
            latest=(frames%2==0)?32'h800000:32'hc00000;
            if(dut.panel_state_addr!==latest) $fatal(1,"commit buffer mismatch");
            for(integer w=0;w<N/8;w++) begin
                got=dut.ps_system.mem[dut.ps_system.index(latest+w*8)];
                for(integer i=0;i<8;i++) begin
                    if(got[8*i+:8]!==transitions[w*8+i])
                        $fatal(1,"integration f=%0d pixel=%0d got=%h want=%h",f,w*8+i,got[8*i+:8],transitions[w*8+i]);
                    actual[w*8+i]=got[8*i+4+:4];
                    source_prev[w*8+i]=desired(f,(w*8+i)/H,(w*8+i)%H);
                end
            end
            if(changed!=src_changes || pending!=gray_pending) $fatal(1,"integrated capture metrics");
            frames++;
            $display("PROGRESS capture committed: frames=%0d changed=%0d driven=%0d pending=%0d at %0t",frames,changed,driven,pending,$time);
        end
    endtask
    function automatic [1:0] expected(input integer p);
        reg [7:0] tr;
        begin
            tr=transitions[p];expected=0;
            if(fast || (refine && (p/H<band || p/H>=band+128))) begin
                if(tr[7:4]!=tr[3:0]) expected=tr[7:4]==15?2:1;
            end else if(refine && tr==8'hff) expected=2;
            else if(tr[7:4]!=tr[3:0]) expected=lut[tr];
        end
    endfunction
    always @(posedge clk) if(rst) begin
        if(dut.gray_ren && (dut.texture_fifo_empty || dut.oldFrame_fifo_empty))
            $fatal(1,"integration consumed empty history FIFO");
    end
    always @(posedge dut.data_fdma_rbusy) if(rst && checking) begin
        if(dut.data_fdma_raddr!=latest+reads*H) $fatal(1,"display read stale buffer after skipped capture");
        reads++;
    end
    always @(posedge epd) if(rst && checking) begin
        if(pop && dut.r_data_fifo_empty) $fatal(1,"integrated output underflow");
        if(!stl) begin
            for(integer i=0;i<8;i++)
                if(pins[2*i+:2]!==expected(samples*8+i))
                    $fatal(1,"integrated pin code pixel=%0d",samples*8+i);
            samples++;
        end
    end
    initial begin
        $readmemh("../../hdmi_native_gc16_20260920/gc16_reference.mem",lut);
        for(integer p=0;p<N;p++) begin source_prev[p]=15;actual[p]=15;end
        #1000;rst=1;repeat(100) @(negedge clk);
        clear=1;@(negedge clk);clear=0;wait(cld);repeat(100) @(negedge clk);
        $display("PROGRESS initial DDR clear complete at %0t",$time);
        capture(0,0,0,0);capture(1,1,0,0);
        capture(1,1,0,0);if(driven) $fatal(1,"unchanged fast input caused drive");
        capture(3,0,1,1536);
        // All rows contain source changes in this test and are marked dirty.
        checking=1;repeat(20) @(negedge epd);
        scan_start=1;@(negedge epd);scan_start=0;
        wait(scan_done);@(negedge epd);checking=0;
        if(samples!=N/8 || reads!=V) $fatal(1,"integration frame truncated");
        capture(3,1,0,0);if(driven) $fatal(1,"post-refine steady image was re-binarized");
        $display("PASS hybrid integration: actual frame_processor, four DDR buffers, five 2560x1600 HDMI captures, realistic blanking and independent DMA stalls, skipped frame pointer, mixed refinement and 1600 output rows");
        $finish;
    end
    initial begin #600000000;$fatal(1,"hybrid integration timeout f=%0d rows=%0d",frames,dut.completed_drive_rows);end
endmodule

module ps_system_wrapper (
    input wire clk,rst_n,output wire CLK_50M,GPIO_O,
    input wire [31:0] texture_fdma_waddr,gray_fdma_waddr,data_fdma_waddr,
    input wire texture_fdma_wareq,gray_fdma_wareq,data_fdma_wareq,
    output wire texture_fdma_wbusy,gray_fdma_wbusy,data_fdma_wbusy,
    input wire [63:0] texture_fdma_wdata,gray_fdma_wdata,data_fdma_wdata,
    input wire texture_fdma_wready,gray_fdma_wready,data_fdma_wready,
    input wire [15:0] texture_fdma_wsize,gray_fdma_wsize,data_fdma_wsize,
    output wire texture_fdma_wvalid,gray_fdma_wvalid,data_fdma_wvalid,
    input wire [31:0] texture_fdma_raddr,gray_fdma_raddr,data_fdma_raddr,
    input wire texture_fdma_rareq,gray_fdma_rareq,data_fdma_rareq,
    output wire texture_fdma_rbusy,gray_fdma_rbusy,data_fdma_rbusy,
    output wire [63:0] texture_fdma_rdata,gray_fdma_rdata,data_fdma_rdata,
    input wire texture_fdma_rready,gray_fdma_rready,data_fdma_rready,
    input wire [15:0] texture_fdma_rsize,gray_fdma_rsize,data_fdma_rsize,
    output wire texture_fdma_rvalid,gray_fdma_rvalid,data_fdma_rvalid
);
    localparam WORDS=2560*1600/8;
    reg [63:0] mem[0:WORDS*4-1];
    function automatic integer index(input reg[31:0] a);
        index=(a>>22)*WORDS+(a&32'h3fffff)/8;
    endfunction
    assign CLK_50M=clk;assign GPIO_O=0;
    wire [31:0] wa[0:2],ra[0:2];
    wire [63:0] wd[0:2];wire [15:0] ws[0:2],rs[0:2];
    wire [2:0] wq,rq,wr,rr;
    reg [2:0] wb=0,rb=0,wv=0,rv=0;
    reg [63:0] rd[0:2];
    reg [31:0] wbase[0:2],rbase[0:2];
    integer wc[0:2],rc[0:2],wn[0:2],rn[0:2],waitw[0:2],waitr[0:2],ticks=0;
    assign {wa[2],wa[1],wa[0]}={data_fdma_waddr,gray_fdma_waddr,texture_fdma_waddr};
    assign {ra[2],ra[1],ra[0]}={data_fdma_raddr,gray_fdma_raddr,texture_fdma_raddr};
    assign {wd[2],wd[1],wd[0]}={data_fdma_wdata,gray_fdma_wdata,texture_fdma_wdata};
    assign {ws[2],ws[1],ws[0]}={data_fdma_wsize,gray_fdma_wsize,texture_fdma_wsize};
    assign {rs[2],rs[1],rs[0]}={data_fdma_rsize,gray_fdma_rsize,texture_fdma_rsize};
    assign wq={data_fdma_wareq,gray_fdma_wareq,texture_fdma_wareq};
    assign rq={data_fdma_rareq,gray_fdma_rareq,texture_fdma_rareq};
    assign wr={data_fdma_wready,gray_fdma_wready,texture_fdma_wready};
    assign rr={data_fdma_rready,gray_fdma_rready,texture_fdma_rready};
    assign {data_fdma_wbusy,gray_fdma_wbusy,texture_fdma_wbusy}=wb;
    assign {data_fdma_rbusy,gray_fdma_rbusy,texture_fdma_rbusy}=rb;
    assign {data_fdma_wvalid,gray_fdma_wvalid,texture_fdma_wvalid}=wv;
    assign {data_fdma_rvalid,gray_fdma_rvalid,texture_fdma_rvalid}=rv;
    assign {data_fdma_rdata,gray_fdma_rdata,texture_fdma_rdata}={rd[2],rd[1],rd[0]};
    always @(posedge clk) if(rst_n) for(integer p=0;p<3;p++) begin
        if(wv[p]) begin mem[index(wbase[p])+wc[p]]=wd[p];wc[p]++;end
        if(rv[p]) rc[p]++;
    end
    always @(negedge clk) if(rst_n) begin
        ticks++;wv=0;rv=0;
        for(integer p=0;p<3;p++) begin
            if(!wb[p] && wq[p]) begin
                wb[p]=1;wbase[p]=wa[p];wc[p]=0;wn[p]=ws[p];waitw[p]=7+p;
            end else if(wb[p]) begin
                if(wc[p]==wn[p]) wb[p]=0;
                else if(waitw[p]) waitw[p]--;
                else wv[p]=wr[p] && ticks%11!=0;
            end
            if(!rb[p] && rq[p]) begin
                rb[p]=1;rbase[p]=ra[p];rc[p]=0;rn[p]=rs[p];waitr[p]=9+2*p;
            end else if(rb[p]) begin
                if(rc[p]==rn[p]) rb[p]=0;
                else if(waitr[p]) waitr[p]--;
                else if(rr[p] && ticks%13!=0) begin rv[p]=1;rd[p]=mem[index(rbase[p])+rc[p]];end
            end
        end
    end
endmodule
