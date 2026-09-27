// Keep the advertised HDMI geometry separate from the panel/DDR stride.
// Register gray data and cropped DE on the same edge; qualify raw geometry.
module hdmi_input_es120mc1 #(
    parameter INPUT_H = 2560,
    parameter FRAME_H = 2560,
    parameter FRAME_V = 1600,
    parameter DITHER_ENABLE = 0,
    parameter NATIVE_GC16 = 0,
    parameter NATIVE_LIGHTEN = 0,
    parameter VIDEO_LEVELS_ENABLE = 0,
    parameter GAMMA_AWARE_DITHER = 1
    )(
    input wire pix_clk,
    input wire rst_n,
    input wire de_i,
    input wire hs_i,
    input wire vs_i,
    input wire [7:0] gray_i,
    output reg gray_de,
    output reg gray_hs,
    output reg gray_vs,
     output reg [7:0] gray_data,
     // Native 16-level source for the text-mode refine pass. gray_data keeps
     // its legacy binary/8-bit interface for the HDMI timing regressions.
     output reg [3:0] gray_source,
     output wire video_valid,
     // Level held for the current source frame: 1 when its sampled content
     // differs from the previous completed source frame.
     output reg frame_changed,
     input wire native_refine,
     input wire [1:0] mode_notice,
     input wire text_mode
    );

    localparam integer CROP_LEFT = (INPUT_H - FRAME_H) / 2;
    localparam integer CROP_END = CROP_LEFT + FRAME_H;
    reg [12:0] active_pixel_count;
    reg raw_de;
    reg [3:0] active_line_mod16;
    reg [11:0] active_line_count;
    reg [31:0] frame_hash;
    reg [31:0] last_frame_hash;
    reg frame_active_seen;
    reg frame_hash_initialized;
    reg vs_i_d;
    reg [7:0] dither_level_s0;
    reg [7:0] dither_level_s1;
    reg [7:0] dither_level_s2;
    reg [7:0] dither_address_s0;
    reg [7:0] dither_address_s1;
    reg [7:0] dither_address_s2;
    reg [11:0] dither_x_s0, dither_x_s1, dither_x_s2;
    reg [11:0] dither_y_s0, dither_y_s1, dither_y_s2;
    (* ASYNC_REG = "TRUE" *) reg native_refine_s0, native_refine_s1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] mode_notice_s0, mode_notice_s1;
    (* ASYNC_REG = "TRUE" *) reg text_mode_s0, text_mode_s1;
    reg dither_de_s0, dither_de_s1, dither_de_s2;
    reg dither_hs_s0, dither_hs_s1, dither_hs_s2;
    reg dither_vs_s0, dither_vs_s1, dither_vs_s2;

    // Legacy 16x16 void-and-cluster map kept as a reference for the previous
    // 256-density path.  The active video path below uses a 4x4 rank cell so
    // that only sixteen stable spatial gray states are generated.
    function [7:0] blue_noise_rank;
        input [7:0] address;
        begin
            case (address)
                8'h00: blue_noise_rank=8'd62;  8'h01: blue_noise_rank=8'd38;  8'h02: blue_noise_rank=8'd128; 8'h03: blue_noise_rank=8'd9;
                8'h04: blue_noise_rank=8'd226; 8'h05: blue_noise_rank=8'd136; 8'h06: blue_noise_rank=8'd80;  8'h07: blue_noise_rank=8'd12;
                8'h08: blue_noise_rank=8'd165; 8'h09: blue_noise_rank=8'd139; 8'h0a: blue_noise_rank=8'd66;  8'h0b: blue_noise_rank=8'd209;
                8'h0c: blue_noise_rank=8'd20;  8'h0d: blue_noise_rank=8'd250; 8'h0e: blue_noise_rank=8'd190; 8'h0f: blue_noise_rank=8'd219;
                8'h10: blue_noise_rank=8'd115; 8'h11: blue_noise_rank=8'd211; 8'h12: blue_noise_rank=8'd157; 8'h13: blue_noise_rank=8'd74;
                8'h14: blue_noise_rank=8'd188; 8'h15: blue_noise_rank=8'd32;  8'h16: blue_noise_rank=8'd217; 8'h17: blue_noise_rank=8'd125;
                8'h18: blue_noise_rank=8'd182; 8'h19: blue_noise_rank=8'd248; 8'h1a: blue_noise_rank=8'd1;   8'h1b: blue_noise_rank=8'd84;
                8'h1c: blue_noise_rank=8'd174; 8'h1d: blue_noise_rank=8'd131; 8'h1e: blue_noise_rank=8'd77;  8'h1f: blue_noise_rank=8'd22;
                8'h20: blue_noise_rank=8'd178; 8'h21: blue_noise_rank=8'd87;  8'h22: blue_noise_rank=8'd236; 8'h23: blue_noise_rank=8'd49;
                8'h24: blue_noise_rank=8'd110; 8'h25: blue_noise_rank=8'd161; 8'h26: blue_noise_rank=8'd96;  8'h27: blue_noise_rank=8'd63;
                8'h28: blue_noise_rank=8'd47;  8'h29: blue_noise_rank=8'd108; 8'h2a: blue_noise_rank=8'd149; 8'h2b: blue_noise_rank=8'd230;
                8'h2c: blue_noise_rank=8'd44;  8'h2d: blue_noise_rank=8'd103; 8'h2e: blue_noise_rank=8'd151; 8'h2f: blue_noise_rank=8'd243;
                8'h30: blue_noise_rank=8'd6;   8'h31: blue_noise_rank=8'd142; 8'h32: blue_noise_rank=8'd30;  8'h33: blue_noise_rank=8'd196;
                8'h34: blue_noise_rank=8'd224; 8'h35: blue_noise_rank=8'd4;   8'h36: blue_noise_rank=8'd246; 8'h37: blue_noise_rank=8'd192;
                8'h38: blue_noise_rank=8'd220; 8'h39: blue_noise_rank=8'd26;  8'h3a: blue_noise_rank=8'd204; 8'h3b: blue_noise_rank=8'd117;
                8'h3c: blue_noise_rank=8'd184; 8'h3d: blue_noise_rank=8'd11;  8'h3e: blue_noise_rank=8'd216; 8'h3f: blue_noise_rank=8'd55;
                8'h40: blue_noise_rank=8'd202; 8'h41: blue_noise_rank=8'd101; 8'h42: blue_noise_rank=8'd169; 8'h43: blue_noise_rank=8'd127;
                8'h44: blue_noise_rank=8'd67;  8'h45: blue_noise_rank=8'd147; 8'h46: blue_noise_rank=8'd39;  8'h47: blue_noise_rank=8'd135;
                8'h48: blue_noise_rank=8'd73;  8'h49: blue_noise_rank=8'd164; 8'h4a: blue_noise_rank=8'd90;  8'h4b: blue_noise_rank=8'd58;
                8'h4c: blue_noise_rank=8'd239; 8'h4d: blue_noise_rank=8'd70;  8'h4e: blue_noise_rank=8'd167; 8'h4f: blue_noise_rank=8'd121;
                8'h50: blue_noise_rank=8'd229; 8'h51: blue_noise_rank=8'd72;  8'h52: blue_noise_rank=8'd254; 8'h53: blue_noise_rank=8'd15;
                8'h54: blue_noise_rank=8'd99;  8'h55: blue_noise_rank=8'd207; 8'h56: blue_noise_rank=8'd176; 8'h57: blue_noise_rank=8'd113;
                8'h58: blue_noise_rank=8'd10;  8'h59: blue_noise_rank=8'd253; 8'h5a: blue_noise_rank=8'd140; 8'h5b: blue_noise_rank=8'd17;
                8'h5c: blue_noise_rank=8'd201; 8'h5d: blue_noise_rank=8'd143; 8'h5e: blue_noise_rank=8'd89;  8'h5f: blue_noise_rank=8'd41;
                8'h60: blue_noise_rank=8'd18;  8'h61: blue_noise_rank=8'd150; 8'h62: blue_noise_rank=8'd51;  8'h63: blue_noise_rank=8'd186;
                8'h64: blue_noise_rank=8'd232; 8'h65: blue_noise_rank=8'd23;  8'h66: blue_noise_rank=8'd78;  8'h67: blue_noise_rank=8'd225;
                8'h68: blue_noise_rank=8'd94;  8'h69: blue_noise_rank=8'd194; 8'h6a: blue_noise_rank=8'd42;  8'h6b: blue_noise_rank=8'd177;
                8'h6c: blue_noise_rank=8'd123; 8'h6d: blue_noise_rank=8'd33;  8'h6e: blue_noise_rank=8'd247; 8'h6f: blue_noise_rank=8'd183;
                8'h70: blue_noise_rank=8'd129; 8'h71: blue_noise_rank=8'd218; 8'h72: blue_noise_rank=8'd116; 8'h73: blue_noise_rank=8'd82;
                8'h74: blue_noise_rank=8'd137; 8'h75: blue_noise_rank=8'd159; 8'h76: blue_noise_rank=8'd50;  8'h77: blue_noise_rank=8'd185;
                8'h78: blue_noise_rank=8'd145; 8'h79: blue_noise_rank=8'd61;  8'h7a: blue_noise_rank=8'd214; 8'h7b: blue_noise_rank=8'd105;
                8'h7c: blue_noise_rank=8'd231; 8'h7d: blue_noise_rank=8'd75;  8'h7e: blue_noise_rank=8'd160; 8'h7f: blue_noise_rank=8'd97;
                8'h80: blue_noise_rank=8'd45;  8'h81: blue_noise_rank=8'd171; 8'h82: blue_noise_rank=8'd3;   8'h83: blue_noise_rank=8'd205;
                8'h84: blue_noise_rank=8'd36;  8'h85: blue_noise_rank=8'd249; 8'h86: blue_noise_rank=8'd124; 8'h87: blue_noise_rank=8'd5;
                8'h88: blue_noise_rank=8'd241; 8'h89: blue_noise_rank=8'd28;  8'h8a: blue_noise_rank=8'd130; 8'h8b: blue_noise_rank=8'd68;
                8'h8c: blue_noise_rank=8'd0;   8'h8d: blue_noise_rank=8'd208; 8'h8e: blue_noise_rank=8'd25;  8'h8f: blue_noise_rank=8'd200;
                8'h90: blue_noise_rank=8'd227; 8'h91: blue_noise_rank=8'd76;  8'h92: blue_noise_rank=8'd238; 8'h93: blue_noise_rank=8'd95;
                8'h94: blue_noise_rank=8'd180; 8'h95: blue_noise_rank=8'd60;  8'h96: blue_noise_rank=8'd212; 8'h97: blue_noise_rank=8'd106;
                8'h98: blue_noise_rank=8'd166; 8'h99: blue_noise_rank=8'd88;  8'h9a: blue_noise_rank=8'd154; 8'h9b: blue_noise_rank=8'd237;
                8'h9c: blue_noise_rank=8'd173; 8'h9d: blue_noise_rank=8'd112; 8'h9e: blue_noise_rank=8'd148; 8'h9f: blue_noise_rank=8'd64;
                8'ha0: blue_noise_rank=8'd13;  8'ha1: blue_noise_rank=8'd156; 8'ha2: blue_noise_rank=8'd133; 8'ha3: blue_noise_rank=8'd24;
                8'ha4: blue_noise_rank=8'd109; 8'ha5: blue_noise_rank=8'd153; 8'ha6: blue_noise_rank=8'd86;  8'ha7: blue_noise_rank=8'd34;
                8'ha8: blue_noise_rank=8'd199; 8'ha9: blue_noise_rank=8'd221; 8'haa: blue_noise_rank=8'd16;  8'hab: blue_noise_rank=8'd193;
                8'hac: blue_noise_rank=8'd48;  8'had: blue_noise_rank=8'd85;  8'hae: blue_noise_rank=8'd252; 8'haf: blue_noise_rank=8'd122;
                8'hb0: blue_noise_rank=8'd100; 8'hb1: blue_noise_rank=8'd189; 8'hb2: blue_noise_rank=8'd52;  8'hb3: blue_noise_rank=8'd198;
                8'hb4: blue_noise_rank=8'd245; 8'hb5: blue_noise_rank=8'd8;   8'hb6: blue_noise_rank=8'd228; 8'hb7: blue_noise_rank=8'd141;
                8'hb8: blue_noise_rank=8'd46;  8'hb9: blue_noise_rank=8'd118; 8'hba: blue_noise_rank=8'd56;  8'hbb: blue_noise_rank=8'd102;
                8'hbc: blue_noise_rank=8'd138; 8'hbd: blue_noise_rank=8'd19;  8'hbe: blue_noise_rank=8'd215; 8'hbf: blue_noise_rank=8'd175;
                8'hc0: blue_noise_rank=8'd242; 8'hc1: blue_noise_rank=8'd29;  8'hc2: blue_noise_rank=8'd222; 8'hc3: blue_noise_rank=8'd79;
                8'hc4: blue_noise_rank=8'd119; 8'hc5: blue_noise_rank=8'd170; 8'hc6: blue_noise_rank=8'd69;  8'hc7: blue_noise_rank=8'd187;
                8'hc8: blue_noise_rank=8'd255; 8'hc9: blue_noise_rank=8'd81;  8'hca: blue_noise_rank=8'd179; 8'hcb: blue_noise_rank=8'd244;
                8'hcc: blue_noise_rank=8'd206; 8'hcd: blue_noise_rank=8'd158; 8'hce: blue_noise_rank=8'd35;  8'hcf: blue_noise_rank=8'd57;
                8'hd0: blue_noise_rank=8'd83;  8'hd1: blue_noise_rank=8'd114; 8'hd2: blue_noise_rank=8'd163; 8'hd3: blue_noise_rank=8'd144;
                8'hd4: blue_noise_rank=8'd43;  8'hd5: blue_noise_rank=8'd210; 8'hd6: blue_noise_rank=8'd27;  8'hd7: blue_noise_rank=8'd126;
                8'hd8: blue_noise_rank=8'd14;  8'hd9: blue_noise_rank=8'd162; 8'hda: blue_noise_rank=8'd132; 8'hdb: blue_noise_rank=8'd7;
                8'hdc: blue_noise_rank=8'd92;  8'hdd: blue_noise_rank=8'd71;  8'hde: blue_noise_rank=8'd197; 8'hdf: blue_noise_rank=8'd134;
                8'he0: blue_noise_rank=8'd2;   8'he1: blue_noise_rank=8'd203; 8'he2: blue_noise_rank=8'd65;  8'he3: blue_noise_rank=8'd21;
                8'he4: blue_noise_rank=8'd235; 8'he5: blue_noise_rank=8'd91;  8'he6: blue_noise_rank=8'd152; 8'he7: blue_noise_rank=8'd107;
                8'he8: blue_noise_rank=8'd213; 8'he9: blue_noise_rank=8'd59;  8'hea: blue_noise_rank=8'd233; 8'heb: blue_noise_rank=8'd40;
                8'hec: blue_noise_rank=8'd223; 8'hed: blue_noise_rank=8'd120; 8'hee: blue_noise_rank=8'd168; 8'hef: blue_noise_rank=8'd234;
                8'hf0: blue_noise_rank=8'd146; 8'hf1: blue_noise_rank=8'd181; 8'hf2: blue_noise_rank=8'd251; 8'hf3: blue_noise_rank=8'd104;
                8'hf4: blue_noise_rank=8'd172; 8'hf5: blue_noise_rank=8'd53;  8'hf6: blue_noise_rank=8'd195; 8'hf7: blue_noise_rank=8'd240;
                8'hf8: blue_noise_rank=8'd37;  8'hf9: blue_noise_rank=8'd93;  8'hfa: blue_noise_rank=8'd191; 8'hfb: blue_noise_rank=8'd111;
                8'hfc: blue_noise_rank=8'd155; 8'hfd: blue_noise_rank=8'd54;  8'hfe: blue_noise_rank=8'd31;  8'hff: blue_noise_rank=8'd98;
            endcase
        end
    endfunction

    // A compact 4x4 rank reduction is retained for the quantizer regression,
    // but the production path below uses the complete 16x16 blue-noise tile.
    // The larger tile avoids the visible 4x4 checker/stripe blocks when a
    // moving desktop contains large flat areas.
    function [3:0] blue_noise_rank16;
        input [3:0] address;
        begin
            case (address)
                4'h0: blue_noise_rank16 = 4'd4;
                4'h1: blue_noise_rank16 = 4'd11;
                4'h2: blue_noise_rank16 = 4'd8;
                4'h3: blue_noise_rank16 = 4'd1;
                4'h4: blue_noise_rank16 = 4'd9;
                4'h5: blue_noise_rank16 = 4'd5;
                4'h6: blue_noise_rank16 = 4'd6;
                4'h7: blue_noise_rank16 = 4'd12;
                4'h8: blue_noise_rank16 = 4'd3;
                4'h9: blue_noise_rank16 = 4'd2;
                4'ha: blue_noise_rank16 = 4'd13;
                4'hb: blue_noise_rank16 = 4'd0;
                4'hc: blue_noise_rank16 = 4'd14;
                4'hd: blue_noise_rank16 = 4'd7;
                4'he: blue_noise_rank16 = 4'd15;
                4'hf: blue_noise_rank16 = 4'd10;
            endcase
        end
    endfunction

    // Preserve the solid endpoint bands from display_tone_map, then divide
    // the usable middle range into fourteen explicit bins.  Together with
    // solid black and solid white this is exactly sixteen output states.
    function [3:0] quantize_gray16;
        input [7:0] level;
        begin
            if (level == 8'h00)      quantize_gray16 = 4'd0;
            else if (level <= 8'd46) quantize_gray16 = 4'd1;
            else if (level <= 8'd59) quantize_gray16 = 4'd2;
            else if (level <= 8'd73) quantize_gray16 = 4'd3;
            else if (level <= 8'd87) quantize_gray16 = 4'd4;
            else if (level <= 8'd101) quantize_gray16 = 4'd5;
            else if (level <= 8'd114) quantize_gray16 = 4'd6;
            else if (level <= 8'd128) quantize_gray16 = 4'd7;
            else if (level <= 8'd142) quantize_gray16 = 4'd8;
            else if (level <= 8'd155) quantize_gray16 = 4'd9;
            else if (level <= 8'd169) quantize_gray16 = 4'd10;
            else if (level <= 8'd183) quantize_gray16 = 4'd11;
            else if (level <= 8'd197) quantize_gray16 = 4'd12;
            else if (level <= 8'd210) quantize_gray16 = 4'd13;
            else if (level != 8'hff) quantize_gray16 = 4'd14;
            else                    quantize_gray16 = 4'd15;
        end
    endfunction

    // ADV7611 emits studio-range luma for the HDMI modes used here. Expand
    // 16..235 to 0..255 before dithering. The source image is normally sRGB,
    // while the white-pixel density of a binary dither is linear-light. Using
    // the raw sRGB code directly makes midtones too bright and produces a
    // screen-wide gray veil. The previous x^2 approximation over-corrected
    // the other way and made the physical image nearly black. This low-cost
    // shift/add lift restores midtones without adding a multiplier to pix_clk.
    function [7:0] studio_range_expand;
        input [7:0] level;
        reg [15:0] scaled;
        begin
            if (level <= 8'd16)
                studio_range_expand = 8'd0;
            else if (level >= 8'd235)
                studio_range_expand = 8'd255;
            else begin
                // floor((level - 16) * 149 / 128), an accurate 255/219
                // fixed-point approximation without a divider.
                scaled = (level - 8'd16) * 8'd149;
                studio_range_expand = scaled[14:7];
            end
        end
    endfunction

    function [7:0] gamma_aware_level;
        input [7:0] expanded;
        reg [8:0] lifted;
        begin
            if (expanded == 8'h00)
                gamma_aware_level = 8'h00;
            else if (expanded == 8'hff)
                gamma_aware_level = 8'hff;
            else begin
                // Give the darker half a slightly stronger lift and the
                // lighter half a gentler lift. Both branches are shift/add
                // only.
                if (expanded < 8'd128)
                    lifted = {1'b0, expanded} + ({1'b0, expanded} >> 3);
                else
                    lifted = {1'b0, expanded} + ({1'b0, expanded} >> 4);
                gamma_aware_level = lifted[8] ? 8'hff : lifted[7:0];
            end
        end
    endfunction

    // The smooth path uses the full input range more aggressively.  This
    // keeps near-black desktop pixels black and near-white pixels white,
    // while leaving the text path on the unmodified native 16-level source.
    function [7:0] smooth_contrast_expand;
        input [7:0] level;
        reg [15:0] scaled;
        begin
            if (level <= 8'd24)
                smooth_contrast_expand = 8'h00;
            else if (level >= 8'd232)
                smooth_contrast_expand = 8'hff;
            else begin
                // 255 / (232 - 24) ~= 78 / 64.
                scaled = (level - 8'd24) * 8'd78;
                smooth_contrast_expand = scaled[13:6];
            end
        end
    endfunction

    wire [12:0] cropped_x = active_pixel_count - CROP_LEFT;
    wire [7:0] native_level = text_mode_s1 ? dither_level_s1 : dither_level_s2;
    // Position-independent rounding to sixteen target gray states.
    wire [8:0] native_rounded = {1'b0,native_level}+9'd8;
    wire [3:0] native_base = native_rounded / 9'd17;
    // Lift midtones one step without turning black text gray or clipping white.
    wire [3:0] native_gray = NATIVE_LIGHTEN && native_base != 0 && native_base != 15 ?
                             native_base + 1'b1 : native_base;
    wire [7:0] smooth_level = smooth_contrast_expand(dither_level_s2);
    wire [3:0] gray_level16 = quantize_gray16(smooth_level);
    wire [7:0] dither_rank256 = blue_noise_rank(dither_address_s2);
    wire dither_white = (smooth_level == 8'hff) ||
                        ((gray_level16 != 4'h0) &&
                         smooth_level > dither_rank256);
    wire [7:0] native_base_data = {native_gray,native_gray};
    wire [7:0] dither_base_data = dither_white ? 8'hff : 8'h00;
    wire [7:0] processed_base_data =
        text_mode_s1 ? native_base_data :
        (NATIVE_GC16 && native_refine_s1) ? native_base_data :
        (DITHER_ENABLE ? dither_base_data : gray_i);
    wire [7:0] mode_overlay_data;
    mode_overlay_es120mc1 #(.H_ACTIVE(FRAME_H), .V_ACTIVE(FRAME_V), .SCALE(8))
        mode_overlay (
            .x(dither_x_s2), .y(dither_y_s2),
            .base_gray(processed_base_data), .mode_notice(mode_notice_s1),
            .gray_out(mode_overlay_data)
        );

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            active_pixel_count <= 0;
            raw_de <= 0;
            active_line_mod16 <= 0;
            gray_de <= 0;
            gray_hs <= 0;
            gray_vs <= 0;
            gray_data <= 0;
            gray_source <= 0;
            active_line_count <= 0;
            frame_hash <= 0;
            last_frame_hash <= 0;
            frame_active_seen <= 0;
            frame_hash_initialized <= 0;
            frame_changed <= 1'b1;
            vs_i_d <= 1'b1;
            dither_level_s0 <= 0;
            dither_level_s1 <= 0;
            dither_level_s2 <= 0;
            dither_address_s0 <= 0;
            dither_address_s1 <= 0;
            dither_address_s2 <= 0;
            dither_x_s0 <= 0;
            dither_x_s1 <= 0;
            dither_x_s2 <= 0;
            dither_y_s0 <= 0;
            dither_y_s1 <= 0;
            dither_y_s2 <= 0;
            native_refine_s0 <= 1'b0;
            native_refine_s1 <= 1'b0;
            mode_notice_s0 <= 2'b0;
            mode_notice_s1 <= 2'b0;
            text_mode_s0 <= 1'b0;
            text_mode_s1 <= 1'b0;
            dither_de_s0 <= 0;
            dither_de_s1 <= 0;
            dither_de_s2 <= 0;
            dither_hs_s0 <= 0;
            dither_hs_s1 <= 0;
            dither_hs_s2 <= 0;
            dither_vs_s0 <= 0;
            dither_vs_s1 <= 0;
            dither_vs_s2 <= 0;
        end else begin
            raw_de <= de_i;
            dither_level_s0 <= gray_i;
            dither_level_s1 <= VIDEO_LEVELS_ENABLE ?
                               studio_range_expand(dither_level_s0) :
                               dither_level_s0;
            dither_level_s2 <= (VIDEO_LEVELS_ENABLE &&
                                !(NATIVE_GC16 && native_refine_s1) &&
                                GAMMA_AWARE_DITHER) ?
                               gamma_aware_level(dither_level_s1) :
                               dither_level_s1;
            dither_address_s0 <= {active_line_mod16, cropped_x[3:0]};
            dither_address_s1 <= dither_address_s0;
            dither_address_s2 <= dither_address_s1;
            dither_x_s0 <= cropped_x[11:0];
            dither_x_s1 <= dither_x_s0;
            dither_x_s2 <= dither_x_s1;
            dither_y_s0 <= active_line_count;
            dither_y_s1 <= dither_y_s0;
            dither_y_s2 <= dither_y_s1;
            native_refine_s0 <= native_refine;
            native_refine_s1 <= native_refine_s0;
            mode_notice_s0 <= mode_notice;
            mode_notice_s1 <= mode_notice_s0;
            text_mode_s0 <= text_mode;
            text_mode_s1 <= text_mode_s0;
            dither_de_s0 <= de_i && active_pixel_count >= CROP_LEFT &&
                                   active_pixel_count < CROP_END;
            dither_de_s1 <= dither_de_s0;
            dither_de_s2 <= dither_de_s1;
            dither_hs_s0 <= ~hs_i;
            dither_hs_s1 <= dither_hs_s0;
            dither_hs_s2 <= dither_hs_s1;
            dither_vs_s0 <= ~vs_i;
            dither_vs_s1 <= dither_vs_s0;
            dither_vs_s2 <= dither_vs_s1;
            if (NATIVE_GC16 && native_refine_s1) begin
                gray_data <= mode_overlay_data;
                gray_source <= native_gray;
                gray_de <= dither_de_s2;
                gray_hs <= dither_hs_s2;
                gray_vs <= dither_vs_s2;
            end else if (DITHER_ENABLE) begin
                gray_data <= mode_overlay_data;
                gray_source <= native_gray;
                gray_de <= dither_de_s2;
                gray_hs <= dither_hs_s2;
                gray_vs <= dither_vs_s2;
            end else begin
                gray_data <= gray_i;
                gray_source <= gray_i[7:4];
                gray_de <= de_i && active_pixel_count >= CROP_LEFT &&
                                      active_pixel_count < CROP_END;
                gray_hs <= ~hs_i;
                gray_vs <= ~vs_i;
            end
            if (!vs_i) active_line_mod16 <= 0;
            else if (!de_i && raw_de) active_line_mod16 <= active_line_mod16 + 1'b1;
            if (!de_i) active_pixel_count <= 0;
            else if (active_pixel_count < INPUT_H)
                active_pixel_count <= active_pixel_count + 1'b1;

            // Hash a sparse, position-dependent sample of the cropped frame.
            // This is only a source-change detector; the actual framebuffer
            // and old/new waveform data remain in DDR.
            if (vs_i != vs_i_d) begin
                if (frame_active_seen) begin
                    if (!frame_hash_initialized)
                        frame_changed <= 1'b1;
                    else
                        frame_changed <= (frame_hash != last_frame_hash);
                    last_frame_hash <= frame_hash;
                    frame_hash_initialized <= 1'b1;
                end
                frame_hash <= 0;
                frame_active_seen <= 1'b0;
                active_line_count <= 0;
            end else begin
                if (de_i) begin
                    frame_active_seen <= 1'b1;
                    if (active_pixel_count >= CROP_LEFT &&
                        active_pixel_count < CROP_END &&
                        active_pixel_count[3:0] == 4'd0) begin
                        frame_hash <= {frame_hash[26:0], frame_hash[31:27]} ^
                                      {24'd0, gray_i} ^
                                      {19'd0, active_pixel_count} ^
                                      {20'd0, active_line_count};
                    end
                end else if (raw_de) begin
                    active_line_count <= active_line_count + 1'b1;
                end
            end
            vs_i_d <= vs_i;
        end
    end

    // A wrong-width source must not become valid just because cropping
    // produces a plausible line. Count every original DE pixel and row.
    hdmi_timing_qualifier #(.FRAME_H(INPUT_H), .FRAME_V(FRAME_V)) timing (
        .pix_clk(pix_clk), .rst_n(rst_n), .gray_de(raw_de),
        .gray_vs(gray_vs), .video_valid(video_valid)
    );
endmodule
