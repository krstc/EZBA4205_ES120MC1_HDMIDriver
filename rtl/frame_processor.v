//`define vsim  // 仿真命令
//////////////////////////////////////////////////////////////////////////////////
//
//  这个模块用于完成帧处理成驱动数据并缓冲到DDR内存的过程
// 
//////////////////////////////////////////////////////////////////////////////////

module frame_processor#
    (
    // FDMA配置
    parameter FDMA_WID                = 64,     // FDMA数据宽度
    // EPD
    parameter EPD_WID                 = 8,      // 接口宽度
    parameter EPD_H                   = 1200,   // EPD屏幕长度
    parameter EPD_V                   = 825,    // EPD屏幕宽度
    // 输入图像配置
    parameter MAX_H                   = 2208,   // 考虑地址对齐所以+8
    parameter MAX_V                   = 1872,
    parameter FRAME_H                 = 1920,   // 输入长度
    parameter FRAME_V                 = 1080,   // 输入宽度
    parameter DIRECT_MONO             = 0,
    parameter LOCAL_RECOVERY          = 0,
    parameter NATIVE_GC16             = 0,
    parameter HYBRID_REFRESH          = 0,
    parameter REFINE_ROWS             = 128,
    // 缓冲区配置
    parameter GRAY_SIZE               = 4,      // 缓冲区长度单位MB
    parameter DATA_SIZE               = 1,
    parameter TEXTURE_ADDR_MEM_OFFSET = 32'h1F100000,
    parameter GRAY_0_ADDR_MEM_OFFSET  = 32'h1F500000,
    parameter GRAY_1_ADDR_MEM_OFFSET  = 32'h1F900000,
    parameter DATA_0_ADDR_MEM_OFFSET  = 32'h1FD00000,
    parameter DATA_1_ADDR_MEM_OFFSET  = 32'h1FE00000
    )
    (
    input wire                  clk,
    input wire                  rst_n,
    input wire                  pix_rst_n,
    input wire                  epd_rst_n,
    // 帧采样处理
    input wire                  w_gray_s_flag,  // 开始处理一帧

    input wire                  pix_clk,
    input wire                  gray_de,
    input wire                  gray_hs,
    input wire                  gray_vs,
    input wire  [7:0]           gray_data,

    output wire                 w_gray_busy,  // 正在采样
    output wire                 w_gray_fflag,  // 采样完成标志
    // 缓冲区屏幕清理
    input wire                  clr_s_flag,  // 开始清除缓冲区
    input wire                  clear_history,
    output wire [22:0]          changed_pixels,
    output wire [22:0]          drive_pixels, pending_pixels,
    input wire                  hybrid_fast, hybrid_refine, clear_band,
    input wire [11:0]            refine_y,
    output wire                 clr_fflag,  // 缓冲区清除完毕
    // 驱动数据输出
    input wire                  epd_clk,
    input wire [7:0]             gc16_phase,
    input wire                  gc16_recovery,
    input wire                  sw_rdata_addr,  // 周期完成切换地址
    input wire                  r_data_flag,  // FMDA读取一行信号
    input wire                  r_data_fifo_ren,  // FIFO读取一行信号
    output wire [FDMA_WID -1:0] r_data_fifo_out,  // FIFO数据输出

    output wire                 CLK_50M,
    output wire                 GPIO_O
    ,output wire                dma_idle
    );

//--------------------------------------------------------------
    wire    [31:0]              clear_fdma_waddr;
    wire                        clear_fdma_wareq;
    wire                        clear_fdma_wbusy;
    wire    [FDMA_WID - 1:0]    clear_fdma_wdata;
    wire                        clear_fdma_wready;
    wire    [15:0]              clear_fdma_wsize;
    wire                        clear_fdma_wvalid;
//--------------------------------------------------------------
    wire                        texture_rbusy;
    wire                        texture_fflag;
    wire    [FDMA_WID - 1:0]    texture_fifo_out;
    wire                        texture_fifo_full;
    wire                        texture_fifo_empty;

    wire    [31:0]              texture_fdma_raddr;
    wire                        texture_fdma_rareq;
    wire                        texture_fdma_rbusy;
    wire    [FDMA_WID - 1:0]    texture_fdma_rdata;
    wire                        texture_fdma_rready;
    wire    [15:0]              texture_fdma_rsize;
    wire                        texture_fdma_rvalid;
//--------------------------------------------------------------
    wire                        oldFrame_rbusy;
    wire                        oldFrame_fflag;
    wire    [FDMA_WID - 1:0]    oldFrame_fifo_out;
    wire                        oldFrame_fifo_full;
    wire                        oldFrame_fifo_empty;

    wire    [31:0]              gray_fdma_raddr;
    wire                        gray_fdma_rareq;
    wire                        gray_fdma_rbusy;
    wire    [FDMA_WID - 1:0]    gray_fdma_rdata;
    wire                        gray_fdma_rready;
    wire    [15:0]              gray_fdma_rsize;
    wire                        gray_fdma_rvalid;
//--------------------------------------------------------------
    wire    [FDMA_WID - 1:0]    newFrame_fifo_out;
    wire                        newFrame_fifo_full;
    wire                        newFrame_fifo_empty;

    wire    [31:0]              gray_fdma_waddr;
    wire                        gray_fdma_wareq;
    wire                        gray_fdma_wbusy;
    wire    [FDMA_WID - 1:0]    gray_fdma_wdata;
    wire                        gray_fdma_wready;
    wire    [15:0]              gray_fdma_wsize;
    wire                        gray_fdma_wvalid;
//--------------------------------------------------------------
    wire                        r_data_rbusy;
    wire                        r_data_fflag;

    wire                        r_data_fifo_full;
    wire                        r_data_fifo_empty;

    wire                        r_data_flag_t;

    wire    [31:0]              data_fdma_raddr;
    wire                        data_fdma_rareq;
    wire                        data_fdma_rbusy;
    wire    [FDMA_WID - 1:0]    data_fdma_rdata;
    wire                        data_fdma_rready;
    wire    [15:0]              data_fdma_rsize;
    wire                        data_fdma_rvalid;
//--------------------------------------------------------------
    wire                        gray_ren;
    wire                        w_data_wbusy;
    wire                        w_data_fflag;

    wire    [31:0]              data_fdma_waddr;
    wire                        data_fdma_wareq;
    wire                        data_fdma_wbusy;
    wire    [FDMA_WID - 1:0]    data_fdma_wdata;
    wire                        data_fdma_wready;
    wire    [15:0]              data_fdma_wsize;
    wire                        data_fdma_wvalid;
//--------------------------------------------------------------
    wire                        sw_rdata_addr_t;
//--------------------------------------------------------------
    wire                        r_gray_flag;
    assign dma_idle = !(clear_fdma_wareq || clear_fdma_wbusy ||
                       gray_fdma_wareq || gray_fdma_wbusy ||
                       gray_fdma_rareq || gray_fdma_rbusy ||
                       texture_fdma_rareq || texture_fdma_rbusy ||
                       data_fdma_wareq || data_fdma_wbusy ||
                       data_fdma_rareq || data_fdma_rbusy);
    wire                        gray_capture_done;
    wire                        gray_capture_busy;
    reg [11:0]                  completed_drive_rows;
    reg                         gray_complete_seen, drive_complete_seen;
    reg                         complete_frame;

    // A gray capture can finish before its last converted DDR row is written.
    // Do not swap either write buffer or launch the panel until BOTH finish.
    assign w_gray_fflag = (DIRECT_MONO == 2 || NATIVE_GC16) ? complete_frame : gray_capture_done;
    assign w_gray_busy = (DIRECT_MONO == 2 || NATIVE_GC16) ?
                         (gray_capture_busy || gray_complete_seen || drive_complete_seen) : gray_capture_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            completed_drive_rows <= 0;
            gray_complete_seen <= 0; drive_complete_seen <= 0; complete_frame <= 0;
        end else begin
            complete_frame <= 0;
            if (clr_s_flag || w_gray_s_flag) begin
                completed_drive_rows <= 0;
                gray_complete_seen <= 0; drive_complete_seen <= 0;
            end else begin
                if (gray_capture_done) gray_complete_seen <= 1;
                if (w_data_fflag) begin
                    if (completed_drive_rows == FRAME_V-1) begin
                        completed_drive_rows <= 0;
                        drive_complete_seen <= 1;
                    end else completed_drive_rows <= completed_drive_rows+1'b1;
                end
                if (gray_complete_seen && drive_complete_seen) begin
                    complete_frame <= 1;
                    gray_complete_seen <= 0; drive_complete_seen <= 0;
                end
            end
        end
    end
//--------------------------------------------------------------
    wire    [31:0]              gray_w_addr;
    wire    [31:0]              gray_r_addr;
//--------------------------------------------------------------
    wire    [31:0]              data_w_addr;
    wire    [31:0]              data_r_addr;
    wire    [31:0]              panel_state_addr;
//--------------------------------------------------------------

    sync_h2lck sync_sw_rdata_addr
        (
            .in_clk    (epd_clk),
            .out_clk   (clk),
            .rst_n     (epd_rst_n),
            .level_in  (sw_rdata_addr),
            .pulse_out (sw_rdata_addr_t)
        );

    sync_h2lck sync_r_data_flag
        (
            .in_clk    (epd_clk),
            .out_clk   (clk),
            .rst_n     (epd_rst_n),
            .level_in  (r_data_flag),
            .pulse_out (r_data_flag_t)
        );

    addr_sw #(  // 缓冲数据地址转换器
            .ADDR_0         (GRAY_0_ADDR_MEM_OFFSET),
            .ADDR_1         (GRAY_1_ADDR_MEM_OFFSET)
        ) addr_sw_gray (
            .clk            (clk),
            .rst_n          (rst_n & ~clr_s_flag),  // 清除缓冲区时复位地址指针
            .sw             (w_gray_fflag),  // 切地址信号,帧采样完成后切换地址
            .new_addr       (gray_w_addr),
            .old_addr       (gray_r_addr)
        );

    addr_sw #(  // 驱动数据地址转换器
            .ADDR_0         (DATA_0_ADDR_MEM_OFFSET),
            .ADDR_1         (DATA_1_ADDR_MEM_OFFSET)
        ) addr_sw_wdata (
            .clk            (clk),
            .rst_n          (rst_n & ~clr_s_flag),  // 清除缓冲区时复位地址指针
            .sw             (w_gray_fflag),  // 切地址信号,帧采样完成后切换地址
            .new_addr       (data_w_addr),
            .old_addr       (panel_state_addr)
        );

    addr_sw #(  // 驱动数据地址转换器
            .ADDR_0         (DATA_0_ADDR_MEM_OFFSET),
            .ADDR_1         (DATA_1_ADDR_MEM_OFFSET)
        ) addr_sw_rdata (
            .clk            (clk),
            .rst_n          (rst_n & ~clr_s_flag),  // 清除缓冲区时复位地址指针
            .sw             (sw_rdata_addr_t),
            .new_addr       (data_r_addr),
            .old_addr       ()
        );

    level2pulse #(  // 读取DDR缓冲区数据信号
        .MODE("RISING")
        ) r_gray_start_flag (
        .clk    (clk),
        .rst_n  (rst_n),
        .in     (gray_fdma_wbusy),
        .out    (r_gray_flag)
    );

    fdma_w_gray #(  // 以帧为单位写入新帧
            .SAFE_CAPTURE  (DIRECT_MONO == 2 || NATIVE_GC16),
            .FDMA_WID       (FDMA_WID),
            .MAX_H          (MAX_H),
            .FRAME_H        (FRAME_H),
            .FRAME_V        (FRAME_V)
        ) newframe_ctrl (
            .clk            (clk),
            .rst_n          (rst_n),
            .pix_rst_n      (pix_rst_n),
            .fdma_wflag     (w_gray_s_flag),
            .pix_clk        (pix_clk),
            .gray_data      (gray_data),
            .gray_vs        (gray_vs),
            .gray_hs        (gray_hs),
            .gray_de        (gray_de),
            .buf_addr       (gray_w_addr),
            .fdma_waddr     (gray_fdma_waddr),
            .fdma_wareq     (gray_fdma_wareq),
            .fdma_wbusy     (gray_fdma_wbusy),
            .fdma_wdata     (gray_fdma_wdata),
            .fdma_wready    (gray_fdma_wready),
            .fdma_wsize     (gray_fdma_wsize),
            .fdma_wvalid    (gray_fdma_wvalid),
            .wbusy          (gray_capture_busy),
            .fflag          (gray_capture_done),
            .fifo_ren       (gray_ren),
            .fifo_out       (newFrame_fifo_out),
            .fifo_full      (newFrame_fifo_full),
            .fifo_empty     (newFrame_fifo_empty)
        );

    fdma_r_gary #(  // 以行为单位读出旧帧
            .FDMA_WID       (FDMA_WID),
            .MAX_H          (MAX_H),
            .FRAME_H        (FRAME_H),
            .FRAME_V        (FRAME_V)
        ) oldframe_ctrl (
            .clk            (clk),
            .rst_n          (rst_n),
            .fdma_rflag     (r_gray_flag),
            .buf_addr       (gray_r_addr),
            .fdma_raddr     (gray_fdma_raddr),
            .fdma_rareq     (gray_fdma_rareq),
            .fdma_rbusy     (gray_fdma_rbusy),
            .fdma_rdata     (gray_fdma_rdata),
            .fdma_rready    (gray_fdma_rready),
            .fdma_rsize     (gray_fdma_rsize),
            .fdma_rvalid    (gray_fdma_rvalid),
            .rbusy          (oldFrame_rbusy),
            .fflag          (oldFrame_fflag),
            .fifo_ren       (gray_ren),
            .fifo_out       (oldFrame_fifo_out),
            .fifo_full      (oldFrame_fifo_full),
            .fifo_empty     (oldFrame_fifo_empty)
        );

    fdma_r_gary #(  // 以行为单位读出纹理
            .FDMA_WID       (FDMA_WID),
            .MAX_H          (MAX_H),
            .FRAME_H        (FRAME_H),
            .FRAME_V        (FRAME_V)
        ) texture_ctrl (
            .clk            (clk),
            .rst_n          (rst_n),
            .fdma_rflag     (NATIVE_GC16 && !HYBRID_REFRESH ? 1'b0 : r_gray_flag),
            .buf_addr       (HYBRID_REFRESH ? panel_state_addr : TEXTURE_ADDR_MEM_OFFSET),
            .fdma_raddr     (texture_fdma_raddr),
            .fdma_rareq     (texture_fdma_rareq),
            .fdma_rbusy     (texture_fdma_rbusy),
            .fdma_rdata     (texture_fdma_rdata),
            .fdma_rready    (texture_fdma_rready),
            .fdma_rsize     (texture_fdma_rsize),
            .fdma_rvalid    (texture_fdma_rvalid),
            .rbusy          (texture_rbusy),
            .fflag          (texture_fflag),
            .fifo_ren       (gray_ren),
            .fifo_out       (texture_fifo_out),
            .fifo_full      (texture_fifo_full),
            .fifo_empty     (texture_fifo_empty)
        );

    wire [13:0] recovery_tile;
    wire recovery_dirty;
    generate if (NATIVE_GC16) begin: native_gray
        fdma_w_gc16_es120mc1 #(.MAX_H(MAX_H),.FRAME_H(FRAME_H),.FRAME_V(FRAME_V),
            .HYBRID_REFRESH(HYBRID_REFRESH),.REFINE_ROWS(REFINE_ROWS)) data_w_ctrl (
            .clk(clk),.rst_n(rst_n),.clear_history(clear_history || clr_s_flag),
            .fast_update(hybrid_fast),.refine_update(hybrid_refine),.refine_y(refine_y),
            .clear_band(clear_band),.state_fifo_empty(texture_fifo_empty),.panel_state(texture_fifo_out),
            .drive_pixels(drive_pixels),.pending_pixels(pending_pixels),
            .changed_pixels(changed_pixels),.recovery_tile(recovery_tile),.recovery_dirty(recovery_dirty),
            .newFrame_fifo_empty(newFrame_fifo_empty),.oldFrame_fifo_empty(oldFrame_fifo_empty),
            .gray_ren(gray_ren),.newFrame(newFrame_fifo_out),.oldFrame(oldFrame_fifo_out),
            .buf_addr(data_w_addr),.fdma_waddr(data_fdma_waddr),.fdma_wareq(data_fdma_wareq),
            .fdma_wbusy(data_fdma_wbusy),.fdma_wdata(data_fdma_wdata),.fdma_wready(data_fdma_wready),
            .fdma_wsize(data_fdma_wsize),.fdma_wvalid(data_fdma_wvalid),.wbusy(w_data_wbusy),.fflag(w_data_fflag)
        );
    end else if (DIRECT_MONO == 2) begin: safe_mono
        fdma_w_mono_es120mc1 #(
            .FDMA_WID(FDMA_WID), .MAX_H(MAX_H), .FRAME_H(FRAME_H), .FRAME_V(FRAME_V),
            .LOCAL_RECOVERY(LOCAL_RECOVERY)
        ) data_w_ctrl (
            .clk(clk), .rst_n(rst_n),
            .clear_history(clear_history || clr_s_flag), .changed_pixels(changed_pixels),
            .newFrame_fifo_empty(newFrame_fifo_empty),
            .oldFrame_fifo_empty(oldFrame_fifo_empty), .texture_fifo_empty(texture_fifo_empty),
            .gray_ren(gray_ren), .newFrame(newFrame_fifo_out),
            .oldFrame(oldFrame_fifo_out), .texture(texture_fifo_out), .buf_addr(data_w_addr),
            .fdma_waddr(data_fdma_waddr), .fdma_wareq(data_fdma_wareq),
            .fdma_wbusy(data_fdma_wbusy), .fdma_wdata(data_fdma_wdata),
            .fdma_wready(data_fdma_wready), .fdma_wsize(data_fdma_wsize),
            .fdma_wvalid(data_fdma_wvalid), .wbusy(w_data_wbusy), .fflag(w_data_fflag)
        );
    end else begin: legacy_algo
    assign changed_pixels = 0;
    fdma_w_data #(  // 以行为单位处理图像数据并写入数据缓冲区
            .FDMA_WID            (FDMA_WID),
            .MAX_H               (MAX_H),
            .FRAME_H             (FRAME_H),
            .FRAME_V             (FRAME_V),
            .DIRECT_MONO         (DIRECT_MONO)
        ) data_w_ctrl (
            .clk                 (clk),
            .rst_n               (rst_n),
            .newFrame_fifo_empty (newFrame_fifo_empty),
            .oldFrame_fifo_empty (oldFrame_fifo_empty),
            .texture_fifo_empty  (texture_fifo_empty),
            .gray_ren            (gray_ren),
            .newFrame            (newFrame_fifo_out),
            .oldFrame            (oldFrame_fifo_out),
            .texture             (texture_fifo_out),
            .buf_addr            (data_w_addr),
            .fdma_waddr          (data_fdma_waddr),
            .fdma_wareq          (data_fdma_wareq),
            .fdma_wbusy          (data_fdma_wbusy),
            .fdma_wdata          (data_fdma_wdata),
            .fdma_wready         (data_fdma_wready),
            .fdma_wsize          (data_fdma_wsize),
            .fdma_wvalid         (data_fdma_wvalid),
            .wbusy               (w_data_wbusy),
            .fflag               (w_data_fflag)
        );
    end endgenerate

    generate if (NATIVE_GC16) begin: native_read
        fdma_r_gc16_es120mc1 #(.MAX_H(MAX_H),.EPD_H(EPD_H),.EPD_V(EPD_V),
            .HYBRID_REFRESH(HYBRID_REFRESH),.REFINE_ROWS(REFINE_ROWS)) reader (
            .clk(clk),.rst_n(rst_n),.epd_clk(epd_clk),.fdma_rflag(r_data_flag_t),
            .phase(gc16_phase),.local_recovery(gc16_recovery),
            .fast_update(hybrid_fast),.refine_update(hybrid_refine),.refine_y(refine_y),
            .recovery_tile(recovery_tile),.recovery_dirty(recovery_dirty),
            // Sequential hybrid updates can skip unchanged captures. Select
            // the last committed transition buffer, not a display-done toggle.
            .buf_addr(HYBRID_REFRESH ? panel_state_addr : data_r_addr),
            .fdma_raddr(data_fdma_raddr),.fdma_rareq(data_fdma_rareq),.fdma_rbusy(data_fdma_rbusy),
            .fdma_rdata(data_fdma_rdata),.fdma_rready(data_fdma_rready),.fdma_rsize(data_fdma_rsize),
            .fdma_rvalid(data_fdma_rvalid),.fifo_ren(r_data_fifo_ren),.fifo_out(r_data_fifo_out),
            .fifo_full(r_data_fifo_full),.fifo_empty(r_data_fifo_empty)
        );
    end else begin: legacy_read
    fdma_r_data #(
            .FDMA_WID(FDMA_WID),
            .EPD_WID(EPD_WID),
            .MAX_H(MAX_H),
            .EPD_H(EPD_H),
            .EPD_V(EPD_V)
        ) fdma_r_data (
            .clk         (clk),
            .rst_n       (rst_n),
            .fdma_rflag  (r_data_flag_t),
            .buf_addr    (data_r_addr),
            .fdma_raddr  (data_fdma_raddr),
            .fdma_rareq  (data_fdma_rareq),
            .fdma_rbusy  (data_fdma_rbusy),
            .fdma_rdata  (data_fdma_rdata),
            .fdma_rready (data_fdma_rready),
            .fdma_rsize  (data_fdma_rsize),
            .fdma_rvalid (data_fdma_rvalid),
            .rbusy       (r_data_rbusy),
            .fflag       (r_data_fflag),
            .epd_clk     (epd_clk),
            .fifo_ren    (r_data_fifo_ren),
            .fifo_out    (r_data_fifo_out),
            .fifo_full   (r_data_fifo_full),
            .fifo_empty  (r_data_fifo_empty)
        );

    end endgenerate

    fdma_clear #(
            .NATIVE_GC16(NATIVE_GC16),
            .FDMA_WID(FDMA_WID),
            .MAX_H(MAX_H),
            .MAX_V(MAX_V),
            .GRAY_0_ADDR_MEM_OFFSET(GRAY_0_ADDR_MEM_OFFSET),
            .GRAY_1_ADDR_MEM_OFFSET(GRAY_1_ADDR_MEM_OFFSET),
            .DATA_0_ADDR_MEM_OFFSET(DATA_0_ADDR_MEM_OFFSET),
            .DATA_1_ADDR_MEM_OFFSET(DATA_1_ADDR_MEM_OFFSET)
        ) fdma_clear (
            .clk         (clk),
            .rst_n       (rst_n),
            .clr_flag    (clr_s_flag),
            .fdma_waddr  (clear_fdma_waddr),
            .fdma_wareq  (clear_fdma_wareq),
            .fdma_wbusy  (clear_fdma_wbusy),
            .fdma_wdata  (clear_fdma_wdata),
            .fdma_wready (clear_fdma_wready),
            .fdma_wsize  (clear_fdma_wsize),
            .fdma_wvalid (clear_fdma_wvalid),
            .wbusy       (clr_wbusy),
            .fflag       (clr_fflag)
        );

    `ifdef vsim  // 仿真时AXI VIP有问题故采用 fdma_sim_slave 该模块仅响应读写并不产生数据

    fdma_sim_slave #(
            .FDMA_WID(FDMA_WID)
        ) texture_fdma_sim (
            .clk         (clk),
            .rst_n       (rst_n),
            .fdma_waddr  (clear_fdma_waddr),  // 接口用于重置缓冲区并非用于填充纹理!
            .fdma_wareq  (clear_fdma_wareq),
            .fdma_wbusy  (clear_fdma_wbusy),
            .fdma_wdata  (clear_fdma_wdata),
            .fdma_wready (clear_fdma_wready),
            .fdma_wsize  (clear_fdma_wsize),
            .fdma_wvalid (clear_fdma_wvalid),
            .fdma_raddr  (texture_fdma_raddr),  // 接口用于读出纹理
            .fdma_rareq  (texture_fdma_rareq),
            .fdma_rbusy  (texture_fdma_rbusy),
            .fdma_rdata  (texture_fdma_rdata),
            .fdma_rready (texture_fdma_rready),
            .fdma_rsize  (texture_fdma_rsize),
            .fdma_rvalid (texture_fdma_rvalid)
        );

    fdma_sim_slave #(
            .FDMA_WID(FDMA_WID)
        ) gray_fdma_sim (
            .clk         (clk),
            .rst_n       (rst_n),
            .fdma_waddr  (gray_fdma_waddr),  // 接口用于写入灰度数据
            .fdma_wareq  (gray_fdma_wareq),
            .fdma_wbusy  (gray_fdma_wbusy),
            .fdma_wdata  (gray_fdma_wdata),
            .fdma_wready (gray_fdma_wready),
            .fdma_wsize  (gray_fdma_wsize),
            .fdma_wvalid (gray_fdma_wvalid),
            .fdma_raddr  (gray_fdma_raddr),  // 接口用于读出灰度数据
            .fdma_rareq  (gray_fdma_rareq),
            .fdma_rbusy  (gray_fdma_rbusy),
            .fdma_rdata  (gray_fdma_rdata),
            .fdma_rready (gray_fdma_rready),
            .fdma_rsize  (gray_fdma_rsize),
            .fdma_rvalid (gray_fdma_rvalid)
        );

    fdma_sim_slave #(
            .FDMA_WID(FDMA_WID)
        ) data_fdma_sim (
            .clk         (clk),
            .rst_n       (rst_n),
            .fdma_waddr  (data_fdma_waddr),  // 接口用于写入处理完成的驱动数据
            .fdma_wareq  (data_fdma_wareq),
            .fdma_wbusy  (data_fdma_wbusy),
            .fdma_wdata  (data_fdma_wdata),
            .fdma_wready (data_fdma_wready),
            .fdma_wsize  (data_fdma_wsize),
            .fdma_wvalid (data_fdma_wvalid),
            .fdma_raddr  (data_fdma_raddr),  // 接口用于读出驱动数据
            .fdma_rareq  (data_fdma_rareq),
            .fdma_rbusy  (data_fdma_rbusy),
            .fdma_rdata  (data_fdma_rdata),
            .fdma_rready (data_fdma_rready),
            .fdma_rsize  (data_fdma_rsize),
            .fdma_rvalid (data_fdma_rvalid)
        );

    `else


    ps_system_wrapper ps_system
        (
            .clk                    (clk),
            .rst_n                  (rst_n),

            .CLK_50M                (CLK_50M),
            .GPIO_O                 (GPIO_O),

            .texture_fdma_waddr     (clear_fdma_waddr),  // 接口用于重置缓冲区并非用于填充纹理!
            .texture_fdma_wareq     (clear_fdma_wareq),
            .texture_fdma_wbusy     (clear_fdma_wbusy),
            .texture_fdma_wdata     (clear_fdma_wdata),
            .texture_fdma_wready    (clear_fdma_wready),
            .texture_fdma_wsize     (clear_fdma_wsize),
            .texture_fdma_wvalid    (clear_fdma_wvalid),

            .texture_fdma_raddr     (texture_fdma_raddr),  // 接口用于读出纹理
            .texture_fdma_rareq     (texture_fdma_rareq),
            .texture_fdma_rbusy     (texture_fdma_rbusy),
            .texture_fdma_rdata     (texture_fdma_rdata),
            .texture_fdma_rready    (texture_fdma_rready),
            .texture_fdma_rsize     (texture_fdma_rsize),
            .texture_fdma_rvalid    (texture_fdma_rvalid),

            .gray_fdma_waddr        (gray_fdma_waddr),     // 接口用于写入灰度数据
            .gray_fdma_wareq        (gray_fdma_wareq),
            .gray_fdma_wbusy        (gray_fdma_wbusy),
            .gray_fdma_wdata        (gray_fdma_wdata),
            .gray_fdma_wready       (gray_fdma_wready),
            .gray_fdma_wsize        (gray_fdma_wsize),
            .gray_fdma_wvalid       (gray_fdma_wvalid),

            .gray_fdma_raddr        (gray_fdma_raddr),     // 接口用于读出灰度数据
            .gray_fdma_rareq        (gray_fdma_rareq),
            .gray_fdma_rbusy        (gray_fdma_rbusy),
            .gray_fdma_rdata        (gray_fdma_rdata),
            .gray_fdma_rready       (gray_fdma_rready),
            .gray_fdma_rsize        (gray_fdma_rsize),
            .gray_fdma_rvalid       (gray_fdma_rvalid),

            .data_fdma_waddr        (data_fdma_waddr),     // 接口用于写入处理完成的驱动数据
            .data_fdma_wareq        (data_fdma_wareq),
            .data_fdma_wbusy        (data_fdma_wbusy),
            .data_fdma_wdata        (data_fdma_wdata),
            .data_fdma_wready       (data_fdma_wready),
            .data_fdma_wsize        (data_fdma_wsize),
            .data_fdma_wvalid       (data_fdma_wvalid),

            .data_fdma_raddr        (data_fdma_raddr),     // 接口用于读出驱动数据
            .data_fdma_rareq        (data_fdma_rareq),
            .data_fdma_rbusy        (data_fdma_rbusy),
            .data_fdma_rdata        (data_fdma_rdata),
            .data_fdma_rready       (data_fdma_rready),
            .data_fdma_rsize        (data_fdma_rsize),
            .data_fdma_rvalid       (data_fdma_rvalid)
        );

    `endif

//    FRAME_LOGIC FRAME_LOGIC (
//        .clk(clk), // input wire clk
//
//        .probe0 (
//            {sw_rdata_addr_t,
//            r_data_flag_t,
//            w_gray_fflag,
//            r_gray_flag,
//            gray_fdma_waddr,
//            gray_fdma_wdata,
//            gray_fdma_wvalid,
//            texture_fdma_raddr,
//            texture_fdma_rdata,
//            texture_fdma_rvalid,
//            data_fdma_waddr,
//            data_fdma_wdata,
//            data_fdma_wvalid,
//            data_fdma_raddr,
//            data_fdma_rdata,
//            data_fdma_rvalid}
//        )
//    );

endmodule
