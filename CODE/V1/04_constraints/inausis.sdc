// 27 MHz system clock (Tang Nano 9K crystal). Period = 1/27e6 = 37.037 ns.
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
