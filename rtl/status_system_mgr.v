module status_system_mgr(
    input wire clk,
    input wire rst_n,
    input wire clear_request,
    input wire hdmi_status_valid,
    input wire hdmi_locked,
    // This changes only at a local-frame boundary.  It selects the initial
    // checkerboard versus the ordinary status-frame source.
    input wire boot_pattern_active,
    // Asserted only after one complete FRAME_H by FRAME_V HDMI frame.
    // This is the hand-off boundary between the local status source and
    // the HDMI pixel stream.
    input wire hdmi_capture_valid,
    input wire hdmi_status_changed,
    output reg w_gray_s_flag,
    input wire w_gray_fflag,
    output reg clr_s_flag,
    input wire clr_fflag,
    input wire epd_clk,
    input wire epd_rst_n,
    output reg epd_s_flag,
    input wire epd_fflag
    );

    localparam [3:0]
        WAIT_CLEAR = 4'd0,
        START_CLEAR = 4'd1,
        WAIT_CLEAR_DONE = 4'd2,
        START_BLACK_REFRESH = 4'd3,
        WAIT_BLACK_REFRESH = 4'd4,
        START_WHITE_REFRESH = 4'd5,
        WAIT_WHITE_REFRESH = 4'd6,
        WAIT_STATUS = 4'd7,
        START_CAPTURE = 4'd8,
        WAIT_CAPTURE = 4'd9,
        START_STATUS_REFRESH = 4'd10,
        WAIT_STATUS_REFRESH = 4'd11;

    reg [3:0] state;
    reg status_update_pending;
    reg status_seen;
    reg capture_after_clear;
    reg hdmi_capture_valid_d;
    reg boot_pattern_active_d;
    wire epd_fflag_pulse;

    sync_h2lck sync_epd_fflag (
        .in_clk(epd_clk),
        .out_clk(clk),
        .rst_n(epd_rst_n),
        .level_in(epd_fflag),
        .pulse_out(epd_fflag_pulse)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_CLEAR;
            w_gray_s_flag <= 1'b0;
            clr_s_flag <= 1'b0;
            epd_s_flag <= 1'b0;
            status_update_pending <= 1'b0;
            status_seen <= 1'b0;
            capture_after_clear <= 1'b0;
            hdmi_capture_valid_d <= 1'b0;
            boot_pattern_active_d <= 1'b0;
        end
        else begin
            w_gray_s_flag <= 1'b0;
            clr_s_flag <= 1'b0;
            epd_s_flag <= 1'b0;

            if (hdmi_status_valid && (!status_seen || hdmi_status_changed))
                status_update_pending <= 1'b1;
            if (hdmi_status_valid)
                status_seen <= 1'b1;

            // PLL lock alone is not enough to hand the writer over to HDMI:
            // wait until the timing qualifier has measured a complete frame.
            // A qualified-mode transition always gets a full panel clear so
            // that a stale status frame cannot mix with captured pixels.
            if (hdmi_capture_valid != hdmi_capture_valid_d)
                status_update_pending <= 1'b1;
            hdmi_capture_valid_d <= hdmi_capture_valid;

            // Request one clean recapture when the ten-second diagnostic
            // pattern finishes.  This prevents checkerboard/status mixing.
            if (boot_pattern_active != boot_pattern_active_d)
                status_update_pending <= 1'b1;
            boot_pattern_active_d <= boot_pattern_active;

            case (state)
                WAIT_CLEAR: begin
                    if (clear_request) begin
                        status_update_pending <= 1'b0;
                        status_seen <= 1'b0;
                        capture_after_clear <= 1'b0;
                        state <= START_CLEAR;
                    end
                end
                START_CLEAR: begin
                    clr_s_flag <= 1'b1;
                    state <= WAIT_CLEAR_DONE;
                end
                WAIT_CLEAR_DONE: begin
                    if (clr_fflag)
                        state <= START_BLACK_REFRESH;
                end
                // fdma_clear has prepared DATA_0 as all black and DATA_1 as
                // all white. Drive both complete frames to erase the panel,
                // rather than using the differential image path.
                START_BLACK_REFRESH: begin
                    epd_s_flag <= 1'b1;
                    state <= WAIT_BLACK_REFRESH;
                end
                WAIT_BLACK_REFRESH: begin
                    if (epd_fflag_pulse)
                        state <= START_WHITE_REFRESH;
                end
                START_WHITE_REFRESH: begin
                    epd_s_flag <= 1'b1;
                    state <= WAIT_WHITE_REFRESH;
                end
                WAIT_WHITE_REFRESH: begin
                    if (epd_fflag_pulse) begin
                        if (capture_after_clear)
                            state <= START_CAPTURE;
                        else
                            state <= WAIT_STATUS;
                    end
                end
                WAIT_STATUS: begin
                    if (hdmi_status_valid && status_update_pending) begin
                        status_update_pending <= 1'b0;
                        capture_after_clear <= 1'b1;
                        state <= START_CLEAR;
                    end
                end
                START_CAPTURE: begin
                    w_gray_s_flag <= 1'b1;
                    capture_after_clear <= 1'b0;
                    state <= WAIT_CAPTURE;
                end
                WAIT_CAPTURE: begin
                    if (w_gray_fflag)
                        state <= START_STATUS_REFRESH;
                end
                START_STATUS_REFRESH: begin
                    epd_s_flag <= 1'b1;
                    state <= WAIT_STATUS_REFRESH;
                end
                WAIT_STATUS_REFRESH: begin
                    if (epd_fflag_pulse) begin
                        if (status_update_pending) begin
                            status_update_pending <= 1'b0;
                            capture_after_clear <= 1'b1;
                            state <= START_CLEAR;
                    end
                    else if (hdmi_capture_valid) begin
                        // EPD refresh is the rate limiter. Capture the
                        // newest complete HDMI frame for the next pass.
                        state <= START_CAPTURE;
                        end
                        else begin
                            state <= WAIT_STATUS;
                        end
                    end
                end
                default: state <= WAIT_CLEAR;
            endcase
        end
    end

endmodule
