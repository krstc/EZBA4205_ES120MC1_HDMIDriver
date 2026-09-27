`timescale 1ns/1ps
module es120_pixel_packet_tb;
    reg clk=0,rst=0,valid=0,video=0,refine=0;
    always #10 clk=~clk;
    reg [63:0] pixels;
    reg [31:0] source_levels;
    reg [127:0] history;
    wire ov;
    wire [63:0] drives;
    wire [127:0] next_history;
    wire [3:0] changed,driven,pending;
    reg [1:0] lut[0:8191];
    reg [63:0] saved;
    integer checks=0;
    pixel_packet_es120mc1 dut(.clk(clk),.rst_n(rst),.valid(valid),.video_mode(video),.refine(refine),.text_mode(1'b0),
        .pixels(pixels),.source_levels(source_levels),.history(history),.out_valid(ov),.drives(drives),.next_history(next_history),
        .changed_count(changed),.drive_count(driven),.pending_count(pending));
    task packet;
        @(negedge clk);valid=1;
        @(negedge clk);valid=0;
        wait(ov);@(negedge clk);
        saved=drives;history=next_history;checks++;
        @(negedge clk);
    endtask
    initial begin
        $readmemh("../../hdmi_native_gc16_20260920/gc16_reference.mem",lut);
        #100;rst=1;video=0;
        for(integer old=0;old<16;old++) for(integer target=0;target<16;target++) begin
            for(integer lane=0;lane<8;lane++) begin
                history[lane*16+:16]={2'd0,5'd0,4'(old),1'b0,4'(old)};
                pixels[lane*8+:8]={2{4'(target)}};
            end
            source_levels={8{4'(target)}};
            for(integer n=0;n<11;n++) begin
                packet();
                for(integer f=0;f<3;f++) for(integer lane=0;lane<8;lane++)
                    if(saved[lane*8+f*2+:2] !== ((n*3+f<30 && old!=target) ? lut[(n*3+f)*256+target*16+old] : 2'b0))
                        $fatal(1,"GC16 old=%0d target=%0d phase=%0d got=%h",old,target,n*3+f,saved);
            end
            for(integer lane=0;lane<8;lane++)
                if(history[lane*16+14+:2]!=0 || history[lane*16+:4]!=target)
                    $fatal(1,"GC16 committed before/after wrong target");
        end
        video=1;refine=0;history={8{16'h01ef}};pixels=0;source_levels=0;
        packet();if(saved!=={8{8'h15}}) $fatal(1,"first three black pulses");
        packet();if(saved!=={8{8'h05}}) $fatal(1,"remaining TWO black pulses");
        packet();if(saved!==0) $fatal(1,"static black driven again");
        pixels={8{8'hff}};source_levels={8{4'hf}};packet();if(saved!=={8{8'h2a}}) $fatal(1,"first three white pulses");
        pixels=0;source_levels=0;packet();if(saved!=={8{8'h15}}) $fatal(1,"early cancel must undo exactly three pulses");
        packet();if(saved!==0) $fatal(1,"cancellation leaves no phantom remaining dose");
        // Cancellation at every possible residual count must undo precisely
        // the delivered dose, including a direction change on the last field.
        for(integer rem=1;rem<5;rem++) begin
            history={8{{2'd1,5'(rem),4'd0,1'b0,4'hf}}};pixels={8{8'hff}};source_levels={8{4'hf}};
            packet();
            for(integer f=0;f<3;f++)
                if(saved[f*2+:2] !== (f<5-rem ? 2'b10 : 2'b00)) $fatal(1,"cancel remainder=%0d",rem);
        end
        history={8{16'h01ef}};pixels={8{8'h99}};source_levels={8{4'h9}};packet();
        if(saved!=0 || pending!=8) $fatal(1,"midgray must wait without dithering");
        refine=1;packet();
        refine=0;pixels=0;
        for(integer n=1;n<11;n++) begin
            packet();
            for(integer f=0;f<3;f++)
                if(saved[f*2+:2] !== (n*3+f<30 ? lut[(n*3+f)*256+9*16+15] : n*3+f<32 ? 2'b00 : 2'b01))
                    $fatal(1,"mid-wave HDMI change corrupted fixed GC16 target");
        end
        if(history[3:0]!=9) $fatal(1,"GC16 did not finish old target");
        $display("PASS per-pixel packets: %0d, all native transitions, DU5, cancellation and immutable GC16",checks);
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
