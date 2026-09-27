`timescale 1ns/1ps
module es120_boot_hdmi_present_tb;
    reg clk=0, rst_n=0, ready=1;
    reg hdmi_valid=1, hdmi_signal_locked=1;
    reg clear_done=0, capture_done=0, display_done=0, dma_idle=1;
    always #10 clk=~clk;

    wire clear_start, capture_start, display_start;
    wire init_mode, white_only, stripes, capture_from_hdmi, datapath_run;
    wire hdmi_fast_update;
    wire [1:0] status_mode;

    status_manager_es120mc1 #(
        .POWER_SETTLE_CYCLES(4), .STRIPE_HOLD_CYCLES(8),
        .CAPTURE_TIMEOUT_CYCLES(1000), .BOOT_SCRUB_CYCLES(3),
        .HDMI_STAGE_CYCLES(8), .BOOT_WHITE_CLEAN(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .ready(ready),
        .hdmi_valid(hdmi_valid), .hdmi_signal_locked(hdmi_signal_locked),
        .hdmi_frame_changed(1'b1),
        .manual_refresh(1'b0),
        .clear_done(clear_done), .capture_done(capture_done),
        .display_done(display_done), .dma_idle(dma_idle),
        .clear_start(clear_start), .capture_start(capture_start),
        .display_start(display_start), .init_mode(init_mode),
        .white_only(white_only), .stripes(stripes),
        .capture_from_hdmi(capture_from_hdmi), .datapath_run(datapath_run),
        .hdmi_fast_update(hdmi_fast_update), .status_mode(status_mode)
    );

    integer clear_delay=0, capture_delay=0, display_delay=0;
    integer hdmi_displays=0, white_cleans=0;
    reg saw_direct_handoff=0;
    always @(posedge clk) begin
        clear_done <= 0;
        capture_done <= 0;
        display_done <= 0;

        if (clear_start) clear_delay <= 2;
        else if (clear_delay > 0) begin
            clear_delay <= clear_delay-1;
            if (clear_delay == 1) clear_done <= 1;
        end
        if (capture_start) capture_delay <= 3;
        else if (capture_delay > 0) begin
            capture_delay <= capture_delay-1;
            if (capture_delay == 1) capture_done <= 1;
        end
        if (display_start) display_delay <= 4;
        else if (display_delay > 0) begin
            display_delay <= display_delay-1;
            if (display_delay == 1) display_done <= 1;
        end

        if (rst_n && stripes)
            $fatal(1,"startup stripes were re-enabled");
        if (display_start && init_mode) begin
            if(!white_only) $fatal(1,"boot must not flash black");
            white_cleans <= white_cleans+1;
        end

        if (capture_start && !capture_from_hdmi && status_mode == 2'd1) begin
            if (clear_start)
                $fatal(1,"HDMI-at-boot restarted the non-reentrant DDR clear path");
            saw_direct_handoff <= 1;
        end

        if (capture_from_hdmi && display_start) begin
            hdmi_displays <= hdmi_displays+1;
            if (hdmi_displays == 0 && hdmi_fast_update)
                $fatal(1,"first HDMI frame was not fully primed");
            if (hdmi_displays == 1 && !hdmi_fast_update)
                $fatal(1,"fast HDMI mode did not start after priming");
            if (hdmi_displays == 1) begin
                if(white_cleans != 1) $fatal(1,"missing or repeated power-on white alignment");
                if (!saw_direct_handoff)
                    $fatal(1,"HDMI started without the verified diagnostic handoff");
                $display("PASS HDMI-at-boot: one white alignment, no stripes, diagnostics and complete HDMI DU5");
                $finish;
            end
        end
    end

    initial begin
        #100; rst_n=1;
    end
    initial begin
        #200000; $fatal(1,"HDMI-at-boot timeout state=%0d hdmi=%0d",
                         dut.state, hdmi_displays);
    end
endmodule
