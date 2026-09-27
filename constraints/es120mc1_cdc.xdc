# epd_busy is synchronized before reaching the 50 MHz power controller.
set receiver_probe_d [get_pins -quiet -of_objects \
    [get_cells -hier -quiet -filter {NAME =~ *receiver_debug_sync0_reg*}] \
    -filter {REF_PIN_NAME == D}]
# Only the first stage samples asynchronous external signals. XDC does not
# execute Tcl 'if'; -quiet also allows builds without the optional probes.
set_false_path -quiet -to $receiver_probe_d

set_false_path -from [get_clocks epd_clk_mmcm] \
    -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ *epd_busy_cdc/sync_ff_reg*}] -filter {REF_PIN_NAME == D}]

# ADV7611 pixel data crosses into the PS/DDR clock domain only through XPM
# asynchronous FIFOs and xpm_cdc_pulse instances in fdma_w_gray.
set_clock_groups -asynchronous \
    -group [get_clocks pix_clk] \
    -group [get_clocks clk_50m_mmcm]

# Model the actual forwarded panel clock, not an unrelated primary clock
# placed on an output port. ES120MC1 p11 requires SDD tSU/tH >= 8 ns.
create_generated_clock -name EPD_SDCK -source [get_pins clock_pll/u_mmcm/CLKOUT0] \
    -divide_by 1 [get_ports EPD_XCL]
set_output_delay -clock EPD_SDCK -max 8.000 [get_ports {EPD_DOUT[*]}]
set_output_delay -clock EPD_SDCK -min -8.000 [get_ports {EPD_DOUT[*]}]

# The I2C bit engine uses the divided register clock internally (50 MHz / 250).
# A primary clock on the SCL output does not constrain these internal flops.
create_generated_clock -name ADV_I2C_BITCLK \
    -source [get_pins adv7611_manager/iic_ctrl/scl_clk_reg/C] -divide_by 250 \
    [get_pins adv7611_manager/iic_ctrl/scl_clk_reg/Q]
