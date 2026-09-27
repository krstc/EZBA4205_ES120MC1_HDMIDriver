// Per-pixel progress, following the AUTO_LUT / early-cancellation strategy
// described by Modos Caster. ES120 uses its own DU5 and 30-phase GC16 table.
// DONE:      {mode[1:0], remaining[4:0], last_source[3:0], dirty, actual[3:0]}.
// MONO:      {mode[1:0], remaining[4:0], last_source[3:0], direction, actual[3:0]}.
// GREY:      {2'b10, next_phase[4:0], 1'b0, source[3:0], target[3:0]}.
module pixel_step_es120mc1 #(
    // Text mode supplies native 16-level targets and uses GC16 only for the
    // pixels selected by the dirty-pixel packet. Smooth mode continues to
    // use its binary fast path and its existing refinement policy.
    parameter ENABLE_NATIVE_GC16 = 1
) (
    input wire [15:0] before_state,
    input wire [3:0] desired,
    input wire [3:0] source_level,
    input wire video_mode, refine, text_mode,
    output reg [15:0] after_state,
    output reg [1:0] fixed_drive,
    output reg use_lut,
    output reg [4:0] lut_phase,
    output reg [7:0] transition
);
    localparam DONE=2'd0, MONO=2'd1, GREY=2'd2;
    wire [1:0] mode=before_state[15:14];
    wire [4:0] count=before_state[13:9];
    wire [3:0] actual=before_state[3:0];
    wire [3:0] last_source=before_state[8:5];
    wire direction=before_state[4];
    wire dirty=before_state[4];
    wire source_changed=source_level!=last_source;
    wire text_dirty=video_mode && text_mode;
    wire endpoint=actual==0 || actual==15;
    wire [4:0] return_pulses=5-count;
    always @* begin
        after_state=before_state;
        fixed_drive=0;use_lut=0;lut_phase=0;transition=0;
        case(mode)
            GREY: begin
                // A native transition must finish against the SAME source and
                // target even when HDMI changes halfway through the waveform.
                lut_phase=count;transition=before_state[7:0];
                use_lut=count<30;
                if(count==31)
                    after_state={DONE,5'd0,actual,1'b0,actual};
                else after_state={GREY,count+5'd1,1'b0,before_state[7:0]};
            end
            MONO: begin
                fixed_drive=direction ? 2'b10 : 2'b01;
                if(desired[3]!=direction && endpoint) begin
                    // Reverse only the charge already delivered, not another
                    // full DU5. count excludes the field being generated now.
                    fixed_drive=desired[3] ? 2'b10 : 2'b01;
                    if(return_pulses<=1) begin
                        if(return_pulses==0) fixed_drive=0;
                        after_state={DONE,5'd0,source_level,text_dirty,{4{desired[3]}}};
                    end else
                        // The first reverse pulse is already in the new
                        // direction; keep that direction for the remaining
                        // cancellation pulses while retaining the old
                        // endpoint as the committed-position marker.
                        after_state={MONO,return_pulses-5'd1,source_level,desired[3],{4{direction}}};
                end else if(count<=1)
                    after_state={DONE,5'd0,source_level,text_dirty,{4{direction}}};
                else after_state={MONO,count-5'd1,source_level,direction,actual};
            end
            default: begin
                after_state={DONE,5'd0,source_level,dirty,actual};
                // Text mode has two independent paths. A changing pixel first
                // takes the short binary transition. Once THAT pixel is stable
                // it refines itself with GC16, regardless of activity elsewhere.
                // refine is reserved for the one-shot whole-screen GC16 pass.
                if(text_dirty) begin
                    if(refine && ENABLE_NATIVE_GC16) begin
                        use_lut=1;transition={source_level,actual};
                        after_state={GREY,5'd1,1'b0,actual,source_level};
                    end else if(source_changed) begin
                        if(!endpoint || desired[3]!=actual[3]) begin
                            fixed_drive=desired[3] ? 2'b10 : 2'b01;
                            after_state={MONO,5'd4,source_level,desired[3],actual};
                        end else begin
                            // A gray change inside the same binary half needs
                            // no endpoint repaint, but still owes a GC16 pass.
                            after_state={DONE,5'd0,source_level,1'b1,actual};
                        end
                    end else if(dirty) begin
                        if(source_level==actual)
                            after_state={DONE,5'd0,source_level,1'b0,actual};
                        else if(ENABLE_NATIVE_GC16) begin
                            use_lut=1;transition={source_level,actual};
                            after_state={GREY,5'd1,1'b0,actual,source_level};
                        end
                    end
                end else if(desired!=actual) begin
                    if(ENABLE_NATIVE_GC16 &&
                       (!video_mode || (refine && desired==before_state[8:5]))) begin
                        use_lut=1;transition={desired,actual};
                        after_state={GREY,5'd1,1'b0,actual,desired};
                    end else if(!endpoint || desired[3]!=actual[3]) begin
                        fixed_drive=desired[3] ? 2'b10 : 2'b01;
                        after_state={MONO,5'd4,source_level,desired[3],actual};
                    end
                end
            end
        endcase
        if(mode==GREY) transition={before_state[3:0],before_state[7:4]};
    end
endmodule
