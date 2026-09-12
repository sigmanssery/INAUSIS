set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5
add_file -type verilog power_null.v
add_file -type cst led_id.cst
set_option -top_module power_null
set_option -output_base_name project
run all
