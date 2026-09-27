`timescale 1ns/1ps
module es120_text_dirty_tb;
    reg clk=0,rst=0,valid=0,video=1,refine=0,text_mode=1;
    always #10 clk=~clk;
    reg [63:0] pixels=0;
    reg [31:0] source_levels=0;
    reg [127:0] history=0;
    wire out_valid;
    wire [63:0] drives;
    wire [127:0] next_history;
    wire [3:0] changed_count,drive_count,pending_count;
    pixel_packet_es120mc1 #(.ENABLE_NATIVE_GC16(1)) dut (
        .clk(clk),.rst_n(rst),.valid(valid),.video_mode(video),.refine(refine),
        .text_mode(text_mode),.pixels(pixels),.source_levels(source_levels),
        .history(history),.out_valid(out_valid),.drives(drives),
        .next_history(next_history),.changed_count(changed_count),
        .drive_count(drive_count),.pending_count(pending_count));

    task packet;
        begin
            @(negedge clk);valid=1;
            @(negedge clk);valid=0;
            wait(out_valid);@(negedge clk);
            history=next_history;
            @(negedge clk);
        end
    endtask

    initial begin
        #100;rst=1;
        // All pixels are already black. Only lane 0 changes gray level.
        // Text mode must first use the short binary endpoint path.
        source_levels[3:0]=4'h8;
        pixels[7:4]=4'h8;
        packet();
        if (history[15:14]!==2'd1 || drives[5:0]===0)
            $fatal(1,"lane 0 did not enter fast DU5: state=%h drives=%h",history[15:0],drives);
        if (history[31:16]!==16'h0000 || history[47:32]!==16'h0000 ||
            history[63:48]!==16'h0000 || history[79:64]!==16'h0000 ||
            history[95:80]!==16'h0000 || history[111:96]!==16'h0000 ||
            history[127:112]!==16'h0000)
            $fatal(1,"unchanged lanes were modified");

        // The same pixel is now stable. It must promote itself to native GC16
        // without waiting for a global quiet/refine command.
        packet();
        if (history[15:14]!==2'd2 || history[8]!==1'b0 || history[3:0]!==4'h8)
            $fatal(1,"stable dirty pixel did not enter local GC16: %h",history[15:0]);
        if (history[31:16]!==16'h0000 || history[47:32]!==16'h0000 ||
            history[63:48]!==16'h0000 || history[79:64]!==16'h0000 ||
            history[95:80]!==16'h0000 || history[111:96]!==16'h0000 ||
            history[127:112]!==16'h0000)
            $fatal(1,"local GC16 modified unchanged lanes");

        // A stable native gray pixel must not be forced to a binary endpoint
        // just because the fast dither representation differs. This models
        // the unchanged page background while Word scrolls elsewhere.
        refine=0;
        pixels[7:4]=4'h0;
        source_levels[3:0]=4'h8;
        history[15:0]={2'd0,5'd0,4'h8,1'b0,4'h8};
        packet();
        if (drives[5:0]!==0 || history[15:0]!==16'h0108)
            $fatal(1,"stable native gray was spuriously driven: state=%h drives=%h",
                history[15:0],drives[5:0]);

        // A real source change at that pixel is still eligible for the fast
        // binary path.
        source_levels[3:0]=4'h9;
        packet();
        if (drives[5:0]===0 || history[15:14]!==2'd1)
            $fatal(1,"changed native gray did not enter DU5: state=%h drives=%h",
                history[15:0],drives[5:0]);

        // The one-shot idle cleanup is explicitly global: even clean pixels
        // whose old and new gray are equal must run the GC16 waveform once.
        refine=1;
        pixels={8{8'h88}};
        source_levels={8{4'h8}};
        history={8{16'h0108}};
        packet();
        if (history[15:14]!==2'd2 || history[31:30]!==2'd2 ||
            history[47:46]!==2'd2 || history[63:62]!==2'd2 ||
            history[79:78]!==2'd2 || history[95:94]!==2'd2 ||
            history[111:110]!==2'd2 || history[127:126]!==2'd2)
            $fatal(1,"global refine did not start GC16 on every clean pixel: %h",history);

        $display("PASS text mode: per-pixel DU/GC16 plus one-shot global GC16");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
