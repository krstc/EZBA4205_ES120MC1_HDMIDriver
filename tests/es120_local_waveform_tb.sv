`timescale 1ns/1ps
module es120_local_waveform_tb;
    reg clk=0, epd=0, rst=0, start=0, recovery=0;
    always #10 clk=~clk;
    always #11.346 epd=~epd;
    wire [7:0] phase;
    wire busy, done, request, pop, skv, spv, xcl, le, stl;
    wire [15:0] data;
    integer samples[0:32];
    integer requests=0, pops=0, images=0;
    wire image_done;
    localparam [63:0] INPUT_CODES=64'he4e4e4e4e4e4e4e4;
    reg [1:0] code, expected;
    display_mgr_es120mc1 #(.EPD_WID(16),.EPD_H(1280),.EPD_V(2),
        .PERIOD_CNT(5),.FAST_PERIOD_CNT(5),.LOCAL_RECOVERY(1)) dut(
        .clk(clk),.epd_clk(epd),.rst_n(rst),.epd_rst_n(rst),.s_flag(start),
        .init_mode(1'b0),.white_only(1'b0),.fast_update(1'b1),.local_recovery(recovery),
        .period_cnt(phase),.d_busy(busy),.d_fflag(done),.image_fflag(image_done),
        .r_flag(request),.fifo_ren(pop),.din(INPUT_CODES),.EPD_SKV(skv),
        .EPD_SPV(spv),.EPD_XCL(xcl),.EPD_XLE(le),.EPD_XSTL(stl),.EPD_DOUT(data));
    reg previous_image_done=0;
    always @(posedge epd) if(rst) begin
        previous_image_done<=image_done;
        if(image_done && !previous_image_done) images=images+1;
        if(request) requests=requests+1;
        if(pop) pops=pops+1;
        if(!stl) begin
            for(integer i=0;i<8;i=i+1) begin
                code=INPUT_CODES[14-2*i+:2];
                expected=0;
                if(recovery) begin
                    if((code==2 || code==3) && phase<=10) expected=2;
                    if(code==1 && phase<=5) expected=1;
                end else if(code!=3) expected=code;
                if(data[i*2+:2]!==expected || data[i*2+:2]===3)
                    $fatal(1,"unsafe repair waveform phase=%0d code=%0d data=%h",phase,code,data);
            end
            samples[phase]=samples[phase]+1;
        end else if(data!==0) $fatal(1,"nonzero blanking drive");
    end
    task launch(input bit mode, input integer scans);
        repeat(40) @(negedge clk);
        recovery=mode;
        repeat(20) @(negedge clk);
        for(integer i=0;i<=32;i=i+1) samples[i]=0;
        requests=0; pops=0;
        start=1; @(negedge clk); start=0;
        wait(done); repeat(5) @(negedge clk);
        for(integer i=1;i<=32;i=i+1)
            if(samples[i] != (i<=scans ? 640:0)) $fatal(1,"wrong scan length");
        if(requests!=2*scans || pops!=160*scans) $fatal(1,"repair transport count");
    endtask
    initial begin
        #100; rst=1;
        launch(0,5); launch(1,12); launch(0,5);
        if(images!=3) $fatal(1,"repair must advance DDR exactly once");
        $display("PASS local waveform: normal DU5 masks marker 11, repair W10/N2 only marked whites, black DU5, untouched hold, one buffer swap per update");
        $finish;
    end
    initial begin #50000000; $fatal(1,"local waveform timeout"); end
endmodule
