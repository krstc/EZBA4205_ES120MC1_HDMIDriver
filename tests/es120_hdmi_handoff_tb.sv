`timescale 1ns/1ps
// Exercise the production receiver poller, TOP gate and source mux together.
// I2C transactions, parallel-video qualification and PS/DDR/panel completion
// are modeled. Do not force the receiver's decoded lock/frequency outputs.
module es120_hdmi_handoff_tb;
    reg rst=0, locked=0, frequency_valid=0, geometry=0, rate=0;
    reg [15:0] q7=0;
    reg pix=0;
    always #4.324 pix=~pix;
    reg display_complete=0;
    integer display_age=0, hdmi_captures=0, local_captures=0;
    reg [8:0] index=0;
    wire [39:0] transaction;
    reg [7:0] edid[0:127];
    reg [7:0] receiver_edid[0:127];
    reg mock_busy=0, mock_error=0;
    reg [7:0] mock_data=0, device_address, register_address;
    integer diagnostic_reads=0;
    integer pixel_clock_khz;
    config_reg_es120mc1 table_dut(.REG_INDEX(index),.REG_DATA(transaction),.REG_SIZE());
    // Scale only the long control timers; the transport test uses real clocks.
    eink_controller_es120mc1 #(.SYS_CLK_FREQ(1),.SCL_FREQ(10)) dut(.pix_clk(pix),.hs_i(1'b1),.vs_i(1'b1),
        .de_i(1'b0),.gray_i(8'ha5),.manual_refresh_n(1'b1),.mode_key_n(1'b1));
    defparam dut.system_manager.POWER_SETTLE_CYCLES=20;
    defparam dut.system_manager.BOOT_CYCLE_MIN_CYCLES=100;
    defparam dut.adv7611_manager.STARTUP_DELAY_CYCLES=10;
    defparam dut.adv7611_manager.I2C_RESET_DELAY_CYCLES=10;
    defparam dut.adv7611_manager.EDID_DISABLE_DELAY_CYCLES=10;
    defparam dut.adv7611_manager.HPD_LOW_HOLD_CYCLES=10;
    defparam dut.adv7611_manager.HPD_HIGH_HOLD_CYCLES=10;
    defparam dut.adv7611_manager.DETECT_PERIOD_CYCLES=200;
    defparam dut.system_manager.HDMI_STAGE_CYCLES=100;
    wire clk=dut.clk_50m;
    task tick; @(negedge clk); endtask
    // Include one full receiver poll before the 100000-cycle debounce.
    task assertion_wait; repeat(101000) tick; endtask
    initial begin
        force dut.adv7611_manager.iic_busy=mock_busy;
        force dut.adv7611_manager.iic_ack_error=mock_error;
        force dut.adv7611_manager.rd_data=mock_data;
        forever begin
            wait(dut.adv7611_manager.iic_en);
            tick;
            device_address=dut.adv7611_manager.wr_data[7:0];
            register_address=dut.adv7611_manager.wr_data[15:8];
            mock_busy=1; mock_error=0; mock_data=0;
            if(!dut.adv7611_manager.iic_mode) begin
                if(device_address==8'h6c)
                    receiver_edid[register_address]=dut.adv7611_manager.wr_data[23:16];
            end else case(device_address)
                8'h6c: mock_data=receiver_edid[register_address];
                8'h64: mock_data=1;
                8'h98: mock_data=8'h40;
                8'h68: case(register_address)
                    8'h04: mock_data=locked ? 8'h03 : 8'h00;
                    8'h51: begin mock_data=q7[15:8]; mock_error=!frequency_valid; end
                    8'h52: mock_data=q7[7:0];
                    8'h07,8'h1b: mock_data=8'h00;
                    // An optional diagnostic NACK must not invalidate the
                    // complete lock/frequency sample or restart debounce.
                    8'he0: begin mock_data=0; mock_error=1; diagnostic_reads=diagnostic_reads+1; end
                    default: $fatal(1,"unexpected receiver register");
                endcase
                default: $fatal(1,"unexpected receiver device");
            endcase
            repeat(5) tick;
            mock_busy=0;
            wait(!dut.adv7611_manager.iic_en);
            tick;
        end
    end
    initial begin
        force dut.clk_50m_rst_n=rst;
        force dut.hdmi_video_valid=geometry;
        force dut.hdmi_rate_valid=rate;
        force dut.display_done_sys=display_complete;
        for(integer i=0;i<128;i=i+1) begin
            index=50+i; #10; edid[i]=transaction[15:8];
        end
        pixel_clock_khz=(edid[55]*256+edid[54])*10;
        q7=(pixel_clock_khz*128+500)/1000;
        $display("EDID pixel clock=%0d kHz, receiver q7=%0d",pixel_clock_khz,q7);
        if(dut.HDMI_H!=edid[56]+(edid[58]>>4)*256)
            $fatal(1,"top input width differs from actual EDID");
        repeat(200) tick; rst=1;
        // Cold boot now skips the stripe frame and captures only NO SIGNAL.
        wait(local_captures==1); repeat(200) tick;
        if(dut.capture_from_hdmi) $fatal(1,"HDMI selected without link");
        locked=1; frequency_valid=1; geometry=1; rate=1;
        assertion_wait();
        if(!dut.hdmi_capture_valid || hdmi_captures==0 || diagnostic_reads<3)
            $fatal(1,"handoff: q7=%h flags=%b%b%b%b candidate=%b age=%d capture=%b state=%d count=%d",
                dut.hdmi_tmds_q7,dut.edid_verified,dut.hdmi_locked,dut.hdmi_frequency_valid,
                dut.hdmi_valid_sync[1],dut.hdmi_link_candidate,dut.hdmi_valid_age,
                dut.hdmi_capture_valid,dut.system_manager.state,hdmi_captures);
        // Polling blips may be held, but sustained loss must exit to local.
        frequency_valid=0; repeat(1000) tick; frequency_valid=1;
        if(!dut.hdmi_capture_valid) $fatal(1,"short status blip dropped link");
        locked=0; frequency_valid=0; geometry=0; rate=0;
        repeat(1002000) tick;
        if(dut.hdmi_capture_valid || dut.capture_from_hdmi)
            $fatal(1,"unplug: valid=%b source=%b state=%d invalid_age=%d",
                dut.hdmi_capture_valid,dut.capture_from_hdmi,dut.system_manager.state,dut.hdmi_invalid_age);
        // A matching TMDS reading alone is not a valid parallel video stream.
        locked=1; frequency_valid=1;
        assertion_wait();
        if(dut.hdmi_capture_valid) $fatal(1,"missing parallel geometry/rate accepted");
        geometry=1; assertion_wait();
        if(dut.hdmi_capture_valid) $fatal(1,"wrong/stopped VS accepted");
        geometry=0; rate=1; assertion_wait();
        if(dut.hdmi_capture_valid) $fatal(1,"wrong geometry accepted");
        geometry=1; q7=16'h8640; assertion_wait();
        if(dut.hdmi_capture_valid) $fatal(1,"268.5 MHz mode accepted");
        q7=(pixel_clock_khz*128+500)/1000; assertion_wait();
        if(!dut.hdmi_capture_valid || !dut.capture_from_hdmi)
            $fatal(1,"reconnect failed");
        $display("PASS handoff: real receiver polls through diagnostic NACKs, real top selects HDMI capture, filters blips, rejects bad geometry/rate, unplugs and reconnects");
        $finish;
    end
    always @(posedge clk) begin
        display_complete<=0;
        if(dut.epd_s_flag) display_age<=20;
        else if(display_age>0) begin
            display_age<=display_age-1;
            if(display_age==1) display_complete<=1;
        end
        if(dut.w_gray_s_flag) begin
            if(dut.capture_from_hdmi) hdmi_captures<=hdmi_captures+1;
            else local_captures<=local_captures+1;
        end
    end
    initial begin #2000000000; $fatal(1,"handoff timeout"); end
endmodule

module frame_stream_es120mc1 #(
    parameter FRAME_H=2560,FRAME_V=1600,DATA0=0,DATA1=0,USE_NATIVE_GC16=1
)(
    input wire clk,rst_n,epd_rst_n,capture_start,display_start,pix_clk,
    gray_de,gray_vs,clear_start,epd_clk,row_request,fifo_pop,video_mode,refine,text_mode,
    input wire [7:0] gray_data, input wire [3:0] gray_source, input wire [7:0] phase,
    output wire capture_busy,capture_fault,dma_idle,GPIO_O,
    output wire [22:0] changed_pixels,
    output wire [22:0] drive_pixels,pending_pixels,
    output reg capture_done=0,clear_done=0,CLK_50M=0,
    output wire [63:0] fifo_data
);
    always #10 CLK_50M=~CLK_50M;
    assign GPIO_O=0;
    assign changed_pixels=0;
    assign drive_pixels=0;
    assign pending_pixels=0;
    assign fifo_data=0;
    assign capture_busy=0;
    assign capture_fault=0;
    assign dma_idle=1;
    always @(posedge clk) begin
        capture_done<=rst_n && capture_start;
        clear_done<=rst_n && clear_start;
    end
endmodule
