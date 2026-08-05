# Real board-level top (ttcgs_board): synthesis + PnR + 27 MHz timing + bitstream
# with the schematic-verified pin constraints (inausis.cst).
set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5

add_file -type verilog crc16_ccitt.v
add_file -type verilog manchester_enc.v
add_file -type verilog manchester_tx.v
add_file -type verilog manchester_rx.v
add_file -type verilog zscore_flag_multi.v
add_file -type verilog dog_fir_multi.v
add_file -type verilog frame_packer.v
add_file -type verilog dsp_chain.v
add_file -type verilog lut_parser.v
add_file -type verilog halfduplex_ctrl.v
add_file -type verilog ttcgs_sys.v
add_file -type verilog ads114s08_spi.v
add_file -type verilog ldc1101_spi.v
add_file -type verilog ttcgs_board.v
add_file -type cst inausis.cst
add_file -type sdc board.sdc

set_option -top_module ttcgs_board
set_option -verilog_std v2001

run all
