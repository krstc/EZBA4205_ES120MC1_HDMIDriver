// Planar 2-bit fields: each row contains field 0, field 1, then field 2.
// Only 640 bytes are read per 2560-pixel row instead of 2560 bytes.
module fdma_r_packet_es120mc1 #(parameter FRAME_H=2560,FRAME_V=1600)(
    input wire clk,rst_n,epd_clk,fdma_rflag,
    input wire [7:0] phase,
    input wire [31:0] buf_addr,
    output reg [31:0] fdma_raddr,
    output wire fdma_rareq,
    input wire fdma_rbusy,
    input wire [63:0] fdma_rdata,
    output wire fdma_rready,
    output wire [15:0] fdma_rsize,
    input wire fdma_rvalid,fifo_ren,
    output wire [63:0] fifo_out,
    output wire fifo_full,fifo_empty
);
    reg [1:0] state;
    reg [2:0] pending_rows;
    reg [11:0] row;
    wire launch=state==0 && pending_rows!=0;
    wire [7:0] phase_sync;
    xpm_cdc_array_single #(.WIDTH(8),.DEST_SYNC_FF(2),.SRC_INPUT_REG(0)) phase_cdc (
        .src_clk(epd_clk),.src_in(phase),.dest_clk(clk),.dest_out(phase_sync));
    assign fdma_rareq=state==1;
    assign fdma_rsize=FRAME_H/32;
    assign fdma_rready=!fifo_full;
    xpm_fifo_rdata_buf #(.FDMA_WID(64),.EPD_H(FRAME_H)) drive_fifo (
        .rst_n(rst_n),.wr_clk(clk),.rd_clk(epd_clk),.din(fdma_rdata),.wr_en(fdma_rvalid),
        .rd_en(fifo_ren),.dout(fifo_out),.full(fifo_full),.empty(fifo_empty));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=0;pending_rows<=0;row<=0;fdma_raddr<=0;end
        else begin
            case({fdma_rflag,launch})
                2'b10: pending_rows<=pending_rows+1'b1;
                2'b01: pending_rows<=pending_rows-1'b1;
                default: pending_rows<=pending_rows;
            endcase
            case(state)
                0: if(launch) begin
                    fdma_raddr<=buf_addr+row*(FRAME_H*3/4)+(phase_sync-1)*(FRAME_H/4);
                    row<=row==FRAME_V-1 ? 0 : row+1'b1;state<=1;
                end
                1: if(fdma_rbusy) state<=2;
                2: if(!fdma_rbusy) state<=0;
            endcase
        end
    end
endmodule
