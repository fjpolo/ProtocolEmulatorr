# Gowin Tcl Batch Build Script for Sipeed Tang Console 60K
# Project: ProtocolEmulator
# Target FPGA: Gowin GW5AT-LV60PG484AC1/I0 (GW5AT-60B)

set script_dir [file dirname [file normalize [info script]]]
cd $script_dir

set target "all"
if {$argc > 0} {
    set target [lindex $argv 0]
}

puts "============================================================"
puts "  ProtocolEmulator Tang Console 60K - Gowin EDA Build Flow"
puts "  Target: $target"
puts "  Working Dir: $script_dir"
puts "============================================================"

# Open Gowin project
if {[catch {open_project console60k.gprj} err]} {
    puts stderr "ERROR: Failed to open project console60k.gprj: $err"
    exit 1
}

# Ensure critical project options are set
set_option -top_module top
set_option -verilog_std sysv2017

# Execute flow
if {$target == "syn"} {
    puts "==> Running Logic Synthesis..."
    if {[catch {run syn} err]} {
        puts stderr "ERROR: Synthesis failed: $err"
        exit 1
    }
} elseif {$target == "pnr"} {
    puts "==> Running Place & Route..."
    if {[catch {run pnr} err]} {
        puts stderr "ERROR: Place & Route failed: $err"
        exit 1
    }
} else {
    puts "==> Running Full Flow: Synthesis, PnR, Bitstream Generation..."
    if {[catch {run all} err]} {
        puts stderr "ERROR: Build failed: $err"
        exit 1
    }
}

puts "============================================================"
puts "  Gowin Build Finished Successfully!"
puts "============================================================"
exit 0
