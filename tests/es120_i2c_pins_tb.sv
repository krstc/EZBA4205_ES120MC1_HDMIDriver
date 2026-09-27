`timescale 1ns/1ps
module es120_i2c_pins_tb;
    reg clk=0,rst=0,en=0,mode=0;
    reg [31:0] wr_data=0;
    reg [7:0] wr_cnt=0,rd_cnt=0;
    wire [7:0] rd_data;
    wire scl,busy,ack_error;
    tri1 sda;
    reg slave_low=0;
    assign sda=slave_low ? 1'b0 : 1'bz;
    always #10 clk=~clk;
    i2c_top #(.WMEN_LEN(4),.RMEN_LEN(1),.SCL_FREQ(200)) dut(
        .clk_i(clk),.rst_n(rst),.iic_scl(scl),.iic_sda(sda),
        .wr_data(wr_data),.wr_cnt(wr_cnt),.rd_data(rd_data),.rd_cnt(rd_cnt),
        .iic_en(en),.iic_mode(mode),.iic_busy(busy),.iic_ack_error(ack_error));

    // Slave responds exclusively to physical SCL/SDA, not internal DUT state.
    reg active=0,reading=0,selected=0;
    reg [7:0] shift=0,mem[0:255],pointer=0;
    integer bit_number=0,byte_number=0,starts=0;
    always @(negedge sda) if(scl===1'b1) begin
        active=1; reading=0; selected=0; bit_number=0; byte_number=0;
        shift=0; starts=starts+1;
    end
    always @(posedge sda) if(scl===1'b1) active=0;
    always @(posedge scl) if(active) begin
        if(bit_number<8) begin
            if(!reading) shift={shift[6:0],sda};
            bit_number=bit_number+1;
        end else begin
            if(byte_number==0) begin
                selected=(shift[7:1]==7'h36);
                reading=selected && shift[0];
            end else if(!reading && selected) begin
                if(byte_number==1) pointer=shift;
                else begin mem[pointer]=shift; pointer=pointer+1'b1; end
            end else if(reading) begin
                pointer=pointer+1'b1;
                if(sda===1'b1) active=0;
            end
            bit_number=0; byte_number=byte_number+1;
        end
    end
    always @(negedge scl) begin
        if(!active) slave_low=0;
        else if(bit_number==8)
            slave_low=!reading && (byte_number==0 ? shift[7:1]==7'h36 : selected);
        else if(reading) slave_low=!mem[pointer][7-bit_number];
        else slave_low=0;
    end
    task transaction(input [31:0] data,input [7:0] wc,input [7:0] rc,input read_mode);
        begin
            @(negedge clk); wr_data=data; wr_cnt=wc; rd_cnt=rc; mode=read_mode; en=1;
            wait(busy); @(negedge clk); en=0;
            wait(!busy); @(negedge clk);
        end
    endtask
    initial begin
        #200; rst=1;
        for(integer i=0;i<256;i=i+1) begin
            transaction({8'd0,8'(i^8'ha5),8'(i),8'h6c},3,0,0);
            if(ack_error || mem[i] !== 8'(i^8'ha5))
                $fatal(1,"write at %0d: ack=%b data=%h",i,ack_error,mem[i]);
        end
        for(integer i=0;i<256;i=i+1) begin
            transaction({16'd0,8'(i),8'h6c},2,1,1);
            if(ack_error || rd_data !== 8'(i^8'ha5))
                $fatal(1,"random read at %0d: ack=%b data=%h expected=%h",i,ack_error,rd_data,8'(i^8'ha5));
        end
        transaction(32'h0000006e,2,1,1);
        if(!ack_error) $fatal(1,"missing slave NACK not reported");
        $display("PASS physical I2C: all 256 byte values written/read, random-read addressing, missing-device NACK");
        $finish;
    end
    initial begin #200000000; $fatal(1,"I2C pins timeout"); end
endmodule
