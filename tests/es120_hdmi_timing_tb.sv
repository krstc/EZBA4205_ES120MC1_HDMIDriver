`timescale 1ns/1ps
module es120_hdmi_timing_tb;
    reg clk=0,rst=0,vs=0,de=0,gvs=0;
    always #10 clk=~clk;
    wire rate_valid,video_valid;
    wire [31:0] period;
    hdmi_frame_guard_es120mc1 #(.CLK_HZ(2500)) guard(
        .clk(clk),.rst_n(rst),.vs(vs),.rate_valid(rate_valid),.measured_period(period));
    hdmi_timing_qualifier #(.FRAME_H(16),.FRAME_V(4)) timing(
        .pix_clk(clk),.rst_n(rst),.gray_de(de),.gray_vs(gvs),.video_valid(video_valid));
    task tick; @(negedge clk); endtask
    task pulse(input integer cycles);
        vs=1; tick; vs=0; repeat(cycles-1) tick;
    endtask
    task frame(input integer width,input integer height);
        gvs=1; tick; gvs=0; tick;
        repeat(height) begin de=1; repeat(width) tick; de=0; repeat(2) tick; end
        gvs=1; tick; gvs=0; repeat(2) tick;
    endtask
    initial begin
        #200; rst=1; tick;
        repeat(4) pulse(100);
        if(!rate_valid || period!=100) $fatal(1,"25Hz rejected");
        repeat(4) pulse(42);
        if(rate_valid) $fatal(1,"60Hz accepted");
        repeat(4) pulse(33);
        if(rate_valid) $fatal(1,"75Hz accepted");
        repeat(4) pulse(100);
        if(!rate_valid) $fatal(1,"25Hz reconnect rejected");
        repeat(110) tick;
        if(rate_valid) $fatal(1,"stopped VS retains valid");
        frame(16,4); if(!video_valid) $fatal(1,"correct dimensions rejected");
        frame(17,4); if(video_valid) $fatal(1,"wide source accepted");
        frame(15,4); if(video_valid) $fatal(1,"short line accepted");
        frame(16,3); if(video_valid) $fatal(1,"short frame accepted");
        frame(16,4); if(!video_valid) $fatal(1,"correct dimensions not recovered");
        $display("PASS HDMI timing: 25Hz accepted; 60/75Hz, stopped VS and incorrect dimensions rejected; recovery accepted");
        $finish;
    end
    initial begin #2000000; $fatal(1,"timing timeout"); end
endmodule
