`timescale 1ns/1ps
module hdmi_input_case #(parameter INPUT_H=2650)(output reg done=0);
    localparam CROP=(INPUT_H-2560)/2;
    reg clk=0,rst=0,de=0,hs=1,vs=1;
    reg [7:0] data=0;
    wire out_de,out_hs,out_vs,valid;
    wire [7:0] out_data;
    integer count;
    always #5 clk=~clk;
    hdmi_input_es120mc1 #(.INPUT_H(INPUT_H), .FRAME_V(4), .DITHER_ENABLE(0)) dut(
        .pix_clk(clk),.rst_n(rst),.de_i(de),.hs_i(hs),.vs_i(vs),.gray_i(data),
        .gray_de(out_de),.gray_hs(out_hs),.gray_vs(out_vs),
        .gray_data(out_data),.video_valid(valid),.native_refine(1'b0),.mode_notice(2'b0));
    task pixel(input bit d,input bit h,input bit v,input integer value);
        @(negedge clk); de=d; hs=h; vs=v; data=value;
        @(posedge clk); #1;
        if(out_data!==data || out_hs!==~h || out_vs!==~v)
            $fatal(1,"data/sync registration mismatch");
    endtask
    task line(input integer width,input integer row);
        count=0;
        pixel(0,0,1,0);
        for(integer x=0;x<width;x=x+1) begin
            pixel(1,1,1,x+row);
            if(out_de !== (x >= CROP && x < CROP+2560)) $fatal(1,"crop DE boundary x=%0d",x);
            if(out_de) begin
                if(out_data!==((CROP+count+row)&255)) $fatal(1,"shifted cropped data");
                count=count+1;
            end
        end
        pixel(0,1,1,0);
        if(out_de) $fatal(1,"DE outside source line");
        if(width>=INPUT_H && count!=2560) $fatal(1,"cropped line has %0d pixels",count);
        pixel(0,1,1,0);
    endtask
    task frame(input integer width,input integer height);
        pixel(0,1,0,0); pixel(0,1,1,0);
        for(integer y=0;y<height;y=y+1) line(width,y);
        pixel(0,1,0,0); pixel(0,1,1,0); pixel(0,1,1,0);
    endtask
    initial begin
        #21; rst=1;
        frame(INPUT_H,4); if(!valid) $fatal(1,"configured mode rejected");
        frame(INPUT_H+1,4); if(valid) $fatal(1,"overwide source accepted");
        frame(1920,4); if(valid) $fatal(1,"1080p width accepted");
        frame(INPUT_H,3); if(valid) $fatal(1,"short frame accepted");
        frame(INPUT_H,4); if(!valid) $fatal(1,"reconnect did not recover");
        #2; rst=0; #1;
        if(valid || out_de) $fatal(1,"reset retains valid video");
        done=1;
    end
    initial begin #2000000; $fatal(1,"HDMI input timeout"); end
endmodule
module es120_hdmi_input_tb;
    wire native_done,compat_done;
    hdmi_input_case #(.INPUT_H(2560)) native_mode(native_done);
    hdmi_input_case #(.INPUT_H(2650)) compat_mode(compat_done);
    initial begin
        wait(native_done && compat_done);
        $display("PASS HDMI input: native 2560 and EDID 2650 with exact 45+2560+45 crop, invalid-mode rejection and recovery");
        $finish;
    end
endmodule
