# Phase-1 bring-up GOWIN project (top_bringup): ADS114S08 SPI verify + UART.
# Synthesize -> PnR -> bitstream (load to SRAM, not flash). GW1NR-9C.
#
# IMPORTANT: include ONLY these three sources. uart_tx_simple is ALSO redefined
# inside ads114s08_bringup_trace.v and ldc1101_bringup_trace.v (different ports),
# so adding either trace file here would cause a duplicate-module error.
set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5

add_file -type verilog top_bringup.v
add_file -type verilog ads114s08_spi.v
add_file -type verilog uart_tx_simple.v
add_file -type cst bringup.cst
add_file -type sdc bringup.sdc

set_option -top_module top_bringup
set_option -verilog_std v2001

run all
