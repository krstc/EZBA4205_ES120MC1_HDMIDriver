// uiFDMA splits at 256 beats, but not at AXI's 4 KiB boundary. Keep the
// client's logical transaction busy while issuing page-bounded subrequests.
module fdma_page_guard_es120mc1 (
    input wire clk,rst_n,request,
    input wire [31:0] address,
    input wire [15:0] size,
    output wire busy,
    output wire physical_request,
    output reg [31:0] physical_address,
    output reg [15:0] physical_size,
    input wire physical_busy
);
    localparam IDLE=0,PREPARE=1,REQUEST=2,TRANSFER=3;
    reg [1:0] state;
    reg [15:0] remaining;
    wire [15:0] page_words=16'd512-{7'd0,physical_address[11:3]};
    assign busy=state!=IDLE;
    assign physical_request=state==REQUEST;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=IDLE;physical_address<=0;physical_size<=0;remaining<=0;end
        else case(state)
            IDLE: if(request && size!=0) begin
                physical_address<=address;remaining<=size;state<=PREPARE;
            end
            PREPARE: begin
                physical_size<=remaining<page_words ? remaining : page_words;
                state<=REQUEST;
            end
            REQUEST: if(physical_busy) state<=TRANSFER;
            TRANSFER: if(!physical_busy) begin
                if(remaining==physical_size) state<=IDLE;
                else begin
                    remaining<=remaining-physical_size;
                    physical_address<=physical_address+{13'd0,physical_size,3'd0};
                    state<=PREPARE;
                end
            end
        endcase
    end
endmodule
