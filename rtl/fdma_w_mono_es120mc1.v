// Binary subset of epdiy_ED047TC1 MODE_DU. Its five phases are identical:
// black->black=00, white->black=01, black->white=10, white->white=00.
// Consume the three FWFT inputs together, and count accepted words, not time.
module fdma_w_mono_es120mc1 #(
    parameter FDMA_WID=64, MAX_H=2560, FRAME_H=2560, FRAME_V=1600,
    parameter LOCAL_RECOVERY=0
)(
    input wire clk, rst_n,
    input wire clear_history,
    output reg [22:0] changed_pixels,
    input wire newFrame_fifo_empty, oldFrame_fifo_empty, texture_fifo_empty,
    output wire gray_ren,
    input wire [FDMA_WID-1:0] newFrame, oldFrame, texture,
    input wire [31:0] buf_addr,
    output reg [31:0] fdma_waddr,
    output wire fdma_wareq,
    input wire fdma_wbusy,
    output wire [FDMA_WID-1:0] fdma_wdata,
    output wire fdma_wready,
    output wire [15:0] fdma_wsize,
    input wire fdma_wvalid,
    output wire wbusy,
    output reg fflag
);
    localparam WORDS = FRAME_H / (FDMA_WID/8);
    localparam COLLECT=0, SETTLE=1, REQUEST=2, WAIT_DONE=3;
    reg [1:0] state;
    reg [11:0] word_count, line_count;
    reg [3:0] settle_count;
    wire full, empty;
    wire [FDMA_WID/4-1:0] drive;
    localparam PIXELS_PER_WORD = FDMA_WID/8;
    localparam TILE_COLS = (FRAME_H+31)/32;
    localparam TILE_ROWS = (FRAME_V+15)/16;
    localparam TILE_COUNT = TILE_COLS*TILE_ROWS;
    localparam HISTORY_WORDS = (TILE_COUNT+7)/8;
    wire [13:0] tile_address = (line_count >> 4)*TILE_COLS +
                              word_count/(32/PIXELS_PER_WORD);
    wire history_busy, tile_dirty;
    wire [PIXELS_PER_WORD-1:0] changed;
    reg [22:0] change_count;
    reg [4:0] word_changes;
    integer p;
    always @* begin
        word_changes = 0;
        for (p=0; p<PIXELS_PER_WORD; p=p+1)
            word_changes = word_changes + changed[p];
    end
    assign gray_ren = state == COLLECT && !full && !history_busy &&
                     !newFrame_fifo_empty && !oldFrame_fifo_empty && !texture_fifo_empty;
    genvar i;
    generate for (i=0; i<FDMA_WID/8; i=i+1) begin: du
        assign changed[i] = newFrame[8*i+7] != oldFrame[8*i+7];
        // 11 is an INTERNAL repair marker, never a voltage code at the pins.
        // Keep stable black and untouched white at zero drive. Remember white
        // pixels in recently changed tiles for one post-motion white repair.
        assign drive[2*i+:2] = changed[i] ?
                              (newFrame[8*i+7] ? 2'b10 : 2'b01) :
                              ((LOCAL_RECOVERY && tile_dirty && newFrame[8*i+7]) ?
                               2'b11 : 2'b00);
    end endgenerate
    generate if (LOCAL_RECOVERY) begin: history
        (* ram_style = "distributed" *) reg [7:0] dirty [0:HISTORY_WORDS-1];
        reg clearing;
        reg [13:0] clear_index;
        assign history_busy = clearing || clear_history;
        assign tile_dirty = dirty[tile_address >> 3][tile_address[2:0]];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                clearing <= 1'b1;
                clear_index <= 0;
            end else if (clear_history) begin
                clearing <= 1'b1;
                clear_index <= 0;
            end else if (clearing) begin
                if (clear_index == HISTORY_WORDS-1) begin
                    clearing <= 1'b0;
                    clear_index <= 0;
                end else clear_index <= clear_index+1'b1;
            end
        end
        // Clear eight tiles/clock: 20 us at full size, below one HDMI line.
        // A one-bit sweep blocks consumption for 160 us and can overflow the
        // live HDMI FIFOs when capture starts close to VS.
        always @(posedge clk) begin
            if (clearing) dirty[clear_index] <= 8'b0;
            else if (gray_ren && |changed) dirty[tile_address >> 3][tile_address[2:0]] <= 1'b1;
        end
    end else begin: no_history
        assign history_busy = 1'b0;
        assign tile_dirty = 1'b0;
    end endgenerate

    // Count the actual accepted pixels, including the last word of the frame.
    // The result is stable before the final DDR write completes.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            change_count <= 0;
            changed_pixels <= 0;
        end else if (gray_ren) begin
            if (line_count == FRAME_V-1 && word_count == WORDS-1) begin
                changed_pixels <= change_count + word_changes;
                change_count <= 0;
            end else change_count <= change_count + word_changes;
        end
    end
    xpm_fifo_wdata_buf #(.FDMA_WID(FDMA_WID), .FRAME_H(FRAME_H)) packed_fifo (
        .clk(clk), .rst_n(rst_n), .din(drive), .wr_en(gray_ren),
        .rd_en(fdma_wvalid), .dout(fdma_wdata), .full(full), .empty(empty)
    );
    assign fdma_wareq = state == REQUEST;
    assign fdma_wready = !empty;
    assign fdma_wsize = FRAME_H * 2 / FDMA_WID;
    assign wbusy = state != COLLECT || word_count != 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= COLLECT; word_count <= 0; line_count <= 0;
            fflag <= 0; settle_count <= 0; fdma_waddr <= 0;
        end else begin
            fflag <= 0;
            case (state)
                COLLECT: if (gray_ren) begin
                    if (word_count == WORDS-1) begin
                        word_count <= 0;
                        fdma_waddr <= buf_addr + line_count * (MAX_H/4);
                        settle_count <= 0;
                        state <= SETTLE;
                    end else word_count <= word_count+1'b1;
                end
                SETTLE: if (settle_count == 7) state <= REQUEST;
                        else settle_count <= settle_count+1'b1;
                REQUEST: if (fdma_wbusy) state <= WAIT_DONE;
                WAIT_DONE: if (!fdma_wbusy) begin
                    fflag <= 1;
                    line_count <= (line_count == FRAME_V-1) ? 0 : line_count+1'b1;
                    state <= COLLECT;
                end
            endcase
        end
    end
endmodule
