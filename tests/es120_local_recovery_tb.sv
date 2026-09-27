`timescale 1ns/1ps
module es120_local_recovery_tb;
    reg clk=0, rst=0, manual=0, link=1;
    always #10 clk=~clk;
    reg capture_done=0, display_done=0, clear_done=0;
    reg [22:0] source_changes=128, captured_changes=0, pending_changes=0;
    wire capture_start, display_start, clear_start, init_mode, white_only;
    wire stripes, hdmi, run, fast, recovery;
    wire [1:0] status;
    integer capture_age=0, display_age=0, clear_age=0;
    integer hdmi_displays=0, repairs=0, cleans=0, rebases=0, captures=0;
    integer checkpoint;
    reg active_repair=0;
    status_manager_es120mc1 #(.POWER_SETTLE_CYCLES(2),.HDMI_STAGE_CYCLES(2),
        .CAPTURE_TIMEOUT_CYCLES(1000),.LOCAL_RECOVERY_ENABLE(1),
        .RECOVERY_QUIET_FRAMES(3),.RECOVERY_MIN_PIXELS(64)) dut(
        .clk(clk),.rst_n(rst),.ready(1'b1),.hdmi_valid(link),.hdmi_signal_locked(link),
        .hdmi_frame_changed(1'b0),.captured_changed_pixels(captured_changes),
        .manual_refresh(manual),.clear_done(clear_done),.capture_done(capture_done),
        .display_done(display_done),.dma_idle(1'b1),.clear_start(clear_start),
        .capture_start(capture_start),.display_start(display_start),.init_mode(init_mode),
        .white_only(white_only),.stripes(stripes),.capture_from_hdmi(hdmi),
        .datapath_run(run),.hdmi_fast_update(fast),.local_recovery(recovery),.status_mode(status));
    always @(posedge clk) begin
        capture_done<=0; display_done<=0; clear_done<=0;
        if(capture_start) begin
            if(capture_age!=0) $fatal(1,"capture overlap");
            capture_age<=hdmi_displays%2 ? 4:12;
            pending_changes<=source_changes;
            if(hdmi) captures<=captures+1;
        end else if(capture_age>0) begin
            capture_age<=capture_age-1;
            if(capture_age==1) begin
                capture_done<=1;
                captured_changes<=pending_changes;
            end
        end
        if(display_start) begin
            if(display_age!=0) $fatal(1,"display overlap");
            display_age<=recovery ? 25:8;
            active_repair<=recovery;
            if(hdmi) hdmi_displays<=hdmi_displays+1;
            if(recovery) begin
                if(init_mode || captured_changes>=64) $fatal(1,"repair of moving frame/global clean");
                repairs<=repairs+1;
            end
            if(init_mode) begin
                if(!white_only || hdmi) $fatal(1,"unexpected full-screen flash");
                cleans<=cleans+1;
            end
        end else if(display_age>0) begin
            display_age<=display_age-1;
            if(display_age==1) begin display_done<=1; active_repair<=0; end
        end
        if(clear_start) begin
            if(display_age!=0 || capture_age!=0) $fatal(1,"DDR rebase while pipeline active");
            rebases<=rebases+1; clear_age<=3;
        end else if(clear_age>0) begin
            clear_age<=clear_age-1;
            if(clear_age==1) clear_done<=1;
        end
    end
    initial begin
        #100; rst=1;
        wait(hdmi_displays>=6);
        if(repairs || cleans) $fatal(1,"moving input triggered recovery");
        // The source hash is permanently zero: exact DDR metrics must dominate.
        source_changes=0;
        wait(repairs==1);
        checkpoint=hdmi_displays;
        wait(hdmi_displays>=checkpoint+12);
        if(repairs!=1 || cleans || rebases!=1) $fatal(1,"static page repeatedly flashed/repaired");
        // Cursor-sized changes must not request a scene recovery.
        source_changes=4; checkpoint=captures;
        wait(captures>=checkpoint+4); source_changes=0;
        checkpoint=hdmi_displays; wait(hdmi_displays>=checkpoint+10);
        if(repairs!=1) $fatal(1,"small cursor change scheduled recovery");
        source_changes=128; checkpoint=captures;
        // A blinking caret must not prevent the pending scroll repair.
        wait(captures>=checkpoint+3); source_changes=4;
        wait(repairs==2);
        @(negedge clk); manual=1;
        @(negedge clk); manual=0;
        wait(cleans==1 && rebases==2);
        wait(hdmi && fast);
        checkpoint=hdmi_displays; wait(hdmi_displays>=checkpoint+8);
        if(cleans!=1 || repairs!=2) $fatal(1,"manual action caused duplicate recovery");
        link=0;
        wait(!hdmi);
        repeat(100) @(negedge clk);
        if(recovery) $fatal(1,"repair state leaked through unplug");
        $display("PASS local scheduler: exact capture metrics, both completion orders, motion/quiet, one-shot repair, cursor filtering, queued M18, unplug");
        $finish;
    end
    initial begin #2000000; $fatal(1,"local scheduler timeout state=%0d repairs=%0d",dut.state,repairs); end
endmodule
