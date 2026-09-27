// Three FDMA frontends sharing bounded stalls. Read/write responses are
// transfer strobes, as in the actual uiFDMA IP (not AXI VALID signals).
module ps_system_wrapper (
    input wire clk,rst_n,output wire CLK_50M,GPIO_O,
    input wire [31:0] texture_fdma_waddr,gray_fdma_waddr,data_fdma_waddr,
    input wire texture_fdma_wareq,gray_fdma_wareq,data_fdma_wareq,
    output wire texture_fdma_wbusy,gray_fdma_wbusy,data_fdma_wbusy,
    input wire [63:0] texture_fdma_wdata,gray_fdma_wdata,data_fdma_wdata,
    input wire texture_fdma_wready,gray_fdma_wready,data_fdma_wready,
    input wire [15:0] texture_fdma_wsize,gray_fdma_wsize,data_fdma_wsize,
    output wire texture_fdma_wvalid,gray_fdma_wvalid,data_fdma_wvalid,
    input wire [31:0] texture_fdma_raddr,gray_fdma_raddr,data_fdma_raddr,
    input wire texture_fdma_rareq,gray_fdma_rareq,data_fdma_rareq,
    output wire texture_fdma_rbusy,gray_fdma_rbusy,data_fdma_rbusy,
    output wire [63:0] texture_fdma_rdata,gray_fdma_rdata,data_fdma_rdata,
    input wire texture_fdma_rready,gray_fdma_rready,data_fdma_rready,
    input wire [15:0] texture_fdma_rsize,gray_fdma_rsize,data_fdma_rsize,
    output wire texture_fdma_rvalid,gray_fdma_rvalid,data_fdma_rvalid
);
    reg [63:0] mem[0:3145727];
    function automatic integer index(input reg[31:0] a);
        if(a>=32'h0d000000 && a<32'h0e000000) index=(a-32'h0d000000)/8;
        else if(a>=32'h0e800000 && a<32'h0f000000) index=2097152+(a-32'h0e800000)/8;
        else begin $fatal(1,"DDR out of owned buffers: %h",a);index=0;end
    endfunction
    assign CLK_50M=clk;assign GPIO_O=0;
    wire [31:0] wa[0:2],ra[0:2];
    wire [63:0] wd[0:2];wire [15:0] ws[0:2],rs[0:2];
    wire [2:0] wq,rq,wr,rr;
    reg [2:0] wb=0,rb=0,wv=0,rv=0;
    reg [63:0] rd[0:2];
    reg [31:0] wbase[0:2],rbase[0:2];
    integer wc[0:2],rc[0:2],wn[0:2],rn[0:2],waitw[0:2],waitr[0:2],ticks=0;
    assign {wa[2],wa[1],wa[0]}={data_fdma_waddr,gray_fdma_waddr,texture_fdma_waddr};
    assign {ra[2],ra[1],ra[0]}={data_fdma_raddr,gray_fdma_raddr,texture_fdma_raddr};
    assign {wd[2],wd[1],wd[0]}={data_fdma_wdata,gray_fdma_wdata,texture_fdma_wdata};
    assign {ws[2],ws[1],ws[0]}={data_fdma_wsize,gray_fdma_wsize,texture_fdma_wsize};
    assign {rs[2],rs[1],rs[0]}={data_fdma_rsize,gray_fdma_rsize,texture_fdma_rsize};
    assign wq={data_fdma_wareq,gray_fdma_wareq,texture_fdma_wareq};
    assign rq={data_fdma_rareq,gray_fdma_rareq,texture_fdma_rareq};
    assign wr={data_fdma_wready,gray_fdma_wready,texture_fdma_wready};
    assign rr={data_fdma_rready,gray_fdma_rready,texture_fdma_rready};
    assign {data_fdma_wbusy,gray_fdma_wbusy,texture_fdma_wbusy}=wb;
    assign {data_fdma_wvalid,gray_fdma_wvalid,texture_fdma_wvalid}=wv;
    assign {data_fdma_rbusy,gray_fdma_rbusy,texture_fdma_rbusy}=rb;
    assign {data_fdma_rvalid,gray_fdma_rvalid,texture_fdma_rvalid}=rv;
    assign {data_fdma_rdata,gray_fdma_rdata,texture_fdma_rdata}={rd[2],rd[1],rd[0]};
    always @(posedge clk) if(rst_n) for(integer p=0;p<3;p++) begin
        if(wv[p]) begin mem[index(wbase[p])+wc[p]]=wd[p];wc[p]++;end
        if(rv[p]) rc[p]++;
    end
    always @(negedge clk) if(!rst_n) begin wb=0;rb=0;wv=0;rv=0;end else begin
        ticks++;wv=0;rv=0;
        for(integer p=0;p<3;p++) begin
            if(!wb[p] && wq[p]) begin
                if(wa[p][2:0]!=0 || wa[p][11:0]+ws[p]*8>4096) $fatal(1,"AXI write crosses 4KiB: %h %0d",wa[p],ws[p]);
                wb[p]=1;wbase[p]=wa[p];wc[p]=0;wn[p]=ws[p];waitw[p]=9+p;
            end else if(wb[p]) begin
                if(wc[p]==wn[p]) wb[p]=0;
                else if(waitw[p]) waitw[p]--;
                else wv[p]=wr[p] && ticks%11!=0;
            end
            if(!rb[p] && rq[p]) begin
                if(ra[p][2:0]!=0 || ra[p][11:0]+rs[p]*8>4096) $fatal(1,"AXI read crosses 4KiB: %h %0d",ra[p],rs[p]);
                rb[p]=1;rbase[p]=ra[p];rc[p]=0;rn[p]=rs[p];waitr[p]=13+2*p;
            end else if(rb[p]) begin
                if(rc[p]==rn[p]) rb[p]=0;
                else if(waitr[p]) waitr[p]--;
                else if(rr[p] && ticks%13!=0) begin rv[p]=1;rd[p]=mem[index(rbase[p])+rc[p]];end
            end
        end
    end
endmodule
