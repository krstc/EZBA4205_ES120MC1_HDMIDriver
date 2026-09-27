// Measure VS in the independent system clock domain. A stopped receiver
// pixel clock must not leave an old video_valid asserted indefinitely.
module hdmi_frame_guard_es120mc1 #(
    parameter integer CLK_HZ = 50000000
)(
    input wire clk, rst_n, vs,
    output reg rate_valid,
    output reg [31:0] measured_period
);
    localparam integer MIN_PERIOD = CLK_HZ / 26;
    localparam integer MAX_PERIOD = CLK_HZ / 24;
    (* ASYNC_REG = "TRUE" *) reg [1:0] vs_sync;
    reg vs_d, seen_vs, previous_good;
    reg [31:0] elapsed;
    wire good_period = elapsed + 1 >= MIN_PERIOD && elapsed + 1 <= MAX_PERIOD;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_sync <= 0; vs_d <= 0; elapsed <= 0; seen_vs <= 0;
            previous_good <= 0; rate_valid <= 0; measured_period <= 0;
        end else begin
            vs_sync <= {vs_sync[0], vs};
            vs_d <= vs_sync[1];
            if (vs_sync[1] && !vs_d) begin
                measured_period <= elapsed + 1'b1;
                elapsed <= 0; seen_vs <= 1;
                previous_good <= seen_vs && good_period;
                rate_valid <= seen_vs && previous_good && good_period;
            end else if (elapsed < MAX_PERIOD) elapsed <= elapsed + 1'b1;
            else begin
                rate_valid <= 0; seen_vs <= 0; previous_good <= 0;
            end
        end
    end
endmodule
