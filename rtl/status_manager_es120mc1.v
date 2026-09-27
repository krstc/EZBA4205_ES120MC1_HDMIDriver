module status_manager_es120mc1 #(
    parameter integer POWER_SETTLE_CYCLES = 5000000,
    parameter integer STRIPE_HOLD_CYCLES = 250000000,
    // At 25 Hz the source frame itself is only 40 ms, but the DDR capture
    // and mono conversion share the 50 MHz bus.  Allow several source frames
    // before declaring a capture dead; link loss is debounced at the top.
    parameter integer CAPTURE_TIMEOUT_CYCLES = 100000000,
    parameter integer BOOT_SCRUB_CYCLES = 3,
    // Give the panel a complete local status update for each HDMI diagnostic
    // stage before the pixel clock is switched to the external source.
    parameter integer HDMI_STAGE_CYCLES = 250000000,
    // Retained for source compatibility with older test benches. Static HDMI
    // content no longer starts a timed global refresh; only manual_refresh does.
    parameter integer STATIC_FRAME_LIMIT = 75,
    parameter integer LOCAL_RECOVERY_ENABLE = 0,
    parameter integer BOOT_WHITE_CLEAN = 0,
    parameter integer BOOT_CLEAR_CYCLES = 1,
    parameter integer BOOT_CYCLE_MIN_CYCLES = 0,
    parameter integer NATIVE_GC16 = 0,
    parameter integer HYBRID_REFRESH = 0,
    parameter integer FRAME_V = 1600,
    parameter integer REFINE_ROWS = 128,
    parameter integer RECOVERY_QUIET_FRAMES = 6,
    parameter integer RECOVERY_MIN_PIXELS = 16384
)(
    input wire clk, rst_n, ready, hdmi_valid, hdmi_signal_locked,
    input wire hdmi_frame_changed,
    input wire [22:0] captured_changed_pixels,
    input wire [22:0] captured_drive_pixels, captured_pending_pixels,
    input wire manual_refresh,
    input wire clear_done, capture_done, display_done, dma_idle,
    output reg clear_start, capture_start, display_start,
    output reg init_mode, white_only, stripes, capture_from_hdmi, datapath_run,
    output wire hdmi_fast_update,
    output reg local_recovery,
    output reg hybrid_fast, hybrid_refine,
    output reg [11:0] refine_y,
    output reg [1:0] status_mode
);
    localparam POWER=0, CLEAR=1, INIT_START=2, INIT_WAIT=3,
               SOURCE_SETTLE=4, CAPTURE_START=5, CAPTURE_WAIT=6,
               DISPLAY_START=7, DISPLAY_WAIT=8, HOLD=9, IDLE=10,
               DRAIN=11, RESET_PIPE=12, HDMI_IN_HOLD=13, HDMI_INFO_HOLD=14,
               HDMI_PIPE_WAIT=15;
    reg [3:0] state;
    reg [31:0] timer;
    reg [2:0] scrub_remaining;
    reg diagnostic_shown;
    reg hdmi_primed;
    reg pipe_capture_seen;
    reg pipe_display_seen;
    reg manual_refresh_pending;
    reg rebase_hdmi_pending;
    reg boot_clean_pending;
    reg [7:0] quiet_frames;
    reg recovery_debt, recovery_ready;
    reg init_done_seen;
    reg refine_sweep;
    assign hdmi_fast_update = capture_from_hdmi && hdmi_primed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= POWER; timer <= 0;
            scrub_remaining <= BOOT_WHITE_CLEAN ? BOOT_CLEAR_CYCLES : 0;
            init_done_seen <= 0;
            clear_start <= 0; capture_start <= 0; display_start <= 0;
            // Do not put a high-contrast test pattern on the panel at boot.
            // Rebase DDR and, when enabled, the retained physical image to
            // white before assuming that unchanged white pixels need no drive.
            init_mode <= BOOT_WHITE_CLEAN; white_only <= !NATIVE_GC16; stripes <= 0; capture_from_hdmi <= 0;
            datapath_run <= 1; status_mode <= 2'd0; diagnostic_shown <= 1'b0;
            hdmi_primed <= 1'b0;
            pipe_capture_seen <= 1'b0; pipe_display_seen <= 1'b0;
            manual_refresh_pending <= 1'b0;
            rebase_hdmi_pending <= 1'b0;
            boot_clean_pending <= BOOT_WHITE_CLEAN;
            quiet_frames <= 0;
            recovery_debt <= 0;
            recovery_ready <= 0;
            local_recovery <= 0;
            hybrid_fast<=0;hybrid_refine<=0;refine_y<=0;refine_sweep<=0;
        end else begin
            clear_start <= 0; capture_start <= 0; display_start <= 0;
            if (manual_refresh)
                manual_refresh_pending <= 1'b1;
            // Use the exact old/new comparison of the captured DDR frame,
            // not the sparse hash of an independently arriving source frame.
            if (!capture_from_hdmi || !hdmi_valid || !hdmi_signal_locked) begin
                quiet_frames <= 0;
                recovery_debt <= 0;
                recovery_ready <= 0;
                refine_sweep <= 0;
                if (!NATIVE_GC16 || state != HDMI_PIPE_WAIT) local_recovery <= 0;
            end else if ((LOCAL_RECOVERY_ENABLE || HYBRID_REFRESH) && capture_done) begin
                // Ignore cursor-sized changes when waiting for scrolling to
                // stop. A blinking caret must not starve a pending recovery.
                if (captured_changed_pixels >= RECOVERY_MIN_PIXELS) begin
                    quiet_frames <= 0;
                    recovery_ready <= 0;
                    recovery_debt <= 1;
                end else if (quiet_frames < RECOVERY_QUIET_FRAMES) begin
                    quiet_frames <= quiet_frames+1'b1;
                    if (!HYBRID_REFRESH && quiet_frames == RECOVERY_QUIET_FRAMES-1 && recovery_debt)
                        recovery_ready <= 1;
                end
                if(HYBRID_REFRESH && captured_pending_pixels!=0) recovery_debt<=1;
            end
            case (state)
                POWER: if (!ready) timer <= 0;
                       else if (timer == POWER_SETTLE_CYCLES-1) begin
                           timer <= 0; clear_start <= 1; state <= CLEAR;
                       end else timer <= timer+1'b1;
                CLEAR: if (clear_done) begin
                    if (rebase_hdmi_pending) begin
                        // DDR now matches the manually cleaned white panel.
                        // Re-enter a qualified HDMI source directly and force
                        // the first rebuilt frame through the full DU5 path.
                        rebase_hdmi_pending <= 1'b0;
                        capture_from_hdmi <= hdmi_signal_locked && hdmi_valid;
                        hdmi_primed <= 1'b0;
                        status_mode <= (hdmi_signal_locked && !hdmi_valid) ?
                                       2'd2 : 2'd0;
                        diagnostic_shown <= hdmi_signal_locked;
                        timer <= 0;
                        state <= SOURCE_SETTLE;
                    end else if (init_mode) begin
                        // Cold start and runtime link loss align the physical
                        // panel with the white state stored in both buffers.
                        state <= INIT_START;
                    end else begin
                        // Cold boot skips all physical stripe/scrub scans. Go
                        // directly to signal detection after the DDR rebase.
                        stripes <= 0;
                        capture_from_hdmi <= 0;
                        if (hdmi_signal_locked) begin
                            status_mode <= 2'd1;
                            diagnostic_shown <= 1'b1;
                        end else begin
                            status_mode <= 2'd0;
                            diagnostic_shown <= 1'b0;
                        end
                        timer <= 0;
                        state <= SOURCE_SETTLE;
                    end
                end
                INIT_START: begin
                    display_start <= 1; state <= INIT_WAIT; timer <= 0; init_done_seen <= 0;
                end
                INIT_WAIT: begin
                    if (display_done) init_done_seen <= 1;
                    if (timer < BOOT_CYCLE_MIN_CYCLES) timer <= timer+1'b1;
                    if ((display_done || init_done_seen) &&
                        (!boot_clean_pending || timer >= BOOT_CYCLE_MIN_CYCLES)) begin
                    if (scrub_remaining > 1) begin
                        scrub_remaining <= scrub_remaining - 1'b1;
                        state <= INIT_START;
                    end else begin
                        scrub_remaining <= 0;
                        init_mode <= 0;
                        if (boot_clean_pending) begin
                            boot_clean_pending <= 0;
                            status_mode <= hdmi_signal_locked ? 2'd1 : 2'd0;
                            diagnostic_shown <= hdmi_signal_locked;
                            timer <= 0;
                            state <= SOURCE_SETTLE;
                        end else if (rebase_hdmi_pending) begin
                            // Start a DDR rebase after the physical clean so
                            // both stored frame buffers again describe white.
                            white_only <= 0;
                            clear_start <= 1;
                            state <= CLEAR;
                        end else begin
                            timer <= 0; state <= SOURCE_SETTLE;
                        end
                    end
                end
                end
                // Clock selection and data selection settle before the capture
                // command; the writer itself then waits for the NEXT frame VS.
                SOURCE_SETTLE: if (timer == 63) begin timer <= 0; state <= CAPTURE_START; end
                               else timer <= timer+1'b1;
                CAPTURE_START: begin
                    capture_start <= 1; timer <= 0; state <= CAPTURE_WAIT;
                    if(HYBRID_REFRESH) begin
                        hybrid_refine <= capture_from_hdmi && recovery_debt &&
                                         quiet_frames>=RECOVERY_QUIET_FRAMES;
                        hybrid_fast <= capture_from_hdmi && !(recovery_debt &&
                                       quiet_frames>=RECOVERY_QUIET_FRAMES);
                        if(!refine_sweep) refine_y<=0;
                    end
                end
                CAPTURE_WAIT: if (capture_from_hdmi && !hdmi_signal_locked) begin
                        timer <= 0; state <= DRAIN;
                    end else if (capture_done) begin
                        if (NATIVE_GC16 && !HYBRID_REFRESH && capture_from_hdmi) begin
                            local_recovery <= LOCAL_RECOVERY_ENABLE && recovery_ready &&
                                              captured_changed_pixels < RECOVERY_MIN_PIXELS;
                            if (LOCAL_RECOVERY_ENABLE && recovery_ready &&
                                captured_changed_pixels < RECOVERY_MIN_PIXELS) begin
                                recovery_debt <= 0; recovery_ready <= 0; quiet_frames <= 0;
                            end
                        end
                        if(HYBRID_REFRESH && capture_from_hdmi && captured_drive_pixels==0) begin
                            // No panel scan and no synthetic display-done event.
                            // Both capture pointers already refer to the new history.
                            pipe_capture_seen<=1;pipe_display_seen<=1;timer<=0;
                            state<=HDMI_PIPE_WAIT;
                        end else state <= DISPLAY_START;
                    end
                    else if (timer == CAPTURE_TIMEOUT_CYCLES-1 ||
                             (capture_from_hdmi && !hdmi_valid)) begin
                        timer <= 0; state <= DRAIN;
                    end else timer <= timer+1'b1;
                DISPLAY_START: begin
                    display_start <= 1;
                    if (capture_from_hdmi) begin
                        // The data buffers are already double-buffered. Capture
                        // the next HDMI frame while the panel scans this one.
                        // Native GC16 must finish against an immutable target
                        // before capturing the next frame or changing history.
                        capture_start <= !NATIVE_GC16;
                        pipe_capture_seen <= NATIVE_GC16;
                        pipe_display_seen <= 0;
                        timer <= 0;
                        state <= HDMI_PIPE_WAIT;
                    end else state <= DISPLAY_WAIT;
                end
                DISPLAY_WAIT: if (display_done) begin
                    timer <= 0;
                    if (!stripes && status_mode == 2'd1)
                        state <= HDMI_IN_HOLD;
                    else if (!stripes && status_mode == 2'd2)
                        state <= HDMI_INFO_HOLD;
                    else
                        state <= stripes ? HOLD : IDLE;
                end
                HOLD: if (timer == STRIPE_HOLD_CYCLES-1) begin
                    timer <= 0; stripes <= 0;
                    if (hdmi_signal_locked && !diagnostic_shown) begin
                        // Keep the verified direct hand-off when HDMI is already
                        // present. The first HDMI image is deliberately unprimed,
                        // so display_mgr drives the full PERIOD_CNT scans and
                        // physically replaces the startup stripes.
                        capture_from_hdmi <= 0;
                        status_mode <= 2'd1;
                        diagnostic_shown <= 1'b1;
                        state <= SOURCE_SETTLE;
                    end
                    else begin
                        // With no HDMI source, align the physical white state and
                        // both stored gray frames before showing NO SIGNAL.
                        init_mode <= 1; white_only <= 0;
                        scrub_remaining <= BOOT_SCRUB_CYCLES[2:0];
                        clear_start <= 1; state <= CLEAR;
                    end
                end else timer <= timer+1'b1;
                IDLE: begin
                    if (manual_refresh_pending) begin
                        // A complete white clean is intentionally user-driven.
                        // Rebase DDR afterwards so old/new comparisons match
                        // the new physical white panel state.
                        manual_refresh_pending <= 1'b0;
                        local_recovery <= 0;
                        rebase_hdmi_pending <= 1'b1;
                        capture_from_hdmi <= 1'b0;
                        hdmi_primed <= 1'b0;
                        init_mode <= 1'b1;
                        white_only <= 1'b1;
                        scrub_remaining <= 0;
                        status_mode <= 2'd0;
                        timer <= 0;
                        state <= INIT_START;
                    end
                    else if (capture_from_hdmi && hdmi_valid) begin
                        status_mode <= 2'd0;
                        state <= CAPTURE_START;
                    end
                    else if (capture_from_hdmi && !hdmi_valid) begin
                        capture_from_hdmi <= 0;
                        hdmi_primed <= 0;
                        status_mode <= 2'd0;
                        diagnostic_shown <= 1'b0;
                        init_mode <= 1; white_only <= 1;
                        clear_start <= 1; state <= CLEAR;
                    end
                    else if (hdmi_signal_locked && !diagnostic_shown) begin
                        capture_from_hdmi <= 0;
                        status_mode <= 2'd1;
                        diagnostic_shown <= 1'b1;
                        state <= SOURCE_SETTLE;
                    end
                    else if (hdmi_signal_locked && hdmi_valid && !capture_from_hdmi) begin
                        // The two diagnostic frames are mandatory even when
                        // the parallel video qualified early. Once they have
                        // completed, a valid frame may take over directly.
                        capture_from_hdmi <= 1;
                        hdmi_primed <= 0;
                        status_mode <= 2'd0;
                        state <= SOURCE_SETTLE;
                    end
                    else if (hdmi_signal_locked && diagnostic_shown) begin
                        // A locked TMDS clock without a complete parallel
                        // frame must keep the diagnostic frame visible. Do
                        // not clear status_mode while waiting for VS/DE.
                        capture_from_hdmi <= 0;
                        status_mode <= 2'd2;
                    end
                    else if (diagnostic_shown) begin
                        diagnostic_shown <= 1'b0;
                        hdmi_primed <= 0;
                        status_mode <= 2'd0;
                        init_mode <= 1; white_only <= 1;
                        clear_start <= 1; state <= CLEAR;
                    end
                end
                HDMI_IN_HOLD: if (!hdmi_signal_locked) begin
                        diagnostic_shown <= 1'b0;
                        hdmi_primed <= 0;
                        status_mode <= 2'd0;
                        init_mode <= 1; white_only <= 1;
                        clear_start <= 1; state <= CLEAR;
                    end
                    else if (timer == HDMI_STAGE_CYCLES-1) begin
                        timer <= 0;
                        status_mode <= 2'd2;
                        state <= SOURCE_SETTLE;
                    end
                    else timer <= timer + 1'b1;
                HDMI_INFO_HOLD: if (!hdmi_signal_locked) begin
                        diagnostic_shown <= 1'b0;
                        hdmi_primed <= 0;
                        status_mode <= 2'd0;
                        init_mode <= 1; white_only <= 1;
                        clear_start <= 1; state <= CLEAR;
                    end
                    else if (timer == HDMI_STAGE_CYCLES-1 && hdmi_valid) begin
                        timer <= 0;
                        // Keep observing the live qualification after the
                        // information hold. Never accept TMDS lock alone as
                        // evidence of a complete, safe-to-display frame.
                        status_mode <= 2'd0;
                        capture_from_hdmi <= 1;
                        hdmi_primed <= 0;
                        state <= SOURCE_SETTLE;
                    end
                    else if (timer < HDMI_STAGE_CYCLES-1) timer <= timer + 1'b1;
                HDMI_PIPE_WAIT: begin
                    if (capture_done)
                        pipe_capture_seen <= 1'b1;
                    if (display_done) begin
                        pipe_display_seen <= 1'b1;
                        if (hdmi_valid && hdmi_signal_locked)
                            hdmi_primed <= 1'b1;
                    end
                    if (!hdmi_valid || !hdmi_signal_locked ||
                        timer == CAPTURE_TIMEOUT_CYCLES-1) begin
                        // Let the active panel scan finish and wait until AXI
                        // has drained before resetting a stopped pixel clock.
                        if ((pipe_display_seen || display_done) && dma_idle) begin
                            timer <= 0;
                            state <= DRAIN;
                        end else if (timer < CAPTURE_TIMEOUT_CYCLES-1)
                            timer <= timer + 1'b1;
                    end else if ((pipe_capture_seen || capture_done) &&
                                 (pipe_display_seen || display_done)) begin
                        if (manual_refresh_pending) begin
                            // Finish the active fast-DU update before the manual
                            // white clean and full DU5 framebuffer rebuild.
                            manual_refresh_pending <= 1'b0;
                            local_recovery <= 0;
                            rebase_hdmi_pending <= 1'b1;
                            capture_from_hdmi <= 0;
                            hdmi_primed <= 0;
                            init_mode <= 1;
                            white_only <= 1;
                            scrub_remaining <= 0;
                            status_mode <= 2'd0;
                            timer <= 0;
                            state <= INIT_START;
                        end else begin
                            if(HYBRID_REFRESH && hybrid_refine) begin
                                if(captured_changed_pixels>=RECOVERY_MIN_PIXELS) begin
                                    refine_sweep<=0;refine_y<=0;
                                end else if(refine_y+REFINE_ROWS>=FRAME_V) begin
                                    refine_sweep<=0;refine_y<=0;
                                    recovery_debt<=0;quiet_frames<=0;
                                end else begin
                                    refine_sweep<=1;refine_y<=refine_y+REFINE_ROWS;
                                end
                            end
                            // Select the already-complete pending frame. Both
                            // capture and display must finish before changing
                            // its waveform or recycling either DDR buffer.
                            local_recovery <= !NATIVE_GC16 && LOCAL_RECOVERY_ENABLE && recovery_ready &&
                                              (captured_changed_pixels < RECOVERY_MIN_PIXELS);
                            if (!NATIVE_GC16 && LOCAL_RECOVERY_ENABLE && recovery_ready &&
                                captured_changed_pixels < RECOVERY_MIN_PIXELS) begin
                                recovery_debt <= 0;
                                recovery_ready <= 0;
                                quiet_frames <= 0;
                            end
                            timer <= 0;
                            state <= NATIVE_GC16 ? CAPTURE_START : DISPLAY_START;
                        end
                    end else timer <= timer + 1'b1;
                end
                // An unplug can stop pix_clk mid-frame. Never display that
                // partial frame or reset AXI with an outstanding transaction.
                DRAIN: if (!dma_idle) timer <= 0;
                       else if (timer == 63) begin
                           datapath_run <= 0; capture_from_hdmi <= 0;
                           hdmi_primed <= 0;
                           timer <= 0; state <= RESET_PIPE;
                       end else timer <= timer+1'b1;
                RESET_PIPE: if (timer == 127) begin
                    if (!NATIVE_GC16 && diagnostic_shown && hdmi_signal_locked) begin
                        // A failed HDMI capture must not leave the panel in
                        // a blank waiting state. Re-render the information
                        // frame locally, then retry the HDMI hand-off.
                        datapath_run <= 1; init_mode <= 0; white_only <= 0;
                        capture_from_hdmi <= 0; stripes <= 0;
                        status_mode <= 2'd2;
                        timer <= 0; state <= SOURCE_SETTLE;
                    end
                    else begin
                        datapath_run <= 1; init_mode <= 1; white_only <= !stripes;
                        status_mode <= 2'd0; diagnostic_shown <= 1'b0;
                        timer <= 0; state <= POWER;
                    end
                end else timer <= timer+1'b1;
                default: state <= POWER;
            endcase
        end
    end
endmodule
