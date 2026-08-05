# Combined ADS114S08 + LDC1101 readout (top_dual) -> single UART.
# uart_byte_tx is defined inside top_dual.v; do NOT add the ADS/LDC bring-up
# UARTs (name clash). GW1NR-9C, load to SRAM.
set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5

add_file -type verilog top_dual.v
add_file -type verilog ads114s08_spi.v
add_file -type verilog ldc1101_spi.v
add_file -type cst dual_bringup.cst
add_file -type sdc bringup.sdc

set_option -top_module top_dual
set_option -verilog_std v2001

run all
