// Qualifies the ADV7611 parallel output before it is connected to the fixed
// 2560x1600 frame store.  DE is the authoritative active-video indication.
module hdmi_timing_qualifier #(
    parameter FRAME_H = 2560,
    parameter FRAME_V = 1600
    )(
    input wire pix_clk,
    input wire rst_n,
    input wire gray_de,
    input wire gray_vs,
    output reg video_valid
    );

    reg de_d;
    reg vs_d;
    reg [12:0] pixel_count;
    reg [11:0] line_count;
    reg bad_line;

    wire de_rise = gray_de & ~de_d;
    wire de_fall = ~gray_de & de_d;
    wire vs_rise = gray_vs & ~vs_d;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d        <= 1'b0;
            vs_d        <= 1'b0;
            pixel_count <= 13'd0;
            line_count  <= 12'd0;
            bad_line    <= 1'b0;
            video_valid <= 1'b0;
        end
        else begin
            de_d <= gray_de;
            vs_d <= gray_vs;

            if (de_rise) begin
                pixel_count <= 13'd1;
            end
            else if (gray_de) begin
                pixel_count <= pixel_count + 1'b1;
            end

            if (de_fall) begin
                if (pixel_count == FRAME_H)
                    line_count <= line_count + 1'b1;
                else
                    bad_line <= 1'b1;
            end

            if (vs_rise) begin
                video_valid <= (line_count == FRAME_V) && !bad_line;
                pixel_count <= 13'd0;
                line_count  <= 12'd0;
                bad_line    <= 1'b0;
            end
        end
    end
endmodule
