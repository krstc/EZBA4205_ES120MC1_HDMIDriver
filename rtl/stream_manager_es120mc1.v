module stream_manager_es120mc1 #(
    parameter POWER_SETTLE_CYCLES=5000000,
    parameter BOOT_CYCLE_MIN_CYCLES=150000000,
    parameter HDMI_STAGE_CYCLES=100000000,
    parameter MODE_NOTICE_CYCLES=100000000,
    parameter CAPTURE_TIMEOUT_CYCLES=100000000,
    // Kept for source compatibility with older test benches. Text-mode local
    // refinement is now per-pixel and does not wait for a global frame count.
    parameter QUIET_FRAMES=20,
    parameter TEXT_IDLE_CYCLES=100000000,
    // Retained for compatibility with older instantiations. Smooth-mode
    // automatic global cleanup is disabled; M18 is the only cleanup trigger.
    parameter SMOOTH_CLEAN_CYCLES=100000000
)(
    input wire clk,rst_n,ready,hdmi_valid,hdmi_signal_locked,manual_refresh,
    input wire mode_toggle,hdmi_frame_changed,
    input wire capture_done,clear_done,display_done,dma_idle,capture_fault,
    input wire [22:0] changed_pixels,drive_pixels,pending_pixels,
    output reg capture_start,clear_start,display_start,
    output reg capture_from_hdmi,init_mode,white_only,datapath_run,refine,
    output reg text_mode,
    output reg [1:0] mode_notice,
    output reg [1:0] status_mode
);
    localparam POWER=0,CLEAR=1,INIT_START=2,INIT_WAIT=3,SELECT=4,SETTLE=5,
        CAP_START=6,CAP_WAIT=7,LAUNCH=8,PIPE_WAIT=9,IDLE=10,HOLD=11,
        DRAIN=12,RESET=13,MODE_HOLD=14;
    localparam TO_BOOT=0,TO_NO=1,TO_IN=2,TO_INFO=3,TO_VIDEO=4,TO_MODE=5;
    localparam NOTICE_SMOOTH=1,NOTICE_TEXT=2;
    reg [3:0] state;
    reg [2:0] destination,boot_left;
    reg [31:0] timer;
    reg booting,init_seen,cap_seen,display_seen,manual_pending,mode_pending;
    reg text_idle_refreshed,full_refine_pending;
    reg [1:0] notice_frames;
    reg [31:0] text_idle_timer;
    wire link_ok=hdmi_signal_locked && hdmi_valid;
    wire full_refine_request=full_refine_pending && capture_from_hdmi &&
        text_mode && mode_notice==0 && !hdmi_frame_changed;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=POWER;destination<=TO_BOOT;boot_left<=3;timer<=0;booting<=1;
            init_seen<=0;cap_seen<=0;display_seen<=0;manual_pending<=0;
            mode_pending<=0;notice_frames<=0;text_idle_timer<=0;
            text_idle_refreshed<=0;full_refine_pending<=0;
            capture_start<=0;clear_start<=0;display_start<=0;capture_from_hdmi<=0;
            init_mode<=1;white_only<=0;datapath_run<=1;refine<=0;status_mode<=0;
            text_mode<=0;mode_notice<=0;
        end else begin
            capture_start<=0;clear_start<=0;display_start<=0;
            if(manual_refresh) manual_pending<=1;
            if(mode_toggle) begin
                text_mode<=!text_mode;
                mode_notice<=text_mode ? NOTICE_SMOOTH : NOTICE_TEXT;
                mode_pending<=1;
                text_idle_timer<=0;
                text_idle_refreshed<=0;
                full_refine_pending<=0;
            end else if(!capture_from_hdmi || !text_mode || !link_ok || mode_notice!=0) begin
                text_idle_timer<=0;
                text_idle_refreshed<=0;
                full_refine_pending<=0;
            end else if(hdmi_frame_changed) begin
                // Any new source activity rearms exactly one later full GC16
                // cleanup. Local dirty pixels are refined independently.
                text_idle_timer<=0;
                text_idle_refreshed<=0;
                full_refine_pending<=0;
            end else if(!text_idle_refreshed && !full_refine_pending) begin
                if(text_idle_timer>=TEXT_IDLE_CYCLES-1) begin
                    text_idle_timer<=TEXT_IDLE_CYCLES-1;
                    full_refine_pending<=1;
                end else text_idle_timer<=text_idle_timer+1'b1;
            end
            case(state)
                POWER: if(!ready) timer<=0;
                    else if(timer==POWER_SETTLE_CYCLES-1) begin
                        timer<=0;clear_start<=1;state<=CLEAR;
                    end else timer<=timer+1'b1;
                CLEAR: if(clear_done) state<=booting ? INIT_START : SELECT;
                INIT_START: begin display_start<=1;timer<=0;init_seen<=0;state<=INIT_WAIT;end
                INIT_WAIT: begin
                    if(display_done) init_seen<=1;
                    if(timer<BOOT_CYCLE_MIN_CYCLES) timer<=timer+1'b1;
                    if((init_seen || display_done) && (!booting || timer>=BOOT_CYCLE_MIN_CYCLES)) begin
                        if(booting && boot_left>1) begin boot_left<=boot_left-1'b1;state<=INIT_START;end
                        else begin
                            init_mode<=0;white_only<=0;timer<=0;
                            if(booting) begin booting<=0;state<=SELECT;end
                            else begin clear_start<=1;state<=CLEAR;end
                        end
                    end
                end
                SELECT: begin
                    if(mode_pending && destination!=TO_MODE) begin
                        mode_pending<=0;destination<=TO_MODE;capture_from_hdmi<=0;
                        notice_frames<=0;refine<=0;timer<=0;state<=SETTLE;
                    end else begin
                        capture_from_hdmi<=(destination==TO_VIDEO || destination==TO_MODE) && link_ok;
                        status_mode<=destination==TO_INFO && hdmi_signal_locked ? 2'd2 :
                            ((destination==TO_IN || destination==TO_BOOT) && hdmi_signal_locked) ? 2'd1 : 2'd0;
                        if(destination==TO_VIDEO && !link_ok && hdmi_signal_locked) status_mode<=2'd2;
                        timer<=0;refine<=0;state<=SETTLE;
                    end
                end
                SETTLE: if(timer==63) begin timer<=0;state<=CAP_START;end
                    else timer<=timer+1'b1;
                CAP_START: begin
                    capture_start<=1;refine<=full_refine_request;
                    if(full_refine_request) begin
                        full_refine_pending<=0;text_idle_refreshed<=1;
                    end
                    timer<=0;state<=CAP_WAIT;
                end
                CAP_WAIT: if(capture_done) state<=LAUNCH;
                    else if(capture_fault || (capture_from_hdmi && !link_ok) || timer==CAPTURE_TIMEOUT_CYCLES-1) begin
                        timer<=0;state<=DRAIN;
                    end else timer<=timer+1'b1;
                LAUNCH: begin
                    display_start<=1;capture_start<=1;refine<=full_refine_request;
                    if(full_refine_request) begin
                        full_refine_pending<=0;text_idle_refreshed<=1;
                    end
                    cap_seen<=0;display_seen<=0;timer<=0;state<=PIPE_WAIT;
                end
                PIPE_WAIT: begin
                    if(capture_done) cap_seen<=1;
                    if(display_done) display_seen<=1;
                    if(capture_fault || (capture_from_hdmi && !link_ok) || timer==CAPTURE_TIMEOUT_CYCLES-1) begin
                        if(display_seen || display_done) begin timer<=0;state<=DRAIN;end
                    end else if((cap_seen || capture_done) && (display_seen || display_done)) begin
                        timer<=0;
                        if(manual_pending) begin
                            manual_pending<=0;destination<=link_ok ? TO_VIDEO : TO_NO;
                            capture_from_hdmi<=0;init_mode<=1;white_only<=1;state<=INIT_START;
                        end else if(mode_pending) begin
                            mode_pending<=0;destination<=TO_MODE;capture_from_hdmi<=0;
                            notice_frames<=0;refine<=0;state<=SELECT;
                        end else if(mode_notice!=0) begin
                            // Two 3-field packets complete the DU5 box/text
                            // dose even when the live background keeps moving.
                            if(notice_frames==1) begin
                                timer<=0;state<=MODE_HOLD;
                            end else begin
                                notice_frames<=notice_frames+1'b1;state<=LAUNCH;
                            end
                        end else if(!capture_from_hdmi && pending_pixels==0 && drive_pixels==0)
                            state<=status_mode==0 ? IDLE : HOLD;
                        else state<=LAUNCH;
                    end else timer<=timer+1'b1;
                end
                IDLE: if(manual_pending) begin
                        manual_pending<=0;destination<=hdmi_signal_locked ? TO_IN : TO_NO;
                        init_mode<=1;white_only<=1;state<=INIT_START;
                    end else if(mode_pending) begin
                        mode_pending<=0;destination<=TO_MODE;notice_frames<=0;state<=SELECT;
                    end else if(hdmi_signal_locked) begin destination<=TO_IN;state<=SELECT;end
                HOLD: if(!hdmi_signal_locked || manual_pending) begin
                        destination<=link_ok ? TO_VIDEO : TO_NO;manual_pending<=0;
                        init_mode<=1;white_only<=1;state<=INIT_START;
                    end else if(mode_pending) begin
                        mode_pending<=0;destination<=TO_MODE;notice_frames<=0;state<=SELECT;
                    end else if(timer>=HDMI_STAGE_CYCLES-1 && (status_mode==1 || hdmi_valid)) begin
                        destination<=status_mode==1 ? TO_INFO : TO_VIDEO;
                        init_mode<=1;white_only<=1;state<=INIT_START;
                    end else if(timer<HDMI_STAGE_CYCLES-1) timer<=timer+1'b1;
                MODE_HOLD: begin
                    refine<=0;
                    if(manual_pending) begin
                        manual_pending<=0;mode_notice<=0;
                        destination<=link_ok ? TO_VIDEO : TO_NO;
                        capture_from_hdmi<=0;init_mode<=1;white_only<=1;state<=INIT_START;
                    end else if(mode_pending) begin
                        mode_pending<=0;destination<=TO_MODE;notice_frames<=0;timer<=0;state<=SELECT;
                    end else if(timer>=MODE_NOTICE_CYCLES-1) begin
                        mode_notice<=0;timer<=0;
                        destination<=link_ok ? TO_VIDEO : TO_NO;state<=SELECT;
                    end else timer<=timer+1'b1;
                end
                DRAIN: if(!dma_idle) timer<=0;
                    else if(timer==63) begin datapath_run<=0;capture_from_hdmi<=0;timer<=0;state<=RESET;end
                    else timer<=timer+1'b1;
                RESET: if(timer==127) begin
                        datapath_run<=1;init_mode<=1;white_only<=1;booting<=0;
                        mode_notice<=0;destination<=hdmi_signal_locked ? TO_INFO : TO_NO;
                        timer<=0;state<=INIT_START;
                    end else timer<=timer+1'b1;
                default: state<=POWER;
            endcase
        end
    end
endmodule
