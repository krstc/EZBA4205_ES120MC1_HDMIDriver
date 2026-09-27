`timescale 1ns/1ps
module es120_gc16_clear_tb;
    reg clk=0,rst=0,start=0,busy=0,valid=0;
    always #10 clk=~clk;
    wire req,ready,done;
    wire [31:0] addr;
    wire [63:0] data;
    wire [15:0] size;
    integer rows=0,word=0,total_words=0;
    reg [31:0] expected_base;
    fdma_clear #(.NATIVE_GC16(1),.MAX_H(2560),.MAX_V(1600),
        .GRAY_0_ADDR_MEM_OFFSET(32'hf500000),.GRAY_1_ADDR_MEM_OFFSET(32'hf900000),
        .DATA_0_ADDR_MEM_OFFSET(32'he800000),.DATA_1_ADDR_MEM_OFFSET(32'hec00000)) dut (
        .clk(clk),.rst_n(rst),.clr_flag(start),.fdma_waddr(addr),.fdma_wareq(req),
        .fdma_wbusy(busy),.fdma_wdata(data),.fdma_wready(ready),.fdma_wsize(size),
        .fdma_wvalid(valid),.wbusy(),.fflag(done));
    always @(posedge clk) if(valid) begin
        if(data!==64'hffffffffffffffff) $fatal(1,"native clear does not establish white-to-white");
        word=word+1;total_words=total_words+1;
    end
    always @(negedge clk) if(rst) begin
        valid=0;
        if(!busy && req) begin
            case(rows/1600)
                0:expected_base=32'hf500000;
                1:expected_base=32'hf900000;
                2:expected_base=32'he800000;
                3:expected_base=32'hec00000;
                default:$fatal(1,"extra clear region");
            endcase
            if(size!=320 || addr!=expected_base+(rows%1600)*2560) $fatal(1,"clear bounds/stride");
            busy=1;word=0;
        end else if(busy) begin
            if(word==320) begin busy=0;rows=rows+1;end
            else valid=ready;
        end
    end
    initial begin
        #100;rst=1;repeat(5) @(negedge clk);start=1;@(negedge clk);start=0;
        wait(done);
        if(rows!=6400 || total_words!=2048000) $fatal(1,"partial native buffer initialization");
        $display("PASS native clear: all four 4096000-byte buffers, exact bounds/stride, every byte white/white-to-white");
        $finish;
    end
    initial begin #60000000;$fatal(1,"native clear timeout");end
endmodule
