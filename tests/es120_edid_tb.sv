`timescale 1ns/1ps
module es120_edid_tb;
    reg [8:0] index;
    wire [39:0] transaction;
    reg [7:0] edid[0:127];
    integer sum=0,ha,hb,va,vb,hfront,hsync,pixelclock,edid_file;
    config_reg_es120mc1 dut(.REG_INDEX(index),.REG_DATA(transaction),.REG_SIZE());
    adv7611_iic_manager #(.EDID_DTD_CLOCK_LOW(8'hb9),.EDID_CHECKSUM(8'h5c),.HPA_VERIFY_VALUE(8'ha2))
        receiver(.clk(1'b0),.rst_n(1'b0),.REG_DATA(40'd0),.REG_SIZE(9'd0));
    initial begin
        for(integer i=0;i<128;i=i+1) begin
            index=50+i; #10;
            if(transaction[39:32]!=3 || transaction[31:24]!=8'h6c || transaction[23:16]!=i)
                $fatal(1,"EDID transaction packing");
            edid[i]=transaction[15:8]; sum=sum+transaction[15:8];
        end
        if(sum%256!=0) $fatal(1,"EDID checksum %0d",sum%256);
        if(edid[35] || edid[36] || edid[37] || edid[126]) $fatal(1,"unwanted established/extension timings");
        for(integer i=38;i<54;i=i+1)
            if(edid[i]!=1) $fatal(1,"unwanted standard timing");
        if(edid[100]!=1 || edid[101]!=10) $fatal(1,"range-only descriptor invalid");
        if(edid[10]!=8'h33 || edid[11]!=1 || edid[20]!=8'ha2) $fatal(1,"25Hz identity / digital input");
        if(receiver.verify_value(4)!=8'ha2) $fatal(1,"incorrect HPA readback expectation");
        if(receiver.verify_value(1)!=edid[54] || receiver.verify_value(2)!=edid[127])
            $fatal(1,"receiver verification constants differ from programmed EDID");
        pixelclock=(edid[55]*256+edid[54])*10000;
        ha=edid[56]+(edid[58]>>4)*256; hb=edid[57]+(edid[58]&15)*256;
        va=edid[59]+(edid[61]>>4)*256; vb=edid[60]+(edid[61]&15)*256;
        hfront=edid[62]+((edid[65]>>6)&3)*256;
        hsync=edid[63]+((edid[65]>>4)&3)*256;
        if(ha!=2560 || va!=1600 || hb!=160 || vb!=46 || hfront!=48 ||
           hsync!=32 || pixelclock!=111930000)
            $fatal(1,"native detailed timing incorrect");
        if(1.0*pixelclock/(ha+hb)/(va+vb)<24.99 || 1.0*pixelclock/(ha+hb)/(va+vb)>25.01)
            $fatal(1,"detailed timing is not 25Hz");
        if(hfront+hsync>=hb) $fatal(1,"nonpositive horizontal back porch");
        edid_file=$fopen("edid.bin","wb");
        if(!edid_file) $fatal(1,"cannot write EDID fixture");
        for(integer i=0;i<128;i=i+1) $fwrite(edid_file,"%c",edid[i]);
        $fclose(edid_file);
        $display("PASS EDID: checksum, I2C bytes, native 2560x1600 / 111.93MHz / 25Hz, H 48+32+80, V blanking 46");
        $finish;
    end
endmodule
