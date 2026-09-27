`timescale 1ns/1ps
module es120_pixel_dither_motion_tb;
    reg clk=0, rst=0, valid=0;
    reg [63:0] pixels;
    reg [31:0] source_levels;
    reg [127:0] history;
    wire out_valid;
    wire [63:0] drives;
    wire [127:0] next_history;
    wire [3:0] changed, driven, pending;
    reg [63:0] saved;
    integer packets=0;
    always #10 clk=~clk;

    pixel_packet_es120mc1 #(.ENABLE_NATIVE_GC16(0)) dut(
        .clk(clk), .rst_n(rst), .valid(valid), .video_mode(1'b1), .refine(1'b0),
        .pixels(pixels), .source_levels(source_levels), .history(history), .text_mode(1'b0), .out_valid(out_valid), .drives(drives),
        .next_history(next_history), .changed_count(changed), .drive_count(driven),
        .pending_count(pending));

    task automatic packet;
        begin
            @(negedge clk); valid=1;
            @(negedge clk); valid=0;
            wait(out_valid); @(negedge clk);
            saved=drives; history=next_history; packets=packets+1;
            @(negedge clk);
        end
    endtask

    task automatic settle_target(input [7:0] target);
        integer i;
        begin
            pixels={8{target}};
            source_levels={8{target[3:0]}};
            for(i=0;i<5;i=i+1) packet();
            if (pending != 0 || driven != 0)
                $fatal(1,"target %h did not settle: pending=%0d driven=%0d state=%h",
                    target,pending,driven,history);
        end
    endtask

    initial begin
        #100; rst=1;
        history={8{16'h01ef}};
        pixels=0;
        source_levels=0;
        settle_target(8'h00);
        // A white cursor entering a black document, then leaving it, must
        // cancel only the dose already delivered.  It must not leave a
        // permanent black/white brush behind the moving cursor.
        settle_target(8'hff);
        settle_target(8'h00);
        settle_target(8'hff);
        settle_target(8'h00);
        $display("PASS spatial DU5 motion: reversible pixel target changes settle without GC16 or phantom drive, packets=%0d", packets);
        $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule
