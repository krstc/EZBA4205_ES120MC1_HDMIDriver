`timescale 1ns/1ps
module es120_dither_tb;
    reg clk=0, rst=0, de=0, hs=1, vs=1;
    reg [7:0] data=0;
    wire out_de, out_hs, out_vs, valid;
    wire [7:0] out_data;
    integer white_count;

    always #5 clk=~clk;
    hdmi_input_es120mc1 #(
        .INPUT_H(16), .FRAME_H(16), .FRAME_V(16), .DITHER_ENABLE(1),
        // Exercise the complete 16x16 rank tile directly.  The production
        // build keeps VIDEO_LEVELS_ENABLE=1 for studio-range expansion and
        // tone mapping; this bench isolates the spatial quantizer itself.
        .VIDEO_LEVELS_ENABLE(0)
    ) dut (
        .pix_clk(clk), .rst_n(rst), .de_i(de), .hs_i(hs), .vs_i(vs),
        .gray_i(data), .gray_de(out_de), .gray_hs(out_hs),
        .gray_vs(out_vs), .gray_data(out_data), .video_valid(valid),
        .native_refine(1'b0), .mode_notice(2'b0)
    );

    task pixel(input bit d, input bit v, input [7:0] value);
        begin
            @(negedge clk); de=d; vs=v; data=value;
            @(posedge clk); #1;
            if (out_de) begin
                if (out_data !== 8'h00 && out_data !== 8'hff)
                    $fatal(1,"dither emitted non-binary pixel %h",out_data);
                if (out_data == 8'hff) white_count=white_count+1;
            end
        end
    endtask

    task check_level(input [7:0] level, input integer expected_white);
        begin
            repeat(4) pixel(0,1,level);
            white_count=0;
            pixel(0,0,level); pixel(0,1,level);
            for(integer y=0;y<16;y=y+1) begin
                for(integer x=0;x<16;x=x+1) pixel(1,1,level);
                pixel(0,1,level);
            end
            pixel(0,0,level); repeat(4) pixel(0,1,level);
            if (white_count != expected_white)
                $fatal(1,"level %0d produced %0d white pixels, expected %0d",
                    level,white_count,expected_white);
        end
    endtask

    initial begin
        #21; rst=1;
        check_level(8'd0,0);
        check_level(8'd1,1);
        check_level(8'd16,16);
        check_level(8'd64,64);
        check_level(8'd128,128);
        check_level(8'd192,192);
        check_level(8'd254,254);
        check_level(8'd255,256);
        $display("PASS spatial dither: complete 16x16 blue-noise tile and solid endpoints correct");
        $finish;
    end
    initial begin #1000000; $fatal(1,"dither timeout"); end
endmodule
