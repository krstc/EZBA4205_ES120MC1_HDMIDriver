# Keep the script path literal. Vivado's Windows Tcl layer in this setup
# incorrectly resolves the Desktop component when file normalize is used.
set root_dir [file dirname [info script]]
set project_path [file join $root_dir .. c p Eink_controller_V1.0.xpr]
set source_dir [file join $root_dir .. c p Eink_controller_V1.0.srcs sources_1 new]
set constraint_dir [file join $root_dir .. c p Eink_controller_V1.0.srcs constrs_1 new]
set output_dir [file join $root_dir es120mc1_jtag_diagnostic]
if {$argc > 0} {set output_dir [lindex $argv 0]}

set es120_sources [list \
    [file join $source_dir config_reg_es120mc1.v] \
    [file join $source_dir adv7611_iic_manager.v] \
    [file join $source_dir status_frame_source.v] \
    [file join $source_dir status_system_mgr.v] \
    [file join $source_dir status_source_es120mc1.v] \
    [file join $source_dir status_manager_es120mc1.v] \
    [file join $source_dir fdma_w_mono_es120mc1.v] \
    [file join $source_dir gc16_lut_es120mc1.v] \
    [file join $source_dir fdma_w_gc16_es120mc1.v] \
    [file join $source_dir fdma_r_gc16_es120mc1.v] \
    [file join $source_dir pixel_step_es120mc1.v] \
    [file join $source_dir pixel_packet_es120mc1.v] \
    [file join $source_dir frame_stream_es120mc1.v] \
    [file join $source_dir fdma_r_packet_es120mc1.v] \
    [file join $source_dir fdma_page_guard_es120mc1.v] \
    [file join $source_dir stream_manager_es120mc1.v] \
    [file join $source_dir hdmi_timing_qualifier.v] \
    [file join $source_dir hdmi_input_es120mc1.v] \
    [file join $source_dir hdmi_frame_guard_es120mc1.v] \
    [file join $source_dir config_reg_es120mc1.v] \
    [file join $source_dir clock_pll_es120mc1.v] \
    [file join $source_dir frame_timing.v] \
    [file join $source_dir frame_ctrl.v] \
    [file join $source_dir display_mgr.v] \
    [file join $source_dir frame_ctrl_es120mc1.v] \
    [file join $source_dir display_mgr_es120mc1.v] \
    [file join $source_dir eink_controller_es120mc1.v]]

file mkdir $output_dir
open_project $project_path
# The project previously retained 1920x1080 overrides from the original panel.
# Set the DDR stride/clear geometry explicitly; Verilog defaults do not override
# a Vivado fileset generic.
set_property generic {MAX_H=2560 MAX_V=1600 FRAME_H=2560 FRAME_V=1600 HDMI_H=2560 EPD_H=2560 EPD_V=1600} [get_filesets sources_1]
set build_defines {EDID_ILA}
set pinout_diagnostic 0
set route_explore 0
if {$argc > 1 && [lindex $argv 1] eq "pinout"} {
    set pinout_diagnostic 1
    lappend build_defines HDMI_PINOUT_ILA
}
if {$argc > 1 && [lindex $argv 1] eq "route_explore"} {
    set route_explore 1
}
set_property verilog_define $build_defines [get_filesets sources_1]
if {[llength [get_ips -quiet adv7611_debug_vio]] == 0} {
    create_ip -name vio -vendor xilinx.com -library ip -module_name adv7611_debug_vio
    set_property -dict [list CONFIG.C_NUM_PROBE_IN {1} CONFIG.C_NUM_PROBE_OUT {1} \
        CONFIG.C_PROBE_IN0_WIDTH {10} CONFIG.C_PROBE_OUT0_WIDTH {26} \
        CONFIG.C_PROBE_OUT0_INIT_VAL {0x0000000}] [get_ips adv7611_debug_vio]
}
generate_target all [get_ips adv7611_debug_vio]
foreach source_file $es120_sources {
    if {[llength [get_files -quiet $source_file]] == 0} {
        add_files -norecurse $source_file
    }
}
set cdc_constraint [file join $constraint_dir es120mc1_cdc.xdc]
set active_constrs [get_property CONSTRSET [get_runs impl_1]]
if {[llength [get_files -quiet $cdc_constraint]] == 0} {
    add_files -fileset $active_constrs -norecurse $cdc_constraint
}
update_compile_order -fileset sources_1
set_property top eink_controller_es120mc1 [get_filesets sources_1]

reset_run impl_1
reset_run synth_1
if {$route_explore} {
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraPostPlacementOpt [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
}
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithAggressiveHoldFix [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set run_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $run_status"
if {![string match "*Complete*" $run_status]} {
    error "Implementation did not complete: $run_status"
}

open_run impl_1
report_timing_summary -file [file join $output_dir timing_summary.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
report_bus_skew -file [file join $output_dir bus_skew.rpt]
report_timing -to [get_ports {EPD_DOUT[*]}] -delay_type max -max_paths 16 \
    -file [file join $output_dir panel_setup.rpt]
report_timing -to [get_ports {EPD_DOUT[*]}] -delay_type min -max_paths 16 \
    -file [file join $output_dir panel_hold.rpt]
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0 ||
    [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {
    if {!$pinout_diagnostic} {
        error "Timing violations remain; do not publish a NAND candidate"
    }
    puts "WARNING: pinout diagnostic contains intentional asynchronous probe paths; JTAG use only"
}
file copy -force \
    [file join $root_dir .. c p Eink_controller_V1.0.runs impl_1 eink_controller_es120mc1.bit] \
    [file join $output_dir EBAZ4205_ES120MC1_EDID_DIAGNOSTIC.bit]
file copy -force \
    [file join $root_dir .. c p Eink_controller_V1.0.runs impl_1 eink_controller_es120mc1.ltx] \
    [file join $output_dir EBAZ4205_ES120MC1_EDID_DIAGNOSTIC.ltx]
close_project
