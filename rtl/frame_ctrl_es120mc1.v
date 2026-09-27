// ES120MC1 / VD1400-MOA Mode 3 timing.
//
// The coordinates below are the values in the panel datasheet, not the
// shorter LCD/RMT timing used by the ESP32 reference board. XCL is 44.068 MHz,
// giving a 75.0057 Hz complete scan. Three identical DU phases therefore
// complete one moving-image update at 25.0019 Hz. Control outputs move on XCL's falling
// edge, leaving half an SDCK cycle of setup time before the panel's rising
// edge.
module frame_ctrl_es120mc1 #(
    parameter EPD_V = 1600,
    parameter LSL = 14,
    parameter LBL = 10,
    parameter LDL = 320,
    parameter LEL = 18,
    parameter GDCK_STA = 4,
    parameter LGONL = 264,
    parameter FSL = 1,
    parameter FBL = 4,
    parameter FDL = EPD_V,
    parameter FEL = 18
    )(
    input  wire rst_n,
    input  wire epd_clk,
    input  wire s_flag,
    output reg  SKV,
    output reg  SPV,
    output wire XCL,
    output reg  XLE,
    output reg  XSTL,
    output reg  r_flag,
    output reg  end_flag
    );

    localparam LINE_TOTAL = LSL + LBL + LDL + LEL;
    localparam DATA_START = LSL + LBL;
    localparam DATA_END = DATA_START + LDL;
    localparam CKV_START = LSL + GDCK_STA;
    localparam CKV_END = CKV_START + LGONL;
    localparam V_ACTIVE_START = FSL + FBL;
    localparam V_ACTIVE_END = V_ACTIVE_START + FDL;
    // Figure 6-2: SPH transfers a row BEFORE that row's LEH latch pulse.
    localparam V_DATA_START = V_ACTIVE_START - 1;
    localparam V_DATA_END = V_ACTIVE_END - 1;
    localparam FRAME_TOTAL = FSL + FBL + FDL + FEL;
    // Keep source rows zero and one queued during the final two FBL lines.
    // This gives the DDR reader two whole line periods before FDL begins.
    localparam PREFETCH_START = V_DATA_START - 2;
    localparam PREFETCH_END = V_DATA_END - 2;

    reg [9:0] line_count;
    reg [11:0] frame_count;
    reg active;

    assign XCL = epd_clk;

    always @(negedge epd_clk or negedge rst_n) begin
        if (!rst_n) begin
            line_count <= 10'd0;
            frame_count <= 12'd0;
            active <= 1'b0;
            SKV <= 1'b0;
            SPV <= 1'b1;
            XLE <= 1'b0;
            XSTL <= 1'b1;
            r_flag <= 1'b0;
            end_flag <= 1'b0;
        end
        else begin
            r_flag <= 1'b0;
            end_flag <= 1'b0;

            if (!active) begin
                SKV <= 1'b0;
                SPV <= 1'b1;
                XLE <= 1'b0;
                XSTL <= 1'b1;
                line_count <= 10'd0;
                frame_count <= 12'd0;
                if (s_flag) begin
                    active <= 1'b1;
                end
            end
            else begin
                // Mode 3 source timing: LEH is high for LSL, then SPH/XSTL
                // is active low only through the LDL data clocks.
                XSTL <= !((frame_count >= V_DATA_START) &&
                            (frame_count < V_DATA_END) &&
                           (line_count >= DATA_START) &&
                           (line_count < DATA_END));
                XLE <= (frame_count >= V_ACTIVE_START) &&
                       (frame_count < V_ACTIVE_END) &&
                       (line_count < LSL);

                // CKV begins GDCK_STA clocks after LSL and remains high for
                // LGONL clocks in every FSL/FBL/FDL/FEL line.
                SKV <= (line_count >= CKV_START) && (line_count < CKV_END);
                // Figure on page 12: SPV brackets CKV falling then rising.
                // CKV rise in line 1 is pulse 1; rise in line 5 selects Gout1.
                SPV <= !(((frame_count == 0) && (line_count >= CKV_END - 4)) ||
                         ((frame_count > 0) && (frame_count < FSL)) ||
                         ((frame_count == FSL) && (line_count < CKV_END - 4)));

                // Issue exactly FDL row requests.  The first two happen in
                // FBL, then each following request remains two line periods
                // ahead of the corresponding FDL data window.
                if ((frame_count >= PREFETCH_START) &&
                    (frame_count < PREFETCH_END) &&
                    (line_count == DATA_START - 1)) begin
                    r_flag <= 1'b1;
                end

                if (line_count == LINE_TOTAL - 1) begin
                    line_count <= 10'd0;
                    if (frame_count == FRAME_TOTAL - 1) begin
                        frame_count <= 12'd0;
                        active <= 1'b0;
                        end_flag <= 1'b1;
                    end
                    else begin
                        frame_count <= frame_count + 1'b1;
                    end
                end
                else begin
                    line_count <= line_count + 1'b1;
                end
            end
        end
    end

endmodule
