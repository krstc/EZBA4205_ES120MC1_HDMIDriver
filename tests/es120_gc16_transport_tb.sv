`timescale 1ns/1ps
module es120_gc16_transport_tb #(parameter HEIGHT=32, RECOVERY=1, SCANS=44,
    HYBRID=0,FAST=0,REFINE=0,BAND_Y=16,BAND_ROWS=16);
    reg clk=0,epd=0,rst=0,start=0;
    always #10 clk=~clk;
    always #11.346154 epd=~epd;
    reg [7:0] phase=1;
    wire req_epd,request,done,pop,stl,le,full,empty;
    wire [63:0] data;
    wire [15:0] output_pixels;
    wire [13:0] tile;
    wire ra,rr;
    wire [15:0] size;
    wire [31:0] addr;
    reg busy=0,valid=0;
    reg [63:0] rdata=0;
    integer requests=0,row=0,word=0,delay_left=0,tick=0;
    integer samples=0,pops=0,scans=0,latches=0;
    reg old_le=0;
    reg [1:0] ref_lut[0:8191];
    wire dirty=!tile[0];
    function automatic [7:0] transition(input integer y,x);
        reg [3:0] t,o;
        begin
            t=(x/16+y)%16;o=(x+y*3)%16;
            if(HYBRID) begin
                if((x%8)<2) begin t=15;o=15;end
                else if((x%8)==2) begin t=7;o=7;end
                else if(FAST || (REFINE && (y<BAND_Y || y>=BAND_Y+BAND_ROWS)))
                    t=t[3]?15:0;
            end
            if(RECOVERY && ((x/32)%2)) o=t;
            transition={t,o};
        end
    endfunction
    function automatic [1:0] expected(input integer ph,y,x);
        reg [7:0] tr;
        integer ix;
        begin
            tr=transition(y,x);expected=0;
            if(HYBRID && (FAST || (REFINE && (y<BAND_Y || y>=BAND_Y+BAND_ROWS)))) begin
                if(ph<=5 && tr[7:4]!=tr[3:0]) expected=tr[7:4]==15?2:tr[7:4]==0?1:0;
            end else if(HYBRID && REFINE && tr==8'hff && (x/32)%2==0 && ph<=5) expected=2;
            else if(RECOVERY) begin
                if((x/32)%2==0) begin
                    if(ph<=10) expected=2;
                    else if(ph>=13 && ph<=42) expected=ref_lut[(ph-13)*256+tr[7:4]*16+15];
                end
            end else if(ph<=30 && tr[7:4]!=tr[3:0]) expected=ref_lut[(ph-1)*256+tr];
        end
    endfunction
    frame_ctrl_es120mc1 #(.EPD_V(HEIGHT)) timing (
        .rst_n(rst),.epd_clk(epd),.s_flag(start),.SKV(),.SPV(),.XCL(),
        .XLE(le),.XSTL(stl),.r_flag(req_epd),.end_flag(done));
    sync_h2lck crossing(.in_clk(epd),.out_clk(clk),.rst_n(rst),.level_in(req_epd),.pulse_out(request));
    fdma_r_gc16_es120mc1 #(.EPD_V(HEIGHT),.HYBRID_REFRESH(HYBRID),.REFINE_ROWS(BAND_ROWS)) dut (
        .clk(clk),.rst_n(rst),.epd_clk(epd),.fdma_rflag(request),.phase(phase),
        .local_recovery(RECOVERY!=0),.recovery_tile(tile),.recovery_dirty(dirty),
        .fast_update(FAST!=0),.refine_update(REFINE!=0),.refine_y(12'(BAND_Y)),
        .buf_addr(32'he800000),.fdma_raddr(addr),.fdma_rareq(ra),.fdma_rbusy(busy),
        .fdma_rdata(rdata),.fdma_rready(rr),.fdma_rsize(size),.fdma_rvalid(valid),
        .fifo_ren(pop),.fifo_out(data),.fifo_full(full),.fifo_empty(empty));
    data_mgr #(.IN_WID(64),.OUT_WID(16),.LINE_DATA_COUNT(320)) serializer (
        .clk(epd),.rst_n(rst),.fifo_ren(pop),.din(data),.data_ren(!stl),.dout(output_pixels));
    always @(posedge clk) if(rst) begin
        if(valid) word=word+1;
        if(dut.pack_write && full) $fatal(1,"native output FIFO overflow");
    end
    always @(negedge clk) if(rst) begin
        tick=tick+1;valid=0;
        if(!busy && ra) begin
            if(size!=320 || addr!=32'he800000+row*2560) $fatal(1,"native reader stride/count");
            busy=1;word=0;requests=requests+1;
            // Cross one line-request boundary without exhausting the two-line lead.
            delay_left=(row%41==40)?150:3;
        end else if(busy) begin
            if(word==320) begin busy=0;row=(row+1)%HEIGHT; end
            else if(delay_left>0) delay_left=delay_left-1;
            else if(rr && tick%11!=0) begin
                valid=1;
                for(integer p=0;p<8;p=p+1) rdata[8*p+:8]=transition(row,word*8+p);
            end
        end
    end
    always @(posedge epd) if(rst) begin
        if(pop) begin
            if(empty) $fatal(1,"native FIFO underflow scan=%0d row=%0d sample=%0d",scans,samples/320,samples%320);
            pops=pops+1;
        end
        if(!stl) begin
            for(integer p=0;p<8;p=p+1)
                if(output_pixels[2*p+:2]!==expected(phase,samples/320,(samples%320)*8+p))
                    $fatal(1,"GC16 pin data phase=%0d row=%0d x=%0d got=%h expected=%h",phase,samples/320,(samples%320)*8+p,output_pixels[2*p+:2],expected(phase,samples/320,(samples%320)*8+p));
            samples=samples+1;
        end
        if(le && !old_le) begin
            if(samples!=(latches+1)*320) $fatal(1,"latch before row completion");
            latches=latches+1;
        end
        old_le=le;
    end
    initial begin
        $readmemh("../../hdmi_native_gc16_20260920/gc16_reference.mem",ref_lut);
        #1000;rst=1;repeat(50) @(negedge epd);
        for(integer s=0;s<SCANS;s=s+1) begin
            phase=(SCANS==1)?25:s+1;
            repeat(10) @(negedge epd);
            start=1;@(negedge epd);start=0;
            wait(done);@(negedge epd);
            if(samples!=HEIGHT*320 || pops!=HEIGHT*80 || latches!=HEIGHT || requests!=HEIGHT)
                $fatal(1,"native scan counts sample=%0d pop=%0d latch=%0d request=%0d",samples,pops,latches,requests);
            samples=0;pops=0;latches=0;requests=0;scans=scans+1;
            repeat(20) @(negedge epd);
        end
        $display("PASS GC16 transport: %0d scans x %0d full-width rows, all pixels, all phases, recovery=%0d, 44.0678MHz panel, stalled DDR",SCANS,HEIGHT,RECOVERY);
        $finish;
    end
    initial begin #100000000; $fatal(1,"native transport timeout");end
endmodule
