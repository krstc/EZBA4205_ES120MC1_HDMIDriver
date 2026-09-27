set root_dir [file normalize [file dirname [info script]]]
set bit_file [file join $root_dir es120mc1_jtag_diagnostic EBAZ4205_ES120MC1_EDID_DIAGNOSTIC.bit]
set ltx_file [file join $root_dir es120mc1_jtag_diagnostic EBAZ4205_ES120MC1_EDID_DIAGNOSTIC.ltx]

if {![file exists $bit_file]} {
    error "Bitstream does not exist: $bit_file"
}

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

set dev [lindex [get_hw_devices xc7z010*] 0]
if {$dev eq ""} {
    error "xc7z010 not found on the current JTAG target"
}

set_property PROGRAM.FILE $bit_file $dev
set_property PROBES.FILE $ltx_file $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "JTAG_PROGRAMMED_DEVICE=[get_property PART $dev]"
puts "JTAG_PROGRAMMED_BIT=$bit_file"

close_hw_target
disconnect_hw_server
close_hw_manager
