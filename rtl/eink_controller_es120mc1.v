module eink_controller_es120mc1 #(
    parameter SYS_CLK_FREQ = 50,
    parameter SCL_FREQ = 200,
    parameter DELAY_CNT = 32'h00FFFFFF,
    parameter VCOM = 1600,
    parameter EPD_WID = 16,
    parameter EPD_FREQ = 12,
    parameter EPD_H = 2560,
    parameter EPD_V = 1600,
    parameter PERIOD_CNT = 5,
    parameter HDMI_DU_PHASES = 5,
    parameter HDMI_FULL_PHASES = 5,
    parameter tFdly = 0,
    parameter tLEdly = 450,
    parameter tLEw = 300,
    parameter tLEoff = 200,
    parameter MAX_H = 2560,
    parameter MAX_V = 1600,
    parameter FRAME_H = 2560,
    parameter FRAME_V = 1600,
    parameter HDMI_H = 2560,
    parameter FDMA_WID = 64,
    parameter GRAY_SIZE = 4,
    parameter DATA_SIZE = 4,
    parameter TEXTURE_ADDR_MEM_OFFSET = 32'h0F100000,
    parameter GRAY_0_ADDR_MEM_OFFSET = 32'h0F500000,
    parameter GRAY_1_ADDR_MEM_OFFSET = 32'h0F900000,
    parameter DATA_0_ADDR_MEM_OFFSET = 32'h0E800000,
    parameter DATA_1_ADDR_MEM_OFFSET = 32'h0EC00000,
    // Optional local-only diagnostic; normal builds accept qualified HDMI.
    parameter DIAGNOSTIC_LOCAL_ONLY = 0
    )(
    inout wire sda,
    output wire scl,
    output wire video_card_rst_n,
    output wire epd_dir,
    output wire epd_pwr_en,
    output wire EPD_SKV,
    output wire EPD_SPV,
    output wire EPD_XCL,
    output wire EPD_XLE,
    output wire EPD_XSTL,
    output wire [EPD_WID - 1:0] EPD_DOUT,
    input wire hs_i,
    input wire vs_i,
    input wire de_i,
    input wire pix_clk,
    input wire [7:0] gray_i,
    input wire manual_refresh_n,
    input wire mode_key_n
    );

    initial begin
        if (MAX_H < FRAME_H || MAX_H < EPD_H || MAX_V < FRAME_V || MAX_V < EPD_V)
            $error("Framebuffer stride/height must contain the complete capture and panel");
    end

    wire w_gray_busy;
    wire w_gray_fflag;
    wire clr_fflag;
    wire [FDMA_WID - 1:0] r_data_fifo_out;
    wire CLK_50M;
    wire GPIO_O;
    wire [7:0] period_cnt;
    wire epd_busy;
    wire epd_busy_50m;
    wire epd_fflag;
    wire r_data_flag;
    wire r_data_fifo_ren;
    wire w_gray_s_flag;
    wire clr_s_flag;
    wire epd_clk;
    wire epd_s_flag;
    (* MARK_DEBUG = "TRUE" *) wire cfg_done;
    (* MARK_DEBUG = "TRUE" *) wire cfg_failed;
    (* MARK_DEBUG = "TRUE" *) wire [8:0] cfg_error_index;
    (* MARK_DEBUG = "TRUE" *) wire [1:0] cfg_attempt;
    (* MARK_DEBUG = "TRUE" *) wire cfg_write_failed;
    (* MARK_DEBUG = "TRUE" *) wire [8:0] cfg_write_error_index;
    (* MARK_DEBUG = "TRUE" *) wire [7:0] verify_read_address;
    (* MARK_DEBUG = "TRUE" *) wire verify_read_ack_error;
    (* MARK_DEBUG = "TRUE" *) wire [7:0] verify_read_data;
    (* MARK_DEBUG = "TRUE" *) wire i2c_ack_error_debug;
    (* MARK_DEBUG = "TRUE" *) wire i2c_busy_debug;
    (* MARK_DEBUG = "TRUE" *) wire hdmi_locked;
    (* MARK_DEBUG = "TRUE" *) wire hdmi_status_valid;
    (* MARK_DEBUG = "TRUE" *) wire hdmi_status_changed;
    wire edid_verified, hdmi_frequency_valid, hdmi_rate_valid;
    wire [7:0] hdmi_status_byte;
    wire [15:0] hdmi_tmds_q7;
    wire [31:0] hdmi_frame_period;
    wire [55:0] hdmi_io_config;
    wire [6:0] hdmi_io_config_valid;
    wire [8:0] REG_INDEX;
    wire [39:0] REG_DATA;
    wire [8:0] REG_SIZE;
    wire p_clr_flag;
    wire [16:0] hdmi_path_debug;
    wire [1:0] status_mode;
    wire [25:0] receiver_debug_command;
    wire [9:0] receiver_debug_response;
    wire clk_50m;

`ifdef EDID_ILA
    localparam RECEIVER_DEBUG_ACCESS = 1;
    adv7611_debug_vio receiver_vio (
        .clk(clk_50m), .probe_out0(receiver_debug_command),
        .probe_in0(receiver_debug_response)
    );
    // Eight 128-cycle slots fit in one 1024-sample ILA capture.
    reg [9:0] receiver_debug_slot = 0;
    reg [7:0] receiver_debug_pix_div = 0;
    (* ASYNC_REG = "TRUE" *) reg [3:0] receiver_debug_sync0 = 0;
    (* ASYNC_REG = "TRUE" *) reg [3:0] receiver_debug_sync1 = 0;
    (* ASYNC_REG = "TRUE" *) reg [11:0] receiver_pin_sync0 = 0;
    (* ASYNC_REG = "TRUE" *) reg [11:0] receiver_pin_sync1 = 0;
    reg [16:0] receiver_debug_data;
    always @(posedge pix_clk) receiver_debug_pix_div <= receiver_debug_pix_div + 1'b1;
    always @(posedge CLK_50M) begin
        receiver_debug_slot <= receiver_debug_slot + 1'b1;
        receiver_debug_sync0 <= {vs_i, hs_i, de_i, receiver_debug_pix_div[7]};
        receiver_debug_sync1 <= receiver_debug_sync0;
        receiver_pin_sync0 <= {gray_i, vs_i, hs_i, de_i, receiver_debug_pix_div[7]};
        receiver_pin_sync1 <= receiver_pin_sync0;
    end
    always @(*) begin
`ifdef HDMI_PINOUT_ILA
        receiver_debug_data = {5'd0, receiver_pin_sync1};
`else
        case (receiver_debug_slot[9:7])
            0: receiver_debug_data = {cfg_write_failed, cfg_write_error_index, hdmi_io_config_valid};
            1: receiver_debug_data = {1'b0, hdmi_frame_period[15:0]};
            2: receiver_debug_data = {1'b0, hdmi_frame_period[31:16]};
            3: receiver_debug_data = {1'b0, hdmi_io_config[15:0]};
            4: receiver_debug_data = {1'b0, hdmi_io_config[31:16]};
            5: receiver_debug_data = {1'b0, hdmi_io_config[47:32]};
            6: receiver_debug_data = {5'd0, system_manager.state, hdmi_io_config[55:48]};
            default: receiver_debug_data = hdmi_path_debug;
        endcase
`endif
    end
    // Always expose the live receiver state. cfg_failed is sticky for a
    // recoverable configuration write error, so selecting error indices when
    // it is set would hide the actual EDID/TMDS/HDMI hand-off state.
    adv7611_ila edid_ila (
        .clk(CLK_50M),
        .probe0({cfg_done, cfg_failed}),
        .probe1(hdmi_tmds_q7[15:7]),
        .probe2({edid_verified, hdmi_frequency_valid, hdmi_status_byte}),
        .probe3(receiver_debug_data),
        // Slot tag, synchronized physical pins, qualified geometry and rate.
        .probe4({receiver_debug_slot[9:7], receiver_debug_sync1,
                 hdmi_valid_sync[1], hdmi_rate_valid})
    );
`else
    localparam RECEIVER_DEBUG_ACCESS = 0;
    assign receiver_debug_command = 0;
`endif
    wire pll_locked;
    wire rst_n;
    wire sys_rst_n;
    wire epd_sys_rst_n;
    wire clk_50m_rst_n;
    localparam integer ADV_RESET_HOLD_CYCLES = SYS_CLK_FREQ * 30000;
    reg [31:0] adv_reset_counter;
    reg adv_reset_n;
    wire epd_rst_n;
    wire status_gray_de;
    wire status_gray_hs;
    wire status_gray_vs;
    wire [7:0] status_gray_data;
    wire [3:0] status_gray_source;
    wire hdmi_gray_hs;
    wire hdmi_gray_vs;
    wire [7:0] hdmi_gray_data;
    wire [3:0] hdmi_gray_source;
    wire hdmi_gray_de_cropped;
    wire capture_pix_clk;
    wire capture_gray_de;
    wire capture_gray_hs;
    wire capture_gray_vs;
    wire [7:0] capture_gray_data;
    wire [3:0] capture_gray_source;
    wire hdmi_video_valid;
    wire hdmi_frame_changed_pix;
    (* ASYNC_REG = "TRUE" *) reg [1:0] hdmi_frame_changed_sync;
    wire hdmi_frame_changed;
    wire hdmi_capture_valid;
    wire capture_from_hdmi;
    wire hdmi_fast_update;
    wire local_recovery;
    wire [22:0] captured_changed_pixels;
    wire [22:0] captured_drive_pixels,captured_pending_pixels;
    wire hybrid_fast,hybrid_refine;
    wire [11:0] refine_y;
    wire boot_pattern_active;
    wire text_mode;
    wire [1:0] mode_notice;
    wire init_mode, white_only;
    wire datapath_run, dma_idle;
    wire display_done_sys;
    wire image_done;
    (* ASYNC_REG = "TRUE" *) reg [1:0] hdmi_valid_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] manual_refresh_sync;
    reg [19:0] manual_refresh_count;
    reg manual_refresh_level;
    reg manual_refresh_level_d;
    (* ASYNC_REG = "TRUE" *) reg [1:0] mode_key_sync;
    reg [19:0] mode_key_count;
    reg mode_key_level;
    reg mode_key_level_d;
    wire manual_refresh_pulse = manual_refresh_level_d &&
                                !manual_refresh_level;
    wire mode_toggle_pulse = mode_key_level_d && !mode_key_level;
    wire display_hdmi_locked;
    wire display_hdmi_status_valid;
    wire display_hdmi_status_changed;

    wire clk = CLK_50M;
    wire clr_flag = GPIO_O;

    // ADV7611 RESET is active low. Keep it asserted through PLL startup and
    // for 30 ms of stable 50 MHz clock before beginning its I2C sequence.
    assign video_card_rst_n = clk_50m_rst_n & adv_reset_n;
    assign epd_dir = 1'b1;

    delay_cnt #(.NUM(DELAY_CNT * 2)) startup_delay (
        .clk_i(clk),
        .rstn_i(1'b1),
        .rst_o(rst_n)
    );

`ifdef vsim
    div_2 test_clk (.clk(clk), .rst_n(rst_n), .q(epd_clk));
    assign clk_50m = clk;
    assign pll_locked = 1'b1;
`else
    // Mode 3 totals: 362 source clocks/line, 1623 lines/scan, about 75 Hz.
    clock_pll_es120mc1 clock_pll (
        .clk_in(clk),
        .resetn(1'b1),
        .clk_50m(clk_50m),
        .epd_clk(epd_clk),
        .locked(pll_locked)
    );
`endif

    assign sys_rst_n = pll_locked & rst_n;
    assign epd_sys_rst_n = pll_locked;

    rst_sync_n_es120mc1 sync_50m (
        .clk(clk_50m),
        .arst_n(sys_rst_n),
        .srst_n(clk_50m_rst_n)
    );

    // M18 is the board's active-low manual-refresh key. M20 is the active-low
    // mode key. ADV7611 has no external enable gate and remains configured
    // whenever its reset has been released.
    always @(posedge clk_50m or negedge clk_50m_rst_n) begin
        if (!clk_50m_rst_n) begin
            manual_refresh_sync <= 2'b11;
            manual_refresh_count <= 0;
            manual_refresh_level <= 1'b1;
            manual_refresh_level_d <= 1'b1;
        end else begin
            manual_refresh_sync <= {manual_refresh_sync[0], manual_refresh_n};
            manual_refresh_level_d <= manual_refresh_level;
            if (manual_refresh_sync[1] == manual_refresh_level) begin
                manual_refresh_count <= 0;
            end else if (manual_refresh_count == 20'd999999) begin
                manual_refresh_count <= 0;
                manual_refresh_level <= manual_refresh_sync[1];
            end else begin
                manual_refresh_count <= manual_refresh_count + 1'b1;
            end
        end
    end

    always @(posedge clk_50m or negedge clk_50m_rst_n) begin
        if (!clk_50m_rst_n) begin
            mode_key_sync <= 2'b11;
            mode_key_count <= 0;
            mode_key_level <= 1'b1;
            mode_key_level_d <= 1'b1;
        end else begin
            mode_key_sync <= {mode_key_sync[0], mode_key_n};
            mode_key_level_d <= mode_key_level;
            if (mode_key_sync[1] == mode_key_level) begin
                mode_key_count <= 0;
            end else if (mode_key_count == 20'd999999) begin
                mode_key_count <= 0;
                mode_key_level <= mode_key_sync[1];
            end else begin
                mode_key_count <= mode_key_count + 1'b1;
            end
        end
    end

    always @(posedge clk_50m or negedge clk_50m_rst_n) begin
        if (!clk_50m_rst_n) begin
            adv_reset_counter <= 32'd0;
            adv_reset_n <= 1'b0;
        end
        else if (!adv_reset_n) begin
            if (adv_reset_counter == ADV_RESET_HOLD_CYCLES - 1'b1)
                adv_reset_n <= 1'b1;
            else
                adv_reset_counter <= adv_reset_counter + 1'b1;
        end
    end
    rst_sync_n_es120mc1 sync_epd (
        .clk(epd_clk),
        .arst_n(epd_sys_rst_n),
        .srst_n(epd_rst_n)
    );

    // Verify ADV7611 ACKs and its EDID RAM before exposing HPD to the source.
    adv7611_iic_manager #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .SCL_FREQ(SCL_FREQ),
        .STARTUP_DELAY_CYCLES(SYS_CLK_FREQ * 25000),
        .EDID_DTD_CLOCK_LOW(8'hb9), .EDID_CHECKSUM(8'h5c), .HPA_VERIFY_VALUE(8'ha2),
        .FULL_EDID_VERIFY(1), .MONITOR_TMDS_FREQ(1), .MONITOR_IO_CONFIG(1),
        .DEBUG_ACCESS(RECEIVER_DEBUG_ACCESS),
        .DETECT_PERIOD_CYCLES(SYS_CLK_FREQ * 100000)
    ) adv7611_manager (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n & adv_reset_n),
        .scl(scl),
        .sda(sda),
        .REG_INDEX(REG_INDEX),
        .REG_DATA(REG_DATA),
        .REG_SIZE(REG_SIZE),
        .cfg_done(cfg_done),
        .cfg_failed(cfg_failed),
        .cfg_error_index(cfg_error_index),
        .cfg_attempt(cfg_attempt),
        .cfg_write_failed(cfg_write_failed),
        .cfg_write_error_index(cfg_write_error_index),
        .verify_read_address(verify_read_address),
        .verify_read_ack_error(verify_read_ack_error),
        .verify_read_data(verify_read_data),
        .i2c_ack_error_debug(i2c_ack_error_debug),
        .i2c_busy_debug(i2c_busy_debug),
        .hdmi_locked(hdmi_locked),
        .hdmi_status_valid(hdmi_status_valid),
        .hdmi_status_changed(hdmi_status_changed), .edid_verified(edid_verified),
        .hdmi_status_byte(hdmi_status_byte), .hdmi_tmds_q7(hdmi_tmds_q7),
        .hdmi_frequency_valid(hdmi_frequency_valid),
        .io_config_readback(hdmi_io_config), .io_config_valid(hdmi_io_config_valid),
        .debug_command(receiver_debug_command), .debug_response(receiver_debug_response)
    );

    config_reg_es120mc1 #(.VCOM(VCOM)) config_registers (
        .REG_INDEX(REG_INDEX),
        .REG_DATA(REG_DATA),
        .REG_SIZE(REG_SIZE)
    );

    level2pulse #(.MODE("RISING")) config_done_pulse (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n),
        .in(cfg_done),
        .out(p_clr_flag)
    );

    status_source_es120mc1 #(
        .NATIVE_GC16(0),
        .H_ACTIVE(FRAME_H), .V_ACTIVE(FRAME_V), .SCALE(8), .STRIPE_WIDTH(80),
        .BOOT_STRIPE_HALF_GRAY(0)
    ) status_source (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n),
        .stripes(boot_pattern_active),
        .status_mode(status_mode),
        .hdmi_tmds_q7(hdmi_tmds_q7),
        .hdmi_rate_valid(hdmi_rate_valid),
        .mode_notice(mode_notice),
        .gray_de(status_gray_de),
        .gray_hs(status_gray_hs),
        .gray_vs(status_gray_vs),
        .gray_data(status_gray_data),
        .gray_source(status_gray_source)
    );

    // The EBAZ4205 ADV7611 wiring exposes its configured 8-bit gray output.
    // HDMI active geometry and DDR/panel geometry are identical: no crop.
    hdmi_input_es120mc1 #(
        .INPUT_H(HDMI_H), .FRAME_H(FRAME_H), .FRAME_V(FRAME_V),
        .DITHER_ENABLE(1), .NATIVE_GC16(1), .VIDEO_LEVELS_ENABLE(1), .NATIVE_LIGHTEN(0),
        .GAMMA_AWARE_DITHER(1)
    ) hdmi_input (
        .pix_clk(pix_clk), .rst_n(clk_50m_rst_n),
        .de_i(de_i), .hs_i(hs_i), .vs_i(vs_i), .gray_i(gray_i),
        .gray_de(hdmi_gray_de_cropped), .gray_hs(hdmi_gray_hs),
        .gray_vs(hdmi_gray_vs), .gray_data(hdmi_gray_data),
        .gray_source(hdmi_gray_source),
        .video_valid(hdmi_video_valid), .frame_changed(hdmi_frame_changed_pix),
        .native_refine(hybrid_refine), .mode_notice(mode_notice), .text_mode(text_mode)
    );

    // In local diagnostic mode HDMI is disconnected before the frame-source
    // mux, status manager and pixel-clock mux.  ADV7611 configuration still
    // runs, but it cannot affect any pixels written to the EPD buffers.
    assign display_hdmi_locked = DIAGNOSTIC_LOCAL_ONLY ? 1'b0 : hdmi_locked;
    assign display_hdmi_status_valid = DIAGNOSTIC_LOCAL_ONLY ? 1'b1 : hdmi_status_valid;
    assign display_hdmi_status_changed = DIAGNOSTIC_LOCAL_ONLY ? 1'b0 : hdmi_status_changed;
    always @(posedge clk_50m or negedge clk_50m_rst_n) begin
        if (!clk_50m_rst_n) begin
            hdmi_valid_sync <= 0;
            hdmi_frame_changed_sync <= 0;
        end else begin
            hdmi_valid_sync <= {hdmi_valid_sync[0], hdmi_video_valid};
            hdmi_frame_changed_sync <= {hdmi_frame_changed_sync[0], hdmi_frame_changed_pix};
        end
    end
    assign hdmi_frame_changed = hdmi_frame_changed_sync[1];
    hdmi_frame_guard_es120mc1 #(.CLK_HZ(SYS_CLK_FREQ * 1000000)) hdmi_frame_guard (
        .clk(clk_50m), .rst_n(clk_50m_rst_n), .vs(vs_i),
        .rate_valid(hdmi_rate_valid), .measured_period(hdmi_frame_period)
    );
    // EDID: 111.93 MHz / (2720 * 1646) = 25.000447 Hz, q7 about 14327.
    // Require both the receiver lock and its actual parallel video geometry
    // and VS rate; a TMDS lock alone must not feed free-run/wrong-size data
    // into the fixed-stride DDR writer. Debounce transient status-read loss.
    localparam integer HDMI_TMDS_MIN_Q7 = 110 * 128;
    localparam integer HDMI_TMDS_MAX_Q7 = 114 * 128;
    wire hdmi_link_candidate = !DIAGNOSTIC_LOCAL_ONLY && edid_verified &&
        hdmi_locked && hdmi_frequency_valid && hdmi_valid_sync[1] && hdmi_rate_valid &&
        hdmi_tmds_q7 >= HDMI_TMDS_MIN_Q7 && hdmi_tmds_q7 <= HDMI_TMDS_MAX_Q7;
    // Stop the diagnostic hand-off one qualification step earlier so the
    // panel can show whether ADV7611 itself has locked the HDMI source.
    wire hdmi_signal_locked = !DIAGNOSTIC_LOCAL_ONLY && edid_verified &&
        hdmi_locked && hdmi_frequency_valid &&
        hdmi_tmds_q7 >= HDMI_TMDS_MIN_Q7 && hdmi_tmds_q7 <= HDMI_TMDS_MAX_Q7;
    localparam integer HDMI_VALID_ASSERT_CYCLES = SYS_CLK_FREQ * 100000;
    localparam integer HDMI_VALID_DROP_CYCLES = SYS_CLK_FREQ * 1000000;
    reg [26:0] hdmi_valid_age;
    reg [26:0] hdmi_invalid_age;
    reg hdmi_link_stable;
    always @(posedge clk_50m or negedge clk_50m_rst_n) begin
        if (!clk_50m_rst_n) begin
            hdmi_valid_age <= 0;
            hdmi_invalid_age <= 0;
            hdmi_link_stable <= 1'b0;
        end
        else if (hdmi_link_candidate) begin
            hdmi_invalid_age <= 0;
            if (!hdmi_link_stable) begin
                if (hdmi_valid_age >= HDMI_VALID_ASSERT_CYCLES - 1) begin
                    hdmi_valid_age <= 0;
                    hdmi_link_stable <= 1'b1;
                end
                else hdmi_valid_age <= hdmi_valid_age + 1'b1;
            end
            else hdmi_valid_age <= 0;
        end
        else begin
            hdmi_valid_age <= 0;
            if (hdmi_link_stable) begin
                if (hdmi_invalid_age >= HDMI_VALID_DROP_CYCLES - 1) begin
                    hdmi_invalid_age <= 0;
                    hdmi_link_stable <= 1'b0;
                end
                else hdmi_invalid_age <= hdmi_invalid_age + 1'b1;
            end
            else hdmi_invalid_age <= 0;
        end
    end
    assign hdmi_capture_valid = hdmi_link_stable;

    // ILA probe3: [16:13] captures requested, [12:9] captures completed,
    // [8:5] displays completed (all modulo 16), then geometry/candidate/
    // stable/source/datapath in [4:0]. Counters retain events between reads.
    reg [3:0] debug_capture_starts, debug_capture_dones, debug_display_dones;
    always @(posedge clk_50m or negedge clk_50m_rst_n) begin
        if (!clk_50m_rst_n) begin
            debug_capture_starts <= 0;
            debug_capture_dones <= 0;
            debug_display_dones <= 0;
        end else begin
            if (w_gray_s_flag) debug_capture_starts <= debug_capture_starts + 1'b1;
            if (w_gray_fflag) debug_capture_dones <= debug_capture_dones + 1'b1;
            if (display_done_sys) debug_display_dones <= debug_display_dones + 1'b1;
        end
    end
    assign hdmi_path_debug = {debug_capture_starts, debug_capture_dones,
        debug_display_dones, hdmi_valid_sync[1], hdmi_link_candidate,
        hdmi_capture_valid, capture_from_hdmi, datapath_run};

    // Only switch while capture is idle. IGNORE permits returning to local
    // video even when the unplugged receiver's pixel clock has stopped.
    // The manager allows 64 system clocks to settle before arming capture.
    BUFGCTRL #(.SIM_DEVICE("7SERIES")) capture_clock_mux (
        .I0(clk_50m),
        .I1(pix_clk),
        .S0(~capture_from_hdmi), .S1(capture_from_hdmi),
        .CE0(1'b1), .CE1(1'b1), .IGNORE0(1'b1), .IGNORE1(1'b1),
        .O(capture_pix_clk)
    );

    assign capture_gray_de = capture_from_hdmi ? hdmi_gray_de_cropped : status_gray_de;
    assign capture_gray_hs = capture_from_hdmi ? hdmi_gray_hs : status_gray_hs;
    assign capture_gray_vs = capture_from_hdmi ? hdmi_gray_vs : status_gray_vs;
    assign capture_gray_data = capture_from_hdmi ? hdmi_gray_data : status_gray_data;
    assign capture_gray_source = capture_from_hdmi ? hdmi_gray_source : status_gray_source;

    sync_epd_busy_to_sys epd_busy_cdc (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n),
        .in(epd_busy),
        .out(epd_busy_50m)
    );

    tps65185_ctrl panel_power (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n & cfg_done),
        .epd_busy(epd_busy_50m),
        .epd_pwr_sw(1'b1),
        .pwr_good(1'b1),
        .epd_pwr_en(epd_pwr_en)
    );

    wire stream_capture_fault;
    frame_stream_es120mc1 #(
        .FRAME_H(FRAME_H),
        .FRAME_V(FRAME_V),
        .DATA0(DATA_0_ADDR_MEM_OFFSET), .DATA1(DATA_1_ADDR_MEM_OFFSET),
        .USE_NATIVE_GC16(1)
    ) frame_processor (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n && datapath_run),
        .epd_rst_n(epd_rst_n),
        .capture_start(w_gray_s_flag), .display_start(epd_s_flag),
        .pix_clk(capture_pix_clk),
        .gray_de(capture_gray_de),
        .gray_vs(capture_gray_vs),
        .gray_data(capture_gray_data),
        .gray_source(capture_gray_source),
        .capture_busy(w_gray_busy), .capture_done(w_gray_fflag),
        .clear_start(clr_s_flag), .video_mode(capture_from_hdmi), .refine(hybrid_refine),
        .text_mode(text_mode),
        .capture_fault(stream_capture_fault),
        .drive_pixels(captured_drive_pixels),.pending_pixels(captured_pending_pixels),
        .changed_pixels(captured_changed_pixels),
        .clear_done(clr_fflag),
        .epd_clk(epd_clk),
        .phase(period_cnt), .row_request(r_data_flag),
        .fifo_pop(r_data_fifo_ren), .fifo_data(r_data_fifo_out),
        .CLK_50M(CLK_50M),
        .GPIO_O(GPIO_O), .dma_idle(dma_idle)
    );

    // ES120MC1 Mode 3 has its own line protocol.  The generic ES108-style
    // controller uses a different CKV/LE/XSTL relationship and produces
    // horizontal tearing on this panel.
    display_mgr_es120mc1 #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .FDMA_WID(FDMA_WID),
        .EPD_WID(EPD_WID),
        .EPD_FREQ(EPD_FREQ),
        .EPD_H(EPD_H / (EPD_WID / 8)),
        .EPD_V(EPD_V),
        .PERIOD_CNT(HDMI_FULL_PHASES),
        .FAST_PERIOD_CNT(HDMI_DU_PHASES),
        .NATIVE_GC16(1),
        .STREAMING_REFRESH(1),
        .LOCAL_RECOVERY(0),
        .tFdly(tFdly),
        .tLEdly(tLEdly),
        .tLEw(tLEw),
        .tLEoff(tLEoff)
    ) display_manager (
        .clk(clk_50m),
        .epd_clk(epd_clk),
        .rst_n(clk_50m_rst_n),
        .epd_rst_n(epd_rst_n),
        .s_flag(epd_s_flag),
        .init_mode(init_mode),
        .white_only(white_only),
        .fast_update(hybrid_fast),
        .local_recovery(local_recovery),
        .period_cnt(period_cnt),
        .d_busy(epd_busy),
        .d_fflag(epd_fflag),
        .image_fflag(image_done),
        .r_flag(r_data_flag),
        .fifo_ren(r_data_fifo_ren),
        .din(r_data_fifo_out),
        .EPD_SKV(EPD_SKV),
        .EPD_SPV(EPD_SPV),
        .EPD_XCL(EPD_XCL),
        .EPD_XLE(EPD_XLE),
        .EPD_XSTL(EPD_XSTL),
        .EPD_DOUT(EPD_DOUT)
    );

    sync_h2lck display_done_cdc (
        .in_clk(epd_clk), .out_clk(clk_50m), .rst_n(epd_rst_n),
        .level_in(epd_fflag), .pulse_out(display_done_sys)
    );
    assign boot_pattern_active=1'b0;
    assign local_recovery=1'b0;
    assign hybrid_fast=capture_from_hdmi;
    assign hdmi_fast_update=capture_from_hdmi;
    assign refine_y=0;
    stream_manager_es120mc1 #(
        .POWER_SETTLE_CYCLES(SYS_CLK_FREQ * 100000),
        .HDMI_STAGE_CYCLES(SYS_CLK_FREQ * 2000000),
        .BOOT_CYCLE_MIN_CYCLES(SYS_CLK_FREQ * 3000000)
    ) system_manager (
        .clk(clk_50m),
        .rst_n(clk_50m_rst_n),
        .ready(cfg_done && epd_pwr_en),
        .dma_idle(dma_idle), .datapath_run(datapath_run),
        .hdmi_valid(hdmi_capture_valid), .hdmi_signal_locked(hdmi_signal_locked),
        .changed_pixels(captured_changed_pixels),
        .drive_pixels(captured_drive_pixels),.pending_pixels(captured_pending_pixels),
        .refine(hybrid_refine), .capture_fault(stream_capture_fault),
        .manual_refresh(manual_refresh_pulse),
        .init_mode(init_mode),
        .white_only(white_only),
        .capture_from_hdmi(capture_from_hdmi),
        .capture_start(w_gray_s_flag), .capture_done(w_gray_fflag),
        .clear_start(clr_s_flag), .clear_done(clr_fflag),
        .display_start(epd_s_flag), .display_done(display_done_sys),
        .status_mode(status_mode),
        .mode_toggle(mode_toggle_pulse), .hdmi_frame_changed(hdmi_frame_changed),
        .text_mode(text_mode), .mode_notice(mode_notice)
    );
endmodule

module rst_sync_n_es120mc1 (
    input wire clk,
    input wire arst_n,
    output wire srst_n
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_pipe;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            rst_pipe <= 2'b00;
        end
        else begin
            rst_pipe <= {rst_pipe[0], 1'b1};
        end
    end

    assign srst_n = rst_pipe[1];
endmodule

module sync_epd_busy_to_sys (
    input wire clk,
    input wire rst_n,
    input wire in,
    output wire out
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_ff;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_ff <= 2'b00;
        end
        else begin
            sync_ff <= {sync_ff[0], in};
        end
    end

    assign out = sync_ff[1];
endmodule
