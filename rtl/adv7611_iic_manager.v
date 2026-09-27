// Configures the external devices, then polls ADV7611 TMDS status. Free-run
// keeps video timing alive without a source, so
// this uses the receiver's TMDS PLL status rather than DE/HS/VS activity.
module adv7611_iic_manager #(
    parameter SYS_CLK_FREQ = 50,
    parameter SCL_FREQ = 200,
    parameter DETECT_PERIOD_CYCLES = SYS_CLK_FREQ * 1000000,
    // Keep the manual HPA pulse wide enough for a PC HDMI transmitter to
    // invalidate a cached EDID. The ADI requirement is at least 50 ms.
    parameter HPD_LOW_HOLD_CYCLES = SYS_CLK_FREQ * 1000000,
    parameter HPD_HIGH_HOLD_CYCLES = SYS_CLK_FREQ * 500000,
    parameter I2C_RESET_DELAY_CYCLES = SYS_CLK_FREQ * 10000,
    parameter EDID_DISABLE_DELAY_CYCLES = SYS_CLK_FREQ * 5000,
    // ADV7611 needs more than 1 ms after reset before its I2C maps ACK.
    parameter STARTUP_DELAY_CYCLES = SYS_CLK_FREQ * 5000,
    parameter [7:0] EDID_DTD_CLOCK_LOW = 8'h2b,
    parameter [7:0] EDID_CHECKSUM = 8'h50,
    parameter [7:0] HPA_VERIFY_VALUE = 8'ha4,
    parameter FULL_EDID_VERIFY = 0,
    parameter MONITOR_TMDS_FREQ = 0,
    parameter MONITOR_IO_CONFIG = 0,
    parameter DEBUG_ACCESS = 0
    )(
    input wire clk,
    input wire rst_n,
    output wire scl,
    inout wire sda,

    output reg [8:0] REG_INDEX,
    input wire [39:0] REG_DATA,
    input wire [8:0] REG_SIZE,
    output reg cfg_done,
    output reg cfg_failed,
    output reg [8:0] cfg_error_index,
    output reg [1:0] cfg_attempt,
    output reg cfg_write_failed,
    output reg [8:0] cfg_write_error_index,
    output reg [7:0] verify_read_address,
    output reg verify_read_ack_error,
    output reg [7:0] verify_read_data,
    output wire i2c_ack_error_debug,
    output wire i2c_busy_debug,

    output reg hdmi_locked,
    output reg hdmi_status_valid,
    output reg hdmi_status_changed,
    output reg edid_verified,
    output reg [7:0] hdmi_status_byte,
    output reg [15:0] hdmi_tmds_q7,
    output reg hdmi_frequency_valid,
    output reg [55:0] io_config_readback,
    output reg [6:0] io_config_valid,
    // Same-clock toggle handshake: {toggle, write, device, register, data}.
    input wire [25:0] debug_command,
    output reg [9:0] debug_response
    );

    localparam [3:0]
        STARTUP_WAIT = 4'd0,
        CFG_PREPARE = 4'd1,
        CFG_LAUNCH = 4'd2,
        CFG_WAIT = 4'd3,
        CFG_HPD_HOLD = 4'd4,
        VERIFY_PREPARE = 4'd5,
        VERIFY_LAUNCH = 4'd6,
        VERIFY_READ = 4'd7,
        DETECT_WAIT = 4'd8,
        DETECT_PREPARE = 4'd9,
        DETECT_LAUNCH = 4'd10,
        DETECT_READ = 4'd11,
        CFG_FAILED = 4'd12,
        PRECFG_RESET_WAIT = 4'd13,
        PRECFG_EDID_WAIT = 4'd14,
        CFG_HPD_HIGH_HOLD = 4'd15;

    // The configuration table ends with: enable EDID, release HPD, release
    // manual HPA, TPS65185 setup, and VCOM setup.
    localparam [8:0] EDID_ENABLE_INDEX = 9'd178;
    localparam [8:0] HPA_ASSERT_INDEX = 9'd179;

    reg [3:0] state;
    reg iic_en;
    reg iic_mode;
    reg [31:0] wr_data;
    reg [7:0] wr_cnt;
    reg [7:0] rd_cnt;
    wire [7:0] rd_data;
    wire iic_busy;
    wire iic_ack_error;
    reg [31:0] detect_counter;
    reg [31:0] hpd_hold_counter;
    reg [31:0] startup_counter;
    reg [31:0] preconfig_delay_counter;
    reg [7:0] verify_index;
    reg [3:0] preconfig_index;
    reg preconfig_done;
    // Poll both the selected HDMI-map status and the raw Port-A lock/status
    // registers.  The latter distinguishes an absent TMDS clock from a
    // decoder/front-end lock problem without changing the capture gate.
    reg [3:0] detect_index;
    reg [7:0] tmds_high;
    reg poll_error;
    reg debug_pending;
    reg debug_toggle;
    wire next_hdmi_locked = !iic_ack_error && rd_data[1];
    wire [7:0] detect_address = (detect_index == 0) ? 8'h04 :
                                (detect_index == 1) ? 8'h51 :
                                (detect_index == 2) ? 8'h52 :
                                (detect_index == 3) ? 8'h6a :
                                (detect_index == 4) ? 8'h07 :
                                (detect_index == 5) ? 8'h1b :
                                (detect_index == 6) ? 8'he0 :
                                (detect_index == 7) ? 8'h03 :
                                (detect_index == 8) ? 8'h05 :
                                (detect_index == 9) ? 8'h06 :
                                (detect_index == 10) ? 8'h15 :
                                (detect_index == 11) ? 8'h0c :
                                (detect_index == 12) ? 8'h19 : 8'h33;
    wire [7:0] detect_device_address =
        (detect_index == 3 || detect_index >= 7) ? 8'h98 : 8'h68;

    // ADV7611 must not expose its current EDID while the replacement image is
    // being written.  This prefix is intentionally separate from the board
    // configuration table: it establishes the ADI-defined DDC sequence before
    // any receiver or panel setup touches the normal table.
    function [39:0] preconfig_data;
        input [3:0] index;
        begin
            case (index)
                4'd0:  preconfig_data = {8'd3, 8'h98, 8'hff, 8'h80, 8'h00};
                4'd1:  preconfig_data = {8'd3, 8'h98, 8'hf4, 8'h80, 8'h00};
                4'd2:  preconfig_data = {8'd3, 8'h98, 8'hf5, 8'h7c, 8'h00};
                4'd3:  preconfig_data = {8'd3, 8'h98, 8'hf8, 8'h4c, 8'h00};
                4'd4:  preconfig_data = {8'd3, 8'h98, 8'hf9, 8'h64, 8'h00};
                4'd5:  preconfig_data = {8'd3, 8'h98, 8'hfa, 8'h6c, 8'h00};
                4'd6:  preconfig_data = {8'd3, 8'h98, 8'hfb, 8'h68, 8'h00};
                4'd7:  preconfig_data = {8'd3, 8'h98, 8'hfd, 8'h44, 8'h00};
                4'd8:  preconfig_data = {8'd3, 8'h68, 8'h6c, 8'ha3, 8'h00};
                4'd9:  preconfig_data = {8'd3, 8'h98, 8'h20, 8'h70, 8'h00};
                4'd10: preconfig_data = {8'd3, 8'h64, 8'h74, 8'h00, 8'h00};
                default: preconfig_data = 40'd0;
            endcase
        end
    endfunction

    wire [39:0] active_reg_data =
        preconfig_done ? REG_DATA : preconfig_data(preconfig_index);

    function [7:0] verify_address;
        input [7:0] index;
        begin
            if (FULL_EDID_VERIFY)
                verify_address = (index < 128) ? index : ((index == 128) ? 8'h74 : 8'h76);
            else case (index)
                3'd0: verify_address = 8'h00;
                3'd1: verify_address = 8'h36;
                3'd2: verify_address = 8'h7f;
                3'd3: verify_address = 8'h74;
                3'd4: verify_address = 8'h6c;
                3'd5: verify_address = 8'h20;
                3'd6: verify_address = 8'h21;
                default: verify_address = 8'h76;
            endcase
        end
    endfunction

    function [7:0] verify_device_address;
        input [7:0] index;
        begin
            if (FULL_EDID_VERIFY)
                verify_device_address = (index < 128) ? 8'h6c : 8'h64;
            else case (index)
                3'd0, 3'd1, 3'd2: verify_device_address = 8'h6c;
                3'd3:             verify_device_address = 8'h64;
                3'd4:             verify_device_address = 8'h68;
                3'd5, 3'd6:       verify_device_address = 8'h98;
                default:           verify_device_address = 8'h64;
            endcase
        end
    endfunction

    function [7:0] verify_value;
        input [7:0] index;
        begin
            if (FULL_EDID_VERIFY)
                verify_value = (index < 128) ? REG_DATA[15:8] : 8'h01;
            else case (index)
                3'd0: verify_value = 8'h00;
                3'd1: verify_value = EDID_DTD_CLOCK_LOW;
                3'd2: verify_value = EDID_CHECKSUM;
                3'd3: verify_value = 8'h01;
                3'd4: verify_value = HPA_VERIFY_VALUE;
                3'd5: verify_value = 8'hf0;
                default: verify_value = 8'h00;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= STARTUP_WAIT;
            REG_INDEX           <= 9'd0;
            cfg_done            <= 1'b0;
            cfg_failed          <= 1'b0;
            cfg_error_index     <= 9'd0;
            cfg_attempt         <= 2'd0;
            cfg_write_failed    <= 1'b0;
            cfg_write_error_index <= 9'd0;
            verify_read_address <= 8'd0;
            verify_read_ack_error <= 1'b0;
            verify_read_data    <= 8'd0;
            iic_en              <= 1'b0;
            iic_mode            <= 1'b0;
            wr_data             <= 32'd0;
            wr_cnt              <= 8'd0;
            rd_cnt              <= 8'd0;
            detect_counter      <= 32'd0;
            hpd_hold_counter    <= 32'd0;
            startup_counter     <= 32'd0;
            preconfig_delay_counter <= 32'd0;
            verify_index        <= 3'd0;
            preconfig_index     <= 4'd0;
            preconfig_done      <= 1'b0;
            hdmi_locked         <= 1'b0;
            hdmi_status_valid   <= 1'b0;
            hdmi_status_changed <= 1'b0;
            edid_verified       <= 1'b0;
            hdmi_status_byte    <= 0;
            hdmi_tmds_q7        <= 0;
            hdmi_frequency_valid <= 0;
            detect_index <= 0; tmds_high <= 0; poll_error <= 0;
            io_config_readback <= 0; io_config_valid <= 0;
            debug_pending <= 0; debug_toggle <= 0; debug_response <= 0;
        end
        else begin
            hdmi_status_changed <= 1'b0;
            case (state)
                STARTUP_WAIT: begin
                    if (startup_counter == STARTUP_DELAY_CYCLES - 1'b1) begin
                        state <= CFG_PREPARE;
                    end
                    else begin
                        startup_counter <= startup_counter + 1'b1;
                    end
                end

                CFG_PREPARE: begin
                    if (!iic_busy) begin
                        wr_data <= {8'h00, active_reg_data[7:0],
                                    active_reg_data[15:8],
                                    active_reg_data[23:16],
                                    active_reg_data[31:24]};
                        wr_cnt   <= active_reg_data[39:32];
                        rd_cnt   <= 8'd0;
                        iic_mode <= 1'b0;
                        iic_en   <= 1'b1;
                        state    <= CFG_LAUNCH;
                    end
                end

                CFG_LAUNCH: begin
                    if (iic_busy) begin
                        iic_en <= 1'b0;
                        state  <= CFG_WAIT;
                    end
                end

                CFG_WAIT: begin
                    if (!iic_busy) begin
                        if (!preconfig_done) begin
                            if (iic_ack_error && cfg_attempt != 2'd2) begin
                                cfg_attempt <= cfg_attempt + 1'b1;
                                state <= CFG_PREPARE;
                            end
                            else begin
                                if (iic_ack_error) begin
                                    cfg_failed <= 1'b1;
                                    cfg_write_failed <= 1'b1;
                                    cfg_write_error_index <= {5'd0, preconfig_index};
                                end
                                cfg_attempt <= 2'd0;
                                if (preconfig_index == 4'd0) begin
                                    preconfig_delay_counter <= 32'd0;
                                    state <= PRECFG_RESET_WAIT;
                                end
                                else if (preconfig_index == 4'd10) begin
                                    preconfig_delay_counter <= 32'd0;
                                    state <= PRECFG_EDID_WAIT;
                                end
                                else begin
                                    preconfig_index <= preconfig_index + 1'b1;
                                    state <= CFG_PREPARE;
                                end
                            end
                        end
                        else if (iic_ack_error) begin
                            cfg_error_index <= REG_INDEX;
                            if (cfg_attempt == 2'd2) begin
                                // Keep the original configuration sequence
                                // fail-open.  A diagnostic read/write error
                                // must not disable panel power and HPD.
                                cfg_failed <= 1'b1;
                                cfg_write_failed <= 1'b1;
                                cfg_write_error_index <= REG_INDEX;
                                cfg_attempt <= 2'd0;
                                if (REG_INDEX == REG_SIZE - 1'b1) begin
                                    cfg_done <= 1'b1;
                                    verify_index <= 3'd0;
                                    state <= FULL_EDID_VERIFY ? DETECT_WAIT : VERIFY_PREPARE;
                                end
                                else if (FULL_EDID_VERIFY && REG_INDEX == EDID_ENABLE_INDEX) begin
                                    // Do not assert HPD if EDID could not be enabled.
                                    REG_INDEX <= REG_SIZE - 1'b1;
                                    state <= CFG_PREPARE;
                                end else begin
                                    REG_INDEX <= REG_INDEX + 1'b1;
                                    state <= CFG_PREPARE;
                                end
                            end
                            else begin
                                cfg_attempt <= cfg_attempt + 1'b1;
                                state <= CFG_PREPARE;
                            end
                        end
                        else if (REG_INDEX == EDID_ENABLE_INDEX) begin
                            cfg_attempt <= 2'd0;
                            hpd_hold_counter <= 32'd0;
                            state <= CFG_HPD_HOLD;
                        end
                        else if (REG_INDEX == HPA_ASSERT_INDEX) begin
                            cfg_attempt <= 2'd0;
                            hpd_hold_counter <= 32'd0;
                            state <= CFG_HPD_HIGH_HOLD;
                        end
                        else if (REG_INDEX == REG_SIZE - 1'b1) begin
                            cfg_attempt <= 2'd0;
                            cfg_done <= 1'b1;
                            verify_index <= 3'd0;
                            state <= FULL_EDID_VERIFY ? DETECT_WAIT : VERIFY_PREPARE;
                        end
                        else begin
                            cfg_attempt <= 2'd0;
                            REG_INDEX <= REG_INDEX + 1'b1;
                            state     <= CFG_PREPARE;
                        end
                    end
                end

                PRECFG_RESET_WAIT: begin
                    if (preconfig_delay_counter == I2C_RESET_DELAY_CYCLES - 1'b1) begin
                        preconfig_delay_counter <= 32'd0;
                        preconfig_index <= 4'd1;
                        state <= CFG_PREPARE;
                    end
                    else begin
                        preconfig_delay_counter <= preconfig_delay_counter + 1'b1;
                    end
                end

                PRECFG_EDID_WAIT: begin
                    if (preconfig_delay_counter == EDID_DISABLE_DELAY_CYCLES - 1'b1) begin
                        preconfig_delay_counter <= 32'd0;
                        preconfig_done <= 1'b1;
                        REG_INDEX <= 9'd0;
                        state <= CFG_PREPARE;
                    end
                    else begin
                        preconfig_delay_counter <= preconfig_delay_counter + 1'b1;
                    end
                end

                // HDMI sources only re-read EDID after observing HPD low for
                // at least 100 ms.  Keep it low after the new EDID is enabled
                // before executing register 179, which raises HPD.
                CFG_HPD_HOLD: begin
                    if (hpd_hold_counter == HPD_LOW_HOLD_CYCLES - 1'b1) begin
                        if (FULL_EDID_VERIFY) begin
                            // EDID is enabled but HPD is still manually LOW.
                            // REG_DATA supplies the canonical byte to compare.
                            verify_index <= 0; REG_INDEX <= 50;
                            state <= VERIFY_PREPARE;
                        end else begin
                            REG_INDEX <= REG_INDEX + 1'b1;
                            state <= CFG_PREPARE;
                        end
                    end
                    else begin
                        hpd_hold_counter <= hpd_hold_counter + 1'b1;
                    end
                end

                // Hold HPA high under manual control before returning the pin
                // to automatic cable-detect operation. This prevents a short
                // high pulse from being filtered by the HDMI source.
                CFG_HPD_HIGH_HOLD: begin
                    if (hpd_hold_counter == HPD_HIGH_HOLD_CYCLES - 1'b1) begin
                        REG_INDEX <= REG_INDEX + 1'b1;
                        state <= CFG_PREPARE;
                    end
                    else begin
                        hpd_hold_counter <= hpd_hold_counter + 1'b1;
                    end
                end

                // ES120 verifies all 128 EDID bytes and enabled/active status
                // before HPD is raised; legacy targets retain the short check.
                VERIFY_PREPARE: begin
                    if (!iic_busy) begin
                        wr_data <= {16'd0, verify_address(verify_index),
                                    verify_device_address(verify_index)};
                        wr_cnt   <= 8'd2;
                        rd_cnt   <= 8'd1;
                        iic_mode <= 1'b1;
                        iic_en   <= 1'b1;
                        state    <= VERIFY_LAUNCH;
                    end
                end

                VERIFY_LAUNCH: begin
                    if (iic_busy) begin
                        iic_en <= 1'b0;
                        state <= VERIFY_READ;
                    end
                end

                VERIFY_READ: begin
                    if (!iic_busy) begin
                        verify_read_address <= verify_address(verify_index);
                        verify_read_ack_error <= iic_ack_error;
                        verify_read_data <= rd_data;
                        // Index 6 captures IO 0x21, whose bit 3 reports the
                        // physical HPA output. Index 7 captures KSV 0x76,
                        // which reports the active internal EDID path. Retain
                        // both status values without full-byte matching.
                        if (FULL_EDID_VERIFY) begin
                            if (iic_ack_error ||
                                (verify_index < 128 && rd_data != verify_value(verify_index)) ||
                                (verify_index >= 128 && !rd_data[0])) begin
                                cfg_failed <= 1; cfg_error_index <= 9'd200 + verify_index;
                                edid_verified <= 0;
                                // Keep HPD low, but still perform panel VCOM
                                // setup so the local display remains available.
                                REG_INDEX <= REG_SIZE - 1'b1; state <= CFG_PREPARE;
                            end else if (verify_index == 129) begin
                                edid_verified <= 1;
                                REG_INDEX <= HPA_ASSERT_INDEX; state <= CFG_PREPARE;
                            end else begin
                                verify_index <= verify_index + 1'b1;
                                if (verify_index < 127) REG_INDEX <= REG_INDEX + 1'b1;
                                state <= VERIFY_PREPARE;
                            end
                        end else if (iic_ack_error ||
                            ((verify_index != 3'd6) && (verify_index != 3'd7) &&
                             (rd_data != verify_value(verify_index)))) begin
                            cfg_failed <= 1'b1;
                            cfg_error_index <= 9'd200 + verify_index;
                            cfg_done <= 1'b1;
                            detect_counter <= 32'd0;
                            state <= DETECT_WAIT;
                        end
                        else if (verify_index == 3'd7) begin
                            edid_verified <= 1'b1;
                            cfg_done <= 1'b1;
                            detect_counter <= 32'd0;
                            state <= DETECT_WAIT;
                        end
                        else begin
                            verify_index <= verify_index + 1'b1;
                            state <= VERIFY_PREPARE;
                        end
                    end
                end

                DETECT_WAIT: begin
                    if (DEBUG_ACCESS && debug_command[25] != debug_response[9] && !iic_busy) begin
                        // Serialize debugger access between complete polls.
                        wr_data <= {8'd0, debug_command[7:0], debug_command[15:8],
                                    debug_command[23:16]};
                        wr_cnt <= debug_command[24] ? 8'd3 : 8'd2;
                        rd_cnt <= debug_command[24] ? 8'd0 : 8'd1;
                        iic_mode <= !debug_command[24];
                        iic_en <= 1;
                        debug_pending <= 1;
                        debug_toggle <= debug_command[25];
                        state <= DETECT_LAUNCH;
                    end else if (detect_counter == DETECT_PERIOD_CYCLES - 1'b1) begin
                        detect_counter <= 32'd0;
                        detect_index <= 0; poll_error <= 0;
                        state          <= DETECT_PREPARE;
                    end
                    else begin
                        detect_counter <= detect_counter + 1'b1;
                    end
                end

                DETECT_PREPARE: begin
                    if (!iic_busy) begin
                        wr_data <= {16'd0, detect_address, detect_device_address};
                        wr_cnt   <= 8'd2;
                        rd_cnt   <= 8'd1;
                        iic_mode <= 1'b1;
                        iic_en   <= 1'b1;
                        state    <= DETECT_LAUNCH;
                    end
                end

                DETECT_LAUNCH: begin
                    if (iic_busy) begin
                        iic_en <= 1'b0;
                        state  <= DETECT_READ;
                    end
                end

                DETECT_READ: begin
                    if (!iic_busy) begin
                      if (debug_pending) begin
                        debug_response <= {debug_toggle, iic_ack_error, rd_data};
                        debug_pending <= 0;
                        state <= DETECT_WAIT;
                      end else begin
                        verify_read_address <= detect_address;
                        verify_read_ack_error <= iic_ack_error;
                        verify_read_data <= rd_data;
                        if (detect_index <= 2)
                            poll_error <= poll_error || iic_ack_error;
                        if (detect_index == 0) begin
                            // UG-180: HDMI 0x04 bit 1 = TMDS_PLL_LOCKED.
                            if (!hdmi_status_valid || hdmi_locked != next_hdmi_locked)
                                hdmi_status_changed <= 1'b1;
                            hdmi_locked <= next_hdmi_locked;
                            hdmi_status_byte <= iic_ack_error ? 8'd0 : rd_data;
                            hdmi_status_valid <= 1'b1;
                            if (iic_ack_error || !rd_data[1]) hdmi_frequency_valid <= 0;
                        end else if (detect_index == 1) tmds_high <= rd_data;
                        else if (detect_index == 2) begin
                            // {0x51,0x52} = MHz * 128 (9 integer + 7 fraction).
                            // Later reads are diagnostic registers, not the
                            // frequency low byte. Their values and NACKs must
                            // not overwrite a completed lock/frequency sample.
                            hdmi_tmds_q7 <= {tmds_high, rd_data};
                            hdmi_frequency_valid <= !poll_error && !iic_ack_error && hdmi_locked;
                        end
                        if (detect_index >= 7) begin
                            io_config_readback[(detect_index-7)*8 +: 8] <= rd_data;
                            io_config_valid[detect_index-7] <= !iic_ack_error;
                        end
                        if (!MONITOR_TMDS_FREQ ||
                            detect_index == (MONITOR_IO_CONFIG ? 13 : 6)) state <= DETECT_WAIT;
                        else begin detect_index <= detect_index+1'b1; state <= DETECT_PREPARE; end
                      end
                    end
                end

                CFG_FAILED: begin
                    // Keep HPD low after a failed configuration attempt.
                    iic_en <= 1'b0;
                    hdmi_locked <= 1'b0;
                    hdmi_status_valid <= 1'b0;
                end

                default: state <= CFG_PREPARE;
            endcase
        end
    end

    i2c_top #(
        .WMEN_LEN(4),
        .RMEN_LEN(1),
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .SCL_FREQ(SCL_FREQ)
    ) iic_ctrl (
        .clk_i(clk),
        .rst_n(rst_n),
        .iic_scl(scl),
        .iic_sda(sda),
        .wr_data(wr_data),
        .wr_cnt(wr_cnt),
        .rd_data(rd_data),
        .rd_cnt(rd_cnt),
        .iic_mode(iic_mode),
        .iic_en(iic_en),
        .iic_busy(iic_busy),
        .sda_dg(),
        .iic_ack_error(iic_ack_error)
    );

    assign i2c_ack_error_debug = iic_ack_error;
    assign i2c_busy_debug = iic_busy;

endmodule
