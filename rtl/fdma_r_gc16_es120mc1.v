// Eight parallel GC16 lookups: one accepted DDR word represents eight pixels.
// The target buffer and dirty map stay immutable for the entire update.
module fdma_r_gc16_es120mc1 #(
    parameter MAX_H=2560, EPD_H=2560, EPD_V=1600,
    parameter HYBRID_REFRESH=0, REFINE_ROWS=128
)(
    input wire clk,rst_n,epd_clk,fdma_rflag,
    input wire [7:0] phase,
    input wire local_recovery,
    input wire fast_update, refine_update,
    input wire [11:0] refine_y,
    output wire [13:0] recovery_tile,
    input wire recovery_dirty,
    input wire [31:0] buf_addr,
    output reg [31:0] fdma_raddr,
    output wire fdma_rareq,
    input wire fdma_rbusy,
    input wire [63:0] fdma_rdata,
    output wire fdma_rready,
    output wire [15:0] fdma_rsize,
    input wire fdma_rvalid,
    input wire fifo_ren,
    output wire [63:0] fifo_out,
    output wire fifo_full,fifo_empty
);
    localparam WORDS=EPD_H/8,TILE_COLS=(EPD_H+31)/32;
    localparam IDLE=0,REQUEST=1,TRANSFER=2;
    reg [1:0] state;
    reg [2:0] pending_rows;
    wire launch_row=state==IDLE && pending_rows!=0;
    reg [11:0] row,active_row,word_count;
    wire [7:0] phase_sync;
    reg [7:0] row_phase;
    reg row_recovery;
    reg row_fast,row_refine;
    reg [11:0] row_refine_y;
    xpm_cdc_array_single #(.WIDTH(8),.DEST_SYNC_FF(2),.SRC_INPUT_REG(0)) phase_cdc (
        .src_clk(epd_clk),.src_in(phase),.dest_clk(clk),.dest_out(phase_sync)
    );
    assign recovery_tile=(active_row>>4)*TILE_COLS+(word_count>>2);
    assign fdma_rareq=state==REQUEST;
    assign fdma_rsize=WORDS;
    // One entire row fits with the two-line lead, so no response must be dropped.
    assign fdma_rready=!fifo_full;
    wire accepted=fdma_rvalid;
    wire repairing=row_recovery && recovery_dirty;
    wire prefix=row_recovery && row_phase<=12;
    wire [7:0] lut_phase=row_phase-(row_recovery?13:1);
    wire active_phase=!prefix && lut_phase<30;
    wire [15:0] lut_drive;
    wire in_band=active_row>=row_refine_y && active_row<row_refine_y+REFINE_ROWS;
    reg [7:0] enable_q;
    reg [15:0] fast_drive_q;
    reg [7:0] white_repair_q;
    reg fast_q;
    reg valid_q,white_q,active_q;
    wire [15:0] drive;
    genvar i;
    generate for(i=0;i<8;i=i+1) begin: pixels
        wire [7:0] transition=fdma_rdata[8*i+:8];
        gc16_lut_es120mc1 rom (
            .clk(clk),.phase(lut_phase[4:0]),
            .transition({transition[7:4],repairing?4'hf:transition[3:0]}),
            .drive(lut_drive[2*i+:2])
        );
        assign drive[2*i+:2]=fast_q?fast_drive_q[2*i+:2]:
                             white_repair_q[i]?2'b10:!enable_q[i]?2'b00:
                             white_q?2'b10:active_q?lut_drive[2*i+:2]:2'b00;
        always @(posedge clk) if(accepted) begin
            enable_q[i]<=row_recovery ? repairing : transition[7:4]!=transition[3:0];
            // EPDiy MODE_DU has five identical phases. Only changed endpoint
            // targets are driven; an unchanged native gray keeps its charge.
            fast_drive_q[2*i+:2]<=(row_phase>=1 && row_phase<=5 &&
                transition[7:4]!=transition[3:0]) ?
                (transition[7:4]==0 ? 2'b01 : transition[7:4]==15 ? 2'b10 : 2'b00) : 2'b00;
            // Restore white in scrolled tiles without a black/white reset of
            // the entire tile. Midtones use their actual previous state in GC16.
            white_repair_q[i]<=HYBRID_REFRESH && row_refine && in_band && recovery_dirty &&
                transition==8'hff && row_phase>=1 && row_phase<=5;
        end
    end endgenerate
    reg [1:0] pack_count;
    reg [47:0] pack_low;
    wire pack_write=valid_q && pack_count==3;
    xpm_fifo_rdata_buf #(.FDMA_WID(64),.EPD_H(EPD_H)) drive_fifo (
        .rst_n(rst_n),.wr_clk(clk),.rd_clk(epd_clk),
        .din({drive,pack_low}),.wr_en(pack_write),.rd_en(fifo_ren),
        .dout(fifo_out),.full(fifo_full),.empty(fifo_empty)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;pending_rows<=0;row<=0;active_row<=0;word_count<=0;fdma_raddr<=0;
            row_phase<=0;row_recovery<=0;valid_q<=0;white_q<=0;active_q<=0;
            row_fast<=0;row_refine<=0;row_refine_y<=0;fast_q<=0;
            pack_count<=0;pack_low<=0;
        end else begin
            // DDR may still be finishing a previous row when the next line
            // pulse arrives. Queue pulses so a brief stall cannot shift rows.
            case({fdma_rflag,launch_row})
                2'b10: pending_rows<=pending_rows+1'b1;
                2'b01: pending_rows<=pending_rows-1'b1;
                default: pending_rows<=pending_rows;
            endcase
            valid_q<=accepted;
            if(accepted) begin
                fast_q<=row_fast || (row_refine && !in_band);
                white_q<=prefix && row_phase<=10;
                active_q<=active_phase;
                word_count<=word_count+1'b1;
            end
            if(valid_q) begin
                if(pack_count<3) pack_low[16*pack_count+:16]<=drive;
                pack_count<=pack_count+1'b1;
            end
            case(state)
                IDLE: if(launch_row) begin
                    fdma_raddr<=buf_addr+row*MAX_H;active_row<=row;
                    row<=(row==EPD_V-1)?0:row+1'b1;
                    row_phase<=phase_sync;row_recovery<=local_recovery;
                    row_fast<=HYBRID_REFRESH && fast_update;
                    row_refine<=HYBRID_REFRESH && refine_update;row_refine_y<=refine_y;
                    word_count<=0;state<=REQUEST;
                end
                REQUEST: if(fdma_rbusy) state<=TRANSFER;
                TRANSFER: if(!fdma_rbusy) state<=IDLE;
            endcase
        end
    end
endmodule
