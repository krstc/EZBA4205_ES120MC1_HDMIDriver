// A parameterized status source with a register-only 5x7 text scanner. Avoiding
// division/modulo keeps the pixel path comfortably inside the 50 MHz budget.
module status_frame_source #(
    parameter H_TOTAL = 2200,
    parameter H_SYNC = 44,
    parameter H_START = 190,
    parameter H_ACTIVE = 1920,
    parameter V_TOTAL = 1125,
    parameter V_SYNC = 5,
    parameter V_START = 41,
    parameter V_ACTIVE = 1080,
    parameter GLYPH_SCALE = 24,
    // fdma_w_gray transfers sync events through xpm_cdc_pulse.  In pulse
    // mode, drive one source-clock event per line/frame instead of a video
    // sync level that remains asserted for several pixel clocks.
    parameter SINGLE_CLOCK_SYNC = 0,
    // The ES120 panel is mounted portrait on the controller although its
    // source/gate address space is landscape (2560 by 1600).
    parameter ROTATE_CW = 0,
    parameter ROTATED_GLYPH_SCALE = 16,
    // Set to zero for the legacy text-only source.  The ES120 build uses ten
    // seconds at 50 MHz to validate the entire panel path before hand-off.
    parameter integer BOOT_PATTERN_CYCLES = 0,
    parameter integer BOOT_STRIPE_WIDTH = 80
    )(
    input wire pix_clk,
    input wire rst_n,
    input wire hdmi_locked,
    output wire boot_pattern_active,
    output wire gray_de,
    output wire gray_hs,
    output wire gray_vs,
    output wire [7:0] gray_data
    );

    localparam GLYPH_W = 5 * GLYPH_SCALE;
    localparam GLYPH_H = 7 * GLYPH_SCALE;
    localparam CHAR_PITCH = 6 * GLYPH_SCALE;
    localparam HDMI_CHAR_COUNT = 7;
    localparam NO_SIGNAL_CHAR_COUNT = 12;
    localparam HDMI_LEFT = (H_ACTIVE - HDMI_CHAR_COUNT * CHAR_PITCH) / 2;
    localparam NO_SIGNAL_LEFT = (H_ACTIVE - NO_SIGNAL_CHAR_COUNT * CHAR_PITCH) / 2;
    localparam TEXT_TOP = (V_ACTIVE - GLYPH_H) / 2;
    localparam ROT_GLYPH_H = 7 * ROTATED_GLYPH_SCALE;
    localparam ROT_CHAR_PITCH = 6 * ROTATED_GLYPH_SCALE;
    localparam ROT_HDMI_LEFT = (V_ACTIVE - HDMI_CHAR_COUNT * ROT_CHAR_PITCH) / 2;
    localparam ROT_NO_SIGNAL_LEFT = (V_ACTIVE - NO_SIGNAL_CHAR_COUNT * ROT_CHAR_PITCH) / 2;
    localparam ROT_TEXT_TOP = (H_ACTIVE - ROT_GLYPH_H) / 2;

    reg [11:0] h_count;
    reg [10:0] v_count;
    (* ASYNC_REG = "TRUE" *) reg [1:0] locked_sync;
    reg status_locked;
    reg [11:0] active_x;
    reg [10:0] active_y;
    reg [7:0] char_code;
    reg [3:0] char_index;
    reg [2:0] glyph_row_index;
    reg [2:0] glyph_col_index;
    reg [4:0] glyph_bits;
    reg [4:0] x_scale_count;
    reg [4:0] y_scale_count;
    reg text_line;
    reg text_area;
    reg black_pixel;
    reg [7:0] rotated_char_code;
    reg [4:0] rotated_glyph_bits;
    reg rotated_black_pixel;
    reg [31:0] boot_pattern_counter;
    reg boot_pattern_running;
    reg boot_pattern_frame;

    wire active_video = (h_count >= H_START) && (h_count < H_START + H_ACTIVE) &&
                        (v_count >= V_START) && (v_count < V_START + V_ACTIVE);
    wire start_of_line = (h_count == H_START);
    wire end_of_line = (h_count == H_START + H_ACTIVE - 1);
    wire start_of_frame = (h_count == H_START) && (v_count == V_START);
    wire active_pixel = active_video;
    wire first_text_line = (v_count == V_START + TEXT_TOP);
    wire hsync_pulse = (h_count == H_TOTAL - 1);
    wire vsync_pulse = (h_count == 0) && (v_count == 0);
    wire [11:0] source_x = h_count - H_START;
    wire [10:0] source_y = v_count - V_START;
    wire [10:0] rotated_x = V_ACTIVE - 1 - source_y;
    wire [11:0] rotated_y = source_x;
    wire [10:0] rotated_text_left = status_locked ? ROT_HDMI_LEFT : ROT_NO_SIGNAL_LEFT;
    wire [10:0] rotated_text_width = status_locked ?
                                   HDMI_CHAR_COUNT * ROT_CHAR_PITCH :
                                   NO_SIGNAL_CHAR_COUNT * ROT_CHAR_PITCH;
    wire rotated_text_area = active_video &&
                             (rotated_x >= rotated_text_left) &&
                             (rotated_x < rotated_text_left + rotated_text_width) &&
                             (rotated_y >= ROT_TEXT_TOP) &&
                             (rotated_y < ROT_TEXT_TOP + ROT_GLYPH_H);
    wire [10:0] rotated_relative_x = rotated_x - rotated_text_left;
    wire [11:0] rotated_relative_y = rotated_y - ROT_TEXT_TOP;
    wire [3:0] rotated_char_index = rotated_character_index(rotated_relative_x);
    wire [10:0] rotated_char_start = rotated_character_start(rotated_char_index);
    wire [2:0] rotated_glyph_col = (rotated_relative_x - rotated_char_start) >> 4;
    wire [2:0] rotated_glyph_row = rotated_relative_y >> 4;
    wire boot_stripe_black_pixel =
        (source_x < BOOT_STRIPE_WIDTH * 1) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 2) && (source_x < BOOT_STRIPE_WIDTH * 3)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 4) && (source_x < BOOT_STRIPE_WIDTH * 5)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 6) && (source_x < BOOT_STRIPE_WIDTH * 7)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 8) && (source_x < BOOT_STRIPE_WIDTH * 9)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 10) && (source_x < BOOT_STRIPE_WIDTH * 11)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 12) && (source_x < BOOT_STRIPE_WIDTH * 13)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 14) && (source_x < BOOT_STRIPE_WIDTH * 15)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 16) && (source_x < BOOT_STRIPE_WIDTH * 17)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 18) && (source_x < BOOT_STRIPE_WIDTH * 19)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 20) && (source_x < BOOT_STRIPE_WIDTH * 21)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 22) && (source_x < BOOT_STRIPE_WIDTH * 23)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 24) && (source_x < BOOT_STRIPE_WIDTH * 25)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 26) && (source_x < BOOT_STRIPE_WIDTH * 27)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 28) && (source_x < BOOT_STRIPE_WIDTH * 29)) ||
        ((source_x >= BOOT_STRIPE_WIDTH * 30) && (source_x < BOOT_STRIPE_WIDTH * 31));

    function [7:0] message_character;
        input is_locked;
        input [3:0] index;
        begin
            if (is_locked) begin
                case (index)
                    4'd0: message_character = "H";
                    4'd1: message_character = "D";
                    4'd2: message_character = "M";
                    4'd3: message_character = "I";
                    4'd4: message_character = " ";
                    4'd5: message_character = "I";
                    4'd6: message_character = "N";
                    default: message_character = " ";
                endcase
            end
            else begin
                case (index)
                    4'd0:  message_character = "N";
                    4'd1:  message_character = "O";
                    4'd2:  message_character = " ";
                    4'd3:  message_character = "S";
                    4'd4:  message_character = "I";
                    4'd5:  message_character = "G";
                    4'd6:  message_character = "N";
                    4'd7:  message_character = "A";
                    4'd8:  message_character = "L";
                    4'd9:  message_character = "!";
                    4'd10: message_character = "!";
                    4'd11: message_character = "!";
                    default: message_character = " ";
                endcase
            end
        end
    endfunction

    function [3:0] rotated_character_index;
        input [10:0] x;
        begin
            if (x < 96) rotated_character_index = 4'd0;
            else if (x < 192) rotated_character_index = 4'd1;
            else if (x < 288) rotated_character_index = 4'd2;
            else if (x < 384) rotated_character_index = 4'd3;
            else if (x < 480) rotated_character_index = 4'd4;
            else if (x < 576) rotated_character_index = 4'd5;
            else if (x < 672) rotated_character_index = 4'd6;
            else if (x < 768) rotated_character_index = 4'd7;
            else if (x < 864) rotated_character_index = 4'd8;
            else if (x < 960) rotated_character_index = 4'd9;
            else if (x < 1056) rotated_character_index = 4'd10;
            else rotated_character_index = 4'd11;
        end
    endfunction

    function [10:0] rotated_character_start;
        input [3:0] index;
        begin
            // One character pitch is 96 = 64 + 32 pixels.
            rotated_character_start = {index, 6'b0} + {index, 5'b0};
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] c;
        input [2:0] row;
        begin
            case (c)
                "A": case (row)
                    0: glyph_row = 5'b01110; 1: glyph_row = 5'b10001;
                    2: glyph_row = 5'b10001; 3: glyph_row = 5'b11111;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b10001;
                endcase
                "D": case (row)
                    0: glyph_row = 5'b11110; 1: glyph_row = 5'b10001;
                    2: glyph_row = 5'b10001; 3: glyph_row = 5'b10001;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b11110;
                endcase
                "G": case (row)
                    0: glyph_row = 5'b01110; 1: glyph_row = 5'b10001;
                    2: glyph_row = 5'b10000; 3: glyph_row = 5'b10111;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b01110;
                endcase
                "H": case (row)
                    0: glyph_row = 5'b10001; 1: glyph_row = 5'b10001;
                    2: glyph_row = 5'b10001; 3: glyph_row = 5'b11111;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b10001;
                endcase
                "I": case (row)
                    0: glyph_row = 5'b11111; 1: glyph_row = 5'b00100;
                    2: glyph_row = 5'b00100; 3: glyph_row = 5'b00100;
                    4: glyph_row = 5'b00100; 5: glyph_row = 5'b00100;
                    default: glyph_row = 5'b11111;
                endcase
                "L": case (row)
                    0: glyph_row = 5'b10000; 1: glyph_row = 5'b10000;
                    2: glyph_row = 5'b10000; 3: glyph_row = 5'b10000;
                    4: glyph_row = 5'b10000; 5: glyph_row = 5'b10000;
                    default: glyph_row = 5'b11111;
                endcase
                "M": case (row)
                    0: glyph_row = 5'b10001; 1: glyph_row = 5'b11011;
                    2: glyph_row = 5'b10101; 3: glyph_row = 5'b10101;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b10001;
                endcase
                "N": case (row)
                    0: glyph_row = 5'b10001; 1: glyph_row = 5'b11001;
                    2: glyph_row = 5'b10101; 3: glyph_row = 5'b10011;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b10001;
                endcase
                "O": case (row)
                    0: glyph_row = 5'b01110; 1: glyph_row = 5'b10001;
                    2: glyph_row = 5'b10001; 3: glyph_row = 5'b10001;
                    4: glyph_row = 5'b10001; 5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b01110;
                endcase
                "S": case (row)
                    0: glyph_row = 5'b01111; 1: glyph_row = 5'b10000;
                    2: glyph_row = 5'b10000; 3: glyph_row = 5'b01110;
                    4: glyph_row = 5'b00001; 5: glyph_row = 5'b00001;
                    default: glyph_row = 5'b11110;
                endcase
                "!": case (row)
                    0: glyph_row = 5'b00100; 1: glyph_row = 5'b00100;
                    2: glyph_row = 5'b00100; 3: glyph_row = 5'b00100;
                    4: glyph_row = 5'b00100; 5: glyph_row = 5'b00000;
                    default: glyph_row = 5'b00100;
                endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= 12'd0;
            v_count <= 11'd0;
            locked_sync <= 2'b00;
            status_locked <= 1'b0;
            active_x <= 12'd0;
            active_y <= 11'd0;
            char_index <= 4'd0;
            glyph_row_index <= 3'd0;
            glyph_col_index <= 3'd0;
            x_scale_count <= 5'd0;
            y_scale_count <= 5'd0;
            text_line <= 1'b0;
            text_area <= 1'b0;
            boot_pattern_counter <= 32'd0;
            boot_pattern_running <= (BOOT_PATTERN_CYCLES != 0);
            boot_pattern_frame <= (BOOT_PATTERN_CYCLES != 0);
        end
        else begin
            locked_sync <= {locked_sync[0], hdmi_locked};

            if (boot_pattern_running) begin
                if (boot_pattern_counter == BOOT_PATTERN_CYCLES - 1) begin
                    boot_pattern_running <= 1'b0;
                end
                else begin
                    boot_pattern_counter <= boot_pattern_counter + 1'b1;
                end
            end

            if (h_count == H_TOTAL - 1) begin
                h_count <= 12'd0;
                if (v_count == V_TOTAL - 1) begin
                    v_count <= 11'd0;
                    status_locked <= locked_sync[1];
                    // Only switch source content between complete frames.
                    boot_pattern_frame <= boot_pattern_running;
                end
                else begin
                    v_count <= v_count + 1'b1;
                end
            end
            else begin
                h_count <= h_count + 1'b1;
            end

            if (start_of_frame) begin
                active_y <= 11'd0;
            end
            else if (end_of_line && active_video) begin
                active_y <= active_y + 1'b1;
            end

            if (start_of_line) begin
                active_x <= 12'd0;
                if (v_count == V_START + TEXT_TOP) begin
                    text_line <= 1'b1;
                    glyph_row_index <= 3'd0;
                    y_scale_count <= 5'd0;
                end
                else if (text_line && y_scale_count == GLYPH_SCALE - 1) begin
                    y_scale_count <= 5'd0;
                    if (glyph_row_index == 3'd6) begin
                        text_line <= 1'b0;
                        glyph_row_index <= 3'd0;
                    end
                    else begin
                        glyph_row_index <= glyph_row_index + 1'b1;
                    end
                end
                else if (text_line) begin
                    y_scale_count <= y_scale_count + 1'b1;
                end

                char_index <= 4'd0;
                glyph_col_index <= 3'd0;
                x_scale_count <= 5'd0;
                text_area <= 1'b0;
            end
            else if (active_pixel) begin
                active_x <= active_x + 1'b1;
                if (!text_area) begin
                    if (active_x == (status_locked ? HDMI_LEFT : NO_SIGNAL_LEFT) - 1) begin
                        text_area <= text_line;
                        char_index <= 4'd0;
                        glyph_col_index <= 3'd0;
                        x_scale_count <= 5'd0;
                    end
                end
                else if (x_scale_count == GLYPH_SCALE - 1) begin
                    x_scale_count <= 5'd0;
                    if (glyph_col_index == 3'd5) begin
                        glyph_col_index <= 3'd0;
                        if (char_index == (status_locked ? HDMI_CHAR_COUNT : NO_SIGNAL_CHAR_COUNT) - 1) begin
                            text_area <= 1'b0;
                        end
                        else begin
                            char_index <= char_index + 1'b1;
                        end
                    end
                    else begin
                        glyph_col_index <= glyph_col_index + 1'b1;
                    end
                end
                else begin
                    x_scale_count <= x_scale_count + 1'b1;
                end

            end
        end
    end

    always @(*) begin
        char_code = message_character(status_locked, char_index);
        glyph_bits = glyph_row(char_code, glyph_row_index);
        black_pixel = text_area && text_line && (glyph_col_index < 5) &&
                      glyph_bits[4 - glyph_col_index];

        rotated_char_code = message_character(status_locked, rotated_char_index);
        rotated_glyph_bits = glyph_row(rotated_char_code, rotated_glyph_row);
        if (rotated_text_area && (rotated_glyph_col < 5)) begin
            rotated_black_pixel = rotated_glyph_bits[4 - rotated_glyph_col];
        end
        else begin
            rotated_black_pixel = 1'b0;
        end
    end

    assign gray_de = active_video;
    assign gray_hs = SINGLE_CLOCK_SYNC ? hsync_pulse : (h_count < H_SYNC);
    assign gray_vs = SINGLE_CLOCK_SYNC ? vsync_pulse : (v_count < V_SYNC);
    assign boot_pattern_active = boot_pattern_frame;
    assign gray_data = boot_pattern_frame ?
                       (boot_stripe_black_pixel ? 8'h00 : 8'hff) :
                       ((ROTATE_CW ? rotated_black_pixel : black_pixel) ? 8'h00 : 8'hff);

endmodule
