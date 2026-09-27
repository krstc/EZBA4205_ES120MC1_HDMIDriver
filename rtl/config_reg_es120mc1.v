module config_reg_es120mc1 #(
    // Value in mV. The TPS65185 register uses 10 mV increments.
    parameter VCOM = 1810
    )(
    input wire [8:0] REG_INDEX,
    output reg [39:0] REG_DATA,
    output wire [8:0] REG_SIZE
    );

    localparam vcom = VCOM / 10;
    // Write a complete, valid block. ADV7611 recomputes the checksum when
    // enabling internal EDID (UG-180); the computed byte must match ours.
    assign REG_SIZE = 9'd182;

    function [7:0] edid_byte;
        input [7:0] index;
        begin
            case (index)
                // Native panel mode: 2560x1600, totals 2720x1646, 111.93 MHz.
                // Capture all 2560 columns without cropping.
                7'd1, 7'd2, 7'd3, 7'd4, 7'd5, 7'd6: edid_byte = 8'hff;
                7'd8: edid_byte = 8'h16;
                7'd9: edid_byte = 8'h04;
                // Change the product code so Windows creates a fresh monitor
                // instance instead of retaining the old mode selection.
                7'd10: edid_byte = 8'h33;
                7'd11: edid_byte = 8'h01;
                7'd16: edid_byte = 8'h01;
                7'd17: edid_byte = 8'h24;
                7'd18: edid_byte = 8'h01;
                7'd19: edid_byte = 8'h04;
                7'd20: edid_byte = 8'ha2;
                7'd21: edid_byte = 8'h1a;
                7'd22: edid_byte = 8'h10;
                7'd23: edid_byte = 8'h78;
                7'd24: edid_byte = 8'h0a;
                7'd25: edid_byte = 8'hf3;
                7'd26: edid_byte = 8'h30;
                7'd27: edid_byte = 8'ha7;
                7'd28: edid_byte = 8'h54;
                7'd29: edid_byte = 8'h42;
                7'd30: edid_byte = 8'haa;
                7'd31: edid_byte = 8'h26;
                7'd32: edid_byte = 8'h0f;
                7'd33: edid_byte = 8'h50;
                7'd34: edid_byte = 8'h54;
                // 35..37 are established timings: all zero, NOT unused 01/01.
                7'd38, 7'd39, 7'd40, 7'd41, 7'd42, 7'd43,
                7'd44, 7'd45, 7'd46, 7'd47, 7'd48, 7'd49, 7'd50, 7'd51,
                7'd52, 7'd53: edid_byte = 8'h01;
                // 111.93 MHz / (2720 * 1646) = 25.000447 Hz.
                7'd54: edid_byte = 8'hb9;
                7'd55: edid_byte = 8'h2b;
                7'd56: edid_byte = 8'h00;
                7'd57: edid_byte = 8'ha0;
                7'd58: edid_byte = 8'ha0;
                7'd59: edid_byte = 8'h40;
                7'd60: edid_byte = 8'h2e;
                7'd61: edid_byte = 8'h60;
                7'd62: edid_byte = 8'h30;
                // Front porch 48 + sync 32 + back porch 80 = 160.
                7'd63: edid_byte = 8'h20;
                // Standard DTD packing: byte 64 contains the vertical porch
                // and sync low bits; byte 65 contains the four upper-bit
                // fields. Bytes 66..68 are the physical image size.
                7'd64: edid_byte = 8'h36;
                7'd65: edid_byte = 8'h00;
                7'd66: edid_byte = 8'h03;
                7'd67: edid_byte = 8'ha2;
                7'd68: edid_byte = 8'h10;
                7'd69: edid_byte = 8'h00;
                7'd70: edid_byte = 8'h00;
                7'd71: edid_byte = 8'h1e;
                7'd75: edid_byte = 8'hfc;
                7'd77: edid_byte = "E";
                7'd78: edid_byte = "S";
                7'd79: edid_byte = "1";
                7'd80: edid_byte = "2";
                7'd81: edid_byte = "0";
                7'd82: edid_byte = "M";
                7'd83: edid_byte = "C";
                7'd84: edid_byte = "1";
                7'd85: edid_byte = "-";
                7'd86: edid_byte = "2";
                7'd87: edid_byte = "5";
                7'd88: edid_byte = "H";
                7'd89: edid_byte = "z";
                7'd93: edid_byte = 8'hfd;
                7'd95: edid_byte = 8'h18;
                7'd96: edid_byte = 8'h1a;
                7'd97: edid_byte = 8'h28;
                7'd98: edid_byte = 8'h2a;
                7'd99: edid_byte = 8'h0c;
                // Range limits only; do not invite GTF/CVT-generated modes.
                7'd100: edid_byte = 8'h01;
                7'd101: edid_byte = 8'h0a;
                7'd102, 7'd103, 7'd104, 7'd105, 7'd106, 7'd107: edid_byte = 8'h20;
                7'd111: edid_byte = 8'h10;
                // Base block checksum for the native timing and product 0133.
                7'd127: edid_byte = 8'h5c;
                default: edid_byte = 8'h00;
            endcase
        end
    endfunction

    always @(*) begin
        case (REG_INDEX)
            0: REG_DATA = {8'd3, 8'h98, 8'hf4, 8'h80, 8'h00};
            1: REG_DATA = {8'd3, 8'h98, 8'hf5, 8'h7c, 8'h00};
            2: REG_DATA = {8'd3, 8'h98, 8'hf8, 8'h4c, 8'h00};
            3: REG_DATA = {8'd3, 8'h98, 8'hf9, 8'h64, 8'h00};
            4: REG_DATA = {8'd3, 8'h98, 8'hfa, 8'h6c, 8'h00};
            5: REG_DATA = {8'd3, 8'h98, 8'hfb, 8'h68, 8'h00};
            6: REG_DATA = {8'd3, 8'h98, 8'hfd, 8'h44, 8'h00};
            7: REG_DATA = {8'd3, 8'h98, 8'h01, 8'h05, 8'h00};
            8: REG_DATA = {8'd3, 8'h98, 8'h00, 8'h1e, 8'h00};
            9: REG_DATA = {8'd3, 8'h98, 8'h02, 8'hf0, 8'h00};
            10: REG_DATA = {8'd3, 8'h98, 8'h03, 8'h80, 8'h00};
            11: REG_DATA = {8'd3, 8'h98, 8'h04, 8'h42, 8'h00};
            12: REG_DATA = {8'd3, 8'h98, 8'h05, 8'h28, 8'h00};
            13: REG_DATA = {8'd3, 8'h98, 8'h06, 8'ha7, 8'h00};
            14: REG_DATA = {8'd3, 8'h98, 8'h0b, 8'h44, 8'h00};
            15: REG_DATA = {8'd3, 8'h98, 8'h0c, 8'h42, 8'h00};
            16: REG_DATA = {8'd3, 8'h98, 8'h15, 8'h80, 8'h00};
            17: REG_DATA = {8'd3, 8'h98, 8'h19, 8'h8a, 8'h00};
            18: REG_DATA = {8'd3, 8'h98, 8'h33, 8'h40, 8'h00};
            19: REG_DATA = {8'd3, 8'h98, 8'h14, 8'h3f, 8'h00};
            20: REG_DATA = {8'd3, 8'h44, 8'hba, 8'h01, 8'h00};
            21: REG_DATA = {8'd3, 8'h44, 8'h7c, 8'h01, 8'h00};
            22: REG_DATA = {8'd3, 8'h64, 8'h40, 8'h81, 8'h00};
            23: REG_DATA = {8'd3, 8'h68, 8'h9b, 8'h03, 8'h00};
            24: REG_DATA = {8'd3, 8'h68, 8'hc1, 8'h01, 8'h00};
            25: REG_DATA = {8'd3, 8'h68, 8'hc2, 8'h01, 8'h00};
            26: REG_DATA = {8'd3, 8'h68, 8'hc3, 8'h01, 8'h00};
            27: REG_DATA = {8'd3, 8'h68, 8'hc4, 8'h01, 8'h00};
            28: REG_DATA = {8'd3, 8'h68, 8'hc5, 8'h01, 8'h00};
            29: REG_DATA = {8'd3, 8'h68, 8'hc6, 8'h01, 8'h00};
            30: REG_DATA = {8'd3, 8'h68, 8'hc7, 8'h01, 8'h00};
            31: REG_DATA = {8'd3, 8'h68, 8'hc8, 8'h01, 8'h00};
            32: REG_DATA = {8'd3, 8'h68, 8'hc9, 8'h01, 8'h00};
            33: REG_DATA = {8'd3, 8'h68, 8'hca, 8'h01, 8'h00};
            34: REG_DATA = {8'd3, 8'h68, 8'hcb, 8'h01, 8'h00};
            35: REG_DATA = {8'd3, 8'h68, 8'hcc, 8'h01, 8'h00};
            36: REG_DATA = {8'd3, 8'h68, 8'h00, 8'h00, 8'h00};
            37: REG_DATA = {8'd3, 8'h68, 8'h83, 8'hfe, 8'h00};
            38: REG_DATA = {8'd3, 8'h68, 8'h6f, 8'h08, 8'h00};
            39: REG_DATA = {8'd3, 8'h68, 8'h85, 8'h1f, 8'h00};
            40: REG_DATA = {8'd3, 8'h68, 8'h87, 8'h70, 8'h00};
            41: REG_DATA = {8'd3, 8'h68, 8'h8d, 8'h04, 8'h00};
            42: REG_DATA = {8'd3, 8'h68, 8'h8e, 8'h1e, 8'h00};
            43: REG_DATA = {8'd3, 8'h68, 8'h1a, 8'h8a, 8'h00};
            44: REG_DATA = {8'd3, 8'h68, 8'h57, 8'hda, 8'h00};
            45: REG_DATA = {8'd3, 8'h68, 8'h58, 8'h01, 8'h00};
            46: REG_DATA = {8'd3, 8'h68, 8'h75, 8'h10, 8'h00};
            47: REG_DATA = {8'd3, 8'h68, 8'h6c, 8'ha3, 8'h00};
            48: REG_DATA = {8'd3, 8'h98, 8'h20, 8'h70, 8'h00};
            49: REG_DATA = {8'd3, 8'h64, 8'h74, 8'h00, 8'h00};
            178: REG_DATA = {8'd3, 8'h64, 8'h74, 8'h01, 8'h00};
            179: REG_DATA = {8'd3, 8'h98, 8'h20, 8'hf0, 8'h00};
            // Match the known-good ADV7611 sequence used by the original
            // project: release HPD under manual control, then return HPA to
            // its normal automatic mode after the source has observed it.
            180: REG_DATA = {8'd3, 8'h68, 8'h6c, 8'ha2, 8'h00};
            181: REG_DATA = {8'd4, 8'hd0, 8'h03, vcom[7:0], vcom[15:8]};
            default: begin
                if ((REG_INDEX >= 9'd50) && (REG_INDEX <= 9'd177)) begin
                    // Keep this concatenation at exactly 40 bits.  A 9-bit
                    // REG_INDEX expression here expands the transaction to
                    // six bytes and corrupts the ADV7611 EDID RAM writes.
                    REG_DATA = {8'd3, 8'h6c, REG_INDEX[7:0] - 8'd50,
                                edid_byte(REG_INDEX[7:0] - 8'd50), 8'h00};
                end
                else begin
                    REG_DATA = 40'd0;
                end
            end
        endcase
    end
endmodule
