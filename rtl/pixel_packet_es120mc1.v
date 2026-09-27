// Eight pixels per beat, three panel fields per packet. The 75 Hz panel can
// accept a new 25 Hz target without restarting incomplete per-pixel waveforms.
module pixel_packet_es120mc1 #(
    parameter ENABLE_NATIVE_GC16 = 1
) (
    input wire clk, rst_n, valid,
    input wire video_mode, refine, text_mode,
    input wire [63:0] pixels,
    input wire [31:0] source_levels,
    input wire [127:0] history,
    output wire out_valid,
    output wire [63:0] drives,
    output wire [127:0] next_history,
    output reg [3:0] changed_count,
    output reg [3:0] drive_count, pending_count
);
    reg [2:0] valid_q;
    reg [1:0] video_q,refine_q,text_q;
    reg [63:0] pixels_q[0:2];
    reg [31:0] source_levels_q[0:2];
    wire [127:0] states[0:3];
    wire [15:0] field_drive[0:2];
    reg [15:0] drive0_q,drive0_qq,drive1_q;
    reg [7:0] changed_q[0:2];
    assign states[0]=history;
    assign next_history=states[3];
    assign out_valid=valid_q[2];
    genvar s,p;
    generate for(s=0;s<3;s=s+1) begin: fields
        wire [63:0] source_pixels=s==0 ? pixels : pixels_q[s-1];
        wire [31:0] source_gray=s==0 ? source_levels : source_levels_q[s-1];
        wire source_video=s==0 ? video_mode : video_q[s-1];
        wire source_refine=s==0 ? refine : refine_q[s-1];
        wire source_text=s==0 ? text_mode : text_q[s-1];
        for(p=0;p<8;p=p+1) begin: lanes
            wire [15:0] next_state;
            wire [1:0] fixed_code,lut_code;
            wire select_lut;
            wire [4:0] phase;
            wire [7:0] transition;
            reg [15:0] state_q;
            reg [1:0] fixed_q;
            reg lut_q;
            pixel_step_es120mc1 #(.ENABLE_NATIVE_GC16(ENABLE_NATIVE_GC16)) step (
                .before_state(states[s][p*16+:16]),.desired(source_pixels[p*8+4+:4]),
                .source_level(source_gray[p*4+:4]),.video_mode(source_video),
                .refine(source_refine),.text_mode(source_text),.after_state(next_state),
                .fixed_drive(fixed_code),.use_lut(select_lut),.lut_phase(phase),.transition(transition));
            gc16_lut_es120mc1 rom(.clk(clk),.phase(phase),.transition(transition),.drive(lut_code));
            always @(posedge clk) begin state_q<=next_state;fixed_q<=fixed_code;lut_q<=select_lut;end
            assign states[s+1][p*16+:16]=state_q;
            assign field_drive[s][p*2+:2]=lut_q ? lut_code : fixed_q;
        end
    end
    for(p=0;p<8;p=p+1) begin: packing
        assign drives[p*8+:8]={2'b0,field_drive[2][p*2+:2],drive1_q[p*2+:2],drive0_qq[p*2+:2]};
    end endgenerate
    integer i,k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixels_q[0]<=0;pixels_q[1]<=0;pixels_q[2]<=0;
            source_levels_q[0]<=0;source_levels_q[1]<=0;source_levels_q[2]<=0;
            video_q<=0;refine_q<=0;text_q<=0;
            drive0_q<=0;drive0_qq<=0;drive1_q<=0;
            changed_q[0]<=0;changed_q[1]<=0;changed_q[2]<=0;
        end else begin
            pixels_q[0]<=pixels;pixels_q[1]<=pixels_q[0];pixels_q[2]<=pixels_q[1];
            source_levels_q[0]<=source_levels;source_levels_q[1]<=source_levels_q[0];source_levels_q[2]<=source_levels_q[1];
            video_q<={video_q[0],video_mode};refine_q<={refine_q[0],refine};
            text_q<={text_q[0],text_mode};
            drive0_q<=field_drive[0];drive0_qq<=drive0_q;drive1_q<=field_drive[1];
            for(i=0;i<8;i=i+1) begin
                // Text-mode change detection follows the native source gray
                // level. Comparing a dithered endpoint with native history
                // makes every stable mid-gray background look changed.
                if (video_mode && text_mode)
                    changed_q[0][i]<=history[i*16+14+:2]!=2'd2 &&
                        source_levels[i*4+:4]!=history[i*16+5+:4];
                else
                    changed_q[0][i]<=history[i*16+14+:2]!=2'd2 &&
                        pixels[i*8+4+:4]!=history[i*16+5+:4];
            end
            changed_q[1]<=changed_q[0];changed_q[2]<=changed_q[1];
        end
    end
    always @(posedge clk or negedge rst_n)
        if(!rst_n) valid_q<=0;else valid_q<={valid_q[1:0],valid};
    always @* begin
        changed_count=0;drive_count=0;pending_count=0;
        for(k=0;k<8;k=k+1) begin
            changed_count=changed_count+changed_q[2][k];
            drive_count=drive_count+(drives[k*8+:6]!=0);
            if (text_q[1])
                pending_count=pending_count+(next_history[k*16+14+:2]!=0 ||
                    (next_history[k*16+14+:2]==0 && next_history[k*16+4]));
            else
                pending_count=pending_count+(next_history[k*16+14+:2]!=0 ||
                    next_history[k*16+:4]!=pixels_q[2][k*8+4+:4]);
        end
    end
endmodule
