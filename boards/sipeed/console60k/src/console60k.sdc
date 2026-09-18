// Timing constraints for Tang Console 60K (50 MHz onboard oscillator)
create_clock -name sys_clk_50m -period 20.000 -waveform {0 10.000} [get_ports {i_sys_clk}]
