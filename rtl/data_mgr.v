
//////////////////////////////////////////////////////////////////////////////////
//
//  这是一个并行数据管理器,用于自动请求FIFO中的数据并转换成所需位宽
//
//////////////////////////////////////////////////////////////////////////////////

module data_mgr#
    (
    parameter IN_WID    = 64,  // FDMA数据宽度
    parameter OUT_WID   = 8,  // 屏幕数据宽度
    // Number of OUT_WID words in one gate line; zero is an unbounded stream.
    parameter LINE_DATA_COUNT = 0
    )
    (
    input wire                      clk,
    input wire                      rst_n,
    output wire                     fifo_ren,  // 使能FIFO输出数据
    input wire  [IN_WID - 1:0]      din,
    input wire                      data_ren,  // 使能data_mgr输出数据
    output wire [OUT_WID - 1:0]     dout
    );

    localparam integer DATA_CNT = IN_WID / OUT_WID;
    localparam integer LINE_WORD_COUNT =
        (LINE_DATA_COUNT == 0) ? 0 : (LINE_DATA_COUNT / DATA_CNT);

    reg [4:0]               data_cnt;
    reg [15:0]              line_word_cnt;
    reg [IN_WID - 1:0]    t_din;  // 移位

    // The ES120MC1 samples SDD on CKH rising edges and requires tSU/tH >= 8ns.
    // Advance the parallel-to-serial register on the falling edge so DOUT is
    // stable for a complete half SDCK period around the sampling edge.
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_din <= 0;
            data_cnt <= 0;
            line_word_cnt <= 0;
        end
        else if (data_ren) begin
            if (data_cnt < DATA_CNT - 1) begin
                data_cnt <= data_cnt + 1'b1;
                t_din <= t_din >> OUT_WID;
            end
            else begin
                t_din <= din;
                data_cnt <= 0;
                if ((LINE_WORD_COUNT == 0) ||
                    (line_word_cnt < LINE_WORD_COUNT - 1)) begin
                    line_word_cnt <= line_word_cnt + 1'b1;
                end
            end
        end
        else begin
            t_din <= din;
            data_cnt <= 0;
            line_word_cnt <= 0;
        end
    end

    // FWFT exposes, but does not consume, the head. Pop EVERY loaded word,
    // including the last one. The shift register retains its final slice
    // while the FIFO advances, leaving the next line's head unconsumed.
    assign fifo_ren = data_ren &&
                      (data_cnt == DATA_CNT - 2) &&
                      ((LINE_WORD_COUNT == 0) ||
                       (line_word_cnt < LINE_WORD_COUNT));

    assign dout = t_din[OUT_WID - 1:0];  // 截取驱动数据

endmodule
