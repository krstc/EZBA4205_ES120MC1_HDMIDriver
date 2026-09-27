`timescale 1ns/1ps
module es120_gc16_quantizer_tb #(parameter LIGHTEN=0);
    reg clk=0,rst=0,de=0;
    always #5 clk=~clk;
    reg [7:0] input_gray=0;
    wire valid;
    wire [7:0] output_gray;
    reg [7:0] queue[0:3];
    reg [3:0] de_queue=0;
    integer count=0;
    hdmi_input_es120mc1 #(.INPUT_H(64),.FRAME_H(64),.FRAME_V(256),
        .NATIVE_GC16(1),.DITHER_ENABLE(0),.VIDEO_LEVELS_ENABLE(1),.NATIVE_LIGHTEN(LIGHTEN)) dut (
        .pix_clk(clk),.rst_n(rst),.de_i(de),.hs_i(1'b1),.vs_i(1'b1),.gray_i(input_gray),
        .gray_de(valid),.gray_hs(),.gray_vs(),.gray_data(output_gray),.video_valid(),.frame_changed(),
        .native_refine(1'b1),.mode_notice(2'b0));
    function automatic [7:0] expected(input integer y);
        integer full_range;
        begin
            full_range=y<=16?0:y>=235?255:((y-16)*149)/128;
            expected=((full_range+8)/17)*17;
            if(LIGHTEN && expected!=0 && expected!=255) expected=expected+17;
        end
    endfunction
    always @(posedge clk) if(rst) begin
        for(integer i=3;i>0;i=i-1) queue[i]=queue[i-1];
        queue[0]=expected(input_gray);
        de_queue={de_queue[2:0],de};
        #1;
        if(valid!==de_queue[3]) $fatal(1,"native DE latency mismatch");
        if(valid) begin
            if(output_gray!==queue[3]) $fatal(1,"native level mismatch %h %h",output_gray,queue[3]);
            if(output_gray[7:4]!=output_gray[3:0]) $fatal(1,"not an actual four-bit gray");
            count=count+1;
        end
    end
    initial begin
        #100;rst=1;repeat(5) @(negedge clk);
        for(integer y=0;y<256;y=y+1) begin
            for(integer x=0;x<64;x=x+1) begin
                de=1;input_gray=y;@(negedge clk);
            end
            de=0;repeat(10) @(negedge clk);
        end
        if(count!=16384) $fatal(1,"cropped native pixels: %0d",count);
        $display("PASS native quantizer: all 256 input levels, position-independent output, sixteen gray states, studio endpoints and exact DE alignment");
        $finish;
    end
endmodule
