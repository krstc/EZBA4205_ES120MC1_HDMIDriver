// Preserve all four gray bits. A transition byte is {target, previous}.
module fdma_w_gc16_es120mc1 #(
    parameter MAX_H=2560, FRAME_H=2560, FRAME_V=1600,
    parameter HYBRID_REFRESH=0, REFINE_ROWS=128
)(
    input wire clk, rst_n, clear_history,
    input wire fast_update, refine_update, clear_band,
    input wire [11:0] refine_y,
    input wire state_fifo_empty,
    input wire [63:0] panel_state,
    output reg [22:0] changed_pixels,
    output reg [22:0] drive_pixels, pending_pixels,
    input wire newFrame_fifo_empty, oldFrame_fifo_empty,
    output wire gray_ren,
    input wire [63:0] newFrame, oldFrame,
    input wire [13:0] recovery_tile,
    output wire recovery_dirty,
    input wire [31:0] buf_addr,
    output reg [31:0] fdma_waddr,
    output wire fdma_wareq,
    input wire fdma_wbusy,
    output wire [63:0] fdma_wdata,
    output wire fdma_wready,
    output wire [15:0] fdma_wsize,
    input wire fdma_wvalid,
    output wire wbusy,
    output reg fflag
);
    localparam WORDS=FRAME_H/8, TILE_COLS=(FRAME_H+31)/32;
    localparam TILES=TILE_COLS*((FRAME_V+15)/16), HISTORY_WORDS=(TILES+7)/8;
    localparam COLLECT=0, SETTLE=1, REQUEST=2, WAIT_DONE=3;
    reg [1:0] state;
    reg [11:0] word_count, line_count;
    reg [3:0] settle_count;
    wire full, empty, wr_reset_busy, rd_reset_busy;
    wire [63:0] transitions;
    wire [7:0] changed;
    wire [7:0] driven, pending_gray;
    reg [22:0] change_count;
    reg [22:0] drive_count, pending_count;
    reg [3:0] word_changes, word_driven, word_pending;
    wire [13:0] tile_address=(line_count>>4)*TILE_COLS+(word_count>>2);
    (* ram_style="distributed" *) reg [7:0] dirty [0:HISTORY_WORDS-1];
    reg clearing;
    reg [13:0] clear_index;
    reg partial_clear;
    reg [13:0] clear_first_tile,clear_end_tile;
    reg [7:0] keep_mask;
    integer bit_index;
    always @* begin
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)
            keep_mask[bit_index]=partial_clear &&
                (clear_index*8+bit_index < clear_first_tile ||
                 clear_index*8+bit_index >= clear_end_tile);
    end
    wire in_band=line_count>=refine_y && line_count<refine_y+REFINE_ROWS;
    wire tile_dirty=dirty[tile_address>>3][tile_address[2:0]];
    assign recovery_dirty = recovery_tile < TILES && !clearing && !clear_history ?
                            dirty[recovery_tile>>3][recovery_tile[2:0]] : 1'b0;
    assign gray_ren=state==COLLECT && !full && !wr_reset_busy && !clearing &&
                    !clear_history && !(HYBRID_REFRESH && clear_band) &&
                    !newFrame_fifo_empty && !oldFrame_fifo_empty &&
                    (!HYBRID_REFRESH || !state_fifo_empty);
    genvar i;
    generate for(i=0;i<8;i=i+1) begin: pixels
        wire [3:0] desired=newFrame[8*i+4+:4];
        wire [3:0] previous=HYBRID_REFRESH ? panel_state[8*i+4+:4] : oldFrame[8*i+4+:4];
        wire [3:0] target=!HYBRID_REFRESH ? desired :
            (fast_update || (refine_update && !in_band)) ?
                (changed[i] ? (desired[3] ? 4'hf : 4'h0) : previous) : desired;
        assign transitions[8*i+:8]={target,previous};
        assign changed[i]=newFrame[8*i+4+:4]!=oldFrame[8*i+4+:4];
        assign driven[i]=target!=previous || (HYBRID_REFRESH && refine_update &&
                          in_band && tile_dirty && target==15);
        assign pending_gray[i]=desired!=target;
    end endgenerate
    integer p;
    always @* begin
        word_changes=0; word_driven=0; word_pending=0;
        for(p=0;p<8;p=p+1) begin
            word_changes=word_changes+changed[p];
            word_driven=word_driven+driven[p];
            word_pending=word_pending+pending_gray[p];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            clearing<=1;clear_index<=0;partial_clear<=0;clear_first_tile<=0;clear_end_tile<=0;
        end
        else if(clear_history) begin clearing<=1; clear_index<=0;partial_clear<=0;end
        else if(HYBRID_REFRESH && clear_band) begin
            clearing<=1;clear_index<=0;partial_clear<=1;
            clear_first_tile<=(refine_y>>4)*TILE_COLS;
            clear_end_tile<=((refine_y+REFINE_ROWS)>>4)*TILE_COLS;
        end
        else if(clearing) begin
            if(clear_index==HISTORY_WORDS-1) begin clearing<=0; clear_index<=0; end
            else clear_index<=clear_index+1'b1;
        end
    end
    always @(posedge clk) begin
        if(clearing) dirty[clear_index]<=partial_clear ? dirty[clear_index]&keep_mask : 8'd0;
        else if(gray_ren && |changed) dirty[tile_address>>3][tile_address[2:0]]<=1;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            change_count<=0; changed_pixels<=0;drive_count<=0;pending_count<=0;
            drive_pixels<=0;pending_pixels<=0;
        end
        else if(gray_ren) begin
            if(line_count==FRAME_V-1 && word_count==WORDS-1) begin
                changed_pixels<=change_count+word_changes;
                drive_pixels<=drive_count+word_driven;
                pending_pixels<=pending_count+word_pending;
                change_count<=0;
                drive_count<=0;pending_count<=0;
            end else begin
                change_count<=change_count+word_changes;
                drive_count<=drive_count+word_driven;
                pending_count<=pending_count+word_pending;
            end
        end
    end
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(1024),
        .WRITE_DATA_WIDTH(64),.READ_DATA_WIDTH(64),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.USE_ADV_FEATURES("0000"),
        .WR_DATA_COUNT_WIDTH(1),.RD_DATA_COUNT_WIDTH(1)
    ) transition_fifo (
        .rst(!rst_n),.wr_clk(clk),.din(transitions),.wr_en(gray_ren),
        .rd_en(fdma_wvalid),.dout(fdma_wdata),.full(full),.empty(empty),
        .wr_rst_busy(wr_reset_busy),.rd_rst_busy(rd_reset_busy),.sleep(1'b0),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0)
    );
    assign fdma_wareq=state==REQUEST;
    assign fdma_wready=!empty && !rd_reset_busy;
    assign fdma_wsize=WORDS;
    assign wbusy=state!=COLLECT || word_count!=0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=COLLECT;word_count<=0;line_count<=0;settle_count<=0;fdma_waddr<=0;fflag<=0;
        end else begin
            fflag<=0;
            case(state)
                COLLECT: if(gray_ren) begin
                    if(word_count==WORDS-1) begin
                        word_count<=0;fdma_waddr<=buf_addr+line_count*MAX_H;
                        settle_count<=0;state<=SETTLE;
                    end else word_count<=word_count+1'b1;
                end
                SETTLE: if(settle_count==7) state<=REQUEST;
                        else settle_count<=settle_count+1'b1;
                REQUEST: if(fdma_wbusy) state<=WAIT_DONE;
                WAIT_DONE: if(!fdma_wbusy) begin
                    fflag<=1;line_count<=(line_count==FRAME_V-1)?0:line_count+1'b1;
                    state<=COLLECT;
                end
            endcase
        end
    end
endmodule
