`timescale 1ns/1ps
module receiver_case #(parameter CORRUPT=0, MONITOR_IO=0)(output reg done=0);
    reg clk=0,rst=0,mock_busy=0,mock_error=0;
    reg [7:0] mock_data=0, ram[0:127];
    reg [7:0] io_ram[0:255];
    reg [15:0] source_clock=16'h39d1;
    reg nack_frequency=0, nack_diagnostic=0, source_locked=1;
    reg [25:0] debug_command=0;
    wire [9:0] debug_response;
    wire [8:0] index,size;
    wire [39:0] txn;
    wire cfg_done,failed,verified,locked,freq_valid;
    wire [8:0] error_index;
    wire [15:0] freq;
    integer edid_reads=0, hpd_raises=0;
    reg [7:0] dev,addr,value;
    always #10 clk=~clk;
    config_reg_es120mc1 table_dut(.REG_INDEX(index),.REG_SIZE(size),.REG_DATA(txn));
    adv7611_iic_manager #(.STARTUP_DELAY_CYCLES(10),.I2C_RESET_DELAY_CYCLES(10),
        .EDID_DISABLE_DELAY_CYCLES(10),.HPD_LOW_HOLD_CYCLES(10),.HPD_HIGH_HOLD_CYCLES(10),
        .DETECT_PERIOD_CYCLES(20),.FULL_EDID_VERIFY(1),.MONITOR_TMDS_FREQ(1),
        .MONITOR_IO_CONFIG(MONITOR_IO),.DEBUG_ACCESS(MONITOR_IO),.HPA_VERIFY_VALUE(8'ha2)) dut(
        .clk(clk),.rst_n(rst),.REG_INDEX(index),.REG_DATA(txn),.REG_SIZE(size),
        .cfg_done(cfg_done),.cfg_failed(failed),.cfg_error_index(error_index),
        .edid_verified(verified),.hdmi_locked(locked),.hdmi_tmds_q7(freq),.hdmi_frequency_valid(freq_valid),
        .debug_command(debug_command),.debug_response(debug_response));
    // Exercise manager sequencing and error paths with transaction-level I2C
    // responses. The bit-level I2C controller is intentionally not tested here.
    initial begin
        force dut.iic_busy=mock_busy;
        force dut.iic_ack_error=mock_error;
        force dut.rd_data=mock_data;
        forever begin
            wait(dut.iic_en);
            @(negedge clk);
            dev=dut.wr_data[7:0]; addr=dut.wr_data[15:8]; value=dut.wr_data[23:16];
            mock_busy=1; mock_error=0; mock_data=0;
            if(!dut.iic_mode) begin
                if(CORRUPT==2 && dev==8'h64 && addr==8'h74 && value==1) mock_error=1;
                if(dev==8'h6c) ram[addr]=value;
                if(dev==8'h98) io_ram[addr]=value;
                if(dev==8'h98 && addr==8'h20 && value==8'hf0) begin
                    hpd_raises=hpd_raises+1;
                    if(!verified || edid_reads!=128) $fatal(1,"HPD raised before full EDID verification");
                end
            end else if(dev==8'h6c) begin
                if(addr!=edid_reads) $fatal(1,"EDID verify order");
                mock_data=ram[addr] ^ ((CORRUPT==1 && addr==55) ? 8'h01:8'h00);
                edid_reads=edid_reads+1;
            end else if(dev==8'h64) mock_data=(CORRUPT==3 && addr==8'h76) ? 0:1;
            else if(dev==8'h98) begin
                // Raw Port-A diagnostics are read from the IO map after the
                // normal HDMI-map lock/frequency registers.
                case(addr)
                    8'h6a: mock_data=8'h40;
                    default: begin
                        mock_data=io_ram[addr];
                        mock_error=nack_diagnostic && addr==8'h15;
                    end
                endcase
            end else if(dev==8'h68) begin
                case(addr)
                    8'h04: mock_data=source_locked ? 8'h03 : 8'h00;
                    8'h51: begin mock_data=source_clock[15:8]; mock_error=nack_frequency; end
                    8'h52: mock_data=source_clock[7:0];
                    8'h07, 8'h1b, 8'he0: begin mock_data=8'h00; mock_error=nack_diagnostic; end
                    default: $fatal(1,"unexpected polling register");
                endcase
            end
            repeat(5) @(negedge clk);
            mock_busy=0;
            wait(!dut.iic_en);
            @(negedge clk);
        end
    end
    task finish_poll;
        wait(dut.state==11 && dut.detect_index==(MONITOR_IO ? 13 : 6));
        wait(dut.state==8);
        @(negedge clk);
    endtask
    task stable_poll(input [15:0] expected, input bit expected_valid);
        finish_poll();
        if(freq!==expected || freq_valid!==expected_valid)
            $fatal(1,"poll corrupted frequency/status: expected q7=%h valid=%b, got q7=%h valid=%b",
                expected,expected_valid,freq,freq_valid);
    endtask
    task debug_access(input bit write_access, input [7:0] address,
                      input [7:0] data, input bit expect_error);
        @(negedge clk);
        debug_command={!debug_command[25],write_access,8'h98,address,data};
        wait(debug_response[9]===debug_command[25]);
        @(negedge clk);
        if(debug_response[8]!==expect_error || (!write_access && debug_response[7:0]!==data))
            $fatal(1,"Debug response mismatch: %h",debug_response);
        if(!locked || !freq_valid || freq!=16'h39d1 || !verified || hpd_raises!=1)
            $fatal(1,"Debug transaction corrupted normal receiver state");
    endtask
    initial begin
        #200; rst=1;
        wait(cfg_done); @(negedge clk);
        if(CORRUPT) begin
            if(!failed || verified || hpd_raises ||
               error_index!=(CORRUPT==1 ? 255 : (CORRUPT==2 ? 178:329)))
                $fatal(1,"EDID failure not contained: case=%0d index=%0d",CORRUPT,error_index);
        end else begin
            if(failed || !verified || hpd_raises!=1 || edid_reads!=128) $fatal(1,"good EDID rejected");
            wait(freq_valid);
            if(!locked || freq!=16'h39d1) $fatal(1,"115.63MHz measurement incorrect");
            repeat(3) stable_poll(16'h39d1,1);
            if(MONITOR_IO && (dut.io_config_valid!==7'h7f ||
               dut.io_config_readback!==56'h408a4280a72880))
                $fatal(1,"IO readback does not match the programmed output controls");
            if(MONITOR_IO) begin
                debug_access(0,8'h03,8'h80,0);
                debug_access(1,8'h33,8'h40,0);
                debug_access(0,8'h33,8'h40,0);
                nack_diagnostic=1;
                debug_access(0,8'h15,8'h80,1);
                nack_diagnostic=0;
            end
            nack_diagnostic=1;
            repeat(3) stable_poll(16'h39d1,1);
            if(MONITOR_IO && dut.io_config_valid!==7'h77)
                $fatal(1,"IO diagnostic NACK did not invalidate only the failing register");
            nack_diagnostic=0;
            source_clock=16'h8640;
            wait(freq==16'h8640);
            if(freq[15:7]!=268) $fatal(1,"268.5MHz measurement incorrect");
            stable_poll(16'h8640,1);
            nack_frequency=1;
            wait(!freq_valid);
            stable_poll(16'h8640,0);
            nack_frequency=0;
            source_clock=16'h39d1;
            wait(freq_valid);
            stable_poll(16'h39d1,1);
            source_locked=0;
            stable_poll(16'h39d1,0);
            if(locked) $fatal(1,"unplug retained receiver lock");
            source_locked=1;
            stable_poll(16'h39d1,1);
        end
        done=1;
    end
endmodule
module es120_receiver_tb;
    wire good_done,bad_done,enable_done,active_done,io_done;
    receiver_case good(good_done);
    receiver_case #(.CORRUPT(1)) bad(bad_done);
    receiver_case #(.CORRUPT(2)) enable_failure(enable_done);
    receiver_case #(.CORRUPT(3)) inactive_failure(active_done);
    receiver_case #(.MONITOR_IO(1)) io_monitor(io_done);
    initial begin
        wait(good_done && bad_done && enable_done && active_done && io_done);
        $display("PASS receiver: full EDID before HPD, corrupt/enable-NACK/inactive containment, TMDS 115.63/268.5MHz and read NACK");
        $finish;
    end
    initial begin #2000000; $fatal(1,"receiver timeout"); end
endmodule
