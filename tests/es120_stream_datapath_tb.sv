`timescale 1ns/1ps
module es120_stream_datapath_tb;
    localparam H=2560,V=1600,N=H*V;
    reg clk=0,pix=0,epd=0,rst=0,cap=0,clear=0,ds=0;
    reg vs=0,de=0;
    reg [7:0] gray=0;
    always #10 clk=~clk;
    always #4.467 pix=~pix;
    always #11.346154 epd=~epd;
    wire cd,cld,req,pop,dd,idle,fault,stl;
    wire [7:0] phase;
    wire [63:0] fifo;
    wire [15:0] pins;
    wire [22:0] changed,driven,pending;
    integer position[0:N-1];
    reg [7:0] expected[0:1][0:N-1];
    integer capture_index=0,show_index=0,samples=0,fields=0;
    time capture_times[0:3];
    reg checking=0;
    function automatic bit desired(input integer f,y,x);
        desired=((x/17+y/13+(f>=2 ? 1:0))%2)!=0;
    endfunction
    frame_stream_es120mc1 #(.USE_NATIVE_GC16(0)) dut(.clk(clk),.rst_n(rst),.pix_clk(pix),.epd_clk(epd),.epd_rst_n(rst),
        .capture_start(cap),.display_start(ds),.clear_start(clear),.video_mode(1'b1),.refine(1'b0),.text_mode(1'b0),
        .gray_vs(vs),.gray_de(de),.gray_data(gray),.gray_source(gray[7:4]),.capture_done(cd),.clear_done(cld),.capture_busy(),
        .changed_pixels(changed),.drive_pixels(driven),.pending_pixels(pending),.capture_fault(fault),
        .dma_idle(idle),.phase(phase),.row_request(req),.fifo_pop(pop),.fifo_data(fifo),.CLK_50M(),.GPIO_O());
    display_mgr_es120mc1 #(.EPD_WID(16),.EPD_H(1280),.EPD_V(V),.NATIVE_GC16(0),.STREAMING_REFRESH(1),.tFdly(0)) panel (
        .clk(clk),.epd_clk(epd),.rst_n(rst),.epd_rst_n(rst),.s_flag(ds),.init_mode(1'b0),.white_only(1'b0),
        .fast_update(1'b1),.local_recovery(1'b0),.period_cnt(phase),.d_busy(),.d_fflag(dd),.image_fflag(),
        .r_flag(req),.fifo_ren(pop),.din(fifo),.EPD_SKV(),.EPD_SPV(),.EPD_XCL(),.EPD_XLE(),.EPD_XSTL(stl),.EPD_DOUT(pins));
    task model(input integer f);
        bit target;
        integer code;
        for(integer p=0;p<N;p++) begin
            target=desired(f,p/H,p%H);expected[f%2][p]=0;
            for(integer s=0;s<3;s++) begin
                code=0;
                if(target && position[p]<5) begin position[p]++;code=2;end
                if(!target && position[p]>0) begin position[p]--;code=1;end
                expected[f%2][p][s*2+:2]=2'(code);
            end
        end
    endtask
    task source_frame(input integer f);
        repeat(50) @(negedge pix);
        vs=1;repeat(32) @(negedge pix);vs=0;
        repeat(2720*40) @(negedge pix);
        for(integer y=0;y<V;y++) begin
            for(integer x=0;x<H;x++) begin
                de=1;gray=desired(f,y,x)?8'hff:8'h00;@(negedge pix);
            end
            de=0;repeat(160) @(negedge pix);
        end
    endtask
    task capture(input integer f);
        model(f);
        @(negedge clk);cap=1;@(negedge clk);cap=0;
        wait(cd);capture_times[f]=$time;
        repeat(8) @(negedge clk);
        for(integer y=0;y<V;y++) for(integer phase=0;phase<3;phase++) for(integer x=0;x<H;x++) begin
            if(dut.ps_system.mem[dut.ps_system.index(dut.committed_drive)+(y*3+phase)*(H/32)+x/32][(x%32)*2+:2]!==expected[f%2][y*H+x][phase*2+:2])
                $fatal(1,"DDR packet mismatch frame=%0d pixel=%0d phase=%0d",f,y*H+x,phase);
        end
        $display("PROGRESS captured %0d at %0t",f,$time);
    endtask
    task display_packet(input integer f);
        show_index=f;samples=0;fields=0;checking=1;
        @(negedge clk);ds=1;@(negedge clk);ds=0;
        wait(dd);@(negedge epd);checking=0;
        if(samples!=N/8*3) $fatal(1,"not exactly three full fields: %0d",samples);
        $display("PROGRESS displayed %0d at %0t",f,$time);
    endtask
    always @(posedge clk) if(rst) begin
        if(fault) $fatal(1,"capture overflow/geometry fault");
        if(dut.rv[0] && dut.state_full) $fatal(1,"state read overflow");
        if(dut.packet_valid && (dut.drive_full || dut.next_full)) $fatal(1,"output overflow");
    end
    always @(posedge epd) if(rst && checking) begin
        if(pop && dut.output_empty) $fatal(1,"panel FIFO underrun at %0t phase=%0d samples=%0d",$time,phase,samples);
        if(!stl) begin
            for(integer lane=0;lane<8;lane++)
                if(pins[14-lane*2+:2]!==expected[show_index%2][(samples%(N/8))*8+lane][(phase-1)*2+:2])
                    $fatal(1,"pin data mismatch frame=%0d phase=%0d pixel=%0d",show_index,phase,(samples%(N/8))*8+lane);
            samples++;
        end
    end
    initial begin
        for(integer p=0;p<N;p++) position[p]=5;
        #1000;rst=1;repeat(100) @(negedge clk);
        clear=1;@(negedge clk);clear=0;wait(cld);repeat(100) @(negedge clk);
        for(integer bank=0;bank<2;bank++) for(integer w=0;w<N/4;w++)
            if(dut.ps_system.mem[dut.ps_system.index(bank ? 32'h0d800000 : 32'h0d000000)+w]!=={4{16'h01ef}})
                $fatal(1,"state clear not white");
        $display("PROGRESS DDR white rebase complete at %0t",$time);
        fork
            begin
                // The source runs at its own fixed 2720 x 1646 cadence,
                // independent of requests or DDR/display completion.
                for(integer f=0;f<4;f++) begin
                    source_frame(f);
                    repeat(2720*6-82) @(negedge pix);
                end
            end
            begin
                capture(0);
                for(integer f=0;f<3;f++) begin
                    fork display_packet(f);capture(f+1);join
                end
                display_packet(3);
            end
        join
        for(integer f=1;f<4;f++)
            if(capture_times[f]-capture_times[f-1]>41000000)
                $fatal(1,"capture cadence below 24 Hz: %0t",capture_times[f]-capture_times[f-1]);
        $display("PASS streaming 2560x1600 full-frame DDR, free-running 25 Hz HDMI, overlapping capture/display, 3 fields, all pin codes");
        $finish;
    end
    initial begin #400000000;$fatal(1,"full-frame timeout");end
endmodule
