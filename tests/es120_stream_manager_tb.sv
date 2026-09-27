`timescale 1ns/1ps
module es120_stream_manager_tb;
    reg clk=0,rst=0,locked=0,valid=0,manual=0,fault=0;
    reg mode_toggle=0,frame_changed=0;
    always #10 clk=~clk;
    wire cap,ds,clear,video,init_mode,white,run,refine,text_mode;
    wire [1:0] mode;
    wire [1:0] mode_notice;
    reg cd=0,dd=0,cld=0;
    reg [22:0] changed=0,driven=0,pending=0;
    integer cap_ticks=0,display_ticks=0,clear_ticks=0,local_packets=0;
    integer cycles=0,initial_cleans=0,white_cleans=0,video_frames=0,overlap=0;
    integer full_refines=0;
    integer hold_started=0,info_started=0;
    reg [1:0] prev_mode=0;
    bit motion=0,cap_source=0;
    stream_manager_es120mc1 #(.POWER_SETTLE_CYCLES(8),.BOOT_CYCLE_MIN_CYCLES(50),
        .HDMI_STAGE_CYCLES(100),.MODE_NOTICE_CYCLES(100),
        .CAPTURE_TIMEOUT_CYCLES(500),.QUIET_FRAMES(4),
        .TEXT_IDLE_CYCLES(120),
        .SMOOTH_CLEAN_CYCLES(10)) dut (
        .clk(clk),.rst_n(rst),.ready(1'b1),.hdmi_valid(valid),.hdmi_signal_locked(locked),
        .manual_refresh(manual),.capture_done(cd),.clear_done(cld),.display_done(dd),
        .dma_idle(1'b1),.capture_fault(fault),.changed_pixels(changed),.drive_pixels(driven),.pending_pixels(pending),
        .capture_start(cap),.clear_start(clear),.display_start(ds),.capture_from_hdmi(video),
        .init_mode(init_mode),.white_only(white),.datapath_run(run),.refine(refine),.status_mode(mode),
        .mode_toggle(mode_toggle),.hdmi_frame_changed(frame_changed),
        .text_mode(text_mode),.mode_notice(mode_notice));
    always @(negedge clk) if(rst) begin
        cycles++;cd=0;dd=0;cld=0;
        if(mode!=prev_mode) local_packets=0;
        prev_mode=mode;
        if(clear) begin clear_ticks=4;local_packets=0;end
        else if(clear_ticks>0) begin clear_ticks--;if(clear_ticks==0) cld=1;end
        if(cap) begin
            if(cap_ticks) $fatal(1,"overlapping capture commands");
            cap_ticks=25;cap_source=video;
            if(refine) full_refines++;
            if(ds && !init_mode) overlap++;
        end else if(cap_ticks>0) begin
            cap_ticks--;
            if(cap_ticks==0) begin
                cd=1;
                if(cap_source) begin
                    video_frames++;changed=motion?20000:0;pending=8;driven=motion?20000:0;
                end else begin
                    local_packets++;changed=0;
                    pending=local_packets<11 ? 100:0;driven=local_packets<11 ? 100:0;
                end
            end
        end
        if(ds) begin
            if(display_ticks) $fatal(1,"overlapping display commands");
            display_ticks=20;
            if(init_mode) begin
                if(white) begin
                    white_cleans++;
                    if(mode==1 && cycles-hold_started<100) $fatal(1,"HDMI IN hold too short");
                    if(mode==2 && info_started!=0 && cycles-info_started<100) $fatal(1,"INFO hold too short");
                end else initial_cleans++;
            end
        end else if(display_ticks>0) begin display_ticks--;if(display_ticks==0) dd=1;end
        if(dut.state==11 && dut.timer==0) begin
            if(mode==1) hold_started=cycles;
            if(mode==2) info_started=cycles;
        end
    end
    initial begin
        #100;rst=1;
        wait(dut.state==10);if(initial_cleans!=3) $fatal(1,"boot clean count");
        repeat(20) @(negedge clk);locked=1;valid=1;
        wait(mode==1);wait(mode==2);
        if(white_cleans!=1 || hold_started==0) $fatal(1,"missing IN -> white -> info");
        wait(video);if(white_cleans!=2 || info_started==0) $fatal(1,"missing info -> white -> video");
        wait(video_frames>=8);if(refine) $fatal(1,"smooth path must not promote a frame to GC16");
        motion=1;wait(video_frames>=11);repeat(8) @(negedge clk);
        if(refine) $fatal(1,"smooth path asserted refine");
        if(white_cleans!=2) $fatal(1,"automatic global refresh during video");

        // Enter text mode. Source activity rearms the two-second timer, then a
        // quiet interval launches exactly one whole-screen GC16 capture.
        mode_toggle=1;@(negedge clk);mode_toggle=0;
        wait(text_mode);wait(mode_notice!=0);wait(mode_notice==0);wait(video);
        frame_changed=1;repeat(8) @(negedge clk);frame_changed=0;
        wait(full_refines==1);
        repeat(500) @(negedge clk);
        if(full_refines!=1) $fatal(1,"static text frame repeated global GC16");
        frame_changed=1;repeat(8) @(negedge clk);frame_changed=0;
        wait(full_refines==2);

        manual=1;@(negedge clk);manual=0;wait(white_cleans==3);wait(video_frames>=14);
        locked=0;valid=0;wait(dut.state==10);
        if(video || mode!=0) $fatal(1,"unplug must settle on NO SIGNAL");
        if(overlap<10) $fatal(1,"capture/display not pipelined");
        $display("PASS stream manager: smooth no-auto-clean; text idle one-shot GC16 rearms only on change");
        $finish;
    end
    initial begin #5000000;$fatal(1,"manager timeout state=%0d",dut.state);end
endmodule
