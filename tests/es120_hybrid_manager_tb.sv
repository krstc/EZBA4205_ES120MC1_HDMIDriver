`timescale 1ns/1ps
module es120_hybrid_manager_tb;
    reg clk=0,rst=0,link=0,manual=0,moving=1,needs_gray=1;
    always #10 clk=~clk;
    reg cd=0,dd=0,cld=0;
    reg [22:0] changes=0,drives=0,pending=0;
    wire cs,ds,cls,init_mode,white,hdmi,repair,stripes,fast,refine;
    wire [11:0] band;
    integer ca=0,da=0,cla=0,ticks=0,boots=0,manuals=0,fasts=0,refines=0,captures=0;
    integer boot_start=0,mark=0,mark_c=0;
    reg [11:0] last_band=0;
    reg held_fast,held_refine;
    status_manager_es120mc1 #(.POWER_SETTLE_CYCLES(2),.HDMI_STAGE_CYCLES(5),
        .CAPTURE_TIMEOUT_CYCLES(1000),.LOCAL_RECOVERY_ENABLE(0),.NATIVE_GC16(1),
        .HYBRID_REFRESH(1),.FRAME_V(1600),.REFINE_ROWS(128),
        .BOOT_WHITE_CLEAN(1),.BOOT_CLEAR_CYCLES(3),.BOOT_CYCLE_MIN_CYCLES(150),
        .RECOVERY_QUIET_FRAMES(3),.RECOVERY_MIN_PIXELS(64)) dut (
        .clk(clk),.rst_n(rst),.ready(1'b1),.hdmi_valid(link),.hdmi_signal_locked(link),
        .hdmi_frame_changed(1'b0),.captured_changed_pixels(changes),.manual_refresh(manual),
        .captured_drive_pixels(drives),.captured_pending_pixels(pending),
        .hybrid_fast(fast),.hybrid_refine(refine),.refine_y(band),
        .clear_done(cld),.capture_done(cd),.display_done(dd),.dma_idle(1'b1),
        .clear_start(cls),.capture_start(cs),.display_start(ds),.init_mode(init_mode),
        .white_only(white),.stripes(stripes),.capture_from_hdmi(hdmi),.local_recovery(repair));
    always @(posedge clk) if(rst) begin
        ticks++;cd<=0;dd<=0;cld<=0;
        if(stripes || repair) $fatal(1,"hybrid enabled startup stripes or automatic W10 recovery");
        if(cs) begin
            if(ca || da) $fatal(1,"capture overwrote active waveform");
            if(boots!=3 || ticks-boot_start<150) $fatal(1,"boot clean shortened");
            ca<=7;captures++;held_fast=fast;held_refine=refine;
        end else if(ca) begin
            ca<=ca-1;
            if(ca==1) begin
                cd<=1;changes<=moving?128:0;
                drives<=!hdmi || moving || (refine && needs_gray)?128:0;
                pending<=needs_gray && !(refine && band==1536)?128:0;
            end
        end
        if(ds) begin
            if(ca || da) $fatal(1,"display started before capture committed");
            if(hdmi && (held_fast!=fast || held_refine!=refine)) $fatal(1,"mode changed after capture");
            da<=fast?7:32;
            if(init_mode && dut.boot_clean_pending) begin boots++;boot_start=ticks;end
            else if(init_mode) begin manuals++;needs_gray=1;end
            if(hdmi && fast) fasts++;
            if(hdmi && refine) begin
                if(refines%13!=0 && band!=last_band+128) $fatal(1,"skipped refinement band");
                last_band=band;refines++;
            end
        end else if(da) begin
            da<=da-1;
            if(da==1) begin dd<=1;if(refine && band==1536) needs_gray=0;end
        end
        if(cls) cla<=4;
        else if(cla) begin cla<=cla-1;if(cla==1) cld<=1;end
    end
    initial begin
        #100;rst=1;wait(dut.state==10);
        link=1;wait(fasts>=5);
        if(refines || manuals) $fatal(1,"long recovery during motion");
        moving=0;wait(refines==13);wait(!needs_gray);repeat(60) @(negedge clk);
        mark=fasts+refines;mark_c=captures;
        wait(captures>=mark_c+200);
        if(fasts+refines!=mark || manuals) $fatal(1,"static display auto-refreshed");
        @(negedge clk);manual=1;@(negedge clk);manual=0;
        wait(manuals==1);wait(refines==26);wait(!needs_gray);
        moving=1;wait(fasts>=8);moving=0;needs_gray=1;
        wait(refines==27);@(negedge clk);link=0;
        repeat(5) @(negedge clk);
        if(!refine || band!=0) $fatal(1,"unplug changed active native waveform");
        wait(!hdmi);wait(dut.state==10);
        $display("PASS hybrid manager: boot 3x3s model, fast motion, skipped no-op frames, 13 bounded bands, 200 static captures without scans, queued manual rebase and unplug");
        $finish;
    end
    initial begin #2000000;$fatal(1,"hybrid manager timeout state=%0d captures=%0d fast=%0d refine=%0d",dut.state,captures,fasts,refines);end
endmodule
