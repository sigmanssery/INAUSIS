# Full bidirectional system (ttcgs_sys) synthesis fit check on GW1NR-9C
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

set_option -top_module ttcgs_sys
set_option -verilog_std v2001

run syn
