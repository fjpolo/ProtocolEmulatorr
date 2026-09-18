# Gowin Tcl Batch Build Script for Sipeed Tang Nano 9K
# Project: ProtocolEmulator
# Target FPGA: Gowin GW1NR-LV9QN88PC6/I5 (GW1NR-9C)

set script_dir [file dirname [file normalize [info script]]]
cd $script_dir

set target "all"
if {$argc > 0} {
    set target [lindex $argv 0]
}

puts "============================================================"
puts "  ProtocolEmulator Tang Nano 9K - Gowin EDA Build Flow"
puts "  Target: $target"
puts "  Working Dir: $script_dir"
puts "============================================================"

# Open Gowin project
if {[catch {open_project nano9k.gprj} err]} {
    puts stderr "ERROR: Failed to open project nano9k.gprj: $err"
    exit 1
}

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
