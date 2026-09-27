// Native panel coordinates. Only the capture manager changes stripes, while
// no capture is active; the next VS starts a complete, immutable source frame.
module status_source_es120mc1 #(
    parameter NATIVE_GC16 = 0,
    parameter H_ACTIVE = 2560, V_ACTIVE = 1600,
    parameter SCALE = 8, STRIPE_WIDTH = 80,
    parameter H_START = 112, H_TOTAL = 2720,
    parameter V_START = 17, V_TOTAL = 1620,
    // Keep each startup stripe spatially solid. A spatial half-gray pattern
    // creates periodic gaps in a diagnostic bar on this panel.
    parameter BOOT_STRIPE_HALF_GRAY = 0
)(
    input wire clk, rst_n, stripes,
    input wire [1:0] status_mode,
    input wire [1:0] mode_notice,
    input wire [15:0] hdmi_tmds_q7,
    input wire hdmi_rate_valid,
    output wire gray_de, gray_hs, gray_vs,
    output wire [7:0] gray_data,
    output wire [3:0] gray_source
);
    localparam MAX_MESSAGE_CHARS = 14;
    localparam TEXT_WIDTH = (MAX_MESSAGE_CHARS * 6 - 1) * SCALE;
    localparam TEXT_HEIGHT = 7 * SCALE;
    localparam LEFT = (H_ACTIVE - TEXT_WIDTH) / 2;
    localparam TOP = (V_ACTIVE - TEXT_HEIGHT) / 2;
    reg [11:0] h, v;
    wire [11:0] x = h - H_START;
    wire [11:0] y = v - V_START;
    reg text_black;
    integer c;
    reg [34:0] glyph;
    integer col, row;
    wire stripe_black = ((x / STRIPE_WIDTH) % 2) == 0;
    wire stripe_half_gray_pixel = 1'b1;
    // Status text is 75% luminance gray: one stable black dot per 2x2 cell.
    // Spatial modulation is required because the downstream status path is
    // intentionally binary and would threshold a literal 8'hbf to white.
    wire text_gray_black = text_black && !x[0] && !y[0];

    function [7:0] message_character;
        input [1:0] mode;
        input integer index;
        integer mhz;
        begin
            mhz = hdmi_tmds_q7 / 128;
            if (mode == 2'd1) begin
                case (index)
                    0: message_character = "H"; 1: message_character = "D";
                    2: message_character = "M"; 3: message_character = "I";
                    4: message_character = " "; 5: message_character = "I";
                    6: message_character = "N";
                    default: message_character = " ";
                endcase
            end
            else if (mode == 2'd2) begin
                case (index)
                    0: message_character = "T"; 1: message_character = "M";
                    2: message_character = "D"; 3: message_character = "S";
                    4: message_character = " ";
                    5: message_character = 8'd48 + ((mhz / 100) % 10);
                    6: message_character = 8'd48 + ((mhz / 10) % 10);
                    7: message_character = 8'd48 + (mhz % 10);
                    8: message_character = "M"; 9: message_character = " ";
                    10: message_character = hdmi_rate_valid ? "2" : "W";
                    11: message_character = hdmi_rate_valid ? "5" : "A";
                    12: message_character = hdmi_rate_valid ? "H" : "I";
                    13: message_character = hdmi_rate_valid ? "Z" : "T";
                    default: message_character = " ";
                endcase
            end
            else begin
                case (index)
                    0: message_character = "N"; 1: message_character = "O";
                    2: message_character = " "; 3: message_character = "S";
                    4: message_character = "I"; 5: message_character = "G";
                    6: message_character = "N"; 7: message_character = "A";
                    8: message_character = "L";
                    default: message_character = " ";
                endcase
            end
        end
    endfunction

    function integer message_length;
        input [1:0] mode;
        begin
            case (mode)
                2'd1: message_length = 7;
                2'd2: message_length = 14;
                default: message_length = 9;
            endcase
        end
    endfunction

    function [34:0] letter;
        input [7:0] ch;
        begin
            case (ch)
                "N": letter = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "O": letter = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "S": letter = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "I": letter = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "G": letter = {5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
                "A": letter = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "L": letter = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "H": letter = {5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001,5'b10001};
                "D": letter = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "M": letter = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "T": letter = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "W": letter = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "Z": letter = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                "0": letter = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": letter = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": letter = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "5": letter = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "?": letter = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b00000,5'b00100};
                default: letter = 35'd0;
            endcase
        end
    endfunction

    // Fixed per-character windows avoid a stateful scanner or expensive
    // division by the non-power-of-two character pitch in the pixel path.
    integer message_len;
    integer message_left;
    always @* begin
        text_black = 0;
        glyph = 0;
        col = 0;
        row = 0;
        message_len = message_length(status_mode);
        message_left = (H_ACTIVE - (message_len * 6 - 1) * SCALE) / 2;
        for (c = 0; c < MAX_MESSAGE_CHARS; c = c + 1) begin
            if (c < message_len && x >= message_left + c*6*SCALE &&
                x < message_left + (c*6+5)*SCALE &&
                y >= TOP && y < TOP + TEXT_HEIGHT) begin
                glyph = letter(message_character(status_mode, c));
                col = (x - message_left - c*6*SCALE) / SCALE;
                row = (y - TOP) / SCALE;
                text_black = glyph[34 - row*5 - col];
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin h <= 0; v <= 0; end
        else if (h == H_TOTAL-1) begin
            h <= 0;
            v <= (v == V_TOTAL-1) ? 0 : v+1'b1;
        end else h <= h+1'b1;
    end
    assign gray_de = h >= H_START && h < H_START+H_ACTIVE &&
                     v >= V_START && v < V_START+V_ACTIVE;
    assign gray_hs = h < 32;
    assign gray_vs = v < 6;
    wire [7:0] status_base = NATIVE_GC16 ? (text_black ? 8'hbb : 8'hff) :
                              (text_gray_black ? 8'h00 : 8'hff);
    wire [7:0] mode_base = (mode_notice != 0) ? 8'hff : status_base;
    wire [7:0] mode_overlay_data;
    mode_overlay_es120mc1 #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .SCALE(SCALE))
        mode_overlay (
            .x(x), .y(y), .base_gray(mode_base), .mode_notice(mode_notice),
            .gray_out(mode_overlay_data)
        );
    assign gray_data = !gray_de ? 8'hff :
                      (stripes ?
                       ((stripe_black &&
                         (!BOOT_STRIPE_HALF_GRAY || stripe_half_gray_pixel)) ? 8'h00 : 8'hff) :
                       mode_overlay_data);
    assign gray_source = gray_data[7:4];
endmodule

// The mode announcement is rendered as a self-contained box. It is kept in
// this small combinational block so the same geometry can be used on the
// local status clock and on the HDMI pixel clock without a frame buffer copy.
module mode_overlay_es120mc1 #(
    parameter H_ACTIVE=2560, V_ACTIVE=1600, SCALE=8
)(
    input wire [11:0] x, y,
    input wire [7:0] base_gray,
    input wire [1:0] mode_notice,
    output reg [7:0] gray_out
);
    localparam MAX_CHARS=4;
    localparam GLYPH_SIZE=32;
    // Keep the scale a power of two so row/column selection synthesizes to
    // wiring shifts instead of a divider. The mode label is intentionally
    // compact so it does not dominate the display.
    localparam GLYPH_SCALE=2;
    localparam GLYPH_PITCH=36*GLYPH_SCALE;
    localparam TEXT_HEIGHT=GLYPH_SIZE*GLYPH_SCALE;
    localparam BORDER_PX=2;
    integer chars, text_width, left, top, right, bottom;
    integer box_left, box_top, box_right, box_bottom;
    integer c, col, row;
    reg [31:0] glyph_row_data;
    reg text_pixel, overlay_inside, border;

    // Regular Microsoft YaHei glyphs rendered at 32x32 and displayed at 2x.
    // The panel label is half the previous physical size and is not bold.
    function [31:0] chinese_row;
        input [2:0] id;
        input [5:0] row_id;
        begin
            chinese_row=32'h00000000;
            case(id)
                3'd0: case(row_id)
                    6'd0: chinese_row=32'h00004000;
                    6'd1: chinese_row=32'h2000e000;
                    6'd2: chinese_row=32'h78007000;
                    6'd3: chinese_row=32'h3c003800;
                    6'd4: chinese_row=32'h1e7ffffc;
                    6'd5: chinese_row=32'h0f7ffffc;
                    6'd6: chinese_row=32'h02018000;
                    6'd7: chinese_row=32'h0003c000;
                    6'd8: chinese_row=32'h00078080;
                    6'd9: chinese_row=32'h400f01c0;
                    6'd10: chinese_row=32'he01e00e0;
                    6'd11: chinese_row=32'h703c00f0;
                    6'd12: chinese_row=32'h3c780070;
                    6'd13: chinese_row=32'h1cfffff8;
                    6'd14: chinese_row=32'h087ff81c;
                    6'd15: chinese_row=32'h00000008;
                    6'd16: chinese_row=32'h00186180;
                    6'd17: chinese_row=32'h00186180;
                    6'd18: chinese_row=32'h08186180;
                    6'd19: chinese_row=32'h0c186180;
                    6'd20: chinese_row=32'h1c186180;
                    6'd21: chinese_row=32'h18186180;
                    6'd22: chinese_row=32'h18386180;
                    6'd23: chinese_row=32'h18306184;
                    6'd24: chinese_row=32'h18306186;
                    6'd25: chinese_row=32'h30706186;
                    6'd26: chinese_row=32'h30606186;
                    6'd27: chinese_row=32'h30e0618e;
                    6'd28: chinese_row=32'h73c061fc;
                    6'd29: chinese_row=32'h678060f8;
                    6'd30: chinese_row=32'h22000000;
                    6'd31: chinese_row=32'h00000000;
                    default: chinese_row=32'h00000000;
                endcase
                3'd1: case(row_id)
                    6'd0: chinese_row=32'h03000000;
                    6'd1: chinese_row=32'h03000000;
                    6'd2: chinese_row=32'h0301fff0;
                    6'd3: chinese_row=32'h0301fff0;
                    6'd4: chinese_row=32'h030000e0;
                    6'd5: chinese_row=32'h7ff803c0;
                    6'd6: chinese_row=32'h7ff80780;
                    6'd7: chinese_row=32'h63180e00;
                    6'd8: chinese_row=32'h63183c00;
                    6'd9: chinese_row=32'h63187800;
                    6'd10: chinese_row=32'h6318f000;
                    6'd11: chinese_row=32'h631bc000;
                    6'd12: chinese_row=32'h7ffbfffc;
                    6'd13: chinese_row=32'h7ffbfffc;
                    6'd14: chinese_row=32'h6318318c;
                    6'd15: chinese_row=32'h6318318c;
                    6'd16: chinese_row=32'h6318718c;
                    6'd17: chinese_row=32'h6318638c;
                    6'd18: chinese_row=32'h6318e30c;
                    6'd19: chinese_row=32'h7ff8c30c;
                    6'd20: chinese_row=32'h7ff9c71c;
                    6'd21: chinese_row=32'h63038618;
                    6'd22: chinese_row=32'h03070e18;
                    6'd23: chinese_row=32'h030f0c18;
                    6'd24: chinese_row=32'h031c1c18;
                    6'd25: chinese_row=32'h03083818;
                    6'd26: chinese_row=32'h03007018;
                    6'd27: chinese_row=32'h0300e038;
                    6'd28: chinese_row=32'h0301eff0;
                    6'd29: chinese_row=32'h0303c7e0;
                    6'd30: chinese_row=32'h03010000;
                    6'd31: chinese_row=32'h00000000;
                    default: chinese_row=32'h00000000;
                endcase
                3'd2: case(row_id)
                    6'd0: chinese_row=32'h0600c0c0;
                    6'd1: chinese_row=32'h0600c0c0;
                    6'd2: chinese_row=32'h0600c0c0;
                    6'd3: chinese_row=32'h063ffffe;
                    6'd4: chinese_row=32'h063ffffe;
                    6'd5: chinese_row=32'h0600c0c0;
                    6'd6: chinese_row=32'h0600c0c0;
                    6'd7: chinese_row=32'hffe0c0c0;
                    6'd8: chinese_row=32'hffe00000;
                    6'd9: chinese_row=32'h0e0ffff8;
                    6'd10: chinese_row=32'h0e0ffff8;
                    6'd11: chinese_row=32'h0e0c0018;
                    6'd12: chinese_row=32'h0e8c0018;
                    6'd13: chinese_row=32'h1fcffff8;
                    6'd14: chinese_row=32'h1ecffff8;
                    6'd15: chinese_row=32'h16ec0018;
                    6'd16: chinese_row=32'h367c0018;
                    6'd17: chinese_row=32'h362ffff8;
                    6'd18: chinese_row=32'h660ffff8;
                    6'd19: chinese_row=32'h660c0c18;
                    6'd20: chinese_row=32'hc6000c00;
                    6'd21: chinese_row=32'hc6000c00;
                    6'd22: chinese_row=32'h863ffffe;
                    6'd23: chinese_row=32'h063ffffe;
                    6'd24: chinese_row=32'h06003e00;
                    6'd25: chinese_row=32'h06007700;
                    6'd26: chinese_row=32'h0600e380;
                    6'd27: chinese_row=32'h0603c1c0;
                    6'd28: chinese_row=32'h060f00f0;
                    6'd29: chinese_row=32'h067c003e;
                    6'd30: chinese_row=32'h0630000c;
                    6'd31: chinese_row=32'h00000000;
                    default: chinese_row=32'h00000000;
                endcase
                3'd3: case(row_id)
                    6'd0: chinese_row=32'h00000000;
                    6'd1: chinese_row=32'h00003080;
                    6'd2: chinese_row=32'h000031e0;
                    6'd3: chinese_row=32'h000030f0;
                    6'd4: chinese_row=32'h00003078;
                    6'd5: chinese_row=32'h00003010;
                    6'd6: chinese_row=32'h00003000;
                    6'd7: chinese_row=32'hffffffff;
                    6'd8: chinese_row=32'hffffffff;
                    6'd9: chinese_row=32'h00003000;
                    6'd10: chinese_row=32'h00003000;
                    6'd11: chinese_row=32'h00003000;
                    6'd12: chinese_row=32'h00001000;
                    6'd13: chinese_row=32'h00001800;
                    6'd14: chinese_row=32'h7fff9800;
                    6'd15: chinese_row=32'h7fff9800;
                    6'd16: chinese_row=32'h00c01800;
                    6'd17: chinese_row=32'h00c01800;
                    6'd18: chinese_row=32'h00c01800;
                    6'd19: chinese_row=32'h00c01c00;
                    6'd20: chinese_row=32'h00c00c00;
                    6'd21: chinese_row=32'h00c00c00;
                    6'd22: chinese_row=32'h00c00c02;
                    6'd23: chinese_row=32'h00c00e03;
                    6'd24: chinese_row=32'h00c3c603;
                    6'd25: chinese_row=32'h00ffc707;
                    6'd26: chinese_row=32'h1ffc0386;
                    6'd27: chinese_row=32'hff0003c6;
                    6'd28: chinese_row=32'he00001fe;
                    6'd29: chinese_row=32'h000000fc;
                    6'd30: chinese_row=32'h0000003c;
                    6'd31: chinese_row=32'h00000000;
                    default: chinese_row=32'h00000000;
                endcase
                3'd4: case(row_id)
                    6'd0: chinese_row=32'h00010000;
                    6'd1: chinese_row=32'h00038000;
                    6'd2: chinese_row=32'h00018000;
                    6'd3: chinese_row=32'h0001c000;
                    6'd4: chinese_row=32'h0000c000;
                    6'd5: chinese_row=32'h00008000;
                    6'd6: chinese_row=32'h7ffffffe;
                    6'd7: chinese_row=32'h7ffffffe;
                    6'd8: chinese_row=32'h01800180;
                    6'd9: chinese_row=32'h01800180;
                    6'd10: chinese_row=32'h01800180;
                    6'd11: chinese_row=32'h01c00300;
                    6'd12: chinese_row=32'h00c00300;
                    6'd13: chinese_row=32'h00c00300;
                    6'd14: chinese_row=32'h00e00600;
                    6'd15: chinese_row=32'h00600600;
                    6'd16: chinese_row=32'h00700c00;
                    6'd17: chinese_row=32'h00300c00;
                    6'd18: chinese_row=32'h00381800;
                    6'd19: chinese_row=32'h00183800;
                    6'd20: chinese_row=32'h000c7000;
                    6'd21: chinese_row=32'h000ee000;
                    6'd22: chinese_row=32'h0007c000;
                    6'd23: chinese_row=32'h0003c000;
                    6'd24: chinese_row=32'h0007e000;
                    6'd25: chinese_row=32'h001e7800;
                    6'd26: chinese_row=32'h003c3c00;
                    6'd27: chinese_row=32'h00f01f00;
                    6'd28: chinese_row=32'h03e007c0;
                    6'd29: chinese_row=32'h1f0001f8;
                    6'd30: chinese_row=32'h7c00007e;
                    6'd31: chinese_row=32'h30000018;
                    default: chinese_row=32'h00000000;
                endcase
                3'd5: case(row_id)
                    6'd0: chinese_row=32'h00018000;
                    6'd1: chinese_row=32'h00018000;
                    6'd2: chinese_row=32'h00018000;
                    6'd3: chinese_row=32'h00018000;
                    6'd4: chinese_row=32'h00018000;
                    6'd5: chinese_row=32'h00018000;
                    6'd6: chinese_row=32'h3ffffffe;
                    6'd7: chinese_row=32'h3ffffffe;
                    6'd8: chinese_row=32'h0003c000;
                    6'd9: chinese_row=32'h0007e000;
                    6'd10: chinese_row=32'h0007e000;
                    6'd11: chinese_row=32'h000db000;
                    6'd12: chinese_row=32'h0019b800;
                    6'd13: chinese_row=32'h00399800;
                    6'd14: chinese_row=32'h00318c00;
                    6'd15: chinese_row=32'h00618e00;
                    6'd16: chinese_row=32'h00e18700;
                    6'd17: chinese_row=32'h01c18380;
                    6'd18: chinese_row=32'h038181c0;
                    6'd19: chinese_row=32'h070180e0;
                    6'd20: chinese_row=32'h0e018070;
                    6'd21: chinese_row=32'h1c018038;
                    6'd22: chinese_row=32'h3801801e;
                    6'd23: chinese_row=32'h70ffff8f;
                    6'd24: chinese_row=32'h20ffff84;
                    6'd25: chinese_row=32'h00018000;
                    6'd26: chinese_row=32'h00018000;
                    6'd27: chinese_row=32'h00018000;
                    6'd28: chinese_row=32'h00018000;
                    6'd29: chinese_row=32'h00018000;
                    6'd30: chinese_row=32'h00018000;
                    6'd31: chinese_row=32'h00018000;
                    default: chinese_row=32'h00000000;
                endcase
            endcase
        end
    endfunction

    function [2:0] mode_character;
        input [1:0] mode;
        input integer index;
        begin
            if (mode == 2'd1) begin
                case(index)
                    0: mode_character=3'd0; 1: mode_character=3'd1;
                    2: mode_character=3'd2; default: mode_character=3'd3;
                endcase
            end else begin
                case(index)
                    0: mode_character=3'd4; 1: mode_character=3'd5;
                    2: mode_character=3'd2; default: mode_character=3'd3;
                endcase
            end
        end
    endfunction

    always @* begin
        chars=4;
        text_width=chars*GLYPH_PITCH-4*GLYPH_SCALE;
        left=(H_ACTIVE-text_width)/2;
        top=(V_ACTIVE-TEXT_HEIGHT)/2;
        right=left+text_width-1;
        bottom=top+TEXT_HEIGHT-1;
        box_left=left-2*GLYPH_SCALE;
        box_right=right+2*GLYPH_SCALE;
        box_top=top-2*GLYPH_SCALE;
        box_bottom=bottom+2*GLYPH_SCALE;
        overlay_inside=(mode_notice!=0 && x>=box_left && x<=box_right &&
                y>=box_top && y<=box_bottom);
        border=overlay_inside && (x<box_left+BORDER_PX || x>box_right-BORDER_PX ||
                y<box_top+BORDER_PX || y>box_bottom-BORDER_PX);
        text_pixel=0;
        glyph_row_data=0;col=0;row=0;
        for(c=0;c<MAX_CHARS;c=c+1) begin
            if(c<chars && x>=left+c*GLYPH_PITCH && x<left+c*GLYPH_PITCH+GLYPH_SIZE*GLYPH_SCALE &&
               y>=top && y<top+TEXT_HEIGHT) begin
                col=(x-left-c*GLYPH_PITCH)/GLYPH_SCALE;
                row=(y-top)/GLYPH_SCALE;
                glyph_row_data=chinese_row(mode_character(mode_notice,c),row[5:0]);
                text_pixel=glyph_row_data[31-col];
            end
        end
        if(!overlay_inside) gray_out=base_gray;
        else if(border) gray_out=8'h00;
        else if(text_pixel) gray_out=8'h00;
        else gray_out=8'hff;
    end
endmodule
