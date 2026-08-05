// Phase-1 bring-up clock: 27 MHz crystal on clk27 (top_bringup). 37.037 ns.
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk27}]
