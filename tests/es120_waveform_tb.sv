`timescale 1ns/1ps
module es120_waveform_tb #(parameter NATIVE=0,HYBRID=0);
    reg clk=0, epd=0, rst=0, start=0, init_mode=1, white_only=0, fast_update=0;
    always #10 clk=~clk;
    always #(NATIVE?11.346154:34.039) epd=~epd;
    wire [7:0] phase;
    wire busy, done, request, pop, skv, spv, xcl, le, stl;
    wire [15:0] data;
    integer samples[0:44];
    reg recovery=0;
    integer requests=0,pops=0;
    reg [1:0] expected;
    display_mgr_es120mc1 #(.EPD_WID(16),.EPD_H(1280),.EPD_V(1),
        .PERIOD_CNT(5),.FAST_PERIOD_CNT(5),.NATIVE_GC16(NATIVE),
        .HYBRID_REFRESH(HYBRID),.LOCAL_RECOVERY(NATIVE && !HYBRID)) dut(
        .clk(clk),.epd_clk(epd),.rst_n(rst),.epd_rst_n(rst),.s_flag(start),.init_mode(init_mode),
        .white_only(white_only),.fast_update(fast_update),
        .local_recovery(recovery),
        .period_cnt(phase),.d_busy(busy),.d_fflag(done),.r_flag(request),.fifo_ren(pop),
        .din(64'h5555555555555555),.EPD_SKV(skv),.EPD_SPV(spv),.EPD_XCL(xcl),
        .EPD_XLE(le),.EPD_XSTL(stl),.EPD_DOUT(data));
    always @(posedge epd) if(rst) begin
        if(request) requests=requests+1;
        if(pop) pops=pops+1;
        if(!stl) begin
            expected = init_mode ? (white_only ? (phase<=10 ? 2:0) :
                ((phase<=10) ? 2 : (phase<=20 ? 1 : (phase<=30 ? 2:0)))) : 1;
            if(data !== {8{expected}}) $fatal(1,"waveform phase=%0d data=%h",phase,data);
            samples[phase]=samples[phase]+1;
        end else if(data !== 0) $fatal(1,"nonzero idle drive");
    end
    task launch;
        @(negedge clk); start=1; @(negedge clk); start=0;
        wait(done); @(negedge clk);
    endtask
    initial begin
        for(integer i=0;i<=32;i=i+1) samples[i]=0;
        #1000; rst=1; repeat(100) @(negedge clk);
        launch();
        for(integer i=1;i<=32;i=i+1)
            if(samples[i]!=320) $fatal(1,"init scan %0d count=%0d",i,samples[i]);
        if(requests || pops) $fatal(1,"initialization consumed framebuffer");
        repeat(100) @(negedge clk); white_only=1;
        for(integer i=0;i<=32;i=i+1) samples[i]=0;
        launch();
        for(integer i=1;i<=32;i=i+1)
            if(samples[i] != (i<=12 ? 320:0)) $fatal(1,"white-only scan count %0d",i);
        if(requests || pops) $fatal(1,"white-only clean consumed framebuffer");
        repeat(100) @(negedge clk); init_mode=0;
        for(integer i=0;i<=32;i=i+1) samples[i]=0;
        launch();
        for(integer i=1;i<=(NATIVE?32:5);i=i+1)
            if(samples[i]!=320) $fatal(1,"DU scan %0d count=%0d",i,samples[i]);
        if(requests!=(NATIVE?32:5) || pops!=(NATIVE?2560:400)) $fatal(1,"normal transport counts");
        repeat(100) @(negedge clk); fast_update=1;
        for(integer i=0;i<=32;i=i+1) samples[i]=0;
        launch();
        for(integer i=1;i<=(HYBRID?7:NATIVE?32:5);i=i+1)
            if(samples[i]!=320) $fatal(1,"fast DU scan %0d count=%0d",i,samples[i]);
        if(!NATIVE && samples[6]!=0) $fatal(1,"DU exceeded five phases");
        if(requests!=(HYBRID?39:NATIVE?64:10) || pops!=(HYBRID?3120:NATIVE?5120:800)) $fatal(1,"fast transport counts");
        if(HYBRID && samples[8]!=0) $fatal(1,"hybrid fast path still uses long GC16");
        if(NATIVE && !HYBRID) begin
            repeat(100) @(negedge clk);recovery=1;
            for(integer i=0;i<=44;i=i+1) samples[i]=0;
            launch();
            for(integer i=1;i<=44;i=i+1) if(samples[i]!=320) $fatal(1,"repair scan count %0d",i);
        end
        $display("PASS waveform: boot W10/B10/W10/N2, manual W10/N2, native=%0d (32 normal / 44 repair) or legacy DU5; no framebuffer consumption during cleaning",NATIVE);
        $finish;
    end
    initial begin #50000000; $fatal(1,"waveform timeout"); end
endmodule
