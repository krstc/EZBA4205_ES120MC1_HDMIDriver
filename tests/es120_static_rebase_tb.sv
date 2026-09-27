`timescale 1ns/1ps
module es120_static_rebase_tb;
    reg clk=0, rst_n=0, ready=1;
    reg hdmi_valid=1, hdmi_signal_locked=1, hdmi_frame_changed=1;
    reg manual_refresh=0;
    reg clear_done=0, capture_done=0, display_done=0, dma_idle=1;
    always #10 clk=~clk;

    wire clear_start, capture_start, display_start;
    wire init_mode, white_only, stripes, capture_from_hdmi, datapath_run;
    wire hdmi_fast_update;
    wire [1:0] status_mode;

    status_manager_es120mc1 #(
        .POWER_SETTLE_CYCLES(2), .STRIPE_HOLD_CYCLES(2),
        .CAPTURE_TIMEOUT_CYCLES(1000), .BOOT_SCRUB_CYCLES(1),
        .HDMI_STAGE_CYCLES(2), .STATIC_FRAME_LIMIT(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .ready(ready),
        .hdmi_valid(hdmi_valid), .hdmi_signal_locked(hdmi_signal_locked),
        .hdmi_frame_changed(hdmi_frame_changed),
        .manual_refresh(manual_refresh),
        .clear_done(clear_done), .capture_done(capture_done),
        .display_done(display_done), .dma_idle(dma_idle),
        .clear_start(clear_start), .capture_start(capture_start),
        .display_start(display_start), .init_mode(init_mode),
        .white_only(white_only), .stripes(stripes),
        .capture_from_hdmi(capture_from_hdmi), .datapath_run(datapath_run),
        .hdmi_fast_update(hdmi_fast_update), .status_mode(status_mode)
    );

    integer clear_delay=0, capture_delay=0, display_delay=0;
    integer hdmi_displays=0, white_cleans=0, clear_starts=0;
    reg saw_manual_full_rebuild=0, saw_fast_after_rebuild=0;

    always @(posedge clk) begin
        clear_done <= 0;
        capture_done <= 0;
        display_done <= 0;

        if (clear_start) begin
            clear_delay <= 2;
            clear_starts <= clear_starts+1;
        end else if (clear_delay > 0) begin
            clear_delay <= clear_delay-1;
            if (clear_delay == 1) clear_done <= 1;
        end

        if (capture_start) capture_delay <= 3;
        else if (capture_delay > 0) begin
            capture_delay <= capture_delay-1;
            if (capture_delay == 1) capture_done <= 1;
        end

        if (display_start) begin
            display_delay <= 4;
            if (init_mode && white_only)
                white_cleans <= white_cleans+1;
            if (capture_from_hdmi) begin
                hdmi_displays <= hdmi_displays+1;
                if (white_cleans == 1 && !saw_manual_full_rebuild) begin
                    if (hdmi_fast_update)
                        $fatal(1,"manual rebuild skipped the full DU5 prime");
                    saw_manual_full_rebuild <= 1;
                end else if (saw_manual_full_rebuild && hdmi_fast_update) begin
                    saw_fast_after_rebuild <= 1;
                end
            end
        end else if (display_delay > 0) begin
            display_delay <= display_delay-1;
            if (display_delay == 1) display_done <= 1;
        end

        if (hdmi_displays >= 2)
            hdmi_frame_changed <= 0;
        if (white_cleans > 1)
            $fatal(1,"one manual key press caused multiple white cleans");
    end

    initial begin
        #100; rst_n=1;
        wait(hdmi_displays >= 8);
        if (white_cleans != 0 || clear_starts != 1)
            $fatal(1,"static HDMI content started an automatic global refresh");

        @(negedge clk); manual_refresh=1;
        @(negedge clk); manual_refresh=0;
        wait(saw_manual_full_rebuild && saw_fast_after_rebuild);
        if (white_cleans != 1 || clear_starts != 2)
            $fatal(1,"manual refresh did not perform one white clean and DDR rebase");
        $display("PASS manual rebase: static content never auto-cleans; one key press performs white clean, DDR rebase and DU5 rebuild");
        $finish;
    end
    initial begin
        #500000; $fatal(1,"manual rebase timeout state=%0d hdmi_displays=%0d cleans=%0d clears=%0d",
                         dut.state, hdmi_displays, white_cleans, clear_starts);
    end
endmodule
