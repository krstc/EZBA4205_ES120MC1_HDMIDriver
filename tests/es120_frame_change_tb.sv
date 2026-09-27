`timescale 1ns/1ps
module es120_frame_change_tb;
    reg pix_clk=0, rst_n=0, de=0, hs=1, vs=1;
    reg [7:0] gray=0;
    always #5 pix_clk=~pix_clk;

    wire gray_de, gray_hs, gray_vs, video_valid, frame_changed;
    wire [7:0] gray_data;
    hdmi_input_es120mc1 #(
        .INPUT_H(16), .FRAME_H(16), .FRAME_V(4), .DITHER_ENABLE(0)
    ) dut (
        .pix_clk(pix_clk), .rst_n(rst_n), .de_i(de), .hs_i(hs),
        .vs_i(vs), .gray_i(gray), .gray_de(gray_de), .gray_hs(gray_hs),
        .gray_vs(gray_vs), .gray_data(gray_data), .video_valid(video_valid),
        .frame_changed(frame_changed), .native_refine(1'b0), .mode_notice(2'b0)
    );

    task boundary;
        begin
            @(negedge pix_clk); vs=0;
            repeat(2) @(negedge pix_clk);
            vs=1;
            repeat(2) @(negedge pix_clk);
        end
    endtask

    task pixels;
        input [7:0] first_pixel;
        integer x, y;
        begin
            for (y=0; y<4; y=y+1) begin
                @(negedge pix_clk); de=1;
                for (x=0; x<16; x=x+1) begin
                    gray=(x==0 && y==0) ? first_pixel : 8'h40;
                    @(negedge pix_clk);
                end
                de=0; gray=0;
                repeat(3) @(negedge pix_clk);
            end
        end
    endtask

    initial begin
        repeat(4) @(negedge pix_clk); rst_n=1;
        boundary();
        pixels(8'h40);
        boundary();
        if (!frame_changed) $fatal(1,"first completed frame was not marked changed");

        pixels(8'h40);
        boundary();
        if (frame_changed) $fatal(1,"identical frame was marked changed");

        pixels(8'h41);
        boundary();
        if (!frame_changed) $fatal(1,"changed sampled pixel was not detected");

        $display("PASS frame change: first/different frames detected and identical frame held static");
        $finish;
    end
    initial begin #100000; $fatal(1,"frame change timeout"); end
endmodule
