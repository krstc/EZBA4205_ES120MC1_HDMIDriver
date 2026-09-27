`timescale 1ns/1ps
module es120_boot_tb;
    reg clk=0,rst_n=0,ready=0,hdmi=0,clear_done=0,capture_done=0,display_done=0,idle=1;
    reg signal_locked=0;
    always #10 clk=~clk;
    wire clear_start,capture_start,display_start,init_mode,white_only,stripes,from_hdmi,run;
    wire hdmi_fast_update;
    wire [1:0] status_mode;
    integer captures=0, displays=0;
    status_manager_es120mc1 #(.POWER_SETTLE_CYCLES(20), .STRIPE_HOLD_CYCLES(100),
        .CAPTURE_TIMEOUT_CYCLES(1000), .HDMI_STAGE_CYCLES(100), .BOOT_WHITE_CLEAN(1)) dut(
         .clk(clk),.rst_n(rst_n),.ready(ready),.hdmi_valid(hdmi),.hdmi_signal_locked(signal_locked),
         .hdmi_frame_changed(1'b1),
        .manual_refresh(1'b0),
        .clear_done(clear_done),.capture_done(capture_done),.display_done(display_done),.dma_idle(idle),
        .clear_start(clear_start),.capture_start(capture_start),.display_start(display_start),
        .init_mode(init_mode),.white_only(white_only),.stripes(stripes),.capture_from_hdmi(from_hdmi),
        .datapath_run(run),.hdmi_fast_update(hdmi_fast_update),.status_mode(status_mode));
    task tick; @(negedge clk); endtask
    task capture;
        wait(capture_start); tick;
        repeat(30) tick;
        capture_done=1; tick; capture_done=0;
        wait(display_start); tick;
        repeat(30) tick;
        display_done=1; tick; display_done=0;
    endtask
    task white_clean;
        wait(clear_start); tick;
        if(!init_mode || !white_only) $fatal(1,"missing white-only clean / DDR rebase");
        repeat(20) tick;
        if(capture_start || display_start) $fatal(1,"clean did not wait for DDR");
        clear_done=1; tick; clear_done=0;
        wait(display_start); tick;
        repeat(20) tick; display_done=1; tick; display_done=0;
    endtask
    initial begin
        #200; rst_n=1;
        repeat(200) tick;
        if(clear_start || stripes) $fatal(1,"boot ran before power ready or enabled stripes");
        ready=1; wait(clear_start); tick;
        repeat(200) tick;
        if(stripes || !init_mode || !white_only) $fatal(1,"cold boot must align panel and DDR to white");
        clear_done=1; tick; clear_done=0;
        wait(display_start); tick;
        if(!init_mode || !white_only || capture_start) $fatal(1,"missing physical white clean before first capture");
        repeat(30) tick; display_done=1; tick; display_done=0;
        capture();
        repeat(200) tick;
        if(captures!=1 || displays!=2 || from_hdmi || stripes)
            $fatal(1,"cold boot did not go directly to one static no-signal frame");
        signal_locked=1;
        capture();
        if(from_hdmi || status_mode != 2'd1) $fatal(1,"HDMI IN stage did not render locally");
        wait(capture_start); tick;
        if(from_hdmi || status_mode != 2'd2) $fatal(1,"HDMI info stage did not render locally");
        repeat(30) tick;
        capture_done=1; tick; capture_done=0;
        wait(display_start); tick;
        repeat(30) tick; display_done=1; tick; display_done=0;
        repeat(300) tick;
        if(from_hdmi || status_mode != 2'd2)
            $fatal(1,"TMDS lock alone bypassed parallel frame validation");
        hdmi=1;
        wait(capture_start); tick;
        if(!from_hdmi || status_mode != 2'd0) $fatal(1,"HDMI did not take over after diagnostic stages");
        hdmi=0; signal_locked=0;
        white_clean(); capture();
        if(from_hdmi) $fatal(1,"no-signal source not restored");
        hdmi=1; signal_locked=1;
        wait(capture_start); tick;
        if(from_hdmi || status_mode != 2'd1) $fatal(1,"HDMI reconnect IN stage failed");
        repeat(30) tick;
        capture_done=1; tick; capture_done=0;
        wait(display_start); tick;
        repeat(30) tick; display_done=1; tick; display_done=0;
        wait(capture_start); tick;
        if(from_hdmi || status_mode != 2'd2) $fatal(1,"HDMI reconnect info stage failed");
        repeat(30) tick;
        capture_done=1; tick; capture_done=0;
        wait(display_start); tick;
        repeat(30) tick; display_done=1; tick; display_done=0;
        wait(capture_start); tick;
        if(!from_hdmi || status_mode != 2'd0) $fatal(1,"HDMI did not take over");
        repeat(30) tick;
        capture_done=1; tick; capture_done=0;
        wait(display_start);
        if(hdmi_fast_update) $fatal(1,"first HDMI frame skipped the full PERIOD_CNT drive");
        if(!capture_start) $fatal(1,"HDMI display and next capture did not start together");
        tick;
        repeat(30) tick;
        capture_done=1; display_done=1; tick;
        capture_done=0; display_done=0;
        wait(display_start);
        if(!hdmi_fast_update) $fatal(1,"HDMI fast mode did not arm after the priming display");
        if(!capture_start) $fatal(1,"HDMI pipeline did not sustain overlap");
        tick;
        // Pull cable mid-capture with a DDR burst outstanding.
        idle=0; hdmi=0; signal_locked=0;
        repeat(30) tick;
        display_done=1; tick; display_done=0;
        repeat(70) tick;
        if(!run || !from_hdmi) $fatal(1,"reset/switch occurred during DDR burst");
        idle=1; wait(!run); tick;
        if(from_hdmi) $fatal(1,"stopped HDMI clock not released");
        wait(run); wait(clear_start);
        $display("PASS boot: one white alignment before capture, no stripes, runtime white clean, HDMI display/unplug/reconnect and abort drain");
        $finish;
    end
    always @(posedge clk) begin
        if(capture_start) captures=captures+1;
        if(display_start) displays=displays+1;
    end
    initial begin #1000000; $fatal(1,"boot timeout"); end
endmodule
