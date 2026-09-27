
//////////////////////////////////////////////////////////////////////////////////
//
//  这个模块用于控制屏幕刷新
//
//////////////////////////////////////////////////////////////////////////////////

module display_mgr_es120mc1#
    (
    parameter SYS_CLK_FREQ = 50,    // 系统时钟Mhz
    parameter FDMA_WID     = 64,    // FDMA数据宽度
    // 屏幕信息
    parameter EPD_WID      = 8,     // EPD数据宽度
    parameter EPD_FREQ     = 25,    // EPD像素时钟频率Mhz
    parameter EPD_H        = 1200,  // 屏幕宽度
    parameter EPD_V        = 825,   // 屏幕长度
    parameter PERIOD_CNT   = 10,    // 首帧/本地图像刷新次数
    parameter FAST_PERIOD_CNT = 5,  // complete EPDiy DU waveform
    parameter LOCAL_RECOVERY = 0,
    parameter NATIVE_GC16 = 0,
    parameter HYBRID_REFRESH = 0,
    parameter STREAMING_REFRESH = 0,
    // 时序信息
    parameter tFdly        = 0,     // 帧间隔ms 较小值可能会导致更大的漏电流...
    parameter tLEdly       = 40,    // 单位ns
    parameter tLEw         = 40,
    parameter tLEoff       = 200
    )
    (
    input wire                      clk,
    input wire                      epd_clk,
    input wire                      rst_n,
    input wire                      epd_rst_n,

    input wire                      s_flag,  // 触发刷新
    input wire                      init_mode,
    input wire                      white_only,
    input wire                      fast_update,
    input wire                      local_recovery,
    output reg  [7:0]               period_cnt,  // 周期计数器
    output reg                      d_busy,  // 正在刷新屏幕
    output reg                      d_fflag,   // 屏幕刷新完成
    output wire                     image_fflag,
    // 数据
    output wire                     r_flag,     // 读取一行信号
    output wire                     fifo_ren,   // 使能FIFO输出数据
    input wire  [FDMA_WID - 1:0]    din,
    // 屏幕驱动信号
    output wire                     EPD_SKV,
    output wire                     EPD_SPV,
    output wire                     EPD_XCL,
    output wire                     EPD_XLE,
    output wire                     EPD_XSTL,
    output wire [EPD_WID -1:0]      EPD_DOUT
    );

    wire s_flag_t;

    sync_h2lck sync_s_flag
        (
            .in_clk    (clk),
            .out_clk   (epd_clk),
            .rst_n     (rst_n),
            .level_in  (s_flag),
            .pulse_out (s_flag_t)
        );

    reg [31:0] DELAY_CNT;

    initial begin
        DELAY_CNT = (EPD_FREQ * 32'd500) * tFdly;  // N0毫秒计数器
    end

    wire fend_flag;  // 帧刷新完成
    reg sf_flag;  // 触发帧信号
    reg [1:0] MGR_STATE;
    reg [31:0] delay_cnt;
    reg initializing;
    reg whitening;
    reg fast_scanning;
    reg recovering;
    wire local_recovery_sync;
    wire init_mode_sync;
    wire white_only_sync;
    wire fast_update_sync;
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0), .INIT_SYNC_FF(1)) init_cdc (
        .src_clk(clk), .src_in(init_mode), .dest_clk(epd_clk), .dest_out(init_mode_sync)
    );
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0), .INIT_SYNC_FF(1)) white_cdc (
        .src_clk(clk), .src_in(white_only), .dest_clk(epd_clk), .dest_out(white_only_sync)
    );
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0), .INIT_SYNC_FF(1)) fast_cdc (
        .src_clk(clk), .src_in(fast_update), .dest_clk(epd_clk), .dest_out(fast_update_sync)
    );
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0), .INIT_SYNC_FF(1)) recovery_cdc (
        .src_clk(clk), .src_in(LOCAL_RECOVERY ? local_recovery : 1'b0),
        .dest_clk(epd_clk), .dest_out(local_recovery_sync)
    );
    assign image_fflag = d_fflag && !initializing;
    wire row_request;
    wire [7:0] scan_count = initializing ? (whitening ? 8'd12 : 8'd32) :
                            STREAMING_REFRESH ? 8'd3 :
                            (HYBRID_REFRESH && fast_scanning) ? 8'd7 :
                            NATIVE_GC16 ? (recovering ? 8'd44 : 8'd32) :
                            recovering ? 8'd12 :
                            (fast_scanning ? FAST_PERIOD_CNT : PERIOD_CNT);

    localparam MGR_IDEL   = 2'd0;
    localparam MGR_STATE1 = 2'd1;
    localparam MGR_STATE2 = 2'd2;
    localparam MGR_STATE3 = 2'd3;

    always @(posedge epd_clk or negedge epd_rst_n) begin
        if (!epd_rst_n) begin
            // reset
            MGR_STATE <= 0;
            period_cnt <= 0;
            delay_cnt <= 0;
            sf_flag <= 0;
            d_busy <= 0;
            d_fflag <= 0;
            initializing <= 0;
            whitening <= 0;
            fast_scanning <= 0;
            recovering <= 0;
        end
        else begin

            case(MGR_STATE)

                MGR_IDEL:begin  // 等待开始信号
                    d_fflag <= 0;
                    if (s_flag_t) begin
                        d_busy <= 1;
                        initializing <= init_mode_sync;
                        whitening <= white_only_sync;
                        fast_scanning <= fast_update_sync;
                        recovering <= local_recovery_sync;
                        MGR_STATE <= MGR_STATE1;
                    end
                    else begin
                        d_busy <= 0;
                    end
                end

                MGR_STATE1:begin
                    if (period_cnt < scan_count) begin
                        period_cnt <= period_cnt + 1;  // 一次有效刷新需要输出几帧
                        MGR_STATE <= MGR_STATE2;
                        sf_flag <= 1;  // 触发刷新
                    end
                    else begin
                        period_cnt <= 0;
                        d_fflag <= 1;
                        MGR_STATE <= MGR_IDEL;
                    end
                end

                MGR_STATE2:begin
                    if (fend_flag) begin  // 刷新完成
                        MGR_STATE <= MGR_STATE3;
                    end
                    else begin
                        sf_flag <= 0;
                    end
                end

                MGR_STATE3:begin
                    if (delay_cnt < DELAY_CNT) begin  // 刷新完延迟一段时间
                        delay_cnt <= delay_cnt + 1;
                    end
                    else begin
                        delay_cnt <= 0;
                        MGR_STATE <= MGR_STATE1;
                    end
                end

                default:begin
                    MGR_STATE <= MGR_IDEL;
                end

            endcase

        end
    end

    frame_ctrl_es120mc1 #(
            .EPD_V(EPD_V)
        ) frame_ctrl (
            .rst_n    (epd_rst_n),
            .epd_clk  (epd_clk),
            .s_flag   (sf_flag),  // 开始信号
            .SKV      (EPD_SKV),
            .SPV      (EPD_SPV),
            .XCL      (EPD_XCL),
            .XLE      (EPD_XLE),
            .XSTL     (EPD_XSTL),
            .r_flag   (row_request),
            .end_flag (fend_flag)  // 帧完成
        );

    wire [EPD_WID - 1:0] DOUT;
    wire pop;
    assign r_flag = row_request && !initializing;
    assign fifo_ren = pop && !initializing;
    // epd_clear_area_cycles: ten black scans, ten white, two no-op.
    // Prefix ten white scans to give a visible white-black-white power-on clean.
    wire [1:0] init_drive = whitening ? ((period_cnt <= 10) ? 2'b10 : 2'b00) :
                            (period_cnt <= 10) ? 2'b10 :
                            (period_cnt <= 20) ? 2'b01 :
                            (period_cnt <= 30) ? 2'b10 : 2'b00;
    reg [1:0] init_drive_fall;
    reg initializing_fall;
    always @(negedge epd_clk or negedge epd_rst_n) begin
        if (!epd_rst_n) begin init_drive_fall <= 0; initializing_fall <= 0; end
        else begin init_drive_fall <= init_drive; initializing_fall <= initializing; end
    end

    // Resolve internal repair markers BEFORE the falling-edge serializer.
    // No phase comparator or recovery mux may extend the SDD output path.
    wire [FDMA_WID-1:0] driven_data;
    genvar lane;
    generate for (lane=0; lane<FDMA_WID/2; lane=lane+1) begin: waveform
        wire [1:0] code = din[2*lane+:2];
        assign driven_data[2*lane+:2] = (!LOCAL_RECOVERY || NATIVE_GC16) ? code :
            recovering ? ((code == 2'b10 || code == 2'b11) ?
                              ((period_cnt <= 10) ? 2'b10 : 2'b00) :
                          ((code == 2'b01 && period_cnt <= 5) ? 2'b01 : 2'b00)) :
            ((code == 2'b11) ? 2'b00 : code);
    end endgenerate

    data_mgr #(
            .IN_WID(FDMA_WID),
            .OUT_WID(EPD_WID),
            // EPD_H is passed in 8-bit packed pixels.  Mode 3 emits one
            // 16-bit value for four packed pixels, or 320 CKH cycles/line.
            .LINE_DATA_COUNT(EPD_H / (EPD_WID / 4))
        ) data_mgr (
            .clk      (epd_clk),
            .rst_n    (epd_rst_n),
            .fifo_ren (pop),
            .din      (driven_data),
            .data_ren (~EPD_XSTL && !initializing),
            .dout     (DOUT)
        );

    genvar i;
    generate for(i = 0; i < EPD_WID - 1; i = i + 2) begin
      assign EPD_DOUT[i + 1 : i] = EPD_XSTL ? 2'b00 :
          (initializing_fall ? init_drive_fall : DOUT[EPD_WID - 1 - i : EPD_WID - 2 - i]);
    end endgenerate

//    DATA_MGR_LOGIC DATA_MGR_LOGIC (
//        .clk(epd_clk), // input wire clk
//
//        .probe0(
//            {EPD_SPV,
//            r_flag,
//            fifo_ren,
//            din,
//            EPD_XSTL,
//            EPD_DOUT})
//    );

endmodule
