`timescale 1ns/1ps
module es120_gc16_manager_tb;
    reg clk=0,rst=0,link=0,manual=0;
    always #10 clk=~clk;
    reg cd=0,dd=0,cld=0;
    reg [22:0] changes=128,measured=0;
    wire cs,ds,cls,init_mode,white,hdmi,repair,stripes;
    integer capture_age=0,display_age=0,clear_age=0;
    integer ticks=0,boot_count=0,boot_start=0,previous_boot=0;
    integer hdmi_count=0,repair_count=0,manual_count=0;
    integer mark;
    status_manager_es120mc1 #(.POWER_SETTLE_CYCLES(2),.HDMI_STAGE_CYCLES(5),
        .CAPTURE_TIMEOUT_CYCLES(1000),.LOCAL_RECOVERY_ENABLE(1),.NATIVE_GC16(1),
        .BOOT_WHITE_CLEAN(1),.BOOT_CLEAR_CYCLES(3),.BOOT_CYCLE_MIN_CYCLES(150),
        .RECOVERY_QUIET_FRAMES(2),.RECOVERY_MIN_PIXELS(64)) dut (
        .clk(clk),.rst_n(rst),.ready(1'b1),.hdmi_valid(link),.hdmi_signal_locked(link),
        .hdmi_frame_changed(1'b0),.captured_changed_pixels(measured),.manual_refresh(manual),
        .clear_done(cld),.capture_done(cd),.display_done(dd),.dma_idle(1'b1),
        .clear_start(cls),.capture_start(cs),.display_start(ds),.init_mode(init_mode),
        .white_only(white),.stripes(stripes),.capture_from_hdmi(hdmi),.local_recovery(repair));
    always @(posedge clk) if(rst) begin
        ticks=ticks+1;cd<=0;dd<=0;cld<=0;
        if(stripes) $fatal(1,"boot stripe regression");
        if(cs) begin
            if(display_age || capture_age) $fatal(1,"native captures while target still displayed");
            if(boot_count!=3 || ticks-boot_start<150) $fatal(1,"boot clean shorter than required");
            capture_age<=7;
        end else if(capture_age) begin
            capture_age<=capture_age-1;
            if(capture_age==1) begin cd<=1;measured<=changes;end
        end
        if(ds) begin
            if(capture_age || display_age) $fatal(1,"native display before capture is complete");
            display_age<=repair?44:32;
            if(init_mode && dut.boot_clean_pending) begin
                if(white) $fatal(1,"boot skipped full black/white reset sequence");
                if(boot_count && ticks-previous_boot<150) $fatal(1,"short boot cycle spacing");
                previous_boot=ticks;boot_start=ticks;boot_count=boot_count+1;
            end else if(init_mode) manual_count=manual_count+1;
            if(hdmi) hdmi_count=hdmi_count+1;
            if(repair) repair_count=repair_count+1;
        end else if(display_age) begin
            display_age<=display_age-1;
            if(display_age==1) dd<=1;
        end
        if(cls) clear_age<=4;
        else if(clear_age) begin
            clear_age<=clear_age-1;if(clear_age==1) cld<=1;
        end
    end
    initial begin
        #100;rst=1;wait(dut.state==10);
        if(boot_count!=3) $fatal(1,"wrong number of boot cleans");
        link=1;wait(hdmi_count>=4);
        if(repair_count || manual_count) $fatal(1,"recovery during motion");
        changes=0;wait(repair_count==1);
        mark=hdmi_count;wait(hdmi_count>=mark+6);
        if(repair_count!=1 || manual_count) $fatal(1,"static global/periodic refresh");
        @(negedge clk);manual=1;@(negedge clk);manual=0;
        wait(manual_count==1);wait(hdmi_count>=mark+8);
        // Preserve a recovery in progress even when qualification is lost.
        changes=128;mark=hdmi_count;wait(hdmi_count>=mark+3);changes=0;
        wait(repair_count==2);@(negedge clk);link=0;
        repeat(5) @(negedge clk);
        if(!repair) $fatal(1,"link loss changed an active LUT sequence");
        wait(!hdmi);wait(dut.state==10);
        $display("PASS GC16 manager: 3 complete minimum-duration boot cycles, immutable capture/display, one post-motion repair, static no global flashing, manual rebase and unplug");
        $finish;
    end
    initial begin #1000000;$fatal(1,"native manager timeout state=%0d",dut.state);end
endmodule
