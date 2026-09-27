// Input -> per-pixel waveform progress -> three-field drive packets.
// State and drive buffers commit only after both DDR writers finish. The
// display address is separately latched, so capture never changes a live scan.
module frame_stream_es120mc1 #(
    parameter FRAME_H=2560, FRAME_V=1600,
    parameter STATE0=32'h0D000000, STATE1=32'h0D800000,
    parameter DATA0=32'h0E800000, DATA1=32'h0EC00000,
    parameter USE_NATIVE_GC16=1
)(
    input wire clk,rst_n,pix_clk,epd_clk,epd_rst_n,
    input wire capture_start,display_start,clear_start,video_mode,refine,text_mode,
    input wire gray_vs,gray_de,
    input wire [7:0] gray_data,
    input wire [3:0] gray_source,
    output reg capture_done,clear_done,
    output reg capture_busy,
    output reg [22:0] changed_pixels,drive_pixels,pending_pixels,
    output wire capture_fault,dma_idle,
    input wire [7:0] phase,
    input wire row_request,fifo_pop,
    output wire [63:0] fifo_data,
    output wire CLK_50M,GPIO_O
);
    localparam GROUPS=FRAME_H/8,STATE_WORDS=FRAME_H/4,PLANE_WORDS=FRAME_H/32;
    localparam IDLE=0,REQUEST=1,TRANSFER=2;
    wire [31:0] wa[0:2],ra[0:2];
    wire [63:0] wd[0:2],rd[0:2];
    wire [15:0] ws[0:2],rs[0:2];
    wire [2:0] wq,wb,wr,wv,rq,rb,rr,rv;
    assign dma_idle=!(|wq || |wb || |rq || |rb);
    assign wa[1]=0;assign wd[1]=0;assign ws[1]=0;assign wq[1]=0;assign wr[1]=0;
    assign ra[1]=0;assign rs[1]=0;assign rq[1]=0;assign rr[1]=0;

    reg write_bank;
    reg [31:0] state_read_base,state_write_base,drive_write_base;
    reg [31:0] committed_drive,display_base;
    reg video_q,refine_q,text_q;
    wire pix_reset_n;
    xpm_cdc_async_rst_n pix_reset(.src_arst_n(rst_n && !clear_start),
        .dest_clk(pix_clk),.dest_arst_n(pix_reset_n));
    wire pix_start;
    xpm_cdc_pulse #(.DEST_SYNC_FF(3),.REG_OUTPUT(1),.RST_USED(1)) capture_cdc (
        .src_clk(clk),.src_rst(!rst_n),.src_pulse(capture_start),
        .dest_clk(pix_clk),.dest_rst(!pix_reset_n),.dest_pulse(pix_start));
    reg vs_d,de_d,armed,accept_pixels,pix_fault;
    reg [11:0] pix_x,pix_y;
    wire source_full,source_empty,source_wreset,source_rreset;
    wire [95:0] source_data;
    wire [63:0] source_gray_data;
    wire [31:0] source_levels;
    wire consume;
    wire pixel_write=accept_pixels && gray_de && !source_wreset;
    always @(posedge pix_clk or negedge pix_reset_n) begin
        if(!pix_reset_n) begin
            vs_d<=0;de_d<=0;armed<=0;accept_pixels<=0;pix_x<=0;pix_y<=0;pix_fault<=0;
        end else begin
            vs_d<=gray_vs;de_d<=gray_de;
            if(pix_start) begin armed<=1;pix_fault<=0;pix_x<=0;pix_y<=0;end
            if(armed && gray_vs && !vs_d) begin armed<=0;accept_pixels<=1;end
            if(pixel_write) begin
                if(source_full || pix_x>=FRAME_H) pix_fault<=1;
                pix_x<=pix_x+1'b1;
            end
            if(accept_pixels && de_d && !gray_de) begin
                if(pix_x!=FRAME_H) pix_fault<=1;
                pix_x<=0;
                if(pix_y==FRAME_V-1) accept_pixels<=0;
                else pix_y<=pix_y+1'b1;
            end
        end
    end
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0)) fault_cdc (
        .src_clk(pix_clk),.src_in(pix_fault),.dest_clk(clk),.dest_out(capture_fault));
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(16384),
        .WRITE_DATA_WIDTH(12),.READ_DATA_WIDTH(96),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(3),.USE_ADV_FEATURES("0000"),
        .WR_DATA_COUNT_WIDTH(1),.RD_DATA_COUNT_WIDTH(1)) input_fifo (
        .rst(!pix_reset_n),.wr_clk(pix_clk),.rd_clk(clk),.din({gray_source,gray_data}),
        .wr_en(pixel_write),.rd_en(consume),.dout(source_data),.full(source_full),.empty(source_empty),
        .wr_rst_busy(source_wreset),.rd_rst_busy(source_rreset),.sleep(1'b0),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0));

    genvar source_lane;
    generate for(source_lane=0;source_lane<8;source_lane=source_lane+1) begin: source_unpack
        assign source_gray_data[source_lane*8+:8]=source_data[source_lane*12+:8];
        assign source_levels[source_lane*4+:4]=source_data[source_lane*12+8+:4];
    end endgenerate

    // Read ahead by whole rows. FDMA responses are strobes, not an AXI
    // ready/valid pair: reserve space before requesting the entire burst.
    reg [1:0] read_state;
    reg [11:0] read_row;
    reg [31:0] read_address;
    wire state_full,state_empty,state_wreset,state_rreset;
    wire [127:0] state_data;
    wire [11:0] state_words;
    wire fifo_reset=!rst_n || clear_start;
    xpm_fifo_sync #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(2048),
        .WRITE_DATA_WIDTH(64),.READ_DATA_WIDTH(128),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.USE_ADV_FEATURES("0004"),
        .WR_DATA_COUNT_WIDTH(12),.RD_DATA_COUNT_WIDTH(1)) state_input_fifo (
        .rst(fifo_reset),.wr_clk(clk),.din(rd[0]),.wr_en(rv[0]),.rd_en(consume),
        .dout(state_data),.full(state_full),.empty(state_empty),.wr_data_count(state_words),
        .wr_rst_busy(state_wreset),.rd_rst_busy(state_rreset),.sleep(1'b0),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0));
    assign ra[0]=read_address;assign rs[0]=STATE_WORDS;
    assign rq[0]=read_state==REQUEST;assign rr[0]=1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin read_state<=IDLE;read_row<=0;read_address<=0;end
        else if(clear_start || capture_start) begin read_state<=IDLE;read_row<=0;end
        else case(read_state)
            IDLE: if(capture_busy && read_row<FRAME_V && !state_wreset &&
                     state_words<2048-STATE_WORDS-16) begin
                read_address<=state_read_base+read_row*(FRAME_H*2);read_state<=REQUEST;
            end
            REQUEST: if(rb[0]) read_state<=TRANSFER;
            TRANSFER: if(!rb[0]) begin read_row<=read_row+1'b1;read_state<=IDLE;end
        endcase
    end

    wire [127:0] next_history;
    wire [63:0] packet_drives;
    wire packet_valid,drive_full,next_full,next_empty;
    wire [2:0] plane_full,plane_empty,plane_wr_reset,plane_rd_reset;
    wire next_wr_reset,next_rd_reset;
    wire [10:0] plane_groups[0:2];
    wire [10:0] next_groups;
    wire [63:0] plane_words[0:2];
    reg [1:0] write_plane;
    wire [3:0] word_changes,word_drives,word_pending;
    reg [11:0] input_row,input_group,output_row,output_group;
    assign consume=capture_busy && input_row<FRAME_V && !capture_fault &&
        !source_empty && !source_rreset && !state_empty && !state_rreset &&
        !(|plane_wr_reset) && !next_wr_reset &&
        plane_groups[0]<1008 && plane_groups[1]<1008 && plane_groups[2]<1008 && next_groups<1008;
    pixel_packet_es120mc1 #(.ENABLE_NATIVE_GC16(USE_NATIVE_GC16)) pipeline(
        .clk(clk),.rst_n(rst_n && !clear_start),.valid(consume),
        .video_mode(video_q),.refine(refine_q),.text_mode(text_q),
        .pixels(source_gray_data),.source_levels(source_levels),.history(state_data),
        .out_valid(packet_valid),.drives(packet_drives),.next_history(next_history),
        .changed_count(word_changes),.drive_count(word_drives),.pending_count(word_pending));
    assign drive_full=|plane_full;
    assign wd[2]=plane_words[write_plane];
    genvar plane,lane;
    generate for(plane=0;plane<3;plane=plane+1) begin: planes
        wire [15:0] codes;
        for(lane=0;lane<8;lane=lane+1) begin: pixels
            assign codes[lane*2+:2]=packet_drives[lane*8+plane*2+:2];
        end
        xpm_fifo_sync #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(1024),
            .WRITE_DATA_WIDTH(16),.READ_DATA_WIDTH(64),.READ_MODE("fwft"),
            .FIFO_READ_LATENCY(0),.USE_ADV_FEATURES("0004"),
            .WR_DATA_COUNT_WIDTH(11),.RD_DATA_COUNT_WIDTH(1)) drive_output_fifo (
            .rst(fifo_reset),.wr_clk(clk),.din(codes),.wr_en(packet_valid),.rd_en(wv[2] && write_plane==plane),
            .dout(plane_words[plane]),.full(plane_full[plane]),.empty(plane_empty[plane]),
            .wr_data_count(plane_groups[plane]),.wr_rst_busy(plane_wr_reset[plane]),
            .rd_rst_busy(plane_rd_reset[plane]),.sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0));
    end endgenerate
    wire [63:0] next_state_word;
    reg clearing;
    xpm_fifo_sync #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(1024),
        .WRITE_DATA_WIDTH(128),.READ_DATA_WIDTH(64),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.USE_ADV_FEATURES("0004"),
        .WR_DATA_COUNT_WIDTH(11),.RD_DATA_COUNT_WIDTH(1)) state_output_fifo (
        .rst(fifo_reset),.wr_clk(clk),.din(next_history),.wr_en(packet_valid),
        .rd_en(wv[0] && !clearing),.dout(next_state_word),.full(next_full),.empty(next_empty),
        .wr_data_count(next_groups),.wr_rst_busy(next_wr_reset),.rd_rst_busy(next_rd_reset),
        .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0));
    reg [1:0] state_write_state,drive_write_state;
    reg [11:0] state_row,drive_row,clear_row;
    reg clear_bank;
    reg [31:0] state_address,drive_address;
    assign wa[0]=state_address;assign ws[0]=STATE_WORDS;
    assign wd[0]=clearing ? {4{16'h01ef}} : next_state_word;
    assign wq[0]=state_write_state==REQUEST;
    assign wr[0]=clearing || (!next_empty && !next_rd_reset);
    assign wa[2]=drive_address;assign ws[2]=PLANE_WORDS;
    assign wq[2]=drive_write_state==REQUEST;
    assign wr[2]=!plane_empty[write_plane] && !plane_rd_reset[write_plane];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state_write_state<=IDLE;drive_write_state<=IDLE;state_row<=0;drive_row<=0;
            clear_row<=0;clear_bank<=0;clearing<=0;clear_done<=0;state_address<=0;drive_address<=0;write_plane<=0;
        end else begin
            clear_done<=0;
            if(clear_start) begin clearing<=1;clear_row<=0;clear_bank<=0;end
            if(capture_start) begin state_row<=0;drive_row<=0;write_plane<=0;end
            case(state_write_state)
                IDLE: if(clearing || (capture_busy && state_row<output_row)) begin
                    state_address<=clearing ? ((clear_bank ? STATE1 : STATE0)+clear_row*(FRAME_H*2)) :
                        state_write_base+state_row*(FRAME_H*2);
                    state_write_state<=REQUEST;
                end
                REQUEST: if(wb[0]) state_write_state<=TRANSFER;
                TRANSFER: if(!wb[0]) begin
                    state_write_state<=IDLE;
                    if(clearing) begin
                        if(clear_row==FRAME_V-1) begin
                            clear_row<=0;clear_bank<=1;
                            if(clear_bank) begin clearing<=0;clear_done<=1;end
                        end else clear_row<=clear_row+1'b1;
                    end else state_row<=state_row+1'b1;
                end
            endcase
            case(drive_write_state)
                IDLE: if(capture_busy && drive_row<output_row) begin
                    drive_address<=drive_write_base+drive_row*(FRAME_H*3/4)+write_plane*(FRAME_H/4);
                    drive_write_state<=REQUEST;
                end
                REQUEST: if(wb[2]) drive_write_state<=TRANSFER;
                TRANSFER: if(!wb[2]) begin
                    drive_write_state<=IDLE;
                    if(write_plane==2) begin write_plane<=0;drive_row<=drive_row+1'b1;end
                    else write_plane<=write_plane+1'b1;
                end
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            capture_busy<=0;capture_done<=0;write_bank<=0;
            state_read_base<=STATE1;state_write_base<=STATE0;drive_write_base<=DATA0;
            committed_drive<=DATA0;display_base<=DATA0;video_q<=0;refine_q<=0;text_q<=0;
            input_row<=0;input_group<=0;output_row<=0;output_group<=0;
            changed_pixels<=0;drive_pixels<=0;pending_pixels<=0;
        end else begin
            capture_done<=0;
            if(display_start) display_base<=committed_drive;
            if(clear_start) begin write_bank<=0;capture_busy<=0;end
            if(capture_start) begin
                capture_busy<=1;state_read_base<=write_bank ? STATE0 : STATE1;
                state_write_base<=write_bank ? STATE1 : STATE0;
                drive_write_base<=write_bank ? DATA1 : DATA0;
                video_q<=video_mode;refine_q<=refine;text_q<=text_mode;
                input_row<=0;input_group<=0;output_row<=0;output_group<=0;
                changed_pixels<=0;drive_pixels<=0;pending_pixels<=0;
            end
            if(consume) begin
                if(input_group==GROUPS-1) begin input_group<=0;input_row<=input_row+1'b1;end
                else input_group<=input_group+1'b1;
            end
            if(packet_valid) begin
                changed_pixels<=changed_pixels+word_changes;
                drive_pixels<=drive_pixels+word_drives;pending_pixels<=pending_pixels+word_pending;
                if(output_group==GROUPS-1) begin output_group<=0;output_row<=output_row+1'b1;end
                else output_group<=output_group+1'b1;
            end
            if(capture_busy && state_row==FRAME_V && drive_row==FRAME_V && !capture_fault) begin
                capture_busy<=0;capture_done<=1;committed_drive<=drive_write_base;write_bank<=!write_bank;
            end
        end
    end
    wire row_pulse;
    sync_h2lck request_cdc(.in_clk(epd_clk),.out_clk(clk),.rst_n(epd_rst_n),
        .level_in(row_request),.pulse_out(row_pulse));
    wire output_full,output_empty;
    fdma_r_packet_es120mc1 #(.FRAME_H(FRAME_H),.FRAME_V(FRAME_V)) reader (
        .clk(clk),.rst_n(rst_n),.epd_clk(epd_clk),.fdma_rflag(row_pulse),.phase(phase),
        .buf_addr(display_base),
        .fdma_raddr(ra[2]),.fdma_rareq(rq[2]),.fdma_rbusy(rb[2]),.fdma_rdata(rd[2]),
        .fdma_rready(rr[2]),.fdma_rsize(rs[2]),.fdma_rvalid(rv[2]),
        .fifo_ren(fifo_pop),.fifo_out(fifo_data),.fifo_full(output_full),.fifo_empty(output_empty));
    wire [31:0] physical_wa[0:2],physical_ra[0:2];
    wire [15:0] physical_ws[0:2],physical_rs[0:2];
    wire [2:0] physical_wq,physical_rq,physical_wb,physical_rb;
    genvar port;
    generate for(port=0;port<3;port=port+1) begin: page_guards
        fdma_page_guard_es120mc1 write_guard(.clk(clk),.rst_n(rst_n),.request(wq[port]),
            .address(wa[port]),.size(ws[port]),.busy(wb[port]),.physical_request(physical_wq[port]),
            .physical_address(physical_wa[port]),.physical_size(physical_ws[port]),.physical_busy(physical_wb[port]));
        fdma_page_guard_es120mc1 read_guard(.clk(clk),.rst_n(rst_n),.request(rq[port]),
            .address(ra[port]),.size(rs[port]),.busy(rb[port]),.physical_request(physical_rq[port]),
            .physical_address(physical_ra[port]),.physical_size(physical_rs[port]),.physical_busy(physical_rb[port]));
    end endgenerate
    ps_system_wrapper ps_system (
        .clk(clk),.rst_n(rst_n),.CLK_50M(CLK_50M),.GPIO_O(GPIO_O),
        .texture_fdma_waddr(physical_wa[0]),.texture_fdma_wareq(physical_wq[0]),.texture_fdma_wbusy(physical_wb[0]),
        .texture_fdma_wdata(wd[0]),.texture_fdma_wready(wr[0]),.texture_fdma_wsize(physical_ws[0]),.texture_fdma_wvalid(wv[0]),
        .texture_fdma_raddr(physical_ra[0]),.texture_fdma_rareq(physical_rq[0]),.texture_fdma_rbusy(physical_rb[0]),
        .texture_fdma_rdata(rd[0]),.texture_fdma_rready(rr[0]),.texture_fdma_rsize(physical_rs[0]),.texture_fdma_rvalid(rv[0]),
        .gray_fdma_waddr(physical_wa[1]),.gray_fdma_wareq(physical_wq[1]),.gray_fdma_wbusy(physical_wb[1]),
        .gray_fdma_wdata(wd[1]),.gray_fdma_wready(wr[1]),.gray_fdma_wsize(physical_ws[1]),.gray_fdma_wvalid(wv[1]),
        .gray_fdma_raddr(physical_ra[1]),.gray_fdma_rareq(physical_rq[1]),.gray_fdma_rbusy(physical_rb[1]),
        .gray_fdma_rdata(rd[1]),.gray_fdma_rready(rr[1]),.gray_fdma_rsize(physical_rs[1]),.gray_fdma_rvalid(rv[1]),
        .data_fdma_waddr(physical_wa[2]),.data_fdma_wareq(physical_wq[2]),.data_fdma_wbusy(physical_wb[2]),
        .data_fdma_wdata(wd[2]),.data_fdma_wready(wr[2]),.data_fdma_wsize(physical_ws[2]),.data_fdma_wvalid(wv[2]),
        .data_fdma_raddr(physical_ra[2]),.data_fdma_rareq(physical_rq[2]),.data_fdma_rbusy(physical_rb[2]),
        .data_fdma_rdata(rd[2]),.data_fdma_rready(rr[2]),.data_fdma_rsize(physical_rs[2]),.data_fdma_rvalid(rv[2]));
endmodule
