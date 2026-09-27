// 50 MHz PS FCLK input, ES120MC1 75 Hz scan source clock, and a retained
// 50 MHz system clock. The 44.0677966 MHz output yields 75.0057 Hz with the
// VD1400-MOA Mode 3 timing: 362 SDCK/line and 1623 lines/frame.
module clock_pll_es120mc1 (
    input  wire clk_in,
    input  wire resetn,
    output wire epd_clk,
    output wire clk_50m,
    output wire locked
    );

    wire clkfb;
    wire clkfb_buf;
    wire clk_in_buf;
    wire epd_clk_mmcm;
    wire clk_50m_mmcm;

    IBUF u_ibuf (.I(clk_in), .O(clk_in_buf));
    BUFG u_fb_buf (.I(clkfb), .O(clkfb_buf));
    BUFG u_epd_buf (.I(epd_clk_mmcm), .O(epd_clk));
    BUFG u_50m_buf (.I(clk_50m_mmcm), .O(clk_50m));

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(13.0),
        .CLKIN1_PERIOD(20.0),
        // 650 MHz VCO / 14.75 = 44.0677966 MHz.
        .CLKOUT0_DIVIDE_F(14.75),
        .CLKOUT1_DIVIDE(13),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKOUT0(epd_clk_mmcm),
        .CLKOUT1(clk_50m_mmcm),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKFBOUT(clkfb),
        .CLKIN1(clk_in_buf),
        .CLKFBIN(clkfb_buf),
        .PWRDWN(1'b0),
        .RST(~resetn),
        .LOCKED(locked)
    );
endmodule
