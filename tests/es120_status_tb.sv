`timescale 1ns/1ps
module es120_status_tb;
    reg clk=0, rst_n=0, stripes=0;
    always #10 clk=~clk;
    wire de, hs, vs;
    wire [7:0] data;
    reg [1:0] status_mode=0, mode_notice=0;
    reg [15:0] hdmi_tmds_q7=0;
    reg hdmi_rate_valid=0;
    integer pixels=0, black=0, x=0, y=0, minx=9999, maxx=0, miny=9999, maxy=0;
    integer frame=0, file_text, file_stripes;
    status_source_es120mc1 dut(.clk(clk), .rst_n(rst_n), .stripes(stripes),
        .status_mode(status_mode), .hdmi_tmds_q7(hdmi_tmds_q7),
        .hdmi_rate_valid(hdmi_rate_valid), .mode_notice(mode_notice),
        .gray_de(de), .gray_hs(hs), .gray_vs(vs), .gray_data(data));
    initial begin
        file_text=$fopen("status.pbm","w"); $fwrite(file_text,"P1\n2560 1600\n");
        file_stripes=$fopen("stripes.pbm","w"); $fwrite(file_stripes,"P1\n2560 1600\n");
        #1000; rst_n=1;
        #200000000; $fatal(1,"status timeout");
    end
    always @(posedge clk) if(rst_n && de) begin
        x=pixels%2560; y=pixels/2560;
        if(frame==0) begin
            $fwrite(file_text,"%0d ",data==0);
            if(data==0) begin
                black=black+1;
                if(x<minx) minx=x; if(x>maxx) maxx=x;
                if(y<miny) miny=y; if(y>maxy) maxy=y;
            end
        end else begin
            $fwrite(file_stripes,"%0d ",data==0);
            if(data !== (((x/80)%2==0) ? 8'h00:8'hff))
                $fatal(1,"stripe mismatch x=%0d y=%0d",x,y);
        end
        pixels=pixels+1;
        if(pixels==2560*1600) begin
            if(frame==0) begin
                if(minx!=1068 || maxx!=1490 || miny!=772 || maxy!=826)
                    $fatal(1,"text bounds %0d,%0d to %0d,%0d",minx,miny,maxx,maxy);
                if(black != 126*8*8/4) $fatal(1,"text black pixel count %0d",black);
                $fclose(file_text);
                frame=1; pixels=0; stripes=1;
            end else begin
                $fclose(file_stripes);
                $display("PASS status: centered 75-percent-luminance text and continuous startup stripes correct");
                $finish;
            end
        end
    end
endmodule
